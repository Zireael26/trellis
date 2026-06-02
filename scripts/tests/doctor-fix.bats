#!/usr/bin/env bats
# Tests for scripts/doctor.sh --fix / --fix-hooks / --dry-run (P2 repair path).
#
# FULLY ISOLATED from the live registry and the 7 real managed projects, in the
# same shape as doctor.bats: every test stands up its own fixture in a fresh
# `mktemp` dir and exports $TRELLIS_CONFIG so config-load.sh (and the engines
# doctor delegates to) resolve the FIXTURE config, never the worktree's real one.
#
#   <sandbox>/canonical            — a real git repo (the fixture canonical clone)
#   <sandbox>/projects             — the fixture PROJECTS_ROOT
#   <sandbox>/projects/<name>      — a real git repo (onboard needs $PROJECT/.git)
#   <sandbox>/trellis.config.json  — trellis_root/projects_root point at the above
#
# Why real --fix is safe here (and is genuinely exercised, not faked):
#   onboard-project.sh reads canonical rules/skills/commands + the primer-index
#   template from $TRELLIS_ROOT (the fixture canonical), and the target PROJECT
#   from $PROJECTS_ROOT/<name> (the fixture projects root). Both come from the
#   fixture config, so onboard mutates ONLY inside the sandbox. (onboard also
#   copies hook scripts + the settings template from its own SOURCE_ROOT = the
#   real worktree's core-rules/; those are COPIED INTO the fixture project and
#   never written back to the worktree — still fully contained in the sandbox.)
#   This was verified empirically before these tests were written.
#
# Engine quirks pinned down (so the assertions are correct, not lucky):
#   - onboard exits NON-ZERO even on a fully successful seed for a claude-only
#     project (its last statement is a `{ codex || antigravity; } && echo` short
#     circuit). doctor.sh treats the AFTER-pass re-check as authoritative, not
#     onboard's exit — so a repaired symlink + exit 0 from doctor is the proof.
#   - onboard NEVER-CLOBBERS: it skips files that already exist. So it will NOT
#     update a STALE hook copy and will NOT repair a WRONG-TARGET symlink. The
#     stale-symlink repair therefore relies on doctor `rm`ing the bad link FIRST,
#     then onboard re-seeding it. The stale-HOOK repair relies on --fix-hooks
#     (sync-hooks.sh), which plain --fix must NOT trigger.
#   - hc_hook_freshness compares project hooks against the FIXTURE canonical's
#     core-rules/hooks, but sync-hooks.sh copies from the REAL worktree's
#     core-rules/hooks. So the gate fixture seeds the fixture canonical's hooks
#     by COPYING the real worktree hooks — making "drifted-from" and "synced-to"
#     the same bytes, so convergence is observable.
#
# bash 3.2 / bats 1.x. $CANON is captured once via `cd && pwd -P` so /var vs
# /private/var cannot diverge between the symlink targets we write and the
# config's trellis_root (hc_rules_symlink string-compares readlink output).

# Resolve paths relative to this test file so the suite is portable (no
# machine-specific absolute paths — those would also leak into the public
# mirror). $BATS_TEST_DIRNAME is scripts/tests/, so ../.. is the repo root.
REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
WORKTREE_HOOKS="$REPO_ROOT/core-rules/hooks"
# The repo's configured canonical clone — what doctor must NOT print when run
# against a fixture (proves the $TRELLIS_CONFIG override took effect).
LIVE_CANON="$(jq -r '.trellis_root' "$REPO_ROOT/trellis.config.json" 2>/dev/null || true)"

CANON_SKILLS="process-gate security-gate clarify spec plan tasks analyze"
CANON_COMMANDS="primer primer-refresh primer-check explore autonomy"

