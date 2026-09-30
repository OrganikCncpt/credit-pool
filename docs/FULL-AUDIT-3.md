# Full audit #3 (internal)

**Date:** 2026-09-30. **Baseline:** commit `65d1410`, the whole system:
- `src/CreditPool.sol`, `src/AssemblyVault.sol`, `src/CreditStore.sol`, `src/IStatementAssembler.sol`;
- the deploy scripts;
- the `app/` frontend.

**Method:** the `creditpool-audit` skill.
- **Six blind specialists**, each working in an isolated copy with Foundry PoCs and not shown earlier audit results:
  1. ETH custody and reentrancy
  2. NFT custody and the vault
  3. Auction, governance and oracle
  4. Store, points and owner powers
  5. Fees, DoS and gas
  6. Deploy scripts and frontend
- **Slither** re-run with manual triage (`docs/STATIC-ANALYSIS.md`).
- **Fixes:** every medium-or-higher finding was fixed with a regression test.
- **Verify pass:** an adversarial verifier attacked all six fixes with 10 PoCs. All held and it found no regressions. It also confirmed that the first CP-46 approach (a timestamp heuristic) was broken, which is why the fix uses the recorded flag.
- **Not an external audit.**

## Findings and fixes

| ID | Sev | Finding | Found by | Fix / test |
|---|---|---|---|---|
| CP-44 | **Medium** | Points were awarded when a batch filled and kept if it dissolved via the 14-day escape hatch. A whale filling a batch alone (or anyone, once the Statement cap is reached) could cycle the same 80 Credits for 160 points every 14 days. | store, DoS, game (3 of 6) | Points are awarded in `assemble()`, so only Credits burned into a Statement earn them. `test_DissolvedBatchEarnsNoPoints` |
| CP-45 | **Medium** | After 30 days a 1-slot holder could vote 1 wei, open the fallback auction and dust-bid first, locking the treasury out. | game | In a fallback-opened auction the treasury outbids a bid below the majority price, at exactly the majority price. It never outbids a bid at or above that price. `test_FallbackDustBidCantLockOutTreasury` |
| CP-46 | Medium | *Found while fixing CP-45:* the store inferred "fallback-opened" from `endsAt − 24h`, and anti-snipe extensions move that time. A bidding war could make a normal auction look fallback-opened. | self | The pool records `openedByFallback[b]` when the auction opens. `test_BiddingWarDoesntMakeNormalAuctionLookFallback` |
| CP-47 | Low | Absurd feed prices priced fees off a broken feed, or reverted with overflow. | DoS | Prices outside $10–$10M per ETH are treated as untrusted and use the fallback. `test_AbsurdFeedPricesUseFallback` |
| CP-48 | Info | A gas-burning fee wallet could make `sweepFees` revert on a modest gas budget. | ETH | The fee wallet is paid with a fixed 100k gas and no returndata copy. `test_GasBurningFeeWalletCantStallTreasury` |
| CP-49 | Info | `sweepBidFees` reverted when the fee wallet rejected ETH. | ETH | Bounded call; on failure the fees stay held and are never counted as treasury. `test_SweepBidFeesHoldsOnRejectingWallet` |
| CP-50 | Low | Deploy scripts: `DeployFork` had no chain guard (on mainnet it would wire real Credits to a test Statements). Mainnet deploy accepted non-canonical Credits or feed, and an EOA or the deployer as owner. | deploy | Local scripts are chain-31337 only. Mainnet requires the canonical Credits and feed, and an owner that is a contract and not the deployer. Verified by dry-runs. |
| CP-51 | Info | Frontend: remote token images leaked viewer IPs, a rejected deposit lost the selection, the jump box threw on bad input, no CSP, approval target not pinned, demo server on all interfaces. | frontend | `data:` images only; selection kept on failure; input validated; CSP; mainnet Credits address pinned; `serve.py` bound to localhost. |

## Accepted or documented (no code change)

- **AR-11: owner trust in the treasury.** The owner can route treasury ETH up to the cap per batch by controlling a batch's majority. The cap starts at 0 on mainnet and raises take 3 days. Use a multisig owner.
- **AR-12: non-monotonic fee at 5→6 Credits.** This is the owner's pricing decision. An optional smoothing (1–3 at $2 each, 4–5 at $6 flat, 6+ at $1 each) was offered.
- **AR-18: a plain `deposit` can be front-run to break "sole holder".** The frontend always uses `depositAt`.
- **AR-19: a reserve vote is immediately usable.** Anyone can start the auction just before a raise lands. The vote tooltip now says so.
- **AR-20: `assemble` ignores `assemblyOpensAt`.** Jack's contract gates real assembly.
- **AR-21: `config.js` ships demo entries.** This is a launch-checklist item.
- **OK-11 / S-8 (blocked on Statements): stray Statement swap.** A Statement donated to the vault, plus an assembler that returns a wrong id, could swap a batch's Statement. This gets fixed once we know how Jack's contract mints.
- **Info: claim rounding** leaves under 80 wei per batch.
- **Verifier residuals (by design):**
  - In a fallback auction, a bid between about 95% and 100% of the majority price blocks the treasury, because the pool's +5% step applies. Depositors still get about 95%.
  - The majority can raise its votes after the treasury bids, and the owner may then outbid the treasury's own bid. The old bid is refunded to the store.
  - A fee wallet whose `receive` needs more than 100k gas (e.g. a splitter) has its share held until `setFeeRecipient` changes it. Use a Safe.
  - An EOA with an EIP-7702 delegation has code, so it passes the multisig check. Confirm OWNER is a real Safe.
  - A wallet extension that injects inline scripts would be blocked by the CSP. MetaMask and Rabby are unaffected.

## Verified safe (highlights across specialists)

- **Pool solvency**, fuzzed with a stateful invariant (128 runs, depth 80): balance ≥ live bids + refunds + unclaimed shares + fees + held platform fees.
- **Store solvency:** balance ≥ bid fees + treasury.
- **Reentrancy:** no cross-contract reentry between pool, store and vault.
- **Custody:** the assembler can't reach any Credit outside the batch. Minting two Statements, swapping in an assigned one, or re-entering all fail. Statements leave the pool or the store only by their single intended exit.
- **Points:**
  - Σ balances (including the store's escrow) = total supply;
  - no way around the cap delay;
  - neither owner can take users' ETH, points or NFTs.
- **Gas:** no call can be pushed past the 2^24 per-transaction cap.
  - 100-Credit deposit: 10.8M
  - assemble with the award to 80 depositors: 6.4M
  - worst-case vote sort: 2.6M
- **Frontend:**
  - every ABI matches the compiled contracts;
  - the fees and chunking the site sends match the contracts;
  - no injection sinks;
  - the demo modes are gated to the local chain.

## Test gate after fixes

- **Local:** 154 unit, fuzz and invariant tests.
- **Mainnet fork:** 17 tests with real Credits and the real Chainlink feed, including the store lifecycle.
- **End-to-end:** 38/38 checks on a fresh mainnet fork.
- **Rehearsal:** 100 burners on a local copy of Sepolia.
- **Browser:** the real-Chrome flow of approve → deposit → Assemble → 60 SCREDIT → store bid → raise own bid.
