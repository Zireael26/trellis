#!/usr/bin/env bash
# Sync canonical hook scripts to all registered projects.
#
# Reads se-core.config.json for paths.
# Reads registry.md for the project list (rows in "Active projects" table).
# Skips blacklisted projects.
#
# Skill symlinks are not synced — they are symlinks to canonical and
# update automatically. This script handles only the .sh hook *copies*
# under <project>/.claude/hooks/.
#
# Usage:
#   sync-hooks.sh              # interactive: confirm before each project
#   sync-hooks.sh --dry-run    # show what would change, no writes
#   sync-hooks.sh --yes        # non-interactive, sync everywhere
#   sync-hooks.sh <name>       # only that project (must be in registry)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
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
REGISTRY="$SE_CORE_ROOT/registry.md"
BLACKLIST="$SE_CORE_ROOT/blacklist.md"

[ -d "$CANONICAL_HOOKS_DIR" ] || { echo "canonical hooks dir missing: $CANONICAL_HOOKS_DIR" >&2; exit 1; }
[ -f "$REGISTRY" ]            || { echo "registry.md missing: $REGISTRY" >&2; exit 1; }

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
    echo "skip (no .claude/hooks/): $name"
    return
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
