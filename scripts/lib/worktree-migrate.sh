#!/usr/bin/env bash
# worktree-migrate.sh — `trellis worktree migrate` (spec 069 A3-A6): drain the
# machine's linked worktrees into the sanctioned roots, once, with a journal.
#
# Sourced by scripts/worktree.sh after hygiene-common.sh and
# disk-janitor-lib.sh, so it runs under the wrapper's `set -euo pipefail`.
# Function-only: nothing runs at source time.
#
# Inventory. A repository is in scope when its git common dir is named by a
# local registry checkout, or when a directory holding `.git` (file or
# directory) sits up to three levels below a scanned parent:
# `worktrees.known_parents`, the central root, the legacy pi roots and the
# foreign managed roots. EVIDENCE.md P4: 95 of 216 worktrees belong to repos
# with no registry row, so registry rows alone are not enough. Each repo's
# `git worktree list --porcelain` is the source of truth; its main checkout is
# never a row. A `.git` file whose gitdir is gone is an orphan row.
#
# Output. One plan row per linked worktree, as JSON Lines (`--json`) or a
# table plus totals (the default). Plan row (plan §2):
#   {repo, common, path, branch, head, project, class, reasons[], target,
#    dehydrate[], after[], owner_record, release, locked, bytes, ...}
#
# bash 3.2 compatible: no [[ ]], no associative arrays, no mapfile.

_WM_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

wm_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    GIT_OPTIONAL_LOCKS=0 git "$@"
}

wm_err() {
  printf 'trellis worktree migrate: %s\n' "$*" >&2
}

# wm_config_path — the portable policy file, found the way config-load.sh finds
# it: $TRELLIS_CONFIG, then an exported $TRELLIS_CONFIG_PATH, then the nearest
# trellis.config.json above this library. Prints nothing when there is none.
wm_config_path() {
  local dir
  if [ -n "${TRELLIS_CONFIG:-}" ]; then
    [ -f "$TRELLIS_CONFIG" ] && printf '%s\n' "$TRELLIS_CONFIG"
    return 0
  fi
  if [ -n "${TRELLIS_CONFIG_PATH:-}" ] && [ -f "$TRELLIS_CONFIG_PATH" ]; then
    printf '%s\n' "$TRELLIS_CONFIG_PATH"
    return 0
  fi
  dir="$_WM_LIB_DIR"
  while :; do
    if [ -f "$dir/trellis.config.json" ]; then
      printf '%s\n' "$dir/trellis.config.json"
      return 0
    fi
    [ "$dir" != "/" ] || return 0
    dir="$(dirname "$dir")"
  done
}

# wm_config_list KEY — the string list `.worktrees.KEY`, one per line, with a
# leading `~` expanded to $HOME.
wm_config_list() {
  local cfg
  cfg="$(wm_config_path)"
  [ -n "$cfg" ] || return 0
  jq -r --arg key "$1" '.worktrees[$key] // [] | .[]' "$cfg" 2>/dev/null |
    while IFS= read -r item; do
      case "$item" in
        \~) item="$HOME" ;;
        \~/*) item="$HOME/${item#\~/}" ;;
      esac
      printf '%s\n' "$item"
    done
}

# _wm_walk DIR DEPTH — directories up to DEPTH levels below DIR that hold a
# `.git` entry, NUL-terminated. A repository is never descended into;
# node_modules is skipped.
_wm_walk() {
  local dir="$1" depth="$2" child
  for child in "$dir"/* "$dir"/.[!.]*; do
    [ -d "$child" ] && [ ! -L "$child" ] || continue
    if [ -e "$child/.git" ] || [ -L "$child/.git" ]; then
      printf '%s\0' "$child"
      continue
    fi
    [ "$depth" -gt 1 ] || continue
    case "${child##*/}" in node_modules|.git) continue ;; esac
    _wm_walk "$child" $((depth - 1))
  done
}

