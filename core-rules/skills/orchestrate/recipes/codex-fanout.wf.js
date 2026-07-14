// codex-fanout — mixed Codex/Claude implementation fan-out with independent
// Claude verification and one bounded repair round. `args.codexCap` is required
// and must be caller-resolved from `trellis.config.json.codex_fanout.concurrency`.
// Agents only produce and verify diffs. The calling orchestrator alone
// commits and merges dependency-ready work, in the returned receipt order.
//
// Inputs (all specifics come from args):
//   args.units       [{ name, leg, task, effort?, justification?, paths,
//                       proofCmd, conflicts?, targetCwd?, dependsOn? }]
//                    leg is 'codex'|'claude'. Codex effort is REQUIRED and is
//                    'xhigh'|'max' (medium/high suspended 2026-07-10 per
//                    docs/codex-routing.md §3); ultra is hard-rejected;
//                    max requires a non-empty justification. dependsOn is an
//                    array of unit names. conflicts requires targetCwd: a
//                    caller-provisioned stable worktree shared unchanged by
//                    generate, verify, and fix. Workers never commit it.
//   args.codexCap    REQUIRED positive integer resolved by the caller.
//   args.codexAvailable boolean capability-gate result; only true enables the
//                    Codex leg. Any other value degrades Codex units to Claude.
//   args.targetCwd   optional target root for worker/verifier prompts; when
//                    absent, the Workflow-provided checkout/worktree is used.
//   args.companionPath optional explicit companion path passed to codex-worker.

export const meta = {
  name: 'codex-fanout',
  description: 'Bounded mixed-harness generation with blocking Codex workers, cheap Claude actual-diff verification, one repair round, and dependency-ordered merge receipts',
  phases: [
    { title: 'Presence', detail: 'validate unit graph, effort contract, caller-resolved Codex cap, and capability state' },
    { title: 'Fan-out', detail: 'run bounded waves; Claude units consume no Codex slot and only conflicting units use worktrees' },
    { title: 'Verify', detail: 'cheap Claude reviewer inspects the actual diff and runs each declared proof command' },
    { title: 'Fix', detail: 'one same-leg repair round on failure followed by a fresh independent verification' },
  ],
  // Loop-safety (`core-rules/loop-safety.md`): omitted max_iterations and
  // budget_ceiling_usd inherit the resolved baseline. One worker
  // stall-cancel-retry is one no-progress iteration; a repeat hard-fails the
  // unit. The recipe adds no further repair loops beyond its single fix round.
  safety: {
    // First worker stall retries; a second no-progress iteration halts.
    no_progress_iterations: 1,
    progress_signal: 'file delta',
  },
}

const VERIFY = {
  type: 'object',
  additionalProperties: false,
  required: ['unit', 'green', 'reviewed', 'notes'],
  properties: {
    unit: { type: 'string', description: 'unit name' },
    green: { type: 'boolean', description: 'true only when the actual diff is in scope and proofCmd exits zero' },
    reviewed: { type: 'boolean', description: 'true only after inspecting the actual working-tree diff' },
    notes: { type: 'string', description: 'diff findings and actual proof outcome' },
  },
}

const units = args.units ?? []
const codexCap = args.codexCap
const defaultTargetCwd = args.targetCwd ?? '. (the Workflow-provided checkout/worktree root)'
// medium/high suspended by operator directive 2026-07-10 (docs/codex-routing.md §3)
const EFFORT_ENUM = ['xhigh', 'max']

function hasText(value) {
  return typeof value === 'string' && value.trim() !== ''
}

function pathText(paths) {
  return Array.isArray(paths) ? paths.join(', ') : String(paths ?? '')
}

function dependencyNames(unit) {
  return unit.dependsOn ?? []
}

function targetCwdOf(unit) {
  return unit.targetCwd ?? defaultTargetCwd
}

function normalizeTargetCwd(value) {
  const raw = value.trim().replace(/\/{2,}/g, '/')
  const absolute = raw.startsWith('/')
  const parts = []
  for (const part of raw.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (parts.length > 0 && parts[parts.length - 1] !== '..') parts.pop()
      else if (!absolute) parts.push(part)
      continue
    }
    parts.push(part)
  }
  const normalized = parts.join('/')
  return absolute ? '/' + normalized : normalized || '.'
}

function branchOf(unit) {
  return 'unit/' + unit.name
}

