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
SHARED_FIXTURE="$BATS_TEST_DIRNAME/fixtures/shared-infra"
# The repo's configured canonical clone — what doctor must NOT print when run
# against a fixture (proves the $TRELLIS_CONFIG override took effect).
LIVE_CANON="$(jq -r '.trellis_root' "$REPO_ROOT/trellis.config.json" 2>/dev/null || true)"

# The full canonical inheritance surface a healthy project carries. Kept in
# lockstep with HC_CANONICAL_SKILLS / HC_CANONICAL_COMMANDS in health-checks.sh.
CANON_SKILLS="process-gate security-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing"
CANON_COMMANDS="primer primer-refresh primer-check explore autonomy surgical"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through the real path so /var vs /private/var cannot diverge between
  # the symlink targets we write and the config's trellis_root.
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  SHARED="$SANDBOX/shared-infra"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS"
  DOCTOR_SHARED_OVERRIDE=""
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

# Lay down the canonical inheritance surface (rules file, skills, commands,
# empty OMP agents dir + hook adapter, registry with one active "healthy"
# project, empty blacklist). The skills/commands manifests carry OMP discovery
# frontmatter (hc_omp_manifests requires it), the agents dir holds only a
# .gitkeep (the GPTX-era custom agents were removed — empty is healthy), and
# the OMP adapter stub exists (hc_omp_adapter requires it) — a healthy
# canonical is OMP-healthy too. Does NOT git init — branch/clean state is set
# per test by the helpers below.
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands" \
    "$CANON/core-rules/agents" "$CANON/core-rules/omp/hooks/pre"
  # A healthy canonical carries the dod-receipt grammar anchor (Tier-0
  # hc_receipt_grammar_present greps for the literal `dod-receipt`).
  printf '# Parent engineering rules\n\n<!-- dod-receipt cmd= exit=0 diff= -->\n' \
    > "$CANON/core-rules/CLAUDE.md"
  local s c
  for s in $CANON_SKILLS; do
    mkdir -p "$CANON/core-rules/skills/$s"
    printf -- '---\nname: %s\ndescription: fixture skill %s\n---\n\nx\n' \
      "$s" "$s" > "$CANON/core-rules/skills/$s/SKILL.md"
  done
  for c in $CANON_COMMANDS; do
    printf -- '---\ndescription: fixture command %s\n---\n\nx\n' \
      "$c" > "$CANON/core-rules/commands/$c.md"
  done
  # The canonical agents dir is EMPTY (the GPTX-era custom agents were removed;
  # only .gitkeep remains) — an empty .omp/agents target is healthy.
  printf '' > "$CANON/core-rules/agents/.gitkeep"
  printf 'export const trellisAdapter = () => ({});\n' \
    > "$CANON/core-rules/omp/hooks/pre/trellis.ts"
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
# harness list as a JSON array body; defaults to Claude + OMP so Codex parity
# checks stay silent while the OMP contract remains active.
write_config() {
  local harnesses_json="${1:-\"claude\",\"omp\"}"
  local shared_root="${2:-}"
  local shared_line=""
  if [ -n "$shared_root" ]; then
    shared_line="  \"shared_infra_root\": \"$shared_root\","
  fi
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
$shared_line
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": [$harnesses_json]
}
EOF
}

build_shared_infra_fixture() {
  mkdir -p "$SHARED"
  cp "$SHARED_FIXTURE/Makefile" "$SHARED/Makefile"
  cp "$SHARED_FIXTURE/projects.yaml" "$SHARED/projects.yaml"
  rm -f "$SHARED/calls.log" "$SHARED/drift"
}

