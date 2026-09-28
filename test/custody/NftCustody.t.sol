// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {deployPool} from "../DeployPool.sol";
import {MockCredits, MockStatements, MockFeed} from "../Mocks.sol";
import {Credits} from "../../external/credits/Credits.sol";

// ════════════════════════════════════════════════════════════════════════════════
//  Assembler / Statements variants used to probe the assembly trust boundary
// ════════════════════════════════════════════════════════════════════════════════

/// Statements that PLAIN-mints (no onERC721Received callback). Optionally returns a wrong id
/// (e.g. an off-by-one / "previous id" bug in the real contract's return value).
contract PlainMintStatements is ERC721 {
    MockCredits public credits;
    uint256 public next = 1;
    uint256 public lie; // 0 = honest
    constructor(MockCredits c) ERC721("Statements", "STMT") { credits = c; }
    function setLie(uint256 l) external { lie = l; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        require(ids.length == 80, "need 80");
        credits.burn(msg.sender, ids);
        sid = next++;
        _mint(msg.sender, sid); // no receiver hook
        if (lie != 0) sid = lie;
    }
}

/// Burns the batch correctly, but (when armed) also uses the pool's transient
/// setApprovalForAll to pull every OTHER Credit the pool holds.
contract ThiefStatements is ERC721 {
    MockCredits public credits;
    uint256 public next = 1;
    address public thief;
    bool public armed;
    constructor(MockCredits c, address t) ERC721("Statements", "STMT") { credits = c; thief = t; }
    function arm(bool a) external { armed = a; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        credits.burn(msg.sender, ids);
        if (armed) {
            uint256[] memory rest = credits.tokensOf(msg.sender);
            for (uint256 i; i < rest.length; ++i) credits.transferFrom(msg.sender, thief, rest[i]);
        }
        sid = next++;
        _safeMint(msg.sender, sid);
    }
    /// Used outside of assemble() to prove the approval does not persist.
    function tryPull(address from, uint256 id) external { credits.transferFrom(from, thief, id); }
}

/// Aims straight at the POOL: burns the batch, then tries to pull every other pool Credit.
contract PoolThiefStatements is ERC721 {
    MockCredits public credits;
    uint256 public next = 1;
    address public thief;
    address public pool;
    constructor(MockCredits c, address t) ERC721("Statements", "STMT") { credits = c; thief = t; }
    function setPool(address p) external { pool = p; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        credits.burn(msg.sender, ids);
        uint256[] memory rest = credits.tokensOf(pool);
        for (uint256 i; i < rest.length; ++i) credits.transferFrom(pool, thief, rest[i]);
        sid = next++;
        _safeMint(msg.sender, sid);
    }
}

/// The audit's N-1 swap: burns the 80, then pushes a Credit it owns back in so a
/// balance-only check would still add up.
contract SwapInStatements is ERC721 {
    MockCredits public credits;
    uint256 public next = 1;
    uint256 public cheap;
    constructor(MockCredits c) ERC721("Statements", "STMT") { credits = c; }
    function setCheap(uint256 id) external { cheap = id; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        credits.burn(msg.sender, ids);
        credits.transferFrom(address(this), msg.sender, cheap);
        sid = next++;
        _safeMint(msg.sender, sid);
    }
}

/// Buggy: ignores the ids it is given and burns the LAST 80 Credits the caller holds.
contract WrongIdsStatements is ERC721 {
    MockCredits public credits;
    uint256 public next = 1;
    constructor(MockCredits c) ERC721("Statements", "STMT") { credits = c; }
    function assemble(uint256[] calldata) external returns (uint256 sid) {
        uint256[] memory held = credits.tokensOf(msg.sender);
        uint256[] memory tail = new uint256[](80);
        for (uint256 i; i < 80; ++i) tail[i] = held[held.length - 80 + i];
        credits.burn(msg.sender, tail);
        sid = next++;
        _safeMint(msg.sender, sid);
    }
}

/// Incompatible real-world shapes: payable fee, EOA-only, different signature.
contract FeeStatements is ERC721 {
    MockCredits public credits; uint256 next = 1;
    constructor(MockCredits c) ERC721("S", "S") { credits = c; }
    function assemble(uint256[] calldata ids) external payable returns (uint256 sid) {
        require(msg.value >= 0.01 ether, "fee");
        credits.burn(msg.sender, ids);
        sid = next++; _safeMint(msg.sender, sid);
    }
}

contract EoaOnlyStatements is ERC721 {
    MockCredits public credits; uint256 next = 1;
    constructor(MockCredits c) ERC721("S", "S") { credits = c; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        require(msg.sender == tx.origin, "eoa only");
        credits.burn(msg.sender, ids);
        sid = next++; _safeMint(msg.sender, sid);
    }
}

contract OtherSigStatements is ERC721 {
    MockCredits public credits; uint256 next = 1;
    constructor(MockCredits c) ERC721("S", "S") { credits = c; }
    function assemble(uint256[] calldata ids, address to) external returns (uint256 sid) {
        credits.burn(msg.sender, ids);
        sid = next++; _safeMint(to, sid);
    }
}

/// Assembler that burns through the REAL Credits.burn(owner, ids) (sealed edition required).
contract RealCreditsStatements is ERC721 {
    Credits public credits; uint256 next = 1;
    constructor(Credits c) ERC721("S", "S") { credits = c; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        require(ids.length == 80, "need 80");
        credits.burn(msg.sender, ids);
        sid = next++; _safeMint(msg.sender, sid);
    }
}

/// A contract actor whose ERC721 hook / receive() tries to re-enter the pool.
contract HookedActor is IERC721Receiver {
    CreditPool pool;
    bool public hookHit;
    bool public reenterOnEth;
    uint256[] toWithdraw;
    constructor(CreditPool p, MockCredits c) { pool = p; c.setApprovalForAll(address(p), true); }
    function deposit(uint256[] calldata ids) external payable { pool.deposit{value: msg.value}(ids); }
    function withdraw(uint256[] calldata ids) external { pool.withdraw(ids); }
    function bid(uint256 b) external payable { pool.bid{value: msg.value}(b); }
    function redeem(uint256 b) external { pool.redeem(b); }
    function arm(bool r, uint256[] calldata ids) external { reenterOnEth = r; toWithdraw = ids; }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        hookHit = true;
        if (toWithdraw.length > 0) pool.withdraw(toWithdraw);
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable { if (reenterOnEth) pool.withdraw(toWithdraw); }
}

// ════════════════════════════════════════════════════════════════════════════════
//  Unit attacks
// ════════════════════════════════════════════════════════════════════════════════

