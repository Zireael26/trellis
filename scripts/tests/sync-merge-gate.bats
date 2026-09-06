#!/usr/bin/env bats
# Portable merge-dispatcher reconciliation coverage. The dispatcher is owned by
# the attachment in TRELLIS_HOME, never by .husky/.githooks/.git hooks files.

REPO="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
VERSION="1.2.3"
PROJECT_ID="merge-project"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/merge gate fixture"
  mkdir -p "$SANDBOX"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/operator home"
  export TRELLIS_HOME="$SANDBOX/trellis home"
  HOME_PATH="$TRELLIS_HOME"
  PROJECT="$SANDBOX/projects/Merge Project With Spaces"
  SOURCE="$SANDBOX/release source"
  RUNNER="$SANDBOX/old mutable source"
  MOVED_RUNNER="$SANDBOX/moved synchronizer"
  UNAVAILABLE_ROOT="$SANDBOX/Missing Volume/merge project"
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
  cp "$REPO/scripts/trellis-launcher.sh" "$bootstrap/scripts/trellis-launcher.sh"
  cp -R "$REPO/scripts/lib" "$bootstrap/scripts/lib"
  cat >> "$bootstrap/scripts/attach-project.sh" <<'SH'

if [ "${1:-}" = relink ]; then
  printf '%s\n' "$@" > "$TRELLIS_HOME/test-relink-arguments"
  printf '%s' "${TMPDIR-}" > "$TRELLIS_HOME/test-relink-temp-tmpdir"
  printf '%s' "${TMP-}" > "$TRELLIS_HOME/test-relink-temp-tmp"
  printf '%s' "${TEMP-}" > "$TRELLIS_HOME/test-relink-temp-temp"
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
  git -C "$bootstrap" config user.email 'merge-fixture@trellis.test'
  git -C "$bootstrap" config user.name 'Merge Fixture'
  git -C "$bootstrap" config commit.gpgsign false
  git -C "$bootstrap" config tag.gpgSign false
  git -C "$bootstrap" add core-rules scripts
  git -C "$bootstrap" commit -qm 'bootstrap release'
  git -C "$bootstrap" tag --no-sign -a v0.0.0 -m v0.0.0
  bootstrap="$(canonical_dir "$bootstrap")"
  TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    sync-merge-bootstrap "$REPO/scripts/lib/release-store.sh" 0.0.0 "$bootstrap"
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
  cp "$REPO/scripts/trellis-launcher.sh" "$SOURCE/scripts/trellis-launcher.sh"
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
    }
  }
}
JSON

  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.email 'merge-fixture@trellis.test'
  git -C "$SOURCE" config user.name 'Merge Fixture'
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
  printf '# merge project fixture\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add .
  git -C "$PROJECT" commit -qm 'fixture project'
}

