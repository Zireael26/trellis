#!/usr/bin/env bats
# Tests for the Phase 5b E2 re-read-before-edit guard (CODEX side):
#   reread-guard.sh (PreToolUse Edit|MultiEdit|Write — warn→block at all levels)
#   track-read.sh   (PostToolUse recorder — owns reads.tsv)
#   stamp-turn.sh   (Stop hook — sole writer of .epoch)
#
# This suite is the anti-self-block guard the design omits: an UNTESTED Codex
# mirror is exactly how the past Codex self-block slipped through. It exercises
# the REAL Codex hooks in place (they source the present sibling lib/deps.sh),
# mirrors the Claude reread-guard.bats cases, and ADDS Codex-only relative-path
# cases (the (c) mirror delta) that the Claude suite cannot cover.
#
# Codex BLOCK convention (the (b) delta — asserted on BOTH channels):
#   BLOCK       = exit status 2 AND stdout contains "decision":"block".
#   WARN/PERMIT = exit status 0 AND stdout EMPTY.
# A warn is distinguished from a permit by the STDERR advisory + a warns.tsv row.
#
# Epoch discipline: NEVER drive these tests off wall-clock comparisons. date +%s
# can return the same second twice, so a freshly-recorded read could land at
# read_epoch == turn_epoch and stay IN-set by the >= rule. We pre-write state
# with EXPLICIT integer epochs (turn boundary 1000; reads at 2000) so the
# known-set relationships are deterministic. A single fixed transcript_path is
# used in every envelope so KEY is constant across guard/track/stamp.
#
# PORTABLE / MIRROR-CLEAN: NO absolute machine paths. The hooks resolve from
# $BATS_TEST_DIRNAME; the project dir, fixtures and state live under mktemp.

# Resolve the canonical Codex hooks dir from this test file's location.
HOOKS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
GUARD="$HOOKS_DIR/reread-guard.sh"
TRACK="$HOOKS_DIR/track-read.sh"
STAMP="$HOOKS_DIR/stamp-turn.sh"

# A stable transcript path → a stable KEY across all envelopes / all hooks.
TP="/tmp/reread-guard-codex-bats-transcript.jsonl"

# Run a hook with given stdin; sets: status (rc), output (stdout), stderr.
# `set +e` is required because the BLOCK path exits 2 and bats would otherwise
# abort the test before the assertions run.
run_with_stderr() {
  local script="$1" input="$2"
  local stderr_file
  stderr_file="$(mktemp)"
  set +e
  output="$(printf '%s' "$input" | bash "$script" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}

setup() {
  # Real project root with a git repo so _se_repo_root resolves cleanly.
  PROJECT_DIR="$(mktemp -d)"
  ( cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -q -m init )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  # Defensive: a stray Claude precedence in the env would point _se_project_dir
  # at the wrong root and break the relative-path cases.
  unset CLAUDE_PROJECT_DIR
  STATE_DIR="$PROJECT_DIR/.codex/.reread-state"
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

# Run the guard for an existing/new target $1; sets status/output/stderr.
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
@test "known-after-Read: existing file Read this turn → silent permit (exit 0, empty stdout)" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/known.txt"; echo "data" > "$f"
  record_read 2000 "$f"          # read AFTER the turn boundary → IN_SET
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]               # no block JSON
  [ -z "$stderr" ]               # no warning
}

