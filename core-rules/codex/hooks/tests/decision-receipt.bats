#!/usr/bin/env bats
# Forward-only high-autonomy decision receipt coverage for the deployed Codex wrapper.

load helpers

setup() {
  local deploy="$BATS_TEST_TMPDIR/deploy/.codex/hooks"
  mkdir -p "$deploy/lib"
  cp "$BATS_TEST_DIRNAME/../decision-receipt.sh" "$deploy/decision-receipt.sh"
  cp "$BATS_TEST_DIRNAME/../lib/deps.sh" "$deploy/lib/deps.sh"
  cp "$BATS_TEST_DIRNAME/../lib/autonomy.sh" "$deploy/lib/autonomy.sh"
  cp "$BATS_TEST_DIRNAME/../../../hooks/lib/decision-receipt-core.sh" "$deploy/lib/decision-receipt-core.sh"
  HOOK="$deploy/decision-receipt.sh"

  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" commit --allow-empty -q -m init
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR

  TODAY="$(date -u '+%Y-%m-%d')"
  VALID_ENTRY="- ${TODAY}T12:34:56Z [L4] [scope] Keep the validator forward-only. Reasoning: Legacy entries remain immutable. Alternatives considered: Rewriting history."
  printf '{"autonomy":4}\n' >"$PROJECT_DIR/.trellis.config.json"
  printf '# Decisions log\n\n%s\n' "$VALID_ENTRY" >"$PROJECT_DIR/decisions-log.md"
  git -C "$PROJECT_DIR" add .trellis.config.json decisions-log.md
  git -C "$PROJECT_DIR" commit -q -m fixture
}

make_dirty_code() {
  printf 'changed\n' >"$PROJECT_DIR/app.js"
}

message_with_entry() {
  printf 'Done.\n\n## Decisions made (L%s)\n\n%s\n\n## Follow-ups\n\nNone.\n' "$1" "$2"
}

make_envelope() {
  local message="$1" transcript="${2:-}" active="${3:-false}"
  jq -nc --arg message "$message" --arg transcript "$transcript" --argjson active "$active" \
    '{hook_event_name:"Stop", stop_hook_active:$active, last_assistant_message:$message, transcript_path:(if ($transcript | length) > 0 then $transcript else null end)}'
}

write_transcript() {
  local message="$1" prior="${2:-old turn}" path="$BATS_TEST_TMPDIR/transcript.jsonl"
  jq -nc --arg content "$prior" '{type:"response_item",payload:{type:"message",role:"assistant",content:[{type:"output_text",text:$content}]}}' >"$path"
  jq -nc --arg content "current request" '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:$content}]}}' >>"$path"
  jq -nc --arg content "$message" '{type:"response_item",payload:{type:"message",role:"assistant",content:[{type:"output_text",text:$content}]}}' >>"$path"
  printf '%s' "$path"
}

run_preserving_log() {
  local envelope="$1" before after
  before="$(shasum -a 256 "$PROJECT_DIR/decisions-log.md" | cut -d' ' -f1)"
  run bash "$HOOK" <<<"$envelope"
  after="$(shasum -a 256 "$PROJECT_DIR/decisions-log.md" | cut -d' ' -f1)"
  [ "$after" = "$before" ]
}

assert_block() {
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.decision == "block" and (.reason | startswith("decision-receipt:"))' >/dev/null
}

@test "T27: malformed canonical project policy denies independently even below L4" {
  local policy
  for policy in '{"autonomy":4,' '[]' 'null' '"not an object"'; do
    printf '%s\n' "$policy" > "$PROJECT_DIR/.trellis.json"
    run_preserving_log "$(make_envelope 'Read only.')"
    assert_block
    [[ "$output" == *malformed* ]]
  done
}

