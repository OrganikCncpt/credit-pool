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
    function majorityMinimum(uint256 b) external view returns (uint256);
    function sellToStore(uint256 b) external payable;
    function withdrawRefund() external;
    function pendingReturns(address who) external view returns (uint256);
}

/// @title credit.pool store for BackedPool (backed auctions)
/// @notice Three things, all funded by the pool's deposit fees:
///         1. SCREDIT ("Store Credit"): non-transferable points. When a batch is burned into a
///            Statement, the pool awards each depositor 2 per Credit in it. They can't be sent, sold or approved;
///            they can only be bid here.
///         2. The treasury: 75% of every deposit fee. Its only outflow is buyUnsold: an
///            owner-triggered purchase of a batch whose last auction round ended unsold (no bid at
///            the price, holders didn't accept the backer), at exactly the depositors' majority price
///            (which must also be the median of the votes cast), capped per purchase by
///            maxTreasuryBid. It never backs batches.
///            TRUST: the owner decides which unsold batches to buy, within that cap. Raising the cap
///            takes CAP_RAISE_DELAY to apply, so depositors can see it coming.
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
    uint256 internal _maxTreasuryBid; // cap on what buyUnsold may pay for one Statement
    uint256 public pendingMaxTreasuryBid;
    uint64 public pendingMaxTreasuryBidAt;
    mapping(uint256 statementId => Listing) public listings;

    event Transfer(address indexed from, address indexed to, uint256 value); // ERC-20 shape, mint/burn only
    event PoolSet(address pool);
    event MaxTreasuryBidSet(uint256 amount);
    event MaxTreasuryBidRaiseScheduled(uint256 amount, uint64 effectiveAt);
    event TreasuryBought(uint256 indexed batchId, uint256 price);
    event Listed(uint256 indexed statementId, uint256 reserve, uint64 endsAt);
    event StoreBid(uint256 indexed statementId, address indexed bidder, uint256 points, uint256 fee, uint64 endsAt);
    event StoreSettled(uint256 indexed statementId, address winner, uint256 points);
    event BidFeesSwept(address indexed to, uint256 amount);
    event BidFeesHeld(address indexed to, uint256 amount);

    error NonTransferable();
    error NotPool();
    error PoolAlreadySet();
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

    /// @notice Buy an unsold batch at exactly the depositors' majority price. `expectedPrice` is the
    ///         price the owner reviewed: if votes moved since, it reverts instead of paying something
    ///         else. The pool checks the rest (last round unsold, nothing changed since, not a sole
    ///         holder's batch, price = median of cast votes). The Statement comes here, ready to list.
    function buyUnsold(uint256 b, uint256 expectedPrice) external onlyOwner nonReentrant {
        uint256 price = pool.majorityMinimum(b);
        if (price == 0 || price != expectedPrice) revert PriceMoved();
        if (price > maxTreasuryBid() || price > treasuryBalance()) revert OverCap();
        pool.sellToStore{value: price}(b);
        emit TreasuryBought(b, price);
    }

    /// @notice Pull everything the pool owes the treasury (a purchase that unwound) back into it. Anyone can call.
    function collectRefund() external nonReentrant {
        if (pool.pendingReturns(address(this)) != 0) pool.withdrawRefund();
    }

    /// @dev ETH arrives only from the pool: its fee sweep and refunds of unwound purchases.
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
