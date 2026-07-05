#!/usr/bin/env bats
# Codex mirror tests for propose-rules.sh.

HOOK="$BATS_TEST_DIRNAME/../propose-rules.sh"

setup_editheavy_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/codex-prop.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git config user.email "ci-bats@trellis.test"
    git config user.name "Trellis CI"
    git commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n' > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR
}

setup_transcript_with_signal() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/codex-transcript.txt"
  {
    printf '%s\n' 'user: please refactor the parser'
    printf '%s\n' 'assistant: done, used a recursive descent approach'
    printf '%s\n' "user: no, do not use recursion here - it overflows on deep input"
  } > "$TRANSCRIPT"
  export CODEX_TRANSCRIPT_PATH="$TRANSCRIPT"
  unset CLAUDE_TRANSCRIPT_PATH
}

teardown() {
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR CODEX_TRANSCRIPT_PATH \
        CLAUDE_TRANSCRIPT_PATH TRELLIS_REVIEW_IN_PROGRESS \
        PROCESS_GATE_PROPOSE_RULES
  return 0
}

run_with_stderr() {
  local script="$1" input="$2" stderr_file
  stderr_file="$(mktemp)"
  set +e
  output="$(printf '%s' "$input" | bash "$script" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}

install_fake_claude() {
  local countfile="$1" envfile="${2:-}" bindir
  bindir="$BATS_TEST_TMPDIR/fakebin.$$.$RANDOM"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'
    printf 'printf %s >> %s\n' "'x'" "$(_shq "$countfile")"
    if [ -n "$envfile" ]; then
      printf 'printf %s "${TRELLIS_REVIEW_IN_PROGRESS:-UNSET}" > %s\n' '%s' "$(_shq "$envfile")"
    fi
    printf '%s\n' 'printf "%s\n" "## 2026-07-03 - avoid recursion"'
  } > "$bindir/claude"
  chmod +x "$bindir/claude"
  printf '%s' "$bindir:$PATH"
}

_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

claude_call_count() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  wc -c < "$f" | tr -d ' '
}

run_hook() {
  run_with_stderr "$HOOK" '{}'
}

@test "codex propose-rules syntax is valid" {
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "codex transcript + project vars reach claude with recursion sentinel exported" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/default.count"; : > "$COUNT"
  ENVF="$BATS_TEST_TMPDIR/default.env"; : > "$ENVF"
  PATH="$(install_fake_claude "$COUNT" "$ENVF")"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -ge 1 ]
  [ "$(cat "$ENVF")" = "1" ]
}

@test "codex explicit opt-out exits without invoking claude" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/optout.count"; : > "$COUNT"
  PATH="$(install_fake_claude "$COUNT")"
  export PROCESS_GATE_PROPOSE_RULES=0

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
}
