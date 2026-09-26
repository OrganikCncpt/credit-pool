# Methodology beyond checklists

Checklists find bugs that belong to a known vulnerability class. The costly bugs in a
contract like Credit Pool often don't: they live at a seam (a unit that differs between two
places, a check that counts the right number of the wrong thing). These passes target that.
Run them in this order; each is cheap next to the full specialist fan-out.

## 1. Units pass

Annotate every value with its unit, then check every expression converts correctly.

Credit Pool's units:
- **USD at 8 decimals:** `DEPOSIT_FEE_USD = 1e8` means $1.00.
- **Feed answer at `decimals()`:** 8 on mainnet ETH/USD. Never assume 8; the code reads it.
- **wei:** the fee, bids, refunds, proceeds.
- **bps out of 10,000:** `SALE_FEE_BPS`, `MIN_BID_INCREMENT_BPS`.
- **slots out of 80:** `slots[b][who]`, the reserve quorum.
- **Credit count:** `depositFee() × creditIds.length`.
- **seconds:** `ORACLE_MAX_AGE`, `ESCAPE_DELAY`, `AUCTION_DURATION`, `AUCTION_EXTENSION`,
  `NO_RESERVE_AFTER`, and `ASSEMBLY_OPENS_AT`, which is set at deploy time and a classic
  place for a milliseconds-vs-seconds slip.

Surfaces to annotate: `depositFee`, `_deposit`, `settle` (fee and proceeds), `claim`,
`bid` (min raise), `currentReserve` / `lowestVote`, every time comparison, and the env reads
in `script/Deploy.s.sol`. A finding is any expression whose two sides disagree on unit.

## 2. Check what a guard actually proves

For each custody check, write down the property it is meant to guarantee, then try to
construct a state where the check passes and the property is false. Counting checks are the
usual weak spot: "the balance dropped by 80" does not prove "these 80 left and nothing else
moved". (That is exactly how the second internal audit beat the first version of the
assembly check; the fix was structural isolation in `AssemblyVault`, not a better count.)

## 3. Variant sweep

After any confirmed finding, search the whole codebase for the same shape before closing it:
the same pattern in another function, the same assumption in the frontend, the same parameter
in a deploy script. Record each hit as fixed, not applicable (with the reason), or a new finding.

## 4. Static analysis

- **Slither** (Trail of Bits): `slither . --filter-paths "lib/|test/|external/" --exclude-dependencies`.
  Every hit must end in a written verdict; see `docs/STATIC-ANALYSIS.md`. An untriaged
  scan proves nothing.
- **Semgrep / Aderyn:** optional second opinions; not yet run.

## 5. Property testing

`test/Invariant.t.sol` and `test/custody/` hold Foundry handler invariants for ETH solvency
and NFT ownership (see `docs/AUDIT-SCOPE.md` §4). When the contract changes:
- Keep every handler able to reach every state. Log call counts per action and fail if an
  action never succeeds, or the invariant proves nothing.
- Add a property for any new guarantee before relying on it.
- Echidna / Medusa are optional second engines for the same properties.

## 6. Triage of an external audit report

When a third-party report arrives:
1. **Classify each finding** against `creditpool-known-state.md`: NET-NEW, ALREADY-FIXED,
   ACCEPTED-RESIDUAL, DESIGN-INVARIANT, OPEN-KNOWN, or FALSE-POSITIVE.
2. **Reproduce before accepting.** Write a failing Foundry test for every claimed
   medium-or-higher issue. A claim that can't be reproduced against the real code is not
   accepted, however confident it sounds.
3. **Check claims about "missing" things** (a missing check, a script that never wires a
   value) by searching the whole repo. Single-file reviewers often miss code elsewhere.
4. **Verify the proposed fix separately from the finding.** A correct finding can come with
   a fix that breaks the protocol (for example, switching `settle` to `safeTransferFrom`
   would let a malicious winner block settlement for every depositor; see AR-9).
5. After fixing, add the item to the known-state file and the README security table.
