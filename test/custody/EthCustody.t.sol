// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {deployPool} from "../DeployPool.sol";
import {MockCredits, MockStatements, MockFeed} from "../Mocks.sol";

/*
 * ETH custody attack suite for CreditPool.
 *
 * ETH IN :  deposit() msg.value (fee kept -> accruedFees, excess refunded in the same call)
 *           bid()     msg.value (becomes auctions[b].highBid)
 *           (forced ETH via selfdestruct; no receive()/fallback, so plain sends revert)
 * ETH OUT:  deposit()        _send(msg.sender, msg.value - fee)
 *           withdrawRefund() _send(msg.sender, pendingReturns[msg.sender])
 *           claim()          _send(msg.sender, proceeds * slots / 80)
 *           sweepFees()      _send(feeRecipient, accruedFees)
 * OBLIGATIONS: auctions[b].highBid while Auction, pendingReturns[*],
 *              proceeds*slots/80 for each unclaimed depositor of a Settled batch, accruedFees.
 */

/// Contract actor that deposits / bids / claims with its own balance and, on every ETH receipt,
/// tries to re-enter the pool in a configurable way. Records whether the re-entry succeeded.
contract Reenterer {
    enum Mode { None, WithdrawRefund, Claim, Bid, Settle, Deposit, SweepFees, Withdraw, StartAuction, SetReserve }

    CreditPool public pool;
    MockCredits public credits;
    Mode public mode;
    uint256 public target;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public lastErr;
    uint256[] internal reIds;

    constructor(CreditPool p, MockCredits c) {
        pool = p; credits = c;
        c.setApprovalForAll(address(p), true);
    }

    function setMode(Mode m, uint256 t) external { mode = m; target = t; attempted = false; }
    function setReIds(uint256[] calldata ids) external { reIds = ids; }
    function doDeposit(uint256[] calldata ids, uint256 value) external { pool.deposit{value: value}(ids); }
    function doBid(uint256 b, uint256 value) external { pool.bid{value: value}(b); }
    function doClaim(uint256 b) external { pool.claim(b); }
    function doWithdrawRefund() external { pool.withdrawRefund(); }
    function doSetReserve(uint256 b, uint256 r) external { pool.setReserve(b, r); }
    function doSettle(uint256 b) external { pool.settle(b); }

    receive() external payable {
        if (mode == Mode.None || attempted) return;
        attempted = true;
        bool ok; bytes memory err;
        address p = address(pool);
        if (mode == Mode.WithdrawRefund) (ok, err) = p.call(abi.encodeCall(CreditPool.withdrawRefund, ()));
        else if (mode == Mode.Claim) (ok, err) = p.call(abi.encodeCall(CreditPool.claim, (target)));
        else if (mode == Mode.Bid) (ok, err) = p.call{value: msg.value}(abi.encodeCall(CreditPool.bid, (target)));
        else if (mode == Mode.Settle) (ok, err) = p.call(abi.encodeCall(CreditPool.settle, (target)));
        else if (mode == Mode.Deposit) (ok, err) = p.call{value: msg.value}(abi.encodeCall(CreditPool.deposit, (reIds)));
        else if (mode == Mode.SweepFees) (ok, err) = p.call(abi.encodeCall(CreditPool.sweepFees, ()));
        else if (mode == Mode.Withdraw) (ok, err) = p.call(abi.encodeCall(CreditPool.withdraw, (reIds)));
        else if (mode == Mode.StartAuction) (ok, err) = p.call(abi.encodeCall(CreditPool.startAuction, (target)));
        else if (mode == Mode.SetReserve) (ok, err) = p.call(abi.encodeCall(CreditPool.setReserve, (target, 1)));
        reentrySucceeded = ok;
        lastErr = err;
    }
}

/// High bidder whose receive() reverts unless unlocked.
contract RevertBidder {
    CreditPool public pool;
    bool public accept;
    constructor(CreditPool p) { pool = p; }
    function setAccept(bool a) external { accept = a; }
    function doBid(uint256 b, uint256 value) external { pool.bid{value: value}(b); }
    function doWithdrawRefund() external { pool.withdrawRefund(); }
    receive() external payable { require(accept, "no eth"); }
}

/// Fee recipient that reverts with ~3 MB of revert data.
contract ReturnBomb {
    receive() external payable { assembly { revert(0, 3000000) } }
}

/// Fee recipient that always reverts.
contract RevertingTreasury {
    receive() external payable { revert("nope"); }
}

/// Forces ETH into a contract with no receive().
contract ForceSend {
    constructor(address payable to) payable { selfdestruct(to); }
}

