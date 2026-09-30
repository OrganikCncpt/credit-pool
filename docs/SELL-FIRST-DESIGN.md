# Sell first, burn second (with backer offers)

**Status:** design, 2026-09-30. No code yet. It will be built once Jack's Statements contract is published
and has passed the S-1..S-8 checks (`docs/STATEMENTS-DESIGN.md`). It replaces today's "burn first, sell
second" core. It is **not** covered by any audit so far: it needs its own full internal audit and an
external audit before mainnet.

**Owner decisions (2026-09-30):**
- Accepting a backer offer needs a **majority** (more than 40 of 80 slots).
- Every acceptance opens a **1-hour last-call window**.
- The design must be **ultra safe**.

**Default chosen for safety:** backers may post offers any time; acceptance is only possible once the batch
is Full and bound to its exact set of Credits.

## 1. Why

Today a full batch is burned first and sold afterwards. If nobody buys, depositors hold a share of an
unsold Statement: no Credits, no ETH, money stuck. That forced the 30-day fallback, the treasury's
buy-unsold role and a long tail of edge cases.

**New rule: nothing burns until a sale is locked in.** Credits stay in the pool, unburned and
attributable, until a buyer's ETH is committed at a price the majority agreed to. Then the burn,
delivery and payment happen together in one transaction. With no buyer, depositors keep an exit
with their Credits intact.

## 2. The flow

```
Filling ──fill──▶ Full ──┬─ auction (24h) ──── winning bid ≥ majority minimum ──▶ FINALIZE
   ▲                     │        └─ no winning bid ─▶ back to Full
   │                     ├─ accept backer offer (majority) ─▶ LAST CALL (1h, outbiddable) ─▶ FINALIZE
   └── withdraw (resets votes; unburned Credits back) ──┘
FINALIZE = burn the 80 (via the vault) → Statement to the buyer → proceeds to depositors (pull) → points
```

1. **Filling.** Deposits and withdrawals work as today. Fees are unchanged: $2/Credit, or $1 each for 6+.
2. **Full.** Depositors vote a minimum price, the same majority rule as today. They also vote the print
   order (Design 1 in the Statements doc) and, later, layering choices. The arrangement is **frozen**
   when an auction or last call starts, so buyers know exactly what they're buying.
3. **Auction (pre-burn).** A 24h English auction for the Statement that will be made: 5% steps, 15-min
   anti-snipe, bids held by the contract, pull refunds.
   - **A winning bid at or above the minimum** leads to FINALIZE.
   - **No winning bid** sends the batch back to Full. Nothing is burned. Depositors can re-vote, accept a
     backer offer, or withdraw.
4. **Backer offers.** Anyone can post an offer for a batch: an amount of ETH for the whole batch, held by
   the contract. Offers can be posted while the batch fills, which signals demand. A backer can raise or
   withdraw an offer at any time **except** while it is in last call.
5. **Accept (majority).** Depositors vote to accept a specific offer: exact backer, exact amount, exact
   composition. When more than 40 of 80 slots back the same offer, **last call** starts.
6. **Last call (1 hour).** The accepted offer becomes the opening bid of a 1-hour auction. Anyone,
   including an outvoted depositor, can outbid it by 5%; anti-snipe applies. When it ends, the highest
   bid goes to FINALIZE.
7. **FINALIZE (atomic).** In one transaction:
   1. burn the batch's 80 Credits through the AssemblyVault;
   2. verify one new Statement arrived;
   3. deliver it to the buyer;
   4. book the proceeds for depositors (claimed pro-rata, pull);
   5. award points (2 per burned Credit).

   If any step fails, **everything unwinds** (§5): the buyer is refunded, the Credits stay, and the batch
   returns to Full.
8. **Exit.** While no auction or last call is live, a depositor of a Full batch can withdraw. The batch
   goes back to Filling, and every vote and acceptance for it is cleared (the composition changed).

## 3. Safety invariants (must hold always; each gets a handler invariant, and I1–I3 a formal proof)

| # | Invariant |
|---|---|
| I1 | Every Credit the pool holds belongs to exactly one depositor in exactly one unsold batch. A Credit leaves the pool only to its own depositor (withdraw) or burned inside FINALIZE of **its own** batch. |
| I2 | **Nothing burns** without a locked-in buyer: either a 24h-auction bid ≥ the majority minimum, or a majority-accepted offer after its full 1-hour last call. |
| I3 | Pool ETH ≥ Σ live offers + live high bids + pending refunds + unclaimed proceeds + fees owed. |
| I4 | A backer's escrow leaves only to (a) the backer, via withdraw or refund, or (b) that batch's depositors, via FINALIZE. Nobody else, ever. |
| I5 | An accepted sale pays **at least** the exact accepted amount. A backer can't cancel, lower or swap an offer once it is accepted (no bait-and-switch). |
| I6 | A failed burn never loses a Credit or a wei: a full unwind to the pre-FINALIZE state, and the buyer is refunded. |
| I7 | Neither owner can move Credits, bids, offers or proceeds, or pause any of it. |
| I8 | Votes and acceptances bind to a composition nonce. Any change to a batch's Credit set invalidates them. |
| I9 | Each batch finalizes at most once. Each Statement is delivered to exactly one buyer and backs exactly one batch. |

