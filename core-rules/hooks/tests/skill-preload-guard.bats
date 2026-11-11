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
  rm -rf "${SANDBOX:?}"
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

@test "supervised model and slash twins quickly report the budget for a 25 MB Skill" {
  make_skill "$PROJECT/.claude/skills/huge" 25000000
  local tree hook harness input expected started
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for hook in skill-preload-guard.sh skill-slash-guard.sh; do
      if [ "$hook" = skill-preload-guard.sh ]; then
        harness=claude
        expected=11
        input='{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"huge"}}'
      else
        harness=claude-expansion
        expected=11
        input='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"huge"}'
      fi
      started=$SECONDS
      run env HOME="$USER_HOME" CLAUDE_PROJECT_DIR="$PROJECT" HOOK_INPUT="$input" \
        /bin/bash -c 'printf "%s" "$HOOK_INPUT" | /usr/bin/perl "$1" "$2" "${3%.sh}" /bin/bash "$4/$3"' \
        _ "$HOOKS_DIR/lib/guard-supervise.pl" "$harness" "$hook" "$tree"
      [ "$status" -eq "$expected" ] || { echo "$tree/$hook supervisor exit=$status: $output"; false; }
      jq -e '(tostring | contains("Skill root exceeds 65536-byte inline budget")) and (tostring | contains("bytes=25000000"))' <<<"$output" >/dev/null
      [ "$((SECONDS-started))" -lt 10 ] || { echo "$tree/$hook took 10 seconds or more"; false; }
    done
  done
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

@test "canonical and hook Skill size libraries remain byte-identical" {
  cmp "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../codex/hooks/lib/skill-size.sh"
  cmp "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../../scripts/lib/skill-size.sh"
}

@test "qualified resolver selects its named plugin before unrelated suffix matches" {
  local lib root="$USER_HOME/.claude/plugins/cache/vendor/plugin-a/1/skills/foo"
  make_named_skill "$PROJECT/.claude/skills/foo" bar 128
  make_named_skill "$root" foo 70000
  make_named_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/plugin-a/skills/foo" foo 128
  for lib in "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../codex/hooks/lib/skill-size.sh" "$HOOKS_DIR/../../scripts/lib/skill-size.sh"; do
    run bash -c '. "$1"; skill_size_resolve_root plugin-a:foo "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$root" ] || { echo "$output"; false; }
    # Unknown qualifiers retain the documented suffix fallback.
    run bash -c '. "$1"; skill_size_resolve_root unknown:foo "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$PROJECT/.claude/skills/foo" ] || { echo "$output"; false; }
  done
  mkdir -p "$USER_HOME/.claude/plugins/cache/vendor/plugin-a/2/skills"
  ln -s "$root" "$USER_HOME/.claude/plugins/cache/vendor/plugin-a/2/skills/foo"
  for lib in "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../codex/hooks/lib/skill-size.sh" "$HOOKS_DIR/../../scripts/lib/skill-size.sh"; do
    run bash -c '. "$1"; skill_size_resolve_root plugin-a:foo "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 0 ] && [ "$output" = "$root" ] || { echo "$output"; false; }
  done
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin-a/3/skills/foo" foo 128
  for lib in "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../codex/hooks/lib/skill-size.sh" "$HOOKS_DIR/../../scripts/lib/skill-size.sh"; do
    run bash -c '. "$1"; skill_size_resolve_root plugin-a:foo "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 2 ] && [[ "$output" == *'ambiguous Skill'* ]] || { echo "$output"; false; }
  done
}

@test "shadowed named skills cannot hide oversized qualified or declared targets" {
  local hooks hook input name
  local project_skill="$PROJECT/.claude/skills/foo"
  make_named_skill "$project_skill" bar 128
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin-a/1/skills/foo" foo 70000
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/other/1/skills/foo" foo 128
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin-c/1/skills/foo" foo 128
  make_named_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/plugin-c/skills/foo" foo 70000
  for hooks in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for name in plugin-a:foo foo; do
      for hook in skill-preload-guard.sh skill-slash-guard.sh; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
        else
          input="{\"hook_event_name\":\"UserPromptExpansion\",\"expansion_type\":\"slash_command\",\"command_name\":\"$name\"}"
        fi
        run_hook "$hooks/$hook" "$input"
        [ "$status" -eq 0 ]
        jq -e '.decision == "block" or .hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
        [[ "$output" == *'plugin-a'* ]] || { echo "$output"; false; }
      done
    done
    for name in other:foo missing:foo plugin-c:foo; do
      run_hook "$hooks/skill-preload-guard.sh" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
      [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$name $output"; false; }
    done
  done
  # The documented project precedence is unchanged for a correctly named root.
  make_named_skill "$project_skill" foo 128
  for hooks in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    run_hook "$hooks/skill-preload-guard.sh" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"foo"}}'
    [ "$status" -eq 0 ] && [ -z "$output" ]
  done
}

