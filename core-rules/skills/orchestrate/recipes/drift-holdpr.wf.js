// drift-holdpr — auto-remediate MECHANICAL drift to a HOLD PR per project.
//
// Component-D (higher autonomy). Takes mechanical drift findings — the kind
// `parent-hook-drift` (SHA256 canonical-vs-deployed hook mismatch) and
// `cross-project-process-audit` surface — and fans out one worktree-isolated
// agent per project that RE-SYNCS the canonical file into the project and opens
// a **HOLD PR**. It NEVER writes to a project's main, never merges: the human
// merges the PR. Only mechanical, byte-level drift (a canonical hook/file the
// project should carry verbatim) is in scope — never a behavioral change.
//
// Opt-in and inert until invoked: nothing calls this recipe automatically. The
// existing `sync-hooks.sh` already does the rsync; the NEW part here is the
// HOLD-PR orchestration around it (per the cross-model review of the spec).
//
// Inputs (from `args`, never baked literals):
//   args.drifts        [{ project, path, canonical, fix }] — drift rows. All
//                      mechanical rows for one project are grouped into the
//                      same remediation unit / HOLD PR.
//                      If absent, a discovery agent reads the latest
//                      parent-hook-drift audit report.
//   args.branchPrefix  branch name prefix. Defaults to 'chore/drift-sync'.
//
// This file ships in the public mirror — keep it parametric and path-neutral.

export const meta = {
  name: 'drift-holdpr',
  description: 'Auto-remediate mechanical drift (parent-hook-drift / audit findings) to a HOLD PR per project — re-sync canonical file, open PR, never merge, never touch project main',
  phases: [
    { title: 'Discover', detail: 'resolve drift list from args or the latest parent-hook-drift audit' },
    { title: 'Remediate', detail: 'one worktree-isolated agent per project: re-sync canonical -> verify -> HOLD PR' },
  ],
  // Component-D loop-safety: one-shot fan-out over the drift list (a single
  // dispatch barrier, no rounds), so `no_progress_iterations: null`. This recipe
  // OPENS PRs unattended, so it declares a conservative budget ceiling of its
  // own rather than inheriting — a runaway fan-out that opens dozens of PRs is
  // the failure mode to bound. `max_iterations` bounds the project count.
  safety: {
    no_progress_iterations: null,
    max_iterations: 25,
    budget_ceiling_usd: 40,
    progress_signal: 'HOLD PR opened',
  },
}

const DRIFT = {
  type: 'object',
  additionalProperties: false,
  required: ['project', 'path', 'fix', 'mechanical'],
  properties: {
    project: { type: 'string' },
    path: { type: 'string', description: 'the drifted file, repo-relative' },
    canonical: { type: 'string', description: 'canonical source path (optional)' },
    fix: { type: 'string', description: 'one-line what/why' },
    mechanical: { type: 'boolean', description: 'true iff a verified byte-level canonical mismatch (NOT an intentional project-local divergence). Only mechanical drifts are remediated.' },
  },
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['project', 'branch', 'pr_url', 'synced', 'notes'],
  properties: {
    project: { type: 'string' },
    branch: { type: 'string' },
    pr_url: { type: 'string', description: 'HOLD PR URL, empty if none opened' },
    synced: { type: 'boolean', description: 'true iff the canonical file was re-synced clean' },
    notes: { type: 'string' },
  },
}

const DRIFT_LIST = {
  type: 'object',
  additionalProperties: false,
  required: ['drifts'],
  properties: { drifts: { type: 'array', items: DRIFT } },
}

const branchPrefix = args.branchPrefix ?? 'chore/drift-sync'

