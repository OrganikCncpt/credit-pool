> **Status (2026-09-25, after this report):** N-1 to N-7 and N-9 fixed; N-8 accepted (AR-9);
> proposed OK-5 added. Details: `.claude/skills/creditpool-audit/references/creditpool-known-state.md`
> (CP-17..CP-22, AR-9, OK-5). Test gate: 103/103 local + 3/3 mainnet-fork tests passing.

# Credit Pool fused audit #2 (2026-09-25)

**Scope:** `src/CreditPool.sol` (502 lines), `script/Deploy.s.sol`, `app/` (`app.js`, `config.js`, `index.html`), `test/`.
**Purpose:** A re-audit after the CP-8..CP-16 fixes, and a readiness check before an external audit.

**Source roster (checklists the specialists worked from):**
- evm-audit checklists: access-control, erc721, precision-math, oracles, dos
- scv: transaction-ordering, timestamp-dependence, lack-of-precision, inadherence-to-standards
- state-invariant-detection
- external-call-safety
- defender deploy-script safety (D/E/G/H/I)
- solskill #12

**The 10 specialists:** access-guard, state-machine, eth-extcall, erc721, precision, oracle-time, auction-game, dos-gas, deploy-integration, frontend. None of them saw the baseline, so their review was blind.

**Method:**
1. The specialists produced 23 raw findings.
2. An adversarial verifier re-checked the medium+ findings against the code.
   - The assembler-swap finding was confirmed with a Foundry PoC. The PoC was temporary and has since been removed.
   - The depositAt-pin finding was confirmed by tracing the code.
   - The Statements-cap finding was downgraded from medium to low. It is already a known open item (OK-2).
3. At synthesis, the 23 raw findings were merged into 17 root causes.
4. The baseline itself (`creditpool-known-state.md` and the README "Security review" section) was re-checked against the current code before any finding was classified against it.
5. Each finding was classified.
6. A standards lens was applied: ethskills/security, solskill/solidity, and OZ develop-secure-contracts.

**Result:**
- 0 critical, 0 high.
- **2 medium, 4 low, 3 info net-new.** Each medium closes a gap in a fix the baseline marks as complete (CP-8 and CP-11).
- 0 false positives.

---

## Baseline check: does the known state still match the code?

These entries still match the code:
- CP-1: `ORACLE_MAX_AGE = 1 days`.
- CP-2: the `onERC721Received` gate.
- CP-3 and CP-9: `statementAssigned` plus agreement between the hook receipt and the returned id.
- CP-5, CP-6, CP-7.
- CP-10: the reserve over all 80 slots.
- CP-12: a sole holder is exempt from the no-reserve path.
- CP-14: a minimum 1-wei step.
- CP-15: the events are present, and `setReserve`/`startAuction` are `nonReentrant`.
- Design invariants 1-5 and 7-8.

**These entries do not match. Each mismatch is itself a finding:**

1. **DI-6 / CP-8 is false.** The known state says the pool "verifies afterwards that exactly this batch's 80 Credits left and nothing else". The code checks only the net balance delta and that this batch's ids are gone. A swap that takes one Credit out and puts another in passes both checks. See **N-1**.
2. **CP-11 is incomplete.** The frontend calls `depositAt`, but it reads the pin *after* the confirm dialog, from globals that a background poll has overwritten. See **N-2**.
3. **CP-16 is incomplete.** The reserve is re-read *before* the confirm dialog, not before sending. The no-reserve crossover is never re-checked. See **N-4**.
4. **AR-7's rationale is wrong.** AR-7 calls the stale `creditIds` on Dissolved batches "view-only". The frontend builds `withdraw` calldata from it. See **N-3**.
5. **CP-13 overstates the fix.** "sane `ASSEMBLY_OPENS_AT`" is only a lower bound (`Deploy.s.sol:37`). There is no upper bound in the script or the constructor. See **N-6**.
6. **The CP-4 intent does not match the code.** The NatSpec at `CreditPool.sol:320-322` says the fallback exists to stop a majority holding a minority hostage. The code discards every reserve after 30 days, including a quorum or unanimous one. See **N-5**.
7. **Documentation drift (no code impact):**
   - "~440 lines": the file is now 502 lines.
   - The proven fact "every state-changing external function except `setReserve`, `startAuction`, `setFeeRecipient` is nonReentrant" is stale. Since CP-15, only `setFeeRecipient` and `onERC721Received` lack the guard.
   - AR-5 says "ESM imports can't carry SRI". Import maps now support an `integrity` field in current Chromium and Safari.

---

## Net-new findings

