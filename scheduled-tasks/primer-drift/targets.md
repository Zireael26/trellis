# Targets — primer-drift

Reads `__TRELLIS_PATH__/registry.md` at runtime.
Target set = `registry \ blacklist`.

## Scope

- Weekly. Cadence: Monday 12:15 (after `preset-drift` 12:00). Lands in the
  Monday block because the SessionStart hook already covers the hot path;
  this is the cold-path backstop for long-idle projects.
- Read-only, single-host, no remote fetch.

## Per-project overrides

None today.

## Skip list

- Projects with no `.claude/primers/INDEX.md` are silently skipped (opt-in
  feature).

## Tunable thresholds

| Setting | Default | Override |
|---|---|---|
| STALE threshold (commits since pin) | 11 | env `PRIMER_DRIFT_STALE_THRESHOLD` |
| Entry-point path cap per primer | 10 | env `PRIMER_DRIFT_PATH_CAP` |
