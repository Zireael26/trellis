#!/usr/bin/env bats
# SessionStart (startup|resume) task-context advisory + reserved-cap parity.
#
# Behaviour-based: every fixture is produced by the REAL accepted task-state
# primitive (`task-state.py capture`) in a real Git worktree, and every
# assertion reads the actual lifecycle event envelope the hook emits. The
# Claude and Codex hooks are exercised through the same cases because the
# reserved 2000-byte cap is required parity, not a Claude-only property.

CLAUDE_HOOKS="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
CODEX_HOOKS="$(cd "$BATS_TEST_DIRNAME/../../codex/hooks" && pwd -P)"
CLAUDE_HOOK="$CLAUDE_HOOKS/session-context.sh"
CODEX_HOOK="$CODEX_HOOKS/session-context.sh"

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
  TRELLIS_FIXTURE="$WORK/trellis"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets" "$WORK/trellis-home"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  export TRELLIS_HOME="$WORK/trellis-home"
}

teardown() {
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR TRELLIS_ROOT TRELLIS_HOME
}

# --- fixtures -------------------------------------------------------------

list_tasks() {
  cat > "$1/tasks.md" <<'EOF'
# Tasks

- [x] T1 first done
- [x] T2 second done
- [ ] T3 open
- [ ] T4 open
- [ ] T5 open
EOF
}

table_tasks() {
  cat > "$1/tasks.md" <<'EOF'
# Tasks

| ID | Task | Done |
| --- | --- | --- |
| T1 | first | [x] |
| T2 | second | [ ] |
| T3 | third | [ ] |
EOF
}

capture() {  # <cwd> [relative-doc]
  python3 "$CLAUDE_HOOKS/lib/task-state.py" capture \
    --cwd "$1" --tasks "${2:-tasks.md}" --harness claude >/dev/null
}

