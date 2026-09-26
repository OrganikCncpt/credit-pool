// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

/// Assembler that burns 80 but "returns" a Statement the pool already holds.
contract LyingAssembler {
    MockStatements real;
    uint256 lie;
    constructor(MockStatements r) { real = r; }
    function setLie(uint256 l) external { lie = l; }
    function assemble(uint256[] calldata ids) external returns (uint256) {
        MockCredits c = real.credits();
        c.burn(msg.sender, ids); // pool approved us
        return lie;              // no new Statement minted
    }
}

/// Bidder that tries to re-enter on refund / reject ETH.
contract NastyBidder {
    CreditPool pool; uint256 b; bool reenter;
    constructor(CreditPool p) { pool = p; }
    function bid(uint256 id) external payable { b = id; pool.bid{value: msg.value}(id); }
    function pull(bool r) external { reenter = r; pool.withdrawRefund(); }
    receive() external payable { if (reenter) pool.withdrawRefund(); }
}

contract AttacksTest is Test {
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

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _deposit(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = pool.depositFee() * ids.length; // $1 per Credit
        vm.prank(who); pool.deposit{value: fee}(ids);
    }

    // ── FIXED 1: heartbeat edge no longer bricks deposits; a dead feed still does ──
    function test_Fixed_OracleHeartbeatEdge() public {
        feed.set(2500e8, block.timestamp - 3600 - 12); // one block past a 1h heartbeat
        uint256[] memory ids = _give(alice, 1);
        vm.prank(alice); pool.deposit{value: 1 ether}(ids);
        feed.set(2500e8, block.timestamp - 1 days - 1);
        vm.expectRevert(CreditPool.StaleOracle.selector);
        pool.depositFee();
    }

    // ── FIXED 2: stray safeTransfers bounce instead of getting stuck ──
    function test_Fixed_StrayCreditBounces() public {
        uint256[] memory ids = _give(alice, 1);
        vm.prank(alice); vm.expectRevert();
        credits.safeTransferFrom(alice, address(pool), ids[0]);
        assertEq(credits.ownerOf(ids[0]), alice);
    }

    // ── FIXED 3: assembler returning an already-held Statement id is rejected ──
    function test_Fixed_AssemblerCannotDoubleAssign() public {
        LyingAssembler liar = new LyingAssembler(stmts);
        CreditPool p2 = new CreditPool(address(credits), address(stmts), address(liar), address(feed), block.timestamp, address(this));
        // pool legitimately holds Statement #1 from somewhere (e.g. someone sent it)
        uint256[] memory x = _give(address(this), 80);
        credits.setApprovalForAll(address(stmts), true);
        uint256 sid = stmts.assemble(x);
        stmts.transferFrom(address(this), address(p2), sid); // plain transfer, no callback

        liar.setLie(sid);
        vm.prank(alice); credits.setApprovalForAll(address(p2), true);
        uint256[] memory ids = _give(alice, 80);
        uint256 fee = p2.depositFee() * ids.length; // $1 per Credit
        vm.prank(alice); p2.deposit{value: fee}(ids);
        vm.expectRevert(CreditPool.StatementNotReceived.selector);
        p2.assemble(0); // whole tx reverts, Credits are not burned
        assertEq(credits.ownerOf(ids[0]), address(p2));
    }

    // ── FIXED 4 (+ audit N-5): an unreachable majority reserve expires after 30 days; the
    //    minimum then drops to the LOWEST vote cast, so a seller's own price is still respected ──
    function test_Fixed_MajorityCannotTrapMinority() public {
        _deposit(alice, 41); _deposit(bob, 39);
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 10_000 ether); // unreachable reserve
        vm.prank(bob); pool.setReserve(0, 1 ether);
        for (uint256 i; i < 5; ++i) {
            pool.startAuction(0);
            vm.warp(block.timestamp + 25 hours);
            pool.settle(0); // no bids → back to Assembled
        }
        assertFalse(pool.noReserveOpen(0));
        vm.warp(pool.assembledAt(0) + 30 days);
        assertTrue(pool.noReserveOpen(0));
        pool.startAuction(0);
        (,, uint256 reserve,) = pool.auctions(0);
        assertEq(reserve, 1 ether);                     // bob's own vote, not 0 and not alice's 10k
        vm.prank(eve); vm.expectRevert(CreditPool.BidTooLow.selector);
        pool.bid{value: 0.5 ether}(0);
        vm.prank(eve); pool.bid{value: 1 ether}(0);
        vm.warp(block.timestamp + 25 hours); pool.settle(0);
        uint256 b0 = bob.balance;
        vm.prank(bob); pool.claim(0);
        assertEq(bob.balance - b0, (0.99 ether * 39) / 80); // bob is out, paid pro-rata after the 1% fee
    }

    // ── BY DESIGN 5: majority can lowball, but the minority can outbid within 24h ──
    function test_Design_MajorityLowballButMinorityCanOutbid() public {
        _deposit(alice, 41); _deposit(bob, 39);
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 1 wei);
        pool.startAuction(0); // bob can't react: alice alone is quorum
        vm.prank(alice); pool.bid{value: 1 wei}(0);
        vm.prank(bob); pool.bid{value: 5 ether}(0); // bob defends
        vm.warp(block.timestamp + 25 hours);
        pool.settle(0);
        (,,, uint256 sid,,) = pool.batchInfo(0);
        assertEq(stmts.ownerOf(sid), bob);
    }

    // ── HOLE 6: deposits after the Statement cap still fill and lock for 14 days ──
    function test_Hole_DepositAfterCapLocks14Days() public {
        stmts.setCap(0);
        uint256[] memory ids = _deposit(alice, 80);
        vm.expectRevert(bytes("cap")); pool.assemble(0);
        vm.warp(block.timestamp + 13 days);
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.withdraw(ids);
    }

    // ── FIXED 7: escape opening doesn't block a late assembly; first withdrawal does ──
    function test_Fixed_LateAssemblyStillAllowed() public {
        _deposit(alice, 40); _deposit(bob, 40);
        vm.warp(block.timestamp + 15 days);
        assertTrue(pool.escapeOpen(0));
        pool.assemble(0);
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
    }

    function test_Fixed_AfterDissolveNoAssembly() public {
        uint256[] memory a = _deposit(alice, 40); _deposit(bob, 40);
        vm.warp(block.timestamp + 15 days);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        vm.expectRevert(CreditPool.WrongBatchState.selector);
        pool.assemble(0);
    }

    // ── FIXED N2: a minority can't set the price by voting low the moment quorum is crossed ──
    function test_Fixed_MinorityCannotDragReserveDown() public {
        _deposit(alice, 20); _deposit(bob, 25); _deposit(eve, 35);   // eve: 35 slots that never vote
        pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 10 ether);   // honest 20 slots
        vm.prank(bob); pool.setReserve(0, 1 wei);        // attacker 25 slots, 45 voted in total
        assertEq(pool.currentReserve(0), 10 ether);       // only 25 slots accept 1 wei; 45 accept 10 ETH
        pool.startAuction(0);
        (,, uint256 reserve,) = pool.auctions(0);
        assertEq(reserve, 10 ether);
    }

    // ── FIXED N3: depositAt refuses a deposit if someone got in first ──
    function test_Fixed_DepositAtBlocksFrontRun() public {
        uint256[] memory whaleIds = _give(alice, 80);
        _deposit(eve, 1);                                 // front-runner lands first
        uint256 fee = pool.depositFee() * whaleIds.length; // $1 per Credit
        vm.prank(alice); vm.expectRevert(CreditPool.BatchMoved.selector);
        pool.depositAt{value: fee}(whaleIds, 0, 0);       // whale expected an empty batch #0
        vm.prank(alice); pool.depositAt{value: fee}(whaleIds, 0, 1); // explicit consent to the new state works
        assertEq(pool.slots(0, alice), 79);
    }

    // ── FIXED N4: nobody can force a no-reserve sale on a sole 80-slot holder ──
    function test_Fixed_SoleHolderNotForcedToSell() public {
        _deposit(alice, 80);
        pool.assemble(0);
        vm.warp(block.timestamp + 31 days);
        assertFalse(pool.noReserveOpen(0));
        vm.prank(eve); vm.expectRevert(CreditPool.ReserveQuorumNotMet.selector);
        pool.startAuction(0);
        vm.prank(alice); pool.redeem(0);
    }

    // ── checks that should HOLD ──
    function test_Safe_RefundReentrancyBlocked() public {
        _deposit(alice, 80); pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        pool.startAuction(0);
        NastyBidder n = new NastyBidder(pool);
        n.bid{value: 1 ether}(0);
        vm.prank(bob); pool.bid{value: 2 ether}(0);
        vm.expectRevert(CreditPool.TransferFailed.selector); // re-entry trips the guard, whole call reverts
        n.pull(true);
        n.pull(false);
        assertEq(address(n).balance, 1 ether);
        assertEq(pool.pendingReturns(address(n)), 0);
    }

    function test_Safe_DuplicateIdsInDeposit() public {
        uint256[] memory one = _give(alice, 1);
        uint256[] memory dup = new uint256[](2); dup[0] = one[0]; dup[1] = one[0];
        uint256 fee = pool.depositFee() * dup.length; // $1 per Credit
        vm.prank(alice); vm.expectRevert();
        pool.deposit{value: fee}(dup);
    }

    function test_Safe_CannotDepositOthersCredits() public {
        uint256[] memory ids = _give(alice, 1);
        uint256 fee = pool.depositFee() * ids.length; // $1 per Credit
        vm.prank(eve); vm.expectRevert();
        pool.deposit{value: fee}(ids); // pool is approved by alice, but eve can't route alice's Credits
    }

    function test_Safe_CannotClaimTwiceOrWithoutSlots() public {
        _deposit(alice, 40); _deposit(bob, 40); pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        pool.startAuction(0);
        vm.prank(eve); pool.bid{value: 1 ether}(0);
        vm.warp(block.timestamp + 25 hours); pool.settle(0);
        vm.prank(eve); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.claim(0);
        vm.prank(alice); pool.claim(0);
        vm.prank(alice); vm.expectRevert(CreditPool.NothingToClaim.selector); pool.claim(0);
    }

    /// Fuzz the payout: fee is exactly 1%, claims never exceed the net, dust stays < 80 wei.
    function testFuzz_ClaimsNeverExceedProceeds(uint8 a, uint96 price) public {
        uint256 na = bound(a, 1, 79);
        price = uint96(bound(price, 1, 1_000_000 ether));
        _deposit(alice, na); _deposit(bob, 80 - na); pool.assemble(0);
        vm.prank(alice); pool.setReserve(0, 1);
        vm.prank(bob); pool.setReserve(0, 1);
        pool.startAuction(0);
        vm.deal(eve, price); vm.prank(eve); pool.bid{value: price}(0);
        vm.warp(block.timestamp + 25 hours); pool.settle(0);
        uint256 before = address(pool).balance;
        vm.prank(alice); pool.claim(0);
        vm.prank(bob); pool.claim(0);
        uint256 paid = before - address(pool).balance;
        uint256 fee = (uint256(price) * 100) / 10_000;
        (,,,, uint256 net,) = pool.batchInfo(0);
        assertEq(net, price - fee);
        assertLe(paid, net);
        assertLt(net - paid, 80);
    }
}