### N-1 [MEDIUM] A swapped-in Credit defeats the CP-8 custody check, so the assembler can steal another batch's Credit
- **Location:** `src/CreditPool.sol:262`, `:283-287`
- **Fired:** deploy-integration. The verifier confirmed it with a PoC.
- **Failure scenario:**
  1. `assemble(b)` grants the assembler `setApprovalForAll` over every Credit the pool holds.
  2. During the call, the assembler burns the batch's 80 ids.
  3. It calls `credits.transferFrom(pool, attacker, X)`. X is a rare Credit sitting in a later batch.
  4. It calls `credits.transferFrom(attacker, pool, Y)`. Y is a cheap Credit. Plain `transferFrom` fires no receiver hook.
  5. Net balance change: -80. None of batch b's ids is still held. Both checks pass.
- **Result:**
  - X's depositor can never withdraw it: `withdraw` reverts at `:237`.
  - X's batch can never assemble.
  - At escape, X is unrecoverable.
  - Y is stranded with no `_credit` entry.
  - `test/custody/NftCustody.t.sol` only tests a thief that *removes* extra Credits. That changes the balance and is caught. The swap case is not tested.
- **Why medium, not high:** It needs a malicious or compromised assembler. The assembler is immutable and chosen at deploy (AR-3). But the whole point of CP-8 was to make that trust unnecessary, and `Deploy.s.sol:17` lets `ASSEMBLER` differ from `STATEMENTS`.
- **Fix:**
  - **A count check does not work.** The verifier suggested "track live custodied count and require balance == count - 80". A 1-for-1 swap keeps the count unchanged, so this check cannot catch it.
  - **Recommended: isolate the approval.** Move the batch's 80 Credits into a fresh single-use escrow (a CREATE2 minimal clone). The escrow grants `setApprovalForAll` only over its own holdings, calls the assembler, and forwards the Statement. Real Credits `burn(owner, ids)` needs approval-for-all (`external/credits/Credits.sol:91`), so per-id approvals cannot replace this.
  - **Interim hardening:**
    - Make `Deploy.s.sol` require `ASSEMBLER == STATEMENTS` unless an explicit override flag is set.
    - Correct the comment at `:280-282` and the DI-6/CP-8 text.
    - Add a regression test with a swap-in assembler.

### N-2 [MEDIUM] The frontend `depositAt` pin is read after the confirm dialog from globals a poll can change, which defeats the CP-11 front-run guard
- **Location:** `app/app.js:476`. Related code: `:256`, `:281-288`, `:331-348`, `:466-470`.
- **Fired:** frontend. The verifier confirmed it by code trace.
- **Failure scenario:**
  1. The dialog text is built from `S.openBatch`/`S.openFilled` at click time.
  2. While the modal is open, `poll()` keeps running. It skips a refresh only when an `<input>` has focus, and the dialog's focus is on a `<button>`.
  3. `renderStats()` overwrites both globals (`:348`).
  4. `expect = [S.openBatch, S.openFilled]` is read *after* `await confirmStep(...)`.
- **Example:**
  1. A user with 80 Credits sees "batch #5, taking it to 80/80".
  2. A stranger deposits 1 Credit into #5. It is mined, and the next poll sets `openFilled = 1`.
  3. The user clicks Deposit, and `depositAt(ids, 5, 1)` succeeds.
  4. 79 Credits fill #5 next to the stranger and lock. 1 Credit spills into #6.
  5. The sole-holder redeem path is lost, and the Statement is forced through the vote and auction with its 1% fee.
- **Fix:**
  - Take `const shown = [S.openBatch, S.openFilled]` *before* `confirmStep`.
  - Use it for both the dialog text and the first `expect`.
  - Optionally, set `S.sending`, or pause `poll`, while a confirm dialog is open.

### N-3 [LOW] Dissolved batches keep a stale `creditIds`, and "Withdraw my N" can pull re-deposited Credits out of the open batch
- **Location:** `src/CreditPool.sol:224-232`, `app/app.js:643-647`
- **Fired:** state-machine.
- **Failure scenario:**
  1. Alice has 10 Credits in batch 3, which becomes escape-Dissolved.
  2. She withdraws 5 of them outside the app, then re-deposits those 5 into Filling batch 7.
  3. She clicks "Withdraw my 5" on batch 3. The label comes from `slots`.
  4. The app reads `batchCredits(3)`, which still lists all 10 ids, and filters them by `depositorOf(id) == Alice`. All 10 match.
  5. The app sends all 10 ids to `withdraw`, which routes each id by `_credit[id].batch`.
  6. The 5 Credits in batch 7 are silently withdrawn. Alice loses those $5 of fees and her place in the batch.
- **Other effects:**
  - `batchInfo(3).filled` keeps reporting 80.
  - The invariant `sum(slots[b]) == creditIds.length` fails for Dissolved batches. The fuzz handler never warps past `ESCAPE_DELAY`, so it never checks this case.
