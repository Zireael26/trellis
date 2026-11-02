#!/usr/bin/env bash
# Shared only within a runner's private root. The original builder remains the
# standalone path; the adopted machine baseline is still built by setup_file.
historical_releases_key() (
  set -o pipefail
  local version file
  {
    printf 'historical-releases-v1\n'
    for version in 1.3.6 1.3.7 1.3.8 1.3.9 1.3.10; do
      git -C "$REPO_ROOT" rev-parse "refs/tags/v$version^{tree}" || exit 1
    done
    # The 1.3.10 fixture intentionally uses HEAD plus three working-tree files,
    # not its tag. Bind those too, without changing the historical builder.
    git -C "$REPO_ROOT" rev-parse HEAD:core-rules HEAD:scripts || exit 1
    for file in "$REPO_ROOT"/scripts/lib/release-store.sh "$REPO_ROOT"/scripts/lib/semver.sh \
      "$REPO_ROOT"/scripts/release.sh \
      "$REPO_ROOT"/scripts/attach-project.sh "$REPO_ROOT"/scripts/seed-inheritance-symlinks.sh \
      "$REPO_ROOT"/scripts/tests/helpers/group-plan.bash "$REPO_ROOT"/scripts/tests/helpers/payload-fixture* \
      "$REPO_ROOT"/scripts/tests/helpers/fixture-clone.bash "$REPO_ROOT"/scripts/tests/helpers/historical-releases.bash; do
      printf '%s\n' "${file#"$REPO_ROOT/"}"
      git -C "$REPO_ROOT" hash-object "$file" || exit 1
    done
    git --version || exit 1
  } | shasum -a 256 | awk '{print $1}'
)

historical_releases_prepare() {
  local run_root="$1" key cache
  key="$(historical_releases_key)" || return 1
  cache="$run_root/historical-releases/$key"
  if [ ! -f "$cache/.complete" ]; then
    # Build at the final pathname: release.json records its source remote.
    # No reader is admitted until the builder succeeds and seals the tree.
    mkdir -p "$cache" || return 1
    group_plan_build_release_cache "$cache" || return 1
    printf '%s\n' "$key" > "$cache/.complete" || return 1
    chmod -R a-w "$cache" || return 1
  fi
  TRELLIS_TEST_HISTORICAL_RELEASES="$cache"
  export TRELLIS_TEST_HISTORICAL_RELEASES
}

historical_releases_copy_or_build() {
  local destination="$1" cache="${TRELLIS_TEST_HISTORICAL_RELEASES:-}" key
  if [ -n "$cache" ]; then
    key="$(historical_releases_key)" || return 1
    if [ "${cache##*/}" = "$key" ] && [ -f "$cache/.complete" ] &&
      [ "$(< "$cache/.complete")" = "$key" ]; then
      mkdir -p "$destination/trellis-home" || return 1
      fixture_clone "$cache/trellis-home/releases" "$destination/trellis-home/releases"
      return "$?"
    fi
  fi
  printf 'historical releases: no matching runner fixture; building locally\n' >&2
  group_plan_build_release_cache "$destination"
}
