#!/usr/bin/env bats
# Tests for the GPTX global switch (spec 028) — the `gptx` config block resolved
# by the SHARED reader in spec-gate-core.sh.
#
# The property under test: absence, `enabled: false`, and a malformed block are
# all indistinguishable from a Trellis that never shipped GPTX. Off is the safe
# direction because it can only withdraw an instruction to use a lane, never
# invent one — a single-subscription operator who mistypes the block must not be
# handed doctrine they cannot satisfy.
#
# The reader is shared with `mandatory_pipeline` (spec 006) on purpose: one
# parser, two blocks. `spec-gate.bats` guards that the refactor did not move
# mandatory_pipeline's semantics; this file guards the gptx side.
#
# bash 3.2 / bats 1.x compatible.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CORE="$REPO/core-rules/hooks/lib/spec-gate-core.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  cd "$SANDBOX"
}

teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
}

resolve() {
  # shellcheck source=/dev/null
  ( . "$CORE"; sg_resolve_gptx "$SANDBOX" )
}

predicate() {
  # shellcheck source=/dev/null
  ( . "$CORE"; if sg_gptx_enabled "$SANDBOX"; then echo on; else echo off; fi )
}

@test "absent: no config file at all resolves to off/disabled" {
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "false disabled" ]
  [ "$(predicate)" = off ]
}

@test "absent: config present but no gptx block resolves to off/disabled" {
  echo '{"maintainer_name":"t"}' > trellis.config.json
  run resolve
  [ "$output" = "false disabled" ]
  [ "$(predicate)" = off ]
}

@test "false: explicit enabled:false resolves to off, status ok" {
  echo '{"gptx":{"enabled":false}}' > trellis.config.json
  run resolve
  [ "$output" = "false ok" ]
  [ "$(predicate)" = off ]
}

@test "true: explicit enabled:true resolves to on" {
  echo '{"gptx":{"enabled":true}}' > trellis.config.json
  run resolve
  [ "$output" = "true ok" ]
  [ "$(predicate)" = on ]
}

@test "malformed: unparseable JSON fails CLOSED (off)" {
  echo '{"gptx":{"enabled":true' > trellis.config.json
  run resolve
  [ "$output" = "false malformed" ]
  [ "$(predicate)" = off ]
}

@test "malformed: gptx present but not an object fails CLOSED (off)" {
  echo '{"gptx":true}' > trellis.config.json
  run resolve
  [ "$output" = "false malformed" ]
  [ "$(predicate)" = off ]
}

@test "malformed: enabled is a string, not a boolean, fails CLOSED (off)" {
  echo '{"gptx":{"enabled":"yes"}}' > trellis.config.json
  run resolve
  [ "$output" = "false malformed" ]
  [ "$(predicate)" = off ]
}

@test "missing enabled key inside a present block defaults to off" {
  echo '{"gptx":{"comment":"declared but never switched on"}}' > trellis.config.json
  run resolve
  [ "$output" = "false ok" ]
  [ "$(predicate)" = off ]
}

@test "project-local overrides central: local false beats central true" {
  echo '{"gptx":{"enabled":true}}'  > trellis.config.json
  echo '{"gptx":{"enabled":false}}' > .trellis.config.json
  run resolve
  [ "$output" = "false ok" ]
  [ "$(predicate)" = off ]
}

@test "project-local overrides central: local true beats central false" {
  echo '{"gptx":{"enabled":false}}' > trellis.config.json
  echo '{"gptx":{"enabled":true}}'  > .trellis.config.json
  run resolve
  [ "$output" = "true ok" ]
  [ "$(predicate)" = on ]
}

@test "project-local without the block falls through to central" {
  echo '{"gptx":{"enabled":true}}' > trellis.config.json
  echo '{"autonomy":3}'            > .trellis.config.json
  run resolve
  [ "$output" = "true ok" ]
  [ "$(predicate)" = on ]
}

@test "an unparseable project-local config fails CLOSED even if central is valid" {
  echo '{"gptx":{"enabled":true}}' > trellis.config.json
  echo 'not json at all'           > .trellis.config.json
  run resolve
  [ "$output" = "false malformed" ]
  [ "$(predicate)" = off ]
}

@test "this checkout's own config resolves correctly for what it is" {
  # Two legitimate shapes, and the assertion differs by which one this is:
  #   - the live trellis-instance DECLARES the block and dogfoods it ON, exactly as it
  #     does for mandatory_pipeline;
  #   - the PUBLIC TEMPLATE ships no block at all, and must therefore resolve OFF.
  # The second is the more important guarantee — it is the whole claim of spec 028, that
  # a fresh public clone behaves as though GPTX never shipped. Asserting `true` here
  # unconditionally made this test unrunnable in the mirror, which is how it was found.
  # shellcheck source=/dev/null
  run bash -c ". '$CORE'; sg_resolve_gptx '$REPO'"
  if grep -q '"gptx"' "$REPO/trellis.config.json" 2>/dev/null; then
    [ "$output" = "true ok" ]
  else
    [ "$output" = "false disabled" ]
  fi
}

@test "shared reader: mandatory_pipeline still resolves independently of gptx" {
  # Both blocks present, opposite values — neither may leak into the other.
  cat > trellis.config.json <<'JSON'
{
  "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 80 },
  "gptx": { "enabled": false }
}
JSON
  # shellcheck source=/dev/null
  run bash -c ". '$CORE'; sg_resolve_cfg '$SANDBOX'"
  [ "$output" = "true 80 400 ok" ]
  [ "$(predicate)" = off ]
}

@test "shared reader: a malformed mandatory_pipeline does not disable a valid gptx" {
  # mandatory_pipeline's threshold validation is block-specific; it must not
  # bleed into the gptx resolution, which has no thresholds.
  cat > trellis.config.json <<'JSON'
{
  "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": -5 },
  "gptx": { "enabled": true }
}
JSON
  # shellcheck source=/dev/null
  run bash -c ". '$CORE'; sg_resolve_cfg '$SANDBOX'"
  [ "$output" = "false 80 400 malformed" ]
  [ "$(predicate)" = on ]
}
