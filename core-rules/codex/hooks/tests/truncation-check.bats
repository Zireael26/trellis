#!/usr/bin/env bats

HOOK="$BATS_TEST_DIRNAME/../truncation-check.sh"

run_hook() {
  local input="$1" stderr_file="$BATS_TEST_TMPDIR/hook.stderr"
  if output="$(printf '%s' "$input" | /bin/bash "$HOOK" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  stderr="$(cat "$stderr_file")"
}

@test "a legitimate low-result Codex Grep response emits no advisory" {
  local input
  input="$(jq -nc --arg response 'src/only-match.ts:7:needle' \
    '{tool_name:"Grep",tool_input:{pattern:"needle"},tool_response:$response}')"

  run_hook "$input"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an explicit truncation marker still emits a Codex advisory" {
  local input
  input="$(jq -nc --arg response 'matches ...truncated... here' \
    '{tool_name:"Grep",tool_input:{pattern:"needle"},tool_response:$response}')"

  run_hook "$input"

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostToolUse" ]
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" == *"truncated"* ]]
}

@test "a 100K response still emits a Codex advisory" {
  local input response
  response="$(awk 'BEGIN { for (i = 0; i < 100000; i++) printf "x" }')"
  input="$(jq -nc --arg response "$response" \
    '{tool_name:"Read",tool_input:{},tool_response:$response}')"

  run_hook "$input"

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostToolUse" ]
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" == *"≥100K"* ]]
}
