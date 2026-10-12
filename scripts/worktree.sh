#!/usr/bin/env bash
# Trellis worktree wrapper. Opted-in clones are attached from clone-local
# registry/release state before any harness has a chance to discover them;
# unregistered clones remain inert.
#
# Usage:
#   worktree.sh add <branch> [<start-point>] [--no-checkout]
#   worktree.sh add --detach [<commit-ish>] [--no-checkout]
#   worktree.sh sync [<path>]
#   worktree.sh root-init
#   worktree.sh migrate [--dry-run|--apply|--revert <journal>] [--json]
#   worktree.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
worktree.sh — Trellis worktree wrapper

Usage:
  worktree.sh add <branch> [<start-point>] [--no-checkout] [<path>]
  worktree.sh add --detach [<commit-ish>] [--no-checkout] [<path>]
      Create a worktree at the convention path
      <root>/<project>/<branch-slug> (root: worktrees.root, default
      ~/projects/worktrees; unregistered repos use _unregistered/<name>),
      then reconcile it from this clone's local Trellis registration and
      immutable release. An existing branch is checked out; a new one is
      created from <start-point> (default HEAD). A detached worktree is
      named detached-<shortsha>. A <path>, if given, must equal the
      convention path. Refuses (exit 3, nothing created) a target inside a
      git tree or a slug taken by another branch. Unregistered clones are
      otherwise unchanged.

  worktree.sh sync [<path>]
      Reconcile an existing worktree. Defaults to $PWD.

  worktree.sh root-init
      Create the central root (worktrees.root, default ~/projects/worktrees)
      with a .metadata_never_index marker and exclude it from Time Machine.
      Idempotent; exit 5 when tmutil is unavailable.

  worktree.sh migrate [--dry-run] [--json] [--only <path>]
      Plan the move of every linked worktree on this machine into the
      sanctioned roots: one row per worktree with its action and reasons.
      Read-only; see `migrate --help` for --apply and --revert.

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
    # Spec 069 A1: a worktree lands only at hy_convention_path,
    # <root>/<project>/<branch-slug>. Parse the new grammar; raw
    # `git worktree add` flags are refused rather than passed through.
    detach=0; defer_attachment=0; branch=""; start_point=""; explicit=""; npos=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --detach) detach=1 ;;
        --no-checkout) defer_attachment=1 ;;
        --checkout) defer_attachment=0 ;;
        -b|-b?*|-B|-B?*|--reason|--reason=*)
          echo "error: 'add' no longer takes git worktree flags ($1); use: trellis worktree add <branch> [<start-point>]" >&2
          exit 2 ;;
        -*)
          echo "error: unknown option for 'add': $1" >&2
          usage >&2
          exit 2 ;;
        /*|./*|../*|\~|\~/*)
          if [ -n "$explicit" ]; then
            echo "error: 'add' takes at most one path" >&2
            exit 2
          fi
          explicit="$1" ;;
        *)
          npos=$((npos + 1))
          case "$npos" in
            1) branch="$1" ;;
            2) start_point="$1" ;;
            *) echo "error: unexpected argument for 'add': $1" >&2; usage >&2; exit 2 ;;
          esac ;;
      esac
      shift
    done
    if [ "$detach" -eq 1 ]; then
      # --detach takes a commit-ish (default HEAD), never a start point.
      if [ -n "$start_point" ]; then
        echo "error: 'add --detach' takes one commit-ish" >&2
        exit 2
      fi
      start_point="${branch:-HEAD}"; branch=""
    elif [ -z "$branch" ]; then
      echo "error: 'add' requires a branch (or --detach)" >&2
      usage >&2
      exit 2
    fi

    # shellcheck source=lib/hygiene-common.sh
    . "$SCRIPT_DIR/lib/hygiene-common.sh"
    git rev-parse --show-toplevel >/dev/null 2>&1 || {
      echo "error: 'add' must run inside a git worktree of the repository" >&2
      exit 2
    }
    new_branch=""
    if [ "$detach" -eq 1 ]; then
      sha="$(git rev-parse --verify -q "$start_point^{commit}")" || {
        echo "error: not a commit: $start_point" >&2
        exit 2
      }
      wt_path="$(hy_convention_path "$PWD" --detached "$sha")" && rc=0 || rc=$?
    else
      git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
        echo "error: not a valid branch name: $branch" >&2
        exit 2
      }
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        if [ -n "$start_point" ]; then
          echo "error: branch '$branch' already exists; a start point applies only to a new branch" >&2
          exit 2
        fi
      elif ! { [ -z "$start_point" ] && git show-ref --verify --quiet "refs/remotes/origin/$branch"; }; then
        # A remote-only branch is left to git's tracking DWIM; anything else
        # is a new branch whose creation base is recorded below.
        new_branch="$branch"
      fi
      wt_path="$(hy_convention_path "$PWD" "$branch")" && rc=0 || rc=$?
    fi
    case "$rc" in
      0) ;;
      3)
        if [ -n "$wt_path" ]; then
          echo "error: slug collision: $wt_path is already taken by another branch, clone or file; pick another branch name" >&2
        else
          echo "error: more than one registered project claims this repository" >&2
        fi
        exit 3 ;;
      *)
        echo "error: could not compute the convention path (hygiene status $rc)" >&2
        exit "$rc" ;;
    esac
    if [ -n "$explicit" ]; then
      case "$explicit" in
        \~) explicit="$HOME" ;;
        \~/*) explicit="$HOME/${explicit#\~/}" ;;
        /*) ;;
        *) explicit="$PWD/$explicit" ;;
      esac
      explicit_dir="$(_hy_canon "$explicit")" || explicit_dir="$explicit"
      if [ "$explicit_dir" != "$wt_path" ]; then
        echo "error: refusing $explicit: worktrees are created only at the convention path $wt_path" >&2
        exit 3
      fi
    fi
    if [ -e "$wt_path" ]; then
      echo "error: a worktree for this branch already exists: $wt_path" >&2
      exit 3
    fi
    if enclosing="$(hy_inside_git_tree "$wt_path")"; then
      echo "error: refusing $wt_path: it is inside the git tree at $enclosing; set worktrees.root outside any repository" >&2
      exit 3
    fi

    # Read-only group-plan check: never leave a branch/tree for a predictable
    # shared-exclude refusal. No-checkout remains deliberately deferred.
    if [ "$defer_attachment" -eq 0 ]; then
      "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$PWD" --pre-add --quiet
    fi

    creation_parent="$(git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse --verify HEAD 2>/dev/null || true)"
    git_args=()
    [ "$defer_attachment" -eq 0 ] || git_args+=(--no-checkout)
    if [ "$detach" -eq 1 ]; then
      git_args+=(--detach "$wt_path" "$sha")
    elif [ -n "$new_branch" ]; then
      git_args+=(-b "$new_branch" "$wt_path")
      [ -z "$start_point" ] || git_args+=("$start_point")
    else
      git_args+=("$wt_path" "$branch")
    fi
    project_dir="$(dirname "$wt_path")"
    project_dir_created=0
    if [ ! -d "$project_dir" ]; then
      mkdir -p "$project_dir"
      project_dir_created=1
    fi
    git worktree add "${git_args[@]}" || {
      rc=$?
      [ "$project_dir_created" -eq 0 ] || rmdir "$project_dir" 2>/dev/null || true
      exit "$rc"
    }

    # The dispatcher does not run for --no-checkout. Preserve any record it
    # already wrote, and record the literal start point in the common config.
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

  migrate)
    shift
    # shellcheck source=lib/hygiene-common.sh
    . "$SCRIPT_DIR/lib/hygiene-common.sh"
    # shellcheck source=lib/disk-janitor-lib.sh
    . "$SCRIPT_DIR/lib/disk-janitor-lib.sh"
    # shellcheck source=lib/worktree-migrate.sh
    . "$SCRIPT_DIR/lib/worktree-migrate.sh"
    wm_main "$@"
    ;;

  root-init)
    shift
    [ $# -eq 0 ] || { echo "error: 'root-init' takes no arguments" >&2; exit 2; }
    # shellcheck source=lib/worktree-layout.sh
    . "$SCRIPT_DIR/lib/worktree-layout.sh"
    wl_root_init "$HOME"
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
