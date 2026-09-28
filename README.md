# credit.pool

Deposit Credits, not ETH. Every 80 deposited Credits burn into one Statement, held for the depositors of that batch.

## Flow
1. **Deposit**: `setApprovalForAll(pool)`, then `deposit(ids)` with `depositFee() × number of Credits` in ETH ($1 per Credit via Chainlink ETH/USD, excess refunded; `depositAt` adds a front-run guard). Credits fill sequential 80-slot batches and overflow into the next one.
2. **Withdraw**: Credits can be withdrawn from the open batch at any time. Full batches are locked.
3. **Assemble**: anyone can call `assemble(batchId)` on a full batch.
4. **Settle**:
   - A depositor holding all 80 slots can `redeem` the Statement directly.
   - Otherwise depositors `setReserve`. The reserve is the lowest price that more than 40 of the 80 slots have voted at or below; once such a price exists, anyone can `startAuction`. A minority voting low can't drag it down.
   - Auctions run 24h with a 5% minimum raise and a 15-minute anti-snipe extension. `settle`, then each depositor calls `claim` for (slots / 80) × sale price. With no bids, the batch returns to voting.
   - If the Statement is still unsold 30 days after assembly, anyone can start a **no-reserve** auction. A majority can't trap the minority with an unreachable reserve.
5. **Escape hatch**: a full batch that can't be assembled (cap reached, contract blocks vaults) becomes withdrawable 14 days after it filled or assembly opened, whichever is later. Assembly stays possible until someone actually withdraws.

Fees (all constants; in ETH via Chainlink ETH/USD):
- Deposit: $2 per Credit, or $1 per Credit for a deposit of 6+ in one transaction (`depositFeeFor(n)`).
  `sweepFees` (permissionless) splits it: 25% to `feeRecipient`, 75% to the store's treasury.
- Auction sales carry **no fee**: depositors split 100% of the price.

The store (`src/CreditStore.sol`):
- **SCREDIT** ("Store Credit"): 2 non-transferable points per Credit deposited (`transfer`/`approve` revert).
- **Treasury** (75% of deposit fees): spent only by `buyUnsold(batch)`, owner-triggered, and only for a batch
  whose pool auction already ended with no bids. It opens a new auction with a bid at exactly the depositors'
  own minimum, capped by `maxTreasuryBid`; anyone can outbid it for 24h. No function sends treasury ETH anywhere else.
- **Store auction**: Statements the treasury holds are auctioned for SCREDIT only (24h, +5%, 15-min anti-snipe).
  Every bid pays a $0.25 platform fee in ETH (`sweepBidFees` → `feeRecipient`). Outbid points come straight
  back; the winner's points are burned.

## Before deploying
- `IStatementAssembler` is a **placeholder**. Replace it with the real Credits/Statement interface once it's published.
- Credits (mainnet, verified): `0x97630aA70AB14ed9883B41dAfccBc11349723043`. Standard ERC-721, sealed 2026-09-23, supply 122,154. Its only burn is `burn(owner, ids)`, which needs the caller to be the owner or approved-for-all. The pool already approves the assembler just before assembly, so it fits this.
- The Statements contract isn't published yet. Confirm it's ERC-721 and can be sent to contracts.
- Mainnet ETH/USD feed: `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` (verify on data.chain.link).
- Get an audit. Get legal review of the auction and proceeds split.

## Security review (self-audit, not a substitute for a real one)
Attack tests: `test/Attacks.t.sol`. Invariant fuzzing: `test/Invariant.t.sol`.

