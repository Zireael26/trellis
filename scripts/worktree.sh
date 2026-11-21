#!/usr/bin/env bash
# Trellis worktree wrapper. Opted-in clones are attached from clone-local
# registry/release state before any harness has a chance to discover them;
# unregistered clones remain inert.
#
# Usage:
#   worktree.sh add <branch> [<start-point>] [--no-checkout]
#   worktree.sh add --detach [<commit-ish>] [--no-checkout]
#   worktree.sh launch --harness <claude|codex|pi|antigravity|opencode> [--reuse] [--print-cmd] <branch> [<start-point>]
#   worktree.sh sync [<path>]
#   worktree.sh root-init
#   worktree.sh migrate [--dry-run|--apply|--revert <journal>] [--json]
#   worktree.sh --help

set -euo pipefail

# Reconcile children run in fresh shells, not the caller's preloaded bundle.
unset TRELLIS_LIBS_PRELOADED

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
worktree.sh — Trellis worktree wrapper

Usage:
  worktree.sh add <branch> [<start-point>] [--no-checkout] [<path>] [--cow-deps | --no-cow-deps]
  worktree.sh add --detach [<commit-ish>] [--no-checkout] [<path>] [--cow-deps | --no-cow-deps]
      Create a worktree at the convention path
      <root>/<project>/<branch-slug> (root: worktrees.root, default
      ~/projects/worktrees; unregistered repos use _unregistered/<name>),
      then reconcile it from this clone's local Trellis registration and
      immutable release. An existing branch is checked out; a new one is
      created from <start-point> (default HEAD). A detached worktree is
      named detached-<shortsha>. A <path>, if given, must equal the
      convention path. Opt-in --cow-deps (or worktrees.cow_deps:true,
      default false) CoW-clones node_modules/.venv from the source checkout
      on the same APFS device via /bin/cp -Rc; fail-soft on copy failure. Refuses (exit 3, nothing created) a target inside a
      git tree or a slug taken by another branch. Unregistered clones are
      otherwise unchanged.

  worktree.sh launch --harness <claude|codex|pi|antigravity|opencode> [--reuse] [--print-cmd] <branch> [<start-point>]
      Create (or --reuse an existing) convention worktree under
      <root>/<project>/<branch-slug>, reconcile Trellis attachment, and
      start an interactive session of the selected harness in that directory
      (never -p/print mode). With --print-cmd (or no TTY), prints the
      worktree path and interactive launch command instead of exec'ing.

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
    detach=0; defer_attachment=0; branch=""; start_point=""; explicit=""; npos=0; cow_deps="" 
    while [ $# -gt 0 ]; do
      case "$1" in
        --detach) detach=1 ;;
        --no-checkout) defer_attachment=1 ;;
        --checkout) defer_attachment=0 ;;
        --cow-deps) cow_deps=1 ;;
        --no-cow-deps) cow_deps=0 ;;
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

    # Spotlight exclusion + TRELLIS_HOME marker (Darwin best-effort; never
    # fails the add when unwritable).
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
      _hy_root_mark="$(hy_root 2>/dev/null || echo '')"
      [ -z "$_hy_root_mark" ] || [ ! -d "$_hy_root_mark" ] || : >"$_hy_root_mark/.metadata_never_index" 2>/dev/null || true
      [ -z "${TRELLIS_HOME:-}" ] || [ ! -d "$TRELLIS_HOME" ] || : >"$TRELLIS_HOME/.metadata_never_index" 2>/dev/null || true
    fi

    # Opt-in APFS Copy-on-Write dependency hydration (--cow-deps or
    # worktrees.cow_deps:true, default false). On Darwin only, when the
    # source checkout and the new worktree share one APFS device
    # (stat -f %d) and the same lockfile contents, CoW-clone node_modules /
    # .venv via /bin/cp -Rc (clonefile(2): <1s, ~0 extra bytes). Fail-soft:
    # any copy failure cleans the partial target and logs a notice.
    if [ -z "$cow_deps" ] && [ -n "${TRELLIS_CONFIG_PATH:-}" ] && [ -r "$TRELLIS_CONFIG_PATH" ]; then
      case "$(jq -r '.worktrees.cow_deps // empty' "$TRELLIS_CONFIG_PATH" 2>/dev/null)" in
        true) cow_deps=1 ;; false) cow_deps=0 ;; *) cow_deps=0 ;;
      esac
    fi
    [ -n "$cow_deps" ] || cow_deps=0
    if [ "$cow_deps" -eq 1 ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
      _cow_src="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
      if [ -n "$_cow_src" ] && [ -d "$wt_path" ]; then
        _cow_dev_src=""
        _cow_dev_dst=""
        _cow_dev_src="$(stat -f %d "$_cow_src" 2>/dev/null)" || _cow_dev_src=""
        _cow_dev_dst="$(stat -f %d "$wt_path" 2>/dev/null)" || _cow_dev_dst=""
        if [ -n "$_cow_dev_src" ] && [ "$_cow_dev_src" = "$_cow_dev_dst" ]; then
          # Clone node_modules only when a JS lockfile matches byte-for-byte.
          # Python .venv is intentionally excluded: cloning it duplicates
          # source-checkout shebangs and editable .pth paths (`uv sync` already
          # hardlinks/clones from the uv cache with worktree-local paths).
          for _cow_lock in pnpm-lock.yaml package-lock.json yarn.lock bun.lock bun.lockb; do
            if [ -f "$_cow_src/$_cow_lock" ] && [ -f "$wt_path/$_cow_lock" ] && cmp -s "$_cow_src/$_cow_lock" "$wt_path/$_cow_lock" 2>/dev/null; then
              if [ -d "$_cow_src/node_modules" ] && [ ! -e "$wt_path/node_modules" ]; then
                if /bin/cp -Rc "$_cow_src/node_modules" "$wt_path/node_modules" 2>/dev/null; then
                  echo "trellis worktree: CoW-cloned node_modules from source checkout (APFS clonefile, ~0 extra bytes)" >&2
                else
                  rm -rf -- "${wt_path:?}/node_modules" 2>/dev/null || true
                  echo "trellis worktree: notice: --cow-deps copy of node_modules failed; left for the package manager to populate" >&2
                fi
              fi
              break
            fi
          done
        else
          echo "trellis worktree: notice: --cow-deps skipped (source and worktree are on different devices)" >&2
        fi
      fi
    elif [ "$cow_deps" -eq 1 ]; then
      echo "trellis worktree: notice: --cow-deps is Darwin/APFS-only; skipped on this platform" >&2
    fi

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
      # Git silently skips a missing or drifted post-checkout dispatcher. An
      # owner record that merely exists is not readiness (spec 074 T48): with a
      # runtime link, the canonical read-only verify must pass (committed
      # owner, exact artifacts, anchor); otherwise retry the full seed, which
      # returns 0 only once ready and is inert for unregistered clones.
      needs_seed=1
      if [ -L "$abs/.trellis/runtime" ] && [ -e "$abs/.trellis/runtime" ] &&
         "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$abs" --verify-only --quiet >/dev/null 2>&1; then
        needs_seed=0
      fi
      if [ "$needs_seed" -eq 1 ]; then
        "$SCRIPT_DIR/seed-inheritance-symlinks.sh" --target "$abs" --quiet || {
          rc=$?
          echo "error: worktree created but not ready: $abs; remedy: trellis worktree sync $abs" >&2
          exit "$rc"
        }
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

  launch)
    shift
    harness=""; reuse=0; print_cmd=0; branch=""; start_point=""; npos=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --harness)
          [ $# -ge 2 ] || { echo "error: --harness requires a value" >&2; exit 2; }
          harness="$2"; shift ;;
        --harness=*)
          harness="${1#--harness=}" ;;
        --reuse)
          reuse=1 ;;
        --print-cmd|--no-exec)
          print_cmd=1 ;;
        -h|--help)
          usage; exit 0 ;;
        -*)
          echo "error: unknown option for 'launch': $1" >&2; usage >&2; exit 2 ;;
        *)
          npos=$((npos + 1))
          case "$npos" in
            1) branch="$1" ;;
            2) start_point="$1" ;;
            *) echo "error: unexpected argument for 'launch': $1" >&2; usage >&2; exit 2 ;;
          esac ;;
      esac
      shift
    done
    [ -n "$harness" ] || { echo "error: 'launch' requires --harness <claude|codex|pi|antigravity|opencode>" >&2; exit 2; }
    [ -n "$branch" ] || { echo "error: 'launch' requires <branch>" >&2; exit 2; }
    launch_argv=()
    case "$harness" in
      claude|claude-code) launch_argv=(claude) ;;
      codex)              launch_argv=(codex --no-daemon) ;;
      pi)                 launch_argv=(pi) ;;
      antigravity|agy)    launch_argv=(agy .) ;;
      opencode)           launch_argv=(opencode .) ;;
      *)
        echo "error: unsupported harness '$harness' (expected claude, codex, pi, antigravity, or opencode)" >&2
        exit 2 ;;
    esac
    # shellcheck source=lib/hygiene-common.sh
    . "$SCRIPT_DIR/lib/hygiene-common.sh"
    wt_path="$(hy_convention_path "$PWD" "$branch")" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "error: could not compute or reuse convention path for '$branch' (status $rc)" >&2
      exit "$rc"
    fi
    if [ -d "$wt_path" ]; then
      if [ "$reuse" -eq 0 ]; then
        echo "error: worktree already exists at $wt_path (pass --reuse to reuse)" >&2
        exit 3
      fi
      "$0" sync "$wt_path" >/dev/null
      wt_abs="$(cd "$wt_path" && pwd -P)"
    else
      if [ -n "$start_point" ]; then
        "$0" add "$branch" "$start_point" >/dev/null
      else
        "$0" add "$branch" >/dev/null
      fi
      wt_abs="$(cd "$wt_path" && pwd -P)"
    fi
    if [ "$print_cmd" -eq 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
      printf 'worktree: %s\nlaunch: cd %q && exec' "$wt_abs" "$wt_abs"
      for arg in "${launch_argv[@]}"; do
        printf ' %q' "$arg"
      done
      printf '\n'
      exit 0
    fi
    command -v "${launch_argv[0]}" >/dev/null 2>&1 || {
      echo "error: harness binary '${launch_argv[0]}' not found on PATH" >&2
      exit 5
    }
    cd "$wt_abs"
    exec "${launch_argv[@]}"
    ;;

  "")
    usage; exit 0 ;;

  *)
    echo "error: unknown subcommand: $cmd" >&2
    usage >&2
    exit 2 ;;
esac
