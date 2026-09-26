// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {CreditPool} from "../src/CreditPool.sol";

interface ICredits {
    function ownerOf(uint256) external view returns (address);
    function tokensOf(address) external view returns (uint256[] memory);
    function setApprovalForAll(address, bool) external;
    function burn(address owner_, uint256[] calldata ids) external returns (bytes21[] memory);
    function isSealed() external view returns (bool);
}

/// Stand-in Statements that burns through the REAL Credits.burn(owner, ids).
contract ForkStatements is ERC721 {
    ICredits immutable credits;
    uint256 next = 1;
    constructor(ICredits c) ERC721("Statements", "STMT") { credits = c; }
    function assemble(uint256[] calldata ids) external returns (uint256 sid) {
        require(ids.length == 80, "need 80");
        credits.burn(msg.sender, ids);
        sid = next++;
        _safeMint(msg.sender, sid);
    }
}

/// Runs against mainnet state. Skipped unless MAINNET_RPC is set:
///   MAINNET_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract Fork
contract CreditPoolForkTest is Test {
    ICredits constant CREDITS = ICredits(0x97630aA70AB14ed9883B41dAfccBc11349723043);
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    CreditPool pool;
    ForkStatements stmts;
    address holder;
    uint256[] ids;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        stmts = new ForkStatements(CREDITS);
        pool = new CreditPool(address(CREDITS), address(stmts), address(stmts), ETH_USD, block.timestamp, address(this));

        holder = CREDITS.ownerOf(3); // a wallet holding 80+ Credits
        uint256[] memory owned = CREDITS.tokensOf(holder);
        require(owned.length >= 80, "pick another holder");
        for (uint256 i; i < 80; ++i) ids.push(owned[i]);
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        CREDITS.setApprovalForAll(address(pool), true);
    }

    modifier forked() {
        if (address(pool) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_Fork_RealFeedFeeIsSane() public forked {
        uint256 fee = pool.depositFee();
        assertGt(fee, 0.00005 ether); // ETH < $20k
        assertLt(fee, 0.002 ether);   // ETH > $500
    }

    function test_Fork_DepositWithdrawRealCredits() public forked {
        uint256[] memory five = new uint256[](5);
        for (uint256 i; i < 5; ++i) five[i] = ids[i];
        uint256 fee = pool.depositFee() * five.length; // $1 per Credit
        vm.prank(holder); pool.deposit{value: fee}(five);
        assertEq(CREDITS.ownerOf(five[0]), address(pool));
        assertEq(CREDITS.tokensOf(address(pool)).length, 5);

        vm.prank(holder); pool.withdraw(five);
        assertEq(CREDITS.ownerOf(five[0]), holder);
        assertEq(CREDITS.tokensOf(address(pool)).length, 0);
    }

    function test_Fork_AssembleBurnsRealCredits() public forked {
        assertTrue(CREDITS.isSealed());
        uint256 fee = pool.depositFee() * ids.length; // $1 per Credit
        vm.prank(holder); pool.deposit{value: fee}(ids);
        uint256 g = gasleft();
        pool.assemble(0);
        g -= gasleft();
        emit log_named_uint("assemble 80 real Credits, gas", g);
        assertLt(g, 16_777_216); // must fit Ethereum's per-tx gas cap

        (CreditPool.BatchState s,,, uint256 sid,,) = pool.batchInfo(0);
        assertEq(uint8(s), uint8(CreditPool.BatchState.Assembled));
        assertEq(stmts.ownerOf(sid), address(pool));
        vm.expectRevert(); CREDITS.ownerOf(ids[0]); // burned

        vm.prank(holder); pool.redeem(0);
        assertEq(stmts.ownerOf(sid), holder);
    }
}
