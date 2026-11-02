#!/usr/bin/env bats
# Fixture runtime only; never attach or mutate installed artifacts.
setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  TEST_ROOT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TRELLIS_HOME="$TEST_ROOT/trellis"
  export HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}

lifecycle_fixture() {
  project="$TEST_ROOT/project"
  hooks="$project/.trellis/runtime/core-rules/codex/hooks"
  mkdir -p "$hooks" "$TEST_ROOT/event"
  chmod 700 "$TEST_ROOT/event"
  for name in session-context inject-primer-index spec-gate decision-receipt primer-capture-nudge ui-verify stamp-turn; do
    printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >> "$CODEX_PROJECT_DIR/order"\ncat > "$CODEX_PROJECT_DIR/${0##*/}.input"\nprintf "%%s\\n" "$TRELLIS_HARNESS|$TRELLIS_ROOT" > "$CODEX_PROJECT_DIR/${0##*/}.env"\n' > "$hooks/$name.sh"
    chmod +x "$hooks/$name.sh"
  done
}

lifecycle_event() {
  jq -nc --arg cwd "$project" --arg native "$1" --arg reason "${2:-startup}" '
    {schema_version:1,harness:"pi",cwd:$cwd,phase:"lifecycle",native_event:$native,reason:$reason,
     session_id:"session-\"é",session_file:($cwd + "/session transcript.jsonl")}
  ' > "$TEST_ROOT/event/event.json"
  chmod 600 "$TEST_ROOT/event/event.json"
}

run_lifecycle() {
  run bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$TEST_ROOT/event/event.json"
}

@test "installed-style pi extension preserves pre-action parity in process" {
  run node --test --test-reporter=tap "$SOURCE/core-rules/pi/tests/in-process-parity.test.mjs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "lifecycle batch preserves every hook input environment and execution order" {
  lifecycle_fixture
  for native in session_start agent_settled; do
    lifecycle_event "$native" resume
    run_lifecycle
    [ "$status" -eq 0 ]
    if [ "$native" = session_start ]; then
      expected=$'session-context.sh\ninject-primer-index.sh'
      source_value=resume
    else
      expected=$'spec-gate.sh\ndecision-receipt.sh\nprimer-capture-nudge.sh\nui-verify.sh\nstamp-turn.sh'
      source_value=agent_settled
    fi
    [ "$(<"$project/order")" = "$expected" ]
    while IFS= read -r name; do
      run jq -e --arg cwd "$project" --arg source "$source_value" '
        . == {tool_name:"",tool_input:{},session_id:"session-\"é",transcript_path:($cwd + "/session transcript.jsonl"),
              tool_response:null,native_tool_name:"",is_error:null,hook_event_name:(if $source == "resume" then "session_start" else $source end),
              source:$source,stop_hook_active:false}
      ' "$project/$name.input"
      [ "$status" -eq 0 ]
      [ "$(<"$project/$name.env")" = "pi|$project/.trellis/runtime" ]
    done <<< "$expected"
    rm "$project/order"
  done
}

@test "lifecycle hook failures retain warnings reasons streams and later hooks" {
  lifecycle_fixture
  printf '%s\n' 'printf '\''%s'\'' '\''{"decision":"block","reason":"stop reason","hookSpecificOutput":{"additionalContext":"first"}}'\''' 'printf stop-diagnostic >&2' 'exit 2' >> "$hooks/spec-gate.sh"
  printf '%s\n' 'printf "\\357\\273\\277"' 'printf '\''%s'\'' '\''{"hookSpecificOutput":{"additionalContext":"second"}} {"reason":"later reason"}'\''' >> "$hooks/decision-receipt.sh"
  printf '%s\n' 'printf broken >&2' 'exit 7' >> "$hooks/ui-verify.sh"
  lifecycle_event agent_settled
  run_lifecycle
  [ "$status" -eq 0 ]
  result="$output"
  run jq -e '.decision == "warn" and .capability_status == "unknown" and .context == "first\n\nsecond"
    and (.reason | contains("spec-gate.sh: stop reason") and contains("spec-gate.sh stderr: stop-diagnostic")
         and contains("decision-receipt.sh: later reason") and contains("ui-verify.sh: unknown — exited 7"))' <<< "$result"
  [ "$status" -eq 0 ]
  [ "$(<"$project/order")" = $'spec-gate.sh\ndecision-receipt.sh\nprimer-capture-nudge.sh\nui-verify.sh\nstamp-turn.sh' ]
}

