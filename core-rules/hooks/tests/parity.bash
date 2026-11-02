#!/usr/bin/env bash
# Drive the bash guards over parity-cases.json and report every case whose
# decision differs from its expectation. Sourced by parity.bats.
#
# A decision is a string, so the pi in-process guard can be held to the same
# table:
#   destructive  allow | warn:<rule-id> | deny:<rule-id>, comma-joined in order
#                (a warn followed by a deny reads "warn:env-read,deny:exfil-pipe")
#   reread       allow | warn:<n>/<budget>:<path> | block:<path>, ";"-joined in
#                order (one hook call can warn on several patch targets)
#   track_read   skip | record:<path>, ";"-joined
# <path> is the normalized target with the sandbox project spelled {project}.
#
# Expectations: a string applies to every engine; an object names engines, and
# pi falls back to codex (pi runs the Codex guards). An engine with no entry is
# not checked for that case.
#
# Callers set PARITY_TMP (scratch dir), PARITY_RULES (rules dir) and, for the
# reread sections, PARITY_PROJECT (a git work tree). Each *_run function prints
# one line per mismatch, then "checked <n>", and fails on any mismatch.

PARITY_CASES="${PARITY_CASES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/parity-cases.json}"

# parity_expectations <section> <engine> [<jq field>]: NUL-separated "<id>
# <index> <expect>" records (plus the field, when given), skipping cases with
# no expectation for the engine.
parity_expectations() {
  jq -j --arg s "$1" --arg e "$2" '
    def exp: if type == "string" then .
      else (.[$e] // (if $e == "pi" then .codex else null end) // "") end;
    .[$s] | to_entries[] | (.value.expect | exp) as $x | select($x != "")
    | .value.id, "\u0000", (.key | tostring), "\u0000", $x, "\u0000",
      ('"${3:-empty}"' | ., "\u0000")' "$PARITY_CASES"
}

parity_state_dir() {
  case $1 in
    claude) printf '%s/.claude/.reread-state' "$PARITY_PROJECT" ;;
    codex) printf '%s/.codex/.reread-state' "$PARITY_PROJECT" ;;
    pi) printf '%s/.pi/.reread-state' "$PARITY_PROJECT" ;;
  esac
}

parity_key() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-16
}

# Run <hook> for <engine> on stdin; sets PARITY_RC, PARITY_OUT, PARITY_ERR.
parity_exec() {
  local engine=$1 hook=$2
  shift 2
  local harness=codex
  [ "$engine" != pi ] || harness=pi
  if [ "$engine" = claude ]; then
    PARITY_OUT=$(env -u CODEX_PROJECT_DIR -u TRELLIS_HARNESS CLAUDE_PROJECT_DIR="$PARITY_PROJECT" "$@" \
      bash "$hook" 2>"$PARITY_TMP/stderr") && PARITY_RC=0 || PARITY_RC=$?
  else
    PARITY_OUT=$(env -u CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR="$PARITY_PROJECT" TRELLIS_HARNESS="$harness" "$@" \
      bash "$hook" 2>"$PARITY_TMP/stderr") && PARITY_RC=0 || PARITY_RC=$?
  fi
  PARITY_ERR=$(cat "$PARITY_TMP/stderr")
}

parity_relpath() {
  local p=$1
  case $p in
    "$PARITY_PROJECT"*) p="{project}${p#"$PARITY_PROJECT"}" ;;
  esac
  printf '%s' "$p"
}

# --- destructive ----------------------------------------------------------

