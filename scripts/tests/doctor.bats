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
  # A healthy canonical carries the dod-receipt grammar anchor (Tier-0
  # hc_receipt_grammar_present greps for the literal `dod-receipt`).
  printf '# Parent engineering rules\n\n<!-- dod-receipt cmd= exit=0 diff= -->\n' \
    > "$CANON/core-rules/CLAUDE.md"
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
  # A healthy project has its pre-push wired to process-gate's run-all.sh so
  # hc_prepush_wired_runall passes. (No review hook + no tracked UI files keep
  # hc_reviewer_resolvable / hc_ui_screenshot_path silently OK by default.)
  mkdir -p "$hp/.husky"
  printf '#!/usr/bin/env sh\nbash .claude/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$hp/.husky/pre-push"
}

# Run the doctor against the fixture. $TRELLIS_CONFIG is already exported in
# setup(), so this can never hit the live config. Run from the worktree root
# (NOT inside the fixture canonical) to mirror real use — doctor resolves the
# canonical from config, not cwd.
run_doctor() {
  run bash "$DOCTOR" "$@"
}

# Build a symlink-farm bin dir under $BATS_TEST_TMPDIR that mirrors EVERY
# executable on the current PATH EXCEPT any named `playwright`, then print the
# farm dir. Adapts the make_jq_free_path symlink-farm idiom from
# core-rules/hooks/tests/helpers.bash but enumerates the FULL PATH (not a fixed
# command list) so doctor's complete toolchain — git + its helpers, jq, shasum,
# coreutils — resolves under the farm and only `playwright` is excluded
# (DL-P8a-12 hermeticity: the no-screenshot-tool WARN branch must be reached on
# EVERY host, including this operator's, where playwright IS on the real PATH).
# First-wins on basename collisions to preserve PATH precedence order. Local to
# this suite — NOT cross-sourced from the hooks test dir.
make_no_playwright_path() {
  local farm dir entry base
  farm="$(mktemp -d "$BATS_TEST_TMPDIR/farm.XXXXXX")"
  # Split PATH on ':' without a subshell-unsafe IFS leak.
  local oldifs="$IFS"
  IFS=':'
  for dir in $PATH; do
    IFS="$oldifs"
    [ -d "$dir" ] || { IFS=':'; continue; }
    for entry in "$dir"/*; do
      [ -x "$entry" ] && [ ! -d "$entry" ] || continue
      base="$(basename "$entry")"
      [ "$base" = "playwright" ] && continue
      # First-wins: do not overwrite an earlier (higher-precedence) link.
      [ -e "$farm/$base" ] && continue
      ln -s "$entry" "$farm/$base"
    done
    IFS=':'
  done
  IFS="$oldifs"
  printf '%s' "$farm"
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

# ===========================================================================
# Phase 8a — process-enforcement inheritance-health checks (all WARN-class,
# never flip the exit; DL-P8a-01..05). Static: never invoke the subject.
# ===========================================================================

@test "P8a hc_reviewer_resolvable: review hook wired + reviewer lib MISSING => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Wire the review hook but leave its sibling lib absent.
  mkdir -p "$PROJECTS/healthy/.claude/hooks"
  printf '#!/usr/bin/env bash\n: review\n' \
    > "$PROJECTS/healthy/.claude/hooks/code-review-subagent.sh"

  run_doctor
  # bats fails only on the LAST command, so the load-bearing WARN assertion is
  # chained into ONE terminal statement (DL-P8a-12): any failing conjunct aborts
  # the test, and the WARN-specific substring is the final discriminator (flips
  # RED under an always-HC_OK mutation of hc_reviewer_resolvable).
  [[ "$output" != *"✗ inheritance is broken"* ]]
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ reviewer-resolvable:"* ]] \
    && [[ "$output" == *"lib/code-reviewer.sh MISSING"* ]]
}

@test "P8a hc_reviewer_resolvable: no review hook => OK (no manufactured noise)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # build_healthy_project wires no review hook at all.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ reviewer-resolvable: no review hook wired"* ]]
}

@test "P8a hc_reviewer_resolvable: review hook + reviewer lib both present => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  mkdir -p "$PROJECTS/healthy/.claude/hooks/lib"
  printf '#!/usr/bin/env bash\n: review\n' \
    > "$PROJECTS/healthy/.claude/hooks/code-review-subagent.sh"
  printf '#!/usr/bin/env bash\n: reviewer-lib\n' \
    > "$PROJECTS/healthy/.claude/hooks/lib/code-reviewer.sh"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ reviewer-resolvable: review hook + reviewer lib both present"* ]]
}

@test "P8a hc_ui_screenshot_path: tracked UI files + no screenshot tool => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # The project must be a git work tree with a TRACKED UI source file for
  # `git ls-files` to enumerate it.
  (
    cd "$PROJECTS/healthy"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    printf 'export const X = 1;\n' > App.tsx
    git add App.tsx
    git commit -q -m "ui"
  )
  # HERMETIC (DL-P8a-12): the WARN branch is gated on `command -v playwright`,
  # which RESOLVES on this operator's host (pyenv shim) — so without isolation
  # the doctor would run the OPPOSITE (resolvable-tool) branch and the WARN
  # assertion would be false-green. Run the doctor child under a sanitized PATH
  # that mirrors every executable EXCEPT playwright, so the no-tool WARN branch
  # is deterministically reached on EVERY host. UI_SHOT_CMD="" closes the first
  # leg of "no resolvable tool".
  local farm
  farm="$(make_no_playwright_path)"
  run env PATH="$farm" UI_SHOT_CMD="" bash "$DOCTOR"
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK / resolvable-✓
  # mutation of hc_ui_screenshot_path.
  [[ "$output" != *"✗ inheritance is broken"* ]]
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ ui-screenshot-path:"* ]] \
    && [[ "$output" == *"no screenshot tool resolves"* ]]
}

@test "P8a hc_ui_screenshot_path: non-UI project => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # build_healthy_project is not a git work tree and tracks no UI files, so
  # `git ls-files` is empty -> not a UI project.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ ui-screenshot-path: no tracked UI source files"* ]]
}

@test "P8a hc_prepush_wired_runall: no pre-push hook => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Remove the pre-push the healthy fixture wires.
  rm -f "$PROJECTS/healthy/.husky/pre-push"

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]]
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ prepush-wired-runall:"* ]] \
    && [[ "$output" == *"no pre-push hook"* ]]
}

@test "P8a hc_prepush_wired_runall: pre-push present but NOT wired to run-all.sh => WARN" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Overwrite the wired hook with one that does not reference run-all.sh.
  printf '#!/usr/bin/env sh\nnpm test\n' > "$PROJECTS/healthy/.husky/pre-push"

  run_doctor
  # Chained terminal assertion (DL-P8a-12): the dead non-final `status` check is
  # folded into one statement ending on the WARN-specific discriminator.
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ prepush-wired-runall:"* ]] \
    && [[ "$output" == *"not wired to run-all.sh"* ]]
}

@test "P8a hc_prepush_wired_runall: pre-push wired to run-all.sh => OK (.git/hooks fallback)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Drop the .husky hook and instead wire .git/hooks/pre-push (the fallback
  # location) referencing the .agents/ path variant.
  rm -f "$PROJECTS/healthy/.husky/pre-push"
  mkdir -p "$PROJECTS/healthy/.git/hooks"
  printf '#!/usr/bin/env sh\nbash .agents/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$PROJECTS/healthy/.git/hooks/pre-push"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ prepush-wired-runall: pre-push references process-gate run-all.sh"* ]]
}

@test "P8a hc_prepush_wired_runall: native core.hooksPath=.githooks wired to run-all.sh => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Native-git-hooks project (lume / clusterbid-console shape): no husky, the
  # active hook lives at .githooks/pre-push via core.hooksPath. Reading
  # core.hooksPath needs a real repo, so git-init the project and pin the config.
  local hp="$PROJECTS/healthy"
  rm -rf "$hp/.husky"
  (
    cd "$hp"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config core.hooksPath .githooks
  )
  mkdir -p "$hp/.githooks"
  printf '#!/usr/bin/env sh\nbash .claude/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$hp/.githooks/pre-push"

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ prepush-wired-runall: pre-push references process-gate run-all.sh"* ]]
}

@test "P8a hc_prepush_wired_runall: core.hooksPath set but target pre-push missing => WARN" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # No false positive: hooksPath points at .githooks but no .githooks/pre-push
  # exists, and a stale .husky/pre-push (the fixture default) must NOT be
  # consulted because git would never run it.
  local hp="$PROJECTS/healthy"
  (
    cd "$hp"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config core.hooksPath .githooks
  )
  mkdir -p "$hp/.githooks"

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]]
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ prepush-wired-runall:"* ]] \
    && [[ "$output" == *"no pre-push hook"* ]]
}

@test "P8a hc_receipt_grammar_present (Tier-0): canonical CLAUDE.md MISSING dod-receipt => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Strip the dod-receipt grammar from the canonical rules, then re-commit so
  # the canonical tree stays clean (else the Tier-0 dirty check would fire too).
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  ( cd "$CANON" && git add -A && git commit -q -m "strip receipt grammar" )

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]]
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ receipt-grammar-present:"* ]] \
    && [[ "$output" == *"dod-receipt grammar MISSING"* ]]
}

@test "P8a hc_receipt_grammar_present (Tier-0): canonical CLAUDE.md with dod-receipt => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # build_canonical_tree now lays down the dod-receipt anchor.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ receipt-grammar-present: dod-receipt grammar present"* ]]
}
