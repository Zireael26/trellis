#!/usr/bin/env bash
# Trellis worktree wrapper — creates (or repairs) a git worktree and then
# seeds Trellis inheritance symlinks into it via seed-inheritance-symlinks.sh.
#
# Unlike the git post-checkout hook (dead on husky projects), this wrapper
# works on every project: just use `trellis worktree add` instead of
# `git worktree add`.
#
# Usage:
#   worktree.sh add <path> [extra git-worktree-add-args...]
#   worktree.sh sync [<path>]
#   worktree.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
worktree.sh — Trellis worktree wrapper

Usage:
  worktree.sh add <path> [git-worktree-add-args...]
      Create a new git worktree at <path> and seed Trellis inheritance
      symlinks into it. Extra args (e.g. -b <branch>) are passed through
      verbatim to git worktree add.

      NOTE: The FIRST non-flag positional argument is treated as the worktree
      path (matching git's own "git worktree add <path> [<commit-ish>]"
      convention). Flags that take a value (-b/-B/--reason) are skipped when
      locating the path.

  worktree.sh sync [<path>]
      Seed (or re-seed) Trellis inheritance symlinks into an existing worktree.
      Defaults to $PWD when <path> is omitted.

  worktree.sh --help
      Print this message and exit 0.
EOF
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  --help)
    usage; exit 0 ;;
  add)
    shift
    if [ $# -eq 0 ]; then
      echo "error: 'add' requires a path argument" >&2
      usage >&2
      exit 2
    fi

    # Run git worktree add with ALL original args passed through verbatim.
    # set -e means: if git fails, we exit here and the seeder never runs.
    git worktree add "$@"

    # Now locate the worktree path from the (already-validated) arg list.
    # Convention: the FIRST non-flag positional is the worktree path, which
    # matches git's "git worktree add <path> [<commit-ish>]" signature.
    # Flags that consume a following value (-b/-B/--reason) are skipped so we
    # don't accidentally pick up the branch name as the path.
    wt_path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -b|-B|--reason)
          shift 2 ;;   # safe: git already validated these succeeded
        -*)
          shift ;;
        *)
          wt_path="$1"; break ;;
      esac
    done

    if [ -z "$wt_path" ]; then
      echo "error: could not locate worktree path in args — was it a flag-only invocation?" >&2
      exit 1
    fi

    abs="$(cd "$wt_path" && pwd -P)"
    "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$abs"
    echo "worktree ready (inheritance seeded): $abs"
    ;;

  sync)
    shift
    target="${1:-$PWD}"
    "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$target"
    ;;

  "")
    usage; exit 0 ;;

  *)
    echo "error: unknown subcommand: $cmd" >&2
    usage >&2
    exit 2 ;;
esac
