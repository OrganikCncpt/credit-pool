// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {BackedPool} from "../src/BackedPool.sol";
import {BackedStore} from "../src/BackedStore.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

function deployBacked(address credits, address statements, address assembler, address feed, uint256 opensAt, address feeRecipient)
    returns (BackedPool pool)
{
    BackedStore store = new BackedStore(5 ether);
    pool = new BackedPool(credits, statements, assembler, feed, opensAt, feeRecipient, address(store));
    store.setPool(address(pool));
}

/// Bidder that re-enters on refunds and can refuse ETH.
contract NastyBackedBidder {
    BackedPool pool; bool reenter; bool refuse;
    constructor(BackedPool p) { pool = p; }
    function bid(uint256 b) external payable { pool.bid{value: msg.value}(b); }
    function back(uint256 b) external payable { pool.back{value: msg.value}(b); }
    function setRefuse(bool r) external { refuse = r; }
    function pull(bool r) external { reenter = r; pool.withdrawRefund(); }
    receive() external payable {
        require(!refuse, "no");
        if (reenter) pool.withdrawRefund();
    }
}

/// Assembler that re-enters the pool mid-assembly.
contract ReenteringAssembler {
    MockStatements real; BackedPool pool;
    constructor(MockStatements r) { real = r; }
    function setPool(BackedPool p) external { pool = p; }
    function assemble(uint256[] calldata) external returns (uint256) {
        pool.withdrawRefund(); // must hit the reentrancy lock, which unwinds the sale
        return 0;
    }
}

