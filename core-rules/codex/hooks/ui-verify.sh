#!/usr/bin/env bash
# ui-verify.sh — Codex Stop. Screenshot verification on UI-touching turns.
# Source: Trellis / core-rules / codex hooks.
#
# Thin MIRROR of core-rules/hooks/ui-verify.sh (the Claude Stop hook). The
# decision lives in the canonical core lib/ui-verify-core.sh; this wrapper only
# guards re-entrancy, sources project config, delegates, and maps the verdict.
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Thin wrapper: delegates the decision to lib/ui-verify-core.sh, which
#     decides from git state + env (it ignores stdin). The core gates on
#     presence FIRST (no UI files changed → skip), so this wrapper does no
#     UI-detection, dev-server probing, or screenshotting itself.
#   - Maps the core's single-line verdict to a Codex control block (the Codex
#     Stop output schema is Claude-compatible, so the shapes port verbatim):
#       skip      → exit 0 silently (not applicable).
#       advisory  → Stop-safe systemMessage note; exit 0 (fail-open: no visual tool,
#                   dev server unreachable, probe/timeout error).
#       pass      → Stop-safe systemMessage note with the screenshot path; exit 0.
#       block     → {"decision":"block",...} on stdout; exit 0. The ONLY blocking path:
#                   a visual tool IS present, the dev server IS up, yet the
#                   capture produced no artifact. Net: server-down → advisory.
#   - Missing core: block with the repair line (spec 055 R1.3) — fail closed.
#   - Fail-open: if the core emits nothing or unparseable output (infra
#     failure), exit 0 — never block on a core failure.
#
# Dependencies: jq (required). git/curl/screenshot tooling live in the core.
#
# Status: thin wrapper over lib/ui-verify-core.sh (Phase 2b port of Phase 2a).

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "ui-verify: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "ui-verify"

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Resolve the decision core before any project config is sourced (spec 055
# R1.1): sibling first, from this script's resolved directory. Run in place from
# the payload, the shared core-rules/hooks/lib/ is the fallback, and only when
# this directory IS the declared runtime's Codex tree — never for a project path
# that merely ends in core-rules/codex/hooks.
__h_dir=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
__h_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
CORE="$__h_dir/lib/ui-verify-core.sh"
if [ ! -f "$CORE" ] && [ -n "$__h_rt" ] && [ "$__h_dir" = "$__h_rt/core-rules/codex/hooks" ]; then
  CORE="$__h_dir/../../hooks/lib/ui-verify-core.sh"
fi
# A missing core fails CLOSED (spec 055 R1.3): the gate cannot decide. Codex
# consumes a Stop block as stdout JSON on exit 0; exit 2 needs a stderr prompt.
if [ ! -f "$CORE" ]; then
  jq -nc --arg reason "ui-verify degraded: core library missing at $CORE; run trellis doctor in $PROJECT_DIR" '{decision: "block", reason: $reason}'
  exit 0
fi

# Source optional project-level hook config (UI_PORT, UI_PATH, UI_REGEX, …) with
# auto-export on, so any UI_* it sets propagate into the core subprocess below.
# The Pi bridge selects .pi with the fixed TRELLIS_HARNESS=pi enum; all other
# values retain the Codex namespace. This cannot redirect config loading to an
# arbitrary env-provided path. Harness config wins over the Claude fallback.
HARNESS_HOME="$(_se_harness_home "$PROJECT_DIR")"
if [ -f "${HARNESS_HOME}/hooks/config.sh" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${HARNESS_HOME}/hooks/config.sh"
  set +a
elif [ -f "${PROJECT_DIR}/.claude/hooks/config.sh" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${PROJECT_DIR}/.claude/hooks/config.sh"
  set +a
fi

# --- Delegate to the decision core. ---
# The core ignores stdin; redirect from /dev/null so it never blocks on a tty.
# Discard stderr and `|| true` so a core infra failure surfaces as empty output
# (→ fail-open below), never a non-zero abort under `set -u`.
VERDICT_JSON=$(bash "$CORE" "$PROJECT_DIR" </dev/null 2>/dev/null || true)

# Fail-open: no output (broken core) → never block.
[ -n "$VERDICT_JSON" ] || exit 0

VERDICT=$(printf '%s' "$VERDICT_JSON" | jq -r '.verdict // "skip"' 2>/dev/null)
REASON=$(printf '%s' "$VERDICT_JSON" | jq -r '.reason // ""' 2>/dev/null)
ARTIFACT=$(printf '%s' "$VERDICT_JSON" | jq -r '.artifacts[0] // ""' 2>/dev/null)

# Unparseable verdict (jq failed → empty VERDICT) → fail-open.
[ -n "$VERDICT" ] || exit 0

case "$VERDICT" in
  skip)
    exit 0
    ;;
  advisory)
    _se_emit_system_message "$REASON"
    exit 0
    ;;
  pass)
    _se_emit_system_message "ui-verify: screenshot saved to ${ARTIFACT}"
    exit 0
    ;;
  block)
    jq -nc --arg reason "UI-visible change requires visual verification. $REASON" '{decision: "block", reason: $reason}'
    exit 0
    ;;
  *)
    # Unknown verdict → fail-open.
    exit 0
    ;;
esac
