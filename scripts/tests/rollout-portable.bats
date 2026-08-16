#!/usr/bin/env bats
# Focused T17 portable rollout contracts. Every fixture owns a temporary home.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"
BUILDER="$REPO_ROOT/scripts/rollout-builder-skills.sh"
SETTINGS="$REPO_ROOT/scripts/rollout-settings.sh"
PRESETS="$REPO_ROOT/scripts/rollout-presets.sh"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"

release_payload() {
  printf '%s/releases/%s/payload\n' "$TRELLIS_HOME" "$1"
}

make_release() {
  local release="$1"
  local mutation="${2:-}"
  local source="$SANDBOX/mutable policy source/$release"

  mkdir -p \
    "$source/core-rules/githooks" \
    "$source/core-rules/presets" \
    "$source/core-rules/skills/brainstorming" \
    "$source/core-rules/skills/execute" \
    "$source/core-rules/templates" \
    "$source/scripts/lib"
  local path
  for path in attach-project.sh registry.sh release.sh trellis; do
    cp "$REPO_ROOT/scripts/$path" "$source/scripts/$path"
  done
  for path in \
    attachment.sh \
    local-registry.sh \
    release-store.sh \
    semver.sh \
    surface-plan.sh \
    trellis-home.sh \
    trellis.machine.schema.json \
    trellis.registry.schema.json; do
    cp "$REPO_ROOT/scripts/lib/$path" "$source/scripts/lib/$path"
  done
  chmod 755 \
    "$source/scripts/attach-project.sh" \
    "$source/scripts/registry.sh" \
    "$source/scripts/release.sh" \
    "$source/scripts/trellis"
  printf '# fixture policy\n' > "$source/core-rules/CLAUDE.md"
  printf '# fixture brainstorming skill\n' > "$source/core-rules/skills/brainstorming/SKILL.md"
  printf '# fixture execute skill\n' > "$source/core-rules/skills/execute/SKILL.md"
  printf '# fixture strict preset\n' > "$source/core-rules/presets/compliance-strict.md"
  printf '# fixture experimental preset\n' > "$source/core-rules/presets/experimental-loose.md"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$source/core-rules/templates/claude-settings.local.json"
  cat > "$source/core-rules/githooks/pre-push" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$source/scripts/seed-inheritance-symlinks.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 755 \
    "$source/core-rules/githooks/pre-push" \
    "$source/scripts/seed-inheritance-symlinks.sh"
  cat > "$source/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"},
        {"source_children": "core-rules/skills", "destination_dir": ".claude/skills", "entry_type": "directory", "required_file": "SKILL.md"}
      ],
      "render": [
        {"template": "core-rules/templates/claude-settings.local.json", "destination": ".claude/settings.local.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    },
    "codex": {"links": [], "render": []},
    "omp": {"links": [], "render": []}
  }
}
JSON
  printf '%s\n' "$release" > "$source/core-rules/VERSION"

  case "$mutation" in
    "") ;;
    wrong-builder-surface)
      mkdir -p "$source/core-rules/alternate-skills"
      cp -R "$source/core-rules/skills/execute" "$source/core-rules/alternate-skills/"
      cp -R "$source/core-rules/skills/brainstorming" "$source/core-rules/alternate-skills/"
      jq '
        (.harnesses.claude.links[]
          | select(.destination_dir == ".claude/skills")
          | .source_children) = "core-rules/alternate-skills"
      ' "$source/core-rules/inheritance-manifest.json" \
        > "$source/core-rules/inheritance-manifest.json.next"
      mv "$source/core-rules/inheritance-manifest.json.next" \
        "$source/core-rules/inheritance-manifest.json"
      ;;
    wrong-settings-template)
      cp "$source/core-rules/templates/claude-settings.local.json" \
        "$source/core-rules/templates/alternate-claude-settings.local.json"
      jq '
        (.harnesses.claude.render[]
          | select(.destination == ".claude/settings.local.json")
          | .template) = "core-rules/templates/alternate-claude-settings.local.json"
      ' "$source/core-rules/inheritance-manifest.json" \
        > "$source/core-rules/inheritance-manifest.json.next"
      mv "$source/core-rules/inheritance-manifest.json.next" \
        "$source/core-rules/inheritance-manifest.json"
      ;;
    *)
      echo "unknown fixture release mutation: $mutation" >&2
      return 2
      ;;
  esac

  git -C "$source" init -q
  git -C "$source" config user.email rollout@example.invalid
  git -C "$source" config user.name Rollout
  git -C "$source" config commit.gpgsign false
  git -C "$source" config tag.gpgSign false
  git -C "$source" add -A
  git -C "$source" commit -qm release
  git -C "$source" tag -a "v$release" -m release

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; release_store_install "$2" "$3" ""' \
    release-store-bootstrap "$RELEASE_STORE_LIB" "$release" "$source"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  jq -n \
    --arg source_root "$source" \
    --arg release_remote "$source" \
    --arg release "$release" \
    --arg root "$SANDBOX" \
    '{
      schema_version: 1,
      source_root: $source_root,
      release_remote: $release_remote,
      active_cli_release: $release,
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$root]}}
    }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  SOURCE="$source"
  PAYLOAD="$(release_payload "$release")"
}

