#!/usr/bin/env bats

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/stage-weights.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}
teardown() { rm -rf "$SANDBOX"; }

check_weights() {
  run python3 -I "$BATS_TEST_DIRNAME/test_stage_weights.py" "WeightTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "weights use the median of the last five passing runs and label estimates" { check_weights test_median_of_last_five_and_unmeasured_estimate; }
@test "weights ignore tampered nonprivate red and incomplete retained receipts" { check_weights test_tampered_and_nonprivate_runs_are_not_samples; }
@test "weights refuse corrupt red partial or nonfinite baseline receipts" { check_weights test_baseline_must_be_complete_green_with_finite_timings; }
