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
        store.buyUnsold(b, reserve);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);
        assertEq(stmts.ownerOf(sid), address(store));
    }
    function _fillOpen(address who) internal {
        (, uint256 filled,,,,) = pool.batchInfo(pool.openBatchId());
        _deposit(who, 80 - filled);
    }
    function _fundTreasury() internal {
        _deposit(carol, 5); // $10 of fees
        pool.sweepFees();   // 75% of it (0.003 ETH) lands in the treasury
    }

    // ───────────────────────── points ─────────────────────────

    // Points arrive when the batch fills: 2 per Credit each depositor has in it.
    function test_PointsAreTwoPerCreditWhenBatchFills() public {
        _deposit(alice, 1); _deposit(alice, 2); _deposit(bob, 5);
        assertEq(store.totalSupply(), 0);               // nothing yet: the batch is still filling
        _deposit(carol, 72);                            // fills it: 3 + 5 + 72 = 80
        assertEq(store.balanceOf(alice), 6);
        assertEq(store.balanceOf(bob), 10);
        assertEq(store.balanceOf(carol), 144);
        assertEq(store.totalSupply(), 160);
        _deposit(alice, 30);                            // next batch: not full, no points yet
        assertEq(store.balanceOf(alice), 6);
    }

    // Worst case for the award loop: 80 different depositors, the last deposit fills the batch.
    function test_FillAwardGas_80Depositors() public {
        for (uint256 i; i < 79; ++i) {
            address u = address(uint160(0x10000 + i));
            vm.deal(u, 1 ether);
            vm.prank(u); credits.setApprovalForAll(address(pool), true);
            _deposit(u, 1);
        }
        vm.deal(address(0x20000), 1 ether);
        vm.prank(address(0x20000)); credits.setApprovalForAll(address(pool), true);
        uint256[] memory one = new uint256[](1);
        credits.mint(address(0x20000), nextId); one[0] = nextId++;
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(address(0x20000));
        uint256 g = gasleft();
        pool.deposit{value: fee}(one);
        uint256 used = g - gasleft();
        emit log_named_uint("filling deposit with 80 depositors, gas", used);
        assertLt(used, 3_000_000);
        assertEq(store.totalSupply(), 160);
        assertEq(store.balanceOf(address(0x20000)), 2);
    }

    // Audit fix: deposit → withdraw loops used to mint points for $0.50 each with nothing pooled.
    function test_DepositWithdrawLoopEarnsNoPoints() public {
        for (uint256 k; k < 5; ++k) {
            _deposit(eve, 6);
            uint256[] memory ids = new uint256[](6);
            for (uint256 i; i < 6; ++i) ids[i] = nextId - 6 + i;
            vm.prank(eve); pool.withdraw(ids);
        }
        assertEq(store.balanceOf(eve), 0);
        assertEq(store.totalSupply(), 0);
    }

    function test_PointsCannotMove() public {
        _deposit(alice, 40); _deposit(bob, 40);
        vm.startPrank(alice);
        vm.expectRevert(CreditStore.NonTransferable.selector); store.transfer(bob, 1);
        vm.expectRevert(CreditStore.NonTransferable.selector); store.approve(bob, 1);
        vm.expectRevert(CreditStore.NonTransferable.selector); store.transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(store.allowance(alice, bob), 0);
        assertEq(store.balanceOf(alice), 80);
    }

    function test_OnlyPoolAwards() public {
        address[] memory to = new address[](1); to[0] = eve;
        uint256[] memory pts = new uint256[](1); pts[0] = 1_000_000;
        vm.prank(eve); vm.expectRevert(CreditStore.NotPool.selector);
        store.award(to, pts);
    }

    // Audit fix: the store refuses to link to a pool that doesn't point back at it.
    function test_StoreRefusesWrongPool() public {
        CreditStore fresh = new CreditStore(0);
        vm.expectRevert(CreditStore.WrongPool.selector);
        fresh.setPool(address(pool)); // pool.store() is the original store
    }

    function test_FeeRecipientCantBeTheStore() public {
        vm.expectRevert(CreditPool.ZeroAddress.selector);
        pool.setFeeRecipient(address(store));
    }

    function test_PoolLinkIsOneTime() public {
        vm.expectRevert(CreditStore.PoolAlreadySet.selector);
        store.setPool(address(0xBEEF));
        CreditStore fresh = new CreditStore(0);
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
        store.buyUnsold(b, 1 ether);
        pool.startAuction(b); // a live FIRST auction (never unsold): still off limits
        vm.expectRevert(CreditStore.NotUnsold.selector);
        store.buyUnsold(b, 1 ether);
    }

    function test_TreasuryBuysUnsoldAtDepositorsMinimum() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        store.buyUnsold(b, 0.001 ether);
        (address hb, uint256 hbid, uint256 reserve,) = pool.auctions(b);
        assertEq(hb, address(store));
        assertEq(hbid, reserve);
        assertEq(hbid, 0.001 ether);
    }

    function test_OnlyOwnerTriggersTreasury() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(eve); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        store.buyUnsold(b, 1 ether);
    }

    // Audit fix (M-1): depositors raising their votes before the purchase lands can't make the
    // treasury overpay; the owner's price limit reverts it.
    function test_FrontRunRaisingReserveReverts() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(alice); pool.setReserve(b, 0.002 ether);   // front-run: both raise
        vm.prank(bob); pool.setReserve(b, 0.002 ether);
        vm.expectRevert(CreditStore.PriceMoved.selector);
        store.buyUnsold(b, 0.001 ether);
    }

    // Audit fix (M-1): a live auction someone started at a higher minimum can't make it overpay.
    function test_RestartedAuctionAtHigherMinimumReverts() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(alice); pool.setReserve(b, 0.002 ether);
        vm.prank(bob); pool.setReserve(b, 0.002 ether);
        pool.startAuction(b);
        vm.expectRevert(CreditStore.PriceMoved.selector);
        store.buyUnsold(b, 0.001 ether);
    }

    // Verify R1: restarting the auction first can't lock the treasury out; it opens the bidding
    // in that no-bid auction at the same majority minimum.
    function test_RestartedAuctionStillBuyable() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(eve); pool.startAuction(b);                 // griefer restarts it first
        store.buyUnsold(b, 0.001 ether);
        (address hb, uint256 hbid,,) = pool.auctions(b);
        assertEq(hb, address(store)); assertEq(hbid, 0.001 ether);
    }

    // It never bids against a bidder, and never after a live auction ended.
    function test_NeverCompetesWithABidder() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        pool.startAuction(b);
        vm.prank(eve); pool.bid{value: 0.001 ether}(b);
        vm.expectRevert(CreditStore.AlreadyBid.selector);
        store.buyUnsold(b, 1 ether);
    }

    function test_ConstructorRejectsStoreAsFeeRecipient() public {
        address st = address(store);
        vm.expectRevert(CreditPool.ZeroAddress.selector);
        new CreditPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, st, st);
    }

    // After 30 days one low vote can't block the treasury or cheapen it: the auction may open at
    // the lowest single vote, but the treasury always bids the majority price.
    function test_After30DaysPaysMajorityNotLowestVote() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.002 ether);
        vm.prank(bob); pool.setReserve(b, 0.0001 ether);     // one low vote (bob: 35 slots, alice 40 + carol 5 unvoted)
        vm.prank(alice); pool.setReserve(b, 0.002 ether);
        vm.warp(block.timestamp + 31 days);
        assertTrue(pool.noReserveOpen(b));
        uint256 majority = pool.currentReserve(b);
        assertEq(majority, 0.002 ether);
        store.buyUnsold(b, majority);
        (address hb, uint256 hbid, uint256 reserve,) = pool.auctions(b);
        assertEq(hb, address(store));
        assertEq(hbid, 0.002 ether);                         // majority price, not 0.0001
        assertEq(reserve, 0.0001 ether);                      // the auction itself opened at the fallback
    }

    // In a live auction the treasury pays the price that auction opened at, and only within
    // the owner's limit; later vote changes don't move it.
    function test_LiveAuctionPaysItsOpeningPrice() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(alice); pool.setReserve(b, 0.002 ether);
        vm.prank(bob); pool.setReserve(b, 0.002 ether);
        pool.startAuction(b);                                 // opens at 0.002
        vm.prank(alice); pool.setReserve(b, 0.001 ether);   // votes drop afterwards
        vm.prank(bob); pool.setReserve(b, 0.001 ether);
        vm.expectRevert(CreditStore.PriceMoved.selector);   // above the owner's limit
        store.buyUnsold(b, 0.001 ether);
        store.buyUnsold(b, 0.002 ether);
        (, uint256 hbid,,) = pool.auctions(b);
        assertEq(hbid, 0.002 ether);
    }

    // Verify2 #2: raising votes after a live auction opened can't push the treasury up.
    function test_VoteRaiseAfterOpenDoesntRaiseTreasuryBid() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        pool.startAuction(b);                                 // opens at 0.001
        vm.prank(alice); pool.setReserve(b, 0.0025 ether);  // majority raises after the open
        vm.prank(bob); pool.setReserve(b, 0.0025 ether);
        store.buyUnsold(b, 1 ether);                         // even with a loose limit
        (address hb, uint256 hbid,,) = pool.auctions(b);
        assertEq(hb, address(store));
        assertEq(hbid, 0.001 ether);                          // the price it opened at
    }

    function test_NoVotesNoPurchase() public {
        _fundTreasury();
        (uint256 b,) = _unsold(0.001 ether);
        vm.prank(alice); pool.setReserve(b, 0);
        vm.prank(bob); pool.setReserve(b, 0);
        vm.expectRevert(CreditPool.ReserveQuorumNotMet.selector);
        store.buyUnsold(b, 1 ether);
    }

    // Audit fix (M-2): raising the cap takes 3 days; lowering is immediate.
    function test_CapRaiseIsDelayed() public {
        assertEq(store.maxTreasuryBid(), 5 ether);
        store.setMaxTreasuryBid(100 ether);
        assertEq(store.maxTreasuryBid(), 5 ether);
        vm.warp(block.timestamp + 3 days - 1);
        assertEq(store.maxTreasuryBid(), 5 ether);
        vm.warp(block.timestamp + 1);
        assertEq(store.maxTreasuryBid(), 100 ether);
        store.setMaxTreasuryBid(1 ether);                    // lowering: at once, cancels nothing pending
        assertEq(store.maxTreasuryBid(), 1 ether);
        store.setMaxTreasuryBid(2 ether);
        store.setMaxTreasuryBid(0.5 ether);                  // lowering cancels a pending raise
        vm.warp(block.timestamp + 4 days);
        assertEq(store.maxTreasuryBid(), 0.5 ether);
    }

    function test_TreasuryCapAndBalanceHold() public {
        _fundTreasury(); // 0.003 ETH treasury
        (uint256 b,) = _unsold(0.01 ether);
        vm.expectRevert(CreditStore.OverCap.selector); // over the treasury balance
        store.buyUnsold(b, 1 ether);
        store.setMaxTreasuryBid(0.0001 ether);
        (uint256 b2,) = _unsold(0.001 ether);
        vm.expectRevert(CreditStore.OverCap.selector); // over the cap
        store.buyUnsold(b2, 1 ether);
    }

    function test_TreasuryOnlyOpens_AnyoneCanOutbid_RefundComesBack() public {
        _fundTreasury();
        (uint256 b, uint256 sid) = _unsold(0.001 ether);
        uint256 t0 = store.treasuryBalance();
        store.buyUnsold(b, 0.001 ether);
        assertEq(store.treasuryBalance(), t0 - 0.001 ether);
        vm.expectRevert(CreditStore.AlreadyBid.selector); // it never raises its own bid
        store.buyUnsold(b, 1 ether);
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
        _fundTreasury(); // (goes into the next batch, not alice's)
        vm.expectRevert(CreditPool.NotDepositor.selector);
        store.buyUnsold(b, 1 ether);
    }

    // ───────────────────────── store auction ─────────────────────────

    function test_StoreAuction_FullFlow() public {
        uint256 sid = _storeOwns(0.001 ether);
        // alice and bob hold 80 points each from the batch _storeOwns filled
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
        r.approveAndDeposit(pool, ids);
        _fillOpen(alice);                                // its batch fills → 2 points
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
        assertEq(store.balanceOf(address(store)), held);  // escrow lives in the store's own balance
        uint256 sum = store.balanceOf(alice) + store.balanceOf(bob) + store.balanceOf(carol) + store.balanceOf(address(store));
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
