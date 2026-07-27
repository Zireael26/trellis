#!/usr/bin/env bats

setup() {
  export ROOT
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAUNCHER="$ROOT/scripts/cmux-trellis-teams"
  export CMUX_BIN=/usr/bin/true
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex"
  mkdir -p "$CODEX_HOME"
  cp "$BATS_TEST_DIRNAME/fixtures/models-cache-272k.json" "$CODEX_HOME/models_cache.json"
}

json_field() {
  jq -r "$1" <<<"$output"
}

@test "gptx preserves the Claude main loop and split router" {
  run "$LAUNCHER" --dry-run --mode gptx --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(json_field '.mode')" = gptx ]
  [ "$(json_field '.main_model')" = "opus[1m]" ]
  [ "$(json_field '.base_url')" = http://127.0.0.1:8318 ]
  [ "$(json_field '.command[-1]')" = --dangerously-skip-permissions ]
}

@test "codex maps the opus family to Terra and selects Sol advisor" {
  run "$LAUNCHER" --dry-run --mode codex
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-terra ]
  [ "$(json_field '.claude_model')" = opus ]
  [ "$(json_field '.advisor')" = sol ]
  [ "$(json_field '.advisor_transport')" = server-tool ]
  [ "$(json_field '.settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL')" = gpt-5.6-terra ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS')" = 272000 ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // "unset"')" = unset ]
}

@test "hybrid defaults to Terra with an auto Claude to Sol advisor" {
  run "$LAUNCHER" --dry-run --mode hybrid
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-terra ]
  [ "$(json_field '.advisor')" = auto ]
  [ "$(json_field '.settings.advisorModel')" = claude-opus-5 ]
}

@test "pure Claude bypasses the local router" {
  run "$LAUNCHER" --dry-run --mode claude
  [ "$status" -eq 0 ]
  [ "$(json_field '.base_url')" = https://api.anthropic.com ]
  [ "$(json_field '.advisor_transport')" = server-tool ]
  [ "$(json_field '.settings.env.ANTHROPIC_CUSTOM_HEADERS // "unset"')" = unset ]
}

@test "Claude with Sol advisor uses the explicit nested-agent override" {
  run "$LAUNCHER" --dry-run --mode claude --advisor sol
  [ "$status" -eq 0 ]
  [ "$(json_field '.base_url')" = http://127.0.0.1:8318 ]
  [ "$(json_field '.advisor_transport')" = nested-agent ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL')" = 1 ]
  [[ "$(json_field '.command | join(" ")')" == *gpt-sol-advisor* ]]
}

@test "model and advisor flags override mode defaults" {
  run "$LAUNCHER" --dry-run --mode hybrid --model sol --advisor fable
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = gpt-5.6-sol ]
  [ "$(json_field '.advisor')" = fable ]
  [ "$(json_field '.settings.advisorModel')" = claude-fable-5 ]
}

@test "unknown Claude arguments are forwarded in order" {
  run "$LAUNCHER" --dry-run --mode codex -- --resume abc --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(json_field '.command[-3]')" = --resume ]
  [ "$(json_field '.command[-2]')" = abc ]
  [ "$(json_field '.command[-1]')" = --dangerously-skip-permissions ]
}

@test "invalid modes and cross-mode models fail closed" {
  run "$LAUNCHER" --dry-run --mode nope
  [ "$status" -eq 2 ]

  run "$LAUNCHER" --dry-run --mode codex --model opus
  [ "$status" -eq 2 ]

  run "$LAUNCHER" --dry-run --mode claude --model terra
  [ "$status" -eq 2 ]
}
