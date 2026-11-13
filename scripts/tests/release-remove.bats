#!/usr/bin/env bats
# `trellis release remove VERSION [--dry-run|--apply]`: every refusal reason, a
# removal, an interrupted removal that reap-tmp and a rerun finish, a removal
# put back when a reference appears mid-apply, and links that are never
# followed. Each case drives the installed stable launcher (or the installed
# release.sh it runs) against a sandboxed HOME and TRELLIS_HOME.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
REGISTRY_LIB="$REPO_ROOT/scripts/lib/local-registry.sh"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"
HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
load helpers/release-fixture

setup_file() {
  local proto
  proto="$(CDPATH='' cd "$BATS_FILE_TMPDIR" && pwd -P)/proto"
  mkdir -p "$proto"
  release_fixture_bootstrap "$proto/user" "$proto/trellis" "$proto"
}

teardown_file() {
  find "$BATS_FILE_TMPDIR" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
}

setup() {
  local proto config
  proto="$(CDPATH='' cd "$BATS_FILE_TMPDIR" && pwd -P)/proto"
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/relrm.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  for name in user trellis 'bootstrap release source'; do
    fixture_clone "$proto/$name" "$SANDBOX/$name"
  done
  USER_HOME="$SANDBOX/user"
  TRELLIS_HOME="$SANDBOX/trellis"
  RELEASES="$TRELLIS_HOME/releases"
  LAUNCHER="$USER_HOME/.local/bin/trellis"
  chmod 700 "$USER_HOME" "$TRELLIS_HOME"
  config="$TRELLIS_HOME/config.json"
  jq --arg source "$SANDBOX/bootstrap release source" --arg root "$SANDBOX" \
    '.source_root = $source | .fleets.personal.discovery_roots = [$root]' "$config" > "$config.next"
  mv "$config.next" "$config"
  chmod 600 "$config"
  release_fixture_rewrite_release_remote "$RELEASES/0.0.0" "$SANDBOX/bootstrap release source"
  # The launcher makes its private stores (state, scratch, .exec) on first use.
  trellis release list >/dev/null
  umask 077
  fake_release 1.0.0
  LIVE_PID=""
}

teardown() {
  [ -z "${LIVE_PID:-}" ] || kill "$LIVE_PID" 2>/dev/null || true
  find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
  rm -rf "${SANDBOX:?}"
}

trellis() {
  env HOME="$USER_HOME" TRELLIS_HOME="$TRELLIS_HOME" GIT_CONFIG_NOSYSTEM=1 "$LAUNCHER" "$@"
}

# fake_release VERSION: an installed-looking release, sealed read-only, with one
# execution snapshot, its flock file, and a release and an exec stamp.
fake_release() {
  local version="$1"
  mkdir -p "$RELEASES/$version/payload/scripts" "$RELEASES/.exec/$version-$HASH/payload" \
    "$TRELLIS_HOME/state/release-stamps" "$TRELLIS_HOME/state/exec-stamps"
  head -c 65536 /dev/zero > "$RELEASES/$version/payload/scripts/blob"
  printf '{}\n' > "$RELEASES/$version/release.json"
  printf 'snapshot\n' > "$RELEASES/.exec/$version-$HASH/payload/file"
  : > "$RELEASES/.exec/.lock.$version-$HASH"
  printf '{}\n' > "$TRELLIS_HOME/state/release-stamps/$version-$HASH.json"
  printf '{}\n' > "$TRELLIS_HOME/state/exec-stamps/$version-$HASH.json"
  chmod -R a-w "$RELEASES/$version" "$RELEASES/.exec/$version-$HASH"
}

entries() {
  printf '%s\n' "$RELEASES/$1" "$RELEASES/.exec/$1-$HASH" "$RELEASES/.exec/.lock.$1-$HASH" \
    "$TRELLIS_HOME/state/release-stamps/$1-$HASH.json" "$TRELLIS_HOME/state/exec-stamps/$1-$HASH.json"
}

assert_intact() {
  local entry
  while IFS= read -r entry; do
    [ -e "$entry" ] || { echo "missing: $entry"; false; }
  done < <(entries "$1")
  [ -f "$RELEASES/$1/payload/scripts/blob" ]
}

assert_gone() {
  local entry
  while IFS= read -r entry; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || { echo "still present: $entry"; false; }
  done < <(entries "$1")
}

assert_refused() {
  [ "$status" -eq "$1" ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"trellis release: refusing to remove 1.0.0: $2"* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: 1.0.0 kept; nothing removed"* ]] || { echo "$output"; false; }
  assert_intact 1.0.0
  [ -z "$(cd "$RELEASES" && find . -maxdepth 1 -name '.tmp.remove.*')" ]
  [ ! -e "$RELEASES/1.0.0.lock" ]
}

# register PROJECT [RELEASE]: a registered worktree at $SANDBOX/projects/PROJECT.
register() {
  local root="$SANDBOX/projects/$1"
  mkdir -p "$root"
  git init -q -b main "$root"
  printf '{"schema_version":1,"project_id":"%s"}\n' "$1" > "$root/.trellis.json"
  git -C "$root" add .trellis.json
  git -C "$root" -c user.email=f@example.invalid -c user.name=f commit -qm fixture
  env HOME="$USER_HOME" TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    local_registry_register_worktree "$2" personal "$3" "$4" "$5" "[]" "" "{}" >/dev/null
  ' register "$REGISTRY_LIB" "$TRELLIS_HOME" "$1" "$root" "${2-0.0.0}"
}

# sourced SCRIPT: run SCRIPT with the installed release.sh command surface loaded,
# exactly as the launcher's bundle would, so a case can stand in for a crash or a
# concurrent writer between two steps.
sourced() {
  local scratch="$TRELLIS_HOME/state/scratch/.cmd.test"
  mkdir -p "$scratch"
  chmod 700 "$scratch"
  env -i HOME="$USER_HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TRELLIS_VERIFIED_PAYLOAD="$RELEASES/0.0.0/payload" TRELLIS_VERIFIED_RELEASE_VERSION=0.0.0 \
    TRELLIS_RELEASE_CLEAN_ENV=1 TRELLIS_RELEASE_BUNDLE_PRELOAD=1 \
    TRELLIS_RELEASE_SCRATCH_CANDIDATE="$scratch" PROJECT="$SANDBOX/projects/racer" \
    SANDBOX="$SANDBOX" RACE_TARGET="${RACE_TARGET:-}" \
    bash -c '. "$1"; eval "$2"' sourced "$RELEASES/0.0.0/payload/scripts/release.sh" "$1"
}

backdate() {
  python3 - "$@" <<'PY'
import os, sys, time
when = time.time() - int(sys.argv[1])
for path in sys.argv[2:]:
    os.utime(path, (when, when), follow_symlinks=False)
PY
}

# Full fake proc records of a live (state S) PID: its missing members are
# unknown, not evidence that it exited. Used through the installed command on
# macOS.
proc_fixture() {
  mkdir -p "$SANDBOX/proc/42/fd"
  ln -s "$RELEASES/1.0.0" "$SANDBOX/proc/42/cwd"
  ln -s / "$SANDBOX/proc/42/root"
  ln -s /bin/sleep "$SANDBOX/proc/42/exe"
  printf '7f00-7f01 r-xp 0 01:02 3 %s\n' "$RELEASES/1.0.0/payload/scripts/blob" > "$SANDBOX/proc/42/maps"
  printf 'sleep\n' > "$SANDBOX/proc/42/comm"
  mkdir -p "$SANDBOX/proc/42/task/42"
  printf '42 (sleep) S 1 42 42 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0\n' > "$SANDBOX/proc/42/stat"
}

# A zombie as Linux shows it once the task has dropped fs and mm: fd/ and maps
# read empty, cwd, root and exe are absent (readlink gives ENOENT), stat stays.
# zombie_fixture [COMM] [STATE] [FLAGS] [FILE]: FILE (default stat) gets the line.
zombie_fixture() {
  mkdir -p "$SANDBOX/proc/44/fd" "$SANDBOX/proc/44/task/44"
  : > "$SANDBOX/proc/44/maps"
  printf 'zombie\n' > "$SANDBOX/proc/44/comm"
  printf '44 (%s) %s 1 44 44 0 -1 %s 0 0 0 0 0 0 0 0 20 0 1 0\n' "${1:-zombie}" "${2:-Z}" "${3:-4227084}" \
    > "$SANDBOX/proc/44/${4:-stat}"
}

@test "remove fail-closed: every reference namespace must be listable and searchable" {
  for relative in state/attachments state/attachments/checkout attachments \
    state/git-hooks state/git-hooks/checkout state/attachment-journals \
    state/user-attachment-journals state/release-adoptions state/release-adoptions/checkout; do
    directory="$TRELLIS_HOME/$relative"
    mkdir -p "$directory"
    if [ "$relative" = state/attachments/checkout ]; then
      printf '{"release":"1.0.0"}\n' > "$directory/worktree.json"
    elif [ "$relative" = state/release-adoptions/checkout ]; then
      printf '{"old_version":"0.0.0","new_version":"0.0.1"}\n' > "$directory/plans.jsonl"
    fi
    for mode in 100 400 000; do
      chmod "$mode" "$directory"
      run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
      chmod 700 "$directory"
      assert_refused 4 "reference namespace could not be checked: $directory"
    done
    if [ "$relative" = state/attachments/checkout ]; then
      run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
      assert_refused 3 "attachment owner record: $directory/worktree.json"
      rm "${directory:?}/worktree.json"
    elif [ "$relative" = state/release-adoptions/checkout ]; then
      rm "${directory:?}/plans.jsonl"
    fi
  done
}

@test "remove fail-closed: unreadable regular hook sidecar refuses with all entries intact" {
  sidecar="$TRELLIS_HOME/state/git-hooks/review/release-payload"
  mkdir -p "${sidecar%/*}"
  printf '%s\n' "$RELEASES/1.0.0/payload" > "$sidecar"
  chmod 000 "$sidecar"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 600 "$sidecar"
  assert_refused 4 "managed Git hook release-payload sidecar is unreadable: $sidecar"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "managed Git hook release-payload sidecar: $sidecar"
}

# EACCES/EPERM on a PID's entry means the kernel will not let us inspect that
# process: it is skipped and listed. Any other error cannot answer and refuses,
# as does an unreadable proc root. A dry-run keeps the release for each case.
@test "remove fail-closed: proc root and non-permission errors refuse; EACCES PIDs are skipped and listed" {
  proc_fixture
  chmod 000 "$SANDBOX/proc"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$SANDBOX/proc"
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc"* ]] || false
  # A holder found before the EACCES still refuses, so cwd points elsewhere here.
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  for member in 42 42/fd 42/maps; do
    path="$SANDBOX/proc/$member"
    chmod 000 "$path"
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 dry-run'
    chmod 700 "$path"
    [ "$status" -eq 0 ] || { echo "$member: $output"; false; }
    [[ "$output" == *"could not inspect 1 processes (1 of uid $(id -u) the kernel will not let it inspect: 42 "* ]] ||
      { echo "$member: $output"; false; }
    [[ "$output" == *"remove: dry-run: nothing removed"* ]] || { echo "$output"; false; }
    assert_intact 1.0.0
  done
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s "$RELEASES/1.0.0" "$SANDBOX/proc/42/cwd"
  # Errors other than EACCES/EPERM: EINVAL (a link that is not one), ENOTDIR
  # (fd/ not a directory), EISDIR (maps a directory); then ENOENT on a live PID.
  for member in cwd root exe; do
    path="$SANDBOX/proc/42/$member"
    target="$(readlink "$path")"
    rm "${path:?}"
    printf 'not a link\n' > "$path"
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$path is unreadable"* ]] || { echo "$output"; false; }
    rm "${path:?}"
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    ln -s "$target" "$path"
  done
  for member in fd maps; do
    path="$SANDBOX/proc/42/$member"
    mv "$path" "$path.saved"
    if [ "$member" = fd ]; then : > "$path"; else mkdir "$path"; fi
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    rm -rf "${path:?}"
    mv "$path.saved" "$path"
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$path is unreadable"* ]] || { echo "$output"; false; }
  done
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
}

# Linux refuses a cwd, root or exe link with EACCES whenever the reader lacks
# ptrace-read access, even while fd/ is readable (systemd --user). macOS honours
# a symlink's own mode, so a 000 link stands in; Linux ignores link modes. The
# release stays in use unseen: the documented residual.
# A descriptor that closes between the fd listing and its readlink (busy
# desktops hit this) is benign; the seam makes one entry vanish on cue. A
# vanished cwd of a PID still present is not.
@test "remove: proc fd entry closed between listing and readlink is benign" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/proc/42/fd/3"
  ln -s /elsewhere "$SANDBOX/proc/42/fd/4"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_CLOSED="$SANDBOX/proc/42/cwd" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc/42/cwd is unreadable"* ]] || { echo "$output"; false; }
  run sourced 'TRELLIS_TEST_RELEASE_PROC_CLOSED="$SANDBOX/proc/42/fd/3" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"could not inspect"* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove: our PID with a readable fd but an EACCES cwd is skipped and listed" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  chmod -h 000 "$SANDBOX/proc/42/cwd" 2>/dev/null || true
  ! readlink "$SANDBOX/proc/42/cwd" >/dev/null 2>&1 || skip "this host ignores symlink modes"
  ls "$SANDBOX/proc/42/fd" >/dev/null
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not inspect 1 processes (1 of uid $(id -u) the kernel will not let it inspect: 42 \"sleep\")"* ]] ||
    { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove fail-closed: proc missing fd or maps on a present PID refuses; exited PID is benign" {
  proc_fixture
  for member in fd maps; do
    path="$SANDBOX/proc/42/$member"
    mv "$path" "$path.saved"
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    mv "$path.saved" "$path"
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$path"* ]] || { echo "$output"; false; }
  done
  # A numeric directory entry whose PID has disappeared by inspection time.
  mv "$SANDBOX/proc/42" "$SANDBOX/exited"
  ln -s "$SANDBOX/vanished" "$SANDBOX/proc/42"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

# A zombie (Z) or dead (X) PID, or one whose stat is gone, has exited: its
# absent links are benign. The state is the field after the last ")", so a comm
# such as "a) Z (b" cannot pass a running process off as one. A live process
# with an absent link, or a zombie leader whose other threads still run, is
# indeterminate and refuses as before.
@test "remove: proc zombie, dead or vanished-stat PIDs with absent links are benign; live ones refuse" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  zombie_fixture
  # The zombie does not hide another PID's holder.
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/proc/42/fd/3"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
  rm "${SANDBOX:?}/proc/42/fd/3"
  for state in Z X vanished; do
    if [ "$state" = vanished ]; then rm "${SANDBOX:?}/proc/44/stat"; else zombie_fixture zombie "$state"; fi
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 dry-run'
    [ "$status" -eq 0 ] || { echo "$state: $output"; false; }
    [[ "$output" == *"remove: dry-run: nothing removed"* ]] || { echo "$state: $output"; false; }
    [[ "$output" != *"could not inspect"* ]] || { echo "$state: $output"; false; }
    assert_intact 1.0.0
  done
  for case in R "a) Z (b:R" "zombie:S" "zombie:D" thread; do
    case "$case" in
      thread) zombie_fixture; mkdir "$SANDBOX/proc/44/task/45" ;;
      *:*) zombie_fixture "${case%:*}" "${case##*:}" ;;
      *) zombie_fixture zombie "$case" ;;
    esac
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    rm -rf "${SANDBOX:?}/proc/44/task/45"
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$SANDBOX/proc/44/cwd is unreadable"* ]] || { echo "$case: $output"; false; }
  done
  # A stat that cannot be parsed answers nothing.
  printf '44 (zombie\n' > "$SANDBOX/proc/44/stat"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc/44/stat"* ]] || { echo "$output"; false; }
  zombie_fixture
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"could not inspect"* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
}

