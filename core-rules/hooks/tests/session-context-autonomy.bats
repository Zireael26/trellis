#!/usr/bin/env bats
# Tests for session-context.sh autonomy + decisions injection.

load helpers

HOOK="$HOOKS_DIR/session-context.sh"

setup() {
  setup_project_dir
  # Prevent TRELLIS_ROOT from leaking into tests and skewing the fleet default.
  unset TRELLIS_ROOT
}

teardown() {
  teardown_project_dir
}

@test "autonomy: no config → defaults to L3 (Standard)" {
  cd "$PROJECT_DIR"
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "Level: L3 (Standard)"
}

@test "autonomy: project config autonomy=4 → reported as L4 (Initiative)" {
  cd "$PROJECT_DIR"
  cat > "$PROJECT_DIR/.trellis.config.json" <<'EOF'
{"trellis_root":"/x","projects_root":"/y","user_home":"/z","maintainer_name":"a","github_user":"b","harnesses":["claude"],"autonomy":4}
EOF
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "Level: L4 (Initiative)"
}

@test "autonomy: session-autonomy file wins over project config" {
  cd "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/.claude"
  cat > "$PROJECT_DIR/.trellis.config.json" <<'EOF'
{"trellis_root":"/x","projects_root":"/y","user_home":"/z","maintainer_name":"a","github_user":"b","harnesses":["claude"],"autonomy":2}
EOF
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "Level: L5 (Autonomous)"
}

@test "decisions: L4 + decisions-log.md → recent block appears in context" {
  cd "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/.claude"
  printf '4\n' > "$PROJECT_DIR/.claude/session-autonomy"
  cat > "$PROJECT_DIR/decisions-log.md" <<'EOF'
# Decision log

- 2026-05-20T12:00:00Z [L4] [interpretation] decided X. Reasoning: Y. Alternatives: Z.
- 2026-05-20T12:05:00Z [L4] [pattern] picked A over B. Reasoning: C. Alternatives: D.
EOF
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "Recent decisions (L4/L5)"
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "decided X"
}

@test "decisions: L3 + decisions-log.md → recent block does NOT appear" {
  cd "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/.claude"
  printf '3\n' > "$PROJECT_DIR/.claude/session-autonomy"
  cat > "$PROJECT_DIR/decisions-log.md" <<'EOF'
- 2026-05-20T12:00:00Z [L3] [interpretation] should not appear
EOF
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ! (echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "Recent decisions")
}

@test "autonomy: invalid session-autonomy value falls back to default" {
  cd "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/.claude"
  printf '99\n' > "$PROJECT_DIR/.claude/session-autonomy"
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "Level: L3 (Standard)"
}
