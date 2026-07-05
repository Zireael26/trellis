# Targets - lint-debt-trend

## Scope

- Status: Tier 2 drafted, not scheduled.
- Proposed cadence: weekly, after `test-health` so failures and lint debt are
  read in the same weekly pass.
- Target set: `registry.md` minus `blacklist.md`.

## Tunable thresholds

| Knob | Default | Meaning |
|---|---:|---|
| `PROJECT_BUDGET_SECONDS` | 180 | Per-project lint/typecheck time budget. |
| `REGRESSION_PERCENT` | 20 | Week-over-week increase that becomes a regression finding. |
| `CLEANUP_PERCENT` | 20 | Week-over-week decrease that becomes a cleanup-win finding. |

## Per-project overrides

- None today. Add command overrides here only when the generic detector cannot
  find the repo's established lint/typecheck entrypoint.

## Skip list

- None today.
