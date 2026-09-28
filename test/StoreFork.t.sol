// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditStore} from "../src/CreditStore.sol";
import {deployPool} from "./DeployPool.sol";
import {ICredits, ForkStatements} from "./CreditPool.fork.t.sol";

interface ITransfer { function transferFrom(address, address, uint256) external; }

/// The store (SCREDIT points, treasury, SCREDIT auction) against REAL Credits and the REAL
/// Chainlink ETH/USD feed on a pinned mainnet fork.
///   MAINNET_RPC=https://eth.drpc.org forge test --match-contract StoreFork -vv
contract StoreForkTest is Test {
    ICredits constant CREDITS = ICredits(0x97630aA70AB14ed9883B41dAfccBc11349723043);
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant WHALE = 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a;
    uint256 constant FORK_BLOCK = 26_059_000;
    uint256 constant TX_GAS_CAP = 16_777_216;

    CreditPool pool; CreditStore store; ForkStatements stmts;
    // Unique labels: Foundry's usual "alice"/"bob" keys are public, and on real mainnet some of
    // those addresses are delegated to sweeper contracts that forward any ETH they receive.
    address platform = makeAddr("creditpool-fork-platform");
    address alice = makeAddr("creditpool-fork-alice"); address bob = makeAddr("creditpool-fork-bob");
    address carol = makeAddr("creditpool-fork-carol");
    uint256[] owned; uint256 next; // next unused whale Credit
    uint256 dust;
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        stmts = new ForkStatements(CREDITS);
        pool = deployPool(address(CREDITS), address(stmts), address(stmts), ETH_USD, block.timestamp, platform);
        store = CreditStore(payable(address(pool.store())));
        dust = address(store).balance; // this address holds dust on real mainnet; it just joins the treasury
        owned = CREDITS.tokensOf(WHALE);
        require(owned.length >= 330, "whale too small");
        address[4] memory plain = [alice, bob, carol, platform];
        for (uint256 i; i < 4; ++i) require(plain[i].code.length == 0, "test address has code on mainnet");
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.deal(us[i], 100 ether);
            vm.prank(us[i]); CREDITS.setApprovalForAll(address(pool), true);
        }
        live = true;
    }
    modifier forked() { if (!live) { vm.skip(true); return; } _; }

    /// Hand `n` real Credits from the whale to `to` and deposit them.
    function _dep(address to, uint256 n) internal returns (uint256 gasUsed) {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = owned[next++];
            vm.prank(WHALE); ITransfer(address(CREDITS)).transferFrom(WHALE, to, ids[i]);
        }
        if (CREDITS.ownerOf(ids[0]) != to) revert("transfer");
        (bool approved) = _approved(to);
        if (!approved) { vm.prank(to); CREDITS.setApprovalForAll(address(pool), true); }
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(to);
        uint256 g = gasleft();
        pool.deposit{value: fee}(ids);
        gasUsed = g - gasleft();
    }
    function _approved(address who) internal view returns (bool ok) {
        (bool s, bytes memory r) = address(CREDITS).staticcall(abi.encodeWithSignature("isApprovedForAll(address,address)", who, address(pool)));
        ok = s && abi.decode(r, (bool));
    }

    // Full store life cycle on real Credits: points on fill, real burn, unsold auction,
    // treasury buys at the majority price, SCREDIT auction with real $0.25 bid fees.
    function test_StoreFork_FullLifecycle() public forked {
        _dep(alice, 40); _dep(bob, 39);
        assertEq(store.totalSupply(), 0, "no points before the batch fills");
        _dep(carol, 1);                                   // fills: points for all three
        assertEq(store.balanceOf(alice), 80);
        assertEq(store.balanceOf(bob), 78);
        assertEq(store.balanceOf(carol), 2);

        pool.assemble(0);                                 // burns 80 REAL Credits
        (,,, uint256 sid,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), address(pool));

        // fund the treasury with real-priced fees ($40 + $39 + $2 = $81 → 75% treasury)
        uint256 fees = pool.accruedFees();
        assertEq(fees, pool.usdWei() * 81);
        pool.sweepFees();
        assertEq(platform.balance, fees / 4);
        assertEq(store.treasuryBalance(), dust + fees - fees / 4);

        // majority votes a small minimum; the auction ends with no bids
        uint256 price = store.treasuryBalance() / 2;
        vm.prank(alice); pool.setReserve(0, price);
        vm.prank(bob); pool.setReserve(0, price);
        pool.startAuction(0);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(0);
        assertEq(pool.unsoldAuctions(0), 1);

        store.buyUnsold(0, price);                        // test contract owns the store
        (address hb, uint256 hbid,,) = pool.auctions(0);
        assertEq(hb, address(store)); assertEq(hbid, price);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(0);
        assertEq(stmts.ownerOf(sid), address(store));
        uint256 a0 = alice.balance;
        vm.prank(alice); pool.claim(0);
        assertEq(alice.balance - a0, price * 40 / 80);    // depositors paid the majority price

        // SCREDIT-only store auction, $0.25 fee per bid priced by the real feed
        store.list(sid, 10);
        uint256 bf = store.bidFee();
        assertEq(bf, pool.usdWei() / 4);
        vm.prank(alice); store.bid{value: bf}(sid, 10);
        vm.prank(bob); store.bid{value: bf}(sid, 11);
        assertEq(store.balanceOf(alice), 80);             // outbid: points back
        assertEq(store.balanceOf(address(store)), 11);    // bob's escrow
        vm.warp(block.timestamp + 25 hours);
        store.settle(sid);
        assertEq(stmts.ownerOf(sid), bob);
        assertEq(store.totalSupply(), 160 - 11);          // winner's points burned
        uint256 p0 = platform.balance;
        store.sweepBidFees();
        assertEq(platform.balance - p0, 2 * bf);
    }

    // After 30 days the real feed is stale (fallback fee) and one low vote can't block or
    // cheapen the treasury: it bids the majority price.
    function test_StoreFork_After30DaysMajorityPrice() public forked {
        _dep(alice, 41); _dep(bob, 39);
        pool.assemble(0);
        pool.sweepFees();
        uint256 majority = store.treasuryBalance() / 2;
        vm.prank(alice); pool.setReserve(0, majority);
        vm.prank(bob); pool.setReserve(0, majority);
        pool.startAuction(0);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(0);
        vm.prank(bob); pool.setReserve(0, 1);             // one low minority vote
        vm.warp(block.timestamp + 31 days);
        assertTrue(pool.noReserveOpen(0));
        assertTrue(pool.feeUsesFallback(), "real feed is stale by now");
        store.buyUnsold(0, majority);
        (address hb, uint256 hbid, uint256 reserve,) = pool.auctions(0);
        assertEq(hb, address(store));
        assertEq(hbid, majority);
        assertEq(reserve, 1);
    }

    // Worst-case award gas with REAL Credits: 79 different depositors, then one fills it.
    function test_StoreFork_FillAwardGas() public forked {
        for (uint256 i; i < 79; ++i) {
            address u = address(uint160(0xA0000 + i));
            vm.deal(u, 1 ether);
            _dep(u, 1);
        }
        vm.deal(address(0xB0000), 1 ether);
        uint256 used = _dep(address(0xB0000), 1);
        console.log("fill with 80 real depositors, gas:", used);
        assertLt(used, 4_000_000);
        assertEq(store.totalSupply(), 160);
        // and the biggest frontend deposit filling a batch stays under the cap
        vm.deal(alice, 10 ether);
        uint256 big = _dep(alice, 100);
        console.log("100 real Credits (fills a batch), gas:", big);
        assertLt(big, TX_GAS_CAP);
        assertEq(store.balanceOf(alice), 160);            // batch #1 filled by alice alone
    }

    // A fee wallet that rejects ETH doesn't hold up the treasury's share.
    function test_StoreFork_RevertingFeeWallet() public forked {
        RejectEth bad = new RejectEth();
        pool.setFeeRecipient(address(bad));
        _dep(alice, 10);
        uint256 fees = pool.accruedFees();
        pool.sweepFees();
        assertEq(store.treasuryBalance(), dust + fees - fees / 4);
        assertEq(pool.platformFeesOwed(), fees / 4);
        pool.setFeeRecipient(platform);
        pool.sweepFees();
        assertEq(platform.balance, fees / 4);
        assertEq(pool.platformFeesOwed(), 0);
    }
}

contract RejectEth { receive() external payable { revert("no"); } }
