#!/usr/bin/env bash
# health-checks.sh — shared deterministic check library for trellis doctor.
#
# Single source of truth for "what healthy looks like." Sourced by
# scripts/doctor.sh (P1) and, later, by the scheduled audits (P3). Defines
# small, composable check functions. Each takes EXPLICIT path arguments —
# NO global cwd assumptions, NO reliance on the caller's working directory —
# emits a human-readable message on stdout, and returns a status code:
#
#   0  HC_OK    — healthy
#   1  HC_ERROR — inheritance broken (project gets no parent rules) / canonical
#                 off-main or dirty. Caller must exit non-zero on any of these.
#   2  HC_WARN  — degraded (missing skill, hook drift, missing @-import
#                 fallback, missing harness parity). Still exit 0.
#   3  HC_INFO  — informational (version-pin lag; rules current via symlink).
#
# Callers MUST capture the status without tripping `set -e`, e.g.
#   if msg=$(hc_canonical_on_main "$root"); then rc=0; else rc=$?; fi
#
# Tier-0 functions take the CANONICAL clone path as their first argument and
# probe it with `git -C "<canonical>" ...` — never the caller's cwd, because
# doctor runs from worktrees (the naive-cwd trap, ADR Tier-0).
#
# bash 3.2 compatible: no associative arrays, no `mapfile`, no `declare -A`.

# Status-code constants (exported so doctor.sh can reference by name).
HC_OK=0
HC_ERROR=1
HC_WARN=2
HC_INFO=3
export HC_OK HC_ERROR HC_WARN HC_INFO

# Canonical sets — the full inheritance surface a healthy project carries.
# Kept here (not in doctor.sh) so audits share the same definition of "full".
HC_CANONICAL_SKILLS="process-gate security-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing"
HC_CANONICAL_COMMANDS="primer primer-refresh primer-check explore autonomy surgical"
export HC_CANONICAL_SKILLS HC_CANONICAL_COMMANDS

# ---------------------------------------------------------------------------
# Small helpers (pure where possible).
# ---------------------------------------------------------------------------

# Resolve a symlink's literal target (one level — matches how onboard writes
# absolute-target links). Prints the target, or empty if not a symlink.
hc_link_target() {
  local link="$1"
  [ -L "$link" ] || { printf ''; return 0; }
  readlink "$link"
}

# Extract the first `## [vX.Y.Z]` version token from a CHANGELOG, skipping the
# `## Unreleased` heading. Prints the bare version (no leading v), or empty.
hc_changelog_latest_version() {
  local changelog="$1"
  [ -f "$changelog" ] || { printf ''; return 0; }
  # First heading of the form `## [vX.Y.Z]` (Keep-a-Changelog style).
  # grep -o keeps us off sed-flavor portability concerns.
  grep -oE '^## \[v[0-9]+\.[0-9]+\.[0-9]+[^]]*\]' "$changelog" 2>/dev/null \
    | head -n 1 \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^]]*' \
    | sed 's/^v//'
}

# Compare two semver-ish strings. Prints the higher per `sort -V`. If equal,
# prints the value itself.
hc_higher_version() {
  printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1
}

# ===========================================================================
# TIER 0 — global preconditions. Probe $canonical via `git -C`, never cwd.
# Each takes the canonical clone path as $1.
# ===========================================================================

# hc_canonical_on_main <canonical>
# ERROR if the canonical clone is NOT on `main`. A canonical checkout on a
# feature/detached branch silently feeds every project stale rules (incident
# #2). on-main is the load-bearing OK condition.
hc_canonical_on_main() {
  local canon="$1" branch
  if ! git -C "$canon" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "canonical clone is not a git work tree: $canon"
    return "$HC_ERROR"
  fi
  branch="$(git -C "$canon" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$branch" = "main" ]; then
    echo "canonical clone is on main"
    return "$HC_OK"
  fi
  if [ "$branch" = "HEAD" ] || [ -z "$branch" ]; then
    echo "canonical clone is in detached HEAD (expected: main) — every project inherits stale rules"
    return "$HC_ERROR"
  fi
  echo "canonical clone is on '$branch' (expected: main) — every project inherits this branch's rules"
  return "$HC_ERROR"
}

# hc_canonical_clean <canonical>
# ERROR if the canonical working tree has uncommitted changes — those leak
# into every project's inheritance with no version trail.
hc_canonical_clean() {
  local canon="$1" dirty
  if ! git -C "$canon" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "canonical clone is not a git work tree: $canon"
    return "$HC_ERROR"
  fi
  dirty="$(git -C "$canon" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    echo "canonical clone has uncommitted changes — projects inherit unversioned rules"
    return "$HC_ERROR"
  fi
  echo "canonical clone is clean"
  return "$HC_OK"
}

# hc_canonical_sync <canonical>
# READ-ONLY divergence check against the LOCAL origin/main tracking ref
# (NO network fetch). Being ahead of origin is normal for the source-of-truth
# clone and is NEVER an error. Behind is at most INFO. No origin/main ref =>
# OK (silent skip).
hc_canonical_sync() {
  local canon="$1" ahead behind
  if ! git -C "$canon" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "canonical clone is not a git work tree: $canon"
    return "$HC_ERROR"
  fi
  if ! git -C "$canon" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    echo "no local origin/main tracking ref — sync check skipped (no network probe)"
    return "$HC_OK"
  fi
  ahead="$(git -C "$canon" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  behind="$(git -C "$canon" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "${behind:-0}" -gt 0 ]; then
    echo "canonical is $behind commit(s) behind origin/main (ahead $ahead) — consider pulling"
    return "$HC_INFO"
  fi
  if [ "${ahead:-0}" -gt 0 ]; then
    echo "canonical is $ahead commit(s) ahead of origin/main (normal for source-of-truth)"
    return "$HC_OK"
  fi
  echo "canonical is in sync with origin/main"
  return "$HC_OK"
}

