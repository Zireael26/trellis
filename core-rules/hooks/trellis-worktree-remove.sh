#!/usr/bin/env bash
# trellis-worktree-remove.sh — WorktreeRemove (Claude Code, user-global).
# Source: Trellis / spec 069 A7
#
# Pairs with trellis-worktree-create.sh. Claude Code runs it when it cleans up
# a worktree that hook created: on exit from a worktree session (after the
# keep/remove prompt, or unprompted when an unnamed session is clean) and when
# a background session is deleted.
#
# Contract (https://code.claude.com/docs/en/hooks#worktreeremove):
#   - stdin is the hook JSON; `worktree_path` is read.
#   - Exit 0 means removed. Exit non-zero with the directory still present
#     means the removal failed and the worktree stays, with no git fallback.
#     The reason goes to stderr (Claude's debug log) and to
#     TRELLIS_HOME/state/worktree-hooks/<key>.remove.log.
#   - Claude Code never deletes a hook-created worktree's branch; this hook
#     does, only for a worktree-* branch whose merge is proven (merge_proven:
#     a merged PR per dj_branch_merged AND HEAD at or behind that PR's head
#     commit). The deleted sha is logged so the branch can be recreated.
#
# The worktree is kept, and the hook exits 1, when any of these hold (the
# spec 069 A3 "clean" test, minus the idle and lsof rules, which cannot hold
# for a session that is exiting the worktree right now):
#   - it is the main checkout, not a git worktree top level, or locked;
#   - `git status` shows a tracked change or an untracked file;
#   - an ignored entry is neither in the regenerable set (hy_regenerable_kind)
#     nor a path the worktree's committed Trellis owner record owns;
#   - HEAD has commits on no remote-tracking ref and no other local branch,
#     and the merge is not proven. gh absent, unauthenticated or failing is
#     an unknown merge state and counts as not proven.
#
# Removal is always `git worktree remove`, never rm and never --force. A
# worktree with a Trellis owner record is detached first (`trellis detach`),
# because a plain remove orphans the record and breaks later attaches for the
# checkout. Detach must not run under a hook timeout, so for an attached
# worktree, or one whose create-time `trellis worktree sync` is still running,
# the checks above run here and the detach, re-check, remove and branch delete
# run detached (nohup, stdin /dev/null) after the sync finishes; the hook then
# exits 0 with the directory still present. The wait is bounded
# (TRELLIS_WORKTREE_SYNC_WAIT_S, default 900 s); a pid counts as the sync only
# while its command line still names `worktree sync <path>`. If that background
# step finds the worktree unsafe, or the sync still running, it keeps it and
# logs why; the janitor's cc-* sweep reports it.
#
# Dependencies: bash, git, jq, shasum; scripts/lib/hygiene-common.sh and
# scripts/lib/disk-janitor-lib.sh from the payload this file lives in.

