# Sources and routing

The public checklists the audit workflow reads, how to fetch them, and which specialist
reviews which file.

## Setup: clone the sources

Run from `credit-pool/` (the git root). Sources land in `.audit-cache/`, which is git-ignored.

```bash
SC="$(git rev-parse --show-toplevel)/.audit-cache"
mkdir -p "$SC" && cd "$SC"
[ -d evm-audit-skills ] || git clone --depth 1 https://github.com/austintgriffith/evm-audit-skills.git evm-audit-skills
[ -d scv ]              || git clone --depth 1 https://github.com/kadenzipfel/scv-scan.git scv
[ -d quill ]            || git clone --depth 1 https://github.com/quillai-network/quillshield_skills.git quill
[ -d solskill ]         || git clone --depth 1 https://github.com/Cyfrin/solskill.git solskill
[ -d ethskills ]        || git clone --depth 1 https://github.com/austintgriffith/ethskills.git ethskills
[ -d ozskills ]         || git clone --depth 1 https://github.com/OpenZeppelin/openzeppelin-skills.git ozskills
```

Upstream repos sometimes move files. If a path in `fused-audit.workflow.js` is missing after
cloning, find the moved file under `.audit-cache/` and update the path constant.

## The sources

| Source | Repo | What it contributes | Paths used |
|---|---|---|---|
| **evm-audit-skills** | austintgriffith/evm-audit-skills | Domain checklists: access control, DoS, precision math, ERC-721, oracles, plus a master skill | `evm-audit-skills/evm-audit-<domain>/references/checklist.md`, `evm-audit-skills/evm-audit-master/SKILL.md` |
| **scv-scan** | kadenzipfel/scv-scan | Vulnerability classes, each with explicit false-positive conditions applied before reporting | `scv/references/<class>.md` |
| **QuillShield** | quillai-network/quillshield_skills | Analysis methods: semantic guards, state invariants, external calls, DoS/griefing, input arithmetic, deploy readiness | `quill/plugins/<name>/skills/<name>/SKILL.md` |
| **Cyfrin solskill** | Cyfrin/solskill | Secure Solidity development practices | `solskill/skills/solidity/SKILL.md` |
| **ethskills** | austintgriffith/ethskills | Cross-cutting security lens used in synthesis | `ethskills/security/SKILL.md` |
| **OpenZeppelin skills** | OpenZeppelin/openzeppelin-skills | Secure contract development lens used in synthesis | `ozskills/skills/develop-secure-contracts/SKILL.md` |

Optional, for the passes in `methodology.md`: Trail of Bits' public skills
(`https://github.com/trailofbits/skills`) for dimensional analysis, variant analysis,
static analysis and property-based testing.

## Specialist -> target routing (Credit Pool)

10 specialists. Each reads its checklists in full, then its targets. For a **diff
review**, run only the specialists whose targets include a touched file.

Paths are relative to `credit-pool/`. `external/credits/` is Jack's verified Credits
source (read-only context, not ours to fix, but our integration with it is in scope).

| # | Specialist | Sources (beyond the checklist) | Targets |
|---|---|---|---|
| 1 | **Access control / guards** | access-control, quill semantic-guard, scv insufficient-access / tx-origin | `src/CreditPool.sol` (every external fn: who may call it, in which `BatchState`) |
| 2 | **State machine / batch lifecycle** | quill state-invariant, evm-audit master | `src/CreditPool.sol` (`BatchState` transitions: Filling → Full → Assembled ⇄ Auction → Settled / Redeemed; Full → Dissolved), `test/Invariant.t.sol` |
| 3 | **ETH flows / external calls / reentrancy** | quill external-call-safety, scv unchecked-return / unsafe-low-level / reentrancy | `src/CreditPool.sol` (`_send`, `deposit` refund, `bid`/`withdrawRefund`, `claim`, `sweepFees`, `assemble` external call) |
| 4 | **ERC-721 integration** | erc721, scv inadherence-to-standards | `src/CreditPool.sol` (`transferFrom` in/out, `onERC721Received`, approval to assembler, Statement receipt check), `external/credits/Credits.sol` |
| 5 | **Precision / fees / payouts** | precision-math, quill input-arithmetic, scv lack-of-precision / off-by-one / overflow | `src/CreditPool.sol` (`depositFee` decimals, `SALE_FEE_BPS`, claim split, `MIN_BID_INCREMENT_BPS`, weighted median in `currentReserve`) |
| 6 | **Oracle / time** | oracles, scv timestamp-dependence / transaction-ordering | `src/CreditPool.sol` (Chainlink staleness + sign, `ESCAPE_DELAY`, `NO_RESERVE_AFTER`, `AUCTION_DURATION`, anti-snipe `AUCTION_EXTENSION`, `assemblyOpensAt`) |
| 7 | **Auction & governance game theory** | quill dos-griefing, scv transaction-ordering; no checklist fits fully, so reason adversarially | `src/CreditPool.sol` (reserve voting, quorum, start/settle races, self-dealing, shill bidding, griefing via deposit/withdraw churn) |
| 8 | **DoS / gas limits** | dos, scv dos-revert / dos-gas-limit / insufficient-gas-griefing | `src/CreditPool.sol` (loops over depositors/credits, `currentReserve` sort, deposit array size vs the 2^24 per-tx gas cap, revert-on-send paths) |
| 9 | **Deploy readiness + Statements integration** | quill defender, solskill, scv incorrect-constructor | `script/Deploy.s.sol`, `src/CreditPool.sol` (constructor, immutables, `IStatementAssembler` placeholder), `external/credits/`, `README.md` launch checklist |
| 10 | **Frontend / transaction construction** | (focus brief, no checklist) | `app/app.js`, `app/config.js`, `app/index.html` (ABI vs `src/`, approval scope, value/fee math, chain gating of `?dev=`/`?as=`, XSS sinks incl. on-chain SVG/tokenURI, CDN supply chain) |

Coverage note: `src/CreditPool.sol` is the only production contract; every function
is owned by at least one specialist. If Statements integration code is added, route
it to #4, #9 and #3 before running.
