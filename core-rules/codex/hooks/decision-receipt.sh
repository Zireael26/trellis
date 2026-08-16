#!/usr/bin/env bash
# Stop boundary for forward-only L4/L5 decision receipts.

DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
CORE="$DIR/lib/decision-receipt-core.sh"
[ -f "$CORE" ] || CORE="$DIR/../../hooks/lib/decision-receipt-core.sh"
[ -f "$CORE" ] || { echo "decision-receipt: missing shared core — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/decision-receipt-core.sh disable=SC1091
. "$CORE"

decision_receipt_run
