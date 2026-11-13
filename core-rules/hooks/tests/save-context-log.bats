#!/usr/bin/env bats
# Tests for save-context-log.sh — PreCompact hook.
# Covers P1.4 (JSONL filter excludes tool_result wrappers; envelope validation).

load helpers

HOOK="$HOOKS_DIR/save-context-log.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/save-context-log.sh"

setup() {
  setup_project_dir
}

teardown() {
  # Ensure unwritable fixtures don't block cleanup
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    chmod 700 "$PROJECT_DIR" 2>/dev/null || true
  fi
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
  # tool_result content NOT present. Counted, not `! grep -q`: a leading `!`
  # is never fatal under `set -e`, so the bare form asserted nothing.
  [ "$(grep -cF "tool output here" "$PROJECT_DIR/context-log.md")" -eq 0 ] ||
    { cat "$PROJECT_DIR/context-log.md"; false; }
  [ "$(grep -cF "tool_use_id" "$PROJECT_DIR/context-log.md")" -eq 0 ] ||
    { cat "$PROJECT_DIR/context-log.md"; false; }
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
  [[ "$stderr" == *"PROJECT_DIR not a directory"* ]] || false
}

@test "P1.4: bad transcript_path → rc=1 + stderr line" {
  run_with_stderr "$HOOK" '{"transcript_path": "/nonexistent/transcript.jsonl"}'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"transcript_path"* ]] || { echo "$stderr"; false; }
  [[ "$stderr" == *"does not exist"* ]] || false
}

@test "P1.4: empty envelope → rc=0 (transcript_path optional)" {
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
}

# C6-F12 + C8-F14: malformed envelope JSON must return 1 before any write, no file for each twin

@test "C6-F12: malformed envelope → exit1 and no file (canonical)" {
  run_with_stderr "$HOOK" '{'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"save-context-log"* ]] || false
  [[ "$stderr" == *"malformed envelope"* ]] || false
  [ ! -f "$PROJECT_DIR/context-log.md" ]
}

@test "C6-F12: malformed envelope with not json → exit1 and no file (canonical)" {
  run_with_stderr "$HOOK" 'not json'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"save-context-log"* ]] || false
  [ ! -f "$PROJECT_DIR/context-log.md" ]
}

@test "C8-F14: malformed envelope → exit1 and no file (codex)" {
  run_with_stderr "$CODEX_HOOK" '{'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"save-context-log"* ]] || false
  [[ "$stderr" == *"malformed envelope"* ]] || false
  [ ! -f "$PROJECT_DIR/context-log.md" ]
}

@test "C8-F14: malformed envelope with not json → exit1 and no file (codex)" {
  run_with_stderr "$CODEX_HOOK" 'not json'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"save-context-log"* ]] || false
  [ ! -f "$PROJECT_DIR/context-log.md" ]
}

# Per-section jq status: invalid todos must be visible, not silent omission

@test "C6-F12: malformed todos visible and valid sections kept (canonical)" {
  mkdir -p "$PROJECT_DIR/.claude"
  echo "{ invalid" > "$PROJECT_DIR/.claude/todos.json"
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/context-log.md" ]
  grep -q "malformed" "$PROJECT_DIR/context-log.md"
  grep -q "todos" "$PROJECT_DIR/context-log.md"
  # valid bounded sections still present
  grep -q "Branch" "$PROJECT_DIR/context-log.md"
}

@test "C8-F14: malformed todos visible (codex)" {
  mkdir -p "$PROJECT_DIR/.codex"
  echo "{ invalid" > "$PROJECT_DIR/.codex/todos.json"
  run bash "$CODEX_HOOK" <<<'{}'
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/context-log.md" ]
  grep -q "malformed" "$PROJECT_DIR/context-log.md"
  grep -q "todos" "$PROJECT_DIR/context-log.md"
  grep -q "Branch" "$PROJECT_DIR/context-log.md"
}

# Per-section jq status: invalid transcript must be visible

@test "C6-F12: malformed transcript visible and valid sections kept (canonical)" {
  TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
  echo "not json" > "$TRANSCRIPT"
  run_with_stderr "$HOOK" "{\"transcript_path\": \"$TRANSCRIPT\"}"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/context-log.md" ]
  grep -q "malformed" "$PROJECT_DIR/context-log.md"
  grep -q "transcript" "$PROJECT_DIR/context-log.md"
  grep -q "Branch" "$PROJECT_DIR/context-log.md"
}

