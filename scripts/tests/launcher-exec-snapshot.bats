#!/usr/bin/env bats
# Spec 072 T4: the launcher's persistent execution snapshot and its stamps, and
# the metadata-only routes. A run executes releases/.exec/<version>-<digest>
# only after a stamp hit or a full verify; every miss falls back to the full
# verify, and that verify's verdict decides.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LAUNCHER_TEMPLATE="$REPO_ROOT/scripts/trellis-launcher.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/launcher-exec.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  LAUNCHER="$SANDBOX/bin/trellis"
  RELEASES="$TRELLIS_HOME/releases"
  EXEC_STORE="$RELEASES/.exec"
  MARKER="$SANDBOX/tampered-ran"
  mkdir -p "$HOME" "$RELEASES" "$SANDBOX/projects" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  cp "$LAUNCHER_TEMPLATE" "$LAUNCHER"
  chmod 755 "$LAUNCHER"
  jq -n --arg projects "$SANDBOX/projects" '{
    schema_version: 1, source_root: "/nonexistent", release_remote: "fixture://release",
    active_cli_release: "1.2.3", default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$projects]}}
  }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  find "$SANDBOX" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$SANDBOX"
}

write_config() {
  jq -n --arg projects "$SANDBOX/projects" --arg release "$1" '{
    schema_version: 1, source_root: "/nonexistent", release_remote: "fixture://release",
    active_cli_release: $release, default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$projects]}}
  }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

# Release VERSION (default 1.2.3) whose CLI reports the path it ran from and
# exits 3, plus EXTRA filler files so a snapshot build takes long enough to race
# or kill. A current release declares the exec-snapshot capability in
# scripts/lib/trellis-home.sh. An old one (KIND=old) does not, and its CLI first
# applies the payload gate releases up to 1.3.21 carry (show-config.sh,
# sync-to-template.sh), verbatim, which refuses the persistent .exec form.
make_release() {
  local extra="${1:-0}" version="${2:-1.2.3}" kind="${3:-current}" payload i
  payload="$RELEASES/$version/payload"
  mkdir -p "$payload/scripts/lib"
  if [ "$kind" = old ]; then
    cat > "$payload/scripts/trellis" <<'EOF'
#!/bin/bash
old_gate() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}
old_gate "$TRELLIS_HOME" "$TRELLIS_VERIFIED_PAYLOAD" "$TRELLIS_VERIFIED_RELEASE_VERSION" || {
  printf '%s\n' 'old gate: direct source execution is unsupported' >&2
  exit 2
}
printf 'ran %s from %s\n' "$*" "$0"
exit 3
EOF
    printf '# a release before the persistent snapshot\n' > "$payload/scripts/lib/trellis-home.sh"
  else
    cat > "$payload/scripts/trellis" <<'EOF'
#!/bin/bash
printf 'ran %s from %s\n' "$*" "$0"
exit 3
EOF
    printf '# trellis-payload-capability: exec-snapshot\n' > "$payload/scripts/lib/trellis-home.sh"
  fi
  chmod 755 "$payload/scripts/trellis"
  printf 'immutable fixture\n' > "$payload/README"
  ln -s README "$payload/linked"
  for i in $(seq 1 "$extra"); do
    printf 'filler %s\n' "$i" > "$payload/filler-$i"
  done
  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$SANDBOX/manifest.jsonl"
  jq -n --slurpfile tree "$SANDBOX/manifest.jsonl" --arg version "$version" '{
    schema_version: 1, version: $version, tag: ("v" + $version),
    commit: "0000000000000000000000000000000000000000", remote: "fixture://release", tree: $tree
  }' > "$RELEASES/$version/release.json"
  find "$payload" -type f -exec chmod a-w {} +
  find "$payload" -type d -exec chmod a-w {} +
  chmod a-w "$RELEASES/$version/release.json" "$RELEASES/$version"
  DIGEST="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$RELEASES/$version/release.json")"
  SNAPSHOT="$EXEC_STORE/$version-$DIGEST"
  RAN="ran doctor from $SNAPSHOT/payload/scripts/trellis"
}

