#!/usr/bin/env bats
# Forward-only high-autonomy decision receipt coverage for the deployed Codex wrapper.

load helpers

setup() {
  local deploy="$BATS_TEST_TMPDIR/deploy/.codex/hooks"
  mkdir -p "$deploy/lib"
  cp "$BATS_TEST_DIRNAME/../decision-receipt.sh" "$deploy/decision-receipt.sh"
  cp "$BATS_TEST_DIRNAME/../lib/deps.sh" "$deploy/lib/deps.sh"
  cp "$BATS_TEST_DIRNAME/../lib/autonomy.sh" "$deploy/lib/autonomy.sh"
  cp "$BATS_TEST_DIRNAME/../../../hooks/lib/decision-receipt-core.sh" "$deploy/lib/decision-receipt-core.sh"
  HOOK="$deploy/decision-receipt.sh"

  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" commit --allow-empty -q -m init
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR

  TODAY="$(date -u '+%Y-%m-%d')"
  VALID_ENTRY="- ${TODAY}T12:34:56Z [L4] [scope] Keep the validator forward-only. Reasoning: Legacy entries remain immutable. Alternatives considered: Rewriting history."
  printf '{"autonomy":4}\n' >"$PROJECT_DIR/.trellis.config.json"
  printf '# Decisions log\n\n%s\n' "$VALID_ENTRY" >"$PROJECT_DIR/decisions-log.md"
  git -C "$PROJECT_DIR" add .trellis.config.json decisions-log.md
  git -C "$PROJECT_DIR" commit -q -m fixture
}

make_dirty_code() {
  printf 'changed\n' >"$PROJECT_DIR/app.js"
}

message_with_entry() {
  printf 'Done.\n\n## Decisions made (L%s)\n\n%s\n\n## Follow-ups\n\nNone.\n' "$1" "$2"
}

make_envelope() {
  local message="$1" transcript="${2:-}" active="${3:-false}"
  jq -nc --arg message "$message" --arg transcript "$transcript" --argjson active "$active" \
    '{hook_event_name:"Stop", stop_hook_active:$active, last_assistant_message:$message, transcript_path:(if ($transcript | length) > 0 then $transcript else null end)}'
}

write_transcript() {
  local message="$1" prior="${2:-old turn}" path="$BATS_TEST_TMPDIR/transcript.jsonl"
  jq -nc --arg content "$prior" '{type:"response_item",payload:{type:"message",role:"assistant",content:[{type:"output_text",text:$content}]}}' >"$path"
  jq -nc --arg content "current request" '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:$content}]}}' >>"$path"
  jq -nc --arg content "$message" '{type:"response_item",payload:{type:"message",role:"assistant",content:[{type:"output_text",text:$content}]}}' >>"$path"
  printf '%s' "$path"
}

run_preserving_log() {
  local envelope="$1" before after
  before="$(shasum -a 256 "$PROJECT_DIR/decisions-log.md" | cut -d' ' -f1)"
  run bash "$HOOK" <<<"$envelope"
  after="$(shasum -a 256 "$PROJECT_DIR/decisions-log.md" | cut -d' ' -f1)"
  [ "$after" = "$before" ]
}

assert_block() {
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e '.decision == "block" and (.reason | startswith("decision-receipt:"))' >/dev/null
}

@test "valid current L4 receipt passes without changing the log" {
  make_dirty_code
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$VALID_ENTRY")")"
  [ "$status" -eq 0 ]
}

@test "malformed receipt blocks without changing the log" {
  make_dirty_code
  local malformed="- ${TODAY}T12:34:56Z [L4] [scope] Missing required clauses."
  printf '\n%s\n' "$malformed" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$malformed")")"
  assert_block
  [[ "$output" == *"malformed decision entry"* ]]
}

@test "blank decision clauses are rejected without changing the log" {
  make_dirty_code
  local blank entries=(
    "- ${TODAY}T12:35:00Z [L4] [scope]   . Reasoning: Filled. Alternatives considered: Filled."
    "- ${TODAY}T12:35:01Z [L4] [scope] Filled. Reasoning:   . Alternatives considered: Filled."
    "- ${TODAY}T12:35:02Z [L4] [scope] Filled. Reasoning: Filled. Alternatives considered:   ."
  )
  for blank in "${entries[@]}"; do
    printf '\n%s\n' "$blank" >>"$PROJECT_DIR/decisions-log.md"
    run_preserving_log "$(make_envelope "$(message_with_entry 4 "$blank")")"
    assert_block
    [[ "$output" == *"malformed decision entry"* ]] || { echo "$output"; false; }
  done
}

