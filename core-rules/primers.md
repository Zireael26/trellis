# Feature primers

Trellis ships a primer system that gives agents pre-built context for stable
features, cutting exploration cost on tasks like testing, debugging, or extending
those features. `core-rules/CLAUDE.md` § Feature primers carries the load rule —
read the primer before exploring code when the task names a feature in INDEX.
This file carries the rest of the system: opt-in, authoring, staleness, storage,
and the command set.

## Opt-in

Project-level and implicit: if `<canonical-root>/.claude/primers/INDEX.md`
exists, primers are live for that project. Projects without that directory are
unaffected by any of this.

## At session start

The `inject-primer-index` SessionStart hook auto-injects
`.claude/primers/INDEX.md` — one line per primer, with a drift flag (FRESH /
WARM / STALE / MISSING_PATHS / UNREACHABLE_PIN / BROKEN / NO_ENTRY_POINTS). You
do not need to read INDEX manually. The path resolves at the canonical repo root
via `git rev-parse --git-common-dir`, the same pattern as `context-log.md`.

## Loading policy

1. **If the user's task names a feature, directory, or subsystem listed in INDEX,
   you MUST read that primer before exploring code.** Loading is not optional —
   that is why the primer exists. Cost is ~3 KB; re-exploring costs 50× that.
2. If the relevant primer shows drift status WARM, FRESH, or no flag, load and
   use it.
3. If it shows STALE / MISSING_PATHS / UNREACHABLE_PIN / BROKEN, tell the user
   before relying on it and offer `/primer-refresh`.
4. If the task touches a feature with no primer, do the work, then propose
   `/primer <feature-slug>` at the end to capture what you learned.

## Authorship and staleness

Primers are agent-written via `/primer` and hand-editable. Treat any hand-edits
to a primer as load-bearing — `/primer-refresh` patches around them rather than
overwriting.

Every primer is pinned to a commit SHA. When loading one, check quickly that the
referenced files still exist. If a primer looks stale (referenced files moved,
SHA unreachable), say so and suggest `/primer-refresh <slug>` rather than acting
on possibly-wrong information.

## What a primer describes

Stable shape — entry points, data flow, dependencies, test commands, gotchas.
Not line-by-line walkthroughs. A primer over ~150 lines, or one describing
implementation detail, should be split or trimmed.

## Storage

Primer files live at the canonical repo root (`<canonical-root>/.claude/primers/`),
not the worktree-specific path, so worktree sessions see the same primer set as
the main checkout. Same load-bearing canonical-root convention as the three
context-log hooks; see `gotchas.md` 2026-05-11 for the rationale.

## Commands

- `/primer <slug>` — create a new primer for a feature
- `/primer-refresh <slug>` — update an existing primer against current HEAD
- `/primer-check` — audit all primers for staleness (no changes made)