run_launcher() {
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" "$@"
}

inode_of() {
  python3 -I -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' "$1"
}

# Exactly one finished snapshot (beside its repair lock file, if a repair ran),
# and no work directory, owner sidecar, verify scratch or per-run snapshot
# anywhere in the store.
assert_one_snapshot_no_work() {
  local entries
  entries="$({ find "$RELEASES" -mindepth 1 -maxdepth 1 -name '.*' -print; find "$EXEC_STORE" -mindepth 1 -maxdepth 1 ! -name ".lock.${SNAPSHOT##*/}" -print; } 2>&1 | LC_ALL=C sort)"
  [ "$entries" = "$(printf '%s\n%s' "$EXEC_STORE" "$SNAPSHOT")" ] || { echo "store holds: $entries"; false; }
}

# The launcher's embedded snapshot driver, run directly.
exec_driver() {
  local driver stamp
  driver="$(awk '/^launcher_exec_snapshot_python\(\) \{$/ { getline; inside = 1; next }
    inside && /^TRELLIS_EXEC_SNAPSHOT_PY$/ { exit } inside { print }' "$LAUNCHER_TEMPLATE")"
  stamp="$(cat "$REPO_ROOT/scripts/lib/release_stamp.py")"
  python3 -I -c "$driver" "$stamp" "$@"
}

# Rewrite a sealed snapshot file and put its mtime back; only ctime moves.
tamper() {
  local file="$1" dir="${1%/*}"
  cp -p "$file" "$SANDBOX/original"
  chmod u+w "$dir" "$file"
  printf '#!/bin/bash\ntouch %q\nexit 0\n' "$MARKER" > "$file"
  touch -r "$SANDBOX/original" "$file"
  chmod a-w "$file" "$dir"
}

@test "a warm run executes the persistent snapshot without re-verifying anything" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  assert_one_snapshot_no_work
  [ -f "$TRELLIS_HOME/state/release-stamps/1.2.3-$DIGEST.json" ]
  [ -f "$TRELLIS_HOME/state/exec-stamps/1.2.3-$DIGEST.json" ]

  # A full verify allocates scratch beside what it verifies; with both stores
  # read-only any re-verify, copy or rebuild fails. The warm run must not need one.
  chmod 500 "$RELEASES" "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
}

@test "a stamp miss falls back to the full verify, which then re-stamps" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # Same bytes, new ctime: the installed release stamp misses. The fallback
  # full verify needs scratch in the store, so it is refused while the store is
  # read-only: proof that the miss really took the full verify.
  chmod u+w "$RELEASES/1.2.3/payload/README"
  chmod a-w "$RELEASES/1.2.3/payload/README"
  chmod 500 "$RELEASES"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *'could not allocate release verification state'* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }

  chmod 700 "$RELEASES"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  chmod 500 "$RELEASES" "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "re-stamped run: $output"; false; }
  chmod 700 "$RELEASES" "$EXEC_STORE"

  # A missing snapshot stamp: the snapshot is verified in place, kept, and
  # stamped again.
  local inode
  inode="$(inode_of "$SNAPSHOT")"
  rm "$TRELLIS_HOME/state/exec-stamps/1.2.3-$DIGEST.json"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  [ "$(inode_of "$SNAPSHOT")" = "$inode" ]
  [ -f "$TRELLIS_HOME/state/exec-stamps/1.2.3-$DIGEST.json" ]
  assert_one_snapshot_no_work
}

