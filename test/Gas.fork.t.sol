// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {deployPool} from "./DeployPool.sol";
import {ICredits, ForkStatements} from "./CreditPool.fork.t.sol";

interface ICr { function tokensOf(address) external view returns (uint256[] memory); function ownerOf(uint256) external view returns (address); function setApprovalForAll(address,bool) external; }

contract GasForkTest is Test {
    function test_Fork_GasPerCredit() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        ICr c = ICr(0x97630aA70AB14ed9883B41dAfccBc11349723043);
        address holder = c.ownerOf(1); // biggest wallet
        uint256[] memory owned = c.tokensOf(holder);
        ForkStatements st = new ForkStatements(ICredits(address(c))); // a real stand-in: the pool refuses Statements == Credits
        CreditPool pool = deployPool(address(c), address(st), address(st), 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, block.timestamp, address(this));
        vm.deal(holder, 1 ether);
        vm.prank(holder); c.setApprovalForAll(address(pool), true);
        uint256[5] memory sizes = [uint256(1), 10, 50, 80, 160];
        uint256 off;
        for (uint256 k; k < 5; ++k) {
            uint256[] memory ids = new uint256[](sizes[k]);
            for (uint256 i; i < sizes[k]; ++i) ids[i] = owned[off + i];
            off += sizes[k];
            uint256 fee = pool.depositFeeFor(ids.length);
            vm.prank(holder);
            uint256 g = gasleft();
            pool.deposit{value: fee}(ids);
            console.log("deposit n=%s gas=%s", sizes[k], g - gasleft());
        }
        uint256 open = pool.openBatchId();
        uint256[] memory w = pool.batchCredits(open);
        vm.prank(holder);
        uint256 g2 = gasleft();
        pool.withdraw(w);
        console.log("withdraw n=%s gas=%s", w.length, g2 - gasleft());
    }
}
