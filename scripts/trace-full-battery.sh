#!/usr/bin/env bash
# Linux T32 collector. Usage: trace-full-battery.sh NEW_DIRECTORY [--workers N]
# Collection writes complete:false; promotion is a separate reviewed command.
set -euo pipefail
ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec python3 -I "$ROOT/scripts/trace-release-metadata.py" --collect "$@"
