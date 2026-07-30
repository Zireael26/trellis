// conductor — daily fleet selection loop: rank the backlog, then auto-spec the
// top eligible item(s). "Rank + auto-spec, hold code": the spec agents produce
// a spec -> plan -> tasks triad on a feature branch and STOP. They never write
// implementation code, never push, never merge. The main loop returns the
// ranked slate + spec verdicts; a human dispatches `execute` from there.
//
// Inputs (from `args`, never baked literals — this file ships in the public mirror):
//   args.today        string  ISO date 'YYYY-MM-DD'. REQUIRED. The engine forbids
//                             the argless date constructor, so the caller injects
//                             "today" for deadline math.
//   args.backlogPath  string  path to the fleet backlog.yml (source of truth).
//   args.registryPath string  path to registry.md (active projects).
//   args.autoSpecTopN number  how many top eligible items to spec tonight (default 1).
//   args.weights      object  optional scoring-weight override; serialized into
//                            the rank work order. Else read from backlog.
//   args.refreshTimeoutSeconds number per-repo fetch ceiling (default 30).
//   args.maxParallel number optional Auto-spec mutation-wave cap (default 2).
//                    Values >2 require parallelJustification and an exact
//                    successful two-target pilotReceipt; this recipe owns a budget.
//
// Degrade: with a workflow tool, run as-is. Without, read meta.phases + the
// prompt builders below and dispatch each stage by hand (SKILL.md tier 2/3).

export const meta = {
  name: 'conductor',
  description: 'Rank the fleet backlog into a daily slate, then auto-spec the top eligible item(s) on a feature branch — hold code, never merge',
  phases: [
    { title: 'Refresh refs', detail: 'fetch each repo once with a timeout and bind ranking to immutable main SHAs' },
    { title: 'Rank', detail: 'read backlog + registry + per-project git signals, score every task, emit a ranked slate' },
    { title: 'Auto-spec', detail: 'top N eligible items: one worktree-isolated agent each runs spec -> plan -> tasks, holds code, returns a verdict' },
  ],
  // Loop-safety (`core-rules/loop-safety.md`). ONE-SHOT: a single rank pass, then
  // one finite auto-spec pass in bounded checkpointed waves — no adaptive rounds. Exempt from
  // no_progress (declares null). max_iterations inherits the resolved baseline.
  // budget_ceiling_usd is OVERRIDDEN low: this is an unattended nightly writer
  // loop that should spec, not spend — a tight ceiling is a deliberate guardrail.
  safety: {
    no_progress_iterations: null,
    budget_ceiling_usd: 60,
    progress_signal: 'work-list drain',
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
    if (seen.has(id)) throw new Error('conductor: duplicate expected id "' + id + '" before ' + stage + ' dispatch')
    seen.add(id)
  }
  return expected
}

function resolveMutationParallelism(currentTargetIds, scopeFingerprint = '') {
  if (currentTargetIds.length === 0) return 2
  if (args.maxParallel === undefined) return 2
  if (!Number.isInteger(args.maxParallel) || args.maxParallel < 1) throw new Error('conductor: args.maxParallel must be a positive integer')
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
  if (typeof args.parallelJustification !== 'string' || args.parallelJustification.trim() === '') throw new Error('conductor: maxParallel > 2 requires non-empty args.parallelJustification')
  if (!pilotComplete) throw new Error('conductor: maxParallel > 2 requires a current-run args.pilotReceipt bound to recipe, runId, exact first two target IDs, successes, and scope')
  if (typeof budgetCeiling !== 'number' || !Number.isFinite(budgetCeiling) || budgetCeiling <= 0) throw new Error('conductor: maxParallel > 2 requires a positive existing safety budget')
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

const REFRESH = {
  type: 'object',
  additionalProperties: false,
  required: ['complete', 'refs', 'notes'],
  properties: {
    complete: { type: 'boolean', description: 'true iff every repo-backed backlog project refreshed and resolved an immutable origin/main commit' },
    refs: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['project', 'repo_path', 'main_sha'],
        properties: {
          project: { type: 'string' },
          repo_path: { type: 'string' },
          main_sha: { type: 'string', pattern: '^[0-9a-f]{40,64}$' },
        },
      },
    },
    notes: { type: 'string' },
  },
}

