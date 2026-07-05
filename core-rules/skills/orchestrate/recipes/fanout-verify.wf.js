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
  ],
  // Loop-safety contract (`core-rules/loop-safety.md`). This recipe is a
  // ONE-SHOT FAN-OUT: a single dispatch barrier over the target list, no
  // rounds. There are no consecutive iterations to measure, so it is exempt
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
  required: ['target', 'branch', 'pushed', 'green', 'pr_url', 'notes'],
  properties: {
    target: { type: 'string', description: 'target name' },
    branch: { type: 'string', description: 'branch the agent created (empty if none)' },
    pushed: { type: 'boolean', description: 'true iff the branch was pushed to origin' },
    green: { type: 'boolean', description: 'true iff install+build+typecheck (and lint, if present) passed' },
    pr_url: { type: 'string', description: 'PR URL, empty if none opened' },
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
    '  cd ' + t.path + ' && git fetch origin && git worktree add <tmp-worktree> -b ' + branchPrefix + '-' + t.name + ' origin/main',
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
    'Do NOT merge. Clean up your worktree when done (git worktree remove).',
    '',
    'Return the VERDICT object for target="' + t.name + '". If no branch was produced, set pushed=false and leave pr_url empty.',
  ].join('\n')
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

// The main loop acts on these verdicts: auto-merge the GREEN PRs, HOLD the rest
// for review. Agents never merge — that decision lives here, in the caller.
return { verdicts: verdicts.filter(Boolean) }
