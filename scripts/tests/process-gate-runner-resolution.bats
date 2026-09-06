#!/usr/bin/env bats
# Resolver coverage for installed source checkouts and both linked-worktree shapes.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PRE_PUSH="$REPO_ROOT/core-rules/githooks/pre-push"
HUSKY_PRE_PUSH="$REPO_ROOT/core-rules/husky/pre-push"
PR_GATE="$REPO_ROOT/core-rules/hooks/pr-gate-shiftleft.sh"
CODEX_PR_GATE="$REPO_ROOT/core-rules/codex/hooks/pr-gate-shiftleft.sh"

setup() {
  FIXTURE="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/fixture"
  MAIN="$FIXTURE/main"
  WORKTREE="$FIXTURE/worktree"
  CAPTURE="$FIXTURE/runner.log"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email resolver@test.invalid
  git -C "$MAIN" config user.name resolver-test
  printf 'seed\n' > "$MAIN/README.md"
}

write_runner() {
  local runner="$1"
  mkdir -p "$(dirname "$runner")"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$0" "$*" > "$PROCESS_GATE_CAPTURE"
exit 0
SH
  chmod +x "$runner"
}

commit_main() {
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm fixture
}

add_worktree() {
  git -C "$MAIN" worktree add -q -b fixture "$WORKTREE"
}

install_claude_source_link() {
  mkdir -p "$MAIN/.claude/skills"
  ln -s ../../core-rules/skills/process-gate "$MAIN/.claude/skills/process-gate"
}

run_pre_push() {
  local checkout="$1"
  run env PROCESS_GATE_CAPTURE="$CAPTURE" sh -c 'cd "$1" && sh "$2" </dev/null' _ "$checkout" "$PRE_PUSH"
}

run_husky_pre_push() {
  local checkout="$1"
  run env PROCESS_GATE_CAPTURE="$CAPTURE" sh -c 'cd "$1" && sh "$2" </dev/null' _ "$checkout" "$HUSKY_PRE_PUSH"
}

