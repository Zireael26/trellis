#!/usr/bin/env bats
# 1.3.12 workstream A, unit A4: the deferred post-attach checks run as one
# detached job per worktree, record a status file under
# $TRELLIS_HOME/state/attachment-status, and surface in doctor and pre-push.
# Every case uses the private portable fixture home from doctor-fix-common.
# A fixture attach costs minutes on a loaded host, so each case walks one
# attachment through a sequence of states instead of attaching per assertion.

load doctor-fix-common

JOB="$REPO_ROOT/scripts/lib/attach-postjob.sh"
CHECK_NAMES='["hooks-path","release","owner-artifacts","exclude","toolchain","registry"]'

# A healthy attached fixture with managed hooks. The fixture attach itself does
# not spawn, so each case drives the job explicitly.
postjob_attach() {
  TRELLIS_ATTACH_POSTJOB=off hooks_fix_attach null || return 1
  ST_DIR="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  ST="$ST_DIR/$PORTABLE_WORKTREE_ID.json"
}

run_job() {
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB HOME="$PORTABLE_ACCOUNT_HOME" \
    TRELLIS_HOME="$PORTABLE_HOME" bash "$JOB" "$@" </dev/null
}

run_pre_push() {
  run bash -c 'cd "$1" && env -u TRELLIS_CONFIG HOME="$2" "$3/pre-push" origin /dev/null </dev/null' \
    _ "$PORTABLE_PROJECT" "$PORTABLE_ACCOUNT_HOME" "$HF_MANAGED"
}

state_of() { jq -r '.state' "$ST"; }

# write_status <state> [attachment-id] [owner-sha256] [updated-at] [failure-json]
write_status() {
  local state="$1" attachment="${2:-}" sha="${3:-}" at="${4:-}" failure="${5:-null}"
  [ -n "$attachment" ] || attachment="$(jq -r '.attachment_id' "$HF_OWNER")"
  [ -n "$sha" ] || sha="$(sha_of "$HF_OWNER")"
  [ -n "$at" ] || at="$(date +%s)"
  mkdir -p "$ST_DIR"
  chmod 700 "$PORTABLE_HOME/state/attachment-status" "$ST_DIR"
  jq -n --arg state "$state" --arg checkout "$PORTABLE_CHECKOUT_ID" --arg worktree "$PORTABLE_WORKTREE_ID" \
    --arg attachment "$attachment" --arg sha "$sha" --argjson at "$at" --argjson failure "$failure" '
      {schema_version:1,state:$state,checkout_id:$checkout,worktree_id:$worktree,
       attachment_id:$attachment,owner_sha256:$sha,updated_at:$at,checks:[],failure:$failure}' > "$ST"
  chmod 600 "$ST"
}

# A live process holding this checkout's attachment lock.
hold_checkout_lock() {
  sleep 300 &
  HOLDER_PID=$!
  TRELLIS_HOME="$PORTABLE_HOME" bash -c '
    . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/attachment.sh"
    _attachment_test_stage_checkout_lock "$2" "$3" "$4" "$5"' _ \
    "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_CHECKOUT_ID" "$PORTABLE_COMMON" "$HOLDER_PID"
}

release_checkout_lock() {
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
}

mode_of() { fixture_mode_of "$1"; }
fixture_mode_of() {
  local candidate
  candidate="$(/usr/bin/stat -f '%Lp' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in ''|*[!0-7]*) candidate="$(/usr/bin/stat -c '%a' "$1")" ;; esac
  printf '%s\n' "$candidate"
}

wait_for_state() {
  local want="$1" tries=0
  while [ "$tries" -lt 1200 ]; do
    [ -f "$ST" ] && [ "$(state_of)" = "$want" ] && return 0
    sleep 0.5
    tries=$((tries + 1))
  done
  echo "state never reached $want: $(cat "$ST" 2>/dev/null)"
  return 1
}

