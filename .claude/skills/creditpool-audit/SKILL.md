---
name: creditpool-audit
description: >-
  The audit system for Credit Pool (credit.pool): src/CreditPool.sol and
  src/AssemblyVault.sol, which pool Jack Butcher's Credits (ERC-721, Ethereum mainnet)
  into 80-slot batches, burn each into a Statement through an isolated vault, and sell it
  by on-chain English auction with slot-weighted reserve voting, plus the deploy scripts
  and the app/ frontend. Runs blind specialists fed by public checklists (evm-audit-skills,
  scv-scan, QuillShield, Cyfrin, ethskills, OpenZeppelin), adversarially verifies every
  medium+ finding, and reports only what is new against a known-state baseline. USE THIS
  whenever asked to audit, security-review, threat-model, or sanity-check the contracts, a
  diff to them, a deploy script, or the frontend; after wiring in the real Statements
  contract; before any mainnet deploy; or when an external audit report needs triage.
---

# Credit Pool fused audit

Runs blind specialists over the contracts, scripts and frontend, verifies every medium+
finding adversarially against the real code, then reports only what is NET-NEW versus the
known-state baseline in `references/creditpool-known-state.md` (fixed findings CP-1..22,
accepted residuals AR-1..9, and the open items OK-1..5 blocked on the Statements contract).

Checklists alone are not enough: the second internal audit beat the first version of the
assembly custody check with a swap no checklist names. Read `references/methodology.md`
before choosing what to run.

## When to use

- Auditing `src/`, `script/*.s.sol`, or `app/`.
- **Right after the real Statements contract is wired in.** That change touches the
  most trusted call in the system; run the full audit, not a diff review.
- Reviewing a diff before it ships (scope the specialists; see Diff review).
- Before any mainnet deploy, or when the user asks "is this safe / ready to ship".
- When a third-party audit report arrives: `references/methodology.md` §6.

## How to run it

### Full audit (default for "audit it all" / pre-deploy)

1. **Setup (once).** From `credit-pool/` (the git root), clone the sources into
   `.audit-cache/` (git-ignored). Commands: `references/sources-and-routing.md`.
2. **Run the workflow.** `references/fused-audit.workflow.js` is a ready Workflow script:
   10 specialists (Review) → one adversarial refuter per medium+ finding (Verify) → lead
   synthesis. Check `const REPO` (flagged `// EDIT`), then call
   `Workflow({ scriptPath: "<REPO>/.claude/skills/creditpool-audit/references/fused-audit.workflow.js", args: { report: "docs/FUSED-AUDIT-<n>.md" } })`
   with the absolute `<REPO>` path. Requires explicit multi-agent opt-in from the user.
   Expect roughly 12-25 agents.
3. **Read the synthesis, then the report.** Only NET-NEW findings need action.
4. **Triage NET-NEW against the known state** before acting: many "findings" are
   deliberate design (immutable wiring, majority-set reserve, one slot per Credit,
   permissionless assembly). Confirm each is a real deviation.
5. **Fix, then re-gate.** Apply fixes, add a test that fails without the fix, then run
   the full gate and paste the result. Never claim green without running it:
   ```bash
   forge build --force && forge test
   MAINNET_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract Fork
   ```
6. **Update the baseline.** Add newly fixed items to `creditpool-known-state.md`
   (next CP-n) and the README security table, so the next run doesn't re-report them.

### Diff / PR review (default for "review this change")

1. `git diff` the change; list touched files.
2. Map them to specialists with the routing table in `references/sources-and-routing.md`
   and run only those (a filtered copy of `SPECIALISTS`, or direct `Agent` calls using
   `reviewPrompt`'s structure). A small change usually needs 1-3 specialists.
3. Same verify + known-state triage as above.

### Cheap passes (no fan-out)

From `references/methodology.md`: the units pass, checking what each custody guard really
proves, Slither with written triage, and extending the handler invariants.

## The method

- **Blind specialists.** Each reads its checklists, then the targets, and is told NOT to
  read the README security table, `test/Attacks.t.sol`, or this skill. Reading the answer
  key first biases the search; baseline comparison happens only in synthesis.
- **Extract intent, then find the deviation,** with exact `file:line` evidence and a
  concrete failure scenario. No pattern-match-only findings.
- **scv false-positive filters up front,** applied before reporting.
- **Adversarial verify.** Every medium+ finding goes to an agent told to REFUTE it against
  the real code, defaulting to REFUTED unless a concrete path holds.
- **Synthesis is the value.** Dedupe by root cause, classify against the baseline,
  net-new first.

## Reference files

- `references/creditpool-known-state.md`: the baseline. What the system is, design
  invariants, fixed findings, accepted residuals, open items blocked on Statements, and
  proven facts. Synthesis only; specialists never read it.
- `references/sources-and-routing.md`: the public checklist sources with clone commands,
  and the 10-specialist routing table.
- `references/fused-audit.workflow.js`: the runnable workflow.
- `references/methodology.md`: the passes checklists miss, and how to triage an external report.
- `docs/AUDIT-SCOPE.md` (repo): the package handed to external auditors.
- `external/credits/` (repo): Jack's verified Credits source, so specialists can read
  the exact code the pool integrates with.

## Guardrails

- Never read, print, or ask for private keys, keystore passwords, or `.env` files.
  The anvil keys in `app/app.js` are Foundry's public test keys, gated to chain 31337.
- The user signs every mainnet transaction. This skill audits; it never deploys,
  broadcasts, or moves funds, and an audit result never triggers a deploy.
- The pool must not be deployed to mainnet until the real Statements contract is
  published, wired in, and audited with this skill (known-state OK-1, OK-3).
- Run fork tests only against public RPCs or ones the user provides; never paste an
  RPC URL containing an API key into a report.
