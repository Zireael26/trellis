#!/usr/bin/env bats
# Spec 072 T5: hermetic release-tmp leak and safety checks.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/release-tmp.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$SANDBOX/trellis"
  export TRELLIS_CONFIG="$SANDBOX/source/trellis.config.json"
  mkdir -p "$HOME" "$TMPDIR" "$SANDBOX/source/audits" "$SANDBOX/bin" "$SANDBOX/projects" \
    "$TRELLIS_HOME/releases/.exec" "$TRELLIS_HOME/state/release-stamps" "$TRELLIS_HOME/state/exec-stamps"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' '{"schema_version":2,"maintainer_name":"Test","github_user":"tester","harnesses":["claude"]}' >"$TRELLIS_CONFIG"
  jq -n --arg source "$SANDBOX/source" --arg projects "$SANDBOX/projects" '{schema_version:1,source_root:$source,
    release_remote:"https://example.invalid/trellis.git",active_cli_release:"1.2.3",
    default_fleet:"personal",fleets:{personal:{discovery_roots:[$projects]}}}' >"$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' >"$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/config.json" "$TRELLIS_HOME/registry.json"
  # Deterministic lsof snapshot; existing janitor suites test the capture itself.
  printf '#!/bin/sh\nprintf "p1\\nn%%s\\n" "${DJ_OPEN_PATH:-/not-this-sandbox}"\n' >"$SANDBOX/bin/lsof"
  chmod +x "$SANDBOX/bin/lsof"
  export PATH="$SANDBOX/bin:$PATH"
  DIGEST="$(printf '%064d' 0)"
  STORE="$TRELLIS_HOME/releases/.exec"
  STAMPS="$TRELLIS_HOME/state/release-stamps"
  EXEC_STAMPS="$TRELLIS_HOME/state/exec-stamps"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

make_tree() {
  mkdir -p "$1/payload"
  printf 'keep or reap\n' >"$1/payload/marker"
}

old() { touch -t 200001010000 "$@"; }

owner() {
  jq -n --argjson pid "$2" --arg birth "$3" \
    '{schema_version:1,pid:$pid,process_birth:$birth}' >"$1.owner.json"
}

