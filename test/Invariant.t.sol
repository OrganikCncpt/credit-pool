// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";

contract Handler is Test {
    CreditPool pool; MockCredits credits;
    address[4] public users;
    uint256 nextId = 1;
    uint256[] public inPool; // every Credit currently held by the pool (ghost)

    constructor(CreditPool p, MockCredits c) {
        pool = p; credits = c;
        for (uint256 i; i < 4; ++i) {
            users[i] = address(uint160(0xA11CE + i));
            vm.deal(users[i], 1000 ether);
            vm.prank(users[i]); credits.setApprovalForAll(address(pool), true);
        }
    }

    function deposit(uint256 who, uint256 n) external {
        address u = users[who % 4];
        n = bound(n, 1, 120);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(u, nextId); ids[i] = nextId++; inPool.push(ids[i]); }
        uint256 fee = pool.depositFee() * ids.length; // $1 per Credit
        vm.prank(u); pool.deposit{value: fee}(ids);
    }

    function withdraw(uint256 who, uint256 seed) external {
        address u = users[who % 4];
        // collect u's Credits sitting in the open batch
        uint256 open = pool.openBatchId();
        uint256[] memory all = pool.batchCredits(open);
        uint256 cnt;
        for (uint256 i; i < all.length; ++i) if (pool.depositorOf(all[i]) == u) ++cnt;
        if (cnt == 0) return;
        uint256 take = bound(seed, 1, cnt);
        uint256[] memory ids = new uint256[](take);
        uint256 k;
        for (uint256 i; i < all.length && k < take; ++i) if (pool.depositorOf(all[i]) == u) ids[k++] = all[i];
        vm.prank(u); pool.withdraw(ids);
        for (uint256 j; j < take; ++j) _drop(ids[j]);
    }

    function assemble(uint256 b) external {
        uint256 open = pool.openBatchId();
        if (open == 0) return;
        b = bound(b, 0, open - 1);
        (CreditPool.BatchState s,,,,,) = pool.batchInfo(b);
        if (s != CreditPool.BatchState.Full) return;
        uint256[] memory ids = pool.batchCredits(b);
        pool.assemble(b);
        for (uint256 j; j < ids.length; ++j) _drop(ids[j]);
    }

    function _drop(uint256 id) internal {
        for (uint256 i; i < inPool.length; ++i) if (inPool[i] == id) { inPool[i] = inPool[inPool.length - 1]; inPool.pop(); return; }
    }
    function inPoolLength() external view returns (uint256) { return inPool.length; }
    function userAt(uint256 i) external view returns (address) { return users[i]; }
}

contract InvariantTest is Test {
    CreditPool pool; MockCredits credits; MockStatements stmts; Handler h;

    function setUp() public {
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        MockFeed feed = new MockFeed(2500e8);
        pool = new CreditPool(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, address(this));
        h = new Handler(pool, credits);
        targetContract(address(h));
    }

    /// The pool owns exactly the Credits the ghost says it does.
    function invariant_PoolHoldsExactlyTracked() public view {
        assertEq(credits.balanceOf(address(pool)), h.inPoolLength());
    }

    /// Every batch below the open one is full-or-later; the open one is Filling with < 80.
    function invariant_BatchShape() public view {
        uint256 open = pool.openBatchId();
        (CreditPool.BatchState s, uint256 filled,,,,) = pool.batchInfo(open);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Filling));
        assertLt(filled, 80);
        for (uint256 b; b < open; ++b) {
            (CreditPool.BatchState sb, uint256 fb,,,,) = pool.batchInfo(b);
            assertTrue(sb != CreditPool.BatchState.Filling);
            assertEq(fb, 80);
        }
    }

    /// Slots in each batch sum to its Credit count, and depositor list matches non-zero slots.
    function invariant_SlotsSumToCredits() public view {
        uint256 open = pool.openBatchId();
        for (uint256 b; b <= open; ++b) {
            (, uint256 filled, uint256 deps,,,) = pool.batchInfo(b);
            uint256 sum; uint256 nonzero;
            for (uint256 i; i < 4; ++i) {
                uint256 s = pool.slots(b, h.userAt(i));
                sum += s; if (s > 0) ++nonzero;
            }
            assertEq(sum, filled);
            assertEq(nonzero, deps);
        }
    }

    /// Every Credit in the open batch is owned by the pool and attributed to a depositor.
    function invariant_OpenBatchCreditsOwned() public view {
        uint256 open = pool.openBatchId();
        uint256[] memory ids = pool.batchCredits(open);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(credits.ownerOf(ids[i]), address(pool));
            assertTrue(pool.depositorOf(ids[i]) != address(0));
            assertEq(pool.batchOf(ids[i]), open);
        }
    }
}