# A process between dropping its mm or fs and becoming a zombie still shows R,
# S or D with its links gone. The probe re-reads its stat and the link over a
# bounded window: turning Z or X, or vanishing, is an exit; a link that
# resolves is checked and the scan goes on; staying alive with the link gone
# refuses. A kernel thread (PF_KTHREAD in the flags, field 9) has no exe and
# holds nothing. The step seam swaps in each NAME.next before every retry.
@test "remove: proc exiting PIDs are re-read over a bounded window; kernel threads hold nothing" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  step='TRELLIS_TEST_RELEASE_PROC_STEP=.next TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc"'
  for next in Z X vanished; do
    zombie_fixture zombie R
    if [ "$next" = vanished ]; then
      ln -s "$SANDBOX/gone" "$SANDBOX/proc/44/stat.next"
    else
      zombie_fixture zombie "$next" 4227084 stat.next
    fi
    run sourced "$step"' remove_release "$TRELLIS_HOME" 1.0.0 dry-run'
    [ "$status" -eq 0 ] || { echo "R then $next: $output"; false; }
    [[ "$output" == *"remove: dry-run: nothing removed"* ]] || { echo "R then $next: $output"; false; }
    [[ "$output" != *"could not inspect"* ]] || { echo "R then $next: $output"; false; }
    # The exit was seen on a re-read, not on the first one.
    [ ! -e "$SANDBOX/proc/44/stat.next" ] && [ ! -L "$SANDBOX/proc/44/stat.next" ] || { echo "R then $next: no re-read"; false; }
    assert_intact 1.0.0
  done
  # Still alive on the re-read, links still gone: refuses as before.
  zombie_fixture zombie R
  zombie_fixture zombie S 4227084 stat.next
  run sourced "$step"' remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc/44/cwd is unreadable"* ]] || { echo "$output"; false; }
  # Links that resolve on the re-read are checked, and the rest of the PID too.
  for member in cwd root exe; do ln -s /elsewhere "$SANDBOX/proc/44/$member.next"; done
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/proc/44/fd/3"
  run sourced "$step"' remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 44 uses it: $RELEASES/1.0.0"
  rm -f "${SANDBOX:?}/proc/44/cwd" "${SANDBOX:?}/proc/44/root" "${SANDBOX:?}/proc/44/exe" "${SANDBOX:?}/proc/44/fd/3"
  ln -s "$RELEASES/1.0.0" "$SANDBOX/proc/44/cwd.next"
  for member in root exe; do ln -s /elsewhere "$SANDBOX/proc/44/$member.next"; done
  run sourced "$step"' remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 44 uses it: $RELEASES/1.0.0"
  rm -f "${SANDBOX:?}/proc/44/cwd" "${SANDBOX:?}/proc/44/root" "${SANDBOX:?}/proc/44/exe"
  # A kernel thread: S with PF_KTHREAD (0x00200000) in kthreadd's flags 0x208040.
  zombie_fixture kthreadd S 2129984
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"could not inspect"* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
}

# The exit probes are per-PID entries too: EACCES or EPERM on the stat or task
# of a PID whose link is gone skips and counts it, any other error refuses. The
# seam injects EPERM, which no file mode gives; a 000 stat is a real EACCES.
@test "remove: EACCES or EPERM on a PID's stat or task skips and counts it; other errors refuse" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  zombie_fixture
  me="$(id -u)"
  for target in stat task; do
    for code in EACCES EPERM; do
      run sourced 'TRELLIS_TEST_RELEASE_PROC_FAULT="$SANDBOX/proc/44/'"$target:$code"'" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 dry-run'
      [ "$status" -eq 0 ] || { echo "$target $code: $output"; false; }
      [[ "$output" == *"could not inspect 1 processes (1 of uid $me the kernel will not let it inspect: 44 \"zombie\")"* ]] ||
        { echo "$target $code: $output"; false; }
      [[ "$output" == *"remove: dry-run: nothing removed"* ]] || { echo "$output"; false; }
      assert_intact 1.0.0
    done
    run sourced 'TRELLIS_TEST_RELEASE_PROC_FAULT="$SANDBOX/proc/44/'"$target"':EIO" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$SANDBOX/proc/44/$target is unreadable"* ]] || { echo "$target EIO: $output"; false; }
  done
  # A skipped PID does not hide another PID's holder.
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/proc/42/fd/3"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_FAULT="$SANDBOX/proc/44/stat:EPERM" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
  rm "${SANDBOX:?}/proc/42/fd/3"
  [ "$me" -ne 0 ] || return 0
  chmod 000 "$SANDBOX/proc/44/stat"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 600 "$SANDBOX/proc/44/stat"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not inspect 1 processes (1 of uid $me the kernel will not let it inspect: 44 \"zombie\")"* ]] ||
    { echo "$output"; false; }
  assert_gone 1.0.0
}

# A PID reaped between the /proc listing and the read answers ESRCH, not ENOENT:
# it has gone, so it is skipped. ESRCH proves nothing while the stat still says
# the PID is alive, so a live PID whose member answers ESRCH still refuses.
@test "remove: ESRCH from a PID reaped mid-scan skips it; a live PID's ESRCH refuses" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  zombie_fixture
  for target in stat task; do
    run sourced 'TRELLIS_TEST_RELEASE_PROC_FAULT="$SANDBOX/proc/44/'"$target"':ESRCH" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 dry-run'
    [ "$status" -eq 0 ] || { echo "$target ESRCH: $output"; false; }
    [[ "$output" == *"remove: dry-run: nothing removed"* ]] || { echo "$target ESRCH: $output"; false; }
    [[ "$output" != *"could not inspect"* ]] || { echo "$target ESRCH: $output"; false; }
    assert_intact 1.0.0
  done
  # A gone PID does not hide another PID's holder.
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/proc/42/fd/3"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_FAULT="$SANDBOX/proc/44/stat:ESRCH" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
  rm "${SANDBOX:?}/proc/42/fd/3"
  # Alive (S) with its cwd gone and ESRCH on its descriptors: indeterminate.
  zombie_fixture zombie S
  run sourced 'TRELLIS_TEST_RELEASE_PROC_FAULT="$SANDBOX/proc/44/fd:ESRCH" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc/44/fd is unreadable"* ]] || { echo "$output"; false; }
  assert_intact 1.0.0
}

