#!/bin/bash
# Test the real home-lock helper with isolated lock directories and a TERM
# injected at the shell command boundaries; no production fault switch.
set -u
case_name=$1
root=$2
TEST_ROOT=$3
# shellcheck disable=SC1090
. "$root/scripts/lib/trellis-home.sh"
home="$TEST_ROOT/home"
name=config
case "$case_name" in
  registry-*) name=registry; case_name=${case_name#registry-} ;;
  scheduled-*) name=scheduled-tasks; case_name=${case_name#scheduled-} ;;
esac
lock="$home/locks/$name.lock"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
signal_this_shell() { /bin/sh -c 'kill -TERM "$PPID"'; }
make_lock() { mkdir -p "$home/locks"; mkdir -m 700 "$lock" || exit 1; }
old() { touch -t 200001010000 "$@"; }
acquire_and_release() {
  trellis_home_lock_acquire "$home" "$name" 0 || return "$?"
  trellis_home_lock_release
}
wait_for_file() {
  local marker="$1" pid="${2:-}" n=0
  while [ ! -e "$marker" ]; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    n=$((n + 1)); [ "$n" -lt 200 ] || return 1
    sleep 0.1
  done
  return 0
}
barrier_kill() {
  local pid
  for pid in "$@"; do kill "$pid" 2>/dev/null || true; done
  for pid in "$@"; do wait "$pid" 2>/dev/null || true; done
}

case "$case_name" in
  worker-*)
    phase=${case_name#worker-}
    trap 'exit 143' TERM
    mkdir() {
      local target='' result
      [ "$#" -ne 3 ] || target=$3
      if [ "$target" = "$lock" ] && [ "$phase" = before-mkdir ]; then signal_this_shell; fi
      /bin/mkdir "$@"; result=$?
      if [ "$target" = "$lock" ] && [ "$result" -eq 0 ] && [ "$phase" = after-mkdir ]; then signal_this_shell; fi
      return "$result"
    }
    printf() {
      local result
      builtin printf "$@"; result=$?
      if [ "$phase" = after-pid ] && [ "$#" -eq 2 ] && [ "$1" = '%s\n' ] && [ "$2" = "$$" ]; then
        signal_this_shell
      fi
      return "$result"
    }
    chmod() {
      local result
      /bin/chmod "$@"; result=$?
      if [ "$phase" = after-chmod ] && [ "${2:-}" = "$lock/pid" ] && [ "$result" -eq 0 ]; then signal_this_shell; fi
      return "$result"
    }
    trellis_home_lock_acquire "$home" config 0 || exit "$?"
    if [ "$phase" = after-acquire ]; then signal_this_shell; fi
    exit 99
    ;;
  term-*)
    phase=${case_name#term-}
    mkdir -p "$home/locks"
    "$BASH" --noprofile --norc "$root/scripts/tests/helpers/home-lock-ownerless-driver.sh" \
      "worker-$phase" "$root" "$TEST_ROOT" > "$TEST_ROOT/worker.out" 2>&1; rc=$?
    [ "$rc" -eq 143 ] || fail "TERM at $phase returned $rc"
    if [ -d "$lock" ] && [ ! -L "$lock" ] && { [ ! -e "$lock/pid" ] || [ ! -s "$lock/pid" ]; }; then
      # The threshold is ten minutes, not a dead-owner inference. Backdate
      # only the test-owned lock left by this exact interrupted attempt.
      old "$lock"
      [ ! -e "$lock/pid" ] || old "$lock/pid"
    fi
    acquire_and_release || fail "lock remained unavailable after interrupted $phase"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "lock persisted after $phase retry"
    ;;
  age-boundary)
    if trellis_home_lock_age_over 1600 1000; then fail 'exactly ten minutes was treated as older'; fi
    trellis_home_lock_age_over 1601 1000 || fail 'more than ten minutes was not stale'
    if trellis_home_lock_age_over 999 1000; then fail 'future timestamp was treated as stale'; fi
    if trellis_home_lock_age_over invalid 1000; then fail 'invalid timestamp was treated as stale'; fi
    ;;
  young-missing|young-empty|old-missing|old-empty|old-blank-lines|old-dir-young-pid)
    make_lock
    case "$case_name" in *empty|old-dir-young-pid) : > "$lock/pid" ;; old-blank-lines) printf '\n\n' > "$lock/pid" ;; esac
    case "$case_name" in
      old-missing) old "$lock" ;;
      old-empty|old-blank-lines) old "$lock/pid" "$lock" ;;
      old-dir-young-pid) old "$lock" ;;
    esac
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    case "$case_name" in
      old-missing|old-empty|old-blank-lines)
        [ "$rc" -eq 0 ] || fail "$case_name did not recover: $rc"
        [ ! -e "$lock" ] || fail "$case_name lock remained after release"
        ;;
      *)
        expected="$TRELLIS_EX_STATE"
        [ "$name" != registry ] || expected="$TRELLIS_EX_UNAVAILABLE"
        [ "$rc" -eq "$expected" ] || fail "$case_name was not respected: $rc"
        [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
        ;;
    esac
    ;;
  fresh-no-python|old-no-python)
    mkdir -p "$home/locks" "$TEST_ROOT/bin"
    printf '#!/bin/sh\nprintf used > "%s"\nexit 88\n' "$TEST_ROOT/python-was-run" > "$TEST_ROOT/bin/python3"
    chmod 700 "$TEST_ROOT/bin/python3"
    if [ "$case_name" = old-no-python ]; then mkdir -m 700 "$lock"; old "$lock"; fi
    PATH="$TEST_ROOT/bin:$PATH"; export PATH
    acquire_and_release > "$TEST_ROOT/output" 2>&1 || fail "$case_name did not acquire without Python"
    [ ! -e "$TEST_ROOT/python-was-run" ] || fail 'lock path invoked Python'
    [ ! -e "$lock" ] || fail 'lock remained after release'
    ;;
  live-pid|dead-pid)
    make_lock
    holder=''
    if [ "$case_name" = live-pid ]; then
      /bin/sleep 60 & holder=$!
      printf '%s\n' "$holder" > "$lock/pid"
    else
      printf '%s\n' 99999999 > "$lock/pid"
    fi
    old "$lock" "$lock/pid"
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    retained=false; alive=false
    if [ "$case_name" = live-pid ]; then
      [ -f "$lock/pid" ] && [ "$(<"$lock/pid")" = "$holder" ] && retained=true
      kill -0 "$holder" 2>/dev/null && alive=true
      kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
      [ "$rc" -eq "$TRELLIS_EX_STATE" ] && [ "$retained" = true ] && [ "$alive" = true ] || fail 'live numeric holder changed'
    else
      [ "$rc" -eq 0 ] && [ ! -e "$lock" ] || fail 'dead numeric holder was not recovered'
    fi
    ;;
  unknown-entry|unknown-entry-with-pid|symlink-pid|hardlinked-empty-pid|unsafe-mode|binary-pid)
    make_lock
    case "$case_name" in
      unknown-entry|unknown-entry-with-pid)
        printf '%s\n' keep > "$lock/foreign"; old "$lock/foreign"
        if [ "$case_name" = unknown-entry-with-pid ]; then : > "$lock/pid"; old "$lock/pid"; fi
        rmdir() { : > "$TEST_ROOT/rmdir-attempted"; /bin/rmdir "$@"; }
        ;;
      symlink-pid) : > "$TEST_ROOT/sentinel"; ln -s "$TEST_ROOT/sentinel" "$lock/pid" ;;
      hardlinked-empty-pid) : > "$TEST_ROOT/sentinel"; ln "$TEST_ROOT/sentinel" "$lock/pid"; old "$lock/pid" ;;
      unsafe-mode) chmod 777 "$lock" ;;
      binary-pid) printf '\0' > "$lock/pid"; old "$lock/pid" ;;
    esac
    old "$lock"
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
    case "$case_name" in
      unknown-entry|unknown-entry-with-pid)
        [ "$(<"$lock/foreign")" = keep ] || fail 'unknown file changed'
        if [ "$case_name" = unknown-entry-with-pid ]; then [ -f "$lock/pid" ] || fail 'PID entry was removed'; fi
        [ ! -e "$TEST_ROOT/rmdir-attempted" ] || fail 'unknown directory reached removal'
        ;;
      symlink-pid) [ -L "$lock/pid" ] && [ -f "$TEST_ROOT/sentinel" ] || fail 'symlink target changed' ;;
      hardlinked-empty-pid) [ -f "$lock/pid" ] && [ -f "$TEST_ROOT/sentinel" ] || fail 'hardlinked PID file was removed' ;;
      binary-pid) [ -s "$lock/pid" ] || fail 'binary PID record was removed' ;;
    esac
    ;;
  race-pid-write|race-pid-symlink|race-pid-null)
    make_lock
    : > "$lock/pid"; : > "$TEST_ROOT/sentinel"
    old "$lock/pid" "$lock"
    stat_body=$(declare -f trellis_home_lock_stat)
    stat_body=${stat_body/trellis_home_lock_stat/_fixture_real_lock_stat}
    eval "$stat_body"
    trellis_home_lock_stat() {
      if [ "$1" = "$lock/pid" ]; then
        _fixture_real_lock_stat "$1" || return "$?"
        if [ ! -e "$TEST_ROOT/first-pid-stat" ]; then
          : > "$TEST_ROOT/first-pid-stat"
        elif [ ! -e "$TEST_ROOT/race-fired" ]; then
          : > "$TEST_ROOT/race-fired"
          case "$case_name" in
            race-pid-write) printf '%s\n' 99999999 > "$lock/pid" ;;
            race-pid-null) printf '\0' > "$lock/pid" ;;
            race-pid-symlink) /bin/rm -f "${lock:?}/pid" && ln -s "$TEST_ROOT/sentinel" "$lock/pid" ;;
          esac
        fi
      else
        _fixture_real_lock_stat "$1"
      fi
    }
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -e "$TEST_ROOT/race-fired" ] || fail "$case_name did not reach identity recheck"
    [ -d "$lock" ] || fail "$case_name lock was removed"
    case "$case_name" in
      race-pid-write) [ "$(<"$lock/pid")" = 99999999 ] || fail 'new PID record was removed' ;;
      race-pid-null) [ -s "$lock/pid" ] || fail 'new binary PID record was removed' ;;
      race-pid-symlink) [ -L "$lock/pid" ] && [ -f "$TEST_ROOT/sentinel" ] || fail 'replacement symlink was removed' ;;
    esac
    ;;
  race-dir)
    make_lock
    old "$lock"
    stat_body=$(declare -f trellis_home_lock_stat)
    stat_body=${stat_body/trellis_home_lock_stat/_fixture_real_lock_stat}
    eval "$stat_body"
    trellis_home_lock_stat() {
      if [ "$1" = "$lock" ]; then
        _fixture_real_lock_stat "$1" || return "$?"
        if [ ! -e "$TEST_ROOT/race-fired" ]; then
          : > "$TEST_ROOT/race-fired"
          /bin/rmdir "${lock:?}" && /bin/mkdir -m 700 "${lock:?}" || return 1
          _fixture_real_lock_stat "$lock" > "$TEST_ROOT/new-dir-id" || return 1
        fi
      else
        _fixture_real_lock_stat "$1"
      fi
    }
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -e "$TEST_ROOT/race-fired" ] || fail "$case_name did not reach identity recheck"
    [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
    new_id="$(<"$TEST_ROOT/new-dir-id")"
    current_id="$(_fixture_real_lock_stat "$lock" 2>/dev/null || true)"
    [ -n "$new_id" ] && [ "$current_id" = "$new_id" ] || fail 'race-dir replacement directory changed'
    ( shopt -s dotglob nullglob; set -- "$lock"/*; [ "$#" -eq 0 ] ) || fail 'race-dir replacement directory gained an entry'
    ;;
  foreign-owner)
    make_lock
    old "$lock"
    stat_body=$(declare -f trellis_home_lock_stat)
    stat_body=${stat_body/trellis_home_lock_stat/_fixture_real_lock_stat}
    eval "$stat_body"
    fake_uid=$(( $(id -u 2>/dev/null || printf '0') + 9973 ))
    trellis_home_lock_stat() {
      if [ "$1" = "$lock" ]; then
        local real d i mode mtime c size links
        real="$(_fixture_real_lock_stat "$1")" || return "$?"
        IFS=: read -r d i _ mode mtime c size links <<< "$real"
        printf '%s:%s:%s:%s:%s:%s:%s:%s\n' "$d" "$i" "$fake_uid" "$mode" "$mtime" "$c" "$size" "$links"
      else
        _fixture_real_lock_stat "$1"
      fi
    }
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
    ;;
  old-residue|old-residue-multiple)
    make_lock
    printf '4194301\n' > "$lock/pid.recovery.4194302"
    chmod 600 "$lock/pid.recovery.4194302"
    if [ "$case_name" = old-residue-multiple ]; then
      printf '4194303\n' > "$lock/pid.recovery.4194304"
      chmod 600 "$lock/pid.recovery.4194304"
      old "$lock/pid.recovery.4194304"
    fi
    old "$lock/pid.recovery.4194302" "$lock"
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -eq 0 ] || fail "$case_name did not recover: $rc"
    [ ! -e "$lock" ] || fail "$case_name lock remained after release"
    ;;
  young-residue|old-dir-young-residue)
    make_lock
    printf '4194301\n' > "$lock/pid.recovery.4194302"
    chmod 600 "$lock/pid.recovery.4194302"
    if [ "$case_name" = old-dir-young-residue ]; then old "$lock"; fi
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -f "$lock/pid.recovery.4194302" ] && [ "$(<"$lock/pid.recovery.4194302")" = 4194301 ] || fail "$case_name residue was removed"
    [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
    ;;
  residue-unknown-entry)
    make_lock
    printf '4194301\n' > "$lock/pid.recovery.4194302"
    chmod 600 "$lock/pid.recovery.4194302"
    printf '%s\n' keep > "$lock/foreign"; old "$lock/foreign" "$lock/pid.recovery.4194302"
    rmdir() { : > "$TEST_ROOT/rmdir-attempted"; /bin/rmdir "$@"; }
    old "$lock"
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
    [ "$(<"$lock/foreign")" = keep ] || fail 'unknown file changed'
    [ -f "$lock/pid.recovery.4194302" ] && [ "$(<"$lock/pid.recovery.4194302")" = 4194301 ] || fail 'residue beside unknown entry was removed'
    [ ! -e "$TEST_ROOT/rmdir-attempted" ] || fail 'unknown directory reached removal'
    ;;
  residue-symlink|residue-hardlink|residue-binary|residue-badname)
    make_lock
    : > "$TEST_ROOT/sentinel"
    case "$case_name" in
      residue-symlink) ln -s "$TEST_ROOT/sentinel" "$lock/pid.recovery.4194302" ;;
      residue-hardlink) ln "$TEST_ROOT/sentinel" "$lock/pid.recovery.4194302"; old "$lock/pid.recovery.4194302" ;;
      residue-binary) printf '\0' > "$lock/pid.recovery.4194302"; chmod 600 "$lock/pid.recovery.4194302"; old "$lock/pid.recovery.4194302" ;;
      residue-badname) printf '4194301\n' > "$lock/pid.recovery.abc"; chmod 600 "$lock/pid.recovery.abc"; old "$lock/pid.recovery.abc" ;;
    esac
    old "$lock"
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -d "$lock" ] && [ ! -L "$lock" ] || fail "$case_name lock was removed"
    case "$case_name" in
      residue-symlink) [ -L "$lock/pid.recovery.4194302" ] && [ -f "$TEST_ROOT/sentinel" ] || fail 'symlink target changed' ;;
      residue-hardlink) [ -f "$lock/pid.recovery.4194302" ] && [ -f "$TEST_ROOT/sentinel" ] || fail 'hardlinked residue was removed' ;;
      residue-binary) [ -s "$lock/pid.recovery.4194302" ] || fail 'binary residue was removed' ;;
      residue-badname) [ -f "$lock/pid.recovery.abc" ] && [ "$(<"$lock/pid.recovery.abc")" = 4194301 ] || fail 'badname residue was removed' ;;
    esac
    ;;
  race-residue-swap)
    make_lock
    printf '4194301\n' > "$lock/pid.recovery.4194302"
    chmod 600 "$lock/pid.recovery.4194302"
    old "$lock/pid.recovery.4194302" "$lock"
    stat_body=$(declare -f trellis_home_lock_stat)
    stat_body=${stat_body/trellis_home_lock_stat/_fixture_real_lock_stat}
    eval "$stat_body"
    trellis_home_lock_stat() {
      if [ "$1" = "$lock/pid.recovery.4194302" ]; then
        if [ ! -e "$TEST_ROOT/first-residue-stat" ]; then
          : > "$TEST_ROOT/first-residue-stat"
          _fixture_real_lock_stat "$1"
        elif [ ! -e "$TEST_ROOT/race-fired" ]; then
          : > "$TEST_ROOT/race-fired"
          printf '99999999\n' > "$lock/pid.recovery.4194302"
          _fixture_real_lock_stat "$1"
        else
          _fixture_real_lock_stat "$1"
        fi
      else
        _fixture_real_lock_stat "$1"
      fi
    }
    if acquire_and_release > "$TEST_ROOT/output" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -ne 0 ] || fail "$case_name unexpectedly recovered"
    [ -e "$TEST_ROOT/race-fired" ] || fail "$case_name did not reach identity recheck"
    [ -d "$lock" ] || fail "$case_name lock was removed"
    [ -f "$lock/pid.recovery.4194302" ] && [ "$(<"$lock/pid.recovery.4194302")" = 99999999 ] || fail 'swapped residue was removed'
    ;;
  restore-fail-keeps-record)
    make_lock
    printf '99999999\n' > "$lock/pid"
    replaced=0
    trellis_home_pid_is_live() {
      if [ "$replaced" -eq 0 ]; then
        replaced=1
        printf '%s\n' "$$" > "$lock/pid"
        return 1
      fi
      return 1
    }
    mv_calls=0
    mv() {
      mv_calls=$((mv_calls + 1))
      if [ "$mv_calls" -eq 2 ]; then return 1; fi
      /bin/mv "$@"
    }
    trellis_home_lock_try_recover_stale "$lock" "$name" > "$TEST_ROOT/output" 2>&1; rc=$?
    moved="$lock/pid.recovery.$$"
    [ "$rc" -eq 1 ] || fail "restore-fail rc=$rc want 1"
    [ -f "$moved" ] || fail 'live owner record was deleted on failed restore'
    [ "$(<"$moved")" = "$$" ] || fail 'live owner record content changed'
    [ -d "$lock" ] || fail 'restore-fail lock was removed'
    ;;
  race-missing-b)
    _b_rmdir_seen=false
    rmdir() {
      local result
      if [ "$_b_rmdir_seen" = false ]; then
        _b_rmdir_seen=true
        : > "$TEST_ROOT/b-ready"
        local n=0
        while [ ! -e "$TEST_ROOT/b-go" ]; do
          n=$((n + 1)); [ "$n" -lt 200 ] || return 1; sleep 0.1
        done
      fi
      /bin/rmdir "$@"; result=$?; return "$result"
    }
    printf '%s\n' "$$" > "$TEST_ROOT/b-pid"
    trellis_home_lock_acquire "$home" "$name" 0; rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/b-rc"
    ;;
  race-missing-a)
    _a_mkdir_seen=false
    mkdir() {
      local result
      /bin/mkdir "$@"; result=$?
      if [ "$result" -eq 0 ] && [ "$#" -eq 3 ] && [ "$3" = "$lock" ] && [ "$_a_mkdir_seen" = false ]; then
        _a_mkdir_seen=true
        : > "$TEST_ROOT/a-ready"
        local n=0
        while [ ! -e "$TEST_ROOT/a-go" ]; do
          n=$((n + 1)); [ "$n" -lt 200 ] || return 1; sleep 0.1
        done
      fi
      return "$result"
    }
    printf '%s\n' "$$" > "$TEST_ROOT/a-pid"
    trellis_home_lock_acquire "$home" "$name" 0; rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/a-rc"
    ;;
  race-missing-acquire)
    make_lock
    old "$lock"
    "$BASH" --noprofile --norc "$root/scripts/tests/helpers/home-lock-ownerless-driver.sh" \
      "race-missing-b" "$root" "$TEST_ROOT" > "$TEST_ROOT/b.out" 2>&1 &
    b_pid=$!
    if ! wait_for_file "$TEST_ROOT/b-ready" "$b_pid"; then
      barrier_kill "$b_pid"
      [ ! -s "$TEST_ROOT/b.out" ] || cat "$TEST_ROOT/b.out" >&2
      fail 'missing-pid B did not reach rmdir barrier'
    fi
    "$BASH" --noprofile --norc "$root/scripts/tests/helpers/home-lock-ownerless-driver.sh" \
      "race-missing-a" "$root" "$TEST_ROOT" > "$TEST_ROOT/a.out" 2>&1 &
    a_pid=$!
    if ! wait_for_file "$TEST_ROOT/a-ready" "$a_pid"; then
      barrier_kill "$b_pid" "$a_pid"
      [ ! -s "$TEST_ROOT/a.out" ] || cat "$TEST_ROOT/a.out" >&2
      [ ! -s "$TEST_ROOT/b.out" ] || cat "$TEST_ROOT/b.out" >&2
      fail 'missing-pid A did not reach mkdir barrier'
    fi
    : > "$TEST_ROOT/b-go"
    if ! wait_for_file "$TEST_ROOT/b-rc" "$b_pid"; then
      barrier_kill "$b_pid" "$a_pid"
      [ ! -s "$TEST_ROOT/b.out" ] || cat "$TEST_ROOT/b.out" >&2
      fail 'missing-pid B did not finish'
    fi
    wait "$b_pid" 2>/dev/null || true
    b_rc="$(<"$TEST_ROOT/b-rc")"
    b_pid_capture="$(<"$TEST_ROOT/b-pid")"
    [ "$b_rc" = 0 ] || fail "missing-pid winner rc=$b_rc want 0"
    [ -f "$lock/pid" ] && [ "$(<"$lock/pid")" = "$b_pid_capture" ] || fail 'missing-pid winner did not hold before loser resumed'
    : > "$TEST_ROOT/a-go"
    if ! wait_for_file "$TEST_ROOT/a-rc" "$a_pid"; then
      barrier_kill "$a_pid"
      [ ! -s "$TEST_ROOT/a.out" ] || cat "$TEST_ROOT/a.out" >&2
      fail 'missing-pid A did not finish'
    fi
    wait "$a_pid" 2>/dev/null || true
    a_rc="$(<"$TEST_ROOT/a-rc")"
    a_pid_capture="$(<"$TEST_ROOT/a-pid")"
    [ "$a_rc" = "$TRELLIS_EX_UNAVAILABLE" ] || fail "missing-pid loser rc=$a_rc want 5 (0 means double hold)"
    [ -f "$lock/pid" ] && [ "$(<"$lock/pid")" = "$b_pid_capture" ] || fail 'missing-pid winner pid not exclusive'
    [ "$(<"$lock/pid")" != "$a_pid_capture" ] || fail 'missing-pid loser overwrote winner pid'
    rm -rf "${lock:?}"
    [ ! -e "$lock" ] || fail 'missing-pid cleanup failed'
    ;;
  race-stalled-a)
    _a_mkdir_seen=false
    mkdir() {
      local result
      /bin/mkdir "$@"; result=$?
      if [ "$result" -eq 0 ] && [ "$#" -eq 3 ] && [ "$3" = "$lock" ] && [ "$_a_mkdir_seen" = false ]; then
        _a_mkdir_seen=true
        old "$lock"
        : > "$TEST_ROOT/a-ready"
        local n=0
        while [ ! -e "$TEST_ROOT/a-go" ]; do
          n=$((n + 1)); [ "$n" -lt 200 ] || return 1; sleep 0.1
        done
      fi
      return "$result"
    }
    printf '%s\n' "$$" > "$TEST_ROOT/a-pid"
    trellis_home_lock_acquire "$home" "$name" 0; rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/a-rc"
    ;;
  race-stalled-b)
    printf '%s\n' "$$" > "$TEST_ROOT/b-pid"
    trellis_home_lock_acquire "$home" "$name" 0; rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/b-rc"
    ;;
  race-stalled-owner)
    mkdir -p "$home/locks"
    "$BASH" --noprofile --norc "$root/scripts/tests/helpers/home-lock-ownerless-driver.sh" \
      "race-stalled-a" "$root" "$TEST_ROOT" > "$TEST_ROOT/a.out" 2>&1 &
    a_pid=$!
    if ! wait_for_file "$TEST_ROOT/a-ready" "$a_pid"; then
      barrier_kill "$a_pid"
      [ ! -s "$TEST_ROOT/a.out" ] || cat "$TEST_ROOT/a.out" >&2
      fail 'stalled-owner A did not reach mkdir barrier'
    fi
    "$BASH" --noprofile --norc "$root/scripts/tests/helpers/home-lock-ownerless-driver.sh" \
      "race-stalled-b" "$root" "$TEST_ROOT" > "$TEST_ROOT/b.out" 2>&1 &
    b_pid=$!
    if ! wait_for_file "$TEST_ROOT/b-rc" "$b_pid"; then
      barrier_kill "$a_pid" "$b_pid"
      [ ! -s "$TEST_ROOT/b.out" ] || cat "$TEST_ROOT/b.out" >&2
      fail 'stalled-owner B did not finish'
    fi
    wait "$b_pid" 2>/dev/null || true
    b_rc="$(<"$TEST_ROOT/b-rc")"
    b_pid_capture="$(<"$TEST_ROOT/b-pid")"
    [ "$b_rc" = 0 ] || fail "stalled-owner winner rc=$b_rc want 0"
    [ -f "$lock/pid" ] && [ "$(<"$lock/pid")" = "$b_pid_capture" ] || fail 'stalled-owner winner did not hold before loser resumed'
    : > "$TEST_ROOT/a-go"
    if ! wait_for_file "$TEST_ROOT/a-rc" "$a_pid"; then
      barrier_kill "$a_pid"
      [ ! -s "$TEST_ROOT/a.out" ] || cat "$TEST_ROOT/a.out" >&2
      fail 'stalled-owner A did not finish'
    fi
    wait "$a_pid" 2>/dev/null || true
    a_rc="$(<"$TEST_ROOT/a-rc")"
    a_pid_capture="$(<"$TEST_ROOT/a-pid")"
    [ "$a_rc" = "$TRELLIS_EX_UNAVAILABLE" ] || fail "stalled-owner loser rc=$a_rc want 5 (0 means double hold)"
    [ -f "$lock/pid" ] && [ "$(<"$lock/pid")" = "$b_pid_capture" ] || fail 'stalled-owner winner pid not exclusive'
    [ "$(<"$lock/pid")" != "$a_pid_capture" ] || fail 'stalled-owner loser overwrote winner pid'
    rm -rf "${lock:?}"
    [ ! -e "$lock" ] || fail 'stalled-owner cleanup failed'
    ;;
  *) fail "unknown case $case_name" ;;
esac
