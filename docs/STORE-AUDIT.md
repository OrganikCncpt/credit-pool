# Store review: fee change + `CreditStore`

**Date:** 2026-09-28. **Scope:** `git diff audit-prep-2..63d32c9 -- src/ script/ app/`:
- the tiered deposit fee
- the removed sale fee
- the 25/75 fee split
- `unsoldAuctions`
- the new `src/CreditStore.sol` (SCREDIT points, treasury, SCREDIT store auction)
- the deploy scripts and frontend changes

**Method:** a diff review with the `creditpool-audit` skill.
- Five blind specialists covered ETH custody and reentrancy, fees and points math, auction and treasury game theory, access control and deploy, and the frontend.
- Each wrote Foundry PoCs in an isolated copy of the repo.
- Findings were de-duplicated by root cause, fixed, and each fix got a regression test.
- A separate adversarial verifier then tried to break every fix and looked for regressions. It found one (R1) and one incomplete fix, and both were fixed.
- **Not a substitute for an external audit.** `CreditStore` and the pool's fee changes have not been externally audited.

## Findings

| ID | Sev | Finding | Found by | Fix | Test |
|---|---|---|---|---|---|
| CP-29 | Medium | `buyUnsold` read the reserve at execution time and could join a live auction. Depositors (a >40-slot majority, or anyone after 30 days) front-ran it so the treasury paid up to the cap, then claimed it. | 4 of 5 specialists; PoCs by 3 | `buyUnsold(b, maxAmount)` pays only `currentReserve` (the majority minimum) and reverts `PriceMoved` above the owner's limit. It opens the auction itself via `startAuctionAt`, or bids into a live no-bid auction only if that auction opened at the same minimum. | `test_FrontRunRaisingReserveReverts`, `test_RestartedAuctionAtHigherMinimumReverts` |
| CP-31 | Medium (trust) | The owner could raise the cap instantly and route the treasury to a batch they control. | game theory | Raising `maxTreasuryBid` takes 3 days to apply; lowering is immediate. The initial cap is set in the constructor (0 on mainnet). Residual trust is documented (AR-11). | `test_CapRaiseIsDelayed`, verifier fuzz |
| CP-32 | Low-Med | SCREDIT could be farmed through deposit→withdraw loops at $0.50/point with nothing pooled. A farmer outbid an honest 40-Credit depositor for a store Statement. | math, access, frontend | Points are awarded only when a batch fills, 2 × slots per depositor. | `test_DepositWithdrawLoopEarnsNoPoints`, `test_PointsAreTwoPerCreditWhenBatchFills` |
| CP-30 | Low | The treasury could open at 1 wei via the 30-day lowest-vote fallback, or with no votes. | game theory, frontend | Covered by CP-29: `currentReserve` needs quorum, and `startAuctionAt` rejects the fallback minimum. | `test_NeverBuysAtThirtyDayLowestVote`, `test_NoVotesNoPurchase` |
| CP-33 | Low | `setPool` accepted a pool that doesn't point back, permanently bricking deposits and sweeps. | 3 specialists | `setPool` requires `pool.store() == this`. | `test_StoreRefusesWrongPool` |
| CP-38 | Low-Med | *Regression from the first CP-29 fix:* anyone could lock the treasury out by restarting the auction first. | verifier (R1) | Also bids into a live auction that has no bids and opened at the majority minimum. | `test_RestartedAuctionStillBuyable` |
| CP-34, CP-39 | Info | `feeRecipient` could be the store (bid-fee sweep DoS). | access, verifier | Rejected in `setFeeRecipient` and in the constructor. | `test_FeeRecipientCantBeTheStore`, `test_ConstructorRejectsStoreAsFeeRecipient` |
| CP-40 | Low | After 30 days, one low minority vote blocked all treasury purchases of that batch. | owner request (was AR-16) | The treasury opens the auction, possibly at the fallback minimum, but always bids the majority price, which is never lower. | `test_After30DaysPaysMajorityNotLowestVote`, `test_LiveAuctionAboveMajorityReverts` |
| CP-41 | Low | A `feeRecipient` that rejects ETH paused sweeps, including the treasury's share. | owner request (was AR-13) | The treasury's 75% always goes out; the platform's 25% waits in `platformFeesOwed` and pays on the next sweep. | `test_Attack_RevertingTreasuryOnlyFreezesFees` |
| CP-42 | Low | A fee wallet reverting with a ~3 MB payload stalled the treasury's sweep, because the returndata was copied. | 2nd verifier | The call no longer copies returndata; a `PlatformFeesHeld` event is emitted. | `test_ReturndataBombCantStallTreasury` (fails on 542dccd) |
| CP-43 | Low | Votes raised after a live auction opened pushed the treasury's bid up. | 2nd verifier | The treasury pays the opening price. Only a 30-day fallback opening gets the majority price. | `test_VoteRaiseAfterOpenDoesntRaiseTreasuryBid` (fails on 542dccd) |
| CP-35 | Info | Escrowed bid points had no events; Σ balances < totalSupply during bids. | access | Escrow moves points to the store's own balance with `Transfer` events. | fuzz `testFuzz_PointsConserved` |
| CP-36 | Low (UI) | The leader couldn't raise their own store bid. | frontend | Held points count toward the raise. | real-Chrome run |
| CP-37 | Low (UI) | A click on Deposit right after Approve was refused while the page redrew. | found during UI re-test | The send lock is released once the tx is final. | real-Chrome run |

## Accepted residuals (owner decisions / documented)

- **AR-11: owner trust in the treasury.** The owner picks which unsold batches to buy, up to the cap each. It only ever pays a majority-voted minimum, only places the first bid, and cap raises are visible 3 days ahead. A multisig owner is expected.
- **AR-12: non-monotonic fee at the bulk boundary.** 5 Credits cost $10 and 6 cost $6. This is the owner's pricing, and the UI suggests depositing 6+.
- **AR-14: the fill transaction pays for the points award.** Measured worst cases:
  - 2.35–2.72M gas for 80 depositors;
  - 11.8–13.1M gas for a 100-Credit deposit, under the 16.77M cap.
- **AR-15: a batch that dissolves keeps its points.** The cost is the same as honest depositors pay, the Credits are locked for 14+ days, and anyone can `assemble`.
- **AR-17: points can stay escrowed if a listed Statement leaves the store by external means.** This depends on the real Statements contract.

## Verified safe (highlights)

- **Pool↔store calls:** none re-enter a held guard.
- **Treasury ETH:** leaves only through `buyUnsold`. `treasuryBalance()` can't underflow, and bid fees aren't counted as treasury.
- **The 25/75 split:** sums exactly, with no stuck wei.
- **Fees:** can't round to 0 (the fallback applies).
- **Store auction:**
  - outbid points come straight back;
  - self-raise works;
  - settling twice, bidding on an unlisted Statement, and bidding after the end all revert;
  - excess-fee refunds are reentrancy-safe.
- **Store owner powers:** the owner cannot take users' ETH, points or NFTs.
- **Frontend:**
  - fee and chunk math is checked for n = 1..2000;
  - every ABI matches the contracts;
  - there are no HTML-injection sinks;
  - the demo modes are gated to chain 31337.

## Test gate after fixes

- 148 local tests pass.
- 14 mainnet-fork tests pass, including 4 store scenarios on real Credits and the real Chainlink feed (`test/StoreFork.t.sol`).
- Fork tests with real Credits pass.
- The full local rehearsal passed: 100 burners, the store flow, and real-Chrome UI checks.
