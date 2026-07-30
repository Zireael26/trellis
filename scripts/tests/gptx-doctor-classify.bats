#!/usr/bin/env bats
#
# Pins doctor.sh's four-way probe classification.
#
# Why this file exists: on 2026-07-30 an OpenAI outage made the doctor report FAIL and
# exit 1 — "your upgrade broke the GPT lane" — for probes that were purely the provider
# being down. The doctor's own header had always claimed that distinction mattered; it
# just had no branch for it and no test holding the branches in order.
#
# The classifier is loaded via GPTX_DOCTOR_LIB_ONLY so these run offline: no router, no
# provider, no network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCTOR="$REPO_ROOT/scripts/gptx/doctor.sh"
}

# Load the classifier and run one case. Echoes the printed line; sets the flag globals.
run_classify() {
  local http="$1" body="$2" expect="$3"
  GPTX_DOCTOR_LIB_ONLY=1 bash -c '
    set -uo pipefail
    # shellcheck disable=SC1090
    . "$1"
    HTTP="$2"
    classify_gpt "probe" "$3" "$4"
    printf "flags FAIL=%s QUOTA=%s UPSTREAM=%s\n" "$FAIL" "$QUOTA" "$UPSTREAM"
  ' _ "$DOCTOR" "$http" "$body" "$expect"
}

@test "lib-only sourcing defines the classifier without running probes" {
  run bash -c 'GPTX_DOCTOR_LIB_ONLY=1 . "'"$DOCTOR"'" && declare -F classify_gpt >/dev/null && echo loaded'
  [ "$status" -eq 0 ]
  [[ "$output" == *loaded* ]]
  # If the guard leaked, the preflight would have printed OK/FAIL lines too.
  [[ "$output" != *"router answering"* ]]
}

@test "a well-formed tool_use response is OK" {
  run run_classify 200 'event: content_block_start
data: {"type":"tool_use","name":"StructuredOutput"}
event: message_stop' 'StructuredOutput'
  [[ "$output" == *"OK    probe"* ]]
  [[ "$output" == *"FAIL=0 QUOTA=0 UPSTREAM=0"* ]]
}

@test "in-stream service_unavailable_error is UPSTR, never FAIL" {
  # Verbatim shape observed on the wire 2026-07-30: HTTP is 200 and message_start has
  # already been emitted, so only the body distinguishes this from a translation break.
  run run_classify 200 'event: message_start
data: {"type":"message_start","message":{"model":"gpt-5.6-sol"}}
event: error
data: {"type":"error","error":{"type":"service_unavailable_error","message":"Our servers are currently overloaded. Please try again later."}}' 'StructuredOutput'
  [[ "$output" == *"UPSTR probe"* ]]
  [[ "$output" == *"FAIL=0 QUOTA=0 UPSTREAM=1"* ]]
}

@test "the overload prose alone is enough to classify UPSTR" {
  run run_classify 200 'data: {"error":{"message":"Our servers are currently overloaded."}}' 'tool_use'
  [[ "$output" == *"UPSTR probe"* ]]
  [[ "$output" == *"UPSTREAM=1"* ]]
}

@test "an OpenAI request-ID escalation line classifies UPSTR" {
  run run_classify 200 'data: {"error":{"message":"Please include the request ID abc-123 in your message."}}' 'tool_use'
  [[ "$output" == *"UPSTR probe"* ]]
  [[ "$output" == *"UPSTREAM=1"* ]]
}

@test "quota still wins over upstream when both could match" {
  # Ordering matters for where a reader is sent: QUOTA points at billing and auth,
  # UPSTR at the provider's status page.
  run run_classify 200 'data: {"error":{"message":"quota exceeded; servers are currently overloaded"}}' 'tool_use'
  [[ "$output" == *"QUOTA probe"* ]]
  [[ "$output" == *"FAIL=0 QUOTA=1 UPSTREAM=0"* ]]
}

@test "a genuine translation break still FAILs — the fix must not broaden into silence" {
  # This is the regression that would make the whole doctor worthless: a 200 with a
  # complete stream that simply never emitted the expected block.
  run run_classify 200 'event: message_start
data: {"type":"message_start"}
event: content_block_delta
data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Sure, the weather is fine."}}
event: message_stop' 'tool_use'
  [[ "$output" == *"FAIL  probe"* ]]
  [[ "$output" == *"FAIL=1 QUOTA=0 UPSTREAM=0"* ]]
}

@test "a non-200 with no known signature still FAILs" {
  run run_classify 500 'internal error' 'tool_use'
  [[ "$output" == *"FAIL  probe"* ]]
  [[ "$output" == *"FAIL=1"* ]]
}

@test "success is checked before upstream — a model discussing outages is not an outage" {
  # The model's own prose can contain the provider's error text. Success must be
  # evaluated first or a green probe would be reclassified as a provider failure.
  run run_classify 200 'event: content_block_start
data: {"type":"tool_use","name":"StructuredOutput","input":{"note":"service_unavailable_error means servers are currently overloaded"}}
event: message_stop' 'StructuredOutput'
  [[ "$output" == *"OK    probe"* ]]
  [[ "$output" == *"UPSTREAM=0"* ]]
}

@test "UPSTREAM is in the --certify refusal guard and the exit-2 arm" {
  # A baseline written during an outage would record probes that never exercised tool
  # translation at all. Asserted on the source because reaching it live needs an outage.
  run grep -c 'UPSTREAM" -ne 0' "$DOCTOR"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "UPSTR and QUOTA are distinct labels, not aliases" {
  run grep -E "^upstream\(\)|^quota\(\)" "$DOCTOR"
  [[ "$output" == *"UPSTR"* ]]
  [[ "$output" == *"QUOTA"* ]]
}