@test "concurrent first runs all succeed and leave exactly one snapshot" {
  local i pids=()
  make_release 300
  for i in 1 2 3 4; do
    env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor "c$i" > "$SANDBOX/out-$i" 2>&1 &
    pids+=("$!")
  done
  for i in 1 2 3 4; do
    local rc=0
    wait "${pids[$((i - 1))]}" || rc=$?
    [ "$rc" -eq 3 ] || { echo "run $i: rc=$rc"; cat "$SANDBOX/out-$i"; false; }
    [ "$(cat "$SANDBOX/out-$i")" = "ran doctor c$i from $SNAPSHOT/payload/scripts/trellis" ] ||
      { echo "run $i:"; cat "$SANDBOX/out-$i"; false; }
  done
  assert_one_snapshot_no_work
}

@test "a run killed while building leaves no runnable partial, and the next run rebuilds" {
  local pid work="" i
  make_release 300
  perl -e 'setpgrp(0, 0); exec @ARGV' env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor \
    > "$SANDBOX/killed.out" 2>&1 &
  pid=$!
  for i in $(seq 1 3000); do
    work="$(find "$EXEC_STORE" -maxdepth 1 -name '.tmp.1.2.3-*' ! -name '*.owner.json' -print 2>/dev/null)" || :
    [ -z "$work" ] || break
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" || true
  [ -n "$work" ] || { echo 'never saw the work directory'; cat "$SANDBOX/killed.out"; false; }
  [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || { echo 'a killed build published the final name'; false; }
  [[ "$(cat "$SANDBOX/killed.out")" != *'ran doctor'* ]]

  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  [ -d "$SNAPSHOT" ]
  # The killed run's work directory is left for the janitor; it is not the
  # snapshot that ran.
  [ "$(find "$EXEC_STORE" -maxdepth 1 -name '1.2.3-*' -print)" = "$SNAPSHOT" ]
}

@test "a tampered snapshot is refused, rebuilt, and never executed" {
  local inode
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  inode="$(inode_of "$SNAPSHOT")"
  tamper "$SNAPSHOT/payload/scripts/trellis"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"release execution snapshot failed verification and is rebuilt: $SNAPSHOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$RAN"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ] || { echo 'tampered snapshot bytes executed'; false; }
  [ "$(inode_of "$SNAPSHOT")" != "$inode" ]
  assert_one_snapshot_no_work

  # A half-built directory under the final name, and a symlink there to a
  # good copy elsewhere: both refused and replaced.
  chmod -R u+w "$SNAPSHOT"
  rm -rf "$SNAPSHOT/payload"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"failed verification and is rebuilt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$RAN"* ]] || { echo "$output"; false; }

  chmod u+w "$SNAPSHOT"
  mv "$SNAPSHOT" "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$SNAPSHOT"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"failed verification and is rebuilt"* ]] || { echo "$output"; false; }
  [ ! -L "$SNAPSHOT" ] && [ -d "$SNAPSHOT" ]
  assert_one_snapshot_no_work
}

@test "a tampered installed release is refused even though its snapshot is intact" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  tamper "$RELEASES/1.2.3/payload/README"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'configured release content has changed: README'* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }
}

@test "help, heavy --check and heavy --status need no release at all" {
  local dispatcher_help supervisor
  mkdir -p "$RELEASES/1.2.3"
  printf 'broken record\n' > "$RELEASES/1.2.3/release.json"
  dispatcher_help="$(bash "$REPO_ROOT/scripts/trellis" help)"

  run_launcher
  [ "$status" -eq 0 ] && [ "$output" = "$dispatcher_help" ] || { echo "no words: $output"; false; }
  for word in help --help -h ''; do
    run_launcher "$word"
    [ "$status" -eq 0 ] || { echo "'$word': $output"; false; }
    [ "$output" = "$dispatcher_help" ] || { echo "'$word': $output"; false; }
  done
  run_launcher help extra words
  [ "$status" -eq 0 ] && [ "$output" = "$dispatcher_help" ] || { echo "$output"; false; }

  for mode in check status; do
    run_launcher heavy "--$mode"
    [ "$status" -eq 0 ] || { echo "$mode: $output"; false; }
    supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" "$mode" 2>&1)"
    [ "$output" = "$supervisor" ] || { printf 'launcher:\n%s\nsupervisor:\n%s\n' "$output" "$supervisor"; false; }
  done
  [ ! -e "$TRELLIS_HOME/state" ] && [ ! -e "$EXEC_STORE" ]

  # Any other shape is an ordinary route and meets the broken release.
  run_launcher heavy --status --light
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
}

