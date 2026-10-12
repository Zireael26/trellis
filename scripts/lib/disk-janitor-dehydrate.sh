#!/usr/bin/env bash
# disk-janitor-dehydrate.sh — the janitor's worktree-side spec 069 scopes:
# D1 dehydrate (`--dehydrate`), D5 `orphans`, A11 enumeration of every repo
# under the sanctioned roots and worktrees.known_parents, the A7 `cc-*` sweep
# and the A8 `_codex` report. Owned by lane L-DW.
#
# The janitor lane-library contract, shared with disk-janitor-host.sh.
# scripts/disk-janitor.sh sources both libraries after disk-janitor-lib.sh and
# hygiene-common.sh, and calls, in every run:
#
#   <lib>_scan    once, after the registry fleet loop and the pi scan. Appends
#                 plan rows with `plan_row SCOPE VERDICT KIND PATH BYTES REPO
#                 DETAIL [identity...]` (column 1 is the scope name). Reads
#                 nothing from stdout; print diagnostics to stderr.
#   <lib>_render  in --report (twice: console, then the audit file) and in
#                 --dry-run, after the pi section. Prints its sections from
#                 PLAN_TMP to stdout. Must be read-only.
#   <lib>_apply   in --apply, after the Docker section. Deletes only rows its
#                 own scan planned, re-validating each just before acting, and
#                 asks `confirm_category LABEL` first.
#
# Each function checks `scope_enabled NAME` for the scopes it owns, so a call
# with none of them selected does nothing. In scope: MODE (report|dry-run|
# apply), SCOPES, DEHYDRATE (1 under --dehydrate), SAFE_ONLY, ASSUME_YES,
# PLAN_TMP, TARGETS_TMP (the registry targets), LSOF_SNAPSHOT_TMP (captured
# when worktrees, pi, orphans, logs or tmp is selected; read it through
# dj_worktree_in_use), TRELLIS_HOME, CFG with cfg_num and cfg_bool, and
# EXIT_STATUS (set it to 1 on a failure; never exit). The caller runs under
# `set -euo pipefail`. Scopes listed in disk_janitor.apply_disabled_scopes are
# already removed from SCOPES under --apply.
#
# Plan rows this library writes, besides the `worktrees` rows scan_worktrees
# writes through dj_dehydrate_plan_tree:
#
#   dehydrate  VERDICT KIND PATH BYTES TREE REASON [identity]
#              VERDICT delete|hold|keep (see dj_dehydrate_classify). The
#              identity columns are the registry row of TREE, or empty fields
#              with only GIT_COMMON_DIR set for an unregistered tree.

# Lockfiles that make a regenerable directory reproducible. A tree is
# dehydrated only when it tracks at least one of them (D1).
_DW_LOCKFILES='pnpm-lock.yaml package-lock.json npm-shrinkwrap.json yarn.lock bun.lock bun.lockb uv.lock poetry.lock Pipfile.lock pdm.lock Cargo.lock go.sum Gemfile.lock composer.lock'

# _dw_has_control PATH — 0 when PATH holds a control character. Plan rows are
# tab-separated lines read back by awk and `read`, so such a name could shift
# a field (a path into the bytes column, then into shell arithmetic) or forge a
# whole row; it is refused, never planned.
_dw_has_control() {
  case "$1" in
    *[[:cntrl:]]*) return 0 ;;
  esac
  return 1
}

# _dw_is_count VALUE — 0 when VALUE is a plain non-negative decimal integer, the
# only shape allowed into $(( )).
_dw_is_count() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# _dw_under_root PATH ROOT — 0 when PATH equals ROOT or lies strictly below it.
# Pure fixed-string prefix comparison (no glob): glob characters in either side
# are literal. An empty ROOT never matches.
_dw_under_root() {
  local path="$1" root="$2" path_slash prefix
  [ -n "$root" ] || return 1
  [ "$path" = "$root" ] && return 0
  path_slash="$path/"
  prefix="$root/"
  [ "${path_slash#"$prefix"}" != "$path_slash" ]
}

# _dw_regenerable_kind DIR — hy_regenerable_kind (spec 069 D1): L-0 already
# restricts `target` to Cargo/Maven/Gradle markers and `dist`/`build` to JS or
# Python markers. Tracked content is ruled out separately, by the caller's
# git ls-files check.
_dw_regenerable_kind() {
  hy_regenerable_kind "$1"
}

# _dw_has_nested_git DIR — 0 when DIR holds a `.git` file or directory at any
# depth (a nested repository or a linked worktree inside a regenerable
# candidate), 1 when a complete scan finds none, 2 when the scan could not
# complete (find error, unreadable content, or the 10 s timeout for very deep
# trees). Links are never followed. Callers must treat 2 like 0 (hold/REFUSED):
# an incomplete scan is never read as "no nested git". Mirrors dj_cache_entry_owned_by_worktree
# (disk-janitor-lib.sh): a candidate git does not own is never deleted.
_dw_has_nested_git() {
  local dir="$1" hit err rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/dw-nested-git.XXXXXX")" || return 2
  hit="$(perl -e 'alarm shift; exec @ARGV' 10 find -P "$dir" -mindepth 1 -name .git -print -quit 2>"$err")" || rc=$?
  if [ -n "$hit" ]; then
    rm -f "$err"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$err"
    return 2
  fi
  if [ -s "$err" ]; then
    rm -f "$err"
    return 2
  fi
  rm -f "$err"
  return 1
}

