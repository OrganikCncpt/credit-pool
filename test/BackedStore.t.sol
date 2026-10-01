// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BackedPool} from "../src/BackedPool.sol";
import {BackedStore} from "../src/BackedStore.sol";
import {MockCredits, MockStatements, MockFeed} from "./Mocks.sol";
import {deployBacked} from "./BackedPool.t.sol";

/// The treasury buys unsold batches (no bid at the price, holders didn't accept the backer) at
/// exactly the depositors' majority price, capped; it never backs batches.
contract BackedStoreTest is Test {
    MockCredits credits; MockStatements stmts; MockFeed feed; BackedPool pool; BackedStore store;
    address treasury = makeAddr("bs-fees");
    address alice = makeAddr("bs-alice"); address bob = makeAddr("bs-bob"); address carol = makeAddr("bs-carol");
    address whale = makeAddr("bs-whale"); address bidder = makeAddr("bs-bidder");
    uint256 nextId = 1;

    function setUp() public {
        vm.warp(1_000_000);
        credits = new MockCredits();
        stmts = new MockStatements(credits);
        feed = new MockFeed(2500e8);
        pool = deployBacked(address(credits), address(stmts), address(stmts), address(feed), block.timestamp, treasury);
        store = BackedStore(payable(address(pool.store())));
        address[5] memory us = [alice, bob, carol, whale, bidder];
        for (uint256 i; i < 5; ++i) {
            vm.deal(us[i], 100 ether);
            vm.prank(us[i]); credits.setApprovalForAll(address(pool), true);
        }
        // Fund the treasury: the real path (deposit fees swept 75% to the store) plus a test top-up
        // to round numbers.
        for (uint256 i; i < 4; ++i) _deposit(carol, 10);
        pool.sweepFees();
        assertGt(store.treasuryBalance(), 0);
        vm.deal(address(store), 30 ether);
        assertEq(store.treasuryBalance(), 30 ether);
    }

    function _give(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { credits.mint(to, nextId); ids[i] = nextId++; }
    }
    function _deposit(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _give(who, n);
        uint256 fee = pool.depositFeeFor(n);
        vm.prank(who); pool.deposit{value: fee}(ids);
    }
    /// Batch 0 already holds carol's 40; alice 40 fills it.
    function _fill() internal returns (uint256[] memory a) { a = _deposit(alice, 40); }
    function _state(uint256 b) internal view returns (BackedPool.BatchState s) { (s,,,,,,) = pool.batchInfo(b); }
    function _ends(uint256 b) internal view returns (uint64 e) { (,,, e,,) = pool.auctions(b); }
    function _votes(uint256 price) internal {
        vm.prank(alice); pool.setReserve(0, price);
        vm.prank(carol); pool.setReserve(0, price);
    }
    /// A round that ends unsold: a lowball backing, no bid, holders don't accept, it expires.
    function _unsoldRound(uint256 b) internal {
        vm.prank(whale); pool.back{value: 0.001 ether}(b);
        vm.prank(alice); pool.startAuction(b);
        vm.warp(_ends(b)); pool.settle(b);
        vm.warp(_ends(b)); pool.expire(b);
        assertTrue(pool.unsold(b));
    }

    function test_TreasuryBuysUnsoldAtThePrice() public {
        _fill(); _votes(1 ether);
        _unsoldRound(0);
        store.buyUnsold(0, 1 ether);
        (BackedPool.BatchState st,,, uint256 sid, uint256 proceeds,,) = pool.batchInfo(0);
        assertEq(uint8(st), uint8(BackedPool.BatchState.Sold));
        assertEq(stmts.ownerOf(sid), address(store));
        assertEq(proceeds, 1 ether);
        assertEq(store.treasuryBalance(), 29 ether);
        uint256 a0 = alice.balance; vm.prank(alice); pool.claim(0); assertEq(alice.balance - a0, 0.5 ether);
        store.list(sid, 10);                          // straight into the SCREDIT store
        uint256 bf = store.bidFee();
        vm.prank(alice); store.bid{value: bf}(sid, 80); // alice earned 80 points at the burn
        vm.warp(block.timestamp + 1 days); store.settle(sid);
        assertEq(stmts.ownerOf(sid), alice);
    }

    function test_OnlyAfterAnUnsoldRound() public {
        _fill(); _votes(1 ether);
        vm.expectRevert(BackedPool.NotUnsold.selector);
        store.buyUnsold(0, 1 ether);                  // never auctioned
        vm.prank(whale); pool.back{value: 0.001 ether}(0);
        vm.prank(alice); pool.startAuction(0);
        vm.expectRevert(BackedPool.NotUnsold.selector);
        store.buyUnsold(0, 1 ether);                  // auction running
    }

    function test_ReopeningClearsUnsold() public {
        uint256[] memory a = _fill(); _votes(1 ether);
        _unsoldRound(0);
        uint256[] memory one = new uint256[](1); one[0] = a[0];
        vm.prank(alice); pool.withdraw(one);
        uint256[] memory fresh = _give(alice, 1);
        uint256 fee = pool.depositFeeFor(1);
        vm.prank(alice); pool.depositInto{value: fee}(0, fresh, 79);
        vm.expectRevert(BackedPool.NotUnsold.selector);
        store.buyUnsold(0, 1 ether);                  // different Credits now
    }

    function test_PinnedPrice() public {
        _fill(); _votes(1 ether);
        _unsoldRound(0);
        vm.expectRevert(BackedStore.PriceMoved.selector);
        store.buyUnsold(0, 0.9 ether);
        _votes(2 ether);                              // votes moved after the owner looked
        vm.expectRevert(BackedStore.PriceMoved.selector);
        store.buyUnsold(0, 1 ether);
        store.buyUnsold(0, 2 ether);
    }

    /// One small voter can't set the treasury's price while the others abstain (CreditPool CP-52).
    function test_PivotalMinorityRefused() public {
        _deposit(carol, 40);              // batch 0 full (carol 80)… use batch 1 for a 3-way split
        _deposit(alice, 40); _deposit(bob, 39); _deposit(whale, 1);
        vm.prank(alice); pool.setReserve(1, 1 ether);  // 40 slots
        vm.prank(whale); pool.setReserve(1, 4 ether);  // 1 slot: tips the majority to 4
        assertEq(pool.majorityMinimum(1), 4 ether);
        assertEq(pool.votedMedian(1), 1 ether);
        vm.prank(bidder); pool.back{value: 0.001 ether}(1);
        vm.prank(alice); pool.startAuction(1);
        vm.warp(_ends(1)); pool.settle(1);
        vm.warp(_ends(1)); pool.expire(1);
        vm.expectRevert(BackedPool.PivotalMinority.selector);
        store.buyUnsold(1, 4 ether);
    }

    function test_CapAndBalance() public {
        _fill(); _votes(6 ether);
        _unsoldRound(0);
        vm.expectRevert(BackedStore.OverCap.selector);
        store.buyUnsold(0, 6 ether);                  // cap is 5 ether
        store.setMaxTreasuryBid(50 ether);
        vm.expectRevert(BackedStore.OverCap.selector);
        store.buyUnsold(0, 6 ether);                  // raise needs 3 days
        vm.warp(block.timestamp + 3 days);
        store.buyUnsold(0, 6 ether);
    }

    function test_NeverASoleHoldersBatch() public {
        _deposit(carol, 40);                          // carol holds all 80 of batch 0
        vm.prank(carol); pool.setReserve(0, 1 ether);
        vm.prank(whale); pool.back{value: 0.001 ether}(0);
        vm.prank(carol); pool.startAuction(0);
        vm.warp(_ends(0)); pool.settle(0);
        vm.warp(_ends(0)); pool.expire(0);
        vm.expectRevert(BackedPool.NotDepositor.selector);
        store.buyUnsold(0, 1 ether);
    }

    function test_OnlyOwner() public {
        _fill(); _votes(1 ether); _unsoldRound(0);
        vm.prank(whale); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, whale));
        store.buyUnsold(0, 1 ether);
    }

    function test_UnwoundPurchaseRefundsAndStaysBuyable() public {
        _fill(); _votes(1 ether); _unsoldRound(0);
        stmts.setCap(0);                              // the Statements contract refuses
        store.buyUnsold(0, 1 ether);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Full));
        assertEq(credits.balanceOf(address(pool)), 80);
        store.collectRefund();
        assertEq(store.treasuryBalance(), 30 ether);
        assertTrue(pool.unsold(0));
        stmts.setCap(type(uint256).max);
        store.buyUnsold(0, 1 ether);
        assertEq(uint8(_state(0)), uint8(BackedPool.BatchState.Sold));
    }

    function test_EthOnlyFromPool() public {
        vm.deal(whale, 1 ether);
        vm.prank(whale);
        (bool ok,) = address(store).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
