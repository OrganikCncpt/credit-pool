# Credit Pool: external audit package

Everything an auditor needs to start: what the system does, what's in scope, who is
trusted, what must always hold, what we already know, and how to build and test it.

> **Status:** ready to audit, with one blocker. The Statements contract (Jack Butcher's,
> unpublished as of 2026-09-25) is represented by a placeholder interface. The external
> audit should start once the real interface is wired in (see "Blocked on Statements").

## 1. What it does

Jack Butcher's **Credits** (ERC-721, Ethereum mainnet, `0x97630aA70AB14ed9883B41dAfccBc11349723043`)
burn 80-at-a-time into one **Statement**. X Money capped each account at 50 Credits, so
most holders can't reach 80 alone. Credit Pool lets holders pool Credits:

1. **Deposit** Credits into the open 80-slot batch (`deposit` / `depositAt`). $1 per Credit in ETH
   (Chainlink ETH/USD). Withdraw any time while the batch is filling.
2. At 80 the batch locks. Anyone calls **`assemble`**: the pool moves exactly that batch's 80
   Credits into the `AssemblyVault`, which calls the Statements contract to burn them and mint
   one Statement, then hands the Statement back to the pool.
3. A sole 80-slot holder **`redeem`s** the Statement. Otherwise depositors **vote a reserve**
   (`setReserve`); the reserve is the lowest price that more than 40 of the 80 slots accept.
   Anyone starts a 24h English **auction** (`startAuction` / `startAuctionAt`): 5% minimum
   raise, 15-minute anti-snipe extension, pull refunds for outbid bidders.
4. **`settle`** sends the Statement to the winner and books the sale: 100% split
   by slots. Each depositor **`claim`s** their share.
5. Safety valves: after 30 days unsold, quorum is dropped and the minimum becomes the lowest
   vote cast. A full batch that can't be assembled becomes withdrawable after 14 days.