@test "heavy --status from the launcher matches the supervisor on held, retired and broken tables" {
  local slots="$TRELLIS_HOME/locks/heavy" supervisor holder
  mkdir -p "$RELEASES"
  mkdir -p "$slots"
  chmod 700 "$TRELLIS_HOME/locks" "$slots"
  # Slot 3 is retired (heavy_slots 2) and held, with an info line.
  printf '%s\tlane-x\t2026-10-31T00:00:00Z\tbats x.bats\n' "$$" > "$slots/slot-3.info"
  perl -MFcntl=:flock -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; print "locked\n"; $| = 1; sleep 30' \
    "$slots/slot-3.lock" > "$SANDBOX/holder.out" &
  holder=$!
  for _ in $(seq 1 200); do [ -s "$SANDBOX/holder.out" ] && break; sleep 0.05; done
  run_launcher heavy --status
  supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" status 2>&1)"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'slot 3: held (retired) lane=lane-x'* ]] || { echo "$output"; false; }
  [ "$output" = "$supervisor" ] || { printf 'launcher:\n%s\nsupervisor:\n%s\n' "$output" "$supervisor"; false; }

  # A broken config and an open slot directory fail the same way in both.
  jq '.heavy_slots = 0' "$TRELLIS_HOME/config.json" > "$SANDBOX/config" && cat "$SANDBOX/config" > "$TRELLIS_HOME/config.json"
  run_launcher heavy --check
  supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" check 2>&1)" || :
  [ "$status" -eq 78 ] && [ "$output" = "$supervisor" ] || { printf '%s\n--\n%s\n' "$output" "$supervisor"; false; }
  jq 'del(.heavy_slots)' "$TRELLIS_HOME/config.json" > "$SANDBOX/config" && cat "$SANDBOX/config" > "$TRELLIS_HOME/config.json"
  chmod 755 "$slots"
  run_launcher heavy --status
  supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" status 2>&1)" || :
  [ "$status" -eq 78 ] && [ "$output" = "$supervisor" ] || { printf '%s\n--\n%s\n' "$output" "$supervisor"; false; }
}

@test "the launcher's pinned copies equal their sources" {
  local copy source
  copy="$(awk '/^launcher_release_stamp_python\(\) \{$/ { getline; inside = 1; next }
    inside && /^TRELLIS_RELEASE_STAMP_PY$/ { exit } inside { print }' "$LAUNCHER_TEMPLATE")"
  [ -n "$copy" ] && [ "$copy" = "$(cat "$REPO_ROOT/scripts/lib/release_stamp.py")" ] ||
    { echo 'launcher_release_stamp_python drifted from scripts/lib/release_stamp.py'; false; }

  copy="$(awk '/^launcher_usage\(\) \{$/ { getline; inside = 1; next } inside && /^EOF$/ { exit } inside { print }' "$LAUNCHER_TEMPLATE")"
  source="$(awk '/^usage\(\) \{$/ { getline; inside = 1; next } inside && /^EOF$/ { exit } inside { print }' "$REPO_ROOT/scripts/trellis")"
  [ -n "$copy" ] && [ "$copy" = "$source" ] || { echo 'launcher_usage drifted from usage() in scripts/trellis'; false; }

  run python3 -I - "$LAUNCHER_TEMPLATE" "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" <<'PY'
import re, sys
launcher, supervisor = (open(path).read() for path in sys.argv[1:3])
body = launcher.split("launcher_heavy_metadata_perl() {\n", 1)[1].split("\nTRELLIS_HEAVY_METADATA_PL\n", 1)[0]
blocks = re.findall(r"\n#@pin\n(.*?)\n#@end\n", body, re.S)
if len(blocks) != 2:
    sys.exit("expected two pinned blocks, found %d" % len(blocks))
for block in blocks:
    if block not in supervisor:
        sys.exit("pinned block is not in heavy-supervisor.pl:\n" + block[:200])
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # The capability line the launcher looks for is the one this release's own
  # normative predicate file declares, so a current payload takes the
  # persistent snapshot.
  copy="$(sed -n "s/.*grep -qxF '\\(# trellis-payload-capability: [a-z-]*\\)'.*/\\1/p" "$LAUNCHER_TEMPLATE")"
  [ -n "$copy" ] && grep -qxF "$copy" "$REPO_ROOT/scripts/lib/trellis-home.sh" ||
    { echo "capability line '$copy' is not declared in scripts/lib/trellis-home.sh"; false; }
}

