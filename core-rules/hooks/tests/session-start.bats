#!/usr/bin/env bats
# session-start.sh (spec 072 U4): the one SessionStart command dispatches the
# context hooks by source, hands each the same event and environment the
# launcher route gave it, and injects their joined contexts.

load helpers

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/session-start.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  PAYLOAD="$SANDBOX/payload"
  RECORD="$SANDBOX/record"
  mkdir -p "$PAYLOAD/core-rules/codex" "$SANDBOX/project"
  cp -R "$HOOKS_DIR" "$PAYLOAD/core-rules/hooks"
  cp -R "$CODEX_HOOKS_DIR" "$PAYLOAD/core-rules/codex/hooks"
  git init -q "$SANDBOX/project"
  ln -s project "$SANDBOX/project link"
}

teardown() {
  rm -rf "$SANDBOX"
}

# Replace the three context hooks in both trees with stubs that record their
# name, stdin and environment, and print their name as additionalContext.
stub_context_hooks() {
  local dir name
  for dir in "$PAYLOAD/core-rules/hooks" "$PAYLOAD/core-rules/codex/hooks"; do
    for name in session-context post-compact-context inject-primer-index; do
      cat > "$dir/$name.sh" <<EOF
#!/usr/bin/env bash
{
  printf 'hook=%s\n' "$name"
  printf 'stdin=%s\n' "\$(cat)"
  printf 'project=%s\n' "\${CLAUDE_PROJECT_DIR:-}\${CODEX_PROJECT_DIR:+codex:\$CODEX_PROJECT_DIR}"
  printf 'root=%s\n' "\${TRELLIS_ROOT:-}"
  printf 'git=%s\n' "\$(git -C "$SANDBOX/project" config --get core.fsmonitor):\$(git -C "$SANDBOX/project" config --get core.hooksPath):\${GIT_CONFIG_NOSYSTEM:-}:\${GIT_CONFIG_GLOBAL:-}"
} >> "$RECORD"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$name"
EOF
      chmod 755 "$dir/$name.sh"
    done
  done
}

dispatch() {
  local harness_dir="$1" source="$2"
  shift 2
  printf '{"source":"%s","session_id":"s-1"}' "$source" |
    env "$@" bash "$PAYLOAD/$harness_dir/session-start.sh" "$SANDBOX/project link"
}

@test "startup and resume run session-context then the primer index, compact runs post-compact-context, clear runs nothing" {
  stub_context_hooks
  for harness_dir in core-rules/hooks core-rules/codex/hooks; do
    for source in startup resume; do
      rm -f "$RECORD"
      out="$(dispatch "$harness_dir" "$source")"
      [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" = $'session-context\n\ninject-primer-index' ] ||
        { echo "$harness_dir $source: $out"; false; }
      [ "$(grep '^hook=' "$RECORD" | tr '\n' ' ')" = "hook=session-context hook=inject-primer-index " ] || { cat "$RECORD"; false; }
      [ "$(grep -c "^stdin={\"source\":\"$source\",\"session_id\":\"s-1\"}\$" "$RECORD")" -eq 2 ] || { cat "$RECORD"; false; }
    done

    rm -f "$RECORD"
    out="$(dispatch "$harness_dir" compact)"
    [ "$out" = '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"post-compact-context"}}' ] ||
      { echo "$harness_dir compact: $out"; false; }
    [ "$(grep '^hook=' "$RECORD")" = "hook=post-compact-context" ] || { cat "$RECORD"; false; }

    rm -f "$RECORD"
    run dispatch "$harness_dir" clear
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$RECORD" ]
  done
}

@test "the hooks get the canonical project dir, the payload root and the launcher route's Git pins" {
  stub_context_hooks
  git -C "$SANDBOX/project" config core.fsmonitor "$SANDBOX/evil-monitor"
  for harness_dir in core-rules/hooks core-rules/codex/hooks; do
    rm -f "$RECORD"
    dispatch "$harness_dir" compact GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$SANDBOX/evil-hooks" >/dev/null
    case "$harness_dir" in
      core-rules/hooks) grep -qx "project=$SANDBOX/project" "$RECORD" || { cat "$RECORD"; false; } ;;
      *) grep -qx "project=codex:$SANDBOX/project" "$RECORD" || { cat "$RECORD"; false; } ;;
    esac
    grep -qx "root=$PAYLOAD" "$RECORD" || { cat "$RECORD"; false; }
    grep -qx "git=false:/dev/null:1:/dev/null" "$RECORD" || { cat "$RECORD"; false; }
  done
}