@test "A4 status, stale, doctor row and pre-push verdicts on one attachment" {
  postjob_attach
  # Sync run: ok with every check, keyed to the attachment, private, atomic.
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  [ "$(jq -c '[.checks[].name]' "$ST")" = "$CHECK_NAMES" ] || { cat "$ST"; false; }
  [ "$(jq -r '[.checks[].result] | unique | join(",")' "$ST")" = ok ]
  [ "$(jq -r '.attachment_id' "$ST")" = "$(jq -r '.attachment_id' "$HF_OWNER")" ]
  [ "$(jq -r '.owner_sha256' "$ST")" = "$(sha_of "$HF_OWNER")" ]
  [ "$(jq -r '.checkout_id + "/" + .worktree_id' "$ST")" = "$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID" ]
  [ "$(jq -c '.failure' "$ST")" = null ]
  [ "$(mode_of "$ST")" = 600 ]
  [ "$(mode_of "$ST_DIR")" = 700 ]
  [ "$(mode_of "$PORTABLE_HOME/state/attachment-status")" = 700 ]
  [ -z "$(find "$ST_DIR" -name '.*' -print)" ] || { ls -la "$ST_DIR"; false; }
  # ok: doctor reports it and pre-push skips the inline run.
  run_portable_doctor_fix
  [[ "$output" == *"✓ attachment checks: ok"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"running them inline"* ]] || { echo "$output"; false; }
  # Stale: another attachment ID or owner digest; pre-push re-runs inline.
  write_status ok "00000000-0000-4000-8000-000000000000"
  run_portable_doctor_fix
  [[ "$output" == *"attachment checks: stale"*"trellis doctor --fix"* ]] || { echo "$output"; false; }
  write_status ok "" "$(printf '0%.0s' $(seq 64))"
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks are stale; running them inline"* ]] || { echo "$output"; false; }
  # Long-pending warns in doctor; pending passes inline on a healthy attachment.
  write_status pending "" "" "$(( $(date +%s) - 7200 ))"
  run_portable_doctor_fix
  [[ "$output" == *"⚠ attachment checks: pending for "*"trellis doctor --fix"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks are pending; running them inline"* ]] || { echo "$output"; false; }
  # FAILED: doctor errors with the remedy and pre-push refuses.
  write_status failed "" "" "" '{"check":"exclude","code":3,"remedy":"restore the recorded exclude block"}'
  run_portable_doctor_fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"✗ attachment checks FAILED at exclude"*"restore the recorded exclude block"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks FAILED at exclude"*"restore the recorded exclude block"* ]] || { echo "$output"; false; }
  # doctor --fix runs the job synchronously; --dry-run only says it would.
  run_portable_doctor_fix --fix --dry-run
  [ "$(state_of)" = failed ]
  [[ "$output" == *"attachment checks would run now"* ]] || { echo "$output"; false; }
  run_portable_doctor_fix --fix
  [ "$(state_of)" = ok ] || { echo "$output"; cat "$ST"; false; }
  [[ "$output" == *"✓ attachment checks: ok"* ]] || { echo "$output"; false; }
  # Missing: doctor says so, pre-push runs the checks inline.
  rm "$ST"
  run_portable_doctor_fix
  [[ "$output" == *"attachment checks: not recorded"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks are missing; running them inline"* ]] || { echo "$output"; false; }
  # Pending with a broken owned artifact: the inline run refuses the push and
  # reports, without rewriting the status.
  write_status pending
  leaf="$(jq -r '[.artifacts[] | select(.kind == "symlink" and .path != ".trellis/runtime")][0].path' "$HF_OWNER")"
  [ -n "$leaf" ] && [ "$leaf" != null ]
  rm "$PORTABLE_PROJECT/$leaf"
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks are pending; running them inline"* ]] || { echo "$output"; false; }
  [[ "$output" == *"attachment check failed at owner-artifacts"* ]] || { echo "$output"; false; }
  [ "$(state_of)" = pending ]
}

@test "A4 journal, lock contention and the husky hooksPath reassert" {
  postjob_attach
  local journal="$PORTABLE_HOME/state/attachment-journals/11111111-1111-4111-8111-111111111111.json"
  # Another checkout's journal does not block this one.
  jq -n '{checkout_id:"'"$(printf 'f%.0s' $(seq 64))"'"}' > "$journal"
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ]
  # A journal or adoption that appears after an ok status outranks it.
  jq -n --arg checkout "$PORTABLE_CHECKOUT_ID" '{checkout_id:$checkout}' > "$journal"
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis recover"* ]] || { echo "$output"; false; }
  [ "$(state_of)" = ok ]
  rm "$journal"
  mkdir -p "$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"release adopt"* ]] || { echo "$output"; false; }
  rmdir "$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  # This checkout's journal: blocked-by-journal, nothing checked or changed.
  jq -n --arg checkout "$PORTABLE_CHECKOUT_ID" '{checkout_id:$checkout}' > "$journal"
  before="$(config_digest)"
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(state_of)" = blocked-by-journal ] || { cat "$ST"; false; }
  [[ "$(jq -r '.failure.remedy' "$ST")" == *"trellis recover"* ]] || { cat "$ST"; false; }
  [ "$(jq -c '.checks' "$ST")" = '[]' ]
  [ "$(config_digest)" = "$before" ]
  # Still blocked at pre-push while the journal remains.
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis recover"* ]] || { echo "$output"; false; }
  rm "$journal"
  mkdir -p "$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(state_of)" = blocked-by-journal ]
  [[ "$(jq -r '.failure.remedy' "$ST")" == *"release adopt"* ]] || { cat "$ST"; false; }
  rmdir "$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  # husky resets hooksPath while another writer holds the checkout lock: the
  # job withholds the reassert, stays PENDING, never waits, changes nothing.
  husky_prepare
  before="$(config_digest)"
  hold_checkout_lock
  started=$SECONDS
  run_job run --sync --target "$PORTABLE_PROJECT"
  elapsed=$((SECONDS - started))
  release_checkout_lock
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ "$(state_of)" = pending ] || { cat "$ST"; false; }
  [[ "$output" == *"checkout lock"* ]] || { echo "$output"; false; }
  [ "$elapsed" -lt 280 ] || { echo "waited ${elapsed}s"; false; }
  [ "$(config_digest)" = "$before" ]
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = .husky/_ ]
  # Holder gone: the job re-asserts hooksPath through the R4.6 repair.
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = "$HF_MANAGED" ]
  [ "$(state_of)" = ok ]
  [ "$(jq -r '.checks[] | select(.name == "hooks-path") | .result' "$ST")" = ok ]
  [[ "$output" == *"core.hooksPath repaired in"* ]] || { echo "$output"; false; }
  # Contention at the commit step leaves PENDING as well.
  hold_checkout_lock
  run_job run --sync --target "$PORTABLE_PROJECT"
  release_checkout_lock
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ "$(state_of)" = pending ]
  # A journal published after the first journal read but before the checkout
  # lock is taken blocks the reassert: hooksPath stays as husky left it.
  husky_prepare
  before="$(config_digest)"
  out="$BATS_TEST_TMPDIR/lock-race.out"
  env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB ATTACH_POSTJOB_TEST_LOCK_HOLD=5 HOME="$PORTABLE_ACCOUNT_HOME" \
    TRELLIS_HOME="$PORTABLE_HOME" bash "$JOB" run --sync --target "$PORTABLE_PROJECT" </dev/null >"$out" 2>&1 &
  job=$!
  tries=0
  until grep -q 'test hold before the checkout lock' "$out" || [ "$tries" -ge 240 ]; do sleep 0.25; tries=$((tries + 1)); done
  jq -n --arg checkout "$PORTABLE_CHECKOUT_ID" '{checkout_id:$checkout}' > "$journal"
  rc=0
  wait "$job" || rc=$?
  rm "$journal"
  grep -q 'test hold before the checkout lock' "$out" || { cat "$out"; false; }
  [ "$rc" -eq 3 ] || { cat "$out"; false; }
  ! grep -q 'core.hooksPath repaired' "$out" || { cat "$out"; false; }
  [ "$(config_digest)" = "$before" ]
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = .husky/_ ]
  [ "$(state_of)" = blocked-by-journal ]
}