Revenue: a deposit fee of $2 per Credit ($1 each for 6+ at once), swept (permissionless) 25% to
`feeRecipient` and 75% to the `CreditStore` treasury; plus $0.25 per store bid. No sale fee.
6. **Store** (`CreditStore`, new since audit #1): 2 non-transferable SCREDIT points per Credit deposited;
   the treasury buys only Statements whose auction ended with no bids (opening bid at the depositors'
   minimum, capped, owner-triggered); those Statements are auctioned for SCREDIT only.

> **Scope changed after external audit #1:** the fee model, `CreditStore`, and the pool's calls into it
> (`store.award` in `_deposit`, the 25/75 sweep, `unsoldAuctions`) are new and need review.

## 2. Scope

Current: tag **`audit-prep-4`**, https://github.com/OrganikCncpt/credit-pool/tree/audit-prep-4
(external audit #2's fixes on top of `audit-prep-3`; see `docs/EXTERNAL-AUDIT-2-TRIAGE.md`).
It adds `CreditStore` (SCREDIT points, treasury, store auction), the tiered deposit fee and the
removed sale fee. Everything since external audit #1 has had internal reviews only:
`docs/STORE-AUDIT.md` and `docs/FULL-AUDIT-3.md`.
Previously audited externally: tag `audit-prep-1` (commit `30d172a`); fixes at `audit-prep-2`
(`docs/EXTERNAL-AUDIT-1-TRIAGE.md`). External audit #2 ran on `audit-prep-3`; triage and fixes:
`docs/EXTERNAL-AUDIT-2-TRIAGE.md`.

| File | nSLOC | Notes |
|---|---:|---|
| `src/CreditPool.sol` | 445 | Batches, custody, voting, auction, payouts, tiered fees, fee split, points award on assembly |
| `src/AssemblyVault.sol` | 59 | Custody firewall between the pool and the Statements contract |
| `src/CreditStore.sol` | 212 | **New since audit #1:** SCREDIT points, treasury (buy-unsold only), SCREDIT store auction |
| `src/IStatementAssembler.sol` | 4 | **Placeholder** for the unpublished Statements interface |
| `script/Deploy.s.sol` | 47 | Mainnet deploy with parameter guards (canonical addresses, multisig owner) |
| **Total** | **767** | |

Compiler: solc **0.8.28** (pinned), optimizer on, 200 runs, default (non-IR) pipeline.
Dependencies: OpenZeppelin Contracts **v5.7.0** (`ReentrancyGuard`, `Ownable2Step`, ERC-721 interfaces).

**Out of scope:**
- `external/credits/`: Jack's verified Credits source, included read-only so the integration can be checked.
- `app/`: static frontend. In scope for a separate web review if wanted; not for the contract audit.
- `test/`, `script/DeployLocal.s.sol`, `script/DeployFork.s.sol`, `demo-fork.sh`, `simulate-*.py`, `serve.py`: test and demo tooling.

## 3. Actors and trust

| Actor | Powers | Trusted? |
|---|---|---|
| Depositor | deposit / withdraw own Credits while Filling; vote; claim own share | No |
| Bidder | bid; withdraw own refunds | No |
| Anyone | assemble a full batch; start / settle auctions; sweep fees to `feeRecipient` | No |
| Owner | `setFeeRecipient` only (two-step ownership; `renounceOwnership` disabled) | Minimal: cannot touch Credits, bids or proceeds, or Statements held by the pool (the store owner's discretion over treasury-held Statements is AR-11/AR-25) |
| Statements contract (`assembler`, immutable) | burns the 80 Credits the vault holds during one `assemble` call | **Trusted to mint a Statement**, but custody does not depend on it (see invariant C3) |
| Chainlink ETH/USD (immutable) | prices the $1 fee | Trusted for the fee only; if it is stale or down, deposits use `fallbackFeeWei` (frozen at deploy) instead of stopping |

No upgradeability, no pause, no admin withdrawal. Every address above is immutable except `feeRecipient` and the owner.

## 4. Invariants (what must always hold)

**ETH**
- E1. `address(pool).balance ≥ live high bids + Σ pendingReturns + Σ unclaimed proceeds shares + accruedFees`.
- E2. A bidder can always recover an outbid bid; nobody can withdraw another's bid, refund or share.
- E3. Per settled batch: fee + Σ shares ≤ winning bid, with at most 79 wei of rounding dust.

**Credits and Statements**
- C1. Every Credit the pool holds is attributed to exactly one depositor in exactly one Filling or Full batch.
- C2. A Credit leaves the pool only to its own depositor (withdraw) or by being burned in its own batch's assembly.
- C3. During `assemble`, the Statements contract can reach only the 80 Credits of the batch being assembled. The pool never approves anyone; the vault is empty before and after every call.
- C4. Each assembled batch owns exactly one Statement, distinct from every other batch's, held by the pool until redeem or settle.
- C5. A Statement leaves the pool only to a sole 80-slot holder (redeem) or to the auction winner (settle).

**Governance**
- G1. The reserve is the lowest price that more than 40 of the 80 slots accept; a minority cannot lower it.
- G2. No one can force a sale on a sole 80-slot holder.

These are exercised by the handler invariants in `test/Invariant.t.sol` and `test/custody/` (E1, C1, C2, C4) and by targeted tests.

## 5. Known issues (please don't re-report)

The full, maintained list is `.claude/skills/creditpool-audit/references/creditpool-known-state.md`:
- **Design choices DI-1..8:** immutable wiring, one slot per Credit regardless of rarity,
  deposit-order batches, withdraw only while filling, majority pricing, permissionless
  assembly, pull payments, deposits via `transferFrom`.
- **Fixed during internal review CP-1..CP-22:** each has a regression test.
- **Accepted residuals AR-1..9:** e.g. 1-wei auctions by a >50% coalition (the minority can
  outbid), rounding dust, CDN frontend, deposit size vs the per-tx gas cap, stale ids on
  dissolved batches, plain `transferFrom` NFTs stuck, Statement delivered with `transferFrom`.
- **Blocked on Statements OK-1..5:** see below.
- **External audit #1** (on `audit-prep-1`): triage and fixes in `docs/EXTERNAL-AUDIT-1-TRIAGE.md` (CP-23..27).

## 6. Blocked on Statements (the most important thing to review once it exists)

The only external call with custody implications is `AssemblyVault.assemble → IStatementAssembler.assemble`.
The placeholder assumes: *takes 80 ids, burns them from `msg.sender` via Credits `burn(owner, ids)`
(which needs approve-for-all), mints one Statement to `msg.sender`, returns its id.* When the real
contract is published, confirm:
1. It accepts a contract caller (no EOA / `tx.origin` checks). **If not, the pool cannot work.**
2. It needs no off-chain signature (e.g. tied to an X account).
3. It has no per-address Statement limit (the vault is one address for every batch).
4. It mints to `msg.sender` (the vault), not `tx.origin`.
5. It burns rather than escrows Credits (`AssemblyVault._burned` assumes `ownerOf` reverts).
6. Statement transfers aren't restricted in a way that breaks `redeem` / `settle`.
7. Cap behaviour (1,526 Statements): add a deposit guard so batches can't fill after the cap.
8. **Order and colour decide the print** (Jack, Sep 27). Confirm how order maps to the output and
   whether the call takes an order/direction parameter; the planned arrangement vote passes an ordered
   list checked to be exactly the batch's 80 ids. See `docs/STATEMENTS-DESIGN.md`.
9. **Layering** onto existing Statements: who may layer, whether a layer mints, and how it affects the
   vault's "exactly one new Statement" check.
10. Any randomness inside Statements must not be influenced by the (permissionless) `assemble` caller.

## 7. Build, test, analyze

```bash
forge build
forge test                                                        # 164 local tests
MAINNET_RPC=<rpc> forge test --match-contract Fork                # real Credits on a mainnet fork
forge coverage --no-match-contract Fork --no-match-path "test/custody/NftCustody.t.sol" --report summary
```

- `test/custody/NftCustody.t.sol` imports Jack's real `Credits.sol`, which needs via-IR;
  `foundry.toml` scopes via-IR to `external/credits/**` only, so the audited contracts
  compile on the default pipeline.
- Coverage (`src/CreditPool.sol`, excluding the via-IR suite): 99% lines, 97% functions.
  The remaining custody branches are covered by the NFT custody suite.
- Static analysis: Slither 0.11.6; triage in `docs/STATIC-ANALYSIS.md` (no true positives).
- Gas on a mainnet fork with real Credits: deposit ≈ 100k per Credit; `assemble` ≈ 4.25M.

## 8. Prior review

- `docs/FUSED-AUDIT.md`: internal fused audit #1 (10 specialists + adversarial verification), 2026-09-24.
- `test/custody/`: custody deep dive, 56 attack tests + ETH-solvency and NFT-ownership invariants.
- `docs/FUSED-AUDIT-2.md`: internal fused audit #2 after fixes, 2026-09-25.
- All findings from these are fixed or listed as accepted/blocked in the known-state file.

## 9. Deployment parameters

`script/Deploy.s.sol` refuses to run unless: chain is mainnet (or every address is overridden),
Statements and Credits have code, `FEE_RECIPIENT` and `OWNER` are non-zero, the feed has 8 decimals
and is fresh, and `ASSEMBLY_OPENS_AT` is within [-30, +90] days of now. `OWNER` (a multisig) must
call `acceptOwnership()` after deploy.