# _dw_ignored_entry TREE REL
#
# Classify one ignored path REL (as `git status --ignored` names it, without a
# trailing slash) of the worktree TREE. Walks REL from the top and prints
# `<kind>\t<prefix>` for the first prefix that is regenerable
# (_dw_regenerable_kind: a real directory) and holds no tracked path, or
# `link:<name>\t<prefix>` for a symlink whose name is always regenerable: the
# link is unlinked, never followed. Anything else prints `keep\t<rel>`: an
# ignored path outside the regenerable set blocks only itself. Returns 1 when
# git cannot answer the tracked-path question.
_dw_ignored_entry() {
  local tree="$1" rel="$2" rest="$2" prefix="" part kind tracked
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    prefix="${prefix:+$prefix/}$part"
    if [ -L "$tree/$prefix" ]; then
      # Git lists nothing below a symlink, so this is the entry itself.
      case " $_HY_REGENERABLE_ALWAYS " in
        *" $part "*) kind="link:$part" ;;
        *) break ;;
      esac
    else
      kind="$(_dw_regenerable_kind "$tree/$prefix")" || continue
    fi
    tracked="$(_hy_git -C "$tree" --literal-pathspecs ls-files -- "$prefix" 2>/dev/null)" || return 1
    if [ -z "$tracked" ]; then
      printf '%s\t%s\n' "$kind" "$prefix"
      return 0
    fi
    case "$kind" in link:*) break ;; esac
  done
  printf 'keep\t%s\n' "$rel"
}

# _dw_tracks_lockfile TREE — 0 when TREE tracks a lockfile at any depth,
# 1 when it tracks none, 2 when git fails.
_dw_tracks_lockfile() {
  local tree="$1" name out
  local -a specs=()
  for name in $_DW_LOCKFILES; do
    specs+=(":(glob)**/$name")
  done
  out="$(_hy_git -C "$tree" ls-files -- "${specs[@]}" 2>/dev/null)" || return 2
  [ -n "$out" ]
}

# dj_dehydrate_classify TREE IDLE_DAYS NOW LSOF_SNAPSHOT
#
# Split the ignored content of the worktree TREE (an absolute canonical path)
# into the regenerable set and everything else (spec 069 D1). Prints one TSV
# row per path, `<verdict>\t<kind>\t<abs_path>\t<reason>`:
#
#   delete  a regenerable directory, or a symlink with a regenerable name, that
#           may go now: the tree has no tracked or untracked change, no live
#           handle in LSOF_SNAPSHOT (dj_worktree_in_use), more than IDLE_DAYS
#           of git idle time (hy_last_git_activity, never directory mtime) and
#           a tracked lockfile;
#   hold    the same path, kept because the tree fails one of those gates; the
#           reason names the first gate that failed;
#   keep    an ignored path outside the regenerable set, which blocks only
#           itself.
#
# A tree git cannot read prints a single `hold\ttree\tTREE\tgit error` row and
# nothing is planned in it: a git failure is never read as a clean tree. An
# ignored path with a control character in its name holds the tree the same
# way. A TREE whose own path holds one is refused (return 2, no output). Git
# runs with GIT_OPTIONAL_LOCKS=0 (_hy_git), so the status call cannot refresh
# the index and reset the idle clock it is about to read.
dj_dehydrate_classify() {
  local tree="$1" idle_days="$2" now="$3" snapshot="$4"
  local status_file entry rel row kind rows="" reason="" in_use activity rc
  local verdict tab nl
  tab="$(printf '\t')"
  nl="$(printf '\nx')"; nl="${nl%x}"

  ! _dw_has_control "$tree" || return 2
  if ! _hy_git -C "$tree" rev-parse --absolute-git-dir >/dev/null 2>&1; then
    printf 'hold\ttree\t%s\tgit error\n' "$tree"
    return 0
  fi
  status_file="$(mktemp "${TMPDIR:-/tmp}/dj-dehydrate.XXXXXX")" || return 1
  # --ignored=matching names each path an ignore rule matched (a matched
  # directory once, with a slash); traditional mode would collapse an untracked
  # directory holding only ignored content (`pkg/` for pkg/mod/__pycache__)
  # into one opaque entry.
  if ! _hy_git -C "$tree" status --porcelain -z --ignored=matching \
      --untracked-files=normal >"$status_file" 2>/dev/null; then
    rm -f "$status_file"
    printf 'hold\ttree\t%s\tgit error\n' "$tree"
    return 0
  fi
  while IFS= read -r -d '' entry; do
    case "$entry" in
      '!! '*) ;;
      *) reason="tracked or untracked changes"; continue ;;
    esac
    rel="${entry#!! }"
    rel="${rel%/}"
    if _dw_has_control "$rel"; then
      rm -f "$status_file"
      printf 'hold\ttree\t%s\tcontrol character in an ignored path name\n' "$tree"
      return 0
    fi
    if ! row="$(_dw_ignored_entry "$tree" "$rel")"; then
      rm -f "$status_file"
      printf 'hold\ttree\t%s\tgit error\n' "$tree"
      return 0
    fi
    rows="$rows$row$nl"
  done <"$status_file"
  rm -f "$status_file"
  [ -n "$rows" ] || return 0

  if [ -z "$reason" ] && in_use="$(dj_worktree_in_use "$tree" "$snapshot")"; then
    case "$in_use" in
      live*) reason="in use" ;;
      *) reason="liveness unknown" ;;
    esac
  fi
  if [ -z "$reason" ]; then
    if ! activity="$(hy_last_git_activity "$tree")"; then
      reason="git activity unknown"
    elif ! dj_cache_is_stale "$activity" "$idle_days" "$now"; then
      reason="recent git activity (idle <= ${idle_days}d)"
    fi
  fi
  if [ -z "$reason" ]; then
    if _dw_tracks_lockfile "$tree"; then rc=0; else rc=$?; fi
    case "$rc" in
      0) ;;
      1) reason="no tracked lockfile" ;;
      *) reason="git error" ;;
    esac
  fi

  # Several ignored entries can resolve to one regenerable prefix: a .venv
  # ignored by its own inner .gitignore lists each child.
  rows="$(printf '%s' "$rows" | awk '!seen[$0]++')"
  while IFS="$tab" read -r kind rel; do
    [ -n "$rel" ] || continue
    if [ "$kind" = keep ]; then
      printf 'keep\tignored\t%s/%s\tnot in the regenerable set\n' "$tree" "$rel"
      continue
    fi
    case "$kind" in
      link:*) ;;
      *)
        if _dw_has_nested_git "$tree/$rel"; then rc=0; else rc=$?; fi
        case "$rc" in
          0)
            printf 'hold\t%s\t%s/%s\tcontains a nested git repository or linked worktree\n' "$kind" "$tree" "$rel"
            continue
            ;;
          2)
            printf 'hold\t%s\t%s/%s\tcould not scan for nested git repositories\n' "$kind" "$tree" "$rel"
            continue
            ;;
        esac
        ;;
    esac
    verdict=delete
    [ -z "$reason" ] || verdict=hold
    printf '%s\t%s\t%s/%s\t%s\n' "$verdict" "$kind" "$tree" "$rel" \
      "${reason:-idle, clean, lockfile tracked}"
  done <<EOF
