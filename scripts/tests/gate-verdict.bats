#!/usr/bin/env bats

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gate-verdict.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}
teardown() { rm -rf "$SANDBOX"; }

check_verdict() {
  run python3 -I "$BATS_TEST_DIRNAME/test_gate_verdict.py" "VerdictTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "verdict schema mutation forces rerun" { check_verdict test_mutation_schema; }
@test "verdict tree mutation forces rerun" { check_verdict test_mutation_tree; }
@test "verdict inventory mutation forces rerun" { check_verdict test_mutation_inventory; }
@test "verdict suite version mutation forces rerun" { check_verdict test_mutation_suite_versions; }
@test "verdict each runner and fence blob mutation forces rerun" { check_verdict test_mutation_runner; }
@test "verdict each toolchain version mutation forces rerun" { check_verdict test_mutation_toolchain; }
@test "verdict environment mutation forces rerun" { check_verdict test_mutation_environment; }
@test "verdict refs mutation forces rerun" { check_verdict test_mutation_refs; }
@test "verdict git config mutation forces rerun" { check_verdict test_mutation_git_config; }
@test "verdict platform mutation forces rerun" { check_verdict test_mutation_platform; }
@test "verdict captures real sources and refuses dirty or wrong gated head" { check_verdict test_capture_binds_real_sources_and_rejects_dirty_or_wrong_head; }
@test "verdict bad evidence wrong mode location or failure is never reused" { check_verdict test_bad_evidence_mode_location_and_failure_are_never_reused; }
@test "verdict ignored discovery suites refuse reuse while benign caches do not" { check_verdict test_ignored_discovery_suites_refuse_reuse_but_caches_do_not; }
@test "verdict failed version probes refuse reuse" { check_verdict test_failed_version_probe_refuses_reuse; }
@test "verdict heavy exclusion is limited to operational transport" { check_verdict test_heavy_only_operational_transport_is_excluded; }
@test "verdict additional tool identities bind executable changes" { check_verdict test_additional_tool_identities_bind_binary_changes; }
@test "verdict npm package upgrades are bound without executing npm" { check_verdict test_npm_package_upgrade_is_bound_without_invoking_npm; }
@test "verdict age is capped at seven days" { check_verdict test_verdict_age_is_capped_at_seven_days; }
@test "verdict disabled green run publishes no reusable record" { check_verdict test_disabled_green_run_publishes_no_verdict; }
@test "verdict mid-run input change prevents publication after green shards" { check_verdict test_midrun_input_change_prevents_publication; }
@test "verdict failed close deletes a record published before finalization" { check_verdict test_failed_close_deletes_a_published_verdict; }
@test "verdict narrowed and test seam runs never qualify" { check_verdict test_narrowed_and_test_seam_inputs_never_qualify; }
@test "verdict active or quarantined runs cannot reuse an older pass" { check_verdict test_active_or_quarantined_run_never_reuses_an_older_pass; }
@test "verdict weekly snapshot ignores only occupancy, not disable or bad evidence" { check_verdict test_weekly_snapshot_ignores_occupancy_not_disable_or_bad_evidence; }
@test "verdict administrative reap does not invalidate a pass" { check_verdict test_reap_does_not_invalidate_a_pass; }
@test "verdict Tests row reuse still runs static and coverage checks and misses rerun" { check_verdict test_tests_row_reuses_but_static_and_coverage_still_execute; }
@test "verdict selected runs cannot seal full and gate interfaces are parent-only" { check_verdict test_selected_runs_never_publish_full_and_gate_interface_is_parent_only; }
@test "verdict runner writes only complete verified empty green runs" { check_verdict test_runner_writes_only_complete_verified_empty_green; }
