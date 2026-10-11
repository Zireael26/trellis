#!/usr/bin/env bats
# `trellis release reap-tmp` (spec 067 §6.3, ruling R6) and its doctor row.
# Every case runs against a fake TRELLIS_HOME under the test tmpdir.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"
HEALTH_LIB="$REPO_ROOT/scripts/lib/health-checks.sh"
EPOCH_BIRTH='Thu Jan  1 00:00:00 1970'

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/reap.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  RELEASES="$TRELLIS_HOME/releases"
  mkdir -p "$RELEASES/1.0.0/payload" "$SANDBOX/outside"
  printf 'installed\n' > "$RELEASES/1.0.0/payload/VERSION"
  LIVE_PID=""
}

teardown() {
  [ -z "${LIVE_PID:-}" ] || kill "$LIVE_PID" 2>/dev/null || true
  find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
  rm -rf "$SANDBOX"
}

reap() {
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_reap_tmp "$2"' \
    reap "$RELEASE_STORE_LIB" "$1"
}

doctor_row() {
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; . "$2"; hc_release_tmp_scratch "$3"' \
    doctor-row "$RELEASE_STORE_LIB" "$HEALTH_LIB" "$TRELLIS_HOME"
}

# backdate SECONDS PATH...: set mtime SECONDS ago without following links.
backdate() {
  python3 - "$@" <<'PY'
import os, sys, time
when = time.time() - int(sys.argv[1])
for path in sys.argv[2:]:
    if os.path.lexists(path):
        os.utime(path, (when, when), follow_symlinks=False)
PY
}

# scratch NAME AGE [PID BIRTH]: a scratch dir aged AGE seconds; with PID, its
# sibling owner record in the exec-snapshot format, aged the same.
scratch() {
  mkdir -p "$RELEASES/$1/payload"
  printf 'x\n' > "$RELEASES/$1/payload/file"
  if [ "$#" -ge 4 ]; then
    jq -cn --argjson pid "$3" --arg birth "$4" \
      '{schema_version:1,pid:$pid,process_birth:$birth}' > "$RELEASES/$1.owner.json"
  fi
  backdate "$2" "$RELEASES/$1" "$RELEASES/$1.owner.json"
}

dead_pid() {
  sleep 0 &
  local pid=$!
  wait "$pid"
  printf '%s\n' "$pid"
}

start_live_owner() {
  sleep 600 >/dev/null 2>&1 3>&- &
  LIVE_PID=$!
  LIVE_BIRTH="$(bash -c '. "$1"; release_store_process_birth "$2"' birth "$RELEASE_STORE_LIB" "$LIVE_PID")"
  [ -n "$LIVE_BIRTH" ]
}

@test "reap-tmp: dry-run lists each candidate and totals and removes nothing" {
  scratch .tmp.1.0.0.exec.old 7200 "$(dead_pid)" "$EPOCH_BIRTH"
  scratch .tmp.1.0.0.verify.new 60
  before="$(cd "$RELEASES" && find . | LC_ALL=C sort)"
  run reap dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"reapable dir .tmp.1.0.0.exec.old age="*" owner=dead bytes="* ]] || { echo "$output"; false; }
  [[ "$output" == *"keep dir .tmp.1.0.0.verify.new age="*" owner=none bytes="* ]] || { echo "$output"; false; }
  [[ "$output" == *"total entries=2 bytes="*" reapable=1 "*"nothing removed"* ]] || { echo "$output"; false; }
  [ "$(cd "$RELEASES" && find . | LC_ALL=C sort)" = "$before" ]
}

@test "reap-tmp --fix: a dead owner's sealed scratch over 1 h goes with its owner file, nothing else does" {
  scratch .tmp.1.0.0.exec.dead 7200 "$(dead_pid)" "$EPOCH_BIRTH"
  # Exec snapshots and stages are sealed read-only, like this one.
  find "$RELEASES/.tmp.1.0.0.exec.dead" -depth -type d -exec chmod 500 {} \;
  run reap fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed dir .tmp.1.0.0.exec.dead "*"owner=dead"* ]] || { echo "$output"; false; }
  [[ "$output" == *"total entries=1 "*"removed=1 "* ]] || { echo "$output"; false; }
  [ ! -e "$RELEASES/.tmp.1.0.0.exec.dead" ]
  [ ! -e "$RELEASES/.tmp.1.0.0.exec.dead.owner.json" ]
  [ -f "$RELEASES/1.0.0/payload/VERSION" ]
}

@test "reap-tmp --fix: a live owner keeps its scratch at any age" {
  start_live_owner
  scratch .tmp.1.0.0.exec.live 90000 "$LIVE_PID" "$LIVE_BIRTH"
  run reap fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"keep dir .tmp.1.0.0.exec.live "*"owner=alive"* ]] || { echo "$output"; false; }
  [ -d "$RELEASES/.tmp.1.0.0.exec.live" ]
  [ -f "$RELEASES/.tmp.1.0.0.exec.live.owner.json" ]
}

