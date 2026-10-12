#!/usr/bin/env bash
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
#   - The same name again returns the worktree already there.
#
# Attach is not inline. The post-checkout dispatcher attaches synchronously,
# and a hook timeout would kill it mid-journal. So the worktree is added with
# --no-checkout and populated with `reset --hard`, which runs no post-checkout
# hook. For a registered project, `trellis worktree sync <path>` then runs
# detached (nohup, stdin /dev/null, no timeout), logging and recording its pid
# under TRELLIS_HOME/state/worktree-hooks/. SessionStart's "attachment
# missing" line covers the window before it finishes.
#
# Because the hook replaces Claude Code's git logic, `.worktreeinclude` is not
# processed and Claude's sweep marker is not written: the WorktreeRemove hook
# and the janitor's cc-* sweep own cleanup.
#
# Dependencies: bash, git, jq; scripts/lib/hygiene-common.sh from the payload
# this file lives in (found through the ~/.claude/hooks symlink).

set -u

die() {
  printf 'trellis-worktree-create: %s\n' "$1" >&2
  exit "${2:-1}"
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
# Claude Code refuses a hook-created directory inside a repository.
if enclosing="$(hy_inside_git_tree "$project_dir")"; then
  die "worktree root is inside the git tree $enclosing"
fi

if [ -e "$path" ] || [ -L "$path" ]; then
  held="$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null)" || held=""
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ "$held" = "$branch" ] && [ "$top" = "$path" ] &&
     [ "$(_hy_common_dir "$path")" = "$(_hy_common_dir "$repo")" ]; then
    printf '%s\n' "$path"
    exit 0
  fi
  die "$path is occupied by something other than this repository's $branch" 3
fi

mkdir -p "$project_dir" || die "cannot create $project_dir"
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$repo" worktree add --no-checkout "$path" "$branch" >&2 || die "git worktree add failed for $path"
else
  # A commit, not a ref: `-b` from origin/HEAD would set main as the upstream.
  base="$(git -C "$repo" rev-parse -q --verify 'refs/remotes/origin/HEAD^{commit}' 2>/dev/null)" ||
    base="$(git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" ||
    die "$repo has no commit to branch from"
  git -C "$repo" worktree add --no-checkout -b "$branch" "$path" "$base" >&2 || die "git worktree add failed for $path"
fi
git -C "$path" reset --hard -q >&2 || die "could not populate $path"

case "$project_dir" in
  "$root/_unregistered/"*) ;;
  *)
    state="${TRELLIS_HOME:-$HOME/.trellis}/state/worktree-hooks"
    key="$(printf '%s' "${path#"$root"/}" | tr '/' '_')"
    mkdir -p "$state" && chmod 700 "$state" || die "cannot create $state"
    log="$state/$key.sync.log"
    printf '%s worktree sync %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" >> "$log"
    if command -v trellis >/dev/null 2>&1; then
      nohup trellis worktree sync "$path" < /dev/null >> "$log" 2>&1 &
      printf '%s\n' "$!" > "$state/$key.sync.pid"
    else
      printf 'trellis is not on PATH; attach it with: trellis worktree sync %s\n' "$path" |
        tee -a "$log" | sed 's/^/trellis-worktree-create: /' >&2
    fi
    ;;
esac

printf '%s\n' "$path"
