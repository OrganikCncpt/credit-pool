"""Fill the local testnet copy with burner activity (local anvil only; uses impersonation).

Run after ./demo-testnet.sh with the burners as TESTERS (40 Credits each):

    python3 simulate-burners.py <burner-addresses.txt>

Leaves the pool with every state to look at:
  settled + collected, settled + waiting to collect, live auctions with rival bids,
  voted but not started, assembled awaiting votes, full awaiting assembly, and an open
  batch at 50/80 so a real tester can deposit 30 to fill it. Five burners keep their Credits.
"""
import json, random, re, subprocess, sys, time, urllib.request

RPC = "http://127.0.0.1:8545"
cfg = open("app/config.js").read()
POOL = re.search(r'31337: \{[^}]*?pool: "(0x[0-9a-fA-F]{40})"', cfg, re.S).group(1)
B = open(sys.argv[1]).read().strip().split(",")
assert len(B) >= 100, "need 100 burner addresses"
random.seed(7)
E = 10**18

_id = 0
def rpc(method, *params):
    global _id; _id += 1
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": list(params)}).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req))
    if "error" in out: raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]

def cd(sig, *args): return subprocess.run(["cast", "calldata", sig, *map(str, args)], capture_output=True, text=True, check=True).stdout.strip()
def call(to, sig, *args):
    return int(rpc("eth_call", {"to": to, "data": cd(sig, *args)}, "latest")[:66], 16)
def send(frm, to, sig, *args, value=0):
    h = rpc("eth_sendTransaction", {"from": frm, "to": to, "data": cd(sig, *args), "value": hex(value), "gas": hex(15_000_000)})
    r = None
    for _ in range(200):  # automine lands within a moment
        r = rpc("eth_getTransactionReceipt", h)
        if r: break
        time.sleep(0.02)
    if r["status"] != "0x1": raise RuntimeError(f"{sig} from {frm} reverted")
def ids_of(credits, who):
    out = subprocess.run(["cast", "call", credits, "tokensOf(address)(uint256[])", who, "--rpc-url", RPC],
                         capture_output=True, text=True, check=True).stdout
    return [int(x) for x in re.findall(r"\d+", out)]
def eth(w): return f"{w / E:.4f} ETH"

rpc("anvil_autoImpersonateAccount", True)
CREDITS = "0x" + rpc("eth_call", {"to": POOL, "data": cd("credits()")}, "latest")[-40:]
FEED = "0x" + rpc("eth_call", {"to": POOL, "data": cd("ethUsdFeed()")}, "latest")[-40:]

# The fork's Chainlink feed never updates, so skipping 24h would flip the pool to its fallback fee.
# Swap in an always-fresh feed at the same price (local copy only; Sepolia has live Chainlink).
price = int(rpc("eth_call", {"to": FEED, "data": cd("latestRoundData()")}, "latest")[66:130], 16)
code = json.load(open("out/Mocks.sol/MockFeed.json"))["deployedBytecode"]["object"]
rpc("anvil_setCode", FEED, code)
rpc("anvil_setStorageAt", FEED, "0x" + "0" * 64, "0x" + format(price, "064x"))  # price; updatedAt 0 = always fresh
fee = call(POOL, "depositFee()")
print(f"pool {POOL} · fee {fee} wei per Credit · feed pinned fresh")

for b in B: rpc("anvil_setBalance", b, hex(2 * E))  # gas + bids
for b in B[:95]:
    send(b, CREDITS, "setApprovalForAll(address,bool)", POOL, "true")

print("deposits: 90 burners × 40 → batches #0–44 full (two burners each)")
for b in B[:90]:
    ids = ids_of(CREDITS, b)
    send(b, POOL, "deposit(uint256[])", "[" + ",".join(map(str, ids)) + "]", value=fee * len(ids))
print("deposits: 5 burners × 10 → batch #45 at 50/80")
for b in B[90:95]:
    ids = ids_of(CREDITS, b)[:10]
    send(b, POOL, "deposit(uint256[])", "[" + ",".join(map(str, ids)) + "]", value=fee * len(ids))

print("assemble batches #0–39 (#40–44 left ready to assemble)")
for n in range(40): send(B[random.randrange(100)], POOL, "assemble(uint256)", n)

def vote(n):
    for b in B[2 * n: 2 * n + 2]:
        send(b, POOL, "setReserve(uint256,uint256)", n, random.randrange(10, 40) * E // 1000)  # 0.010–0.039 ETH
def auction(n, rounds):
    send(B[random.randrange(95)], POOL, "startAuction(uint256)", n)
    bid = call(POOL, "auctionReserve(uint256)", n)
    bidders = B[95:] + B[2 * n: 2 * n + 2]  # outsiders plus the batch's own depositors
    last = None
    for _ in range(rounds):
        who = random.choice([x for x in bidders if x != last])
        send(who, POOL, "bid(uint256)", n, value=bid)
        last, bid = who, bid * 106 // 100  # next bid clears the 5% step

print("round 1: batches #0–9 vote, auction, rival bids")
for n in range(10): vote(n); auction(n, random.randrange(2, 6))
rpc("evm_increaseTime", 24 * 3600 + 60); rpc("evm_mine")
for n in range(10): send(B[random.randrange(100)], POOL, "settle(uint256)", n)
for n in range(5):
    for b in B[2 * n: 2 * n + 2]: send(b, POOL, "claim(uint256)", n)
print("  settled #0–9; depositors of #0–4 collected, #5–9 left to collect")

print("round 2: batches #10–19 live auctions with rival bids")
for n in range(10, 20):
    vote(n); auction(n, random.randrange(1, 5))
print("  voted, not started: #20–24 · assembled, awaiting votes: #25–39")
for n in range(20, 25): vote(n)

print(f"\ndone · open batch #{call(POOL, 'openBatchId()')} · fees accrued {eth(call(POOL, 'accruedFees()'))}")
print("burners with untouched Credits:", ", ".join(B[95:100]))
