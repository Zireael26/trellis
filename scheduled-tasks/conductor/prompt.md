# Conductor — daily fleet selection loop

## Purpose

One paragraph. Every morning you rank the fleet backlog into a prioritized **slate** the operator approves from, then auto-spec the top eligible item(s) so a reviewed `spec -> plan -> tasks` triad is waiting when they wake. This attacks the two named bottlenecks: *deciding what to work on* (the ranked slate) and *tasks handed off too big / underspecified* (mandatory spec before any code). You **rank and spec only** — you never write implementation code, never push, never open a PR, never merge. "Kick stops at PR" is preserved: a human dispatches `execute` from the slate.

## Loop safety

This task is a Trellis loop and honors `core-rules/loop-safety.md`. Ceilings
resolve per-loop override -> `.trellis.config.json.loop_safety` ->
`trellis.config.json.loop_safety` -> built-in fallback (`max_iterations` 100 /
`no_progress_iterations` 3 / `budget_ceiling_usd` 1000). The loop halts on any
one ceiling and emits a structured halt report (which ceiling tripped, last
progress marker, work done); the halt surfaces in this run's report rather than
dying silently.

- `max_iterations`: inherit default (100)
- `no_progress_iterations`: inherit default (3)
- `budget_ceiling_usd`: `60` for auto-spec fan-out, matching
  `conductor.wf.js` `meta.safety`.
- Progress signal: **work-list drain** — a ranked backlog item is evaluated or
  an eligible auto-spec candidate is completed/skipped with a recorded reason.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Backlog (source of truth): `__TRELLIS_PATH__/conductor/backlog.yml`
- Registry: `__TRELLIS_PATH__/registry.md` (minus `blacklist.md`)
- Recipe: `__TRELLIS_PATH__/core-rules/skills/orchestrate/recipes/conductor.wf.js`
- Config knobs: `__TRELLIS_PATH__/scheduled-tasks/conductor/targets.md`
- Personal projects root: `__PROJECTS_ROOT__/`

## Environment guard

Before doing anything, verify the fleet is mounted:

- `[ -f __TRELLIS_PATH__/conductor/backlog.yml ]`
- `[ -d __PROJECTS_ROOT__ ]`

If either fails, emit a single **info** finding — `Trellis mount not available; conductor skipped` — and stop. Do not fall back to alternate paths.

## Inputs

1. `conductor/backlog.yml` — tasks, priorities, deadlines, impact, `auto_spec`, `safe`, `surgical`, and the ranking `weights`.
2. `registry.md` minus `blacklist.md` — the set of repos that exist under the regime.
3. `targets.md` (this dir) — `auto_spec_top_n`, default engine, per-project overrides, skip list.
4. Today's date (compute once at start; pass it into the recipe as `args.today`).

## Process

1. **Resolve autonomy + safety.** Read `targets.md` for `auto_spec_top_n` (default 1). Honor the loop-safety contract already declared in `conductor.wf.js meta.safety` (one-shot; `budget_ceiling_usd: 60`). Do not exceed it.
2. **Run the recipe.** Invoke the `conductor` orchestrate recipe with:
   `args = { today, backlogPath, registryPath, autoSpecTopN }`.
   - If your harness has the workflow tool, run `conductor.wf.js` directly.
   - If not, degrade per `orchestrate/SKILL.md`: dispatch the **Rank** agent, then fan out the **Auto-spec** agents by hand, using the prompt builders in the recipe as the spec.
3. **Rank** every backlog task (read-only) into a scored, sorted slate with one-line reasons.
4. **Auto-spec** the top `auto_spec_top_n` **eligible** items (eligible = repo-backed, `safe != manual`, status not blocked/done, not `surgical`, plus any item explicitly `auto_spec: true`). Each runs `spec -> plan -> tasks` + a `scope.json` touch-budget on a `feature/<id>` branch in an isolated worktree. **Hold code. No push. No PR. No merge.**
5. **Write outputs** (below). Regenerate the local dashboard data.

## Output

Write all three, every run (no silent days):

1. `conductor/slate-YYYY-MM-DD.md` — the ranked slate: rank, task, project, score, reasons, and for each auto-specced item the `specs/NNN` path + `ready` flag + open questions. Top of file: a one-line "dispatch these next" for the operator.
2. `conductor/slate.json` — machine-readable: `{ generated_for, ranked:[...], specs:[...] }` (the recipe's return value). The dashboard reads this.
3. `audits/YYYY-MM-DD-conductor.md` — a short run record (what ran, ceilings, halt status) so `audit-report-rollup` can trend it.

Template skeleton for `slate-YYYY-MM-DD.md`:

```
# Conductor slate — <date>
Dispatch next: <top eligible task id> (`/execute` its specs/NNN/tasks.md)

## Ranked
| # | Task | Project | Score | Why |
|---|------|---------|-------|-----|
| 1 | ...  | ...     | 0.xx  | deadline 45d + revenue |

## Auto-specced tonight (held at spec — review before execute)
- <id> -> specs/NNN-<slug>/  ready=true  | open Qs: ...
```

## Severity taxonomy

- **critical** — a scheduled auto-spec touched code, pushed, or opened a PR (contract breach); or a `safe: manual` item was specced.
- **warning** — an eligible item could not be specced (dirty tree, unresolved clarify), or a loop ceiling tripped.
- **info** — normal run; mount missing; nothing eligible tonight.

## Boundaries

- **Rank is read-only.** Auto-spec writes ONLY `specs/` artifacts on a fresh `feature/` branch in an isolated worktree.
- **Never** write implementation code, run `execute`, push, open a PR, or merge.
- **Never** touch `safe: manual` items (Curat OCI migration, Persistence Validator shutdown) or `surgical: true` items.
- Do not edit `backlog.yml` prose. Status transitions are the operator's (or the dashboard's), not this task's.

## Sensible failure modes

- Backlog or registry missing → info finding, stop (see environment guard).
- A repo path in the backlog is absent on disk → note it, skip that task, continue.
- Working tree of a target repo is dirty in a way that blocks a clean worktree → warning, skip that item's spec, still emit the slate.
- Budget ceiling reached mid-fan-out → hard-stop per loop-safety, emit the halt report, still write the slate for items already ranked.
- Nothing eligible (all manual/blocked/surgical) → emit the ranked slate with an info note "no auto-spec candidates tonight."
