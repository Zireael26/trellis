#!/usr/bin/env bats
# Spec 069 A1: `trellis worktree add <branch>` creates only at the convention
# path <root>/<project>/<branch-slug> and refuses, creating nothing, an explicit
# path elsewhere, a target inside any git tree, and a slug collision.
#
# Hermetic: HOME, TRELLIS_HOME and the worktree root are sandboxes under
# BATS_TEST_TMPDIR; the operator's registry and worktrees are never read.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/worktree.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/wt-add.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis-home"
  export TRELLIS_WORKTREE_ROOT="$SANDBOX/worktrees"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  unset TRELLIS_CONFIG_PATH
  mkdir -p "$HOME" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  REPO="$SANDBOX/src/app"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
  printf 'seed\n' > "$REPO/seed.txt"
  git -C "$REPO" add seed.txt
  git -C "$REPO" commit -q -m init
  M0="$(git -C "$REPO" rev-parse HEAD)"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

add() {
  run bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$SCRIPT" add "$@"
}

register() {
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_register_worktree "$2" personal "$3" "$4" 1.2.3 "[\"claude\"]" ""
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$2" "$1" >/dev/null
}

# Nothing may appear under the root or in the branch list after a refusal.
assert_nothing_created() {
  [ -z "$(find "$TRELLIS_WORKTREE_ROOT" -mindepth 1 -print 2>/dev/null)" ] ||
    { find "$TRELLIS_WORKTREE_ROOT" -mindepth 1 -print; return 1; }
  [ "$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] || return 1
}

@test "add creates an unregistered repo's branch at _unregistered/<basename>/<slug>" {
  add feature/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  wt="$TRELLIS_WORKTREE_ROOT/_unregistered/app/feature-x"
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = feature/x ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$M0" ]
  [[ "$output" == *"worktree ready: $wt"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$REPO" config --get branch.feature/x.trellisParent)" = main ]
  [ "$(git -C "$REPO" config --get branch.feature/x.trellisBase)" = "$M0" ]
  [ "$(git -C "$REPO" config --get branch.feature/x.trellisSource)" = worktree ]
}

@test "add puts a registered repo under its project id" {
  register "$REPO" demo-project
  add topic
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$TRELLIS_WORKTREE_ROOT/demo-project/topic" symbolic-ref --short HEAD)" = topic ]
}

@test "add checks out an existing branch and records nothing new" {
  git -C "$REPO" branch existing
  add existing
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$TRELLIS_WORKTREE_ROOT/_unregistered/app/existing" symbolic-ref --short HEAD)" = existing ]
  run git -C "$REPO" config --get branch.existing.trellisParent
  [ "$status" -eq 1 ]
}

@test "add with a start point bases the new branch there" {
  git -C "$REPO" checkout -q -b side
  git -C "$REPO" commit -q --allow-empty -m side
  SIDE="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  add stacked side
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$TRELLIS_WORKTREE_ROOT/_unregistered/app/stacked" rev-parse HEAD)" = "$SIDE" ]
  [ "$(git -C "$REPO" config --get branch.stacked.trellisParent)" = side ]
}

@test "add --detach names the directory detached-<shortsha>" {
  add --detach
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  wt="$TRELLIS_WORKTREE_ROOT/_unregistered/app/detached-$(printf '%s' "$M0" | cut -c1-7)"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$M0" ]
  run git -C "$wt" symbolic-ref -q HEAD
  [ "$status" -ne 0 ]
}

@test "add accepts an explicit path equal to the convention path" {
  add feature/y "$TRELLIS_WORKTREE_ROOT/_unregistered/app/feature-y"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$TRELLIS_WORKTREE_ROOT/_unregistered/app/feature-y" ]
}

@test "add refuses an explicit path outside the convention and creates nothing" {
  add feature/z "$SANDBOX/elsewhere"
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"convention path"* ]] || { echo "$output"; return 1; }
  [ ! -e "$SANDBOX/elsewhere" ]
  assert_nothing_created
  run git -C "$REPO" show-ref --verify --quiet refs/heads/feature/z
  [ "$status" -ne 0 ]
}

@test "add refuses a target inside a git tree (the root nested in a repo)" {
  export TRELLIS_WORKTREE_ROOT="$REPO/.claude/worktrees"
  add nested
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"inside the git tree"* ]] || { echo "$output"; return 1; }
  [ ! -e "$REPO/.claude" ]
  run git -C "$REPO" show-ref --verify --quiet refs/heads/nested
  [ "$status" -ne 0 ]
}

@test "add refuses a slug collision between a/b and a-b" {
  add a/b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  add a-b
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"collision"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$TRELLIS_WORKTREE_ROOT/_unregistered/app/a-b" symbolic-ref --short HEAD)" = a/b ]
  run git -C "$REPO" show-ref --verify --quiet refs/heads/a-b
  [ "$status" -ne 0 ]
}

@test "add refuses raw git-worktree flags with a migration hint" {
  for flag in -b -B --reason; do
    add "$flag" topic "$SANDBOX/wt"
    [ "$status" -eq 2 ] || { echo "$flag: $output"; return 1; }
    [[ "$output" == *"trellis worktree add <branch>"* ]] || { echo "$output"; return 1; }
  done
  add -btopic "$SANDBOX/wt"
  [ "$status" -eq 2 ]
  assert_nothing_created
}

@test "add refuses a start point for a branch that already exists" {
  git -C "$REPO" branch existing
  add existing main
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  assert_nothing_created
}

@test "add --no-checkout defers attachment and still lands at the convention path" {
  add --no-checkout later
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$TRELLIS_WORKTREE_ROOT/_unregistered/app/later" ]
  [ ! -e "$TRELLIS_WORKTREE_ROOT/_unregistered/app/later/seed.txt" ]
  [[ "$output" == *"will reconcile on first checkout"* ]] || { echo "$output"; return 1; }
}
