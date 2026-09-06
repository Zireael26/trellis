#!/usr/bin/env bats
# Deterministic coverage that non-Anthropic providers require an explicit
# LLM_MODEL. Proves llm-call.sh fails closed (exit 2) before invoking the
# llm binary and that an explicit model is forwarded.

setup() {
  TEST_ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/security-gate-llm.XXXXXX")"
  BIN="$TEST_ROOT/bin"
  NO_TIMEOUT_BIN="$TEST_ROOT/no-timeout-bin"
  ALLOC_FAIL_BIN="$TEST_ROOT/alloc-fail-bin"
  DIAG_DIR="$TEST_ROOT/diagnostics"
  mkdir -p "$BIN" "$NO_TIMEOUT_BIN" "$ALLOC_FAIL_BIN" "$DIAG_DIR"
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
if [ -n "${LLM_STUB_STDERR:-}" ]; then
  printf '%s' "$LLM_STUB_STDERR" >&2
fi
if [ "${LLM_STUB_EXIT:-0}" -ne 0 ]; then
  exit "$LLM_STUB_EXIT"
fi
printf '%s\n' '{"ok":1}'
exit 0
SH
  chmod +x "$BIN/llm"

  cat > "$ALLOC_FAIL_BIN/mktemp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'stub mktemp refusal' >&2
exit 1
SH
  chmod +x "$ALLOC_FAIL_BIN/mktemp"

  cat > "$BIN/timeout" <<'SH'
#!/bin/bash
[ "${1:-}" = "--preserve-status" ] && shift
shift
exec "$@"
SH
  chmod +x "$BIN/timeout"

  for tool in bash cat; do
    ln -s "$(command -v "$tool")" "$NO_TIMEOUT_BIN/$tool"
  done
  ln -s "$BIN/llm" "$NO_TIMEOUT_BIN/llm"
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

@test "llm is not invoked unbounded when no timeout utility is available" {
  run /usr/bin/env PATH="$NO_TIMEOUT_BIN" LLM_PROVIDER=anthropic LLM_MODEL="anthropic-explicit" \
    /bin/bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "llm should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$OUT_FILE" ]
  [[ "$output" == *"neither timeout nor gtimeout is available"* ]]
}

@test "successful llm call removes its private diagnostic" {
  run env PATH="$BIN:$PATH" TMPDIR="$DIAG_DIR" LLM_PROVIDER=anthropic LLM_MODEL="anthropic-explicit" \
    bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 0 ]
  [ -s "$OUT_FILE" ]
  shopt -s nullglob
  diagnostics=("$DIAG_DIR"/security-gate-llm.*)
  [ "${#diagnostics[@]}" -eq 0 ]
}

@test "failed llm calls retain different private diagnostics with stderr bytes" {
  run env PATH="$BIN:$PATH" TMPDIR="$DIAG_DIR" LLM_PROVIDER=anthropic LLM_MODEL="anthropic-explicit" \
    LLM_STUB_STDERR="first private diagnostic" LLM_STUB_EXIT=9 \
    bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 2 ]
  FIRST_WARNING="$output"
  FIRST_ERR="${FIRST_WARNING##* — see }"
  [ "$FIRST_WARNING" = "warn: llm call failed (model=anthropic-explicit provider=anthropic) — see $FIRST_ERR" ]
  [ -f "$FIRST_ERR" ]
  [[ "$(ls -ld "$FIRST_ERR")" == "-rw-------"* ]] || return 1
  [ "$(cat "$FIRST_ERR")" = "first private diagnostic" ]
  [ ! -s "$OUT_FILE" ]

  SECOND_OUT="$TEST_ROOT/out-second.json"
  run env PATH="$BIN:$PATH" TMPDIR="$DIAG_DIR" LLM_PROVIDER=anthropic LLM_MODEL="anthropic-explicit" \
    LLM_STUB_STDERR="second private diagnostic" LLM_STUB_EXIT=7 \
    bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$SECOND_OUT"
  [ "$status" -eq 2 ]
  SECOND_WARNING="$output"
  SECOND_ERR="${SECOND_WARNING##* — see }"
  [ "$SECOND_WARNING" = "warn: llm call failed (model=anthropic-explicit provider=anthropic) — see $SECOND_ERR" ]
  [ "$SECOND_ERR" != "$FIRST_ERR" ]
  [ -f "$SECOND_ERR" ]
  [[ "$(ls -ld "$SECOND_ERR")" == "-rw-------"* ]] || return 1
  [ "$(cat "$SECOND_ERR")" = "second private diagnostic" ]
  [ ! -s "$SECOND_OUT" ]
}

@test "diagnostic allocation failure exits 2 before llm invocation" {
  run env PATH="$ALLOC_FAIL_BIN:$BIN:$PATH" TMPDIR="$DIAG_DIR" LLM_PROVIDER=anthropic LLM_MODEL="anthropic-explicit" \
    bash "$LLC" "$PROMPT_FILE" "$INPUT_FILE" "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "llm should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$OUT_FILE" ]
  [[ "$output" == *"unable to allocate private llm diagnostic at $DIAG_DIR/security-gate-llm.XXXXXX"* ]]
}