function workerReceipt(value) {
  if (typeof value !== 'string') return ''
  const match = value.match(/(?:^|\n)--- CODEX-WORKER RECEIPT ---\s*\n([\s\S]*?)\n--- END RECEIPT ---(?:\n|$)/)
  return match?.[1] ?? ''
}

function isFailedOutput(value) {
  if (value == null) return true
  if (typeof value !== 'string') return false
  if (value.trim() === '') return true
  return /^STATUS:\s*(?:FAILURE|UNAVAILABLE)\b/im.test(workerReceipt(value))
}

function isJobHandle(value) {
  if (typeof value !== 'string') return false
  try {
    const parsed = JSON.parse(value)
    if (hasText(parsed?.jobId) && !hasText(parsed?.result)) return true
  } catch {
    // Handles are commonly prose rather than standalone JSON.
  }
  return /(started in the background|\/codex:status|check .* for progress|^\s*job\s*id\s*[:=])/im.test(value)
}

function leakedJobId(value) {
  if (typeof value !== 'string') return ''
  try {
    const parsed = JSON.parse(value)
    if (hasText(parsed?.jobId)) return parsed.jobId
    if (hasText(parsed?.job?.id)) return parsed.job.id
  } catch {
    // Handles are commonly prose rather than standalone JSON.
  }
  return value.match(/\b(?:job|task)-[a-z0-9-]{6,}\b/i)?.[0] ?? ''
}

async function cancelLeakedJob(unit, value) {
  const jobId = leakedJobId(value)
  if (!jobId) {
    log('codex-fanout: leaked handle for unit=' + unit.name + ' did not expose a cancellable job id')
    return
  }
  const companion = args.companionPath ?? '$CODEX_PLUGIN/scripts/codex-companion.mjs'
  try {
    await agent([
      'A blocking codex-worker leaked job handle ' + jobId + '.',
      'From TARGET_CWD ' + targetCwdOf(unit) + ', attempt exactly:',
      'node "' + companion + '" cancel ' + jobId + ' --json',
      'Then run status once for the same id and report whether it still shows active. Do not edit files.',
    ].join('\n'), {
      agentType: 'general-purpose',
      label: 'cancel-leaked:' + unit.name,
      phase: 'Fan-out',
    })
  } catch {
    log('codex-fanout: leaked job cancel attempt failed for unit=' + unit.name + ' job=' + jobId)
  }
}

// --- Unit-schema validation (spec 011 D1/D4a) — runs BEFORE any dispatch ----
// Every Codex-routable unit declares effort explicitly at dispatch; an omitted
// effort field is a validation error, never a default. 'ultra' is hard-rejected
// (surface caps at xhigh + delegation invisible in a deterministic workflow —
// docs/codex-routing.md §3). 'max' requires a non-empty justification. A
// violation THROWS before any agent call; nothing is clamped or defaulted.
phase('Presence')
if (!Array.isArray(units)) throw new Error('codex-fanout: args.units must be an array')
if (!Number.isInteger(codexCap) || codexCap <= 0) {
  throw new Error('codex-fanout: caller-resolved codexCap is required and must be a positive integer')
}
log('codex-fanout: codexCap=' + codexCap + ' source=args')

