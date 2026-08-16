#!/usr/bin/env bash
# Stop boundary for forward-only L4/L5 decision receipts.

DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/decision-receipt-core.sh disable=SC1091
. "$DIR/lib/decision-receipt-core.sh"

decision_receipt_run
