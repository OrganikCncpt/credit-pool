// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console2} from "forge-std/Test.sol";
import {BackedPool} from "../src/BackedPool.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";
import {deployBacked} from "./BackedPool.t.sol";

/// Random walks through every BackedPool action. Tracks what the pool owes so the invariants can
/// check every wei and every Credit is accounted for.
contract BackedHandler is Test {
    BackedPool public pool; MockCredits public credits; MockStatements public stmts;
    address[] public actors;
    uint256 nextId = 1;
    uint256 public batchesTouched = 1;
    uint256 public sold; uint256 public unwound;

    constructor(BackedPool p, MockCredits c, MockStatements s) {
        pool = p; credits = c; stmts = s;
        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string.concat("bi-actor", vm.toString(i)));
            actors.push(a);
            vm.deal(a, 1_000 ether);
            vm.prank(a); credits.setApprovalForAll(address(p), true);
        }
    }

    function actorsList() external view returns (address[] memory) { return actors; }
    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }
    function _batch(uint256 s) internal view returns (uint256) { return s % (pool.openBatchId() + 1); }

    function deposit(uint256 who, uint256 n) external {
        address a = _actor(who);
        n = bound(n, 1, 40);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(a, nextId); ids[i] = nextId++; }
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(a); pool.deposit{value: fee}(ids);
        if (pool.openBatchId() + 1 > batchesTouched) batchesTouched = pool.openBatchId() + 1;
    }

    function withdraw(uint256 who, uint256 bs, uint256 k) external {
        address a = _actor(who); uint256 b = _batch(bs);
        uint256[] memory ids = pool.batchCredits(b);
        if (ids.length == 0) return;
        uint256 id = ids[k % ids.length];
        if (pool.depositorOf(id) != a) return;
        uint256[] memory one = new uint256[](1); one[0] = id;
        vm.prank(a);
        try pool.withdraw(one) {} catch {}
    }

    function refill(uint256 who, uint256 bs) external {
        address a = _actor(who); uint256 b = _batch(bs);
        (BackedPool.BatchState st, uint256 filled,,,,,) = pool.batchInfo(b);
        if (st != BackedPool.BatchState.Filling || b >= pool.openBatchId()) return;
        uint256 n = 80 - filled;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(a, nextId); ids[i] = nextId++; }
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(a); pool.depositInto{value: fee}(b, ids, filled);
    }

    function vote(uint256 who, uint256 bs, uint256 price) external {
        address a = _actor(who);
        vm.prank(a);
        try pool.setReserve(_batch(bs), bound(price, 0, 5 ether)) {} catch {}
    }

    function back(uint256 who, uint256 bs, uint256 amt) external {
        address a = _actor(who);
        vm.prank(a);
        try pool.back{value: bound(amt, 80, 3 ether)}(_batch(bs)) {} catch {}
    }

    function unback(uint256 who, uint256 bs) external {
        vm.prank(_actor(who));
        try pool.withdrawBacking(_batch(bs)) {} catch {}
    }

    function start(uint256 bs) external {
        uint256 b = _batch(bs);
        (, uint256 open) = pool.bestBacking(b);
        try pool.startAuction(b, open) {} catch {}
    }

    function bid(uint256 who, uint256 bs, uint256 extra) external {
        uint256 b = _batch(bs);
        uint256 v = pool.minNextBid(b) + bound(extra, 0, 1 ether);
        vm.prank(_actor(who));
        try pool.bid{value: v}(b) {} catch {}
    }

    function wait(uint256 secs) external { vm.warp(block.timestamp + bound(secs, 1, 2 days)); }

    function breakAssembler(bool broken) external { stmts.setCap(broken ? 0 : type(uint256).max); }

    function settle(uint256 bs) external {
        uint256 b = _batch(bs);
        uint256 u = _unwindCount(b);
        try pool.settle(b) { _count(b, u); } catch {}
    }

    function claim(uint256 who, uint256 bs) external {
        vm.prank(_actor(who));
        try pool.claim(_batch(bs)) {} catch {}
    }

    function refund(uint256 who) external {
        vm.prank(_actor(who));
        try pool.withdrawRefund() {} catch {}
    }

    function sweep() external { pool.sweepFees(); }

    /// Pushes one batch a step along its lifecycle so random walks reach sales, unwinds and expiries.
    function drive(uint256 who, uint256 bs, uint256 coin) external {
        uint256 b = _batch(bs);
        uint256 steps = 1 + coin % 5;
        for (uint256 i; i < steps; ++i) _step(who, b, coin >> i);
    }

    function _step(uint256 who, uint256 b, uint256 coin) internal {
        address a = _actor(who);
        (BackedPool.BatchState s, uint256 filled,,,,,) = pool.batchInfo(b);
        if (s == BackedPool.BatchState.Filling) {
            uint256 n = 80 - filled;
            uint256[] memory ids = new uint256[](n);
            for (uint256 i; i < n; ++i) { credits.mint(a, nextId); ids[i] = nextId++; }
            uint256 fee = pool.depositFeeFor(n);
            bool open_ = b == pool.openBatchId();
            vm.prank(a);
            if (open_) pool.depositAt{value: fee}(ids, b, filled);
            else pool.depositInto{value: fee}(b, ids, filled);
            if (pool.openBatchId() + 1 > batchesTouched) batchesTouched = pool.openBatchId() + 1;
        } else if (s == BackedPool.BatchState.Full) {
            (, uint256 open) = pool.bestBacking(b);
            if (open == 0) { vm.prank(a); pool.back{value: 1 ether}(b); (, open) = pool.bestBacking(b); }
            uint256 m = pool.majorityMinimum(b);
            if (m == 0 || m > open) { // depositors agree the backing's price
                address[] memory ds = pool.batchDepositors(b);
                for (uint256 i; i < ds.length; ++i) { vm.prank(ds[i]); pool.setReserve(b, open); }
            }
            pool.startAuction(b, open);
        } else if (s == BackedPool.BatchState.Auction) {
            (,,, uint64 e) = pool.auctions(b);
            if (block.timestamp < e) vm.warp(e);
            uint256 u = _unwindCount(b);
            pool.settle(b);
            _count(b, u);
        }
    }

    function _unwindCount(uint256 b) internal view returns (uint256) {
        (BackedPool.BatchState s,,,,,,) = pool.batchInfo(b);
        return uint256(s);
    }
    function _count(uint256 b, uint256 before) internal {
        (BackedPool.BatchState s,,,,,,) = pool.batchInfo(b);
        if (s == BackedPool.BatchState.Sold) ++sold;
        else if (s == BackedPool.BatchState.Full && before != uint256(BackedPool.BatchState.Full)) ++unwound;
    }
}

