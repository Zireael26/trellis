#!/usr/bin/env bash
# Rollout: install (and reconcile) preset symlinks in registered projects per
# each project's own .trellis.config.json declaration. Idempotent.
#
# A "preset" is a markdown file at <trellis_root>/core-rules/presets/<name>.md
# that layers opt-in rules on top of the parent CLAUDE.md. Each project
# decides which presets it wants by listing them in its own root-level
# .trellis.config.json (or trellis.config.json) under a "presets" array.
#
# Per project this script:
#   1. Reads <project>/.trellis.config.json (or trellis.config.json — first
#      match wins) and extracts .presets[].
#   2. For each preset name in the array, verifies the canonical preset file
#      exists; refuses to install symlinks pointing at missing presets.
#   3. Installs <project>/.claude/rules/preset-<name>.md as a symlink to
#      the canonical preset. Same under .agents/rules/ when Codex enabled.
#   4. Removes any preset-*.md symlinks NOT declared in the current array
#      (so removing a preset from config + re-running this script cleans
#      up the project tree). Symlinks pointing somewhere unexpected are
#      left alone with a warning.
#
# Reads trellis.config.json for the parent paths (TRELLIS_ROOT, PROJECTS_ROOT,
# HARNESSES). Per-project preset selection lives in the project, NOT the parent.
#
# Usage:
#   rollout-presets.sh                 # interactive, all registered projects
#   rollout-presets.sh --dry-run       # show plan only
#   rollout-presets.sh --yes           # non-interactive
#   rollout-presets.sh <project-name>  # single project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  esac
done

# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

CANONICAL_PRESETS_DIR="$TRELLIS_ROOT/core-rules/presets"
[ -d "$CANONICAL_PRESETS_DIR" ] || {
  echo "canonical presets dir missing at $CANONICAL_PRESETS_DIR" >&2
  echo "is the parent branch merged? run from main of the Trellis canonical clone." >&2
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
  [ "${#BLACKLIST_NAMES[@]:-0}" -eq 0 ] && return 1
  for b in "${BLACKLIST_NAMES[@]}"; do [ "$b" = "$n" ] && return 0; done
  return 1
}

# Read a project's declared presets array. Echoes preset names one per line.
read_project_presets() {
  local p="$1" cand
  for cand in "$p/.trellis.config.json" "$p/trellis.config.json"; do
    if [ -f "$cand" ]; then
      jq -r '.presets // [] | .[]' "$cand" 2>/dev/null
      return 0
    fi
  done
  return 0
}

# Install one preset symlink. Skip if already correct; warn if pointed elsewhere.
install_preset_symlink() {
  local p="$1" subdir="$2" name="$3"
  # Re-validate the name. The schema's pattern is enforced when ajv runs
  # against the parent config, but the project-local config we read here
  # does not pass through that validator, so a malformed name could reach
  # the filesystem unchecked. Defence in depth.
  if ! printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; then
    echo "  WARN: skipping malformed preset name '$name' (must match ^[a-z0-9][a-z0-9-]*[a-z0-9]\$)" >&2
    return
  fi
  local target="$CANONICAL_PRESETS_DIR/$name.md"
  local link="$p/$subdir/rules/preset-$name.md"
  if [ ! -f "$target" ]; then
    echo "  WARN: preset '$name' declared but $target missing — skipping" >&2
    return
  fi
  # Surface autonomy frontmatter (if any) for operator visibility
  AUTONOMY_BLOCK=$(awk '/^---$/{c++; if(c==2){exit}; next} c==1{print}' "$target")
  FM_CEIL=$(printf '%s\n' "$AUTONOMY_BLOCK" | awk '/^autonomy_ceiling:/{print $2}')
  FM_DEF=$(printf '%s\n' "$AUTONOMY_BLOCK" | awk '/^autonomy_default:/{print $2}')
  if [ -n "$FM_CEIL" ] || [ -n "$FM_DEF" ]; then
    printf '       autonomy: ceiling=%s default=%s\n' "${FM_CEIL:-(none)}" "${FM_DEF:-(none)}"
  fi
  if [ -L "$link" ]; then
    local cur; cur="$(readlink "$link")"
    if [ "$cur" = "$target" ]; then
      echo "  skip (correct symlink): $subdir/rules/preset-$name.md"
      return
    fi
    echo "  WARN: $subdir/rules/preset-$name.md → '$cur' (expected '$target') — leaving" >&2
    return
  fi
  if [ -e "$link" ]; then
    echo "  WARN: $subdir/rules/preset-$name.md exists and is not a symlink — leaving" >&2
    return
  fi
  $DRY_RUN && { echo "  + would link: $subdir/rules/preset-$name.md → canonical"; return; }
  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
  echo "  linked: $subdir/rules/preset-$name.md → canonical"
}