setup() {
  SANDBOX="$(mktemp -d)"
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

# Lay down the canonical inheritance surface. Unlike doctor.bats's builder, this
# ALSO seeds core-rules/commands/templates/primer-index-template.md, which
# onboard-project.sh REQUIRES (it exits 1 before seeding anything if absent).
# Does NOT git init — that is git_init_canonical_main's job, run AFTER any
# per-test canonical augmentation so the committed tree stays clean (a dirty
# canonical trips Tier-0 ERROR, which gates ALL [auto] repair off).
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands/templates"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  local s c
  for s in $CANON_SKILLS; do
    mkdir -p "$CANON/core-rules/skills/$s"
    printf 'x\n' > "$CANON/core-rules/skills/$s/SKILL.md"
  done
  for c in $CANON_COMMANDS; do
    printf 'x\n' > "$CANON/core-rules/commands/$c.md"
  done
  printf '# primer index template\n' \
    > "$CANON/core-rules/commands/templates/primer-index-template.md"
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

# Seed the fixture canonical's core-rules/hooks by COPYING the REAL worktree's
# canonical hooks. This makes hc_hook_freshness's comparison target (fixture
# canonical) byte-identical to sync-hooks.sh's source (worktree), so a hook
# the project drifted from can be observed converging back. Call BEFORE
# git_init_canonical_main. Only the gate test needs hooks in the canonical;
# every other test deliberately omits them so onboard's hook seed does not add
# a spurious "hooks installed" surface to assert around.
add_canonical_hooks() {
  cp -R "$WORKTREE_HOOKS" "$CANON/core-rules/hooks"
}

# git init the canonical on `main` and commit so the tree is clean. Run AFTER
# all canonical augmentation (templates, hooks) so nothing is left uncommitted.
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

# Build a fully healthy "healthy" project: real git repo (onboard requires
# $PROJECT/.git), good rules symlink, canonical @-import, full skills + commands
# sets, and a .claude/settings.json. The git init is what lets onboard run when
# a later mutation breaks part of the surface.
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
  (
    cd "$hp"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
  )
}

