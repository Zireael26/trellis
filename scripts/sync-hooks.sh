#!/usr/bin/env bash
# Sync canonical hook scripts to all registered projects.
#
# Reads trellis.config.json for paths.
# Reads registry.md for the project list (rows in "Active projects" table).
# Skips blacklisted projects.
#
# Skill symlinks are not synced — they are symlinks to canonical and
# update automatically. This script handles only the .sh hook *copies*
# under <project>/.claude/hooks/.
#
# Usage:
#   sync-hooks.sh                  # interactive: confirm before each project
#   sync-hooks.sh --dry-run        # show what would change, no writes
#   sync-hooks.sh --yes            # non-interactive, sync everywhere
#   sync-hooks.sh <name>           # only that project (must be in registry)
#   sync-hooks.sh --from-main-only # refuse to run from a worktree / detached HEAD
#
# Provenance: every run prints SOURCE_ROOT, HEAD SHA, and the SHA of one
# bellwether hook before touching any project. The 2026-05-09 cross-project
# sync silently used a stale source (pre-May-8 canonical) and missed the
# context-log hooks; see audits/2026-05-11-sync-tool-rca.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""
FROM_MAIN_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)         DRY_RUN=true ;;
    --yes|-y)          ASSUME_YES=true ;;
    --from-main-only)  FROM_MAIN_ONLY=true ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
    *)
      ONLY_PROJECT="$arg"
      ;;
  esac
done

CANONICAL_HOOKS_DIR="$SOURCE_ROOT/core-rules/hooks"
REGISTRY="$TRELLIS_ROOT/registry.md"
BLACKLIST="$TRELLIS_ROOT/blacklist.md"

[ -d "$CANONICAL_HOOKS_DIR" ] || { echo "canonical hooks dir missing: $CANONICAL_HOOKS_DIR" >&2; exit 1; }
[ -f "$REGISTRY" ]            || { echo "registry.md missing: $REGISTRY" >&2; exit 1; }

# --- Provenance breadcrumbs ---
# Loudly identify the source the sync is reading from. The 2026-05-09 incident
# was a stale source that silently shipped pre-May-8 hooks to every project;
# logging this up front makes that class of bug visible in retrospect.
SOURCE_HEAD="(no git)"
if command -v git >/dev/null 2>&1 && git -C "$SOURCE_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD)"
fi
BELLWETHER="$CANONICAL_HOOKS_DIR/session-context.sh"
BELLWETHER_SHA="(missing)"
[ -f "$BELLWETHER" ] && BELLWETHER_SHA="$(shasum -a 256 "$BELLWETHER" | awk '{print $1}')"

echo "Source:        $SOURCE_ROOT"
echo "Source HEAD:   $SOURCE_HEAD"
echo "Bellwether:    session-context.sh sha=${BELLWETHER_SHA:0:12}"

