#!/usr/bin/env bats
# Tests for the worktree inheritance safety-net in session-context.sh
# (and the Codex mirror).
#
# FULLY ISOLATED — every test builds its own fixture in a mktemp dir.
# No absolute paths hardcoded; all paths derived from BATS_TEST_DIRNAME.
#
# Fixture layout (mirrors scripts/tests/seed-inheritance-symlinks.bats):
#   $SANDBOX/root/         — fake TRELLIS_ROOT (contains scripts/seed-inheritance-symlinks.sh
#                            and core-rules/ with CLAUDE.md + skills/commands)
#   $SANDBOX/main/         — fake MAIN git checkout with inheritance symlinks
#   $SANDBOX/wt/           — fake linked worktree (via git worktree add)

load helpers

HOOK="$HOOKS_DIR/session-context.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/session-context.sh"

# Path to the real seeder (relative to test runner's repo root)
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
REAL_SEEDER="$REPO_ROOT/scripts/seed-inheritance-symlinks.sh"

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

build_fixture() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"

  ROOT="$SANDBOX/root"
  MAIN="$SANDBOX/main"
  WT="$SANDBOX/wt"

  # ---- Fake TRELLIS_ROOT ----
  mkdir -p \
    "$ROOT/core-rules/skills/process-gate" \
    "$ROOT/core-rules/skills/security-gate" \
    "$ROOT/core-rules/commands" \
    "$ROOT/scripts"
  printf '# Trellis rules\n' > "$ROOT/core-rules/CLAUDE.md"
  printf 'x\n' > "$ROOT/core-rules/skills/process-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/skills/security-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/commands/primer.md"

  # Copy the real seeder into the fake root so the hook can invoke it
  cp "$REAL_SEEDER" "$ROOT/scripts/seed-inheritance-symlinks.sh"
  chmod +x "$ROOT/scripts/seed-inheritance-symlinks.sh"

  # ---- Fake MAIN checkout ----
  mkdir -p "$MAIN"
  (
    cd "$MAIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false

    printf '.claude/rules\n.claude/skills\n.claude/commands\n.agents/rules\n.agents/skills\n' > .gitignore
    printf 'tracked\n' > README.md
    git add README.md .gitignore
    git commit -q -m "init"
  )

  # Create inheritance symlinks in MAIN (the seeder reads these)
  mkdir -p \
    "$MAIN/.claude/rules" \
    "$MAIN/.claude/skills" \
    "$MAIN/.claude/commands"
  ln -s "$ROOT/core-rules/CLAUDE.md"              "$MAIN/.claude/rules/trellis.md"
  ln -s "$ROOT/core-rules/skills/process-gate"    "$MAIN/.claude/skills/process-gate"
  ln -s "$ROOT/core-rules/skills/security-gate"   "$MAIN/.claude/skills/security-gate"
  ln -s "$ROOT/core-rules/commands/primer.md"     "$MAIN/.claude/commands/primer.md"

  # Create the linked worktree
  git -C "$MAIN" worktree add --detach "$WT" >/dev/null 2>&1
}

destroy_fixture() {
  if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ]; then
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

extract_ctx() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // .additionalContext // ""'
}

# ---------------------------------------------------------------------------
# Test 1: WT missing symlinks → warning emitted + symlinks seeded for next session
# ---------------------------------------------------------------------------

@test "worktree missing symlinks: warning emitted in context" {
  build_fixture
  # WT has no inheritance symlinks yet — exactly as git worktree add leaves it.
  [ ! -e "$WT/.claude/rules/trellis.md" ]

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")

  # Output must be valid JSON
  printf '%s' "$out" | jq . >/dev/null

  ctx="$(extract_ctx "$out")"
  [[ "$ctx" == *"TRELLIS INHERITANCE WAS MISSING"* ]]

  destroy_fixture
}

@test "worktree missing symlinks: symlinks seeded on disk for next session" {
  build_fixture

  printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK" >/dev/null

  # Seeder should have created the symlinks
  [ -L "$WT/.claude/rules/trellis.md" ]
  [ -L "$WT/.claude/skills/process-gate" ]
  [ -L "$WT/.claude/skills/security-gate" ]
  [ -L "$WT/.claude/commands/primer.md" ]

  # Targets are correct
  [ "$(readlink "$WT/.claude/rules/trellis.md")" = "$ROOT/core-rules/CLAUDE.md" ]
  [ "$(readlink "$WT/.claude/skills/process-gate")" = "$ROOT/core-rules/skills/process-gate" ]

  destroy_fixture
}

