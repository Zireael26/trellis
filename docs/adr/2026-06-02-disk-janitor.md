# 2026-06-02 — Disk janitor: report-first fleet disk reclamation

## Context

A Trellis fleet machine filled its disk. The root cause was a single unscoped
`turbo.json` `outputs[]` glob: a `.next/**`-class entry with no `!.next/cache/**`
negation told turbo to cache the *entire* `.next` tree — including `.next/cache`,
which Next.js itself uses as a build cache and rewrites on every dev/build cycle.
The two layers compounded: turbo archived a fresh copy of `.next` (cache and all)
into `.turbo/cache` on each task run, and nothing ever evicted the old archives.
On one project (`vericite`) this reached **148 GB accumulated over two days**
before the disk pressure surfaced. The misconfiguration was fixed in place, but
the incident exposed two structural gaps:

1. **No fleet-wide view of reclaimable disk.** Build caches (`.turbo/cache`,
   `.next/cache`, `.next/dev`), stale `git worktree` checkouts, and package-store
   cruft accumulate silently across every registered project. Nothing measured
   them, so the first signal was a full disk, not a warning.

2. **The landmine recurs without a tripwire.** The unscoped-`outputs` pattern is
   easy to reintroduce — any new `turbo.json` task, or a copy-paste from another
   repo, can land it again. A one-time manual fix does not prevent the next one.

Two constraints from the existing Trellis machinery shaped the solution:

- **The scheduled-task MCP cannot measure disk.** The fleet's audits run headless
  in a sandbox (`claude -p` via `mcp__scheduled-tasks__*`) with no view of the
  host filesystem's true sizes — `du` inside the sandbox does not see the host's
  `node_modules`/`.next`/`.turbo` footprint. Disk measurement is inherently a
  **host** operation; it cannot live in the audit layer where every other Trellis
  health check lives.

- **`git branch --merged` is blind to the fleet's merge style.** Trellis projects
  merge via merge-commit (squash-merge is forbidden, §6.5), but several fleet
  repos historically squash-merged, and `git branch --merged` reports a
  squash-merged branch as *unmerged* (its commits never appear as ancestors of
  `main`). A worktree reaper keyed on `git branch --merged` would refuse to reap
  exactly the stale-but-merged branches it exists to clean up — and worse, could
  be coaxed into a false "merged" on a rebase. Merge detection has to be more
  robust than the built-in predicate.

## Decision

Ship **`trellis disk-janitor`** (`scripts/disk-janitor.sh` + the pure
`scripts/lib/disk-janitor-lib.sh` scanner library) — a **host CLI**, not an audit
— that scans the active fleet for three categories of reclaimable disk (build
caches, stale worktrees, package stores), reports what it found, and deletes only
when explicitly driven through a `--dry-run` preview into a confirmed `--apply`.

Three components, each report-first:

1. **The host CLI.** `trellis disk-janitor` defaults to `--report`: a human report
   to stdout plus a dated `audits/YYYY-MM-DD-disk-janitor.md`, including a tripwire
   (free space vs floor, largest cache vs ceiling) and a recurrence pre-pass that
   flags any project whose `turbo.json` carries the unscoped-`outputs` landmine.
   `--dry-run` prints the exact deletion plan (per-row human bytes + why-safe,
   worktrees with their gate verdict) and mutates nothing. `--apply` prints the
   plan, then **confirms per category** before deleting (mandatory `y/N` prompt
   unless `--yes`); a worktree is reaped only when **all four gates** hold —
   non-main, older than `worktree_stale_days`, working tree clean (untracked
   included), and verified-merged. Disk measurement lives on the host because the
   sandbox cannot see the real footprint.

2. **A launchd report agent.** `core-rules/templates/org.trellis.disk-janitor.plist`
   runs `trellis disk-janitor --report` daily off-peak (installed idempotently by
   `scripts/install-disk-janitor-launchd.sh`, `--uninstall` to remove). **The agent
   runs `--report` only — never `--apply`.** It turns the silent-accumulation
   failure mode into a daily artifact under `audits/`, so the next 148-GB build-up
   surfaces as a report line days before it is a full disk.

3. **A report-only doctor guard.** `hc_turbo_outputs` in
   `scripts/lib/health-checks.sh`, wired into `scripts/doctor.sh`'s Tier-1
   per-project loop, warns (`HC_WARN`) on any project whose `turbo.json` has the
   unscoped-`outputs` glob and prints the one-line fix. This is the recurrence
   tripwire promoted into the always-run health check.

**Report-first, never auto-delete.** Every component defaults to measuring and
reporting; deletion is a separate, explicitly-driven, per-category-confirmed step.
The launchd agent and the doctor guard are *incapable* of deleting — they only
report. This mirrors the `trellis doctor` shape (read-only by default; `--fix` is
explicit and gated): destructive disk reclamation is a bright-line action, so it
gets a bright-line guardrail.