$rows
EOF
}

# dj_dehydrate_classify_orphan DIR IDLE_DAYS NOW LSOF_SNAPSHOT
#
# The D1 split for a D5 orphan: DIR's `.git` file names a gitdir that is gone,
# so git cannot run there and nothing in DIR can be proved tracked or
# untracked. The rules tighten instead of loosening. Same row format as
# dj_dehydrate_classify, and:
#
#   - only always-regenerable names (node_modules, .venv, the caches) are
#     candidates; dist, build and target never are;
#   - a candidate must be ignored by DIR's own .gitignore files (git
#     check-ignore against an empty scratch repository, global excludes off);
#     one that is not is kept;
#   - idle time is the newest mtime of DIR and DIR/.git, the only activity
#     record an orphan has left, and must exceed IDLE_DAYS;
#   - a lockfile must sit at DIR's top level; no live handle may be open.
#
# DIR that is no longer an orphan, or any candidate name with a control
# character, holds the whole directory. A DIR path with one returns 2.
dj_dehydrate_classify_orphan() {
  local dir="$1" idle_days="$2" now="$3" snapshot="$4"
  local reason="" in_use newest mtime name scratch found rel rc nrc rows="" verdict
  local -a names=()
  ! _dw_has_control "$dir" || return 2
  if ! _dw_orphan_gitdir "$dir" >/dev/null; then
    printf 'hold\ttree\t%s\tno longer an orphan\n' "$dir"
    return 0
  fi
  for name in $_HY_REGENERABLE_ALWAYS; do
    names+=(-o -name "$name")
  done
  while IFS= read -r -d '' found; do
    if _dw_has_control "$found"; then
      printf 'hold\ttree\t%s\tcontrol character in a path name\n' "$dir"
      return 0
    fi
    [ -d "$found" ] && [ ! -L "$found" ] || continue
    rows="$rows${found#"$dir"/}
"
  done < <(find -P "$dir" -mindepth 1 \( -name .git -prune \) -o -type d \
    \( "${names[@]:1}" \) -print0 -prune 2>/dev/null || :)
  [ -n "$rows" ] || return 0

  if in_use="$(dj_worktree_in_use "$dir" "$snapshot")"; then
    case "$in_use" in
      live*) reason="in use" ;;
      *) reason="liveness unknown" ;;
    esac
  fi
  if [ -z "$reason" ]; then
    newest="$(dj_mtime "$dir")"
    mtime="$(dj_mtime "$dir/.git")"
    [ "$mtime" -le "$newest" ] || newest="$mtime"
    dj_cache_is_stale "$newest" "$idle_days" "$now" ||
      reason="recent activity (directory mtime, idle <= ${idle_days}d)"
  fi
  if [ -z "$reason" ]; then
    if dj_pi_entry_fresh "$dir" "$idle_days"; then rc=0; else rc=$?; fi
    case "$rc" in
      0) reason="recent activity (content mtime, idle <= ${idle_days}d)" ;;
      2) reason="activity unknown (unreadable content)" ;;
    esac
  fi
  if [ -z "$reason" ]; then
    reason="no lockfile"
    for name in $_DW_LOCKFILES; do
      if [ -f "$dir/$name" ]; then reason=""; break; fi
    done
  fi

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/dj-orphan.XXXXXX")" || return 1
  if ! _hy_git init -q "$scratch" >/dev/null 2>&1; then
    rm -rf "$scratch"
    printf 'hold\ttree\t%s\tgit error\n' "$dir"
    return 0
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if _hy_git --git-dir="$scratch/.git" --work-tree="$dir" -c core.excludesFile=/dev/null \
        check-ignore --no-index -q -- "$rel" >/dev/null 2>&1; then rc=0; else rc=$?; fi
    case "$rc" in
      0)
        if _dw_has_nested_git "$dir/$rel"; then nrc=0; else nrc=$?; fi
        case "$nrc" in
          0)
            printf 'hold\t%s\t%s/%s\tcontains a nested git repository or linked worktree\n' "${rel##*/}" "$dir" "$rel"
            ;;
          2)
            printf 'hold\t%s\t%s/%s\tcould not scan for nested git repositories\n' "${rel##*/}" "$dir" "$rel"
            ;;
          *)
            verdict=delete
            [ -z "$reason" ] || verdict=hold
            printf '%s\t%s\t%s/%s\t%s\n' "$verdict" "${rel##*/}" "$dir" "$rel" \
              "${reason:-orphan idle, ignored by its own .gitignore, lockfile present}"
            ;;
        esac
        ;;
      1) printf 'keep\tignored\t%s/%s\tnot ignored by the orphan'"'"'s own .gitignore\n' "$dir" "$rel" ;;
      *)
        rm -rf "$scratch"
        printf 'hold\ttree\t%s\tgit error\n' "$dir"
        return 0
        ;;
    esac
  done <<EOF
$rows
EOF
  rm -rf "$scratch"
}

# _dw_classify_for TREE IDLE_DAYS NOW SNAPSHOT FLEET GIT_COMMON_DIR — the
# orphan rules when the plan carries neither a registry row nor a common dir,
# the git-backed rules otherwise.
_dw_classify_for() {
  if [ -z "$5" ] && [ -z "$6" ]; then
    dj_dehydrate_classify_orphan "$1" "$2" "$3" "$4"
  else
    dj_dehydrate_classify "$1" "$2" "$3" "$4"
  fi
}

# dj_dehydrate_idle_days — disk_janitor.dehydrate_idle_days (default 7).
dj_dehydrate_idle_days() {
  cfg_num '.disk_janitor.dehydrate_idle_days' 7
}

