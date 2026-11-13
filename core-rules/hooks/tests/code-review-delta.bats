#!/usr/bin/env bats
# Tests for code-review-subagent's delta review, bounded retry and marker
# sweep (spec 072 U8), on both Stop adapters. The reviewer is a rung-1
# CODE_REVIEWER_CMD stub that records each payload, so no real reviewer runs.

load helpers

setup() {
  # Never read or write the operator's ~/.trellis or HOME.
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$HOME"
  setup_project_dir
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/reviewer" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$STUB_DIR/count" 2>/dev/null || printf 0) + 1 ))
printf '%s' "\$n" > "$STUB_DIR/count"
cat > "$STUB_DIR/payload.\$n"
reply="$STUB_DIR/reply.\$n"
[ -f "\$reply" ] || reply="$STUB_DIR/reply"
cat "\$reply"
EOF
  chmod +x "$STUB_DIR/reviewer"
  export CODE_REVIEWER_CMD="$STUB_DIR/reviewer"
  reply '{"status":"completed","findings":[]}'
  # Four new code files clear the edit-heavy gate (>= 3 files).
  local f
  for f in alpha beta gamma delta; do
    printf 'def %s():\n    return 1\n' "$f" > "$PROJECT_DIR/$f.py"
  done
}

teardown() {
  teardown_project_dir
}

reply() { printf '%s\n' "$1" > "$STUB_DIR/reply${2:+.$2}"; }
calls() { cat "$STUB_DIR/count" 2>/dev/null || printf 0; }
payload_diff() { jq -r '.diff' "$STUB_DIR/payload.$1"; }

hook_for() {
  if [ "$1" = codex ]; then printf '%s' "$CODEX_HOOKS_DIR/code-review-subagent.sh"; else printf '%s' "$HOOKS_DIR/code-review-subagent.sh"; fi
}
marker_dir() { if [ "$1" = codex ]; then printf '%s/.codex' "$PROJECT_DIR"; else printf '%s/.claude' "$PROJECT_DIR"; fi; }
markers() { find "$(marker_dir "$1")" -maxdepth 1 -type f -name '.review-done-*' 2>/dev/null | wc -l | tr -d ' '; }
state_files() { find "$TRELLIS_HOME/state/code-review" -type f -name "$1" 2>/dev/null | wc -l | tr -d ' '; }

# In place, the Codex hook finds the shared reviewer only under its runtime root.
review() {
  if [ "$1" = codex ]; then
    TRELLIS_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)" run_with_stderr "$(hook_for "$1")" '{}'
  else
    run_with_stderr "$(hook_for "$1")" '{}'
  fi
}

@test "143-stop review includes staged source files before the first commit" {
  teardown_project_dir
  PROJECT_DIR="$BATS_TEST_TMPDIR/unborn"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  local f h n=0
  for f in alpha beta gamma; do printf 'UNBORN_%s = 1\n' "$f" > "$PROJECT_DIR/$f.py"; done
  git -C "$PROJECT_DIR" add alpha.py beta.py gamma.py
  for h in claude codex; do
    review "$h"
    [ "$status" -eq 0 ]
    n=$((n + 1))
    [ "$(calls)" -eq "$n" ]
    payload_diff "$n" | grep -q 'UNBORN_gamma'
    [ "$(markers "$h")" -eq 1 ]
    review "$h"
    [ "$(calls)" -eq "$n" ]
  done
}

@test "143-stop review from a subdirectory covers untracked files throughout the worktree" {
  mkdir -p "$PROJECT_DIR/pkg" "$PROJECT_DIR/other"
  local f h n=0
  for f in one two three; do printf 'local_%s = 1\n' "$f" > "$PROJECT_DIR/pkg/$f.py"; done
  printf 'outside_marker = 42\n' > "$PROJECT_DIR/other/new.py"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR/pkg" CODEX_PROJECT_DIR="$PROJECT_DIR/pkg"
  for h in claude codex; do
    review "$h"
    [ "$status" -eq 0 ]
    n=$((n + 1))
    [ "$(calls)" -eq "$n" ]
    payload_diff "$n" | grep -q 'outside_marker = 42'
    payload_diff "$n" | grep -q 'local_one = 1'
    [ "$(markers "$h")" -eq 1 ]
  done
}

