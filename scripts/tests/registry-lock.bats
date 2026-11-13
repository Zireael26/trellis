#!/usr/bin/env bats
# Registry contention is transient; unsafe state is never retried or reclaimed.
REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
HOME_LIB="$REPO_ROOT/scripts/lib/trellis-home.sh"
ATTACHMENT_LIB="$REPO_ROOT/scripts/lib/attachment.sh"
POSTJOB_LIB="$REPO_ROOT/scripts/lib/attach-postjob.sh"

setup() {
  HOME_FIX="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME_FIX/locks"
}

@test "attachment registry lock helper uses a bounded 300-second budget and preserves zero probes" {
  run bash -c '
    . "$1"
    trellis_home_lock_acquire() { printf "%s %s %s\n" "$1" "$2" "$3"; }
    trellis_home_registry_lock_acquire "$2"
    trellis_home_registry_lock_acquire "$2" 0
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME_FIX registry 300"$'\n'"$HOME_FIX registry 0" ]
}

@test "registry contention retries with capped backoff and times out as unavailable, retaining the holder" {
  run bash -c '
    . "$1"
    mkdir "$2/locks/registry.lock"
    printf "%s\n" "$$" > "$2/locks/registry.lock/pid"
    sleep() { printf "backoff=%s\n" "$1"; }
    trellis_home_lock_acquire "$2" registry 7
    rc=$?
    [ "$(trellis_home_lock_read_pid "$2/locks/registry.lock/pid")" = "$$" ] || exit 99
    exit "$rc"
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 5 ]
  [[ "$output" == *$'backoff=1\nbackoff=2\nbackoff=4\n'* ]] || false
  [[ "$output" == *'timed out waiting for registry lock'*'held by pid'* ]] || false
  [ -d "$HOME_FIX/locks/registry.lock" ]
}

@test "registry retry succeeds after contention clears without replacing the live holder" {
  run bash -c '
    . "$1"
    mkdir "$2/locks/registry.lock"
    printf "%s\n" "$$" > "$2/locks/registry.lock/pid"
    home="$2"; calls=0
    sleep() {
      printf "backoff=%s\n" "$1"
      calls=$((calls + 1))
      if [ "$calls" -eq 2 ]; then
        (cd "$home/locks/registry.lock" && rm ./pid) && rmdir "$home/locks/registry.lock"
      fi
    }
    trellis_home_lock_acquire "$home" registry 7 || exit "$?"
    trellis_home_lock_release
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ]
  [ "$output" = $'backoff=1\nbackoff=2' ]
  [ ! -e "$HOME_FIX/locks/registry.lock" ]
}

@test "registry backoff is capped by the remaining timeout budget" {
  run bash -c '
    . "$1"
    mkdir "$2/locks/registry.lock"
    printf "%s\n" "$$" > "$2/locks/registry.lock/pid"
    sleep() { printf "backoff=%s\n" "$1"; }
    trellis_home_lock_acquire "$2" registry 5
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 5 ]
  [[ "$output" == *$'backoff=1\nbackoff=2\nbackoff=2\n'* ]] || false
}

@test "registry backoff never exceeds eight seconds" {
  run bash -c '
    . "$1"
    mkdir "$2/locks/registry.lock"
    printf "%s\n" "$$" > "$2/locks/registry.lock/pid"
    sleep() { printf "backoff=%s\n" "$1"; }
    trellis_home_lock_acquire "$2" registry 24
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 5 ]
  [[ "$output" == *$'backoff=1\nbackoff=2\nbackoff=4\nbackoff=8\nbackoff=8\nbackoff=1\n'* ]] || false
}

