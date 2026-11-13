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

# write_status <state> [attachment-id] [owner-sha256] [updated-at] [failure-json] [release] [root]
# Schema 2 (T14 amended): bound to the owner's release and worktree root too.
write_status() {
  local state="$1" attachment="${2:-}" sha="${3:-}" at="${4:-}" failure="${5:-null}" release="${6:-}" root="${7:-}"
  [ -n "$attachment" ] || attachment="$(jq -r '.attachment_id' "$HF_OWNER")"
  [ -n "$sha" ] || sha="$(sha_of "$HF_OWNER")"
  [ -n "$at" ] || at="$(date +%s)"
  [ -n "$release" ] || release="$(jq -r '.release' "$HF_OWNER")"
  [ -n "$root" ] || root="$(jq -r '.worktree_root' "$HF_OWNER")"
  mkdir -p "$ST_DIR"
  chmod 700 "$PORTABLE_HOME/state/attachment-status" "$ST_DIR"
  jq -n --arg state "$state" --arg checkout "$PORTABLE_CHECKOUT_ID" --arg worktree "$PORTABLE_WORKTREE_ID" \
    --arg attachment "$attachment" --arg sha "$sha" --argjson at "$at" --argjson failure "$failure" \
    --arg release "$release" --arg root "$root" '
      {schema_version:2,state:$state,checkout_id:$checkout,worktree_id:$worktree,
       attachment_id:$attachment,owner_sha256:$sha,release:$release,worktree_root:$root,
       updated_at:$at,checks:[],failure:$failure}' > "$ST"
  chmod 600 "$ST"
}

