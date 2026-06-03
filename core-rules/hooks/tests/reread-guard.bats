#!/usr/bin/env bats
# Tests for the Phase 5a E2 re-read-before-edit guard (Claude side):
#   reread-guard.sh (PreToolUse Edit|MultiEdit|Write — warn→block at all levels)
#   track-read.sh   (PostToolUse recorder — owns reads.tsv)
#   stamp-turn.sh   (Stop hook — sole writer of .epoch)
#
# Epoch discipline: NEVER drive these tests off wall-clock comparisons. date +%s
# can return the same second twice, so a freshly-recorded read could land at
# read_epoch == turn_epoch and stay IN-set by the >= rule. Instead we pre-write
# state with EXPLICIT integer epochs (turn boundary 1000; reads at 2000) so the
# known-set relationships are deterministic. A single fixed transcript_path is
# used in every envelope so KEY is constant across guard/track/stamp.
#
# Channels are asserted APART:
#   WARN  = exit 0, advisory on STDERR, a warns.tsv row, NO "deny" on stdout.
#   BLOCK = "deny" JSON on stdout, exit 0.

load helpers

GUARD="$HOOKS_DIR/reread-guard.sh"
TRACK="$HOOKS_DIR/track-read.sh"
STAMP="$HOOKS_DIR/stamp-turn.sh"

# A stable transcript path → a stable KEY across all envelopes / all hooks.
TP="/tmp/reread-guard-bats-transcript.jsonl"

setup() {
  # Real project root with a git repo so _se_repo_root resolves cleanly.
  PROJECT_DIR="$(mktemp -d)"
  ( cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -q -m init )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  STATE_DIR="$PROJECT_DIR/.claude/.reread-state"
  KEY="$(printf '%s' "$TP" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"
  mkdir -p "$STATE_DIR"
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    chmod -R u+rwx "$PROJECT_DIR" 2>/dev/null || true
    rm -rf "$PROJECT_DIR"
  fi
}

# --- helpers -----------------------------------------------------------------

# Set the turn boundary to an explicit integer epoch.
set_turn_epoch() { printf '%s\n' "$1" > "$STATE_DIR/$KEY.epoch"; }

# Record a read row at an explicit epoch for a path (simulates track-read).
record_read() { printf '%s\t%s\n' "$1" "$2" >> "$STATE_DIR/$KEY.reads.tsv"; }

# Run the guard for an existing/new target $1; sets: status, output (stdout),
# stderr. Uses the stable transcript path.
run_guard() {
  local target="$1"
  run_with_stderr "$GUARD" "$(jq -nc --arg tp "$TP" --arg t "$target" \
    '{transcript_path: $tp, tool_input: {file_path: $t}}')"
}

# Count warns.tsv rows for $1 at turn-epoch $2.
warn_rows() {
  [ -f "$STATE_DIR/$KEY.warns.tsv" ] || { echo 0; return; }
  T="$1" E="$2" awk -F '\t' '$2==ENVIRON["T"] && $1==ENVIRON["E"]{n++} END{print n+0}' \
    "$STATE_DIR/$KEY.warns.tsv"
}

# =============================================================================
# known-after-Read passes silent
# =============================================================================
@test "known-after-Read: existing file Read this turn → silent permit" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/known.txt"; echo "data" > "$f"
  record_read 2000 "$f"          # read AFTER the turn boundary → IN_SET
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]               # no deny JSON
  [ -z "$stderr" ]               # no warning
}

