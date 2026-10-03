#!/usr/bin/env bash
# Stop boundary for forward-only L4/L5 decision receipts.

# Sibling first; the in-place fallback applies only inside the declared
# runtime's Codex tree (spec 055 R1.1), never a project-controlled hooks/lib/.
DIR=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
__h_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
CORE="$DIR/lib/decision-receipt-core.sh"
if [ ! -f "$CORE" ] && [ -n "$__h_rt" ] && [ "$DIR" = "$__h_rt/core-rules/codex/hooks" ]; then
  CORE="$DIR/../../hooks/lib/decision-receipt-core.sh"
fi
[ -f "$CORE" ] || { echo "decision-receipt: missing shared core — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/decision-receipt-core.sh disable=SC1091
. "$CORE"

# Override only the Codex emit path; the shared core's Claude exit-2 semantics
# remain untouched. Codex consumes a stdout JSON block on exit 0, whereas
# exit 2 would require a continuation prompt on stderr.
_dr_block() {
  local reason="$1"
  jq -nc --arg reason "decision-receipt: ${reason}" '{decision: "block", reason: $reason}'
  exit 0
}

decision_receipt_run
