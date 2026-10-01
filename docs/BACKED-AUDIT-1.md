# BackedPool internal audit #1: triage

**Scope:** `src/BackedPool.sol` (new, sell-first backed auctions) against `docs/SELL-FIRST-DESIGN.md`.
**Method:** a blind adversarial reviewer worked in its own copy, and every finding came with a Foundry PoC.
The PoCs were re-run against the fixed contract: each fixed finding's PoC now fails, meaning the exploit no longer works.
**Result:** no Critical or High. 2 Medium, 2 Low, 3 Info.

| # | Finding | Status | Fix / regression test |
|---|---|---|---|
| M-1 | 75% of deposit fees reach CreditStore, whose only outflow (`buyUnsold`) calls CreditPool-only functions, so the treasury is stuck with BackedPool | **Fixed: under review** | New `src/BackedStore.sol`: CreditStore unchanged except the treasury section. `backBatch(b, amount, expectedTotal)` is owner-only and Full-only, never backs a sole-holder batch, keeps the per-batch total ≤ `maxTreasuryBid` (raises still take 3 days) and ≤ the depositors' majority minimum, and pins the exact total. Also `unbackBatch`, and `collectRefund` (anyone). CreditStore stays byte-identical for CreditPool. Tests: `test/BackedStore.t.sol` (13). Its own blind audit is running.
| M-2 | Stale backings (posted while filling) could squat all 10 backer places and block any backing below their size, at no cost | Fixed | `_evictable`: stale backings are displaced first; a newcomer only has to beat the lowest *current* backing. `test_StaleBackingsEvictedFirst` |
| L-1 | `startAuction` pinned the exact opening bid and minimum, so a 1-wei top-up or a vote flip could front-run and block every start | Fixed | `startAuction(b, minOpening)`: the opening may be higher than the caller saw (it only helps depositors); the minimum is the depositors' own vote and isn't pinned. `test_StartOpeningAtLeastWhatCallerSaw`, `test_StartRevertsIfOpeningDropped` |
| L-2 | A pool built with a store linked elsewhere would unwind every sale | Fixed | `_requireLinked()` in `startAuction` and `redeem` (store's `pool()` must be this pool). `test_UnlinkedStoreRefused` |
| Info-1 | Votes survived a composition change (design §2.8 says they're cleared) | Fixed | Reopening a Full batch clears every vote. `test_ReopenClearsVotes`. Design doc updated: no new backings during auction/decide (as built). |
| Info-2 | `claim` rounding leaves up to (depositors − 1) wei per batch | Accepted | Same as the audited CreditPool; dust < 80 wei. |
| Info-3 | Worst case (80 depositors, real Credits) uses 7.40M of the 12M finalize budget; an expensive real Statement mint (>~4.5M) would make every sale unwind (nothing lost) | Open: tracked | Re-measure against Jack's real Statements contract (checklist S-1..S-8) before deploy; raise `FINALIZE_GAS` if needed (the tx cap allows ≈16.4M). |

**Checked and believed sound (by the reviewer, with tests):**
- The gas guard and the 63/64 rule: the minimum `settle` gas still gives the assembler its full budget.
- The unwind is complete, and leftover accept tallies can't be reused.
- `finalizeSale` is only callable by the pool itself, and re-entry is blocked.
- The accept tally can't be manipulated.
- Stale or foreign backings can't open an auction.
- ETH accounting: every wei is credited exactly once.
- Withdraw-from-Full and `depositInto` edge cases.
- Delivery can't be blocked.

**Suites after fixes:** 201 local tests and 17 mainnet fork tests pass, and the invariant runs reach sales, unwinds and expiries.

---

# BackedStore internal audit (treasury backing)

**Scope:** `src/BackedStore.sol`, which is CreditStore with its treasury section replaced, and how it interacts with BackedPool.
**Method:** a blind adversarial reviewer, with a PoC for every claim (8 new tests, plus the existing 13 still passing).
**Result:** no Critical, High, Medium or Low findings. One informational item.

| # | Finding | Status |
|---|---|---|
| Info-1 | "Never above the depositors' minimum" is checked when the treasury backs, not when the auction starts. If depositors lower their minimum afterwards, the treasury's earlier (pinned, capped) backing can still open the auction above the new minimum. No extraction is possible: the treasury pays at most the amount the owner pinned, within the cap. At the original vote the batch would have sold at that price anyway. | Accepted, documented. The rule reads "checked at backing time". The owner's panel on the site warns when the minimum drops below the treasury's backing, so the owner can return it and back again. |

**Checked and believed sound, each with a passing test:**
- A sole holder can't inherit a treasury backing.
- The treasury is never exposed beyond the cap on one batch across rounds.
- A leftover backing is recoverable after another buyer wins.
- Eviction griefing loses nothing: `collectRefund` recovers it all.
- Re-entry during the bid-fee sweep keeps `treasuryBalance` and `bidFees` exact.
- Forced ETH only adds to the treasury.
- The cap and its 3-day delay also apply to top-ups.
- Every pool state ends with the treasury's ETH recoverable or its Statement in the store.
- The owner can't pull treasury ETH out except by backing a batch.

---

# Option-1 change audit (auctions open only at or above the depositors' price)

**Scope:** commit `d2813e4` versus `dcbe3ba`: the `startAuction` price gate, and the removal of Decide, `acceptBid` and `expire`. Also how it interacts with BackedStore.

**Method:** the `creditpool-audit` skill's diff review. Three blind specialists (state machine, auction game theory, access control) each read their public checklists and wrote Foundry PoCs in isolated copies. Every finding was then reproduced against the repo; the new tests fail on the old code and pass on the fix.

**Result:** no Critical or High.

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | Reopening a full batch cleared every depositor's vote. A 1-slot depositor could `withdraw` + `depositInto` for one deposit fee and erase a 41+ slot price, again and again, blocking every start, since option 1 needs a price. Found independently by two specialists. | Medium | **Fixed.** Other depositors' votes persist; only a depositor who leaves entirely loses theirs. This supersedes the earlier Info-1 "clear all votes" fix: a start still needs a backing ≥ the live majority price. Tests: `test_OneSlotCantWipeQuorum`, `test_ReopenKeepsOtherVotes` (both fail on `d2813e4`). |
| 2 | The treasury could back while no price existed, skipping the "≤ depositors' price" cap. Its backing could then open above a lower price voted later. | Low | **Fixed.** `backBatch` reverts `NoMinimum`, and the owner panel waits for a price. Test: `test_NoTreasuryBackingWithoutPrice`. |
| 3 | A treasury backing sitting exactly at the price couldn't be re-confirmed after the Credits changed: any top-up exceeds the price. | Low | **Fixed.** `BackedPool.reconfirm(b)` refreshes a backing without ETH, for any backer. `BackedStore.reconfirmBatch(b)` (owner) applies the same price rule. Tests: `test_TreasuryReconfirmsAtExactPrice`, `test_TreasuryReconfirmRespectsPrice`, `test_ReconfirmFillingBacking`. |
| 4 | A backing posted while the batch fills is always stale once it's Full: the filling deposit bumps the nonce. | Info | Accepted. It's now one free `reconfirm` click, and the site shows the button. |
| 5 | A stale comment said acceptances bind to `round`. | Info | Fixed. |
| 6 | `app/flow.js` and `app/preview.js` (mock-data prototypes, no contract calls) still show the old decide step. | Info | Doc drift; prototypes only. |

**Checked and sound:**
- No state can get stuck. Every Auction has a price, and its high bid meets it.
- The unwind is the only non-sale exit from an Auction, and the majority can escape a failing-finalize loop by clearing its votes.
- No path forces a sale below the majority's price. A vote raised in the same block as a start makes the start revert.
- Enum ordinals are consistent: BackedStore `state == 1`, and the site's `BACKED_STATES`.
- Access guards are consistent after the removal.
- Owner powers are unchanged.
- ETH accounting holds without `expire`.
