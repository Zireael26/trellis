#!/usr/bin/env bats
# Narrow fixtures for pr-gate-shiftleft.sh (Spec 005 C3 / T-P4d).
#
# The hook is a recorder only: on `gh pr create` it records the literal --base
# on the checked-out head branch and exits 0. It never runs process-gate. The
# suite drives a stub run-all.sh that writes a marker, proving it is not run.

load helpers

HOOK="$HOOKS_DIR/pr-gate-shiftleft.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/pr-gate-shiftleft.sh"

setup() {
  setup_project_dir
  git -C "$PROJECT_DIR" branch -M main
  git -C "$PROJECT_DIR" checkout -qb feature/x
  RUNNER="$PROJECT_DIR/.claude/skills/process-gate/scripts/run-all.sh"
  MARKER="$PROJECT_DIR/runner-ran"
  export PR_GATE_TEST_MARKER="$MARKER"
  export PR_GATE_SHIFTLEFT_RUNNER="$RUNNER"
  unset PROCESS_GATE_RUNNER
}

teardown() {
  teardown_project_dir
}

write_runner() {
  mkdir -p "$(dirname "$RUNNER")"
  cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PR_GATE_TEST_MARKER"
printf '%s\n' 'Overall: BLOCKED'
exit 1
EOF
  chmod +x "$RUNNER"
}

select_twin() {
  if [ "$1" = "$CODEX_HOOK" ]; then
    export CODEX_PROJECT_DIR="$PROJECT_DIR"
    unset CLAUDE_PROJECT_DIR
  else
    export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
    unset CODEX_PROJECT_DIR
  fi
}

run_hook() {
  local hook="$1" command="$2" input
  select_twin "$hook"
  input="$(jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash "$hook" <<<"$input"
}

# Splits stdout (`output`) from stderr (`stderr`), unlike run_hook.
run_hook_stderr() {
  local hook="$1" command="$2" input
  select_twin "$hook"
  input="$(jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run_with_stderr "$hook" "$input"
}

recorded_base() {
  git -C "$PROJECT_DIR" config --get branch.feature/x.trellisPrBase || true
}

@test "runner is never invoked on gh pr create, and the hook exits 0 with no decision" {
  write_runner
  local hook
  for hook in "$HOOK" "$CODEX_HOOK"; do
    rm -f "$MARKER"
    run_hook_stderr "$hook" 'gh pr create --base develop --fill'
    [ ! -e "$MARKER" ]
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "successful trigger prints one stderr note naming the recorded base" {
  local hook
  for hook in "$HOOK" "$CODEX_HOOK"; do
    git -C "$PROJECT_DIR" config --unset branch.feature/x.trellisPrBase || true
    run_hook_stderr "$hook" 'gh pr create --base develop --fill'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = 'pr-gate-shiftleft: recorded PR base develop; the full process gate runs at push' ]
  done
}

@test "a trigger without a literal base prints no note" {
  local hook
  for hook in "$HOOK" "$CODEX_HOOK"; do
    run_hook_stderr "$hook" 'gh pr create --fill'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
}

@test "recorder: literal --base is recorded on the checked-out head branch" {
  local hook
  for hook in "$HOOK" "$CODEX_HOOK"; do
    git -C "$PROJECT_DIR" config --unset branch.feature/x.trellisPrBase || true
    run_hook "$hook" 'gh pr create --base develop --fill'
    [ "$status" -eq 0 ]
    [ "$(recorded_base)" = develop ]
  done
}

@test "recorder: a PR without a literal base records nothing" {
  local hook
  for hook in "$HOOK" "$CODEX_HOOK"; do
    run_hook "$hook" 'gh pr create --fill'
    [ "$status" -eq 0 ]
    [ -z "$(recorded_base)" ]
  done
}

@test "recorder: trigger scanning still feeds it through separators and wrappers" {
  local command
  for command in \
    'git status && gh  pr  create --base develop' \
    'command gh pr create --base develop' \
    'env GH_TOKEN=test gh pr create --base develop' \
    'gh pr create --base develop;'; do
    git -C "$PROJECT_DIR" config --unset branch.feature/x.trellisPrBase || true
    run_hook "$HOOK" "$command"
    [ "$status" -eq 0 ]
    [ "$(recorded_base)" = develop ]
  done
}

@test "recorder: heredoc prose and echoed commands record nothing" {
  run_hook "$HOOK" $'cat <<\'EOF\'\ngh pr create --base other\nEOF'
  [ "$status" -eq 0 ]
  [ -z "$(recorded_base)" ]

  run_hook "$HOOK" 'echo gh pr create --base other'
  [ "$status" -eq 0 ]
  [ -z "$(recorded_base)" ]
}

@test "unresolvable PR head is advisory, records nothing, and exits 0" {
  run_hook "$HOOK" 'gh pr create --head nope --base develop'
  [ "$status" -eq 0 ]
  [ -z "$(recorded_base)" ]
  printf '%s' "$output" | jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext == "pr-gate-shiftleft: cannot resolve the PR head; advisory skipped")
  ' >/dev/null
}

@test "malformed input: invalid JSON is a silent no-op" {
  write_runner
  run bash "$HOOK" <<<'{"tool_input":{"command":'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$MARKER" ]
}

@test "malformed input: non-string command is a silent no-op" {
  write_runner
  run bash "$HOOK" <<<'{"tool_input":{"command":["gh","pr","create"]}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$MARKER" ]
}

@test "malformed input: non-Bash tool envelopes are a silent no-op" {
  write_runner
  run bash "$HOOK" <<<'{"tool_name":"Read","tool_input":{"command":"gh pr create --base develop"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$MARKER" ]
  [ -z "$(recorded_base)" ]
}
