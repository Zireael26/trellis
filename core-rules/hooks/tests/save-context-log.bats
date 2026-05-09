#!/usr/bin/env bats
# Tests for save-context-log.sh — PreCompact hook.
# Covers P1.4 (JSONL filter excludes tool_result wrappers; envelope validation).

load helpers

HOOK="$HOOKS_DIR/save-context-log.sh"

setup() {
  setup_project_dir
}

teardown() {
  teardown_project_dir
}

# Build a synthetic transcript JSONL covering the shapes save-context-log
# parses: real user prompts (string content) and tool_result wrappers
# (array content where items have .type == "tool_result").
seed_transcript() {
  local file="$1"
  cat > "$file" <<'EOF'
{"type":"user","message":{"role":"user","content":"first real user prompt"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"abc","content":"tool output here"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first assistant decision"},{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":"second real user prompt"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"def","content":"more tool output"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"second assistant decision"}]}}
EOF
}

@test "P1.4: real transcript → user section has only user-typed prompts" {
  TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
  seed_transcript "$TRANSCRIPT"
  run bash "$HOOK" <<<"{\"transcript_path\": \"$TRANSCRIPT\"}"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/context-log.md" ]
  # Real user prompts present
  grep -q "first real user prompt" "$PROJECT_DIR/context-log.md"
  grep -q "second real user prompt" "$PROJECT_DIR/context-log.md"
  # tool_result content NOT present
  ! grep -q "tool output here" "$PROJECT_DIR/context-log.md"
  ! grep -q "tool_use_id" "$PROJECT_DIR/context-log.md"
}

@test "P1.4: real transcript → assistant section extracts text blocks only" {
  TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
  seed_transcript "$TRANSCRIPT"
  run bash "$HOOK" <<<"{\"transcript_path\": \"$TRANSCRIPT\"}"
  grep -q "first assistant decision" "$PROJECT_DIR/context-log.md"
  grep -q "second assistant decision" "$PROJECT_DIR/context-log.md"
}

@test "P1.4: bad PROJECT_DIR → rc=1 + stderr line" {
  CLAUDE_PROJECT_DIR="/nonexistent/path/xyz"
  run_with_stderr "$HOOK" '{}'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PROJECT_DIR not a directory"* ]]
}

@test "P1.4: bad transcript_path → rc=1 + stderr line" {
  run_with_stderr "$HOOK" '{"transcript_path": "/nonexistent/transcript.jsonl"}'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"transcript_path"* ]]
  [[ "$stderr" == *"does not exist"* ]]
}

@test "P1.4: empty envelope → rc=0 (transcript_path optional)" {
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
}
