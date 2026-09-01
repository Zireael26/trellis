#!/usr/bin/env bats

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture

canonical_dir() {
  (CDPATH='' cd "$1" && pwd -P)
}

sha256_file() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

file_mode() {
  local candidate
  candidate="$(stat -f %Lp "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %a "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

file_identity() {
  local candidate
  candidate="$(stat -c '%d:%i' "$1" 2>/dev/null)" ||
    candidate="$(stat -f '%d:%i' "$1")" || return 1
  printf '%s\n' "$candidate"
}

user_owner_path() {
  printf '%s/attachments/user.json\n' "$TRELLIS_HOME"
}

user_attach_journal_path() {
  printf '%s/state/user-attachment-journals/attach.json\n' "$TRELLIS_HOME"
}

user_detach_journal_path() {
  printf '%s/state/user-attachment-journals/detach.json\n' "$TRELLIS_HOME"
}

installed_attach() {
  printf '%s/releases/%s/payload/scripts/attach-project.sh\n' "$TRELLIS_HOME" "$1"
}

installed_configure() {
  printf '%s/releases/%s/payload/scripts/configure.sh\n' "$TRELLIS_HOME" "$1"
}

user_attach() {
  run "$USER_CLI" attach --user --home "$TRELLIS_HOME" --release "$USER_RELEASE"
}

user_attach_adopt_identical() {
  run "$USER_CLI" attach --user --adopt-identical --home "$TRELLIS_HOME" --release "$USER_RELEASE"
}

user_detach() {
  run "$USER_CLI" detach --user --home "$TRELLIS_HOME"
}

make_configure_source() {
  local source="$SANDBOX/configure source"
  mkdir -p "$source/core-rules" "$source/scripts"
  printf '{}\n' > "$source/trellis.config.json"
  printf '2.0.0\n' > "$source/core-rules/VERSION"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$source/scripts/trellis-launcher.sh"
  chmod 755 "$source/scripts/trellis-launcher.sh"
  printf '%s\n' "$source"
}

assert_output_has() {
  local text="$1" needle="$2"
  case "$text" in
    *"$needle"*) return 0 ;;
    *) printf 'expected output to contain %s, got:\n%s\n' "$needle" "$text" >&2; return 1 ;;
  esac
}

copy_user_release_runtime() {
  local repo="$1"
  mkdir -p "$repo/scripts"
  cp "$REPO_ROOT/scripts/trellis" "$repo/scripts/trellis"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/configure.sh" "$repo/scripts/configure.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp "$REPO_ROOT/scripts/release.sh" "$repo/scripts/release.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/"
  chmod 755 "$repo/scripts/trellis" "$repo/scripts/attach-project.sh" \
    "$repo/scripts/configure.sh" "$repo/scripts/trellis-launcher.sh" "$repo/scripts/release.sh"
}

make_user_release() {
  local version="$1" include_new="${2:-false}" include_rules="${3:-true}" agents_kind="${4:-symlink}"
  local include_second_render="${5:-false}" repo
  case "$agents_kind" in
    file|symlink) ;;
    *) return 1 ;;
  esac
  repo="$SANDBOX/release source $version"

  mkdir -p "$repo/core-rules/omp/global" "$repo/core-rules/templates"
  copy_user_release_runtime "$repo"

  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  printf 'fixture user AGENTS for release %s\n' "$version" > "$repo/core-rules/omp/global/AGENTS.md"
  printf 'fixture user RULES for release %s\n' "$version" > "$repo/core-rules/omp/global/RULES.md"
  if [ "$include_new" = true ]; then
    printf 'new fixture user leaf from release %s\n' "$version" > "$repo/core-rules/omp/global/new-leaf.md"
  fi
  jq -n --arg release "$version" '{
    managed: {release: $release, policy: "fixture"},
    hooks: {
      SessionStart: [
        {
          matcher: "*",
          hooks: [
            {
              type: "command",
              command: "fixture Trellis SessionStart",
              timeout: 60
            }
          ]
        }
      ]
    }
  }' > "$repo/core-rules/templates/claude-user-settings.json"
  jq -n --arg release "$version" '{managed: {codex_release: $release}}' \
    > "$repo/core-rules/templates/codex-user-settings.json"

  jq -n --arg agents_kind "$agents_kind" --argjson include_new "$include_new" \
    --argjson include_rules "$include_rules" --argjson include_second_render "$include_second_render" '{
    schema_version: 1,
    harnesses: {
      claude: {links: [], render: []},
      codex: {links: [], render: []},
      omp: {links: [], render: []},
      user: {
        links: (
          (if $agents_kind == "symlink" then [
            {source: "core-rules/omp/global/AGENTS.md", destination: ".omp/agent/AGENTS.md", destination_home: true}
          ] else [] end)
          + (if $include_rules then [
            {source: "core-rules/omp/global/RULES.md", destination: ".omp/agent/RULES.md", destination_home: true}
          ] else [] end)
          + (if $include_new then [
            {source: "core-rules/omp/global/new-leaf.md", destination: ".omp/agent/new-leaf.md", destination_home: true}
          ] else [] end)
        ),
        render: (
          (if $agents_kind == "file" then [
            {template: "core-rules/omp/global/AGENTS.md", destination: ".omp/agent/AGENTS.md", destination_home: true, merge: "replace", mode: "0600", required: true}
          ] else [] end)
          + [
            {template: "core-rules/templates/claude-user-settings.json", destination: ".claude/settings.json", destination_home: true, merge: "explicit-json", mode: "0600", required: true}
          ]
          + (if $include_second_render then [
            {template: "core-rules/templates/codex-user-settings.json", destination: ".codex/settings.json", destination_home: true, merge: "explicit-json", mode: "0600", required: true}
          ] else [] end)
        )
      }
    }
  }' > "$repo/core-rules/inheritance-manifest.json"

  release_fixture_install "$HOME" "$TRELLIS_HOME" "$version" "$repo"
}

make_full_user_release() {
  local version="$1" changed="${2:-false}" repo
  repo="$SANDBOX/full release source $version"
  mkdir -p "$repo"
  cp -R "$REPO_ROOT/core-rules" "$repo/"
  copy_user_release_runtime "$repo"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  if [ "$changed" = true ]; then
    rm "$repo/core-rules/omp/global/agents/cheap.md"
    printf 'fixture added agent for release %s\n' "$version" \
      > "$repo/core-rules/omp/global/agents/fixture-added.md"
  fi
  release_fixture_install "$HOME" "$TRELLIS_HOME" "$version" "$repo"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-user-surface.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/operator home with spaces"
  export TRELLIS_HOME="$SANDBOX/machine home with spaces"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  HOME="$(canonical_dir "$HOME")"
  TRELLIS_HOME="$(canonical_dir "$TRELLIS_HOME")"
  export HOME TRELLIS_HOME

  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  USER_CLI="$RELEASE_FIXTURE_LAUNCHER"
  USER_RELEASE=1.0.0
  export USER_CLI USER_RELEASE
  make_user_release "$USER_RELEASE" false
  jq --arg release "$USER_RELEASE" '.active_cli_release = $release' \
    "$TRELLIS_HOME/config.json" > "$TRELLIS_HOME/config.json.tmp"
  mv "$TRELLIS_HOME/config.json.tmp" "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"

  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "operator": {
    "theme": "dark",
    "keep": true
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "operator-owned pre-tool hook"
          }
        ]
      }
    ]
  }
}
JSON
  chmod 640 "$HOME/.claude/settings.json"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

