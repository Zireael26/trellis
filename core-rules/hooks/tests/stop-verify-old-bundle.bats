#!/usr/bin/env bats
# A pre-release native entry can omit a newly required Stop bundle sibling.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project" CODEX_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$HOME" "$CLAUDE_PROJECT_DIR"
}

make_bundle() {
  local harness="$1" kind="${2:-old}" source
  source="$REPO_ROOT/core-rules/hooks"
  [ "$harness" != codex ] || source="$REPO_ROOT/core-rules/codex/hooks"
  BUNDLE="$TRELLIS_HOME/state/native-stop-bundles/fixture/core-rules/hooks"
  [ "$harness" != codex ] || BUNDLE="$TRELLIS_HOME/state/native-stop-bundles/fixture/core-rules/codex/hooks"
  mkdir -p "$BUNDLE/lib"
  cp "$source/stop-verify.sh" "$BUNDLE/stop-verify.sh"
  cp "$source/lib/deps.sh" "$BUNDLE/lib/deps.sh"
  if [ "$kind" = broken ]; then
    printf 'return 1\n' > "$BUNDLE/lib/deps-heavy.sh"
  fi
}

run_bundle() {
  local input="${1:-}"
  [ -n "$input" ] || input='{}'
  run bash -c 'bash "$1" <<<"$2" >"$3" 2>"$4"' _ \
    "$BUNDLE/stop-verify.sh" "$input" "$BATS_TEST_TMPDIR/stdout" "$BATS_TEST_TMPDIR/stderr"
  STDOUT="$(<"$BATS_TEST_TMPDIR/stdout")"
  STDERR="$(<"$BATS_TEST_TMPDIR/stderr")"
}

assert_transport() {
  if [ "$1" = claude ]; then
    [ "$status" -eq 2 ] && [ -z "$STDOUT" ] || return 1
  else
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$STDOUT" | jq -e '.decision == "block"' >/dev/null || return 1
  fi
}

@test "old native Stop bundle blocks with session restart guidance in both harnesses" {
  local harness
  for harness in claude codex; do
    make_bundle "$harness"
    run_bundle
    assert_transport "$harness" || return 1
    [[ "$STDERR" == *"session predates the project's Trellis release"* ]] || return 1
    [[ "$STDERR" == *'restart the session'* ]] || return 1
    [[ "$STDERR" == *'deps-heavy.sh'* ]] || return 1
    [[ "$STDERR$STDOUT" != *'re-run sync'* ]] || return 1
    if [ "$harness" = codex ]; then
      printf '%s' "$STDOUT" | jq -e '.reason | contains("restart the session")' >/dev/null || return 1
    fi
  done
}

@test "old native bundle retains the reentrant Stop loop guard" {
  local harness
  for harness in claude codex; do
    make_bundle "$harness"
    run_bundle '{"stop_hook_active":true}'
    [ "$status" -eq 0 ] && [ -z "$STDOUT" ] && [ -z "$STDERR" ] || return 1
  done
}

@test "an unloadable heavy sibling is not diagnosed as an old session" {
  local harness
  for harness in claude codex; do
    make_bundle "$harness" broken
    run_bundle
    assert_transport "$harness" || return 1
    [[ "$STDERR" == *'unable to load sibling lib deps-heavy.sh'* ]] || return 1
    [[ "$STDERR" != *'restart the session'* ]] || return 1
  done
}

@test "a missing sibling outside a native bundle keeps the ordinary repair diagnosis" {
  local harness ordinary
  for harness in claude codex; do
    make_bundle "$harness"
    ordinary="$BATS_TEST_TMPDIR/deployed-$harness"
    cp -R "$BUNDLE" "$ordinary"
    BUNDLE="$ordinary"
    run_bundle
    assert_transport "$harness" || return 1
    [[ "$STDERR" == *'unable to load sibling lib deps-heavy.sh'* ]] || return 1
    [[ "$STDERR" == *'re-run sync'* ]] || return 1
    [[ "$STDERR" != *'restart the session'* ]] || return 1
  done
}

@test "a dangling heavy sibling is corruption rather than an old bundle file list" {
  local harness
  for harness in claude codex; do
    make_bundle "$harness"
    ln -s "$BATS_TEST_TMPDIR/absent" "$BUNDLE/lib/deps-heavy.sh"
    run_bundle
    assert_transport "$harness" || return 1
    [[ "$STDERR" == *'unable to load sibling lib deps-heavy.sh'* ]] || return 1
    [[ "$STDERR" != *'restart the session'* ]] || return 1
  done
}

@test "old bundle restart block does not require jq" {
  local harness tool tools="$BATS_TEST_TMPDIR/no-jq"
  mkdir -p "$tools"
  for tool in bash cat dirname; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  ! PATH="$tools" command -v jq >/dev/null 2>&1 || return 1
  for harness in claude codex; do
    make_bundle "$harness"
    PATH="$tools" run_bundle
    assert_transport "$harness" || return 1
    [[ "$STDERR" == *'restart the session'* ]] || return 1
  done
}
