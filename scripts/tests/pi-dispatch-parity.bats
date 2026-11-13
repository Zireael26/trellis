#!/usr/bin/env bats
# Fixture runtime only; never attach or mutate installed artifacts.
bats_require_minimum_version 1.5.0
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
  # stderr apart: without a native companion the dispatcher labels its
  # sequential fallback there (T34).
  run --separate-stderr bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$TEST_ROOT/event/event.json"
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
      expected=$'spec-gate.sh\ndecision-receipt.sh\nprimer-capture-nudge.sh\nui-verify.sh'
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
  [ "$(<"$project/order")" = $'spec-gate.sh\ndecision-receipt.sh\nprimer-capture-nudge.sh\nui-verify.sh' ]
  [ ! -e "$project/stamp-turn.sh.input" ]  # T64a: settling never stamps
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
  [ -f "$project/ui-verify.sh.input" ]
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

# --- T52b: edit/write post batch through one native companion call ---------
post_fixture() {
  project="$TEST_ROOT/project"
  runtime="$project/.trellis/runtime"
  hooks="$runtime/core-rules/codex/hooks"
  log="$TEST_ROOT/native-log"
  mkdir -p "$hooks/lib" "$runtime/core-rules/native" "$TEST_ROOT/event" "$log"
  chmod 700 "$TEST_ROOT/event"
  cp "$SOURCE/core-rules/codex/hooks/lib/deps.sh" "$hooks/lib/deps.sh"
  cp "$SOURCE/core-rules/codex/hooks/lib/deps-heavy.sh" "$hooks/lib/deps-heavy.sh"
  for name in post-edit-verify slop-tripwire track-read wiki-skill-suggest; do
    printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >> "%s/order"\n' "$log" > "$hooks/$name.sh"
    chmod +x "$hooks/$name.sh"
  done
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) skip "no native target for this host" ;;
  esac
  body="$TEST_ROOT/companion"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/argv"\ncat > "%s/stdin"\ncat "%s/response"\nexit "$(cat "%s/rc")"\n' "$log" "$log" "$log" "$log" > "$body"
  printf 0 > "$log/rc"
  digest="$(shasum -a 256 "$body" | awk '{print $1}')"
  jq -n --arg t "$target" --arg d "$digest" '{version:"9.9.9",assets:{($t):{sha256:$d}}}' > "$runtime/core-rules/native/artifacts.json"
  dir="$TRELLIS_HOME/bin/native/9.9.9/$target/$digest"
  mkdir -p "$dir"
  chmod 700 "$TRELLIS_HOME/bin" "$TRELLIS_HOME/bin/native" "$TRELLIS_HOME/bin/native/9.9.9" "$TRELLIS_HOME/bin/native/9.9.9/$target" "$dir"
  companion="$dir/trellis-hooks"
  cp "$body" "$companion"
  chmod 500 "$companion"
}

# response <decision> <post-edit-verify row> <slop row> [member names]
response() {
  jq -nc --arg d "$1" --argjson pev "$2" --argjson slop "$3" --argjson names "${4:-[\"post-edit-verify\",\"slop-tripwire\",\"track-read\",\"wiki-skill-suggest\"]}" '
    def noop: {status:"no_op",exit_code:0,context:"",reason:"",error_class:null};
    {schema_version:1,harness:"pi",phase:"post_action",boundary:null,
     batch:{decision:$d,members:[$pev,$slop,noop,noop] | to_entries | map({member:$names[.key],result:.value})}}' > "$log/response"
}

post_event() {  # <status> [extra jq object merged into the event]
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg cwd "$project" --arg status "${1:-succeeded}" --argjson extra "$extra" '
    {schema_version:1,harness:"pi",phase:"post_action",native_event:"tool_result",cwd:$cwd,session_id:"sid",
     session_file:($cwd + "/s.jsonl"),unexpected_key:"dropped",
     action:{id:"call-1",tool_name:"edit",family:"file_mutation",target_coverage:"complete",
       targets:[{operation:"update",path:"a.ts"}],input:{path:"a.ts"},diagnostics:[]},
     result:{status:$status,is_error:false,output:{}}} + $extra' > "$TEST_ROOT/event/event.json"
  chmod 600 "$TEST_ROOT/event/event.json"
}

run_post() {
  run --separate-stderr bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$TEST_ROOT/event/event.json"
}

