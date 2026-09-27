#!/usr/bin/env bash
# Full-scale testnet rehearsal on a local copy of Sepolia (chain id 31337, so the site's demo
# modes work): runs the real script/DeployTestnet.s.sol and points app/config.js at the pool.
#   TESTERS=0x..,0x.. COUNTS=80,40 FEE_SCALE=100 ./demo-testnet.sh
# Then: python3 simulate-burners.py  and  python3 serve.py  →  http://localhost:5173/?as=<tester>
set -euo pipefail
cd "$(dirname "$0")"
RPC_UP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
R=http://127.0.0.1:8545
# A throwaway deployer: anvil's default keys are public and delegated to sweepers on Sepolia.
KEY=0x$(openssl rand -hex 32)
DEPLOYER=$(cast wallet address --private-key "$KEY")

pkill -x anvil 2>/dev/null || true; sleep 1
anvil --fork-url "$RPC_UP" --chain-id 31337 --gas-limit 60000000 --silent >/dev/null 2>&1 &
for _ in $(seq 1 30); do cast block-number --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
cast rpc anvil_setBalance "$DEPLOYER" 0x3635C9ADC5DEA00000 --rpc-url $R >/dev/null   # 1000 ETH
BN=$(( $(cast block-number --rpc-url $R) + 1 ))

OUT=$(forge script script/DeployTestnet.s.sol --tc DeployTestnet --rpc-url $R --broadcast --slow --private-key "$KEY" 2>&1) \
  || { echo "$OUT" | tail -20; exit 1; }
echo "$OUT" | sed -n '/== Logs ==/,/^$/p'
POOL=$(echo "$OUT" | awk '/pool:/{print $2}')
SCALE=$(echo "$OUT" | awk '/fee scale/{print $NF}')

python3 - "$POOL" "$BN" "$SCALE" <<'PY'
import re, sys
pool, bn, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
p = "app/config.js"; s = open(p).read()
block = re.search(r"  31337: \{.*?\n  \},\n", s, re.S).group(0)
new = ('  31337: {\n    name: "Local demo",\n    rpc: "http://127.0.0.1:8545",\n'
       f'    pool: "{pool}",\n    deployBlock: {bn}n, // local fork; use 0n for a plain anvil chain\n'
       '    explorer: null,\n    forkOf: "Sepolia",\n' + (f'    feeUsd: {1 / scale:g},\n' if scale > 1 else '') + '  },\n')
open(p, "w").write(s.replace(block, new))
PY
echo "config.js → pool $POOL (deploy block $BN)"
