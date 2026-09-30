# External audit #2: triage

**Report scope:** tag `audit-prep-3`, commit `d92be83` (767 nSLOC: `CreditPool`, `CreditStore`,
`AssemblyVault`, `Deploy.s.sol`).
**Report counts:** 0 Critical · 1 High · 3 Medium · 9 Low · 14 Informational.

**Method:** same as audit #1.
- Every actionable finding was reproduced with a Foundry test that asserts the **correct** behaviour.
- Each test was run against the untouched `audit-prep-3` contracts in a separate copy. A finding counts as
  real only if its test fails there.
- Each fix was then judged separately from the proposed fix.
- Regression tests: `test/ExternalAudit2.t.sol`.

**Result:** 6 reproduced and fixed, 1 hardened (valid as API design), the rest confirmed as design or
already accepted (with docs corrected where the report showed our docs overstated a guarantee).

## Findings

| # | Finding (report severity) | Reproduced on audited code | Verdict | Resolution |
|---|---|---|---|---|
| H | `currentReserve` returns the pivotal voter's ask; a 1-slot vote made the treasury's price 400× | **Yes**: `test_Repro_H_PivotalVoteSetsQuorumPrice`, `test_Fix_TreasuryRejectsPivotalMinorityPrice` fails on audited code | **Valid, re-scoped to Medium.** The math matches its definition: at 4 ETH, the 0.01 voter and the 4 ETH voter both accept, so 41 slots do. The real flaw: non-voters count as "not yet", so when a majority abstains a tiny pivotal voter sets the quorum price, and the treasury trusted it as a price to *pay*. The proposed fix (voters strictly below the price must exceed 40 slots) would break the normal case: a 41-slot voter could never set a price. | **Fixed (CP-52):** new `votedMedian(b)` (slot-weighted median of votes actually cast). `buyUnsold` reverts `PivotalMinority` unless the price equals it. With good turnout the two agree; an abstention-driven outlier can't become the treasury's price. |
| M1 | `buyUnsold` doesn't pin the price; a raise up to the owner's ceiling lands | **Partly**: with `maxAmount` = the reviewed price the audited code already reverted (`test_Fix_BuyUnsoldPinsExactPrice` passes there); it overpays only if the owner passes a looser ceiling | **Valid as API hardening.** Also correct that our docs said "opens via `startAuctionAt`", which was stale after CP-40. | **Fixed (CP-53):** the parameter is now `expectedAmount`, and **any** difference reverts `PriceMoved`. Docs corrected. "Minimum remaining time" for joining a live auction: owner-timed; documented, since the 15-minute anti-snipe applies. |
| M2 | Treasury can't defend a batch's first auction, or a fallback auction without quorum | Behaviour confirmed | **By design.** The treasury is a buyer of last resort at a *majority-backed* price, never a guarantor of every batch. A no-quorum 30-day fallback sale is AR-10 (owner decision H-03, option 1). **Sell-first** (`docs/SELL-FIRST-DESIGN.md`) removes both the fallback and this path. | Documented (AR-22). |
| M3 | A 1-wei winning bid makes every `claim` round to zero | **Yes**: `test_Fix_FirstBidAtLeastOneWeiPerSlot` fails on audited code | **Valid.** | **Fixed (CP-54):** every auction's first bid is at least 80 wei (1 wei per slot), so no share can round to 0. |
| L1 | Store owner lists a treasury Statement at reserve 0 and wins it back for 1 point | Behaviour confirmed | **Owner trust (AR-11).** Blocking `owner()` from bidding is cosmetic, since a second wallet defeats it. The real gap was our docs saying the owner "cannot take Statements". | **Docs corrected:** treasury-held Statements are under owner discretion within AR-11. Listing floors are an operator policy; revisit in sell-first. |
| L2 | `buyUnsold` sole-holder guard skipped if the holder opened their own auction | **Yes**: `test_Fix_TreasuryNeverBuysFromSoleHolder` fails on audited code | **Valid.** | **Fixed (CP-55):** explicit `depositors == 1 → NotDepositor` check in `buyUnsold`, on every branch. |
| L3 | Constructor doesn't check distinct dependencies or bound `assemblyOpensAt` | **Yes**: `test_Fix_ConstructorRejectsMiswiring` fails on audited code | **Valid** (operator-error class with permanent consequences). | **Fixed (CP-56):** `BadConfig` for duplicate Credits/Statements/assembler/feed/store addresses and for `assemblyOpensAt` > now + 365 days. |
| L4 | One 1-slot depositor can dissolve a Full batch after the 14-day escape delay | Behaviour confirmed | **By design** (the escape hatch exists for batches that *can't* be assembled; `assemble` is permissionless for all 14 days). Sell-first replaces the escape hatch with free, unburned withdrawal. | Documented (AR-23). |
| L5 | The 30-day fallback floor is permanent and controlled by the lowest voter | Behaviour confirmed | **Variant of AR-10** (owner decision). | Documented under AR-10; removed in sell-first. |
| L6 | Unbounded anti-snipe extensions delay settlement | Behaviour confirmed | **Accepted.** Standard English-auction behaviour; each extension costs a +5% bid and raises depositors' proceeds. | Documented (AR-24). |
| L7 | `_liveFee` reverts on malformed feed return data (`try/catch` can't catch a failed decode) | **Yes**: `test_Fix_MalformedFeedFallsBack` fails on audited code | **Valid.** | **Fixed (CP-57):** low-level `staticcall`; a revert or fewer than 160 bytes of return data means untrusted, so the fallback is used. |
| L8 | `settle` has no recovery if Statement delivery fails | n/a (needs the real Statements contract) | **Valid, Statements-dependent.** Already on the OK list. Sell-first's atomic finalize/unwind handles it. | OK-12 added; S-8/S-4 checks. |

## Informational (14)

| # | Item | Resolution |
|---|---|---|
| 1 | Dead `votedSlots` local in `currentReserve` | Now used: `votedMedian` (CP-52) |
| 2 | `award` doesn't check array lengths | Added `LengthMismatch` (Solidity already reverted on out-of-bounds reads, so this makes it explicit) |
| 3 | Store hard-codes `BatchState` ordinals | Pinned by `test_Fix_StoreStateOrdinalsMatchPool` |
| 4 | Docs say CP-29 uses `startAuctionAt` | Corrected in `STORE-AUDIT.md` and the baseline |
| 5 | Comments say points are awarded "when a batch fills" | Corrected: awarded on assembly (CP-44) |
| 6 | `sweepBidFees` fails silently and hard-codes the gas | `BidFeesHeld` event; `FEE_CALL_GAS` constant |
| 7 | `auctions[b]` stays populated after a sale | Accepted: read `batchInfo` state; no in-scope reader |
| 8 | `unsoldAuctions` never resets | By design; gates `buyUnsold` together with the current state checks |
| 9 | Fee recipient could be the pool or vault | Rejected in the constructor and `setFeeRecipient` (`test_Fix_FeeRecipientCantBePoolOrVault`) |
| 10 | Oracle band not anchored to the deploy price | Accepted: the band only catches broken feeds; the fee is $1–2 |
| 11 | `fallbackFeeWei` frozen forever | Known (M-01 decision) |
| 12 | Deploy script feed check can underflow and uses a 1-day tolerance | Fixed: `updatedAt <= now`, and fresh within 70 minutes |
| 13 | Two independent two-step ownership handoffs | Documented in the launch checklist: accept both; the script logs both pending owners |
| 14 | No length cap on `withdraw` arrays | Self-griefing only, as AR-6 |

## Test gate after fixes

- **Local:** 164 tests pass, including 11 in `ExternalAudit2.t.sol`.
- **Mainnet fork:** 17 tests pass.
- **End-to-end:** 38/38 on a fresh mainnet fork.
- **Mainnet deploy dry run:** succeeds against the live Chainlink feed.
