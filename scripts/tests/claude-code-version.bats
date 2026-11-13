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
  [[ "$output" == *"unreadable"* ]] || false
  [[ "$output" == *"not found"* ]] || false
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
  local report_fn claude_block
  report_fn="$(awk '/^report\(\) \{/,/^}/' "$REPO/scripts/doctor.sh")"
  [ -n "$report_fn" ] || { echo 'report function not found in doctor.sh'; false; }
  claude_block="$(awk '/if claude_row=/,/^fi$/' "$REPO/scripts/doctor.sh")"
  [[ "$claude_block" == *"report '  ' \"\$?\" \"\$claude_row\""* ]] || { echo "claude block missing report: $claude_block"; false; }
  eval "$report_fn"
  GLYPH_OK='✓'; GLYPH_WARN='⚠'; GLYPH_ERR='✗'; GLYPH_INFO='i'; N_WARN=0; N_ERROR=0; N_INFO=0
  stub_claude "echo '2.1.295 (Claude Code)'"
  output="$(eval "$claude_block")"
  [ -z "$output" ] || { echo "healthy claude reported: $output"; false; }
  stub_claude "echo '2.1.294 (Claude Code)'"
  output="$(eval "$claude_block")"
  [[ "$output" == *"2.1.294"* ]] || { echo "$output"; false; }
  [[ "$output" == *"2.1.295"* ]] || { echo "$output"; false; }
  [[ "$output" == *"⚠"* ]] || { echo "$output"; false; }
  rm -f "$SANDBOX/bin/claude"
  output="$(eval "$claude_block")"
  [[ "$output" == *"not found"* ]] || { echo "$output"; false; }
  [[ "$output" == *"  i claude-code version:"* ]] || { echo "$output"; false; }
}

# r152-t13-code F4: a present CLI whose version cannot be read is reported as
# unreadable output, never as a CLI that is not installed.
@test "a present claude without a readable version says so, not 'not found'" {
  local body
  for body in 'exit 1' "echo 'Claude Code'" 'printf ""'; do
    stub_claude "$body"
    run hc_claude_code_version
    [ "$status" -eq "$HC_INFO" ] || { echo "$body: status=$status $output"; return 1; }
    [[ "$output" == *"gave no X.Y.Z"* ]] || { echo "$body: $output"; return 1; }
    [[ "$output" != *"not found"* ]] || { echo "$body: $output"; return 1; }
  done
}

# r152-t13-code F3: a version line followed by a nonzero exit is read, with and
# without pipefail, and the boundary decision follows it.
@test "a version line before a nonzero exit is read with and without pipefail" {
  local options
  stub_claude "echo '2.1.322 (Claude Code)'; exit 1"
  for options in '' 'set -o pipefail'; do
    run bash -c "$options"'
      . "$1/scripts/lib/attachment.sh"
      printf "%s %s\n" "$(attachment_claude_code_version)" "$(attachment_claude_decision)"
    ' _ "$REPO"
    [ "$status" -eq 0 ] || { echo "[$options] status=$status $output"; return 1; }
    [ "$output" = '2.1.322 supported' ] || { echo "[$options] $output"; return 1; }
  done
}

@test "a version source that succeeds without X.Y.Z is unreadable, never supported" {
  local out
  for out in '' 'garbage' '2.1' '2.1.x9'; do
    attachment_claude_code_version() { printf '%s\n' "$STUB_OUT"; }
    STUB_OUT="$out"
    [ "$(attachment_claude_decision)" = unreadable ] || false
    _ATTACHMENT_CLAUDE_DECISION=''
    run attachment_claude_on_failure_supported
    [ "$status" -eq 2 ] || false
  done
  STUB_OUT=2.1.295
  [ "$(attachment_claude_decision)" = supported ] || false
  STUB_OUT=2.1.294
  [ "$(attachment_claude_decision)" = unsupported ] || false
}

# r152-create-3: digits and dots are not a version. Leading zeros, a missing
# or fourth part, an empty part, a prerelease or a prefix are undecided, from
# the real CLI path and from a version-source wrapper alike.
@test "a CLI version line that is not canonical X.Y.Z is unreadable, never supported" {
  local line
  for line in 02.1.295 2.01.295 2.1.0295 2.1..295 2.1.295.4444 2.1.295-rc.1 v2.1.295 '2.1.295x (Claude Code)'; do
    stub_claude "echo '$line'"
    [ "$(attachment_claude_decision)" = unreadable ] || { echo "$line: $(attachment_claude_decision)"; return 1; }
    _ATTACHMENT_CLAUDE_DECISION=''
    run attachment_claude_on_failure_supported
    [ "$status" -eq 2 ] || { echo "$line: on_failure status=$status"; return 1; }
    run hc_claude_code_version
    [ "$status" -eq "$HC_INFO" ] || { echo "$line: doctor status=$status $output"; return 1; }
  done
  for line in 2.1.295 '2.1.295 (Claude Code)' '3.0.0	(tab)'; do
    stub_claude "printf '%s\n' '$line'"
    [ "$(attachment_claude_decision)" = supported ] || { echo "$line: $(attachment_claude_decision)"; return 1; }
  done
}

@test "a version-source wrapper answer that is not canonical X.Y.Z is unreadable, never supported" {
  local out
  attachment_claude_code_version() { printf '%s\n' "$STUB_OUT"; }
  for out in 02.1.295 2.01.295 2.1.0295 2.1..295 2.1.295.4444 .2.1.295 2.1.295. v2.1.295 2.1.295-rc.1 2.1.295+build ' 2.1.295'; do
    STUB_OUT="$out"
    [ "$(attachment_claude_decision)" = unreadable ] || { echo "$out: $(attachment_claude_decision)"; return 1; }
    _ATTACHMENT_CLAUDE_DECISION=''
    run attachment_claude_on_failure_supported
    [ "$status" -eq 2 ] || { echo "$out: on_failure status=$status"; return 1; }
  done
}

@test "a comparison that fails or answers outside -1, 0, 1 is unreadable, never supported" {
  local answer
  attachment_claude_code_version() { printf '2.1.300\n'; }
  semver_compare() { return 1; }
  [ "$(attachment_claude_decision)" = unreadable ] || { echo "failed compare: $(attachment_claude_decision)"; return 1; }
  for answer in '' 2 x; do
    eval "semver_compare() { printf '%s' '$answer'; }"
    [ "$(attachment_claude_decision)" = unreadable ] || { echo "answer [$answer]: $(attachment_claude_decision)"; return 1; }
  done
}
