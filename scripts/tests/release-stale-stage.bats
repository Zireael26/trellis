#!/usr/bin/env bats
# A TERM may leave an incomplete private release stage. The next successful
# adoption may reap an old stage only while the actual checkout lock is held.

setup() {
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  WORK="$(CDPATH='' cd "$BATS_TEST_TMPDIR" && pwd -P)"
  DRIVER="$ROOT/scripts/tests/helpers/release-stale-stage-driver.sh"
  CASE_BASH="${TRELLIS_TRAP_CASE_BASH:-/bin/bash}"
}

exercise() {
  local kind="$1" lock_mode="$2" dir="$WORK/stage $1 $2"
  mkdir "$dir"
  run "$CASE_BASH" --noprofile --norc "$DRIVER" "$kind" "$lock_mode" "$ROOT" "$dir"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "TERM then successful locked retry reaps only old own owner stages" { exercise owner locked; }
@test "TERM then successful locked retry reaps only old own render stages" { exercise render locked; }
@test "TERM then locked retry reaps only the exact shared exclude stage" {
  exercise shared locked
  exercise shared bad-shared
}
@test "TERM then successful locked retry reaps only old own hook stages" { exercise hooks locked; }
@test "unlocked retries leave all three stale stages" {
  exercise owner no-lock
  exercise render no-lock
  exercise hooks no-lock
}
@test "replaced lock link cannot authorize stage removal" { exercise owner forged-lock; }
@test "foreign PID or mismatched birth record cannot authorize stage removal" {
  exercise owner foreign-holder
  exercise owner forged-birth
}
@test "23 h stage survives and 25 h stage is reaped under lock" { exercise owner locked; }
@test "reused PID with mismatched live birth cannot authorize removal" { exercise owner reused-birth; }
@test "a plan bound to a different checkout cannot authorize removal" { exercise owner wrong-checkout; }
@test "a missing or wrong render root cannot authorize removal" {
  exercise render missing-root
  exercise render wrong-root
}
@test "group-writable stage parent cannot authorize removal" { exercise owner unsafe-parent; }
@test "stage file predicate rejects foreign owner, links and unsafe modes" {
  run python3 -I "$ROOT/scripts/tests/helpers/release-stale-file-predicate.py" "$ROOT/scripts/release.sh"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
@test "ACL on parent, stage or hook child prevents removal" {
  if [ "$(uname -s)" != Darwin ] && ! command -v setfacl >/dev/null 2>&1; then
    skip 'setfacl unavailable on this Linux host'
  fi
  exercise owner acl-parent
  exercise owner acl-stage
  exercise hooks acl-child
}

@test "release.sh avoids process substitutions that corrupt macOS Bash 3.2 subshells" {
  # macOS /bin/bash 3.2.57 corrupts xzone malloc (SIGTRAP / exit 133) after 254
  # cumulative process substitutions inside a subshell function such as
  # adopt_group() or recover_adoptions().
  run grep -nE '<[[:space:]]*<\(' "$ROOT/scripts/release.sh"
  [ "$status" -eq 1 ] || {
    printf 'unexpected process substitution in scripts/release.sh:\n%s\n' "$output"
    return 1
  }
}
