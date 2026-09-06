#!/usr/bin/env bats
# Regression coverage for bounded Garak execution and report classification.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  NO_TIMEOUT_BIN="$TEST_ROOT/no-timeout-bin"
  mkdir -p "$PROJECT" "$BIN" "$NO_TIMEOUT_BIN"
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  GARAK_SCRIPT="$SCRIPT_ROOT/scripts/lib/garak.sh"

  INVOCATION_LOG="$TEST_ROOT/garak-invocations.log"
  export INVOCATION_LOG

  cat > "$BIN/garak" <<'SH'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$INVOCATION_LOG"
report_prefix=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report_prefix) report_prefix="$2"; shift 2 ;;
    *) shift ;;
  esac
done
report="${report_prefix}.test.report.jsonl"
case "${GARAK_MODE:-valid}" in
  valid)
    printf '%s\n' \
      '{"entry_type":"attempt","status":0,"probe_classname":"safe.Probe"}' \
      '{"entry_type":"attempt","status":1,"probe_classname":"promptinject.Probe","detector_results":{"detector":1}}' \
      > "$report"
    ;;
  error)
    printf '%s\n' '{"entry_type":"attempt","status":0,"probe_classname":"safe.Probe"}' > "$report"
    printf '%s\n' 'garak backend diagnostic sentinel' >&2
    exit 7
    ;;
  malformed)
    printf '%s\n' '{not-json' > "$report"
    ;;
  missing-status)
    printf '%s\n' '{"entry_type":"attempt","probe_classname":"promptinject.Probe"}' > "$report"
    ;;
esac
SH
  chmod +x "$BIN/garak"

  cat > "$BIN/timeout" <<'SH'
#!/bin/bash
[ "${1:-}" = "--preserve-status" ] && shift
shift
exec "$@"
SH
  chmod +x "$BIN/timeout"

  ln -s "$BIN/garak" "$NO_TIMEOUT_BIN/garak"
  for tool in bash head ls mkdir mktemp python3 rm; do
    ln -s "$(command -v "$tool")" "$NO_TIMEOUT_BIN/$tool"
  done
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "project-dir argument remains required but is not otherwise consumed" {
  out="$TEST_ROOT/garak.jsonl"

  run bash "$GARAK_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project-dir required"* ]]

  run env SECURITY_GATE_GARAK_TARGET="" bash "$GARAK_SCRIPT" "$TEST_ROOT/not-a-project" "$out"
  [ "$status" -eq 2 ]
  [ -f "$out" ]
}

@test "garak is not invoked unbounded when no timeout utility is available" {
  out="$TEST_ROOT/garak.jsonl"

  run /usr/bin/env PATH="$NO_TIMEOUT_BIN" SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    /bin/bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$INVOCATION_LOG" ] || { echo "garak should not have been invoked"; cat "$INVOCATION_LOG"; false; }
  [ ! -s "$out" ]
  [[ "$output" == *"neither timeout nor gtimeout is available"* ]]
}

@test "garak execution errors preserve stderr and return indeterminate" {
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=error SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$out" ]
  [[ "$output" == *"garak execution failed (rc=7)"* ]]
  [[ "$output" == *"garak backend diagnostic sentinel"* ]]
}

@test "garak malformed JSON records return indeterminate" {
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=malformed SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$out" ]
  [[ "$output" == *"malformed JSON at line 1"* ]]
}

@test "garak attempt records without status return indeterminate" {
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=missing-status SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 2 ]
  [ ! -s "$out" ]
  [[ "$output" == *"attempt at line 1 has no status"* ]]
}

@test "garak valid attempt records retain pass and finding normalization" {
  out="$TEST_ROOT/garak.jsonl"

  run env PATH="$BIN:$PATH" GARAK_MODE=valid SECURITY_GATE_GARAK_TARGET="openai:test-model" \
    bash "$GARAK_SCRIPT" "$PROJECT" "$out"
  [ "$status" -eq 0 ]

  run python3 -c '
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(rows) == 1, rows
assert rows[0]["tool"] == "garak"
assert rows[0]["rule"] == "promptinject.Probe"
assert rows[0]["severity"] == "high"
' "$out"
  [ "$status" -eq 0 ]
}
