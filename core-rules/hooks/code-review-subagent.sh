#!/usr/bin/env bash
# code-review-subagent.sh — Stop. Advisory review on edit-heavy turns.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Guard: stop_hook_active → exit 0.
#   - Runs only on edit-heavy turns: ≥3 files changed OR ≥200 lines added/changed
#     in `git diff HEAD`. Threshold overridable via REVIEW_MIN_FILES /
#     REVIEW_MIN_LINES env vars from project .claude/hooks/config.sh.
#   - Dispatches a code-review subagent against the diff; findings are advisory.
#   - Blocks only on severity=critical returned by the subagent.
#   - Budget: 60s soft cap.
#
# Dependencies: jq (required), git (required for diff / skipped otherwise).
#
# Status: wired (Phase 2a) — calls lib/code-reviewer.sh ladder; fail-open on
# infra, fail-closed on critical.
#
# Env-var/payload contract (exported to $REVIEWER):
#   AUTONOMY_LEVEL       — resolved integer 1–5 (same algorithm as session-context.sh)
#   DECISIONS_LOG_PATH   — absolute path to <canonical-root>/decisions-log.md
#   - At L4/L5 (resolved per core-rules/autonomy.md), the dispatched reviewer
#     also receives the contents of <canonical-root>/decisions-log.md and is
#     expected to flag implicit decisions in the diff that are missing from
#     the log. Reviewer input is a JSON envelope {diff, autonomy_level,
#     decisions_log}; lower levels receive an empty decisions_log string.
#     The reviewer's output schema (findings array) is unchanged.
#
# Reviewer-prompt guidance (Opus 4.8): the dispatched reviewer's job at this
# stage is COVERAGE, not filtering. Opus 4.8 follows "only report high-severity"
# instructions more faithfully than older models — told to be conservative it
# investigates just as deeply but converts fewer investigations into reported
# findings, silently dropping low-severity bugs it judges below the bar (recall
# falls even as precision rises). This hook is ALREADY the filter: severity ==
# "critical" blocks, everything else is advisory. So whoever wires the
# project-local $REVIEWER MUST prompt it to report every issue it finds —
# including low-confidence and low-severity ones — and attach `severity` plus an
# optional `confidence` (0.0–1.0) per finding, rather than self-filtering for
# importance. The block/advisory split here does the ranking. Concretely, the
# reviewer prompt should say something like: "Report every issue you find,
# including ones you are uncertain about or consider low-severity. Do not filter
# for importance or confidence — the hook does that. For each finding include a
# confidence level and estimated severity." `confidence` is back-compat:
# absent ⇒ treat as 1.0; the hook does not key off it today.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "code-review-subagent: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090,SC1091
. "$__se_lib"
_se_require_jq "code-review-subagent"
__se_autonomy_lib="$(dirname "${BASH_SOURCE[0]}")/lib/autonomy.sh"
[ -f "$__se_autonomy_lib" ] || { echo "code-review-subagent: missing sibling lib at $__se_autonomy_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/autonomy.sh disable=SC1090,SC1091
. "$__se_autonomy_lib"

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Mandatory fork-bomb sentinel ---
# Rung 2 of the ladder spawns a child `claude -p` turn, whose own Stop hook would
# otherwise re-fire this reviewer — recursively. `stop_hook_active` does NOT guard
# this: it is FALSE in the `claude -p` child (a fresh, separate session, not a
# re-entrant stop). The ladder exports TRELLIS_REVIEW_IN_PROGRESS=1 before its
# claude call, and that env DOES propagate into the child's Stop-hook environment
# (empirically confirmed). So on entry, if the sentinel is set, bail immediately.
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-}" = "1" ]; then
  exit 0
fi

# Resolve the hook directory now, BEFORE any `cd`, so the sibling-ladder path
# below is correct regardless of the working directory we change into.
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# --- Resolve canonical repo root + autonomy level ---
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO_ROOT=$(dirname "$(git rev-parse --git-common-dir)")
else
  REPO_ROOT="$PROJECT_DIR"
