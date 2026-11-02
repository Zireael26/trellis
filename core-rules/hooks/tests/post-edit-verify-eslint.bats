#!/usr/bin/env bats
# post-edit-verify (Claude and Codex) resolves eslint once: a local
# node_modules/.bin/eslint runs directly with no npx at all, and only a failed
# run asks it for --version (a broken install is skipped, as before); without
# one, the npx probe-then-run path is exactly what it was (spec 072 T1).
#
# npx and eslint are stubs that log every call, so the assertions count node
# starts rather than trusting output alone.

load helpers

REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT/src"
  git -C "$PROJECT" -c core.hooksPath=/dev/null -c init.templateDir= init -q
  printf 'export default [];\n' >"$PROJECT/eslint.config.js"
  printf 'export const a = 1;\n' >"$PROJECT/src/a.ts"
  export CLAUDE_PROJECT_DIR="$PROJECT" CODEX_PROJECT_DIR="$PROJECT"
  # The Codex hook takes its action normalizer from the declared runtime.
  export TRELLIS_ROOT="$REPO_ROOT"

  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BIN"
  : >"$CALLS"
  # npx: `--version` exits NPX_ESLINT (0 = npx can resolve eslint); a lint run fails.
  cat >"$BIN/npx" <<EOF
#!/bin/sh
printf 'npx %s\n' "\$*" >>"$CALLS"
case "\$*" in
  *--version*) exit "\${NPX_ESLINT:-1}" ;;
esac
echo npx-eslint-error
exit 1
EOF
  chmod +x "$BIN/npx"
}

local_eslint() {  # <lint-exit> [<version-exit>]
  mkdir -p "$PROJECT/node_modules/.bin"
  cat >"$PROJECT/node_modules/.bin/eslint" <<EOF
#!/bin/sh
printf 'local %s\n' "\$*" >>"$CALLS"
[ "\$1" = --version ] && exit ${2:-0}
echo local-eslint-error
exit $1
EOF
  chmod +x "$PROJECT/node_modules/.bin/eslint"
}

run_claude() {
  run env PATH="$BIN:$PATH" bash -c 'cd "$1" && exec bash "$2"' _ "$PROJECT" "$HOOKS_DIR/post-edit-verify.sh" \
    <<<'{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
}

run_codex() {
  run env PATH="$BIN:$PATH" bash "$CODEX_HOOKS_DIR/post-edit-verify.sh" \
    <<<"$(jq -nc --arg cwd "$PROJECT" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"src/a.ts"},tool_response:{success:true}}')"
}

@test "a local eslint runs once directly and npx never starts" {
  local runner
  local_eslint 1
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *local-eslint-error* ]] || { echo "$runner: $output"; return 1; }
    [ "$(grep -c '^local --quiet .*src/a\.ts$' "$CALLS")" -eq 1 ] || { cat "$CALLS"; return 1; }
    [ "$(grep -c '^npx ' "$CALLS")" -eq 0 ] || { cat "$CALLS"; return 1; }
  done
}

@test "a configuration error from a working local eslint still blocks" {
  local runner
  local_eslint 2 0
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *local-eslint-error* ]] || { echo "$runner: $output"; return 1; }
    [ "$(sed -n 2p "$CALLS")" = "local --version" ] || { cat "$CALLS"; return 1; }
  done
}

@test "a broken local install that cannot print --version is skipped silently" {
  local runner
  local_eslint 1 1
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 0 ] || { echo "$runner: $output"; return 1; }
    [ -z "$output" ] || { echo "$runner: $output"; return 1; }
    [[ "$(sed -n 1p "$CALLS")" == "local --quiet "*src/a.ts ]] || { cat "$CALLS"; return 1; }
    [ "$(sed -n 2p "$CALLS")" = "local --version" ] || { cat "$CALLS"; return 1; }
    [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 2 ] || { cat "$CALLS"; return 1; }
  done
}

@test "a clean file under a local eslint passes silently" {
  local runner
  local_eslint 0
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 0 ] || { echo "$runner: $output"; return 1; }
    [ -z "$output" ] || { echo "$runner: $output"; return 1; }
    [ "$(grep -c '^local --quiet ' "$CALLS")" -eq 1 ] || { cat "$CALLS"; return 1; }
    [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 1 ] || { cat "$CALLS"; return 1; }
  done
}

@test "without a local eslint, npx still probes and then lints" {
  local runner
  for runner in run_claude run_codex; do
    : >"$CALLS"
    NPX_ESLINT=0 "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *npx-eslint-error* ]] || { echo "$runner: $output"; return 1; }
    [ "$(sed -n 1p "$CALLS")" = "npx --no-install eslint --version" ] || { cat "$CALLS"; return 1; }
    [[ "$(sed -n 2p "$CALLS")" == "npx --no-install eslint --quiet "*src/a.ts ]] || { cat "$CALLS"; return 1; }
    [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 2 ] || { cat "$CALLS"; return 1; }
  done
}

@test "without any eslint the edit is not linted, as before" {
  local runner
  for runner in run_claude run_codex; do
    : >"$CALLS"
    NPX_ESLINT=1 "$runner"
    [ "$status" -eq 0 ] || { echo "$runner: $output"; return 1; }
    [ -z "$output" ] || { echo "$runner: $output"; return 1; }
    [ "$(cat "$CALLS")" = "npx --no-install eslint --version" ] || { cat "$CALLS"; return 1; }
  done
}