@test "C8-F14: malformed transcript visible (codex)" {
  TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
  echo "not json" > "$TRANSCRIPT"
  run_with_stderr "$CODEX_HOOK" "{\"transcript_path\": \"$TRANSCRIPT\"}"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/context-log.md" ]
  grep -q "malformed" "$PROJECT_DIR/context-log.md"
  grep -q "transcript" "$PROJECT_DIR/context-log.md"
}

# Select last two JSON records before rendering — multiline safe

@test "C6-F12: multiline last two user asks complete (canonical)" {
  TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"first\nmultiline\nprompt"}}
{"type":"user","message":{"role":"user","content":"second\nprompt"}}
{"type":"user","message":{"role":"user","content":"third\nwith\nmany\nlines"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first\nassistant"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"second assistant"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"third\nassistant\nmultiline"}]}}
EOF
  run bash "$HOOK" <<<"{\"transcript_path\": \"$TRANSCRIPT\"}"
  [ "$status" -eq 0 ]
  # last two user messages must be complete, not fragments
  grep -q "second" "$PROJECT_DIR/context-log.md"
  grep -q "third" "$PROJECT_DIR/context-log.md"
  grep -q "many" "$PROJECT_DIR/context-log.md"
  # first should not be present (we take last two)
  [ "$(grep -c "first" "$PROJECT_DIR/context-log.md")" -eq 0 ] || { cat "$PROJECT_DIR/context-log.md"; false; }
  # assistant last two complete
  grep -q "second assistant" "$PROJECT_DIR/context-log.md"
  grep -q "multiline" "$PROJECT_DIR/context-log.md"
}

@test "C8-F14: multiline last two asks complete (codex)" {
  TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"a\nb"}}
{"type":"user","message":{"role":"user","content":"c\nd"}}
{"type":"user","message":{"role":"user","content":"e\nf"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"x\ny"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"p\nq"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"m\nn"}]}}
EOF
  run bash "$CODEX_HOOK" <<<"{\"transcript_path\": \"$TRANSCRIPT\"}"
  [ "$status" -eq 0 ]
  # last two user records: c/d and e/f should be present, a/b should not
  grep -q "c" "$PROJECT_DIR/context-log.md"
  grep -q "e" "$PROJECT_DIR/context-log.md"
  grep -q "f" "$PROJECT_DIR/context-log.md"
  [ "$(grep -c "^a$" "$PROJECT_DIR/context-log.md")" -eq 0 ] || { cat "$PROJECT_DIR/context-log.md"; false; }
  # assistant last two
  grep -q "p" "$PROJECT_DIR/context-log.md"
  grep -q "m" "$PROJECT_DIR/context-log.md"
}

# NUL-delimited porcelain: preserve names with spaces and rename paths, bounded to 40

@test "C6-F12: filename with spaces and rename complete (canonical)" {
  echo "hi" > "$PROJECT_DIR/old.txt"
  git -C "$PROJECT_DIR" add . && git -C "$PROJECT_DIR" commit -q -m "init2"
  touch "$PROJECT_DIR/file with spaces.txt"
  git -C "$PROJECT_DIR" mv old.txt "new with spaces.txt"
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q "file with spaces" "$PROJECT_DIR/context-log.md"
  grep -q "old.txt" "$PROJECT_DIR/context-log.md"
  grep -q "new with spaces" "$PROJECT_DIR/context-log.md"
}

@test "C8-F14: filename with spaces and rename complete (codex)" {
  echo "hi" > "$PROJECT_DIR/old.txt"
  git -C "$PROJECT_DIR" add . && git -C "$PROJECT_DIR" commit -q -m "init2"
  touch "$PROJECT_DIR/file with spaces.txt"
  git -C "$PROJECT_DIR" mv old.txt "new with spaces.txt"
  run bash "$CODEX_HOOK" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q "file with spaces" "$PROJECT_DIR/context-log.md"
  grep -q "old.txt" "$PROJECT_DIR/context-log.md"
  grep -q "new with spaces" "$PROJECT_DIR/context-log.md"
}

