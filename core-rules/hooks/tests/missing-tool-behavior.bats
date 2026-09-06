#!/usr/bin/env bats

load helpers

make_path_without() {
  local missing="$1" out cmd source
  out="$BATS_TEST_TMPDIR/path-without-$missing"
  mkdir -p "$out"
  for cmd in jq cat dirname awk head tr wc; do
    [ "$cmd" = "$missing" ] && continue
    source="$(command -v "$cmd" 2>/dev/null)"
    [ -n "$source" ] || continue
    ln -sf "$source" "$out/$cmd"
  done
  printf '%s' "$out"
}

run_hook_without() {
  local missing="$1" hook="$2" input="$3" tool_path stderr_file
  tool_path="$(make_path_without "$missing")"
  stderr_file="$BATS_TEST_TMPDIR/$missing.stderr"
  mkdir -p "$BATS_TEST_TMPDIR/project" "$BATS_TEST_TMPDIR/home"

  set +e
  output="$(printf '%s' "$input" | PATH="$tool_path" HOME="$BATS_TEST_TMPDIR/home" \
    CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" TMPDIR="$BATS_TEST_TMPDIR" \
    /bin/bash "$hook" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
}

assert_missing_tool_notice() {
  local hook_name="$1" tool="$2"
  [[ "$stderr" == *"$hook_name"* ]]
  [[ "$stderr" == *"$tool"* ]]
}

@test "missing jq fails closed in skill-slash-guard" {
  run_hook_without jq "$HOOKS_DIR/skill-slash-guard.sh" '{}'

  [ "$status" -ne 0 ]
  assert_missing_tool_notice skill-slash-guard jq
}

@test "missing jq fails closed in skill-preload-guard" {
  run_hook_without jq "$HOOKS_DIR/skill-preload-guard.sh" '{}'

  [ "$status" -ne 0 ]
  assert_missing_tool_notice skill-preload-guard jq
}

@test "missing jq degrades visibly in skill-size-preflight" {
  run_hook_without jq "$HOOKS_DIR/skill-size-preflight.sh" '{}'

  [ "$status" -eq 0 ]
  assert_missing_tool_notice skill-size-preflight jq
}

@test "missing jq or git degrades visibly in wiki-skill-suggest" {
  run_hook_without jq "$HOOKS_DIR/wiki-skill-suggest.sh" '{}'
  [ "$status" -eq 0 ]
  assert_missing_tool_notice wiki-skill-suggest jq

  run_hook_without git "$HOOKS_DIR/wiki-skill-suggest.sh" '{}'
  [ "$status" -eq 0 ]
  assert_missing_tool_notice wiki-skill-suggest git
}

@test "missing jq or git degrades visibly in Codex wiki-skill-suggest" {
  run_hook_without jq "$CODEX_HOOKS_DIR/wiki-skill-suggest.sh" '{}'
  [ "$status" -eq 0 ]
  assert_missing_tool_notice wiki-skill-suggest jq

  run_hook_without git "$CODEX_HOOKS_DIR/wiki-skill-suggest.sh" '{}'
  [ "$status" -eq 0 ]
  assert_missing_tool_notice wiki-skill-suggest git
}

@test "missing git degrades visibly in primer-capture-nudge" {
  run_hook_without git "$HOOKS_DIR/primer-capture-nudge.sh" '{}'

  [ "$status" -eq 0 ]
  assert_missing_tool_notice primer-capture-nudge git
}

@test "missing git degrades visibly in session-context" {
  run_hook_without git "$HOOKS_DIR/session-context.sh" '{"source":"startup"}'

  [ "$status" -eq 0 ]
  assert_missing_tool_notice session-context git
}
