#!/usr/bin/env bats
# Claude Code 2.1.294 fixed prompt-hook fail-open and the hook skip on a matcher
# failure. Doctor warns below it, stays silent at or above it, and reports INFO
# when the installed version cannot be read. A stub CLI only: never runs claude.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/claude-version.XXXXXX")"
  mkdir -p "$SANDBOX/bin"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
  # The stub directory plus system tools only, so a real claude is never found.
  PATH="$SANDBOX/bin:/usr/bin:/bin"
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

stub_claude() {
  printf '#!/bin/sh\n%s\n' "$1" > "$SANDBOX/bin/claude"
  chmod 755 "$SANDBOX/bin/claude"
}

@test "below 2.1.294 -> WARN naming the installed version and the floor" {
  local version
  for version in 2.1.293 2.1.29 2.0.999 1.9.400; do
    stub_claude "echo '$version (Claude Code)'"
    run hc_claude_code_version
    [ "$status" -eq "$HC_WARN" ] || { echo "$version: status=$status $output"; return 1; }
    [[ "$output" == *"$version"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"2.1.294"* ]] || { echo "$output"; return 1; }
  done
}

@test "at or above 2.1.294 -> silent OK" {
  local version
  for version in 2.1.294 2.1.295 2.1.1000 2.2.0 3.0.0; do
    stub_claude "echo '$version (Claude Code)'"
    run hc_claude_code_version
    [ "$status" -eq "$HC_OK" ] || { echo "$version: status=$status $output"; return 1; }
    [ -z "$output" ] || { echo "$version: $output"; return 1; }
  done
}

@test "a version the CLI cannot report -> INFO, never OK or WARN" {
  local body
  for body in 'exit 1' "echo 'Claude Code'" 'echo 2.1' 'printf ""'; do
    stub_claude "$body"
    run hc_claude_code_version
    [ "$status" -eq "$HC_INFO" ] || { echo "$body: status=$status $output"; return 1; }
    [[ "$output" == *"unreadable"* ]] || { echo "$body: $output"; return 1; }
  done
}

@test "claude absent from PATH -> INFO" {
  run hc_claude_code_version
  [ "$status" -eq "$HC_INFO" ]
  [[ "$output" == *"unreadable"* ]]
  [[ "$output" == *"not found"* ]]
}

@test "portable doctor reports the row only when it is not healthy" {
  grep -q 'if claude_row="$(hc_claude_code_version)"; then :; else' "$REPO/scripts/doctor.sh"
}