# The Stop gate as both shell twins run it (core-rules/hooks/lib/attach-verdict.sh).
run_stop_gate() {
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    TRELLIS_ATTACH_GATE_WAIT_SECONDS="${1:-60}" bash -c '
      . "$1/core-rules/hooks/lib/attach-verdict.sh"; trellis_attach_verdict_stop "$2"' _ "$REPO_ROOT" "$PORTABLE_PROJECT" </dev/null
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
  [ "$(jq -r '.schema_version' "$ST")" = 2 ]
  [ "$(jq -r '.release' "$ST")" = "$(jq -r '.release' "$HF_OWNER")" ]
  [ "$(jq -r '.worktree_root' "$ST")" = "$(jq -r '.worktree_root' "$HF_OWNER")" ]
  # ok: doctor reports it and pre-push passes on the verdict alone.
  run_portable_doctor_fix
  [[ "$output" == *"✓ attachment checks: ok"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"running them now"* ]] || { echo "$output"; false; }
  # Stale: another attachment ID or owner digest. T14 amended: pre-push runs
  # the full checks job and gates on the verdict it records.
  write_status ok "00000000-0000-4000-8000-000000000000"
  run_portable_doctor_fix
  [[ "$output" == *"attachment checks: stale"*"trellis doctor --fix"* ]] || { echo "$output"; false; }
  write_status ok "" "$(printf '0%.0s' $(seq 64))"
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks are stale for "*"running them now"* ]] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  # Long-pending warns in doctor; a pending verdict whose job is gone runs the
  # full job at pre-push on a healthy attachment.
  write_status pending "" "" "$(( $(date +%s) - 7200 ))"
  run_portable_doctor_fix
  [[ "$output" == *"⚠ attachment checks: pending for "*"trellis doctor --fix"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"running them now"* ]] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
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
  # Missing: doctor says so; pre-push runs the full job and records its verdict.
  rm "$ST"
  run_portable_doctor_fix
  [[ "$output" == *"attachment checks: not recorded"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  [[ "$output" == *"attachment checks are missing for "*"running them now"* ]] || { echo "$output"; false; }
  # Pending with no live job and a broken owned artifact: the full job runs,
  # records the failure, and the push is refused on that verdict.
  write_status pending
  leaf="$(jq -r '[.artifacts[] | select(.kind == "symlink" and .path != ".trellis/runtime")][0].path' "$HF_OWNER")"
  [ -n "$leaf" ] && [ "$leaf" != null ]
  rm "$PORTABLE_PROJECT/$leaf"
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"running them now"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks FAILED at owner-artifacts"* ]] || { echo "$output"; false; }
  [ "$(state_of)" = failed ]
}

@test "direct attach does not silently succeed without attaching when preload marker is inherited" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG TRELLIS_LIBS_PRELOADED=1 TRELLIS_ATTACH_POSTJOB=off \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    /bin/bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 --harness claude --harness codex "$PORTABLE_PROJECT" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  owner="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  [ -f "$owner" ] || { echo "attach returned success without an owner: $output"; false; }
  [ -L "$PORTABLE_PROJECT/.trellis/runtime" ] || { echo "attach returned success without a runtime: $output"; false; }
}

@test "both Stop twins clear a preload marker before executing an older gate" {
  postjob_attach
  legacy="$SANDBOX/legacy-payload"
  mkdir -p "$legacy/scripts/lib"
  printf '%s\n' '#!/bin/bash' \
    '[ -z "${TRELLIS_LIBS_PRELOADED+x}" ] || { echo marker-leaked >&2; exit 1; }' \
    'exit 0' > "$legacy/scripts/lib/attach-postjob.sh"
  for surface in hooks codex/hooks; do
    mkdir -p "$legacy/core-rules/$surface/lib"
    cp "$REPO_ROOT/core-rules/$surface/lib/attach-verdict.sh" "$legacy/core-rules/$surface/lib/attach-verdict.sh"
    run env -u TRELLIS_CONFIG TRELLIS_LIBS_PRELOADED=1 HOME="$PORTABLE_ACCOUNT_HOME" \
      TRELLIS_HOME="$PORTABLE_HOME" bash -c '
        . "$1"; trellis_attach_verdict_stop "$2"' _ \
      "$legacy/core-rules/$surface/lib/attach-verdict.sh" "$PORTABLE_PROJECT" </dev/null
    [ "$status" -eq 0 ] || { echo "$surface: $output"; false; }
  done
}

@test "fresh postjob loads its libraries despite an inherited preload marker and still refuses render drift" {
  postjob_attach
  jq -e 'any(.renders[]; .path == ".claude/settings.local.json")' "$HF_OWNER" >/dev/null || false

  # A launcher bundle exports this marker, but its shell functions do not cross
  # exec. The standalone job must load its own libraries, not trust the marker.
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB TRELLIS_LIBS_PRELOADED=1 \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    /bin/bash "$JOB" run --sync --target "$PORTABLE_PROJECT" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(state_of)" = ok ] || { cat "$ST"; false; }
  [ "$(jq -r '.owner_sha256' "$ST")" = "$(sha_of "$HF_OWNER")" ] || false
  [ "$(jq -r '.checks[] | select(.name == "owner-artifacts") | .result' "$ST")" = ok ] || false

  # A sourced spawn also crosses into a fresh detached shell.
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB -u TRELLIS_LIBS_PRELOADED \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash -c '
      . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/release-store.sh"
      . "$1/scripts/lib/local-registry.sh"; . "$1/scripts/lib/attachment.sh"
      . "$1/scripts/lib/attach-postjob.sh"
      export TRELLIS_LIBS_PRELOADED=1
      trellis_attach_postjob_spawn "$2" "$3"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  tries=0
  while [ "$(state_of)" != ok ]; do
    case "$(state_of)" in failed|blocked-by-journal) cat "$ST" "${ST%.json}.log"; return 1 ;; esac
    tries=$((tries + 1))
    [ "$tries" -lt 1200 ] || { cat "$ST" "${ST%.json}.log"; return 1; }
    sleep 0.5
  done

  # An older target may not reset the flag at entry. Probe the spawn exec
  # itself with a legacy stand-in: its only job is to record the inherited env.
  old_release="$SANDBOX/old-release"
  mkdir -p "$old_release/payload/scripts/lib"
  printf '%s\n' '#!/bin/bash' \
    'printf "%s\\n" "${TRELLIS_LIBS_PRELOADED-unset}" > "$TEST_SPAWN_PROBE"' \
    > "$old_release/payload/scripts/lib/attach-postjob.sh"
  probe="$SANDBOX/legacy-spawn-env"
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB -u TRELLIS_LIBS_PRELOADED \
    TEST_SPAWN_PROBE="$probe" HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash -c '
      . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/release-store.sh"
      . "$1/scripts/lib/local-registry.sh"; . "$1/scripts/lib/attachment.sh"
      . "$1/scripts/lib/attach-postjob.sh"
      OLD_RELEASE_DIR="$4"
      release_store_locate() { printf "%s\\n" "$OLD_RELEASE_DIR"; }
      export TRELLIS_LIBS_PRELOADED=1
      trellis_attach_postjob_spawn "$2" "$3"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" "$old_release" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  tries=0
  while [ ! -f "$probe" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || { echo 'legacy postjob did not start'; return 1; }
    sleep 0.1
  done
  [ "$(<"$probe")" = unset ] || { echo "legacy postjob inherited: $(<"$probe")"; false; }

  # The environment fix must not weaken the same check on a changed render.
  render="$PORTABLE_PROJECT/.claude/settings.local.json"
  jq 'del(.hooks)' "$render" > "$SANDBOX/drifted-settings.json"
  cp "$SANDBOX/drifted-settings.json" "$render"
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB TRELLIS_LIBS_PRELOADED=1 \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    /bin/bash "$JOB" run --sync --target "$PORTABLE_PROJECT" </dev/null
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  jq -e '.state == "failed" and .failure.check == "owner-artifacts"' "$ST" >/dev/null || { cat "$ST"; false; }
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks FAILED at owner-artifacts"* ]] || { echo "$output"; false; }
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
  PORTABLE_CARRIER_SENTINEL="$SANDBOX/managed-carrier-ran"
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
  [ ! -e "$PORTABLE_CARRIER_SENTINEL" ] || { echo "carrier ran after mid-suite adoption"; false; }
  [ "$status" -eq 1 ] || { echo "adoption published mid-suite not refused, status $status: $output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks are blocked: a group release adoption is pending for this checkout; remedy: retry trellis release adopt with the same selector to recover"* ]] || { echo "$output"; false; }
  # Positive control: the same sealed carrier runs once adoption is clear.
  rmdir "$adoption"
  printf '#!/bin/sh\nexit 0\n' > "$PORTABLE_PROJECT/.husky/pre-push"
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -e "$PORTABLE_CARRIER_SENTINEL" ] || { echo "carrier witness did not run after adoption cleared"; false; }
}