run_pr_gate() {
  local checkout="$1"
  run bash -c '
    unset CODEX_PROJECT_DIR
    export CLAUDE_PROJECT_DIR="$1"
    export PROCESS_GATE_CAPTURE="$2"
    export PR_GATE_SHIFTLEFT_TIMEOUT=2
    printf "%s\n" '\''{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'\'' | bash "$3"
  ' _ "$checkout" "$CAPTURE" "$PR_GATE"
}

run_codex_pr_gate() {
  local checkout="$1"
  run bash -c '
    unset CLAUDE_PROJECT_DIR
    export CODEX_PROJECT_DIR="$1"
    export PROCESS_GATE_CAPTURE="$2"
    export PR_GATE_SHIFTLEFT_TIMEOUT=2
    printf "%s\n" '\''{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'\'' | bash "$3"
  ' _ "$checkout" "$CAPTURE" "$CODEX_PR_GATE"
}

assert_runner() {
  local expected_path="$1" expected_args="$2" actual
  [ -f "$CAPTURE" ]
  actual="$(cat "$CAPTURE")"
  [ "$actual" = "$expected_path|$expected_args" ] || {
    printf 'expected runner: %s|%s\nactual runner:   %s\n' "$expected_path" "$expected_args" "$actual"
    false
  }
}

@test "source checkout keeps the installed skill path ahead of the tracked fallback" {
  local tracked="$MAIN/core-rules/skills/process-gate/scripts/run-all.sh"
  local installed="$MAIN/.claude/skills/process-gate/scripts/run-all.sh"
  write_runner "$tracked"
  commit_main
  install_claude_source_link

  run_pre_push "$MAIN"
  [ "$status" -eq 0 ]
  assert_runner "$installed" "--mode=push"

  run_pr_gate "$MAIN"
  [ "$status" -eq 0 ]
  assert_runner "$installed" "--range=main..HEAD"
}

@test "source worktree resolves the tracked in-repository runner" {
  local tracked="$MAIN/core-rules/skills/process-gate/scripts/run-all.sh"
  local worktree_runner="$WORKTREE/core-rules/skills/process-gate/scripts/run-all.sh"
  write_runner "$tracked"
  commit_main
  install_claude_source_link
  add_worktree

  run_pre_push "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$worktree_runner" "--mode=push"

  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$worktree_runner" "--range=main..HEAD"
}

@test "attached-project worktree resolves the runner through the main checkout common dir" {
  local main_runner="$MAIN/.claude/skills/process-gate/scripts/run-all.sh"
  commit_main
  add_worktree
  write_runner "$main_runner"

  run_pre_push "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--mode=push"

  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--range=main..HEAD"
}

@test "attached-project worktree resolves the Codex runner through the main checkout common dir" {
  local main_runner="$MAIN/.agents/skills/process-gate/scripts/run-all.sh"
  commit_main
  add_worktree
  write_runner "$main_runner"
  [ ! -e "$MAIN/.claude/skills/process-gate/scripts/run-all.sh" ]

  run_pre_push "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--mode=push"

  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--range=main..HEAD"

  run_codex_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  assert_runner "$main_runner" "--range=main..HEAD"
}

@test "missing runner fails pre-push closed and reports every candidate miss" {
  commit_main
  add_worktree
  mkdir -p "$WORKTREE/.claude/skills"
  ln -s ../../missing-process-gate "$WORKTREE/.claude/skills/process-gate"
  mkdir -p "$WORKTREE/.agents/skills/process-gate/scripts/run-all.sh"

  run_pre_push "$WORKTREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing push because the gate produced no safety verdict"* ]]
  [[ "$output" == *"$WORKTREE/.claude/skills/process-gate/scripts/run-all.sh: process-gate skill symlink target is unavailable"* ]]
  [[ "$output" == *"$WORKTREE/.agents/skills/process-gate/scripts/run-all.sh: exists but is not a regular file"* ]]
  [[ "$output" == *"$WORKTREE/core-rules/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.claude/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.agents/skills/process-gate/scripts/run-all.sh: not found"* ]]

  run_husky_pre_push "$WORKTREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing push because the gate produced no safety verdict"* ]]
  [[ "$output" == *"$WORKTREE/.claude/skills/process-gate/scripts/run-all.sh: process-gate skill symlink target is unavailable"* ]]
  [[ "$output" == *"$WORKTREE/.agents/skills/process-gate/scripts/run-all.sh: exists but is not a regular file"* ]]
  [[ "$output" == *"$WORKTREE/core-rules/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.claude/skills/process-gate/scripts/run-all.sh: not found"* ]]
  [[ "$output" == *"$MAIN/.agents/skills/process-gate/scripts/run-all.sh: not found"* ]]

  run_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg worktree "$WORKTREE" --arg main "$MAIN" '
    .hookSpecificOutput.additionalContext
    | contains("Candidates tried:")
      and contains($worktree + "/.claude/skills/process-gate/scripts/run-all.sh: process-gate skill symlink target is unavailable")
      and contains($worktree + "/.agents/skills/process-gate/scripts/run-all.sh: exists but is not a regular file")
      and contains($worktree + "/core-rules/skills/process-gate/scripts/run-all.sh: not found")
      and contains($main + "/.claude/skills/process-gate/scripts/run-all.sh: not found")
      and contains($main + "/.agents/skills/process-gate/scripts/run-all.sh: not found")
  ' >/dev/null

  run_codex_pr_gate "$WORKTREE"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg worktree "$WORKTREE" --arg main "$MAIN" '
    .hookSpecificOutput.additionalContext
    | contains("Candidates tried:")
      and contains($worktree + "/.agents/skills/process-gate/scripts/run-all.sh: exists but is not a regular file")
      and contains($worktree + "/.claude/skills/process-gate/scripts/run-all.sh: process-gate skill symlink target is unavailable")
      and contains($worktree + "/core-rules/skills/process-gate/scripts/run-all.sh: not found")
      and contains($main + "/.agents/skills/process-gate/scripts/run-all.sh: not found")
      and contains($main + "/.claude/skills/process-gate/scripts/run-all.sh: not found")
  ' >/dev/null
}