# dj_dehydrate_plan_tree TREE [FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID
#   GIT_COMMON_DIR OWNER_ROOT]
#
# Classify TREE and append one `dehydrate` plan row per path, with TREE in the
# repo column and the identity (empty fields but GIT_COMMON_DIR for an
# unregistered tree, all empty for an orphan) in the trailing columns, so apply
# can re-validate the exact owner. Prints the tree summary
# `<planned paths>\t<planned bytes>\t<hold reason>`. A TREE whose path holds a
# control character gets no rows at all: its path cannot be written safely.
dj_dehydrate_plan_tree() {
  local tree="$1" rows verdict kind path reason bytes count=0 total=0 held=""
  shift
  if _dw_has_control "$tree"; then
    printf '0\t0\tcontrol character in the worktree path\n'
    return 0
  fi
  rows="$(_dw_classify_for "$tree" "$(dj_dehydrate_idle_days)" "$NOW_EPOCH" \
    "$LSOF_SNAPSHOT_TMP" "${1:-}" "${5:-}")" || return 1
  while IFS="$(printf '\t')" read -r verdict kind path reason; do
    [ -n "$path" ] || continue
    case "$kind" in
      tree|link:*) bytes=0 ;;
      *) bytes="$(dj_dir_bytes "$path")" ;;
    esac
    _dw_is_count "$bytes" || bytes=0
    plan_row dehydrate "$verdict" "$kind" "$path" "$bytes" "$tree" "$reason" "$@"
    case "$verdict" in
      delete) count=$((count + 1)); total=$((total + bytes)) ;;
      hold) held="$reason" ;;
    esac
  done <<EOF
$rows
EOF
  printf '%s\t%s\t%s\n' "$count" "$total" "$held"
}