# =============================================================================
# stale unread existing file warns then BLOCKS after the budget
# (drive past budget by repeated guard calls with NO intervening record)
# =============================================================================
@test "stale-existing: L3 budget 2 → warn, warn, then BLOCK (decision+exit 2; never an immediate block)" {
  set_turn_epoch 1000           # no reads recorded → T is stale
  f="$PROJECT_DIR/stale.txt"; echo "old" > "$f"

  # Call 1 — WARN: exit 0, empty stdout, advisory on stderr.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]               # NEVER an immediate block
  [[ "$stderr" == *"warn 1/2"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 1 ]

  # Call 2 — WARN, still not a block.
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warn 2/2"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 2 ]

  # Call 3 — budget exhausted → BLOCK: exit 2, decision JSON, no further warn row.
  run_guard "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *"$f"* ]]
  [[ "$output" == *"TRELLIS_REREAD_OVERRIDE=1"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 2 ]   # block did not append a warn
}

# =============================================================================
# warn-then-block fires at L5 too (budget 1 → exactly one warn then block;
# NEVER an immediate block at any level)
# =============================================================================
@test "L5: budget 1 → exactly one warn, then BLOCK (no immediate block)" {
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy" 2>/dev/null || { mkdir -p "$PROJECT_DIR/.claude"; printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"; }
  set_turn_epoch 1000
  f="$PROJECT_DIR/l5.txt"; echo "old" > "$f"

  # Call 1 — single warn, NOT a block (the L5 warn is never skipped).
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warn 1/1"* ]]
  [ "$(warn_rows "$f" 1000)" -eq 1 ]

  # Call 2 — block.
  run_guard "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
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
# (the headline guarantee, end-to-end, NOT via hand-seeded reads.tsv).
# =============================================================================
@test "integration: Read → track-read → guard silent on the just-Read file" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/just-read.txt"; printf 'hello world\n' > "$f"

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

@test "integration: a Read whose CONTENT contains 'Error:'/'not found' is still recorded → guard silent" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/source-with-markers.txt"
  printf 'log("Error: not found"); // does not match anything real\n' > "$f"

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

  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$b" \
    '{transcript_path: $tp, tool_name: "Write", tool_input: {file_path: $t}, tool_response: {filePath: $t, success: true}}')"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/$KEY.reads.tsv" ]
  run grep -F -- "$b" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

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

  run_guard "$a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warn 1/"* ]]

  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$a" \
    '{transcript_path: $tp, tool_name: "Edit", tool_input: {file_path: $t}, tool_response: {filePath: $t, success: true}}')"
  [ "$status" -eq 0 ]

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

  run_guard "$f"
  [ -z "$output" ]
  [[ "$stderr" == *"warn 1/2"* ]]

  # The Edit FAILED (old_string mismatch). track-read must NOT record it.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$f" \
    '{transcript_path: $tp, tool_name: "Edit", tool_input: {file_path: $t}, tool_response: "Error: String to replace not found in file. The provided string does not match."}')"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_DIR/$KEY.reads.tsv" ] || ! grep -qF -- "$f" "$STATE_DIR/$KEY.reads.tsv"

  run_guard "$f"
  [ -z "$output" ]
  [[ "$stderr" == *"warn 2/2"* ]]

  run_guard "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
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
  [ -z "$output" ]               # permitted, no block JSON
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
  chmod 000 "$PROJECT_DIR/.codex"   # state dir becomes unreadable/unwritable
  i=0
  while [ "$i" -lt 5 ]; do
    run_guard "$f"
    [ "$status" -eq 0 ]            # never exit 2
    [ -z "$output" ]              # never a block
    i=$((i + 1))
  done
  chmod 755 "$PROJECT_DIR/.codex"
}

@test "fail-open: malformed stdin JSON → permit (no crash, no block)" {
  run_with_stderr "$GUARD" 'this is not json at all'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: empty target → permit" {
  run_with_stderr "$GUARD" "$(jq -nc --arg tp "$TP" '{transcript_path: $tp, tool_input: {}}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# FIX-2 (DL-P5-06): stamp-turn advances .epoch on EVERY Stop, INCLUDING
# stop_hook_active=true. This INVERTS the pre-remediation case, which asserted
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
  set_turn_epoch 1000
  f="$PROJECT_DIR/carry.txt"; echo "x" > "$f"
  record_read 2000 "$f"
  run_guard "$f"
  [ -z "$output" ]; [ -z "$stderr" ]              # IN_SET → silent

  run_with_stderr "$STAMP" "$(jq -nc --arg tp "$TP" \
    '{transcript_path: $tp, stop_hook_active: false}')"
  [ "$status" -eq 0 ]
  new_epoch="$(cat "$STATE_DIR/$KEY.epoch")"
  [ "$new_epoch" -gt 2000 ]                        # advanced past the prior read

  # Turn 2: the epoch=2000 read is now BELOW the boundary → OUT of the known-set
  # → editing the same file warns (stale).
  run_guard "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not Read this turn"* ]]
}

