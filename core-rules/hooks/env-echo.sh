#!/usr/bin/env bash
# env-echo.sh — one-line environment echo probe. Prints "<NAME>=<value>" for
# each variable name passed as an argument, one per line, exit 0. Used by the
# OMP adapter (core-rules/omp/hooks/pre/trellis.ts) to prove at attach time
# that TRELLIS_OMP=1 reaches canonical script environments — the marker that
# keeps model-backed stop scripts off the Claude/Codex `claude -p` rung.
#
# Pure: reads nothing from stdin, touches nothing, never blocks. printenv keeps
# the lookup free of eval/indirection so an argument can never execute. Variable
# names come from argv and/or TRELLIS_PROBE_VARS (whitespace-separated) — the
# adapter passes the list by env because runCanonicalHook fixes argv to the
# script path only.

set -u
for name in "$@" ${TRELLIS_PROBE_VARS:-}; do
  # Only valid POSIX shell names are echoed; anything else is skipped.
  case "$name" in
    ''|*[!A-Za-z0-9_]*) continue ;;
  esac
  printf '%s=%s\n' "$name" "$(printenv "$name" 2>/dev/null || true)"
done
exit 0
