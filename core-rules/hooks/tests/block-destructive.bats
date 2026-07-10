#!/usr/bin/env bats
# Tests for block-destructive.sh — Claude PreToolUse hook.
# Covers Phase 1 fixes:
#   P1.1 (rm-rf rule covers absolute paths outside cwd)
#   P1.2 (DELETE-without-WHERE handles terminated SQL)
#   P1.5 (jq-missing fails closed)

load helpers

HOOK="$HOOKS_DIR/block-destructive.sh"

# Helper: run with a Bash tool envelope carrying $1 as the command.
run_with_cmd() {
  local cmd="$1"
  local input
  input="$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')"
  printf '%s' "$input" | bash "$HOOK"
}

# --- P1.1 rm-rf rule (D3 semantics: any absolute path or .. outside cwd) ---

@test "P1.1: blocks rm -rf /" {
  out="$(run_with_cmd 'rm -rf /')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf /Users/me/foo" {
  out="$(run_with_cmd 'rm -rf /Users/me/foo')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf ~/work" {
  out="$(run_with_cmd 'rm -rf ~/work')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf \$HOME/cache" {
  out="$(run_with_cmd 'rm -rf $HOME/cache')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf .." {
  out="$(run_with_cmd 'rm -rf ..')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: blocks rm -rf ../foo/bar" {
  out="$(run_with_cmd 'rm -rf ../foo/bar')"
  [[ "$out" == *deny* ]]
}

@test "P1.1: allows rm -rf . (relative cwd)" {
  out="$(run_with_cmd 'rm -rf .')"
  [[ "$out" != *deny* ]]
}

@test "P1.1: allows rm -rf ./build" {
  out="$(run_with_cmd 'rm -rf ./build')"
  [[ "$out" != *deny* ]]
}

@test "P1.1: allows rm -rf node_modules" {
  out="$(run_with_cmd 'rm -rf node_modules')"
  [[ "$out" != *deny* ]]
}

@test "P1.1: allows rm -rf dist" {
  out="$(run_with_cmd 'rm -rf dist')"
  [[ "$out" != *deny* ]]
}

# --- P1.2 DELETE-without-WHERE (covers terminated SQL) ---

@test "P1.2: blocks DELETE FROM users (no WHERE, no semicolon)" {
  out="$(run_with_cmd 'DELETE FROM users')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM users; (terminated, no WHERE)" {
  out="$(run_with_cmd 'DELETE FROM users;')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks delete from users (lowercase)" {
  out="$(run_with_cmd 'delete from users')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM with backtick-quoted table" {
  out="$(run_with_cmd 'DELETE FROM `users`')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM with double-quote-quoted table" {
  out="$(run_with_cmd 'DELETE FROM "users"')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: blocks DELETE FROM schema.users" {
  out="$(run_with_cmd 'DELETE FROM schema.users')"
  [[ "$out" == *deny* ]]
}

@test "P1.2: allows DELETE FROM users WHERE id=1;" {
  out="$(run_with_cmd 'DELETE FROM users WHERE id=1;')"
  [[ "$out" != *deny* ]]
}

@test "P1.2: allows SELECT * FROM users" {
  out="$(run_with_cmd 'SELECT * FROM users')"
  [[ "$out" != *deny* ]]
}

@test "P1.2: blocks psql -c \"DELETE FROM users;\"" {
  out="$(run_with_cmd 'psql -c "DELETE FROM users;"')"
  [[ "$out" == *deny* ]]
}

# --- codex hatch + max/ultra compound ---

@test "hatch: blocks codex bypass-sandbox + ultra" {
  out="$(run_with_cmd 'codex exec --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort="ultra" "task"')"
  [[ "$out" == *deny* ]]
}

@test "hatch: blocks codex -s danger-full-access + max" {
  out="$(run_with_cmd 'codex exec -s danger-full-access -c model_reasoning_effort=max "task"')"
  [[ "$out" == *deny* ]]
}

@test "hatch: allows sandboxed ultra (workspace-write)" {
  out="$(run_with_cmd 'codex exec --json -s workspace-write -c model_reasoning_effort="ultra" "task" </dev/null')"
  [[ "$out" != *deny* ]]
}

@test "hatch: allows bypass-sandbox at xhigh" {
  out="$(run_with_cmd 'codex exec --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort="xhigh" "task"')"
  [[ "$out" != *deny* ]]
}

# --- P1.5 jq-missing fails closed ---

@test "P1.5: jq missing without env → exit 1 + install help on stderr" {
  jq_free_path="$(make_jq_free_path)"
  run_with_stderr "$HOOK" '{}'
  rc_normal=$status
  PATH_BACKUP="$PATH"; export PATH="$jq_free_path"
  run_with_stderr "$HOOK" '{}'
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"install jq"* ]]
}

@test "P1.5: jq missing + TRELLIS_NO_JQ_DEGRADE=1 → exit 0 + breadcrumb" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"; export PATH="$jq_free_path"
  export TRELLIS_NO_JQ_DEGRADE=1
  run_with_stderr "$HOOK" '{}'
  unset TRELLIS_NO_JQ_DEGRADE
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"TRELLIS_NO_JQ_DEGRADE=1"* ]]
}