# wm_scan_parents — every directory to walk: known_parents, the central root,
# the legacy pi roots and the foreign managed roots (whose worktrees are held).
wm_scan_parents() {
  wm_config_list known_parents
  hy_root || true
  printf '%s\n' "$HOME/.pi-worktrees" "${TRELLIS_HOME:-$HOME/.trellis}/pi-worktrees" \
    "$HOME/.cursor/worktrees" "${CODEX_HOME:-$HOME/.codex}/worktrees"
}

# wm_inventory_repos WORK — print the unique git common dirs in scope,
# NUL-terminated. Side files, JSON Lines so any path survives:
#   WORK/orphans.jsonl  {path, gitdir}  a `.git` that resolves to no repository
#   WORK/links.jsonl    {path, admin}   a found linked worktree and the admin
#                       dir its `.git` file points at; a worktree moved by hand
#                       still points at its old admin dir, which git lists as
#                       prunable under the old path.
wm_inventory_repos() {
  local work="$1" registry parent found common admin gitdir
  registry="${TRELLIS_HOME:-$HOME/.trellis}/registry.json"
  : > "$work/orphans.jsonl"
  : > "$work/links.jsonl"
  {
    if [ -f "$registry" ]; then
      jq -j '[.projects[]?.checkouts[]?.git_common_dir] | unique | .[] | . + "\u0000"' "$registry" 2>/dev/null |
        while IFS= read -r -d '' common; do
          [ -d "$common" ] && printf '%s\0' "$common"
        done
    fi
    wm_scan_parents | while IFS= read -r parent; do
      [ -d "$parent" ] || continue
      _wm_walk "$parent" 3
    done | while IFS= read -r -d '' found; do
      if common="$(wm_git -C "$found" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
         [ -d "$common" ]; then
        printf '%s\0' "$(CDPATH='' cd "$common" && pwd -P)"
        if [ -f "$found/.git" ] &&
           admin="$(wm_git -C "$found" rev-parse --absolute-git-dir 2>/dev/null)" && [ -d "$admin" ]; then
          jq -nc --arg p "$found" --arg a "$(CDPATH='' cd "$admin" && pwd -P)" '{path:$p, admin:$a}' \
            >> "$work/links.jsonl"
        fi
      else
        gitdir=""
        [ ! -f "$found/.git" ] || gitdir="$(sed -n 's/^gitdir: //p' "$found/.git" 2>/dev/null | head -n 1)"
        jq -nc --arg p "$found" --arg g "$gitdir" '{path:$p, gitdir:$g}' >> "$work/orphans.jsonl"
      fi
    done
  } | sort -zu
}

# wm_owner_index WORK — WORK/owners.jsonl: {root, release, file} for every
# attachment owner record.
wm_owner_index() {
  local work="$1" file
  : > "$work/owners.jsonl"
  for file in "${TRELLIS_HOME:-$HOME/.trellis}"/state/attachments/*/*.json; do
    [ -f "$file" ] || continue
    jq -c --arg file "$file" '{root:(.worktree_root // ""), release:(.release // ""), file:$file}' "$file" \
      >> "$work/owners.jsonl" 2>/dev/null ||
      jq -nc --arg file "$file" '{root:"", release:"", file:$file}' >> "$work/owners.jsonl"
  done
}

# wm_porcelain COMMON — `git worktree list --porcelain -z` for one repository,
# one JSON object per worktree: {path, head, branch, locked, prunable, main}.
wm_porcelain() {
  local tok path="" head="" branch="" locked=0 prunable=0 n=0
  _wm_porcelain_emit() {
    [ -n "$path" ] || return 0
    jq -nc --arg path "$path" --arg head "$head" --arg branch "$branch" \
      --argjson locked "$locked" --argjson prunable "$prunable" --argjson main "$([ "$n" -eq 1 ] && echo true || echo false)" \
      '{path:$path, head:$head, branch:$branch, locked:($locked == 1), prunable:($prunable == 1), main:$main}'
    path=""; head=""; branch=""; locked=0; prunable=0
  }
  while IFS= read -r -d '' tok; do
    case "$tok" in
      '') _wm_porcelain_emit ;;
      'worktree '*) path="${tok#worktree }"; n=$((n + 1)) ;;
      'HEAD '*) head="${tok#HEAD }" ;;
      'branch '*) branch="${tok#branch }"; branch="${branch#refs/heads/}" ;;
      locked|'locked '*) locked=1 ;;
      prunable|'prunable '*) prunable=1 ;;
    esac
  done < <(wm_git --git-dir="$1" worktree list --porcelain -z 2>/dev/null)
  _wm_porcelain_emit
}

# wm_admin_dir COMMON PATH — the admin dir (COMMON/worktrees/<name>) whose
# gitdir back-link names PATH.
wm_admin_dir() {
  local gitdir
  for gitdir in "$1"/worktrees/*/gitdir; do
    [ -f "$gitdir" ] || continue
    if [ "$(cat "$gitdir")" = "$2/.git" ]; then
      (CDPATH='' cd "${gitdir%/gitdir}" && pwd -P)
      return 0
    fi
  done
  return 1
}