function remediatePrompt(group) {
  const driftLines = group.drifts.flatMap((d) => [
    '- DRIFT: ' + d.path + ' — ' + d.fix,
    d.canonical ? '  CANONICAL SOURCE: ' + d.canonical : '',
  ]).filter(Boolean)
  return [
    'You are re-syncing ALL listed canonical files into the project "' + group.project + '" to clear mechanical drift.',
    ...driftLines,
    '',
    'STRICT SCOPE — mechanical only:',
    '- Re-sync EVERY drifted file named above from its canonical source, in this one project worktree. Change NOTHING else.',
    '- This is a byte-level re-sync, not a behavioral edit. If the "drift" turns out to be an intentional',
    '  project-local divergence (not mechanical), STOP and report it — do NOT overwrite it.',
    '',
    'GIT DISCIPLINE: the checkout may be a dirty WIP branch — NEVER checkout/switch/stash/clean it.',
    'Work ONLY in an isolated worktree off the LATEST origin/main, on branch ' + branchPrefix + '-' + group.project + '.',
    'Do NOT run unbounded `rm` or `$VAR.*` globs. Confine every write to that worktree.',
    '',
    'Then VERIFY the re-sync (the file now matches canonical; the project still builds if the file is executable),',
    'commit (conventional commit), push with -u, and open a **HOLD PR** with `gh pr create` —',
    'title prefixed "[HOLD] drift-sync:", body stating what drifted, that this is a mechanical re-sync,',
    'and "DO NOT MERGE without human review". Do NOT merge. Clean up the worktree.',
    '',
    'Return the VERDICT for project="' + group.project + '". synced=true only if every listed file was re-synced and verified. If you refused any row (non-mechanical), set synced=false, pr_url empty, and say why in notes.',
  ].join('\n')
}

// --- Phase: Discover ------------------------------------------------------
phase('Discover')
let drifts = args.drifts
if (!drifts || drifts.length === 0) {
  const discovered = await agent(
    [
      'Read the most recent parent-hook-drift audit report under the control-plane audits/.',
      'Return ONLY the MECHANICAL drift rows (a canonical hook/file whose deployed copy',
      'no longer matches by SHA256) as drifts: [{ project, path, fix, mechanical }].',
      'Set mechanical:true only for a verified byte-level canonical mismatch. If a row',
      'looks like an intentional project-local divergence, set mechanical:false (it will',
      'be excluded) — do NOT silently drop it, so the human can see it was considered.',
    ].join('\n'),
    { label: 'discover-drift', phase: 'Discover', schema: DRIFT_LIST },
  )
  drifts = discovered.drifts
}

// Fail-closed gate before any unattended fan-out (Component-D). Three guards,
// each in code — not prose — so a directly-passed `args.drifts` cannot bypass them:
//   1. mechanical filter: only verified byte-level drift is remediated. A row
//      without an explicit `mechanical:true` is treated as needs-review and skipped.
//   2. per-project grouping: every mechanical row for a project is retained in
//      one branch/PR, so parallel units cannot collide or silently drop files.
//   3. max_iterations cap: bounds the project count so a runaway list can't open
//      dozens of PRs — the loop-safety ceiling is enforced, not just declared.
const MAX = meta.safety.max_iterations
const mechanical = drifts.filter((d) => d.mechanical === true)
const grouped = new Map()
for (const drift of mechanical) {
  if (!grouped.has(drift.project)) grouped.set(drift.project, [])
  grouped.get(drift.project).push(drift)
}
const remediable = [...grouped.entries()].map(([project, projectDrifts]) => ({
  project,
  drifts: projectDrifts,
}))
const skipped = drifts.length - mechanical.length
if (skipped > 0) {
  log('drift-holdpr: ' + skipped + ' drift(s) skipped (non-mechanical or needs-review)')
}
const capped = remediable.slice(0, MAX)
if (capped.length < remediable.length) {
  log('drift-holdpr: capped at max_iterations=' + MAX + ' — ' + (remediable.length - capped.length) + ' project(s) deferred to a later run')
}
log('drift-holdpr: ' + mechanical.length + ' mechanical drift file(s) grouped into ' + capped.length + ' project HOLD PR(s)')

// --- Phase: Remediate -----------------------------------------------------
// One worktree-isolated agent per project. Stays on the orchestrator (Claude):
// the unit needs a structured VERDICT + `gh pr create`, and the codex-rescue
// forwarder returns raw stdout (no schema) — so routing it to Codex would break
// the verdict contract (same reason codex-executor omits schema on its Codex
// leg). The Component-D risk here is the unattended PR-opening, not the executor.
// HOLD PR only, never merge, never a project's main.
phase('Remediate')
const verdicts = await parallel(
  capped.map((group) => () => agent(remediatePrompt(group), {
    label: 'drift:' + group.project,
    phase: 'Remediate',
    schema: VERDICT,
    isolation: 'worktree',
  })),
)

// Every result is a HOLD PR for the human to review + merge (or a refusal for a
// non-mechanical divergence). Nothing here merges — the merge bright-line holds.
return { verdicts: verdicts.filter(Boolean) }
