#!/usr/bin/env bash
# Shared hermetic fixture for the spec 069 migrate suites
# (worktree-migrate.bats, worktree-migrate-apply.bats). Callers set REPO_ROOT
# and SCRIPT before loading this helper. WT_ROOT is read by the suites and
# $output is set by bats `run`.
# shellcheck disable=SC2034,SC2154

wm_fixture_setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/wt-migrate.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis-home"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export CODEX_HOME="$HOME/.codex"
  unset TRELLIS_WORKTREE_ROOT TRELLIS_CONFIG_PATH TRELLIS_ATTACH_CALLER_PATH DJ_MERGED_OVERRIDE
  WT_ROOT="$HOME/projects/worktrees"
  mkdir -p "$HOME/projects" "$TRELLIS_HOME" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  export TRELLIS_CONFIG="$SANDBOX/trellis.config.json"
  wm_policy '{}'
  # A quiet lsof: header-free records for nothing open. wm_lsof_hold makes
  # a path look open.
  export WM_LSOF_OPEN="$SANDBOX/lsof-open"
  : > "$WM_LSOF_OPEN"
  cat > "$SANDBOX/bin/lsof" <<'SH'
#!/bin/sh
printf 'p1\n'
while IFS= read -r path; do printf 'fcwd\nn%s\n' "$path"; done < "$WM_LSOF_OPEN"
printf 'f0\nn/dev/null\n'
SH
  chmod 755 "$SANDBOX/bin/lsof"
  # gh answers from WM_GH_MERGED: lines `branch<TAB>headRefOid` of merged PRs.
  export WM_GH_MERGED="$SANDBOX/gh-merged"
  : > "$WM_GH_MERGED"
  mkdir -p "$SANDBOX/ghbin"
  cat > "$SANDBOX/ghbin/gh" <<'SH'
#!/bin/sh
head=""
while [ $# -gt 0 ]; do
  case "$1" in --head) head="$2"; shift ;; esac
  shift
done
printf '['
sep=""
while IFS="$(printf '\t')" read -r branch oid; do
  [ "$branch" = "$head" ] || continue
  printf '%s{"number":1,"headRefOid":"%s"}' "$sep" "$oid"
  sep=","
done < "$WM_GH_MERGED"
printf ']\n'
SH
  chmod 755 "$SANDBOX/ghbin/gh"
  # The launcher's control PATH plus the sandbox stubs; gh is reachable only
  # when a test adds ghbin (directly or through TRELLIS_ATTACH_CALLER_PATH).
  # git and jq are linked in by name so their directories (which may also hold
  # the operator's real gh) never join PATH.
  ln -s "$(command -v git)" "$SANDBOX/bin/git"
  ln -s "$(command -v jq)" "$SANDBOX/bin/jq"
  export PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if [ -x /usr/bin/gh ] || [ -x /bin/gh ]; then
    echo "a system gh would break the gh-absent fixtures" >&2
    return 1
  fi
}

wm_fixture_teardown() {
  [ -z "${SANDBOX:-}" ] || { chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"; }
}

# wm_machine_config — TRELLIS_HOME/config.json with the `personal` fleet, which
# `registry deregister` requires.
wm_machine_config() {
  jq -n --arg root "$SANDBOX" \
    '{schema_version: 1, source_root: $root, release_remote: $root,
      active_cli_release: "0.0.0", default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$root]}}}' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

wm_policy() {
  printf '%s\n' "$1" > "$TRELLIS_CONFIG"
}

wm_with_gh() {
  PATH="$SANDBOX/ghbin:$PATH"
}

# wm_repo DIR [ORIGIN] — a main checkout with one commit on main. With ORIGIN,
# a bare repository at that path is created and pushed to as origin.
wm_repo() {
  local dir="$1" origin="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
  printf 'seed\n' > "$dir/seed.txt"
  printf 'node_modules/\n.venv/\n.env*\n*.db\n*.sqlite\ndist/\n' > "$dir/.gitignore"
  git -C "$dir" add seed.txt .gitignore
  git -C "$dir" commit -q -m init
  if [ -n "$origin" ]; then
    mkdir -p "$origin"
    git init -q --bare -b main "$origin"
    git -C "$dir" remote add origin "$origin"
    git -C "$dir" push -q origin main
  fi
}

wm_register() {
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_register_worktree "$2" personal "$3" "$4" 1.2.3 "[\"claude\"]" ""
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$2" "$1" >/dev/null
}