make_project_at() {
  local root="$1"
  local fleet="$2"
  local project_id="$3"
  local release="$4"
  local harness="${5:-claude}"

  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" config user.email rollout@example.invalid
  git -C "$root" config user.name Rollout
  git -C "$root" config commit.gpgsign false
  cat > "$root/.trellis.json" <<JSON
{"schema_version":1,"project_id":"$project_id","presets":["compliance-strict"]}
JSON
  git -C "$root" add .trellis.json
  git -C "$root" commit -qm initial

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    "$HOME/.local/bin/trellis" attach --home "$TRELLIS_HOME" --fleet "$fleet" --release "$release" \
      --harness "$harness" "$root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

make_project() {
  PROJECT="$SANDBOX/arbitrary project path/fixture project"
  make_project_at "$PROJECT" personal fixture-project 1.2.3
}

rewrite_registry() {
  local program="$1"
  local registry="$TRELLIS_HOME/registry.json"
  local next
  shift

  next="$(mktemp "$TRELLIS_HOME/.registry.test.XXXXXX")"
  jq "$@" "$program" "$registry" > "$next" || { rm -f "$next"; return 1; }
  mv -f "$next" "$registry" || { rm -f "$next"; return 1; }
  chmod 600 "$registry"
}

set_registry_release() {
  local project_key="$1"
  local release="$2"

  rewrite_registry \
    '.projects[$project_key].checkouts |= with_entries(.value.release = $release)' \
    --arg project_key "$project_key" --arg release "$release"
}

set_registry_status() {
  local project_key="$1"
  local status="$2"

  rewrite_registry '.projects[$project_key].status = $status' \
    --arg project_key "$project_key" --arg status "$status"
}

drift_registry_worktree_id() {
  local project_key="$1"
  local drifted_id="0000000000000000000000000000000000000000000000000000000000000000"

  rewrite_registry '
    .projects[$project_key].checkouts |= with_entries(
      .value.worktrees |= (to_entries | {($worktree_id): .[0].value})
    )
  ' --arg project_key "$project_key" --arg worktree_id "$drifted_id"
}

record_unavailable() {
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" personal unavailable "$2" "{}"' \
    _ "$REGISTRY_LIB" "$SANDBOX/unavailable volume/missing project"
  [ "$status" -eq 0 ]
}

poison_mutable_source() {
  printf 'MUTABLE SOURCE POISON\n' > "$SOURCE/core-rules/skills/execute/SKILL.md"
  printf 'MUTABLE SOURCE POISON\n' > "$SOURCE/core-rules/presets/compliance-strict.md"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/rollout-portable.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  mkdir -p "$SANDBOX/home with spaces" "$SANDBOX/trellis home"
  export HOME="$(CDPATH= cd "$SANDBOX/home with spaces" && pwd -P)"
  export TRELLIS_HOME="$(CDPATH= cd "$SANDBOX/trellis home" && pwd -P)"
  mkdir -p "$HOME/.local/bin"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis"
  chmod 755 "$HOME/.local/bin/trellis"
  make_release 1.2.3
  make_project
  record_unavailable
  poison_mutable_source
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

@test "builder dry-run uses an immutable payload, retains unavailable rows, and writes nothing" {
  runtime_before="$(readlink "$PROJECT/.trellis/runtime")"
  exclude_before="$(cat "$PROJECT/.git/info/exclude")"
  skill_before="$(readlink "$PROJECT/.claude/skills/execute")"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip (unavailable): personal/unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"would reconcile attachment-managed builder skill surfaces"* ]] || { echo "$output"; false; }
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$runtime_before" ]
  [ "$(cat "$PROJECT/.git/info/exclude")" = "$exclude_before" ]
  [ "$(readlink "$PROJECT/.claude/skills/execute")" = "$skill_before" ]
  [ "$(cat "$PROJECT/.trellis/runtime/core-rules/skills/execute/SKILL.md")" != "MUTABLE SOURCE POISON" ]
}