@test "T27: non-Boolean stop_hook_active takes the strict-parser failure path" {
  local active
  # Even a valid read-only L1 turn cannot turn malformed input into a pass.
  printf '{"autonomy":1}\n' > "$PROJECT_DIR/.trellis.json"
  for active in '"true"' '"false"' 'null' '1' '[]' '{}' '"true\\u0000\\n"'; do
    run_preserving_log "$(make_envelope 'Read only.' '' "$active")"
    assert_block
    [[ "$output" == *stop_hook_active*Boolean* ]]
  done
  run_preserving_log "$(make_envelope 'Read only.' '' true)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T27: an absent first preset does not hide a later L4 preset" {
  local runtime="$BATS_TEST_TMPDIR/preset-runtime"
  mkdir -p "$runtime/core-rules/presets"
  printf '{"autonomy_default":2}\n' > "$runtime/trellis.config.json"
  printf '%s\n' '---' 'autonomy_default: 4' '---' > "$runtime/core-rules/presets/later.md"
  printf '{"presets":["absent","later"]}\n' > "$PROJECT_DIR/.trellis.json"
  # No legacy override: exercise the later preset, not the fixture's L4 knob.
  printf '{}\n' > "$PROJECT_DIR/.trellis.config.json"
  make_dirty_code
  export TRELLIS_ROOT="$runtime"
  run_preserving_log "$(make_envelope 'Done without a block.')"
  assert_block
  [[ "$output" == *L4* ]]
}

@test "T27 R1 M3: schema-invalid autonomy and preset fields deny independently" {
  local runtime="$BATS_TEST_TMPDIR/schema-runtime" policy long
  mkdir -p "$runtime/core-rules/presets"
  printf '{"autonomy_default":3}\n' > "$runtime/trellis.config.json"
  printf '%s\n' '---' 'autonomy_default: 4' '---' > "$runtime/core-rules/presets/l4.md"
  export TRELLIS_ROOT="$runtime"
  printf '{}\n' > "$PROJECT_DIR/.trellis.config.json"
  make_dirty_code
  long=$(printf '%065d' 0 | tr 0 a)
  for policy in '{"autonomy":"L4"}' '{"autonomy":null}' '{"autonomy":"x"}' '{"autonomy":"4"}' \
      '{"autonomy":true}' '{"autonomy":0}' '{"autonomy":6}' '{"autonomy":3.5}' \
      '{"presets":"l4"}' '{"presets":null}' '{"presets":[1]}' '{"presets":["a"]}' \
      '{"presets":["L4"]}' '{"presets":["bad_name"]}' '{"presets":["a-"]}' \
      '{"presets":["l4","l4"]}' '{"presets":["l4"],"autonomy":"x"}' \
      "{\"presets\":[\"$long\"]}"; do
    printf '%s\n' "$policy" > "$PROJECT_DIR/.trellis.json"
    run_preserving_log "$(make_envelope 'Done without a block.')"
    assert_block
    [[ "$output" == *malformed* ]]
    run_preserving_log "$(make_envelope "$(message_with_entry 4 "$VALID_ENTRY")")"
    assert_block
    [[ "$output" == *malformed* ]]
  done
}

@test "T27 R1 M3: schema integer 4.0 resolves to L4 and syntax-valid absent presets remain allowed" {
  local number missing runtime="$BATS_TEST_TMPDIR/integer-runtime"
  mkdir -p "$runtime/core-rules/presets"
  printf '{"autonomy_default":3}\n' > "$runtime/trellis.config.json"
  printf '{}\n' > "$PROJECT_DIR/.trellis.config.json"
  export TRELLIS_ROOT="$runtime"
  make_dirty_code
  for number in 4.0 4e0 40e-1 0.4e1; do
    printf '{"autonomy":%s}\n' "$number" > "$PROJECT_DIR/.trellis.json"
    run_preserving_log "$(make_envelope 'Done without a block.')"
    assert_block
    [[ "$output" == *L4* ]]
    run_preserving_log "$(make_envelope "$(message_with_entry 4 "$VALID_ENTRY")")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  missing=$(printf '%064d' 0 | tr 0 a)
  printf '{"autonomy":3,"presets":["%s"]}\n' "$missing" > "$PROJECT_DIR/.trellis.json"
  run_preserving_log "$(make_envelope 'No receipt is needed at valid L3.')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "valid current L4 receipt passes without changing the log" {
  make_dirty_code
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$VALID_ENTRY")")"
  [ "$status" -eq 0 ]
}