# U2: a pending release adoption refuses the push before the chained prior hook
# (husky's .husky/pre-push, which runs the project suite) starts. The sentinel is
# the chained hook's marker file: absent on refusal, present on normal dispatch.
@test "U2 pending adoption refuses before the chained suite starts; normal dispatch still runs it" {
  TRELLIS_ATTACH_POSTJOB=off hooks_fix_attach husky
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$HF_OWNER")" = ".husky/_" ] || { cat "$HF_OWNER"; false; }
  ST_DIR="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  ST="$ST_DIR/$PORTABLE_WORKTREE_ID.json"
  local sentinel="$SANDBOX/husky-pre-push-ran"
  rm -f "$sentinel"
  mkdir -p "$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  run_pre_push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks are blocked: a group release adoption is pending for this checkout; remedy: retry trellis release adopt with the same selector to recover"* ]] || { echo "$output"; false; }
  [ ! -e "$sentinel" ] || { echo "chained suite started on pending adoption"; false; }
  rmdir "$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  run_pre_push
  [ -e "$sentinel" ] || { echo "normal dispatch did not reach the chained hook: $output"; false; }
  # Exit 0 is reachable only when the carrier gate ran and passed: a refusal
  # sets carrier_status 1, and a nonzero prior hook would have won.
  [ "$status" -eq 0 ] || { echo "normal dispatch exit $status, expected 0 from the carrier: $output"; false; }
  [[ "$output" != *"release adoption is pending"* ]] || { echo "$output"; false; }
}

