# core-rules / hooks

Canonical shell implementations of the spec in `../hooks.md`. Portable
inheritance links these files into `.claude/hooks/` and renders
`.claude/settings.local.json`; the Codex twins and rendered hook manifest live
under `.codex/`. The direct-copy settings manifests remain canonical legacy
surfaces.

## Scripts

**Tier 1 — fast-local (every turn)**

| Script | Event | Origin |
|---|---|---|
| `block-destructive.sh` | PreToolUse (Bash) | upstream, extended |
| `pr-gate-shiftleft.sh` | PreToolUse (Bash, `gh pr create`) | new |
| `skill-preload-guard.sh` | PreToolUse (Skill) | new |
| `skill-slash-guard.sh` | UserPromptExpansion (slash command) | new |
| `turn-baseline.sh` | UserPromptSubmit (turn-entry baseline for stop-verify's receipt trigger) | new |
| `reread-guard.sh` | PreToolUse (Edit/Write/MultiEdit) | new |
| `post-edit-verify.sh` | PostToolUse (Edit/Write/MultiEdit) | upstream, extended |
| `slop-tripwire.sh` | PostToolUse (Edit/Write/MultiEdit) | new |
| `truncation-check.sh` | unregistered (was PostToolUse Grep/Bash/Read) | upstream |
| `track-read.sh` | PostToolUse (Read/Write/Edit/MultiEdit) | new |
| `session-context.sh` | SessionStart (startup/resume) | new |
| `save-context-log.sh` | PreCompact | new |
| `post-compact-context.sh` | SessionStart (compact) | new |
| `inject-primer-index.sh` | SessionStart | new |
| `skill-size-preflight.sh` | unregistered (was SessionStart advisory) | new |
| `env-echo.sh` | SessionStart (environment probe) | new |
| `core-rules/hooks/wiki-skill-suggest.sh` | PostToolUse (Write/Edit/MultiEdit) | new |
| `core-rules/codex/hooks/wiki-skill-suggest.sh` | PostToolUse (Write/Edit/MultiEdit) | new |
| `core-rules/hooks/hookspath-guard.sh` | PostToolUse (Bash, advisory: core.hooksPath drift) | new |
| `core-rules/codex/hooks/hookspath-guard.sh` | PostToolUse (Bash, advisory: core.hooksPath drift) | new |

**User-global** (linked into `~/.claude/hooks/` by the user surface, wired in `templates/claude-user-settings.json`)

| Script | Event | Origin |
|---|---|---|
| `herdr-foreman-session.sh` | SessionStart (Herdr user-global) | new |
| `trellis-worktree-create.sh` | WorktreeCreate (central-root `cc-<name>` worktree, detached attach) | new |
| `trellis-worktree-remove.sh` | WorktreeRemove (refuses unsaved work; detach, `git worktree remove`, merged-branch delete) | new |

The local-template-only twins' inventory basenames are
`wiki-skill-suggest.sh` and `hookspath-guard.sh`; their exact Claude and Codex
paths are listed above.

**Tier 2 — heavy-gated (wrap-up)**

| Script | Event | Origin |
|---|---|---|
| `spec-gate.sh` | Stop | new |
| `decision-receipt.sh` | Stop (L4/L5 substantive turns) | new |
| `stop-verify.sh` | Stop | upstream, extended |
| `code-review-subagent.sh` | Stop (edit-heavy) | new |
| `propose-rules.sh` | unregistered (was Stop, default-on) | new |
| `primer-capture-nudge.sh` | unregistered (was Stop, edit-heavy) | new |
| `ui-verify.sh` | Stop (UI diff) | new |
| `stamp-turn.sh` | Stop | new |

Tier 3 (husky) lives outside this directory.

## Attribution

The four scripts marked "upstream" or "upstream, extended" are derived from
[iamfakeguru/claude-md](https://github.com/iamfakeguru/claude-md) (MIT).
Extensions vs upstream are documented in each script's header.

## How projects pick these up

`core-rules/inheritance-manifest.json` links the Claude and Codex hook trees and
renders `core-rules/templates/{claude-settings.local,codex-hooks.local}.json`
into each attached project. The direct-copy surfaces use
`core-rules/templates/claude-settings.json` and `core-rules/codex/hooks.json`.
The `wiki-skill-suggest.sh` and `hookspath-guard.sh` twins are intentionally
registered only by those attach-rendered local templates, not by either legacy
direct-copy manifest. `hookspath-guard.sh` is rendered behind
`[ -f "$h" ] || exit 0`, so a rollback to a payload without it leaves Bash
working; it is the only hook with that guard, because it is advisory.
`skill-size-preflight.sh`, `truncation-check.sh`, `propose-rules.sh` and
`primer-capture-nudge.sh` have no registration in any manifest since 1.3.12
(E-15); their scripts remain on disk.
Override project-local tooling through the harness hook `config.sh` files (for
example `TODOS_FILE`, `UI_PORT`, or `REVIEW_MIN_FILES`; see script headers).

## Dependencies

All scripts assume `jq` on PATH. Tool-specific checks (eslint, ruff,
clippy, etc.) degrade gracefully when the tool isn't installed.
