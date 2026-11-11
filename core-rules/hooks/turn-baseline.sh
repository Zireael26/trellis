#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
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
#   - Reads UserPromptSubmit JSON and exits 0. Successful publication is
#     silent; if no failure can be recorded, emit non-blocking model context
#     warning that the next Stop may not detect this turn.
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
command -v jq >/dev/null 2>&1 || { _se_prompt_baseline_notice; exit 0; }
_se_require_jq "turn-baseline"

PROJECT_DIR=$(_se_project_dir)
# Non-string session ids cannot name a session. Invalidate earlier baselines
# rather than stringify malformed input into a different, apparently valid key.
SID=$(printf '%s' "$INPUT" | jq -er 'if type == "object" and (.session_id | type == "string") then .session_id else empty end' 2>/dev/null) || SID=""
_se_turn_baseline_publish "$PROJECT_DIR" claude "$SID" || _se_prompt_baseline_notice
exit 0