# Atomic temp+rename: write/setup/rename failure emits one stderr diagnostic while non-blocking

@test "C6-F12: unwritable output → exit0 + stderr diagnostic (canonical)" {
  chmod 500 "$PROJECT_DIR"
  run_with_stderr "$HOOK" '{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"save-context-log"* ]] || false
  [[ "$stderr" == *"failed"* ]] || false
  chmod 700 "$PROJECT_DIR"
}

@test "C8-F14: unwritable output → exit0 + stderr diagnostic (codex)" {
  chmod 500 "$PROJECT_DIR"
  run_with_stderr "$CODEX_HOOK" '{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"save-context-log"* ]] || false
  [[ "$stderr" == *"failed"* ]] || false
  chmod 700 "$PROJECT_DIR"
}

# Guard: adjacent temp directory proves atomic same-filesystem rename; single mktemp -d and fixed private names inside
@test "guard: temp directory is adjacent for atomic rename (canonical)" {
  grep -Fq 'mktemp -d "${OUT}.tmp' "$HOOK"
  [ "$(grep -c 'mktemp' "$HOOK")" -eq 1 ]
  grep -Fq 'TMPDIR}/' "$HOOK"
  grep -Fq 'rm -rf "${TMPDIR:?}"' "$HOOK"
}

@test "guard: temp directory is adjacent for atomic rename (codex)" {
  grep -Fq 'mktemp -d "${OUT}.tmp' "$CODEX_HOOK"
  [ "$(grep -c 'mktemp' "$CODEX_HOOK")" -eq 1 ]
  grep -Fq 'TMPDIR}/' "$CODEX_HOOK"
  grep -Fq 'rm -rf "${TMPDIR:?}"' "$CODEX_HOOK"
}

@test "guard: mktemp -d setup failure logs and exits 0 (canonical)" {
  chmod 500 "$PROJECT_DIR"
  run_with_stderr "$HOOK" '{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"failed to create temp directory"* ]] || false
  chmod 700 "$PROJECT_DIR"
}

@test "guard: mktemp -d setup failure logs and exits 0 (codex)" {
  chmod 500 "$PROJECT_DIR"
  run_with_stderr "$CODEX_HOOK" '{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"failed to create temp directory"* ]] || false
  chmod 700 "$PROJECT_DIR"
}

@test "sweep-fx1: write-failure flag prevents truncated replace" {
  # Behavioural: ENOSPC-class write failure must not replace the good log.
  # Uses trap XFSZ ignore + ulimit -f 1 so builtin writes fail with EFBIG
  # instead of killing the shell, matching the reported truncated-replace.
  local proj="$BATS_TEST_TMPDIR/save-enospc"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" config user.email test@test.invalid
  git -C "$proj" config user.name test
  printf '# Context log\n\n_GOOD_SENTINEL_\n' > "$proj/context-log.md"
  jq -nc --arg x "$(printf 'x%.0s' {1..5000})" '{type:"user",message:{role:"user",content:$x}}' > "$proj/transcript.jsonl"
  local hook
  for hook in "$HOOK" "$CODEX_HOOK"; do
    ( trap '' XFSZ; ulimit -f 1; printf '{"transcript_path":"%s"}' "$proj/transcript.jsonl" | CLAUDE_PROJECT_DIR="$proj" CODEX_PROJECT_DIR="$proj" bash "$hook" >/dev/null 2>&1 )
    grep -q '_GOOD_SENTINEL_' "$proj/context-log.md" || { echo "good log lost for $hook"; cat "$proj/context-log.md"; false; }
  done
}

# ------------------------------------------------------------------ T61
# Process-count proxy: one jq parse per input (event, todos, transcript), no
# per-entry cut, no tr, and one work-tree probe shared by both Git sections.
t61_spies() {
  local tool real
  T61_SPY="$PROJECT_DIR/.t61-spy"
  mkdir -p "$T61_SPY"
  for tool in jq git cut tr; do
    real="$(command -v "$tool")"
    printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> %q\nexec %q "$@"\n' "$tool" "$T61_SPY/calls" "$real" > "$T61_SPY/$tool"
    chmod 755 "$T61_SPY/$tool"
  done
}

