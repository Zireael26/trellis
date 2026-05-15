#!/usr/bin/env bash
# Trellis project onboarding. Idempotent: never overwrites existing files.
#
# Reads trellis.config.json for paths and harness selection.
# Seeds:
#   - <project>/gotchas.md, <project>/context-log.md
#   - <project>/.claude/rules/trellis.md → canonical CLAUDE.md (symlink)
#   - <project>/.claude/skills/{process-gate,security-gate,clarify,spec,plan,tasks,analyze}
#       → canonical skills (symlinks; always-on: process-gate + security-gate,
#         opt-in pipeline: clarify → spec → plan → tasks → analyze)
#   - <project>/.claude/commands/{primer,primer-refresh,primer-check}.md
#       → canonical commands (symlinks; feature primer system)
#   - <project>/.claude/primers/INDEX.md (copied from canonical template; opt-in directory)
#   - <project>/.claude/settings.json (copied from canonical template)
#   - <project>/.claude/hooks/*.sh (9 canonical hook scripts, copied)
#   - <project>/.husky/{pre-commit,commit-msg,pre-push}     [if Node project]
#   - <project>/AGENTS.md                     → CLAUDE.md    [if Codex enabled and absent]
#   - <project>/.agents/rules/trellis.md   → canonical CLAUDE.md  [if Codex enabled]
#   - <project>/.agents/skills/{process-gate,security-gate,clarify,spec,plan,tasks,analyze}
#       → canonical skills (symlinks; mirrors .claude/skills/)        [if Codex enabled]
#   - <project>/.agents/commands/{primer,primer-refresh,primer-check}.md
#       → canonical commands (symlinks; mirrors .claude/commands/)    [if Codex enabled]
#   - <project>/.agents/primers/INDEX.md (copied; mirrors .claude/primers/)  [if Codex enabled]
#   - <project>/.codex/hooks.json and .codex/hooks/*.sh           [if Codex enabled]
# Then runs the initial Mode 1 security-gate baseline (override:
# TRELLIS_SKIP_SECURITY_BASELINE=1).
#
# Usage: onboard-project.sh <project-path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/config-load.sh
. "$SCRIPT_DIR/lib/config-load.sh"

TEMPLATES="$SOURCE_ROOT/core-rules/templates"
HUSKY_CANONICAL="$SOURCE_ROOT/core-rules/husky"
CANONICAL_RULES="$TRELLIS_ROOT/core-rules/CLAUDE.md"
CANONICAL_SKILLS_DIR="$TRELLIS_ROOT/core-rules/skills"
CANONICAL_COMMANDS_DIR="$TRELLIS_ROOT/core-rules/commands"
CANONICAL_PRIMER_INDEX_TEMPLATE="$TRELLIS_ROOT/core-rules/commands/templates/primer-index-template.md"
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
[ -f "$CANONICAL_RULES" ]                  || { echo "canonical rules missing: $CANONICAL_RULES" >&2; exit 1; }
[ -d "$CANONICAL_SKILLS_DIR" ]             || { echo "canonical skills dir missing: $CANONICAL_SKILLS_DIR" >&2; exit 1; }
[ -d "$CANONICAL_COMMANDS_DIR" ]           || { echo "canonical commands dir missing: $CANONICAL_COMMANDS_DIR" >&2; exit 1; }
[ -f "$CANONICAL_PRIMER_INDEX_TEMPLATE" ]  || { echo "canonical primer INDEX template missing: $CANONICAL_PRIMER_INDEX_TEMPLATE" >&2; exit 1; }
[ -d "$CANONICAL_CLAUDE_HOOKS_DIR" ]       || { echo "canonical Claude hooks dir missing: $CANONICAL_CLAUDE_HOOKS_DIR" >&2; exit 1; }
[ -f "$CANONICAL_CLAUDE_SETTINGS" ]        || { echo "canonical Claude settings template missing: $CANONICAL_CLAUDE_SETTINGS" >&2; exit 1; }
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

CANONICAL_PRESETS_DIR="$SOURCE_ROOT/core-rules/presets"