@test "A4 attach spawns the detached job and returns before it finishes (T14 amended); own session, stdin /dev/null, no caller pipes" {
  TRELLIS_ATTACH_POSTJOB=off build_portable_doctor_fix_home
  install_portable_doctor_release
  ST_DIR="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  ST="$ST_DIR/$PORTABLE_WORKTREE_ID.json"
  HF_OWNER="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  # T14 amended (owner 2026-11-10): attach returns once attached, while its
  # checks job still runs (held 30 s here); the verdict gates Stop and push.
  local started=$SECONDS
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB ATTACH_POSTJOB_TEST_HOLD=30 \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash -c '"$1" attach --home "$2" --fleet personal --release 1.2.3 --harness claude --harness codex "$3" &&
      jq -r .state "$4"' _ "$REPO_ROOT/scripts/attach-project.sh" "$PORTABLE_HOME" "$PORTABLE_PROJECT" "$ST"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attached: "* ]] || { echo "$output"; false; }
  case "${lines[${#lines[@]}-1]}" in pending|running) ;; *) echo "attach waited for the checks: $output"; false ;; esac
  [ "$(jq -r '.attachment_id' "$ST")" = "$(jq -r '.attachment_id' "$HF_OWNER")" ]
  wait_for_state ok
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

# Spec 074 T14: attach success means final owner/harness readiness. A job that
# cannot start is a refusal, never a success line.
@test "T14 a failed postjob spawn refuses attach instead of reporting success" {
  TRELLIS_ATTACH_POSTJOB=off build_portable_doctor_fix_home
  install_portable_doctor_release
  local shim="$BATS_TEST_TMPDIR/shim" real_perl
  real_perl="$(command -v perl)"
  mkdir -p "$shim"
  # Only the detaching fork (perl -MPOSIX) fails; every other perl use passes.
  printf '#!/bin/sh\n[ "$1" = -MPOSIX ] && exit 1\nexec "%s" "$@"\n' "$real_perl" > "$shim/perl"
  chmod +x "$shim/perl"
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB PATH="$shim:$PATH" TRELLIS_ATTACH_READY_SECONDS=600 \
    HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" --fleet personal --release 1.2.3 \
      --harness claude --harness codex "$PORTABLE_PROJECT" </dev/null
  [ "$status" -eq 5 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"the attachment checks could not start for"*"so it is not ready"* ]] || { echo "$output"; false; }
  [[ "$output" != *"attached: "* ]] || { echo "$output"; false; }
}