# _dw_discovery_roots — the A11 roots, one per line: the central worktree root
# (hy_root, which holds _codex and _unregistered) and every
# worktrees.known_parents entry, `~` expanded. The pi worktree roots are left to
# the pi scope (A9).
_dw_discovery_roots() {
  local parent
  hy_root || :
  jq -r '.worktrees.known_parents[]? // empty' "$CFG" 2>/dev/null |
    while IFS= read -r parent; do
      case "$parent" in
        \~) parent="$HOME" ;;
        \~/*) parent="$HOME/${parent#\~/}" ;;
      esac
      case "$parent" in /*) printf '%s\n' "$parent" ;; esac
    done
}

# _dw_seed_dirs — every directory holding a `.git` entry within four levels of
# a discovery root (`<root>/_unregistered/<repo>/<slug>` and Codex's
# `<date>/task-<n>/<repo>` are the deepest layouts), plus every registry target
# root. Dependency and build trees are not descended into, links are never
# followed, and a name with a control character is skipped.
_dw_seed_dirs() {
  local root entry
  _dw_discovery_roots | while IFS= read -r root; do
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    find -P "$root" -mindepth 1 -maxdepth 4 \
      \( -name node_modules -o -name .venv -o -name .next -o -name target \) -prune \
      -o -name .git -print -prune 2>/dev/null || :
  done | while IFS= read -r entry; do
    _dw_has_control "$entry" || printf '%s\n' "${entry%/.git}"
  done
  awk -F'\t' 'NF==6 {print $5}' "$TARGETS_TMP" 2>/dev/null | while IFS= read -r entry; do
    _dw_has_control "$entry" || printf '%s\n' "$entry"
  done
}

# _dw_orphan_gitdir DIR — print the gitdir DIR's `.git` file names and return 0
# when that gitdir is gone (a D5 orphan); return 1 otherwise.
_dw_orphan_gitdir() {
  local dir="$1" line gitdir
  [ -f "$dir/.git" ] && [ ! -L "$dir/.git" ] || return 1
  IFS= read -r line <"$dir/.git" || return 1
  case "$line" in "gitdir: "*) gitdir="${line#gitdir: }" ;; *) return 1 ;; esac
  gitdir="${gitdir%$'\r'}"
  case "$gitdir" in /*) ;; *) gitdir="$dir/$gitdir" ;; esac
  [ ! -e "$gitdir" ] || return 1
  printf '%s\n' "$gitdir"
}

# _dw_worktree_rows DIR — `git worktree list --porcelain -z` of the repository
# at DIR as `<path>\t<branch>\t<is_main>\t<prunable>\t<locked>`, main first.
# A path with a control character is skipped with a warning.
_dw_worktree_rows() {
  local token path="" branch="" prunable=0 locked=0 first=1 listing
  listing="$(mktemp "${TMPDIR:-/tmp}/dj-worktrees.XXXXXX")" || return 1
  if ! _hy_git -C "$1" worktree list --porcelain -z >"$listing" 2>/dev/null; then
    rm -f "$listing"
    return 1
  fi
  while IFS= read -r -d '' token; do
    case "$token" in
      "worktree "*) path="${token#worktree }"; branch=detached; prunable=0; locked=0 ;;
      "branch "*) branch="${token#branch refs/heads/}" ;;
      prunable|"prunable "*) prunable=1 ;;
      locked|"locked "*) locked=1 ;;
      "")
        [ -n "$path" ] || continue
        if _dw_has_control "$path"; then
          echo "disk-janitor: a worktree path of $1 holds a control character; not enumerated" >&2
        else
          printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$branch" "$first" "$prunable" "$locked"
        fi
        first=0
        path=""
        ;;
    esac
  done <"$listing"
  rm -f "$listing"
}

# _dw_cc_verdict PATH BRANCH MAIN LOCKED
#
# The A7 sweep predicate for a Claude Code worktree (`cc-*` under the central
# root). Prints `sweep\t<merged 0|1>\t<why>` when PATH may be removed with
# `git worktree remove`, else `hold\t\t<reason>`. Removable means all of:
# unlocked; no tracked or untracked change and every ignored path regenerable
# (git worktree remove deletes ignored content); no live handle; idle more
# than cc_worktree_idle_days by git activity; no attachment owner record names
# it (removing an attached worktree would orphan its record); and the branch is
# merged (dj_branch_merged) or HEAD has no commit outside every other branch
# and remote. Under --safe-only only a merged branch qualifies.
_dw_cc_verdict() {
  local path="$1" branch="$2" main="$3" locked="$4" idle rows reason="" in_use activity
  local owners unique merged=1 why tab dirty
  tab="$(printf '\t')"
  [ "$locked" = 0 ] || { printf 'hold\t\tlocked\n'; return 0; }
  idle="$(cfg_num '.disk_janitor.cc_worktree_idle_days' 1)"
  rows="$(dj_dehydrate_classify "$path" "$idle" "$NOW_EPOCH" "$LSOF_SNAPSHOT_TMP")" ||
    reason="classification failed"
  if [ -z "$reason" ] && [ -z "$rows" ]; then
    if dirty="$(_hy_git -C "$path" status --porcelain 2>/dev/null)"; then
      [ -z "$dirty" ] || reason="tracked or untracked changes"
    else
      reason="git error"
    fi
  fi
  [ -n "$reason" ] || reason="$(printf '%s\n' "$rows" | awk -F'\t' '
    $1 == "hold" { print $4; exit }
    $1 == "keep" { k="ignored content outside the regenerable set" }
    END { if (k != "") print k }')"
  if [ -z "$reason" ] && in_use="$(dj_worktree_in_use "$path" "$LSOF_SNAPSHOT_TMP")"; then
    reason="in use ($in_use)"
  fi
  if [ -z "$reason" ]; then
    if ! activity="$(hy_last_git_activity "$path")"; then
      reason="git activity unknown"
    elif ! dj_cache_is_stale "$activity" "$idle" "$NOW_EPOCH"; then
      reason="recent git activity (idle <= ${idle}d)"
    fi
  fi
  if [ -z "$reason" ]; then
    owners="$(mktemp "${TMPDIR:-/tmp}/dj-cc-owners.XXXXXX")" || return 1
    if ! dj_pi_owner_paths "$TRELLIS_HOME" "$owners"; then
      reason="attachment owner records unreadable"
    elif dj_pi_path_owned "$path" "$owners"; then
      reason="attached: an owner record names it (detach it first; git worktree remove would orphan the record)"
    fi
    rm -f "$owners"
  fi
  if [ -z "$reason" ]; then
    if dj_branch_merged "$main" "$branch"; then
      merged=0
      why="merged"
    elif [ "$SAFE_ONLY" -eq 1 ]; then
      reason="safe-only: not merged"
    else
      if [ "$branch" = detached ]; then
        unique="$(_hy_git -C "$path" rev-list --count HEAD --not --branches --remotes 2>/dev/null)" || unique=""
      else
        unique="$(_hy_git -C "$path" rev-list --count HEAD --not --exclude="$branch" --branches \
          --remotes 2>/dev/null)" || unique=""
      fi
      case "$unique" in
        0) why="no unique commits" ;;
        ''|*[!0-9]*) reason="git error" ;;
        *) reason="unmerged with $unique unique commit(s)" ;;
      esac
    fi
  fi
  if [ -n "$reason" ]; then
    printf 'hold\t\t%s\n' "$reason"
  else
    printf 'sweep%s%s%s%s, idle > %sd\n' "$tab" "$((1 - merged))" "$tab" "$why" "$idle"
  fi
}

# _dw_plan_orphan DIR GITDIR — the D5 report row for an orphaned worktree
# directory, plus its dehydrate plan (dj_dehydrate_classify_orphan).
_dw_plan_orphan() {
  local dir="$1" gitdir="$2" summary count planned held detail=""
  _dw_has_control "$gitdir" && gitdir="(name with a control character)"
  summary="$(dj_dehydrate_plan_tree "$dir" "" "" "" "" "" "")" || return 0
  IFS="$(printf '\t')" read -r count planned held <<EOF
$summary
EOF
  if _dw_is_count "$count" && _dw_is_count "$planned" && [ "$count" -gt 0 ]; then
    detail="; dehydrate: $count regenerable path(s), $(dj_human_bytes "$planned")"
  elif [ -n "$held" ]; then
    detail="; dehydrate held: $held"
  fi
  plan_row orphans orphan worktree-orphan "$dir" "$(dj_dir_bytes "$dir")" - \
    "gitdir $gitdir is gone; repair it (git worktree repair) or hold it with \`trellis worktree migrate\`; never removed whole$detail"
}

# _dw_enumerate LISTING — A11, A8, the A7 cc-* sweep and the D5 orphan pass. LISTING is 1 when
# the worktrees scope enumerates; orphans need only the orphans scope. Every repository reached by _dw_seed_dirs is
# listed once (by git common dir); each linked worktree that is not a registry
# row, not missing and not under a pi root is reported in the worktrees scope.
# A `_codex` worktree is a report-only skip: Codex rotates its own. Every other
# one is a report-only candidate whose regenerable content is planned for
# dehydrate. A repository git cannot read is reported and left alone.
_dw_enumerate() {
  local listing="$1" root pi legacy seen="" nl dir common rows main path branch is_main
  local prunable locked bytes summary count planned held detail tab gitdir cc cc_note
  tab="$(printf '\t')"
  nl="$(printf '\nx')"; nl="${nl%x}"
  root="$(hy_root)" || root=""
  pi="$(_hy_canon "$HOME/.pi-worktrees")" || pi=""
  legacy="$(_hy_canon "$TRELLIS_HOME/pi-worktrees")" || legacy=""
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    if gitdir="$(_dw_orphan_gitdir "$dir")"; then
      ! scope_enabled orphans || _dw_plan_orphan "$dir" "$gitdir"
      continue
    fi
    [ "$listing" -eq 1 ] || continue
    if ! common="$(_hy_common_dir "$dir")"; then
      plan_row worktrees skip worktree-unreadable "$dir" 0 - \
        "skip (git cannot read this repository; its worktrees were not enumerated)"
      continue
    fi
    case "$nl$seen$nl" in *"$nl$common$nl"*) continue ;; esac
    seen="$seen$nl$common"
    if ! rows="$(_dw_worktree_rows "$dir")"; then
      plan_row worktrees skip worktree-unreadable "$dir" 0 "$common" \
        "skip (git worktree list failed; its worktrees were not enumerated)"
      continue
    fi
    main="${rows%%"$tab"*}"
    while IFS="$tab" read -r path branch is_main prunable locked; do
      [ "$is_main" = 0 ] && [ "$prunable" = 0 ] || continue
      path="$(_hy_canon "$path")" || continue
      cut -f5 "$TARGETS_TMP" | grep -Fxq -- "$path" && continue
      if _dw_under_root "$path" "$pi" || _dw_under_root "$path" "$legacy"; then
        continue
      fi
      bytes="$(dj_dir_bytes "$path")"
      if [ -n "$root" ] && _dw_under_root "$path" "$root/_codex"; then
        plan_row worktrees skip worktree-codex "$path" "$bytes" "$common" \
          "skip (Codex app worktree under _codex: Codex rotates it; reported, never removed or dehydrated) — branch=$branch"
        continue
      fi
      cc_note=""
      if _dw_under_root "$path" "$root"; then
        case "${path##*/}" in
          cc-*)
          cc="$(_dw_cc_verdict "$path" "$branch" "$main" "$locked")" || cc=""
          if [ "${cc%%"$tab"*}" = sweep ]; then
            plan_row worktrees sweep worktree-cc "$path" "$bytes" "$common" \
              "sweep (Claude Code worktree: clean, ${cc##*"$tab"}; git worktree remove, never --force) — branch=$branch" \
              "" "" "" "" "$common" "$main"
            continue
          fi
          cc_note="; cc sweep held: ${cc##*"$tab"}"
          ;;
        esac
      fi
      summary="$(dj_dehydrate_plan_tree "$path" "" "" "" "" "$common" "")" || continue
      IFS="$tab" read -r count planned held <<EOF
