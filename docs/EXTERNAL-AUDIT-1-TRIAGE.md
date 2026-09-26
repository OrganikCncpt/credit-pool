# External audit #1: triage

**Report scope:** tag `audit-prep-1`, commit `30d172a`, 477 nSLOC (`CreditPool.sol`,
`AssemblyVault.sol`, `IStatementAssembler.sol`, `Deploy.s.sol`).
**Report counts:** 0 Critical · 3 High · 1 Medium · 5 Low · 6 Informational.

**Method:** every finding was reproduced with a Foundry test that asserts the *correct*
behavior and was run against the audited code first; a finding is accepted only if that test
fails there. Each proposed fix was then evaluated separately from its finding. Regression tests
live in `test/ExternalAudit1.t.sol`.

| ID | Finding | Reproduced on audited code | Verdict | Resolution |
|---|---|---|---|---|
| **H-01** | `AssemblyVault` used absolute Credit-balance checks; one Credit plain-transferred to the vault blocks every assembly forever | **Yes** (`test_H01_DonatedCreditToVaultDoesNotBrickAssembly` reverted `CreditsNotBurned`) | **Valid, High** | **Fixed** as recommended: balance measured at entry, exit must equal entry − batch size; per-id burn check kept. Verified the fix keeps the earlier swap attack (fused audit #2 N-1) closed even with a stray present (`test_H01_FixStillCatchesSwapWithStrayPresent`). |
| **H-02** | A sole 80-slot holder's own reserve vote let any third party start an auction, closing their free redeem | **Yes** (`test_H02_StrangerCannotForceSoleHolderToAuction`) | **Valid.** It broke documented guarantee G2 (CP-12 closed only the 30-day path) | **Fixed, differently from the recommendation.** The report suggested reverting every auction start on a single-depositor batch, which would also stop the holder from *choosing* to auction. Instead, only the sole holder may start it (`NotDepositor` for anyone else). Both behaviors tested (`test_H02_SoleHolderCanStillChooseAuction`). |
| **H-03** | The 30-day fallback minimum (`lowestVote`) is unweighted by slots | Behavior confirmed | **By design (owner decision, option 1).** The fallback exists so a majority can't block a sale forever (CP-4, CP-21); weighting it reintroduces that trap. Every depositor can outbid during the 24h auction. | **Accepted residual AR-10.** Frontend now warns depositors during the last 7 days before the fallback applies |
| **M-01** | Immutable price feed; a dead feed blocks deposits permanently | Behavior confirmed | Valid (previously disclosed as DI-1); owner chose to fix | **Fixed**: `fallbackFeeWei`, frozen at deploy as $1 in ETH, is used whenever the feed is stale, future-dated, non-positive or not answering; `depositFee()` never reverts; `feeUsesFallback()` view; deploy refuses an unhealthy feed. No admin lever added. Tests: `test_M01_*`, `test_StaleOracleUsesFallbackFee` |
| L-01 | No `minAnswer`/`maxAnswer` check | n/a | Accepted: bounds are not used by the current ETH/USD aggregator design; worst case is a mispriced $1 fee | No change |
| **L-02** | Feed `decimals()` re-read every call | n/a | Valid hygiene | **Fixed**: read once at construction (`_feedDecimals`) |
| **L-03** | Future-dated round underflows to `Panic(0x11)` instead of `StaleOracle()` | **Yes** (`test_L03_FutureDatedRoundIsStaleOracle`) | Valid, Low | **Fixed** as recommended |
| **L-04** | Constructor doesn't check dependencies are contracts | **Yes** (`test_L04_ConstructorRejectsNonContracts`) | Valid, Low | **Fixed**: `NotAContract` for credits, statements, assembler, feed; checked before anything is read |
| L-05 | `_burned` treats any `ownerOf` revert (incl. out-of-gas) as burned | n/a | Accepted for now: needs an adversarial assembler; the transaction must still complete a Statement transfer afterwards, so starving only the inner call isn't practical. Revisit with the real Statements contract (OK-3) | No change |
| I-01 | `settle` has no recovery if Statements refuses a transfer | n/a | Already disclosed (OK-5) | No change |
| I-02, I-02b, I-03 | Assembler returndata size, deploy default for `ASSEMBLER`, no ERC-165 | n/a | Contingent on the unpublished Statements contract (OK-1) | Revisit when published |
| I-04 | Deployer owns until the multisig accepts | n/a | Inherent to two-step ownership; owner can only change the fee recipient | No change |
| **I-05** | Burned Credits keep reporting a depositor and batch | **Yes** (`test_I05_BurnedCreditsClearedFromBookkeeping`) | Valid, view accuracy | **Fixed**: cleared when moved to the vault |
| I-06 | Deposits continue even if assembly is broken | n/a | Consistent with the no-pause design; H-01's fix removes the example cause | No change |

**Test gate after fixes:** 110/110 local tests (7 new), both custody invariant suites, and the
mainnet-fork tests with real Credits.

## Decisions for the owner

**H-03: the 30-day fallback. Decided: option 1 (keep).** If a Statement is unsold 30 days after assembly, the
minimum becomes the lowest price any depositor voted (0 if nobody voted), and any depositor or
buyer can start the auction; everyone can outbid for 24 hours. Options:
1. **Keep (current).** Nobody can trap the Statement forever; the cost is that one low vote sets the floor after 30 days, so larger holders must watch and bid if they value it more.
2. **Slot-weighted fallback** (lowest price accepted by more than half of the *voted* slots). Respects a majority's price, but a majority can again block a sale indefinitely by voting an unreachable price: the problem CP-4 fixed.
3. **Middle ground:** after 30 days use option 2, after e.g. 90 days fall back to option 1.

**M-01: the price feed. Decided: add a fixed fallback fee** (frozen at deploy, not adjustable).
