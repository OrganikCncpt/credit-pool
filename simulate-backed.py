"""Fill a local BackedPool demo with burner activity (local anvil only; uses impersonation).

Run after `BACKED=1 ./demo-testnet.sh` with the burners (40 Credits each) and optionally your
tester wallet as TESTERS:

    python3 simulate-backed.py <burner-addresses.txt> [tester-address]

Leaves every state to look at (a depositor starts each auction; the depositors' price is the
reserve; the best backing is the fallback offer):
  #0–3   sold to a bidder at or above the price (#0–2 collected, #3 waiting to collect)
  #4     unsold round → the store treasury bought it at the price → listed for SCREDIT
  #5     a backing at the price opened the auction as its first bid; nobody beat it → sold to the backer
  #6     no bid, the holders voted to take the best (lower) offer → sold to that backer
  #7     started with no backing, no bid, no offer → ended unsold: resting; the store may buy it
  #8     the tester's batch: the other depositor voted; the tester's vote makes the price; a backer waits
  #9     no bid, holders deciding now (one of two depositors accepted)
  #10–14 live auctions with rival bids
  #15–17 priced and backed: a depositor can start
  #18–19 priced, waiting for a backer · #20–21 full, no price yet
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
def state(n): return ["Filling", "Full", "Auction", "Decide", "Sold"][call(POOL, "batchInfo(uint256)", n)]
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
def start(n):  # only a depositor can start
    send(deps(n)[0] if deps(n)[0] != TESTER else deps(n)[1], POOL, "startAuction(uint256)", n)
def bids(n, k, to=None):
    last = None
    for i in range(k):
        who = random.choice([x for x in outsiders if x != last])
        v = call(POOL, "minNextBid(uint256)", n)
        if to and i == k - 1: v = max(v, to)
        send(who, POOL, "bid(uint256)", n, value=v)
        last = who

def price(n): return call(POOL, "majorityMinimum(uint256)", n)
def ends(n): return call(POOL, "auctions(uint256)", n, word=3)
def offer(n): return addr(POOL, "auctions(uint256)", n, word=4), call(POOL, "auctions(uint256)", n, word=5)
def rnd(n): return call(POOL, "batchInfo(uint256)", n, word=5)
def accept(n, d):
    who, amt = offer(n)
    send(d, POOL, "acceptBacking(uint256,uint64,address,uint256)", n, rnd(n), who, amt)

print("round 1: #0–3 bid at the price · #4,#7 unsold · #5 backer meets the price · #6 holders take the backer · #9 deciding")
for n in list(range(8)) + [9]:
    vote(n, 10, 20)                                          # 0.010–0.019 ETH
    if n in (4, 6, 9): back(n, random.choice(outsiders), random.randrange(3, 6))   # an offer below the price
    elif n == 7: pass                                                               # no backing at all
    elif n == 5: send(random.choice(outsiders), POOL, "back(uint256)", n, value=price(n))
    else: back(n, random.choice(outsiders), random.randrange(3, 6))
    start(n)
    if n < 4: bids(n, random.randrange(1, 4), to=price(n))   # first bid at the price
skip()
for n in list(range(8)) + [9]: send(random.choice(outsiders), POOL, "settle(uint256)", n)
accept(6, deps(6)[0]); accept(6, deps(6)[1])                  # the majority takes the backer's offer
accept(9, [d for d in deps(9) if d != TESTER][0])             # 40 of 80: one more would sell it
for n in range(3):
    for d in deps(n): send(d, POOL, "claim(uint256)", n, gas=300_000)
skip()
send(random.choice(outsiders), POOL, "expire(uint256)", 4, gas=300_000)       # #7 already ended unsold at settle
send(OWNER, STORE, "buyUnsold(uint256,uint256)", 4, price(4))  # the treasury buys #4 at the price
print("  " + ", ".join(f"#{n} {state(n)}" for n in range(8)))

# #9 must still be deciding when the demo opens: a fresh round, after all other time skips
if state(9) == "Decide":
    send(random.choice(outsiders), POOL, "expire(uint256)", 9, gas=300_000)
    rpc("evm_increaseTime", 24 * 3600 + 60); rpc("evm_mine")
back(9, random.choice(outsiders), 4)
start(9)
rpc("evm_increaseTime", 24 * 3600 + 60); rpc("evm_mine")
send(random.choice(outsiders), POOL, "settle(uint256)", 9)
accept(9, deps(9)[0])

print("#8: the other depositor votes; a backer waits for the tester's vote")
other = [x for x in deps(8) if x != TESTER][0]
send(other, POOL, "setReserve(uint256,uint256)", 8, 12 * E // 1000)
back(8, random.choice(outsiders), 9)

print("round 2: #10–14 live auctions")
for n in range(10, 15):
    vote(n, 10, 30); back(n, random.choice(outsiders), random.randrange(3, 9)); start(n)
    bids(n, random.randrange(1, 4), to=price(n))
print("#15–17 priced and backed · #18–19 priced, no backer · #20–21 no price")
for n in range(15, 20): vote(n, 10, 30)
for n in range(15, 18): back(n, random.choice(outsiders), random.randrange(4, 12))
send(B[0], POOL, "sweepFees()", gas=500_000)
sid4 = call(POOL, "batchInfo(uint256)", 4, word=3)
send(OWNER, STORE, "list(uint256,uint256)", sid4, 20, gas=300_000)
bf = call(STORE, "bidFee()")
for who, pts in [(deps(0)[0], 20), (deps(1)[1], 40), (deps(0)[0], 60)]:  # points earned at burn
    send(who, STORE, "bid(uint256,uint256)", sid4, pts, value=bf, gas=300_000)
print(f"#4 bought by the treasury → Statement #{sid4} listed in the store, 3 SCREDIT bids")
if TESTER:  # local demo only: hand the store to the tester so its owner controls show
    send(OWNER, STORE, "transferOwnership(address)", TESTER, gas=200_000)
    send(TESTER, STORE, "acceptOwnership()", gas=200_000)
    print(f"store owner → tester {TESTER}")
print(f"\ndone · fees swept · tester {TESTER or '(none)'}")
