#!/usr/bin/env bats
# T28: real, active failing verifier toolchains, not fake runners. Each case
# drives both canonical shell adapters and requires the tool's own diagnostic.
# Missing host tools are reported as skips; no package or tool is installed.
load helpers

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  export GOCACHE="$BATS_TEST_TMPDIR/go-cache" GOPATH="$BATS_TEST_TMPDIR/go-path" GOENV=off
  export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOWORK=off
  export CARGO_NET_OFFLINE=true RUSTUP_AUTO_INSTALL=0 RUSTUP_TOOLCHAIN=1.97.1 CARGO_BUILD_JOBS=2
  export CARGO_TARGET_DIR="$BATS_TEST_TMPDIR/cargo-target" COREPACK_ENABLE_NETWORK=0
  mkdir -p "$HOME" "$TRELLIS_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
  setup_project_dir "$BATS_TEST_TMPDIR"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR" PROCESS_GATE_NO_RECEIPTS=1
}

teardown() { teardown_project_dir; }

assert_active_block() {
  local step="$1" diagnostic="$2" harness hook reason hooks settings sid state key baseline
  for harness in claude codex; do
    hooks="$HOOKS_DIR"; settings="$PROJECT_DIR/.claude/settings.local.json"
    if [ "$harness" = codex ]; then hooks="$CODEX_HOOKS_DIR"; settings="$PROJECT_DIR/.codex/hooks.json"; fi
    mkdir -p "${settings%/*}"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$settings"
    printf '/%s\n' "${settings#"$PROJECT_DIR"/}" >> "$PROJECT_DIR/.git/info/exclude"
    sid="t28-active-$harness"
    run bash "$hooks/turn-baseline.sh" <<<"{\"session_id\":\"$sid\"}"
    [ "$status" -eq 0 ] || { echo "$harness: prompt failed: $output"; return 1; }
    state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$hooks/lib/deps.sh" "$PROJECT_DIR")"
    key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$hooks/lib/deps.sh" "$sid")"
    baseline="$state/$harness.$key"
    [ -f "$baseline" ] || { echo "$harness: real prompt did not publish baseline"; return 1; }
    # Change a non-doc input after the prompt, so Stop must actually execute
    # the failing tool rather than taking its unchanged-turn shortcut.
    printf '%s\n' "$harness" > "$PROJECT_DIR/.t28-active-trigger"
    hook="$hooks/stop-verify.sh"
    run bash "$hook" <<<"{\"session_id\":\"$sid\"}"
    if [ "$harness" = claude ]; then
      [ "$status" -eq 2 ] || { echo "$harness: expected block exit, got $status: $output"; return 1; }
    else
      [ "$status" -eq 0 ] || { echo "$harness: expected Codex transport exit 0, got $status: $output"; return 1; }
    fi
    reason="$(printf '%s' "$output" | jq -er 'select(.decision == "block") | .reason')" || {
      echo "$harness: missing block: $output"; return 1;
    }
    case "$reason" in "$step"*) ;; *) echo "$harness: wrong check: $reason"; return 1 ;; esac
    [[ "$reason" == *"$diagnostic"* ]] || { echo "$harness: missing real tool diagnostic $diagnostic: $reason"; return 1; }
    [ ! -e "$baseline" ] || { echo "$harness: failing active check published a carry"; return 1; }
    [ -z "$(find "$TRELLIS_HOME/state/stop-receipts" -type f -name "*.$harness" 2>/dev/null)" ] || {
      echo "$harness: failing active check published a reusable pass receipt"; return 1;
    }
  done
}

@test "T28 active pnpm and Node failing test blocks both adapters" {
  command -v pnpm >/dev/null 2>&1 || skip 'pnpm is not installed on this host'
  command -v node >/dev/null 2>&1 || skip 'Node is not installed on this host'
  pnpm --version >/dev/null 2>&1 || skip 'installed pnpm cannot run offline in the sandbox'
  printf '%s\n' '{"package_manager":"pnpm"}' > "$PROJECT_DIR/.trellis.json"
  printf '%s\n' '{"name":"t28-active","private":true,"scripts":{"test":"node test.mjs"}}' > "$PROJECT_DIR/package.json"
  printf '%s\n' 'console.error("T28_NODE_TEST_FAILED"); process.exit(17);' > "$PROJECT_DIR/test.mjs"
  assert_active_block 'test (pnpm run test):' 'T28_NODE_TEST_FAILED'
}

