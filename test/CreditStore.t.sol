// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditStore} from "../src/CreditStore.sol";
import {deployPool} from "./DeployPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

/// SCREDIT points, the fee split, the treasury's buy-unsold rule, and the SCREDIT store auction.
contract CreditStoreTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool; CreditStore store;
    address platform = makeAddr("platform");
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address carol = makeAddr("carol");
    address eve = makeAddr("eve");
    uint256 nextId = 1;
    uint256 constant USD = 0.0004 ether; // $1 at $2,500 ETH

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, platform);
        store = CreditStore(payable(address(pool.store())));
        store.setMaxTreasuryBid(5 ether);
        address[4] memory us = [alice, bob, carol, eve];
        for (uint256 i; i < 4; ++i) {
            vm.deal(us[i], 1000 ether);
            vm.prank(us[i]); credits.setApprovalForAll(address(pool), true);
        }
    }

    function _deposit(address who, uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(who, nextId); ids[i] = nextId++; }
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(who); pool.deposit{value: fee}(ids);
    }
    /// Batch 0 split 40 / 40 between alice and bob, assembled, both voting `reserve`.
    function _assembledBatch(uint256 reserve) internal returns (uint256 b, uint256 sid) {
        b = pool.openBatchId();
        _deposit(alice, 40); _deposit(bob, 40);
        pool.assemble(b);
        (,,, sid,,) = pool.batchInfo(b);
        vm.prank(alice); pool.setReserve(b, reserve);
        vm.prank(bob); pool.setReserve(b, reserve);
    }
    /// Run one pool auction with no bids, so the batch counts as unsold.
    function _unsold(uint256 reserve) internal returns (uint256 b, uint256 sid) {
        (b, sid) = _assembledBatch(reserve);
        pool.startAuction(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);
        assertEq(pool.unsoldAuctions(b), 1);
    }
    /// The treasury buys batch b's Statement uncontested and lists it for SCREDIT.
    function _storeOwns(uint256 reserve) internal returns (uint256 sid) {
        _fundTreasury();
        uint256 b;
        (b, sid) = _unsold(reserve);
        store.buyUnsold(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);
        assertEq(stmts.ownerOf(sid), address(store));
    }
    function _fundTreasury() internal {
        _deposit(carol, 5); // $10 of fees
        pool.sweepFees();   // 75% of it (0.003 ETH) lands in the treasury
    }

    // ───────────────────────── points ─────────────────────────

    function test_PointsAreTwoPerCredit() public {
        _deposit(alice, 1); assertEq(store.balanceOf(alice), 2);
        _deposit(alice, 2); assertEq(store.balanceOf(alice), 2 + 4);
        _deposit(bob, 5);   assertEq(store.balanceOf(bob), 10);
        _deposit(carol, 6); assertEq(store.balanceOf(carol), 12); // bulk fee doesn't change points
        assertEq(store.totalSupply(), 28);
    }

    function test_PointsKeptAfterWithdraw_ButFeeIsTheirCost() public {
        _deposit(alice, 3);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        vm.prank(alice); pool.withdraw(ids);
        assertEq(store.balanceOf(alice), 6); // earned by paying the $2 fee, which isn't refunded
    }

    function test_PointsCannotMove() public {
        _deposit(alice, 5);
        vm.startPrank(alice);
        vm.expectRevert(CreditStore.NonTransferable.selector); store.transfer(bob, 1);
        vm.expectRevert(CreditStore.NonTransferable.selector); store.approve(bob, 1);
        vm.expectRevert(CreditStore.NonTransferable.selector); store.transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(store.allowance(alice, bob), 0);
        assertEq(store.balanceOf(alice), 10);
    }

    function test_OnlyPoolAwards() public {
        vm.prank(eve); vm.expectRevert(CreditStore.NotPool.selector);
        store.award(eve, 1_000_000);
    }

    function test_PoolLinkIsOneTime() public {
        vm.expectRevert(CreditStore.PoolAlreadySet.selector);
        store.setPool(address(0xBEEF));
        CreditStore fresh = new CreditStore();
        vm.prank(eve); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        fresh.setPool(address(pool));
    }

    // ───────────────────────── fees ─────────────────────────

    function test_SweepSplits25To75() public {
        _deposit(alice, 3); // $6
        _deposit(bob, 10);  // $10
        pool.sweepFees();
        assertEq(platform.balance, 16 * USD / 4);
        assertEq(store.treasuryBalance(), 16 * USD * 3 / 4);
        assertEq(address(pool).balance, 0);
    }

    function test_NoSaleFee() public {
        (uint256 b,) = _assembledBatch(1 ether);
        pool.startAuction(b);
        vm.prank(eve); pool.bid{value: 2 ether}(b);
        vm.warp(block.timestamp + 25 hours);
        uint256 feesBefore = pool.accruedFees();
        pool.settle(b);
        assertEq(pool.accruedFees(), feesBefore);
        uint256 a0 = alice.balance;
        vm.prank(alice); pool.claim(b);
        assertEq(alice.balance - a0, 1 ether); // 40/80 of the full 2 ETH
    }

    function test_StoreOnlyAcceptsEthFromPool() public {
        vm.prank(eve); (bool ok,) = address(store).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ───────────────────────── treasury: buy unsold ─────────────────────────

    function test_TreasuryCannotBidOnFreshBatch() public {
        _fundTreasury();
        (uint256 b,) = _assembledBatch(0.001 ether);
        vm.expectRevert(CreditStore.NotUnsold.selector);
        store.buyUnsold(b);
        pool.startAuction(b); // a live first auction: still off limits
        vm.expectRevert(CreditStore.NotUnsold.selector);
        store.buyUnsold(b);
    }

    function test_TreasuryBuysUnsoldAtDepositorsMinimum() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        store.buyUnsold(b);
        (address hb, uint256 hbid, uint256 reserve,) = pool.auctions(b);
        assertEq(hb, address(store));
        assertEq(hbid, reserve);
        assertEq(hbid, 0.001 ether);
    }

    function test_OnlyOwnerTriggersTreasury() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(eve); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        store.buyUnsold(b);
    }

    function test_TreasuryCapAndBalanceHold() public {
        _fundTreasury(); // 0.003 ETH treasury
        (uint256 b,) = _unsold(0.01 ether);
        vm.expectRevert(CreditStore.OverCap.selector); // over the treasury balance
        store.buyUnsold(b);
        store.setMaxTreasuryBid(0.0001 ether);
        (uint256 b2,) = _unsold(0.001 ether);
        vm.expectRevert(CreditStore.OverCap.selector); // over the cap
        store.buyUnsold(b2);
    }

    function test_TreasuryOnlyOpens_AnyoneCanOutbid_RefundComesBack() public {
        _fundTreasury();
        (uint256 b, uint256 sid) = _unsold(0.001 ether);
        uint256 t0 = store.treasuryBalance();
        store.buyUnsold(b);
        assertEq(store.treasuryBalance(), t0 - 0.001 ether);
        vm.expectRevert(CreditStore.AlreadyBid.selector); // it never raises its own bid
        store.buyUnsold(b);
        vm.prank(eve); pool.bid{value: 0.002 ether}(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);
        assertEq(stmts.ownerOf(sid), eve);
        store.collectRefund();
        assertEq(store.treasuryBalance(), t0);
    }

    function test_TreasuryCantForceSoleHolder() public {
        uint256 b = pool.openBatchId();
        _deposit(alice, 80);
        pool.assemble(b);
        vm.prank(alice); pool.setReserve(b, 0.001 ether);
        vm.prank(alice); pool.startAuction(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b); // unsold, but alice alone holds it
        vm.expectRevert(CreditPool.NotDepositor.selector);
        store.buyUnsold(b);
    }

    // ───────────────────────── store auction ─────────────────────────

    function test_StoreAuction_FullFlow() public {
        uint256 sid = _storeOwns(0.001 ether);
        _deposit(alice, 10); _deposit(bob, 10); // +20 points each
        uint256 a0 = store.balanceOf(alice); uint256 b0 = store.balanceOf(bob);
        store.list(sid, 5);
        uint256 fee = store.bidFee();
        assertEq(fee, USD / 4);                             // $0.25

        vm.prank(alice); vm.expectRevert(CreditStore.InsufficientFee.selector);
        store.bid{value: fee - 1}(sid, 5);
        vm.prank(alice); vm.expectRevert(CreditStore.BidTooLow.selector);
        store.bid{value: fee}(sid, 4);
        vm.prank(alice); store.bid{value: 1 ether}(sid, 5);   // excess ETH refunded
        assertEq(store.balanceOf(alice), a0 - 5);             // 5 held while leading
        vm.prank(bob); vm.expectRevert(CreditStore.BidTooLow.selector);
        store.bid{value: fee}(sid, 5);
        vm.prank(bob); store.bid{value: fee}(sid, 6);
        assertEq(store.balanceOf(alice), a0);                 // outbid: points back
        assertEq(store.balanceOf(bob), b0 - 6);
        vm.prank(bob); vm.expectRevert(CreditStore.InsufficientPoints.selector);
        store.bid{value: fee}(sid, b0 + 1);

        vm.expectRevert(CreditStore.AuctionLive.selector);
        store.settle(sid);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice); vm.expectRevert(CreditStore.AuctionOver.selector);
        store.bid{value: fee}(sid, 7);
        uint256 supply = store.totalSupply();
        store.settle(sid);
        assertEq(stmts.ownerOf(sid), bob);
        assertEq(store.totalSupply(), supply - 6);            // winner's points burned
        assertEq(store.balanceOf(bob), b0 - 6);

        assertEq(store.bidFees(), 2 * fee);
        uint256 p0 = platform.balance;
        vm.prank(eve); store.sweepBidFees();
        assertEq(platform.balance - p0, 2 * fee);
    }

    function test_StoreAuction_AntiSnipeAndSelfRaise() public {
        uint256 sid = _storeOwns(0.001 ether);
        _deposit(alice, 10);
        uint256 a0 = store.balanceOf(alice);
        store.list(sid, 1);
        (,,, uint64 endsAt) = store.listings(sid);
        vm.warp(endsAt - 1 minutes);
        uint256 fee = store.bidFee();
        vm.prank(alice); store.bid{value: fee}(sid, 3);
        vm.prank(alice); store.bid{value: fee}(sid, 8);       // raising your own bid re-escrows
        assertEq(store.balanceOf(alice), a0 - 8);
        (,,, uint64 newEnd) = store.listings(sid);
        assertEq(newEnd, block.timestamp + 15 minutes);
    }

    function test_StoreAuction_NoBidsKeepsStatement() public {
        uint256 sid = _storeOwns(0.001 ether);
        store.list(sid, 1);
        vm.warp(block.timestamp + 25 hours);
        store.settle(sid);
        assertEq(stmts.ownerOf(sid), address(store));
        store.list(sid, 1); // can relist
    }

    function test_StoreAuction_Guards() public {
        uint256 sid = _storeOwns(0.001 ether);
        vm.expectRevert(); // doesn't exist: the Statements contract itself refuses
        store.list(999, 1);
        vm.prank(eve); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        store.list(sid, 1);
        store.list(sid, 1);
        vm.expectRevert(CreditStore.AuctionLive.selector);
        store.list(sid, 1);
        vm.prank(eve); vm.expectRevert(CreditStore.NotListed.selector);
        store.bid(12345, 1);
    }

    function test_BidFeesNeverCountAsTreasury() public {
        uint256 sid = _storeOwns(0.001 ether);
        _deposit(alice, 10);
        uint256 t0 = store.treasuryBalance();
        store.list(sid, 1);
        uint256 fee = store.bidFee(); // read first: a call inside the args would use up the prank
        vm.prank(alice); store.bid{value: fee}(sid, 1);
        assertEq(store.treasuryBalance(), t0);
        assertEq(address(store).balance, t0 + store.bidFees());
    }

    function test_CantListSomeoneElsesStatement() public {
        (uint256 b, uint256 sid) = _assembledBatch(0.001 ether);
        pool.startAuction(b);
        vm.prank(eve); pool.bid{value: 0.001 ether}(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b); // eve owns it now
        vm.expectRevert(CreditStore.NotHeld.selector);
        store.list(sid, 1);
    }

    function test_BidRefundCantReenter() public {
        uint256 sid = _storeOwns(0.001 ether);
        StoreReenterer r = new StoreReenterer(store, sid);
        vm.deal(address(r), 1 ether);
        credits.mint(address(r), 9_999);
        uint256[] memory ids = new uint256[](1); ids[0] = 9_999;
        r.approveAndDeposit(pool, ids);                  // 2 points
        store.list(sid, 1);
        r.bid(1, 0.5 ether);                             // excess refund → tries to re-enter bid and settle
        assertTrue(r.attempted());
        assertFalse(r.reentered());
        (address hb, uint256 hbid,,) = store.listings(sid);
        assertEq(hb, address(r)); assertEq(hbid, 1);
    }

    /// Points are conserved: supply = spendable balances + points escrowed in live bids.
    function testFuzz_PointsConserved(uint8 a, uint8 b, uint8 bidA, uint8 bidB) public {
        uint256 sid = _storeOwns(0.001 ether);
        uint256 na = bound(a, 1, 40); uint256 nb = bound(b, 1, 40);
        _deposit(alice, na); _deposit(bob, nb);
        store.list(sid, 1);
        uint256 fee = store.bidFee();
        uint256 pa = bound(bidA, 1, na * 2);
        vm.prank(alice); store.bid{value: fee}(sid, pa);
        uint256 pb = bound(bidB, 1, nb * 2);
        vm.prank(bob); try store.bid{value: fee}(sid, pb) {} catch {}
        (, uint256 held,,) = store.listings(sid);
        uint256 sum = store.balanceOf(alice) + store.balanceOf(bob) + store.balanceOf(carol) + held;
        assertEq(store.totalSupply(), sum);
    }
}

contract StoreReenterer {
    CreditStore store; uint256 sid;
    bool public attempted; bool public reentered;
    constructor(CreditStore s, uint256 id) { store = s; sid = id; }
    function approveAndDeposit(CreditPool pool, uint256[] calldata ids) external {
        pool.credits().setApprovalForAll(address(pool), true);
        pool.deposit{value: pool.depositFeeFor(ids.length)}(ids);
    }
    function bid(uint256 points, uint256 value) external { store.bid{value: value}(sid, points); }
    receive() external payable {
        if (attempted || msg.sender != address(store)) return;
        attempted = true;
        uint256 fee = store.bidFee();
        try store.bid{value: fee}(sid, 2) { reentered = true; } catch {}
        try store.settle(sid) { reentered = true; } catch {}
    }
}
