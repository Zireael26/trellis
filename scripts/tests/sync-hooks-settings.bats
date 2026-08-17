#!/usr/bin/env bats
# Portable attachment reconciliation coverage for Claude and Codex hook sync.
# Every fixture uses a private temporary TRELLIS_HOME and an installed immutable
# release. The synchronizers must not inspect tracked registry Markdown, derive
# a checkout under one root, or copy mutable source files into a project.

REPO="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
VERSION="1.2.3"
PROJECT_ID="attached-project"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sync hook fixture"
  mkdir -p "$SANDBOX"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/operator home"
  export TRELLIS_HOME="$SANDBOX/trellis home"
  HOME_PATH="$TRELLIS_HOME"
  PROJECT="$SANDBOX/projects/Project With Spaces"
  SOURCE="$SANDBOX/release source"
  RUNNER="$SANDBOX/old mutable source"
  MOVED_RUNNER="$SANDBOX/moved synchronizer"
  UNAVAILABLE_ROOT="$SANDBOX/Missing Volume/project not mounted"
  mkdir -p "$HOME" "$HOME_PATH"
  chmod 700 "$HOME" "$HOME_PATH"
  bootstrap_release_admin
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

bootstrap_release_admin() {
  local bootstrap="$SANDBOX/bootstrap release source" config user_home trellis_home

  mkdir -p "$HOME/.local/bin" "$HOME_PATH" "$bootstrap/scripts"
  user_home="$(canonical_dir "$HOME")"
  trellis_home="$(canonical_dir "$HOME_PATH")"
  HOME="$user_home"
  HOME_PATH="$trellis_home"
  TRELLIS_HOME="$trellis_home"
  export HOME TRELLIS_HOME
  chmod 700 "$HOME" "$HOME_PATH"
  cp "$REPO/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis"
  chmod 755 "$HOME/.local/bin/trellis"
  cp "$REPO/scripts/trellis" "$REPO/scripts/release.sh" "$REPO/scripts/attach-project.sh" \
    "$bootstrap/scripts/"
  cp -R "$REPO/scripts/lib" "$bootstrap/scripts/lib"
  cat >> "$bootstrap/scripts/attach-project.sh" <<'SH'

if [ "${1:-}" = relink ]; then
  printf '%s\n' "$@" > "$TRELLIS_HOME/test-relink-arguments"
  if [ -f "$TRELLIS_HOME/test-relink-child-diagnostic" ]; then
    cat "$TRELLIS_HOME/test-relink-child-diagnostic" >&2
    exit 5
  fi
fi
SH
  chmod 755 "$bootstrap/scripts/trellis" "$bootstrap/scripts/release.sh" \
    "$bootstrap/scripts/attach-project.sh"
  mkdir -p "$bootstrap/core-rules"
  printf '0.0.0\n' > "$bootstrap/core-rules/VERSION"
  git -C "$bootstrap" init -q
  git -C "$bootstrap" config user.email 'sync-fixture@trellis.test'
  git -C "$bootstrap" config user.name 'Sync Fixture'
  git -C "$bootstrap" config commit.gpgsign false
  git -C "$bootstrap" config tag.gpgSign false
  git -C "$bootstrap" add core-rules scripts
  git -C "$bootstrap" commit -qm 'bootstrap release'
  git -C "$bootstrap" tag --no-sign -a v0.0.0 -m v0.0.0
  bootstrap="$(canonical_dir "$bootstrap")"
  TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    sync-hooks-bootstrap "$REPO/scripts/lib/release-store.sh" 0.0.0 "$bootstrap"
  config="$HOME_PATH/config.json"
  jq -n --arg source "$bootstrap" --arg root "$SANDBOX" '{
    schema_version:1,
    source_root:$source,
    release_remote:$source,
    active_cli_release:"0.0.0",
    default_fleet:"personal",
    fleets:{personal:{discovery_roots:[$root]}}
  }' > "$config"
  chmod 600 "$config"
}

