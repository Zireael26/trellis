#!/usr/bin/env bats
# Tests for check-bypass.sh — sections §3a (core.hooksPath active-disable)
# and §3b (commit.gpgsign actively false).
#
# Approach: each test stands up a fresh fixture git repo (single empty commit
# on `main`) and sets only the config knob under test. With no `.husky/`,
# `.githooks/`, `package.json`, or `.claude/settings.json` in the fixture,
# every other section in check-bypass.sh is silent — so the exit code is a
# clean signal for the new checks.
#
# Exit codes follow pg_exit_code: 0=pass, 1=fail, 2=warn.
#   §3a (core.hooksPath disabled) -> fail (exit 1)
#   §3b (commit.gpgsign=false)    -> warn (exit 2)

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-bypass.sh"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Run check-bypass.sh against the fixture from inside it (so the default
# range resolves to `main..HEAD`, which is empty on a single-commit repo).
run_check() {
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT'"
}

# --- §3a: core.hooksPath active-disable ---

@test "§3a: core.hooksPath=/dev/null -> fail with finding" {
  git -C "$PROJECT_DIR" config core.hooksPath /dev/null
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"core.hooksPath"* ]]
  [[ "$output" == *"actively set to disable hooks"* ]]
  [[ "$output" == *"/dev/null"* ]]
}

@test "§3a: core.hooksPath unset -> no finding from this check (exit 0)" {
  # Sanity: ensure key is not set in the fixture.
  ! git -C "$PROJECT_DIR" config --get core.hooksPath >/dev/null 2>&1
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively set to disable hooks"* ]]
}

@test "§3a: core.hooksPath=/custom/path -> no finding (legitimate override)" {
  git -C "$PROJECT_DIR" config core.hooksPath /custom/path
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively set to disable hooks"* ]]
}

# --- §3b: commit.gpgsign actively disabled ---

@test "§3b: commit.gpgsign=false -> warn with finding (exit 2)" {
  git -C "$PROJECT_DIR" config commit.gpgsign false
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit.gpgsign"* ]]
  [[ "$output" == *"actively disabled via persistent config"* ]]
}

@test "§3b: commit.gpgsign=true -> no finding (exit 0)" {
  git -C "$PROJECT_DIR" config commit.gpgsign true
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively disabled via persistent config"* ]]
}

@test "§3b: commit.gpgsign unset -> no finding (exit 0)" {
  ! git -C "$PROJECT_DIR" config --get commit.gpgsign >/dev/null 2>&1
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively disabled via persistent config"* ]]
}
