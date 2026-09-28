// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script, console} from "forge-std/Script.sol";
import {CreditPool, AggregatorV3Interface} from "../src/CreditPool.sol";
import {Credits} from "../external/credits/Credits.sol";
import {CreditStore} from "../src/CreditStore.sol";
import {ForkStatements, ICredits} from "../test/CreditPool.fork.t.sol";

/// Testnet only: passes the real Chainlink feed through with the price multiplied by `scale`,
/// so the pool's "$1" fee costs $1 / scale in real terms. Timestamps are untouched, so the
/// stale-feed fallback still behaves exactly as on mainnet.
contract ScaledFeed is AggregatorV3Interface {
    AggregatorV3Interface public immutable feed;
    int256 public immutable scale;
    constructor(AggregatorV3Interface feed_, int256 scale_) { feed = feed_; scale = scale_; }
    function decimals() external view returns (uint8) { return feed.decimals(); }
    function latestRoundData() external view returns (uint80 r, int256 a, uint256 s, uint256 u, uint80 ar) {
        (r, a, s, u, ar) = feed.latestRoundData();
        a *= scale;
    }
}

/// Sepolia testnet: Jack's real Credits contract (same source), loaded with real mainnet seeds so
/// the art is identical, a stand-in Statements that burns through the real burn(owner, ids), and
/// CreditPool on Sepolia's Chainlink ETH/USD feed.
///
///   TESTERS=0xabc...,0xdef... COUNTS=80,40 FEE_SCALE=100 FUND_WEI=6000000000000000 \
///   forge script script/DeployTestnet.s.sol --tc DeployTestnet --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
///     --broadcast --slow --interactives 1
///
/// TESTERS:    comma-separated wallets to receive Credits (default: the deployer).
/// COUNTS:     Credits for each tester, same order (default: PER_TESTER each, or all seeds split evenly).
/// FEE_SCALE:  every $ amount (deposit fee, $0.25 bid fee) ÷ FEE_SCALE (default 1; 100 → $0.02/$0.01 per Credit).
/// MAX_TREASURY_BID: cap for the store's buy-unsold bids (default 0.01 ETH).
/// FUND_WEI:   ETH sent to each tester other than the deployer, for gas (default 0).
/// Seeds come from script/testnet-seeds.json.
contract DeployTestnet is Script {
    address constant SEPOLIA_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    uint256 constant CHUNK = 80;  // mints per distribute(): 100 costs ~14.8M gas, too near the 16.77M tx cap

    function run() external {
        require(block.chainid == 11155111 || block.chainid == 31337, "Sepolia or local only");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/testnet-seeds.json"));
        bytes21[] memory seeds = _seeds(vm.parseJsonBytesArray(json, ".seeds"));
        uint256[] memory stampsRaw = vm.parseJsonUintArray(json, ".timestamps");

        address[] memory testers = vm.envOr("TESTERS", ",", new address[](0));
        uint256[] memory counts = vm.envOr("COUNTS", ",", new uint256[](0));
        uint256 feeScale = vm.envOr("FEE_SCALE", uint256(1));
        uint256 fund = vm.envOr("FUND_WEI", uint256(0));
        address feed = vm.envOr("ETH_USD_FEED", SEPOLIA_ETH_USD);
        require(feeScale >= 1 && feeScale <= 1000, "FEE_SCALE 1..1000");

        vm.startBroadcast();
        address deployer = msg.sender;
        if (testers.length == 0) { testers = new address[](1); testers[0] = deployer; }
        if (counts.length == 0) {
            uint256 per = vm.envOr("PER_TESTER", seeds.length / testers.length);
            counts = new uint256[](testers.length);
            for (uint256 i; i < testers.length; ++i) counts[i] = per;
        }
        require(counts.length == testers.length, "COUNTS must match TESTERS");
        uint256 total;
        for (uint256 i; i < counts.length; ++i) total += counts[i];
        require(total <= seeds.length, "not enough seeds: export more or lower COUNTS");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        Credits credits = new Credits(deployer);
        address[] memory owners = new address[](total);
        uint256 k;
        for (uint256 i; i < testers.length; ++i)
            for (uint256 j; j < counts[i]; ++j) owners[k++] = testers[i];
        for (uint256 start; start < total; start += CHUNK) {
            uint256 n = total - start < CHUNK ? total - start : CHUNK;
            address[] memory to = new address[](n);
            bytes21[] memory s = new bytes21[](n);
            uint64[] memory t = new uint64[](n);
            for (uint256 i; i < n; ++i) {
                to[i] = owners[start + i];
                s[i] = seeds[start + i];
                t[i] = uint64(stampsRaw[start + i]);
            }
            credits.distribute(to, s, t);
        }
        credits.seal(); // burn() only works once sealed, same as mainnet

        if (feeScale > 1) feed = address(new ScaledFeed(AggregatorV3Interface(feed), int256(feeScale)));
        ForkStatements stmts = new ForkStatements(ICredits(address(credits)));
        CreditStore store = new CreditStore(vm.envOr("MAX_TREASURY_BID", uint256(0.01 ether)));
        CreditPool pool = new CreditPool(address(credits), address(stmts), address(stmts), feed, block.timestamp, feeRecipient, address(store));
        store.setPool(address(pool));
        if (fund > 0) {
            for (uint256 i; i < testers.length; ++i) {
                if (testers[i] == deployer) continue;
                (bool ok,) = testers[i].call{value: fund}("");
                require(ok, "fund tester");
            }
        }
        vm.stopBroadcast();

        console.log("chain:", block.chainid);
        console.log("deploy block:", block.number);
        console.log("credits:", address(credits));
        console.log("statements:", address(stmts));
        console.log("pool:", address(pool));
        console.log("vault:", address(pool.vault()));
        console.log("store:", address(store));
        console.log("fee scale ($1 /):", feeScale);
        console.log("fee, 1 Credit (wei):", pool.depositFeeFor(1));
        console.log("fee, 6 Credits (wei):", pool.depositFeeFor(6));
        console.log("Credits minted:", total);
        console.log("testers:", testers.length);
    }

    function _seeds(bytes[] memory raw) internal pure returns (bytes21[] memory out) {
        out = new bytes21[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            require(raw[i].length == 21, "seed must be 21 bytes");
            out[i] = bytes21(raw[i]);
        }
    }
}
