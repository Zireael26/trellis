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
#       advisory  → additionalContext note; exit 0 (fail-open: no visual tool,
#                   dev server unreachable, probe/timeout error).
#       pass      → additionalContext note with the screenshot path; exit 0.
#       block     → {"decision":"block",...}; exit 2. The ONLY blocking path:
#                   a visual tool IS present, the dev server IS up, yet the
#                   capture produced no artifact. Net: server-down → advisory.
#   - Fail-open: if the core emits nothing or unparseable output (infra
#     failure / core not yet deployed), exit 0 — never block on a core failure.
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

# Source optional project-level hook config (UI_PORT, UI_PATH, UI_REGEX, …) with
# auto-export on, so any UI_* it sets propagate into the core subprocess below.
# Codex config wins over the Claude fallback when both are present.
if [ -f "${PROJECT_DIR}/.codex/hooks/config.sh" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${PROJECT_DIR}/.codex/hooks/config.sh"
  set +a
elif [ -f "${PROJECT_DIR}/.claude/hooks/config.sh" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${PROJECT_DIR}/.claude/hooks/config.sh"
  set +a
fi

emit_block() {
  local reason="$1"
  jq -nc --arg reason "UI-visible change requires visual verification. $reason" '{decision: "block", reason: $reason}'
  exit 2
}

# --- Delegate to the decision core. ---
# The core ignores stdin; redirect from /dev/null so it never blocks on a tty.
# Discard stderr and `|| true` so a core infra failure surfaces as empty output
# (→ fail-open below), never a non-zero abort under `set -u`.
CORE="$(dirname "${BASH_SOURCE[0]}")/lib/ui-verify-core.sh"
VERDICT_JSON=$(bash "$CORE" "$PROJECT_DIR" </dev/null 2>/dev/null || true)

# Fail-open: no output (missing/broken core) → never block.
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
    jq -nc --arg ctx "$REASON" '{additionalContext: $ctx}'
    exit 0
    ;;
  pass)
    jq -nc --arg ctx "ui-verify: screenshot saved to ${ARTIFACT}" '{additionalContext: $ctx}'
    exit 0
    ;;
  block)
    emit_block "$REASON"
    ;;
  *)
    # Unknown verdict → fail-open.
    exit 0
    ;;
esac
