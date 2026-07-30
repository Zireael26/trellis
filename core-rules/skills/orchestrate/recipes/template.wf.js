// Recipe template — copy this file to start a new workflow recipe.
//
// A recipe is plain ES-module JS. The engine injects a fixed set of globals;
// you never import or define them yourself:
//   agent(prompt, opts?)  -> returns text, or a validated object when opts.schema is set
//   parallel(thunks)      -> runs an array of () => agent(...) thunks, barrier-joins
//   pipeline(items, ...s) -> streams items through stages, no barrier
//   phase(title)          -> marks a phase boundary (matches a meta.phases title)
//   log(msg)              -> structured progress line
//   args                  -> caller-supplied inputs (the ONLY place specifics enter)
//   budget                -> remaining run budget
//
// FORBIDDEN — the engine rejects scripts that call non-deterministic globals:
// the current-time call, the random call, and the argless date constructor.
// Need a timestamp or seed? Take it from `args`.
//
// Authoring rules of thumb:
//   - Keep `meta` a PURE LITERAL (no function calls, no concatenation).
//   - Put every specific (targets, paths, dates, scope) in `args` — never bake
//     literals. This file ships in the public mirror; keep it path-neutral.
//   - Agents do the work and RETURN a verdict; the main loop decides/merges.
//   - Declare a `safety` block. Every recipe is a loop and must honor the
//     loop-safety contract (`core-rules/loop-safety.md`); a recipe with no
//     `safety` declaration is non-compliant.

export const meta = {
  // <fill-in> short kebab-case identifier, unique across recipes.
  name: 'my-recipe',
  // <fill-in> one line: what this recipe accomplishes and for whom.
  description: 'One-line intent — what this recipe produces and verifies.',
  // <fill-in> optional ordered phases; each title should match a phase() call.
  phases: [
    { title: 'Work', detail: 'what the agents in this phase do' },
  ],
  // Loop-safety contract — the three ceilings every loop honors; halt on any
  // one. Policy + progress-signal catalog + token↔dollar conversion live in
  // `core-rules/loop-safety.md`; the VALUES live in `trellis.config.json`.
  // INHERIT-OR-OVERRIDE: set a field only to OVERRIDE the resolved baseline
  // (per-loop > project-local > central config > built-in fallback). Leave a
  // field out — or set it to null — to inherit the resolved value. The block
  // is a per-loop override, not a place to restate the defaults.
  safety: {
    // OVERRIDE-ONLY: uncomment a ceiling ONLY to override the resolved baseline;
    // leave it commented to inherit (per-loop > project-local > central > fallback).
    // Restating a default here PINS it and defeats a later central retune.
    // max_iterations: 100,          // hard cap on dispatch rounds (fallback 100)
    // no_progress_iterations: 3,    // halt after N no-progress rounds (fallback 3)
    //   NULL-FOR-ONE-SHOT: a one-shot fan-out — one finite work-list pass in
    //   bounded waves, no adaptive rounds — sets `no_progress_iterations: null`
    //   (see `fanout-verify.wf.js`); `max_iterations`/`budget_ceiling_usd` still apply.
    // budget_ceiling_usd: 1000,     // spend ceiling per run, USD (fallback 1000)
    // The progress signal is the one field worth declaring per loop — pick the
    // catalog entry that fits: commit/PR | file delta | new finding |
    // work-list drain | state-hash change (catch-all; also the inherited default).
    progress_signal: 'state-hash change',
  },
}

// Every dispatched identity gets one receipt. The Workflow engine may resolve a
// failed thunk to null, so required-stage success must be decided here — never by
// shrinking the result array with filter(Boolean).
async function settle(id, run) {
  try {
    const value = await run()
    if (value == null) return { id, ok: false, value: null, error: 'null result' }
    return { id, ok: true, value, error: null }
  } catch (error) {
    return {
      id,
      ok: false,
      value: null,
      error: typeof error?.message === 'string' ? error.message : String(error),
    }
  }
}

// Identity integrity is always strict: one unique receipt per expected id. The
// minSuccess argument controls only how many non-null values the stage requires.
// Required stages pass expectedIds.length; an explicitly optional provider leg
// may pass 0, preserving and logging its failed receipts for visible degradation.
function requireStage(stage, expectedIds, receipts, minSuccess = expectedIds.length) {
  const expected = expectedIds.map(String)
  const rows = Array.isArray(receipts) ? receipts : []
  const byId = new Map()
  let malformedCount = 0
  for (const receipt of rows) {
    if (!receipt || typeof receipt.id !== 'string' || byId.has(receipt.id)) {
      malformedCount += 1
      continue
    }
    byId.set(receipt.id, receipt)
  }
  const unexpectedIds = [...byId.keys()].filter((id) => !expected.includes(id))
  const missingIds = expected.filter((id) => !byId.has(id))
  const successIds = expected.filter((id) => byId.get(id)?.ok === true && byId.get(id)?.value != null)
  const failureIds = expected.filter((id) => !successIds.includes(id))
  const identityOk = rows.length === expected.length && malformedCount === 0 && unexpectedIds.length === 0 && missingIds.length === 0
  const ok = identityOk && successIds.length >= minSuccess
  log(JSON.stringify({
    event: 'workflow_stage_gate',
    stage,
    expected_ids: expected,
    success_ids: successIds,
    failure_ids: failureIds,
    unexpected_ids: unexpectedIds,
    missing_ids: missingIds,
    expected_count: expected.length,
    receipt_count: rows.length,
    success_count: successIds.length,
    failure_count: failureIds.length,
    malformed_count: malformedCount,
    min_success: minSuccess,
    ok,
  }))
  if (!ok) {
    throw new Error('workflow stage "' + stage + '" failed: ' + successIds.length + '/' + expected.length + ' successful; required ' + minSuccess)
  }
  return expected.map((id) => byId.get(id))
}

