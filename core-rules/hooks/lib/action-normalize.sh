#!/usr/bin/env bash
# Normalize native harness tool events into the Trellis action envelope.
# Source this file, then call _ta_normalize_action <harness> <phase> <json>.

_ta_add_diagnostic() {
  _ta_diagnostics=$(jq -c --arg value "$1" '. + [$value]' <<EOF
$_ta_diagnostics
EOF
  ) || return 1
}

_ta_add_target() {
  local operation="$1" path="$2" destination="${3:-}"
  if [ -z "$path" ]; then
    _ta_add_diagnostic "empty file path in mutation directive"
    _ta_complete=0
    return 0
  fi
  case "$path$destination" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      _ta_add_diagnostic "file path contains a tab or line break"
      _ta_complete=0
      return 0
      ;;
  esac
  if [ -n "$destination" ]; then
    _ta_targets=$(jq -c \
      --arg operation "$operation" --arg path "$path" --arg destination "$destination" \
      '. + [{operation: $operation, path: $path, destination: $destination}]' <<EOF
$_ta_targets
EOF
    ) || return 1
  else
    _ta_targets=$(jq -c --arg operation "$operation" --arg path "$path" \
      '. + [{operation: $operation, path: $path}]' <<EOF
$_ta_targets
EOF
    ) || return 1
  fi
}

_ta_parse_apply_patch() {
  local patch="$1" line="" last_operation="" last_path="" saw_begin=0 saw_end=0
  _ta_targets='[]'
  _ta_diagnostics='[]'
  _ta_complete=1

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$saw_begin" -eq 0 ]; then
      if [ "$line" = "*** Begin Patch" ]; then
        saw_begin=1
      elif [ -n "$line" ]; then
        _ta_add_diagnostic "apply_patch does not start with *** Begin Patch"
        _ta_complete=0
        saw_begin=1
      fi
      continue
    fi
    if [ "$saw_end" -eq 1 ]; then
      if [ -n "$line" ]; then
        _ta_add_diagnostic "content follows *** End Patch"
        _ta_complete=0
      fi
      continue
    fi
    case "$line" in
      "*** End Patch")
        saw_end=1
        last_operation=""
        ;;
      "*** Add File: "*)
        last_operation="create"
        last_path=${line#"*** Add File: "}
        _ta_add_target "create" "$last_path" || return 1
        ;;
      "*** Delete File: "*)
        last_operation="delete"
        last_path=${line#"*** Delete File: "}
        _ta_add_target "delete" "$last_path" || return 1
        ;;
      "*** Update File: "*)
        last_operation="update"
        last_path=${line#"*** Update File: "}
        _ta_add_target "update" "$last_path" || return 1
        ;;
      "*** Move to: "*)
        if [ "$last_operation" != "update" ] || [ -z "$last_path" ]; then
          _ta_add_diagnostic "*** Move to directive does not follow an update"
          _ta_complete=0
        else
          local destination=${line#"*** Move to: "}
          if [ -z "$destination" ]; then
            _ta_add_diagnostic "empty destination in *** Move to directive"
            _ta_complete=0
          else
            case "$destination" in
              *$'\t'*|*$'\n'*|*$'\r'*)
                _ta_add_diagnostic "move destination contains a tab or line break"
                _ta_complete=0
                ;;
              *)
                _ta_targets=$(jq -c --arg destination "$destination" \
                  '.[-1].operation = "rename" | .[-1].destination = $destination' <<EOF
$_ta_targets
EOF
                ) || return 1
                ;;
            esac
          fi
          last_operation=""
        fi
        ;;
      "*** End of File")
        # Valid apply_patch sentinel used when a hunk consumes the file tail.
        last_operation=""
        ;;
      "*** "*)
        _ta_add_diagnostic "unknown apply_patch directive: $line"
        _ta_complete=0
        last_operation=""
        ;;
    esac
  done <<EOF
