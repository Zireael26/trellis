#!/usr/bin/env bash
# truncation-check.sh — PostToolUse on Grep|Bash|Read. Advisory only; never blocks.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Triggers when tool_response length ≥ 50,000 chars OR contains a
#     "...truncated..." / "Output too large" marker.
#   - Returns {"additionalContext": "..."} for Claude's awareness.
#   - Always exit 0. Advisory only — the tool already ran.
#
# Dependencies: jq (required).
#
# Base: github.com/iamfakeguru/claude-md (MIT). Spec alignment:
#   - Explicit 50,000-char threshold per our hooks.md.
#   - Kept upstream's low-result-count grep heuristic as a bonus signal.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "truncation-check: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "truncation-check"

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# Normalize tool_response to a string regardless of shape.
TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -r '
  if (.tool_response | type) == "string" then .tool_response
  elif (.tool_response | type) == "object" then (.tool_response | tostring)
  else ""
  end
')

emit_advisory() {
  local msg="$1"
  jq -nc --arg msg "$msg" '{additionalContext: $msg}'
}

# 1) Explicit truncation markers.
if printf '%s' "$TOOL_RESPONSE" | grep -qE '\.\.\.truncated\.\.\.|Output too large|truncated output|\[truncated\]'; then
  emit_advisory "Result was truncated. Re-run with narrower scope or read the source file directly."
  exit 0
fi

# 2) ≥ 50,000 chars → treat as effective truncation.
RESP_LEN=${#TOOL_RESPONSE}
if [ "$RESP_LEN" -ge 50000 ]; then
  emit_advisory "Result is large (${RESP_LEN} chars, ≥50K). Narrow the scope or read specific files/ranges instead of scanning broadly."
  exit 0
fi

# 3) Bonus heuristic (upstream): grep returning ~0 results for a specific pattern.
if [ "$TOOL_NAME" = "Grep" ]; then
  RESULT_COUNT=$(printf '%s\n' "$TOOL_RESPONSE" | grep -c '^' 2>/dev/null || echo 0)
  PATTERN=$(printf '%s' "$INPUT" | jq -r '.tool_input.pattern // empty')
  if [ -n "$PATTERN" ] && [ "$RESULT_COUNT" -lt 5 ]; then
    emit_advisory "Low result count (${RESULT_COUNT}) for pattern '${PATTERN}'. If you expected more, the result may have been filtered; try a broader pattern or a different path."
    exit 0
  fi
fi

exit 0
