#!/usr/bin/env bash
# Host-pinned weekly test-health audit. This standalone snapshot receives its
# home, fleet, canonical checkout and stable launcher from launchd's plist.
#
# There is deliberately no Linux/Cowork fallback: the registered projects'
# dependencies are hydrated for Darwin arm64, so any other kernel produces
# meaningless results. Each fire re-materializes the task on the active release
# and dispatches that prompt, never the raw scheduled-tasks template, whose
# {{TASK_ROOT}}/{{OUTPUT_ROOT}} placeholders made the 2026-09-21 run halt.
set -euo pipefail

LABEL=com.trellis.test-health
TASK=test-health
MAX_TURNS=100
MAX_BUDGET_USD=25
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
TRELLIS_HOME="${TRELLIS_HOME:-$HOME/.trellis}"
TRELLIS_FLEET="${TRELLIS_FLEET:-personal}"
TRELLIS_ROOT="${TRELLIS_ROOT:-$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
TRELLIS_LAUNCHER="${TRELLIS_LAUNCHER:-$HOME/.local/bin/trellis}"
MANIFEST="$TRELLIS_HOME/tasks/$TRELLIS_FLEET/$TASK/manifest.json"
PROMPT="$TRELLIS_HOME/tasks/$TRELLIS_FLEET/$TASK/prompt.md"
LOCK_FILE="${TEST_HEALTH_LOCK_FILE:-$HOME/Library/Caches/$LABEL.lock}"

refuse() {
  printf 'test-health: refused (%s): %s\n' "$1" "$2" >&2
  exit 1
}

host_gate() {
  local host
  host="$(uname -sm)"
  if [ "$host" != 'Darwin arm64' ]; then
    printf 'info: test-health could not run: off-host (uname=%s); darwin node_modules cannot execute under this kernel\n' "$host" >&2
    return 1
  fi
}

validate_home() {
  case "$TRELLIS_HOME" in
    /*) ;;
    *) refuse home "TRELLIS_HOME must be absolute: $TRELLIS_HOME" ;;
  esac
}

validate_manifest() {
  [ -f "$MANIFEST" ] && [ -r "$MANIFEST" ] || refuse manifest "$MANIFEST"
  /usr/bin/jq -e '.status == "ready" and (.requirements.planned_errors | type == "array" and length == 0)' \
    "$MANIFEST" >/dev/null 2>&1 || refuse manifest "$MANIFEST (status must be ready; requirements.planned_errors must be empty)"
}

validate_prompt() {
  [ -f "$PROMPT" ] && [ -r "$PROMPT" ] || refuse prompt "$PROMPT"
  if LC_ALL=C grep -qE '\{\{[^}]*\}\}' "$PROMPT"; then
    refuse prompt "$PROMPT (unfilled placeholder)"
  fi
}

usage() {
  printf 'Usage: run-test-health-host.sh [--smoke]\n'
}

smoke=false
case "${1:-}" in
  '') ;;
  --smoke) smoke=true ;;
  --help|-h) usage; exit 0 ;;
  *) refuse option "${1}" ;;
esac
[ "$#" -le 1 ] || refuse option 'too many arguments'

# The host gate precedes every task or checkout access.
host_gate || exit 3
validate_home

if ! $smoke; then
  mkdir -p "$(dirname "$LOCK_FILE")" || refuse lock "$LOCK_FILE"
  if ! /usr/bin/shlock -f "$LOCK_FILE" -p "$$"; then
    lock_owner="$(cat "$LOCK_FILE" 2>/dev/null || printf 'unknown')"
    printf 'info: test-health skipped: another run is active (pid=%s)\n' "$lock_owner"
    exit 0
  fi
  trap 'rm -f "$LOCK_FILE"' EXIT
  materialize_err="$("$TRELLIS_LAUNCHER" task materialize --fleet "$TRELLIS_FLEET" "$TASK" \
    --home "$TRELLIS_HOME" 2>&1 >/dev/null)" ||
    refuse materialize "$TRELLIS_LAUNCHER: $(printf '%s' "$materialize_err" | tail -n 1)"
fi

validate_manifest
validate_prompt
cd "$TRELLIS_ROOT" 2>/dev/null || refuse cwd "$TRELLIS_ROOT"

if $smoke; then
  prompt_hash="$(/usr/bin/shasum -a 256 "$PROMPT")" || refuse prompt "$PROMPT (sha256 failed)"
  printf '%s\n' "$MANIFEST" "$PROMPT" "${prompt_hash%% *}" 'placeholders: none unfilled'
  exit 0
fi

[ -x "$CLAUDE_BIN" ] || refuse claude "$CLAUDE_BIN (not executable)"
# A sentinel preserves trailing newlines in command substitution. The Claude
# argument is thus byte-identical to the materialized prompt, not a trimmed
# shell-substitution copy and never the raw release template.
prompt_body="$(cat "$PROMPT" && printf '.')" || refuse prompt "$PROMPT (read failed)"
prompt_body="${prompt_body%.}"
"$CLAUDE_BIN" -p \
  --permission-mode bypassPermissions \
  --max-turns "$MAX_TURNS" \
  --max-budget-usd "$MAX_BUDGET_USD" \
  "$prompt_body"
