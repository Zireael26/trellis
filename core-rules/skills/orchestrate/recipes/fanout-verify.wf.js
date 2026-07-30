// fanout-verify — generic fan-out-per-target -> verify-on-host -> verdict recipe.
//
// The reusable shape extracted from Trellis one-shot scripts: one isolated agent
// per target works in a worktree, makes the change, VERIFIES it on the host
// (install/build/typecheck, lint if present, tests best-effort), pushes a branch,
// opens a PR, and returns a structured VERDICT. Agents NEVER merge — the main
// loop reads the verdicts and decides (auto-merge greens, hold the rest).
//
// Inputs (from `args`, never baked literals):
//   args.targets     [{ name, path }]  — repos to operate on. If absent, a
//                                        discovery agent reads the control-plane
//                                        registry's Active-projects table.
//   args.task        string            — what each agent should DO to its target.
//   args.branchPrefix string           — branch name prefix (e.g. 'chore/dep-bump').
//                                        Defaults to 'chore/fanout'. The agent
//                                        appends a per-target suffix; no dates here.
//   args.maxParallel  optional mutation-wave cap (default 2). Values >2 also
//                     require parallelJustification, an exact successful two-target
//                     pilotReceipt, and positive loopSafety.budget_ceiling_usd.
//
// This file ships in the public mirror — keep it parametric and path-neutral.
// No personal paths, no dated literals, no project names, no per-package lists.

export const meta = {
  name: 'fanout-verify',
  description: 'Fan out one verified-change agent per target, push + PR each, return verdicts for the main loop to merge/hold',
  phases: [
    { title: 'Targets', detail: 'resolve the target list from args or the registry' },
    { title: 'Fan-out', detail: 'one worktree-isolated agent per target: change -> verify -> push -> PR -> verdict' },
    { title: 'Teardown', detail: 'reap each unit worktree once its work is pushed + PR-open, re-verifying clean+pushed at reap time; best-effort, never fails a unit' },
  ],
  // Loop-safety contract (`core-rules/loop-safety.md`). This recipe is a
  // ONE-SHOT FAN-OUT: a fan-out dispatch over the target list followed by a
  // best-effort teardown pass, no rounds. There are no consecutive iterations
  // to measure, so it is exempt
  // from no_progress and declares `no_progress_iterations: null` — its one
  // justified override. `max_iterations` and `budget_ceiling_usd` are omitted
  // so they genuinely inherit the resolved baseline (per-loop > project-local >
  // central config > built-in fallback); they still bound the run, and omitting
  // them keeps the ceilings tracking the baseline if it is ever retuned.
  // `progress_signal` is commit/PR — the natural marker for a fleet-mutation
  // loop — though with no rounds it is informational rather than a halting input.
  safety: {
    no_progress_iterations: null,
    progress_signal: 'commit/PR',
  },
}

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

function assertUniqueExpectedIds(stage, ids) {
  const expected = ids.map(String)
  const seen = new Set()
  for (const id of expected) {
    if (seen.has(id)) throw new Error('fanout-verify: duplicate expected id "' + id + '" before ' + stage + ' dispatch')
    seen.add(id)
  }
  return expected
}

function resolveMutationParallelism(currentTargetIds, scopeFingerprint = '') {
  if (currentTargetIds.length === 0) return 2
  if (args.maxParallel === undefined) return 2
  if (!Number.isInteger(args.maxParallel) || args.maxParallel < 1) throw new Error('fanout-verify: args.maxParallel must be a positive integer')
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
  if (typeof args.parallelJustification !== 'string' || args.parallelJustification.trim() === '') throw new Error('fanout-verify: maxParallel > 2 requires non-empty args.parallelJustification')
  if (!pilotComplete) throw new Error('fanout-verify: maxParallel > 2 requires a current-run args.pilotReceipt bound to recipe, runId, exact first two target IDs, successes, and scope')
  if (typeof budgetCeiling !== 'number' || !Number.isFinite(budgetCeiling) || budgetCeiling <= 0) throw new Error('fanout-verify: maxParallel > 2 requires a positive existing safety budget')
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

// Per-target verdict. additionalProperties:false so nothing unexpected slips in.
const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['target', 'branch', 'pushed', 'green', 'pr_url', 'worktree_path', 'notes'],
  properties: {
    target: { type: 'string', description: 'target name' },
    branch: { type: 'string', description: 'branch the agent created (empty if none)' },
    pushed: { type: 'boolean', description: 'true iff the branch was pushed to origin' },
    green: { type: 'boolean', description: 'true iff install+build+typecheck (and lint, if present) passed' },
    pr_url: { type: 'string', description: 'PR URL, empty if none opened' },
    worktree_path: { type: 'string', description: 'absolute path of the isolated worktree the agent created for this target (empty if none). The caller reaps it after confirming the push; the agent must NOT remove it itself.' },
    notes: { type: 'string', description: 'what changed, what was dropped/held, and why' },
  },
}

