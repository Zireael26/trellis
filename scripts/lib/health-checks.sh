#!/usr/bin/env bash
# health-checks.sh — shared deterministic check library for trellis doctor.
#
# Single source of truth for "what healthy looks like." Sourced by
# scripts/doctor.sh (P1) and optional operator audits (P3). Defines
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
HC_CANONICAL_SKILLS="process-gate security-gate aeo-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing"
# Project-seeded commands only. `constitution`, `trellis-doctor`, and
# `disk-janitor` are control-plane diagnostics run from the canonical checkout
# and are intentionally outside this set.
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

# hc_resolve_python_tool <project> <tool>
# Mirrors stop-verify's pinned-project precedence without executing the selected
# tool. Direct .venv paths prevent a global shim from winning; Poetry and uv
# are considered only when their corresponding lockfile is present.
hc_resolve_python_tool() {
  local proj="$1" tool="$2"

  if [ -x "$proj/.venv/bin/$tool" ]; then
    printf '%s' "$proj/.venv/bin/$tool"
  elif [ -f "$proj/poetry.lock" ] && command -v poetry >/dev/null 2>&1; then
    printf '%s run %s' "$(command -v poetry)" "$tool"
  elif [ -f "$proj/uv.lock" ] && command -v uv >/dev/null 2>&1; then
    printf '%s run %s' "$(command -v uv)" "$tool"
  elif command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
  fi
}

# hc_gate_interpreters <project>
# Read-only interpreter diagnostics for stop-verify's Node/Python gates.
# Missing tools are explicit but advisory, so unrelated inheritance checks still
# run and retain their own verdict.
hc_gate_interpreters() {
  local proj="$1" node python mypy pytest
  node="$(command -v node 2>/dev/null || true)"
  python="$(hc_resolve_python_tool "$proj" python)"
  mypy="$(hc_resolve_python_tool "$proj" mypy)"
  pytest="$(hc_resolve_python_tool "$proj" pytest)"

  [ -n "$node" ] || node="unavailable"
  [ -n "$python" ] || python="unavailable"
  [ -n "$mypy" ] || mypy="unavailable"
  [ -n "$pytest" ] || pytest="unavailable"

  echo "gate-interpreters: node=$node; python=$python; mypy=$mypy; pytest=$pytest"
  return "$HC_OK"
}

# ===========================================================================
# TIER 1 — per active project. Each takes the project dir as $1 and the
# canonical clone path as $2 so the function can compute the expected target
# without touching globals.
# ===========================================================================

