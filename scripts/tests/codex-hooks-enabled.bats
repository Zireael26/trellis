#!/usr/bin/env bats
# Narrow config-intent observation, not evidence of native runtime activation.
# Private fixtures and a CLI stub: never execute Codex or read live config.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/codex-config.XXXXXX")"
  export CODEX_HOME="$SANDBOX/codex"
  mkdir -p "$CODEX_HOME" "$SANDBOX/bin"
  printf '#!/usr/bin/env bash\nexit 99\n' > "$SANDBOX/bin/codex"
  chmod 755 "$SANDBOX/bin/codex"
  export PATH="$SANDBOX/bin:$PATH"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
  HARNESSES=(claude codex)
  pg_has_harness() { local t="$1" h; for h in "${HARNESSES[@]}"; do [ "$h" = "$t" ] && return 0; done; return 1; }
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
_write_cfg() { printf '%s\n' "$@" > "$CODEX_HOME/config.toml"; }
_truthful() {
  [[ "$output" != *"hooks active"* && "$output" != *"NO-OP"* && "$output" != *"will NOT run"* && "$output" != *"fix: set"* ]]
}
_unknown() {
  [ "$status" -eq "$HC_INFO" ]
  [[ "$output" == *"unknown"* ]] || return 1
  [[ "$output" == *"native activation unverified"* ]] || return 1
  _truthful
}

@test "codex not selected -> OK n/a" {
  HARNESSES=(claude)
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_OK" ]
  [[ "$output" == *"n/a"* ]]
}

@test "explicit true is configured intent only -> INFO" {
  _write_cfg '[features]' 'hooks = true'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_INFO" ]
  [[ "$output" == *"configured intent: [features] hooks = true"* ]]
  [[ "$output" == *"native activation unverified"* ]]
  _truthful
}

@test "unset and non-features declarations are unknown -> INFO" {
  _write_cfg '[features]' 'other = true' '[unrelated]' 'hooks = true'
  run hc_codex_hooks_enabled
  _unknown
  _write_cfg '[hooks.state]' 'hooks = true'
  run hc_codex_hooks_enabled
  _unknown
}

@test "explicit false is configured intent only -> WARN" {
  _write_cfg '[features]' 'hooks = false'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"configured intent: [features] hooks = false"* ]]
  [[ "$output" == *"native activation unverified"* ]]
  _truthful
}

@test "missing config is unknown, not certain failure -> INFO" {
  run hc_codex_hooks_enabled
  _unknown
  [[ "$output" == *"absent"* ]]
}

@test "malformed scalars and conflicting or repeated declarations are unknown" {
  local scalar
  for scalar in trueish 'true junk' 'false junk' '"true"' TRUE ''; do
    _write_cfg '[features]' "hooks = $scalar"
    run hc_codex_hooks_enabled
    _unknown
  done
  _write_cfg '[features]' 'hooks = true' 'hooks = false'
  run hc_codex_hooks_enabled
  _unknown
  _write_cfg '[features]' 'hooks = true' '[features]' 'hooks = true'
  run hc_codex_hooks_enabled
  _unknown
  _write_cfg '[features.extra]' 'hooks = true'
  run hc_codex_hooks_enabled
  _unknown
}

@test "ordinary inline comments are accepted on exact features table and scalar" {
  _write_cfg ' [features] # intent' ' hooks = true # enabled intent'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_INFO" ]
  [[ "$output" == *"configured intent: [features] hooks = true"* ]]
  _truthful
  _write_cfg '[features]' 'hooks = false # disabled intent'
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"configured intent: [features] hooks = false"* ]]
  _truthful
}

@test "config read failure warns with unknown observation" {
  _write_cfg '[features]' 'hooks = true'
  chmod 000 "$CODEX_HOME/config.toml"
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"unknown"* ]]
  [[ "$output" == *"read"* ]]
  _truthful
}

@test "missing CLI warns only that CLI cannot be invoked" {
  _write_cfg '[features]' 'hooks = true'
  rm -f "$SANDBOX/bin/codex"
  PATH="$SANDBOX/bin:/usr/bin:/bin"
  run hc_codex_hooks_enabled
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"cannot invoke"* ]]
  [[ "$output" == *"native activation unverified"* ]]
  _truthful
}
