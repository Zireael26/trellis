#!/usr/bin/env bats
# R10 group-plan case lease helper tests. Lightweight: sources only
# helpers/group-plan.bash with a temp GROUP_PLAN_RELEASE_CACHE. No
# release-store fixtures, no attach/trellis commands.
# shellcheck disable=SC2034
load helpers/group-plan

setup() {
  LEASE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/group-plan-lease.XXXXXX")"
  LEASE_TMP="$(cd "$LEASE_TMP" && pwd -P)"
  GROUP_PLAN_RELEASE_CACHE="$LEASE_TMP/cache"
  mkdir -p "$GROUP_PLAN_RELEASE_CACHE"
  export GROUP_PLAN_RELEASE_CACHE
  GROUP_PLAN_CASE_LOCK_HELD=false
  LEASE_HOLDER_PID=""
}

teardown() {
  if [ -n "${LEASE_HOLDER_PID:-}" ]; then
    kill "$LEASE_HOLDER_PID" 2>/dev/null || true
    wait "$LEASE_HOLDER_PID" 2>/dev/null || true
  fi
  unset GROUP_PLAN_LEASE_POLL || true
  unset GROUP_PLAN_LEASE_GRACE || true
  unset GROUP_PLAN_LEASE_PROGRESS_INTERVAL || true
  unset GROUP_PLAN_LEASE_OBSERVE_MAX || true
  unset -f ps sed kill sleep 2>/dev/null || true
  if [ -n "${LEASE_TMP:-}" ] && [ -d "$LEASE_TMP" ]; then
    chmod -R u+w "$LEASE_TMP" 2>/dev/null || true
    rm -rf "$LEASE_TMP"
  fi
}