set -u

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link="$(readlink "$src")"
  case "$link" in
    /*) src="$link" ;;
    *) src="$(dirname "$src")/$link" ;;
  esac
done
lib_dir="$(CDPATH='' cd "$(dirname "$src")/../../scripts/lib" 2>/dev/null && pwd -P)" || {
  printf 'trellis-worktree-remove: cannot find scripts/lib beside %s\n' "$src" >&2
  exit 1
}
# shellcheck source=../../scripts/lib/hygiene-common.sh
. "$lib_dir/hygiene-common.sh"
# shellcheck source=../../scripts/lib/disk-janitor-lib.sh
. "$lib_dir/disk-janitor-lib.sh"

LOG=""
WT=""

say() {
  printf 'trellis-worktree-remove: %s\n' "$1" >&2
  [ -z "$LOG" ] || printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG"
}

keep() {
  say "kept $WT: $1"
  exit 1
}

state_dir() {
  printf '%s/state/worktree-hooks\n' "${TRELLIS_HOME:-$HOME/.trellis}"
}

# state_key WT — WT relative to the worktree root, `/` as `_`; the create hook
# names its sync log and pid file the same way.
state_key() {
  local root
  root="$(hy_root)" || root=""
  printf '%s' "${1#"$root"/}" | tr '/' '_'
}

# owner_record WT — the committed Trellis owner record path for WT, if any.
owner_record() {
  local identity owner
  identity="$(local_registry_identity_for_root "$1" 2>/dev/null)" || return 1
  owner="$(trellis_home_resolve "" 2>/dev/null)/state/attachments/$(printf '%s\n' "$identity" |
    jq -r '.checkout_id + "/" + .worktree_id').json"
  [ -f "$owner" ] && jq -e '.status == "committed"' "$owner" >/dev/null 2>&1 || return 1
  printf '%s\n' "$owner"
}

# is_owned WT ENTRY OWNED — ENTRY is one of OWNED (newline-separated relative
# paths), or a directory whose every non-directory descendant is.
is_owned() {
  local wt="$1" entry="$2" owned="$3" file
  [ -n "$owned" ] || return 1
  printf '%s\n' "$owned" | grep -Fxq -- "$entry" && return 0
  [ -d "$wt/$entry" ] && [ ! -L "$wt/$entry" ] || return 1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '%s\n' "$owned" | grep -Fxq -- "${file#"$wt"/}" || return 1
  done <<EOF
$(find "$wt/$entry" ! -type d)
EOF
}

# blockers WT OWNED — one line per local file `git worktree remove` would
# destroy: tracked changes, untracked files, and ignored entries that are
# neither regenerable nor owned. A git error is itself a blocker.
blockers() {
  local wt="$1" owned="$2" status list entry
  status="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" || {
    echo "git status failed"
    return
  }
  [ -z "$status" ] || printf '%s\n' "$status" | sed 's/^/uncommitted or untracked: /'
  list="$(mktemp "${TMPDIR:-/tmp}/trellis-worktree-remove.XXXXXX")" || {
    echo "mktemp failed"
    return
  }
  if ! git -C "$wt" ls-files -z --others --ignored --exclude-standard --directory --no-empty-directory > "$list" 2>/dev/null; then
    echo "git ls-files failed"
  fi
  while IFS= read -r -d '' entry; do
    entry="${entry%/}"
    hy_regenerable_kind "$wt/$entry" >/dev/null && continue
    is_owned "$wt" "$entry" "$owned" && continue
    printf 'ignored, not regenerable: %s\n' "$entry"
  done < "$list"
  rm -f "$list"
}

# sync_running WT — 0 while the create hook's recorded sync for WT is alive.
# A reused pid whose command line does not name `worktree sync WT` is not it.
sync_running() {
  local pidfile pid
  pidfile="$(state_dir)/$(state_key "$1").sync.pid"
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile")"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *"worktree sync $1"*) return 0 ;;
  esac
  return 1
}

# resolve_gh — resolve the gh binary from PATH or TRELLIS_ATTACH_CALLER_PATH
# (set by the Trellis launcher when stripping PATH to system entries).
resolve_gh() {
  local bin dir old_ifs
  if bin="$(command -v gh 2>/dev/null)" && [ -n "$bin" ]; then
    printf '%s\n' "$bin"
    return 0
  fi
  if [ -n "${TRELLIS_ATTACH_CALLER_PATH:-}" ]; then
    old_ifs="$IFS"
    IFS=':'
    for dir in $TRELLIS_ATTACH_CALLER_PATH; do
      IFS="$old_ifs"
      if [ -n "$dir" ] && [ -x "$dir/gh" ] && [ ! -d "$dir/gh" ]; then
        printf '%s/gh\n' "$dir"
        return 0
      fi
    done
    IFS="$old_ifs"
  fi
  return 1
}

# merge_proven WT BRANCH — 0 only when BRANCH has a merged PR
# (dj_branch_merged) and HEAD is that PR's head commit or an ancestor of it, so
# no commit made after the merge rides along. A missing, unauthenticated or
# failing gh, or a head commit not present locally, is not proof.
merge_proven() {
  local wt="$1" branch="$2" oid gh_bin gh_dir
  [ -n "$branch" ] || return 1
  gh_bin="$(resolve_gh)" || return 1
  gh_dir="$(dirname "$gh_bin")"
  case ":$PATH:" in
    *":$gh_dir:"*) ;;
    *) PATH="$gh_dir:$PATH" ;;
  esac
  dj_branch_merged "$wt" "$branch" || return 1
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    git -C "$wt" merge-base --is-ancestor HEAD "$oid" 2>/dev/null && return 0
  done <<EOF
$(cd "$wt" 2>/dev/null && "$gh_bin" pr list --head "$branch" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null)
EOF
  return 1
}

# unpushed WT BRANCH PROVEN — the reason to keep WT when HEAD carries commits
# that are on no remote-tracking ref and no other local branch, unless PROVEN
# (merge_proven) is 0. Prints nothing when there is no such reason.
unpushed() {
  local wt="$1" branch="$2" proven="$3" count
  [ "$proven" -eq 0 ] && return 0
  if [ -n "$branch" ]; then
    count="$(git -C "$wt" rev-list --count HEAD --not --remotes --exclude="$branch" --branches 2>/dev/null)"
  else
    count="$(git -C "$wt" rev-list --count HEAD --not --remotes --branches 2>/dev/null)"
  fi
  case "$count" in
    0) ;;
    ''|*[!0-9]*) echo "could not count unpushed commits" ;;
    *) echo "$count commit(s) on ${branch:-detached HEAD} are not on any remote or other branch, and no merged PR covers HEAD" ;;
  esac
}

# finish WT MAIN BRANCH [OWNED] — wait (bounded) for a create-time sync,
# detach when attached, re-check everything (passing the owned list so
# Trellis-owned artifacts do not falsely block removal, while ignored
# non-regenerable files like .env and *.db still block removal), then
# `git worktree remove` and delete a worktree-* branch whose merge is proven.
finish() {
  local main="$2" branch="$3" owned="${4:-}"
  local waited=0 limit="${TRELLIS_WORKTREE_SYNC_WAIT_S:-900}"
  local proven=1 reasons sha owner
  while sync_running "$WT"; do
    [ "$waited" -lt "$limit" ] || keep "its create-time trellis worktree sync is still running after ${limit}s"
    sleep 1
    waited=$((waited + 1))
  done
  if [ -z "$owned" ] && owner="$(owner_record "$WT")"; then
    owned="$(jq -r '.artifacts[].path, (.renders // [])[].path' "$owner" 2>/dev/null)" || owned=""
  fi
  if owner_record "$WT" >/dev/null; then
    trellis detach "$WT" < /dev/null >&2 || keep "trellis detach failed; rerun: trellis detach $WT"
  fi
  merge_proven "$WT" "$branch" && proven=0
  reasons="$(blockers "$WT" "$owned"; unpushed "$WT" "$branch" "$proven")"
  [ -z "$reasons" ] || keep "$(printf '%s\n' "$reasons" | head -n 20)"
  sha="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" || sha=""
  git -C "$main" worktree remove "$WT" >&2 || keep "git worktree remove refused"
  rm -f "$(state_dir)/$(state_key "$WT").sync.pid"
  case "$branch" in
    worktree-*)
      if [ "$proven" -eq 0 ] && [ -n "$sha" ]; then
        if git -C "$main" branch -D "$branch" >&2; then
          say "deleted branch $branch at $sha (recreate: git branch $branch $sha)"
        else
          say "removed $WT; could not delete branch $branch"
        fi
      fi
      ;;
  esac
  say "removed $WT"
}

if [ "${1:-}" = --finish ]; then
  # Background step: stderr is already the remove log.
  WT="$2"
  finish "$WT" "$3" "$4" "${5:-}"
  exit 0
fi

if [ -n "${TRELLIS_ATTACH_CALLER_PATH:-}" ]; then
  case ":$PATH:" in
    *":$TRELLIS_ATTACH_CALLER_PATH:"*) ;;
    *) PATH="$PATH:$TRELLIS_ATTACH_CALLER_PATH" ;;
  esac
fi

command -v jq >/dev/null 2>&1 || { WT="(unknown)"; keep "jq is not on PATH"; }
WT="$(jq -r '.worktree_path // empty' 2>/dev/null)" || { WT="(unknown)"; keep "hook input is not JSON"; }
[ -n "$WT" ] || { WT="(unknown)"; keep "hook input has no worktree_path"; }
if [ ! -e "$WT" ] && [ ! -L "$WT" ]; then
  say "already gone: $WT"
  exit 0
fi
WT="$(CDPATH='' cd "$WT" 2>/dev/null && pwd -P)" || keep "cannot enter the directory"

state="$(state_dir)"
mkdir -p "$state" && chmod 700 "$state" && LOG="$state/$(state_key "$WT").remove.log" || LOG=""

top="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" || keep "not a git worktree"
[ "$top" = "$WT" ] || keep "not the top level of a git worktree"
git_dir="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" || keep "cannot resolve its git dir"
git_dir="$(CDPATH='' cd "$git_dir" && pwd -P)"
[ "$git_dir" != "$(_hy_common_dir "$WT")" ] || keep "it is a main checkout"
[ ! -e "$git_dir/locked" ] || keep "it is locked ($(cat "$git_dir/locked"))"
main="$(git -C "$WT" worktree list --porcelain | sed -n '1s/^worktree //p')"
[ -n "$main" ] || keep "cannot find the main checkout"
branch="$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null)" || branch=""

background=false
owned=""
if sync_running "$WT"; then
  # Attach is still writing leaves no record names yet; the ignored-file check
  # runs again in the background step once it has finished.
  background=true
  reasons="$(git -C "$WT" status --porcelain --untracked-files=all 2>&1 | sed 's/^/uncommitted or untracked: /')"
elif owner="$(owner_record "$WT")"; then
  background=true
  owned="$(jq -r '.artifacts[].path, (.renders // [])[].path' "$owner")"
  reasons="$(blockers "$WT" "$owned")"
else
  reasons="$(blockers "$WT" "")"
fi
[ -z "$reasons" ] || keep "$(printf '%s\n' "$reasons" | head -n 20)"

proven=1
merge_proven "$WT" "$branch" && proven=0
reasons="$(unpushed "$WT" "$branch" "$proven")"
[ -z "$reasons" ] || keep "$reasons"

if [ "$background" = true ]; then
  nohup bash "$src" --finish "$WT" "$main" "$branch" "$owned" < /dev/null >> "${LOG:-/dev/null}" 2>&1 &
  say "detach and git worktree remove continue in the background; log: ${LOG:-none}"
  exit 0
fi
finish "$WT" "$main" "$branch" "$owned"
