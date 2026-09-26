"""Walk one batch through its whole life on the fork demo, one step at a time.

    python3 simulate-auction.py status  B          # who's in batch B, state, votes, auction
    python3 simulate-auction.py fill    B [N]      # top B up to N (default 80) with new simulated depositors
    python3 simulate-auction.py assemble B         # burn the 80 Credits into a Statement
    python3 simulate-auction.py vote    B 1.5      # simulated depositors vote reserves around 1.5 ETH
    python3 simulate-auction.py start   B          # start the 24h auction
    python3 simulate-auction.py bid     B 2.4      # one simulated collector bids 2.4 ETH
    python3 simulate-auction.py war     B 3        # collectors trade bids up to ~3 ETH
    python3 simulate-auction.py skip    25         # jump the chain forward N hours
    python3 simulate-auction.py settle  B          # close the auction, Statement → winner
    python3 simulate-auction.py claim   B          # every simulated depositor claims their share

Simulated wallets act through anvil impersonation, so this only works on the local fork.
Real people (like you in the browser) are never acted for; they click their own buttons.
"""
import json, math, random, re, subprocess, sys, time, urllib.request

RPC = "http://127.0.0.1:8545"
CREDITS = "0x97630aA70AB14ed9883B41dAfccBc11349723043"
DONOR = "0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a"
POOL = re.search(r'31337: \{[^}]*?pool: "(0x[0-9a-fA-F]{40})"', open("app/config.js").read(), re.S).group(1)
SIM_PREFIX = "0xc0ffee"   # depositors from simulate-participants.py and `fill`
BIDDERS = ["0x" + format(0xB1DDE70000000000000000000000000000000000 + i + 1, "040x") for i in range(4)]
STATES = ["Filling", "Full", "Assembled", "Auction", "Settled", "Redeemed", "Dissolved"]
ETH = 10**18
rng = random.Random()

_id = 0
def rpc(method, *params):
    global _id; _id += 1
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": list(params)}).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req))
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error'].get('message')}")
    return out["result"]

def cast(*args):
    return subprocess.run(["cast", *args], capture_output=True, text=True, check=True).stdout.strip()

def call(sig, *args, to=POOL):
    """Read a view function; returns cast's decoded output lines."""
    out = cast("call", to, sig, *map(str, args), "--rpc-url", RPC, "--json")
    return json.loads(out)

def send(frm, sig, *args, to=POOL, value=0):
    rpc("anvil_impersonateAccount", frm)
    data = cast("calldata", sig, *map(str, args))
    h = rpc("eth_sendTransaction", {"from": frm, "to": to, "data": data, "value": hex(value)})
    for _ in range(600):  # fork mines lazily while fetching state
        r = rpc("eth_getTransactionReceipt", h)
        if r: break
        time.sleep(0.05)
    if not r or r["status"] != "0x1":
        raise RuntimeError(f"{sig} from {frm} reverted")

def fund(addr, eth=10):
    rpc("anvil_setBalance", addr, hex(eth * ETH))

def fmt(wei): return f"{int(wei) / ETH:.4f}".rstrip("0").rstrip(".") + " ETH"
def short(a): return f"{a[:6]}…{a[-4:]}"
def is_sim(a): return a.lower().startswith(SIM_PREFIX)

def depositors(b):
    addrs = call("batchDepositors(uint256)(address[])", b)[0]
    return [(a, int(call("slots(uint256,address)(uint256)", b, a)[0])) for a in addrs]

def info(b):
    s, filled, deps, sid, proceeds, _ = call("batchInfo(uint256)(uint8,uint256,uint256,uint256,uint256,uint64)", b)
    return STATES[int(s)], int(filled), int(deps), int(sid), int(proceeds)

# ───────────────────────── steps ─────────────────────────

def status(b):
    state, filled, deps, sid, proceeds = info(b)
    print(f"Batch #{b}: {state} · {filled}/80 Credits · {deps} depositors" + (f" · Statement #{sid}" if state not in ("Filling", "Full") else ""))
    for a, n in sorted(depositors(b), key=lambda x: -x[1]):
        vote = int(call("reservePref(uint256,address)(uint256)", b, a)[0])
        who = "sim" if is_sim(a) else "REAL"
        print(f"  {short(a)} {who:>4}  {n:>2} slots  {n / 80:6.2%}" + (f"  vote {fmt(vote)}" if vote else ""))
    if state == "Assembled":
        try: print(f"  reserve if started now: {fmt(call('currentReserve(uint256)(uint256)', b)[0])}")
        except subprocess.CalledProcessError: print("  reserve: not enough votes yet (needs >40 slots)")
    if state in ("Auction", "Settled"):
        bidder, high, reserve, ends = call("auctions(uint256)(address,uint256,uint256,uint64)", b)
        now = int(rpc("eth_getBlockByNumber", "latest", False)["timestamp"], 16)
        left = int(ends) - now
        print(f"  reserve {fmt(reserve)} · high bid {fmt(high)} by {short(bidder)} · " +
              (f"ends in {left // 3600}h {left % 3600 // 60}m" if left > 0 else "ended"))
    if state == "Settled":
        print(f"  sold for {fmt(int(call('auctions(uint256)(address,uint256,uint256,uint64)', b)[1]))} · depositors split {fmt(proceeds)} after 1%")

