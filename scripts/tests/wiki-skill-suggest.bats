#!/usr/bin/env bats
# Hermetic coverage for the paired WikiSkill advisory hooks and their runtime
# boundary. Every mutable project, Git repository, and would-be global path lives
# below BATS_TEST_TMPDIR; the canonical hook/template bytes are read in place.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CLAUDE_HOOK="$REPO_ROOT/core-rules/hooks/wiki-skill-suggest.sh"
CODEX_HOOK="$REPO_ROOT/core-rules/codex/hooks/wiki-skill-suggest.sh"
CLAUDE_SESSION_HOOK="$REPO_ROOT/core-rules/hooks/session-context.sh"
CODEX_SESSION_HOOK="$REPO_ROOT/core-rules/codex/hooks/session-context.sh"
WIKI_VALIDATOR="$REPO_ROOT/core-rules/skills/wiki-maintain/scripts/validate_wiki.py"
WIKI_FIXTURE="$REPO_ROOT/scripts/tests/fixtures/wiki-skill/project"
ADVISORY='wiki-skill-suggest: project-root gotchas.md changed; consider running wiki-maintain explicitly for any qualifying procedure.'
REGISTRATION_STATUS='Suggesting wiki maintenance...'

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/wiki-skill-suggest"
  PROJECT="$SANDBOX/project"
  TEST_HOME="$SANDBOX/home"
  TEST_TRELLIS_HOME="$SANDBOX/trellis-home"
  mkdir -p "$PROJECT/notes" "$TEST_HOME" "$TEST_TRELLIS_HOME"
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c init.defaultBranch=main init -q "$PROJECT"
  printf '%s\n' '## Unresolved fixture gotcha' > "$PROJECT/gotchas.md"
  printf '%s\n' 'nested fixture' > "$PROJECT/notes/gotchas.md"
  ln -s gotchas.md "$PROJECT/gotchas-link.md"
  ln -s "$PROJECT" "$SANDBOX/project-link"
}

event_for() {
  local key="$1" path="$2"
  case "$key" in
    file_path) jq -cn --arg path "$path" '{tool_input: {file_path: $path}}' ;;
    filePath) jq -cn --arg path "$path" '{tool_input: {filePath: $path}}' ;;
    *) return 2 ;;
  esac
}

invoke_hook() {
  local hook="$1" input="$2" tool_path="${3:-$PATH}" project="${4:-$PROJECT}"
  printf '%s' "$input" | /usr/bin/env \
    HOME="$TEST_HOME" \
    TRELLIS_HOME="$TEST_TRELLIS_HOME" \
    CLAUDE_PROJECT_DIR="$project" \
    CODEX_PROJECT_DIR="$project" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    PATH="$tool_path" \
    /bin/bash "$hook"
}

assert_claude_case() {
  local input="$1" expected="$2"
  run invoke_hook "$CLAUDE_HOOK" "$input"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if [ "$expected" = advisory ]; then
    printf '%s\n' "$output" | jq -e --arg message "$ADVISORY" \
      '. == {additionalContext: $message}' >/dev/null
  else
    [ -z "$output" ] || { echo "expected silence, got: $output"; false; }
  fi
}

assert_silent_case() {
  local hook="$1" input="$2" tool_path="${3:-$PATH}" project="${4:-$PROJECT}"
  run invoke_hook "$hook" "$input" "$tool_path" "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "expected silent exit 0, got: $output"; false; }
}

link_tool() {
  local destination="$1" name="$2" source
  source="$(command -v "$name")" || return 1
  ln -s "$source" "$destination/$name"
}

invoke_session_hook() {
  local hook="$1"
  printf '%s' '{"source":"startup"}' | /usr/bin/env \
    HOME="$TEST_HOME" \
    TRELLIS_HOME="$TEST_TRELLIS_HOME" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    CODEX_PROJECT_DIR="$PROJECT" \
    PATH="$PATH" \
    /bin/bash "$hook"
}

sha256_file() {
  local digest
  digest="$(shasum -a 256 "$1" 2>/dev/null)" || \
    digest="$(sha256sum "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${digest%% *}"
}

