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
@test "verdict command mutation forces rerun" { check_verdict test_mutation_command; }
@test "verdict each runner and fence blob mutation forces rerun" { check_verdict test_mutation_runner; }
@test "verdict each toolchain version mutation forces rerun" { check_verdict test_mutation_toolchain; }
@test "native Cargo toolchain and cache mutations refuse reused full verdicts" { check_verdict test_native_cargo_inputs_and_test_seams_bind_full_battery_reuse; }
@test "native Rust version identity uses the contained probe" { check_verdict test_native_cargo_version_probe_uses_the_contained_probe_callback; }
@test "verdict platform mutation forces rerun" { check_verdict test_mutation_platform; }
@test "verdict captures real sources and refuses dirty or wrong gated head" { check_verdict test_capture_binds_real_sources_and_rejects_dirty_or_wrong_head; }
@test "verdict bad evidence wrong mode location or failure is never reused" { check_verdict test_bad_evidence_mode_location_and_failure_are_never_reused; }
@test "verdict ignored discovery suites refuse reuse while benign caches do not" { check_verdict test_ignored_discovery_suites_refuse_reuse_but_caches_do_not; }
@test "verdict failed version probes refuse reuse" { check_verdict test_failed_version_probe_refuses_reuse; }
@test "verdict heavy transport is excluded and heavy test seams refuse" { check_verdict test_heavy_only_operational_transport_is_excluded; }
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
@test "native-only diagnostic cannot publish or reuse a full verdict" { check_verdict test_native_only_cannot_reuse_a_full_battery_verdict; }
@test "verdict runner writes only complete verified empty green runs" { check_verdict test_runner_writes_only_complete_verified_empty_green; }
@test "verdict sessions env refs config and fresh clones share one verdict" { check_verdict test_sessions_and_checkouts_share_a_verdict; }
@test "verdict project command pass reused; tree command toolchain dirty fail and disable miss" { check_verdict test_project_command_pass_is_reused_until_tree_command_or_toolchain_changes; }
@test "verdict project .trellis.json gate.verdict_reuse=false always runs" { check_verdict test_project_opt_out_always_runs; }
@test "verdict project record age and evidence are checked" { check_verdict test_project_verdict_age_and_evidence_are_checked; }
@test "verdict env mutation forces rerun" { check_verdict test_mutation_env; }
@test "verdict policy mutation forces rerun" { check_verdict test_mutation_policy; }
@test "verdict external config mutation forces rerun" { check_verdict test_mutation_configs; }
@test "r151 H1 forged command verdict without its execution log is not reused" { check_verdict test_h1_forged_verdict_without_its_execution_log_is_not_reused; }
@test "r151 H1 command verdicts live only in the guarded store with a retained log; kill switch" { check_verdict test_h1_verdicts_live_only_in_the_guarded_store_with_a_retained_log; }
@test "r151 H2 PYTEST_ADDOPTS-filtered run is never published as full" { check_verdict test_h2_pytest_addopts_filtered_run_is_never_published_as_full; }
@test "r151 L4 N7 reuse grammar is an allowlist across runners and forms" { check_verdict test_n7_reuse_grammar_is_an_allowlist; }
@test "r151 M3 ignored discovered test file refuses reuse" { check_verdict test_m3_ignored_discovered_test_file_refuses_reuse; }
@test "r151 M3 ignored file allowances follow the runner" { check_verdict test_m3_ignored_file_allowances_follow_the_runner; }
@test "r151 M4 rustup toolchain switch is keyed on the effective compiler" { check_verdict test_m4_rustup_toolchain_switch_is_keyed_on_the_effective_compiler; }
@test "r151 M4 dispatcher identity is bound or reuse refused" { check_verdict test_m4_dispatcher_identity_or_refusal; }
@test "r151 muse HIGH-1 env_passthrough values are keyed" { check_verdict test_muse_high1_env_passthrough_values_are_keyed; }
@test "r151 muse MEDIUM-1 execution-shaping env refuses or keys" { check_verdict test_muse_medium1_execution_shaping_env_refuses_or_keys; }
@test "r151 muse MEDIUM-1 injected session never publishes" { check_verdict test_muse_medium1_injected_session_never_publishes; }
@test "r151 muse LOW-1 inputs file is never followed or trusted" { check_verdict test_muse_low1_inputs_file_is_never_followed_or_trusted; }
@test "r151 muse LOW-2 a failure during an overlapping pass wins" { check_verdict test_muse_low2_failure_during_an_overlapping_pass_wins; }
@test "r151 N2 dispatcher forwarding and verdict keying share one trusted policy" { check_verdict test_n2_forwarding_and_keying_share_the_remote_default_policy; }
@test "r151 N3 a CARGO_HOME override never publishes; the default home config is bound" { check_verdict test_n3_cargo_home_override_never_publishes; }
@test "r151 N4 package-manager options and config never publish; a user npmrc script-shell refuses" { check_verdict test_n4_package_manager_options_and_config_never_publish; }
@test "r151 N5 ignored coverage tests discovered by real pytest refuse reuse" { check_verdict test_n5_ignored_coverage_tests_are_discovered_by_pytest; }
@test "r151 N5 ignored coverage tests discovered by real node refuse reuse" { check_verdict test_n5_ignored_coverage_tests_are_discovered_by_node; }
@test "r151 N5 an ignored cargo test named by committed config refuses reuse" { check_verdict test_n5_ignored_cargo_test_named_by_committed_config; }
@test "r151 N6 a hard-linked rustup proxy is keyed on the selected compiler" { check_verdict test_n6_hard_linked_rustup_proxy_is_keyed_on_the_selected_compiler; }
@test "r151 N7 a name-filtered real node run is never published as full" { check_verdict test_n7_filtered_node_run_is_never_published_as_full; }
@test "r151 N8 forced-full failures invalidate and block overlapping publication" { check_verdict test_n8_forced_full_failures_invalidate_and_block_overlapping_publication; }
@test "r151 N9 an unhealthy store never reuses and failures survive its repair" { check_verdict test_n9_unhealthy_store_never_reuses_and_failures_survive_repair; }
@test "r151 F1 a user Cargo runner replaces the executor and never publishes" { check_verdict test_f1_user_cargo_runner_replaces_the_executor_and_never_publishes; }
@test "r151 F1 a user npm script-shell replaces the executor and never publishes" { check_verdict test_f1_user_npm_script_shell_replaces_the_executor_and_never_publishes; }
@test "r151 F1 path-valued uv pdm and yarn settings never publish" { check_verdict test_f1_path_valued_settings_never_publish; }
@test "r151 F2 control characters never parse as whitespace" { check_verdict test_f2_control_characters_never_parse_as_whitespace; }
@test "r151 F6 reporter modules outside the tree never publish" { check_verdict test_f6_reporter_modules_outside_the_tree_never_publish; }
@test "r151 F8 node discovers ignored tests in __pycache__" { check_verdict test_f8_node_discovers_ignored_tests_in_pycache; }
@test "r151 F8 an explicit pytest root is traversed whatever its name" { check_verdict test_f8_explicit_pytest_root_is_traversed_whatever_its_name; }
@test "r151 F9 an abandoned failure supersedes passes overlapping it" { check_verdict test_f9_abandoned_failure_supersedes_passes_overlapping_it; }
@test "r151 F10 an untrackable store is moved aside, or the command never runs" { check_verdict test_f10_untrackable_store_moves_aside_or_never_runs; }
@test "r151 reuse4 the range interface never reaches a reuse-tracked command" { check_verdict test_range_interface_never_reaches_a_reuse_tracked_command; }
@test "r151 cargo-fence the native-stage decision is keyed for the full battery" { check_verdict test_native_stage_decision_is_keyed_for_the_full_battery; }
@test "r151 cargo-fence rustup detection probes use the caller's probe" { check_verdict test_rustup_detection_probes_use_the_callers_probe; }
@test "r151-reuse4 R4 native stages bind the pinned 1.97.1 toolchain, not the active default" { check_verdict test_native_stages_bind_the_pinned_toolchain_not_the_active_default; }
@test "native rustc probe timeout costs reuse only" { check_verdict test_native_cargo_probe_timeout_costs_reuse_only; }
@test "r151-reuse4 R5 native identity never falls back past an unavailable candidate" { check_verdict test_native_identity_never_falls_back_past_an_unavailable_candidate; }
@test "r151-reuse4 R1 a committed or ancestor executor setting never publishes" { check_verdict test_r1_committed_or_ancestor_executor_config_never_publishes; }
@test "r151-reuse4 R2 reporters in committed runner config meet the reporter contract" { check_verdict test_r2_reporters_in_committed_runner_config_meet_the_reporter_contract; }
@test "r151-reuse4 R6 a string jest projects entry refuses reuse" { check_verdict test_r6_string_jest_projects_refuse_reuse; }
@test "r151-reuse4 R7 a tracked symlink leaving the tree refuses reuse" { check_verdict test_r7_tracked_symlinks_leaving_the_tree_refuse_reuse; }
@test "r151-reuse4 R3 a rustup detection timeout costs reuse, not the compiler identity" { check_verdict test_rustup_detection_timeout_costs_reuse_not_identity; }
@test "reuse4 a slow version probe costs reuse, and a failure during it still supersedes" { check_verdict test_slow_version_probe_costs_reuse_and_a_failure_still_supersedes; }
@test "reuse4 a slow version probe only costs reuse for the local runner" { check_verdict test_slow_version_probe_only_costs_reuse_for_the_local_runner; }
@test "reuse4 parallelism-only variables do not refuse reuse; other Cargo overrides still do" { check_verdict test_parallelism_only_variables_do_not_refuse_reuse; }
@test "reuse4 ambient exports cannot break the fixture" { check_verdict test_ambient_exports_cannot_break_the_fixture; }