# Read this project's preset selection from <project>/.trellis.config.json or
# <project>/trellis.config.json (first match wins). The file is OPTIONAL; if
# absent, the project gets no presets and seed_presets is a no-op.
# Echoes preset names one per line; empty output = no presets.
read_project_presets() {
  for cand in "$PROJECT/.trellis.config.json" "$PROJECT/trellis.config.json"; do
    if [ -f "$cand" ]; then
      jq -r '.presets // [] | .[]' "$cand" 2>/dev/null
      return 0
    fi
  done
  return 0
}

# Seed preset symlinks under .claude/rules/ and (if Codex enabled) .agents/rules/.
# Each preset symlink is named preset-<name>.md and points at the canonical
# core-rules/presets/<name>.md. Refuses to seed for an unknown preset name.
seed_presets() {
  local presets harness_dir name target link
  presets="$(read_project_presets)"
  if [ -z "$presets" ]; then
    echo "info: no presets declared for this project (no .trellis.config.json or empty .presets array)"
    return 0
  fi
  for name in $presets; do
    # Re-validate the name even though the schema also enforces it. The schema
    # validation runs against the *parent* config in config-load.sh; the
    # per-project config that supplies this preset name does NOT pass through
    # that validator, so a malformed name (path traversal, whitespace, etc.)
    # would otherwise reach the filesystem unchecked.
    if ! printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; then
      echo "WARN: skipping malformed preset name '$name' (must match ^[a-z0-9][a-z0-9-]*[a-z0-9]\$)" >&2
      continue
    fi
    target="$CANONICAL_PRESETS_DIR/$name.md"
    if [ ! -f "$target" ]; then
      echo "WARN: preset '$name' declared but $target does not exist — skipping" >&2
      continue
    fi
    seed_symlink "$target" "$PROJECT/.claude/rules/preset-$name.md"
    if pg_has_harness codex; then
      seed_symlink "$target" "$PROJECT/.agents/rules/preset-$name.md"
    fi
  done
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

# Ensure project .gitignore carries the canonical Trellis symlink fragment.
# Absolute-path symlinks must NOT be tracked — different developers' clones
# produce different absolute targets that conflict on cross-machine merges.
# Idempotent: detected via the current fragment's sentinel header.
# The sentinel includes a version marker ('5-skill set') so a fragment update
# that adds new symlinks (e.g., Phase B added spec/plan/tasks beyond the
# original process-gate) triggers an append on re-onboard. Older blocks remain
# in place; duplicate gitignore entries are harmless. Operators may clean up
# legacy blocks manually if desired.
ensure_gitignore_fragment() {
  local fragment="$TEMPLATES/project.gitignore.fragment"
  local gi="$PROJECT/.gitignore"
  local current_sentinel="Trellis inheritance symlinks (7-skill set + presets + primer commands)"
  local any_legacy_marker="Trellis inheritance symlinks"
  local had_any_legacy=false

  if [ ! -f "$fragment" ]; then
    echo "WARN: gitignore fragment template missing at $fragment — skipping" >&2
    return
  fi

  if [ -f "$gi" ] && grep -qF "$current_sentinel" "$gi"; then
    echo "skip (already present): .gitignore Trellis fragment ($current_sentinel)"
    return
  fi

  if [ -f "$gi" ] && grep -qF "$any_legacy_marker" "$gi"; then
    had_any_legacy=true
  fi

  if [ -f "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ]; then
    printf '\n' >> "$gi"
  fi
  cat "$fragment" >> "$gi"

  if $had_any_legacy; then
    echo "note: legacy pre-7-skill Trellis fragment detected in .gitignore." >&2
    echo "      the new (7-skill set) block was appended alongside; duplicate" >&2
    echo "      gitignore entries are harmless. Remove the older block manually" >&2
    echo "      once you've confirmed the new one covers your symlinks." >&2
  fi
  echo "created: .gitignore Trellis fragment appended ($current_sentinel)"
}

echo "== onboarding $PROJECT =="
echo "   trellis_root:  $TRELLIS_ROOT"
echo "   harnesses:     ${HARNESSES[*]}"

# Project root files
seed_file "$TEMPLATES/gotchas.md"     "$PROJECT/gotchas.md"
seed_file "$TEMPLATES/context-log.md" "$PROJECT/context-log.md"

# .gitignore — ensure the Trellis fragment is present BEFORE creating any symlinks
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
untrack_if_tracked ".claude/rules/trellis.md"
untrack_if_tracked ".claude/skills/process-gate"
untrack_if_tracked ".claude/skills/security-gate"
untrack_if_tracked ".claude/skills/clarify"
untrack_if_tracked ".claude/skills/spec"
untrack_if_tracked ".claude/skills/plan"
untrack_if_tracked ".claude/skills/tasks"
untrack_if_tracked ".claude/skills/analyze"
untrack_if_tracked ".claude/commands/primer.md"
untrack_if_tracked ".claude/commands/primer-refresh.md"
untrack_if_tracked ".claude/commands/primer-check.md"
untrack_if_tracked ".agents/rules/trellis.md"
untrack_if_tracked ".agents/skills/process-gate"
untrack_if_tracked ".agents/skills/security-gate"
untrack_if_tracked ".agents/skills/clarify"
untrack_if_tracked ".agents/skills/spec"
untrack_if_tracked ".agents/skills/plan"
untrack_if_tracked ".agents/skills/tasks"
untrack_if_tracked ".agents/skills/analyze"
untrack_if_tracked ".agents/commands/primer.md"
untrack_if_tracked ".agents/commands/primer-refresh.md"
untrack_if_tracked ".agents/commands/primer-check.md"

# Claude Code inheritance: rules + skills + hooks.
# Canonical skills shipped today: process-gate, security-gate (always on),
# plus the opt-in clarify → spec → plan → tasks → analyze pipeline (skills
# surface in the agent's skill picker but never run automatically; operators
# invoke them by name when scaffolding a non-trivial feature). See
# core-rules/skills/spec/SKILL.md for the "when to use" decision rule on the
# pipeline as a whole, core-rules/skills/clarify/SKILL.md for the front-step
# question pass, and core-rules/skills/analyze/SKILL.md for the tail-step
# drift check.
seed_symlink "$CANONICAL_RULES"                       "$PROJECT/.claude/rules/trellis.md"
seed_symlink "$CANONICAL_SKILLS_DIR/process-gate"     "$PROJECT/.claude/skills/process-gate"
seed_symlink "$CANONICAL_SKILLS_DIR/security-gate"    "$PROJECT/.claude/skills/security-gate"
seed_symlink "$CANONICAL_SKILLS_DIR/clarify"          "$PROJECT/.claude/skills/clarify"
seed_symlink "$CANONICAL_SKILLS_DIR/spec"             "$PROJECT/.claude/skills/spec"
seed_symlink "$CANONICAL_SKILLS_DIR/plan"             "$PROJECT/.claude/skills/plan"
seed_symlink "$CANONICAL_SKILLS_DIR/tasks"            "$PROJECT/.claude/skills/tasks"
seed_symlink "$CANONICAL_SKILLS_DIR/analyze"          "$PROJECT/.claude/skills/analyze"

# Canonical commands — explicit user invocations (primer system today).
seed_symlink "$CANONICAL_COMMANDS_DIR/primer.md"          "$PROJECT/.claude/commands/primer.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/primer-refresh.md"  "$PROJECT/.claude/commands/primer-refresh.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/primer-check.md"    "$PROJECT/.claude/commands/primer-check.md"

# Primer INDEX — opt-in feature primer system. INDEX is project-state (copied,
# not symlinked) so each project owns its primer list. Empty INDEX = "primers
# bootstrapped, no primers yet" which is the correct v1 state.
seed_file "$CANONICAL_PRIMER_INDEX_TEMPLATE" "$PROJECT/.claude/primers/INDEX.md"

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
  seed_symlink "$CANONICAL_RULES"                    "$PROJECT/.agents/rules/trellis.md"
  seed_symlink "$CANONICAL_SKILLS_DIR/process-gate"  "$PROJECT/.agents/skills/process-gate"
  seed_symlink "$CANONICAL_SKILLS_DIR/security-gate" "$PROJECT/.agents/skills/security-gate"
  seed_symlink "$CANONICAL_SKILLS_DIR/clarify"       "$PROJECT/.agents/skills/clarify"
  seed_symlink "$CANONICAL_SKILLS_DIR/spec"          "$PROJECT/.agents/skills/spec"
  seed_symlink "$CANONICAL_SKILLS_DIR/plan"          "$PROJECT/.agents/skills/plan"
  seed_symlink "$CANONICAL_SKILLS_DIR/tasks"         "$PROJECT/.agents/skills/tasks"
  seed_symlink "$CANONICAL_SKILLS_DIR/analyze"       "$PROJECT/.agents/skills/analyze"
  seed_symlink "$CANONICAL_COMMANDS_DIR/primer.md"         "$PROJECT/.agents/commands/primer.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/primer-refresh.md" "$PROJECT/.agents/commands/primer-refresh.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/primer-check.md"   "$PROJECT/.agents/commands/primer-check.md"
  seed_file    "$CANONICAL_PRIMER_INDEX_TEMPLATE"          "$PROJECT/.agents/primers/INDEX.md"
  if [ -f "$PROJECT/.claude/skills/process-gate-local/local.config.sh" ] && [ ! -f "$PROJECT/.agents/skills/process-gate-local/local.config.sh" ]; then
    mkdir -p "$PROJECT/.agents/skills/process-gate-local"
    cp "$PROJECT/.claude/skills/process-gate-local/local.config.sh" "$PROJECT/.agents/skills/process-gate-local/local.config.sh"
    echo "created: .agents/skills/process-gate-local/local.config.sh (copied from Claude local config)"
  else
    seed_process_gate_config "$PROJECT/.agents/skills/process-gate-local/local.config.sh" "$PROFILE"
  fi
  seed_codex_hooks
fi

# Optional preset layering — opt-in per project via <project>/.trellis.config.json
# (or trellis.config.json) with a "presets": [...] array. No-op if the file is
# absent or the array is empty. Seeds preset-<name>.md symlinks under .claude/
# rules/ and (if Codex enabled) .agents/rules/.
seed_presets

# Initial security-gate baseline (Mode 1). Idempotent — re-running on an
# unchanged tree produces the same findings JSON. Override:
# TRELLIS_SKIP_SECURITY_BASELINE=1 onboard-project.sh ...
if [ "${TRELLIS_SKIP_SECURITY_BASELINE:-0}" != "1" ] && [ -x "$CANONICAL_SKILLS_DIR/security-gate/scripts/run-baseline.sh" ]; then
  echo "-- running initial security-gate baseline (Mode 1) --"
  echo "   override: TRELLIS_SKIP_SECURITY_BASELINE=1 to skip"
  bash "$CANONICAL_SKILLS_DIR/security-gate/scripts/run-baseline.sh" "$PROJECT" --no-llm || \
    echo "WARN: baseline produced non-zero exit — review $PROJECT/audits/" >&2
fi

echo "== done =="
echo "Next:"
[ -f "$PROJECT/package.json" ] && echo "  - run install in project so husky activates (pnpm/bun/npm install)"
echo "  - add @-import line to project CLAUDE.md if not present:"
echo "      @$CANONICAL_RULES"
pg_has_harness codex && echo "  - confirm Codex hooks are enabled in \$CODEX_HOME/config.toml: [features] codex_hooks = true"
echo "  - register the project in $TRELLIS_ROOT/registry.md (chore: register <name>)"
echo "  - configure project-local skill:"
echo "      $PROJECT/.claude/skills/process-gate-local/local.config.sh"
pg_has_harness codex && echo "      $PROJECT/.agents/skills/process-gate-local/local.config.sh"
echo "  - configure security-gate profile + LLM provider:"
echo "      $PROJECT/.claude/skills/security-gate-local/local.config.sh"
pg_has_harness codex && echo "      $PROJECT/.agents/skills/security-gate-local/local.config.sh"