scope_hashes() {
  local root="$1"
  printf 'gotchas %s\n' "$(sha256_file "$root/gotchas.md")"
  printf 'context %s\n' "$(sha256_file "$root/context-log.md")"
  printf 'decisions %s\n' "$(sha256_file "$root/decisions-log.md")"
  printf 'impact %s\n' "$(sha256_file "$root/wiki/skill-impact.md")"
  printf 'skill %s\n' "$(sha256_file "$root/core-rules/skills/one-skill/SKILL.md")"
  printf 'purpose %s\n' "$(sha256_file "$root/core-rules/skills/one-skill/PURPOSE.md")"
  printf 'protected %s\n' "$(sha256_file "$root/core-rules/skills/protected/SKILL.md")"
}

snapshot_project() {
  local root="$1" destination="$2"
  (
    cd "$root" || exit 1
    find . -path './.git' -prune -o \( -type f -o -type l \) -print |
      LC_ALL=C sort |
      while IFS= read -r path; do
        if [ -L "$path" ]; then
          printf 'L %s %s\n' "$path" "$(readlink "$path")"
        else
          printf 'F %s %s\n' "$path" "$(sha256_file "$path")"
        fi
      done
  ) > "$destination"
}

@test "Claude hook suggests only for canonical root gotchas.md path variants and always exits zero" {
  local input
  for input in \
    "$(event_for file_path "$PROJECT/gotchas.md")" \
    "$(event_for filePath './gotchas.md')" \
    "$(event_for file_path "$PROJECT/gotchas-link.md")" \
    "$(event_for filePath "$SANDBOX/project-link/gotchas.md")"; do
    assert_claude_case "$input" advisory
  done

  for input in \
    "$(event_for file_path "$PROJECT/notes/gotchas.md")" \
    "$(event_for filePath 'gotchas.md')" \
    "$(event_for file_path "$PROJECT/missing/gotchas.md")" \
    '{not-json'; do
    assert_claude_case "$input" silent
  done
}

@test "Codex twin makes the same path decisions and emits the PostToolUse envelope" {
  local inputs expected index claude_output codex_output claude_context codex_context linked hook
  inputs=(
    "$(event_for file_path "$PROJECT/gotchas.md")"
    "$(event_for filePath './gotchas.md')"
    "$(event_for file_path "$PROJECT/notes/gotchas.md")"
    "$(event_for filePath 'gotchas.md')"
    "$(event_for file_path "$PROJECT/missing/gotchas.md")"
  )
  expected=(advisory advisory silent silent silent)

  index=0
  while [ "$index" -lt "${#inputs[@]}" ]; do
    run invoke_hook "$CLAUDE_HOOK" "${inputs[$index]}"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    claude_output="$output"

    run invoke_hook "$CODEX_HOOK" "${inputs[$index]}"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    codex_output="$output"

    if [ -n "$claude_output" ]; then
      claude_context="$(printf '%s\n' "$claude_output" | jq -er '.additionalContext')"
    else
      claude_context=""
    fi
    if [ -n "$codex_output" ]; then
      printf '%s\n' "$codex_output" | jq -e --arg message "$ADVISORY" '
        . == {
          hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $message
          }
        }
      ' >/dev/null
      codex_context="$(printf '%s\n' "$codex_output" | jq -er '.hookSpecificOutput.additionalContext')"
    else
      codex_context=""
    fi

    [ "$claude_context" = "$codex_context" ]
    if [ "${expected[$index]}" = advisory ]; then
      [ "$codex_context" = "$ADVISORY" ]
    else
      [ -z "$codex_context" ]
    fi
    index=$((index + 1))
  done

  git -C "$PROJECT" add gotchas.md notes/gotchas.md gotchas-link.md
  git -C "$PROJECT" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -q -m "seed canonical root"
  linked="$SANDBOX/linked-worktree"
  git -C "$PROJECT" worktree add -q -b linked "$linked"
  for hook in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
    assert_silent_case "$hook" "$(event_for filePath './gotchas.md')" "$PATH" "$linked"
    run invoke_hook "$hook" "$(event_for file_path "$PROJECT/gotchas.md")" "$PATH" "$linked"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    if [ "$hook" = "$CLAUDE_HOOK" ]; then
      printf '%s\n' "$output" | jq -e --arg message "$ADVISORY" \
        '. == {additionalContext: $message}' >/dev/null
    else
      printf '%s\n' "$output" | jq -e --arg message "$ADVISORY" '
        . == {
          hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $message
          }
        }
      ' >/dev/null
    fi
  done
}

