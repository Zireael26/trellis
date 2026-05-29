#!/usr/bin/env bats
# Tests for scripts/doctor.sh — the P1 read-only inheritance health checker.
#
# FULLY ISOLATED from the live registry and the 7 real managed projects.
# Every test stands up its own fixture in a fresh `mktemp` dir:
#   <sandbox>/canonical   — a real git repo (the fixture canonical clone)
#   <sandbox>/projects     — the fixture PROJECTS_ROOT
#   <sandbox>/trellis.config.json — points trellis_root/projects_root at the above
# and exports $TRELLIS_CONFIG so config-load.sh resolves the FIXTURE config and
# never the worktree's real one (whose trellis_root is the live clone).
#
# Isolation invariant (asserted in at least one test): the doctor's
# "canonical clone:" header line must equal the fixture path. If it ever prints
# the live canonical clone path (the repo's own trellis_root) instead, the test
# has leaked.
#
# bash 3.2 / bats 1.x. Path note: $CANON is captured once via `cd && pwd` and
# reused verbatim for the config's trellis_root, every symlink target, and every
# assertion — hc_rules_symlink string-compares readlink output against
# "$CANON/core-rules/CLAUDE.md", so the fixture must not mix /var with
# /private/var spellings.

# Resolve paths relative to this test file so the suite is portable (no
# machine-specific absolute paths — those would also leak into the public
# mirror). $BATS_TEST_DIRNAME is scripts/tests/, so ../.. is the repo root.
REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
# The repo's configured canonical clone — what doctor must NOT print when run
# against a fixture (proves the $TRELLIS_CONFIG override took effect).
LIVE_CANON="$(jq -r '.trellis_root' "$REPO_ROOT/trellis.config.json" 2>/dev/null || true)"

# The full canonical inheritance surface a healthy project carries. Kept in
# lockstep with HC_CANONICAL_SKILLS / HC_CANONICAL_COMMANDS in health-checks.sh.
CANON_SKILLS="process-gate security-gate clarify spec plan tasks analyze"
CANON_COMMANDS="primer primer-refresh primer-check explore autonomy"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through the real path so /var vs /private/var cannot diverge between
  # the symlink targets we write and the config's trellis_root.
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS"
  export TRELLIS_CONFIG="$CFG"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# Lay down the canonical inheritance surface (rules file, 7 skills, 5 commands,
