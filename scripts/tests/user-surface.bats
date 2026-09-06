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
  local version="$1" include_second_render="${5:-false}" repo
  repo="$SANDBOX/release source $version"

  mkdir -p "$repo/core-rules/templates"
  copy_user_release_runtime "$repo"

  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  printf 'fixture user output style for release %s\n' "$version" \
    > "$repo/core-rules/templates/claude-user-output-style.md"
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

  jq -n --argjson include_second_render "$include_second_render" '{
    schema_version: 1,
    harnesses: {
      claude: {links: [], render: []},
      codex: {links: [], render: []},
      user: {
        links: [
          {source: "core-rules/templates/claude-user-output-style.md", destination: ".claude/output-styles/fixture.md", destination_home: true}
        ],
        render: (
          [
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
  local version="$1" repo
  repo="$SANDBOX/full release source $version"
  mkdir -p "$repo"
  cp -R "$REPO_ROOT/core-rules" "$repo/"
  copy_user_release_runtime "$repo"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
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
  # Business contract, not wording: the style defers scheduling to the shared
  # parent delegation policy and names where that policy lives, so a reader has
  # one authority to consult rather than two that can drift apart.
  if [[ "$style_body" != *"CLAUDE.md"* || "$style_body" != *"Context management"* ]]; then
    echo "style does not point at the shared delegation policy"
    false
  fi
  # ...and it must not restate an independent scheduling authority of its own:
  # no standalone per-target/per-item dispatch mandate, and no count-based trigger.
  if [[ "$style_body" =~ (o|O)ne[[:space:]]+([A-Za-z-]+[[:space:]]+)?[Aa]gent[[:space:]]+per[[:space:]]+(target|item|file|unit|project|skill|question) ]]; then
    echo "style still carries an independent one-agent-per-target scheduling rule"
    false
  fi
  if [[ "$style_body" =~ [0-9]+\+?[[:space:]]+([a-z-]+[[:space:]]+)?(targets|units|items|files|projects) ]]; then
    echo "style still carries a count-based dispatch trigger"
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
  # The template ships the output-style file but must NOT set outputStyle:
  # it is an operator preference, and declaring it makes attach --user collide
  # with any operator who chose a different style.
  jq -e 'has("outputStyle") | not' "$settings" >/dev/null
  jq -e '.workflowSizeGuideline == "large"' "$settings" >/dev/null

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

  user_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$owner")" = "$first_owner_hash" ]
  [ "$(sha256_file "$HOME/.claude/settings.json")" = "$first_settings_hash" ]
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

@test "detach --user removes owned leaves and restores the exact pre-attach render" {
  before_hash="$(sha256_file "$HOME/.claude/settings.json")"
  before_mode="$(file_mode "$HOME/.claude/settings.json")"

  user_attach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  user_detach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
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

@test "attach --user retry recovers an interrupted transaction" {
  run env ATTACHMENT_FAULT_PHASE=owner-published "$(installed_attach "$USER_RELEASE")" \
    attach --user --home "$TRELLIS_HOME" --release "$USER_RELEASE"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -f "$(user_attach_journal_path)" ]
  [ -f "$(user_owner_path)" ]
  user_attach
  [ ! -e "$(user_attach_journal_path)" ]
  [ ! -L "$(user_attach_journal_path)" ]

  [ "$status" -eq 0 ] || { echo "$output"; false; }
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
  ! compgen -G "$HOME/.claude/.settings.json.user-attachment-stage-*" >/dev/null

  user_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  user_detach
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sha256_file "$settings")" = "$before_hash" ]
  [ "$(file_mode "$settings")" = "$before_mode" ]
  [ "$(base64 < "$settings" | tr -d '\n')" = "$before_base64" ]
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
  [ ! -e "$(user_owner_path)" ]
  [ ! -L "$(user_owner_path)" ]
}

