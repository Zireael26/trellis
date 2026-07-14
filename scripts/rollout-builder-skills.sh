#!/usr/bin/env bash
# Rollout: install the canonical builder skill symlinks — execute + brainstorming
# — in every registered project. Idempotent; safe to re-run. Modeled on
# scripts/rollout-process-gate-skill.sh (and its multi-skill sibling
# scripts/rollout-feature-skills.sh).
#
# These are the NON-pipeline skills: brainstorming is the ideation front-door and
# execute is the canonical builder loop. They are deliberately NOT part of the
# clarify → spec → plan → tasks → analyze pipeline, so they have their own rollout
# path and are NOT listed in rollout-feature-skills.sh's FEATURE_SKILLS array.
# The symlinks make them discoverable in each project (Claude Code reads
# .claude/skills/; Codex reads .agents/skills/); operators invoke them
# by name. Stateless per-project — no local config is seeded.
#
# Reads trellis.config.json for paths. Honors `harnesses` — .agents/ parity is
# applied only when "codex" is enabled in the parent config.
#
# Behavior per project:
#   1. If <project>/.claude/skills/<skill>/ is already a symlink to canonical: skip.
#   2. If a directory exists where the symlink should go: rename to
#      <skill>.local-backup-YYYYMMDD/ and create the symlink.
#   3. If neither exists: create the symlink.
#   4. Same flow under .agents/skills/<skill>/ when Codex is enabled.
#   5. Does NOT seed any local config — these skills are stateless per-project.
#
# Usage:
#   rollout-builder-skills.sh                 # interactive, all registered projects
#   rollout-builder-skills.sh --dry-run       # show plan only
#   rollout-builder-skills.sh --yes           # non-interactive
#   rollout-builder-skills.sh <project-name>  # single project

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

# The non-pipeline builder skills: brainstorming (ideation front-door) and
# execute (the canonical builder loop). These are NOT writers in the
# clarify → spec → plan → tasks → analyze pipeline, so they live here rather
# than in rollout-feature-skills.sh's FEATURE_SKILLS.
BUILDER_SKILLS=(execute brainstorming)

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""
DATE_TAG="$(date +%Y%m%d)"

# Parse args BEFORE the canonical-skill existence check so --dry-run can soften
# a missing skill dir (the skill bodies land in later phases of the
# process-enforcement program; --dry-run must resolve cleanly before then).
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    --help|-h) ;;
    -*)        echo "unknown option: $arg" >&2; exit 2 ;;
    *)         ONLY_PROJECT="$arg" ;;
  esac
done

CANONICAL_SKILLS_DIR="$TRELLIS_ROOT/core-rules/skills"
for s in "${BUILDER_SKILLS[@]}"; do
  if [ ! -d "$CANONICAL_SKILLS_DIR/$s" ]; then
    if $DRY_RUN; then
      echo "  WARN (dry-run): canonical skill not present yet: $CANONICAL_SKILLS_DIR/$s" >&2
      echo "    (lands in a later phase of the process-enforcement program — dry-run continues)" >&2
    else
      echo "canonical skill missing: $CANONICAL_SKILLS_DIR/$s" >&2
      echo "is the parent branch merged? run from main of the Trellis canonical clone." >&2
      exit 1
    fi
  fi
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

install_skill_symlink() {
  local p="$1" rel="$2" skill="$3"
  local target="$CANONICAL_SKILLS_DIR/$skill"
  local link="$p/$rel"
  local parent_dir backup_dir cur

  parent_dir="$(dirname "$link")"
  $DRY_RUN || mkdir -p "$parent_dir"

  if [ -L "$link" ]; then
    cur="$(readlink "$link")"
    if [ "$cur" = "$target" ]; then
      echo "  skip (correct symlink): $rel"
      return
    fi
    echo "  WARN: $rel symlinks to '$cur', expected '$target' — leaving" >&2
    return
  fi

  if [ -e "$link" ]; then
    backup_dir="${link%/}.local-backup-$DATE_TAG"
    if [ -e "$backup_dir" ]; then
      echo "  WARN: backup target $backup_dir already exists — leaving original alone" >&2
      return
    fi
    $DRY_RUN && { echo "  + would back up: $rel → ${rel}.local-backup-$DATE_TAG"; echo "  + would link: $rel → canonical"; return; }
    mv "$link" "$backup_dir"
    echo "  backed up: $rel → ${rel}.local-backup-$DATE_TAG"
  fi

  $DRY_RUN && { echo "  + would link: $rel → canonical"; return; }
  ln -s "$target" "$link"
  echo "  linked: $rel → canonical"
}

rollout_one() {
  local name="$1"
  local p="$PROJECTS_ROOT/$name"
  if [ ! -e "$p/.git" ]; then
    echo "skip (not a git repo on disk): $name → $p"
    return
  fi

  echo "== $name =="

  for s in "${BUILDER_SKILLS[@]}"; do
    install_skill_symlink "$p" ".claude/skills/$s" "$s"
  done

  if pg_has_harness codex; then
    for s in "${BUILDER_SKILLS[@]}"; do
      install_skill_symlink "$p" ".agents/skills/$s" "$s"
    done
  elif [ -d "$p/.agents" ]; then
    echo "  info: $p has .agents/ but harnesses=${HARNESSES[*]} — .agents/ parity NOT applied; rerun with codex enabled if desired"
  fi
}

# Filter targets
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
echo "Builder skills: ${BUILDER_SKILLS[*]}"
$DRY_RUN && echo "(dry-run mode — no writes)"

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 0; }
fi

for n in "${TARGETS[@]}"; do
  rollout_one "$n"
done

echo "== done =="
echo
echo "Per-project next steps:"
echo "  1. The new symlinks (.claude/skills/{execute,brainstorming},"
echo "     .agents/skills/{execute,brainstorming}) MUST be gitignored"
echo "     — they target absolute paths under \$TRELLIS_ROOT that conflict on"
echo "     cross-machine merges."
echo "  2. Older projects carry stale/stacked gitignore fragments that do not"
echo "     list the new execute/brainstorming symlinks. Re-run onboard-project.sh"
echo "     on the project — it regenerates the .gitignore Trellis-managed block in"
echo "     full (collapsing any stale/stacked blocks into one) from the symlinks"
echo "     it creates. No manual fragment paste is needed."
echo "  3. No project-local config is required for the builder skills — they"
echo "     run stateless."