t61_fixture() {
  seed_transcript "$PROJECT_DIR/t.jsonl"
  printf 'a' > "$PROJECT_DIR/a file.txt"
  printf 'b' > "$PROJECT_DIR/b.txt"
  printf 'c' > "$PROJECT_DIR/c.txt"
  mkdir -p "$PROJECT_DIR/.claude"
  printf '[{"status":"pending","content":"open item"}]' > "$PROJECT_DIR/.claude/todos.json"
  printf '/.t61-spy/\n/.trellis-t61/\n' > "$PROJECT_DIR/.gitignore"
}

@test "T61: one parse per input and one shared work-tree probe (both twins)" {
  local hook
  t61_fixture
  t61_spies
  for hook in "$HOOK" "$CODEX_HOOK"; do
    rm -f "$T61_SPY/calls" "$PROJECT_DIR/context-log.md"
    printf '{"transcript_path":"%s"}' "$PROJECT_DIR/t.jsonl" |
      TRELLIS_HOME="$PROJECT_DIR/.trellis-t61" PATH="$T61_SPY:$PATH" bash "$hook"
    grep -q 'second real user prompt' "$PROJECT_DIR/context-log.md"
    grep -q 'second assistant decision' "$PROJECT_DIR/context-log.md"
    grep -q 'a file.txt' "$PROJECT_DIR/context-log.md"
    grep -q 'open item' "$PROJECT_DIR/context-log.md"
    [ "$(grep -c '^jq ' "$T61_SPY/calls")" -eq 3 ] || { echo "$hook"; cat "$T61_SPY/calls"; false; }
    [ "$(grep -c '^git .*rev-parse --is-inside-work-tree' "$T61_SPY/calls")" -eq 1 ] || { cat "$T61_SPY/calls"; false; }
    ! grep -q '^cut \|^tr ' "$T61_SPY/calls" || { cat "$T61_SPY/calls"; false; }
  done
}

@test "T61: Codex Stop skips an unchanged transcript and rewrites after it grows; Claude PreCompact always writes" {
  local first second
  export TRELLIS_HOME="$PROJECT_DIR/.trellis-t61"
  t61_fixture
  printf '{"transcript_path":"%s"}' "$PROJECT_DIR/t.jsonl" | bash "$CODEX_HOOK"
  first="$(ls -i "$PROJECT_DIR/context-log.md")"
  sleep 1.1
  printf '{"transcript_path":"%s"}' "$PROJECT_DIR/t.jsonl" | bash "$CODEX_HOOK"
  [ "$(ls -i "$PROJECT_DIR/context-log.md")" = "$first" ] || { echo "unchanged transcript rewrote the log"; false; }
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"third prompt"}}' >> "$PROJECT_DIR/t.jsonl"
  printf '{"transcript_path":"%s"}' "$PROJECT_DIR/t.jsonl" | bash "$CODEX_HOOK"
  grep -q 'third prompt' "$PROJECT_DIR/context-log.md"
  second="$(ls -i "$PROJECT_DIR/context-log.md")"
  printf '{"transcript_path":"%s"}' "$PROJECT_DIR/t.jsonl" | bash "$HOOK"
  [ "$(ls -i "$PROJECT_DIR/context-log.md")" != "$second" ] || { echo "PreCompact skipped its write"; false; }
}

@test "T61: a linked worktree writes the log atomically at the canonical root (both twins)" {
  local hook wt
  export TRELLIS_HOME="$PROJECT_DIR/.trellis-t61"
  t61_fixture
  wt="$(mktemp -d)/linked wt"
  git -C "$PROJECT_DIR" worktree add -q -b t61-linked "$wt"
  for hook in "$HOOK" "$CODEX_HOOK"; do
    rm -f "$PROJECT_DIR/context-log.md"
    printf '{"transcript_path":"%s"}' "$PROJECT_DIR/t.jsonl" |
      CLAUDE_PROJECT_DIR="$wt" CODEX_PROJECT_DIR="$wt" bash "$hook"
    grep -q 't61-linked' "$PROJECT_DIR/context-log.md" || { cat "$PROJECT_DIR/context-log.md"; false; }
    [ ! -e "$wt/context-log.md" ]
    [ -z "$(find "$PROJECT_DIR" -maxdepth 1 -name 'context-log.md.tmp.*')" ]
  done
  git -C "$PROJECT_DIR" worktree remove --force "$wt"
}
