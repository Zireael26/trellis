#!/usr/bin/env bash
# Sync canonical hook scripts to all registered projects, AND reconcile each
# project's .claude/settings.json .hooks wiring with the canonical baseline.
#
# Reads trellis.config.json for paths.
# Reads registry.md for the project list (rows in "Active projects" table).
# Skips blacklisted projects.
#
# Two things happen per project:
#   1. Hook FILE copies — every canonical .sh under core-rules/hooks/ (and its
#      lib/ siblings) is sha-compared and overwritten if stale.
#   2. settings.json .hooks RECONCILE — the project's .hooks object is rebuilt
#      from the canonical .hooks baseline (core-rules/templates/claude-settings
#      .json) PLUS any project-specific hook block re-appended verbatim into its
#      original event array. A block is project-specific iff none of its command
#      basenames appear in the canonical command-basename set. Every non-.hooks
#      key (permissions, effortLevel, …) is preserved untouched. Projects with
#      no settings.json are skipped with a note (run onboard-project.sh first) —
#      this script operates on existing projects and never creates settings.json.
#
# Skill symlinks are not synced — they are symlinks to canonical and
# update automatically. This script handles only the .sh hook *copies*
# under <project>/.claude/hooks/ plus the settings.json .hooks wiring.
#
# Usage:
#   sync-hooks.sh                  # interactive: confirm before each project
#   sync-hooks.sh --dry-run        # show what would change, no writes
#   sync-hooks.sh --yes            # non-interactive, sync everywhere
#   sync-hooks.sh <name>           # only that project (must be in registry)
#   sync-hooks.sh --from-main-only # refuse to run from a worktree / detached HEAD
#
# Provenance: every run prints SOURCE_ROOT, HEAD SHA, and the SHA of one
# bellwether hook before touching any project. The 2026-05-09 cross-project
# sync silently used a stale source (pre-May-8 canonical) and missed the
# context-log hooks; see audits/2026-05-11-sync-tool-rca.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"
# shellcheck source=lib/blacklist-parser.sh
. "$SCRIPT_DIR/lib/blacklist-parser.sh"
# shellcheck source=lib/settings-hooks-merge.sh
. "$SCRIPT_DIR/lib/settings-hooks-merge.sh"

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

CANONICAL_HOOKS_DIR="$SOURCE_ROOT/core-rules/hooks"
# Canonical .hooks baseline lives in the settings template (same path
# rollout-settings.sh resolves via TRELLIS_ROOT). Used by the settings.json
# .hooks reconcile step at the end of sync_one.
CANONICAL_SETTINGS_TEMPLATE="$TRELLIS_ROOT/core-rules/templates/claude-settings.json"
REGISTRY="$TRELLIS_ROOT/registry.md"
BLACKLIST="$TRELLIS_ROOT/blacklist.md"

[ -d "$CANONICAL_HOOKS_DIR" ] || { echo "canonical hooks dir missing: $CANONICAL_HOOKS_DIR" >&2; exit 1; }
[ -f "$REGISTRY" ]            || { echo "registry.md missing: $REGISTRY" >&2; exit 1; }
# jq is required for the settings.json .hooks reconcile (config-load already
# checked it, but be explicit since this script now depends on it directly).
command -v jq >/dev/null 2>&1 || { echo "jq required for settings reconcile" >&2; exit 1; }
[ -f "$CANONICAL_SETTINGS_TEMPLATE" ] || { echo "canonical settings template missing: $CANONICAL_SETTINGS_TEMPLATE" >&2; exit 1; }

# --- Provenance breadcrumbs ---
# Loudly identify the source the sync is reading from. The 2026-05-09 incident
# was a stale source that silently shipped pre-May-8 hooks to every project;
# logging this up front makes that class of bug visible in retrospect.
SOURCE_HEAD="(no git)"
if command -v git >/dev/null 2>&1 && git -C "$SOURCE_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD)"
fi
BELLWETHER="$CANONICAL_HOOKS_DIR/session-context.sh"
BELLWETHER_SHA="(missing)"
[ -f "$BELLWETHER" ] && BELLWETHER_SHA="$(shasum -a 256 "$BELLWETHER" | awk '{print $1}')"

echo "Source:        $SOURCE_ROOT"
echo "Source HEAD:   $SOURCE_HEAD"
echo "Bellwether:    session-context.sh sha=${BELLWETHER_SHA:0:12}"