# wm_wt REPO BRANCH PATH — a linked worktree on a new BRANCH from main.
wm_wt() {
  mkdir -p "$(dirname "$3")"
  git -C "$1" worktree add -q -b "$2" "$3" main
}

# Hash files or stdin without relying on Perl's shasum being on the control PATH.
wm_fixture_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    sha256sum "$@"
  fi
}

# wm_owner PATH RELEASE [ARTIFACTS-JSON] — a minimal attachment owner record
# naming PATH.
wm_owner() {
  local dir="$TRELLIS_HOME/state/attachments/fixture-checkout"
  mkdir -p "$dir"
  jq -n --arg root "$1" --arg release "$2" --argjson artifacts "${3:-[]}" \
    '{worktree_root:$root, release:$release, status:"committed", artifacts:$artifacts}' \
    > "$dir/$(printf '%s' "$1" | wm_fixture_sha256 - | cut -c1-16).json"
}

# wm_age PATH DAYS — make a worktree's git activity DAYS old.
wm_age() {
  local git_dir stamp f ref common ref_file
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)"
  stamp="$(perl -e 'my @t = localtime(time - $ARGV[0] * 86400); printf "%04d%02d%02d%02d%02d", $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1]' "$2")"
  for f in HEAD index logs/HEAD; do
    [ ! -e "$git_dir/$f" ] || touch -t "$stamp" "$git_dir/$f"
  done
  # hy_last_git_activity also reads the checked-out branch's ref in the
  # common dir: backdate it (or its packed-refs fallback) the same way.
  ref="$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null)" || ref=""
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || common=""
  case "$common" in /*) ;; *) common="$1/$common" ;; esac
  if [ -n "$ref" ] && [ -n "$common" ]; then
    ref_file="$common/$ref"
    [ -f "$ref_file" ] || ref_file="$common/packed-refs"
    [ ! -e "$ref_file" ] || touch -t "$stamp" "$ref_file"
  fi
}

wm_lsof_hold() {
  printf '%s\n' "$1" >> "$WM_LSOF_OPEN"
}

wm_merged() {
  printf '%s\t%s\n' "$1" "$2" >> "$WM_GH_MERGED"
}

migrate() {
  run bash "$SCRIPT" migrate "$@"
}

# rows — the JSON rows in $output (skipping any non-JSON line).
rows() {
  printf '%s\n' "$output" | grep '^{'
}

row() {
  rows | jq -c --arg p "$1" 'select(.path == $p)' | grep . || { echo "no row for $1" >&2; echo "$output" >&2; return 1; }
}

# alpha: registered, origin at a bare repo owned by "Zireael26".
alpha() {
  wm_repo "$HOME/projects/alpha" "$SANDBOX/remotes/Zireael26/alpha.git"
  wm_register "$HOME/projects/alpha" alpha
}

# journal — the newest apply journal (not a revert journal).
journal() {
  local candidate latest=""
  for candidate in "$TRELLIS_HOME"/state/worktree-migrate/*.jsonl; do
    [ -f "$candidate" ] || continue
    case "${candidate##*/}" in *revert*) continue ;; esac
    latest="$candidate"
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

# git_fail_move PATH — a git shim that fails `worktree move` of PATH only;
# git_restore puts the real git back.
git_fail_move() {
  local real
  real="$(readlink "$SANDBOX/bin/git")"
  GIT_REAL="$real"
  rm -f "$SANDBOX/bin/git"
  cat > "$SANDBOX/bin/git" <<SH
#!/bin/sh
case " \$* " in *" worktree move $1 "*) echo "injected move failure" >&2; exit 1 ;; esac
exec "$real" "\$@"
SH
  chmod 755 "$SANDBOX/bin/git"
}

git_restore() {
  rm -f "$SANDBOX/bin/git"
  ln -s "$GIT_REAL" "$SANDBOX/bin/git"
}

# merged_wt NAME — a clean worktree whose branch is pushed, merged and idle.
merged_wt() {
  local wt="$HOME/projects/alpha-wt/$1"
  wm_wt "$HOME/projects/alpha" "$1" "$wt"
  git -C "$wt" commit -q --allow-empty -m "work $1"
  git -C "$wt" push -q -u origin "$1"
  wm_merged "$1" "$(git -C "$wt" rev-parse HEAD)"
  wm_age "$wt" 2
}