@test "missing decision block blocks without changing the log" {
  make_dirty_code
  run_preserving_log "$(make_envelope "Done without a decision block.")"
  assert_block
  [[ "$output" == *"requires exactly one"* ]]
}

@test "receipt absent from canonical log blocks without changing the log" {
  make_dirty_code
  local missing="- ${TODAY}T13:00:00Z [L4] [pattern] Keep one parser. Reasoning: Duplicate parsers drift. Alternatives considered: Harness-specific parsing."
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$missing")")"
  assert_block
  [[ "$output" == *"absent from canonical-root decisions-log.md"* ]]
}

@test "L1-L3 substantive turn passes without a decision block" {
  printf '{"autonomy":3}\n' >"$PROJECT_DIR/.trellis.config.json"
  make_dirty_code
  run_preserving_log "$(make_envelope "No high-autonomy block required.")"
  [ "$status" -eq 0 ]
}

@test "cross-level block is rejected" {
  make_dirty_code
  local cross="- ${TODAY}T13:00:00Z [L5] [scope] Use the wrong level. Reasoning: Fixture exercises level checks. Alternatives considered: Matching L4."
  printf '\n%s\n' "$cross" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 5 "$cross")")"
  assert_block
  [[ "$output" == *"does not match resolved L4"* ]]
}

@test "stale-date receipt is rejected" {
  make_dirty_code
  local stale="- 2000-01-01T13:00:00Z [L4] [scope] Reuse an old receipt. Reasoning: Fixture exercises freshness. Alternatives considered: Current UTC date."
  printf '\n%s\n' "$stale" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$stale")")"
  assert_block
  [[ "$output" == *"malformed decision entry"* ]]
}

@test "transcript supplies the current receipt when final message is absent" {
  make_dirty_code
  local transcript
  transcript="$(write_transcript "$(message_with_entry 4 "$VALID_ENTRY")")"
  run_preserving_log "$(make_envelope "" "$transcript")"
  [ "$status" -eq 0 ]
}

@test "prior-turn receipt does not satisfy a receiptless current transcript turn" {
  make_dirty_code
  local transcript
  transcript="$(write_transcript "Current answer without a decision block." "$(message_with_entry 4 "$VALID_ENTRY")")"
  run_preserving_log "$(make_envelope "" "$transcript")"
  assert_block
  [[ "$output" == *"requires exactly one"* ]]
}

@test "prior conflicting block does not contaminate a valid current transcript turn" {
  make_dirty_code
  local prior transcript
  prior="$(message_with_entry 5 "- ${TODAY}T11:00:00Z [L5] [scope] Conflict with the current level. Reasoning: Exercise turn scoping. Alternatives considered: L4.")"
  transcript="$(write_transcript "$(message_with_entry 4 "$VALID_ENTRY")" "$prior")"
  run_preserving_log "$(make_envelope "" "$transcript")"
  [ "$status" -eq 0 ]
}

@test "architectural receipt requires SURFACED INLINE" {
  make_dirty_code
  local architectural="- ${TODAY}T14:00:00Z [L4] [architectural] Keep the dedicated Stop boundary. Reasoning: Ordering is load-bearing. Alternatives considered: Folding into stop-verify."
  printf '\n%s\n' "$architectural" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$architectural")")"
  assert_block
  [[ "$output" == *"missing SURFACED INLINE"* ]]
}

@test "continuation short-circuits before validation" {
  make_dirty_code
  run_preserving_log "$(make_envelope "" "" true)"
  [ "$status" -eq 0 ]
}

@test "clean worktree with a current DoD marker is substantive" {
  local message
  message="$(message_with_entry 4 "$VALID_ENTRY")"
  message="${message}\n<!-- dod-receipt cmd=\"bats decision-receipt.bats\" exit=0 diff=\"+1/-0 (1 files)\" -->"
  run_preserving_log "$(make_envelope "$message")"
  [ "$status" -eq 0 ]
}

@test "clean read-only turn skips decision validation" {
  run_preserving_log "$(make_envelope "Read-only answer.")"
  [ "$status" -eq 0 ]
}

@test "clean turn with a DoD marker blocks when the decision block is missing" {
  local message='Done. <!-- dod-receipt cmd="bats decision-receipt.bats" exit=0 diff="+1/-0 (1 files)" -->'
  run_preserving_log "$(make_envelope "$message")"
  assert_block
  [[ "$output" == *"requires exactly one"* ]]
}
