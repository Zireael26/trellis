#!/usr/bin/env bats
# Codex 0.157.1 SessionStart/Stop/PreToolUse/PostToolUse output schemas.
# Re-derive the closed key lists and field types from the binary on upgrade.
#
# Codex parses each hook's stdout against a closed schema
# (`additionalProperties: false`, embedded in codex-cli 0.157.1 as
# `session-start.command.output`, `stop.command.output`,
# `pre-tool-use.command.output`, `post-tool-use.command.output`) and reports
# "hook returned invalid session start JSON output" /
# "hook returned invalid stop hook JSON output" on any mismatch:
#   - SessionStart: empty, plain text (becomes developer context), or ONE JSON
#     object with only continue/stopReason/suppressOutput/systemMessage/
#     hookSpecificOutput{hookEventName:"SessionStart", additionalContext}.
#   - Stop: empty, or ONE JSON object with only continue/stopReason/
#     suppressOutput/systemMessage/decision("block")/reason. Plain text is invalid.
# Source: https://learn.chatgpt.com/docs/hooks plus the schemas in the binary.
#
# Every hook registered under the four events in core-rules/codex/hooks.json
# or core-rules/templates/codex-hooks.local.json (union by basename)
# runs from a deployed .codex/hooks layout (libs per inheritance-manifest.json)
# with an isolated HOME, so a newly registered hook is covered automatically.

bats_require_minimum_version 1.5.0
load helpers

