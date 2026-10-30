#!/usr/bin/env bats

@test "trellis usage selects supported Python when python3 on PATH is 3.9" {
  local root
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  [ -x /opt/homebrew/bin/python3.14 ] || skip "Python 3.14 unavailable"
  [ -x /usr/bin/python3 ] || skip "system python3 unavailable"
  run env PATH=/usr/bin:/bin:/opt/homebrew/bin "$root/scripts/trellis" usage --help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"usage-federation"* ]] || { echo "$output"; return 1; }
}
