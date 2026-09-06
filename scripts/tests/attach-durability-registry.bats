#!/usr/bin/env bats
# WS-A coverage for spec 044 (attach durability): registry rebuild duplicate
# diagnostics (R1.1), registry deregister (R1.2), adopt dead-row naming (R1.3),
# adopt uniformity diagnostics (R2.1), adopt template-dropped owned keys (R4.2).
#
# Every case uses a temporary --home fixture. No `trellis` command ever runs
# against the real home.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/scripts/registry.sh"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"
SOURCE_RELEASE="$REPO_ROOT/scripts/release.sh"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

configure_fleet() {
  local fleet="$1"
  jq -n --arg fleet "$fleet" --arg root "$SANDBOX" \
    '{schema_version: 1, source_root: $root, release_remote: $root,
      active_cli_release: "0.0.0", default_fleet: $fleet,
      fleets: {($fleet): {discovery_roots: [$root]}}}' > "$TRELLIS_HOME_FIX/config.json"
  chmod 600 "$TRELLIS_HOME_FIX/config.json"
}

make_repo() {
  local path="$1" project_id="$2"
  mkdir -p "$path"
  git init -q -b main "$path"
  git -C "$path" config user.email attach-durability@example.invalid
  git -C "$path" config user.name 'Attach Durability'
  printf '{"schema_version":1,"project_id":"%s"}\n' "$project_id" > "$path/.trellis.json"
  printf 'fixture\n' > "$path/README"
  git -C "$path" add .trellis.json README
  git -C "$path" commit -q -m fixture
}

register_repo() {
  local fleet="$1" project_id="$2" path="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    . "$1"
    local_registry_register_worktree "$2" "$3" "$4" "$5" "" "[]" "" "{}"
  ' attach-durability-register "$REGISTRY_LIB" "$TRELLIS_HOME_FIX" "$fleet" "$project_id" "$path"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# Lazily bootstraps an installed 0.0.0 release from the CURRENT working tree
# (release-store.bats seam) so `adopt` runs under test. Idempotent per test.
ensure_release_launcher() {
  [ -n "${RELEASE_INSTALLED:-}" ] && return 0
  local bootstrap="$SANDBOX/bootstrap-release"
  mkdir -p "$bootstrap/core-rules" "$bootstrap/scripts"
  printf '0.0.0\n' > "$bootstrap/core-rules/VERSION"
  printf '# bootstrap\n' > "$bootstrap/core-rules/CLAUDE.md"
  cp "$REPO_ROOT/scripts/release.sh" "$bootstrap/scripts/release.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$bootstrap/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$bootstrap/scripts/lib"
  (CDPATH= cd "$bootstrap" && git init -q -b main && \
    git config user.email bootstrap@example.invalid && \
    git config user.name Bootstrap && \
    git config commit.gpgsign false && git config tag.gpgSign false && \
    git add -A && git commit -q -m bootstrap && \
    git tag -a v0.0.0 -m bootstrap) || return 1
  TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    attach-durability-bootstrap "$REGISTRY_LIB_DIR/release-store.sh" "0.0.0" "$bootstrap" || return 1
  RELEASE="$TRELLIS_HOME_FIX/releases/0.0.0/payload/scripts/release.sh"
  export TRELLIS_VERIFIED_PAYLOAD="$TRELLIS_HOME_FIX/releases/0.0.0/payload"
  export TRELLIS_VERIFIED_RELEASE_VERSION="0.0.0"
  export TRELLIS_VERIFIED_SSH_AUTH_SOCK=""
  RELEASE_INSTALLED=1
}

# Minimal installable release whose claude harness renders the given settings
# template with explicit-json merge.
build_template_release() {
  local version="$1" template_src="$2" repo
  repo="$SANDBOX/release-$version"
  mkdir -p "$repo/core-rules/templates" "$repo/core-rules/githooks" "$repo/scripts"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  printf '# rules %s\n' "$version" > "$repo/core-rules/CLAUDE.md"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}],
      "render": [
        {
          "template": "core-rules/templates/claude-settings.local.json",
          "destination": ".claude/settings.local.json",
          "merge": "explicit-json",
          "mode": "0600",
          "required": true
        }
      ]
    },
    "codex": {
      "links": [{"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}],
      "render": []
    }
  }
}
JSON
  cp "$template_src" "$repo/core-rules/templates/claude-settings.local.json" || return 1
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  cp "$REPO_ROOT/scripts/release.sh" "$repo/scripts/release.sh" || return 1
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib" || return 1
  ln -s core-rules/CLAUDE.md "$repo/AGENTS.md"
  (CDPATH= cd "$repo" && git init -q -b main && \
    git config user.email template-release@example.invalid && \
    git config user.name 'Template Release' && \
    git config commit.gpgsign false && git config tag.gpgSign false && \
    git config core.autocrlf false && \
    git add -A && git commit -q -m "release $version" && \
    git tag -a "v$version" -m "release $version") || return 1
  printf '%s\n' "$repo"
}

