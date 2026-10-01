"""Fill a local BackedPool demo with burner activity (local anvil only; uses impersonation).

Run after `BACKED=1 ./demo-testnet.sh` with the burners (40 Credits each) and optionally your
tester wallet as TESTERS:

    python3 simulate-backed.py <burner-addresses.txt> [tester-address]

Leaves every state to look at (auctions open only with a backing at or above the depositors'
majority price, so every auction sells):
  #0–3   sold (#0–2 collected, #3 waiting to collect)
  #4     won by the store treasury's backing at the price → listed in the store for SCREDIT
  #5     a lowball backing sat below the price until the majority lowered its price to it → sold
  #6–7   price set, but the only backing is a lowball below it: can't start, Credits stay free
  #8     the tester's batch: the other depositor voted, the tester's vote makes the price; a backer waits
  #9     full, no votes, no backing
  #10–14 live auctions with rival bids
  #15–17 backed at the price: anyone can start the auction
  #18    backed by the store treasury at the price · #19 live auction led by the treasury
  #20–21 price set, waiting for a backer
  open batch at 50/80
The store's ownership moves to the tester (local demo only) so the owner's treasury controls show.
"""
import json, random, re, subprocess, sys, time, urllib.request

RPC = "http://127.0.0.1:8545"
cfg = open("app/config.js").read()
POOL = re.search(r'31337: \{[^}]*?pool: "(0x[0-9a-fA-F]{40})"', cfg, re.S).group(1)
B = open(sys.argv[1]).read().strip().split(",")
TESTER = sys.argv[2] if len(sys.argv) > 2 else None
assert len(B) >= 60, "need 60+ burner addresses"
random.seed(11)
E = 10**18
FIN_GAS = 15_000_000  # a sale's all-or-nothing burn needs 12M+ available

_id = 0
def rpc(method, *params):
    global _id; _id += 1
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": list(params)}).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req))
    if "error" in out: raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]

def cd(sig, *args): return subprocess.run(["cast", "calldata", sig, *map(str, args)], capture_output=True, text=True, check=True).stdout.strip()
def raw(to, sig, *args): return rpc("eth_call", {"to": to, "data": cd(sig, *args)}, "latest")
def call(to, sig, *args, word=0): return int(raw(to, sig, *args)[2 + 64 * word: 2 + 64 * (word + 1)], 16)
def addr(to, sig, *args, word=0): return "0x" + raw(to, sig, *args)[2 + 64 * word + 24: 2 + 64 * (word + 1)]
def send(frm, to, sig, *args, value=0, gas=FIN_GAS):
    h = rpc("eth_sendTransaction", {"from": frm, "to": to, "data": cd(sig, *args), "value": hex(value), "gas": hex(gas)})
    r = None
    for _ in range(300):
        r = rpc("eth_getTransactionReceipt", h)
        if r: break
        time.sleep(0.02)
    if r["status"] != "0x1": raise RuntimeError(f"{sig} {args} from {frm} reverted")
def ids_of(credits, who):
    out = subprocess.run(["cast", "call", credits, "tokensOf(address)(uint256[])", who, "--rpc-url", RPC],
                         capture_output=True, text=True, check=True).stdout
    return [int(x) for x in re.findall(r"\d+", out)]
def eth(w): return f"{w / E:.4f} ETH"
def state(n): return ["Filling", "Full", "Auction", "Sold"][call(POOL, "batchInfo(uint256)", n)]
skip = lambda h=24: (rpc("evm_increaseTime", h * 3600 + 60), rpc("evm_mine"))