@test "reap-tmp --fix: a reused pid (live pid, different birth) counts as dead" {
  start_live_owner
  scratch .tmp.1.0.0.exec.reused 7200 "$LIVE_PID" "$EPOCH_BIRTH"
  run reap fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed dir .tmp.1.0.0.exec.reused "*"owner=dead"* ]] || { echo "$output"; false; }
  [ ! -e "$RELEASES/.tmp.1.0.0.exec.reused" ]
}

@test "reap-tmp --fix: a dead owner aged 15 min is kept, at 61 min it is removed" {
  pid="$(dead_pid)"
  scratch .tmp.1.0.0.exec.young 900 "$pid" "$EPOCH_BIRTH"
  scratch .tmp.1.0.0.exec.old 3660 "$pid" "$EPOCH_BIRTH"
  run reap fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"keep dir .tmp.1.0.0.exec.young "*"owner=dead"* ]] || { echo "$output"; false; }
  [ -d "$RELEASES/.tmp.1.0.0.exec.young" ]
  [ -f "$RELEASES/.tmp.1.0.0.exec.young.owner.json" ]
  [ ! -e "$RELEASES/.tmp.1.0.0.exec.old" ]
}

@test "reap-tmp --fix: no or malformed owner record keeps scratch for 24 h" {
  scratch .tmp.1.0.0.verify.h23 82800
  scratch .tmp.1.0.0.verify.h25 90000
  scratch .tmp.1.0.0.verify.bad 7200
  scratch .tmp.1.0.0.verify.bad25 90000
  printf '{"pid":' > "$RELEASES/.tmp.1.0.0.verify.bad.owner.json"
  printf '{"pid":' > "$RELEASES/.tmp.1.0.0.verify.bad25.owner.json"
  backdate 7200 "$RELEASES/.tmp.1.0.0.verify.bad" "$RELEASES/.tmp.1.0.0.verify.bad.owner.json"
  backdate 90000 "$RELEASES/.tmp.1.0.0.verify.bad25" "$RELEASES/.tmp.1.0.0.verify.bad25.owner.json"
  run reap fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"keep dir .tmp.1.0.0.verify.h23 "*"owner=none"* ]] || { echo "$output"; false; }
  [[ "$output" == *"keep dir .tmp.1.0.0.verify.bad "*"owner=unreadable"* ]] || { echo "$output"; false; }
  [ -d "$RELEASES/.tmp.1.0.0.verify.h23" ]
  [ -d "$RELEASES/.tmp.1.0.0.verify.bad" ]
  [ ! -e "$RELEASES/.tmp.1.0.0.verify.h25" ]
  [ ! -e "$RELEASES/.tmp.1.0.0.verify.bad25" ]
  [ ! -e "$RELEASES/.tmp.1.0.0.verify.bad25.owner.json" ]
}

@test "reap-tmp --fix: an orphaned owner file is kept for 1 h, collected after" {
  printf '{}\n' > "$RELEASES/.tmp.1.0.0.exec.gone30.owner.json"
  printf '{}\n' > "$RELEASES/.tmp.1.0.0.exec.gone120.owner.json"
  backdate 1800 "$RELEASES/.tmp.1.0.0.exec.gone30.owner.json"
  backdate 7200 "$RELEASES/.tmp.1.0.0.exec.gone120.owner.json"
  run reap fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed orphan-owner .tmp.1.0.0.exec.gone120.owner.json "* ]] || { echo "$output"; false; }
  [ -f "$RELEASES/.tmp.1.0.0.exec.gone30.owner.json" ]
  [ ! -e "$RELEASES/.tmp.1.0.0.exec.gone120.owner.json" ]
}

