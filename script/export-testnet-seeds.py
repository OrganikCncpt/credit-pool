"""Export real Credit seeds + payment times from mainnet, so testnet Credits render identical art.

    python3 script/export-testnet-seeds.py 400 > script/testnet-seeds.json

Reads seedOf(id) and timestampOf(id) for ids 1..N from the real Credits contract (both survive
burns). Output: {"seeds": [...bytes21 hex...], "timestamps": [...]} in id order.
"""
import json, subprocess, sys, time

RPC = "https://ethereum-rpc.publicnode.com"
CREDITS = "0x97630aA70AB14ed9883B41dAfccBc11349723043"
SEED_OF, TS_OF = "0x82829f74", "0x2d9c77e1"  # seedOf(uint256), timestampOf(uint256) (cast sig)

def batch(calls):
    body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": "eth_call",
                        "params": [{"to": CREDITS, "data": d}, "latest"]} for i, d in enumerate(calls)]).encode()
    # curl, not urllib: python.org builds on macOS often ship without CA certs
    for attempt in range(6):  # public RPCs drop or rate-limit long runs: back off and retry
        r = subprocess.run(["curl", "-sf", "-H", "Content-Type: application/json", "--data-binary", "@-", RPC],
                           input=body, capture_output=True)
        try:
            out = json.loads(r.stdout)
            if isinstance(out, list) and all("result" in x for x in out): break
        except ValueError: pass
        time.sleep(2 ** attempt)
    else: sys.exit("RPC kept failing")
    return [r["result"] for r in sorted(out, key=lambda r: r["id"])]

n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
seeds, stamps = [], []
for start in range(1, n + 1, 50):
    ids = range(start, min(start + 50, n + 1))
    res = batch([SEED_OF + format(i, "064x") for i in ids] + [TS_OF + format(i, "064x") for i in ids])
    k = len(ids)
    seeds += ["0x" + r[2:44] for r in res[:k]]          # bytes21 is left-aligned in the word
    stamps += [int(r, 16) for r in res[k:]]
assert all(int(s, 16) for s in seeds) and all(stamps), "missing seed or timestamp"
print(json.dumps({"seeds": seeds, "timestamps": stamps}))
