#!/usr/bin/env bats
# Tests for the CODEX stop-verify.sh — Phase 2b FAIL-COUNTER (emit_block
# consecutive-block escalation), ported from the Claude suite fail-counter.bats.
# emit_block hashes the changed FILE SET via _se_changed_files (diff-vs-HEAD
# UNION untracked, self-filtering .codex/.fail-counter) → cksum of sorted paths
# (POSIX-portable, no sha256sum) → counts consecutive blocks against the SAME
# set. On the second+ block of an unchanged set it appends:
#   "STOP: re-read top-down, ... (same files failed N times)."
# A different file set resets the count to 1. A receipt-pass removes the
# .codex/.fail-counter state file.
#
# GIT-DERIVED, NOT PAYLOAD-DERIVED (Codex-specific, load-bearing): the counter
# keys ONLY off the git changed-file set. The NullableString payload fields
# (last_assistant_message / transcript_path) NEVER feed it. The
# payload-invariance test below proves this: two blocks on the SAME {app.js} set
# with DIFFERENT payload content still escalate on the 2nd.
#
# ANTI-STUB: setup_deployed_hook runs the REAL stop-verify.sh + REAL deps.sh +
# REAL pm.sh from a deployed <tmp>/.codex/hooks layout; CODEX_PROJECT_DIR is a
# SEPARATE git repo so the deployment never enters the changed-file set, and
# transcript fixtures live under $BATS_TEST_TMPDIR (outside the project). The
# hook self-filters .codex/.fail-counter, so the only set member is the code
# file(s) we write — keeping the hash stable across consecutive blocking runs.

load helpers

STATE_REL=".codex/.fail-counter"
ESCALATION="STOP: re-read top-down"

setup() {
  setup_deployed_hook
}

seed_todos_none() {
  rm -f "$PROJECT_DIR/.codex/todos.json" "$PROJECT_DIR/.claude/todos.json"
}

# Build a Codex Stop envelope with NullableString fields:
#   $1 = last_assistant_message (NULL token → JSON null)
#   $2 = transcript_path        (NULL token → JSON null)
make_envelope() {
  local lam="${1:-NULL}" tx="${2:-NULL}"
  local lam_json tx_json
  if [ "$lam" = "NULL" ]; then lam_json='null'; else lam_json="$(jq -nc --arg v "$lam" '$v')"; fi
  if [ "$tx"  = "NULL" ]; then tx_json='null';  else tx_json="$(jq -nc --arg v "$tx" '$v')"; fi
  jq -nc \
    --argjson lam "$lam_json" \
    --argjson tx "$tx_json" \
    --arg cwd "$PROJECT_DIR" \
    '{
      cwd: $cwd,
      hook_event_name: "Stop",
      last_assistant_message: $lam,
      model: "codex-test",
      permission_mode: "default",
      session_id: "sess-1",
      stop_hook_active: false,
      transcript_path: $tx,
      turn_id: "turn-1"
    }'
}

# A done-claim transcript with NO receipt → drives the receipts gate to block.
write_transcript_no_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"All done — the change is complete."}}
EOF
}

# A transcript with a CURRENT-turn receipt → receipts gate passes (rm STATE_FILE).
write_transcript_current_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"node app.js\" exit=0 diff=\"+1/-0 (1 files)\" -->"}}
EOF
}

# Prepend a temp dir with an `npx` stub that always fails → the hook's
# `npx --no-install tsc --noEmit` typecheck step blocks. Echoes the dir so the
# caller can clean it up. The hook never calls `tsc` directly, only via `npx`.
# (This is the ONE legitimate stub — of an external toolchain, NOT the core.)
make_failing_npx_dir() {
  local dir
  dir="$(mktemp -d "$BATS_TMPDIR/npxstub.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "error TS1005: synthetic typecheck failure" >&2'
    printf '%s\n' 'exit 1'
  } > "$dir/npx"
  chmod +x "$dir/npx"
  printf '%s' "$dir"
}

# =========================================================================
# Same-file-set: two consecutive RECEIPTS blocks on the same {app.js} set →
# the SECOND block reason carries the escalation; the FIRST does not.
# =========================================================================
@test "fail-counter: same file set → 2nd consecutive receipts block escalates" {
  seed_todos_none
  echo "function add(a,b){return a+b}" > "$PROJECT_DIR/app.js"
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$ESCALATION"* ]]
}

