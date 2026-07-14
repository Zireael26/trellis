// codex-executor — mixed-harness fan-out: execution-heavy bounded units go to
// Codex (the executor node); planning / review / synthesis stay on Claude (the
// orchestrator). This is the reusable shape for the dual-harness topology in
// `docs/codex-routing.md`: Claude owns the loop, Codex is one worker TYPE it
// dispatches to. Codex is a runtime-detected CAPABILITY, never a hard
// dependency — the `openai-codex` plugin is not part of Trellis and cannot ship
// to the public mirror, so absent-Codex must degrade to a clean Claude-only run.
// This file ships in the public mirror and is INERT without the plugin.
//
// Inputs (from `args`, never baked literals):
//   args.units          [{ name, kind, task, effort, justification?, targetCwd?,
//                        paths?, constraints?, nonGoals?, proof? }] — the work. `kind`
//                        routes it: 'execute' = execution-heavy bounded
//                        SYNCHRONOUS unit (large mechanical edit) → Codex when
//                        available; 'plan' | 'review' | 'synthesize' = judgment
//                        unit → always the orchestrator. Default kind 'execute'.
//                        `effort` is REQUIRED on every Codex-routable ('execute')
//                        unit — enum 'xhigh'|'max' (medium/high suspended
//                        2026-07-10 per docs/codex-routing.md §3), declared per
//                        unit from the docs/codex-routing.md §3 ladder; an
//                        omitted effort is a validation error, NEVER a default
//                        (spec 011 D1). 'ultra' is hard-rejected in recipes
//                        (spec 011 D4a). `justification` is REQUIRED (non-empty)
//                        when effort is 'max', optional otherwise; it is echoed
//                        into the receipt. `targetCwd` is REQUIRED on execute
//                        units and names the caller-provisioned stable worktree
//                        shared by producer + verifier. Workers never commit;
//                        the caller commits only after a green verdict.
//                        `paths` / `constraints` / `nonGoals` /
//                        `proof` feed the six-field work-order contract in the
//                        Codex prompt (spec 011 D5a). The blocking codex-worker
//                        owns companion launch/poll/result mechanics and never
//                        returns until the unit completes or fails.
//   args.codexAvailable  boolean — the presence-gate result, threaded in by the
//                        main loop (see Presence phase). Absent → a probe agent
//                        resolves it; unknown ultimately defaults to OFF.
//   args.supportedEfforts string[] — the accepted --effort set of the installed
//                        surface, threaded by the main loop from the D6
//                        preflight (scripts/codex-effort-preflight.sh), same
//                        pattern as codexAvailable. Absent → conservative
//                        default ['medium','high','xhigh'] (verified companion
//                        v1.0.5 reality — the fail-closed direction; a surface-
//                        capability floor, not an effort default). A unit whose
//                        validated effort is outside the set FAILS CLOSED:
//                        logged + degraded to Claude, never clamped (spec 011
//                        D6b / SC6).
//   args.branchPrefix    string — branch prefix for repo-mutating units
//                        (default 'chore/codex-exec'); a per-unit suffix is
//                        appended. No dates here.
//
// ─────────────────────────────────────────────────────────────────────────────
// DISPATCH MECHANICS — TWO paths to Codex; pick by WHERE the loop runs. The
// runnable code below is engine code, so it uses canonical mechanic (ii).
//
//   (i) Bash-direct — from the MAIN ORCHESTRATOR LOOP (a `/loop`, a scheduled
//       task, or an agent driving this by hand), which HOLDS the Bash tool:
//         node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> "<prompt>"
//       (tier from docs/codex-routing.md §3 — declared per unit, never defaulted)
//       ZERO wrapper, ZERO extra model — the orchestrator is already running,
//       so it spends nothing on a middleman. This is the leanest main-loop path.
//       It remains mandatory for the presence gate (`setup --json`) and is the
//       interactive-rescue-only path for a human-managed detached job.
//
//  (ii) In-engine blocking worker — from INSIDE a `.wf.js`, dispatch with
//       `agent(prompt, { agentType: 'codex-worker' })`. The worker launches the
//       companion, polls from the same cwd, applies its bounded stall recovery,
//       fetches the real result, and only then returns. This is the CANONICAL
//       in-workflow Codex path. The rescue forwarder remains interactive-only.
//
// When each applies: hold the Bash tool (main loop) → (i). Strictly in-engine,
// Workflow engine → (ii). Never use the interactive rescue forwarder as a
// producing Workflow node.
// ─────────────────────────────────────────────────────────────────────────────

