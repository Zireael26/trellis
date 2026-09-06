#!/usr/bin/env bats
# Tests for scripts/rollout-hooks.sh — the post-rollout verification wrapper
# added after audits/2026-08-13-parent-hook-drift.md found that the fleet
# rollout had no check step, so a sync that silently did not happen looked
# identical to one that did.
#
# The wrapper no longer compares a project against the mutable checkout that
# launched it, so neither do these tests. Every fixture builds a private
# TRELLIS_HOME, installs a SEALED IMMUTABLE RELEASE through the stable
# launcher, and attaches real projects to it — the same shape
# scripts/tests/sync-hooks-settings.bats uses. The strict attachment predicate
# is never stubbed: what these tests assert is what hc_portable_attachment
# actually accepted or rejected.
#
# Every invocation runs the wrapper from a MOVED copy of scripts/ whose
# core-rules/ tree deliberately diverges from the installed release. A wrapper
# that still read mutable source would fail most of this file.
#
# DL-P5-11 discipline (EMPIRICALLY-CORRECT RULE): under bats `set -eET`, a
# NON-FINAL simple command that fails — `[ ]`, grep, cmp, jq, diff — DOES abort
# the test, but a NON-FINAL compound `[[ ]]` does NOT (its non-zero status is
# swallowed). So a load-bearing assertion must NEVER be a non-final `[[ ]]`:
# make it the FINAL statement, or write it as a set-e-catchable simple command
# (prefer `grep -qF <<<"$output"`). Every discriminating assertion below is the
# FINAL enforced statement or a set-e-catchable simple command.

REPO="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
VERSION="1.2.3"
PROJECT_ID="attached-project"
PI_PROJECT_ID="pi-only-project"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/rollout fixture"
  mkdir -p "$SANDBOX"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/operator home"
  export TRELLIS_HOME="$SANDBOX/trellis home"
  HOME_PATH="$TRELLIS_HOME"
  PROJECT="$SANDBOX/projects/Project With Spaces"
  PI_PROJECT="$SANDBOX/projects/Pi Only Project"
  SECOND_WORKTREE="$SANDBOX/projects/Second Worktree"
  DETACHED_PROJECT="$SANDBOX/projects/Detached Project"
  SOURCE="$SANDBOX/release source"
  RUNNER="$SANDBOX/divergent mutable source"
  UNAVAILABLE_ROOT="$SANDBOX/Missing Volume/project not mounted"
  mkdir -p "$HOME" "$HOME_PATH"
  chmod 700 "$HOME" "$HOME_PATH"
  bootstrap_release_admin
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -r -f "$SANDBOX"
}

canonical_dir() {
  (CDPATH='' cd "$1" && pwd -P)
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
    "$REPO/scripts/trellis-launcher.sh" "$bootstrap/scripts/"
  cp -R "$REPO/scripts/lib" "$bootstrap/scripts/lib"
  chmod 755 "$bootstrap/scripts/trellis" "$bootstrap/scripts/release.sh" \
    "$bootstrap/scripts/attach-project.sh" "$bootstrap/scripts/trellis-launcher.sh"
  mkdir -p "$bootstrap/core-rules"
  printf '0.0.0\n' > "$bootstrap/core-rules/VERSION"
  git -C "$bootstrap" init -q
  git -C "$bootstrap" config user.email 'rollout-fixture@trellis.test'
  git -C "$bootstrap" config user.name 'Rollout Fixture'
  git -C "$bootstrap" config commit.gpgsign false
  git -C "$bootstrap" config tag.gpgSign false
  git -C "$bootstrap" add core-rules scripts
  git -C "$bootstrap" commit -qm 'bootstrap release'
  git -C "$bootstrap" tag --no-sign -a v0.0.0 -m v0.0.0
  bootstrap="$(canonical_dir "$bootstrap")"
  TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    rollout-bootstrap "$REPO/scripts/lib/release-store.sh" 0.0.0 "$bootstrap"
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

# The sealed release carries all three native harnesses, so a Pi-only
# attachment is a real manifest selection here rather than a shape the fixture
# invents.
build_installed_release() {
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
    "$REPO/scripts/trellis" "$REPO/scripts/release.sh" "$REPO/scripts/trellis-launcher.sh" "$SOURCE/scripts/"
  cp -R "$REPO/scripts/lib" "$SOURCE/scripts/lib"
  chmod 755 "$SOURCE/core-rules/githooks/pre-push" \
    "$SOURCE/core-rules/hooks/"*.sh "$SOURCE/core-rules/codex/hooks/"*.sh \
    "$SOURCE/scripts/attach-project.sh" "$SOURCE/scripts/seed-inheritance-symlinks.sh" \
    "$SOURCE/scripts/trellis" "$SOURCE/scripts/release.sh" "$SOURCE/scripts/trellis-launcher.sh"
  printf '%s\n' "$VERSION" > "$SOURCE/core-rules/VERSION"
  cat > "$SOURCE/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 2,
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
        {"source_children": "core-rules/codex/hooks", "destination_dir": ".codex/hooks", "entry_type": "file", "suffix": ".sh", "executable": true},
        {"source_children": "core-rules/codex/hooks/lib", "destination_dir": ".codex/hooks/lib", "entry_type": "file", "suffix": ".sh", "executable": true}
      ],
      "render": [
        {"template": "core-rules/templates/codex-hooks.local.json", "destination": ".codex/hooks.json", "merge": "explicit-json", "mode": "0600", "required": false}
      ]
    },
    "pi": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".pi/rules/trellis.md"},
        {"source_children": "core-rules/codex/hooks", "destination_dir": ".pi/hooks", "entry_type": "file", "suffix": ".sh", "executable": true},
        {"source_children": "core-rules/codex/hooks/lib", "destination_dir": ".pi/hooks/lib", "entry_type": "file", "suffix": ".sh", "executable": true}
      ],
      "render": []
    },
    "shared_agents": {
      "links": [
        {"project_target": "CLAUDE.md", "fallback_source": "core-rules/CLAUDE.md", "destination": "AGENTS.md"},
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": []
    }
  }
}
JSON

  if [ "${1:-}" = deferred-context ]; then
    jq '(.harnesses.claude.render[], .harnesses.codex.render[])
      |= (.merge = "replace" | .render_if_absent = true)' \
      "$SOURCE/core-rules/inheritance-manifest.json" > "$SOURCE/core-rules/inheritance-manifest.json.next"
    mv "$SOURCE/core-rules/inheritance-manifest.json.next" "$SOURCE/core-rules/inheritance-manifest.json"
  fi

  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.email 'rollout-fixture@trellis.test'
  git -C "$SOURCE" config user.name 'Rollout Fixture'
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
  local root="$1" project_id="$2"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" config user.email 'project-fixture@trellis.test'
  git -C "$root" config user.name 'Project Fixture'
  git -C "$root" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"%s"}\n' "$project_id" > "$root/.trellis.json"
  printf '# project fixture\n' > "$root/README.md"
  git -C "$root" add .
  git -C "$root" commit -qm 'fixture project'
}

