// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {deployPool} from "./DeployPool.sol";
import {AssemblyVault} from "../src/AssemblyVault.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

/// Safe-mints Statement `mintId` to the caller but returns `claimId`.
contract MismatchAssembler is ERC721 {
    MockCredits immutable credits;
    uint256 next = 1;
    uint256 public claimOffset;
    constructor(MockCredits c) ERC721("S", "S") { credits = c; }
    function setClaimOffset(uint256 o) external { claimOffset = o; }
    function assemble(uint256[] calldata ids) external returns (uint256) {
        credits.burn(msg.sender, ids);
        uint256 id = next++;
        _safeMint(msg.sender, id);
        return id + claimOffset;
    }
}

/// Burns 79 of the batch plus one Credit from outside it: the balance drops by exactly 80,
/// but one of the batch's own Credits is still in the pool.
contract SwapOneAssembler is ERC721 {
    MockCredits immutable credits;
    uint256 public outsider;
    uint256 next = 1;
    constructor(MockCredits c) ERC721("S", "S") { credits = c; }
    function setOutsider(uint256 id) external { outsider = id; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        uint256[] memory burn = new uint256[](80);
        for (uint256 i; i < 79; ++i) burn[i] = ids[i];
        burn[79] = outsider;
        credits.burn(msg.sender, burn);
        sid = next++;
        _safeMint(msg.sender, sid);
    }
}

