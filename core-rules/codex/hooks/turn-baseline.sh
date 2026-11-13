#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# turn-baseline.sh — Codex UserPromptSubmit hook, single purpose (C01). Codex
# mirror of the Claude hook. Source: Trellis / core-rules / codex hooks.
#
# Records the turn-entry state stop-verify needs to tell a turn that mutated the
# tree from one that did not: appends a fingerprint of HEAD + index + tracked
# and untracked content (_se_tree_fingerprint, lib/deps.sh) to this session's
# baseline before the agent acts. stop-verify consumes the baseline at Stop; a
# turn whose tree still matches every recorded line owes no DoD receipt.
#
# Incremental: fp-cache beside the baseline keeps each dirty file's blob id
# under its stat identity, so only files that changed since the last
# fingerprint are re-read (lib/deps.sh __se_fp_perl). The hash is unchanged.
#
# APPEND, never overwrite: a prompt submitted mid-turn adds a line instead of
# replacing the turn-entry state, so it cannot launder an earlier edit.
#
# MIRROR DELTA vs the Claude hook: baselines are named <harness>.<KEY>, where
# harness is "pi" only when TRELLIS_HARNESS=pi and "codex" otherwise, so they
# never collide with a Claude session's.
#
# Floor: UserPromptSubmit needs Codex >= 0.116.0 (Trellis' R5 floor is 0.159.0).
# Whatever the version, a skipped or failed run leaves no usable
# baseline, and stop-verify then demands the receipt: unknown never reads as
# "no edits".
#
# Contract:
#   - Reads UserPromptSubmit JSON and exits 0. Successful publication is
#     silent; if no failure can be recorded, emit non-blocking model context
#     warning that the next Stop may not detect this turn.
#   - Fingerprint failure → appends a poison line (or removes the file), so
#     the Stop side reads unknown.
#   - Unparseable input or no session_id → removes every baseline of this
#     harness in this worktree (each becomes unknown) and records nothing.
#   - Storage: <TRELLIS_HOME or ~/.trellis>/state/turn-baseline/<worktree
#     hash>/<harness>.<KEY>, mode 0600, outside the worktree. Each line carries
#     a random nonce that is also appended to nonces.log beside it; Stop
#     rejects a line whose nonce the log lacks. This stops accidental or lazy
#     tampering only: an agent running as the same user can forge both files
#     and suppress the demand (accepted residual, hooks.md § stop-verify).
#
# Dependencies: jq (required), git, shasum, awk, od.

set -u

_se_prompt_baseline_notice() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"turn-baseline degraded: the next Stop may not detect this turn; verify changes and receipts manually."}}'
}

# Nested reviewers skip stop-verify, so nothing would ever consume a baseline
# recorded for them. Same guard as stop-verify's.
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { _se_prompt_baseline_notice; exit 0; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_load_heavy || { _se_prompt_baseline_notice; exit 0; }
command -v jq >/dev/null 2>&1 || { _se_prompt_baseline_notice; exit 0; }
_se_require_jq "turn-baseline"

HARNESS=codex
[ "${TRELLIS_HARNESS:-codex}" = "pi" ] && HARNESS=pi
PROJECT_DIR=$(_se_project_dir)
STATE_DIR=$(_se_turn_state_dir "$PROJECT_DIR") || { _se_turn_confirm_non_git "$PROJECT_DIR" || _se_prompt_baseline_notice; exit 0; }

# Non-string session ids cannot name a session. Invalidate earlier baselines
# rather than stringify malformed input into a different, apparently valid key.
SID=$(printf '%s' "$INPUT" | jq -er 'if type == "object" and (.session_id | type == "string") then .session_id else empty end' 2>/dev/null) || SID=""
KEY=""
[ -z "$SID" ] || KEY=$(_se_state_key "" "$SID") || KEY=""
if [ -n "$KEY" ]; then
  FILE="$STATE_DIR/$HARNESS.$KEY"
  UI_FILE="$STATE_DIR/ui.$HARNESS.$KEY"
  MISMATCH_FILE="$STATE_DIR/mismatch.$HARNESS.$KEY"
  ( umask 077 && mkdir -p "$STATE_DIR" ) 2>/dev/null || { _se_prompt_baseline_notice; exit 0; }
  if _se_inherited_project_mismatch "$INPUT" "$PROJECT_DIR"; then
    # A prompt cannot block, so persist the refusal for Stop, even when its
    # envelope later lacks cwd. Poison both baseline copies as a backstop.
    _se_mismatch_recorded=0 _se_boundary_recorded=0
    if _se_turn_lock "$STATE_DIR"; then
      ( umask 077 && printf 'mismatch\n' > "$MISMATCH_FILE" ) 2>/dev/null && _se_mismatch_recorded=1
      _se_turn_generation_bump "$STATE_DIR" "$HARNESS.$KEY" >/dev/null && _se_boundary_recorded=1
      ( umask 077 && printf 'trellis-turn-baseline v2 unknown\n' >> "$FILE" ) 2>/dev/null \
        && _se_mismatch_recorded=1 || { rm -f "${FILE:?}" 2>/dev/null && _se_mismatch_recorded=1; }
      if [ "$_se_mismatch_recorded" = 0 ] || [ "$_se_boundary_recorded" = 0 ]; then
        _se_turn_poison "$STATE_DIR" "$HARNESS.$KEY" && _se_mismatch_recorded=1 && _se_boundary_recorded=1
      fi
      if ! _se_turn_unlock "$STATE_DIR"; then
        _se_turn_poison "$STATE_DIR" "$HARNESS.$KEY" && _se_mismatch_recorded=1 && _se_boundary_recorded=1
      fi
    else
      # Never append or remove a baseline while another writer holds the
      # lock. A per-failure poison invalidates an in-flight deferred Stop.
      _se_turn_poison "$STATE_DIR" "$HARNESS.$KEY" && _se_mismatch_recorded=1 && _se_boundary_recorded=1
      ( umask 077 && printf 'mismatch\n' > "$MISMATCH_FILE" ) 2>/dev/null && _se_mismatch_recorded=1
    fi
    [ "$_se_mismatch_recorded" = 1 ] && [ "$_se_boundary_recorded" = 1 ] || _se_prompt_baseline_notice
    _se_ui_baseline_append "$UI_FILE" "" "" || true
    echo 'turn-baseline: inherited Claude project differs from the Codex worktree; Stop will refuse' >&2
    exit 0
  fi
  rm -f "${MISMATCH_FILE:?}" 2>/dev/null || true
fi
# An empty key invalidates this harness's earlier baselines, UI copy included.
_se_turn_baseline_publish "$PROJECT_DIR" "$HARNESS" "$SID" || _se_prompt_baseline_notice
exit 0