# Return the expected literal link text for an absolute target under the active
# symlink style. Relative links are computed from the link's containing dir.
hc_expected_link_target() {
  local target="$1" link="$2"
  if [ "${SYMLINK_STYLE:-absolute}" = "relative" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$target" "$(dirname "$link")" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[1], sys.argv[2]), end="")
PY
  else
    printf '%s' "$target"
  fi
}

# hc_rules_symlink <project> <canonical>
# ERROR if .claude/rules/trellis.md is missing, not a symlink, or resolves to
# anything other than <canonical>/core-rules/CLAUDE.md (incident #1: missing
# link, or stale cross-machine target like /Users/helios/...).
hc_rules_symlink() {
  local proj="$1" canon="$2"
  local link="$proj/.claude/rules/trellis.md"
  local expected
  expected="$(hc_expected_link_target "$canon/core-rules/CLAUDE.md" "$link")"
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
      if [ "$target" != "$(hc_expected_link_target "$canon_skills/$s" "$link")" ] || [ ! -e "$link" ]; then
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
      if [ "$target" != "$(hc_expected_link_target "$canon_cmd/$c.md" "$link")" ] || [ ! -e "$link" ]; then
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
#   omp         -> .omp/AGENTS.md, .omp/skills, .omp/commands, .omp/agents, .omp/hooks
#   claude      -> nothing extra (Claude is the baseline surface)
# WARN if any required artifact for that enabled harness is missing.
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
    omp)
      [ -e "$proj/.omp/AGENTS.md" ] || missing="$missing .omp/AGENTS.md"
      [ -e "$proj/.omp/skills" ]    || missing="$missing .omp/skills"
      [ -e "$proj/.omp/commands" ]  || missing="$missing .omp/commands"
      [ -e "$proj/.omp/agents" ]    || missing="$missing .omp/agents"
      [ -e "$proj/.omp/hooks" ]     || missing="$missing .omp/hooks"
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

# hc_worktree_links_ok <main-checkout> <worktree> <canonical>
# Return 0 when every legacy direct-link inheritance symlink present in the MAIN
# checkout also exists in WORKTREE and resolves to the same destination.
#
# Until v1.0.0-rc.25 this question was answered by shelling out to
# `seed-inheritance-symlinks.sh --legacy-mirror --verify-only`. The cutover
# removed that mode, and a diagnosis must not depend on a writer, so the
# verification half lives here now. It is READ-ONLY by construction: it creates
# nothing and repairs nothing, which is exactly the split the cutover draws.
#
# Enumeration matches the mirror it replaces: symlinks at depth <= 2 under
# .claude/.agents/.omp whose resolved destination is inside the canonical clone,
# plus the control-plane root AGENTS.md link, plus .omp/AGENTS.md — which points
# at the checkout's OWN CLAUDE.md and must therefore resolve to the WORKTREE's
# copy, never the main checkout's. Comparison is by RESOLVED destination, so an
# absolute link and an equivalent relative one are both correct; a missing link,
# a non-symlink, and a link to somewhere else are all offences.
hc_worktree_links_ok() {
  local main="$1" wt="$2" canon="$3" dir link relpath resolved dest
  command -v python3 >/dev/null 2>&1 || return 0
  for dir in "$main/.claude" "$main/.agents" "$main/.omp"; do
    [ -d "$dir" ] || continue
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      relpath="${link#"$main"/}"
      resolved="$(hc_realpath "$link")" || continue
      case "$resolved" in
        "$canon"/*) ;;
        *) continue ;;
      esac
      dest="$wt/$relpath"
      [ -L "$dest" ] || return 1
      [ "$(hc_realpath "$dest")" = "$resolved" ] || return 1
    done < <(find "$dir" -maxdepth 2 -type l 2>/dev/null)
  done
  if [ -L "$main/AGENTS.md" ]; then
    resolved="$(hc_realpath "$main/AGENTS.md")"
    case "$resolved" in
      "$canon"/*)
        [ -L "$wt/AGENTS.md" ] || return 1
        [ "$(hc_realpath "$wt/AGENTS.md")" = "$resolved" ] || return 1
        ;;
    esac
  fi
  if [ -L "$main/.omp/AGENTS.md" ] && [ -f "$main/CLAUDE.md" ] &&
     [ "$(hc_realpath "$main/.omp/AGENTS.md")" = "$(hc_realpath "$main/CLAUDE.md")" ]; then
    [ -L "$wt/.omp/AGENTS.md" ] || return 1
    [ "$(hc_realpath "$wt/.omp/AGENTS.md")" = "$(hc_realpath "$wt/CLAUDE.md")" ] || return 1
  fi
  return 0
}

hc_realpath() {
  python3 - "$1" <<'HCPY'
import os
import sys
print(os.path.realpath(sys.argv[1]), end="")
HCPY
}

# hc_worktree_offenders <project> <canonical>
# Helper (not an hc_ check): prints one offending linked-worktree path per line.
# Used by hc_worktree_inheritance to build the WARN message AND by doctor.sh's
# WARN-branch to fill PLAN_SEED_WORKTREES without re-running full check logic.
# Prints nothing and returns 0 when there are no offending worktrees.
# Skips worktrees that no longer exist on disk (detached-but-deleted worktrees).
hc_worktree_offenders() {
  local proj="$1" canon="$2"
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
        # This row IS the legacy direct-link inheritance contract, so it is
        # verified directly against the main checkout's links. It deliberately
        # does NOT consult seed-inheritance-symlinks.sh: its legacy mirror mode
        # was removed at v1.0.0-rc.25 and refuses, while its portable default
        # answers a different question entirely (whether this worktree's local
        # ATTACHMENT is committed and current against its recorded release) and
        # returns 0 for any clone the local registry does not opt in — which a
        # legacy clone always is. Either verdict would be evidence about
        # something other than direct links.
        if ! hc_worktree_links_ok "$proj" "$wt_path" "$canon"; then
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
# symlinks. Compares each linked worktree (found via
# `git worktree list --porcelain`; the first entry — the main checkout — is
# always skipped) against the main checkout through hc_worktree_links_ok.
#   - Not a git repo, no linked worktrees, or no python3 -> OK (silent)
#   - Any linked worktree missing/mismatched symlinks     -> WARN
# Classification: WARN / [manual]. Since v1.0.0-rc.25 the repair is the clone's
# migration (`trellis migrate --prepare` then `trellis attach`), not a
# per-worktree re-seed: the mirror writer that used to own that is gone.
hc_worktree_inheritance() {
  local proj="$1" canon="$2"
  # Guard: project must be a git repo (doctor.bats's healthy fixture is NOT
  # git-inited — only doctor-fix.bats's version is).
  if ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    echo "worktree-inheritance: not a git repo — check skipped"
    return "$HC_OK"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "worktree-inheritance: python3 unavailable — link resolution skipped"
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

# ===========================================================================
# OMP SURFACE (design 2026-08-09 — full Trellis inheritance into Oh My Pi).
# ERROR-class Tier-1 checks. OMP native discovery stops at the nearest
# non-empty ancestor `.omp` directory even when required files are absent, so a
# partial/dangling/wrong/non-symlink Trellis-owned `.omp` surface silently
# yields an unparented OMP session — the same incident-#1 class as a broken
# .claude/rules link. Links use the configured absolute or relative style:
#   .omp/AGENTS.md -> <project>/CLAUDE.md
#   .omp/skills    -> <canonical>/core-rules/skills
#   .omp/commands  -> <canonical>/core-rules/commands
#   .omp/agents    -> <canonical>/core-rules/agents
#   .omp/hooks     -> <canonical>/core-rules/omp/hooks
# Whole-directory links are deliberate (new canonical skills/commands/agents/
# adapters appear without re-running onboarding), so the manifest checks
# validate the RESOLVED canonical contents, not a snapshot list.
# ===========================================================================

# Expected literal target for an OMP surface path. Prints the expected absolute
# target, or empty for an unknown path. Helper shared by hc_omp_symlinks and
# doctor.sh's --fix rm re-walk (bash 3.2: no arrays of pairs).
#
# Canonical control-plane exception (steered 2026-08-09): when the checked
# project IS the canonical clone itself (realpath-equal to trellis_root) and
# the canonical root carries no CLAUDE.md, the project overlay IS the parent
# rules file — .omp/AGENTS.md links <trellis_root>/core-rules/CLAUDE.md and no
# parent import applies (see hc_omp_project_import). Ordinary projects always
# link their own <project>/CLAUDE.md.
hc_omp_expected_target() {
  local proj="$1" canon="$2" p="$3" target=""
  case "$p" in
    AGENTS.md)
      local proj_real canon_real
      proj_real="$(cd "$proj" 2>/dev/null && pwd -P || printf '%s' "$proj")"
      canon_real="$(cd "$canon" 2>/dev/null && pwd -P || printf '%s' "$canon")"
      if [ "$proj_real" = "$canon_real" ] && [ ! -f "$canon/CLAUDE.md" ]; then
        target="$canon/core-rules/CLAUDE.md"
      else
        target="$proj/CLAUDE.md"
      fi
      ;;
    skills)    target="$canon/core-rules/skills" ;;
    commands)  target="$canon/core-rules/commands" ;;
    agents)    target="$canon/core-rules/agents" ;;
    hooks)     target="$canon/core-rules/omp/hooks" ;;
  esac
  if [ "${SYMLINK_STYLE:-absolute}" = "relative" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$target" "$proj/.omp" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[1], sys.argv[2]), end="")
PY
  else
    printf '%s' "$target"
  fi
}

# hc_omp_symlinks <project> <canonical>
# ERROR if any of the five OMP surface paths is missing, not a symlink,
# wrong-target, or dangling. The literal readlink target must equal the
# expected absolute path (machine-local, generated from the configured
# trellis_root / project root) — a stale cross-machine target is exactly
# incident #1's shape. First failure wins; the message names the path.
hc_omp_symlinks() {
  local proj="$1" canon="$2"
  local p link expected target
  for p in AGENTS.md skills commands agents hooks; do
    link="$proj/.omp/$p"
    expected="$(hc_omp_expected_target "$proj" "$canon" "$p")"
    if [ ! -L "$link" ]; then
      if [ -e "$link" ]; then
        echo "omp: .omp/$p exists but is not a symlink — OMP reads a policy copy, not the live Trellis link"
      else
        echo "omp: .omp/$p missing — OMP session has no Trellis surface"
      fi
      return "$HC_ERROR"
    fi
    target="$(readlink "$link")"
    if [ "$target" != "$expected" ]; then
      echo "omp: .omp/$p → '$target' (expected '$expected') — stale/wrong target"
      return "$HC_ERROR"
    fi
    if [ ! -e "$link" ]; then
      echo "omp: .omp/$p → '$target' is a dangling symlink"
      return "$HC_ERROR"
    fi
  done
  echo "omp: all 5 surface links resolve to exact canonical targets"
  return "$HC_OK"
}

# hc_omp_target_kinds <project> <canonical>
# ERROR if a resolved OMP link is the wrong target kind (AGENTS.md must be a
# regular file; the four canonical links must be directories) or if a canonical
# link's REALPATH escapes the canonical root — the containment half of the
# contract (e.g. a `core-rules/skills` that is itself a symlink out of
# trellis_root passes the literal-target check but must still fail here).
hc_omp_target_kinds() {
  local proj="$1" canon="$2"
  local p link canon_real target_real
  for p in AGENTS.md skills commands agents hooks; do
    link="$proj/.omp/$p"
    [ -L "$link" ] || continue  # missing/wrong/dangling handled by hc_omp_symlinks
    if [ "$p" = "AGENTS.md" ]; then
      if [ ! -f "$link" ]; then
        echo "omp: .omp/AGENTS.md resolves to a non-file target — OMP overlay must be a file"
        return "$HC_ERROR"
      fi
      continue
    fi
    if [ ! -d "$link" ]; then
      echo "omp: .omp/$p resolves to a non-directory target — canonical directory link must be a directory"
      return "$HC_ERROR"
    fi
    # Canonical realpath containment: the RESOLVED target must stay under the
    # canonical root's own realpath. `cd && pwd -P` normalizes /var vs
    # /private/var so the two spellings cannot diverge.
    canon_real="$(cd "$canon" && pwd -P 2>/dev/null || printf '%s' "$canon")"
    target_real="$(cd "$link" && pwd -P 2>/dev/null || printf '%s' "$link")"
    case "$target_real" in
      "$canon_real"/*) ;;
      *)
        echo "omp: .omp/$p resolves to '$target_real' OUTSIDE the canonical root '$canon_real' — links must stay under trellis_root"
        return "$HC_ERROR"
        ;;
    esac
  done
  echo "omp: target kinds correct and canonical links stay under trellis_root"
  return "$HC_OK"
}

# hc_omp_project_import <project> <canonical>
# ERROR-class OMP parent-import check. .omp/AGENTS.md resolves the project's
# CLAUDE.md (validated by hc_omp_symlinks); that file must carry the canonical
# @-import as its FIRST import, resolving to <canonical>/core-rules/CLAUDE.md.
# OMP installs no RULES.md and has no symlinked rules file — the AGENTS.md
# @-import is the ONLY channel for parent rules, so a missing or wrong first
# import is an inheritance break (ERROR), not a degraded warning.
#
# Canonical control-plane exception: when the checked project IS the canonical
# clone (realpath-equal) and the canonical root has no CLAUDE.md, .omp/AGENTS.md
# IS the parent rules file — there is no parent above it to import, so the
# check passes without inspecting an import line.
hc_omp_project_import() {
  local proj="$1" canon="$2"
  local proj_real canon_real
  proj_real="$(cd "$proj" 2>/dev/null && pwd -P || printf '%s' "$proj")"
  canon_real="$(cd "$canon" 2>/dev/null && pwd -P || printf '%s' "$canon")"
  if [ "$proj_real" = "$canon_real" ] && [ ! -f "$canon/CLAUDE.md" ]; then
    echo "omp-import: canonical control-plane project — .omp/AGENTS.md IS core-rules/CLAUDE.md (no parent import applies)"
    return "$HC_OK"
  fi
  local claudemd="$proj/CLAUDE.md"
  local expected="$canon/core-rules/CLAUDE.md"
  if [ ! -f "$claudemd" ]; then
    echo "omp-import: project CLAUDE.md (target of .omp/AGENTS.md) missing — OMP session has no overlay at all"
    return "$HC_ERROR"
  fi
  # First @-import line (leading whitespace allowed), mirroring the
  # hc_import_resolves extraction but restricting to the FIRST match.
  local first_import path
  first_import="$(grep -E '^[[:space:]]*@' "$claudemd" 2>/dev/null | head -n 1)"
  if [ -z "$first_import" ]; then
    echo "omp-import: no @-import in project CLAUDE.md — OMP session inherits NO parent rules (AGENTS.md is the only channel)"
    return "$HC_ERROR"
  fi
  # Strip leading whitespace and the leading @; trim trailing whitespace.
  path="${first_import#"${first_import%%[![:space:]]*}"}"
  path="${path#@}"
  path="${path%"${path##*[![:space:]]}"}"
  if [ "$path" = "$expected" ]; then
    echo "omp-import: first @-import → canonical core-rules/CLAUDE.md"
    return "$HC_OK"
  fi
  echo "omp-import: first @-import → '$path' (expected '$expected') — OMP parent chain broken"
  return "$HC_ERROR"
}

# hc_omp_manifests <project> <canonical>
# ERROR if the RESOLVED canonical manifest layout fails OMP discovery:
#   skills   — one-level <skills-root>/<name>/SKILL.md entries, each with a
#              `description:` frontmatter key; a missing SKILL.md or a
#              description-less one silently vanishes from discovery.
#   commands — .omp/commands/*.md, each with a `description:` frontmatter key.
#   agents   — the canonical agents dir is being EMPTIED (the custom
#              fable/opus/codex/lane agents are GPTX-era and removed; only a
#              .gitkeep remains). An EMPTY agents target is healthy; ANY
#              discoverable *.md is an ERROR — a legacy agent that would still
#              be discovered by OMP (first-win by name) and must be removed.
# Non-.md entries under commands/agents (e.g. templates/) are ignored by OMP
# discovery and are not flagged. Reads the canonical dirs directly: the links
# were already exact-target-validated, so the resolved dirs ARE these. The
# <project> arg is part of the standard Tier-1 signature but unused here.
hc_omp_manifests() {
  local canon="$2"
  local entry bad=""
  if [ -d "$canon/core-rules/skills" ]; then
    for entry in "$canon/core-rules/skills"/*; do
      [ -e "$entry" ] || continue
      if [ ! -d "$entry" ]; then
        bad="$bad skills:$(basename "$entry")"
        continue
      fi
      if [ ! -f "$entry/SKILL.md" ]; then
        bad="$bad skills:$(basename "$entry")/SKILL.md"
        continue
      fi
      if ! grep -qE '^description:' "$entry/SKILL.md" 2>/dev/null; then
        bad="$bad skills:$(basename "$entry")/SKILL.md"
      fi
    done
  else
    bad="$bad skills-dir-missing"
  fi
  if [ -d "$canon/core-rules/commands" ]; then
    for entry in "$canon/core-rules/commands"/*.md; do
      [ -e "$entry" ] || continue
      if ! grep -qE '^description:' "$entry" 2>/dev/null; then
        bad="$bad commands:$(basename "$entry")"
      fi
    done
  else
    bad="$bad commands-dir-missing"
  fi
  if [ -d "$canon/core-rules/agents" ]; then
    for entry in "$canon/core-rules/agents"/*.md; do
      [ -e "$entry" ] || continue
      bad="$bad agents:$(basename "$entry")"
    done
  else
    bad="$bad agents-dir-missing"
  fi
  if [ -n "$bad" ]; then
    echo "omp-manifests: OMP discovery broken —${bad# }"
    return "$HC_ERROR"
  fi
  echo "omp-manifests: canonical skill/command/agent manifests satisfy OMP discovery"
  return "$HC_OK"
}

# hc_omp_adapter <project> <canonical>
# ERROR if the canonical OMP hook adapter is absent. .omp/hooks resolves to
# <canonical>/core-rules/omp/hooks (validated by hc_omp_symlinks); the adapter
# factory must exist at pre/trellis.ts. STATIC existence check only — doctor
# NEVER invokes node/tsx/omp to load it (read-only contract; loadability is the
# rollout's smoke test, not doctor's). The <project> arg is part of the
# standard Tier-1 signature but unused here.
hc_omp_adapter() {
  local canon="$2"
  local adapter="$canon/core-rules/omp/hooks/pre/trellis.ts"
  if [ ! -f "$adapter" ]; then
    echo "omp-adapter: canonical adapter $adapter missing — OMP hooks surface unlinked"
    return "$HC_ERROR"
  fi
  echo "omp-adapter: canonical adapter present (pre/trellis.ts)"
  return "$HC_OK"
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
# e.g. Unity and polyglot-monorepo projects) are inspected at .githooks/pre-push instead of
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

# hc_claudemd_budget <canonical>
# STATIC (adopt-loop, spec 008 — digest 2026-07-07 hygiene): SINGLE-ARG
# canonical-side check (Tier-0). core-rules/CLAUDE.md is the parent doctrine
# every project inherits. A repeated community finding is that past ~200 lines /
# ~150 instructions a CLAUDE.md starts getting PARTIALLY IGNORED — instructions
# beyond the cliff silently lose force. 006 just added lines to the doctrine, so
# a growth guardrail is timely. WARN (never blocks) when core-rules/CLAUDE.md
# crosses the ~200-line attention budget; advisory, future-growth prevention.
#
# METRIC CHOICE (deliberate): this instrument adopts the community ATTENTION-CLIFF
# finding, which is stated in lines/instructions, so it measures LINES and uses
# the community's ~200 figure verbatim as the budget. Trellis's SEPARATE "small
# surface" byte target — <= 19,000 bytes for core-rules/CLAUDE.md, stated in that
# file's Control plane section — is a separate goal tracked there and in the
# cross-project audits, and is deliberately NOT what this check
# enforces. At the parent's ~130 B/line density a 200-line budget permits ~26 KB
# (~5× the byte target): byte-bloat and the attention cliff are different
# concerns, and this check guards only the latter. Missing file => OK (skip):
# an absent parent is caught by the inheritance checks, not here. The <canonical>
# arg ($1) is the standard Tier-0 signature.
hc_claudemd_budget() {
  local canon="$1"
  local claudemd="$canon/core-rules/CLAUDE.md"
  local budget=200
  if [ ! -f "$claudemd" ]; then
    echo "claudemd-budget: core-rules/CLAUDE.md absent — line-budget check skipped"
    return "$HC_OK"
  fi
  # awk NR counts the final line even without a trailing newline (robust vs a
  # naive `wc -l`); always a bare integer, safe for the -gt comparison below.
  local lines
  lines="$(awk 'END{print NR}' "$claudemd" 2>/dev/null || echo 0)"
  [ -n "$lines" ] || lines=0
  if [ "$lines" -gt "$budget" ]; then
    echo "claudemd-budget: core-rules/CLAUDE.md is $lines lines (budget: $budget) — past the attention cliff where instructions get partially ignored; trim or split reference into sibling docs"
    return "$HC_WARN"
  fi
  echo "claudemd-budget: core-rules/CLAUDE.md is $lines lines (budget: $budget)"
  return "$HC_OK"
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

# WARN-class, global: guard Codex plugin hook runtime setup. A plugin update can
# remove the hooks.json node/PATH prefix; the check script repairs it
# idempotently. Delegates to check-codex-plugin-surface.sh.
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
      echo "codex-plugin-surface: hooks PATH/setup present"
    fi
    return "$HC_OK"
  fi
  echo "codex-plugin-surface: DRIFT needing a human — $(printf '%s' "$out" | grep -E 'CHANGED|manually|cannot' | head -2 | tr '\n' '; ')"
  return "$HC_WARN"
}

# ===========================================================================
# PORTABLE LOCAL-STATE HEALTH
#
# These checks consume only validated TRELLIS_HOME state, the local registry,
# immutable installed payloads, and attachment ownership.  They never infer a
# checkout from tracked policy or accept mutable source-checkout runtime paths.
# ===========================================================================

hc_portable_sha256_file() {
  local path="$1" output
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  output="$(shasum -a 256 "$path" 2>/dev/null)" ||
    output="$(sha256sum "$path" 2>/dev/null)" || return 1
  printf '%s\n' "${output%% *}"
}

hc_portable_sha256_text() {
  local value="$1" output
  output="$(printf '%s' "$value" | shasum -a 256 2>/dev/null)" ||
    output="$(printf '%s' "$value" | sha256sum 2>/dev/null)" || return 1
  printf '%s\n' "${output%% *}"
}

hc_portable_decode_base64() {
  local value="$1"
  printf '%s' "$value" | base64 -D 2>/dev/null ||
    printf '%s' "$value" | base64 -d 2>/dev/null
}

# Keep manifest expansion bound to the immutable payload.  Doctor/show-config
# may be launched from a mutable checkout, so their sourced surface planner is
# never authority for an attached payload.
hc_portable_payload_surface_plan() (
  local payload="${1:-}" runtime_plan
  [ "$#" -gt 0 ] || return 1
  shift
  _attachment_canonical_dir "$payload" || return 1
  runtime_plan="$payload/scripts/lib/surface-plan.sh"
  _attachment_canonical_file "$runtime_plan" || return 1
  # shellcheck disable=SC1090  # Path is resolved at runtime by design: an installed release
  # is the only authority, so this must never be a constant checkout path.
  . "$runtime_plan" || return 1
  type surface_plan_emit >/dev/null 2>&1 || return 1
  surface_plan_emit "$payload" "$@"
)

hc_portable_normalize_harnesses() {
  local raw="${1:-}" normalized
  normalized="$(printf '%s\n' "$raw" | jq -cS '
    if type == "array" and length > 0
       and all(.[]; . == "claude" or . == "codex" or . == "omp")
    then unique | sort
    else error("invalid harness set")
    end
  ' 2>/dev/null)" || return 1
  printf '%s\n' "$normalized"
}

# This mirrors attach_exclude_block, but derives the block from the installed
# immutable payload's surface planner rather than trusting bytes in an owner
# record.
hc_portable_expected_exclude_block() (
  local payload="$1" registry_harnesses="$2" deferred="${3:-[]}" normalized plan harness
  local -a harnesses=()
  normalized="$(hc_portable_normalize_harnesses "$registry_harnesses")" || return 1
  while IFS= read -r harness; do
    [ -n "$harness" ] && harnesses+=("$harness")
  done < <(printf '%s\n' "$normalized" | jq -r '.[]')
  plan="$(hc_portable_payload_surface_plan "$payload" "${harnesses[@]}")" || return 1
  printf '%s\n' '# --- Trellis local attachment exclude block ---'
  printf '%s\n' "$plan" | jq -r --argjson deferred "$deferred" '
    ($deferred | map(.path)) as $skip
    | ["/.trellis/runtime"]
      + [.artifacts[].destination | . as $d | select(($skip | index($d)) == null) | "/" + .]
    | unique | sort | .[]
  ' || return 1
  printf '%s\n' '# --- end Trellis local attachment exclude block ---'
)

# A contextual render is attachment state, not an instruction to consult the
# caller's process environment.  The owner records the attach-time context;
# validate it against the selected local machine before using the immutable
# renderer to reconstruct owned bytes.
hc_portable_owner_render_context() (
  local home="$1" owner="$2" context
  context="$(jq -c '.render_context // empty' "$owner" 2>/dev/null)" || return 1
  [ -n "$context" ] || return 1
  attachment_contextual_render_context_validate "$context" "$home" >/dev/null 2>&1 || return 1
  printf '%s\n' "$context"
)

# Exact read-only equivalent of trellis_home_validate_config's schema check.
# Calling that writer-facing helper would chmod the config, so doctor mirrors
# its validation and intentionally does not repair permissions during a read.
hc_portable_machine_config() {
  local home="$1" cfg="$1/config.json" schema home_mode config_mode
  if ! _attachment_canonical_dir "$home"; then
    echo "machine state: TRELLIS_HOME is unavailable, noncanonical, or has a symlink component: $home"
    return "$HC_ERROR"
  fi
  if ! home_mode="$(local_registry_mode "$home" 2>/dev/null)"; then
    echo "machine state: could not inspect TRELLIS_HOME permissions: $home"
    return "$HC_ERROR"
  fi
  if [ "$home_mode" != 700 ]; then
    echo "machine state: TRELLIS_HOME permissions must be 0700, found $home_mode: $home"
    return "$HC_ERROR"
  fi
  if [ -L "$cfg" ] || [ ! -f "$cfg" ]; then
    echo "machine state: missing or non-regular local config: $cfg — run trellis configure"
    return "$HC_ERROR"
  fi
  if ! config_mode="$(local_registry_mode "$cfg" 2>/dev/null)"; then
    echo "machine state: could not inspect local config permissions: $cfg"
    return "$HC_ERROR"
  fi
  if [ "$config_mode" != 600 ]; then
    echo "machine state: local config permissions must be 0600, found $config_mode: $cfg"
    return "$HC_ERROR"
  fi
  schema="$(trellis_home_schema_path)"
  if [ ! -f "$schema" ]; then
    echo "machine state: local machine schema is unavailable: $schema"
    return "$HC_ERROR"
  fi
  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    echo "machine state: config is not a JSON object: $cfg"
    return "$HC_ERROR"
  fi
  if ! jq -e '
    def no_machine_controls:
      type == "string" and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def absolute_safe_path:
      no_machine_controls
      and startswith("/")
      and length >= 2
      and (startswith("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def closed_object($required; $optional):
      type == "object"
      and ((keys_unsorted - ($required + $optional)) | length == 0)
      and (($required - keys_unsorted) | length == 0);
    def fleet_name:
      no_machine_controls and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def version:
      no_machine_controls and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$");
    def fleet_config:
      closed_object(["discovery_roots"]; ["shared_infra_root"])
      and (.discovery_roots | type == "array" and length >= 1)
      and ([.discovery_roots[] | absolute_safe_path] | all)
      and ((.discovery_roots | unique | length) == (.discovery_roots | length))
      and ((has("shared_infra_root") | not) or (.shared_infra_root | absolute_safe_path));
    closed_object(["schema_version", "source_root", "release_remote", "active_cli_release", "default_fleet", "fleets"]; ["$schema"])
    and ((has("$schema") | not) or (.["$schema"] | no_machine_controls and length > 0))
    and .schema_version == 1
    and (.source_root | absolute_safe_path)
    and (.release_remote | no_machine_controls and length > 0)
    and (.active_cli_release | version)
    and (.default_fleet | fleet_name)
    and (.fleets | type == "object" and length >= 1)
    and ([.fleets | keys[] | fleet_name] | all)
    and (.fleets[.default_fleet] != null)
    and ([.fleets[] | fleet_config] | all)
  ' "$cfg" >/dev/null 2>&1; then
    echo "machine state: invalid local config at $cfg — run trellis configure with an explicit source and fleet"
    return "$HC_ERROR"
  fi
  echo "machine state: validated local config at $cfg"
  return "$HC_OK"
}

hc_portable_source_root() {
  local home="$1" cfg source canonical
  cfg="$home/config.json"
  source="$(jq -r '.source_root // empty' "$cfg" 2>/dev/null)" || source=""
  if ! canonical="$(trellis_home_require_source_root "$source" 2>/dev/null)"; then
    echo "source checkout: configured source_root is unavailable or not a Trellis policy checkout (${source:-unset}) — run trellis configure"
    return "$HC_ERROR"
  fi
  echo "source checkout: validated management source $canonical (not used for attached runtime)"
  return "$HC_OK"
}

hc_portable_release_store() {
  local home="$1"
  if TRELLIS_HOME="$home" release_store_verify >/dev/null 2>&1; then
    echo "immutable releases: every installed payload passed integrity verification"
    return "$HC_OK"
  fi
  echo "immutable releases: installed release store is unavailable, corrupt, or unsafe — run trellis release verify"
  return "$HC_ERROR"
}

hc_portable_release() {
  local home="$1" version="$2" rc
  if TRELLIS_HOME="$home" release_store_verify "$version" >/dev/null 2>&1; then
    echo "immutable release: $version passed installed payload integrity verification"
    return "$HC_OK"
  else
    rc=$?
  fi
  case "$rc" in
    "$TRELLIS_EX_UNAVAILABLE")
      echo "immutable release: $version is unavailable — install or explicitly adopt a verified release"
      ;;
    *)
      echo "immutable release: $version is corrupt or unsafe — run trellis release verify $version before attach/relink"
      ;;
  esac
  return "$HC_ERROR"
}

# The store can be internally sound while config.json points its CLI selection
# at an absent release.  Treat that selection as machine health, not a later
# best-effort repair detail.
hc_portable_active_cli_release() {
  local home="$1" release
  release="$(jq -r '.active_cli_release // empty' "$home/config.json" 2>/dev/null)" || release=""
  if [ -z "$release" ]; then
    echo "active CLI release: local config has no usable active_cli_release"
    return "$HC_ERROR"
  fi
  hc_portable_release "$home" "$release"
}


# Owner files are local authority.  Verify their canonical private ancestry
# before inspecting even an absent final file so a symlinked state subtree is
# never accepted as an inert attachment.
hc_portable_owner_path_is_safe() {
  local home="$1" owner="$2" checkout_id="$3" worktree_id="$4" expected parent
  expected="$home/state/attachments/$checkout_id/$worktree_id.json"
  [ "$owner" = "$expected" ] || return 1
  _attachment_valid_absolute "$expected" || return 1
  _attachment_canonical_dir "$home" && [ "$(_attachment_mode "$home")" = 700 ] || return 1
  for parent in "$home/state" "$home/state/attachments" "$home/state/attachments/$checkout_id"; do
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      _attachment_canonical_dir "$parent" && [ "$(_attachment_mode "$parent")" = 700 ] || return 1

    else
      return 0
    fi
  done
  return 0
}

# A checkout has one managed hook authority.  A worktree that shares another
# attachment's exclude block legitimately records disabled hooks, but only if
# that exact checkout has one healthy, matching hook-owning attachment.
HC_PORTABLE_HOOK_STATE=""
hc_portable_managed_hooks() {
  local home="$1" owner="$2" enabled checkout_id release common block_hash owner_dir candidate
  local candidate_checkout candidate_worktree candidate_enabled hook_owner_count=0
  HC_PORTABLE_HOOK_STATE=""
  if ! jq -e '
    has("git_hooks")
    and (.git_hooks | type == "object" and has("enabled") and (.enabled | type == "boolean"))
  ' "$owner" >/dev/null 2>&1; then
    HC_PORTABLE_HOOK_STATE="missing"
    return 1
  fi
  enabled="$(jq -r '.git_hooks.enabled' "$owner")" || return 1
  if [ "$enabled" = true ]; then
    if _attachment_verify_managed_hooks "$home" "$owner"; then
      HC_PORTABLE_HOOK_STATE="direct"
      return 0
    fi
    HC_PORTABLE_HOOK_STATE="conflict"
    return 1
  fi
  [ "$enabled" = false ] || { HC_PORTABLE_HOOK_STATE="corrupt"; return 1; }

  checkout_id="$(jq -r '.checkout_id' "$owner")" || return 1
  release="$(jq -r '.release' "$owner")" || return 1
  common="$(jq -r '.exclude.git_common_dir // empty' "$owner")" || return 1
  block_hash="$(jq -r '.exclude.managed_block_sha256 // empty' "$owner")" || return 1
  [ -n "$common" ] && [ -n "$block_hash" ] || { HC_PORTABLE_HOOK_STATE="corrupt"; return 1; }
  owner_dir="$home/state/attachments/$checkout_id"
  _attachment_canonical_dir "$owner_dir" &&
    [ "$(_attachment_mode "$owner_dir")" = 700 ] || {
      HC_PORTABLE_HOOK_STATE="missing"
      return 1
    }
  for candidate in "$owner_dir"/*.json; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
      [ "$(_attachment_mode "$candidate")" = 600 ] || {
        HC_PORTABLE_HOOK_STATE="corrupt"
        return 1
      }
    _attachment_owner_json_valid "$candidate" >/dev/null 2>&1 || {
      HC_PORTABLE_HOOK_STATE="corrupt"
      return 1
    }
    candidate_checkout="$(jq -r '.checkout_id' "$candidate")" || return 1
    candidate_worktree="$(jq -r '.worktree_id' "$candidate")" || return 1
    [ "$candidate_checkout" = "$checkout_id" ] &&
      hc_portable_owner_path_is_safe "$home" "$candidate" "$candidate_checkout" "$candidate_worktree" || {
        HC_PORTABLE_HOOK_STATE="corrupt"
        return 1
      }
    candidate_enabled="$(jq -r '.git_hooks.enabled // empty' "$candidate")" || return 1
    case "$candidate_enabled" in
      false) continue ;;
      true) ;;
      *) HC_PORTABLE_HOOK_STATE="corrupt"; return 1 ;;
    esac
    jq -e --arg release "$release" --arg common "$common" --arg block_hash "$block_hash" '
      .release == $release
      and .exclude.git_common_dir == $common
      and .exclude.managed_block_sha256 == $block_hash
      and .exclude.managed_by_attachment == true
    ' "$candidate" >/dev/null 2>&1 || {
      HC_PORTABLE_HOOK_STATE="conflict"
      return 1
    }
    _attachment_verify_owner_artifacts "$candidate" "$home" &&
      _attachment_verify_managed_hooks "$home" "$candidate" || {
        HC_PORTABLE_HOOK_STATE="conflict"
        return 1
      }
    hook_owner_count=$((hook_owner_count + 1))
  done
  [ "$hook_owner_count" -eq 1 ] || {
    HC_PORTABLE_HOOK_STATE="missing"
    return 1
  }
  # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
  HC_PORTABLE_HOOK_STATE="shared"
  return 0
}

# Verify every owned leaf except the runtime anchor.  This distinguishes the
# one safe relink condition (only runtime absent) from any conflicting mutation.
hc_portable_owner_without_runtime_exact() {
  local home="$1" owner="$2" record root artifact
  record="$(jq -c . "$owner")" || return 1
  _attachment_contextual_render_context_record_valid "$record" "$home" || return 1
  _attachment_validate_roots "$record" || return 1
  _attachment_validate_ids "$record" || return 1
  root="$(printf '%s\n' "$record" | jq -r '.worktree_root')" || return 1
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    _attachment_parent_safe "$root" "$(printf '%s\n' "$artifact" | jq -r '.path')" || return 1
    _attachment_artifact_exact "$root" "$artifact" || return 1
  done < <(jq -c '.artifacts[] | select(.path != ".trellis/runtime")' "$owner")
}

HC_PORTABLE_OWNER_STATE=""
hc_portable_owner() {
  local home="$1" owner="$2" root="$3" fleet="$4" project_id="$5"
  local checkout_id="$6" worktree_id="$7" attachment_id="$8" release="$9"
  local expected identity expected_runtime
  HC_PORTABLE_OWNER_STATE=""
  if [ -L "$root" ] || [ ! -d "$root" ]; then
    HC_PORTABLE_OWNER_STATE="corrupt"
    echo "attachment ownership: registered worktree root is unavailable or a raw symlink: $root"
    return "$HC_ERROR"
  fi
  if ! hc_portable_owner_path_is_safe "$home" "$owner" "$checkout_id" "$worktree_id"; then
    HC_PORTABLE_OWNER_STATE="corrupt"
    echo "attachment ownership: owner state path is noncanonical, symlinked, or has unsafe private parent permissions"
    return "$HC_ERROR"
  fi

  if [ -L "$owner" ] || [ ! -f "$owner" ]; then
    if [ -n "$attachment_id" ]; then
      HC_PORTABLE_OWNER_STATE="conflict"
      echo "attachment ownership: registry attachment_id has no committed bound owner record; local attachment state is corrupt"
      return "$HC_ERROR"
    fi
    HC_PORTABLE_OWNER_STATE="missing"
    echo "attachment ownership: no committed owner record for this registered checkout/worktree"
    return "$HC_INFO"
  fi
  if [ -z "$attachment_id" ]; then
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: registry record lacks attachment_id; refusing to accept an unbound owner"
    return "$HC_ERROR"
  fi
  if ! _attachment_owner_json_valid "$owner" >/dev/null 2>&1; then
    HC_PORTABLE_OWNER_STATE="corrupt"
    echo "attachment ownership: owner record is invalid or has unsafe permissions: $owner"
    return "$HC_ERROR"
  fi
  identity="$(local_registry_identity_for_root "$root" 2>/dev/null)" || {
    HC_PORTABLE_OWNER_STATE="corrupt"
    echo "attachment ownership: registered root no longer resolves to a canonical Git worktree"
    return "$HC_ERROR"
  }
  if ! printf '%s\n' "$identity" | jq -e --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
      '.checkout_id == $checkout and .worktree_id == $worktree' >/dev/null 2>&1; then
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: current Git identity disagrees with the local registry row"
    return "$HC_ERROR"
  fi
  expected="$(jq -cn \
    --arg project_root "$root" \
    --arg root "$root" --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg checkout_id "$checkout_id" --arg worktree_id "$worktree_id" \
    --arg attachment_id "$attachment_id" --arg release "$release" \
    '{project_root:$project_root,worktree_root:$root,fleet:$fleet,project_id:$project_id,checkout_id:$checkout_id,worktree_id:$worktree_id,attachment_id:$attachment_id,release:$release}')" ||
    {
      HC_PORTABLE_OWNER_STATE="corrupt"
      echo "attachment ownership: could not construct expected local identity"
      return "$HC_ERROR"
    }
  if ! jq -e --argjson expected "$expected" '
    {project_root, worktree_root, fleet, project_id, checkout_id, worktree_id, attachment_id, release} == $expected
  ' "$owner" >/dev/null 2>&1; then
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: owner record does not exactly match its registry checkout/worktree identity"
    return "$HC_ERROR"
  fi
  if ! expected_runtime="$(TRELLIS_HOME="$home" release_store_release_path "$release" 2>/dev/null)"; then
    HC_PORTABLE_OWNER_STATE="corrupt"
    echo "attachment ownership: registry release cannot resolve to an immutable release path"
    return "$HC_ERROR"
  fi
  expected_runtime="$expected_runtime/payload"
  if ! jq -e --arg expected_runtime "$expected_runtime" '
    [.artifacts[] | select(.path == ".trellis/runtime")] as $runtime
    | ($runtime | length) == 1
    and $runtime[0].kind == "symlink"
    and $runtime[0].target == $expected_runtime
  ' "$owner" >/dev/null 2>&1; then
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: runtime anchor does not exactly match the registry-selected immutable release"
    return "$HC_ERROR"
  fi
  if [ ! -e "$root/.trellis/runtime" ] && [ ! -L "$root/.trellis/runtime" ]; then
    if hc_portable_owner_without_runtime_exact "$home" "$owner" &&
       hc_portable_managed_hooks "$home" "$owner"; then
      HC_PORTABLE_OWNER_STATE="runtime-missing"
      echo "attachment ownership: committed owner and managed hooks are intact but its Trellis runtime anchor is missing"
      return "$HC_ERROR"
    fi
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: runtime anchor is missing and another Trellis-owned artifact or managed hook changed"
    return "$HC_ERROR"
  fi
  if ! _attachment_verify_owner_artifacts "$owner" "$home"; then
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: a Trellis-owned artifact is missing, modified, or escapes its recorded state"
    return "$HC_ERROR"
  fi
  if ! hc_portable_managed_hooks "$home" "$owner"; then
    HC_PORTABLE_OWNER_STATE="conflict"
    echo "attachment ownership: the required managed hook authority is missing, disabled, modified, or escapes its recorded state"
    return "$HC_ERROR"
  fi
  HC_PORTABLE_OWNER_STATE="attached"
  echo "attachment ownership: exact committed owner, owned artifacts, and managed hooks match"
  return "$HC_OK"
}

HC_PORTABLE_EXCLUDE_STATE=""
hc_portable_exclude_parse() {
  local file="$1" block_file="$2" line state=outside count=0 block="" expected
  local begin='# --- Trellis local attachment exclude block ---'
  local end='# --- end Trellis local attachment exclude block ---'
  expected="$(cat "$block_file")" || return 1
  [ -e "$file" ] || [ -L "$file" ] || { printf 'none\n'; return 0; }
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$state:$line" in
      outside:"$begin")
        state=inside
        count=$((count + 1))
        block="$line"
        ;;
      outside:"$end") return 1 ;;
      outside:*) ;;
      inside:"$end")
        block="$block
$line"
        [ "$block" = "$expected" ] || return 1
        state=after
        ;;
      inside:"$begin") return 1 ;;
      inside:*) block="$block
$line" ;;
      after:"$begin"|after:"$end") return 1 ;;
      after:*) ;;
    esac
  done < "$file"
  [ "$state" != inside ] || return 1
  [ "$count" -eq 1 ] || return 1
  printf 'one\n'
}

hc_portable_excludes() (
  local owner="$1" payload="$2" registry_harnesses="$3"
  local exclude path common expected_hash expected_exists expected64
  local before_exists before_hash before64 block64 block_hash managed_by_attachment root actual_common
  local before_file after_file block_file expected_file expected_after_file size last empty_hash block_state
  HC_PORTABLE_EXCLUDE_STATE=""
  exclude="$(jq -c '.exclude' "$owner" 2>/dev/null)" || {
    HC_PORTABLE_EXCLUDE_STATE="corrupt"
    echo "managed excludes: owner record has no readable exclude state"
    return "$HC_ERROR"
  }
  path="$(printf '%s\n' "$exclude" | jq -r '.path // empty')" || path=""
  common="$(printf '%s\n' "$exclude" | jq -r '.git_common_dir // empty')" || common=""
  expected_hash="$(printf '%s\n' "$exclude" | jq -r '.after_sha256 // empty')" || expected_hash=""
  expected_exists="$(printf '%s\n' "$exclude" | jq -r '.after_exists // empty')" || expected_exists=""
  expected64="$(printf '%s\n' "$exclude" | jq -r '.after_base64 // empty')" || expected64=""
  before_exists="$(printf '%s\n' "$exclude" | jq -r '.before_exists // empty')" || before_exists=""
  before_hash="$(printf '%s\n' "$exclude" | jq -r '.before_sha256 // empty')" || before_hash=""
  before64="$(printf '%s\n' "$exclude" | jq -r '.before_base64 // empty')" || before64=""
  block64="$(printf '%s\n' "$exclude" | jq -r '.managed_block_base64 // empty')" || block64=""
  block_hash="$(printf '%s\n' "$exclude" | jq -r '.managed_block_sha256 // empty')" || block_hash=""
  managed_by_attachment="$(printf '%s\n' "$exclude" | jq -r '.managed_by_attachment // empty')" || managed_by_attachment=""
  if [ -z "$path" ] || [ -z "$common" ] || [ -z "$expected_hash" ] || [ -z "$expected64" ] ||
     [ -z "$before_hash" ] || [ -z "$block_hash" ]; then
    HC_PORTABLE_EXCLUDE_STATE="corrupt"
    echo "managed excludes: owner record is incomplete"
    return "$HC_ERROR"
  fi
  root="$(jq -r '.worktree_root // empty' "$owner")" || root=""
  actual_common="$(_attachment_git_common_dir "$root" 2>/dev/null)" || actual_common=""
  if [ -z "$actual_common" ] || [ "$common" != "$actual_common" ] ||
     [ "$path" != "$actual_common/info/exclude" ]; then
    HC_PORTABLE_EXCLUDE_STATE="conflict"
    echo "managed excludes: owner exclude path no longer matches this worktree's Git common directory"
    return "$HC_ERROR"
  fi
  before_file="$(mktemp "${TMPDIR:-/tmp}/trellis-health-exclude.before.XXXXXX")" ||
    { HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: could not create a verification scratch file"; return "$HC_ERROR"; }
  after_file="$(mktemp "${TMPDIR:-/tmp}/trellis-health-exclude.after.XXXXXX")" ||
    { rm -f "$before_file"; HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: could not create a verification scratch file"; return "$HC_ERROR"; }
  block_file="$(mktemp "${TMPDIR:-/tmp}/trellis-health-exclude.block.XXXXXX")" ||
    { rm -f "$before_file" "$after_file"; HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: could not create a verification scratch file"; return "$HC_ERROR"; }
  expected_file="$(mktemp "${TMPDIR:-/tmp}/trellis-health-exclude.expected.XXXXXX")" ||
    { rm -f "$before_file" "$after_file" "$block_file"; HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: could not create a verification scratch file"; return "$HC_ERROR"; }
  expected_after_file="$(mktemp "${TMPDIR:-/tmp}/trellis-health-exclude.composed.XXXXXX")" ||
    { rm -f "$before_file" "$after_file" "$block_file" "$expected_file"; HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: could not create a verification scratch file"; return "$HC_ERROR"; }
  trap 'rm -f "$before_file" "$after_file" "$block_file" "$expected_file" "$expected_after_file"' EXIT
  hc_portable_decode_base64 "$before64" > "$before_file" &&
    hc_portable_decode_base64 "$expected64" > "$after_file" &&
    hc_portable_decode_base64 "$block64" > "$block_file" || {
      HC_PORTABLE_EXCLUDE_STATE="corrupt"
      echo "managed excludes: owner block or byte encoding is corrupt"
      return "$HC_ERROR"
    }
  empty_hash="$(hc_portable_sha256_text '')" || return "$HC_ERROR"
  case "$before_exists" in
    true) [ "$(hc_portable_sha256_file "$before_file")" = "$before_hash" ] || {
      HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: owner before-image hash is corrupt"; return "$HC_ERROR"; } ;;
    false) [ "$(wc -c < "$before_file" | tr -d ' ')" -eq 0 ] && [ "$before_hash" = "$empty_hash" ] || {
      HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: owner empty before-image is corrupt"; return "$HC_ERROR"; } ;;
    *) HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: owner before-image state is invalid"; return "$HC_ERROR" ;;
  esac
  hc_portable_expected_exclude_block "$payload" "$registry_harnesses" "$(jq -c '.pre_existing // []' "$owner")" > "$expected_file" || {
    HC_PORTABLE_EXCLUDE_STATE="corrupt"
    echo "managed excludes: immutable payload cannot derive the exact native surface block"
    return "$HC_ERROR"
  }
  if [ "$(hc_portable_sha256_file "$block_file")" != "$block_hash" ] ||
     ! cmp -s "$block_file" "$expected_file"; then
    HC_PORTABLE_EXCLUDE_STATE="conflict"
    echo "managed excludes: owner block does not match the exact immutable native surface plan"
    return "$HC_ERROR"
  fi
  case "$managed_by_attachment" in
    true)
      cat "$before_file" > "$expected_after_file" || return "$HC_ERROR"
      size="$(wc -c < "$before_file" | tr -d ' ')" || return "$HC_ERROR"
      if [ "$size" -gt 0 ]; then
        last="$(dd if="$before_file" bs=1 skip=$((size - 1)) count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" || return "$HC_ERROR"
        [ "$last" = 0a ] || printf '\n' >> "$expected_after_file" || return "$HC_ERROR"
      fi
      cat "$expected_file" >> "$expected_after_file" || return "$HC_ERROR"
      ;;
    false) cp "$before_file" "$expected_after_file" || return "$HC_ERROR" ;;
    *) HC_PORTABLE_EXCLUDE_STATE="corrupt"; echo "managed excludes: owner managed-block state is invalid"; return "$HC_ERROR" ;;
  esac
  if [ "$expected_exists" != true ] ||
     [ "$(hc_portable_sha256_file "$after_file")" != "$expected_hash" ] ||
     ! cmp -s "$after_file" "$expected_after_file"; then
    HC_PORTABLE_EXCLUDE_STATE="corrupt"
    echo "managed excludes: owner after-image does not exactly derive from its immutable block and recorded user bytes"
    return "$HC_ERROR"
  fi
  if [ -L "$path" ] || [ ! -f "$path" ] || ! cmp -s "$path" "$expected_after_file"; then
    HC_PORTABLE_EXCLUDE_STATE="conflict"
    echo "managed excludes: exact Trellis-owned block or surrounding user bytes changed at $path"
    return "$HC_ERROR"
  fi
  block_state="$(hc_portable_exclude_parse "$path" "$expected_file")" || {
    HC_PORTABLE_EXCLUDE_STATE="conflict"
    echo "managed excludes: expected immutable block is missing, duplicated, or modified at $path"
    return "$HC_ERROR"
  }
  [ "$block_state" = one ] || {
    HC_PORTABLE_EXCLUDE_STATE="conflict"
    echo "managed excludes: expected immutable block is missing, duplicated, or modified at $path"
    return "$HC_ERROR"
  }
  # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
  HC_PORTABLE_EXCLUDE_STATE="ok"
  echo "managed excludes: exact immutable native-surface block and surrounding user bytes match ownership"
  return "$HC_OK"
)
hc_portable_verify_payload_render_record() (
  local home="$1" owner="$2" payload="$3" record="$4" context="${5:-}"
  local merge template destination mode source expected expected_owner tmp_root="" before_path
  local before_exists before64 before_mode before_hash expected_before_hash
  merge="$(printf '%s\n' "$record" | jq -r '.merge')" || return 1
  template="$(printf '%s\n' "$record" | jq -r '.template')" || return 1
  destination="$(printf '%s\n' "$record" | jq -r '.destination')" || return 1
  mode="$(printf '%s\n' "$record" | jq -r '.mode')" || return 1
  source="$payload/$template"
  _attachment_canonical_file "$source" || return 1
  case "$merge" in
    replace)
      expected="$(jq -cn --arg path "$destination" \
        --arg sha "$(hc_portable_sha256_file "$source")" --arg mode "$mode" \
        '{path:$path,kind:"file",sha256:$sha,mode:$mode}')" || return 1
      jq -e --arg path "$destination" --argjson expected "$expected" '
        ([.artifacts[] | select(.path == $path)]) == [$expected]
        and ([.renders[] | select(.path == $path)] | length) == 0
      ' "$owner" >/dev/null 2>&1
      return $?
      ;;
    explicit-json)
      before_exists="$(jq -r --arg path "$destination" '[.renders[] | select(.path == $path)] | if length == 1 then .[0].before_exists else empty end' "$owner")" || return 1
      before64="$(jq -r --arg path "$destination" '[.renders[] | select(.path == $path)] | if length == 1 then .[0].before_base64 else empty end' "$owner")" || return 1
      before_mode="$(jq -r --arg path "$destination" '[.renders[] | select(.path == $path)] | if length == 1 then .[0].before_mode else empty end' "$owner")" || return 1
      before_hash="$(jq -r --arg path "$destination" '[.renders[] | select(.path == $path)] | if length == 1 then .[0].before_sha256 else empty end' "$owner")" || return 1
      tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/trellis-health-render.XXXXXX")" || return 1
      trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
      case "$before_exists" in
        true)
          [ "$before_mode" != null ] || return 1
          mkdir -p "$tmp_root/$(dirname "$destination")" || return 1
          before_path="$tmp_root/$destination"
          hc_portable_decode_base64 "$before64" > "$before_path" || return 1
          [ "$(hc_portable_sha256_file "$before_path")" = "$before_hash" ] || return 1
          chmod "$before_mode" "$before_path" || return 1
          ;;
        false)
          expected_before_hash="$(hc_portable_sha256_text '')" || return 1
          [ -z "$before64" ] && [ "$before_mode" = null ] && [ "$before_hash" = "$expected_before_hash" ] || return 1
          ;;
        *) return 1 ;;
      esac
      expected="$(attach_json_render_plan "$tmp_root" "$payload" "$record" "$context" 2>/dev/null)" || return 1
      expected_owner="$(printf '%s\n' "$expected" | jq -cS '.artifact | del(.source, .content_base64, .replace)')" || return 1
      jq -e --arg path "$destination" --argjson artifact "$expected_owner" --argjson render "$expected" '
        ([.artifacts[] | select(.path == $path)]) == [$artifact]
        and ([.renders[] | select(.path == $path)]) == [$render.render]
      ' "$owner" >/dev/null 2>&1
      return $?
      ;;
    *) return 1 ;;
  esac
)

hc_portable_verify_payload_renders() (
  local home="$1" owner="$2" payload="$3" plan="$4"
  local runtime_lib runtime_script context="" expected_paths actual_paths record deferred
  runtime_lib="$payload/scripts/lib/attachment.sh"
  runtime_script="$payload/scripts/attach-project.sh"
  _attachment_canonical_file "$runtime_lib" || return 1
  _attachment_canonical_file "$runtime_script" || return 1
  # shellcheck disable=SC1090  # Path is resolved at runtime by design: an installed release
  # is the only authority, so this must never be a constant checkout path.
  . "$runtime_lib" || return 1
  # shellcheck disable=SC1090  # Path is resolved at runtime by design: an installed release
  # is the only authority, so this must never be a constant checkout path.
  . "$runtime_script" || return 1
  type attachment_contextual_render_required >/dev/null 2>&1 ||
    type attachment_contextual_template_render >/dev/null 2>&1 ||
    type attachment_contextual_render_context_validate >/dev/null 2>&1 ||
    type attach_json_render_plan >/dev/null 2>&1 || return 1
  deferred="$(jq -c '[(.pre_existing // [])[].path]' "$owner")" || return 1
  expected_paths="$(printf '%s\n' "$plan" | jq -cS --argjson deferred "$deferred" '
    [.artifacts[]
     | select(.kind == "render" and .merge == "explicit-json")
     | .destination
     | . as $d | select(($deferred | index($d)) == null)] | sort
  ')" || return 1
  actual_paths="$(jq -cS '[.renders[] | .path] | sort' "$owner")" || return 1
  [ "$actual_paths" = "$expected_paths" ] || return 1
  if attachment_contextual_render_required "$plan"; then
    context="$(hc_portable_owner_render_context "$home" "$owner")" || return 1
  elif ! jq -e '(has("render_context") | not) or .render_context == null' "$owner" >/dev/null 2>&1; then
    return 1
  fi
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    hc_portable_verify_payload_render_record "$home" "$owner" "$payload" "$record" "$context" || return 1
  done < <(printf '%s\n' "$plan" | jq -c --argjson deferred "$deferred" '
    .artifacts[]
    | select(.kind == "render")
    | .destination as $d | select(($deferred | index($d)) == null)')
)

# Attach defers three leaf shapes to the project and records them on the owner
# (attach_deferred_leaves in scripts/attach-project.sh). Doctor cannot take that
# record on trust: a forged or stale entry would otherwise hide a leaf that is
# genuinely missing. So re-derive the SAME decision from the immutable manifest
# and the checkout — the entry has to name a leaf the manifest still plans, in
# the shape that qualifies for deferral, and the checkout still has to hold it.
#
# The re-derivation is per RECORDED REASON, not merely per kind, and the two
# symlink reasons are mutually exclusive by construction — one needs a symlink
# at the destination, the other a regular file. So an authored `AGENTS.md` that
# is later deleted fails (nothing qualifies), and one later REPLACED by the
# managed symlink also fails: the checkout now derives `pre-existing-symlink`
# while the owner still claims `project-authored-file`, and a leaf that changed
# shape under a live attachment is drift the operator should see, not a state
# doctor should quietly re-label.
hc_portable_deferred_leaves_still_justified() {
  local root="$1" payload="$2" plan="$3" deferred="$4" project_claude="$5"
  local entry kind path target reason record
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    kind="$(printf '%s\n' "$entry" | jq -r '.kind')" || return 1
    path="$(printf '%s\n' "$entry" | jq -r '.path')" || return 1
    target="$(printf '%s\n' "$entry" | jq -r '.target // ""')" || return 1
    reason="$(printf '%s\n' "$entry" | jq -r '.reason')" || return 1
    case "$kind" in
      symlink)
        printf '%s\n' "$plan" | jq -e --arg path "$path" --arg target "$target" --argjson project_claude "$project_claude" '
          [.artifacts[]
           | select(.kind == "symlink" and .destination == $path)
           | (if .source_scope == "project"
              then (if $project_claude then .target else .fallback_target end)
              else .target end)] == [$target]
        ' >/dev/null 2>&1 || return 1
        case "$reason" in
          pre-existing-symlink)
            _attachment_symlink_matches "$root/$path" "$target" || return 1
            ;;
          project-authored-file)
            record="$(printf '%s\n' "$plan" | jq -c --arg path "$path" '
              first(.artifacts[] | select(.kind == "symlink" and .destination == $path))')" || return 1
            [ -n "$record" ] || return 1
            _attachment_symlink_destination_authored "$record" "$root" "$payload" "$path" || return 1
            ;;
          *) return 1 ;;
        esac
        ;;
      file)
        printf '%s\n' "$plan" | jq -e --arg path "$path" '
          [.artifacts[]
           | select(.kind == "render" and .destination == $path and (.render_if_absent // false))]
          | length == 1
        ' >/dev/null 2>&1 || return 1
        [ -e "$root/$path" ] || [ -L "$root/$path" ] || return 1
        ;;
      *) return 1 ;;
    esac
  done < <(printf '%s\n' "$deferred" | jq -c '.[]')
  return 0
}

HC_PORTABLE_SURFACE_STATE=""
hc_portable_native_surfaces() (
  local home="$1" owner="$2" payload="$3" registry_harnesses="$4" root owner_harnesses normalized_registry
  local expected actual plan project_claude=false harness deferred
  local -a harnesses=()
  HC_PORTABLE_SURFACE_STATE=""
  normalized_registry="$(hc_portable_normalize_harnesses "$registry_harnesses")" || {
    HC_PORTABLE_SURFACE_STATE="conflict"
    echo "native surfaces: registry harness selection is empty or invalid"
    return "$HC_ERROR"
  }
  root="$(jq -r '.worktree_root' "$owner" 2>/dev/null)" || root=""
  if [ -z "$root" ] || [ -L "$root" ] || [ ! -d "$root" ]; then
    HC_PORTABLE_SURFACE_STATE="corrupt"
    echo "native surfaces: owner worktree root is unavailable or symlinked"
    return "$HC_ERROR"
  fi
  owner_harnesses="$(jq -cS '
    [(.artifacts + (.pre_existing // []))[]
      | if .path == "AGENTS.md" or (.path | startswith(".agents/")) or (.path | startswith(".codex/")) then "codex"
        elif .path | startswith(".claude/") then "claude"
        elif .path | startswith(".omp/") then "omp"
        else empty end] | unique | sort
  ' "$owner" 2>/dev/null)" || owner_harnesses=""
  if [ "$owner_harnesses" != "$normalized_registry" ]; then
    HC_PORTABLE_SURFACE_STATE="conflict"
    echo "native surfaces: registry harness selection does not exactly match the committed attachment owner"
    return "$HC_ERROR"
  fi
  while IFS= read -r harness; do harnesses+=("$harness"); done < <(printf '%s\n' "$normalized_registry" | jq -r '.[]')
  if [ -f "$root/CLAUDE.md" ] && [ ! -L "$root/CLAUDE.md" ]; then project_claude=true; fi
  plan="$(hc_portable_payload_surface_plan "$payload" "${harnesses[@]}")" || {
    HC_PORTABLE_SURFACE_STATE="corrupt"
    echo "native surfaces: installed immutable inheritance manifest is invalid for this attachment"
    return "$HC_ERROR"
  }
  deferred="$(jq -c '.pre_existing // []' "$owner" 2>/dev/null)" || deferred=""
  if [ -z "$deferred" ]; then
    HC_PORTABLE_SURFACE_STATE="corrupt"
    echo "native surfaces: owner record has no readable project-owned deferral list"
    return "$HC_ERROR"
  fi
  if ! hc_portable_deferred_leaves_still_justified "$root" "$payload" "$plan" "$deferred" "$project_claude"; then
    HC_PORTABLE_SURFACE_STATE="conflict"
    echo "native surfaces: a leaf recorded as project-owned no longer matches the immutable manifest or the checkout"
    return "$HC_ERROR"
  fi
  expected="$(printf '%s\n' "$plan" | jq -cS --arg payload "$payload" --argjson project_claude "$project_claude" --argjson deferred "$deferred" '
    .artifacts as $artifacts
    | ($deferred | map(.path)) as $skip
    | ([{path:".trellis/runtime",kind:"symlink",target:$payload}]
       + [$artifacts[] | select(.kind == "symlink") | .destination as $d | select(($skip | index($d)) == null)
          | {path:.destination,kind:"symlink",
             target:(if .source_scope == "project"
                     then (if $project_claude then .target else .fallback_target end)
                     else .target end)}]
       + [$artifacts[] | select(.kind == "render") | .destination as $d | select(($skip | index($d)) == null)
          | {path:.destination,kind:"file",target:null}])
    | sort_by(.path, .kind)
  ')" || {
    HC_PORTABLE_SURFACE_STATE="corrupt"
    echo "native surfaces: could not normalize installed inheritance manifest"
    return "$HC_ERROR"
  }
  actual="$(jq -cS '
    [.artifacts[]
     | select(.kind != "parent" and .kind != "directory")
     | {path:.path,kind:.kind,target:(.target // null)}]
    | sort_by(.path, .kind)
  ' "$owner" 2>/dev/null)" || actual=""
  if [ "$actual" != "$expected" ]; then
    HC_PORTABLE_SURFACE_STATE="conflict"
    echo "native surfaces: committed leaves differ from the exact immutable inheritance manifest"
    return "$HC_ERROR"
  fi
  if ! hc_portable_verify_payload_renders "$home" "$owner" "$payload" "$plan"; then
    HC_PORTABLE_SURFACE_STATE="conflict"
    echo "native surfaces: committed render bytes or owned keys differ from the exact immutable template context"
    return "$HC_ERROR"
  fi
  # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
  HC_PORTABLE_SURFACE_STATE="ok"
  echo "native surfaces: $(printf '%s\n' "$normalized_registry" | jq -r 'join(", ")') match the immutable Claude/Codex/OMP manifest"
  return "$HC_OK"
)

# hc_portable_attachment
# The strict local attachment predicate used by show-config.  A display may
# mention an attachment only after the exact registry/owner binding, immutable
# payload, managed excludes, native leaves/renders/runtime, and managed hooks
# all validate against the selected local state.
HC_PORTABLE_ATTACHMENT_RELEASE_PATH=""
HC_PORTABLE_ATTACHMENT_STATE=""
hc_portable_attachment() {
  local home="$1" owner="$2" root="$3" fleet="$4" project_id="$5"
  local checkout_id="$6" worktree_id="$7" attachment_id="$8" release="$9"
  local harness_list="${10}" release_path
  HC_PORTABLE_ATTACHMENT_RELEASE_PATH=""
  HC_PORTABLE_ATTACHMENT_STATE=""
  hc_portable_owner "$home" "$owner" "$root" "$fleet" "$project_id" \
    "$checkout_id" "$worktree_id" "$attachment_id" "$release" || return "$HC_ERROR"
  if [ "$HC_PORTABLE_OWNER_STATE" != attached ]; then
    echo "attachment: exact owner verification did not reach an attached state"
    return "$HC_ERROR"
  fi
  hc_portable_release "$home" "$release" || return "$HC_ERROR"
  if ! release_path="$(TRELLIS_HOME="$home" release_store_locate "$release" 2>/dev/null)"; then
    echo "attachment: verified immutable release disappeared before strict attachment verification"
    return "$HC_ERROR"
  fi
  hc_portable_excludes "$owner" "$release_path/payload" "$harness_list" || return "$HC_ERROR"
  hc_portable_native_surfaces "$home" "$owner" "$release_path/payload" "$harness_list" || return "$HC_ERROR"
  # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
  HC_PORTABLE_ATTACHMENT_RELEASE_PATH="$release_path"
  # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
  HC_PORTABLE_ATTACHMENT_STATE="attached"
  echo "attachment: exact registry, owner, immutable payload, excludes, native surfaces, and managed hooks match"
  return "$HC_OK"
}

# Only unambiguously generated compatibility artifacts count. A project-owned
# CLAUDE.md, .claude/, or .agents/ directory alone is never legacy.
hc_portable_legacy_marker() {
  local root="$1" path target
  for path in ".trellis.config.json" ".claude/rules/se-core.md" ".agents/rules/se-core.md"; do
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then printf '%s\n' "$path"; return 0; fi
  done
  for path in ".claude/rules/trellis.md" ".agents/rules/trellis.md"; do
    if [ -L "$root/$path" ]; then
      target="$(readlink "$root/$path" 2>/dev/null || true)"
      case "$target" in */core-rules/CLAUDE.md)
        case "$target" in */.trellis/runtime/*) ;; *) printf '%s\n' "$path"; return 0 ;; esac ;;
      esac
    fi
  done
  if [ -f "$root/CLAUDE.md" ] && [ ! -L "$root/CLAUDE.md" ] &&
     LC_ALL=C grep -Eq '^@/.*/core-rules/CLAUDE\.md$' "$root/CLAUDE.md"; then printf '%s\n' 'CLAUDE.md'; return 0; fi
  if [ -f "$root/.gitignore" ] && [ ! -L "$root/.gitignore" ] &&
     LC_ALL=C grep -qF '# --- Trellis inheritance symlinks' "$root/.gitignore"; then printf '%s\n' '.gitignore'; return 0; fi
  return 1
}

