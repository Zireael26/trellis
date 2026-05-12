#!/usr/bin/env bash
# post-compact-context.sh — Codex SessionStart (source=compact). Re-inject context-log.md.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Runs only when SessionStart.source == "compact".
#   - If context-log.md exists at the canonical project root (resolved via
#     `git rev-parse --git-common-dir` so worktrees still find it), emits it
#     as additionalContext.
#   - Never blocks. Exit 0 always.
#
# Dependencies: jq (required).
#
# Status: new in this core-rules layer.

set -u

INPUT=$(cat 2>/dev/null || true)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "post-compact-context: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "post-compact-context"

SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty')
if [ "$SOURCE" != "compact" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")
LOG="${REPO_ROOT}/context-log.md"

if [ ! -f "$LOG" ]; then
  exit 0
fi

# Cap injected content at ~4K chars — compact rehydration should be lean.
CONTENT=$(head -c 4000 "$LOG")
if [ -z "$CONTENT" ]; then
  exit 0
fi

jq -nc \
  --arg ctx "$CONTENT" \
  '{additionalContext: $ctx}'

exit 0
