#!/usr/bin/env bats
# disk-janitor --scopes pi: pi temp files and orphan pi worktrees, REPORT-ONLY
# in 1.3.12. --apply refuses the scope and nothing under a pi root is deleted.
#
# pi's temp root is $TMPDIR/pi (TRELLIS_PI_TMPDIR when set); its subagent
# worktrees, and the temp files pi's own process still writes beside them, live
# under HOME/.pi-worktrees, and older ones under the legacy
# TRELLIS_HOME/pi-worktrees. Entries older than 3 days are listed as
# reclaimable, except that a worktree is listed only when it is an orphan: no
# attachment owner record names it and no parent repository's `git worktree
# list` registers it. A repository is never listed. pi's bash spill logs
# (pi-bash-*.log) are listed after 1 day, or at any age once over 1 GiB, and
# only when lsof sees no open handle on them.
#
# Hermetic: TMPDIR, HOME and TRELLIS_HOME all point into a per-test sandbox, so
# the janitor never sees the real ~/.trellis or the real temp directory.

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"
STALE_TOUCH="200001010000"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-pi.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  TRELLIS_HOME="$SANDBOX/.trellis"
  CFG="$CANON/trellis.config.json"
  mkdir -p "$CANON/audits" "$SANDBOX/projects" "$TRELLIS_HOME" "$SANDBOX/tmp" "$SANDBOX/home"
  chmod 700 "$TRELLIS_HOME"
  export TRELLIS_CONFIG="$CFG" TRELLIS_HOME
  export TMPDIR="$SANDBOX/tmp" HOME="$SANDBOX/home"
  unset TRELLIS_PI_TMPDIR
  # C3 hermetic: never scan the real per-user Darwin temp in tests.
  export DJ_DARWIN_TMPDIR_OVERRIDE=""
  WT_ROOT="$TRELLIS_HOME/pi-worktrees"
  PI_ROOT="$HOME/.pi-worktrees"
  PI_TMP="$TMPDIR/pi"
  mkdir -p "$WT_ROOT" "$PI_ROOT" "$PI_TMP"
  HOLDER_PID=""
  cat >"$CFG" <<'EOF'
{"schema_version": 2, "maintainer_name": "Test Maintainer", "github_user": "tester", "harnesses": ["claude"]}
EOF
  cat >"$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$CANON",
  "release_remote": "https://example.invalid/trellis.git",
  "active_cli_release": "1.2.3",
  "default_fleet": "personal",
  "fleets": {"personal": {"discovery_roots": ["$SANDBOX/projects"]}}
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' >"$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  PARENT="$SANDBOX/parent"
  git init -q -b main "$PARENT"
  git -C "$PARENT" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m seed
}