@test "builder and presets repeat against the recorded release at an arbitrary path" {
  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes fixture-project
  [ "$status" -eq 0 ]
  runtime_target="$(readlink "$PROJECT/.trellis/runtime")"
  [ "$runtime_target" = "$PAYLOAD" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PRESETS" --yes fixture-project
  [ "$status" -eq 0 ]
  preset="$PROJECT/.claude/rules/preset-compliance-strict.md"
  [ -L "$preset" ]
  [ "$(readlink "$preset")" = "$PAYLOAD/core-rules/presets/compliance-strict.md" ]
  [ "$(cat "$preset")" != "MUTABLE SOURCE POISON" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes fixture-project
  [ "$status" -eq 0 ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$runtime_target" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PRESETS" --yes fixture-project
  [ "$status" -eq 0 ]
  [ "$(readlink "$preset")" = "$PAYLOAD/core-rules/presets/compliance-strict.md" ]
}

@test "builder rejects active registry identity drift before attachment relink" {
  runtime="$PROJECT/.trellis/runtime"
  rm "$runtime"
  drift_registry_worktree_id personal/fixture-project

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes fixture-project
  [ "$status" -eq 4 ]
  [ ! -e "$runtime" ]
  [ ! -L "$runtime" ]
}

@test "builder returns unavailable for an unmatched single selector" {
  runtime="$PROJECT/.trellis/runtime"
  rm "$runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes missing-project
  [ "$status" -eq 5 ]
  [ ! -e "$runtime" ]
  [ ! -L "$runtime" ]
}

@test "builder rejects cross-fleet bare project ID ambiguity before relinking" {
  second_project="$SANDBOX/other fleet/fixture project"
  make_project_at "$second_project" work fixture-project 1.2.3
  rm "$PROJECT/.trellis/runtime"
  rm "$second_project/.trellis/runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes fixture-project
  [ "$status" -eq 3 ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
  [ ! -L "$PROJECT/.trellis/runtime" ]
  [ ! -e "$second_project/.trellis/runtime" ]
  [ ! -L "$second_project/.trellis/runtime" ]
}

@test "builder aggregates invalid releases and corrupt plans while continuing later rows" {
  valid_payload="$PAYLOAD"
  bad_release_project="$SANDBOX/bad release/fixture project"
  bad_plan_project="$SANDBOX/bad plan/fixture project"
  make_release 1.2.4 wrong-builder-surface
  make_project_at "$bad_release_project" personal bad-release 1.2.3
  make_project_at "$bad_plan_project" personal bad-plan 1.2.3
  set_registry_release personal/bad-release 9.9.9
  set_registry_release personal/bad-plan 1.2.4
  rm "$bad_release_project/.trellis/runtime"
  rm "$bad_plan_project/.trellis/runtime"
  rm "$PROJECT/.trellis/runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes
  [ "$status" -eq 5 ]
  [ ! -e "$bad_release_project/.trellis/runtime" ]
  [ ! -L "$bad_release_project/.trellis/runtime" ]
  [ ! -e "$bad_plan_project/.trellis/runtime" ]
  [ ! -L "$bad_plan_project/.trellis/runtime" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$valid_payload" ]
}

@test "builder includes failed attachment relinks in the bulk result" {
  valid_payload="$PAYLOAD"
  failed_project="$SANDBOX/bad relink/fixture project"
  foreign_runtime="$SANDBOX/foreign immutable payload"
  make_project_at "$failed_project" personal bad-relink 1.2.3
  mkdir -p "$foreign_runtime"
  rm "$failed_project/.trellis/runtime"
  ln -s "$foreign_runtime" "$failed_project/.trellis/runtime"
  rm "$PROJECT/.trellis/runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes
  [ "$status" -eq 4 ]
  [ "$(readlink "$failed_project/.trellis/runtime")" = "$foreign_runtime" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$valid_payload" ]
}

@test "settings requires the exact immutable Claude render tuple before relinking" {
  valid_payload="$PAYLOAD"
  bad_settings_project="$SANDBOX/bad settings/fixture project"
  make_release 1.2.4 wrong-settings-template
  make_project_at "$bad_settings_project" personal bad-settings 1.2.3
  set_registry_release personal/bad-settings 1.2.4
  settings_before="$(cat "$bad_settings_project/.claude/settings.local.json")"
  rm "$bad_settings_project/.trellis/runtime"
  rm "$PROJECT/.trellis/runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SETTINGS" --yes
  [ "$status" -eq 4 ]
  [ ! -e "$bad_settings_project/.trellis/runtime" ]
  [ ! -L "$bad_settings_project/.trellis/runtime" ]
  [ "$(cat "$bad_settings_project/.claude/settings.local.json")" = "$settings_before" ]
  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$valid_payload" ]
}

@test "presets require active rows and retarget only verified immutable-release links" {
  old_payload="$PAYLOAD"
  make_release 1.2.4
  new_payload="$PAYLOAD"
  set_registry_release personal/fixture-project 1.2.4
  cat > "$PROJECT/.trellis.json" <<'JSON'
{"schema_version":1,"project_id":"fixture-project","presets":["compliance-strict","experimental-loose"]}
JSON
  adopted_link="$PROJECT/.claude/rules/preset-compliance-strict.md"
  foreign_link="$PROJECT/.claude/rules/preset-experimental-loose.md"
  foreign_target="$SANDBOX/foreign preset.md"
  printf 'foreign preset\n' > "$foreign_target"
  ln -s "$old_payload/core-rules/presets/compliance-strict.md" "$adopted_link"
  ln -s "$foreign_target" "$foreign_link"

  detached_project="$SANDBOX/detached/fixture project"
  make_project_at "$detached_project" personal detached-project 1.2.3
  set_registry_status personal/detached-project detached

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PRESETS" --yes
  [ "$status" -eq 0 ]
  [ -L "$adopted_link" ]
  [ "$(readlink "$adopted_link")" = "$new_payload/core-rules/presets/compliance-strict.md" ]
  [ -L "$foreign_link" ]
  [ "$(readlink "$foreign_link")" = "$foreign_target" ]
  [ ! -e "$detached_project/.claude/rules/preset-compliance-strict.md" ]
  [ ! -L "$detached_project/.claude/rules/preset-compliance-strict.md" ]
}

@test "an empty local registry yields no targets and a clean rollout completion" {
  rewrite_registry '.projects = {}'

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Targets:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"(none)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"== done =="* ]] || { echo "$output"; false; }
}

@test "a present but broken root is a reported state error while a healthy sibling still runs" {
  broken_project="$SANDBOX/broken checkout/fixture project"
  make_project_at "$broken_project" personal broken-project 1.2.3
  rm -rf "$broken_project/.git"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --dry-run --yes
  [ "$status" -eq 4 ]
  [[ "$output" == *"error (registry row failed identity validation): personal/broken-project"* ]] || { echo "$output"; false; }
  [[ "$output" == *"skip (unavailable): personal/unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"== fixture-project"* ]] || [[ "$output" == *"personal/fixture-project"* ]] || { echo "$output"; false; }
  [[ "$output" == *"would reconcile attachment-managed builder skill surfaces"* ]] || { echo "$output"; false; }
}

@test "a broken row is a state error while a healthy sibling relink still applies" {
  valid_payload="$PAYLOAD"
  broken_project="$SANDBOX/broken checkout/fixture project"
  make_project_at "$broken_project" personal broken-project 1.2.3
  rm -rf "$broken_project/.git"
  rm "$PROJECT/.trellis/runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes
  [ "$status" -eq 4 ]
  [[ "$output" == *"error (registry row failed identity validation): personal/broken-project"* ]] || { echo "$output"; false; }
  [[ "$output" == *"relinked: $PROJECT"* ]] || { echo "$output"; false; }
  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$valid_payload" ]
  [ -L "$PROJECT/.claude/skills/execute" ]
  [ "$(cat "$PROJECT/.claude/skills/execute/SKILL.md")" = "# fixture execute skill" ]
}

@test "presets install nothing into .claude yet reclaim its stale links for a Codex-only row" {
  codex_project="$SANDBOX/codex only/fixture project"
  make_project_at "$codex_project" personal codex-project 1.2.3 codex
  [ ! -e "$codex_project/.claude" ]
  [ ! -L "$codex_project/.claude" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PRESETS" --yes codex-project
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaim (row without Claude harness)"* ]] || { echo "$output"; false; }
  [ ! -e "$codex_project/.claude" ]
  [ ! -L "$codex_project/.claude" ]
  [ -L "$codex_project/.agents/rules/preset-compliance-strict.md" ]
  [ "$(readlink "$codex_project/.agents/rules/preset-compliance-strict.md")" = "$PAYLOAD/core-rules/presets/compliance-strict.md" ]

  # A pre-existing .claude/rules keeps its foreign links but loses the managed
  # payload links nothing owns once the row dropped the Claude harness.
  stale_link="$codex_project/.claude/rules/preset-experimental-loose.md"
  foreign_link="$codex_project/.claude/rules/preset-compliance-strict.md"
  foreign_target="$SANDBOX/foreign preset.md"
  printf 'foreign preset\n' > "$foreign_target"
  mkdir -p "$codex_project/.claude/rules"
  ln -s "$PAYLOAD/core-rules/presets/experimental-loose.md" "$stale_link"
  ln -s "$foreign_target" "$foreign_link"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PRESETS" --yes codex-project
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed stale payload link: .claude/rules/preset-experimental-loose.md"* ]] || { echo "$output"; false; }
  [ ! -e "$stale_link" ]
  [ ! -L "$stale_link" ]
  [ -L "$foreign_link" ]
  [ "$(readlink "$foreign_link")" = "$foreign_target" ]
  [ -d "$codex_project/.claude/rules" ]
}

@test "an inherited preloaded-libs marker does not turn attachment relink into a no-op" {
  runtime="$PROJECT/.trellis/runtime"
  rm "$runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED=1 bash "$BUILDER" --yes fixture-project
  [ "$status" -eq 0 ]
  [[ "$output" == *"relinked: $PROJECT"* ]] || { echo "$output"; false; }
  [ -L "$runtime" ]
  [ "$(readlink "$runtime")" = "$PAYLOAD" ]
  [ -L "$PROJECT/.claude/skills/execute" ]
  [ "$(cat "$PROJECT/.claude/skills/execute/SKILL.md")" = "# fixture execute skill" ]
}

@test "a control-byte preset link name never reaches diagnostics raw" {
  esc="$(printf '\033')"
  foreign_target="$SANDBOX/foreign preset.md"
  printf 'foreign preset\n' > "$foreign_target"
  ln -s "$foreign_target" "$PROJECT/.claude/rules/preset-${esc}[31mstale.md"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PRESETS" --dry-run --yes fixture-project
  [ "$status" -eq 0 ]
  # The subject under test is a raw escape byte, so the failure diagnostic has
  # to render it printably rather than replay it into the terminal.
  [[ "$output" == *"has terminal control characters"* ]] || { cat -v <<<"$output"; false; }
  [[ "$output" != *"$esc"* ]] || { cat -v <<<"$output"; false; }
}

@test "a project-scoped rollout still carries a drifted row outside the selection" {
  broken_project="$SANDBOX/broken checkout/fixture project"
  make_project_at "$broken_project" personal broken-project 1.2.3
  rm -rf "$broken_project/.git"
  rm "$PROJECT/.trellis/runtime"

  # The selector narrows what the rollout ACTS on; it never narrows what counts
  # toward the exit class. Before this, naming one healthy project dropped every
  # other row from the run and exited 0 over a registry already shown corrupt.
  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes fixture-project
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'registry row outside this selection failed identity validation' <<<"$output"
  grep -qF 'personal/broken-project' <<<"$output"
  grep -qF "relinked: $PROJECT" <<<"$output"
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "a rollout selector refusal reports at no lower a class than registry state" {
  broken_project="$SANDBOX/broken checkout/fixture project"
  make_project_at "$broken_project" personal broken-project 1.2.3
  rm -rf "$broken_project/.git"

  # The unmatched-selector refusal is class 5. It must still name the drifted
  # rows and never report below the state class they prove; 5 already outranks
  # 4, so the discriminating assertion is that the rows are REPORTED at all.
  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$BUILDER" --yes missing-project
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'project not in local registry: missing-project' <<<"$output"
  grep -qF 'registry row outside this selection failed identity validation' <<<"$output"
  grep -qF 'personal/broken-project' <<<"$output"
}

@test "a print_targets failure reports at no lower a class than registry state" {
  broken_project="$SANDBOX/broken checkout/fixture project"
  make_project_at "$broken_project" personal broken-project 1.2.3
  rm -rf "$broken_project/.git"

  # A `jq` shim that fails ONLY on the filter `print_targets` uses to render a
  # row's root — the one jq invocation in this rollout that no other code path
  # makes. Everything earlier (the listing, the selection, the unselected-state
  # report) passes different argv and runs the real tool, so the run reaches
  # print_targets with the registry-state floor already armed at class 4 and
  # only the display step broken.
  shim="$SANDBOX/jq shim"
  mkdir -p "$shim"
  real_jq="$(command -v jq)"
  cat > "$shim/jq" <<SHIM
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = '.root // "<no local root>"' ]; then
    echo 'fixture: print_targets jq failure' >&2
    exit 1
  fi
done
exec "$real_jq" "\$@"
SHIM
  chmod 755 "$shim/jq"

  run env TRELLIS_HOME="$TRELLIS_HOME" PATH="$shim:$PATH" \
    bash "$SETTINGS" --yes fixture-project
  # The display fault's own class is 1. Exiting on it raw would report BELOW a
  # registry state error the same run had already proven and printed.
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'registry row outside this selection failed identity validation' <<<"$output"
  grep -qF 'personal/broken-project' <<<"$output"
  grep -qF 'fixture: print_targets jq failure' <<<"$output"
  # The display broke before any target was reconciled. Counted, not `grep -v`:
  # `grep -qv` succeeds whenever ANY line fails to match, which asserts nothing.
  [ "$(grep -cF 'relinked:' <<<"$output")" -eq 0 ]
}
