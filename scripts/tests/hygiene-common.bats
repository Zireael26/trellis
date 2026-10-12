#!/usr/bin/env bats
# Spec 069 L-0: the shared hygiene helpers (scripts/lib/hygiene-common.sh) that
# the worktree convention, migrate, the Claude Code worktree hooks and the
# janitor's dehydrate and enumeration scopes all build on.
#
# Hermetic: HOME, TRELLIS_HOME and the worktree root are fresh sandboxes under
# BATS_TEST_TMPDIR; the operator's registry and worktrees are never read.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/hygiene-common.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/hygiene.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  export HOME TRELLIS_HOME
  unset TRELLIS_WORKTREE_ROOT TRELLIS_CONFIG_PATH
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

# hy FN ARGS... — run one helper in a fresh shell that sourced only the lib.
hy() {
  run bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -q -m init
}

register() {
  local root="$1" project_id="$2"
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_register_worktree "$2" personal "$3" "$4" 1.2.3 "[\"claude\"]" ""
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$project_id" "$root" >/dev/null
}

# ---------------------------------------------------------------------------
# hy_root
# ---------------------------------------------------------------------------

@test "hy_root defaults to ~/projects/worktrees" {
  hy hy_root
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/projects/worktrees" ]
}

@test "hy_root reads worktrees.root from the policy, expanding ~ and dropping a trailing slash" {
  printf '%s\n' '{"worktrees":{"root":"~/wt/"}}' > "$SANDBOX/policy.json"
  TRELLIS_CONFIG_PATH="$SANDBOX/policy.json" hy hy_root
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/wt" ]
}

@test "hy_root prefers TRELLIS_WORKTREE_ROOT over the policy" {
  printf '%s\n' '{"worktrees":{"root":"~/wt"}}' > "$SANDBOX/policy.json"
  TRELLIS_CONFIG_PATH="$SANDBOX/policy.json" TRELLIS_WORKTREE_ROOT="$SANDBOX/override" hy hy_root
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/override" ]
}

@test "hy_root refuses a relative root" {
  TRELLIS_WORKTREE_ROOT="projects/worktrees" hy hy_root
  [ "$status" -eq 2 ]
  [ -z "$output" ] || [[ "$output" == *"must be absolute"* ]]
}

@test "hy_root prints the canonical spelling of an existing root" {
  mkdir -p "$SANDBOX/real-root"
  ln -s "$SANDBOX/real-root" "$SANDBOX/link-root"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/link-root" hy hy_root
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/real-root" ]
}

# ---------------------------------------------------------------------------
# hy_slug
# ---------------------------------------------------------------------------

@test "hy_slug replaces / with - so a/b and a-b collide on one slug" {
  hy hy_slug a/b
  [ "$status" -eq 0 ]
  [ "$output" = "a-b" ]
  hy hy_slug a-b
  [ "$output" = "a-b" ]
  hy hy_slug refs/heads/feat/x/y
  [ "$output" = "feat-x-y" ]
}

@test "hy_slug names a detached HEAD detached-<shortsha>" {
  hy hy_slug --detached 0123456789abcdef0123456789abcdef01234567
  [ "$status" -eq 0 ]
  [ "$output" = "detached-0123456" ]
}

@test "hy_slug refuses an empty branch and a non-hex sha" {
  hy hy_slug ""
  [ "$status" -eq 2 ]
  hy hy_slug --detached xyz1234
  [ "$status" -eq 2 ]
  hy hy_slug --detached abc12
  [ "$status" -eq 2 ]
}

@test "hy_slug refuses dot, dash-leading and control-character slugs" {
  local bad
  for bad in . .. refs/heads/.. -x .hidden "a$(printf '\t')b" "a$(printf '\001')b" "a$(printf '\177')b"; do
    hy hy_slug "$bad"
    [ "$status" -eq 2 ] || { echo "accepted [$bad]: $output"; false; }
    [ -z "$output" ]
  done
}

