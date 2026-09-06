#!/usr/bin/env bats
# SessionStart (source=compact) task-context advisory on both harnesses.
#
# The existing context-log recovery is unchanged; the new requirement is that
# compaction carries the bounded task summary EVEN WHEN context-log.md is
# absent, which previously produced no event at all. Fixtures come from the
# real accepted task-state primitive; assertions read the real envelope.

CLAUDE_HOOKS="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
CODEX_HOOKS="$(cd "$BATS_TEST_DIRNAME/../../codex/hooks" && pwd -P)"
CLAUDE_HOOK="$CLAUDE_HOOKS/post-compact-context.sh"
CODEX_HOOK="$CODEX_HOOKS/post-compact-context.sh"

setup() {
  WORK="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$WORK/project"
  PROJECT_DIR="$(cd "$WORK/project" && pwd -P)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -q -m init
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
}

teardown() {
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
}

list_tasks() {
  cat > "$PROJECT_DIR/tasks.md" <<'EOF'
# Tasks

- [x] T1 first done
- [ ] T2 open
- [ ] T3 open
EOF
}

capture() {
  python3 "$CLAUDE_HOOKS/lib/task-state.py" capture \
    --cwd "$PROJECT_DIR" --tasks tasks.md --harness codex >/dev/null
}

deploy() {  # <hooks-dir> <tag>
  local src="$1" dst="$WORK/deploy-$2"
  mkdir -p "$dst/lib"
  cp "$src/post-compact-context.sh" "$dst/post-compact-context.sh"
  cp "$src"/lib/*.sh "$dst/lib/" 2>/dev/null || true
  cp "$src"/lib/*.py "$dst/lib/" 2>/dev/null || true
  # Match the manifest's shared-library entries in a mapped hook installation.
  cp "$CLAUDE_HOOKS/lib/task-context.sh" "$CLAUDE_HOOKS/lib/task-state.py" "$dst/lib/"
  printf '%s' "$dst/post-compact-context.sh"
}

ctx() { printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'; }
event_name() { printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName'; }

@test "compact: Claude keeps context-log recovery AND adds the task summary" {
  list_tasks
  capture
  printf '# Context log\nprevious-session-marker\n' > "$PROJECT_DIR/context-log.md"
  run bash "$CLAUDE_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ "$(event_name)" = "SessionStart" ]
  ctx | grep -q 'previous-session-marker'
  ctx | grep -q -- '--- Task context (captured task documents; canonical documents authoritative) ---'
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=1 pending=2'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=1 pending=2$'
}

@test "compact: Claude still emits the task summary when context-log.md is absent" {
  list_tasks
  capture
  [ ! -f "$PROJECT_DIR/context-log.md" ]
  run bash "$CLAUDE_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(event_name)" = "SessionStart" ]
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=1 pending=2'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=1 pending=2$'
}

@test "compact: Codex still emits the task summary when context-log.md is absent" {
  list_tasks
  capture
  [ ! -f "$PROJECT_DIR/context-log.md" ]
  run bash "$CODEX_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(event_name)" = "SessionStart" ]
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=1 pending=2'
}

@test "compact: Codex keeps context-log recovery AND adds the task summary" {
  list_tasks
  capture
  printf '# Context log\ncodex-previous-session-marker\n' > "$PROJECT_DIR/context-log.md"
  run bash "$CODEX_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'codex-previous-session-marker'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=1 pending=2$'
}

@test "compact: an empty context-log.md does not suppress the task summary" {
  list_tasks
  capture
  : > "$PROJECT_DIR/context-log.md"
  run bash "$CLAUDE_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=1 pending=2'
}

@test "compact: an unseeded worktree reports no_records, never empty success" {
  run bash "$CODEX_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ctx | grep -q 'task-context v1: status=no_records documents=0 foreign_records=0 checked=0 pending=0'
}

@test "compact: a missing helper library yields explicit bounded unavailable advice" {
  local hook
  list_tasks
  capture
  hook="$(deploy "$CLAUDE_HOOKS" nolib)"
  rm -f "$(dirname "$hook")/lib/task-context.sh"
  run bash "$hook" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=unavailable reason=library_unavailable documents=0 foreign_records=0 checked=0 pending=0'
  ctx | grep -q 'Canonical task documents are authoritative'
}

@test "source guard: a startup event produces no post-compact output on either harness" {
  list_tasks
  capture
  printf 'log\n' > "$PROJECT_DIR/context-log.md"
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$CODEX_HOOK" <<<'{"source":"resume"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