# Worktree / stale-source guard.
case "$SOURCE_ROOT" in
  */.claude/worktrees/*)
    if $FROM_MAIN_ONLY; then
      echo "refusing to run: SOURCE_ROOT is inside a worktree and --from-main-only is set" >&2
      exit 1
    fi
    echo "WARNING: SOURCE_ROOT is inside a worktree (.claude/worktrees/...) — pass --from-main-only to refuse this configuration." >&2
    ;;
esac

# Parse Active projects table from registry.md
# Format: | name | `/personal/<dir>` | class | notes |
# Skips the header row ("| Project |") and separator ("|---|").
read_registry() {
  awk '
    /^## Active projects/ { in_table=1; next }
    /^---$/ && in_table { in_table=0 }
    in_table && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0
      gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
    }
  ' "$REGISTRY"
}

read_blacklist_names() {
  [ -f "$BLACKLIST" ] || return 0
  awk '
    /^## (Blacklisted|Currently exempt|Active blacklist)/ { in_table=1; next }
    /^---$/ && in_table { in_table=0 }
    in_table && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0
      gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
    }
  ' "$BLACKLIST"
}

resolve_project_path() {
  # Map a registry name to absolute path under PROJECTS_ROOT.
  # registry uses paths like `/personal/<name>` — we strip /personal/ and
  # join with PROJECTS_ROOT.
  local name="$1"
  printf "%s/%s" "$PROJECTS_ROOT" "$name"
}

REGISTRY_NAMES=()
while IFS= read -r line; do
  [ -n "$line" ] && REGISTRY_NAMES+=("$line")
done < <(read_registry)

BLACKLIST_NAMES=()
while IFS= read -r line; do
  [ -n "$line" ] && BLACKLIST_NAMES+=("$line")
done < <(read_blacklist_names)

is_blacklisted() {
  local name="$1" b
  [ "${#BLACKLIST_NAMES[@]:-0}" -eq 0 ] && return 1
  for b in "${BLACKLIST_NAMES[@]}"; do
    [ "$b" = "$name" ] && return 0
  done
  return 1
}

sync_one() {
  local name="$1"
  local proj
  proj="$(resolve_project_path "$name")"

  if [ ! -d "$proj" ]; then
    echo "skip (not on disk): $name → $proj"
    return
  fi
  if [ ! -d "$proj/.claude/hooks" ]; then
    # Single-project explicit invocation is treated as opt-in to onboarding.
    # Bulk runs still skip silently so a stale project does not get a fresh
    # hook stack by accident.
    if [ -n "$ONLY_PROJECT" ] && [ "$ONLY_PROJECT" = "$name" ]; then
      echo "  + creating .claude/hooks/ (explicit single-project run)"
      $DRY_RUN || mkdir -p "$proj/.claude/hooks"
    else
      echo "skip (no .claude/hooks/): $name"
      return
    fi
  fi

  echo "== $name =="
  local changed=0
  for src in "$CANONICAL_HOOKS_DIR"/*.sh; do
    local fn dst src_sha dst_sha
    fn="$(basename "$src")"
    dst="$proj/.claude/hooks/$fn"

    if [ ! -f "$dst" ]; then
      echo "  + would add: $fn"
      $DRY_RUN || { cp "$src" "$dst"; chmod +x "$dst"; }
      changed=$((changed+1))
      continue
    fi

    src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
    dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
    if [ "$src_sha" != "$dst_sha" ]; then
      echo "  ~ would update: $fn"
      $DRY_RUN || { cp "$src" "$dst"; chmod +x "$dst"; }
      changed=$((changed+1))
    fi
  done

  # Sibling lib/: ship shared helpers (P3.5) alongside the hook scripts.
  if [ -d "$CANONICAL_HOOKS_DIR/lib" ]; then
    for src in "$CANONICAL_HOOKS_DIR/lib"/*.sh; do
      local fn dst src_sha dst_sha
      fn="$(basename "$src")"
      dst="$proj/.claude/hooks/lib/$fn"

      if [ ! -f "$dst" ]; then
        echo "  + would add: lib/$fn"
        $DRY_RUN || { mkdir -p "$proj/.claude/hooks/lib"; cp "$src" "$dst"; }
        changed=$((changed+1))
        continue
      fi

      src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
      dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
      if [ "$src_sha" != "$dst_sha" ]; then
        echo "  ~ would update: lib/$fn"
        $DRY_RUN || cp "$src" "$dst"
        changed=$((changed+1))
      fi
    done
  fi

  if [ "$changed" -eq 0 ]; then
    echo "  (in sync)"
  fi
}

# Filter target list
TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  for n in "${REGISTRY_NAMES[@]}"; do
    [ "$n" = "$ONLY_PROJECT" ] && TARGETS+=("$n")
  done
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "project not in registry: $ONLY_PROJECT" >&2
    exit 1
  fi
else
  for n in "${REGISTRY_NAMES[@]}"; do
    if is_blacklisted "$n"; then
      echo "skip (blacklisted): $n"
      continue
    fi
    TARGETS+=("$n")
  done
fi

echo "Targets: ${TARGETS[*]}"
$DRY_RUN && echo "(dry-run mode — no writes)"

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 0; }
fi

for n in "${TARGETS[@]}"; do
  sync_one "$n"
done

echo "== done =="
$DRY_RUN || echo "Reminder: commit changes in each project (chore: sync hooks to canonical)."
