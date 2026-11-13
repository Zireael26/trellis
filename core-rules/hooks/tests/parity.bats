#!/usr/bin/env bats
# Spec 072 U6: one decision table, parity-cases.json, for every bright-line
# guard path. Each test runs the table through one guard as one engine and
# lists every case whose decision differs; parity.bash holds the decision
# grammar. The pi in-process guard runs the same table under node --test.
#
# The guards run from a copy of both hook trees with TRELLIS_ROOT on it, as an
# attached runtime runs them (the Codex shared-lib fallback is bound to
# TRELLIS_ROOT, spec 055 R1.1), and with no fleet config, so autonomy comes
# only from each case. HOME, TRELLIS_HOME and TMPDIR live under
# $BATS_TEST_TMPDIR; nothing touches ~/.trellis.

load helpers

REPO="$(cd "$HOOKS_DIR/../.." && pwd)"

setup() {
  local tmp
  tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$tmp/home" TRELLIS_HOME="$tmp/trellis-home" TMPDIR="$tmp/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR TRELLIS_HARNESS TRELLIS_REREAD_OVERRIDE TRELLIS_NO_JQ_DEGRADE
  RT="$tmp/rt"
  mkdir -p "$RT/core-rules/codex" "$RT/scripts/lib"
  cp -R "$HOOKS_DIR" "$RT/core-rules/hooks"
  cp -R "$CODEX_HOOKS_DIR" "$RT/core-rules/codex/hooks"
  export TRELLIS_ROOT="$RT"
  PARITY_TMP="$tmp/parity"
  PARITY_RULES="$RT/core-rules/hooks/rules"
  PARITY_PROJECT="$tmp/project"
  mkdir -p "$PARITY_TMP"
  git init -q "$PARITY_PROJECT"
  # shellcheck source=parity.bash
  . "$BATS_TEST_DIRNAME/parity.bash"
}

claude_hook() { printf '%s' "$RT/core-rules/hooks/$1.sh"; }
codex_hook() { printf '%s' "$RT/core-rules/codex/hooks/$1.sh"; }