$summary
EOF
      detail=""
      if _dw_is_count "$count" && _dw_is_count "$planned" && [ "$count" -gt 0 ]; then
        detail="; dehydrate: $count regenerable path(s), $(dj_human_bytes "$planned")"
      elif [ -n "$held" ]; then
        detail="; dehydrate held: $held"
      fi
      [ "$locked" = 0 ] || detail="$detail; locked"
      plan_row worktrees candidate worktree-unregistered "$path" "$bytes" "$common" \
        "candidate (worktree with no registry row, of $main; report-only$cc_note$detail) — branch=$branch"
    done <<EOF
$rows
EOF
  done < <(_dw_seed_dirs | awk '!seen[$0]++')
}

dj_dehydrate_scan() {
  local listing=0
  if scope_enabled worktrees && [ -z "$ONLY_PROJECT" ]; then listing=1; fi
  [ "$listing" -eq 1 ] || scope_enabled orphans || return 0
  _dw_enumerate "$listing"
}

# _dw_render_dehydrate — the D1 plan: one line per tree, every planned path in
# dry-run, and the held bytes split by reason, so the spec §9 reclaim metric
# (or the per-reason gap) reads straight off one report.
_dw_render_dehydrate() {
  local tab tree verdict bytes count kept reason kind path
  tab="$(printf '\t')"
  awk -F'\t' '$1=="dehydrate" { found = 1 } END { exit !found }' "$PLAN_TMP" || return 0
  echo "== Dehydrate: regenerable directories in idle, clean worktrees (spec 069 D1) =="
  [ "$DEHYDRATE" -eq 1 ] || echo "  plan only: --apply --dehydrate removes the delete paths"
  awk -F'\t' '
    $1 == "dehydrate" {
      t = $6; seen[t] = 1
      if ($2 == "keep") { kept[t]++; next }
      n[t]++; b[t] += $5; v[t] = $2
      if ($2 == "hold") r[t] = $7
    }
    END { for (t in seen) printf "%s\t%s\t%.0f\t%d\t%d\t%s\n", t, (t in v ? v[t] : "keep"), b[t], n[t], kept[t], r[t] }
  ' "$PLAN_TMP" | LC_ALL=C sort |
    while IFS="$tab" read -r tree verdict bytes count kept reason; do
      printf '  [%s] %s (%s in %s regenerable path(s); %s other ignored path(s) kept)%s\n' \
        "$verdict" "$tree" "$(dj_human_bytes "$bytes")" "$count" "$kept" "${reason:+ — $reason}"
    done
  if [ "$MODE" = dry-run ]; then
    awk -F'\t' '$1=="dehydrate" && $2=="delete"' "$PLAN_TMP" |
      while IFS="$tab" read -r _ _ kind path bytes _; do
        printf '    remove  %s  (%s, %s)\n' "$path" "$kind" "$(dj_human_bytes "$bytes")"
      done
  fi
  printf '  reclaimable by dehydrate: %s\n' "$(dj_human_bytes "$(sum_bytes dehydrate delete)")"
  echo "  held regenerable bytes by reason:"
  awk -F'\t' '$1=="dehydrate" && $2=="hold" { s[$7] += $5; seen = 1 }
    END { for (r in s) printf "%.0f\t%s\n", s[r], r; if (!seen) print "0\t(none)" }' "$PLAN_TMP" |
    LC_ALL=C sort -rn |
    while IFS="$tab" read -r bytes reason; do
      printf '    %s: %s\n' "$reason" "$(dj_human_bytes "$bytes")"
    done
  printf '  ignored content kept outside the regenerable set: %s\n' \
    "$(dj_human_bytes "$(sum_bytes dehydrate keep)")"
  echo
}

# _dw_render_orphans — the D5 report: every orphaned worktree directory, its
# footprint and the repair route. Its regenerable part is in the dehydrate plan.
_dw_render_orphans() {
  local tab path bytes detail
  tab="$(printf '\t')"
  scope_enabled orphans || return 0
  echo "== Orphaned worktree directories (gitdir gone; spec 069 D5) =="
  awk -F'\t' '$1=="orphans"' "$PLAN_TMP" | grep -q . || echo "  (none)"
  awk -F'\t' -v OFS='\t' '$1=="orphans" { print $4, $5, $7 }' "$PLAN_TMP" |
    while IFS="$tab" read -r path bytes detail; do
      printf '  [orphan] %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
  printf '  orphan footprint: %s; only --dehydrate removes anything, and only regenerable directories\n' \
    "$(dj_human_bytes "$(sum_bytes orphans '*')")"
  echo
}