# hc_conformance_passes <canonical>
# Runs the repo's conformance-check.sh (doc path refs resolve) if present.
# Missing script => OK (skip): minimal fixtures / consumer clones may not
# carry it, and a missing optional tool must not trip Tier-0.
hc_conformance_passes() {
  local canon="$1"
  local script="$canon/scripts/conformance-check.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "conformance-check.sh not present — skipped"
    return "$HC_OK"
  fi
  # READ-ONLY CONTRACT: doctor's read-only guarantee transitively depends on
  # this external script. conformance-check.sh MUST stay side-effect-free
  # (no writes to the canonical clone or projects; mktemp-only scratch, cleaned
  # up). If a future change there mutates state, it silently breaks doctor's
  # read-only property — keep it audited.
  if bash "$script" --quiet >/dev/null 2>&1; then
    echo "conformance-check passes (doc path refs resolve)"
    return "$HC_OK"
  fi
  echo "conformance-check FAILED — spec docs reference missing files (run scripts/conformance-check.sh)"
  return "$HC_ERROR"
}

# hc_version_changelog_coherent <canonical>
# VERSION (core-rules/VERSION — the pin source upgrade.sh treats as canonical)
# should match the latest released CHANGELOG entry. Missing either input =>
# OK (skip). A mismatch is WARN (release-hygiene, not inheritance-breaking).
hc_version_changelog_coherent() {
  local canon="$1"
  local version_file="$canon/core-rules/VERSION"
  local changelog="$canon/CHANGELOG.md"
  local ver cl_ver
  if [ ! -f "$version_file" ]; then
    echo "core-rules/VERSION not present — coherence check skipped"
    return "$HC_OK"
  fi
  ver="$(tr -d '[:space:]' < "$version_file" 2>/dev/null || echo '')"
  if [ -z "$ver" ]; then
    echo "core-rules/VERSION is empty — coherence check skipped"
    return "$HC_OK"
  fi
  cl_ver="$(hc_changelog_latest_version "$changelog")"
  if [ -z "$cl_ver" ]; then
    echo "no released version heading in CHANGELOG.md — coherence check skipped"
    return "$HC_OK"
  fi
  if [ "$ver" = "$cl_ver" ]; then
    echo "VERSION ($ver) matches latest CHANGELOG entry"
    return "$HC_OK"
  fi
  echo "VERSION ($ver) does not match latest CHANGELOG entry (v$cl_ver) — release metadata drift"
  return "$HC_WARN"
}

# hc_tooling_noninteractive_path
# Tooling baseline (NOT inheritance). Git hooks run in a NON-LOGIN, non-
# interactive shell. The 2026-05-31 incident: node/pnpm were on PATH only for
# login shells, so git hooks resolved a different (brew) Node with no pnpm —
# breaking pnpm/corepack and Node-26-sensitive tests. Durable fix was a PATH
# prepend in ~/.zshenv so non-login shells inherit the nvm Node + pnpm.
# This check flags any tool that resolves INTERACTIVELY but vanishes in a
# non-login shell — the precise regression signature. No false positive for a
# tool that simply isn't installed (we only probe tools already on PATH).
# Portable: the probe only runs when the login shell is zsh; skipped otherwise.
# WARN at worst — never blocks inheritance.
hc_tooling_noninteractive_path() {
  case "${SHELL:-}" in
    *zsh) ;;
    *) echo "non-login PATH probe skipped (login shell is not zsh)"; return "$HC_OK" ;;
  esac
  command -v zsh >/dev/null 2>&1 || { echo "non-login PATH probe skipped (zsh not found)"; return "$HC_OK"; }
  local tool missing=""
  for tool in node pnpm npm yarn bun; do
    if command -v "$tool" >/dev/null 2>&1; then
      zsh -c "command -v $tool >/dev/null 2>&1" 2>/dev/null || missing="$missing $tool"
    fi
  done
  if [ -n "$missing" ]; then
    echo "tools on PATH interactively but MISSING in a non-login shell:$missing — git hooks (non-login) lose them; add a PATH prepend to ~/.zshenv (see gotchas: non-login hooks)"
    return "$HC_WARN"
  fi
  echo "node + package managers resolve in both login and non-login shells"
  return "$HC_OK"
}

# ===========================================================================
# TIER 1 — per active project. Each takes the project dir as $1 and the
# canonical clone path as $2 so the function can compute the expected target
# without touching globals.
# ===========================================================================

# hc_rules_symlink <project> <canonical>
# ERROR if .claude/rules/trellis.md is missing, not a symlink, or resolves to
# anything other than <canonical>/core-rules/CLAUDE.md (incident #1: missing
# link, or stale cross-machine target like /Users/helios/...).
hc_rules_symlink() {
  local proj="$1" canon="$2"
  local link="$proj/.claude/rules/trellis.md"
  local expected="$canon/core-rules/CLAUDE.md"
  if [ ! -L "$link" ]; then
    if [ -e "$link" ]; then
      echo "rules: .claude/rules/trellis.md exists but is not a symlink"
      return "$HC_ERROR"
    fi
    echo "rules: .claude/rules/trellis.md missing — project runs unparented"
    return "$HC_ERROR"
  fi
  local target
  target="$(readlink "$link")"
  if [ "$target" != "$expected" ]; then
    echo "rules: trellis.md → '$target' (expected '$expected') — stale/wrong target, parent rules dropped"
    return "$HC_ERROR"
  fi
  if [ ! -e "$link" ]; then
    echo "rules: trellis.md → '$target' is a dangling symlink — parent rules dropped"
    return "$HC_ERROR"
  fi
  echo "rules: trellis.md resolves to canonical"
  return "$HC_OK"
}

