#!/usr/bin/env bats
# Tests for scripts/seed-inheritance-symlinks.sh
#
# FULLY ISOLATED — every test builds its own fixture in a mktemp dir.
# No absolute paths are hardcoded; all paths derived from $BATS_TEST_DIRNAME.
#
# Fixture layout:
#   $SANDBOX/root/         — fake TRELLIS_ROOT with core-rules/
#   $SANDBOX/main/         — fake MAIN git checkout with inheritance symlinks
#                            (.claude/, .agents/, and .omp/ surfaces)
#   $SANDBOX/wt/           — fake linked worktree (via git worktree add)

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/seed-inheritance-symlinks.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through real path so /var vs /private/var cannot diverge
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"

  ROOT="$SANDBOX/root"
  MAIN="$SANDBOX/main"
  WT="$SANDBOX/wt"

  # ---- Build fake TRELLIS_ROOT ----
  mkdir -p \
    "$ROOT/core-rules/skills/process-gate" \
    "$ROOT/core-rules/skills/security-gate" \
    "$ROOT/core-rules/agents" \
    "$ROOT/core-rules/commands" \
    "$ROOT/core-rules/omp/hooks"
  printf '# Trellis rules\n' > "$ROOT/core-rules/CLAUDE.md"
  printf 'x\n' > "$ROOT/core-rules/skills/process-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/skills/security-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/agents/verify-agent.md"
  printf 'x\n' > "$ROOT/core-rules/commands/primer.md"

  # ---- Build fake MAIN checkout ----
  mkdir -p "$MAIN"
  (
    cd "$MAIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false

    # .gitignore — ignore the inheritance symlink directories (incl. .omp)
    printf '.claude/rules\n.claude/skills\n.claude/commands\n.claude/agents\n.agents/rules\n.agents/skills\n.omp/AGENTS.md\n.omp/skills\n.omp/commands\n.omp/agents\n.omp/hooks\n' > .gitignore

    # Tracked files so git worktree add works and the worktree gets its own
    # CLAUDE.md (the .omp/AGENTS.md target is the checkout's own overlay).
    printf 'tracked\n' > README.md
    printf '# project overlay\n' > CLAUDE.md
    git add README.md CLAUDE.md .gitignore
    git commit -q -m "init"
  )

  # Create inheritance symlinks in MAIN
  mkdir -p \
    "$MAIN/.claude/rules" \
    "$MAIN/.claude/skills" \
    "$MAIN/.claude/commands" \
    "$MAIN/.claude/agents" \
    "$MAIN/.omp"
  ln -s "$ROOT/core-rules/CLAUDE.md"              "$MAIN/.claude/rules/trellis.md"
  ln -s "$ROOT/core-rules/skills/process-gate"    "$MAIN/.claude/skills/process-gate"
  ln -s "$ROOT/core-rules/skills/security-gate"   "$MAIN/.claude/skills/security-gate"
  ln -s "$ROOT/core-rules/commands/primer.md"     "$MAIN/.claude/commands/primer.md"
  ln -s "$ROOT/core-rules/agents/verify-agent.md" "$MAIN/.claude/agents/verify-agent.md"

  # OMP live surface: one project-overlay file link plus four whole-directory
  # links into canonical core-rules.
  ln -s "$MAIN/CLAUDE.md"            "$MAIN/.omp/AGENTS.md"
  ln -s "$ROOT/core-rules/skills"    "$MAIN/.omp/skills"
  ln -s "$ROOT/core-rules/commands"  "$MAIN/.omp/commands"
  ln -s "$ROOT/core-rules/agents"    "$MAIN/.omp/agents"
  ln -s "$ROOT/core-rules/omp/hooks" "$MAIN/.omp/hooks"

  # Non-inheritance symlink that must NOT be mirrored
  ln -s "/tmp" "$MAIN/.claude/other"
  ln -s "/tmp" "$MAIN/.omp/other"

  # Create the linked worktree
  git -C "$MAIN" worktree add --detach "$WT" >/dev/null 2>&1
}