# U2 remediation: the chained prior hook runs after the early preflight, so the
# carrier must be verified again after it. A prior hook that replaces the
# immutable carrier must be refused, and the replacement must never execute.
@test "U2 prior hook that replaces the immutable carrier is refused before the carrier runs" {
  TRELLIS_ATTACH_POSTJOB=off hooks_fix_attach husky
  ST_DIR="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  ST="$ST_DIR/$PORTABLE_WORKTREE_ID.json"
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  local sentinel="$SANDBOX/husky-pre-push-ran" carrier_sentinel="$SANDBOX/carrier-ran" carrier
  carrier="$(cat "$HF_MANAGED/release-payload")/$(cat "$HF_MANAGED/pre-push-source")"
  [ -f "$carrier" ] && [ ! -L "$carrier" ] || { echo "carrier missing: $carrier"; false; }
  # The prior hook rewrites the carrier in place (test-only, sandbox TRELLIS_HOME)
  # into an exit-0 script that records its own execution.
  cat > "$PORTABLE_PROJECT/.husky/pre-push" <<EOF
#!/bin/sh
printf chained > "$sentinel"
chmod u+w "$carrier"
printf '#!/bin/sh\nprintf carrier > "$carrier_sentinel"\nexit 0\n' > "$carrier"
EOF
  run_pre_push
  [ -e "$sentinel" ] || { echo "prior hook did not run: $output"; false; }
  [ ! -e "$carrier_sentinel" ] || { echo "replaced carrier executed: $output"; false; }
  [ "$status" -eq 1 ] || { echo "tampered carrier not refused, status $status: $output"; false; }
  [[ "$output" == *"trellis pre-push: managed immutable release carrier is unavailable"* ]] || { echo "$output"; false; }
}

# U2 remediation: a pending adoption published by the chained prior hook, after
# the early preflight passed on an ok status, must still refuse before the carrier.
@test "U2 adoption published during the chained suite refuses before the carrier runs" {
  TRELLIS_ATTACH_POSTJOB=off hooks_fix_attach husky
  ST_DIR="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  ST="$ST_DIR/$PORTABLE_WORKTREE_ID.json"
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  local sentinel="$SANDBOX/husky-pre-push-ran" adoption="$PORTABLE_HOME/state/release-adoptions/$PORTABLE_CHECKOUT_ID"
  [ ! -e "$adoption" ] || { echo "adoption marker preexists"; false; }
  cat > "$PORTABLE_PROJECT/.husky/pre-push" <<EOF
#!/bin/sh
printf chained > "$sentinel"
mkdir -p "$adoption"
EOF
  run_pre_push
  [ -e "$sentinel" ] || { echo "prior hook did not run: $output"; false; }
  [ -d "$adoption" ] || { echo "prior hook did not publish the marker"; false; }
  [ "$status" -eq 1 ] || { echo "adoption published mid-suite not refused, status $status: $output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks are blocked: a group release adoption is pending for this checkout; remedy: retry trellis release adopt with the same selector to recover"* ]] || { echo "$output"; false; }
}