# wm_linked_from WORK ADMIN — an existing directory whose `.git` file points
# at ADMIN (from the inventory walk).
wm_linked_from() {
  jq -r --arg a "$2" 'select(.admin == $a) | .path' "$1/links.jsonl" 2>/dev/null |
    while IFS= read -r found; do
      [ -d "$found" ] && { printf '%s\n' "$found"; break; }
    done
}

# wm_bytes PATH — on-disk bytes (du -sk), 0 when absent.
wm_bytes() {
  local kb
  [ -e "$1" ] || { printf '0\n'; return 0; }
  kb="$(du -sk "$1" 2>/dev/null | cut -f 1)" || kb=0
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  printf '%s\n' "$((kb * 1024))"
}

# wm_facts_repo WORK COMMON ROOT [ONLY] — the fact rows for one repository's
# linked worktrees, or for its worktree at ONLY (WORK/owners.jsonl and
# WORK/links.jsonl must be current).
wm_facts_repo() {
  local work="$1" common="$2" root="$3" only="${4:-}" repo="" rec path head branch locked prunable main
  local project_dir project prc owners owner_count owner release group_release="" registry admin moved_to
  # A moved worktree re-attaches at its checkout group's release (the
  # registry's checkout row), falling back to its own owner record's.
  registry="${TRELLIS_HOME:-$HOME/.trellis}/registry.json"
  [ ! -f "$registry" ] || group_release="$(jq -r --arg c "$common" '[.projects[]?.checkouts[]?
    | select(.git_common_dir == $c) | .release // empty] | first // empty' "$registry" 2>/dev/null)" || group_release=""
  wm_porcelain "$common" > "$work/porcelain.jsonl"
  while IFS= read -r rec; do
    eval "$(printf '%s' "$rec" | jq -r '@sh "path=\(.path) head=\(.head) branch=\(.branch) locked=\(.locked) prunable=\(.prunable) main=\(.main)"')"
    if [ "$main" = true ]; then repo="$path"; continue; fi
    [ -z "$only" ] || [ "$path" = "$only" ] || continue
    prc=0
    project_dir="$(hy_project_dir "$repo" 2>/dev/null)" || prc=$?
    case "$project_dir" in "$root"/*) project="${project_dir#"$root"/}" ;; *) project="" ;; esac
    owners="$(jq -c --arg p "$path" 'select(.root == $p)' "$work/owners.jsonl")"
    owner_count="$(printf '%s' "$owners" | grep -c . || true)"
    release="$(printf '%s\n' "$owners" | sed -n '1p' | jq -r '.release // empty' 2>/dev/null)"
    owner="$(printf '%s\n' "$owners" | sed -n '1p' | jq -r '.file // empty' 2>/dev/null)"
    moved_to=""
    if [ "$prunable" = true ] && admin="$(wm_admin_dir "$common" "$path")"; then
      moved_to="$(wm_linked_from "$work" "$admin")"
    fi
    jq -nc --arg repo "$repo" --arg common "$common" --arg path "$path" \
      --arg head "$head" --arg branch "$branch" --arg project "$project" \
      --argjson project_rc "$prc" --arg owner "$owner" --arg release "$release" \
      --arg group_release "$group_release" --arg moved_to "$moved_to" \
      --argjson owner_count "$owner_count" --argjson locked "$locked" \
      --argjson prunable "$prunable" --argjson bytes "$(wm_bytes "$path")" \
      '{repo:$repo, common:$common, path:$path, head:$head,
        branch:(if $branch == "" then null else $branch end),
        project:(if $project == "" then null else $project end), project_rc:$project_rc,
        owner_record:(if $owner == "" then null else $owner end),
        owner_count:$owner_count, release:(if $release == "" then null else $release end),
        group_release:(if $group_release == "" then null else $group_release end),
        locked:$locked, missing:$prunable, orphan:false, bytes:$bytes,
        moved_to:(if $moved_to == "" then null else $moved_to end),
        class:null, reasons:[], target:null, dehydrate:[], after:[]}'
  done < "$work/porcelain.jsonl"
}

# wm_facts WORK — the inventory: one JSON object per linked worktree (and per
# orphan directory) on stdout, before classification.
wm_facts() {
  local work="$1" root common rec
  root="$(hy_root)" || return "$?"
  wm_owner_index "$work"
  wm_inventory_repos "$work" > "$work/repos"
  while IFS= read -r -d '' common; do
    wm_facts_repo "$work" "$common" "$root"
  done < "$work/repos"
  while IFS= read -r rec; do
    printf '%s' "$rec" | jq -c --argjson bytes "$(wm_bytes "$(printf '%s' "$rec" | jq -r '.path')")" \
      '{repo:null, common:null, path:.path, head:null, branch:null, project:null, project_rc:2,
        owner_record:null, owner_count:0, release:null, locked:false, missing:false,
        orphan:true, gitdir:.gitdir, bytes:$bytes, moved_to:null,
        class:null, reasons:[], target:null, dehydrate:[], after:[]}'
  done < "$work/orphans.jsonl"
}

# The classifier, the apply engine and the preserve step live beside this
# file so each part stays reviewable on its own.
# shellcheck source=worktree-migrate-classify.sh
. "$_WM_LIB_DIR/worktree-migrate-classify.sh"
# shellcheck source=worktree-migrate-apply.sh
. "$_WM_LIB_DIR/worktree-migrate-apply.sh"
# shellcheck source=worktree-migrate-preserve.sh
. "$_WM_LIB_DIR/worktree-migrate-preserve.sh"

# wm_render_table ROWS — the human view: one line per row, then totals.
wm_render_table() {
  jq -r '[(.class // "-"), (.bytes | tostring), (.project // "-"), (.branch // "(detached)"),
          .path, ((.reasons | join("; ")) + (if .target then " -> " + .target else "" end))] | @tsv' "$1" |
    awk -F '\t' '
      function human(b) {
        if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
        if (b >= 1048576) return sprintf("%.1fM", b / 1048576)
        if (b >= 1024) return sprintf("%.1fK", b / 1024)
        return b "B"
      }
      BEGIN { printf "%-8s %7s  %-24s %-28s %s\n", "ACTION", "SIZE", "PROJECT", "BRANCH", "PATH / REASONS" }
      {
        printf "%-8s %7s  %-24s %-28s %s\n", $1, human($2), $3, $4, $5
        if ($6 != "") printf "%-8s %7s  %s\n", "", "", $6
        count[$1]++; bytes[$1] += $2; n++; total += $2
      }
      END {
        printf "\nTotals: %d worktree(s), %s\n", n, human(total)
        for (c in count) printf "  %-8s %4d  %s\n", c, count[c], human(bytes[c])
      }'
}

wm_usage() {
  cat <<'EOF'
Usage: trellis worktree migrate [--dry-run] [--json] [--only <path>]
       trellis worktree migrate --apply [--yes] [--only <path>] [--resume <journal>]
       trellis worktree migrate --revert <journal> [--yes]

Plan (default, read-only) or apply the move of every linked worktree into
the sanctioned roots. --json prints one plan row per line. --apply prints the
plan, asks for confirmation (or takes --yes), and journals every step under
TRELLIS_HOME/state/worktree-migrate/. --resume finishes an interrupted run in
its own journal. Exit 4 when any entry failed and was held.
EOF
}

# wm_main ARGS... — the `migrate` subcommand.
wm_main() {
  local json=0 only="" work rows status=0 mode=plan yes=0 resume="" revert="" journal
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) ;;
      --json) json=1 ;;
      --apply) mode=apply ;;
      --yes) yes=1 ;;
      --only|--resume|--revert)
        [ $# -ge 2 ] || { wm_usage >&2; return 2; }
        case "$1" in
          --only) only="$(_hy_canon "$2")" || { wm_err "--only needs an absolute path"; return 2; } ;;
          --resume) resume="$2" ;;
          --revert) revert="$2"; mode=revert ;;
        esac
        shift ;;
      -h|--help) wm_usage; return 0 ;;
      *) wm_err "unknown argument: $1"; wm_usage >&2; return 2 ;;
    esac
    shift
  done
  if [ -n "$resume" ] && { [ "$mode" != apply ] || [ ! -f "$resume" ]; }; then
    wm_err "--resume needs --apply and an existing journal"
    return 2
  fi
  wm_extend_path
  work="$(mktemp -d "${TMPDIR:-/tmp}/trellis-wt-migrate.XXXXXX")" || return 1
  rows="$work/rows.jsonl"
  if [ "$mode" = revert ]; then
    if [ ! -f "$revert" ]; then
      wm_err "--revert needs an existing journal: $revert"
      status=2
    elif { [ "$yes" -eq 1 ] || wm_confirm "Revert the moves in $revert"; } && wm_lock; then
      journal="${revert%.jsonl}-revert-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
      touch "$journal" && chmod 600 "$journal"
      wm_revert "$work" "$revert" "$journal" || status=$?
      wm_unlock
      printf 'journal: %s\n' "$journal"
    else
      status=$?
    fi
    rm -rf "$work"
    return "$status"
  fi
  if [ "$mode" = apply ]; then
    wm_lock || { status=$?; rm -rf "$work"; return "$status"; }
    if [ -n "$resume" ]; then
      [ "$yes" -eq 1 ] || wm_confirm "Resume $resume" || { status=$?; wm_unlock; rm -rf "$work"; return "$status"; }
      wm_resume "$work" "$resume" || status=4
    fi
  fi
  wm_facts "$work" > "$work/facts.jsonl" || status=$?
  if [ "$status" -eq 0 ] && [ -n "$only" ]; then
    jq -c --arg only "$only" 'select(.path == $only)' "$work/facts.jsonl" > "$work/only.jsonl"
    mv "$work/only.jsonl" "$work/facts.jsonl"
  fi
  case "$status" in 0|4) wm_classify "$work" "$work/facts.jsonl" > "$rows" || status=$? ;; esac
  case "$status" in
    0|4) if [ "$json" -eq 1 ]; then cat "$rows"; else wm_render_table "$rows"; fi ;;
  esac
  if [ "$mode" = apply ]; then
    case "$status" in
      0|4)
        if [ "$yes" -eq 1 ] || wm_confirm "Apply this plan"; then
          journal="${resume:-$(wm_state_dir)/$(date -u +%Y%m%dT%H%M%SZ).jsonl}"
          touch "$journal" && chmod 600 "$journal"
          wm_apply "$work" "$rows" "$journal" || status=$?
          printf 'journal: %s\n' "$journal"
        else
          status=$?
        fi ;;
    esac
    wm_unlock
  fi
  rm -rf "$work"
  return "$status"
}