# Remove preset-*.md symlinks under <project>/$subdir/rules/ that aren't in the
# declared list. Leaves non-symlinks alone. Warns on symlinks pointing somewhere
# unexpected.
prune_stale_presets() {
  local p="$1" subdir="$2" declared="$3"
  local dir="$p/$subdir/rules"
  [ -d "$dir" ] || return 0
  for link in "$dir"/preset-*.md; do
    [ -e "$link" ] || continue   # glob didn't match anything
    [ -L "$link" ] || continue   # not a symlink — leave alone
    local fname
    fname="$(basename "$link")"
    local name="${fname#preset-}"; name="${name%.md}"
    if echo "$declared" | grep -qxF "$name"; then
      continue                    # still declared
    fi
    local cur; cur="$(readlink "$link")"
    if [[ "$cur" != "$CANONICAL_PRESETS_DIR/"* ]]; then
      echo "  WARN: $subdir/rules/$fname → '$cur' (not a canonical preset target) — leaving" >&2
      continue
    fi
    $DRY_RUN && { echo "  + would remove stale: $subdir/rules/$fname (no longer in declared array)"; continue; }
    rm "$link"
    echo "  removed stale: $subdir/rules/$fname (no longer declared)"
  done
}

rollout_one() {
  local name="$1"
  local p="$PROJECTS_ROOT/$name"
  if [ ! -e "$p/.git" ]; then
    echo "skip (not a git repo on disk): $name → $p"
    return
  fi

  echo "== $name =="

  local declared
  declared="$(read_project_presets "$p")"

  if [ -z "$declared" ]; then
    echo "  no presets declared (no .trellis.config.json or empty .presets array)"
  fi

  for n in $declared; do
    install_preset_symlink "$p" ".claude" "$n"
  done
  prune_stale_presets "$p" ".claude" "$declared"

  if pg_has_harness codex || pg_has_harness antigravity; then
    for n in $declared; do
      install_preset_symlink "$p" ".agents" "$n"
    done
    prune_stale_presets "$p" ".agents" "$declared"
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
preset_names=""
for p in "$CANONICAL_PRESETS_DIR"/*.md; do
  [ -f "$p" ] || continue
  base="$(basename "$p" .md)"
  [ "$base" = "README" ] && continue
  preset_names="$preset_names $base"
done
echo "Canonical presets available: ${preset_names# }"
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
echo "  1. Symlinks at .claude/rules/preset-*.md and .agents/rules/preset-*.md"
echo "     are per-machine state — they target absolute paths and MUST be"
echo "     gitignored. The canonical project.gitignore.fragment (7-skill +"
echo "     presets edition) covers this via the .claude/rules/preset-*.md"
echo "     and .agents/rules/preset-*.md globs."
echo "  2. To add a preset: edit <project>/.trellis.config.json (or"
echo "     trellis.config.json) — add the name to the .presets array —"
echo "     then re-run scripts/rollout-presets.sh. To remove: delete the"
echo "     name from the array and re-run; the script prunes stale"
echo "     symlinks."
echo "  3. Available presets live at $CANONICAL_PRESETS_DIR/ ; see the"
echo "     README there for the authoring contract."
