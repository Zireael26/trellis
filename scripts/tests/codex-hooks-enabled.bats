#!/usr/bin/env bats
# Unit tests for hc_codex_hooks_enabled (spec 006 PD8 / C-2c) — the doctor check
# that catches a Codex runtime whose hooks are OFF, which would silently no-op the
# entire cross-harness enforcement mechanism (spec-gate included).
#
# Isolation: we source the check lib, stub HARNESSES + pg_has_harness, put a stub
# `codex` on PATH, and point CODEX_HOME at a throwaway config.toml. No live
# registry, no real ~/.codex.
#
# The PATH stub is load-bearing, not decorative. `hc_codex_hooks_enabled` returns
# WARN before reading any config when the codex CLI is absent, so on a machine
# without codex installed — every GitHub runner — the three config-parsing cases
# below asserted against the wrong branch and failed. Measured in ubuntu:24.04:
# 3 of 6 red without the stub, 6 of 6 green with it. The CLI-absent branch has
# its own case, which unsets the stub rather than relying on the host.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d)"
  export CODEX_HOME="$SANDBOX/codex"
  mkdir -p "$CODEX_HOME" "$SANDBOX/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/codex"
  chmod 755 "$SANDBOX/bin/codex"
  export PATH="$SANDBOX/bin:$PATH"
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
  [[ "$output" == *"n/a"* ]] || { echo "$output"; false; }
}

@test "[features] hooks = true -> OK" {
  _write_cfg '[features]' 'hooks = true'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_OK" ]
  [[ "$output" == *"hooks = true"* ]] || { echo "$output"; false; }
}

@test "config present but [features] hooks not set -> WARN" {
  _write_cfg '[features]' 'other = true' '' '[unrelated]' 'hooks = true'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"NO-OP"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"absent"* ]] || { echo "$output"; false; }
}

@test "hooks=true only in a NON-features table -> WARN (table-scoped)" {
  _write_cfg '[hooks.state]' 'hooks = true' '' '[features]' 'other = 1'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
}

# The branch the stub hides on a developer machine: codex enabled, no CLI.
@test "codex enabled but the CLI is absent -> WARN naming the missing CLI" {
  _write_cfg '[features]' 'hooks = true'
  # Narrow PATH to the sandbox plus the base system directories and drop the
  # stub, so the case tests the absent-CLI branch even where codex is installed.
  rm -f "$SANDBOX/bin/codex"
  PATH="$SANDBOX/bin:/usr/bin:/bin"
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ] || { echo "$output"; false; }
  [[ "$output" == *"codex CLI is not installed"* ]] || { echo "$output"; false; }
}
