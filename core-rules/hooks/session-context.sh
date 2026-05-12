#!/usr/bin/env bash
# session-context.sh — SessionStart (startup|resume). Inject repo context header.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Runs on SessionStart with source=startup or source=resume.
#   - Assembles: current branch, last 5 commits, dirty-file count,
#     context-log.md (if present), unresolved gotchas.md entries.
#   - context-log.md and gotchas.md are read from the canonical project root
#     (resolved via `git rev-parse --git-common-dir`) so worktree sessions
#     still see the repo-level files.
#   - Emits {"hookSpecificOutput":{"hookEventName":"SessionStart",
#            "additionalContext":"..."}}.
#   - Output trimmed to ≤ 2000 chars. Never blocks. Exit 0 always.
#
# Dependencies: jq (required), git (optional — skips git section if absent).
#
# Status: new in this core-rules layer (not in upstream template).

set -u

INPUT=$(cat 2>/dev/null || true)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "session-context: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "session-context"

SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"')

# Only run on startup/resume. compact is handled by post-compact-context.sh.
case "$SOURCE" in
  startup|resume) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

CTX=""

# --- Git section ---
# Branch / commits / dirty count reflect the active checkout (worktree HEAD
# when in a worktree, main HEAD otherwise) — the user's working context.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  DIRTY=$(git status --porcelain 2>/dev/null | awk 'END{print NR}')
  COMMITS=$(git log --oneline -n 5 2>/dev/null || true)

  CTX="${CTX}Branch: ${BRANCH}    Dirty files: ${DIRTY}

Last 5 commits:
${COMMITS}

"
fi

# --- context-log.md (from a previous session) ---
if [ -f "${REPO_ROOT}/context-log.md" ]; then
  LOG_CONTENT=$(head -c 800 "${REPO_ROOT}/context-log.md")
  CTX="${CTX}--- context-log.md (previous session) ---
${LOG_CONTENT}

"
fi

# --- Unresolved gotchas ---
# Convention: entries tagged with 'unresolved' (case-insensitive) in gotchas.md.
if [ -f "${REPO_ROOT}/gotchas.md" ]; then
  UNRESOLVED=$(grep -inE 'unresolved' "${REPO_ROOT}/gotchas.md" 2>/dev/null | head -10 || true)
  if [ -n "$UNRESOLVED" ]; then
    CTX="${CTX}--- Unresolved gotchas ---
${UNRESOLVED}

"
  fi
fi

if [ -z "$CTX" ]; then
  exit 0
fi

# Hard cap at 2000 chars per spec.
if [ "${#CTX}" -gt 2000 ]; then
  CTX=$(printf '%s' "$CTX" | head -c 1980)
  CTX="${CTX}
...[trimmed]"
fi

jq -nc \
  --arg ctx "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
