#!/usr/bin/env bats
SOURCE_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/fixture-clone
load helpers/historical-releases

setup() {
  REPO_ROOT="$BATS_TEST_TMPDIR/repo"
  RUN_ROOT="$BATS_TEST_TMPDIR/run"
  BUILD_LOG="$BATS_TEST_TMPDIR/builds"
  mkdir -p "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/tests/helpers" "$RUN_ROOT"
  for file in scripts/lib/release-store.sh scripts/lib/semver.sh scripts/release.sh scripts/attach-project.sh \
    scripts/seed-inheritance-symlinks.sh scripts/tests/helpers/group-plan.bash \
    scripts/tests/helpers/payload-fixture.bash scripts/tests/helpers/fixture-clone.bash \
    scripts/tests/helpers/historical-releases.bash; do
    printf '# %s\n' "$file" > "$REPO_ROOT/$file"
  done
  printf 'fixture\n' > "$REPO_ROOT/core-rules/VERSION"
  git -C "$REPO_ROOT" init -q
  git -C "$REPO_ROOT" config user.name Fixture
  git -C "$REPO_ROOT" config user.email fixture@example.invalid
  git -C "$REPO_ROOT" config commit.gpgsign false
  git -C "$REPO_ROOT" config core.hooksPath /dev/null
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm fixture
  for version in 1.3.6 1.3.7 1.3.8 1.3.9 1.3.10; do
    git -C "$REPO_ROOT" tag "v$version"
  done
  unset TRELLIS_TEST_HISTORICAL_RELEASES
}

teardown() {
  find "$BATS_TEST_TMPDIR" -type d -exec chmod u+w {} +
}

# The expensive builder is a seam; the real five-release output is exercised
# by release-store-part1. This spy measures rebuilds without precomputing tests.
group_plan_build_release_cache() {
  printf '%s\n' "$1" >> "$BUILD_LOG"
  local version
  for version in 1.3.6 1.3.7 1.3.8 1.3.9 1.3.10; do
    mkdir -p "$1/trellis-home/releases/$version"
    printf 'release %s\n' "$version" > "$1/trellis-home/releases/$version/payload"
    chmod 444 "$1/trellis-home/releases/$version/payload"
    chmod 555 "$1/trellis-home/releases/$version"
  done
}

@test "historical fixture builds once per key under the run root and is read only" {
  historical_releases_prepare "$RUN_ROOT"
  local cache="$TRELLIS_TEST_HISTORICAL_RELEASES"
  [ "$cache" = "$RUN_ROOT/historical-releases/$(historical_releases_key)" ]
  (cd "$RUN_ROOT" && historical_releases_prepare "$RUN_ROOT")
  [ "$(wc -l < "$BUILD_LOG" | tr -d ' ')" -eq 1 ]
  python3 -I - "$cache" <<'PY'
import os
import sys
from pathlib import Path
root = Path(sys.argv[1])
for path in [root, *root.rglob('*')]:
    assert not os.lstat(path).st_mode & 0o222, path
assert len(list((root / 'trellis-home/releases').iterdir())) == 5
PY
}

@test "every tag tree HEAD surface helper live script and Git version change rebuilds" {
  historical_releases_prepare "$RUN_ROOT"
  local previous="$TRELLIS_TEST_HISTORICAL_RELEASES" file version expected=1
  for file in scripts/lib/release-store.sh scripts/lib/semver.sh scripts/release.sh scripts/attach-project.sh \
    scripts/seed-inheritance-symlinks.sh scripts/tests/helpers/group-plan.bash \
    scripts/tests/helpers/payload-fixture.bash scripts/tests/helpers/fixture-clone.bash \
    scripts/tests/helpers/historical-releases.bash scripts/tests/helpers/payload-fixture-extra.bash; do
    printf '# changed\n' >> "$REPO_ROOT/$file"
    historical_releases_prepare "$RUN_ROOT"
    [ "$TRELLIS_TEST_HISTORICAL_RELEASES" != "$previous" ]
    previous="$TRELLIS_TEST_HISTORICAL_RELEASES"
    expected=$((expected + 1))
  done
  for version in 1.3.6 1.3.7 1.3.8 1.3.9 1.3.10; do
    printf '%s\n' "$version" > "$REPO_ROOT/core-rules/VERSION"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" commit -qm "$version"
    # First isolate HEAD's archived trees; then move just this tag.
    historical_releases_prepare "$RUN_ROOT"
    [ "$TRELLIS_TEST_HISTORICAL_RELEASES" != "$previous" ]
    previous="$TRELLIS_TEST_HISTORICAL_RELEASES"
    git -C "$REPO_ROOT" tag -f "v$version" >/dev/null
    historical_releases_prepare "$RUN_ROOT"
    [ "$TRELLIS_TEST_HISTORICAL_RELEASES" != "$previous" ]
    previous="$TRELLIS_TEST_HISTORICAL_RELEASES"
    expected=$((expected + 2))
  done
  git() {
    if [ "$1" = --version ]; then printf 'git version changed\n'; else command git "$@"; fi
  }
  historical_releases_prepare "$RUN_ROOT"
  [ "$TRELLIS_TEST_HISTORICAL_RELEASES" != "$previous" ]
  [ "$(wc -l < "$BUILD_LOG" | tr -d ' ')" -eq "$((expected + 1))" ]
}

