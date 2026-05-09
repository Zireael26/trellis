#!/usr/bin/env bash
# Shared helpers for the bats hook test suite.
# Loaded via `load helpers` from individual .bats files.

# Resolve the canonical hooks directory regardless of where bats is invoked.
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOOKS_DIR="$(cd "$HOOKS_DIR/../codex/hooks" && pwd)"

# Build a temp dir that simulates a project root (with a git init so
# stop-verify's working-tree check works), and export CLAUDE_PROJECT_DIR.
setup_project_dir() {
  PROJECT_DIR="$(mktemp -d)"
  ( cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -q -m init )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

teardown_project_dir() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Build a PATH that excludes jq (and any directory containing jq), keeping
# bash + standard coreutils available. Used to verify fail-closed behavior.
make_jq_free_path() {
  local out
  out="$(mktemp -d)"
  for cmd in bash sh test [ echo printf grep sed awk cat head tail mktemp date git basename dirname readlink id stat rm mv cp mkdir tr cut sort uniq wc env; do
    local src
    src="$(command -v "$cmd" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$out/$cmd"
  done
  printf '%s' "$out"
}

# Run a hook with given stdin, returning rc + stdout + stderr in three vars.
# Usage: run_with_stderr <hook-script> <stdin>
# Sets: status (rc), output (stdout), stderr (stderr).
# Note: must temporarily disable `set -e` so bats does not abort the test when
# the hook (legitimately) exits non-zero — that exit code is the assertion.
run_with_stderr() {
  local script="$1" input="$2"
  local stderr_file
  stderr_file="$(mktemp)"
  set +e
  output="$(printf '%s' "$input" | bash "$script" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}
