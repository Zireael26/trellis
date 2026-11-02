#!/usr/bin/env bats

@test "diff-aware push test mapping and gate integration" {
  run python3 -I "$BATS_TEST_DIRNAME/test_push_test_map.py"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