@test "reap-tmp --fix: symlinked candidates and owner files are refused, never followed" {
  mkdir -p "$SANDBOX/outside/victim/sub"
  printf 'victim\n' > "$SANDBOX/outside/victim/file"
  printf 'nested\n' > "$SANDBOX/outside/victim/sub/file"
  printf 'victim\n' > "$SANDBOX/outside/owner"
  # One link leaves the store, one points at an installed release inside it.
  ln -s "$SANDBOX/outside/victim" "$RELEASES/.tmp.1.0.0.verify.link"
  ln -s "$RELEASES/1.0.0" "$RELEASES/.tmp.1.0.0.verify.inlink"
  scratch .tmp.1.0.0.exec.linkowner 90000
  ln -s "$SANDBOX/outside/owner" "$RELEASES/.tmp.1.0.0.exec.linkowner.owner.json"
  backdate 90000 "$SANDBOX/outside/victim" "$SANDBOX/outside/owner" "$RELEASES/1.0.0" \
    "$RELEASES/.tmp.1.0.0.verify.link" "$RELEASES/.tmp.1.0.0.verify.inlink" \
    "$RELEASES/.tmp.1.0.0.exec.linkowner.owner.json"
  run reap fix
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"refused .tmp.1.0.0.verify.link (symlinked candidate)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"refused .tmp.1.0.0.verify.inlink (symlinked candidate)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"refused .tmp.1.0.0.exec.linkowner (owner file is a symlink"* ]] || { echo "$output"; false; }
  [ -L "$RELEASES/.tmp.1.0.0.verify.link" ]
  [ -L "$RELEASES/.tmp.1.0.0.verify.inlink" ]
  [ "$(cat "$SANDBOX/outside/victim/file")" = victim ]
  [ "$(cat "$SANDBOX/outside/victim/sub/file")" = nested ]
  [ "$(cat "$RELEASES/1.0.0/payload/VERSION")" = installed ]
  [ -d "$RELEASES/.tmp.1.0.0.exec.linkowner" ]
  [ "$(cat "$SANDBOX/outside/owner")" = victim ]
}

# Ruling R22: direct children only, never recurse into an installed release.
@test "reap-tmp: .tmp.* names inside an installed release are never listed or touched" {
  mkdir -p "$RELEASES/9.9.9/payload/.tmp.x.verify.d/sub"
  printf 'release file\n' > "$RELEASES/9.9.9/payload/.tmp.x"
  printf 'release dir\n' > "$RELEASES/9.9.9/payload/.tmp.x.verify.d/sub/file"
  printf '{"schema_version":1,"pid":%s,"process_birth":"x"}\n' "$(dead_pid)" \
    > "$RELEASES/9.9.9/payload/.tmp.x.verify.d.owner.json"
  backdate 90000 "$RELEASES/9.9.9/payload/.tmp.x" "$RELEASES/9.9.9/payload/.tmp.x.verify.d" \
    "$RELEASES/9.9.9/payload/.tmp.x.verify.d.owner.json"
  before="$(cd "$RELEASES/9.9.9" && find . | LC_ALL=C sort)"
  for mode in dry-run fix; do
    run reap "$mode"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" != *".tmp.x"* ]] || { echo "$output"; false; }
    [[ "$output" == *"total entries=0 "* ]] || { echo "$output"; false; }
  done
  [ "$(cd "$RELEASES/9.9.9" && find . | LC_ALL=C sort)" = "$before" ]
  [ "$(cat "$RELEASES/9.9.9/payload/.tmp.x")" = 'release file' ]
  [ "$(cat "$RELEASES/9.9.9/payload/.tmp.x.verify.d/sub/file")" = 'release dir' ]
}

@test "reap-tmp --fix: a releases dir resolving outside TRELLIS_HOME is refused" {
  mkdir -p "$SANDBOX/outside/.tmp.1.0.0.verify.far"
  backdate 90000 "$SANDBOX/outside/.tmp.1.0.0.verify.far"
  rm -rf "$RELEASES"
  ln -s "$SANDBOX/outside" "$RELEASES"
  run reap fix
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"release store escapes canonical home"* ]] || { echo "$output"; false; }
  [ -d "$SANDBOX/outside/.tmp.1.0.0.verify.far" ]
}

@test "release CLI routes reap-tmp and lists it in usage" {
  grep -qF 'reap-tmp) shift; run_reap_tmp "$@" ;;' "$REPO_ROOT/scripts/release.sh"
  grep -qF 'trellis release reap-tmp [--fix]' "$REPO_ROOT/scripts/release.sh"
  grep -qF 'release_store_reap_tmp "$mode"' "$REPO_ROOT/scripts/release.sh"
}

@test "doctor row: count and bytes, split reapable now / not yet" {
  grep -qF "run_check '  ' hc_release_tmp_scratch \"\$HOME_PATH\"" "$REPO_ROOT/scripts/doctor.sh"
  scratch .tmp.1.0.0.exec.dead 7200 "$(dead_pid)" "$EPOCH_BIRTH"
  dd if=/dev/zero of="$RELEASES/.tmp.1.0.0.exec.dead/payload/blob" bs=1024 count=1024 2>/dev/null
  backdate 7200 "$RELEASES/.tmp.1.0.0.exec.dead" "$RELEASES/.tmp.1.0.0.exec.dead.owner.json"
  scratch .tmp.1.0.0.verify.new 60
  run doctor_row
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "release scratch: 2 .tmp.* entries, "*"; 1 reapable now ("*" bytes), 1 not yet, 0 refused" ]] || { echo "$output"; false; }
  bytes="$(printf '%s\n' "$output" | sed -n 's/^release scratch: 2 \.tmp\.\* entries, \([0-9]*\) bytes;.*/\1/p')"
  reapable_bytes="$(printf '%s\n' "$output" | sed -n 's/.*reapable now (\([0-9]*\) bytes).*/\1/p')"
  [ "$reapable_bytes" -ge 1048576 ] || { echo "$output"; false; }
  [ "$bytes" -gt "$reapable_bytes" ] || { echo "$output"; false; }
  [ -d "$RELEASES/.tmp.1.0.0.exec.dead" ]
}