@test "T52b: edit post batch is one native call with the closed envelope and keeps a mandatory deny" {
  post_fixture
  response deny '{"status":"deny","exit_code":2,"context":"","reason":"lint sentinel","error_class":null}' \
    '{"status":"advice","exit_code":0,"context":"slop sentinel","reason":"","error_class":null}'
  post_event
  run_post
  [ "$status" -eq 1 ] || { echo "$output $stderr"; false; }
  [ "$(wc -l < "$log/argv" | tr -d ' ')" = 1 ]
  [ "$(<"$log/argv")" = "event pi post_action $project" ]
  [ ! -e "$log/order" ]
  [[ "$stderr" != *"sequential fallback"* ]] || false
  jq -e --arg cwd "$project" '
    (keys == ["action","cwd","harness","in_process_read_tracking","native_event","phase","result","schema_version","session_file","session_id"])
    and .in_process_read_tracking == false and .cwd == $cwd and .session_id == "sid"
    and (.action | keys == ["family","id","input","target_coverage","targets","tool_name"])
    and (.result | keys == ["is_error","output","status"])' "$log/stdin"
  printf '%s' "$output" | jq -e '.decision == "deny" and .capability_status == "advisory"
    and (.reason | contains("post-edit-verify.sh: lint sentinel")) and .context == "slop sentinel"'
}

@test "T52b: advisory batch maps to warn and the tracking flag reaches the native call" {
  post_fixture
  response warn '{"status":"no_op","exit_code":0,"context":"","reason":"","error_class":null}' \
    '{"status":"advice","exit_code":0,"context":"slop sentinel","reason":"","error_class":null}'
  post_event succeeded '{"in_process_read_tracking":true}'
  run_post
  [ "$status" -eq 0 ]
  jq -e '.in_process_read_tracking == true' "$log/stdin"
  printf '%s' "$output" | jq -e '.decision == "warn" and .context == "slop sentinel"'
}

@test "T52b: unselected, unverified, refusing or malformed natives take the labelled sequential fallback" {
  post_fixture
  ok='{"status":"no_op","exit_code":0,"context":"","reason":"","error_class":null}'
  check_fallback() {  # <expected label> <expected companion calls>
    : > "$log/argv"; rm -f "$log/order"
    post_event
    run_post
    [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
    [[ "$stderr" == *"post_action sequential fallback ($1"* ]] || { echo "$stderr"; false; }
    [ "$(<"$log/order")" = "$(printf '%s\n' post-edit-verify.sh slop-tripwire.sh track-read.sh wiki-skill-suggest.sh)" ]
    [ "$(wc -l < "$log/argv" | tr -d ' ')" = "$2" ]
  }
  response allow "$ok" "$ok"
  printf 2 > "$log/rc"; check_fallback 'native batch refused (exit 2' 1
  printf 0 > "$log/rc"
  response allow "$ok" "$ok" '["slop-tripwire","post-edit-verify","track-read","wiki-skill-suggest"]'
  check_fallback 'native batch response is not the closed post_action shape' 1
  response allow "$ok" "$ok"
  chmod 700 "$companion"; check_fallback 'companion verification failed' 0
  chmod 500 "$companion"; chmod 755 "$(dirname "$companion")"; check_fallback 'companion verification failed' 0
  chmod 700 "$(dirname "$companion")"
  chmod 700 "$companion"; printf '\n' >> "$companion"; chmod 500 "$companion"
  check_fallback 'companion verification failed' 0
  mv "$runtime/core-rules/native/artifacts.json" "$TEST_ROOT/artifacts.json"
  check_fallback 'no native asset selected' 0
}

@test "T52b: failed edits and unsafe event files never reach the companion" {
  post_fixture
  ok='{"status":"no_op","exit_code":0,"context":"","reason":"","error_class":null}'
  response allow "$ok" "$ok"
  post_event failed
  run_post
  [ "$status" -eq 0 ]
  [ ! -s "$log/argv" ] && [ ! -e "$log/order" ]
  printf '%s' "$output" | jq -e '.capability_status == "unsupported"'
  post_event
  chmod 644 "$TEST_ROOT/event/event.json"
  run_post
  [ "$status" -eq 2 ]
  [ ! -s "$log/argv" ]
}

# --- T64a: Pi completion only through the native Stop core ------------------
completion_response() {  # <decision> <stop-verify row> [boundary]
  local boundary="${3:-}"
  [ -n "$boundary" ] || boundary='{}'
  jq -nc --arg d "$1" --argjson verify "$2" --argjson boundary "$boundary" '
    def noop: {status:"no_op",exit_code:0,context:"",reason:"",error_class:null};
    {schema_version:1,harness:"pi",phase:"agent_before_settle",boundary:$boundary,
     batch:{decision:$d,members:[noop,noop,$verify,noop,noop,noop,noop] | to_entries
       | map({member:(["spec-gate","decision-receipt","stop-verify","code-review-subagent","ui-verify","required-post-action","stamp-turn"][.key]),result:.value})}}' > "$log/response"
}

completion_event() {
  jq -nc --arg cwd "$project" '
    {schema_version:1,harness:"pi",phase:"agent_before_settle",cwd:$cwd,session_id:"sid",session_file:($cwd + "/s.jsonl"),
     turn_id:"turn-1",generation:3,can_continue:true,last_assistant_message:"Done.",stop_hook_active:false,unexpected_key:"dropped"}' > "$TEST_ROOT/event/event.json"
  chmod 600 "$TEST_ROOT/event/event.json"
}

@test "T64a: completion is one native call with the closed request and returns its verdict" {
  post_fixture
  for name in spec-gate decision-receipt stop-verify ui-verify stamp-turn; do
    printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >> "%s/order"\n' "$log" > "$hooks/$name.sh"; chmod +x "$hooks/$name.sh"
  done
  completion_response allow '{"status":"no_op","exit_code":0,"context":"","reason":"","error_class":null}'
  completion_event
  run_post
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ "$(<"$log/argv")" = "event pi agent_before_settle $project" ]
  [ ! -e "$log/order" ]  # no shell Stop hook, and no stamp, outside the native batch
  jq -e --arg cwd "$project" '
    keys == ["can_continue","cwd","generation","harness","last_assistant_message","phase","schema_version","session_file","session_id","stop_hook_active","turn_id"]
    and .cwd == $cwd and .generation == 3 and .turn_id == "turn-1"' "$log/stdin"
  printf '%s' "$output" | jq -e --slurpfile r "$log/response" '.decision == "allow" and .capability_status == "enforced" and .completion == $r[0]'
  completion_response deny '{"status":"deny","exit_code":2,"context":"","reason":"receipts: missing DoD receipt","error_class":null}' \
    '{"entries":[{"type":"custom_message","customType":"trellis-completion","content":"receipts: missing DoD receipt","display":true}],"continue":true}'
  run_post
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.decision == "deny" and (.reason | contains("stop-verify: receipts: missing DoD receipt")) and .completion.boundary.continue == true'
}

