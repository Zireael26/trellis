# Targets — conductor

The conductor **always** reads `__TRELLIS_PATH__/conductor/backlog.yml`
(task source of truth) and `registry.md` (repo set) at runtime. Don't hardcode tasks here — this
file is config knobs only.

## Scope

- Cadence: daily at 06:00 local (IST). Runs before `daily-project-digest` (08:00) so the digest
  can reference the morning slate.
- Ordering: independent of the audits. It reads current repo state directly.

## Tunable thresholds

| Knob | Default | Meaning |
|---|---|---|
| `auto_spec_top_n` | **1** | How many top *eligible* backlog items get `spec -> plan -> tasks` overnight. `0` = rank only (pure slate, zero repo mutation). Raise to 2-3 once you trust the ranking. |
| `auto_execute_top_n` | **0** | **Component-D — default OFF.** How many top *safe* items **whose auto-spec (`spec->plan->tasks`) came out `ready`** get `execute`d to a **HOLD PR** overnight. `surgical` items skip the spec pipeline, so they carry no `ready` spec and are never auto-execute candidates. `0` = the conductor stops at spec and **"kick stops at PR" is fully preserved** — identical to today. When `>0`: those items are executed in an isolated worktree and opened as a `[HOLD]` PR — **never merged** (the merge bright-line is absolute at every value). Runs under its own ceiling (`conductor.wf.js meta.safety`) and needs bypass-perms for an unattended run. Raise only once you trust the pipeline end-to-end. |
| `default_engine` | `claude` | Executor for spec/plan/tasks. Per-task `engine:` in backlog.yml overrides. |
| `spec_budget_usd` | `60` | Mirrors the recipe's `meta.safety.budget_ceiling_usd`. Change in both places if you retune. |

Current shipped value: `auto_spec_top_n = 1` — the single top eligible item is specced each night
(local feature branch, no code, no push). Conservative on purpose for an unattended run. To go
rank-only, set `0`. To spec more, raise it.

## Per-project overrides

- None today. To force a specific task to be specced regardless of rank, set `auto_spec: true` on it
  in `backlog.yml`. To exempt one, set `auto_spec: false`.

## Skip list (never auto-specced)

- Any task with `safe: manual` — `cu-oci-migrate` (Curat OCI), `pvs-claim-shutdown` (validator shutdown).
- Any task with `surgical: true` — `vc-citations-off` (do it by hand, no spec pipeline).
- Non-registry projects with `repo: null` — `sudhamrit`, `persistence-validator-servers` (ranked for
  visibility, but no repo branch to spec into).
