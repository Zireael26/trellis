#!/usr/bin/env bash
# Sync canonical Codex hook assets to all registered projects.
#
# Reads trellis.config.json for paths.
# Reads registry.md for the project list (rows in "Active projects" table).
# Skips blacklisted projects.
#
# Skill symlinks are not synced here; this script handles only the Codex
# project-local hook assets under <project>/.codex/.
#
# Usage:
#   sync-codex-hooks.sh              # interactive: confirm before each project
#   sync-codex-hooks.sh --dry-run    # show what would change, no writes
#   sync-codex-hooks.sh --yes        # non-interactive, sync everywhere
#   sync-codex-hooks.sh <name>       # only that project (must be in registry)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/blacklist-parser.sh
. "$SCRIPT_DIR/lib/blacklist-parser.sh"

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

if ! pg_has_harness codex; then
  echo "Codex harness is not enabled in $TRELLIS_CONFIG_PATH; nothing to sync."
  echo "Set harnesses to include \"codex\" before running this script."
  exit 0
fi

CANONICAL_CODEX_DIR="$SOURCE_ROOT/core-rules/codex"
CANONICAL_HOOKS_DIR="$CANONICAL_CODEX_DIR/hooks"
# Reviewer decision cores live ONLY in the Claude canonical lib (single source
# of truth). The Codex hooks source them from .codex/hooks/lib/, so we deploy
# them from here rather than duplicating copies under core-rules/codex/.
CANONICAL_REVIEWER_LIB_DIR="$SOURCE_ROOT/core-rules/hooks/lib"
REVIEWER_CORES="code-reviewer.sh ui-verify-core.sh spec-gate-core.sh"
REGISTRY="$TRELLIS_ROOT/registry.md"
BLACKLIST="$TRELLIS_ROOT/blacklist.md"

[ -f "$CANONICAL_CODEX_DIR/hooks.json" ] || { echo "canonical Codex hooks manifest missing: $CANONICAL_CODEX_DIR/hooks.json" >&2; exit 1; }
[ -d "$CANONICAL_HOOKS_DIR" ] || { echo "canonical Codex hooks dir missing: $CANONICAL_HOOKS_DIR" >&2; exit 1; }
[ -d "$CANONICAL_REVIEWER_LIB_DIR" ] || { echo "canonical reviewer lib dir missing: $CANONICAL_REVIEWER_LIB_DIR" >&2; exit 1; }
for core in $REVIEWER_CORES; do
  [ -f "$CANONICAL_REVIEWER_LIB_DIR/$core" ] || { echo "canonical reviewer core missing: $CANONICAL_REVIEWER_LIB_DIR/$core" >&2; exit 1; }
done
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
done < <(read_blacklist_names "$BLACKLIST")

