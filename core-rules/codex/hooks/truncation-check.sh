#!/usr/bin/env bash
# truncation-check.sh — Codex PostToolUse on Grep|Bash|Read. Advisory only; never blocks.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Triggers when tool_response length ≥ 100,000 chars OR contains a
#     "...truncated..." / "Output too large" marker.
#   - Returns Codex PostToolUse hookSpecificOutput additionalContext.
#   - Always exit 0. Advisory only — the tool already ran.
#
# Dependencies: jq (required).
#
# Base: github.com/iamfakeguru/claude-md (MIT). Spec alignment:
#   - Explicit 100,000-char threshold per our hooks.md.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "truncation-check: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "truncation-check"

# Normalize tool_response to a string regardless of shape.
TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -r '
  if (.tool_response | type) == "string" then .tool_response
  elif (.tool_response | type) == "object" then (.tool_response | tostring)
  else ""
  end
')

emit_advisory() {
  local msg="$1"
  _se_emit_hook_context "PostToolUse" "$msg"
}

# 1) Explicit truncation markers.
if printf '%s' "$TOOL_RESPONSE" | grep -qE '\.\.\.truncated\.\.\.|Output too large|truncated output|\[truncated\]'; then
  emit_advisory "Result was truncated. Re-run with narrower scope or read the source file directly."
  exit 0
fi

# 2) ≥ 100,000 chars → treat as effective truncation.
RESP_LEN=${#TOOL_RESPONSE}
if [ "$RESP_LEN" -ge 100000 ]; then
  emit_advisory "Result is large (${RESP_LEN} chars, ≥100K). Narrow the scope or read specific files/ranges instead of scanning broadly."
  exit 0
fi

exit 0