@test "release list and locate ignore the execution snapshot store" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -d "$SNAPSHOT" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_list' _ "$REPO_ROOT/scripts/lib/release-store.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'.exec'* ]] && [[ "$output" != *'unexpected release store entry'* ]] || { echo "$output"; false; }
  [[ "$output" == *'1.2.3'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_locate 1.2.3' _ "$REPO_ROOT/scripts/lib/release-store.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$RELEASES/1.2.3" ] || { echo "$output"; false; }
}

@test "a snapshot changed while the installed release is re-verified is refused and rebuilt" {
  local pid i seen="" rc=0
  make_release 1000
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # Same bytes, new ctime: only the installed release's stamp misses, so this
  # run takes its full verify. While that verify runs, rewrite the snapshot,
  # whose stamp hit before the verify began.
  chmod u+w "$RELEASES/1.2.3/payload/README"
  chmod a-w "$RELEASES/1.2.3/payload/README"
  env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor > "$SANDBOX/race.out" 2>&1 &
  pid=$!
  for i in $(seq 1 3000); do
    seen="$(find "$RELEASES" -maxdepth 1 -name '.tmp.1.2.3.verify.*' -print 2>/dev/null)" || :
    [ -z "$seen" ] || break
  done
  [ -z "$seen" ] || tamper "$SNAPSHOT/payload/scripts/trellis"
  wait "$pid" || rc=$?
  [ -n "$seen" ] || { echo 'never caught the installed release verify'; cat "$SANDBOX/race.out"; false; }
  [ ! -e "$MARKER" ] || { echo 'snapshot bytes changed during the verify were executed'; false; }
  [ "$rc" -eq 3 ] || { echo "rc=$rc"; cat "$SANDBOX/race.out"; false; }
  grep -qF "release execution snapshot failed verification and is rebuilt: $SNAPSHOT" "$SANDBOX/race.out" ||
    { cat "$SANDBOX/race.out"; false; }
  grep -qxF "$RAN" "$SANDBOX/race.out" || { cat "$SANDBOX/race.out"; false; }
}

@test "an older payload runs from a per-run snapshot its own gate accepts, and rollback keeps working" {
  local old_digest current_ran
  make_release 0 1.2.4
  current_ran="$RAN"
  make_release 0 1.2.3 old
  old_digest="$DIGEST"

  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == "ran doctor from $RELEASES/.tmp.1.2.3.exec."*"/payload/scripts/trellis" ]] || { echo "$output"; false; }
  [ ! -e "$EXEC_STORE" ] || { echo 'an old payload created the persistent store'; false; }
  [ -z "$(find "$RELEASES" -maxdepth 2 -name '.tmp.*' -print)" ] || { echo 'the per-run snapshot survived'; false; }
  [ -f "$TRELLIS_HOME/state/release-stamps/1.2.3-$old_digest.json" ]

  # Forward to the current release, then roll back with the same launcher.
  write_config 1.2.4
  run_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$current_ran" ] || { echo "$output"; false; }
  write_config 1.2.3
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "rollback: $output"; false; }
  [[ "$output" == "ran doctor from $RELEASES/.tmp.1.2.3.exec."*"/payload/scripts/trellis" ]] || { echo "$output"; false; }
  write_config 1.2.4
  run_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$current_ran" ] || { echo "$output"; false; }
}