@test "attach --user creates release-backed leaves and a committed user owner" {
  user_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.omp/agent/AGENTS.md" ]
  [ -L "$HOME/.omp/agent/RULES.md" ]
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/AGENTS.md" ]
  [ "$(readlink "$HOME/.omp/agent/RULES.md")" = "$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/RULES.md" ]
  jq -e '
    .operator.theme == "dark" and
    .operator.keep == true and
    .managed.release == "1.0.0" and
    .managed.policy == "fixture" and
    .hooks.PreToolUse[0].hooks[0].command == "operator-owned pre-tool hook" and
    .hooks.SessionStart[0].hooks[0].command == "fixture Trellis SessionStart" and
    (.hooks | keys) == ["PreToolUse", "SessionStart"]
  ' "$HOME/.claude/settings.json" >/dev/null

  owner="$(user_owner_path)"
  [ -f "$owner" ]
  [ "$(file_mode "$owner")" = 600 ]
  jq -e --arg home "$HOME" '
    .schema_version == 1 and
    .surface == "user" and
    .status == "committed" and
    .home_paths == [$home] and
    ([.artifacts[] | select(.destination == ($home + "/.omp/agent/AGENTS.md") and .kind == "symlink")] | length) == 1 and
    ([.renders[] | select(.destination == ($home + "/.claude/settings.json") and .merge == "explicit-json")] | length) == 1
  ' "$owner" >/dev/null
}

@test "full user payload installs the Claude orchestration output style contract" {
  local version=5.0.0 manifest style settings owner style_body directive
  version="5.0.0"
  make_full_user_release "$version"
  manifest="$TRELLIS_HOME/releases/$version/payload/core-rules/inheritance-manifest.json"
  style="$TRELLIS_HOME/releases/$version/payload/core-rules/templates/claude-output-styles/trellis-orchestration.md"
  settings="$HOME/.claude/settings.json"

  jq -e '
    ([.harnesses.user.links[] |
      select(
        .source == "core-rules/templates/claude-output-styles/trellis-orchestration.md"
        and .destination == ".claude/output-styles/trellis-orchestration.md"
        and .destination_home == true
      )
    ] | length) == 1
  ' "$manifest" >/dev/null
  [ "$(sed -n '1p' "$style")" = "---" ]
  [ "$(sed -n '2p' "$style")" = "name: Trellis Orchestration" ]
  [ "$(sed -n '3p' "$style")" = "description: Dispatch independent work concurrently while keeping linear and mechanical tasks inline." ]
  [ "$(sed -n '4p' "$style")" = "keep-coding-instructions: true" ]
  [ "$(sed -n '5p' "$style")" = "---" ]
  style_body="$(cat "$style")"
  directive="Standing orchestration rule: when a request lists 2+ independent targets (files, projects, skills, questions), dispatch one concurrent Agent per target after shared discovery, rather than processing the targets inline. If concurrency is impossible, state why."
  if [[ "$style_body" != *"$directive"* ]]; then
    echo "missing orchestration directive"
    false
  fi
  if [[ "$style_body" != *"single linear unit stays inline"*
      || "$style_body" != *"one cross-repo symbol rename"*
      || "$style_body" != *"one failing test"*
      || "$style_body" != *"set-wide mechanical work needing no per-item model judgment stays inline"* ]]; then
    echo "missing inline guards"
    false
  fi

  run "$USER_CLI" attach --user --home "$TRELLIS_HOME" --release "$version"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.claude/output-styles/trellis-orchestration.md" ]
  [ "$(readlink "$HOME/.claude/output-styles/trellis-orchestration.md")" = "$style" ]
  jq -e '.outputStyle == "Trellis Orchestration"' "$settings" >/dev/null

  owner="$(user_owner_path)"
  jq -e --arg destination "$HOME/.claude/output-styles/trellis-orchestration.md" '
    ([.artifacts[] | select(.destination == $destination and .kind == "symlink")] | length) == 1
  ' "$owner" >/dev/null
}

@test "attach --user is idempotent for an existing exact committed desired state" {
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(user_owner_path)"
  first_owner_hash="$(sha256_file "$owner")"
  first_settings_hash="$(sha256_file "$HOME/.claude/settings.json")"
  first_agents_target="$(readlink "$HOME/.omp/agent/AGENTS.md")"
  first_rules_target="$(readlink "$HOME/.omp/agent/RULES.md")"

  user_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$owner")" = "$first_owner_hash" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$first_settings_hash" ]
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$first_agents_target" ]
  [ "$(readlink "$HOME/.omp/agent/RULES.md")" = "$first_rules_target" ]
}

