#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  INSTALLER="$REPO_ROOT/scripts/gptx/install.sh"
  SANDBOX="$(mktemp -d)"
  TEST_HOME="$SANDBOX/home"
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.cli-proxy-api" "$TEST_HOME/.codex"
  printf '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"200000"}}\n' \
    > "$TEST_HOME/.claude/settings.json"
  printf 'host: "127.0.0.1"\nport: 8317\n' > "$TEST_HOME/.cli-proxy-api/config.yaml"
  cp "$BATS_TEST_DIRNAME/fixtures/models-cache-272k.json" "$TEST_HOME/.codex/models_cache.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/cliproxyapi-trellis"
  chmod +x "$SANDBOX/cliproxyapi-trellis"
}

teardown() {
  if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then
    rm -rf "$SANDBOX"
  fi
}

run_installer() {
  env \
    HOME="$TEST_HOME" \
    CODEX_HOME="$TEST_HOME/.codex" \
    TRELLIS_GPTX_MANIFEST="$TEST_HOME/.trellis/gptx-install.json" \
    "$INSTALLER" \
    --proxy-bin "$SANDBOX/cliproxyapi-trellis" \
    --proxy-config "$TEST_HOME/.cli-proxy-api/config.yaml" \
    "$@"
}

@test "dry-run reports catalog context and does not change settings" {
  before="$(shasum -a 256 "$TEST_HOME/.claude/settings.json" | awk '{print $1}')"
  run run_installer --replace-running-proxy --dry-run
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_code_max_context_tokens' <<<"$output")" = 272000 ]
  [ "$(jq -r '.auto_compact_window' <<<"$output")" = unset ]
  [ "$(jq -r '.replace_running_proxy' <<<"$output")" = true ]
  after="$(shasum -a 256 "$TEST_HOME/.claude/settings.json" | awk '{print $1}')"
  [ "$before" = "$after" ]
  [ ! -e "$TEST_HOME/.trellis/gptx-install.json" ]
}

@test "no-start install is reversible and removes the global compact override" {
  run run_installer --no-start
  [ "$status" -eq 0 ]

  [ "$(jq -r '.env.ANTHROPIC_BASE_URL' "$TEST_HOME/.claude/settings.json")" \
    = "http://127.0.0.1:8318" ]
  [ "$(jq -r '.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS' "$TEST_HOME/.claude/settings.json")" \
    = 272000 ]
  [ "$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // "unset"' \
    "$TEST_HOME/.claude/settings.json")" = unset ]
  [ -L "$TEST_HOME/.local/bin/cmux-trellis-teams" ]
  [ -L "$TEST_HOME/.claude/agents/gpt-high.md" ]
  [ -x "$TEST_HOME/.local/libexec/trellis-cliproxyapi" ]
  [ -f "$TEST_HOME/.trellis/gptx-install.json" ]
  settings_backup="$(jq -r '.settings_backup' "$TEST_HOME/.trellis/gptx-install.json")"
  [ -f "$settings_backup" ]
  [ "$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$settings_backup")" = 200000 ]

  run run_installer --no-start
  [ "$status" -eq 0 ]
  [ "$(jq -r '.settings_backup' "$TEST_HOME/.trellis/gptx-install.json")" = "$settings_backup" ]
  [ "$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$settings_backup")" = 200000 ]
}
