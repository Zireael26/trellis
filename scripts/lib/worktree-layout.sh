#!/usr/bin/env bash
# worktree-layout.sh — doctor rows for the central worktree root (spec 069
# A8, A10, A12). Owned by lane L-A (task A.9); L-0 ships the empty stub.
#
# hc_wt_layout_rows USER_HOME TRELLIS_HOME FIX_MODE
#
# The doctor row contract shared by worktree-layout.sh, dep-sharing.sh and
# pi-output-guard.sh. scripts/doctor.sh calls each row function once per run,
# after the disk-janitor agent rows, and reports every line it prints:
#
#   * stdout: zero or more `STATUS<TAB>MESSAGE` lines, STATUS one of the
#     health-checks.sh codes (0 HC_OK, 1 HC_ERROR, 2 HC_WARN, 3 HC_INFO). An
#     HC_ERROR row counts toward doctor's exit class. A line with an empty
#     MESSAGE is ignored.
#   * USER_HOME is the account HOME; TRELLIS_HOME is the resolved machine home.
#     Read paths only from these arguments so fixtures stay hermetic.
#   * FIX_MODE is `off` (plain doctor: read-only), `dry-run` (`--fix --dry-run`:
#     print what the repair would do, change nothing) or `apply` (`--fix`:
#     perform the lane's bounded repair, then report the resulting state).
#     A library with no repair treats all three as `off`.
#   * Never exit the caller, never prompt, never touch the network; return 0.
#     The caller runs under `set -euo pipefail`.
#
# This library reports the A12 state of the root from hygiene-common.sh's
# hy_root (Time Machine exclusion, .metadata_never_index, Spotlight hits), A8
# worktrees left under $CODEX_HOME/worktrees, and A10 an existing
# ~/.cursor/worktrees. Its --fix repair is `trellis worktree root-init`.

_WL_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hygiene-common.sh
. "$_WL_LIB_DIR/hygiene-common.sh"

WL_SPOTLIGHT_STEP='System Settings > Siri & Spotlight (Spotlight on older macOS) > Spotlight Privacy, add the folder'

# _wl_excluded ROOT — 0 when Time Machine excludes ROOT. Output is captured
# before matching so a caller's pipefail never reads SIGPIPE as "included".
_wl_excluded() {
  local out
  out="$(tmutil isexcluded "$1" 2>/dev/null || true)"
  case "$out" in *'[Excluded]'*) return 0 ;; esac
  return 1
}

# wl_root_init USER_HOME — create the central root (0755) with its
# .metadata_never_index marker and exclude it from Time Machine (A12).
# Idempotent. Prints one line per step; returns 5 when tmutil is unavailable
# (the root and marker are still made), 1 when the root cannot be created.
wl_root_init() {
  local root
  root="$(HOME="$1" hy_root)" || return 1
  mkdir -p "$root" && chmod 755 "$root" || return 1
  printf 'worktree root: %s\n' "$root"
  : > "$root/.metadata_never_index" || return 1
  printf 'spotlight marker: %s/.metadata_never_index\n' "$root"
  if ! command -v tmutil >/dev/null 2>&1; then
    printf 'time machine: tmutil unavailable; exclusion not set\n'
    return 5
  fi
  _wl_excluded "$root" || tmutil addexclusion "$root" || return 1
  printf 'time machine: %s\n' "$(tmutil isexcluded "$root" 2>/dev/null | head -n 1)"
}

hc_wt_layout_rows() {
  local user_home="$1" fix_mode="${3:-off}" root codex cursor count
  root="$(HOME="$user_home" hy_root 2>/dev/null)" || {
    printf '%s\t%s\n' 2 "worktree root: worktrees.root is not an absolute path"
    return 0
  }
  case "$fix_mode" in
    apply)
      if [ ! -d "$root" ] || [ ! -e "$root/.metadata_never_index" ] ||
         { command -v tmutil >/dev/null 2>&1 && ! _wl_excluded "$root"; }; then
        wl_root_init "$user_home" >/dev/null 2>&1 || true
      fi ;;
    dry-run)
      [ -d "$root" ] && [ -e "$root/.metadata_never_index" ] ||
        printf '%s\t%s\n' 3 "worktree root: --fix would run trellis worktree root-init for $root" ;;
  esac
  if [ ! -d "$root" ]; then
    printf '%s\t%s\n' 2 "worktree root $root does not exist; run: trellis worktree root-init"
  else
    if ! command -v tmutil >/dev/null 2>&1; then
      printf '%s\t%s\n' 3 "worktree root: tmutil unavailable; Time Machine exclusion not checked"
    elif _wl_excluded "$root"; then
      printf '%s\t%s\n' 0 "worktree root $root is excluded from Time Machine"
    else
      printf '%s\t%s\n' 2 "worktree root $root is not excluded from Time Machine; run: trellis worktree root-init"
    fi
    if [ -e "$root/.metadata_never_index" ]; then
      printf '%s\t%s\n' 0 "worktree root carries .metadata_never_index"
    else
      printf '%s\t%s\n' 2 "worktree root has no .metadata_never_index; run: trellis worktree root-init"
    fi
    # The marker is advisory on recent macOS. Hits mean Spotlight still
    # indexes the root, so name the manual step instead of claiming exclusion.
    if ! command -v mdfind >/dev/null 2>&1; then
      printf '%s\t%s\n' 3 "worktree root: mdfind unavailable; Spotlight state not checked"
    elif [ -n "$(mdfind -onlyin "$root" 'kMDItemFSName == "*"' 2>/dev/null | head -n 1)" ]; then
      printf '%s\t%s\n' 2 "Spotlight still indexes $root; in $WL_SPOTLIGHT_STEP $root"
    else
      printf '%s\t%s\n' 0 "Spotlight returns no hits under $root"
    fi
  fi
  codex="${CODEX_HOME:-$user_home/.codex}/worktrees"
  count=0
  [ ! -d "$codex" ] || count="$(find "$codex" -mindepth 1 -maxdepth 1 2>/dev/null | grep -c . || true)"
  if [ "$count" -gt 0 ]; then
    printf '%s\t%s\n' 2 "$count entr(ies) under $codex: in the Codex app set Settings > Worktrees > Worktree root to $root/_codex, then run: trellis worktree migrate"
  fi
  cursor="$user_home/.cursor/worktrees"
  if [ -d "$cursor" ]; then
    printf '%s\t%s\n' 2 "$cursor exists: Cursor's cleanup keeps 25 worktrees and can delete ones it did not create; never point Cursor at $root"
  fi
  return 0
}