# =========================================================================
# PAYLOAD-INVARIANCE (Codex-specific, load-bearing): two consecutive blocks on
# the SAME {app.js} set but with DIFFERENT last_assistant_message AND DIFFERENT
# transcript content → the 2nd STILL escalates. Proves the counter is keyed off
# the git changed-file set, NOT the NullableString payload.
# =========================================================================
@test "fail-counter: counter is git-derived — differing payload still escalates on 2nd" {
  seed_todos_none
  echo "function add(a,b){return a+b}" > "$PROJECT_DIR/app.js"
  local tx1="$BATS_TEST_TMPDIR/t1.jsonl"
  local tx2="$BATS_TEST_TMPDIR/t2.jsonl"
  write_transcript_no_receipt "$tx1"
  # A different receipt-less transcript (distinct user prompt, same outcome).
  cat > "$tx2" <<'EOF'
{"type":"user","message":{"role":"user","content":"a completely different request"}}
{"type":"assistant","message":{"role":"assistant","content":"Wrapped up, all good here."}}
EOF

  # Block 1: one payload.
  run bash "$HOOK" <<<"$(make_envelope "All done — the change is complete." "$tx1")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]

  # Block 2: DIFFERENT last_assistant_message + DIFFERENT transcript, SAME files.
  run bash "$HOOK" <<<"$(make_envelope "Wrapped up, all good here." "$tx2")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$ESCALATION"* ]]
}

# =========================================================================
# Different file set: block on set A {app.js}, then block on set B
# {app.js, other.js} → B's count resets to 1 → NO escalation on B.
# =========================================================================
@test "fail-counter: different file set resets count → no escalation" {
  seed_todos_none
  echo "function add(a,b){return a+b}" > "$PROJECT_DIR/app.js"
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]

  # Change the file SET (add a second non-doc file).
  echo "function sub(a,b){return a-b}" > "$PROJECT_DIR/other.js"

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]
}

# =========================================================================
# Pass resets: a receipts block, then a clean PASS (receipt supplied this turn
# on the SAME dirty set) → the .codex/.fail-counter STATE file is removed.
# (Clean-tree exit does NOT rm the state file by design; the resolving signal is
# the receipts gate passing — the line that rm's STATE_FILE on receipt-found.)
# =========================================================================
@test "fail-counter: a block then a receipt-pass removes the state file" {
  seed_todos_none
  echo "function add(a,b){return a+b}" > "$PROJECT_DIR/app.js"
  local tx_block="$BATS_TEST_TMPDIR/block.jsonl"
  local tx_pass="$BATS_TEST_TMPDIR/pass.jsonl"
  write_transcript_no_receipt "$tx_block"
  write_transcript_current_receipt "$tx_pass"

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx_block")"
  [ "$status" -eq 2 ]
  [ -f "$PROJECT_DIR/$STATE_REL" ]

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx_pass")"
  [ "$status" -eq 0 ]
  [ ! -f "$PROJECT_DIR/$STATE_REL" ]
}

# =========================================================================
# Fires on repeated TYPECHECK failure too (not only receipts): tsconfig.json +
# a .ts file at PROJECT_DIR root, with a stubbed `npx` that always fails. Two
# consecutive same-file-set blocks → escalation injected on the second. The
# typecheck step blocks at Step 2 (before receipts), so no transcript needed.
# =========================================================================
@test "fail-counter: repeated typecheck failure on same set escalates on 2nd" {
  seed_todos_none
  echo '{"compilerOptions":{"noEmit":true}}' > "$PROJECT_DIR/tsconfig.json"
  echo 'export const x: number = "nope"' > "$PROJECT_DIR/index.ts"

  local npxdir
  npxdir="$(make_failing_npx_dir)"
  PATH_BACKUP="$PATH"; export PATH="$npxdir:$PATH"

  run bash "$HOOK" <<<"$(make_envelope)"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.reason | startswith("typecheck (tsc):")' >/dev/null
  [[ "$output" != *"$ESCALATION"* ]]

  run bash "$HOOK" <<<"$(make_envelope)"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.reason | startswith("typecheck (tsc):")' >/dev/null
  [[ "$output" == *"$ESCALATION"* ]]

  export PATH="$PATH_BACKUP"; rm -rf "$npxdir"
}
