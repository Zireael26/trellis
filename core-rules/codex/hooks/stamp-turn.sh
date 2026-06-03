#!/usr/bin/env bash
# stamp-turn.sh — Codex Stop hook, single purpose. Phase 5b (E2 re-read-before-
# edit guard, Codex mirror of the Claude Phase 5a hook).
#
# Overwrites <KEY>.epoch with `date +%s` on EVERY Stop. This is the ONLY writer
# of .epoch. reread-guard reads it as the turn boundary: reads recorded before
# this stamp fall OUT of the next turn's known-set, so the agent must re-read a
# file it touched in a prior turn before editing it again.
#
# It is a DEDICATED hook (NOT an edit to stop-verify.sh) so it cannot be skipped
# by stop-verify's early-exit paths, and cannot break stop-verify's bats
# (the dedicated-hook core of DL-P5-02 stands).
#
# MIRROR DELTA vs the Claude hook: STATE_DIR = ROOT/.codex/.reread-state
# (not .claude). Everything else is byte-for-behavior identical. stamp-turn
# touches no file paths, so there is no relative-path delta here.
#
# WHY stamp on EVERY Stop — the stop_hook_active gate is REMOVED (DL-P5-06,
# which SUPERSEDES the gate clause of DL-P5-02). stop_hook_active==true is the
# post-block re-fire that the three sibling Stop *blockers* (stop-verify /
# code-review / ui-verify) gate on to avoid a re-block loop. A clock-STAMPER has
# NO re-block loop to prevent, so copying that gate was cargo-cult: it froze
# .epoch at the first (blocked) Stop of a block-involved turn, causing (a) a
# STALENESS LEAK — turn-N reads stayed >= turn_epoch into turn N+1, silently
# re-opening hazard F5; and (b) a ZERO-WARN FALSE-BLOCK — warns.tsv rows keyed
# at the frozen turn_epoch still counted next turn, so the first edit of that
# file was DENIED with NO warning, violating the locked "never zero warns"
# contract. Both were reviewer-reproduced end-to-end.
#
# Accepted mid-turn-friction (DL-P5-06): on a multi-Stop (block-involved) turn
# the boundary advances mid-turn, so a file read BEFORE a mid-turn block is
# evicted and re-editing it WARNS — but ≤ budget warns, it self-registers on the
# first successful edit, and it is NEVER a zero-warn block. A false-negative leak
# is worse than warn-friction for a safety guard.
#
# Budget unit (DL-P5-07): warns.tsv is keyed by turn_epoch; with the epoch
# advancing on every Stop, the per-file warn budget is now per-STAMP-INTERVAL,
# not per-logical-turn. Fail-LENIENT (more warns permitted, never fewer; "never
# zero warns" preserved).
#
# Contract:
#   - Reads Codex Stop event JSON on stdin.
#   - Overwrite <KEY>.epoch with `date +%s` on EVERY Stop. exit 0.
#   - Always exit 0. FAIL-OPEN: any error → exit 0 (a failed stamp just leaves
#     the prior boundary in place; it never blocks anything).
#
# State contract: see reread-guard.sh header. stamp-turn OWNS .epoch.
#
# Dependencies: jq (required), shasum, awk (BSD), date.

set -u

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "stamp-turn: missing sibling lib at $__se_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "stamp-turn"

# DL-P5-06: NO stop_hook_active gate — stamp on EVERY Stop (see header for why).

# --- derive the shared state key (DL-P5-09: one helper, zero inline copies) ---
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty') || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty') || exit 0
KEY=$(_se_state_key "$TP" "$SID") || exit 0
[ -n "$KEY" ] || exit 0   # key derivation failed → fail-open (no stamp)

# --- resolve root + stamp ---
ROOT=$(_se_repo_root "$(_se_project_dir)" 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0
STATE_DIR="$ROOT/.codex/.reread-state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

NOW=$(date +%s 2>/dev/null) || exit 0
printf '%s\n' "$NOW" > "$STATE_DIR/$KEY.epoch" 2>/dev/null || exit 0
exit 0
