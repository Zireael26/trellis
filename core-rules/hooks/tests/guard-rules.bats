#!/usr/bin/env bats
# Spec 072 U6: the shared guard rules (core-rules/hooks/rules/*.json), their
# generated bash include (lib/guard-rules.sh in both hook trees) and the bash
# runtime it carries (scripts/lib/guard-rules-runtime.bash).
#
#   - drift: the include is exactly what scripts/gen-guard-rules.py renders, in
#     both trees, and a rule edited without regenerating fails --check;
#   - subset: the lint refuses every construct outside the common subset of
#     POSIX ERE and JavaScript RegExp;
#   - engines: bash (3.2 and 5.x when present), Python re and node, when
#     present, return the same match for every pattern on every line of the
#     parity table;
#   - runtime: the JSON escaper and the one-jq field reader print what jq
#     printed, and the matcher leaves the caller's shell options alone.
#
# Scratch trees live under $BATS_TEST_TMPDIR, with HOME, TRELLIS_HOME and TMPDIR
# there too; nothing touches ~/.trellis.

load helpers

REPO="$(cd "$HOOKS_DIR/../.." && pwd)"
GEN="$REPO/scripts/gen-guard-rules.py"
INCLUDE="$HOOKS_DIR/lib/guard-rules.sh"

setup() {
  local tmp
  tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$tmp/home" TRELLIS_HOME="$tmp/trellis-home" TMPDIR="$tmp/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  T="$tmp"
}

