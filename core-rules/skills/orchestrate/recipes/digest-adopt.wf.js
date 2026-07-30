// digest-adopt — turn an ai-dev-trends digest into shipped Trellis change.
//
// The IMPLEMENTATION half of `research/ai-dev-trends/` (spec 008). The research
// task is read-only and writes only inside its own folder; this recipe is its
// more-privileged counterpart: it reads a digest + the Trellis repo, triages
// each proposal, and — only for routes a human has approved — fans out
// worktree-isolated agents that open **HOLD PRs**. It NEVER merges and NEVER
// writes to a project's main: the human merges. (spec 008 stopping point.)
//
// Loop shape (per `core-rules/references/loops.md`): a proactive/time outer loop
// (fires when a digest lands) wrapping a goal loop over the digest's actionable
// work-list. Halting is delegated to the loop-safety contract (meta.safety).
//
// The human gate is encoded IN CODE, not prose: with no `args.approved`, the
// recipe triages and RETURNS the proposed routes WITHOUT executing anything.
// Execution happens only on a second invocation carrying the approved routes —
// so a bare run can never reshape the framework. This mirrors the PR-flow
// bright-line the whole framework holds.
//
// Routing dogfoods spec 006: an approved `surgical` item takes a `/surgical`
// declaration; an approved `feature` item runs the `clarify -> spec -> plan ->
// tasks` pipeline and stops at a triad + HOLD PR. Triage skepticism reuses the
// P2 skeptical-evaluator persona (`references/skeptical-evaluator.md`); the run
// report carries the P3 `spent_usd / budget_ceiling_usd` cost line.
//
// Inputs (from `args`, never baked literals):
//   args.digestPath   repo-relative path to the digest to adopt, e.g.
//                     'research/ai-dev-trends/digests/2026-07-07.md'. Required.
//   args.ledgerPath   the durable adopt-ledger for cross-week dedup. Defaults to
//                     'research/ai-dev-trends/adopt-ledger.md'.
//   args.approved     [{ id, route }] — the human-approved routes from a prior
//                     propose run. ABSENT => propose-only (triage + stop, the
//                     human gate). PRESENT => execute exactly these, nothing else.
//                     route ∈ 'surgical' | 'feature' (validation-only / watch are
//                     never executed — they are ledger notes).
//   args.branchPrefix branch prefix for executed items. Defaults to 'feat/adopt'.
//   args.loopSafety   caller-resolved canonical `loop_safety` config block.
//                     Its `usd_per_mtok` rate is used for spend reporting when
//                     no per-run override is supplied.
//   args.usdPerMTok   optional positive per-run output-token rate override in
//                     USD per million tokens. Takes precedence over loopSafety.
//   args.maxParallel  optional Execute-wave cap (default 2). Values >2 also
//                     require parallelJustification and an exact successful
//                     two-target pilotReceipt; this recipe supplies its own budget.
//
// This file ships in the public mirror — keep it parametric and path-neutral.

export const meta = {
  name: 'digest-adopt',
  description: 'Turn an ai-dev-trends digest into shipped Trellis change: ingest + dedup vs the ledger, skeptically triage each proposal, and (only for human-approved routes) fan out worktree-isolated agents that open HOLD PRs via the 006 pipeline — never merge, never touch project main',
  phases: [
    { title: 'Ingest', detail: 'parse the digest + subtract ledger-settled proposals' },
    { title: 'Triage', detail: 'classify each candidate into a route, each checked by a skeptical verifier' },
    { title: 'Execute', detail: 'approved routes only: one worktree-isolated agent each -> 006 pipeline -> HOLD PR' },
    { title: 'Report', detail: 'cost line + ledger update instructions; park carryover' },
  ],
  // Loop-safety (spec 008): a bounded weekly job. One work-list pass; the recipe
  // OPENS PRs unattended on the execute leg, so it declares a conservative
  // ceiling of its own rather than inheriting the fleet default (1000). A
  // runaway fan-out that opens dozens of PRs is the failure mode to bound;
  // max_iterations caps the executed-item count. Cost is reported EVERY run
  // (P3), not only on a ceiling trip.
  safety: {
    no_progress_iterations: 2,
    max_iterations: 12,
    budget_ceiling_usd: 60,
    progress_signal: 'HOLD PR opened / ledger state transition',
  },
}

async function settle(id, run) {
  try {
    const value = await run()
    if (value == null) return { id, ok: false, value: null, error: 'null result' }
    return { id, ok: true, value, error: null }
  } catch (error) {
    return { id, ok: false, value: null, error: typeof error?.message === 'string' ? error.message : String(error) }
  }
}

