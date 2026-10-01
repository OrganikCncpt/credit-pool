# Sell first, burn second: backed auctions

**Status:** design, 2026-09-30. No code yet. It will be built once Jack's Statements contract is published
and has passed the S-1..S-8 checks (`docs/STATEMENTS-DESIGN.md`). It replaces today's "burn first, sell
second" core. It is **not** covered by any audit so far: it needs its own full internal audit and an
external audit before mainnet.

**Owner decisions (2026-09-30):**
1. **Every auction must be backed.** An auction can't start until a backer has committed ETH for the
   whole batch.
2. **Backing can be any amount.** Depositors are never forced to take it.
3. **The auction opens with the best backing as its opening bid,** and anyone can beat it.
4. If the auction ends below the depositors' minimum, they have **24 hours** to accept the best bid by
   **majority** (more than 40 of 80 slots). Otherwise every bid is refunded and nothing burns.
5. **No separate last-call window.** The 24-hour auction is the "anyone can beat it" window.
6. **Several backers can back the same batch.** The highest opens the auction; the rest stay posted.
7. The design must be **ultra safe**.

## 1. Why

Today a full batch is burned first and sold afterwards. If nobody buys, depositors hold a share of an
unsold Statement: no Credits, no ETH, money stuck. That forced the 30-day fallback, the treasury's
buy-unsold role and a long tail of edge cases (CP-29..58).

**New rule: nothing burns until a sale is locked in, and every sale starts from a real, funded bid.**
- Credits stay in the pool, unburned and attributable, until a buyer's ETH is committed at or above the
  depositors' majority price. An auction can only open with a backing at that price or more, so every
  auction that starts ends in a sale (or a full unwind if the burn itself fails).
- Then the burn, delivery and payment happen together in one transaction.
- With no sale, depositors keep an exit with their Credits intact, and every bidder gets their ETH back.

## 2. The flow

```
Filling ─fill─▶ Full ── vote a price (41/80) ── backing ≥ price ──start──▶ AUCTION (24h, backing = opening bid)
   ▲             │ backers can post, raise, withdraw at any amount             │
   │             │ (below the price they just wait; they can't start anything)  └─ ends ─▶ FINALIZE (sells)
   └─ withdraw ──┘ (no auction live; clears votes)                                         │ burn fails
                                                                                ◀── unwind: refund, back to Full
FINALIZE = burn the 80 (vault) → Statement to the buyer → proceeds to depositors (pull) → points
```

**Revision (2026-09-30, "option 1"):** the first build let any backing open an auction, and a 24h accept
window handled auctions that ended below the price. That let a lowball backer start auctions nobody
wanted and lock depositors' Credits for up to 48h, repeatedly, for gas only. Now an auction opens only
with a majority price and a backing at or above it. The accept window, `acceptBid` and `expire` are
gone. A majority that wants to sell for less lowers its price before the auction instead of accepting
after it.

1. **Filling.** Deposits and withdrawals work as today. Fees are unchanged ($2/Credit, or $1 each for 6+),
   split 25% platform / 75% treasury.
2. **Full.** Depositors vote their minimum price, with the same majority rule as today: the price at
   which more than 40 of 80 slots accept. They also vote the print order (Design 1 in the Statements doc).
3. **Backing.** Anyone can back a batch by posting ETH for the whole batch, held by the contract, in **any
   amount**.
   - Several backers can back the same batch.
   - A backer can withdraw their backing any time **except** while it is the opening bid of a live
     auction. Raising or posting a backing is only possible while the batch is Filling or Full (no new
     backings during an auction; bidding is the way in then). A backing below the majority price is
     allowed and simply waits: it can't open an auction.
   - At most 10 backers per batch. A newcomer displaces a stale backing (made for an older set of
     Credits) first, otherwise must beat the lowest current one (internal audit M-2).
   - Backing can be posted while the batch is still filling, as an early signal. It only counts once the
     batch is Full.
