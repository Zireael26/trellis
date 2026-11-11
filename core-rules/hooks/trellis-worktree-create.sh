#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# trellis-worktree-create.sh — WorktreeCreate (Claude Code, user-global).
# Source: Trellis / spec 069 A7
#
# Replaces Claude Code's default `.claude/worktrees/<name>` checkout for every
# Claude Code worktree (`claude --worktree`, `isolation: "worktree"` subagents,
# background sessions). The worktree lands at <root>/<project>/cc-<name> on
# branch worktree-<name>, where <root>/<project> is hygiene-common.sh's
# hy_project_dir: the registered project id, else _unregistered/<basename>.
#
# Contract (https://code.claude.com/docs/en/hooks#worktreecreate):
#   - stdin is the hook JSON; `name` and `cwd` are read.
#   - stdout is exactly one line, the absolute worktree path; everything else
#     goes to stderr. Any failure exits non-zero, which fails the creation.
#   - An existing worktree-<name> branch is reused. A new one starts at
#     origin/HEAD (Claude Code's default "fresh" base, without its fetch), or
#     HEAD when there is no origin/HEAD. No network.
#   - The same name again returns the populated worktree already there; an
#     interrupted population or empty index against a nonempty HEAD is refused.
#
# The worktree is added with --no-checkout and populated with `reset --hard`,
# which runs no post-checkout hook. For a registered project the path is
# printed only once it is ready (spec 074 T48): `trellis worktree sync <path>`
# runs in the foreground, still holding the creation lock, and returns 0 once
# the attachment is committed and verified and its checks job has started.
# That job's verdict gates the next Stop and push (T14, amended 2026-11-10 by
# the owner), so create no longer waits for it. The same name again re-runs that sync, which reproves an existing
# attachment or repairs a missing one. Any failure, a missing trellis, or a
# still-pending attachment exits non-zero with nothing on stdout and keeps the
# worktree, its branch and the sync log as recovery evidence.
#
# Because the hook replaces Claude Code's git logic, `.worktreeinclude` is not
# processed and Claude's sweep marker is not written: the WorktreeRemove hook
# and the janitor's cc-* sweep own cleanup.
#
# Dependencies: bash, git, jq, perl, trellis (registered projects); scripts/lib/hygiene-common.sh from the payload
# this file lives in (found through the ~/.claude/hooks symlink).

set -u