def fill(b, to=80):
    b = int(b)
    state, filled, *_ = info(b)
    if state != "Filling": sys.exit(f"batch #{b} is {state}, not Filling")
    need = int(to) - filled  # e.g. `fill 2 76` leaves 4 slots for a real person to complete the batch
    donor_ids = call("tokensOf(address)(uint256[])", DONOR, to=CREDITS)[0]
    rpc("anvil_impersonateAccount", DONOR); fund(DONOR)
    fee = int(call("depositFee()(uint256)")[0])
    base = 0xC0FFEE0000000000000000000000000000000000 + 1000 + b * 100
    i = 0
    while need:
        k = min(need, rng.randint(1, 8)); need -= k
        w = "0x" + format(base + i, "040x"); i += 1
        fund(w, 1)
        ids = [donor_ids.pop(0) for _ in range(k)]
        for cid in ids: send(DONOR, "transferFrom(address,address,uint256)", DONOR, w, cid, to=CREDITS)
        send(w, "setApprovalForAll(address,bool)", POOL, "true", to=CREDITS)
        send(w, "deposit(uint256[])", "[" + ",".join(map(str, ids)) + "]", value=(fee + fee // 20) * k)  # $1 per Credit, 5% buffer
        print(f"  {short(w)} deposited {k}")
    status(b)

def assemble(b):
    fund(BIDDERS[0]); send(BIDDERS[0], "assemble(uint256)", b)  # anyone can assemble
    status(b)

def vote(b, around):
    around = float(around)
    for a, n in depositors(b):
        if not is_sim(a): continue
        price = round(around * rng.uniform(0.7, 1.3), 3)
        fund(a, 1)
        send(a, "setReserve(uint256,uint256)", b, int(price * ETH))
    status(b)

def start(b):
    fund(BIDDERS[0]); send(BIDDERS[0], "startAuction(uint256)", b)
    status(b)

def bid(b, amount, who=None):
    who = who or rng.choice(BIDDERS)
    fund(who, 1000)
    send(who, "bid(uint256)", b, value=int(float(amount) * ETH))
    print(f"  {short(who)} bid {amount} ETH")

def war(b, up_to):
    up_to = float(up_to)
    bidder, high, reserve, _ = call("auctions(uint256)(address,uint256,uint256,uint64)", b)
    price = max(int(high) * 1.05, int(reserve)) / ETH if int(high) else int(reserve) / ETH
    last = bidder.lower()
    while price <= up_to:
        who = rng.choice([x for x in BIDDERS if x.lower() != last])
        price = math.ceil(price * 1e4) / 1e4  # round up, so we never land under the 5% minimum raise
        bid(b, f"{price:.4f}", who); last = who.lower()
        price *= rng.uniform(1.06, 1.2)
    status(b)

def skip(hours):
    rpc("evm_increaseTime", int(float(hours) * 3600)); rpc("evm_mine")
    print(f"  chain moved forward {hours}h")

def settle(b):
    fund(BIDDERS[0]); send(BIDDERS[0], "settle(uint256)", b)
    status(b)

def claim(b):
    proceeds = info(b)[4]
    for a, n in depositors(b):
        if not is_sim(a):
            print(f"  {short(a)} REAL  {n} slots → {fmt(proceeds * n // 80)} waiting (claim it in the browser)")
            continue
        send(a, "claim(uint256)", b)
        print(f"  {short(a)} sim   {n} slots → claimed {fmt(proceeds * n // 80)}")

if __name__ == "__main__":
    steps = {"status": status, "fill": fill, "assemble": assemble, "vote": vote, "start": start,
             "bid": bid, "war": war, "skip": skip, "settle": settle, "claim": claim}
    if len(sys.argv) < 2 or sys.argv[1] not in steps: sys.exit(__doc__)
    steps[sys.argv[1]](*sys.argv[2:])
