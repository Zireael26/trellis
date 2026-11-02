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
  [[ "$output" != *'def alpha'* ]]
  [[ "$output" != *'gamma.py'* ]]
}

@test "after a completed review the next one sees only the delta (codex)" {
  review codex
  [ "$(calls)" -eq 1 ]
  printf 'def epsilon():\n    return 5\n' >> "$PROJECT_DIR/beta.py"
  review codex
  [ "$(calls)" -eq 2 ]
  payload_diff 2 | grep -q '+def epsilon'
  run payload_diff 2
  [[ "$output" != *'def alpha'* ]]
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