@test "unsafe discovered paths deny matching identities without denying unrelated skills" {
  local bad_tab="$PROJECT/.claude/skills/"$'bad\tpath' bad_newline="$USER_HOME/.claude/skills/"$'bad\npath'
  local hooks name hook input lib
  make_named_skill "$bad_tab" unsafe-tab 70000
  make_named_skill "$bad_newline" unsafe-newline 70000
  make_skill "$USER_HOME/.claude/skills/unsafe-tab" 128
  make_skill "$PROJECT/.claude/skills/ordinary" 128
  # A safe spelling resolving to an unsafe physical directory is also invalid.
  ln -s "$bad_tab" "$PROJECT/.claude/skills/unsafe-alias"
  for hooks in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for name in unsafe-tab unsafe-newline unsafe-alias; do
      for hook in skill-preload-guard.sh skill-slash-guard.sh; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
        else
          input="{\"hook_event_name\":\"UserPromptExpansion\",\"expansion_type\":\"slash_command\",\"command_name\":\"$name\"}"
        fi
        run_hook "$hooks/$hook" "$input"
        [ "$status" -eq 0 ]
        jq -e '.decision == "block" or .hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
      done
    done
    run_hook "$hooks/skill-preload-guard.sh" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"ordinary"}}'
    [ "$status" -eq 0 ] && [ -z "$output" ]
    run_hook "$hooks/skill-slash-guard.sh" '{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"unknown"}'
    [ "$status" -eq 0 ] && [ -z "$output" ]
  done
  for lib in "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../codex/hooks/lib/skill-size.sh" "$HOOKS_DIR/../../scripts/lib/skill-size.sh"; do
    run bash -c '. "$1"; skill_size_discover_roots "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 2 ] || { echo "$output"; false; }
  done
}

@test "CRLF BOM and padded frontmatter names enforce budget without widening matches" {
  local hooks format name dir input hook lib
  for format in crlf bom padded bom-crlf; do
    name="big-$format"
    dir="$PROJECT/.claude/skills/dir-$format"
    mkdir -p "$dir" "$USER_HOME/.claude/skills/$name"
    python3 -I - "$dir/SKILL.md" "$name" "$format" <<'PY'
import pathlib, sys
path, name, fmt = sys.argv[1:]
end = b'\r\n' if 'crlf' in fmt else b'\n'
fence = b'---  ' if fmt == 'padded' else b'---'
prefix = (b'\xef\xbb\xbf' if 'bom' in fmt else b'') + fence + end + b'name: ' + name.encode() + end + fence + end
pathlib.Path(path).write_bytes(prefix + b'x' * 70000)
PY
    printf 'small\n' > "$USER_HOME/.claude/skills/$name/SKILL.md"
  done
  make_named_skill "$PROJECT/.claude/skills/small-root" small-declared 128
  for hooks in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for format in crlf bom padded bom-crlf; do
      name="big-$format"
      for hook in skill-preload-guard.sh skill-slash-guard.sh; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
        else
          input="{\"hook_event_name\":\"UserPromptExpansion\",\"expansion_type\":\"slash_command\",\"command_name\":\"$name\"}"
        fi
        run_hook "$hooks/$hook" "$input"
        [ "$status" -eq 0 ]
        jq -e '.decision == "block" or .hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
        [[ "$output" == *"dir-$format"* ]] || { echo "$output"; false; }
      done
    done
    run_hook "$hooks/skill-preload-guard.sh" '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"small-declared"}}'
    [ "$status" -eq 0 ] && [ -z "$output" ]
  done
  # The canonical size library must resolve the same frontmatter as both twins.
  for lib in "$HOOKS_DIR/lib/skill-size.sh" "$HOOKS_DIR/../codex/hooks/lib/skill-size.sh" "$HOOKS_DIR/../../scripts/lib/skill-size.sh"; do
    run bash -c '. "$1"; skill_size_resolve_root big-bom-crlf "$2" "$3"' _ "$lib" "$PROJECT" "$USER_HOME"
    [ "$status" -eq 0 ] && [[ "$output" == *'/dir-bom-crlf' ]]
  done
}

