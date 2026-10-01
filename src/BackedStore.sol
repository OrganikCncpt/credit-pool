// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IBackedPool {
    function usdWei() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function statements() external view returns (IERC721);
    function store() external view returns (address);
    function batchInfo(uint256 b)
        external
        view
        returns (uint8 state, uint256 filled, uint256 depositorCount, uint256 statementId, uint256 proceeds, uint64 round, uint64 nonce);
    function majorityMinimum(uint256 b) external view returns (uint256);
    function backings(uint256 b, address who) external view returns (uint256 amount, uint64 nonce);
    function back(uint256 b) external payable;
    function withdrawBacking(uint256 b) external;
    function reconfirm(uint256 b) external;
    function withdrawRefund() external;
    function pendingReturns(address who) external view returns (uint256);
}

/// @title credit.pool store for BackedPool (backed auctions)
/// @notice Three things, all funded by the pool's deposit fees:
///         1. SCREDIT ("Store Credit"): non-transferable points. When a batch is burned into a
///            Statement, the pool awards each depositor 2 per Credit in it. They can't be sent, sold or approved;
///            they can only be bid here.
///         2. The treasury: 75% of every deposit fee. Its only outflow is backBatch: an
///            owner-triggered backing of a full pool batch (the pool's opening bid if it's the best),
///            capped per batch by maxTreasuryBid and never above the depositors' own majority
///            minimum. An auction only opens at or above that minimum, so in practice the treasury
///            backs at exactly the depositors' price, and wins only if nobody outbids it.
///            TRUST: the owner decides which batches to back and for how much, within that cap.
///            Raising the cap takes CAP_RAISE_DELAY to apply, so depositors can see it coming.
///         3. The store auction: Statements the treasury won are auctioned for SCREDIT only.
///            Every bid also pays a $0.25 platform fee in ETH. Outbid points come back; the
///            winner's points are burned. These Statements never go back into the pool.
contract BackedStore is ReentrancyGuard, Ownable2Step {
    // ───────────────────────── SCREDIT (points) ─────────────────────────
    string public constant name = "Store Credit";
    string public constant symbol = "SCREDIT";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;                    // = Σ balanceOf, including the store's own
    mapping(address => uint256) public balanceOf;  // the store's own balance = points escrowed in live bids

    // ───────────────────────── store auction ─────────────────────────
    uint256 public constant FEE_CALL_GAS = 100_000;      // gas given to the fee wallet (same as the pool)
    uint256 public constant BID_FEE_CENTS = 25;         // $0.25 in ETH per bid, to the platform
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant AUCTION_EXTENSION = 15 minutes;
    uint256 public constant MIN_BID_INCREMENT_BPS = 500; // 5%, at least 1 point

    struct Listing {
        address highBidder;
        uint256 highBid;   // points
        uint256 reserve;   // points
        uint64 endsAt;     // 0 = not listed
    }

    IBackedPool public pool;
    IERC721 public statements;
    uint256 public bidFees;         // ETH owed to the platform; everything else held is treasury
    uint256 public constant CAP_RAISE_DELAY = 3 days;
    uint256 internal _maxTreasuryBid; // cap on the treasury's total backing of one batch
    uint256 public pendingMaxTreasuryBid;
    uint64 public pendingMaxTreasuryBidAt;
    mapping(uint256 statementId => Listing) public listings;

    event Transfer(address indexed from, address indexed to, uint256 value); // ERC-20 shape, mint/burn only
    event PoolSet(address pool);
    event MaxTreasuryBidSet(uint256 amount);
    event MaxTreasuryBidRaiseScheduled(uint256 amount, uint64 effectiveAt);
    event TreasuryBacked(uint256 indexed batchId, uint256 amount, uint256 total);
    event TreasuryUnbacked(uint256 indexed batchId);
    event Listed(uint256 indexed statementId, uint256 reserve, uint64 endsAt);
    event StoreBid(uint256 indexed statementId, address indexed bidder, uint256 points, uint256 fee, uint64 endsAt);
    event StoreSettled(uint256 indexed statementId, address winner, uint256 points);
    event BidFeesSwept(address indexed to, uint256 amount);
    event BidFeesHeld(address indexed to, uint256 amount);

    error NonTransferable();
    error NotPool();
    error PoolAlreadySet();
    error NotFull();
    error AboveMinimum();
    error NoMinimum();
    error PriceMoved();
    error NotDepositor();
    error LengthMismatch();
    error WrongPool();
    error OverCap();
    error NotHeld();
    error NotListed();
    error AuctionLive();
    error AuctionOver();
    error BidTooLow();
    error InsufficientFee();
    error InsufficientPoints();
    error TransferFailed();
    error RenounceDisabled();

    constructor(uint256 initialMaxTreasuryBid) Ownable(msg.sender) {
        _maxTreasuryBid = initialMaxTreasuryBid;
        emit MaxTreasuryBidSet(initialMaxTreasuryBid);
    }

    /// @notice One-time link to the pool (the pool is deployed after the store and knows it).
    ///         Refuses a pool that doesn't point back here: a wrong link would brick its deposits.
    function setPool(address pool_) external onlyOwner {
        if (address(pool) != address(0)) revert PoolAlreadySet();
        if (IBackedPool(pool_).store() != address(this)) revert WrongPool();
        pool = IBackedPool(pool_);
        statements = IBackedPool(pool_).statements();
        emit PoolSet(pool_);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ───────────────────────── points ─────────────────────────

    /// @notice Called by the pool when a batch is assembled: each depositor's points for that batch.
    function award(address[] calldata to, uint256[] calldata points) external {
        if (msg.sender != address(pool)) revert NotPool();
        if (to.length != points.length) revert LengthMismatch();
        for (uint256 i; i < to.length; ++i) {
            balanceOf[to[i]] += points[i];
            totalSupply += points[i];
            emit Transfer(address(0), to[i], points[i]);
        }
    }

    // Wallets probe these; points never move between accounts.
    function transfer(address, uint256) external pure returns (bool) { revert NonTransferable(); }
    function transferFrom(address, address, uint256) external pure returns (bool) { revert NonTransferable(); }
    function approve(address, uint256) external pure returns (bool) { revert NonTransferable(); }
    function allowance(address, address) external pure returns (uint256) { return 0; }

    // ───────────────────────── treasury ─────────────────────────

    /// @notice ETH that belongs to the treasury (everything held except unswept bid fees).
    function treasuryBalance() public view returns (uint256) {
        return address(this).balance - bidFees;
    }

    /// @notice The per-purchase cap in force now (a scheduled raise applies after its delay).
    function maxTreasuryBid() public view returns (uint256) {
        uint64 at = pendingMaxTreasuryBidAt;
        return at != 0 && block.timestamp >= at ? pendingMaxTreasuryBid : _maxTreasuryBid;
    }

    /// @notice Lowering the cap applies at once; raising it applies CAP_RAISE_DELAY later.
    function setMaxTreasuryBid(uint256 amount) external onlyOwner {
        uint256 current = maxTreasuryBid();
        _maxTreasuryBid = current;
        if (amount <= current) {
            _maxTreasuryBid = amount;
            pendingMaxTreasuryBid = 0;
            pendingMaxTreasuryBidAt = 0;
            emit MaxTreasuryBidSet(amount);
        } else {
            uint64 at = uint64(block.timestamp + CAP_RAISE_DELAY);
            pendingMaxTreasuryBid = amount;
            pendingMaxTreasuryBidAt = at;
            emit MaxTreasuryBidRaiseScheduled(amount, at);
        }
    }

    /// @notice Back a full batch from the treasury. `expectedTotal` is the treasury's total backing
    ///         on this batch after the call, as the owner reviewed it: anything else reverts. The
    ///         depositors must have a majority price first, and the total stays within maxTreasuryBid
    ///         and that price: the treasury never offers more than the depositors themselves ask.
    ///         Topping up (any amount) also re-confirms a backing after the batch's Credits changed.
    function backBatch(uint256 b, uint256 amount, uint256 expectedTotal) external onlyOwner nonReentrant {
        (uint8 state,, uint256 depositors,,,,) = pool.batchInfo(b);
        if (state != 1) revert NotFull();                    // Full only: a batch whose Credits are final
        if (depositors < 2) revert NotDepositor();          // never a sole 80-slot holder's batch (they can redeem)
        (uint256 current,) = pool.backings(b, address(this));
        uint256 total = current + amount;
        if (total != expectedTotal) revert PriceMoved();
        uint256 minimum = pool.majorityMinimum(b);
        // No price yet: no auction can open, so a treasury backing would only sit there, and it
        // could later open above whatever price the depositors then set (option-1 audit L).
        if (minimum == 0) revert NoMinimum();
        if (total > minimum) revert AboveMinimum();
        if (total > maxTreasuryBid() || amount > treasuryBalance()) revert OverCap();
        pool.back{value: amount}(b);
        emit TreasuryBacked(b, amount, total);
    }

    /// @notice Re-confirm the treasury's backing after the batch's Credits changed, without adding ETH.
    ///         Same rules as backBatch: a Full batch, not a sole holder's, with a depositors' price the
    ///         backing doesn't exceed.
    function reconfirmBatch(uint256 b) external onlyOwner nonReentrant {
        (uint8 state,, uint256 depositors,,,,) = pool.batchInfo(b);
        if (state != 1) revert NotFull();
        if (depositors < 2) revert NotDepositor();
        (uint256 current,) = pool.backings(b, address(this));
        uint256 minimum = pool.majorityMinimum(b);
        if (minimum == 0) revert NoMinimum();
        if (current > minimum) revert AboveMinimum();
        pool.reconfirm(b);
        emit TreasuryBacked(b, 0, current);
    }

    /// @notice Take the treasury's backing on a batch back into the treasury (only while it isn't a
    ///         running auction's opening bid; the pool enforces that).
    function unbackBatch(uint256 b) external onlyOwner nonReentrant {
        pool.withdrawBacking(b);
        pool.withdrawRefund();
        emit TreasuryUnbacked(b);
    }

    /// @notice Pull everything the pool owes the treasury (outbid, withdrawn or evicted backings,
    ///         unwound sales) back into it. Anyone can call.
    function collectRefund() external nonReentrant {
        if (pool.pendingReturns(address(this)) != 0) pool.withdrawRefund();
    }

    /// @dev ETH arrives only from the pool: its fee sweep and returned backings.
    receive() external payable {
        if (msg.sender != address(pool)) revert NotPool();
    }

    // ───────────────────────── store auction (SCREDIT only) ─────────────────────────

    /// @notice $0.25 in wei at the pool's current ETH price.
    function bidFee() public view returns (uint256) {
        return (pool.usdWei() * BID_FEE_CENTS) / 100;
    }

    /// @notice Put a Statement the treasury owns up for a 24h SCREDIT auction.
    function list(uint256 statementId, uint256 reservePoints) external onlyOwner {
        if (statements.ownerOf(statementId) != address(this)) revert NotHeld();
        if (listings[statementId].endsAt != 0) revert AuctionLive();
        uint64 endsAt = uint64(block.timestamp + AUCTION_DURATION);
        listings[statementId] = Listing(address(0), 0, reservePoints, endsAt);
        emit Listed(statementId, reservePoints, endsAt);
    }

    /// @notice The lowest bid (in points) that would be accepted now.
    function minBid(uint256 statementId) public view returns (uint256) {
        Listing storage l = listings[statementId];
        if (l.highBidder == address(0)) return l.reserve == 0 ? 1 : l.reserve;
        uint256 step = (l.highBid * MIN_BID_INCREMENT_BPS) / 10_000;
        return l.highBid + (step == 0 ? 1 : step);
    }

    /// @notice Bid points on a listed Statement, paying the $0.25 bid fee in ETH (excess refunded).
    ///         Your points are held while you lead; if you're outbid they come straight back.
    function bid(uint256 statementId, uint256 points) external payable nonReentrant {
        Listing storage l = listings[statementId];
        if (l.endsAt == 0) revert NotListed();
        if (block.timestamp >= l.endsAt) revert AuctionOver();
        uint256 fee = bidFee();
        if (msg.value < fee) revert InsufficientFee();
        if (points < minBid(statementId)) revert BidTooLow();

        if (l.highBidder != address(0)) _move(address(this), l.highBidder, l.highBid); // return outbid points
        if (balanceOf[msg.sender] < points) revert InsufficientPoints();
        _move(msg.sender, address(this), points); // escrow in the store while leading
        l.highBidder = msg.sender;
        l.highBid = points;
        if (l.endsAt - block.timestamp < AUCTION_EXTENSION) l.endsAt = uint64(block.timestamp + AUCTION_EXTENSION);
        bidFees += fee;
        emit StoreBid(statementId, msg.sender, points, fee, l.endsAt);

        if (msg.value > fee) _send(msg.sender, msg.value - fee);
    }

    /// @notice Close a store auction: the winner gets the Statement and their points are burned.
    ///         No bids: the listing closes and the Statement stays in the treasury.
    function settle(uint256 statementId) external nonReentrant {
        Listing memory l = listings[statementId];
        if (l.endsAt == 0) revert NotListed();
        if (block.timestamp < l.endsAt) revert AuctionLive();
        delete listings[statementId];
        if (l.highBidder == address(0)) {
            emit StoreSettled(statementId, address(0), 0);
            return;
        }
        balanceOf[address(this)] -= l.highBid; // burn the winner's escrowed points
        totalSupply -= l.highBid;
        emit Transfer(address(this), address(0), l.highBid);
        statements.transferFrom(address(this), l.highBidder, statementId);
        emit StoreSettled(statementId, l.highBidder, l.highBid);
    }

    /// @notice Send accumulated bid fees to the platform (the pool's fee recipient). Anyone can call.
    ///         If the fee wallet won't take it, the fees simply stay here as bidFees (never treasury).
    function sweepBidFees() external nonReentrant {
        uint256 amt = bidFees;
        if (amt == 0) return;
        address to = pool.feeRecipient();
        bidFees = 0; // effects first: treasuryBalance() stays exact even during the call
        bool paid;
        // Same as the pool's sweep: bounded gas, no returndata copy.
        uint256 gasForRecipient = FEE_CALL_GAS;
        assembly ("memory-safe") { paid := call(gasForRecipient, to, amt, 0, 0, 0, 0) }
        if (!paid) {
            bidFees = amt; // held for a later sweep
            emit BidFeesHeld(to, amt);
            return;
        }
        emit BidFeesSwept(to, amt);
    }

    function _move(address from, address to, uint256 amt) internal {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
    }

    function _send(address to, uint256 amt) internal {
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }
}