# hc_import_resolves <project> <canonical>
# Inspects the project's own CLAUDE.md for an @-import of the canonical rules.
# A CLAUDE.md may carry several @-lines (e.g. @docs/strategy.md) — we look for
# one ending in core-rules/CLAUDE.md.
#   - canonical @-line present and == expected      -> OK
#   - canonical-looking @-line pointing elsewhere   -> ERROR (dead import, #1)
#   - no canonical @-line at all                     -> WARN (fallback missing)
hc_import_resolves() {
  local proj="$1" canon="$2"
  local claudemd="$proj/CLAUDE.md"
  local expected="$canon/core-rules/CLAUDE.md"
  if [ ! -f "$claudemd" ]; then
    echo "import: no project CLAUDE.md — @-import fallback absent"
    return "$HC_WARN"
  fi
  # Pull all @-import lines (lines beginning with @, optional leading space).
  local imports line path matched_canonical=""
  imports="$(grep -E '^[[:space:]]*@' "$claudemd" 2>/dev/null || true)"
  if [ -n "$imports" ]; then
    while IFS= read -r line; do
      # Strip leading whitespace and the leading @.
      path="${line#"${line%%[![:space:]]*}"}"
      path="${path#@}"
      # Trim trailing whitespace.
      path="${path%"${path##*[![:space:]]}"}"
      case "$path" in
        */core-rules/CLAUDE.md)
          matched_canonical="$path"
          break
          ;;
      esac
    done <<EOF
$imports
EOF
  fi
  if [ -z "$matched_canonical" ]; then
    echo "import: no @<canonical>/core-rules/CLAUDE.md line in CLAUDE.md — symlink-only, no fallback"
    return "$HC_WARN"
  fi
  if [ "$matched_canonical" != "$expected" ]; then
    echo "import: @-import → '$matched_canonical' (expected '$expected') — dead/cross-machine import"
    return "$HC_ERROR"
  fi
  echo "import: @-import matches canonical"
  return "$HC_OK"
}

# hc_skills_symlinks <project> <canonical>
# WARN if any of the full canonical skill set is missing or its symlink does
# not resolve. Checks the 7 are PRESENT (subset) — extra skills like
# process-gate-local are fine and not flagged.
hc_skills_symlinks() {
  local proj="$1" canon="$2"
  local skills_dir="$proj/.claude/skills"
  local canon_skills="$canon/core-rules/skills"
  local s missing="" broken=""
  for s in $HC_CANONICAL_SKILLS; do
    local link="$skills_dir/$s"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      missing="$missing $s"
      continue
    fi
    if [ -L "$link" ]; then
      local target
      target="$(readlink "$link")"
      if [ "$target" != "$canon_skills/$s" ] || [ ! -e "$link" ]; then
        broken="$broken $s"
      fi
    fi
  done
  if [ -n "$missing" ] || [ -n "$broken" ]; then
    local detail=""
    [ -n "$missing" ] && detail="missing:${missing}"
    [ -n "$broken" ] && detail="$detail broken:${broken}"
    echo "skills: incomplete canonical set —${detail# }"
    return "$HC_WARN"
  fi
  echo "skills: full canonical set resolves"
  return "$HC_OK"
}

# hc_commands_symlinks <project> <canonical>
# WARN if any of the full canonical command set is missing or unresolved.
# Commands are seeded under .claude/commands/<name>.md.
hc_commands_symlinks() {
  local proj="$1" canon="$2"
  local cmd_dir="$proj/.claude/commands"
  local canon_cmd="$canon/core-rules/commands"
  local c missing="" broken=""
  for c in $HC_CANONICAL_COMMANDS; do
    local link="$cmd_dir/$c.md"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      missing="$missing $c"
      continue
    fi
    if [ -L "$link" ]; then
      local target
      target="$(readlink "$link")"
      if [ "$target" != "$canon_cmd/$c.md" ] || [ ! -e "$link" ]; then
        broken="$broken $c"
      fi
    fi
  done
  if [ -n "$missing" ] || [ -n "$broken" ]; then
    local detail=""
    [ -n "$missing" ] && detail="missing:${missing}"
    [ -n "$broken" ] && detail="$detail broken:${broken}"
    echo "commands: incomplete canonical set —${detail# }"
    return "$HC_WARN"
  fi
  echo "commands: full canonical set resolves"
  return "$HC_OK"
}

