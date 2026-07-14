#!/usr/bin/env bash
# Re-sync the canonical pre-push merge-gate hook to all registered projects.
#
# Reads trellis.config.json for paths.
# Reads registry.md for the project list (rows in "Active projects" table).
# Skips blacklisted projects.
#
# This script owns ONLY the pre-push hook — the cross-harness merge gate that
# carries the process-gate run-all aggregator. commit-msg/pre-commit are out of
# scope. Gate-1 analysis confirmed every project's pre-push diverges from
# canonical by PURE version-staleness (no custom pre-push logic), so an
# overwrite-from-canonical is safe.
#
# Per project, the pre-push target + canonical source are derived from the
# install shape (the load-bearing decision is resolve_prepush_target() in
# lib/prepush-target.sh):
#   * <project>/.husky/ exists        -> .husky/pre-push       <- core-rules/husky/pre-push
#   * core.hooksPath = tracked in-repo dir (e.g. .githooks)
#                                      -> <hooksPath>/pre-push  <- core-rules/githooks/pre-push
#   * core.hooksPath outside worktree, OR = .git/hooks while a tracked
#     .githooks/ also exists (clusterbid misconfig)
#                                      -> WARN + SKIP (operator resolves intent;
#                                         this script never changes git config)
#   * no husky, no hooksPath           -> .git/hooks/pre-push   <- core-rules/githooks/pre-push
#
# sha-compare; overwrite + chmod +x only when stale/missing.
#
# Usage:
#   sync-merge-gate.sh                  # interactive: confirm once before the loop
#   sync-merge-gate.sh --dry-run        # show what would change, no writes
#   sync-merge-gate.sh --yes            # non-interactive, sync everywhere
#   sync-merge-gate.sh <name>           # only that project (must be in registry)
#   sync-merge-gate.sh --from-main-only # refuse to run from a worktree / detached HEAD
#
# Provenance: every run prints SOURCE_ROOT and HEAD SHA before touching any
# project (same breadcrumb discipline as sync-hooks.sh — the 2026-05-09 stale-
# source incident; see audits/2026-05-11-sync-tool-rca.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/blacklist-parser.sh
. "$SCRIPT_DIR/lib/blacklist-parser.sh"
# shellcheck source=lib/prepush-target.sh
. "$SCRIPT_DIR/lib/prepush-target.sh"

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

CANONICAL_HUSKY_PREPUSH="$SOURCE_ROOT/core-rules/husky/pre-push"
CANONICAL_GITHOOKS_PREPUSH="$SOURCE_ROOT/core-rules/githooks/pre-push"
REGISTRY="$TRELLIS_ROOT/registry.md"
BLACKLIST="$TRELLIS_ROOT/blacklist.md"

[ -f "$CANONICAL_HUSKY_PREPUSH" ]    || { echo "canonical husky pre-push missing: $CANONICAL_HUSKY_PREPUSH" >&2; exit 1; }
[ -f "$CANONICAL_GITHOOKS_PREPUSH" ] || { echo "canonical githooks pre-push missing: $CANONICAL_GITHOOKS_PREPUSH" >&2; exit 1; }
[ -f "$REGISTRY" ]                   || { echo "registry.md missing: $REGISTRY" >&2; exit 1; }

# --- Provenance breadcrumbs ---
SOURCE_HEAD="(no git)"
if command -v git >/dev/null 2>&1 && git -C "$SOURCE_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD)"
fi
HUSKY_SHA="(missing)"
[ -f "$CANONICAL_HUSKY_PREPUSH" ] && HUSKY_SHA="$(shasum -a 256 "$CANONICAL_HUSKY_PREPUSH" | awk '{print $1}')"

echo "Source:        $SOURCE_ROOT"
echo "Source HEAD:   $SOURCE_HEAD"
echo "Bellwether:    husky/pre-push sha=${HUSKY_SHA:0:12}"