@test "T28 active TypeScript typecheck blocks both adapters" {
  local tool="${T28_TSC:-}"
  [ -n "$tool" ] || tool="$(command -v tsc 2>/dev/null || true)"
  [ -n "$tool" ] || skip 'TypeScript tsc is not installed on this host'
  [ -x "$tool" ] || { echo "TypeScript fixture is not executable: $tool"; return 1; }
  command -v npx >/dev/null 2>&1 || skip 'npx is required by the verifier TypeScript detector'
  command -v node >/dev/null 2>&1 || skip 'Node is not installed on this host'
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  ln -s "$tool" "$PROJECT_DIR/node_modules/.bin/tsc"
  printf '%s\n' '{"compilerOptions":{"noEmit":true},"files":["broken.ts"]}' > "$PROJECT_DIR/tsconfig.json"
  printf '%s\n' 'const broken: number = "not a number";' > "$PROJECT_DIR/broken.ts"
  assert_active_block 'typecheck (tsc):' 'TS2322'
}

@test "T28 active ESLint failure blocks both adapters" {
  local version major tool="${T28_ESLINT:-}"
  [ -n "$tool" ] || tool="$(command -v eslint 2>/dev/null || true)"
  [ -n "$tool" ] || skip 'ESLint is not installed on this host'
  [ -x "$tool" ] || { echo "ESLint fixture is not executable: $tool"; return 1; }
  command -v npx >/dev/null 2>&1 || skip 'npx is required by the verifier ESLint detector'
  command -v node >/dev/null 2>&1 || skip 'Node is not installed on this host'
  version="$("$tool" --version)" || { echo 'installed ESLint version probe failed'; return 1; }
  major="${version#v}"; major="${major%%.*}"
  case "$major" in ''|*[!0-9]*) echo "unrecognized ESLint version: $version"; return 1 ;; esac
  mkdir -p "$PROJECT_DIR/node_modules/.bin"
  ln -s "$tool" "$PROJECT_DIR/node_modules/.bin/eslint"
  if [ "$major" -ge 9 ]; then
    printf '%s\n' "export default [{rules: {'no-undef': 'error'}}];" > "$PROJECT_DIR/eslint.config.mjs"
  else
    printf '%s\n' '{"root":true,"rules":{"no-undef":"error"}}' > "$PROJECT_DIR/.eslintrc.json"
  fi
  printf '%s\n' 't28_missing_identifier();' > "$PROJECT_DIR/broken.js"
  assert_active_block 'lint (eslint):' 't28_missing_identifier'
}

@test "T28 active mypy typecheck blocks both adapters" {
  command -v mypy >/dev/null 2>&1 || skip 'mypy is not installed on this host'
  printf '[mypy]\ncache_dir = %s\n' "$BATS_TEST_TMPDIR/mypy-cache" > "$PROJECT_DIR/mypy.ini"
  printf '%s\n' 'value: int = "not an integer"' > "$PROJECT_DIR/broken.py"
  assert_active_block 'typecheck (mypy):' 'broken.py'
}

@test "T28 active ruff lint blocks both adapters" {
  command -v ruff >/dev/null 2>&1 || skip 'ruff is not installed on this host'
  printf '%s\n' '[lint]' 'select = ["F401"]' > "$PROJECT_DIR/ruff.toml"
  printf '%s\n' 'import os' > "$PROJECT_DIR/broken.py"
  assert_active_block 'lint (ruff):' 'F401'
}