# hc_harness_artifacts <project> <harness>
# Harness-conditional parity, checked per enabled harness. The caller passes
# ONE harness name and invokes once per enabled harness.
#   codex       -> AGENTS.md, .agents/rules, .agents/skills, .agents/workflows, .codex/hooks
#   claude      -> nothing extra (Claude is the baseline surface)
# WARN if any required artifact for that harness is missing.
hc_harness_artifacts() {
  local proj="$1" harness="$2"
  local missing=""
  case "$harness" in
    codex)
      [ -e "$proj/AGENTS.md" ]         || missing="$missing AGENTS.md"
      [ -e "$proj/.agents/rules" ]     || missing="$missing .agents/rules"
      [ -e "$proj/.agents/skills" ]    || missing="$missing .agents/skills"
      [ -e "$proj/.agents/workflows" ] || missing="$missing .agents/workflows"
      [ -e "$proj/.codex/hooks" ]      || missing="$missing .codex/hooks"
      ;;
    claude)
      echo "harness[$harness]: baseline surface (no extra artifacts)"
      return "$HC_OK"
      ;;
    *)
      echo "harness[$harness]: unknown harness — no parity rule"
      return "$HC_OK"
      ;;
  esac
  if [ -n "$missing" ]; then
    echo "harness[$harness]: missing parity artifact(s) —${missing}"
    return "$HC_WARN"
  fi
  echo "harness[$harness]: parity artifacts present"
  return "$HC_OK"
}

# hc_codex_process_gate_local_parity <project>
# WARN if a Codex-enabled project carries a different process-gate-local config
# than Claude. These files are intentionally project-owned (not canonical
# symlinks), but Codex must inherit the same per-project commands, ADR paths,
# stack profile, and PR-size policy Claude sees.
hc_codex_process_gate_local_parity() {
  local proj="$1"
  local claude_cfg="$proj/.claude/skills/process-gate-local/local.config.sh"
  local codex_cfg="$proj/.agents/skills/process-gate-local/local.config.sh"

  if [ ! -e "$claude_cfg" ] && [ ! -e "$codex_cfg" ]; then
    echo "codex-process-gate-local: no project-local config on either harness"
    return "$HC_OK"
  fi
  if [ ! -f "$claude_cfg" ]; then
    echo "codex-process-gate-local: Codex config exists but Claude baseline is missing"
    return "$HC_WARN"
  fi
  if [ ! -f "$codex_cfg" ]; then
    echo "codex-process-gate-local: Claude config exists but Codex copy is missing"
    return "$HC_WARN"
  fi
  if cmp -s "$claude_cfg" "$codex_cfg"; then
    echo "codex-process-gate-local: matches Claude project-local config"
    return "$HC_OK"
  fi
  echo "codex-process-gate-local: differs from Claude project-local config — Codex sees different process gates"
  return "$HC_WARN"
}

