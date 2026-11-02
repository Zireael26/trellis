#!/usr/bin/env bats

HOOKS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
NORMALIZER="$REPO_ROOT/core-rules/hooks/lib/action-normalize.sh"
POST_EDIT="$HOOKS_DIR/post-edit-verify.sh"
TRACK_READ="$HOOKS_DIR/track-read.sh"

normalize() {
  local phase="$1" envelope="$2"
  bash -c '. "$1"; _ta_normalize_action codex "$2" "$3"' _ \
    "$NORMALIZER" "$phase" "$envelope"
}

setup() {
  PROJECT_DIR="$(mktemp -d)"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit --allow-empty -q -m init
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR
  # The hooks run in place from this tree, as the rendered hooks.json does; their
  # shared-lib fallback is bound to TRELLIS_ROOT (spec 055 R1.1).
  export TRELLIS_ROOT="$REPO_ROOT"
}

teardown() {
  rm -rf "$PROJECT_DIR"
}

@test "normalizer accepts exactly one object and silently rejects invalid envelope streams" {
  bats_require_minimum_version 1.5.0
  local compact pretty envelope
  compact='{"tool_name":"Read","tool_input":{"file_path":"one.py"}}'
  pretty="$(printf '%s' "$compact" | jq '.')" || return 1
  for envelope in "$compact" "$pretty"; do
    run --separate-stderr normalize pre_action "$envelope"
    [ "$status" -eq 0 ] || return 1
    [ -z "$stderr" ] || return 1
    printf '%s' "$output" | jq -e '
      .action.tool_name == "Read" and .action.family == "file_read" and
      .action.target_coverage == "complete" and
      .action.targets == [{operation:"read",path:"one.py"}] and
      .result == null' >/dev/null || return 1
  done
  for envelope in '' 'null' '42' '"scalar"' 'true' '[]' '[{}]' '{' \
    "$compact"$'\n'"$compact" "$compact$compact" "$compact"$'\n{'; do
    run --separate-stderr normalize pre_action "$envelope"
    [ "$status" -eq 1 ] || return 1
    [ -z "$output" ] || return 1
    [ -z "$stderr" ] || return 1
  done
}

@test "native apply_patch normalizes every add, update, rename, and delete target" {
  local command envelope
  command=$'*** Begin Patch\n*** Add File: one file.py\n+pass\n*** End of File\n*** Update File: old.py\n*** Move to: moved.py\n@@\n-old\n+new\n*** Delete File: gone.py\n*** End Patch'
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" --arg command "$command" \
    '{hook_event_name:"PostToolUse",cwd:$cwd,tool_name:"apply_patch",tool_use_id:"call-1",tool_input:{command:$command},tool_response:"Success. Updated the following files:\nA one file.py\nM moved.py\nD gone.py"}')"

  run normalize post_action "$envelope"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schema_version == 1 and .harness == "codex" and .phase == "post_action" and
    .action.id == "call-1" and .action.family == "file_mutation" and
    .action.target_coverage == "complete" and .result.status == "succeeded" and
    .action.targets == [
      {operation:"create",path:"one file.py"},
      {operation:"rename",path:"old.py",destination:"moved.py"},
      {operation:"delete",path:"gone.py"}
    ]' >/dev/null
}

@test "MultiEdit uses its outer file path when individual edits have no paths" {
  local envelope
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{cwd:$cwd,tool_name:"MultiEdit",tool_input:{file_path:"outer.py",edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:"d"}]}}')"
  run normalize pre_action "$envelope"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .action.target_coverage == "complete" and
    .action.targets == [{operation:"update",path:"outer.py"}]' >/dev/null
}

@test "malformed apply_patch preserves declared targets and reports partial coverage" {
  local command envelope
  command=$'*** Begin Patch\n*** Add File: known.py\n+pass\n*** Mystery: opaque\n'
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" --arg command "$command" \
    '{cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}')"

  run normalize pre_action "$envelope"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .action.target_coverage == "partial" and
    .action.targets == [{operation:"create",path:"known.py"}] and
    (.action.diagnostics | any(test("unknown apply_patch directive"))) and
    (.action.diagnostics | any(test("does not end")))' >/dev/null
}

@test "post result status distinguishes explicit success, explicit failure, and absent evidence" {
  local base success failure unknown
  base='{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}'
  success="$(printf '%s' "$base" | jq -c '. + {tool_response:"Success. Updated the following files:\nM a.py"}')"
  failure="$(printf '%s' "$base" | jq -c '. + {tool_response:"No files were modified."}')"

  success="$(normalize post_action "$success")"
  failure="$(normalize post_action "$failure")"
  unknown="$(normalize post_action "$base")"
  [ "$(printf '%s' "$success" | jq -r '.result.status')" = succeeded ]
  [ "$(printf '%s' "$failure" | jq -r '.result.status')" = failed ]
  [ "$(printf '%s' "$unknown" | jq -r '.result.status')" = unknown ]
}

@test "shell commands stay shell actions and receive no file-read targets" {
  local envelope
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{cwd:$cwd,tool_name:"exec_command",tool_input:{cmd:"cat secret.txt"}}')"
  run normalize pre_action "$envelope"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .action.family == "shell" and .action.target_coverage == "none" and
    .action.targets == []' >/dev/null
}

