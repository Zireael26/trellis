#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PYTHON_BIN=${AEO_GATE_PYTHON:-python3}

exec "$PYTHON_BIN" "$SCRIPT_DIR/aeo_gate.py" diff "$@"
