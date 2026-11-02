#!/usr/bin/env bats
# U3(a): dependency availability is advisory, never executed/pass evidence.
load helpers

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export TRELLIS_ROOT="$BATS_TEST_TMPDIR/runtime"
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TRELLIS_ROOT" "$PROJECT_DIR" "$BATS_TEST_TMPDIR/bin"
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR"
  export CALL_LOG="$BATS_TEST_TMPDIR/calls" TOOL_STATUS=0
  ln -s "$(command -v jq)" "$BATS_TEST_TMPDIR/bin/jq"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" config user.email ci-bats@trellis.test
  git -C "$PROJECT_DIR" config user.name 'Trellis CI'
  git -C "$PROJECT_DIR" commit --allow-empty -qm init
  printf '%s\n' 'changed' > "$PROJECT_DIR/app.js"
  printf '%s\n' '{"scripts":{"test":"turbo run test"},"devDependencies":{"turbo":"1"}}' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/pnpm-lock.yaml"
  cat > "$BATS_TEST_TMPDIR/bin/pnpm" <<'EOF'
#!/bin/bash
printf '%s|%s|%s\n' "$PWD" "$(basename "$0")" "$*" >> "$CALL_LOG"
[ "${TOOL_STATUS:-0}" -eq 0 ] || printf '%s\n' 'turbo: command not found'
exit "${TOOL_STATUS:-0}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  cp "$BATS_TEST_TMPDIR/bin/pnpm" "$BATS_TEST_TMPDIR/bin/npx"
  : > "$CALL_LOG"
  RECEIPT='<!-- dod-receipt cmd="fixture" exit=0 diff="+1/-0 (1 files)" -->'
}

run_hook() {
  : > "$CALL_LOG"
  local input="${1:-}"
  [ -n "$input" ] || input='{}'
  run bash "$candidate" <<<"$input"
}

assert_unavailable() {
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -se 'length == 1 and (.[0].decision != "block")' >/dev/null
  [[ "$output" == *'verification unavailable: dependencies not installed'* ]]
  [[ "$output" != *'no typecheck/lint/test configured'* ]]
  if [ "$candidate" = "$HOOKS_DIR/stop-verify.sh" ]; then
    printf '%s' "$output" | jq -e '.additionalContext | contains("verification unavailable")' >/dev/null
  else
    printf '%s' "$output" | jq -e '.systemMessage | contains("verification unavailable")' >/dev/null
  fi
}

assert_block() {
  if [ "$candidate" = "$HOOKS_DIR/stop-verify.sh" ]; then
    [ "$status" -eq 2 ]
  else
    [ "$status" -eq 0 ]
  fi
  printf '%s' "$output" | jq -e --arg step "$1" '.decision == "block" and (.reason | startswith($step))' >/dev/null
}

@test "U3 missing dependencies skip runner without failure counter or executed receipt" {
  export TOOL_STATUS=127 PROCESS_GATE_NO_RECEIPTS=1
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_unavailable
    [ ! -s "$CALL_LOG" ]
    [ ! -f "$PROJECT_DIR/.claude/.fail-counter" ]
    [ ! -f "$PROJECT_DIR/.codex/.fail-counter" ]
    [ ! -d "$PROJECT_DIR/.git/trellis-verification-receipts" ]
  done
}

@test "U3 missing dependencies prevent TypeScript and ESLint version probes" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '{}\n' > "$PROJECT_DIR/tsconfig.json"
  touch "$PROJECT_DIR/eslint.config.js"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_unavailable
    [ ! -s "$CALL_LOG" ]
  done
}

@test "U3 installed dependencies preserve command-not-found failures and counters" {
  export TOOL_STATUS=127 PROCESS_GATE_NO_RECEIPTS=1
  mkdir "$PROJECT_DIR/node_modules"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'test ('
    [[ "$output" == *'turbo: command not found'* ]]
    [[ "$output" != *'verification unavailable'* ]]
    [ -s "$CALL_LOG" ]
    if [ "$candidate" = "$HOOKS_DIR/stop-verify.sh" ]; then
      [ -s "$PROJECT_DIR/.claude/.fail-counter" ]
    else
      [ -s "$PROJECT_DIR/.codex/.fail-counter" ]
    fi
  done
}