# Build a fully healthy "healthy" project: good rules symlink, canonical
# @-import, full skills + commands sets, a .claude/settings.json (so the
# settings-wiring check does not WARN; with no canonical template present the
# wiring check then skips -> OK), and the five OMP surface links (design
# 2026-08-09) so the OMP checks are green in every healthy-path test.
build_healthy_project() {
  local hp="$PROJECTS/healthy"
  mkdir -p "$hp/.claude/rules" "$hp/.claude/skills" "$hp/.claude/commands" "$hp/.omp"
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
  # OMP surface: the five exact live links in the shared contract.
  ln -s "$hp/CLAUDE.md" "$hp/.omp/AGENTS.md"
  ln -s "$CANON/core-rules/skills" "$hp/.omp/skills"
  ln -s "$CANON/core-rules/commands" "$hp/.omp/commands"
  ln -s "$CANON/core-rules/agents" "$hp/.omp/agents"
  ln -s "$CANON/core-rules/omp/hooks" "$hp/.omp/hooks"
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
  if [ -n "$DOCTOR_SHARED_OVERRIDE" ]; then
    run env SHARED_INFRA_ROOT="$DOCTOR_SHARED_OVERRIDE" bash "$DOCTOR" "$@"
  else
    run env -u SHARED_INFRA_ROOT bash "$DOCTOR" "$@"
  fi
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

@test "Tier-0 shared infrastructure rows delegate validate and doctor through the configured repository" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"

  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"✓ shared-infra override: resolved path matches config ($SHARED)"* ]]
  [[ "$output" == *"✓ shared-infra path: $SHARED"* ]]
  [[ "$output" == *"✓ shared-infra manifest: schema and allocation validation passed"* ]]
  [[ "$output" == *"✓ shared-infra doctor: registry parity, runtime, and fixed-port checks passed"* ]]
  grep -F 'validate PROJECT= PROJECTS_FILE=' "$SHARED/calls.log"
  grep -F "doctor PROJECT= REGISTRY_FILE=$CANON/registry.md" "$SHARED/calls.log"
}

@test "Tier-0 shared infrastructure warns when project-side default differs from configured root" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  local project_default="$SANDBOX/test-home/projects/shared-infra"

  run env -u SHARED_INFRA_ROOT HOME="$SANDBOX/test-home" bash "$DOCTOR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"⚠ shared-infra override: resolved $project_default differs from config $SHARED — set SHARED_INFRA_ROOT=$SHARED"* ]]
}

@test "Tier-0 shared infrastructure drift fails read-only and leaves drift plus manifest unchanged" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  printf 'deliberate drift\n' > "$SHARED/drift"
  local manifest_before drift_before
  manifest_before="$(shasum -a 256 "$SHARED/projects.yaml" | awk '{print $1}')"
  drift_before="$(shasum -a 256 "$SHARED/drift" | awk '{print $1}')"

  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ shared-infra doctor: read-only checks failed"* ]]
  [[ "$output" == *"deliberate drift remains"* ]]
  [ "$(shasum -a 256 "$SHARED/projects.yaml" | awk '{print $1}')" = "$manifest_before" ]
  [ "$(shasum -a 256 "$SHARED/drift" | awk '{print $1}')" = "$drift_before" ]
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
  [[ "$output" == *"✓ healthy — no drift detected"* ]]
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

@test "Tier-1: missing @-import => Claude WARN but OMP parent-chain ERROR (exit non-zero)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # CLAUDE.md present but with no canonical @-import line at all. The Claude
  # surface degrades to WARN (hc_import_resolves: symlink-only fallback), but
  # OMP installs no RULES.md and has no symlinked rules file — the AGENTS.md
  # @-import is the ONLY channel for parent rules, so the missing import is an
  # OMP inheritance break (hc_omp_project_import ERROR, non-zero exit).
  printf '# Healthy project\n\nNo import here.\n' > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  # Claude row: degraded-not-broken (⚠ WARN), rules symlink still resolves.
  [[ "$output" == *"⚠ import:"* ]]
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
  # OMP row: the missing import is an ERROR — OMP would inherit no parent rules.
  [[ "$output" == *"✗ omp-import:"* ]]
  [[ "$output" == *"no @-import"* ]]
  [[ "$output" == *"✗ inheritance is broken"* ]]
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
  # The OMP parent chain is broken by the same dead import (ERROR row).
  [[ "$output" == *"✗ omp-import:"* ]]
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