# =============================================================================
# stale unread existing file warns then BLOCKS after the budget
# (drive past budget by repeated guard calls with NO intervening record)
# =============================================================================
@test "stale-existing: L3 budget 2 → warn, warn, then BLOCK (never an immediate block)" {
  set_turn_epoch 1000           # no reads recorded → T is stale
  f="$PROJECT_DIR/stale.txt"; echo "old" > "$f"

  # Call 1 — WARN, not a block.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]      # NEVER an immediate block
  [[ "$stderr" == *"warn 1/2"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 1 ]

  # Call 2 — WARN, still not a block.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]
  [[ "$stderr" == *"warn 2/2"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 2 ]

  # Call 3 — budget exhausted → BLOCK on stdout, no further warn row.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *deny* ]]
  [[ "$output" == *"$f"* ]]
  [[ "$output" == *"TRELLIS_REREAD_OVERRIDE=1"* ]]
  [ -z "$stderr" ]
  [ "$(warn_rows "$f" 1000)" -eq 2 ]   # block did not append a warn
}

# =============================================================================
# warn-then-block fires at L5 too (budget 1 → exactly one warn then block;
# NEVER an immediate block at any level)
# =============================================================================
@test "L5: budget 1 → exactly one warn, then BLOCK (no immediate block)" {
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"
  set_turn_epoch 1000
  f="$PROJECT_DIR/l5.txt"; echo "old" > "$f"

  # Call 1 — single warn, NOT a block (the L5 warn is never skipped).
  run_guard "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]
  [[ "$stderr" == *"warn 1/1"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 1 ]

  # Call 2 — block.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *deny* ]]
}

# =============================================================================
# new-file Write exempt (target does not exist on disk)
# =============================================================================
@test "new-file: a Write to a nonexistent path is exempt → silent permit" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/brand-new.txt"   # never created
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -f "$STATE_DIR/$KEY.warns.tsv" ]   # exempt path records nothing
}

# =============================================================================
# INTEGRATION: a real Read envelope through track-read makes the guard silent
# (the headline guarantee — "a just-Read file passes silently" — end-to-end,
# NOT via hand-seeded reads.tsv).
# =============================================================================
@test "integration: Read → track-read → guard silent on the just-Read file" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/just-read.txt"; printf 'hello world\n' > "$f"

  # Real Claude Read PostToolUse envelope: tool_response IS the file body.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$f" --arg body "$(cat "$f")" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: $body}')"
  [ "$status" -eq 0 ]
  run grep -F -- "$f" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  # The guard sees it in the known-set → silent permit.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "integration: a Read whose CONTENT contains 'Error:'/'not found' is still recorded → guard silent" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/source-with-markers.txt"
  # A perfectly normal source file that happens to contain edit-failure words.
  printf 'log("Error: not found"); // does not match anything real\n' > "$f"

  # Read of this file is a SUCCESSFUL read — its body must not be mistaken for
  # a failure. track-read records it; the guard must then be silent.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$f" --arg body "$(cat "$f")" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: $body}')"
  [ "$status" -eq 0 ]
  run grep -F -- "$f" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# =============================================================================
# Write-B-then-Edit-B passes (self-register via track-read)
# =============================================================================
@test "Write-B-then-Edit-B: a successful Write recorded by track-read → Edit B passes silent" {
  set_turn_epoch 1000
  b="$PROJECT_DIR/b.txt"; touch "$b"   # exists → Edit hits IN_SET, not new-file exempt

  # track-read records the SUCCESSFUL Write of B.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$b" \
    '{transcript_path: $tp, tool_name: "Write", tool_input: {file_path: $t}, tool_response: {filePath: $t, success: true}}')"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/$KEY.reads.tsv" ]
  run grep -F -- "$b" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  # Edit B now passes silently (B is in the known-set via the Write record).
  run_guard "$b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# =============================================================================
# Edit-A-then-Edit-A passes (first Edit warns; track-read records the success;
# second Edit is silent — neither call BLOCKS)
# =============================================================================
@test "Edit-A-then-Edit-A: first Edit warns, track-read records, second Edit silent — neither blocks" {
  set_turn_epoch 1000
  a="$PROJECT_DIR/a.txt"; echo "x" > "$a"   # exists, never read this turn

  # First Edit A — A is stale → WARN (a pass), not a block.
  run_guard "$a"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]
  [[ "$stderr" == *"warn 1/"* ]]

  # The Edit succeeded; track-read records A.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$a" \
    '{transcript_path: $tp, tool_name: "Edit", tool_input: {file_path: $t}, tool_response: {filePath: $t, success: true}}')"
  [ "$status" -eq 0 ]

  # Second Edit A — now in the known-set → silent permit, never a block.
  run_guard "$a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# =============================================================================
# A FAILED stale edit does NOT record → the warn→block counter keeps climbing
# (the "does not match" loop that the guard exists to catch)
# =============================================================================
@test "failed-stale-edit: track-read skips a 'does not match' response → warns accumulate to a block" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/loop.txt"; echo "old" > "$f"

  # First guard call warns.
  run_guard "$f"
  [[ "$output" != *deny* ]]
  [[ "$stderr" == *"warn 1/2"* ]]

  # The Edit FAILED (old_string mismatch). track-read must NOT record it.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$f" \
    '{transcript_path: $tp, tool_name: "Edit", tool_input: {file_path: $t}, tool_response: "Error: String to replace not found in file. The provided string does not match."}')"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_DIR/$KEY.reads.tsv" ] || ! grep -qF -- "$f" "$STATE_DIR/$KEY.reads.tsv"

  # Second guard call — still stale → second warn.
  run_guard "$f"
  [[ "$output" != *deny* ]]
  [[ "$stderr" == *"warn 2/2"* ]]

  # Third — budget exhausted → BLOCK.
  run_guard "$f"
  [[ "$output" == *deny* ]]
}

