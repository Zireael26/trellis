#!/usr/bin/env bash
# Trellis project onboarding. Idempotent: never overwrites existing files.
#
# Reads trellis.config.json for paths and harness selection.
# Seeds:
#   - <project>/gotchas.md, <project>/context-log.md
#   - <project>/.claude/rules/trellis.md → canonical CLAUDE.md (symlink)
#   - <project>/.claude/skills/{process-gate,security-gate,clarify,spec,plan,tasks,analyze,execute,brainstorming,orchestrate,debrief}
#       → canonical skills (symlinks; always-on: process-gate + security-gate,
#         opt-in pipeline: clarify → spec → plan → tasks → analyze,
#         capability-gated dynamic-workflow kit: orchestrate)
#   - <project>/.claude/commands/{primer,primer-refresh,primer-check,explore,autonomy,surgical}.md
#       → canonical commands (symlinks; feature primer system + /explore + /autonomy + /surgical)
#   - <project>/.claude/agents/codex-worker.md → canonical blocking worker agent (symlink)
#   - <project>/.claude/primers/INDEX.md (copied from canonical template; opt-in directory)
#   - <project>/.claude/settings.json (copied from canonical template)
#   - <project>/.claude/hooks/*.sh (9 canonical hook scripts, copied)
#   - <project>/.husky/{pre-commit,commit-msg,pre-push}     [if Node project]
#
# Shared "agents/" surface (Codex reads this):
#   - <project>/AGENTS.md                     → CLAUDE.md    [if codex enabled, and absent]
#   - <project>/.agents/rules/trellis.md   → canonical CLAUDE.md  [if codex]
#   - <project>/.agents/skills/{process-gate,security-gate,clarify,spec,plan,tasks,analyze,execute,brainstorming,orchestrate,debrief}
#       → canonical skills (symlinks; mirrors .claude/skills/)        [if codex]
#   - <project>/.agents/primers/INDEX.md (copied; mirrors .claude/primers/)  [if codex]
#   - <project>/.agents/workflows/{primer,primer-refresh,primer-check,explore,surgical}.md
#       (tracked copies; workflow aliases remain portable across teammates)  [if codex]
#   - <project>/.agents/skills/process-gate-local/local.config.sh (copy of Claude local config)
#                                                                     [if codex]
#
# Codex-only surface:
#   - <project>/.agents/commands/{primer,primer-refresh,primer-check,explore,autonomy,surgical}.md
#       → canonical commands (Codex reads commands/)  [if codex]
#   - <project>/.codex/hooks.json and .codex/hooks/*.sh           [if codex]
#
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
GITHOOKS_CANONICAL="$SOURCE_ROOT/core-rules/githooks"
CANONICAL_RULES="$TRELLIS_ROOT/core-rules/CLAUDE.md"
CANONICAL_SKILLS_DIR="$TRELLIS_ROOT/core-rules/skills"
CANONICAL_COMMANDS_DIR="$TRELLIS_ROOT/core-rules/commands"
CANONICAL_AGENTS_DIR="$TRELLIS_ROOT/core-rules/agents"
CANONICAL_PRIMER_INDEX_TEMPLATE="$TRELLIS_ROOT/core-rules/commands/templates/primer-index-template.md"
CANONICAL_CODEX_DIR="$SOURCE_ROOT/core-rules/codex"
CANONICAL_CLAUDE_HOOKS_DIR="$SOURCE_ROOT/core-rules/hooks"
CANONICAL_REVIEWER_LIB_DIR="$SOURCE_ROOT/core-rules/hooks/lib"
REVIEWER_CORES="code-reviewer.sh ui-verify-core.sh"
CANONICAL_CLAUDE_SETTINGS="$TEMPLATES/claude-settings.json"

