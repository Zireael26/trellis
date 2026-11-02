#!/usr/bin/env bats
# Spec 055 R4.3/R4.4: the PostToolUse(Bash) core.hooksPath drift advisory.
#
# husky's `prepare` runs `git config core.hooksPath .husky/_`; git then never
# invokes the Trellis dispatcher, so the only place left to notice is the
# harness. Fixtures: a throwaway repo, and a private TRELLIS_HOME whose owner
# record enables git hooks with a managed dispatcher path. Nothing reads the
# real ~/.trellis.

HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)/hookspath-guard.sh"
REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"

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
  unset CODEX_PROJECT_DIR
  export CLAUDE_PROJECT_DIR="$PROJECT"
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

# --- Round 5: checkout-wide authority in linked worktrees ---------------------

linked_hooks_fixture() {
  git -C "$PROJECT" -c user.name=test -c user.email=test@example.com \
    -c commit.gpgsign=false commit --allow-empty -qm fixture
  git -C "$PROJECT" worktree add -q --detach "$TMP/linked-worktree" HEAD
  PROJECT="$TMP/linked-worktree"
  worktree="$(printf '%s' "$PROJECT" | shasum -a 256 | awk '{print $1}')"
  printf '{"git_hooks":{"enabled":false}}\n' \
    > "$TRELLIS_HOME/state/attachments/$checkout/$worktree.json"
  export CLAUDE_PROJECT_DIR="$PROJECT"
}

@test "R5: linked-worktree husky reset gets the main owner's advisory" {
  linked_hooks_fixture
  rmdir "$MANAGED"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *'core.hooksPath is ".husky/_"'* ]] || { echo "$output"; false; }
  [[ "$(ctx)" == *"$MANAGED"* ]]
  [[ "$(ctx)" == *'`trellis doctor --fix`'* ]]
}

@test "R5: linked-worktree managed hooksPath stays silent" {
  linked_hooks_fixture
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
  [ -s "$GIT_LOG" ]
}

@test "R5: managed directory alone detects linked-worktree drift" {
  linked_hooks_fixture
  main_worktree="$(printf '%s' "$TMP/project" | shasum -a 256 | awk '{print $1}')"
  rm "$TRELLIS_HOME/state/attachments/$checkout/$main_worktree.json"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"$MANAGED"* ]] || { echo "$output"; false; }
  git -C "$PROJECT" config --local core.hooksPath "$MANAGED"
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "R5: disabled hooks in a truly unmanaged checkout stay silent" {
  printf '{"git_hooks":{"enabled":false}}\n' \
    > "$TRELLIS_HOME/state/attachments/$checkout/$worktree.json"
  rmdir "$MANAGED"
  git -C "$PROJECT" config --local core.hooksPath .husky/_
  run_guard 'pnpm install'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
  [ -s "$GIT_LOG" ]
}

# --- R4.4 rollback sequence ---------------------------------------------------

# Render both local templates, then point .trellis/runtime at a payload that
# lacks the script: the rendered Bash PostToolUse exits 0 without error and
# never falls back to a project-controlled hooks/hookspath-guard.sh.
@test "after a rollback to a payload without the script, the rendered command is inert" {
  local home trellis_home name rendered command marker
  home="$TMP/account" trellis_home="$TMP/render-home" marker="$TMP/project-hook-ran"
  mkdir -p "$home/.local/bin" "$trellis_home" "$TMP/old-payload/core-rules/hooks" "$TMP/old-payload/core-rules/codex/hooks"
  printf '#!/bin/sh\n' > "$home/.local/bin/trellis"
  chmod +x "$home/.local/bin/trellis"
  mkdir -p "$PROJECT/.trellis" "$PROJECT/hooks" "$PROJECT/.claude/hooks" "$PROJECT/.codex/hooks"
  ln -s "$TMP/old-payload" "$PROJECT/.trellis/runtime"
  for f in "$PROJECT/hooks/hookspath-guard.sh" "$PROJECT/.claude/hooks/hookspath-guard.sh" "$PROJECT/.codex/hooks/hookspath-guard.sh"; do
    printf '#!/bin/sh\necho ran >> %s\n' "$marker" > "$f"
    chmod +x "$f"
  done
  for name in claude-settings.local.json codex-hooks.local.json; do
    rendered="$(HOME="$home" bash -c '
      . "$1/scripts/lib/attachment.sh" || exit 90
      context="$(attachment_contextual_render_context "$2")" || exit 91
      attachment_contextual_template_render "$1/core-rules/templates/$3" "core-rules/templates/$3" "$context"
    ' _ "$REPO" "$trellis_home" "$name")"
    # Shell form runs through sh; exec form (Claude) is spawned directly with
    # ${CLAUDE_PROJECT_DIR} substituted in each element, as the client does.
    command="$(printf '%s\n' "$rendered" | jq -r --arg dir "$PROJECT" '
      [.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[]
       | if has("args") then [.command] + .args | map(split("${CLAUDE_PROJECT_DIR}") | join($dir) | @sh) | join(" ")
         else .command end] | .[0]')"
    [[ "$command" == *hookspath-guard.sh* ]] || { echo "$name: $command"; false; }
    run bash -c 'cd "$1" && printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$1" CODEX_PROJECT_DIR="$1" /bin/sh -c "$3"' _ \
      "$PROJECT" "$(event 'pnpm install')" "$command"
    [ "$status" -eq 0 ] || { echo "$name: $status $output"; false; }
    [ -z "$output" ] || { echo "$name: $output"; false; }
    [ ! -e "$marker" ] || { echo "$name ran a project file"; false; }
  done
}
