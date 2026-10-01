// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IStatementAssembler} from "./IStatementAssembler.sol";
import {AssemblyVault} from "./AssemblyVault.sol";
import {ICreditStore, AggregatorV3Interface} from "./CreditPool.sol";

/// @title credit.pool: backed auctions (sell first, burn second)
/// @notice Holders pool Credits into 80-slot batches. **Nothing burns until a sale is locked in.**
///         A full batch needs a backer (ETH for the whole batch, any amount) before its auction can
///         start; the best backing is the opening bid of a 24h English auction. If the auction ends
///         at or above the depositors' majority minimum it sells; if below, depositors have 24h to
///         accept the best bid by majority (more than 40 of 80 slots), otherwise everyone is
///         refunded and nothing burns. A sale burns the 80 Credits into a Statement, delivers it to
///         the buyer and books the proceeds for depositors, all in one all-or-nothing step.
///         See docs/SELL-FIRST-DESIGN.md (invariants I1–I10, threat model).
contract BackedPool is IERC721Receiver, ReentrancyGuard, Ownable2Step {
    // ───────────────────────── constants ─────────────────────────
    uint256 public constant CREDITS_PER_STATEMENT = 80;
    uint256 public constant MAJORITY = 41;                   // slots needed: more than half of 80
    uint256 public constant USD = 1e8;
    uint256 public constant FEE_USD_PER_CREDIT = 2;          // $2 per Credit...
    uint256 public constant BULK_FEE_USD_PER_CREDIT = 1;     // ...or $1 each for 6+ in one deposit
    uint256 public constant BULK_MIN_CREDITS = 6;
    uint256 public constant PLATFORM_SHARE_BPS = 2500;       // 25% of deposit fees; 75% to the store
    uint256 public constant POINTS_PER_CREDIT = 2;           // SCREDIT per burned Credit
    uint256 public constant ORACLE_MAX_AGE = 1 days;
    uint256 public constant MIN_ETH_USD = 10;
    uint256 public constant MAX_ETH_USD = 10_000_000;
    uint256 public constant FEE_CALL_GAS = 100_000;
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant AUCTION_EXTENSION = 15 minutes;
    uint256 public constant MIN_BID_INCREMENT_BPS = 500;     // 5%
    uint256 public constant DECIDE_WINDOW = 24 hours;        // accept window after an auction below the minimum
    uint256 public constant MIN_BACKING = 80;                // wei: 1 wei per slot, so no share rounds to 0
    uint256 public constant MAX_BACKERS = 10;                // per batch; a new backer must beat the lowest
    /// @dev Gas handed to the all-or-nothing finalize. A caller can't starve it into an unwind:
    ///      finalize refuses to start without this much available (real assembly ≈ 4.3M + award ≈ 2.4M).
    uint256 public constant FINALIZE_GAS = 12_000_000;

    // ───────────────────────── immutables ─────────────────────────
    IERC721 public immutable credits;
    IERC721 public immutable statements;
    IStatementAssembler public immutable assembler;
    AggregatorV3Interface public immutable ethUsdFeed;
    uint256 public immutable assemblyOpensAt;
    uint8 private immutable _feedDecimals;
    uint256 public immutable fallbackFeeWei;
    AssemblyVault public immutable vault;
    ICreditStore public immutable store;

    // ───────────────────────── state ─────────────────────────
    enum BatchState { Filling, Full, Auction, Decide, Sold }

    struct Batch {
        BatchState state;
        uint64 nonce;          // bumps on every change to the Credit set: stale backings can't open an auction
        uint64 round;          // bumps on every auction start: acceptances bind to a round
        uint256 statementId;
        uint256 proceeds;
        uint256[] creditIds;
        address[] depositors;
    }
    struct Auction {
        address highBidder;
        uint256 highBid;
        uint256 minimum;       // majority minimum at start; 0 = no quorum then (never sells automatically)
        uint64 endsAt;         // auction end, or accept-window end while in Decide
    }
    struct Backing {
        uint256 amount;
        uint64 nonce;          // the composition it was posted for
    }
    struct CreditInfo {
        address depositor;
        uint64 batch;
        uint32 idx;
    }

    uint256 public openBatchId;
    uint256 public accruedFees;
    uint256 public platformFeesOwed;
    address public feeRecipient;

    mapping(uint256 => Batch) internal _batches;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => uint256)) public slots;
    mapping(uint256 => mapping(address => uint256)) internal _depositorIdx; // 1-based
    mapping(uint256 => mapping(address => uint256)) public reservePref;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(uint256 => CreditInfo) internal _credit;
    mapping(uint256 => bool) public statementAssigned;
    mapping(address => uint256) public pendingReturns;
    mapping(uint256 => mapping(address => Backing)) public backings;
    mapping(uint256 => address[]) internal _backers;
    mapping(uint256 => mapping(uint64 => uint256)) public acceptTally;            // batch => round => slots
    mapping(uint256 => mapping(uint64 => mapping(address => bool))) public accepted;

    // ───────────────────────── events ─────────────────────────
    event Deposited(address indexed who, uint256 indexed batchId, uint256 creditId);
    event Withdrawn(address indexed who, uint256 indexed batchId, uint256 creditId);
    event BatchFull(uint256 indexed batchId);
    event BatchReopened(uint256 indexed batchId);
    event ReserveSet(uint256 indexed batchId, address indexed who, uint256 reserve);
    event Backed(uint256 indexed batchId, address indexed backer, uint256 total);
    event BackingWithdrawn(uint256 indexed batchId, address indexed backer, uint256 amount);
    event BackingEvicted(uint256 indexed batchId, address indexed backer, uint256 amount);
    event AuctionStarted(uint256 indexed batchId, uint64 round, address backer, uint256 opening, uint256 minimum, uint256 endsAt);
    event Bid(uint256 indexed batchId, address indexed bidder, uint256 amount, uint256 endsAt);
    event DecideOpened(uint256 indexed batchId, uint64 round, uint256 highBid, uint256 endsAt);
    event Accepted(uint256 indexed batchId, uint64 round, address indexed who, uint256 slots, uint256 tally);
    event Expired(uint256 indexed batchId, uint64 round, address bidder, uint256 refunded);
    event Sold(uint256 indexed batchId, address indexed buyer, uint256 price, uint256 statementId);
    event Unwound(uint256 indexed batchId, address indexed buyer, uint256 refunded);
    event Redeemed(uint256 indexed batchId, address indexed who, uint256 statementId);
    event Claimed(uint256 indexed batchId, address indexed who, uint256 amount);
    event RefundWithdrawn(address indexed who, uint256 amount);
    event FeesSwept(address indexed to, uint256 amount, address indexed treasury, uint256 treasuryAmount);
    event PlatformFeesHeld(address indexed recipient, uint256 amount);
    event FeeRecipientSet(address indexed recipient);

    error WrongBatchState();
    error NotDepositor();
    error InsufficientFee();
    error StaleOracle();
    error BidTooLow();
    error AuctionLive();
    error NothingToClaim();
    error TransferFailed();
    error UnexpectedToken();
    error StatementNotReceived();
    error CreditsNotBurned();
    error BatchMoved();
    error ZeroAddress();
    error RenounceDisabled();
    error NotAContract();
    error BadConfig();
    error NotBacked();
    error BackingTooLow();
    error BackingChanged();
    error BidChanged();
    error NotYet();
    error OnlySelf();
    error NeedMoreGas();
    error TooMany();
    error StoreNotLinked();

    constructor(
        address credits_,
        address statements_,
        address assembler_,
        address ethUsdFeed_,
        uint256 assemblyOpensAt_,
        address feeRecipient_,
        address store_
    ) Ownable(msg.sender) {
        if (credits_.code.length == 0 || statements_.code.length == 0 || assembler_.code.length == 0
                || ethUsdFeed_.code.length == 0 || store_.code.length == 0) revert NotAContract();
        if (credits_ == statements_ || credits_ == assembler_ || credits_ == ethUsdFeed_ || credits_ == store_
                || statements_ == ethUsdFeed_ || statements_ == store_ || ethUsdFeed_ == store_
                || assemblyOpensAt_ > block.timestamp + 365 days) revert BadConfig();
        credits = IERC721(credits_);
        statements = IERC721(statements_);
        assembler = IStatementAssembler(assembler_);
        ethUsdFeed = AggregatorV3Interface(ethUsdFeed_);
        _feedDecimals = AggregatorV3Interface(ethUsdFeed_).decimals();
        uint256 atDeploy = _liveFee();
        if (atDeploy == 0) revert StaleOracle();
        fallbackFeeWei = atDeploy;
        assemblyOpensAt = assemblyOpensAt_;
        if (feeRecipient_ == address(0) || feeRecipient_ == store_ || feeRecipient_ == address(this)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        vault = new AssemblyVault(credits, statements, assembler);
        store = ICreditStore(store_);
    }

    // ───────────────────────── fee (unchanged from CreditPool) ─────────────────────────

    function usdWei() public view returns (uint256) {
        uint256 live = _liveFee();
        return live == 0 ? fallbackFeeWei : live;
    }

    function depositFeeFor(uint256 n) public view returns (uint256) {
        return usdWei() * n * (n >= BULK_MIN_CREDITS ? BULK_FEE_USD_PER_CREDIT : FEE_USD_PER_CREDIT);
    }

    function feeUsesFallback() external view returns (bool) {
        return _liveFee() == 0;
    }

    function _liveFee() internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            address(ethUsdFeed).staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (!ok || ret.length < 160) return 0;
        (, int256 price,, uint256 updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (price <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > ORACLE_MAX_AGE) return 0;
        uint256 unit = 10 ** _feedDecimals;
        if (uint256(price) < MIN_ETH_USD * unit || uint256(price) > MAX_ETH_USD * unit) return 0;
        return (USD * 10 ** _feedDecimals * 1e18) / (uint256(price) * 1e8);
    }

    // ───────────────────────── deposit / withdraw ─────────────────────────

    /// @notice Deposit into the open batch; overflow spills into the next. Fee: depositFeeFor(count).
    function deposit(uint256[] calldata creditIds) external payable nonReentrant {
        _takeFee(creditIds.length);
        for (uint256 i; i < creditIds.length; ++i) _add(openBatchId, creditIds[i]);
    }

    /// @notice Like deposit, but reverts if the open batch moved since the caller looked.
    function depositAt(uint256[] calldata creditIds, uint256 expectedBatch, uint256 expectedFilled)
        external
        payable
        nonReentrant
    {
        if (openBatchId != expectedBatch || _batches[expectedBatch].creditIds.length != expectedFilled) revert BatchMoved();
        _takeFee(creditIds.length);
        for (uint256 i; i < creditIds.length; ++i) _add(openBatchId, creditIds[i]);
    }

    /// @notice Refill one specific batch that reopened (someone withdrew from it while it was
    ///         Full). Never spills: reverts if the Credits don't fit.
    function depositInto(uint256 b, uint256[] calldata creditIds, uint256 expectedFilled) external payable nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Filling || b > openBatchId) revert WrongBatchState();
        if (batch.creditIds.length != expectedFilled) revert BatchMoved();
        if (expectedFilled + creditIds.length > CREDITS_PER_STATEMENT) revert TooMany();
        _takeFee(creditIds.length);
        for (uint256 i; i < creditIds.length; ++i) _add(b, creditIds[i]);
    }

    function _takeFee(uint256 n) internal {
        require(n > 0, "empty");
        uint256 fee = depositFeeFor(n);
        if (msg.value < fee) revert InsufficientFee();
        accruedFees += fee;
        if (msg.value > fee) pendingReturns[msg.sender] += msg.value - fee; // excess, pulled later
    }

    function _add(uint256 b, uint256 id) internal {
        Batch storage batch = _batches[b];
        // forge-lint: disable-next-line(unsafe-typecast)
        _credit[id] = CreditInfo(msg.sender, uint64(b), uint32(batch.creditIds.length));
        batch.creditIds.push(id);
        batch.nonce++;
        if (slots[b][msg.sender]++ == 0) {
            batch.depositors.push(msg.sender);
            _depositorIdx[b][msg.sender] = batch.depositors.length;
        }
        emit Deposited(msg.sender, b, id);
        credits.transferFrom(msg.sender, address(this), id); // interaction last; a revert undoes the bookkeeping
        if (batch.creditIds.length == CREDITS_PER_STATEMENT) {
            batch.state = BatchState.Full;
            emit BatchFull(b);
            if (b == openBatchId) openBatchId = b + 1;
        }
    }

    /// @notice Take Credits back: any time while the batch fills, and from a Full batch as long as
    ///         no auction or accept window is running (the batch reopens; backings for the old
    ///         composition can't open an auction any more). Deposit fees aren't refunded.
    function withdraw(uint256[] calldata creditIds) external nonReentrant {
        for (uint256 i; i < creditIds.length; ++i) {
            uint256 id = creditIds[i];
            CreditInfo memory info = _credit[id];
            if (info.depositor != msg.sender) revert NotDepositor();
            uint256 b = info.batch;
            Batch storage batch = _batches[b];
            if (batch.state == BatchState.Full) {
                batch.state = BatchState.Filling;
                // Votes were cast for the old set of Credits: clear them all (design §2.8, audit Info-1).
                address[] storage ds = batch.depositors;
                for (uint256 j; j < ds.length; ++j) delete reservePref[b][ds[j]];
                emit BatchReopened(b);
            } else if (batch.state != BatchState.Filling) {
                revert WrongBatchState();
            }
            uint32 idx = info.idx;
            uint256 last = batch.creditIds[batch.creditIds.length - 1];
            batch.creditIds[idx] = last;
            _credit[last].idx = idx;
            batch.creditIds.pop();
            batch.nonce++;
            delete _credit[id];
            if (--slots[b][msg.sender] == 0) _removeDepositor(b, msg.sender);
            credits.transferFrom(address(this), msg.sender, id);
            emit Withdrawn(msg.sender, b, id);
        }
    }

    // ───────────────────────── votes ─────────────────────────

    /// @notice The lowest price you'd accept for the whole batch. 0 clears your vote.
    function setReserve(uint256 b, uint256 reserveWei) external nonReentrant {
        if (slots[b][msg.sender] == 0) revert NotDepositor();
        if (_batches[b].state == BatchState.Sold) revert WrongBatchState();
        reservePref[b][msg.sender] = reserveWei;
        emit ReserveSet(b, msg.sender, reserveWei);
    }

    /// @notice The majority minimum: the lowest price that more than 40 of the 80 slots accept,
    ///         or 0 if fewer than 41 slots have voted (then an auction never sells automatically;
    ///         depositors decide in the accept window).
    function majorityMinimum(uint256 b) public view returns (uint256) {
        address[] storage ds = _batches[b].depositors;
        uint256 n = ds.length;
        uint256[] memory prices = new uint256[](n);
        uint256[] memory weights = new uint256[](n);
        uint256 voters;
        for (uint256 i; i < n; ++i) {
            uint256 p = reservePref[b][ds[i]];
            if (p == 0) continue;
            uint256 w = slots[b][ds[i]];
            uint256 j = voters;
            while (j > 0 && prices[j - 1] > p) { prices[j] = prices[j - 1]; weights[j] = weights[j - 1]; --j; }
            prices[j] = p; weights[j] = w; ++voters;
        }
        uint256 cum;
        for (uint256 k; k < voters; ++k) {
            cum += weights[k];
            if (cum >= MAJORITY) return prices[k];
        }
        return 0;
    }

    // ───────────────────────── backing ─────────────────────────

    /// @notice Back a batch: ETH for the whole batch, held by the contract, in any amount (at least
    ///         80 wei). Adds to your existing backing and re-confirms it for the batch's current
    ///         Credits. Open while the batch fills or is Full and idle. At most MAX_BACKERS per batch:
    ///         when full, a new backer must beat the lowest, who is refunded (pull).
    function back(uint256 b) external payable nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Filling && batch.state != BatchState.Full) revert WrongBatchState();
        if (b > openBatchId) revert WrongBatchState();
        Backing storage mine = backings[b][msg.sender];
        uint256 total = mine.amount + msg.value;
        if (msg.value == 0 || total < MIN_BACKING) revert BackingTooLow();
        if (mine.amount == 0) {
            address[] storage list = _backers[b];
            if (list.length == MAX_BACKERS) {
                // A backing for an older set of Credits can't open an auction, so it never holds a
                // place against a current one (audit M-2): stale ones go first, whatever their size.
                (uint256 lowIdx, uint256 lowAmt, bool stale) = _evictable(b);
                if (!stale && total <= lowAmt) revert BackingTooLow();
                address evicted = list[lowIdx];
                pendingReturns[evicted] += lowAmt;
                delete backings[b][evicted];
                list[lowIdx] = list[list.length - 1];
                list.pop();
                emit BackingEvicted(b, evicted, lowAmt);
            }
            list.push(msg.sender);
        }
        mine.amount = total;
        mine.nonce = batch.nonce;
        emit Backed(b, msg.sender, total);
    }

    /// @notice Take your backing back (to your refunds). Always possible for a backing that isn't
    ///         the committed opening bid; the opening bid is committed once the auction starts.
    function withdrawBacking(uint256 b) external nonReentrant {
        uint256 amt = backings[b][msg.sender].amount;
        if (amt == 0) revert NothingToClaim();
        _dropBacker(b, msg.sender);
        pendingReturns[msg.sender] += amt;
        emit BackingWithdrawn(b, msg.sender, amt);
    }

    /// @notice The highest backing that is valid for the batch's current Credits (0 if none).
    function bestBacking(uint256 b) public view returns (address who, uint256 amount) {
        uint64 nonce = _batches[b].nonce;
        address[] storage list = _backers[b];
        for (uint256 i; i < list.length; ++i) {
            Backing storage bk = backings[b][list[i]];
            if (bk.nonce == nonce && bk.amount > amount) (who, amount) = (list[i], bk.amount);
        }
    }

    function backersOf(uint256 b) external view returns (address[] memory who, uint256[] memory amount, bool[] memory current) {
        address[] storage list = _backers[b];
        who = new address[](list.length); amount = new uint256[](list.length); current = new bool[](list.length);
        for (uint256 i; i < list.length; ++i) {
            Backing storage bk = backings[b][list[i]];
            (who[i], amount[i], current[i]) = (list[i], bk.amount, bk.nonce == _batches[b].nonce);
        }
    }

    // ───────────────────────── auction ─────────────────────────

    /// @notice Start the 24h auction of a Full, backed batch. The best backing becomes the opening
    ///         bid (committed); the depositors' majority minimum is fixed for this round. The opening
    ///         bid must be at least what the caller saw. A higher one only helps depositors, so it
    ///         doesn't revert, and a 1-wei top-up can't be used to block starts (audit L-1). The
    ///         minimum is the depositors' own vote, so it isn't pinned by the caller.
    function startAuction(uint256 b, uint256 minOpening) external nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Full) revert WrongBatchState();
        if (block.timestamp < assemblyOpensAt) revert NotYet();
        _requireLinked();
        (address backer, uint256 opening) = bestBacking(b);
        if (opening == 0) revert NotBacked();
        if (opening < minOpening) revert BackingChanged();
        uint256 minimum = majorityMinimum(b);
        _dropBacker(b, backer); // its ETH is now the committed opening bid
        batch.state = BatchState.Auction;
        batch.round++;
        uint64 endsAt = uint64(block.timestamp + AUCTION_DURATION);
        auctions[b] = Auction(backer, opening, minimum, endsAt);
        emit AuctionStarted(b, batch.round, backer, opening, minimum, endsAt);
    }

    /// @notice The lowest bid accepted now: 5% over the high bid, at least 1 wei more.
    function minNextBid(uint256 b) public view returns (uint256) {
        uint256 hb = auctions[b].highBid;
        uint256 step = (hb * MIN_BID_INCREMENT_BPS) / 10_000;
        return hb + (step == 0 ? 1 : step);
    }

    function bid(uint256 b) external payable nonReentrant {
        if (_batches[b].state != BatchState.Auction) revert WrongBatchState();
        Auction storage a = auctions[b];
        if (block.timestamp >= a.endsAt) revert WrongBatchState();
        if (msg.value < minNextBid(b)) revert BidTooLow();
        pendingReturns[a.highBidder] += a.highBid; // the previous high bid (incl. the backer's) is refunded
        a.highBidder = msg.sender;
        a.highBid = msg.value;
        if (a.endsAt - block.timestamp < AUCTION_EXTENSION) a.endsAt = uint64(block.timestamp + AUCTION_EXTENSION);
        emit Bid(b, msg.sender, msg.value, a.endsAt);
    }

    /// @notice After the auction ends: sells if the high bid meets the majority minimum, otherwise
    ///         opens the 24h accept window. Anyone can call.
    function settle(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        Auction storage a = auctions[b];
        if (batch.state != BatchState.Auction) revert WrongBatchState();
        if (block.timestamp < a.endsAt) revert AuctionLive();
        if (a.minimum != 0 && a.highBid >= a.minimum) {
            _finalizeOrUnwind(b);
        } else {
            batch.state = BatchState.Decide;
            a.endsAt = uint64(block.timestamp + DECIDE_WINDOW);
            emit DecideOpened(b, batch.round, a.highBid, a.endsAt);
        }
    }

    /// @notice Depositors accept the best bid, naming the exact round, bidder and amount. When more
    ///         than 40 of 80 slots accept, it sells in the same transaction.
    function acceptBid(uint256 b, uint64 round, address bidder, uint256 amount) external nonReentrant {
        Batch storage batch = _batches[b];
        Auction storage a = auctions[b];
        if (batch.state != BatchState.Decide || block.timestamp >= a.endsAt) revert WrongBatchState();
        if (round != batch.round || bidder != a.highBidder || amount != a.highBid) revert BidChanged();
        uint256 s = slots[b][msg.sender];
        if (s == 0) revert NotDepositor();
        if (accepted[b][round][msg.sender]) revert WrongBatchState();
        accepted[b][round][msg.sender] = true;
        uint256 tally = acceptTally[b][round] + s;
        acceptTally[b][round] = tally;
        emit Accepted(b, round, msg.sender, s, tally);
        if (tally >= MAJORITY) _finalizeOrUnwind(b);
    }

    /// @notice After an accept window passes without a majority: the bidder is refunded, nothing
    ///         burns, and the batch is Full again (new backings, votes and rounds possible).
    function expire(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        Auction memory a = auctions[b];
        if (batch.state != BatchState.Decide || block.timestamp < a.endsAt) revert WrongBatchState();
        batch.state = BatchState.Full;
        delete auctions[b];
        pendingReturns[a.highBidder] += a.highBid;
        emit Expired(b, batch.round, a.highBidder, a.highBid);
    }

    /// @notice A sole 80-slot holder can burn their batch into a Statement for themselves, no sale.
    function redeem(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Full) revert WrongBatchState();
        if (slots[b][msg.sender] != CREDITS_PER_STATEMENT) revert NotDepositor();
        if (block.timestamp < assemblyOpensAt) revert NotYet();
        _requireLinked();
        uint256 sid = _burnTo(b, msg.sender, 0);
        emit Redeemed(b, msg.sender, sid);
    }

    // ───────────────────────── finalize: all or nothing ─────────────────────────

    /// @dev Runs the whole sale as an external self-call with a fixed gas budget. If anything in it
    ///      reverts (the Statements contract refuses, the cap is reached, a check fails), every
    ///      effect of the attempt is undone, including moving the Credits to the vault, and the buyer
    ///      is refunded: the batch is Full again, Credits unburned. A caller can't force this by
    ///      starving gas: it refuses to start with less than FINALIZE_GAS available.
    function _finalizeOrUnwind(uint256 b) internal {
        Auction memory a = auctions[b];
        if (gasleft() < FINALIZE_GAS + FINALIZE_GAS / 63 + 50_000) revert NeedMoreGas();
        try this.finalizeSale{gas: FINALIZE_GAS}(b, a.highBidder, a.highBid) {
            // sold
        } catch {
            _batches[b].state = BatchState.Full;
            delete auctions[b];
            pendingReturns[a.highBidder] += a.highBid;
            emit Unwound(b, a.highBidder, a.highBid);
        }
    }

    /// @notice Internal step of the sale, callable only by this contract (see _finalizeOrUnwind).
    function finalizeSale(uint256 b, address buyer, uint256 price) external {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 sid = _burnTo(b, buyer, price);
        delete auctions[b];
        emit Sold(b, buyer, price, sid);
    }

    /// @dev Burn the batch's 80 Credits through the vault, check exactly one new Statement arrived and
    ///      nothing else moved, deliver it, book proceeds, award points.
    function _burnTo(uint256 b, address to, uint256 price) internal returns (uint256 sid) {
        Batch storage batch = _batches[b];
        uint256 heldStatements = statements.balanceOf(address(this));
        uint256 heldCredits = credits.balanceOf(address(this));
        uint256[] storage ids = batch.creditIds;
        for (uint256 i; i < ids.length; ++i) {
            delete _credit[ids[i]];
            credits.transferFrom(address(this), address(vault), ids[i]);
        }
        sid = vault.assemble(ids);
        if (statements.balanceOf(address(this)) != heldStatements + 1 || statements.ownerOf(sid) != address(this)
                || statementAssigned[sid]) revert StatementNotReceived();
        if (credits.balanceOf(address(this)) != heldCredits - CREDITS_PER_STATEMENT) revert CreditsNotBurned();
        statementAssigned[sid] = true;
        batch.statementId = sid;
        batch.proceeds = price;
        batch.state = BatchState.Sold;
        _awardPoints(b);
        statements.transferFrom(address(this), to, sid); // plain transfer: a buyer can't block delivery
    }

    // ───────────────────────── payouts ─────────────────────────

    function claim(uint256 b) external nonReentrant {
        Batch storage batch = _batches[b];
        if (batch.state != BatchState.Sold) revert WrongBatchState();
        uint256 s = slots[b][msg.sender];
        if (s == 0 || claimed[b][msg.sender]) revert NothingToClaim();
        claimed[b][msg.sender] = true;
        uint256 amt = (batch.proceeds * s) / CREDITS_PER_STATEMENT;
        _send(msg.sender, amt);
        emit Claimed(b, msg.sender, amt);
    }

    /// @notice Everything returned to you: outbid bids, withdrawn or evicted backings, expired and
    ///         unwound sales, and excess deposit fees.
    function withdrawRefund() external nonReentrant {
        uint256 amt = pendingReturns[msg.sender];
        if (amt == 0) revert NothingToClaim();
        pendingReturns[msg.sender] = 0;
        _send(msg.sender, amt);
        emit RefundWithdrawn(msg.sender, amt);
    }

    // ───────────────────────── fees (unchanged from CreditPool) ─────────────────────────

    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0) || r == address(store) || r == address(this) || r == address(vault)) revert ZeroAddress();
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

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
        returns (BatchState state, uint256 filled, uint256 depositorCount, uint256 statementId, uint256 proceeds, uint64 round, uint64 nonce)
    {
        Batch storage x = _batches[b];
        return (x.state, x.creditIds.length, x.depositors.length, x.statementId, x.proceeds, x.round, x.nonce);
    }
    function batchCredits(uint256 b) external view returns (uint256[] memory) { return _batches[b].creditIds; }
    function batchDepositors(uint256 b) external view returns (address[] memory) { return _batches[b].depositors; }
    function depositorOf(uint256 id) external view returns (address) { return _credit[id].depositor; }
    function batchOf(uint256 id) external view returns (uint256) { return _credit[id].batch; }

    // ───────────────────────── internals ─────────────────────────

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert UnexpectedToken();
    }

    function _awardPoints(uint256 b) internal {
        address[] storage ds = _batches[b].depositors;
        uint256[] memory pts = new uint256[](ds.length);
        for (uint256 i; i < ds.length; ++i) pts[i] = slots[b][ds[i]] * POINTS_PER_CREDIT;
        store.award(ds, pts);
    }

    /// @dev The backing a newcomer displaces: the smallest stale one if any, else the smallest current one.
    function _evictable(uint256 b) internal view returns (uint256 idx, uint256 amt, bool stale) {
        address[] storage list = _backers[b];
        uint64 nonce = _batches[b].nonce;
        amt = type(uint256).max;
        for (uint256 i; i < list.length; ++i) {
            Backing storage bk = backings[b][list[i]];
            bool s = bk.nonce != nonce;
            if ((s && !stale) || (s == stale && bk.amount < amt)) (idx, amt, stale) = (i, bk.amount, s);
        }
    }

    /// @dev The store must award points to THIS pool, or every sale would unwind (audit L-2).
    function _requireLinked() internal view {
        (bool ok, bytes memory ret) = address(store).staticcall(abi.encodeWithSignature("pool()"));
        if (!ok || ret.length < 32 || abi.decode(ret, (address)) != address(this)) revert StoreNotLinked();
    }

    function _dropBacker(uint256 b, address who) internal {
        address[] storage list = _backers[b];
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == who) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        delete backings[b][who];
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