@test "hy_slug caps a long slug at 96 bytes with a hash suffix that keeps names distinct" {
  local long_a long_b
  long_a="feat/$(printf 'a%.0s' $(seq 1 200))"
  long_b="${long_a}b"
  hy hy_slug "$long_a"
  [ "$status" -eq 0 ]
  local slug_a="$output"
  [ "$(printf '%s' "$slug_a" | LC_ALL=C wc -c | tr -d ' ')" -le 96 ] || { echo "$slug_a"; false; }
  [[ "$slug_a" == feat-aaaa*-* ]] || { echo "$slug_a"; false; }
  hy hy_slug "$long_b"
  [ "$status" -eq 0 ]
  [ "$output" != "$slug_a" ]
  # A multibyte name is cut on a character boundary, never mid-sequence.
  hy hy_slug "$(printf 'é%.0s' $(seq 1 80))"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | LC_ALL=C wc -c | tr -d ' ')" -le 96 ]
  printf '%s' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null
  # A short slug is unchanged.
  hy hy_slug feat/short
  [ "$output" = feat-short ]
}

# ---------------------------------------------------------------------------
# hy_project_dir
# ---------------------------------------------------------------------------

@test "hy_project_dir uses the registry project id for a registered checkout and its linked worktrees" {
  git_repo "$SANDBOX/src/alpha-clone"
  register "$SANDBOX/src/alpha-clone" alpha
  git -C "$SANDBOX/src/alpha-clone" worktree add -q -b side "$SANDBOX/elsewhere/side"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_project_dir "$SANDBOX/src/alpha-clone"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/alpha" ]
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_project_dir "$SANDBOX/elsewhere/side"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/alpha" ]
}

@test "hy_project_dir falls back to _unregistered/<main checkout basename>" {
  git_repo "$SANDBOX/src/loose-repo"
  git -C "$SANDBOX/src/loose-repo" worktree add -q -b side "$SANDBOX/elsewhere/side"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_project_dir "$SANDBOX/elsewhere/side"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/_unregistered/loose-repo" ]
  rm -f "$TRELLIS_HOME/registry.json"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_project_dir "$SANDBOX/src/loose-repo"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/_unregistered/loose-repo" ]
}

@test "hy_project_dir refuses a non-repository and an unreadable registry" {
  mkdir -p "$SANDBOX/plain"
  hy hy_project_dir "$SANDBOX/plain"
  [ "$status" -eq 2 ]
  git_repo "$SANDBOX/src/r"
  printf 'not json\n' > "$TRELLIS_HOME/registry.json"
  hy hy_project_dir "$SANDBOX/src/r"
  [ "$status" -eq 4 ]
}

@test "hy_project_dir refuses a common dir that two project ids claim" {
  git_repo "$SANDBOX/src/twin"
  register "$SANDBOX/src/twin" one
  jq '.projects["personal/two"] = (.projects["personal/one"] | .project_id = "two")' \
    "$TRELLIS_HOME/registry.json" > "$SANDBOX/r.json"
  mv "$SANDBOX/r.json" "$TRELLIS_HOME/registry.json"
  hy hy_project_dir "$SANDBOX/src/twin"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# hy_convention_path
# ---------------------------------------------------------------------------

@test "hy_convention_path is <root>/<project>/<slug>" {
  git_repo "$SANDBOX/src/alpha"
  register "$SANDBOX/src/alpha" alpha
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" feat/x
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/alpha/feat-x" ]
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" --detached "$(git -C "$SANDBOX/src/alpha" rev-parse HEAD)"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/alpha/detached-$(git -C "$SANDBOX/src/alpha" rev-parse HEAD | cut -c1-7)" ]
}

@test "hy_convention_path reports the a/b versus a-b collision with exit 3" {
  git_repo "$SANDBOX/src/alpha"
  register "$SANDBOX/src/alpha" alpha
  git -C "$SANDBOX/src/alpha" worktree add -q -b a-b "$SANDBOX/wt/alpha/a-b"
  # The same branch at its own convention path is not a collision.
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" a-b
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/wt/alpha/a-b" ]
  # a/b maps to the slug a-b already held by a different branch.
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" a/b
  [ "$status" -eq 3 ]
  [ "$output" = "$SANDBOX/wt/alpha/a-b" ]
  # A plain directory at the target is a collision too.
  mkdir -p "$SANDBOX/wt/alpha/stray"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" stray
  [ "$status" -eq 3 ]
}