@test "real registry attach and clear writers wait through contention before publishing" {
  run env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c '
    . "$1/scripts/lib/local-registry.sh"
    home="$2"; root="$2/project"; calls=0
    mkdir "$root"
    git -C "$root" -c core.hooksPath=/dev/null init -q -b main || exit "$?"
    printf "{\"schema_version\":1,\"project_id\":\"fixture\"}\n" > "$root/.trellis.json"
    seed_lock() {
      mkdir "$home/locks/registry.lock" && printf "%s\n" "$$" > "$home/locks/registry.lock/pid"
    }
    sleep() {
      printf "%s\n" "$1" >> "$home/backoffs"
      calls=$((calls + 1))
      if [ "$calls" -eq 2 ]; then
        (cd "$home/locks/registry.lock" && rm ./pid) && rmdir "$home/locks/registry.lock"
      fi
    }
    id=11111111-2222-3333-4444-555555555555
    seed_lock || exit "$?"
    identity="$(local_registry_register_worktree "$home" personal fixture "$root" 1.3.16 "[\"claude\"]" "$id" "{}")" || exit "$?"
    checkout="$(printf "%s\n" "$identity" | jq -r .checkout_id)"
    worktree="$(printf "%s\n" "$identity" | jq -r .worktree_id)"
    jq -e --arg c "$checkout" --arg w "$worktree" --arg id "$id" ".projects[\"personal/fixture\"].checkouts[\$c].worktrees[\$w].attachment_id == \$id" "$home/registry.json" || exit "$?"
    calls=0; seed_lock || exit "$?"
    local_registry_clear_attachment "$home" personal fixture "$checkout" "$worktree" "$id" || exit "$?"
    jq -e --arg c "$checkout" --arg w "$worktree" ".projects[\"personal/fixture\"].checkouts[\$c].worktrees[\$w] | has(\"attachment_id\") | not" "$home/registry.json" || exit "$?"
    [ "$(< "$home/backoffs")" = "$(printf "1\n2\n1\n2")" ]
  ' _ "$REPO_ROOT" "$HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$HOME_FIX/locks/registry.lock" ]
}

@test "initializing registry lock timeout is unavailable and never reclaimed" {
  mkdir "$HOME_FIX/locks/registry.lock"
  run bash -c '. "$1"; trellis_home_lock_acquire "$2" registry 0' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 5 ]
  [[ "$output" == *'still initializing'* ]] || false
  [ -d "$HOME_FIX/locks/registry.lock" ]
  [ ! -e "$HOME_FIX/locks/registry.lock/pid" ]
}

@test "unsafe registry locks still refuse immediately as corrupt state without retry" {
  mkdir "$HOME_FIX/locks/registry.lock"
  printf 'not-a-pid\n' > "$HOME_FIX/locks/registry.lock/pid"
  run bash -c '
    . "$1"
    sleep() { printf "UNEXPECTED RETRY\n"; }
    trellis_home_lock_acquire "$2" registry 7
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 4 ]
  [[ "$output" != *'UNEXPECTED RETRY'* ]] || false
  [ "$(< "$HOME_FIX/locks/registry.lock/pid")" = not-a-pid ]
  (cd "$HOME_FIX/locks/registry.lock" && rm ./pid)
  rmdir "$HOME_FIX/locks/registry.lock"
  mkdir "$HOME_FIX/outside"
  ln -s "$HOME_FIX/outside" "$HOME_FIX/locks/registry.lock"
  run bash -c '. "$1"; trellis_home_lock_acquire "$2" registry 7' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 4 ]
  [ -L "$HOME_FIX/locks/registry.lock" ]
  [ -z "$(find "$HOME_FIX/outside" -mindepth 1 -print)" ]
}

@test "registry stale-holder churn cannot bypass the elapsed deadline" {
  run bash -c '
    . "$1"
    mkdir "$2/locks/registry.lock"
    printf "999999999\n" > "$2/locks/registry.lock/pid"
    calls=0
    trellis_home_lock_try_recover_stale() {
      calls=$((calls + 1)); SECONDS=$((SECONDS + 5))
      [ "$calls" -le 2 ] || return 4
      return 0
    }
    trellis_home_lock_acquire "$2" registry 3
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 5 ]
  [[ "$output" == *'timed out waiting for registry lock'*'kept changing'* ]] || false
}

