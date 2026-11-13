#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
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
#     commit). The proof is bound to the exact HEAD commit: one that moves
#     during the detach is proven again, and the branch is deleted only while
#     it still points at the proven commit. The deleted sha is logged so the
#     branch can be recreated.
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
# checkout. After the remove, its local registry row is retired with
# `trellis registry deregister --worktree-root` (1.5.1), which detach leaves. Everything runs in the foreground (spec 074 T49): exit 0 only once
# the directory is gone. The whole removal holds the create hook's per-path
# creation lock, which a create holds through population and its foreground
# sync: a create in progress is waited for, and a create that starts
# meanwhile is refused. A create-time `trellis worktree sync` recorded by an
# older create hook is waited for too. Both waits share one budget from hook
# start, TRELLIS_WORKTREE_SYNC_WAIT_S
# (default 90 s, under Claude's 120 s WorktreeRemove timeout); a pid counts as
# the sync only while its command line still names `worktree sync <path>`.
# Still running at the bound, a failed detach, or a check that fails after
# the detach keeps the worktree and exits 1 with the reason; nothing is left
# to finish in the background.
#
# Dependencies: bash, git, jq, shasum, perl; scripts/lib/hygiene-common.sh and
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
. "$lib_dir/hygiene-common.sh" || exit 1
# shellcheck source=../../scripts/lib/disk-janitor-lib.sh
. "$lib_dir/disk-janitor-lib.sh" || exit 1
for dependency in hy_root local_registry_identity_for_root trellis_home_resolve dj_branch_merged; do
  command -v "$dependency" >/dev/null 2>&1 || { printf 'trellis-worktree-remove: missing helper %s\n' "$dependency" >&2; exit 1; }
done

LOG=""
WT=""
# One budget for every wait (a create in progress, a legacy sync), measured
# from hook start with SECONDS, so the hook stays under Claude's timeout.
WAIT_LIMIT="${TRELLIS_WORKTREE_SYNC_WAIT_S:-90}"

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

# owner_record WT — 0: committed record, 1: genuinely absent, 2: unknown.
owner_record() {
  local identity home ids owner rc=0
  identity="$(local_registry_identity_for_root "$1" 2>/dev/null)" || return 2
  home="$(trellis_home_resolve "" 2>/dev/null)" || return 2
  ids="$(printf '%s\n' "$identity" | jq -er '
    select((.checkout_id | test("^[a-f0-9]{64}$")) and (.worktree_id | test("^[a-f0-9]{64}$")))
    | .checkout_id + "/" + .worktree_id' 2>/dev/null)" || return 2
  owner="$home/state/attachments/$ids.json"
  # Shell -e conflates ENOENT with inaccessible or stale filesystem state.
  perl -e 'use Errno qw(ENOENT); exit 0 if lstat $ARGV[0]; exit($! == ENOENT ? 1 : 2)' "$owner" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 2
  jq -e 'type == "object" and .status == "committed" and (.artifacts | type == "array") and ((.renders // []) | type == "array")' "$owner" >/dev/null 2>&1 || return 2
  printf '%s\n' "$owner"
}

# registry_fleets WT — each fleet whose local registry row names WT's exact
# checkout and worktree identity, one per line; nothing when there is no row
# or the registry cannot be read. Read before the remove: the identity needs
# the worktree.
registry_fleets() {
  local identity home
  identity="$(local_registry_identity_for_root "$1" 2>/dev/null)" || return 0
  home="$(trellis_home_resolve "" 2>/dev/null)" || return 0
  [ -f "$home/registry.json" ] && [ ! -L "$home/registry.json" ] || return 0
  printf '%s\n' "$identity" | jq -r --slurpfile registry "$home/registry.json" '
    .checkout_id as $c | .worktree_id as $w
    | [$registry[0].projects | objects | .[] | objects
       | select((.checkouts | objects | .[$c] | objects | .worktrees | objects | .[$w]) != null)
       | .fleet | strings] | unique | .[]' 2>/dev/null || :
}

