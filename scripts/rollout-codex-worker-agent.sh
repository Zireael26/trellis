#!/usr/bin/env bash
# Roll out the canonical blocking codex-worker agent symlink to registered
# projects. Idempotent and safe to re-run.
#
# Usage:
#   rollout-codex-worker-agent.sh                 # interactive, all projects
#   rollout-codex-worker-agent.sh --dry-run       # report only
#   rollout-codex-worker-agent.sh --yes           # non-interactive
#   rollout-codex-worker-agent.sh <project-name>  # one registered project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/blacklist-parser.sh
. "$SCRIPT_DIR/lib/blacklist-parser.sh"

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""
DATE_TAG="$(date +%Y%m%d)"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) ONLY_PROJECT="$arg" ;;
  esac
done

CANONICAL_AGENT="$TRELLIS_ROOT/core-rules/agents/codex-worker.md"
REGISTRY="$TRELLIS_ROOT/registry.md"
BLACKLIST="$TRELLIS_ROOT/blacklist.md"

if [ ! -f "$CANONICAL_AGENT" ]; then
  if $DRY_RUN; then
    echo "WARN (dry-run): canonical agent not present yet: $CANONICAL_AGENT" >&2
  else
    echo "canonical agent missing: $CANONICAL_AGENT" >&2
    exit 1
  fi
fi

read_table() {
  local file="$1" heading_re="$2"
  [ -f "$file" ] || return 0
  awk -v heading_re="$heading_re" '
    $0 ~ heading_re { in_table=1; next }
    /^---$/ && in_table { in_table=0 }
    in_table && /^\| [a-zA-Z0-9._-]+ \|/ {
      name=$0; sub(/^\| /, "", name); sub(/ \|.*$/, "", name)
      if (name != "Project" && name !~ /^-+$/) print name
    }
  ' "$file"
}

REGISTRY_NAMES=()
while IFS= read -r line; do [ -n "$line" ] && REGISTRY_NAMES+=("$line"); done < <(read_table "$REGISTRY" '^## Active projects')
BLACKLIST_NAMES=()
while IFS= read -r line; do [ -n "$line" ] && BLACKLIST_NAMES+=("$line"); done < <(read_blacklist_names "$BLACKLIST")

is_blacklisted() {
  local name="$1" item
  for item in "${BLACKLIST_NAMES[@]+"${BLACKLIST_NAMES[@]}"}"; do
    [ "$item" = "$name" ] && return 0
  done
  return 1
}

install_agent_symlink() {
  local project="$1" rel=".claude/agents/codex-worker.md"
  local link="$project/$rel" current backup

  if [ -L "$link" ]; then
    current="$(readlink "$link")"
    if [ "$current" = "$CANONICAL_AGENT" ]; then
      echo "  skip (correct symlink): $rel"
    else
      echo "  WARN: $rel symlinks to '$current', expected '$CANONICAL_AGENT' — leaving" >&2
    fi
    return
  fi

  if [ -e "$link" ]; then
    backup="${link}.local-backup-$DATE_TAG"
    if [ -e "$backup" ]; then
      echo "  WARN: backup target already exists: ${backup#"$project/"} — leaving" >&2
      return
    fi
    if $DRY_RUN; then
      echo "  + would back up: $rel → ${rel}.local-backup-$DATE_TAG"
    else
      mv "$link" "$backup"
      echo "  backed up: $rel → ${rel}.local-backup-$DATE_TAG"
    fi
  fi

  if $DRY_RUN; then
    echo "  + would link: $rel → $CANONICAL_AGENT"
  else
    mkdir -p "$(dirname "$link")"
    ln -s "$CANONICAL_AGENT" "$link"
    echo "  linked: $rel → $CANONICAL_AGENT"
  fi
}

TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  for name in "${REGISTRY_NAMES[@]}"; do
    [ "$name" = "$ONLY_PROJECT" ] && TARGETS+=("$name")
  done
  [ "${#TARGETS[@]}" -gt 0 ] || { echo "project not in registry: $ONLY_PROJECT" >&2; exit 1; }
else
  for name in "${REGISTRY_NAMES[@]}"; do
    if is_blacklisted "$name"; then
      echo "skip (blacklisted): $name"
    else
      TARGETS+=("$name")
    fi
  done
fi

echo "Targets: ${TARGETS[*]}"
echo "Agent: codex-worker"
$DRY_RUN && echo "(dry-run mode — no writes)"

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf 'Proceed? [y/N] '
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "aborted"; exit 0; }
fi

for name in "${TARGETS[@]}"; do
  project="$PROJECTS_ROOT/$name"
  if [ ! -e "$project/.git" ]; then
    echo "skip (not a git repo on disk): $name → $project"
    continue
  fi
  echo "== $name =="
  install_agent_symlink "$project"
done

echo "== done =="
echo "Run onboard-project.sh for each project to refresh its generated gitignore block."