build_installed_release() {
  # release_store_locate verifies every payload file during attachment and sync,
  # so retain only the trusted assets this reconciliation fixture exercises.
  mkdir -p \
    "$SOURCE/core-rules/templates" \
    "$SOURCE/core-rules/hooks" \
    "$SOURCE/core-rules/codex/hooks" \
    "$SOURCE/core-rules/githooks" \
    "$SOURCE/scripts"
  cp "$REPO/core-rules/CLAUDE.md" "$SOURCE/core-rules/CLAUDE.md"
  cp "$REPO/core-rules/templates/claude-settings.local.json" \
    "$SOURCE/core-rules/templates/claude-settings.local.json"
  cp "$REPO/core-rules/templates/codex-hooks.local.json" \
    "$SOURCE/core-rules/templates/codex-hooks.local.json"
  cp "$REPO/core-rules/githooks/pre-push" "$SOURCE/core-rules/githooks/pre-push"
  cp "$REPO/core-rules/hooks/"*.sh "$SOURCE/core-rules/hooks/"
  cp -R "$REPO/core-rules/hooks/lib" "$SOURCE/core-rules/hooks/"
  cp "$REPO/core-rules/codex/hooks/"*.sh "$SOURCE/core-rules/codex/hooks/"
  cp -R "$REPO/core-rules/codex/hooks/lib" "$SOURCE/core-rules/codex/hooks/"
  cp "$REPO/scripts/attach-project.sh" "$REPO/scripts/seed-inheritance-symlinks.sh" \
    "$REPO/scripts/trellis" "$REPO/scripts/release.sh" "$SOURCE/scripts/"
  cp -R "$REPO/scripts/lib" "$SOURCE/scripts/lib"
  chmod 755 "$SOURCE/core-rules/githooks/pre-push" \
    "$SOURCE/core-rules/hooks/"*.sh "$SOURCE/core-rules/codex/hooks/"*.sh \
    "$SOURCE/scripts/attach-project.sh" "$SOURCE/scripts/seed-inheritance-symlinks.sh" \
    "$SOURCE/scripts/trellis" "$SOURCE/scripts/release.sh"
  printf '%s\n' "$VERSION" > "$SOURCE/core-rules/VERSION"
  cat > "$SOURCE/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"},
        {"source_children": "core-rules/hooks", "destination_dir": ".claude/hooks", "entry_type": "file", "suffix": ".sh", "executable": true},
        {"source_children": "core-rules/hooks/lib", "destination_dir": ".claude/hooks/lib", "entry_type": "file", "suffix": ".sh", "executable": true}
      ],
      "render": [
        {"template": "core-rules/templates/claude-settings.local.json", "destination": ".claude/settings.local.json", "merge": "explicit-json", "mode": "0600", "required": false}
      ]
    },
    "codex": {
      "links": [
        {"project_target": "CLAUDE.md", "fallback_source": "core-rules/CLAUDE.md", "destination": "AGENTS.md"},
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"},
        {"source_children": "core-rules/codex/hooks", "destination_dir": ".codex/hooks", "entry_type": "file", "suffix": ".sh", "executable": true},
        {"source_children": "core-rules/codex/hooks/lib", "destination_dir": ".codex/hooks/lib", "entry_type": "file", "suffix": ".sh", "executable": true}
      ],
      "render": [
        {"template": "core-rules/templates/codex-hooks.local.json", "destination": ".codex/hooks.json", "merge": "explicit-json", "mode": "0600", "required": false}
      ]
    },
    "omp": {"links": [], "render": []}
  }
}
JSON

  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.email 'sync-fixture@trellis.test'
  git -C "$SOURCE" config user.name 'Sync Fixture'
  git -C "$SOURCE" config commit.gpgsign false
  git -C "$SOURCE" config tag.gpgSign false
  git -C "$SOURCE" add -A
  git -C "$SOURCE" commit -qm 'fixture release'
  git -C "$SOURCE" tag --no-sign -a "v$VERSION" -m "v$VERSION"

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    "$HOME/.local/bin/trellis" release install "$VERSION" --remote "$SOURCE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