# Only ENOENT on a descriptor is a close race; EINVAL (an fd entry that is not a
# link) or any other non-permission error cannot answer.
@test "remove fail-closed: a non-permission error other than ENOENT on an fd entry refuses" {
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  printf 'not a link\n' > "$SANDBOX/proc/42/fd/3"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc/42/fd/3 is unreadable"* ]] || { echo "$output"; false; }
  [[ "$output" != *"could not inspect"* ]] || { echo "$output"; false; }
}

@test "remove fail-closed: runtime traversal and target resolution cannot hide inaccessible paths" {
  register guarded
  mkdir -p "$SANDBOX/projects/guarded/.trellis" "$SANDBOX/hidden"
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/hidden/target"
  ln -s "$SANDBOX/hidden/target" "$SANDBOX/projects/guarded/.trellis/runtime"
  chmod 000 "$SANDBOX/projects/guarded/.trellis"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$SANDBOX/projects/guarded/.trellis"
  assert_refused 4 "runtime anchor of personal/guarded is unreadable: $SANDBOX/projects/guarded/.trellis/runtime"
  chmod 000 "$SANDBOX/hidden"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$SANDBOX/hidden"
  assert_refused 4 "runtime anchor of personal/guarded is unreadable: $SANDBOX/projects/guarded/.trellis/runtime"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "runtime anchor of personal/guarded: $SANDBOX/projects/guarded/.trellis/runtime"
}

@test "remove fail-closed: unreadable JSON records, project pin, config and registry refuse" {
  for relative in state/attachments/checkout/worktree.json attachments/user.json \
    state/attachment-journals/pending.json state/user-attachment-journals/pending.json \
    state/release-adoptions/checkout/plans.jsonl; do
    file="$TRELLIS_HOME/$relative"
    mkdir -p "${file%/*}"
    printf '{"release":"1.0.0"}\n' > "$file"
    chmod 000 "$file"
    run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
    chmod 600 "$file"
    [ "$status" -eq 4 ] || { echo "$output"; false; }
    [[ "$output" == *"$file"* ]] || { echo "$output"; false; }
    assert_intact 1.0.0
    rm "${file:?}"
    # An adoption workspace without a plan is itself indeterminate.
    [ "$relative" != state/release-adoptions/checkout/plans.jsonl ] || rmdir "${file%/*}"
  done
  register configured
  file="$SANDBOX/projects/configured/.trellis.config.json"
  printf '{"trellis_version":"1.0.0"}\n' > "$file"
  chmod 000 "$file"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 600 "$file"
  assert_refused 4 "project config of personal/configured is unreadable: $file"
  rm "${file:?}"
  for file in "$TRELLIS_HOME/config.json" "$TRELLIS_HOME/registry.json"; do
    chmod 000 "$file"
    run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
    chmod 600 "$file"
    [ "$status" -eq 4 ] || { echo "$output"; false; }
    [[ "$output" == *"$file"* ]] || { echo "$output"; false; }
    assert_intact 1.0.0
  done
}

@test "remove fail-closed: registry scratch failure and optional lookup failure are explicit" {
  run sourced 'mktemp() { return 1; }; remove_release_references "$TRELLIS_HOME" 1.0.0 ""'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *$'4\tthe local registry could not be listed\t'"$TRELLIS_HOME/registry.json"* ]] || { echo "$output"; false; }
  mkdir -p "$SANDBOX/hidden"
  chmod 000 "$SANDBOX/hidden"
  run sourced 'remove_reference_paths "$SANDBOX/hidden/config.json" 0 ""'
  chmod 700 "$SANDBOX/hidden"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"$SANDBOX/hidden/config.json"* ]] || false
  assert_intact 1.0.0
}

@test "remove fail-closed: runtime readlink and registry decoding failures refuse" {
  register guarded
  mkdir -p "$SANDBOX/projects/guarded/.trellis"
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/projects/guarded/.trellis/runtime"
  run sourced 'readlink() { return 1; }; remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "runtime anchor of personal/guarded is unreadable: $SANDBOX/projects/guarded/.trellis/runtime"
  rm "${SANDBOX:?}/projects/guarded/.trellis/runtime"
  # Inject failures only in the two consumer-side inventory projections, not
  # in registry production. Previously pipelines discarded both jq statuses.
  for projection in pins rows; do
    if [ "$projection" = pins ]; then
      pattern='*"registry release pin of"*'
    else
      pattern='*"@tsv"*'
    fi
    run sourced "jq() { case \"\$*\" in $pattern) return 7 ;; esac; command jq \"\$@\"; }; remove_release \"\$TRELLIS_HOME\" 1.0.0 apply"
    assert_refused 4 "the local registry could not be decoded: $TRELLIS_HOME/registry.json"
  done
}

@test "remove fail-closed: unavailable-row owner lookup and read failures remain unknown" {
  mkdir -p "$TRELLIS_HOME/state/attachments/checkout"
  owner="$TRELLIS_HOME/state/attachments/checkout/worktree.json"
  printf '{"release":"1.0.0"}\n' > "$owner"
  for path in "$owner" "${owner%/*}"; do
    chmod 000 "$path"
    run sourced 'remove_unavailable_row "$TRELLIS_HOME" 1.0.0 personal/gone /missing-root 0.0.0 checkout worktree'
    chmod 700 "$path"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *$'4\tunavailable registry row of personal/gone has an unreadable owner record '*"$owner"* ]] || { echo "$output"; false; }
    assert_intact 1.0.0
  done
  run sourced 'remove_unavailable_row "$TRELLIS_HOME" 1.0.0 personal/gone /missing-root 0.0.0 checkout worktree'
  [[ "$output" == $'3\tunavailable registry row of personal/gone records this release\t/missing-root' ]] || { echo "$output"; false; }
}

@test "remove fail-closed: inaccessible existing registry root is not an absent checkout" {
  register hidden 0.0.0
  chmod 000 "$SANDBOX/projects"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$SANDBOX/projects"
  assert_refused 4 "unavailable registry row of personal/hidden cannot be inspected: $SANDBOX/projects/hidden"
}

@test "remove fail-closed: symlinked namespaces and missing adoption plans refuse" {
  mkdir -p "$SANDBOX/outside"
  for relative in attachments state/attachments state/git-hooks state/attachment-journals \
    state/user-attachment-journals state/release-adoptions; do
    path="$TRELLIS_HOME/$relative"
    [ ! -d "$path" ] || rmdir "$path"
    ln -s "$SANDBOX/outside" "$path"
    run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "reference namespace could not be checked: $path"
    rm "${path:?}"
  done
  mkdir -p "$TRELLIS_HOME/state/release-adoptions/incomplete"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "pending adoption journal has no readable plan: $TRELLIS_HOME/state/release-adoptions/incomplete"
}

# Finder leaves .DS_Store in any directory it opens. Beside the record
# directories it holds no record, so it must not make every removal refuse;
# records, unreadable records and links there still count.
@test "remove: a stray non-record file beside the record directories is ignored; records and links still count" {
  owners="$TRELLIS_HOME/state/attachments"
  mkdir -p "$owners/checkout" "$TRELLIS_HOME/state/git-hooks"
  : > "$owners/.DS_Store"
  : > "$TRELLIS_HOME/state/git-hooks/.DS_Store"
  chmod 000 "$owners/.DS_Store"
  printf '{"release":"1.0.0"}\n' > "$owners/checkout/worktree.json"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "attachment owner record: $owners/checkout/worktree.json"
  chmod 000 "$owners/checkout/worktree.json"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 600 "$owners/checkout/worktree.json"
  assert_refused 4 "attachment owner record is unreadable: $owners/checkout/worktree.json"
  rm "${owners:?}/checkout/worktree.json"
  ln -s "$SANDBOX" "$owners/.link"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "reference namespace could not be checked: $owners/.link"
  rm "${owners:?}/.link"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove fail-closed: hook target resolution failure is unknown, not not-found" {
  mkdir -p "$SANDBOX/hidden" "$TRELLIS_HOME/state/git-hooks/checkout"
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/hidden/payload"
  printf '%s\n' "$SANDBOX/hidden/payload" > "$TRELLIS_HOME/state/git-hooks/checkout/release-payload"
  chmod 000 "$SANDBOX/hidden"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$SANDBOX/hidden"
  assert_refused 4 "managed Git hook release-payload sidecar could not be resolved: $TRELLIS_HOME/state/git-hooks/checkout/release-payload"
}

@test "remove fail-closed: unanswerable second pass restores all five entries" {
  mkdir -p "$TRELLIS_HOME/state/attachments/checkout"
  run sourced '
    eval "original_$(declare -f release_store_rename_no_clobber)"
    release_store_rename_no_clobber() {
      original_release_store_rename_no_clobber "$@" || return
      case "$2" in */.tmp.remove.*) chmod 000 "$TRELLIS_HOME/state/attachments/checkout" ;; esac
    }
    remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$TRELLIS_HOME/state/attachments/checkout"
  assert_refused 4 "reference namespace could not be checked: $TRELLIS_HOME/state/attachments/checkout"
}

