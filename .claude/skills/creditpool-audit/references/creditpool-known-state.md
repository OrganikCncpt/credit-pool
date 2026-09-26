# Credit Pool known state (the baseline)

The "compare vs code" baseline for synthesis and the baseline verifier. Specialists
must NOT read this file or `README.md`'s security table while reviewing; reading the
answer key first biases the search. Only the synthesizer uses it, to classify each
confirmed finding as NET-NEW, ALREADY-FIXED, ACCEPTED-RESIDUAL, DESIGN-INVARIANT,
OPEN-KNOWN, or FALSE-POSITIVE.

Before relying on any line below, confirm it against `src/CreditPool.sol` as it is
now. This file describes intent as of 2026-09-24; the code wins if they disagree, and
a disagreement is itself a finding.

## What the system is

- `src/CreditPool.sol` (~510 lines, 380 nSLOC) + `src/AssemblyVault.sol` (58 nSLOC) +
  `src/IStatementAssembler.sol` (placeholder), solc 0.8.28 pinned, OZ v5.7: depositors pool Jack
  Butcher's **Credits** (ERC-721, mainnet `0x9763…3043`, source in
  `external/credits/`) into sequential 80-slot batches. A full batch is burned into
  one **Statement** via `IStatementAssembler` (a PLACEHOLDER: the real Statements
  contract is unpublished). The Statement is redeemed by a sole 80-slot holder or sold
  by on-chain English auction; proceeds split pro-rata by slots.
- Platform revenue: `$1` per Credit deposited (in ETH via Chainlink ETH/USD; `depositFee()` is per Credit), plus
  `SALE_FEE_BPS = 100` (1%) of each settled sale. Both accrue to `accruedFees`;
  `sweepFees` (permissionless) sends to `feeRecipient`.
- `app/`: static frontend (viem from jsdelivr, pinned 2.56.8, no build). `config.js`
  per-chain addresses. Chain 31337 is a local mainnet-fork demo.
- `script/Deploy.s.sol` (mainnet), `script/DeployLocal.s.sol`, `script/DeployFork.s.sol`.
- Not in scope as production code: `demo-fork.sh`, `simulate-*.py`, `serve.py`
  (local demo tooling only; still worth a glance for anything that could leak into
  mainnet config).

## Design invariants (deliberate; not findings)

1. **Immutable wiring.** `credits`, `statements`, `assembler`, `ethUsdFeed`,
   `assemblyOpensAt` are immutable. No upgrade, no pause, no admin rescue. The only
   owner lever is `setFeeRecipient` (non-zero). Wrong assembler = redeploy.
2. **One slot per Credit regardless of rarity.** Adverse selection (people pool
   Commons, keep rare Credits) is a known economic property, surfaced in the UI.
3. **Batches fill in deposit order**; depositors do not choose composition.
4. **Withdraw only while Filling**, or after the escape hatch dissolves a Full batch.
   Deposit fees are never refunded.
5. **Majority rules pricing.** Reserve = the lowest price that more than 40 of ALL 80
   slots have voted at or below (non-voters count as "not yet"). Only a >50% coalition
   can set a low reserve; a minority voting low cannot drag it down. A >50% holder can
   still start the auction immediately. Mitigations: the auction is public for 24h and
   anyone, including the minority, can outbid; `NO_RESERVE_AFTER` (below).
6. **Assembly is permissionless and isolated.** The pool NEVER approves the assembler. For
   each `assemble` it moves exactly the batch's 80 Credits into `AssemblyVault`, which alone
   approves the assembler for the duration of one call (revoked in the same tx), then checks
   the vault is empty, every id is burned, and exactly one new Statement arrived, and sends it
   to the pool. The pool re-checks its own Credit and Statement balances. The assembler can
   reach nothing but the 80 Credits being assembled (CP-17).
