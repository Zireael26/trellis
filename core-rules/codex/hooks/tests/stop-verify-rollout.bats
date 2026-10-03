#!/usr/bin/env bats
# Synthetic Codex 0.157.1 rollout SHAPES only; all fixture content is invented.
# The copied JSONL lives outside the dirty project. The Stop input supplies no
# last_assistant_message so only the transcript's last-user anchor can pass.

load helpers

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export GIT_AUTHOR_NAME='Synthetic Tester' GIT_AUTHOR_EMAIL='synthetic@example.invalid'
  export GIT_COMMITTER_NAME='Synthetic Tester' GIT_COMMITTER_EMAIL='synthetic@example.invalid'
  mkdir -p "$HOME"
  setup_deployed_hook
  printf 'invented code\n' > "$PROJECT_DIR/example.js"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/stop-verify-rollout-0157-synthetic.jsonl"
  TX="$BATS_TEST_TMPDIR/rollout.jsonl"
  cp "$FIXTURE" "$TX"
}

rewrite_fixture() {
  jq -c "$1" "$TX" > "$TX.tmp" && mv "$TX.tmp" "$TX"
}

stop_input() {
  jq -nc --arg cwd "$PROJECT_DIR" --arg tx "$TX" '{
    cwd: $cwd, hook_event_name: "Stop", last_assistant_message: null,
    model: "synthetic", permission_mode: "default", session_id: "synthetic",
    stop_hook_active: false, transcript_path: $tx, turn_id: "synthetic-turn-2"
  }'
}

assert_block_reason() {
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg prefix "$1" '
    type == "object" and (keys == ["decision", "reason"])
    and .decision == "block" and (.reason | type == "string" and startswith($prefix))
  ' >/dev/null
}

@test "rollout: non-message user role does not replace last user anchor" {
  jq -e 'select(.type == "response_item" and .payload.type == "function_call" and .payload.role == "user")' "$TX" >/dev/null
  run bash "$HOOK" <<<"$(stop_input)"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || printf '%s' "$output" | jq -e 'has("decision") | not' >/dev/null
}

@test "rollout: no receipt blocks as receipts, not transcript-unusable" {
  rewrite_fixture 'if .type == "response_item" and .payload.type == "message" and .payload.role == "assistant"
    then .payload.content = [{"type":"output_text","text":"Invented result without a receipt."}]
    else . end'
  run bash "$HOOK" <<<"$(stop_input)"
  assert_block_reason 'receipts:'
}

@test "rollout: receipt only before last user does not satisfy current turn" {
  rewrite_fixture 'if .type == "response_item" and .payload.id == "synthetic-assistant-2"
    then .payload.content = [{"type":"output_text","text":"Invented current result without a receipt."}]
    else . end'
  run bash "$HOOK" <<<"$(stop_input)"
  assert_block_reason 'receipts:'
}

@test "rollout: transcript with no user message is unusable" {
  rewrite_fixture 'if .type == "response_item" and .payload.type == "message" and .payload.role == "user"
    then .payload.role = "developer" else . end'
  run bash "$HOOK" <<<"$(stop_input)"
  assert_block_reason 'transcript-unusable:'
}

@test "rollout: legacy message.role still anchors" {
  rewrite_fixture 'if .type == "response_item" and .payload.id == "synthetic-user-1"
    then .payload.role = "developer"
    elif .type == "response_item" and .payload.id == "synthetic-user-2"
    then (.message = {"role":"user","content":"Invented legacy prompt."}) | del(.payload.role)
    else . end'
  run bash "$HOOK" <<<"$(stop_input)"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || printf '%s' "$output" | jq -e 'has("decision") | not' >/dev/null
}
