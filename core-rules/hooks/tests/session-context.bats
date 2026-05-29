#!/usr/bin/env bats
# Tests for session-context.sh — SessionStart (startup|resume) hook.
# Covers MEDIUM audit §2.1 fixes:
#   - gotchas detector anchors to headings + status fields (no free-text false-positives)
#   - context-log read window large enough to surface meaningful content from
#     a typical 6-10K log written by save-context-log.sh

load helpers

HOOK="$HOOKS_DIR/session-context.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/session-context.sh"

setup() {
  setup_project_dir
}

teardown() {
  teardown_project_dir
}

# Extract additionalContext from the hook's JSON output. Claude wraps it in
# hookSpecificOutput; Codex emits it flat. Try Claude shape first, fall back.
extract_ctx() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // .additionalContext // ""'
}

run_hook() {
  local hook="$1"
  printf '%s' '{"source":"startup"}' | bash "$hook"
}

# --- Gotchas detector: heading match ---

@test "M2.1: gotchas detector matches a heading line (## Unresolved)" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Unresolved
Body of the entry.
EOF
  out="$(run_hook "$HOOK")"
  ctx="$(extract_ctx "$out")"
  [[ "$ctx" == *"Unresolved gotchas"* ]]
  [[ "$ctx" == *"## Unresolved"* ]]
}

@test "M2.1: gotchas detector matches a deeper heading (### Unresolved gotchas)" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

### Unresolved gotchas
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"### Unresolved gotchas"* ]]
}

@test "M2.1: gotchas detector matches a dated heading containing UNRESOLVED" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## 2026-05-11 — UNRESOLVED: pre-push gate missing
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"UNRESOLVED: pre-push gate missing"* ]]
}

# --- Gotchas detector: status field match ---

@test "M2.1: gotchas detector matches a Status: unresolved field" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

Status: unresolved
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"Status: unresolved"* ]]
}

@test "M2.1: gotchas detector matches a **unresolved** status tag" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

**unresolved**
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"**unresolved**"* ]]
}

# --- Gotchas detector: free-text mentions do NOT match ---

@test "M2.1: gotchas detector ignores free-text 'was unresolved on …'" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Resolved item
This issue is now resolved (was unresolved on 2026-04-01).
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  # Section header should not appear at all because no anchored match exists.
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

@test "M2.1: gotchas detector ignores body text 'mentions unresolved status'" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Resolved item
Some body text mentions unresolved status in passing.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

@test "M2.1: gotchas detector ignores **Fix.** UNRESOLVED. (different bold label)" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Some entry
**Fix.** UNRESOLVED.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

# --- Codex parity: same gotchas regex must apply ---

@test "M2.1: Codex copy also ignores free-text mentions" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Resolved item
This issue is now resolved (was unresolved on 2026-04-01).
EOF
  ctx="$(extract_ctx "$(run_hook "$CODEX_HOOK")")"
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

@test "M2.1: Codex copy matches the same heading shape" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Unresolved
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$CODEX_HOOK")")"
  [[ "$ctx" == *"## Unresolved"* ]]
}

# --- Context-log injection size sanity ---

@test "M2.1: 5K context-log → injection contains >1000 chars of log content" {
  # Build a 5K context-log.md whose body is line-numbered so we can prove
  # the new 1200-char window surfaces meaningful content past the header.
  {
    printf '# Context log\n_Saved: 2026-05-20T00:00:00Z_\n\n'
    i=0
    while [ "$i" -lt 100 ]; do
      printf 'line %03d body content for read-window verification\n' "$i"
      i=$((i + 1))
    done
  } > "$PROJECT_DIR/context-log.md"
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"context-log.md (previous session)"* ]]
  # More than 1000 chars of log body must reach the injection. The pre-fix
  # 800-char window would fail this; the new 1200-char window passes.
  log_len=$(printf '%s' "$ctx" | awk '/context-log.md \(previous session\)/{flag=1;next} /Unresolved gotchas/{flag=0} flag' | wc -c)
  [ "$log_len" -gt 1000 ]
}