@test "hy_convention_path treats the same branch from another clone of the project as a collision" {
  git_repo "$SANDBOX/src/alpha"
  register "$SANDBOX/src/alpha" alpha
  git clone -q "$SANDBOX/src/alpha" "$SANDBOX/src/alpha-2"
  register "$SANDBOX/src/alpha-2" alpha
  git -C "$SANDBOX/src/alpha" worktree add -q -b topic "$SANDBOX/wt/alpha/topic"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha-2" topic
  [ "$status" -eq 3 ]
}

@test "hy_convention_path refuses a project directory that resolves outside the root" {
  git_repo "$SANDBOX/src/alpha"
  register "$SANDBOX/src/alpha" alpha
  mkdir -p "$SANDBOX/wt" "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$SANDBOX/wt/alpha"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" feat/x
  [ "$status" -eq 3 ] || { echo "$output"; false; }
}

@test "hy_convention_path sees a case-only collision on a case-insensitive volume" {
  mkdir -p "$SANDBOX/case-probe"
  [ -e "$SANDBOX/CASE-PROBE" ] || skip "volume is case-sensitive"
  git_repo "$SANDBOX/src/alpha"
  register "$SANDBOX/src/alpha" alpha
  git -C "$SANDBOX/src/alpha" worktree add -q -b feat-x "$SANDBOX/wt/alpha/feat-x"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/wt" hy hy_convention_path "$SANDBOX/src/alpha" Feat-X
  [ "$status" -eq 3 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# hy_is_sanctioned
# ---------------------------------------------------------------------------

@test "hy_is_sanctioned accepts the central root (with _pi) and main checkouts only" {
  mkdir -p "$SANDBOX/wt" "$HOME/.pi-worktrees/pi-agent-1" "$TRELLIS_HOME/pi-worktrees/pi-agent-2"
  git_repo "$SANDBOX/src/alpha"
  git -C "$SANDBOX/src/alpha" worktree add -q -b inside "$SANDBOX/src/alpha/.claude/worktrees/inside"
  git -C "$SANDBOX/src/alpha" worktree add -q -b outside "$SANDBOX/scatter/outside"
  export TRELLIS_WORKTREE_ROOT="$SANDBOX/wt"

  hy hy_is_sanctioned "$SANDBOX/wt/alpha/feat-x"
  [ "$status" -eq 0 ]
  hy hy_is_sanctioned "$SANDBOX/wt/_codex/abc"
  [ "$status" -eq 0 ]
  hy hy_is_sanctioned "$SANDBOX/wt/_unregistered/r/x"
  [ "$status" -eq 0 ]
  hy hy_is_sanctioned "$SANDBOX/wt/_pi/pi-agent-1"
  [ "$status" -eq 0 ]
  hy hy_is_sanctioned "$SANDBOX/src/alpha"
  [ "$status" -eq 0 ]

  # Both legacy pi roots are drained, not sanctioned (pi moved to <root>/_pi).
  hy hy_is_sanctioned "$HOME/.pi-worktrees/pi-agent-1"
  [ "$status" -eq 1 ]

  hy hy_is_sanctioned "$SANDBOX/wt"
  [ "$status" -eq 1 ]
  hy hy_is_sanctioned "$SANDBOX/wt-sibling/x"
  [ "$status" -eq 1 ]
  hy hy_is_sanctioned "$TRELLIS_HOME/pi-worktrees/pi-agent-2"
  [ "$status" -eq 1 ]
  hy hy_is_sanctioned "$SANDBOX/src/alpha/.claude/worktrees/inside"
  [ "$status" -eq 1 ]
  hy hy_is_sanctioned "$SANDBOX/scatter/outside"
  [ "$status" -eq 1 ]
  # A dot component could escape the prefix test below a missing root.
  TRELLIS_WORKTREE_ROOT="$SANDBOX/no-such-root" hy hy_is_sanctioned "$SANDBOX/no-such-root/../escape"
  [ "$status" -eq 2 ]
}

@test "hy_is_sanctioned compares canonical paths" {
  mkdir -p "$SANDBOX/real-wt/alpha/x"
  ln -s "$SANDBOX/real-wt" "$SANDBOX/link-wt"
  TRELLIS_WORKTREE_ROOT="$SANDBOX/real-wt" hy hy_is_sanctioned "$SANDBOX/link-wt/alpha/x"
  [ "$status" -eq 0 ]
  TRELLIS_WORKTREE_ROOT="$SANDBOX/link-wt" hy hy_is_sanctioned "$SANDBOX/real-wt/alpha/x"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# hy_inside_git_tree
# ---------------------------------------------------------------------------

@test "hy_inside_git_tree checks every ancestor, including ones that do not exist yet" {
  git_repo "$SANDBOX/src/alpha"
  hy hy_inside_git_tree "$SANDBOX/src/alpha/not/yet/created"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/src/alpha" ]

  git -C "$SANDBOX/src/alpha" worktree add -q -b linked "$SANDBOX/linked"
  hy hy_inside_git_tree "$SANDBOX/linked/deeper"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/linked" ]

  hy hy_inside_git_tree "$SANDBOX/wt/alpha/feat-x"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "hy_inside_git_tree finds an outer repository even when git discovery would stop" {
  git_repo "$SANDBOX/outer"
  mkdir -p "$SANDBOX/outer/sub"
  GIT_CEILING_DIRECTORIES="$SANDBOX/outer" hy hy_inside_git_tree "$SANDBOX/outer/sub/target"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/outer" ]
}

# ---------------------------------------------------------------------------
# hy_regenerable_kind
# ---------------------------------------------------------------------------

@test "hy_regenerable_kind names the unconditional regenerable directories" {
  local name
  for name in node_modules .venv .next .turbo .mypy_cache .pytest_cache .ruff_cache __pycache__; do
    mkdir -p "$SANDBOX/t/$name"
    hy hy_regenerable_kind "$SANDBOX/t/$name"
    [ "$status" -eq 0 ] || { echo "$name: $output"; false; }
    [ "$output" = "$name" ]
  done
}

@test "hy_regenerable_kind requires a lockfile or build manifest beside dist, build and target" {
  local name
  for name in dist build target; do
    mkdir -p "$SANDBOX/bare/$name"
    hy hy_regenerable_kind "$SANDBOX/bare/$name"
    [ "$status" -eq 1 ] || { echo "$name without a manifest: $output"; false; }
  done
  mkdir -p "$SANDBOX/js/dist" "$SANDBOX/py/build" "$SANDBOX/rs/target" "$SANDBOX/lock/build"
  printf '{}\n' > "$SANDBOX/js/package.json"
  printf '[project]\n' > "$SANDBOX/py/pyproject.toml"
  printf '[package]\n' > "$SANDBOX/rs/Cargo.toml"
  : > "$SANDBOX/lock/pnpm-lock.yaml"
  hy hy_regenerable_kind "$SANDBOX/js/dist"
  [ "$status" -eq 0 ] && [ "$output" = dist ]
  hy hy_regenerable_kind "$SANDBOX/py/build"
  [ "$status" -eq 0 ] && [ "$output" = build ]
  hy hy_regenerable_kind "$SANDBOX/rs/target"
  [ "$status" -eq 0 ] && [ "$output" = target ]
  hy hy_regenerable_kind "$SANDBOX/lock/build"
  [ "$status" -eq 0 ] && [ "$output" = build ]
}

@test "hy_regenerable_kind refuses other names, files and symlinks" {
  mkdir -p "$SANDBOX/t/.env.d" "$SANDBOX/t/real-modules"
  : > "$SANDBOX/t/.env"
  : > "$SANDBOX/t/data.sqlite"
  printf 'x\n' > "$SANDBOX/t/__pycache__"
  ln -s "$SANDBOX/t/real-modules" "$SANDBOX/t/node_modules"
  local path
  for path in "$SANDBOX/t/.env" "$SANDBOX/t/.env.d" "$SANDBOX/t/data.sqlite" \
    "$SANDBOX/t/__pycache__" "$SANDBOX/t/node_modules" "$SANDBOX/t/missing"; do
    hy hy_regenerable_kind "$path"
    [ "$status" -eq 1 ] || { echo "$path: $output"; false; }
    [ -z "$output" ]
  done
}

@test "hy_regenerable_kind matches each conditional kind to its own build files" {
  mkdir -p "$SANDBOX/py/target" "$SANDBOX/rs/dist" "$SANDBOX/mvn/target" "$SANDBOX/cm/build"
  : > "$SANDBOX/py/requirements.txt"
  : > "$SANDBOX/py/pyproject.toml"
  : > "$SANDBOX/rs/Cargo.toml"
  : > "$SANDBOX/mvn/pom.xml"
  : > "$SANDBOX/cm/CMakeLists.txt"
  hy hy_regenerable_kind "$SANDBOX/py/target"
  [ "$status" -eq 1 ] || { echo "target beside Python files: $output"; false; }
  hy hy_regenerable_kind "$SANDBOX/rs/dist"
  [ "$status" -eq 1 ] || { echo "dist beside Cargo.toml: $output"; false; }
  hy hy_regenerable_kind "$SANDBOX/cm/build"
  [ "$status" -eq 1 ] || { echo "build beside CMakeLists.txt: $output"; false; }
  hy hy_regenerable_kind "$SANDBOX/mvn/target"
  [ "$status" -eq 0 ] && [ "$output" = target ]
}

@test "hy_regenerable_kind refuses a directory holding any tracked file" {
  git_repo "$SANDBOX/repo"
  printf '{}\n' > "$SANDBOX/repo/package.json"
  mkdir -p "$SANDBOX/repo/build/sub" "$SANDBOX/repo/node_modules/pkg" "$SANDBOX/repo/dist"
  printf 'hand-made\n' > "$SANDBOX/repo/build/sub/keep.txt"
  printf 'vendored\n' > "$SANDBOX/repo/node_modules/pkg/index.js"
  : > "$SANDBOX/repo/dist/out.js"
  git -C "$SANDBOX/repo" add -f package.json build/sub/keep.txt node_modules/pkg/index.js
  git -C "$SANDBOX/repo" commit -q -m tracked
  hy hy_regenerable_kind "$SANDBOX/repo/build"
  [ "$status" -eq 1 ] || { echo "tracked build: $output"; false; }
  hy hy_regenerable_kind "$SANDBOX/repo/node_modules"
  [ "$status" -eq 1 ] || { echo "tracked node_modules: $output"; false; }
  # Untracked output beside the same manifest stays regenerable.
  hy hy_regenerable_kind "$SANDBOX/repo/dist"
  [ "$status" -eq 0 ] && [ "$output" = dist ]
}

@test "hy_regenerable_kind fails closed when git cannot list a tree it sits in" {
  mkdir -p "$SANDBOX/orphan/node_modules"
  printf 'gitdir: %s\n' "$SANDBOX/missing-gitdir" > "$SANDBOX/orphan/.git"
  hy hy_regenerable_kind "$SANDBOX/orphan/node_modules"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# hy_last_git_activity
# ---------------------------------------------------------------------------

@test "hy_last_git_activity reads git metadata, not the directory mtime" {
  local gitdir
  git_repo "$SANDBOX/src/alpha"
  git -C "$SANDBOX/src/alpha" worktree add -q -b idle "$SANDBOX/idle"
  gitdir="$(git -C "$SANDBOX/idle" rev-parse --absolute-git-dir)"
  touch -t 202001020304.05 "$gitdir/HEAD" "$gitdir/index" "$gitdir/logs/HEAD" \
    "$(git -C "$SANDBOX/idle" rev-parse --path-format=absolute --git-common-dir)/refs/heads/idle"
  # Fresh directory mtimes must not count as activity.
  touch "$SANDBOX/idle" "$SANDBOX/idle/seed.txt"
  hy hy_last_git_activity "$SANDBOX/idle"
  [ "$status" -eq 0 ]
  [ "$output" = "$(date -j -f '%Y%m%d%H%M.%S' 202001020304.05 +%s 2>/dev/null || date -d '2020-01-02 03:04:05' +%s)" ]

  # The newest of the three wins.
  touch -t 202105060708.09 "$gitdir/index"
  hy hy_last_git_activity "$SANDBOX/idle"
  [ "$output" = "$(date -j -f '%Y%m%d%H%M.%S' 202105060708.09 +%s 2>/dev/null || date -d '2021-05-06 07:08:09' +%s)" ]
}

@test "hy_last_git_activity does not touch the index it measures" {
  local gitdir before
  git_repo "$SANDBOX/src/alpha"
  gitdir="$(git -C "$SANDBOX/src/alpha" rev-parse --absolute-git-dir)"
  touch "$SANDBOX/src/alpha/seed.txt"
  touch -t 202001020304.05 "$gitdir/index"
  before="$(ls -l -T "$gitdir/index" 2>/dev/null || stat -c %y "$gitdir/index")"
  hy hy_last_git_activity "$SANDBOX/src/alpha"
  [ "$status" -eq 0 ]
  [ "$(ls -l -T "$gitdir/index" 2>/dev/null || stat -c %y "$gitdir/index")" = "$before" ]
}

@test "hy_last_git_activity fails closed outside a worktree" {
  mkdir -p "$SANDBOX/plain"
  hy hy_last_git_activity "$SANDBOX/plain"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "hy_last_git_activity counts the branch ref in the common dir" {
  local gitdir common epoch
  git_repo "$SANDBOX/src/alpha"
  git -C "$SANDBOX/src/alpha" config core.logAllRefUpdates false
  git -C "$SANDBOX/src/alpha" worktree add -q -b side "$SANDBOX/side"
  gitdir="$(git -C "$SANDBOX/side" rev-parse --absolute-git-dir)"
  common="$(git -C "$SANDBOX/side" rev-parse --path-format=absolute --git-common-dir)"
  touch -t 202001020304.05 "$gitdir/HEAD" "$gitdir/index"
  rm -f "$gitdir/logs/HEAD"
  # A loose branch ref moved later than the worktree's own files.
  touch -t 202203040506.07 "$common/refs/heads/side"
  epoch="$(date -j -f '%Y%m%d%H%M.%S' 202203040506.07 +%s 2>/dev/null || date -d '2022-03-04 05:06:07' +%s)"
  hy hy_last_git_activity "$SANDBOX/side"
  [ "$status" -eq 0 ]
  [ "$output" = "$epoch" ] || { echo "$output vs $epoch"; false; }

  # A packed branch is measured by packed-refs.
  git -C "$SANDBOX/src/alpha" pack-refs --all
  [ ! -e "$common/refs/heads/side" ]
  touch -t 202304050607.08 "$common/packed-refs"
  epoch="$(date -j -f '%Y%m%d%H%M.%S' 202304050607.08 +%s 2>/dev/null || date -d '2023-04-05 06:07:08' +%s)"
  hy hy_last_git_activity "$SANDBOX/side"
  [ "$output" = "$epoch" ] || { echo "$output vs $epoch"; false; }
}

# ---------------------------------------------------------------------------
# Doctor wiring (T0.3): one row loop over the three lane-owned row libraries.
# ---------------------------------------------------------------------------

# A minimal portable machine home: enough for doctor to reach its host rows.
write_doctor_home() {
  mkdir -p "$SANDBOX/source" "$SANDBOX/projects"
  printf '{"schema_version":2,"harnesses":["claude"]}\n' > "$SANDBOX/source/trellis.config.json"
  cat > "$TRELLIS_HOME/config.json" <<JSON
{"schema_version":1,"source_root":"$SANDBOX/source","release_remote":"$SANDBOX/source","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX/projects"]}}}
JSON
  chmod 600 "$TRELLIS_HOME/config.json"
}

run_doctor_from() {
  local scripts="$1"
  shift
  run /usr/bin/env -u TRELLIS_CONFIG -u DOCKER_HOST HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    bash "$scripts/doctor.sh" "$@"
}

# Every hygiene row library is filled by its lane (worktree-layout: L-A,
# worktree-layout.bats; dep-sharing: L-B, dep-sharing.bats; pi-output-guard:
# L-C, pi-guide-parity.bats), so no stub check remains.

@test "doctor reports every hygiene row with the fix mode it ran under" {
  local copy="$SANDBOX/copy/scripts" lib fn baseline
  write_doctor_home
  mkdir -p "$SANDBOX/copy"
  cp -R "$REPO_ROOT/scripts" "$copy"
  # Stand-in rows: each library reports its own name, argv and status code.
  for lib in worktree-layout:hc_wt_layout_rows:2 dep-sharing:hc_dep_sharing_rows:3 pi-output-guard:hc_pi_guard_rows:1; do
    fn="${lib#*:}"; fn="${fn%%:*}"
    printf '%s() { printf "%s\\t%s %%s %%s %%s\\n" "$1" "$2" "$3"; }\n' \
      "$fn" "${lib##*:}" "$fn" > "$copy/lib/${lib%%:*}.sh"
  done

  run_doctor_from "$REPO_ROOT/scripts"
  baseline="$(printf '%s\n' "$output" | sed -n 's/^✗ \([0-9][0-9]*\) error(s).*/\1/p')"
  [ -n "$baseline" ] || { echo "$output"; false; }

  run_doctor_from "$copy"
  [[ "$output" == *"⚠ hc_wt_layout_rows $HOME $TRELLIS_HOME off"* ]] || { echo "$output"; false; }
  [[ "$output" == *"i hc_dep_sharing_rows $HOME $TRELLIS_HOME off"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✗ hc_pi_guard_rows $HOME $TRELLIS_HOME off"* ]] || { echo "$output"; false; }
  # An error row counts toward doctor's tally and exit class like any host row.
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ $((baseline + 1)) error(s)"* ]] || { echo "$output"; false; }

  run_doctor_from "$copy" --fix --dry-run
  [[ "$output" == *"hc_dep_sharing_rows $HOME $TRELLIS_HOME dry-run"* ]] || { echo "$output"; false; }
  run_doctor_from "$copy" --fix
  [[ "$output" == *"hc_dep_sharing_rows $HOME $TRELLIS_HOME apply"* ]] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# Janitor skeleton (T0.4): new scopes, --dehydrate, the two lane libraries, the
# tool-path file and the per-scope apply opt-out.
# ---------------------------------------------------------------------------

# write_janitor_home [DISK_JANITOR_JSON] — policy, machine home, empty registry.
write_janitor_home() {
  mkdir -p "$SANDBOX/canonical/audits" "$SANDBOX/projects"
  jq -n --argjson dj "${1:-{\}}" \
    '{schema_version: 2, maintainer_name: "T", github_user: "t", harnesses: ["claude"], disk_janitor: $dj}' \
    > "$SANDBOX/canonical/trellis.config.json"
  cat > "$TRELLIS_HOME/config.json" <<JSON
{"schema_version":1,"source_root":"$SANDBOX/canonical","release_remote":"https://example.invalid/t.git","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX/projects"]}}}
JSON
  chmod 600 "$TRELLIS_HOME/config.json"
}

run_janitor_from() {
  local scripts="$1"
  shift
  run env TRELLIS_CONFIG="$SANDBOX/canonical/trellis.config.json" TRELLIS_HOME="$TRELLIS_HOME" \
    DJ_BUILD_ACTIVE_OVERRIDE=0 bash "$scripts/disk-janitor.sh" "$@" </dev/null
}

# Copy the scripts tree and replace both janitor lane libraries with recorders
# that log each call (name, mode, --dehydrate, scopes, PATH) to $CALLS.
recording_janitor() {
  local fn
  CALLS="$SANDBOX/calls"
  : > "$CALLS"
  mkdir -p "$SANDBOX/copy"
  cp -R "$REPO_ROOT/scripts" "$SANDBOX/copy/scripts"
  for fn in dj_dehydrate_scan dj_dehydrate_render dj_dehydrate_apply; do
    printf '%s() { printf "%%s %%s %%s %%s\\n" %s "$MODE" "$DEHYDRATE" "$SCOPES" >> "%s"; }\n' \
      "$fn" "$fn" "$CALLS"
  done > "$SANDBOX/copy/scripts/lib/disk-janitor-dehydrate.sh"
  cat > "$SANDBOX/copy/scripts/lib/disk-janitor-host.sh" <<SH
dj_host_scan() {
  printf 'dj_host_scan PATH=%s\n' "\$PATH" >> "$CALLS"
  plan_row logs report-only log "$SANDBOX/big.log" 7 - recorded
}
dj_host_render() { printf 'dj_host_render rows=%s\n' "\$(awk -F'\t' '\$1=="logs"' "\$PLAN_TMP" | grep -c .)" >> "$CALLS"; }
dj_host_apply() { printf 'dj_host_apply\n' >> "$CALLS"; }
SH
}

@test "janitor accepts the spec 069 scopes and renders the landed lanes" {
  write_janitor_home
  run_janitor_from "$REPO_ROOT/scripts" --report --scopes orphans,logs,tmp,transcripts
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"== Orphaned worktree directories"* ]] || { echo "$output"; false; }
  [[ "$output" == *"== Logs (host-global, report-only) =="* ]] || { echo "$output"; false; }
  [[ "$output" == *"== Tmp scratch (host-global) =="* ]] || { echo "$output"; false; }
  [[ "$output" == *"== Session transcripts"* ]] || { echo "$output"; false; }
  run_janitor_from "$REPO_ROOT/scripts" --dry-run --dehydrate --scopes worktrees,orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"== Orphaned worktree directories"* ]] || { echo "$output"; false; }

  run_janitor_from "$REPO_ROOT/scripts" --report --scopes caches,bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"valid: caches, worktrees, stores, docker, releases, pi, orphans, logs, tmp, transcripts"* ]] || { echo "$output"; false; }
}