@test "143-stop quoted untracked paths count lines and reach the reviewer" {
  teardown_project_dir
  PROJECT_DIR="$BATS_TEST_TMPDIR/unicode"
  mkdir -p "$PROJECT_DIR/src"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" commit --allow-empty -qm init
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  local f="$PROJECT_DIR/src/café.ts" h n=0
  printf 'unicode_marker = 42\n' > "$f"
  awk 'BEGIN { for(i=0;i<210;i++) print "ordinary line" }' >> "$f"
  for h in claude codex; do
    review "$h"
    [ "$status" -eq 0 ]
    n=$((n + 1))
    [ "$(calls)" -eq "$n" ]
    payload_diff "$n" | grep -q 'unicode_marker = 42'
    [ "$(markers "$h")" -eq 1 ]
  done
}

@test "143-stop review preserves quote backslash and newline path bytes" {
  teardown_project_dir
  PROJECT_DIR="$BATS_TEST_TMPDIR/unusual"
  mkdir -p "$PROJECT_DIR/src"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" commit --allow-empty -qm init
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  printf 'quoted_path_marker\n' > "$PROJECT_DIR/src/quote\".ts"
  printf 'backslash_path_marker\n' > "$PROJECT_DIR/src/\\literal.ts"
  printf 'newline_path_marker\n' > "$PROJECT_DIR/src/"$'line\nbreak.ts'
  local h n=0
  for h in claude codex; do
    review "$h"
    [ "$status" -eq 0 ]
    n=$((n + 1))
    [ "$(calls)" -eq "$n" ]
    payload_diff "$n" | grep -q 'quoted_path_marker'
    payload_diff "$n" | grep -q 'backslash_path_marker'
    payload_diff "$n" | grep -q 'newline_path_marker'
  done
}

@test "143-stop review skips documentation-only untracked unicode paths" {
  teardown_project_dir
  PROJECT_DIR="$BATS_TEST_TMPDIR/unicode-docs"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" commit --allow-empty -qm init
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  local i h
  for i in 1 2 3; do printf '# notes\n' > "$PROJECT_DIR/café$i.md"; done
  for h in claude codex; do
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq 0 ]
  done
}

@test "143-stop review still skips small untracked changes" {
  teardown_project_dir
  PROJECT_DIR="$BATS_TEST_TMPDIR/small"
  mkdir -p "$PROJECT_DIR"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" commit --allow-empty -qm init
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  printf 'small = true\n' > "$PROJECT_DIR/café.ts"
  local h
  for h in claude codex; do
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq 0 ]
  done
}

@test "after a completed review the next one sees only the delta (claude)" {
  review claude
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  payload_diff 1 | grep -q 'def alpha'
  printf 'def epsilon():\n    return 5\n' >> "$PROJECT_DIR/beta.py"
  review claude
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
  payload_diff 2 | grep -q '+def epsilon'
  run payload_diff 2
  [[ "$output" != *'def alpha'* ]] || false
  [[ "$output" != *'gamma.py'* ]] || false
}

@test "after a completed review the next one sees only the delta (codex)" {
  review codex
  [ "$(calls)" -eq 1 ]
  printf 'def epsilon():\n    return 5\n' >> "$PROJECT_DIR/beta.py"
  review codex
  [ "$(calls)" -eq 2 ]
  payload_diff 2 | grep -q '+def epsilon'
  run payload_diff 2
  [[ "$output" != *'def alpha'* ]] || false
}

