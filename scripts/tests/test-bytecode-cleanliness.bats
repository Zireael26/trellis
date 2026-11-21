#!/usr/bin/env bats
# Exercise the runner's real final stage loop and verdict, without a battery.
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CHECKOUT"
  HARNESS="$BATS_TEST_TMPDIR/runner-tail.sh"
  cat > "$HARNESS" <<'SH'
set -uo pipefail
ROOT="$1"
STAGE_ORDINAL=1
LIST=0
PLAN=0
QUICK=1
NATIVE_CARGO_ONLY=0
FAILED="${FIXTURE_FAILED_COUNT:-0}"
FAILED_STAGES=()
TRELLIS_TEST_TSV=fixture
SCOPE=local
SHARD_INDEX=1
SHARD_TOTAL=1
RAN=1
SKIPPED=0
run_registered_stage() {
  [ "${LEAVE_CACHE:-0}" != 1 ] || mkdir -p "$ROOT/untracked package/lib/__pycache__"
  [ "${FAIL_STAGE:-0}" != 1 ] || { FAILED=1; FAILED_STAGES+=(fixture); }
  return 0
}
SH
  # Keep the last stage loop and everything after it: this is the actual
  # production exit path, not a reimplementation of its cache guard.
  awk '/^for \(\(STAGE_INDEX = 1;/ { body = ""; found = 1 }
       found { body = body $0 "\n" }
       END { if (!found) exit 1; printf "%s", body }' \
    "$REPO_ROOT/scripts/run-tests.sh" >> "$HARNESS"
}

@test "runner fails when a successful test leaves an untracked Python cache" {
  run env LEAVE_CACHE=1 bash "$HARNESS" "$CHECKOUT"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *'Python bytecode left in repository'* ]] || return 1
  [[ "$output" == *'untracked package/lib/__pycache__'* ]] || return 1
  [ -d "$CHECKOUT/untracked package/lib/__pycache__" ] || return 1
  [[ "$output" != *'all stages passed'* ]] || return 1
}

@test "runner accepts a clean tree and preserves an earlier stage failure" {
  run bash "$HARNESS" "$CHECKOUT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'all stages passed'* ]] || return 1
  run env FAIL_STAGE=1 bash "$HARNESS" "$CHECKOUT"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *'fixture'* ]] || return 1
}

@test "cache refusal cannot wrap a 255-stage failure count into exit zero" {
  run env FIXTURE_FAILED_COUNT=255 LEAVE_CACHE=1 bash "$HARNESS" "$CHECKOUT"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *'Python bytecode left in repository'* ]] || return 1
}

@test "runner fails closed when the repository cache scan fails" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/find"
  chmod +x "$BATS_TEST_TMPDIR/bin/find"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$HARNESS" "$CHECKOUT"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *'unable to check repository for Python bytecode'* ]] || return 1
  [[ "$output" != *'all stages passed'* ]] || return 1
}

@test "runner does not hide pre-existing caches or skip the guard after a failure" {
  mkdir -p "$CHECKOUT/existing/__pycache__"
  run env FAIL_STAGE=1 bash "$HARNESS" "$CHECKOUT"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *'Python bytecode left in repository'* ]] || return 1
  [[ "$output" == *'existing/__pycache__'* ]] || return 1
  [[ "$output" == *'fixture'* ]] || return 1
}
