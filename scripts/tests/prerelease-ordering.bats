#!/usr/bin/env bats
# R27: the production historical-witness predicate and legacy doctor's maximum.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  # shellcheck source=../attach-project.sh disable=SC1091
  . "$REPO_ROOT/scripts/attach-project.sh" || return 1
  # shellcheck source=../lib/health-checks.sh disable=SC1091
  . "$REPO_ROOT/scripts/lib/health-checks.sh" || return 1
}

@test "prerelease current runtime accepts an older stable historical witness" {
  run attach_reconcile_release_is_older 1.3.11 1.3.12-a
  [ "$status" -eq 0 ] || return 1
}

@test "stable current runtime accepts its same-core prerelease historical witness" {
  run attach_reconcile_release_is_older 1.3.12-a 1.3.12
  [ "$status" -eq 0 ] || return 1
}

@test "newer prerelease is predicate-false, not a parse error, for an older stable" {
  run attach_reconcile_release_is_older 1.3.12-a 1.3.11
  [ "$status" -eq 1 ] || return 1
}

@test "doctor chooses same-core stable over prerelease" {
  run hc_higher_version 1.3.12-a 1.3.12
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "1.3.12" ] || return 1
}

@test "doctor chooses newer-core prerelease without version-sort" {
  # This pair also passed sort -V: make that forbidden dependency observable.
  sort() { return 1; }
  run hc_higher_version 1.3.11 1.3.12-a
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "1.3.12-a" ] || return 1
}