export const meta = {
  name: 'codex-executor',
  description: 'Mixed-harness fan-out: route execution-heavy bounded units to Codex, keep planning/review/synthesis on the orchestrator; degrade cleanly to Claude-only when Codex is absent or limit-hit',
  phases: [
    { title: 'Presence', detail: 'capability-gate Codex via setup --json; unavailable → every unit on the orchestrator' },
    { title: 'Fan-out', detail: 'per unit: route by kind, dispatch to Codex or Claude, degrade a null/empty Codex result back to Claude' },
    { title: 'Verify', detail: 'orchestrator review gate over each executed artifact (the real diff, not the executor self-report) → verdicts' },
  ],
  // Loop-safety contract (`core-rules/loop-safety.md`). ONE-SHOT FAN-OUT: a
  // single dispatch barrier over the unit list, no rounds — so it is exempt
  // from no_progress and declares `no_progress_iterations: null` (its one
  // justified override). `max_iterations` / `budget_ceiling_usd` are omitted so
  // they genuinely inherit the resolved baseline (per-loop > project-local >
  // central > fallback). progress_signal is commit/PR, the natural marker for
  // an execution fan-out.
  //
  // PER-MODEL BUDGET RATE (cross-harness loop): this loop spends on BOTH Claude
  // and Codex units, so `budget_ceiling_usd` must not map every token at the
  // Opus rate. The run's budget accounting attributes Claude tokens at
  // `usd_per_mtok` and Codex tokens at the optional `codex_usd_per_mtok`
  // (see `core-rules/loop-safety.md` § Per-model rate). Those RATE VALUES live
  // in `trellis.config.json.loop_safety`, NOT here — this block carries only the
  // per-loop override subset (the null-for-one-shot signal), and never restates
  // a default (restating pins it and defeats a later central retune).
  safety: {
    no_progress_iterations: null,
    progress_signal: 'commit/PR',
  },
}

// ─────────────────────────────────────────────────────────────────────────────
// COMPONENT-D GUARDRAILS (inherited verbatim from the dynamic-workflows spec;
// cross-harness parallel orchestration IS Component D — do not re-decide them):
//   • HOLD-only PRs. An unattended cross-harness run NEVER auto-merges; every
//     verdict is HOLD-for-review. The main loop merges, agents never do.
//   • Own autonomy ceiling. This recipe does not float up to L5 implicitly;
//     it runs under its own declared ceiling.
//   • Bright-lines fire on EVERY Codex unit. Codex output flows back through the
//     orchestrator's review gate (the Verify phase below) — quality is NOT
//     laundered by running work on Codex. Destructive-op, external-message,
//     secrets, and DoD-receipt guards all still apply to Codex units.
//   • Overnight runs need bypass-permissions mode; harden every Codex-unit
//     prompt against unbounded `rm` / `$VAR.*` globs (they stall unattended
//     runs) and confine each write to an isolated worktree.
// ─────────────────────────────────────────────────────────────────────────────

// Capability-gate result from the presence probe (or threaded via args).
const GATE = {
  type: 'object',
  additionalProperties: false,
  required: ['available'],
  properties: {
    available: { type: 'boolean', description: 'true iff setup --json reported ready && codex.available && auth.loggedIn' },
    notes: { type: 'string', description: 'what the gate observed (optional)' },
  },
}