is_blacklisted() {
  local name="$1" b
  [ "${#BLACKLIST_NAMES[@]}" -eq 0 ] && return 1
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

  echo "== $name =="
  local changed=0
  local manifest_dst="$proj/.codex/hooks.json"

  if [ ! -f "$manifest_dst" ]; then
    $DRY_RUN && echo "  + would add: .codex/hooks.json" || echo "  added: .codex/hooks.json"
    $DRY_RUN || { mkdir -p "$proj/.codex"; cp "$CANONICAL_CODEX_DIR/hooks.json" "$manifest_dst"; }
    changed=$((changed+1))
  elif ! cmp -s "$CANONICAL_CODEX_DIR/hooks.json" "$manifest_dst"; then
    $DRY_RUN && echo "  ~ would update: .codex/hooks.json" || echo "  updated: .codex/hooks.json"
    $DRY_RUN || cp "$CANONICAL_CODEX_DIR/hooks.json" "$manifest_dst"
    changed=$((changed+1))
  fi

  for src in "$CANONICAL_HOOKS_DIR"/*.sh; do
    local fn dst src_sha dst_sha
    fn="$(basename "$src")"
    dst="$proj/.codex/hooks/$fn"

    if [ ! -f "$dst" ]; then
      $DRY_RUN && echo "  + would add: .codex/hooks/$fn" || echo "  added: .codex/hooks/$fn"
      $DRY_RUN || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; chmod +x "$dst"; }
      changed=$((changed+1))
      continue
    fi

    src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
    dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
    if [ "$src_sha" != "$dst_sha" ]; then
      $DRY_RUN && echo "  ~ would update: .codex/hooks/$fn" || echo "  updated: .codex/hooks/$fn"
      $DRY_RUN || { cp "$src" "$dst"; chmod +x "$dst"; }
      changed=$((changed+1))
    fi
  done

  # Sibling lib/: ship shared helpers (P3.5) alongside the hook scripts.
  if [ -d "$CANONICAL_HOOKS_DIR/lib" ]; then
    for src in "$CANONICAL_HOOKS_DIR/lib"/*.sh; do
      local fn dst src_sha dst_sha
      fn="$(basename "$src")"
      dst="$proj/.codex/hooks/lib/$fn"

      if [ ! -f "$dst" ]; then
        $DRY_RUN && echo "  + would add: .codex/hooks/lib/$fn" || echo "  added: .codex/hooks/lib/$fn"
        $DRY_RUN || { mkdir -p "$proj/.codex/hooks/lib"; cp "$src" "$dst"; }
        changed=$((changed+1))
        continue
      fi

      src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
      dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
      if [ "$src_sha" != "$dst_sha" ]; then
        $DRY_RUN && echo "  ~ would update: .codex/hooks/lib/$fn" || echo "  updated: .codex/hooks/lib/$fn"
        $DRY_RUN || cp "$src" "$dst"
        changed=$((changed+1))
      fi
    done
  fi

  # Reviewer decision cores: deploy the canonical Claude reviewer ladder
  # (code-reviewer.sh) and UI-verify core (ui-verify-core.sh) into
  # .codex/hooks/lib/ so the Codex Stop hooks can source the same verdict
  # logic as the Claude hooks. Single source of truth: copied from the Claude
  # canonical lib, never duplicated under core-rules/codex/.
  for core in $REVIEWER_CORES; do
    local src dst src_sha dst_sha
    src="$CANONICAL_REVIEWER_LIB_DIR/$core"
    dst="$proj/.codex/hooks/lib/$core"

    if [ ! -f "$dst" ]; then
      $DRY_RUN && echo "  + would add: .codex/hooks/lib/$core" || echo "  added: .codex/hooks/lib/$core"
      $DRY_RUN || { mkdir -p "$proj/.codex/hooks/lib"; cp "$src" "$dst"; }
      changed=$((changed+1))
      continue
    fi

    src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
    dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
    if [ "$src_sha" != "$dst_sha" ]; then
      $DRY_RUN && echo "  ~ would update: .codex/hooks/lib/$core" || echo "  updated: .codex/hooks/lib/$core"
      $DRY_RUN || cp "$src" "$dst"
      changed=$((changed+1))
    fi
  done

  if [ "$changed" -eq 0 ]; then
    echo "  (in sync)"
  fi
}

# Filter target list
TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  for n in ${REGISTRY_NAMES[@]+"${REGISTRY_NAMES[@]}"}; do
    [ "$n" = "$ONLY_PROJECT" ] && TARGETS+=("$n")
  done
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "project not in registry: $ONLY_PROJECT" >&2
    exit 1
  fi
else
  for n in ${REGISTRY_NAMES[@]+"${REGISTRY_NAMES[@]}"}; do
    if is_blacklisted "$n"; then
      echo "skip (blacklisted): $n"
      continue
    fi
    TARGETS+=("$n")
  done
fi

echo "Targets: ${TARGETS[*]-}"
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
$DRY_RUN || echo "Reminder: commit changes in each project (chore: sync Codex hooks to canonical)."
