// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BackedPool} from "../src/BackedPool.sol";
import {BackedStore} from "../src/BackedStore.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";
import {deployBacked} from "./BackedPool.t.sol";

/// Treasury backing (closes internal audit M-1): the store's 75% share of fees can back batches
/// and always finds its way back, as a Statement or as ETH.
contract BackedStoreTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; BackedPool pool; BackedStore store;
    address treasury = makeAddr("bs-fees");
    address alice = makeAddr("bs-alice"); address bob = makeAddr("bs-bob"); address carol = makeAddr("bs-carol");
    address whale = makeAddr("bs-whale"); address bidder = makeAddr("bs-bidder");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        pool = deployBacked(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, treasury);
        store = BackedStore(payable(address(pool.store())));
        address[5] memory us = [alice, bob, carol, whale, bidder];
        for (uint256 i; i < 5; ++i) {
            vm.deal(us[i], 100 ether);
            vm.prank(us[i]); credits.setApprovalForAll(address(pool), true);
        }
        // Fund the treasury: the real path (deposit fees swept 75% to the store) plus a test top-up
        // to round numbers.
        for (uint256 i; i < 4; ++i) _deposit(carol, 10);
        pool.sweepFees();
        assertGt(store.treasuryBalance(), 0);
        vm.deal(address(store), 30 ether);
        assertEq(store.treasuryBalance(), 30 ether);
    }

    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _deposit(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(who); pool.deposit{value: fee}(ids);
    }
    /// Batch 0 already holds carol's 40; alice 40 fills it.
    function _fill() internal returns (uint256[] memory a) { a = _deposit(alice, 40); }
    function _state(uint256 b) internal view returns (BackedPool.BatchState s) { (s,,,,,,) = pool.batchInfo(b); }
    function _end(uint256 b) internal { (,,, uint64 e) = pool.auctions(b); vm.warp(e); }
    function _votes(uint256 price) internal {
        vm.prank(alice); pool.setReserve(0, price);
        vm.prank(carol); pool.setReserve(0, price);
    }

    function test_TreasuryBacksAndWinsStatementThenListsForPoints() public {
        _fill(); _votes(1 ether);
        store.backBatch(0, 1 ether, 1 ether);
        assertEq(store.treasuryBalance(), 29 ether);
        pool.startAuction(0, 1 ether);
        _end(0); pool.settle(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), address(store)); // the treasury won: Statement in the store
        store.list(sid, 10);                           // and it goes up for SCREDIT
        uint256 bf = store.bidFee(); // read before the prank
        vm.prank(alice); store.bid{value: bf}(sid, 80); // alice earned 80 points at burn
        vm.warp(block.timestamp + 1 days);
        store.settle(sid);
        assertEq(stmts.ownerOf(sid), alice);
        // depositors were paid the treasury's 1 ETH
        uint256 a0 = alice.balance; vm.prank(alice); pool.claim(0); assertEq(alice.balance - a0, 0.5 ether);
    }

    function test_OutbidTreasuryGetsEveryWeiBack() public {
        _fill(); _votes(1 ether);
        store.backBatch(0, 1 ether, 1 ether);
        pool.startAuction(0, 1 ether);
        vm.prank(bidder); pool.bid{value: 2 ether}(0);
        assertEq(store.treasuryBalance(), 29 ether);
        vm.prank(whale); store.collectRefund(); // anyone can pull it home
        assertEq(store.treasuryBalance(), 30 ether);
        _end(0); pool.settle(0);
        (,,, uint256 sid,,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), bidder);
    }

    function test_ExpiredAndUnwoundRoundsRefundTheTreasury() public {
        _fill(); // no votes → no majority minimum → decide window
        store.backBatch(0, 1 ether, 1 ether);
        pool.startAuction(0, 1 ether);
        _end(0); pool.settle(0);
        (,,, uint64 e) = pool.auctions(0); vm.warp(e);
        pool.expire(0);
        store.collectRefund();
        assertEq(store.treasuryBalance(), 30 ether);
        // again, but the assembly fails at the accepting step: everything unwinds, treasury refunded
        store.backBatch(0, 1 ether, 1 ether);
        pool.startAuction(0, 1 ether);
        _end(0); pool.settle(0);
        (,,,,, uint64 r,) = pool.batchInfo(0);
        stmts.setCap(0);
        vm.prank(alice); pool.acceptBid(0, r, address(store), 1 ether);
        vm.prank(carol); pool.acceptBid(0, r, address(store), 1 ether);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        store.collectRefund();
        assertEq(store.treasuryBalance(), 30 ether);
        assertEq(credits.balanceOf(address(pool)), 80);
    }

    function test_UnbackReturnsToTreasury() public {
        _fill();
        store.backBatch(0, 2 ether, 2 ether);
        store.backBatch(0, 1 ether, 3 ether); // top up
        store.unbackBatch(0);
        assertEq(store.treasuryBalance(), 30 ether);
        (uint256 amt,) = pool.backings(0, address(store));
        assertEq(amt, 0);
    }

    function test_EvictedTreasuryBackingComesBack() public {
        _fill();
        store.backBatch(0, 0.1 ether, 0.1 ether);
        for (uint256 i; i < 10; ++i) {
            address x = makeAddr(string.concat("bs-backer", vm.toString(i)));
            vm.deal(x, 1 ether);
            vm.prank(x); pool.back{value: 0.2 ether}(0);
        }
        assertEq(pool.pendingReturns(address(store)), 0.1 ether);
        store.collectRefund();
        assertEq(store.treasuryBalance(), 30 ether);
    }

    // ───────── limits ─────────
    function test_NeverAboveDepositorsMinimum() public {
        _fill(); _votes(1 ether);
        vm.expectRevert(BackedStore.AboveMinimum.selector);
        store.backBatch(0, 1.5 ether, 1.5 ether);
        store.backBatch(0, 1 ether, 1 ether);
        vm.expectRevert(BackedStore.AboveMinimum.selector);
        store.backBatch(0, 1, 1 ether + 1);
    }

    function test_CapAndBalance() public {
        _fill();
        vm.expectRevert(BackedStore.OverCap.selector);
        store.backBatch(0, 6 ether, 6 ether); // cap 5 ether per batch
        store.setMaxTreasuryBid(50 ether);    // raise: only after 3 days
        vm.expectRevert(BackedStore.OverCap.selector);
        store.backBatch(0, 6 ether, 6 ether);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(BackedStore.OverCap.selector);
        store.backBatch(0, 31 ether, 31 ether); // more than the treasury holds
        store.backBatch(0, 6 ether, 6 ether);
    }

    function test_PinnedTotal() public {
        _fill();
        store.backBatch(0, 1 ether, 1 ether);
        vm.expectRevert(BackedStore.PriceMoved.selector);
        store.backBatch(0, 1 ether, 1 ether); // owner thought it was the first backing
    }

    function test_OnlyFullAndNotSoleHolder() public {
        vm.expectRevert(BackedStore.NotFull.selector);
        store.backBatch(0, 1 ether, 1 ether); // batch 0 is still filling (carol's 40)
        _fill();
        _deposit(bob, 80); // batch 1: bob alone
        vm.expectRevert(BackedStore.NotDepositor.selector);
        store.backBatch(1, 1 ether, 1 ether);
    }

    function test_OnlyOwner() public {
        _fill();
        vm.prank(whale); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, whale));
        store.backBatch(0, 1 ether, 1 ether);
        vm.prank(whale); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, whale));
        store.unbackBatch(0);
    }

    function test_StaleTreasuryBackingReconfirmedByTopUp() public {
        uint256[] memory a = _fill();
        store.backBatch(0, 1 ether, 1 ether);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        _deposit(bob, 1); // spills? no: open batch is 1; refill batch 0 explicitly
        uint256[] memory fresh = _give(bob, 1);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(bob); pool.depositInto{value: fee}(0, fresh, 79);
        (, uint256 best) = pool.bestBacking(0);
        assertEq(best, 0);                     // stale: can't open an auction
        store.backBatch(0, 1, 1 ether + 1);    // re-confirm
        (, best) = pool.bestBacking(0);
        assertEq(best, 1 ether + 1);
    }

    function test_EthOnlyFromPool() public {
        vm.deal(whale, 1 ether);
        vm.prank(whale);
        (bool ok,) = address(store).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /// Every wei of fees that reached the store is either in the treasury, out as a live backing or
    /// bid, or waiting in the pool for collectRefund.
    function test_TreasuryConservation() public {
        _fill(); _votes(1 ether);
        store.backBatch(0, 1 ether, 1 ether);
        pool.startAuction(0, 1 ether);
        vm.prank(bidder); pool.bid{value: 1.05 ether}(0);
        uint256 out = pool.pendingReturns(address(store));
        assertEq(store.treasuryBalance() + out, 30 ether);
    }
}
