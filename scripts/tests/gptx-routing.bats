#!/usr/bin/env bats
# Tests for GPTX directional family routing (spec 030) — the nested `routing`
# block resolved through the shared config reader in spec-gate-core.sh.
#
# A missing routing block under an enabled GPTX switch is a successful (`ok`)
# resolution to the spec-028 fallback. A disabled switch is `disabled`. Every
# malformed or unavailable resolution returns the same fallback triple.
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
  ( . "$CORE"; sg_resolve_gptx_routing "$SANDBOX" )
}

@test "well-formed routing block resolves all values" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":0.7,"orchestrator_inline_max_lines":40}}}' > trellis.config.json
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "gpt 0.7 40 ok" ]
}

@test "routing absent under enabled GPTX resolves spec-028 fallback with ok status" {
  echo '{"gptx":{"enabled":true}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - ok" ]
}

@test "gptx absent resolves fallback with disabled status" {
  echo '{"maintainer_name":"t"}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - disabled" ]
}

@test "routing present but not an object is malformed" {
  echo '{"gptx":{"enabled":true,"routing":true}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "default_family outside the enum is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"sol","share_floor":0.7}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "share_floor zero is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":0}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "share_floor above one is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":1.5}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "share_floor string is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":"0.7"}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "share_floor boolean is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":true}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "share_floor null is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":null}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "orchestrator_inline_max_lines fraction is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":0.7,"orchestrator_inline_max_lines":2.5}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "project-local gptx block overrides central routing and enabled together" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":0.7,"orchestrator_inline_max_lines":40}}}' > trellis.config.json
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"claude","share_floor":0.6}}}' > .trellis.config.json
  run resolve
  [ "$output" = "claude 0.6 - ok" ]
}

@test "project-local gptx without routing does not borrow central routing" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt","share_floor":0.7,"orchestrator_inline_max_lines":40}}}' > trellis.config.json
  echo '{"gptx":{"enabled":true}}' > .trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - ok" ]
}

@test "gptx enabled false suppresses a valid routing block" {
  echo '{"gptx":{"enabled":false,"routing":{"default_family":"gpt","share_floor":0.7,"orchestrator_inline_max_lines":40}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - disabled" ]
}

@test "missing gptx enabled key suppresses a valid routing block" {
  echo '{"gptx":{"routing":{"default_family":"gpt","share_floor":0.7,"orchestrator_inline_max_lines":40}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - disabled" ]
}

@test "missing default_family in a present routing block is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"share_floor":0.7}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "missing share_floor in a present routing block is malformed" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"gpt"}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 0.4 - malformed" ]
}

@test "optional inline max may be absent and unknown routing keys are ignored" {
  echo '{"gptx":{"enabled":true,"routing":{"default_family":"balanced","share_floor":1,"future_key":"ignored"}}}' > trellis.config.json
  run resolve
  [ "$output" = "balanced 1 - ok" ]
}
