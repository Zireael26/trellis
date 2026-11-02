#!/usr/bin/env bash
# Normalize native harness tool events into the Trellis action envelope.
# Source this file, then call _ta_normalize_action <harness> <phase> <json>.
#
# The normalization is one jq program (_TA_JQ), so a hook pays one jq process
# for it, and the Codex guards take their fields from that same run
# (_ta_guard_fields). It prints, byte for byte, the envelope the earlier
# shell-and-jq normalizer printed; action-normalize.bats pins that against a
# golden corpus.

# Edit-family error-string markers for the post-action status. The guards pass
# the copy generated from core-rules/hooks/rules/reread.json; parity-tables
# in guard-rules.bats keep the two equal.
_TA_EDIT_FAILURE_RE='does not match|String to replace|no changes|Error:|tool_use_error|ENOENT|not found|has not been read'

# ta_r(f) is what `$(jq -r 'f')` kept: strings raw, other values as jq's
# indented JSON, NUL bytes dropped, trailing newlines stripped. The same helpers
# live in lib/guard-rules.sh as gr_*.
# shellcheck disable=SC2016  # jq source, not shell
_TA_JQ='
def ta_pp($i):
  if type == "array" then
    if length == 0 then "[]"
    else "[\n" + (map($i + "  " + ta_pp($i + "  ")) | join(",\n")) + "\n" + $i + "]" end
  elif type == "object" then
    if length == 0 then "{}"
    else "{\n" + (to_entries | map($i + "  " + (.key | tojson) + ": " + (.value | ta_pp($i + "  "))) | join(",\n")) + "\n" + $i + "}" end
  else tojson end;
def ta_nonul: split("\u0000") | join("");
def ta_rstripnl: if endswith("\n") then .[:-1] | ta_rstripnl else . end;
def ta_r(f): [f | (if type == "string" then . else ta_pp("") end) + "\n"] | add // "" | ta_nonul | ta_rstripnl;

def ta_target($operation; $path; $destination):
  if $path == "" then
    .diagnostics += ["empty file path in mutation directive"] | .complete = false
  elif ($path + $destination | test("[\t\n\r]")) then
    .diagnostics += ["file path contains a tab or line break"] | .complete = false
  elif $destination != "" then
    .targets += [{operation: $operation, path: $path, destination: $destination}]
  else
    .targets += [{operation: $operation, path: $path}]
  end;

def ta_complete_if_any: .coverage = (if .targets == [] then "none" else "complete" end);

def ta_one($family; $operation; $path):
  {family: $family, targets: [], diagnostics: [], complete: true}
  | ta_target($operation; $path; "") | ta_complete_if_any;

def ta_patch:
  reduce split("\n")[] as $line (
    {family: "file_mutation", targets: [], diagnostics: [], complete: true,
     begin: false, end: false, op: "", path: ""};
    if .begin | not then
      if $line == "*** Begin Patch" then .begin = true
      elif $line != "" then
        .diagnostics += ["apply_patch does not start with *** Begin Patch"] | .complete = false | .begin = true
      else . end
    elif .end then
      if $line != "" then .diagnostics += ["content follows *** End Patch"] | .complete = false else . end
    elif $line == "*** End Patch" then .end = true | .op = ""
    elif $line | startswith("*** Add File: ") then
      .op = "create" | .path = ($line | ltrimstr("*** Add File: ")) | ta_target("create"; .path; "")
    elif $line | startswith("*** Delete File: ") then
      .op = "delete" | .path = ($line | ltrimstr("*** Delete File: ")) | ta_target("delete"; .path; "")
    elif $line | startswith("*** Update File: ") then
      .op = "update" | .path = ($line | ltrimstr("*** Update File: ")) | ta_target("update"; .path; "")
    elif $line | startswith("*** Move to: ") then
      if .op != "update" or .path == "" then
        .diagnostics += ["*** Move to directive does not follow an update"] | .complete = false
      else
        ($line | ltrimstr("*** Move to: ")) as $destination
        | if $destination == "" then
            .diagnostics += ["empty destination in *** Move to directive"] | .complete = false
          elif ($destination | test("[\t\n\r]")) then
            .diagnostics += ["move destination contains a tab or line break"] | .complete = false
          else
            .targets |= (.[-1].operation = "rename" | .[-1].destination = $destination)
          end
        | .op = ""
      end
    elif $line == "*** End of File" then .op = ""
    elif $line | startswith("*** ") then
      .diagnostics += ["unknown apply_patch directive: " + $line] | .complete = false | .op = ""
    else . end)
  | if .begin then . else .diagnostics += ["apply_patch is empty"] | .complete = false end
  | if .end then . else .diagnostics += ["apply_patch does not end with *** End Patch"] | .complete = false end
  | .coverage = (if .targets == [] then "none" elif .complete then "complete" else "partial" end);