install_template_release() {
  local version="$1" repo="$2"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" install "$version" --remote "$repo"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

attach_portable_project() {
  local root="$1" fleet="$2" version="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$ATTACH" \
    attach --home "$TRELLIS_HOME_FIX" --fleet "$fleet" --release "$version" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/attach-durability-registry.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  OPERATOR_HOME="$SANDBOX/operator home"
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home"
  REGISTRY_LIB_DIR="$REPO_ROOT/scripts/lib"
  mkdir -p "$OPERATOR_HOME" "$TRELLIS_HOME_FIX"
  # release.sh admits a TMPDIR candidate only when it is a private mode-0700
  # `.cmd.*` child of this home's command scratch root, the shape the stable
  # launcher builds. install_template_release drives the installed payload by
  # pathname, so it inherits the Git fence's own TMPDIR; build the
  # launcher-shaped directory here or the release command exits 4 unstarted.
  COMMAND_SCRATCH="$TRELLIS_HOME_FIX/state/scratch/.cmd.attach-durability"
  mkdir -p "$COMMAND_SCRATCH"
  chmod 700 "$TRELLIS_HOME_FIX" "$TRELLIS_HOME_FIX/state" \
    "$TRELLIS_HOME_FIX/state/scratch" "$COMMAND_SCRATCH"
  export TMPDIR="$COMMAND_SCRATCH"
  export HOME="$OPERATOR_HOME"
  export TRELLIS_HOME="$TRELLIS_HOME_FIX"
  # attach derives its trusted render context from the operator launcher.
  mkdir -p "$OPERATOR_HOME/.local/bin"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$OPERATOR_HOME/.local/bin/trellis"
  chmod 755 "$OPERATOR_HOME/.local/bin/trellis"
  RELEASE_INSTALLED=""
  RELEASE=""
  configure_fleet personal
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

@test "rebuild names duplicated project IDs and their manifests" {
  dup_root="$SANDBOX/duplicate-projects"
  make_repo "$dup_root/one" duplicate-id
  make_repo "$dup_root/two" duplicate-id

  run bash "$REGISTRY" rebuild --home "$TRELLIS_HOME_FIX" --fleet personal "$dup_root"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"duplicate-id"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$dup_root/one/.trellis.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$dup_root/two/.trellis.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *'rebuild found duplicate project IDs in selected roots'* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/registry.json" ]
}

@test "deregister removes a dead row" {
  project="$SANDBOX/dead-row-project"
  make_repo "$project" dead-row
  register_repo personal dead-row "$project"
  rm -rf "$project"

  run bash "$REGISTRY" deregister --home "$TRELLIS_HOME_FIX" --fleet personal --project dead-row
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"deregistered: dead-row $project"* ]] || { echo "$output"; false; }
  run bash "$REGISTRY" list --home "$TRELLIS_HOME_FIX" --fleet personal --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq '.entries | length')" -eq 0 ] || { echo "$output"; false; }
}

@test "deregister removes a row whose path is present but not a Git worktree" {
  # REGRESSION: the strict reader fails the WHOLE listing on a row whose path
  # exists but cannot be resolved as a canonical Git worktree, and that row is
  # exactly what deregister exists to remove. Measured 2026-09-04: a husk
  # directory left where an affected consumer worktree had been made every deregister
  # in the fleet exit 4, so the dead rows could not be cleared at all.
  project="$SANDBOX/husk-project"
  make_repo "$project" husk-row
  register_repo personal husk-row "$project"
  rm -rf "$project"
  mkdir -p "$project/infra"          # present, but no longer a Git worktree

  run bash "$REGISTRY" deregister --home "$TRELLIS_HOME_FIX" --fleet personal --project husk-row --force
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"deregistered: husk-row $project"* ]] || { echo "$output"; false; }
}

@test "deregister refuses a live row without --force" {
  project="$SANDBOX/live-row-project"
  make_repo "$project" live-row
  register_repo personal live-row "$project"

  run bash "$REGISTRY" deregister --home "$TRELLIS_HOME_FIX" --fleet personal --project live-row
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"live-row"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$project"* ]] || { echo "$output"; false; }
  run bash "$REGISTRY" list --home "$TRELLIS_HOME_FIX" --fleet personal --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq -r '.entries[0].project_id')" = live-row ]
}

@test "deregister accepts --force on a live row" {
  project="$SANDBOX/force-row-project"
  make_repo "$project" force-row
  register_repo personal force-row "$project"

  run bash "$REGISTRY" deregister --home "$TRELLIS_HOME_FIX" --fleet personal --worktree-root "$project" --force
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"deregistered: force-row $project"* ]] || { echo "$output"; false; }
  run bash "$REGISTRY" list --home "$TRELLIS_HOME_FIX" --fleet personal --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq '.entries | length')" -eq 0 ] || { echo "$output"; false; }
}

