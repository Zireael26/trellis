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

    # Read-only group-plan check: never leave a branch/tree for a predictable
    # shared-exclude refusal. No-checkout remains deliberately deferred.
    if [ "$defer_attachment" -eq 0 ]; then
      "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$PWD" --pre-add --quiet
    fi

    # Run git worktree add with ALL original args passed through verbatim.
    # set -e means: if git fails, we exit here and the seeder never runs.
    creation_parent="$(git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse --verify HEAD 2>/dev/null || true)"
    git worktree add "$@"
    # Now locate the worktree path from the (already-validated) arg list.
    # Convention: the FIRST non-flag positional is the worktree path, which
    # matches git's "git worktree add <path> [<commit-ish>]" signature.
    # Flags that consume a following value (-b/-B/--reason) are skipped so we
    # don't accidentally pick up the branch name as the path.
    wt_path=""
    new_branch=""
    start_point=""
    end_options=0
    while [ $# -gt 0 ]; do
      if [ "$end_options" -eq 0 ]; then
        case "$1" in
          --) end_options=1; shift; continue ;;
          -b) new_branch="$2"; shift 2; continue ;;
          -b?*) new_branch="${1#-b}"; shift; continue ;;
          -B|--reason) shift 2; continue ;;
          -*) shift; continue ;;
        esac
      fi
      if [ -z "$wt_path" ]; then wt_path="$1"; else start_point="$1"; fi
      shift
    done

    # The dispatcher does not run for --no-checkout. Preserve any record it
    # already wrote, and record the literal -b start point in the common config.
    if [ -n "$new_branch" ]; then
      if [ -n "$start_point" ] && [ "$start_point" != HEAD ]; then creation_parent="$start_point"; fi
      if ! git config --local --get "branch.$new_branch.trellisParent" >/dev/null 2>&1; then
        if [ -n "$creation_parent" ] &&
           creation_base="$(git rev-parse --verify "$new_branch^{commit}" 2>/dev/null)" &&
           git config --local "branch.$new_branch.trellisBase" "$creation_base" &&
           git config --local "branch.$new_branch.trellisSource" worktree &&
           git config --local "branch.$new_branch.trellisParent" "$creation_parent"; then
          :
        else
          echo "trellis worktree: warning: could not record branch creation base; use diff-base.sh set <parent>." >&2
        fi
      fi
    fi

    if [ -z "$wt_path" ]; then
      echo "error: could not locate worktree path in args — was it a flag-only invocation?" >&2
      exit 1
    fi

    abs="$(cd "$wt_path" && pwd -P)"
    if [ "$defer_attachment" -eq 1 ]; then
      echo "worktree created without checkout; Trellis attachment will reconcile on first checkout: $abs"
    else
      # Git silently skips a missing or drifted post-checkout dispatcher. The
      # fast path needs both its runtime link and its committed owner record;
      # otherwise retry the full seed (which is inert for unregistered clones).
      needs_seed=1
      if [ -L "$abs/.trellis/runtime" ] && [ -e "$abs/.trellis/runtime" ]; then
        . "$SCRIPT_DIR/lib/trellis-home.sh"
        . "$SCRIPT_DIR/lib/local-registry.sh"
        home="$(trellis_home_resolve "")"
        identity="$(local_registry_identity_for_root "$abs")"
        checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
        worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
        owner="$home/state/attachments/$checkout/$worktree.json"
        if [ -f "$owner" ] && [ ! -L "$owner" ]; then needs_seed=0; fi
      fi
      if [ "$needs_seed" -eq 1 ]; then
        "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$abs" --quiet
      fi
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
