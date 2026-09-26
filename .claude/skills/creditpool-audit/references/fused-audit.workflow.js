export const meta = {
  name: 'creditpool-fused-audit',
  description: 'Fused external-checklist audit of Credit Pool: 10 blind specialists (evm-audit-skills + scv-scan + QuillShield + Cyfrin + ethskills/OZ), adversarial verify with scv false-positive filters, synthesize net-new vs the known-state baseline',
  phases: [{ title: 'Review' }, { title: 'Verify' }, { title: 'Synthesize' }],
}

const REPO = '/Users/user/Desktop/Credit Pull/credit-pool' // EDIT: absolute path to the repo under audit
const SC = REPO + '/.audit-cache' // audit sources are cloned here first; see SKILL.md > Setup
const EV = `${SC}/evm-audit-skills`
const SCV = `${SC}/scv/references`
const Q = `${SC}/quill/plugins`
const qp = (p) => `${Q}/${p}/skills/${p}/SKILL.md`
const KNOWN = `${REPO}/.claude/skills/creditpool-audit/references/creditpool-known-state.md`
// Pass {report: "docs/FUSED-AUDIT-2.md"} as args to keep earlier reports.
const REPORT = `${REPO}/${(args && args.report) || 'docs/FUSED-AUDIT.md'}`

const CONTEXT = `Credit Pool: holders deposit Jack Butcher's Credits (ERC-721 on Ethereum mainnet, verified source in external/credits/) into sequential 80-slot batches in src/CreditPool.sol (solc ^0.8.24, OpenZeppelin v5). A full batch is burned into one Statement through IStatementAssembler, which is a PLACEHOLDER because the real Statements contract is unpublished. A sole 80-slot holder redeems the Statement; otherwise depositors vote a reserve (slot-weighted median, quorum > 40 of 80 slots) and it is sold by a 24h on-chain English auction (5% min raise, 15-minute anti-snipe extension), proceeds split by slots after a 1% sale fee. $1 deposit fee in ETH via Chainlink ETH/USD. app/ is a static viem frontend.`

// Specialists with no checklist that fits get a focused threat brief instead.
const SPECIALISTS = [
  { key: 'access-guard', name: 'Access control / guards',
    sources: [`${EV}/evm-audit-access-control/references/checklist.md`, qp('semantic-guard-analysis'), `${SCV}/insufficient-access-control.md`, `${SCV}/authorization-txorigin.md`],
    targets: ['src/CreditPool.sol'] },
  { key: 'state-machine', name: 'State machine / batch lifecycle',
    sources: [qp('state-invariant-detection'), `${EV}/evm-audit-master/SKILL.md`],
    targets: ['src/CreditPool.sol', 'test/Invariant.t.sol'],
    focus: 'Enumerate every BatchState transition and the function that causes it. Find any reachable state where funds or NFTs are stranded, a transition is skipped, a batch can be acted on twice (double claim, double settle, redeem after auction), or per-batch bookkeeping (slots, depositors, creditIds, _credit) disagrees with reality.' },
  { key: 'eth-extcall', name: 'ETH flows / external calls / reentrancy',
    sources: [qp('external-call-safety'), `${SCV}/unchecked-return-values.md`, `${SCV}/unsafe-low-level-call.md`, `${SCV}/reentrancy.md`],
    targets: ['src/CreditPool.sol'] },
  { key: 'erc721', name: 'ERC-721 integration',
    sources: [`${EV}/evm-audit-erc721/references/checklist.md`, `${SCV}/inadherence-to-standards.md`],
    targets: ['src/CreditPool.sol', 'external/credits/Credits.sol'] },
  { key: 'precision', name: 'Precision / fees / payouts',
    sources: [`${EV}/evm-audit-precision-math/references/checklist.md`, qp('input-arithmetic-safety'), `${SCV}/lack-of-precision.md`, `${SCV}/off-by-one.md`, `${SCV}/overflow-underflow.md`],
    targets: ['src/CreditPool.sol'],
    focus: 'Run a units pass (see .claude/skills/creditpool-audit/references/methodology.md section 1): USD at 8 decimals, Chainlink answer at feed decimals, wei, bps, slots out of 80, seconds. Check every formula converts correctly and that payouts plus fees never exceed what was paid in.' },
  { key: 'oracle-time', name: 'Oracle / time',
    sources: [`${EV}/evm-audit-oracles/references/checklist.md`, `${SCV}/timestamp-dependence.md`, `${SCV}/transaction-ordering-dependence.md`],
    targets: ['src/CreditPool.sol'] },
  { key: 'auction-game', name: 'Auction & governance game theory',
    sources: [qp('dos-griefing-analysis'), `${SCV}/transaction-ordering-dependence.md`],
    targets: ['src/CreditPool.sol'],
    focus: 'No checklist covers this fully; think like an adversarial depositor, bidder, or whale. Reserve-vote manipulation (vote, start, re-vote), quorum edges, self-dealing, shill bidding, anti-snipe abuse, settle/start races, deposit/withdraw churn to grief a batch, whales filling batches to capture Statements cheaply, the 30-day no-reserve path. Report only concrete value extraction or a broken guarantee to depositors.' },
  { key: 'dos-gas', name: 'DoS / gas limits',
    sources: [`${EV}/evm-audit-dos/references/checklist.md`, `${SCV}/dos-revert.md`, `${SCV}/dos-gas-limit.md`, `${SCV}/insufficient-gas-griefing.md`],
    targets: ['src/CreditPool.sol'],
    focus: 'Ethereum caps a single transaction at 2^24 (16,777,216) gas since Fusaka. Measured on a fork: deposit ~100k gas per real Credit, assemble of 80 ~1.5M with a stand-in assembler.' },
  { key: 'deploy-integration', name: 'Deploy readiness + Statements integration',
    sources: [qp('defender'), `${SC}/solskill/skills/solidity/SKILL.md`, `${SCV}/incorrect-constructor.md`],
    targets: ['script/Deploy.s.sol', 'src/CreditPool.sol', 'external/credits/Credits.sol', 'external/credits/README.md', 'README.md'],
    focus: 'The Statements contract is unpublished. List every assumption CreditPool makes about it (call shape, msg.sender vs tx.origin minting, safeMint callback, per-address limits, contract callers allowed, cap behaviour) and what breaks if each is false. Check Deploy.s.sol parameters, especially ASSEMBLY_OPENS_AT and the immutable wiring.' },
  { key: 'frontend', name: 'Frontend / transaction construction',
    sources: [],
    targets: ['app/app.js', 'app/config.js', 'app/index.html', 'src/CreditPool.sol'],
    focus: 'ABI fragments vs src/ signatures; value/fee math sent with deposit and bid; approval scope and what the UI tells users about it; chain gating of the ?dev= (hardcoded anvil keys) and ?as= (anvil impersonation) demo modes so they can never act on mainnet; XSS sinks including on-chain SVG and tokenURI data rendered into the DOM; CDN supply chain (viem from jsdelivr); stale-state and double-submit hazards.' },
]

