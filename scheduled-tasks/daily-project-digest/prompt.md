# Daily project digest (daily, 08:00)

You are producing the user's **morning anchor**: a per-project status digest —
not an audit. For each registered project, report where it stands so the user
starts the day oriented. Always emit a report, every day including weekends (no
silent days).

This is the on-disk migration of the previously scheduler-embedded
`daily-project-digest` task (see `scheduled-tasks/README.md`). The scheduler
registration should be repointed to this directory.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Personal projects root: `__PROJECTS_ROOT__/`

If the control plane is not mounted, abort with an info finding documenting the
absence (no silent failure).

## Targets

Read `__TRELLIS_PATH__/registry.md` "Active projects"
at runtime. Target set = `registry \ blacklist`. Details in `targets.md`.

## Per-project status (the digest body)

For each target, gather cheaply (all on-disk / local git — no remote fetch):

1. **Branch** — current branch + dirty-file count.
2. **Last commit** — short SHA + subject + relative date.
3. **7-day activity** — commit count over the last 7 days.
4. **Open audit hits** — unresolved findings from this project's audit reports
   in the last 7 days (read `audits/` dated files; a finding is "unresolved" if
   it is not marked resolved/fixed).
5. **Suggested next move** — one line: the single most useful next action
   (e.g. "merge open PR #NN", "rebase stale branch", "address audit finding X").

Emit the full digest as the task report (the user's morning read).

## Audit-digest emission (C1 — feeds SessionStart)

In addition to the full report, for **each** target write a **tiny** advisory
file the `session-context` hook injects when work begins in that project:

- Path: `<project-root>/.claude/audit-digest.md`
- Content: a **count** of unresolved 7-day findings, then the **single**
  highest-priority one, then a pointer. Keep it under ~300 bytes — the hook caps
  its read at 400 and shares a 2000-char context budget. Example:

  ```
  # Audit digest (2026-07-05)
  3 unresolved findings (last 7d). Top: eslint 9→10 fleet-blocked (2026-06-09).
  Full: daily-project-digest report / audits/.
  ```

- If a project has **zero** unresolved findings, write a one-line clean state
  (`0 unresolved findings (last 7d).`) rather than deleting the file, so a stale
  digest never lingers.

This file is **advisory only** — it never blocks or mutates anything; it is a
push of what the daily pull already computed, surfaced at the moment work starts.
