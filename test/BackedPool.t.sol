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
    function _vote(uint256 b, uint256 price) internal {
        vm.prank(alice); pool.setReserve(b, price);
        vm.prank(bob); pool.setReserve(b, price);
    }
    /// A depositor (alice) starts; votes the price first if there's none.
    function _start(uint256 b, uint256 price) internal {
        if (pool.majorityMinimum(b) == 0) _vote(b, price);
        vm.warp(opensAt > block.timestamp ? opensAt : block.timestamp);
        vm.prank(alice); pool.startAuction(b);
    }
    function _ends(uint256 b) internal view returns (uint64 e) { (,,, e,,) = pool.auctions(b); }
    function _end(uint256 b) internal { vm.warp(_ends(b)); }
    function _owed(address[] memory who) internal view returns (uint256 sum) {
        sum = pool.accruedFees() + pool.platformFeesOwed();
        for (uint256 i; i < who.length; ++i) sum += pool.pendingReturns(who[i]);
    }

    // ───────── deposits / withdraws ─────────
    function test_FullBatchWithdrawReopensAndBumpsNonce() public {
        (uint256[] memory a,,) = _fill();
        (,,,,,, uint64 n0) = pool.batchInfo(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        (BackedPool.BatchState s, uint256 filled,,,,, uint64 n1) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Filling));
        assertEq(filled, 79); assertGt(n1, n0);
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
    /// A backing at or above the price becomes the opening bid; bids must beat it (fb audit M).
    function test_HighBackingIsOpeningBid_CantBeUndercut() public {
        _fill();
        vm.prank(whale); pool.back{value: 5 ether}(0);
        vm.prank(whale2); pool.back{value: 10 ether}(0);
        _start(0, 1 ether);
        (address hb, uint256 amt,,,,) = pool.auctions(0);
        assertEq(hb, whale2); assertEq(amt, 10 ether);
        assertEq(pool.minNextBid(0), 10.5 ether);
        vm.prank(bidder); vm.expectRevert(BackedPool.BidTooLow.selector); pool.bid{value: 1 ether}(0);
        vm.prank(whale); vm.expectRevert(BackedPool.AuctionLive.selector); pool.withdrawBacking(0); // binding while it runs
        _end(0); pool.settle(0);
        vm.prank(whale2); vm.expectRevert(BackedPool.NothingToClaim.selector); pool.withdrawBacking(0); // used as the opening bid
        vm.prank(whale); pool.withdrawBacking(0);                                                        // free after settle
        (,,,, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(proceeds, 10 ether);
    }

    function test_BackingBelowPriceStaysOpenAtStart() public {
        _fill();
        vm.prank(whale); pool.back{value: 0.5 ether}(0);
        _start(0, 1 ether);
        (address hb,,,,,) = pool.auctions(0);
        assertEq(hb, address(0));
        assertEq(pool.minNextBid(0), 1 ether);
        vm.prank(whale); vm.expectRevert(BackedPool.AuctionLive.selector); pool.withdrawBacking(0); // binding while it runs
    }

    function test_BackingFloorAndZero() public {
        _fill();
        vm.prank(whale); vm.expectRevert(BackedPool.BackingTooLow.selector); pool.back{value: 79}(0);
        vm.prank(whale); vm.expectRevert(BackedPool.BackingTooLow.selector); pool.back{value: 0}(0);
        vm.prank(whale); pool.back{value: 80}(0);
    }

    function test_StaleBackingAndReconfirm() public {
        (uint256[] memory a,,) = _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        uint256[] memory fresh = _give(carol, 1);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(carol); pool.depositInto{value: fee}(0, fresh, 79);
        (, uint256 amt) = pool.bestBacking(0);
        assertEq(amt, 0);
        vm.prank(whale); pool.reconfirm(0);
        (, amt) = pool.bestBacking(0);
        assertEq(amt, 1 ether);
    }

    function test_ReconfirmNeedsABacking() public {
        _fill();
        vm.prank(whale); vm.expectRevert(BackedPool.NotBacked.selector); pool.reconfirm(0);
    }

    function test_StaleBackingsEvictedFirst() public {
        address[] memory sy = new address[](10);
        _deposit(alice, 79);
        for (uint256 i; i < 10; ++i) {
            sy[i] = makeAddr(string.concat("bp-sybil", vm.toString(i)));
            vm.deal(sy[i], 20 ether);
            vm.prank(sy[i]); pool.back{value: 10 ether}(0); // stale once the batch fills
        }
        _deposit(bob, 1);
        vm.prank(whale); pool.back{value: 0.5 ether}(0);  // smaller than every squatter, still gets in
        (address who, uint256 amt) = pool.bestBacking(0);
        assertEq(who, whale); assertEq(amt, 0.5 ether);
        assertEq(pool.pendingReturns(sy[0]), 10 ether);
    }

    function test_BackerCapEvictsLowest() public {
        _fill();
        address[] memory bs = new address[](11);
        for (uint256 i; i < 11; ++i) { bs[i] = makeAddr(string.concat("bp-backer", vm.toString(i))); vm.deal(bs[i], 10 ether); }
        for (uint256 i; i < 10; ++i) { vm.prank(bs[i]); pool.back{value: (i + 1) * 0.1 ether}(0); }
        vm.prank(bs[10]); vm.expectRevert(BackedPool.BackingTooLow.selector); pool.back{value: 0.1 ether}(0);
        vm.prank(bs[10]); pool.back{value: 0.15 ether}(0);
        assertEq(pool.pendingReturns(bs[0]), 0.1 ether);
    }

    // ───────── who can start ─────────
    function test_OnlyDepositorsStart() public {
        _fill(); _vote(0, 1 ether);
        vm.prank(whale); pool.back{value: 0.001 ether}(0); // a lowball
        vm.warp(opensAt);
        vm.prank(whale); vm.expectRevert(BackedPool.NotDepositor.selector); pool.startAuction(0);
        vm.prank(bidder); vm.expectRevert(BackedPool.NotDepositor.selector); pool.startAuction(0);
        vm.prank(carol); pool.startAuction(0); // any depositor, even a 10-slot one
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Auction));
    }

    function test_NoStartWithoutPrice_ButNoBackingNeeded() public {
        _fill();
        vm.warp(opensAt);
        vm.prank(alice); vm.expectRevert(BackedPool.NoMinimum.selector); pool.startAuction(0);
        _vote(0, 1 ether);
        vm.prank(alice); pool.startAuction(0); // no backing at all
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Auction));
    }

    /// No bid and no backing: the round ends unsold and the batch rests; the rest doubles.
    function test_NoBidNoBacking_UnsoldRestsAndDoubles() public {
        _fill(); _vote(0, 1 ether);
        uint256[4] memory rests = [uint256(1 days), 2 days, 4 days, 8 days];
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp > opensAt ? block.timestamp : opensAt);
            vm.prank(alice); pool.startAuction(0);
            _end(0); pool.settle(0);
            assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
            assertTrue(pool.unsold(0));
            assertEq(pool.cooldownUntil(0), block.timestamp + rests[i < 4 ? i : 3]);
            vm.prank(alice); vm.expectRevert(BackedPool.Cooldown.selector); pool.startAuction(0);
            vm.warp(pool.cooldownUntil(0));
        }
    }

    /// v3 audit M-1: reshuffling Credits doesn't reset the doubling; only real idle time does.
    function test_RestStreakSurvivesReshuffle_DecaysWithIdleTime() public {
        (uint256[] memory a,,) = _fill(); _vote(0, 1 ether);
        _start(0, 1 ether); _end(0); pool.settle(0);                 // rest 1 day
        vm.warp(pool.cooldownUntil(0));
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(alice); pool.depositInto{value: fee}(0, one, 79);   // same Credit back
        vm.prank(alice); pool.startAuction(0); _end(0); pool.settle(0);
        assertEq(pool.cooldownUntil(0), block.timestamp + 2 days);   // still doubles
        vm.warp(pool.cooldownUntil(0) + 7 days);                     // a week idle after the rest
        vm.prank(alice); pool.startAuction(0); _end(0); pool.settle(0);
        assertEq(pool.cooldownUntil(0), block.timestamp + 1 days);   // starts over
    }

    function test_CantStartBeforeFullOrBeforeOpen() public {
        _deposit(alice, 79);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.prank(alice); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.startAuction(0);
        _deposit(bob, 1);
        vm.prank(whale); pool.reconfirm(0);
        vm.prank(alice); vm.expectRevert(BackedPool.NotYet.selector); pool.startAuction(0);
    }

    // ───────── the auction ─────────
    function test_FirstBidMustMeetPrice() public {
        _fill();
        vm.prank(whale); pool.back{value: 0.5 ether}(0);
        _start(0, 2 ether);
        assertEq(pool.minNextBid(0), 2 ether);
        vm.prank(bidder); vm.expectRevert(BackedPool.BidTooLow.selector); pool.bid{value: 1.9 ether}(0);
        vm.prank(bidder); pool.bid{value: 2 ether}(0);
        assertEq(pool.minNextBid(0), 2.1 ether);
    }

    function test_BidAtPriceSells_BackerRefunded() public {
        _fill();
        vm.prank(whale); pool.back{value: 0.5 ether}(0);
        _start(0, 2 ether);
        vm.prank(bidder); pool.bid{value: 2.4 ether}(0);
        _end(0);
        assertEq(credits.balanceOf(address(pool)), 80); // nothing burned before the sale
        pool.settle(0);
        vm.prank(whale); pool.withdrawBacking(0);       // the below-price backing was never used
        (BackedPool.BatchState s,,, uint256 sid, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
        assertEq(stmts.ownerOf(sid), bidder);
        assertEq(proceeds, 2.4 ether);
        assertEq(pool.pendingReturns(whale), 0.5 ether);
        uint256 a0 = alice.balance; vm.prank(alice); pool.claim(0); assertEq(alice.balance - a0, 1.2 ether);
        assertEq(store.balanceOf(alice), 80);
    }

    function test_NoBid_BackingMeetsPrice_SellsToBacker() public {
        _fill();
        vm.prank(whale); pool.back{value: 2 ether}(0);
        _start(0, 2 ether);
        _end(0); pool.settle(0);
        (BackedPool.BatchState s,,, uint256 sid, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
        assertEq(stmts.ownerOf(sid), whale); assertEq(proceeds, 2 ether);
        assertEq(pool.pendingReturns(whale), 0);
    }

    /// The user's flow: a whale backs 1 ETH, the auction gets no bid at the votes' price, and the
    /// holders vote to take the whale's 1 ETH.
    function test_NoBid_HoldersAcceptBackersOffer() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 3 ether);
        _end(0); pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Decide));
        uint64 r = _round(0);
        vm.prank(alice); pool.acceptBacking(0, r, whale, 1 ether); // 40: not yet
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Decide));
        vm.prank(alice); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.acceptBacking(0, r, whale, 1 ether);
        vm.prank(carol); pool.acceptBacking(0, r, whale, 1 ether); // 50 → sells
        (BackedPool.BatchState s,,, uint256 sid, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
        assertEq(stmts.ownerOf(sid), whale); assertEq(proceeds, 1 ether);
    }

    function test_AcceptBindsExactOffer() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 3 ether); _end(0); pool.settle(0);
        uint64 r = _round(0);
        vm.startPrank(alice);
        vm.expectRevert(BackedPool.OfferChanged.selector); pool.acceptBacking(0, r, whale, 0.9 ether);
        vm.expectRevert(BackedPool.OfferChanged.selector); pool.acceptBacking(0, r, whale2, 1 ether);
        vm.expectRevert(BackedPool.OfferChanged.selector); pool.acceptBacking(0, r + 1, whale, 1 ether);
        vm.stopPrank();
        vm.prank(whale); vm.expectRevert(BackedPool.NotDepositor.selector); pool.acceptBacking(0, r, whale, 1 ether);
    }

    function test_ExpireRefundsCooldownThenRestart() public {
        (uint256[] memory a,,) = _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 3 ether); _end(0); pool.settle(0);
        vm.warp(_ends(0));
        pool.expire(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        assertEq(pool.pendingReturns(whale), 1 ether);
        assertEq(credits.balanceOf(address(pool)), 80); // nothing burned
        // the cooldown: no restart, but anyone may leave
        vm.prank(whale2); pool.back{value: 1 ether}(0);
        vm.prank(alice); vm.expectRevert(BackedPool.Cooldown.selector); pool.startAuction(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        assertEq(credits.ownerOf(a[0]), alice);
        uint256[] memory fresh = _give(alice, 1);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(alice); pool.depositInto{value: fee}(0, fresh, 79);
        vm.prank(whale2); pool.reconfirm(0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice); pool.startAuction(0);
        assertEq(_round(0), 2);
    }

    function test_NoWithdrawOrBidOutsideTheirWindows_BackingBelowPriceDuringAuction() public {
        (uint256[] memory a,,) = _fill();
        _start(0, 3 ether);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.withdraw(one);
        vm.prank(whale2); vm.expectRevert(BackedPool.BidInstead.selector); pool.back{value: 3 ether}(0);
        vm.prank(whale2); pool.back{value: 1 ether}(0); // below the price: an offer for the holders
        _end(0); pool.settle(0); // decide on whale2's offer
        (,,,, address backer, uint256 backing) = pool.auctions(0);
        assertEq(backer, whale2); assertEq(backing, 1 ether);
        vm.prank(alice); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.withdraw(one);
        vm.prank(whale); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.back{value: 2 ether}(0);
        vm.prank(bidder); vm.expectRevert(BackedPool.WrongBatchState.selector); pool.bid{value: 5 ether}(0);
    }

    function test_LateBestBackingExtends() public {
        _fill();
        _start(0, 3 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.warp(_ends(0) - 60);
        vm.prank(whale2); pool.back{value: 0.5 ether}(0); // not the best: no extension
        assertEq(_ends(0), block.timestamp + 60);
        vm.prank(whale2); pool.back{value: 0.51 ether}(0); // 1.01: best by under 5%: no extension
        assertEq(_ends(0), block.timestamp + 60);
        vm.prank(whale2); pool.back{value: 0.06 ether}(0); // 1.07 ≥ 1.01 × 1.05: +15 minutes
        assertEq(_ends(0), block.timestamp + 15 minutes);
    }

    /// v3 audit M: 1-wei top-ups can't keep an auction open; offers never extend once someone bid.
    function test_TinyTopUpsCantExtendForever() public {
        _fill();
        _start(0, 3 ether);
        vm.prank(whale); pool.back{value: 80}(0);
        vm.prank(bidder); pool.bid{value: 3 ether}(0);
        uint64 end0 = _ends(0);
        vm.warp(end0 - 60);
        vm.prank(whale); pool.back{value: 1 ether}(0);    // a big jump, but someone already bid
        assertEq(_ends(0), end0);
        vm.warp(end0);
        pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Sold));
    }

    /// v3 audit H-1: fill the list with refundable socks, churn out the honest offer at the deadline,
    /// pull the socks, accept dust. Offers are binding while the auction runs, and a full list only
    /// takes a new best, so it fails.
    function test_CapacityBlockThenWithdrawFails() public {
        _deposit(whale, 41); _deposit(alice, 39);
        vm.prank(whale); pool.setReserve(0, 1000 ether);
        vm.prank(alice); pool.setReserve(0, 10 ether);
        vm.warp(opensAt);
        vm.prank(whale); pool.startAuction(0);
        vm.prank(bidder); pool.back{value: 5 ether}(0);   // honest outsider
        address[] memory socks = new address[](10);
        for (uint256 i; i < 10; ++i) { socks[i] = makeAddr(string.concat("bp-sock", vm.toString(i))); vm.deal(socks[i], 100 ether); }
        for (uint256 i; i < 9; ++i) { vm.prank(socks[i]); pool.back{value: 20 ether}(0); }
        vm.warp(_ends(0) - 1);
        vm.prank(socks[9]); vm.expectRevert(BackedPool.BackingTooLow.selector);
        pool.back{value: 5 ether + 1}(0);                 // can't evict the outsider without becoming the best
        vm.prank(socks[0]); vm.expectRevert(BackedPool.AuctionLive.selector);
        pool.withdrawBacking(0);                          // socks can't be pulled while it runs
        vm.warp(_ends(0));
        vm.prank(socks[0]); vm.expectRevert(BackedPool.AuctionLive.selector);
        pool.withdrawBacking(0);                          // nor between the deadline and settle
        pool.settle(0);
        (,,,, , uint256 backing) = pool.auctions(0);
        assertEq(backing, 20 ether);                      // the blocking offers became the floor
    }

    /// fb audit H: a 41-slot holder sets a decoy price and a sock backs dust; during the auction
    /// anyone can post a better offer, so the holders' vote is on the best offer, not the sock's.
    function test_DecoyPriceDustTakeoverIsOutbid() public {
        _deposit(whale, 41); _deposit(alice, 20); _deposit(bob, 19);
        vm.prank(whale); pool.setReserve(0, 1_000_000 ether); // decoy: nobody can bid
        vm.prank(alice); pool.setReserve(0, 50 ether);
        vm.prank(bob); pool.setReserve(0, 50 ether);
        address sock = makeAddr("bp-sock");
        vm.deal(sock, 1 ether);
        vm.prank(sock); pool.back{value: 80}(0);
        vm.warp(opensAt);
        vm.prank(whale); pool.startAuction(0);
        vm.prank(bidder); pool.back{value: 50 ether}(0);      // a fair outside offer, below the decoy
        _end(0); pool.settle(0);
        (,,,, address backer, uint256 backing) = pool.auctions(0);
        assertEq(backer, bidder); assertEq(backing, 50 ether); // the holders vote on the best offer
        uint64 r = _round(0);
        vm.prank(whale); vm.expectRevert(BackedPool.OfferChanged.selector); pool.acceptBacking(0, r, sock, 80);
        vm.prank(whale); pool.acceptBacking(0, r, bidder, 50 ether); // if the whale sells, it's at 50
        (,,,, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(proceeds, 50 ether);
    }

    function test_AntiSnipe() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 1 ether);
        vm.warp(_ends(0) - 60);
        vm.prank(bidder); pool.bid{value: 1.05 ether}(0); // beats the opening backing by 5%
        assertEq(_ends(0), block.timestamp + 15 minutes);
    }

    function test_SettleTooEarly() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 1 ether);
        vm.expectRevert(BackedPool.AuctionLive.selector); pool.settle(0);
    }

    /// The opening backer outbid: their backing comes back like any outbid bid.
    function test_OpeningBackerOutbidRefunded() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 1 ether);
        vm.prank(bidder); pool.bid{value: 1.05 ether}(0);
        assertEq(pool.pendingReturns(whale), 1 ether);
        _end(0); pool.settle(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), bidder);
    }

    // ───────── all-or-nothing finalize ─────────
    function test_UnwindRefundsBidderAndBacker() public {
        _fill();
        vm.prank(whale); pool.back{value: 0.5 ether}(0);
        _start(0, 1 ether);
        vm.prank(bidder); pool.bid{value: 3 ether}(0);
        _end(0);
        stmts.setCap(0);
        pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        assertEq(credits.balanceOf(address(pool)), 80);
        assertEq(pool.pendingReturns(bidder), 3 ether);
        vm.prank(whale); pool.withdrawBacking(0); // its backing was never committed
        assertEq(pool.pendingReturns(whale), 0.5 ether);
        assertEq(store.balanceOf(alice), 0);
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
        vm.prank(alice); p2.startAuction(0);
        (,,, uint64 e,,) = p2.auctions(0); vm.warp(e);
        p2.settle(0); // backing meets the price → finalize → assembler re-enters → unwind
        (BackedPool.BatchState s,,,,,,) = p2.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Full));
        assertEq(p2.pendingReturns(whale), 1 ether);
    }

    function test_GasStarvationCantForceUnwind() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 1 ether); _end(0);
        vm.expectRevert(BackedPool.NeedMoreGas.selector);
        pool.settle{gas: 5_000_000}(0);
        pool.settle(0);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Sold));
    }

    function test_FinalizeOnlySelf() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        _start(0, 1 ether);
        vm.prank(whale); vm.expectRevert(BackedPool.OnlySelf.selector);
        pool.finalizeSale(0, whale, 1);
    }

    function test_SellToStoreOnlyFromStore() public {
        _fill();
        vm.prank(whale); vm.expectRevert(BackedPool.NotStore.selector); pool.sellToStore{value: 1 ether}(0);
    }

    // ───────── votes ─────────
    function test_ReopenKeepsOtherVotes() public {
        (uint256[] memory a,, uint256[] memory c) = _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        vm.prank(carol); pool.setReserve(0, 2 ether);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        assertEq(pool.reservePref(0, alice), 1 ether);
        vm.prank(carol); pool.withdraw(c);
        assertEq(pool.reservePref(0, carol), 0);
    }

    function test_OneSlotCantWipeQuorum() public {
        _deposit(alice, 40); _deposit(bob, 39);
        uint256[] memory g = _deposit(carol, 1);
        _vote(0, 1 ether);
        uint256 fee = pool.depositFeeFor(1);
        for (uint256 k; k < 5; ++k) {
            vm.startPrank(carol); pool.withdraw(g); pool.depositInto{value: fee}(0, g, 79); vm.stopPrank();
        }
        assertEq(pool.majorityMinimum(0), 1 ether);
    }

    function test_VotedMedian() public {
        _fill();
        vm.prank(alice); pool.setReserve(0, 1 ether);  // 40
        vm.prank(carol); pool.setReserve(0, 9 ether);  // 10
        assertEq(pool.majorityMinimum(0), 9 ether);    // 41+ slots accept only at 9
        assertEq(pool.votedMedian(0), 1 ether);        // but the voters' median is 1
    }

    function testFuzz_MajorityMinimum(uint96 pa, uint96 pb, uint96 pc) public {
        _fill();
        vm.prank(alice); pool.setReserve(0, pa);
        vm.prank(bob); pool.setReserve(0, pb);
        vm.prank(carol); pool.setReserve(0, pc);
        uint256 m = pool.majorityMinimum(0);
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

    // ───────── sole holder, store link ─────────
    function test_SoleHolderRedeems() public {
        _deposit(alice, 80);
        vm.warp(opensAt);
        vm.prank(bob); vm.expectRevert(BackedPool.NotDepositor.selector); pool.redeem(0);
        vm.prank(alice); pool.redeem(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), alice);
    }

    function test_UnlinkedStoreRefused() public {
        BackedStore other = new BackedStore(1 ether);
        BackedPool p2 = new BackedPool(address(credits), address(stmts), address(stmts), address(feed), opensAt, treasury, address(other));
        vm.prank(alice); credits.setApprovalForAll(address(p2), true);
        uint256[] memory ids = _give(alice, 80);
        uint256 fee = p2.depositFeeFor(80);
        vm.prank(alice); p2.deposit{value: fee}(ids);
        vm.prank(alice); p2.setReserve(0, 1 ether);
        vm.prank(whale); p2.back{value: 1 ether}(0);
        vm.warp(opensAt);
        vm.prank(alice); vm.expectRevert(BackedPool.StoreNotLinked.selector); p2.startAuction(0);
        vm.prank(alice); vm.expectRevert(BackedPool.StoreNotLinked.selector); p2.redeem(0);
    }

    // ───────── money safety ─────────
    function test_RefundReentrancyBlocked() public {
        NastyBackedBidder nb = new NastyBackedBidder(pool);
        vm.deal(address(nb), 10 ether);
        _fill();
        vm.prank(whale); pool.back{value: 0.1 ether}(0);
        _start(0, 1 ether);
        nb.bid{value: 1 ether}(0);
        nb.setRefuse(true);
        vm.prank(bidder); pool.bid{value: 2 ether}(0); // a refuser can't block: refunds are pulled
        nb.setRefuse(false);
        vm.expectRevert(BackedPool.TransferFailed.selector);
        nb.pull(true);
        nb.pull(false);
        assertEq(address(nb).balance, 11 ether);
    }

    function test_EthConservation() public {
        _fill();
        vm.prank(whale); pool.back{value: 1 ether}(0);
        vm.prank(whale2); pool.back{value: 0.5 ether}(0);
        _start(0, 1 ether);
        vm.prank(bidder); pool.bid{value: 1.5 ether}(0);
        _end(0); pool.settle(0);
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
}