@test "an indeterminate liveness probe never reclaims a live or unknown holder" {
  run bash -c '
    . "$1"
    lock="$2/locks/registry.lock"
    mkdir "$lock" || exit
    printf "%s\n" "$$" > "$lock/pid"
    # Model a shell that cannot signal or run ps; the isolated Python probe
    # can still prove this process exists.
    kill() { return 1; }
    ps() { return 1; }
    trellis_home_lock_try_recover_stale "$lock" registry && exit 10
    [ "$(< "$lock/pid")" = "$$" ] || exit 11
    # A failed verifier is indeterminate, never proof of death.
    python3() { return 42; }
    trellis_home_lock_try_recover_stale "$lock" registry && exit 12
    [ "$(< "$lock/pid")" = "$$" ]
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an actual EPERM from the isolated probe retains the lock holder" {
  # PID 1 is normally alive but owned by another user. Skip only when this
  # environment can signal it or cannot establish the EPERM precondition.
  run python3 -I -c '
import errno, os, sys
try:
    os.kill(1, 0)
except OSError as error:
    sys.exit(0 if error.errno == errno.EPERM else 1)
sys.exit(1)
'
  [ "$status" -eq 0 ] || skip 'no live unsignalable PID 1'
  run bash -c '
    . "$1"
    lock="$2/locks/registry.lock"
    mkdir "$lock" || exit
    printf "1\n" > "$lock/pid"
    kill() { return 1; }
    ps() { return 1; }
    trellis_home_lock_try_recover_stale "$lock" registry && exit 10
    [ "$(< "$lock/pid")" = 1 ]
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "unavailable liveness verification explains why a lock is retained" {
  local empty="$BATS_TEST_TMPDIR/no-python"
  mkdir "$empty"
  run env PATH="$empty" TRELLIS_LIBS_PRELOADED=1 /bin/bash -c '
    . "$1"
    kill() { return 1; }
    ps() { return 1; }
    trellis_home_pid_is_live 999999999 || exit 10
    python3() { return 42; }
    trellis_home_pid_is_live 999999999 || exit 11
  ' _ "$HOME_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'python3 is unavailable'*'liveness probe failed'* ]] || { echo "$output"; false; }
}

@test "registry lock still recovers one validated dead holder with a zero budget" {
  mkdir "$HOME_FIX/locks/registry.lock"
  printf '999999999\n' > "$HOME_FIX/locks/registry.lock/pid"
  run bash -c '
    . "$1"
    trellis_home_lock_acquire "$2" registry 0 || exit "$?"
    trellis_home_lock_release
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *'recovered stale registry lock'* ]] || false
  [ ! -e "$HOME_FIX/locks/registry.lock" ]
}

@test "a registry writer timeout leaves the existing registry bytes untouched" {
  run env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c '
    . "$1/scripts/lib/local-registry.sh"
    home="$2"; root="$2/project"
    mkdir "$root"
    git -C "$root" -c core.hooksPath=/dev/null init -q -b main || exit "$?"
    printf "{\"schema_version\":1,\"project_id\":\"fixture\"}\n" > "$root/.trellis.json"
    local_registry_register_worktree "$home" personal fixture "$root" "" "[]" "" "{}" >/dev/null || exit "$?"
    cp "$home/registry.json" "$home/registry.before"
    mkdir "$home/locks/registry.lock" && printf "%s\n" "$$" > "$home/locks/registry.lock/pid"
    trellis_home_registry_lock_acquire() { trellis_home_lock_acquire "$1" registry 0; }
    local_registry_register_worktree "$home" personal fixture "$root" 1.3.16 "[\"claude\"]" 11111111-2222-3333-4444-555555555555 "{}" >/dev/null
    rc=$?
    cmp -s "$home/registry.before" "$home/registry.json" || exit 99
    exit "$rc"
  ' _ "$REPO_ROOT" "$HOME_FIX"
  [ "$status" -eq 5 ] || { echo "$output"; return 1; }
  [[ "$output" == *'timed out waiting for registry lock'* ]] || false
}

@test "non-registry lock timeout retains its existing state classification" {
  mkdir "$HOME_FIX/locks/config.lock"
  printf '%s\n' "$$" > "$HOME_FIX/locks/config.lock/pid"
  run bash -c '. "$1"; trellis_home_lock_acquire "$2" config 0' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 4 ]
  [[ "$output" == *'timed out waiting for config lock'* ]] || false
}

# Exercise the real postjob control flow with deterministic verification and
# registry results. No detached process or live attachment fixture is needed.
postjob_registry_result() {
  bash -c '
    . "$1"; . "$2"
    _APJ_HOME="$3"; _APJ_OWNER="$3/owner.json"
    _APJ_ROOT="$3"; _APJ_COMMON="$3"; _APJ_CHECKOUT=c; _APJ_WORKTREE=w; _APJ_IDENTITY="{}"
    printf "{\"attachment_id\":\"fixture\"}\n" > "$_APJ_OWNER"
    _attachment_hash() { printf hash; }
    _attachment_fs_identity() { printf 1:2; }
    attach_postjob_journal_pending() { return 1; }
    hc_hooks_path_fix_needed() { :; }
    attach_postjob_verify() { printf "pass\trelease\npass\towner-artifacts\npass\texclude\npass\ttoolchain\n"; }
    _attach_postjob_checkout_lock() { return 0; }
    _attach_postjob_locked_recheck() { return 0; }
    _attachment_checkout_lock_release() { printf 'released\n' > "$_APJ_HOME/released"; }
    _attach_postjob_registry_consistent() { return 1; }
    reconcile_rc="$4"
    attach_reconcile_owner_registry() { return "$reconcile_rc"; }
    _attach_postjob_status() { printf "status=%s\n" "$1"; }
    _attach_postjob_fail() { printf "failed=%s code=%s\n" "$1" "$2"; }
    _attach_postjob_once
  ' _ "$HOME_LIB" "$POSTJOB_LIB" "$HOME_FIX" "$1"
}

