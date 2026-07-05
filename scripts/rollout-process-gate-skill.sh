#!/usr/bin/env bash
# Phase-C rollout: install the canonical process-gate skill symlink in every
# registered project (skipping blacklist), preserving any existing project-local
# skill content as a backup.
#
# **Run this AFTER the canonical skill is on the main branch of the Trellis canonical clone.**
# (Until then the symlinks would dangle.)
#
# Reads trellis.config.json for paths.
# Honors `harnesses` to seed `.agents/` and root `AGENTS.md` parity when Codex enabled.
#
# Behavior per project:
#   1. If <project>/.claude/skills/process-gate/ is already a symlink to canonical: skip.
#   2. If a directory exists (project-local kit): rename to process-gate.local-backup-YYYYMMDD/.
#   3. Create symlink → canonical.
#   4. If no .claude/skills/process-gate-local/local.config.sh: seed a minimal one
#      with stack profile auto-guessed from project structure.
#   5. Same flow for .agents/skills/process-gate/ when codex harness enabled.
#      Also seeds root AGENTS.md and .agents/rules/trellis.md when absent.
#   6. Stage changes; do NOT commit (you commit per project, with project-specific
#      message + reviewing the local.config.sh seeded values).
#
# Usage:
#   rollout-process-gate-skill.sh                 # interactive, all projects
#   rollout-process-gate-skill.sh --dry-run       # show plan only
#   rollout-process-gate-skill.sh --yes           # non-interactive
#   rollout-process-gate-skill.sh <name>          # single project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

CANONICAL_RULES="$TRELLIS_ROOT/core-rules/CLAUDE.md"
CANONICAL_SKILL="$TRELLIS_ROOT/core-rules/skills/process-gate"
[ -f "$CANONICAL_RULES" ] || {
  echo "canonical rules missing at $CANONICAL_RULES" >&2
  exit 1
}
[ -d "$CANONICAL_SKILL" ] || {
  echo "canonical skill missing at $CANONICAL_SKILL" >&2
  echo "is the parent branch merged? run from main of the Trellis canonical clone." >&2
  exit 1
}

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""
DATE_TAG="$(date +%Y%m%d)"
SEEDED_LOCAL_CONFIGS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

# Best-effort stack-profile guess
guess_profile() {
  local p="$1"
  if [ -f "$p/pnpm-workspace.yaml" ] || ([ -f "$p/package.json" ] && grep -q '"workspaces"' "$p/package.json" 2>/dev/null); then
    echo "monorepo-pnpm"; return
  fi
  if [ -f "$p/next.config.ts" ] || [ -f "$p/next.config.js" ] || [ -f "$p/next.config.mjs" ]; then
    echo "web-next"; return
  fi
  if [ -f "$p/vite.config.ts" ] || [ -f "$p/vite.config.js" ]; then
    echo "web-vite"; return
  fi
  if [ -f "$p/Cargo.toml" ] || [ -f "$p/go.mod" ] || [ -f "$p/pyproject.toml" ]; then
    echo "native-other"; return
  fi
  if [ -d "$p/Assets" ] && [ -d "$p/ProjectSettings" ]; then
    echo "unity"; return
  fi
  echo "n-a"
}

seed_local_config() {
  local p="$1" profile="$2" harness_dir="${3:-.claude}" cfg_dir
  cfg_dir="$p/$harness_dir/skills/process-gate-local"
  local cfg="$cfg_dir/local.config.sh"
  if [ -f "$cfg" ]; then
    echo "  skip (local config exists): ${cfg#"$p"/}"
    return
  fi
  $DRY_RUN && { echo "  + would seed: $harness_dir/skills/process-gate-local/local.config.sh ($profile)"; return; }
  mkdir -p "$cfg_dir"
  # Track that we seeded a new local config in this run so the footer can warn about it.
  SEEDED_LOCAL_CONFIGS+=("${cfg#"$PROJECTS_ROOT"/}")
  cat > "$cfg" <<EOF
# Project-local process-gate overrides for $(basename "$p")
# Loaded by canonical scripts via:
#   source "\$PROJECT_DIR/$harness_dir/skills/process-gate-local/local.config.sh"
# (Symlink at $harness_dir/skills/process-gate points at canonical and is read-only.
#  Local config lives alongside in process-gate-local/.)

PROCESS_GATE_STACK_PROFILE="$profile"

# Test commands — adjust to match your project. Auto-detected if blank.
PROCESS_GATE_TYPECHECK_CMD=""
PROCESS_GATE_LINT_CMD=""
PROCESS_GATE_TEST_CMD=""

# PR-size thresholds (defaults: 400 / 800)
# PROCESS_GATE_PR_SIZE_LIMIT=400
# PROCESS_GATE_PR_SIZE_HARD=800

# Project EPM doc — gate warns if process-trigger paths change without it updated
# PROCESS_GATE_PROJECT_EPM="docs/EPM.md"

# Stack-profile validators (project-local scripts)
PROCESS_GATE_STACK_VALIDATORS=()

# After review, commit with: chore: rollout Trellis process-gate skill
EOF
  echo "  created: $harness_dir/skills/process-gate-local/local.config.sh ($profile)"
}

