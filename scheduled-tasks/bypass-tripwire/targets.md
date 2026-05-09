# Targets — bypass-tripwire

Reads `__SE_CORE_PATH__/registry.md` at runtime. The registry minus `blacklist.md` is the target set — no hardcoded paths.

## Scope

- Daily on weekdays. Weekends intentionally excluded (low signal, high noise from casual work).
- Last 24h window. Never look further back — that's the weekly `cross-project-process-audit`'s job.

## If you want to skip a project for this scan

Add it to `blacklist.md` with reason `bypass-tripwire-suppress` and a review-after date.

## Per-project protected-branch list (override)

Default scan targets `main` and `master`. If a project uses a different convention, add a line here:

```
# <project-name>: <branch1>,<branch2>
```

No overrides set as of 2026-04-20.
