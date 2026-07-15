#!/usr/bin/env bats
# Tests for session-context.sh autonomy + decisions injection.

load helpers

HOOK="$HOOKS_DIR/session-context.sh"

setup() {
  setup_project_dir
  TRELLIS_FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/trellis.XXXXXX")"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets"
  # Prevent TRELLIS_ROOT from leaking into tests and skewing the fleet default.
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
}

teardown() {
  teardown_project_dir
  rm -rf "$TRELLIS_FIXTURE"
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
}

write_fleet_config() {
  local level="$1"
  jq -n --argjson level "$level" '{autonomy_default: $level}' \
    > "$TRELLIS_FIXTURE/trellis.config.json"
}

write_project_config() {
  local autonomy_json="$1" presets_json="$2"
  jq -n \
    --arg root "$TRELLIS_FIXTURE" \
    --argjson autonomy "$autonomy_json" \
    --argjson presets "$presets_json" \
    '{trellis_root: $root, presets: $presets}
     + (if $autonomy == null then {} else {autonomy: $autonomy} end)' \
    > "$PROJECT_DIR/.trellis.config.json"
}

additional_context() {
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'
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

@test "autonomy: preset default overrides fleet default when project override is absent" {
  write_fleet_config 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 4
---
EOF
  write_project_config null '["experimental"]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L4 (Initiative)'
}

@test "autonomy: project override takes precedence over preset default" {
  write_fleet_config 1
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 4
---
EOF
  write_project_config 3 '["experimental"]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L3 (Standard)'
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

@test "autonomy: session L5 is clamped to L2 by the lowest active preset ceiling" {
  write_fleet_config 3
  cat > "$TRELLIS_FIXTURE/core-rules/presets/loose.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 4
---
EOF
  cat > "$TRELLIS_FIXTURE/core-rules/presets/strict.md" <<'EOF'
---
autonomy_ceiling: 2
---
EOF
  write_project_config 1 '["loose","strict"]'
  mkdir -p "$PROJECT_DIR/.claude"
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
  additional_context | grep -q 'Requested autonomy L5, clamped to L2 (preset strict).'
}

@test "autonomy: L5 to L2 clamp warning survives long-context cap in final JSON" {
  write_fleet_config 3
  cat > "$TRELLIS_FIXTURE/core-rules/presets/strict.md" <<'EOF'
---
autonomy_ceiling: 2
---
EOF
  write_project_config 1 '["strict"]'
  mkdir -p "$PROJECT_DIR/.claude"
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"

  long_subject=$(printf '%*s' 220 '' | tr ' ' x)
  for commit_number in 1 2 3 4 5; do
    git -C "$PROJECT_DIR" commit --allow-empty -q \
      -m "${long_subject}-${commit_number}"
  done
  printf '%*s' 1200 '' | tr ' ' c > "$PROJECT_DIR/context-log.md"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .hookSpecificOutput.additionalContext
    | contains("Requested autonomy L5, clamped to L2 (preset strict).")
  ' >/dev/null
  context_bytes=$(printf '%s' "$output" \
    | jq -rj '.hookSpecificOutput.additionalContext' \
    | wc -c \
    | tr -d '[:space:]')
  [ "$context_bytes" -le 2000 ]
  additional_context | grep -q '\.\.\.\[trimmed\]'
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
