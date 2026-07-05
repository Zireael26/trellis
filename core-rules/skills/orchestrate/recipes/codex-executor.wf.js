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
//   args.units          [{ name, kind, task }] — the work. `kind` routes it:
//                        'execute' = execution-heavy bounded SYNCHRONOUS unit
//                        (large mechanical edit) → Codex when available; 'plan' |
//                        'review' | 'synthesize' = judgment unit → always the
//                        orchestrator. Default kind 'execute'. NOTE: genuinely
//                        long-running / detached (`--background`) Codex units are
//                        NOT handled by this in-engine recipe — the forwarder is
//                        synchronous (see DISPATCH MECHANICS (ii)); background is
//                        a MAIN-LOOP Bash-direct pattern (mechanics (i)), out of
//                        scope here.
//   args.codexAvailable  boolean — the presence-gate result, threaded in by the
//                        main loop (see Presence phase). Absent → a probe agent
//                        resolves it; unknown ultimately defaults to OFF.
//   args.branchPrefix    string — branch prefix for repo-mutating units
//                        (default 'chore/codex-exec'); a per-unit suffix is
//                        appended. No dates here.
//
// ─────────────────────────────────────────────────────────────────────────────
// DISPATCH MECHANICS — TWO paths to Codex; you pick by WHERE the loop runs.
// Both are documented here with equal weight; the runnable code below is
// engine code, so it uses (ii), while (i) is the leaner path the MAIN LOOP uses.
//
//   (i) Bash-direct — from the MAIN ORCHESTRATOR LOOP (a `/loop`, a scheduled
//       task, or an agent driving this by hand), which HOLDS the Bash tool:
//         node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort xhigh "<prompt>"
//       ZERO wrapper, ZERO extra model — the orchestrator is already running,
//       so it spends nothing on a middleman. This is the PREFERRED path (the
//       plan's §3 REFINEMENT: the shipped executor node is Bash-direct). It is
//       also MANDATORY, not merely preferred, for two operations that cannot go
//       through the forwarder at all:
//         • the presence gate — `setup --json` (the forwarder is contractually
//           task-only and may not call `setup`);
//         • `--background` async units — the forwarder strips `--background` and
//           cannot call `status` / `result`, so polling a detached job is
//           Bash-direct only.
//
//  (ii) In-engine forwarder — from INSIDE a `.wf.js` running in the Workflow
//       engine, which exposes NO shell primitive (only agent/parallel/pipeline/
//       phase/log/args/budget). The only way to reach Codex from here is a
//       subagent: `agent(prompt, { agentType: 'codex:codex-rescue' })`. That
//       forwarder is `model: sonnet` — the CHEAPEST available middleman, cheaper
//       than making a general Opus agent shell out to Bash. It forwards ONE
//       `codex-companion task --write` and returns raw stdout. This path is
//       therefore SYNCHRONOUS, in-engine Codex dispatch only.
//
// When each applies: hold the Bash tool (main loop) → (i). Strictly in-engine,
// synchronous → (ii). Never route execution through a general Opus agent that
// only shells out — that is the most expensive of the three and buys nothing.
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
const branchOf = (u) => branchPrefix + '-' + u.name
const isEmpty = (r) => r == null || (typeof r === 'string' && r.trim() === '')
// §4 fix (RC.5): the codex-rescue forwarder's own heuristic may background a
// unit it judges "big/open-ended" (codex-rescue.md:24) and return a JOB HANDLE
// string instead of the work result — non-empty, so it slips past isEmpty and
// would silently replace the real diff with handle text in the fan-out. The
// in-engine forwarder is contractually barred from `status`/`result`
// (codex-rescue.md:28), so this recipe cannot poll; it detects the handle shape
// and degrades that unit to Claude. Background execution is a Bash-direct
// MAIN-LOOP pattern (mechanics (i)), never this in-engine path.
const isJobHandle = (r) =>
  typeof r === 'string' &&
  /(started in the background|task-[a-z0-9]{6,}|\/codex:status|check .* for progress)/i.test(r)

// The prompt handed to Codex. Leading routing flags (`--write --effort xhigh`)
// are recognized and applied by the codex-rescue forwarder (codex-cli-runtime
// contract), giving Codex its xhigh default. Codex's effort CEILING is xhigh —
// there is no `max` for Codex; do not request a higher tier. The Bash-direct
// path passes the same flags on the `task` command line instead.
function codexPrompt(u) {
  return [
    '--write --effort xhigh',
    'You are the EXECUTOR for the bounded unit "' + u.name + '".',
    'TASK: ' + (u.task ?? 'apply the requested change'),
    '',
    'GIT DISCIPLINE: the checkout may be a dirty WIP branch — NEVER checkout/switch/stash/clean it.',
    'Work ONLY in an isolated worktree off the LATEST origin/main, on branch ' + branchOf(u) + '.',
    'Confine every write to that worktree. Do NOT run unbounded `rm` or `$VAR.*` globs.',
    'Make the change, then leave the branch for the orchestrator to review. Do NOT merge.',
    'State the branch name and a one-line summary of the diff in your output.',
    'RUN SYNCHRONOUSLY IN THE FOREGROUND — this is a bounded unit; do NOT use --background. Return the actual branch name and diff summary as your result, never a job handle.',
  ].join('\n')
}

