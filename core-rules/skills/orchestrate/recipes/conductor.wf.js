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
//   args.weights      object  optional scoring-weight override; else read from backlog.
//
// Degrade: with a workflow tool, run as-is. Without, read meta.phases + the
// prompt builders below and dispatch each stage by hand (SKILL.md tier 2/3).

export const meta = {
  name: 'conductor',
  description: 'Rank the fleet backlog into a daily slate, then auto-spec the top eligible item(s) on a feature branch — hold code, never merge',
  phases: [
    { title: 'Rank', detail: 'read backlog + registry + per-project git signals, score every task, emit a ranked slate' },
    { title: 'Auto-spec', detail: 'top N eligible items: one worktree-isolated agent each runs spec -> plan -> tasks, holds code, returns a verdict' },
  ],
  // Loop-safety (`core-rules/loop-safety.md`). ONE-SHOT: a single rank pass, then
  // a single fan-out barrier over the selected items — no rounds. Exempt from
  // no_progress (declares null). max_iterations inherits the resolved baseline.
  // budget_ceiling_usd is OVERRIDDEN low: this is an unattended nightly writer
  // loop that should spec, not spend — a tight ceiling is a deliberate guardrail.
  safety: {
    no_progress_iterations: null,
    budget_ceiling_usd: 60,
    progress_signal: 'work-list drain',
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
        required: ['id', 'project', 'title', 'score', 'reasons', 'eligible_auto_spec'],
        properties: {
          id: { type: 'string' },
          project: { type: 'string' },
          title: { type: 'string' },
          score: { type: 'number', description: '0..1 composite; higher = do sooner' },
          reasons: { type: 'string', description: 'why this score — deadline/impact/staleness drivers, one line' },
          eligible_auto_spec: { type: 'boolean', description: 'true iff repo-backed, not manual, not blocked, not surgical' },
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

function rankPrompt() {
  return [
    'You are the fleet CONDUCTOR ranking agent. Read-only. Produce a ranked slate.',
    '',
    'INPUTS:',
    '  - Backlog (source of truth): ' + (args.backlogPath ?? '<the Trellis conductor backlog.yml>'),
    '  - Active projects: ' + (args.registryPath ?? '<the control-plane registry.md>') + ' (minus blacklist.md)',
    '  - Today is ' + args.today + '. Use it for all deadline math (no system clock calls).',
    '',
    'FOR EACH task in the backlog:',
    '  1. Compute the five normalized signals (0..1): deadline proximity (from `deadline` vs today),',
    '     impact (map `impact` via impact_scale), unblock (judgement from note/tags), effort',
    '     (effort_scale, subtracted), staleness (peek at the repo: many open branches + no recent',
    '     merge on the relevant area = higher). Weights come from backlog `weights` (or args.weights).',
    '  2. score = sum(weight * signal). Keep it auditable: state the 1-2 drivers in `reasons`.',
    '  3. eligible_auto_spec = repo is non-null AND safe != "manual" AND status not in',
    '     {blocked,done} AND surgical != true. Surgical and manual items are never auto-specced.',
    '',
    'Sort ranked by score descending. Return the SLATE object. Do not modify any file.',
  ].join('\n')
}

function specPrompt(item) {
  return [
    'You are a CONDUCTOR auto-spec agent for backlog task "' + item.id + '" (' + item.title + ')',
    'in repo ' + item.project + '. Tonight you SPEC ONLY — you do not write implementation code.',
    '',
    'GIT DISCIPLINE: the main checkout may be on a dirty WIP branch — never checkout/switch/stash/clean it.',
    'Work in an isolated worktree off latest origin/main:',
    '  git fetch origin && git worktree add <tmp> -b feature/' + item.id + ' origin/main',
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

// --- Phase: Rank -----------------------------------------------------------
phase('Rank')
const slate = await agent(rankPrompt(), { label: 'rank', phase: 'Rank', schema: SLATE })

// Select the top N eligible items for tonight's spec pass.
const eligible = (slate.ranked ?? []).filter((r) => r.eligible_auto_spec)
const selected = eligible.slice(0, autoSpecTopN)
log('conductor: ranked ' + (slate.ranked?.length ?? 0) + ' tasks; auto-speccing ' + selected.length + ' (top ' + autoSpecTopN + ' eligible)')

// --- Phase: Auto-spec ------------------------------------------------------
// One-shot fan-out. Each agent works in its own worktree and returns a verdict.
// Agents never merge and never write code — they leave a reviewable spec.
phase('Auto-spec')
const specs = selected.length
  ? await parallel(
      selected.map((item) => () =>
        agent(specPrompt(item), {
          label: 'spec:' + item.id,
          phase: 'Auto-spec',
          schema: SPEC_VERDICT,
          isolation: 'worktree',
        })
      )
    )
  : []

// Main loop consumes this: render the slate, list the specs waiting for a human
// to review and dispatch `execute`. Nothing here crosses the merge boundary.
return { slate, specs }
