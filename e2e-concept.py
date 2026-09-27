"""End-to-end concept test on a fresh mainnet fork: every path a batch can take, with the
money and the NFTs checked at every step. Run after ./demo-fork.sh (a FRESH fork: this
skips weeks of chain time, and the price feed can't update on a fork, so all deposits
happen first).

    ./demo-fork.sh && python3 e2e-concept.py
"""
import importlib.util, sys
from decimal import Decimal

spec = importlib.util.spec_from_file_location("sa", "simulate-auction.py")
sa = importlib.util.module_from_spec(spec); sys.argv = sys.argv[:1]; spec.loader.exec_module(sa)
from_wei, ETH, POOL, CREDITS = sa.fmt, sa.ETH, sa.POOL, sa.CREDITS

checks = 0
def ok(cond, msg):
    global checks
    if not cond: raise SystemExit(f"  FAIL: {msg}")
    checks += 1
    print(f"  ✓ {msg}")

def bal(a): return int(sa.rpc("eth_getBalance", a, "latest"), 16)
def pool_eth(): return bal(POOL)
def u(sig, *a, to=POOL): return int(sa.call(sig, *a, to=to)[0])
def owner_of(nft, id):
    try: return sa.call("ownerOf(uint256)(address)", id, to=nft)[0].lower()
    except Exception: return None  # burned

def W(x): return int(Decimal(str(x)) * 10**18)   # exact ETH -> wei

def wallet(n): return "0x" + format(0xC0FFEE0000000000000000000000000000000000 + 5000 + n, "040x")

# Real Credits come from a large holder plus the two demo wallets (all impersonated on the fork).
SOURCES = [sa.DONOR, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
           "0x48138f98cBd6e958A9606075db045A8dBa682D59"]  # another large real holder (impersonated on the fork only)
donor_ids = []
for src in SOURCES:
    sa.rpc("anvil_impersonateAccount", src); sa.fund(src)
    donor_ids += [(src, i) for i in sa.call("tokensOf(address)(uint256[])", src, to=CREDITS)[0]]
FEE = u("depositFee()(uint256)")
STATEMENTS = sa.call("statements()(address)")[0]
FEE_WALLET = sa.call("feeRecipient()(address)")[0]
for b in sa.BIDDERS: sa.fund(b, 1000)                                            # collectors with test ETH
if len(donor_ids) < 410: raise SystemExit(f"sources hold only {len(donor_ids)} Credits; need 410")
deposited = {}   # wallet -> list of ids

