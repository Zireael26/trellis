#!/usr/bin/env bats
# Read-only worktree enumeration with fake homes and stubbed host tools.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/dj-registered.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; CANON="$SANDBOX/canonical"; MAIN="$SANDBOX/repo"; STUB_BIN="$SANDBOX/bin"
  TRELLIS_WORKTREE_ROOT="$HOME/projects/worktrees"
  CC="$TRELLIS_WORKTREE_ROOT/_unregistered/repo/cc-t1"
  OTHER="$TRELLIS_WORKTREE_ROOT/_unregistered/repo/cc-t2"
  local fenced_git
  fenced_git="$(command -v git)"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$CANON/audits" "$STUB_BIN" "$(dirname "$CC")"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  printf '#!/bin/bash\nexec %q "$@"\n' "$fenced_git" > "$STUB_BIN/git"
  printf '#!/bin/sh\nprintf "[{\\\"number\\\":1,\\\"state\\\":\\\"MERGED\\\",\\\"headRefOid\\\":\\\"%%s\\\"}]\\n" "$FIXTURE_HEAD"\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/launchctl"
  chmod 700 "$STUB_BIN/git" "$STUB_BIN/gh" "$STUB_BIN/launchctl"
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME TRELLIS_WORKTREE_ROOT PATH
  printf '%s\n' '{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude"]}' > "$CANON/trellis.config.json"
  printf '{"schema_version":1,"source_root":"%s","release_remote":"%s","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["%s"]}}}\n' "$CANON" "$CANON" "$SANDBOX" > "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/config.json" "$TRELLIS_HOME/registry.json"
  git init -q -b main "$MAIN"
  git -C "$MAIN" config user.name fixture
  git -C "$MAIN" config user.email fixture@example.invalid
  printf 'tracked\n' > "$MAIN/tracked"; git -C "$MAIN" add tracked; git -C "$MAIN" commit -qm fixture
  git -C "$MAIN" worktree add -q -b worktree-t1 "$CC"
  git -C "$MAIN" worktree add -q -b worktree-t2 "$OTHER"
  FIXTURE_HEAD="$(git -C "$MAIN" rev-parse HEAD)"; export FIXTURE_HEAD
  local wt gd ref common
  for wt in "$CC" "$OTHER"; do
    gd="$(git -C "$wt" rev-parse --absolute-git-dir)"; common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
    ref="$(git -C "$wt" symbolic-ref -q HEAD)"
    touch -t 202001010000 "$gd/HEAD" "$gd/index" "$gd/logs/HEAD" "$common/$ref"
  done
  run bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; local_registry_register_worktree "$2" personal fixture "$3" 1.2.3 '\''["claude"]'\'' ""' _ "$REPO_ROOT" "$TRELLIS_HOME" "$CC"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  ln -s "$CC" "$SANDBOX/alias"
  jq --arg root "$CC" --arg alias "$SANDBOX/alias" '(.projects[].checkouts[].worktrees[] | select(.root == $root) | .root) = $alias' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry.next"
  mv "$SANDBOX/registry.next" "$TRELLIS_HOME/registry.json"; chmod 600 "$TRELLIS_HOME/registry.json"
}
teardown() { [ -z "${SANDBOX:-}" ] || { chmod -R u+rwX "$SANDBOX"; rm -rf "${SANDBOX:?}"; }; }

@test "a registered symlink-spelled root is never treated as an unregistered worktree" {
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash "$REPO_ROOT/scripts/disk-janitor.sh" --dry-run --scopes worktrees
  [[ "$output" != *"git worktree remove  $CC"* ]] || { echo "$output"; false; }
  [[ "$output" == *"git worktree remove  $OTHER"* ]] || { echo "$output"; false; }

  # Ownership in another fleet still protects the same physical worktree.
  jq '.projects = {"work/fixture": (.projects["personal/fixture"] | .fleet = "work")}' \
    "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-other"
  mv "$SANDBOX/registry-other" "$TRELLIS_HOME/registry.json"; chmod 600 "$TRELLIS_HOME/registry.json"
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash "$REPO_ROOT/scripts/disk-janitor.sh" --dry-run --scopes worktrees
  [[ "$output" != *"git worktree remove  $CC"* ]] || { echo "$output"; false; }
  [[ "$output" == *"git worktree remove  $OTHER"* ]] || { echo "$output"; false; }
}

# Exercise the real apply sink with a previously captured plan, but make the
# verdict and liveness deterministic. All Git mutations are inside the fixture
# and still pass through the runner's Git fence.
apply_planned_sweep() {
  local tree="$1" common
  . "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"
  . "$REPO_ROOT/scripts/lib/hygiene-common.sh"
  . "$REPO_ROOT/scripts/lib/disk-janitor-dehydrate.sh"
  common="$(_hy_common_dir "$MAIN")"
  PLAN_TMP="$SANDBOX/plan"; LSOF_SNAPSHOT_TMP="$SANDBOX/lsof"; EXIT_STATUS=0
  printf 'worktrees\tsweep\tworktree-cc\t%s\t0\t%s\tplanned\t\t\t\t\t%s\t%s\n' "$tree" "$common" "$common" "$MAIN" > "$PLAN_TMP"
  sum_bytes() { echo 0; }
  confirm_category() { return 0; }
  dj_capture_lsof_snapshot() { return 0; }
  _dw_cc_verdict() { printf 'sweep\t1\t%s\tmerged\n' "$FIXTURE_HEAD"; }
  _dw_apply_sweep
}