| Finding | Status |
|---|---|
| Oracle max age = Chainlink 1h heartbeat, so deposits reverted at every heartbeat edge | Fixed: 1 day max age (fee is $1) |
| Credits/NFTs sent via `safeTransferFrom` got stuck | Fixed: the pool rejects every NFT except the Statement mid-assembly |
| A buggy assembler could "return" a Statement the pool already held | Fixed: Statement balance must rise by exactly 1 |
| A >50% holder could trap the minority with an unreachable reserve | Fixed: no-reserve auction after 30 days unsold |
| Escape hatch blocked late assembly, so one depositor could veto an unassembled batch | Fixed: assembly allowed until the first escape withdrawal |
| Zero-value bids after a no-reserve start | Fixed: bids must be > 0 |
| >~115 Credits in one deposit exceeds Ethereum's 16.7M per-tx gas cap | Frontend chunks at 100/tx. Storage packing cut gas ~27% (80 real Credits: 11.4M → 8.3M) |
| A >50% coalition can start a 1-wei auction immediately | By design: 24h public English auction, minority can outbid (UI says so) |
| Deposits after the 1,526 Statement cap still fill and lock for 14 days | Open: needs the Statements interface (see checklist) |
| **Fused audit + custody deep dive (2026-09-24)**: see `docs/FUSED-AUDIT.md`, `test/custody/` | 0 critical/high/medium. 56 custody attack tests + ETH-solvency and NFT-ownership invariants: no way found to steal bids or deposited Credits |
| Assembler could take other batches' Credits or burn wrong ids with its temporary approval | Fixed: `assemble` verifies exactly this batch's 80 left the pool |
| Statement id could be double-assigned by a buggy assembler (N1) | Fixed: `statementAssigned` + hook/return-id agreement |
| A minority could set the reserve by voting low as quorum was crossed (N2) | Fixed: reserve = lowest price that >40 of all 80 slots accept |
| Front-run deposit could split a solo batch (N3) | Fixed: `depositAt` with expected batch state (frontend uses it) |
| No-reserve path could force a sale on a sole holder (N4) | Fixed |
| Zero fee recipient; unchecked deploy script (N5) | Fixed: constructor check; deploy script validates chain, feed, recipient, date; optional multisig `OWNER` |
| Stale reserve in UI confirm, double-submit, 1-wei bid step, missing events (N6, N7, N9, N10) | Fixed |
| **Fused audit #2 (2026-09-25)**: see `docs/FUSED-AUDIT-2.md` | 0 critical/high; 2 medium, 4 low, 3 info, all fixed |
| Assembler could beat the balance check by swapping a Credit (N-1) | Fixed: `AssemblyVault` holds only the batch being assembled; the pool never approves the assembler |
| Front-run guard and auction-start price not enforced end to end (N-2, N-4) | Fixed: snapshot before confirm; `startAuctionAt` enforces the confirmed price on-chain |
| 30-day fallback ignored even a unanimous price (N-5) | Fixed: fallback minimum is the lowest vote cast |
| Deploy date unbounded; single-step renounceable ownership; floating pragma (N-6, N-7, N-9) | Fixed |
| Statement delivered with `transferFrom` (N-8) | Accepted: `safeTransferFrom` would let a malicious winner brick settlement |
| Assembler gets `setApprovalForAll` on the pool's Credits during `assemble` | Accepted: it's the official Statements contract; approval is revoked in the same tx |
| Claim rounding leaves < 80 wei per batch | Accepted |

Measured on a mainnet fork: deposit ≈ 100k gas per Credit; assembling 80 real Credits ≈ 1.5M gas.

## External audit
Start with `docs/AUDIT-SCOPE.md` (scope, trust model, invariants, known issues, build/test).
Static analysis triage: `docs/STATIC-ANALYSIS.md`. CI: `.github/workflows/ci.yml`.

## Layout
- `src/CreditPool.sol`: the pool
- `src/AssemblyVault.sol`: custody firewall; the only thing the Statements contract ever touches
- `src/IStatementAssembler.sol`: PLACEHOLDER interface for the unpublished Statements contract
- `test/CreditPool.t.sol`: unit tests with mocks (`test/Mocks.sol`)
- `test/CreditPool.fork.t.sol`: deposits, withdraws and burns **real** Credits on a mainnet fork
- `script/Deploy.s.sol`: mainnet deploy
- `script/DeployLocal.s.sol`: anvil stack with mocks and Credits minted to test wallets
- `app/`: static frontend (no build step; viem from CDN). Addresses live in `app/config.js`