@test "T28 active pytest failure blocks both adapters" {
  if [ "${T28_USE_UV_PYTEST:-0}" = 1 ]; then
    # Keep uv's temporary environment alive for the complete pytest run.
    # This thin test launcher execs the real cached pytest, with no network;
    # capturing its ephemeral entrypoint after uv exits would leave a dead path.
    command -v uv >/dev/null 2>&1 || { echo 'uv is required for the requested pytest fixture'; return 1; }
    mkdir -p "$PROJECT_DIR/.venv/bin"
    printf '%s\n' '#!/bin/sh' 'exec uv run --offline --no-project --with pytest pytest "$@"' > "$PROJECT_DIR/.venv/bin/pytest"
    chmod 700 "$PROJECT_DIR/.venv/bin/pytest"
  else
    command -v pytest >/dev/null 2>&1 || skip 'pytest is not installed on this host'
  fi
  printf '%s\n' '[pytest]' 'cache_dir = /dev/null' > "$PROJECT_DIR/pytest.ini"
  printf '%s\n' 'def test_t28_failure():' '    assert False, "T28_PYTEST_FAILED"' > "$PROJECT_DIR/test_failure.py"
  assert_active_block 'test (' 'T28_PYTEST_FAILED'
}

@test "T28 active pinned Rust cargo check failure blocks both adapters" {
  command -v cargo >/dev/null 2>&1 || skip 'cargo is not installed on this host'
  command -v rustup >/dev/null 2>&1 || skip 'rustup is unavailable for the pinned Rust toolchain'
  rustup run 1.97.1 rustc --version >/dev/null 2>&1 || skip 'pinned Rust 1.97.1 is not installed on this host'
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '[package]' 'name = "t28_active"' 'version = "0.1.0"' 'edition = "2021"' > "$PROJECT_DIR/Cargo.toml"
  printf '%s\n' 'pub fn broken() -> usize { "not a number" }' > "$PROJECT_DIR/src/lib.rs"
  assert_active_block 'typecheck (cargo check):' 'E0308'
}

@test "T28 active pinned Rust cargo test failure blocks both adapters" {
  command -v cargo >/dev/null 2>&1 || skip 'cargo is not installed on this host'
  command -v rustup >/dev/null 2>&1 || skip 'rustup is unavailable for the pinned Rust toolchain'
  rustup run 1.97.1 rustc --version >/dev/null 2>&1 || skip 'pinned Rust 1.97.1 is not installed on this host'
  cargo +1.97.1 clippy --version >/dev/null 2>&1 || skip 'pinned Rust clippy is not installed on this host'
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '[package]' 'name = "t28_active"' 'version = "0.1.0"' 'edition = "2021"' > "$PROJECT_DIR/Cargo.toml"
  printf '%s\n' '#[test]' 'fn failing_test() { panic!("T28_RUST_TEST_FAILED"); }' > "$PROJECT_DIR/src/lib.rs"
  assert_active_block 'test (cargo test --quiet):' 'T28_RUST_TEST_FAILED'
}

@test "T28 active Go test failure blocks both adapters" {
  command -v go >/dev/null 2>&1 || skip 'Go is not installed on this host'
  printf '%s\n' 'module example.invalid/t28' '' 'go 1.20' > "$PROJECT_DIR/go.mod"
  printf '%s\n' 'package t28' 'import "testing"' 'func TestT28Failure(t *testing.T) { t.Fatal("T28_GO_TEST_FAILED") }' > "$PROJECT_DIR/active_test.go"
  assert_active_block 'test (go test ./...):' 'T28_GO_TEST_FAILED'
}

@test "T28 active golangci-lint failure blocks both adapters" {
  command -v go >/dev/null 2>&1 || skip 'Go is not installed on this host'
  command -v golangci-lint >/dev/null 2>&1 || skip 'golangci-lint is not installed on this host'
  printf '%s\n' 'module example.invalid/t28' '' 'go 1.20' > "$PROJECT_DIR/go.mod"
  printf '%s\n' 'package t28' 'func t28NeverUsed() {}' > "$PROJECT_DIR/active.go"
  assert_active_block 'lint (golangci-lint):' 't28NeverUsed'
}
