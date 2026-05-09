#!/usr/bin/env bash
# SE Core project onboarding. Idempotent: never overwrites existing files.
#
# Reads se-core.config.json for paths and harness selection.
# Seeds:
#   - <project>/gotchas.md, <project>/context-log.md
#   - <project>/.claude/rules/se-core.md → canonical CLAUDE.md (symlink)
#   - <project>/.claude/skills/process-gate → canonical skill (symlink)
#   - <project>/.claude/skills/security-gate → canonical skill (symlink)
#   - <project>/.claude/settings.json (copied from canonical template)
#   - <project>/.claude/hooks/*.sh (9 canonical hook scripts, copied)
#   - <project>/.husky/{pre-commit,commit-msg,pre-push}     [if Node project]
#   - <project>/AGENTS.md                     → CLAUDE.md    [if Codex enabled and absent]
#   - <project>/.agents/rules/se-core.md   → canonical CLAUDE.md  [if Codex enabled]
#   - <project>/.agents/skills/process-gate → canonical skill     [if Codex enabled]
#   - <project>/.agents/skills/security-gate → canonical skill    [if Codex enabled]
#   - <project>/.codex/hooks.json and .codex/hooks/*.sh           [if Codex enabled]
# Then runs the initial Mode 1 security-gate baseline (override:
# SE_CORE_SKIP_SECURITY_BASELINE=1).
#
# Usage: onboard-project.sh <project-path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

TEMPLATES="$SOURCE_ROOT/core-rules/templates"
HUSKY_CANONICAL="$SOURCE_ROOT/core-rules/husky"
CANONICAL_RULES="$SE_CORE_ROOT/core-rules/CLAUDE.md"
CANONICAL_SKILLS_DIR="$SE_CORE_ROOT/core-rules/skills"
CANONICAL_CODEX_DIR="$SOURCE_ROOT/core-rules/codex"
CANONICAL_CLAUDE_HOOKS_DIR="$SOURCE_ROOT/core-rules/hooks"
CANONICAL_CLAUDE_SETTINGS="$TEMPLATES/claude-settings.json"

if [ $# -ne 1 ]; then
  echo "usage: $0 <project-path>" >&2
  exit 2
fi

PROJECT="$1"
[ -d "$PROJECT" ]       || { echo "not a directory: $PROJECT" >&2; exit 1; }
[ -e "$PROJECT/.git" ]  || { echo "not a git repo: $PROJECT" >&2; exit 1; }

# Sanity-check canonical sources exist before we start seeding
[ -f "$CANONICAL_RULES" ]            || { echo "canonical rules missing: $CANONICAL_RULES" >&2; exit 1; }
[ -d "$CANONICAL_SKILLS_DIR" ]       || { echo "canonical skills dir missing: $CANONICAL_SKILLS_DIR" >&2; exit 1; }
[ -d "$CANONICAL_CLAUDE_HOOKS_DIR" ] || { echo "canonical Claude hooks dir missing: $CANONICAL_CLAUDE_HOOKS_DIR" >&2; exit 1; }
[ -f "$CANONICAL_CLAUDE_SETTINGS" ]  || { echo "canonical Claude settings template missing: $CANONICAL_CLAUDE_SETTINGS" >&2; exit 1; }
if pg_has_harness codex; then
  [ -f "$CANONICAL_CODEX_DIR/hooks.json" ] || { echo "canonical Codex hooks manifest missing: $CANONICAL_CODEX_DIR/hooks.json" >&2; exit 1; }
  [ -d "$CANONICAL_CODEX_DIR/hooks" ]      || { echo "canonical Codex hooks dir missing: $CANONICAL_CODEX_DIR/hooks" >&2; exit 1; }
fi

seed_file() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    echo "skip (exists): ${dst#"$PROJECT"/}"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "created: ${dst#"$PROJECT"/}"
  fi
}

seed_executable_file() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    echo "skip (exists): ${dst#"$PROJECT"/}"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "created: ${dst#"$PROJECT"/}"
  fi
}

seed_symlink() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$link")"
  if [ -L "$link" ]; then
    local cur
    cur="$(readlink "$link")"
    if [ "$cur" = "$target" ]; then
      echo "skip (correct symlink): ${link#"$PROJECT"/}"
      return
    fi
    echo "WARN: ${link#"$PROJECT"/} symlinks to '$cur', expected '$target' — leaving as-is" >&2
    return
  fi
  if [ -e "$link" ]; then
    echo "WARN: ${link#"$PROJECT"/} exists and is not a symlink — leaving as-is" >&2
    return
  fi
  ln -s "$target" "$link"
  echo "linked: ${link#"$PROJECT"/} → $target"
}

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

