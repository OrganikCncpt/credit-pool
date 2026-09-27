#!/usr/bin/env bash
# Fresh mainnet-fork demo: real Credits + real Chainlink feed, stand-in Statements.
# Gives anvil wallet 0 fifty real Credits and wallet 1 forty, then points app/config.js at the pool.
# Then: python3 serve.py  →  http://localhost:5173/?dev=0
set -euo pipefail
cd "$(dirname "$0")"
# drpc serves historical state for free, so the fork keeps working hours later (publicnode 403s)
RPC_UP=${MAINNET_RPC:-https://eth.drpc.org}
R=http://127.0.0.1:8545
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
C=0x97630aA70AB14ed9883B41dAfccBc11349723043
H=0x88Fe56808AAc806336A0Eb28682D10033c73826a   # real holder with 100 Credits
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
A1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

pkill -x anvil 2>/dev/null || true; sleep 1
anvil --fork-url "$RPC_UP" --chain-id 31337 --silent >/dev/null 2>&1 &
for _ in $(seq 1 30); do cast block-number --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
# The pool deploys after the fork block. Start event scans one block later: anything at or
# before the fork block is forwarded upstream, and free RPCs reject those log queries.
BN=$(( $(cast block-number --rpc-url $R) + 1 ))

OUT=$(forge script script/DeployFork.s.sol --rpc-url $R --broadcast --private-key $KEY0 2>&1)
POOL=$(echo "$OUT" | awk '/pool:/{print $2}')

cast rpc anvil_impersonateAccount $H --rpc-url $R >/dev/null
cast rpc anvil_setBalance $H 0x56BC75E2D63100000 --rpc-url $R >/dev/null
IDS=$(cast call $C "tokensOf(address)(uint256[])" $H --rpc-url $R --json \
  | python3 -c "import json,sys; print(' '.join(map(str, json.load(sys.stdin)[0][:90])))")
n=0
for id in $IDS; do
  n=$((n+1)); to=$A0; [ $n -gt 50 ] && to=$A1
  cast send $C "transferFrom(address,address,uint256)" $H $to $id --from $H --unlocked --rpc-url $R >/dev/null
done

python3 - "$POOL" "$BN" <<'PY'
import re, sys
p = "app/config.js"; s = open(p).read()
s = re.sub(r'(31337: \{[^}]*?pool: )"0x[0-9a-fA-F]+"', r'\1"%s"' % sys.argv[1], s, flags=re.S)
s = re.sub(r'deployBlock: \d+n, // mainnet-fork demo', 'deployBlock: %sn, // mainnet-fork demo' % sys.argv[2], s)
open(p, "w").write(s)
PY
# Report what each wallet actually holds (the source holder's supply can run low over time).
B0=$(cast call $C "balanceOf(address)(uint256)" $A0 --rpc-url $R); B1=$(cast call $C "balanceOf(address)(uint256)" $A1 --rpc-url $R)
echo "fork block $BN · pool $POOL · wallet0 $B0 Credits · wallet1 $B1 Credits"
