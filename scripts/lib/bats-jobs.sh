# shellcheck shell=bash
# Run one Bats file with two in-file jobs; after the bats-core wait race, rerun
# it serially once and let that run decide.
#
# bats-core 1.14 under bash 5.3 can exit 1 when bats-exec-file's `wait <pid>`
# prints "pid N is not a child of this shell": a later child of the same shell
# reused the saved pid, and bash discarded the finished test's saved status
# (bash jobs.c: "new process, discard any saved status"). That is one shown way
# the message arises, not proof that nothing else failed, so the parallel run's
# output is never accepted. The file runs again with --jobs 1, which does not
# take the parallel wait path, and its exit is the result. A deterministic
# failure fails again; only a failure that does not recur serially is lost.
# The `bats-jobs: rerun` line marks every such run.

bats_jobs_file() {
  local file="$1" log ec tee_ec
  local -a st
  log="$(mktemp "${TMPDIR:-/tmp}/bats-jobs.XXXXXX")" || return 2
  bats --jobs 2 --no-parallelize-across-files "$file" 2>&1 | tee "$log"
  st=("${PIPESTATUS[@]}")
  ec="${st[0]}" tee_ec="${st[1]}"
  if [ "$ec" -eq 1 ] && [ "$tee_ec" -eq 0 ] && bats_jobs_wait_race_seen "$log"; then
    printf 'bats-jobs: bats-core wait race in %s: rerun with --jobs 1 decides\n' "$file"
    bats --jobs 1 "$file"
    ec=$?
  fi
  rm -f "$log"
  [ "$ec" -ne 0 ] && return "$ec"
  return "$tee_ec"
}

# The message must stand alone on its line, as bash prints it.
bats_jobs_wait_race_seen() {
  grep -Eq '^[^ ]*bats-exec-file: line [0-9]+: wait: pid [0-9]+ is not a child of this shell$' "$1"
}