# The point of the dispatcher is that nothing a session used to receive is
# lost: its context is exactly what the hooks themselves produce.
@test "the dispatched context equals the real hooks' own contexts, joined" {
  local project="$SANDBOX/project" home="$SANDBOX/home" direct primer expected out var
  mkdir -p "$home" "$project/.claude/primers"
  git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  printf '# Context log\nprevious session notes\n' > "$project/context-log.md"
  printf '%s\n' '- [alpha](./alpha.md) — alpha primer' > "$project/.claude/primers/INDEX.md"
  printf -- '---\npinned_to: %s\n---\n## Entry points\n- context-log.md\n' "$(git -C "$project" rev-parse HEAD)" > "$project/.claude/primers/alpha.md"
  for harness_dir in core-rules/hooks core-rules/codex/hooks; do
    case "$harness_dir" in
      core-rules/hooks) var=CLAUDE_PROJECT_DIR ;;
      *) var=CODEX_PROJECT_DIR ;;
    esac
    direct="$(printf '{"source":"startup"}' | env -i HOME="$home" TRELLIS_HOME="$home/.trellis" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$var=$project" TRELLIS_ROOT="$PAYLOAD" "$PAYLOAD/$harness_dir/session-context.sh")"
    primer="$(printf '{"source":"startup"}' | env -i HOME="$home" TRELLIS_HOME="$home/.trellis" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$var=$project" TRELLIS_ROOT="$PAYLOAD" "$PAYLOAD/$harness_dir/inject-primer-index.sh")"
    [[ "$direct" == *"previous session notes"* ]] || { echo "$direct"; false; }
    [[ "$primer" == *"alpha"* ]] || { echo "$primer"; false; }
    expected="$(jq -n --argjson a "$direct" --argjson b "$primer" \
      '$a.hookSpecificOutput.additionalContext + "\n\n" + $b.hookSpecificOutput.additionalContext')"
    out="$(printf '{"source":"startup"}' | env -i HOME="$home" TRELLIS_HOME="$home/.trellis" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      /bin/bash --noprofile --norc "$PAYLOAD/$harness_dir/session-start.sh" "$project")"
    [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = SessionStart ]
    [ "$(printf '%s' "$out" | jq '.hookSpecificOutput.additionalContext')" = "$expected" ] ||
      { printf 'dispatched: %s\nexpected:   %s\n' "$(printf '%s' "$out" | jq '.hookSpecificOutput.additionalContext')" "$expected"; false; }
  done
}

# Review MEDIUM-1: one failing or malformed hook never costs the other its
# context, and its absence is named rather than silent.
@test "a failing or malformed hook is named and the other hook keeps its context" {
  local harness_dir ctx
  stub_context_hooks
  for harness_dir in core-rules/hooks core-rules/codex/hooks; do
    printf '#!/usr/bin/env bash\nprintf "not-json\\n"\n' > "$PAYLOAD/$harness_dir/inject-primer-index.sh"
    out="$(dispatch "$harness_dir" startup)"
    ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" || { echo "$harness_dir: $out"; false; }
    [ "$ctx" = $'session-context\n\nTrellis SessionStart: inject-primer-index.sh returned malformed output; its context is missing.' ] ||
      { echo "$harness_dir malformed: $out"; false; }

    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "{\\"hookSpecificOutput\\":{\\"additionalContext\\":\\"partial\\"}}"\nexit 3\n' > "$PAYLOAD/$harness_dir/session-context.sh"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "{\\"hookSpecificOutput\\":{\\"hookEventName\\":\\"SessionStart\\",\\"additionalContext\\":\\"primer\\"}}"\n' > "$PAYLOAD/$harness_dir/inject-primer-index.sh"
    out="$(dispatch "$harness_dir" startup)"
    ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" || { echo "$harness_dir: $out"; false; }
    [ "$ctx" = $'Trellis SessionStart: session-context.sh exited 3; its context is missing.\n\nprimer' ] ||
      { echo "$harness_dir failing: $out"; false; }
  done
}
