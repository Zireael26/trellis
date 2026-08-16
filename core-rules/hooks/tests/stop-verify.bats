#!/usr/bin/env bats
# Tests for stop-verify.sh — Stop hook.
# Covers P1.3 (todo check runs before dirty-tree skip).

load helpers

HOOK="$HOOKS_DIR/stop-verify.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/stop-verify.sh"
POST_EDIT_HOOK="$HOOKS_DIR/post-edit-verify.sh"
CODEX_POST_EDIT_HOOK="$CODEX_HOOKS_DIR/post-edit-verify.sh"

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

@test "L1: nested-review bypass skips dirty-tree verification in both twins; normal calls still block" {
  seed_todos open
  make_dirty

  local candidate jq_free_path
  jq_free_path="$(make_jq_free_path)"
  for candidate in "$HOOK" "$CODEX_HOOK"; do
    run env TRELLIS_REVIEW_IN_PROGRESS=1 PATH="$jq_free_path" bash "$candidate" <<<'{}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run env -u TRELLIS_REVIEW_IN_PROGRESS bash "$candidate" <<<'{}'
    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
    printf '%s' "$output" | jq -e '.reason | startswith("TodoWrite:")' >/dev/null
  done
}

@test "M14: absolute edited Go file resolves to repo-relative package in both post-edit verifier twins" {
  local module_dir="$PROJECT_DIR/services/api"
  local source_file
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local call_log="$BATS_TEST_TMPDIR/go-calls.log"
  local input candidate

  mkdir -p "$module_dir/pkg" "$fake_bin"
  module_dir="$(cd "$module_dir" && pwd -P)"
  source_file="$module_dir/pkg/handler.go"
  printf 'module example.com/api\n\ngo 1.22\n' > "$module_dir/go.mod"
  printf 'package pkg\n' > "$source_file"
  ln -s "$(command -v jq)" "$fake_bin/jq"
  cat > "$fake_bin/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$PWD" "$*" >> "$GO_CALL_LOG"
EOF
  chmod +x "$fake_bin/go"
  input="$(jq -nc --arg path "$source_file" '{tool_input: {file_path: $path}}')"

  for candidate in "$POST_EDIT_HOOK" "$CODEX_POST_EDIT_HOOK"; do
    : > "$call_log"
    run env GO_CALL_LOG="$call_log" PATH="$fake_bin:/usr/bin:/bin" \
      bash "$candidate" <<<"$input"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -l < "$call_log" | tr -d ' ')" -eq 1 ]
    [ "$(cut -f1 "$call_log")" = "$module_dir" ]
    [ "$(cut -f2- "$call_log")" = "vet ./pkg/..." ]
    # Counted, not `! grep`: a leading `!` never trips `set -e`, so the bare
    # form could not have failed on a leaked `.//` or absolute path.
    [ "$(grep -cF './/' "$call_log")" -eq 0 ] || { cat "$call_log"; false; }
    [ "$(cut -f2- "$call_log" | grep -cF "$PROJECT_DIR")" -eq 0 ] || { cat "$call_log"; false; }
  done
}

@test "Python checks prefer the project venv in both stop-hook twins" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local local_log="$BATS_TEST_TMPDIR/local-tools.log"
  local global_log="$BATS_TEST_TMPDIR/global-tools.log"
  local candidate tool

  seed_todos completed
  mkdir -p "$PROJECT_DIR/.venv/bin" "$fake_bin"
  printf '[tool.mypy]\n' > "$PROJECT_DIR/pyproject.toml"
  printf 'value: int = 1\n' > "$PROJECT_DIR/scratch.py"

  for tool in mypy pytest; do
    cat > "$PROJECT_DIR/.venv/bin/$tool" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$LOCAL_TOOL_LOG"
EOF
    cat > "$fake_bin/$tool" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$GLOBAL_TOOL_LOG"
exit 99
EOF
    chmod +x "$PROJECT_DIR/.venv/bin/$tool" "$fake_bin/$tool"
  done

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    : > "$local_log"
    : > "$global_log"
    run env PROCESS_GATE_NO_RECEIPTS=1 LOCAL_TOOL_LOG="$local_log" \
      GLOBAL_TOOL_LOG="$global_log" PATH="$fake_bin:/usr/bin:/bin" \
      bash "$candidate" <<<'{}'
    [ "$status" -eq 0 ]
    [ "$(cat "$local_log")" = $'mypy .\npytest --tb=short -q' ]
    [ ! -s "$global_log" ]
  done
}


@test "mixed Python and Rust manifests fall through when pytest is unavailable" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local cargo_log="$BATS_TEST_TMPDIR/cargo.log"
  local candidate

  seed_todos completed
  mkdir -p "$fake_bin"
  printf '[build-system]\nrequires = []\n' > "$PROJECT_DIR/pyproject.toml"
  printf '[package]\nname = "mixed"\nversion = "0.1.0"\n' > "$PROJECT_DIR/Cargo.toml"
  cat > "$fake_bin/cargo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CARGO_LOG"
EOF
  chmod +x "$fake_bin/cargo"

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    : > "$cargo_log"
    run env PROCESS_GATE_NO_RECEIPTS=1 CARGO_LOG="$cargo_log" \
      PATH="$fake_bin:/usr/bin:/bin" bash "$candidate" <<<'{}'
    [ "$status" -eq 0 ]
    grep -Fx 'check' "$cargo_log"
    grep -Fx 'test --quiet' "$cargo_log"
  done
}