@test "remove fail-closed: lsof launch, status, empty and malformed records refuse, readable controls hold" {
  probe="$SANDBOX/lsof"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$probe"* ]] || false
  for body in 'exit 42' 'exit 0' 'printf "bad\\n"' 'printf "p42\\n"' \
    'printf "p42\\nu$(id -u)\\nn/elsewhere\\n"; printf "partial snapshot\\n" >&2'; do
    printf '#!/bin/sh\n%s\n' "$body" > "$probe"
    chmod 700 "$probe"
    run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$probe"* ]] || false
  done
  printf '#!/bin/sh\nprintf "p42\\nu%s\\nn%%s\\n" "%s"\n' "$(id -u)" "$RELEASES/1.0.0/payload" > "$probe"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
  printf '#!/bin/sh\nprintf "p42\\nu%s\\nn/elsewhere\\n"\n' "$(id -u)" > "$probe"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

# The process check covers the invoking user's inspectable processes only: a
# release lives under that user's TRELLIS_HOME, and no unprivileged user can
# read root's /proc/1/fd. A root-owned / stands in for another user's /proc/PID;
# a PID directory of ours whose fd is a root-owned directory no one else may
# search stands in for a non-dumpable process of ours (ssh-agent).
@test "remove: proc PIDs of other users and PIDs we may not inspect are skipped and counted" {
  [ "$(id -u)" -ne 0 ] || skip "root reads every /proc entry"
  locked=""
  for candidate in /var/root /root; do
    if [ -d "$candidate" ] && [ ! -O "$candidate" ] && [ ! -x "$candidate" ]; then
      locked="$candidate"
      break
    fi
  done
  [ -n "$locked" ] || { echo "no root-owned directory this user cannot search"; false; }
  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s /elsewhere "$SANDBOX/proc/42/cwd"
  ln -s / "$SANDBOX/proc/1"
  mkdir "$SANDBOX/proc/43"
  ln -s "$locked" "$SANDBOX/proc/43/fd"
  ln -s /elsewhere "$SANDBOX/proc/43/cwd"
  printf 'ssh-agent\n' > "$SANDBOX/proc/43/comm"
  # EACCES on the stat of the PID directory itself.
  ln -s "$locked/44" "$SANDBOX/proc/44"
  # A proc root that lists but cannot be searched is unreadable, not skipped.
  chmod 400 "$SANDBOX/proc"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$SANDBOX/proc"
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$SANDBOX/proc is unreadable (not searchable)"* ]] || { echo "$output"; false; }
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"process check could not inspect 3 processes (1 of other users; 2 of uid $(id -u) the kernel will not let it inspect: 43 \"ssh-agent\", 44 \"?\"); it covers uid $(id -u)'s inspectable processes only"* ]] ||
    { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove fail-closed: lsof requires a uid on every process record, including at EOF" {
  probe="$SANDBOX/lsof"
  me="$(id -u)"
  for records in "$(printf 'p7\np42\nu%s\nn/elsewhere\n' "$me")" \
    "$(printf 'p42\nu%s\nn/elsewhere\np7\np43\nu%s\nn/elsewhere\n' "$me" "$me")" \
    "$(printf 'p42\nu%s\nn/elsewhere\np7\n' "$me")"; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "'${records}'" > "$probe"
    chmod 700 "$probe"
    run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$probe returned malformed process records"* ]] || { echo "$output"; false; }
  done
}

@test "remove: lsof uid-bearing records need no descriptors but the snapshot needs our paths" {
  probe="$SANDBOX/lsof"
  me="$(id -u)"
  # Descriptor-less records of either uid are valid at boundaries and at EOF.
  printf '#!/bin/sh\nprintf "p7\\nu%s\\np8\\nu%s\\np42\\nu%s\\nn/elsewhere\\np43\\nu%s\\n"\n' \
    "$me" "$((me + 1))" "$me" "$me" > "$probe"
  chmod 700 "$probe"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 dry-run'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not inspect 1 processes (1 of other users)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: dry-run: nothing removed"* ]] || { echo "$output"; false; }
  assert_intact 1.0.0
  printf '#!/bin/sh\nprintf "p7\\nu%s\\np8\\nu%s\\n"\n' "$me" "$((me + 1))" > "$probe"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
  [[ "$output" == *"$probe returned no process paths for uid $me"* ]] || { echo "$output"; false; }
}

@test "remove: proc skipped names are one-line JSON with whitespace preserved and missing names explicit" {
  [ "$(id -u)" -ne 0 ] || skip "root reads every /proc entry"
  proc_fixture
  chmod 000 "$SANDBOX/proc/42/fd"
  for kind in controls trailing-newline empty unreadable; do
    case "$kind" in
      controls)
        printf 'agent\nFORGED\t\033[31m \342\230\203  \n' > "$SANDBOX/proc/42/comm"
        quoted='"agent\nFORGED\t\u001b[31m \u2603  "'
        ;;
      trailing-newline)
        printf 'agent\n\n' > "$SANDBOX/proc/42/comm"
        quoted='"agent\n"'
        ;;
      empty)
        printf '\n' > "$SANDBOX/proc/42/comm"
        quoted='"?"'
        ;;
      unreadable)
        printf 'hidden\n' > "$SANDBOX/proc/42/comm"
        chmod 000 "$SANDBOX/proc/42/comm"
        quoted='"?"'
        ;;
    esac
    run env HOME="$USER_HOME" TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" \
      bash -c '. "$1"; release_store_live_handles "$2" > "$3" 2> "$4"' \
      live "$RELEASE_STORE_LIB" "$RELEASES/1.0.0" "$SANDBOX/probe.stdout" "$SANDBOX/probe.stderr"
    chmod 600 "$SANDBOX/proc/42/comm"
    [ "$status" -eq 0 ] || { echo "$kind: $output"; false; }
    [ ! -s "$SANDBOX/probe.stdout" ]
    [ "$(wc -l < "$SANDBOX/probe.stderr")" -eq 1 ]
    diagnostic="$(< "$SANDBOX/probe.stderr")"
    [ "$diagnostic" = "trellis release: process check could not inspect 1 processes (1 of uid $(id -u) the kernel will not let it inspect: 42 $quoted); it covers uid $(id -u)'s inspectable processes only" ] ||
      { echo "$kind: $diagnostic"; false; }
    [[ "$diagnostic" != *$'\033'* ]] || false
    [[ "$diagnostic" != *$'\t'* ]] || false
    [[ "$diagnostic" != *$'\n'* ]] || false
    assert_intact 1.0.0
  done
}

@test "remove: lsof records of other users are skipped and counted, ours still hold" {
  probe="$SANDBOX/lsof"
  me="$(id -u)"
  for body in 'printf "p42\\nn/elsewhere\\n"' 'printf "p42\\nf3\\nu%s\\nn/elsewhere\\n" "$(id -u)"' \
    'printf "p42\\nu%s\\nu%s\\nn/elsewhere\\n" "$(id -u)" "$(id -u)"' "printf 'p42\\nu$((me + 1))\\nn/elsewhere\\n'"; do
    printf '#!/bin/sh\n%s\n' "$body" > "$probe"
    chmod 700 "$probe"
    run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"
    [[ "$output" == *"$probe"* ]] || { echo "$output"; false; }
  done
  printf '#!/bin/sh\nprintf "p7\\nu%s\\nn%%s\\np42\\nu%s\\nn%%s\\n" "%s" "%s"\n' \
    "$((me + 1))" "$me" "$RELEASES/1.0.0/payload" "$RELEASES/.exec/1.0.0-$HASH/payload/file" > "$probe"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/.exec/1.0.0-$HASH"
  [[ "$output" != *"running process 7 uses it"* ]] || { echo "$output"; false; }
  printf '#!/bin/sh\nprintf "p7\\nu0\\nn%%s\\np8\\nu%s\\nn%%s\\np42\\nu%s\\nn/elsewhere\\n" "%s" "%s"\n' \
    "$((me + 1))" "$me" "$RELEASES/1.0.0/payload" "$RELEASES/.exec/1.0.0-$HASH/payload/file" > "$probe"
  run sourced 'TRELLIS_TEST_RELEASE_LSOF="$SANDBOX/lsof" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"process check could not inspect 2 processes (2 of other users); it covers uid $me's inspectable processes only"* ]] ||
    { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove fail-closed: owner and journal symlinks or directories are not regular records" {
  printf '{"release":"1.0.0"}\n' > "$SANDBOX/outside.json"
  for relative in state/attachments/checkout/worktree.json state/attachment-journals/pending.json; do
    file="$TRELLIS_HOME/$relative"
    mkdir -p "${file%/*}"
    for kind in link directory; do
      if [ "$kind" = link ]; then ln -s "$SANDBOX/outside.json" "$file"; else mkdir "$file"; fi
      run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
      [ "$status" -eq 4 ] || { echo "$output"; false; }
      [[ "$output" == *"is not a regular file: $file"* ]] || { echo "$output"; false; }
      assert_intact 1.0.0
      [ -f "$SANDBOX/outside.json" ]
      if [ "$kind" = link ]; then rm "${file:?}"; else rmdir "$file"; fi
    done
  done
}

@test "remove: proc maps, cwd, root, executable and descriptors each independently hold a release" {
  proc_fixture
  for member in cwd root exe; do
    rm "${SANDBOX:?}/proc/42/$member"
    ln -s /elsewhere "$SANDBOX/proc/42/$member"
  done
  # No matching links: only maps can make this first refusal.
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
  : > "$SANDBOX/proc/42/maps"
  for member in cwd root exe fd/3; do
    [ "$member" = fd/3 ] || rm "${SANDBOX:?}/proc/42/$member"
    ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/proc/42/$member"
    run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
    assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
    rm "${SANDBOX:?}/proc/42/$member"
    [ "$member" = fd/3 ] || ln -s /elsewhere "$SANDBOX/proc/42/$member"
  done
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove: rerun immediately finishes a dead-owner stage even when no installed entries remain" {
  run sourced '
    eval "original_$(declare -f release_store_remove_entries)"
    release_store_remove_entries() {
      if [ "$1" = finish ]; then
        find "$TRELLIS_HOME/releases/.exec" -type d -exec chmod u+w {} ";"
        rm -rf "${TRELLIS_HOME:?}/releases/.exec/1.0.0-'"$HASH"'"
        rm -f "${TRELLIS_HOME:?}/releases/.exec/.lock.1.0.0-'"$HASH"'" \
          "${TRELLIS_HOME:?}/state/release-stamps/1.0.0-'"$HASH"'.json" \
          "${TRELLIS_HOME:?}/state/exec-stamps/1.0.0-'"$HASH"'.json"
        kill -KILL "$(exec sh -c "echo \$PPID")" $$
      fi
      original_release_store_remove_entries "$@"
    }
    remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 137 ] || { echo "$output"; false; }
  assert_gone 1.0.0
  stage="$(find "$RELEASES" -maxdepth 1 -type d -name '.tmp.remove.1.0.0.*')"
  [ -f "$stage/payload/scripts/blob" ] && [ -f "$stage.owner.json" ]
  run trellis release remove 1.0.0 --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"would remove remove-stage $stage"* ]] || { echo "$output"; false; }
  [ -f "$stage/payload/scripts/blob" ] && [ -f "$stage.owner.json" ]
  # No backdating and no reap-tmp: a validated dead owner is enough.
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed remove-stage $stage"* ]] || { echo "$output"; false; }
  [ ! -e "$stage" ] && [ ! -e "$stage.owner.json" ]
  [ ! -e "$RELEASES/1.0.0.lock" ]
}

@test "remove: resumed stages still refuse references and unanswerable probes without republishing" {
  stage="$RELEASES/.tmp.remove.1.0.0.resume"
  mv "$RELEASES/1.0.0" "$stage"
  printf '{"schema_version":1,"pid":2147483646,"process_birth":"gone"}\n' > "$stage.owner.json"
  chmod 600 "$stage.owner.json"
  mkdir -p "$TRELLIS_HOME/state/attachments/checkout"
  printf '{"release":"1.0.0"}\n' > "$TRELLIS_HOME/state/attachments/checkout/worktree.json"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -f "$stage/payload/scripts/blob" ] && [ ! -e "$RELEASES/1.0.0" ]
  rm "${TRELLIS_HOME:?}/state/attachments/checkout/worktree.json"
  chmod 000 "$TRELLIS_HOME/state/attachments/checkout"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$TRELLIS_HOME/state/attachments/checkout"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ -f "$stage/payload/scripts/blob" ] && [ ! -e "$RELEASES/1.0.0" ]
  (cd "$stage/payload" && exec sleep 600) >/dev/null 2>&1 3>&- &
  LIVE_PID=$!
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"running process $LIVE_PID uses it: $stage"* ]] || { echo "$output"; false; }
  [ -f "$stage/payload/scripts/blob" ] && [ ! -e "$RELEASES/1.0.0" ]
}

