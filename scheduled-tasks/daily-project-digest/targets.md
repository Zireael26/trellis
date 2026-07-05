# Targets — daily-project-digest

Reads `__TRELLIS_PATH__/registry.md` at runtime. Target
set = `registry \ blacklist` (every Active project, minus any temporarily
exempted in `blacklist.md`), plus the parent Trellis clone itself.

## Scope

- Daily at 08:00, weekends included — the user's morning anchor.
- Inputs are all on disk / local git (branch, log, `audits/` reports from the
  last 7 days). No remote fetch. Cheap, single-host.
- It reads audit reports produced by the other scheduled tasks; it does not run
  those audits itself, so it does not depend on their cadence — a stale audit
  simply shows as an older-dated finding.

## Outputs

1. The full per-project digest as the task report (the user's morning read).
2. A tiny `<project-root>/.claude/audit-digest.md` per project (count + top
   unresolved finding) that the `session-context` SessionStart hook injects when
   work begins. Advisory only — never blocks or mutates.