attach_root() {
  local root="$1"
  shift
  local -a harness_args=()
  local harness
  for harness in "$@"; do harness_args+=(--harness "$harness"); done
  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    bash "$REPO/scripts/attach-project.sh" attach --home "$HOME_PATH" \
      --fleet personal --release "$VERSION" "${harness_args[@]}" "$root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

# owner_for <worktree-root> — the committed owner record bound to that exact
# worktree. Matched on the owner's recorded worktree_root, never by taking the
# first file found: the second-worktree tests depend on telling two owner
# records of the SAME project apart.
owner_for() {
  local root="$1" candidate
  for candidate in "$HOME_PATH"/state/attachments/*/*.json; do
    [ -f "$candidate" ] || continue
    if [ "$(jq -r '.worktree_root' "$candidate")" = "$root" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# The wrapper always runs from here. Its core-rules/ tree is deliberately NOT
# the installed release: hook bodies differ, a canonical hook is missing, and an
# extra hook exists that no manifest declares.
make_divergent_runner() {
  local hook
  mkdir -p "$RUNNER/scripts" "$RUNNER/core-rules/hooks/lib" "$RUNNER/core-rules/templates"
  cp "$REPO/scripts/rollout-hooks.sh" "$REPO/scripts/sync-hooks.sh" \
     "$REPO/scripts/sync-codex-hooks.sh" "$RUNNER/scripts/"
  cp -R "$REPO/scripts/lib" "$RUNNER/scripts/lib"
  chmod 755 "$RUNNER/scripts/rollout-hooks.sh" "$RUNNER/scripts/sync-hooks.sh" \
    "$RUNNER/scripts/sync-codex-hooks.sh"
  for hook in "$SOURCE"/core-rules/hooks/*.sh; do
    printf '#!/usr/bin/env bash\n# DIVERGENT mutable source vintage\nexit 0\n' \
      > "$RUNNER/core-rules/hooks/$(basename "$hook")"
  done
  # One canonical hook absent from the mutable tree, one extra hook present in
  # it: the two shapes the retired raw-copy sweep reported as fleet drift.
  rm -f "$RUNNER/core-rules/hooks/session-context.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER/core-rules/hooks/never-released.sh"
  printf '#!/usr/bin/env bash\n# DIVERGENT lib vintage\n' \
    > "$RUNNER/core-rules/hooks/lib/spec-gate-core.sh"
  printf '{"hooks":{"Stop":[]}}\n' > "$RUNNER/core-rules/templates/claude-settings.json"
}

rollout() {
  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    bash "$RUNNER/scripts/rollout-hooks.sh" --home "$HOME_PATH" --fleet personal "$@"
}

# prepare_fixture — one attached claude+codex project plus the divergent runner.
prepare_fixture() {
  build_installed_release
  create_project "$PROJECT" "$PROJECT_ID"
  attach_root "$PROJECT" claude codex
  make_divergent_runner
  OWNER="$(owner_for "$PROJECT")"
  [ -n "$OWNER" ] && [ -f "$OWNER" ]
}

add_pi_only_project() {
  create_project "$PI_PROJECT" "$PI_PROJECT_ID"
  attach_root "$PI_PROJECT" pi
  PI_OWNER="$(owner_for "$PI_PROJECT")"
  [ -n "$PI_OWNER" ] && [ -f "$PI_OWNER" ]
}

# A second linked worktree of the SAME project. The retired sweep grouped rows
# by project_id and inspected only the first, so a second worktree could rot
# invisibly; the test that uses this asserts both rows are visited.
add_second_worktree() {
  git -C "$PROJECT" worktree add -q -b second-worktree "$SECOND_WORKTREE"
  attach_root "$SECOND_WORKTREE" claude codex
  SECOND_OWNER="$(owner_for "$SECOND_WORKTREE")"
  [ -n "$SECOND_OWNER" ] && [ -f "$SECOND_OWNER" ]
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
# so its registry row lists as `identity_error`.
register_drifted_sibling() {
  local sibling="$SANDBOX/projects/drifted sibling"
  create_project "$sibling" drifted-sibling
  run env TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; local_registry_register_worktree "$2" personal drifted-sibling "$3" "" "[]" "" "{}"' \
    _ "$REPO/scripts/lib/local-registry.sh" "$HOME_PATH" "$sibling"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rm -r -f "$sibling/.git"
}

# Registers a healthy, active, NON-attached worktree row: available identity,
# no attachment_id, no checkout binding, no release.
register_unattached_row() {
  local root="$SANDBOX/projects/unattached sibling"
  create_project "$root" unattached-sibling
  run env TRELLIS_HOME="$HOME_PATH" bash -c \
    '. "$1"; local_registry_register_worktree "$2" personal unattached-sibling "$3" "" "[]" "" "{}"' \
    _ "$REPO/scripts/lib/local-registry.sh" "$HOME_PATH" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# Registry surgery. Rewrites the machine-local registry directly, which is how
# the fixture reaches states (`detached`, blacklisted) that no supported command
# produces on an otherwise healthy attachment.
registry_edit() {
  local filter="$1"
  shift
  local registry="$HOME_PATH/registry.json" next="$HOME_PATH/registry.json.next"
  chmod u+w "$registry"
  jq "$@" "$filter" "$registry" > "$next"
  mv "$next" "$registry"
  chmod 600 "$registry"
}

mark_project_detached() {
  registry_edit '.projects[$key].status = "detached"' --arg key "personal/$1"
}

mark_project_excluded() {
  registry_edit '.projects[$key].metadata.legacy.blacklisted = true' --arg key "personal/$1"
}

# Hash the exact managed surface of a worktree, so "nothing was touched" is an
# assertion about bytes and link targets rather than about wording.
managed_state() {
  local root="$1"
  (
    cd "$root" || exit 1
    find .claude .codex .pi .agents AGENTS.md .trellis -print 2>/dev/null |
      LC_ALL=C sort |
      while IFS= read -r path; do
        if [ -L "$path" ]; then
          printf '%s\tlink\t%s\n' "$path" "$(readlink "$path")"
        elif [ -f "$path" ]; then
          printf '%s\tfile\t%s\n' "$path" "$(shasum -a 256 "$path" | awk '{print $1}')"
        else
          printf '%s\tdir\n' "$path"
        fi
      done
  )
}

_stub_sync_children() {
  export RH_SYNC_LOG="$BATS_TEST_TMPDIR/sync-calls"
  local name
  for name in sync-hooks.sh sync-codex-hooks.sh; do
    cat > "$RUNNER/scripts/$name" <<'SH'
#!/bin/bash
printf '%s\n' "${0##*/}" "$@" >> "$RH_SYNC_LOG"
if [ "${0##*/}" = sync-codex-hooks.sh ]; then
  exit "${RH_CODEX_SYNC_EXIT:-0}"
fi
exit "${RH_SYNC_EXIT:-0}"
SH
    chmod +x "$RUNNER/scripts/$name"
  done
}

