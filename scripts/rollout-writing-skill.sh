#!/usr/bin/env bash
# Rollout: install the canonical `writing` skill symlink in every registered
# project. Idempotent; safe to re-run. Modeled on scripts/rollout-builder-skills.sh
# (and its siblings rollout-process-gate-skill.sh / rollout-feature-skills.sh).
#
# writing is the explicit-invoke-only publishing skill (the twelfth canonical
# skill, spec 010): drafts and publishes blogs + X threads in the author's voice,
# gated by check-writing.sh. Like the builder skills it is NOT part of the
# clarify → spec → plan → tasks → analyze pipeline, so it has its own rollout path. The symlink makes it
# discoverable per project (Claude Code reads .claude/skills/; Codex reads
# .agents/skills/); operators invoke it explicitly with /writing. Stateless
# per-project — no local config is seeded.
#
# Reads trellis.config.json for paths. Honors `harnesses` — .agents/ parity is
# applied only when "codex" is enabled in the parent config.
#
# NOTE on gitignore: the new symlinks should be gitignored (they target absolute
# paths under $TRELLIS_ROOT that conflict on cross-machine merges). Since the
# 2026-06 onboard rework, write_gitignore_block regenerates the managed block
# from the symlinks actually present — re-running onboard-project.sh per project
# (idempotent) folds the writing link in. This script does not touch .gitignore.
#
# Behavior per project:
#   1. If <project>/.claude/skills/writing is already a symlink to canonical: skip.
#   2. If a directory exists where the symlink should go: rename to
#      writing.local-backup-YYYYMMDD/ and create the symlink.
#   3. If neither exists: create the symlink.
#   4. Same flow under .agents/skills/writing when Codex is enabled.
#
# Usage:
#   rollout-writing-skill.sh                 # interactive, all registered projects
#   rollout-writing-skill.sh --dry-run       # show plan only
#   rollout-writing-skill.sh --yes           # non-interactive
#   rollout-writing-skill.sh <project-name>  # single project

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

WRITING_SKILLS=(writing)

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

CANONICAL_SKILLS_DIR="$TRELLIS_ROOT/core-rules/skills"
for s in "${WRITING_SKILLS[@]}"; do
  if [ ! -d "$CANONICAL_SKILLS_DIR/$s" ]; then
    echo "canonical skill missing: $CANONICAL_SKILLS_DIR/$s" >&2
    echo "is the parent branch merged? run from main of the Trellis canonical clone." >&2
    exit 1
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
  # dry-run must be side-effect free — defer mkdir until an actual write
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

  for s in "${WRITING_SKILLS[@]}"; do
    install_skill_symlink "$p" ".claude/skills/$s" "$s"
  done

  if pg_has_harness codex; then
    for s in "${WRITING_SKILLS[@]}"; do
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
echo "Skill: ${WRITING_SKILLS[*]}"
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
echo "  1. /writing is now discoverable in each project (Claude Code reads"
echo "     .claude/skills/; Codex reads .agents/skills/)."
echo "  2. The new symlinks are NOT yet gitignored — run onboard-project.sh"
echo "     per project (idempotent; write_gitignore_block regenerates the"
echo "     managed block) when closing that drift."
echo "  3. No project-local config is required — writing itself is stateless;"
echo "     the per-project VOICE file lives in the target content repo at"
echo "     docs/voice.md (see references/voice.md) and is seeded on first use."
