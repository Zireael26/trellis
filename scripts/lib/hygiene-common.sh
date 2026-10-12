#!/usr/bin/env bash
# hygiene-common.sh — the shared worktree-layout and regenerable-content
# predicates for spec 069 (disk and worktree hygiene).
#
# One definition of: the central worktree root, the branch slug, the per-project
# directory, the convention path, the sanctioned-root predicate, the "inside a
# git tree" walk, the regenerable set, and last git activity. `trellis worktree`
# (add, migrate), the Claude Code worktree hooks and the janitor's dehydrate and
# enumeration scopes all call these instead of re-deriving them.
#
# Function-only library: it sets no shell options and sources nothing, so a
# hook can source it without config-load. Every function takes explicit path
# arguments, prints its result on stdout and signals status by return code:
#
#   0  yes / success
#   1  no (predicates only)
#   2  bad argument (relative root, empty branch, not a git worktree)
#   3  conflict (slug collision, ambiguous registry owner)
#   4  unreadable local state (registry is not valid JSON)
#
# Paths are compared in canonical form (`pwd -P` of the longest existing
# ancestor plus the remaining components), so /var and /private/var, or a
# symlinked HOME, agree. Git runs with the hook environment (GIT_DIR and
# friends) removed and GIT_OPTIONAL_LOCKS=0, so a call from inside a git hook
# reads the named path and no call refreshes the index it may be measuring.
#
# bash 3.2 compatible: no [[ ]], no associative arrays, no mapfile.

# The regenerable set (spec 069 D1). dist and build count only beside a JS or
# Python build manifest or lockfile, and target only beside a Cargo or
# Maven/Gradle build file; the rest are regenerable wherever they sit.
_HY_REGENERABLE_ALWAYS='node_modules .venv .next .turbo .mypy_cache .pytest_cache .ruff_cache __pycache__'
_HY_DIST_BUILD_MARKERS='package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lock bun.lockb pyproject.toml setup.py setup.cfg uv.lock poetry.lock'
_HY_TARGET_MARKERS='Cargo.toml Cargo.lock pom.xml build.gradle build.gradle.kts'
# Slugs longer than this many bytes keep a prefix plus a hash of the full name.
_HY_SLUG_MAX_BYTES=96

_hy_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY \
    GIT_OPTIONAL_LOCKS=0 git "$@"
}

# _hy_canon PATH — canonical spelling of an absolute PATH that may not exist:
# the longest existing ancestor through `pwd -P`, then the missing components.
# A `.` or `..` component is refused (2): it could not be resolved lexically
# below a missing ancestor and would let a prefix test be escaped.
_hy_canon() {
  local path="$1" head tail="" real
  case "$path" in /*) ;; *) return 2 ;; esac
  case "$path/" in */./*|*/../*) return 2 ;; esac
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  head="$path"
  while [ ! -d "$head" ]; do
    tail="/${head##*/}$tail"
    head="${head%/*}"
    [ -n "$head" ] || head="/"
  done
  real="$(CDPATH='' cd "$head" 2>/dev/null && pwd -P)" || return 2
  if [ "$real" = "/" ]; then
    printf '%s\n' "${tail:-/}"
  else
    printf '%s%s\n' "$real" "$tail"
  fi
}

_hy_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-64
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-64
  fi
}

_hy_mtime() {
  local value
  value="$(stat -f %m "$1" 2>/dev/null)" || value=""
  case "$value" in ''|*[!0-9]*) value="$(stat -c %Y "$1" 2>/dev/null)" || value="" ;; esac
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

# _hy_common_dir REPO — canonical git common dir of the worktree at REPO.
_hy_common_dir() {
  local common
  common="$(_hy_git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 2
  [ -d "$common" ] || return 2
  (CDPATH='' cd "$common" && pwd -P)
}