@test "attach --user refuses an exact desired leaf when its committed owner is absent" {
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$(user_owner_path)"
  exact_target="$(readlink "$HOME/.omp/agent/AGENTS.md")"
  exact_hash="$(sha256_file "$HOME/.omp/agent/AGENTS.md")"
  rm "$owner" "$HOME/.claude/settings.json" "$HOME/.omp/agent/RULES.md"

  user_attach

  [ "$status" -eq 3 ]
  assert_output_has "$output" "$HOME/.omp/agent/AGENTS.md"
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$exact_target" ]
  [ "$(sha256_file "$HOME/.omp/agent/AGENTS.md")" = "$exact_hash" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "project selector usage rejection happens before HOME-state mutation and accepts -- as delimiter" {
  local unused_home="$SANDBOX/unused selector home" uninspected_path="--user"

  run "$(installed_attach "$USER_RELEASE")" detach \
    --home "$unused_home" \
    --harness user \
    -- "$uninspected_path"

  [ "$status" -eq 2 ] || { echo "$output"; false; }
  assert_output_has "$output" "project --harness user is invalid"
  [ ! -e "$unused_home" ]
  [ ! -L "$unused_home" ]
}


@test "attach --user refuses an unowned destination with exit 3 and its absolute path" {
  mkdir -p "$HOME/.omp/agent"
  printf 'operator-owned AGENTS\n' > "$HOME/.omp/agent/AGENTS.md"
  before="$(sha256_file "$HOME/.omp/agent/AGENTS.md")"
  settings_before="$(sha256_file "$HOME/.claude/settings.json")"

  user_attach

  [ "$status" -eq 3 ]
  assert_output_has "$output" "$HOME/.omp/agent/AGENTS.md"
  [ "$(sha256_file "$HOME/.omp/agent/AGENTS.md")" = "$before" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
  owner="$(user_owner_path)"
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "attach --user explicit-json merge preserves operator keys" {
  operator_before="$(jq -cS '.operator' "$HOME/.claude/settings.json")"
  operator_hook_before="$(jq -cS '.hooks.PreToolUse' "$HOME/.claude/settings.json")"

  user_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -cS '.operator' "$HOME/.claude/settings.json")" = "$operator_before" ]
  [ "$(jq -cS '.hooks.PreToolUse' "$HOME/.claude/settings.json")" = "$operator_hook_before" ]
  jq -e '
    .operator.theme == "dark" and
    .operator.keep == true and
    .managed.release == "1.0.0" and
    .hooks.SessionStart[0].hooks[0].command == "fixture Trellis SessionStart" and
    (.hooks | keys) == ["PreToolUse", "SessionStart"]
  ' "$HOME/.claude/settings.json" >/dev/null
  [ "$(file_mode "$HOME/.claude/settings.json")" = 600 ]
}

@test "attach --user rejects a destination whose parent escapes HOME" {
  outside="$SANDBOX/outside user destination"
  mkdir -p "$outside"
  ln -s "$outside" "$HOME/.omp"

  user_attach

  [ "$status" -eq 4 ]
  assert_output_has "$output" "HOME"
  assert_output_has "$output" "escapes"
  [ ! -e "$outside/agent/AGENTS.md" ]
  [ ! -e "$outside/agent/RULES.md" ]
  owner="$(user_owner_path)"
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "detach --user removes owned leaves and restores the exact pre-attach render" {
  before_hash="$(sha256_file "$HOME/.claude/settings.json")"
  before_mode="$(file_mode "$HOME/.claude/settings.json")"

  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -L "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$before_hash" ]
  [ "$(file_mode "$HOME/.claude/settings.json")" = "$before_mode" ]
  owner="$(user_owner_path)"
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]

  user_detach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "detach --user inverse-merges rendered keys while preserving operator edits" {
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  edited="$HOME/.claude/settings.json.edited"
  jq '.operator.after_attach = "keep"' "$HOME/.claude/settings.json" > "$edited"
  chmod 600 "$edited"
  mv "$edited" "$HOME/.claude/settings.json"

  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '
    .operator.theme == "dark" and
    .operator.keep == true and
    .operator.after_attach == "keep" and
    .hooks.PreToolUse[0].hooks[0].command == "operator-owned pre-tool hook" and
    (.hooks.SessionStart | not) and
    (.managed | not)
  ' "$HOME/.claude/settings.json" >/dev/null
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$(user_owner_path)" ]
}

@test "relink --user adopts a replacement release and materializes its new leaf" {
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false

  run "$USER_CLI" relink --user --home "$TRELLIS_HOME" --release 2.0.0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.omp/agent/AGENTS.md" ]
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/2.0.0/payload/core-rules/omp/global/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ -L "$HOME/.omp/agent/new-leaf.md" ]
  [ "$(readlink "$HOME/.omp/agent/new-leaf.md")" = "$TRELLIS_HOME/releases/2.0.0/payload/core-rules/omp/global/new-leaf.md" ]
  jq -e '
    .operator.theme == "dark" and
    .operator.keep == true and
    .managed.release == "2.0.0" and
    .hooks.PreToolUse[0].hooks[0].command == "operator-owned pre-tool hook" and
    .hooks.SessionStart[0].hooks[0].command == "fixture Trellis SessionStart" and
    (.hooks | keys) == ["PreToolUse", "SessionStart"]
  ' "$HOME/.claude/settings.json" >/dev/null
  jq -e --arg home "$HOME" '
    .surface == "user" and .status == "committed" and .release == "2.0.0" and
    ([.artifacts[] | select(.destination == ($home + "/.omp/agent/new-leaf.md") and .kind == "symlink")] | length) == 1
  ' "$(user_owner_path)" >/dev/null
}

@test "installed full user payload relinks expanded file and directory leaves and detaches cleanly" {
  make_full_user_release 3.0.0 false
  mkdir -p "$HOME/.omp/agent/skills"
  cp -R "$TRELLIS_HOME/releases/3.0.0/payload/core-rules/omp/global/skills/eval-workflow" \
    "$HOME/.omp/agent/skills/eval-workflow"

  run "$USER_CLI" attach --user --adopt-identical --home "$TRELLIS_HOME" --release 3.0.0

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  assert_output_has "$output" "cannot safely adopt a directory"
  [ -f "$HOME/.omp/agent/skills/eval-workflow/SKILL.md" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  chmod -R u+w "$HOME/.omp/agent/skills/eval-workflow"
  rm -rf "$HOME/.omp/agent/skills/eval-workflow"
  rmdir "$HOME/.omp/agent/skills" "$HOME/.omp/agent" "$HOME/.omp"

  run "$USER_CLI" attach --user --home "$TRELLIS_HOME" --release 3.0.0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.omp/agent/AGENTS.md" ]
  [ -L "$HOME/.omp/agent/agents/cheap.md" ]
  [ -L "$HOME/.omp/agent/skills/eval-workflow" ]
  [ -L "$HOME/.claude/skills/herdr-foreman" ]
  [ -L "$HOME/.claude/hooks/herdr-foreman-session.sh" ]
  [ "$(readlink "$HOME/.omp/agent/skills/eval-workflow")" = "$TRELLIS_HOME/releases/3.0.0/payload/core-rules/omp/global/skills/eval-workflow" ]
  [ "$(readlink "$HOME/.claude/skills/herdr-foreman")" = "$TRELLIS_HOME/releases/3.0.0/payload/core-rules/skills/herdr-foreman" ]

  make_full_user_release 4.0.0 true
  run "$USER_CLI" relink --user --home "$TRELLIS_HOME" --release 4.0.0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOME/.omp/agent/agents/cheap.md" ]
  [ ! -L "$HOME/.omp/agent/agents/cheap.md" ]
  [ -L "$HOME/.omp/agent/agents/fixture-added.md" ]
  [ "$(readlink "$HOME/.omp/agent/agents/fixture-added.md")" = "$TRELLIS_HOME/releases/4.0.0/payload/core-rules/omp/global/agents/fixture-added.md" ]
  [ "$(readlink "$HOME/.omp/agent/skills/eval-workflow")" = "$TRELLIS_HOME/releases/4.0.0/payload/core-rules/omp/global/skills/eval-workflow" ]
  [ "$(readlink "$HOME/.claude/skills/herdr-foreman")" = "$TRELLIS_HOME/releases/4.0.0/payload/core-rules/skills/herdr-foreman" ]
  [ "$(readlink "$HOME/.claude/hooks/herdr-foreman-session.sh")" = "$TRELLIS_HOME/releases/4.0.0/payload/core-rules/hooks/herdr-foreman-session.sh" ]
  jq -e '.release == "4.0.0"' "$(user_owner_path)" >/dev/null

  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOME/.omp" ]
  [ ! -L "$HOME/.omp" ]
  [ ! -e "$HOME/.claude/skills" ]
  [ ! -e "$HOME/.claude/hooks" ]
  [ ! -e "$(user_owner_path)" ]
}

@test "configure --release relinks an attached user surface through the adopted payload" {
  local configure_source owner
  configure_source="$(make_configure_source)"
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false

  run "$USER_CLI" configure \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0 \
    --no-install-launcher

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.active_cli_release == "2.0.0"' "$TRELLIS_HOME/config.json" >/dev/null
  [ -L "$HOME/.omp/agent/AGENTS.md" ]
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/2.0.0/payload/core-rules/omp/global/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ -L "$HOME/.omp/agent/new-leaf.md" ]
  [ "$(readlink "$HOME/.omp/agent/new-leaf.md")" = "$TRELLIS_HOME/releases/2.0.0/payload/core-rules/omp/global/new-leaf.md" ]
  jq -e '.managed.release == "2.0.0"' "$HOME/.claude/settings.json" >/dev/null
  owner="$(user_owner_path)"
  jq -e '.surface == "user" and .status == "committed" and .release == "2.0.0"' "$owner" >/dev/null
}

@test "configure --release advances an unattached home without creating user artifacts" {
  local configure_source settings_before owner
  configure_source="$(make_configure_source)"
  make_user_release 2.0.0 true false
  settings_before="$(sha256_file "$HOME/.claude/settings.json")"

  run "$USER_CLI" configure \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0 \
    --no-install-launcher

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.active_cli_release == "2.0.0"' "$TRELLIS_HOME/config.json" >/dev/null
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
  owner="$(user_owner_path)"
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -L "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$HOME/.omp/agent/new-leaf.md" ]
  [ ! -L "$HOME/.omp/agent/new-leaf.md" ]
}

@test "configure --release restores config and the old user surface when relink fails" {
  local configure_source owner config_before owner_before settings_before
  configure_source="$(make_configure_source)"
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false
  owner="$(user_owner_path)"
  config_before="$SANDBOX/config.before"
  owner_before="$(sha256_file "$owner")"
  settings_before="$(sha256_file "$HOME/.claude/settings.json")"
  cp "$TRELLIS_HOME/config.json" "$config_before"

  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_configure "$USER_RELEASE")" \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0 \
    --no-install-launcher

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  run cmp -s "$config_before" "$TRELLIS_HOME/config.json"
  [ "$status" -eq 0 ]
  [ "$(sha256_file "$owner")" = "$owner_before" ]
  jq -e '.surface == "user" and .status == "committed" and .release == "1.0.0"' "$owner" >/dev/null
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/AGENTS.md" ]
  [ "$(readlink "$HOME/.omp/agent/RULES.md")" = "$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/RULES.md" ]
  [ ! -e "$HOME/.omp/agent/new-leaf.md" ]
  [ ! -L "$HOME/.omp/agent/new-leaf.md" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
}

@test "configure finalizes an owner-published relink and keeps config and user ownership aligned" {
  local configure_source owner
  configure_source="$(make_configure_source)"
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false

  run env ATTACHMENT_FAULT_PHASE=owner-published "$(installed_configure "$USER_RELEASE")" \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0 \
    --no-install-launcher

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.active_cli_release == "2.0.0"' "$TRELLIS_HOME/config.json" >/dev/null
  owner="$(user_owner_path)"
  jq -e '.surface == "user" and .status == "committed" and .release == "2.0.0"' "$owner" >/dev/null
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/2.0.0/payload/core-rules/omp/global/AGENTS.md" ]
  [ -L "$HOME/.omp/agent/new-leaf.md" ]
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -L "$(user_attach_journal_path)" ]
  [ ! -e "$(user_detach_journal_path)" ]
  [ ! -L "$(user_detach_journal_path)" ]
}

