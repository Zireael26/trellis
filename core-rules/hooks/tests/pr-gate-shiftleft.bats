#!/usr/bin/env bats
# Narrow fixtures for pr-gate-shiftleft.sh (Spec 005 C3 / T-P4d).
#
# The suite intentionally drives a throwaway process-gate runner. It covers
# exact trigger/non-trigger matching, malformed envelopes, the Perl timeout,
# and all three process-gate exit outcomes without running a real gate.

load helpers

HOOK="$HOOKS_DIR/pr-gate-shiftleft.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/pr-gate-shiftleft.sh"

setup() {
  setup_project_dir
  RUNNER="$PROJECT_DIR/.claude/skills/process-gate/scripts/run-all.sh"
  mkdir -p "$(dirname "$RUNNER")"
  GATE_LOG="$PROJECT_DIR/gate-args.log"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  export PR_GATE_TEST_LOG="$GATE_LOG"
  export PR_GATE_TEST_OUTPUT='## process-gate verdict

Overall: MERGEABLE'
  export PR_GATE_TEST_RC=0
  export PR_GATE_TEST_SLEEP=0
  export PR_GATE_TEST_CHILD_PID_FILE="$PROJECT_DIR/child.pid"
  export PR_GATE_SHIFTLEFT_TIMEOUT=2
  unset PR_GATE_SHIFTLEFT_RUNNER PROCESS_GATE_RUNNER PR_GATE_SHIFTLEFT_RANGE
}

teardown() {
  teardown_project_dir
}

write_runner() {
  cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
if [ -n "${PR_GATE_TEST_LOG:-}" ]; then
  printf '%s\n' "$*" > "$PR_GATE_TEST_LOG"
fi
if [ "${PR_GATE_TEST_SLEEP:-0}" = "1" ]; then
  ( sleep 30 ) &
  child="$!"
  if [ -n "${PR_GATE_TEST_CHILD_PID_FILE:-}" ]; then
    printf '%s\n' "$child" > "$PR_GATE_TEST_CHILD_PID_FILE"
  fi
  wait "$child"
fi
printf '%s\n' "${PR_GATE_TEST_OUTPUT:-}"
exit "${PR_GATE_TEST_RC:-0}"
EOF
  chmod +x "$RUNNER"
}

# Build a minimal command PATH that intentionally has no perl. The hook still
# gets its normal shell utilities and jq, while the runner is proved untouched.
make_no_perl_path() {
  local out command_name source_path
  out="$(mktemp -d "$BATS_TMPDIR/pr-gate-no-perl.XXXXXX")"
  for command_name in awk bash cat date dirname env git grep jq mktemp mv rm sed sort tail tr wc; do
    if source_path="$(command -v "$command_name" 2>/dev/null)"; then
      ln -s "$source_path" "$out/$command_name"
    fi
  done
  printf '%s' "$out"
}

run_hook() {
  local hook="$1" command="$2" input
  input="$(jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash "$hook" <<<"$input"
}

@test "exact trigger: gh pr create runs process-gate with the standard range" {
  write_runner
  run_hook "$HOOK" 'gh pr create --fill'
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate MERGEABLE"* ]]
  [[ "$output" == *"Overall: MERGEABLE"* ]]
  [ "$(cat "$GATE_LOG")" = "--range=main..HEAD" ]
  printf '%s' "$output" | jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext | contains("advisory only"))
  ' >/dev/null
}

@test "exact trigger: separators still find gh pr create" {
  write_runner
  run_hook "$HOOK" 'git status && gh  pr  create --draft'
  [ "$status" -eq 0 ]
  [ -f "$GATE_LOG" ]
}

@test "heredoc bodies are data, while a command after the delimiter triggers" {
  write_runner
  run_hook "$HOOK" $'cat <<\'EOF\'\ngh pr create --fill\nEOF'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]

  run_hook "$HOOK" $'cat <<\'EOF\'\nPR body prose: gh pr create --fill\nEOF\ngh pr create --draft'
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate MERGEABLE"* ]]
  [ -f "$GATE_LOG" ]
}

@test "explicit safe wrappers trigger, but wrapped prose does not" {
  write_runner
  local command
  for command in \
    'command gh pr create --fill' \
    'exec gh pr create --fill' \
    'env GH_TOKEN=test gh pr create --fill' \
    'sudo gh pr create --fill' \
    'nohup gh pr create --fill' \
    'time gh pr create --fill'; do
    rm -f "$GATE_LOG"
    run_hook "$HOOK" "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *"process-gate MERGEABLE"* ]]
    [ -f "$GATE_LOG" ]
  done

  rm -f "$GATE_LOG"
  run_hook "$HOOK" 'sudo echo gh pr create --fill'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]
}