# hy_root
#
# The central worktree root (spec 069 A). Precedence: $TRELLIS_WORKTREE_ROOT,
# then `worktrees.root` in the portable policy at $TRELLIS_CONFIG_PATH (exported
# by config-load.sh), then $HOME/projects/worktrees. A leading `~/` expands to
# $HOME. Prints the canonical absolute spelling; the root need not exist.
# Returns 2 when the configured value is not absolute.
hy_root() {
  local root="${TRELLIS_WORKTREE_ROOT:-}"
  if [ -z "$root" ] && [ -n "${TRELLIS_CONFIG_PATH:-}" ] && [ -r "$TRELLIS_CONFIG_PATH" ]; then
    root="$(jq -r '.worktrees.root // empty' "$TRELLIS_CONFIG_PATH" 2>/dev/null)" || root=""
  fi
  [ -n "$root" ] || root="$HOME/projects/worktrees"
  case "$root" in
    \~) root="$HOME" ;;
    \~/*) root="$HOME/${root#\~/}" ;;
  esac
  case "$root" in
    /*) ;;
    *) printf 'hygiene: worktree root must be absolute: %s\n' "$root" >&2; return 2 ;;
  esac
  _hy_canon "$root"
}

# hy_slug BRANCH
# hy_slug --detached SHA
#
# The <branch-slug> path component: BRANCH without refs/heads/, every `/` as
# `-`. Distinct branches can share a slug (a/b and a-b, or Feat and feat on a
# case-insensitive volume); hy_convention_path detects that on disk. A slug
# over 96 bytes keeps its first 80 bytes (cut on a UTF-8 character boundary)
# plus `-` and 12 hex of the full name's sha256, so it never exceeds NAME_MAX.
# A detached HEAD is detached-<first 7 hex of SHA>. Returns 2 for an empty
# slug, `.` or `..`, a leading `-` or `.`, a control character, or a SHA that
# is not at least 7 hex digits.
hy_slug() {
  local branch slug
  if [ "${1:-}" = "--detached" ]; then
    case "${2:-}" in
      ''|*[!0-9a-f]*) return 2 ;;
    esac
    [ "${#2}" -ge 7 ] || return 2
    printf 'detached-%s\n' "$(printf '%s' "$2" | cut -c1-7)"
    return 0
  fi
  branch="${1:-}"
  branch="${branch#refs/heads/}"
  case "$branch" in
    ''|-*|.*|*[[:cntrl:]]*) return 2 ;;
  esac
  slug="$(printf '%s' "$branch" | tr '/' '-')"
  if [ "$(printf '%s' "$slug" | LC_ALL=C wc -c | tr -d ' ')" -gt "$_HY_SLUG_MAX_BYTES" ]; then
    slug="$(printf '%s' "$slug" | LC_ALL=C cut -c1-80 | iconv -f UTF-8 -t UTF-8 -c)-$(_hy_sha256 "$branch" | cut -c1-12)"
  fi
  printf '%s\n' "$slug"
}

# hy_project_dir REPO
#
# <root>/<project-id> when REPO's git common dir belongs to exactly one project
# in the local registry ($TRELLIS_HOME/registry.json, default ~/.trellis), else
# <root>/_unregistered/<basename of the repo's main checkout> (spec 069 §6 Q2).
# REPO may be any worktree of the repository. A missing registry means
# unregistered. Returns 2 when REPO is not a git worktree, 3 when two project
# ids claim the common dir, 4 when the registry is not readable JSON.
hy_project_dir() {
  local repo="${1:-}" root common registry ids count main
  root="$(hy_root)" || return "$?"
  common="$(_hy_common_dir "$repo")" || return 2
  registry="${TRELLIS_HOME:-$HOME/.trellis}/registry.json"
  ids=""
  if [ -e "$registry" ]; then
    ids="$(jq -r --arg common "$common" '
      [.projects[]? | select(any(.checkouts[]?; .git_common_dir == $common)) | .project_id]
      | unique | .[]' "$registry" 2>/dev/null)" || return 4
  fi
  count="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$count" -eq 1 ]; then
    printf '%s/%s\n' "$root" "$ids"
    return 0
  fi
  [ "$count" -eq 0 ] || return 3
  main="$(_hy_git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  [ -n "$main" ] || return 2
  printf '%s/_unregistered/%s\n' "$root" "${main##*/}"
}

# hy_convention_path REPO BRANCH
# hy_convention_path REPO --detached SHA
#
# The one sanctioned location for a new worktree of REPO:
# $(hy_project_dir REPO)/$(hy_slug ...). Always prints the path when it can be
# computed. Returns 0 when the path is free or already holds this repository's
# worktree for the same branch (or the same detached commit); returns 3 when
# anything else occupies it: a worktree on another branch (the a/b versus a-b
# collision), another clone's worktree, or a plain directory or file, and when
# the project directory resolves outside the root (a symlink). Other failures
# propagate from hy_project_dir and hy_slug.
hy_convention_path() {
  local repo="${1:-}" dir slug path top held want_common held_common
  [ "$#" -ge 2 ] || return 2
  shift
  dir="$(hy_project_dir "$repo")" || return "$?"
  slug="$(hy_slug "$@")" || return "$?"
  path="$dir/$slug"
  printf '%s\n' "$path"
  [ -L "$dir" ] && return 3
  [ "$(_hy_canon "$dir")/$slug" = "$path" ] || return 3
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -d "$path" ] && [ ! -L "$path" ] || return 3
  top="$(_hy_git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 3
  [ "$(_hy_canon "$top")" = "$(_hy_canon "$path")" ] || return 3
  want_common="$(_hy_common_dir "$repo")" || return 3
  held_common="$(_hy_common_dir "$path")" || return 3
  [ "$want_common" = "$held_common" ] || return 3
  if [ "$1" = "--detached" ]; then
    _hy_git -C "$path" symbolic-ref -q HEAD >/dev/null 2>&1 && return 3
    held="$(_hy_git -C "$path" rev-parse HEAD 2>/dev/null)" || return 3
    case "$held" in "$2"*) return 0 ;; esac
    return 3
  fi
  held="$(_hy_git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null)" || return 3
  [ "$held" = "${1#refs/heads/}" ] || return 3
}

