#!/usr/bin/env bats
# Spec 069 lane DW, A11 and A8: the janitor's worktrees scope enumerates
# `git worktree list` of every repository under the central worktree root and
# worktrees.known_parents, not only registry rows. A worktree with no registry
# row is reported (and may be dehydrated); a Codex app worktree under `_codex`
# is reported and never touched; pi worktrees stay with the pi scope.
#
# Hermetic: HOME, TRELLIS_HOME, the worktree root and every repository live in
# a fresh sandbox under BATS_TEST_TMPDIR.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"
OLD_STAMP="202001010000"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-enumerate.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  CANON="$SANDBOX/canonical"
  ROOT="$HOME/projects/worktrees"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$CANON/audits" "$ROOT"
  chmod 700 "$TRELLIS_HOME"
  export HOME TRELLIS_HOME
  export TRELLIS_WORKTREE_ROOT="$ROOT"
  export GIT_CONFIG_NOSYSTEM=1
  unset TRELLIS_CONFIG_PATH
  write_config '[]'
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

# write_config KNOWN_PARENTS_JSON
write_config() {
  jq -n --argjson kp "$1" \
    '{schema_version: 2, maintainer_name: "T", github_user: "t", harnesses: ["claude"],
      worktrees: {known_parents: $kp}}' > "$CANON/trellis.config.json"
  cat > "$TRELLIS_HOME/config.json" <<JSON
{"schema_version":1,"source_root":"$CANON","release_remote":"https://example.invalid/t.git","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$HOME/projects"]}}}
JSON
  chmod 600 "$TRELLIS_HOME/config.json"
}

register() {
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_register_worktree "$2" personal "$3" "$4" 1.2.3 "[\"claude\"]" ""
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$2" "$1" >/dev/null
}

run_dj() {
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    DJ_MERGED_OVERRIDE="${MERGED:-unmerged}" DJ_PUSHED_OVERRIDE=unpushed \
    bash "$DJ" "$@" </dev/null
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
  printf '{"name":"fixture"}\n' > "$dir/package.json"
  printf 'lockfileVersion: 9\n' > "$dir/pnpm-lock.yaml"
  printf 'node_modules\n.env\n' > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
}

add_wt() {
  mkdir -p "$(dirname "$2")"
  git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1
}

backdate() {
  local gd common ref
  gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  touch -t "$OLD_STAMP" "$gd/HEAD" "$gd/index" "$gd/logs/HEAD"
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  if ref="$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null)"; then
    if [ -f "$common/$ref" ]; then
      touch -t "$OLD_STAMP" "$common/$ref"
    elif [ -f "$common/packed-refs" ]; then
      touch -t "$OLD_STAMP" "$common/packed-refs"
    fi
  fi
}

fill() {
  mkdir -p "$1"
  dd if=/dev/zero of="$1/blob" bs=1024 count=16 >/dev/null 2>&1
}

@test "an unregistered repo's worktree under the central root is reported" {
  make_repo "$ROOT/_unregistered/app/main"
  local wt="$ROOT/_unregistered/app/feat-x"
  add_wt "$ROOT/_unregistered/app/main" "$wt" feat/x
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[candidate] $wt ("*"no registry row"*"branch=feat/x"* ]] || { echo "$output"; false; }
  # The main checkout is never a row.
  [[ "$output" != *"] $ROOT/_unregistered/app/main ("* ]] || { echo "$output"; false; }
}

@test "known_parents reach a legacy layout; without them it stays unseen" {
  make_repo "$HOME/legacy/app"
  local wt="$HOME/legacy/app-wt/feat-y"
  add_wt "$HOME/legacy/app" "$wt" feat/y
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"$wt"* ]] || { echo "$output"; false; }

  write_config '["~/legacy"]'
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[candidate] $wt ("*"no registry row"* ]] || { echo "$output"; false; }
}

@test "a registered checkout's unregistered worktree is reported once, its registered one once" {
  make_repo "$HOME/projects/app"
  local reg="$HOME/projects/app-wt/reg" unreg="$HOME/projects/app-wt/unreg"
  add_wt "$HOME/projects/app" "$reg" feat/reg
  add_wt "$HOME/projects/app" "$unreg" feat/unreg
  register "$HOME/projects/app" app
  register "$reg" app
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c "\] $reg (")" -eq 1 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c "\] $unreg (.*no registry row")" -eq 1 ] || { echo "$output"; false; }
}

@test "an idle unregistered worktree is dehydrated; a _codex one never is (A8)" {
  make_repo "$HOME/src/app"
  local plain="$ROOT/_unregistered/app/feat-z" codex="$ROOT/_codex/1a2b/app"
  add_wt "$HOME/src/app" "$plain" feat/z
  add_wt "$HOME/src/app" "$codex" codex/task
  fill "$plain/node_modules/pkg"
  fill "$codex/node_modules/pkg"
  backdate "$plain"
  backdate "$codex"

  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[skip] $codex ("*"Codex app worktree"*"never removed or dehydrated"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --dehydrate --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$plain/node_modules" ]
  [ -f "$codex/node_modules/pkg/blob" ]
  [ -d "$codex" ] && [ -d "$plain" ]
}

@test "pi worktrees are left to the pi scope" {
  make_repo "$ROOT/_unregistered/app/main"
  local pi="$HOME/.pi-worktrees/pi-agent-1"
  add_wt "$ROOT/_unregistered/app/main" "$pi" pi/agent
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"$pi"* ]] || { echo "$output"; false; }
}

@test "--project limits the run to registry rows: nothing is enumerated" {
  make_repo "$HOME/projects/app"
  register "$HOME/projects/app" app
  local wt="$ROOT/_unregistered/other/feat"
  make_repo "$ROOT/_unregistered/other/main"
  add_wt "$ROOT/_unregistered/other/main" "$wt" feat/o
  run_dj --report --project app --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"$wt"* ]] || { echo "$output"; false; }
}

@test "a repository git cannot read is reported and nothing in it is touched" {
  mkdir -p "$ROOT/broken/repo/.git" "$ROOT/broken/repo/node_modules"
  printf 'garbage\n' > "$ROOT/broken/repo/.git/HEAD"
  printf 'x\n' > "$ROOT/broken/repo/node_modules/x"
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[skip] $ROOT/broken/repo ("*"git cannot read this repository"* ]] || { echo "$output"; false; }
  run_dj --apply --yes --dehydrate --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$ROOT/broken/repo/node_modules/x" ]
}