# hc_hook_freshness <project> <canonical>
# WARN if any project-side Claude hook .sh copy drifts from canonical
# (parent-hook-drift class). Hooks are COPIES (not symlinks), compared by
# SHA-256 against <canonical>/core-rules/hooks/*.sh. A missing .claude/hooks
# dir is WARN (project not wired for hooks at all).
hc_hook_freshness() {
  local proj="$1" canon="$2"
  local canon_hooks="$canon/core-rules/hooks"
  local proj_hooks="$proj/.claude/hooks"
  if [ ! -d "$canon_hooks" ]; then
    echo "hooks: canonical hooks dir absent — freshness check skipped"
    return "$HC_OK"
  fi
  if [ ! -d "$proj_hooks" ]; then
    echo "hooks: .claude/hooks/ missing — hook stack not installed"
    return "$HC_WARN"
  fi
  local src fn dst src_sha dst_sha missing="" stale=""
  for src in "$canon_hooks"/*.sh; do
    [ -e "$src" ] || continue
    fn="$(basename "$src")"
    dst="$proj_hooks/$fn"
    if [ ! -f "$dst" ]; then
      missing="$missing $fn"
      continue
    fi
    src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"
    dst_sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
    if [ "$src_sha" != "$dst_sha" ]; then
      stale="$stale $fn"
    fi
  done
  if [ -n "$missing" ] || [ -n "$stale" ]; then
    local detail=""
    [ -n "$missing" ] && detail="missing:${missing}"
    [ -n "$stale" ] && detail="$detail stale:${stale}"
    echo "hooks: drift vs canonical —${detail# }"
    return "$HC_WARN"
  fi
  echo "hooks: all canonical hook copies in sync"
  return "$HC_OK"
}

# hc_settings_wiring <project> <canonical>
# WARN if .claude/settings.json is missing, invalid, or fails to wire every
# canonical hook. settings.json is the ONLY thing that seeds hook *wiring*; a
# MISSING canonical wiring means a hook is installed but never fires.
#
# Superset semantics (not exact match): the project must contain every canonical
# (event, matcher, command) wiring, but MAY add its own hooks and tune timeouts.
# Projects legitimately extend the baseline — e.g. a project-specific boundary
# check, or a longer stop-verify timeout for a big suite — and that is not drift.
# Only an absent canonical wiring is. Timeouts are intentionally not compared.
hc_settings_wiring() {
  local proj="$1" canon="$2"
  local settings="$proj/.claude/settings.json"
  local template="$canon/core-rules/templates/claude-settings.json"
  if [ ! -f "$settings" ]; then
    echo "settings: .claude/settings.json missing — hooks unwired"
    return "$HC_WARN"
  fi
  if [ ! -f "$template" ]; then
    echo "settings: canonical template absent — wiring check skipped"
    return "$HC_OK"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "settings: jq unavailable — wiring check skipped"
    return "$HC_OK"
  fi
  # Flatten each file to one "event<TAB>matcher<TAB>command" line per wired hook
  # (matcher-less events use "*"). Timeout is deliberately excluded.
  local extract='.hooks // {} | to_entries[] | .key as $e | .value[]
    | (.matcher // "*") as $m | (.hooks // [])[] | [$e, $m, .command] | @tsv'
  local proj_pairs canon_pairs missing names line
  proj_pairs="$(jq -r "$extract" "$settings" 2>/dev/null)" || proj_pairs="ERR"
  if [ "$proj_pairs" = "ERR" ]; then
    echo "settings: .claude/settings.json is not valid JSON"
    return "$HC_WARN"
  fi
  canon_pairs="$(jq -r "$extract" "$template" 2>/dev/null || true)"
  # Portable set difference (no process substitution — mirrors this library):
  # collect canonical wirings absent from the project.
  missing=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$proj_pairs" | grep -Fxq -- "$line" || missing="${missing}${line}"$'\n'
  done <<EOF
$canon_pairs
EOF
  if [ -n "$missing" ]; then
    names="$(printf '%s' "$missing" | awk -F'\t' 'NF{n=$3; sub(/.*\//,"",n); printf "%s ", n}')"
    echo "settings: missing canonical hook wiring —${names% }"
    return "$HC_WARN"
  fi
  echo "settings: canonical hook wiring present (project extensions OK)"
  return "$HC_OK"
}

# hc_worktree_offenders <project> <canonical>
# Helper (not an hc_ check): prints one offending linked-worktree path per line.
# Used by hc_worktree_inheritance to build the WARN message AND by doctor.sh's
# WARN-branch to fill PLAN_SEED_WORKTREES without re-running full check logic.
# Prints nothing and returns 0 when there are no offending worktrees.
# Skips worktrees that no longer exist on disk (detached-but-deleted worktrees).
hc_worktree_offenders() {
  local proj="$1" canon="$2"
  local seeder="$canon/scripts/seed-inheritance-symlinks.sh"
  # If the project is not a git repo, there are no worktrees to check.
  local wt_list
  wt_list="$(git -C "$proj" worktree list --porcelain 2>/dev/null || true)"
  [ -z "$wt_list" ] && return 0
  # Parse all 'worktree <path>' entries; skip the first (the main checkout).
  local first_seen=0 wt_path line
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        if [ "$first_seen" -eq 0 ]; then
          first_seen=1
          continue  # skip the main checkout
        fi
        # Only probe linked worktrees that still exist on disk.
        [ -d "$wt_path" ] || continue
        # If the seeder is absent, skip (can't verify); not an error.
        [ -f "$seeder" ] || continue
        if ! bash "$seeder" --target "$wt_path" --verify-only --quiet >/dev/null 2>&1; then
          printf '%s\n' "$wt_path"
        fi
        ;;
    esac
  done <<EOF
$wt_list
EOF
}

# hc_worktree_inheritance <project> <canonical>
# WARN if any linked git worktree of the project is missing Trellis inheritance
# symlinks. Uses seed-inheritance-symlinks.sh --verify-only to probe each linked
# worktree (found via `git worktree list --porcelain`; the first entry — the
# main checkout — is always skipped).
#   - Not a git repo, or no linked worktrees, or seeder absent -> OK (silent)
#   - Any linked worktree missing symlinks                      -> WARN
# Classification: WARN / [auto] (fixable via seed-inheritance-symlinks.sh).
hc_worktree_inheritance() {
  local proj="$1" canon="$2"
  # Guard: project must be a git repo (doctor.bats's healthy fixture is NOT
  # git-inited — only doctor-fix.bats's version is).
  if ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    echo "worktree-inheritance: not a git repo — check skipped"
    return "$HC_OK"
  fi
  local seeder="$canon/scripts/seed-inheritance-symlinks.sh"
  if [ ! -f "$seeder" ]; then
    echo "worktree-inheritance: seeder not present in canonical — check skipped"
    return "$HC_OK"
  fi
  local offenders wt_count
  offenders="$(hc_worktree_offenders "$proj" "$canon")"
  if [ -z "$offenders" ]; then
    # Either no linked worktrees or all are healthy.
    echo "worktree-inheritance: all linked worktrees carry inheritance symlinks"
    return "$HC_OK"
  fi
  # Count and list offenders.
  wt_count="$(printf '%s\n' "$offenders" | grep -c .)"
  local detail=""
  while IFS= read -r wt; do
    [ -n "$wt" ] && detail="$detail $wt"
  done <<EOF
$offenders
EOF
  echo "worktree-inheritance: $wt_count linked worktree(s) missing inheritance symlinks —${detail}"
  return "$HC_WARN"
}

# hc_version_pin_lag <project> <canonical>
# INFO if the project's own pin (<project>/.trellis.config.json .trellis_version)
# trails the canonical core-rules/VERSION. Rules themselves are current via the
# symlink; only pinned features trail — hence INFO, never ERROR. A project with
# no per-project pin is OK (it inherits live, unpinned).
hc_version_pin_lag() {
  local proj="$1" canon="$2"
  local proj_cfg="$proj/.trellis.config.json"
  local version_file="$canon/core-rules/VERSION"
  local canon_ver pin higher
  if [ ! -f "$version_file" ]; then
    echo "version: canonical core-rules/VERSION absent — pin-lag check skipped"
    return "$HC_OK"
  fi
  canon_ver="$(tr -d '[:space:]' < "$version_file" 2>/dev/null || echo '')"
  [ -z "$canon_ver" ] && { echo "version: canonical VERSION empty — pin-lag check skipped"; return "$HC_OK"; }
  if [ ! -f "$proj_cfg" ]; then
    echo "version: no per-project pin (inherits live canonical $canon_ver)"
    return "$HC_OK"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "version: jq unavailable — pin-lag check skipped"
    return "$HC_OK"
  fi
  pin="$(jq -r '.trellis_version // empty' "$proj_cfg" 2>/dev/null || echo '')"
  if [ -z "$pin" ]; then
    echo "version: no trellis_version pin (inherits live canonical $canon_ver)"
    return "$HC_OK"
  fi
  if [ "$pin" = "$canon_ver" ]; then
    echo "version: pin ($pin) matches canonical"
    return "$HC_OK"
  fi
  higher="$(hc_higher_version "$pin" "$canon_ver")"
  if [ "$higher" = "$pin" ]; then
    # Project pin ahead of canonical — unusual but not a lag; report neutrally.
    echo "version: pin ($pin) is ahead of canonical ($canon_ver)"
    return "$HC_OK"
  fi
  echo "version: pin ($pin) lags canonical ($canon_ver) — pinned features trail"
  return "$HC_INFO"
}

# Canonical one-line fix for an unscoped Turbo `.next/**` outputs glob. SINGLE
# SOURCE OF TRUTH for the hint string — disk-janitor-lib.sh's dj_turbo_fix_hint
# echoes the SAME text; keep the two byte-identical. The fleet incident (148 GB
# in 2 days, 2026-06-02) was an unscoped `.next/**` that tarred `.next/cache/`
# (Next's incremental cache) + `.next/dev/` into every Turbo cache entry. The
# fix scopes the glob with both negations.
hc_turbo_fix_hint() {
  printf '%s' 'in turbo.json, add "!.next/cache/**" and "!.next/dev/**" after ".next/**" in the task'"'"'s outputs (e.g. ["...", ".next/**", "!.next/cache/**", "!.next/dev/**"]) — keeps Next'"'"'s incremental + dev caches out of the Turbo cache'
}

# hc_turbo_outputs <project>
# RECURRENCE GUARD for the fleet-wide build-cache blowup (disk-janitor feature,
# finding #2). WARN if the project's turbo.json has any task whose `outputs[]`
# carries a `.next/**`-class glob WITHOUT a matching `!.next/cache/**` negation —
# the exact misconfiguration that let Next's cache get tarred into every Turbo
# cache entry. Inspects both turbo v2 (`.tasks`) and v1 (`.pipeline`) shapes.
#   - no turbo.json / jq unavailable / already-scoped / no .next glob -> OK
#   - any task with an unscoped .next/** outputs glob               -> WARN + fix
# REPORT-ONLY: turbo.json is a user-owned project file — doctor NEVER auto-edits
# it (same policy as the CLAUDE.md @-import). doctor.sh must NOT add a --fix
# action for this check; it only prints the one-line fix as a suggested action.
#
# Self-contained: the jq predicate below is DUPLICATED from
# disk-janitor-lib.sh's dj_turbo_outputs_unscoped (deliberate — health-checks.sh
# must not take a runtime source dependency on disk-janitor-lib.sh). The
# fix-hint string is shared via hc_turbo_fix_hint above.
hc_turbo_outputs() {
  local proj="$1"
  local turbo="$proj/turbo.json"
  if [ ! -f "$turbo" ]; then
    echo "turbo-outputs: no turbo.json — recurrence check skipped"
    return "$HC_OK"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "turbo-outputs: jq unavailable — recurrence check skipped"
    return "$HC_OK"
  fi
  # A task is "unscoped" iff its outputs contain a positive `.next/**`-class glob
  # (a string with `.next/` AND `**`, not starting with `!`) but NO `!.next/cache`
  # negation. Probe v2 `.tasks` and v1 `.pipeline`; emit "unscoped" if any match.
  local verdict
  verdict="$(jq -r '
    ((.tasks // {}) + (.pipeline // {}))
    | to_entries
    | map(
        (.value.outputs // []) as $o
        | (($o | map(select(type == "string"
              and (startswith("!") | not)
              and (contains(".next/"))
              and (contains("**"))
            )) | length) > 0) as $has_next
        | (($o | map(select(type == "string"
              and startswith("!")
              and (contains(".next/cache"))
            )) | length) > 0) as $has_neg
        | ($has_next and ($has_neg | not))
      )
    | if any(.) then "unscoped" else "scoped" end
  ' "$turbo" 2>/dev/null)" || verdict=""
  if [ "$verdict" = "unscoped" ]; then
    echo "turbo-outputs: turbo.json has an unscoped .next/** outputs glob (Next caches get tarred into the Turbo cache) — fix: $(hc_turbo_fix_hint)"
    return "$HC_WARN"
  fi
  echo "turbo-outputs: turbo.json outputs are scoped (no unscoped .next/** glob)"
  return "$HC_OK"
}

# ===========================================================================
# PROCESS-ENFORCEMENT PLACEHOLDERS (design 2026-06-02 §3 Phase 0).
# Registered (defined in the standard hc_* form) so doctor wiring can land
# incrementally without a later >7-file phase. Each is a no-op that returns
# HC_OK (pass/skip cleanly) until the owning phase fills it in. They are NOT
# yet wired into scripts/doctor.sh — Phase 8a wires them into the run order —
# so they do not change doctor's verdict while stubbed. Intended signatures are
# documented in each header so the filling phase knows the expected arguments.
# Bodies take no arguments to stay shellcheck-clean (no unused-var SC2034).
# ===========================================================================

# hc_reviewer_resolvable <project> <canonical>
# STATIC (DL-P8a-01/02): NEVER invokes the reviewer — doctor runs this across
# every registered project as a read-only sweep, so executing the rung-2
# `claude -p` would spawn N side-effecting LLM calls. The 3-rung ladder's rung 3
# (deterministic regex) ALWAYS resolves, so "no reviewer at any rung" is
# structurally impossible. The meaningful inheritance-health condition is a
# review hook wired with a MISSING sibling lib: the wired hook then can't source
# the ladder and the review silently fails open. So WARN ONLY when the review
# hook IS present AND lib/code-reviewer.sh is absent; a project that legitimately
# runs no review (no review hook) is OK with no warning (no manufactured noise).
# The <canonical> arg ($2) is part of the standard signature but unused here.
hc_reviewer_resolvable() {
  local proj="$1"
  local hook="$proj/.claude/hooks/code-review-subagent.sh"
  local lib="$proj/.claude/hooks/lib/code-reviewer.sh"
  if [ ! -f "$hook" ]; then
    echo "reviewer-resolvable: no review hook wired — project runs no code-review (OK)"
    return "$HC_OK"
  fi
  if [ ! -f "$lib" ]; then
    echo "reviewer-resolvable: code-review hook wired but lib/code-reviewer.sh MISSING — review silently fails open (re-seed hooks)"
    return "$HC_WARN"
  fi
  echo "reviewer-resolvable: review hook + reviewer lib both present"
  return "$HC_OK"
}

# hc_ui_screenshot_path <project> <canonical>
# STATIC (DL-P8a-01/03): NEVER runs a screenshot tool. UI project = the project
# tracks at least one file whose final path segment ends in a UI extension
# (.tsx/.jsx/.vue/.svelte/.html/.css — matching ui-verify-core's UI_REGEX),
# enumerated via `git ls-files` (doctor runs outside a turn, so it keys off
# TRACKED files, never "changed files"). "No resolvable screenshot path" =
# UI_SHOT_CMD is empty AND playwright is not on PATH. UI project AND no
# resolvable tool -> WARN with a remediation hint. Otherwise OK. The <canonical>
# arg ($2) is part of the standard signature but unused here.
hc_ui_screenshot_path() {
  local proj="$1"
  local ui_count
  # pipefail-safe: `grep -c` reads all input (no SIGPIPE on grep short-circuit)
  # and `|| true` swallows grep's exit-1-on-no-match. Each ls-files line is one
  # path, so the `$`-anchored extension test matches the final path segment.
  ui_count="$(git -C "$proj" ls-files 2>/dev/null \
    | grep -ciE '\.(tsx|jsx|vue|svelte|html|css)$' || true)"
  if [ "${ui_count:-0}" -le 0 ]; then
    echo "ui-screenshot-path: no tracked UI source files — not a UI project (OK)"
    return "$HC_OK"
  fi
  if [ -n "${UI_SHOT_CMD:-}" ] || command -v playwright >/dev/null 2>&1; then
    echo "ui-screenshot-path: UI project with a resolvable screenshot tool"
    return "$HC_OK"
  fi
  echo "ui-screenshot-path: UI project but no screenshot tool resolves — configure UI_SHOT_CMD or install playwright (ui-verify can't capture)"
  return "$HC_WARN"
}

# hc_prepush_wired_runall <project> <canonical>
# STATIC (DL-P8a-01/04): NEVER executes the hook — running pre-push runs the
# WHOLE merge gate incl. tests. Resolves the ACTIVE pre-push the way git itself
# does, honoring core.hooksPath (mirrors resolve_prepush_target() in
# lib/prepush-target.sh) so native-git-hooks projects (core.hooksPath=.githooks,
# e.g. lume / clusterbid-console) are inspected at .githooks/pre-push instead of
# being falsely WARNed:
#   hp = git config --local core.hooksPath
#   hp empty   -> .git/hooks/pre-push, BUT husky-classic also keeps the real gate
#                 body at .husky/pre-push, so a .husky/pre-push is honored too.
#   hp=.husky/_ (husky v9) -> the real gate body is .husky/pre-push.
#   hp other   -> (hp absolute ? hp : <worktree>/hp)/pre-push.
# Whichever ACTIVE hook exists is grep'd for the literal substring `run-all.sh`
# (accepting either a .claude/ or .agents/ path): found -> OK; present but not
# wired -> WARN (bypassed); none exists -> WARN (unwired). A stale .git/hooks or
# inactive .husky hook is NOT consulted unless it is the one git would run, so
# the check cannot report a false positive. The <canonical> arg ($2) is part of
# the standard signature but unused.
hc_prepush_wired_runall() {
  local proj="$1"
  local husky="$proj/.husky/pre-push"
  # Plain `git config` honors git's effective precedence (a local value already
  # wins over a global one), so this matches the hook git actually runs and the
  # canonical resolver in lib/prepush-target.sh; `|| true` keeps set -e/-u quiet
  # when $proj is not a git repo.
  local hp
  hp="$(git -C "$proj" config core.hooksPath 2>/dev/null || true)"

  local hook=""
  if [ -z "$hp" ]; then
    # No hooksPath: git runs .git/hooks/pre-push. Husky-classic keeps the real
    # gate body at .husky/pre-push, so honor that first when it exists.
    if [ -f "$husky" ]; then
      hook="$husky"
    elif [ -f "$proj/.git/hooks/pre-push" ]; then
      hook="$proj/.git/hooks/pre-push"
    fi
  elif [ "$hp" = ".husky/_" ] || [ "${hp%/.husky/_}" != "$hp" ]; then
    # husky v9 wrapper dir (relative OR absolute — `husky init` writes the
    # absolute form): the real gate body lives at .husky/pre-push.
    [ -f "$husky" ] && hook="$husky"
  else
    # Native hooks dir. A relative hooksPath is resolved against the worktree
    # root (git's own interpretation; falls back to $proj if rev-parse fails).
    local abs_hooks toplevel
    case "$hp" in
      /*) abs_hooks="$hp" ;;
      *)
        toplevel="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null || true)"
        abs_hooks="${toplevel:-$proj}/$hp"
        ;;
    esac
    [ -f "$abs_hooks/pre-push" ] && hook="$abs_hooks/pre-push"
  fi

  if [ -z "$hook" ]; then
    echo "prepush-wired-runall: no pre-push hook — merge gate not wired (install process-gate's pre-push)"
    return "$HC_WARN"
  fi
  # -F: literal substring (the `.` in run-all.sh must not act as a wildcard).
  if grep -qF 'run-all.sh' "$hook" 2>/dev/null; then
    echo "prepush-wired-runall: pre-push references process-gate run-all.sh"
    return "$HC_OK"
  fi
  echo "prepush-wired-runall: pre-push present but not wired to run-all.sh — merge gate bypassed (re-seed the canonical pre-push)"
  return "$HC_WARN"
}

# hc_receipt_grammar_present <canonical>
# STATIC (DL-P8a-01/05): SINGLE-ARG canonical-side check (Tier-0). Greps the
# canonical core-rules/CLAUDE.md for the literal `dod-receipt` grammar anchor.
# Present -> OK; absent (or file missing) -> WARN.
hc_receipt_grammar_present() {
  local canon="$1"
  local claudemd="$canon/core-rules/CLAUDE.md"
  if [ -f "$claudemd" ] && grep -qF 'dod-receipt' "$claudemd" 2>/dev/null; then
    echo "receipt-grammar-present: dod-receipt grammar present in core-rules/CLAUDE.md"
    return "$HC_OK"
  fi
  echo "receipt-grammar-present: dod-receipt grammar MISSING from core-rules/CLAUDE.md — execute receipts have no canonical contract"
  return "$HC_WARN"
}

# Codex runtime hooks-enabled check (spec 006, PD8 / C-2c). The Codex spec-gate
# and every Codex Stop/PreToolUse hook only fire when the Codex runtime has hooks
# turned on in $CODEX_HOME/config.toml ([features] hooks = true). If Codex is an
# enabled harness but that switch is off (or the CLI/config is absent), the whole
# cross-harness enforcement mechanism silently no-ops on Codex — the exact failure
# the parity work exists to prevent. WARN, report-only. No project arg: reads the
# central HARNESSES + the per-machine Codex config.
hc_codex_hooks_enabled() {
  if ! pg_has_harness codex 2>/dev/null; then
    echo "codex-runtime: n/a (codex not an enabled harness)"
    return "$HC_OK"
  fi
  if ! command -v codex >/dev/null 2>&1; then
    echo "codex-runtime: codex harness enabled but the codex CLI is not installed — Codex hooks (incl. spec-gate) cannot run"
    return "$HC_WARN"
  fi
  local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ ! -f "$cfg" ]; then
    echo "codex-runtime: $cfg absent — [features] hooks unset; Codex spec-gate + Stop/PreToolUse hooks will NOT run"
    return "$HC_WARN"
  fi
  # true iff a `hooks = true` line appears inside the [features] table.
  if awk '
      /^[[:space:]]*\[features\][[:space:]]*$/ { in_f=1; next }
      /^[[:space:]]*\[/                        { in_f=0 }
      in_f && /^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true/ { found=1 }
      END { exit(found?0:1) }
    ' "$cfg"; then
    echo "codex-runtime: [features] hooks = true (Codex hooks active)"
    return "$HC_OK"
  fi
  echo "codex-runtime: [features] hooks not enabled in $cfg — the Codex spec-gate + every Codex Stop/PreToolUse hook silently NO-OPS (fix: set [features] hooks = true)"
  return "$HC_WARN"
}

# WARN-class, global: guard the codex plugin surface — companion effort enum
# (widening unblocks recipe-side max; ADR 2026-07-10-sol-ultra) and the
# teammate node/PATH hooks.json patch (a plugin update reverts it; the check
# script re-applies idempotently). Delegates to check-codex-plugin-surface.sh.
hc_codex_plugin_surface() {
  local script="$SCRIPT_DIR/check-codex-plugin-surface.sh"
  if [ ! -x "$script" ]; then
    echo "codex-plugin-surface: check script missing at $script"
    return "$HC_WARN"
  fi
  local out
  if out="$(bash "$script" 2>&1)"; then
    if printf '%s' "$out" | grep -q 'RE-APPLIED\|refreshed'; then
      echo "codex-plugin-surface: drift auto-repaired — $(printf '%s' "$out" | grep -E 'RE-APPLIED|refreshed' | head -2 | tr '\n' '; ')"
    else
      echo "codex-plugin-surface: baseline (companion caps at xhigh; hooks.json patch present)"
    fi
    return "$HC_OK"
  fi
  echo "codex-plugin-surface: DRIFT needing a human — $(printf '%s' "$out" | grep -E 'WIDENED|CHANGED|manually|cannot' | head -2 | tr '\n' '; ')"
  return "$HC_WARN"
}