@test "remove: stage ownership is revalidated immediately before finishing" {
  stage="$RELEASES/.tmp.remove.1.0.0.resume"
  mv "$RELEASES/1.0.0" "$stage"
  printf '{"schema_version":1,"pid":2147483646,"process_birth":"gone"}\n' > "$stage.owner.json"
  chmod 600 "$stage.owner.json"
  run sourced '
    eval "original_$(declare -f release_store_remove_entries)"
    release_store_remove_entries() {
      original_release_store_remove_entries "$@" || return
      if [ "$1" = plan ]; then
        printf "{\"schema_version\":1,\"pid\":%s,\"process_birth\":\"live\"}\n" "$$" > "$TRELLIS_HOME/releases/.tmp.remove.1.0.0.resume.owner.json"
      fi
    }
    remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"removal stage owner is still live: $stage.owner.json"* ]] || { echo "$output"; false; }
  [ -f "$stage/payload/scripts/blob" ] && [ ! -e "$RELEASES/1.0.0" ]
  [ -d "$RELEASES/.exec/1.0.0-$HASH" ]
}

@test "remove: multiple stages or a stage beside an installed release are ambiguous" {
  first="$RELEASES/.tmp.remove.1.0.0.first"
  second="$RELEASES/.tmp.remove.1.0.0.second"
  mkdir "$first"
  printf '{"schema_version":1,"pid":2147483646,"process_birth":"gone"}\n' > "$first.owner.json"
  chmod 600 "$first.owner.json"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"ambiguous removal stages or installed release"* ]] || false
  assert_intact 1.0.0
  mv "$RELEASES/1.0.0" "$second"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"ambiguous removal stages or installed release"* ]] || false
  [ -d "$first" ] && [ -f "$second/payload/scripts/blob" ]
}

@test "remove: stage recovery refuses absent, malformed, unreadable, linked or live owners" {
  stage="$RELEASES/.tmp.remove.1.0.0.resume"
  mv "$RELEASES/1.0.0" "$stage"
  owner="$stage.owner.json"
  for kind in absent malformed unreadable linked live; do
    case "$kind" in
      absent) ;;
      malformed) printf '{}\n' > "$owner" ;;
      unreadable) printf '{"schema_version":1,"pid":2147483646,"process_birth":"gone"}\n' > "$owner"; chmod 000 "$owner" ;;
      linked) printf '{"schema_version":1,"pid":2147483646,"process_birth":"gone"}\n' > "$SANDBOX/owner.json"; ln -s "$SANDBOX/owner.json" "$owner" ;;
      live) printf '{"schema_version":1,"pid":%s,"process_birth":"alive"}\n' "$$" > "$owner" ;;
    esac
    run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
    expected=4; [ "$kind" != live ] || expected=3
    [ "$status" -eq "$expected" ] || { echo "$kind: $output"; false; }
    [[ "$output" == *"$stage"* ]] || { echo "$output"; false; }
    [ -f "$stage/payload/scripts/blob" ] && [ ! -e "$RELEASES/1.0.0" ]
    while IFS= read -r entry; do
      [ "$entry" = "$RELEASES/1.0.0" ] || [ -e "$entry" ] || { echo "missing: $entry"; false; }
    done < <(entries 1.0.0)
    [ ! -e "$RELEASES/1.0.0.lock" ]
    [ ! -e "$owner" ] && [ ! -L "$owner" ] || { chmod 600 "$owner"; rm "${owner:?}"; }
  done
  printf '{"schema_version":1,"pid":2147483646,"process_birth":"gone"}\n' > "$owner"
  chmod 600 "$owner"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
  [ ! -e "$stage" ] && [ ! -e "$owner" ]
}

@test "remove: dry-run is the default, lists every entry with its size, and writes nothing" {
  before="$(cd "$TRELLIS_HOME" && find . | LC_ALL=C sort)"
  run trellis release remove 1.0.0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  while IFS= read -r entry; do
    [[ "$output" == *"remove: would remove "*" $entry ("*" MiB)"* ]] || { echo "$entry: $output"; false; }
  done < <(entries 1.0.0)
  [[ "$output" == *"remove: would remove release $RELEASES/1.0.0 ("* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: 1.0.0 total entries=5 bytes="* ]] || { echo "$output"; false; }
  [[ "$output" == *"dry-run: nothing removed"* ]] || { echo "$output"; false; }
  [ "$(cd "$TRELLIS_HOME" && find . | LC_ALL=C sort)" = "$before" ]
  run trellis release remove v1.0.0 --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cd "$TRELLIS_HOME" && find . | LC_ALL=C sort)" = "$before" ]
}

@test "remove --apply: deletes the release, snapshot, lock and stamps and nothing of another version" {
  fake_release 1.0.1
  fake_release 1.0.0-rc.1
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"remove: removed release $RELEASES/1.0.0 ("* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: removed exec-snapshot $RELEASES/.exec/1.0.0-$HASH ("* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: 1.0.0 total entries=5 bytes="* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
  assert_intact 1.0.1
  assert_intact 1.0.0-rc.1
  [ -d "$RELEASES/0.0.0/payload" ]
  [ -z "$(cd "$RELEASES" && find . -maxdepth 1 -name '.tmp.remove.*')" ]
  [ ! -e "$RELEASES/1.0.0.lock" ]
  run trellis release remove 1.0.0
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *"release not installed: 1.0.0"* ]] || { echo "$output"; false; }
}

# finish sizes the nonempty stage, moves snapshots into it, then walks it again.
# Linux can miss the inserted snapshots when the walk reuses a directory cursor.
@test "remove finish: sizing a nonempty stage does not hide snapshots inserted before deletion" {
  other_hash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  other_snapshot="$RELEASES/.exec/1.0.0-$other_hash"
  stage_name=.tmp.remove.1.0.0.enumeration
  stage="$RELEASES/$stage_name"
  fake_release 1.0.1
  mkdir -p "$other_snapshot/payload/nested"
  printf 'second snapshot\n' > "$other_snapshot/payload/nested/file"
  printf 'hidden snapshot entry\n' > "$other_snapshot/.hidden"
  : > "$RELEASES/.exec/.lock.1.0.0-$other_hash"
  for area in release-stamps exec-stamps; do
    printf '{}\n' > "$TRELLIS_HOME/state/$area/1.0.0-$other_hash.json"
  done
  chmod -R a-w "$other_snapshot"
  chmod u+w "$RELEASES/1.0.0"
  printf 'original stage entry\n' > "$RELEASES/1.0.0/.hidden"
  chmod a-w "$RELEASES/1.0.0"
  mv "$RELEASES/1.0.0" "$stage"
  run env HOME="$USER_HOME" TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    release_store_write_snapshot_owner "$3" || exit
    release_store_remove_entries finish 1.0.0 "$2" staged
  ' finish "$RELEASE_STORE_LIB" "$stage_name" "$stage"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *$'release\t'"$RELEASES/1.0.0"$'\t'* ]] || false
  for hash in "$HASH" "$other_hash"; do
    [[ "$output" == *$'exec-snapshot\t'"$RELEASES/.exec/1.0.0-$hash"$'\t'* ]] || false
  done
  assert_gone 1.0.0
  for entry in "$stage" "$stage.owner.json" "$other_snapshot" \
    "$RELEASES/.exec/.lock.1.0.0-$other_hash" \
    "$TRELLIS_HOME/state/release-stamps/1.0.0-$other_hash.json" \
    "$TRELLIS_HOME/state/exec-stamps/1.0.0-$other_hash.json"; do
    [ ! -e "$entry" ]
    [ ! -L "$entry" ]
  done
  assert_intact 1.0.1
}

@test "remove: usage errors name the bad option" {
  run trellis release remove 1.0.0 --dry-run --apply
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"remove accepts one of --dry-run or --apply"* ]] || { echo "$output"; false; }
  run trellis release remove 1.0.0 --force
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"unknown remove option: --force"* ]] || { echo "$output"; false; }
  assert_intact 1.0.0
}

@test "remove refuses the active CLI release" {
  run trellis release remove 0.0.0 --apply
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to remove 0.0.0: it is the active CLI release (active_cli_release): $TRELLIS_HOME/config.json"* ]] || { echo "$output"; false; }
  [ -f "$RELEASES/0.0.0/release.json" ]
}

@test "remove refuses while an attachment owner record names the release" {
  mkdir -p "$TRELLIS_HOME/state/attachments/checkout"
  owner="$TRELLIS_HOME/state/attachments/checkout/worktree.json"
  printf '{"release":"1.0.0","project_root":"/elsewhere"}\n' > "$owner"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "attachment owner record: $owner"
}

@test "remove refuses while the user attachment owner record names the release" {
  mkdir -p "$TRELLIS_HOME/attachments"
  printf '{"release":"1.0.0"}\n' > "$TRELLIS_HOME/attachments/user.json"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "attachment owner record: $TRELLIS_HOME/attachments/user.json"
}

@test "remove refuses while a managed Git hook sidecar names the release" {
  mkdir -p "$TRELLIS_HOME/state/git-hooks/checkout"
  sidecar="$TRELLIS_HOME/state/git-hooks/checkout/release-payload"
  printf '%s\n' "$RELEASES/1.0.0/payload" > "$sidecar"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "managed Git hook release-payload sidecar: $sidecar"
  : > "$sidecar"
  run trellis release remove 1.0.0 --apply
  assert_refused 4 "managed Git hook release-payload sidecar is not a non-empty regular file: $sidecar"
}

@test "remove refuses on an owner record it cannot read" {
  mkdir -p "$TRELLIS_HOME/state/attachments/checkout"
  owner="$TRELLIS_HOME/state/attachments/checkout/worktree.json"
  printf '{"release":' > "$owner"
  run trellis release remove 1.0.0 --apply
  assert_refused 4 "attachment owner record is unreadable: $owner"
}

