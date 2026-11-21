#!/usr/bin/env bats
# The recommended pi setup supports pi 1.5.2 and above. Doctor warns below it,
# stays silent at or above it, warns when pi is missing but a registered
# checkout selects the pi harness, and reports INFO when pi is neither
# installed nor selected, or its version cannot be read. A stub CLI only:
# never runs pi.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/pi-version.XXXXXX")"
  mkdir -p "$SANDBOX/bin"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
  # The stub directory plus system tools only, so a real pi is never found.
  PATH="$SANDBOX/bin:/usr/bin:/bin"
  REG="$SANDBOX/registry.json"
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

stub_pi() {
  printf '#!/bin/sh\n%s\n' "$1" > "$SANDBOX/bin/pi"
  chmod 755 "$SANDBOX/bin/pi"
}

registry_with() {
  printf '{"version":1,"projects":{"f/p":{"fleet":"f","project_id":"p","status":"active","metadata":{},"checkouts":{"c":{"root":"/x","git_common_dir":"/x/.git","harnesses":%s,"worktrees":{}}}}}}\n' "$1" > "$REG"
}

@test "below 1.5.2 -> WARN naming the installed version and the floor" {
  local version
  registry_with '["claude","pi"]'
  for version in 1.5.1 1.5.0 1.1.0 1.0.9 0.99.2 0.87.1; do
    stub_pi "echo '$version'"
    run hc_pi_version "$REG"
    [ "$status" -eq "$HC_WARN" ] || { echo "$version: status=$status $output"; return 1; }
    [[ "$output" == *"$version"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"1.5.2"* ]] || { echo "$output"; return 1; }
  done
}

@test "below 1.5.2 warns even when no checkout selects pi" {
  stub_pi "echo 1.1.0"
  run hc_pi_version "$SANDBOX/no-registry.json"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"1.1.0"* ]] || false
}

@test "at or above 1.5.2 -> silent OK" {
  local version
  registry_with '["pi"]'
  for version in 1.5.2 1.5.3 1.6.0 1.10.0 2.0.0; do
    stub_pi "echo '$version'"
    run hc_pi_version "$REG"
    [ "$status" -eq "$HC_OK" ] || { echo "$version: status=$status $output"; return 1; }
    [ -z "$output" ] || { echo "$version: $output"; return 1; }
  done
}

@test "a version pi cannot report -> INFO, never OK or WARN" {
  local body
  registry_with '["pi"]'
  for body in 'exit 1' "echo 'pi'" 'echo 1.1' 'printf ""'; do
    stub_pi "$body"
    run hc_pi_version "$REG"
    [ "$status" -eq "$HC_INFO" ] || { echo "$body: status=$status $output"; return 1; }
    [[ "$output" == *"unreadable"* ]] || { echo "$body: $output"; return 1; }
  done
}

@test "pi --version runs with stdin closed" {
  # Prints a passing version only when stdin is at EOF; an inherited stdin
  # would make it print a failing one.
  stub_pi 'if read -r _; then echo 0.1.0; else echo 1.5.2; fi'
  registry_with '["pi"]'
  printf 'not-eof\n' | {
    run hc_pi_version "$REG"
    [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; return 1; }
  }
}

@test "a pi --version that hangs is cut off by the timeout -> INFO" {
  stub_pi 'exec sleep 20'
  registry_with '["pi"]'
  HC_PI_VERSION_TIMEOUT_SECONDS=1
  local start=$SECONDS
  run hc_pi_version "$REG"
  [ "$status" -eq "$HC_INFO" ] || { echo "status=$status $output"; return 1; }
  [[ "$output" == *"unreadable"* ]] || false
  [ $((SECONDS - start)) -lt 10 ]
}

@test "pi absent while a registered checkout selects pi -> WARN" {
  registry_with '["claude","pi"]'
  run hc_pi_version "$REG"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *"not found"* ]] || false
  [[ "$output" == *"1.5.2"* ]] || false
}

@test "pi absent and not selected by any checkout -> INFO" {
  registry_with '["claude","codex"]'
  run hc_pi_version "$REG"
  [ "$status" -eq "$HC_INFO" ]
  [[ "$output" == *"not found"* ]] || false
  run hc_pi_version "$SANDBOX/no-registry.json"
  [ "$status" -eq "$HC_INFO" ]
  [[ "$output" == *"not found"* ]] || false
}

@test "portable doctor reports the row only when it is not healthy" {
  # Run the doctor's own report() and pi block (extracted verbatim) against
  # the real hc_pi_version, so a neutered else branch fails behaviorally.
  local report_fn pi_block
  report_fn="$(awk '/^report\(\) \{/,/^}/' "$REPO/scripts/doctor.sh")"
  [ -n "$report_fn" ] || { echo 'report function not found in doctor.sh'; false; }
  pi_block="$(awk '/if pi_row=/,/^fi$/' "$REPO/scripts/doctor.sh")"
  [[ "$pi_block" == *"report '  ' \"\$?\" \"\$pi_row\""* ]] || { echo "pi block missing report: $pi_block"; false; }
  eval "$report_fn"
  GLYPH_OK='✓'; GLYPH_WARN='⚠'; GLYPH_ERR='✗'; GLYPH_INFO='i'; N_WARN=0; N_ERROR=0; N_INFO=0
  REGISTRY_PATH="$REG"
  stub_pi "echo '1.5.2'"
  registry_with '["pi"]'
  output="$(eval "$pi_block")"
  [ -z "$output" ] || { echo "healthy pi reported: $output"; false; }
  rm -f "$SANDBOX/bin/pi"
  registry_with '["claude","pi"]'
  output="$(eval "$pi_block")"
  [[ "$output" == *"not found"* ]] || { echo "$output"; false; }
  [[ "$output" == *"1.5.2"* ]] || { echo "$output"; false; }
  [[ "$output" == *"⚠"* ]] || { echo "$output"; false; }
  registry_with '["claude","codex"]'
  output="$(eval "$pi_block")"
  [[ "$output" == *"not found"* ]] || { echo "$output"; false; }
  [[ "$output" == *"  i pi version:"* ]] || { echo "$output"; false; }
}