@test "doctor row: WARNs above 50 entries" {
  for i in $(seq 1 51); do mkdir "$RELEASES/.tmp.1.0.0.verify.n$i"; done
  run doctor_row
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == "release scratch: 51 .tmp.* entries, "*"0 reapable now"*"51 not yet"*"trellis release reap-tmp"* ]] || { echo "$output"; false; }
}

@test "reap-tmp --fix: a candidate that changes between scan and removal is kept" {
  [ "$(uname -s)" = Darwin ] || skip "the stub rides the Darwin libproc birth-reader seam"
  start_live_owner
  scratch .tmp.1.0.0.exec.raced 7200 "$LIVE_PID" "$EPOCH_BIRTH"
  # The first birth read (the scan) touches the dir, as a returning owner would.
  cat > "$SANDBOX/birth.py" <<'PY'
import os
count = os.environ["REAP_STUB_COUNT"]
if not os.path.exists(count):
    open(count, "w").close()
    os.utime(os.environ["REAP_STUB_TOUCH"], None)
print("Fri Jan  2 00:00:00 1970")
PY
  run env TRELLIS_HOME="$TRELLIS_HOME" REAP_STUB_COUNT="$SANDBOX/count" \
    REAP_STUB_TOUCH="$RELEASES/.tmp.1.0.0.exec.raced" bash -c '
      . "$1"
      stub="$2"
      release_store_process_birth_python() { cat "$stub"; }
      release_store_reap_tmp fix
    ' reap "$RELEASE_STORE_LIB" "$SANDBOX/birth.py"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"kept dir .tmp.1.0.0.exec.raced (changed since scan)"* ]] || { echo "$output"; false; }
  [ -d "$RELEASES/.tmp.1.0.0.exec.raced" ]
  [ -f "$RELEASES/.tmp.1.0.0.exec.raced.owner.json" ]
}

@test "reap-tmp: a tree too deep to walk is refused, not a traceback" {
  python3 - "$RELEASES" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.mkdir(".tmp.1.0.0.verify.deep", dir_fd=fd)
for _ in range(1200):
    child = os.open(".tmp.1.0.0.verify.deep" if _ == 0 else "d", os.O_RDONLY, dir_fd=fd)
    os.close(fd)
    fd = child
    os.mkdir("d", dir_fd=fd)
os.close(fd)
PY
  backdate 90000 "$RELEASES/.tmp.1.0.0.verify.deep"
  run reap fix
  [ "$status" -eq 4 ] || { echo "$output" | tail -5; false; }
  [[ "$output" == *"refused .tmp.1.0.0.verify.deep ("* ]] || { echo "$output" | tail -5; false; }
  [ -d "$RELEASES/.tmp.1.0.0.verify.deep/d" ]
  rm -rf "$RELEASES/.tmp.1.0.0.verify.deep"
}

@test "reap-tmp summary: past the byte cap entries are counted but not sized" {
  scratch .tmp.1.0.0.verify.a 60
  scratch .tmp.1.0.0.verify.b 60
  dd if=/dev/zero of="$RELEASES/.tmp.1.0.0.verify.a/payload/blob" bs=1024 count=1024 2>/dev/null
  dd if=/dev/zero of="$RELEASES/.tmp.1.0.0.verify.b/payload/blob" bs=1024 count=1024 2>/dev/null
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_reap_tmp summary 1' \
    reap "$RELEASE_STORE_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  read -r entries bytes _ _ _ capped <<<"$output"
  [ "$entries" -eq 2 ] || { echo "$output"; false; }
  [ "$capped" -eq 1 ] || { echo "$output"; false; }
  [ "$bytes" -ge 1048576 ] || { echo "$output"; false; }
  [ "$bytes" -lt 2097152 ] || { echo "$output"; false; }
}

@test "doctor row: WARNs above 1 GiB and asks for the capped summary" {
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"; . "$2"
    release_store_reap_tmp() {
      [ "$*" = "summary 1073741824" ] || return 9
      printf "3 2147483648 1 1073741824 0 1\n"
    }
    hc_release_tmp_scratch "$3"
  ' doctor-row "$RELEASE_STORE_LIB" "$HEALTH_LIB" "$TRELLIS_HOME"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == "release scratch: 3 .tmp.* entries, over 2147483648 bytes (sizing stopped past 1 GiB); 1 reapable now (at least 1073741824 bytes), 2 not yet, 0 refused — review with trellis release reap-tmp"* ]] || { echo "$output"; false; }
}