@test "adopt-008 hc_claudemd_budget (Tier-0): canonical CLAUDE.md under line budget => OK" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # The default fixture CLAUDE.md is only a few lines — well under the 200-line
  # attention budget, so the guardrail is OK.
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ claudemd-budget: core-rules/CLAUDE.md is"* ]]
  [[ "$output" == *"(budget: 200)"* ]]
}

@test "adopt-008 hc_claudemd_budget (Tier-0): canonical CLAUDE.md over line budget => WARN, exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Grow the canonical rules past the 200-line attention budget while KEEPING the
  # dod-receipt anchor (so receipt-grammar stays OK and this WARN is isolated),
  # then re-commit so the canonical tree stays clean (else the Tier-0 dirty check
  # would also fire and mask the result).
  {
    printf '# Parent engineering rules\n\n<!-- dod-receipt cmd= exit=0 diff= -->\n'
    i=1
    while [ "$i" -le 250 ]; do
      printf -- '- rule line %s\n' "$i"
      i=$((i + 1))
    done
  } > "$CANON/core-rules/CLAUDE.md"
  ( cd "$CANON" && git add -A && git commit -q -m "grow parent rules past budget" )

  run_doctor
  # Chained terminal assertion (DL-P8a-12): WARN substring is the final
  # discriminator so the test goes RED under an always-HC_OK mutation.
  [[ "$output" != *"✗ inheritance is broken"* ]]
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"⚠ claudemd-budget:"* ]] \
    && [[ "$output" == *"past the attention cliff"* ]]
}

# ===========================================================================
# OMP surface (design 2026-08-09) — Tier-1 live-link contract. All ERROR-class:
# OMP native discovery stops at the nearest non-empty .omp dir, so any broken
# Trellis-owned .omp path silently yields an unparented OMP session.
# ===========================================================================

@test "OMP: fully healthy OMP surface => all ✓ and exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]]
  [[ "$output" == *"✓ omp: target kinds correct and canonical links stay under trellis_root"* ]]
  [[ "$output" == *"✓ omp-import: first @-import → canonical core-rules/CLAUDE.md"* ]]
  [[ "$output" == *"✓ omp-manifests: canonical skill/command/agent manifests satisfy OMP discovery"* ]]
  [[ "$output" == *"✓ omp-adapter: canonical adapter present"* ]]
}

@test "OMP: disabled harness imposes no .omp or canonical OMP dependency" {
  build_canonical_tree
  rm -rf "$CANON/core-rules/agents" "$CANON/core-rules/omp"
  git_init_canonical_main
  build_healthy_project
  rm -rf "$PROJECTS/healthy/.omp"
  write_config '"claude"'

  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"omp:"* ]]
  [[ "$output" != *"omp-import:"* ]]
  [[ "$output" != *"omp-manifests:"* ]]
  [[ "$output" != *"omp-adapter:"* ]]
}

@test "OMP: missing .omp/AGENTS.md => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.omp/AGENTS.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/AGENTS.md missing"* ]]
}

@test "OMP: dangling .omp/skills symlink => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.omp/skills"
  ln -s "$CANON/core-rules/skills-does-not-exist" "$PROJECTS/healthy/.omp/skills"
  [ ! -e "$PROJECTS/healthy/.omp/skills" ]  # precondition: truly dangling

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/skills →"* ]]
  [[ "$output" == *"dangling"* ]]
}

@test "OMP: wrong-target .omp/agents link => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Repoint at a dead cross-machine path (incident #1 shape).
  rm -f "$PROJECTS/healthy/.omp/agents"
  ln -s "/Users/helios/claude/se-core-template/core-rules/agents" \
        "$PROJECTS/healthy/.omp/agents"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/agents →"* ]]
  # Reports the wrong/stale target it found.
  [[ "$output" == *"/Users/helios/"* ]]
}

