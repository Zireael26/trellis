#!/usr/bin/env bats
# Temp-home compatibility tests; never read or repair the installed plugins.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d)"
  ACCOUNT="$SANDBOX/account"
  BIN="$SANDBOX/bin"
  mkdir -p "$ACCOUNT" "$BIN"
  printf '#!/bin/sh\nexit 0\n' > "$BIN/node"
  chmod 755 "$BIN/node"
  CHECKER="$REPO_ROOT/scripts/check-codex-plugin-surface.sh"
  CODEX_MANIFEST="$ACCOUNT/.codex/plugins/cache/openai-codex/codex/1.0.6/hooks/hooks.json"
  CLAUDE_MANIFEST="$ACCOUNT/.claude/plugins/cache/openai-codex/codex/1.0.6/hooks/hooks.json"
}

teardown() { rm -rf "$SANDBOX"; }

manifest() {
  mkdir -p "$(dirname "$1")"
  # Compact serialization defeats the old whitespace-dependent text replacement.
  printf '%s\n' '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"node companion.mjs stop","timeout":5}]}],"Stop":[{"hooks":[{"type":"command","command":"node companion.mjs review","timeout":120}]}]}}' > "$1"
  chmod 640 "$1"
}

check_surface() {
  run env HOME="$ACCOUNT" PATH="$BIN:$PATH" bash "$CHECKER" "$@"
}

@test "no plugin is accurately reported and check creates no node shim" {
  check_surface
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
  [ ! -e "$ACCOUNT/.local" ]
}

@test "default check diagnoses compact Codex JSON without any mutation" {
  manifest "$CODEX_MANIFEST"
  cp "$CODEX_MANIFEST" "$SANDBOX/before.json"
  check_surface
  [ "$status" -eq 1 ]
  [[ "$output" == *"SessionEnd timeout capped at 3s"* ]]
  cmp "$CODEX_MANIFEST" "$SANDBOX/before.json"
  [ ! -e "$ACCOUNT/.local" ]
}

@test "explicit repair covers both caches and only caps Codex SessionEnd" {
  manifest "$CODEX_MANIFEST"
  manifest "$CLAUDE_MANIFEST"
  check_surface --repair
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(readlink "$ACCOUNT/.local/bin/node")" = "$BIN/node" ]
  jq -e '.hooks.SessionEnd[0].hooks[0].timeout == 3 and .hooks.Stop[0].hooks[0].timeout == 120 and (.hooks.SessionEnd[0].hooks[0].command | startswith("PATH="))' "$CODEX_MANIFEST"
  jq -e '.hooks.SessionEnd[0].hooks[0].timeout == 5 and (.hooks.SessionEnd[0].hooks[0].command | startswith("PATH="))' "$CLAUDE_MANIFEST"
  python3 - "$CODEX_MANIFEST" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640
PY
  cp "$CODEX_MANIFEST" "$SANDBOX/repaired.json"
  check_surface --repair
  [ "$status" -eq 0 ]
  [[ "$output" != *"repaired"* ]]
  cmp "$CODEX_MANIFEST" "$SANDBOX/repaired.json"
}

@test "repair refuses to replace an operator-owned node executable" {
  manifest "$CODEX_MANIFEST"
  mkdir -p "$ACCOUNT/.local/bin"
  printf '#!/bin/sh\necho operator-owned\n' > "$ACCOUNT/.local/bin/node"
  chmod 755 "$ACCOUNT/.local/bin/node"
  cp "$ACCOUNT/.local/bin/node" "$SANDBOX/owned-node"
  check_surface --repair
  [ "$status" -eq 1 ]
  [[ "$output" == *"operator-owned"* ]]
  [ ! -L "$ACCOUNT/.local/bin/node" ]
  cmp "$ACCOUNT/.local/bin/node" "$SANDBOX/owned-node"
}

@test "malformed manifest is surfaced and preserved even under repair" {
  mkdir -p "$(dirname "$CODEX_MANIFEST")"
  printf '{broken\n' > "$CODEX_MANIFEST"
  cp "$CODEX_MANIFEST" "$SANDBOX/before.json"
  check_surface --repair
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot inspect/repair"* ]]
  cmp "$CODEX_MANIFEST" "$SANDBOX/before.json"
}

@test "doctor health check is read-only and propagates actionable drift" {
  manifest "$CODEX_MANIFEST"
  cp "$CODEX_MANIFEST" "$SANDBOX/before.json"
  run env HOME="$ACCOUNT" PATH="$BIN:$PATH" bash -c '
    SCRIPT_DIR="$1/scripts"
    . "$SCRIPT_DIR/lib/health-checks.sh"
    hc_codex_plugin_surface
  ' doctor-fixture "$REPO_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repair"* ]]
  [[ "$output" != *"auto-repaired"* ]]
  cmp "$CODEX_MANIFEST" "$SANDBOX/before.json"
  [ ! -e "$ACCOUNT/.local" ]
}

@test "doctor reports absent plugin rather than claiming hooks present" {
  run env HOME="$ACCOUNT" PATH="$BIN:$PATH" bash -c '
    SCRIPT_DIR="$1/scripts"
    . "$SCRIPT_DIR/lib/health-checks.sh"
    hc_codex_plugin_surface
  ' doctor-fixture "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "unknown flags are rejected without creating directories" {
  check_surface --unexpected
  [ "$status" -eq 64 ]
  [ ! -e "$ACCOUNT/.local" ]
}

@test "valid pinned node shim survives an equivalent PATH alias" {
  manifest "$CODEX_MANIFEST"
  mkdir -p "$ACCOUNT/.local/bin" "$SANDBOX/real-bin"
  mv "$BIN/node" "$SANDBOX/real-bin/node"
  ln -s "$SANDBOX/real-bin/node" "$BIN/node"
  ln -s "$SANDBOX/real-bin/node" "$ACCOUNT/.local/bin/node"
  check_surface --repair
  [ "$status" -eq 0 ]
  [ "$(readlink "$ACCOUNT/.local/bin/node")" = "$SANDBOX/real-bin/node" ]
  [[ "$output" != *"refreshed"* ]]
}

@test "invalid hooks shape cannot produce a healthy check" {
  mkdir -p "$(dirname "$CODEX_MANIFEST")"
  printf '{"hooks": []}\n' > "$CODEX_MANIFEST"
  check_surface
  [ "$status" -eq 1 ]
  [[ "$output" == *"hooks must be an object"* ]]
}

@test "valid pinned node version survives a different interactive PATH version" {
  manifest "$CODEX_MANIFEST"
  mkdir -p "$ACCOUNT/.local/bin" "$SANDBOX/pinned-bin"
  printf '#!/bin/sh\necho pinned-version\n' > "$SANDBOX/pinned-bin/node"
  chmod 755 "$SANDBOX/pinned-bin/node"
  ln -s "$SANDBOX/pinned-bin/node" "$ACCOUNT/.local/bin/node"
  check_surface --repair
  [ "$status" -eq 0 ]
  [ "$(readlink "$ACCOUNT/.local/bin/node")" = "$SANDBOX/pinned-bin/node" ]
  [[ "$output" != *"refreshed"* ]]
}

@test "missing external node is diagnosed without creating a shim" {
  manifest "$CODEX_MANIFEST"
  rm "$BIN/node"
  ln -s "$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')" "$BIN/python3"
  run env HOME="$ACCOUNT" PATH="$BIN" /bin/bash "$CHECKER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no node outside"* ]]
  [ ! -e "$ACCOUNT/.local" ]
}
