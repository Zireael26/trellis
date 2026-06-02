#!/usr/bin/env bats
# Tests for scripts/lib/sync-coverage.sh — check_core_rules_coverage.
#
# FULLY ISOLATED — every test builds its own core-rules/ fixture in a mktemp
# dir. No absolute paths are hardcoded; the lib is resolved relative to
# $BATS_TEST_DIRNAME (absolute paths would leak into the public mirror and
# trip the redaction tripwire, and the sync skips .bats substitution).

# shellcheck source=../lib/sync-coverage.sh
source "$BATS_TEST_DIRNAME/../lib/sync-coverage.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through real path so /var vs /private/var cannot diverge.
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  mkdir -p "$SANDBOX/core-rules"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: all subdirs covered by SYNC_PATHS → status 0, empty output.
# ---------------------------------------------------------------------------
@test "all subdirs in SYNC_PATHS: status 0, empty output" {
  mkdir -p "$SANDBOX/core-rules/hooks" "$SANDBOX/core-rules/skills"

  sync_paths="$(printf '%s\n' "core-rules/hooks/" "core-rules/skills/")"
  exclude=""

  run check_core_rules_coverage "$SANDBOX" "$sync_paths" "$exclude"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 2: a subdir in neither list → status 1, output names it.
# ---------------------------------------------------------------------------
@test "subdir in neither list: status 1, names the uncovered subdir" {
  mkdir -p "$SANDBOX/core-rules/hooks" "$SANDBOX/core-rules/orphan"

  sync_paths="$(printf '%s\n' "core-rules/hooks/")"
  exclude=""

  run check_core_rules_coverage "$SANDBOX" "$sync_paths" "$exclude"
  [ "$status" -eq 1 ]
  [[ "$output" == *"core-rules/orphan/"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: a subdir present ONLY in the exclude list → status 0, not in output.
# ---------------------------------------------------------------------------
@test "subdir only in exclude list: treated as covered, status 0" {
  mkdir -p "$SANDBOX/core-rules/hooks" "$SANDBOX/core-rules/evals"

  sync_paths="$(printf '%s\n' "core-rules/hooks/")"
  exclude="$(printf '%s\n' "evals")"

  run check_core_rules_coverage "$SANDBOX" "$sync_paths" "$exclude"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$output" != *"evals"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: trailing-slash and no-trailing-slash SYNC_PATHS entries both match.
# ---------------------------------------------------------------------------
@test "trailing-slash and bare SYNC_PATHS entries both match" {
  mkdir -p "$SANDBOX/core-rules/withslash" "$SANDBOX/core-rules/noslash"

  # withslash uses trailing slash; noslash uses bare form.
  sync_paths="$(printf '%s\n' "core-rules/withslash/" "core-rules/noslash")"
  exclude=""

  run check_core_rules_coverage "$SANDBOX" "$sync_paths" "$exclude"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test 5: a plain file directly under core-rules/ (not a subdir) is ignored.
# ---------------------------------------------------------------------------
@test "plain file directly under core-rules/ is ignored" {
  mkdir -p "$SANDBOX/core-rules/hooks"
  printf 'x\n' > "$SANDBOX/core-rules/VERSION"
  printf 'x\n' > "$SANDBOX/core-rules/hooks.md"

  sync_paths="$(printf '%s\n' "core-rules/hooks/")"
  exclude=""

  run check_core_rules_coverage "$SANDBOX" "$sync_paths" "$exclude"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