@test "control characters in structured and patch paths never become targets" {
  local envelope
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"bad\u0000name.py"}}')"
  run normalize pre_action "$envelope"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.action.targets == []' >/dev/null

  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" '
    {cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: bad\u0000name.py\n+x\n*** Add File: safe.py\n+y\n*** End Patch"}}')"
  run normalize pre_action "$envelope"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .action.target_coverage == "partial" and
    .action.targets == [{operation:"create",path:"safe.py"}]' >/dev/null
}

@test "raw target transport preserves backslashes" {
  local envelope normalized transported
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" --arg path 'dir\name.py' \
    '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$path}}')"
  normalized="$(normalize pre_action "$envelope")"
  transported="$(bash -c '. "$1"; _ta_targets_tsv "$2"' _ "$NORMALIZER" "$normalized")"
  [ "$transported" = $'update\tdir\\name.py\t' ]
}

@test "unknown post status still lints every declared existing mutation target" {
  local fake_bin command envelope
  fake_bin="$PROJECT_DIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ruff" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$RUFF_LOG"
exit 0
SH
  chmod +x "$fake_bin/ruff"
  printf 'x = 1\n' > "$PROJECT_DIR/a.py"
  printf 'y = 2\n' > "$PROJECT_DIR/b.py"
  command=$'*** Begin Patch\n*** Update File: a.py\n@@\n-x = 0\n+x = 1\n*** Add File: b.py\n+y = 2\n*** Delete File: removed.py\n*** End Patch'
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" --arg command "$command" \
    '{cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$command}}')"

  run env PATH="$fake_bin:$PATH" RUFF_LOG="$PROJECT_DIR/ruff.log" \
    bash "$POST_EDIT" <<<"$envelope"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PROJECT_DIR/ruff.log" | tr -d ' ')" -eq 2 ]
  grep -Fx "$PROJECT_DIR/a.py" "$PROJECT_DIR/ruff.log"
  grep -Fx "$PROJECT_DIR/b.py" "$PROJECT_DIR/ruff.log"

  envelope="$(printf '%s' "$envelope" | jq -c '. + {tool_response:"No files were modified."}')"
  rm "$PROJECT_DIR/ruff.log"
  run env PATH="$fake_bin:$PATH" RUFF_LOG="$PROJECT_DIR/ruff.log" \
    bash "$POST_EDIT" <<<"$envelope"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT_DIR/ruff.log" ]
}

@test "track-read records native mutation destinations but never parses shell reads" {
  local command envelope state_file
  printf 'new\n' > "$PROJECT_DIR/renamed.txt"
  command=$'*** Begin Patch\n*** Update File: old.txt\n*** Move to: renamed.txt\n@@\n-old\n+new\n*** End Patch'
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" --arg command "$command" \
    '{cwd:$cwd,session_id:"native-session",tool_name:"apply_patch",tool_input:{command:$command},tool_response:"Success. Updated the following files:\nM renamed.txt"}')"

  run bash "$TRACK_READ" <<<"$envelope"
  [ "$status" -eq 0 ]
  state_file="$(find "$PROJECT_DIR/.codex/.reread-state" -name '*.reads.tsv' -type f)"
  grep -F "$PROJECT_DIR/renamed.txt" "$state_file"

  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{cwd:$cwd,session_id:"shell-session",tool_name:"exec_command",tool_input:{cmd:"cat never-credit.txt"},tool_response:{success:true}}')"
  run bash "$TRACK_READ" <<<"$envelope"
  [ "$status" -eq 0 ]
  ! grep -R -F 'never-credit.txt' "$PROJECT_DIR/.codex/.reread-state"
}

@test "track-read skips an explicitly failed Read" {
  local envelope
  printf 'contents\n' > "$PROJECT_DIR/failed-read.txt"
  envelope="$(jq -nc --arg cwd "$PROJECT_DIR" \
    '{cwd:$cwd,session_id:"failed-read",tool_name:"Read",tool_input:{file_path:"failed-read.txt"},tool_response:{is_error:true,error:"denied"}}')"
  run bash "$TRACK_READ" <<<"$envelope"
  [ "$status" -eq 0 ]
  [ ! -d "$PROJECT_DIR/.codex/.reread-state" ]
}