contract NftCustodyTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; CreditPool pool;
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address carol = makeAddr("carol");
    address whale = makeAddr("whale"); address eve = makeAddr("eve");
    address bidder1 = makeAddr("bidder1"); address bidder2 = makeAddr("bidder2");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        feed = new MockFeed(2500e8);
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, address(this));
        _approveAll(pool);
    }

    function _approveAll(CreditPool p) internal {
        address[7] memory us = [alice, bob, carol, whale, eve, bidder1, bidder2];
        for (uint256 i; i < us.length; ++i) {
            vm.deal(us[i], 1000 ether);
            vm.prank(us[i]); credits.setApprovalForAll(address(p), true);
        }
    }

    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _depositTo(CreditPool p, address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = p.depositFeeFor(ids.length);
        vm.prank(who); p.deposit{value: fee}(ids);
    }
    function _deposit(address who, uint256 n) internal returns (uint256[] memory ids) { return _depositTo(pool, who, n); }
    function _redeposit(address who, uint256[] memory ids) internal {
        uint256 fee = pool.depositFeeFor(ids.length);
        vm.prank(who); pool.deposit{value: fee}(ids);
    }
    function _one(uint256 id) internal pure returns (uint256[] memory a) { a = new uint256[](1); a[0] = id; }
    function _two(uint256 x, uint256 y) internal pure returns (uint256[] memory a) { a = new uint256[](2); a[0] = x; a[1] = y; }
    function _state(CreditPool p, uint256 b) internal view returns (CreditPool.BatchState s) { (s,,,,,) = p.batchInfo(b); }
    function _sid(CreditPool p, uint256 b) internal view returns (uint256 sid) { (,,, sid,,) = p.batchInfo(b); }

    function _expectNotDepositor(address who, uint256[] memory ids) internal {
        vm.prank(who); vm.expectRevert(CreditPool.NotDepositor.selector); pool.withdraw(ids);
    }
    /// After assembly the burned Credits are dropped from bookkeeping (external audit #1, I-05),
    /// so even their former depositor gets NotDepositor: there is nothing left to withdraw.
    function _expectUntracked(address who, uint256[] memory ids) internal {
        vm.prank(who); vm.expectRevert(CreditPool.NotDepositor.selector); pool.withdraw(ids);
    }

    function _expectWrongState(address who, uint256[] memory ids) internal {
        vm.prank(who); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.withdraw(ids);
    }

    /// Full bookkeeping check of every Filling/Full batch of `p`.
    function _checkLive(CreditPool p, address[] memory us) internal view {
        uint256 open = p.openBatchId();
        for (uint256 b; b <= open; ++b) {
            CreditPool.BatchState s = _state(p, b);
            if (s != CreditPool.BatchState.Filling && s != CreditPool.BatchState.Full) continue;
            uint256[] memory ids = p.batchCredits(b);
            for (uint256 i; i < ids.length; ++i) {
                assertEq(credits.ownerOf(ids[i]), address(p), "listed credit not in pool");
                assertEq(p.batchOf(ids[i]), b, "listed credit wrong batch");
                assertTrue(p.depositorOf(ids[i]) != address(0), "listed credit unattributed");
                for (uint256 j; j < i; ++j) assertTrue(ids[j] != ids[i], "duplicate in list");
            }
            uint256 sum; uint256 nz;
            for (uint256 k; k < us.length; ++k) { uint256 sl = p.slots(b, us[k]); sum += sl; if (sl > 0) ++nz; }
            assertEq(sum, ids.length, "slots != credits");
            assertEq(nz, p.batchDepositors(b).length, "depositor list");
        }
    }
    function _users() internal view returns (address[] memory us) {
        us = new address[](5); us[0] = alice; us[1] = bob; us[2] = carol; us[3] = whale; us[4] = eve;
    }

    // ───────────── 1. Withdraw somebody else's Credit, every state ─────────────

    function test_Steal_WithdrawOthers_FillingFullEscapeDissolved() public {
        uint256[] memory a = _deposit(alice, 40);
        uint256[] memory b = _deposit(bob, 40);          // batch 0 Full
        uint256[] memory c = _deposit(carol, 10);        // batch 1 Filling

        // Filling: outsider and a depositor of another batch both fail
        _expectNotDepositor(eve, _one(c[0]));
        _expectNotDepositor(alice, _one(c[0]));
        // mixing your own id with a victim's reverts the whole call
        vm.prank(alice); vm.expectRevert(); pool.withdraw(_two(a[0], c[1]));

        // Full, pre-escape: outsiders fail, owner fails on state
        _expectNotDepositor(eve, _one(a[0]));
        _expectNotDepositor(bob, _one(a[0]));
        _expectWrongState(alice, _one(a[0]));

        // escape open, but a non-depositor cannot trigger the dissolve
        vm.warp(vm.getBlockTimestamp() + 14 days + 1);
        assertTrue(pool.escapeOpen(0));
        _expectNotDepositor(eve, _one(a[0]));
        _expectNotDepositor(carol, _one(a[0])); // depositor in batch 1 only
        assertEq(uint8(_state(pool, 0)), uint8(CreditPool.BatchState.Full));

        // alice dissolves by taking her own; still nobody can take hers or bob's
        vm.prank(alice); pool.withdraw(_one(a[0]));
        assertEq(uint8(_state(pool, 0)), uint8(CreditPool.BatchState.Dissolved));
        _expectNotDepositor(bob, _one(a[1]));
        _expectNotDepositor(alice, _one(b[0]));
        _expectNotDepositor(eve, _one(b[0]));
        // everyone gets exactly their own back
        vm.prank(bob); pool.withdraw(b);
        uint256[] memory rest = new uint256[](39);
        for (uint256 i; i < 39; ++i) rest[i] = a[i + 1];
        vm.prank(alice); pool.withdraw(rest);
        for (uint256 i; i < 40; ++i) { assertEq(credits.ownerOf(a[i]), alice); assertEq(credits.ownerOf(b[i]), bob); }
        assertEq(credits.balanceOf(address(pool)), 10); // carol's 10 untouched
        _expectNotDepositor(alice, _one(a[0])); // already out: no double-withdraw
    }

    function test_Steal_WithdrawAfterAssembly_AllLaterStates() public {
        uint256[] memory a = _deposit(alice, 40); _deposit(bob, 40);          // batch 0
        uint256[] memory w = _deposit(whale, 80);                              // batch 1
        pool.assemble(0); pool.assemble(1);

        // Assembled
        _expectUntracked(alice, _one(a[0]));
        _expectNotDepositor(eve, _one(a[0]));
        // Auction
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        pool.startAuction(0);
        _expectUntracked(alice, _one(a[0]));
        vm.prank(bidder1); pool.bid{value: 1 ether}(0);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        pool.settle(0);
        // Settled
        _expectUntracked(alice, _one(a[0]));
        // Redeemed
        vm.prank(whale); pool.redeem(1);
        _expectUntracked(whale, _one(w[0]));
        _expectNotDepositor(eve, _one(w[0]));
        // burned credits stay burned
        vm.expectRevert(); credits.ownerOf(a[0]);
        vm.expectRevert(); credits.ownerOf(w[0]);
    }

    // ───────────── 2. Deposit a Credit you don't own ─────────────

    function test_Steal_DepositVictimCredit_UsingApprovals() public {
        uint256[] memory ids = _give(alice, 2); // alice approved the pool in setUp
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(eve); vm.expectRevert(); pool.deposit{value: fee}(_one(ids[0]));
        // even with a per-token approval and approval-for-all to eve, from == msg.sender blocks it
        vm.prank(alice); credits.approve(eve, ids[0]);
        vm.prank(alice); credits.setApprovalForAll(eve, true);
        vm.prank(eve); vm.expectRevert(); pool.deposit{value: fee}(_one(ids[0]));
        vm.prank(eve); vm.expectRevert(); pool.deposit{value: fee}(_one(ids[1]));
        assertEq(credits.ownerOf(ids[0]), alice);
        assertEq(credits.ownerOf(ids[1]), alice);
        assertEq(pool.depositorOf(ids[0]), address(0));
        // a Credit already in the pool can't be "re-deposited" to hijack attribution
        uint256[] memory mine = _deposit(bob, 1);
        vm.prank(eve); vm.expectRevert(); pool.deposit{value: fee}(mine);
        vm.prank(bob); vm.expectRevert(); pool.deposit{value: fee}(mine);
        assertEq(pool.depositorOf(mine[0]), bob);
    }

    // ───────────── 3. Swap-and-pop bookkeeping ─────────────

    function test_SwapPop_EdgeOrders() public {
        uint256[] memory a = _deposit(alice, 5);   // [1,2,3,4,5]
        uint256[] memory b = _deposit(bob, 3);     // [..,6,7,8]
        address[] memory us = _users();

        vm.prank(bob); pool.withdraw(_one(b[2]));  // last element
        _checkLive(pool, us);
        vm.prank(alice); pool.withdraw(_one(a[0])); // first element, last moves to 0
        _checkLive(pool, us);
        // withdraw the element that was just moved, plus the new last, in one call
        vm.prank(bob); pool.withdraw(_two(b[1], b[0]));
        _checkLive(pool, us);
        assertEq(pool.slots(0, bob), 0);
        assertEq(pool.batchDepositors(0).length, 1);
        // reverse order drain
        uint256[] memory rev = new uint256[](4);
        for (uint256 i; i < 4; ++i) rev[i] = a[4 - i];
        vm.prank(alice); pool.withdraw(rev);
        _checkLive(pool, us);
        assertEq(pool.batchCredits(0).length, 0);
        assertEq(pool.batchDepositors(0).length, 0);
        // re-deposit everything, withdraw only element (single-element list)
        _redeposit(alice, _one(a[3]));
        vm.prank(alice); pool.withdraw(_one(a[3]));
        _checkLive(pool, us);
        _redeposit(alice, a);
        _redeposit(bob, b);
        _checkLive(pool, us);
        assertEq(pool.slots(0, alice), 5);
        assertEq(pool.slots(0, bob), 3);
        for (uint256 i; i < 5; ++i) assertEq(pool.depositorOf(a[i]), alice);
    }

    function test_SwapPop_DuplicateIdsInWithdraw() public {
        uint256[] memory a = _deposit(alice, 3);
        vm.prank(alice); vm.expectRevert(CreditPool.NotDepositor.selector); pool.withdraw(_two(a[1], a[1]));
        _checkLive(pool, _users());
        assertEq(pool.slots(0, alice), 3);
        assertEq(credits.ownerOf(a[1]), address(pool));

        // same in a Dissolved batch
        uint256[] memory x = _deposit(bob, 77); // fills batch 0
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.prank(bob); vm.expectRevert(CreditPool.NotDepositor.selector); pool.withdraw(_two(x[0], x[0]));
        vm.prank(bob); pool.withdraw(_one(x[0]));
        vm.prank(bob); vm.expectRevert(CreditPool.NotDepositor.selector); pool.withdraw(_one(x[0]));
        assertEq(pool.slots(0, bob), 76);
    }

    /// Credit withdrawn from a Dissolved batch stays in that batch's stale list; re-depositing it
    /// (and even transferring it to a new owner) must not let anyone reach it through the old batch.
    function test_SwapPop_DissolvedStaleListCannotBeAbused() public {
        uint256[] memory a = _deposit(alice, 40); _deposit(bob, 40);
        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.prank(alice); pool.withdraw(_one(a[0]));             // dissolve batch 0
        vm.prank(alice); credits.transferFrom(alice, carol, a[0]); // sold to carol
        _redeposit(carol, _one(a[0]));                          // now in batch 1 (Filling)
        assertEq(pool.depositorOf(a[0]), carol);
        assertEq(pool.batchOf(a[0]), 1);
        _expectNotDepositor(alice, _one(a[0]));
        vm.prank(carol); pool.withdraw(_one(a[0]));
        assertEq(credits.ownerOf(a[0]), carol);
        assertEq(pool.slots(0, alice), 39);
    }

    function testFuzz_SwapPop_RandomOps(uint256 seed) public {
        address[3] memory us3 = [alice, bob, carol];
        address[] memory us = _users();
        for (uint256 i; i < 3; ++i) _deposit(us3[i], 15 + (uint256(keccak256(abi.encode(seed, i))) % 10));
        for (uint256 step; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address u = us3[r % 3];
            if ((r >> 8) % 3 != 0) {
                uint256 open = pool.openBatchId();
                uint256[] memory all = pool.batchCredits(open);
                uint256 cnt;
                for (uint256 i; i < all.length; ++i) if (pool.depositorOf(all[i]) == u) ++cnt;
                if (cnt == 0) continue;
                uint256[] memory mine = new uint256[](cnt);
                uint256 k;
                for (uint256 i; i < all.length; ++i) if (pool.depositorOf(all[i]) == u) mine[k++] = all[i];
                // shuffle so we withdraw in arbitrary order
                for (uint256 i = cnt; i > 1; --i) {
                    uint256 j = uint256(keccak256(abi.encode(r, i))) % i;
                    (mine[i - 1], mine[j]) = (mine[j], mine[i - 1]);
                }
                uint256 take = 1 + (r >> 16) % cnt;
                uint256[] memory ids = new uint256[](take);
                for (uint256 i; i < take; ++i) ids[i] = mine[i];
                vm.prank(u); pool.withdraw(ids);
                for (uint256 i; i < take; ++i) assertEq(credits.ownerOf(ids[i]), u);
            } else {
                uint256[] memory held = credits.tokensOf(u);
                if (held.length == 0) continue;
                uint256 take = 1 + (r >> 16) % held.length;
                uint256[] memory ids = new uint256[](take);
                for (uint256 i; i < take; ++i) ids[i] = held[i];
                _redeposit(u, ids);
            }
            _checkLive(pool, us);
        }
    }

    // ───────────── 4. Early dissolve ─────────────

    function test_EarlyDissolve_BoundaryAndWhoCanTrigger() public {
        uint256[] memory a = _deposit(alice, 40); _deposit(bob, 40);
        (,,,,, uint64 fullAt) = pool.batchInfo(0);
        vm.warp(uint256(fullAt) + 14 days); // exactly at the boundary: still closed (strict >)
        assertFalse(pool.escapeOpen(0));
        _expectWrongState(alice, _one(a[0]));
        vm.warp(uint256(fullAt) + 14 days + 1);
        _expectNotDepositor(eve, _one(a[0]));
        assertEq(uint8(_state(pool, 0)), uint8(CreditPool.BatchState.Full));
        vm.prank(alice); pool.withdraw(_one(a[0]));
        assertEq(uint8(_state(pool, 0)), uint8(CreditPool.BatchState.Dissolved));
    }

    function test_EarlyDissolve_AssemblyNotOpenYetExtendsLock() public {
        CreditPool p = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp + 30 days, address(this));
        _approveAll(p);
        uint256[] memory a = _depositTo(p, alice, 80);
        vm.warp(vm.getBlockTimestamp() + 15 days);
        assertFalse(p.escapeOpen(0)); // clock starts at assemblyOpensAt
        vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); p.withdraw(_one(a[0]));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(alice); p.withdraw(a);
        assertEq(credits.balanceOf(alice), 80);
    }

    function test_Safe_WithdrawWorksWithDeadOracle() public {
        uint256[] memory a = _deposit(alice, 10);
        feed.set(0, 1); // dead feed
        vm.prank(alice); pool.withdraw(a);
        assertEq(credits.balanceOf(alice), 10);
    }

    // ───────────── 5. Redeem without owning all 80 ─────────────

    function test_Redeem_RequiresAll80InThatBatch() public {
        _deposit(whale, 75); _deposit(alice, 5);   // batch 0: whale 75 + alice 5
        _deposit(whale, 85);                        // batch 1: whale 80, batch 2: whale 5
        assertEq(pool.slots(1, whale), 80);
        assertEq(pool.slots(2, whale), 5);
        pool.assemble(0); pool.assemble(1);
        uint256 sid0 = _sid(pool, 0); uint256 sid1 = _sid(pool, 1);

        vm.prank(whale); vm.expectRevert(CreditPool.NotDepositor.selector); pool.redeem(0);
        vm.prank(alice); vm.expectRevert(CreditPool.NotDepositor.selector); pool.redeem(0);
        vm.prank(eve);   vm.expectRevert(CreditPool.NotDepositor.selector); pool.redeem(1);
        vm.prank(whale); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.redeem(2); // Filling

        vm.prank(whale); pool.redeem(1);
        assertEq(stmts.ownerOf(sid1), whale);
        assertEq(stmts.ownerOf(sid0), address(pool));
        vm.prank(whale); vm.expectRevert(CreditPool.WrongBatchState.selector); pool.redeem(1);
    }

    // ───────────── 6. Settle to the wrong address ─────────────

    function test_Settle_StatementOnlyToHighBidder() public {
        _deposit(alice, 40); _deposit(bob, 40); _deposit(carol, 80);
        pool.assemble(0); pool.assemble(1);
        uint256 sid0 = _sid(pool, 0); uint256 sid1 = _sid(pool, 1);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(bob); pool.setReserve(0, 1 ether);
        pool.startAuction(0);
        vm.prank(bidder1); pool.bid{value: 1 ether}(0);
        vm.prank(bidder2); pool.bid{value: 2 ether}(0);
        vm.prank(eve); vm.expectRevert(CreditPool.AuctionLive.selector); pool.settle(0);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vm.prank(eve); pool.settle(0); // third party settles
        assertEq(stmts.ownerOf(sid0), bidder2);
        assertEq(stmts.ownerOf(sid1), address(pool)); // other batch untouched
        assertEq(stmts.balanceOf(eve), 0);
        assertEq(stmts.balanceOf(bidder1), 0);
        assertEq(pool.pendingReturns(bidder1), 1 ether);
        vm.expectRevert(CreditPool.WrongBatchState.selector); pool.settle(0);
    }

    function test_Settle_NoBidsKeepsStatementInPool() public {
        _deposit(alice, 80); pool.assemble(0);
        uint256 sid = _sid(pool, 0);
        vm.prank(alice); pool.setReserve(0, 1 ether);
        vm.prank(alice); pool.startAuction(0); // sole holder starts their own auction
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        pool.settle(0);
        assertEq(stmts.ownerOf(sid), address(pool));
        assertEq(uint8(_state(pool, 0)), uint8(CreditPool.BatchState.Assembled));
        vm.prank(alice); pool.redeem(0);
        assertEq(stmts.ownerOf(sid), alice);
    }

    // ───────────── 7. Statement delivery: safeMint vs plain mint ─────────────

    function test_Statement_PlainMintHonestWorks() public {
        PlainMintStatements ps = new PlainMintStatements(credits);
        CreditPool p = deployPool(address(credits), address(ps), address(ps), address(feed), block.timestamp, address(this));
        _approveAll(p);
        _depositTo(p, alice, 80);
        p.assemble(0);
        assertEq(_sid(p, 0), 1);
        assertEq(ps.ownerOf(1), address(p));
        vm.prank(alice); p.redeem(0);
        assertEq(ps.ownerOf(1), alice);
    }

    /// FINDING: the StatementNotReceived guard only checks "balance went up by one" and
    /// "pool owns sid". A plain-mint assembler that mints a NEW Statement but returns the id of
    /// one the pool already holds for another batch passes both checks. Two batches then share
    /// one Statement; the fresh Statement is orphaned in the pool with no way out.
    // FIXED (was audit N1): a plain-mint assembler that returns an id the pool already holds for
    // another batch. statementAssigned makes assemble revert instead of double-assigning.
    function test_Fixed_PlainMintWrongReturnId_Rejected() public {
        PlainMintStatements ps = new PlainMintStatements(credits);
        CreditPool p = deployPool(address(credits), address(ps), address(ps), address(feed), block.timestamp, address(this));
        _approveAll(p);
        _depositTo(p, alice, 40); _depositTo(p, bob, 40); // batch 0
        _depositTo(p, whale, 80);                         // batch 1
        p.assemble(0);
        uint256 sid0 = _sid(p, 0);
        ps.setLie(sid0);                                  // buggy return value
        vm.expectRevert(CreditPool.StatementNotReceived.selector);
        p.assemble(1);
        assertEq(uint8(_state(p, 1)), uint8(CreditPool.BatchState.Full)); // batch 1 untouched, Credits unburned
        assertTrue(p.statementAssigned(sid0));
        // batch 0 still sells normally
        vm.prank(alice); p.setReserve(0, 1 ether);
        vm.prank(bob); p.setReserve(0, 1 ether);
        p.startAuction(0);
        vm.prank(bidder1); p.bid{value: 5 ether}(0);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        p.settle(0);
        assertEq(ps.ownerOf(sid0), bidder1);
    }

    // ───────────── 8. Assembler approval reach ─────────────

    function test_Safe_AssemblerApprovalRevokedAfterSuccessAndRevert() public {
        ThiefStatements ts = new ThiefStatements(credits, eve);
        CreditPool p = deployPool(address(credits), address(ts), address(ts), address(feed), block.timestamp, address(this));
        _approveAll(p);
        _depositTo(p, alice, 80);
        uint256[] memory c = _depositTo(p, carol, 10);
        p.assemble(0);
        assertFalse(credits.isApprovedForAll(address(p), address(ts)));
        vm.expectRevert(); ts.tryPull(address(p), c[0]); // approval is gone once assemble returns

        // A reverting assemble rolls the approval back too.
        MockStatements capped = new MockStatements(credits);
        capped.setCap(0);
        CreditPool p2 = deployPool(address(credits), address(capped), address(capped), address(feed), block.timestamp, address(this));
        _approveAll(p2);
        _depositTo(p2, bob, 80);
        vm.expectRevert(bytes("cap")); p2.assemble(0);
        assertFalse(credits.isApprovedForAll(address(p2), address(capped)));
    }

    /// FINDING (trust boundary): during assemble() the assembler is approved for EVERY Credit
    /// the pool holds (other Full batches, the Filling batch, Dissolved leftovers). The pool
    /// only checks that one Statement arrived, not that exactly the batch's 80 Credits left and
    /// nothing else moved. A malicious/compromised assembler takes everything.
    // FIXED (custody finding, then audit N-1): the assembler only ever sees the AssemblyVault,
    // which holds exactly the batch being assembled. A thief sweeping "everything the caller
    // holds" finds nothing else to take; assembly completes correctly.
    function test_Fixed_AssemblerSeesOnlyTheBatch() public {
        ThiefStatements ts = new ThiefStatements(credits, eve);
        CreditPool p = deployPool(address(credits), address(ts), address(ts), address(feed), block.timestamp, address(this));
        _approveAll(p);
        _depositTo(p, alice, 80);                       // batch 0
        _depositTo(p, bob, 80);                         // batch 1 (Full, other batch)
        uint256[] memory c = _depositTo(p, carol, 30);  // batch 2 (Filling)
        ts.arm(true);
        p.assemble(0);
        assertEq(credits.balanceOf(eve), 0, "thief got nothing");
        assertEq(credits.balanceOf(address(p)), 110, "batch 1 + filling batch untouched");
        assertEq(credits.balanceOf(address(p.vault())), 0, "vault empty after the call");
        vm.prank(carol); p.withdraw(_one(c[0]));
        assertEq(credits.ownerOf(c[0]), carol);
    }

    // A thief aiming at the POOL directly is refused: the pool never approves anyone.
    function test_Fixed_AssemblerCannotReachPool() public {
        PoolThiefStatements pt = new PoolThiefStatements(credits, eve);
        CreditPool p = deployPool(address(credits), address(pt), address(pt), address(feed), block.timestamp, address(this));
        pt.setPool(address(p));
        _approveAll(p);
        _depositTo(p, alice, 80);
        _depositTo(p, bob, 80);
        vm.expectRevert();                              // transferFrom(pool, ...) has no approval
        p.assemble(0);
        assertEq(credits.balanceOf(eve), 0);
        assertEq(credits.balanceOf(address(p)), 160, "nothing moved, nothing burned");
        assertFalse(credits.isApprovedForAll(address(p), address(pt)));
    }

    // Audit N-1: burn the 80, push a cheap Credit back in so the numbers add up. Caught.
    function test_Fixed_SwapInCaught() public {
        SwapInStatements sw = new SwapInStatements(credits);
        CreditPool p = deployPool(address(credits), address(sw), address(sw), address(feed), block.timestamp, address(this));
        _approveAll(p);
        uint256[] memory a = _depositTo(p, alice, 80);
        uint256[] memory cheap = _give(address(sw), 1);
        sw.setCheap(cheap[0]);
        vm.expectRevert(CreditPool.CreditsNotBurned.selector);
        p.assemble(0);
        assertEq(credits.ownerOf(a[0]), address(p));    // whole call undone
        assertEq(credits.ownerOf(cheap[0]), address(sw));
    }

    /// FINDING (integration): a buggy assembler that burns the wrong 80 ids is accepted.
    /// Batch 0's own Credits get stuck forever (its state is Assembled so withdraw reverts),
    /// while other depositors' Credits are the ones that got burned.
    // FIXED (was a finding): a buggy assembler that burns "the last 80 the caller holds"
    // used to hit another batch. Via the vault, the last 80 the caller holds ARE this batch.
    function test_Fixed_AssemblerCannotBurnWrongIds() public {
        WrongIdsStatements ws = new WrongIdsStatements(credits);
        CreditPool p = deployPool(address(credits), address(ws), address(ws), address(feed), block.timestamp, address(this));
        _approveAll(p);
        uint256[] memory a = _depositTo(p, alice, 80); // batch 0
        uint256[] memory c = _depositTo(p, carol, 30); // batch 1 Filling
        p.assemble(0);
        for (uint256 i; i < 30; ++i) assertEq(credits.ownerOf(c[i]), address(p)); // carol's are untouched
        vm.expectRevert(); credits.ownerOf(a[0]);      // batch 0's own Credits were the ones burned
        vm.prank(carol); p.withdraw(_one(c[0]));
        assertEq(credits.ownerOf(c[0]), carol);
    }

    // ───────────── 9. Incompatible real assembler → escape hatch recovery ─────────────

    function test_Integration_IncompatibleAssemblers_EscapeReturnsEverything() public {
        address[3] memory asms = [
            address(new FeeStatements(credits)),
            address(new EoaOnlyStatements(credits)),
            address(new OtherSigStatements(credits))
        ];
        for (uint256 k; k < 3; ++k) {
            CreditPool p = deployPool(address(credits), asms[k], asms[k], address(feed), block.timestamp, address(this));
            _approveAll(p);
            uint256[] memory a = _depositTo(p, alice, 50);
            uint256[] memory b = _depositTo(p, bob, 30);
            vm.expectRevert(); p.assemble(0);
            vm.prank(alice); vm.expectRevert(CreditPool.WrongBatchState.selector); p.withdraw(a);
            vm.warp(vm.getBlockTimestamp() + 14 days + 1);
            vm.prank(alice); p.withdraw(a);
            vm.prank(bob); p.withdraw(b);
            assertEq(credits.balanceOf(address(p)), 0);
            assertEq(credits.ownerOf(a[0]), alice);
            assertEq(credits.ownerOf(b[0]), bob);
        }
    }

    // ───────────── 10. Stray NFTs ─────────────

    function test_Stray_PlainTransferCreditIsStuckButHarmless() public {
        uint256[] memory a = _deposit(alice, 79);
        uint256[] memory s = _give(eve, 1);
        vm.prank(eve); credits.transferFrom(eve, address(pool), s[0]); // no hook on plain transfer
        assertEq(pool.depositorOf(s[0]), address(0));
        _expectNotDepositor(eve, _one(s[0]));   // sender cannot recover it (no rescue fn)
        _expectNotDepositor(alice, _one(s[0]));
        // it is not counted in any batch and does not disturb assembly
        _deposit(bob, 1);
        pool.assemble(0);
        assertEq(credits.ownerOf(s[0]), address(pool));
        vm.expectRevert(); credits.ownerOf(a[0]);
    }

    function test_Stray_StatementDoesNotConfuseAssembly() public {
        // someone makes a Statement outside the pool and plain-transfers it in
        uint256[] memory x = _give(eve, 80);
        vm.prank(eve); credits.setApprovalForAll(address(stmts), true);
        vm.prank(eve); uint256 stray = stmts.assemble(x);
        vm.prank(eve); vm.expectRevert(); stmts.safeTransferFrom(eve, address(pool), stray); // bounces
        vm.prank(eve); stmts.transferFrom(eve, address(pool), stray);                      // sticks
        _deposit(alice, 80);
        pool.assemble(0);
        uint256 sid = _sid(pool, 0);
        assertTrue(sid != stray);
        vm.prank(alice); pool.redeem(0);
        assertEq(stmts.ownerOf(sid), alice);
        assertEq(stmts.ownerOf(stray), address(pool));
    }

    // ───────────── 11. Reentrancy via receiver hooks ─────────────

    function test_Safe_NoReceiverHooksOnWithdrawRedeemSettle() public {
        HookedActor h = new HookedActor(pool, credits);
        vm.deal(address(h), 10 ether);
        uint256[] memory x = _give(address(h), 90);
        uint256[] memory first80 = new uint256[](80);
        for (uint256 i; i < 80; ++i) first80[i] = x[i];
        uint256[] memory last10 = new uint256[](10);
        for (uint256 i; i < 10; ++i) last10[i] = x[80 + i];
        uint256 fee = pool.depositFeeFor(first80.length);
        h.deposit{value: fee}(first80);
        h.deposit{value: fee}(last10);
        uint256[] memory aliceIds = _deposit(alice, 5); // victim in same Filling batch
        h.arm(false, aliceIds);                          // hook would try to steal alice's
        pool.assemble(0);
        h.redeem(0);
        assertEq(stmts.ownerOf(_sid(pool, 0)), address(h));
        h.withdraw(last10);
        assertFalse(h.hookHit(), "transferFrom never calls hooks");
        for (uint256 i; i < 5; ++i) assertEq(credits.ownerOf(aliceIds[i]), address(pool));

        // settle to a hooked contract
        _deposit(bob, 80); pool.assemble(1);
        vm.prank(bob); pool.setReserve(1, 1 ether);
        pool.startAuction(1);
        h.bid{value: 1 ether}(1);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        pool.settle(1);
        assertEq(stmts.ownerOf(_sid(pool, 1)), address(h));
        assertFalse(h.hookHit());
    }

    function test_Safe_DepositRefundReentryIntoWithdrawBlocked() public {
        HookedActor h = new HookedActor(pool, credits);
        vm.deal(address(h), 10 ether);
        uint256[] memory x = _give(address(h), 3);
        h.arm(true, x); // on the refund, try to pull the credits straight back out
        vm.expectRevert(CreditPool.TransferFailed.selector);
        h.deposit{value: 1 ether}(x);
        assertEq(credits.ownerOf(x[0]), address(h));
        assertEq(pool.depositorOf(x[0]), address(0));
    }

    // ───────────── 12. Real Credits contract (burn(owner, ids)) ─────────────

    function _realCredits(address holder, uint256 n) internal returns (Credits rc) {
        rc = new Credits(address(this));
        address[] memory to = new address[](n);
        bytes21[] memory seeds = new bytes21[](n);
        uint64[] memory ts = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            bytes memory s = bytes("AAAAAAAAAAAAAAAAAA000");
            s[18] = bytes1(uint8(48 + (i / 100) % 10));
            s[19] = bytes1(uint8(48 + (i / 10) % 10));
            s[20] = bytes1(uint8(48 + i % 10));
            to[i] = holder; seeds[i] = bytes21(s); ts[i] = uint64(block.timestamp);
        }
        rc.distribute(to, seeds, ts);
    }

    function test_Integration_RealCreditsBurnPath() public {
        Credits rc = _realCredits(alice, 90);
        RealCreditsStatements rs = new RealCreditsStatements(rc);
        CreditPool p = deployPool(address(rc), address(rs), address(rs), address(feed), block.timestamp, address(this));
        vm.prank(alice); rc.setApprovalForAll(address(p), true);
        uint256[] memory ids = new uint256[](80);
        for (uint256 i; i < 80; ++i) ids[i] = i + 1;
        uint256 fee = p.depositFeeFor(ids.length);
        vm.prank(alice); p.deposit{value: fee}(ids);
        uint256[] memory extra = new uint256[](10);
        for (uint256 i; i < 10; ++i) extra[i] = 81 + i;
        vm.prank(alice); p.deposit{value: fee}(extra); // batch 1 Filling

        // not sealed → real burn reverts → nothing moves, escape later
        vm.expectRevert(Credits.NotSealed.selector); p.assemble(0);
        assertEq(rc.ownerOf(1), address(p));
        rc.seal();
        uint256 g = gasleft();
        p.assemble(0);
        emit log_named_uint("assemble with real Credits.burn, gas", g - gasleft());
        vm.expectRevert(); rc.ownerOf(1);
        assertEq(rc.ownerOf(81), address(p)); // other batch untouched
        assertFalse(rc.isApprovedForAll(address(p), address(rs)));
        vm.prank(alice); p.redeem(0);
        assertEq(rs.ownerOf(1), alice);
        vm.prank(alice); p.withdraw(extra);
        assertEq(rc.balanceOf(alice), 10);
    }
}

