#!/usr/bin/env bash
# ui-verify-core.sh — factored UI-verification DECISION CORE.
# Source: Trellis / core-rules / hooks (lib).
#
# Sourced (not executed) by both:
#   - core-rules/hooks/ui-verify.sh        (Phase-2a Stop hook)
#   - the Phase-4 execute body
#   - the Phase-2b/test layer (bats) which unit-tests the functions below.
#
# This is a PURE DECISION FUNCTION. It does not emit Claude-Code control blocks
# and it does not own the exit code: it prints ONE JSON line describing a
# verdict and the caller decides what to do (verdict "block" → caller's
# emit_block). It always exits 0 when invoked as a script; the verdict lives
# in the JSON payload, never in the process exit status.
#
# OUTPUT CONTRACT (single line on stdout):
#   {"verdict":"skip|advisory|block|pass","reason":"...","artifacts":["..."]}
#
#   skip      — turn touched no UI files; not applicable.
#   advisory  — UI changed but verification could not be performed
#               (no visual tool, dev server unreachable, probe/timeout error).
#               Surface a note; do NOT block. This is the fail-open verdict.
#   block     — UI changed, a visual tool IS present, but it produced nothing
#               (empty/missing screenshot artifact). The real gate.
#   pass      — UI changed, tool present, screenshot produced.
#
# DESIGN NOTES
#   - bash 3.2 compatible: no namerefs, no mapfile, no associative arrays.
#   - No `set` flags at source time (would leak -e/pipefail into the caller —
#     mirror lib/deps.sh and lib/pm.sh, which set nothing). Flags are enabled
#     only inside the run-as-main guard at the bottom.
#   - No top-level stdin read (`cat`) — that would hang at source time. The core
#     decides from git state + env, not from the hook JSON envelope. (stdin is
#     ignored.)
#   - jq is OPTIONAL here: callers (ui-verify.sh) already enforce jq before
#     sourcing. If jq is missing we still emit a hand-built JSON line so the
#     test layer and the Phase-4 body get a parseable verdict and we fail open.
#   - PORTABLE TIMEOUT: GNU `timeout` is absent on macOS. We use a perl-alarm
#     shim (perl present at /usr/bin/perl); if perl is absent we run the probe
#     without a wall-clock timeout but still bound it with --no-install and a
#     cheap `--version`. Never use bare `timeout`.
#   - npx probe uses `--no-install` so it can never trigger a network install.
#   - The screenshot command is env-overridable (UI_SHOT_CMD) — mirrors the
#     CODE_REVIEWER_CMD pattern in code-review-subagent.sh — so the test layer
#     can exercise the pass/block branches without a real browser.
#
# ENV (reused names so this core drops into ui-verify.sh without a rename):
#   UI_REGEX    — egrep regex of UI extensions. Default below.
#   UI_PORT     — dev-server port probe (default 3000).
#   UI_PATH     — dev-server path probe (default "/").
#   UI_SHOT_CMD — override the screenshot command. Receives "<url> <out>" args.
#                 Default: `npx --no-install playwright screenshot --full-page`.
#   UI_VERIFY_TIMEOUT — wall-clock seconds for bounded probes (default 20).

# --- Defaults (only set if caller hasn't) ----------------------------------
: "${UI_REGEX:=\.(tsx|jsx|vue|svelte|html|css)$}"
: "${UI_PORT:=3000}"
: "${UI_PATH:=/}"
: "${UI_VERIFY_TIMEOUT:=20}"

# run_with_timeout <secs> <cmd...>
#   Bounded execution via a perl alarm shim (GNU timeout is absent on macOS).
#   Returns the command's exit status; a fired alarm surfaces as 142.
#   Fail-open: if perl is absent, run the command without a wall-clock bound
#   (the callers below also use --no-install / cheap probes to stay bounded).
run_with_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    return $?
  fi
  "$@"
  return $?
}