teardown() {
  if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ]; then
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: seeds all inheritance symlinks; non-inheritance .claude/other NOT
#         created in TARGET
# ---------------------------------------------------------------------------
@test "seeds all inheritance symlinks into worktree" {
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # All four inheritance symlinks exist in the worktree
  [ -L "$WT/.claude/rules/trellis.md" ]
  [ -L "$WT/.claude/skills/process-gate" ]
  [ -L "$WT/.claude/skills/security-gate" ]
  [ -L "$WT/.claude/commands/primer.md" ]

  # Targets match the originals
  [ "$(readlink "$WT/.claude/rules/trellis.md")"           = "$ROOT/core-rules/CLAUDE.md" ]
  [ "$(readlink "$WT/.claude/skills/process-gate")"        = "$ROOT/core-rules/skills/process-gate" ]
  [ "$(readlink "$WT/.claude/skills/security-gate")"       = "$ROOT/core-rules/skills/security-gate" ]
  [ "$(readlink "$WT/.claude/commands/primer.md")"         = "$ROOT/core-rules/commands/primer.md" ]

  # Non-inheritance symlinks (.claude/other → /tmp, .omp/other → /tmp) must
  # NOT be mirrored
  [ ! -e "$WT/.claude/other" ]
  [ ! -L "$WT/.claude/other" ]
  [ ! -e "$WT/.omp/other" ]
  [ ! -L "$WT/.omp/other" ]

  # Output contains "linked:" lines
  [[ "$output" == *"linked:"* ]]
  # Summary line
  [[ "$output" == *"seeded"*"symlink"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: idempotent — second run prints skip lines, makes no change
# ---------------------------------------------------------------------------
@test "idempotent: second run skips already-correct symlinks" {
  # First run seeds
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # Second run
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # All skip lines, no linked lines
  [[ "$output" == *"skip (correct symlink):"* ]]
  [[ "$output" != *"linked:"* ]]

  # Symlinks still correct
  [ "$(readlink "$WT/.claude/rules/trellis.md")" = "$ROOT/core-rules/CLAUDE.md" ]
}

# ---------------------------------------------------------------------------
# Test 3: wrong-target — pre-existing symlink with wrong target is left as-is;
#         WARN emitted; exit 0
# ---------------------------------------------------------------------------
@test "wrong-target symlink is left as-is with WARN, exit 0" {
  mkdir -p "$WT/.claude/skills"
  ln -s "/wrong/path" "$WT/.claude/skills/process-gate"

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # The wrong-target symlink is unchanged
  [ "$(readlink "$WT/.claude/skills/process-gate")" = "/wrong/path" ]

  # WARN message in output (bats merges stderr into $output)
  [[ "$output" == *"WARN:"* ]]
  [[ "$output" == *"process-gate"* ]]
  [[ "$output" == *"leaving as-is"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: --verify-only on unseeded target exits 1 and names a missing path;
#         after seeding, --verify-only exits 0
# ---------------------------------------------------------------------------
@test "--verify-only: exits 1 on missing symlinks, exits 0 after seeding" {
  # Unseeded: should fail
  run bash "$SCRIPT" --target "$WT" --root "$ROOT" --verify-only
  [ "$status" -eq 1 ]
  # Reports missing symlinks and names specific paths
  [[ "$output" == *"verify:"* ]]
  [[ "$output" == *"missing"* ]]
  [[ "$output" == *".claude/rules/trellis.md"* ]]

  # Seed first
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # Now verify should pass
  run bash "$SCRIPT" --target "$WT" --root "$ROOT" --verify-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify:"*"correct"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: --root override works
# ---------------------------------------------------------------------------
@test "--root override: seeding succeeds with explicit root" {
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # Inheritance symlinks present
  [ -L "$WT/.claude/rules/trellis.md" ]
  [ -L "$WT/.claude/skills/process-gate" ]
  [ -L "$WT/.claude/skills/security-gate" ]
  [ -L "$WT/.claude/commands/primer.md" ]
}

# ---------------------------------------------------------------------------
# Test 6: --target = MAIN checkout → exits 0 with info, creates nothing
# ---------------------------------------------------------------------------
@test "target is main checkout: exits 0 with info, creates nothing" {
  # Count existing symlinks in MAIN (should be 5 inheritance + 1 non-inheritance)
  main_link_count_before="$(find "$MAIN/.claude" -type l | wc -l | tr -d ' ')"

  run bash "$SCRIPT" --target "$MAIN" --root "$ROOT"
  [ "$status" -eq 0 ]

  # Output indicates nothing to mirror
  [[ "$output" == *"info:"*"main checkout"* ]]
  [[ "$output" == *"nothing to mirror"* ]]

  # Worktree unchanged: same link count in MAIN
  main_link_count_after="$(find "$MAIN/.claude" -type l | wc -l | tr -d ' ')"
  [ "$main_link_count_before" = "$main_link_count_after" ]

  # WT still unseeded (nothing was created there)
  [ ! -e "$WT/.claude/rules/trellis.md" ]
}

# ---------------------------------------------------------------------------
# Test 7: auto-resolution via step 3b (readlink trellis.md → strip suffix)
#         No --root passed; TRELLIS_ROOT and TRELLIS_CONFIG unset.
# ---------------------------------------------------------------------------
@test "auto-resolves TRELLIS_ROOT from main's trellis.md symlink (no --root)" {
  # Unset env fallbacks so only step 3b (readlink strip) can resolve ROOT
  unset TRELLIS_ROOT TRELLIS_CONFIG 2>/dev/null || true

  run bash "$SCRIPT" --target "$WT"
  [ "$status" -eq 0 ]

  # All inheritance symlinks seeded with correct targets
  [ -L "$WT/.claude/rules/trellis.md" ]
  [ "$(readlink "$WT/.claude/rules/trellis.md")" = "$ROOT/core-rules/CLAUDE.md" ]
  [ -L "$WT/.claude/skills/process-gate" ]
  [ "$(readlink "$WT/.claude/skills/process-gate")" = "$ROOT/core-rules/skills/process-gate" ]
}

# ---------------------------------------------------------------------------
# Test 8: nested worktree symlinks (e.g. .claude/worktrees/<x>/.claude/...)
#         in MAIN must NOT be re-mirrored into TARGET. Regression: an
#         unbounded find recursed into nested git worktrees living under the
#         main checkout and recreated their symlinks at bogus nested paths.
# ---------------------------------------------------------------------------
@test "nested worktree symlinks under main are NOT mirrored (maxdepth 2)" {
  # Simulate a nested seeded worktree inside MAIN's .claude/worktrees/
  mkdir -p "$MAIN/.claude/worktrees/nested/.claude/rules"
  mkdir -p "$MAIN/.claude/worktrees/nested/.claude/skills"
  ln -s "$ROOT/core-rules/CLAUDE.md"           "$MAIN/.claude/worktrees/nested/.claude/rules/trellis.md"
  ln -s "$ROOT/core-rules/skills/process-gate" "$MAIN/.claude/worktrees/nested/.claude/skills/process-gate"

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # The real top-level inheritance symlinks ARE seeded
  [ -L "$WT/.claude/rules/trellis.md" ]
  [ -L "$WT/.claude/skills/process-gate" ]

  # The nested-worktree symlinks must NOT appear in TARGET
  [ ! -e "$WT/.claude/worktrees" ]
  [[ "$output" != *".claude/worktrees/nested"* ]]
}

@test "project-owned local infrastructure wrappers are outside the symlink inheritance seeder" {
  mkdir -p "$MAIN/scripts"
  printf '#!/bin/sh\nexit 0\n' > "$MAIN/scripts/local-infra-preflight.sh"
  chmod +x "$MAIN/scripts/local-infra-preflight.sh"

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # This helper mirrors only the machine-local inheritance symlinks. The tracked
  # wrapper is seeded by onboard-project.sh and reaches worktrees through Git.
  [ ! -e "$WT/scripts/local-infra-preflight.sh" ]
  [ -L "$WT/.claude/rules/trellis.md" ]
}

# ---------------------------------------------------------------------------
# OMP surface mirroring. .omp/AGENTS.md targets the project's OWN CLAUDE.md
# (tracked, so the worktree has its own copy) — it must be retargeted to the
# WORKTREE's CLAUDE.md, never the main checkout's. The four whole-directory
# links mirror verbatim and must resolve as directories in the worktree.
# ---------------------------------------------------------------------------
@test "mirrors the .omp live surface into the worktree (directory links + worktree-local AGENTS.md)" {
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # AGENTS.md is retargeted to the worktree's own CLAUDE.md.
  [ -L "$WT/.omp/AGENTS.md" ]
  [ "$(readlink "$WT/.omp/AGENTS.md")" = "$WT/CLAUDE.md" ]
  [ -f "$WT/CLAUDE.md" ]

  # The four whole-directory links mirror verbatim and resolve.
  [ -L "$WT/.omp/skills" ]
  [ "$(readlink "$WT/.omp/skills")" = "$ROOT/core-rules/skills" ]
  [ -d "$WT/.omp/skills" ]
  [ -L "$WT/.omp/commands" ]
  [ "$(readlink "$WT/.omp/commands")" = "$ROOT/core-rules/commands" ]
  [ -d "$WT/.omp/commands" ]
  [ -L "$WT/.omp/agents" ]
  [ "$(readlink "$WT/.omp/agents")" = "$ROOT/core-rules/agents" ]
  [ -d "$WT/.omp/agents" ]
  [ -L "$WT/.omp/hooks" ]
  [ "$(readlink "$WT/.omp/hooks")" = "$ROOT/core-rules/omp/hooks" ]
  [ -d "$WT/.omp/hooks" ]

  # User-owned .omp content (.omp/other → /tmp) is NOT mirrored.
  [ ! -e "$WT/.omp/other" ]
  [ ! -L "$WT/.omp/other" ]

  # Output shows the .omp links being created.
  [[ "$output" == *"linked: .omp/AGENTS.md"* ]]
  [[ "$output" == *"linked: .omp/hooks"* ]]
}

@test "idempotent: .omp links skip on second run" {
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  [[ "$output" == *"skip (correct symlink): .omp/AGENTS.md"* ]]
  [[ "$output" == *"skip (correct symlink): .omp/skills"* ]]
  [[ "$output" != *"linked: .omp/"* ]]
  [ "$(readlink "$WT/.omp/AGENTS.md")" = "$WT/CLAUDE.md" ]
  [ "$(readlink "$WT/.omp/hooks")" = "$ROOT/core-rules/omp/hooks" ]
}

@test "--verify-only covers the .omp surface (AGENTS.md retarget + directory links)" {
  # Unseeded: fails and names an .omp path.
  run bash "$SCRIPT" --target "$WT" --root "$ROOT" --verify-only
  [ "$status" -eq 1 ]
  [[ "$output" == *".omp/AGENTS.md"* ]]

  # After seeding, verify passes for the whole surface.
  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --target "$WT" --root "$ROOT" --verify-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify:"*"correct"* ]]
}

@test "user-owned .omp paths in the worktree are never clobbered" {
  # User-owned regular file where .omp/AGENTS.md belongs.
  mkdir -p "$WT/.omp"
  printf 'user overlay\n' > "$WT/.omp/AGENTS.md"
  # User-owned wrong-target symlink.
  ln -s "/wrong/commands" "$WT/.omp/commands"
  # User-owned real directory.
  mkdir -p "$WT/.omp/skills"
  printf 'user\n' > "$WT/.omp/skills/local.md"

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  [ -f "$WT/.omp/AGENTS.md" ] && [ ! -L "$WT/.omp/AGENTS.md" ]
  [ "$(cat "$WT/.omp/AGENTS.md")" = "user overlay" ]
  [ "$(readlink "$WT/.omp/commands")" = "/wrong/commands" ]
  [ -d "$WT/.omp/skills" ] && [ ! -L "$WT/.omp/skills" ]
  [ "$(cat "$WT/.omp/skills/local.md")" = "user" ]
  [[ "$output" == *"WARN:"* ]]
  [[ "$output" == *"leaving as-is"* ]]
}

@test "nested .omp links under main are NOT mirrored (depth bound)" {
  # A nested worktree living under .omp/ carries its own .omp surface at
  # depth >= 3 from $MAIN/.omp — the maxdepth-2 bound must exclude it.
  mkdir -p "$MAIN/.omp/worktrees/nested/.omp"
  ln -s "$ROOT/core-rules/skills" "$MAIN/.omp/worktrees/nested/.omp/skills"

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 0 ]

  # The depth-1 link IS mirrored...
  [ -L "$WT/.omp/skills" ]
  [ "$(readlink "$WT/.omp/skills")" = "$ROOT/core-rules/skills" ]
  # ...the nested surface is not.
  [ ! -e "$WT/.omp/worktrees" ]
  [[ "$output" != *".omp/worktrees/nested"* ]]
}