// Shape returned by the discovery agent when args.targets is absent.
const TARGET_LIST = {
  type: 'object',
  additionalProperties: false,
  required: ['targets'],
  properties: {
    targets: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'path'],
        properties: { name: { type: 'string' }, path: { type: 'string' } },
      },
    },
  },
}

const branchPrefix = args.branchPrefix ?? 'chore/fanout'
const task = args.task ?? 'apply the requested change'

function workPrompt(t) {
  return [
    'You are operating on the repo "' + t.name + '" at ' + t.path + '.',
    'TASK: ' + task,
    '',
    'GIT DISCIPLINE: the checkout may be on a dirty WIP branch — NEVER checkout/switch/stash/clean it.',
    'Work ONLY in an isolated worktree off the LATEST origin/main:',
    '  cd ' + t.path + ' && git fetch origin && git worktree add <abs-tmp-worktree> -b ' + branchPrefix + '-' + t.name + ' origin/main',
    '  Use an ABSOLUTE path for <abs-tmp-worktree> and remember it — you MUST return it as worktree_path.',
    '',
    'Detect the package manager from the repo (lockfile / packageManager field). For a monorepo, target the right workspace.',
    'Make the change, then VERIFY ON-HOST in this order:',
    '  1. install succeeds',
    '  2. build succeeds',
    '  3. typecheck succeeds (the repo typecheck script, or tsc --noEmit)',
    '  4. lint succeeds IF the repo has a lint script',
    '  5. tests best-effort (an infra-only skip is acceptable; a real failure is not)',
    'If a sub-change breaks verification, DROP just that part, note it, and ship the rest green.',
    'green=true ONLY if the pushed branch is install+build+typecheck (and lint, where present) clean.',
    '',
    'If green: commit (conventional commit), push the branch with -u, and open a PR with `gh pr create`',
    '(title + body summarizing the change and stating "verified: install+build+typecheck green").',
    'Do NOT merge. Do NOT remove the worktree yourself — report its absolute path as worktree_path and',
    'leave it in place; the caller tears it down after confirming your branch is pushed.',
    '',
    'Return the VERDICT object for target="' + t.name + '". Set worktree_path to the absolute worktree path',
    '(empty if you created none). If no branch was produced, set pushed=false and leave pr_url empty.',
  ].join('\n')
}

function hasText(value) {
  return typeof value === 'string' && value.trim() !== ''
}

// True for a path we must never hand to `git worktree remove`: empties, the repo
// root itself, non-absolute or dotted paths. This is a cheap first gate; the
// reap agent independently re-verifies (via `git worktree list`) that the path
// is a LINKED, non-main worktree before removing anything.
function isUnsafeReapPath(worktreePath, repoPath) {
  const p = worktreePath.trim()
  if (p === '' || p === '.' || p === '/' || !p.startsWith('/')) return true
  if (p === (hasText(repoPath) ? repoPath.trim() : '')) return true
  return false
}

// Bounded reap work order. The agent RE-VERIFIES the safety predicate at reap
// time — never trusting the stale verdict — and removes the tree only if every
// check passes. A skip (or a refused remove) is an acceptable outcome.
function reapPrompt(t, worktreePath) {
  return [
    'You are reaping a throwaway git worktree in the repo "' + t.name + '" at ' + t.path + '.',
    'CANDIDATE_WORKTREE: ' + worktreePath,
    '',
    'A fan-out agent created this worktree, pushed its branch, and opened a PR, so its committed work is',
    'safe on origin and the checkout is disposable. Remove it — but ONLY after re-verifying, right now,',
    'that removal destroys nothing. Run these checks and PROCEED ONLY IF ALL pass:',
    '  1. `git -C ' + t.path + ' worktree list --porcelain` lists CANDIDATE_WORKTREE as a LINKED worktree',
    '     (a "worktree <path>" entry that is NOT the main working tree). If it is absent or is the main',
    '     worktree, STOP — do nothing.',
    '  2. CANDIDATE_WORKTREE is not ' + t.path + ', not the repo root, not "/", not ".".',
    '  3. `git -C CANDIDATE_WORKTREE status --porcelain` prints NOTHING. If it prints anything (any',
    '     uncommitted or untracked file), STOP — leave the tree for inspection.',
    '  4. HEAD is pushed: `git -C CANDIDATE_WORKTREE rev-parse @{u}` succeeds AND',
    '     `git -C CANDIDATE_WORKTREE rev-list --count @{u}..HEAD` prints 0. If there is no upstream or',
    '     the local tip is ahead, STOP — leave the tree.',
    '',
    'ONLY if every check passes: `git -C ' + t.path + ' worktree remove CANDIDATE_WORKTREE` (NEVER --force).',
    'If git refuses, do NOT retry with --force and do NOT delete the directory by hand — STOP and report.',
    'Do not touch any other worktree, branch, the main checkout, or origin. Never merge, push, or commit.',
    'Report one line: REAPED <path>, or SKIPPED <path> (reason). This is best-effort; a skip is fine.',
  ].join('\n')
}