// Per-unit verdict from the orchestrator review gate. additionalProperties:false
// so nothing unexpected slips in.
const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['unit', 'harness', 'green', 'reviewed', 'notes'],
  properties: {
    unit: { type: 'string', description: 'unit name' },
    harness: { type: 'string', description: "who executed it: 'codex', 'claude', or 'claude(degraded)'" },
    branch: { type: 'string', description: 'branch the executor produced (empty if none)' },
    green: { type: 'boolean', description: 'true iff the produced artifact passed install+build+typecheck on-host' },
    reviewed: { type: 'boolean', description: 'true iff the diff cleared the orchestrator code-review gate' },
    notes: { type: 'string', description: 'what changed, what was held/dropped, and why' },
  },
}

const branchPrefix = args.branchPrefix ?? 'chore/codex-exec'
const units = args.units ?? []
const routesToCodex = (u) => (u.kind ?? 'execute') === 'execute'

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

// --- Unit-schema validation (spec 011 D1/D4a) — runs BEFORE any dispatch ----
// Every Codex-routable unit (kind 'execute', the default) declares effort
// explicitly at dispatch; an omitted effort field is a validation error, never
// a default. 'ultra' is hard-rejected in recipes — the dispatch surface
// (codex-worker → companion) caps at xhigh, and ultra's prompt-nudged
// delegation is invisible/non-resumable inside a deterministic workflow
// (docs/codex-routing.md §3; D4a satisfied 2026-07-10, reject stands on
// surface + visibility). 'max' requires a non-empty justification (echoed
// into the receipt).
// A violation THROWS — the run fails before any unit is dispatched; nothing is
// silently clamped or defaulted.
// medium/high suspended by operator directive 2026-07-10 (docs/codex-routing.md §3)
const EFFORT_ENUM = ['xhigh', 'max']
const concurrentTargetCwds = new Map()
for (const u of units) {
  if (!routesToCodex(u)) continue
  if (typeof u.targetCwd !== 'string' || u.targetCwd.trim() === '') {
    throw new Error('targetCwd required for execute unit "' + u.name + '" — caller must provision one stable producer/verifier worktree')
  }
  const normalizedTargetCwd = normalizeTargetCwd(u.targetCwd)
  const priorUnit = concurrentTargetCwds.get(normalizedTargetCwd)
  if (priorUnit !== undefined) {
    throw new Error(
      'codex-executor: execute units "' + priorUnit + '" and "' + u.name +
        '" share normalized targetCwd "' + normalizedTargetCwd + '" but execute concurrently',
    )
  }
  concurrentTargetCwds.set(normalizedTargetCwd, u.name)
  if (typeof u.effort !== 'string' || u.effort.trim() === '') {
    throw new Error('effort required for unit "' + u.name + '" — no default (spec 011 D1)')
  }
  if (u.effort === 'ultra') {
    log(
      'codex-executor: HARD-REJECT unit=' + u.name +
        " — effort 'ultra' is forbidden in recipes: the companion dispatch surface caps at xhigh" +
        ' and delegation is invisible/non-resumable in a deterministic workflow (docs/codex-routing.md §3; spec 011 D4a)',
    )
    throw new Error('unit "' + u.name + "\": effort 'ultra' is hard-rejected in recipes — surface caps at xhigh + delegation invisible (docs/codex-routing.md §3; spec 011 D4a)")
  }
  if (!EFFORT_ENUM.includes(u.effort)) {
    throw new Error(
      'unit "' + u.name + '": effort \'' + u.effort +
        "' is not in the enum ['xhigh','max'] (medium/high suspended 2026-07-10 — docs/codex-routing.md §3; spec 011 D1)",
    )
  }
  if (u.effort === 'max' && !(typeof u.justification === 'string' && u.justification.trim() !== '')) {
    throw new Error('unit "' + u.name + "\": effort 'max' requires a non-empty justification (spec 011 D1)")
  }
}

