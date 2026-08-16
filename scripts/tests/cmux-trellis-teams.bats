#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LAUNCHER="$ROOT/scripts/cmux-trellis-teams"
  export CMUX_BIN=/usr/bin/true
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex"
  mkdir -p "$CODEX_HOME"
}

json_field() {
  jq -r "$1" <<<"$output"
}

@test "claude is the default mode and resolves a direct Anthropic session" {
  run "$LAUNCHER" --dry-run --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(json_field '.mode')" = claude ]
  [ "$(json_field '.main_model')" = "opus[1m]" ]
  [ "$(json_field '.topology')" = direct ]
  [ "$(json_field '.base_url')" = https://api.anthropic.com ]
  [ "$(json_field '.command[-1]')" = --dangerously-skip-permissions ]
}

@test "explicit claude mode matches the default" {
  run "$LAUNCHER" --dry-run --mode claude
  [ "$status" -eq 0 ]
  [ "$(json_field '.mode')" = claude ]
  [ "$(json_field '.settings.advisorModel')" = claude-opus-5 ]
  [ "$(json_field '.settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL')" = claude-opus-5 ]
  [ "$(json_field '.settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL')" = claude-sonnet-5 ]
  [ "$(json_field '.settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL')" = claude-haiku-4-5-20251001 ]
}

@test "model overrides accept Claude aliases and literal claude-* ids only" {
  run "$LAUNCHER" --dry-run --model sonnet
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = claude-sonnet-5 ]

  run "$LAUNCHER" --dry-run --model haiku
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = claude-haiku-4-5-20251001 ]

  run "$LAUNCHER" --dry-run --model fable
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = claude-fable-5 ]

  run "$LAUNCHER" --dry-run --model claude-opus-4-7
  [ "$status" -eq 0 ]
  [ "$(json_field '.main_model')" = claude-opus-4-7 ]

  run "$LAUNCHER" --dry-run --model sol
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported model"* ]] || { echo "$output"; false; }

  run "$LAUNCHER" --dry-run --model terra
  [ "$status" -ne 0 ]
}

@test "advisor selectors accept auto, opus, fable, and none" {
  run "$LAUNCHER" --dry-run --advisor opus
  [ "$status" -eq 0 ]
  [ "$(json_field '.advisor')" = opus ]
  [ "$(json_field '.settings.advisorModel')" = claude-opus-5 ]

  run "$LAUNCHER" --dry-run --advisor fable
  [ "$status" -eq 0 ]
  [ "$(json_field '.advisor')" = fable ]
  [ "$(json_field '.settings.advisorModel')" = claude-fable-5 ]

  run "$LAUNCHER" --dry-run --advisor none
  [ "$status" -eq 0 ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL')" = 1 ]

  run "$LAUNCHER" --dry-run --advisor sol
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported advisor"* ]] || { echo "$output"; false; }
}

@test "delegates defaults to auto and accepts claude and none" {
  run "$LAUNCHER" --dry-run
  [ "$status" -eq 0 ]
  [ "$(json_field '.delegates')" = auto ]
  [[ "$(json_field '.command | join(" ")')" == *"--delegates auto governs"* ]] || { echo "$output"; false; }

  run "$LAUNCHER" --dry-run --delegates claude
  [ "$status" -eq 0 ]
  [ "$(json_field '.delegates')" = claude ]

  run "$LAUNCHER" --dry-run --delegates none
  [ "$status" -eq 0 ]
  [ "$(json_field '.delegates')" = none ]

  run "$LAUNCHER" --dry-run --delegates gpt
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported delegates"* ]] || { echo "$output"; false; }
}

@test "removed routed topologies are rejected" {
  for mode in codex hybrid deepseek muse-contributor; do
    run "$LAUNCHER" --dry-run --mode "$mode"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported mode"* ]] || { echo "$output"; false; }
  done
  run "$LAUNCHER" --dry-run --mode nope
  [ "$status" -ne 0 ]
}

@test "the session carries no router, guard, or alias-policy environment" {
  run "$LAUNCHER" --dry-run
  [ "$status" -eq 0 ]
  [ "$(json_field '.settings.env.ANTHROPIC_CUSTOM_HEADERS // "unset"')" = unset ]
  [ "$(json_field '.settings.hooks // "unset"')" = unset ]
  [ "$(json_field '.settings.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS // "unset"')" = unset ]
}

@test "unknown Claude arguments are forwarded in order" {
  run "$LAUNCHER" --dry-run -- --resume abc --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(json_field '.command[-3]')" = --resume ]
  [ "$(json_field '.command[-2]')" = abc ]
  [ "$(json_field '.command[-1]')" = --dangerously-skip-permissions ]
}

@test "a real launch reaches cmux without touching a local gateway" {
  run env CMUX_BIN=/usr/bin/true CODEX_HOME="$CODEX_HOME" "$LAUNCHER"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'Trellis session:'
}

@test "Agent lifecycle guidance is injected into the session prompt" {
  run "$LAUNCHER" --dry-run
  [ "$status" -eq 0 ]
  [[ "$(json_field '.command | join(" ")')" == *"the root orchestrator may pass name"* ]] || { echo "$output"; false; }
  [[ "$(json_field '.command | join(" ")')" == *"TaskStop"* ]] || { echo "$output"; false; }
}