@test "deregister errors on zero matches" {
  project="$SANDBOX/unrelated-project"
  make_repo "$project" unrelated
  register_repo personal unrelated "$project"

  run bash "$REGISTRY" deregister --home "$TRELLIS_HOME_FIX" --fleet personal --project no-such-project
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"no-such-project"* ]] || { echo "$output"; false; }
  run bash "$REGISTRY" list --home "$TRELLIS_HOME_FIX" --fleet personal --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | jq '.entries | length')" -eq 1 ] || { echo "$output"; false; }
}

@test "adopt names a registry row whose root is gone" {
  ensure_release_launcher
  install_template_release 1.6.0 "$(build_template_release 1.6.0 "$REPO_ROOT/core-rules/templates/claude-settings.local.json")"
  project="$SANDBOX/gone-root-project"
  make_repo "$project" gone-root
  register_repo personal gone-root "$project"
  checkout="$(TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$REGISTRY" list --home "$TRELLIS_HOME_FIX" --fleet personal --json | jq -r '.entries[0].checkout_id')"
  rm -rf "$project"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.6.0 --project gone-root --fleet personal
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$project"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$checkout"* ]] || { echo "$output"; false; }
  [[ "$output" == *"personal/gone-root"* ]] || { echo "$output"; false; }
}

@test "adopt on a mixed-version checkout names both versions" {
  ensure_release_launcher
  plans="$SANDBOX/mixed-plans.jsonl"
  cat > "$plans" <<'JSON'
{"row":{"fleet":"personal","project_id":"mixed-version"},"old_version":"1.6.0","managed":"/x/state/git-hooks/abc","hooks":"true"}
{"row":{"fleet":"personal","project_id":"mixed-version"},"old_version":"1.6.1","managed":"/x/state/git-hooks/abc","hooks":"true"}
JSON
  run bash -c '
    export TRELLIS_HOME="$0" TRELLIS_VERIFIED_PAYLOAD="$1" TRELLIS_VERIFIED_RELEASE_VERSION=0.0.0
    export TRELLIS_RELEASE_CLEAN_ENV=1 TRELLIS_RELEASE_BUNDLE_PRELOAD=1
    . "$2"
    adopt_group_require_uniform "$3"
  ' "$TRELLIS_HOME_FIX" "$TRELLIS_HOME_FIX/releases/0.0.0/payload" "$RELEASE" "$plans"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"1.6.0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"1.6.1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"personal/mixed-version"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis registry deregister --fleet personal --project mixed-version"* ]] || { echo "$output"; false; }

  cat > "$plans" <<'JSON'
{"row":{"fleet":"personal","project_id":"mixed-version"},"old_version":"1.6.1","managed":"/x/state/git-hooks/abc","hooks":"true"}
{"row":{"fleet":"personal","project_id":"mixed-version"},"old_version":"1.6.1","managed":"/x/state/git-hooks/abc","hooks":"true"}
JSON
  run bash -c '
    export TRELLIS_HOME="$0" TRELLIS_VERIFIED_PAYLOAD="$1" TRELLIS_VERIFIED_RELEASE_VERSION=0.0.0
    export TRELLIS_RELEASE_CLEAN_ENV=1 TRELLIS_RELEASE_BUNDLE_PRELOAD=1
    . "$2"
    adopt_group_require_uniform "$3"
  ' "$TRELLIS_HOME_FIX" "$TRELLIS_HOME_FIX/releases/0.0.0/payload" "$RELEASE" "$plans"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"non-uniform"* ]] || { echo "$output"; false; }
}

@test "adopt reports template-dropped owned keys" {
  ensure_release_launcher
  template_a="$SANDBOX/template-a.json"
  template_b="$SANDBOX/template-b.json"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$template_a"
  jq 'del(.permissions.deny)' "$template_a" > "$template_b" || false
  [ "$(jq -r '.permissions | has("deny")' "$template_b")" = false ]
  install_template_release 1.6.0 "$(build_template_release 1.6.0 "$template_a")"
  install_template_release 1.6.1 "$(build_template_release 1.6.1 "$template_b")"
  project="$SANDBOX/template-drop-project"
  make_repo "$project" template-drop
  attach_portable_project "$project" personal 1.6.0
  destination="$project/.claude/settings.local.json"
  [ -f "$destination" ]
  jq -e '.permissions.deny == []' "$destination" >/dev/null

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.6.1 --project template-drop --fleet personal
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"left in place (no longer in template): .claude/settings.local.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *'"permissions","deny"'* ]] || { echo "$output"; false; }
  jq -e '.permissions.deny == []' "$destination" >/dev/null
}