# Bound attach arguments for an intentionally inert negative-test worktree.
# Hook suppression is setup only; successful worktree-add tests below use the
# real managed post-checkout dispatcher without any override.
donor_negative_target() {
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q -b donor-negative "$SECOND_WORKTREE"
  local identity
  identity="$(bash -c '. "$1"; local_registry_identity_for_root "$2"' \
    _ "$REPO/scripts/lib/local-registry.sh" "$SECOND_WORKTREE")"
  DONOR_ARGS=(--home "$HOME_PATH" --fleet personal --release "$VERSION"
    --harness claude --harness codex
    --expected-fleet personal --expected-project-id "$PROJECT_ID"
    --expected-root "$SECOND_WORKTREE"
    --expected-checkout-id "$(jq -r '.checkout_id' <<<"$identity")"
    --expected-worktree-id "$(jq -r '.worktree_id' <<<"$identity")"
    --expected-attachment-id '' --expected-release "$VERSION"
    --expected-harnesses-json '["claude","codex"]'
    --expected-donor-root "$PROJECT"
    --expected-donor-checkout-id "$(jq -r '.checkout_id' "$OWNER")"
    --expected-donor-worktree-id "$(jq -r '.worktree_id' "$OWNER")"
    --expected-donor-attachment-id "$(jq -r '.attachment_id' "$OWNER")"
    --expected-donor-release "$VERSION"
    --expected-donor-harnesses-json '["claude","codex"]' "$SECOND_WORKTREE")
}

donor_target_absent() {
  [ -z "$(managed_state "$SECOND_WORKTREE")" ]
  if owner_for "$SECOND_WORKTREE"; then return 1; fi
}

# ---------------------------------------------------------------------------
# Verification (--check)
# ---------------------------------------------------------------------------

@test "check verifies an attachment against its installed immutable release" {
  prepare_fixture
  rollout --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "verified: installed immutable attachment $VERSION" <<<"$output"
  grep -qF 'verified=1 failed=0 report-only=0' <<<"$output"
  grep -qF 'Fleet is in sync (1 attachment(s) verified' <<<"$output"
}

@test "a mutable source that diverges from the release does not change the verdict" {
  prepare_fixture
  before="$(managed_state "$PROJECT")"
  # The runner's core-rules/ already diverges. Widen the gap to the exact shapes
  # the retired sweep called drift: a missing lib tree, a core-rules/hooks that
  # is not even a directory, and a deleted settings template.
  rm -r -f "$RUNNER/core-rules/hooks"
  printf 'not even a hook tree\n' > "$RUNNER/core-rules/hooks"
  rm -f "$RUNNER/core-rules/templates/claude-settings.json"

  rollout --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'verified=1 failed=0 report-only=0' <<<"$output"
  # Nothing in the divergent tree reached the project, and nothing was repaired.
  [ ! -e "$PROJECT/.claude/hooks/never-released.sh" ]
  [ "$(managed_state "$PROJECT")" = "$before" ]
}