$patch
EOF

  if [ "$saw_begin" -eq 0 ]; then
    _ta_add_diagnostic "apply_patch is empty"
    _ta_complete=0
  fi
  if [ "$saw_end" -eq 0 ]; then
    _ta_add_diagnostic "apply_patch does not end with *** End Patch"
    _ta_complete=0
  fi
  if [ "$(jq 'length' <<EOF
$_ta_targets
EOF
  )" -eq 0 ]; then
    _ta_coverage="none"
  elif [ "$_ta_complete" -eq 1 ]; then
    _ta_coverage="complete"
  else
    _ta_coverage="partial"
  fi
}

_ta_result_json() {
  local phase="$1" response="$2" tool_name="$3" status="unknown" is_error="null"
  if [ "$phase" != "post_action" ]; then
    printf 'null\n'
    return 0
  fi

  if jq -e 'type == "object" and ((.is_error? == true) or (.isError? == true) or ((.error? // "") != "") or ((.tool_use_error? // "") != ""))' >/dev/null 2>&1 <<EOF
$response
EOF
  then
    status="failed"
    is_error="true"
  elif jq -e 'type == "object" and ((.success? == true) or (.is_error? == false) or (.isError? == false))' >/dev/null 2>&1 <<EOF
$response
EOF
  then
    status="succeeded"
    is_error="false"
  elif jq -e 'type == "string" and (startswith("Success. Updated the following files:"))' >/dev/null 2>&1 <<EOF
$response
EOF
  then
    status="succeeded"
    is_error="false"
  elif jq -e 'type == "string" and ((startswith("Error")) or (startswith("No files were modified.")))' >/dev/null 2>&1 <<EOF
$response
EOF
  then
    status="failed"
    is_error="true"
  elif [ "$tool_name" != "Read" ] && jq -e 'type == "string" and test("does not match|String to replace|no changes|Error:|tool_use_error|ENOENT|not found|has not been read"; "i")' >/dev/null 2>&1 <<EOF
$response
EOF
  then
    status="failed"
    is_error="true"
  fi

  jq -nc --arg status "$status" --argjson is_error "$is_error" --argjson output "$response" \
    '{status: $status, is_error: $is_error, output: $output}'
}