@test "postjob keeps unavailable registry reconciliation pending for retry" {
  run postjob_registry_result 5
  [ "$status" -eq 5 ]
  [[ "$output" == *'status=pending'* ]] || false
  [[ "$output" != *'failed=registry'* ]] || false
  [ -f "$HOME_FIX/released" ]
}

@test "postjob preserves the actual corrupt-registry failure code instead of negation status zero" {
  run postjob_registry_result 4
  [ "$status" -eq 1 ]
  [[ "$output" == *'failed=registry code=4'* ]] || false
  [ -f "$HOME_FIX/released" ]
}

@test "post-checkout retains registry timeout details without claiming unsafe worktree" {
  run bash -c '
    . "$1"; . "$2"
    _attachment_hooks_dispatcher_common_body() {
      printf "%s\n" \
        "project_root=/unused; managed_dir=/unused" \
        "trellis_enter_command_scratch() { :; }" \
        "git() { return 1; }" \
        "trellis_read_sidecar() { case \"\$1\" in */release-payload) printf payload;; esac; }" \
        "trellis_prior_hook() { return 1; }" \
        "trellis_managed_payload_file() { printf reconcile; }" \
        "trellis_run_control_payload() { printf \"trellis: timed out waiting for registry lock at fixture (held by pid 123)\\n\" >&2; return 5; }"
    }
    _attachment_hooks_post_checkout_dispatcher_body_in_process > "$3/dispatcher"
    bash "$3/dispatcher" old new 1
  ' _ "$HOME_LIB" "$ATTACHMENT_LIB" "$HOME_FIX"
  [ "$status" -eq 5 ]
  [[ "$output" == *'attachment reconciliation failed'* ]] || false
  [[ "$output" == *'timed out waiting for registry lock'* ]] || false
  [[ "$output" != *'unsafe worktree'* ]] || false
}

@test "stale-lock recovery never deletes a pid record it no longer owns" {
  run bash -c '
    . "$1"
    home="$2"
    lock="$home/locks/registry.lock"
    mkdir -p "$lock"
    printf "999999\n" > "$lock/pid"
    replaced=0
    trellis_home_pid_is_live() {
      if [ "$replaced" -eq 0 ]; then
        replaced=1
        printf "%s\n" "$$" > "$lock/pid"
        return 1
      fi
      return 1
    }
    trellis_home_lock_try_recover_stale "$lock" registry
    rc=$?
    [ "$rc" -ne 0 ] || exit 10
    [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] || exit 11
    exit 0
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a losing stale-lock recoverer retries when the pid record already moved" {
  run bash -c '
    . "$1"
    home="$2"
    lock="$home/locks/registry.lock"
    mkdir -p "$lock"
    printf "999999\n" > "$lock/pid"
    trellis_home_lock_has_only_pid() { command rm -f "$lock/pid"; return 0; }
    trellis_home_lock_try_recover_stale "$lock" registry
    [ "$?" -eq 1 ] || exit 10
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an unreadable moved pid record is restored instead of deleted" {
  run bash -c '
    . "$1"
    home="$2"
    lock="$home/locks/registry.lock"
    mkdir -p "$lock"
    printf "999999\n" > "$lock/pid"
    trellis_home_lock_read_pid() {
      case "$1" in
        *.recovery.*) return 1 ;;
        *) printf "999999\n"; return 0 ;;
      esac
    }
    trellis_home_lock_try_recover_stale "$lock" registry
    rc=$?
    [ "$rc" -eq 1 ] || exit 10
    [ "$(cat "$lock/pid" 2>/dev/null)" = "999999" ] || exit 11
  ' _ "$HOME_LIB" "$HOME_FIX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
