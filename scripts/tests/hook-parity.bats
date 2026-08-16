#!/usr/bin/env bats
# Tests for Claude ↔ Codex hook harness parity (RC.5, Workstream fold-in of the
# cross-model review finding).
#
# Trellis ships every hook twice — the Claude copy under core-rules/hooks/ and
# its Codex twin under core-rules/codex/hooks/ — kept in lockstep so both
# harnesses run the same governance. A hook added to only one tree silently
# starves the other harness of that automation (the RC.5 plan's first draft did
# exactly this). This test asserts strict bidirectional parity of the *.sh set
# so any future untwinned hook fails CI instead of shipping half-wired.
#
# Static test against the real repo (not a fixture): the trees themselves are
# the thing under test.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CLAUDE_HOOKS="$REPO/core-rules/hooks"
CODEX_HOOKS="$REPO/core-rules/codex/hooks"

setup() {
  PM_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-hook-parity.XXXXXX")"
  PM_PROJECT="$PM_SANDBOX/project"
  PM_RUNTIME="$PM_SANDBOX/runtime"
  mkdir -p "$PM_PROJECT" "$PM_RUNTIME"
}

teardown() {
  [ -z "${PM_SANDBOX:-}" ] || rm -rf "$PM_SANDBOX"
}

_resolve_pm_from() {
  local library="$1" project="$2" runtime="$3"
  (
    TRELLIS_ROOT="$runtime"
    . "$library"
    trellis_resolve_pm "$project"
  )
}

_assert_pm_resolution() {
  local expected="$1" project="$2" runtime="$3" claude codex
  claude="$(_resolve_pm_from "$CLAUDE_HOOKS/lib/pm.sh" "$project" "$runtime")"
  codex="$(_resolve_pm_from "$CODEX_HOOKS/lib/pm.sh" "$project" "$runtime")"
  [ "$claude" = "$expected" ]
  [ "$codex" = "$expected" ]
}

_basenames() {
  # basenames of *.sh directly under $1, sorted; empty if none.
  ls "$1"/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sort
}

@test "hook trees exist" {
  [ -d "$CLAUDE_HOOKS" ]
  [ -d "$CODEX_HOOKS" ]
}

@test "every Claude hook has a Codex twin" {
  local missing=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ -f "$CODEX_HOOKS/$h" ] || missing="$missing $h"
  done < <(_basenames "$CLAUDE_HOOKS")
  [ -z "$missing" ] || {
    echo "Claude hooks missing a Codex twin under core-rules/codex/hooks/:$missing"
    false
  }
}

@test "every Codex hook has a Claude twin" {
  local missing=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ -f "$CLAUDE_HOOKS/$h" ] || missing="$missing $h"
  done < <(_basenames "$CODEX_HOOKS")
  [ -z "$missing" ] || {
    echo "Codex hooks missing a Claude twin under core-rules/hooks/:$missing"
    false
  }
}

@test "PM resolver mirrors are byte-identical" {
  cmp -s "$CLAUDE_HOOKS/lib/pm.sh" "$CODEX_HOOKS/lib/pm.sh"
}

@test "PM resolver mirrors honor canonical legacy runtime precedence" {
  command -v jq >/dev/null 2>&1 || skip "jq is required for policy resolution"

  printf '%s\n' '{"package_manager":"bun"}' > "$PM_RUNTIME/trellis.config.json"
  printf '%s\n' '{"package_manager":"yarn"}' > "$PM_PROJECT/.trellis.config.json"
  printf '%s\n' '{"package_manager":"pnpm"}' > "$PM_PROJECT/.trellis.json"
  touch "$PM_PROJECT/package-lock.json"
  _assert_pm_resolution "pnpm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{not-json' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '[]' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{"package_manager":null}' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{"package_manager":""}' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{"package_manager":true}' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{"package_manager":"/tmp/tool"}' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{}' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "yarn" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{}' > "$PM_PROJECT/.trellis.config.json"
  _assert_pm_resolution "bun" "$PM_PROJECT" "$PM_RUNTIME"

  printf '%s\n' '{"package_manager":"auto"}' > "$PM_PROJECT/.trellis.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"
}

@test "PM resolver mirrors detect lockfiles in priority order" {
  touch \
    "$PM_PROJECT/package-lock.json" \
    "$PM_PROJECT/yarn.lock" \
    "$PM_PROJECT/bun.lock" \
    "$PM_PROJECT/pnpm-lock.yaml"
  _assert_pm_resolution "pnpm" "$PM_PROJECT" "$PM_RUNTIME"

  rm "$PM_PROJECT/pnpm-lock.yaml"
  _assert_pm_resolution "bun" "$PM_PROJECT" "$PM_RUNTIME"

  rm "$PM_PROJECT/bun.lock"
  touch "$PM_PROJECT/bun.lockb"
  _assert_pm_resolution "bun" "$PM_PROJECT" "$PM_RUNTIME"

  rm "$PM_PROJECT/bun.lockb"
  _assert_pm_resolution "yarn" "$PM_PROJECT" "$PM_RUNTIME"

  rm "$PM_PROJECT/yarn.lock"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"

  rm "$PM_PROJECT/package-lock.json"
  _assert_pm_resolution "npm" "$PM_PROJECT" "$PM_RUNTIME"
}