// Mutation fan-out defaults to waves of two. A larger wave is an explicit,
// fail-closed exception: name maxParallel, explain it, attach a completed
// two-target pilot receipt, and pass the caller-resolved positive safety budget.
function assertUniqueExpectedIds(stage, ids) {
  const expected = ids.map(String)
  const seen = new Set()
  for (const id of expected) {
    if (seen.has(id)) throw new Error('my-recipe: duplicate expected id "' + id + '" before ' + stage + ' dispatch')
    seen.add(id)
  }
  return expected
}

function resolveMutationParallelism(currentTargetIds, scopeFingerprint = '') {
  if (currentTargetIds.length === 0) return 2
  if (args.maxParallel === undefined) return 2
  if (!Number.isInteger(args.maxParallel) || args.maxParallel < 1) throw new Error('my-recipe: args.maxParallel must be a positive integer')
  if (args.maxParallel <= 2) return args.maxParallel
  const pilot = args.pilotReceipt
  const expectedPilotIds = currentTargetIds.slice(0, 2).map(String)
  const targetIds = Array.isArray(pilot?.target_ids) ? pilot.target_ids.map(String) : []
  const successIds = Array.isArray(pilot?.success_ids) ? pilot.success_ids.map(String) : []
  const exactTargets = expectedPilotIds.length === 2 && targetIds.length === 2 && targetIds.every((id, index) => id === expectedPilotIds[index])
  const exactSuccess = successIds.length === 2 && successIds.every((id, index) => id === expectedPilotIds[index])
  const runId = typeof args.runId === 'string' ? args.runId.trim() : ''
  const runBound = runId !== '' && pilot?.recipe === meta.name && pilot?.run_id === runId
  const scopeBound = scopeFingerprint === '' || pilot?.scope_fingerprint === scopeFingerprint
  const pilotComplete = pilot?.completed === true && exactTargets && exactSuccess && runBound && scopeBound
  const budgetCeiling = meta.safety.budget_ceiling_usd ?? args.loopSafety?.budget_ceiling_usd
  if (typeof args.parallelJustification !== 'string' || args.parallelJustification.trim() === '') throw new Error('my-recipe: maxParallel > 2 requires non-empty args.parallelJustification')
  if (!pilotComplete) throw new Error('my-recipe: maxParallel > 2 requires a current-run args.pilotReceipt bound to recipe, runId, exact first two target IDs, successes, and scope')
  if (typeof budgetCeiling !== 'number' || !Number.isFinite(budgetCeiling) || budgetCeiling <= 0) throw new Error('my-recipe: maxParallel > 2 requires a positive existing safety budget')
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

// Structured-output schema for an agent's verdict. Setting opts.schema makes
// agent() return a validated object instead of free text. Keep
// additionalProperties:false so the agent can't smuggle unexpected keys.
const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'summary'],
  properties: {
    ok: { type: 'boolean', description: '<fill-in> the pass/fail predicate for this unit of work' },
    summary: { type: 'string', description: '<fill-in> what changed / what was found, concise' },
    // <fill-in> add the fields the main loop needs to act on the result.
  },
}

// Build the prompt as an array of lines joined with newlines — easy to read in
// diffs, and the array doubles as a readable spec for a harness with no workflow
// tool. Pull every specific from `args`; do not hardcode.
function workPrompt(item) {
  return [
    'You are doing <fill-in: the task> for "' + item.name + '".',
    'Verify on-host before you report (add isolation:"worktree" to the agent opts when the agent mutates a repo).',
    'Return the VERDICT object describing the outcome.',
  ].join('\n')
}

phase('Work')

// One live agent call. opts: { label, phase, schema } — and isolation:'worktree'
// when the agent mutates a repo checkout. A valid negative verdict (ok:false
// inside the schema) is still a successful receipt; only null/throw is transport
// failure.
const workReceipt = await settle('work', () => agent(workPrompt(args.item ?? { name: 'subject' }), {
  label: 'work',
  phase: 'Work',
  schema: VERDICT,
}))
requireStage('Work', ['work'], [workReceipt], 1)
const result = workReceipt.value

// Fan-out example (commented). Map each input to a settled thunk, require one
// receipt per declared identity, then read values without filtering failures away.
// Recipe-specific thunks should also validate the schema's identity field before
// returning the value (for example verdict.id === it.id).
//
// const items = args.items ?? []
// const itemIds = assertUniqueExpectedIds('Work', items.map((it) => String(it.name)))
// const scopeFingerprint = JSON.stringify(items.map((it) => ({ id: String(it.name) })))
// const mutationCap = resolveMutationParallelism(itemIds, scopeFingerprint)
// const receipts = await runInWaves(items, mutationCap, 'Work', (it) => agent(workPrompt(it), {
//   label: 'work:' + it.name, phase: 'Work', schema: VERDICT, isolation: 'worktree',
// }), (it) => it.name)
// requireStage('Work', itemIds, receipts, itemIds.length)
// const results = receipts.map((receipt) => receipt.value)

// The main loop receives this return value and acts on the verdicts (e.g. merge
// the green ones, hold the rest). Agents never merge.
return { result }
