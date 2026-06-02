#!/usr/bin/env bats
# Tests for scripts/worktree.sh — the Trellis worktree wrapper.
#
# FULLY ISOLATED — every test builds its own fixture in a mktemp dir.
# No absolute paths are hardcoded; all paths derived from $BATS_TEST_DIRNAME.
#
# Fixture layout:
#   $SANDBOX/root/         — fake TRELLIS_ROOT with core-rules/
#   $SANDBOX/main/         — fake MAIN git checkout with inheritance symlinks
#
# Each test that needs a second worktree creates it inside the fixture.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through real path so /var vs /private/var cannot diverge
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"

  ROOT="$SANDBOX/root"
  MAIN="$SANDBOX/main"

  # ---- Build fake TRELLIS_ROOT ----
  mkdir -p \
    "$ROOT/core-rules/skills/process-gate" \
    "$ROOT/core-rules/skills/security-gate" \
    "$ROOT/core-rules/commands"
  printf '# Trellis rules\n' > "$ROOT/core-rules/CLAUDE.md"
  printf 'x\n' > "$ROOT/core-rules/skills/process-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/skills/security-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/commands/primer.md"

  # ---- Build fake MAIN checkout ----
  mkdir -p "$MAIN"
  (
    cd "$MAIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false

    # .gitignore — ignore the inheritance symlink directories
    printf '.claude/rules\n.claude/skills\n.claude/commands\n' > .gitignore

    # Create a tracked file so git worktree add works
    printf 'tracked\n' > README.md
    git add README.md .gitignore
    git commit -q -m "init"
  )

  # Create inheritance symlinks in MAIN (mirrors seeder bats fixture)
  mkdir -p \
    "$MAIN/.claude/rules" \
    "$MAIN/.claude/skills" \
    "$MAIN/.claude/commands"
  ln -s "$ROOT/core-rules/CLAUDE.md"              "$MAIN/.claude/rules/trellis.md"
  ln -s "$ROOT/core-rules/skills/process-gate"    "$MAIN/.claude/skills/process-gate"
  ln -s "$ROOT/core-rules/skills/security-gate"   "$MAIN/.claude/skills/security-gate"
  ln -s "$ROOT/core-rules/commands/primer.md"     "$MAIN/.claude/commands/primer.md"
}

teardown() {
  if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ]; then
    # Remove any linked worktrees so git does not complain about locked refs
    git -C "$MAIN" worktree list --porcelain 2>/dev/null \
      | grep '^worktree ' \
      | tail -n +2 \
      | awk '{print $2}' \
      | while read -r wt; do
          git -C "$MAIN" worktree remove --force "$wt" 2>/dev/null || true
        done
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: worktree add creates the worktree AND seeds inheritance symlinks
# ---------------------------------------------------------------------------
@test "'add <path>' creates the worktree and seeds inheritance symlinks" {
  WT2="$SANDBOX/wt2"

  # Must run from MAIN so git worktree add can find the repository
  cd "$MAIN"
  run bash "$SCRIPT" add "$WT2"

  [ "$status" -eq 0 ]

  # The worktree directory must exist
  [ -d "$WT2" ]

  # Inheritance symlinks seeded
  [ -L "$WT2/.claude/rules/trellis.md" ]
  [ -L "$WT2/.claude/skills/process-gate" ]
  [ -L "$WT2/.claude/skills/security-gate" ]
  [ -L "$WT2/.claude/commands/primer.md" ]

  # Targets correct
  [ "$(readlink "$WT2/.claude/rules/trellis.md")"        = "$ROOT/core-rules/CLAUDE.md" ]
  [ "$(readlink "$WT2/.claude/skills/process-gate")"     = "$ROOT/core-rules/skills/process-gate" ]

  # Success line present
  [[ "$output" == *"worktree ready (inheritance seeded):"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: worktree sync <path> seeds an existing unseeded worktree
# ---------------------------------------------------------------------------
@test "'sync <path>' seeds an existing unseeded worktree" {
  WT2="$SANDBOX/wt2"

  # Create the real git worktree (unseeded — no inheritance symlinks)
  git -C "$MAIN" worktree add --detach "$WT2" >/dev/null 2>&1

  # Confirm it is unseeded
  [ ! -L "$WT2/.claude/skills/process-gate" ]

  run bash "$SCRIPT" sync "$WT2"
  [ "$status" -eq 0 ]

  # Inheritance symlinks now present
  [ -L "$WT2/.claude/rules/trellis.md" ]
  [ -L "$WT2/.claude/skills/process-gate" ]
  [ -L "$WT2/.claude/skills/security-gate" ]
  [ -L "$WT2/.claude/commands/primer.md" ]
}

# ---------------------------------------------------------------------------
# Test 3: worktree sync (no arg) seeds $PWD when cwd is an unseeded worktree
# ---------------------------------------------------------------------------
@test "'sync' with no arg seeds \$PWD" {
  WT2="$SANDBOX/wt2"

  # Create unseeded worktree
  git -C "$MAIN" worktree add --detach "$WT2" >/dev/null 2>&1

  # cd into the worktree before running sync with no argument
  cd "$WT2"
  run bash "$SCRIPT" sync
  [ "$status" -eq 0 ]

  # Symlinks seeded
  [ -L "$WT2/.claude/rules/trellis.md" ]
  [ -L "$WT2/.claude/skills/process-gate" ]
}

# ---------------------------------------------------------------------------
# Test 4: unknown subcommand → exit 2
# ---------------------------------------------------------------------------
@test "unknown subcommand exits 2" {
  run bash "$SCRIPT" frobulate
  [ "$status" -eq 2 ]
  [[ "$output" == *"error: unknown subcommand"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: --help → exit 0, usage to stdout
# ---------------------------------------------------------------------------
@test "--help exits 0 and prints usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktree.sh"* ]]
  [[ "$output" == *"add"* ]]
  [[ "$output" == *"sync"* ]]
}
