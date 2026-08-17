#!/usr/bin/env bash
# Run the host-pinned weekly test-health audit through Claude Code.
#
# This runner deliberately has no Linux/Cowork fallback: the registered project
# dependencies are hydrated for Darwin arm64, so any other kernel produces
# meaningless test results. It holds an atomic macOS lock around the bounded
# Claude invocation and changes to the canonical checkout before Claude starts
# so that the canonical rules and prompt govern the audit.

set -euo pipefail

LABEL="com.trellis.test-health"
# Defaults are derived, never hardcoded: this file is published to the public
# mirror, so an operator path here both leaks a real home directory and pins
# every other machine to this one. The runner ships inside the policy
# checkout, so its own location is the authority.
DEFAULT_TRELLIS_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_CLAUDE_BIN="$HOME/.local/bin/claude"
MAX_TURNS=100
MAX_BUDGET_USD=25

TRELLIS_ROOT="${TRELLIS_ROOT:-$DEFAULT_TRELLIS_ROOT}"
CLAUDE_BIN="${CLAUDE_BIN:-$DEFAULT_CLAUDE_BIN}"
PROMPT="$TRELLIS_ROOT/scheduled-tasks/test-health/prompt.md"
LOCK_FILE="${TEST_HEALTH_LOCK_FILE:-$HOME/Library/Caches/$LABEL.lock}"

usage() {
  cat <<'EOF'
Usage: run-test-health-host.sh [--smoke]

Runs the canonical test-health prompt on the Darwin arm64 host through a
bounded non-interactive Claude invocation. --smoke verifies the host gate,
canonical cwd, canonical prompt, and planned bounded command without invoking
Claude or running any project tests.
EOF
}

host_gate() {
  local host
  host="$(uname -sm)"
  if [ "$host" != "Darwin arm64" ]; then
    printf 'info: test-health could not run: off-host (uname=%s); darwin node_modules cannot execute under this kernel\n' "$host" >&2
    return 1
  fi
}

validate_runtime() {
  [ -d "$TRELLIS_ROOT" ] || {
    printf 'test-health runner: canonical root missing: %s\n' "$TRELLIS_ROOT" >&2
    exit 1
  }
  [ -r "$PROMPT" ] || {
    printf 'test-health runner: canonical prompt missing: %s\n' "$PROMPT" >&2
    exit 1
  }
  [ -x "$CLAUDE_BIN" ] || {
    printf 'test-health runner: Claude binary is not executable: %s\n' "$CLAUDE_BIN" >&2
    exit 1
  }
}

print_smoke() {
  local prompt_hash
  prompt_hash="$(/usr/bin/shasum -a 256 "$PROMPT")"
  prompt_hash="${prompt_hash%% *}"

  printf 'smoke: host preflight: Darwin arm64\n'
  printf 'smoke: canonical cwd: %s\n' "$PWD"
  printf 'smoke: canonical prompt: %s\n' "$PROMPT"
  printf 'smoke: prompt sha256: %s\n' "$prompt_hash"
  printf 'smoke: Claude dispatch: %s -p --permission-mode bypassPermissions --max-turns %s --max-budget-usd %s <contents of canonical prompt>\n' \
    "$CLAUDE_BIN" "$MAX_TURNS" "$MAX_BUDGET_USD"
}

smoke=false
case "${1:-}" in
  "") ;;
  --smoke) smoke=true ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    printf 'test-health runner: unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

# This must be the first audit preflight: do not resolve the prompt or project
# files before proving that the Darwin-arm64 host is available.
if ! host_gate; then
  exit 3
fi

validate_runtime
cd "$TRELLIS_ROOT"

if $smoke; then
  print_smoke
  exit 0
fi

mkdir -p "$(dirname "$LOCK_FILE")"
if ! /usr/bin/shlock -f "$LOCK_FILE" -p "$$"; then
  lock_owner="$(cat "$LOCK_FILE" 2>/dev/null || printf 'unknown')"
  printf 'info: test-health skipped: another run is active (pid=%s)\n' "$lock_owner"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT

# Keep the canonical prompt as the sole user prompt. Its read-only boundary
# permits only the dated audit output, while this outer runner owns host gating,
# non-overlap, cwd, and the hard Claude limits.
"$CLAUDE_BIN" -p \
  --permission-mode bypassPermissions \
  --max-turns "$MAX_TURNS" \
  --max-budget-usd "$MAX_BUDGET_USD" \
  "$(cat "$PROMPT")"