@test "worktree missing symlinks: hook output is valid JSON even with warning" {
  build_fixture

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")

  # Must parse cleanly — no stray seeder output leaked onto stdout
  printf '%s' "$out" | jq . >/dev/null

  destroy_fixture
}

# ---------------------------------------------------------------------------
# Test 2: WT already seeded → no warning, existing context intact
# ---------------------------------------------------------------------------

@test "worktree already seeded: no warning emitted" {
  build_fixture

  # Pre-seed the worktree
  bash "$ROOT/scripts/seed-inheritance-symlinks.sh" --target "$WT" --root "$ROOT" --quiet >/dev/null 2>&1

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")
  ctx="$(extract_ctx "$out")"

  [[ "$ctx" != *"TRELLIS INHERITANCE WAS MISSING"* ]]

  destroy_fixture
}

@test "worktree already seeded: existing context (branch/commits) still present" {
  build_fixture
  bash "$ROOT/scripts/seed-inheritance-symlinks.sh" --target "$WT" --root "$ROOT" --quiet >/dev/null 2>&1

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")
  ctx="$(extract_ctx "$out")"

  # Branch section should still be present since we're in a git repo
  [[ "$ctx" == *"Branch:"* ]]

  destroy_fixture
}

# ---------------------------------------------------------------------------
# Test 3: Main checkout (non-worktree) → no warning, behaves exactly as before
# ---------------------------------------------------------------------------

@test "main checkout: no warning emitted" {
  build_fixture

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$MAIN" bash "$HOOK")
  ctx="$(extract_ctx "$out")"

  [[ "$ctx" != *"TRELLIS INHERITANCE WAS MISSING"* ]]

  destroy_fixture
}

@test "main checkout: existing context (branch/commits) intact" {
  build_fixture

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$MAIN" bash "$HOOK")
  ctx="$(extract_ctx "$out")"

  [[ "$ctx" == *"Branch:"* ]]

  destroy_fixture
}

# ---------------------------------------------------------------------------
# Test 4: Codex mirror — same behavior
# ---------------------------------------------------------------------------

@test "codex: worktree missing symlinks → warning in context" {
  build_fixture
  [ ! -e "$WT/.claude/rules/trellis.md" ]

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$WT" bash "$CODEX_HOOK")

  printf '%s' "$out" | jq . >/dev/null

  ctx="$(extract_ctx "$out")"
  [[ "$ctx" == *"TRELLIS INHERITANCE WAS MISSING"* ]]

  destroy_fixture
}

@test "codex: main checkout → no warning" {
  build_fixture

  out=$(printf '%s' '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$MAIN" bash "$CODEX_HOOK")
  ctx="$(extract_ctx "$out")"

  [[ "$ctx" != *"TRELLIS INHERITANCE WAS MISSING"* ]]

  destroy_fixture
}

# ---------------------------------------------------------------------------
# L3 regression: both twins allocate the warning capture with mktemp and clean
# it up. The audited `/tmp/_trellis_wt_warn_$$` implementation never called the
# stub, so this test fails against that predictable-temp version.
# ---------------------------------------------------------------------------

@test "L3: both harnesses use mktemp for worktree warning capture and clean it up" {
  build_fixture
  local bindir="$SANDBOX/bin"
  local tmpdir="$SANDBOX/tmp"
  local mktemp_log="$SANDBOX/mktemp.log"
  local generated="$tmpdir/generated-wtwarn"
  local candidate
  mkdir -p "$bindir" "$tmpdir"
  cat > "$bindir/mktemp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$MKTEMP_LOG"
(umask 077; : > "$MKTEMP_RESULT") || exit 1
printf '%s\n' "$MKTEMP_RESULT"
EOF
  chmod +x "$bindir/mktemp"

  for candidate in "$HOOK" "$CODEX_HOOK"; do
    : > "$mktemp_log"
    rm -f "$generated"
    run env \
      CLAUDE_PROJECT_DIR="$MAIN" \
      TMPDIR="$tmpdir" \
      MKTEMP_LOG="$mktemp_log" \
      MKTEMP_RESULT="$generated" \
      PATH="$bindir:$PATH" \
      bash "$candidate" <<<'{"source":"startup"}'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq . >/dev/null
    [ "$(cat "$mktemp_log")" = "$tmpdir/trellis-wtwarn.XXXXXX" ]
    [ ! -e "$generated" ]
  done

  destroy_fixture
}

# ---------------------------------------------------------------------------
# Test 5: compact source → skipped entirely (no regressions)
# ---------------------------------------------------------------------------

@test "compact source: hook exits 0 and emits nothing (worktree)" {
  build_fixture

  out=$(printf '%s' '{"source":"compact"}' | CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")
  [ -z "$out" ]

  destroy_fixture
}
