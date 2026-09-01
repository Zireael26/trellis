#!/usr/bin/env bats

ROOT="$(CDPATH= cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/commit-hooks sandbox"
  PSEUDO_REPO="$SANDBOX/pseudo repository"
  HOOK_BIN="$SANDBOX/bin"
  TRACE="$SANDBOX/call trace.log"

  mkdir -p "$PSEUDO_REPO/.git" "$PSEUDO_REPO/.husky" \
    "$PSEUDO_REPO/scripts" "$PSEUDO_REPO/home" "$PSEUDO_REPO/tmp" \
    "$HOOK_BIN"
  : > "$TRACE"

  PRECOMMIT_MISSING=""
  PRECOMMIT_NONEXEC=""
  PRECOMMIT_FAIL_SCRIPT=""
  PRECOMMIT_FAIL_STATUS=37
  COMMIT_CHECKER_STATUS=0
}

hook_source_root() {
  local configured="${TRELLIS_HOOK_SOURCE_ROOT:-}"
  if [ -n "$configured" ]; then
    case "$configured" in
      /*) printf '%s\n' "$configured" ;;
      *) printf '%s/%s\n' "$ROOT" "$configured" ;;
    esac
  else
    printf '%s/.husky\n' "$ROOT"
  fi
}

copy_hook() {
  local hook="$1" source
  source="$(hook_source_root)/$hook"
  if [ ! -e "$source" ]; then
    printf 'hook source is missing: %s\n' "$source" >&2
    return 1
  fi
  cp "$source" "$PSEUDO_REPO/.husky/$hook"
  chmod 755 "$PSEUDO_REPO/.husky/$hook"
}

write_node_stub() {
  cat > "$HOOK_BIN/node" <<'EOF'
#!/bin/sh
printf 'node|%s\n' "$*" >> "${TRELLIS_HOOK_TRACE}.node"
exit 0
EOF
  chmod 755 "$HOOK_BIN/node"
}

write_bash_stub() {
  cat > "$HOOK_BIN/bash" <<'EOF'
#!/bin/sh
script="${1:-}"
if [ "$#" -eq 0 ]; then
  printf '[stub-bash] missing script\n' >&2
  exit 64
fi
shift
printf 'bash|%s' "$script" >> "$TRELLIS_HOOK_TRACE"
for arg do
  printf '|%s' "$arg" >> "$TRELLIS_HOOK_TRACE"
done
printf '\n' >> "$TRELLIS_HOOK_TRACE"
case "$script" in
  scripts/run-tests.sh|scripts/check-skill-sizes.sh|scripts/lint-recipe-routing.sh|scripts/lint-prompt-shell-blocks.sh) ;;
  *)
    printf '[stub-bash] unexpected script: %s\n' "$script" >&2
    exit 64
    ;;
esac
exec /bin/sh "$TRELLIS_HOOK_REPO/$script" "$@"
EOF
  chmod 755 "$HOOK_BIN/bash"
}

write_commit_checker() {
  cat > "$PSEUDO_REPO/scripts/check-commit-message.sh" <<'EOF'
#!/bin/sh
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  printf '[stub-checker] expected one existing message-file argument\n' >&2
  exit 64
fi
printf 'checker|%s\n' "$1" >> "$TRELLIS_HOOK_TRACE"
if [ "${TRELLIS_COMMIT_CHECKER_STATUS:-0}" -ne 0 ]; then
  printf '[stub-checker] rejected\n' >&2
  exit "$TRELLIS_COMMIT_CHECKER_STATUS"
fi
exit 0
EOF
  chmod 755 "$PSEUDO_REPO/scripts/check-commit-message.sh"
}

write_precommit_stubs() {
  local script
  : > "$PSEUDO_REPO/decisions-log.md"
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    [ "$script" = "${PRECOMMIT_MISSING:-}" ] && continue
    cat > "$PSEUDO_REPO/$script" <<'EOF'
#!/bin/sh
name="${0##*/}"
printf 'script|%s' "$name" >> "$TRELLIS_HOOK_TRACE"
for arg do
  printf '|%s' "$arg" >> "$TRELLIS_HOOK_TRACE"