create_project() {
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email 'project-fixture@trellis.test'
  git -C "$PROJECT" config commit.gpgsign false
  git -C "$PROJECT" config user.name 'Project Fixture'
  printf '{"schema_version":1,"project_id":"%s"}\n' "$PROJECT_ID" > "$PROJECT/.trellis.json"
  printf '# project fixture\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add .
  git -C "$PROJECT" commit -qm 'fixture project'
}

attach_project() {
  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    bash "$REPO/scripts/attach-project.sh" attach --home "$HOME_PATH" \
      --fleet personal --release "$VERSION" --harness claude --harness codex "$PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

make_movable_runner() {
  mkdir -p "$RUNNER/scripts"
  cp "$REPO/scripts/sync-hooks.sh" "$RUNNER/scripts/"
  cp "$REPO/scripts/sync-codex-hooks.sh" "$RUNNER/scripts/"
  cp -R "$REPO/scripts/lib" "$RUNNER/scripts/lib"
  chmod 755 "$RUNNER/scripts/sync-hooks.sh" "$RUNNER/scripts/sync-codex-hooks.sh"

  mv "$RUNNER" "$MOVED_RUNNER"
  cat > "$MOVED_RUNNER/scripts/attach-project.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' source-poisoned >&2
exit 99
SH
  chmod 755 "$MOVED_RUNNER/scripts/attach-project.sh"
  mkdir -p "$RUNNER/core-rules/hooks"
  printf '#!/usr/bin/env bash\nprintf source-poisoned\\n\n' > "$RUNNER/core-rules/hooks/source-poison.sh"
}

capture_relink_arguments() {
  RELINK_ARGS="$HOME_PATH/test-relink-arguments"
  rm -f "$RELINK_ARGS"
}

install_snapshot_probe() {
  local library="$MOVED_RUNNER/scripts/lib/release-store.sh"
  local real_library="$MOVED_RUNNER/scripts/lib/release-store.real.sh"

  mv "$library" "$real_library"
  cat > "$library" <<'SH'
#!/usr/bin/env bash
_T16_REAL_RELEASE_STORE="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/release-store.real.sh"
. "$_T16_REAL_RELEASE_STORE"

_t16_poison_attachment_source() {
  local path="$1" marker="$2" label="$3"
  chmod u+w "$(dirname "$path")" "$path"
  printf '#!/usr/bin/env bash\nprintf %%s %q > %q\nexit 99\n' "$label" "$marker" > "$path"
  chmod 755 "$path"
}

release_store_snapshot_verified_release() {
  local version="${1:-}" record snapshot digest marker carrier attachment_lib
  if record="$(
    /usr/bin/env -i \
      "HOME=${HOME:-}" \
      "TRELLIS_HOME=${TRELLIS_HOME:-}" \
      "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
      /bin/bash --noprofile --norc -c '
        . "$1"
        release_store_snapshot_verified_release "$2"
      ' _ "$_T16_REAL_RELEASE_STORE" "$version"
  )"; then
    :
  else
    return "$?"
  fi

  case "$record" in
    *$'\t'*)
      snapshot="${record%%$'\t'*}"
      digest="${record#*$'\t'}"
      ;;
    *) return 4 ;;
  esac
  [ -n "$snapshot" ] && [ -n "$digest" ] || return 4
  marker="${TRELLIS_TEST_CARRIER_MARKER:-}"
  carrier="$TRELLIS_HOME/releases/$version/payload/scripts/attach-project.sh"
  attachment_lib="$TRELLIS_HOME/releases/$version/payload/scripts/lib/attachment.sh"

  case "${TRELLIS_TEST_SNAPSHOT_PROBE_MODE:-}" in
    original)
      _t16_poison_attachment_source "$carrier" "$marker" original-carrier-executed
      _t16_poison_attachment_source "$attachment_lib" "$marker" original-lib-executed
      ;;
    snapshot-carrier)
      _t16_poison_attachment_source "$snapshot/payload/scripts/attach-project.sh" \
        "$marker" snapshot-carrier-executed
      ;;
    snapshot-lib)
      _t16_poison_attachment_source "$snapshot/payload/scripts/lib/attachment.sh" \
        "$marker" snapshot-lib-executed
      ;;
  esac
  printf '%s\n' "$record"
}

