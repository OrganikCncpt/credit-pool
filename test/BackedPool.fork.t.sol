// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {BackedPool} from "../src/BackedPool.sol";
import {BackedStore} from "../src/BackedStore.sol";
import {ICredits, ForkStatements} from "./CreditPool.fork.t.sol";
import {deployBacked} from "./BackedPool.t.sol";

/// Backed auctions against mainnet state: real Credits, real burn, real Chainlink feed, real gas.
/// Skipped unless MAINNET_RPC is set.
contract BackedPoolForkTest is Test {
    ICredits constant CREDITS = ICredits(0x97630aA70AB14ed9883B41dAfccBc11349723043);
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    BackedPool pool;
    ForkStatements stmts;
    address holder = 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a; // 330+ Credits at the pinned block
    address whale = makeAddr("bpf-whale-7c1");
    address bidder = makeAddr("bpf-bidder-7c1");
    uint256[] ids;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, 26_059_000);
        require(whale.code.length == 0 && bidder.code.length == 0, "label collides with a mainnet contract");
        stmts = new ForkStatements(CREDITS);
        pool = deployBacked(address(CREDITS), address(stmts), address(stmts), ETH_USD, block.timestamp, makeAddr("bpf-fees-7c1"));
        uint256[] memory owned = CREDITS.tokensOf(holder);
        for (uint256 i; i < 80; ++i) ids.push(owned[i]);
        vm.deal(holder, 1 ether); vm.deal(whale, 10 ether); vm.deal(bidder, 10 ether);
        vm.prank(holder); CREDITS.setApprovalForAll(address(pool), true);
    }

    modifier forked() {
        if (address(pool) == address(0)) { vm.skip(true); return; }
        _;
    }

    function _depositAll() internal {
        uint256 fee = pool.depositFeeFor(80);
        vm.prank(holder); pool.deposit{value: fee}(ids);
    }

    function test_Fork_BackedSaleBurnsRealCredits() public forked {
        _depositAll();
        vm.prank(holder); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 1 ether}(0); // at the holder's minimum
        pool.startAuction(0, 1 ether);
        vm.prank(bidder); pool.bid{value: 1.2 ether}(0);
        (,,, uint64 e) = pool.auctions(0);
        vm.warp(e);
        uint256 g = gasleft();
        pool.settle(0);
        console.log("settle (burn 80 real Credits + award + deliver) gas=%s", g - gasleft());
        (BackedPool.BatchState s,,, uint256 sid, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
        assertEq(stmts.ownerOf(sid), bidder);
        for (uint256 i; i < 80; ++i) {
            vm.expectRevert();
            CREDITS.ownerOf(ids[i]); // really burned
        }
        uint256 b0 = holder.balance;
        vm.prank(holder); pool.claim(0);
        assertEq(holder.balance - b0, proceeds);
        assertEq(BackedStore(payable(address(pool.store()))).balanceOf(holder), 160);
        assertEq(pool.pendingReturns(whale), 1 ether);
    }

    /// A lowball backing can't start an auction on real Credits; the holder walks away with them.
    function test_Fork_LowballCantLockRealCredits() public forked {
        _depositAll();
        vm.prank(holder); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 0.001 ether}(0);
        vm.expectRevert(BackedPool.BelowMinimum.selector);
        pool.startAuction(0, 0.001 ether);
        vm.prank(holder); pool.withdraw(ids);
        for (uint256 i; i < 80; ++i) assertEq(CREDITS.ownerOf(ids[i]), holder);
        vm.prank(whale); pool.withdrawBacking(0);
        assertEq(pool.pendingReturns(whale), 0.001 ether);
    }

    function test_Fork_SettleFinalizesUnderTxCap() public forked {
        _depositAll();
        vm.prank(holder); pool.setReserve(0, 0.3 ether);
        vm.prank(whale); pool.back{value: 0.3 ether}(0);
        pool.startAuction(0, 0.3 ether);
        (,,, uint64 e) = pool.auctions(0);
        vm.warp(e);
        uint256 g = gasleft();
        pool.settle{gas: 1 << 24}(0); // the per-transaction cap
        console.log("settle that finalizes gas=%s", g - gasleft());
        (BackedPool.BatchState s,,,,,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
    }
}