@test "janitor calls both lane libraries from its scan, render and apply sites" {
  write_janitor_home
  recording_janitor

  run_janitor_from "$SANDBOX/copy/scripts" --report --dehydrate --scopes worktrees,logs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sed -n 1p "$CALLS")" = "dj_dehydrate_scan report 1 worktrees,logs" ]
  [[ "$(sed -n 2p "$CALLS")" == "dj_host_scan PATH="* ]]
  grep -qx 'dj_dehydrate_render report 1 worktrees,logs' "$CALLS"
  # The host scan's plan row is visible to its renderer.
  grep -qx 'dj_host_render rows=1' "$CALLS"
  ! grep -q '_apply' "$CALLS"

  : > "$CALLS"
  run_janitor_from "$SANDBOX/copy/scripts" --dry-run --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'dj_dehydrate_render dry-run 0 tmp' "$CALLS"
  grep -qx 'dj_host_render rows=1' "$CALLS"
  ! grep -q '_apply' "$CALLS"

  : > "$CALLS"
  run_janitor_from "$SANDBOX/copy/scripts" --apply --yes --scopes tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'dj_dehydrate_apply apply 0 tmp' "$CALLS"
  grep -qx 'dj_host_apply' "$CALLS"
  ! grep -q '_render' "$CALLS"
}