- **Fix:**
  - In the contract, swap-and-pop `creditIds` in the Dissolved branch too. `_credit[id].idx` is still valid there, so the same code works.
  - In the app, also filter by `batchOf(id) == b`.
  - Extend the invariant handler to cover the escape path.
  - Once fixed, retire AR-7.

### N-4 [LOW] The start-auction reserve is re-checked before the confirm dialog, not after, and the contract takes no expected reserve (CP-16 incomplete)
- **Location:** `app/app.js:677-685`, `src/CreditPool.sol:323-331`
- **Fired:** frontend.
- **Failure scenario:**
  1. `currentReserve` is re-read (`:679`), and only then does the dialog open. It can stay open for any length of time.
  2. `startAuction(b)` is sent with no price argument.
  3. Meanwhile, votes can be lowered, or the batch can cross `NO_RESERVE_AFTER`. `noReserveOpen` is never re-checked after confirmation.
  4. A user who confirmed "Minimum bid: 10 ETH" can start a 24h auction that cannot be cancelled, at a lower reserve or with no reserve at all.
  5. A voter can also front-run the signed transaction by lowering their vote.
- **Fix:**
  - Re-read both `currentReserve` and `noReserveOpen` after confirmation.
  - Better: add `startAuction(b, expectedReserve)`, which reverts on a mismatch. This mirrors `depositAt`.

### N-5 [LOW] The 30-day no-reserve fallback throws away any reserve, including a unanimous one, and a failed auction never resets the clock
- **Location:** `src/CreditPool.sol:326`, `:333-338`, `:401-405`
- **Fired:** oracle-time, auction-game. These two findings were merged.
- **Failure scenario:**
  1. `reserve = noReserveOpen(b) ? 0 : currentReserve(b)`. `assembledAt` is set once and is not reset when `settle` returns a no-bid batch to Assembled.
  2. Two or more depositors unanimously vote 10 ETH. Their auction gets no bids and is settled on day 30.
  3. Any outsider calls `startAuction` at a quiet hour with reserve 0 and bids 1 wei.
  4. Unless a depositor counter-bids within 24h, the Statement sells for dust.
- **Why this is new:** CP-12 only protects a *sole* holder. This is a timed forced sale that anyone can trigger. It is not the "minority hostage" protection the NatSpec describes.
- **Fix (design decision for the owner):**
  - Apply the no-reserve path only when no quorum reserve exists, or measure 30 days from the last failed auction.
  - Consider restricting the no-reserve start to depositors.
  - At minimum, document the behavior accurately in the NatSpec, the UI and an AR entry.

### N-6 [LOW] `ASSEMBLY_OPENS_AT` has no upper bound, so a unit typo effectively disables the escape hatch (CP-13 incomplete)
- **Location:** `script/Deploy.s.sol:37`, `src/CreditPool.sol:139`
- **Fired:** deploy-integration.
- **Failure scenario:**
  1. Only values more than 30 days in the past are rejected.
  2. A milliseconds value (e.g. `1790000000000`) or a far-future date passes the check and is stored as an immutable.
  3. `escapeOpen` then never becomes true in practice.
  4. If Statements later rejects the pool (OK-2, OK-3), every full batch is locked for good. Redeploying does not free Credits that are already inside.
- **Fix:**
  - Add `require(opensAt <= block.timestamp + 90 days)` in the script, with a matching constructor bound.
  - Also add non-zero checks in the constructor for `credits`, `statements`, `assembler` and `ethUsdFeed`.

### N-7 [INFO] Single-step `Ownable` and a live `renounceOwnership` can freeze `feeRecipient`, and an unset `OWNER` leaves the deployer EOA as owner
- **Location:** `src/CreditPool.sol:31`, `:134`, `:436`; `script/Deploy.s.sol:26`, `:41`
- **Fired:** access-guard, deploy-integration. The solskill #24 standards check also flags this.
- **Failure scenario:**
  - A mistyped `OWNER` or a call to `renounceOwnership()` removes the ability to call `setFeeRecipient`.
  - If the recipient then reverts on receive, `sweepFees` reverts forever and `accruedFees` is locked.
  - If `OWNER` is unset, the hot deployer key stays owner and can redirect future fees.
  - Only platform revenue is affected. Depositors are not.
- **Fix:**
  - Use `Ownable2Step`.
  - Override `renounceOwnership` to revert.
  - Require `OWNER` on chainid 1.

### N-8 [INFO] `settle` delivers the Statement with `transferFrom`, so a contract winner without ERC721 support loses it
- **Location:** `src/CreditPool.sol:411`
- **Fired:** erc721.
- **Failure scenario:** A bot or contract-wallet bidder that cannot move ERC721s wins the auction. It pays `highBid`, and the Statement is stuck in it.
- **Why `transferFrom` is still right here:** `safeTransferFrom` would let a reverting receiver brick `settle`.
- **Fix:**
  - Document this in the bid dialog.
  - Or add an opt-in pull, for example `claimStatement(b, to)` using `safeTransferFrom` to an address the winner chooses.

