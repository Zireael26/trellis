# Targets — parent-hook-drift

Reads `__TRELLIS_PATH__/registry.md` at
runtime. Target set = `registry \ blacklist`.

## Scope

- Weekly, Sunday at 9 PM — deliberately end-of-week and late, so the
  Monday morning audits can act on findings the same week.
- Compares each project's `.claude/hooks/` against canonical in
  `__TRELLIS_PATH__/core-rules/hooks/`.

## Canonical hook manifest

**Single source of truth:** [`core-rules/hooks/README.md`](../../core-rules/hooks/README.md) — the Tier 1 + Tier 2 tables list every canonical hook by name and tier.

For audit-runtime matcher detail (which Claude Code event + matcher each hook must wire to in `settings.json`), see [`./prompt.md`](./prompt.md) "Canonical Claude hook manifest" section.

Earlier versions of this file kept the hook list inline. That created drift risk: adding a hook needed three edits (the README, this file, and `prompt.md`). Plan task P3.7 collapsed the duplication.

## Per-project allowlisted extras

Projects are allowed to have hooks beyond the canonical set. Known extras:

```
neev: check-module-boundary.sh
```

No other project-specific hooks as of 2026-04-20. If new ones appear, add
them here so they're not flagged as "unexpected".

## Universally allowed config files

Non-hook files in `.claude/hooks/` that any project may ship. Not flagged as
unexpected extras.

```
config.sh    # per-project env overrides (UI_PORT, UI_PATH, TODOS_FILE,
             # REVIEW_*). Sourced by ui-verify.sh (v2 canonical, 2026-04-24),
             # stop-verify.sh, code-review-subagent.sh.
```