# registry with one active "healthy" project, empty blacklist). Does NOT git
# init — branch/clean state is set per test by the helpers below.
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  local s c
  for s in $CANON_SKILLS; do
    mkdir -p "$CANON/core-rules/skills/$s"
    printf 'x\n' > "$CANON/core-rules/skills/$s/SKILL.md"
  done
  for c in $CANON_COMMANDS; do
    printf 'x\n' > "$CANON/core-rules/commands/$c.md"
  done
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| healthy | \`/personal/healthy\` | app | fixture |

---
EOF
  cat > "$CANON/blacklist.md" <<EOF
# Blacklist

## 1. Temporarily excluded (registered projects)

| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

## 2. Permanently excluded from management

| Path | Reason |
|---|---|

## Semantics
EOF
}

# git init the canonical on `main` and make one commit so the tree is clean.
git_init_canonical_main() {
  (
    cd "$CANON"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    git add -A
    git commit -q -m "init"
  )
}

# Write the fixture trellis.config.json. $1 (optional) = space-separated
# harness list as a JSON array body; defaults to just "claude" so codex/
# antigravity parity checks stay silent in the healthy path.
write_config() {
  local harnesses_json="${1:-\"claude\"}"
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": [$harnesses_json]
}
EOF
}

# Build a fully healthy "healthy" project: good rules symlink, canonical
# @-import, full skills + commands sets, and a .claude/settings.json (so the
# settings-wiring check does not WARN; with no canonical template present the
# wiring check then skips -> OK).
build_healthy_project() {
  local hp="$PROJECTS/healthy"
  mkdir -p "$hp/.claude/rules" "$hp/.claude/skills" "$hp/.claude/commands"
  ln -s "$CANON/core-rules/CLAUDE.md" "$hp/.claude/rules/trellis.md"
  local s c
  for s in $CANON_SKILLS; do
    ln -s "$CANON/core-rules/skills/$s" "$hp/.claude/skills/$s"
  done
  for c in $CANON_COMMANDS; do
    ln -s "$CANON/core-rules/commands/$c.md" "$hp/.claude/commands/$c.md"
  done
  cat > "$hp/CLAUDE.md" <<EOF
# Healthy project

@$CANON/core-rules/CLAUDE.md
EOF
  printf '{ "hooks": {} }\n' > "$hp/.claude/settings.json"
}

# Run the doctor against the fixture. $TRELLIS_CONFIG is already exported in
# setup(), so this can never hit the live config. Run from the worktree root
# (NOT inside the fixture canonical) to mirror real use — doctor resolves the
# canonical from config, not cwd.
run_doctor() {
  run bash "$DOCTOR" "$@"
}

# ===========================================================================
# Tier 0
# ===========================================================================

@test "isolation: doctor reports the FIXTURE canonical path, never the live clone" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [[ "$output" == *"canonical clone: $CANON"* ]]
  [[ -z "$LIVE_CANON" || "$output" != *"$LIVE_CANON"* ]]
}

@test "Tier-0: GREEN when fixture canonical is on main + clean" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ canonical clone is on main"* ]]
  [[ "$output" == *"✓ canonical clone is clean"* ]]
}

@test "Tier-0 GATE: feature-branch canonical => ERROR + non-zero exit, even though the project's rules symlink resolves" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Move the canonical off main onto a real feature branch. The project still
  # symlinks correctly into it — only Tier-0 can catch this poisoning.
  ( cd "$CANON" && git checkout -q -b feat/some-work )

  run_doctor
  # (a) Tier-0 fires the off-main ERROR.
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat/some-work"* ]]
  [[ "$output" == *"expected: main"* ]]
  [[ "$output" == *"✗ inheritance is broken"* ]]
  # (b) The per-project rules check is GREEN — proving the non-zero exit comes
  # from Tier-0, not from a broken symlink. This is what makes the gate
  # load-bearing.
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
}

@test "Tier-0: dirty canonical (uncommitted change) => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Dirty the working tree after the clean commit.
  printf 'drift\n' >> "$CANON/core-rules/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ canonical clone has uncommitted changes"* ]]
}

@test "Tier-0: canonical AHEAD of origin/main is NOT an error (no false positive)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Add a second commit, then plant a local origin/main ref one commit behind
  # HEAD (no network). Now HEAD is 1 ahead of origin/main — the normal state
  # for the source-of-truth clone.
  (
    cd "$CANON"
    printf 'more\n' >> core-rules/CLAUDE.md
    git add -A && git commit -q -m "second"
    git update-ref refs/remotes/origin/main HEAD~1
  )

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"ahead of origin/main"* ]]
  # Ahead is reported with the OK glyph, never the error glyph.
  [[ "$output" == *"✓"*"ahead of origin/main"* ]]
}

# ===========================================================================
# Tier 1
# ===========================================================================

@test "Tier-1: fully healthy project => all ✓ and exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
  [[ "$output" == *"✓ import: @-import matches canonical"* ]]
  [[ "$output" == *"✓ skills: full canonical set resolves"* ]]
  [[ "$output" == *"✓ commands: full canonical set resolves"* ]]
  # No ERROR row anywhere.
  [[ "$output" != *"✗"* ]]
}

@test "Tier-1: missing rules symlink => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ rules:"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "Tier-1: stale/broken rules symlink target => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Repoint the symlink at a dead cross-machine path (incident #1 shape).
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ rules:"* ]]
  # Reports the wrong/stale target it found.
  [[ "$output" == *"/Users/helios/"* ]]
}

@test "Tier-1: missing @-import => WARN (not ERROR), exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # CLAUDE.md present but with no canonical @-import line at all.
  printf '# Healthy project\n\nNo import here.\n' > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ import:"* ]]
  # Symlink still resolves, so this is a degraded-not-broken state.
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
  # No ERROR: the summary reports zero errors and the broken-inheritance line
  # does not fire. (The ✗ glyph still appears as the summary's error LABEL —
  # "✗ 0 error(s)" — so we assert on the error signal, not the bare glyph.)
  [[ "$output" == *"✗ 0 error(s)"* ]]
  [[ "$output" != *"✗ inheritance is broken"* ]]
}

@test "Tier-1: dead/cross-machine @-import => ERROR + non-zero exit, rules symlink still ✓" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Present-but-DEAD @-import (incident #1's literal shape: curat.money's import
  # pointed at /Users/helios/...). The rules symlink is left healthy so the only
  # ERROR source is the import branch — this isolates hc_import_resolves's
  # HC_ERROR path from the rules-symlink ERROR path (test 8).
  printf '# Healthy project\n\n@/Users/helios/claude/se-core-template/core-rules/CLAUDE.md\n' \
    > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ import:"* ]]
  # Reports the dead cross-machine target it found.
  [[ "$output" == *"/Users/helios/"* ]]
  # Load-bearing: the rules symlink is GREEN, proving the non-zero exit comes
  # from the import ERROR, not a broken symlink.
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
}

@test "Tier-1: codex harness lacking parity artifacts => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  # Enable the codex harness. build_healthy_project lays down no AGENTS.md /
  # .agents/ / .codex/ surface, so the codex parity check WARNs with no extra
  # setup. This exercises hc_harness_artifacts's codex branch (silent under the
  # claude-only default).
  write_config '"claude","codex"'

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ harness[codex]: missing parity artifact(s)"* ]]
  # Missing parity is degraded, not broken: no inheritance ERROR.
  [[ "$output" != *"✗ inheritance is broken"* ]]
}

@test "Tier-1: missing skill => WARN (not ERROR), exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Drop one canonical skill symlink from the project.
  rm -f "$PROJECTS/healthy/.claude/skills/analyze"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ skills:"* ]]
  [[ "$output" == *"analyze"* ]]
  # Degraded, not broken: zero errors, no broken-inheritance line.
  [[ "$output" == *"✗ 0 error(s)"* ]]
  [[ "$output" != *"✗ inheritance is broken"* ]]
}

# ===========================================================================
# Exit-code polarity: 0 iff no ERROR present.
# ===========================================================================

@test "exit code: WARN-only run exits 0; ERROR run exits 1" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config

  # WARN-only: drop a skill -> ⚠ but exit 0.
  rm -f "$PROJECTS/healthy/.claude/skills/spec"
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠"* ]]
  [[ "$output" != *"✗ inheritance is broken"* ]]

  # Now introduce an ERROR (kill the rules symlink) -> exit 1.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]]
}
