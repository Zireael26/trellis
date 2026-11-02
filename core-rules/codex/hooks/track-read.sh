#!/usr/bin/env bash
# track-read.sh — Codex PostToolUse on Read|Write|Edit|MultiEdit.
# Source: Trellis / core-rules / codex hooks. Phase 5b (E2 re-read-before-edit
# guard, Codex mirror of the Claude Phase 5a hook).
#
# Records the known-set for reread-guard.sh: every structured Read and every
# non-explicitly-failed file mutation appends a "<now_epoch>\t<path>" row for
# each affected path to <KEY>.reads.tsv. The guard's
# IN_SET test reads only this file. Recording a Write/Edit here is the NEW-4
# mitigation — it is what lets "Write B then Edit B" and "Edit A then Edit A"
# PASS, and what stops a FAILED stale edit (which does NOT record) from being
# counted as a successful re-read.
#
# Native Codex shell calls deliberately earn no file-read credit: parsing an
# arbitrary command is not a reliable read observation.
#
# Harness-specific state is ROOT/.pi/.reread-state only when
# TRELLIS_HARNESS=pi; otherwise it remains ROOT/.codex/.reread-state. Other
# Codex-specific deltas include native action normalization and the rule that
# shell commands earn no read credit.
#
# Contract:
#   - Reads Codex tool event JSON on stdin.
#   - Success-detection is SHAPE-based for the edit family, NOT a content grep
#     (DL-P5-08): a SUCCESSFUL Edit/Write/MultiEdit tool_response is an OBJECT
#     that echoes the edited code (originalFile / structuredPatch / newString),
#     so grepping the whole stringified response for failure markers misread any
#     edited file whose BODY contained 'Error:' / 'not found' / 'ENOENT' as a
#     FAILED edit → it was not recorded → a legit re-edit escalated to a BLOCK.
#       * tool_response type == object → a SUCCESSFUL edit → RECORD; skip ONLY on
#         an explicit error key (.error non-empty, .is_error == true, or
#         .tool_use_error non-empty).
#       * tool_response type == string → a genuine edit FAILURE arrives as an
#         error string → keep the marker grep; on a marker, do NOT record.
#       * anything else (null/number/absent) → RECORD (lean lenient).
#     A Read (or any non-edit tool) is ALWAYS recorded — a Read body is the file
#     content, never a failure indicator.
#   - Always exit 0. FAIL-OPEN: any error → exit 0 (and, on doubt, RECORD).
#
# State contract: see reread-guard.sh header. track-read OWNS reads.tsv.
#
# Failure markers: core-rules/hooks/rules/reread.json, compiled into
# lib/guard-rules.sh by scripts/gen-guard-rules.py.
#
# Dependencies: jq (required — one call), sha256sum or shasum, awk (BSD), git.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "track-read: missing sibling lib at $__se_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "track-read"

__gr_lib="$(dirname "${BASH_SOURCE[0]}")/lib/guard-rules.sh"
[ -f "$__gr_lib" ] || { echo "track-read: missing sibling lib at $__gr_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/guard-rules.sh disable=SC1090
. "$__gr_lib"

# Sibling first; the in-place fallback applies only inside the declared
# runtime's Codex tree (spec 055 R1.1), never a project-controlled hooks/lib/.
__h_dir=$(unset CDPATH; cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
__h_rt=$(unset CDPATH; [ -n "${TRELLIS_ROOT:-}" ] && cd -P -- "$TRELLIS_ROOT" 2>/dev/null && pwd -P)
__ta_lib="$__h_dir/lib/action-normalize.sh"
if [ ! -f "$__ta_lib" ] && [ -n "$__h_rt" ] && [ "$__h_dir" = "$__h_rt/core-rules/codex/hooks" ]; then
  __ta_lib="$__h_dir/../../hooks/lib/action-normalize.sh"
fi
[ -f "$__ta_lib" ] || exit 0
# shellcheck source=../../hooks/lib/action-normalize.sh disable=SC1090
. "$__ta_lib"

# One jq run normalizes the event and yields every field this tracker reads.
_ta_guard_fields post_action "$INPUT" "$GR_EDIT_FAILURE_RE" "$GR_EDIT_FAILURE_FLAGS" || exit 0
case "$TA_FAMILY" in
  file_read|file_mutation)
    [ "$TA_STATUS" != "failed" ] || exit 0 ;;
  *) exit 0 ;;
esac

ACTION_CWD=$TA_CWD
[ -d "$ACTION_CWD" ] || ACTION_CWD="$(_se_project_dir)"

# Codex may pass a relative file_path; resolve against the project dir. Claude
# always passes absolute (verbatim). Store + compare identically with the guard.
record_target() {
  local T="$1"
  T=$(_ta_resolve_path "$ACTION_CWD" "$T") || return 0

# FIX-5 (DL-P5-10): reads.tsv is TAB-delimited, newline-terminated. A target
# containing a TAB or a NEWLINE would forge/split rows → SKIP recording (a
# corrupt row is worse than a missed record; the guard fails-open on the same).
# This MUST run BEFORE _se_normpath: normpath's awk pass is line-oriented and
# would silently EAT an embedded newline (split the record, concatenate the
# halves), so a post-normpath check could never see it. (Deviation from the
# mandate's "normalized target" wording — normpath is newline-lossy, so pre-
# normpath detection is the only correct realization of the intent.)
# Detect a NEWLINE with a LITERAL-newline variable, not $(printf '\n') (command
# substitution strips the trailing newline → matches everything — the Phase-4
# tick.sh lesson). Detect a TAB with tab=$(printf '\t') (a tab survives subst).
tab=$(printf '\t')
nl='
'
case "$T" in
  *"$tab"*|*"$nl"*)
    echo "track-read: target contains a TAB/NEWLINE — skipping record (would corrupt reads.tsv)" >&2
    return 0 ;;
esac

# FIX-4 (DL-P5-10): lexically normalize the resolved target BEFORE storing, so
# the store side here and the compare side in reread-guard produce the SAME
# spelling (./foo ≡ foo ≡ a/../foo). Near-no-op for Claude's absolute paths;
# this fixes the Codex relative-path IN_SET self-block.
T=$(_se_normpath "$T")
[ -n "$T" ] || return 0

# --- derive the shared state key (DL-P5-09: one helper, zero inline copies) ---
KEY=$(_se_state_key "$TA_TP" "$TA_SID") || return 0
[ -n "$KEY" ] || return 0   # key derivation failed → fail-open (no record)

# --- resolve root + record ---
ROOT=$(_se_repo_root "$(_se_project_dir)" 2>/dev/null) || return 0
[ -n "$ROOT" ] || return 0
STATE_DIR="$(_se_harness_home "$ROOT")/.reread-state"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || return 0

_gr_now
[ -n "$GR_NOW" ] || return 0
printf '%s\t%s\n' "$GR_NOW" "$T" >> "$STATE_DIR/$KEY.reads.tsv" 2>/dev/null || return 0
}

__i=0
while [ "$__i" -lt "${#TA_OPS[@]}" ]; do
  case "${TA_OPS[__i]}" in
    read|create|update) record_target "${TA_PATHS[__i]}" ;;
    rename) record_target "${TA_DESTS[__i]}" ;;
    delete) ;;
  esac
  __i=$((__i + 1))
done
exit 0