@test "a corrupted owned link is a conflict, and --check repairs nothing" {
  prepare_fixture
  leaf="$PROJECT/.claude/rules/trellis.md"
  [ -L "$leaf" ]
  rm "$leaf"
  ln -s /dev/null "$leaf"

  rollout --check
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'CONFLICT:' <<<"$output"
  grep -qF 'verified=0 failed=1 report-only=0' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ "$(readlink "$leaf")" = /dev/null ]
}

@test "a corrupted owned render is a conflict, and --check repairs nothing" {
  prepare_fixture
  render="$PROJECT/.claude/settings.local.json"
  [ -f "$render" ]
  chmod u+w "$render"
  printf '{"permissions":{"allow":["Bash(curl:*)"]}}\n' > "$render"
  render_before="$(shasum -a 256 "$render" | awk '{print $1}')"

  rollout --check
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'CONFLICT:' <<<"$output"
  grep -qF 'verified=0 failed=1' <<<"$output"
  [ "$(shasum -a 256 "$render" | awk '{print $1}')" = "$render_before" ]
}

@test "a registry-selected-release/runtime mismatch is an ownership conflict" {
  prepare_fixture
  chmod u+w "$OWNER"
  jq --arg release '9.9.9' '.release = $release' "$OWNER" > "$OWNER.next"
  mv "$OWNER.next" "$OWNER"
  chmod 600 "$OWNER"
  registry_edit '.projects[$key].checkouts |= with_entries(.value.release = $release)' \
    --arg key "personal/$PROJECT_ID" --arg release '9.9.9'
  before="$(managed_state "$PROJECT")"
  owner_before="$(shasum -a 256 "$OWNER")"
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"

  rollout --check
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  expected_reason="$(printf '%q' 'attachment ownership: runtime anchor does not exactly match the registry-selected immutable release')"
  grep -qF "CONFLICT: $expected_reason" <<<"$output"
  grep -qF 'verified=0 failed=1 report-only=0' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ "$(managed_state "$PROJECT")" = "$before" ]
  [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
  [ ! -e "$HOME_PATH/releases/9.9.9" ]
}

@test "a missing sealed release record fails bound hook ownership without repair" {
  prepare_fixture
  release_dir="$HOME_PATH/releases/$VERSION"
  release_mode="$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$release_dir")"
  before="$(managed_state "$PROJECT")"
  owner_before="$(shasum -a 256 "$OWNER")"
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"
  # Keep the version bindings, runtime target, and sealed payload intact. Only
  # the private fixture's release record leaves the store; teardown owns both.
  chmod u+w "$release_dir"
  mv "$release_dir/release.json" "$SANDBOX/sealed-release.json"
  chmod "$release_mode" "$release_dir"

  rollout --check
  # Managed-hook ownership binds the release record and refuses before the
  # subsequent payload-integrity check; this is an ownership conflict (3).
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  expected_reason="$(printf '%q' 'attachment ownership: the required managed hook authority is missing, disabled, modified, or escapes its recorded state')"
  grep -qF "CONFLICT: $expected_reason" <<<"$output"
  grep -qF 'verified=0 failed=1 report-only=0' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ ! -e "$release_dir/release.json" ]
  [ "$(managed_state "$PROJECT")" = "$before" ]
  [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
  chmod u+w "$release_dir"
  mv "$SANDBOX/sealed-release.json" "$release_dir/release.json"
  chmod "$release_mode" "$release_dir"
}

@test "a second worktree is verified in its own right, not folded into the first" {
  prepare_fixture
  add_second_worktree
  first_before="$(managed_state "$PROJECT")"
  # Break ONLY the second worktree. The retired sweep grouped by project_id and
  # inspected group_by(.project_id)[0], so this state reported as fully in sync.
  rm "$SECOND_WORKTREE/.trellis/runtime"

  rollout --check --project "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'Selected rows: 2' <<<"$output"
  grep -qF 'verified=1 failed=1 report-only=0' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ "$(managed_state "$PROJECT")" = "$first_before" ]
}

@test "a Pi-only attachment verifies without any Claude surface" {
  prepare_fixture
  add_pi_only_project

  rollout --check --project "$PI_PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'Selected rows: 1' <<<"$output"
  grep -qF "verified: installed immutable attachment $VERSION for pi" <<<"$output"
  grep -qF 'verified=1 failed=0 report-only=0' <<<"$output"
  [ -L "$PI_PROJECT/.pi/rules/trellis.md" ]
  [ ! -e "$PI_PROJECT/.claude/hooks" ]
}

@test "an unavailable row is a failure and its root is never reconstructed" {
  prepare_fixture
  record_unavailable_row

  rollout --check
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'UNAVAILABLE: registered root is not present' <<<"$output"
  grep -qF 'verified=1 failed=1 report-only=0' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ ! -e "$UNAVAILABLE_ROOT" ]
}

@test "an identity-error row is preserved as a failure, not dropped" {
  prepare_fixture
  register_drifted_sibling

  rollout --check
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'IDENTITY ERROR: registry row failed identity validation' <<<"$output"
  grep -qF 'drifted-sibling' <<<"$output"
  grep -qF 'verified=1 failed=1 report-only=0' <<<"$output"
}