@test "T14 the readiness wait passes only on ok; failed, blocked, pending or stale at the bound, and no spawn refuse" {
  postjob_attach
  await_ready() {
    run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB TRELLIS_ATTACH_READY_SECONDS="${2:-5}" \
      HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash -c '
        . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/release-store.sh"
        . "$1/scripts/lib/local-registry.sh"
        . "$1/scripts/lib/attachment.sh"; . "$1/scripts/lib/attach-postjob.sh"
        if [ "$6" = spawned ]; then
          _ATTACH_POSTJOB_SPAWNED="$3" _ATTACH_POSTJOB_SPAWNED_CHECKOUT="$4"
          _ATTACH_POSTJOB_SPAWNED_WORKTREE="$5" _ATTACH_POSTJOB_SPAWNED_OWNER="$7"
        fi
        trellis_attach_postjob_await "$2" "$3"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" \
      "$PORTABLE_CHECKOUT_ID" "$PORTABLE_WORKTREE_ID" "$1" "$HF_OWNER" </dev/null
  }
  write_status ok
  await_ready spawned
  [ "$status" -eq 0 ] || { echo "ok: status $status: $output"; false; }
  write_status failed "" "" "" '{"check":"exclude","code":3,"remedy":"restore the recorded block"}'
  await_ready spawned
  [ "$status" -eq 4 ] || { echo "failed: status $status: $output"; false; }
  [[ "$output" == *"FAILED at exclude"*"remedy: restore the recorded block"* ]] || { echo "$output"; false; }
  # A control-only toolchain only gates pushes; the attachment itself is ready.
  write_status failed "" "" "" '{"check":"toolchain","code":3,"remedy":"refresh the toolchain"}'
  await_ready spawned
  [ "$status" -eq 0 ] || { echo "toolchain: status $status: $output"; false; }
  write_status blocked-by-journal "" "" "" '{"check":"journal","code":3,"remedy":"remedy: trellis recover X"}'
  await_ready spawned
  [ "$status" -eq 3 ] || { echo "blocked: status $status: $output"; false; }
  [[ "$output" == *"blocked for"*"trellis recover X"* ]] || { echo "$output"; false; }
  write_status pending
  local started=$SECONDS
  await_ready spawned 1
  [ "$status" -eq 5 ] || { echo "pending: status $status: $output"; false; }
  [[ "$output" == *"still pending"*"kept but not ready"* ]] || { echo "$output"; false; }
  [ $((SECONDS - started)) -lt 15 ] || { echo "the wait was not bounded"; false; }
  # ok for another owner state is stale, never ready.
  write_status ok "" 0000000000000000000000000000000000000000000000000000000000000000
  await_ready spawned 1
  [ "$status" -eq 5 ] || { echo "stale: status $status: $output"; false; }
  [[ "$output" == *"still stale"* ]] || { echo "$output"; false; }
  write_status ok
  await_ready none
  [ "$status" -eq 5 ] || { echo "no spawn: status $status: $output"; false; }
  [[ "$output" == *"no attachment checks were started"* ]] || { echo "$output"; false; }
}

# Spec 074 T14, amended 2026-11-10 (owner): the verdict gates the next Stop
# (both shell twins share attach-verdict.sh; the native member delegates the
# same gate) and the next push. Never a warning; every refusal is labelled.
@test "T14 amended a failed verdict blocks Stop and push; a toolchain failure blocks only push" {
  postjob_attach
  write_status failed "" "" "" '{"check":"exclude","code":3,"remedy":"restore the recorded exclude block"}'
  run_stop_gate
  [ "$status" -eq 1 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"trellis Stop: attachment checks FAILED at exclude for "*"restore the recorded exclude block"* ]] || { echo "$output"; false; }
  # The real Claude wrapper blocks with its labelled step.
  run bash -c 'cd "$1" && printf "%s" "{\"session_id\":\"t14\",\"stop_hook_active\":false}" |
    env -u TRELLIS_CONFIG HOME="$2" TRELLIS_HOME="$3" CLAUDE_PROJECT_DIR="$1" bash "$4/core-rules/hooks/stop-verify.sh"' \
    _ "$PORTABLE_PROJECT" "$PORTABLE_ACCOUNT_HOME" "$PORTABLE_HOME" "$REPO_ROOT" </dev/null
  [[ "$output" == *'"decision":"block"'*"attachment-checks: trellis Stop: attachment checks FAILED at exclude"* ]] || { echo "status $status: $output"; false; }
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks FAILED at exclude"* ]] || { echo "$output"; false; }
  write_status failed "" "" "" '{"check":"toolchain","code":3,"remedy":"refresh the toolchain"}'
  run_stop_gate
  [ "$status" -eq 0 ] || { echo "toolchain blocked Stop: $output"; false; }
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"attachment checks FAILED at toolchain"* ]] || { echo "$output"; false; }
}

