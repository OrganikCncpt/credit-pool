> **Status (2026-09-24, after this report):** N1-N7, N9, N10 fixed, plus the custody deep dive's
> assembler-approval hardening. N8 addressed by the custody invariants in `test/custody/`.
> Details: `.claude/skills/creditpool-audit/references/creditpool-known-state.md` (CP-8..CP-16).
> Test gate: 89/89 local tests + 3/3 mainnet-fork tests passing.

# Credit Pool fused audit (2026-09-24)

**Scope:** src/CreditPool.sol, script/Deploy.s.sol, app/, test/.
**How it was run:** 10 specialists reviewed the code without seeing the baseline: access-guard, state-machine, eth-extcall, erc721, precision, oracle-time, auction-game, dos-gas, deploy-integration and frontend. Checklist sources were the evm-audit checklists (access-control, erc721, precision-math, oracles, dos), scv, and state-invariant-detection.
**Verification:** Adversarial verification confirmed 3 findings, all downgraded from medium to low. One of them has a passing Foundry PoC for the minority-reserve attack. I then merged the findings by root cause and re-checked each against the current code.
**Baseline:** Classified against creditpool-known-state.md and the README's "Security review" section.
**Standards check:** I also compared the code against the ethskills/security, solskill/solidity and OZ develop-secure-contracts skills.

## Does the baseline still match the code?
- **Still matches:** CP-1, CP-2 and CP-4 through CP-7 are all present in the code. So are design invariants 1–8, the nonReentrant claim, and the ~440-line size.
- **Mismatches (each one is a finding):**
  1. CP-3 is only partly fixed (N1).
  2. Design invariant 5 ("majority rules pricing") and AR-1 are wrong. The median is taken over votes cast, so a minority of 21–40 slots can set the reserve (N2).
  3. The "proven fact" that slots sum to filled for every batch is false for Dissolved batches. It only holds because the fuzz handler never exercises escape or auctions (N8).
  4. Design invariant 1 says the fee recipient is always non-zero, but the constructor accepts address(0) (N5).

## New findings