@test "a scoped run still fails on an identity-error row outside the selection" {
  prepare_fixture
  register_drifted_sibling

  rollout --check --project "$PROJECT_ID"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'Selected rows: 1' <<<"$output"
  grep -qF 'verified=1 failed=0 report-only=0' <<<"$output"
  grep -qF 'outside this selection failed identity validation' <<<"$output"
  grep -qF 'verification incomplete' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
}

@test "excluded and detached inventory rows are report-only and counted apart" {
  prepare_fixture
  add_pi_only_project
  create_project "$DETACHED_PROJECT" detached-project
  attach_root "$DETACHED_PROJECT" claude
  detached_before="$(managed_state "$DETACHED_PROJECT")"
  mark_project_excluded "$PI_PROJECT_ID"
  mark_project_detached detached-project

  rollout --check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'report-only: explicitly excluded inventory row' <<<"$output"
  grep -qF 'report-only: detached inventory row' <<<"$output"
  grep -qF 'verified=1 failed=0 report-only=2' <<<"$output"
  grep -qF 'Fleet is in sync (1 attachment(s) verified' <<<"$output"
  [ "$(managed_state "$DETACHED_PROJECT")" = "$detached_before" ]
}

@test "a zero verified population says so instead of claiming the fleet is in sync" {
  prepare_fixture
  mark_project_excluded "$PROJECT_ID"

  rollout --check
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  grep -qF 'verified=0 failed=0 report-only=1' <<<"$output"
  grep -qF 'no attachments verified' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
}

@test "an active worktree with no committed attachment is a failure" {
  prepare_fixture
  register_unattached_row

  rollout --check --project unattached-sibling
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'UNATTACHED: active worktree has no committed immutable attachment' <<<"$output"
  grep -qF 'verified=0 failed=1 report-only=0' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
}

@test "a project absent from the selected fleet is a selection error" {
  prepare_fixture

  rollout --check --project no-such-project
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  grep -qF 'project not in local registry fleet personal: no-such-project' <<<"$output"
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

@test "apply restores an absent runtime anchor and managed library availability" {
  prepare_fixture
  lib_leaf="$PROJECT/.claude/hooks/lib/spec-gate-core.sh"
  [ -L "$lib_leaf" ]
  expected_target="$(readlink "$lib_leaf")"
  anchor_target="$(readlink "$PROJECT/.trellis/runtime")"
  [ -f "$lib_leaf" ]
  rm "$PROJECT/.trellis/runtime"
  [ -L "$lib_leaf" ]
  [ ! -e "$lib_leaf" ]
  [ "$(readlink "$lib_leaf")" = "$expected_target" ]

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'Fleet is in sync (1 attachment(s) verified' <<<"$output"
  [ -L "$lib_leaf" ]
  [ -f "$lib_leaf" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$anchor_target" ]
  # Repaired from the installed release, never from the divergent mutable tree.
  [ "$(readlink "$lib_leaf")" = "$expected_target" ]
  if grep -rqF 'DIVERGENT' "$PROJECT/.claude/hooks/"; then
    echo 'mutable source reached the project'
    false
  fi
  [ ! -e "$PROJECT/.claude/hooks/never-released.sh" ]
}

@test "apply restores an absent managed dispatcher and hooksPath without changing render keys" {
  prepare_fixture
  render="$PROJECT/.claude/settings.local.json"
  owned_before="$(jq -cS '{permissions, hooks}' "$render")"
  jq '.project_only = true' "$render" > "$render.next"
  cp "$render.next" "$render"
  rm "$render.next"
  render_before="$(shasum -a 256 "$render")"
  printf '{"project_setting":true}\n' > "$PROJECT/.claude/settings.json"
  settings_before="$(shasum -a 256 "$PROJECT/.claude/settings.json")"
  managed="$(jq -er '.git_hooks.managed_hooks_path' "$OWNER")"
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$managed" ]
  dispatcher_before="$(shasum -a 256 "$managed/pre-push")"
  [ -x "$managed/pre-push" ]
  rm "$managed/pre-push"
  git -C "$PROJECT" config --local --unset core.hooksPath
  [ ! -e "$managed/pre-push" ]
  run git -C "$PROJECT" config --local --get core.hooksPath
  [ "$status" -eq 1 ]

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'Fleet is in sync' <<<"$output"
  [ -x "$managed/pre-push" ]
  [ "$(shasum -a 256 "$managed/pre-push")" = "$dispatcher_before" ]
  [ "$(git -C "$PROJECT" config --local --get core.hooksPath)" = "$managed" ]
  [ "$(jq -cS '{permissions, hooks}' "$render")" = "$owned_before" ]
  [ "$(shasum -a 256 "$render")" = "$render_before" ]
  [ "$(shasum -a 256 "$PROJECT/.claude/settings.json")" = "$settings_before" ]
  jq -e '.project_only == true' "$render" >/dev/null
}

@test "apply is idempotent across repeated runs" {
  prepare_fixture
  render="$PROJECT/.claude/settings.local.json"
  owned_before="$(jq -cS '{permissions, hooks}' "$render")"
  render_before="$(shasum -a 256 "$render")"
  anchor_target="$(readlink "$PROJECT/.trellis/runtime")"
  rm "$PROJECT/.trellis/runtime"

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -cS '{permissions, hooks}' "$render")" = "$owned_before" ]
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$anchor_target" ]
  [ "$(shasum -a 256 "$render")" = "$render_before" ]
  after_first="$(managed_state "$PROJECT")"
  owner_first="$(shasum -a 256 "$OWNER" | awk '{print $1}')"

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$OWNER" | awk '{print $1}')" = "$owner_first" ]
  [ "$(managed_state "$PROJECT")" = "$after_first" ]
}