@test "OMP: .omp/skills replaced by a regular file (not a symlink) => ERROR" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.omp/skills"
  printf 'not a link\n' > "$PROJECTS/healthy/.omp/skills"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp: .omp/skills exists but is not a symlink"* ]]
}

@test "OMP: wrong target kind (dir link resolving to a regular file) => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Replace the canonical hooks DIRECTORY with a regular FILE at the same path,
  # then re-commit so the canonical stays clean: .omp/hooks still has the exact
  # literal target (link row stays ✓) but resolves to a non-directory — only
  # the target-kind half of the contract can catch this.
  rm -rf "$CANON/core-rules/omp/hooks"
  printf 'not a dir\n' > "$CANON/core-rules/omp/hooks"
  ( cd "$CANON" && git add -A && git commit -q -m "hooks path becomes a file" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]]
  [[ "$output" == *"✗ omp: .omp/hooks resolves to a non-directory target"* ]]
}

@test "OMP: realpath containment — canonical link resolving OUTSIDE trellis_root => ERROR" {
  build_canonical_tree
  # Redirect core-rules/skills out of the canonical root BEFORE the git init so
  # the committed tree is clean: the .omp/skills link still reads
  # <canon>/core-rules/skills (exact target ✓) but its realpath escapes
  # trellis_root — only the containment half of the contract can catch this.
  mkdir -p "$SANDBOX/elsewhere/skills/process-gate"
  printf -- '---\ndescription: elsewhere skill\n---\n\nx\n' \
    > "$SANDBOX/elsewhere/skills/process-gate/SKILL.md"
  mv "$CANON/core-rules/skills" "$CANON/core-rules/skills.orig"
  ln -s "$SANDBOX/elsewhere/skills" "$CANON/core-rules/skills"
  git_init_canonical_main
  build_healthy_project
  write_config

  run_doctor
  [ "$status" -ne 0 ]
  # Load-bearing: the exact-target row is GREEN — the ERROR comes from the
  # containment check, not from re-detecting a wrong target.
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]]
  [[ "$output" == *"✗ omp: .omp/skills resolves to"* ]]
  [[ "$output" == *"OUTSIDE the canonical root"* ]]
}

@test "OMP: first @-import is NOT canonical => ERROR even when a later import is" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # A project-local import FIRST, the canonical one second. The Claude-side
  # check (hc_import_resolves) scans every import and is satisfied; the OMP
  # check requires the FIRST import to be canonical (OMP resolves imports
  # top-down and the design pins "whose first import resolves canonical").
  printf '# Healthy project\n\n@docs/strategy.md\n@%s/core-rules/CLAUDE.md\n' \
    "$CANON" > "$PROJECTS/healthy/CLAUDE.md"

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✓ import: @-import matches canonical"* ]]
  [[ "$output" == *"✗ omp-import:"* ]]
  [[ "$output" == *"docs/strategy.md"* ]]
}

@test "OMP: skill dir missing SKILL.md => manifest ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$CANON/core-rules/skills/analyze/SKILL.md"
  # Re-commit so the canonical stays clean (else Tier-0 dirty would mask the
  # manifest row). The Claude-side skill LINK still resolves (dir remains).
  ( cd "$CANON" && git add -A && git commit -q -m "break skill manifest" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-manifests:"* ]]
  [[ "$output" == *"analyze"* ]]
  [[ "$output" == *"✓ skills: full canonical set resolves"* ]]
}

@test "OMP: command without description frontmatter => manifest ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  printf 'no frontmatter\n' > "$CANON/core-rules/commands/primer.md"
  ( cd "$CANON" && git add -A && git commit -q -m "strip command description" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-manifests:"* ]]
  [[ "$output" == *"primer"* ]]
}

@test "OMP: legacy .md agent still discoverable in canonical agents dir => manifest ERROR" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # The custom fable/opus/codex/lane agents are GPTX-era and removed; any
  # discoverable *.md left behind is a legacy agent OMP would load (first-win
  # by name) and must be purged. Empty (only .gitkeep) is the healthy state.
  printf '# legacy agent\n' > "$CANON/core-rules/agents/legacy-agent.md"
  ( cd "$CANON" && git add -A && git commit -q -m "legacy agent resurfaces" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-manifests:"* ]]
  [[ "$output" == *"agents:legacy-agent.md"* ]]
}

