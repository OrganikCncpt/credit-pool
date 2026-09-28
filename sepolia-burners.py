"""Drive burner wallets on a live testnet (Sepolia): each burner signs with its own throwaway key.

    python3 sepolia-burners.py <burners.json> status
    python3 sepolia-burners.py <burners.json> deposit            # 90 burners × 40, 5 × 10, 5 keep theirs
    python3 sepolia-burners.py <burners.json> vote 0 1 2         # each depositor votes a small reserve
    python3 sepolia-burners.py <burners.json> auction 0 1        # start + rival bids from burners 95–99
    python3 sepolia-burners.py <burners.json> settle 0 1         # after the 24h auction ends
    python3 sepolia-burners.py <burners.json> claim 0 1

burners.json: [{"address", "private_key"}] from `cast wallet new --number 100 --json`. Keep it out
of git. Pool and RPC come from app/config.js (chain 11155111), or POOL= / RPC= env overrides.
Assembling costs ~4M gas, more than a burner's 0.005 ETH covers: press Assemble in the site.
Gas: every tx caps maxFeePerGas at what the wallet can afford for its gas limit, so a burner never
gets "insufficient funds for gas * price + value" while the base fee sits below that cap.
"""
import json, os, random, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

cfg = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "app/config.js")).read()
sep = re.search(r"11155111: \{(.*?)\n  \},", cfg, re.S).group(1)
POOL = os.environ.get("POOL") or re.search(r'pool: "(0x[0-9a-fA-F]{40})"', sep).group(1)
RPC = os.environ.get("RPC") or re.search(r'rpc: "([^"]+)"', sep).group(1)
W = json.load(open(sys.argv[1]))
CMD, ARGS = sys.argv[2], [int(x) for x in sys.argv[3:]]
E = 10**18
random.seed(11)

def cast(*a, key=None):
    signer = ["--private-key", key] if key else []  # throwaway testnet keys only
    r = subprocess.run(["cast", *map(str, a), *signer, "--rpc-url", RPC], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr.strip().splitlines()[-1][:240])
    return r.stdout.strip()
def call(sig, *a): return cast("call", POOL, sig, *a).split()[0]
CREDITS = call("credits()(address)")

def send(w, to, sig, *a, value=0):
    """Estimate, cap the fee at what this wallet can pay, send, wait for the receipt."""
    gas = int(int(cast("estimate", to, sig, *a, "--value", value, "--from", w["address"])) * 1.2)
    base = int(cast("base-fee"))
    afford = (int(cast("balance", w["address"])) - value) // gas
    tip = 10**6  # 0.001 gwei is plenty on Sepolia
    max_fee = min(2 * base + tip, afford)
    if max_fee <= base + tip: raise RuntimeError(f"{w['address'][:10]} can't afford {sig.split('(')[0]} at base fee {base / 1e9:.2f} gwei")
    out = cast("send", to, sig, *a, "--value", value, "--gas-limit", gas, "--gas-price", max_fee,
               "--priority-gas-price", tip, "--json", key=w["private_key"])
    if json.loads(out)["status"] != "0x1": raise RuntimeError(f"{sig} reverted for {w['address']}")

def ids_of(a): return [int(x) for x in re.findall(r"\d+", cast("call", CREDITS, "tokensOf(address)(uint256[])", a))]
def fee(n): return int(call("depositFeeFor(uint256)(uint256)", n))  # $2 each, $1 each for 6+
def each(fn, ws, workers=8):  # different wallets have independent nonces: run them in parallel
    with ThreadPoolExecutor(workers) as ex:
        for w, r in zip(ws, ex.map(lambda w: _try(fn, w), ws)):
            if r: print(f"  ! {w['address'][:10]}: {r}")
def _try(fn, w):
    try: fn(w)
    except Exception as e: return str(e)
def depositors(b):
    return [w for w in W if int(call("slots(uint256,address)(uint256)", b, w["address"])) > 0]

if CMD == "status":
    print(f"pool {POOL} · open batch #{call('openBatchId()(uint256)')} · fee {fee(1)} wei for 1 Credit, {fee(20)} for 20 · base fee {int(cast('base-fee')) / 1e9:.3f} gwei")
    bals = [int(cast("balance", w["address"])) for w in W]
    print(f"burners: {len(W)} · ETH min {min(bals) / E:.5f} · avg {sum(bals) / len(bals) / E:.5f}")

elif CMD == "deposit":
    def dep(w, n=None):
        ids = ids_of(w["address"])[:n] if n else ids_of(w["address"])
        if not ids: return
        if cast("call", CREDITS, "isApprovedForAll(address,address)(bool)", w["address"], POOL) != "true":
            send(w, CREDITS, "setApprovalForAll(address,bool)", POOL, "true")
        for i in range(0, len(ids), 20):  # 20 per tx keeps each gas limit (and upfront cost) small
            chunk = ids[i:i + 20]
            send(w, POOL, "deposit(uint256[])", "[" + ",".join(map(str, chunk)) + "]", value=fee(len(chunk)) * 105 // 100)
    print("90 burners × 40 (in parallel, so batches mix depositors)")
    each(dep, W[:90])
    print("5 burners × 10 → the open batch reaches 50/80")
    each(lambda w: dep(w, 10), W[90:95])

elif CMD == "vote":
    for b in ARGS:
        each(lambda w: send(w, POOL, "setReserve(uint256,uint256)", b, random.randrange(2, 6) * E // 10000), depositors(b))
        print(f"  #{b} reserve {int(call('currentReserve(uint256)(uint256)', b)) / E} ETH")

elif CMD == "auction":
    bidders = W[95:100]
    for b in ARGS:
        send(bidders[0], POOL, "startAuction(uint256)", b)
        bid, last = int(call("auctionReserve(uint256)(uint256)", b)) or E // 10000, None
        for _ in range(random.randrange(2, 4)):
            w = random.choice([x for x in bidders if x is not last])
            send(w, POOL, "bid(uint256)", b, value=bid)
            last, bid = w, bid * 106 // 100
        print(f"  #{b} live, high bid {bid * 100 // 106 / E} ETH")

elif CMD == "settle":
    for b in ARGS: send(W[95], POOL, "settle(uint256)", b); print(f"  #{b} settled")

elif CMD == "claim":
    for b in ARGS: each(lambda w: send(w, POOL, "claim(uint256)", b), depositors(b)); print(f"  #{b} claimed")

else: sys.exit(__doc__)