@test "Codex hooks source the one shared normalizer and never carry a copy" {
  local hook n=0
  # A function of the normalizer defined anywhere else is a copy that can drift.
  run grep -rlE '^_ta_[a-z_]+\(\)' "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$NORMALIZER" ] || { echo "$output"; false; }
  for hook in "$HOOKS_DIR"/*.sh; do
    grep -qE '_ta_(normalize_action|guard_fields)' "$hook" || continue
    grep -qF '__ta_lib="$__h_dir/lib/action-normalize.sh"' "$hook" || { echo "$hook"; return 1; }
    grep -qxF '. "$__ta_lib"' "$hook" || { echo "$hook"; return 1; }
    n=$((n + 1))
  done
  [ "$n" -ge 5 ]
}

# The single-jq normalizer must print what the shell-and-jq normalizer printed.
# action-normalize-golden.json holds that normalizer's status and stdout for
# each entry, captured at a2a8746e4 before the rewrite.
GOLDEN="$BATS_TEST_DIRNAME/action-normalize-golden.json"

golden_entries() {
  jq -j '.[] | .name, "\u0000", .phase, "\u0000", .input, "\u0000", (.status | tostring), "\u0000", .output, "\u0000"' "$GOLDEN"
}

@test "normalizer output matches the golden corpus byte for byte" {
  local name phase input want_status want got rc checked=0 fails=0
  while IFS= read -r -d '' name && IFS= read -r -d '' phase && IFS= read -r -d '' input &&
    IFS= read -r -d '' want_status && IFS= read -r -d '' want; do
    got="$(normalize "$phase" "$input" 2>/dev/null)" && rc=0 || rc=$?
    checked=$((checked + 1))
    if [ "$rc" != "$want_status" ] || [ "$got" != "$want" ]; then
      printf '%s: status %s want %s\n  got  %s\n  want %s\n' "$name" "$rc" "$want_status" "$got" "$want"
      fails=$((fails + 1))
    fi
  done < <(golden_entries)
  echo "checked $checked"
  [ "$checked" -gt 150 ]
  [ "$fails" -eq 0 ]
}

# The guards read their fields from _ta_guard_fields in the normalizer's own jq
# run; each must equal what the guards read from the envelope before.
@test "guard fields agree with the envelope for every golden entry" {
  local name phase input want_status want fields expected checked=0 fails=0
  while IFS= read -r -d '' name && IFS= read -r -d '' phase && IFS= read -r -d '' input &&
    IFS= read -r -d '' want_status && IFS= read -r -d '' want; do
    fields="$(bash -c '
      . "$1"
      _ta_guard_fields "$2" "$3" "$_TA_EDIT_FAILURE_RE" i || { echo FAIL; exit 0; }
      printf "%s|" "$TA_FAMILY" "$TA_COVERAGE" "$TA_DIAGNOSTIC" "$TA_CWD" "$TA_STATUS" "$TA_TP" "$TA_SID"
      for i in "${!TA_OPS[@]}"; do printf "%s\t%s\t%s\n" "${TA_OPS[i]}" "${TA_PATHS[i]}" "${TA_DESTS[i]}"; done' _ \
      "$NORMALIZER" "$phase" "$input")"
    if [ "$want_status" != 0 ]; then
      expected=FAIL
    else
      expected="$(printf '%s|' \
        "$(printf '%s' "$want" | jq -r '.action.family')" \
        "$(printf '%s' "$want" | jq -r '.action.target_coverage')" \
        "$(printf '%s' "$want" | jq -r '.action.diagnostics[0] // "mutation targets are unavailable"')" \
        "$(printf '%s' "$want" | jq -r '.cwd // empty')" \
        "$(printf '%s' "$want" | jq -r '.result.status')" \
        "$(printf '%s' "$input" | jq -r '.transcript_path // empty')" \
        "$(printf '%s' "$input" | jq -r '.session_id // empty')"
        bash -c '. "$1"; _ta_targets_tsv "$2"' _ "$NORMALIZER" "$want")"
    fi
    checked=$((checked + 1))
    [ "$fields" = "$expected" ] || { printf '%s:\n  got  %s\n  want %s\n' "$name" "$fields" "$expected"; fails=$((fails + 1)); }
  done < <(golden_entries)
  echo "checked $checked"
  [ "$checked" -gt 150 ]
  [ "$fails" -eq 0 ]
}

# ta_r(f) reads a field as `$(jq -r f)` did; the guard include carries the same
# reading as gr_field (guard-rules.bats).
@test "ta_r reads every field as jq -r and command substitution did" {
  local input filter want got
  for input in '{"p":"/a b\n\n","s":{"k":[1,{"y":"z"},[],{}],"n":-1.50,"t":true,"u":null}}' \
    '{"p":"a\u0000b","s":42}' '{"p":false,"s":[]}' '{"p":"","s":"x\ty"}'; do
    for filter in '.p // empty' '.s // empty' '.s' '.missing // ""'; do
      want="$(printf '%s' "$input" | jq -r "$filter" 2>/dev/null)"
      got="$(printf '%s' "$input" | bash -c '. "$1"; jq -j "$_TA_JQ ta_r($2)"' _ "$NORMALIZER" "$filter")"
      [ "$got" = "$want" ] || { echo "$input $filter: $(printf '%q' "$got") want $(printf '%q' "$want")"; return 1; }
    done
  done
}

@test "the normalizer and the guard rules share one edit-failure marker set" {
  run bash -c '. "$1"; . "$2"; [ "$_TA_EDIT_FAILURE_RE" = "$GR_EDIT_FAILURE_RE" ] && [ "$GR_EDIT_FAILURE_FLAGS" = i ]' _ \
    "$NORMALIZER" "$REPO_ROOT/core-rules/hooks/lib/guard-rules.sh"
  [ "$status" -eq 0 ]
}