@test "configure compensates a partial old-user detach and preserves the initiating status" {
  local configure_source owner config_before owner_before settings_before
  configure_source="$(make_configure_source)"
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false
  owner="$(user_owner_path)"
  config_before="$SANDBOX/detach-fault.config.before"
  cp "$TRELLIS_HOME/config.json" "$config_before"
  owner_before="$(sha256_file "$owner")"
  settings_before="$(sha256_file "$HOME/.claude/settings.json")"

  run env ATTACHMENT_FAULT_PHASE=user-detach-1 "$(installed_configure "$USER_RELEASE")" \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0 \
    --no-install-launcher

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  run cmp -s "$config_before" "$TRELLIS_HOME/config.json"
  [ "$status" -eq 0 ]
  [ "$(sha256_file "$owner")" = "$owner_before" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/AGENTS.md" ]
  [ "$(readlink "$HOME/.omp/agent/RULES.md")" = "$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/RULES.md" ]
  [ ! -e "$HOME/.omp/agent/new-leaf.md" ]
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -e "$(user_detach_journal_path)" ]
}

@test "configure restores retained launcher bytes and mode when relink fails" {
  local configure_source launcher launcher_before launcher_mode_before config_before
  configure_source="$(make_configure_source)"
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false
  launcher="$HOME/.local/bin/trellis"
  chmod 700 "$launcher"
  launcher_before="$(sha256_file "$launcher")"
  launcher_mode_before="$(file_mode "$launcher")"
  config_before="$SANDBOX/launcher.config.before"
  cp "$TRELLIS_HOME/config.json" "$config_before"

  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_configure "$USER_RELEASE")" \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ "$(sha256_file "$launcher")" = "$launcher_before" ]
  [ "$(file_mode "$launcher")" = "$launcher_mode_before" ]
  run cmp -s "$config_before" "$TRELLIS_HOME/config.json"
  [ "$status" -eq 0 ]
  jq -e '.release == "1.0.0"' "$(user_owner_path)" >/dev/null
}

@test "configure removes a newly installed launcher and its new parent directories when relink fails" {
  local configure_source configure_command config_before
  configure_source="$(make_configure_source)"
  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false
  configure_command="$(installed_configure "$USER_RELEASE")"
  config_before="$SANDBOX/new-launcher.config.before"
  cp "$TRELLIS_HOME/config.json" "$config_before"
  rm "$HOME/.local/bin/trellis"
  rmdir "$HOME/.local/bin" "$HOME/.local"

  run env ATTACHMENT_FAULT_PHASE=1 "$configure_command" \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ ! -e "$HOME/.local/bin/trellis" ]
  [ ! -L "$HOME/.local/bin/trellis" ]
  [ ! -e "$HOME/.local/bin" ]
  [ ! -e "$HOME/.local" ]
  run cmp -s "$config_before" "$TRELLIS_HOME/config.json"
  [ "$status" -eq 0 ]
  jq -e '.release == "1.0.0"' "$(user_owner_path)" >/dev/null
}

@test "configure help succeeds without creating its temporary directory" {
  local missing_tmp="$SANDBOX/help must not create tmp"

  run env TMPDIR="$missing_tmp" "$(installed_configure "$USER_RELEASE")" configure --help

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "$output" "trellis configure"
  [ ! -e "$missing_tmp" ]
  [ ! -L "$missing_tmp" ]
}

@test "configure recovers an owner-absent pending user journal before deciding attachment state" {
  local configure_source
  configure_source="$(make_configure_source)"
  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_attach "$USER_RELEASE")" \
    attach --user --home "$TRELLIS_HOME" --release "$USER_RELEASE"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$(user_attach_journal_path)" ]
  [ ! -e "$(user_owner_path)" ]
  make_user_release 2.0.0 true false

  run "$USER_CLI" configure \
    --source "$configure_source" \
    --home "$TRELLIS_HOME" \
    --release 2.0.0 \
    --no-install-launcher

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -e "$(user_detach_journal_path)" ]
  jq -e '.active_cli_release == "2.0.0"' "$TRELLIS_HOME/config.json" >/dev/null
  jq -e '.release == "2.0.0"' "$(user_owner_path)" >/dev/null
  [ "$(readlink "$HOME/.omp/agent/AGENTS.md")" = "$TRELLIS_HOME/releases/2.0.0/payload/core-rules/omp/global/AGENTS.md" ]
}

@test "attach --user retry recovers an interrupted transaction" {
  run env ATTACHMENT_FAULT_PHASE=owner-published "$(installed_attach "$USER_RELEASE")" \
    attach --user --home "$TRELLIS_HOME" --release "$USER_RELEASE"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$(user_attach_journal_path)" ]
  [ -f "$(user_owner_path)" ]
  [ -L "$HOME/.omp/agent/AGENTS.md" ]
  [ -L "$HOME/.omp/agent/RULES.md" ]
  user_attach
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -L "$(user_attach_journal_path)" ]

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$HOME/.omp/agent/AGENTS.md" ]
  [ -f "$(user_owner_path)" ]
  jq -e '.surface == "user" and .status == "committed" and .release == "1.0.0"' \
    "$(user_owner_path)" >/dev/null
}

@test "attach --user cleans a staged replacement before its destination identity is recorded" {
  local settings before_hash before_mode before_base64
  settings="$HOME/.claude/settings.json"
  before_hash="$(sha256_file "$settings")"
  before_mode="$(file_mode "$settings")"
  before_base64="$(base64 < "$settings" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=user-replace-staged "$(installed_attach "$USER_RELEASE")" \
    attach --user --home "$TRELLIS_HOME" --release "$USER_RELEASE"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(file_mode "$settings")" = "$before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -L "$(user_attach_journal_path)" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  [ ! -e "$HOME/.omp" ]
  [ ! -L "$HOME/.omp" ]
  ! compgen -G "$HOME/.claude/.settings.json.user-attachment-stage-*" >/dev/null

  user_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  user_detach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(file_mode "$settings")" = "$before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
}

