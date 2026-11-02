#!/usr/bin/env bats

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/weekly-battery.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}
teardown() { rm -rf "$SANDBOX"; }

check_weekly() {
  run python3 -I "$BATS_TEST_DIRNAME/test_weekly_battery.py" "WeeklyTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

check_weekly_integration() {
  run python3 -I "$BATS_TEST_DIRNAME/test_weekly_battery.py" "WeeklyIntegrationTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "weekly battery always invokes the uncached full runner and scrubs overrides" { check_weekly test_full_uncached_command_scrubs_selection_and_runner_overrides; }
@test "weekly scheduler environment drift still raises P1 from real tree verdicts" { check_weekly_integration test_scheduler_environment_drift_still_disables_tree_reuse; }
@test "weekly occupied holder still snapshots green verdicts and raises P1 (P7)" { check_weekly_integration test_occupied_holder_snapshot_still_raises_p1; }
@test "weekly dead run record still snapshots green verdicts and raises P1 (P8)" { check_weekly_integration test_dead_record_snapshot_still_raises_p1; }
@test "weekly cron and agents share P1 disable state despite differing XDG roots" { check_weekly_integration test_agent_and_cron_xdg_share_p1_disable_marker; }
@test "weekly exact-input divergence raises P1 and disables reuse privately" { check_weekly test_failure_against_exact_green_disables_reuse_and_records_p1; }
@test "weekly changed inputs or absent green fail without a false divergence" { check_weekly test_changed_inputs_or_absent_green_are_failures_not_false_divergence; }
@test "weekly unsafe state is refused before launching the battery" { check_weekly test_unsafe_state_directory_is_refused_before_battery; }