### N-9 [INFO, standards lens] The compiler setup is not pinned for audit reproducibility, and there is no static-analysis or CI evidence
- **Location:** `src/CreditPool.sol:2`, `foundry.toml`
- **Fired:** synthesis. Sources: ethskills pre-deploy checklist, solskill #29 and the CI section.
- **Issues:**
  - The pragma floats (`^0.8.24`).
  - `foundry.toml` pins neither `solc_version` nor `optimizer` for the default profile. So the audited bytecode and the gas figures in the README cannot be reproduced exactly.
  - No Slither/Aderyn output or CI config exists in the repo.
- **Fix:**
  - Pin the solc version and the optimizer settings.
  - Run Slither or Aderyn and triage the output.
  - Commit the report alongside this one before handing off.

---

## Everything else, by classification

| # | Finding | Specialists | Class | Note |
|---|---|---|---|---|
| 1 | Claim rounding leaves < 80 wei per settled batch; `depositFee` rounds down by < 1 wei | state-machine, eth-extcall, precision | ACCEPTED-RESIDUAL (AR-2) | Solvency holds (balance >= liabilities). Tell the external auditor that exact-balance invariants must allow for this dust |
| 2 | Credits or Statements sent by plain `transferFrom` are stuck | erc721 | ACCEPTED-RESIDUAL (AR-8) | Reword the comment at `:468-470` ("bounce" applies only to `safeTransferFrom`) |
| 3 | viem loaded from jsdelivr without SRI, and no CSP | frontend | ACCEPTED-RESIDUAL (AR-5) | AR-5's rationale is outdated: an importmap `integrity` field works. Self-host viem and add `script-src 'self'` before launch |
| 4 | Immutable Chainlink feed with no fallback: a deprecated or stalled feed blocks deposits | oracle-time, dos-gas | DESIGN-INVARIANT (DI-1) | No funds at risk. Withdraw, assemble, auction and claim are oracle-free |
| 5 | Deposits continue after the Statements cap or per-address limit; batches lock and fees are kept | deploy-integration (verified, med -> low) | OPEN-KNOWN (OK-2, OK-3) | Bounded by the 14-day escape. Fees are non-refundable by DI-4 |
| 6 | Deploy script checks Statements only via `code.length`; incompatibility is found only after 80 Credits lock | deploy-integration | OPEN-KNOWN (OK-1, OK-3) | Add an ERC165 `supportsInterface(0x80ac58cd)` check and a fork rehearsal that assembles one batch against the real contract |
| 7 | `settle`/`redeem` have no fallback if the Statements token restricts transfers (pause, blocklist, soulbound, upgrade) | eth-extcall, erc721 | OPEN-KNOWN (extends OK-3; propose OK-5) | Not in the current OK list: add "Statements transfer semantics" to the launch checklist. If it is not a plain OZ ERC721, add an escape that makes the high bid refundable |
| 8 | `DEFAULT_CHAIN = 31337`: production visitors without a wallet see the "local demo" banner and read from 127.0.0.1 | frontend | OPEN-KNOWN (launch checklist step 4) | Also drop the 31337 entry from the production build |
| 9 | A cheap parked Credit in the open batch blocks the sole-holder path | dos-gas | DESIGN-INVARIANT (DI-3, CP-11) | `depositAt` reverting is intended. Optional: a "fresh batch of exactly 80" entry point |

**False positives:** 0 of 17 root causes (23 raw findings). No finding was contradicted by the code. Two claims were narrowed:
- Finding 5: the per-address limit is speculative until Statements is published.
- N-1: the verifier's count-based fix does not work, and a replacement is given above.

**Standards lens:** ethskills, solskill and OZ turned up three gaps the specialists missed:
- Compiler and optimizer pinning (N-9).
- Static-analysis and CI evidence (N-9).
- The constructor zero-address checks folded into N-6.

They also agree with N-7 (`Ownable2Step`). Everything else on the ethskills pre-deploy checklist passes, including reentrancy, oracle staleness, events and bounded approvals. The exception is the approval scope in N-1.

## Before the external audit (recommended order)
1. Fix N-1: add the per-batch escrow, plus a swap-in regression test.
2. Fix N-2 and N-4, the frontend pins. Add `expectedReserve` to `startAuction`.
3. Fix N-3: swap-and-pop in Dissolved, the app filter, and an invariant handler that warps past escape.
4. Decide on N-5 and record the decision.
5. Fix N-6, N-7 and N-9, then run Slither.
6. Update `creditpool-known-state.md` and the README table: the DI-6/CP-8/CP-11/CP-13/CP-16/AR-5/AR-7 text, the new OK-5, and the line count.