function requireStage(stage, expectedIds, receipts, minSuccess = expectedIds.length) {
  const expected = expectedIds.map(String)
  const rows = Array.isArray(receipts) ? receipts : []
  const byId = new Map()
  let malformedCount = 0
  for (const receipt of rows) {
    if (!receipt || typeof receipt.id !== 'string' || byId.has(receipt.id)) { malformedCount += 1; continue }
    byId.set(receipt.id, receipt)
  }
  const unexpectedIds = [...byId.keys()].filter((id) => !expected.includes(id))
  const missingIds = expected.filter((id) => !byId.has(id))
  const successIds = expected.filter((id) => byId.get(id)?.ok === true && byId.get(id)?.value != null)
  const failureIds = expected.filter((id) => !successIds.includes(id))
  const identityOk = rows.length === expected.length && malformedCount === 0 && unexpectedIds.length === 0 && missingIds.length === 0
  const ok = identityOk && successIds.length >= minSuccess
  log(JSON.stringify({ event: 'workflow_stage_gate', stage, expected_ids: expected, success_ids: successIds, failure_ids: failureIds, unexpected_ids: unexpectedIds, missing_ids: missingIds, expected_count: expected.length, receipt_count: rows.length, success_count: successIds.length, failure_count: failureIds.length, malformed_count: malformedCount, min_success: minSuccess, ok }))
  if (!ok) throw new Error('workflow stage "' + stage + '" failed: ' + successIds.length + '/' + expected.length + ' successful; required ' + minSuccess)
  return expected.map((id) => byId.get(id))
}

function assertUniqueExpectedIds(stage, ids) {
  const expected = ids.map(String)
  const seen = new Set()
  for (const id of expected) {
    if (seen.has(id)) throw new Error('digest-adopt: duplicate expected id "' + id + '" before ' + stage + ' dispatch')
    seen.add(id)
  }
  return expected
}

function resolveMutationParallelism(currentTargetIds, scopeFingerprint = '') {
  if (currentTargetIds.length === 0) return 2
  if (args.maxParallel === undefined) return 2
  if (!Number.isInteger(args.maxParallel) || args.maxParallel < 1) throw new Error('digest-adopt: args.maxParallel must be a positive integer')
  if (args.maxParallel <= 2) return args.maxParallel
  const pilot = args.pilotReceipt
  const expectedPilotIds = currentTargetIds.slice(0, 2).map(String)
  const targetIds = Array.isArray(pilot?.target_ids) ? pilot.target_ids.map(String) : []
  const successIds = Array.isArray(pilot?.success_ids) ? pilot.success_ids.map(String) : []
  const exactTargets = expectedPilotIds.length === 2
    && targetIds.length === 2
    && targetIds.every((id, index) => id === expectedPilotIds[index])
  const exactSuccess = successIds.length === 2
    && successIds.every((id, index) => id === expectedPilotIds[index])
  const runId = typeof args.runId === 'string' ? args.runId.trim() : ''
  const runBound = runId !== '' && pilot?.recipe === meta.name && pilot?.run_id === runId
  const scopeBound = scopeFingerprint === '' || pilot?.scope_fingerprint === scopeFingerprint
  const pilotComplete = pilot?.completed === true && exactTargets && exactSuccess && runBound && scopeBound
  const budgetCeiling = meta.safety.budget_ceiling_usd ?? args.loopSafety?.budget_ceiling_usd
  if (typeof args.parallelJustification !== 'string' || args.parallelJustification.trim() === '') throw new Error('digest-adopt: maxParallel > 2 requires non-empty args.parallelJustification')
  if (!pilotComplete) throw new Error('digest-adopt: maxParallel > 2 requires a current-run args.pilotReceipt bound to recipe, runId, exact first two target IDs, successes, and scope')
  if (typeof budgetCeiling !== 'number' || !Number.isFinite(budgetCeiling) || budgetCeiling <= 0) throw new Error('digest-adopt: maxParallel > 2 requires a positive existing safety budget')
  return args.maxParallel
}

function checkpointWave(stage, waveIndex, expectedIds, receipts, minSuccess = expectedIds.length) {
  const checked = requireStage(stage, expectedIds, receipts, minSuccess)
  log(JSON.stringify({ event: 'workflow_checkpoint', stage, wave: waveIndex + 1, expected_ids: expectedIds.map(String), success_ids: checked.filter((receipt) => receipt.ok === true && receipt.value != null).map((receipt) => receipt.id), receipt_count: checked.length, ok: true }))
  return checked
}

