#!/usr/bin/env bash
# ui-verify.sh — Stop. Screenshot verification on UI-touching turns.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Runs only when the turn's diff touches UI files. Default glob:
#     **/*.{tsx,jsx,vue,svelte,html,css}. Overridable via UI_GLOB env.
#   - Probes dev server on UI_PORT (default 3000) at UI_PATH (default "/").
#   - Takes a screenshot: prefer computer-use MCP, fall back to Playwright.
#   - Blocks if: dev server unreachable, screenshot empty, or no UI tool ran.
#
# Dependencies: jq (required), curl (for dev-server probe), git (for diff).
#
# Status: NEW (no upstream template). v1 is a SKELETON for the screenshot
# step — the file-glob detection and dev-server probe are fully wired. The
# actual screenshot calls are marked TODO: computer-use MCP is not callable
# from a shell hook today; Playwright path is real but commented out so it
# doesn't run on systems without playwright installed.

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
cd "$PROJECT_DIR" 2>/dev/null || exit 0

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- UI-touch detection ---
UI_REGEX="${UI_REGEX:-\.(tsx|jsx|vue|svelte|html|css)$}"
UI_TOUCHED=$(git diff HEAD --name-only 2>/dev/null | grep -E "$UI_REGEX" | head -20)

if [ -z "$UI_TOUCHED" ]; then
  exit 0
fi

emit_block() {
  local reason="$1"
  jq -nc --arg reason "UI-visible change requires visual verification. $reason" '{decision: "block", reason: $reason}'
  exit 2
}

# --- Dev-server probe ---
# Source optional project-level hook config (UI_PORT, UI_PATH, etc.)
if [ -f "${PROJECT_DIR}/.claude/hooks/config.sh" ]; then
  # shellcheck disable=SC1091
  . "${PROJECT_DIR}/.claude/hooks/config.sh"
fi
UI_PORT="${UI_PORT:-3000}"
UI_PATH="${UI_PATH:-/}"
UI_URL="http://localhost:${UI_PORT}${UI_PATH}"

server_up() {
  if command -v curl >/dev/null 2>&1; then
    curl -sf -o /dev/null --max-time 2 "$UI_URL"
    return $?
  fi
  return 1
}

if ! server_up; then
  # The spec says "starts it via the monitor tool". That's a Claude-side
  # affordance not available from a pure shell hook. We report the failure
  # and let Claude start it next turn.
  emit_block "Dev server not reachable at ${UI_URL}. Start it (e.g., \`npm run dev\`) and retry, or set UI_PORT/UI_PATH in .claude/hooks/config.sh."
fi

# --- Screenshot ---
SHOT_DIR="${PROJECT_DIR}/.claude/screenshots"
mkdir -p "$SHOT_DIR" 2>/dev/null || true
SHOT_PATH="${SHOT_DIR}/ui-verify-$(date +%Y%m%d-%H%M%S).png"

# -----------------------------------------------------------------------------
# TODO (v1 skeleton): take the screenshot.
#
# Preferred: computer-use MCP `mcp__computer-use__screenshot` targeted at the
# user's browser showing $UI_URL. That call originates from Claude, not a
# shell hook — so the clean wiring is for this hook to emit an additionalContext
# instructing Claude to take the screenshot, OR for Claude Code to expose a
# hook→MCP bridge. Until that lands, we fall back to Playwright when present.
#
# Fallback: headless Playwright. Uncomment once `npx playwright` is known
# to be available in the project toolchain, or enable via UI_USE_PLAYWRIGHT=1.
# -----------------------------------------------------------------------------

if [ "${UI_USE_PLAYWRIGHT:-0}" = "1" ] && command -v npx >/dev/null 2>&1; then
  npx --no-install playwright screenshot --full-page "$UI_URL" "$SHOT_PATH" >/dev/null 2>&1 || true
fi

if [ ! -s "$SHOT_PATH" ]; then
  # Skeleton behavior: advisory instead of block so we don't trap users
  # without computer-use or Playwright. Flip to emit_block once wired.
  jq -nc --arg ctx "ui-verify: UI files were touched (${UI_TOUCHED}). Dev server is up at ${UI_URL}, but no screenshot tool is wired in this hook yet. Take a screenshot via computer-use MCP or \`npx playwright screenshot ${UI_URL} <out>\` and attach it to your response." '{additionalContext: $ctx}'
  exit 0
fi

jq -nc --arg ctx "ui-verify: screenshot saved to ${SHOT_PATH} for ${UI_URL}." '{additionalContext: $ctx}'
exit 0
