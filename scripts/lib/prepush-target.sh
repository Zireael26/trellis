#!/usr/bin/env bash
# prepush-target.sh — pure, sourceable helper for sync-merge-gate.sh.
#
# Purpose: decide WHERE a project's pre-push hook lives and WHICH canonical
# source feeds it, accounting for the three install shapes Trellis projects use
# (husky/Node, native core.hooksPath in-repo dir, and per-clone .git/hooks) plus
# the clusterbid misconfig (hooksPath pointing at .git/hooks while a tracked
# .githooks/ also exists). Extracting the branchy decision as a pure function is
# the only sane way to unit-test the misconfig path without git-push machinery
# (mirrors sync-coverage.sh / sync-coverage.bats).
#
# Read/write contract:
#   READS  — the project's filesystem layout (.husky/, tracked dirs) and its git
#            config core.hooksPath, via `git -C <proj>` only. No file contents.
#   WRITES — nothing. Prints a single line "ACTION\tTARGET\tSOURCE_KIND" to
#            stdout and returns 0, OR prints "WARN\t<reason>" and returns 0 when
#            the install is ambiguous (caller turns that into a skip). Sets no
#            global variables, touches no files, changes no git config.
#   This file intentionally does NOT set `set -euo pipefail`: sourcing it must
#   not alter the caller's / test harness's shell.
#
# Output protocol (tab-separated, first field is the verb):
#   WRITE\t<absolute target path>\t<husky|githooks>
#       -> caller sha-compares against the named canonical source and overwrites.
#   WARN\t<human-readable reason>
#       -> caller prints the warning and SKIPS (operator must resolve intent).
# SOURCE_KIND maps to: husky -> core-rules/husky/pre-push,
#                      githooks -> core-rules/githooks/pre-push.

# resolve_prepush_target <project_dir>
#   project_dir : absolute path to the project working tree
# Prints one tab-separated line per the output protocol above. Returns 0.
resolve_prepush_target() {
  local proj hooks_path toplevel
  proj="$1"

  # 1. Husky/Node: .husky/ present -> husky carrier.
  if [ -d "$proj/.husky" ]; then
    printf 'WRITE\t%s\t%s\n' "$proj/.husky/pre-push" "husky"
    return 0
  fi

  # Resolve the project's worktree root once for inside/outside checks.
  toplevel="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null || true)"

  # 2. Native: core.hooksPath set.
  hooks_path="$(git -C "$proj" config core.hooksPath 2>/dev/null || true)"
  if [ -n "$hooks_path" ]; then
    # Normalize to an absolute path. A relative hooksPath is resolved against
    # the worktree root (git's own interpretation).
    local abs_hooks
    case "$hooks_path" in
      /*) abs_hooks="$hooks_path" ;;
      *)  abs_hooks="${toplevel:-$proj}/$hooks_path" ;;
    esac

    # Misconfig A (the clusterbid case): hooksPath resolves to the per-clone
    # .git/hooks (inside the worktree, so the outside-check below won't catch
    # it) WHILE a tracked .githooks/ ALSO exists. The intent is ambiguous — the
    # operator pinned hooksPath at the untracked per-clone dir but ships a
    # tracked native hooks dir. Do NOT silently write; WARN + skip.
    case "$abs_hooks" in
      */.git/hooks|*/.git/hooks/)
        if git -C "$proj" ls-files --error-unmatch .githooks >/dev/null 2>&1 \
           || [ -n "$(git -C "$proj" ls-files .githooks 2>/dev/null)" ]; then
          printf 'WARN\t%s\n' "core.hooksPath=$hooks_path points at per-clone .git/hooks but a tracked .githooks/ exists; resolve the hooksPath intent before syncing"
          return 0
        fi
        ;;
    esac

    # Misconfig B: hooksPath resolves OUTSIDE the worktree (absolute external
    # dir). Not a place we own; WARN + skip so the operator resolves intent.
    if [ -n "$toplevel" ]; then
      case "$abs_hooks/" in
        "$toplevel"/*) : ;;  # inside the worktree — fine
        *)
          printf 'WARN\t%s\n' "core.hooksPath=$hooks_path resolves outside the worktree ($abs_hooks); not syncing"
          return 0
          ;;
      esac
    fi

    # In-repo native hooks dir (tracked, e.g. .githooks) -> native carrier.
    printf 'WRITE\t%s\t%s\n' "$abs_hooks/pre-push" "githooks"
    return 0
  fi

  # 3. No husky, no hooksPath -> per-clone .git/hooks (native source).
  printf 'WRITE\t%s\t%s\n' "$proj/.git/hooks/pre-push" "githooks"
  return 0
}