# ui_changed_files
#   Echo the UI files (one per line) changed this turn, capped. Unions tracked
#   changes (`git diff HEAD`) with brand-new untracked files
#   (`git ls-files --others --exclude-standard`) — a UI gate that watched only
#   the diff would miss freshly-created .tsx components. Echoes nothing when
#   git is unavailable / not a worktree. Never errors.
ui_changed_files() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # `|| true`: grep exits 1 on no-match — without this the pipeline returns
  # non-zero and a caller running `set -e`/`pipefail` (Phase-4 body) would abort
  # the function before the skip verdict is emitted. Stay robust to caller flags.
  {
    git diff HEAD --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | grep -Ei "$UI_REGEX" | sort -u | head -50 || true
}

# ui_changed
#   Predicate: returns 0 (true) iff this turn touched any UI file.
ui_changed() {
  [ -n "$(ui_changed_files)" ]
}

# detect_visual_tool
#   Echo the name of an available visual/screenshot tool, or nothing.
#   - If UI_SHOT_CMD is set, the operator/test has supplied a tool → echo "custom".
#   - Else probe `npx playwright --version`, bounded by the perl-alarm shim and
#     `--no-install` so it cannot trigger a network install. Echo "playwright"
#     on success, nothing otherwise. Fail-open: any probe error → nothing
#     (caller maps "no tool" → advisory, never block).
detect_visual_tool() {
  if [ -n "${UI_SHOT_CMD:-}" ]; then
    printf 'custom'
    return 0
  fi
  command -v npx >/dev/null 2>&1 || return 0
  if run_with_timeout "$UI_VERIFY_TIMEOUT" \
       npx --no-install playwright --version >/dev/null 2>&1; then
    printf 'playwright'
    return 0
  fi
  return 0
}

# server_up <url>
#   Best-effort dev-server reachability probe. Returns 0 iff reachable.
#   Absence of curl → treat as "could not probe" (return non-zero); the caller
#   maps that to advisory (fail-open), not block.
server_up() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || return 1
  run_with_timeout "$UI_VERIFY_TIMEOUT" \
    curl -sf -o /dev/null --max-time 2 "$url" >/dev/null 2>&1
}