# hy_is_sanctioned PATH
#
# Return 0 when PATH is a sanctioned worktree location (spec 069 A): strictly
# below the central root (which includes _codex, _pi and _unregistered), or
# the top level of a repository's main checkout. The legacy pi roots
# ~/.pi-worktrees and TRELLIS_HOME/pi-worktrees are drained, not sanctioned
# (owner ruling 2026-10-09: pi moves to <root>/_pi), and neither is a
# directory inside a repository. Return 1 otherwise; 2 when PATH is not
# absolute.
hy_is_sanctioned() {
  local path root top git_dir common
  path="$(_hy_canon "${1:-}")" || return 2
  root="$(hy_root)" || return "$?"
  case "$path" in "$root"/?*) return 0 ;; esac
  [ -d "$path" ] || return 1
  top="$(_hy_git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(_hy_canon "$top")" = "$path" ] || return 1
  git_dir="$(_hy_git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(_hy_common_dir "$path")" || return 1
  [ "$(_hy_canon "$git_dir")" = "$common" ]
}

# hy_inside_git_tree PATH
#
# Return 0 and print the directory when PATH itself or any ancestor holds a
# `.git` entry (a repository or a linked worktree); return 1 when none does.
# PATH need not exist. The walk inspects every ancestor directly instead of
# asking git, so GIT_CEILING_DIRECTORIES, safe.directory and filesystem
# boundaries cannot hide an enclosing tree. Returns 2 when PATH is not absolute.
hy_inside_git_tree() {
  local path
  path="$(_hy_canon "${1:-}")" || return 2
  while :; do
    if [ -e "$path/.git" ]; then
      printf '%s\n' "${path:-/}"
      return 0
    fi
    [ -n "$path" ] && [ "$path" != "/" ] || return 1
    path="${path%/*}"
  done
}

# hy_regenerable_kind DIR
#
# Print DIR's kind (its basename) and return 0 when DIR is a real directory,
# not a symlink, in the regenerable set, and git tracks no file under it:
# node_modules, .venv, .next, .turbo, .mypy_cache, .pytest_cache, .ruff_cache,
# __pycache__ anywhere; dist and build only beside a JS or Python build
# manifest or lockfile; target only beside Cargo.toml, Cargo.lock, pom.xml or
# build.gradle(.kts). Return 1 otherwise, including when DIR sits inside a git
# tree that git cannot list (an orphaned worktree whose gitdir is gone), since
# tracked content can then not be ruled out. Callers deleting on this still
# re-check porcelain cleanliness and open handles just before acting.
hy_regenerable_kind() {
  local dir="${1:-}" name parent markers marker tracked
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  dir="${dir%/}"
  name="${dir##*/}"
  parent="${dir%/*}"
  case "$name" in
    dist|build) markers="$_HY_DIST_BUILD_MARKERS" ;;
    target) markers="$_HY_TARGET_MARKERS" ;;
    *)
      case " $_HY_REGENERABLE_ALWAYS " in
        *" $name "*) markers="" ;;
        *) return 1 ;;
      esac
      ;;
  esac
  if [ -n "$markers" ]; then
    for marker in $markers; do
      [ -f "$parent/$marker" ] && break
      marker=""
    done
    [ -n "$marker" ] || return 1
  fi
  if hy_inside_git_tree "$(_hy_canon "$dir")" >/dev/null 2>&1; then
    _hy_git -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    tracked="$(_hy_git -C "$parent" ls-files -- "$name" 2>/dev/null | head -n 1)"
    [ -z "$tracked" ] || return 1
  fi
  printf '%s\n' "$name"
}

# hy_last_git_activity WORKTREE
#
# Print the epoch of the newest of WORKTREE's own HEAD, index and logs/HEAD
# (the per-worktree git dir) and its checked-out branch's ref in the common dir
# (the loose refs/heads/<branch>, else packed-refs). These move on checkout,
# commit, reset and staging, with or without reflogs, but not when an editor,
# build or `ls` touches the directory. Return 2 with no output when WORKTREE
# is not a git worktree and 1 when none of the files exist, so an idle-time
# check fails closed. Callers that also run `git status` on the tree must set
# GIT_OPTIONAL_LOCKS=0, or status refreshes the index and resets idle.
hy_last_git_activity() {
  local git_dir common ref ref_file file mtime newest=""
  git_dir="$(_hy_git -C "${1:-}" rev-parse --absolute-git-dir 2>/dev/null)" || return 2
  ref_file=""
  if ref="$(_hy_git -C "$1" symbolic-ref -q HEAD 2>/dev/null)" &&
     common="$(_hy_common_dir "$1")"; then
    ref_file="$common/$ref"
    [ -f "$ref_file" ] || ref_file="$common/packed-refs"
  fi
  for file in "$git_dir/HEAD" "$git_dir/index" "$git_dir/logs/HEAD" ${ref_file:+"$ref_file"}; do
    [ -f "$file" ] || continue
    mtime="$(_hy_mtime "$file")" || continue
    if [ -z "$newest" ] || [ "$mtime" -gt "$newest" ]; then newest="$mtime"; fi
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}
