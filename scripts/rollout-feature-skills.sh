#!/usr/bin/env bash
# Rollout: install the clarify → spec → plan → tasks → analyze skill symlinks
# in every registered project. Idempotent; safe to re-run. Modeled on
# scripts/rollout-process-gate-skill.sh.
#
# These skills are opt-in. The symlinks make them discoverable in each project
# (Claude Code reads .claude/skills/; Codex reads .agents/skills/) but the
# operator still has to invoke them by name. No project's day-to-day workflow
# changes unless the operator wants the pipeline for a particular feature.
#
# Reads trellis.config.json for paths. Honors `harnesses` — Codex parity is
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
#   rollout-feature-skills.sh                 # interactive, all registered projects
#   rollout-feature-skills.sh --dry-run       # show plan only
#   rollout-feature-skills.sh --yes           # non-interactive
#   rollout-feature-skills.sh <project-name>  # single project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  esac
done

# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

# The full opt-in pipeline: clarify (front-step question pass) → spec → plan
# → tasks → analyze (tail-step drift check). All five surface in each project's
# .claude/skills/ (and .agents/skills/ under Codex) but stay opt-in — agents
# invoke them by name; nothing fires automatically.
FEATURE_SKILLS=(clarify spec plan tasks analyze)

CANONICAL_SKILLS_DIR="$TRELLIS_ROOT/core-rules/skills"
for s in "${FEATURE_SKILLS[@]}"; do
  if [ ! -d "$CANONICAL_SKILLS_DIR/$s" ]; then
    echo "canonical skill missing: $CANONICAL_SKILLS_DIR/$s" >&2
    echo "is the parent branch merged? run from main of the Trellis canonical clone." >&2
    exit 1
  fi
done

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""
DATE_TAG="$(date +%Y%m%d)"

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
read_blacklist() {
  [ -f "$BLACKLIST" ] || return 0
  awk '
    /^## (Blacklisted|Currently exempt|Active blacklist)/ { in_table=1; next }
    /^---$/ && in_table { in_table=0 }
    in_table && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0; gsub(/^\| /, "", name); gsub(/ \|.*$/, "", name)
      if (name == "Project" || name ~ /^-+$/) next
      print name
    }
  ' "$BLACKLIST"
}

REGISTRY_NAMES=()
while IFS= read -r line; do [ -n "$line" ] && REGISTRY_NAMES+=("$line"); done < <(read_registry)
BLACKLIST_NAMES=()
while IFS= read -r line; do [ -n "$line" ] && BLACKLIST_NAMES+=("$line"); done < <(read_blacklist)

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
  mkdir -p "$parent_dir"

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

  for s in "${FEATURE_SKILLS[@]}"; do
    install_skill_symlink "$p" ".claude/skills/$s" "$s"
  done

  if pg_has_harness codex || pg_has_harness antigravity; then
    for s in "${FEATURE_SKILLS[@]}"; do
      install_skill_symlink "$p" ".agents/skills/$s" "$s"
    done
  elif [ -d "$p/.agents" ]; then
    echo "  info: $p has .agents/ but harnesses=${HARNESSES[*]} — .agents/ parity NOT applied; rerun with codex or antigravity enabled if desired"
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
echo "Feature skills: ${FEATURE_SKILLS[*]}"
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
echo "  1. The new symlinks (.claude/skills/{clarify,spec,plan,tasks,analyze},"
echo "     .agents/skills/{clarify,spec,plan,tasks,analyze}) MUST be gitignored"
echo "     — they target absolute paths under \$TRELLIS_ROOT that conflict on"
echo "     cross-machine merges."
echo "  2. Older projects carry pre-Phase-C gitignore fragments that do not"
echo "     list the new clarify/analyze symlinks. Run onboard-project.sh on"
echo "     the project (idempotent: appends the current-version fragment when"
echo "     the sentinel string has bumped; existing files are skipped), OR"
echo "     paste the canonical fragment yourself:"
echo "         cat $TRELLIS_ROOT/core-rules/templates/project.gitignore.fragment >> <project>/.gitignore"
echo "  3. No project-local config is required for the pipeline skills — they"
echo "     run stateless."
