#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  INSTALLER="$REPO_ROOT/scripts/gptx/install.sh"
  local temp_base="${TRELLIS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  SANDBOX="$(mktemp -d "$temp_base/gptx-install.XXXXXX")"
  TEST_HOME="$SANDBOX/home"
  FAKE_BIN="$SANDBOX/bin"
  COMMAND_LOG="$SANDBOX/platform-command.log"
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.cli-proxy-api" "$TEST_HOME/.codex" "$FAKE_BIN"
  printf '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"200000"}}\n' \
    > "$TEST_HOME/.claude/settings.json"
  printf 'host: "127.0.0.1"\nport: 8317\n' > "$TEST_HOME/.cli-proxy-api/config.yaml"
  cp "$BATS_TEST_DIRNAME/fixtures/models-cache-272k.json" "$TEST_HOME/.codex/models_cache.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/cliproxyapi-trellis"
  cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl|%s\n' "$*" >> "${TRELLIS_TEST_COMMAND_LOG:?}"
EOF
  cat > "$FAKE_BIN/brew" <<'EOF'
#!/usr/bin/env bash
printf 'brew|%s\n' "$*" >> "${TRELLIS_TEST_COMMAND_LOG:?}"
exit 0
EOF
  cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'uname|%s\n' "$*" >> "${TRELLIS_TEST_COMMAND_LOG:?}"
printf 'Darwin\n'
EOF
  chmod +x \
    "$SANDBOX/cliproxyapi-trellis" \
    "$FAKE_BIN/launchctl" \
    "$FAKE_BIN/brew" \
    "$FAKE_BIN/uname"
  : > "$COMMAND_LOG"
}

teardown() {
  if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then
    rm -rf "$SANDBOX"
  fi
}

run_installer() {
  env \
    HOME="$TEST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    CODEX_HOME="$TEST_HOME/.codex" \
    TRELLIS_GPTX_MANIFEST="$TEST_HOME/.trellis/gptx-install.json" \
    TRELLIS_TEST_COMMAND_LOG="$COMMAND_LOG" \
    "$INSTALLER" \
    --proxy-bin "$SANDBOX/cliproxyapi-trellis" \
    --proxy-config "$TEST_HOME/.cli-proxy-api/config.yaml" \
    "$@"
}

@test "dry-run reports context and reaches only fake uname and brew" {
  before="$(shasum -a 256 "$TEST_HOME/.claude/settings.json" | awk '{print $1}')"
  auto_compact_before="$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")"
  run run_installer --replace-running-proxy --dry-run
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_code_max_context_tokens' <<<"$output")" = 272000 ]
  [ "$(jq -r '.auto_compact_window' <<<"$output")" = preserved ]
  [ "$(jq -r '.policy_version' <<<"$output")" = 2 ]
  [[ "$(jq -r '.session_policy' <<<"$output")" == */scripts/gptx/session-policy.js ]]
  [[ "$(jq -r '.delegation_guard' <<<"$output")" == */scripts/gptx/delegation-guard.js ]]
  [ "$(jq -r '.replace_running_proxy' <<<"$output")" = true ]
  [ "$(jq -r '.proxy_policy.request_retry' <<<"$output")" = 1 ]
  [ "$(jq -r '.proxy_policy.disable_cooling' <<<"$output")" = false ]
  [ "$(jq -r '.proxy_policy.transient_error_cooldown_seconds' <<<"$output")" = -1 ]
  after="$(shasum -a 256 "$TEST_HOME/.claude/settings.json" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")" = "$auto_compact_before" ]
  [ ! -e "$TEST_HOME/.trellis/gptx-install.json" ]
  [ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" -eq 2 ]
  grep -Fx 'uname|-s' "$COMMAND_LOG"
  grep -Fx 'brew|services list' "$COMMAND_LOG"
  ! grep -q '^launchctl|' "$COMMAND_LOG"
}

