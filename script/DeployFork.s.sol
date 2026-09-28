// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console} from "forge-std/Script.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditStore} from "../src/CreditStore.sol";
import {ForkStatements, ICredits} from "../test/CreditPool.fork.t.sol";

/// Demo on a local mainnet fork: real Credits + real Chainlink feed, stand-in Statements.
///   anvil --fork-url $MAINNET_RPC --chain-id 31337
///   forge script script/DeployFork.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key 0>
contract DeployFork is Script {
    function run() external {
        ICredits credits = ICredits(0x97630aA70AB14ed9883B41dAfccBc11349723043);
        vm.startBroadcast();
        ForkStatements stmts = new ForkStatements(credits);
        CreditStore store = new CreditStore(1 ether);
        CreditPool pool = new CreditPool(
            address(credits), address(stmts), address(stmts),
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, block.timestamp, msg.sender, address(store)
        );
        store.setPool(address(pool));
        vm.stopBroadcast();
        console.log("statements:", address(stmts));
        console.log("pool:", address(pool));
        console.log("store:", address(store));
    }
}