4. **Start.** Anyone can start the auction once the batch is Full, has a majority price, **and its best
   current backing is at or above that price** (`NoMinimum` / `BelowMinimum` otherwise).
   - The highest backing becomes the opening bid. That backer's ETH is now committed.
   - The print order and composition freeze.
   - The other backings stay posted, untouched, as fallbacks for a later round.
5. **Auction (24h).** Anyone, including depositors, can bid at least 5% above the current high bid. Bids
   in the last 15 minutes add 15 minutes. Outbid bidders, including the backer, are refunded (pull).
6. **Auction ends:** FINALIZE runs (anyone can call it). The auction opened at or above the price and
   bids only rise, so the sale always meets it. Depositors' Credits are locked for at most the 24h auction
   plus anti-snipe extensions, and only at a price their majority set.
7. **FINALIZE (atomic).** In one transaction:
   1. burn the batch's 80 Credits through the AssemblyVault;
   2. verify one new Statement arrived;
   3. deliver it to the buyer;
   4. book the proceeds for depositors (claimed pro-rata, pull);
   5. award points (2 per burned Credit).

   If any step fails, **everything unwinds** (§5).
8. **Exit.** While no auction is live, a depositor of a Full batch can withdraw. The batch goes back to
   Filling, and all votes for it are cleared (the composition changed).
   Backings remain but must be re-matched to the new composition before a start.

## 3. Safety invariants (must hold always; each gets a handler invariant, and I1–I3 a formal proof)

| # | Invariant |
|---|---|
| I1 | Every Credit the pool holds belongs to exactly one depositor in exactly one unsold batch. A Credit leaves the pool only to its own depositor (withdraw) or burned inside FINALIZE of **its own** batch. |
| I2 | **Nothing burns** except in FINALIZE for an auction that opened with a backing ≥ the majority price (so its high bid ≥ that price). |
| I3 | Pool ETH ≥ Σ posted backings + live high bids + pending refunds + unclaimed proceeds + fees owed. |
| I4 | A backer's or bidder's ETH leaves only to (a) that same address, via withdraw or refund, or (b) that batch's depositors, via FINALIZE. Nobody else, ever. |
| I5 | A sale pays exactly the auction's high bid, and nobody can swap, lower or cancel a committed bid. |
| I6 | A failed burn never loses a Credit or a wei: a full unwind to the pre-FINALIZE state, and the buyer is refunded. |
| I7 | No auction starts without a majority price and a funded backing at or above it; the opening bid is the highest current backing at that moment. |
| I8 | Backings bind to a composition nonce, and reopening a full batch clears its votes. Any change to a batch's Credit set invalidates them. |
| I9 | Each batch finalizes at most once. Each Statement is delivered to exactly one buyer and backs exactly one batch. |
| I10 | Neither owner can move Credits, backings, bids or proceeds, or pause any of it. |

## 4. Threat model

| Attack | Defence |
|---|---|
| Backer pulls out as the auction starts | Start reads and locks the highest backing in the same transaction; a withdraw in the same block either lands first (a different backing opens it) or reverts |
| Majority lowers its price to a sock puppet's lowball | Still a 24h open auction: anyone can outbid. The minority is outvoted exactly as with the minimum-price vote. The site shows price per Credit. |
| A lowball "backing" to start an auction and lock Credits | **Can't start**: an auction needs a backing ≥ the majority price (`BelowMinimum`). The lowball just waits, and depositors stay free to withdraw. |
| Backing spam (many tiny backings) | Only the top N backings per batch are stored (a new backing must beat the lowest to enter); escrow ties up capital |
| Swapping Credits after start | Composition nonce (I8); arrangement frozen at start; withdrawals blocked while an auction is live |
| Reentrancy (bidder, backer, depositor, fee wallet, Statements) | `nonReentrant` on every entry point; pull payments; checks-effects-interactions; FINALIZE internals `onlySelf` |
| Griefing the burn (Jack's contract rejects, cap reached, gas) | FINALIZE is an all-or-nothing self-call; on revert everything is undone (§5) |
| Buyer is a contract that can't receive the NFT | Plain `transferFrom` delivery (no receiver hook), so settlement can't be blocked |
| Price oracle manipulation | No floor oracle on-chain; prices come only from bids and votes |
| Gas limits (80 depositors, many backers) | Pull claims; bounded backing list; award loop measured (about 2.4M gas) |
| Stuck money | Every path ends in either FINALIZE or a refund; no batch can end holding an unsold Statement |
| Owner abuse | No owner power over any of it (I10); fee constants only |

## 5. FINALIZE and the unwind

Custody depends on this being all-or-nothing.

- `finalize(b)` (permissionless, `nonReentrant`) calls `this._finalize(b)` as an **external self-call**
  (`onlySelf`) inside `try/catch`.
- `_finalize` moves the batch's 80 Credits to the vault, calls the vault (which calls Jack's contract),
  checks the Statement, delivers it and books the proceeds.