@test "lease (a) alive holder keeps waiter waiting, then acquire succeeds after release" {
  sleep 30 &
  LEASE_HOLDER_PID=$!
  holder_start="$(group_plan_case_lease__start_time "$LEASE_HOLDER_PID")"
  [ -n "$holder_start" ]
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$LEASE_HOLDER_PID" "$holder_start" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp"
  mv "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp" "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  export GROUP_PLAN_LEASE_POLL=0.05
  export GROUP_PLAN_LEASE_OBSERVE_MAX=0.5
  run group_plan_case_lease_acquire
  unset GROUP_PLAN_LEASE_OBSERVE_MAX
  [ "$status" -eq 2 ]
  [[ "$output" != *"stale lease"* ]]
  [[ "$output" != *"malformed lease"* ]]
  [ -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
  kill "$LEASE_HOLDER_PID" 2>/dev/null || true
  wait "$LEASE_HOLDER_PID" 2>/dev/null || true
  LEASE_HOLDER_PID=""
  rm -rf "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  run group_plan_case_lease_acquire
  [ "$status" -eq 0 ]
  [ -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
  GROUP_PLAN_CASE_LOCK_HELD=true
  group_plan_case_lease_release
  [ ! -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (b) dead holder fails fast as stale without breaking the lock" {
  sleep 30 &
  LEASE_HOLDER_PID=$!
  dead_pid="$LEASE_HOLDER_PID"
  dead_start="$(group_plan_case_lease__start_time "$dead_pid")"
  [ -n "$dead_start" ]
  kill "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  LEASE_HOLDER_PID=""
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$dead_pid" "$dead_start" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp"
  mv "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp" "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  export GROUP_PLAN_LEASE_POLL=0.05
  run group_plan_case_lease_acquire
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lease"* ]]
  [[ "$output" == *"$dead_pid"* ]]
  [[ "$output" == *"is dead"* ]]
  [ -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (c) live pid with wrong start fails fast as pid reuse" {
  sleep 30 &
  LEASE_HOLDER_PID=$!
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$LEASE_HOLDER_PID" "Mon Jan  1 00:00:00 2000" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp"
  mv "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp" "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  export GROUP_PLAN_LEASE_POLL=0.05
  run group_plan_case_lease_acquire
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid reuse"* ]]
  [[ "$output" == *"$LEASE_HOLDER_PID"* ]]
  [ -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (d) missing or garbage identity fails fast as malformed after grace" {
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  export GROUP_PLAN_LEASE_POLL=0.05
  export GROUP_PLAN_LEASE_GRACE=0.3
  run group_plan_case_lease_acquire
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed lease"* ]]
  rm -rf "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf 'garbage-no-newline' > "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  run group_plan_case_lease_acquire
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed lease"* ]]
  [ -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (e) waiter prints progress naming holder pid and elapsed" {
  sleep 30 &
  LEASE_HOLDER_PID=$!
  holder_start="$(group_plan_case_lease__start_time "$LEASE_HOLDER_PID")"
  [ -n "$holder_start" ]
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$LEASE_HOLDER_PID" "$holder_start" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp"
  mv "$GROUP_PLAN_RELEASE_CACHE/case.lock/.tmp" "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  export GROUP_PLAN_LEASE_POLL=0.05
  export GROUP_PLAN_LEASE_PROGRESS_INTERVAL=0.1
  export GROUP_PLAN_LEASE_OBSERVE_MAX=0.6
  run group_plan_case_lease_acquire
  [ "$status" -eq 2 ]
  [[ "$output" == *"waiting for holder pid $LEASE_HOLDER_PID"* ]]
  [[ "$output" == *"elapsed"* ]]
  [ -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (f) missing cache dir fails fast without spinning" {
  GROUP_PLAN_RELEASE_CACHE="$LEASE_TMP/does-not-exist"
  export GROUP_PLAN_RELEASE_CACHE
  export GROUP_PLAN_LEASE_POLL=0.05
  run group_plan_case_lease_acquire
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
  [ ! -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (g) zombie holder is dead and start time uses C locale" {
  sleep 30 & LEASE_HOLDER_PID=$!
  holder_start="$(group_plan_case_lease__start_time "$LEASE_HOLDER_PID")"
  [ -n "$holder_start" ]
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$LEASE_HOLDER_PID" "$holder_start" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  ps() {
    case "$*" in
      *state=*) printf 'Z\n'; return 0 ;;
      *) command ps "$@" ;;
    esac
  }
  export GROUP_PLAN_LEASE_POLL=0.05
  export GROUP_PLAN_LEASE_OBSERVE_MAX=0.5
  run group_plan_case_lease_acquire
  [ "$status" -eq 1 ]
  [[ "$output" == *"is dead"* ]]
  ps() {
    case "$*" in
      *state=*) printf 'S\n'; return 0 ;;
      *lstart*)
        if [ "${LC_ALL:-}" = "C" ]; then printf 'Wed Oct  7 11:21:31 2026\n'; else printf 'mer. 7 oct. 11:21:31 2026\n'; fi
        return 0 ;;
      *) command ps "$@" ;;
    esac
  }
  out="$(LC_ALL=fr_FR group_plan_case_lease__start_time "$LEASE_HOLDER_PID")"
  [ "$out" = "Wed Oct 7 11:21:31 2026" ]
}

@test "lease (h) waiter and release read identity without sed line helpers" {
  sleep 30 & LEASE_HOLDER_PID=$!
  holder_start="$(group_plan_case_lease__start_time "$LEASE_HOLDER_PID")"
  [ -n "$holder_start" ]
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$LEASE_HOLDER_PID" "$holder_start" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  sed() {
    case "$*" in
      *1p*|*2p*|*3p*) return 1 ;;
      *) command sed "$@" ;;
    esac
  }
  export GROUP_PLAN_LEASE_POLL=0.05
  export GROUP_PLAN_LEASE_GRACE=0.3
  export GROUP_PLAN_LEASE_OBSERVE_MAX=1.0
  run group_plan_case_lease_acquire
  [ "$status" -eq 2 ]
  [[ "$output" != *"malformed lease"* ]]
  kill "$LEASE_HOLDER_PID" 2>/dev/null || true; wait "$LEASE_HOLDER_PID" 2>/dev/null || true
  rm -rf "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  run group_plan_case_lease_acquire
  [ "$status" -eq 0 ]
  GROUP_PLAN_CASE_LOCK_HELD=true
  group_plan_case_lease_release
  [ ! -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (i) a holder that releases and exits between the waiter's read and probe hands over" {
  # P1g (R39): two concurrent holders. Under load the live holder can release
  # and exit after the waiter read its identity but before kill -0/ps. That is
  # a normal handoff, never a stale lease that fails the waiter's setup.
  bash -c '. "$1"; group_plan_case_lease_acquire || exit 1; : > "$2"; exec sleep 30' _ \
    "$BATS_TEST_DIRNAME/helpers/group-plan.bash" "$LEASE_TMP/held" &
  LEASE_HOLDER_PID=$!
  local tries=0
  while [ ! -e "$LEASE_TMP/held" ] && [ "$tries" -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
  [ -e "$LEASE_TMP/held" ]
  [ "$(head -n 1 "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder")" = "$LEASE_HOLDER_PID" ]
  kill() {
    if [ "$1" = -0 ] && [ "$2" = "$LEASE_HOLDER_PID" ]; then
      unset -f kill
      # The holder's teardown lands exactly here: release, then process exit.
      rm -f "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
      rmdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
      kill "$LEASE_HOLDER_PID"
      wait "$LEASE_HOLDER_PID" 2>/dev/null || true
      LEASE_HOLDER_PID=""
    fi
    builtin kill "$@"
  }
  export GROUP_PLAN_LEASE_POLL=0.05
  local rc=0
  group_plan_case_lease_acquire 2>"$LEASE_TMP/acquire.err" || rc=$?
  unset -f kill
  [ "$rc" -eq 0 ] || { cat "$LEASE_TMP/acquire.err"; false; }
  [ -z "$LEASE_HOLDER_PID" ]
  [ "$(head -n 1 "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder")" = "$$" ]
  group_plan_case_lease_release
  [ ! -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ]
}

@test "lease (j) a long wait on a live holder heartbeats by wall clock, not poll count" {
  # P1g (R39 Q2 condition): an uncapped wait must say so at least every 5 min.
  # Each stubbed poll costs 100 s of wall clock, as under heavy load; ten polls
  # never reach the 1,200-poll count that a 60 s / 0.05 s cadence would need.
  sleep 30 &
  LEASE_HOLDER_PID=$!
  holder_start="$(group_plan_case_lease__start_time "$LEASE_HOLDER_PID")"
  [ -n "$holder_start" ]
  mkdir "$GROUP_PLAN_RELEASE_CACHE/case.lock"
  printf '%s\n%s\n' "$LEASE_HOLDER_PID" "$holder_start" > "$GROUP_PLAN_RELEASE_CACHE/case.lock/holder"
  export GROUP_PLAN_LEASE_POLL=0.05
  export GROUP_PLAN_LEASE_OBSERVE_MAX=0.5
  sleep() { SECONDS=$((SECONDS + 100)); }
  run group_plan_case_lease_acquire
  unset -f sleep
  [ "$status" -eq 2 ]
  [[ "$output" =~ "waiting for holder pid $LEASE_HOLDER_PID (elapsed "([0-9]+)"s" ]] || { echo "$output"; false; }
  [ "${BASH_REMATCH[1]}" -ge 100 ]
}