# =============================================================================
# The SAME KEY is derived across guard / track / stamp from the same stdin,
# and all three write under ROOT/.codex/.reread-state (the (a) delta).
# =============================================================================
@test "same-key: stamp-turn, track-read, and reread-guard all write under one KEY stem in .codex" {
  run_with_stderr "$STAMP" "$(jq -nc --arg tp "$TP" '{transcript_path: $tp, stop_hook_active: false}')"
  [ -f "$STATE_DIR/$KEY.epoch" ]

  g="$PROJECT_DIR/k.txt"; echo y > "$g"
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$g" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: "ok"}')"
  [ -f "$STATE_DIR/$KEY.reads.tsv" ]

  printf '%s\n' "9999999999" > "$STATE_DIR/$KEY.epoch"   # boundary in the far future
  h="$PROJECT_DIR/stalekey.txt"; echo z > "$h"
  run_guard "$h"
  [ -f "$STATE_DIR/$KEY.warns.tsv" ]

  stems="$(ls "$STATE_DIR" | sed 's/\.[^.]*$//; s/\.reads$//; s/\.warns$//' | sort -u)"
  [ "$(printf '%s\n' "$stems" | grep -c .)" -eq 1 ]
  [ "$stems" = "$KEY" ]
}

# =============================================================================
# CODEX-ONLY (c) DELTA: a RELATIVE file_path is resolved against the project dir
# in BOTH track-read and reread-guard, so a file recorded-relative is IN_SET for
# an edit issued-relative. A mismatch here is precisely the self-block class
# this mirror must never produce — the Claude suite cannot cover it (Claude
# always passes absolute paths).
# =============================================================================
@test "codex-relative: relative file_path recorded by track-read → guard silent on the same relative path" {
  set_turn_epoch 1000
  rel="rel-known.txt"
  printf 'body\n' > "$PROJECT_DIR/$rel"   # exists at the resolved absolute path

  # track-read records the relative path (resolved to absolute internally).
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "$rel" --arg body "body" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: $body}')"
  [ "$status" -eq 0 ]
  # Stored as the ABSOLUTE form (the (c) delta), not the bare relative string.
  run grep -F -- "$PROJECT_DIR/$rel" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  # Guard on the SAME relative path → resolves to the same absolute → IN_SET → silent.
  run_guard "$rel"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "codex-relative: a STALE relative path warns then BLOCKS (resolved consistently, no self-block escape)" {
  set_turn_epoch 1000
  rel="rel-stale.txt"
  printf 'old\n' > "$PROJECT_DIR/$rel"   # exists but never read this turn

  # Two warns (L3 budget 2) on the relative path...
  run_guard "$rel"
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warn 1/2"* ]]
  run_guard "$rel"
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warn 2/2"* ]]

  # ...then a real BLOCK (exit 2 + decision JSON naming the RESOLVED absolute path).
  run_guard "$rel"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *"$PROJECT_DIR/$rel"* ]]
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
  [ -z "$output" ]      # no block
  [ -z "$stderr" ]      # no warn
}