# Worktree / stale-source guard.
case "$SOURCE_ROOT" in
  */.claude/worktrees/*)
    if $FROM_MAIN_ONLY; then
      echo "refusing to run: SOURCE_ROOT is inside a worktree and --from-main-only is set" >&2
      exit 1
    fi
    echo "WARNING: SOURCE_ROOT is inside a worktree (.claude/worktrees/...) — pass --from-main-only to refuse this configuration." >&2
    ;;
esac

# Linked-worktree guard (generalizes the path check above): a linked worktree
# whose path is NOT under .claude/worktrees/ — e.g. a sibling dir — is just as
# stale-prone. A linked worktree's --git-dir is <main>/.git/worktrees/<name>;
# the main work tree's is a plain .git. This catches the path-pattern-miss case.
if command -v git >/dev/null 2>&1 \
   && git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  __sh_gitdir="$(git -C "$SOURCE_ROOT" rev-parse --git-dir 2>/dev/null || true)"
  case "$__sh_gitdir" in
    */worktrees/*)
      if $FROM_MAIN_ONLY; then
        echo "refusing to run: SOURCE_ROOT is a linked git worktree and --from-main-only is set" >&2
        exit 1
      fi
      echo "WARNING: SOURCE_ROOT is a linked git worktree — pass --from-main-only to refuse this configuration." >&2
      ;;
  esac
fi

# Detached-HEAD guard: --from-main-only promises to refuse a detached HEAD too
# (a detached source is as stale-prone as a worktree). symbolic-ref -q fails on
# a detached HEAD; only enforce when the flag is set and SOURCE_ROOT is a repo.
if $FROM_MAIN_ONLY && command -v git >/dev/null 2>&1 \
   && git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && ! git -C "$SOURCE_ROOT" symbolic-ref -q HEAD >/dev/null 2>&1; then
  echo "refusing to run: SOURCE_ROOT HEAD is detached and --from-main-only is set" >&2
  exit 1
fi

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
  if [ ! -d "$proj/.claude/hooks" ]; then
    # Single-project explicit invocation is treated as opt-in to onboarding.
    # Bulk runs still skip silently so a stale project does not get a fresh
    # hook stack by accident.
    if [ -n "$ONLY_PROJECT" ] && [ "$ONLY_PROJECT" = "$name" ]; then
      echo "  + creating .claude/hooks/ (explicit single-project run)"
      $DRY_RUN || mkdir -p "$proj/.claude/hooks"
    else
      echo "skip (no .claude/hooks/): $name"
      return
    fi
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

  # --- settings.json .hooks reconcile (Gap A) -------------------------------
  # Bring the project's .hooks wiring up to the canonical baseline while
  # preserving project-specific blocks and every non-.hooks key. The
  # load-bearing merge is reconcile_settings_hooks() in lib/settings-hooks-
  # merge.sh; here we own change-detection + DRY_RUN + the temp-file write.
  local settings="$proj/.claude/settings.json"
  if [ ! -f "$settings" ]; then
    # sync-hooks operates on existing projects only — never create settings.json.
    echo "  note: settings.json missing — run onboard-project.sh first (skipping settings reconcile)"
  else
    # Non-fatal per project: a malformed settings.json that makes jq error must
    # NOT abort the whole fleet sync. Capture the reconcile status explicitly and
    # skip ONLY this project's settings on failure (the rest of the run, and this
    # project's hook-file copies above, still stand).
    local merged tmp_err
    tmp_err="$(mktemp)"
    if ! merged="$(reconcile_settings_hooks "$CANONICAL_SETTINGS_TEMPLATE" "$settings" 2>"$tmp_err")"; then
      echo "  WARN: settings reconcile failed (skipping settings for this project): $(cat "$tmp_err")" >&2
    else
      # Change-detection: only write if the canonicalized merged differs from
      # current (mirrors rollout-settings.sh idiom).
      if printf '%s' "$merged" | jq -S . | diff -q - <(jq -S . "$settings") >/dev/null 2>&1; then
        : # settings already current — no change
      else
        changed=$((changed+1))
        if $DRY_RUN; then
          echo "  ~ would update settings.json .hooks (diff below)"
          # diff returns 1 when the inputs differ — which is exactly when this
          # line runs — so `|| true` keeps pipefail+set -e from aborting the run
          # at the first changed project (defeating --dry-run).
          diff <(jq -S '.hooks' "$settings") <(printf '%s' "$merged" | jq -S '.hooks') | sed 's/^/    /' || true
        else
          echo "  ~ updating settings.json .hooks"
          # Non-fatal write: a printf/mv failure (disk full, perms) must not
          # abort the whole fleet run either — WARN + skip this project's
          # settings, matching the reconcile-failure branch above.
          if printf '%s\n' "$merged" > "$settings.tmp" && mv "$settings.tmp" "$settings"; then
            :
          else
            echo "  WARN: settings.json write failed (skipping settings for this project)" >&2
            rm -f "$settings.tmp"
          fi
        fi
      fi
    fi
    rm -f "$tmp_err"
  fi

  if [ "$changed" -eq 0 ]; then
    echo "  (in sync)"
  fi
}

# Filter target list. NOTE (bash 3.2 + set -u): every array expansion that can be
# empty must be length-guarded — an empty registry/blacklist/target list would
# otherwise trip "unbound variable". Use a `[ ${#arr[@]} -gt 0 ] && for` guard
# (NOT "${arr[@]:-}", which iterates once with an empty string and would append
# a spurious "" element to TARGETS).
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
$DRY_RUN || echo "Reminder: commit changes in each project (chore: sync hooks to canonical)."
