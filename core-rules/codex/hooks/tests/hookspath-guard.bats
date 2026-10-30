#!/usr/bin/env bats
# Spec 055 R4.3: the Codex PostToolUse(Bash) core.hooksPath drift advisory.
#
# Mirror of core-rules/hooks/tests/hookspath-guard.bats for the Codex twin, run
# in place as the rendered hooks.json does: TRELLIS_ROOT names this checkout,
# and the shared lib is reached through the R1.1 guard. The rollback-sequence
# case for both templates lives in the Claude suite. Nothing reads the real
# ~/.trellis.

HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)/hookspath-guard.sh"
REPO="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  PROJECT="$TMP/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  export TRELLIS_HOME="$TMP/trellis-home"
  checkout="$(printf '%s' "$PROJECT/.git" | shasum -a 256 | awk '{print $1}')"
  worktree="$(printf '%s' "$PROJECT" | shasum -a 256 | awk '{print $1}')"
  MANAGED="$TRELLIS_HOME/state/git-hooks/$checkout"
  mkdir -p "$TRELLIS_HOME/state/attachments/$checkout" "$MANAGED"
  jq -n --arg managed "$MANAGED" \
    '{git_hooks: {enabled: true, managed_hooks_path: $managed, previous_hooks_path: null, pre_push_source: "core-rules/githooks/pre-push"}}' \
    > "$TRELLIS_HOME/state/attachments/$checkout/$worktree.json"
  git -C "$PROJECT" config --local core.hooksPath "$MANAGED"
  # A recording git shim: every git process the hook starts leaves a line.
  SHIM="$TMP/shim"
  GIT_LOG="$TMP/git.log"
  mkdir -p "$SHIM"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexec %s "$@"\n' "$GIT_LOG" "$(command -v git)" > "$SHIM/git"
  chmod +x "$SHIM/git"
  unset CLAUDE_PROJECT_DIR
  export CODEX_PROJECT_DIR="$PROJECT"
  export TRELLIS_ROOT="$REPO"
}

@test "the Codex twin emits the PostToolUse envelope and needs TRELLIS_ROOT in place" {
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = PostToolUse ] || { echo "$output"; false; }
  # In place without the declared runtime, the shared lib is unreachable: silent.
  unset TRELLIS_ROOT
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

event() {
  jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c, description: "x"}, tool_response: {stdout: "npm make just husky"}}'
}

run_guard() {
  : > "$GIT_LOG"
  run bash -c 'printf "%s" "$1" | PATH="$2:$PATH" "$3"' _ "$(event "$1")" "$SHIM" "$HOOK"
}

ctx() { printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // .additionalContext // empty'; }

@test "a pnpm install that let husky reset core.hooksPath gets the doctor --fix advisory" {
  # What husky's prepare does during the install.
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *'core.hooksPath is ".husky/_"'* ]] || { echo "$output"; false; }
  [[ "$(ctx)" == *husky* ]]
  [[ "$(ctx)" == *'`trellis doctor --fix`'* ]]
  [[ "$(ctx)" != *'git config'* ]] || { echo "$output"; false; }
}

@test "the same install with core.hooksPath intact stays silent" {
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -s "$GIT_LOG" ]
}

@test "git -c core.hooksPath=... worktree add names trellis worktree sync for the new path" {
  run_guard 'git -c core.hooksPath=/tmp/empty-hooks worktree add ../wt'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *'Operator remedy (report it; never run it yourself): `trellis worktree sync ../wt`'* ]] || { echo "$output"; false; }
  [[ "$(ctx)" == *'before its first push'* ]]
}

@test "an env-style GIT_CONFIG_KEY_0=core.hooksPath command runs the check" {
  git -C "$PROJECT" config --local core.hooksPath /elsewhere
  run_guard 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git status'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *'core.hooksPath is "/elsewhere"'* ]] || { echo "$output"; false; }
}

@test "ls, cat Makefile.bak and ls justfile-notes exit silently without a git process" {
  local command
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  for command in 'ls' 'cat Makefile.bak' 'ls justfile-notes' 'echo npm-cache.tar' 'cat .yarnrc'; do
    run_guard "$command"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$command: $output"; false; }
    [ ! -s "$GIT_LOG" ] || { echo "$command started git: $(cat "$GIT_LOG")"; false; }
  done
}

@test "make build and just test run the check" {
  local command
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  for command in 'make build' 'just test' 'NPM ci' 'cd web && npx husky'; do
    run_guard "$command"
    [ "$status" -eq 0 ]
    [ -s "$GIT_LOG" ] || { echo "$command did not run the check"; false; }
    [[ "$(ctx)" == *'trellis doctor --fix'* ]] || { echo "$command: $output"; false; }
  done
}

@test "a wrong path under state/git-hooks and a duplicated managed value are both drift" {
  git -C "$PROJECT" config --local core.hooksPath "$TRELLIS_HOME/state/git-hooks/other"
  run_guard 'npm install'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"state/git-hooks/other"* ]] || { echo "$output"; false; }

  git -C "$PROJECT" config --local core.hooksPath "$MANAGED"
  git -C "$PROJECT" config --local --add core.hooksPath "$MANAGED"
  run_guard 'npm install'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *'2 values'* ]] || { echo "$output"; false; }
  [[ "$(ctx)" == *'trellis doctor --fix'* ]]
}

@test "the guard never writes git config" {
  local before
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  before="$(shasum -a 256 "$PROJECT/.git/config")"
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(shasum -a 256 "$PROJECT/.git/config")" = "$before" ]
}

