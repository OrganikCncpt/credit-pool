// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditStore} from "../src/CreditStore.sol";
import {deployPool} from "./DeployPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

/// Findings from external audit #2 (report on tag audit-prep-3, commit d92be83).
/// `test_Fix_*` assert the CORRECT behaviour, so each fails on the audited code if the finding is real.
/// `test_Repro_*` reproduce a claim as described, for findings triaged as design / documented.
contract ExternalAudit2Test is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool; CreditStore store;
    address alice = makeAddr("ea2-alice"); address bob = makeAddr("ea2-bob"); address eve = makeAddr("ea2-eve");
    address carol = makeAddr("ea2-carol");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, makeAddr("ea2-platform"));
        store = CreditStore(payable(address(pool.store())));
        address[4] memory us = [alice, bob, eve, carol];
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
    /// Carol fills a batch of her own (so later batches start clean); 75% of the $80 goes to the treasury.
    function _fundTreasury(uint256) internal {
        _deposit(carol, 80);
        pool.sweepFees();
    }
    /// A 2-depositor batch, assembled, whose first auction ends with no bids at `reserve`.
    function _unsold(address a, uint256 na, address c, uint256 nc, uint256 reserve) internal returns (uint256 b) {
        b = pool.openBatchId();
        _deposit(a, na); _deposit(c, nc);
        pool.assemble(b);
        vm.prank(a); pool.setReserve(b, reserve);
        vm.prank(c); pool.setReserve(b, reserve);
        pool.startAuction(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);
    }

    // ── HIGH (report): currentReserve returns the pivotal voter's ask ──
    // Reproduced as described: with the 39-slot holder abstaining, one 1-slot vote moves the
    // quorum price 400x. Triage: the math matches its definition ("lowest price >40 slots accept":
    // at 4 ETH, alice (min 0.01) and eve both accept); the real exposure is the treasury trusting
    // it as a price to PAY. Fixed on the treasury side (see test_Fix_TreasuryRejectsPivotalMinorityPrice).
    function test_Repro_H_PivotalVoteSetsQuorumPrice() public {
        uint256 b = pool.openBatchId();
        _deposit(alice, 40); _deposit(bob, 39); _deposit(eve, 1);
        pool.assemble(b);
        vm.prank(alice); pool.setReserve(b, 0.01 ether);
        vm.expectRevert(CreditPool.ReserveQuorumNotMet.selector);
        pool.currentReserve(b);                                 // 40 slots: not a majority
        vm.prank(eve); pool.setReserve(b, 4 ether);
        assertEq(pool.currentReserve(b), 4 ether);              // eve's 1 slot is pivotal
    }

    // ── MEDIUM (report): buyUnsold doesn't pin the price; a raise up to the owner's ceiling lands ──
    function test_Fix_BuyUnsoldPinsExactPrice() public {
        _fundTreasury(0.01 ether);
        uint256 b = _unsold(alice, 41, bob, 39, 0.001 ether);
        vm.prank(alice); pool.setReserve(b, 0.0015 ether);     // majority raises before the owner's tx
        vm.expectRevert(CreditStore.PriceMoved.selector);
        store.buyUnsold(b, 0.001 ether);                        // owner saw 0.001: any change reverts
    }

    // ── MEDIUM (report): a 1-wei winning bid makes every claim round to zero ──
    function test_Fix_FirstBidAtLeastOneWeiPerSlot() public {
        uint256 b = pool.openBatchId();
        _deposit(alice, 41); _deposit(bob, 39);
        pool.assemble(b);
        vm.warp(block.timestamp + 31 days);                     // nobody voted: fallback opens at 0
        pool.startAuction(b);
        vm.prank(eve); vm.expectRevert(CreditPool.BidTooLow.selector);
        pool.bid{value: 1}(b);
        vm.prank(eve); pool.bid{value: 80}(b);                   // 1 wei per slot is the floor
    }

    // ── LOW (report): sole-holder guard skipped when the sole holder opened their own auction ──
    function test_Fix_TreasuryNeverBuysFromSoleHolder() public {
        _fundTreasury(0.01 ether);
        uint256 b = pool.openBatchId();
        _deposit(alice, 80);
        pool.assemble(b);
        vm.prank(alice); pool.setReserve(b, 0.001 ether);
        vm.prank(alice); pool.startAuction(b);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);                                          // unsold once
        vm.prank(alice); pool.startAuction(b);                   // alice reopens it herself
        vm.expectRevert(CreditPool.NotDepositor.selector);
        store.buyUnsold(b, 0.001 ether);
    }

    // ── HIGH follow-up: the treasury only pays a price the pivotal voter can't set alone ──
    function test_Fix_TreasuryRejectsPivotalMinorityPrice() public {
        _fundTreasury(0.01 ether);
        uint256 b = pool.openBatchId();
        _deposit(alice, 40); _deposit(bob, 39); _deposit(eve, 1);
        pool.assemble(b);
        vm.prank(alice); pool.setReserve(b, 0.001 ether);
        vm.prank(eve); pool.setReserve(b, 0.004 ether);
        pool.startAuction(b);                                    // opens at 0.004 (eve pivotal)
        vm.warp(block.timestamp + 25 hours);
        pool.settle(b);
        vm.expectRevert(CreditStore.PivotalMinority.selector);
        store.buyUnsold(b, 0.004 ether);
        vm.prank(bob); pool.setReserve(b, 0.004 ether);          // a real majority now asks 0.004
        store.buyUnsold(b, 0.004 ether);
    }

    // ── LOW (report): constructor accepts duplicate dependency addresses and an unbounded opensAt ──
    function test_Fix_ConstructorRejectsMiswiring() public {
        address st = address(store);
        vm.expectRevert(CreditPool.BadConfig.selector);           // Statements set to the Credits address
        new CreditPool(address(credits), address(credits), address(credits), address(feed), block.timestamp, address(1), st);
        vm.expectRevert(CreditPool.BadConfig.selector);           // milliseconds instead of seconds
        new CreditPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp * 1000, address(1), st);
    }

    // ── LOW (report): malformed feed return data reverts instead of falling back ──
    function test_Fix_MalformedFeedFallsBack() public {
        vm.etch(address(feed), address(new ShortFeed()).code);
        assertEq(pool.usdWei(), pool.fallbackFeeWei());
        assertTrue(pool.feeUsesFallback());
    }

    // ── INFO: award array lengths; fee recipient can't be the pool or vault ──
    function test_Fix_AwardLengthsMustMatch() public {
        address[] memory to = new address[](1); to[0] = eve;
        uint256[] memory pts = new uint256[](0);
        vm.prank(address(pool)); vm.expectRevert(CreditStore.LengthMismatch.selector);
        store.award(to, pts);
    }
    function test_Fix_FeeRecipientCantBePoolOrVault() public {
        address v = address(pool.vault());
        vm.expectRevert(CreditPool.ZeroAddress.selector); pool.setFeeRecipient(address(pool));
        vm.expectRevert(CreditPool.ZeroAddress.selector); pool.setFeeRecipient(v);
    }
}

/// INFO: the store's local interface uses BatchState ordinals (2 = Assembled, 3 = Auction).
contract BatchStateOrdinalsTest is Test {
    function test_Fix_StoreStateOrdinalsMatchPool() public pure {
        assertEq(uint8(CreditPool.BatchState.Assembled), 2);
        assertEq(uint8(CreditPool.BatchState.Auction), 3);
    }
}

/// A feed that answers decimals() but returns only 32 bytes from latestRoundData().
contract ShortFeed {
    function decimals() external pure returns (uint8) { return 8; }
    fallback() external { assembly { mstore(0, 1) return(0, 32) } }
}