def ta_path:
  (.file_path // .filePath // .path // "")
  | select(type == "string" and (test("[\u0000-\u001f\u007f]") | not));

def ta_action($tool_name):
  if $tool_name == "apply_patch" then
    # Replace directives with unsafe control characters before they become
    # targets; NUL bytes never survived the old shell transport either.
    ta_r((.command // "") | select(type == "string") | split("\n") | map(
      if test("^\\*\\*\\* (Add File|Delete File|Update File|Move to): ") and
         (sub("^\\*\\*\\* (Add File|Delete File|Update File|Move to): "; "") |
          test("[\u0000-\u001f\u007f]"))
      then "*** Invalid Path Directive"
      else . end
    ) | join("\n")) | ta_patch
  elif $tool_name == "Edit" or $tool_name == "Write" then
    # A legacy Write can create or overwrite. Treat it conservatively as an
    # update; reread-guard exempts the target after confirming it is absent.
    ta_one("file_mutation"; "update"; ta_r(ta_path))
  elif $tool_name == "MultiEdit" then
    {family: "file_mutation", diagnostics: [], targets: (
      (.file_path // .filePath // .path // null) as $outer
      | [
          (if ($outer | type) == "string" and ($outer | length) > 0 and
              ($outer | test("[\u0000-\u001f\u007f]") | not)
           then $outer else empty end),
          ((.edits // [])[] | (.file_path // .filePath // .path // empty)
            | select(type == "string" and length > 0 and
                     (test("[\u0000-\u001f\u007f]") | not)))
        ] | unique | map({operation: "update", path: .}))}
    | ta_complete_if_any
  elif $tool_name == "Read" then
    ta_one("file_read"; "read"; ta_r(ta_path))
  elif $tool_name == "Bash" or $tool_name == "exec_command" then
    {family: "shell", coverage: "none", targets: [], diagnostics: []}
  elif $tool_name | startswith("mcp__") then
    {family: "mcp", coverage: "none", targets: [], diagnostics: []}
  elif $tool_name == "" then
    # Older hook fixtures and pre-native Codex adapters omitted tool_name.
    # These hooks are registered only for file actions, so retain their
    # structured path without guessing at shell command contents.
    ta_r(ta_path) as $path
    | if $path != "" then ta_one("file_mutation"; "update"; $path)
      else {family: "unknown", coverage: "none", targets: [], diagnostics: []} end
  else
    {family: "local_tool", coverage: "none", targets: [], diagnostics: []}
  end;

# A condition that errors counts as false, as it did under `jq -e`.
def ta_holds(f): try (if f then true else false end) catch false;

def ta_result($phase; $response; $tool_name; $markers; $flags):
  if $phase != "post_action" then null
  else
    ($response
     | if ta_holds(type == "object" and ((.is_error? == true) or (.isError? == true) or
                   ((.error? // "") != "") or ((.tool_use_error? // "") != "")))
       then ["failed", true]
       elif ta_holds(type == "object" and ((.success? == true) or (.is_error? == false) or (.isError? == false)))
       then ["succeeded", false]
       elif ta_holds(type == "string" and (startswith("Success. Updated the following files:")))
       then ["succeeded", false]
       elif ta_holds(type == "string" and ((startswith("Error")) or (startswith("No files were modified."))))
       then ["failed", true]
       elif $tool_name != "Read" and ta_holds(type == "string" and test($markers; $flags))
       then ["failed", true]
       else ["unknown", null] end) as [$status, $is_error]
    | {status: $status, is_error: $is_error, output: $response}
  end;

def ta_normalize($harness; $phase; $markers; $flags):
  ta_r(.tool_name // .toolName // "") as $tool_name
  | (.tool_input // .input // {}) as $tool_input
  | ($tool_input | ta_action($tool_name)) as $action
  | {schema_version: 1, harness: $harness, phase: $phase,
     native_event: ta_r(.hook_event_name // .type // ""),
     cwd: ta_r(.cwd // ""), session_id: (.session_id // null), turn_id: (.turn_id // null),
     action: {id: (.tool_use_id // .toolCallId // null), tool_name: $tool_name, family: $action.family,
       target_coverage: $action.coverage, targets: $action.targets, input: $tool_input,
       diagnostics: $action.diagnostics},
     result: ta_result($phase; (.tool_response // .result // null); $tool_name; $markers; $flags)};

def ta_one_object:
  if length == 1 and (.[0] | type == "object") then .[0] else error("not exactly one object") end;
'

_ta_normalize_action() {
  printf '%s' "$3" | jq -cs --arg harness "$1" --arg phase "$2" --arg markers "$_TA_EDIT_FAILURE_RE" \
    "$_TA_JQ"' ta_one_object | ta_normalize($harness; $phase; $markers; "i")' 2>/dev/null || return 1
}

# _ta_guard_fields <phase> <json> <edit-failure-re> <re-flags>
#   One jq run that normalizes a Codex event and hands a guard its fields:
#   TA_FAMILY, TA_COVERAGE, TA_DIAGNOSTIC (the first diagnostic, or "mutation
#   targets are unavailable"), TA_CWD, TA_STATUS, the raw event's TA_TP
#   (transcript_path) and TA_SID (session_id), and the targets as parallel
#   arrays TA_OPS, TA_PATHS and TA_DESTS. Each value reads as the guards read it
#   before, through `$(jq -r ...)`. Fails, as _ta_normalize_action does, unless
#   the input is exactly one JSON object.
# shellcheck disable=SC2034  # TA_* are read by the guards that source this
_ta_guard_fields() {
  local tok n i=0
  TA_OPS=() TA_PATHS=() TA_DESTS=()
  {
    IFS= read -r -d '' n || return 1
    case $n in ''|*[!0-9]*) return 1 ;; esac
    while [ "$i" -lt "$n" ]; do
      IFS= read -r -d '' tok || return 1
      case $i in
        0) TA_FAMILY=$tok ;;
        1) TA_COVERAGE=$tok ;;
        2) TA_DIAGNOSTIC=$tok ;;
        3) TA_CWD=$tok ;;
        4) TA_STATUS=$tok ;;
        5) TA_TP=$tok ;;
        6) TA_SID=$tok ;;
        *)
          case $(((i - 7) % 3)) in
            0) TA_OPS[${#TA_OPS[@]}]=$tok ;;
            1) TA_PATHS[${#TA_PATHS[@]}]=$tok ;;
            2) TA_DESTS[${#TA_DESTS[@]}]=$tok ;;
          esac
          ;;
      esac
      i=$((i + 1))
    done
  } < <(printf '%s' "$2" | jq -js --arg phase "$1" --arg markers "$3" --arg flags "$4" "$_TA_JQ"'
      ta_one_object | . as $in | ta_normalize("codex"; $phase; $markers; $flags) as $n
      | [$n.action.family, $n.action.target_coverage,
         ta_r($n.action.diagnostics[0] // "mutation targets are unavailable"),
         $n.cwd, ta_r($n.result.status), ($in | ta_r(.transcript_path // empty)),
         ($in | ta_r(.session_id // empty))]
        + [$n.action.targets[] | .operation, .path, (.destination // "")]
      | [length | tostring] + . | map(ta_nonul + "\u0000") | add' 2>/dev/null)
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
