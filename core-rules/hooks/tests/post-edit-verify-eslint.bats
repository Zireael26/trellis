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
  PROJECT="$(cd -P "$PROJECT" && pwd -P)"
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
  local event
  event="$(jq -nc --arg target "${EDIT_TARGET:-src/a.ts}" '{tool_name:"Edit",tool_input:{file_path:$target}}')"
  run env PATH="$BIN:$PATH" bash -c 'cd "$1" && exec bash "$2"' _ "$PROJECT" "$HOOKS_DIR/post-edit-verify.sh" <<<"$event"
}

run_codex() {
  run env PATH="$BIN:$PATH" bash "$CODEX_HOOKS_DIR/post-edit-verify.sh" \
    <<<"$(jq -nc --arg cwd "$PROJECT" --arg target "${EDIT_TARGET:-src/a.ts}" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$target},tool_response:{success:true}}')"
}

@test "143-stop supported flat eslint extensions are detected without widening absent configs" {
  local runner config
  local_eslint 1
  mv "$PROJECT/eslint.config.js" "$BATS_TEST_TMPDIR/config.saved"
  for config in cjs mts cts; do
    cp "$BATS_TEST_TMPDIR/config.saved" "$PROJECT/eslint.config.$config"
    for runner in run_claude run_codex; do
      : >"$CALLS"
      "$runner"
      [ "$status" -eq 2 ] || { echo "$config $runner: $output"; return 1; }
      [[ "$output" == *local-eslint-error* ]] || false
      grep -q '^local --quiet ' "$CALLS"
    done
    mv "$PROJECT/eslint.config.$config" "$BATS_TEST_TMPDIR/config.$config"
  done
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$CALLS" ]
  done
}

@test "143-stop nested eslint config lints from its owning workspace with hoisted binary" {
  local runner
  mv "$PROJECT/eslint.config.js" "$BATS_TEST_TMPDIR/config.saved"
  mkdir -p "$PROJECT/packages/web/src"
  cp "$BATS_TEST_TMPDIR/config.saved" "$PROJECT/packages/web/eslint.config.mjs"
  printf 'export const nested = 1;\n' > "$PROJECT/packages/web/src/a.ts"
  export EDIT_TARGET='packages/web/src/a.ts'
  local_eslint 1
  cat > "$PROJECT/node_modules/.bin/eslint" <<EOF
#!/bin/sh
printf 'cwd=%s\n' "\$PWD" >>"$CALLS"
[ "\$1" = --version ] && exit 0
printf 'workspace lint failed\n'
exit 1
EOF
  chmod +x "$PROJECT/node_modules/.bin/eslint"
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *'workspace lint failed'* ]] || false
    grep -Fx "cwd=$PROJECT/packages/web" "$CALLS"
  done
}

@test "143-stop local eslint does not depend on npx being on PATH" {
  local runner
  mv "$BIN/npx" "$BATS_TEST_TMPDIR/npx.saved"
  ln -s "$(command -v jq)" "$BIN/jq"
  export PATH="$BIN:/usr/bin:/bin"
  ! command -v npx >/dev/null 2>&1
  local_eslint 1
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *local-eslint-error* ]] || false
    grep -q '^local --quiet ' "$CALLS"
  done
  local_eslint 0
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q '^local --quiet ' "$CALLS"
  done
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
    # R1 PATH ruling A (a039a8c43): a missing project tool is one labelled
    # advisory line, never a lint run or a block.
    [ "${#lines[@]}" -eq 1 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == 'post-edit-verify: eslint not found (no local install and no npx eslint on PATH); JS/TS lint skipped for '*src/a.ts ]] ||
      { echo "$runner: $output"; return 1; }
    [ "$(cat "$CALLS")" = "npx --no-install eslint --version" ] || { cat "$CALLS"; return 1; }
  done
}

@test "P45 oxlint config takes precedence over eslint and biome in post-edit-verify" {
  local runner
  printf '{}\n' >"$PROJECT/.oxlintrc.json"
  printf '{}\n' >"$PROJECT/biome.json"
  local_eslint 1
  mkdir -p "$PROJECT/node_modules/.bin"
  cat >"$PROJECT/node_modules/.bin/oxlint" <<EOF
#!/bin/sh
printf 'oxlint %s\n' "\$*" >>"$CALLS"
echo oxlint-error
exit 1
EOF
  chmod +x "$PROJECT/node_modules/.bin/oxlint"
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *oxlint-error* ]] || { echo "$runner: $output"; return 1; }
    grep -q '^oxlint --quiet ' "$CALLS"
    ! grep -q '^local ' "$CALLS"
  done
}

@test "P45 biome config takes precedence over eslint when oxlint is absent" {
  local runner
  printf '{}\n' >"$PROJECT/biome.json"
  local_eslint 1
  mkdir -p "$PROJECT/node_modules/.bin"
  cat >"$PROJECT/node_modules/.bin/biome" <<EOF
#!/bin/sh
printf 'biome %s\n' "\$*" >>"$CALLS"
echo biome-error
exit 1
EOF
  chmod +x "$PROJECT/node_modules/.bin/biome"
  for runner in run_claude run_codex; do
    : >"$CALLS"
    "$runner"
    [ "$status" -eq 2 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *biome-error* ]] || { echo "$runner: $output"; return 1; }
    grep -q '^biome check ' "$CALLS"
    ! grep -q '^local ' "$CALLS"
  done
}