// ═══════════════════════════════════════════════════════════════════════════
//                              UNIT ATTACKS
// ═══════════════════════════════════════════════════════════════════════════
contract EthCustodyUnitTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address carol = makeAddr("carol");
    address b1 = makeAddr("b1"); address b2 = makeAddr("b2"); address eve = makeAddr("eve");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        feed = new MockFeed(2500e8);
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, treasury);
        address[6] memory us = [alice, bob, carol, b1, b2, eve];
        for (uint256 i; i < 6; ++i) {
            vm.deal(us[i], 100 ether);
            vm.prank(us[i]); credits.setApprovalForAll(address(pool), true);
        }
    }

    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _deposit(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = pool.depositFeeFor(ids.length);
        vm.prank(who); pool.deposit{value: fee}(ids);
    }
    /// alice 40 / bob 30 / carol 10 → assembled, reserve voted 1 ether, auction started.
    function _auction() internal returns (uint256 b) {
        b = pool.openBatchId();
        _deposit(alice, 40); _deposit(bob, 30); _deposit(carol, 10);
        pool.assemble(b);
        vm.prank(alice); pool.setReserve(b, 1 ether);
        vm.prank(bob); pool.setReserve(b, 1 ether);
        pool.startAuction(b);
    }
    function _obligations(uint256 maxB, address[] memory who) internal view returns (uint256 o) {
        o = pool.accruedFees();
        for (uint256 b; b <= maxB; ++b) {
            (CreditPool.BatchState s,,,, uint256 proceeds,) = pool.batchInfo(b);
            if (s == CreditPool.BatchState.Auction) { (, uint256 hb,,) = pool.auctions(b); o += hb; }
            if (s == CreditPool.BatchState.Settled) {
                for (uint256 i; i < who.length; ++i) {
                    if (!pool.claimed(b, who[i])) o += proceeds * pool.slots(b, who[i]) / 80;
                }
            }
        }
        for (uint256 i; i < who.length; ++i) o += pool.pendingReturns(who[i]);
    }

    // ── take someone else's bid / refund ──
    function test_Attack_StealOthersRefund() public {
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.prank(b2); pool.bid{value: 2 ether}(b);
        assertEq(pool.pendingReturns(b1), 1 ether);
        // eve (never bid), b2 (current high bidder) and a depositor all try to pull b1's refund
        vm.prank(eve); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        vm.prank(b2); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        vm.prank(alice); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        uint256 before = b1.balance;
        vm.prank(b1); pool.withdrawRefund();
        assertEq(b1.balance - before, 1 ether);
        assertEq(eve.balance, 100 ether);
    }

    function test_Attack_WithdrawRefundTwice() public {
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.prank(b2); pool.bid{value: 2 ether}(b);
        vm.prank(b1); pool.withdrawRefund();
        vm.prank(b1); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        assertEq(b1.balance, 100 ether);
        assertEq(address(pool).balance, 2 ether + pool.accruedFees());
    }

    // ── the high bidder's live bid cannot be withdrawn (no pendingReturns) and winner gets no refund ──
    function test_Attack_HighBidderCannotPullLiveBidOrWinningBid() public {
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.prank(b1); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        vm.prank(b1); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        assertEq(stmts.ownerOf(1), b1);
    }

    // ── claim: exact share, no double, not in batch, before settle ──
    function test_Attack_ClaimExactShare_NoDouble() public {
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 8 ether}(b);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        (,,,, uint256 proceeds,) = pool.batchInfo(b);
        assertEq(proceeds, 8 ether); // no sale fee
        uint256 a0 = alice.balance;
        vm.prank(alice); pool.claim(b);
        assertEq(alice.balance - a0, proceeds * 40 / 80);
        vm.prank(alice); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.claim(b);
        vm.prank(eve); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.claim(b);
        vm.prank(b1); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.claim(b);   // winner isn't a depositor
        vm.prank(bob); pool.claim(b);
        vm.prank(carol); pool.claim(b);
        // everything paid; only swept-able fees remain
        assertEq(address(pool).balance, pool.accruedFees());
        pool.sweepFees();
        assertEq(address(pool).balance, 0);
    }

    function test_Attack_ClaimBeforeSettle_AllStates() public {
        uint256 b = pool.openBatchId();
        _deposit(alice, 40);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b); // Filling
        _deposit(bob, 30); _deposit(carol, 10);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b); // Full
        pool.assemble(b);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b); // Assembled
        vm.prank(alice); pool.setReserve(b, 1 ether);
        vm.prank(bob); pool.setReserve(b, 1 ether);
        pool.startAuction(b);
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b); // Auction live
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b); // Auction ended, not settled
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b + 5); // nonexistent batch
    }

    // ── a depositor in batch 1 cannot claim batch 0's proceeds ──
    function test_Attack_ClaimOtherBatch() public {
        uint256 b = _auction();
        _deposit(eve, 5); // eve in batch 1 (Filling)
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        vm.prank(eve); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.claim(b);
    }

    // ── settle: before end, twice, pays statement to high bidder only ──
    function test_Attack_SettleEarlyTwiceWrongParty() public {
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.prank(b2); pool.bid{value: 1.05 ether}(b);
        vm.expectRevert(CreditPool.AuctionLive.selector); pool.settle(b);
        vm.warp(block.timestamp + 1 days);
        vm.prank(eve); pool.settle(b); // permissionless; eve gains nothing
        assertEq(stmts.ownerOf(1), b2);
        assertEq(eve.balance, 100 ether);
        vm.expectRevert(CreditPool.WrongBatchState.selector); pool.settle(b);
        assertEq(pool.accruedFees(), pool.usdWei() * 80); // deposit fees only: sales carry no fee
        vm.prank(b1); pool.withdrawRefund();
        assertEq(b1.balance, 100 ether);
    }

    // ── bidding into every non-Auction state ──
    function test_Attack_BidIntoNonAuctionStates() public {
        uint256 b = pool.openBatchId();
        vm.prank(b1); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 1 ether}(b); // Filling
        _deposit(alice, 80);
        vm.prank(b1); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 1 ether}(b); // Full
        pool.assemble(b);
        vm.prank(b1); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 1 ether}(b); // Assembled
        vm.prank(alice); pool.redeem(b);
        vm.prank(b1); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 1 ether}(b); // Redeemed
        // Settled
        uint256 c = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(c);
        vm.warp(block.timestamp + 1 days);
        vm.prank(b2); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 5 ether}(c); // ended
        pool.settle(c);
        vm.prank(b2); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 5 ether}(c); // Settled
        // Dissolved
        uint256 d = pool.openBatchId();
        uint256[] memory ids = _deposit(bob, 80);
        vm.warp(block.timestamp + 15 days);
        uint256[] memory one = new uint256[](1); one[0] = ids[0];
        vm.prank(bob); pool.withdraw(one);
        vm.prank(b1); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 1 ether}(d); // Dissolved
        assertEq(b2.balance, 100 ether);
        assertEq(b1.balance, 99 ether);
    }

    // ── outbid yourself: old bid goes to pendingReturns, fully recoverable ──
    function test_Attack_OutbidSelf() public {
        uint256 b = _auction();
        vm.startPrank(b1);
        pool.bid{value: 1 ether}(b);
        pool.bid{value: 1.05 ether}(b);
        pool.bid{value: 2 ether}(b);
        vm.stopPrank();
        assertEq(pool.pendingReturns(b1), 2.05 ether);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        vm.prank(b1); pool.withdrawRefund();
        assertEq(b1.balance, 98 ether);
        assertEq(stmts.ownerOf(1), b1);
    }

    // ── high bidder that reverts on receive can't freeze anybody else ──
    function test_Attack_RevertingHighBidderCannotFreeze() public {
        uint256 b = _auction();
        RevertBidder rb = new RevertBidder(pool);
        vm.deal(address(rb), 10 ether);
        rb.doBid(b, 1 ether);
        vm.prank(b1); pool.bid{value: 1.05 ether}(b);     // outbidding the reverting bidder works (pull refunds)
        rb.doBid(b, 2 ether);                              // it retakes the lead
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);                                    // statement transferred with transferFrom (no hook)
        assertEq(stmts.ownerOf(1), address(rb));
        vm.prank(b1); pool.withdrawRefund();
        vm.prank(alice); pool.claim(b);
        vm.prank(bob); pool.claim(b);
        vm.prank(carol); pool.claim(b);
        vm.expectRevert(CreditPool.TransferFailed.selector); rb.doWithdrawRefund(); // only its own refund stuck
        assertEq(pool.pendingReturns(address(rb)), 1 ether);
        rb.setAccept(true); rb.doWithdrawRefund();
        assertEq(address(rb).balance, 8 ether); // paid 2 ether winning bid, 1 ether losing bid refunded
        pool.sweepFees();
        assertEq(address(pool).balance, 0);
    }

    // ── reentrancy through every _send path ──
    function _reentryOnRefund(Reenterer.Mode m, uint256 t) internal returns (Reenterer r, uint256 b) {
        b = _auction();
        r = new Reenterer(pool, credits);
        vm.deal(address(r), 10 ether);
        r.doBid(b, 1 ether);
        vm.prank(b1); pool.bid{value: 2 ether}(b);
        r.setMode(m, t == type(uint256).max ? b : t);
        r.doWithdrawRefund();
        assertTrue(r.attempted());
    }
    function _assertGuarded(Reenterer r) internal view {
        assertFalse(r.reentrySucceeded());
        assertEq(bytes4(r.lastErr()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_Reenter_WithdrawRefund_into_WithdrawRefund() public {
        (Reenterer r,) = _reentryOnRefund(Reenterer.Mode.WithdrawRefund, 0);
        _assertGuarded(r);
        assertEq(address(r).balance, 10 ether);
        assertEq(pool.pendingReturns(address(r)), 0);
    }
    function test_Reenter_WithdrawRefund_into_Bid() public {
        (Reenterer r,) = _reentryOnRefund(Reenterer.Mode.Bid, type(uint256).max);
        _assertGuarded(r);
    }
    function test_Reenter_WithdrawRefund_into_Settle() public {
        (Reenterer r,) = _reentryOnRefund(Reenterer.Mode.Settle, type(uint256).max);
        _assertGuarded(r);
    }
    function test_Reenter_WithdrawRefund_into_SweepFees() public {
        (Reenterer r,) = _reentryOnRefund(Reenterer.Mode.SweepFees, 0);
        _assertGuarded(r);
    }
    function test_Reenter_WithdrawRefund_into_Deposit() public {
        Reenterer.Mode m = Reenterer.Mode.Deposit;
        uint256 b = _auction();
        Reenterer r = new Reenterer(pool, credits);
        vm.deal(address(r), 10 ether);
        r.setReIds(_give(address(r), 1));
        r.doBid(b, 1 ether);
        vm.prank(b1); pool.bid{value: 2 ether}(b);
        r.setMode(m, 0);
        r.doWithdrawRefund();
        _assertGuarded(r);
    }

    function test_Reenter_Claim_into_Claim() public {
        uint256 b = pool.openBatchId();
        Reenterer r = new Reenterer(pool, credits);
        vm.deal(address(r), 10 ether);
        r.doDeposit(_give(address(r), 40), 40 * pool.usdWei());
        _deposit(bob, 40);
        pool.assemble(b);
        r.doSetReserve(b, 1 ether); vm.prank(bob); pool.setReserve(b, 1 ether);
        pool.startAuction(b);
        vm.prank(b1); pool.bid{value: 4 ether}(b);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        uint256 before = address(r).balance;
        r.setMode(Reenterer.Mode.Claim, b);
        r.doClaim(b);
        _assertGuarded(r);
        assertEq(address(r).balance - before, 4 ether / 2);
        // and a second top-level claim fails
        r.setMode(Reenterer.Mode.None, 0);
        vm.expectRevert(CreditPool.NothingToClaim.selector); r.doClaim(b);
        vm.prank(bob); pool.claim(b);
        pool.sweepFees();
        assertEq(address(pool).balance, 0);
    }

    function test_Reenter_DepositRefund_into_DepositAndBid() public {
        uint256 b = _auction();
        Reenterer r = new Reenterer(pool, credits);
        vm.deal(address(r), 10 ether);
        r.setReIds(_give(address(r), 1));
        r.setMode(Reenterer.Mode.Deposit, 0);
        r.doDeposit(_give(address(r), 1), 1 ether); // big excess → refund → re-entry attempt
        _assertGuarded(r);
        r.setMode(Reenterer.Mode.Bid, b);
        r.doDeposit(_give(address(r), 1), 1 ether);
        _assertGuarded(r);
        r.setMode(Reenterer.Mode.Withdraw, 0);
        r.doDeposit(_give(address(r), 1), 1 ether);
        _assertGuarded(r);
        // exact refund: spent only 3 deposit fees (3 single-Credit deposits at $2)
        assertEq(address(r).balance, 10 ether - 3 * pool.depositFeeFor(1));
    }

    /// startAuction / setReserve used to be unguarded; both are nonReentrant now. Show re-entering them from a _send
    /// callback moves no ETH (they're permissionless / self-only anyway).
    function test_Reenter_StartAuction_Refused() public {
        uint256 b0 = _auction();
        // batch 1 assembled, reserve voted, not started
        uint256 b1_ = pool.openBatchId();
        Reenterer r = new Reenterer(pool, credits);
        vm.deal(address(r), 10 ether);
        r.doDeposit(_give(address(r), 41), 41 * pool.usdWei());
        _deposit(carol, 39);
        pool.assemble(b1_);
        r.doSetReserve(b1_, 3 ether);
        r.doBid(b0, 1 ether);
        vm.prank(b1); pool.bid{value: 2 ether}(b0);
        uint256 bal = address(pool).balance;
        r.setMode(Reenterer.Mode.StartAuction, b1_);
        r.doWithdrawRefund();
        // startAuction is nonReentrant now: the re-entry is refused, the refund itself still pays out.
        assertFalse(r.reentrySucceeded());
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(b1_);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
        assertEq(address(pool).balance, bal - 1 ether);
    }

    // ── no-reserve path ──
    function test_Attack_NoReservePath() public {
        uint256 b = pool.openBatchId();
        _deposit(alice, 40); _deposit(bob, 30); _deposit(carol, 10);
        pool.assemble(b);
        vm.expectRevert(CreditPool.ReserveQuorumNotMet.selector); pool.startAuction(b);
        vm.warp(block.timestamp + 30 days);
        vm.prank(eve); pool.startAuction(b);
        (, , uint256 reserve,) = pool.auctions(b);
        assertEq(reserve, 0);
        vm.prank(b1); vm.expectRevert(CreditPool.BidTooLow.selector); pool.bid{value: 0}(b);
        // External audit #2: the first bid is at least 1 wei per slot, so no share rounds to 0.
        vm.prank(b1); vm.expectRevert(CreditPool.BidTooLow.selector); pool.bid{value: 79}(b);
        vm.prank(b1); pool.bid{value: 80}(b);
        // FIXED (audit N9): an equal bid never outbids; +5% of 80 = 84
        vm.prank(b2); vm.expectRevert(CreditPool.BidTooLow.selector); pool.bid{value: 80}(b);
        vm.prank(b2); pool.bid{value: 84}(b);
        assertEq(pool.pendingReturns(b1), 80);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        (,,,, uint256 proceeds,) = pool.batchInfo(b);
        assertEq(proceeds, 84);
        vm.prank(alice); pool.claim(b);  // 84*40/80 = 42, bob 31, carol 10
        vm.prank(bob); pool.claim(b);
        vm.prank(carol); pool.claim(b);
        vm.prank(b1); pool.withdrawRefund();
        pool.sweepFees();
        assertEq(address(pool).balance, 1); // 1 wei rounding dust stuck forever — not anyone's loss beyond dust
    }

    // ── re-auction after a no-bid settle; stale auction data cannot be reused ──
    function test_Attack_ReauctionAfterNoBids() public {
        uint256 b = _auction();
        vm.warp(block.timestamp + 1 days);
        pool.settle(b); // no bids → Assembled
        vm.expectRevert(CreditPool.WrongBatchState.selector); pool.claim(b);
        (address hb, uint256 hbid,,) = pool.auctions(b);
        assertEq(hb, address(0)); assertEq(hbid, 0);
        pool.startAuction(b);
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        assertEq(stmts.ownerOf(1), b1);
    }

    // ── sweepFees never touches bids, refunds, or proceeds ──
    function test_Attack_SweepFeesOnlyFees() public {
        uint256 b0 = _auction();
        vm.prank(b1); pool.bid{value: 3 ether}(b0);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b0);                           // unclaimed proceeds
        uint256 bb = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(bb);
        vm.prank(b2); pool.bid{value: 2 ether}(bb); // live bid + pending refund
        address[] memory who = new address[](5);
        who[0] = alice; who[1] = bob; who[2] = carol; who[3] = b1; who[4] = b2;
        uint256 fees = pool.accruedFees();
        vm.prank(eve); pool.sweepFees();
        assertEq(treasury.balance, fees / 4);                                  // 25% platform
        assertEq(address(pool.store()).balance, fees - fees / 4);              // 75% store treasury
        vm.prank(eve); pool.sweepFees();         // second sweep sends 0
        assertEq(treasury.balance, fees / 4);
        assertEq(address(pool).balance, _obligations(pool.openBatchId(), who));
        assertGe(address(pool).balance, 3 ether + 2 ether + 1 ether);
    }

    // ── FINDING (low): feeRecipient == address(0) at construction; anyone can sweep fees into 0x0 ──
    // FIXED (audit N5 / custody finding): a zero fee recipient can no longer be deployed.
    function test_Fixed_ZeroFeeRecipientRejected() public {
        address st = address(pool.store()); // read first: a call here would consume expectRevert
        vm.expectRevert(CreditPool.ZeroAddress.selector);
        new CreditPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, address(0), st);
        vm.expectRevert(CreditPool.ZeroAddress.selector);
        pool.setFeeRecipient(address(0));
    }

    // ── fee recipient that reverts: only fees are frozen, owner can re-point ──
    // Verify2 #1: a fee wallet reverting with a ~3 MB payload can't burn the sweep's gas.
    function test_ReturndataBombCantStallTreasury() public {
        ReturnBomb bomb = new ReturnBomb();
        pool.setFeeRecipient(address(bomb));
        _auction();                                   // accrues deposit fees
        uint256 fees = pool.accruedFees();
        uint256 s0 = address(pool.store()).balance;
        // The hostile wallet burns all gas forwarded to it (as any wallet could); the sweep just
        // needs a normal budget for its own bookkeeping. Before the fix, copying the 3 MB revert
        // payload ran even a 30M-gas sweep out of gas.
        pool.sweepFees{gas: 30_000_000}();
        assertEq(address(pool.store()).balance - s0, fees - fees / 4); // treasury paid
        assertEq(pool.platformFeesOwed(), fees / 4);                     // platform share held
    }

    // A fee wallet that rejects ETH holds back only the platform's own 25%; the store's 75% and
    // every user payment still flow, and the held share pays out once the wallet is fixed.
    function test_Attack_RevertingTreasuryOnlyFreezesFees() public {
        RevertingTreasury rt = new RevertingTreasury();
        pool.setFeeRecipient(address(rt));
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.prank(b2); pool.bid{value: 2 ether}(b);
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        uint256 fees = pool.accruedFees();
        pool.sweepFees();                                            // doesn't revert
        assertEq(address(pool.store()).balance, fees - fees / 4);   // treasury paid
        assertEq(pool.platformFeesOwed(), fees / 4);                // platform share held
        assertEq(pool.accruedFees(), 0);
        pool.sweepFees();                                            // still held, not double-split
        assertEq(pool.platformFeesOwed(), fees / 4);
        assertEq(address(pool.store()).balance, fees - fees / 4);
        vm.prank(b1); pool.withdrawRefund();
        vm.prank(alice); pool.claim(b);
        vm.prank(bob); pool.claim(b);
        vm.prank(carol); pool.claim(b);
        pool.setFeeRecipient(treasury);
        pool.sweepFees();
        assertEq(treasury.balance, fees / 4);                       // held share paid once fixed
        assertEq(pool.platformFeesOwed(), 0);
        assertEq(address(pool).balance, 0);
        // non-owner can't redirect fees
        vm.prank(eve); vm.expectRevert(); pool.setFeeRecipient(eve);
    }

    // ── forced ETH doesn't corrupt accounting (nothing reads address(this).balance) ──
    function test_Attack_ForcedEth() public {
        uint256 b = _auction();
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        vm.deal(eve, 101 ether);
        vm.prank(eve); new ForceSend{value: 1 ether}(payable(address(pool)));
        (bool ok,) = address(pool).call{value: 1}(""); // no receive → reverts
        assertFalse(ok);
        vm.prank(eve); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.withdrawRefund();
        vm.warp(block.timestamp + 1 days);
        pool.settle(b);
        vm.prank(alice); pool.claim(b);
        vm.prank(bob); pool.claim(b);
        vm.prank(carol); pool.claim(b);
        pool.sweepFees();
        assertEq(address(pool).balance, 1 ether); // forced ETH stranded, nobody's loss but eve's
    }

    // ── deposit excess refund is exact; insufficient fee reverts; fee under extreme prices ──
    function test_Attack_DepositFeeAndRefund() public {
        uint256[] memory ids = _give(alice, 3);
        uint256 fee = pool.depositFeeFor(ids.length);
        vm.prank(alice); vm.expectRevert(CreditPool.InsufficientFee.selector); pool.deposit{value: fee - 1}(ids);
        vm.prank(alice); pool.deposit{value: 5 ether}(ids);
        assertEq(alice.balance, 100 ether - fee);
        assertEq(address(pool).balance, fee);
        assertEq(pool.accruedFees(), fee);
        feed.set(type(int128).max, 0);                 // absurd price → fee rounds to 0, still no ETH mismatch
        uint256 f0 = pool.depositFeeFor(1);
        uint256[] memory bobIds = _give(bob, 1);
        vm.prank(bob); pool.deposit{value: 1 ether}(bobIds);
        assertEq(bob.balance, 100 ether - f0);
        assertEq(address(pool).balance, pool.accruedFees());
    }

    // ── anti-snipe extension + no bidding after end ──
    function test_Attack_BidAfterEndAndExtension() public {
        uint256 b = _auction();
        (,,, uint64 endsAt) = pool.auctions(b);
        vm.warp(endsAt - 1);
        vm.prank(b1); pool.bid{value: 1 ether}(b);
        (,,, uint64 e2) = pool.auctions(b);
        assertEq(e2, endsAt - 1 + 15 minutes);
        vm.warp(e2);
        vm.prank(b2); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.bid{value: 5 ether}(b);
        pool.settle(b);
        assertEq(stmts.ownerOf(1), b1);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                              INVARIANT
// ═══════════════════════════════════════════════════════════════════════════
contract EthHandler is Test {
    CreditPool public pool; MockCredits public credits; MockFeed public feed; MockStatements public stmts;
    address public treasury;
    address[] public actors;       // 0..2 EOAs, 3 = Reenterer (depositor+bidder), 4 = RevertBidder (bidder)
    Reenterer public re;
    RevertBidder public rb;
    address public eve;            // thief: never deposits or bids
    uint256 nextId = 1_000_000;
    uint256 public constant INIT = 1_000_000 ether;

    // ghosts
    uint256 public gIn; uint256 public gOut;
    uint256 public gFees; uint256 public gSwept;
    mapping(address => uint256) public gPending; uint256 public gPendingSum;
    mapping(uint256 => uint256) public gLiveBid; uint256 public gLiveBidSum;
    mapping(uint256 => mapping(address => uint256)) public gShare; uint256 public gUnclaimedSum;
    uint256 public gDust;
    mapping(address => uint256) public spent; mapping(address => uint256) public received; mapping(address => uint256) public entitled;
    bool public attackSucceeded; string public attackNote;
    uint256 public nSettledSale; uint256 public nClaims; uint256 public nRefunds; uint256 public nBids;

    constructor(CreditPool p, MockCredits c, MockFeed f, MockStatements s, address t) {
        pool = p; credits = c; feed = f; stmts = s; treasury = t;
        for (uint256 i; i < 3; ++i) {
            address u = address(uint160(0xE7A000 + i));
            actors.push(u);
            vm.deal(u, INIT);
            vm.prank(u); credits.setApprovalForAll(address(pool), true);
        }
        re = new Reenterer(p, c);
        rb = new RevertBidder(p);
        vm.deal(address(re), INIT); vm.deal(address(rb), INIT);
        actors.push(address(re)); actors.push(address(rb));
        eve = address(0xE7E);
        vm.deal(eve, INIT);
    }

    function actorCount() external view returns (uint256) { return actors.length; }
    function _flag(string memory why) internal { attackSucceeded = true; attackNote = why; }

    /// Pick a batch in state `st`, scanning from a random start. Steers the fuzzer to live batches.
    function _pick(uint256 seed, CreditPool.BatchState st) internal view returns (bool, uint256) {
        uint256 n = pool.openBatchId() + 1;
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 b = (start + k) % n;
            (CreditPool.BatchState s,,,,,) = pool.batchInfo(b);
            if (s == st) return (true, b);
        }
        return (false, 0);
    }
    uint256 public nAssembled; uint256 public nStarted;

    function _randReMode(uint256 seed) internal {
        // only nonReentrant targets here, so any success is a real bypass
        uint256 k = seed % 6;
        Reenterer.Mode m = k == 0 ? Reenterer.Mode.WithdrawRefund : k == 1 ? Reenterer.Mode.Claim
            : k == 2 ? Reenterer.Mode.Bid : k == 3 ? Reenterer.Mode.Settle : k == 4 ? Reenterer.Mode.SweepFees : Reenterer.Mode.Withdraw;
        re.setMode(m, (seed >> 8) % (pool.openBatchId() + 1));
    }

    // ── actions ──
    function deposit(uint256 who, uint256 n, uint256 extra, uint256 seed) external {
        address u = actors[who % 4];
        n = bound(n, 1, 45);
        extra = bound(extra, 0, 1 ether);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(u, nextId); ids[i] = nextId++; }
        uint256 fee = pool.depositFeeFor(ids.length);
        uint256 before = u.balance;
        if (u == address(re)) { _randReMode(seed); re.doDeposit(ids, fee + extra); }
        else { vm.prank(u); pool.deposit{value: fee + extra}(ids); }
        assertEq(before - u.balance, fee, "deposit refund not exact");
        gIn += fee; gFees += fee; spent[u] += fee;
    }

    function assemble(uint256 seed) external {
        (bool f, uint256 b) = _pick(seed, CreditPool.BatchState.Full);
        if (!f) return;
        pool.assemble(b);
        ++nAssembled;
    }

    function setReserve(uint256 who, uint256 seed, uint256 r) external {
        (bool f, uint256 b) = _pick(seed, seed % 3 == 0 ? CreditPool.BatchState.Auction : CreditPool.BatchState.Assembled);
        if (!f) b = seed % (pool.openBatchId() + 1);
        who = who % 4;
        address u = actors[who];
        for (uint256 k; k < 4 && pool.slots(b, u) == 0; ++k) u = actors[(who + k + 1) % 4];
        if (pool.slots(b, u) == 0) return;
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(b);
        if (s == CreditPool.BatchState.Settled || s == CreditPool.BatchState.Redeemed || s == CreditPool.BatchState.Dissolved) return;
        r = bound(r, 0, 20 ether);
        if (u == address(re)) re.doSetReserve(b, r);
        else { vm.prank(u); pool.setReserve(b, r); }
    }

    function startAuction(uint256 seed) external {
        (bool f, uint256 b) = _pick(seed, CreditPool.BatchState.Assembled);
        if (!f) return;
        if (!pool.noReserveOpen(b)) {
            try pool.currentReserve(b) returns (uint256) {} catch {
                if (seed % 4 == 0) return; // sometimes leave quorum unmet
                // depositors coordinate a vote (every holder votes a reserve in [0.01, 3] ether)
                for (uint256 i; i < 4; ++i) {
                    address u = actors[i];
                    if (pool.slots(b, u) == 0) continue;
                    uint256 r = 0.01 ether + uint256(keccak256(abi.encode(seed, i))) % 3 ether;
                    if (u == address(re)) re.doSetReserve(b, r);
                    else { vm.prank(u); pool.setReserve(b, r); }
                }
            }
        }
        address[] memory ds = pool.batchDepositors(b);
        if (ds.length == 1) {                          // only a sole holder may auction their own batch
            if (ds[0] == address(re)) return;          // (the re-entering actor can't be pranked into it)
            vm.prank(ds[0]);
        }
        pool.startAuction(b);
        assertEq(gLiveBid[b], 0);
        ++nStarted;
    }

    /// 1–3 competing bids (rotating bidders) on one auction per call, so outbids/refunds are common.
    function bid(uint256 who, uint256 bseed, uint256 extra, uint256 seed) external {
        (bool f, uint256 b) = _pick(bseed, CreditPool.BatchState.Auction);
        if (!f || bseed % 8 == 0) b = bseed % (pool.openBatchId() + 1); // sometimes a random (likely non-live) batch
        uint256 k = 1 + seed % 3;
        who = who % 5;
        for (uint256 i; i < k; ++i) {
            _bid(actors[(who + i) % 5], b, uint256(keccak256(abi.encode(extra, i))), seed >> (8 * i));
        }
    }

    function _bid(address u, uint256 b, uint256 extra, uint256 seed) internal {
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(b);
        (address hb, uint256 hbid, uint256 reserve, uint64 endsAt) = pool.auctions(b);
        if (s != CreditPool.BatchState.Auction || block.timestamp >= endsAt) {
            // attack: bid into a non-live auction must revert
            vm.prank(u);
            try pool.bid{value: 1 ether}(b) { _flag("bid into non-live auction"); } catch {}
            return;
        }
        uint256 minBid = hb == address(0) ? reserve : hbid + hbid * 500 / 10_000;
        if (minBid == 0) minBid = 1;
        uint256 amt = minBid + bound(extra, 0, 5 ether);
        uint256 before = u.balance;
        if (u == address(re)) { _randReMode(seed); re.doBid(b, amt); }
        else if (u == address(rb)) { rb.doBid(b, amt); }
        else { vm.prank(u); pool.bid{value: amt}(b); }
        assertEq(before - u.balance, amt);
        if (hb != address(0)) {
            gPending[hb] += hbid; gPendingSum += hbid; entitled[hb] += hbid; gLiveBidSum -= hbid;
        }
        gLiveBid[b] = amt; gLiveBidSum += amt;
        gIn += amt; spent[u] += amt; ++nBids;
    }

    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1, 12 hours)); }
    function warpFar(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 20 days, 35 days)); }
    function changePrice(uint256 p) external { feed.set(int256(bound(p, 100e8, 1_000_000e8)), 0); }

    function settle(uint256 bseed) external {
        (bool f, uint256 b) = _pick(bseed, CreditPool.BatchState.Auction);
        if (!f || bseed % 8 == 0) b = bseed % (pool.openBatchId() + 1);
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(b);
        (address hb, uint256 hbid,, uint64 endsAt) = pool.auctions(b);
        if (s == CreditPool.BatchState.Auction && block.timestamp < endsAt && (bseed >> 8) % 2 == 0) vm.warp(endsAt);
        if (s != CreditPool.BatchState.Auction || block.timestamp < endsAt) {
            try pool.settle(b) { _flag("settle outside ended auction"); } catch {}
            return;
        }
        pool.settle(b);
        if (hb != address(0)) {
            (,,, uint256 sid, uint256 proceeds,) = pool.batchInfo(b);
            assertEq(stmts.ownerOf(sid), hb, "statement to wrong party");
            assertEq(proceeds, hbid, "no sale fee: depositors get the whole price");
            gLiveBidSum -= hbid; gLiveBid[b] = 0;
            uint256 distributed;
            for (uint256 i; i < 4; ++i) {
                uint256 sh = proceeds * pool.slots(b, actors[i]) / 80;
                gShare[b][actors[i]] = sh; gUnclaimedSum += sh; entitled[actors[i]] += sh; distributed += sh;
            }
            gDust += proceeds - distributed;
            ++nSettledSale;
        }
        try pool.settle(b) { _flag("double settle"); } catch {}
    }

    /// 1–4 claims per call (different claimants / batches), so settled proceeds actually get drawn down.
    function claim(uint256 who, uint256 bseed, uint256 seed) external {
        uint256 k = 1 + seed % 4;
        for (uint256 i; i < k; ++i) _claim(who % 4 + i, bseed >> (4 * i), seed >> (8 * i + 2));
    }

    function _claim(uint256 who, uint256 bseed, uint256 seed) internal {
        who = who % 4;
        address u = actors[who];
        (bool f, uint256 b) = _pick(bseed, CreditPool.BatchState.Settled);
        if (!f || bseed % 8 == 0) b = bseed % (pool.openBatchId() + 1);
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(b);
        if (seed % 4 != 0) { // usually pick an eligible claimant
            for (uint256 i; i < 4; ++i) {
                address c = actors[(who + i) % 4];
                if (pool.slots(b, c) > 0 && !pool.claimed(b, c)) { u = c; break; }
            }
        }
        bool ok = s == CreditPool.BatchState.Settled && pool.slots(b, u) > 0 && !pool.claimed(b, u);
        uint256 before = u.balance;
        if (!ok) {
            if (u == address(re)) { try re.doClaim(b) { _flag("claim not entitled (re)"); } catch {} }
            else { vm.prank(u); try pool.claim(b) { _flag("claim not entitled"); } catch {} }
            assertEq(u.balance, before);
            return;
        }
        if (u == address(re)) { _randReMode(seed); re.doClaim(b); }
        else { vm.prank(u); pool.claim(b); }
        uint256 sh = gShare[b][u];
        assertEq(u.balance - before, sh, "claim amount");
        gShare[b][u] = 0; gUnclaimedSum -= sh; gOut += sh; received[u] += sh; ++nClaims;
    }

    function withdrawRefund(uint256 who, uint256 seed) external {
        who = who % 5;
        address u = actors[who];
        if (seed % 4 != 0) { // usually pick someone owed a refund
            for (uint256 i; i < 5; ++i) {
                address c = actors[(who + i) % 5];
                if (pool.pendingReturns(c) > 0) { u = c; break; }
            }
        }
        uint256 amt = pool.pendingReturns(u);
        uint256 before = u.balance;
        if (amt == 0) {
            if (u == address(re)) { try re.doWithdrawRefund() { _flag("refund from nothing (re)"); } catch {} }
            else if (u == address(rb)) { try rb.doWithdrawRefund() { _flag("refund from nothing (rb)"); } catch {} }
            else { vm.prank(u); try pool.withdrawRefund() { _flag("refund from nothing"); } catch {} }
            return;
        }
        if (u == address(rb)) {
            if (seed % 2 == 0) {
                try rb.doWithdrawRefund() { _flag("reverting receiver got paid"); } catch {}
                assertEq(pool.pendingReturns(u), amt, "refund lost on failed send");
                return;
            }
            rb.setAccept(true); rb.doWithdrawRefund(); rb.setAccept(false);
        } else if (u == address(re)) { _randReMode(seed); re.doWithdrawRefund(); }
        else { vm.prank(u); pool.withdrawRefund(); }
        assertEq(u.balance - before, amt);
        assertEq(amt, gPending[u]);
        gPending[u] = 0; gPendingSum -= amt; gOut += amt; received[u] += amt; ++nRefunds;
        // second pull must fail
        if (u == address(re)) { re.setMode(Reenterer.Mode.None, 0); try re.doWithdrawRefund() { _flag("double refund"); } catch {} }
        else if (u != address(rb)) { vm.prank(u); try pool.withdrawRefund() { _flag("double refund"); } catch {} }
    }

    function sweepFees() external {
        uint256 before = treasury.balance;
        uint256 storeBefore = address(pool.store()).balance;
        vm.prank(eve); pool.sweepFees();
        assertEq(treasury.balance - before, gFees * 2500 / 10_000, "platform gets 25%");
        assertEq(address(pool.store()).balance - storeBefore, gFees - gFees * 2500 / 10_000, "store gets 75%");
        gOut += gFees; gSwept += gFees; gFees = 0;
    }

    /// Thief: tries claim on any batch and withdrawRefund; everything must revert.
    function eveSteal(uint256 b) external {
        b = bound(b, 0, pool.openBatchId());
        vm.prank(eve); try pool.claim(b) { _flag("eve claimed"); } catch {}
        vm.prank(eve); try pool.withdrawRefund() { _flag("eve refunded"); } catch {}
    }
}