async function runInWaves(items, cap, stage, runItem, idOf, minSuccessPerWave) {
  const allIds = assertUniqueExpectedIds(stage, items.map((item) => String(idOf(item))))
  const receipts = []
  for (let offset = 0, waveIndex = 0; offset < items.length; offset += cap, waveIndex += 1) {
    const wave = items.slice(offset, offset + cap)
    const waveIds = allIds.slice(offset, offset + wave.length)
    const waveReceipts = await parallel(wave.map((item) => () => settle(String(idOf(item)), () => runItem(item))))
    const minSuccess = minSuccessPerWave === undefined ? waveIds.length : minSuccessPerWave
    receipts.push(...checkpointWave(stage, waveIndex, waveIds, waveReceipts, minSuccess))
  }
  return receipts
}

const CANDIDATE = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'title', 'effort', 'risk'],
  properties: {
    id: { type: 'string', description: 'stable proposal id from the digest, e.g. P3' },
    title: { type: 'string' },
    effort: { type: 'string', description: 'digest effort tag: S | M | L' },
    risk: { type: 'string', description: 'digest risk tag: lo | med | hi' },
    touchpoint: { type: 'string', description: 'the Trellis file/area it touches (optional)' },
  },
}

const CANDIDATE_LIST = {
  type: 'object',
  additionalProperties: false,
  required: ['candidates', 'skipped_settled'],
  properties: {
    candidates: { type: 'array', items: CANDIDATE },
    skipped_settled: { type: 'number', description: 'count subtracted because the ledger marks them shipped/parked/rejected' },
  },
}

const TRIAGE = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'title', 'route', 'rationale', 'skeptic_upheld'],
  properties: {
    id: { type: 'string' },
    title: { type: 'string' },
    route: { type: 'string', description: "one of: validation-only | surgical | feature | watch" },
    rationale: { type: 'string', description: 'why this route (honest effort/risk read)' },
    skeptic_upheld: { type: 'boolean', description: 'true iff an independent skeptical verifier upheld the route (is it REALLY surgical? does Trellis REALLY already do this? is the effort tag honest?)' },
  },
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'route', 'branch', 'pr_url', 'gate_green', 'notes'],
  properties: {
    id: { type: 'string' },
    route: { type: 'string' },
    branch: { type: 'string' },
    pr_url: { type: 'string', description: 'HOLD PR URL, empty if none opened' },
    gate_green: { type: 'boolean', description: 'true iff process-gate --mode=merge was green before the PR opened' },
    notes: { type: 'string' },
  },
}

const ledgerPath = args.ledgerPath ?? 'research/ai-dev-trends/adopt-ledger.md'
const branchPrefix = args.branchPrefix ?? 'feat/adopt'
if (!args.digestPath) {
  throw new Error('digest-adopt: args.digestPath is required (the digest to adopt).')
}
const hasUsdPerMTokOverride = args.usdPerMTok !== undefined
if (hasUsdPerMTokOverride
  && (typeof args.usdPerMTok !== 'number' || !Number.isFinite(args.usdPerMTok) || args.usdPerMTok <= 0)) {
  throw new Error('digest-adopt: args.usdPerMTok must be a finite number greater than 0 (USD per million output tokens).')
}
const usdPerMTok = hasUsdPerMTokOverride
  ? args.usdPerMTok
  : args.loopSafety?.usd_per_mtok
const usdPerMTokAvailable = typeof usdPerMTok === 'number'
  && Number.isFinite(usdPerMTok)
  && usdPerMTok > 0

function currentCostLine() {
  const ceiling = meta.safety.budget_ceiling_usd.toFixed(2)
  const rate = usdPerMTokAvailable
    ? (Number.isInteger(usdPerMTok) ? usdPerMTok.toFixed(2) : String(usdPerMTok))
    : 'unavailable'
  let spentTokens = null
  if (typeof budget !== 'undefined' && typeof budget.spent === 'function') {
    try {
      spentTokens = budget.spent()
    } catch {
      spentTokens = null
    }
  }
  if (typeof spentTokens !== 'number' || !Number.isFinite(spentTokens) || spentTokens < 0) {
    return 'spent_usd unavailable / budget_ceiling_usd ' + ceiling
      + ' (output-token metering unavailable; usd_per_mtok ' + rate + ')'
  }
  if (!usdPerMTokAvailable) {
    return 'spent_usd unavailable / budget_ceiling_usd ' + ceiling
      + ' (' + spentTokens + ' output tokens metered; usd_per_mtok unavailable)'
  }
  const spentUsd = spentTokens * usdPerMTok / 1_000_000
  return 'spent_usd ' + spentUsd.toFixed(6) + ' / budget_ceiling_usd ' + ceiling
    + ' (' + spentTokens + ' output tokens at usd_per_mtok ' + rate + ')'
}

