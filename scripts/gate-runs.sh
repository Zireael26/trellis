#!/usr/bin/env bash
# The durable records, not a wrapper PID, retain/quarantine the heavy slot.
set -euo pipefail
ROOT="$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)"
case "${1:-}" in
  status|reap)
    [ "$#" -eq 1 ] || { printf 'usage: scripts/gate-runs.sh status|reap\n' >&2; exit 64; }
    exec python3 "$ROOT/scripts/run-tests-local.py" "--runs-$1"
    ;;
  *) printf 'usage: scripts/gate-runs.sh status|reap\n' >&2; exit 64 ;;
esac