7. **Pull payments.** Outbid refunds go to `pendingReturns`; claims are per-depositor
   pull; `_send` uses a raw call and reverts on failure (the caller's own tx only).
8. **Deposits use `transferFrom`, not `safeTransferFrom`,** so `onERC721Received` is
   never hit on deposit.

## Fixed during the 2026-09-23 self-review (regression = finding)

Evidence: `test/Attacks.t.sol`, `test/Invariant.t.sol`.

| ID | Was | Fix now in code |
|---|---|---|
| CP-1 | `ORACLE_MAX_AGE = 1 hours` equalled the Chainlink heartbeat, bricking deposits at every heartbeat edge | `ORACLE_MAX_AGE = 1 days` (fee is $1) |
| CP-2 | NFTs sent via `safeTransferFrom` stuck forever | `onERC721Received` reverts `UnexpectedToken` unless `_assembling && msg.sender == statements` |
| CP-3 | Assembler could "return" a Statement the pool already held (double-assign, 80 burned for nothing) | `statements.balanceOf(pool)` must rise by exactly 1 and `ownerOf(sid) == pool`, else `StatementNotReceived` |
| CP-4 | A >50% holder could trap the minority forever with an unreachable reserve | `NO_RESERVE_AFTER = 30 days` after `assembledAt`: anyone can start a reserve-0 auction (`noReserveOpen`) |
| CP-5 | Escape hatch opening blocked `assemble`, letting one depositor veto a batch nobody assembled | `assemble` requires only `state == Full`; the first escape withdrawal moves it to `Dissolved` |
| CP-6 | Zero-value bids accepted after a reserve-0 start (endless 0-bid extension griefing) | `bid` rejects `msg.value == 0`; first-bid detection uses `highBidder == address(0)` |
| CP-7 | Per-Credit storage cost (three mappings) | Packed `CreditInfo {address depositor; uint64 batch; uint32 idx}` |

Fixed after the 2026-09-24 fused audit (`docs/FUSED-AUDIT.md`) and custody deep dive
(`test/custody/`):

| ID | Was | Fix now in code |
|---|---|---|
| CP-8 | Assembler's temporary approval could take other batches' Credits or burn the wrong ids (custody finding) | `assemble` requires `credits.balanceOf(pool)` to drop by exactly 80 and every id of this batch to be gone (`_stillHeld`), else `CreditsNotBurned` |
| CP-9 | CP-3 incomplete (audit N1): stale return id or hook-injected Statement could double-assign | `statementAssigned[sid]`; a hook receipt must equal the returned id; else `StatementNotReceived` |
| CP-10 | Minority of 21-40 slots could fix the reserve (audit N2) | Reserve = lowest price >40 of ALL 80 slots accept |
| CP-11 | Front-running a deposit could split a planned solo batch (audit N3) | `depositAt(ids, expectedBatch, expectedFilled)` reverts `BatchMoved`; the frontend uses it |
| CP-12 | No-reserve path could force a sale on a sole 80-slot holder (audit N4) | `noReserveOpen` is false when the batch has one depositor |
| CP-13 | Constructor accepted a zero fee recipient; deploy script unchecked (audit N5) | `ZeroAddress` in constructor and `setFeeRecipient`; `Deploy.s.sol` checks chain, feed decimals/freshness, non-zero recipient, sane `ASSEMBLY_OPENS_AT`, optional `OWNER` handoff |
| CP-14 | Equal bid below 20 wei outbid and extended the auction (audit N9) | Minimum step is at least 1 wei |
| CP-15 | No events on fee/refund admin paths; `setReserve`/`startAuction` unguarded (audit N10) | `RefundWithdrawn`, `FeesSwept`, `FeeRecipientSet`; both functions `nonReentrant` |
| CP-16 | Frontend: stale reserve on "Start auction" confirm; double-submit (audit N6, N7) | Superseded by CP-20; one transaction at a time |

Fixed after fused audit #2 (`docs/FUSED-AUDIT-2.md`, 2026-09-25):

| ID | Was | Fix now in code |
|---|---|---|
| CP-17 | CP-8's balance check could be beaten by a swap (burn 80, pull another batch's Credit out, push a cheap one in): audit #2 N-1 | `AssemblyVault`: the assembler only ever holds approval over the vault, which holds only the batch; vault must end empty with every id burned (`test_Fixed_SwapInCaught`, `test_Fixed_AssemblerCannotReachPool`) |
| CP-18 | Frontend `depositAt` pin read after the confirm dialog, from state the live poll could overwrite (N-2) | Snapshot before the dialog |
| CP-19 | Frontend withdraw on a Dissolved batch built from stale `creditIds` and could pull a re-deposited Credit from its new batch (N-3) | Also requires `batchOf(id) == b` |
| CP-20 | Reserve re-checked before the confirm, not enforced on-chain; 30-day crossover unchecked (N-4) | `startAuctionAt(b, expectedReserve)` reverts `ReserveChanged`; frontend uses it |
| CP-21 | 30-day fallback discarded even a unanimous reserve (N-5) | Fallback minimum = lowest vote cast (`lowestVote`), 0 only if nobody voted; `auctionReserve` view |
| CP-22 | No upper bound on `ASSEMBLY_OPENS_AT`; single-step, renounceable ownership; floating pragma, unpinned solc/optimizer; Slither CEI and uninitialized-local notes (N-6, N-7, N-9) | Deploy script bounds [-30, +90] days and requires `OWNER`; `Ownable2Step`, `renounceOwnership` reverts; pragma `0.8.28`, `foundry.toml` pins solc and optimizer; `_deposit` records before transferring; explicit zero inits |