CODEX_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$HOME/.trellis"
  mkdir -p "$TRELLIS_HOME"
  DEPLOY="$BATS_TEST_TMPDIR/deploy/.codex/hooks"
  mkdir -p "$DEPLOY/lib"
  cp "$CODEX_DIR"/hooks/*.sh "$DEPLOY/"
  cp "$CODEX_DIR"/hooks/lib/* "$DEPLOY/lib/"
  local src
  while IFS= read -r src; do
    cp "$CODEX_DIR/../../$src" "$DEPLOY/lib/"
  done < <(jq -r '.. | objects | select((.destination? // "") | startswith(".codex/hooks/lib/")) | .source' \
    "$CODEX_DIR/../inheritance-manifest.json")
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -q -m init
    git checkout -q -b feat/contract
    printf 'x\n' > app.py
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  # Keeps code-review-subagent.sh from launching a live reviewer on the dirty tree.
  export TRELLIS_REVIEW_OVERRIDE=1
  unset CLAUDE_PROJECT_DIR
}

# assert_codex_output <SessionStart|Stop|PreToolUse|PostToolUse> <stdout>
assert_codex_output() {
  local event="$1" out="$2" trimmed
  trimmed="$(printf '%s' "$out" | tr -d '[:space:]')"
  [ -z "$trimmed" ] && return 0
  case "$trimmed" in
    '{'*|'['*) ;;
    *)
      [ "$event" = SessionStart ] && return 0
      echo "$event stdout is plain text: $out" >&2
      return 1 ;;
  esac
  printf '%s' "$out" | jq -se --arg ev "$event" '
    def typed($o; $key; $expected): (($o | has($key)) | not) or (($o[$key] | type) == $expected);
    def specific($o; $ev):
      ($o | has("hookSpecificOutput") | not) or
      ($o.hookSpecificOutput | type == "object" and
        ((keys - (if $ev == "PreToolUse" then
            ["hookEventName", "additionalContext", "permissionDecision", "permissionDecisionReason", "updatedInput"]
          elif $ev == "PostToolUse" then
            ["hookEventName", "additionalContext", "updatedMCPToolOutput"]
          else ["hookEventName", "additionalContext"] end)) | length == 0) and
        .hookEventName == $ev and
        ((has("additionalContext") | not) or (.additionalContext | type == "string")) and
        (if $ev == "PreToolUse" then
           ((has("permissionDecision") | not) or (.permissionDecision == "allow" or .permissionDecision == "deny" or .permissionDecision == "ask")) and
           ((has("permissionDecisionReason") | not) or (.permissionDecisionReason | type == "string"))
         else true end));
    length == 1 and (.[0] | type == "object") and (.[0] as $o |
      (["continue", "stopReason", "suppressOutput", "systemMessage"]
        + (if $ev == "SessionStart" then ["hookSpecificOutput"]
           elif $ev == "Stop" then ["decision", "reason"]
           else ["decision", "reason", "hookSpecificOutput"] end)) as $allowed
      | (($o | keys) - $allowed | length == 0)
      and typed($o; "continue"; "boolean")
      and typed($o; "stopReason"; "string")
      and typed($o; "suppressOutput"; "boolean")
      and typed($o; "systemMessage"; "string")
      and (if $ev == "SessionStart" then specific($o; $ev)
           else (typed($o; "reason"; "string") and
                 (if $ev == "Stop" or $ev == "PostToolUse" then
                    (($o | has("decision") | not) or $o.decision == "block")
                  else (($o | has("decision") | not) or $o.decision == "block" or $o.decision == "approve") end) and
                 (if $ev == "Stop" then true else specific($o; $ev) end)) end))' >/dev/null || {
    echo "$event stdout violates the Codex 0.157.1 output schema: $out" >&2
    return 1
  }
}

registered_hooks() {
  # The attach template uses a launcher for SessionStart and direct runtime
  # paths for other events; the direct-copy manifest uses .codex/hooks paths.
  # Optional manifest arguments let the negative self-test probe a temp copy.
  local event="$1" hooks
  local -a manifests
  shift
  if [ "$#" -gt 0 ]; then
    manifests=("$@")
  else
    manifests=("$CODEX_DIR/hooks.json" "$CODEX_DIR/../templates/codex-hooks.local.json")
  fi
  hooks="$(jq -r --arg ev "$event" '
    .hooks[$ev][]?.hooks[].command |
    if type != "string" then
      error("unrecognised \($ev) hook command entry (not a string): \(.)")
    elif test("/[A-Za-z0-9_.-]+\\.sh") then
      capture("/(?<hook>[A-Za-z0-9_.-]+\\.sh)").hook
    elif test(" hook [A-Za-z0-9_.-]+ codex") then
      capture(" hook (?<hook>[A-Za-z0-9_.-]+) codex").hook + ".sh"
    else
      error("unrecognised \($ev) hook command entry: \(.)")
    end
  ' "${manifests[@]}")" || return 1
  printf '%s\n' "$hooks" | sort -u
}

registered_hook_names() {
  local event hooks names=""
  for event in SessionStart Stop PreToolUse PostToolUse; do
    hooks="$(registered_hooks "$event")" || return 1
    [ -z "$hooks" ] || names+="$hooks"$'\n'
  done
  printf '%s' "$names" | sort -u
}

run_registered() {
  local event="$1" payload="$2" hook registered
  registered="$(registered_hooks "$event")" || return 1
  [ -n "$registered" ] || { echo "$event: no registered hooks" >&2; return 1; }
  while IFS= read -r hook; do
    # shellcheck disable=SC2016  # positional args expand inside the child shell
    run --separate-stderr bash -c 'cd "$1" && printf "%s" "$2" | perl -e "alarm 60; exec @ARGV" /bin/bash "$3"' \
      _ "$PROJECT_DIR" "$payload" "$DEPLOY/$hook"
    echo "# $event $hook rc=$status" >&3
    [ "$status" -eq 0 ] || { echo "$event $hook failed with $status: $stderr" >&2; return 1; }
    assert_codex_output "$event" "$output" || { echo "hook: $hook" >&2; return 1; }
    HOOKS_EXERCISED="${HOOKS_EXERCISED:-}${hook}"$'\n'
  done <<<"$registered"
}

@test "validator rejects the security-guidance 2.0.8 SessionStart output" {
  run assert_codex_output SessionStart '{"async": true, "asyncTimeout": 180000}
{"metrics": {"sdk_bootstrap": 6}}'
  [ "$status" -ne 0 ]
  run assert_codex_output SessionStart '{"metrics": {"sdk_bootstrap": 6}, "systemMessage": "x"}'
  [ "$status" -ne 0 ]
}

@test "validator rejects the security-guidance 2.0.8 Stop output and plain text" {
  run assert_codex_output Stop '{"metrics": {"pv": 20008, "skipped": true}}'
  [ "$status" -ne 0 ]
  run assert_codex_output Stop '[spec-gate] note'
  [ "$status" -ne 0 ]
  run assert_codex_output Stop '{"decision": "approve"}'
  [ "$status" -ne 0 ]
  run assert_codex_output Stop '{"hookSpecificOutput": {"hookEventName": "Stop"}}'
  [ "$status" -ne 0 ]
}

@test "validator rejects wrong field types and nested unknown keys for all events" {
  local event bad
  for event in SessionStart Stop PreToolUse PostToolUse; do
    for bad in '{"continue":"true"}' '{"suppressOutput":0}' '{"stopReason":false}' '{"systemMessage":[]}' '{"metrics":{"x":1}}'; do
      run assert_codex_output "$event" "$bad"
      [ "$status" -ne 0 ] || { echo "$event incorrectly accepted $bad" >&2; return 1; }
    done
  done
  run assert_codex_output Stop '{"reason":3}'
  [ "$status" -ne 0 ]
  run assert_codex_output SessionStart '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":4}}'
  [ "$status" -ne 0 ]
  run assert_codex_output PreToolUse '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"permit"}}'
  [ "$status" -ne 0 ]
  run assert_codex_output PostToolUse '{"hookSpecificOutput":{"hookEventName":"PostToolUse","metrics":1}}'
  [ "$status" -ne 0 ]
}

@test "validator accepts every documented valid shape" {
  assert_codex_output SessionStart ''
  assert_codex_output SessionStart 'plain developer context'
  assert_codex_output SessionStart '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"c"}}'
  assert_codex_output Stop ''
  assert_codex_output Stop '{"systemMessage":"m"}'
  assert_codex_output Stop '{"decision":"block","reason":"r"}'
  assert_codex_output PreToolUse '{"decision":"approve","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"r"}}'
  assert_codex_output PostToolUse '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"c"}}'
}

@test "every registered SessionStart hook emits Codex-valid stdout" {
  run_registered SessionStart \
    "{\"session_id\":\"s1\",\"transcript_path\":null,\"cwd\":\"$PROJECT_DIR\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-6-astra\",\"source\":\"startup\"}"
}

@test "every registered Stop hook emits Codex-valid stdout" {
  run_registered Stop \
    "{\"session_id\":\"s1\",\"turn_id\":\"t1\",\"transcript_path\":null,\"cwd\":\"$PROJECT_DIR\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-6-astra\",\"stop_hook_active\":false,\"last_assistant_message\":\"done\"}"
}

@test "attach-only wiki-skill-suggest is enumerated once from both manifests" {
  [ "$(registered_hooks PostToolUse | grep -cx 'wiki-skill-suggest.sh')" -eq 1 ]
}

@test "registered hook enumeration fails on an unrecognised command form" {
  local manifest_copy="$BATS_TEST_TMPDIR/hooks.json"
  cp "$CODEX_DIR/hooks.json" "$manifest_copy"
  jq '.hooks.SessionStart[0].hooks[0].command = "unrecognised-command-fixture"' \
    "$manifest_copy" > "$manifest_copy.tmp"
  mv "$manifest_copy.tmp" "$manifest_copy"
  run registered_hooks SessionStart "$manifest_copy"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unrecognised-command-fixture'* ]]
}

@test "unique registered hook count equals the hooks exercised" {
  local event payload registered_count exercised_count registered
  HOOKS_EXERCISED=""
  registered="$(registered_hook_names)" || return 1
  registered_count="$(printf '%s\n' "$registered" | awk 'NF { count++ } END { print count + 0 }')"

  for event in SessionStart Stop PreToolUse PostToolUse; do
    case "$event" in
      SessionStart)
        payload="{\"session_id\":\"s1\",\"transcript_path\":null,\"cwd\":\"$PROJECT_DIR\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-6-astra\",\"source\":\"startup\"}"
        ;;
      Stop) payload="$(stop_payload)" ;;
      *)
        payload="$(jq -nc --arg cwd "$PROJECT_DIR" --arg event "$event" \
          '{session_id:"s1",turn_id:"t1",transcript_path:null,cwd:$cwd,hook_event_name:$event,
            model:"gpt-6-astra",tool_name:"Read",tool_input:{file_path:"absent.txt"},
            tool_response:"not found"}')"
        ;;
    esac
    run_registered "$event" "$payload" || return 1
  done

  exercised_count="$(printf '%s' "$HOOKS_EXERCISED" | sort -u | awk 'NF { count++ } END { print count + 0 }')"
  [ "$exercised_count" -eq "$registered_count" ] || {
    echo "unique registered hook count $registered_count != hooks exercised count $exercised_count" >&2
    return 1
  }
}

@test "every registered PreToolUse and PostToolUse hook has type-valid non-block output" {
  local event
  for event in PreToolUse PostToolUse; do
    run_registered "$event" "$(jq -nc --arg cwd "$PROJECT_DIR" --arg event "$event" \
      '{session_id:"s1",turn_id:"t1",transcript_path:null,cwd:$cwd,hook_event_name:$event,
        model:"gpt-6-astra",tool_name:"Read",tool_input:{file_path:"absent.txt"},
        tool_response:"not found"}')"
  done
}

stop_payload() {
  jq -nc --arg cwd "$PROJECT_DIR" --arg message "${1:-Done without a receipt.}" \
    '{session_id:"s1",turn_id:"t1",transcript_path:null,cwd:$cwd,
      hook_event_name:"Stop",model:"gpt-6-astra",stop_hook_active:false,
      last_assistant_message:$message}'
}

run_stop() {
  local hook="$1" payload="$2"
  run --separate-stderr bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' \
    _ "$PROJECT_DIR" "$payload" "$DEPLOY/$hook"
}

# Trellis Stop blocks use ONLY exit 0 and EXACTLY decision+reason JSON.
# Exit 2 is forbidden even when stderr supplies a continuation prompt.
assert_stop_block() {
  local rc="$1" out="$2"
  [ "$rc" -eq 0 ] || { echo "unexpected Stop exit: $rc" >&2; return 1; }
  assert_codex_output Stop "$out" || return 1
  printf '%s' "$out" | jq -se 'length == 1 and (.[0] | keys == ["decision", "reason"])
    and .[0].decision == "block" and (.[0].reason | type == "string" and length > 0)' >/dev/null || {
      echo "Stop block shape invalid: $out (stderr: ${3:-})" >&2; return 1;
    }
}

assert_run_block() {
  assert_stop_block "$status" "$output" "$stderr"
}

assert_tool_block() {
  local event="$1"
  [ "$status" -eq 2 ] || { echo "$event expected exit 2, got $status: $output" >&2; return 1; }
  [ -n "$stderr" ] || { echo "$event exit 2 missing stderr reason" >&2; return 1; }
  assert_codex_output "$event" "$output"
}

@test "block-destructive PreToolUse sends blocking reason to stderr" {
  run --separate-stderr bash "$DEPLOY/block-destructive.sh" \
    <<<'{"tool_name":"Bash","tool_input":{"command":"rm -rf /absolute-fixture"}}'
  assert_tool_block PreToolUse
  [[ "$stderr" == *'Blocked destructive rm'* ]]
}

@test "reread-guard PreToolUse budget block sends blocking reason to stderr" {
  printf 'old\n' > "$PROJECT_DIR/existing.txt"
  local payload
  payload="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{session_id:"contract-reread",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"existing.txt"}}')"
  for _ in 1 2; do
    run --separate-stderr bash "$DEPLOY/reread-guard.sh" <<<"$payload"
    [ "$status" -eq 0 ]
    assert_codex_output PreToolUse "$output"
  done
  run --separate-stderr bash "$DEPLOY/reread-guard.sh" <<<"$payload"
  assert_tool_block PreToolUse
  [[ "$stderr" == *'BLOCKED edit'* ]]
}

@test "post-edit-verify PostToolUse lint failure sends feedback to stderr" {
  printf 'x = 1\n' > "$PROJECT_DIR/edited.py"
  local bindir="$BATS_TEST_TMPDIR/bin" payload
  mkdir -p "$bindir"
  printf '#!/bin/sh\necho fixture-lint >&2\nexit 1\n' > "$bindir/ruff"
  chmod +x "$bindir/ruff"
  payload="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"edited.py"},tool_response:{success:true}}')"
  run --separate-stderr env PATH="$bindir:$PATH" bash "$DEPLOY/post-edit-verify.sh" <<<"$payload"
  assert_tool_block PostToolUse
  [[ "$stderr" == *'fixture-lint'* ]]
}

# Curated path has the real tools needed to start the hooks, but no jq.
no_jq_path() {
  local bin="$BATS_TEST_TMPDIR/no-jq-bin" tool src
  mkdir -p "$bin"
  for tool in bash cat dirname git shasum awk sed grep cut date tr head tail wc cksum perl; do
    src="$(command -v "$tool" 2>/dev/null)"
    case "$src" in /*) ln -sf "$src" "$bin/$tool" ;; esac
  done
  printf '%s' "$bin"
}

@test "R8: every jq-dependent Stop hook fails closed or explicitly degrades with no jq" {
  local path hook degrade
  path="$(no_jq_path)"
  # All nine registered Stop hooks invoke the shared jq dependency helper.
  for hook in $(registered_hooks Stop); do
    for degrade in 0 1; do
      if [ "$degrade" -eq 1 ]; then
        run --separate-stderr env PATH="$path" TRELLIS_NO_JQ_DEGRADE=1 \
          /bin/bash "$DEPLOY/$hook" <<<"$(stop_payload)"
      else
        run --separate-stderr env -u TRELLIS_NO_JQ_DEGRADE PATH="$path" \
          /bin/bash "$DEPLOY/$hook" <<<"$(stop_payload)"
      fi
      [ "$status" -eq "$((1 - degrade))" ] || {
        echo "$hook degrade=$degrade rc=$status stdout=$output stderr=$stderr" >&2; return 1;
      }
      [ -z "$output" ]
      if [ "$degrade" -eq 1 ]; then
        [[ "$stderr" == *'degrading to no-op'* ]]
      else
        [[ "$stderr" == *'jq required but not found'* ]]
      fi
    done
  done
}

@test "spec-gate Stop blocks on malformed opted-in policy with Codex output" {
  printf '{"mandatory_pipeline":' > "$PROJECT_DIR/.trellis.json"
  run_stop spec-gate.sh "$(stop_payload)"
  assert_run_block
  [[ "$output" == *'spec-gate'* ]]
}

@test "spec-gate re-entrancy guard suppresses a second block on the same state" {
  printf '{"mandatory_pipeline":' > "$PROJECT_DIR/.trellis.json"
  run_stop spec-gate.sh "$(stop_payload)"
  assert_run_block
  run_stop spec-gate.sh "$(stop_payload | jq -c '.stop_hook_active = true')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop-verify project-directory failure blocks with Codex output" {
  local missing="$BATS_TEST_TMPDIR/missing-project"
  run --separate-stderr env CODEX_PROJECT_DIR="$missing" bash "$DEPLOY/stop-verify.sh" \
    <<<"$(stop_payload)"
  assert_run_block
  [[ "$output" == *'could not enter configured project directory'* ]]
}

@test "stop-verify receipts block has Codex output and retains fail-counter" {
  run_stop stop-verify.sh "$(stop_payload)"
  assert_run_block
  printf '%s' "$output" | jq -e '.reason | startswith("receipts:")' >/dev/null
  [ -f "$PROJECT_DIR/.codex/.fail-counter" ]
}

@test "ui-verify failed capture blocks with Codex output" {
  printf 'export UI_SHOT_CMD=true\n' > "$PROJECT_DIR/.codex-ui-config"
  printf 'component\n' > "$PROJECT_DIR/component.tsx"
  local bindir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bindir"
  printf '#!/bin/sh\nexit 0\n' > "$bindir/curl"
  chmod +x "$bindir/curl"
  UI_SHOT_CMD=true PATH="$bindir:$PATH" run_stop ui-verify.sh "$(stop_payload)"
  assert_run_block
  [[ "$output" == *'screenshot produced no artifact'* ]]
}

@test "code-review critical finding blocks with Codex output and no marker" {
  printf 'unsafe = true\n' > "$PROJECT_DIR/app.py"
  git -C "$PROJECT_DIR" add app.py
  local reviewer="$BATS_TEST_TMPDIR/reviewer.sh"
  printf '#!/bin/sh\nprintf '\''%%s\\n'\'' '\''{"findings":[{"severity":"critical","file":"app.py","msg":"fixture critical"}]}'\''\n' > "$reviewer"
  chmod +x "$reviewer"
  unset TRELLIS_REVIEW_OVERRIDE
  CODE_REVIEWER_CMD="$reviewer" REVIEW_MIN_FILES=1 run_stop code-review-subagent.sh "$(stop_payload)"
  assert_run_block
  [[ "$output" == *'fixture critical'* ]]
  [ -z "$(find "$PROJECT_DIR/.codex" -maxdepth 1 -name '.review-done-*' -print 2>/dev/null)" ]
}

@test "decision-receipt shared-core block is remapped by Codex wrapper" {
  printf '{"autonomy":4}\n' > "$PROJECT_DIR/.trellis.config.json"
  run_stop decision-receipt.sh "$(stop_payload)"
  assert_run_block
  [[ "$output" == *'decision-receipt:'* ]]
}

@test "missing-core Stop blocks (spec 055 R1.3) keep Codex output" {
  rm -f "$DEPLOY/lib/spec-gate-core.sh" "$DEPLOY/lib/ui-verify-core.sh"
  run_stop spec-gate.sh "$(stop_payload)"
  assert_run_block
  [[ "$output" == *'core library missing'* ]]
  run_stop ui-verify.sh "$(stop_payload)"
  assert_run_block
  [[ "$output" == *'core library missing'* ]]
}

@test "missing-core spec-gate block is valid JSON without jq on a hostile path" {
  local path proj
  path="$(no_jq_path)"
  proj="$BATS_TEST_TMPDIR/q\"uo\\te"$'\n'"line"
  mkdir -p "$proj"
  git -C "$proj" init -q
  rm -f "$DEPLOY/lib/spec-gate-core.sh"
  run --separate-stderr env PATH="$path" bash -c 'cd "$1" && printf "{}" | bash "$2"' \
    _ "$proj" "$DEPLOY/spec-gate.sh"
  assert_run_block
  printf '%s' "$output" | jq -e --arg p "$proj" '.reason | contains($p)' >/dev/null
}

@test "Stop exit 2 is rejected even with a valid JSON object and stderr continuation" {
  run assert_stop_block 2 '{"decision":"block","reason":"valid"}' 'continuation prompt'
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected Stop exit: 2'* ]]
}

@test "M1: invalid metrics key on deployed Stop fixture is rejected and restored" {
  local hook="$DEPLOY/stamp-turn.sh" original="$BATS_TEST_TMPDIR/stamp-turn-original.sh" payload
  cp "$hook" "$original"
  payload="$(stop_payload)"
  run_stop stamp-turn.sh "$payload"
  [ "$status" -eq 0 ]
  assert_codex_output Stop "$output"
  # Inject the production failure class into the *deployed copy*, not source.
  perl -0pi -e 's/^(#![^\n]*\n)/$1printf '\''%s\\n'\'' '\''{"metrics":{"x":1}}'\''\n/' "$hook"
  run_stop stamp-turn.sh "$payload"
  [ "$status" -eq 0 ]
  run assert_codex_output Stop "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *'violates the Codex'* ]]
  cp "$original" "$hook"
  run_stop stamp-turn.sh "$payload"
  [ "$status" -eq 0 ]
  assert_codex_output Stop "$output"
}

@test "M2: exit-2 mutation on deployed Stop fixture is rejected and restored" {
  local hook="$DEPLOY/stop-verify.sh" original="$BATS_TEST_TMPDIR/stop-verify-original.sh"
  cp "$hook" "$original"
  # Mutate only the deployed fixture, never the source. Restore before the
  # test ends even though each Bats test has its own deployment directory.
  perl -0pi -e 's/(Codex reads this decision\n  # from stdout only on exit 0 \(exit 2 instead requires a stderr prompt\)\.\n  )exit 0/$1exit 2/' "$hook"
  run_stop stop-verify.sh "$(stop_payload)"
  local mutated_status="$status" mutated_output="$output"
  [ "$mutated_status" -eq 2 ]
  run assert_stop_block "$mutated_status" "$mutated_output"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected Stop exit: 2'* ]]
  cp "$original" "$hook"
  run_stop stop-verify.sh "$(stop_payload)"
  assert_run_block
}
