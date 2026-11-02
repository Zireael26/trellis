#!/usr/bin/env bash
# Copy a directory to a NEW pathname, preserving modes and symlinks, never
# sharing inodes. Clone/reflink extents are copy-on-write, not hardlinks.
fixture_clone() {
  local source="$1" destination="$2"
  [ -d "$source" ] && [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  cp -cRp "$source" "$destination" 2>/dev/null && return 0
  # A filesystem may reject cloning after creating part of the destination.
  fixture_clone_remove_partial "$destination" || return 1
  cp -Rp --reflink=auto "$source" "$destination" 2>/dev/null && return 0
  fixture_clone_remove_partial "$destination" || return 1
  cp -Rp "$source" "$destination"
}

fixture_clone_remove_partial() {
  [ -d "$1" ] || return 0
  find "$1" -type d -exec chmod u+w {} + || return 1
  rm -rf "$1"
}