## 4. Threat model

| Attack | Defence |
|---|---|
| Backer bait-and-switch: lower or cancel the offer just as depositors accept | Accept names `(backer, amount, compositionNonce)` and reverts on any mismatch; in last call the offer is locked |
| Backer front-runs acceptance with a withdrawal | Acceptance fails cleanly (offer gone); no burn, no loss |
| Minority sold below its price | Majority rule (as today) plus the 1-hour last call, where anyone can outbid by 5% |
| Majority accepts a lowball offer from its own sock puppet | The last call lets anyone pay more; the site shows the OpenSea floor and the offer per Credit as a guide |
| Swapping Credits after acceptance to sell a different set | Composition nonce (I8); the arrangement is frozen at auction or last-call start; withdrawals blocked while live |
| Offer spam or dust offers | Minimum offer size and a per-batch cap on active offers; only the best few are shown; escrow makes spam cost capital |
| Griefing the burn (Jack's contract rejects, cap reached, gas) | FINALIZE runs as an all-or-nothing self-call; on revert the whole attempt is undone (§5) |
| Buyer is a contract that can't receive the NFT | Plain `transferFrom` delivery (no receiver hook), so a buyer can't block settlement (AR-9) |
| Reentrancy (buyer, backer, depositor, fee wallet, Statements) | `nonReentrant` on every entry point; pull payments; checks-effects-interactions; FINALIZE internals `onlySelf` |
| Price oracle manipulation | **No floor oracle on-chain.** Prices come only from bids, offers and votes. The floor is display-only. |
| Gas limits (80 depositors, many offers) | Pull claims; bounded offer list; award loop measured (≤ ~2.4M gas); no unbounded loops |
| Stuck money | With no sale, Credits stay withdrawable; offers and bids are always refundable; no batch can end holding unsold Statements |
| Owner abuse | No owner power over any of it (I7); fee constants only |

## 5. FINALIZE and the unwind

Custody depends on this being all-or-nothing.

- `settle(b)` (permissionless, `nonReentrant`) calls `this._finalize(b)` as an **external self-call**
  (`onlySelf`) inside `try/catch`.
- `_finalize` moves the batch's 80 Credits to the vault, calls the vault (which calls Jack's contract),
  checks the Statement, delivers it and books the proceeds.
- **If anything reverts, the whole self-call reverts,** including the Credit transfers to the vault. `settle` then
  catches it, refunds the buyer into `pendingReturns`, and returns the batch to Full with an `Unwound` event.
- **No partial state is possible.** A `try/catch` on the vault call alone would *not* be safe, because the
  Credit transfers made before it would persist. That is why the whole finalize must be the self-call.
- The vault keeps today's delta checks: only this batch's Credits are reachable, exactly one new Statement
  arrives, and nothing else moves.

## 6. What changes versus today

- **Removed:**
  - burn-before-sale;
  - the post-burn Statement auction;
  - the 30-day lowest-vote fallback (AR-10);
  - `unsoldAuctions`, `openedByFallback` and the treasury's `buyUnsold` path, along with their edge cases
    (CP-29..46);
  - `redeem` as a separate path: a sole 80-slot holder simply accepts their own offer, or a
    `burnToSelf` with no payment.
- **Kept:**
  - deposits, fees and the 25/75 split;
  - majority minimum-price voting;
  - the 24h auction mechanics;
  - pull payments;
  - the AssemblyVault;
  - SCREDIT points (awarded at burn).
- **Store:** keeps the SCREDIT auction of Statements it holds. The treasury can act as a **backer**
  (owner-triggered offers, same cap and 3-day raise delay), which is how it acquires Statements from now on.
- **Frontend:** a batch card shows the minimum-price vote, the best offers (with per-Credit and floor
  comparison), Accept, and a last-call countdown. Withdraw is visible and says it resets the batch's votes.

## 7. Open questions (answer from Jack's contract first)

- **S-1 / S-2:** the burn call and whether order or direction are parameters. These are fixed before the
  auction or last call.
- **Delivery:** can the Statement be minted straight to the buyer, or must it come to the vault/pool first?
  We keep the vault either way.
- **Cap and pause behaviour:** what makes his burn revert, so we can test every unwind path.
- **Layering:** "back a Statement with Credits" (the Statements doc, Design 3) fits the same sell-first
  pattern: a layer burns only when its buyer or backer is locked in.

## 8. Build and verification plan (ultra-safe gate)

1. Implement on a branch, with the new invariants I1–I9 as handler invariants from day one.
2. Write an attack test for every row of §4, with a PoC-style test that fails without the defence.
3. Prove I1–I3 formally (Halmos or similar) for the finalize and unwind paths.
4. Fork tests with real Credits and **Jack's real contract**:
   - every unwind cause;
   - gas under 2^24 for the worst case.
5. The end-to-end concept test and the 100-burner rehearsal rewritten for sell-first; real-Chrome UI flows.
6. A full internal audit (6 blind specialists plus an adversarial verifier), then Sepolia with real
   users, then an **external audit** of the final code before any mainnet deploy.