@test "leading and trailing shell delimiters bound the logical command" {
  write_runner
  local command
  for command in \
    'true;gh pr create --fill' \
    'true && gh pr create --fill' \
    'true || gh pr create --fill' \
    'true | gh pr create --fill' \
    '(gh pr create --fill)' \
    '{ gh pr create --fill; }' \
    'gh pr create --fill;'; do
    rm -f "$GATE_LOG"
    run_hook "$HOOK" "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *"process-gate MERGEABLE"* ]]
    [ -f "$GATE_LOG" ]
  done
}

@test "Claude/Codex twins share heredoc and wrapper scanning" {
  write_runner
  local fixture
  fixture=$'cat <<\'EOF\'\ngh pr create --fill\nEOF\ncommand gh pr create --draft'

  run_hook "$HOOK" "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate MERGEABLE"* ]]
  [ -f "$GATE_LOG" ]

  rm -f "$GATE_LOG"
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR
  run_hook "$CODEX_HOOK" "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate MERGEABLE"* ]]
  [ -f "$GATE_LOG" ]
}

@test "exact non-trigger: other gh subcommands and prose do not run process-gate" {
  write_runner
  run_hook "$HOOK" 'gh pr view 123'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]

  run_hook "$HOOK" 'echo gh pr create --fill'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]
}

@test "unrelated command stays unblocked even when the gate would fail" {
  write_runner
  export PR_GATE_TEST_RC=1
  run_hook "$HOOK" 'git status --short'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]
}

@test "malformed input: invalid JSON is a silent no-op" {
  write_runner
  run bash "$HOOK" <<<'{"tool_input":{"command":'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]
}

@test "malformed input: non-string command is a silent no-op" {
  write_runner
  run bash "$HOOK" <<<'{"tool_input":{"command":["gh","pr","create"]}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]
}

@test "malformed input: non-Bash tool envelopes are a silent no-op" {
  write_runner
  run bash "$HOOK" <<<'{"tool_name":"Read","tool_input":{"command":"gh pr create --fill"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GATE_LOG" ]
}

@test "timeout: process-gate timeout is advisory and exits 0" {
  write_runner
  export PR_GATE_SHIFTLEFT_TIMEOUT=1
  export PR_GATE_TEST_SLEEP=1
  run_hook "$HOOK" 'gh pr create --fill'
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIMED OUT after 1s"* ]]
  [ -f "$PROJECT_DIR/child.pid" ]
}

@test "timeout: missing Perl skips the canonical runner with one visible degradation" {
  write_runner
  NO_PERL_PATH="$(make_no_perl_path)"
  input="$(jq -nc --arg c 'gh pr create --fill' '{tool_name:"Bash",tool_input:{command:$c}}')"
  PATH_BACKUP="$PATH"
  export PATH="$NO_PERL_PATH"
  run_with_stderr "$HOOK" "$input"
  export PATH="$PATH_BACKUP"

  [ "$status" -eq 0 ]
  [ ! -e "$GATE_LOG" ]
  [[ "$stderr" == *"pr-gate-shiftleft"*"Perl"* ]]
  [ "$(printf '%s' "$stderr" | grep -Fc 'Perl')" -eq 1 ]
  [[ "$output" != *"process-gate BLOCKED"* ]]
  rm -rf "$NO_PERL_PATH"
}

@test "timeout: missing Perl skips the Codex runner with one visible degradation" {
  write_runner
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR
  NO_PERL_PATH="$(make_no_perl_path)"
  input="$(jq -nc --arg c 'gh pr create --fill' '{tool_name:"Bash",tool_input:{command:$c}}')"
  PATH_BACKUP="$PATH"
  export PATH="$NO_PERL_PATH"
  run_with_stderr "$CODEX_HOOK" "$input"
  export PATH="$PATH_BACKUP"

  [ "$status" -eq 0 ]
  [ ! -e "$GATE_LOG" ]
  [[ "$stderr" == *"pr-gate-shiftleft"*"Perl"* ]]
  [ "$(printf '%s' "$stderr" | grep -Fc 'Perl')" -eq 1 ]
  [[ "$output" != *"process-gate BLOCKED"* ]]
  rm -rf "$NO_PERL_PATH"
}

@test "gate outcome: NEEDS CHANGES is surfaced without blocking" {
  write_runner
  export PR_GATE_TEST_RC=2
  export PR_GATE_TEST_OUTPUT='Overall: NEEDS CHANGES'
  run_hook "$HOOK" 'gh pr create --fill'
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate NEEDS CHANGES"* ]]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

@test "gate outcome: BLOCKED is surfaced without blocking" {
  write_runner
  export PR_GATE_TEST_RC=1
  export PR_GATE_TEST_OUTPUT='Overall: BLOCKED'
  run_hook "$HOOK" 'gh pr create --fill'
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate BLOCKED"* ]]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "Codex twin: trigger emits PreToolUse context and stays advisory" {
  write_runner
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR
  run_hook "$CODEX_HOOK" 'gh pr create --fill'
  [ "$status" -eq 0 ]
  [[ "$output" == *"process-gate MERGEABLE"* ]]
  printf '%s' "$output" | jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext | contains("CI and branch protection"))
  ' >/dev/null
}