# =============================================================================
# FIX-1 corollary: an OBJECT response carrying an EXPLICIT error key is NOT
# recorded (an explicitly-failed edit must still escalate). Distinguishes the
# shape-based success path from a real object-shaped failure.
# RED on the OLD track-read: the stringified {"error":...,"is_error":true} carries
# NONE of the failure-marker substrings → the whole-response grep did NOT skip →
# it WRONGLY recorded. The fix keys off the explicit .is_error/.error object keys.
# =============================================================================
@test "FIX-1: a success-shaped OBJECT with .is_error=true is NOT recorded (explicit failure)" {
  set_turn_epoch 1000
  f="$PROJECT_DIR/obj-err.txt"; echo "x" > "$f"

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
# RED on the OLD hooks (transcript_path-PRIMARY inline blocks): stamp-turn (tp
# null) keyed off session_id, the guard (tp populated) keyed off transcript_path
# → DIFFERENT KEYs → the guard read a never-written .epoch under its own key.
# We assert the concrete artifact: stamp-turn's .epoch and the guard's lookup
# live under ONE key derived from session_id (under .codex — the (a) delta).
# =============================================================================
@test "FIX-3: mixed nullability — stamp-turn(tp=null,sid) and guard(tp set,sid) share one KEY (session_id primary)" {
  SID="sess-mixed-nullability-xyz"
  SKEY="$(printf '%s' "$SID" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"

  # stamp-turn with a NULL transcript_path but a session_id → keys off session_id.
  run_with_stderr "$STAMP" "$(jq -nc --arg sid "$SID" \
    '{transcript_path: null, session_id: $sid, stop_hook_active: false}')"
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/$SKEY.epoch" ]          # written under the session_id-derived key

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
# FIX-4 (DL-P5-10) CODEX-ONLY: a NON-CANONICAL store spelling must normalize to
# the SAME path the guard compares. track-read stores the weird spelling
# (./foo, a/../foo, foo/); the guard edits the plain canonical 'foo' that exists
# on disk. Both sides run _se_normpath → IN_SET hit → SILENT permit.
# RED on the OLD hooks: track-read stored the bare un-normalized concat
# (".../  ./foo" etc.) while the guard compared ".../foo" → IN_SET MISS → WARN.
# (NOTE: the non-canonical spelling is on the STORE side, not the guard side —
# the guard's new-file [-e] test runs on the un-normalized path in the OLD hook,
# so a non-canonical GUARD path would stat-miss → new-file-exempt → silent on
# OLD too, faking the red-green. Keeping it store-side is the real divergence.)
# =============================================================================
@test "FIX-4: './foo' stored by track-read ≡ 'foo' compared by guard → silent (normpath)" {
  set_turn_epoch 1000
  printf 'body\n' > "$PROJECT_DIR/dotslash.txt"   # the canonical file exists

  # track-read records the NON-CANONICAL './dotslash.txt' spelling.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "./dotslash.txt" --arg body "body" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: $body}')"
  [ "$status" -eq 0 ]
  # Stored as the NORMALIZED absolute form (no embedded "/./").
  run grep -F -- "$PROJECT_DIR/dotslash.txt" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  # Guard edits the plain canonical 'dotslash.txt' → normalizes to the same →
  # IN_SET → silent.
  run_guard "dotslash.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "FIX-4: 'a/../foo' stored by track-read ≡ 'foo' compared by guard → silent (normpath)" {
  set_turn_epoch 1000
  printf 'body\n' > "$PROJECT_DIR/dotdot.txt"   # the canonical file exists

  # track-read records the NON-CANONICAL 'a/../dotdot.txt' spelling (no real 'a' dir).
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "a/../dotdot.txt" --arg body "body" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: $body}')"
  [ "$status" -eq 0 ]
  run grep -F -- "$PROJECT_DIR/dotdot.txt" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  run_guard "dotdot.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "FIX-4: trailing-slash 'foo/' stored by track-read ≡ 'foo' compared by guard → silent (normpath)" {
  set_turn_epoch 1000
  printf 'body\n' > "$PROJECT_DIR/trail.txt"   # the canonical file exists

  # track-read records the NON-CANONICAL 'trail.txt/' (trailing slash) spelling.
  run_with_stderr "$TRACK" "$(jq -nc --arg tp "$TP" --arg t "trail.txt/" --arg body "body" \
    '{transcript_path: $tp, tool_name: "Read", tool_input: {file_path: $t}, tool_response: $body}')"
  [ "$status" -eq 0 ]
  run grep -F -- "$PROJECT_DIR/trail.txt" "$STATE_DIR/$KEY.reads.tsv"
  [ "$status" -eq 0 ]

  run_guard "trail.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# =============================================================================
# FIX-5 (DL-P5-10): a path containing a NEWLINE.
#   - track-read does NOT corrupt reads.tsv (skips the record, breadcrumb).
#   - reread-guard FAIL-OPENs (permit, no block).
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
  [ -z "$output" ]        # never a block on an unmatchable path
}