# =============================================================================
# TRELLIS_REREAD_OVERRIDE=1 escapes (logged, never silent)
# =============================================================================
@test "override: TRELLIS_REREAD_OVERRIDE=1 permits a stale edit and logs a breadcrumb" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/override.txt"; echo "old" > "$f"
  export TRELLIS_REREAD_OVERRIDE=1
  run_with_stderr "$GUARD" "$(jq -nc --arg tp "$TP" --arg t "$f" \
    '{transcript_path: $tp, tool_input: {file_path: $t}}')"
  unset TRELLIS_REREAD_OVERRIDE
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]      # permitted
  # Logged escape: a breadcrumb landed in warns.tsv (or, if unwritable, stderr).
  if [ -f "$STATE_DIR/$KEY.warns.tsv" ]; then
    run grep -F -- "OVERRIDE:$f" "$STATE_DIR/$KEY.warns.tsv"
    [ "$status" -eq 0 ]
  else
    [[ "$stderr" == *"TRELLIS_REREAD_OVERRIDE=1"* ]]
  fi
}

# =============================================================================
# corrupt / missing state => fail-OPEN permit
# A genuinely unreadable state dir must NEVER produce a block — the gate
# degrades to permit. Drive past where a block would otherwise fire.
# =============================================================================
@test "fail-open: unwritable state dir → permit, never a block (even past the budget)" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/fo.txt"; echo "old" > "$f"
  chmod 000 "$PROJECT_DIR/.claude"   # state dir becomes unreadable/unwritable
  i=0
  while [ "$i" -lt 5 ]; do
    run_guard "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *deny* ]]        # never a block
    i=$((i + 1))
  done
  chmod 755 "$PROJECT_DIR/.claude"
}

@test "fail-open: malformed stdin JSON → permit (no crash, no block)" {
  run_with_stderr "$GUARD" 'this is not json at all'
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]
}

@test "fail-open: empty target → permit" {
  run_with_stderr "$GUARD" "$(jq -nc --arg tp "$TP" '{transcript_path: $tp, tool_input: {}}')"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]
}

# =============================================================================
# FIX-2 (DL-P5-06): stamp-turn advances .epoch on EVERY Stop, INCLUDING
# stop_hook_active=true. This INVERTS the pre-remediation case F, which asserted
# the buggy "stop(true) leaves .epoch unchanged" as PASS (the gate froze .epoch
# at the first blocked Stop → staleness leak + zero-warn false-block). RED on the
# OLD stamp-turn (.epoch stays 1000), GREEN on the fixed one (.epoch advances).
# =============================================================================
@test "stamp-turn: stop_hook_active=true ADVANCES .epoch (FIX-2 — gate removed)" {
  set_turn_epoch 1000
  run_with_stderr "$STAMP" "$(jq -nc --arg tp "$TP" \
    '{transcript_path: $tp, stop_hook_active: true}')"
  [ "$status" -eq 0 ]
  new_epoch="$(cat "$STATE_DIR/$KEY.epoch")"
  [ "$new_epoch" != "1000" ]    # the frozen-epoch gate is gone
  [ "$new_epoch" -gt 1000 ]     # advanced to the current wall clock (≫1000)
}

@test "stamp-turn: genuine turn-end advances .epoch; a prior-turn read falls OUT of the known-set" {
  # Turn 1: boundary 1000, file read at epoch 2000 → IN_SET.
  set_turn_epoch 1000
  f="$PROJECT_DIR/carry.txt"; echo "x" > "$f"
  record_read 2000 "$f"
  run_guard "$f"
  [ -z "$output" ]; [ -z "$stderr" ]              # IN_SET → silent

  # Genuine turn-end (stop_hook_active != true) → .epoch advances to now (≫2000).
  run_with_stderr "$STAMP" "$(jq -nc --arg tp "$TP" \
    '{transcript_path: $tp, stop_hook_active: false}')"
  [ "$status" -eq 0 ]
  new_epoch="$(cat "$STATE_DIR/$KEY.epoch")"
  [ "$new_epoch" -gt 2000 ]                        # advanced past the prior read

  # Turn 2: the epoch=2000 read is now BELOW the boundary → OUT of the known-set
  # → editing the same file warns (stale).
  run_guard "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]
  [[ "$stderr" == *"not Read this turn"* ]]
}