@test "A4 attach spawns the detached job: pending at once, then ok; own session, stdin /dev/null, no caller pipes" {
  TRELLIS_ATTACH_POSTJOB=off build_portable_doctor_fix_home
  install_portable_doctor_release
  ST_DIR="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  ST="$ST_DIR/$PORTABLE_WORKTREE_ID.json"
  HF_OWNER="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash -c '"$1" attach --home "$2" --fleet personal --release 1.2.3 --harness claude --harness codex "$3" &&
      jq -r .state "$4"' _ "$REPO_ROOT/scripts/attach-project.sh" "$PORTABLE_HOME" "$PORTABLE_PROJECT" "$ST"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "${lines[${#lines[@]}-1]}" == pending || "${lines[${#lines[@]}-1]}" == running ]] || { echo "$output"; false; }
  wait_for_state ok
  [ "$(jq -r '.attachment_id' "$ST")" = "$(jq -r '.attachment_id' "$HF_OWNER")" ]
  [ "$(jq -c '[.checks[].name]' "$ST")" = "$CHECK_NAMES" ]
  # The spawn API directly: fd 1, 2 and 3 are the command-substitution pipe,
  # so if the job kept any of them this would block for its 30 s hold. Fd 5000
  # sits above any guessed descriptor ceiling and must not survive either.
  high_fd="$BATS_TEST_TMPDIR/inherited-fd-5000"
  started=$SECONDS
  out="$(printf 'refs/heads/main 0 refs/heads/main 0\n' |
    env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB ATTACH_POSTJOB_TEST_HOLD=30 HOME="$PORTABLE_ACCOUNT_HOME" \
      TRELLIS_HOME="$PORTABLE_HOME" bash -c '
        . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/release-store.sh"
        . "$1/scripts/lib/local-registry.sh"
        . "$1/scripts/lib/attachment.sh"; . "$1/scripts/lib/attach-postjob.sh"
        exec 5000>"$4" || exit 9
        trellis_attach_postjob_spawn "$2" "$3"; echo "spawned $?"' _ \
      "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" "$high_fd" 3>&1 2>&1)"
  elapsed=$((SECONDS - started))
  [ "$out" = "spawned 0" ] || { echo "$out"; false; }
  [ "$elapsed" -lt 15 ] || { echo "spawn held the pipe for ${elapsed}s"; false; }
  [ "$(state_of)" = pending ]
  job_lock="$ST_DIR/$PORTABLE_WORKTREE_ID.job"
  tries=0
  until [ -f "$job_lock/pid" ] || [ "$tries" -ge 120 ]; do sleep 0.25; tries=$((tries + 1)); done
  pid="$(cut -d ' ' -f 1 "$job_lock/pid")"
  kill -0 "$pid"
  run python3 -c 'import os, sys; print(os.getsid(int(sys.argv[1])) != os.getsid(0))' "$pid"
  [ "$output" = True ] || { echo "same session: $output"; false; }
  run lsof -a -p "$pid" -d 0 -Fn
  [[ "$output" == *"n/dev/null"* ]] || { echo "$output"; false; }
  run lsof -a -p "$pid" -d 1,2 -Fn
  [[ "$output" == *"n$ST_DIR/$PORTABLE_WORKTREE_ID.log"* ]] || { echo "$output"; false; }
  [[ "$output" != *pipe* ]] || { echo "$output"; false; }
  run lsof -a -p "$pid" -Fn
  # lsof reports the resolved path (/tmp is /private/tmp), so match the name.
  [[ "$output" != *inherited-fd-5000* ]] || { echo "inherited fd 5000 survived: $output"; false; }
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  tries=0
  while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
}
