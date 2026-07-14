#!/usr/bin/env bash
# Rollout: reconcile each registered project's .claude/settings.json with the
# canonical permissions.deny baseline from core-rules/templates/claude-settings.json.
# Idempotent. Project-local deny entries are preserved; canonical entries are
# unioned in. Hooks blocks are left alone — sync-hooks.sh owns those.
#
# A "canonical deny entry" is any string under .permissions.deny in the canonical
# template. The rollout:
#   1. Reads canonical .permissions.deny[] as the required baseline.
#   2. For each registered project under registry.md (skipping blacklist):
#      a. If .claude/settings.json missing → skip with warning (run onboard-project.sh first).
#      b. Compute union of canonical baseline + existing project .permissions.deny[].
#      c. Write back if the union differs from current.
#   3. Never touches .permissions.allow, .permissions.ask, .hooks, or any other key.
#
# This script is the post-onboarding companion to onboard-project.sh — the
# onboard script seeds settings.json fresh from the template; rollout-settings
# brings older projects up to the current baseline without clobbering local
# customizations.
#
# Usage:
#   rollout-settings.sh                 # interactive, all registered projects
#   rollout-settings.sh --dry-run       # show plan only
#   rollout-settings.sh --yes           # non-interactive
#   rollout-settings.sh <project-name>  # single project (by registry name)

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

CANONICAL_TEMPLATE="$TRELLIS_ROOT/core-rules/templates/claude-settings.json"
[ -f "$CANONICAL_TEMPLATE" ] || {
  echo "canonical settings template missing at $CANONICAL_TEMPLATE" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

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

# Path resolution mirrors rollout-presets.sh: PROJECTS_ROOT/<name>.
project_path() {
  echo "$PROJECTS_ROOT/$1"
}

reconcile_project() {
  local name="$1"
  local p
  p="$(project_path "$name")"
  echo
  echo "=== $name ($p)"

  local settings="$p/.claude/settings.json"
  if [ ! -f "$settings" ]; then
    echo "  WARN: $settings missing — run onboard-project.sh first" >&2
    return
  fi

  # Compute the union: canonical deny ∪ existing project deny, deduped.
  # `unique` sorts; that's acceptable — deny entries are unordered.
  local merged
  merged="$(jq -s '
    .[0].permissions.deny as $canon
    | (.[1].permissions.deny // []) as $local
    | .[1]
    | .permissions = (.permissions // {})
    | .permissions.deny = (($canon + $local) | unique)
  ' "$CANONICAL_TEMPLATE" "$settings")"

  # Check whether anything actually changed; bail if not.
  if printf '%s' "$merged" | jq -S . | diff -q - <(jq -S . "$settings") >/dev/null 2>&1; then
    echo "  skip (already current)"
    return
  fi

  if $DRY_RUN; then
    echo "  + would update .permissions.deny (deltas below)"
    local diff_output diff_status
    if diff_output="$(diff <(jq -S '.permissions.deny // []' "$settings") <(printf '%s' "$merged" | jq -S '.permissions.deny // []'))"; then
      diff_status=0
    else
      diff_status=$?
    fi
    [ "$diff_status" -le 1 ] || return "$diff_status"
    printf '%s\n' "$diff_output" | sed 's/^/    /'
    return
  fi

  if ! $ASSUME_YES; then
    printf "  apply update? [y/N] "
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "  skipped by user"; return ;; esac
  fi

  printf '%s\n' "$merged" > "$settings.tmp"
  mv "$settings.tmp" "$settings"
  echo "  updated"
}

main() {
  if [ -n "$ONLY_PROJECT" ]; then
    if is_blacklisted "$ONLY_PROJECT"; then
      echo "$ONLY_PROJECT is blacklisted — skipping" >&2
      exit 0
    fi
    reconcile_project "$ONLY_PROJECT"
    return
  fi

  for name in "${REGISTRY_NAMES[@]}"; do
    if is_blacklisted "$name"; then
      echo "skip (blacklisted): $name"
      continue
    fi
    reconcile_project "$name"
  done
}

main