# Worktree / stale-source guard (mirrors sync-hooks.sh).
case "$SOURCE_ROOT" in
  */.claude/worktrees/*)
    if $FROM_MAIN_ONLY; then
      echo "refusing to run: SOURCE_ROOT is inside a worktree and --from-main-only is set" >&2
      exit 1
    fi
    echo "WARNING: SOURCE_ROOT is inside a worktree (.claude/worktrees/...) — pass --from-main-only to refuse this configuration." >&2
    ;;
esac

# Linked-worktree guard (generalizes the path check above; mirrors sync-hooks.sh):
# a linked worktree outside .claude/worktrees/ (e.g. a sibling dir) is just as
# stale-prone. A linked worktree's --git-dir is <main>/.git/worktrees/<name>.
if command -v git >/dev/null 2>&1 \
   && git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  __mg_gitdir="$(git -C "$SOURCE_ROOT" rev-parse --git-dir 2>/dev/null || true)"
  case "$__mg_gitdir" in
    */worktrees/*)
      if $FROM_MAIN_ONLY; then
        echo "refusing to run: SOURCE_ROOT is a linked git worktree and --from-main-only is set" >&2
        exit 1
      fi
      echo "WARNING: SOURCE_ROOT is a linked git worktree — pass --from-main-only to refuse this configuration." >&2
      ;;
  esac
fi

# Detached-HEAD guard (mirrors sync-hooks.sh): --from-main-only also refuses a
# detached HEAD. symbolic-ref -q fails on a detached HEAD; only enforce when the
# flag is set and SOURCE_ROOT is a repo.
if $FROM_MAIN_ONLY && command -v git >/dev/null 2>&1 \
   && git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && ! git -C "$SOURCE_ROOT" symbolic-ref -q HEAD >/dev/null 2>&1; then
  echo "refusing to run: SOURCE_ROOT HEAD is detached and --from-main-only is set" >&2
  exit 1
fi

# Parse Active projects table from registry.md (same parser as sync-hooks.sh).
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

# Map a SOURCE_KIND token (from resolve_prepush_target) to its canonical file.
canonical_source_for() {
  case "$1" in
    husky)    printf '%s' "$CANONICAL_HUSKY_PREPUSH" ;;
    githooks) printf '%s' "$CANONICAL_GITHOOKS_PREPUSH" ;;
    *)        return 1 ;;
  esac
}

# is_managed_prepush <file>
#   Returns 0 if the existing pre-push looks Trellis/SE-Core-managed (i.e. a
#   stale-but-ours hook we may safely overwrite), 1 if it is an unknown custom
#   hook the operator authored. Gate-1 proved TODAY no project ships a custom
#   pre-push, but this tool is general + mirror-published, so a divergent file
#   that matches NO managed marker is treated as operator-owned: WARN + SKIP
#   rather than clobber. Markers cover the canonical carrier's vocabulary:
#   "Trellis" / "SE Core" (the banner), "run-all" (the aggregator it invokes),
#   and the PR-flow guard string.
is_managed_prepush() {
  grep -qE 'Trellis|SE Core|run-all|PR-flow' "$1"
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

  # Decide target + source via the pure resolver.
  local decision verb target kind src
  decision="$(resolve_prepush_target "$proj")"
  verb="$(printf '%s' "$decision" | cut -f1)"

  if [ "$verb" = "WARN" ]; then
    local reason
    reason="$(printf '%s' "$decision" | cut -f2)"
    echo "  WARN: $reason — SKIP" >&2
    return
  fi

  target="$(printf '%s' "$decision" | cut -f2)"
  kind="$(printf '%s' "$decision" | cut -f3)"
  src="$(canonical_source_for "$kind")" || {
    echo "  internal error: unknown source kind '$kind'" >&2
    return
  }

  # sha-compare; overwrite + chmod +x if missing or stale.
  if [ ! -f "$target" ]; then
    echo "  + would add: ${target#"$proj"/} (from $kind canonical)"
    if ! $DRY_RUN; then
      mkdir -p "$(dirname "$target")"
      cp "$src" "$target"
      chmod +x "$target"
    fi
    return
  fi

  local src_sha dst_sha
  src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
  dst_sha="$(shasum -a 256 "$target" | awk '{print $1}')"
  if [ "$src_sha" = "$dst_sha" ]; then
    echo "  (in sync)"
    return
  fi

  # Overwrite safety: the existing pre-push diverges from canonical. If it is a
  # NON-EMPTY file that matches NO managed marker, treat it as an operator-
  # authored custom hook and WARN + SKIP rather than clobber. A managed (stale)
  # file, or an empty placeholder, overwrites normally. Checked BEFORE the
  # "would update" echo so --dry-run reports the skip honestly.
  if [ -s "$target" ] && ! is_managed_prepush "$target"; then
    echo "  WARN: ${target#"$proj"/} diverges from canonical but matches no managed marker (unknown custom hook) — SKIP (operator resolves)" >&2
    return
  fi

  echo "  ~ would update: ${target#"$proj"/} (from $kind canonical)"
  if $DRY_RUN; then
    diff "$target" "$src" | sed 's/^/    /' || true
  else
    cp "$src" "$target"
    chmod +x "$target"
  fi
}

# Filter target list (same model as sync-hooks.sh). NOTE (bash 3.2 + set -u):
# length-guard every array expansion that can be empty; "${arr[@]:-}" would
# iterate once with an empty string and append a spurious "" to TARGETS.
TARGETS=()
if [ -n "$ONLY_PROJECT" ]; then
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      [ "$n" = "$ONLY_PROJECT" ] && TARGETS+=("$n")
    done
  fi
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "project not in registry: $ONLY_PROJECT" >&2
    exit 1
  fi
else
  if [ "${#REGISTRY_NAMES[@]}" -gt 0 ]; then
    for n in "${REGISTRY_NAMES[@]}"; do
      if is_blacklisted "$n"; then
        echo "skip (blacklisted): $n"
        continue
      fi
      TARGETS+=("$n")
    done
  fi
fi

echo "Targets: ${TARGETS[*]:-(none)}"
$DRY_RUN && echo "(dry-run mode — no writes)"

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit 0; }
fi

if [ "${#TARGETS[@]}" -gt 0 ]; then
  for n in "${TARGETS[@]}"; do
    sync_one "$n"
  done
fi

echo "== done =="
$DRY_RUN || echo "Reminder: commit changes in each project (chore: sync pre-push to canonical)."
