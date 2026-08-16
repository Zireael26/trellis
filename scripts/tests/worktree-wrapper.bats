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
load helpers/t14-worktree

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
  t14_teardown_sandbox
}

# ---------------------------------------------------------------------------
# An ordinary clone may carry no Trellis state. The wrapper must still be a
# harmless worktree convenience rather than revive legacy direct-link state.
# ---------------------------------------------------------------------------
@test "'add <path>' leaves an unregistered clone inert" {
  WT2="$SANDBOX/wt2"

  cd "$MAIN"
  run bash "$SCRIPT" add "$WT2"

  [ "$status" -eq 0 ]
  [ -d "$WT2" ]
  [ ! -e "$WT2/.trellis/runtime" ]
  [ ! -e "$WT2/.claude/rules/trellis.md" ]
  [[ "$output" == *"worktree ready:"* ]] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# sync is likewise an inert no-op for an unregistered worktree.
# ---------------------------------------------------------------------------
@test "'sync <path>' leaves an unregistered worktree inert" {
  WT2="$SANDBOX/wt2"

  git -C "$MAIN" worktree add --detach "$WT2" >/dev/null 2>&1
  run bash "$SCRIPT" sync "$WT2"

  [ "$status" -eq 0 ]
  [ ! -e "$WT2/.trellis/runtime" ]
  [ ! -e "$WT2/.claude/rules/trellis.md" ]
}

# ---------------------------------------------------------------------------
# sync without a path diagnoses/reconciles only the active worktree.
# ---------------------------------------------------------------------------
@test "'sync' with no arg leaves an unregistered \$PWD inert" {
  WT2="$SANDBOX/wt2"

  git -C "$MAIN" worktree add --detach "$WT2" >/dev/null 2>&1
  cd "$WT2"
  run bash "$SCRIPT" sync

  [ "$status" -eq 0 ]
  [ ! -e "$WT2/.trellis/runtime" ]
  [ ! -e "$WT2/.claude/rules/trellis.md" ]
}

# ---------------------------------------------------------------------------
# Test 4: unknown subcommand → exit 2
# ---------------------------------------------------------------------------
@test "unknown subcommand exits 2" {
  run bash "$SCRIPT" frobulate
  [ "$status" -eq 2 ]
  [[ "$output" == *"error: unknown subcommand"* ]] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# Test 5: --help → exit 0, usage to stdout
# ---------------------------------------------------------------------------
@test "--help exits 0 and prints usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktree.sh"* ]] || { echo "$output"; false; }
  [[ "$output" == *"add"* ]] || { echo "$output"; false; }
  [[ "$output" == *"sync"* ]] || { echo "$output"; false; }
}

@test "opted-in worktree add attaches from immutable release with registered project identity" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  T14_WORKTREE="$T14_SANDBOX/linked worktree"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && "$2" add -b t14-linked "$3"' \
    worktree-wrapper "$T14_PROJECT" "$SCRIPT" "$T14_WORKTREE"

  [ "$status" -eq 0 ]
  [ -L "$T14_WORKTREE/.trellis/runtime" ]
  [ -L "$T14_WORKTREE/.claude/rules/trellis.md" ]
  owner="$(t14_owner_for_root "$T14_WORKTREE")"
  [ -f "$owner" ]
  jq -e '.status == "committed" and .project_id == "fixture-project" and .fleet == "personal" and .release == "1.2.3"' "$owner"
  [ -z "$(git -C "$T14_PROJECT" status --porcelain)" ]
  [ -z "$(git -C "$T14_WORKTREE" status --porcelain)" ]
}

@test "opted-in --no-checkout add defers attachment until a real checkout" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  T14_WORKTREE="$T14_SANDBOX/deferred worktree"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && "$2" add --no-checkout -b t14-deferred "$3"' \
    worktree-wrapper "$T14_PROJECT" "$SCRIPT" "$T14_WORKTREE"

  [ "$status" -eq 0 ]
  [ -d "$T14_WORKTREE" ]
  [ ! -e "$T14_WORKTREE/.trellis/runtime" ]
  [ ! -L "$T14_WORKTREE/.trellis/runtime" ]
  [[ "$output" == *"will reconcile on first checkout"* ]] || { echo "$output"; false; }
  [ -z "$(t14_owner_for_root "$T14_WORKTREE" 2>/dev/null || true)" ]
}

@test "ordinary opted-in add is immediately attached and sync is idempotent" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  T14_WORKTREE="$T14_SANDBOX/idempotent linked worktree"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && "$2" add -b t14-idempotent "$3"' \
    worktree-wrapper "$T14_PROJECT" "$SCRIPT" "$T14_WORKTREE"
  [ "$status" -eq 0 ]
  owner="$(t14_owner_for_root "$T14_WORKTREE")"
  before="$(t14_sha256_text "$(cat "$owner")")"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" sync "$T14_WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(t14_sha256_text "$(cat "$owner")")" = "$before" ]
  [ -L "$T14_WORKTREE/.trellis/runtime" ]
  [ -L "$T14_WORKTREE/.claude/rules/trellis.md" ]
}