// ════════════════════════════════════════════════════════════════════════════════
//  Handler-based invariant
// ════════════════════════════════════════════════════════════════════════════════

contract CustodyHandler is Test {
    CreditPool public pool; MockCredits public credits; MockStatements public stmts;
    address[4] public users;
    address public eve = address(0xE7E);
    address[2] public bidders;
    uint256 nextId = 1;

    uint256[] public inPool;                       // ghost: Credits the pool should hold
    mapping(uint256 => uint256) posInPool;         // 1-based
    mapping(uint256 => address) public ghostDepositor;
    mapping(uint256 => address) public lastDepositor;
    uint256[] public everDeposited;
    mapping(uint256 => bool) seen;
    mapping(uint256 => bool) public ghostBurned;
    uint256[] public burnedList;
    mapping(uint256 => address) public ghostStmtOwner;

    bool public breach;
    string public breachWhy;
    uint256 public nAssembled; uint256 public nSettled; uint256 public nRedeemed; uint256 public nDissolveWithdraws;

    constructor(CreditPool p, MockCredits c, MockStatements s) {
        pool = p; credits = c; stmts = s;
        for (uint256 i; i < 4; ++i) {
            users[i] = address(uint160(0xA11CE + i));
            vm.deal(users[i], 1_000_000 ether);
            vm.prank(users[i]); credits.setApprovalForAll(address(pool), true);
        }
        bidders[0] = address(0xB1D0); bidders[1] = address(0xB1D1);
        vm.deal(eve, 1000 ether);
        vm.prank(eve); credits.setApprovalForAll(address(pool), true);
    }

    // ── ghost helpers ──
    function _add(uint256 id, address who) internal {
        inPool.push(id); posInPool[id] = inPool.length;
        ghostDepositor[id] = who; lastDepositor[id] = who;
        if (!seen[id]) { seen[id] = true; everDeposited.push(id); }
    }
    function _remove(uint256 id) internal {
        uint256 i = posInPool[id] - 1;
        uint256 last = inPool[inPool.length - 1];
        inPool[i] = last; posInPool[last] = i + 1;
        inPool.pop(); delete posInPool[id]; delete ghostDepositor[id];
    }
    function _flag(string memory why) internal { breach = true; breachWhy = why; }
    function _st(uint256 b) internal view returns (CreditPool.BatchState s) { (s,,,,,) = pool.batchInfo(b); }
    function _pickBatch(uint256 b) internal view returns (bool ok, uint256 r) {
        uint256 open = pool.openBatchId();
        if (open == 0) return (false, 0);
        return (true, bound(b, 0, open - 1));
    }

    // ── honest actions ──
    function deposit(uint256 who, uint256 n, bool reuse) external {
        address u = users[who % 4];
        uint256[] memory held = credits.tokensOf(u);
        uint256[] memory ids;
        if (reuse && held.length > 0) {
            n = bound(n, 1, held.length);
            ids = new uint256[](n);
            for (uint256 i; i < n; ++i) ids[i] = held[i];
        } else {
            n = bound(n, 1, 100);
            ids = new uint256[](n);
            for (uint256 i; i < n; ++i) { credits.mint(u, nextId); ids[i] = nextId++; }
        }
        uint256 fee = pool.depositFeeFor(ids.length);
        vm.prank(u); pool.deposit{value: fee}(ids);
        for (uint256 i; i < n; ++i) _add(ids[i], u);
    }

    function withdrawOpen(uint256 who, uint256 seed) external {
        address u = users[who % 4];
        uint256[] memory all = pool.batchCredits(pool.openBatchId());
        _withdrawFrom(u, all, pool.openBatchId(), seed);
    }

    function withdrawEscaped(uint256 who, uint256 b, uint256 seed) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok) return;
        CreditPool.BatchState s = _st(bb);
        if (!(s == CreditPool.BatchState.Dissolved || (s == CreditPool.BatchState.Full && pool.escapeOpen(bb)))) return;
        address u = users[who % 4];
        _withdrawFrom(u, pool.batchCredits(bb), bb, seed);
        if (credits.balanceOf(address(pool)) != inPool.length) _flag("escape withdraw ghost drift");
    }

    function _withdrawFrom(address u, uint256[] memory all, uint256 b, uint256 seed) internal {
        uint256 cnt;
        for (uint256 i; i < all.length; ++i) if (pool.depositorOf(all[i]) == u && pool.batchOf(all[i]) == b) ++cnt;
        if (cnt == 0) return;
        uint256[] memory mine = new uint256[](cnt);
        uint256 k;
        for (uint256 i; i < all.length; ++i) if (pool.depositorOf(all[i]) == u && pool.batchOf(all[i]) == b) mine[k++] = all[i];
        for (uint256 i = cnt; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (mine[i - 1], mine[j]) = (mine[j], mine[i - 1]);
        }
        uint256 take = bound(seed, 1, cnt);
        uint256[] memory ids = new uint256[](take);
        for (uint256 i; i < take; ++i) ids[i] = mine[i];
        bool dissolving = _st(b) != CreditPool.BatchState.Filling;
        vm.prank(u); pool.withdraw(ids);
        for (uint256 i; i < take; ++i) {
            if (credits.ownerOf(ids[i]) != u) _flag("withdraw sent credit elsewhere");
            _remove(ids[i]);
        }
        if (dissolving) ++nDissolveWithdraws;
    }

    function warp(uint256 dt) external { vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 20 days)); }

    function assemble(uint256 b) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok || _st(bb) != CreditPool.BatchState.Full) return;
        uint256[] memory ids = pool.batchCredits(bb);
        pool.assemble(bb);
        for (uint256 i; i < ids.length; ++i) { _remove(ids[i]); ghostBurned[ids[i]] = true; burnedList.push(ids[i]); }
        ++nAssembled;
    }

    function startAuction(uint256 b) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok || _st(bb) != CreditPool.BatchState.Assembled) return;
        if (!pool.noReserveOpen(bb)) {
            for (uint256 i; i < 4; ++i) if (pool.slots(bb, users[i]) > 0) { vm.prank(users[i]); pool.setReserve(bb, 1 ether); }
        }
        address[] memory ds = pool.batchDepositors(bb);
        if (ds.length == 1) vm.prank(ds[0]); // only a sole holder may auction their own batch
        pool.startAuction(bb);
    }

    function bid(uint256 b, uint256 who, uint256 extra) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok || _st(bb) != CreditPool.BatchState.Auction) return;
        (address hb, uint256 hbid, uint256 reserve, uint64 endsAt) = pool.auctions(bb);
        if (block.timestamp >= endsAt) return;
        uint256 minBid = hb == address(0) ? reserve : hbid + (hbid * 500) / 10_000;
        if (minBid == 0) minBid = 1;
        uint256 amt = minBid + bound(extra, 0, 1 ether);
        address bidder = who % 3 == 2 ? users[who % 4] : bidders[who % 2];
        vm.deal(bidder, bidder.balance + amt);
        vm.prank(bidder); pool.bid{value: amt}(bb);
    }

    function settle(uint256 b) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok || _st(bb) != CreditPool.BatchState.Auction) return;
        (address hb,,, uint64 endsAt) = pool.auctions(bb);
        if (block.timestamp < endsAt) return;
        pool.settle(bb);
        if (hb != address(0)) { ghostStmtOwner[bb] = hb; ++nSettled; }
    }

    function redeem(uint256 b) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok || _st(bb) != CreditPool.BatchState.Assembled) return;
        for (uint256 i; i < 4; ++i) {
            if (pool.slots(bb, users[i]) == 80) {
                vm.prank(users[i]); pool.redeem(bb);
                ghostStmtOwner[bb] = users[i]; ++nRedeemed;
                return;
            }
        }
    }

    // ── attacks (must all fail; success raises `breach`) ──
    function attackWithdrawOthers(uint256 seed, uint256 att) external {
        if (inPool.length == 0) return;
        uint256 id = inPool[seed % inPool.length];
        address dep = ghostDepositor[id];
        address a = att % 5 == 4 ? eve : users[att % 4];
        if (a == dep) a = eve;
        uint256[] memory ids = new uint256[](1); ids[0] = id;
        vm.prank(a);
        try pool.withdraw(ids) { _flag("withdrew someone else's credit"); } catch {}
    }

    function attackDepositOthers(uint256 who, uint256 seed) external {
        address victim = users[who % 4];
        uint256[] memory held = credits.tokensOf(victim);
        if (held.length == 0) return;
        uint256[] memory ids = new uint256[](1); ids[0] = held[seed % held.length];
        address a = users[(who % 4 + 1) % 4];
        uint256 fee = pool.depositFeeFor(ids.length);
        vm.prank(eve);
        try pool.deposit{value: fee}(ids) { _flag("eve deposited victim's credit"); } catch {}
        vm.prank(a);
        try pool.deposit{value: fee}(ids) { _flag("user deposited victim's credit"); } catch {}
    }

    function attackWithdrawLocked(uint256 seed) external {
        if (inPool.length > 0) {
            uint256 id = inPool[seed % inPool.length];
            uint256 b = pool.batchOf(id);
            if (_st(b) == CreditPool.BatchState.Full && !pool.escapeOpen(b)) {
                uint256[] memory ids = new uint256[](1); ids[0] = id;
                vm.prank(ghostDepositor[id]);
                try pool.withdraw(ids) { _flag("withdrew from locked Full batch"); } catch {}
            }
        }
        if (burnedList.length > 0) {
            uint256 id = burnedList[seed % burnedList.length];
            uint256[] memory ids = new uint256[](1); ids[0] = id;
            vm.prank(lastDepositor[id]);
            try pool.withdraw(ids) { _flag("withdrew assembled credit"); } catch {}
        }
    }

    function attackDupWithdraw(uint256 seed) external {
        if (inPool.length == 0) return;
        uint256 id = inPool[seed % inPool.length];
        uint256[] memory ids = new uint256[](2); ids[0] = id; ids[1] = id;
        vm.prank(ghostDepositor[id]);
        try pool.withdraw(ids) { _flag("duplicate-id withdraw succeeded"); } catch {}
    }

    function attackRedeemPartial(uint256 b, uint256 who) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok) return;
        address u = who % 5 == 4 ? eve : users[who % 4];
        if (pool.slots(bb, u) == 80) return;
        vm.prank(u);
        try pool.redeem(bb) { _flag("redeem without 80 slots"); } catch {}
    }

    function attackSettleEarly(uint256 b) external {
        (bool ok, uint256 bb) = _pickBatch(b);
        if (!ok || _st(bb) != CreditPool.BatchState.Auction) return;
        (,,, uint64 endsAt) = pool.auctions(bb);
        if (block.timestamp >= endsAt) return;
        try pool.settle(bb) { _flag("settled live auction"); } catch {}
    }

    // ── views for invariants ──
    function inPoolLength() external view returns (uint256) { return inPool.length; }
    function everLength() external view returns (uint256) { return everDeposited.length; }
    function userAt(uint256 i) external view returns (address) { return users[i]; }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract NftCustodyInvariantTest is Test {
    CreditPool pool; MockCredits credits; MockStatements stmts; CustodyHandler h;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        MockFeed feed = new MockFeed(2500e8);
        pool = deployPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, address(this));
        h = new CustodyHandler(pool, credits, stmts);
        targetContract(address(h));
    }

    function _st(uint256 b) internal view returns (CreditPool.BatchState s) { (s,,,,,) = pool.batchInfo(b); }

    /// Every Credit the pool owns is attributed to exactly one depositor in exactly one batch that
    /// can still release it (Filling/Full via its live list, or Dissolved), and
    /// credits.balanceOf(pool) equals the ghost count.
    function invariant_PoolCreditsAttributedExactlyOnce() public view {
        uint256[] memory owned = credits.tokensOf(address(pool));
        assertEq(owned.length, credits.balanceOf(address(pool)));
        assertEq(credits.balanceOf(address(pool)), h.inPoolLength(), "balance != ghost");
        uint256 open = pool.openBatchId();
        uint256[] memory dissolvedHeld = new uint256[](open + 1);
        uint256 dissolvedTotal;
        for (uint256 i; i < owned.length; ++i) {
            uint256 id = owned[i];
            address d = pool.depositorOf(id);
            assertTrue(d != address(0), "pool holds unattributed credit");
            assertEq(d, h.ghostDepositor(id), "depositor != ghost");
            uint256 b = pool.batchOf(id);
            CreditPool.BatchState s = _st(b);
            assertTrue(s == CreditPool.BatchState.Filling || s == CreditPool.BatchState.Full || s == CreditPool.BatchState.Dissolved,
                "held credit attributed to a non-live batch");
            if (s == CreditPool.BatchState.Dissolved) { dissolvedHeld[b]++; dissolvedTotal++; }
        }
        uint256 listed;
        for (uint256 b; b <= open; ++b) {
            CreditPool.BatchState s = _st(b);
            uint256 sum;
            for (uint256 k; k < 4; ++k) sum += pool.slots(b, h.userAt(k));
            if (s == CreditPool.BatchState.Filling || s == CreditPool.BatchState.Full) {
                uint256[] memory ids = pool.batchCredits(b);
                listed += ids.length;
                for (uint256 i; i < ids.length; ++i) {
                    assertEq(credits.ownerOf(ids[i]), address(pool), "listed but not held");
                    assertEq(pool.batchOf(ids[i]), b, "listed in wrong batch");
                    assertTrue(pool.slots(b, pool.depositorOf(ids[i])) > 0, "listed credit, depositor has no slot");
                    for (uint256 j; j < i; ++j) assertTrue(ids[j] != ids[i], "duplicate in live list");
                }
                assertEq(sum, ids.length, "slots != live list");
                if (s == CreditPool.BatchState.Full) assertEq(ids.length, 80);
                else assertLt(ids.length, 80);
            } else if (s == CreditPool.BatchState.Dissolved) {
                assertEq(sum, dissolvedHeld[b], "dissolved slots != credits still held");
            } else {
                assertEq(sum, 80, "assembled batch slots changed");
            }
        }
        assertEq(listed + dissolvedTotal, owned.length, "held credits not in exactly one live batch");
    }

    /// Credits never leave to anyone but the account that deposited them (or get burned by assembly).
    function invariant_CreditsNeverLeakToNonDepositor() public view {
        uint256 n = h.everLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.everDeposited(i);
            try credits.ownerOf(id) returns (address o) {
                if (o == address(pool)) assertEq(h.ghostDepositor(id), h.lastDepositor(id));
                else assertEq(o, h.lastDepositor(id), "credit reached a non-depositor");
            } catch {
                assertTrue(h.ghostBurned(id), "credit vanished outside assembly");
            }
        }
    }

    /// Each Assembled/Auction batch maps to a distinct Statement held by the pool; Settled/Redeemed
    /// Statements are with the winner / redeemer.
    function invariant_StatementCustody() public view {
        uint256 open = pool.openBatchId();
        uint256[] memory sids = new uint256[](open);
        uint256 n; uint256 held;
        for (uint256 b; b < open; ++b) {
            CreditPool.BatchState s = _st(b);
            if (uint8(s) < uint8(CreditPool.BatchState.Assembled) || s == CreditPool.BatchState.Dissolved) continue;
            (,,, uint256 sid,,) = pool.batchInfo(b);
            for (uint256 j; j < n; ++j) assertTrue(sids[j] != sid, "two batches share a Statement");
            sids[n++] = sid;
            if (s == CreditPool.BatchState.Assembled || s == CreditPool.BatchState.Auction) {
                assertEq(stmts.ownerOf(sid), address(pool), "live Statement not in pool");
                ++held;
            } else {
                assertEq(stmts.ownerOf(sid), h.ghostStmtOwner(b), "Statement went to wrong address");
            }
        }
        assertEq(stmts.balanceOf(address(pool)), held, "pool Statement count != live assembled batches");
    }

    function invariant_NoAttackSucceeded() public view {
        assertFalse(h.breach(), h.breachWhy());
    }

    /// Proves the handler can actually reach every custody exit (settle, redeem, dissolve-withdraw)
    /// and that all invariants hold along the way.
    function test_HandlerReachesEveryExitPath() public {
        h.deposit(0, 80, false);                 // batch 0: user0 x80 → redeemable
        h.deposit(1, 40, false); h.deposit(2, 40, false); // batch 1: auctioned
        h.deposit(3, 80, false);                 // batch 2: left to escape
        h.deposit(1, 10, false);                 // batch 3 Filling
        h.withdrawOpen(1, 3);
        h.deposit(1, 1, true);                   // re-deposit a withdrawn one
        h.assemble(0); h.assemble(1);
        h.redeem(0);
        h.startAuction(1);
        h.bid(1, 0, 0); h.bid(1, 1, 5);
        h.attackSettleEarly(1);
        h.warp(25 hours);
        h.settle(1);
        h.warp(15 days);
        h.withdrawEscaped(3, 2, 7);
        h.withdrawEscaped(3, 2, 200);
        for (uint256 s; s < 20; ++s) { h.attackWithdrawOthers(s, s); h.attackDupWithdraw(s); h.attackWithdrawLocked(s); h.attackDepositOthers(s, s); h.attackRedeemPartial(s % 4, s); }
        assertEq(h.nRedeemed(), 1); assertEq(h.nSettled(), 1); assertGt(h.nDissolveWithdraws(), 0);
        assertEq(uint8(_st(2)), uint8(CreditPool.BatchState.Dissolved));
        invariant_PoolCreditsAttributedExactlyOnce();
        invariant_CreditsNeverLeakToNonDepositor();
        invariant_StatementCustody();
        invariant_NoAttackSucceeded();
    }
}
