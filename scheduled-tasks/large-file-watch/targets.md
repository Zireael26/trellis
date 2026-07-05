# Targets - large-file-watch

## Scope

- Status: Tier 2 drafted, not scheduled.
- Proposed cadence: weekly, after `lint-debt-trend` if promoted.
- Target set: `registry.md` minus `blacklist.md`.

## Tunable thresholds

| Knob | Default | Meaning |
|---|---:|---|
| `WARNING_LOC` | 500 | Refactor-consideration threshold. |
| `CRITICAL_LOC` | 1000 | Refactor-plan threshold; context-compaction risk is high. |

Default ignore globs:

```
*.lock
package-lock.json
pnpm-lock.yaml
yarn.lock
**/dist/**
**/build/**
**/node_modules/**
**/migrations/**
**/*.snap
**/*.generated.*
```

## Per-project overrides

- None today. Add project-specific generated-file or fixture globs here only
  when the default ignore set produces repeated false positives.

## Skip list

- None today.