release_store_remove_snapshot() {
  if [ "${TRELLIS_TEST_SNAPSHOT_PROBE_MODE:-}" = cleanup ]; then
    printf 'fixture cleanup diagnostic: \033\001\302\201\n' >&2
    return "${TRELLIS_TEST_CLEANUP_STATUS:-5}"
  fi
  (
    . "$_T16_REAL_RELEASE_STORE"
    release_store_remove_snapshot "$@"
  )
}
SH
}

assert_complete_relink_binding() {
  local args fleet project_id root checkout_id worktree_id attachment_id release harnesses
  args="$(jq -Rsc 'split("\n") | .[:-1]' "$RELINK_ARGS")" || return 1
  fleet="$(jq -r '.fleet' "$OWNER")" || return 1
  project_id="$(jq -r '.project_id' "$OWNER")" || return 1
  root="$(jq -r '.project_root' "$OWNER")" || return 1
  checkout_id="$(jq -r '.checkout_id' "$OWNER")" || return 1
  worktree_id="$(jq -r '.worktree_id' "$OWNER")" || return 1
  attachment_id="$(jq -r '.attachment_id' "$OWNER")" || return 1
  release="$(jq -r '.release' "$OWNER")" || return 1
  harnesses="$(jq -c '
    [.artifacts[]
     | if .path == "AGENTS.md" or (.path | startswith(".agents/")) or (.path | startswith(".codex/"))
       then "codex"
       elif (.path | startswith(".claude/")) then "claude"
       elif (.path | startswith(".omp/")) then "omp"
       else empty
       end]
    | unique | sort
  ' "$OWNER")" || return 1
  jq -e \
    --arg home "$HOME_PATH" --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg root "$root" --arg checkout_id "$checkout_id" --arg worktree_id "$worktree_id" \
    --arg attachment_id "$attachment_id" --arg release "$release" --arg harnesses "$harnesses" '
      . == [
        "relink",
        "--home", $home,
        "--fleet", $fleet,
        "--expected-fleet", $fleet,
        "--expected-project-id", $project_id,
        "--expected-root", $root,
        "--expected-checkout-id", $checkout_id,
        "--expected-worktree-id", $worktree_id,
        "--expected-attachment-id", $attachment_id,
        "--expected-release", $release,
        "--expected-harnesses-json", $harnesses,
        $root
      ]
    ' <<<"$args" >/dev/null
}

owner_path() {
  find "$HOME_PATH/state/attachments" -type f -name '*.json' -print | sed -n '1p'
}

prepare_fixture() {
  build_installed_release
  create_project
  attach_project
  make_movable_runner
  OWNER="$(owner_path)"
  [ -n "$OWNER" ] && [ -f "$OWNER" ]
}