@test "U3 installed TypeScript and ESLint failures remain real failures" {
  export PROCESS_GATE_NO_RECEIPTS=1 TOOL_STATUS=2
  mkdir "$PROJECT_DIR/node_modules"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    printf '{}\n' > "$PROJECT_DIR/tsconfig.json"
    run_hook
    assert_block 'typecheck (tsc):'
    # Checks run concurrently (spec 072 U8): the test step may also have
    # started; the first planned failure, tsc, is the one that blocks.
    cut -d '|' -f2- "$CALL_LOG" | grep -qx 'npx|--no-install tsc --noEmit'
    (cd "$PROJECT_DIR" && rm tsconfig.json)
  done
  touch "$PROJECT_DIR/eslint.config.js"
  cat > "$BATS_TEST_TMPDIR/bin/npx" <<'EOF'
#!/bin/bash
printf '%s|%s|%s\n' "$PWD" npx "$*" >> "$CALL_LOG"
[ "$*" = '--no-install eslint --version' ] && exit 0
printf '%s\n' 'eslint: invalid configuration'
exit 2
EOF
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'lint (eslint):'
    [[ "$output" == *'eslint: invalid configuration'* ]]
    [[ "$output" != *'verification unavailable'* ]]
    # The test step runs concurrently with eslint (spec 072 U8).
    [ "$(cut -d '|' -f2- "$CALL_LOG" | grep '^npx|')" = $'npx|--no-install eslint --version\nnpx|--no-install eslint . --quiet' ]
  done
}

@test "U3 installed dependencies execute normally and persist executed receipts" {
  export PROCESS_GATE_NO_RECEIPTS=1
  mkdir "$PROJECT_DIR/node_modules"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -s "$CALL_LOG" ]
  done
  jq -se 'length == 2 and all(.[]; .executed == true and .exit_status == 0)' \
    "$PROJECT_DIR/.git/trellis-verification-receipts/"*.json >/dev/null
}

@test "U3 workspace uses hoisted ancestor directory without changing selected cwd" {
  export PROCESS_GATE_NO_RECEIPTS=1
  mkdir -p "$PROJECT_DIR/packages/app" "$PROJECT_DIR/node_modules"
  mv "$PROJECT_DIR/package.json" "$PROJECT_DIR/app.js" "$PROJECT_DIR/packages/app/"
  git -C "$PROJECT_DIR" add pnpm-lock.yaml
  git -C "$PROJECT_DIR" commit -qm lock
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cut -d '|' -f1 "$CALL_LOG")" = "$PROJECT_DIR/packages/app" ]
  done
}

@test "U3 Yarn PnP cjs and legacy js artifacts preserve execution" {
  export PROCESS_GATE_NO_RECEIPTS=1
  local candidate artifact
  for artifact in .pnp.cjs .pnp.js; do
    touch "$PROJECT_DIR/$artifact"
    for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
      run_hook
      [ "$status" -eq 0 ]
      [ -z "$output" ]
      [ -s "$CALL_LOG" ]
    done
    # Relative removal only, within the sandbox.
    (cd "$PROJECT_DIR" && rm "$artifact")
  done
}

@test "U3 dependency-free package scripts still execute" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -s "$CALL_LOG" ]
  done
}

@test "U3 unavailable survives receipt success follow-ups warning and unverifiable paths" {
  local candidate msg input
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    for msg in "$RECEIPT <!-- follow-ups: none -->" "$RECEIPT" ''; do
      input="$(jq -nc --arg msg "$msg" '{last_assistant_message:$msg}')"
      run_hook "$input"
      assert_unavailable
      [ ! -s "$CALL_LOG" ]
      if [ "$msg" = "$RECEIPT" ]; then [[ "$output" == *'no follow-ups marker'* ]]; fi
      if [ -z "$msg" ]; then [[ "$output" == *'receipts unverifiable'* ]]; fi
    done
  done
}

@test "U3 missing receipt and open Todos still block independently" {
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook '{"last_assistant_message":"done"}'
    assert_block 'receipts:'
    [ ! -s "$CALL_LOG" ]
    mkdir -p "$PROJECT_DIR/.claude"
    printf '%s\n' '[{"status":"pending","content":"work"}]' > "$PROJECT_DIR/.claude/todos.json"
    run_hook
    assert_block 'TodoWrite:'
    (cd "$PROJECT_DIR" && rm .claude/todos.json)
  done
}