HC_PORTABLE_LAYOUT=""
HC_PORTABLE_LAYOUT_MARKER=""
hc_portable_layout() {
  local root="$1" owner_state="${2:-missing}" registry_project_id="${3:-}" manifest="$1/.trellis.json"
  local manifest_state="absent" manifest_project_id="" marker runtime_present=false
  HC_PORTABLE_LAYOUT=""
  HC_PORTABLE_LAYOUT_MARKER=""
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if [ -L "$manifest" ] || [ ! -f "$manifest" ] ||
       ! manifest_project_id="$(local_registry_manifest_project_id "$manifest" 2>/dev/null)"; then
      manifest_state="corrupt"
    elif [ -n "$registry_project_id" ] && [ "$manifest_project_id" != "$registry_project_id" ]; then
      manifest_state="corrupt"
    else
      manifest_state="portable"
    fi
  fi
  marker="$(hc_portable_legacy_marker "$root" 2>/dev/null || true)"
  # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
  [ -n "$marker" ] && HC_PORTABLE_LAYOUT_MARKER="$marker"
  if [ -e "$root/.trellis/runtime" ] || [ -L "$root/.trellis/runtime" ]; then runtime_present=true; fi
  if [ "$manifest_state" = corrupt ]; then
    HC_PORTABLE_LAYOUT="corrupt"
    echo "layout: corrupt portable project manifest at .trellis.json (missing/invalid or project_id disagrees with local registry)"
    return "$HC_ERROR"
  fi
  case "$owner_state" in
    missing|attached|runtime-missing) ;;
    *)
      HC_PORTABLE_LAYOUT="corrupt"
      echo "layout: corrupt — local attachment ownership is $owner_state, not repairable automatically"
      return "$HC_ERROR"
      ;;
  esac
  if [ -n "$marker" ] && { [ "$manifest_state" = portable ] || [ "$runtime_present" = true ] || [ "$owner_state" = attached ] || [ "$owner_state" = runtime-missing ]; }; then
    HC_PORTABLE_LAYOUT="mixed/conflict"
    echo "layout: mixed/conflict — portable attachment coexists with explicit compatibility artifact $marker"
    return "$HC_ERROR"
  fi
  if [ -n "$marker" ]; then
    HC_PORTABLE_LAYOUT="compatibility-legacy"
    echo "layout: explicit compatibility legacy ($marker) — run trellis migrate --prepare before portable attach"
    return "$HC_WARN"
  fi
  case "$owner_state" in
    attached|runtime-missing)
      if [ "$manifest_state" != portable ]; then
        HC_PORTABLE_LAYOUT="corrupt"
        echo "layout: corrupt — committed attachment lacks its portable manifest"
        return "$HC_ERROR"
      fi
      HC_PORTABLE_LAYOUT="portable-attached"
      if [ "$runtime_present" = true ]; then echo "layout: portable-attached"; return "$HC_OK"; fi
      echo "layout: portable-attached with a missing Trellis runtime anchor"
      return "$HC_ERROR"
      ;;
    missing)
      if [ "$runtime_present" = true ]; then
        HC_PORTABLE_LAYOUT="corrupt"
        echo "layout: corrupt — runtime anchor exists without exact committed ownership"
        return "$HC_ERROR"
      fi
      if [ "$manifest_state" = portable ]; then
        HC_PORTABLE_LAYOUT="inert-non-user"
        echo "layout: inert non-user portable manifest (not locally attached)"
        return "$HC_OK"
      fi
      # shellcheck disable=SC2034  # Out-parameter: doctor reads it after this check returns.
      HC_PORTABLE_LAYOUT="inert-non-user"
      echo "layout: inert non-user (no Trellis local attachment)"
      return "$HC_OK"
      ;;
  esac
}