_ta_normalize_action() {
  local harness="$1" phase="$2" input="$3"
  local native_event cwd session_id turn_id action_id tool_name tool_input tool_response
  local family="unknown" coverage="none" targets='[]' diagnostics='[]' result

  printf '%s' "$input" | jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || return 1
  native_event=$(printf '%s' "$input" | jq -r '.hook_event_name // .type // ""') || return 1
  cwd=$(printf '%s' "$input" | jq -r '.cwd // ""') || return 1
  session_id=$(printf '%s' "$input" | jq -c '.session_id // null') || return 1
  turn_id=$(printf '%s' "$input" | jq -c '.turn_id // null') || return 1
  action_id=$(printf '%s' "$input" | jq -c '.tool_use_id // .toolCallId // null') || return 1
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // ""') || return 1
  tool_input=$(printf '%s' "$input" | jq -c '.tool_input // .input // {}') || return 1
  tool_response=$(printf '%s' "$input" | jq -c '.tool_response // .result // null') || return 1

  case "$tool_name" in
    apply_patch)
      family="file_mutation"
      # Replace directives with unsafe control characters before crossing the
      # JSON-to-shell boundary. Command substitution cannot preserve NUL bytes.
      local patch
      patch=$(printf '%s' "$tool_input" | jq -r '
        (.command // "") | select(type == "string") | split("\n") | map(
          if test("^\\*\\*\\* (Add File|Delete File|Update File|Move to): ") and
             (sub("^\\*\\*\\* (Add File|Delete File|Update File|Move to): "; "") |
              test("[\u0000-\u001f\u007f]"))
          then "*** Invalid Path Directive"
          else . end
        ) | join("\n")') || return 1
      _ta_parse_apply_patch "$patch" || return 1
      targets="$_ta_targets"
      diagnostics="$_ta_diagnostics"
      coverage="$_ta_coverage"
      ;;
    Edit|Write)
      family="file_mutation"
      local path operation
      path=$(printf '%s' "$tool_input" | jq -r '(.file_path // .filePath // .path // "") | select(type == "string" and (test("[\u0000-\u001f\u007f]") | not))') || return 1
      # A legacy Write can create or overwrite. Treat it conservatively as an
      # update; reread-guard exempts the target after confirming it is absent.
      operation="update"
      _ta_targets='[]'; _ta_diagnostics='[]'; _ta_complete=1
      _ta_add_target "$operation" "$path" || return 1
      targets="$_ta_targets"; diagnostics="$_ta_diagnostics"
      [ "$(printf '%s' "$targets" | jq 'length')" -gt 0 ] && coverage="complete"
      ;;
    MultiEdit)
      family="file_mutation"
      targets=$(printf '%s' "$tool_input" | jq -c '
        (.file_path // .filePath // .path // null) as $outer
        | [
            (if ($outer | type) == "string" and ($outer | length) > 0 and
                ($outer | test("[\u0000-\u001f\u007f]") | not)
             then $outer else empty end),
            ((.edits // [])[] | (.file_path // .filePath // .path // empty)
              | select(type == "string" and length > 0 and
                       (test("[\u0000-\u001f\u007f]") | not)))
          ] | unique | map({operation: "update", path: .})') || return 1
      [ "$(printf '%s' "$targets" | jq 'length')" -gt 0 ] && coverage="complete"
      ;;
    Read)
      family="file_read"
      local read_path
      read_path=$(printf '%s' "$tool_input" | jq -r '(.file_path // .filePath // .path // "") | select(type == "string" and (test("[\u0000-\u001f\u007f]") | not))') || return 1
      _ta_targets='[]'; _ta_diagnostics='[]'; _ta_complete=1
      _ta_add_target "read" "$read_path" || return 1
      targets="$_ta_targets"; diagnostics="$_ta_diagnostics"
      [ "$(printf '%s' "$targets" | jq 'length')" -gt 0 ] && coverage="complete"
      ;;
    Bash|exec_command)
      family="shell"
      ;;
    mcp__*)
      family="mcp"
      ;;
    "")
      # Older hook fixtures and pre-native Codex adapters omitted tool_name.
      # These hooks are registered only for file actions, so retain their
      # structured path without guessing at shell command contents.
      local legacy_path
      legacy_path=$(printf '%s' "$tool_input" | jq -r '(.file_path // .filePath // .path // "") | select(type == "string" and (test("[\u0000-\u001f\u007f]") | not))') || return 1
      if [ -n "$legacy_path" ]; then
        family="file_mutation"
        _ta_targets='[]'; _ta_diagnostics='[]'; _ta_complete=1
        _ta_add_target "update" "$legacy_path" || return 1
        targets="$_ta_targets"; diagnostics="$_ta_diagnostics"
        [ "$(printf '%s' "$targets" | jq 'length')" -gt 0 ] && coverage="complete"
      fi
      ;;
    *) family="local_tool" ;;
  esac

  result=$(_ta_result_json "$phase" "$tool_response" "$tool_name") || return 1
  jq -nc \
    --arg harness "$harness" --arg phase "$phase" --arg native_event "$native_event" \
    --arg cwd "$cwd" --argjson session_id "$session_id" --argjson turn_id "$turn_id" \
    --argjson action_id "$action_id" --arg tool_name "$tool_name" --arg family "$family" \
    --arg coverage "$coverage" --argjson targets "$targets" --argjson action_input "$tool_input" \
    --argjson diagnostics "$diagnostics" --argjson result "$result" \
    '{schema_version: 1, harness: $harness, phase: $phase, native_event: $native_event,
      cwd: $cwd, session_id: $session_id, turn_id: $turn_id,
      action: {id: $action_id, tool_name: $tool_name, family: $family,
        target_coverage: $coverage, targets: $targets, input: $action_input,
        diagnostics: $diagnostics}, result: $result}'
}

_ta_resolve_path() {
  local cwd="$1" target="$2"
  [ -n "$cwd" ] && [ -n "$target" ] || return 1
  case "$target" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
    /*) ;;
    *) target="$cwd/$target" ;;
  esac
  if type _se_normpath >/dev/null 2>&1; then
    _se_normpath "$target"
  else
    printf '%s\n' "$target"
  fi
}

_ta_targets_tsv() {
  local normalized="$1"
  printf '%s' "$normalized" | jq -jr '
    .action.targets[]
    | .operation, "\t", .path, "\t", (.destination // ""), "\n"
  '
}