rpc("anvil_autoImpersonateAccount", True)
assert call(POOL, "MIN_BACKING()") == 80, "config.js doesn't point at a BackedPool: run BACKED=1 ./demo-testnet.sh"
CREDITS = addr(POOL, "credits()")
FEED = addr(POOL, "ethUsdFeed()")
# The fork's Chainlink feed never updates, so skipping days would flip the pool to its fallback fee.
price = int(raw(FEED, "latestRoundData()")[66:130], 16)
rpc("anvil_setCode", FEED, json.load(open("out/Mocks.sol/MockFeed.json"))["deployedBytecode"]["object"])
rpc("anvil_setStorageAt", FEED, "0x" + "0" * 64, "0x" + format(price, "064x"))
fee = lambda n: call(POOL, "depositFeeFor(uint256)", n)
STORE = addr(POOL, "store()")
OWNER = addr(STORE, "owner()")
# Testnet fees are cents, so the treasury holds little: top it up (local demo only) so it can back.
rpc("anvil_setBalance", STORE, hex(int(rpc("eth_getBalance", STORE, "latest"), 16) + 2 * E // 10))
print(f"pool {POOL} (BackedPool) · fee for 40: {fee(40)} wei")

for b in B + ([TESTER] if TESTER else []): rpc("anvil_setBalance", b, hex(3 * E))
# Depositors in order: pairs of 40 fill batches #0–21; the tester (if any) pairs up in batch #8.
order = B[:16] + ([TESTER] if TESTER else [B[16]]) + B[17:44]
outsiders = B[50:]
for who in order + B[44:49]:
    send(who, CREDITS, "setApprovalForAll(address,bool)", POOL, "true", gas=200_000)
for who in order:
    ids = ids_of(CREDITS, who)[:40]
    send(who, POOL, "deposit(uint256[])", "[" + ",".join(map(str, ids)) + "]", value=fee(40))
for who in B[44:49]:
    ids = ids_of(CREDITS, who)[:10]
    send(who, POOL, "deposit(uint256[])", "[" + ",".join(map(str, ids)) + "]", value=fee(10))
print(f"deposits: batches #0–21 full, open batch #{call(POOL, 'openBatchId()')} at 50/80")

deps = lambda n: order[2 * n: 2 * n + 2]
def vote(n, lo, hi):
    for d in deps(n):
        if d != TESTER: send(d, POOL, "setReserve(uint256,uint256)", n, random.randrange(lo, hi) * E // 1000)
def back(n, who, milli): send(who, POOL, "back(uint256)", n, value=milli * E // 1000)
def start(n):
    open_ = call(POOL, "bestBacking(uint256)", n, word=1)
    send(random.choice(outsiders), POOL, "startAuction(uint256,uint256)", n, open_)
def bids(n, k, to=None):
    last = None
    for i in range(k):
        who = random.choice([x for x in outsiders if x != last])
        v = call(POOL, "minNextBid(uint256)", n)
        if to and i == k - 1: v = max(v, to)
        send(who, POOL, "bid(uint256)", n, value=v)
        last = who

def price(n): return call(POOL, "majorityMinimum(uint256)", n)

print("round 1: #0–3 sold · #4 the treasury wins at the price · #5 sold after the majority lowered its price")
for n in range(6):
    vote(n, 10, 20)                                          # 0.010–0.019 ETH
    if n == 4:  # the treasury backs at exactly the depositors' price; nobody outbids it
        send(OWNER, STORE, "backBatch(uint256,uint256,uint256)", n, price(n), price(n))
        start(n); continue
    if n == 5:  # a lowball first: it can't start anything…
        back(n, outsiders[0], 5)                             # 0.005 ETH, below the price
        for d in deps(n): send(d, POOL, "setReserve(uint256,uint256)", n, 5 * E // 1000)  # …until the majority agrees to it
        start(n); continue
    send(random.choice(outsiders), POOL, "back(uint256)", n, value=price(n))  # a backer at the price
    if n % 2: back(n, random.choice(outsiders), 3)          # plus a lower one that never counts
    start(n)
    bids(n, random.randrange(1, 4))
skip()
for n in range(6): send(random.choice(outsiders), POOL, "settle(uint256)", n)
print("  " + ", ".join(f"#{n} {state(n)}" for n in range(6)))
for n in range(3):
    for d in deps(n): send(d, POOL, "claim(uint256)", n, gas=300_000)

print("#6–7: price set, only a lowball backing (can't start) · #8: the tester's vote makes the price")
for n in (6, 7):
    vote(n, 20, 30)
    back(n, random.choice(outsiders), 2)                     # 0.002 ETH lowball
other = [x for x in deps(8) if x != TESTER][0]
send(other, POOL, "setReserve(uint256,uint256)", 8, 12 * E // 1000)  # 40 slots at 0.012: one vote short
back(8, random.choice(outsiders), 12)                        # a backer waiting at 0.012

print("round 2: #10–14 live auctions with rival bids")
for n in range(10, 15):
    vote(n, 10, 30)
    send(random.choice(outsiders), POOL, "back(uint256)", n, value=price(n))
    start(n); bids(n, random.randrange(1, 5))
rpc("evm_increaseTime", 3 * 3600); rpc("evm_mine")
print("#15–17 backed at the price · #18 treasury-backed · #19 treasury leads · #20–21 price set, no backer")
for n in range(15, 22):
    vote(n, 10, 30)
for n in range(15, 18):
    send(random.choice(outsiders), POOL, "back(uint256)", n, value=price(n) + random.randrange(0, 3) * E // 1000)
    if n == 16: back(n, random.choice(outsiders), 3)
send(OWNER, STORE, "backBatch(uint256,uint256,uint256)", 18, price(18), price(18))
send(OWNER, STORE, "backBatch(uint256,uint256,uint256)", 19, price(19), price(19))
start(19)
send(B[0], POOL, "sweepFees()", gas=500_000)
sid4 = call(POOL, "batchInfo(uint256)", 4, word=3)
send(OWNER, STORE, "list(uint256,uint256)", sid4, 20, gas=300_000)
bf = call(STORE, "bidFee()")
for who, pts in [(deps(0)[0], 20), (deps(1)[1], 40), (deps(0)[0], 60)]:  # points earned at burn
    send(who, STORE, "bid(uint256,uint256)", sid4, pts, value=bf, gas=300_000)
print(f"#4 won by the treasury → Statement #{sid4} listed in the store, 3 SCREDIT bids")
if TESTER:  # local demo only: hand the store to the tester so its owner controls show
    send(OWNER, STORE, "transferOwnership(address)", TESTER, gas=200_000)
    send(TESTER, STORE, "acceptOwnership()", gas=200_000)
    print(f"store owner → tester {TESTER}")
print(f"\ndone · fees swept · tester {TESTER or '(none)'}")