run_dj() {
  run bash "$DJ" "$@" --scopes release-tmp
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "release-tmp leak: every orphan kind goes, installed snapshots and stamps stay" {
  local dead="$STORE/.tmp.2.0.0-$DIGEST.Dead01" ownerless="$STORE/.tmp.2.0.0-$DIGEST.NoOwner"
  local verify="$STORE/.tmp.2.0.0.verify.Verify01" retired="$STORE/2.0.0-$DIGEST"
  local orphan_owner="$STORE/.tmp.2.0.0-$DIGEST.OwnerOnly"
  make_tree "$dead"; owner "$dead" 2147483647 dead
  make_tree "$ownerless"; old "$ownerless"
  make_tree "$verify"; old "$verify"
  owner "$orphan_owner" 2147483647 dead
  make_tree "$retired"
  mkdir -p "$TRELLIS_HOME/releases/1.2.3" "$TRELLIS_HOME/releases/1.2.4-rc.1+build.2"
  local v area path
  for v in 1.2.3 1.2.4-rc.1+build.2 2.0.0; do
    make_tree "$STORE/$v-$DIGEST"
    for area in "$STAMPS" "$EXEC_STAMPS"; do
      printf 'stamp\n' >"$area/$v-$DIGEST.json"
      path="$area/.$v-$DIGEST.json.0123456789abcdef.tmp"
      printf 'interrupted writer\n' >"$path"; old "$path"
    done
  done
  chmod -R a-w "$retired"
  run_dj --apply --yes
  [ ! -e "$dead" ]; [ ! -e "$dead.owner.json" ]; [ ! -e "$ownerless" ]
  [ ! -e "$verify" ]; [ ! -e "$retired" ]; [ ! -e "$orphan_owner.owner.json" ]
  for area in "$STAMPS" "$EXEC_STAMPS"; do
    [ ! -e "$area/2.0.0-$DIGEST.json" ]
    [ -f "$area/1.2.3-$DIGEST.json" ]; [ -f "$area/1.2.4-rc.1+build.2-$DIGEST.json" ]
    run find "$area" -name '*.tmp'
    [ "$status" -eq 0 ]; [ -z "$output" ]
  done
  [ -d "$STORE/1.2.3-$DIGEST" ]; [ -d "$STORE/1.2.4-rc.1+build.2-$DIGEST" ]
}

@test "release-tmp keeps live owners and rejects PID reuse by birth token" {
  local live="$STORE/.tmp.2.0.0-$DIGEST.Live01" reused="$STORE/.tmp.2.0.0-$DIGEST.Reused01" birth
  birth="$(bash -c '. "$1/scripts/lib/trellis-home.sh"; trellis_process_birth "$2"' _ "$REPO_ROOT" "$$")"
  make_tree "$live"; owner "$live" "$$" "$birth"; old "$live" "$live.owner.json"
  make_tree "$reused"; owner "$reused" "$$" not-this-birth
  run_dj --apply --yes
  [ -f "$live/payload/marker" ]; [ -f "$live.owner.json" ]
  [ ! -e "$reused" ]; [ ! -e "$reused.owner.json" ]
}

@test "release-tmp keeps young ownerless work and malformed owners at any age" {
  local young="$STORE/.tmp.2.0.0-$DIGEST.Young01" malformed="$STORE/.tmp.2.0.0-$DIGEST.Malformed01"
  local temporary="$STAMPS/.2.0.0-$DIGEST.json.0123456789abcdef.tmp"
  make_tree "$young"; make_tree "$malformed"
  printf 'garbage\n' >"$malformed.owner.json"; old "$malformed" "$malformed.owner.json"
  printf 'writing\n' >"$temporary"
  run_dj --apply --yes
  [ -f "$young/payload/marker" ]; [ -f "$malformed/payload/marker" ]; [ -f "$temporary" ]
}

@test "release-tmp report and dry-run delete nothing and apply requires confirmation" {
  local work="$STORE/.tmp.2.0.0-$DIGEST.DryRun01"
  make_tree "$work"; owner "$work" 2147483647 dead
  run_dj
  [[ "$output" == *"[delete] $work "* ]]
  [ -f "$work/payload/marker" ]; [ -f "$work.owner.json" ]
  run_dj --dry-run
  [[ "$output" == *"[delete] $work "* ]]
  [ -f "$work/payload/marker" ]; [ -f "$work.owner.json" ]
  run_dj --apply </dev/null
  [ -f "$work/payload/marker" ]; [ -f "$work.owner.json" ]
}

@test "release-tmp protects active-but-absent releases and live uninstalled snapshots" {
  local active="$STORE/1.2.3-$DIGEST" live="$STORE/2.0.0-$DIGEST"
  make_tree "$active"; make_tree "$live"
  printf 'stamp\n' >"$STAMPS/1.2.3-$DIGEST.json"
  export DJ_OPEN_PATH="$live/payload/marker"
  run_dj --apply --yes
  [ -f "$active/payload/marker" ]; [ -f "$STAMPS/1.2.3-$DIGEST.json" ]
  [ -f "$live/payload/marker" ]
  unset DJ_OPEN_PATH
  printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/bin/lsof"
  run_dj --apply --yes
  [ -f "$live/payload/marker" ]
}

@test "release-tmp never follows symlink candidates or nested symlinks" {
  local outside="$SANDBOX/outside" work="$STORE/.tmp.2.0.0-$DIGEST.Links01"
  make_tree "$outside"; make_tree "$work"
  owner "$work" 2147483647 dead
  ln -s "$outside" "$work/payload/link"
  ln -s "$outside" "$STORE/2.0.0-$DIGEST"
  ln -s "$outside/payload/marker" "$STAMPS/2.0.0-$DIGEST.json"
  run_dj --apply --yes
  [ ! -e "$work" ]; [ -f "$outside/payload/marker" ]
  [ -L "$STORE/2.0.0-$DIGEST" ]; [ -L "$STAMPS/2.0.0-$DIGEST.json" ]
}

@test "release-tmp sink revalidates installed state, owner and planned inode" {
  local snapshot="$STORE/2.0.0-$DIGEST" work="$STORE/.tmp.2.0.0-$DIGEST.Changed01"
  make_tree "$snapshot"; make_tree "$work"; owner "$work" 2147483647 dead
  local script="$SANDBOX/revalidate.sh"
  cat >"$script" <<'SH'
set -eu
. "$1/scripts/lib/disk-janitor-lib.sh"
LSOF_SNAPSHOT_TMP="$TMPDIR/lsof"
printf 'ok\nn/elsewhere\n' >"$LSOF_SNAPSHOT_TMP"
rows="$(dj_release_tmp scan)"
while IFS="$(printf '\t')" read -r scope verdict kind path bytes repo detail device inode; do
  [ "$verdict" = delete ] || continue
  case "$kind" in
    exec-snapshot) mkdir "$TRELLIS_HOME/releases/2.0.0" ;;
    exec-work) printf 'garbage\n' >"$path.owner.json" ;;
  esac
  dj_release_tmp remove "$path" "$device" "$inode"
