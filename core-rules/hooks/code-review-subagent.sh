#!/usr/bin/env bash
# code-review-subagent.sh — Stop. Advisory review on edit-heavy turns.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Runs only on edit-heavy turns: ≥3 files changed OR ≥200 lines added/changed
#     in `git diff HEAD`. Threshold overridable via REVIEW_MIN_FILES /
#     REVIEW_MIN_LINES env vars from project .claude/hooks/config.sh.
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
# or a project-local script at $CLAUDE_PROJECT_DIR/.claude/agents/code-reviewer).
#
# Env-var/payload contract (exported to $REVIEWER):
#   AUTONOMY_LEVEL       — resolved integer 1–5 (same algorithm as session-context.sh)
#   DECISIONS_LOG_PATH   — absolute path to <canonical-root>/decisions-log.md
#   - At L4/L5 (resolved per core-rules/autonomy.md), the dispatched reviewer
#     also receives the contents of <canonical-root>/decisions-log.md and is
#     expected to flag implicit decisions in the diff that are missing from
#     the log. Reviewer input is a JSON envelope {diff, autonomy_level,
#     decisions_log}; lower levels receive an empty decisions_log string.
#     The reviewer's output schema (findings array) is unchanged.
#
# Reviewer-prompt guidance (Opus 4.8): the dispatched reviewer's job at this
# stage is COVERAGE, not filtering. Opus 4.8 follows "only report high-severity"
# instructions more faithfully than older models — told to be conservative it
# investigates just as deeply but converts fewer investigations into reported
# findings, silently dropping low-severity bugs it judges below the bar (recall
# falls even as precision rises). This hook is ALREADY the filter: severity ==
# "critical" blocks, everything else is advisory. So whoever wires the
# project-local $REVIEWER MUST prompt it to report every issue it finds —
# including low-confidence and low-severity ones — and attach `severity` plus an
# optional `confidence` (0.0–1.0) per finding, rather than self-filtering for
# importance. The block/advisory split here does the ranking. Concretely, the
# reviewer prompt should say something like: "Report every issue you find,
# including ones you are uncertain about or consider low-severity. Do not filter
# for importance or confidence — the hook does that. For each finding include a
# confidence level and estimated severity." `confidence` is back-compat:
# absent ⇒ treat as 1.0; the hook does not key off it today.

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

# --- Resolve canonical repo root + autonomy level ---
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO_ROOT=$(dirname "$(git rev-parse --git-common-dir)")
else
  REPO_ROOT="$PROJECT_DIR"
fi

# Autonomy resolution mirrors session-context.sh. Used to decide whether the
# reviewer receives the L4/L5 decision-log verification clause.
AUTONOMY_LEVEL=3
TRELLIS_CFG=""
if [ -n "${TRELLIS_ROOT:-}" ] && [ -f "$TRELLIS_ROOT/trellis.config.json" ]; then
  TRELLIS_CFG="$TRELLIS_ROOT/trellis.config.json"
fi
if [ -n "$TRELLIS_CFG" ] && command -v jq >/dev/null 2>&1; then
  FLEET=$(jq -r '.autonomy_default // empty' "$TRELLIS_CFG" 2>/dev/null)
  [ -n "$FLEET" ] && AUTONOMY_LEVEL="$FLEET"
fi
for cand in "$REPO_ROOT/.trellis.config.json" "$REPO_ROOT/trellis.config.json"; do
  if [ -f "$cand" ] && command -v jq >/dev/null 2>&1; then
    PL=$(jq -r '.autonomy // empty' "$cand" 2>/dev/null)
    [ -n "$PL" ] && AUTONOMY_LEVEL="$PL"
    break
  fi
done
SESSION_FILE="$REPO_ROOT/.claude/session-autonomy"
if [ -f "$SESSION_FILE" ]; then
  SESS=$(head -1 "$SESSION_FILE" | tr -d '[:space:]')
  case "$SESS" in 1|2|3|4|5) AUTONOMY_LEVEL="$SESS" ;; esac
fi
export AUTONOMY_LEVEL
export DECISIONS_LOG_PATH="$REPO_ROOT/decisions-log.md"

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

# --- Doc-only skip: if every changed file has a doc extension (.md/.mdx/.rst/.txt),
# skip. Earlier versions also skipped anything under `docs/` regardless of
# extension — that wrongly skipped non-doc files like `docs/scripts/setup.sh`
# or `docs/examples/app.ts`. The `(^|/)[^/]+\.ext$` anchor matches the final
# path segment only, so a doc anywhere in the tree (e.g. `src/notes.md`) still
# counts as a doc and a non-doc under `docs/` still counts as a non-doc.
NONDOC_COUNT=$(git diff HEAD --name-only 2>/dev/null \
  | grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
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
#   b) A project-local script: $CLAUDE_PROJECT_DIR/.claude/agents/code-reviewer.sh
#      reading the diff from stdin and emitting the JSON above.
#   c) An HTTP callback to a reviewer service.
#
# For now the skeleton exits 0 without dispatching, so stop flow is never blocked.
# -----------------------------------------------------------------------------

REVIEWER="${CODE_REVIEWER_CMD:-${PROJECT_DIR}/.claude/agents/code-reviewer.sh}"

if [ -x "$REVIEWER" ]; then
  # At L4/L5 the reviewer must also verify decision-log completeness vs diff.
  # Pass the decisions-log content (if any) and the level as a JSON envelope.
  if [ "$AUTONOMY_LEVEL" -ge 4 ] 2>/dev/null && [ -f "$DECISIONS_LOG_PATH" ]; then
    DECISIONS_PAYLOAD=$(head -c 50000 "$DECISIONS_LOG_PATH" 2>/dev/null)
  else
    DECISIONS_PAYLOAD=""
  fi
  REVIEW_PAYLOAD=$(jq -nc \
    --arg diff "$DIFF" \
    --arg level "$AUTONOMY_LEVEL" \
    --arg decisions "$DECISIONS_PAYLOAD" \
    '{diff: $diff, autonomy_level: ($level | tonumber), decisions_log: $decisions}')
  FINDINGS=$(printf '%s' "$REVIEW_PAYLOAD" | timeout 60 "$REVIEWER" 2>/dev/null || true)

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
