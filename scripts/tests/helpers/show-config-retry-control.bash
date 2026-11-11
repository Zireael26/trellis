#!/usr/bin/env bash
# Exercise the actual bounded retry loop with test-only attempt results.
set -u
repo=$1
base=$(mktemp -d "$TMPDIR/t12-retry-control.XXXXXX") || exit 1
loop=$(python3 -I - "$repo/scripts/show-config.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('_SHOW_RETRY_ROOT="$(mktemp -d ')
print(source[start:])
PY
) || exit 1
run_case() {
  local mode=$1 expected_status=$2 expected_attempts=$3 expected_text=$4 output rc=0
  : > "$base/attempts"
  output=$(env T12_RETRY_CONTROL_MODE="$mode" T12_RETRY_CONTROL_LOG="$base/attempts" \
    /bin/bash -c '
      TRELLIS_EX_STATE=4 TRELLIS_EX_UNAVAILABLE=5
      show_config_attempt() {
        printf "attempt\n" >> "$T12_RETRY_CONTROL_LOG"
        count=$(wc -l < "$T12_RETRY_CONTROL_LOG" | tr -d " ")
        case "$T12_RETRY_CONTROL_MODE:$count" in
          once:1|continuous:*) echo BAD-UNPUBLISHED-SENTINEL; return 75 ;;
          file:*) echo BAD-UNPUBLISHED-SENTINEL; return 76 ;;
          clean:*) echo clean; return 3 ;;
          *) echo clean; return 0 ;;
        esac
      }
      eval "$1"
    ' retry-control "$loop" 2>&1) || rc=$?
  printf '%s status=%s attempts=%s output=%s\n' "$mode" "$rc" \
    "$(wc -l < "$base/attempts" | tr -d ' ')" "$output"
  [ "$rc" -eq "$expected_status" ] &&
    [ "$(wc -l < "$base/attempts" | tr -d ' ')" -eq "$expected_attempts" ] &&
    [[ "$output" == *"$expected_text"* ]] && [[ "$output" != *BAD-UNPUBLISHED-SENTINEL* ]]
}
run_case once 0 2 clean || exit 11
run_case continuous 4 3 'state directory kept changing' || exit 12
run_case file 4 1 'guarded input changed' || exit 13
run_case clean 3 1 clean || exit 14