@test "T64a: an unavailable, refusing or malformed native core denies completion, never falls back" {
  post_fixture
  printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >> "%s/order"\n' "$log" > "$hooks/stamp-turn.sh"; chmod +x "$hooks/stamp-turn.sh"
  ok='{"status":"no_op","exit_code":0,"context":"","reason":"","error_class":null}'
  check_deny() {  # <expected reason fragment>
    completion_event
    run_post
    [ "$status" -eq 1 ] || { echo "$output $stderr"; false; }
    printf '%s' "$output" | jq -e --arg why "$1" '.decision == "deny" and .capability_status == "unknown" and (.reason | contains($why)) and (has("completion") | not)'
    [ ! -e "$log/order" ]
  }
  completion_response allow "$ok"
  printf 2 > "$log/rc"; check_deny 'native completion refused (exit 2)'
  printf 0 > "$log/rc"
  jq -c '.batch.members |= reverse' "$log/response" > "$log/r2" && mv "$log/r2" "$log/response"
  check_deny 'not the closed agent_before_settle shape'
  completion_response allow "$ok"
  mv "$runtime/core-rules/native/artifacts.json" "$TEST_ROOT/artifacts.json"
  check_deny 'completion: unavailable — no native asset selected'
}

# --- T34: Pi lifecycle through one native companion call ---------------------
@test "T34: Pi lifecycle events are one native call with the closed request and keep their context" {
  post_fixture
  jq -nc '{schema_version:1,harness:"pi",phase:"session_start",boundary:null,
    batch:{decision:"warn",members:[
      {member:"session-context",result:{status:"advice",exit_code:0,context:"native session context",reason:"",error_class:null}},
      {member:"inject-primer-index",result:{status:"no_op",exit_code:0,context:"",reason:"",error_class:null}}]}}' > "$log/response"
  lifecycle_event session_start resume
  run --separate-stderr bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$TEST_ROOT/event/event.json"
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ "$(<"$log/argv")" = "event pi session_start $project" ]
  [[ "$stderr" != *"sequential fallback"* ]] || { echo "$stderr"; false; }
  jq -e --arg cwd "$project" '
    keys == ["cwd","harness","phase","reason","schema_version","session_file","session_id"]
    and .phase == "session_start" and .reason == "resume" and .cwd == $cwd' "$log/stdin"
  printf '%s' "$output" | jq -e '.context == "native session context" and .decision == "warn"'
  # A refusing native core falls back to the labelled shell route.
  printf 2 > "$log/rc"
  run --separate-stderr bash -c 'cd "$1" && exec bash "$2" --event-file "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$TEST_ROOT/event/event.json"
  [[ "$stderr" == *"session_start sequential fallback (native lifecycle refused (exit 2)"* ]] || { echo "$stderr"; false; }
}