@test "remove refuses unlistable reference directories without deleting the release" {
  [ "$(id -u)" -ne 0 ] || skip 'root bypasses directory permissions'
  local dir label
  for dir in \
    "$TRELLIS_HOME/state/attachments/blocked-checkout" \
    "$TRELLIS_HOME/state/git-hooks/blocked-checkout" \
    "$TRELLIS_HOME/state/attachment-journals" \
    "$TRELLIS_HOME/state/user-attachment-journals" \
    "$TRELLIS_HOME/state/release-adoptions" \
    "$TRELLIS_HOME/attachments"; do
    mkdir -p "$dir"
    # For the attachment case, this is a real owner that the glob cannot see.
    case "$dir" in */state/attachments/*) printf '{"release":"1.0.0"}\n' > "$dir/owner.json" ;; esac
    chmod 000 "$dir"
    run trellis release remove 1.0.0 --apply
    chmod 700 "$dir"
    [ "$status" -eq 4 ] || { echo "$dir: $output"; false; }
    [[ "$output" == *'reference namespace could not be checked'* ]] || { echo "$dir: $output"; false; }
    assert_intact 1.0.0
    # Reset the sentinel owner before the next independent directory case.
    case "$dir" in */state/attachments/*) rm -f "${dir:?}/owner.json" ;; esac
  done
  # Empty, accessible directories are not references and must not block removal.
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove ignores stray non-record files beside reference directories" {
  local owners="$TRELLIS_HOME/state/attachments"
  mkdir -p "$owners/checkout" "$TRELLIS_HOME/state/git-hooks"
  : > "$owners/.DS_Store"
  : > "$TRELLIS_HOME/state/git-hooks/.DS_Store"
  chmod 000 "$owners/.DS_Store"
  printf '{"release":"1.0.0"}\n' > "$owners/checkout/worktree.json"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "attachment owner record: $owners/checkout/worktree.json"
  chmod 000 "$owners/checkout/worktree.json"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 600 "$owners/checkout/worktree.json"
  assert_refused 4 "attachment owner record is unreadable: $owners/checkout/worktree.json"
  rm -f "${owners:?}/checkout/worktree.json"
  ln -s "$SANDBOX" "$owners/.link"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "reference namespace could not be checked: $owners/.link"
  rm -f "${owners:?}/.link"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove refuses while a registry checkout pins the release" {
  register pinned 1.0.0
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "registry release pin of personal/pinned checkout "
}

@test "remove refuses while a runtime anchor points into a snapshot, or is not a link" {
  register snapshotted
  mkdir -p "$SANDBOX/projects/snapshotted/.trellis"
  ln -s "$RELEASES/.exec/1.0.0-$HASH/payload" "$SANDBOX/projects/snapshotted/.trellis/runtime"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "runtime anchor of personal/snapshotted: $SANDBOX/projects/snapshotted/.trellis/runtime"
  rm "$SANDBOX/projects/snapshotted/.trellis/runtime"
  mkdir "$SANDBOX/projects/snapshotted/.trellis/runtime"
  run trellis release remove 1.0.0 --apply
  assert_refused 4 "runtime anchor of personal/snapshotted is not a symlink: $SANDBOX/projects/snapshotted/.trellis/runtime"
}

@test "remove refuses while a registry row fails identity validation" {
  register drifted 0.0.0
  root="$SANDBOX/projects/drifted"
  mv "$root" "$root.old"
  git init -q -b main "$SANDBOX/other"
  git -C "$SANDBOX/other" -c user.email=f@example.invalid -c user.name=f commit -q --allow-empty -m other
  git -C "$SANDBOX/other" worktree add -q "$root"
  run trellis release remove 1.0.0 --apply
  assert_refused 4 "registry row of personal/drifted failed identity validation: $root"
}

@test "remove refuses while a registered runtime anchor points into the release" {
  register anchored
  mkdir -p "$SANDBOX/projects/anchored/.trellis"
  ln -s "$RELEASES/1.0.0/payload" "$SANDBOX/projects/anchored/.trellis/runtime"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "runtime anchor of personal/anchored: $SANDBOX/projects/anchored/.trellis/runtime"
}

@test "remove refuses for an unavailable registry row that records the release or no release" {
  register elsewhere 0.0.0
  mv "$SANDBOX/projects/elsewhere" "$SANDBOX/projects/elsewhere.moved"
  register unknown ''
  mv "$SANDBOX/projects/unknown" "$SANDBOX/projects/unknown.moved"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "unavailable registry row of personal/unknown records no release, so it may still use it: $SANDBOX/projects/unknown"
  [[ "$output" != *"personal/elsewhere"* ]] || { echo "$output"; false; }

  register gone 1.0.0
  mv "$SANDBOX/projects/gone" "$SANDBOX/projects/gone.moved"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "unavailable registry row of personal/gone records this release: $SANDBOX/projects/gone"
}

@test "remove: an unavailable registry row recording another release does not block" {
  register elsewhere 0.0.0
  mv "$SANDBOX/projects/elsewhere" "$SANDBOX/projects/elsewhere.moved"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove refuses while a project config pins trellis_version to the release" {
  register configured
  config="$SANDBOX/projects/configured/.trellis.config.json"
  printf '{"trellis_version":"v1.0.0"}\n' > "$config"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "project config trellis_version pin of personal/configured: $config"
}

@test "remove refuses on a project config it cannot read as one object with a string pin" {
  register configured
  config="$SANDBOX/projects/configured/trellis.config.json"
  for body in '' '{"trellis_version":1}' '[]'; do
    printf '%s' "$body" > "$config"
    run trellis release remove 1.0.0 --apply
    assert_refused 4 "project config of personal/configured is unreadable: $config"
  done
  rm "$config"
  printf '{"trellis_version":"1.0.0"}\n' > "$SANDBOX/elsewhere.json"
  ln -s "$SANDBOX/elsewhere.json" "$config"
  run trellis release remove 1.0.0 --apply
  assert_refused 4 "project config of personal/configured is not a regular file: $config"
}

@test "remove refuses while a pending attachment journal references the release" {
  mkdir -p "$TRELLIS_HOME/state/attachment-journals"
  journal="$TRELLIS_HOME/state/attachment-journals/detach-x.json"
  jq -n --arg path "$RELEASES/1.0.0/payload/core-rules/CLAUDE.md" \
    '{phase:1, original_owner:{release:"0.0.0", artifacts:[{target:$path}]}}' > "$journal"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "pending attachment journal: $journal"
}

@test "remove refuses while a pending user attachment journal references the release" {
  mkdir -p "$TRELLIS_HOME/state/user-attachment-journals"
  journal="$TRELLIS_HOME/state/user-attachment-journals/attach.json"
  printf '{"release":"1.0.0","phase":0}\n' > "$journal"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "pending attachment journal: $journal"
}

@test "remove refuses while a pending adoption journal moves to or from the release" {
  mkdir -p "$TRELLIS_HOME/state/release-adoptions/checkout"
  plans="$TRELLIS_HOME/state/release-adoptions/checkout/plans.jsonl"
  printf '%s\n' '{"old_version":"0.0.0","new_version":"1.0.1"}' '{"old_version":"1.0.0","new_version":"1.0.1"}' > "$plans"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "pending adoption journal: $plans"
}

@test "remove refuses while a running process works inside the release or a snapshot" {
  (cd "$RELEASES/1.0.0/payload" && exec sleep 600) >/dev/null 2>&1 3>&- &
  LIVE_PID=$!
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "running process $LIVE_PID uses it: $RELEASES/1.0.0"
  kill "$LIVE_PID"
  (cd "$RELEASES/.exec/1.0.0-$HASH/payload" && exec sleep 600) >/dev/null 2>&1 3>&- &
  LIVE_PID=$!
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "running process $LIVE_PID uses it: $RELEASES/.exec/1.0.0-$HASH"
}

@test "remove refuses while the release store lock is held, and clears one a dead remover left" {
  mkdir "$RELEASES/1.0.0.lock"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"the release store lock is held (an install or removal is in progress): $RELEASES/1.0.0.lock"* ]] || { echo "$output"; false; }
  assert_intact 1.0.0
  # A removal lock whose owner is gone is cleared; an install lock never is.
  jq -cn '{schema_version:1,pid:2147483646,process_birth:"Thu Jan  1 00:00:00 1970"}' \
    > "$RELEASES/1.0.0.lock/remove.owner.json"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"clearing the removal lock a dead process left"* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
  [ ! -e "$RELEASES/1.0.0.lock" ]
}

@test "remove: a removal lock with an invalid pid or a live, padded birth is held" {
  mkdir "$RELEASES/1.0.0.lock"
  for pid in 1.5 -5 0; do
    jq -cn --argjson pid "$pid" '{schema_version:1,pid:$pid,process_birth:"Thu Jan  1 00:00:00 1970"}' \
      > "$RELEASES/1.0.0.lock/remove.owner.json"
    run trellis release remove 1.0.0 --apply
    [ "$status" -eq 3 ] || { echo "pid $pid: $output"; false; }
    [[ "$output" == *"the release store lock is held"* ]] || { echo "pid $pid: $output"; false; }
    assert_intact 1.0.0
  done
  sleep 600 >/dev/null 2>&1 3>&- &
  LIVE_PID=$!
  birth="$(bash -c '. "$1"; release_store_process_birth "$2"' birth "$RELEASE_STORE_LIB" "$LIVE_PID")"
  [ -n "$birth" ]
  jq -cn --argjson pid "$LIVE_PID" --arg birth "  $birth  " '{schema_version:1,pid:$pid,process_birth:$birth}' \
    > "$RELEASES/1.0.0.lock/remove.owner.json"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"the release store lock is held"* ]] || { echo "$output"; false; }
  assert_intact 1.0.0
}

@test "remove: dry-run treats a dead remover's lock as --apply does" {
  mkdir "$RELEASES/1.0.0.lock"
  jq -cn '{schema_version:1,pid:2147483646,process_birth:"Thu Jan  1 00:00:00 1970"}' \
    > "$RELEASES/1.0.0.lock/remove.owner.json"
  run trellis release remove 1.0.0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"remove: --apply clears the removal lock a dead process left: $RELEASES/1.0.0.lock"* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: would remove release $RELEASES/1.0.0 "* ]] || { echo "$output"; false; }
  [ -f "$RELEASES/1.0.0.lock/remove.owner.json" ]
}

@test "remove: a crash while taking the lock never leaves an empty lock behind" {
  run sourced '
    eval "original_$(declare -f release_store_write_snapshot_owner)"
    release_store_write_snapshot_owner() {
      case "$1" in */remove) kill -KILL "$(exec sh -c "echo \$PPID")" $$ ;; esac
      original_release_store_write_snapshot_owner "$@"
    }
    remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 137 ] || { echo "status $status: $output"; false; }
  [ ! -e "$RELEASES/1.0.0.lock" ]
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "remove refuses a symlinked release, snapshot or stamp and touches neither link nor target" {
  outside="$SANDBOX/outside"
  mkdir -p "$outside/payload"
  printf 'keep\n' > "$outside/payload/file"
  fake_release 1.0.2
  chmod u+w "$RELEASES"
  find "$RELEASES/1.0.2" -depth -type d -exec chmod u+w {} \;
  rm -rf "$RELEASES/1.0.2"
  ln -s "$outside" "$RELEASES/1.0.2"
  run trellis release remove 1.0.2 --apply
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to remove 1.0.2: release is a symlink or not a directory: $RELEASES/1.0.2"* ]] || { echo "$output"; false; }
  [ -L "$RELEASES/1.0.2" ] && [ -f "$outside/payload/file" ]

  find "$RELEASES/.exec/1.0.0-$HASH" -depth -type d -exec chmod u+w {} \;
  rm -rf "$RELEASES/.exec/1.0.0-$HASH"
  ln -s "$outside" "$RELEASES/.exec/1.0.0-$HASH"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"execution snapshot is a symlink or not a directory: $RELEASES/.exec/1.0.0-$HASH"* ]] || { echo "$output"; false; }
  [ -L "$RELEASES/.exec/1.0.0-$HASH" ] && [ -f "$outside/payload/file" ] && [ -d "$RELEASES/1.0.0/payload" ]

  rm "$RELEASES/.exec/1.0.0-$HASH"
  stamp="$TRELLIS_HOME/state/release-stamps/1.0.0-$HASH.json"
  rm "$stamp"
  ln -s "$outside/payload/file" "$stamp"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"stamp is a symlink or not a regular file: $stamp"* ]] || { echo "$output"; false; }
  [ -L "$stamp" ] && [ -f "$outside/payload/file" ] && [ -d "$RELEASES/1.0.0/payload" ]
}