@test "lifecycle malformed response stream cannot grant partial clean context" {
  lifecycle_fixture
  printf '%s\n' 'printf '\''%s'\'' '\''{"hookSpecificOutput":{"additionalContext":"partial"}} {"hookSpecificOutput":5}'\''' >> "$hooks/session-context.sh"
  lifecycle_event session_start
  run_lifecycle
  [ "$status" -eq 0 ]
  result="$output"
  run jq -e '.decision == "warn" and .capability_status == "advisory" and (has("context") | not)
    and (.reason | contains("session-context.sh stdout:"))' <<< "$result"
  [ "$status" -eq 0 ]
  [ -f "$project/inject-primer-index.sh.input" ]
}

@test "lifecycle batch does not wait for a descendant holding only stderr" {
  lifecycle_fixture
  printf '%s\n' 'sleep 10 >/dev/null &' 'printf "%s" "$!" > "$CODEX_PROJECT_DIR/child"' >> "$hooks/spec-gate.sh"
  lifecycle_event agent_settled
  start=$SECONDS
  run_lifecycle
  elapsed=$((SECONDS - start))
  kill "$(<"$project/child")" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ]
  [ -f "$project/stamp-turn.sh.input" ]
}

@test "lifecycle dispatcher parses in one interpreter without jq subprocesses" {
  lifecycle_fixture
  # Stub hooks never call either parser; these sentinels count dispatcher starts.
  mkdir "$TEST_ROOT/bin"
  real_jq="$(command -v jq)"
  real_python="$(command -v python3)"
  printf '#!/bin/bash\nprintf jq >> "%s"\nexec "%s" "$@"\n' "$TEST_ROOT/jq-starts" "$real_jq" > "$TEST_ROOT/bin/jq"
  printf '#!/bin/bash\nprintf python >> "%s"\nexec "%s" "$@"\n' "$TEST_ROOT/python-starts" "$real_python" > "$TEST_ROOT/bin/python3"
  chmod +x "$TEST_ROOT/bin/"*
  for native in session_start agent_settled; do
    lifecycle_event "$native"
    export TRELLIS_PYTHON="$TEST_ROOT/bin/python3"
    PATH="$TEST_ROOT/bin:$PATH" run_lifecycle
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_ROOT/jq-starts" ]
    [ "$(<"$TEST_ROOT/python-starts")" = python ]
    rm "$TEST_ROOT/python-starts"
  done
}

@test "legacy dispatcher retains read tracking unless the extension records it" {
  project="$BATS_TEST_TMPDIR/project"
  hooks="$project/.trellis/runtime/core-rules/codex/hooks"
  mkdir -p "$hooks"
  printf '#!/bin/bash\nexit 0\n' > "$hooks/truncation-check.sh"
  printf '#!/bin/bash\nprintf track-sentinel >&2\n' > "$hooks/track-read.sh"
  chmod +x "$hooks/"*.sh
  for recorded in false true; do
    encoded="$(jq -nc --arg cwd "$project" --argjson recorded "$recorded" '{schema_version:1,harness:"pi",cwd:$cwd,phase:"post_action",native_event:"tool_result",in_process_read_tracking:$recorded,action:{family:"file_read",tool_name:"read",input:{path:"file"}},result:{status:"succeeded"}}' | base64)"
    run bash -c 'cd "$1" && exec bash "$2" --base64 "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$encoded"
    [ "$status" -eq 0 ]
    if [ "$recorded" = true ]; then [[ "$output" != *track-sentinel* ]]; else [[ "$output" == *track-sentinel* ]]; fi
  done
}
