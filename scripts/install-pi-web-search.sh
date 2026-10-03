#!/usr/bin/env bash
# Install or remove the pi web-search extension (spec 056 R14).
#
#   install-pi-web-search.sh [--home H] install <src>
#   install-pi-web-search.sh [--home H] remove
#
# install copies <src> into a private snapshot first, then hashes, checks and
# installs that same snapshot, so a source swapped after the check cannot be
# installed. It refuses a snapshot whose sha256 is on the block list
# (core-rules/pi/extensions/trellis-web-search.blocked.sha256, compared
# case-insensitively). Any existing live file, including a dangling symlink,
# is moved to H/.pi/agent/backups/extensions/, which must resolve outside the
# extensions directory pi loads from. The snapshot is installed with mode 0644
# and the installed file's digest must equal the vetted digest, or it is
# removed and the install fails. remove moves the live file to the same
# backups directory and installs nothing, which is the fail-closed rollback:
# search is absent, not reverted.
#
# Directories are pinned, not re-resolved. Each directory is vetted as a real,
# non-symlink directory and its physical path recorded; every mutating step
# then runs with that directory as the working directory (`cd -P`), uses a
# relative name on the side it pins, and first re-checks that `pwd -P` still
# equals the vetted path. The install write and the backup's source are
# pinned this way; the backup's destination is re-vetted just before the move
# and the backup is verified afterwards (see move_live_aside). A directory
# swapped after vetting is therefore refused, or the operation lands in the
# vetted directory itself, never through a new symlink.
#
# Residual risk, stated plainly: this protects against mistakes and against
# other users, not against a same-UID attacker who can already write to
# ~/.pi. Such an attacker can edit the live extension directly, so racing the
# installer gains nothing, and defending against it is out of scope. The one
# unpinned instant (a backups swap between its final re-vet and the move) is
# only reachable by that attacker.
#
# H defaults to $HOME. TWS_BLOCKED_LIST overrides the block list path; the Bats
# suite uses it to test refusal without shipping a blocked build as a fixture.

set -euo pipefail

usage() {
  echo "usage: install-pi-web-search.sh [--home H] install <src> | remove" >&2
  exit 2
}
refuse() {
  echo "install-pi-web-search: refused: $*" >&2
  exit 4
}

repo="$(cd "$(dirname "$0")/.." && pwd -P)"
blocked_list="${TWS_BLOCKED_LIST:-$repo/core-rules/pi/extensions/trellis-web-search.blocked.sha256}"
home="$HOME"
if [ "${1:-}" = "--home" ]; then
  [ $# -ge 2 ] || usage
  home="$2"
  shift 2
fi
command="${1:-}"
[ -n "$command" ] || usage

name="trellis-web-search.ts"
agent="$home/.pi/agent"
extensions="$agent/extensions"
backups_root="$agent/backups"
backups="$backups_root/extensions"

if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print tolower($1)}'; }
else
  echo "install-pi-web-search: neither shasum nor sha256sum is available" >&2
  exit 2
fi

# vet <dir>: prints the physical path of a real, non-symlink directory.
vet() {
  [ -L "$1" ] && refuse "$1 is a symlink"
  [ -d "$1" ] || refuse "$1 is not a directory"
  (cd -P "$1" && pwd -P)
}

# enter <vetted-path>: cd into a vetted directory and confirm it is still the
# same physical path. Runs before every mutating step.
enter() {
  cd -P "$1" || refuse "cannot enter $1"
  [ "$(pwd -P)" = "$1" ] || refuse "$1 changed after it was vetted"
}

ext_real=""
backups_real=""
vet_layout() {
  [ -L "$backups_root" ] && refuse "$backups_root is a symlink"
  ext_real="$(vet "$extensions")"
  if [ -e "$backups" ] || [ -L "$backups" ]; then
    backups_real="$(vet "$backups")"
    case "$backups_real/" in
      "$ext_real/"*) refuse "backups directory $backups resolves inside $extensions" ;;
    esac
  fi
  return 0
}

# Describes the live file for the receipt without following a symlink. Runs
# with the extensions directory as the working directory.
describe_live() {
  if [ -L "$name" ]; then
    echo "symlink -> $(readlink "$name")"
  else
    sha256 "$name"
  fi
}