**N1 [LOW] The CP-3 fix is incomplete: the Statement id is not tied to a single batch.** src/CreditPool.sol:242-248. Found by erc721 and deploy-integration.
- **What happens:** `sid = _receivedStatement ? _receivedStatementId : returnedId`, and the only post-check is `balanceOf == held+1 && ownerOf(sid)==pool`.
  - (a) If Statements mints with plain `_mint` (no callback) and the assembler returns an id the pool already holds (say #5 from batch 3) while a new #9 arrives, both checks pass. Batch 4 is then recorded against #5 and #9 is orphaned. Whichever batch settles or redeems second reverts, which strands its bid or Statement.
  - (b) If the real Statements gives control to the caller mid-call (the mint-to-tx.origin / 7702 case in OK-3), the caller can push an older Statement Y through the hook. The pool records the last id it received (Y) and the caller keeps the new X.
- **Why it matters:** The code comment at L244-245 claims this case is blocked. test_Fixed_AssemblerCannotDoubleAssign only covers the case where no Statement arrives at all.
- **Fix:**
  - Keep a `mapping(uint256=>bool) statementAssigned` and revert on reuse.
  - Revert on a second receipt within one assemble call.
  - When a receipt happened, require `returnedId == _receivedStatementId`.

**N2 [LOW, downgraded from MED; PoC passes] A minority of 21–40 slots can set the reserve because the first vote tally to reach quorum is locked in.** L281-326. Found by auction-game.
- **What happens:** `currentReserve` takes the median of votes cast, and `startAuction` is permissionless. An attacker with 25 slots waits until 20 honest slots have voted 10 ETH. In one transaction they vote 1 wei and start the auction. The median over 45 voted slots is 1 wei.
- **Why it matters:** This contradicts design invariant 5 and AR-1, which assume only a majority can do this. Harm needs a thin market, because the minority can still outbid.
- **Fix (any one):**
  - Require a minimum delay after the last reserve change before an auction can start.
  - Compute the median over all 80 slots, treating non-voters as abstaining high.
  - Add a voting window.

**N3 [LOW, downgraded from MED] Front-running a sole 80-Credit deposit blocks redemption.** L151-182 and L259-266. Found by oracle-time and auction-game.
- **What happens:** An attacker deposits 1 Credit ahead of the whale's 80. The whale ends up with 79 slots in batch N plus 1 in N+1. Anyone can then call `assemble(N)` immediately, so `redeem` is permanently out of reach. The whale must win an auction and pay the 1% fee. This is griefing, not theft.
- **Why it matters:** The contract header and README promise fee-free redemption, and there is no way to guarantee it. Design invariant 3 covers batch composition but not this.
- **Fix:** Add an `expectedBatchId` argument to deposit, or a `requireFreshBatch` flag.

**N4 [LOW] After 30 days, anyone can front-run a sole holder's redeem with a no-reserve auction.** L284. Found by dos-gas.
- **What happens:** This is a side effect of CP-4. `startAuction` puts the batch into Auction state, so `redeem` reverts. The sole holder must then outbid within the 24h window and loses 1%.
- **Fix:** Skip the no-reserve path when `depositors.length == 1`.

**N5 [LOW] The constructor accepts feeRecipient = 0, and the deploy script has no sanity checks.** CreditPool.sol:133 and script/Deploy.s.sol:14-29. Found by deploy-integration.
- **What happens:** Because `sweepFees` is permissionless, fees sent to address(0) are burned before the owner can fix the recipient.
- **Other gaps:** The script has no `block.chainid == 1` check and no feed `decimals()` or freshness check. Ownership stays with the deployer EOA and is never handed to a multisig. The `ASSEMBLY_OPENS_AT` default of `now` is already OK-4.
- **Fix:** Add the zero-address check to the constructor and the checks above to the script, then transfer ownership to a multisig.

**N6 [LOW] The "Start auction @ X" confirmation shows a reserve the transaction does not enforce.** app/app.js:661-666. Found by frontend.
- **What happens:** Votes can change between when the page renders and when the transaction lands, so the auction can start at a different reserve than the one confirmed. This is irreversible.
- **Fix:** Re-read and simulate right before sending, or add a `startAuction(b, expectedReserve)` parameter.

**N7 [LOW] Deposit and other actions can be sent twice.** app/app.js:451-473 and 289-305. Found by frontend.
- **What happens:** Nothing blocks a second click while a transaction is in flight. A double-click produces two identical wallet prompts, and the second transaction reverts at the user's gas cost.
- **Fix:** Disable the button and keep a per-action in-flight flag.

**N8 [INFO] Dissolved batches keep a stale creditIds array, and the invariant suite never tests escape or auctions.** L205, L407; test/Invariant.t.sol:97-108. Found by state-machine.
- **What happens:** After dissolution, batchInfo still reports `filled == 80` while the sum of slots is 0.
- **Coverage gap:** The handler never warps time and never calls setReserve, startAuction, bid, settle, claim or redeem. So the transitions Full→Dissolved, Assembled→Auction→(Assembled|Settled) and →Redeemed are never fuzzed.

**N9 [INFO] Bids under 20 wei need no increment (synthesis).** L332-335.
- **What happens:** `highBid * 500 / 10000` rounds to 0, so an equal 1-wei re-bid is accepted and extends the auction by 15 minutes. This is left over after CP-6.
- **Impact and fix:** Anyone can end the loop by bidding 20 wei or more. The fix is to require `minBid > highBid`.

**N10 [INFO] Gaps from the standards check.**
- setFeeRecipient, sweepFees and withdrawRefund emit no events.
- There is no CI and no Slither or Aderyn run.
- Deploy.s.sol is never exercised by any test, and there is no fork test of the deployed state.
- Some checks still use `require` strings instead of custom errors.

## Everything else by classification
| Finding | Specialists | Class |
|---|---|---|
| Assembler gets approval over all pool Credits, with no check on which Credits were burned (L236) | access-guard, eth-extcall, erc721, deploy-integration | ACCEPTED-RESIDUAL AR-3 / design invariant 6. Cheap hardening worth adding: require `credits.balanceOf(pool)` to drop by exactly 80, matching CP-3's own assumption that the assembler may be buggy |
| Claim rounding leaves under 80 wei of dust per batch (L374) | eth-extcall, precision | ACCEPTED-RESIDUAL AR-2 |
| Immutable Chainlink feed with no fallback stops deposits if it dies (L140) | oracle-time, dos-gas | DESIGN-INVARIANT (design invariant 1). Withdrawals still work |
| viem loaded from a CDN with no integrity check and no CSP (app.js:3) | frontend | ACCEPTED-RESIDUAL AR-5. Also add a CSP when self-hosting before launch |
| Placeholder assembler interface, mint-to-tx.origin, ASSEMBLY_OPENS_AT default (parts of N1 and N5) | deploy-integration, erc721 | OPEN-KNOWN OK-1, OK-3, OK-4 |

**False positives:** 0. Nothing the specialists reported was contradicted by the code.

**Standards check:** The contract meets the core checklist items: Chainlink staleness check, nonReentrant, pull payments, OZ Ownable. It falls short on events for admin and fund actions, zero-address validation in the constructor, stateful invariants that are kept in sync with the code (FREI-PI style), a deploy script covered by tests, and CI with static analysis.

**Verdict: fix a few small issues first.** Nothing is critical, high or medium. Fix N1, N2, N3 and N5 before the external audit: all are small patches. Then extend the invariant handler (N8) so the auditor gets a baseline that is actually true.
