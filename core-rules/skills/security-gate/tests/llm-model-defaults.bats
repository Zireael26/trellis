#!/usr/bin/env bats
# Deterministic coverage that non-Anthropic providers require an explicit
# LLM_MODEL. Proves llm-call.sh fails closed (exit 2) before invoking the
# llm binary and that an explicit model is forwarded.

setup() {
  TEST_ROOT="$(mktemp -d)"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$BIN"
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LLC="$SCRIPT_ROOT/scripts/lib/llm-call.sh"

  PROMPT_FILE="$TEST_ROOT/prompt.md"
  INPUT_FILE="$TEST_ROOT/input.json"
  OUT_FILE="$TEST_ROOT/out.json"
  printf '%s\n' 'system prompt' > "$PROMPT_FILE"
  printf '%s\n' '{"input":1}' > "$INPUT_FILE"

  INVOCATION_LOG="$TEST_ROOT/invocations.log"
  MODEL_LOG="$TEST_ROOT/model.log"
  export INVOCATION_LOG MODEL_LOG

  cat > "$BIN/llm" <<'SH'
#!/usr/bin/env bash
# Stub: record invocation and model, produce non-empty output.
echo "invoked:$*" >> "$INVOCATION_LOG"
MODEL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -m) MODEL="$2"; printf '%s' "$MODEL" > "$MODEL_LOG"; shift 2 ;;
    *) shift ;;
  esac
done
# Consume stdin to mimic real llm.
cat >/dev/null
printf '%s\n' '{"ok":1}'
exit 0
SH
  chmod +x "$BIN/llm"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "openai without LLM_MODEL exits 2 before llm invocation" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=openai LLM_MODEL="" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "llm should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$OUT_FILE" ]
  [[ "$output" == *"requires LLM_MODEL"* ]]
}

@test "gemini without LLM_MODEL exits 2 before llm invocation" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=gemini LLM_MODEL="" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "llm should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$OUT_FILE" ]
  [[ "$output" == *"requires LLM_MODEL"* ]]
}

@test "ollama without LLM_MODEL exits 2 before llm invocation" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=ollama LLM_MODEL="" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "llm should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$OUT_FILE" ]
  [[ "$output" == *"requires LLM_MODEL"* ]]
}

@test "openai with explicit LLM_MODEL forwards the model to llm" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=openai LLM_MODEL="openai-explicit" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -s "$INVOCATION_LOG" ]
  run cat "$MODEL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "openai-explicit" ]
  [ -s "$OUT_FILE" ]
}

@test "gemini with explicit LLM_MODEL forwards the model to llm" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=gemini LLM_MODEL="gemini-explicit" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  run cat "$MODEL_LOG"
  [ "$output" = "gemini-explicit" ]
}

@test "ollama with explicit LLM_MODEL forwards the model to llm" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=ollama LLM_MODEL="ollama-explicit" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  run cat "$MODEL_LOG"
  [ "$output" = "ollama-explicit" ]
}

@test "anthropic without LLM_MODEL defaults to claude-opus-5 and invokes llm" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=anthropic bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  run cat "$MODEL_LOG"
  [ "$output" = "claude-opus-5" ]
}

@test "empty provider without LLM_MODEL defaults to anthropic claude-opus-5" {
  run env PATH="$BIN:$PATH" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  run cat "$MODEL_LOG"
  [ "$output" = "claude-opus-5" ]
}

@test "anthropic with explicit LLM_MODEL respects the explicit value" {
  run env PATH="$BIN:$PATH" LLM_PROVIDER=anthropic LLM_MODEL="anthropic-explicit" bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  run cat "$MODEL_LOG"
  [ "$output" = "anthropic-explicit" ]
}
