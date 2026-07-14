#!/usr/bin/env bats
# Focused SemVer regression tests for scripts/upgrade.sh.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SEMVER_LIB="$REPO/scripts/lib/semver.sh"
UPGRADE="$REPO/scripts/upgrade.sh"

setup() {
  # shellcheck source=../lib/semver.sh disable=SC1090
  . "$SEMVER_LIB"
}

@test "numeric prerelease identifiers order rc.10 after rc.2" {
  run semver_compare 1.0.0-rc.10 1.0.0-rc.2
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run semver_compare 1.0.0-rc.10 1.0.0-rc.11
  [ "$status" -eq 0 ]
  [ "$output" = "-1" ]
}

@test "stable release orders after every prerelease of the same core" {
  run semver_compare 1.0.0 1.0.0-rc.999
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "SemVer prerelease identifier precedence follows numeric lexical and length rules" {
  [ "$(semver_compare 1.0.0-alpha.1 1.0.0-alpha.beta)" = "-1" ]
  [ "$(semver_compare 1.0.0-alpha.beta 1.0.0-beta)" = "-1" ]
  [ "$(semver_compare 1.0.0-beta.2 1.0.0-beta.11)" = "-1" ]
  [ "$(semver_compare 1.0.0-rc 1.0.0-rc.1)" = "-1" ]
}

@test "build metadata does not affect precedence" {
  run semver_compare 1.2.3-rc.1+build.7 1.2.3-rc.1+build.99
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "strict validator rejects leading zeroes and malformed prereleases" {
  ! semver_is_valid 01.0.0
  ! semver_is_valid 1.0.0-rc.01
  ! semver_is_valid 1.0.0-
  semver_is_valid v1.0.0-rc.11
}

@test "semver_max ignores malformed tags and prefers stable over prerelease" {
  run bash -c '
    . "$1"
    printf "%s\n" \
      v1.0.0-rc.2 \
      v1.0.0-rc.11 \
      v1.0.0-rc.10 \
      v1.0.0 \
      v1.0.0-rc.01 \
      version-next \
      | semver_max
  ' _ "$SEMVER_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.0.0" ]
}

@test "upgrade --check detects rc.10 to rc.11 drift from fetched tags" {
  upstream="$BATS_TEST_TMPDIR/upstream"
  consumer="$BATS_TEST_TMPDIR/consumer"
  projects="$BATS_TEST_TMPDIR/projects"
  config="$BATS_TEST_TMPDIR/trellis.config.json"
  mkdir -p "$upstream" "$consumer" "$projects"

  (
    cd "$upstream" || exit 1
    git init -q
    git -c user.name=Test -c user.email=test@example.invalid \
      commit --allow-empty -q -m release
    git tag v0.9.0
    git tag v1.0.0-rc.2
    git tag v1.0.0-rc.10
    git tag v1.0.0-rc.11
  )
  (
    cd "$consumer" || exit 1
    git init -q
    git remote add origin "$upstream"
  )

  jq -n \
    --arg trellis_root "$consumer" \
    --arg projects_root "$projects" \
    --arg user_home "$BATS_TEST_TMPDIR" \
    --arg remote "$upstream" \
    '{
      trellis_root: $trellis_root,
      projects_root: $projects_root,
      user_home: $user_home,
      maintainer_name: "Test",
      github_user: "test",
      harnesses: ["codex"],
      trellis_version: "1.0.0-rc.10",
      template: {remote: $remote, branch: "main"}
    }' > "$config"

  run env TRELLIS_CONFIG="$config" bash "$UPGRADE" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *'latest:  1.0.0-rc.11  (v1.0.0-rc.11)'* ]]
  [[ "$output" == *'drift detected.'* ]]
  [[ "$output" != *'ahead-of-canonical'* ]]
}
