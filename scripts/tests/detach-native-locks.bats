#!/usr/bin/env bats
# Spec 075 T3: the native detach program takes the checkout lock and the
# worktree attachment lock with the shell's own protocol. A lock either side
# holds is held for the other; a dead holder of either side is reclaimed by
# the other; a malformed lock is refused (4) by both.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/attachment.sh"
bats_require_minimum_version 1.5.0

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/detach-native-locks.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export TRELLIS_HOME="$SANDBOX/home"
  mkdir -m 700 "$TRELLIS_HOME"
  bash -c '. "$1"; _attachment_prepare_state "$2"' _ "$LIB" "$TRELLIS_HOME"
  COMMON="$SANDBOX/repo.git"
  mkdir "$COMMON"
  CHECKOUT="$(bash -c '. "$1"; _attachment_hash_text "$2"' _ "$LIB" "$COMMON")"
  WORKTREE="$(printf '%064d' 7)"
  ATTACHMENT="11111111-2222-3333-4444-555555555555"
  PROGRAM="$SANDBOX/program.py"
  bash -c '. "$1"; _attachment_detach_program' _ "$LIB" > "$PROGRAM"
  HOLDERS=()
}

teardown() {
  local pid
  for pid in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do kill -9 "$pid" 2>/dev/null || true; done
  rm -rf "$SANDBOX"
}

# native VERB ARGS...: one lock call through the program's own functions.
DRIVER=$(cat <<'PY'
import sys
namespace = {"__name__": "detach_native_locks_test"}
exec(compile(open(sys.argv[1]).read(), "detach_native.py", "exec"), namespace)
verb, args = sys.argv[2], sys.argv[3:]
if verb == "worktree-reclaim":
    sys.exit(namespace["worktree_lock_reclaim"](*args))
if verb == "checkout-reclaim":
    sys.exit(namespace["checkout_lock_reclaim"](*args))
if verb == "worktree-acquire":
    status, held = namespace["worktree_lock_acquire"](*args)
    if held is not None:
        held.release()
    sys.exit(status)
if verb == "checkout-acquire":
    status, held = namespace["checkout_lock_acquire"](*args)
    if held is not None:
        held.release()
    sys.exit(status)
if verb in ("worktree-hold", "checkout-hold"):
    import time
    acquire = namespace["worktree_lock_acquire" if verb == "worktree-hold" else "checkout_lock_acquire"]
    status, held = acquire(*args[1:])
    open(args[0], "w").write("%d\n" % status)
    if status == 0:
        time.sleep(600)
    sys.exit(status)
if verb == "checkout-wait":
    status, held = namespace["checkout_lock_wait"](*args)
    if held is not None:
        held.release()
    sys.exit(status)
sys.exit(99)
PY
)

native() {
  python3 -I -B -c "$DRIVER" "$PROGRAM" "$@"
}

