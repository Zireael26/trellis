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

# The local runner stubs record their invocation and fail only the selected
# suite; cargo check/clippy and go vet remain successful.
make_mixed_test_runners() {
  mkdir -p "$PROJECT_DIR/.venv/bin"
  cat > "$PROJECT_DIR/.venv/bin/pytest" <<'EOF'
#!/bin/bash
printf 'pytest|%s\n' "$*" >> "$CALL_LOG"
[ "${FAIL_TARGET:-}" != pytest ] || { echo 'pytest failed'; exit 17; }
EOF
  cat > "$BATS_TEST_TMPDIR/bin/cargo" <<'EOF'
#!/bin/bash
printf 'cargo|%s\n' "$*" >> "$CALL_LOG"
[ "${FAIL_TARGET:-}" != cargo ] || [ "$1" != test ] || { echo 'cargo test failed'; exit 18; }
EOF
  cat > "$BATS_TEST_TMPDIR/bin/go" <<'EOF'
#!/bin/bash
printf 'go|%s\n' "$*" >> "$CALL_LOG"
[ "${FAIL_TARGET:-}" != go ] || [ "$1" != test ] || { echo 'go test failed'; exit 19; }
EOF
  chmod +x "$PROJECT_DIR/.venv/bin/pytest" "$BATS_TEST_TMPDIR/bin/cargo" "$BATS_TEST_TMPDIR/bin/go"
}

_r2_l4_serial_tests() {
  local harness="$1" candidate runner name
  if [ "$harness" = claude ]; then candidate="$HOOKS_DIR/stop-verify.sh"; else candidate="$CODEX_HOOKS_DIR/stop-verify.sh"; fi
  export PROCESS_GATE_NO_RECEIPTS=1 LOCK_DIR="$BATS_TEST_TMPDIR/test-lock" OVERLAP="$BATS_TEST_TMPDIR/overlap"
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/pyproject.toml" "$PROJECT_DIR/Cargo.toml" "$PROJECT_DIR/go.mod"
  mkdir -p "$PROJECT_DIR/node_modules" "$PROJECT_DIR/.venv/bin"
  cat > "$BATS_TEST_TMPDIR/runner" <<'EOF'
#!/bin/bash
name="$(basename "$0")"
[ "$name" != go ] || [ "$1" != vet ] || { printf 'go|vet\n' >> "$CALL_LOG"; exit 0; }
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf '%s %s\n' "$name" "$*" >> "$OVERLAP"
  exit 0
fi
printf '%s|%s\n' "$name" "$*" >> "$CALL_LOG"
sleep 0.3
rmdir "$LOCK_DIR"
EOF
  for name in pnpm cargo go; do cp "$BATS_TEST_TMPDIR/runner" "$BATS_TEST_TMPDIR/bin/$name"; chmod +x "$BATS_TEST_TMPDIR/bin/$name"; done
  cp "$BATS_TEST_TMPDIR/runner" "$PROJECT_DIR/.venv/bin/pytest"
  chmod +x "$PROJECT_DIR/.venv/bin/pytest"
  run_hook
  [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
  [ ! -s "$OVERLAP" ] || { printf 'overlapping checks: '; cat "$OVERLAP"; false; }
  grep -q '^pnpm|run test$' "$CALL_LOG"
  grep -q '^pytest|' "$CALL_LOG"
  grep -q '^cargo|check$' "$CALL_LOG"
  grep -q '^cargo|clippy' "$CALL_LOG"
  grep -q '^cargo|test ' "$CALL_LOG"
  grep -q '^go|test ' "$CALL_LOG"
  grep -q '^go|vet$' "$CALL_LOG"
}

@test "R2 L4: Claude mixed test suites and cargo checks do not overlap" {
  _r2_l4_serial_tests claude
}

@test "R2 L4: Codex mixed test suites and cargo checks do not overlap" {
  _r2_l4_serial_tests codex
}

@test "143-stop package manifest without a test cannot shadow pytest" {
  export PROCESS_GATE_NO_RECEIPTS=1 FAIL_TARGET=pytest
  printf '{}\n' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/pyproject.toml"
  make_mixed_test_runners
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'test ('
    [[ "$output" == *'pytest failed'* ]]
    grep -q '^pytest|' "$CALL_LOG"
  done
}

@test "143-stop package and python tests both run and a failing pytest blocks" {
  export PROCESS_GATE_NO_RECEIPTS=1 FAIL_TARGET=pytest
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/pyproject.toml"
  make_mixed_test_runners
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'test ('
    [[ "$output" == *'pytest failed'* ]]
    grep -q '^pytest|' "$CALL_LOG"
    grep -q '|pnpm|run test$' "$CALL_LOG"
    FAIL_TARGET='' run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision":"block"'* ]]
    grep -q '^pytest|' "$CALL_LOG"
    grep -q '|pnpm|run test$' "$CALL_LOG"
  done
}

@test "143-stop mixed package cargo and go tests are independently enforced" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/Cargo.toml" "$PROJECT_DIR/go.mod"
  make_mixed_test_runners
  local candidate target
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    for target in cargo go; do
      export FAIL_TARGET="$target"
      run_hook
      assert_block 'test ('
      [[ "$output" == *"$target test failed"* ]]
      grep -q "^$target|test" "$CALL_LOG"
    done
    export FAIL_TARGET=''
    run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision":"block"'* ]]
    grep -q '^cargo|test' "$CALL_LOG"
    grep -q '^go|test' "$CALL_LOG"
    grep -q '|pnpm|run test$' "$CALL_LOG"
  done
}