// Surface-capability floor (spec 011 D6b): the accepted --effort set, threaded
// by the main loop from the D6 preflight (scripts/codex-effort-preflight.sh).
// Absent → the conservative verified default (companion v1.0.5 rejects >xhigh)
// — the fail-closed direction. Enforcement lives in the Fan-out router: a
// Codex-routed unit whose effort is outside this set is logged + degraded to
// Claude, NEVER clamped to a lower tier.
const supportedEfforts = args.supportedEfforts ?? ['medium', 'high', 'xhigh']
const branchOf = (u) => branchPrefix + '-' + u.name
const workerReceipt = (r) => {
  if (typeof r !== 'string') return ''
  const match = r.match(/(?:^|\n)--- CODEX-WORKER RECEIPT ---\s*\n([\s\S]*?)\n--- END RECEIPT ---(?:\n|$)/)
  return match?.[1] ?? ''
}
const isEmpty = (r) =>
  r == null ||
  (typeof r === 'string' && (r.trim() === '' || /^STATUS:\s*(?:FAILURE|UNAVAILABLE)\b/im.test(workerReceipt(r))))
// Defensive assertion: codex-worker is blocking, so a background handle is a
// contract leak rather than a supported result. Keep the detector as a loud
// fail-closed assertion while the unit degrades to Claude.
const isJobHandle = (r) => {
  if (typeof r !== 'string') return false
  try {
    const parsed = JSON.parse(r)
    if (typeof parsed?.jobId === 'string' && parsed.jobId.trim() !== '' && parsed?.result == null) return true
  } catch {
    // Handles are commonly prose rather than standalone JSON.
  }
  return /(started in the background|\/codex:status|check .* for progress|^\s*job\s*id\s*[:=])/im.test(r)
}

// The prompt handed to Codex — the six-field work-order contract (spec 011
// D5a) plus the honest-reporting clause, verbatim. Leading routing flags
// (`EFFORT: <tier>`) are consumed by codex-worker; the tier is the unit's OWN
// validated declaration — recipes take required per-unit effort (spec 011),
// never a hardcoded or defaulted tier.
function codexPrompt(u) {
  return [
    'EFFORT: ' + u.effort,
    'JUSTIFICATION: ' + (u.justification ?? 'n/a'),
    'TARGET_CWD: ' + u.targetCwd,
    'You are the EXECUTOR for the bounded unit "' + u.name + '".',
    'GOAL: ' + (u.task ?? 'apply the requested change'),
    'REPO/PATHS: ' + (u.paths ?? 'the isolated worktree root — stay inside it'),
    'CONSTRAINTS: ' +
      (u.constraints ? u.constraints + ' ' : '') +
      'GIT DISCIPLINE: the caller already provisioned TARGET_CWD as the stable worktree on branch ' + branchOf(u) + '. ' +
      'Work ONLY there. NEVER checkout/switch/stash/clean, create/remove worktrees, commit, push, or merge. ' +
      'Confine every write to that worktree and do not run unbounded `rm` or `$VAR.*` globs. ' +
      'Leave the uncommitted diff for the verifier; the caller alone commits after a green verdict.',
    'NON-GOALS: ' + (u.nonGoals ?? 'anything not named in GOAL'),
    'PROOF: ' + (u.proof ?? 'state the exact verification command you ran and paste its actual output'),
    'OUTPUT: the branch name, a one-line summary of the diff, and the PROOF command output.',
    "Report failures as failures. Never claim completion without the proof command's actual output. A claimed-complete unit without receipts is treated as failed.",
    'The blocking codex-worker owns launch and polling. Return the completed result and receipt, never a job handle.',
  ].join('\n')
}

// The prompt for a unit that stays on the orchestrator (judgment units, and the
// degrade target for a failed Codex unit).
function claudePrompt(u) {
  return [
    'You are the orchestrator handling the unit "' + u.name + '" (kind: ' + (u.kind ?? 'execute') + ').',
    'TASK: ' + (u.task ?? 'apply the requested change'),
    routesToCodex(u)
      ? 'TARGET_CWD: ' + u.targetCwd + '\nWork only in that caller-provisioned stable worktree on branch ' + branchOf(u) + '; do not create/remove worktrees, commit, push, or merge. Leave the diff for independent verification.'
      : 'This is a planning/review/synthesis unit — produce the judgment, no repo mutation.',
  ].join('\n')
}

