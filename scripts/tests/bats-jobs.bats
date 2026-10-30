#!/usr/bin/env bats
# bats_jobs_file reruns a file serially after the bats-core wait race and lets
# that rerun decide; it never accepts the parallel run's output
# (scripts/lib/bats-jobs.sh).

RACE='/opt/homebrew/Cellar/bats-core/1.14.0/libexec/bats-core/bats-exec-file: line 195: wait: pid 94163 is not a child of this shell'

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  STUB="$(mktemp -d "${BATS_TEST_TMPDIR}/stub.XXXXXX")"
  # The stub stands in for bats. It logs its arguments to $STUB/calls. Called
  # with --jobs 2 it prints $STUB/tap, then $STUB/stderr to stderr, and exits
  # with $STUB/exit; called with --jobs 1 it prints $STUB/tap1 and exits with
  # $STUB/exit1.
  cat >"$STUB/bats" <<'SH'
#!/usr/bin/env bash
dir="$(dirname "$0")"
printf '%s\n' "$*" >>"$dir/calls"
if [ "$2" = 1 ]; then
  cat "$dir/tap1"
  exit "$(cat "$dir/exit1")"
fi
cat "$dir/tap"
[ -f "$dir/stderr" ] && cat "$dir/stderr" >&2
exit "$(cat "$dir/exit")"
SH
  chmod +x "$STUB/bats"
}

run_jobs() {
  run env PATH="$STUB:$PATH" TMPDIR="$BATS_TEST_TMPDIR" bash -c \
    '. "$1/scripts/lib/bats-jobs.sh"; bats_jobs_file scripts/tests/x.bats' _ "$ROOT"
}

race_run() {
  printf '1..2\nok 1 a\nok 2 b\n' >"$STUB/tap"
  printf '%s\n' "$RACE" >"$STUB/stderr"
  echo 1 >"$STUB/exit"
}

@test "the wait race reruns the file serially and a clean rerun passes" {
  race_run
  printf '1..2\nok 1 a\nok 2 b\n' >"$STUB/tap1"
  echo 0 >"$STUB/exit1"
  run_jobs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"bats-jobs: bats-core wait race in scripts/tests/x.bats: rerun with --jobs 1 decides"* ]]
  run cat "$STUB/calls"
  [ "${lines[0]}" = "--jobs 2 --no-parallelize-across-files scripts/tests/x.bats" ]
  [ "${lines[1]}" = "--jobs 1 scripts/tests/x.bats" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "a teardown_file failure hidden behind all-ok TAP fails on the rerun" {
  # The reviewers' counterexample: every numbered test ok, the file-level
  # failure prefixed by raw fd 3 output, and the race message present.
  printf '1..2\nok 1 a\nok 2 b\ncleanup progress: not ok 3 teardown_file failed\n' >"$STUB/tap"
  printf '%s\n' "$RACE" >"$STUB/stderr"
  echo 1 >"$STUB/exit"
  printf '1..2\nok 1 a\nok 2 b\ncleanup progress: not ok 3 teardown_file failed\n' >"$STUB/tap1"
  echo 1 >"$STUB/exit1"
  run_jobs
  [ "$status" -eq 1 ]
}

@test "the rerun's exit is returned as it is" {
  race_run
  printf '1..2\nok 1 a\n' >"$STUB/tap1"
  echo 3 >"$STUB/exit1"
  run_jobs
  [ "$status" -eq 3 ]
}

@test "an exit 1 without the race message is not rerun" {
  printf '1..2\nok 1 a\nok 2 b\n' >"$STUB/tap"
  echo 'bats-exec-file: line 172: something else failed' >"$STUB/stderr"
  echo 1 >"$STUB/exit"
  run_jobs
  [ "$status" -eq 1 ]
  run cat "$STUB/calls"
  [ "${#lines[@]}" -eq 1 ]
}

@test "a race message quoted inside other output is not rerun" {
  printf '1..1\nnot ok 1 a\n' >"$STUB/tap"
  printf '# saw: %s\n' "$RACE" >"$STUB/stderr"
  echo 1 >"$STUB/exit"
  run_jobs
  [ "$status" -eq 1 ]
  run cat "$STUB/calls"
  [ "${#lines[@]}" -eq 1 ]
}

@test "an exit other than 1 is never rerun" {
  race_run
  echo 130 >"$STUB/exit"
  run_jobs
  [ "$status" -eq 130 ]
  run cat "$STUB/calls"
  [ "${#lines[@]}" -eq 1 ]
}

@test "a failed tee fails the run even when bats passes" {
  printf '1..1\nok 1 a\n' >"$STUB/tap"
  echo 0 >"$STUB/exit"
  cat >"$STUB/tee" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
  chmod +x "$STUB/tee"
  run_jobs
  [ "$status" -eq 1 ]
}

@test "a clean run passes through without a rerun" {
  printf '1..1\nok 1 a\n' >"$STUB/tap"
  echo 0 >"$STUB/exit"
  run_jobs
  [ "$status" -eq 0 ]
  [[ "$output" != *"bats-jobs:"* ]]
  run cat "$STUB/calls"
  [ "${#lines[@]}" -eq 1 ]
}

@test "the heavy suites in run-tests.sh go through bats_jobs_file" {
  run grep -Ec '^[[:space:]]+stage "bats scripts/tests/\$suite\.bats" bats_jobs_file "scripts/tests/\$suite\.bats"$' "$ROOT/scripts/run-tests.sh"
  [ "$output" = 1 ]
  run grep -Ec '^[^#]*bats --jobs 2' "$ROOT/scripts/run-tests.sh"
  [ "$output" = 0 ]
}