# _dw_render_sweep — the A7 sweep plan, for report and dry-run.
_dw_render_sweep() {
  local tab path bytes detail
  tab="$(printf '\t')"
  awk -F'\t' '$1=="worktrees" && $2=="sweep" { f = 1 } END { exit !f }' "$PLAN_TMP" || return 0
  echo "== Claude Code cc-* worktrees to remove (spec 069 A7 sweep; --apply runs git worktree remove) =="
  awk -F'\t' -v OFS='\t' '$1=="worktrees" && $2=="sweep" { print $4, $5, $7 }' "$PLAN_TMP" |
    while IFS="$tab" read -r path bytes detail; do
      printf '  git worktree remove  %s  (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$detail"
    done
  printf '  -> %s reclaimable\n' "$(dj_human_bytes "$(sum_bytes worktrees sweep)")"
  echo
}

dj_dehydrate_render() {
  _dw_render_sweep
  _dw_render_orphans
  _dw_render_dehydrate
}

# _dw_apply_sweep — remove the planned cc-* worktrees. Each one is re-checked
# under the registry lock with a fresh lsof snapshot: same git common dir, still
# a linked, unmissing worktree of MAIN, and _dw_cc_verdict still says sweep.
# Removal is `git worktree remove` without --force; the worktree-<name> branch
# is then deleted only when it is the worktree's branch and verified merged.
# shellcheck disable=SC2034  # EXIT_STATUS is the janitor's exit class
_dw_apply_sweep() {
  local us tab path bytes common main rows line cc branch locked merged reclaimed=0
  us="$(printf '\037')"
  tab="$(printf '\t')"
  awk -F'\t' '$1=="worktrees" && $2=="sweep" { f = 1 } END { exit !f }' "$PLAN_TMP" || return 0
  echo "== Claude Code cc-* worktrees to remove (spec 069 A7 sweep), $(dj_human_bytes "$(sum_bytes worktrees sweep)") =="
  awk -F'\t' -v OFS='\t' '$1=="worktrees" && $2=="sweep" { print $4, $5, $7 }' "$PLAN_TMP" |
    while IFS="$tab" read -r path bytes line; do
      printf '  %s (%s) — %s\n' "$path" "$(dj_human_bytes "$bytes")" "$line"
    done
  if ! confirm_category "these Claude Code cc-* worktrees (git worktree remove, never --force)"; then
    echo
    return 0
  fi
  while IFS="$us" read -r path bytes common main; do
    [ -n "$path" ] || continue
    if ! _dw_is_count "$bytes" || _dw_has_control "$path$main"; then
      echo "  REFUSED: malformed sweep plan row" >&2
      EXIT_STATUS=1
      continue
    fi
    if ! trellis_home_lock_acquire "$TRELLIS_HOME" registry 30; then
      echo "  REFUSED: $path (could not acquire the registry lock)" >&2
      EXIT_STATUS=1
      continue
    fi
    cc=""
    branch=""
    if [ "$(_hy_common_dir "$path" 2>/dev/null)" = "$common" ] &&
        rows="$(_dw_worktree_rows "$main")"; then
      line="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$path" '$1==p && $3==0 && $4==0')"
      if [ -n "$line" ]; then
        IFS="$tab" read -r _ branch _ _ locked <<EOF
$line
EOF
        dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5 || :
        cc="$(_dw_cc_verdict "$path" "$branch" "$main" "$locked")" || cc=""
      fi
    fi
    if [ "${cc%%"$tab"*}" != sweep ]; then
      echo "  skipped (plan changed): $path — ${cc##*"$tab"}"
    elif _hy_git -C "$main" worktree remove "$path" >/dev/null 2>&1; then
      reclaimed=$((reclaimed + bytes))
      echo "  removed worktree: $path"
      merged="${cc#sweep"$tab"}"
      merged="${merged%%"$tab"*}"
      if [ "$merged" = 1 ] && [ "$branch" = "worktree-${path##*/cc-}" ]; then
        if _hy_git -C "$main" branch -D "$branch" >/dev/null 2>&1; then
          echo "  deleted merged branch: $branch"
        else
          echo "  REFUSED/failed: could not delete merged branch $branch" >&2
          EXIT_STATUS=1
        fi
      fi
    else
      echo "  REFUSED/failed: $path (git worktree remove refused)" >&2
      EXIT_STATUS=1
    fi
    if ! trellis_home_lock_release >/dev/null 2>&1; then
      echo "  REFUSED: could not release the registry lock after $path" >&2
      EXIT_STATUS=1
    fi
  done < <(awk -F'\t' -v OFS="$us" '$1=="worktrees" && $2=="sweep" { print $4, $5, $12, $13 }' "$PLAN_TMP")
  printf '  cc-* worktrees: %s removed\n' "$(dj_human_bytes "$reclaimed")"
  echo
}

# _dw_unlink_link TREE LINK — remove the symlink LINK strictly below TREE
# without following it or any parent: every component is opened from TREE with
# O_NOFOLLOW, and the leaf must still be a symlink when it is unlinked. The
# link's target is never touched.
_dw_unlink_link() {
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

root, target = sys.argv[1:3]
rel = os.path.relpath(target, root)
parts = rel.split(os.sep)
if rel == ".." or rel.startswith("../") or any(p in ("", ".", "..") for p in parts):
    sys.exit("dehydrate: link is not strictly below its tree: %s" % target)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
fds = []
try:
    fds.append(os.open(root, flags))
    for part in parts[:-1]:
        fds.append(os.open(part, flags, dir_fd=fds[-1]))
    leaf = os.stat(parts[-1], dir_fd=fds[-1], follow_symlinks=False)
    if not stat.S_ISLNK(leaf.st_mode):
        sys.exit("dehydrate: no longer a symlink: %s" % target)
    os.unlink(parts[-1], dir_fd=fds[-1])
except OSError as error:
    sys.exit("dehydrate: could not unlink %s: %s" % (target, error))
finally:
    for fd in reversed(fds):
        os.close(fd)
PY
}