@test "apply preserves a project-local hook and project-owned settings" {
  prepare_fixture
  mkdir -p "$PROJECT/.claude/hooks"
  printf '#!/usr/bin/env bash\n# project-owned module-boundary hook\nexit 0\n' \
    > "$PROJECT/.claude/hooks/local-only.sh"
  chmod +x "$PROJECT/.claude/hooks/local-only.sh"
  jq -n --arg command 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/local-only.sh"' \
    '{permissions:{allow:["Bash(git status:*)"]},hooks:{Stop:[{hooks:[{type:"command",command:$command}]}]}}' \
    > "$PROJECT/.claude/settings.json"
  local_before="$(shasum -a 256 "$PROJECT/.claude/hooks/local-only.sh" | awk '{print $1}')"
  settings_before="$(shasum -a 256 "$PROJECT/.claude/settings.json" | awk '{print $1}')"
  rm "$PROJECT/.trellis/runtime"

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -x "$PROJECT/.claude/hooks/local-only.sh" ]
  [ "$(shasum -a 256 "$PROJECT/.claude/hooks/local-only.sh" | awk '{print $1}')" = "$local_before" ]
  jq -e '.permissions.allow | index("Bash(git status:*)")' "$PROJECT/.claude/settings.json" >/dev/null
  jq -e --arg command 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/local-only.sh"' \
    '.hooks.Stop == [{hooks:[{type:"command",command:$command}]}]' \
    "$PROJECT/.claude/settings.json" >/dev/null
  [ "$(shasum -a 256 "$PROJECT/.claude/settings.json" | awk '{print $1}')" = "$settings_before" ]
}

@test "--project limits the apply scope and leaves other projects untouched" {
  prepare_fixture
  other="$SANDBOX/projects/Other Attached Project"
  create_project "$other" other-attached-project
  attach_root "$other" claude codex
  other_owner="$(owner_for "$other")"
  rm "$other/.trellis/runtime"
  other_before="$(managed_state "$other")"
  other_owner_before="$(shasum -a 256 "$other_owner" | awk '{print $1}')"
  other_registry_before="$(jq -cS '.projects["personal/other-attached-project"]' "$HOME_PATH/registry.json")"
  rm "$PROJECT/.trellis/runtime"

  rollout --yes --project "$PROJECT_ID"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'Selected rows: 1' <<<"$output"
  [ -L "$PROJECT/.trellis/runtime" ]
  # The unselected project keeps its broken state: scope was honoured by both
  # the reconcilers and the sweep.
  [ ! -e "$other/.trellis/runtime" ]
  [ "$(shasum -a 256 "$other_owner" | awk '{print $1}')" = "$other_owner_before" ]
  [ "$(jq -cS '.projects["personal/other-attached-project"]' "$HOME_PATH/registry.json")" = "$other_registry_before" ]
  [ "$(managed_state "$other")" = "$other_before" ]
}

@test "apply refuses an altered owned link and preserves the exact conflict" {
  prepare_fixture
  leaf="$PROJECT/.claude/rules/trellis.md"
  [ -L "$leaf" ]
  rm "$leaf"
  ln -s /dev/null "$leaf"
  before="$(managed_state "$PROJECT")"
  owner_before="$(shasum -a 256 "$OWNER")"
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"

  rollout --yes
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ "$(readlink "$leaf")" = /dev/null ]
  [ "$(managed_state "$PROJECT")" = "$before" ]
  [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
}

@test "apply refuses changed and reordered owned render keys and preserves the exact conflict" {
  prepare_fixture
  render="$PROJECT/.claude/settings.local.json"
  owned_before="$(jq -cS '{permissions, hooks}' "$render")"
  jq '.permissions.allow = ["Bash(curl:*)"] | .hooks |= with_entries(.value |= reverse)' \
    "$render" > "$render.next"
  cp "$render.next" "$render"
  rm "$render.next"
  [ "$(jq -cS '{permissions, hooks}' "$render")" != "$owned_before" ]
  render_before="$(shasum -a 256 "$render")"
  before="$(managed_state "$PROJECT")"
  owner_before="$(shasum -a 256 "$OWNER")"
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"

  rollout --yes
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  if grep -qF 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  [ "$(shasum -a 256 "$render")" = "$render_before" ]
  [ "$(managed_state "$PROJECT")" = "$before" ]
  [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
}

@test "apply verification re-reads the registry instead of trusting pre-apply rows" {
  prepare_fixture
  add_pi_only_project
  # The reconcilers drive Claude and Codex only, so the Pi row is n/a to both
  # children; the wrapper must still verify it strictly from a fresh listing.
  rm "$PROJECT/.trellis/runtime"

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "verified: installed immutable attachment $VERSION for pi" <<<"$output"
  grep -qF 'verified=2 failed=0 report-only=0' <<<"$output"
  [ -L "$PROJECT/.trellis/runtime" ]
}

@test "apply forwards explicit home fleet and project to both sync children" {
  prepare_fixture
  _stub_sync_children
  expected="$(printf '%s\n' sync-hooks.sh --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID" \
    sync-codex-hooks.sh --home "$HOME_PATH" --fleet personal --yes "$PROJECT_ID")"

  run env -u TRELLIS_HOME -u TRELLIS_FLEET -u TRELLIS_CONFIG HOME="$HOME" \
    bash "$RUNNER/scripts/rollout-hooks.sh" \
    --home "$HOME_PATH" --fleet personal --project "$PROJECT_ID" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if grep -q 'command not found' <<<"$output"; then echo "$output"; false; fi
  [ "$(cat "$RH_SYNC_LOG")" = "$expected" ]
}

