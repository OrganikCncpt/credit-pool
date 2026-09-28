// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {deployPool} from "./DeployPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

contract CreditPoolTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address carol = makeAddr("carol");
    address whale = makeAddr("whale"); address bidder1 = makeAddr("b1"); address bidder2 = makeAddr("b2");
    uint256 nextId = 1;
    uint256 opensAt;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8); // $2,500 ETH
        opensAt = block.timestamp + 8 days;
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), opensAt, treasury);
        for (uint256 i; i < 6; ++i) {
            address u = [alice, bob, carol, whale, bidder1, bidder2][i];
            vm.deal(u, 100 ether);
            vm.prank(u); credits.setApprovalForAll(address(pool), true);
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
    function _fillBatch0() internal {
        _deposit(alice, 40); _deposit(bob, 30); _deposit(carol, 10);
    }

    function test_FeeIsOneDollar() public view {
        assertEq(pool.usdWei(), 0.0004 ether); // $1 / $2500
    }

    function test_ExcessFeeRefunded_FeesSwept() public {
        uint256[] memory ids = _give(alice, 3);
        uint256 before = alice.balance;
        vm.prank(alice); pool.deposit{value: 1 ether}(ids);
        assertEq(before - alice.balance, 0.0024 ether); // $2 per Credit × 3 (under the 6-Credit bulk rate)
        pool.sweepFees();
        assertEq(treasury.balance, 0.0006 ether);                 // 25% to the platform
        assertEq(address(pool.store()).balance, 0.0018 ether);    // 75% to the store's treasury
    }

    function test_RevertUnderpaidFee() public {
        uint256[] memory ids = _give(alice, 1);
        vm.prank(alice); vm.expectRevert(CreditPool.InsufficientFee.selector);
        pool.deposit{value: 0.0003 ether}(ids);
    }

    function test_StaleOracleUsesFallbackFee() public {
        uint256 live = pool.usdWei();
        assertEq(pool.fallbackFeeWei(), live);              // frozen at deploy: $1 at the deploy price
        feed.set(5000e8, block.timestamp - 2 days);         // stale, even though the price changed
        assertTrue(pool.feeUsesFallback());
        assertEq(pool.usdWei(), live);                  // fallback, not the stale price
    }

    function test_OverflowIntoNextBatch() public {
        _deposit(alice, 75);
        _deposit(bob, 10);
        (CreditPool.BatchState s0, uint256 f0,,,,) = pool.batchInfo(0);
        (, uint256 f1,,,,) = pool.batchInfo(1);
        assertEq(uint8(s0), uint8(CreditPool.BatchState.Full));
        assertEq(f0, 80); assertEq(f1, 5);
        assertEq(pool.slots(0, bob), 5); assertEq(pool.slots(1, bob), 5);
        assertEq(pool.openBatchId(), 1);
    }

    function test_WithdrawFromFillingBatch() public {
        uint256[] memory ids = _deposit(alice, 10);
        uint256[] memory some = new uint256[](4);
        for (uint256 i; i < 4; ++i) some[i] = ids[i * 2];
        vm.prank(alice); pool.withdraw(some);
        (, uint256 filled, uint256 deps,,,) = pool.batchInfo(0);
        assertEq(filled, 6); assertEq(deps, 1);
        assertEq(credits.ownerOf(ids[0]), alice);
        vm.prank(alice); pool.withdraw(_slice(ids, [uint256(1),3,5,7,8,9]));
        (, filled, deps,,,) = pool.batchInfo(0);
        assertEq(filled, 0); assertEq(deps, 0);
    }

    function test_CannotWithdrawFullBatch() public {
        uint256[] memory ids = _deposit(alice, 80);
        uint256[] memory one = new uint256[](1); one[0] = ids[0];
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.withdraw(one);
    }

    function test_CannotWithdrawOthers() public {
        uint256[] memory ids = _deposit(alice, 5);
        uint256[] memory one = new uint256[](1); one[0] = ids[0];
        vm.prank(bob); vm.expectRevert(CreditPool.NotDepositor.selector);
        pool.withdraw(one);
    }

    function test_FullFlow_AuctionAndClaims() public {
        _fillBatch0();
        pool.assemble(0);
        (CreditPool.BatchState s,,, uint256 sid,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
        assertEq(stmts.ownerOf(sid), address(pool));

        // quorum: alice alone (40/80) is exactly half → not enough
        vm.prank(alice); pool.setReserve(0, 3 ether);
        vm.expectRevert(CreditPool.ReserveQuorumNotMet.selector);
        pool.startAuction(0);
        vm.prank(carol); pool.setReserve(0, 1 ether);
        // votes: carol 10 @1, alice 40 @3 → weighted median = 3
        assertEq(pool.currentReserve(0), 3 ether);
        vm.prank(bob); pool.setReserve(0, 2 ether);
        // carol10@1, bob30@2, alice40@3 → only 40 of 80 slots accept ≤ 2, so the reserve stays 3
        assertEq(pool.currentReserve(0), 3 ether);
        vm.prank(alice); pool.setReserve(0, 2 ether);
        // now 80 of 80 accept ≤ 2 (first price where >40 slots are in) → 2
        assertEq(pool.currentReserve(0), 2 ether);
        pool.startAuction(0);

        vm.prank(bidder1); vm.expectRevert(CreditPool.BidTooLow.selector);
        pool.bid{value: 1.9 ether}(0);
        vm.prank(bidder1); pool.bid{value: 2 ether}(0);
        vm.prank(bidder2); vm.expectRevert(CreditPool.BidTooLow.selector);
        pool.bid{value: 2.09 ether}(0);
        vm.prank(bidder2); pool.bid{value: 2.4 ether}(0);

        vm.expectRevert(CreditPool.AuctionLive.selector);
        pool.settle(0);

        // anti-snipe
        (,,, uint64 endsAt) = pool.auctions(0);
        vm.warp(endsAt - 1 minutes);
        vm.prank(bidder1); pool.bid{value: 3 ether}(0);
        (,,, uint64 newEnd) = pool.auctions(0);
        assertEq(newEnd, block.timestamp + 15 minutes);

        vm.warp(newEnd);
        pool.settle(0);
        assertEq(stmts.ownerOf(sid), bidder1);

        vm.prank(bidder1); pool.withdrawRefund();       // 2 ETH back
        vm.prank(bidder2); pool.withdrawRefund();       // 2.4 ETH back
        assertEq(bidder1.balance, 100 ether - 3 ether);
        assertEq(bidder2.balance, 100 ether);

        uint256 a0 = alice.balance; uint256 b0 = bob.balance; uint256 c0 = carol.balance;
        vm.prank(alice); pool.claim(0);
        vm.prank(bob); pool.claim(0);
        vm.prank(carol); pool.claim(0);
        // 3 ETH sale, no sale fee → all 3 ETH split 40/30/10
        assertEq(alice.balance - a0, 1.5 ether);
        assertEq(bob.balance - b0, 1.125 ether);
        assertEq(carol.balance - c0, 0.375 ether);
        assertEq(pool.accruedFees(), pool.usdWei() * 80); // deposits of 40, 30, 10: all bulk rate ($1)
        pool.sweepFees();
        assertEq(address(pool).balance, 0); // everything paid out: refunds, shares, fees
        vm.prank(alice); vm.expectRevert(CreditPool.NothingToClaim.selector);
        pool.claim(0);
    }

    function test_NoBids_ResetsForRevote() public {
        _fillBatch0(); pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 5 ether);
        vm.prank(bob); pool.setReserve(0, 5 ether);
        pool.startAuction(0);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(0);
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
        vm.prank(alice); pool.setReserve(0, 2 ether);
        vm.prank(bob); pool.setReserve(0, 2 ether);
        pool.startAuction(0);
        (,, uint256 reserve,) = pool.auctions(0);
        assertEq(reserve, 2 ether);
    }

    function test_SoleOwnerRedeems() public {
        _deposit(whale, 80);
        pool.assemble(0);
        vm.prank(alice); vm.expectRevert(CreditPool.NotDepositor.selector);
        pool.redeem(0);
        vm.prank(whale); pool.redeem(0);
        (,,, uint256 sid,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), whale);
    }

    function test_EscapeHatchWhenCapHit() public {
        stmts.setCap(0); // assembly permanently blocked
        uint256[] memory aIds = _deposit(alice, 50);
        _deposit(bob, 30);
        vm.expectRevert(bytes("cap"));
        pool.assemble(0);
        assertFalse(pool.escapeOpen(0));
        vm.warp(opensAt + 14 days + 1);
        assertTrue(pool.escapeOpen(0));
        vm.prank(alice); pool.withdraw(aIds);
        assertEq(credits.balanceOf(alice), 50);
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Dissolved));
        vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.assemble(0);
    }

    function test_DepositorRemovalClearsVote() public {
        uint256[] memory ids = _deposit(alice, 5);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(alice); pool.withdraw(ids);
        assertEq(pool.reservePref(0, alice), 0);
        assertEq(pool.batchDepositors(0).length, 0);
    }

    function _slice(uint256[] memory ids, uint256[6] memory idx) internal pure returns (uint256[] memory out) {
        out = new uint256[](6);
        for (uint256 i; i < 6; ++i) out[i] = ids[idx[i]];
    }
}