# Deploy a hook into its own installed layout so the sibling lib set can be
# degraded without touching the frozen source tree.
deploy() {  # <hooks-dir> <hook-name> <tag>
  local src="$1" name="$2" dst="$WORK/deploy-$3"
  mkdir -p "$dst/lib"
  cp "$src/$name" "$dst/$name"
  cp "$src"/lib/*.sh "$dst/lib/" 2>/dev/null || true
  cp "$src"/lib/*.py "$dst/lib/" 2>/dev/null || true
  # Match the manifest's shared-library entries in a mapped hook installation.
  cp "$CLAUDE_HOOKS/lib/task-context.sh" "$CLAUDE_HOOKS/lib/task-state.py" "$dst/lib/"
  printf '%s' "$dst/$name"
}

python_free_path() {
  local out="$WORK/nopython" src cmd
  mkdir -p "$out"
  for cmd in bash sh git jq env test [ echo printf grep sed awk cat head tail \
             mktemp date basename dirname readlink id stat rm mv cp mkdir tr \
             cut sort uniq wc od cmp find xargs chmod ls touch; do
    src="$(command -v "$cmd" 2>/dev/null)"
    case "$src" in /*) ln -sf "$src" "$out/$cmd" ;; esac
  done
  printf '%s' "$out"
}

ctx() { printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'; }
ctx_bytes() {
  printf '%s' "$output" | jq -rj '.hookSpecificOutput.additionalContext' \
    | LC_ALL=C wc -c | tr -d '[:space:]'
}
event_name() { printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName'; }

big_git_history() {
  local subject
  subject=$(printf '%*s' 220 '' | tr ' ' x)
  for n in 1 2 3 4 5; do
    git -C "$PROJECT_DIR" -c user.name=Test -c user.email=test@example.invalid \
      commit --allow-empty -q -m "${subject}-${n}"
  done
}

autonomy_l4_with_decisions() {
  mkdir -p "$PROJECT_DIR/.claude"
  printf '4\n' > "$PROJECT_DIR/.claude/session-autonomy"
  cat > "$PROJECT_DIR/decisions-log.md" <<'EOF'
- 2026-09-06T00:00:00Z [L4] [interpretation] decided X. Reasoning: Y. Alternatives: Z.
EOF
}

# --- current records ------------------------------------------------------

@test "startup: Claude reports current list-task counts in the SessionStart envelope" {
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$(event_name)" = "SessionStart" ]
  ctx | grep -q -- '--- Task context (captured task documents; canonical documents authoritative) ---'
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=2 pending=3'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=2 pending=3$'
  ctx | grep -q 'Canonical task documents are authoritative'
  # Raw task text is never replayed into context.
  [ "$(ctx | grep -c 'T3 open')" -eq 0 ]
}

@test "resume: Codex reports current table-task counts in the SessionStart envelope" {
  table_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  run bash "$CODEX_HOOK" <<<'{"source":"resume"}'
  [ "$status" -eq 0 ]
  [ "$(event_name)" = "SessionStart" ]
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=1 pending=2'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=1 pending=2$'
}

@test "no records: an unseeded worktree reports no_records, never empty success" {
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=no_records documents=0 foreign_records=0 checked=0 pending=0'
}

@test "stale: a drifted source is reported stale and contributes no counts" {
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  printf -- '- [x] T6 added after capture\n' >> "$PROJECT_DIR/tasks.md"
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=0 pending=0'
  ctx | grep -qE '^- "?tasks\.md"?: stale$'
}

@test "missing: a deleted source is reported missing and contributes no counts" {
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  rm -f "$PROJECT_DIR/tasks.md"
  run bash "$CODEX_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=0 pending=0'
  ctx | grep -qE '^- "?tasks\.md"?: missing$'
}

@test "foreign only: another worktree's record is counted, never replayed as tasks" {
  local other="$WORK/other"
  git -C "$PROJECT_DIR" -c user.name=Test -c user.email=test@example.invalid \
    worktree add -q -b other "$other"
  other="$(cd "$other" && pwd -P)"
  list_tasks "$other"
  capture "$other"
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=no_records documents=0 foreign_records=1 checked=0 pending=0'
  [ "$(ctx | grep -c 'current checked=')" -eq 0 ]
}

# --- missing dependencies -------------------------------------------------

@test "missing helper library yields explicit bounded unavailable advice" {
  local hook
  hook="$(deploy "$CLAUDE_HOOKS" session-context.sh nolib)"
  rm -f "$(dirname "$hook")/lib/task-context.sh"
  run bash "$hook" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=unavailable reason=library_unavailable documents=0 foreign_records=0 checked=0 pending=0'
  ctx | grep -q 'Canonical task documents are authoritative'
}

@test "missing python3 yields explicit bounded unavailable advice" {
  local hook path
  hook="$(deploy "$CODEX_HOOKS" session-context.sh nopy)"
  path="$(python_free_path)"
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  run env PATH="$path" bash "$hook" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=unavailable reason=python_unavailable'
  [ "$(ctx | grep -c 'status=available')" -eq 0 ]
}

@test "truncated protocol output yields explicit bounded unavailable advice" {
  local hook
  hook="$(deploy "$CLAUDE_HOOKS" session-context.sh truncated)"
  cat > "$(dirname "$hook")/lib/task-state.py" <<'EOF'
import sys
sys.stdout.write('{"status":"available","documents":[{"stat')
EOF
  run bash "$hook" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=unavailable reason=malformed_protocol'
}

@test "protocol with a missing required key yields explicit bounded unavailable advice" {
  local hook
  hook="$(deploy "$CODEX_HOOKS" session-context.sh malformed)"
  cat > "$(dirname "$hook")/lib/task-state.py" <<'EOF'
import sys
sys.stdout.write('{"status":"available"}\n')
EOF
  run bash "$hook" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'task-context v1: status=unavailable reason=malformed_protocol'
}

# --- reserved cap ---------------------------------------------------------

@test "cap: Claude keeps autonomy L4 AND the whole task summary under 2000 bytes" {
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  autonomy_l4_with_decisions
  big_git_history
  printf '%*s' 1300 '' | tr ' ' c > "$PROJECT_DIR/context-log.md"
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$(ctx_bytes)" -le 2000 ]
  ctx | grep -q '\.\.\.\[trimmed\]'
  ctx | grep -q 'Level: L4 (Initiative)'
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=2 pending=3'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=2 pending=3$'
}

@test "cap: Codex keeps autonomy L4 AND the whole task summary under 2000 bytes" {
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  autonomy_l4_with_decisions
  big_git_history
  printf '%*s' 1300 '' | tr ' ' c > "$PROJECT_DIR/context-log.md"
  run bash "$CODEX_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$(ctx_bytes)" -le 2000 ]
  ctx | grep -q '\.\.\.\[trimmed\]'
  ctx | grep -q 'Level: L4 (Initiative)'
  ctx | grep -q 'task-context v1: status=available documents=1 foreign_records=0 checked=2 pending=3'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=2 pending=3$'
}

@test "cap: a large non-ASCII context is cut on a UTF-8 character boundary" {
  local replacement
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  autonomy_l4_with_decisions
  big_git_history
  {
    printf 'x'
    n=0
    while [ "$n" -lt 2000 ]; do printf '\342\200\246'; n=$((n + 1)); done
  } > "$PROJECT_DIR/context-log.md"
  run bash "$CLAUDE_HOOK" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$(ctx_bytes)" -le 2000 ]
  replacement="$(printf '\357\277\275')"
  [[ "$(ctx)" != *"$replacement"* ]] || { ctx | od -c | tail -20; false; }
  ctx | grep -q 'Level: L4 (Initiative)'
  ctx | grep -qE '^- "?tasks\.md"?: current checked=2 pending=3$'
}

@test "cap: Codex cuts a large non-ASCII context on a UTF-8 character boundary" {
  local replacement
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  autonomy_l4_with_decisions
  big_git_history
  {
    printf 'x'
    n=0
    while [ "$n" -lt 2000 ]; do printf '\342\200\246'; n=$((n + 1)); done
  } > "$PROJECT_DIR/context-log.md"
  run bash "$CODEX_HOOK" <<<'{"source":"resume"}'
  [ "$status" -eq 0 ]
  [ "$(ctx_bytes)" -le 2000 ]
  replacement="$(printf '\357\277\275')"
  [[ "$(ctx)" != *"$replacement"* ]] || { ctx | od -c | tail -20; false; }
  ctx | grep -qE '^- "?tasks\.md"?: current checked=2 pending=3$'
}

@test "source guard: compact is not handled by session-context on either harness" {
  list_tasks "$PROJECT_DIR"
  capture "$PROJECT_DIR"
  run bash "$CLAUDE_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$CODEX_HOOK" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
