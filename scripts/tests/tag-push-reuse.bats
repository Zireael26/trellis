#!/usr/bin/env bats

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tag-push-reuse.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  export PI_CODING_AGENT_DIR="$SANDBOX/pi" TRELLIS_GATE_STATE_DIR="$SANDBOX/state"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR" "$PI_CODING_AGENT_DIR"
}
teardown() { rm -rf "$SANDBOX"; }

check_tag() {
  run python3 -I "$BATS_TEST_DIRNAME/test_tag_push_reuse.py" "TagReuseTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "tag reuse exact-tree hit runs traced tag-reading suites" { check_tag test_exact_tree_hit_reuses_runner_verdict_and_runs_tag_suite; }
@test "tag reuse one-byte tree change runs full" { check_tag test_one_byte_tree_change_runs_full; }
@test "tag reuse rejects forged edited and failed aggregate verdicts" { check_tag test_forged_or_edited_verdict_runs_full; }
@test "tag reuse missing incomplete or stale T32 trace runs full" { check_tag test_missing_incomplete_or_stale_t32_trace_runs_full; }
@test "tag reuse a failing tag-reading suite still blocks" { check_tag test_tag_reading_suite_failure_blocks_instead_of_reusing_to_green; }
@test "tag reuse failed verify-tag runs full" { check_tag test_verify_tag_failure_runs_full; }
@test "tag reuse changed refs stale or ambiguous verdicts run full" { check_tag test_ref_changes_stale_or_ambiguous_verdicts_run_full; }
@test "tag reuse unverified pushes cannot use ordinary T30 receipts" { check_tag test_tag_push_without_verified_identity_cannot_use_ordinary_t30_reuse; }
@test "tag reuse overrides a branch selector scope and never narrows" { check_tag test_tag_identity_beats_branch_selector_scope_and_never_narrows; }
@test "tag reuse both hooks forward verified identity and render the receipt" { check_tag test_both_hooks_forward_only_verified_single_tag_and_render_receipt; }