# Seed the project's .claude/hooks/ from the FIXTURE canonical hooks (which were
# themselves copied from the worktree by add_canonical_hooks). After this the
# project is hook-in-sync; callers then deliberately drift one hook.
seed_project_hooks_from_canonical() {
  local hp="$PROJECTS/healthy"
  mkdir -p "$hp/.claude/hooks"
  cp "$CANON/core-rules/hooks"/*.sh "$hp/.claude/hooks/"
  if [ -d "$CANON/core-rules/hooks/lib" ]; then
    mkdir -p "$hp/.claude/hooks/lib"
    cp "$CANON/core-rules/hooks/lib"/*.sh "$hp/.claude/hooks/lib/" 2>/dev/null || true
  fi
}

run_doctor() {
  run bash "$DOCTOR" "$@"
}

# Symlink-aware snapshot of the project subtree: emits one line per path —
#   L <path> -> <readlink>   for symlinks (catches retargets a hash cannot)
#   F <path> <sha256>        for regular files
#   D <path>                 for directories
# This is the read-only oracle: a dry-run must leave it byte-for-byte identical,
# including symlink targets. (BSD-safe: no GNU stat, no readlink -f.)
snapshot_project() {
  local proj="$1" f
  find "$proj" -print0 | sort -z | while IFS= read -r -d '' f; do
    if [ -L "$f" ]; then
      printf 'L %s -> %s\n' "$f" "$(readlink "$f")"
    elif [ -f "$f" ]; then
      printf 'F %s %s\n' "$f" "$(shasum -a 256 "$f" | awk '{print $1}')"
    elif [ -d "$f" ]; then
      printf 'D %s\n' "$f"
    fi
  done
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# ===========================================================================
# Flag-relationship guards (no fixture mutation; pure arg handling).
# ===========================================================================

@test "--dry-run without --fix is rejected (exit 2)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"--dry-run is only valid with --fix"* ]]
}

# ===========================================================================
# 1. --fix --dry-run is READ-ONLY: prints the plan, mutates nothing.
#    Fixture has a STALE (wrong-target) rules symlink — the kind of drift that
#    needs the rm+onboard path — so the plan has real [auto] content to print
#    while the tree must remain byte/link-identical.  (dryrun_is_readonly_verified)
# ===========================================================================

@test "--fix --dry-run on a drifted fixture: prints the planned commands AND leaves the fixture byte/link-identical" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Stale/wrong-target rules symlink (incident #1 shape).
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"

  local before after
  before="$(snapshot_project "$PROJECTS/healthy")"

  run_doctor --fix --dry-run
  [ "$status" -eq 0 ]
  # The plan is printed: the rm of the known-bad link AND the onboard re-seed.
  [[ "$output" == *"[auto] rm "*".claude/rules/trellis.md"* ]]
  [[ "$output" == *"onboard-project.sh"* ]]
  [[ "$output" == *"nothing applied"* ]]

  after="$(snapshot_project "$PROJECTS/healthy")"
  # READ-ONLY oracle: byte-for-byte + symlink-target identical before vs after.
  [ "$before" = "$after" ]
  # The bad symlink in particular was NOT touched.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
}

# ===========================================================================
# 2. --fix repairs a MISSING rules symlink: afterward it resolves to canonical
#    and the re-check is ✓ + exit 0.  (fix_repairs_verified)
# ===========================================================================

@test "--fix on a MISSING rules symlink: onboard re-seeds it; afterward it resolves to canonical and exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]

  run_doctor --fix
  [ "$status" -eq 0 ]
  # The link now exists, points at the fixture canonical, and resolves.
  [ -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "$CANON/core-rules/CLAUDE.md" ]
  [ -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  # The AFTER-pass re-check shows the row green (proves doctor re-verified, not
  # just that onboard exited).
  [[ "$output" == *"re-checking healthy after fixes"* ]]
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
}

# ===========================================================================
# 3. --fix repairs a STALE/broken symlink via the rm+onboard path: onboard alone
#    never-clobbers, so doctor must rm the bad link first, then re-seed.
# ===========================================================================

@test "--fix on a STALE/wrong-target rules symlink: rm+onboard repairs it; afterward it resolves to canonical and exit 0" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"
  # Pre-condition: the bad link does NOT resolve.
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]

  run_doctor --fix
  [ "$status" -eq 0 ]
  # doctor printed the rm of the known-bad link before re-seeding.
  [[ "$output" == *"[auto] rm "*".claude/rules/trellis.md"* ]]
  # Now retargeted to the fixture canonical and resolving.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "$CANON/core-rules/CLAUDE.md" ]
  [ -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [[ "$output" == *"✓ rules: trellis.md resolves to canonical"* ]]
}

# ===========================================================================
# 4. The --fix-hooks GATE. Fixture has BOTH a stale top-level hook AND a missing
#    rules symlink, so onboard actually RUNS — proving that onboard's seed pass
#    does NOT clobber the stale hook (never-clobber), and that ONLY --fix-hooks
#    (sync-hooks.sh) updates it.  (hook_gate_verified)
# ===========================================================================

@test "--fix WITHOUT --fix-hooks does NOT modify a drifted hook (reported skipped); --fix --fix-hooks DOES converge it" {
  build_canonical_tree
  add_canonical_hooks            # canonical hooks == worktree hooks
  git_init_canonical_main        # commit AFTER hooks so canonical stays clean
  build_healthy_project
  seed_project_hooks_from_canonical
  write_config

  local bell="$PROJECTS/healthy/.claude/hooks/session-context.sh"
  # Drift exactly one top-level hook so hc_hook_freshness WARNs on it.
  printf '\n# DRIFT MARKER\n' >> "$bell"
  local stale_sha canon_sha
  stale_sha="$(sha_of "$bell")"
  canon_sha="$(sha_of "$CANON/core-rules/hooks/session-context.sh")"
  [ "$stale_sha" != "$canon_sha" ]   # precondition: it really is drifted

  # Also break the rules symlink so onboard has a real reason to run. This makes
  # the gate load-bearing: onboard executes, yet must leave the stale hook alone.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  # --- plain --fix: onboard runs, hook must be UNTOUCHED, output says skipped ---
  run_doctor --fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped (run with --fix-hooks)"* ]]
  # The rules symlink WAS repaired (proving onboard ran)...
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "$CANON/core-rules/CLAUDE.md" ]
  # ...but the drifted hook is byte-for-byte UNCHANGED (still the stale sha,
  # NOT the canonical sha). This is the gate.
  [ "$(sha_of "$bell")" = "$stale_sha" ]
  [ "$(sha_of "$bell")" != "$canon_sha" ]

  # --- now --fix --fix-hooks: the hook converges to canonical ---
  run_doctor --fix --fix-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync-hooks.sh"* ]]
  [ "$(sha_of "$bell")" = "$canon_sha" ]
}

# ===========================================================================
# 5. A dead/cross-machine @-import is MANUAL-only: --fix NEVER edits a user's
#    CLAUDE.md. We pair it with a missing rules symlink so onboard actually runs
#    — proving onboard repairs the symlink yet leaves CLAUDE.md byte-identical.
#    The import is a dead ERROR, so the run stays non-zero (it is unfixed).
# ===========================================================================

@test "--fix on a dead @-import: CLAUDE.md is byte-identical, reported [manual], import still ERROR (non-zero exit)" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Dead cross-machine @-import (incident #1's literal shape).
  printf '# Healthy project\n\n@/Users/helios/claude/se-core-template/core-rules/CLAUDE.md\n' \
    > "$PROJECTS/healthy/CLAUDE.md"
  local cm="$PROJECTS/healthy/CLAUDE.md"
  local before_sha
  before_sha="$(sha_of "$cm")"
  # Also break the rules symlink so onboard genuinely runs alongside.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor --fix
  # Dead @-import is an ERROR and is NOT auto-fixed → the run is non-zero even
  # though the symlink was repaired.
  [ "$status" -ne 0 ]
  # Reported as a [manual] action (never auto-edited).
  [[ "$output" == *"[manual]"* ]]
  [[ "$output" == *"@-import"* ]]
  # onboard DID run and repaired the symlink (the load-bearing pairing)...
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "$CANON/core-rules/CLAUDE.md" ]
  # ...yet the user-owned CLAUDE.md is byte-for-byte UNCHANGED.
  [ "$(sha_of "$cm")" = "$before_sha" ]
  [[ "$output" == *"/Users/helios/"* ]]
  # The import row is still ✗ in the after-pass re-check.
  [[ "$output" == *"✗ import:"* ]]
}

# ===========================================================================
# 6. Tier-0 gate on --fix: a dirty/off-main canonical blocks ALL [auto] repair
#    (onboard would re-link projects to off-main/dirty rules — incident #2).
#    The bad symlink must therefore remain untouched.
# ===========================================================================

@test "--fix is BLOCKED by a Tier-0 ERROR: off-main canonical => [auto] skipped, the bad symlink is left as-is, non-zero exit" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Break the rules symlink (an [auto]-fixable condition)...
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" \
        "$PROJECTS/healthy/.claude/rules/trellis.md"
  # ...then push the canonical OFF main so Tier-0 ERRORs.
  ( cd "$CANON" && git checkout -q -b feat/poison )

  run_doctor --fix
  [ "$status" -ne 0 ]
  # [auto] repair is explicitly skipped while Tier-0 stands.
  [[ "$output" == *"SKIPPED"* ]]
  [[ "$output" == *"Tier-0"* ]]
  # The known-bad symlink was NOT touched — still pointing cross-machine.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
}

# ===========================================================================
# 7. Isolation tripwire: even under --fix, doctor must report the FIXTURE
#    canonical, never the live clone — a leaked config would mutate real
#    projects. (Mirrors doctor.bats's read-only isolation test for the mutating
#    path.)
# ===========================================================================

@test "isolation: --fix --dry-run reports the FIXTURE canonical, never the live clone" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor --fix --dry-run
  [[ "$output" == *"canonical clone: $CANON"* ]]
  [[ -z "$LIVE_CANON" || "$output" != *"$LIVE_CANON"* ]]
}

# ===========================================================================
# 8. Worktree-inheritance: DETECTION — linked worktree missing symlinks => WARN.
#
# The project is a real git repo (git_init_canonical_main + build_healthy_project
# already handles canonical; build_healthy_project here inits the project too).
# We add a linked worktree via `git worktree add` and leave its .claude/ absent
# (git worktree add only materialises tracked files; the symlinks are untracked
# so they are not present in the new worktree). We also copy the seeder into the
# fixture canonical (needed so hc_worktree_inheritance can locate it). The
# project's main-checkout symlinks are committed-untracked (they exist in the
# working tree, which is what the seeder mirrors).
# ===========================================================================

# Copy the real seed-inheritance-symlinks.sh into the fixture canonical's
# scripts/ directory so hc_worktree_inheritance can find it. Must be called
# BEFORE git_init_canonical_main so the copy is committed and the canonical
# stays clean.
add_canonical_seeder() {
  mkdir -p "$CANON/scripts"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$CANON/scripts/seed-inheritance-symlinks.sh"
  chmod +x "$CANON/scripts/seed-inheritance-symlinks.sh"
}

# Create a linked worktree for the healthy project at <sandbox>/worktrees/<name>.
# Returns the path in WT_PATH. Must be called AFTER build_healthy_project (needs
# a committed HEAD — git worktree add requires at least one commit).
add_linked_worktree() {
  local wt_name="${1:-wt1}"
  mkdir -p "$SANDBOX/worktrees"
  WT_PATH="$SANDBOX/worktrees/$wt_name"
  local hp="$PROJECTS/healthy"
  # Ensure there is at least one commit in the project (needed for git worktree
  # add). We commit only CLAUDE.md so the .claude/ symlinks stay untracked.
  (
    cd "$hp"
    git add CLAUDE.md 2>/dev/null || true
    git commit -q -m "init" --allow-empty 2>/dev/null || true
    git worktree add -q "$WT_PATH" HEAD
  )
}

@test "worktree-inheritance DETECTION: linked worktree missing symlinks => WARN (read-only doctor)" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "missing-wt"

  # Pre-condition: the worktree exists but has no .claude/ directory.
  [ -d "$WT_PATH" ]
  [ ! -d "$WT_PATH/.claude" ]

  run_doctor
  # Doctor WARNs about the missing-inheritance worktree.
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ worktree-inheritance:"* ]]
  [[ "$output" == *"missing inheritance symlinks"* ]]
}

@test "worktree-inheritance DETECTION: all linked worktrees healthy => no WARN" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "healthy-wt"

  # Seed the worktree manually so it is fully healthy before running doctor.
  bash "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" \
    --target "$WT_PATH" --root "$CANON" --quiet

  run_doctor
  # The worktree is healthy — no worktree-inheritance WARN.
  [ "$status" -eq 0 ]
  [[ "$output" != *"⚠ worktree-inheritance:"* ]]
  [[ "$output" == *"✓ worktree-inheritance:"* ]]
}

@test "worktree-inheritance FIX --dry-run: plans the seeder repair (seed-inheritance-symlinks.sh + wt path), changes nothing" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "dryrun-wt"

  # Pre-condition: worktree missing .claude/
  [ ! -d "$WT_PATH/.claude" ]
  local before
  before="$(ls "$WT_PATH" 2>/dev/null | sort)"

  run_doctor --fix --dry-run
  [ "$status" -eq 0 ]
  # The plan mentions seed-inheritance-symlinks.sh and the worktree path.
  [[ "$output" == *"seed-inheritance-symlinks.sh"* ]]
  [[ "$output" == *"$WT_PATH"* ]]
  [[ "$output" == *"nothing applied"* ]]

  # Filesystem is unchanged (dry-run = no mutation).
  local after
  after="$(ls "$WT_PATH" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
  [ ! -d "$WT_PATH/.claude" ]
}

@test "worktree-inheritance FIX: --fix seeds missing inheritance and re-check is OK (exit 0)" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "fix-wt"

  # Pre-condition: worktree missing .claude/
  [ ! -d "$WT_PATH/.claude" ]

  run_doctor --fix
  # After fix the re-check must show the worktree as healthy.
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-checking healthy after fixes"* ]]
  [[ "$output" == *"✓ worktree-inheritance:"* ]]
  # The symlinks must actually exist in the worktree.
  [ -d "$WT_PATH/.claude" ]
  [ -L "$WT_PATH/.claude/rules/trellis.md" ]
}

@test "worktree-inheritance FIX: Tier-0 gate blocks seed repair when canonical is off-main" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "gate-wt"

  # Push canonical off main so Tier-0 ERRORs.
  ( cd "$CANON" && git checkout -q -b feat/poison )

  run_doctor --fix
  # Tier-0 is in error → non-zero exit.
  [ "$status" -ne 0 ]
  # The seed repair is explicitly skipped (Tier-0 gate).
  [[ "$output" == *"SKIPPED"* ]]
  [[ "$output" == *"Tier-0"* ]]
  # The worktree must remain un-seeded.
  [ ! -d "$WT_PATH/.claude" ]
}