@test "T14 amended a pending verdict blocks Stop and push at the bound, then passes once the job records ok" {
  postjob_attach
  # A live job, held 20 s before it starts checking.
  run env -u TRELLIS_CONFIG -u TRELLIS_ATTACH_POSTJOB ATTACH_POSTJOB_TEST_HOLD=20 HOME="$PORTABLE_ACCOUNT_HOME" \
    TRELLIS_HOME="$PORTABLE_HOME" bash -c '
      . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/release-store.sh"
      . "$1/scripts/lib/local-registry.sh"
      . "$1/scripts/lib/attachment.sh"; . "$1/scripts/lib/attach-postjob.sh"
      trellis_attach_postjob_spawn "$2" "$3"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local tries=0
  until [ -f "$ST_DIR/$PORTABLE_WORKTREE_ID.job/pid" ] || [ "$tries" -ge 120 ]; do sleep 0.25; tries=$((tries + 1)); done
  run_stop_gate 1
  [ "$status" -eq 1 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"trellis Stop: attachment checks are still "*" after 1 s"* ]] || { echo "$output"; false; }
  run env -u TRELLIS_CONFIG TRELLIS_ATTACH_GATE_WAIT_SECONDS=1 HOME="$PORTABLE_ACCOUNT_HOME" \
    TRELLIS_HOME="$PORTABLE_HOME" bash "$JOB" gate --for push --target "$PORTABLE_PROJECT" </dev/null
  [ "$status" -eq 1 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks are still "*" after 1 s"* ]] || { echo "$output"; false; }
  wait_for_state ok
  run_stop_gate 1
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T14 amended a verdict for another release or worktree is never accepted" {
  postjob_attach
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$(state_of)" = ok ] || { echo "$output"; cat "$ST"; false; }
  classify() {
    run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash -c '
      . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/attachment.sh"; . "$1/scripts/lib/attach-postjob.sh"
      attach_status_classify "$2" "$3" "$4" "$5"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$HF_OWNER" \
      "$PORTABLE_CHECKOUT_ID" "$PORTABLE_WORKTREE_ID" </dev/null
  }
  classify
  [ "${output%%$'\t'*}" = ok ] || { echo "$output"; false; }
  # Break the attachment so a rerun of the checks fails: an ok verdict that is
  # not this worktree's own must not let it through.
  local runtime="$PORTABLE_PROJECT/.trellis/runtime" target
  target="$(readlink "$runtime")"
  rm "$runtime"
  ln -s /nonexistent-runtime "$runtime"
  for foreign in release root schema; do
    case "$foreign" in
      release) write_status ok "" "" "" null 0.0.1 ;;
      root) write_status ok "" "" "" null "" "$SANDBOX/another-worktree" ;;
      schema) write_status ok; jq '.schema_version = 1 | del(.release, .worktree_root)' "$ST" > "$ST.next" && mv "$ST.next" "$ST" && chmod 600 "$ST" ;;
    esac
    classify
    [ "${output%%$'\t'*}" = stale ] || { echo "$foreign: $output"; false; }
    run_stop_gate 5
    [ "$status" -eq 1 ] || { echo "$foreign accepted at Stop: $output"; false; }
    [[ "$output" == *"attachment checks are stale for "*"running them now"* ]] || { echo "$foreign: $output"; false; }
    [[ "$output" == *"FAILED at "* ]] || { echo "$foreign: $output"; false; }
    write_status ok "" "" "" null 0.0.1
    run_pre_push
    [ "$status" -ne 0 ] || { echo "$foreign accepted at push: $output"; false; }
  done
  rm "$runtime"
  ln -s "$target" "$runtime"
}

@test "T14 amended an owner record that is not a regular file refuses Stop and push instead of reading as no attachment" {
  postjob_attach
  run_job run --sync --target "$PORTABLE_PROJECT"
  [ "$(state_of)" = ok ] || { echo "$output"; cat "$ST"; false; }
  mv "$HF_OWNER" "$HF_OWNER.real"
  ln -s "$HF_OWNER.real" "$HF_OWNER"
  run_stop_gate 1
  [ "$status" -eq 1 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"trellis Stop: attachment checks: the owner record for "*"is not a regular file"* ]] || { echo "$output"; false; }
  run_pre_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis pre-push: attachment checks: the owner record for "*"is not a regular file"* ]] || { echo "$output"; false; }
  rm "$HF_OWNER"
  mv "$HF_OWNER.real" "$HF_OWNER"
}
