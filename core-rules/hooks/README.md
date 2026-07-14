# core-rules / hooks

Canonical shell implementations of the spec in `../hooks.md`. These are
reference files. Projects copy the canonical set into their own
`.claude/hooks/` and point Claude Code's `settings.json` hook config at them.

## Scripts

**Tier 1 — fast-local (every turn)**

| Script | Event | Origin |
|---|---|---|
| `block-destructive.sh` | PreToolUse (Bash) | upstream, extended |
| `reread-guard.sh` | PreToolUse (Edit/Write/MultiEdit) | new |
| `post-edit-verify.sh` | PostToolUse (Edit/Write/MultiEdit) | upstream, extended |
| `truncation-check.sh` | PostToolUse (Grep/Bash/Read) | upstream |
| `track-read.sh` | PostToolUse (Read/Write/Edit/MultiEdit) | new |
| `session-context.sh` | SessionStart (startup/resume) | new |
| `save-context-log.sh` | PreCompact | new |
| `post-compact-context.sh` | SessionStart (compact) | new |
| `inject-primer-index.sh` | SessionStart | new |

**Tier 2 — heavy-gated (wrap-up)**

| Script | Event | Origin |
|---|---|---|
| `spec-gate.sh` | Stop | new |
| `stop-verify.sh` | Stop | upstream, extended |
| `code-review-subagent.sh` | Stop (edit-heavy) | new |
| `propose-rules.sh` | Stop (default-on, opt-out) | new |
| `ui-verify.sh` | Stop (UI diff) | new |
| `stamp-turn.sh` | Stop | new |

Tier 3 (husky) lives outside this directory.

## Attribution

The four scripts marked "upstream" or "upstream, extended" are derived from
[iamfakeguru/claude-md](https://github.com/iamfakeguru/claude-md) (MIT).
Extensions vs upstream are documented in each script's header.

## How projects pick these up

Copy the canonical scripts into your project's
`.claude/hooks/`, make them executable, register them in
`.claude/settings.json`. Override per-project tooling via a
`.claude/hooks/config.sh` exporting env vars (`TODOS_FILE`, `UI_PORT`,
`REVIEW_MIN_FILES`, etc. — see script headers).

## Dependencies

All scripts assume `jq` on PATH. Tool-specific checks (eslint, ruff,
clippy, etc.) degrade gracefully when the tool isn't installed.