@test "143-stop missing configured package manager blocks unless fast override replaces tests" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  mv "$BATS_TEST_TMPDIR/bin/pnpm" "$BATS_TEST_TMPDIR/pnpm.saved"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    assert_block 'test:'
    [[ "$output" == *'pnpm'* ]] && [[ "$output" == *'not available'* ]]
  done
  # An absent test script is not a reason to require a package manager.
  printf '{}\n' > "$PROJECT_DIR/package.json"
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
  done
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  printf '#!/bin/bash\nprintf "fast|run\\n" >> "$CALL_LOG"\n' > "$BATS_TEST_TMPDIR/bin/fast_suite"
  chmod +x "$BATS_TEST_TMPDIR/bin/fast_suite"
  jq -nc --arg root "$PROJECT_DIR" '{projects:{($root):{stop_checks:{fast:"fast_suite"}}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
    grep -q '^fast|run$' "$CALL_LOG"
  done
  # Restoring the selected package manager restores the ordinary test step.
  mv "$BATS_TEST_TMPDIR/pnpm.saved" "$BATS_TEST_TMPDIR/bin/pnpm"
  mv "$TRELLIS_HOME/config.json" "$BATS_TEST_TMPDIR/config.saved"
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]; [ -s "$CALL_LOG" ]
  done
}

@test "143-stop host fast override replaces all mixed-language test suites" {
  export PROCESS_GATE_NO_RECEIPTS=1 FAIL_TARGET=''
  printf '%s\n' '{"scripts":{"test":"echo ok"}}' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/pyproject.toml" "$PROJECT_DIR/Cargo.toml" "$PROJECT_DIR/go.mod"
  make_mixed_test_runners
  printf '#!/bin/bash\nprintf "fast|run\\n" >> "$CALL_LOG"\n' > "$BATS_TEST_TMPDIR/bin/fast_suite"
  chmod +x "$BATS_TEST_TMPDIR/bin/fast_suite"
  jq -nc --arg root "$PROJECT_DIR" '{projects:{($root):{stop_checks:{fast:"fast_suite"}}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'stop_checks.fast'* ]]
    grep -q '^fast|run$' "$CALL_LOG"
    ! grep -qE '^(pytest\||cargo\|test|go\|test)' "$CALL_LOG"
    ! grep -q '|pnpm|run test$' "$CALL_LOG"
    grep -q '^cargo|check' "$CALL_LOG"
    grep -q '^go|vet' "$CALL_LOG"
  done
}

@test "143-stop Stop lint recognizes supported flat config extensions" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '{}\n' > "$PROJECT_DIR/package.json"
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  cat > "$PROJECT_DIR/node_modules/.bin/eslint" <<'EOF'
#!/bin/bash
printf 'eslint|%s\n' "$*" >> "$CALL_LOG"
[ "$1" != --version ] || { echo v9.0.0; exit 0; }
echo 'flat lint failed'
exit 5
EOF
  chmod +x "$PROJECT_DIR/node_modules/.bin/eslint"
  local candidate ext
  for ext in cjs mts cts; do
    touch "$PROJECT_DIR/eslint.config.$ext"
    for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
      run_hook
      assert_block 'lint (eslint):'
      [[ "$output" == *'flat lint failed'* ]]
    done
    mv "$PROJECT_DIR/eslint.config.$ext" "$BATS_TEST_TMPDIR/config.$ext"
  done
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    run_hook
    [ "$status" -eq 0 ]
    ! grep -q '^eslint|' "$CALL_LOG"
  done
}

@test "143-stop broken local eslint version probe cannot silently drop lint" {
  export PROCESS_GATE_NO_RECEIPTS=1
  printf '{}\n' > "$PROJECT_DIR/package.json"
  touch "$PROJECT_DIR/eslint.config.js"
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  cat > "$PROJECT_DIR/node_modules/.bin/eslint" <<'EOF'
#!/bin/bash
printf 'eslint|%s\n' "$*" >> "$CALL_LOG"
[ "$1" != --version ] || { [ "${BROKEN_VERSION:-1}" = 0 ] && { echo v9.0.0; exit 0; }; exit 4; }
[ "${BROKEN_LINT:-1}" = 0 ] || { echo 'lint failed'; exit 5; }
EOF
  chmod +x "$PROJECT_DIR/node_modules/.bin/eslint"
  local candidate
  for candidate in "$HOOKS_DIR/stop-verify.sh" "$CODEX_HOOKS_DIR/stop-verify.sh"; do
    export BROKEN_VERSION=1 BROKEN_LINT=1
    run_hook
    assert_block 'lint (eslint):'
    [[ "$output" == *'lint failed'* ]]
    grep -q '^eslint|\. --quiet$' "$CALL_LOG"
    export BROKEN_VERSION=1 BROKEN_LINT=0
    run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision":"block"'* ]]
    [[ "$output" == *'eslint version probe failed'* ]]
    grep -q '^eslint|\. --quiet$' "$CALL_LOG"
    run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'eslint version probe failed'* ]]
    [[ "$output" != *'checks reused'* ]]
    grep -q '^eslint|\. --quiet$' "$CALL_LOG"
    export BROKEN_VERSION=0 BROKEN_LINT=0
    run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *'"decision":"block"'* ]]
    [[ "$output" != *'eslint version probe failed'* ]]
  done
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
    [ "$(cut -d '|' -f2- "$CALL_LOG" | grep -vx -e 'cargo|--version' -e 'go|version' | sort)" = "$(printf '%s\n' 'cargo|check' 'go|vet ./...' 'cargo|clippy --quiet --message-format=short -- -D warnings' 'cargo|test --quiet' 'go|test ./...' | sort)" ]
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