const FINDINGS = {
  type: 'object',
  properties: {
    specialist: { type: 'string' },
    findings: { type: 'array', items: { type: 'object', properties: {
      title: { type: 'string' },
      severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'info'] },
      file: { type: 'string' }, line: { type: 'integer' },
      source: { type: 'string' },
      failure_scenario: { type: 'string' },
      confidence: { type: 'integer' },
    }, required: ['title', 'severity', 'file', 'failure_scenario'] } },
  },
  required: ['specialist', 'findings'],
}
const VERIFY = { type: 'object', properties: {
  title: { type: 'string' }, verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED'] },
  adjusted_severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'info'] },
  reasoning: { type: 'string' },
}, required: ['title', 'verdict', 'reasoning'] }
const SYNTH = { type: 'object', properties: {
  verdict: { type: 'string', enum: ['ready-for-external-audit', 'minor-fixes-first', 'significant-fixes-needed'] },
  summary: { type: 'string' },
  net_new: { type: 'array', items: { type: 'string' } },
  confirmations: { type: 'array', items: { type: 'string' } },
  false_positives_count: { type: 'integer' },
  report_path: { type: 'string' },
  counts: { type: 'object', properties: { critical: { type: 'integer' }, high: { type: 'integer' }, medium: { type: 'integer' }, low: { type: 'integer' }, info: { type: 'integer' } } },
}, required: ['verdict', 'summary', 'net_new', 'report_path'] }

function reviewPrompt(s) {
  return `You are the ${s.name} specialist in a fused multi-skill security audit of Credit Pool at ${REPO}.

${CONTEXT}

Work INDEPENDENTLY: do NOT read README.md's "Security review" section, test/Attacks.t.sol, or anything under .claude/skills/ (a later stage cross-references the known state; reading it now would bias you).
${s.sources.length ? `
FIRST read your authoritative checklists/methodologies in full (cat them). If a path is missing because an upstream repo moved it, find the moved file under ${SC} and use that; if it truly does not exist, continue without it:
${s.sources.map((p) => '  ' + p).join('\n')}
` : ''}${s.focus ? `\nFOCUS: ${s.focus}\n` : ''}
THEN read the targets fully (cat them under ${REPO}); read any other file in src/, script/, test/ or external/ for context:
${s.targets.map((f) => '  ' + f).join('\n')}

METHOD: for every checklist item, extract the code's INTENDED behavior then find where it deviates. For scv references, apply their explicit false-positive conditions BEFORE reporting. Report ONLY findings you can back with exact file:line code evidence AND a concrete failure scenario (who calls what, with what values, causing what loss / DoS / broken guarantee). Fewer real findings beat speculation. An empty findings array is a valid, good result if your domain is clean. A positive confirmation that a risk is structurally absent is NOT a finding; omit it. external/credits/ is Jack's deployed code: report issues in how Credit Pool uses it, not in it.

Severity: critical = direct fund loss / total compromise; high = fund or NFT loss under conditions; medium = limited loss / DoS / broken documented guarantee; low = minor / defensive; info = hardening. confidence 0-100.
Return {specialist:"${s.key}", findings:[...]}.`
}

