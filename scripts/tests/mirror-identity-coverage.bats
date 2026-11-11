#!/usr/bin/env bats
# Mirror lint sees private tokens in names, identifiers and binary-classified files.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/mirror-coverage.XXXXXX")"; MIRROR="$SANDBOX/mirror"; mkdir -p "$MIRROR"
  TRELLIS_MIRROR_IDENTITY_SOURCE="$SANDBOX/registry.json"
  printf '%s\n' '{"projects":{"work/fixtureproj":{"project_id":"fixtureproj"},"work/otherfixture":{"project_id":"otherfixture"}}}' > "$TRELLIS_MIRROR_IDENTITY_SOURCE"
  export TRELLIS_MIRROR_IDENTITY_SOURCE
  . "$REPO_ROOT/scripts/lib/mirror-lint.sh"
}
teardown() { [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"; }

@test "private identifiers in file directory and symlink names are rejected" {
  mkdir -p "$MIRROR/docs/fixtureproj-archive" "$MIRROR/fixtureprojection"
  printf 'safe\n' > "$MIRROR/docs/fixtureproj-runbook.md"
  printf 'safe\n' > "$MIRROR/fixtureprojection/readme.md"
  ln -s fixtureprojection "$MIRROR/fixtureproj-link"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'docs/fixtureproj-runbook.md: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'docs/fixtureproj-archive: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'fixtureproj-link: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" != *'fixtureprojection: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
}

@test "underscore-delimited identifiers are private but longer words remain allowed" {
  printf 'fixtureprojection is an unrelated word.\n' > "$MIRROR/readme.md"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'FIXTUREPROJ_HOME=1\n' > "$MIRROR/env.sh"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'env.sh: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
}

@test "binary-classified files do not hide fleet, proxy or retired harness tokens" {
  printf 'binary\000 fixtureprojection\n' > "$MIRROR/generic.bin"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'binary\000 fixtureproj\n' > "$MIRROR/fleet.bin"
  printf 'binary\000 %s\n' 'cli-proxy-''api' > "$MIRROR/proxy.bin"
  printf 'binary\000 %s\n' 'Anti''Gravity' > "$MIRROR/retired.bin"
  run lint_mirror "$MIRROR"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'fleet.bin: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'proxy.bin: instance-private proxy token must not publish'* ]] || { echo "$output"; false; }
  local retired_token='anti''gravity'
  [[ "$output" == *"retired.bin: stale '$retired_token' in current operator surface"* ]] || { echo "$output"; false; }
  [[ "$output" != *'generic.bin: local fleet project identifier must not publish'* ]] || { echo "$output"; false; }
}