@test "invalid discovery directories deny matching events in both hook trees" {
  local hooks input hook envname
  for hooks in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for envname in HOME CLAUDE_PROJECT_DIR; do
      for hook in skill-preload-guard.sh skill-slash-guard.sh; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input='{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"example"}}'
        else
          input='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"example"}'
        fi
        run env HOME="$USER_HOME" CLAUDE_PROJECT_DIR="$PROJECT" "$envname=$SANDBOX/absent" HOOK_INPUT="$input" \
          bash -c 'printf "%s" "$HOOK_INPUT" | bash "$1"' _ "$hooks/$hook"
        [ "$status" -eq 0 ] || { echo "$output"; false; }
        jq -e '.decision == "block" or .hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
      done
    done
    # An unrelated event must still pass even when discovery is unavailable.
    run env HOME="$SANDBOX/absent" CLAUDE_PROJECT_DIR="$PROJECT" bash -c \
      'printf "%s" '\''{"hook_event_name":"PreToolUse","tool_name":"Bash"}'\'' | bash "$1"' _ "$hooks/skill-preload-guard.sh"
    [ "$status" -eq 0 ] && [ -z "$output" ]
  done
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

@test "both guard trees distinguish invalid names from ambiguity" {
  local tree hook name input
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for hook in skill-preload-guard.sh skill-slash-guard.sh; do
      for name in 'a/b' 'plugin:'; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
        else
          input="{\"hook_event_name\":\"UserPromptExpansion\",\"expansion_type\":\"slash_command\",\"command_name\":\"$name\"}"
        fi
        run_hook "$tree/$hook" "$input"
        [ "$status" -eq 0 ]
        jq -e '(.hookSpecificOutput.permissionDecision == "deny" or .decision == "block") and (tostring | contains("invalid name or discovery root")) and ((tostring | contains("resolves ambiguously")) | not)' <<<"$output" >/dev/null
      done
    done
    run /bin/bash -c '. "$1/lib/skill-size.sh"; . "$1/lib/skill-preload.sh"; skill_preload_check known "$2" "$3"' \
      _ "$tree" "$PROJECT/missing" "$USER_HOME"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid name or discovery root"* ]]
  done
}

@test "both guard trees reject invalid UTF-8 before model or slash expansion" {
  make_skill "$PROJECT/.claude/skills/invalid-directory" 1
  printf '%s\n' '---' > "$PROJECT/.claude/skills/invalid-directory/SKILL.md"
  printf 'description: \377\nname: invalid\n---\nbody' >> "$PROJECT/.claude/skills/invalid-directory/SKILL.md"
  local tree hook input
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for hook in skill-preload-guard.sh skill-slash-guard.sh; do
      if [ "$hook" = skill-preload-guard.sh ]; then
        input='{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"invalid"}}'
      else
        input='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"invalid"}'
      fi
      run_hook "$tree/$hook" "$input"
      [ "$status" -eq 0 ]
      jq -e '(.hookSpecificOutput.permissionDecision == "deny" or .decision == "block") and (tostring | contains("unreadable manifest"))' <<<"$output" >/dev/null
    done
  done
}

@test "both model and slash twins refuse budget and ambiguous roots before expansion" {
  make_skill "$PROJECT/.claude/skills/exact" 65536
  make_skill "$PROJECT/.claude/skills/over" 65537
  make_skill "$USER_HOME/.claude/plugins/cache/v/a/1/skills/shared" 1
  make_skill "$USER_HOME/.claude/plugins/cache/v/b/1/skills/shared" 1
  local tree hook name input
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for hook in skill-preload-guard.sh skill-slash-guard.sh; do
      for name in exact over shared plugin:shared unknown; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
        else
          input="{\"hook_event_name\":\"UserPromptExpansion\",\"expansion_type\":\"slash_command\",\"command_name\":\"$name\"}"
        fi
        run_hook "$tree/$hook" "$input"
        [ "$status" -eq 0 ]
        case "$name" in
          over) jq -e '(.hookSpecificOutput.permissionDecision == "deny" or .decision == "block") and (tostring | contains("inline budget"))' <<<"$output" >/dev/null ;;
          shared|plugin:shared) jq -e '(.hookSpecificOutput.permissionDecision == "deny" or .decision == "block") and (tostring | contains("resolves ambiguously"))' <<<"$output" >/dev/null ;;
          *) [ -z "$output" ] ;;
        esac
      done
    done
  done
}