# Accumulator: every symlink seed_symlink() creates whose target is an absolute
# path under $TRELLIS_ROOT. These — and ONLY these — must be gitignored (their
# machine-specific targets conflict on cross-machine merges). write_gitignore_block
# reads this at the end of the run to regenerate the project's .gitignore block.
# Relative-target symlinks (e.g. AGENTS.md → CLAUDE.md) are deliberately excluded
# so they stay tracked.
IGNORE_PATHS=()

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
[ -f "$CANONICAL_AGENTS_DIR/codex-worker.md" ] || { echo "canonical agent missing: $CANONICAL_AGENTS_DIR/codex-worker.md" >&2; exit 1; }
[ -f "$CANONICAL_PRIMER_INDEX_TEMPLATE" ]  || { echo "canonical primer INDEX template missing: $CANONICAL_PRIMER_INDEX_TEMPLATE" >&2; exit 1; }
[ -d "$CANONICAL_CLAUDE_HOOKS_DIR" ]       || { echo "canonical Claude hooks dir missing: $CANONICAL_CLAUDE_HOOKS_DIR" >&2; exit 1; }
[ -f "$CANONICAL_CLAUDE_SETTINGS" ]        || { echo "canonical Claude settings template missing: $CANONICAL_CLAUDE_SETTINGS" >&2; exit 1; }
if pg_has_harness codex; then
  [ -f "$CANONICAL_CODEX_DIR/hooks.json" ] || { echo "canonical Codex hooks manifest missing: $CANONICAL_CODEX_DIR/hooks.json" >&2; exit 1; }
  [ -d "$CANONICAL_CODEX_DIR/hooks" ]      || { echo "canonical Codex hooks dir missing: $CANONICAL_CODEX_DIR/hooks" >&2; exit 1; }
  [ -d "$CANONICAL_REVIEWER_LIB_DIR" ]     || { echo "canonical reviewer lib dir missing: $CANONICAL_REVIEWER_LIB_DIR" >&2; exit 1; }
  for core in $REVIEWER_CORES; do
    [ -f "$CANONICAL_REVIEWER_LIB_DIR/$core" ] || { echo "canonical reviewer core missing: $CANONICAL_REVIEWER_LIB_DIR/$core" >&2; exit 1; }
  done
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

seed_tracked_copy() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ]; then
    local cur
    cur="$(readlink "$dst")"
    if [ "$cur" = "$src" ]; then
      rm "$dst"
      cp "$src" "$dst"
      echo "copied: ${dst#"$PROJECT"/} (replaced machine-local symlink)"
      return
    fi
    echo "WARN: ${dst#"$PROJECT"/} symlinks to '$cur', expected '$src' — leaving as-is" >&2
    return
  fi
  if [ -e "$dst" ]; then
    echo "skip (exists): ${dst#"$PROJECT"/}"
  else
    cp "$src" "$dst"
    echo "created: ${dst#"$PROJECT"/}"
  fi
}

