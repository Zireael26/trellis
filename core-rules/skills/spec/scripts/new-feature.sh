#!/usr/bin/env bash
# Create a new feature spec scaffold inside the current project.
#
# Reads:
#   - $PWD: must be a git repo. Spec lands at <repo-root>/specs/<NNN>-<slug>/spec.md.
#   - Canonical template at <skill-dir>/references/spec-template.md (resolved
#     relative to this script so it works through symlinks).
#
# Writes:
#   - <repo-root>/specs/<NNN>-<slug>/ directory.
#   - <repo-root>/specs/<NNN>-<slug>/spec.md (template copy with slug + date filled).
#   - New branch feature/<slug>, checked out from the repo's default branch
#     (main or master), or --from <parent>. --no-branch skips branch creation.
#
# Refuses to run if:
#   - Working tree is dirty (any unstaged or untracked files).
#   - Current branch is not main/master (unless --from or --no-branch).
#   - spec.md already exists at the target path.
#
# Usage:
#   new-feature.sh <slug>                  # default: branch + spec
#   new-feature.sh <slug> --no-branch      # only create the directory; stay on current branch
#   new-feature.sh <slug> --from feature/a # stack on an explicit parent
#   new-feature.sh -h

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
# Resolve through a symlinked SKILL.md if present
if [ -L "$0" ]; then
  REAL="$(readlink -f "$0" 2>/dev/null || python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
  SCRIPT_DIR="$(cd "$(dirname "$REAL")" && pwd)"
fi
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SKILL_DIR/references/spec-template.md"

NO_BRANCH=false
SLUG=""
FROM=""

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --no-branch) NO_BRANCH=true ;;
    --from)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--from requires a parent ref" >&2
        exit 2
      fi
      FROM="$2"; shift ;;
    --from=*)
      FROM="${arg#--from=}"
      [ -n "$FROM" ] || { echo "--from requires a parent ref" >&2; exit 2; } ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
    *)
      if [ -z "$SLUG" ]; then
        SLUG="$arg"
      else
        echo "unexpected argument: $arg (slug already set to '$SLUG')" >&2
        exit 2
      fi
      ;;
  esac
  shift
done

if $NO_BRANCH && [ -n "$FROM" ]; then
  echo "--from cannot be combined with --no-branch" >&2
  exit 2
fi
if [ -z "$SLUG" ]; then
  echo "usage: new-feature.sh <slug> [--no-branch | --from <parent>]" >&2
  exit 2
fi

# Slug validation: kebab-case, alnum + dash, no leading/trailing dash, max 40
if ! echo "$SLUG" | grep -qE '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'; then
  echo "invalid slug: '$SLUG'" >&2
  echo "  must be kebab-case ([a-z0-9-]), 1-40 chars, no leading/trailing dash" >&2
  exit 2
fi

# Git sanity
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not inside a git work tree" >&2
  exit 1
fi
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Dirty-tree guard. Allow empty output from status --porcelain.
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  echo "working tree is dirty; commit/stash before scaffolding a spec." >&2
  git -C "$REPO_ROOT" status --short
  exit 1
fi

# Branch guard (unless --no-branch)
CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if ! $NO_BRANCH && [ -z "$FROM" ]; then
  case "$CURRENT_BRANCH" in
    main|master) ;;
    *)
      echo "current branch is '$CURRENT_BRANCH'; expected main/master (or pass --no-branch)." >&2
      exit 1
      ;;
  esac
fi

PARENT="${FROM:-$CURRENT_BRANCH}"
if [ "$PARENT" = HEAD ]; then PARENT="$CURRENT_BRANCH"; fi
if ! $NO_BRANCH; then
  BASE="$(git -C "$REPO_ROOT" rev-parse --verify "$PARENT^{commit}" 2>/dev/null)" || {
    echo "unknown parent ref: $PARENT" >&2
    exit 1
  }
fi

# Pick next NNN
SPECS_DIR="$REPO_ROOT/specs"
mkdir -p "$SPECS_DIR"
HIGHEST=0
if [ -d "$SPECS_DIR" ]; then
  while IFS= read -r d; do
    n="$(basename "$d" | sed -E 's/^0*([0-9]+)-.*/\1/')"
    if [ -n "$n" ] && [ "$n" -eq "$n" ] 2>/dev/null; then
      if [ "$n" -gt "$HIGHEST" ]; then HIGHEST="$n"; fi
    fi
  done < <(find "$SPECS_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null)
fi
NEXT=$((HIGHEST + 1))
NNN="$(printf '%03d' "$NEXT")"

TARGET_DIR="$SPECS_DIR/$NNN-$SLUG"
TARGET_SPEC="$TARGET_DIR/spec.md"

if [ -e "$TARGET_DIR" ]; then
  echo "target already exists: $TARGET_DIR" >&2
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "template missing at $TEMPLATE" >&2
  exit 1
fi

# Branch
if ! $NO_BRANCH; then
  BRANCH="feature/$SLUG"
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "$BRANCH" >/dev/null; then
    echo "branch already exists: $BRANCH" >&2
    exit 1
  fi
  git -C "$REPO_ROOT" checkout -b "$BRANCH" "$PARENT" >/dev/null
  if ! git -C "$REPO_ROOT" config --local --get "branch.$BRANCH.trellisParent" >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" config --local "branch.$BRANCH.trellisBase" "$BASE" &&
       git -C "$REPO_ROOT" config --local "branch.$BRANCH.trellisSource" new-feature &&
       git -C "$REPO_ROOT" config --local "branch.$BRANCH.trellisParent" "$PARENT"; then
      :
    else
      echo "new-feature: warning: could not record branch creation base; use diff-base.sh set <parent>." >&2
    fi
  fi
  echo "branch: $BRANCH"
fi

# Materialise the spec
mkdir -p "$TARGET_DIR"
TODAY="$(date +%Y-%m-%d)"
sed \
  -e "s/<slug>/$SLUG/" \
  -e "s/YYYY-MM-DD/$TODAY/" \
  "$TEMPLATE" > "$TARGET_SPEC"
echo "created: ${TARGET_SPEC#"$REPO_ROOT/"}"

# Try to open in $EDITOR if interactive
if [ -t 0 ] && [ -n "${EDITOR:-}" ]; then
  exec "$EDITOR" "$TARGET_SPEC"
fi
