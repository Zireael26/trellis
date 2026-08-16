#!/usr/bin/env bats
# Tests for session-context.sh autonomy + decisions injection.

load helpers

HOOK="$HOOKS_DIR/session-context.sh"
AUTONOMY_HELPER="$HOOKS_DIR/lib/autonomy.sh"
CODEX_AUTONOMY_HELPER="$(dirname "$HOOKS_DIR")/codex/hooks/lib/autonomy.sh"

setup() {
  setup_project_dir
  TRELLIS_FIXTURE="$(mktemp -d "$BATS_TEST_TMPDIR/trellis.XXXXXX")"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  unset CODEX_PROJECT_DIR
}

teardown() {
  teardown_project_dir
  rm -rf "$TRELLIS_FIXTURE"
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
}

write_runtime_config() {
  local level="$1"
  jq -n --argjson level "$level" '{autonomy_default: $level}' \
    > "$TRELLIS_FIXTURE/trellis.config.json"
}

write_project_config() {
  local file="$1" autonomy_json="$2" presets_json="$3"
  jq -n \
    --argjson autonomy "$autonomy_json" \
    --argjson presets "$presets_json" \
    '{
      schema_version: 1,
      project_id: "fixture-project"
    }
    + (if $autonomy == null then {} else {autonomy: $autonomy} end)
    + (if $presets == null then {} else {presets: $presets} end)' \
    > "$file"
}

write_canonical_project_config() {
  write_project_config "$PROJECT_DIR/.trellis.json" "$1" "$2"
}

write_legacy_project_config() {
  write_project_config "$PROJECT_DIR/.trellis.config.json" "$1" "$2"
}

additional_context() {
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

resolver_globals() {
  local helper="$1"
  bash -c '
    source "$1"
    _se_resolve_autonomy "$2"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$AUTONOMY_LEVEL" "$AUTONOMY_NAME" "$AUTONOMY_REQUESTED_LEVEL" \
      "$AUTONOMY_CEILING" "$AUTONOMY_CLAMPED" "$AUTONOMY_LIMITING_PRESET"
  ' bash "$helper" "$PROJECT_DIR"
}

@test "autonomy: no policy defaults to L3 (Standard)" {
  cd "$PROJECT_DIR"
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q "Level: L3 (Standard)"
}

@test "autonomy: immutable runtime default overrides the built-in default" {
  write_runtime_config 4

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q "Level: L4 (Initiative)"
}

@test "autonomy: canonical project policy overrides legacy project policy" {
  write_runtime_config 1
  write_legacy_project_config 2 '[]'
  write_canonical_project_config 4 '[]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q "Level: L4 (Initiative)"
}

@test "autonomy: legacy project policy is used without a canonical manifest" {
  write_runtime_config 5
  write_legacy_project_config 2 '[]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q "Level: L2 (Cautious)"
}

@test "autonomy: first active runtime preset default overrides the fleet default" {
  write_runtime_config 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 4
---
EOF
  write_canonical_project_config null '["experimental"]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L4 (Initiative)'
}

@test "autonomy: lowest active runtime preset ceiling clamps the session override" {
  write_runtime_config 3
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
  write_canonical_project_config 1 '["loose","strict"]'
  mkdir -p "$PROJECT_DIR/.claude"
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
  additional_context | grep -q 'Requested autonomy L5, clamped to L2 (preset strict).'
}

@test "autonomy: project override wins before the session override" {
  write_runtime_config 1
  write_canonical_project_config 2 '[]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'

  mkdir -p "$PROJECT_DIR/.claude"
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L5 (Autonomous)'
}

@test "autonomy: malformed canonical override does not fall through to legacy or preset" {
  write_runtime_config 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_default: 5
---
EOF
  write_legacy_project_config 4 '[]'
  write_canonical_project_config 9 '["experimental"]'

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
}

@test "autonomy: canonical null override does not fall through to legacy policy" {
  write_runtime_config 2
  write_legacy_project_config 4 '[]'
  printf '%s\n' \
    '{"schema_version":1,"project_id":"fixture-project","autonomy":null}' \
    > "$PROJECT_DIR/.trellis.json"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
}

@test "autonomy: canonical null presets do not fall through to legacy presets" {
  write_runtime_config 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_default: 5
---
EOF
  write_legacy_project_config null '["experimental"]'
  printf '%s\n' \
    '{"schema_version":1,"project_id":"fixture-project","presets":null}' \
    > "$PROJECT_DIR/.trellis.json"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
}

@test "autonomy: non-object canonical policy does not fall through to legacy autonomy" {
  write_runtime_config 2
  write_legacy_project_config 4 '[]'
  printf '%s\n' '[]' > "$PROJECT_DIR/.trellis.json"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
}

@test "autonomy: non-object canonical policy does not fall through to legacy presets" {
  write_runtime_config 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_default: 5
---
EOF
  write_legacy_project_config null '["experimental"]'
  printf '%s\n' '"text"' > "$PROJECT_DIR/.trellis.json"

  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q 'Level: L2 (Cautious)'
}

@test "autonomy: Claude and Codex mirrors are byte and behavior identical" {
  write_runtime_config 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/strict.md" <<'EOF'
---
autonomy_ceiling: 2
---
EOF
  write_canonical_project_config 1 '["strict"]'
  mkdir -p "$PROJECT_DIR/.claude"
  printf '5\n' > "$PROJECT_DIR/.claude/session-autonomy"

  run cmp -s "$AUTONOMY_HELPER" "$CODEX_AUTONOMY_HELPER"
  [ "$status" -eq 0 ]
  [ "$(resolver_globals "$AUTONOMY_HELPER")" = "$(resolver_globals "$CODEX_AUTONOMY_HELPER")" ]
}

@test "autonomy: L5 to L2 clamp warning survives long-context cap in final JSON" {
  write_runtime_config 3
  cat > "$TRELLIS_FIXTURE/core-rules/presets/strict.md" <<'EOF'
---
autonomy_ceiling: 2
---
EOF
  write_canonical_project_config 1 '["strict"]'
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
  additional_context | grep -q "Recent decisions (L4/L5)"
  additional_context | grep -q "decided X"
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
  # Counted zero, not a leading `!`: the negation is enforced here only because
  # it happens to be the LAST statement, so any line appended below it would
  # silently make the absence claim vacuous.
  [ "$(additional_context | grep -c "Recent decisions")" -eq 0 ] || { additional_context; false; }
}

@test "autonomy: invalid session-autonomy value falls back to configured policy" {
  write_runtime_config 4
  mkdir -p "$PROJECT_DIR/.claude"
  printf '99\n' > "$PROJECT_DIR/.claude/session-autonomy"
  run bash "$HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  additional_context | grep -q "Level: L4 (Initiative)"
}
