#!/usr/bin/env bash
# Release stamp wrappers (spec 072 D-A, plan §3.1) around release_stamp.py.
#
# Public functions:
#   release_stamp_check <home> <release_dir>   0: the stamp proves the release
#                                              unchanged since a full verify
#   release_stamp_write <home> <release_dir>   0: stamped
#
# The pattern every caller follows:
#
#   if ! release_stamp_check "$home" "$release_dir"; then
#     <the existing full verify> || <refuse as today>
#     release_stamp_write "$home" "$release_dir" || :
#   fi
#
# A miss of any kind (changed, absent, unreadable, garbage, another digest,
# coarse ctime, no python3) means the full verify decides, exactly as before the stamp existed.
# A hit is exit 0 with the program's "hit" line, so an interpreter that exits 0
# without running the program (TRELLIS_PYTHON=/bin/true) is a miss too.
# check records the sweep it took before that verify, and write stamps only
# when a fresh sweep still equals it, so nothing that changed during the
# verify is stamped. A write failure only costs the next caller a full verify.
#
# Each call is one python3 -I process. A hit is memoized for the shell process
# that saw it and its subshells, keyed by `$$`, home and release dir; sourcing
# discards any inherited memo and it is never exported, so an exec'd or spawned
# child sweeps again. The TOCTOU window equals the verify-then-use window
# release-store.sh's memo already accepts.
#
# Bash 3.2 compatible; sourcing defines functions and resets the memo only.

_RELEASE_STAMP_PROGRAM="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/release_stamp.py"
unset _TRELLIS_RELEASE_STAMP_MEMO _TRELLIS_RELEASE_STAMP_PENDING
_TRELLIS_RELEASE_STAMP_MEMO=""
_TRELLIS_RELEASE_STAMP_PENDING=""

# An absolute, executable TRELLIS_PYTHON wins over a PATH lookup, so a caller
# PATH that leads with a version-manager shim costs no shim start per call.
_release_stamp_run() {
  local python_bin="${TRELLIS_PYTHON:-}"
  case "$python_bin" in /*) [ -x "$python_bin" ] || python_bin="" ;; *) python_bin="" ;; esac
  if [ -z "$python_bin" ]; then
    python_bin="$(command -v python3)" || return 1
    case "$python_bin" in /*) ;; *) return 1 ;; esac
  fi
  LC_ALL=C "$python_bin" -I "$_RELEASE_STAMP_PROGRAM" "$@" 2>/dev/null
}

release_stamp_check() {
  local tab=$'\t' key="" token=""
  key="$$$tab${1:-}$tab${2:-}"
  _TRELLIS_RELEASE_STAMP_PENDING=""
  case $'\n'"$_TRELLIS_RELEASE_STAMP_MEMO" in
    *$'\n'"$key"$'\n'*) return 0 ;;
  esac
  if token="$(_release_stamp_run check "${1:-}" "${2:-}")" && [ "$token" = hit ]; then
    _TRELLIS_RELEASE_STAMP_MEMO="$_TRELLIS_RELEASE_STAMP_MEMO$key"$'\n'
    return 0
  fi
  _TRELLIS_RELEASE_STAMP_PENDING="$key$tab$token"
  return 1
}

release_stamp_write() {
  local tab=$'\t' key="" pending="$_TRELLIS_RELEASE_STAMP_PENDING"
  key="$$$tab${1:-}$tab${2:-}"
  _TRELLIS_RELEASE_STAMP_PENDING=""
  [ "${pending%"$tab"*}" = "$key" ] || return 1
  _release_stamp_run write "${1:-}" "${2:-}" "${pending##*"$tab"}" >/dev/null || return 1
  _TRELLIS_RELEASE_STAMP_MEMO="$_TRELLIS_RELEASE_STAMP_MEMO$key"$'\n'
}
