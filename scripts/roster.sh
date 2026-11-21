#!/bin/sh
# Machine-local roster administration from this release's payload.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 -I "$SCRIPT_DIR/roster.py" "$@"
