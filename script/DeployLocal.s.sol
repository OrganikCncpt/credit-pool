// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console} from "forge-std/Script.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockCredits, MockStatements, MockFeed} from "../test/Mocks.sol";

/// Local anvil stack with mocks. Mints Credits to the first four anvil accounts.
///   anvil &
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployLocal is Script {
    function run() external {
        address[4] memory users = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906
        ];
        uint256[4] memory counts = [uint256(50), 50, 30, 250]; // dev=3 is a whale (tests chunked deposits)

        vm.startBroadcast();
        MockCredits credits = new MockCredits();
        MockStatements stmts = new MockStatements(credits);
        MockFeed feed = new MockFeed(2500e8);
        CreditPool pool = new CreditPool(
            address(credits), address(stmts), address(stmts), address(feed), block.timestamp, users[0]
        );
        uint256 id = 1;
        for (uint256 u; u < 4; ++u) {
            for (uint256 i; i < counts[u]; ++i) credits.mint(users[u], id++);
        }
        vm.stopBroadcast();

        console.log("credits:", address(credits));
        console.log("statements:", address(stmts));
        console.log("pool:", address(pool));
    }
}
