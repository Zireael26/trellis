#!/usr/bin/env bats

# Doctor must compare concrete discovery leaves with the manifest behind the
# project's runtime anchor.  This fixture installs and attaches a real immutable
# release so the check cannot accidentally consult this mutable source checkout.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
load helpers/release-fixture
load helpers/t25-portable

missing_leaf_install_release() {
  local version=1.2.4 repo="$T25_SANDBOX/missing-leaf release source"

  mkdir -p \
    "$repo/scripts" \
    "$repo/core-rules/skills/fixture-skill" \
    "$repo/core-rules/commands" \
    "$repo/core-rules/agents" \
    "$repo/core-rules/githooks"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" \
    "$repo/scripts/seed-inheritance-symlinks.sh"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  chmod 755 "$repo/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/attach-project.sh"

  printf '{"schema_version":2}\n' > "$repo/trellis.config.json"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/core-rules/githooks/pre-push"
  chmod 755 "$repo/core-rules/githooks/pre-push"
  printf '%s\n' '---' 'name: fixture-skill' 'description: fixture skill' '---' > \
    "$repo/core-rules/skills/fixture-skill/SKILL.md"
  printf '%s\n' '---' 'description: fixture command' '---' > \
    "$repo/core-rules/commands/fixture-command.md"
  printf '%s\n' '---' 'description: fixture agent' '---' > \
    "$repo/core-rules/agents/fixture-agent.md"

  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source_children":"core-rules/skills","destination_dir":".claude/skills","entry_type":"directory","required_file":"SKILL.md"},
        {"source_children":"core-rules/commands","destination_dir":".claude/commands","entry_type":"file","suffix":".md"},
        {"source_children":"core-rules/agents","destination_dir":".claude/agents","entry_type":"file","suffix":".md"}
      ],
      "render": []
    },
    "codex": {
      "links": [
        {"source_children":"core-rules/skills","destination_dir":".agents/skills","entry_type":"directory","required_file":"SKILL.md"},
        {"source_children":"core-rules/commands","destination_dir":".agents/commands","entry_type":"file","suffix":".md"}
      ],
      "render": []
    }
  }
}
JSON

  release_fixture_install "$T25_USER_HOME" "$T25_TRELLIS_HOME" "$version" "$repo" || return 1
  jq --arg source "$repo" '.source_root = $source' "$T25_TRELLIS_HOME/config.json" > \
    "$T25_TRELLIS_HOME/config.json.next" || return 1
  mv "$T25_TRELLIS_HOME/config.json.next" "$T25_TRELLIS_HOME/config.json" || return 1
  chmod 600 "$T25_TRELLIS_HOME/config.json" || return 1
  T25_RELEASE="$version"
  T25_PAYLOAD="$T25_TRELLIS_HOME/releases/$version/payload"
  T25_MANIFEST="$T25_PAYLOAD/core-rules/inheritance-manifest.json"
  MISSING_LEAF_RELEASE_SOURCE="$repo"
}

missing_leaf_adopt_release_with_new_skill() {
  local version=1.2.5 skill=adopted-only
  mkdir -p "$MISSING_LEAF_RELEASE_SOURCE/core-rules/skills/$skill"
  printf '%s\n' '---' "name: $skill" 'description: adoption-only fixture skill' '---' > \
    "$MISSING_LEAF_RELEASE_SOURCE/core-rules/skills/$skill/SKILL.md"
  printf '%s\n' "$version" > "$MISSING_LEAF_RELEASE_SOURCE/core-rules/VERSION"
  release_fixture_install "$T25_USER_HOME" "$T25_TRELLIS_HOME" "$version" \
    "$MISSING_LEAF_RELEASE_SOURCE" || return 1

  # The immutable payload keeps the new declaration. Remove it from the mutable
  # source so a checker that falls back to config.source_root becomes falsely
  # healthy and this fixture catches that authority regression.
  rm -rf "$MISSING_LEAF_RELEASE_SOURCE/core-rules/skills/$skill"
  t25_attachment_env "$T25_LAUNCHER" release adopt "$version" \
    --project t25-fixture-project --fleet personal >/dev/null || return 1
}

setup() {
  t25_setup_attachment_fixture
  missing_leaf_install_release
  t25_attach >/dev/null
}

teardown() {
  t25_teardown_sandbox
}

run_missing_leaf_doctor() {
  t25_attachment_env bash "$DOCTOR" --home "$T25_TRELLIS_HOME" \
    --project t25-fixture-project
}

@test "doctor reports a deleted release-manifest leaf as an error with the reattach remedy" {
  rm "$T25_PROJECT/.claude/skills/fixture-skill"

  run run_missing_leaf_doctor

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  t25_contains "$output" 'manifest leaves: missing declared leaf(s): .claude/skills/fixture-skill'
  t25_contains "$output" 'detach then attach the project'
}

@test "doctor leaves a complete release-manifest surface healthy" {
  run run_missing_leaf_doctor

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  t25_contains "$output" 'manifest leaves: all declared skill, command, and agent leaves are present'
  t25_lacks "$output" 'missing declared leaf(s)'
}

@test "doctor reads newly adopted leaves from the runtime manifest, not owner or source inventory" {
  missing_leaf_adopt_release_with_new_skill
  owner="$(t25_owner_path "$T25_PROJECT")"

  [ ! -e "$T25_PROJECT/.claude/skills/adopted-only" ]
  jq -e '[.artifacts[].path] | index(".claude/skills/adopted-only") == null' \
    "$owner" >/dev/null

  run run_missing_leaf_doctor

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  t25_contains "$output" 'manifest leaves: missing declared leaf(s): .agents/skills/adopted-only'
  t25_contains "$output" '.claude/skills/adopted-only'
}
