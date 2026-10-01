#!/usr/bin/env bash
# Full-scale testnet rehearsal on a local chain (chain id 31337, so the site's demo modes work):
# runs the real script/DeployTestnet.s.sol and points app/config.js at the pool.
# Default: a plain local anvil (no fork) with a local ETH/USD mock feed: it stays up indefinitely.
# FORK=1: a local copy of Sepolia instead (real Chainlink feed), which public RPCs only support for
# a few hours before they drop the forked block's state and anvil crashes.
#   TESTERS=0x..,0x.. COUNTS=80,40 FEE_SCALE=100 ./demo-testnet.sh
# BACKED=1 (default) deploys BackedPool (backed auctions); BACKED=0 the burn-first CreditPool.
# Then: python3 simulate-burners.py  and  python3 serve.py  →  http://localhost:5173/?as=<tester>
set -euo pipefail
cd "$(dirname "$0")"
RPC_UP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
R=http://127.0.0.1:8545
# A throwaway deployer: anvil's default keys are public and delegated to sweepers on Sepolia.
KEY=0x$(openssl rand -hex 32)
DEPLOYER=$(cast wallet address --private-key "$KEY")

# REUSE_ANVIL=1: deploy onto an anvil you started yourself (one that outlives this script), e.g.
#   anvil --fork-url https://ethereum-sepolia-rpc.publicnode.com --chain-id 31337 --gas-limit 60000000
FORK=${FORK:-0}
if [ "${REUSE_ANVIL:-0}" != 1 ]; then
  pkill -x anvil 2>/dev/null || true; sleep 1
  if [ "$FORK" = 1 ]; then
    nohup anvil --fork-url "$RPC_UP" --chain-id 31337 --gas-limit 60000000 --silent >/dev/null 2>&1 & disown
  else
    nohup anvil --chain-id 31337 --gas-limit 60000000 --silent >/dev/null 2>&1 & disown
  fi
fi
for _ in $(seq 1 30); do cast block-number --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
cast rpc anvil_setBalance "$DEPLOYER" 0x3635C9ADC5DEA00000 --rpc-url $R >/dev/null   # 1000 ETH
if [ "$FORK" != 1 ] && [ -z "${ETH_USD_FEED:-}" ]; then
  # No Chainlink on a plain chain: a mock ETH/USD feed at $2,500 that's always fresh.
  ETH_USD_FEED=$(forge create test/Mocks.sol:MockFeed --rpc-url $R --private-key "$KEY" --broadcast --constructor-args 250000000000 2>&1 \
    | awk '/Deployed to:/{print $3}')
  export ETH_USD_FEED
  echo "mock ETH/USD feed: $ETH_USD_FEED"
fi
BN=$(( $(cast block-number --rpc-url $R) + 1 ))

export BACKED=${BACKED:-1}
OUT=$(forge script script/DeployTestnet.s.sol --tc DeployTestnet --rpc-url $R --broadcast --slow --private-key "$KEY" 2>&1) \
  || { echo "$OUT" | tail -20; exit 1; }
echo "$OUT" | sed -n '/== Logs ==/,/^$/p'
POOL=$(echo "$OUT" | awk '/pool:/{print $2}')
SCALE=$(echo "$OUT" | awk '/fee scale/{print $NF}')

python3 - "$POOL" "$BN" "$SCALE" "$FORK" <<'PY'
import re, sys
pool, bn, scale, fork = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"
p = "app/config.js"; s = open(p).read()
block = re.search(r"  31337: \{.*?\n  \},\n", s, re.S).group(0)
new = ('  31337: {\n    name: "Local demo",\n    rpc: "http://127.0.0.1:8545",\n'
       f'    pool: "{pool}",\n    deployBlock: {bn}n,\n'
       '    explorer: null,\n' + ('    forkOf: "Sepolia",\n' if fork else '')
       + (f'    feeUsd: {1 / scale:g},\n' if scale > 1 else '') + '  },\n')
open(p, "w").write(s.replace(block, new))
PY
echo "config.js → pool $POOL (deploy block $BN)"
