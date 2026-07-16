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
// the unit's work is provably on origin (pushed + PR URL present). Any error is
// logged and swallowed: teardown never fails the unit, never mutates the
// verdict, never aborts the run. Leaving the tree is the safe failure mode.
async function reap(t, verdict) {
  if (!verdict) return
  const worktreePath = hasText(verdict.worktree_path) ? verdict.worktree_path.trim() : ''
  if (verdict.pushed !== true || !hasText(verdict.pr_url) || worktreePath === '') return
  if (isUnsafeReapPath(worktreePath, t.path)) {
    log('fanout-verify: refusing to reap unsafe path "' + worktreePath + '" for target=' + t.name)
    return
  }
  try {
    await agent(reapPrompt(t, worktreePath), { label: 'reap:' + t.name, phase: 'Teardown' })
  } catch {
    log('fanout-verify: reap step errored for target=' + t.name + ' — worktree left in place')
  }
}

// --- Phase: Targets -------------------------------------------------------
// Targets come from args. Fallback: ask a discovery agent to read the
// control-plane registry's Active-projects table (filename reference is
// path-neutral; a baked absolute path would not be). No `fs` global exists.
phase('Targets')
let targets = args.targets
if (!targets || targets.length === 0) {
  const discovered = await agent(
    [
      'Read the control-plane registry.md "Active projects" table.',
      'Return its rows as targets: an array of { name, path } using the Project and Path columns.',
      'Skip any project listed in blacklist.md.',
    ].join('\n'),
    { label: 'resolve-targets', phase: 'Targets', schema: TARGET_LIST },
  )
  targets = discovered.targets
}
log('fanout-verify: ' + targets.length + ' target(s)')

// --- Phase: Fan-out -------------------------------------------------------
phase('Fan-out')
const verdicts = await parallel(
  targets.map((t) => () => agent(workPrompt(t), {
    label: 'fanout:' + t.name,
    phase: 'Fan-out',
    schema: VERDICT,
    isolation: 'worktree',
  })),
)

// --- Phase: Teardown ------------------------------------------------------
// Reap each unit's worktree ONCE its work is safely on origin (pushed + PR
// open). `parallel` aligns verdicts[i] with targets[i]; each reap is scoped to
// its own repo so concurrent removals across targets don't contend. Teardown is
// a pure side effect — verdicts are returned UNCHANGED. reap() is best-effort
// and cannot throw out of here, so a stuck lock / live process / racing remove
// leaves the tree in place (the safe failure mode) without failing the run.
phase('Teardown')
await parallel(targets.map((t, i) => () => reap(t, verdicts[i])))

// The main loop acts on these verdicts: auto-merge the GREEN PRs, HOLD the rest
// for review. Agents never merge — that decision lives here, in the caller.
return { verdicts: verdicts.filter(Boolean) }