@test "a commit that leaves the reviewed tree unchanged is not reviewed again" {
  review claude
  [ "$(calls)" -eq 1 ]
  git -C "$PROJECT_DIR" add alpha.py
  git -C "$PROJECT_DIR" commit -qm alpha
  review claude
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
}

@test "a recorded tree that is unreadable, or a HEAD that is not an ancestor, falls back to the full diff" {
  review claude
  local state; state=$(find "$TRELLIS_HOME/state/code-review" -type f -name 'reviewed.claude')
  [ -n "$state" ]
  printf '%s %s\n' "$(git -C "$PROJECT_DIR" rev-parse HEAD)" 0123456789012345678901234567890123456789 > "$state"
  echo 'x = 1' >> "$PROJECT_DIR/beta.py"
  review claude
  [ "$(calls)" -eq 2 ]
  payload_diff 2 | grep -q 'def alpha'
  # A recorded HEAD from unrelated history: full diff again.
  local tree; tree=$(cut -d' ' -f2 "$state")
  printf '%s %s\n' 0123456789012345678901234567890123456789 "$tree" > "$state"
  echo 'y = 1' >> "$PROJECT_DIR/beta.py"
  review claude
  [ "$(calls)" -eq 3 ]
  payload_diff 3 | grep -q 'def alpha'
}

@test "a changed completion reference invalidates exact and covered captures on either adapter" {
  local h state n head tree context
  for h in claude codex; do
    review "$h"
    n=$(calls)
    state=$(find "$TRELLIS_HOME/state/code-review" -type f -name "reviewed.$h")
    [ -n "$state" ]
    read -r head tree context < "$state"
    printf '%s %s %s\n' "$head" 0123456789012345678901234567890123456789 "$context" > "$state"
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq "$((n + 1))" ]
    payload_diff "$((n + 1))" | grep -q 'def alpha'
  done
}

@test "unreadable coverage cannot reuse an exact capture or an older completed base on either adapter" {
  local h state n tmp
  for h in claude codex; do
    review "$h"
    n=$(calls)
    state=$(find "$TRELLIS_HOME/state/code-review" -type f -name "covered.$h.json")
    [ -n "$state" ]
    tmp="$state.test-tmp"
    jq '.tree = "0123456789012345678901234567890123456789"' "$state" > "$tmp"
    mv "$tmp" "$state"
    # No worktree change: a still-valid exact capture must not hide the fault.
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq "$((n + 1))" ]
    payload_diff "$((n + 1))" | grep -q 'def alpha'
  done
}

# This guards fallback/reference bookkeeping, not the rewrite heuristic in
# 28239f6e. Its load-bearing scope oracle is dispatch's B10 D2 R7 M-1 case
# (test12 in the review's focused filter), plus the explicit R8 L-k cases.
@test "unrelated covered history falls back to HEAD rather than attributing another branch on either adapter" {
  local h state n tmp tree unrelated
  tree=$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')
  unrelated=$(git -C "$PROJECT_DIR" commit-tree "$tree" -m 'unrelated review coverage')
  for h in claude codex; do
    review "$h"
    n=$(calls)
    state=$(find "$TRELLIS_HOME/state/code-review" -type f -name "covered.$h.json")
    [ -n "$state" ]
    tmp="$state.test-tmp"
    jq --arg head "$unrelated" '.head = $head' "$state" > "$tmp"
    mv "$tmp" "$state"
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq "$((n + 1))" ]
    payload_diff "$((n + 1))" | grep -q 'def alpha'
    printf 'new_after_history = 1\n' >> "$PROJECT_DIR/beta.py"
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq "$((n + 2))" ]
    payload_diff "$((n + 2))" | grep -q '+new_after_history'
    run payload_diff "$((n + 2))"
    [[ "$output" != *'def alpha'* ]] || false
  done
}

