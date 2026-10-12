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

  export TRELLIS_HOME="$SANDBOX/inert trellis home"
  export TRELLIS_WORKTREE_ROOT="$SANDBOX/work trees"
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
@test "'add <branch>' leaves an unregistered clone inert" {
  WT2="$TRELLIS_WORKTREE_ROOT/_unregistered/main/wt2"

  cd "$MAIN"
  run bash "$SCRIPT" add wt2

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

# Observe wrapper invocations separately from the managed post-checkout hook.
# Both still use the real seeder and sealed payload; no hook is disabled.
# Point T14_WORKTREE at fixture-project's convention path for BRANCH, under a
# root whose name holds a space.
t14_use_convention_path() {
  export TRELLIS_WORKTREE_ROOT="$T14_SANDBOX/work trees"
  T14_WORKTREE="$TRELLIS_WORKTREE_ROOT/fixture-project/$1"
}

wrapper_counted_copy() {
  COUNTED_WRAPPER_DIR="$T14_SANDBOX/counted wrapper"
  export WRAPPER_SEED_LOG="$T14_SANDBOX/wrapper.seeds"
  export WRAPPER_REAL_SEED="$REPO_ROOT/scripts/seed-inheritance-symlinks.sh"
  : > "$WRAPPER_SEED_LOG"
  mkdir -p "$COUNTED_WRAPPER_DIR"
  cp "$SCRIPT" "$COUNTED_WRAPPER_DIR/worktree.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$COUNTED_WRAPPER_DIR/lib"
  cat > "$COUNTED_WRAPPER_DIR/seed-inheritance-symlinks.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WRAPPER_SEED_LOG"
bash "$WRAPPER_REAL_SEED" "$@" || exit "$?"
# Inject a fault after the read-only pre-add check to exercise Git's actual
# post-checkout refusal, not just the wrapper's predictable pre-add refusal.
if [ -n "${WRAPPER_TAMPER_RELEASE:-}" ]; then
  chmod u+w "$WRAPPER_TAMPER_RELEASE"
  printf '\n# post-preflight corruption\n' >> "$WRAPPER_TAMPER_RELEASE"
  chmod 500 "$WRAPPER_TAMPER_RELEASE"
fi
if [ -n "${WRAPPER_DRIFT_HOOKS_ROOT:-}" ]; then
  git -C "$WRAPPER_DRIFT_HOOKS_ROOT" config --local core.hooksPath "$WRAPPER_DRIFT_HOOKS_ROOT/.husky/_"
fi
SH
  chmod 755 "$COUNTED_WRAPPER_DIR/seed-inheritance-symlinks.sh"
}

@test "wrapper add seeds only in post-checkout after one read-only pre-add call" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  wrapper_counted_copy
  t14_use_convention_path t14-counted-wrapper

  run bash -c 'cd "$1" && bash "$2" add t14-counted-wrapper' _ \
    "$T14_PROJECT" "$COUNTED_WRAPPER_DIR/worktree.sh"

  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$WRAPPER_SEED_LOG" | tr -d ' ')" -eq 1 ]
  grep -- '--pre-add --quiet' "$WRAPPER_SEED_LOG"
  [ -f "$(t14_owner_for_root "$T14_WORKTREE")" ]
  [ -L "$T14_WORKTREE/.trellis/runtime" ]
  [ -L "$T14_WORKTREE/.claude/rules/trellis.md" ]
}

@test "wrapper add refuses readiness when hooksPath drifts after pre-add" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  wrapper_counted_copy
  t14_use_convention_path t14-hook-drift
  export WRAPPER_DRIFT_HOOKS_ROOT="$T14_PROJECT"

  run bash -c 'cd "$1" && bash "$2" add t14-hook-drift' _ \
    "$T14_PROJECT" "$COUNTED_WRAPPER_DIR/worktree.sh"

  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$WRAPPER_SEED_LOG" | tr -d ' ')" -eq 2 ]
  [ ! -e "$T14_WORKTREE/.trellis/runtime" ]
  [ -z "$(t14_owner_for_root "$T14_WORKTREE" 2>/dev/null || true)" ]
  [[ "$output" != *"worktree ready:"* ]]
}

