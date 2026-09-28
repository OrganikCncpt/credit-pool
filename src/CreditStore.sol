// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ICreditPool {
    function usdWei() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function statements() external view returns (IERC721);
    function unsoldAuctions(uint256 b) external view returns (uint256);
    function auctions(uint256 b) external view returns (address highBidder, uint256 highBid, uint256 reserve, uint64 endsAt);
    function batchInfo(uint256 b)
        external
        view
        returns (uint8 state, uint256 filled, uint256 depositorCount, uint256 statementId, uint256 proceeds, uint64 fullAt);
    function startAuction(uint256 b) external;
    function bid(uint256 b) external payable;
    function withdrawRefund() external;
}

/// @title credit.pool store
/// @notice Three things, all funded by the pool's deposit fees:
///         1. SCREDIT ("Store Credit"): non-transferable points. The pool awards 1 per Credit
///            deposited. They can't be sent, sold or approved; they can only be bid here.
///         2. The treasury: 75% of every deposit fee. It is spent only on buying Statements
///            that failed to sell (see buyUnsold); no function sends it anywhere else.
///         3. The store auction: Statements the treasury bought are auctioned for SCREDIT only.
///            Every bid also pays a $0.25 platform fee in ETH. Outbid points come back; the
///            winner's points are burned. These Statements never go back into the pool.
contract CreditStore is ReentrancyGuard, Ownable2Step {
    // ───────────────────────── SCREDIT (points) ─────────────────────────
    string public constant name = "Store Credit";
    string public constant symbol = "SCREDIT";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;                    // includes points escrowed in live bids
    mapping(address => uint256) public balanceOf;  // spendable points

    // ───────────────────────── store auction ─────────────────────────
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

    ICreditPool public pool;
    IERC721 public statements;
    uint256 public bidFees;         // ETH owed to the platform; everything else held is treasury
    uint256 public maxTreasuryBid;  // owner-set cap on what buyUnsold may pay for one Statement
    mapping(uint256 statementId => Listing) public listings;

    event Transfer(address indexed from, address indexed to, uint256 value); // ERC-20 shape, mint/burn only
    event PoolSet(address pool);
    event MaxTreasuryBidSet(uint256 amount);
    event TreasuryBid(uint256 indexed batchId, uint256 amount);
    event Listed(uint256 indexed statementId, uint256 reserve, uint64 endsAt);
    event StoreBid(uint256 indexed statementId, address indexed bidder, uint256 points, uint256 fee, uint64 endsAt);
    event StoreSettled(uint256 indexed statementId, address winner, uint256 points);
    event BidFeesSwept(address indexed to, uint256 amount);

    error NonTransferable();
    error NotPool();
    error PoolAlreadySet();
    error NotUnsold();
    error AlreadyBid();
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

    constructor() Ownable(msg.sender) {}

    /// @notice One-time link to the pool (the pool is deployed after the store and knows it).
    function setPool(address pool_) external onlyOwner {
        if (address(pool) != address(0)) revert PoolAlreadySet();
        pool = ICreditPool(pool_);
        statements = ICreditPool(pool_).statements();
        emit PoolSet(pool_);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ───────────────────────── points ─────────────────────────

    /// @notice Called by the pool on every deposit: 1 point per Credit.
    function award(address to, uint256 points) external {
        if (msg.sender != address(pool)) revert NotPool();
        balanceOf[to] += points;
        totalSupply += points;
        emit Transfer(address(0), to, points);
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

    function setMaxTreasuryBid(uint256 amount) external onlyOwner {
        maxTreasuryBid = amount;
        emit MaxTreasuryBidSet(amount);
    }

    /// @notice Buyer of last resort. Only for a batch whose auction already ended with no bids:
    ///         (re)starts its auction if needed and places the opening bid at exactly the
    ///         depositors' own minimum (1 wei if there is none), capped by maxTreasuryBid.
    ///         Anyone can still outbid the treasury for 24 hours; if they do, the refund comes
    ///         back here via collectRefund.
    function buyUnsold(uint256 b) external onlyOwner nonReentrant {
        if (pool.unsoldAuctions(b) == 0) revert NotUnsold();
        (uint8 state,,,,,) = pool.batchInfo(b);
        if (state == 2) pool.startAuction(b); // Assembled → Auction (sole-holder batches revert here)
        (address high,, uint256 reserve,) = pool.auctions(b);
        if (high != address(0)) revert AlreadyBid();
        uint256 amount = reserve == 0 ? 1 : reserve;
        if (amount > maxTreasuryBid || amount > treasuryBalance()) revert OverCap();
        pool.bid{value: amount}(b);
        emit TreasuryBid(b, amount);
    }

    /// @notice Pull the treasury's outbid refunds back from the pool. Anyone can call.
    function collectRefund() external nonReentrant {
        pool.withdrawRefund();
    }

    /// @dev ETH arrives only from the pool: its fee sweep and outbid refunds.
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

        if (l.highBidder != address(0)) balanceOf[l.highBidder] += l.highBid; // return outbid points
        if (balanceOf[msg.sender] < points) revert InsufficientPoints();
        balanceOf[msg.sender] -= points;
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
        totalSupply -= l.highBid;
        emit Transfer(l.highBidder, address(0), l.highBid);
        statements.transferFrom(address(this), l.highBidder, statementId);
        emit StoreSettled(statementId, l.highBidder, l.highBid);
    }

    /// @notice Send accumulated bid fees to the platform (the pool's fee recipient). Anyone can call.
    function sweepBidFees() external nonReentrant {
        uint256 amt = bidFees;
        bidFees = 0;
        address to = pool.feeRecipient();
        _send(to, amt);
        emit BidFeesSwept(to, amt);
    }

    function _send(address to, uint256 amt) internal {
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }
}
