#!/usr/bin/env bash
# code-review-subagent.sh — Codex Stop. Advisory review on edit-heavy turns.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Runs only on edit-heavy turns: ≥3 files changed OR ≥200 lines added/changed
#     in `git diff HEAD`. Threshold overridable via REVIEW_MIN_FILES /
#     REVIEW_MIN_LINES env vars from project hook config.
#   - Dispatches a code-review subagent against the diff; findings are advisory.
#   - Blocks only on severity=critical returned by the subagent.
#   - Budget: 60s soft cap.
#
# Dependencies: jq (required), git (required for diff / skipped otherwise).
#
# Status: NEW (no upstream template). v1 is a SKELETON — the actual subagent
# dispatch is marked TODO below. It relies on a Claude Code mechanism for
# invoking the Agent tool from inside a hook; that surface area is not yet
# standardized. Wire it up once Claude Code exposes a stable subagent-from-hook
# entrypoint (today options are: an HTTP callback, a `claude` CLI invocation,
# or a project-local script at $CODEX_PROJECT_DIR/.codex/agents/code-reviewer).

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "code-review-subagent: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "code-review-subagent"

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- Threshold check ---
MIN_FILES="${REVIEW_MIN_FILES:-3}"
MIN_LINES="${REVIEW_MIN_LINES:-200}"

# Count always outputs a number, never errors. Avoid `grep -c '^' || echo 0` —
# that doubles output to "0\n0" on empty input and breaks numeric comparisons.
CHANGED_FILES=$(git diff HEAD --name-only 2>/dev/null | awk 'END{print NR}')

# Sum added+deleted lines from numstat; skip binary rows (marked '-').
CHANGED_LINES=$(git diff HEAD --numstat 2>/dev/null \
  | awk '$1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum+0 }')

if [ "$CHANGED_FILES" -lt "$MIN_FILES" ] && [ "$CHANGED_LINES" -lt "$MIN_LINES" ]; then
  exit 0
fi

# --- Doc-only skip: if every changed file is markdown/docs, skip.
NONDOC_COUNT=$(git diff HEAD --name-only 2>/dev/null \
  | grep -vE '\.(md|mdx|rst|txt)$|^docs/' \
  | awk 'END{print NR}')
if [ "$NONDOC_COUNT" -eq 0 ]; then
  exit 0
fi

# --- Gather the diff for the reviewer (capped) ---
DIFF=$(git diff HEAD 2>/dev/null | head -c 200000)
if [ -z "$DIFF" ]; then
  exit 0
fi

# -----------------------------------------------------------------------------
# TODO (v1 skeleton): dispatch the `code-reviewer` subagent here.
#
# Expected interface once wired:
#   - Input: the $DIFF string above + PROJECT_DIR.
#   - Reviewer runs with read-only tools.
#   - Output: JSON on stdout shaped like:
#       {
#         "findings": [
#           {"severity":"info|warn|critical", "file":"...","line":N,"msg":"..."},
#           ...
#         ]
#       }
#   - If any finding has severity=="critical", this hook returns
#     {"decision":"block","reason":"<critical finding summary>"} and exits 2.
#   - Otherwise, findings are appended as advisory context.
#
# Implementation options (pick at Phase 2 wiring time):
#   a) `claude -p "Review this diff: ..." --agent code-reviewer` (CLI one-shot).
#   b) A project-local script: $CODEX_PROJECT_DIR/.codex/agents/code-reviewer.sh
#      reading the diff from stdin and emitting the JSON above.
#   c) An HTTP callback to a reviewer service.
#
# For now the skeleton exits 0 without dispatching, so stop flow is never blocked.
# -----------------------------------------------------------------------------

REVIEWER="${CODE_REVIEWER_CMD:-${PROJECT_DIR}/.codex/agents/code-reviewer.sh}"

if [ -x "$REVIEWER" ]; then
  FINDINGS=$(printf '%s' "$DIFF" | timeout 60 "$REVIEWER" 2>/dev/null || true)

  if [ -n "$FINDINGS" ]; then
    CRITICAL=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | select(.severity == "critical") | "- \(.file):\(.line // "?") \(.msg)"' 2>/dev/null | head -10)
    if [ -n "$CRITICAL" ]; then
      REASON="Code review flagged critical issues — resolve or explicitly defer:
${CRITICAL}"
      jq -nc --arg reason "$REASON" '{decision: "block", reason: $reason}'
      exit 2
    fi

    # Advisory findings → additionalContext (shown to Claude, not blocking).
    ADVISORY=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | "- [\(.severity)] \(.file):\(.line // "?") \(.msg)"' 2>/dev/null | head -30)
    if [ -n "$ADVISORY" ]; then
      jq -nc --arg ctx "<review>
${ADVISORY}
</review>" '{additionalContext: $ctx}'
    fi
  fi
fi

exit 0