done <<EOF
$rows
EOF
# A stale device/inode must also refuse a still-reapable row.
rm -f "$2.owner.json"
touch -t 200001010000 "$2"
dj_release_tmp remove "$2" 0 0
SH
  run bash "$script" "$REPO_ROOT" "$work"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$snapshot/payload/marker" ]; [ -f "$work/payload/marker" ]
}

@test "release-tmp preserves old stamp temp files held by a live writer" {
  local temporary="$STAMPS/.2.0.0-$DIGEST.json.0123456789abcdef.tmp"
  printf 'writing\n' >"$temporary"; old "$temporary"
  export DJ_OPEN_PATH="$temporary"
  run_dj --apply --yes
  [ -f "$temporary" ]
}

@test "release-tmp supports the per-scope apply rollback switch in both validators" {
  local work="$STORE/.tmp.2.0.0-$DIGEST.Rollback01"
  make_tree "$work"; owner "$work" 2147483647 dead
  # Force the jq fallback independently of any host-local ajv installation.
  printf '#!/bin/sh\nexit 127\n' >"$SANDBOX/bin/ajv"
  printf '#!/bin/sh\nexit 127\n' >"$SANDBOX/bin/npx"
  chmod +x "$SANDBOX/bin/ajv" "$SANDBOX/bin/npx"
  run python3 -I -c 'import json, sys; assert "release-tmp" in json.load(open(sys.argv[1]))["properties"]["disk_janitor"]["properties"]["apply_disabled_scopes"]["items"]["enum"]' \
    "$REPO_ROOT/scripts/lib/trellis.config.schema.json"
  [ "$status" -eq 0 ]
  jq '.disk_janitor.apply_disabled_scopes = ["release-tmp"]' "$TRELLIS_CONFIG" >"$SANDBOX/policy.tmp"
  mv "$SANDBOX/policy.tmp" "$TRELLIS_CONFIG"
  run_dj --apply --yes
  [[ "$output" == *"apply disabled for scope release-tmp"* ]]
  [ -f "$work/payload/marker" ]
  run_dj --dry-run
  [[ "$output" == *"[delete] $work "* ]]
  [ -f "$work/payload/marker" ]
  jq '.disk_janitor.apply_disabled_scopes = []' "$TRELLIS_CONFIG" >"$SANDBOX/policy.tmp"
  mv "$SANDBOX/policy.tmp" "$TRELLIS_CONFIG"
  run_dj --apply --yes
  [ ! -e "$work" ]
}
