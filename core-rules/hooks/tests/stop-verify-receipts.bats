#!/usr/bin/env bats
# Tests for stop-verify.sh — Phase 2a RECEIPTS gate (Step 5, structural
# done-detection). The gate is reached only on a DIRTY tree (clean-tree pure-chat
# turns exit 0 earlier), with no open todos and all configured checks passing.
#
# PORTABLE: no absolute machine paths (mirror-clean for the public template).
# PROJECT_DIR is a fresh git repo per test (helpers.setup_project_dir). Transcript
# fixtures live UNDER BATS_TEST_TMPDIR — never inside PROJECT_DIR — so they never
# enter the hook's changed-file set. The only changed file in each dirty turn is a
# genuine non-doc file (app.js), which trips the receipts gate (.txt would be
# treated as a doc and SKIP the gate — see make_dirty_code below).

load helpers

HOOK="$HOOKS_DIR/stop-verify.sh"

setup() {
  setup_project_dir
}

teardown() {
  teardown_project_dir
}

# Ensure no open todos so the Step-1 TodoWrite gate never fires first (it would
# block at step "TodoWrite", masking the receipts behaviour under test). A fresh
# PROJECT_DIR has no todos.json at all; this makes that explicit + defensive.
seed_todos_none() {
  rm -f "$PROJECT_DIR/.claude/todos.json"
}

# Dirty the tree with a genuine NON-DOC file. The receipts gate's doc-only skip
# filters .md/.mdx/.rst/.txt; a .js file keeps NONDOC_COUNT>0 so the gate runs.
make_dirty_code() {
  echo "function add(a, b){ return a + b }" > "$PROJECT_DIR/app.js"
}

# Dirty the tree with ONLY doc files → receipts gate's doc-only skip applies.
make_dirty_docs() {
  echo "# notes" > "$PROJECT_DIR/NOTES.md"
}

# Build a Stop-hook envelope JSON carrying transcript_path = $1 (omit arg → no
# transcript_path key at all). Uses jq so paths are escaped correctly.
make_envelope() {
  if [ "$#" -ge 1 ]; then
    jq -nc --arg t "$1" '{transcript_path: $t}'
  else
    printf '%s' '{}'
  fi
}

# Write a transcript JSONL that ends with a CURRENT-turn receipt: a user line
# followed by an assistant line carrying a valid <!-- dod-receipt ... --> marker.
# Lives outside PROJECT_DIR so it is never seen as a changed file.
write_transcript_current_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"node -e 'require(\\\"./app.js\\\")'\" exit=0 diff=\"+1/-0 (1 files)\" -->"}}
EOF
}

# Transcript with a done-claim assistant line but NO receipt marker anywhere.
write_transcript_no_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"All done — the change is complete."}}
EOF
}

# Transcript with a VALID receipt that predates the last user message, and NO
# receipt after it. The stale prior-turn receipt must NOT satisfy this turn.
write_transcript_stale_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"first task"}}
{"type":"assistant","message":{"role":"assistant","content":"Prior turn done. <!-- dod-receipt cmd=\"npm test\" exit=0 diff=\"+3/-0 (1 files)\" -->"}}
{"type":"user","message":{"role":"user","content":"now do a second change"}}
{"type":"assistant","message":{"role":"assistant","content":"Made the second change."}}
EOF
}

# =========================================================================
# Receipt present THIS turn on a dirty non-doc tree → pass (exit 0).
# =========================================================================
@test "receipts: current-turn receipt on dirty non-doc tree → pass (0)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_current_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Done-claim WITHOUT a receipt on a dirty non-doc tree → block (exit 2),
# step "receipts".
# =========================================================================
@test "receipts: done-claim without receipt on dirty non-doc tree → block (2, receipts)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
}

# =========================================================================
# STALE receipt (LOAD-BEARING): a valid receipt BEFORE the last user message,
# none after → must BLOCK. The prior-turn receipt must not satisfy this turn.
# =========================================================================
@test "receipts: stale prior-turn receipt does NOT satisfy this turn → block (2, receipts)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_stale_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
}

# =========================================================================
# Conversational: clean tree → exit 0 (pure-chat skip; never reaches receipts).
# A receipt-less transcript is supplied to prove the clean-tree skip wins.
# =========================================================================
@test "receipts: clean tree → pass (0), never reaches receipts gate" {
  seed_todos_none
  # No dirty file written → worktree matches HEAD.
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Doc-only: only .md files changed → doc-only skip → exit 0 even without a
# receipt and with a done-claim transcript.
# =========================================================================
@test "receipts: doc-only change (.md) → skip gate → pass (0)" {
  seed_todos_none
  make_dirty_docs
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Missing transcript: dirty non-doc tree, no transcript_path in the envelope →
# receipt is unverifiable → advisory PASS (exit 0, additionalContext).
# =========================================================================
@test "receipts: no transcript_path → advisory-pass (0, additionalContext)" {
  seed_todos_none
  make_dirty_code

  run bash "$HOOK" <<<"$(make_envelope)"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("additionalContext")' >/dev/null
}

# =========================================================================
# Opt-out: PROCESS_GATE_NO_RECEIPTS=1 → receipts gate skipped → exit 0 on a
# dirty non-doc tree even with a receipt-less, done-claim transcript.
# =========================================================================
@test "receipts: PROCESS_GATE_NO_RECEIPTS=1 → skip gate → pass (0)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  PROCESS_GATE_NO_RECEIPTS=1 run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
}

# --- Follow-ups marker fixtures (spec 012) -------------------------------------

# Current-turn receipt AND a follow-ups count marker on the assistant line.
write_transcript_receipt_and_followups() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"node -e 'require(\\\"./app.js\\\")'\" exit=0 diff=\"+1/-0 (1 files)\" --> <!-- follow-ups: 2 -->"}}
EOF
}