# _dw_owner_unchanged TREE FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID COMMON ROOT
#
# The planned owner still holds TREE: the exact active registry row for a
# registered tree, the same git common dir for an unregistered one, and a
# still-missing gitdir for an orphan.
_dw_owner_unchanged() {
  local tree="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5"
  local common="$6" root="$7" actual
  if [ -n "$fleet" ]; then
    dj_registered_owner_identity "$TRELLIS_HOME" "$fleet" "$project_id" \
      "$checkout_id" "$worktree_id" "$common" "$root" >/dev/null 2>&1
    return
  fi
  if [ -z "$common" ]; then
    _dw_orphan_gitdir "$tree" >/dev/null
    return
  fi
  actual="$(_hy_common_dir "$tree")" || return 1
  [ "$actual" = "$common" ]
}

# _dw_apply_tree TREE FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID COMMON ROOT
#
# Remove TREE's planned regenerable paths. Under the registry lock (as
# dj_reap_worktree holds it), the owner is re-checked, a fresh lsof snapshot is
# taken and the tree is classified again; a path is removed only when the fresh
# classification still says delete for the same kind. Directories go through
# dj_remove_cache_tree_safely (descriptor-relative, no symlink or mount
# crossing); links through _dw_unlink_link.
# shellcheck disable=SC2034  # EXIT_STATUS is the janitor's exit class
_dw_apply_tree() {
  local tree="$1" fresh kind path bytes now_reason us rc
  us="$(printf '\037')"
  if ! trellis_home_lock_acquire "$TRELLIS_HOME" registry 30; then
    echo "  REFUSED: $tree (could not acquire the registry lock)" >&2
    EXIT_STATUS=1
    return 0
  fi
  if ! _dw_owner_unchanged "$@"; then
    echo "  skipped (plan changed): $tree — owner changed or is unavailable"
  else
    dj_capture_lsof_snapshot "$LSOF_SNAPSHOT_TMP" 5 || :
    fresh="$(_dw_classify_for "$tree" "$(dj_dehydrate_idle_days)" "$(date +%s)" \
      "$LSOF_SNAPSHOT_TMP" "$2" "$6")" || fresh=""
    while IFS="$us" read -r kind path bytes; do
      [ -n "$path" ] || continue
      # The plan file is advisory text: a row that does not round-trip as a
      # count is refused before anything reads it as a number.
      if ! _dw_is_count "$bytes" || _dw_has_control "$path"; then
        echo "  REFUSED: malformed dehydrate plan row under $tree" >&2
        EXIT_STATUS=1
        continue
      fi
      if ! printf '%s\n' "$fresh" | awk -F'\t' -v k="$kind" -v p="$path" \
          '$1=="delete" && $2==k && $3==p { f = 1 } END { exit !f }'; then
        now_reason="$(printf '%s\n' "$fresh" | awk -F'\t' -v p="$path" '$3==p { print $4; exit }')"
        echo "  skipped (plan changed): $path — ${now_reason:-no longer planned}"
        continue
      fi
      case "$kind" in
        link:*)
          if _dw_unlink_link "$tree" "$path"; then
            echo "  unlinked: $path"
          else
            echo "  REFUSED/failed: $path (symlink removal refused)" >&2
            EXIT_STATUS=1
          fi
          ;;
        *)
          if _dw_has_nested_git "$path"; then rc=0; else rc=$?; fi
          case "$rc" in
            0)
              echo "  REFUSED: $path (contains a nested git repository or linked worktree)" >&2
              EXIT_STATUS=1
              continue
              ;;
            2)
              echo "  REFUSED: $path (could not scan for nested git repositories)" >&2
              EXIT_STATUS=1
              continue
              ;;
          esac
          if dj_remove_cache_tree_safely "$tree" "$path"; then
            echo "  removed: $path ($(dj_human_bytes "$bytes"))"
            DW_DEHYDRATED_BYTES=$((DW_DEHYDRATED_BYTES + bytes))
          else
            echo "  REFUSED/failed: $path (descriptor-relative removal refused)" >&2
            EXIT_STATUS=1
          fi
          ;;
      esac
    done < <(awk -F'\t' -v t="$tree" -v OFS="$us" \
      '$1=="dehydrate" && $2=="delete" && $6==t { print $3, $4, $5 }' "$PLAN_TMP")
  fi
  if ! trellis_home_lock_release >/dev/null 2>&1; then
    echo "  REFUSED: could not release the registry lock after $tree" >&2
    EXIT_STATUS=1
  fi
}

DW_DEHYDRATED_BYTES=0

dj_dehydrate_apply() {
  local us tree fleet project_id checkout_id worktree_id common root planned
  _dw_apply_sweep
  if [ "$DEHYDRATE" -ne 1 ]; then
    _dw_render_orphans
    _dw_render_dehydrate
    return 0
  fi
  _dw_render_orphans
  planned="$(sum_bytes dehydrate delete)"
  awk -F'\t' '$1=="dehydrate" && $2=="delete" { found = 1 } END { exit !found }' "$PLAN_TMP" || {
    _dw_render_dehydrate
    return 0
  }
  echo "== Dehydrate: remove regenerable directories in idle, clean worktrees, $(dj_human_bytes "$planned") =="
  awk -F'\t' '$1=="dehydrate" && $2=="delete"' "$PLAN_TMP" |
    while IFS="$(printf '\t')" read -r _ _ kind path bytes _; do
      printf '  %s (%s, %s)\n' "$path" "$kind" "$(dj_human_bytes "$bytes")"
    done
  if confirm_category "these regenerable directories (dehydrate; ignored content outside the regenerable set is kept)"; then
    us="$(printf '\037')"
    # \037 keeps the empty identity fields of an unregistered tree in place;
    # a tab IFS would collapse them.
    while IFS="$us" read -r tree fleet project_id checkout_id worktree_id common root; do
      [ -n "$tree" ] || continue
      _dw_apply_tree "$tree" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$common" "$root"
    done < <(awk -F'\t' -v OFS="$us" '$1=="dehydrate" && $2=="delete" && !seen[$6]++ \
      { print $6, $8, $9, $10, $11, $12, $13 }' "$PLAN_TMP")
    printf '  dehydrated: %s removed (planned %s)\n' "$(dj_human_bytes "$DW_DEHYDRATED_BYTES")" \
      "$(dj_human_bytes "$planned")"
  fi
  echo
}