fi

# --- Untracked-inclusive change set (read-only) -------------------------------
# `git diff HEAD` omits untracked files, but a turn that only CREATES new files
# is exactly what needs review — and the reviewer must see their contents, not a
# blank diff. Fold untracked (non-ignored) files into every count AND into the
# reviewer payload, all from the same source, so the gate and the diff never
# disagree. Strictly read-only: `git ls-files --others` and `git diff --no-index`
# never touch the index (no `git add -N`), so the user's staging/status is
# unchanged.
# Exclude harness-state dirs: `.claude/` / `.codex/` hold symlinks, primers, and
# THIS hook's own idempotency marker — never user code to review. Not excluding
# them self-poisons idempotency (the marker written this turn would reappear as
# untracked content next turn, changing the diff hash).
_cr_untracked() { git ls-files --others --exclude-standard 2>/dev/null | grep -vE '^\.(claude|codex)/'; }
_cr_changed_names() { { git diff HEAD --name-only 2>/dev/null; _cr_untracked; } | sort -u | sed '/^$/d'; }
_cr_full_diff() {
  git diff HEAD 2>/dev/null
  local f
  _cr_untracked | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # --no-index vs /dev/null renders the new file as an all-additions diff. It
    # exits 1 because the inputs differ — expected here, not an error.
    git diff --no-index -- /dev/null "$f" 2>/dev/null || true
  done
}

# --- TRELLIS_REVIEW_OVERRIDE escape ---
# Documented, LOGGED deferral — mirrors the TRELLIS_ALLOW_MAIN_PUSH tripwire. When
# the operator sets this, code-review is skipped for this turn, but NEVER silently:
# we append an acknowledged-and-deferred entry to the decisions-log so a false
# critical never trains the operator toward a habitual --no-verify. Logged in the
# dated format session-context.sh greps ("^- 20YY-..."). Uses the literal path
# because DECISIONS_LOG_PATH is exported further below.
if [ -n "${TRELLIS_REVIEW_OVERRIDE:-}" ]; then
  OVERRIDE_FILES=$(_cr_changed_names | awk 'END{print NR}')
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

# The shared resolver implements the complete canonical pick/clamp algorithm.
# The effective (post-ceiling) level controls decision-log reviewer context.
_se_resolve_autonomy "$REPO_ROOT"
export AUTONOMY_LEVEL
export DECISIONS_LOG_PATH="$REPO_ROOT/decisions-log.md"

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- Threshold check ---
MIN_FILES="${REVIEW_MIN_FILES:-3}"
MIN_LINES="${REVIEW_MIN_LINES:-200}"

# Count always outputs a number, never errors. Avoid `grep -c '^' || echo 0` —
# that doubles output to "0\n0" on empty input and breaks numeric comparisons.
CHANGED_FILES=$(_cr_changed_names | awk 'END{print NR}')

# Sum added+deleted lines: tracked via numstat (skip binary rows marked '-'),
# untracked via line count (the whole new file is an addition).
TRACKED_LINES=$(git diff HEAD --numstat 2>/dev/null \
  | awk '$1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum+0 }')
UNTRACKED_LINES=$(_cr_untracked | while IFS= read -r f; do [ -f "$f" ] && wc -l < "$f" 2>/dev/null; done \
  | awk '{ sum += $1 } END { print sum+0 }')
CHANGED_LINES=$((TRACKED_LINES + UNTRACKED_LINES))

if [ "$CHANGED_FILES" -lt "$MIN_FILES" ] && [ "$CHANGED_LINES" -lt "$MIN_LINES" ]; then
  exit 0
fi

# --- Doc-only skip: if every changed file has a doc extension (.md/.mdx/.rst/.txt),
# skip. Earlier versions also skipped anything under `docs/` regardless of
# extension — that wrongly skipped non-doc files like `docs/scripts/setup.sh`
# or `docs/examples/app.ts`. The `(^|/)[^/]+\.ext$` anchor matches the final
# path segment only, so a doc anywhere in the tree (e.g. `src/notes.md`) still
# counts as a doc and a non-doc under `docs/` still counts as a non-doc.
NONDOC_COUNT=$(_cr_changed_names \
  | grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
  | awk 'END{print NR}')