# =============================================================================
# The SAME KEY is derived across guard / track / stamp from the same stdin.
# =============================================================================
@test "same-key: stamp-turn, track-read, and reread-guard all write under one KEY stem" {
  # stamp-turn writes <KEY>.epoch
  run_with_stderr "$STAMP" "$(jq -nc --arg tp "$TP" '{transcript_path: $tp, stop_hook_active: false}')"
  [ -f "$STATE_DIR/$KEY.epoch" ]

  # track-read writes <KEY>.reads.tsv
  g="$PROJECT_DIR/k.txt"; echo y > "$g"
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$g" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: "ok"}')"
  [ -f "$STATE_DIR/$KEY.reads.tsv" ]

  # reread-guard (stale path, fresh turn) writes <KEY>.warns.tsv
  printf '%s\n' "9999999999" > "$STATE_DIR/$KEY.epoch"   # boundary in the far future
  h="$PROJECT_DIR/stalekey.txt"; echo z > "$h"
  run_guard "$h"
  [ -f "$STATE_DIR/$KEY.warns.tsv" ]

  # All three artifacts share exactly ONE KEY stem.
  stems="$(ls "$STATE_DIR" | sed 's/\.[^.]*$//; s/\.reads$//; s/\.warns$//' | sort -u)"
  [ "$(printf '%s\n' "$stems" | grep -c .)" -eq 1 ]
  [ "$stems" = "$KEY" ]
}

# =============================================================================
# FIX-1 (DL-P5-08): a SUCCESSFUL Edit whose tool_response is an OBJECT echoing
# code that CONTAINS 'Error:' / 'not found' is RECORDED (shape-based success),
# so the next same-turn edit of that file is SILENT.
# RED on the OLD track-read: it stringified the whole response and grepped it
# for 'Error:'/'not found' → misread the success object as a FAILED edit → did
# NOT record → the second guard call WARNS (not silent). GREEN on the fix.
# =============================================================================
@test "FIX-1: a success Edit OBJECT whose newString contains 'Error:'/'not found' is recorded → next edit silent" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/marker-edit.txt"; echo "x" > "$f"   # exists → not new-file exempt

  # A SUCCESSFUL Edit. The response is an OBJECT echoing the edited code; that
  # code legitimately contains the failure-marker words.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$f" \
    '{transcript_path: $tp, tool_name: "Edit", tool_input: {file_path: $t},
      tool_response: {
        filePath: $t,
        originalFile: "old line\nlog(\"Error: not found\");\n",
        structuredPatch: [{oldStart: 1, newStart: 1,
          lines: ["-old line", "+throw new Error(\"ENOENT: not found, does not match\")"]}],
        newString: "throw new Error(\"ENOENT: not found, does not match\")"
      }}')"
  [ "$status" -eq 0 ]
  # The success object MUST have been recorded despite the marker words in body.
  run grep -F -- "$f" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  # The next same-turn edit of f is now in the known-set → SILENT permit.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]      # no deny
  [ -z "$stderr" ]      # no warn
}

# =============================================================================
# FIX-1 corollary: an OBJECT response carrying an EXPLICIT error key is NOT
# recorded (an explicitly-failed edit must still escalate). Distinguishes the
# shape-based success path from a real object-shaped failure.
# =============================================================================
@test "FIX-1: a success-shaped OBJECT with .is_error=true is NOT recorded (explicit failure)" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/obj-err.txt"; echo "x" > "$f"

  # The error message contains NONE of the failure-marker substrings, so the
  # OLD whole-response-grep would NOT have skipped → it would WRONGLY RECORD.
  # The fix keys off the explicit .is_error/.error object keys instead. RED-GREEN.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$f" \
    '{transcript_path: $tp, tool_name: "Edit", tool_input: {file_path: $t},
      tool_response: {filePath: $t, is_error: true, error: "edit failed"}}')"
  [ "$status" -eq 0 ]
  # Explicit error key → NOT recorded.
  [ ! -f "$STATE_DIR/$KEY.reads.tsv" ] || ! grep -qF -- "$f" "$STATE_DIR/$KEY.reads.tsv"
}

