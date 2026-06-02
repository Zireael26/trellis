#!/usr/bin/env bash
# sync-coverage.sh — pure, sourceable helper for the public-mirror sync.
#
# Purpose: fail-closed completeness pre-flight for core-rules/ subdirs. The
# sync's SYNC_PATHS is a positive allowlist with no completeness check, so a
# newly-added core-rules/<name>/ can be silently dropped from the public
# template (the PR #78 failure class: core-rules/githooks/ was missing from
# SYNC_PATHS and the mirror silently lacked a new git hook). This helper lets
# the caller assert every core-rules/*/ subdir is explicitly classified as
# either "published" (in SYNC_PATHS) or "intentionally private" (in the
# exclude register) before any work happens.
#
# Read/write contract:
#   READS  — only the filesystem under <source_root>/core-rules/ (directory
#            listing via glob; no file contents). Treats the two list strings
#            as inert text; does not read any other path.
#   WRITES — nothing. Prints uncovered subdir paths to stdout only. Sets no
#            global variables, mutates no shell state, touches no files.
#   This file intentionally does NOT set shell options (no `set -euo
#   pipefail`): sourcing it must not alter the caller's / test harness's
#   shell. The function is self-contained and `set -e`-safe on its own — every
#   match runs inside an `if` condition and it ends with `return $rc`.

# check_core_rules_coverage <source_root> <sync_paths_newline> <exclude_newline>
#   source_root        : absolute path to the live clone root
#   sync_paths_newline : the SYNC_PATHS entries, newline-separated (one per line)
#   exclude_newline    : the bare exclude names, newline-separated (one per line)
# Prints each uncovered "core-rules/<name>/" subdir to stdout, one per line.
# Returns 0 if all core-rules/*/ subdirs are covered, 1 if any are uncovered.
check_core_rules_coverage() {
  # All function-scoped (no caller mutation). Plain `local` is bash-3.2-safe;
  # only `local -n` namerefs are banned. Assigning from positionals/literals
  # avoids SC2155 (which fires only on `local x="$(cmd)"`).
  local source_root sync_paths_newline exclude_newline rc dir name
  source_root="$1"
  sync_paths_newline="$2"
  exclude_newline="$3"

  rc=0
  for dir in "$source_root"/core-rules/*/; do
    # Skip if the glob didn't expand or isn't a directory.
    [ -d "$dir" ] || continue

    # Basename of the subdir via parameter expansion (no subshell → no SC2155).
    name="${dir%/}"
    name="${name##*/}"

    # COVERED if SYNC_PATHS has an exact line for core-rules/<name> or
    # core-rules/<name>/ (trailing slash optional — match both).
    if printf '%s\n' "$sync_paths_newline" | grep -qxF "core-rules/$name"; then
      continue
    fi
    if printf '%s\n' "$sync_paths_newline" | grep -qxF "core-rules/$name/"; then
      continue
    fi

    # COVERED if the exclude register has an exact line for the bare basename.
    if printf '%s\n' "$exclude_newline" | grep -qxF "$name"; then
      continue
    fi

    # Otherwise UNCOVERED.
    printf '%s\n' "core-rules/$name/"
    rc=1
  done

  return $rc
}
