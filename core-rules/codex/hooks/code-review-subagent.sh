#!/usr/bin/env bash
# code-review-subagent.sh — Codex Stop. Advisory review on edit-heavy turns.
# Source: Trellis / core-rules / codex hooks. LEAN MIRROR of the merged Claude
# core-rules/hooks/code-review-subagent.sh (Phase 2b port).
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Re-entrancy guard: TRELLIS_REVIEW_IN_PROGRESS==1 on entry → exit 0 (the
#     ladder's rung-2 `claude -p` child would otherwise re-fire this hook).
#   - Runs only on edit-heavy turns: ≥3 files changed OR ≥200 lines added/changed
#     in `git diff HEAD`. Threshold overridable via REVIEW_MIN_FILES /
#     REVIEW_MIN_LINES env vars from project hook config.
#   - Pipes the RAW staged+unstaged diff (`git diff HEAD`) into the canonical
#     reviewer ladder lib/code-reviewer.sh; findings are advisory.
#   - Blocks only on severity=critical returned by the ladder.
#   - Budget: bounded by the ladder's internal perl-alarm timeout (no outer cap).
#
# Dependencies: jq (required), git (required for diff / skipped otherwise),
#   lib/code-reviewer.sh (the Phase-1 ladder; synced beside this hook by
#   sync-codex-hooks.sh at deploy time → .codex/hooks/lib/code-reviewer.sh).
#
# Status: wired (Phase 2b) — calls lib/code-reviewer.sh ladder; fail-open on
# infra, fail-closed on a parsed `critical` finding.
#
# LEAN VARIANT vs the Claude hook: this hook does NOT build the autonomy /
# decisions-log JSON envelope. It pipes the raw unified diff straight to the
# ladder — the ladder's extract_raw_diff treats non-JSON stdin as a raw diff and
# the reviewer prompt accepts raw-diff stdin. The L4/L5 decisions-log
# verification clause is intentionally not wired on the Codex side; .autonomy_level
# simply being absent is the "no decisions-log clause" path.
#
# *** REVIEWER LADDER WIRING — the crux (Phase 2a bug, do NOT repeat) ***
# The single canonical reviewer is the ladder lib/code-reviewer.sh, invoked as a
# sibling: bash "$HOOK_DIR/lib/code-reviewer.sh". Do NOT pre-export
# TRELLIS_REVIEW_IN_PROGRESS before that call: the ladder gates rung 2 on that
# sentinel, so pre-setting it would force every default-path call straight to the
# rung-3 regex and the built-in `claude -p` reviewer would never run. The ladder
# exports the sentinel itself, internally, right before spawning ANY child, so
# the child's own top-of-hook guard still trips — recursion is prevented without
# disabling rung 2. No outer `timeout` (and never a bare `timeout` — GNU/gtimeout
# are absent on macOS); the ladder bounds rung 2 via its own perl-alarm shim.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "code-review-subagent: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "code-review-subagent"

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Mandatory fork-bomb sentinel ---
# Rung 2 of the ladder spawns a child `claude -p` turn, whose own Stop hook would
# otherwise re-fire this reviewer — recursively. `stop_hook_active` does NOT guard
# this: it is FALSE in the `claude -p` child (a fresh, separate session, not a
# re-entrant stop). The ladder exports TRELLIS_REVIEW_IN_PROGRESS=1 before its
# claude call, and that env propagates into the child's Stop-hook environment. So
# on entry, if the sentinel is set, bail immediately.
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-}" = "1" ]; then
  exit 0
fi

# Resolve the hook directory now, BEFORE any `cd`, so the sibling-ladder path
# below is correct regardless of the working directory we change into.
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# --- Resolve canonical repo root (worktree-aware; falls back to PROJECT_DIR) ---
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

# --- TRELLIS_REVIEW_OVERRIDE escape ---
# Documented, LOGGED deferral — mirrors the TRELLIS_ALLOW_MAIN_PUSH tripwire. When
# the operator sets this, code-review is skipped for this turn, but NEVER silently:
# we append an acknowledged-and-deferred entry to the decisions-log so a false
# critical never trains the operator toward a habitual --no-verify. Logged in the
# dated format session-context.sh greps ("- 20YY-..."). The decisions-log stays at
# the canonical repo root (NOT under .codex) — it is shared across harnesses.
if [ -n "${TRELLIS_REVIEW_OVERRIDE:-}" ]; then
  OVERRIDE_FILES=$(git diff HEAD --name-only 2>/dev/null | awk 'END{print NR}')
  if printf '%s\n' "- $(date +%Y-%m-%d) code-review deferred via TRELLIS_REVIEW_OVERRIDE on a turn touching ${OVERRIDE_FILES} file(s)" \
       >> "$REPO_ROOT/decisions-log.md" 2>/dev/null; then
    :
  else
    # The deferral must never be both un-logged AND un-surfaced. If the
    # decisions-log is unwritable (read-only file/dir/FS), surface a breadcrumb
    # instead of silently swallowing the skip.
    jq -nc --arg ctx "code-review override applied (TRELLIS_REVIEW_OVERRIDE) but the decisions-log at $REPO_ROOT/decisions-log.md was unwritable — record the deferral manually." '{additionalContext: $ctx}'
  fi
  exit 0