contract EthCustodyInvariantTest is Test {
    CreditPool pool; MockCredits credits; MockStatements stmts; MockFeed feed; EthHandler h;
    address treasury = address(0x7EA5);

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        feed = new MockFeed(2500e8);
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, treasury);
        h = new EthHandler(pool, credits, feed, stmts, treasury);
        bytes4[] memory sel = new bytes4[](13);
        sel[0] = EthHandler.deposit.selector;       sel[1] = EthHandler.assemble.selector;
        sel[2] = EthHandler.setReserve.selector;    sel[3] = EthHandler.startAuction.selector;
        sel[4] = EthHandler.bid.selector;           sel[5] = EthHandler.warp.selector;
        sel[6] = EthHandler.warpFar.selector;       sel[7] = EthHandler.settle.selector;
        sel[8] = EthHandler.claim.selector;         sel[9] = EthHandler.withdrawRefund.selector;
        sel[10] = EthHandler.sweepFees.selector;    sel[11] = EthHandler.eveSteal.selector;
        sel[12] = EthHandler.changePrice.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_EthSolvencyAndEntitlements() public view {
        // 1. obligations computed purely from contract storage
        uint256 open = pool.openBatchId();
        uint256 n = h.actorCount();
        uint256 liveBids; uint256 unclaimed; uint256 pending;
        for (uint256 b; b <= open; ++b) {
            (CreditPool.BatchState s,,,, uint256 proceeds,) = pool.batchInfo(b);
            if (s == CreditPool.BatchState.Auction) { (, uint256 hb,,) = pool.auctions(b); liveBids += hb; }
            if (s == CreditPool.BatchState.Settled) {
                uint256 slotSum;
                for (uint256 i; i < n; ++i) {
                    address a = h.actors(i);
                    slotSum += pool.slots(b, a);
                    if (!pool.claimed(b, a)) unclaimed += proceeds * pool.slots(b, a) / 80;
                }
                assertEq(slotSum, 80, "settled batch slots != 80");
            }
        }
        for (uint256 i; i < n; ++i) pending += pool.pendingReturns(h.actors(i));
        pending += pool.pendingReturns(h.eve());
        uint256 obligations = liveBids + pending + unclaimed + pool.accruedFees() + pool.platformFeesOwed();
        assertGe(address(pool).balance, obligations, "INSOLVENT");

        // 2. contract state matches ghosts
        assertEq(liveBids, h.gLiveBidSum(), "live bids ghost");
        assertEq(pending, h.gPendingSum(), "pending ghost");
        assertEq(unclaimed, h.gUnclaimedSum(), "unclaimed ghost");
        assertEq(pool.accruedFees(), h.gFees(), "fees ghost");
        assertEq(pool.pendingReturns(h.eve()), 0);

        // 3. exact conservation: balance == in - out == obligations + rounding dust
        assertEq(address(pool).balance, h.gIn() - h.gOut(), "conservation");
        assertEq(address(pool).balance, obligations + h.gDust(), "dust accounting");
        assertLe(h.gDust(), 80 * h.nSettledSale());
        // Every swept wei landed at the platform (25%) or the store's treasury (75%), nowhere else.
        assertEq(h.treasury().balance + address(h.pool().store()).balance, h.gSwept(), "swept fees accounted");

        // 4. per-actor: no one ends with more than paid-in + entitled
        for (uint256 i; i < n; ++i) {
            address a = h.actors(i);
            assertEq(a.balance, h.INIT() - h.spent(a) + h.received(a), "actor balance drift");
            assertLe(h.received(a), h.entitled(a), "actor over-received");
            assertEq(pool.pendingReturns(a), h.gPending(a));
        }
        assertEq(h.eve().balance, h.INIT(), "eve profited");

        // 5. no attack / reentry succeeded
        assertFalse(h.attackSucceeded(), h.attackNote());
        assertFalse(h.re().reentrySucceeded(), "reentry succeeded");
    }

    function afterInvariant() external view {
        console.log("assembled", h.nAssembled(), "auctions started", h.nStarted());
        console.log("bids", h.nBids(), "sales settled", h.nSettledSale());
        console.log("claims", h.nClaims(), "refunds", h.nRefunds());
    }
}
