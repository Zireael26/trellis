#!/usr/bin/env bash
# Trellis worktree wrapper. Opted-in clones are attached from clone-local
# registry/release state before any harness has a chance to discover them;
# unregistered clones remain inert.
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
      Create a worktree, then reconcile it from this clone's local Trellis
      registration and immutable release. Unregistered clones are unchanged.

  worktree.sh sync [<path>]
      Reconcile an existing worktree. Defaults to $PWD.

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

    # `--no-checkout` deliberately leaves the new worktree without its tracked
    # manifest. Its common-dir post-checkout dispatcher reconciles the
    # attachment after the first real checkout, when the manifest exists.
    defer_attachment=0
    for arg in "$@"; do
      case "$arg" in
        --no-checkout) defer_attachment=1 ;;
        --checkout) defer_attachment=0 ;;
      esac
    done

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
    if [ "$defer_attachment" -eq 1 ]; then
      echo "worktree created without checkout; Trellis attachment will reconcile on first checkout: $abs"
    else
      "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$abs"
      echo "worktree ready: $abs"
    fi
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