// (ii) In-engine blocking-worker dispatch. NO `schema`: codex-worker returns a
// completed raw receipt, and an empty/null result is still a degrade trigger.
// TARGET_CWD confines the write to the caller-provisioned stable worktree. Do
// not request engine isolation here: each isolated agent gets a different
// worktree, which would sever the producer from the verifier (H2).
// A THROWN dispatch error is folded into the same empty signal (return null) so
// "null/empty/errored" all degrade uniformly — the engine may reject rather
// than resolve-empty on a hard worker failure, and either way must fall to
// Claude. This is a system-boundary guard, not speculative defense.
async function dispatchCodex(u) {
  try {
    const r = await agent(codexPrompt(u), {
      agentType: 'codex-worker',
      label: 'codex:' + u.name,
      phase: 'Fan-out',
    })
    if (isJobHandle(r)) {
      // A blocking worker must never leak a handle. Log the assertion failure
      // and degrade rather than treating the handle as completed work.
      log('codex-executor: ASSERT blocking codex-worker leaked a job handle for unit=' + u.name + ' — degrading to Claude')
      return null
    }
    return r
  } catch {
    return null
  }
}

function dispatchClaude(u) {
  return agent(claudePrompt(u), {
    label: 'claude:' + u.name,
    phase: 'Fan-out',
  })
}

// --- Phase: Presence ------------------------------------------------------
// Capability gate. Prefer `args.codexAvailable` (the main loop runs the gate
// Bash-direct and threads the result in — the engine has no shell). Absent → a
// GENERAL probe agent runs the gate before any worker dispatch:
//   node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json
// Codex is available ONLY if ready && codex.available && auth.loggedIn.
// Unknown resolves to OFF — the safe degrade, and the public-mirror-inert path.
phase('Presence')
let codexAvailable = args.codexAvailable
if (codexAvailable === undefined) {
  // A dead/skipped probe agent resolves to null (Workflow semantics); a schema
  // failure may reject. Either way the gate is UNKNOWN, which must resolve to
  // OFF (the safe degrade) — never abort the run. So catch the throw and read
  // `gate?.available`, so a failed probe becomes Claude-only, not a crash.
  let gate = null
  try {
    gate = await agent(
      [
        'Check whether the local Codex CLI is callable. Run exactly:',
        '  node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json',
        'Parse the JSON. Report available=true ONLY if ready===true AND codex.available===true AND auth.loggedIn===true.',
        'If $CODEX_PLUGIN is unset, the script is missing, or the command errors, report available=false.',
        'Do not install anything or change any config. Return the GATE object.',
      ].join('\n'),
      { label: 'codex-presence', phase: 'Presence', schema: GATE },
    )
  } catch {
    gate = null
  }
  codexAvailable = Boolean(gate?.available)
}
codexAvailable = codexAvailable ?? false
log(
  'codex-executor: codex ' +
    (codexAvailable
      ? 'AVAILABLE — mixed-harness routing ON'
      : 'ABSENT — every unit runs on the orchestrator'),
)