# _uvc_emit <verdict> <reason> <artifact-path-or-empty>
#   Print the single-line JSON verdict. Prefers jq; falls back to a hand-built
#   line (with minimal escaping) when jq is absent, so the core stays usable in
#   jq-less environments and the test layer always gets parseable output.
_uvc_emit() {
  local verdict="$1" reason="$2" shot="${3:-}"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg v "$verdict" --arg r "$reason" --arg s "$shot" \
      '{verdict: $v, reason: $r, artifacts: (if $s == "" then [] else [$s] end)}'
    return 0
  fi
  # jq-less fallback: escape backslash, double-quote, and newlines.
  local er es
  er=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  es=$(printf '%s' "$shot"   | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [ -z "$shot" ]; then
    printf '{"verdict":"%s","reason":"%s","artifacts":[]}\n' "$verdict" "$er"
  else
    printf '{"verdict":"%s","reason":"%s","artifacts":["%s"]}\n' "$verdict" "$er" "$es"
  fi
}

# ui_verify_decision [project_dir]
#   The decision core. Prints one JSON verdict line to stdout, returns 0.
#   project_dir defaults to CODEX_PROJECT_DIR / CLAUDE_PROJECT_DIR / $PWD.
#
#   The entire body runs inside a subshell `( ... )`. This contains the `cd`
#   below so that sourcing this file and calling the function IN-PROCESS (the
#   Phase-4 execute body does exactly this) does NOT mutate the caller's cwd.
#   stdout and the exit status still propagate; `return N` exits the subshell
#   with status N, which the function returns. Callers read the verdict from
#   stdout, not the status.
ui_verify_decision() (
  local project_dir="${1:-${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  cd "$project_dir" 2>/dev/null || {
    _uvc_emit advisory "ui-verify: could not enter project dir ${project_dir}; skipping verification." ""
    return 0
  }

  # --- PRESENCE GATE: no UI files changed → not applicable. ---
  local touched
  touched="$(ui_changed_files)"
  if [ -z "$touched" ]; then
    _uvc_emit skip "ui-verify: no UI files changed this turn." ""
    return 0
  fi
  # Compact the touched list to a single comma-joined line for reason strings.
  local touched_line
  touched_line="$(printf '%s' "$touched" | tr '\n' ',' | sed 's/,$//')"

  # --- Probe for a visual tool. ---
  local tool
  tool="$(detect_visual_tool)"
  if [ -z "$tool" ]; then
    _uvc_emit advisory \
      "ui-verify: UI files changed (${touched_line}) but no screenshot tool is available (npx playwright not found). Cannot verify visually — note this in your response. Install Playwright or set UI_SHOT_CMD to enable the gate." \
      ""
    return 0
  fi

  # --- Tool present. Probe dev server (best-effort; do not hard-depend). ---
  local url="http://localhost:${UI_PORT}${UI_PATH}"
  if ! server_up "$url"; then
    # Server-down sits between fail-open and the real gate. Under the new
    # contract we treat "could not attempt" as ADVISORY (this diverges from the
    # old ui-verify.sh, which blocked on server-down — intentional). The gate
    # only blocks when the tool RAN and produced nothing.
    _uvc_emit advisory \
      "ui-verify: UI files changed (${touched_line}); a visual tool (${tool}) is available but the dev server is not reachable at ${url}. Start it (e.g. \`npm run dev\`) and re-verify, or set UI_PORT/UI_PATH." \
      ""
    return 0
  fi

  # --- Take a bounded screenshot. ---
  local shot_dir="${project_dir}/.claude/screenshots"
  mkdir -p "$shot_dir" 2>/dev/null || true
  local shot_path
  shot_path="${shot_dir}/ui-verify-$(date +%Y%m%d-%H%M%S-$$).png"

  # Capture status with `&& rc=0 || rc=$?` on the same logical line so a caller
  # running `set -e` cannot abort the function between the call and the capture
  # (a perl-alarm timeout returns 142 — a non-zero we must observe, not crash on).
  local rc=0
  if [ -n "${UI_SHOT_CMD:-}" ]; then
    # Operator/test-supplied command. Word-split intentionally so a multi-word
    # command works; receives "<url> <out>".
    # shellcheck disable=SC2086
    run_with_timeout "$UI_VERIFY_TIMEOUT" $UI_SHOT_CMD "$url" "$shot_path" >/dev/null 2>&1 && rc=0 || rc=$?
  else
    run_with_timeout "$UI_VERIFY_TIMEOUT" \
      npx --no-install playwright screenshot --full-page "$url" "$shot_path" >/dev/null 2>&1 && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 142 ]; then
    # Timeout fired → infra/fail-open, not a real failure to verify.
    _uvc_emit advisory \
      "ui-verify: UI files changed (${touched_line}); screenshot via ${tool} timed out after ${UI_VERIFY_TIMEOUT}s. Treating as unverified (fail-open) — re-verify manually." \
      ""
    return 0
  fi

  if [ -s "$shot_path" ]; then
    # Tool ran and produced a non-empty artifact → PASS.
    _uvc_emit pass \
      "ui-verify: screenshot captured via ${tool} for ${url} (UI files: ${touched_line})." \
      "$shot_path"
    return 0
  fi

  # Tool present, server up, command ran (rc!=142), yet produced nothing → the
  # real gate. This is the only path that yields "block".
  _uvc_emit block \
    "ui-verify: a visual tool (${tool}) is present and the dev server is up at ${url}, but the screenshot produced no artifact (UI files: ${touched_line}). Capture a screenshot of the changed UI and attach it before finishing." \
    ""
  return 0
)

# --- Run-as-main guard ------------------------------------------------------
# When this file is sourced, only the function definitions above take effect —
# no flags, no stdin read, no exits leak into the caller. When executed
# directly (or from a test that runs it as a script), enable strict flags and
# print a verdict. The core itself always exits 0; the verdict is in the JSON.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -euo pipefail
  ui_verify_decision "$@"
  exit 0
fi