@test "apply propagates a raw Claude child failure and claims nothing" {
  prepare_fixture
  _stub_sync_children

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" RH_SYNC_EXIT=5 \
    bash "$RUNNER/scripts/rollout-hooks.sh" --home "$HOME_PATH" --fleet personal --yes
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  if grep -q 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
  if grep -q '^sync-codex-hooks.sh$' "$RH_SYNC_LOG"; then
    echo 'Codex child ran after Claude child failed'
    false
  fi
}

@test "apply propagates a raw Codex child failure and claims nothing" {
  prepare_fixture
  _stub_sync_children

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" RH_CODEX_SYNC_EXIT=4 \
    bash "$RUNNER/scripts/rollout-hooks.sh" --home "$HOME_PATH" --fleet personal --yes
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -q '^sync-codex-hooks.sh$' "$RH_SYNC_LOG"
  if grep -q 'Fleet is in sync' <<<"$output"; then echo "$output"; false; fi
}

@test "apply without --yes requires explicit confirmation and mutates nothing on refusal" {
  prepare_fixture
  _stub_sync_children
  before="$(managed_state "$PROJECT")"

  run env -u TRELLIS_CONFIG HOME="$HOME" TRELLIS_HOME="$HOME_PATH" \
    bash -c 'printf "n\n" | bash "$1" --home "$2" --fleet personal' \
    _ "$RUNNER/scripts/rollout-hooks.sh" "$HOME_PATH"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'aborted' <<<"$output"
  [ ! -e "$RH_SYNC_LOG" ]
  [ "$(managed_state "$PROJECT")" = "$before" ]
}

@test "a successful rollout does not tell the operator to commit managed leaves" {
  prepare_fixture
  rm "$PROJECT/.trellis/runtime"

  rollout --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if grep -qi 'commit' <<<"$output"; then echo "$output"; false; fi
  grep -qF 'Fleet is in sync' <<<"$output"
}

@test "donor render context managed worktree add inherits exact context despite poisoned HOME" {
  prepare_fixture
  context="$(jq -cS '.render_context' "$OWNER")"
  jq -e --arg home "$HOME" '.render_context.user_home == $home' "$OWNER" >/dev/null
  run env HOME=/dev/null git -C "$PROJECT" worktree add -q -b inherited-context "$SECOND_WORKTREE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  second_owner="$(owner_for "$SECOND_WORKTREE")"
  [ "$(jq -cS '.render_context' "$second_owner")" = "$context" ]
  for render in .claude/settings.local.json .codex/hooks.json; do
    jq -e --argjson context "$context" '
      [.hooks.SessionStart[].hooks[].command] as $commands
      | ($commands | length) > 0
      and all($commands[]; contains("HOME=" + $context.user_home_shell)
        and contains("TRELLIS_HOME=" + $context.trellis_home_shell)
        and contains($context.launcher_shell))
    ' "$SECOND_WORKTREE/$render" >/dev/null
  done
  run bash -c '. "$1"; attachment_verify "$2" "$3"' \
    _ "$REPO/scripts/lib/attachment.sh" "$HOME_PATH" "$second_owner"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "donor render context direct attach still derives ambient HOME and noncontextual stays null" {
  prepare_fixture
  original_home="$HOME"
  export HOME="$SANDBOX/another operator"
  mkdir -p "$HOME/.local/bin"
  cp "$original_home/.local/bin/trellis" "$HOME/.local/bin/trellis"
  create_project "$DETACHED_PROJECT" direct-context
  attach_root "$DETACHED_PROJECT" claude codex
  direct_owner="$(owner_for "$DETACHED_PROJECT")"
  jq -e --arg home "$HOME" '.render_context.user_home == $home and .render_context.launcher == ($home + "/.local/bin/trellis")' "$direct_owner" >/dev/null
  [ "$(jq -cS '.render_context' "$direct_owner")" != "$(jq -cS '.render_context' "$OWNER")" ]
  add_pi_only_project
  jq -e '.render_context == null' "$PI_OWNER" >/dev/null
  run env HOME=/dev/null git -C "$PI_PROJECT" worktree add -q -b pi-context "$SECOND_WORKTREE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  second_owner="$(owner_for "$SECOND_WORKTREE")"
  jq -e '.render_context == null' "$second_owner" >/dev/null
  [ ! -e "$SECOND_WORKTREE/.claude" ]
}

@test "donor render context null malformed wrong home and unavailable launcher refuse without mutation" {
  prepare_fixture
  donor_negative_target
  cp "$OWNER" "$SANDBOX/donor.owner.before"
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"
  donor_before="$(managed_state "$PROJECT")"
  for corruption in null malformed wrong-home unavailable-launcher; do
    cp "$SANDBOX/donor.owner.before" "$OWNER"
    case "$corruption" in
      null) jq '.render_context = null' "$OWNER" > "$OWNER.next" ;;
      malformed) jq '.render_context = {schema_version:1}' "$OWNER" > "$OWNER.next" ;;
      wrong-home) jq --arg home "$HOME" '.render_context.trellis_home = $home' "$OWNER" > "$OWNER.next" ;;
      unavailable-launcher) mv "$HOME/.local/bin/trellis" "$SANDBOX/launcher.saved" ;;
    esac
    if [ -f "$OWNER.next" ]; then mv "$OWNER.next" "$OWNER"; fi
    chmod 600 "$OWNER"
    owner_before="$(shasum -a 256 "$OWNER")"
    run env HOME=/dev/null bash "$REPO/scripts/attach-project.sh" attach "${DONOR_ARGS[@]}"
    [ "$status" -eq 3 ] || { printf '%s: %s\n' "$corruption" "$output"; false; }
    grep -qF 'expected donor' <<<"$output"
    donor_target_absent
    [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
    [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
    [ "$(managed_state "$PROJECT")" = "$donor_before" ]
    if [ "$corruption" = unavailable-launcher ]; then mv "$SANDBOX/launcher.saved" "$HOME/.local/bin/trellis"; fi
  done
}

@test "donor render context final snapshot guard rejects valid changed owner and source mutation proves guard load bearing" {
  prepare_fixture
  donor_negative_target
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"
  # Test-local wrapper changes only JSON whitespace after plan construction.
  # Both complete artifact checks still pass; only the pinned byte snapshot
  # detects the replacement. No production testing knob or sealed edit.
  wrapper="$SANDBOX/change-donor.sh"
  cat > "$wrapper" <<'SH'
source "$1"
shift
definition="$(declare -f attach_plan_from_surfaces)"
eval "${definition/attach_plan_from_surfaces/original_plan_from_surfaces}"
attach_plan_from_surfaces() {
  original_plan_from_surfaces "$@" || return "$?"
  printf '\n' >> "$DONOR_OWNER"
}
main attach "$@"
SH
  run env HOME=/dev/null DONOR_OWNER="$OWNER" bash "$wrapper" \
    "$REPO/scripts/attach-project.sh" "${DONOR_ARGS[@]}"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF 'expected donor snapshot changed before attachment preparation' <<<"$output"
  donor_target_absent
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
  run bash -c '. "$1"; attachment_verify "$2" "$3"' \
    _ "$REPO/scripts/lib/attachment.sh" "$HOME_PATH" "$OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  mutant="$RUNNER/scripts/attach-project.sh"
  python3 - "$REPO/scripts/attach-project.sh" "$mutant" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
guard = '[ -n "$donor_snapshot" ] && [ "$final_donor_snapshot" != "$donor_snapshot" ]'
assert source.count(guard) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(guard, 'false'))
PY
  run env HOME=/dev/null DONOR_OWNER="$OWNER" bash "$wrapper" "$mutant" "${DONOR_ARGS[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if grep -qF 'owner_sha256' <<<"$output"; then echo "$output"; false; fi
  second_owner="$(owner_for "$SECOND_WORKTREE")"
  [ "$(jq -cS '.render_context' "$second_owner")" = "$(jq -cS '.render_context' "$OWNER")" ]
}