// Reap ONE unit's worktree — best-effort and failure-isolated. Fires only once
// the unit's work is provably on origin (pushed + PR URL present). Deliberate
// skips are successful teardown outcomes; transport null/throw remains a failed
// optional receipt. Leaving the tree is always the safe failure mode.
async function reap(t, verdict) {
  if (!verdict) return { target: t.name, outcome: 'skipped' }
  const worktreePath = hasText(verdict.worktree_path) ? verdict.worktree_path.trim() : ''
  if (verdict.pushed !== true || !hasText(verdict.pr_url) || worktreePath === '') {
    return { target: t.name, outcome: 'skipped' }
  }
  if (isUnsafeReapPath(worktreePath, t.path)) {
    log('fanout-verify: refusing to reap unsafe path "' + worktreePath + '" for target=' + t.name)
    return { target: t.name, outcome: 'skipped' }
  }
  try {
    const result = await agent(reapPrompt(t, worktreePath), { label: 'reap:' + t.name, phase: 'Teardown' })
    return result == null ? null : { target: t.name, outcome: 'attempted' }
  } catch (error) {
    log('fanout-verify: reap step errored for target=' + t.name + ' — worktree left in place')
    throw error
  }
}

// --- Phase: Targets -------------------------------------------------------
// Targets come from args. Fallback: ask a discovery agent to read the
// control-plane registry's Active-projects table (filename reference is
// path-neutral; a baked absolute path would not be). No `fs` global exists.
phase('Targets')
let targets = args.targets
if (!targets || targets.length === 0) {
  const discoveryReceipt = await settle('resolve-targets', async () => {
    const discovered = await agent(
      [
        'Read the control-plane registry.md "Active projects" table.',
        'Return its rows as targets: an array of { name, path } using the Project and Path columns.',
        'Skip any project listed in blacklist.md.',
      ].join('\n'),
      { label: 'resolve-targets', phase: 'Targets', schema: TARGET_LIST },
    )
    return Array.isArray(discovered?.targets) ? discovered : null
  })
  requireStage('Targets', ['resolve-targets'], [discoveryReceipt], 1)
  targets = discoveryReceipt.value.targets
}
log('fanout-verify: ' + targets.length + ' target(s)')

// --- Phase: Fan-out -------------------------------------------------------
phase('Fan-out')
const targetIds = assertUniqueExpectedIds('Fan-out', targets.map((t) => String(t.name)))
const mutationScopeFingerprint = JSON.stringify({
  task,
  targets: targets.map((t) => ({ id: String(t.name), path: String(t.path ?? '') })),
})
const mutationCap = resolveMutationParallelism(targetIds, mutationScopeFingerprint)
log('fanout-verify: mutation maxParallel=' + mutationCap)
const verdictReceipts = await runInWaves(targets, mutationCap, 'Fan-out', async (t) => {
  const verdict = await agent(workPrompt(t), {
    label: 'fanout:' + t.name,
    phase: 'Fan-out',
    schema: VERDICT,
    isolation: 'worktree',
  })
  return verdict?.target === t.name ? verdict : null
}, (t) => t.name)
requireStage('Fan-out', targetIds, verdictReceipts, targetIds.length)
const verdicts = verdictReceipts.map((receipt) => receipt.value)

// --- Phase: Teardown ------------------------------------------------------
// Reap each unit's worktree ONCE its work is safely on origin (pushed + PR
// open). `parallel` aligns verdicts[i] with targets[i]; each reap is scoped to
// its own repo so concurrent removals across targets don't contend. Teardown is
// a pure side effect — verdicts are returned UNCHANGED. Failed teardown
// receipts stay visible in the optional gate, while a stuck lock / live process /
// racing remove still leaves the tree in place without failing the run.
phase('Teardown')
const verdictByTarget = new Map(verdicts.map((verdict) => [String(verdict.target), verdict]))
const teardownReceipts = await runInWaves(
  targets,
  mutationCap,
  'Teardown',
  (t) => reap(t, verdictByTarget.get(String(t.name))),
  (t) => t.name,
  0,
)
requireStage('Teardown', targetIds, teardownReceipts, 0)

// The main loop acts on these verdicts: auto-merge the GREEN PRs, HOLD the rest
// for review. Agents never merge — that decision lives here, in the caller.
return { verdicts }
