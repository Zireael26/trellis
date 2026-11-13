#!/usr/bin/env bats
# The release-store fixture must not remove or reuse a home with live postjobs.
load release-store-common

setup() {
  export TRELLIS_ATTACH_POSTJOB=off
  GROUP_PLAN_CASE_LOCK_HELD=false
  SANDBOX="$BATS_TEST_TMPDIR/machine [literal] with spaces"
  mkdir -p "$SANDBOX"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  initialize_release_store_machine || return 1
  RELEASE_PROCESS_PID_A=""
  RELEASE_PROCESS_PID_B=""
  RELEASE_PROCESS_STATUS=""
  POSTJOB_TEST_CONTROL=""
  POSTJOB_TEST_OTHER_PID=""
}

teardown() {
  # Release our barriers even when an assertion or spawn fails unexpectedly.
  if [ -n "${POSTJOB_TEST_CONTROL:-}" ]; then
    : > "$POSTJOB_TEST_CONTROL/release"
    : > "$POSTJOB_TEST_CONTROL/other-release"
  fi
  if [ -n "${POSTJOB_TEST_OTHER_PID:-}" ]; then
    wait "$POSTJOB_TEST_OTHER_PID" 2>/dev/null || true
  fi
  release_store_fixture_teardown
}

@test "teardown retains the fixture and lease for a live postjob, then ignores another home" {
  local control="$BATS_TEST_TMPDIR/postjob-control" version=2.9.1 repo project owner status_file lock job_pid
  local postjob other_job other_pid tries=0 first_rc=0 second_rc=0 first_home first_lease
  local live_after_second=no other_live_after_second=no
  mkdir -p "$control/bin" "$control/other-home/releases/other/payload/scripts/lib"
  POSTJOB_TEST_CONTROL="$control"
  cat > "$control/bin/sleep" <<'SH'
#!/bin/bash
if [ "${1-}" = 987 ]; then
  : > "$POSTJOB_BARRIER/held"
  while [ ! -e "$POSTJOB_BARRIER/release" ]; do /bin/sleep 0.1; done
else
  exec /bin/sleep "$@"
fi
SH
  chmod +x "$control/bin/sleep"
  other_job="$control/other-home/releases/other/payload/scripts/lib/attach-postjob.sh"
  cat > "$other_job" <<'SH'
#!/bin/bash
: > "$OTHER_BARRIER/other-held"
while [ ! -e "$OTHER_BARRIER/other-release" ]; do /bin/sleep 0.1; done
SH
  chmod +x "$other_job"

  repo="$(build_release_repo "$version")"
  install_release "$version" "$repo"
  project="$SANDBOX/postjob-project"
  make_portable_project "$project" postjob-project
  attach_portable_project "$project" personal "$version"
  owner="$(owner_for_root "$project")"
  status_file="$TRELLIS_HOME_FIX/state/attachment-status/${owner#"$TRELLIS_HOME_FIX/state/attachments/"}"
  lock="${status_file%.json}.job"
  postjob="$TRELLIS_HOME_FIX/releases/$version/payload/scripts/lib/attach-postjob.sh"

  GROUP_PLAN_RELEASE_CACHE="$BATS_TEST_TMPDIR/lease"
  mkdir -p "$GROUP_PLAN_RELEASE_CACHE"
  group_plan_case_lease_acquire || { echo 'could not acquire fixture lease'; false; }
  OTHER_BARRIER="$control" /bin/bash "$other_job" </dev/null >/dev/null 2>&1 &
  other_pid=$!
  POSTJOB_TEST_OTHER_PID="$other_pid"
  env -u TRELLIS_ATTACH_POSTJOB -u TRELLIS_LIBS_PRELOADED \
    TRELLIS_HOME="$TRELLIS_HOME_FIX" ATTACH_POSTJOB_TEST_HOLD=987 POSTJOB_BARRIER="$control" \
    PATH="$control/bin:$PATH" /bin/bash --noprofile --norc "$postjob" spawn --target "$project" \
    </dev/null >/dev/null 2>&1 || {
      : > "$control/release"; : > "$control/other-release"; wait "$other_pid" || true; false
    }
  while [ ! -f "$control/held" ] || [ ! -f "$control/other-held" ] || [ ! -f "$lock/pid" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 3000 ]; then
      : > "$control/release"; : > "$control/other-release"; wait "$other_pid" || true
      echo 'postjob barriers did not become ready'; false
    fi
    sleep 0.1
  done
  job_pid="$(awk '{print $1}' "$lock/pid")"

  # The real job remains held until explicitly released. A timeout must report
  # failure without deleting the home or releasing its lease.
  if FIXTURE_POSTJOB_WAIT_SECONDS=1 release_store_fixture_teardown; then first_rc=0; else first_rc=$?; fi
  first_home=absent; [ ! -d "$SANDBOX" ] || first_home=present
  first_lease=absent; [ ! -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ] || first_lease=present
  : > "$control/release"
  if FIXTURE_POSTJOB_WAIT_SECONDS=120 release_store_fixture_teardown; then second_rc=0; else second_rc=$?; fi
  if ps -p "$job_pid" -o command= 2>/dev/null | grep -F "$postjob" >/dev/null; then live_after_second=yes; fi
  if kill -0 "$other_pid" 2>/dev/null; then other_live_after_second=yes; fi
  : > "$control/other-release"
  wait "$other_pid" || true
  # Even a pre-fix failure must not strand this test's real detached job.
  tries=0
  while ps -p "$job_pid" -o command= 2>/dev/null | grep -F "$postjob" >/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 1200 ] || { echo "postjob $job_pid did not exit"; false; }
    sleep 0.1
  done

  [ "$first_rc" -ne 0 ] || { echo 'teardown succeeded with a live postjob'; false; }
  [ "$first_home" = present ] || { echo 'teardown deleted the live postjob home'; false; }
  [ "$first_lease" = present ] || { echo 'teardown released the live postjob lease'; false; }
  [ "$second_rc" -eq 0 ] || { echo "teardown did not finish after releasing its job: $second_rc"; false; }
  [ "$live_after_second" = no ] || { echo 'fixture postjob outlived successful teardown'; false; }
  [ "$other_live_after_second" = yes ] || { echo 'an unrelated home was signalled or waited for'; false; }
  [ ! -d "$SANDBOX" ] || { echo 'fixture home was not removed'; false; }
  [ ! -d "$GROUP_PLAN_RELEASE_CACHE/case.lock" ] || { echo 'fixture lease was not released'; false; }
}
