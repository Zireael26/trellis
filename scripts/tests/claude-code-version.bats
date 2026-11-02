#!/usr/bin/env bats
# Claude Code 2.1.294 fixed prompt-hook fail-open and the hook skip on a matcher
# failure; 2.1.295 added hook onFailure, which attach renders only at or above
# it. Doctor warns below 2.1.295, stays silent at or above it, and reports INFO
# when the installed version cannot be read. A stub CLI only: never runs claude.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/claude-version.XXXXXX")"
  mkdir -p "$SANDBOX/bin"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/attachment.sh"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
  # The stub directory plus system tools only, so a real claude is never found.
  unset TRELLIS_ATTACH_CALLER_PATH
  PATH="$SANDBOX/bin:/usr/bin:/bin"
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

stub_claude() {
  printf '#!/bin/sh\n%s\n' "$1" > "$SANDBOX/bin/claude"
  chmod 755 "$SANDBOX/bin/claude"
}

@test "below 2.1.295 -> WARN naming the installed version and the floor" {
  local version
  for version in 2.1.294 2.1.293 2.1.29 2.0.999 1.9.400; do
    stub_claude "echo '$version (Claude Code)'"
    run hc_claude_code_version
    [ "$status" -eq "$HC_WARN" ] || { echo "$version: status=$status $output"; return 1; }
    [[ "$output" == *"$version"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"2.1.295"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"onFailure"* ]] || { echo "$output"; return 1; }
  done
}

@test "at or above 2.1.295 -> silent OK" {
  local version
  for version in 2.1.295 2.1.296 2.1.1000 2.2.0 3.0.0; do
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

# The launcher runs doctor under the control PATH and forwards the caller's
# PATH as TRELLIS_ATTACH_CALLER_PATH; a claude there is the one the user runs.
@test "claude only on the forwarded caller PATH is found and read" {
  mkdir -p "$SANDBOX/caller-bin"
  printf '#!/bin/sh\necho "2.1.294 (Claude Code)"\n' > "$SANDBOX/caller-bin/claude"
  chmod 755 "$SANDBOX/caller-bin/claude"
  TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/caller-bin:/usr/bin" run hc_claude_code_version
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; return 1; }
  [[ "$output" == *"2.1.294 is below 2.1.295"* ]] || { echo "$output"; return 1; }
}

# An npm-style `#!/usr/bin/env node` claude: the runtime is only on the caller
# PATH, so the CLI child must run with it.
@test "a claude whose shebang runtime is only on the forwarded caller PATH is read" {
  mkdir -p "$SANDBOX/caller-bin"
  printf '#!/usr/bin/env claude-stub-runtime\n' > "$SANDBOX/caller-bin/claude"
  printf '#!/bin/sh\necho "2.1.294 (Claude Code)"\n' > "$SANDBOX/caller-bin/claude-stub-runtime"
  chmod 755 "$SANDBOX/caller-bin/claude" "$SANDBOX/caller-bin/claude-stub-runtime"
  TRELLIS_ATTACH_CALLER_PATH="$SANDBOX/caller-bin:/usr/bin:/bin" run hc_claude_code_version
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; return 1; }
  [[ "$output" == *"2.1.294 is below 2.1.295"* ]] || { echo "$output"; return 1; }
}

@test "the doctor floor is the attach render floor for onFailure" {
  [ "$HC_CLAUDE_CODE_MIN_VERSION" = "$ATTACHMENT_CLAUDE_ON_FAILURE_VERSION" ]
}

@test "portable doctor reports the row only when it is not healthy" {
  grep -q 'if claude_row="$(hc_claude_code_version)"; then :; else' "$REPO/scripts/doctor.sh"
}
