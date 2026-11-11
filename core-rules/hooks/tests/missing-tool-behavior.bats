#!/usr/bin/env bats

load helpers

setup() {
  # Never read the operator's ~/.trellis.
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
}

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

  # Exit 2 blocks the expansion; exit 1 would let it run.
  [ "$status" -eq 2 ]
  assert_missing_tool_notice skill-slash-guard jq
}

@test "missing jq blocks slash expansion in both hook trees" {
  local hooks
  for hooks in "$HOOKS_DIR" "$CODEX_HOOKS_DIR"; do
    run_hook_without jq "$hooks/skill-slash-guard.sh" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"probe"}'
    [ "$status" -eq 2 ]
    assert_missing_tool_notice skill-slash-guard jq
  done
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

@test "missing sibling lib fails closed in block-destructive (both trees)" {
  local hooks hook tmp_hook tmp_lib input
  for hooks in "$HOOKS_DIR" "$CODEX_HOOKS_DIR"; do
    tmp_hook="$BATS_TEST_TMPDIR/block-destructive-missing-lib.sh"
    cp "$hooks/block-destructive.sh" "$tmp_hook"
    # Point the hook at a lib dir with no guard-rules.sh by rewriting dirname lookup.
    # Simpler: copy the hook alongside an empty lib dir so both sibling checks miss.
    mkdir -p "$BATS_TEST_TMPDIR/empty-lib"
    # Run with the hook file in a dir whose lib/ has no deps.sh or guard-rules.sh.
    mkdir -p "$BATS_TEST_TMPDIR/fake-hooks/lib"
    cp "$hooks/block-destructive.sh" "$BATS_TEST_TMPDIR/fake-hooks/block-destructive.sh"
    input=$(jq -nc '{tool_input: {command: "rm -rf /tmp/x"}}')
    set +e
    output=$(printf '%s' "$input" | HOME="$BATS_TEST_TMPDIR/home" CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR/project" TMPDIR="$BATS_TEST_TMPDIR" /bin/bash "$BATS_TEST_TMPDIR/fake-hooks/block-destructive.sh" 2>"$BATS_TEST_TMPDIR/block.stderr")
    status=$?
    set -e
    stderr=$(cat "$BATS_TEST_TMPDIR/block.stderr")
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"missing sibling lib"* ]]
    rm -rf "$BATS_TEST_TMPDIR/fake-hooks"
  done
}

@test "missing sibling lib fails closed in reread-guard (both trees)" {
  local hooks input
  for hooks in "$HOOKS_DIR" "$CODEX_HOOKS_DIR"; do
    mkdir -p "$BATS_TEST_TMPDIR/fake-reread/lib"
    cp "$hooks/reread-guard.sh" "$BATS_TEST_TMPDIR/fake-reread/reread-guard.sh"
    input=$(jq -nc '{tool_input: {file_path: "/tmp/x"}}')
    set +e
    output=$(printf '%s' "$input" | HOME="$BATS_TEST_TMPDIR/home" CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR/project" TMPDIR="$BATS_TEST_TMPDIR" /bin/bash "$BATS_TEST_TMPDIR/fake-reread/reread-guard.sh" 2>"$BATS_TEST_TMPDIR/reread.stderr")
    status=$?
    set -e
    stderr=$(cat "$BATS_TEST_TMPDIR/reread.stderr")
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"missing sibling lib"* ]]
    rm -rf "$BATS_TEST_TMPDIR/fake-reread"
  done
}