## Test
```
forge test                                                              # unit tests
MAINNET_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract Fork   # real Credits
```

## Run locally
```
anvil
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
python3 serve.py   # no-cache static server for app/
```
Open `http://localhost:5173/?dev=0` (or `dev=1..3`; `dev=3` holds 250 Credits) to act as an anvil account without a wallet.
Skip auction time with `cast rpc evm_increaseTime 90000 && cast rpc evm_mine`.

Mainnet-fork demo with real Credits, 50 simulated depositors, and step-by-step auction tooling:
```
./demo-fork.sh && python3 simulate-participants.py && python3 serve.py
python3 simulate-auction.py status 0        # also: fill, assemble, vote, start, bid, war, skip, settle, claim
```
End-to-end concept test (fresh fork; every lifecycle path with money and NFTs checked, 33 checks):
```
./demo-fork.sh && python3 e2e-concept.py
```

## Testnet (Sepolia)

A full public rehearsal: Jack's real `Credits` source, loaded with real mainnet seeds (same
art), a stand-in Statements contract that burns through the real `burn(owner, ids)`, and
CreditPool on Sepolia's Chainlink ETH/USD feed.

```bash
python3 script/export-testnet-seeds.py 4200 > script/testnet-seeds.json   # already committed
TESTERS=0xA…,0xB… COUNTS=80,40 FEE_SCALE=100 FUND_WEI=6000000000000000 FEE_RECIPIENT=0x… \
forge script script/DeployTestnet.s.sol --tc DeployTestnet --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast --slow --interactives 1
```

- `COUNTS`: Credits per tester (or `PER_TESTER` for all). `FUND_WEI`: gas money sent to each tester.
- `FEE_SCALE=100` makes the deposit fee $0.01 for testing: the pool reads a `ScaledFeed` that passes
  Chainlink through with the price ×100 (timestamps untouched, so the stale fallback still works).
  Set `feeUsd: 0.01` on the chain in `app/config.js` so the site shows the right dollars.
- Then set `pool` and `deployBlock` for chain 11155111 in `app/config.js` (and `DEFAULT_CHAIN`).
- Gas: about 149k per Credit minted (`distribute` is chunked at 80 mints, max 11.9M gas per tx,
  well under the 16.77M cap), plus about 11M for the contracts. 4,080 Credits ≈ 617M gas.
- Don't use anvil's default keys as testers on Sepolia: they are public and delegated to sweepers.

Full-scale local rehearsal (a copy of Sepolia on anvil, chain 31337, so the demo modes work):

```bash
TESTERS=<you>,<100 burners> COUNTS=80,40,…,40 FEE_SCALE=100 ./demo-testnet.sh
python3 simulate-burners.py burners.txt   # every batch state: sold, live, voting, full, filling
python3 serve.py                          # http://localhost:5173/?as=<your address>
```

## Launch checklist (once Statements is live)
1. Swap `IStatementAssembler` in `src/CreditPool.sol` for the real call. Mirror it in `test/Mocks.sol` and `ForkStatements` in the fork test.
   - If Statements exposes a supply or cap, make `deposit` revert once the cap is hit (open finding above).
   - If it rejects contract callers, the pool can't work. Check this first.
2. `forge test` + the fork test.
3. `STATEMENTS=0x.. ASSEMBLER=0x.. FEE_RECIPIENT=0x.. ASSEMBLY_OPENS_AT=<unix> forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC --account deployer --broadcast --verify`
4. Put the pool address and deploy block in `app/config.js` under chain `1`, and set `DEFAULT_CHAIN = 1`.
5. Host `app/` anywhere static (Vercel, Netlify, IPFS).
