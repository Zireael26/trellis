#!/usr/bin/env bash
# reread-guard.sh — Claude PreToolUse on Edit|MultiEdit|Write.
# Source: Trellis / core-rules / hooks. Phase 5a (E2 re-read-before-edit guard).
#
# Hazard F5: an agent edits an EXISTING file using a STALE mental model (read
# long ago, or never) → old_string mismatches or the edit is plain wrong.
#
# Guard: before editing an EXISTING file you must have Read it THIS turn OR
# Written it THIS turn (the known-set = Read ∪ Written this turn, recorded by
# the sibling track-read.sh). Otherwise WARN, and after a per-level budget of
# warns, BLOCK. The block fires at EVERY autonomy level — the slider tunes only
# how many warns precede it (never zero). Locked decision #2.
#
# Contract:
#   - Reads Claude Code tool event JSON on stdin.
#   - WARN  = advisory on STDERR, append a warns row, exit 0, NO permissionDecision
#             (so it never bypasses Claude's normal permission prompts).
#   - BLOCK = PreToolUse deny JSON on stdout, exit 0.
#   - Exit is ALWAYS 0 (PreToolUse decisions ride in the JSON, not the exit code).
#   - FAIL-OPEN: any STATE error (missing/corrupt state, shasum/mkdir failure,
#     empty/odd target — e.g. a TAB/NEWLINE in the path) → PERMIT silently (no
#     decision). A state error must NEVER block all edits. jq-missing follows the
#     shared _se_require_jq P1.5 convention (rc!=0 + install help unless
#     TRELLIS_NO_JQ_DEGRADE=1). (DL-P5-11)
#
# State contract (identical across reread-guard / track-read / stamp-turn):
#   ROOT      = _se_repo_root "$(_se_project_dir)"   (canonical, worktree-aware)
#   STATE_DIR = ROOT/.claude/.reread-state           (runtime artifact, never committed)
#   KEY       = _se_state_key transcript_path session_id  (16 hex; session_id
#               PRIMARY, transcript_path FALLBACK, "default" last — DL-P5-09)
#   <KEY>.epoch     last GENUINE turn-end epoch (absent → 0); written ONLY by stamp-turn
#   <KEY>.reads.tsv "<read_epoch>\t<path>" rows; written ONLY by track-read
#   <KEY>.warns.tsv "<turn_epoch>\t<path>" rows; written ONLY by reread-guard
#   IN_SET(T): some reads.tsv row has read_epoch >= turn_epoch AND path == T
#   Targets are lexically normalized via _se_normpath before compare so the
#   store side (track-read) and the compare side here agree (DL-P5-10).
#
# Dependencies: jq (required), shasum, awk (BSD).

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "reread-guard: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "reread-guard"

# --- target file ---
T=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -n "$T" ] || exit 0   # empty target → permit (fail-open)

