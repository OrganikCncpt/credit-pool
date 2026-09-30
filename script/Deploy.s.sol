// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console} from "forge-std/Script.sol";
import {CreditPool, AggregatorV3Interface} from "../src/CreditPool.sol";
import {CreditStore} from "../src/CreditStore.sol";

/// Mainnet deploy. Run once the Statements contract is live.
///   STATEMENTS=0x... ASSEMBLER=0x... FEE_RECIPIENT=0x... \
///   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC --account deployer --broadcast --verify
///   OWNER=0x... (required; a multisig). Ownership is two-step: after deploy, OWNER must call
///   acceptOwnership() on the pool AND on the store before it becomes owner of each.
/// Optional: CREDITS, ETH_USD_FEED (default mainnet), ASSEMBLY_OPENS_AT (default now).
contract Deploy is Script {
    address constant CREDITS = 0x97630aA70AB14ed9883B41dAfccBc11349723043;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function run() external returns (CreditPool pool) {
        address statements = vm.envAddress("STATEMENTS");
        address assembler = vm.envOr("ASSEMBLER", statements);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address credits = vm.envOr("CREDITS", CREDITS);
        address feed = vm.envOr("ETH_USD_FEED", ETH_USD);
        // Escape hatch opens 14 days after this (or after a batch fills, if later).
        // Set it to when Statement assembly actually opens. Too early and full batches
        // could dissolve before they can be assembled.
        uint256 opensAt = vm.envOr("ASSEMBLY_OPENS_AT", block.timestamp);

        address owner = vm.envAddress("OWNER");

        // Guards: this script carries mainnet constants, so refuse anything that isn't mainnet
        // unless every address was supplied explicitly.
        // On mainnet only the canonical Credits and Chainlink feed (a stray env var from a testnet
        // session must not wire a test feed into the immutable fallback fee); elsewhere, both overridden.
        if (block.chainid == 1) require(credits == CREDITS && feed == ETH_USD, "mainnet must use the real Credits and feed");
        else require(credits != CREDITS && feed != ETH_USD, "mainnet constants on non-mainnet chain");
        require(statements.code.length > 0 && assembler.code.length > 0, "statements not deployed");
        require(credits.code.length > 0, "credits not deployed");
        require(feeRecipient != address(0), "FEE_RECIPIENT is zero");
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(AggregatorV3Interface(feed).decimals() == 8, "feed decimals != 8");
        require(price > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt < 1 hours + 10 minutes, "feed stale or broken");
        require(opensAt + 30 days > block.timestamp, "ASSEMBLY_OPENS_AT looks wrong (over 30 days ago)");
        require(opensAt < block.timestamp + 90 days, "ASSEMBLY_OPENS_AT looks wrong (over 90 days ahead; ms instead of s?)");
        require(owner != address(0), "OWNER is zero");

        vm.startBroadcast();
        // OWNER must be a multisig contract, not the deploying key (it would stay owner of both).
        if (block.chainid == 1) require(owner.code.length > 0 && owner != msg.sender, "OWNER must be a multisig contract");
        CreditStore store = new CreditStore(0); // treasury can't buy until OWNER raises the cap (3-day delay)
        pool = new CreditPool(credits, statements, assembler, feed, opensAt, feeRecipient, address(store));
        store.setPool(address(pool)); // one-time link; the store can't be pointed anywhere else later
        if (owner != msg.sender) {
            pool.transferOwnership(owner);  // pending until OWNER calls acceptOwnership()
            store.transferOwnership(owner); // same for the store
        }
        vm.stopBroadcast();

        console.log("CreditPool:", address(pool));
        console.log("deploy block:", block.number);
        console.log("owner:", pool.owner());
        console.log("pool pending owner (must acceptOwnership):", pool.pendingOwner());
        console.log("store pending owner (must acceptOwnership):", store.pendingOwner());
        console.log("assembly vault:", address(pool.vault()));
        console.log("CreditStore:", address(store));
        require(address(store.pool()) == address(pool) && address(pool.store()) == address(store), "store not linked");
        console.log("fallback $1 in wei (frozen at deploy):", pool.fallbackFeeWei());
    }
}