die() {
  printf 'trellis-worktree-create: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Shell -e conflates absence with EACCES and other lookup errors.
path_is_missing() {
  perl -e 'use Errno qw(ENOENT); exit 1 if lstat $ARGV[0]; exit($! == ENOENT ? 0 : 1)' "$1"
}

worktree_add_failed() {
  # A failed add can still have created a partial worktree. Only remove the
  # marker when the path is conclusively absent.
  if path_is_missing "$path"; then
    rmdir "$populate_marker" 2>/dev/null || printf 'trellis-worktree-create: could not clear marker %s\n' "$populate_marker" >&2
  fi
  die "git worktree add failed for $path"
}

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link="$(readlink "$src")"
  case "$link" in
    /*) src="$link" ;;
    *) src="$(dirname "$src")/$link" ;;
  esac
done
lib_dir="$(CDPATH='' cd "$(dirname "$src")/../../scripts/lib" 2>/dev/null && pwd -P)" ||
  die "cannot find scripts/lib beside $src"
# shellcheck source=../../scripts/lib/hygiene-common.sh
. "$lib_dir/hygiene-common.sh"

command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
input="$(cat)"
name="$(printf '%s' "$input" | jq -r '.name // empty' 2>/dev/null)" || die "hook input is not JSON" 2
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$name" ] || die "hook input has no name" 2
[ -n "$cwd" ] || die "hook input has no cwd" 2
branch="worktree-$name"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "not a valid branch name: $branch" 2

repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git worktree: $cwd" 2
project_dir="$(hy_project_dir "$repo")" || die "cannot resolve the worktree directory for $repo (hy_project_dir exit $?)"
root="$(hy_root)" || die "invalid worktree root"
path="$project_dir/cc-$(hy_slug "$name")"
state="${TRELLIS_HOME:-$HOME/.trellis}/state/worktree-hooks"
key="$(printf '%s' "${path#"$root"/}" | tr '/' '_')"
populate_key="$(printf '%s' "$path" | git hash-object --stdin)" || die "cannot identify $path"
populate_marker="$state/populate-$populate_key"
# Claude Code refuses a hook-created directory inside a repository.
if enclosing="$(hy_inside_git_tree "$project_dir")"; then
  die "worktree root is inside the git tree $enclosing"
fi

# Serialize same-path creates before inspecting or reclaiming a marker. The
# helper locks the inherited fd; the lock survives until this shell and any
# in-flight Git child close it, including if the hook is killed mid-command.
command -v perl >/dev/null 2>&1 || die "perl is not on PATH"
mkdir -p "$state" && chmod 700 "$state" || die "cannot create $state"
creation_lock="$state/create-$populate_key.lock"
[ ! -L "$creation_lock" ] && { [ ! -e "$creation_lock" ] || [ -f "$creation_lock" ]; } || die "invalid creation lock $creation_lock"
(umask 077; : >> "$creation_lock") || die "cannot create lock $creation_lock"
exec 9>>"$creation_lock" || die "cannot open lock $creation_lock"
perl -MFcntl=:flock -e 'flock(STDIN, LOCK_EX | LOCK_NB) or exit 1' <&9 || die "creation already in progress for $path"

if [ -e "$path" ] || [ -L "$path" ]; then
  held="$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null)" || held=""
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ "$held" != "$branch" ] || [ "$top" != "$path" ] ||
     [ "$(_hy_common_dir "$path")" != "$(_hy_common_dir "$repo")" ]; then
    die "$path is occupied by something other than this repository's $branch" 3
  fi
  if [ -e "$populate_marker" ] || [ -L "$populate_marker" ]; then
    die "$path has an interrupted population marker at $populate_marker; inspect and recover it manually"
  fi
  # A killed --no-checkout can leave no index, or an empty index materialized
  # by a later git status. Never reset a reused tree: it may contain user work.
  index_list="$(mktemp "${TMPDIR:-/tmp}/trellis-worktree-index.XXXXXX")" || die "cannot inspect $path"
  git -C "$path" ls-files --stage > "$index_list" || { rm -f "${index_list:?}"; die "cannot inspect $path index"; }
  if [ ! -s "$index_list" ]; then
    git -C "$path" ls-tree -r --name-only HEAD > "$index_list" || { rm -f "${index_list:?}"; die "cannot inspect $path HEAD"; }
    if [ -s "$index_list" ]; then
      rm -f "${index_list:?}"
      die "$path appears unpopulated (empty index); inspect and recover it manually"
    fi
  fi
  rm -f "${index_list:?}"
else
  path_is_missing "$path" || die "cannot inspect the worktree path $path"
  # Only an empty, non-symlink marker for a conclusively absent path is stale.
  if [ -e "$populate_marker" ] || [ -L "$populate_marker" ]; then
    [ -d "$populate_marker" ] && [ ! -L "$populate_marker" ] && rmdir "$populate_marker" ||
      die "cannot clear stale population marker $populate_marker; inspect it before retrying"
  fi
  mkdir -p "$project_dir" || die "cannot create $project_dir"
  branch_exists=false
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    branch_exists=true
  else
    # A commit, not a ref: `-b` from origin/HEAD would set main as the upstream.
    base="$(git -C "$repo" rev-parse -q --verify 'refs/remotes/origin/HEAD^{commit}' 2>/dev/null)" ||
      base="$(git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" ||
      die "$repo has no commit to branch from"
  fi
  # Persist before worktree add: reset may fail after it has written an index.
  mkdir -m 700 "$populate_marker" || die "cannot create population marker $populate_marker; inspect it before retrying"
  if [ "$branch_exists" = true ]; then
    git -C "$repo" worktree add --no-checkout "$path" "$branch" >&2 || worktree_add_failed
  else
    git -C "$repo" worktree add --no-checkout -b "$branch" "$path" "$base" >&2 || worktree_add_failed
  fi
  git -C "$path" reset --hard -q >&2 || die "could not populate $path"
  rmdir "$populate_marker" || die "cannot clear population marker $populate_marker"
fi
case "$project_dir" in
  "$root/_unregistered/"*) ;;
  *)
    log="$state/$key.sync.log"
    printf '%s worktree sync %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" >> "$log"
    command -v trellis >/dev/null 2>&1 || {
      printf 'trellis is not on PATH\n' >> "$log"
      die "trellis is not on PATH, so $path cannot be made ready; install trellis, then retry (log: $log)"
    }
    # Foreground, under the creation lock; its output goes to the log, never
    # to stdout, which carries only the path.
    if trellis worktree sync "$path" < /dev/null >> "$log" 2>&1; then
      :
    else
      rc=$?
      printf 'worktree sync exit %s\n' "$rc" >> "$log"
      die "$path is not ready: trellis worktree sync failed (exit $rc); the worktree is kept, see $log" "$rc"
    fi
    ;;
esac
exec 9>&-

printf '%s\n' "$path"