// The prompt for a unit that stays on the orchestrator (judgment units, and the
// degrade target for a failed Codex unit).
function claudePrompt(u) {
  return [
    'You are the orchestrator handling the unit "' + u.name + '" (kind: ' + (u.kind ?? 'execute') + ').',
    'TASK: ' + (u.task ?? 'apply the requested change'),
    routesToCodex(u)
      ? 'Work in an isolated worktree off origin/main on branch ' + branchOf(u) + '; do NOT merge.'
      : 'This is a planning/review/synthesis unit — produce the judgment, no repo mutation.',
  ].join('\n')
}

// (ii) In-engine forwarder dispatch. NO `schema`: the forwarder returns raw
// stdout and "returns nothing" on failure, so an empty/null result IS the
// degrade trigger — a schema would make the engine try to validate raw text.
// isolation:'worktree' confines the --write to a throwaway checkout (guardrail).
// A THROWN dispatch error is folded into the same empty signal (return null) so
// "null/empty/errored" all degrade uniformly — the engine may reject rather
// than resolve-empty on a hard forwarder failure, and either way must fall to
// Claude. This is a system-boundary guard, not speculative defense.
async function dispatchCodex(u) {
  try {
    const r = await agent(codexPrompt(u), {
      agentType: 'codex:codex-rescue',
      label: 'codex:' + u.name,
      phase: 'Fan-out',
      isolation: 'worktree',
    })
    if (isJobHandle(r)) {
      // Backgrounded despite the foreground directive → the result is a handle,
      // not the work. Degrade this unit to Claude rather than drop it silently.
      log('codex:' + u.name + ' returned a background job handle, not a result — degrading to Claude')
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
    isolation: routesToCodex(u) ? 'worktree' : undefined,
  })
}

// --- Phase: Presence ------------------------------------------------------
// Capability gate. Prefer `args.codexAvailable` (the main loop runs the gate
// Bash-direct and threads the result in — the engine has no shell). Absent → a
// GENERAL probe agent (NOT the forwarder, which is contractually barred from
// `setup`) runs the gate command:
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
    if (!(codexAvailable && routesToCodex(u))) {
      const out = await dispatchClaude(u)
      return { unit: u.name, kind: u.kind ?? 'execute', harness: 'claude', branch: routesToCodex(u) ? branchOf(u) : '', output: out }
    }
    const codexOut = await dispatchCodex(u)
    if (isEmpty(codexOut)) {
      log('codex-executor: DEGRADE unit=' + u.name + ' — Codex empty/error, re-dispatching to orchestrator')
      const out = await dispatchClaude(u)
      return { unit: u.name, kind: u.kind ?? 'execute', harness: 'claude(degraded)', branch: branchOf(u), output: out }
    }
    return { unit: u.name, kind: u.kind ?? 'execute', harness: 'codex', branch: branchOf(u), output: codexOut }
  }),
)

// --- Phase: Verify --------------------------------------------------------
// Orchestrator review gate — quality is NOT laundered by routing to Codex.
// One Claude reviewer per unit that produced a branch. It reviews the REAL
// artifact (the diff on the branch vs origin/main), NOT the executor's stdout
// self-report, and runs the on-host green check — same discipline as
// fanout-verify. Bright-line guardrails fire here on Codex output too.
phase('Verify')
const artifacts = executed.filter((e) => e.branch)
const verdicts = await parallel(
  artifacts.map((e) => () => agent(
    [
      'REVIEW the unit "' + e.unit + '" executed by ' + e.harness + ' on branch ' + e.branch + '.',
      'Inspect the ACTUAL diff (git diff origin/main...' + e.branch + '), not the executor summary.',
      'On-host: install + build + typecheck (lint where present). green=true only if that passes.',
      'Apply the bright-line guardrails (destructive-op, secrets, external-message) to the diff.',
      'reviewed=true only if the diff clears code review. Do NOT merge. Return the VERDICT object.',
    ].join('\n'),
    { label: 'verify:' + e.unit, phase: 'Verify', schema: VERDICT, isolation: 'worktree' },
  )),
)

// Judgment units (plan/review/synthesize) produced no branch — carry their
// output through as-is for the caller to fold into synthesis.
const judgments = executed
  .filter((e) => !e.branch)
  .map((e) => ({ unit: e.unit, harness: e.harness, output: e.output }))

// The main loop acts on these: HOLD every PR for review (Component-D), merge
// nothing here. Agents never merge — that decision lives in the caller.
return { codexAvailable, verdicts: verdicts.filter(Boolean), judgments }