function emitCostLine(summary) {
  phase('Report')
  const costLine = currentCostLine()
  log('digest-adopt report: ' + summary + '; ' + costLine)
  return costLine
}

// --- Phase: Ingest --------------------------------------------------------
// Deterministic parse of the digest's actionable proposals, minus anything the
// ledger has already settled (cross-week dedup — never re-propose settled work).
phase('Ingest')
const ingestReceipt = await settle('ingest-digest', async () => {
  const value = await agent(
    [
      'You are the INGEST stage of the digest-adopt loop. Read TWO files:',
      '  1. the digest: ' + args.digestPath,
      '  2. the ledger: ' + ledgerPath + ' (may not exist yet — treat absent as empty).',
      "Parse the digest's `Trellis proposals` section (P1..Pn) plus any inline",
      'adopt-now / evaluate / watch tags and the risk radar. Produce the candidate',
      'list. SUBTRACT every proposal the ledger marks shipped, parked, or rejected',
      '(match by id + title). Return candidates: [{id,title,effort,risk,touchpoint}]',
      'and skipped_settled = how many you subtracted.',
    ].join('\n'),
    { label: 'ingest-digest', phase: 'Ingest', schema: CANDIDATE_LIST },
  )
  return Array.isArray(value?.candidates) ? value : null
})
requireStage('Ingest', ['ingest-digest'], [ingestReceipt], 1)
const ingest = ingestReceipt.value
const candidates = ingest.candidates
log('digest-adopt: ' + candidates.length + ' candidate(s); ' + (ingest.skipped_settled ?? 0) + ' already settled in the ledger')
if (candidates.length === 0) {
  const costLine = emitCostLine('no fresh candidates')
  return {
    triage: [],
    costLine,
    note: 'no fresh candidates — the ledger has settled everything in this digest.',
  }
}

// --- Phase: Triage --------------------------------------------------------
// Classify each candidate into a route, each classification CHECKED by an
// independent skeptical verifier (the P2 persona): is it REALLY surgical? does
// Trellis REALLY already do this? is the effort tag honest? A route the skeptic
// does not uphold is surfaced (skeptic_upheld=false) so the human sees the doubt.
phase('Triage')
const candidateIds = candidates.map((c) => String(c.id))
const triageReceipts = await parallel(
  candidates.map((c) => () => settle(String(c.id), async () => {
    const triage = await agent(
      [
        'You are the TRIAGE stage for ONE digest proposal. Classify its route and',
        'then adopt the skeptical-evaluator persona',
        '(`core-rules/skills/orchestrate/references/skeptical-evaluator.md`) to CHECK',
        'your own classification — default to doubt, uphold only on evidence.',
        '',
        'PROPOSAL ' + c.id + ': ' + c.title + '  (effort ' + c.effort + ', risk ' + c.risk + ')',
        c.touchpoint ? 'Touchpoint: ' + c.touchpoint : '',
        '',
        'Routes:',
        "  validation-only — no code; Trellis already does this. A ledger note only.",
        "  surgical        — small/mechanical; a `/surgical` change (size-capped, spec 006).",
        "  feature         — needs design; the clarify->spec->plan->tasks pipeline.",
        "  watch           — park to the watchlist, no action.",
        '',
        'Skeptical checks before you commit to a route: is it REALLY surgical (not a',
        'feature in disguise)? does Trellis REALLY already do this (read the touchpoint',
        'before claiming validation-only)? is the digest effort tag honest? Set',
        'skeptic_upheld=false if your own skeptical pass does not confirm the route.',
      ].join('\n'),
      { label: 'triage:' + c.id, phase: 'Triage', schema: TRIAGE },
    )
    return triage?.id === c.id ? triage : null
  })),
)
requireStage('Triage', candidateIds, triageReceipts, candidateIds.length)
const triaged = triageReceipts.map((receipt) => receipt.value)

// --- Human gate (bright-line, in code) ------------------------------------
// With no approved routes, STOP here: return the triage proposal for the human
// to approve. Nothing is built. Execution requires a second invocation carrying
// args.approved — the framework is never reshaped by a bare run.
if (!args.approved || args.approved.length === 0) {
  const costLine = emitCostLine('PROPOSE-ONLY (human gate)')
  return {
    triage: triaged,
    costLine,
    ledgerPath,
    note: 'PROPOSE-ONLY (human gate). Review the routes above; re-invoke with '
      + 'args.approved = [{id, route}] for the surgical/feature items to build. '
      + 'validation-only and watch are ledger notes, never executed.',
  }
}