@test "remove --apply deletes a link inside the release as a link, never its target" {
  outside="$SANDBOX/outside"
  mkdir -p "$outside/tree"
  printf 'keep\n' > "$outside/tree/file"
  chmod u+w "$RELEASES/1.0.0/payload"
  ln -s "$outside/tree" "$RELEASES/1.0.0/payload/link"
  chmod a-w "$RELEASES/1.0.0/payload"
  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_gone 1.0.0
  [ -f "$outside/tree/file" ]
}

@test "remove: an interrupted apply is finished by reap-tmp --fix and a rerun" {
  run sourced '
    eval "original_$(declare -f release_store_remove_entries)"
    release_store_remove_entries() {
      [ "$1" != finish ] || kill -KILL "$(exec sh -c "echo \$PPID")" $$
      original_release_store_remove_entries "$@"
    }
    remove_release "$TRELLIS_HOME" 1.0.0 apply'
  [ "$status" -eq 137 ] || { echo "status $status: $output"; false; }
  [ ! -e "$RELEASES/1.0.0" ]
  stage="$(cd "$RELEASES" && find . -maxdepth 1 -type d -name '.tmp.remove.1.0.0.*')"
  stage="$RELEASES/${stage#./}"
  [ -f "$stage/payload/scripts/blob" ] && [ -f "$stage.owner.json" ]
  [ -f "$RELEASES/1.0.0.lock/remove.owner.json" ]

  backdate 7200 "$stage" "$stage.owner.json"
  run trellis release reap-tmp --fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed dir ${stage##*/} "*"owner=dead"* ]] || { echo "$output"; false; }
  [ ! -e "$stage" ] && [ ! -e "$stage.owner.json" ]

  run trellis release remove 1.0.0 --apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"clearing the removal lock a dead process left"* ]] || { echo "$output"; false; }
  [[ "$output" == *"remove: 1.0.0 total entries=4 "* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
  [ ! -e "$RELEASES/1.0.0.lock" ]
}

# race TARGET: during --apply, right after the release is renamed to its stage,
# bind a registered project's runtime anchor to TARGET, evaluated with $2 set to
# the stage, as a concurrent adoption would.
race() {
  register racer
  RACE_TARGET="$1" run sourced '
    eval "original_$(declare -f release_store_rename_no_clobber)"
    release_store_rename_no_clobber() {
      original_release_store_rename_no_clobber "$@" || return
      case "$2" in
        */.tmp.remove.*)
          mkdir -p "$PROJECT/.trellis"
          ln -s "$(eval "printf %s \"$RACE_TARGET\"")" "$PROJECT/.trellis/runtime"
          ;;
      esac
    }
    remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "runtime anchor of personal/racer: $SANDBOX/projects/racer/.trellis/runtime"
}

@test "remove --apply puts the release back when a reference appears after the first check" {
  race '$TRELLIS_HOME/releases/1.0.0/payload'
}

@test "remove --apply re-check resolves a relative anchor target once the release is staged" {
  race '../../../trellis/releases/1.0.0/payload'
}

@test "remove --apply re-check resolves a symlinked prefix, // and a trailing slash" {
  ln -s "$SANDBOX" "$SANDBOX/alias"
  race '$SANDBOX/alias//trellis/releases/./1.0.0/payload/'
}

@test "remove --apply re-check counts a target inside the removal stage" {
  race '$2/payload'
}

@test "remove compares references against the canonical home, not the alias it was given" {
  ln -s "$SANDBOX" "$SANDBOX/alias"
  mkdir -p "$TRELLIS_HOME/state/attachment-journals"
  journal="$TRELLIS_HOME/state/attachment-journals/attach.json"
  jq -n --arg path "$RELEASES/1.0.0/payload" '{phase:0, target:$path}' > "$journal"
  run sourced 'remove_release "$SANDBOX/alias/trellis" 1.0.0 apply'
  assert_refused 3 "pending attachment journal: $journal"
}

@test "lsof failure or malformed output refuses, with other users scoped out" {
  [ "$(id -u)" -ne 0 ] || skip 'fixture needs a different UID'
  local fake="$SANDBOX/lsof-fixture" uid
  uid="$(id -u)"
  cat > "$fake" <<'SH'
#!/bin/bash
case "$LSOF_MODE" in
  fail) exit 42 ;;
  malformed) printf 'pbad\n'; exit 0 ;;
  empty) exit 0 ;;
  no-names) printf 'p42\nu%s\n' "$LSOF_UID"; exit 0 ;;
  partial) printf 'p42\nu%s\nfcwd\nn/elsewhere\n' "$LSOF_UID"; printf 'partial snapshot\n' >&2; exit 0 ;;
  held) own="$LSOF_RELEASE" ;;
  *) own=/elsewhere ;;
esac
printf 'p42\nu%s\nfcwd\nn%s\np43\nu0\nfcwd\nn%s\n' "$LSOF_UID" "$own" "$LSOF_RELEASE"
SH
  chmod 755 "$fake"
  for mode in fail malformed empty no-names partial; do
    run env TRELLIS_TEST_RELEASE_LSOF="$fake" LSOF_MODE="$mode" LSOF_UID="$uid" LSOF_RELEASE="$RELEASES/1.0.0" \
      bash -c '. "$1"; release_store_live_handles "$2"' _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
    [ "$status" -eq 4 ] || { echo "$mode: $output"; false; }
  done
  run env TRELLIS_TEST_RELEASE_LSOF="$fake" LSOF_MODE=clear LSOF_UID="$uid" LSOF_RELEASE="$RELEASES/1.0.0" \
    bash -c '. "$1"; release_store_live_handles "$2"' _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  [ "$status" -eq 0 ] && [[ "$output" == *'1 of other users'* ]] || { echo "$output"; false; }
  [[ "$output" != *$'43\t'* ]] || { echo "$output"; false; }
  run env TRELLIS_TEST_RELEASE_LSOF="$fake" LSOF_MODE=held LSOF_UID="$uid" LSOF_RELEASE="$RELEASES/1.0.0" \
    bash -c '. "$1"; release_store_live_handles "$2"' _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  [ "$status" -eq 0 ] && [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }
}