@test "missing jq, missing Git, and malformed envelopes are silent exit zero" {
  local no_jq="$SANDBOX/no-jq" no_git="$SANDBOX/no-git" hook input
  mkdir -p "$no_jq" "$no_git"
  link_tool "$no_jq" git
  link_tool "$no_git" jq
  input="$(event_for file_path "$PROJECT/gotchas.md")"

  for hook in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
    assert_silent_case "$hook" "$input" "$no_jq"
    assert_silent_case "$hook" "$input" "$no_git"
    assert_silent_case "$hook" "$input" "$PATH" "$SANDBOX/missing-root"
    for input in \
      '{' \
      '[]' \
      '{"tool_input":{"file_path":42}}' \
      '{"tool_input":{"file_path":"./gotchas.md\n"}}' \
      $'{"tool_input":{"file_path":"./gotchas.md"}}\n{"tool_input":{"filePath":"./gotchas.md"}}'; do
      assert_silent_case "$hook" "$input"
    done
  done
}

@test "both attach-rendered local templates carry one exact PostToolUse registration" {
  local claude_template="$REPO_ROOT/core-rules/templates/claude-settings.local.json"
  local codex_template="$REPO_ROOT/core-rules/templates/codex-hooks.local.json"
  local manifest="$REPO_ROOT/core-rules/inheritance-manifest.json"
  local claude_command codex_command template command
  claude_command='TRELLIS_ROOT="$CLAUDE_PROJECT_DIR/.trellis/runtime" "$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/wiki-skill-suggest.sh"'
  codex_command='TRELLIS_ROOT="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.trellis/runtime" "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.trellis/runtime/core-rules/codex/hooks/wiki-skill-suggest.sh"'

  for template in "$claude_template" "$codex_template"; do
    if [ "$template" = "$claude_template" ]; then
      command="$claude_command"
    else
      command="$codex_command"
    fi
    run jq -e --arg command "$command" --arg status "$REGISTRATION_STATUS" '
      ([.hooks.PostToolUse[]
        | select(any(.hooks[]?; .command? == $command))]
       == [{
         matcher: "Write|Edit|MultiEdit",
         hooks: [{
           type: "command",
           command: $command,
           timeout: 5,
           statusMessage: $status
         }]
       }])
      and ([.hooks | to_entries[] | .value[]? | .hooks[]?
            | select(.command? == $command)] | length) == 1
      and ([.. | strings | select(contains("wiki-skill-suggest.sh"))] | length) == 1
    ' "$template"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done

  jq -e '[.. | strings | select(contains("wiki-skill-suggest"))] | length == 0' \
    "$manifest" >/dev/null
}

@test "session context remains wiki-free while an explicit on-demand read follows the catalog link" {
  local hook context index_bytes relative_pattern pattern_bytes
  cat > "$PROJECT/gotchas.md" <<'EOF'
## Unresolved RUNTIME_GOTCHA_SENTINEL
The unresolved source remains authoritative.
EOF
  mkdir -p "$PROJECT/wiki/patterns"
  cat > "$PROJECT/wiki/index.md" <<'EOF'
# Wiki patterns
WIKI_INDEX_SENTINEL

| Pattern | Status |
|---|---|
| [runtime-fixture](patterns/runtime-fixture.md) | active |
EOF
  cat > "$PROJECT/wiki/patterns/runtime-fixture.md" <<'EOF'
# Runtime fixture
WIKI_PATTERN_SENTINEL
EOF

  for hook in "$CLAUDE_SESSION_HOOK" "$CODEX_SESSION_HOOK"; do
    run invoke_session_hook "$hook"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    context="$(printf '%s\n' "$output" | jq -er \
      '.hookSpecificOutput
       | select(.hookEventName == "SessionStart")
       | .additionalContext')"
    [[ "$context" == *RUNTIME_GOTCHA_SENTINEL* ]]
    [[ "$context" != *WIKI_INDEX_SENTINEL* ]]
    [[ "$context" != *WIKI_PATTERN_SENTINEL* ]]
    [[ "$context" != *runtime-fixture* ]]
    [[ "$context" != *wiki/index.md* ]]
  done

  index_bytes="$(cat "$PROJECT/wiki/index.md")"
  [[ "$index_bytes" == *WIKI_INDEX_SENTINEL* ]]
  relative_pattern="${index_bytes#*](}"
  relative_pattern="${relative_pattern%%)*}"
  [ "$relative_pattern" = 'patterns/runtime-fixture.md' ]
  pattern_bytes="$(cat "$PROJECT/wiki/$relative_pattern")"
  [[ "$pattern_bytes" == *WIKI_PATTERN_SENTINEL* ]]
}