@test "a failed review is retried at most three times, then every Stop says it is unreviewed" {
  reply 'not-json'
  local i
  for i in 1 2 3; do
    review claude
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"review degraded"*"attempt $i of 3"* ]] || { echo "$stderr"; false; }
    [ -z "$output" ]
  done
  [ "$(calls)" -eq 3 ]
  for i in 1 2; do
    review claude
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq 3 ]
    printf '%s' "$output" | jq -e '.additionalContext | test("UNREVIEWED")' >/dev/null
  done
  # Never a pass in disguise: no marker and no reviewed tree were recorded.
  [ "$(markers claude)" -eq 0 ]
  [ "$(state_files 'reviewed.*')" -eq 0 ]
  # A changed diff is retried.
  echo 'z = 1' >> "$PROJECT_DIR/beta.py"
  review claude
  [ "$(calls)" -eq 4 ]
}

@test "the retry bound and unreviewed warning hold on the Codex adapter" {
  reply 'not-json'
  local i
  for i in 1 2 3; do review codex; done
  [ "$(calls)" -eq 3 ]
  review codex
  [ "$(calls)" -eq 3 ]
  printf '%s' "$output" | jq -e '.systemMessage | test("UNREVIEWED")' >/dev/null
  [ "$(markers codex)" -eq 0 ]
}

@test "a reviewer that fails twice then succeeds still completes the review" {
  reply 'not-json' 1
  reply '{"status":"degraded","findings":[]}' 2
  review claude
  review claude
  [ "$(markers claude)" -eq 0 ]
  review claude
  [ "$(calls)" -eq 3 ]
  [ "$(markers claude)" -eq 1 ]
  [ "$(state_files 'reviewed.claude')" -eq 1 ]
  [ "$(state_files 'fail.*')" -eq 0 ]
}

@test "a critical block records nothing, so the fix is reviewed with the flagged code" {
  review claude
  [ "$(calls)" -eq 1 ]
  printf 'def bad():\n    return None\n' >> "$PROJECT_DIR/beta.py"
  reply '{"status":"completed","findings":[{"severity":"critical","file":"beta.py","msg":"flagged"}]}' 2
  review claude
  [ "$status" -eq 2 ]
  printf 'def fixed():\n    return 1\n' >> "$PROJECT_DIR/gamma.py"
  review claude
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 3 ]
  payload_diff 3 | grep -q '+def bad'
  payload_diff 3 | grep -q '+def fixed'
}

@test "markers older than 7 days are swept after a completed review" {
  mkdir -p "$PROJECT_DIR/.claude"
  : > "$PROJECT_DIR/.claude/.review-done-old"
  : > "$PROJECT_DIR/.claude/.review-done-fresh"
  touch -t 202001010000 "$PROJECT_DIR/.claude/.review-done-old"
  review claude
  [ ! -e "$PROJECT_DIR/.claude/.review-done-old" ]
  [ -e "$PROJECT_DIR/.claude/.review-done-fresh" ]
  [ "$(markers claude)" -eq 2 ]
}

@test "a later edit to a tracked file in the harness directory is reviewed (both adapters)" {
  local h dir
  for h in claude codex; do
    if [ "$h" = codex ]; then dir=.codex; else dir=.claude; fi
    mkdir -p "$PROJECT_DIR/$dir/hooks"
    printf '#!/bin/sh\necho one\n' > "$PROJECT_DIR/$dir/hooks/tracked.sh"
    git -C "$PROJECT_DIR" add "$dir/hooks/tracked.sh"
    git -C "$PROJECT_DIR" commit -qm "tracked $h hook"
    local before; before=$(calls)
    review "$h"
    [ "$(calls)" -eq $((before + 1)) ]
    printf 'echo two\n' >> "$PROJECT_DIR/$dir/hooks/tracked.sh"
    review "$h"
    [ "$status" -eq 0 ]
    [ "$(calls)" -eq $((before + 2)) ]
    payload_diff "$(calls)" | grep -q '+echo two'
  done
}