contract BackedPoolTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; BackedPool pool; BackedStore store;
    address treasury = makeAddr("bp-treasury");
    address alice = makeAddr("bp-alice"); address bob = makeAddr("bp-bob"); address carol = makeAddr("bp-carol");
    address whale = makeAddr("bp-whale"); address whale2 = makeAddr("bp-whale2"); address bidder = makeAddr("bp-bidder");
    uint256 nextId = 1;
    uint256 opensAt;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        opensAt = block.timestamp + 1 days;
        pool = deployBacked(address(credits), address(stmts), address(stmts), address(feed), opensAt, treasury);
        store = BackedStore(payable(address(pool.store())));
        address[6] memory us = [alice, bob, carol, whale, whale2, bidder];
        for (uint256 i; i < 6; ++i) {
            vm.deal(us[i], 100 ether);
            vm.prank(us[i]); credits.setApprovalForAll(address(pool), true);
        }
    }

    // ───────── helpers ─────────
    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _deposit(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(who); pool.deposit{value: fee}(ids);
    }
    /// alice 40, bob 30, carol 10 → batch 0 Full
    function _fill() internal returns (uint256[] memory a, uint256[] memory b_, uint256[] memory c) {
        a = _deposit(alice, 40); b_ = _deposit(bob, 30); c = _deposit(carol, 10);
    }
    function _state(uint256 b) internal view returns (BackedPool.BatchState s) { (s,,,,,,) = pool.batchInfo(b); }
    function _round(uint256 b) internal view returns (uint64 r) { (,,,,, r,) = pool.batchInfo(b); }
    /// Starts the auction; if the depositors haven't voted, alice (40) and bob (30) vote the best backing.
    function _start(uint256 b) internal {
        (, uint256 open) = pool.bestBacking(b);
        if (pool.majorityMinimum(b) == 0) _vote(b, open);
        vm.warp(opensAt > block.timestamp ? opensAt : block.timestamp);
        pool.startAuction(b, open);
    }
    function _vote(uint256 b, uint256 price) internal {
        vm.prank(alice); pool.setReserve(b, price);
        vm.prank(bob); pool.setReserve(b, price);
    }
    function _end(uint256 b) internal { (,,, uint64 e) = pool.auctions(b); vm.warp(e); }
    /// Every wei the pool holds is owed to someone (I9).
    function _owed(address[] memory who) internal view returns (uint256 sum) {
        sum = pool.accruedFees() + pool.platformFeesOwed();
        for (uint256 i; i < who.length; ++i) sum += pool.pendingReturns(who[i]);
    }

    // ───────── deposits / withdraws ─────────
    function test_FullBatchWithdrawReopensAndBumpsNonce() public {
        (uint256[] memory a,,) = _fill();
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        (,,,,,, uint64 n0) = pool.batchInfo(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        (BackedPool.BatchState s, uint256 filled,,,,, uint64 n1) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Filling));
        assertEq(filled, 79); assertGt(n1, n0);
        assertEq(credits.ownerOf(a[0]), alice);
        // new deposits go to batch 1; batch 0 refills only through depositInto
        uint256[] memory fresh = _give(carol, 1);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(carol); pool.depositInto{value: fee}(0, fresh, 79);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        assertEq(pool.openBatchId(), 1);
    }

    function test_DepositIntoNeverSpills() public {
        (uint256[] memory a,,) = _fill();
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        uint256[] memory two = _give(bob, 2);
        uint256 fee = pool.depositFeeFor(2);
        vm.prank(bob); vm.expectRevert(BackedPool.TooMany.selector);
        pool.depositInto{value: fee}(0, two, 79);
    }

    // ───────── backing ─────────
    function test_BackAnyAmountSeveralBackersBestOpens() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.prank(whale2); pool.back{value: 2 ether}(0);
        vm.prank(whale); pool.back{value: 1.5 ether}(0); // adds up: 2.5
        (address who, uint256 amt) = pool.bestBacking(0);
        assertEq(who, whale); assertEq(amt, 2.5 ether);
        _start(0);
        (address hb, uint256 hbid,,) = pool.auctions(0);
        assertEq(hb, whale); assertEq(hbid, 2.5 ether);
        // the other backer is not committed and can leave any time
        vm.prank(whale2); pool.withdrawBacking(0);
        assertEq(pool.pendingReturns(whale2), 2 ether);
        // the committed opening bid can't be withdrawn as a backing
        vm.prank(whale); vm.expectRevert(BackedPool.NothingToClaim.selector);
        pool.withdrawBacking(0);
    }

    function test_BackingFloorAndZero() public {
        _fill();
        vm.prank(whale); vm.expectRevert(BackedPool.BackingTooLow.selector);
        pool.back{value: 79}(0);
        vm.prank(whale); vm.expectRevert(BackedPool.BackingTooLow.selector);
        pool.back{value: 0}(0);
        vm.prank(whale); pool.back{value: 80}(0);
    }

    function test_CantStartWithoutBacking() public {
        _fill();
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.NotBacked.selector);
        pool.startAuction(0, 0);
    }

    function test_CantStartBeforeFull() public {
        _deposit(alice, 79);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.WrongBatchState.selector);
        pool.startAuction(0, 1 ether);
    }

    function test_CantStartBeforeAssemblyOpens() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.expectRevert(BackedPool.NotYet.selector);
        pool.startAuction(0, 1 ether);
    }

    /// A backing posted for one set of Credits can't open an auction for a different set (I3).
    function test_StaleBackingAfterCompositionChange() public {
        (uint256[] memory a,,) = _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        uint256[] memory fresh = _give(carol, 1);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(carol); pool.depositInto{value: fee}(0, fresh, 79);
        (, uint256 amt) = pool.bestBacking(0);
        assertEq(amt, 0);
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.NotBacked.selector);
        pool.startAuction(0, 1 ether);
        // re-confirming (any top-up) makes it current again
        vm.prank(whale); pool.back{value: 1}(0);
        (, amt) = pool.bestBacking(0);
        assertEq(amt, 1 ether + 1);
    }

    /// The opening bid can only be what the caller saw or better; a top-up can't block a start (audit L-1).
    function test_StartOpeningAtLeastWhatCallerSaw() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _vote(0, 1 ether);
        vm.warp(opensAt);
        vm.prank(whale); pool.back{value: 1}(0); // "front-run" top-up
        pool.startAuction(0, 1 ether);           // still starts: the opening only went up
        (, uint256 hb,,) = pool.auctions(0);
        assertEq(hb, 1 ether + 1);
    }

    function test_StartRevertsIfOpeningDropped() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.prank(whale2); pool.back{value: 0.5 ether}(0);
        _vote(0, 0.5 ether);
        vm.warp(opensAt);
        vm.prank(whale); pool.withdrawBacking(0);
        vm.expectRevert(BackedPool.BackingChanged.selector);
        pool.startAuction(0, 1 ether);
        pool.startAuction(0, 0.5 ether);
    }

    /// Stale backings can't squat the 10-backer list (audit M-2).
    function test_StaleBackingsEvictedFirst() public {
        address[] memory sy = new address[](10);
        _deposit(alice, 79);
        for (uint256 i; i < 10; ++i) {
            sy[i] = makeAddr(string.concat("bp-sybil", vm.toString(i)));
            vm.deal(sy[i], 20 ether);
            vm.prank(sy[i]); pool.back{value: 10 ether}(0); // posted while filling → stale once it fills
        }
        _deposit(bob, 1);
        (, uint256 best) = pool.bestBacking(0);
        assertEq(best, 0);
        vm.prank(whale); pool.back{value: 0.5 ether}(0);  // smaller than every squatter, still gets in
        assertEq(pool.pendingReturns(sy[0]) + pool.pendingReturns(sy[9]) > 0, true);
        (address who, uint256 amt) = pool.bestBacking(0);
        assertEq(who, whale); assertEq(amt, 0.5 ether);
        vm.prank(alice); pool.setReserve(0, 0.5 ether); // 79 slots
        vm.warp(opensAt);
        pool.startAuction(0, 0.5 ether);
    }

    /// A pool whose store points elsewhere can't start auctions or redeem (audit L-2).
    function test_UnlinkedStoreRefused() public {
        BackedStore other = new BackedStore(1 ether); // never linked to p2
        BackedPool p2 = new BackedPool(address(credits), address(stmts), address(stmts), address(feed), opensAt, treasury, address(other));
        vm.prank(alice); credits.setApprovalForAll(address(p2), true);
        uint256[] memory ids = _give(alice, 80);
        uint256 fee = p2.depositFeeFor(80);
        vm.prank(alice); p2.deposit{value: fee}(ids);
        vm.prank(whale); p2.back{value: 1 ether}(0);
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.StoreNotLinked.selector);
        p2.startAuction(0, 1 ether);
        vm.prank(alice); vm.expectRevert(BackedPool.StoreNotLinked.selector);
        p2.redeem(0);
    }

    /// Votes were for the old Credits: reopening a full batch clears them (audit Info-1).
    function test_ReopenClearsVotes() public {
        (uint256[] memory a,,) = _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        assertEq(pool.majorityMinimum(0), 1 ether);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        assertEq(pool.reservePref(0, alice), 0);
        assertEq(pool.reservePref(0, bob), 0);
        assertEq(pool.majorityMinimum(0), 0);
    }

    function test_BackerCapEvictsLowest() public {
        _fill();
        address[] memory bs = new address[](11);
        for (uint256 i; i < 11; ++i) {
            bs[i] = makeAddr(string.concat("bp-backer", vm.toString(i)));
            vm.deal(bs[i], 10 ether);
        }
        for (uint256 i; i < 10; ++i) { vm.prank(bs[i]); pool.back{value: (i + 1) * 0.1 ether}(0); }
        vm.prank(bs[10]); vm.expectRevert(BackedPool.BackingTooLow.selector);
        pool.back{value: 0.1 ether}(0); // must beat the lowest
        vm.prank(bs[10]); pool.back{value: 0.15 ether}(0);
        assertEq(pool.pendingReturns(bs[0]), 0.1 ether); // the evicted backer is refunded
        (uint256 amt,) = pool.backings(0, bs[0]);
        assertEq(amt, 0);
        (address[] memory who,,) = pool.backersOf(0);
        assertEq(who.length, 10);
    }

    function test_NoBackingWhileAuctionLive() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        vm.prank(whale2); vm.expectRevert(BackedPool.WrongBatchState.selector);
        pool.back{value: 2 ether}(0);
    }

    // ───────── auction → sold ─────────
    function test_SellsAtOrAboveMajorityMinimum() public {
        _fill();
        vm.prank(alice); pool.setReserve(0, 2 ether);
        vm.prank(carol); pool.setReserve(0, 1 ether); // 10 slots @1, 40 @2 → 50 ≥ 41 at 2 ether
        assertEq(pool.majorityMinimum(0), 2 ether);
        vm.prank(whale); pool.back{value: 2 ether}(0);
        _start(0);
        vm.prank(bidder); pool.bid{value: 2.1 ether}(0);
        assertEq(pool.pendingReturns(whale), 2 ether); // backer outbid → refunded
        _end(0);
        assertEq(credits.balanceOf(address(pool)), 80); // nothing burned yet (I1)
        pool.settle(0);
        (BackedPool.BatchState s,,, uint256 sid, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
        assertEq(stmts.ownerOf(sid), bidder);
        assertEq(proceeds, 2.1 ether);
        assertEq(credits.balanceOf(address(pool)), 0);
        // split by slots
        uint256 a0 = alice.balance; vm.prank(alice); pool.claim(0); assertEq(alice.balance - a0, 1.05 ether);
        uint256 b0 = bob.balance;   vm.prank(bob);   pool.claim(0); assertEq(bob.balance - b0, 0.7875 ether);
        uint256 c0 = carol.balance; vm.prank(carol); pool.claim(0); assertEq(carol.balance - c0, 0.2625 ether);
        vm.prank(carol); vm.expectRevert(BackedPool.NothingToClaim.selector); pool.claim(0);
        // points: 2 per Credit, at burn
        assertEq(store.balanceOf(alice), 80); assertEq(store.balanceOf(bob), 60); assertEq(store.balanceOf(carol), 20);
    }

    function test_BackerWinsUncontested() public {
        _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0); _end(0); pool.settle(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), whale);
    }

    function test_AntiSnipeAndIncrement() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        (,,, uint64 e) = pool.auctions(0);
        vm.warp(e - 60);
        vm.prank(bidder); vm.expectRevert(BackedPool.BidTooLow.selector);
        pool.bid{value: 1.04 ether}(0);
        vm.prank(bidder); pool.bid{value: 1.05 ether}(0);
        (,,, uint64 e2) = pool.auctions(0);
        assertEq(e2, block.timestamp + 15 minutes);
        vm.warp(e2);
        vm.prank(whale2); vm.expectRevert(BackedPool.WrongBatchState.selector);
        pool.bid{value: 2 ether}(0);
    }

    function test_SettleTooEarly() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        vm.expectRevert(BackedPool.AuctionLive.selector);
        pool.settle(0);
    }

    // ───────── option 1: auctions open only at or above the depositors' minimum ─────────
    function test_NoAuctionWithoutMajorityMinimum() public {
        _fill();
        vm.prank(whale); pool.back{value: 5 ether}(0);
        vm.prank(bob); pool.setReserve(0, 1 ether); // 30 slots: not a majority
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.NoMinimum.selector);
        pool.startAuction(0, 5 ether);
    }

    /// A lowball backing can't start an auction, so it can't lock the depositors' Credits.
    function test_LowballCantStartOrLockCredits() public {
        (uint256[] memory a,,) = _fill();
        _vote(0, 1 ether);
        vm.prank(whale); pool.back{value: 0.001 ether}(0);
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.BelowMinimum.selector);
        pool.startAuction(0, 0.001 ether);
        // the depositors stay free to leave
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        assertEq(credits.ownerOf(a[0]), alice);
    }

    /// The best backing must meet the minimum; a lower one never opens even if it's the only one.
    function test_BestBackingMustMeetMinimum() public {
        _fill();
        _vote(0, 1 ether);
        vm.prank(whale); pool.back{value: 0.9 ether}(0);
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.BelowMinimum.selector);
        pool.startAuction(0, 0.9 ether);
        vm.prank(whale2); pool.back{value: 1 ether}(0); // exactly the minimum
        pool.startAuction(0, 1 ether);
        (address hb, uint256 amt, uint256 minimum,) = pool.auctions(0);
        assertEq(hb, whale2); assertEq(amt, 1 ether); assertEq(minimum, 1 ether);
    }

    /// To sell for less, the majority lowers its vote: then the lower backing can open.
    function test_MajorityLowersVoteToSellCheaper() public {
        _fill();
        _vote(0, 2 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.warp(opensAt);
        vm.expectRevert(BackedPool.BelowMinimum.selector);
        pool.startAuction(0, 1 ether);
        _vote(0, 1 ether);
        pool.startAuction(0, 1 ether);
        _end(0); pool.settle(0);
        (BackedPool.BatchState st,,,,uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(st), uint8(BackedPool.BatchState.Sold));
        assertEq(proceeds, 1 ether);
    }

    /// Votes changed during the auction don't move its minimum, and every started auction sells.
    function test_StartedAuctionAlwaysSellsVotesDuringAuctionIgnored() public {
        _fill();
        _vote(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        _vote(0, 50 ether); // too late: the price was fixed when it opened
        _end(0); pool.settle(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), whale);
    }

    function test_NoWithdrawOrBackingDuringAuction() public {
        (uint256[] memory a,,) = _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.withdraw(one);
        vm.prank(whale2); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.back{value: 2 ether}(0);
    }

    function test_NewRoundAfterUnwind() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0); _end(0);
        stmts.setCap(0);
        pool.settle(0);                      // unwinds: Full again, whale refunded
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        assertEq(pool.pendingReturns(whale), 1 ether);
        stmts.setCap(type(uint256).max);
        vm.prank(whale2); pool.back{value: 1 ether}(0);
        uint64 r1 = _round(0);
        _start(0);
        assertEq(_round(0), r1 + 1);
        _end(0); pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Sold));
    }

    // ───────── all-or-nothing finalize ─────────
    function test_UnwindWhenAssemblyFails() public {
        _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        vm.prank(bidder); pool.bid{value: 3 ether}(0);
        _end(0);
        stmts.setCap(0); // the Statements contract refuses
        pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        assertEq(credits.balanceOf(address(pool)), 80);                 // every Credit back, unburned
        assertEq(credits.balanceOf(address(pool.vault())), 0);
        assertEq(pool.pendingReturns(bidder), 3 ether);                 // buyer refunded
        assertEq(store.balanceOf(alice), 0);                            // no points without a burn
        (address hb,,,) = pool.auctions(0);
        assertEq(hb, address(0));
    }

    function test_UnwindWhenAssemblerReenters() public {
        ReenteringAssembler ra = new ReenteringAssembler(stmts);
        BackedPool p2 = deployBacked(address(credits), address(stmts), address(ra), address(feed), opensAt, treasury);
        ra.setPool(p2);
        vm.prank(alice); credits.setApprovalForAll(address(p2), true);
        uint256[] memory ids = _give(alice, 80);
        uint256 fee = p2.depositFeeFor(80);
        vm.prank(alice); p2.deposit{value: fee}(ids);
        vm.prank(whale); p2.back{value: 1 ether}(0);
        vm.prank(alice); p2.setReserve(0, 1 ether);
        vm.warp(opensAt);
        p2.startAuction(0, 1 ether);
        (,,, uint64 e) = p2.auctions(0); vm.warp(e);
        p2.settle(0); // finalize → assembler re-enters → unwind
        (BackedPool.BatchState s,,,,,,) = p2.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Full));
        assertEq(credits.balanceOf(address(p2)), 80);
        assertEq(p2.pendingReturns(whale), 1 ether);
    }

    function test_GasStarvationCantForceUnwind() public {
        _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0); _end(0);
        vm.expectRevert(BackedPool.NeedMoreGas.selector);
        pool.settle{gas: 5_000_000}(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Auction));
        pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Sold));
    }

    function test_FinalizeOnlySelf() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0);
        vm.prank(whale); vm.expectRevert(BackedPool.OnlySelf.selector);
        pool.finalizeSale(0, whale, 1);
    }

    // ───────── sole holder ─────────
    function test_SoleHolderRedeems() public {
        _deposit(alice, 80);
        vm.warp(opensAt);
        vm.prank(bob); vm.expectRevert(BackedPool.NotDepositor.selector); pool.redeem(0);
        vm.prank(alice); pool.redeem(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), alice);
        assertEq(store.balanceOf(alice), 160);
    }

    // ───────── money safety ─────────
    function test_RefundReentrancyBlockedAndRefuserCantBlockAuction() public {
        NastyBackedBidder nb = new NastyBackedBidder(pool);
        vm.deal(address(nb), 10 ether);
        _fill();
        nb.back{value: 1 ether}(0);
        _start(0);
        nb.setRefuse(true);
        vm.prank(bidder); pool.bid{value: 2 ether}(0); // refunds are pulled, so a refuser can't block
        nb.setRefuse(false);
        vm.expectRevert(BackedPool.TransferFailed.selector); // re-entry hits the lock → send fails
        nb.pull(true);
        nb.pull(false);
        assertEq(address(nb).balance, 11 ether); // its 10 + the 1 ether backing it was funded with
    }

    function test_EthConservation() public {
        _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.prank(whale2); pool.back{value: 0.5 ether}(0);
        _start(0);
        vm.prank(bidder); pool.bid{value: 1.5 ether}(0);
        _end(0); pool.settle(0);
        address[] memory who = new address[](5);
        (who[0], who[1], who[2], who[3], who[4]) = (whale, whale2, bidder, alice, bob);
        // held = fees + refunds + uncommitted backing (whale2) + unclaimed proceeds
        (uint256 w2,) = pool.backings(0, whale2);
        assertEq(address(pool).balance, _owed(who) + w2 + 1.5 ether);
        vm.prank(alice); pool.claim(0); vm.prank(bob); pool.claim(0); vm.prank(carol); pool.claim(0);
        vm.prank(whale2); pool.withdrawBacking(0);
        vm.prank(whale); pool.withdrawRefund();
        vm.prank(whale2); pool.withdrawRefund();
        pool.sweepFees();
        assertEq(address(pool).balance, 0);
    }

    function test_FeeSplitAndBulkRate() public {
        assertEq(pool.depositFeeFor(5), pool.usdWei() * 10);
        assertEq(pool.depositFeeFor(6), pool.usdWei() * 6);
        _deposit(alice, 6);
        uint256 fees = pool.accruedFees();
        pool.sweepFees();
        assertEq(treasury.balance, fees / 4);
        assertEq(address(store).balance, fees - fees / 4);
    }

    function testFuzz_MajorityMinimum(uint96 pa, uint96 pb, uint96 pc) public {
        _fill(); // 40 / 30 / 10
        vm.prank(alice); pool.setReserve(0, pa);
        vm.prank(bob); pool.setReserve(0, pb);
        vm.prank(carol); pool.setReserve(0, pc);
        uint256 m = pool.majorityMinimum(0);
        // reference: lowest price x among votes with Σ{slots : 0 < p ≤ x} ≥ 41
        uint256[3] memory p = [uint256(pa), pb, pc];
        uint256[3] memory w = [uint256(40), 30, 10];
        uint256 best;
        for (uint256 i; i < 3; ++i) {
            if (p[i] == 0) continue;
            uint256 s;
            for (uint256 j; j < 3; ++j) if (p[j] != 0 && p[j] <= p[i]) s += w[j];
            if (s >= 41 && (best == 0 || p[i] < best)) best = p[i];
        }
        assertEq(m, best);
    }
}