const names = new Set()
for (const u of units) {
  if (!hasText(u.name)) throw new Error('codex-fanout: every unit requires a non-empty name')
  if (names.has(u.name)) throw new Error('codex-fanout: duplicate unit name "' + u.name + '"')
  names.add(u.name)
  if (u.leg !== 'codex' && u.leg !== 'claude') {
    throw new Error('unit "' + u.name + '": leg must be \'codex\' or \'claude\'')
  }
  if (!hasText(u.task)) throw new Error('unit "' + u.name + '": task is required')
  if (!(hasText(u.paths) || (Array.isArray(u.paths) && u.paths.length > 0 && u.paths.every(hasText)))) {
    throw new Error('unit "' + u.name + '": paths must be a non-empty string or string array')
  }
  if (!hasText(u.proofCmd)) throw new Error('unit "' + u.name + '": proofCmd is required')
  if (u.conflicts !== undefined && typeof u.conflicts !== 'boolean') {
    throw new Error('unit "' + u.name + '": conflicts must be a boolean when provided')
  }
  if (u.conflicts === true && !hasText(u.targetCwd)) {
    throw new Error('unit "' + u.name + '": targetCwd is required for conflicts=true so generate/verify/fix share one stable worktree')
  }
  if (!Array.isArray(dependencyNames(u)) || !dependencyNames(u).every(hasText)) {
    throw new Error('unit "' + u.name + '": dependsOn must be an array of unit names')
  }
  if (u.leg !== 'codex') continue
  if (typeof u.effort !== 'string' || u.effort.trim() === '') {
    throw new Error('effort required for unit "' + u.name + '" — no default (spec 011 D1)')
  }
  if (u.effort === 'ultra') {
    log(
      'codex-fanout: HARD-REJECT unit=' + u.name +
        " — effort 'ultra' is forbidden in recipes: the companion dispatch surface caps at xhigh" +
        ' and delegation is invisible/non-resumable in a deterministic workflow (docs/codex-routing.md §3; spec 011 D4a)',
    )
    throw new Error('unit "' + u.name + '": effort \'ultra\' is hard-rejected in recipes — surface caps at xhigh + delegation invisible (docs/codex-routing.md §3; spec 011 D4a)')
  }
  if (!EFFORT_ENUM.includes(u.effort)) {
    throw new Error(
      'unit "' + u.name + '": effort \'' + u.effort +
        "' is not in the enum ['xhigh','max'] (medium/high suspended 2026-07-10 — docs/codex-routing.md §3; spec 011 D1)",
    )
  }
  if (u.effort === 'max' && !(typeof u.justification === 'string' && u.justification.trim() !== '')) {
    throw new Error('unit "' + u.name + '": effort \'max\' requires a non-empty justification (spec 011 D1)')
  }
}

for (const u of units) {
  for (const dependency of dependencyNames(u)) {
    if (dependency === u.name) throw new Error('unit "' + u.name + '" cannot depend on itself')
    if (!names.has(dependency)) {
      throw new Error('unit "' + u.name + '" depends on unknown unit "' + dependency + '"')
    }
  }
}

function topologicalUnits(input) {
  const remaining = input.slice()
  const ordered = []
  const landed = new Set()
  while (remaining.length > 0) {
    const ready = remaining.filter((unit) => dependencyNames(unit).every((name) => landed.has(name)))
    if (ready.length === 0) {
      throw new Error('codex-fanout: dependsOn graph contains a cycle')
    }
    for (const unit of ready) {
      ordered.push(unit)
      landed.add(unit.name)
      remaining.splice(remaining.indexOf(unit), 1)
    }
  }
  return ordered
}

const mergeOrder = topologicalUnits(units)
const codexAvailable = args.codexAvailable === true
log('codex-fanout: codex ' + (codexAvailable ? 'AVAILABLE' : 'UNAVAILABLE — Codex units degrade to Claude'))

function workOrder(unit, mode) {
  const conflictDiscipline = unit.conflicts
    ? mode === 'generate'
      ? 'CONFLICTING UNIT: the caller already provisioned TARGET_CWD as the dedicated stable worktree on branch ' + branchOf(unit) + '. Make the bounded change there; never create/remove a worktree, commit, push, or merge. Leave the diff uncommitted for verification.'
      : 'CONFLICTING UNIT REPAIR: return to the same TARGET_CWD worktree on branch ' + branchOf(unit) + ', inspect its actual uncommitted state, and apply only the bounded repair. Never create/remove a worktree, commit, push, or merge; the caller commits only after a green reverify.'
    : 'WORKING-TREE UNIT: preserve the current checkout and working-tree semantics; never commit, switch branches, merge, or push.'
  return [
    'TASK_PROMPT: ' + mode + ' the bounded unit "' + unit.name + '".',
    'GOAL: ' + unit.task,
    'TARGET_CWD: ' + targetCwdOf(unit),
    'REPO/PATHS: ' + pathText(unit.paths),
    'CONSTRAINTS: change only the declared paths; inspect the current state first. ' + conflictDiscipline,
    'NON-GOALS: unrelated cleanup or any file outside REPO/PATHS.',
    'PROOF: ' + unit.proofCmd,
    'OUTPUT: files changed, actual proof command output, and any blocker.',
    "Report failures as failures. Never claim completion without the proof command's actual output. A claimed-complete unit without receipts is treated as failed.",
    unit.leg === 'codex' ? 'EFFORT: ' + unit.effort : '',
    unit.leg === 'codex' ? 'JUSTIFICATION: ' + (unit.justification ?? 'n/a') : '',
    unit.leg === 'codex' && args.companionPath ? 'COMPANION_PATH: ' + args.companionPath : '',
  ].filter(Boolean).join('\n')
}