@test "janitor prepends the installer's tool-path entries to PATH" {
  write_janitor_home
  recording_janitor
  mkdir -p "$TRELLIS_HOME/state/disk-janitor" "$SANDBOX/tools-a" "$SANDBOX/tools-b"
  printf '%s\n' "$SANDBOX/tools-a" "relative/bin" "$SANDBOX/x:$SANDBOX/y" "" "$SANDBOX/tools-b" \
    > "$TRELLIS_HOME/state/disk-janitor/tool-path"

  run_janitor_from "$SANDBOX/copy/scripts" --report --scopes logs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "^dj_host_scan PATH=$SANDBOX/tools-a:$SANDBOX/tools-b:" "$CALLS" || { cat "$CALLS"; false; }
  ! grep -q 'relative/bin' "$CALLS"
  ! grep -q "$SANDBOX/x" "$CALLS"

  # No file, no change.
  rm -f "$TRELLIS_HOME/state/disk-janitor/tool-path"
  : > "$CALLS"
  run_janitor_from "$SANDBOX/copy/scripts" --report --scopes logs
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "^dj_host_scan PATH=$PATH\$" "$CALLS" || { cat "$CALLS"; false; }
}

@test "janitor drops apply_disabled_scopes from --apply only" {
  write_janitor_home '{"apply_disabled_scopes":["tmp"]}'
  run_janitor_from "$REPO_ROOT/scripts" --apply --yes --scopes caches,tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"apply disabled for scope tmp by disk_janitor.apply_disabled_scopes"* ]] || { echo "$output"; false; }
  [[ "$output" == *"scopes:        caches"$'\n'* ]] || { echo "$output"; false; }

  run_janitor_from "$REPO_ROOT/scripts" --report --scopes caches,tmp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"scopes:        caches,tmp"* ]] || { echo "$output"; false; }
}