done
printf '\n' >> "$TRELLIS_HOOK_TRACE"
if [ "$name" = "${TRELLIS_HOOK_FAIL_SCRIPT:-}" ]; then
  printf '[stub-script] %s rejected\n' "$name" >&2
  exit "${TRELLIS_HOOK_FAIL_STATUS:-37}"
fi
exit 0
EOF
    if [ "$script" = "${PRECOMMIT_NONEXEC:-}" ]; then
      chmod 644 "$PSEUDO_REPO/$script"
    else
      chmod 755 "$PSEUDO_REPO/$script"
    fi
  done <<'EOF'
scripts/run-tests.sh
scripts/check-skill-sizes.sh
scripts/lint-recipe-routing.sh
scripts/lint-prompt-shell-blocks.sh
EOF
}

run_hook() {
  local hook="$1"
  shift
  (
    cd "$PSEUDO_REPO" || exit 1
    /usr/bin/env -i \
      "PATH=$HOOK_BIN" \
      "HOME=$PSEUDO_REPO/home" \
      "TMPDIR=$PSEUDO_REPO/tmp" \
      "TRELLIS_HOOK_TRACE=$TRACE" \
      "TRELLIS_HOOK_REPO=$PSEUDO_REPO" \
      "TRELLIS_HOOK_FAIL_SCRIPT=${PRECOMMIT_FAIL_SCRIPT:-}" \
      "TRELLIS_HOOK_FAIL_STATUS=${PRECOMMIT_FAIL_STATUS:-37}" \
      "TRELLIS_COMMIT_CHECKER_STATUS=${COMMIT_CHECKER_STATUS:-0}" \
      /bin/sh ".husky/$hook" "$@"
  )
}

assert_output_contains() {
  local expected="$1"
  case "$output" in
    *"$expected"*) ;;
    *)
      printf 'expected output to contain:\n%s\nactual output:\n%s\n' \
        "$expected" "$output" >&2
      return 1
      ;;
  esac
}

assert_trace_is() {
  local expected="$1" actual
  actual="$(cat "$TRACE")"
  if [ "$actual" != "$expected" ]; then
    printf 'expected call trace:\n%s\nactual call trace:\n%s\n' \
      "$expected" "$actual" >&2
    return 1
  fi
}

assert_pseudo_repo_safe() {
  [ -d "$PSEUDO_REPO/.git" ]
  [ ! -e "$PSEUDO_REPO/.git/index" ]
}