# Moves the live file (or symlink, dangling or not) into backups under a
# UTC-stamped name that never overwrites an earlier backup.
#
# The source side is pinned: the move runs from inside the vetted extensions
# directory with a relative source name, so an extensions/ swap cannot
# redirect what is moved. The destination is the vetted backups path, re-vetted
# (real directory, same physical path, outside extensions/) immediately before
# the move, and the result is verified from inside the re-entered backups
# directory; a missing or wrong-type backup fails closed (exit 5). What remains
# is the instant between that last re-vet and the move itself: a swap of the
# backups directory exactly then is the same-UID residual stated in the header.
move_live_aside() {
  enter "$ext_real"
  if [ ! -e "$name" ] && [ ! -L "$name" ]; then
    echo "before: none $extensions/$name"
    return 0
  fi
  echo "before: $(describe_live) $extensions/$name"
  if [ -z "$backups_real" ]; then
    mkdir -p "$backups"
    vet_layout
  fi
  enter "$backups_real"
  local stamp target n=0 was_link=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$name.$stamp"
  while [ -e "$target" ] || [ -L "$target" ]; do
    n=$((n + 1))
    target="$name.$stamp.$n"
  done
  # Source side: from inside the pinned extensions directory.
  enter "$ext_real"
  if [ -L "./$name" ]; then
    was_link=1 # the link itself is moved (mv never follows it), dangling or not
  elif [ ! -f "./$name" ]; then
    refuse "$extensions/$name changed before the backup"
  fi
  # Destination side: re-vet the backups directory at the last moment.
  [ -L "$backups_real" ] && refuse "$backups changed after it was vetted"
  [ "$(cd -P "$backups_real" && pwd -P)" = "$backups_real" ] || refuse "$backups changed after it was vetted"
  mv -- "./$name" "$backups_real/$target"
  # Verify from inside the re-entered, re-checked backups directory.
  enter "$backups_real"
  if [ "$was_link" -eq 1 ]; then
    [ -L "./$target" ] || { echo "install-pi-web-search: backup $backups/$target is missing" >&2; exit 5; }
  else
    { [ -f "./$target" ] && [ ! -L "./$target" ]; } || { echo "install-pi-web-search: backup $backups/$target is missing or not a regular file" >&2; exit 5; }
  fi
  echo "backup: $backups/$target"
}

case "$command" in
  install)
    [ $# -eq 2 ] || usage
    src="$2"
    [ -f "$src" ] || { echo "install-pi-web-search: source is not a regular file: $src" >&2; exit 2; }
    [ -f "$blocked_list" ] || { echo "install-pi-web-search: block list missing: $blocked_list" >&2; exit 2; }
    # Snapshot first: every later step reads only this private copy.
    snapdir="$(mktemp -d "${TMPDIR:-/tmp}/install-pi-web-search.XXXXXX")"
    trap 'rm -rf "$snapdir"' EXIT
    chmod 0700 "$snapdir"
    snapshot="$snapdir/$name"
    cp "$src" "$snapshot"
    vetted="$(sha256 "$snapshot")"
    if awk '!/^#/ && NF { print tolower($1) }' "$blocked_list" | grep -qxF "$vetted"; then
      echo "install-pi-web-search: refused: $src is a blocked build (sha256 $vetted)" >&2
      exit 3
    fi
    [ -L "$extensions" ] && refuse "$extensions is a symlink"
    mkdir -p "$extensions"
    vet_layout
    move_live_aside
    # Write with the vetted extensions directory as the working directory.
    enter "$ext_real"
    if [ -e "$name" ] || [ -L "$name" ]; then refuse "$extensions/$name reappeared before install"; fi
    install -m 0644 "$snapshot" "./$name"
    installed="$(sha256 "./$name")"
    if [ "$installed" != "$vetted" ]; then
      rm -f "./$name"
      echo "install-pi-web-search: installed digest $installed does not match vetted digest $vetted; removed" >&2
      exit 5
    fi
    echo "after: $installed $extensions/$name"
    ;;
  remove)
    [ $# -eq 1 ] || usage
    [ -e "$extensions" ] || [ -L "$extensions" ] || { echo "before: none $extensions/$name"; echo "after: none (search extension removed)"; exit 0; }
    vet_layout
    move_live_aside
    echo "after: none (search extension removed)"
    ;;
  *)
    usage
    ;;
esac