// --- Phase: Fan-out -------------------------------------------------------
// One thunk per unit; parallel() barrier-joins. Route by kind + availability,
// then DEGRADE-TO-CLAUDE any null/empty/errored Codex result for the SAME unit.
// "Has limits" is not observable (no quota API) — a limit-hit and a task
// failure are the same signal, and both surface as an empty Codex result.
// Every degrade is log()'d so a run that silently became Claude-only is visible.
phase('Fan-out')
const executed = await parallel(
  units.map((u) => async () => {
    const receipt = { effort: u.effort ?? '', justification: u.justification ?? '' }
    if (!routesToCodex(u)) {
      const out = await dispatchClaude(u)
      return { unit: u.name, kind: u.kind ?? 'execute', harness: 'claude', branch: '', output: out, ...receipt }
    }
    // Fail-closed tier gate (spec 011 D6b/SC6): the surface does not accept
    // this unit's validated tier → log + degrade the UNIT to Claude. Never
    // rewrite the tier — a silent clamp is the exact failure D1 forbids.
    if (!supportedEfforts.includes(u.effort)) {
      log('codex-executor: FAIL-CLOSED unit=' + u.name + ' tier=' + u.effort + ' not supported by surface — degrading to Claude, no clamp')
      const out = await dispatchClaude(u)
      return { unit: u.name, kind: u.kind ?? 'execute', harness: 'claude(degraded)', branch: branchOf(u), targetCwd: u.targetCwd, output: out, ...receipt }
    }
    if (!codexAvailable) {
      const out = await dispatchClaude(u)
      return { unit: u.name, kind: u.kind ?? 'execute', harness: 'claude', branch: branchOf(u), targetCwd: u.targetCwd, output: out, ...receipt }
    }
    const codexOut = await dispatchCodex(u)
    if (isEmpty(codexOut)) {
      log('codex-executor: DEGRADE unit=' + u.name + ' — codex-worker unavailable/failure/empty/error, re-dispatching to orchestrator')
      const out = await dispatchClaude(u)
      return { unit: u.name, kind: u.kind ?? 'execute', harness: 'claude(degraded)', branch: branchOf(u), targetCwd: u.targetCwd, output: out, ...receipt }
    }
    return { unit: u.name, kind: u.kind ?? 'execute', harness: 'codex', branch: branchOf(u), targetCwd: u.targetCwd, output: codexOut, ...receipt }
  }),
)

// --- Phase: Verify --------------------------------------------------------
// Orchestrator review gate — quality is NOT laundered by routing to Codex.
// One Claude reviewer per unit that produced a branch. It reviews the REAL
// uncommitted artifact in the exact same caller-provisioned worktree, NOT the
// executor's stdout self-report or an empty branch diff, and runs the on-host
// green check. Bright-line guardrails fire here on Codex output too.
phase('Verify')
const artifacts = executed.filter((e) => e.branch)
const verdicts = await parallel(
  artifacts.map((e) => () => agent(
    [
      'REVIEW the unit "' + e.unit + '" executed by ' + e.harness + ' on branch ' + e.branch + '.',
      'TARGET_CWD: ' + e.targetCwd,
      'From that exact producer worktree inspect git status --short, git diff, git diff --cached, and any untracked declared files. Do not substitute a fresh worktree or trust the executor summary.',
      'On-host: install + build + typecheck (lint where present). green=true only if that passes.',
      'Apply the bright-line guardrails (destructive-op, secrets, external-message) to the diff.',
      'reviewed=true only if the diff clears code review. Do not edit, create/remove worktrees, commit, push, or merge. The caller commits only after this verdict. Return the VERDICT object.',
    ].join('\n'),
    { label: 'verify:' + e.unit, phase: 'Verify', schema: VERDICT },
  )),
)

// Receipt echo (spec 011 D1/SC3e): merge `effort` + `justification` from the
// unit's executed record into each returned verdict RECIPE-SIDE — a
// deterministic merge, never asked of the reviewer agent (echo-by-agent
// drifts). parallel() preserves order, so verdicts[i] pairs with artifacts[i].
const verdictReceipts = verdicts.map((v, i) =>
  v ? { ...v, effort: artifacts[i].effort, justification: artifacts[i].justification ?? '' } : v,
)

// Judgment units (plan/review/synthesize) produced no branch — carry their
// output through as-is for the caller to fold into synthesis (receipt fields
// echoed for uniform records; judgment units have no required effort).
const judgments = executed
  .filter((e) => !e.branch)
  .map((e) => ({ unit: e.unit, harness: e.harness, output: e.output, effort: e.effort ?? '', justification: e.justification ?? '' }))

// The main loop acts on these: HOLD every PR for review (Component-D), merge
// nothing here. Agents never merge — that decision lives in the caller.
return { codexAvailable, verdicts: verdictReceipts.filter(Boolean), judgments }
