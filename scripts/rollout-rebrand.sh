#!/usr/bin/env bash
# One-shot migration from the legacy SE Core naming to Trellis. Re-links the
# in-project inheritance symlinks every registered project has on disk:
#
#   .claude/rules/se-core.md    → .claude/rules/trellis.md
#   .agents/rules/se-core.md    → .agents/rules/trellis.md     (if Codex enabled)
#
# Both legacy symlinks point at the canonical CLAUDE.md, just under the old
# filename. The audits and onboarding scripts now expect the trellis.md name,
# so projects with only the legacy symlinks will fail cross-project-process-
# audit until this script (or a fresh `onboard-project.sh`) runs.
#
# Behaviour per project:
#   1. If both legacy and new symlinks exist + point at canonical: skip.
#   2. If only legacy exists: create the new symlink, remove the legacy one.
#   3. If only the new symlink exists: nothing to do.
#   4. If a legacy symlink points somewhere unexpected: warn + skip.
#
# Reads trellis.config.json for paths. Honors `harnesses` to decide whether
# to touch `.agents/` paths. Idempotent — re-running on a fully migrated
# project is a no-op.
#
# Usage:
#   rollout-rebrand.sh                 # interactive, all registered projects
#   rollout-rebrand.sh --dry-run       # show plan only
#   rollout-rebrand.sh --yes           # non-interactive
#   rollout-rebrand.sh <name>          # single project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  esac
done

# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/blacklist-parser.sh
. "$SCRIPT_DIR/lib/blacklist-parser.sh"

CANONICAL_RULES="$TRELLIS_ROOT/core-rules/CLAUDE.md"
[ -f "$CANONICAL_RULES" ] || {
  echo "canonical rules missing at $CANONICAL_RULES" >&2
  exit 1
}

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    --help|-h) ;;
    -*)        echo "unknown option: $arg" >&2; exit 2 ;;
    *)         ONLY_PROJECT="$arg" ;;
  esac
done

REGISTRY="$TRELLIS_ROOT/registry.md"
BLACKLIST="$TRELLIS_ROOT/blacklist.md"

read_registry() {
  awk '
    /^## Active projects/ { in_table=1; next }
    /^---$/ && in_table { in_table=0 }
    in_table && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0; gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
    }
  ' "$REGISTRY"
}
REGISTRY_NAMES=()
while IFS= read -r line; do [ -n "$line" ] && REGISTRY_NAMES+=("$line"); done < <(read_registry)
BLACKLIST_NAMES=()
while IFS= read -r line; do [ -n "$line" ] && BLACKLIST_NAMES+=("$line"); done < <(read_blacklist_names "$BLACKLIST")

is_blacklisted() {
  local n="$1" b
  [ "${#BLACKLIST_NAMES[@]}" -eq 0 ] && return 1
  for b in "${BLACKLIST_NAMES[@]}"; do [ "$b" = "$n" ] && return 0; done
  return 1
}

migrate_symlink() {
  local p="$1" subdir="$2"
  local legacy="$p/$subdir/rules/se-core.md"
  local fresh="$p/$subdir/rules/trellis.md"
  local target="$CANONICAL_RULES"

  if [ -L "$fresh" ]; then
    local cur; cur="$(readlink "$fresh")"
    if [ "$cur" = "$target" ]; then
      if [ -L "$legacy" ]; then
        $DRY_RUN && { echo "  + would remove legacy: $subdir/rules/se-core.md"; return; }
        rm "$legacy"
        echo "  removed legacy: $subdir/rules/se-core.md"
        return
      fi
      echo "  skip (new symlink correct, no legacy): $subdir/rules/trellis.md"
      return
    fi
    # Known-bad pre-rebrand target: the old projects/se-core/ path.
    if [[ "$cur" == */projects/se-core/core-rules/CLAUDE.md ]]; then
      $DRY_RUN && { echo "  + would retarget: $subdir/rules/trellis.md → canonical"; return; }
      rm "$fresh"
      ln -s "$target" "$fresh"
      echo "  retargeted: $subdir/rules/trellis.md → canonical (was '$cur')"
      return
    fi
    echo "  WARN: $subdir/rules/trellis.md → '$cur' (expected '$target') — leaving" >&2
    return
  fi

  if [ -L "$legacy" ]; then
    local cur; cur="$(readlink "$legacy")"
    # Accept either the new canonical target or the known-bad pre-rebrand
    # target. Anything else is operator-customised and stays put.
    if [ "$cur" != "$target" ] && [[ "$cur" != */projects/se-core/core-rules/CLAUDE.md ]]; then
      echo "  WARN: $subdir/rules/se-core.md → '$cur' (expected '$target' or legacy se-core path) — leaving" >&2
      return
    fi
    $DRY_RUN && { echo "  + would link: $subdir/rules/trellis.md → canonical, then remove legacy"; return; }
    mkdir -p "$(dirname "$fresh")"
    ln -s "$target" "$fresh"
    rm "$legacy"
    echo "  migrated: $subdir/rules/trellis.md → canonical; removed legacy se-core.md (was → '$cur')"
    return
  fi

  echo "  info: neither $subdir/rules/trellis.md nor /se-core.md exists — run onboard-project.sh to seed"
}

migrate_one() {
  local name="$1"
  local p="$PROJECTS_ROOT/$name"
  if [ ! -e "$p/.git" ]; then
    echo "skip (not a git repo on disk): $name → $p"
    return
  fi

  echo "== $name =="

  migrate_symlink "$p" ".claude"

  if pg_has_harness codex; then
    migrate_symlink "$p" ".agents"
  fi
}

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
    if is_blacklisted "$n"; then echo "skip (blacklisted): $n"; continue; fi
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
  migrate_one "$n"
done

echo "== done =="
echo
echo "Next steps:"
echo "  - Run scripts/sync-hooks.sh --apply to push the rebranded husky pre-push hook"
echo "    (TRELLIS_ALLOW_MAIN_PUSH override, TRELLIS_NO_JQ_DEGRADE override) to every project."
echo "  - Run scripts/sync-codex-hooks.sh --apply if Codex parity is enabled."
echo "  - Re-run scripts/conformance-check.sh and the parent-hook-drift audit"
echo "    to confirm zero residual SE_CORE_* references in deployed copies."