@test "donor render context valid legacy null refuses contextual sibling and mutation proves missing context guard" {
  build_installed_release deferred-context
  create_project "$PROJECT" "$PROJECT_ID"
  # Untracked project-authored destinations defer both optional renders before
  # attachment, leaving a valid null-context donor and a blank sibling checkout.
  mkdir -p "$PROJECT/.claude" "$PROJECT/.codex"
  printf '{}\n' > "$PROJECT/.claude/settings.local.json"
  printf '{}\n' > "$PROJECT/.codex/hooks.json"
  attach_root "$PROJECT" claude codex
  OWNER="$(owner_for "$PROJECT")"
  jq -e '.render_context == null and (.renders | length) == 0
    and ([.pre_existing[] | select(.reason == "project-authored-render") | .path] | sort)
      == [".claude/settings.local.json", ".codex/hooks.json"]' "$OWNER" >/dev/null
  run bash -c '. "$1"; attachment_verify "$2" "$3"' \
    _ "$REPO/scripts/lib/attachment.sh" "$HOME_PATH" "$OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  make_divergent_runner
  donor_negative_target
  donor_target_absent
  owner_before="$(shasum -a 256 "$OWNER")"
  registry_before="$(shasum -a 256 "$HOME_PATH/registry.json")"
  donor_before="$(managed_state "$PROJECT")"
  diagnostic='expected donor has no valid trusted local SessionStart render context'

  run env HOME=/dev/null bash "$REPO/scripts/attach-project.sh" attach "${DONOR_ARGS[@]}"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  grep -qF "$diagnostic" <<<"$output"
  donor_target_absent
  [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
  [ "$(managed_state "$PROJECT")" = "$donor_before" ]

  # Remove only the explicit combined null/validator guard in a disposable copy.
  # A later plan rejection is not the selected-donor business diagnostic.
  mutant="$RUNNER/scripts/attach-project.sh"
  python3 - "$REPO/scripts/attach-project.sh" "$mutant" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
guard = '''      if [ "$render_context" = null ] ||
         ! attachment_contextual_render_context_validate "$render_context" "$home"; then
        attach_err 'expected donor has no valid trusted local SessionStart render context'
        return "$TRELLIS_EX_CONFLICT"
      fi
'''
assert source.count(guard) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(guard, ''))
PY
  run env HOME=/dev/null bash "$mutant" attach "${DONOR_ARGS[@]}"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  mutant_status="$status"
  run grep -qF "$diagnostic" <<<"$output"
  [ "$status" -eq 1 ]
  printf '# deleted missing-context guard: mutant exit=%s; specific diagnostic assertion exit=%s (red)\n' \
    "$mutant_status" "$status" >&3
  donor_target_absent
  [ "$(shasum -a 256 "$OWNER")" = "$owner_before" ]
  [ "$(shasum -a 256 "$HOME_PATH/registry.json")" = "$registry_before" ]
  [ "$(managed_state "$PROJECT")" = "$donor_before" ]
}