- **If anything reverts, the whole self-call reverts,** including the Credit transfers to the vault.
  `finalize` then catches it, refunds the buyer into `pendingReturns`, and returns the batch to Full with
  an `Unwound` event.
- **No partial state is possible.** A `try/catch` on the vault call alone would *not* be safe, because the
  Credit transfers made before it would persist. That is why the whole finalize must be the self-call.
- The vault keeps today's delta checks: only this batch's Credits are reachable, exactly one new Statement
  arrives, and nothing else moves.

## 6. What changes versus today

- **Removed:**
  - burn-before-sale and the post-burn Statement auction;
  - the 30-day lowest-vote fallback (AR-10) and its edge cases;
  - `unsoldAuctions`, `openedByFallback`, `votedMedian`'s treasury role, and the treasury's `buyUnsold` path;
  - `redeem` as a separate path: a sole 80-slot holder can back and accept their own batch, or use a
    `burnToSelf` with no payment.
- **Kept:**
  - deposits, fees and the 25/75 split;
  - majority minimum-price voting;
  - English-auction mechanics;
  - pull payments;
  - the AssemblyVault;
  - SCREDIT points (awarded at burn).
- **Store:**
  - keeps the SCREDIT auction of Statements it holds;
  - the treasury acquires Statements by **backing** batches like anyone else: owner-triggered, with the
    same per-purchase cap and 3-day raise delay;
  - the treasury's backing is just another bid, capped at the depositors' price, so it opens only at exactly that price.
- **Frontend (batch card):**
  - the minimum vote;
  - a "Back this batch" button with the current backings (per Credit and against the floor);
  - Start auction, enabled once backed;
  - a live auction with the backing shown as the opening bid;
  - when relevant, an accept-window countdown with an "Accept the best bid" vote bar (x/80, needs 41);
  - Withdraw, which says it resets the batch's votes.

## 7. Open questions (answer from Jack's contract first)

- **S-1 / S-2:** the burn call and whether order or direction are parameters. These are fixed at auction start.
- **Delivery:** can the Statement be minted straight to the buyer, or must it come to the vault/pool first?
  We keep the vault either way.
- **Cap and pause behaviour:** what makes his burn revert, so we can test every unwind path.
- **Layering** ("back a Statement with Credits", `docs/LAYERING-AND-CUSTOM-BATCHES.md` Part B) uses the
  same backed-auction pattern: a layer burns only when its sale is locked in.

## 8. Build and verification plan (ultra-safe gate)

1. Implement on a branch, with invariants I1–I10 as handler invariants from day one.
2. Write an attack test for every row of §4, each failing without its defence.
3. Prove I1–I3 formally (Halmos or similar) for the finalize and unwind paths.
4. Fork tests with real Credits and **Jack's real contract**:
   - every unwind cause;
   - gas under 2^24 for the worst case.
5. The end-to-end concept test and the 100-burner rehearsal rewritten for backed auctions; real-Chrome UI flows.
6. A full internal audit (6 blind specialists plus an adversarial verifier), then Sepolia with real
   users, then an **external audit** of the final code before any mainnet deploy.
