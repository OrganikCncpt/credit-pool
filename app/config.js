// Per-chain deployment. Fill in mainnet after `script/Deploy.s.sol` runs.
// deployBlock bounds event scans (keeps public RPCs happy).
export const DEPLOYMENTS = {
  1: {
    name: "Ethereum",
    rpc: "https://ethereum-rpc.publicnode.com",
    pool: null, // ← CreditPool address
    deployBlock: 0n,
    explorer: "https://etherscan.io",
  },
  11155111: {
    name: "Sepolia",
    rpc: "https://ethereum-sepolia-rpc.publicnode.com",
    pool: null, // ← CreditPool address from script/DeployTestnet.s.sol
    deployBlock: 0n,
    explorer: "https://sepolia.etherscan.io",
    feeUsd: 0.01, // matches FEE_SCALE=100 in DeployTestnet; remove for a real-fee deploy
    testnet: true,
  },
  31337: {
    name: "Local demo",
    rpc: "http://127.0.0.1:8545",
    pool: "0x7fC6Cdcf0D2f9fd65BfCF64d6fD1bDfbADdd7c7b",
    deployBlock: 26058329n, // mainnet-fork demo; use 0n for a plain anvil chain
    explorer: null,
  },
};

// Default chain when no wallet is connected.
export const DEFAULT_CHAIN = 31337;
