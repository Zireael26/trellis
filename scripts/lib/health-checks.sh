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
HC_CANONICAL_SKILLS="process-gate security-gate clarify spec plan tasks analyze"
HC_CANONICAL_COMMANDS="primer primer-refresh primer-check explore autonomy"
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
#   codex       -> AGENTS.md, .agents/rules, .agents/skills, .codex/hooks
#   antigravity -> AGENTS.md, .agents/rules, .agents/skills, .agents/workflows
#                  (no hook surface — AntiGravity has no native hook API)
#   claude      -> nothing extra (Claude is the baseline surface)
# WARN if any required artifact for that harness is missing.
hc_harness_artifacts() {
  local proj="$1" harness="$2"
  local missing=""
  case "$harness" in
    codex)
      [ -e "$proj/AGENTS.md" ]        || missing="$missing AGENTS.md"
      [ -e "$proj/.agents/rules" ]    || missing="$missing .agents/rules"
      [ -e "$proj/.agents/skills" ]   || missing="$missing .agents/skills"
      [ -e "$proj/.codex/hooks" ]     || missing="$missing .codex/hooks"
      ;;
    antigravity)
      [ -e "$proj/AGENTS.md" ]           || missing="$missing AGENTS.md"
      [ -e "$proj/.agents/rules" ]       || missing="$missing .agents/rules"
      [ -e "$proj/.agents/skills" ]      || missing="$missing .agents/skills"
      [ -e "$proj/.agents/workflows" ]   || missing="$missing .agents/workflows"
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