@test "no-start install is reversible and all platform calls reach fakes" {
  proxy_before="$(shasum -a 256 "$TEST_HOME/.cli-proxy-api/config.yaml" | awk '{print $1}')"
  auto_compact_before="$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")"
  run run_installer --no-start
  [ "$status" -eq 0 ]

  [ "$(jq -r '.env.ANTHROPIC_BASE_URL' "$TEST_HOME/.claude/settings.json")" \
    = "http://127.0.0.1:8318" ]
  [ "$(jq -r '.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS' "$TEST_HOME/.claude/settings.json")" \
    = 272000 ]
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")" \
    = "$auto_compact_before" ]
  # The printed receipt must agree with what actually happened on disk. The original
  # defect shipped under a green suite because nothing compared the claim to the file:
  # the installer deleted this key while reporting it, and no test read either.
  # NOTE: use grep, not [[ ]]. A failing [[ ]] does NOT abort under `set -e` here, so
  # bats silently ignores it — verified: `bash -c 'set -e; [[ a == *X* ]]; echo R'` prints R.
  printf '%s\n' "$output" | grep -Fq 'AUTO_COMPACT_WINDOW preserved'
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")" != null ]
  [ -L "$TEST_HOME/.local/bin/cmux-trellis-teams" ]
  [ -L "$TEST_HOME/.claude/agents/gpt-high.md" ]
  # gpt-sol-reviewer was historically absent from the install loop, so the live copy was a
  # hand-placed file that drifted to a bare `model: gpt-5.6-sol`. That string is not in
  # EFFORT_BY_ALIAS, so the router injects nothing and the profile leans entirely on its
  # frontmatter `effort:`. Assert the aliased string so both mechanisms agree.
  [ -L "$TEST_HOME/.claude/agents/gpt-sol-reviewer.md" ]
  [ "$(awk '/^model:/{print $2; exit}' "$TEST_HOME/.claude/agents/gpt-sol-reviewer.md")" \
    = gpt-5.6-sol-xhigh ]
  # opus-advisor had the same problem and additionally had no canonical file at all.
  [ -L "$TEST_HOME/.claude/agents/opus-advisor.md" ]
  # fable-advisor pins a LITERAL claude-fable-5, not the `fable` alias slot. opus-advisor
  # declares the `opus` slot and was measured resolving to gpt-5.6-sol on 2 of 111 calls
  # (2026-07-31), which turns a cross-family reviewer into same-family review under a name
  # that still says otherwise. A literal has no alias step to lose.
  [ -L "$TEST_HOME/.claude/agents/fable-advisor.md" ]
  [ "$(awk '/^model:/{print $2; exit}' "$TEST_HOME/.claude/agents/fable-advisor.md")" \
    = claude-fable-5 ]
  # The install loop is an explicit list over a directory that is a superset, so a profile
  # added to core-rules/agents/ can be silently left undistributed. Pin the exception list:
  # anything canonical and not named here must be a deliberate non-GPTX rollout.
  for canonical in "$BATS_TEST_DIRNAME"/../../core-rules/agents/*.md; do
    name="$(basename "$canonical" .md)"
    case "$name" in
      codex-worker|lane-worker) continue ;;  # shipped by their own rollout scripts
    esac
    [ -L "$TEST_HOME/.claude/agents/$name.md" ] \
      || { echo "canonical agent not installed by gptx: $name"; false; }
  done
  # Every profile the loop installs must be a symlink; a regular file here means a
  # hand-placed copy that will drift from the repo, which is how both of the above began.
  for installed in "$TEST_HOME"/.claude/agents/*.md; do
    [ -L "$installed" ] || { echo "not a symlink: $installed"; false; }
  done
  [ -x "$TEST_HOME/.local/libexec/trellis-cliproxyapi" ]
  [ -f "$TEST_HOME/.trellis/gptx-install.json" ]
  [ "$(jq -r '.policy_version' "$TEST_HOME/.trellis/gptx-install.json")" = 2 ]
  [ -f "$(jq -r '.session_policy' "$TEST_HOME/.trellis/gptx-install.json")" ]
  [ -f "$(jq -r '.delegation_guard' "$TEST_HOME/.trellis/gptx-install.json")" ]
  [ "$(awk '$1=="request-retry:" {print $2}' "$TEST_HOME/.cli-proxy-api/config.yaml")" = 1 ]
  [ "$(awk '$1=="disable-cooling:" {print $2}' "$TEST_HOME/.cli-proxy-api/config.yaml")" = false ]
  [ "$(awk '$1=="transient-error-cooldown-seconds:" {print $2}' "$TEST_HOME/.cli-proxy-api/config.yaml")" = -1 ]
  settings_backup="$(jq -r '.settings_backup' "$TEST_HOME/.trellis/gptx-install.json")"
  proxy_backup="$(jq -r '.proxy_config_backup' "$TEST_HOME/.trellis/gptx-install.json")"
  [ -f "$settings_backup" ]
  [ -f "$proxy_backup" ]
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$settings_backup")" \
    = "$auto_compact_before" ]
  [ "$(shasum -a 256 "$proxy_backup" | awk '{print $1}')" = "$proxy_before" ]
  [ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" -eq 2 ]
  grep -Fx 'uname|-s' "$COMMAND_LOG"
  grep -Fx 'brew|services list' "$COMMAND_LOG"
  ! grep -q '^launchctl|' "$COMMAND_LOG"
  : > "$COMMAND_LOG"

  run run_installer --no-start
  [ "$status" -eq 0 ]
  [ "$(jq -r '.settings_backup' "$TEST_HOME/.trellis/gptx-install.json")" = "$settings_backup" ]
  [ "$(jq -r '.proxy_config_backup' "$TEST_HOME/.trellis/gptx-install.json")" = "$proxy_backup" ]
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")" \
    = "$auto_compact_before" ]
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$settings_backup")" \
    = "$auto_compact_before" ]
  [ "$(shasum -a 256 "$proxy_backup" | awk '{print $1}')" = "$proxy_before" ]
  [ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" -eq 2 ]
  grep -Fx 'uname|-s' "$COMMAND_LOG"
  grep -Fx 'brew|services list' "$COMMAND_LOG"
  ! grep -q '^launchctl|' "$COMMAND_LOG"
  : > "$COMMAND_LOG"

  run run_installer --uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -c '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TEST_HOME/.claude/settings.json")" \
    = "$auto_compact_before" ]
  [ "$(shasum -a 256 "$TEST_HOME/.cli-proxy-api/config.yaml" | awk '{print $1}')" = "$proxy_before" ]
  [ ! -e "$TEST_HOME/.trellis/gptx-install.json" ]
  [ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" -eq 2 ]
  grep -Fx "launchctl|bootout gui/$(id -u)/dev.trellis.gptx-router" "$COMMAND_LOG"
  grep -Fx "launchctl|bootout gui/$(id -u)/dev.trellis.cliproxyapi" "$COMMAND_LOG"
  ! grep -Eq '^(brew|uname)\|' "$COMMAND_LOG"
}
