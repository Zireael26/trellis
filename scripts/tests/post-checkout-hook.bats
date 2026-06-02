#!/usr/bin/env bats
# Tests for core-rules/githooks/post-checkout hook (worktree inheritance).
#
# FULLY ISOLATED — every test builds its own fixture in a mktemp dir.
# No absolute paths are hardcoded; all paths derived from $BATS_TEST_DIRNAME.
#
# Fixture layout:
#   $SANDBOX/root/        — fake TRELLIS_ROOT (with real seeder + core-rules/)
#   $SANDBOX/main/        — fake MAIN git repo (.githooks/post-checkout = hook)
#   $SANDBOX/wt/          — linked worktree created via git worktree add

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
HOOK="$REPO_ROOT/core-rules/githooks/post-checkout"
SEEDER="$REPO_ROOT/scripts/seed-inheritance-symlinks.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve real path so /var vs /private/var cannot diverge
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"

  ROOT="$SANDBOX/root"
  MAIN="$SANDBOX/main"
  WT="$SANDBOX/wt"

  # ---- Build fake TRELLIS_ROOT ----
  mkdir -p \
    "$ROOT/core-rules/skills/process-gate" \
    "$ROOT/scripts"
  printf '# Trellis rules\n' > "$ROOT/core-rules/CLAUDE.md"
  printf 'x\n' > "$ROOT/core-rules/skills/process-gate/SKILL.md"

  # Copy the REAL seeder into $ROOT/scripts/ so the hook can call it
  cp "$SEEDER" "$ROOT/scripts/seed-inheritance-symlinks.sh"
  chmod +x "$ROOT/scripts/seed-inheritance-symlinks.sh"

  # ---- Build fake MAIN checkout ----
  mkdir -p "$MAIN"
  (
    cd "$MAIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    git config core.hooksPath ".githooks"

    # .gitignore — ignore the inheritance symlink directories
    printf '.claude/rules\n.claude/skills\n.agents/rules\n.agents/skills\n' > .gitignore

    # Tracked file so git worktree add works
    printf 'tracked\n' > README.md

    # Set up the .githooks dir (tracked) with the canonical hook
    mkdir -p .githooks
    cp "$HOOK" .githooks/post-checkout
    chmod +x .githooks/post-checkout

    git add README.md .gitignore .githooks/post-checkout
    git commit -q -m "init"
  )

  # Create inheritance symlinks in MAIN (gitignored, not committed)
  mkdir -p \
    "$MAIN/.claude/rules" \
    "$MAIN/.claude/skills"
  ln -s "$ROOT/core-rules/CLAUDE.md"           "$MAIN/.claude/rules/trellis.md"
  ln -s "$ROOT/core-rules/skills/process-gate" "$MAIN/.claude/skills/process-gate"
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
# Test 1: git worktree add auto-creates inheritance symlinks via hook
# ---------------------------------------------------------------------------
@test "git worktree add triggers hook and seeds inheritance symlinks" {
  # Use -b to create a branch checkout so git passes $3=1 to the hook
  git -C "$MAIN" worktree add -b wt-branch "$WT" >/dev/null 2>&1

  # The hook should have fired and called the seeder, creating the symlinks
  [ -L "$WT/.claude/rules/trellis.md" ]
  [ -L "$WT/.claude/skills/process-gate" ]

  # Targets must match MAIN's inheritance symlinks (pointing into $ROOT)
  [ "$(readlink "$WT/.claude/rules/trellis.md")"      = "$ROOT/core-rules/CLAUDE.md" ]
  [ "$(readlink "$WT/.claude/skills/process-gate")"   = "$ROOT/core-rules/skills/process-gate" ]
}

# ---------------------------------------------------------------------------
# Test 2: $3 != 1 is a no-op (e.g. file checkout, not branch checkout)
# ---------------------------------------------------------------------------
@test "hook with flag=0 is a no-op and exits 0" {
  # Create the worktree but then run the hook manually with flag=0
  git -C "$MAIN" worktree add -b wt-branch2 "$WT" >/dev/null 2>&1

  # Remove any symlinks that the auto-firing may have created
  rm -rf "$WT/.claude"

  # Run the hook body directly with flag=0 from within the worktree
  run bash "$HOOK" "prev-sha" "new-sha" "0"
  [ "$status" -eq 0 ]

  # No symlinks should have been created (hook must have exited early)
  [ ! -e "$WT/.claude/rules/trellis.md" ]
  [ ! -e "$WT/.claude/skills/process-gate" ]
}

# ---------------------------------------------------------------------------
# Test 3: running hook in the MAIN checkout (common==gitdir) is a no-op
# ---------------------------------------------------------------------------
@test "hook in main checkout (not a linked worktree) is a no-op and exits 0" {
  # Run from MAIN (not from a linked worktree) — common == gitdir → skip
  run bash -c "cd '$MAIN' && bash '$HOOK' 'prev-sha' 'new-sha' '1'"
  [ "$status" -eq 0 ]

  # MAIN had its own symlinks already; we only check nothing BROKE
  # (The hook must not abort; in MAIN, common==gitdir so it exits immediately)
  [ -L "$MAIN/.claude/rules/trellis.md" ]
  [ -L "$MAIN/.claude/skills/process-gate" ]
}
