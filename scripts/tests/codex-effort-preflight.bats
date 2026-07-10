#!/usr/bin/env bats
# Tests for scripts/codex-effort-preflight.sh — the spec 011 D6 surface
# preflight (SC6).
#
# THE FAIL-CLOSED GUARANTEE under test: every bad state (wrong/absent pin,
# absent/unrecognizable companion plugin, old/absent CLI) degrades to a
# fail-closed JSON report (pin_ok=false / supported_efforts=[] / cli_ok=false)
# with exit 0 — the script only reports; callers decide. No probe result is
# ever guessed: the effort enum comes from the installed companion's validator
# SOURCE (pattern-driven), never a hardcoded tier list (verified-surface rule,
# spec 011 §4).
#
# Isolation: all three probes are pointed at fixtures via the env overrides
# (CODEX_CONFIG / CODEX_PLUGIN / CODEX_BIN); stub `codex` binaries are built
# per-test under mktemp. The canonical script is exercised in place.
#
# bash 3.2 / bats 1.x compatible.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PREFLIGHT="$REPO/scripts/codex-effort-preflight.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/codex-effort-preflight"

setup() {
  SANDBOX="$(mktemp -d)"
  BIN_DIR="$SANDBOX/bin"
  mkdir -p "$BIN_DIR"
}

teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# --- helpers ----------------------------------------------------------------

# _stub_codex <version-line> — write an executable fake `codex` echoing the
# given --version output; returns its path on stdout.
_stub_codex() {
  cat > "$BIN_DIR/codex" <<EOF
#!/bin/sh
echo "$1"
EOF
  chmod +x "$BIN_DIR/codex"
  echo "$BIN_DIR/codex"
}

# _run_preflight <config> <plugin> <bin> [expected-pin] — run the script with
# all three probes pointed at the given fixtures.
_run_preflight() {
  local cfg="$1" plugin="$2" bin="$3"
  shift 3
  CODEX_CONFIG="$cfg" CODEX_PLUGIN="$plugin" CODEX_BIN="$bin" run "$PREFLIGHT" "$@"
}

# _assert_json — the captured $output must parse as JSON (node, already a
# repo dependency via the wf recipes).
_assert_json() {
  printf '%s' "$output" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))'
}

# --- happy path ---------------------------------------------------------------

@test "happy path: right pin + companion enum + new CLI -> all green, valid JSON" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"model_pin": "gpt-5.6-sol"'* ]]
  [[ "$output" == *'"pin_ok": true'* ]]
  [[ "$output" == *'"supported_efforts": ["none", "minimal", "low", "medium", "high", "xhigh"]'* ]]
  [[ "$output" == *'"cli_version": "0.144.0"'* ]]
  [[ "$output" == *'"cli_ok": true'* ]]
}

@test "enum is read from the installed surface: extended validator -> max/ultra reported" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin-extended" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"supported_efforts": ["medium", "high", "xhigh", "max", "ultra"]'* ]]
}

@test "expected pin is parameterized via \$1, never baked" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-wrong.toml" "$FIXTURES/plugin" "$bin" "gpt-5.5-codex"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"model_pin": "gpt-5.5-codex"'* ]]
  [[ "$output" == *'"pin_ok": true'* ]]
}

# --- fail-closed: model pin ---------------------------------------------------

@test "wrong pin -> pin_ok false, actual pin reported, exit 0" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-wrong.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"model_pin": "gpt-5.5-codex"'* ]]
  [[ "$output" == *'"pin_ok": false'* ]]
}

@test "absent config file -> model_pin absent, pin_ok false, exit 0" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$SANDBOX/nonexistent/config.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"model_pin": "absent"'* ]]
  [[ "$output" == *'"pin_ok": false'* ]]
}

@test "config without a model key -> model_pin absent, pin_ok false" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-no-pin.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"model_pin": "absent"'* ]]
  [[ "$output" == *'"pin_ok": false'* ]]
}

# --- fail-closed: companion enum ----------------------------------------------

@test "absent plugin -> supported_efforts [] (fail-closed), exit 0" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-right.toml" "$SANDBOX/nonexistent-plugin" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"supported_efforts": []'* ]]
}

@test "plugin present but validator pattern moved -> supported_efforts [] (fail-closed, never guessed)" {
  bin="$(_stub_codex "codex-cli 0.144.0")"
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin-no-validator" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"supported_efforts": []'* ]]
}

# --- fail-closed: CLI version ---------------------------------------------------

@test "old CLI 0.143.0 -> cli_ok false (floor is 0.144), version still reported" {
  bin="$(_stub_codex "codex-cli 0.143.0")"
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"cli_version": "0.143.0"'* ]]
  [[ "$output" == *'"cli_ok": false'* ]]
}

@test "CLI at 1.0.0 (major above floor) -> cli_ok true" {
  bin="$(_stub_codex "codex-cli 1.0.0")"
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"cli_ok": true'* ]]
}

@test "absent codex binary -> cli_version absent, cli_ok false, exit 0" {
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin" "$SANDBOX/no-such-codex"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"cli_version": "absent"'* ]]
  [[ "$output" == *'"cli_ok": false'* ]]
}

@test "codex binary emitting garbage -> cli_version absent, cli_ok false" {
  bin="$(_stub_codex "not a version at all")"
  _run_preflight "$FIXTURES/config-right.toml" "$FIXTURES/plugin" "$bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"cli_version": "absent"'* ]]
  [[ "$output" == *'"cli_ok": false'* ]]
}

# --- everything-absent (Claude-only host) ---------------------------------------

@test "Claude-only host (no config, no plugin, no CLI) -> fully fail-closed report, exit 0" {
  _run_preflight "$SANDBOX/none.toml" "$SANDBOX/none-plugin" "$SANDBOX/none-codex"
  [ "$status" -eq 0 ]
  _assert_json
  [[ "$output" == *'"pin_ok": false'* ]]
  [[ "$output" == *'"supported_efforts": []'* ]]
  [[ "$output" == *'"cli_ok": false'* ]]
}