## Accepted residuals (known, deliberate or out of our control)

| ID | Residual | Why accepted |
|---|---|---|
| AR-1 | A >50% coalition can start a 1-wei-reserve auction immediately | Public 24h English auction; minority can outbid and gets `slots/80` back of their own bid |
| AR-2 | Claim rounding leaves `< 80` wei dust per batch | Negligible; fuzzed in `testFuzz_ClaimsNeverExceedProceeds` |
| AR-3 | Assembler holds approve-for-all over pool Credits during `assemble` | Required by Credits `burn(owner, ids)`; assembler is Jack's contract |
| AR-4 | `sweepFees` is permissionless | Can only pay `feeRecipient` |
| AR-5 | Frontend loads viem from a CDN without SRI | ESM imports can't carry SRI; version pinned. Revisit by self-hosting before launch |
| AR-6 | Deposit of >~115 real Credits in one tx exceeds the 2^24 per-tx gas cap | Frontend chunks at 100/tx; contract does not cap array length |
| AR-7 | Dissolved batches keep their `creditIds` array (`filled` still reads 80) | Contract withdrawals use `_credit`, which is cleared; the frontend also checks `batchOf` (CP-19) |
| AR-8 | NFTs sent by plain `transferFrom` (not `safeTransferFrom`) are stuck | No admin rescue by design (immutable, ownerless custody) |
| AR-9 | `settle` delivers the Statement with `transferFrom`, so a contract winner without ERC-721 support can't move it (audit #2 N-8) | Deliberate: `safeTransferFrom` would let a malicious winner revert and brick settlement for every depositor |

## Open, known, blocked on the Statements contract

| ID | Issue | Status |
|---|---|---|
| OK-1 | `IStatementAssembler` is a placeholder; real signature unknown | Swap before deploy (README launch checklist step 1) |
| OK-2 | Deposits after the 1,526 Statement cap still fill and lock for `ESCAPE_DELAY` (14 days) | Needs a cap/supply read from the real Statements contract |
| OK-3 | Statements may reject contract callers, require an X-account signature, cap per address, or mint to `tx.origin` | Any of these breaks assembly; must be checked the day it is published |
| OK-4 | `ASSEMBLY_OPENS_AT` must equal real assembly opening; too early lets full batches dissolve before they can be assembled | Deploy-time parameter (script now bounds it) |
| OK-5 | Statements transfer restrictions (soulbound period, allowlist) would brick `redeem` / `settle` | Check the day it is published |

## Proven facts (so they are not re-litigated)

- Real Credits: after `seal()`, the owner has no remaining powers; no pause,
  blacklist, or transfer hook. `burn(owner, ids)` checks `msg.sender == owner ||
  isApprovedForAll(owner, msg.sender)`. Proven on a mainnet fork
  (`test/CreditPool.fork.t.sol`): deposit, withdraw, and a burn of 80 real Credits.
- Gas (fork, real Credits): deposit ≈ 100k per Credit (80 ≈ 8.3M); `assemble` of 80
  ≈ 1.5M (stand-in assembler).
- Reentrancy: every state-changing external function except `setFeeRecipient` (onlyOwner,
  no external calls) is `nonReentrant`; reentrant bidders and depositors are tested.
- Invariants fuzzed (64 runs × 40 depth): pool Credit balance equals tracked set;
  every closed batch has exactly 80; slots sum to filled; open-batch Credits are owned
  and attributed.
- Custody deep dive (`test/custody/`, 2026-09-24): 56 attack tests. ETH: every
  in/out path enumerated; a 5-actor handler invariant (re-entering contract, reverting
  bidder, thief) asserts after every call that balance covers live bids + refunds +
  unclaimed shares + fees, and the thief never profits. NFTs: every exit path
  enumerated; a handler invariant asserts every pool Credit is attributed to exactly one
  depositor in one live batch and Credits never reach non-depositors. No theft path
  found without a malicious assembler, and CP-8/CP-9 closed those.
- Gas after CP-17 (vault): `assemble` of 80 real Credits ≈ 4.25M (fork, stand-in assembler).
- Slither 0.11.6: no true positives; triage in `docs/STATIC-ANALYSIS.md`.
- Frontend `?dev=` (anvil keys) and `?as=` (anvil impersonation) are gated to chain
  31337. `?view=` is read-only on any chain.