@test "malformed receipt blocks without changing the log" {
  make_dirty_code
  local malformed="- ${TODAY}T12:34:56Z [L4] [scope] Missing required clauses."
  printf '\n%s\n' "$malformed" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$malformed")")"
  assert_block
  [[ "$output" == *"malformed decision entry"* ]]
}

@test "blank decision clauses are rejected without changing the log" {
  make_dirty_code
  local blank entries=(
    "- ${TODAY}T12:35:00Z [L4] [scope]   . Reasoning: Filled. Alternatives considered: Filled."
    "- ${TODAY}T12:35:01Z [L4] [scope] Filled. Reasoning:   . Alternatives considered: Filled."
    "- ${TODAY}T12:35:02Z [L4] [scope] Filled. Reasoning: Filled. Alternatives considered:   ."
  )
  for blank in "${entries[@]}"; do
    printf '\n%s\n' "$blank" >>"$PROJECT_DIR/decisions-log.md"
    run_preserving_log "$(make_envelope "$(message_with_entry 4 "$blank")")"
    assert_block
    [[ "$output" == *"malformed decision entry"* ]] || { echo "$output"; false; }
  done
}

@test "missing decision block blocks without changing the log" {
  make_dirty_code
  run_preserving_log "$(make_envelope "Done without a decision block.")"
  assert_block
  [[ "$output" == *"requires exactly one"* ]]
}

@test "receipt absent from canonical log blocks without changing the log" {
  make_dirty_code
  local missing="- ${TODAY}T13:00:00Z [L4] [pattern] Keep one parser. Reasoning: Duplicate parsers drift. Alternatives considered: Harness-specific parsing."
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$missing")")"
  assert_block
  [[ "$output" == *"absent from canonical-root decisions-log.md"* ]]
}

@test "L1-L3 substantive turn passes without a decision block" {
  printf '{"autonomy":3}\n' >"$PROJECT_DIR/.trellis.config.json"
  make_dirty_code
  run_preserving_log "$(make_envelope "No high-autonomy block required.")"
  [ "$status" -eq 0 ]
}

@test "cross-level block is rejected" {
  make_dirty_code
  local cross="- ${TODAY}T13:00:00Z [L5] [scope] Use the wrong level. Reasoning: Fixture exercises level checks. Alternatives considered: Matching L4."
  printf '\n%s\n' "$cross" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 5 "$cross")")"
  assert_block
  [[ "$output" == *"does not match resolved L4"* ]]
}

@test "stale-date receipt is rejected" {
  make_dirty_code
  local stale="- 2000-01-01T13:00:00Z [L4] [scope] Reuse an old receipt. Reasoning: Fixture exercises freshness. Alternatives considered: Current UTC date."
  printf '\n%s\n' "$stale" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$stale")")"
  assert_block
  [[ "$output" == *"malformed decision entry"* ]]
}

@test "transcript supplies the current receipt when final message is absent" {
  make_dirty_code
  local transcript
  transcript="$(write_transcript "$(message_with_entry 4 "$VALID_ENTRY")")"
  run_preserving_log "$(make_envelope "" "$transcript")"
  [ "$status" -eq 0 ]
}

@test "prior-turn receipt does not satisfy a receiptless current transcript turn" {
  make_dirty_code
  local transcript
  transcript="$(write_transcript "Current answer without a decision block." "$(message_with_entry 4 "$VALID_ENTRY")")"
  run_preserving_log "$(make_envelope "" "$transcript")"
  assert_block
  [[ "$output" == *"requires exactly one"* ]]
}

@test "prior conflicting block does not contaminate a valid current transcript turn" {
  make_dirty_code
  local prior transcript
  prior="$(message_with_entry 5 "- ${TODAY}T11:00:00Z [L5] [scope] Conflict with the current level. Reasoning: Exercise turn scoping. Alternatives considered: L4.")"
  transcript="$(write_transcript "$(message_with_entry 4 "$VALID_ENTRY")" "$prior")"
  run_preserving_log "$(make_envelope "" "$transcript")"
  [ "$status" -eq 0 ]
}

