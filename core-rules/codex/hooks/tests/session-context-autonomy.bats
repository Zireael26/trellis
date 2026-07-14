#!/usr/bin/env bats
# Focused Codex SessionStart tests for canonical autonomy resolution and
# recent-decision evidence.

HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/session-context.sh"

setup() {
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/project.XXXXXX")"
  TRELLIS_FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/trellis.XXXXXX")"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git -c user.name=Test -c user.email=test@example.invalid \
      commit --allow-empty -q -m init
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR TRELLIS_ROOT
}

teardown() {
  rm -rf "$PROJECT_DIR" "$TRELLIS_FIXTURE"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR TRELLIS_ROOT
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

@test "autonomy defaults to L3 when no config exists" {
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L3 (Standard)'
}

@test "preset default overrides fleet default when project override is absent" {
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

@test "session override wins the pick phase and lowest preset ceiling clamps it" {
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

@test "L4 session injects only the last ten decisions" {
  mkdir -p "$PROJECT_DIR/.claude"
  printf '4\n' > "$PROJECT_DIR/.claude/session-autonomy"
  i=1
  while [ "$i" -le 12 ]; do
    printf -- '- 2026-07-14T00:00:%02dZ [L4] [interpretation] decision-%02d. Reasoning: test. Alternatives considered: none.\n' "$i" "$i" \
      >> "$PROJECT_DIR/decisions-log.md"
    i=$((i + 1))
  done

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Recent decisions (L4/L5)'
  additional_context | grep -q 'decision-03'
  additional_context | grep -q 'decision-12'
  ! additional_context | grep -q 'decision-02'
}