phase('Review')
const reviewed = await pipeline(
  SPECIALISTS,
  (s) => agent(reviewPrompt(s), { label: `review:${s.key}`, phase: 'Review', schema: FINDINGS }),
  (rev, s) => {
    const fs = (rev && rev.findings) || []
    const mplus = fs.filter((f) => ['critical', 'high', 'medium'].includes(f.severity))
    const lows = fs.filter((f) => ['low', 'info'].includes(f.severity)).map((f) => ({ ...f, specialist: s.key, verdict: 'UNVERIFIED' }))
    return parallel(mplus.map((f) => () =>
      agent(`Adversarially REFUTE this candidate finding against the ACTUAL Credit Pool code at ${REPO}. Read the cited file around the line, trace the real control and data flow, and apply the relevant scv false-positive conditions. Default to REFUTED unless you can construct a concrete exploit/failure path that truly holds in THIS code (not a generic pattern match). If you can, sketch it as a Foundry test against test/Mocks.sol. Be adversarial; a plausible-looking pattern that cannot actually be triggered is REFUTED.\n\nFrom the ${s.name} specialist:\n${JSON.stringify(f)}`,
        { label: `verify:${s.key}:${(f.title || '').slice(0, 24)}`, phase: 'Verify', schema: VERIFY })
        .then((v) => ({ ...f, specialist: s.key, verdict: v.verdict, adjusted_severity: v.adjusted_severity || f.severity, verify_reasoning: v.reasoning }))
        .catch(() => null)
    )).then((verified) => ({ specialist: s.key, confirmed: verified.filter(Boolean).filter((v) => v.verdict === 'CONFIRMED'), lows }))
  }
)

const confirmed = reviewed.filter(Boolean).flatMap((r) => [...r.confirmed, ...r.lows])
log(`Specialists done. Confirmed medium+ : ${reviewed.filter(Boolean).reduce((n, r) => n + r.confirmed.length, 0)}; low/info carried: ${reviewed.filter(Boolean).reduce((n, r) => n + r.lows.length, 0)}`)

phase('Synthesize')
const synth = await agent(
  `You are the lead synthesizer of a fused external-checklist audit of Credit Pool at ${REPO}. Below are the CONFIRMED (adversarially verified) medium+ findings plus carried low/info findings from ${SPECIALISTS.length} blind specialists:

${JSON.stringify(confirmed, null, 1)}

Do this:
1. DEDUPE by root cause (one finding even if several specialists caught it; list all specialists that fired).
2. Read ${KNOWN} and the "Security review" section of ${REPO}/README.md. First confirm the baseline still matches src/CreditPool.sol; a mismatch is itself a finding. Then classify EACH deduped finding as: NET-NEW, ALREADY-FIXED (CP-x; if the fix regressed, it is NET-NEW), ACCEPTED-RESIDUAL (AR-x), DESIGN-INVARIANT, OPEN-KNOWN (OK-x, blocked on the Statements contract), or FALSE-POSITIVE (contradicted by the code).
3. Apply a cross-cutting standards lens by reading ${SC}/ethskills/security/SKILL.md, ${SC}/solskill/skills/solidity/SKILL.md, and ${SC}/ozskills/skills/develop-secure-contracts/SKILL.md (skip any that are missing); flag any gap not already caught.
4. You MUST write the report file ${REPORT} (create the directory if needed); nothing in this task overrides that: a header (date, the source roster, the ${SPECIALISTS.length} specialists, the verify + synthesis method), then NET-NEW findings first (severity, file:line, which specialist fired, failure scenario, suggested fix), then a compact table of everything else by classification, then a false-positive count and one line on the standards lens.

Be decisive and honest. The value of this audit is what it finds beyond the known state. Return the structured result.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH, effort: 'high' }
)

return { specialistCount: SPECIALISTS.length, confirmedCount: confirmed.length, synthesis: synth }