# =============================================================================
# FIX-3 (DL-P5-09): MIXED NULLABILITY — stamp-turn gets a NULL transcript_path
# (session_id ONLY) while guard/track get a POPULATED transcript_path with the
# SAME session_id. Because session_id is PRIMARY in _se_state_key, all three
# key off it → the .epoch the guard reads is the one stamp-turn wrote.
# RED on the OLD hooks (transcript_path-PRIMARY): stamp-turn (tp null) keyed off
# session_id, the guard (tp populated) keyed off transcript_path → DIFFERENT
# KEYs → the guard read a never-written .epoch (turn_epoch=0) → the just-read
# file stayed IN_SET only by luck of the all-reads-this-turn fallback, but the
# stamp-turn boundary it should have honored was on a different key entirely.
# We assert the concrete artifact: stamp-turn's .epoch and the guard's lookup
# live under ONE key derived from session_id.
# =============================================================================
@test "FIX-3: mixed nullability — stamp-turn(tp=null,sid) and guard(tp set,sid) share one KEY (session_id primary)" {
  SID="sess-mixed-nullability-xyz"
  SKEY="$(printf '%s' "$SID" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"

  # stamp-turn with a NULL transcript_path but a session_id → keys off session_id.
  run_with_stderr "$STAMP" "$(jq -nc --arg sid "$SID" \
    '{transcript_path: null, session_id: $sid, stop_hook_active: false}')"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/$SKEY.epoch" ]          # written under the session_id-derived key
  stamped="$(cat "$STATE_DIR/$SKEY.epoch")"

  # Pin the boundary to an explicit integer so the read relationship is
  # deterministic, then record a read AFTER it under the SAME session_id key.
  printf '%s\n' "1000" > "$STATE_DIR/$SKEY.epoch"
  f="$PROJECT_DIR/mixed.txt"; echo "data" > "$f"
  printf '%s\t%s\n' "2000" "$f" >> "$STATE_DIR/$SKEY.reads.tsv"

  # Guard with a POPULATED transcript_path AND the SAME session_id. It MUST key
  # off session_id (primary) → read the .epoch stamp-turn wrote → IN_SET → silent.
  run_with_stderr "$GUARD" "$(jq -nc --arg tp "$TP" --arg sid "$SID" --arg t "$f" \
    '{transcript_path: $tp, session_id: $sid, tool_input: {file_path: $t}}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]      # silent permit — proves the guard read the SAME-KEY state
  [ -z "$stderr" ]
  # And the guard did NOT spawn a second (transcript_path-derived) key stem.
  tpkey="$(printf '%s' "$TP" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"
  [ ! -f "$STATE_DIR/$tpkey.warns.tsv" ]
  [ ! -f "$STATE_DIR/$tpkey.epoch" ]
}

# =============================================================================
# FIX-5 (DL-P5-10): a path containing a NEWLINE.
#   - track-read does NOT corrupt reads.tsv (skips the record, breadcrumb).
#   - reread-guard FAIL-OPENs (permit, no deny).
# RED on the OLD hooks: track-read appended a 2-physical-line "<epoch>\t<path>"
# row (the embedded newline split it), and reread-guard, having no newline
# guard, would also process the corrupt target. GREEN: both detect-and-bail.
# Newline detection MUST use a literal-newline var (not $(printf '\n')).
# =============================================================================
@test "FIX-5: a path with a NEWLINE → track-read skips (no corrupt tsv) and guard fail-opens" {
  set_turn_epoch 1000
  nl='
'
  # A path whose name embeds a newline. Create the file so the guard's
  # new-file-exempt branch does not pre-empt the newline check.
  bad="$PROJECT_DIR/evil${nl}injected.txt"
  printf 'old\n' > "$bad" 2>/dev/null || true

  # track-read: must SKIP the record — reads.tsv must NOT be created/corrupted.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$bad" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: "ok"}')"
  [ "$status" -eq 0 ]
  # No corrupt row: either the file does not exist, or it has zero data lines.
  if [ -f "$STATE_DIR/$KEY.reads.tsv" ]; then
    [ "$(wc -l < "$STATE_DIR/$KEY.reads.tsv" | tr -d ' ')" -eq 0 ]
  fi

  # reread-guard: a newline-bearing target cannot be matched → FAIL-OPEN permit.
  run_with_stderr "$GUARD" "$(jq -nc --arg tp "$TP" --arg t "$bad" \
    '{transcript_path: $tp, tool_input: {file_path: $t}}')"
  [ "$status" -eq 0 ]
  [[ "$output" != *deny* ]]        # never a block on an unmatchable path
}