record_unavailable_row() {
  local project_id="${1:-unavailable-project}" root="${2:-$UNAVAILABLE_ROOT}"
  run env TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; local_registry_record_unavailable_root "$2" personal "$3" "$4" "{}"' \
    _ "$REPO/scripts/lib/local-registry.sh" "$HOME_PATH" "$project_id" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# Registers a second, healthy project row and then breaks its Git identity in
# place: the root stays present but stops resolving as a canonical Git worktree,
# so its registry row lists as `identity_error` while the fixture project stays
# healthy.
register_drifted_sibling() {
  local sibling="$SANDBOX/projects/drifted sibling"
  mkdir -p "$sibling"
  git -C "$sibling" init -q
  git -C "$sibling" config user.email 'sibling-fixture@trellis.test'
  git -C "$sibling" config user.name 'Sibling Fixture'
  git -C "$sibling" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"drifted-sibling"}\n' > "$sibling/.trellis.json"
  printf '# sibling\n' > "$sibling/README.md"
  git -C "$sibling" add .
  git -C "$sibling" commit -qm 'sibling fixture'
  run env TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; local_registry_register_worktree "$2" personal drifted-sibling "$3" "" "[]" "" "{}"' \
    _ "$REPO/scripts/lib/local-registry.sh" "$HOME_PATH" "$sibling"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rm -rf "$sibling/.git"
}

assert_terminal_safe() {
  if printf '%s' "$1" | LC_ALL=C od -An -tu1 | tr -s ' ' '\n' | awk '
    NF && ($1 == 27 || ($1 >= 0 && $1 <= 31 && $1 != 10) ||
    $1 == 127 || ($1 >= 128 && $1 <= 159)) { exit 1 }
  '; then
    return 0
  fi
  return 1
}

install_terminal_registry_stub() {
  cat >> "$MOVED_RUNNER/scripts/lib/local-registry.sh" <<'SH'
eval "_terminal_stub_real_list_json() $(declare -f local_registry_list_json | sed '1d')"
local_registry_list_json() {
  if [ -z "${TRELLIS_TEST_TERMINAL_ROOT:-}" ]; then
    _terminal_stub_real_list_json "$@"
    return "$?"
  fi
  jq -n --arg root "$TRELLIS_TEST_TERMINAL_ROOT" '{
    entries: [{
      fleet: "personal",
      project_id: "terminal-project",
      kind: "unavailable",
      availability: "unavailable",
      status: "unavailable",
      excluded: false,
      root: $root,
      release: null,
      attachment_id: null,
      checkout_id: null,
      worktree_id: null,
      harnesses: [],
      metadata: {}
    }]
  }'
}
SH
}

remove_codex_owner_artifacts() {
  local next
  chmod u+w "$OWNER"
  next="$OWNER.next"
  jq '
    .artifacts |= map(select(
      ((.path == "AGENTS.md")
       or (.path | startswith(".agents/"))
       or (.path | startswith(".codex/")))
      | not
    ))
  ' "$OWNER" > "$next"
  mv "$next" "$OWNER"
  chmod 600 "$OWNER"
}