# Resolve a relative target against the project dir (Codex may pass relative;
# Claude always passes absolute → no-op), then lexically normalize so the
# spelling here MATCHES track-read's stored spelling (FIX-4 / DL-P5-10).
case "$T" in
  /*) ;;
  *) T="$(_se_project_dir)/$T" ;;
esac

# FIX-5 (DL-P5-10): a target containing a TAB or NEWLINE cannot be safely matched
# against the TAB-delimited reads.tsv → FAIL-OPEN (permit, no decision). This
# MUST run BEFORE _se_normpath: normpath's awk pass is line-oriented and would
# silently EAT an embedded newline, so a post-normpath check could never detect
# it. (Deviation from the mandate's "normalized target" wording — normpath is
# newline-lossy, so pre-normpath detection is the only correct realization.)
# Detect the NEWLINE with a literal-newline variable (NOT $(printf '\n'), which
# strips the trailing newline and would match everything — the Phase-4 tick.sh
# lesson). Detect a TAB with tab=$(printf '\t') (a tab survives substitution).
tab=$(printf '\t')
nl='
'
case "$T" in
  *"$tab"*|*"$nl"*)
    echo "reread-guard: target contains a TAB/NEWLINE — cannot match safely, permitting (fail-open)" >&2
    exit 0 ;;
esac

# Lexically normalize so the spelling here MATCHES track-read's stored spelling
# (FIX-4 / DL-P5-10). No-op for Claude's already-absolute paths.
T=$(_se_normpath "$T")
[ -n "$T" ] || exit 0

# --- override escape: logged, never silent ---
if [ "${TRELLIS_REREAD_OVERRIDE:-0}" = "1" ]; then
  # Best-effort breadcrumb so the escape is recorded, then permit. Any failure
  # to log falls back to stderr; either way we PERMIT (logged escape). The
  # breadcrumb uses the already-normalized $T (FIX-4).
  ROOT=$(_se_repo_root "$(_se_project_dir)" 2>/dev/null) || ROOT=""
  TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || TP=""
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SID=""
  KEY=$(_se_state_key "$TP" "$SID") || KEY=""
  if [ -n "$ROOT" ] && [ -n "$KEY" ]; then
    STATE_DIR="$ROOT/.claude/.reread-state"
    if mkdir -p "$STATE_DIR" 2>/dev/null; then
      now=$(date +%s 2>/dev/null) || now=0
      printf '%s\t%s\n' "$now" "OVERRIDE:$T" >> "$STATE_DIR/$KEY.warns.tsv" 2>/dev/null \
        || echo "reread-guard: TRELLIS_REREAD_OVERRIDE=1 logged-escape for $T (warns.tsv unwritable)" >&2
    else
      echo "reread-guard: TRELLIS_REREAD_OVERRIDE=1 logged-escape for $T (state dir unwritable)" >&2
    fi
  else
    echo "reread-guard: TRELLIS_REREAD_OVERRIDE=1 logged-escape for $T" >&2
  fi
  exit 0
fi

# --- derive the shared state key (DL-P5-09: one helper, zero inline copies) ---
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty') || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty') || exit 0
KEY=$(_se_state_key "$TP" "$SID") || exit 0
[ -n "$KEY" ] || exit 0   # key derivation failed → permit (fail-open)

# --- resolve state; any failure → PERMIT (fail-open) ---
ROOT=$(_se_repo_root "$(_se_project_dir)" 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0
STATE_DIR="$ROOT/.claude/.reread-state"

# new-file test: a path that does not exist on disk is EXEMPT (a Write that
# creates it). track-read records it after the Write succeeds. Permit silently.
[ -e "$T" ] || exit 0

# turn_epoch = contents of <KEY>.epoch, or 0 if absent/unreadable/non-numeric.
TURN_EPOCH=0
EPOCH_FILE="$STATE_DIR/$KEY.epoch"
if [ -f "$EPOCH_FILE" ]; then
  _e=$(head -1 "$EPOCH_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_e" in
    ''|*[!0-9]*) TURN_EPOCH=0 ;;
    *) TURN_EPOCH="$_e" ;;
  esac
fi

# IN_SET test: a reads.tsv row with read_epoch >= turn_epoch AND path == T.
# Pass the path via ENVIRON (NOT -v) so paths containing backslashes are not
# mangled by awk escape processing. exit 0 from awk → found.
READS_FILE="$STATE_DIR/$KEY.reads.tsv"
if [ -f "$READS_FILE" ]; then
  T="$T" TURN_EPOCH="$TURN_EPOCH" awk -F '\t' '
    BEGIN { found=1 }
    $2 == ENVIRON["T"] && ($1+0) >= (ENVIRON["TURN_EPOCH"]+0) { found=0; exit }
    END { exit found }
  ' "$READS_FILE" 2>/dev/null && exit 0
fi

# --- T exists, NOT in the known-set: resolve autonomy, apply warn budget ---

# Autonomy resolution mirrors code-review-subagent.sh (verbatim algorithm).
REPO_ROOT="$ROOT"
AUTONOMY_LEVEL=3
TRELLIS_CFG=""
if [ -n "${TRELLIS_ROOT:-}" ] && [ -f "$TRELLIS_ROOT/trellis.config.json" ]; then
  TRELLIS_CFG="$TRELLIS_ROOT/trellis.config.json"
fi
if [ -n "$TRELLIS_CFG" ] && command -v jq >/dev/null 2>&1; then
  FLEET=$(jq -r '.autonomy_default // empty' "$TRELLIS_CFG" 2>/dev/null)
  [ -n "$FLEET" ] && AUTONOMY_LEVEL="$FLEET"
fi
for cand in "$REPO_ROOT/.trellis.config.json" "$REPO_ROOT/trellis.config.json"; do
  if [ -f "$cand" ] && command -v jq >/dev/null 2>&1; then
    PL=$(jq -r '.autonomy // empty' "$cand" 2>/dev/null)
    [ -n "$PL" ] && AUTONOMY_LEVEL="$PL"
    break
  fi
done
SESSION_FILE="$REPO_ROOT/.claude/session-autonomy"
if [ -f "$SESSION_FILE" ]; then
  SESS=$(head -1 "$SESSION_FILE" | tr -d '[:space:]')
  case "$SESS" in 1|2|3|4|5) AUTONOMY_LEVEL="$SESS" ;; esac
fi

# warn-budget(level): L1=2, L2=2, L3=2, L4=1, L5=1. NEVER 0.
case "$AUTONOMY_LEVEL" in
  4|5) BUDGET=1 ;;
  *)   BUDGET=2 ;;
esac

# count warns already issued for T THIS turn = warns.tsv rows with
# col1 == turn_epoch AND col2 == T.
WARN_COUNT=0
WARNS_FILE="$STATE_DIR/$KEY.warns.tsv"
if [ -f "$WARNS_FILE" ]; then
  WARN_COUNT=$(T="$T" TURN_EPOCH="$TURN_EPOCH" awk -F '\t' '
    $2 == ENVIRON["T"] && $1 == ENVIRON["TURN_EPOCH"] { n++ }
    END { print n+0 }
  ' "$WARNS_FILE" 2>/dev/null) || WARN_COUNT=0
  case "$WARN_COUNT" in ''|*[!0-9]*) WARN_COUNT=0 ;; esac
fi

if [ "$WARN_COUNT" -lt "$BUDGET" ]; then
  # WARN: record the warn, advise on STDERR, PERMIT (no permissionDecision).
  # Failing to record a warn → fail-open: still PERMIT (we never escalate to a
  # block on a state error).
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    printf '%s\t%s\n' "$TURN_EPOCH" "$T" >> "$WARNS_FILE" 2>/dev/null || true
  fi
  N=$((WARN_COUNT + 1))
  echo "reread-guard: about to edit $T not Read this turn (warn $N/$BUDGET). Read it first, or export TRELLIS_REREAD_OVERRIDE=1. Repeated FAILED stale edits will BLOCK." >&2
  exit 0
fi

# BLOCK: budget exhausted. Emit the PreToolUse deny decision; exit 0.
REASON="reread-guard: BLOCKED edit of $T — it was not Read this turn and the re-read warn budget is exhausted. Read it first, or export TRELLIS_REREAD_OVERRIDE=1 to override."
jq -nc \
  --arg reason "$REASON" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
