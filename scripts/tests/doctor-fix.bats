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
#     project (its last statement is a `{ codex; } && echo` short
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
SHARED_FIXTURE="$BATS_TEST_DIRNAME/fixtures/shared-infra"
# The repo's configured canonical clone — what doctor must NOT print when run
# against a fixture (proves the $TRELLIS_CONFIG override took effect).
LIVE_CANON="$(jq -r '.trellis_root' "$REPO_ROOT/trellis.config.json" 2>/dev/null || true)"

CANON_SKILLS="process-gate security-gate aeo-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing"
CANON_COMMANDS="primer primer-refresh primer-check explore autonomy surgical"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  SHARED="$SANDBOX/shared-infra"
  CFG="$SANDBOX/trellis.config.json"
  # Pin the operator-state env every doctor run inherits. A legacy run must not
  # read the real machine's HOME or $TRELLIS_HOME, and any assertion about a
  # delegated engine's REFUSAL is only meaningful if ambient local state cannot
  # be what produced it. FIXTURE_TRELLIS_HOME is a private, empty machine home.
  FIXTURE_HOME="$SANDBOX/operator-home"
  FIXTURE_TRELLIS_HOME="$SANDBOX/machine-home"
  mkdir -p "$CANON" "$PROJECTS" "$FIXTURE_HOME" "$FIXTURE_TRELLIS_HOME"
  chmod 700 "$FIXTURE_TRELLIS_HOME"
  DOCTOR_SHARED_OVERRIDE=""
  export TRELLIS_CONFIG="$CFG"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# Lay down the canonical inheritance surface. Unlike doctor.bats's builder, this
# ALSO seeds core-rules/commands/templates/primer-index-template.md, which
# onboard-project.sh REQUIRES (it exits 1 before seeding anything if absent).
# The skills/commands manifests carry OMP discovery frontmatter, the agents dir
# holds only a .gitkeep (empty is healthy — the GPTX-era custom agents were
# removed), the OMP adapter stub exists (hc_omp_manifests / hc_omp_adapter
# require them), and core-rules/omp/hooks is present (onboard's OMP preflight
# requires the dir).
# Does NOT git init — that is git_init_canonical_main's job, run AFTER any
# per-test canonical augmentation so the committed tree stays clean (a dirty
# canonical trips Tier-0 ERROR, which gates ALL [auto] repair off).
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands/templates" \
    "$CANON/core-rules/agents" "$CANON/core-rules/omp/hooks/pre"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  # The canonical agents dir is EMPTY (the GPTX-era custom agents were removed;
  # only .gitkeep remains) — an empty .omp/agents target is healthy.
  printf '' > "$CANON/core-rules/agents/.gitkeep"
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
  printf '# primer index template\n' \
    > "$CANON/core-rules/commands/templates/primer-index-template.md"
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

