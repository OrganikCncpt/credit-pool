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
- Fees (changed 2026-09-28, after external audit #1): deposit `$2` per Credit, or `$1` each for 6+ in one
  deposit (`depositFeeFor(n)`; `usdWei()` = $1 in wei). No sale fee (SALE_FEE_BPS removed).
  `sweepFees` (permissionless) sends 25% to `feeRecipient`, 75% to the store.
- `src/CreditStore.sol` (NEW, not yet externally audited): SCREDIT non-transferable points (2 per Credit,
  awarded by the pool in `_deposit`), the treasury (spent only via owner-triggered `buyUnsold` on batches
  with `unsoldAuctions(b) > 0`, opening bid = the depositors' own reserve, capped), and the SCREDIT-only store
  auction ($0.25 ETH platform fee per bid). Linked to the pool once via `setPool`.
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

Fixed after external audit #1 (`docs/EXTERNAL-AUDIT-1-TRIAGE.md`, tests in `test/ExternalAudit1.t.sol`):

| ID | Was | Fix now in code |
|---|---|---|
| CP-23 | `AssemblyVault` absolute Credit-balance checks: one donated Credit blocked all assembly forever (ext. H-01) | Entry/exit are deltas from the balance at entry; per-id burn check kept; swap still caught with a stray present |
| CP-24 | A sole holder's own vote let anyone force their Statement to auction (ext. H-02; CP-12 covered only the 30-day path) | Only the sole holder may start an auction on a single-depositor batch (`NotDepositor` otherwise); frontend hides the button for others |
| CP-25 | Feed hygiene (ext. L-02, L-03) | Feed decimals read once at construction; future-dated round → `StaleOracle` |
| CP-26 | Constructor accepted non-contract dependencies (ext. L-04) | `NotAContract` for credits, statements, assembler, feed |
| CP-27 | Burned Credits still reported a depositor/batch (ext. I-05) | `_credit` cleared when moved to the vault; withdrawing a burned id now reverts `NotDepositor` |

External audit #1 H-03 is accepted as AR-10 (owner decision).

| CP-28 | A dead or stale price feed blocked all deposits (ext. M-01; was DI-1) | `fallbackFeeWei` frozen at deploy ($1 in ETH then) is used whenever the feed is untrusted; `depositFee()` never reverts; `feeUsesFallback()`; constructor requires a healthy feed |

Store review (2026-09-28, diff review of the fee change + `CreditStore`; `docs/STORE-AUDIT.md`):

| ID | Finding | Fix |
|---|---|---|
| CP-29 | `buyUnsold` read the reserve at execution and could join a live auction: depositors (>40 slots, or anyone after 30 days) front-run to make the treasury pay up to the cap (M) | `buyUnsold(b, maxAmount)`: price = `currentReserve` (majority), `PriceMoved` above the owner's limit; opens via `startAuctionAt` (batch Assembled) or bids into a live no-bid auction only if it opened at that same minimum (`AlreadyBid` if anyone bid) |
| CP-30 | Treasury could open at 1 wei via the 30-day lowest-vote fallback / no votes (L) | Same fix: `currentReserve` reverts without quorum; `startAuctionAt` reverts when the fallback minimum differs |
| CP-31 | Owner could raise the cap instantly and self-deal the treasury (M, trust) | Raising `maxTreasuryBid` is delayed 3 days (lowering immediate, cancels a pending raise); initial cap in the constructor (0 on mainnet). Residual trust: AR-11 |
| CP-32 | SCREDIT farmable via deposit→withdraw loops at $0.50/point with nothing pooled (L-M) | Points awarded only when a batch fills (`_awardPoints`), 2 × slots, one `store.award(address[],uint256[])` call |
| CP-33 | `setPool` accepted a pool not pointing back, permanently bricking deposits/sweeps (L) | `setPool` requires `pool_.store() == address(this)` (`WrongPool`) |
| CP-34 | `feeRecipient` could be set to the store, making `sweepBidFees` revert (I) | `setFeeRecipient` rejects the store |
| CP-35 | Escrowed bid points had no events; Σ balances < totalSupply during bids (I) | Escrow moves points to `balanceOf[store]` with `Transfer` events; settle burns from the store |
| CP-36 | UI: leader couldn't raise their own store bid (L) | Held points count toward the raise |
| CP-37 | UI: a click on Deposit right after Approve was refused while the page redrew | Send lock released once the tx is final, before the redraw |
| CP-38 | First CP-29 fix required state Assembled, so anyone could lock the treasury out by restarting the auction first (verify pass R1) | Also accepts a live auction with no bids opened at the majority minimum (`test_RestartedAuctionStillBuyable`) |
| CP-39 | Constructor accepted the store as `feeRecipient` (verify pass, fix 6 partial) | Constructor rejects it too |
| CP-40 | After 30 days one low minority vote blocked treasury purchases (was AR-16; owner asked to fix) | The store opens the auction (possibly at the fallback minimum) but always bids the majority price, which is never lower; a live auction above the majority minimum still reverts `PriceMoved` |
| CP-41 | A `feeRecipient` rejecting ETH paused `sweepFees` for the treasury's share too (was AR-13; owner asked to fix) | Treasury's 75% always goes out; the platform's share is held in `platformFeesOwed` and paid on a later sweep (never re-split) |
| CP-42 | `sweepFees` copied the fee wallet's returndata: a recipient reverting with ~3 MB ran even a 30M-gas sweep out of gas, stalling the treasury's share (verify pass 2) | Assembly call without returndata copy; `PlatformFeesHeld` event (`test_ReturndataBombCantStallTreasury`, fails on 542dccd) |
| CP-43 | In a live no-bid auction, a majority could raise votes after it opened and the treasury bid the higher majority price (up to the owner's limit) (verify pass 2) | Treasury bids the price the auction opened at; only an auction opened by the 30-day fallback gets the majority price (`test_VoteRaiseAfterOpenDoesntRaiseTreasuryBid`, fails on 542dccd) |

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
| AR-10 | After 30 days unsold, the fallback minimum is the lowest vote cast, unweighted by slots, so one low vote sets the floor (ext. audit #1 H-03) | Owner decision: prevents a majority from blocking a sale forever (CP-4, CP-21). Everyone can outbid for 24h; the frontend warns depositors in the last 7 days before it applies |
| AR-11 | The store owner chooses which unsold batches the treasury buys, up to `maxTreasuryBid` each; an owner who also controls a batch's majority can route treasury ETH to it | Trust assumption, documented. Bounded by the cap; raises take 3 days (CP-31); owner should be a multisig |
| AR-12 | Deposit fee is non-monotonic at the bulk boundary (5 Credits = $10, 6 = $6) | Owner's pricing decision; the UI tips "6+ at once cost $1 each" |
| AR-15 | A batch that fills, isn't assembled for 14 days, then dissolves keeps its points (same $0.50/point as honest depositors, Credits locked 14+ days) | Anyone can `assemble` once assembly is open; before that, points cost the same as honest ones |
| AR-17 | If a listed Statement left the store by means outside the store's code, `settle` reverts and the winner's escrowed points stay locked | Depends on the real Statements contract (OK-list); revisit when published |
| AR-14 | The deposit that fills a batch pays for awarding points to every depositor (≤ ~2.35M gas for 80 depositors) | Measured (`test_FillAwardGas_80Depositors`); a 100-Credit deposit stays ≈ 13.1M worst case, under 2^24 |

## Open, known, blocked on the Statements contract

| ID | Issue | Status |
|---|---|---|
| OK-1 | `IStatementAssembler` is a placeholder; real signature unknown | Swap before deploy (README launch checklist step 1) |
| OK-2 | Deposits after the 1,526 Statement cap still fill and lock for `ESCAPE_DELAY` (14 days) | Needs a cap/supply read from the real Statements contract |
| OK-3 | Statements may reject contract callers, require an X-account signature, cap per address, or mint to `tx.origin` | Any of these breaks assembly; must be checked the day it is published |
| OK-4 | `ASSEMBLY_OPENS_AT` must equal real assembly opening; too early lets full batches dissolve before they can be assembled | Deploy-time parameter (script now bounds it) |
| OK-5 | Statements transfer restrictions (soulbound period, allowlist) would brick `redeem` / `settle` | Check the day it is published |
| OK-6 | Print order and Credit colour decide the Statement's look (Jack, Sep 27: "behaves like a printer"). The pool burns in deposit order, shuffled by withdraw's swap-and-pop, so every pooled Statement is effectively "random" | Planned: arrangement vote + fixed default order (`docs/STATEMENTS-DESIGN.md` Design 1). Not a custody issue |
| OK-7 | Real function may take an order/direction parameter the placeholder can't pass | Confirm S-1/S-2; decide via depositor vote, never on-chain randomness (the permissionless `assemble` caller would pick it) |
| OK-8 | Layering: Credits can be printed onto an existing Statement. `assemble`/`AssemblyVault` require exactly one NEW Statement per 80 | Confirm S-4; a layering mode needs a new custody check and a full audit (Design 3) |
| OK-9 | Randomness inside Statements (e.g. misregistration) seeded by caller-influenced data would make `assemble` timing a lever | Confirm S-5 |
| OK-10 | Layers may not mint, so fewer than 1,526 Statements may exist; cap guard must match real supply rules | Confirm S-6 with OK-2 |

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