@test "U3 malformed package stays a parse failure before probes despite absent dependencies" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '%s\n' '{"devDependencies":' > "$PROJECT_DIR/package.json"
  printf '{}\n' > "$PROJECT_DIR/tsconfig.json"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'package.json:'
    [ ! -s "$CALL_LOG" ]
  done
}

@test "U3 independent Python failure still blocks when JS dependencies are absent" {
  export PROCESS_GATE_NO_RECEIPTS=1 TOOL_STATUS=7
  printf '[mypy]\n' > "$PROJECT_DIR/mypy.ini"
  cp "$BATS_TEST_TMPDIR/bin/pnpm" "$BATS_TEST_TMPDIR/bin/mypy"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'typecheck (mypy):'
    [[ "$(cut -d '|' -f2 "$CALL_LOG")" == mypy ]]
  done
}

@test "U3 symlinked hoisted installation and hoisted Yarn PnP preserve scoped execution" {
  export PROCESS_GATE_NO_RECEIPTS=1
  mkdir -p "$PROJECT_DIR/packages/app" "$BATS_TEST_TMPDIR/installed"
  # Installed artifacts are not source edits; keep the existing subtree selector
  # scoped to the changed workspace, just as a real workspace's ignore rules do.
  printf 'node_modules\n.pnp.*\n' > "$PROJECT_DIR/.git/info/exclude"
  mv "$PROJECT_DIR/package.json" "$PROJECT_DIR/app.js" "$PROJECT_DIR/packages/app/"
  git -C "$PROJECT_DIR" add pnpm-lock.yaml
  git -C "$PROJECT_DIR" commit -qm lock
  local candidate install
  for install in node_modules .pnp.cjs; do
    if [ "$install" = node_modules ]; then
      ln -s "$BATS_TEST_TMPDIR/installed" "$PROJECT_DIR/node_modules"
    else
      touch "$PROJECT_DIR/.pnp.cjs"
    fi
    for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
      run_hook
      [ "$status" -eq 0 ]
      [ -z "$output" ]
      [ "$(cut -d '|' -f1 "$CALL_LOG")" = "$PROJECT_DIR/packages/app" ]
    done
    (cd "$PROJECT_DIR" && rm "$install")
  done
}

@test "U3 missing JS checks remain unavailable after independent Python checks pass" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '[mypy]\n' > "$PROJECT_DIR/mypy.ini"
  cp "$BATS_TEST_TMPDIR/bin/pnpm" "$BATS_TEST_TMPDIR/bin/mypy"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_unavailable
    [ "$(cut -d '|' -f2 "$CALL_LOG")" = mypy ]
  done
  jq -se 'length == 2 and all(.[]; .check_id == "typecheck.mypy" and .executed == true)' \
    "$PROJECT_DIR/.git/trellis-verification-receipts/"*.json >/dev/null
}

@test "U3 Rust and Go checks still execute without target or vendor directories" {
  export PROCESS_GATE_NO_RECEIPTS=1
  (cd "$PROJECT_DIR" && rm package.json)
  touch "$PROJECT_DIR/Cargo.toml" "$PROJECT_DIR/go.mod"
  cp "$BATS_TEST_TMPDIR/bin/pnpm" "$BATS_TEST_TMPDIR/bin/cargo"
  cp "$BATS_TEST_TMPDIR/bin/pnpm" "$BATS_TEST_TMPDIR/bin/go"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Concurrent groups interleave; cargo's own members keep their order.
    # The reuse key probes `cargo --version` / `go version` for toolchain proxies.
    [ "$(cut -d '|' -f2- "$CALL_LOG" | grep -vx -e 'cargo|--version' -e 'go|version' | sort)" = "$(printf '%s\n' 'cargo|check' 'go|vet ./...' 'cargo|clippy --quiet --message-format=short -- -D warnings' 'cargo|test --quiet' | sort)" ]
    [ "$(cut -d '|' -f2- "$CALL_LOG" | grep '^cargo|' | grep -vx 'cargo|--version' | cut -d ' ' -f1)" = $'cargo|check\ncargo|clippy\ncargo|test' ]
  done
}

@test "U3 non-directory node_modules and installations above checkout do not count" {
  export PROCESS_GATE_NO_RECEIPTS=1
  mkdir "$BATS_TEST_TMPDIR/node_modules"
  touch "$PROJECT_DIR/node_modules"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_unavailable
    [ ! -s "$CALL_LOG" ]
  done
}