@test "OMP: canonical adapter missing => ERROR + non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$CANON/core-rules/omp/hooks/pre/trellis.ts"
  ( cd "$CANON" && git add -A && git commit -q -m "drop adapter" )

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ omp-adapter: canonical adapter"* ]]
  [[ "$output" == *"missing"* ]]
  # The .omp/hooks LINK itself still resolves to the (empty) hooks dir — the
  # adapter row is the isolated failure.
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]]
}

@test "OMP: canonical control-plane project — .omp/AGENTS.md → core-rules/CLAUDE.md, no parent import" {
  build_canonical_tree
  # The canonical clone carries its own ignored .claude/.omp/.husky surfaces
  # (managed-ignore pattern); commit the ignore so the tree stays clean while
  # those surfaces are untracked.
  printf '.claude/\n.omp/\n.husky/\n' > "$CANON/.gitignore"
  git_init_canonical_main
  # Register the canonical clone itself as a control-plane project. The
  # canonical root has no CLAUDE.md (build_canonical_tree writes only
  # core-rules/CLAUDE.md), so the OMP contract expects .omp/AGENTS.md to link
  # the parent rules file directly and skips the parent-import check.
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| trellis | \`/trellis\` | control-plane | canonical clone itself |
| healthy | \`/personal/healthy\` | app | fixture |

---
EOF
  ( cd "$CANON" && git add registry.md && git commit -q -m "register control-plane" )
  # $PROJECTS/trellis IS the canonical clone (realpath-equal) — the shape
  # doctor resolves for a control-plane registry row.
  ln -s "$CANON" "$PROJECTS/trellis"
  local cp="$PROJECTS/trellis"
  # Seed the canonical's own inheritance surfaces (ignored -> tree stays clean).
  mkdir -p "$cp/.claude/rules" "$cp/.claude/skills" "$cp/.claude/commands" \
    "$cp/.omp" "$cp/.husky"
  ln -s "$CANON/core-rules/CLAUDE.md" "$cp/.claude/rules/trellis.md"
  local s c
  for s in $CANON_SKILLS; do
    ln -s "$CANON/core-rules/skills/$s" "$cp/.claude/skills/$s"
  done
  for c in $CANON_COMMANDS; do
    ln -s "$CANON/core-rules/commands/$c.md" "$cp/.claude/commands/$c.md"
  done
  printf '{ "hooks": {} }\n' > "$cp/.claude/settings.json"
  printf '#!/usr/bin/env sh\nbash .claude/skills/process-gate/scripts/run-all.sh --mode=merge\n' \
    > "$cp/.husky/pre-push"
  # OMP control-plane surface: AGENTS.md links the parent rules FILE.
  ln -s "$CANON/core-rules/CLAUDE.md" "$cp/.omp/AGENTS.md"
  ln -s "$CANON/core-rules/skills" "$cp/.omp/skills"
  ln -s "$CANON/core-rules/commands" "$cp/.omp/commands"
  ln -s "$CANON/core-rules/agents" "$cp/.omp/agents"
  ln -s "$CANON/core-rules/omp/hooks" "$cp/.omp/hooks"
  build_healthy_project
  write_config

  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The control-plane project's .omp/AGENTS.md links the parent rules FILE...
  [ "$(readlink "$cp/.omp/AGENTS.md")" = "$CANON/core-rules/CLAUDE.md" ]
  # ...and passes without a parent-import row (there is no parent above it).
  [[ "$output" == *"✓ omp: all 5 surface links resolve to exact canonical targets"* ]]
  [[ "$output" == *"✓ omp-import: canonical control-plane project"* ]]
  # The ordinary healthy project still requires its own CLAUDE.md import.
  [[ "$output" == *"✓ omp-import: first @-import → canonical core-rules/CLAUDE.md"* ]]
}
