// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IStatementAssembler} from "./IStatementAssembler.sol";
import {AssemblyVault} from "./AssemblyVault.sol";

/// @notice The store: SCREDIT points, the treasury, and the SCREDIT-only store auction.
interface ICreditStore {
    function award(address[] calldata to, uint256[] calldata points) external;
}

/// @notice Chainlink price feed (ETH/USD, 8 decimals on mainnet).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title credit.pool
/// @notice Holders deposit Credits (not ETH) into sequential 80-slot batches. A full batch is
///         burned into one Statement. The Statement is either redeemed by a sole owner of all
///         80 slots or sold by on-chain English auction, with proceeds split pro-rata by slots.
///         Deposit fee: $2 (in ETH) per Credit, or $1 per Credit when depositing 6 or more at
///         once. 25% of it goes to the platform and 75% to the store's treasury. When a batch
///         is burned into a Statement, each depositor earns 2 SCREDIT points per Credit in it. Auction sales carry no fee: depositors get 100%.
contract CreditPool is IERC721Receiver, ReentrancyGuard, Ownable2Step {
    // ───────────────────────── constants ─────────────────────────
    uint256 public constant CREDITS_PER_STATEMENT = 80;
    uint256 public constant USD = 1e8;                      // $1.00 at 8 decimals
    uint256 public constant FEE_USD_PER_CREDIT = 2;         // $2 per Credit...
    uint256 public constant BULK_FEE_USD_PER_CREDIT = 1;    // ...or $1 per Credit for a deposit of
    uint256 public constant BULK_MIN_CREDITS = 6;           // at least this many in one transaction
    uint256 public constant PLATFORM_SHARE_BPS = 2500;      // 25% of deposit fees; 75% to the treasury
    uint256 public constant POINTS_PER_CREDIT = 2;          // SCREDIT per Credit, awarded when its batch is assembled
    // Chainlink ETH/USD heartbeat is 1h, so a 1h limit bricks deposits at every heartbeat edge.
    // The fee is $1-2; a day-old price is off by cents. This only guards against a dead feed.
    uint256 public constant ORACLE_MAX_AGE = 1 days;
    // A price outside this range means a broken feed: use the fallback instead of pricing off it.
    uint256 public constant MIN_ETH_USD = 10;
    uint256 public constant FEE_CALL_GAS = 100_000;          // gas given to feeRecipient when paying it
    uint256 public constant MAX_ETH_USD = 10_000_000;
    uint256 public constant ESCAPE_DELAY = 14 days;         // full-but-unassembled escape hatch
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant AUCTION_EXTENSION = 15 minutes; // anti-snipe window
    uint256 public constant MIN_BID_INCREMENT_BPS = 500;    // 5%
    uint256 public constant NO_RESERVE_AFTER = 30 days;     // unsold this long after assembly → reserve-free auction

    // ───────────────────────── immutables ─────────────────────────
    IERC721 public immutable credits;
    IERC721 public immutable statements;
    IStatementAssembler public immutable assembler;
    AggregatorV3Interface public immutable ethUsdFeed;
    uint256 public immutable assemblyOpensAt;
    /// @dev Feed decimals, read once at deploy (external audit #1, L-02).
    uint8 private immutable _feedDecimals;
    /// @notice Per-Credit fee used whenever the price feed can't be trusted (stale, future-dated,
    ///         non-positive, or not answering), so deposits never stop because of the feed
    ///         (external audit #1, M-01). Frozen at deploy as $1 in ETH at that moment; nobody
    ///         can change it.
    uint256 public immutable fallbackFeeWei;
    /// @notice The only address ever approved to the assembler; holds one batch for one call.
    AssemblyVault public immutable vault;
    /// @notice Receives SCREDIT awards and the treasury's share of fees.
    ICreditStore public immutable store;

    // ───────────────────────── state ─────────────────────────
    enum BatchState { Filling, Full, Assembled, Auction, Settled, Redeemed, Dissolved }

    struct Batch {
        BatchState state;
        uint64 fullAt;
        uint64 assembledAt;
        uint256 statementId;
        uint256 proceeds;      // sale price (no sale fee)
        uint256[] creditIds;   // live list while Filling (swap-and-pop on withdraw)
        address[] depositors;  // unique depositors (swap-and-pop when slots hit 0)
    }

    struct Auction {
        address highBidder;
        uint256 highBid;
        uint256 reserve;
        uint64 endsAt;
    }

    uint256 public openBatchId;
    uint256 public accruedFees;
    uint256 public platformFeesOwed; // the platform's share, held when feeRecipient won't accept ETH
    address public feeRecipient;

    mapping(uint256 => Batch) internal _batches;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => uint256)) public slots;          // batch => depositor => credits
    mapping(uint256 => mapping(address => uint256)) internal _depositorIdx; // 1-based
    mapping(uint256 => mapping(address => uint256)) public reservePref;     // batch => depositor => wei
    mapping(uint256 => mapping(address => bool)) public claimed;
    // One slot per Credit (saves two cold SSTOREs per deposit vs. separate mappings).
    struct CreditInfo {
        address depositor;
        uint64 batch;
        uint32 idx; // index in batch.creditIds
    }
    mapping(uint256 => CreditInfo) internal _credit;
    mapping(uint256 => bool) public statementAssigned;                      // statementId => already backs a batch
    mapping(address => uint256) public pendingReturns;                      // outbid refunds
    mapping(uint256 => uint256) public unsoldAuctions;                      // batch => auctions that ended with no bids
    mapping(uint256 => bool) public openedByFallback;                       // batch => current/last auction opened by the 30-day fallback


    // ───────────────────────── events ─────────────────────────
    event Deposited(address indexed who, uint256 indexed batchId, uint256 creditId);
    event Withdrawn(address indexed who, uint256 indexed batchId, uint256 creditId);
    event BatchFull(uint256 indexed batchId);
    event Assembled(uint256 indexed batchId, uint256 statementId);
    event ReserveSet(uint256 indexed batchId, address indexed who, uint256 reserve);
    event AuctionStarted(uint256 indexed batchId, uint256 reserve, uint256 endsAt);
    event Bid(uint256 indexed batchId, address indexed bidder, uint256 amount, uint256 endsAt);
    event Settled(uint256 indexed batchId, address winner, uint256 amount);
    event Redeemed(uint256 indexed batchId, address indexed who);
    event Claimed(uint256 indexed batchId, address indexed who, uint256 amount);
    event Dissolved(uint256 indexed batchId);
    event RefundWithdrawn(address indexed who, uint256 amount);
    event FeesSwept(address indexed to, uint256 amount, address indexed treasury, uint256 treasuryAmount);
    event FeeRecipientSet(address indexed recipient);
    event PlatformFeesHeld(address indexed recipient, uint256 amount);

    error WrongBatchState();
    error NotDepositor();
    error InsufficientFee();
    error StaleOracle();
    error ReserveQuorumNotMet();
    error BidTooLow();
    error AuctionLive();
    error NothingToClaim();
    error TransferFailed();
    error UnexpectedToken();
    error StatementNotReceived();
    error CreditsNotBurned();
    error BatchMoved();
    error ZeroAddress();
    error ReserveChanged();
    error RenounceDisabled();
    error NotAContract();
    error BadConfig();

    constructor(
        address credits_,
        address statements_,
        address assembler_,
        address ethUsdFeed_,
        uint256 assemblyOpensAt_,
        address feeRecipient_,
        address store_
    ) Ownable(msg.sender) {
        // Dependencies must be contracts (external audit #1, L-04); Deploy.s.sol checks more.
        if (credits_.code.length == 0 || statements_.code.length == 0 || assembler_.code.length == 0 || ethUsdFeed_.code.length == 0
                || store_.code.length == 0) {
            revert NotAContract();
        }
        // Mis-wiring guards in the contract itself, not only in the deploy script (external audit #2):
        // distinct dependencies, and an opening time that can't be milliseconds-for-seconds.
        if (credits_ == statements_ || credits_ == assembler_ || credits_ == ethUsdFeed_ || credits_ == store_
                || statements_ == ethUsdFeed_ || statements_ == store_ || ethUsdFeed_ == store_
                || assemblyOpensAt_ > block.timestamp + 365 days) revert BadConfig();
        credits = IERC721(credits_);
        statements = IERC721(statements_);
        assembler = IStatementAssembler(assembler_);
        ethUsdFeed = AggregatorV3Interface(ethUsdFeed_);
        _feedDecimals = AggregatorV3Interface(ethUsdFeed_).decimals();
        uint256 atDeploy = _liveFee();
        if (atDeploy == 0) revert StaleOracle(); // the feed must be healthy at deploy to set the fallback
        fallbackFeeWei = atDeploy;
        assemblyOpensAt = assemblyOpensAt_;
        if (feeRecipient_ == address(0) || feeRecipient_ == store_ || feeRecipient_ == address(this)) revert ZeroAddress(); // must be able to take ETH
        feeRecipient = feeRecipient_;
        vault = new AssemblyVault(credits, statements, assembler);
        store = ICreditStore(store_);
    }

    // ───────────────────────── fee ─────────────────────────

    /// @notice $1 in wei at the current price (fallbackFeeWei if the feed can't be trusted).
    function usdWei() public view returns (uint256) {
        uint256 live = _liveFee();
        return live == 0 ? fallbackFeeWei : live;
    }

    /// @notice Total fee in wei for depositing n Credits in one transaction: $2 each, or $1 each
    ///         for 6 or more. Frontends should send a small buffer; excess is refunded.
    function depositFeeFor(uint256 n) public view returns (uint256) {
        return usdWei() * n * (n >= BULK_MIN_CREDITS ? BULK_FEE_USD_PER_CREDIT : FEE_USD_PER_CREDIT);
    }

    /// @notice True while the price feed can't be trusted and fees use `fallbackFeeWei` per $1.
    function feeUsesFallback() external view returns (bool) {
        return _liveFee() == 0;
    }

    /// @dev $1 in wei at the feed's current price, or 0 if the feed can't be trusted right now:
    ///      it reverts, reports a non-positive price, is older than ORACLE_MAX_AGE, or is dated in
    ///      the future (external audit #1, L-03). Never reverts.
    function _liveFee() internal view returns (uint256) {
        // Low-level call: a reverting feed OR one returning short/malformed data both mean
        // "untrusted" (a try/catch can't catch a failed decode; external audit #2, L).
        (bool ok, bytes memory ret) =
            address(ethUsdFeed).staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (!ok || ret.length < 160) return 0;
        (, int256 price,, uint256 updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (price <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > ORACLE_MAX_AGE) return 0;
        uint256 unit = 10 ** _feedDecimals;
        if (uint256(price) < MIN_ETH_USD * unit || uint256(price) > MAX_ETH_USD * unit) return 0;
        // $1 / (ETH/USD)  →  wei
        return (USD * 10 ** _feedDecimals * 1e18) / (uint256(price) * 1e8);
    }

    // ───────────────────────── deposit / withdraw ─────────────────────────

    /// @notice Deposit Credits. Caller must setApprovalForAll(pool). Credits overflow into
    ///         the next batch automatically. Fee: depositFeeFor(count).
    function deposit(uint256[] calldata creditIds) external payable nonReentrant {
        _deposit(creditIds);
    }

    /// @notice Same as deposit, but reverts if the open batch moved since the caller looked
    ///         (someone deposited first). Like slippage protection: a depositor who planned to
    ///         fill a fresh batch alone can't be split across two by a front-run.
    function depositAt(uint256[] calldata creditIds, uint256 expectedBatch, uint256 expectedFilled)
        external
        payable
        nonReentrant
    {
        if (openBatchId != expectedBatch || _batches[expectedBatch].creditIds.length != expectedFilled) revert BatchMoved();
        _deposit(creditIds);
    }

    function _deposit(uint256[] calldata creditIds) internal {
        require(creditIds.length > 0, "empty");
        uint256 fee = depositFeeFor(creditIds.length);
        if (msg.value < fee) revert InsufficientFee();
        accruedFees += fee;

        for (uint256 i; i < creditIds.length; ++i) {
            uint256 id = creditIds[i];
            uint256 b = openBatchId;
            Batch storage batch = _batches[b];

            // forge-lint: disable-next-line(unsafe-typecast)
            _credit[id] = CreditInfo(msg.sender, uint64(b), uint32(batch.creditIds.length));
            batch.creditIds.push(id);
            if (slots[b][msg.sender]++ == 0) {
                batch.depositors.push(msg.sender);
                _depositorIdx[b][msg.sender] = batch.depositors.length;
            }
            emit Deposited(msg.sender, b, id);
            // Effects above, interaction last (checks-effects-interactions). Reverts undo the bookkeeping.
            credits.transferFrom(msg.sender, address(this), id);

            if (batch.creditIds.length == CREDITS_PER_STATEMENT) {
                batch.state = BatchState.Full;
                batch.fullAt = uint64(block.timestamp);
                emit BatchFull(b);
                openBatchId = b + 1;
            }
        }

        if (msg.value > fee) _send(msg.sender, msg.value - fee);
    }

    /// @notice Withdraw Credits from the open (unfilled) batch, or from a batch that hit the
    ///         escape hatch. Deposit fees are not refunded.
    function withdraw(uint256[] calldata creditIds) external nonReentrant {
        for (uint256 i; i < creditIds.length; ++i) {
            uint256 id = creditIds[i];
            CreditInfo memory info = _credit[id];
            if (info.depositor != msg.sender) revert NotDepositor();
            uint256 b = info.batch;
            Batch storage batch = _batches[b];

            if (batch.state == BatchState.Full && escapeOpen(b)) {
                batch.state = BatchState.Dissolved;
                emit Dissolved(b);
            }

            if (batch.state == BatchState.Filling) {
                uint32 idx = info.idx;
                uint256 last = batch.creditIds[batch.creditIds.length - 1];
                batch.creditIds[idx] = last;
                _credit[last].idx = idx;
                batch.creditIds.pop();
            } else if (batch.state != BatchState.Dissolved) {
                revert WrongBatchState();
            }

            delete _credit[id];
            if (--slots[b][msg.sender] == 0) _removeDepositor(b, msg.sender);

            credits.transferFrom(address(this), msg.sender, id);
            emit Withdrawn(msg.sender, b, id);
        }
    }

    /// @notice A full batch that couldn't be assembled (contract blocked, cap reached, etc.)
    ///         becomes withdrawable ESCAPE_DELAY after it filled or assembly opened, whichever is later.
    function escapeOpen(uint256 b) public view returns (bool) {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Full) return false;
        uint256 start = batch.fullAt > assemblyOpensAt ? batch.fullAt : assemblyOpensAt;
        return block.timestamp > start + ESCAPE_DELAY;
    }

    // ───────────────────────── assembly ─────────────────────────

    /// @notice Permissionless: anyone can trigger the burn once a batch is full. Still allowed
    ///         after the escape hatch opens, until someone actually withdraws (which moves the
    ///         batch to Dissolved), so one depositor can't veto a batch nobody got around to assembling.
    function assemble(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Full) revert WrongBatchState();

        // Custody: the pool never approves the assembler. It hands exactly this batch's 80
        // Credits to the vault, which is the only thing the assembler can touch (see AssemblyVault).
        uint256 heldStatements = statements.balanceOf(address(this));
        uint256 heldCredits = credits.balanceOf(address(this));
        uint256[] storage ids = batch.creditIds;
        for (uint256 i = 0; i < ids.length; ++i) {
            delete _credit[ids[i]]; // about to be burned: drop stale depositor/batch (external audit #1, I-05)
            credits.transferFrom(address(this), address(vault), ids[i]);
        }
        uint256 sid = vault.assemble(ids);

        // Exactly one NEW Statement arrived, and no other batch already owns it.
        if (
            statements.balanceOf(address(this)) != heldStatements + 1 || statements.ownerOf(sid) != address(this)
                || statementAssigned[sid]
        ) revert StatementNotReceived();
        // The pool's other Credits are exactly as they were.
        if (credits.balanceOf(address(this)) != heldCredits - CREDITS_PER_STATEMENT) revert CreditsNotBurned();

        statementAssigned[sid] = true;
        batch.statementId = sid;
        batch.state = BatchState.Assembled;
        batch.assembledAt = uint64(block.timestamp);
        emit Assembled(b, sid);
        // Points only for Credits actually burned into a Statement: nothing for batches that are
        // withdrawn or dissolved, so deposit/withdraw and escape-hatch cycles can't farm them.
        _awardPoints(b);
    }

    // ───────────────────────── settlement ─────────────────────────

    /// @notice If one address holds all 80 slots, it can take the Statement directly.
    function redeem(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Assembled) revert WrongBatchState();
        if (slots[b][msg.sender] != CREDITS_PER_STATEMENT) revert NotDepositor();
        batch.state = BatchState.Redeemed;
        statements.transferFrom(address(this), msg.sender, batch.statementId);
        emit Redeemed(b, msg.sender);
    }

    /// @notice Each depositor states the lowest price they'd accept. 0 clears the vote.
    function setReserve(uint256 b, uint256 reserveWei) external nonReentrant {
        if (slots[b][msg.sender] == 0) revert NotDepositor();
        BatchState s = _batches[b].state;
        if (s == BatchState.Settled || s == BatchState.Redeemed || s == BatchState.Dissolved) revert WrongBatchState();
        reservePref[b][msg.sender] = reserveWei;
        emit ReserveSet(b, msg.sender, reserveWei);
    }

    /// @notice Start the auction once voters holding >50% of all 80 slots accept a price.
    ///         Reserve = the lowest price that more than 40 of the 80 slots have voted at or
    ///         below. Non-voters count as "not yet", so a minority can't drag the price down by
    ///         voting low the moment quorum is crossed. If the Statement is still unsold
    ///         NO_RESERVE_AFTER assembly, quorum stops being required and the minimum becomes the
    ///         LOWEST vote cast (0 if nobody voted), so a majority can't hold the minority hostage
    ///         with an unreachable price, yet a unanimous price is still respected.
    function startAuction(uint256 b) external nonReentrant {
        _startAuction(b);
    }

    /// @notice Same as startAuction, but reverts if the minimum differs from what the caller
    ///         saw (votes changed, or the 30-day fallback kicked in, since the page loaded).
    function startAuctionAt(uint256 b, uint256 expectedReserve) external nonReentrant {
        if (auctionReserve(b) != expectedReserve) revert ReserveChanged();
        _startAuction(b);
    }

    /// @notice The minimum an auction started now would use.
    function auctionReserve(uint256 b) public view returns (uint256) {
        return noReserveOpen(b) ? lowestVote(b) : currentReserve(b);
    }

    /// @notice Lowest non-zero reserve vote among a batch's depositors, or 0 if none.
    function lowestVote(uint256 b) public view returns (uint256 low) {
        address[] storage ds = _batches[b].depositors;
        for (uint256 i = 0; i < ds.length; ++i) {
            uint256 p = reservePref[b][ds[i]];
            if (p != 0 && (low == 0 || p < low)) low = p;
        }
    }

    function _startAuction(uint256 b) internal {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Assembled) revert WrongBatchState();
        // A sole 80-slot holder decides alone: they can redeem, or auction it themselves, but no
        // one else can push their Statement into a sale (external audit #1, H-02; extends CP-12).
        if (batch.depositors.length == 1 && msg.sender != batch.depositors[0]) revert NotDepositor();
        bool fallbackOpen = noReserveOpen(b); // recorded now: anti-snipe extensions move endsAt later
        uint256 reserve = fallbackOpen ? lowestVote(b) : currentReserve(b);
        openedByFallback[b] = fallbackOpen;
        batch.state = BatchState.Auction;
        uint64 endsAt = uint64(block.timestamp + AUCTION_DURATION);
        auctions[b] = Auction(address(0), 0, reserve, endsAt);
        emit AuctionStarted(b, reserve, endsAt);
    }

    function noReserveOpen(uint256 b) public view returns (bool) {
        Batch storage batch = _batches[b];
        // A sole holder can always redeem; nobody else should be able to force a sale on them.
        if (batch.depositors.length == 1) return false;
        return batch.state == BatchState.Assembled && block.timestamp >= batch.assembledAt + NO_RESERVE_AFTER;
    }

    function currentReserve(uint256 b) public view returns (uint256) {
        (uint256[] memory prices, uint256[] memory weights, uint256 voters,) = _sortedVotes(b);
        // Walk up from the lowest vote: the reserve is the first price at which more than half
        // of ALL 80 slots are in. Votes above it don't lower it; missing votes can't be faked.
        uint256 cum = 0;
        for (uint256 k = 0; k < voters; ++k) {
            cum += weights[k];
            if (cum * 2 > CREDITS_PER_STATEMENT) return prices[k];
        }
        revert ReserveQuorumNotMet();
    }

    /// @notice The slot-weighted median of the votes actually CAST (non-voters excluded).
    ///         Equals `currentReserve` when turnout is high; differs when abstentions let one
    ///         small voter's ask become the quorum price (external audit #2, H). The store's
    ///         treasury only pays a price where the two agree.
    function votedMedian(uint256 b) public view returns (uint256) {
        (uint256[] memory prices, uint256[] memory weights, uint256 voters, uint256 votedSlots) = _sortedVotes(b);
        uint256 cum = 0;
        for (uint256 k = 0; k < voters; ++k) {
            cum += weights[k];
            if (cum * 2 > votedSlots) return prices[k];
        }
        revert ReserveQuorumNotMet(); // nobody voted
    }

    /// @dev Cast votes sorted by price (insertion sort, at most 80 depositors), with slot weights.
    function _sortedVotes(uint256 b)
        internal
        view
        returns (uint256[] memory prices, uint256[] memory weights, uint256 voters, uint256 votedSlots)
    {
        address[] storage ds = _batches[b].depositors;
        uint256 n = ds.length;
        prices = new uint256[](n);
        weights = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 p = reservePref[b][ds[i]];
            if (p == 0) continue;
            uint256 w = slots[b][ds[i]];
            uint256 j = voters;
            while (j > 0 && prices[j - 1] > p) {
                prices[j] = prices[j - 1];
                weights[j] = weights[j - 1];
                --j;
            }
            prices[j] = p;
            weights[j] = w;
            ++voters;
            votedSlots += w;
        }
    }

    function bid(uint256 b) external payable nonReentrant {
        if (_batches[b].state != BatchState.Auction) revert WrongBatchState();
        Auction storage a = auctions[b];
        if (block.timestamp >= a.endsAt) revert WrongBatchState();
        uint256 minBid = a.reserve;
        // At least 1 wei per slot, so no depositor's share can round to zero (external audit #2).
        if (minBid < CREDITS_PER_STATEMENT) minBid = CREDITS_PER_STATEMENT;
        if (a.highBidder != address(0)) {
            uint256 step = (a.highBid * MIN_BID_INCREMENT_BPS) / 10_000;
            minBid = a.highBid + (step == 0 ? 1 : step); // tiny bids still have to go up
        }
        if (msg.value < minBid || msg.value == 0) revert BidTooLow();

        if (a.highBidder != address(0)) pendingReturns[a.highBidder] += a.highBid;
        a.highBidder = msg.sender;
        a.highBid = msg.value;
        if (a.endsAt - block.timestamp < AUCTION_EXTENSION) {
            // forge-lint: disable-next-line(unsafe-typecast)
            a.endsAt = uint64(block.timestamp + AUCTION_EXTENSION);
        }
        emit Bid(b, msg.sender, msg.value, a.endsAt);
    }

    /// @notice Close the auction. No bids → back to Assembled so depositors can re-vote.
    function settle(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        Auction storage a = auctions[b];
        if (batch.state != BatchState.Auction) revert WrongBatchState();
        if (block.timestamp < a.endsAt) revert AuctionLive();

        if (a.highBidder == address(0)) {
            batch.state = BatchState.Assembled;
            delete auctions[b];
            unsoldAuctions[b] += 1; // lets the store's treasury step in as buyer of last resort
            emit Settled(b, address(0), 0);
            return;
        }
        batch.state = BatchState.Settled;
        batch.proceeds = a.highBid; // no sale fee: depositors get it all
        statements.transferFrom(address(this), a.highBidder, batch.statementId);
        emit Settled(b, a.highBidder, a.highBid);
    }

    function claim(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Settled) revert WrongBatchState();
        uint256 s = slots[b][msg.sender];
        if (s == 0 || claimed[b][msg.sender]) revert NothingToClaim();
        claimed[b][msg.sender] = true;
        uint256 amt = (batch.proceeds * s) / CREDITS_PER_STATEMENT;
        _send(msg.sender, amt);
        emit Claimed(b, msg.sender, amt);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amt = pendingReturns[msg.sender];
        if (amt == 0) revert NothingToClaim();
        pendingReturns[msg.sender] = 0;
        _send(msg.sender, amt);
        emit RefundWithdrawn(msg.sender, amt);
    }

    // ───────────────────────── platform fee ─────────────────────────

    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0) || r == address(store) || r == address(this) || r == address(vault)) revert ZeroAddress(); // must be able to take ETH
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    /// @dev Renouncing would freeze setFeeRecipient forever. Ownership moves only via the
    ///      two-step transferOwnership / acceptOwnership.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Split accrued deposit fees: 25% to the platform, 75% to the store's treasury.
    ///         The treasury's share always goes out. If feeRecipient rejects ETH, the platform's
    ///         share is held in platformFeesOwed and paid on a later sweep, so a misconfigured
    ///         fee wallet never holds up the treasury.
    function sweepFees() external nonReentrant {
        uint256 amt = accruedFees;
        accruedFees = 0;
        uint256 share = (amt * PLATFORM_SHARE_BPS) / 10_000;
        uint256 treasury = amt - share;
        uint256 platform = share + platformFeesOwed;
        platformFeesOwed = 0;
        if (treasury != 0) _send(address(store), treasury);
        bool paid = true;
        if (platform != 0) {
            address r = feeRecipient;
            // Bounded gas and no returndata copy: a recipient that burns gas or reverts with a huge
            // payload can't starve the rest of the sweep (the treasury's share stays paid).
            assembly ("memory-safe") { paid := call(FEE_CALL_GAS, r, platform, 0, 0, 0, 0) }
            if (!paid) {
                platformFeesOwed = platform;
                emit PlatformFeesHeld(r, platform);
            }
        }
        emit FeesSwept(feeRecipient, paid ? platform : 0, address(store), treasury);
    }

    // ───────────────────────── views ─────────────────────────

    function batchInfo(uint256 b)
        external
        view
        returns (BatchState state, uint256 filled, uint256 depositorCount, uint256 statementId, uint256 proceeds, uint64 fullAt)
    {
        Batch storage x = _batches[b];
        return (x.state, x.creditIds.length, x.depositors.length, x.statementId, x.proceeds, x.fullAt);
    }

    function batchCredits(uint256 b) external view returns (uint256[] memory) { return _batches[b].creditIds; }
    function depositorOf(uint256 id) external view returns (address) { return _credit[id].depositor; }
    function batchOf(uint256 id) external view returns (uint256) { return _credit[id].batch; }
    function assembledAt(uint256 b) external view returns (uint64) { return _batches[b].assembledAt; }
    function batchDepositors(uint256 b) external view returns (address[] memory) { return _batches[b].depositors; }

    // ───────────────────────── internals ─────────────────────────

    /// @dev The pool accepts no safe transfers at all: deposits use transferFrom, and the
    ///      Statement arrives from the vault by transferFrom. Anything sent with safeTransferFrom
    ///      (stray Credits, random NFTs) bounces instead of getting stuck.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert UnexpectedToken();
    }

    /// @dev One call to the (trusted, deploy-time) store with every depositor of the batch just assembled.
    function _awardPoints(uint256 b) internal {
        address[] storage ds = _batches[b].depositors;
        uint256[] memory pts = new uint256[](ds.length);
        for (uint256 i; i < ds.length; ++i) pts[i] = slots[b][ds[i]] * POINTS_PER_CREDIT;
        store.award(ds, pts);
    }

    function _removeDepositor(uint256 b, address who) internal {
        address[] storage ds = _batches[b].depositors;
        uint256 idx = _depositorIdx[b][who] - 1;
        address last = ds[ds.length - 1];
        ds[idx] = last;
        _depositorIdx[b][last] = idx + 1;
        ds.pop();
        delete _depositorIdx[b][who];
        delete reservePref[b][who];
    }

    function _send(address to, uint256 amt) internal {
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }
}