@test "hook and maintainer paths stay within scope and check-change is read-only" {
  local before="$SANDBOX/before" after="$SANDBOX/after" global="$SANDBOX/global-skills"
  local forbidden_before forbidden_after global_before hook_scope_before input
  local before_snapshot="$SANDBOX/before.snapshot" after_snapshot="$SANDBOX/after.snapshot"
  local before_final="$SANDBOX/before.final" after_final="$SANDBOX/after.final"
  local hook_snapshot="$SANDBOX/hook.snapshot" hook_final="$SANDBOX/hook.final"
  mkdir -p "$before" "$after" "$global"
  cp -R "$WIKI_FIXTURE/." "$before/"
  cp -R "$WIKI_FIXTURE/." "$after/"
  cp -R "$WIKI_FIXTURE/." "$PROJECT/"
  mkdir -p \
    "$before/core-rules/skills/protected" \
    "$after/core-rules/skills/protected" \
    "$PROJECT/core-rules/skills/protected"
  printf '%s\n' 'protected project skill' > "$before/core-rules/skills/protected/SKILL.md"
  cp "$before/core-rules/skills/protected/SKILL.md" \
    "$after/core-rules/skills/protected/SKILL.md"
  cp "$before/core-rules/skills/protected/SKILL.md" \
    "$PROJECT/core-rules/skills/protected/SKILL.md"
  printf '%s\n' 'protected global skill' > "$global/SKILL.md"

  forbidden_before="$(scope_hashes "$after")"
  global_before="$(sha256_file "$global/SKILL.md")"
  run python3 "$WIKI_VALIDATOR" mark-stale --root "$after"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e '
    .verdict == "valid"
    and .changed_paths == [
      "wiki/index.md",
      "wiki/patterns/broken-context.md"
    ]
  ' >/dev/null
  forbidden_after="$(scope_hashes "$after")"
  [ "$forbidden_after" = "$forbidden_before" ]
  [ "$(sha256_file "$global/SKILL.md")" = "$global_before" ]

  hook_scope_before="$(scope_hashes "$PROJECT")"
  snapshot_project "$before" "$before_snapshot"
  snapshot_project "$after" "$after_snapshot"
  snapshot_project "$PROJECT" "$hook_snapshot"

  input="$(event_for file_path "$PROJECT/gotchas.md")"
  run invoke_hook "$CLAUDE_HOOK" "$input"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e --arg message "$ADVISORY" \
    '. == {additionalContext: $message}' >/dev/null
  run invoke_hook "$CODEX_HOOK" "$input"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e --arg message "$ADVISORY" '
    . == {hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $message
    }}
  ' >/dev/null
  [ "$(scope_hashes "$PROJECT")" = "$hook_scope_before" ]
  snapshot_project "$PROJECT" "$hook_final"
  cmp -s "$hook_snapshot" "$hook_final"

  run python3 "$WIKI_VALIDATOR" check-change --before "$before" --after "$after"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e '
    .verdict == "allowed"
    and .transition == "mark-stale"
    and .changed_paths == [
      "wiki/index.md",
      "wiki/patterns/broken-context.md"
    ]
  ' >/dev/null
  snapshot_project "$before" "$before_final"
  snapshot_project "$after" "$after_final"
  cmp -s "$before_snapshot" "$before_final"
  cmp -s "$after_snapshot" "$after_final"
  [ "$(scope_hashes "$after")" = "$forbidden_before" ]
  [ "$(sha256_file "$global/SKILL.md")" = "$global_before" ]
}
