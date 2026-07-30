#!/usr/bin/env bats

HOOKS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
MODEL_HOOK="$HOOKS_DIR/skill-preload-guard.sh"
SLASH_HOOK="$HOOKS_DIR/skill-slash-guard.sh"
PREFLIGHT_HOOK="$HOOKS_DIR/skill-size-preflight.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TMPDIR/skill-preload.XXXXXX")"
  PROJECT="$SANDBOX/project"
  USER_HOME="$SANDBOX/home"
  mkdir -p "$PROJECT/.claude/skills" "$USER_HOME/.claude/skills"
}

teardown() {
  rm -rf "$SANDBOX"
}

make_skill() {
  local root="$1" bytes="$2"
  mkdir -p "$root"
  python3 - "$root/SKILL.md" "$bytes" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"a" * int(sys.argv[2]))
PY
}

make_named_skill() {
  local root="$1" name="$2" bytes="$3"
  mkdir -p "$root"
  python3 - "$root/SKILL.md" "$name" "$bytes" <<'PY'
import pathlib
import sys
prefix = f"---\nname: {sys.argv[2]}\n---\n".encode()
target = int(sys.argv[3])
if len(prefix) > target:
    raise SystemExit("target too small")
pathlib.Path(sys.argv[1]).write_bytes(prefix + (b"a" * (target - len(prefix))))
PY
}

run_hook() {
  local hook="$1" input="$2"
  run env HOME="$USER_HOME" CLAUDE_PROJECT_DIR="$PROJECT" HOOK_INPUT="$input" \
    bash -c 'printf "%s" "$HOOK_INPUT" | bash "$1"' _ "$hook"
}

@test "model-invoked Skill denies oversized root with PreToolUse contract" {
  make_skill "$PROJECT/.claude/skills/oversized-probe" 65537
  run_hook "$MODEL_HOOK" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"oversized-probe"}}'

  [ "$status" -eq 0 ]
  jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains("Skill root exceeds 65536-byte inline budget"))
    and (.hookSpecificOutput.permissionDecisionReason | contains("owner=project"))
    and (.hookSpecificOutput.permissionDecisionReason | contains("bytes=65537"))
    and (keys == ["hookSpecificOutput"])
  ' <<<"$output" >/dev/null
}

@test "direct slash command denies oversized root with UserPromptExpansion contract" {
  make_skill "$PROJECT/.claude/skills/oversized-probe" 65537
  run_hook "$SLASH_HOOK" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"oversized-probe","command_args":"","command_source":"projectSettings","prompt":"/oversized-probe"}'

  [ "$status" -eq 0 ]
  jq -e '
    .decision == "block"
    and (.reason | contains("Skill root exceeds 65536-byte inline budget"))
    and (.reason | contains("bytes=65537"))
    and (keys == ["decision", "reason"])
  ' <<<"$output" >/dev/null
}

@test "active-style plugin-qualified names prefer exact declared identity then suffix" {
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/exact-root" "active-plugin:oversized-plugin" 65537
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/other/1.0.0/skills/oversized-plugin" 1

  run_hook "$MODEL_HOOK" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"active-plugin:oversized-plugin"}}'
  [ "$status" -eq 0 ]
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains("active-plugin:oversized-plugin"))
    and (.hookSpecificOutput.permissionDecisionReason | contains("/exact-root"))
    and (.hookSpecificOutput.permissionDecisionReason | contains("owner=plugin-cache"))
  ' <<<"$output" >/dev/null

  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/suffix-only" 65537
  run_hook "$SLASH_HOOK" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"active-plugin:suffix-only","command_source":"plugin","prompt":"/active-plugin:suffix-only"}'
  [ "$status" -eq 0 ]
  jq -e '.decision == "block" and (.reason | contains("owner=plugin-cache"))' <<<"$output" >/dev/null
}

@test "under-budget and exact-budget Skills are allowed without output" {
  make_skill "$PROJECT/.claude/skills/under" 65535
  make_skill "$PROJECT/.claude/skills/exact" 65536

  run_hook "$MODEL_HOOK" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"under"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook "$SLASH_HOOK" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"exact","command_source":"projectSettings","prompt":"/exact"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed or unrelated envelopes allow without output" {
  run_hook "$MODEL_HOOK" '{not-json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook "$MODEL_HOOK" '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"skill":"missing"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook "$MODEL_HOOK" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"unknown"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook "$SLASH_HOOK" '{"hook_event_name":"UserPromptExpansion","expansion_type":"other","command_name":"missing"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_hook "$SLASH_HOOK" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"unknown","command_source":"projectSettings","prompt":"/unknown"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ambiguous discoverable Skill name fails closed for invocation" {
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/duplicate" 1
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/duplicate" 1

  run_hook "$MODEL_HOOK" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"duplicate"}}'
  [ "$status" -eq 0 ]
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains("resolves ambiguously"))
  ' <<<"$output" >/dev/null

  run_hook "$SLASH_HOOK" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"duplicate","command_source":"projectSettings","prompt":"/duplicate"}'
  [ "$status" -eq 0 ]
  jq -e '.decision == "block" and (.reason | contains("resolves ambiguously"))' <<<"$output" >/dev/null
}

@test "SessionStart preflight warns only for oversized and ambiguous roots" {
  make_skill "$PROJECT/.claude/skills/large" 65537
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/duplicate" 1
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/duplicate" 1
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/three/1.0.0/skills/declared-one" "declared-duplicate" 128
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/four/1.0.0/skills/declared-two" "declared-duplicate" 128

  run_hook "$PREFLIGHT_HOOK" '{"hook_event_name":"SessionStart","source":"startup"}'
  [ "$status" -eq 0 ]
  jq -e '
    .hookSpecificOutput.hookEventName == "SessionStart"
    and (.hookSpecificOutput.additionalContext | contains("warning only at SessionStart"))
    and (.hookSpecificOutput.additionalContext | contains("oversized: '\''large'\''"))
    and (.hookSpecificOutput.additionalContext | contains("ambiguous: '\''duplicate'\''"))
    and (.hookSpecificOutput.additionalContext | contains("ambiguous: '\''declared-duplicate'\''"))
    and (.hookSpecificOutput | has("permissionDecision") | not)
  ' <<<"$output" >/dev/null
}

@test "SessionStart preflight stays silent when all roots are bounded and unique" {
  make_skill "$PROJECT/.claude/skills/small" 65536
  run_hook "$PREFLIGHT_HOOK" '{"hook_event_name":"SessionStart","source":"resume"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "canonical settings wire exact Skill and slash expansion matchers" {
  local settings="$HOOKS_DIR/../templates/claude-settings.json"
  jq -e '
    any(.hooks.PreToolUse[];
      .matcher == "Skill" and any(.hooks[]; .command | endswith("/skill-preload-guard.sh")))
    and any(.hooks.UserPromptExpansion[];
      .matcher == ".*" and any(.hooks[]; .command | endswith("/skill-slash-guard.sh")))
    and any(.hooks.SessionStart[].hooks[];
      .command | endswith("/skill-size-preflight.sh"))
  ' "$settings" >/dev/null
}
