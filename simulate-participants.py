"""Fill the fork demo with simulated depositors (local anvil fork only).

Every GROUP_SIZE wallets deposit amounts that sum to exactly 80, so each full batch is
split across GROUP_SIZE depositors. Real Credits come from a large holder, impersonated
on the fork. Run after ./demo-fork.sh:

    python3 simulate-participants.py            # 50 wallets, 20 per batch
    python3 simulate-participants.py 60 15      # 60 wallets, 15 per batch
"""
import json, random, re, sys, time, urllib.request

RPC = "http://127.0.0.1:8545"
CREDITS = "0x97630aA70AB14ed9883B41dAfccBc11349723043"
DONOR = "0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a"  # holds ~579 Credits on mainnet
PER_BATCH = 80

N = int(sys.argv[1]) if len(sys.argv) > 1 else 50
GROUP_SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 20
POOL = re.search(r'31337: \{[^}]*?pool: "(0x[0-9a-fA-F]{40})"', open("app/config.js").read(), re.S).group(1)

_id = 0
def rpc(method, *params):
    global _id; _id += 1
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": list(params)}).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req))
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]

def word(x): return format(x, "064x")
def addr(a): return word(int(a, 16))

def send(frm, to, data, value=0):
    h = rpc("eth_sendTransaction", {"from": frm, "to": to, "data": data, "value": hex(value)})
    r = None
    for _ in range(600):  # a fork mines lazily while it fetches state; wait for the receipt
        r = rpc("eth_getTransactionReceipt", h)
        if r: break
        time.sleep(0.05)
    if r is None or r["status"] != "0x1":
        raise RuntimeError(f"tx failed from {frm} to {to}")

def call(to, data): return rpc("eth_call", {"to": to, "data": data}, "latest")

def split(total, parts, rng, lo=1, hi=8):
    """`parts` random ints in [lo, hi] summing to `total`."""
    xs = [total // parts] * parts
    for i in range(total - sum(xs)): xs[i] += 1
    for _ in range(parts * 20):  # shuffle weight around, staying in range
        i, j = rng.randrange(parts), rng.randrange(parts)
        if i != j and xs[i] > lo and xs[j] < hi:
            xs[i] -= 1; xs[j] += 1
    return xs

rng = random.Random(8)
wallets = ["0x" + format(0xC0FFEE0000000000000000000000000000000000 + i + 1, "040x") for i in range(N)]

amounts = []
for g in range(0, N, GROUP_SIZE):
    size = min(GROUP_SIZE, N - g)
    full = size == GROUP_SIZE
    total = PER_BATCH if full else max(size, round(PER_BATCH * size / GROUP_SIZE * 0.55))  # last group: partial batch
    amounts += split(total, size, rng)

need = sum(amounts)
raw = call(CREDITS, "0x5a3f2672" + addr(DONOR))  # tokensOf(donor)
n = int(raw[2 + 64:2 + 128], 16)
donor_ids = [int(raw[2 + 128 + 64 * i: 2 + 192 + 64 * i], 16) for i in range(n)]
if len(donor_ids) < need:
    sys.exit(f"donor only has {len(donor_ids)} Credits, need {need}")

rpc("anvil_impersonateAccount", DONOR)
rpc("anvil_setBalance", DONOR, hex(10**19))
fee = int(call(POOL, "0x67a52793"), 16)  # depositFee()

cursor = 0
for i, (w, k) in enumerate(zip(wallets, amounts)):
    rpc("anvil_impersonateAccount", w)
    rpc("anvil_setBalance", w, hex(10**18))
    ids = donor_ids[cursor:cursor + k]; cursor += k
    for cid in ids:  # transferFrom(donor, w, id)
        send(DONOR, CREDITS, "0x23b872dd" + addr(DONOR) + addr(w) + word(cid))
    send(w, CREDITS, "0xa22cb465" + addr(POOL) + word(1))  # setApprovalForAll(pool, true)
    data = "0x598b8e71" + word(32) + word(len(ids)) + "".join(word(c) for c in ids)  # deposit(ids)
    send(w, POOL, data, (fee + fee // 20) * len(ids))  # $1 per Credit, 5% buffer
    print(f"wallet {i + 1:>2} {w[:8]}…{w[-4:]} deposited {k}")

groups = [amounts[g:g + GROUP_SIZE] for g in range(0, N, GROUP_SIZE)]
print(f"\npool {POOL}")
for b, grp in enumerate(groups):
    print(f"batch #{b}: {len(grp)} wallets, {sum(grp)}/80 Credits  {grp}")
