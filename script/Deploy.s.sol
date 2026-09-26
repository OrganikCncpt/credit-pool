// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console} from "forge-std/Script.sol";
import {CreditPool, AggregatorV3Interface} from "../src/CreditPool.sol";

/// Mainnet deploy. Run once the Statements contract is live.
///   STATEMENTS=0x... ASSEMBLER=0x... FEE_RECIPIENT=0x... \
///   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC --account deployer --broadcast --verify
///   OWNER=0x... (required; a multisig). Ownership is two-step: after deploy, OWNER must call
///   acceptOwnership() on the pool before it becomes owner.
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
        require(block.chainid == 1 || (credits != CREDITS && feed != ETH_USD), "mainnet constants on non-mainnet chain");
        require(statements.code.length > 0 && assembler.code.length > 0, "statements not deployed");
        require(credits.code.length > 0, "credits not deployed");
        require(feeRecipient != address(0), "FEE_RECIPIENT is zero");
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(AggregatorV3Interface(feed).decimals() == 8, "feed decimals != 8");
        require(price > 0 && block.timestamp - updatedAt < 1 days, "feed stale or broken");
        require(opensAt + 30 days > block.timestamp, "ASSEMBLY_OPENS_AT looks wrong (over 30 days ago)");
        require(opensAt < block.timestamp + 90 days, "ASSEMBLY_OPENS_AT looks wrong (over 90 days ahead; ms instead of s?)");
        require(owner != address(0), "OWNER is zero");

        vm.startBroadcast();
        pool = new CreditPool(credits, statements, assembler, feed, opensAt, feeRecipient);
        if (owner != msg.sender) pool.transferOwnership(owner); // pending until OWNER calls acceptOwnership()
        vm.stopBroadcast();

        console.log("CreditPool:", address(pool));
        console.log("deploy block:", block.number);
        console.log("owner:", pool.owner());
        console.log("pending owner (must acceptOwnership):", pool.pendingOwner());
        console.log("assembly vault:", address(pool.vault()));
        console.log("fallback fee per Credit (wei, frozen at deploy):", pool.fallbackFeeWei());
    }
}