@test "proc permission errors skip a PID with its comm and retain known holders" {
  [ "$(id -u)" -ne 0 ] || skip 'root bypasses fixture permissions'
  local proc="$SANDBOX/scoped-proc" member program error
  mkdir -p "$proc/42/fd" "$proc/43/fd"
  for pid in 42 43; do
    printf 'fixture-%s\n' "$pid" > "$proc/$pid/comm"
    ln -s / "$proc/$pid/cwd"; ln -s / "$proc/$pid/root"; ln -s /bin/sleep "$proc/$pid/exe"
    : > "$proc/$pid/maps"
    # Live (state S), so an absent member is not read as an exited PID.
    mkdir -p "$proc/$pid/task/$pid"
    printf '%s (fixture-%s) S 1 %s %s 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0\n' "$pid" "$pid" "$pid" "$pid" > "$proc/$pid/stat"
  done
  ln -s "$RELEASES/1.0.0" "$proc/42/fd/3"
  ln -s /elsewhere "$proc/43/fd/3"
  for member in fd maps; do
    chmod 000 "$proc/43/$member"
    run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
      _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
    chmod 700 "$proc/43/$member"
    [ "$status" -eq 0 ] && [[ "$output" == *'43'*'fixture-43'* ]] || { echo "$member: $output"; false; }
    [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }
  done
  # A readable but unsearchable fd directory makes readlink(fd/3) fail.
  chmod 400 "$proc/43/fd"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  chmod 700 "$proc/43/fd"
  [ "$status" -eq 0 ] && [[ "$output" == *'43'*'fixture-43'* ]] || { echo "$output"; false; }

  # A positive holder discovered before a later maps denial is still a holder.
  chmod 000 "$proc/42/maps"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  chmod 600 "$proc/42/maps"
  [ "$status" -eq 0 ] && [[ "$output" == *'42'*'fixture-42'* ]] && \
    [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }

  # The Linux replay saw EACCES on cwd even with a readable fd directory.
  # Inject both errno values at the actual embedded readlink call on macOS.
  program="$SANDBOX/proc-program.py"
  awk '/^  "\$python_bin" -I - .*TRELLIS_TEST_RELEASE_PROC_ROOT/ {inside=1; next} inside && /^PY$/ {exit} inside {print}' "$RELEASE_STORE_LIB" > "$program"
  [ -s "$program" ]
  # A descriptor can close after listdir while its process remains alive.
  # ENOENT for that individual descriptor is benign and other holders count.
  ln -s /elsewhere "$proc/43/fd/7"
  run python3 -I -c '
import errno, os, sys
program = sys.argv[4]
del sys.argv[4:]
original = os.readlink
def injected(path, *args, **kwargs):
    if path == os.path.join(sys.argv[1], "43", "fd", "7"):
        raise FileNotFoundError(errno.ENOENT, "descriptor closed", path)
    return original(path, *args, **kwargs)
os.readlink = injected
with open(program, encoding="utf-8") as source:
    exec(compile(source.read(), program, "exec"), {"__name__": "__main__"})
' "$proc" '' "$RELEASES/1.0.0" "$program"
  [ "$status" -eq 0 ] && [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }
  rm -f "${proc:?}/43/fd/7"
  for error in EACCES EPERM; do
    for member in cwd root exe fd/3; do
      run python3 -I -c '
import errno, os, sys
program, error, member = sys.argv[4:7]
del sys.argv[4:]
original = os.readlink
def injected(path, *args, **kwargs):
    if path == os.path.join(sys.argv[1], "43", member):
        raise OSError(getattr(errno, error), "injected", path)
    return original(path, *args, **kwargs)
os.readlink = injected
with open(program, encoding="utf-8") as source:
    exec(compile(source.read(), program, "exec"), {"__name__": "__main__"})
' "$proc" '' "$RELEASES/1.0.0" "$program" "$error" "$member"
      [ "$status" -eq 0 ] && [[ "$output" == *'43'*'fixture-43'* ]] || { echo "$error $member: $output"; false; }
      [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }
    done
  done

  # A readable PID is not excluded merely because fd ownership appears to be
  # another UID. This kills a reintroduced fd-owner prefilter.
  run python3 -I -c '
import os, sys, types
program = sys.argv[4]
del sys.argv[4:]
original = os.stat
def injected(path, *args, **kwargs):
    if path == os.path.join(sys.argv[1], "42", "fd"):
        return types.SimpleNamespace(st_uid=os.geteuid() + 1)
    return original(path, *args, **kwargs)
os.stat = injected
with open(program, encoding="utf-8") as source:
    exec(compile(source.read(), program, "exec"), {"__name__": "__main__"})
' "$proc" '' "$RELEASES/1.0.0" "$program"
  [ "$status" -eq 0 ] && [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }

  # A denied PID ownership stat is still a per-PID permission error; an
  # identifiable other-user PID is counted without inspecting its files.
  for error in EACCES EPERM; do
    run python3 -I -c '
import errno, os, sys
program, error = sys.argv[4:6]
del sys.argv[4:]
original = os.stat
def injected(path, *args, **kwargs):
    if path == os.path.join(sys.argv[1], "43"):
        raise OSError(getattr(errno, error), "injected", path)
    return original(path, *args, **kwargs)
os.stat = injected
with open(program, encoding="utf-8") as source:
    exec(compile(source.read(), program, "exec"), {"__name__": "__main__"})
' "$proc" '' "$RELEASES/1.0.0" "$program" "$error"
    [ "$status" -eq 0 ] && [[ "$output" == *'43'*'fixture-43'* ]] || { echo "$error: $output"; false; }
  done
  run python3 -I -c '
import os, sys, types
program = sys.argv[4]
del sys.argv[4:]
original = os.stat
def injected(path, *args, **kwargs):
    if path == os.path.join(sys.argv[1], "43"):
        return types.SimpleNamespace(st_uid=os.geteuid() + 1)
    return original(path, *args, **kwargs)
os.stat = injected
with open(program, encoding="utf-8") as source:
    exec(compile(source.read(), program, "exec"), {"__name__": "__main__"})
' "$proc" '' "$RELEASES/1.0.0" "$program"
  [ "$status" -eq 0 ] && [[ "$output" == *'1 of other users'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'42\t'"$RELEASES/1.0.0"* ]] || { echo "$output"; false; }

  # A process controls comm; terminal escapes must be quoted, not emitted.
  printf 'unsafe\033[31m\n' > "$proc/43/comm"
  chmod 000 "$proc/43/maps"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  chmod 600 "$proc/43/maps"
  [ "$status" -eq 0 ] && [[ "$output" == *'\u001b'* ]] && [[ "$output" != *$'\033'* ]] || { echo "$output"; false; }
  printf 'fixture-43\n' > "$proc/43/comm"

  # If comm itself is permission-denied, identify the PID without inventing a
  # name: the release-store probe prints "?" for an unreadable comm.
  chmod 000 "$proc/43/comm" "$proc/43/maps"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  chmod 600 "$proc/43/comm" "$proc/43/maps"
  [ "$status" -eq 0 ] && [[ "$output" == *'43 "?"'* ]] && [[ "$output" != *'fixture-43'* ]] || { echo "$output"; false; }

  # With no visible holder, a permission-denied process is advisory, not a
  # refusal: the actual remove succeeds and prints the skipped PID and comm.
  rm -f "${proc:?}/42/fd/3"
  chmod 000 "$proc/43/fd"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/scoped-proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  chmod 700 "$proc/43/fd"
  [ "$status" -eq 0 ] && [[ "$output" == *'43'*'fixture-43'* ]] || { echo "$output"; false; }
  assert_gone 1.0.0
}

@test "proc missing live members and non-permission errors refuse, while vanished PIDs are benign" {
  local proc="$SANDBOX/scoped-proc" member
  mkdir -p "$proc/42/fd" "$proc/42/task/42"
  printf 'fixture-42\n' > "$proc/42/comm"
  ln -s / "$proc/42/cwd"; ln -s / "$proc/42/root"; ln -s /bin/sleep "$proc/42/exe"
  : > "$proc/42/maps"
  # Live (state S): without a stat the probe reads 42 as exited and every
  # missing-member assertion below would turn benign.
  printf '42 (fixture-42) S 1 42 42 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0\n' > "$proc/42/stat"
  if [ "$(id -u)" -ne 0 ]; then
    for mode in 000 400 100; do
      chmod "$mode" "$proc"
      run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
        _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
      chmod 700 "$proc"
      [ "$status" -eq 4 ] || { echo "proc mode $mode: $output"; false; }
    done
  fi
  for member in fd maps; do
    mv "$proc/42/$member" "$proc/42/$member.saved"
    run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
      _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
    mv "$proc/42/$member.saved" "$proc/42/$member"
    [ "$status" -eq 4 ] || { echo "$member: $output"; false; }
  done
  rm -f "${proc:?}/42/cwd"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  printf 'not a link\n' > "$proc/42/cwd"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  rm -f "${proc:?}/42/cwd"
  mv "$proc/42" "$SANDBOX/exited-pid"
  ln -s "$SANDBOX/vanished-pid" "$proc/42"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2"' \
    _ "$RELEASE_STORE_LIB" "$RELEASES/1.0.0"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "remove: a process check that cannot answer refuses, and /proc is read on Linux" {
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$TRELLIS_HOME/no-proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 4 "running processes could not be checked: $RELEASES/1.0.0"

  proc="$SANDBOX/proc"
  mkdir -p "$proc/41/fd" "$proc/42/fd" "$proc/self"
  for pid in 41 42; do
    ln -s / "$proc/$pid/root"
    ln -s /bin/sleep "$proc/$pid/exe"
    : > "$proc/$pid/maps"
  done
  ln -s / "$proc/41/cwd"
  ln -s "$RELEASES/.exec/1.0.0-$HASH/payload/file (deleted)" "$proc/41/fd/3"
  ln -s "$RELEASES/1.0.0" "$proc/42/cwd"
  printf '7f00-7f01 r-xp 0 01:02 3 %s\n' "$RELEASES/1.0.0/payload/scripts/blob" > "$proc/42/maps"
  run env TRELLIS_TEST_RELEASE_PROC_ROOT="$proc" bash -c '. "$1"; release_store_live_handles "$2" "$3" "$4"' \
    live "$RELEASE_STORE_LIB" "$RELEASES/1.0.0" "$RELEASES/.exec/1.0.0-$HASH" "$RELEASES/1.0.1"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '41\t%s\n42\t%s' "$RELEASES/.exec/1.0.0-$HASH" "$RELEASES/1.0.0")" ] || { echo "$output"; false; }
}

# APFS and HFS+ are case-insensitive by default: Releases/1.0.0 is the release
# itself. A case-variant spelling of a path or version must still count, on
# any volume, rather than be ruled out by a byte comparison.
@test "remove fail-closed: case-variant paths in an anchor, journal, sidecar and process still hold" {
  upper=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  register anchored
  mkdir -p "$SANDBOX/projects/anchored/.trellis"
  ln -s "$TRELLIS_HOME/Releases/1.0.0/payload" "$SANDBOX/projects/anchored/.trellis/runtime"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "runtime anchor of personal/anchored: $SANDBOX/projects/anchored/.trellis/runtime"
  rm "${SANDBOX:?}/projects/anchored/.trellis/runtime"

  mkdir -p "$TRELLIS_HOME/state/attachment-journals"
  journal="$TRELLIS_HOME/state/attachment-journals/attach.json"
  jq -n --arg path "$TRELLIS_HOME/RELEASES/1.0.0/payload" '{phase:0, target:$path}' > "$journal"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "pending attachment journal: $journal"
  jq -n --arg path "$RELEASES/.exec/1.0.0-$upper/payload" '{phase:0, target:$path}' > "$journal"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "pending attachment journal: $journal"
  rm "${journal:?}"

  sidecar="$TRELLIS_HOME/state/git-hooks/review/release-payload"
  mkdir -p "${sidecar%/*}"
  printf '%s\n' "$TRELLIS_HOME/RELEASES/.exec/1.0.0-$upper/payload" > "$sidecar"
  run trellis release remove 1.0.0 --apply
  assert_refused 3 "managed Git hook release-payload sidecar: $sidecar"
  rm "${sidecar:?}"

  proc_fixture
  : > "$SANDBOX/proc/42/maps"
  rm "${SANDBOX:?}/proc/42/cwd"
  ln -s "$TRELLIS_HOME/Releases/1.0.0/payload" "$SANDBOX/proc/42/cwd"
  run sourced 'TRELLIS_TEST_RELEASE_PROC_ROOT="$SANDBOX/proc" remove_release "$TRELLIS_HOME" 1.0.0 apply'
  assert_refused 3 "running process 42 uses it: $RELEASES/1.0.0"
}

@test "remove fail-closed: a case-variant version in an owner record, pin or config still holds" {
  fake_release 1.0.0-rc.1
  refused() {
    [ "$status" -eq 3 ] || { echo "status $status: $output"; false; }
    [[ "$output" == *"refusing to remove 1.0.0-rc.1: $1"* ]] || { echo "$output"; false; }
    assert_intact 1.0.0-rc.1
  }
  mkdir -p "$TRELLIS_HOME/state/attachments/checkout"
  owner="$TRELLIS_HOME/state/attachments/checkout/worktree.json"
  printf '{"release":"1.0.0-RC.1"}\n' > "$owner"
  run trellis release remove 1.0.0-rc.1 --apply
  refused "attachment owner record: $owner"
  rm "${owner:?}"

  config="$TRELLIS_HOME/config.json"
  cp "$config" "$SANDBOX/config.saved"
  jq '.active_cli_release = "1.0.0-RC.1"' "$SANDBOX/config.saved" > "$config"
  run sourced 'remove_release "$TRELLIS_HOME" 1.0.0-rc.1 apply'
  cp "$SANDBOX/config.saved" "$config"
  refused "it is the active CLI release (active_cli_release): $config"

  register pinned 1.0.0-RC.1
  run trellis release remove 1.0.0-rc.1 --apply
  refused "registry release pin of personal/pinned checkout "
  printf '{"trellis_version":"v1.0.0-Rc.1"}\n' > "$SANDBOX/projects/pinned/.trellis.config.json"
  run trellis release remove 1.0.0-rc.1 --apply
  refused "project config trellis_version pin of personal/pinned: $SANDBOX/projects/pinned/.trellis.config.json"
}