// --- Phase: Execute -------------------------------------------------------
// Approved routes only. `validation-only`/`watch` are never executable, so drop
// them defensively even if passed. Dedup by id; cap at max_iterations so an
// over-long approved list cannot open unbounded PRs (ceiling ENFORCED, not just
// declared). One worktree-isolated agent per item; process-gate green before
// each HOLD PR; never merge.
phase('Execute')
const MAX = meta.safety.max_iterations
const byId = new Map(triaged.map((t) => [t.id, t]))
const toBuild = args.approved
  .filter((a) => a.route === 'surgical' || a.route === 'feature')
  .filter((a) => byId.has(a.id))
assertUniqueExpectedIds('Execute', toBuild.map((a) => String(a.id)))
const capped = toBuild.slice(0, MAX)
if (capped.length < toBuild.length) {
  log('digest-adopt: capped at max_iterations=' + MAX + ' — ' + (toBuild.length - capped.length) + ' approved item(s) deferred to a later run')
}
log('digest-adopt: executing ' + capped.length + ' approved item(s) as HOLD PRs')

function executePrompt(a) {
  const t = byId.get(a.id)
  return [
    'You are implementing ONE approved digest proposal as a HOLD PR. Route: ' + a.route + '.',
    'PROPOSAL ' + t.id + ': ' + t.title,
    'Rationale from triage: ' + t.rationale,
    '',
    'GIT DISCIPLINE: work ONLY in an isolated worktree off the LATEST origin/main,',
    'on branch ' + branchPrefix + '-' + t.id.toLowerCase() + '. Stage explicit paths,',
    'never `git add -A`. No unbounded `rm` or `$VAR.*` globs. Confine writes to the worktree.',
    '',
    a.route === 'surgical'
      ? 'ROUTE=surgical (spec 006): this is small/mechanical. Make the change, then declare it '
        + 'with `/surgical "<why this needs no spec>"` (size-capped). Keep it minimal.'
      : 'ROUTE=feature (spec 006): run the pipeline — clarify -> spec -> plan -> tasks — and author '
        + 'a real specs/NNN triad (each of spec/plan/tasks >=200 bytes, no scaffold markers). '
        + 'STOP at "triad + implementation + HOLD PR opened for review"; features are the human to approve.',
    '',
    'Before opening the PR, run `process-gate --mode=merge` and require it GREEN (set gate_green).',
    'Match surrounding style. Commit conventionally (subject <=72 chars, no comma in scope).',
    'Push with -u and open a **HOLD PR** (`gh pr create`, "[HOLD]" in title, "DO NOT MERGE without',
    'human review" in the body). Do NOT merge. Leave the worktree in place.',
    '',
    'Return the VERDICT for id="' + t.id + '". If you could not open a clean PR, set pr_url empty',
    'and explain in notes.',
  ].join('\n')
}

const buildIds = assertUniqueExpectedIds('Execute', capped.map((a) => String(a.id)))
const mutationScopeFingerprint = JSON.stringify({
  digestPath: args.digestPath,
  approved: capped.map((a) => ({ id: String(a.id), route: a.route })),
})
const mutationCap = resolveMutationParallelism(buildIds, mutationScopeFingerprint)
log('digest-adopt: mutation maxParallel=' + mutationCap)
const verdictReceipts = await runInWaves(capped, mutationCap, 'Execute', async (a) => {
  const verdict = await agent(executePrompt(a), {
    label: 'build:' + a.id,
    phase: 'Execute',
    schema: VERDICT,
    isolation: 'worktree',
  })
  return verdict?.id === a.id ? verdict : null
}, (a) => a.id)
requireStage('Execute', buildIds, verdictReceipts, buildIds.length)
const verdicts = verdictReceipts.map((receipt) => receipt.value)

// --- Phase: Report --------------------------------------------------------
// P3 cost line every run + ledger-update instructions + carryover. budget.spent()
// is output-token-native, so convert through the resolved USD-per-MTok rate
// before displaying it beside the USD ceiling. Nothing here merges.
const opened = verdicts.filter((v) => v.pr_url)
const costLine = emitCostLine(opened.length + '/' + verdicts.length + ' HOLD PRs opened')

return {
  triage: triaged,
  verdicts,
  costLine,
  ledgerPath,
  note: 'HOLD PRs are the human to merge (spec 008 bright-line). Update ' + ledgerPath
    + ': set each opened item to in-progress (with its PR), each validation-only/watch to its note. '
    + 'Park un-built approved items to carryover for the next run.',
}