@test "parity: destructive table through the Claude guard" {
  run parity_destructive_run claude "$(claude_hook block-destructive)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: destructive table through the Codex guard" {
  run parity_destructive_run codex "$(codex_hook block-destructive)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: reread table through the Claude guard" {
  run parity_reread_run claude "$(claude_hook reread-guard)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: reread table through the Codex guard" {
  run parity_reread_run codex "$(codex_hook reread-guard)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: reread table through the Codex guard as pi runs it" {
  run parity_reread_run pi "$(codex_hook reread-guard)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: track-read table through the Claude tracker" {
  run parity_track_run claude "$(claude_hook track-read)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: track-read table through the Codex tracker" {
  run parity_track_run codex "$(codex_hook track-read)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "parity: track-read table through the Codex tracker as pi runs it" {
  run parity_track_run pi "$(codex_hook track-read)"
  echo "$output"
  [ "$status" -eq 0 ]
}

# Every rule must be pinned for both engines by a case that fires it, or
# deleting that rule could pass the table.
@test "parity: every destructive rule fires in at least one case per engine" {
  run jq -r '
    [.destructive[].expect | if type == "string" then {claude: ., codex: .} else . end] as $x
    | input.rules[].id as $id
    | ("claude", "codex") as $e
    | select([$x[][$e] // "" | split(",")[] | sub("^(deny|warn):"; "")] | index($id) | not)
    | "\($e) has no case for \($id)"' "$PARITY_CASES" "$PARITY_RULES/destructive.json"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Rebuild the runtime's include from a mutated copy of the rules.
mutate_rules() {
  cp "$REPO/scripts/gen-guard-rules.py" "$RT/scripts/"
  cp "$REPO/scripts/lib/guard-rules-runtime.bash" "$RT/scripts/lib/"
  jq "$2" "$PARITY_RULES/$1" > "$PARITY_TMP/mutated.json"
  mv "$PARITY_TMP/mutated.json" "$PARITY_RULES/$1"
  python3 -I "$RT/scripts/gen-guard-rules.py" --write --root "$RT" >/dev/null
}

@test "parity: deleting any destructive rule fails a case for it in both engines" {
  local id ids engine
  ids="$(jq -r '.rules[].id' "$PARITY_RULES/destructive.json")"
  cp "$PARITY_RULES/destructive.json" "$PARITY_TMP/destructive.orig.json"
  for id in $ids; do
    cp "$PARITY_TMP/destructive.orig.json" "$PARITY_RULES/destructive.json"
    mutate_rules destructive.json "del(.rules[] | select(.id == \"$id\"))"
    for engine in claude codex; do
      PARITY_ONLY_RULE="$id" run parity_destructive_run "$engine" \
        "$([ "$engine" = claude ] && claude_hook block-destructive || codex_hook block-destructive)"
      [ "$status" -ne 0 ] || { echo "deleting $id passed every $engine case:"; echo "$output"; return 1; }
    done
  done
}

@test "parity: destructive generator rejects unknown fields and malformed shapes" {
  local mutation
  cp "$REPO/scripts/gen-guard-rules.py" "$RT/scripts/"
  cp "$REPO/scripts/lib/guard-rules-runtime.bash" "$RT/scripts/lib/"
  cp "$PARITY_RULES/destructive.json" "$PARITY_TMP/destructive.orig.json"
  for mutation in '.future_bypass = true' '.rules[0].future_bypass = true' \
    '.rules[6].message_by_engine.future_bypass = "message"' '.rules[10].exempt.future_bypass = true' \
    '.semantics = null' '.rules = []' '.rules[0].match = "rm"' '.rules[0].unless = null' \
    '.rules[0].ignore_case = "yes"' '.rules[10].exempt.engines = "claude"'; do
    jq "$mutation" "$PARITY_TMP/destructive.orig.json" > "$PARITY_RULES/destructive.json"
    run python3 -I "$RT/scripts/gen-guard-rules.py" --write --root "$RT"
    [ "$status" -eq 1 ] || { echo "accepted $mutation: $output"; return 1; }
    [[ "$output" == gen-guard-rules:* ]] || { echo "unhandled schema error $mutation: $output"; return 1; }
    [[ "$output" != *Traceback* ]] || false
  done
}

@test "parity: generator refuses unshared patterns and invalid identifier boundaries" {
  local pattern boundary location filter
  cp "$REPO/scripts/gen-guard-rules.py" "$RT/scripts/"
  cp "$REPO/scripts/lib/guard-rules-runtime.bash" "$RT/scripts/lib/"
  cp "$PARITY_RULES/destructive.json" "$PARITY_TMP/destructive.orig.json"
  cp "$RT/core-rules/hooks/lib/guard-rules.sh" "$PARITY_TMP/claude.orig.sh"
  cp "$RT/core-rules/codex/hooks/lib/guard-rules.sh" "$PARITY_TMP/codex.orig.sh"
  for location in match unless identifier refusal; do
    case $location in
      match) filter='.rules[0].match[0] = $p' ;;
      unless) filter='.rules[0].unless = [$p]' ;;
      identifier) filter='.rules[10].exempt.identifier = $p' ;;
      refusal) filter='.rules[10].exempt.refuse_if_line_matches[0] = $p' ;;
    esac
    for pattern in 'rm.*' '(?i)rm' 'rm\d' 'a*' 'x{256}' '[a-Z]x'; do
      jq --arg p "$pattern" "$filter" "$PARITY_TMP/destructive.orig.json" > "$PARITY_RULES/destructive.json"
      run python3 -I "$RT/scripts/gen-guard-rules.py" --write --root "$RT"
      [ "$status" -eq 1 ] || { echo "generator accepted $pattern at $location: $output"; return 1; }
      [[ "$output" == gen-guard-rules:* ]] && [[ "$output" != *Traceback* ]]
      cmp "$RT/core-rules/hooks/lib/guard-rules.sh" "$PARITY_TMP/claude.orig.sh"
      cmp "$RT/core-rules/codex/hooks/lib/guard-rules.sh" "$PARITY_TMP/codex.orig.sh"
    done
  done
  for boundary in 'x' '[x][y]' '([x])' '[x]|[y]'; do
    jq --arg p "$boundary" '.rules[10].exempt.identifier_boundary = $p' "$PARITY_TMP/destructive.orig.json" > "$PARITY_RULES/destructive.json"
    run python3 -I "$RT/scripts/gen-guard-rules.py" --write --root "$RT"
    [ "$status" -eq 1 ] || { echo "generator accepted boundary $boundary: $output"; return 1; }
    [[ "$output" == gen-guard-rules:* ]] && [[ "$output" != *Traceback* ]]
    cmp "$RT/core-rules/hooks/lib/guard-rules.sh" "$PARITY_TMP/claude.orig.sh"
    cmp "$RT/core-rules/codex/hooks/lib/guard-rules.sh" "$PARITY_TMP/codex.orig.sh"
  done
  cp "$PARITY_TMP/destructive.orig.json" "$PARITY_RULES/destructive.json"
  run python3 -I "$RT/scripts/gen-guard-rules.py" --write --root "$RT"
  [ "$status" -eq 0 ]
  cmp "$RT/core-rules/hooks/lib/guard-rules.sh" "$PARITY_TMP/claude.orig.sh"
  cmp "$RT/core-rules/codex/hooks/lib/guard-rules.sh" "$PARITY_TMP/codex.orig.sh"
}

@test "parity: latent ignore-case exemption behavior in the generated Claude guard" {
  # Synthetic future policy only: the shipped secrets-read exemption does NOT
  # set ignore_case. Bash folds its identifier while today's native exemption
  # does not; native's companion unit test records the corresponding denial.
  mutate_rules destructive.json '(.rules[] | select(.id == "secrets-read") | .ignore_case) = true'
  parity_destructive_tables claude
  run parity_destructive_decision claude "$(claude_hook block-destructive)" \
    'kubectl get secret tail -n NAMESPACES/n/SECRETS/s'
  [ "$status" -eq 0 ]
  [ "$output" = allow ]
}

@test "parity: a warn budget raised by one fails the escalation cases" {
  mutate_rules reread.json '.warn_budget.default += 1 | .warn_budget.by_level |= map_values(. + 1)'
  run parity_reread_run claude "$(claude_hook reread-guard)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unread-escalates: expected"* ]] || false
  [[ "$output" == *"autonomy-4: expected"* ]] || false
  run parity_reread_run codex "$(codex_hook reread-guard)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unread-escalates: expected"* ]] || false
}

@test "parity: dropping the edit-failure markers fails the failed-edit cases" {
  mutate_rules reread.json '.edit_failure_markers.pattern = "no-such-marker-anywhere"'
  run parity_track_run claude "$(claude_hook track-read)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edit-error-string: expected skip"* ]] || false
  run parity_track_run codex "$(codex_hook track-read)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edit-marker-later-line: expected skip"* ]] || false
}