@test "both model and slash twins refuse when snapshot temp creation is denied" {
  [ "$(uname -s)" = Darwin ] || skip "macOS bash 3.2 temp-file regression"
  make_skill "$PROJECT/.claude/skills/over" 65537
  local profile='(version 1)(allow default)(deny file-write-create)' tree hook input
  run /usr/bin/sandbox-exec -p "$profile" /bin/bash -c 'cat <<< probe'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot create temp file"* ]]
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for hook in skill-preload-guard.sh skill-slash-guard.sh; do
      if [ "$hook" = skill-preload-guard.sh ]; then
        input='{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"over"}}'
      else
        input='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"over"}'
      fi
      run env HOME="$USER_HOME" CLAUDE_PROJECT_DIR="$PROJECT" HOOK_INPUT="$input" \
        /usr/bin/sandbox-exec -p "$profile" /bin/bash -c \
        'printf "%s" "$HOOK_INPUT" | /bin/bash "$1"' _ "$tree/$hook"
      [ "$status" -eq 0 ]
      jq -e '(.hookSpecificOutput.permissionDecision == "deny" or .decision == "block") and (tostring | contains("invalid name or discovery root"))' <<<"$output" >/dev/null
    done
  done
}

@test "both guard trees reject non-scalar and exact-budget invalid UTF-8" {
  make_skill "$PROJECT/.claude/skills/non-scalar" 1
  make_skill "$PROJECT/.claude/skills/exact-invalid" 65536
  printf '\364\220\200\200' > "$PROJECT/.claude/skills/non-scalar/SKILL.md"
  printf '\377' | dd of="$PROJECT/.claude/skills/exact-invalid/SKILL.md" bs=1 seek=65535 conv=notrunc 2>/dev/null
  local tree hook name input
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    for hook in skill-preload-guard.sh skill-slash-guard.sh; do
      for name in non-scalar exact-invalid; do
        if [ "$hook" = skill-preload-guard.sh ]; then
          input="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"$name\"}}"
        else
          input="{\"hook_event_name\":\"UserPromptExpansion\",\"expansion_type\":\"slash_command\",\"command_name\":\"$name\"}"
        fi
        run_hook "$tree/$hook" "$input"
        [ "$status" -eq 0 ]
        jq -e '(.hookSpecificOutput.permissionDecision == "deny" or .decision == "block") and (tostring | contains("unreadable manifest"))' <<<"$output" >/dev/null
      done
    done
  done
}

@test "both model guards refuse without jq even with degradation requested" {
  local jq_free="$SANDBOX/jq-free" tree
  mkdir -p "$jq_free"
  ln -s "$(command -v cat)" "$jq_free/cat"
  ln -s "$(command -v dirname)" "$jq_free/dirname"
  for tree in "$HOOKS_DIR" "$HOOKS_DIR/../codex/hooks"; do
    run env HOME="$USER_HOME" CLAUDE_PROJECT_DIR="$PROJECT" PATH="$jq_free" TRELLIS_NO_JQ_DEGRADE=1 \
      /bin/bash "$tree/skill-preload-guard.sh" <<< '{}'
    [ "$status" -eq 2 ] || { echo "$tree missing jq allowed: $output"; false; }
    [[ "$output" == *"jq required but not found; refusing"* ]]
  done
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
  # B0-5 runs the guard through the guard-supervise.pl sh entry; the guard
  # path is the supervisor's last, quoted argument (pinned in guard-supervise.bats).
  local tail='guard-supervise "$CLAUDE_PROJECT_DIR/.claude/hooks/lib/guard-supervise.pl" claude skill-preload-guard "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-preload-guard.sh"'
  local slash_tail='guard-supervise "$CLAUDE_PROJECT_DIR/.claude/hooks/lib/guard-supervise.pl" claude-expansion skill-slash-guard "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-slash-guard.sh"'
  jq -e --arg tail "$tail" --arg slash_tail "$slash_tail" '
    any(.hooks.PreToolUse[];
      .matcher == "Skill" and any(.hooks[]; .command | startswith("/bin/sh -c ") and endswith(" " + $tail)))
    and any(.hooks.UserPromptExpansion[];
      .matcher == ".*" and any(.hooks[]; .command | startswith("/bin/sh -c ") and endswith(" " + $slash_tail)))
    and (any(.hooks.SessionStart[].hooks[];
      .command | contains("skill-size-preflight")) | not)
  ' "$settings" >/dev/null
}