def dep(w, k):
    picks = [donor_ids.pop(0) for _ in range(k)]
    ids = [i for _, i in picks]
    sa.fund(w, 1)
    for src, cid in picks: sa.send(src, "transferFrom(address,address,uint256)", src, w, cid, to=CREDITS)
    sa.send(w, "setApprovalForAll(address,bool)", POOL, "true", to=CREDITS)
    before = pool_eth()
    sa.send(w, "deposit(uint256[])", "[" + ",".join(map(str, ids)) + "]", value=(FEE + FEE // 20) * k)
    assert pool_eth() - before == FEE * k, "excess fee not refunded exactly"
    deposited.setdefault(w, []).extend(ids)
    return ids

def fill_batch(start, sizes):
    ws = [wallet(start + i) for i in range(len(sizes))]
    for w, k in zip(ws, sizes): dep(w, k)
    return ws

def claim_all(b):
    proceeds = sa.info(b)[4]
    paid = 0
    for a, n in sa.depositors(b):
        before = pool_eth()
        sa.send(a, "claim(uint256)", b)
        got = before - pool_eth()
        assert got == proceeds * n // 80, f"{a} got {got}, owed {proceeds * n // 80}"
        paid += got
    return proceeds, paid

print(f"pool {POOL}\nfee per Credit {from_wei(FEE)} · {len(donor_ids)} real Credits available\n")

# ───────────── deposit phase (all at t0: the feed goes stale once time is skipped) ─────────────
print("DEPOSITS")
A = fill_batch(0,  [3, 6, 2, 8, 1, 4, 2, 5, 2, 7, 8, 1, 5, 1, 1, 6, 8, 7, 1, 2])   # batch 0
B = fill_batch(20, [2, 8, 2, 5, 5, 7, 2, 7, 3, 1, 2, 8, 8, 1, 1, 5, 2, 5, 4, 2])   # batch 1
C = fill_batch(40, [80])                                                         # batch 2, whale
D = fill_batch(41, [41, 39])                                                     # batch 3
E = fill_batch(43, [50, 30])                                                     # batch 4, never assembled
F = fill_batch(45, [6, 4])                                                       # batch 5, filling
ok(u("openBatchId()(uint256)") == 5, "5 full batches + 1 filling (batch #5 at 10/80)")
total_credits = 80 * 5 + 10
ok(u("accruedFees()(uint256)") == FEE * total_credits, f"fees = $1 × {total_credits} Credits exactly")
ok(u("balanceOf(address)(uint256)", POOL, to=CREDITS) == total_credits, f"pool holds all {total_credits} Credits")

# ───────────── F: withdraw while filling ─────────────
print("\nF. WITHDRAW WHILE FILLING")
w = F[1]; ids = deposited[w]
sa.send(w, "withdraw(uint256[])", "[" + ",".join(map(str, ids)) + "]")
ok(all(owner_of(CREDITS, i) == w.lower() for i in ids), "all 4 Credits back in the depositor's wallet")
ok(sa.info(5)[1] == 6, "batch #5 now 6/80; fee not refunded (by design)")

# ───────────── A: auction with a bidding war ─────────────
print("\nA. AUCTION WITH A BIDDING WAR (batch #0, 20 depositors)")
sa.send(sa.BIDDERS[0], "assemble(uint256)", 0)                                 # anyone can assemble
sidA = sa.info(0)[3]
ok(owner_of(STATEMENTS, sidA) == POOL.lower(), f"Statement #{sidA} minted to the pool")
ok(all(owner_of(CREDITS, i) is None for w in A for i in deposited[w]), "all 80 Credits burned")
vault = sa.call("vault()(address)")[0]
ok(u("balanceOf(address)(uint256)", vault, to=CREDITS) == 0, "assembly vault empty afterwards")
for a, n in sa.depositors(0): sa.fund(a, 1); sa.send(a, "setReserve(uint256,uint256)", 0, W(1.5))
reserve = u("auctionReserve(uint256)(uint256)", 0)
ok(reserve == W(1.5), "reserve 1.5 ETH")
sa.send(sa.BIDDERS[0], "startAuctionAt(uint256,uint256)", 0, reserve)
for who, amt in [(0, 1.5), (1, 1.8), (2, 2.2), (1, 2.6), (3, 3.0)]:
    sa.bid(0, str(amt), sa.BIDDERS[who])
refunds = {sa.BIDDERS[i]: u("pendingReturns(address)(uint256)", sa.BIDDERS[i]) for i in range(3)}
ok(refunds[sa.BIDDERS[0]] == W(1.5) and refunds[sa.BIDDERS[1]] == W(4.4) and refunds[sa.BIDDERS[2]] == W(2.2),
   "outbid bids held as refunds (1.5, 1.8+2.6, 2.2)")
ends = int(sa.call("auctions(uint256)(address,uint256,uint256,uint64)", 0)[3])
now = int(sa.rpc("eth_getBlockByNumber", "latest", False)["timestamp"], 16)
sa.skip((ends - now - 60) / 3600)                                               # 1 minute left
sa.bid(0, "3.2", sa.BIDDERS[2])
ends2 = int(sa.call("auctions(uint256)(address,uint256,uint256,uint64)", 0)[3])
ok(ends2 > ends, "last-minute bid extended the auction (anti-snipe)")
sa.skip(1)
sa.send(sa.BIDDERS[0], "settle(uint256)", 0)
ok(owner_of(STATEMENTS, sidA) == sa.BIDDERS[2].lower(), "Statement delivered to the winner (3.2 ETH)")
proceeds, paid = claim_all(0)
ok(proceeds == W(3.2) - W(3.2) // 100, "proceeds = 3.2 ETH − 1% = 3.168 ETH")
ok(proceeds - paid < 80, f"all 20 depositors paid exactly slots/80 ({from_wei(paid)}; dust {proceeds - paid} wei)")
for bidr in sa.BIDDERS:
    amt = u("pendingReturns(address)(uint256)", bidr)
    if amt:
        before = pool_eth(); sa.send(bidr, "withdrawRefund()"); assert before - pool_eth() == amt
ok(all(u("pendingReturns(address)(uint256)", b) == 0 for b in sa.BIDDERS), "every outbid bidder refunded in full")

# ───────────── B: no bids → back to voting → sells ─────────────
print("\nB. NO BIDS, RE-VOTE, SELLS (batch #1)")
sa.send(sa.BIDDERS[0], "assemble(uint256)", 1)
for a, n in sa.depositors(1): sa.send(a, "setReserve(uint256,uint256)", 1, 50 * ETH)
sa.send(sa.BIDDERS[0], "startAuction(uint256)", 1)
sa.skip(25)
sa.send(sa.BIDDERS[0], "settle(uint256)", 1)
ok(sa.info(1)[0] == "Assembled", "no bids at 50 ETH: back to voting, Statement still in the pool")
for a, n in sa.depositors(1): sa.send(a, "setReserve(uint256,uint256)", 1, W(0.9))
sa.send(sa.BIDDERS[0], "startAuction(uint256)", 1)
sa.bid(1, "1.1", sa.BIDDERS[3])
sa.skip(25)
sa.send(sa.BIDDERS[0], "settle(uint256)", 1)
proceeds, paid = claim_all(1)
ok(sa.info(1)[0] == "Settled" and proceeds - paid < 80, f"re-voted at 0.9, sold for 1.1 ETH, all 20 paid ({from_wei(paid)})")

# ───────────── C: sole holder redeems ─────────────
print("\nC. SOLO REDEEM (batch #2, one wallet with all 80)")
fees_before = u("accruedFees()(uint256)")
sa.send(sa.BIDDERS[0], "assemble(uint256)", 2)
sidC = sa.info(2)[3]
sa.send(C[0], "redeem(uint256)", 2)
ok(owner_of(STATEMENTS, sidC) == C[0].lower(), f"Statement #{sidC} went straight to the whale")
ok(u("accruedFees()(uint256)") == fees_before, "no 1% fee on a redeem")

# ───────────── D: majority blocks with an absurd price → 30-day fallback ─────────────
print("\nD. 30-DAY FALLBACK (batch #3: 41 slots vs 39)")
sa.send(sa.BIDDERS[0], "assemble(uint256)", 3)
sa.send(D[0], "setReserve(uint256,uint256)", 3, 10_000 * ETH)   # majority, unreachable
sa.send(D[1], "setReserve(uint256,uint256)", 3, 1 * ETH)        # minority
ok(u("auctionReserve(uint256)(uint256)", 3) == 10_000 * ETH, "majority sets the minimum: 10,000 ETH")
ok(sa.call("noReserveOpen(uint256)(bool)", 3)[0] is False, "fallback not open yet")
sa.skip(24 * 30 + 1)
ok(sa.call("noReserveOpen(uint256)(bool)", 3)[0] is True, "30 days unsold: fallback open")
ok(u("auctionReserve(uint256)(uint256)", 3) == 1 * ETH, "minimum is now the LOWEST vote: 1 ETH")
sa.send(D[1], "startAuctionAt(uint256,uint256)", 3, ETH)       # the minority starts it
sa.bid(3, "1.2", sa.BIDDERS[1])
sa.skip(25)
sa.send(D[1], "settle(uint256)", 3)
proceeds, paid = claim_all(3)
ok(proceeds - paid < 80, f"sold for 1.2 ETH; minority (39/80) and majority (41/80) both paid ({from_wei(paid)})")

# ───────────── E: never assembled → escape hatch ─────────────
print("\nE. ESCAPE HATCH (batch #4, full but never assembled)")
ok(sa.call("escapeOpen(uint256)(bool)", 4)[0] is True, "14+ days since it filled: escape open")
for w in E:
    ids = deposited[w]
    sa.send(w, "withdraw(uint256[])", "[" + ",".join(map(str, ids)) + "]")
    ok(all(owner_of(CREDITS, i) == w.lower() for i in ids), f"{sa.short(w)} got all {len(ids)} Credits back")
ok(sa.info(4)[0] == "Dissolved", "batch #4 dissolved")

# ───────────── ledger ─────────────
print("\nLEDGER")
sales = W(3.2) + W(1.1) + W(1.2)
expect_fees = FEE * total_credits + sum(s // 100 for s in (W(3.2), W(1.1), W(1.2)))
ok(u("accruedFees()(uint256)") == expect_fees, f"fees = $1 × {total_credits} Credits + 1% of {from_wei(sales)} in sales = {from_wei(expect_fees)}")
# Measure the pool side: the demo's fee wallet is anvil's default account, which also collects
# local block fees, so its own balance isn't a clean signal.
pool_before = pool_eth()
sa.send(sa.BIDDERS[0], "sweepFees()")
ok(pool_before - pool_eth() == expect_fees and u("accruedFees()(uint256)") == 0,
   f"sweep sent exactly {from_wei(expect_fees)} to the fee wallet {sa.short(FEE_WALLET)}")
ok(pool_eth() < 3 * 80, f"pool left holding only rounding dust ({pool_eth()} wei)")
ok(u("balanceOf(address)(uint256)", POOL, to=CREDITS) == 6, "pool holds only batch #5's 6 Credits")
burned = sum(1 for w in A + B + C + D for i in deposited[w] if owner_of(CREDITS, i) is None)
ok(burned == 320, "320 Credits burned for 4 Statements")
print(f"\nALL {checks} CHECKS PASSED")