@test "a repair waits for the one in progress and keeps the snapshot it leaves" {
  local inode holder pid rc=0
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  inode="$(inode_of "$SNAPSHOT")"

  # Another run holds the repair lock while the snapshot is tampered with.
  tamper "$SNAPSHOT/payload/scripts/trellis"
  perl -MFcntl=:flock -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; $| = 1; print "held\n"; sleep 60' \
    "$EXEC_STORE/.lock.${SNAPSHOT##*/}" > "$SANDBOX/holder.out" &
  holder=$!
  for _ in $(seq 1 200); do [ -s "$SANDBOX/holder.out" ] && break; sleep 0.05; done
  env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor > "$SANDBOX/waiter.out" 2>&1 &
  pid=$!
  sleep 3
  # The holder repairs it in place, then lets go.
  chmod u+w "$SNAPSHOT/payload/scripts" "$SNAPSHOT/payload/scripts/trellis"
  cat "$SANDBOX/original" > "$SNAPSHOT/payload/scripts/trellis"
  chmod a-w "$SNAPSHOT/payload/scripts/trellis" "$SNAPSHOT/payload/scripts"
  kill "$holder"
  wait "$holder" 2>/dev/null || :
  wait "$pid" || rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc"; cat "$SANDBOX/waiter.out"; false; }
  [ "$(cat "$SANDBOX/waiter.out")" = "$RAN" ] || { cat "$SANDBOX/waiter.out"; false; }
  [ ! -e "$MARKER" ]
  [ "$(inode_of "$SNAPSHOT")" = "$inode" ] || { echo 'the repaired snapshot was replaced'; false; }
}

@test "retiring a rejected snapshot moves only that instance" {
  local identity
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  identity="$(exec_driver exec-identity "$TRELLIS_HOME" 1.2.3 "$DIGEST")"
  [[ "$identity" == *:* ]] || { echo "$identity"; false; }

  run exec_driver exec-retire "$TRELLIS_HOME" 1.2.3 "$DIGEST" "0:0" "$$" "fixture birth"
  [ "$status" -eq 3 ] || { echo "status=$status $output"; false; }
  [ "$(exec_driver exec-identity "$TRELLIS_HOME" 1.2.3 "$DIGEST")" = "$identity" ]
  assert_one_snapshot_no_work

  run exec_driver exec-retire "$TRELLIS_HOME" 1.2.3 "$DIGEST" "$identity" "$$" "fixture birth"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ ! -e "$SNAPSHOT" ] && [ -d "$EXEC_STORE/$output" ] && [ -f "$EXEC_STORE/$output.owner.json" ]
}

@test "an unsafe execution snapshot store is refused before it is used" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # Opened up after warming: the stamp would hit, but the store is refused.
  chmod 777 "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"release execution snapshot store is not a private real directory: $EXEC_STORE"* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }
  chmod 700 "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
}

@test "an execution snapshot store symlinked outside is refused and nothing is written there" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # A store that is a symlink to a directory outside, holding a planted copy.
  mkdir -m 700 "$SANDBOX/outside"
  chmod -R u+w "$EXEC_STORE"
  mv "$SNAPSHOT" "$SANDBOX/outside/"
  rm -rf "$EXEC_STORE"
  ln -s "$SANDBOX/outside" "$EXEC_STORE"
  ls -A "$SANDBOX/outside" > "$SANDBOX/outside.before"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"release execution snapshot store is not a private real directory"* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }
  ls -A "$SANDBOX/outside" | cmp -s - "$SANDBOX/outside.before" || { echo 'wrote outside the store:'; ls -A "$SANDBOX/outside"; false; }
}