// Ranked-slate shape. One row per backlog task, score + human-readable reasons.
const SLATE = {
  type: 'object',
  additionalProperties: false,
  required: ['generated_for', 'ranked'],
  properties: {
    generated_for: { type: 'string', description: 'the args.today the slate was built for' },
    ranked: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'project', 'title', 'score', 'reasons', 'eligible_auto_spec', 'auto_spec', 'delivered_on_main', 'existing_spec_path', 'auto_spec_exclusions'],
        properties: {
          id: { type: 'string' },
          project: { type: 'string' },
          title: { type: 'string' },
          score: { type: 'number', description: '0..1 composite; higher = do sooner' },
          reasons: { type: 'string', description: 'why this score — deadline/impact/staleness drivers, one line' },
          eligible_auto_spec: { type: 'boolean', description: 'true iff repo-backed, not manual/blocked/done/surgical, not already delivered on current main, and no matching spec already exists' },
          auto_spec: { type: ['boolean', 'null'], description: 'the backlog override copied exactly: true=force ahead of ranked candidates, false=exempt, null=normal ranking' },
          delivered_on_main: { type: 'boolean', description: 'true iff current origin/main already contains the task outcome; always excluded from auto-spec' },
          existing_spec_path: { type: 'string', description: 'matching existing specs/ path, or empty string when none; a non-empty value is always excluded from auto-spec' },
          auto_spec_exclusions: {
            type: 'array',
            items: { type: 'string' },
            description: 'recorded hard exclusion reasons, including delivered-on-main and existing-spec; empty only when eligible_auto_spec may be true',
          },
        },
      },
    },
  },
}

// Spec verdict — the auto-spec agent returns this. It never returns code.
const SPEC_VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'branch', 'spec_path', 'ready', 'notes'],
  properties: {
    id: { type: 'string', description: 'backlog task id' },
    branch: { type: 'string', description: 'feature/<slug> branch created (empty if none)' },
    spec_path: { type: 'string', description: 'specs/NNN-<slug>/ path (empty if none)' },
    ready: { type: 'boolean', description: 'true iff spec+plan+tasks written with testable success criteria and a scope.json touch-budget' },
    notes: { type: 'string', description: 'open questions surfaced, or why it could not be specced' },
  },
}

const autoSpecTopN = args.autoSpecTopN ?? 1
const weights = args.weights
const refreshTimeoutSeconds = args.refreshTimeoutSeconds ?? 30
if (weights !== undefined && (weights == null || typeof weights !== 'object' || Array.isArray(weights))) {
  throw new Error('conductor: args.weights must be an object when provided')
}
if (!Number.isInteger(refreshTimeoutSeconds) || refreshTimeoutSeconds < 1 || refreshTimeoutSeconds > 300) {
  throw new Error('conductor: args.refreshTimeoutSeconds must be an integer from 1 through 300')
}
const serializedWeights = weights === undefined ? 'null' : JSON.stringify(weights)

function refreshPrompt() {
  return [
    'You are the fleet CONDUCTOR ref-refresh preflight. Read-only except for remote-tracking refs.',
    'Read backlog ' + (args.backlogPath ?? '<the Trellis conductor backlog.yml>') + ' and registry ' + (args.registryPath ?? '<the control-plane registry.md>') + '.',
    'Enumerate every unique repo-backed project in the backlog and resolve its registry path.',
    'For each repo run exactly ONE fetch attempt, with no retry:',
    '  authentication: use ambient task-secret or Keychain credentials only; never print, persist, or return credentials in notes.',
    '  timeout runner: prefer `gtimeout`; else `timeout`; else `perl -e \'alarm shift; exec @ARGV\' ' + refreshTimeoutSeconds + ' git ...`.',
    '  command: git -C <repo_path> fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main',
    '  ceiling: ' + refreshTimeoutSeconds + ' seconds per repo.',
    'After a successful fetch resolve exactly: git -C <repo_path> rev-parse --verify refs/remotes/origin/main^{commit}',
    'Return one project/repo_path/main_sha row per repo. Set complete=false if enumeration, timeout support, fetch, or SHA resolution fails for ANY repo.',
    'Do not retry, modify working trees, or create branches. Return REFRESH; an incomplete receipt permits backlog-only ranking but permanently disables mutation for this run.',
  ].join('\n')
}