@test "commit-msg propagates a rejecting checker and passes exactly the message-file argument" {
  write_node_stub
  write_commit_checker
  copy_hook commit-msg

  message_file="$PSEUDO_REPO/commit message.txt"
  printf '%s\n' 'feat(hooks): exercise the commit checker' > "$message_file"
  COMMIT_CHECKER_STATUS=23

  run run_hook commit-msg "$message_file"

  [ "$status" -eq 23 ]
  assert_output_contains '[stub-checker] rejected'
  assert_trace_is "checker|$message_file"
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "commit-msg accepts a successful checker result" {
  write_node_stub
  write_commit_checker
  copy_hook commit-msg

  message_file="$PSEUDO_REPO/commit message.txt"
  printf '%s\n' 'fix(hooks): exercise the accepted path' > "$message_file"
  COMMIT_CHECKER_STATUS=0

  run run_hook commit-msg "$message_file"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_trace_is "checker|$message_file"
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "commit-msg fails closed when its executable checker is absent" {
  write_node_stub
  copy_hook commit-msg

  message_file="$PSEUDO_REPO/commit message.txt"
  printf '%s\n' 'feat(hooks): checker is intentionally absent' > "$message_file"

  run run_hook commit-msg "$message_file"

  [ "$status" -eq 1 ]
  assert_output_contains 'required checker missing or not executable'
  assert_output_contains 'scripts/check-commit-message.sh'
  assert_trace_is ''
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "commit-msg fails closed when its checker is not executable" {
  write_node_stub
  write_commit_checker
  chmod 644 "$PSEUDO_REPO/scripts/check-commit-message.sh"
  copy_hook commit-msg

  message_file="$PSEUDO_REPO/commit message.txt"
  printf '%s\n' 'feat(hooks): checker mode is intentionally invalid' > "$message_file"

  run run_hook commit-msg "$message_file"

  [ "$status" -eq 1 ]
  assert_output_contains 'required checker missing or not executable'
  assert_output_contains 'scripts/check-commit-message.sh'
  assert_trace_is ''
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "commit-msg runs and propagates a rejecting checker when Node is unavailable" {
  write_commit_checker
  copy_hook commit-msg

  message_file="$PSEUDO_REPO/commit message.txt"
  printf '%s\n' 'not a conventional header, but the checker must still run' > "$message_file"
  COMMIT_CHECKER_STATUS=23

  run run_hook commit-msg "$message_file"

  [ "$status" -eq 23 ]
  assert_output_contains '[stub-checker] rejected'
  assert_trace_is "checker|$message_file"
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "pre-commit invokes every required checker in exact order and with exact arguments" {
  write_node_stub
  write_bash_stub
  write_precommit_stubs
  copy_hook pre-commit

  run run_hook pre-commit

  [ "$status" -eq 0 ]
  assert_trace_is $'bash|scripts/run-tests.sh|--quick\nscript|run-tests.sh|--quick\nbash|scripts/check-skill-sizes.sh\nscript|check-skill-sizes.sh\nbash|scripts/lint-recipe-routing.sh\nscript|lint-recipe-routing.sh\nbash|scripts/lint-prompt-shell-blocks.sh\nscript|lint-prompt-shell-blocks.sh'
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "pre-commit propagates a rejecting checker and stops before later checks" {
  write_node_stub
  write_bash_stub
  PRECOMMIT_FAIL_SCRIPT='check-skill-sizes.sh'
  PRECOMMIT_FAIL_STATUS=29
  write_precommit_stubs
  copy_hook pre-commit

  run run_hook pre-commit

  [ "$status" -eq 29 ]
  assert_output_contains '[stub-script] check-skill-sizes.sh rejected'
  assert_trace_is $'bash|scripts/run-tests.sh|--quick\nscript|run-tests.sh|--quick\nbash|scripts/check-skill-sizes.sh\nscript|check-skill-sizes.sh'
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "pre-commit checks every required path before executing any checker when one is absent" {
  write_node_stub
  write_bash_stub
  PRECOMMIT_MISSING='scripts/check-skill-sizes.sh'
  write_precommit_stubs
  copy_hook pre-commit

  run run_hook pre-commit

  [ "$status" -eq 1 ]
  assert_output_contains 'required script missing or not executable'
  assert_output_contains 'scripts/check-skill-sizes.sh'
  assert_trace_is ''
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "pre-commit checks executability before executing any checker" {
  write_node_stub
  write_bash_stub
  PRECOMMIT_NONEXEC='scripts/check-skill-sizes.sh'
  write_precommit_stubs
  copy_hook pre-commit

  run run_hook pre-commit

  [ "$status" -eq 1 ]
  assert_output_contains 'required script missing or not executable'
  assert_output_contains 'scripts/check-skill-sizes.sh'
  assert_trace_is ''
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}

@test "pre-commit runs and propagates a rejecting checker when Node is unavailable" {
  write_bash_stub
  PRECOMMIT_FAIL_SCRIPT='check-skill-sizes.sh'
  PRECOMMIT_FAIL_STATUS=29
  write_precommit_stubs
  copy_hook pre-commit

  run run_hook pre-commit

  [ "$status" -eq 29 ]
  assert_output_contains '[stub-script] check-skill-sizes.sh rejected'
  assert_trace_is $'bash|scripts/run-tests.sh|--quick\nscript|run-tests.sh|--quick\nbash|scripts/check-skill-sizes.sh\nscript|check-skill-sizes.sh'
  [ ! -e "$TRACE.node" ]
  assert_pseudo_repo_safe
}
