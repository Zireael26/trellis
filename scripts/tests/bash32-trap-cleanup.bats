#!/usr/bin/env bats
# In sourced, bash -c and command-substitution contexts Bash 3.2 can lose
# function-local state when an exit or signal unwinds a subshell. Exercise the
# real bodies with deterministic seams; dynamic-scope collisions also affect 5.

setup() {
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  WORK="$(CDPATH='' cd "$BATS_TEST_TMPDIR" && pwd -P)"
  DRIVER="$ROOT/scripts/tests/helpers/bash32-trap-driver.sh"
  # Default /bin/bash is 3.2 on macOS but may be Bash 5 on Linux. This
  # test-only selector also lets the same cases run under an explicit Bash 5.
  CASE_BASH="${TRELLIS_TRAP_CASE_BASH:-/bin/bash}"
}

exercise() {
  run "$CASE_BASH" --noprofile --norc -c '. "$1" "$2" "$3" "$4"' bash32-trap \
    "$DRIVER" "$1" "$ROOT" "$WORK"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" != *'unbound variable'* ]] || { printf '%s\n' "$output"; return 1; }
}

@test "bash32 release owner exchange rolls back after TERM" { exercise release-owned; }
@test "bash32 release render exchange rolls back after TERM" { exercise release-render; }
@test "bash32 failed hook exchange cleans the staged payload" { exercise release-hooks; }
@test "bash32 migration staged file cleans up after TERM" { exercise migrate-publish; }
@test "bash32 migration prepare cleans its work directory after TERM" { exercise migrate-prepare; }
@test "bash32 scheduled-task failure cleans its stage after returning" { exercise materialize; }
@test "bash32 configure early failure removes roots scratch" { exercise configure; }
@test "bash32 fleet add early failure removes roots scratch" { exercise fleet-add; }
@test "bash32 fleet set-default failure removes proposed scratch" { exercise fleet-default; }
@test "bash32 large jq transport cleans its work directory after TERM" { exercise jq; }
@test "bash32 user attach cleans and preserves recovery diagnostics after TERM" { exercise user-attach; }
@test "bash32 user detach preserves recovery diagnostics after TERM" { exercise user-detach; }
@test "bash32 user relink preserves recovery diagnostics after TERM" { exercise user-relink; }
@test "bash32 bound-harness reconcile releases lock and scratch after TERM" { exercise reconcile-bound; }
@test "bash32 owner-registry reconcile releases lock and scratch after TERM" { exercise reconcile-owner; }
@test "bash32 donor fastpath releases locks and scratch after TERM" { exercise fastpath; }
@test "bash32 detach owner RETURN cleanup does not escape into callers" { exercise detach-return; }
@test "bash32 Claude flagged-index failure cleans its private copy" { exercise flagged-claude; }
@test "bash32 Codex flagged-index failure cleans its private copy" { exercise flagged-codex; }
@test "bash32 Claude flagged diff cleans its index under errexit" { exercise flagged-diff-claude; }
@test "bash32 Codex flagged diff cleans its index under errexit" { exercise flagged-diff-codex; }

exercise_r2() {
  local case_name="$1" work="$WORK/space ' $1"
  mkdir "$work"
  run "$CASE_BASH" --noprofile --norc -c '. "$1" "$2" "$3" "$4"' bash32-trap \
    "$DRIVER" "$case_name" "$ROOT" "$work"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" != *'unbound variable'* ]] || { printf '%s\n' "$output"; return 1; }
}

@test "bash32 owner transaction survives TERM in each exchange phase with shadow locals" {
  for phase in pre swap old new; do exercise_r2 "r2-owner-$phase"; done
}
@test "bash32 render transaction survives TERM in each exchange phase with shadow locals" {
  for phase in pre swap old new; do exercise_r2 "r2-render-$phase"; done
}
@test "bash32 hook transaction survives TERM in each exchange phase with shadow locals" {
  for phase in pre swap old new; do exercise_r2 "r2-hooks-$phase"; done
}
@test "bash32 user attach, detach and relink retain cleanup state under helper locals" {
  for verb in attach detach relink; do
    for phase in reclaim acquire recover; do exercise_r2 "r2-user-$verb-$phase"; done
  done
  exercise_r2 r2-user-attach-realrecover
  exercise_r2 r2-user-relink-plan
  exercise_r2 r2-user-relink-planlock
}
@test "bash32 jq scratch survives final jq failure under inherited errexit" { exercise_r2 r2-jq-errexit; }
@test "bash32 TERM to materializer PID cannot leave a publishing child" { exercise_r2 r2-materialize-signal; }
@test "bash32 materializer releases a newly acquired registry or task lock on TERM" {
  exercise_r2 r2-materialize-lock-registry
  exercise_r2 r2-materialize-lock-scheduled-tasks
  exercise_r2 r2-materialize-lock-foreign
  exercise_r2 r2-materialize-lock-different
  exercise_r2 r2-materialize-lock-different-set
  exercise_r2 r2-materialize-lock-missing
}
@test "cleanup blocks a second TERM before disarming EXIT" {
  for target in release-owned release-render release-hooks adopt-group migrate-publish migrate-prepare jq materialize \
    reconcile-bound reconcile-owner fastpath user-attach user-detach user-relink; do
    exercise_r2 "r2-order-$target"
  done
}
@test "bash32 user signal fixtures preserve spaces, quotes, newline and literal substitutions" {
  local hostile="$WORK/"$'we ird\047$(touch PWNED)\ndir' case_name
  mkdir "$hostile"
  for case_name in user-attach r2-user-attach-realrecover; do
    mkdir "$hostile/$case_name"
    run "$CASE_BASH" --noprofile --norc -c 'cd "$5" && . "$1" "$2" "$3" "$4"' bash32-trap \
      "$DRIVER" "$case_name" "$ROOT" "$hostile/$case_name" "$WORK"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  done
  [ ! -e "$WORK/PWNED" ]
}