function rankPrompt(refs, immutableRefsComplete = true) {
  return [
    'You are the fleet CONDUCTOR ranking agent. Read-only. Produce a ranked slate.',
    '',
    'INPUTS:',
    '  - Backlog (source of truth): ' + (args.backlogPath ?? '<the Trellis conductor backlog.yml>'),
    '  - Active projects: ' + (args.registryPath ?? '<the control-plane registry.md>') + ' (minus blacklist.md)',
    '  - Today is ' + args.today + '. Use it for all deadline math (no system clock calls).',
    '  - IMMUTABLE_MAIN_REFS_JSON: ' + JSON.stringify(refs),
    immutableRefsComplete
      ? '    For delivery and existing-spec anti-dup checks, inspect ONLY each listed main_sha. Never read mutable origin/main.'
      : '    REFRESH INCOMPLETE: rank from backlog fields only. Do not inspect any repo/ref. Set delivered_on_main=false, existing_spec_path="", eligible_auto_spec=false, and include `ref-refresh-incomplete` in every repo-backed row auto_spec_exclusions.',
    '  - WEIGHTS_OVERRIDE_JSON: ' + serializedWeights,
    weights === undefined
      ? '    No args.weights override was supplied; read weights from the backlog.'
      : '    Use this serialized args.weights object exactly; it overrides backlog weights.',
    '',
    'FOR EACH task in the backlog:',
    '  0. Copy backlog `auto_spec` exactly into the row: true, false, or null when unset.',
    '     Inspect the project main_sha from IMMUTABLE_MAIN_REFS_JSON and that commit\'s specs/ for anti-duplication. Set delivered_on_main=true',
    '     and add `delivered-on-main` when the task is already delivered. Set existing_spec_path',
    '     and add `existing-spec:<path>` when a matching spec exists.',
    '     Record every hard reason in auto_spec_exclusions; do not re-spec either case.',
    '  1. Compute the five normalized signals (0..1): deadline proximity (from `deadline` vs today),',
    '     impact (map `impact` via impact_scale), unblock (judgement from note/tags), effort',
    '     (effort_scale, subtracted), staleness (peek at the repo: many open branches + no recent',
    '     merge on the relevant area = higher). Weights come from backlog `weights` (or args.weights).',
    '  2. score = sum(weight * signal). Keep it auditable: state the 1-2 drivers in `reasons`.',
    '  3. eligible_auto_spec = repo is non-null AND safe != "manual" AND status not in',
    '     {blocked,done} AND surgical != true AND auto_spec != false AND auto_spec_exclusions is empty.',
    '     auto_spec=true changes selection order only; it never overrides these hard safety/anti-dup exclusions.',
    '',
    'Sort ranked by score descending. Return the SLATE object. Do not modify any file.',
  ].join('\n')
}

function specPrompt(item, mainSha) {
  return [
    'You are a CONDUCTOR auto-spec agent for backlog task "' + item.id + '" (' + item.title + ')',
    'in repo ' + item.project + '. Tonight you SPEC ONLY — you do not write implementation code.',
    '',
    'GIT DISCIPLINE: the main checkout may be on a dirty WIP branch — never checkout/switch/stash/clean it.',
    'Work in an isolated worktree at the exact preflight-bound main commit (do not fetch or substitute a mutable ref):',
    '  git worktree add <tmp> -b feature/' + item.id + ' ' + mainSha,
    '',
    'Run the Trellis pipeline, in order, and STOP before any code:',
    '  1. clarify (only if the task is vague on intent/users/success/edge-cases/rollback)',
    '  2. spec  -> specs/NNN-<slug>/spec.md with TESTABLE success criteria and explicit non-goals',
    '  3. plan  -> plan.md (file-by-file technical approach)',
    '  4. tasks -> tasks.md work breakdown, AND a scope.json touch-budget next to it:',
    '        { "allow": ["<globs the change may touch>"], "max_files": <cap, default 7> }',
    '',
    'HARD RULES: write no implementation code. Do not run `execute`. Do not push. Do not open a PR.',
    'Do not merge. Commit only the specs/ artifacts to the feature branch (local). Remove your worktree when done.',
    '',
    'Return the SPEC_VERDICT for id="' + item.id + '". ready=true only if spec+plan+tasks+scope.json all exist',
    'with testable criteria. Put any unresolved decisions in notes (do not guess silently).',
  ].join('\n')
}