@test "sweep rechecks missing and unreadable registry under lock before removing a registered worktree" {
  local mode
  for mode in missing unreadable; do
    if [ "$mode" = unreadable ] && [ "$(id -u)" -eq 0 ]; then continue; fi
    if [ "$mode" = missing ]; then
      mv "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-aside"
    else
      chmod 000 "$TRELLIS_HOME/registry.json"
    fi
    run apply_planned_sweep "$CC"
    if [ "$mode" = missing ]; then
      mv "$SANDBOX/registry-aside" "$TRELLIS_HOME/registry.json"
    else
      chmod 600 "$TRELLIS_HOME/registry.json"
    fi
    [ "$status" -eq 0 ] && [[ "$output" == *"registry ownership present or unknown"* ]] || { echo "$mode: $output"; false; }
    [ -d "$CC" ] && git -C "$MAIN" show-ref --verify --quiet refs/heads/worktree-t1 || { echo "$mode: registered worktree or branch deleted"; false; }
  done
  # With a readable registry, an actually unregistered worktree is removable.
  run apply_planned_sweep "$OTHER"
  [ "$status" -eq 0 ] && [[ "$output" == *"removed worktree: $OTHER"* ]] || { echo "$output"; false; }
  [ ! -d "$OTHER" ] && ! git -C "$MAIN" show-ref --verify --quiet refs/heads/worktree-t2
}

@test "missing registry withholds the sweep from dry-run as well as apply" {
  mv "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-aside"
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash "$REPO_ROOT/scripts/disk-janitor.sh" --dry-run --scopes worktrees
  [[ "$output" == *"$TRELLIS_HOME/registry.json"*"could not"* || "$output" == *"could not"*"$TRELLIS_HOME/registry.json"* ]] || { echo "$output"; false; }
  [[ "$output" != *"git worktree remove  $CC"* && "$output" != *"git worktree remove  $OTHER"* ]] || { echo "$output"; false; }
}

@test "an unresolvable registry root reports that ownership could not be checked" {
  [ "$(id -u)" -ne 0 ] || skip 'root can search mode-000 directories'
  local root="$SANDBOX/locked/alias"
  mkdir -p "$SANDBOX/locked"
  ln -s "$CC" "$root"
  jq --arg root "$root" '(.projects[].checkouts[].worktrees[] | .root) = $root' "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry-next"
  mv "$SANDBOX/registry-next" "$TRELLIS_HOME/registry.json"; chmod 600 "$TRELLIS_HOME/registry.json"
  chmod 000 "$SANDBOX/locked"
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash "$REPO_ROOT/scripts/disk-janitor.sh" --dry-run --scopes worktrees
  chmod 700 "$SANDBOX/locked"
  [[ "$output" == *"could not check"*"$root"* ]] || { echo "$output"; false; }
  [[ "$output" != *"git worktree remove  $OTHER"* ]] || { echo "$output"; false; }
}

@test "persisted worktree ID protects a registered tree even if its old root now points elsewhere" {
  mkdir -p "$SANDBOX/different"
  mv "$SANDBOX/alias" "$SANDBOX/alias-aside"
  ln -s "$SANDBOX/different" "$SANDBOX/alias"
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash "$REPO_ROOT/scripts/disk-janitor.sh" --dry-run --scopes worktrees
  [[ "$output" != *"git worktree remove  $CC"* ]] || { echo "$output"; false; }
  [[ "$output" == *"git worktree remove  $OTHER"* ]] || { echo "$output"; false; }
}

@test "unregistered-tree recheck refuses registry ownership or an unavailable registry" {
  local common
  common="$(git -C "$MAIN" rev-parse --absolute-git-dir)"
  run bash -c '. "$1/scripts/lib/disk-janitor-lib.sh"; . "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/disk-janitor-dehydrate.sh"; _dw_owner_unchanged "$2" "" "" "" "" "$3" ""' _ "$REPO_ROOT" "$CC" "$common"
  [ "$status" -ne 0 ] || { echo 'registered alias passed mutation recheck'; false; }
  run bash -c '. "$1/scripts/lib/disk-janitor-lib.sh"; . "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/disk-janitor-dehydrate.sh"; _dw_owner_unchanged "$2" "" "" "" "" "$3" ""' _ "$REPO_ROOT" "$OTHER" "$common"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mv "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-aside"
  run bash -c '. "$1/scripts/lib/disk-janitor-lib.sh"; . "$1/scripts/lib/hygiene-common.sh"; . "$1/scripts/lib/disk-janitor-dehydrate.sh"; _dw_owner_unchanged "$2" "" "" "" "" "$3" ""' _ "$REPO_ROOT" "$OTHER" "$common"
  [ "$status" -ne 0 ] || { echo 'missing registry passed mutation recheck'; false; }
}