attach_project() {
  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    bash "$REPO/scripts/attach-project.sh" attach --home "$HOME_PATH" \
      --fleet personal --release "$VERSION" --harness claude "$PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

make_movable_runner() {
  mkdir -p "$RUNNER/scripts"
  cp "$REPO/scripts/sync-merge-gate.sh" "$RUNNER/scripts/"
  cp -R "$REPO/scripts/lib" "$RUNNER/scripts/lib"
  chmod 755 "$RUNNER/scripts/sync-merge-gate.sh"

  mv "$RUNNER" "$MOVED_RUNNER"
  cat > "$MOVED_RUNNER/scripts/attach-project.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' source-poisoned >&2
exit 99
SH
  chmod 755 "$MOVED_RUNNER/scripts/attach-project.sh"
  mkdir -p "$RUNNER/core-rules/githooks"
  printf '#!/usr/bin/env bash\nprintf source-poisoned\\n\n' > "$RUNNER/core-rules/githooks/pre-push"
}

capture_relink_arguments() {
  RELINK_ARGS="$HOME_PATH/test-relink-arguments"
  rm -f "$RELINK_ARGS"
}

capture_relink_environment() {
  SELECTED_TMPDIR="$SANDBOX/relink child temp with spaces"
  mkdir -p "$SELECTED_TMPDIR"
  chmod 700 "$SELECTED_TMPDIR"
  RELINK_TEMP_PREFIX="$HOME_PATH/test-relink-temp"
  rm -f "$RELINK_TEMP_PREFIX-tmpdir" "$RELINK_TEMP_PREFIX-tmp" "$RELINK_TEMP_PREFIX-temp"
}

assert_relink_temp_triplet() {
  local expected="$SANDBOX/expected relink temp value"
  printf '%s' "$SELECTED_TMPDIR" > "$expected"
  cmp "$expected" "$RELINK_TEMP_PREFIX-tmpdir"
  cmp "$expected" "$RELINK_TEMP_PREFIX-tmp"
  cmp "$expected" "$RELINK_TEMP_PREFIX-temp"
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
      "TMPDIR=${TMPDIR:-/tmp}" \
      "TMP=${TMPDIR:-/tmp}" \
      "TEMP=${TMPDIR:-/tmp}" \
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
  MANAGED_HOOKS="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  [ -n "$MANAGED_HOOKS" ] && [ "$MANAGED_HOOKS" != null ]
}

record_unavailable_row() {
  local project_id="${1:-unavailable-merge}" root="${2:-$UNAVAILABLE_ROOT}"
  run env TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; local_registry_record_unavailable_root "$2" personal "$3" "$4" "{}"' \
    _ "$REPO/scripts/lib/local-registry.sh" "$HOME_PATH" "$project_id" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
      project_id: "terminal-merge",
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

# Rewrite the owner record through FILTER. Used for both dispatcher-metadata
# shapes below: the schema-legal one (no `git_hooks` block at all) and the
# schema-illegal one (a block the owner validator rejects).
rewrite_owner() {
  local next="$OWNER.next"
  chmod u+w "$OWNER"
  jq "$1" "$OWNER" > "$next"
  mv "$next" "$OWNER"
  chmod 600 "$OWNER"
}

# The owner schema makes `git_hooks` optional, so this is a VALID record for an
# attachment that manages no hooks — not corruption.
drop_merge_dispatcher_metadata() {
  rewrite_owner 'del(.git_hooks)'
}

# A PRESENT block the `hooks` definition rejects: `.enabled` must be a boolean.
corrupt_merge_dispatcher_metadata() {
  rewrite_owner '.git_hooks.enabled = "yes"'
}

remove_claude_owner_artifacts() {
  local next
  chmod u+w "$OWNER"
  next="$OWNER.next"
  jq '.artifacts |= map(select((.path | startswith(".claude/")) | not))' \
    "$OWNER" > "$next"
  mv "$next" "$OWNER"
  chmod 600 "$OWNER"
}

@test "merge sync validates the moved attachment dispatcher and leaves project hooks untouched" {
  prepare_fixture
  owner_before="$(shasum -a 256 "$OWNER" | awk '{print $1}')"
  dispatcher_before="$(shasum -a 256 "$MANAGED_HOOKS/pre-push" | awk '{print $1}')"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "attachment-managed immutable dispatcher for $VERSION" <<<"$output"

  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$MANAGED_HOOKS" ]
  [ -f "$MANAGED_HOOKS/pre-push" ]
  [ "$(cat "$MANAGED_HOOKS/release-payload")" = "$HOME_PATH/releases/$VERSION/payload" ]
  [ ! -e "$PROJECT/.husky/pre-push" ]
  [ ! -e "$PROJECT/.githooks/pre-push" ]
  [ "$(shasum -a 256 "$OWNER" | awk '{print $1}')" = "$owner_before" ]
  [ "$(shasum -a 256 "$MANAGED_HOOKS/pre-push" | awk '{print $1}')" = "$dispatcher_before" ]
}

@test "merge sync dry-run preserves a stale dispatcher and relink restores it from the immutable release" {
  prepare_fixture
  rm "$MANAGED_HOOKS/pre-push"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --dry-run "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'would reconcile attachment-managed merge dispatcher' <<<"$output"
  [ ! -e "$MANAGED_HOOKS/pre-push" ]

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'attachment merge dispatcher relinked' <<<"$output"
  [ "$(grep -cF source-poisoned <<<"$output")" -eq 0 ] || { echo "$output"; false; }
  [ -f "$MANAGED_HOOKS/pre-push" ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$MANAGED_HOOKS" ]
  [ ! -e "$PROJECT/.githooks/pre-push" ]
}

@test "merge sync passes the complete strict binding to attachment relink" {
  prepare_fixture
  rm "$MANAGED_HOOKS/pre-push"
  capture_relink_arguments

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_complete_relink_binding
  [ -f "$MANAGED_HOOKS/pre-push" ]
}

@test "merge sync propagates the selected temporary directory into real relink" {
  prepare_fixture
  capture_relink_environment
  rm "$PROJECT/.trellis/runtime"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TMPDIR="$SELECTED_TMPDIR" TMP="$SANDBOX/unselected TMP" TEMP="$SANDBOX/unselected TEMP" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'attachment merge dispatcher relinked' <<<"$output"
  assert_relink_temp_triplet
  [ -L "$PROJECT/.trellis/runtime" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$HOME_PATH/releases/$VERSION/payload" ]
  [ -f "$MANAGED_HOOKS/pre-push" ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$MANAGED_HOOKS" ]
}

@test "merge sync treats a nonregular owner record as a state error" {
  prepare_fixture
  rm "$OWNER"
  mkdir "$OWNER"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'blocked (corrupt attachment owner record)' <<<"$output"
  [ -d "$OWNER" ]
}

@test "merge sync reports unavailable strict rows without creating a guessed checkout" {
  prepare_fixture
  record_unavailable_row

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --dry-run unavailable-merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'skip (unavailable): personal/unavailable-merge' <<<"$output"
  escaped_root="$(LC_ALL=C printf '%q' "$UNAVAILABLE_ROOT")"
  grep -qF "$escaped_root" <<<"$output"
  [ ! -e "$UNAVAILABLE_ROOT" ]
}

@test "merge sync rejects owner harness divergence as a strict conflict" {
  prepare_fixture
  remove_claude_owner_artifacts

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'owner record conflicts with strict registry' <<<"$output"
  [ -f "$MANAGED_HOOKS/pre-push" ]
}

@test "merge sync preserves a failed dispatcher relink conflict" {
  prepare_fixture
  printf 'foreign dispatcher artifact\n' > "$MANAGED_HOOKS/pre-push"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (3)' <<<"$output"
  grep -qF 'foreign dispatcher artifact' "$MANAGED_HOOKS/pre-push"
}

@test "merge sync treats a missing owner record as a state error" {
  prepare_fixture
  rm "$OWNER"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'blocked (corrupt attachment owner record)' <<<"$output"
  [ ! -e "$OWNER" ]
}

@test "merge sync skips an owner record that declares no managed merge dispatcher" {
  prepare_fixture
  # `git_hooks` is optional in the owner schema (scripts/lib/attachment.sh's
  # owner validator: `if has("git_hooks") then (.git_hooks | hooks) else true
  # end`), so its absence is a legal record meaning "hooks are not managed" —
  # exactly what `enabled: false` means. Reconciliation skips, and the
  # dispatcher this attachment installed earlier is left untouched.
  dispatcher_before="$(shasum -a 256 "$MANAGED_HOOKS/pre-push" | awk '{print $1}')"
  drop_merge_dispatcher_metadata

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Counted, and guarded: this is the test's central claim, so it must print the
  # run's output when it fails rather than dying silently mid-test.
  [ "$(grep -cF 'skip (attachment has no managed merge dispatcher): personal/merge-project' <<<"$output")" -ge 1 ] ||
    { echo "$output"; false; }
  [ "$(shasum -a 256 "$MANAGED_HOOKS/pre-push" | awk '{print $1}')" = "$dispatcher_before" ] ||
    { echo "$output"; false; }
}

@test "merge sync treats a schema-invalid dispatcher block as a corrupt owner record" {
  prepare_fixture
  # The state-error branch this command used to keep for dispatcher metadata is
  # unreachable: `_attachment_owner_json_valid` runs first and applies the full
  # `hooks` definition, so a present-but-invalid block is reported one step
  # earlier, as owner corruption, and never as dispatcher metadata.
  corrupt_merge_dispatcher_metadata

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ "$(grep -cF 'blocked (corrupt attachment owner record): personal/merge-project' <<<"$output")" -ge 1 ] ||
    { echo "$output"; false; }
}

@test "merge sync keeps root and child diagnostics terminal-safe" {
  prepare_fixture
  terminal_root="$SANDBOX/Missing$(printf '\033\001\302\201')Root"
  install_terminal_registry_stub

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_TERMINAL_ROOT="$terminal_root" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --dry-run terminal-merge
  # This test's whole subject is escape bytes in diagnostics, so a failure
  # here must render them printably instead of replaying them.
  [ "$status" -eq 0 ] || { cat -v <<<"$output"; false; }
  grep -qF 'skip (unavailable): personal/terminal-merge' <<<"$output"
  assert_terminal_safe "$output"

  rm "$MANAGED_HOOKS/pre-push"
  printf 'fixture child diagnostic: \033\001\302\201\n' > "$HOME_PATH/test-relink-child-diagnostic"
  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 5 ] || { cat -v <<<"$output"; false; }
  grep -qF 'attachment relink failed (5)' <<<"$output"
  assert_terminal_safe "$output"
}

@test "merge sync executes the immutable bundle after active carrier and library swap" {
  prepare_fixture
  rm "$MANAGED_HOOKS/pre-push"
  install_snapshot_probe
  marker="$SANDBOX/active carrier or library executed"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=original \
    TRELLIS_TEST_CARRIER_MARKER="$marker" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$marker" ]
  [ -f "$MANAGED_HOOKS/pre-push" ]
}

@test "merge sync refuses mixed immutable snapshot carrier and library before relink" {
  prepare_fixture
  rm "$MANAGED_HOOKS/pre-push"
  install_snapshot_probe
  marker="$SANDBOX/snapshot carrier or library executed"

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=snapshot-lib \
    TRELLIS_TEST_CARRIER_MARKER="$marker" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (4)' <<<"$output"
  [ ! -e "$marker" ]
  [ ! -e "$MANAGED_HOOKS/pre-push" ]

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=snapshot-carrier \
    TRELLIS_TEST_CARRIER_MARKER="$marker" \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (4)' <<<"$output"
  [ ! -e "$marker" ]
  [ ! -e "$MANAGED_HOOKS/pre-push" ]
}

@test "merge sync surfaces immutable snapshot cleanup failure above a relink conflict" {
  prepare_fixture
  printf 'foreign dispatcher artifact\n' > "$MANAGED_HOOKS/pre-push"
  install_snapshot_probe

  run env -u TRELLIS_CONFIG TRELLIS_HOME="$HOME_PATH" \
    TRELLIS_TEST_SNAPSHOT_PROBE_MODE=cleanup \
    TRELLIS_TEST_CLEANUP_STATUS=5 \
    bash "$MOVED_RUNNER/scripts/sync-merge-gate.sh" --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'attachment relink failed (3)' <<<"$output"
  grep -qF 'active immutable execution snapshot cleanup failed (5)' <<<"$output"
  assert_terminal_safe "$output"
  grep -qF 'foreign dispatcher artifact' "$MANAGED_HOOKS/pre-push"
}