@test "attach --user preserves a phase>0 replacement conflict for correction and retry" {
  local release=2.0.0 agents settings codex_settings journal stage
  local settings_before_hash settings_before_mode settings_before_base64
  local codex_before_hash codex_before_mode codex_before_base64
  local settings_managed_hash settings_managed_base64 settings_managed_mode settings_unknown_base64 settings_unknown_mode

  make_user_release "$release" false false file true
  agents="$HOME/.omp/agent/AGENTS.md"
  settings="$HOME/.claude/settings.json"
  codex_settings="$HOME/.codex/settings.json"
  journal="$(user_attach_journal_path)"
  mkdir -p "$(dirname "$agents")" "$(dirname "$codex_settings")"
  cat > "$codex_settings" <<'JSON'
{
  "operator": {
    "keep": "codex"
  }
}
JSON
  chmod 640 "$codex_settings"
  settings_before_hash="$(sha256_file "$settings")"
  settings_before_mode="$(file_mode "$settings")"
  settings_before_base64="$(base64 < "$settings" | tr -d '\n')"
  codex_before_hash="$(sha256_file "$codex_settings")"
  codex_before_mode="$(file_mode "$codex_settings")"
  codex_before_base64="$(base64 < "$codex_settings" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  jq -e --arg agents "$agents" --arg settings "$settings" --arg codex "$codex_settings" '
    .phase == 1 and .pending == null
      and (.artifacts | length) == 3
      and .artifacts[0].destination == $settings and (.artifacts[0] | has("replace"))
      and .artifacts[1].destination == $codex and (.artifacts[1] | has("replace"))
      and .artifacts[2].destination == $agents
  ' "$journal" >/dev/null
  settings_managed_hash="$(sha256_file "$settings")"
  settings_managed_base64="$(base64 < "$settings" | tr -d '\n')"
  settings_managed_mode="$(file_mode "$settings")"
  [ "$settings_managed_mode" = 600 ]
  printf '{\n  "operator": {\n    "manual": "unknown"\n  }\n}\n' > "$settings"
  chmod 640 "$settings"
  settings_unknown_base64="$(base64 < "$settings" | tr -d '\n')"
  settings_unknown_mode="$(file_mode "$settings")"

  run env ATTACHMENT_FAULT_PHASE=user-replace-staged "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  assert_output_has "$output" "managed file $settings no longer has its pinned filesystem identity"
  assert_output_has "$output" "Unknown bytes were preserved"
  assert_output_has "$output" "user attachment recovery remedy:"
  assert_output_has "$output" "then rerun: trellis attach --user --home"
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_unknown_base64" ]
  [ "$(file_mode "$settings")" = "$settings_unknown_mode" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ -f "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  jq -e --arg settings "$settings" --arg codex "$codex_settings" '
    .phase == 1 and .pending != null
      and .pending.artifact.destination == $codex
      and .pending.destination_identity == null
      and (.pending.staging_identity | type == "string" and length > 0)
      and (.identities | length) == 1
      and .artifacts[0].destination == $settings
  ' "$journal" >/dev/null
  stage="$(jq -r '.pending.staging_path' "$journal")"
  [ -f "$stage" ]
  [ ! -L "$stage" ]

  if ! printf '%s' "$settings_managed_base64" | base64 -D > "$settings" 2>/dev/null; then
    printf '%s' "$settings_managed_base64" | base64 -d > "$settings"
  fi
  chmod "$settings_managed_mode" "$settings"
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_managed_base64" ]
  [ "$(file_mode "$settings")" = "$settings_managed_mode" ]

  run "$(installed_attach "$release")" attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$stage" ]
  [ ! -L "$stage" ]
  [ -f "$(user_owner_path)" ]
  jq -e --arg release "$release" '.release == $release' "$(user_owner_path)" >/dev/null

  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

@test "attach --user rollback durably records reverse progress before a lower conflict" {
  local release=2.0.0 agents settings codex_settings journal lower_identity
  local settings_before_hash settings_before_mode settings_before_base64
  local codex_before_hash codex_before_mode codex_before_base64
  local settings_managed_hash settings_managed_mode settings_managed_base64
  local settings_unknown_hash settings_unknown_mode settings_unknown_base64

  make_user_release "$release" false false file true
  agents="$HOME/.omp/agent/AGENTS.md"
  settings="$HOME/.claude/settings.json"
  codex_settings="$HOME/.codex/settings.json"
  journal="$(user_attach_journal_path)"
  mkdir -p "$(dirname "$agents")" "$(dirname "$codex_settings")"
  cat > "$codex_settings" <<'JSON'
{
  "operator": {
    "keep": "codex"
  }
}
JSON
  chmod 640 "$codex_settings"
  settings_before_hash="$(sha256_file "$settings")"
  settings_before_mode="$(file_mode "$settings")"
  settings_before_base64="$(base64 < "$settings" | tr -d '\n')"
  codex_before_hash="$(sha256_file "$codex_settings")"
  codex_before_mode="$(file_mode "$codex_settings")"
  codex_before_base64="$(base64 < "$codex_settings" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=2 "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$journal" ]
  lower_identity="$(jq -r '.identities[0]' "$journal")"
  settings_managed_hash="$(sha256_file "$settings")"
  settings_managed_mode="$(file_mode "$settings")"
  settings_managed_base64="$(base64 < "$settings" | tr -d '\n')"
  [ "$(file_identity "$settings")" = "$lower_identity" ]

  run env ATTACHMENT_FAULT_PHASE=user-rollback-1 HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$journal" ]
  jq -e --arg lower "$lower_identity" --arg settings "$settings" --arg codex "$codex_settings" '
    .phase == 1 and .pending == null
      and .applied == .artifacts[0:1]
      and .identities == [$lower]
      and .artifacts[0].destination == $settings
      and .artifacts[1].destination == $codex
  ' "$journal" >/dev/null
  [ "$(file_identity "$settings")" = "$lower_identity" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]

  printf '{\n  "operator": {\n    "manual": "unknown"\n  }\n}\n' > "$settings"
  chmod 640 "$settings"
  settings_unknown_hash="$(sha256_file "$settings")"
  settings_unknown_mode="$(file_mode "$settings")"
  settings_unknown_base64="$(base64 < "$settings" | tr -d '\n')"
  [ "$(file_identity "$settings")" = "$lower_identity" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  assert_output_has "$output" \
    "managed file $settings no longer has its pinned filesystem identity/content"
  assert_output_has "$output" \
    "Unknown bytes were preserved; restore the journaled regular-file snapshot instead."
  assert_output_has "$output" "trellis: user attachment recovery remedy: rm -f --"
  [ -f "$journal" ]
  jq -e --arg lower "$lower_identity" '
    .phase == 1 and .pending == null and .identities == [$lower]
  ' "$journal" >/dev/null
  [ "$(sha256_file "$settings")" = "$settings_unknown_hash" ]
  [ "$(file_mode "$settings")" = "$settings_unknown_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_unknown_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]

  if ! printf '%s' "$settings_managed_base64" | base64 -D > "$settings" 2>/dev/null; then
    printf '%s' "$settings_managed_base64" | base64 -d > "$settings"
  fi
  chmod "$settings_managed_mode" "$settings"
  [ "$(file_identity "$settings")" = "$lower_identity" ]
  [ "$(sha256_file "$settings")" = "$settings_managed_hash" ]
  [ "$(file_mode "$settings")" = "$settings_managed_mode" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]

  run "$(installed_attach "$release")" attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$(user_owner_path)" ]

  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

@test "attach --user rollback persists pending undo progress across recovery faults" {
  local release=2.0.0 journal script pending_index destination stage pending_identity phase_before
  local unknown_hash unknown_mode

  make_user_release "$release" true false
  journal="$(user_attach_journal_path)"
  script="$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh"
  mkdir -p "$HOME/.omp/agent"

  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  phase_before="$(jq -r '.phase' "$journal")"
  pending_index="$(jq -r '
    .phase as $phase
    | [range($phase; (.artifacts | length)) as $index
       | select(.artifacts[$index].kind == "symlink"
         and ((.artifacts[$index] | has("replace")) | not))
       | $index][0] // empty
  ' "$journal")"
  [ -n "$pending_index" ] || { cat "$journal"; false; }

  run env ATTACHMENT_FAULT_PHASE=user-pending-finalize HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c '
      source "$1"
      artifact=$(jq -c --argjson index "$4" ".artifacts[\$index]" "$3") || exit $?
      destination=$(printf "%s\n" "$artifact" | jq -r ".destination") || exit $?
      stage=$(_attachment_user_stage_candidate "$destination" "$(jq -r ".attachment_id" "$3")") || exit $?
      _attachment_user_set_pending "$3" "$artifact" "$stage" || exit $?
      _attachment_user_publish_pending "$2" "$3"
    ' _ "$script" "$TRELLIS_HOME" "$journal" "$pending_index"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  destination="$(jq -r '.pending.artifact.destination' "$journal")"
  stage="$(jq -r '.pending.staging_path' "$journal")"
  pending_identity="$(jq -r '.pending.destination_identity' "$journal")"
  jq -e --argjson index "$pending_index" '
    .pending.artifact == .artifacts[$index]
      and (.pending.destination_identity | type == "string" and length > 0)
      and .pending.rollback_state == null
  ' "$journal" >/dev/null
  [ -L "$destination" ]
  [ ! -e "$stage" ]
  [ ! -L "$stage" ]

  run env ATTACHMENT_FAULT_PHASE=user-rollback-pending-destination HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ ! -e "$destination" ]
  [ ! -L "$destination" ]
  [ -L "$stage" ]
  [ "$(file_identity "$stage")" = "$pending_identity" ]
  jq -e --arg identity "$pending_identity" '
    .pending.rollback_state == "destination"
      and .pending.destination_identity == $identity
      and .pending.staging_identity == $identity
  ' "$journal" >/dev/null
  printf 'operator-owned pending destination\n' > "$destination"
  chmod 640 "$destination"
  unknown_hash="$(sha256_file "$destination")"
  unknown_mode="$(file_mode "$destination")"

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(sha256_file "$destination")" = "$unknown_hash" ]
  [ "$(file_mode "$destination")" = "$unknown_mode" ]
  [ -L "$stage" ]
  [ "$(file_identity "$stage")" = "$pending_identity" ]
  jq -e --arg identity "$pending_identity" '
    .pending.rollback_state == "destination"
      and .pending.destination_identity == $identity
      and .pending.staging_identity == $identity
  ' "$journal" >/dev/null
  rm "$destination"


  run env ATTACHMENT_FAULT_PHASE=user-rollback-pending HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  jq -e --argjson phase "$phase_before" '.pending == null and .phase == $phase' "$journal" >/dev/null
  [ ! -e "$destination" ]
  [ ! -L "$destination" ]
  [ ! -e "$stage" ]
  [ ! -L "$stage" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  [ ! -e "$stage" ]
  [ ! -L "$stage" ]

  run "$(installed_attach "$release")" attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$(user_owner_path)" ]

  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  [ ! -e "$destination" ]
  [ ! -L "$destination" ]
}

@test "attach --user rollback converges an applied replace after restore before progress" {
  local release=2.0.0 agents settings codex_settings journal script
  local settings_before_hash settings_before_mode settings_before_base64
  local codex_before_hash codex_before_mode codex_before_base64

  make_user_release "$release" false false file true
  agents="$HOME/.omp/agent/AGENTS.md"
  settings="$HOME/.claude/settings.json"
  codex_settings="$HOME/.codex/settings.json"
  journal="$(user_attach_journal_path)"
  script="$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh"
  mkdir -p "$(dirname "$agents")" "$(dirname "$codex_settings")"
  cat > "$codex_settings" <<'JSON'
{
  "operator": {
    "keep": "codex"
  }
}
JSON
  chmod 640 "$codex_settings"
  settings_before_hash="$(sha256_file "$settings")"
  settings_before_mode="$(file_mode "$settings")"
  settings_before_base64="$(base64 < "$settings" | tr -d '\n')"
  codex_before_hash="$(sha256_file "$codex_settings")"
  codex_before_mode="$(file_mode "$codex_settings")"
  codex_before_base64="$(base64 < "$codex_settings" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=2 "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  jq -e --arg codex "$codex_settings" '
    .phase == 2 and .pending == null
      and .artifacts[1].destination == $codex
      and (.artifacts[1] | has("replace"))
  ' "$journal" >/dev/null

  run env ATTACHMENT_FAULT_PHASE=user-rollback-replace-restored HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  jq -e '
    .phase == 2 and .pending == null
      and .applied == .artifacts[0:2]
      and (.identities | length) == 2
  ' "$journal" >/dev/null
  [ -f "$codex_settings" ]
  [ ! -L "$codex_settings" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  ! compgen -G "$HOME/.claude/.settings.json.user-attachment-stage-*" >/dev/null
  ! compgen -G "$HOME/.codex/.settings.json.user-attachment-stage-*" >/dev/null

  run "$(installed_attach "$release")" attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

@test "attach --user rollback converges a pending replace after restore before progress" {
  local release=2.0.0 agents settings codex_settings journal script
  local settings_before_hash settings_before_mode settings_before_base64
  local codex_before_hash codex_before_mode codex_before_base64

  make_user_release "$release" false false file true
  agents="$HOME/.omp/agent/AGENTS.md"
  settings="$HOME/.claude/settings.json"
  codex_settings="$HOME/.codex/settings.json"
  journal="$(user_attach_journal_path)"
  script="$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh"
  mkdir -p "$(dirname "$agents")" "$(dirname "$codex_settings")"
  cat > "$codex_settings" <<'JSON'
{
  "operator": {
    "keep": "codex"
  }
}
JSON
  chmod 640 "$codex_settings"
  settings_before_hash="$(sha256_file "$settings")"
  settings_before_mode="$(file_mode "$settings")"
  settings_before_base64="$(base64 < "$settings" | tr -d '\n')"
  codex_before_hash="$(sha256_file "$codex_settings")"
  codex_before_mode="$(file_mode "$codex_settings")"
  codex_before_base64="$(base64 < "$codex_settings" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }

  run env ATTACHMENT_FAULT_PHASE=user-pending-finalize HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c '
      source "$1"
      artifact=$(jq -c ".artifacts[1]" "$3") || exit $?
      destination=$(printf "%s\n" "$artifact" | jq -r ".destination") || exit $?
      stage=$(_attachment_user_stage_candidate "$destination" "$(jq -r ".attachment_id" "$3")") || exit $?
      _attachment_user_set_pending "$3" "$artifact" "$stage" || exit $?
      _attachment_user_publish_pending "$2" "$3"
    ' _ "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  jq -e --arg codex "$codex_settings" '
    .phase == 1 and .pending != null
      and .pending.artifact == .artifacts[1]
      and .pending.artifact.destination == $codex
      and (.pending.destination_identity | type == "string" and length > 0)
      and .pending.rollback_state == null
  ' "$journal" >/dev/null

  run env ATTACHMENT_FAULT_PHASE=user-rollback-replace-restored HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  jq -e --arg codex "$codex_settings" '
    .phase == 1 and .pending != null
      and .pending.artifact.destination == $codex
      and (.pending.destination_identity | type == "string" and length > 0)
      and .pending.rollback_state == null
  ' "$journal" >/dev/null
  [ -f "$codex_settings" ]
  [ ! -L "$codex_settings" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  ! compgen -G "$HOME/.claude/.settings.json.user-attachment-stage-*" >/dev/null
  ! compgen -G "$HOME/.codex/.settings.json.user-attachment-stage-*" >/dev/null

  run "$(installed_attach "$release")" attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

@test "attach --user rollback restores a deleted managed symlink replacement" {
  local release=2.0.0 agents target journal script owner
  local before_hash before_mode before_base64

  make_user_release "$release" false true
  agents="$HOME/.omp/agent/AGENTS.md"
  target="$TRELLIS_HOME/releases/$release/payload/core-rules/omp/global/AGENTS.md"
  journal="$(user_attach_journal_path)"
  script="$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh"
  owner="$(user_owner_path)"
  mkdir -p "$(dirname "$agents")"
  cp "$target" "$agents"
  chmod "$(file_mode "$target")" "$agents"
  before_hash="$(sha256_file "$agents")"
  before_mode="$(file_mode "$agents")"
  before_base64="$(base64 < "$agents" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=owner-published "$(installed_attach "$release")" \
    attach --user --adopt-identical --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$journal" ]
  [ -f "$owner" ]
  [ -L "$agents" ]
  rm "$owner" "$agents"

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"user attachment recovery remedy:"* ]]
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
  [ -f "$agents" ]
  [ ! -L "$agents" ]
  [ "$(sha256_file "$agents")" = "$before_hash" ]
  [ "$(file_mode "$agents")" = "$before_mode" ]
  [ "$(base64 < "$agents" | tr -d '\n')" = "$before_base64" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  ! compgen -G "$HOME/.omp/agent/.AGENTS.md.user-attachment-stage-*" >/dev/null

  run "$(installed_attach "$release")" attach --user --adopt-identical --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$agents")" = "$before_hash" ]
  [ "$(file_mode "$agents")" = "$before_mode" ]
  [ "$(base64 < "$agents" | tr -d '\n')" = "$before_base64" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "attach --user rollback repair handles a regular-file replacement drift" {
  local release=2.0.0 agents settings codex_settings journal script repair
  local settings_before_hash settings_before_mode settings_before_base64
  local codex_before_hash codex_before_mode codex_before_base64
  local unknown_hash unknown_mode unknown_base64

  make_user_release "$release" false false file true
  agents="$HOME/.omp/agent/AGENTS.md"
  settings="$HOME/.claude/settings.json"
  codex_settings="$HOME/.codex/settings.json"
  journal="$(user_attach_journal_path)"
  script="$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh"
  mkdir -p "$(dirname "$agents")" "$(dirname "$codex_settings")"
  cat > "$codex_settings" <<'JSON'
{
  "operator": {
    "keep": "codex"
  }
}
JSON
  chmod 640 "$codex_settings"
  settings_before_hash="$(sha256_file "$settings")"
  settings_before_mode="$(file_mode "$settings")"
  settings_before_base64="$(base64 < "$settings" | tr -d '\n')"
  codex_before_hash="$(sha256_file "$codex_settings")"
  codex_before_mode="$(file_mode "$codex_settings")"
  codex_before_base64="$(base64 < "$codex_settings" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=1 "$(installed_attach "$release")" \
    attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  jq -e --arg settings "$settings" '
    .phase == 1 and .pending == null
      and .artifacts[0].destination == $settings
      and .artifacts[0].kind == "file"
      and (.artifacts[0] | has("replace"))
  ' "$journal" >/dev/null
  printf 'operator-owned regular-file drift\n' > "$settings"
  chmod 640 "$settings"
  unknown_hash="$(sha256_file "$settings")"
  unknown_mode="$(file_mode "$settings")"
  unknown_base64="$(base64 < "$settings" | tr -d '\n')"

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  assert_output_has "$output" "managed file $settings no longer has its pinned filesystem identity"
  repair="$(printf '%s\n' "$output" | sed -n 's/^trellis: user attachment recovery remedy: //p')"
  [ -n "$repair" ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$unknown_hash" ]
  [ "$(file_mode "$settings")" = "$unknown_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$unknown_base64" ]

  run bash -c "$repair"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$settings" ]
  [ ! -L "$settings" ]
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]

  run "$(installed_attach "$release")" attach --user --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$(installed_attach "$release")" detach --user --home "$TRELLIS_HOME"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$settings_before_hash" ]
  [ "$(file_mode "$settings")" = "$settings_before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$settings_before_base64" ]
  [ "$(sha256_file "$codex_settings")" = "$codex_before_hash" ]
  [ "$(file_mode "$codex_settings")" = "$codex_before_mode" ]
  [ "$(base64 < "$codex_settings" | tr -d '\n')" = "$codex_before_base64" ]
  [ ! -e "$agents" ]
  [ ! -L "$agents" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

@test "attach --user rollback emits an executable repair for a drifted symlink replacement" {
  local release=2.0.0 agents target journal script owner repair
  local before_hash before_mode before_base64

  make_user_release "$release" false true
  agents="$HOME/.omp/agent/AGENTS.md"
  target="$TRELLIS_HOME/releases/$release/payload/core-rules/omp/global/AGENTS.md"
  journal="$(user_attach_journal_path)"
  script="$TRELLIS_HOME/releases/$release/payload/scripts/lib/attachment.sh"
  owner="$(user_owner_path)"
  mkdir -p "$(dirname "$agents")"
  cp "$target" "$agents"
  chmod "$(file_mode "$target")" "$agents"
  before_hash="$(sha256_file "$agents")"
  before_mode="$(file_mode "$agents")"
  before_base64="$(base64 < "$agents" | tr -d '\n')"

  run env ATTACHMENT_FAULT_PHASE=owner-published "$(installed_attach "$release")" \
    attach --user --adopt-identical --home "$TRELLIS_HOME" --release "$release"

  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$journal" ]
  [ -f "$owner" ]
  [ -L "$agents" ]
  jq -e --arg agents "$agents" '
    any(.artifacts[]; .destination == $agents and .kind == "symlink" and has("replace"))
  ' "$journal" >/dev/null
  rm "$owner" "$agents"
  ln -s "$target" "$agents"
  [ "$(readlink "$agents")" = "$target" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  assert_output_has "$output" "managed symlink $agents no longer has its pinned filesystem identity"
  repair="$(printf '%s\n' "$output" | sed -n 's/^trellis: user attachment recovery remedy: //p')"
  [ -n "$repair" ] || { echo "$output"; false; }

  run bash -c "$repair"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$agents" ]
  [ ! -L "$agents" ]
  [ "$(sha256_file "$agents")" = "$before_hash" ]
  [ "$(file_mode "$agents")" = "$before_mode" ]
  [ "$(base64 < "$agents" | tr -d '\n')" = "$before_base64" ]

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=0 \
    bash -c 'source "$1"; attachment_user_rollback "$2" "$3"' _ \
    "$script" "$TRELLIS_HOME" "$journal"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$journal" ]
  [ ! -L "$journal" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
  [ -f "$agents" ]
  [ ! -L "$agents" ]
  [ "$(sha256_file "$agents")" = "$before_hash" ]
  [ "$(file_mode "$agents")" = "$before_mode" ]
}

@test "attach --user --adopt-identical rejects a byte-identical regular leaf with the wrong mode" {
  local destination target target_mode wrong_mode settings_before
  destination="$HOME/.omp/agent/AGENTS.md"
  target="$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/AGENTS.md"
  target_mode="$(file_mode "$target")"
  if [ "$target_mode" = 600 ]; then wrong_mode=644; else wrong_mode=600; fi
  mkdir -p "$(dirname "$destination")"
  cp "$target" "$destination"
  chmod "$wrong_mode" "$destination"
  settings_before="$(sha256_file "$HOME/.claude/settings.json")"

  user_attach_adopt_identical

  [ "$status" -eq 3 ]
  assert_output_has "$output" "$destination"
  [ -f "$destination" ]
  [ ! -L "$destination" ]
  [ "$(file_mode "$destination")" = "$wrong_mode" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
  [ ! -e "$(user_owner_path)" ]
}

@test "attach --user --adopt-identical promotes an identical regular leaf and detach restores it exactly" {
  destination="$HOME/.omp/agent/AGENTS.md"
  target="$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/AGENTS.md"
  mkdir -p "$(dirname "$destination")"
  cp "$target" "$destination"
  target_mode="$(file_mode "$target")"
  before_mode="0$target_mode"
  chmod "$target_mode" "$destination"
  before_hash="$(sha256_file "$destination")"
  before_base64="$(base64 < "$destination" | tr -d '\n')"
  settings_before="$(sha256_file "$HOME/.claude/settings.json")"

  user_attach

  [ "$status" -eq 3 ]
  assert_output_has "$output" "$destination"
  [ -f "$destination" ]
  [ ! -L "$destination" ]
  [ "$(file_mode "$destination")" = "$(file_mode "$target")" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]

  user_attach_adopt_identical

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$destination" ]
  [ "$(readlink "$destination")" = "$target" ]
  owner="$(user_owner_path)"
  jq -e --arg destination "$destination" --arg bytes "$before_base64" \
    --arg sha "$before_hash" --arg mode "$before_mode" '
    [.artifacts[] | select(.destination == $destination and .kind == "symlink")] as $artifacts
    | ($artifacts | length) == 1
      and (($artifacts[0] | has("replace")) | not)
      and (($artifacts[0].restore | keys) == ["before_base64", "before_mode", "before_sha256"])
      and $artifacts[0].restore.before_base64 == $bytes
      and $artifacts[0].restore.before_sha256 == $sha
      and $artifacts[0].restore.before_mode == $mode
  ' "$owner" >/dev/null

  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$destination" ]
  [ ! -L "$destination" ]
  [ "$(sha256_file "$destination")" = "$before_hash" ]
  [ "$(file_mode "$destination")" = "$target_mode" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$settings_before" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "attach --user --adopt-identical adopts equal JSON leaves and restores operator bytes and mode" {
  settings="$HOME/.claude/settings.json"
  printf '%s' '{"operator":{"theme":"violet","keep":true},"managed":{"policy":"fixture","release":"1.0.0"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"operator-owned pre-tool hook"}]}],"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"fixture Trellis SessionStart","timeout":60}]}]},"extra":{"format":"operator","enabled":true}}' > "$settings"
  chmod 640 "$settings"
  before_hash="$(sha256_file "$settings")"
  before_base64="$(base64 < "$settings" | tr -d '\n')"

  user_attach

  [ "$status" -eq 3 ]
  assert_output_has "$output" "$settings"
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(file_mode "$settings")" = 640 ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -L "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]

  user_attach_adopt_identical

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_mode "$settings")" = 600 ]
  [ "$(sha256_file "$settings")" != "$before_hash" ]
  jq -e '
    .operator.theme == "violet" and
    .operator.keep == true and
    .extra.format == "operator" and
    .extra.enabled == true and
    .managed.release == "1.0.0" and
    .managed.policy == "fixture" and
    .hooks.PreToolUse[0].hooks[0].command == "operator-owned pre-tool hook" and
    .hooks.SessionStart[0].hooks[0].command == "fixture Trellis SessionStart"
  ' "$settings" >/dev/null
  owner="$(user_owner_path)"
  jq -e --arg destination "$settings" --arg bytes "$before_base64" --arg sha "$before_hash" '
    [.renders[] | select(.destination == $destination and .merge == "explicit-json")] as $renders
    | ($renders | length) == 1
      and $renders[0].before_exists == true
      and $renders[0].before_base64 == $bytes
      and $renders[0].before_sha256 == $sha
      and $renders[0].before_mode == "0640"
      and $renders[0].mode == "0600"
      and $renders[0].after_mode == "0600"
  ' "$owner" >/dev/null

  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
  [ "$(file_mode "$settings")" = 640 ]
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -L "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "an adopted equal JSON leaf relinks and later restores the original operator snapshot" {
  local settings before_hash before_base64
  settings="$HOME/.claude/settings.json"
  printf '%s' '{"operator":{"theme":"violet","keep":true},"managed":{"policy":"fixture","release":"1.0.0"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"operator-owned pre-tool hook"}]}],"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"fixture Trellis SessionStart","timeout":60}]}]},"extra":{"format":"operator","enabled":true}}' > "$settings"
  chmod 640 "$settings"
  before_hash="$(sha256_file "$settings")"
  before_base64="$(base64 < "$settings" | tr -d '\n')"
  user_attach_adopt_identical
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 true false

  run "$USER_CLI" relink --user --home "$TRELLIS_HOME" --release 2.0.0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.managed.release == "2.0.0"' "$settings" >/dev/null
  jq -e '.release == "2.0.0"' "$(user_owner_path)" >/dev/null
  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
  [ "$(file_mode "$settings")" = 640 ]
  [ ! -e "$(user_owner_path)" ]
}

@test "--adopt-identical still rejects an unequal owned JSON leaf" {
  settings="$HOME/.claude/settings.json"
  changed="$settings.changed"
  jq '.managed = {release: "operator-owned"}' "$settings" > "$changed"
  chmod 640 "$changed"
  mv "$changed" "$settings"
  before_hash="$(sha256_file "$settings")"
  before_base64="$(base64 < "$settings" | tr -d '\n')"

  user_attach_adopt_identical

  [ "$status" -eq 3 ]
  assert_output_has "$output" "$settings"
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
  [ "$(file_mode "$settings")" = 640 ]
  [ ! -e "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -L "$HOME/.omp/agent/AGENTS.md" ]
  [ ! -e "$HOME/.omp/agent/RULES.md" ]
  [ ! -L "$HOME/.omp/agent/RULES.md" ]
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

@test "relink --user rejects a symlink restore carried onto a file release" {
  local destination target owner owner_before owner_tmp
  destination="$HOME/.omp/agent/AGENTS.md"

  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$destination" ]
  target="$(readlink "$destination")"
  owner="$(user_owner_path)"
  owner_tmp="$owner.tmp"
  jq --arg destination "$destination" --arg target "$target" '
    .artifacts |= map(
      if .destination == $destination then .restore = {before_target:$target} else . end
    )
  ' "$owner" > "$owner_tmp"
  mv "$owner_tmp" "$owner"
  chmod 600 "$owner"
  owner_before="$(sha256_file "$owner")"
  jq -e --arg destination "$destination" --arg target "$target" '
    [.artifacts[] | select(.destination == $destination)] as $artifacts
    | ($artifacts | length) == 1
      and $artifacts[0].kind == "symlink"
      and (($artifacts[0].restore | keys) == ["before_target"])
      and $artifacts[0].restore.before_target == $target
  ' "$owner" >/dev/null
  make_user_release 2.0.0 false true file

  run "$USER_CLI" relink --user --home "$TRELLIS_HOME" --release 2.0.0

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -L "$destination" ]
  [ "$(readlink "$destination")" = "$target" ]
  [ "$(sha256_file "$owner")" = "$owner_before" ]
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -L "$(user_attach_journal_path)" ]
  [ ! -e "$(user_detach_journal_path)" ]
  [ ! -L "$(user_detach_journal_path)" ]

  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -L "$destination" ]
  [ "$(readlink "$destination")" = "$target" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}

@test "relink --user rejects a file restore carried onto a symlink release" {
  local destination target before_hash before_mode before_base64 owner owner_before managed_hash
  destination="$HOME/.omp/agent/AGENTS.md"
  target="$TRELLIS_HOME/releases/1.0.0/payload/core-rules/omp/global/AGENTS.md"
  mkdir -p "$(dirname "$destination")"
  cp "$target" "$destination"
  chmod "$(file_mode "$target")" "$destination"
  before_hash="$(sha256_file "$destination")"
  before_mode="0$(file_mode "$destination")"
  before_base64="$(base64 < "$destination" | tr -d '\n')"

  user_attach_adopt_identical
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_user_release 2.0.0 false true file

  run "$USER_CLI" relink --user --home "$TRELLIS_HOME" --release 2.0.0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$destination" ]
  [ ! -L "$destination" ]
  owner="$(user_owner_path)"
  jq -e --arg destination "$destination" --arg bytes "$before_base64" \
    --arg sha "$before_hash" --arg mode "$before_mode" '
    [.artifacts[] | select(.destination == $destination)] as $artifacts
    | ($artifacts | length) == 1
      and $artifacts[0].kind == "file"
      and (($artifacts[0].restore | keys) == ["before_base64", "before_mode", "before_sha256"])
      and $artifacts[0].restore.before_base64 == $bytes
      and $artifacts[0].restore.before_sha256 == $sha
      and $artifacts[0].restore.before_mode == $mode
  ' "$owner" >/dev/null
  owner_before="$(sha256_file "$owner")"
  managed_hash="$(sha256_file "$destination")"
  make_user_release 3.0.0 false true symlink

  run "$USER_CLI" relink --user --home "$TRELLIS_HOME" --release 3.0.0

  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -f "$destination" ]
  [ ! -L "$destination" ]
  [ "$(sha256_file "$destination")" = "$managed_hash" ]
  [ "$(sha256_file "$owner")" = "$owner_before" ]
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -L "$(user_attach_journal_path)" ]
  [ ! -e "$(user_detach_journal_path)" ]
  [ ! -L "$(user_detach_journal_path)" ]

  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$destination" ]
  [ ! -L "$destination" ]
  [ "$(sha256_file "$destination")" = "$before_hash" ]
  [ "$(file_mode "$destination")" = "${before_mode#0}" ]
  [ "$(base64 < "$destination" | tr -d '\n')" = "$before_base64" ]
  [ ! -e "$owner" ]
  [ ! -L "$owner" ]
}
