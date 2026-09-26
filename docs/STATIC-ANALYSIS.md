# Static analysis

**Tool:** Slither 0.11.6, run on 2026-09-25 against `src/` and `script/`, excluding `lib/`, `test/` and `external/`:

```bash
slither . --filter-paths "lib/|test/|external/" --exclude-dependencies
```

**Result: no true positives.** Every detector hit is triaged below. The two real improvements it
suggested (checks-effects-interactions ordering in `_deposit`, explicit zero initialisation)
were applied (known-state CP-22).

| Detector | Hits | Where | Verdict |
|---|---:|---|---|
| reentrancy-balance (High) | 7 | `CreditPool.assemble`, `AssemblyVault.assemble` | **By design.** These are the custody checks: read a balance, call out, require it changed by exactly the expected amount. The "stale" pre-call value is the point of the comparison. Both functions are `nonReentrant` (the vault is callable only by the pool). |
| reentrancy-no-eth (Medium) | 3 | `_deposit`, `withdraw`, `assemble` | Not exploitable. All three are `nonReentrant`; Credits `transferFrom` makes no receiver callback. In `_deposit` and `withdraw` the hit is loop-carried: the next iteration's writes follow the previous iteration's transfer. Each iteration itself follows checks-effects-interactions. |
| unused-return (Medium) | 2 | `depositFee` (`latestRoundData`), `AssemblyVault._burned` (`ownerOf`) | Intended. Only `answer` and `updatedAt` are used (Chainlink no longer recommends `answeredInRound`). `_burned` only cares whether `ownerOf` reverts. |
| reentrancy-benign (Low) | 5 | `assemble`, `_deposit` | Benign, as reported. |
| calls-loop (Low) | 5 | `_deposit`, `withdraw`, `assemble`, vault checks | Bounded: at most 80 Credits per batch; deposits are chunked at 100 per transaction by the frontend. A revert affects only the caller's own transaction. |
| timestamp (Low) | 6 | auction timing, escape hatch, 30-day fallback, oracle age | Intended. All windows are hours to days; validator timestamp drift (seconds) doesn't matter. |
| costly-loop (Info) | 1 | `_removeDepositor` | Bounded by 80 depositors per batch. |
| low-level-calls (Info) | 1 | `_send` | Intended: ETH transfer with the result checked. |
| missing-inheritance (Info) | 1 | `AssemblyVault` matches `IStatementAssembler`'s shape | Coincidence of signatures; the vault is not an assembler. |

Not yet run: Aderyn, Semgrep,
Echidna/Medusa. Foundry handler invariants cover E1, C1, C2 and C4 (see `docs/AUDIT-SCOPE.md`).