@test "sweep-fx1-L3: each missing sibling lib fails closed" {
  local hooks input real_lib
  for hooks in "$HOOKS_DIR" "$CODEX_HOOKS_DIR"; do
    real_lib="$hooks/lib"
    # block-destructive: guard-rules missing (deps present)
    rm -rf "$BATS_TEST_TMPDIR/fake-bd"
    mkdir -p "$BATS_TEST_TMPDIR/fake-bd/lib"
    cp "$hooks/block-destructive.sh" "$BATS_TEST_TMPDIR/fake-bd/block-destructive.sh"
    cp "$real_lib/deps.sh" "$BATS_TEST_TMPDIR/fake-bd/lib/deps.sh"
    input=$(jq -nc '{tool_input: {command: "rm -rf /tmp/x"}}')
    set +e
    output=$(printf '%s' "$input" | HOME="$BATS_TEST_TMPDIR/home" CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR/project" TMPDIR="$BATS_TEST_TMPDIR" /bin/bash "$BATS_TEST_TMPDIR/fake-bd/block-destructive.sh" 2>"$BATS_TEST_TMPDIR/bd2.stderr")
    status=$?
    set -e
    stderr=$(cat "$BATS_TEST_TMPDIR/bd2.stderr")
    [ "$status" -eq 2 ] || { echo "block-destructive guard-rules missing: status $status stderr $stderr"; false; }
    [[ "$stderr" == *"missing sibling lib"* ]]
    rm -rf "$BATS_TEST_TMPDIR/fake-bd"
    # reread-guard: autonomy missing (deps present)
    rm -rf "$BATS_TEST_TMPDIR/fake-rr1"
    mkdir -p "$BATS_TEST_TMPDIR/fake-rr1/lib"
    cp "$hooks/reread-guard.sh" "$BATS_TEST_TMPDIR/fake-rr1/reread-guard.sh"
    cp "$real_lib/deps.sh" "$BATS_TEST_TMPDIR/fake-rr1/lib/deps.sh"
    # autonomy may live beside lib (check both)
    input=$(jq -nc '{tool_input: {file_path: "/tmp/x"}}')
    set +e
    output=$(printf '%s' "$input" | HOME="$BATS_TEST_TMPDIR/home" CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR/project" TMPDIR="$BATS_TEST_TMPDIR" /bin/bash "$BATS_TEST_TMPDIR/fake-rr1/reread-guard.sh" 2>"$BATS_TEST_TMPDIR/rr1.stderr")
    status=$?
    set -e
    stderr=$(cat "$BATS_TEST_TMPDIR/rr1.stderr")
    [ "$status" -eq 2 ] || { echo "reread autonomy missing: status $status stderr $stderr"; false; }
    [[ "$stderr" == *"missing sibling"* ]]
    rm -rf "$BATS_TEST_TMPDIR/fake-rr1"
    # reread-guard: guard-rules missing (deps+autonomy present)
    rm -rf "$BATS_TEST_TMPDIR/fake-rr2"
    mkdir -p "$BATS_TEST_TMPDIR/fake-rr2/lib"
    cp "$hooks/reread-guard.sh" "$BATS_TEST_TMPDIR/fake-rr2/reread-guard.sh"
    cp "$real_lib/deps.sh" "$BATS_TEST_TMPDIR/fake-rr2/lib/deps.sh"
    if [ -f "$real_lib/autonomy.sh" ]; then cp "$real_lib/autonomy.sh" "$BATS_TEST_TMPDIR/fake-rr2/lib/autonomy.sh"; fi
    if [ -f "$hooks/../lib/autonomy.sh" ]; then cp "$hooks/../lib/autonomy.sh" "$BATS_TEST_TMPDIR/fake-rr2/lib/autonomy.sh" 2>/dev/null || true; fi
    # Also try hooks/lib/autonomy (Claude) vs codex layout
    cp "$HOOKS_DIR/lib/autonomy.sh" "$BATS_TEST_TMPDIR/fake-rr2/lib/autonomy.sh" 2>/dev/null || true
    input=$(jq -nc '{tool_input: {file_path: "/tmp/x"}}')
    set +e
    output=$(printf '%s' "$input" | HOME="$BATS_TEST_TMPDIR/home" CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR/project" TMPDIR="$BATS_TEST_TMPDIR" /bin/bash "$BATS_TEST_TMPDIR/fake-rr2/reread-guard.sh" 2>"$BATS_TEST_TMPDIR/rr2.stderr")
    status=$?
    set -e
    stderr=$(cat "$BATS_TEST_TMPDIR/rr2.stderr")
    [ "$status" -eq 2 ] || { echo "reread guard-rules missing: status $status stderr $stderr"; false; }
    [[ "$stderr" == *"missing sibling"* ]]
    rm -rf "$BATS_TEST_TMPDIR/fake-rr2"
  done
}