function verifyPrompt(state) {
  const unit = state.unit
  const diffInstruction = unit.conflicts
    ? 'Inspect the REAL uncommitted state in this exact producer worktree: git status --short, git diff, git diff --cached, and any untracked declared files. Do not switch branches or substitute a fresh verifier worktree.'
    : 'Read the REAL working-tree state: run git status --short, inspect git diff and git diff --cached for the declared paths, and read any untracked declared files directly.'
  return [
    'Adversarially verify the bounded unit "' + unit.name + '" after execution by ' + state.harness + '.',
    'Work from TARGET_CWD: ' + targetCwdOf(unit) + '.',
    diffInstruction,
    'DECLARED PATHS: ' + pathText(unit.paths),
    'Run the proof command exactly and capture its actual exit/output: ' + unit.proofCmd,
    'Set reviewed=true only after inspecting that actual state. Set green=true only when the diff is in scope and proof exits zero.',
    'Do not edit, commit, merge, push, or trust the producer summary. Return the VERIFY object.',
  ].join('\n')
}

async function dispatchClaude(unit, mode, degraded) {
  return agent(workOrder(unit, mode), {
    label: (degraded ? 'claude(degraded):' : 'claude:') + mode + ':' + unit.name,
    phase: mode === 'generate' ? 'Fan-out' : 'Fix',
  })
}

async function dispatchCodex(unit, mode) {
  try {
    const output = await agent(workOrder(unit, mode), {
      agentType: 'codex-worker',
      label: 'codex:' + mode + ':' + unit.name,
      phase: mode === 'generate' ? 'Fan-out' : 'Fix',
    })
    if (isJobHandle(output)) {
      log('codex-fanout: ASSERT blocking codex-worker leaked a job handle for unit=' + unit.name + ' — cancelling leaked job and degrading to Claude')
      await cancelLeakedJob(unit, output)
      return null
    }
    return output
  } catch {
    return null
  }
}

async function generate(unit) {
  if (unit.leg === 'claude') {
    const output = await dispatchClaude(unit, 'generate', false)
    return { unit, harness: 'claude', output, attempts: 1, retries: 0, notes: [] }
  }
  if (!codexAvailable) {
    const output = await dispatchClaude(unit, 'generate', true)
    return { unit, harness: 'claude(degraded)', output, attempts: 1, retries: 0, notes: ['Codex unavailable; identical unit degraded to Claude'] }
  }
  const output = await dispatchCodex(unit, 'generate')
  if (isFailedOutput(output)) {
    log('codex-fanout: DEGRADE unit=' + unit.name + ' — codex-worker unavailable/failed/empty; re-dispatching identical unit to Claude')
    const degraded = await dispatchClaude(unit, 'generate', true)
    return { unit, harness: 'claude(degraded)', output: degraded, attempts: 2, retries: 1, notes: ['codex-worker failed; identical unit degraded to Claude'] }
  }
  return { unit, harness: 'codex', output, attempts: 1, retries: 0, notes: [] }
}

async function verify(state) {
  let verdict = null
  try {
    verdict = await agent(verifyPrompt(state), {
      agentType: 'general-purpose',
      label: 'verify:' + state.unit.name,
      phase: 'Verify',
      schema: VERIFY,
    })
  } catch {
    verdict = null
  }
  return { ...state, verdict }
}

async function fixAndReverify(state) {
  if (state.verdict?.green === true && state.verdict?.reviewed === true) return state

  const unit = state.unit
  let output = null
  let harness = state.harness
  let dispatchedAttempts = 1
  const fixNotes = ['one fix round dispatched after failed verification']
  if (state.harness === 'codex') {
    output = await dispatchCodex(unit, 'fix')
    if (isFailedOutput(output)) {
      log('codex-fanout: DEGRADE fix unit=' + unit.name + ' — codex-worker unavailable/failed/empty; re-dispatching identical fix to Claude')
      output = await dispatchClaude(unit, 'fix', true)
      harness = 'claude(degraded)'
      dispatchedAttempts += 1
      fixNotes.push('codex-worker fix failed; identical fix degraded to Claude')
    }
  } else {
    output = await dispatchClaude(unit, 'fix', state.harness === 'claude(degraded)')
  }

  const repaired = {
    ...state,
    harness,
    output,
    attempts: state.attempts + dispatchedAttempts,
    retries: state.retries + 1,
    notes: state.notes.concat(fixNotes),
  }
  const reverified = await verify(repaired)
  return {
    ...reverified,
    notes: reverified.notes.concat('fresh Claude reverify completed after fix'),
  }
}