### The report-only Component-3 refinement

The doctor guard (`hc_turbo_outputs`) was deliberately scoped to **report-only —
it does NOT get a `doctor --fix` action**, even though doctor's `--fix` machinery
exists and could in principle rewrite the offending `turbo.json`. `turbo.json` is
a **user-owned project file**, and Trellis's standing policy is that doctor never
auto-edits user-owned files — the same boundary that keeps `doctor --fix` from
rewriting a project's `CLAUDE.md` `@`-import (reported as manual-only). Auto-editing
`turbo.json` would also risk clobbering a deliberately-broad `outputs` glob a
project actually wants. The guard therefore warns and prints the canonical fix
(`dj_turbo_fix_hint`: add `!.next/cache/**` and `!.next/dev/**` negations); the
operator applies it. The fix-hint string has one source of truth in the library so
the doctor message and any future automation cannot drift.

## Consequences

- **Silent accumulation becomes a daily signal.** The launchd report puts a fleet
  disk summary under `audits/` every day; the next runaway cache surfaces as a
  report line, not a full disk.
- **The turbo landmine has a permanent tripwire** in two places — the disk-janitor
  recurrence pre-pass (when you run it) and the always-run doctor guard (every
  `trellis doctor`). The 148-GB-class incident cannot recur silently.
- **Reclamation is safe by construction.** Nothing deletes without a `--dry-run`
  preview and a per-category confirmation; the launchd agent and doctor guard
  cannot delete at all. Cache prune refuses any path that does not resolve under
  `PROJECTS_ROOT` and end in a known cache basename; worktree reaping requires all
  four gates and excludes any branch whose merge status is *unverified*.
- **Additive, reversible.** New scripts, one new library, one new `hc_*` check, an
  optional config object, and a launchd template — no change to inheritance, to any
  rule, or to doctor's existing checks. A project with no `disk_janitor` config
  block and no turbo.json is entirely unaffected.
- **Host-only by design.** Disk measurement does not work in the scheduled-task
  sandbox, so this capability lives outside the audit layer where every other
  Trellis health check lives. The launchd agent is the headless surface; there is
  no MCP audit equivalent, and that is intentional, not a gap.

## Alternatives considered

**Implement disk reclamation as a scheduled-task audit (the natural Trellis home).**
Rejected: the scheduled-task MCP runs headless in a sandbox that cannot see the
host filesystem's real sizes — `du` there does not measure the host's
`node_modules`/`.next`/`.turbo` footprint, which is the entire point. A survey of
the existing scheduled-task surface confirmed no audit can measure host disk. Disk
is a host operation; it gets a host CLI plus a launchd agent, not an MCP audit.

**Detect merged worktree branches with `git branch --merged`.** Rejected: it has a
squash-merge blind spot. A branch that was squash-merged (its commits replayed as a
single new commit on `main`) is reported by `git branch --merged` as *unmerged*,
because none of its original commits are ancestors of `main`. Several fleet repos
have squash-merge history, so a reaper keyed on this predicate would refuse to reap
the stale-merged branches it exists to clean. The reaper instead checks merge status
via `gh pr list --head <branch> --state merged` first, then a `[gone]`
remote-tracking signal after `git fetch --prune`; when neither is available it
returns **unverified** and the branch is reported as a candidate but **never reaped**
— fail-safe over fail-blind.

**Auto-fix the unscoped `turbo.json` via `doctor --fix`.** Rejected: `turbo.json`
is user-owned and a broad `outputs` glob may be intentional; auto-editing it
crosses the same boundary that keeps doctor from rewriting a project's `CLAUDE.md`.
The guard reports the landmine and prints the fix; the operator applies it. (See
"report-only Component-3 refinement" above.)

## Related

- Host CLI: `scripts/disk-janitor.sh`; scanner library: `scripts/lib/disk-janitor-lib.sh`.
- Launchd report agent: `core-rules/templates/org.trellis.disk-janitor.plist`; installer: `scripts/install-disk-janitor-launchd.sh`.
- Doctor guard: `scripts/lib/health-checks.sh` `hc_turbo_outputs`, wired in `scripts/doctor.sh`.
- Agent-facing UI: `core-rules/commands/disk-janitor.md`.
- Config: `scripts/lib/trellis.config.schema.json` (`disk_janitor` object), `core-rules/templates/trellis.config.json.example`.
- Build contract: `docs/plans/2026-06-02-disk-janitor.md`.
- Prior report-first-with-gated-mutation precedent: `docs/adr/2026-05-30-trellis-doctor.md`.