@test "architectural receipt requires SURFACED INLINE" {
  make_dirty_code
  local architectural="- ${TODAY}T14:00:00Z [L4] [architectural] Keep the dedicated Stop boundary. Reasoning: Ordering is load-bearing. Alternatives considered: Folding into stop-verify."
  printf '\n%s\n' "$architectural" >>"$PROJECT_DIR/decisions-log.md"
  run_preserving_log "$(make_envelope "$(message_with_entry 4 "$architectural")")"
  assert_block
  [[ "$output" == *"missing SURFACED INLINE"* ]]
}

@test "continuation short-circuits before validation" {
  make_dirty_code
  run_preserving_log "$(make_envelope "" "" true)"
  [ "$status" -eq 0 ]
}

@test "clean worktree with a current DoD marker is substantive" {
  local message
  message="$(message_with_entry 4 "$VALID_ENTRY")"
  message="${message}\n<!-- dod-receipt cmd=\"bats decision-receipt.bats\" exit=0 diff=\"+1/-0 (1 files)\" -->"
  run_preserving_log "$(make_envelope "$message")"
  [ "$status" -eq 0 ]
}

@test "clean read-only turn skips decision validation" {
  local sid="clean-readonly-codex-1"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$TRELLIS_HOME"
  . "$BATS_TEST_DIRNAME/../lib/deps.sh"
  _se_turn_baseline_publish "$PROJECT_DIR" codex "$sid"
  _se_turn_baseline_publish "$PROJECT_DIR" claude "$sid"
  local env="$(jq -nc --arg m 'Read-only answer.' --arg sid "$sid" '{hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:$m, transcript_path:null, session_id:$sid}')"
  run_preserving_log "$env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clean turn with a DoD marker blocks when the decision block is missing" {
  local message='Done. <!-- dod-receipt cmd="bats decision-receipt.bats" exit=0 diff="+1/-0 (1 files)" -->'
  run_preserving_log "$(make_envelope "$message")"
  assert_block
  [[ "$output" == *"requires exactly one"* ]]
}

make_envelope_sid() {
  local message="$1" sid="$2" transcript="${3:-}"
  jq -nc --arg message "$message" --arg sid "$sid" --arg transcript "$transcript" \
    '{hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:$message, transcript_path:(if ($transcript | length) > 0 then $transcript else null end), session_id:$sid}'
}

publish_baseline_codex() {
  local sid="$1"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$TRELLIS_HOME" "$PROJECT_DIR/.claude" "$PROJECT_DIR/.codex"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  printf '/.claude/settings.local.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
  printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  # shellcheck disable=SC1090
  . "$BATS_TEST_DIRNAME/../lib/deps.sh"
  _se_turn_baseline_publish "$PROJECT_DIR" codex "$sid"
  _se_turn_baseline_publish "$PROJECT_DIR" claude "$sid"
}

@test "codex deps publish and carry write turn-start copies" {
  local sid="sweep-fx1-turnstart-codex-1"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home-turnstart"
  mkdir -p "$TRELLIS_HOME"
  # shellcheck disable=SC1090
  . "$BATS_TEST_DIRNAME/../lib/deps.sh"
  _se_turn_baseline_publish "$PROJECT_DIR" codex "$sid"
  local key sdir
  key=$(_se_state_key "" "$sid")
  sdir=$(_se_turn_state_dir "$PROJECT_DIR")
  [ -f "$sdir/turn-start.codex.$key" ]
  grep -q "^trellis-turn-baseline v2 " "$sdir/turn-start.codex.$key"
  _se_turn_carry_write "$sdir" "codex.$key" "$PROJECT_DIR"
  [ -f "$sdir/turn-start.codex.$key" ]
  grep -q "^trellis-turn-carry v2 " "$sdir/turn-start.codex.$key"
}

assert_codex_block() {
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.decision == "block"' >/dev/null
}

@test "sweep-fx1: commit-then-Stop runs gate even with clean tree" {
  local sid="sweep-fx1-commit-codex-1"
  publish_baseline_codex "$sid"
  git -C "$PROJECT_DIR" commit --allow-empty -q -m "work committed this turn"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Done without a decision block.' "$sid")"
  assert_codex_block
}

@test "sweep-fx1: truly idle turn with matching baseline skips" {
  local sid="sweep-fx1-idle-codex-1"
  publish_baseline_codex "$sid"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep-fx1: missing baseline runs gate fail-closed" {
  local sid="sweep-fx1-missing-codex-1"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home-missing"
  mkdir -p "$TRELLIS_HOME" "$PROJECT_DIR/.claude" "$PROJECT_DIR/.codex"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  printf '/.claude/settings.local.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
  printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  assert_codex_block
}

@test "sweep-fx1-M4: unknown poison line always runs the gate" {
  local sid="sweep-fx1-unknown-codex-1"
  publish_baseline_codex "$sid"
  local key sdir
  key=$(_se_state_key "" "$sid")
  sdir=$(_se_turn_state_dir "$PROJECT_DIR")
  printf 'trellis-turn-baseline v2 unknown\n' >> "$sdir/turn-start.claude.$key"
  printf 'trellis-turn-baseline v2 unknown\n' >> "$sdir/turn-start.codex.$key"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  assert_codex_block
}

@test "sweep-fx1-H3-concurrent: stop-verify deleting baseline does not block idle decision" {
  local sid="sweep-fx1-concurrent-codex-1"
  publish_baseline_codex "$sid"
  local tx="$BATS_TEST_TMPDIR/big-transcript-codex.jsonl"
  # The generator runs isolated: a sitecustomize planted on PYTHONPATH never runs.
  local planted="$BATS_TEST_TMPDIR/planted-py"
  mkdir -p "$planted"
  printf 'open("%s", "w").close()\n' "$BATS_TEST_TMPDIR/planted-ran" > "$planted/sitecustomize.py"
  PYTHONPATH="$planted" python3 -I -c "print('{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"x\"}]}}')" > "$tx"
  PYTHONPATH="$planted" python3 -I -c "for i in range(2000): print('{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"' + 'y'*40 + '\"}]}}')" >> "$tx"
  [ ! -e "$BATS_TEST_TMPDIR/planted-ran" ]
  local stop_hook="$BATS_TEST_DIRNAME/../stop-verify.sh"
  local stop_input
  stop_input=$(jq -nc --arg sid "$sid" --arg tx "$tx" '{hook_event_name:"Stop", stop_hook_active:false, session_id:$sid, transcript_path:$tx, last_assistant_message:"Read-only answer."}')
  printf '%s' "$stop_input" | bash "$stop_hook" >/dev/null 2>&1 &
  local stop_pid=$!
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  wait "$stop_pid" || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep-fx1-L12: unarmed project keeps old dirty trigger" {
  local sid="sweep-fx1-unarmed-codex-1"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home-unarmed-codex"
  mkdir -p "$TRELLIS_HOME"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# R2-H1: the real prompt and Stop hooks, armed and published only for the
# running harness.
arm_running_harness() {
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$TRELLIS_HOME" "$PROJECT_DIR/.codex"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
  printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  # shellcheck disable=SC1090
  . "$BATS_TEST_DIRNAME/../lib/deps.sh"
}

prompt_turn() {
  jq -nc --arg sid "$1" --arg cwd "$PROJECT_DIR" '{hook_event_name:"UserPromptSubmit", session_id:$sid, cwd:$cwd, prompt:"hi"}' \
    | (cd "$PROJECT_DIR" && bash "$BATS_TEST_DIRNAME/../turn-baseline.sh")
}

stop_verify_turn() {
  make_envelope_sid 'Read-only answer.' "$1" | (cd "$PROJECT_DIR" && bash "$BATS_TEST_DIRNAME/../stop-verify.sh") >/dev/null 2>&1
}

# Hold stop-verify inside its run, after it has consumed the baseline and its
# nonces and before its exit carry: the window a parallel decision-receipt sees.
stop_verify_paused() {
  local sid="$1" key sdir shim="$BATS_TEST_TMPDIR/shim" i=0
  key=$(_se_state_key "" "$sid")
  sdir=$(_se_turn_state_dir "$PROJECT_DIR")
  mkdir -p "$shim"
  cat > "$shim/git" <<SHIM
#!/bin/bash
if [ ! -e "$sdir/codex.$key" ] && [ ! -e "$BATS_TEST_TMPDIR/paused" ]; then
  : > "$BATS_TEST_TMPDIR/paused"
  i=0; while [ ! -e "$BATS_TEST_TMPDIR/resume" ] && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done
fi
exec "$(command -v git)" "\$@"
SHIM
  chmod +x "$shim/git"
  make_envelope_sid 'Read-only answer.' "$sid" \
    | (cd "$PROJECT_DIR" && PATH="$shim:$PATH" bash "$BATS_TEST_DIRNAME/../stop-verify.sh") >/dev/null 2>&1 &
  STOP_PID=$!
  while [ ! -e "$BATS_TEST_TMPDIR/paused" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$BATS_TEST_TMPDIR/paused" ]
  [ ! -e "$sdir/codex.$key" ]
}

resume_stop_verify() {
  : > "$BATS_TEST_TMPDIR/resume"
  wait "$STOP_PID" || true
  rm -f "$BATS_TEST_TMPDIR/paused" "$BATS_TEST_TMPDIR/resume"
}

@test "sweep-fx1-R2-H1: stop-verify then decision-receipt on an idle turn skips" {
  local sid="sweep-fx1-r2-stop-first-codex"
  arm_running_harness
  prompt_turn "$sid"
  stop_verify_paused "$sid"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  resume_stop_verify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '^trellis-turn-carry v2 ' "$(_se_turn_state_dir "$PROJECT_DIR")/codex.$(_se_state_key "" "$sid")"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep-fx1-R2-H1: second idle turn skips" {
  local sid="sweep-fx1-r2-second-turn-codex"
  arm_running_harness
  prompt_turn "$sid"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  stop_verify_turn "$sid"
  grep -q '^trellis-turn-carry v2 ' "$(_se_turn_state_dir "$PROJECT_DIR")/codex.$(_se_state_key "" "$sid")"
  prompt_turn "$sid"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  stop_verify_paused "$sid"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  resume_stop_verify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep-fx1-R2-H1: an earlier turn's start HEAD does not excuse a later turn's reset" {
  local sid="sweep-fx1-r2-reset-codex"
  arm_running_harness
  prompt_turn "$sid"
  stop_verify_turn "$sid"
  git -C "$PROJECT_DIR" commit --allow-empty -q -m "operator commit between turns"
  prompt_turn "$sid"
  # The turn moves HEAD back to where the first turn started; the tree is clean.
  git -C "$PROJECT_DIR" reset -q --hard HEAD~1
  run bash "$HOOK" <<<"$(make_envelope_sid 'Done without a decision block.' "$sid")"
  assert_codex_block
  [[ "$output" == *"requires exactly one"* ]]
}

@test "sweep-fx1-R2-L6: pi is not armed by a Claude- or Codex-armed project" {
  local sid="sweep-fx1-r2-l6-pi"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$TRELLIS_HOME" "$PROJECT_DIR/.claude" "$PROJECT_DIR/.codex"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
  printf '/.claude/settings.local.json\n/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  # Pi runs no turn-baseline; a clean pi turn keeps the unarmed trigger.
  run env TRELLIS_HARNESS=pi bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Pi still validates a dirty turn.
  make_dirty_code
  run env TRELLIS_HARNESS=pi bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  assert_codex_block
}

@test "sweep-fx1-R2-L6: a Claude-armed project does not arm the Codex hook" {
  local sid="sweep-fx1-r2-l6-claude-armed"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$TRELLIS_HOME" "$PROJECT_DIR/.claude"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  printf '/.claude/settings.local.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep-fx1-R2-L6: the Codex hook reads only the Codex turn-start" {
  local sid="sweep-fx1-r2-l6-own-file-codex" key sdir
  arm_running_harness
  _se_turn_baseline_publish "$PROJECT_DIR" codex "$sid"
  _se_turn_baseline_publish "$PROJECT_DIR" claude "$sid"
  key=$(_se_state_key "" "$sid")
  sdir=$(_se_turn_state_dir "$PROJECT_DIR")
  printf 'trellis-turn-baseline v2 unknown\n' >> "$sdir/turn-start.codex.$key"
  run bash "$HOOK" <<<"$(make_envelope_sid 'Read-only answer.' "$sid")"
  assert_codex_block
}