// Build dependency-ready waves. Only units whose dependency receipts will have
// been produced by earlier waves are admitted. Within each topological layer,
// split only when the next Codex unit would exceed codexCap; Claude units do
// not consume a Codex slot.
function dependencyWaves(input) {
  const remaining = input.slice()
  const landed = new Set()
  const result = []
  while (remaining.length > 0) {
    const ready = remaining.filter((unit) => dependencyNames(unit).every((name) => landed.has(name)))
    if (ready.length === 0) throw new Error('codex-fanout: dependsOn graph contains a cycle')

    let bounded = []
    let codexInWave = 0
    for (const unit of ready) {
      const consumesCodexSlot = unit.leg === 'codex' && codexAvailable
      if (consumesCodexSlot && codexInWave === codexCap) {
        result.push(bounded)
        bounded = []
        codexInWave = 0
      }
      bounded.push(unit)
      if (consumesCodexSlot) codexInWave += 1
    }
    if (bounded.length > 0) result.push(bounded)

    for (const unit of ready) {
      landed.add(unit.name)
      remaining.splice(remaining.indexOf(unit), 1)
    }
  }
  return result
}

const waves = dependencyWaves(units)
for (let waveIndex = 0; waveIndex < waves.length; waveIndex += 1) {
  const targetOwners = new Map()
  for (const unit of waves[waveIndex]) {
    // The implicit workflow checkout intentionally supports parallel units
    // with disjoint declared paths. Only explicit targetCwd values claim a
    // caller-provisioned worktree and therefore must be unique per wave.
    if (!hasText(unit.targetCwd)) continue
    const normalizedTargetCwd = normalizeTargetCwd(targetCwdOf(unit))
    const priorUnit = targetOwners.get(normalizedTargetCwd)
    if (priorUnit !== undefined) {
      throw new Error(
        'codex-fanout: units "' + priorUnit + '" and "' + unit.name +
          '" share normalized targetCwd "' + normalizedTargetCwd +
          '" in concurrent wave ' + (waveIndex + 1),
      )
    }
    targetOwners.set(normalizedTargetCwd, unit.name)
  }
}

phase('Fan-out')
phase('Verify')
phase('Fix')
const receiptByName = new Map()

function makeReceipt(state) {
  const unit = state.unit
  const verdict = state.verdict
  const dependenciesGreen = dependencyNames(unit).every((name) => receiptByName.get(name)?.green === true)
  return {
    name: unit.name,
    leg: state.harness ?? unit.leg,
    effort: unit.effort ?? '',
    justification: unit.justification ?? '',
    branch: unit.conflicts === true ? branchOf(unit) : '',
    attempts: state.attempts ?? 0,
    retries: state.retries ?? 0,
    worktree: unit.conflicts === true,
    targetCwd: targetCwdOf(unit),
    proofCmd: unit.proofCmd,
    reviewed: verdict?.reviewed === true,
    green: verdict?.green === true && dependenciesGreen,
    notes: [
      ...(state.notes ?? []),
      verdict?.notes ?? 'verification returned no verdict',
      ...(dependenciesGreen ? [] : ['dependency not merge-ready']),
    ].join('; '),
    dependsOn: dependencyNames(unit),
  }
}

for (const boundedWave of waves) {
  const results = await pipeline(boundedWave, generate, verify, fixAndReverify)
  // Materialize receipts before the next wave can start. This is the runtime
  // dependsOn barrier, not merely a final-return sort.
  for (const state of results) receiptByName.set(state.unit.name, makeReceipt(state))
}

const receipts = mergeOrder.map((unit) => receiptByName.get(unit.name))

// Receipts are merge-ready metadata only. The orchestrator commits accepted
// worktree diffs serially in this dependency order; workers never commit.
return { codexAvailable, codexCap, receipts }
