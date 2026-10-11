#!/usr/bin/env bash
# Engine resolution the scanned tree cannot steer. Sourced (not run) by
# run-diff.sh and lib/osv.sh, after each has dropped inherited shell functions.
#
# `type -P` alone trusts PATH as inherited: a relative entry resolves against
# the cwd, and a caller's PATH may already hold a directory inside the project
# (`.tools`, `node_modules/.bin`) where the range can commit a fake scanner.
#
#   sg_path_sanitize [<project-dir>]  rebuild PATH from absolute, existing
#       entries only, and drop every entry whose physical path is inside the
#       project. Without a project dir only the relative/empty entries go.
#   sg_resolve_engine <name> <project-dir>  print the engine's absolute path.
#       rc 1: not on PATH. rc 3: its real path (symlinks followed) is inside
#       the project, or a symlink cannot be followed.
#
# Symlinks are followed with the system readlink at a fixed path, never one
# found on PATH: a PATH readlink could vouch for the very link it is asked
# about. No system readlink means no symlinked engine can be verified.
SG_READLINK=""
for _sg_rl in /usr/bin/readlink /bin/readlink; do
  if [ -x "$_sg_rl" ]; then SG_READLINK="$_sg_rl"; break; fi
done
builtin unset _sg_rl

sg_physical_dir() {
  (builtin cd -P "$1" 2>/dev/null && builtin pwd -P)
}

# sg_inside <physical-path> <physical-dir>
sg_inside() {
  case "$1/" in "$2"/*) return 0 ;; esac
  return 1
}

sg_path_sanitize() {
  local root="" entry phys kept=""
  local -a entries=()
  if [ -n "${1:-}" ]; then
    root="$(sg_physical_dir "$1")" || return 1
  fi
  IFS=: builtin read -r -a entries <<<"$PATH"
  for entry in ${entries[@]+"${entries[@]}"}; do
    case "$entry" in /*) ;; *) continue ;; esac
    phys="$(sg_physical_dir "$entry")" || continue
    if [ -n "$root" ] && sg_inside "$phys" "$root"; then continue; fi
    kept="${kept:+$kept:}$entry"
  done
  PATH="$kept"
}

# sg_realpath <absolute-path>: follow every symlink, then canonicalize the dir.
sg_realpath() {
  local p="$1" link dir n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    [ -n "$SG_READLINK" ] || return 1
    link="$("$SG_READLINK" "$p")" || return 1
    case "$link" in /*) p="$link" ;; *) p="${p%/*}/$link" ;; esac
  done
  dir="$(sg_physical_dir "${p%/*}")" || return 1
  builtin printf '%s/%s\n' "$dir" "${p##*/}"
}

sg_resolve_engine() {
  local bin real root
  bin="$(builtin type -P "$1")" || return 1
  [ -n "$bin" ] || return 1
  root="$(sg_physical_dir "$2")" || return 3
  real="$(sg_realpath "$bin")" || return 3
  if sg_inside "$real" "$root"; then return 3; fi
  builtin printf '%s\n' "$bin"
}
