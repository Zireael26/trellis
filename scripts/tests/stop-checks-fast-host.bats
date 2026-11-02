#!/usr/bin/env bats
# The host-only Stop setting projects.<root>.stop_checks.fast (spec 072): the
# machine-config validators accept the projects key, and the doctor row says
# when a project has a fast suite and when the hook would ignore it. The Stop
# behaviour itself is tested in core-rules/hooks/tests/stop-verify-reuse.bats.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/fast-host.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/source" "$SANDBOX/projects"
  chmod 700 "$TRELLIS_HOME"
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

# write_config <projects json> [mode]
write_config() {
  jq -n --arg source "$SANDBOX/source" --arg projects "$SANDBOX/projects" --argjson p "$1" '
    {
      schema_version: 1,
      source_root: $source,
      release_remote: "fixture://release",
      active_cli_release: "1.2.3",
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$projects]}},
      projects: $p
    }' > "$TRELLIS_HOME/config.json"
  chmod "${2:-600}" "$TRELLIS_HOME/config.json"
}

fast_row() {
  run bash -c '. "$1/scripts/lib/health-checks.sh"; hc_stop_checks_fast "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME"
}

@test "the three closed-object validators accept projects, even values only the Stop hook would refuse" {
  local value
  for value in '{"/p/a":{"stop_checks":{"fast":"make t"}}}' '{"/p/a":{"stop_checks":{"fast":3}}}' '[]'; do
    write_config "$value"
    run bash -c '. "$1/scripts/lib/trellis-home.sh"; trellis_home_validate_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/config.json"
    [ "$status" -eq 0 ] || { echo "trellis-home $value: $output"; false; }
    # The awk program is an argument: bash 3.2 mangles its escapes inside "$( )".
    run bash -c 'eval "$(awk "$3" "$1/scripts/trellis-launcher.sh")"
      launcher_validate_machine_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/config.json" \
      '/^launcher_validate_machine_config\(\) \{/,/^\}/'
    [ "$status" -eq 0 ] || { echo "launcher $value: $output"; false; }
    run bash -c 'for l in semver trellis-home local-registry attachment health-checks; do . "$1/scripts/lib/$l.sh"; done
      hc_portable_machine_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME"
    [ "$status" -eq 0 ] || { echo "health-checks $value: $output"; false; }
  done
}

@test "doctor row: silent when no project sets a fast suite" {
  fast_row
  [ "$status" -eq 0 ] && [ -z "$output" ]
  write_config '{"/p/a":{"stop_checks":{}},"/p/b":{}}'
  fast_row
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$status $output"; false; }
}

@test "doctor row: INFO names each project with a fast suite" {
  write_config '{"/p/a":{"stop_checks":{"fast":"make t"}},"/p/b":{},"/p/c":{"stop_checks":{"fast":"x"}}}'
  fast_row
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/health-checks.sh"
  [ "$status" -eq "$HC_INFO" ] || { echo "$status $output"; false; }
  [[ "$output" == "stop_checks.fast: "*"for /p/a, /p/c "* ]] || { echo "$output"; false; }
}

@test "doctor row: WARN when the hook would ignore the value" {
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/health-checks.sh"
  local how
  for how in mode:644 mode:700 dir:770 dir:702; do
    chmod 700 "$TRELLIS_HOME"
    write_config '{"/p/a":{"stop_checks":{"fast":"make t"}}}'
    case "$how" in
      mode:*) chmod "${how#mode:}" "$TRELLIS_HOME/config.json" ;;
      dir:*) chmod "${how#dir:}" "$TRELLIS_HOME" ;;
    esac
    fast_row
    [ "$status" -eq "$HC_WARN" ] || { echo "$how: $status $output"; false; }
    [[ "$output" == *"set for /p/a but ignored"* ]] || { echo "$how: $output"; false; }
  done
}

@test "doctor runs the row among the machine-level rows" {
  grep -q 'if fast_row="$(hc_stop_checks_fast "$HOME_PATH")"; then :; else' "$REPO_ROOT/scripts/doctor.sh"
}
