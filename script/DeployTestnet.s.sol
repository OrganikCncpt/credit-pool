// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script, console} from "forge-std/Script.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {Credits} from "../external/credits/Credits.sol";
import {ForkStatements, ICredits} from "../test/CreditPool.fork.t.sol";

/// Sepolia testnet: Jack's real Credits contract (same source), loaded with real mainnet seeds so
/// the art is identical, a stand-in Statements that burns through the real burn(owner, ids), and
/// CreditPool on Sepolia's Chainlink ETH/USD feed.
///
///   TESTERS=0xabc...,0xdef... PER_TESTER=80 FEE_RECIPIENT=0x... \
///   forge script script/DeployTestnet.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
///     --broadcast --interactives 1
///
/// TESTERS: comma-separated wallets to receive Credits (default: the deployer).
/// PER_TESTER: Credits each (default: 400 / testers). Seeds come from script/testnet-seeds.json.
contract DeployTestnet is Script {
    address constant SEPOLIA_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    uint256 constant CHUNK = 80;  // mints per distribute(): 100 costs ~14.8M gas, too near the 16.77M tx cap

    function run() external {
        require(block.chainid == 11155111 || block.chainid == 31337, "Sepolia or local only");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/testnet-seeds.json"));
        bytes21[] memory seeds = _seeds(vm.parseJsonBytesArray(json, ".seeds"));
        uint256[] memory stampsRaw = vm.parseJsonUintArray(json, ".timestamps");

        address[] memory testers = vm.envOr("TESTERS", ",", new address[](0));
        uint256 per = vm.envOr("PER_TESTER", uint256(0));
        address feed = vm.envOr("ETH_USD_FEED", SEPOLIA_ETH_USD);

        vm.startBroadcast();
        address deployer = msg.sender;
        if (testers.length == 0) { testers = new address[](1); testers[0] = deployer; }
        if (per == 0) per = seeds.length / testers.length;
        require(per * testers.length <= seeds.length, "not enough seeds: lower PER_TESTER");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        Credits credits = new Credits(deployer);
        uint256 total = per * testers.length;
        for (uint256 start; start < total; start += CHUNK) {
            uint256 n = total - start < CHUNK ? total - start : CHUNK;
            address[] memory to = new address[](n);
            bytes21[] memory s = new bytes21[](n);
            uint64[] memory t = new uint64[](n);
            for (uint256 i; i < n; ++i) {
                to[i] = testers[(start + i) / per];
                s[i] = seeds[start + i];
                t[i] = uint64(stampsRaw[start + i]);
            }
            credits.distribute(to, s, t);
        }
        credits.seal(); // burn() only works once sealed, same as mainnet

        ForkStatements stmts = new ForkStatements(ICredits(address(credits)));
        CreditPool pool = new CreditPool(address(credits), address(stmts), address(stmts), feed, block.timestamp, feeRecipient);
        vm.stopBroadcast();

        console.log("chain:", block.chainid);
        console.log("deploy block:", block.number);
        console.log("credits:", address(credits));
        console.log("statements:", address(stmts));
        console.log("pool:", address(pool));
        console.log("vault:", address(pool.vault()));
        console.log("fallback fee (wei):", pool.fallbackFeeWei());
        console.log("Credits minted:", total);
        for (uint256 i; i < testers.length; ++i) console.log("  tester", testers[i], per);
    }

    function _seeds(bytes[] memory raw) internal pure returns (bytes21[] memory out) {
        out = new bytes21[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            require(raw[i].length == 21, "seed must be 21 bytes");
            out[i] = bytes21(raw[i]);
        }
    }
}