# Seed the fixture canonical's core-rules/hooks by COPYING the REAL worktree's
# canonical hooks. This makes hc_hook_freshness's comparison target (fixture
# canonical) byte-identical to sync-hooks.sh's source (worktree), so a hook
# the project drifted from can be observed converging back. Call BEFORE
# git_init_canonical_main. Only the gate test needs hooks in the canonical;
# every other test deliberately omits them so onboard's hook seed does not add
# a spurious "hooks installed" surface to assert around.
add_canonical_hooks() {
  cp -R "$WORKTREE_HOOKS" "$CANON/core-rules/hooks"
  mkdir -p "$CANON/core-rules/templates"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.json" \
    "$CANON/core-rules/templates/claude-settings.json"
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

# Build a fully healthy "healthy" project: real git repo (onboard requires
# $PROJECT/.git), good rules symlink, canonical @-import, full skills + commands
# sets, a .claude/settings.json, and the five OMP surface links (design
# 2026-08-09). The git init is what lets onboard run when a later mutation
# breaks part of the surface.
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
  printf '{ "hooks": {} }\n' > "$hp/.claude/settings.json"
  # OMP surface: the five exact live links in the shared contract.
  ln -s "$hp/CLAUDE.md" "$hp/.omp/AGENTS.md"
  ln -s "$CANON/core-rules/skills" "$hp/.omp/skills"
  ln -s "$CANON/core-rules/commands" "$hp/.omp/commands"
  ln -s "$CANON/core-rules/agents" "$hp/.omp/agents"
  ln -s "$CANON/core-rules/omp/hooks" "$hp/.omp/hooks"
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
  if [ -n "$DOCTOR_SHARED_OVERRIDE" ]; then
    run env HOME="$FIXTURE_HOME" TRELLIS_HOME="$FIXTURE_TRELLIS_HOME" \
      SHARED_INFRA_ROOT="$DOCTOR_SHARED_OVERRIDE" bash "$DOCTOR" "$@"
  else
    run env -u SHARED_INFRA_ROOT HOME="$FIXTURE_HOME" \
      TRELLIS_HOME="$FIXTURE_TRELLIS_HOME" bash "$DOCTOR" "$@"
  fi
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
  [[ "$output" == *"--dry-run is only valid with --fix"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# 1. --fix --dry-run is READ-ONLY: prints the plan, mutates nothing.
#    Fixture has a STALE (wrong-target) rules symlink. Before the cutover this
#    was the rm+onboard [auto] path; since v1.0.0-rc.25 the only disposition is
#    [manual] with the migration that owns it. The read-only oracle is unchanged
#    and still load-bearing.  (dryrun_is_readonly_verified)
# ===========================================================================

@test "--fix --dry-run on a drifted fixture: prints the migration plan AND leaves the fixture byte/link-identical" {
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
  # The plan names the broken surface and the migration that owns it.
  [[ "$output" == *"[manual] stale/wrong rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" == *"nothing applied"* ]] || { echo "$output"; false; }
  # The removed writers must not be advertised in any spelling.
  [[ "$output" != *"[auto]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"onboard-project.sh"* ]] || { echo "$output"; false; }

  after="$(snapshot_project "$PROJECTS/healthy")"
  # READ-ONLY oracle: byte-for-byte + symlink-target identical before vs after.
  [ "$before" = "$after" ]
  # The bad symlink in particular was NOT touched.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
}

@test "--fix diagnoses inheritance without proposing registering reconciling or changing shared allocations" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  local before
  before="$(sha_of "$SHARED/projects.yaml")"

  run_doctor --fix
  # The missing rules symlink is now an unrepaired ERROR, so the run is non-zero.
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [ "$(sha_of "$SHARED/projects.yaml")" = "$before" ]
  # Doctor did NOT re-seed it — that is the migration's job now.
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  grep -q '^doctor ' "$SHARED/calls.log"
  [ ! -e "$PROJECTS/healthy/scripts/local-infra-preflight.sh" ]
  [[ "$output" == *"[manual] missing rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
  run grep -Eq '^(propose|register|reconcile|preflight) ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

@test "shared infrastructure drift stays an ERROR and does not suppress unrelated inheritance diagnosis" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  build_shared_infra_fixture
  write_config '"claude"' "$SHARED"
  DOCTOR_SHARED_OVERRIDE="$SHARED"
  printf 'deliberate drift\n' > "$SHARED/drift"
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  local before
  before="$(sha_of "$SHARED/projects.yaml")"

  run_doctor --fix
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ shared-infra doctor: read-only checks failed"* ]] || { echo "$output"; false; }
  # A failing shared-infra row must not swallow the per-project diagnosis: the
  # unrelated broken symlink is still classified and still names its migration.
  [[ "$output" == *"[manual] missing rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ "$(sha_of "$SHARED/projects.yaml")" = "$before" ]
  run grep -Eq '^(propose|register|reconcile|preflight) ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# 2. --fix repairs a MISSING rules symlink: afterward it resolves to canonical
#    and the re-check is ✓ + exit 0.  (fix_repairs_verified)
# ===========================================================================

@test "--fix on a MISSING rules symlink: nothing is re-seeded; the row stays ERROR and names its migration" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]

  run_doctor --fix
  # Unrepaired ERROR — the cutover removed every writer that could seed this.
  [ "$status" -ne 0 ]
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [[ "$output" == *"legacy direct-link repair was removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach --fleet NAME \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  # The AFTER-pass re-check still runs and still surfaces the row as broken.
  [[ "$output" == *"re-checking healthy after fixes"* ]] || { echo "$output"; false; }
  [[ "${output##*re-checking healthy after fixes}" == *"rules:"* ]] || { echo "$output"; false; }
  [[ "${output##*re-checking healthy after fixes}" != *"✓ rules: trellis.md resolves to canonical"* ]] \
    || { echo "$output"; false; }
}

# ===========================================================================
# 3. A STALE/broken symlink is the case that most needs a guard: the pre-cutover
#    path `rm`'d it before re-seeding. With the re-seed gone, an `rm` would
#    destroy a project-owned byte for nothing — so doctor must not touch it at
#    all. This pins that the bad link survives verbatim.
# ===========================================================================

@test "--fix on a STALE/wrong-target rules symlink: the bad link is never rm'd, and the migration is reported" {
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
  [ "$status" -ne 0 ]
  # No rm is planned or performed, in any spelling.
  [[ "$output" != *"[auto] rm "* ]] || { echo "$output"; false; }
  # The known-bad link is byte-identical — still pointing cross-machine.
  [ -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/Users/helios/claude/se-core-template/core-rules/CLAUDE.md" ]
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [[ "$output" == *"[manual] stale/wrong rules symlink .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
}

@test "the reported migration quotes a project path containing spaces as one argument" {
  local spaced_root="$SANDBOX/root with spaces"
  CANON="$spaced_root/canonical"
  PROJECTS="$spaced_root/projects"
  CFG="$spaced_root/trellis.config.json"
  export TRELLIS_CONFIG="$CFG"
  mkdir -p "$CANON" "$PROJECTS"

  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"
  ln -s "/nonexistent/wrong-target.md" \
    "$PROJECTS/healthy/.claude/rules/trellis.md"

  run_doctor --fix

  [ "$status" -ne 0 ] || { echo "$output"; false; }
  # The migration command an operator would paste must survive the spaces.
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach --fleet NAME \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  # And the wrong-target link is left exactly as found.
  [ "$(readlink "$PROJECTS/healthy/.claude/rules/trellis.md")" = \
    "/nonexistent/wrong-target.md" ]
}

# ===========================================================================
# 4. Hook drift on a LEGACY direct-link project is [manual], not [auto]/[hooks].
#    Fixture has BOTH a stale top-level hook AND a missing rules symlink, so
#    onboard actually RUNS — proving onboard's seed pass does NOT clobber the
#    stale hook (never-clobber) — while doctor classifies the hook drift as
#    unrepairable and prints the remedy that actually works.
#    (hook_manual_classification_verified)
#
#    Spec 036: sync-hooks.sh reconciles a hook surface ONLY through the
#    recorded immutable release of a REGISTERED, attached row, and never copies
#    a hook out of the mutable checkout that launched it. A legacy-config
#    project has no registry row and no recorded release, so an [auto]/[hooks]
#    repair could NEVER succeed. Doctor therefore stops advertising it: the row
#    is reported [manual] with the attach/adopt remedy, and --fix-hooks says
#    plainly that it is inert. The refusal that makes this the honest answer is
#    proven directly, against sync-hooks.sh itself, in the test after this one.
# ===========================================================================

@test "hook drift on a legacy project is reported [manual] with the attach remedy; neither --fix nor --fix-hooks delegates to sync-hooks.sh, and the after-pass still surfaces the drift" {
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

  # Also break the rules symlink. Before the cutover this made onboard run, so
  # the case proved onboard never-clobbered the hook. Since the cutover it makes
  # the point more directly: doctor repairs NEITHER surface, and says so.
  rm -f "$PROJECTS/healthy/.claude/rules/trellis.md"

  # --- plain --fix ---
  run_doctor --fix
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  # The honest remedy, naming the flow that CAN own hook reconciliation.
  [[ "$output" == *"[manual] Claude hook copies drift from canonical — no engine repairs a legacy direct-link project's hooks; attach it (scripts/attach-project.sh attach \"$PROJECTS/healthy\")"* ]] \
    || { echo "$output"; false; }
  # No [hooks] class, and no promise of a sync-hooks repair, in any spelling.
  [[ "$output" != *"[hooks]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"sync-hooks.sh --yes"* ]] || { echo "$output"; false; }
  [[ "$output" != *"run with --fix-hooks"* ]] || { echo "$output"; false; }
  # The rules symlink was NOT re-seeded...
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  [ ! -L "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  # ...and the drifted hook is byte-for-byte UNCHANGED.
  [ "$(sha_of "$bell")" = "$stale_sha" ]
  [ "$(sha_of "$bell")" != "$canon_sha" ]
  # And the AFTER-pass re-check still surfaces the drift — a [manual] row is
  # reported, never quietly resolved.
  [[ "$output" == *"-- re-checking healthy after fixes --"* ]] || { echo "$output"; false; }
  [[ "${output##*-- re-checking healthy after fixes --}" == *"hooks: drift vs canonical —stale: session-context.sh"* ]] \
    || { echo "$output"; false; }

  # --- --fix --fix-hooks: the flag is accepted and says it is inert. It must
  # NOT resurrect the delegation, and must not touch the hook.
  run_doctor --fix --fix-hooks
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[manual] --fix-hooks is inert:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[hooks]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"sync-hooks.sh --yes"* ]] || { echo "$output"; false; }
  [ "$(sha_of "$bell")" = "$stale_sha" ]
  [ "$(sha_of "$bell")" != "$canon_sha" ]
  [[ "${output##*-- re-checking healthy after fixes --}" == *"hooks: drift vs canonical —stale: session-context.sh"* ]] \
    || { echo "$output"; false; }
}

# The remedy above is honest only if sync-hooks.sh genuinely cannot repair this
# project. Prove that directly, against a PINNED private machine home (an empty
# $TRELLIS_HOME with no config and no registry — exactly what a legacy-config
# operator has), and assert the SPECIFIC refusal rather than "it failed".
@test "sync-hooks.sh refuses a legacy direct-link project outright: no local registry to reconcile through, hook bytes untouched" {
  build_canonical_tree
  add_canonical_hooks
  git_init_canonical_main
  build_healthy_project
  seed_project_hooks_from_canonical
  write_config

  local bell="$PROJECTS/healthy/.claude/hooks/session-context.sh"
  printf '\n# DRIFT MARKER\n' >> "$bell"
  local stale_sha
  stale_sha="$(sha_of "$bell")"

  run env -u SHARED_INFRA_ROOT HOME="$FIXTURE_HOME" TRELLIS_HOME="$FIXTURE_TRELLIS_HOME" \
    bash "$REPO_ROOT/scripts/sync-hooks.sh" --yes healthy
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  # The specific refusal: there is no registry row to reconcile through,
  # because a legacy direct-link project was never registered/attached at all.
  [[ "$output" == *"sync-hooks.sh: project not in local registry fleet personal: healthy"* ]] \
    || { echo "$output"; false; }
  # Refusal, not partial work: the drifted hook is byte-identical.
  [ "$(sha_of "$bell")" = "$stale_sha" ]
}

# ===========================================================================
# 5. A dead/cross-machine @-import is MANUAL-only: --fix NEVER edits a user's
#    CLAUDE.md. Since the cutover nothing else is edited either, so the
#    load-bearing assertion is that the user-owned file is byte-identical while
#    the dead import is still named in full.
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
  [[ "$output" == *"[manual]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"@-import"* ]] || { echo "$output"; false; }
  # Nothing was re-seeded...
  [ ! -e "$PROJECTS/healthy/.claude/rules/trellis.md" ]
  # ...and the user-owned CLAUDE.md is byte-for-byte UNCHANGED.
  [ "$(sha_of "$cm")" = "$before_sha" ]
  [[ "$output" == *"/Users/helios/"* ]] || { echo "$output"; false; }
  # The import row is still ✗ in the after-pass re-check.
  [[ "$output" == *"✗ import:"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# 6. Tier-0 on --fix. The gate used to exist because [auto] repair would re-link
#    projects to off-main/dirty rules (incident #2). With no [auto] channel left
#    there is nothing to gate — so the invariant the gate protected has to hold
#    unconditionally: a Tier-0 ERROR is reported and the bad symlink is
#    untouched, exactly as when the canonical is clean.
# ===========================================================================

@test "--fix under a Tier-0 ERROR: Tier-0 is reported, the bad symlink is left as-is, non-zero exit" {
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
  [[ "$output" == *"Tier-0"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Tier-0 is report-only"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"canonical clone: $CANON"* ]] || { echo "$output"; false; }
  [[ -z "$LIVE_CANON" || "$output" != *"$LIVE_CANON"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"⚠ worktree-inheritance:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"missing inheritance symlinks"* ]] || { echo "$output"; false; }
}

@test "worktree-inheritance DETECTION: all linked worktrees healthy => no WARN" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "healthy-wt"

  # Seed the worktree by hand. The legacy mirror command that used to do this
  # was removed at v1.0.0-rc.25, and its replacement needs local registration
  # this legacy-config fixture deliberately does not have — so the fixture
  # builds the healthy end state directly, by copying every managed link the
  # main checkout carries. Only the DETECTION is under test.
  local wt_link wt_dest
  while IFS= read -r wt_link; do
    [ -n "$wt_link" ] || continue
    wt_dest="$WT_PATH/${wt_link#"$PROJECTS/healthy/"}"
    mkdir -p "$(dirname "$wt_dest")"
    ln -sfn "$(readlink "$wt_link")" "$wt_dest"
  done < <(find "$PROJECTS/healthy/.claude" "$PROJECTS/healthy/.agents" \
    "$PROJECTS/healthy/.omp" -maxdepth 2 -type l 2>/dev/null)
  # .omp/AGENTS.md points at the checkout's OWN CLAUDE.md, so the worktree's
  # copy must point at the worktree's file, not the main checkout's.
  if [ -L "$PROJECTS/healthy/.omp/AGENTS.md" ]; then
    ln -sfn "$WT_PATH/CLAUDE.md" "$WT_PATH/.omp/AGENTS.md"
  fi

  run_doctor
  # The worktree is healthy — no worktree-inheritance WARN.
  [ "$status" -eq 0 ]
  [[ "$output" != *"⚠ worktree-inheritance:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"✓ worktree-inheritance:"* ]] || { echo "$output"; false; }
}

@test "worktree-inheritance FIX --dry-run: reports the clone migration and every offending worktree, changes nothing" {
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
  # The plan names the offending worktree and the clone migration that covers
  # it — never the removed per-worktree mirror command.
  [[ "$output" == *"[manual] linked worktree missing inheritance: $WT_PATH"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" != *"--legacy-mirror"* ]] || { echo "$output"; false; }
  [[ "$output" == *"nothing applied"* ]] || { echo "$output"; false; }

  # Filesystem is unchanged (dry-run = no mutation).
  local after
  after="$(ls "$WT_PATH" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
  [ ! -d "$WT_PATH/.claude" ]
}

@test "worktree-inheritance FIX: --fix seeds nothing; the worktree stays un-seeded and the WARN persists" {
  add_canonical_seeder
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  add_linked_worktree "fix-wt"

  # Pre-condition: worktree missing .claude/
  [ ! -d "$WT_PATH/.claude" ]

  run_doctor --fix
  # Worktree inheritance is a WARN, so a run with nothing else broken still
  # exits 0 — but nothing was seeded and the WARN is still reported after.
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-checking healthy after fixes"* ]] || { echo "$output"; false; }
  [[ "${output##*re-checking healthy after fixes}" == *"⚠ worktree-inheritance:"* ]] || { echo "$output"; false; }
  [ ! -d "$WT_PATH/.claude" ]
}

@test "worktree-inheritance FIX: an off-main canonical changes nothing — the worktree was never going to be seeded" {
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
  [[ "$output" == *"Tier-0"* ]] || { echo "$output"; false; }
  # The worktree remains un-seeded — the same outcome as a clean canonical,
  # because there is no seeding path left to gate.
  [ ! -d "$WT_PATH/.claude" ]
}

# ===========================================================================
# OMP surface (design 2026-08-09) — the --fix PLAN for a broken .omp link.
# Wrong-target OMP links used to follow the rm-then-onboard path. Since
# v1.0.0-rc.25 they follow the same path as every other legacy surface: report
# the migration, touch nothing. Here we pin the doctor-side plan and the
# read-only guarantee.
# ===========================================================================

@test "OMP --fix --dry-run: a wrong-target .omp link is reported for migration, and nothing is touched" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  # Repoint .omp/agents at a dead cross-machine path (incident #1 shape).
  rm -f "$PROJECTS/healthy/.omp/agents"
  ln -s "/Users/helios/claude/se-core-template/core-rules/agents" \
        "$PROJECTS/healthy/.omp/agents"
  local before after
  before="$(snapshot_project "$PROJECTS/healthy")"

  run_doctor --fix --dry-run
  [ "$status" -eq 0 ]
  # The plan names the broken OMP surface and the migration that owns it.
  [[ "$output" == *"[manual] OMP surface link missing/wrong/dangling under .omp/"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare \"$PROJECTS/healthy\""* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] rm "* ]] || { echo "$output"; false; }
  [[ "$output" == *"nothing applied"* ]] || { echo "$output"; false; }

  after="$(snapshot_project "$PROJECTS/healthy")"
  # READ-ONLY oracle: byte-for-byte + symlink-target identical before vs after.
  [ "$before" = "$after" ]
  # The bad link in particular was NOT touched.
  [ "$(readlink "$PROJECTS/healthy/.omp/agents")" = \
    "/Users/helios/claude/se-core-template/core-rules/agents" ]
}

# Portable T15 fixture is intentionally local-only. The source checkout is
# merely configuration provenance; no release or attachment is needed to prove
# doctor withholds an unsafe attach repair without mutating an inert manifest.
build_portable_doctor_fix_home() {
  PORTABLE_HOME="$SANDBOX/portable-home"
  PORTABLE_SOURCE="$SANDBOX/portable-source"
  PORTABLE_PROJECT="$SANDBOX/portable project"
  PORTABLE_ACCOUNT_HOME="$SANDBOX/portable-account"
  mkdir -p "$PORTABLE_HOME/locks" "$PORTABLE_HOME/state" "$PORTABLE_HOME/releases" \
    "$PORTABLE_SOURCE" "$PORTABLE_PROJECT" "$PORTABLE_ACCOUNT_HOME/.local/bin"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis"
  chmod 755 "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis"
  chmod 700 "$PORTABLE_HOME" "$PORTABLE_HOME/locks" "$PORTABLE_HOME/state" "$PORTABLE_HOME/releases"
  printf '{"schema_version":2,"harnesses":["claude","codex","omp"]}\n' > "$PORTABLE_SOURCE/trellis.config.json"
  cat > "$PORTABLE_HOME/config.json" <<EOF
{"schema_version":1,"source_root":"$PORTABLE_SOURCE","release_remote":"$PORTABLE_SOURCE","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX"]}}}
EOF
  chmod 600 "$PORTABLE_HOME/config.json"
  git -C "$PORTABLE_PROJECT" init -q -b main
  printf '{"schema_version":1,"project_id":"portable-fixture"}\n' > "$PORTABLE_PROJECT/.trellis.json"
  git -C "$PORTABLE_PROJECT" add .trellis.json
  git -C "$PORTABLE_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  identity="$(bash -c '. "'"$REPO_ROOT"'/scripts/lib/trellis-home.sh"; . "'"$REPO_ROOT"'/scripts/lib/local-registry.sh"; local_registry_identity_for_root "'"$PORTABLE_PROJECT"'"')"
  PORTABLE_CHECKOUT_ID="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  PORTABLE_WORKTREE_ID="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  PORTABLE_COMMON="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$PORTABLE_CHECKOUT_ID":{"root":"$PORTABLE_PROJECT","git_common_dir":"$PORTABLE_COMMON","release":"1.2.3","harnesses":["claude","codex","omp"],"worktrees":{"$PORTABLE_WORKTREE_ID":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"
}

@test "portable doctor --fix --dry-run withholds attach when the recorded release is unavailable" {
  build_portable_doctor_fix_home
  before="$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')"

  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash "$DOCTOR" --fix --dry-run

  [ "$status" -eq 5 ]
  [[ "$output" == *"repair boundary: attach/relink is withheld until recorded immutable release 1.2.3 validates"* ]] || { echo "$output"; false; }
  [ ! -e "$PORTABLE_PROJECT/.trellis/runtime" ]
  [ "$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')" = "$before" ]
}

run_portable_doctor_fix() {
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" bash "$DOCTOR" "$@"
}

install_portable_doctor_release() {
  local repo="$SANDBOX/portable-release" command_name hook
  mkdir -p \
    "$repo/core-rules/skills/fixture" \
    "$repo/core-rules/commands/templates" \
    "$repo/core-rules/agents" \
    "$repo/core-rules/hooks/lib" \
    "$repo/core-rules/githooks" \
    "$repo/core-rules/codex/hooks/lib" \
    "$repo/core-rules/omp/hooks/pre" \
    "$repo/core-rules/templates" \
    "$repo/core-rules/presets"
  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$repo/core-rules/inheritance-manifest.json"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  mkdir -p "$repo/scripts"
  cp "$REPO_ROOT/scripts/trellis" "$repo/scripts/trellis"
  cp "$REPO_ROOT/scripts/release.sh" "$repo/scripts/release.sh"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/scripts/trellis" "$repo/scripts/release.sh" \
    "$repo/scripts/attach-project.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  cat > "$repo/trellis.config.json" <<'EOF'
{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude","codex","omp"],"autonomy_default":2}
EOF
  printf '1.2.3\n' > "$repo/core-rules/VERSION"
  printf '# fixture rules\n' > "$repo/core-rules/CLAUDE.md"
  printf -- '---\nname: fixture\ndescription: fixture\n---\n' > "$repo/core-rules/skills/fixture/SKILL.md"
  for command_name in fixture primer primer-refresh primer-check explore surgical; do
    printf '# fixture command %s\n' "$command_name" > "$repo/core-rules/commands/$command_name.md"
  done
  printf '# primer\n' > "$repo/core-rules/commands/templates/primer-index-template.md"
  printf '# fixture agent\n' > "$repo/core-rules/agents/fixture.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/hooks/fixture.sh"
  chmod 755 "$repo/core-rules/hooks/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  chmod 755 "$repo/core-rules/githooks/pre-push"
  # Mirrors doctor.bats: every lib the manifest declares as an explicit codex link
  # source is mandatory in the payload, so a new manifest entry lands here too.
  for hook in fixture aeo-gate-warn code-reviewer decision-receipt-core slop-patterns spec-gate-core ui-verify-core; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/hooks/lib/$hook.sh"
    chmod 755 "$repo/core-rules/hooks/lib/$hook.sh"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/codex/hooks/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/codex/hooks/lib/fixture.sh"
  chmod 755 "$repo/core-rules/codex/hooks/fixture.sh" "$repo/core-rules/codex/hooks/lib/fixture.sh"
  printf 'export const fixture = true;\n' > "$repo/core-rules/omp/hooks/pre/fixture.ts"
  (
    cd "$repo"
    git init -q -b main
    git config user.email fixture@example.invalid
    git config user.name fixture
    git config commit.gpgsign false
    git config tag.gpgSign false
    git add -A
    git commit -qm fixture
    git tag -a v1.2.3 -m fixture
  )
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis" release install 1.2.3 --remote "$repo"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis" release verify 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

attach_portable_doctor_project() {
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 \
      --harness claude --harness codex --harness omp "$PORTABLE_PROJECT"
  if [ "$status" -ne 0 ]; then
    printf 'attach_portable_doctor_project failed (exit %s):\n%s\n' "$status" "$output" >&2
    return "$status"
  fi
}

build_portable_fixture_project() {
  local root="$1" project_id="$2"
  mkdir -p "$root"
  git -C "$root" init -q -b main
  printf '{"schema_version":1,"project_id":"%s"}\n' "$project_id" > "$root/.trellis.json"
  git -C "$root" add .trellis.json
  git -C "$root" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}

portable_identity_for_root() {
  bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; local_registry_identity_for_root "$2"' \
    _ "$REPO_ROOT" "$1"
}

@test "portable doctor --fix --dry-run preserves harnesses and quotes attachment arguments" {
  build_portable_doctor_fix_home
  install_portable_doctor_release

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"[auto] trellis attach"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--harness claude"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--harness codex"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--harness omp"* ]] || { echo "$output"; false; }
  [[ "$output" == *"portable\\ project"* ]] || { echo "$output"; false; }
  [[ "$output" == *"safe repair through trellis attach is planned but was not applied"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses a dry-run attach with an empty registry harness set" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  jq '.projects["personal/portable-fixture"].checkouts |= with_entries(.value.harnesses = [])' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"registry harness selection is empty or invalid; attach cannot choose native surfaces"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor never reattaches detached or excluded rows" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  jq '.projects["personal/portable-fixture"].status = "detached"' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"registry status: detached"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }

  jq '.projects["personal/portable-fixture"].status = "active"
      | .projects["personal/portable-fixture"].metadata = {legacy:{blacklisted:true}}' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"registry exclusion: automatic attachment repair is withheld"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses unsafe attachment journal entries instead of recovering or attaching" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  mkdir -p "$PORTABLE_HOME/state/attachment-journals"
  chmod 700 "$PORTABLE_HOME/state" "$PORTABLE_HOME/state/attachment-journals"
  ln -s "$SANDBOX/untrusted-journal" "$PORTABLE_HOME/state/attachment-journals/corrupt.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"attachment journal entry is a symlink or non-regular file"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses an unexpected attachment journal node instead of treating it as absent" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  mkdir -p "$PORTABLE_HOME/state/attachment-journals"
  chmod 700 "$PORTABLE_HOME/state" "$PORTABLE_HOME/state/attachment-journals"
  ln -s "$SANDBOX/untrusted-journal" "$PORTABLE_HOME/state/attachment-journals/unexpected-node"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"attachment journal directory has an unexpected entry"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor refuses a valid-shaped journal for a different registry row" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" ATTACHMENT_FAULT_PHASE=prepared \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 --harness claude "$PORTABLE_PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  journal="$(find "$PORTABLE_HOME/state/attachment-journals" -type f -name '*.json' -print)"
  [ -f "$journal" ]
  jq '.project_id = "different-project"' "$journal" > "$journal.next"
  mv "$journal.next" "$journal"
  chmod 600 "$journal"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 3 ]
  [[ "$output" == *"attachment journal does not exactly match this registry row"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor withholds even an exact journal and continues later rows" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" ATTACHMENT_FAULT_PHASE=prepared \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 --harness claude "$PORTABLE_PROJECT"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  journal="$(find "$PORTABLE_HOME/state/attachment-journals" -type f -name '*.json' -print)"
  [ -f "$journal" ]
  journal_before="$(shasum -a 256 "$journal" | awk '{print $1}')"
  project_before="$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')"

  visible_root="$SANDBOX/z-visible"
  build_portable_fixture_project "$visible_root" z-visible
  visible_identity="$(portable_identity_for_root "$visible_root")"
  visible_checkout="$(printf '%s\n' "$visible_identity" | jq -r '.checkout_id')"
  visible_worktree="$(printf '%s\n' "$visible_identity" | jq -r '.worktree_id')"
  visible_common="$(printf '%s\n' "$visible_identity" | jq -r '.git_common_dir')"
  jq --arg checkout "$visible_checkout" --arg common "$visible_common" \
    --arg root "$visible_root" --arg worktree "$visible_worktree" '
      .projects["personal/z-visible"] = {
        fleet: "personal", project_id: "z-visible", status: "active", metadata: {},
        checkouts: {
          ($checkout): {
            root: $root, git_common_dir: $common, release: "1.2.3", harnesses: ["claude"],
            worktrees: {($worktree): {root: $root}}
          }
        }
      }
    ' "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"attachment journal at $journal (state=prepared) requires manual recovery"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis recover --home"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis recover"* ]] || { echo "$output"; false; }
  [[ "${output#*portable-fixture (worktree)}" == *"z-visible (worktree)"* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$journal" | awk '{print $1}')" = "$journal_before" ]
  [ "$(shasum -a 256 "$PORTABLE_PROJECT/.trellis.json" | awk '{print $1}')" = "$project_before" ]
  [ ! -e "$PORTABLE_PROJECT/.trellis/runtime" ]
}

@test "portable doctor dry-run remains nonzero for an unavailable row" {
  build_portable_doctor_fix_home
  jq '.projects["personal/portable-fixture"].status = "unavailable"' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 5 ]
  [[ "$output" == *"unavailable: retained local registry row at $PORTABLE_PROJECT"* ]] || { echo "$output"; false; }
}

@test "portable doctor treats a corrupt recorded release as a row error" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  corrupt_file="$PORTABLE_HOME/releases/1.2.3/payload/trellis.config.json"
  chmod u+w "$corrupt_file"
  printf '\n# corrupted after verification\n' >> "$corrupt_file"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 4 ]
  [[ "$output" == *"immutable release: 1.2.3 is corrupt or unsafe"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis attach"* ]] || { echo "$output"; false; }
}

@test "portable doctor does not relink when native surfaces or excludes drift" {
  build_portable_doctor_fix_home
  attach_portable_doctor_project
  rm "$PORTABLE_PROJECT/.trellis/runtime"
  printf '\n# user exclude drift\n' >> "$PORTABLE_PROJECT/.git/info/exclude"
  jq --arg checkout "$PORTABLE_CHECKOUT_ID" --arg worktree "$PORTABLE_WORKTREE_ID" \
    '.projects["personal/portable-fixture"].checkouts[$checkout].harnesses = ["codex"]' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  # The registry harness selection is an input to the native-surface plan the
  # owner exclude block is derived from, so shrinking that selection changes the
  # EXPECTED block and the excludes check reports a plan mismatch. It therefore
  # never reaches the "surrounding user bytes changed" wording, which compares
  # the on-disk file against an expected block it has already rejected. This
  # assertion asked for that later wording and was inert (a bare mid-test
  # `[[ … ]]` does not fail a bats test on this host), so it never reported that
  # it was checking for a message this fixture cannot produce. Exclude-byte
  # drift is asserted on its own below, where it is actually reachable.
  [ "$status" -eq 3 ]
  [[ "$output" == *"managed excludes: owner block does not match the exact immutable native surface plan"* ]] || { echo "$output"; false; }
  [[ "$output" == *"native surfaces: registry harness selection does not exactly match"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis relink"* ]] || { echo "$output"; false; }

  # Restore the attached harness selection so the expected block matches again,
  # leaving the appended user bytes as the only drift. That is the fixture in
  # which the byte-level wording IS reachable, so the exclude-byte invariant
  # this test is named for stays proven rather than merely asserted.
  jq --arg checkout "$PORTABLE_CHECKOUT_ID" \
    '.projects["personal/portable-fixture"].checkouts[$checkout].harnesses = ["claude", "codex", "omp"]' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 3 ]
  [[ "$output" == *"managed excludes: exact Trellis-owned block or surrounding user bytes changed"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[auto] trellis relink"* ]] || { echo "$output"; false; }
}

@test "portable doctor reports identity drift and still enumerates a later row" {
  build_portable_doctor_fix_home
  install_portable_doctor_release
  drift_root="$SANDBOX/a-drift"
  visible_root="$SANDBOX/z-visible"
  build_portable_fixture_project "$drift_root" a-drift
  build_portable_fixture_project "$visible_root" z-visible
  drift_identity="$(portable_identity_for_root "$drift_root")"
  visible_identity="$(portable_identity_for_root "$visible_root")"
  drift_checkout="$(printf '%s\n' "$drift_identity" | jq -r '.checkout_id')"
  drift_common="$(printf '%s\n' "$drift_identity" | jq -r '.git_common_dir')"
  visible_checkout="$(printf '%s\n' "$visible_identity" | jq -r '.checkout_id')"
  visible_worktree="$(printf '%s\n' "$visible_identity" | jq -r '.worktree_id')"
  visible_common="$(printf '%s\n' "$visible_identity" | jq -r '.git_common_dir')"
  cat > "$PORTABLE_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/a-drift":{"fleet":"personal","project_id":"a-drift","status":"active","metadata":{},"checkouts":{"$drift_checkout":{"root":"$drift_root","git_common_dir":"$drift_common","release":"1.2.3","harnesses":["claude"],"worktrees":{"0000000000000000000000000000000000000000000000000000000000000000":{"root":"$drift_root"}}}}},"personal/z-visible":{"fleet":"personal","project_id":"z-visible","status":"active","metadata":{},"checkouts":{"$visible_checkout":{"root":"$visible_root","git_common_dir":"$visible_common","release":"1.2.3","harnesses":["claude"],"worktrees":{"$visible_worktree":{"root":"$visible_root"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"
  jq '.projects["personal/a-drift"].checkouts |= with_entries(.value.release = "9.9.9")' \
    "$PORTABLE_HOME/registry.json" > "$PORTABLE_HOME/registry.next"
  mv "$PORTABLE_HOME/registry.next" "$PORTABLE_HOME/registry.json"
  chmod 600 "$PORTABLE_HOME/registry.json"

  run_portable_doctor_fix --fix --dry-run

  [ "$status" -eq 5 ]
  [[ "$output" == *"a-drift (worktree)"* ]] || { echo "$output"; false; }
  # The detail text comes from local_registry (`worktree ID does not match
  # recorded root`); the wording this assertion asked for was never emitted by
  # any code path. It was inert, so the mismatch went unreported.
  [[ "$output" == *"identity drift: worktree ID does not match recorded root"* ]] || { echo "$output"; false; }
  [[ "$output" == *"immutable release: 9.9.9 is unavailable"* ]] || { echo "$output"; false; }
  [[ "${output#*a-drift (worktree)}" == *"z-visible (worktree)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[auto] trellis attach"*"$visible_root"* ]] || { echo "$output"; false; }
}
