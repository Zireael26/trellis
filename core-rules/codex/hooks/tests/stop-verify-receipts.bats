#!/usr/bin/env bats
# Tests for the CODEX stop-verify.sh — Phase 2b RECEIPTS gate (Step 5, structural
# done-detection), ported from the Claude suite stop-verify-receipts.bats and
# adapted to the Codex Stop payload + deployed-layout setup.
#
# The gate is reached only on a DIRTY tree (clean-tree pure-chat turns exit 0
# earlier), with no open todos and all configured checks passing. The Codex hook
# detects a receipt from a TWO-SOURCE UNION: (a) the Stop payload's
# last_assistant_message and (b) a turn-scoped parse of transcript_path. Both are
# NullableString (key always present, value may be null). A receipt in EITHER
# source passes; a done-claim with a receipt in NEITHER blocks; BOTH sources
# unavailable → advisory fail-open.
#
# ANTI-STUB: setup_deployed_hook deploys the REAL stop-verify.sh + REAL deps.sh +
# REAL pm.sh into <tmp>/.codex/hooks and runs the hook from there, so
# $HOOK_DIR/lib resolves to the real libs. CODEX_PROJECT_DIR is a SEPARATE git
# repo so the deployment never enters the hook's changed-file set. Transcript
# fixtures live under $BATS_TEST_TMPDIR (outside the project) for the same reason.

load helpers

setup() {
  setup_deployed_hook
}

# Ensure no open todos so the Step-1 TodoWrite gate never fires first (it would
# block at step "TodoWrite", masking the receipts behaviour under test). A fresh
# PROJECT_DIR has no todos.json; this makes that explicit + defensive (both the
# Codex .codex/ and the shared Claude .claude/ locations).
seed_todos_none() {
  rm -f "$PROJECT_DIR/.codex/todos.json" "$PROJECT_DIR/.claude/todos.json"
}

# Dirty the tree with a genuine NON-DOC file → NONDOC_COUNT>0, gate runs.
make_dirty_code() {
  echo "function add(a, b){ return a + b }" > "$PROJECT_DIR/app.js"
}

# Dirty the tree with ONLY doc files → receipts gate's doc-only skip applies.
make_dirty_docs() {
  echo "# notes" > "$PROJECT_DIR/NOTES.md"
}

# A valid CURRENT-turn receipt string (canonical filled marker). Anchored by the
# hook's tightened RECEIPT_RE: exit=<digit> and diff=...+<digit>.
RECEIPT_MARKER='<!-- dod-receipt cmd="node -e require(./app.js)" exit=0 diff="+1/-0 (1 files)" -->'

# Build a Codex Stop envelope. All schema keys are present (REQUIRED), with the
# two NullableString fields driven by args:
#   $1 = last_assistant_message  (use the literal token NULL → JSON null)
#   $2 = transcript_path         (use the literal token NULL → JSON null)
# Either may be omitted/NULL independently. jq escapes values correctly.
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

# --- Transcript fixtures (live outside PROJECT_DIR). ---------------------------

# Ends with a CURRENT-turn receipt: a user line then an assistant line carrying a
# valid <!-- dod-receipt ... --> marker after it.
write_transcript_current_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"node -e 'require(\\\"./app.js\\\")'\" exit=0 diff=\"+1/-0 (1 files)\" -->"}}
EOF
}

# A done-claim assistant line but NO receipt marker anywhere.
write_transcript_no_receipt() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"please implement add()"}}
{"type":"assistant","message":{"role":"assistant","content":"All done — the change is complete."}}
EOF
}

# A VALID receipt that predates the last user message, with NO receipt after it.
# The stale prior-turn receipt must NOT satisfy this turn.
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
# Source (a): receipt in last_assistant_message (transcript null) → pass (0).
# =========================================================================
@test "receipts: current-turn receipt in last_assistant_message → pass (0)" {
  seed_todos_none
  make_dirty_code

  run bash "$HOOK" <<<"$(make_envelope "Done. $RECEIPT_MARKER" NULL)"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Source (b): receipt in the turn-scoped transcript (last_assistant_message
# null) → pass (0).
# =========================================================================
@test "receipts: current-turn receipt in transcript → pass (0)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_current_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx")"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Done-claim with a receipt in NEITHER source → block (2, receipts).
# transcript present (so this is NOT the fail-open path) but receipt-less.
# =========================================================================
@test "receipts: done-claim, receipt in neither source → block (2, receipts)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "All done — the change is complete." "$tx")"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
}

# =========================================================================
# STALE receipt (LOAD-BEARING): a valid receipt BEFORE the last user message,
# none after → must BLOCK. The prior-turn receipt must not satisfy this turn.
# last_assistant_message is null so source (b)'s turn-scoping is what's tested.
# =========================================================================
@test "receipts: stale prior-turn receipt does NOT satisfy this turn → block (2, receipts)" {
  seed_todos_none
  make_dirty_code
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_stale_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope NULL "$tx")"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
}

# =========================================================================
# Clean tree → exit 0 (pure-chat skip; never reaches receipts). A receipt-less
# done-claim is supplied in both sources to prove the clean-tree skip wins.
# =========================================================================
@test "receipts: clean tree → pass (0), never reaches receipts gate" {
  seed_todos_none
  # No dirty file written → worktree matches HEAD.
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "All done." "$tx")"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Doc-only: only .md files changed → doc-only skip → exit 0 even with a
# receipt-less done-claim in both sources. (Pollution canary: if the deployed
# .codex tree leaked into the changed-file set, .sh files would make this BLOCK.)
# =========================================================================
@test "receipts: doc-only change (.md) → skip gate → pass (0)" {
  seed_todos_none
  make_dirty_docs
  local tx="$BATS_TEST_TMPDIR/transcript.jsonl"
  write_transcript_no_receipt "$tx"

  run bash "$HOOK" <<<"$(make_envelope "All done." "$tx")"
  [ "$status" -eq 0 ]
}

# =========================================================================
# Both sources null → receipt unverifiable → advisory PASS (0, systemMessage).
# This is the fail-open half: last_assistant_message null AND no transcript_path.
# =========================================================================
@test "receipts: both sources null → advisory-pass (0, systemMessage)" {
  seed_todos_none
  make_dirty_code

  run bash "$HOOK" <<<"$(make_envelope NULL NULL)"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("systemMessage")' >/dev/null
}

# =========================================================================
# Discriminator (other half of fail-open): a NON-NULL receipt-less
# last_assistant_message with a NULL transcript is a VERIFIABLE miss → BLOCK.
# Distinguishes "unverifiable → advisory" from "verifiably missing → block".
# =========================================================================
@test "receipts: non-null receiptless last_assistant_message + null transcript → block (2)" {
  seed_todos_none
  make_dirty_code

  run bash "$HOOK" <<<"$(make_envelope "All done — shipped it." NULL)"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
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

  PROCESS_GATE_NO_RECEIPTS=1 run bash "$HOOK" <<<"$(make_envelope "All done." "$tx")"
  [ "$status" -eq 0 ]
}