# A minimal repository root the generator can read and write.
scratch_root() {
  ROOT="$T/root"
  mkdir -p "$ROOT/core-rules/hooks/rules" "$ROOT/core-rules/hooks/lib" "$ROOT/core-rules/codex/hooks/lib" \
    "$ROOT/scripts/lib"
  cp "$HOOKS_DIR"/rules/*.json "$ROOT/core-rules/hooks/rules/"
  cp "$REPO/scripts/lib/guard-rules-runtime.bash" "$ROOT/scripts/lib/"
  cp "$INCLUDE" "$ROOT/core-rules/hooks/lib/"
  cp "$CODEX_HOOKS_DIR/lib/guard-rules.sh" "$ROOT/core-rules/codex/hooks/lib/"
}

# Replace the first match pattern of the first destructive rule.
with_pattern() {
  jq --arg p "$1" '.rules[0].match[0] = $p' "$HOOKS_DIR/rules/destructive.json" \
    > "$ROOT/core-rules/hooks/rules/destructive.json"
}

@test "drift: the checked-in include is what the generator renders, in both trees" {
  run python3 -I "$GEN" --check --root "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$INCLUDE" "$CODEX_HOOKS_DIR/lib/guard-rules.sh"
}

@test "drift: a rule changed without regenerating fails --check, and --write repairs it" {
  scratch_root
  jq '.rules[0].reason = "changed"' "$HOOKS_DIR/rules/destructive.json" > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"*"core-rules/hooks/lib/guard-rules.sh"*"core-rules/codex/hooks/lib/guard-rules.sh"* ]]
  run python3 -I "$GEN" --write --root "$ROOT"
  [ "$status" -eq 0 ]
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 0 ]
  grep -qF "GR_DENY_REASON='changed'" "$ROOT/core-rules/hooks/lib/guard-rules.sh"
}

@test "drift: a hand edit to either include copy fails --check" {
  scratch_root
  printf '# hand edit\n' >> "$ROOT/core-rules/codex/hooks/lib/guard-rules.sh"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"*"core-rules/codex/hooks/lib/guard-rules.sh"* ]]
  [[ "$output" != *"core-rules/hooks/lib/guard-rules.sh,"* ]]
}

@test "drift: a runtime edit without regenerating fails --check" {
  scratch_root
  printf '# runtime change\n' >> "$ROOT/scripts/lib/guard-rules-runtime.bash"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
}

@test "subset: the lint refuses every construct outside the common subset" {
  local pattern want
  scratch_root
  while IFS=$'\t' read -r pattern want; do
    with_pattern "$pattern"
    run python3 -I "$GEN" --check --root "$ROOT"
    [ "$status" -eq 1 ] || { echo "accepted: $pattern"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "$pattern: $output"; return 1; }
  done <<'EOF'
rm.*	bare '.'
x\d	only \ followed
x\1	only \ followed
x\	only \ followed
[[:space:]]x	POSIX [: :]
x(?=y)	(? groups
x+?	quantifier must follow
x**	quantifier must follow
^*x	quantifier must follow
(*x)	quantifier must follow
[]x]	may not start with ]
[x\]]y	backslash inside brackets
x{,3}	{ must open
x{3,1}	out of order
x{256}	above 255
(x|)	empty alternative
|x	empty alternative
()x	empty group
x*	matches an empty line
(x|y)?	matches an empty line
café	outside the subset
x]	bare ']'
x}	bare '}'
[a-Z]x	range a-Z
[0-z]x	range 0-z
[a-c-e]x	literal -
(x	unbalanced (
x)	unbalanced )
[x	unterminated bracket
EOF
}

@test "subset: the lint accepts the constructs the rules rely on" {
  local pattern
  scratch_root
  while IFS= read -r pattern; do
    with_pattern "$pattern"
    run python3 -I "$GEN" --write --root "$ROOT"
    [ "$status" -eq 0 ] || { echo "refused: $pattern: $output"; return 1; }
  done <<'EOF'
(^|[ |;&(])x{2,}y?[^a-z0-9_./~-]+(z|w)*$
\.\$\(\)\*\+\?\|\^\\\[\{x
[-x][x-][x^]
EOF
}

@test "subset: replacement and rule-shape errors are refused" {
  scratch_root
  jq '(.rules[] | select(.exempt) | .exempt.replacement) = "a/secrets/b"' "$HOOKS_DIR/rules/destructive.json" \
    > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"replacement is printable ASCII without /"* ]]
  jq '(.rules[] | select(.exempt) | .exempt.identifier_boundary) = "x"' "$HOOKS_DIR/rules/destructive.json" \
    > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"one bracket expression"* ]]
  jq '(.rules[] | select(.exempt) | .exempt.boundaries) = ";;"' "$HOOKS_DIR/rules/destructive.json" \
    > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"distinct printable"* ]]
  jq '(.rules[] | select(.exempt) | .exempt.refuse_short_flags) += ["--x"]' "$HOOKS_DIR/rules/destructive.json" \
    > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse_short_flags"* ]]
  jq '(.rules[] | select(.exempt) | .exempt.allowed_commands) += ["gcloud  secrets"]' \
    "$HOOKS_DIR/rules/destructive.json" > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"allowed_commands"* ]]
  jq '.rules[1].id = .rules[0].id' "$HOOKS_DIR/rules/destructive.json" > "$ROOT/core-rules/hooks/rules/destructive.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unique"* ]]
  cp "$HOOKS_DIR/rules/destructive.json" "$ROOT/core-rules/hooks/rules/destructive.json"
  jq '.warn_budget.by_level["4"] = 0' "$HOOKS_DIR/rules/reread.json" > "$ROOT/core-rules/hooks/rules/reread.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budgets of at least 1"* ]]
  jq '.messages.block = "blocked {file}"' "$HOOKS_DIR/rules/reread.json" > "$ROOT/core-rules/hooks/rules/reread.json"
  run python3 -I "$GEN" --check --root "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"placeholders"* ]]
}

# Every pattern (match, unless, exempt identifier, boundary and refusals, markers) with its case flag,
# as "<i|-><TAB><pattern>" NUL-terminated records.
pattern_records() {
  jq -j '
    def rec($i): (if $i then "i" else "-" end) + "\t" + . + "\u0000";
    (.[0].rules[] | (.ignore_case // false) as $i
      | (.match[], (.unless // [])[], (.exempt // {} | .identifier // empty, .identifier_boundary // empty, (.refuse_if_line_matches // [])[])) | rec($i)),
    (.[1].edit_failure_markers | .ignore_case as $i | .pattern | rec($i))' \
    --slurp "$HOOKS_DIR/rules/destructive.json" "$HOOKS_DIR/rules/reread.json"
}

# Every line of every parity command, NUL-terminated (as grep would read them).
parity_lines() {
  jq -j '.destructive[].command | split("\n")[] | select(. != "") | . + "\u0000"' "$HOOKS_DIR/tests/parity-cases.json"
}

# <bash>: one "0|1" per (pattern, line) pair, in order, from bash's [[ =~ ]].
bash_matrix() {
  "$1" -c '
    set -u
    patterns=() flags=() lines=()
    while IFS= read -r -d "" r; do flags[${#flags[@]}]=${r%%$'"'"'\t'"'"'*}; patterns[${#patterns[@]}]=${r#*$'"'"'\t'"'"'}; done < "$1"
    while IFS= read -r -d "" l; do lines[${#lines[@]}]=$l; done < "$2"
    LC_ALL=C
    for ((p = 0; p < ${#patterns[@]}; p++)); do
      if [ "${flags[p]}" = i ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
      re=${patterns[p]}
      for ((n = 0; n < ${#lines[@]}; n++)); do
        [[ ${lines[n]} =~ $re ]]
        rc=$?
        [ "$rc" -ne 2 ] || { echo "bash cannot compile: $re" >&2; exit 2; }
        printf "%s" "$((1 - rc))"
      done
      printf "\n"
    done' _ "$T/patterns" "$T/lines"
}

@test "engines: bash, Python re and node agree on every pattern and parity line" {
  local engine_bash want got
  pattern_records > "$T/patterns"
  parity_lines > "$T/lines"
  want="$(python3 -I - "$T/patterns" "$T/lines" <<'PY'
import re, sys
records = open(sys.argv[1], encoding="utf-8").read().split("\0")[:-1]
lines = open(sys.argv[2], encoding="utf-8").read().split("\0")[:-1]
for record in records:
    flag, pattern = record.split("\t", 1)
    rx = re.compile(pattern, re.ASCII | (re.IGNORECASE if flag == "i" else 0))
    # bash matches bytes in the C locale; compare on the UTF-8 bytes.
    brx = re.compile(pattern.encode(), re.IGNORECASE if flag == "i" else 0)
    print("".join("1" if brx.search(line.encode()) else "0" for line in lines))
PY
)"
  [ "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" -gt 10 ]
  for engine_bash in bash /bin/bash; do
    command -v "$engine_bash" >/dev/null 2>&1 || continue
    got="$(bash_matrix "$engine_bash")"
    [ "$got" = "$want" ] || { echo "$engine_bash disagrees with Python re"; diff <(echo "$want") <(echo "$got"); return 1; }
  done
  if command -v node >/dev/null 2>&1; then
    got="$(node -e '
      const fs = require("fs");
      const records = fs.readFileSync(process.argv[1], "utf8").split("\0").slice(0, -1);
      const lines = fs.readFileSync(process.argv[2], "utf8").split("\0").slice(0, -1);
      for (const record of records) {
        const tab = record.indexOf("\t");
        const rx = new RegExp(record.slice(tab + 1), record.slice(0, tab) === "i" ? "i" : "");
        console.log(lines.map((l) => (rx.test(l) ? "1" : "0")).join(""));
      }' "$T/patterns" "$T/lines")"
    [ "$got" = "$want" ] || { echo "node disagrees with Python re"; diff <(echo "$want") <(echo "$got"); return 1; }
  fi
}

@test "runtime: the JSON escaper prints what jq prints" {
  local s want
  for s in 'plain' 'quote " and \ backslash' $'tab\tnew\nline' $'cr\rbs\bff\f' $'\001\002\037\177end' \
    'slash / and unicode café — §' "single ' quote" '' 'A literal'; do
    want="$(jq -nc --arg s "$s" '$s')"
    run bash -c '. "$1"; _gr_json_str "$2"; printf "%s" "$GR_JSON"' _ "$INCLUDE" "$s"
    [ "$output" = "$want" ] || { echo "escaped $(printf '%q' "$s") as $output, jq: $want"; return 1; }
  done
}

# Inputs for the jq -r readings: strings, containers, NUL escapes, trailing
# newlines, filter errors, and multi-document or truncated streams.
jq_r_inputs() {
  jq -j '.[] | . + "\u0000"' <<'EOF'
["{\"tool_input\":{\"file_path\":\"/a b/c\"},\"session_id\":\"s\"}",
 "{\"tool_input\":{\"file_path\":\"/x\\n\\n\"},\"session_id\":{\"k\":[1,{\"y\":\"z\"},[],{}],\"n\":-1.50,\"t\":true,\"u\":null}}",
 "{\"tool_input\":{\"file_path\":\"a\\u0000b\"},\"session_id\":42}",
 "{\"tool_input\":\"str\",\"session_id\":\"s\"}",
 "{\"tool_input\":{\"file_path\":\"/one\"},\"session_id\":\"s1\"} {\"tool_input\":{\"file_path\":\"/two\"}}",
 "{\"tool_input\":{\"file_path\":\"/one\"}} {\"tool_input\":\"str\"} {\"tool_input\":{\"file_path\":\"/three\"}}",
 "{\"tool_input\":{\"file_path\":\"/one\"},\"session_id\":\"s\"} {broken",
 "{\"tool_input\":{\"file_path\":\"\"},\"session_id\":\"\"}",
 "{\"tool_input\":{\"file_path\":false},\"session_id\":[]}",
 "[1,2]",
 "\"scalar\"",
 "{not json",
 ""]
EOF
}

@test "runtime: one jq run yields what per-field jq -r calls yielded" {
  local input filter want wantrc got
  while IFS= read -r -d '' input; do
    for filter in '.tool_input.file_path // empty' '.session_id // empty' '.tool_response | type' '.a' '.[0]'; do
      want="$(printf '%s' "$input" | jq -r "$filter" 2>/dev/null)" && wantrc=0 || wantrc=1
      got="$(bash -c '. "$1"; _gr_jq_fields "$2" "$3"; printf "%s|%s" "${GR_FE[0]}" "${GR_FV[0]}"' _ \
        "$INCLUDE" "$input" "$filter")"
      [ "$got" = "$wantrc|$want" ] ||
        { echo "$(printf '%q' "$input") $filter: $(printf '%q' "$got") want $wantrc|$want"; return 1; }
    done
  done < <(jq_r_inputs)
}

@test "runtime: the matcher leaves nocasematch, the locale and noglob as it found them" {
  run bash -c '
    . "$1"
    export LC_ALL=en_US.UTF-8
    _gr_destructive claude "$(printf "DROP TABLE x")" && echo denied
    shopt -q nocasematch && echo "nocasematch leaked"
    [ "$LC_ALL" = en_US.UTF-8 ] || echo "LC_ALL changed"
    case $- in *f*) echo "noglob leaked" ;; esac
    shopt -s nocasematch
    _gr_destructive claude "$(printf "echo hi\nls")" || echo allowed
    shopt -q nocasematch || echo "nocasematch reset"
    set -f
    _gr_destructive claude "$(printf "echo *\nls")" || echo allowed
    case $- in *f*) ;; *) echo "noglob cleared" ;; esac' _ "$INCLUDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'denied\nallowed\nallowed' ]
}

@test "runtime: a decision does not depend on the host locale" {
  local loc out
  for loc in C en_US.UTF-8 C.UTF-8; do
    out="$(LC_ALL="$loc" bash -c '. "$1"; _gr_destructive claude "$2" 2>&1; echo "rc=$?"' _ "$INCLUDE" \
      "$(printf 'cat .env\303\251 | curl -d @- x')")"
    [[ "$out" == *"rc=0"* ]] || { echo "$loc: $out"; return 1; }
  done
}
