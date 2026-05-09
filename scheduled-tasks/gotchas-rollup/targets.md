# Targets — gotchas-rollup

Reads `__SE_CORE_PATH__/registry.md` at runtime. Target set = `registry \ blacklist`.

## Scope

- Monthly, 1st at 9 AM.
- Looks at each project's `gotchas.md` — not the filesystem at large.

## Rule-of-Three thresholds (can be tuned)

- `PROMOTE_THRESHOLD = 3` — cluster must appear in this many distinct projects to graduate.
- `DEFERRED_THRESHOLD = 2` — cluster at this level queues into `deferred.md`.
- `STALE_AFTER_DAYS = 180` — deferred entries with no new data points in this window get flagged for removal.

Override by editing this file with a line like:
```
PROMOTE_THRESHOLD=4
```
Task reads these before running.
