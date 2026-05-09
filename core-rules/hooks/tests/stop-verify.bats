#!/usr/bin/env bats
# Tests for stop-verify.sh — Stop hook.
# Covers P1.3 (todo check runs before dirty-tree skip).

load helpers

HOOK="$HOOKS_DIR/stop-verify.sh"

setup() {
  setup_project_dir
}

teardown() {
  teardown_project_dir
}

# Write a todos.json with given status entries.
seed_todos() {
  local mode="$1"
  mkdir -p "$PROJECT_DIR/.claude"
  case "$mode" in
    open)
      cat > "$PROJECT_DIR/.claude/todos.json" <<'EOF'
[{"status":"in_progress","content":"do thing"},{"status":"pending","content":"do other"}]
EOF
      ;;
    completed)
      cat > "$PROJECT_DIR/.claude/todos.json" <<'EOF'
[{"status":"completed","content":"done"}]
EOF
      ;;
    none)
      rm -f "$PROJECT_DIR/.claude/todos.json"
      ;;
  esac
}

make_dirty() {
  echo "x" > "$PROJECT_DIR/scratch.txt"
}

make_clean() {
  rm -f "$PROJECT_DIR/scratch.txt"
}

@test "P1.3: clean tree + open todo blocks (rc=2)" {
  seed_todos open
  make_clean
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$output" == *block* ]]
}

@test "P1.3: clean tree + no todos passes (rc=0)" {
  seed_todos none
  make_clean
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
}

@test "P1.3: dirty tree + open todo blocks (rc=2)" {
  seed_todos open
  make_dirty
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$output" == *block* ]]
}

@test "P1.3: dirty tree + all-completed passes (rc=0; no toolchains)" {
  seed_todos completed
  make_dirty
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
}

@test "P1.3: clean tree + all-completed passes (rc=0)" {
  seed_todos completed
  make_clean
  run bash "$HOOK" <<<'{}'
  [ "$status" -eq 0 ]
}

@test "P1.3: stop_hook_active short-circuits (no todo check)" {
  seed_todos open
  make_dirty
  run bash "$HOOK" <<<'{"stop_hook_active": true}'
  [ "$status" -eq 0 ]
}
