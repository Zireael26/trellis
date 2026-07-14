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
    '  timeout runner: prefer `gtimeout`; else `timeout`; else `perl -e \'alarm shift; exec @ARGV\' ' + refreshTimeoutSeconds + ' git ...`.',
    '  command: git -C <repo_path> fetch --no-tags origin main',
    '  ceiling: ' + refreshTimeoutSeconds + ' seconds per repo.',
    'After a successful fetch resolve exactly: git -C <repo_path> rev-parse --verify refs/remotes/origin/main^{commit}',
    'Return one project/repo_path/main_sha row per repo. Set complete=false if enumeration, timeout support, fetch, or SHA resolution fails for ANY repo.',
    'Do not rank, retry, modify working trees, create branches, or continue on a partial refresh. Return REFRESH.',
  ].join('\n')
}

function rankPrompt(refs) {
  return [
    'You are the fleet CONDUCTOR ranking agent. Read-only. Produce a ranked slate.',
    '',
    'INPUTS:',
    '  - Backlog (source of truth): ' + (args.backlogPath ?? '<the Trellis conductor backlog.yml>'),
    '  - Active projects: ' + (args.registryPath ?? '<the control-plane registry.md>') + ' (minus blacklist.md)',
    '  - Today is ' + args.today + '. Use it for all deadline math (no system clock calls).',
    '  - IMMUTABLE_MAIN_REFS_JSON: ' + JSON.stringify(refs),
    '    For delivery and existing-spec anti-dup checks, inspect ONLY each listed main_sha. Never read mutable origin/main.',
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
const refreshed = await agent(refreshPrompt(), { label: 'refresh-refs', phase: 'Refresh refs', schema: REFRESH })
if (refreshed?.complete !== true || !Array.isArray(refreshed.refs)) {
  throw new Error('conductor: ref refresh incomplete; aborting before rank: ' + (refreshed?.notes ?? 'no receipt'))
}
const refByProject = new Map()
for (const ref of refreshed.refs) {
  if (typeof ref.project !== 'string' || ref.project.trim() === '' || typeof ref.repo_path !== 'string' || ref.repo_path.trim() === '' || !/^[0-9a-f]{40,64}$/.test(ref.main_sha)) {
    throw new Error('conductor: invalid immutable ref receipt; aborting before rank')
  }
  if (refByProject.has(ref.project)) {
    throw new Error('conductor: duplicate immutable ref receipt for project "' + ref.project + '"; aborting before rank')
  }
  refByProject.set(ref.project, ref.main_sha)
}

// --- Phase: Rank -----------------------------------------------------------
phase('Rank')
const slate = await agent(rankPrompt(refreshed.refs), { label: 'rank', phase: 'Rank', schema: SLATE })

// Select the top N eligible items for tonight's spec pass. Explicit force rows
// lead regardless of score; explicit false rows are exempt. Hard safety and
// anti-dup exclusions always win over force. Dedup by task id as a final
// recipe-side guard against duplicate backlog/model rows.
const ranked = slate.ranked ?? []
const noExclusions = (row) => Array.isArray(row.auto_spec_exclusions) && row.auto_spec_exclusions.length === 0
const noExistingSpec = (row) => typeof row.existing_spec_path === 'string' && row.existing_spec_path.trim() === ''
const hasBoundMain = (row) => refByProject.has(row.project)
const selectable = (row) => row.eligible_auto_spec === true && row.auto_spec !== false && row.delivered_on_main === false && noExistingSpec(row) && noExclusions(row) && hasBoundMain(row)
const orderedCandidates = [
  ...ranked.filter((row) => row.auto_spec === true && selectable(row)),
  ...ranked.filter((row) => row.auto_spec !== true && selectable(row)),
]
const seenIds = new Set()
const eligible = orderedCandidates.filter((row) => {
  if (seenIds.has(row.id)) return false
  seenIds.add(row.id)
  return true
})
const selected = eligible.slice(0, autoSpecTopN)
const duplicateCount = orderedCandidates.length - eligible.length
const exemptCount = ranked.filter((row) => row.auto_spec === false).length
const hardExcludedCount = ranked.filter((row) => !selectable(row) && row.auto_spec !== false).length
log('conductor: ranked ' + ranked.length + ' tasks; auto-speccing ' + selected.length + ' (top ' + autoSpecTopN + ' eligible; forced=' + orderedCandidates.filter((row) => row.auto_spec === true).length + ', exempt=' + exemptCount + ', hard-excluded=' + hardExcludedCount + ', duplicate=' + duplicateCount + ')')

// --- Phase: Auto-spec ------------------------------------------------------
// One-shot fan-out. Each agent works in its own worktree and returns a verdict.
// Agents never merge and never write code — they leave a reviewable spec.
phase('Auto-spec')
const specs = selected.length
  ? await parallel(
      selected.map((item) => () =>
        agent(specPrompt(item, refByProject.get(item.project)), {
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
