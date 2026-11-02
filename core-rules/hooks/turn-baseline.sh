#!/usr/bin/env bash
# turn-baseline.sh — Claude UserPromptSubmit hook, single purpose (C01).
# Source: Trellis / core-rules / hooks.
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
# Floor: Claude Code >= 2.1.294 (2.1.288 fixed hooks skipped silently on a
# matcher or JSON serialization failure). Nothing in this tree checks the
# version yet; a doctor row is planned in the separate B0-5 unit. Whatever the
# version, a skipped or failed run leaves no usable
# baseline, and stop-verify then demands the receipt: unknown never reads as
# "no edits".
#
# Contract:
#   - Reads the UserPromptSubmit JSON on stdin. Prints NOTHING (stdout on this
#     event becomes prompt context) and exits 0 on every path past the jq
#     check, so it can never block or alter a prompt.
#   - Fingerprint failure → appends a poison line (or removes the file), so
#     the Stop side reads unknown.
#   - Unparseable input or no session_id → removes every Claude baseline in
#     this worktree (each becomes unknown) and records nothing.
#   - Storage: <TRELLIS_HOME or ~/.trellis>/state/turn-baseline/<worktree
#     hash>/<harness>.<KEY>, mode 0600, outside the worktree. Each line carries
#     a random nonce that is also appended to nonces.log beside it; Stop
#     rejects a line whose nonce the log lacks. This stops accidental or lazy
#     tampering only: an agent running as the same user can forge both files
#     and suppress the demand (accepted residual, hooks.md § stop-verify).
#
# Dependencies: jq (required), git, shasum, awk, od.

set -u

# Nested reviewers skip stop-verify, so nothing would ever consume a baseline
# recorded for them. Same guard as stop-verify's.
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "turn-baseline: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "turn-baseline"

PROJECT_DIR=$(_se_project_dir)
STATE_DIR=$(_se_turn_state_dir "$PROJECT_DIR") || exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SID=""
KEY=""
[ -z "$SID" ] || KEY=$(_se_state_key "" "$SID") || KEY=""
if [ -z "$KEY" ]; then
  rm -f "$STATE_DIR"/"claude".* 2>/dev/null
  exit 0
fi

FILE="$STATE_DIR/claude.$KEY"
( umask 077 && mkdir -p "$STATE_DIR" ) 2>/dev/null || exit 0
# The nonce goes to the hook-only log first; a baseline line whose nonce is not
# in the log reads as unknown at Stop.
if NONCE=$(_se_turn_nonce) && FP=$(_se_tree_fingerprint "$PROJECT_DIR" "$STATE_DIR/fp-cache") \
   && ( umask 077 && printf '%s %s\n' "claude.$KEY" "$NONCE" >> "$STATE_DIR/nonces.log" ) 2>/dev/null; then
  ( umask 077 && printf 'trellis-turn-baseline v2 %s %s\n' "$NONCE" "$FP" >> "$FILE" ) 2>/dev/null || rm -f "$FILE" 2>/dev/null
else
  ( umask 077 && printf 'trellis-turn-baseline v2 unknown\n' >> "$FILE" ) 2>/dev/null || rm -f "$FILE" 2>/dev/null
fi
chmod 600 "$FILE" "$STATE_DIR/nonces.log" 2>/dev/null
exit 0