// --- Phase: Refresh refs ---------------------------------------------------
phase('Refresh refs')
const refreshReceipt = await settle('refresh-refs', async () => {
  const value = await agent(refreshPrompt(), { label: 'refresh-refs', phase: 'Refresh refs', schema: REFRESH })
  return value && typeof value.complete === 'boolean' && Array.isArray(value.refs) ? value : null
})
requireStage('Refresh refs', ['refresh-refs'], [refreshReceipt], 1)
const refreshed = refreshReceipt.value
const refByProject = new Map()
let mutationAllowed = refreshed?.complete === true && Array.isArray(refreshed.refs)
for (const ref of (Array.isArray(refreshed?.refs) ? refreshed.refs : [])) {
  if (typeof ref.project !== 'string' || ref.project.trim() === '' || typeof ref.repo_path !== 'string' || ref.repo_path.trim() === '' || !/^[0-9a-f]{40,64}$/.test(ref.main_sha)) {
    mutationAllowed = false
    continue
  }
  if (refByProject.has(ref.project)) {
    mutationAllowed = false
    continue
  }
  refByProject.set(ref.project, ref.main_sha)
}
if (!mutationAllowed) {
  refByProject.clear()
  log('conductor: ref refresh incomplete; rank-only mode, all branch/worktree/spec creation disabled: ' + (refreshed?.notes ?? 'invalid receipt'))
}

// --- Phase: Rank -----------------------------------------------------------
phase('Rank')
const rankReceipt = await settle('rank', async () => {
  const value = await agent(rankPrompt(Array.from(refByProject, ([project, main_sha]) => ({ project, main_sha })), mutationAllowed), { label: 'rank', phase: 'Rank', schema: SLATE })
  return Array.isArray(value?.ranked) ? value : null
})
requireStage('Rank', ['rank'], [rankReceipt], 1)
const slate = rankReceipt.value

// Select the top N eligible items for tonight's spec pass. Explicit force rows
// lead regardless of score; explicit false rows are exempt. Hard safety and
// anti-dup exclusions always win over force. Dedup by task id as a final
// recipe-side guard against duplicate backlog/model rows.
const ranked = slate.ranked ?? []
const noExclusions = (row) => Array.isArray(row.auto_spec_exclusions) && row.auto_spec_exclusions.length === 0
const noExistingSpec = (row) => typeof row.existing_spec_path === 'string' && row.existing_spec_path.trim() === ''
const hasBoundMain = (row) => refByProject.has(row.project)
const selectable = (row) => mutationAllowed && row.eligible_auto_spec === true && row.auto_spec !== false && row.delivered_on_main === false && noExistingSpec(row) && noExclusions(row) && hasBoundMain(row)
const orderedCandidates = [
  ...ranked.filter((row) => row.auto_spec === true && selectable(row)),
  ...ranked.filter((row) => row.auto_spec !== true && selectable(row)),
]
const selected = orderedCandidates.slice(0, autoSpecTopN)
assertUniqueExpectedIds('Auto-spec', selected.map((row) => String(row.id)))
const duplicateCount = orderedCandidates.length - new Set(orderedCandidates.map((row) => String(row.id))).size
const exemptCount = ranked.filter((row) => row.auto_spec === false).length
const hardExcludedCount = ranked.filter((row) => !selectable(row) && row.auto_spec !== false).length
log('conductor: ranked ' + ranked.length + ' tasks; auto-speccing ' + selected.length + ' (top ' + autoSpecTopN + ' eligible; forced=' + orderedCandidates.filter((row) => row.auto_spec === true).length + ', exempt=' + exemptCount + ', hard-excluded=' + hardExcludedCount + ', duplicate=' + duplicateCount + ')')

// --- Phase: Auto-spec ------------------------------------------------------
// One-shot fan-out. Each agent works in its own worktree and returns a verdict.
// Agents never merge and never write code — they leave a reviewable spec.
phase('Auto-spec')
const selectedIds = assertUniqueExpectedIds('Auto-spec', selected.map((item) => String(item.id)))
const mutationScopeFingerprint = JSON.stringify({
  today: args.today,
  selected: selected.map((item) => ({ id: String(item.id), project: item.project, main_sha: refByProject.get(item.project) })),
})
const mutationCap = resolveMutationParallelism(selectedIds, mutationScopeFingerprint)
log('conductor: mutation maxParallel=' + mutationCap)
const specReceipts = selected.length
  ? await runInWaves(selected, mutationCap, 'Auto-spec', async (item) => {
      const verdict = await agent(specPrompt(item, refByProject.get(item.project)), {
        label: 'spec:' + item.id,
        phase: 'Auto-spec',
        schema: SPEC_VERDICT,
        isolation: 'worktree',
      })
      return verdict?.id === item.id ? verdict : null
    }, (item) => item.id)
  : []
requireStage('Auto-spec', selectedIds, specReceipts, selectedIds.length)
const specs = specReceipts.map((receipt) => receipt.value)

// Main loop consumes this: render the slate, list the specs waiting for a human
// to review and dispatch `execute`. Nothing here crosses the merge boundary.
return { slate, specs, refresh_complete: mutationAllowed, refresh_notes: refreshed?.notes ?? '' }