@test "matching historical fixture copies to the existing suite path with isolated inodes" {
  historical_releases_prepare "$RUN_ROOT"
  historical_releases_copy_or_build "$BATS_TEST_TMPDIR/first"
  historical_releases_copy_or_build "$BATS_TEST_TMPDIR/second"
  [ "$(wc -l < "$BUILD_LOG" | tr -d ' ')" -eq 1 ]
  local relative=trellis-home/releases/1.3.6/payload
  chmod u+w "$BATS_TEST_TMPDIR/first/$relative"
  printf 'changed\n' > "$BATS_TEST_TMPDIR/first/$relative"
  [ "$(< "$TRELLIS_TEST_HISTORICAL_RELEASES/$relative")" = 'release 1.3.6' ]
  [ "$(< "$BATS_TEST_TMPDIR/second/$relative")" = 'release 1.3.6' ]
}

@test "standalone missing stale and incomplete historical fixtures build locally" {
  historical_releases_copy_or_build "$BATS_TEST_TMPDIR/standalone"
  historical_releases_prepare "$RUN_ROOT"
  local cache="$TRELLIS_TEST_HISTORICAL_RELEASES"
  printf '# stale\n' >> "$REPO_ROOT/scripts/lib/release-store.sh"
  historical_releases_copy_or_build "$BATS_TEST_TMPDIR/stale"
  historical_releases_prepare "$RUN_ROOT"
  chmod u+w "$TRELLIS_TEST_HISTORICAL_RELEASES"
  rm "$TRELLIS_TEST_HISTORICAL_RELEASES/.complete"
  historical_releases_copy_or_build "$BATS_TEST_TMPDIR/incomplete"
  [ "$(wc -l < "$BUILD_LOG" | tr -d ' ')" -eq 5 ]
  [ "$TRELLIS_TEST_HISTORICAL_RELEASES" != "$cache" ]
  local destination
  for destination in standalone stale incomplete; do
    [ -f "$BATS_TEST_TMPDIR/$destination/trellis-home/releases/1.3.10/payload" ]
  done
}

@test "a failed historical build never publishes a complete cache or export" {
  group_plan_build_release_cache() { return 7; }
  run historical_releases_prepare "$RUN_ROOT"
  [ "$status" -eq 1 ]
  [ -z "${TRELLIS_TEST_HISTORICAL_RELEASES:-}" ]
  [ -z "$(find "$RUN_ROOT" -name .complete -print)" ]
}

@test "historical key fails rather than reusing a fixture when a required tag is missing" {
  git -C "$REPO_ROOT" tag -d v1.3.7 >/dev/null
  run historical_releases_prepare "$RUN_ROOT"
  [ "$status" -eq 1 ]
  [ ! -e "$BUILD_LOG" ]
}

@test "runner pre-phase builds only for its selected historical stage and ignores inbound cache" {
  # Execute the runner's pre-phase, not the battery. Fake inputs and the builder
  # spy keep this scheduling check cheap while retaining the real key/copy code.
  local prephase ROOT="$REPO_ROOT" LIST=0 SHARD_INDEX=1 STAGE_INDEX
  local TRELLIS_TEST_GIT_FENCE_ROOT="$RUN_ROOT" STAGE_ORDINAL=2
  local -a STAGE_NAMES STAGE_ASSIGNMENTS
  STAGE_NAMES[1]='unrelated stage'
  STAGE_NAMES[2]='bats scripts/tests/release-store-part1.bats'
  STAGE_ASSIGNMENTS[1]=1
  STAGE_ASSIGNMENTS[2]=2
  cp "$SOURCE_ROOT/scripts/tests/helpers/historical-releases.bash" "$ROOT/scripts/tests/helpers/"
  cp "$SOURCE_ROOT/scripts/tests/helpers/fixture-clone.bash" "$ROOT/scripts/tests/helpers/"
  declare -f group_plan_build_release_cache > "$ROOT/scripts/tests/helpers/group-plan.bash"
  prephase="$(python3 -I - "$SOURCE_ROOT/scripts/run-tests.sh" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.index('# Only the historical group-plan part consumes this fixture.')
end = text.index('\nfor ((STAGE_INDEX', text.index('\nfi', start))
print(text[start:end])
PY
)"
  [ -n "$prephase" ]
  export TRELLIS_TEST_HISTORICAL_RELEASES=/untrusted/inbound
  eval "$prephase"
  [ -z "${TRELLIS_TEST_HISTORICAL_RELEASES:-}" ]
  [ ! -e "$BUILD_LOG" ]
  SHARD_INDEX=2
  LIST=1
  eval "$prephase"
  [ ! -e "$BUILD_LOG" ]
  LIST=0
  eval "$prephase"
  [ "$TRELLIS_TEST_HISTORICAL_RELEASES" = "$RUN_ROOT/historical-releases/$(historical_releases_key)" ]
  eval "$prephase"
  [ "$(wc -l < "$BUILD_LOG" | tr -d ' ')" -eq 1 ]
}