seed_symlink() {
  local target="$1" link="$2"
  # Record absolute-target links for the .gitignore managed block. Recorded
  # whether or not the link already exists — the block must list every intended
  # symlink, not just newly-created ones. Relative targets (AGENTS.md) skipped.
  case "$target" in
    /*) IGNORE_PATHS+=("${link#"$PROJECT"/}") ;;
  esac
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
  local has_go=0 has_pnpm=0 has_py=0

  [ -f "$p/go.work" ] && has_go=1
  if [ -f "$p/pnpm-workspace.yaml" ] || ([ -f "$p/package.json" ] && grep -q '"workspaces"' "$p/package.json" 2>/dev/null); then
    has_pnpm=1
  fi
  [ -f "$p/pyproject.toml" ] && has_py=1

  # Polyglot first: 2+ language signals at the root → polyglot monorepo.
  if [ $((has_go + has_pnpm + has_py)) -ge 2 ]; then
    echo "monorepo-polyglot"; return
  fi

  # Single-language workspace monorepos
  if [ "$has_go" = 1 ]; then
    echo "monorepo-go"; return
  fi
  if [ "$has_pnpm" = 1 ]; then
    echo "monorepo-pnpm"; return
  fi

  # Framework-specific single apps
  if [ -f "$p/next.config.ts" ] || [ -f "$p/next.config.js" ] || [ -f "$p/next.config.mjs" ]; then
    echo "web-next"; return
  fi
  if [ -f "$p/vite.config.ts" ] || [ -f "$p/vite.config.js" ]; then
    echo "web-vite"; return
  fi

  # Native single-module fallbacks
  if [ -f "$p/Cargo.toml" ] || [ -f "$p/go.mod" ] || [ -f "$p/pyproject.toml" ]; then
    echo "native-other"; return
  fi

  # Unity heuristic
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
  # Shared reviewer/UI decision cores live once under the Claude canonical lib
  # and are deployed beside Codex hooks so Codex Stop hooks can source them.
  for core in $REVIEWER_CORES; do
    seed_file "$CANONICAL_REVIEWER_LIB_DIR/$core" "$PROJECT/.codex/hooks/lib/$core"
  done
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
  local presets name target link
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

# Install the Trellis eager post-checkout hook for worktree inheritance.
# Skipped for Husky projects (hooksPath is gitignored → absent in worktrees).
# For tracked hooksPath (e.g. .githooks) or plain git, copies the canonical
# hook body so it fires automatically on `git worktree add`.
install_post_checkout_hook() {
  if [ ! -f "$GITHOOKS_CANONICAL/post-checkout" ]; then
    echo "WARN: canonical post-checkout hook missing at $GITHOOKS_CANONICAL/post-checkout — skipping worktree hook install" >&2
    return
  fi

  local hp destdir hp_label
  hp="$(git -C "$PROJECT" config core.hooksPath || true)"

  if [ -n "$hp" ]; then
    # hooksPath is set — check if it is gitignored (e.g. .husky/_)
    if git -C "$PROJECT" check-ignore -q "$hp" 2>/dev/null; then
      echo "info: core.hooksPath ($hp) is gitignored (husky) — eager post-checkout unavailable in worktrees; relies on 'trellis worktree' wrapper + SessionStart self-heal."
      return
    fi
    # Tracked hooksPath (e.g. .githooks)
    destdir="$PROJECT/$hp"
    hp_label="$hp"
  else
    # No hooksPath — use machine-local .git/hooks (per-clone)
    destdir="$PROJECT/.git/hooks"
    hp_label=".git/hooks (machine-local; per-clone)"
  fi

  mkdir -p "$destdir"
  if [ -e "$destdir/post-checkout" ]; then
    echo "skip (exists): post-checkout in $hp_label"
  else
    cp "$GITHOOKS_CANONICAL/post-checkout" "$destdir/post-checkout"
    chmod +x "$destdir/post-checkout"
    echo "created: post-checkout in $hp_label"
  fi
}

# Regenerate the project .gitignore's Trellis-managed block. The block lists
# exactly the absolute-target symlinks this run created (IGNORE_PATHS, collected
# by seed_symlink) — i.e. only the machine-specific links that must not be tracked
# (their $TRELLIS_ROOT-absolute targets conflict on cross-machine merges).
# Everything else Trellis seeds — hooks, settings.json, primers/INDEX.md,
# skill-local configs, tracked workflow copies, the relative AGENTS.md symlink —
# is project-state and stays tracked.
#
# Self-healing + idempotent. Every run STRIPS all prior Trellis-managed blocks
# (any historical sentinel — they share the begin prefix; each terminated by the
# current "end Trellis fragment" marker OR the legacy "end SE Core fragment"
# variant) PLUS any orphaned canonical-symlink lines stranded between old stacked
# blocks, then writes ONE fresh block. Project-authored .gitignore content — even
# when interleaved between stacked Trellis blocks — is preserved, because stripping
# is per-block (not span-based) and the orphan sweep matches only exact
# Trellis-owned strings no project would author.
write_gitignore_block() {
  local gi="$PROJECT/.gitignore"
  local denyfile tmp pth

  # Dedupe IGNORE_PATHS, preserving first-seen order for stable diffs.
  local dedup=() seen=" "
  for pth in "${IGNORE_PATHS[@]}"; do
    case "$seen" in *" $pth "*) ;; *) dedup+=("$pth"); seen="$seen$pth " ;; esac
  done

  # Orphan-sweep denylist: exact Trellis-owned lines to drop when found OUTSIDE a
  # managed block. Current canonical symlink paths + legacy se-core links + the
  # stray builder-skill comment header older runs left stranded.
  denyfile="$(mktemp)"
  {
    printf '%s\n' "${dedup[@]}"
    printf '%s\n' ".claude/rules/se-core.md" ".agents/rules/se-core.md"
    printf '%s\n' "# Trellis builder-skill symlinks (machine-specific absolute paths)"
  } > "$denyfile"

  tmp="$(mktemp)"
  if [ -f "$gi" ]; then
    awk -v denyfile="$denyfile" '
      BEGIN { while ((getline l < denyfile) > 0) deny[l] = 1 }
      /^# --- Trellis inheritance symlinks/ { inblock = 1; next }
      inblock {
        if ($0 == "# --- end Trellis fragment ---" || $0 == "# --- end SE Core fragment ---") inblock = 0
        next
      }
      ($0 in deny) { next }
      { print }
    ' "$gi" > "$tmp"
    # Trim trailing blank lines so the fresh block sits flush.
    awk '{ a[NR] = $0 } END { last = NR; while (last > 0 && a[last] ~ /^[ \t]*$/) last--; for (i = 1; i <= last; i++) print a[i] }' "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$tmp"
  fi
  rm -f "$denyfile"

  local out
  out="$(mktemp)"
  {
    cat "$tmp"
    if [ -s "$tmp" ]; then printf '\n'; fi
    cat <<'HDR'
# --- Trellis inheritance symlinks (per-machine; regenerated by onboard-project.sh) ---
# Targets are absolute paths under $TRELLIS_ROOT, which differs on every developer's
# machine. Tracking these in git produces cross-machine merge conflicts. Each developer
# recreates them post-clone by re-running:
#   ~/projects/trellis-instance/scripts/onboard-project.sh <project-path>
# See engineering-process.md (in the Trellis canonical repo) §4.2 + §10.5 for the policy.
#
# This block is GENERATED — it lists only machine-absolute symlinks and is rewritten
# in full on every onboard run (no skill-count sentinel; no stacking). Everything else
# Trellis seeds (hooks, settings.json, primers/INDEX.md, skill-local configs,
# tracked workflow copies, the relative AGENTS.md symlink) is project-state and
# IS tracked in git.
HDR
    printf '%s\n' "${dedup[@]}"
    cat <<'STATE'

# --- Trellis per-session state (autonomy slider) ---
# Per-developer, per-session state written by Trellis commands and hooks.
# NOT shared across machines. See core-rules/autonomy.md and hooks.md.
.claude/session-autonomy
.claude/session-surgical
.claude/spec-gate-audit.log
.claude/.fail-counter
.codex/.fail-counter
.claude/.reread-state/
.codex/.reread-state/
.claude/.review-done-*
.codex/.review-done-*
.claude/screenshots/
.codex/screenshots/
.claude/scheduled_tasks.lock
.claude/codex-thread-pool.json
# --- end Trellis per-session state ---
# --- end Trellis fragment ---
STATE
  } > "$out"

  rm -f "$tmp"
  mv "$out" "$gi"
  echo "rewrote: .gitignore Trellis managed block (${#dedup[@]} symlink paths ignored)"
}

echo "== onboarding $PROJECT =="
echo "   trellis_root:  $TRELLIS_ROOT"
echo "   harnesses:     ${HARNESSES[*]}"

# Project root files
seed_file "$TEMPLATES/gotchas.md"     "$PROJECT/gotchas.md"
seed_file "$TEMPLATES/context-log.md" "$PROJECT/context-log.md"

# .gitignore — the Trellis managed block is (re)generated AFTER all symlinks are
# seeded (see write_gitignore_block near the end), since it lists exactly the
# absolute-target links seed_symlink created this run.

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
untrack_if_tracked ".claude/skills/execute"
untrack_if_tracked ".claude/skills/brainstorming"
untrack_if_tracked ".claude/skills/orchestrate"
untrack_if_tracked ".claude/skills/debrief"
untrack_if_tracked ".claude/commands/primer.md"
untrack_if_tracked ".claude/commands/primer-refresh.md"
untrack_if_tracked ".claude/commands/primer-check.md"
untrack_if_tracked ".claude/commands/explore.md"
untrack_if_tracked ".claude/commands/autonomy.md"
untrack_if_tracked ".claude/commands/surgical.md"
untrack_if_tracked ".claude/agents/codex-worker.md"
untrack_if_tracked ".agents/rules/trellis.md"
untrack_if_tracked ".agents/skills/process-gate"
untrack_if_tracked ".agents/skills/security-gate"
untrack_if_tracked ".agents/skills/clarify"
untrack_if_tracked ".agents/skills/spec"
untrack_if_tracked ".agents/skills/plan"
untrack_if_tracked ".agents/skills/tasks"
untrack_if_tracked ".agents/skills/analyze"
untrack_if_tracked ".agents/skills/execute"
untrack_if_tracked ".agents/skills/brainstorming"
untrack_if_tracked ".agents/skills/orchestrate"
untrack_if_tracked ".agents/skills/debrief"
untrack_if_tracked ".agents/commands/primer.md"
untrack_if_tracked ".agents/commands/primer-refresh.md"
untrack_if_tracked ".agents/commands/primer-check.md"
untrack_if_tracked ".agents/commands/explore.md"
untrack_if_tracked ".agents/commands/autonomy.md"
untrack_if_tracked ".agents/commands/surgical.md"

# Claude Code inheritance: rules + skills + hooks.
# Canonical skills shipped today: process-gate, security-gate (always on),
# plus the opt-in clarify → spec → plan → tasks → analyze pipeline (skills
# surface in the agent's skill picker but never run automatically; operators
# invoke them by name when scaffolding a non-trivial feature), the canonical
# builder execute and the ideation front-door brainstorming, the capability-gated
# dynamic-workflow kit orchestrate (the agent reaches for it when a task
# decomposes into multi-stage fan-out/verify work; it self-degrades when the
# harness has no workflow-orchestration tool), and the explicit teach-it-back
# skill debrief (explicit-invoke-only; never auto-fires). See
# core-rules/skills/spec/SKILL.md for the "when to use" decision rule on the
# pipeline as a whole, core-rules/skills/clarify/SKILL.md for the front-step
# question pass, core-rules/skills/analyze/SKILL.md for the tail-step
# drift check, and core-rules/skills/orchestrate/SKILL.md for the
# capability gate + recipe library.
seed_symlink "$CANONICAL_RULES"                       "$PROJECT/.claude/rules/trellis.md"
seed_symlink "$CANONICAL_SKILLS_DIR/process-gate"     "$PROJECT/.claude/skills/process-gate"
seed_symlink "$CANONICAL_SKILLS_DIR/security-gate"    "$PROJECT/.claude/skills/security-gate"
seed_symlink "$CANONICAL_SKILLS_DIR/clarify"          "$PROJECT/.claude/skills/clarify"
seed_symlink "$CANONICAL_SKILLS_DIR/spec"             "$PROJECT/.claude/skills/spec"
seed_symlink "$CANONICAL_SKILLS_DIR/plan"             "$PROJECT/.claude/skills/plan"
seed_symlink "$CANONICAL_SKILLS_DIR/tasks"            "$PROJECT/.claude/skills/tasks"
seed_symlink "$CANONICAL_SKILLS_DIR/analyze"          "$PROJECT/.claude/skills/analyze"
seed_symlink "$CANONICAL_SKILLS_DIR/execute"          "$PROJECT/.claude/skills/execute"
seed_symlink "$CANONICAL_SKILLS_DIR/brainstorming"    "$PROJECT/.claude/skills/brainstorming"
seed_symlink "$CANONICAL_SKILLS_DIR/orchestrate"      "$PROJECT/.claude/skills/orchestrate"
seed_symlink "$CANONICAL_SKILLS_DIR/debrief"          "$PROJECT/.claude/skills/debrief"

# Canonical commands — explicit user invocations (primer system today).
seed_symlink "$CANONICAL_COMMANDS_DIR/primer.md"          "$PROJECT/.claude/commands/primer.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/primer-refresh.md"  "$PROJECT/.claude/commands/primer-refresh.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/primer-check.md"    "$PROJECT/.claude/commands/primer-check.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/explore.md"         "$PROJECT/.claude/commands/explore.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/autonomy.md"        "$PROJECT/.claude/commands/autonomy.md"
seed_symlink "$CANONICAL_COMMANDS_DIR/surgical.md"        "$PROJECT/.claude/commands/surgical.md"

# Canonical Workflow agents — Claude Code resolves definitions from
# .claude/agents/. There is deliberately no .agents/agents/ mirror.
seed_symlink "$CANONICAL_AGENTS_DIR/codex-worker.md" "$PROJECT/.claude/agents/codex-worker.md"

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

# Eager post-checkout hook for worktree inheritance
install_post_checkout_hook

# Shared "agents/" surface — Codex reads AGENTS.md, .agents/rules/,
# .agents/skills/, and .agents/primers/.
if pg_has_harness codex; then
  echo "-- shared .agents/ surface enabled (codex) --"
  seed_symlink "CLAUDE.md" "$PROJECT/AGENTS.md"
  seed_symlink "$CANONICAL_RULES"                    "$PROJECT/.agents/rules/trellis.md"
  seed_symlink "$CANONICAL_SKILLS_DIR/process-gate"  "$PROJECT/.agents/skills/process-gate"
  seed_symlink "$CANONICAL_SKILLS_DIR/security-gate" "$PROJECT/.agents/skills/security-gate"
  seed_symlink "$CANONICAL_SKILLS_DIR/clarify"       "$PROJECT/.agents/skills/clarify"
  seed_symlink "$CANONICAL_SKILLS_DIR/spec"          "$PROJECT/.agents/skills/spec"
  seed_symlink "$CANONICAL_SKILLS_DIR/plan"          "$PROJECT/.agents/skills/plan"
  seed_symlink "$CANONICAL_SKILLS_DIR/tasks"         "$PROJECT/.agents/skills/tasks"
  seed_symlink "$CANONICAL_SKILLS_DIR/analyze"       "$PROJECT/.agents/skills/analyze"
  seed_symlink "$CANONICAL_SKILLS_DIR/execute"       "$PROJECT/.agents/skills/execute"
  seed_symlink "$CANONICAL_SKILLS_DIR/brainstorming" "$PROJECT/.agents/skills/brainstorming"
  seed_symlink "$CANONICAL_SKILLS_DIR/orchestrate"   "$PROJECT/.agents/skills/orchestrate"
  seed_symlink "$CANONICAL_SKILLS_DIR/debrief"       "$PROJECT/.agents/skills/debrief"
  seed_file    "$CANONICAL_PRIMER_INDEX_TEMPLATE"    "$PROJECT/.agents/primers/INDEX.md"
  if [ -f "$PROJECT/.claude/skills/process-gate-local/local.config.sh" ] && [ ! -f "$PROJECT/.agents/skills/process-gate-local/local.config.sh" ]; then
    mkdir -p "$PROJECT/.agents/skills/process-gate-local"
    cp "$PROJECT/.claude/skills/process-gate-local/local.config.sh" "$PROJECT/.agents/skills/process-gate-local/local.config.sh"
    echo "created: .agents/skills/process-gate-local/local.config.sh (copied from Claude local config)"
  else
    seed_process_gate_config "$PROJECT/.agents/skills/process-gate-local/local.config.sh" "$PROFILE"
  fi
fi

# Codex-only surface — .agents/commands/ slash commands + .codex/ hook envelope.
if pg_has_harness codex; then
  echo "-- codex harness enabled --"
  seed_symlink "$CANONICAL_COMMANDS_DIR/primer.md"         "$PROJECT/.agents/commands/primer.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/primer-refresh.md" "$PROJECT/.agents/commands/primer-refresh.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/primer-check.md"   "$PROJECT/.agents/commands/primer-check.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/explore.md"        "$PROJECT/.agents/commands/explore.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/autonomy.md"       "$PROJECT/.agents/commands/autonomy.md"
  seed_symlink "$CANONICAL_COMMANDS_DIR/surgical.md"       "$PROJECT/.agents/commands/surgical.md"
  seed_codex_hooks
fi

# Shared workflow aliases — tracked copies, not symlinks. Keeping workflows
# tracked lets projects commit this part of the Trellis harness without
# machine-local absolute symlink targets.
if pg_has_harness codex; then
  echo "-- shared .agents/workflows/ surface enabled (codex) --"
  seed_tracked_copy "$CANONICAL_COMMANDS_DIR/primer.md"         "$PROJECT/.agents/workflows/primer.md"
  seed_tracked_copy "$CANONICAL_COMMANDS_DIR/primer-refresh.md" "$PROJECT/.agents/workflows/primer-refresh.md"
  seed_tracked_copy "$CANONICAL_COMMANDS_DIR/primer-check.md"   "$PROJECT/.agents/workflows/primer-check.md"
  seed_tracked_copy "$CANONICAL_COMMANDS_DIR/explore.md"        "$PROJECT/.agents/workflows/explore.md"
  seed_tracked_copy "$CANONICAL_COMMANDS_DIR/surgical.md"       "$PROJECT/.agents/workflows/surgical.md"
fi

# Optional preset layering — opt-in per project via <project>/.trellis.config.json
# (or trellis.config.json) with a "presets": [...] array. No-op if the file is
# absent or the array is empty. Seeds preset-<name>.md symlinks under .claude/
# rules/ and (if Codex enabled) .agents/rules/.
seed_presets

# .gitignore managed block — regenerate now that every symlink (skills, commands,
# presets, both surfaces) has been seeded and recorded in IGNORE_PATHS.
write_gitignore_block

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
pg_has_harness codex && echo "  - confirm Codex hooks are enabled in \$CODEX_HOME/config.toml: [features] hooks = true  (legacy 'codex_hooks' is deprecated on Codex CLI 0.129+)"
echo "  - register the project in $TRELLIS_ROOT/registry.md (chore: register <name>)"
echo "  - configure project-local skill:"
echo "      $PROJECT/.claude/skills/process-gate-local/local.config.sh"
pg_has_harness codex && echo "      $PROJECT/.agents/skills/process-gate-local/local.config.sh"
echo "  - configure security-gate profile + LLM provider:"
echo "      $PROJECT/.claude/skills/security-gate-local/local.config.sh"
pg_has_harness codex && echo "      $PROJECT/.agents/skills/security-gate-local/local.config.sh"