teardown() {
  if [ -n "${HOLDER_PID:-}" ]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

# age <path>: backdate the path and everything under it past the threshold.
age() {
  find "$1" -exec touch -h -t "$STALE_TOUCH" {} +
}

# pi_worktree <name> [root]: a real linked worktree of $PARENT under a worktree
# root (default: the legacy one).
pi_worktree() {
  local root="${2:-$WT_ROOT}"
  git -C "$PARENT" worktree add -q --detach "$root/$1" HEAD
  printf 'agent work\n' >"$root/$1/work.txt"
  printf '%s\n' "$root/$1"
}

# hours_ago <path> <hours>: set the path's mtime that many hours back.
hours_ago() {
  touch -h -t "$(perl -MPOSIX -e 'print strftime("%Y%m%d%H%M", localtime(time - $ARGV[0] * 3600))' "$2")" "$1"
}

# big_log <path>: a sparse file just over 1 GiB, cheap on disk.
big_log() {
  dd if=/dev/zero of="$1" bs=1 count=0 seek=1073741825 2>/dev/null
}

# unregister <worktree>: drop the parent's registration, leaving the directory,
# which is how an orphan arises (its repository forgot it).
unregister() {
  local name
  name="$(sed -n 's|^gitdir: .*/worktrees/||p' "$1/.git")"
  rm -rf "$PARENT/.git/worktrees/$name"
}

# owner_record <path>: an attachment owner record naming <path>.
owner_record() {
  mkdir -p "$TRELLIS_HOME/state/attachments/c0ffee"
  jq -n --arg root "$1" '{schema_version: 1, worktree_root: $root, project_root: $root}' \
    >"$TRELLIS_HOME/state/attachments/c0ffee/w1.json"
}

run_dj() { run bash "$DJ" "$@"; }

# report_dj: the pi report, asserting it ran cleanly.
report_dj() {
  run_dj --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "pi scope: --apply deletes spill logs only, keeps temp and worktrees" {
  # C3 (spec 069): pi-bash-*.log older than 1d or over 1 GiB with no handle
  # apply-deletes across all spill roots (maxdepth 1, never following
  # symlinks); temp files and orphan worktrees stay manual here (DH.4 owns
  # worktrees). pi_apply:false restores report-only (covered in host suite).
  local root orphan
  orphan="$(pi_worktree pi-agent-orphan-0001 "$PI_ROOT")"
  unregister "$orphan"
  age "$orphan"
  for root in "$PI_ROOT" "$WT_ROOT" "$PI_TMP"; do
    printf 'old\n' >"$root/sentinel-old.txt"
    printf 'old\n' >"$root/pi-bash-0000000000000001.log"
    big_log "$root/pi-bash-0000000000000002.log"
    age "$root/sentinel-old.txt"; age "$root/pi-bash-0000000000000001.log"
  done

  run_dj --apply --yes --scopes pi </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed:"*"pi-bash-"* ]] || { echo "$output"; false; }

  for root in "$PI_ROOT" "$WT_ROOT" "$PI_TMP"; do
    [ -f "$root/sentinel-old.txt" ] || { echo "deleted temp in $root"; false; }
    [ ! -e "$root/pi-bash-0000000000000001.log" ] || { echo "aged log survived in $root"; false; }
    [ ! -e "$root/pi-bash-0000000000000002.log" ] || { echo "big log survived in $root"; false; }
  done
  [ -f "$orphan/work.txt" ]
}

@test "pi scope: an aged orphan is listed; registered and owner-recorded worktrees are not" {
  local registered recorded orphan
  registered="$(pi_worktree pi-agent-registered-0001)"
  recorded="$(pi_worktree pi-agent-recorded-0002)"
  orphan="$(pi_worktree pi-agent-orphan-0003)"
  unregister "$recorded"
  unregister "$orphan"
  owner_record "$recorded"
  age "$registered"; age "$recorded"; age "$orphan"

  report_dj
  # A9 (spec 069 DH.4): unregistered orphans with missing gitdir fail the
  # no-unique-commits gate closed and dirty files hold — both list as
  # candidate (held, manual review), never reclaimable/delete. Registered and
  # owner-recorded worktrees are never delete/reclaimable (held as skip or
  # candidate).
  [[ "$output" == *"[candidate] $orphan "* ]] || { echo "$output"; false; }
  [[ "$output" != *"[reclaimable] $registered "* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $registered "* ]] || { echo "$output"; false; }
  [[ "$output" != *"[reclaimable] $recorded "* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete] $recorded "* ]] || { echo "$output"; false; }
  [ -f "$orphan/work.txt" ]
}

@test "pi scope: a repository under a pi root is never listed, however old" {
  local main="$PI_ROOT/pi-agent-main-0001"
  git init -q -b main "$main"
  printf 'valuable\n' >"$main/README"
  age "$main"

  report_dj
  [[ "$output" == *"[skip] $main "*"repository"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[reclaimable] $main "* ]] || { echo "$output"; false; }
  [[ "$output" != *"[candidate] $main "* ]] || { echo "$output"; false; }
  [ -f "$main/README" ]
}

@test "pi scope: an orphan younger than 3 days is not listed" {
  local orphan
  orphan="$(pi_worktree pi-agent-young-0004)"
  unregister "$orphan"
  age "$orphan"
  touch "$orphan/work.txt"

  report_dj
  [[ "$output" == *"[skip] $orphan "*"fresh"* ]] || { echo "$output"; false; }
}

@test "pi scope: unreadable owner records make every worktree a candidate" {
  local orphan
  orphan="$(pi_worktree pi-agent-orphan-0005)"
  unregister "$orphan"
  age "$orphan"
  mkdir -p "$TRELLIS_HOME/state/attachments/c0ffee"
  printf '{not json\n' >"$TRELLIS_HOME/state/attachments/c0ffee/w1.json"

  report_dj
  [[ "$output" == *"[candidate] $orphan "*"owner records"* ]] || { echo "$output"; false; }
}

@test "pi scope: temp files older than 3 days are listed, younger ones not, in every root" {
  printf 'old\n' >"$PI_TMP/old.txt"
  printf 'new\n' >"$PI_TMP/new.txt"
  mkdir -p "$PI_TMP/mixed-dir"
  printf 'new\n' >"$PI_TMP/mixed-dir/fresh"
  printf 'old\n' >"$WT_ROOT/uv-0123.lock"
  printf 'old\n' >"$PI_ROOT/uv-0124.lock"
  age "$PI_TMP/old.txt"; age "$WT_ROOT/uv-0123.lock"; age "$PI_ROOT/uv-0124.lock"
  # A fresh file deep inside keeps an old directory: age is the newest content.
  touch -t "$STALE_TOUCH" "$PI_TMP/mixed-dir"

  report_dj
  [[ "$output" == *"$PI_ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$WT_ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$PI_TMP"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[reclaimable] $PI_TMP/old.txt "* ]] || { echo "$output"; false; }
  [[ "$output" == *"[reclaimable] $WT_ROOT/uv-0123.lock "* ]] || { echo "$output"; false; }
  [[ "$output" == *"[reclaimable] $PI_ROOT/uv-0124.lock "* ]] || { echo "$output"; false; }
  [[ "$output" == *"[skip] $PI_TMP/new.txt "* ]] || { echo "$output"; false; }
  [[ "$output" == *"[skip] $PI_TMP/mixed-dir "* ]] || { echo "$output"; false; }
}

@test "pi scope: spill logs older than 1 day or over 1 GiB are listed in every root" {
  local root
  for root in "$PI_ROOT" "$WT_ROOT" "$PI_TMP"; do
    printf 'old\n' >"$root/pi-bash-0000000000000001.log"
    hours_ago "$root/pi-bash-0000000000000001.log" 30
    printf 'new\n' >"$root/pi-bash-0000000000000002.log"
    hours_ago "$root/pi-bash-0000000000000002.log" 2
    big_log "$root/pi-bash-0000000000000003.log"
    # Other temp files keep the 3-day age: 30 hours is not old enough.
    printf 'share\n' >"$root/pi-share-0001"
    hours_ago "$root/pi-share-0001" 30
  done

  run_dj --dry-run --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for root in "$PI_ROOT" "$WT_ROOT" "$PI_TMP"; do
    # Dry-run previews apply deletes (C3); report mode still shows reclaimable.
    [[ "$output" == *"[delete] $root/pi-bash-0000000000000001.log "*"older than 1d"* ]] || { echo "$output"; false; }
    [[ "$output" == *"[delete] $root/pi-bash-0000000000000003.log "*"over 1 GiB"* ]] || { echo "$output"; false; }
    [[ "$output" == *"[skip] $root/pi-bash-0000000000000002.log "* ]] || { echo "$output"; false; }
    [[ "$output" == *"[skip] $root/pi-share-0001 "* ]] || { echo "$output"; false; }
    [ -f "$root/pi-bash-0000000000000001.log" ] && [ -f "$root/pi-bash-0000000000000003.log" ]
  done
}

@test "pi scope: unreadable owner records do not hide spill logs" {
  mkdir -p "$TRELLIS_HOME/state/attachments/c0ffee"
  printf '{not json\n' >"$TRELLIS_HOME/state/attachments/c0ffee/w1.json"
  big_log "$PI_ROOT/pi-bash-00000000000000a1.log"

  report_dj
  [[ "$output" == *"[reclaimable] $PI_ROOT/pi-bash-00000000000000a1.log "* ]] || { echo "$output"; false; }
}

@test "pi scope: a spill log with an open handle is a candidate, however large or old" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  local held="$WT_ROOT/pi-bash-00000000000000b1.log" i
  big_log "$held"
  hours_ago "$held" 72
  sleep 120 3<"$held" &
  HOLDER_PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    lsof -p "$HOLDER_PID" 2>/dev/null | grep -qF "$held" && break
    sleep 0.5
  done
  lsof -p "$HOLDER_PID" 2>/dev/null | grep -qF "$held"

  report_dj
  [[ "$output" == *"[candidate] $held "*"in use"* ]] || { echo "$output"; false; }
}

@test "pi scope: a failed lsof makes every spill log a candidate" {
  mkdir -p "$SANDBOX/stub"
  printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/stub/lsof"
  chmod +x "$SANDBOX/stub/lsof"
  big_log "$PI_ROOT/pi-bash-00000000000000c1.log"
  hours_ago "$PI_ROOT/pi-bash-00000000000000c1.log" 72

  run env PATH="$SANDBOX/stub:$PATH" bash "$DJ" --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[candidate] $PI_ROOT/pi-bash-00000000000000c1.log "* ]] || { echo "$output"; false; }
}

@test "pi scope: a symlink entry is never listed, however old" {
  mkdir -p "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$PI_TMP/old-link"
  big_log "$SANDBOX/outside.log"
  ln -s "$SANDBOX/outside.log" "$PI_ROOT/pi-bash-0000000000000004.log"
  age "$PI_TMP/old-link"

  report_dj
  [[ "$output" == *"[skip] $PI_TMP/old-link "*"symlink"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[skip] $PI_ROOT/pi-bash-0000000000000004.log "*"symlink"* ]] || { echo "$output"; false; }
}

@test "pi scope: TRELLIS_PI_TMPDIR names the temp root, but never / or HOME" {
  local named="$TMPDIR/named-pi-tmp"
  mkdir -p "$named"
  printf 'old\n' >"$named/old.txt"
  printf 'old\n' >"$HOME/old-home.txt"
  age "$named/old.txt"; age "$HOME/old-home.txt"

  run env TRELLIS_PI_TMPDIR="$named" bash "$DJ" --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[reclaimable] $named/old.txt "* ]] || { echo "$output"; false; }
  run env TRELLIS_PI_TMPDIR="$HOME" bash "$DJ" --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"$HOME/old-home.txt"* ]] || { echo "$output"; false; }
  run env TRELLIS_PI_TMPDIR=/ bash "$DJ" --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no pi temp root"* ]] || { echo "$output"; false; }
}

# refused_temp_root <value>: the report refuses TRELLIS_PI_TMPDIR=<value> and
# lists nothing as reclaimable, though an aged file sits behind it.
refused_temp_root() {
  run env TRELLIS_PI_TMPDIR="$1" bash "$DJ" --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"[reclaimable]"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"no pi temp root"* ]] || { echo "$output"; return 1; }
}

@test "pi scope: a temp root that only spells HOME differently is refused" {
  printf 'old\n' >"$HOME/old-home.txt"
  age "$HOME/old-home.txt"
  refused_temp_root "$HOME/." || return 1
  refused_temp_root "$HOME//" || return 1
  refused_temp_root "$HOME/../home" || return 1
}

@test "pi scope: a temp root under a symlinked ancestor or outside TMPDIR is refused" {
  mkdir -p "$SANDBOX/elsewhere/pi"
  printf 'old\n' >"$SANDBOX/elsewhere/pi/old.txt"
  age "$SANDBOX/elsewhere/pi/old.txt"
  ln -s "$SANDBOX/elsewhere" "$TMPDIR/link"
  refused_temp_root "$TMPDIR/link/pi" || return 1
  refused_temp_root "$SANDBOX/elsewhere/pi" || return 1
}

@test "pi scope: a TMPDIR that is HOME gives no temp root" {
  mkdir -p "$HOME/pi"
  printf 'old\n' >"$HOME/pi/old.txt"
  age "$HOME/pi/old.txt"
  run env -u TRELLIS_PI_TMPDIR TMPDIR="$HOME" bash "$DJ" --report --scopes pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[reclaimable]"* ]] || { echo "$output"; false; }
}

@test "pi scope: TMPDIR=/ never makes /pi a temp root" {
  # The janitor's own scratch files need a writable TMPDIR, so on most hosts
  # it stops before scanning; either way /pi is never a root.
  run env -u TRELLIS_PI_TMPDIR TMPDIR=/ bash "$DJ" --report --scopes pi
  [[ "$output" != *"[reclaimable]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"roots: "*" /pi"* ]] || { echo "$output"; false; }
}

@test "pi scope: a worktree root under a symlinked HOME component is refused" {
  local real_home="$SANDBOX/real-home"
  mkdir -p "$real_home/.pi-worktrees"
  printf 'old\n' >"$real_home/.pi-worktrees/old.txt"
  age "$real_home/.pi-worktrees/old.txt"
  rmdir "$PI_ROOT"
  ln -s "$real_home/.pi-worktrees" "$PI_ROOT"
  report_dj
  [[ "$output" != *"[reclaimable]"* ]] || { echo "$output"; false; }
}

@test "pi scope: a symlinked root is not scanned" {
  rmdir "$PI_ROOT"
  mkdir -p "$SANDBOX/other-root"
  printf 'old\n' >"$SANDBOX/other-root/old.txt"
  age "$SANDBOX/other-root/old.txt"
  ln -s "$SANDBOX/other-root" "$PI_ROOT"

  report_dj
  [[ "$output" != *"other-root/old.txt"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[reclaimable] $PI_ROOT/old.txt"* ]] || { echo "$output"; false; }
  [[ "$output" == *".pi-worktrees missing, symlinked or outside HOME"* ]] || { echo "$output"; false; }
}

@test "pi scope is opt-in: the default scopes never touch pi roots" {
  printf 'old\n' >"$PI_TMP/old.txt"
  age "$PI_TMP/old.txt"
  run_dj --apply --yes --scopes caches,worktrees,releases </dev/null
  [ -f "$PI_TMP/old.txt" ]
  run_dj --report
  [[ "$output" != *"$PI_TMP"* ]] || { echo "$output"; false; }
}