if [ "$NONDOC_COUNT" -eq 0 ]; then
  exit 0
fi

# --- Gather the diff for the reviewer (capped) ---
DIFF=$(_cr_full_diff | head -c 200000)
if [ -z "$DIFF" ]; then
  exit 0
fi

# --- Idempotency marker ---
# A turn can fire this hook AND run the execute-body review over the same diff;
# we must not double-charge the LLM. Key the marker on a content hash of the
# diff (git hash-object --stdin — always present in a git hook, no coreutils
# dependency). If this exact diff was already reviewed this turn, exit 0. The marker is touched only AFTER a completed
# review (clean + advisory paths), NOT on the block path — a blocked turn must
# re-review once the diff changes via the fix.
DIFF_HASH=$(printf '%s' "$DIFF" | git hash-object --stdin 2>/dev/null)
MARKER="$REPO_ROOT/.claude/.review-done-${DIFF_HASH}"
if [ -f "$MARKER" ]; then
  exit 0
fi

# --- Build the reviewer envelope ---
# At L4/L5 the reviewer must also verify decision-log completeness vs diff.
# Pass the decisions-log content (if any) and the level as a JSON envelope.
if [ "$AUTONOMY_LEVEL" -ge 4 ] 2>/dev/null && [ -f "$DECISIONS_LOG_PATH" ]; then
  DECISIONS_PAYLOAD=$(head -c 50000 "$DECISIONS_LOG_PATH" 2>/dev/null)
else
  DECISIONS_PAYLOAD=""
fi
REVIEW_PAYLOAD=$(jq -nc \
  --arg diff "$DIFF" \
  --arg level "$AUTONOMY_LEVEL" \
  --arg decisions "$DECISIONS_PAYLOAD" \
  '{diff: $diff, autonomy_level: ($level | tonumber), decisions_log: $decisions}')

# --- Invoke the reviewer ladder (sibling lib) ---
# The 3-rung ladder (operator override → claude -p → deterministic regex) owns
# rung selection and ALWAYS emits one findings line, fail-open on every infra
# failure. Do NOT pre-export TRELLIS_REVIEW_IN_PROGRESS here: the ladder gates
# rung 2 on that sentinel, so pre-setting it would force every default-path call
# straight to the rung-3 regex and the built-in `claude -p` reviewer would never
# run. The ladder exports the sentinel itself before spawning ANY child (the
# rung-1 `exec` AND the rung-2 `claude`), so the child's own top-of-hook guard
# still trips — recursion is prevented without disabling rung 2. No outer
# `timeout` — the ladder bounds rung 2 internally via its perl-alarm shim.
# NB: no `2>/dev/null` here. lib/code-reviewer.sh deliberately leaves the rung-2
# `claude` stderr unsuppressed so a failing reviewer is visible; silencing fd 2
# on the caller side would re-introduce that documented mistake. stdout (the one
# findings line) is what we capture. `|| true` so a nonzero ladder never aborts.
FINDINGS=$(printf '%s' "$REVIEW_PAYLOAD" | bash "$HOOK_DIR/lib/code-reviewer.sh" || true)

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

  # Advisory findings → additionalContext (shown to Claude, not blocking).
  ADVISORY=$(printf '%s' "$FINDINGS" | jq -r '.findings[]? | "- [\(.severity)] \(.file):\(.line // "?") \(.msg)"' 2>/dev/null | head -30)
  if [ -n "$ADVISORY" ]; then
    jq -nc --arg ctx "<review>
${ADVISORY}
</review>" '{additionalContext: $ctx}'
  fi
fi

# Review completed (clean or advisory) — record the idempotency marker so the
# execute-body review does not re-charge the LLM for this exact diff this turn.
mkdir -p "$REPO_ROOT/.claude" 2>/dev/null || true
: > "$MARKER" 2>/dev/null || true

exit 0
