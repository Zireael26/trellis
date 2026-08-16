#!/usr/bin/env bash
# Instance rollout adapter for Spec 033 Mode 2. This script is intentionally
# non-blocking: every enabled invocation emits exactly one verdict and exits 0.

set -u

_emit() {
  printf '%s\n' "[aeo-gate] $1" >&2
  exit 0
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
CFG=""
for candidate in "$ROOT/.trellis.config.json" "$ROOT/trellis.config.json"; do
  [ -f "$candidate" ] || continue
  CFG="$candidate"
  break
done
[ -n "$CFG" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=jq unavailable for configured gate"
fi
if ! jq -e '.' "$CFG" >/dev/null 2>&1; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=malformed Trellis config"
fi
if ! jq -e 'has("aeo_gate")' "$CFG" >/dev/null 2>&1; then
  exit 0
fi

ENABLED=$(jq -r '.aeo_gate.enabled | if type == "boolean" then tostring else "malformed" end' "$CFG" 2>/dev/null)
case "$ENABLED" in
  false|null|'') exit 0 ;;
  true) ;;
  *) _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=malformed enabled flag" ;;
esac

RANGE=${AEO_GATE_RANGE:-origin/main..HEAD}
if ! CHANGED=$(git -C "$ROOT" diff --no-renames --name-only --diff-filter=ACDMR "$RANGE" -- 2>/dev/null); then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=git range unavailable"
fi
if ! printf '%s\n' "$CHANGED" | grep -Eiq '\.(html?|mdx?|tsx?|jsx?|vue|svelte|astro)$'; then
  exit 0
fi

PROJECT=$(jq -r '(.aeo_gate.project // empty) | strings' "$CFG" 2>/dev/null)
URL=$(jq -r '(.aeo_gate.url // empty) | strings' "$CFG" 2>/dev/null)
MARKER_FILE=$(jq -r '(.aeo_gate.marker_file // empty) | strings' "$CFG" 2>/dev/null)
MARKER=$(jq -r '(.aeo_gate.marker // empty) | strings' "$CFG" 2>/dev/null)
BASELINE=$(jq -r '(.aeo_gate.baseline // empty) | strings' "$CFG" 2>/dev/null)
if [ -z "$PROJECT" ] || [ -z "$URL" ] || [ -z "$MARKER_FILE" ] || [ -z "$MARKER" ] || [ -z "$BASELINE" ]; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=incomplete aeo_gate config"
fi
case "$BASELINE" in
  /*) BASELINE_PATH="$BASELINE" ;;
  *) BASELINE_PATH="$ROOT/$BASELINE" ;;
esac
[ -f "$BASELINE_PATH" ] || _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=accepted baseline missing"

RUNNER=${AEO_GATE_RUNNER:-}
if [ -z "$RUNNER" ]; then
  for candidate in \
    "$ROOT/.claude/skills/aeo-gate/scripts/run-diff.sh" \
    "$ROOT/.codex/skills/aeo-gate/scripts/run-diff.sh" \
    "$ROOT/.agents/skills/aeo-gate/scripts/run-diff.sh" \
    "${TRELLIS_ROOT:-}/core-rules/skills/aeo-gate/scripts/run-diff.sh"
  do
    if [ -f "$candidate" ]; then
      RUNNER="$candidate"
      break
    fi
  done
fi
if [ -z "$RUNNER" ] || [ ! -x "$RUNNER" ]; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=AEO gate runner unavailable"
fi
if ! command -v python3 >/dev/null 2>&1; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=python3 unavailable for AEO watchdog"
fi

GIT_DIR=$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null)
case "$GIT_DIR" in
  /*) ;;
  *) GIT_DIR="$ROOT/$GIT_DIR" ;;
esac
SHA=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null)
[ -n "$SHA" ] || SHA=unknown
if [ -n "${AEO_GATE_OUTPUT:-}" ]; then
  OUTPUT=$AEO_GATE_OUTPUT
  mkdir -p "$OUTPUT" 2>/dev/null || _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=evidence directory unavailable"
else
  OUTPUT_ROOT="$GIT_DIR/trellis-aeo"
  mkdir -p "$OUTPUT_ROOT" 2>/dev/null || _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=evidence directory unavailable"
  OUTPUT=$(mktemp -d "$OUTPUT_ROOT/$SHA.XXXXXX" 2>/dev/null)
  [ -n "$OUTPUT" ] || _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=evidence directory unavailable"
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/aeo-gate-warn.XXXXXX" 2>/dev/null)
[ -n "$TMP" ] || _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=temporary capture unavailable"
HOOK_TIMEOUT=${AEO_GATE_HOOK_TIMEOUT:-45}
STAGE_TIMEOUT=${AEO_GATE_STAGE_TIMEOUT:-8}
case "$HOOK_TIMEOUT:$STAGE_TIMEOUT" in
  *[!0-9:]* | :* | *:) HOOK_TIMEOUT=45; STAGE_TIMEOUT=8 ;;
esac
TIMEOUT_MARKER="$TMP.timeout"
python3 -c 'import os,sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' "$RUNNER" \
  --project "$PROJECT" \
  --url "$URL" \
  --checkout "$ROOT" \
  --output "$OUTPUT" \
  --marker-file "$MARKER_FILE" \
  --marker "$MARKER" \
  --baseline "$BASELINE_PATH" \
  --range "$RANGE" \
  --timeout "$STAGE_TIMEOUT" >"$TMP" 2>&1 &
RUNNER_PID=$!
python3 -c '
import os
import signal
import sys
import time

time.sleep(int(sys.argv[1]))
try:
    os.killpg(int(sys.argv[2]), signal.SIGTERM)
except ProcessLookupError:
    raise SystemExit(0)
open(sys.argv[3], "wb").close()
time.sleep(1)
try:
    os.killpg(int(sys.argv[2]), signal.SIGKILL)
except ProcessLookupError:
    pass
' "$HOOK_TIMEOUT" "$RUNNER_PID" "$TIMEOUT_MARKER" &
WATCHDOG_PID=$!
STATUS=0
wait "$RUNNER_PID" || STATUS=$?
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
RESULT=$(tr '\n' ' ' <"$TMP" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//')
TIMED_OUT=false
if [ -f "$TIMEOUT_MARKER" ]; then
  TIMED_OUT=true
fi
rm -f "$TMP" "$TIMEOUT_MARKER"
if [ "$TIMED_OUT" = true ]; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=diff runner exceeded ${HOOK_TIMEOUT}s wall-clock budget"
fi
if [ "$STATUS" -ne 0 ] || [ -z "$RESULT" ]; then
  _emit "warn-only: status=INDETERMINATE; merge_policy=non-blocking; reason=diff runner failed${RESULT:+; detail=$RESULT}"
fi
_emit "$RESULT"