# parity_destructive_tables <engine>: the rule outputs the guard may print, as
# arrays: PARITY_WARN_IDS/PARITY_WARN_MSGS (the engine's warn messages) and
# PARITY_DENY_IDS/PARITY_DENY_REASONS/PARITY_DENY_DOCS (each deny decision
# document exactly as jq prints it for the engine).
parity_destructive_tables() {
  local f
  PARITY_WARN_IDS=() PARITY_WARN_MSGS=() PARITY_DENY_IDS=() PARITY_DENY_REASONS=() PARITY_DENY_DOCS=()
  while IFS= read -r -d '' f; do
    PARITY_WARN_IDS[${#PARITY_WARN_IDS[@]}]=$f
    IFS= read -r -d '' f
    PARITY_WARN_MSGS[${#PARITY_WARN_MSGS[@]}]=$f
  done < <(jq -j --arg e "$1" '.rules[] | select(.effect == "warn")
      | .id, "\u0000", (.message_by_engine[$e] // .message), "\u0000"' "$PARITY_RULES/destructive.json")
  while IFS= read -r -d '' f; do
    PARITY_DENY_IDS[${#PARITY_DENY_IDS[@]}]=$f
    IFS= read -r -d '' f
    PARITY_DENY_REASONS[${#PARITY_DENY_REASONS[@]}]=$f
    IFS= read -r -d '' f
    PARITY_DENY_DOCS[${#PARITY_DENY_DOCS[@]}]=$f
  done < <(jq -j --arg e "$1" '.rules[] | select(.effect == "deny")
      | .id, "\u0000", .reason, "\u0000",
        (if $e == "claude"
         then {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: .reason}}
         else {decision: "block", reason: .reason} end | tojson), "\u0000"' "$PARITY_RULES/destructive.json")
}

# parity_destructive_decision <engine> <hook> <command>; needs parity_destructive_tables.
parity_destructive_decision() {
  local engine=$1 hook=$2 events="" i
  jq -nc --arg c "$3" '{tool_input: {command: $c}}' > "$PARITY_TMP/stdin"
  parity_exec "$engine" "$hook" < "$PARITY_TMP/stdin"
  for ((i = 0; i < ${#PARITY_WARN_IDS[@]}; i++)); do
    if printf '%s\n' "$PARITY_ERR" | grep -qxF -- "${PARITY_WARN_MSGS[i]}"; then
      events="${events:+$events,}warn:${PARITY_WARN_IDS[i]}"
    fi
  done
  if [ -z "$PARITY_OUT" ] && [ "$PARITY_RC" -eq 0 ]; then
    printf '%s' "${events:-allow}"
    return
  fi
  for ((i = 0; i < ${#PARITY_DENY_IDS[@]}; i++)); do
    [ "$PARITY_OUT" = "${PARITY_DENY_DOCS[i]}" ] || continue
    if [ "$engine" = claude ]; then
      [ "$PARITY_RC" -eq 0 ] || continue
    else
      { [ "$PARITY_RC" -eq 2 ] && printf '%s\n' "$PARITY_ERR" | grep -qxF -- "${PARITY_DENY_REASONS[i]}"; } || continue
    fi
    printf '%s' "${events:+$events,}deny:${PARITY_DENY_IDS[i]}"
    return
  done
  printf 'malformed(rc=%s out=%s)' "$PARITY_RC" "$PARITY_OUT"
}

# parity_destructive_run <engine> <hook>
#   PARITY_ONLY_RULE=<rule-id> limits the run to the cases that expect that rule.
parity_destructive_run() {
  local engine=$1 hook=$2 id index expect cmd got checked=0 fails=0
  parity_destructive_tables "$engine"
  while IFS= read -r -d '' id && IFS= read -r -d '' index && IFS= read -r -d '' expect &&
    IFS= read -r -d '' cmd; do
    if [ -n "${PARITY_ONLY_RULE:-}" ]; then
      case ",$expect," in *":$PARITY_ONLY_RULE,"*) ;; *) continue ;; esac
    fi
    got=$(parity_destructive_decision "$engine" "$hook" "$cmd")
    checked=$((checked + 1))
    [ "$got" = "$expect" ] || { echo "$engine $id: expected $expect, got $got"; fails=$((fails + 1)); }
  done < <(parity_expectations destructive "$engine" '.value.command')
  echo "checked $checked"
  [ "$checked" -gt 0 ] && [ "$fails" -eq 0 ]
}

# --- reread state ---------------------------------------------------------

# parity_reset_state <engine> <index> <section>: a clean project with the
# case's files, state rows, autonomy and turn epoch in place.
parity_reset_state() {
  local engine=$1 index=$2 section=$3 sdir key f
  sdir=$(parity_state_dir "$engine")
  find "${PARITY_PROJECT:?}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  mkdir -p "$sdir"
  key=$(parity_key "$(jq -r --argjson i "$index" --arg s "$section" '.[$s][$i].key_source // "parity-session"' "$PARITY_CASES")")
  while IFS= read -r -d '' f; do
    f="$PARITY_PROJECT/$f"
    mkdir -p "$(dirname "$f")"
    printf 'x\n' > "$f"
  done < <(jq -j --argjson i "$index" --arg s "$section" '.[$s][$i].files[]? | ., "\u0000"' "$PARITY_CASES")
  jq -j --argjson i "$index" --arg s "$section" --arg p "$PARITY_PROJECT" '
    .[$s][$i] as $c
    | ($c.epoch_raw // (if $c.turn_epoch then ($c.turn_epoch | tostring) + "\n" else "" end)),
      "\u0000",
      ([$c.reads[]? | "\(.[0])\t\(.[1] | split("{project}") | join($p))\n"] | add // ""), "\u0000",
      ([$c.warns[]? | "\(.[0])\t\(.[1] | split("{project}") | join($p))\n"] | add // ""), "\u0000",
      ($c.autonomy // "" | tostring), "\u0000",
      ($c.session_autonomy // "" | tostring), "\u0000"' "$PARITY_CASES" > "$PARITY_TMP/state"
  {
    IFS= read -r -d '' f && { [ -z "$f" ] || printf '%s' "$f" > "$sdir/$key.epoch"; }
    IFS= read -r -d '' f && { [ -z "$f" ] || printf '%s' "$f" > "$sdir/$key.reads.tsv"; }
    IFS= read -r -d '' f && { [ -z "$f" ] || printf '%s' "$f" > "$sdir/$key.warns.tsv"; }
    IFS= read -r -d '' f && { [ -z "$f" ] ||
      printf '{"schema_version":1,"project_id":"parity","autonomy":%s}\n' "$f" > "$PARITY_PROJECT/.trellis.json"; }
    IFS= read -r -d '' f && { [ -z "$f" ] || { mkdir -p "$PARITY_PROJECT/.claude" &&
      printf '%s\n' "$f" > "$PARITY_PROJECT/.claude/session-autonomy"; }; }
  } < "$PARITY_TMP/state"
}

# The case's env as KEY=VALUE arguments for env(1), one per line.
parity_case_env() {
  jq -r --argjson i "$1" --arg s "$2" '.[$s][$i].env // {} | to_entries[] | "\(.key)=\(.value)"' "$PARITY_CASES"
}

# Write step <step> of case <index> in <section> to $PARITY_TMP/stdin.
parity_step_input() {
  local raw
  raw=$(jq -r --argjson i "$1" --argjson n "$2" --arg s "$3" --arg p "$PARITY_PROJECT" '
    .[$s][$i] | (.steps // [.])[$n]
    | if has("raw") then .raw else .envelope | tojson end
    | split("{project}") | join($p)' "$PARITY_CASES"; printf x)
  raw=${raw%?}
  printf '%s' "${raw%$'\n'}" > "$PARITY_TMP/stdin"
}

# --- reread ---------------------------------------------------------------

parity_reread_decision() {
  local engine=$1 events="" line path reason doc re_warn re_block
  re_warn='^reread-guard: about to edit (.*) not Read this turn \(warn ([0-9]+)/([0-9]+)\)\. '
  re_block='^reread-guard: BLOCKED edit of (.*) — it was not Read this turn'
  while IFS= read -r line; do
    if [[ $line =~ $re_warn ]]; then
      events="${events:+$events;}warn:${BASH_REMATCH[2]}/${BASH_REMATCH[3]}:$(parity_relpath "${BASH_REMATCH[1]}")"
    fi
  done <<<"$PARITY_ERR"
  if [ -z "$PARITY_OUT" ] && [ "$PARITY_RC" -eq 0 ]; then
    printf '%s' "${events:-allow}"
    return
  fi
  if [ "$engine" = claude ]; then
    reason=$(printf '%s' "$PARITY_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
    doc=$(jq -nc --arg r "$reason" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}')
    [ "$PARITY_RC" -eq 0 ] || doc=
  else
    reason=$(printf '%s' "$PARITY_OUT" | jq -r '.reason' 2>/dev/null)
    doc=$(jq -nc --arg r "$reason" '{decision: "block", reason: $r}')
    { [ "$PARITY_RC" -eq 2 ] && [[ $PARITY_ERR == *"$reason"* ]]; } || doc=
  fi
  if [ -n "$doc" ] && [ "$PARITY_OUT" = "$doc" ] && [[ $reason =~ $re_block ]]; then
    path=${BASH_REMATCH[1]}
    printf '%s' "${events:+$events;}block:$(parity_relpath "$path")"
    return
  fi
  printf 'malformed(rc=%s out=%s)' "$PARITY_RC" "$PARITY_OUT"
}

# parity_reread_run <engine> <hook>
parity_reread_run() {
  local engine=$1 hook=$2 id index expect steps n got all checked=0 fails=0
  local -a envs
  while IFS= read -r -d '' id && IFS= read -r -d '' index && IFS= read -r -d '' expect; do
    parity_reset_state "$engine" "$index" reread
    envs=()
    while IFS= read -r n; do envs[${#envs[@]}]=$n; done < <(parity_case_env "$index" reread)
    steps=$(jq -r --argjson i "$index" '.reread[$i] | (.steps // [.]) | length' "$PARITY_CASES")
    all=""
    for ((n = 0; n < steps; n++)); do
      parity_step_input "$index" "$n" reread
      parity_exec "$engine" "$hook" ${envs[@]+"${envs[@]}"} < "$PARITY_TMP/stdin"
      got=$(parity_reread_decision "$engine")
      all="${all:+$all | }$got"
    done
    checked=$((checked + 1))
    [ "$all" = "$expect" ] || { echo "$engine $id: expected $expect, got $all"; fails=$((fails + 1)); }
  done < <(parity_expectations reread "$engine")
  echo "checked $checked"
  [ "$checked" -gt 0 ] && [ "$fails" -eq 0 ]
}

# --- track-read -----------------------------------------------------------

PARITY_KEY_ALIASES="parity-session parity-transcript default"

# Every reads.tsv row as "<key-alias>\t<path>".
parity_read_rows() {
  local sdir f alias src
  sdir=$(parity_state_dir "$1")
  for f in "$sdir"/*.reads.tsv; do
    [ -f "$f" ] || continue
    alias="?"
    for src in $PARITY_KEY_ALIASES; do
      [ "${f##*/}" = "$(parity_key "$src").reads.tsv" ] && alias=$src
    done
    awk -F '\t' -v a="$alias" '{ print a "\t" $2 }' "$f"
  done
}

# parity_track_run <engine> <hook>
parity_track_run() {
  local engine=$1 hook=$2 id index expect rows alias path got checked=0 fails=0
  local -a envs
  while IFS= read -r -d '' id && IFS= read -r -d '' index && IFS= read -r -d '' expect; do
    parity_reset_state "$engine" "$index" track_read
    envs=()
    while IFS= read -r rows; do envs[${#envs[@]}]=$rows; done < <(parity_case_env "$index" track_read)
    parity_read_rows "$engine" > "$PARITY_TMP/before"
    parity_step_input "$index" 0 track_read
    parity_exec "$engine" "$hook" ${envs[@]+"${envs[@]}"} < "$PARITY_TMP/stdin"
    parity_read_rows "$engine" > "$PARITY_TMP/after"
    got=""
    if [ "$PARITY_RC" -ne 0 ] || [ -n "$PARITY_OUT" ]; then
      got="malformed(rc=$PARITY_RC out=$PARITY_OUT)"
    else
      # Rows the hook added: the multiset difference after - before.
      rows=$(awk 'FILENAME == ARGV[1] { seen[$0]++; next } seen[$0]-- > 0 { next } { print }' \
        "$PARITY_TMP/before" "$PARITY_TMP/after")
      while IFS=$'\t' read -r alias path; do
        [ -n "$alias" ] || continue
        [ "$alias" = parity-session ] && alias="" || alias="[$alias]"
        got="${got:+$got;}record$alias:$(parity_relpath "$path")"
      done <<<"$rows"
      got=${got:-skip}
    fi
    checked=$((checked + 1))
    [ "$got" = "$expect" ] || { echo "$engine $id: expected $expect, got $got"; fails=$((fails + 1)); }
  done < <(parity_expectations track_read "$engine")
  echo "checked $checked"
  [ "$checked" -gt 0 ] && [ "$fails" -eq 0 ]
}