# shell FUNCTION ARGS...: one shell lock call in its own process.
shell() {
  bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

# A shell process holding a lock until killed.
shell_hold() {
  local ready="$1"
  shift
  bash -c '. "$1"; ready=$2; shift 2
    "$@"; printf "%s\n" "$?" > "$ready"; sleep 600' _ "$LIB" "$ready" "$@" &
  HOLDERS+=("$!")
  wait_ready "$ready"
}

native_hold() {
  local ready="$1"
  shift
  # The python3 process itself is the lock holder, so $! is its pid.
  python3 -I -B -c "$DRIVER" "$PROGRAM" "$@" &
  HOLDERS+=("$!")
  wait_ready "$ready"
}

wait_ready() {
  local tries=0
  until [ -s "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 300 ] || { echo "no holder after 30 s"; return 1; }
    sleep 0.1
  done
  [ "$(cat "$1")" = 0 ] || { echo "holder status $(cat "$1")"; return 1; }
}

kill_holder() {
  kill -9 "${HOLDERS[$1]}"
  wait "${HOLDERS[$1]}" 2>/dev/null || true
}

worktree_link() {
  printf '%s/state/locks/attachment-%s-%s.lock\n' "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE"
}

checkout_link() {
  printf '%s/state/locks/attachment-checkout-%s.lock\n' "$TRELLIS_HOME" "$CHECKOUT"
}

@test "a worktree lock the native program holds is held for the shell, and reclaimed once it dies" {
  native_hold "$SANDBOX/ready" worktree-hold "$SANDBOX/ready" "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  run shell _attachment_lock_reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 3 ]
  run shell _attachment_lock_acquire "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 3 ]
  # The record is the shell's own shape, key order included.
  holder="$TRELLIS_HOME/state/locks/$(readlink "$(worktree_link)")"
  jq -e --arg a "$ATTACHMENT" 'keys_unsorted == ["checkout_id","worktree_id","attachment_id","pid","process_birth"] and .attachment_id == $a' "$holder/owner.json"
  [ "$(stat -c %a "$holder/owner.json" 2>/dev/null || stat -f %Lp "$holder/owner.json")" = 600 ]
  [ -f "$holder/publisher.lock" ]
  kill_holder 0
  run shell _attachment_lock_reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 0 ] || { echo "reclaim $status"; false; }
  [ ! -e "$(worktree_link)" ] && [ ! -L "$(worktree_link)" ]
  [ ! -e "$holder" ]
}

@test "a worktree lock a shell holds is held for the native program, and reclaimed once it dies" {
  shell_hold "$SANDBOX/ready" _attachment_lock_acquire "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  run native worktree-reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 3 ]
  run native worktree-acquire "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 3 ]
  # Another attachment's lock on this worktree is held, never reclaimed.
  run native worktree-reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "22222222-2222-3333-4444-555555555555"
  [ "$status" -eq 3 ]
  kill_holder 0
  run native worktree-reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 0 ]
  [ ! -L "$(worktree_link)" ]
  run native worktree-acquire "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
  [ "$status" -eq 0 ]
}

@test "a checkout lock is held and reclaimed alike in both directions, and the native wait outlasts a shell holder" {
  native_hold "$SANDBOX/ready-native" checkout-hold "$SANDBOX/ready-native" "$TRELLIS_HOME" "$CHECKOUT" "$COMMON"
  run shell _attachment_checkout_lock_reclaim "$TRELLIS_HOME" "$CHECKOUT" "$COMMON"
  [ "$status" -eq 3 ]
  holder="$TRELLIS_HOME/state/locks/$(readlink "$(checkout_link)")"
  jq -e 'keys_unsorted == ["checkout_id","git_common_dir","pid","process_birth"]' "$holder/owner.json"
  kill_holder 0
  run shell _attachment_checkout_lock_reclaim "$TRELLIS_HOME" "$CHECKOUT" "$COMMON"
  [ "$status" -eq 0 ]

  shell_hold "$SANDBOX/ready-shell" _attachment_checkout_lock_acquire "$TRELLIS_HOME" "$CHECKOUT" "$COMMON"
  run native checkout-reclaim "$TRELLIS_HOME" "$CHECKOUT" "$COMMON"
  [ "$status" -eq 3 ]
  ( sleep 2; kill -9 "${HOLDERS[1]}" ) &
  run native checkout-wait "$TRELLIS_HOME" "$CHECKOUT" "$COMMON"
  [ "$status" -eq 0 ]
  [ ! -L "$(checkout_link)" ]
}

@test "a malformed lock is refused alike by the shell and the native program" {
  local shape
  for shape in foreign-target slash-target regular-file bad-record; do
    rm -rf "$TRELLIS_HOME/state/locks"
    mkdir -m 700 "$TRELLIS_HOME/state/locks"
    case "$shape" in
      foreign-target) ln -s ".somebody-else" "$(worktree_link)" ;;
      slash-target) ln -s "../elsewhere" "$(worktree_link)" ;;
      regular-file) : > "$(worktree_link)" ;;
      bad-record)
        holder="$TRELLIS_HOME/state/locks/.attachment-$CHECKOUT-$WORKTREE.holder-$ATTACHMENT.1.abcdef"
        mkdir -m 700 "$holder"
        printf '{"pid":"1"}\n' > "$holder/owner.json"
        chmod 600 "$holder/owner.json"
        ln -s "$(basename "$holder")" "$(worktree_link)" ;;
    esac
    run shell _attachment_lock_reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
    shell_status=$status
    run native worktree-reclaim "$TRELLIS_HOME" "$CHECKOUT" "$WORKTREE" "$ATTACHMENT"
    [ "$status" -eq 4 ] && [ "$shell_status" -eq 4 ] || { echo "$shape: shell $shell_status native $status"; false; }
    [ -e "$(worktree_link)" ] || [ -L "$(worktree_link)" ]
  done
}
