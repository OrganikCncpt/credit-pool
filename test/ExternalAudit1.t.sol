// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

/// Findings from external audit #1 (report on tag audit-prep-1, commit 30d172a).
/// Each test asserts the CORRECT behavior, so it fails on the audited code if the finding is real.
contract ExternalAudit1Test is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool;
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address eve = makeAddr("eve");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        pool = new CreditPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, address(this));
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, eve][i];
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
        uint256 fee = pool.depositFee() * n;
        vm.prank(who); pool.deposit{value: fee}(ids);
    }

    // H-01: one Credit sent straight to the vault with plain transferFrom must not brick assembly.
    function test_H01_DonatedCreditToVaultDoesNotBrickAssembly() public {
        uint256[] memory stray = _give(eve, 1);
        address v = address(pool.vault());                   // read first: vm.prank applies to the next call
        vm.prank(eve); credits.transferFrom(eve, v, stray[0]);
        _deposit(alice, 80);
        pool.assemble(0);                                     // reverted CreditsNotBurned before the fix
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
        assertEq(credits.ownerOf(stray[0]), address(pool.vault())); // the stray is untouched
        _deposit(bob, 80);
        pool.assemble(1);                                     // and every later batch still works
    }

    // H-01 fix must keep N-1 closed: with a stray already in the vault, a swap is still caught.
    function test_H01_FixStillCatchesSwapWithStrayPresent() public {
        // assembler that burns the 80, then pushes a Credit it owns into the vault
        SwapInAssembler sw = new SwapInAssembler(credits);
        CreditPool p = new CreditPool(address(credits), address(sw.stmts()), address(sw), address(feed), block.timestamp, address(this));
        vm.prank(alice); credits.setApprovalForAll(address(p), true);
        uint256[] memory stray = _give(eve, 1);
        address v = address(p.vault());
        vm.prank(eve); credits.transferFrom(eve, v, stray[0]);
        uint256[] memory ids = _give(alice, 80);
        uint256 fee = p.depositFee() * 80;
        vm.prank(alice); p.deposit{value: fee}(ids);
        sw.setCheap(_give(address(sw), 1)[0]);
        vm.expectRevert(CreditPool.CreditsNotBurned.selector);
        p.assemble(0);
    }

    // H-02: a sole 80-slot holder's own vote must not let a stranger force their Statement to auction.
    function test_H02_StrangerCannotForceSoleHolderToAuction() public {
        _deposit(alice, 80);
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 1);
        vm.prank(eve); vm.expectRevert(CreditPool.NotDepositor.selector);
        pool.startAuction(0);
        vm.prank(alice); pool.redeem(0);                      // redeem still available
    }

    // H-02 fix must not remove a feature: the sole holder can still CHOOSE to auction.
    function test_H02_SoleHolderCanStillChooseAuction() public {
        _deposit(alice, 80);
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 3 ether);
        vm.prank(alice); pool.startAuction(0);
        (,, uint256 reserve,) = pool.auctions(0);
        assertEq(reserve, 3 ether);
    }

    // L-03: a round dated in the future is untrusted (no arithmetic Panic): the fallback fee applies.
    function test_L03_FutureDatedRoundUsesFallback() public {
        feed.set(1000e8, block.timestamp + 1 hours);
        assertTrue(pool.feeUsesFallback());
        assertEq(pool.depositFee(), pool.fallbackFeeWei());
    }

    // M-01: deposits keep working at the frozen fallback fee when the feed stops answering entirely.
    function test_M01_DeadFeedUsesFallbackAndDepositsWork() public {
        uint256 fb = pool.fallbackFeeWei();
        feed.setBroken(true);
        assertTrue(pool.feeUsesFallback());
        assertEq(pool.depositFee(), fb);
        uint256[] memory ids = _give(alice, 3);
        vm.prank(alice); vm.expectRevert(CreditPool.InsufficientFee.selector);
        pool.deposit{value: fb * 3 - 1}(ids);
        vm.prank(alice); pool.deposit{value: 1 ether}(ids);  // excess refunded
        assertEq(pool.accruedFees(), fb * 3);
        feed.setBroken(false);                                // feed recovers: live pricing resumes
        assertFalse(pool.feeUsesFallback());
    }

    // M-01: the fallback can only be frozen from a healthy feed; a stale feed at deploy is refused.
    function test_M01_DeployRequiresHealthyFeed() public {
        feed.set(2500e8, block.timestamp - 2 days);
        vm.expectRevert(CreditPool.StaleOracle.selector);
        new CreditPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, address(this));
    }

    // L-04: the constructor refuses addresses with no code for its contract dependencies.
    function test_L04_ConstructorRejectsNonContracts() public {
        vm.expectRevert(CreditPool.NotAContract.selector);
        new CreditPool(address(0xBEEF), address(stmts), address(stmts), address(feed), block.timestamp, address(this));
        vm.expectRevert(CreditPool.NotAContract.selector);
        new CreditPool(address(credits), address(stmts), address(stmts), address(0xBEEF), block.timestamp, address(this));
    }

    // I-05: after assembly, burned Credits no longer report a depositor or batch.
    function test_I05_BurnedCreditsClearedFromBookkeeping() public {
        uint256[] memory ids = _deposit(alice, 80);
        pool.assemble(0);
        assertEq(pool.depositorOf(ids[0]), address(0));
    }
}

/// Burns the 80, then pushes a Credit it owns into the vault so a balance-only check would pass.
contract SwapInAssembler {
    MockCredits immutable credits;
    MockStatements public immutable stmts;
    uint256 public cheap;
    constructor(MockCredits c) { credits = c; stmts = new MockStatements(c); }
    function setCheap(uint256 id) external { cheap = id; }
    function assemble(uint256[] calldata ids) external returns (uint256) {
        credits.burn(msg.sender, ids);
        credits.transferFrom(address(this), msg.sender, cheap);
        return 1;
    }
}