# is_owned WT ENTRY OWNED — ENTRY is one of OWNED (newline-separated relative
# paths), or a directory whose every non-directory descendant is. A walk that
# fails, even after printing some paths, proves nothing: not owned.
is_owned() {
  local wt="$1" entry="$2" owned="$3" file walk rc=0
  [ -n "$owned" ] || return 1
  if printf '%s\n' "$owned" | grep -Fxq -- "$entry"; then
    [ -d "$wt/$entry" ] && [ ! -L "$wt/$entry" ] || return 0
  fi
  [ -d "$wt/$entry" ] && [ ! -L "$wt/$entry" ] || return 1
  walk="$(mktemp "${TMPDIR:-/tmp}/trellis-worktree-owned.XXXXXX")" || return 1
  if ! find "$wt/$entry" ! -type d -print0 > "$walk"; then
    rm -f "${walk:?}"
    return 1
  fi
  while IFS= read -r -d '' file; do
    case "${file#"$wt"/}" in
      .claude/.review-done-*|.claude/.reread-state/*|.claude/session-autonomy|.claude/session-surgical|.claude/spec-gate-audit.log|.claude/.fail-counter|.codex/.review-done-*|.codex/.reread-state/*|.pi/.reread-state/*) continue ;;
    esac
    printf '%s\n' "$owned" | grep -Fxq -- "${file#"$wt"/}" || { rc=1; break; }
  done < "$walk"
  rm -f "${walk:?}"
  return "$rc"
}

# blockers WT OWNED — one line per local file `git worktree remove` would
# destroy: tracked changes, untracked files, and ignored entries that are
# neither regenerable nor owned. A git error is itself a blocker.
blockers() {
  local wt="$1" owned="$2" status list entry nested sensitive
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
    if hy_regenerable_kind "$wt/$entry" >/dev/null; then
      # Directory names do not make nested environment files or databases
      # regenerable. Walk without following symlinks and fail closed on error.
      sensitive="$(mktemp "${TMPDIR:-/tmp}/trellis-worktree-sensitive.XXXXXX")" || {
        echo "mktemp failed"
        continue
      }
      if ! find "$wt/$entry" ! -type d \( -name .env -o -name '.env.*' -o -name '*.db' \) -print0 > "$sensitive"; then
        printf 'cannot inspect ignored directory: %s\n' "$entry"
      fi
      while IFS= read -r -d '' nested; do
        nested="${nested#"$wt"/}"
        is_owned "$wt" "$nested" "$owned" && continue
        printf 'ignored, not regenerable: %s\n' "$nested"
      done < "$sensitive"
      rm -f "${sensitive:?}"
      continue
    fi
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

# creation_lock PATH FD — take the create hook's creation lock for PATH (its
# state/create-<git hash-object PATH>.lock) on FD and hold it until exit,
# waiting for a create in progress only within what is left of WAIT_LIMIT.
creation_lock() {
  local path="$1" fd="$2" state key lock remaining=$((WAIT_LIMIT - SECONDS))
  [ "$remaining" -ge 0 ] || remaining=0
  state="$(state_dir)"
  key="$(printf '%s' "$path" | git hash-object --stdin)" || keep "cannot identify its creation lock"
  mkdir -p "$state" && chmod 700 "$state" || keep "cannot create $state"
  lock="$state/create-$key.lock"
  [ ! -L "$lock" ] && { [ ! -e "$lock" ] || [ -f "$lock" ]; } || keep "invalid creation lock $lock"
  (umask 077; : >> "$lock") || keep "cannot create lock $lock"
  eval "exec $fd>>\"\$lock\"" || keep "cannot open lock $lock"
  perl -MFcntl=:flock -e '
    my $deadline = time + $ARGV[0];
    until (flock(STDIN, LOCK_EX | LOCK_NB)) {
      exit 1 if time >= $deadline;
      select(undef, undef, undef, 0.1);
    }' "$remaining" <&"$fd" || keep "a create for this worktree is still in progress after ${WAIT_LIMIT}s"
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

# merge_proven WT BRANCH SHA — 0 only when BRANCH has a merged PR
# (dj_branch_merged) and SHA (the HEAD being proven) is that PR's head commit
# or an ancestor of it, so no commit made after the merge rides along. A
# missing, unauthenticated or failing gh, or a head commit not present
# locally, is not proof.
merge_proven() {
  local wt="$1" branch="$2" sha="$3" oid gh_bin gh_dir
  [ -n "$branch" ] && [ -n "$sha" ] || return 1
  # A missing gh is a labelled degraded check, never a silent pass: the
  # merge stays unproven, so unpushed commits keep the worktree.
  gh_bin="$(resolve_gh)" || {
    say "degraded: PR merge check unavailable (gh not found on PATH or TRELLIS_ATTACH_CALLER_PATH); merge of $branch not proven"
    return 1
  }
  gh_dir="$(dirname "$gh_bin")"
  case ":$PATH:" in
    *":$gh_dir:"*) ;;
    *) PATH="$gh_dir:$PATH" ;;
  esac
  # One gh query answers both halves: its list of merged-PR head commits is
  # empty exactly when dj_branch_merged would find no merged PR (it runs the
  # same `pr list --head BRANCH --state merged`), and a failing gh lists none.
  # dj_branch_merged still runs for its DJ_MERGED_OVERRIDE test seam, which
  # answers without gh.
  if [ -n "${DJ_MERGED_OVERRIDE:-}" ]; then
    dj_branch_merged "$wt" "$branch" || return 1
  fi
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    git -C "$wt" merge-base --is-ancestor "$sha" "$oid" 2>/dev/null && return 0
  done <<EOF
$(cd "$wt" 2>/dev/null && "$gh_bin" pr list --head "$branch" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null)
EOF
  return 1
}

# unpushed WT BRANCH PROVEN SHA — the reason to keep WT when SHA (its HEAD)
# carries commits that are on no remote-tracking ref and no other local branch,
# unless PROVEN (merge_proven for SHA) is 0. Prints nothing when there is no
# such reason.
unpushed() {
  local wt="$1" branch="$2" proven="$3" sha="$4" count
  [ "$proven" -eq 0 ] && return 0
  if [ -n "$branch" ]; then
    count="$(git -C "$wt" rev-list --count "$sha" --not --remotes --exclude="$branch" --branches 2>/dev/null)"
  else
    count="$(git -C "$wt" rev-list --count "$sha" --not --remotes --branches 2>/dev/null)"
  fi
  case "$count" in
    0) ;;
    ''|*[!0-9]*) echo "could not count unpushed commits" ;;
    *) echo "$count commit(s) on ${branch:-detached HEAD} are not on any remote or other branch, and no merged PR covers HEAD" ;;
  esac
}

# finish WT MAIN BRANCH [OWNED] [OWNER|absent] [PROVEN] [PROVEN_SHA] — wait (bounded) for a create-time sync,
# detach when attached, re-check everything (passing the owned list so
# Trellis-owned artifacts do not falsely block removal, while ignored
# non-regenerable files like .env and *.db still block removal), then
# `git worktree remove` and delete a worktree-* branch whose merge is proven.
finish() {
  local main="$2" branch="$3" owned="${4:-}" owner="${5:-}" proven="${6:-}" proven_sha="${7:-}"
  local waited=0 limit="$WAIT_LIMIT"
  local reasons sha now_branch owner_rc fleets fleet
  while sync_running "$WT"; do
    [ "$SECONDS" -lt "$limit" ] || keep "its create-time trellis worktree sync is still running after ${limit}s"
    sleep 1
    waited=$((waited + 1))
  done
  # T49: reuse the owner lookup and merge proof the caller just made, unless a
  # sync ran meanwhile (it can publish the owner record).
  if [ "$waited" -gt 0 ]; then owner=""; proven=""; fi
  if [ "$owner" = absent ]; then
    :
  elif [ -n "$owner" ] || owner="$(owner_record "$WT")"; then
    if [ -z "$owned" ]; then
      owned="$(jq -r '.artifacts[].path, (.renders // [])[].path' "$owner" 2>/dev/null)" || keep "cannot read owner artifacts"
    fi
    trellis detach "$WT" < /dev/null >&2 || keep "trellis detach failed; rerun: trellis detach $WT"
  else
    owner_rc=$?
    [ "$owner_rc" -eq 1 ] || keep "cannot resolve its Trellis owner record"
  fi
  # Detach keeps the registry row; once the directory is gone that row only
  # reports "unavailable: retained local registry row". Find it while the
  # worktree still resolves, and retire it after the remove below.
  fleets="$(registry_fleets "$WT")"
  # The merge proof covers one commit on one branch. A commit or checkout
  # raced in during the detach (or the sync) is proven afresh or keeps WT.
  sha="$(git -C "$WT" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || keep "cannot resolve HEAD after the detach"
  now_branch="$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null)" || now_branch=""
  [ "$now_branch" = "$branch" ] || keep "its branch changed during the detach (${branch:-detached HEAD} -> ${now_branch:-detached HEAD})"
  if [ -z "$proven" ] || [ "$sha" != "$proven_sha" ]; then
    proven=1
    merge_proven "$WT" "$branch" "$sha" && proven=0
  fi
  # Re-check after the detach and immediately before the remove: a raced edit
  # keeps the worktree.
  reasons="$(blockers "$WT" "$owned"; unpushed "$WT" "$branch" "$proven" "$sha")"
  [ -z "$reasons" ] || keep "$(printf '%s\n' "$reasons" | head -n 20)"
  [ "$(git -C "$WT" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" = "$sha" ] || keep "HEAD moved during the final check"
  git -C "$main" worktree remove "$WT" >&2 || keep "git worktree remove refused"
  rm -f "$(state_dir)/$(state_key "$WT").sync.pid"
  # The path is gone, so deregister needs no --force. A failure leaves only
  # the dead row, which doctor reports; the worktree is still removed.
  while IFS= read -r fleet; do
    [ -n "$fleet" ] || continue
    trellis registry deregister --fleet "$fleet" --worktree-root "$WT" < /dev/null >&2 ||
      say "removed $WT; its registry row remains (rerun: trellis registry deregister --fleet $fleet --worktree-root $WT)"
  done <<< "$fleets"
  case "$branch" in
    worktree-*)
      if [ "$proven" -eq 0 ]; then
        # Expected-old-value delete: a branch moved since the proof is kept.
        if git -C "$main" update-ref -d "refs/heads/$branch" "$sha" >&2; then
          say "deleted branch $branch at $sha (recreate: git branch $branch $sha)"
        else
          say "removed $WT; could not delete branch $branch"
        fi
      fi
      ;;
  esac
  say "removed $WT"
}

if [ -n "${TRELLIS_ATTACH_CALLER_PATH:-}" ]; then
  case ":$PATH:" in
    *":$TRELLIS_ATTACH_CALLER_PATH:"*) ;;
    *) PATH="$PATH:$TRELLIS_ATTACH_CALLER_PATH" ;;
  esac
fi

command -v jq >/dev/null 2>&1 || { WT="(unknown)"; keep "jq is not on PATH"; }
WT="$(jq -r '.worktree_path // empty' 2>/dev/null)" || { WT="(unknown)"; keep "hook input is not JSON"; }
[ -n "$WT" ] || { WT="(unknown)"; keep "hook input has no worktree_path"; }
creation_lock "$WT" 8
if [ ! -e "$WT" ] && [ ! -L "$WT" ]; then
  # -e and -L also return false for EACCES and other lookup failures.
  probe_rc=0
  perl -e 'use Errno qw(ENOENT); exit 0 if lstat $ARGV[0]; exit($! == ENOENT ? 1 : 2)' "$WT" || probe_rc=$?
  case "$probe_rc" in
    0) ;; # It appeared between the probes; enter and validate it below.
    1) say "already gone: $WT"; exit 0 ;;
    *) keep "cannot inspect the worktree path" ;;
  esac
fi
raw_wt="$WT"
WT="$(CDPATH='' cd "$WT" 2>/dev/null && pwd -P)" || keep "cannot enter the directory"
# Create keys its lock by the path it printed; cover the physical path too.
[ "$WT" = "$raw_wt" ] || creation_lock "$WT" 7

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

owned=""
owner_state=""
if sync_running "$WT"; then
  # Attach is still writing leaves no record names yet; finish runs the full
  # checks again once the sync has finished.
  reasons="$(git -C "$WT" status --porcelain --untracked-files=all 2>&1 | sed 's/^/uncommitted or untracked: /')"
elif owner="$(owner_record "$WT")"; then
  owner_state="$owner"
  owned="$(jq -r '.artifacts[].path, (.renders // [])[].path' "$owner")" || keep "cannot read owner artifacts"
  reasons="$(blockers "$WT" "$owned")"
else
  owner_rc=$?
  [ "$owner_rc" -eq 1 ] || keep "cannot resolve its Trellis owner record"
  owner_state=absent
  reasons="$(blockers "$WT" "")"
fi
[ -z "$reasons" ] || keep "$(printf '%s\n' "$reasons" | head -n 20)"

head_sha="$(git -C "$WT" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || keep "cannot resolve HEAD"
proven=1
merge_proven "$WT" "$branch" "$head_sha" && proven=0
reasons="$(unpushed "$WT" "$branch" "$proven" "$head_sha")"
[ -z "$reasons" ] || keep "$reasons"

finish "$WT" "$main" "$branch" "$owned" "$owner_state" "$proven" "$head_sha"