/// Error paths and views not reached by the flow, attack, custody or invariant suites.
contract EdgeCasesTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool;
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address eve = makeAddr("eve");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        pool = _pool(address(stmts));
        for (uint256 i; i < 3; ++i) vm.deal([alice, bob, eve][i], 100 ether);
    }

    function _pool(address assembler) internal returns (CreditPool p) {
        p = deployPool(address(credits), assembler, assembler, address(feed), block.timestamp, address(this));
        for (uint256 i; i < 3; ++i) { vm.prank([alice, bob, eve][i]); credits.setApprovalForAll(address(p), true); }
    }
    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _deposit(CreditPool p, address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = p.depositFeeFor(n);
        vm.prank(who); p.deposit{value: fee}(ids);
    }

    function test_EmptyDepositReverts() public {
        uint256[] memory none = new uint256[](0);
        vm.prank(alice); vm.expectRevert(bytes("empty"));
        pool.deposit(none);
    }

    // $2 per Credit for 1–5 Credits in one deposit; $1 per Credit for 6 or more.
    function test_FeeTiers() public {
        uint256 usd = pool.usdWei();
        assertEq(pool.depositFeeFor(1), usd * 2);
        assertEq(pool.depositFeeFor(5), usd * 10);
        assertEq(pool.depositFeeFor(6), usd * 6);   // 6 cost less than 5: the bulk rate covers the whole deposit
        assertEq(pool.depositFeeFor(100), usd * 100);
        uint256[] memory five = _give(alice, 5);
        vm.prank(alice); vm.expectRevert(CreditPool.InsufficientFee.selector);
        pool.deposit{value: usd * 10 - 1}(five);
        vm.prank(alice); pool.deposit{value: usd * 10}(five);
        uint256[] memory six = _give(bob, 6);
        vm.prank(bob); vm.expectRevert(CreditPool.InsufficientFee.selector);
        pool.deposit{value: usd * 6 - 1}(six);
        vm.prank(bob); pool.deposit{value: usd * 6}(six);
        assertEq(pool.accruedFees(), usd * 16);
    }

    function test_EscapeOpenFalseUnlessFull() public {
        _deposit(pool, alice, 10);
        vm.warp(block.timestamp + 365 days);
        assertFalse(pool.escapeOpen(0)); // Filling, however long
    }

    function test_BatchOfTracksDepositsAndOverflow() public {
        uint256[] memory a = _deposit(pool, alice, 79);
        uint256[] memory b = _deposit(pool, bob, 2);
        assertEq(pool.batchOf(a[0]), 0);
        assertEq(pool.batchOf(b[0]), 0);  // took the 80th slot
        assertEq(pool.batchOf(b[1]), 1);  // overflowed into batch 1
        assertEq(pool.depositorOf(b[1]), bob);
    }

    function test_HookIdMustMatchReturnedId() public {
        MismatchAssembler m = new MismatchAssembler(credits);
        CreditPool p = _pool(address(m));
        uint256[] memory ids = _deposit(p, alice, 80);
        m.setClaimOffset(7); // safe-mints #1, claims #8
        vm.expectRevert(CreditPool.StatementNotReceived.selector);
        p.assemble(0);
        assertEq(credits.ownerOf(ids[0]), address(p)); // nothing burned
        m.setClaimOffset(0);
        p.assemble(0);
        (,,, uint256 sid,,) = p.batchInfo(0);
        assertEq(sid, 1);
    }

    function test_AssemblerCannotBurnOutsideTheBatch() public {
        SwapOneAssembler s = new SwapOneAssembler(credits);
        CreditPool p = _pool(address(s));
        uint256[] memory a = _deposit(p, alice, 80);   // batch 0
        uint256[] memory b = _deposit(p, bob, 5);      // batch 1, filling
        s.setOutsider(b[0]);                           // lives in the pool, not the vault
        vm.expectRevert(bytes("not owner"));           // the vault can't burn what it doesn't hold
        p.assemble(0);
        assertEq(credits.ownerOf(a[79]), address(p));
        assertEq(credits.ownerOf(b[0]), address(p));   // bob's Credit untouched
    }

    function test_VaultOnlyCallableByPool() public {
        uint256[] memory ids = new uint256[](0);
        AssemblyVault v = pool.vault();
        vm.prank(eve); vm.expectRevert(AssemblyVault.OnlyPool.selector);
        v.assemble(ids);
    }

    function test_StartAuctionAtRejectsChangedReserve() public {
        _deposit(pool, alice, 50); _deposit(pool, bob, 30);
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 2 ether);
        assertEq(pool.auctionReserve(0), 2 ether);
        vm.prank(alice); pool.setReserve(0, 1 ether);  // price moved after the page loaded
        vm.expectRevert(CreditPool.ReserveChanged.selector);
        pool.startAuctionAt(0, 2 ether);
        pool.startAuctionAt(0, 1 ether);
        (,, uint256 reserve,) = pool.auctions(0);
        assertEq(reserve, 1 ether);
    }

    function test_OwnershipIsTwoStepAndCannotBeRenounced() public {
        vm.expectRevert(CreditPool.RenounceDisabled.selector);
        pool.renounceOwnership();
        pool.transferOwnership(bob);
        assertEq(pool.owner(), address(this));         // still pending
        vm.prank(bob); pool.acceptOwnership();
        assertEq(pool.owner(), bob);
    }

    function test_RedeemAndStartOnlyWhenAssembled() public {
        _deposit(pool, alice, 80);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.redeem(0);                                 // Full, not assembled
        vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.startAuction(0);
        vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.startAuction(1);                           // Filling
    }

    function test_SetReserveGuards() public {
        _deposit(pool, alice, 40); _deposit(pool, bob, 40);
        vm.prank(eve); vm.expectRevert(CreditPool.NotDepositor.selector);
        pool.setReserve(0, 1 ether);
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        pool.startAuction(0);
        vm.prank(eve); pool.bid{value: 1 ether}(0);
        vm.warp(block.timestamp + 25 hours);
        pool.settle(0);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.setReserve(0, 2 ether);                    // Settled

        _deposit(pool, eve, 80);                        // batch 1, sole holder
        pool.assemble(1);
        vm.prank(eve); pool.redeem(1);
        vm.prank(eve); vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.setReserve(1, 1 ether);                    // Redeemed
    }

    function test_SetReserveBlockedOnDissolved() public {
        uint256[] memory a = _deposit(pool, alice, 40); _deposit(pool, bob, 40);
        vm.warp(block.timestamp + 15 days);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);            // dissolves
        vm.prank(bob); vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.setReserve(0, 1 ether);
    }
}
