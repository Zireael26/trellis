#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'install-commit-hooks: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
  || fail 'could not resolve the script directory'
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)" \
  || fail 'could not resolve the repository root'

if [ "$#" -gt 1 ]; then
  fail 'expected zero or one destination directory argument'
fi

SOURCE_ROOT="${TRELLIS_HOOK_SOURCE_ROOT:-$REPO_ROOT/.husky}"
SOURCE_ROOT="$(CDPATH='' cd -- "$SOURCE_ROOT" && pwd -P)" \
  || fail "hook source directory is unavailable: ${TRELLIS_HOOK_SOURCE_ROOT:-$REPO_ROOT/.husky}"

for hook in commit-msg pre-commit; do
  source_path="$SOURCE_ROOT/$hook"
  [ -f "$source_path" ] || fail "required hook source is missing: $source_path"
  [ -r "$source_path" ] || fail "required hook source is unreadable: $source_path"
done

if [ "$#" -eq 1 ]; then
  destination="$1"
  case "$destination" in
    /*) ;;
    *)
      current_directory="$(CDPATH='' pwd -P)" \
        || fail 'could not resolve the current directory'
      destination="$current_directory/$destination"
      ;;
  esac
else
  git_hooks_path="$(git -C "$REPO_ROOT" rev-parse --git-path hooks 2>/dev/null)" \
    || fail 'could not resolve the Git hooks directory'
  git_common_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" \
    || fail 'could not resolve the Git common directory'
  git_dir="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null)" \
    || fail 'could not resolve the Git directory'
  show_toplevel="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || fail 'could not resolve the Git worktree root'

  [ -n "$git_hooks_path" ] || fail 'Git returned an empty hooks directory'
  [ -n "$git_common_dir" ] || fail 'Git returned an empty common directory'
  [ -n "$git_dir" ] || fail 'Git returned an empty Git directory'
  [ -n "$show_toplevel" ] || fail 'Git returned an empty worktree root'

  case "$git_hooks_path" in
    /*) destination="$git_hooks_path" ;;
    *) destination="$REPO_ROOT/$git_hooks_path" ;;
  esac
  case "$git_common_dir" in
    /*) ;;
    *) git_common_dir="$REPO_ROOT/$git_common_dir" ;;
  esac
  case "$git_dir" in
    /*) ;;
    *) git_dir="$REPO_ROOT/$git_dir" ;;
  esac
  case "$show_toplevel" in
    /*) ;;
    *) show_toplevel="$REPO_ROOT/$show_toplevel" ;;
  esac

  git_common_dir="$(CDPATH='' cd -- "$git_common_dir" && pwd -P)" \
    || fail 'could not resolve the Git common directory'
  git_dir="$(CDPATH='' cd -- "$git_dir" && pwd -P)" \
    || fail 'could not resolve the Git directory'
  show_toplevel="$(CDPATH='' cd -- "$show_toplevel" && pwd -P)" \
    || fail 'could not resolve the Git worktree root'
fi

printf 'install-commit-hooks: destination: %s\n' "$destination"

if [ "$#" -eq 0 ]; then
  destination_contained=1
  case "$destination" in
    "$show_toplevel"|"$show_toplevel"/*) destination_contained=0 ;;
  esac

  if [ "$git_dir" != "$git_common_dir" ] || [ "$destination_contained" -ne 0 ]; then
    fail "refusing hooks destination '$destination' for current worktree '$show_toplevel'; rerun from the main checkout or pass an explicit destination"
  fi
fi

mkdir -p "$destination"
for hook in commit-msg pre-commit; do
  cp "$SOURCE_ROOT/$hook" "$destination/$hook"
  chmod 755 "$destination/$hook"
  printf 'installed %s\n' "$destination/$hook"
done