# Current-turn receipt AND an explicit `none` follow-ups marker.
write_transcript_receipt_and_followups_none() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"node -e 'require(\\\"./app.js\\\")'\" exit=0 diff=\"+1/-0 (1 files)\" --> <!-- follow-ups: none -->"}}
EOF
}

# A follow-ups marker (with a valid receipt) BEFORE the last user line; after
# it, a fresh valid receipt with NO marker. The stale prior-turn marker must
# NOT satisfy this turn — the warn should fire.
write_transcript_stale_followups() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"first task"}}
{"type":"assistant","message":{"role":"assistant","content":"Prior turn done. <!-- dod-receipt cmd=\"npm test\" exit=0 diff=\"+3/-0 (1 files)\" --> <!-- follow-ups: 1 -->"}}
{"type":"user","message":{"role":"user","content":"now do a second change"}}
{"type":"assistant","message":{"role":"assistant","content":"Second change done. <!-- dod-receipt cmd=\"npm test\" exit=0 diff=\"+2/-1 (1 files)\" -->"}}
EOF
}

# ONLY a follow-ups marker + a done-claim — no dod-receipt anywhere. Must still
# BLOCK: the follow-ups marker cannot satisfy dod-receipt parsing (spec 012 §4
# collision constraint, direction 2).
write_transcript_followups_no_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"All done — the change is complete. <!-- follow-ups: 2 -->"}}
EOF
}

# =========================================================================
# Follow-ups (spec 012): receipt + count marker → silent clean pass (0, no
# output at all).
# =========================================================================
@test "follow-ups: receipt + count marker → silent pass (0)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_receipt_and_followups "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =========================================================================
# Follow-ups (spec 012): receipt + explicit `none` marker → silent clean pass
# (SC2 clause 2: explicit none passes clean).
# =========================================================================
@test "follow-ups: receipt + none marker → silent pass (0)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_receipt_and_followups_none "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =========================================================================
# Follow-ups (spec 012): receipt WITHOUT a marker → NON-BLOCKING warn (SC2
# clause 3): exit 0, additionalContext, no decision key. Anti-template
# assertion: the rendered warn text itself must NOT satisfy the detection ERE
# (its `<count-or-none>` placeholder is deliberately unfilled), so the warn
# can never self-satisfy a future scan.
# =========================================================================
@test "follow-ups: receipt without marker → warn (0, additionalContext, no block)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_current_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("additionalContext")' >/dev/null
  printf '%s' "$output" | jq -e 'has("decision") | not' >/dev/null
  printf '%s' "$output" | jq -r '.additionalContext' | grep -q 'follow-ups'
  # Anti-template: rendered warn must not match the detection regex.
  ! printf '%s' "$output" | jq -r '.additionalContext' \
    | grep -Eq '<!-- follow-ups: (none|[0-9]+) -->'
}

# =========================================================================
# Follow-ups (spec 012, turn-scoping load-bearing): a stale prior-turn marker
# + a fresh current-turn receipt with no marker → the warn still fires.
# =========================================================================
@test "follow-ups: stale prior-turn marker does NOT satisfy this turn → warn fires" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_stale_followups "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("additionalContext")' >/dev/null
  printf '%s' "$output" | jq -e 'has("decision") | not' >/dev/null
}

# =========================================================================
# Follow-ups (spec 012, collision direction 2): a follow-ups marker WITHOUT a
# dod-receipt must still BLOCK — the new marker cannot satisfy dod-receipt
# parsing.
# =========================================================================
@test "follow-ups: marker without receipt → still block (2, receipts)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_followups_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
}

# F1 regression (012 Codex review): a receipt QUOTING the follow-ups marker
# inside its cmd="…" must NOT satisfy the marker scan — dod-receipt spans are
# stripped (perl non-greedy) before the FOLLOWUPS_RE grep.
write_transcript_receipt_quoting_marker() {
  local path="$1"
  cat > "$path" <<'INNER'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"grep -F '<!-- follow-ups: 1 -->' notes.md\" exit=0 diff=\"+1/-0 (1 files)\" -->"}}
INNER
}

@test "follow-ups: receipt quoting marker inside cmd → warn still fires (F1)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_receipt_quoting_marker "$tx"

  run bash "$HOOK" <<<"$(make_envelope "$tx")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("additionalContext")' >/dev/null
  printf '%s' "$output" | jq -e 'has("decision") | not' >/dev/null
}
