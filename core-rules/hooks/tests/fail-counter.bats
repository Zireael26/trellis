#!/usr/bin/env bats
# Tests for stop-verify.sh — Phase 2a FAIL-COUNTER (emit_block consecutive-block
# escalation). emit_block hashes the changed FILE SET (cksum of sorted paths,
# POSIX-portable) and counts consecutive blocks against the SAME set. On the
# second+ block of an unchanged set it appends:
#   "STOP: re-read top-down, ... (same files failed N times)."
# A different file set resets the count to 1. A non-blocking pass removes the
# .claude/.fail-counter state file.
#
# PORTABLE: no absolute machine paths (mirror-clean for the public template).
# Fresh git PROJECT_DIR per test. Transcript fixtures live under BATS_TEST_TMPDIR
# (outside PROJECT_DIR) so they never enter the changed-file set; the hook also
# self-filters .claude/.fail-counter, so the only set member is the code file(s)
# we write — keeping the hash stable across the two consecutive blocking runs.

load helpers

HOOK="$HOOKS_DIR/stop-verify.sh"
STATE_REL=".claude/.fail-counter"
ESCALATION="STOP: re-read top-down"

setup() {
  setup_project_dir
}

teardown() {
  teardown_project_dir
}

seed_todos_none() {
  rm -f "$PROJECT_DIR/.claude/todos.json"
}

make_envelope() {
  if [ "$#" -ge 1 ]; then
    jq -nc --arg t "$1" '{transcript_path: $t}'
  else
    printf '%s' '{}'
  fi
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

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
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

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]

  # Change the file SET (add a second non-doc file).
  echo "function sub(a,b){return a-b}" > "$PROJECT_DIR/other.js"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$ESCALATION"* ]]
}

# =========================================================================
# Pass resets: a receipts block, then a clean PASS (receipt supplied this turn
# on the SAME dirty set) → the .fail-counter STATE file is removed.
# (Clean-tree exit does NOT rm the state file by design; the resolving signal is
# the receipts gate passing — line that rm's STATE_FILE on receipt-found.)
# =========================================================================
@test "fail-counter: a block then a receipt-pass removes the state file" {
  seed_todos_none
  echo "function add(a,b){return a+b}" > "$PROJECT_DIR/app.js"
  local tx_block="$BATS_TEST_TMPDIR/block.jsonl"
  local tx_pass="$BATS_TEST_TMPDIR/pass.jsonl"
  write_transcript_no_receipt "$tx_block"
  write_transcript_current_receipt "$tx_pass"

  run bash "$HOOK" <<<"$(make_envelope "$tx_block")"
  [ "$status" -eq 2 ]
  [ -f "$PROJECT_DIR/$STATE_REL" ]

  run bash "$HOOK" <<<"$(make_envelope "$tx_pass")"
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