fi

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- Threshold check ---
MIN_FILES="${REVIEW_MIN_FILES:-3}"
MIN_LINES="${REVIEW_MIN_LINES:-200}"

# Count always outputs a number, never errors. Avoid `grep -c '^' || echo 0` —
# that doubles output to "0\n0" on empty input and breaks numeric comparisons.
CHANGED_FILES=$(git diff HEAD --name-only 2>/dev/null | awk 'END{print NR}')

# Sum added+deleted lines from numstat; skip binary rows (marked '-').
CHANGED_LINES=$(git diff HEAD --numstat 2>/dev/null \
  | awk '$1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum+0 }')

if [ "$CHANGED_FILES" -lt "$MIN_FILES" ] && [ "$CHANGED_LINES" -lt "$MIN_LINES" ]; then
  exit 0
fi

# --- Doc-only skip: if every changed file has a doc extension (.md/.mdx/.rst/.txt),
# skip. Earlier versions also skipped anything under `docs/` regardless of
# extension — that wrongly skipped non-doc files like `docs/scripts/setup.sh`
# or `docs/examples/app.ts`. The `(^|/)[^/]+\.ext$` anchor matches the final
# path segment only, so a doc anywhere in the tree (e.g. `src/notes.md`) still
# counts as a doc and a non-doc under `docs/` still counts as a non-doc.
NONDOC_COUNT=$(git diff HEAD --name-only 2>/dev/null \
  | grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
  | awk 'END{print NR}')
if [ "$NONDOC_COUNT" -eq 0 ]; then
  exit 0
fi

# --- Gather the diff for the reviewer (capped) ---
DIFF=$(git diff HEAD 2>/dev/null | head -c 200000)
if [ -z "$DIFF" ]; then
  exit 0
fi

# --- Idempotency marker ---
# A turn can fire this hook AND run the execute-body review over the same diff;
# we must not double-charge the LLM. Key the marker on a sha256 of the diff
# (shasum -a 256 — macOS has no sha256sum). If this exact diff was already
# reviewed this turn, exit 0. The marker is touched only AFTER a completed
# review (clean + advisory paths), NOT on the block path — a blocked turn must
# re-review once the diff changes via the fix. Codex marker lives under .codex/.
DIFF_HASH=$(printf '%s' "$DIFF" | shasum -a 256 | awk '{print $1}')
MARKER="$REPO_ROOT/.codex/.review-done-${DIFF_HASH}"
if [ -f "$MARKER" ]; then
  exit 0
fi

# --- Invoke the reviewer ladder (sibling lib) ---
# The 3-rung ladder (operator override → claude -p → deterministic regex) owns
# rung selection and ALWAYS emits one findings line, fail-open on every infra
# failure. LEAN: pipe the RAW diff — extract_raw_diff treats non-JSON stdin as a
# raw diff. Do NOT pre-export TRELLIS_REVIEW_IN_PROGRESS here: the ladder gates
# rung 2 on that sentinel, so pre-setting it would force every default-path call
# straight to the rung-3 regex and the built-in `claude -p` reviewer would never
# run. The ladder exports the sentinel itself before spawning ANY child, so the
# child's own top-of-hook guard still trips — recursion is prevented without
# disabling rung 2. No outer `timeout` — the ladder bounds rung 2 internally via
# its perl-alarm shim.
# NB: no `2>/dev/null` here. lib/code-reviewer.sh deliberately leaves the rung-2
# `claude` stderr unsuppressed so a failing reviewer is visible; silencing fd 2
# on the caller side would re-introduce that documented mistake. stdout (the one
# findings line) is what we capture. `|| true` so a nonzero ladder never aborts.
if [ ! -f "$HOOK_DIR/lib/code-reviewer.sh" ]; then
  # Fail-OPEN: the ladder core was not synced beside this hook. Never block.
  exit 0
fi
FINDINGS=$(printf '%s' "$DIFF" | bash "$HOOK_DIR/lib/code-reviewer.sh" || true)

if [ -n "$FINDINGS" ]; then
  CRITICAL=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | select(.severity == "critical") | "- \(.file):\(.line // "?") \(.msg)"' 2>/dev/null | head -10)
  if [ -n "$CRITICAL" ]; then
    REASON="Code review flagged critical issues — resolve or explicitly defer:
${CRITICAL}"
    jq -nc --arg reason "$REASON" '{decision: "block", reason: $reason}'
    # Block path: do NOT touch the marker — a blocked turn must re-review the
    # corrected diff (which will hash differently anyway).
    exit 2
  fi

  # Advisory findings → additionalContext (shown to the model, not blocking).
  ADVISORY=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | "- [\(.severity)] \(.file):\(.line // "?") \(.msg)"' 2>/dev/null | head -30)
  if [ -n "$ADVISORY" ]; then
    jq -nc --arg ctx "<review>
${ADVISORY}
</review>" '{additionalContext: $ctx}'
  fi
fi

# Review completed (clean or advisory) — record the idempotency marker so the
# execute-body review does not re-charge the LLM for this exact diff this turn.
mkdir -p "$REPO_ROOT/.codex" 2>/dev/null || true
: > "$MARKER" 2>/dev/null || true

exit 0