create_release_missing_attachment() {
  local registry next candidate
  SECOND_PROJECT_ID="missing-release-project"
  SECOND_PROJECT="$SANDBOX/projects/Second Project With Spaces"
  mkdir -p "$SECOND_PROJECT"
  git -C "$SECOND_PROJECT" init -q
  git -C "$SECOND_PROJECT" config user.email 'second-project@trellis.test'
  git -C "$SECOND_PROJECT" config commit.gpgsign false
  git -C "$SECOND_PROJECT" config user.name 'Second Project'
  printf '{"schema_version":1,"project_id":"%s"}\n' "$SECOND_PROJECT_ID" > "$SECOND_PROJECT/.trellis.json"
  printf '# second fixture\n' > "$SECOND_PROJECT/README.md"
  git -C "$SECOND_PROJECT" add .
  git -C "$SECOND_PROJECT" commit -qm 'second fixture project'

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    bash "$REPO/scripts/attach-project.sh" attach --home "$HOME_PATH" \
      --fleet personal --release "$VERSION" --harness claude "$SECOND_PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }

  SECOND_OWNER=""
  for candidate in "$HOME_PATH"/state/attachments/*/*.json; do
    [ -f "$candidate" ] || continue
    if [ "$(jq -r '.project_id' "$candidate")" = "$SECOND_PROJECT_ID" ]; then
      SECOND_OWNER="$candidate"
    fi
  done
  [ -n "$SECOND_OWNER" ] || return 1

  chmod u+w "$SECOND_OWNER"
  jq --arg release '9.9.9' '.release = $release' "$SECOND_OWNER" > "$SECOND_OWNER.next"
  mv "$SECOND_OWNER.next" "$SECOND_OWNER"
  chmod 600 "$SECOND_OWNER"

  registry="$HOME_PATH/registry.json"
  chmod u+w "$registry"
  next="$registry.next"
  jq --arg key "personal/$SECOND_PROJECT_ID" --arg release '9.9.9' \
    '.projects[$key].checkouts |= with_entries(.value.release = $release)' \
    "$registry" > "$next"
  mv "$next" "$registry"
  chmod 600 "$registry"
}

# POST-SYNC VERIFICATION lives in rollout-hooks.sh --check, not here.
# sync-hooks.sh carried a --verify flag under the registry.md model; the
# portable-fleet model removed it, because verification now compares a
# project against its attached immutable release rather than against the
# mutable checkout that launched the command. The seven tests that exercised
# the old flag were dropped with it; scripts/tests/rollout-hooks.bats owns the
# sweep contract now.

@test "Claude and Codex sync use only the active immutable-release reconciler" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'attachment relinked' <<<"$output"
  [ "$(grep -cF source-poisoned <<<"$output")" -eq 0 ] || { echo "$output"; false; }

  rm "$PROJECT/.trellis/runtime"
  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-codex-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'attachment relinked' <<<"$output"
  [ "$(grep -cF source-poisoned <<<"$output")" -eq 0 ] || { echo "$output"; false; }

  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$HOME_PATH/releases/$VERSION/payload" ]
  [ ! -e "$PROJECT/.claude/settings.json" ]
  [ ! -e "$PROJECT/.claude/hooks/source-poison.sh" ]
  [ ! -e "$PROJECT/.codex/hooks/source-poison.sh" ]
}

@test "Claude sync relinks a stale runtime through attachment ownership and is idempotent" {
  prepare_fixture
  settings="$PROJECT/.claude/settings.local.json"
  [ -f "$settings" ]
  settings_before="$(shasum -a 256 "$settings" | awk '{print $1}')"
  owner_before="$(shasum -a 256 "$OWNER" | awk '{print $1}')"
  rm "$PROJECT/.trellis/runtime"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'attachment relinked' <<<"$output"
  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$HOME_PATH/releases/$VERSION/payload" ]
  [ "$(shasum -a 256 "$settings" | awk '{print $1}')" = "$settings_before" ]
  [ "$(shasum -a 256 "$OWNER" | awk '{print $1}')" = "$owner_before" ]

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "in sync: attached immutable release $VERSION" <<<"$output"
  [ "$(shasum -a 256 "$OWNER" | awk '{print $1}')" = "$owner_before" ]
}

@test "Claude sync passes the complete strict binding to attachment relink" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"
  capture_relink_arguments

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_complete_relink_binding
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "symlinked attachment owner is a state error before reconciliation" {
  prepare_fixture
  rm "$OWNER"
  ln -s "$PROJECT/.trellis/runtime" "$OWNER"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'blocked (corrupt attachment owner record)' <<<"$output"
  [ -L "$OWNER" ]
}

@test "unavailable local row is explicit and never reconstructed under a root" {
  prepare_fixture
  record_unavailable_row

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --dry-run unavailable-project
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'skip (unavailable): personal/unavailable-project' <<<"$output"
  escaped_root="$(LC_ALL=C printf '%q' "$UNAVAILABLE_ROOT")"
  grep -qF "$escaped_root" <<<"$output"
  [ ! -e "$UNAVAILABLE_ROOT" ]
}

@test "owner harness divergence is a strict conflict before attachment mutation" {
  prepare_fixture
  remove_codex_owner_artifacts

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'owner record conflicts with strict registry' <<<"$output"
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "failed attachment relink preserves its conflict exit class" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"
  printf 'foreign runtime artifact\n' > "$PROJECT/.trellis/runtime"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (3)' <<<"$output"
  [ -f "$PROJECT/.trellis/runtime" ]
}

@test "bulk sync reports a missing owner, continues, and returns the highest failure class" {
  prepare_fixture
  rm "$OWNER"
  create_release_missing_attachment

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'blocked (corrupt attachment owner record)' <<<"$output"
  grep -qF 'recorded immutable release unavailable' <<<"$output"
  [ ! -e "$HOME_PATH/releases/9.9.9" ]
}

@test "Claude sync keeps root and child diagnostics terminal-safe" {
  prepare_fixture
  terminal_root="$SANDBOX/Missing$(printf '\033\001\302\201')Root"
  install_terminal_registry_stub

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_TERMINAL_ROOT="$terminal_root" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --dry-run terminal-project
  # This test's whole subject is escape bytes in diagnostics, so a failure
  # here must render them printably instead of replaying them.
  [ "$status" -eq 0 ] || { cat -v <<<"$output"; false; }
  grep -qF 'skip (unavailable): personal/terminal-project' <<<"$output"
  assert_terminal_safe "$output"

  rm "$PROJECT/.trellis/runtime"
  printf 'fixture child diagnostic: \033\001\302\201\n' > "$HOME_PATH/test-relink-child-diagnostic"
  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 5 ] || { cat -v <<<"$output"; false; }
  grep -qF 'attachment relink failed (5)' <<<"$output"
  assert_terminal_safe "$output"
}

@test "Claude sync executes the immutable bundle after active carrier and library swap" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"
  install_snapshot_probe
  marker="$SANDBOX/active carrier or library executed"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=original \
    TRELLIS_TEST_CARRIER_MARKER="$marker" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$marker" ]
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "Claude sync refuses mixed immutable snapshot carrier and library before relink" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"
  install_snapshot_probe
  marker="$SANDBOX/snapshot carrier or library executed"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=snapshot-lib \
    TRELLIS_TEST_CARRIER_MARKER="$marker" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (4)' <<<"$output"
  [ ! -e "$marker" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=snapshot-carrier \
    TRELLIS_TEST_CARRIER_MARKER="$marker" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (4)' <<<"$output"
  [ ! -e "$marker" ]
  [ ! -e "$PROJECT/.trellis/runtime" ]
}

@test "Claude sync surfaces immutable snapshot cleanup failure above a relink conflict" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"
  printf 'foreign runtime artifact\n' > "$PROJECT/.trellis/runtime"
  install_snapshot_probe

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=cleanup \
    TRELLIS_TEST_CLEANUP_STATUS=5 \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (3)' <<<"$output"
  grep -qF 'active immutable execution snapshot cleanup failed (5)' <<<"$output"
  assert_terminal_safe "$output"
  [ -f "$PROJECT/.trellis/runtime" ]
}

@test "a project-scoped sync still carries a drifted sibling row into the exit class" {
  prepare_fixture
  register_drifted_sibling

  # The `--project` filter used to run BEFORE anything looked for state-error
  # rows, so a scoped run over a healthy project exited 0 over a registry it had
  # just been shown to be corrupt. The selection still limits PROCESSING: only
  # the named project is relinked.
  rm "$PROJECT/.trellis/runtime"
  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'registry row outside this selection failed identity validation' <<<"$output"
  grep -qF 'personal/drifted-sibling' <<<"$output"
  grep -qF 'attachment relinked' <<<"$output"
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "a scoped sync refusing an unknown project reports at no lower a class than registry state" {
  prepare_fixture
  register_drifted_sibling

  # The preflight "project not in this fleet" refusal exits 1. It must not
  # report below the class the full listing already proved, and it must name the
  # rows that proved it.
  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-hooks.sh" --home "$HOME_PATH" --fleet personal --yes no-such-project
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'project not in local registry fleet' <<<"$output"
  grep -qF 'registry row outside this selection failed identity validation' <<<"$output"
}