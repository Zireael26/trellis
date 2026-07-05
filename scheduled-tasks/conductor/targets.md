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
