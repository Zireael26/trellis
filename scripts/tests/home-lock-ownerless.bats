#!/usr/bin/env bats
# The shared mkdir lock is Bash 3.2-compatible and must eventually recover an
# interrupted ownerless initialization, without reclaiming young/live locks.

setup() {
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  WORK="$(CDPATH='' cd "$BATS_TEST_TMPDIR" && pwd -P)"
  DRIVER="$ROOT/scripts/tests/helpers/home-lock-ownerless-driver.sh"
  CASE_BASH="${TRELLIS_TRAP_CASE_BASH:-/bin/bash}"
}

exercise() {
  local case_name="$1" dir="$WORK/lock $1"
  mkdir "$dir"
  run "$CASE_BASH" --noprofile --norc "$DRIVER" "$case_name" "$ROOT" "$dir"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "age cutoff is strictly greater than ten minutes" { exercise age-boundary; }
@test "old missing PID lock is recovered" { exercise old-missing; }
@test "old empty PID lock is recovered" { exercise old-empty; }
@test "old blank-lines PID lock is recovered" { exercise old-blank-lines; }
@test "old ownerless registry and scheduled-task locks recover" {
  exercise registry-old-missing
  exercise scheduled-old-missing
}
@test "young ownerless registry and scheduled-task locks stay" {
  exercise registry-young-missing
  exercise scheduled-young-missing
}
@test "young missing PID lock stays" { exercise young-missing; }
@test "young empty PID lock stays" { exercise young-empty; }
@test "old lock with recently touched empty PID stays" { exercise old-dir-young-pid; }
@test "live numeric PID lock stays" { exercise live-pid; }
@test "dead numeric PID lock is recovered" { exercise dead-pid; }
@test "unknown entry prevents ownerless recovery" { exercise unknown-entry; }
@test "unknown entry beside empty PID prevents recovery" { exercise unknown-entry-with-pid; }
@test "symlink PID prevents ownerless recovery" { exercise symlink-pid; }
@test "hardlinked empty PID prevents ownerless recovery" { exercise hardlinked-empty-pid; }
@test "unsafe directory mode prevents ownerless recovery" { exercise unsafe-mode; }
@test "binary PID is not an empty owner record" { exercise binary-pid; }
@test "fresh lock acquisition uses no Python" { exercise fresh-no-python; }
@test "ownerless stale recovery uses no Python" { exercise old-no-python; }
@test "PID written during stale recheck is preserved" { exercise race-pid-write; }
@test "binary PID written during stale recheck is preserved" { exercise race-pid-null; }
@test "PID symlink substituted during stale recheck is preserved" { exercise race-pid-symlink; }
@test "directory swapped during stale recheck is preserved" { exercise race-dir; }
@test "foreign owner lock directory is not recovered" { exercise foreign-owner; }
@test "missing-pid ownerless race leaves single holder and loser exits 5" { exercise race-missing-acquire; }
@test "stalled-owner race leaves single holder and loser exits 5" { exercise race-stalled-owner; }
@test "old pid.recovery residue lock is recovered" {
  exercise old-residue
  exercise old-residue-multiple
}
@test "young pid.recovery residue lock stays" {
  exercise young-residue
  exercise old-dir-young-residue
}
@test "unknown entry beside recovery residue prevents recovery" { exercise residue-unknown-entry; }
@test "symlink recovery residue prevents recovery" { exercise residue-symlink; }
@test "hardlinked recovery residue prevents recovery" { exercise residue-hardlink; }
@test "binary recovery residue prevents recovery" { exercise residue-binary; }
@test "bad recovery residue name prevents recovery" { exercise residue-badname; }
@test "recovery residue swapped during recheck is preserved" { exercise race-residue-swap; }
@test "failed lost-race restore never deletes live owner record" { exercise restore-fail-keeps-record; }
@test "TERM at each mkdir/PID/acquisition phase eventually permits reacquisition" {
  for phase in before-mkdir after-mkdir after-pid after-chmod after-acquire; do
    exercise "term-$phase"
  done
}
