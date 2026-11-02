#!/usr/bin/env bats
# T32 fixtures only: no real strace, battery, operator HOME or Trellis state.
setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/full-trace.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}
teardown() { rm -rf "$SANDBOX"; }

check_trace() {
  run python3 -I "$BATS_TEST_DIRNAME/test_full_trace.py" "TraceTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "trace promotion refuses a missing inventory suite log" { check_trace test_missing_suite_log_refuses_promotion; }
@test "trace promotion refuses source digest drift" { check_trace test_digest_drift_refuses_promotion; }
@test "trace promotion refuses unparseable empty and incomplete logs" { check_trace test_unparseable_log_refuses_promotion; }
@test "trace complete fixture requires an explicit promotion step" { check_trace test_complete_fixture_requires_explicit_promotion; }
@test "trace promotion refuses nonzero strace exits and tampered logs" { check_trace test_nonzero_exit_and_tampered_log_refuse_promotion; }
@test "trace classifies file probes and opaque Git object reads conservatively" { check_trace test_file_and_git_object_reads_are_conservative; }
@test "trace resolves symlink targets from yy fd paths (Argon P1)" { check_trace test_symlink_targets_use_resolved_fd_paths; }
@test "trace resolves dirfd-relative ADR probes (Argon P2)" { check_trace test_dirfd_relative_adr_probes_are_classified; }
@test "trace resolves AT_EMPTY_PATH fd targets (Argon P3)" { check_trace test_empty_path_uses_fd_target; }
@test "trace resolves relative tag operands (Argon P4)" { check_trace test_relative_tag_operand_is_classified; }
@test "trace resolves dirfd-relative tag operands (Argon P5)" { check_trace test_dirfd_relative_tag_operand_is_classified; }
@test "trace joins split resumed paths and preserves flags (Argon P6)" { check_trace test_split_resumed_paths_preserve_flags_and_targets; }
@test "trace O_PATH probes depend on metadata" { check_trace test_o_path_is_a_metadata_dependency; }
@test "trace keeps killed unfinished syscall path evidence" { check_trace test_killed_unfinished_call_retains_path_evidence; }
@test "trace unresolved operands conservatively select both classes" { check_trace test_unresolved_operands_select_both_classes; }
@test "trace launchers pin delegates and survive scrubbed environments" { check_trace test_trace_launchers_survive_scrubbed_environment; }
@test "trace launchers override forged pins and refuse escape" { check_trace test_trace_launchers_override_forged_pins; }
@test "trace scrubs inherited PI and XDG paths" { check_trace test_trace_scrubs_pi_and_xdg_environment; }
@test "trace driver bounds workers and sandboxes every CI inventory suite" { check_trace test_driver_bounds_workers_and_sandboxes_every_inventory_suite; }