/// forge-config: default.invariant.depth = 120
contract BackedInvariantTest is Test {
    BackedPool pool; BackedHandler h; MockCredits credits; MockStatements stmts;
    address treasury = makeAddr("bi-treasury");

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        MockFeed feed = new MockFeed(2500e8);
        pool = deployBacked(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, treasury);
        h = new BackedHandler(pool, credits, stmts);
        targetContract(address(h));
    }

    /// I9: the pool can always pay everything it owes.
    function invariant_Solvent() public view {
        address[] memory as_ = h.actorsList();
        uint256 owed = pool.accruedFees() + pool.platformFeesOwed();
        for (uint256 i; i < as_.length; ++i) owed += pool.pendingReturns(as_[i]);
        uint256 n = h.batchesTouched() + 1;
        for (uint256 b; b < n; ++b) {
            (BackedPool.BatchState s,,,, uint256 proceeds,,) = pool.batchInfo(b);
            (, uint256 hb,,) = pool.auctions(b);
            owed += hb; // live or deciding high bid (0 otherwise)
            for (uint256 i; i < as_.length; ++i) {
                (uint256 amt,) = pool.backings(b, as_[i]);
                owed += amt;
                if (s == BackedPool.BatchState.Sold && !pool.claimed(b, as_[i])) {
                    owed += proceeds * pool.slots(b, as_[i]) / 80;
                }
            }
        }
        assertGe(address(pool).balance, owed);
        assertLe(address(pool).balance - owed, 80 * n); // only rounding dust beyond what's owed
    }

    /// I1/I2: Credits are held for every unsold batch, none for sold ones, none left in the vault.
    function invariant_CreditsAccounted() public view {
        uint256 n = h.batchesTouched() + 1;
        uint256 held;
        for (uint256 b; b < n; ++b) {
            (BackedPool.BatchState s, uint256 filled,,,,,) = pool.batchInfo(b);
            if (s == BackedPool.BatchState.Sold) assertEq(filled, 80);
            else held += filled;
            if (s == BackedPool.BatchState.Auction) assertEq(filled, 80);
        }
        assertEq(credits.balanceOf(address(pool)), held);
        assertEq(credits.balanceOf(address(pool.vault())), 0);
        assertEq(stmts.balanceOf(address(pool)), 0); // Statements always delivered
    }

    /// An auction or accept window always has a real high bidder with at least the backing floor.
    function invariant_AuctionsBacked() public view {
        uint256 n = h.batchesTouched() + 1;
        for (uint256 b; b < n; ++b) {
            (BackedPool.BatchState s,,,,,,) = pool.batchInfo(b);
            (address who, uint256 hb,,) = pool.auctions(b);
            if (s == BackedPool.BatchState.Auction) {
                (,, uint256 minimum,) = pool.auctions(b);
                assertTrue(who != address(0)); assertGe(hb, 80);
                assertGt(minimum, 0);   // option 1: only with a majority minimum
                assertGe(hb, minimum);  // and the price always meets it
            } else {
                assertEq(hb, 0);
            }
        }
    }

    /// Coverage signal (visible with -vv): the walk really reaches sales, unwinds and expiries.
    function afterInvariant() external view {
        uint256 soldNow;
        for (uint256 b; b <= h.batchesTouched(); ++b) {
            (BackedPool.BatchState s,,,,,,) = pool.batchInfo(b);
            if (s == BackedPool.BatchState.Sold) ++soldNow;
        }
        console2.log("sold", h.sold(), "unwound", h.unwound());
        console2.log("soldNow", soldNow);
    }
}

/// The handler's lifecycle driver really reaches a sale (guards the invariant run's coverage).
contract BackedHandlerSmokeTest is Test {
    function test_DriveReachesSale() public {
        vm.warp(1_000_000);
        MockCredits credits = new MockCredits();
        MockStatements stmts = new MockStatements(credits);
        stmts.setCap(type(uint256).max);
        MockFeed feed = new MockFeed(2500e8);
        BackedPool pool = deployBacked(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, makeAddr("bs-t"));
        BackedHandler h = new BackedHandler(pool, credits, stmts);
        h.drive(0, 0, 1 | (1 << 4)); // fill, then (coin bits) start, settle, accept...
        h.drive(0, 0, 1 | (1 << 4));
        h.drive(0, 0, 1 | (1 << 4));
        (BackedPool.BatchState s,,,,,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(BackedPool.BatchState.Sold));
        assertEq(h.sold(), 1);
    }
}
