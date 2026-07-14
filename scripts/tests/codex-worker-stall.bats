#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FIXTURE="$REPO_ROOT/scripts/tests/fixtures/fake-codex-companion.mjs"
STALL_ANNOTATION='prior attempt stalled; working tree may hold partial edits — review git diff first'

setup() {
  SANDBOX="$(mktemp -d)"
  STATE_FILE="$SANDBOX/state.json"
}

teardown() {
  rm -rf "$SANDBOX"
}

companion() {
  FAKE_MODE="$1" FAKE_STATE_FILE="$STATE_FILE" node "$FIXTURE" "${@:2}"
}

lower_effort() {
  case "$1" in
    max) echo xhigh ;;
    *) return 1 ;;
  esac
}

# Exercise the observable mechanics from core-rules/agents/codex-worker.md.
# The agent definition is prose, so this deliberately drives the fake companion
# state machine instead of pretending to execute a live agent.
run_worker_contract() {
  local mode="$1" requested_effort="$2"
  local effort="$requested_effort" attempts=0 stalls=0 downgrades=0
  local prompt='bounded fixture task' launch status job_id thread_id log_file mtime now silent
  local post_cancel_active=0

  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    launch="$(companion "$mode" task --background --write --effort "$effort" --json "$prompt")"
    job_id="$(jq -r '.jobId // empty' <<<"$launch")"
    status="$(companion "$mode" status "$job_id" --json)"
    thread_id="$(jq -r '.job.threadId // empty' <<<"$status")"
    log_file="$(jq -r '.job.logFile // empty' <<<"$status")"

    # The worker owns silence computation. The real status response has no
    # logSilentSeconds; make the fixture log old under harness control.
    if [ "$mode" = "stall-twice" ] || { [ "$mode" = "stall-once" ] && [ "$attempts" -eq 1 ]; }; then
      touch -t 200001010000 "$log_file"
    fi
    mtime="$(stat -f %m "$log_file" 2>/dev/null || stat -c %Y "$log_file")"
    now="$(date +%s)"
    silent=$((now - mtime))

    if [ -z "$thread_id" ]; then
      companion "$mode" cancel "$job_id" --json >/dev/null
      status="$(companion "$mode" status "$job_id" --json)"
      [[ "$(jq -r '.job.status' <<<"$status")" =~ ^(starting|running)$ ]] && post_cancel_active=$((post_cancel_active + 1))
      if [ "$attempts" -ge 2 ] || ! effort="$(lower_effort "$effort")"; then
        echo "STATUS: FAILURE CODE: NO_SESSION_ID ATTEMPTS: $attempts CANCELLATIONS: $attempts POST_CANCEL_ACTIVE: $post_cancel_active"
        return 1
      fi
      downgrades=$((downgrades + 1))
      prompt='bounded fixture task'
      continue
    fi

    if [ "$silent" -gt 900 ]; then
      companion "$mode" cancel "$job_id" --json >/dev/null
      status="$(companion "$mode" status "$job_id" --json)"
      [[ "$(jq -r '.job.status' <<<"$status")" =~ ^(starting|running)$ ]] && post_cancel_active=$((post_cancel_active + 1))
      stalls=$((stalls + 1))
      if [ "$stalls" -ge 2 ]; then
        echo "STATUS: FAILURE CODE: SECOND_STALL ATTEMPTS: $attempts CANCELLATIONS: $stalls POST_CANCEL_ACTIVE: $post_cancel_active STALL_RELAUNCHES: 1"
        return 1
      fi
      prompt="$STALL_ANNOTATION; bounded fixture task"
      continue
    fi

    companion "$mode" result "$job_id" --json >/dev/null
    echo "STATUS: SUCCESS ATTEMPTS: $attempts CANCELLATIONS: $stalls POST_CANCEL_ACTIVE: $post_cancel_active DOWNGRADES: $downgrades EFFECTIVE_EFFORT: $effort"
    return 0
  done

  echo "STATUS: FAILURE CODE: RETRY_EXHAUSTED ATTEMPTS: $attempts"
  return 1
}

@test "background fixture completes without retry" {
  local launch status_payload
  launch="$(companion background-then-complete task --background --write --effort high --json 'shape check')"
  [ "$(jq -r '.jobId' <<<"$launch")" = "job-1" ]
  [ "$(jq -r 'has("job")' <<<"$launch")" = "false" ]
  status_payload="$(companion background-then-complete status job-1 --json)"
  [ "$(jq -r '.job | has("logSilentSeconds")' <<<"$status_payload")" = "false" ]
  rm -f "$STATE_FILE" "$STATE_FILE".job-1.log

  run run_worker_contract background-then-complete xhigh
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: SUCCESS"* ]]
  [ "$(jq -r '.launchCount' "$STATE_FILE")" -eq 1 ]
  [ "$(jq -r '.cancelCalls' "$STATE_FILE")" -eq 0 ]
}

@test "stall once launches twice, cancels once, and records retry annotation" {
  run run_worker_contract stall-once xhigh
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: SUCCESS"* ]]
  [[ "$output" == *"ATTEMPTS: 2"* ]]
  [[ "$output" == *"CANCELLATIONS: 1"* ]]
  [[ "$output" == *"POST_CANCEL_ACTIVE: 1"* ]]
  [ "$(jq -r '.launchCount' "$STATE_FILE")" -eq 2 ]
  [ "$(jq -r '.cancelCalls' "$STATE_FILE")" -eq 1 ]
  [ "$(jq -r '.annotations | length' "$STATE_FILE")" -eq 1 ]
  [ "$(jq -r '.annotations[0]' "$STATE_FILE")" = "$STALL_ANNOTATION" ]
}

@test "stall twice cancels both jobs and returns FAILURE" {
  run run_worker_contract stall-twice xhigh
  [ "$status" -eq 1 ]
  [[ "$output" == *"STATUS: FAILURE"* ]]
  [[ "$output" == *"CODE: SECOND_STALL"* ]]
  [[ "$output" == *"CANCELLATIONS: 2"* ]]
  [[ "$output" == *"POST_CANCEL_ACTIVE: 2"* ]]
  [ "$(jq -r '.launchCount' "$STATE_FILE")" -eq 2 ]
  [ "$(jq -r '.cancelCalls' "$STATE_FILE")" -eq 2 ]
  [ "$(jq -r '.annotations | length' "$STATE_FILE")" -eq 1 ]
}

@test "missing session id retries once at one lower effort tier" {
  run run_worker_contract no-session-id max
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: SUCCESS"* ]]
  [[ "$output" == *"DOWNGRADES: 1"* ]]
  [[ "$output" == *"EFFECTIVE_EFFORT: xhigh"* ]]
  [ "$(jq -c '.requestedEfforts' "$STATE_FILE")" = '["max","xhigh"]' ]
  [ "$(jq -r '.launchCount' "$STATE_FILE")" -eq 2 ]
  [ "$(jq -r '.cancelCalls' "$STATE_FILE")" -eq 1 ]
}

@test "worker prose pins the executable polling and retry contract" {
  local worker="$REPO_ROOT/core-rules/agents/codex-worker.md"
  grep -Fq '30-second chunks' "$worker"
  grep -Fq 'more than 15 minutes' "$worker"
  grep -Fq 'Retry exactly once at one effort tier lower' "$worker"
  grep -Fq 'Relaunch exactly once as a fresh attempt' "$worker"
  grep -Fq "$STALL_ANNOTATION" "$worker"
  grep -Fq '`max -> xhigh`' "$worker"
  grep -Fq '`xhigh` is the lowest permitted input tier' "$worker"
}
