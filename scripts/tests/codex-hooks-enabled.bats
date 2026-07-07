#!/usr/bin/env bats
# Unit tests for hc_codex_hooks_enabled (spec 006 PD8 / C-2c) — the doctor check
# that catches a Codex runtime whose hooks are OFF, which would silently no-op the
# entire cross-harness enforcement mechanism (spec-gate included).
#
# Isolation: we source the check lib, stub HARNESSES + pg_has_harness, and point
# CODEX_HOME at a throwaway config.toml. No live registry, no real ~/.codex.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d)"
  export CODEX_HOME="$SANDBOX/codex"
  mkdir -p "$CODEX_HOME"
  # HC_ constants live in health-checks.sh; source it for the function + codes.
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
  # Stub pg_has_harness (normally from config-load.sh) via a settable HARNESSES.
  HARNESSES=(claude codex)
  pg_has_harness() { local t="$1" h; for h in "${HARNESSES[@]}"; do [ "$h" = "$t" ] && return 0; done; return 1; }
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

_write_cfg() { printf '%s\n' "$@" > "$CODEX_HOME/config.toml"; }

@test "codex not an enabled harness -> OK (n/a)" {
  HARNESSES=(claude)
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_OK" ]
  [[ "$output" == *"n/a"* ]]
}

@test "[features] hooks = true -> OK" {
  _write_cfg '[features]' 'hooks = true'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_OK" ]
  [[ "$output" == *"hooks = true"* ]]
}

@test "config present but [features] hooks not set -> WARN" {
  _write_cfg '[features]' 'other = true' '' '[unrelated]' 'hooks = true'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"NO-OP"* ]]
}

@test "hooks = false under [features] -> WARN" {
  _write_cfg '[features]' 'hooks = false'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
}

@test "config.toml absent -> WARN" {
  # no config written
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"absent"* ]]
}

@test "hooks=true only in a NON-features table -> WARN (table-scoped)" {
  _write_cfg '[hooks.state]' 'hooks = true' '' '[features]' 'other = 1'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
}