@test "wrapper pre-add release refusal still creates no branch or worktree" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  wrapper_counted_copy
  t14_use_convention_path t14-refused-wrapper
  payload_attach="$TRELLIS_HOME/releases/1.2.3/payload/scripts/attach-project.sh"
  chmod u+w "$payload_attach"
  printf '\n# corruption\n' >> "$payload_attach"
  chmod 500 "$payload_attach"

  run bash -c 'cd "$1" && bash "$2" add t14-refused-wrapper' _ \
    "$T14_PROJECT" "$COUNTED_WRAPPER_DIR/worktree.sh"

  [ "$status" -eq 4 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$WRAPPER_SEED_LOG" | tr -d ' ')" -eq 1 ]
  [ ! -e "$T14_WORKTREE" ]
  ! git -C "$T14_PROJECT" show-ref --verify --quiet refs/heads/t14-refused-wrapper
}

@test "wrapper propagates the managed post-checkout release refusal without reseeding" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  wrapper_counted_copy
  t14_use_convention_path t14-hook-refused-wrapper
  export WRAPPER_TAMPER_RELEASE="$TRELLIS_HOME/releases/1.2.3/payload/scripts/attach-project.sh"

  run bash -c 'cd "$1" && bash "$2" add t14-hook-refused-wrapper' _ \
    "$T14_PROJECT" "$COUNTED_WRAPPER_DIR/worktree.sh"

  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$WRAPPER_SEED_LOG" | tr -d ' ')" -eq 1 ]
  [[ "$output" != *"worktree ready:"* ]]
  [ ! -e "$T14_WORKTREE/.trellis/runtime" ]
  [ -z "$(t14_owner_for_root "$T14_WORKTREE" 2>/dev/null || true)" ]
}

@test "opted-in worktree add attaches from immutable release with registered project identity" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  t14_use_convention_path t14-linked

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && "$2" add t14-linked' \
    worktree-wrapper "$T14_PROJECT" "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -L "$T14_WORKTREE/.trellis/runtime" ]
  [ -L "$T14_WORKTREE/.claude/rules/trellis.md" ]
  owner="$(t14_owner_for_root "$T14_WORKTREE")"
  [ -f "$owner" ]
  jq -e '.status == "committed" and .project_id == "fixture-project" and .fleet == "personal" and .release == "1.2.3"' "$owner"
  # Spec 067 creation record survives the new grammar.
  [ "$(git -C "$T14_PROJECT" config --get branch.t14-linked.trellisBase)" = "$(git -C "$T14_PROJECT" rev-parse HEAD)" ]
  [ -n "$(git -C "$T14_PROJECT" config --get branch.t14-linked.trellisParent)" ]
  [ -n "$(git -C "$T14_PROJECT" config --get branch.t14-linked.trellisSource)" ]
  [ -z "$(git -C "$T14_PROJECT" status --porcelain)" ]
  [ -z "$(git -C "$T14_WORKTREE" status --porcelain)" ]
}

@test "opted-in --no-checkout add defers attachment until a real checkout" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  t14_use_convention_path t14-deferred

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && "$2" add --no-checkout t14-deferred' \
    worktree-wrapper "$T14_PROJECT" "$SCRIPT"

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
  t14_use_convention_path t14-idempotent

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    'cd "$1" && "$2" add t14-idempotent' \
    worktree-wrapper "$T14_PROJECT" "$SCRIPT"
  [ "$status" -eq 0 ]
  owner="$(t14_owner_for_root "$T14_WORKTREE")"
  before="$(t14_sha256_text "$(cat "$owner")")"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" sync "$T14_WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(t14_sha256_text "$(cat "$owner")")" = "$before" ]
  [ -L "$T14_WORKTREE/.trellis/runtime" ]
  [ -L "$T14_WORKTREE/.claude/rules/trellis.md" ]
}