install_symlink() {
  local p="$1" rel="$2" target="$3"
  local link="$p/$rel" cur
  mkdir -p "$(dirname "$link")"

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
    echo "  WARN: $rel exists and is not a symlink — leaving" >&2
    return
  fi
  $DRY_RUN && { echo "  + would link: $rel → $target"; return; }
  ln -s "$target" "$link"
  echo "  linked: $rel → $target"
}

install_skill_symlink() {
  local p="$1" rel="$2" target="$CANONICAL_SKILL"
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

  local profile
  profile="$(guess_profile "$p")"
  echo "  stack profile guess: $profile"

  install_skill_symlink "$p" ".claude/skills/process-gate"
  seed_local_config "$p" "$profile" ".claude"

  # Codex parity — first-class when the parent config enables the harness.
  if pg_has_harness codex; then
    install_symlink "$p" "AGENTS.md" "CLAUDE.md"
    install_symlink "$p" ".agents/rules/trellis.md" "$CANONICAL_RULES"
    install_skill_symlink "$p" ".agents/skills/process-gate"
    if [ -f "$p/.claude/skills/process-gate-local/local.config.sh" ] && [ ! -f "$p/.agents/skills/process-gate-local/local.config.sh" ]; then
      $DRY_RUN && {
        echo "  + would copy: .agents/skills/process-gate-local/local.config.sh from Claude local config"
        return
      }
      mkdir -p "$p/.agents/skills/process-gate-local"
      cp "$p/.claude/skills/process-gate-local/local.config.sh" "$p/.agents/skills/process-gate-local/local.config.sh"
      echo "  created: .agents/skills/process-gate-local/local.config.sh (copied from Claude local config)"
    else
      seed_local_config "$p" "$profile" ".agents"
    fi
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

if [ "${#SEEDED_LOCAL_CONFIGS[@]}" -gt 0 ]; then
  echo "!! Newly seeded local.config.sh files in this run:" >&2
  for c in "${SEEDED_LOCAL_CONFIGS[@]}"; do echo "   - $c" >&2; done
  echo "   These contain DEFAULT skeleton values. Before committing:" >&2
  echo "   - customize stack profile, test commands, validators per project" >&2
  echo "   - if main already carries a customized version, REBASE and discard" >&2
  echo "     the seeded skeleton — never replace customized config with the seed." >&2
  echo >&2
fi

echo "Per-project next steps:"
echo "  1. cd <project>"
echo "  2. The four canonical symlinks (.claude/rules/trellis.md, .claude/skills/process-gate,"
echo "     .agents/rules/trellis.md, .agents/skills/process-gate) are gitignored — do NOT"
echo "     stage them. They live on this machine only; teammates regenerate via onboard-project.sh."
echo "  3. Review .claude/skills/process-gate-local/local.config.sh and, if Codex-enabled,"
echo "     .agents/skills/process-gate-local/local.config.sh — customize stack profile,"
echo "     test commands, validators. Commit local.config.sh files in a SEPARATE PR titled"
echo "     'chore: customize process-gate local.config.sh' with the customizations applied —"
echo "     never commit the seeded skeleton over an existing customized config."
echo "  4. For projects with backed-up content: review .claude/skills/process-gate.local-backup-$DATE_TAG/"
echo "     and migrate any keepers into process-gate-local/ as scripts or reference docs."
echo "  5. Verify the project's .gitignore contains the Trellis symlink block"
echo "     (.claude/rules/trellis.md, .claude/skills/process-gate, .agents/rules/trellis.md,"
echo "     .agents/skills/process-gate). If absent or stale, re-run onboard-project.sh"
echo "     on the project — it regenerates the block from the symlinks it creates."
