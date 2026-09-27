// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {ICredits, ForkStatements} from "./CreditPool.fork.t.sol";

/// Bug hunt against REAL Credits and the REAL Chainlink ETH/USD feed on a pinned mainnet fork.
/// Focus: the external-audit fixes (vault deltas, fallback fee) and limits real contracts impose.
///   MAINNET_RPC=https://eth.drpc.org forge test --match-contract ForkScenarios -vv
contract ForkScenariosTest is Test {
    ICredits constant CREDITS = ICredits(0x97630aA70AB14ed9883B41dAfccBc11349723043);
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant WHALE = 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a; // large real holder
    uint256 constant FORK_BLOCK = 26_059_000;                             // after Credits were sealed
    uint256 constant TX_GAS_CAP = 16_777_216;                             // 2^24, per-transaction cap

    CreditPool pool;
    ForkStatements stmts;
    uint256[] owned;
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        stmts = new ForkStatements(CREDITS);
        pool = new CreditPool(address(CREDITS), address(stmts), address(stmts), ETH_USD, block.timestamp, address(this));
        owned = CREDITS.tokensOf(WHALE);
        require(owned.length >= 330, "whale too small at this block");
        vm.deal(WHALE, 100 ether);
        vm.prank(WHALE); CREDITS.setApprovalForAll(address(pool), true);
        live = true;
    }

    modifier forked() {
        if (!live) { vm.skip(true); return; }
        _;
    }

    function _slice(uint256 from, uint256 n) internal view returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = owned[from + i];
    }
    function _deposit(uint256[] memory ids) internal returns (uint256 gasUsed) {
        uint256 fee = pool.depositFee() * ids.length;
        vm.prank(WHALE);
        uint256 g = gasleft();
        pool.deposit{value: fee}(ids);
        gasUsed = g - gasleft();
    }
    function _has(uint256[] memory list, uint256 id) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) if (list[i] == id) return true;
        return false;
    }

    // H-01 on real Credits: a Credit plain-transferred to the vault must not block assembly.
    function test_ForkH01_DonatedRealCreditDoesNotBrickAssembly() public forked {
        address v = address(pool.vault());
        uint256 stray = owned[300];
        vm.prank(WHALE); (bool ok,) = address(CREDITS).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", WHALE, v, stray));
        assertTrue(ok, "donation transfer");
        assertEq(CREDITS.ownerOf(stray), v);

        _deposit(_slice(0, 80));
        uint256 g = gasleft();
        pool.assemble(0);
        uint256 used = g - gasleft();
        console.log("assemble 80 real Credits with a stray in the vault, gas:", used);
        assertLt(used, TX_GAS_CAP);
        (CreditPool.BatchState s,,, uint256 sid,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
        assertEq(stmts.ownerOf(sid), address(pool));
        assertEq(CREDITS.ownerOf(stray), v, "stray untouched");

        _deposit(_slice(80, 80));
        pool.assemble(1);                                   // and the next batch too
        assertEq(CREDITS.tokensOf(v).length, 1, "vault holds only the stray");
    }

    // M-01 with the real feed: once Chainlink's answer is over a day old, deposits use the frozen fallback.
    function test_ForkM01_RealFeedGoesStaleDepositsContinue() public forked {
        uint256 fb = pool.fallbackFeeWei();
        assertEq(fb, pool.depositFee(), "fallback frozen at deploy = live fee then");
        assertFalse(pool.feeUsesFallback());
        vm.warp(block.timestamp + 2 days);                 // the fork's feed can't update: now stale
        assertTrue(pool.feeUsesFallback());
        assertEq(pool.depositFee(), fb);
        _deposit(_slice(0, 3));
        assertEq(pool.accruedFees(), fb * 3);
        assertEq(CREDITS.ownerOf(owned[0]), address(pool));
    }

    // The biggest deposit the frontend sends (100 real Credits) fits the per-transaction gas cap.
    function test_ForkGas_Max100CreditDeposit() public forked {
        uint256 used = _deposit(_slice(0, 100));
        console.log("deposit 100 real Credits, gas:", used);
        assertLt(used, TX_GAS_CAP);
        assertEq(pool.openBatchId(), 1);                     // 80 filled batch 0, 20 spilled into batch 1
        (, uint256 f1,,,,) = pool.batchInfo(1);
        assertEq(f1, 20);
    }

    // A real whale deposits 330 Credits in frontend-sized chunks; every batch and balance adds up.
    function test_ForkWhale_ChunkedDepositsAddUp() public forked {
        uint256 total = 330;
        for (uint256 off; off < total; off += 100) _deposit(_slice(off, off + 100 > total ? total - off : 100));
        assertEq(pool.openBatchId(), 4);                     // 4 full batches + 10 in batch #4
        for (uint256 b; b < 4; ++b) {
            (CreditPool.BatchState s, uint256 f,,,,) = pool.batchInfo(b);
            assertEq(uint8(s), uint8(CreditPool.BatchState.Full));
            assertEq(f, 80);
            assertEq(pool.slots(b, WHALE), 80);
        }
        (, uint256 f4,,,,) = pool.batchInfo(4);
        assertEq(f4, 10);
        assertEq(CREDITS.tokensOf(address(pool)).length, total, "real Credits' owner list agrees");
        assertEq(pool.accruedFees(), pool.depositFee() * total);
    }

    // Real Credits keeps a per-owner token list; deposit / withdraw / re-deposit / burn must keep it exact.
    function test_ForkCredits_OwnerListsStayExact() public forked {
        uint256[] memory ids = _slice(0, 10);
        _deposit(ids);
        uint256[] memory out = new uint256[](5);
        out[0] = ids[1]; out[1] = ids[3]; out[2] = ids[9]; out[3] = ids[0]; out[4] = ids[5];
        vm.prank(WHALE); pool.withdraw(out);                 // non-contiguous, incl. first and last
        uint256[] memory inPool = CREDITS.tokensOf(address(pool));
        assertEq(inPool.length, 5);
        for (uint256 i; i < 5; ++i) {
            assertFalse(_has(inPool, out[i]));
            assertEq(CREDITS.ownerOf(out[i]), WHALE);
            assertEq(pool.depositorOf(out[i]), address(0));
        }
        uint256[] memory back = new uint256[](2);
        back[0] = out[2]; back[1] = out[3];
        _deposit(back);                                      // re-deposit two of them
        assertEq(CREDITS.tokensOf(address(pool)).length, 7);
        assertEq(pool.batchOf(back[0]), 0);
        // fill to 80 and assemble: every burned id leaves every list
        _deposit(_slice(10, 73));
        pool.assemble(0);
        assertEq(CREDITS.tokensOf(address(pool)).length, 0);
        assertEq(CREDITS.tokensOf(address(pool.vault())).length, 0);
        for (uint256 i; i < 2; ++i) { vm.expectRevert(); CREDITS.ownerOf(back[i]); }
        assertEq(pool.depositorOf(back[0]), address(0), "burned ids cleared (I-05)");
    }

    // H-02 with real Credits: a sole holder's batch can only be auctioned by that holder.
    function test_ForkH02_SoleHolderControlsTheirStatement() public forked {
        _deposit(_slice(0, 80));
        pool.assemble(0);
        vm.prank(WHALE); pool.setReserve(0, 1);
        vm.prank(address(0xBEEF)); vm.expectRevert(CreditPool.NotDepositor.selector);
        pool.startAuction(0);
        (,,, uint256 sid,,) = pool.batchInfo(0);
        vm.prank(WHALE); pool.redeem(0);
        assertEq(stmts.ownerOf(sid), WHALE);
    }
}
