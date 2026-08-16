#!/usr/bin/env bash
# Shared sealed-release fixture installer for the attachment suites.
#
# scripts/release.sh refuses pathname execution from a source checkout, so a
# fixture can no longer shell out to it directly.  The sanctioned route is the
# one release-store.bats and trellis-launcher.bats use: a bootstrap release goes
# into the store through the release-store library seam, and every later release
# is installed by the stable launcher that bootstrap payload backs.
#
# Callers set REPO_ROOT before loading this helper.

release_fixture_canonical_dir() {
  (CDPATH='' cd "$1" && pwd -P)
}

release_fixture_git() {
  local home="$1"
  shift
  HOME="$home" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

release_fixture_seal_repo() {
  local home="$1" repo="$2" version="$3"

  release_fixture_git "$home" -C "$repo" init -q || return 1
  release_fixture_git "$home" -C "$repo" config user.email fixture@example.invalid || return 1
  release_fixture_git "$home" -C "$repo" config user.name 'Trellis Fixture' || return 1
  release_fixture_git "$home" -C "$repo" config commit.gpgsign false || return 1
  release_fixture_git "$home" -C "$repo" config tag.gpgSign false || return 1
  release_fixture_git "$home" -C "$repo" config core.autocrlf false || return 1
  release_fixture_git "$home" -C "$repo" add -A || return 1
  release_fixture_git "$home" -C "$repo" -c core.hooksPath=/dev/null commit -qm "release $version" || return 1
  release_fixture_git "$home" -C "$repo" tag -a "v$version" -m "release $version" || return 1
}

# release_fixture_bootstrap <user_home> <trellis_home> <sandbox>
#
# Installs the stable launcher and a 0.0.0 bootstrap release, then points the
# machine config at it so `trellis release install` works for every later
# version.  RELEASE_FIXTURE_LAUNCHER is exported for callers that need the pinned
# launcher path.
release_fixture_bootstrap() {
  local user_home="$1" trellis_home="$2" sandbox="$3"
  local bootstrap="$sandbox/bootstrap release source"

  mkdir -p "$user_home/.local/bin" "$trellis_home" "$bootstrap/scripts" "$bootstrap/core-rules" || return 1
  user_home="$(release_fixture_canonical_dir "$user_home")" || return 1
  trellis_home="$(release_fixture_canonical_dir "$trellis_home")" || return 1
  chmod 700 "$user_home" "$trellis_home" || return 1

  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$user_home/.local/bin/trellis" || return 1
  chmod 755 "$user_home/.local/bin/trellis" || return 1
  # shellcheck disable=SC2034  # Out-parameter: the suites that source this helper read it.
  RELEASE_FIXTURE_LAUNCHER="$user_home/.local/bin/trellis"

  cp "$REPO_ROOT/scripts/trellis" "$bootstrap/scripts/trellis" || return 1
  cp "$REPO_ROOT/scripts/release.sh" "$bootstrap/scripts/release.sh" || return 1
  cp -R "$REPO_ROOT/scripts/lib" "$bootstrap/scripts/lib" || return 1
  chmod 755 "$bootstrap/scripts/trellis" "$bootstrap/scripts/release.sh" || return 1
  printf '0.0.0\n' > "$bootstrap/core-rules/VERSION" || return 1
  release_fixture_seal_repo "$user_home" "$bootstrap" 0.0.0 || return 1
  bootstrap="$(release_fixture_canonical_dir "$bootstrap")" || return 1

  HOME="$user_home" TRELLIS_HOME="$trellis_home" GIT_CONFIG_NOSYSTEM=1 bash -c \
    '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
    release-fixture-bootstrap "$REPO_ROOT/scripts/lib/release-store.sh" 0.0.0 "$bootstrap" || return 1

  jq -n --arg source "$bootstrap" --arg root "$sandbox" '{
    schema_version: 1,
    source_root: $source,
    release_remote: "fixture://bootstrap",
    active_cli_release: "0.0.0",
    default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$root]}}
  }' > "$trellis_home/config.json" || return 1
  chmod 600 "$trellis_home/config.json" || return 1
}

# release_fixture_install <user_home> <trellis_home> <version> <repo>
#
# Seals <repo> as an annotated-tag release and installs it through the launcher.
release_fixture_install() {
  local user_home="$1" trellis_home="$2" version="$3" repo="$4"

  release_fixture_seal_repo "$user_home" "$repo" "$version" || return 1
  HOME="$user_home" TRELLIS_HOME="$trellis_home" GIT_CONFIG_NOSYSTEM=1 \
    "$user_home/.local/bin/trellis" release install "$version" --remote "$repo" >/dev/null || return 1
}