seed_process_gate_config() {
  local cfg="$1" profile="$2"
  if [ -f "$cfg" ]; then
    echo "skip (exists): ${cfg#"$PROJECT"/}"
    return
  fi
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF
# Project-local process-gate overrides for $(basename "$PROJECT")
# Loaded beside the harness skill symlink.

PROCESS_GATE_STACK_PROFILE="$profile"

# Test commands — adjust to match your project. Auto-detected if blank.
PROCESS_GATE_TYPECHECK_CMD=""
PROCESS_GATE_LINT_CMD=""
PROCESS_GATE_TEST_CMD=""

# Stack-profile validators (project-local scripts)
PROCESS_GATE_STACK_VALIDATORS=()
EOF
  echo "created: ${cfg#"$PROJECT"/} ($profile)"
}

seed_codex_hooks() {
  seed_file "$CANONICAL_CODEX_DIR/hooks.json" "$PROJECT/.codex/hooks.json"
  for src in "$CANONICAL_CODEX_DIR/hooks"/*.sh; do
    seed_executable_file "$src" "$PROJECT/.codex/hooks/$(basename "$src")"
  done
  # Sibling lib/ — shared helpers consumed by every hook.
  if [ -d "$CANONICAL_CODEX_DIR/hooks/lib" ]; then
    for src in "$CANONICAL_CODEX_DIR/hooks/lib"/*.sh; do
      seed_file "$src" "$PROJECT/.codex/hooks/lib/$(basename "$src")"
    done
  fi
}

seed_claude_hooks() {
  # Mirrors seed_codex_hooks: copies the 9 canonical Claude hook scripts to
  # $PROJECT/.claude/hooks/ and seeds .claude/settings.json from the canonical
  # template. Idempotent — existing files are skipped.
  seed_file "$CANONICAL_CLAUDE_SETTINGS" "$PROJECT/.claude/settings.json"
  for src in "$CANONICAL_CLAUDE_HOOKS_DIR"/*.sh; do
    seed_executable_file "$src" "$PROJECT/.claude/hooks/$(basename "$src")"
  done
  # Sibling lib/ — shared helpers consumed by every hook.
  if [ -d "$CANONICAL_CLAUDE_HOOKS_DIR/lib" ]; then
    for src in "$CANONICAL_CLAUDE_HOOKS_DIR/lib"/*.sh; do
      seed_file "$src" "$PROJECT/.claude/hooks/lib/$(basename "$src")"
    done
  fi
}

seed_husky_hook() {
  local name="$1"
  local dst="$PROJECT/.husky/$name"
  if [ -e "$dst" ]; then
    echo "skip (exists): .husky/$name"
  else
    cp "$HUSKY_CANONICAL/$name" "$dst"
    chmod +x "$dst"
    echo "created: .husky/$name"
  fi
}

# Ensure project .gitignore carries the canonical SE Core symlink fragment.
# The four absolute-path symlinks must NOT be tracked — different developers'
# clones produce different absolute targets that conflict on cross-machine
# merges. Idempotent: detected via sentinel header, appended only if absent.
ensure_gitignore_fragment() {
  local fragment="$TEMPLATES/project.gitignore.fragment"
  local gi="$PROJECT/.gitignore"
  local sentinel="SE Core inheritance symlinks"

  if [ ! -f "$fragment" ]; then
    echo "WARN: gitignore fragment template missing at $fragment — skipping" >&2
    return
  fi

  if [ -f "$gi" ] && grep -qF "$sentinel" "$gi"; then
    echo "skip (already present): .gitignore SE Core fragment"
    return
  fi

  if [ -f "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ]; then
    printf '\n' >> "$gi"
  fi
  cat "$fragment" >> "$gi"
  echo "created: .gitignore SE Core fragment appended"
}

echo "== onboarding $PROJECT =="
echo "   se_core_root:  $SE_CORE_ROOT"
echo "   harnesses:     ${HARNESSES[*]}"

# Project root files
seed_file "$TEMPLATES/gotchas.md"     "$PROJECT/gotchas.md"
seed_file "$TEMPLATES/context-log.md" "$PROJECT/context-log.md"

# .gitignore — ensure the SE Core fragment is present BEFORE creating any symlinks
# so subsequent `git status` doesn't show them as untracked. Idempotent.
ensure_gitignore_fragment

# Defense in depth: if a previous onboard or rollout left the canonical symlinks
# tracked in git (legacy state pre-2026-05), force-untrack them now. The working-
# tree symlink stays; only the index entry is removed. Safe to re-run.
untrack_if_tracked() {
  local rel="$1"
  if [ -e "$PROJECT/.git" ] && git -C "$PROJECT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    git -C "$PROJECT" rm --cached --quiet "$rel"
    echo "untracked (legacy tracked symlink removed from index): $rel"
  fi
}
untrack_if_tracked ".claude/rules/se-core.md"
untrack_if_tracked ".claude/skills/process-gate"
untrack_if_tracked ".agents/rules/se-core.md"
untrack_if_tracked ".agents/skills/process-gate"

# Claude Code inheritance: rules + skills + hooks
seed_symlink "$CANONICAL_RULES"                       "$PROJECT/.claude/rules/se-core.md"
seed_symlink "$CANONICAL_SKILLS_DIR/process-gate"     "$PROJECT/.claude/skills/process-gate"
seed_symlink "$CANONICAL_SKILLS_DIR/security-gate"    "$PROJECT/.claude/skills/security-gate"
PROFILE="$(guess_profile "$PROJECT")"
seed_process_gate_config "$PROJECT/.claude/skills/process-gate-local/local.config.sh" "$PROFILE"
seed_claude_hooks

# Husky / git hooks (Node projects only)
if [ -f "$PROJECT/package.json" ]; then
  mkdir -p "$PROJECT/.husky"
  seed_husky_hook pre-commit
  seed_husky_hook commit-msg
  seed_husky_hook pre-push
else
  echo "info: no package.json — husky skipped. Project must enforce PR-flow guard via .githooks/ (see core-rules/inheritance.md \"Native git hooks\")."
fi

# Codex parity
if pg_has_harness codex; then
  echo "-- codex harness enabled --"
  seed_symlink "CLAUDE.md" "$PROJECT/AGENTS.md"
  seed_symlink "$CANONICAL_RULES"                    "$PROJECT/.agents/rules/se-core.md"
  seed_symlink "$CANONICAL_SKILLS_DIR/process-gate"  "$PROJECT/.agents/skills/process-gate"
  seed_symlink "$CANONICAL_SKILLS_DIR/security-gate" "$PROJECT/.agents/skills/security-gate"
  if [ -f "$PROJECT/.claude/skills/process-gate-local/local.config.sh" ] && [ ! -f "$PROJECT/.agents/skills/process-gate-local/local.config.sh" ]; then
    mkdir -p "$PROJECT/.agents/skills/process-gate-local"
    cp "$PROJECT/.claude/skills/process-gate-local/local.config.sh" "$PROJECT/.agents/skills/process-gate-local/local.config.sh"
    echo "created: .agents/skills/process-gate-local/local.config.sh (copied from Claude local config)"
  else
    seed_process_gate_config "$PROJECT/.agents/skills/process-gate-local/local.config.sh" "$PROFILE"
  fi
  seed_codex_hooks
fi

# Initial security-gate baseline (Mode 1). Idempotent — re-running on an
# unchanged tree produces the same findings JSON. Override:
# SE_CORE_SKIP_SECURITY_BASELINE=1 onboard-project.sh ...
if [ "${SE_CORE_SKIP_SECURITY_BASELINE:-0}" != "1" ] && [ -x "$CANONICAL_SKILLS_DIR/security-gate/scripts/run-baseline.sh" ]; then
  echo "-- running initial security-gate baseline (Mode 1) --"
  echo "   override: SE_CORE_SKIP_SECURITY_BASELINE=1 to skip"
  bash "$CANONICAL_SKILLS_DIR/security-gate/scripts/run-baseline.sh" "$PROJECT" --no-llm || \
    echo "WARN: baseline produced non-zero exit — review $PROJECT/audits/" >&2
fi

echo "== done =="
echo "Next:"
[ -f "$PROJECT/package.json" ] && echo "  - run install in project so husky activates (pnpm/bun/npm install)"
echo "  - add @-import line to project CLAUDE.md if not present:"
echo "      @$CANONICAL_RULES"
pg_has_harness codex && echo "  - confirm Codex hooks are enabled in \$CODEX_HOME/config.toml: [features] codex_hooks = true"
echo "  - register the project in $SE_CORE_ROOT/registry.md (chore: register <name>)"
echo "  - configure project-local skill:"
echo "      $PROJECT/.claude/skills/process-gate-local/local.config.sh"
pg_has_harness codex && echo "      $PROJECT/.agents/skills/process-gate-local/local.config.sh"
echo "  - configure security-gate profile + LLM provider:"
echo "      $PROJECT/.claude/skills/security-gate-local/local.config.sh"
pg_has_harness codex && echo "      $PROJECT/.agents/skills/security-gate-local/local.config.sh"
