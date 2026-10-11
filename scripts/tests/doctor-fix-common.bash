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
# Consumed by the doctor-fix-part1.bats suite that loads this helper.
# shellcheck disable=SC2034
LIVE_CANON="$(CDPATH='' cd "$REPO_ROOT" && pwd -P)"

CANON_SKILLS="process-gate security-gate aeo-gate clarify spec plan tasks analyze execute brainstorming orchestrate debrief writing wiki-maintain wiki-skill-propose"
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
  # A fixture attach must not leave a detached post-attach job that repairs
  # core.hooksPath behind a test's back. attach-postjob.bats unsets this.
  export TRELLIS_ATTACH_POSTJOB=off
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
# Does NOT git init — that is git_init_canonical_main's job, run AFTER any
# per-test canonical augmentation so the committed tree stays clean (a dirty
# canonical trips Tier-0 ERROR, which gates ALL [auto] repair off).
build_canonical_tree() {
  mkdir -p "$CANON/core-rules/skills" "$CANON/core-rules/commands/templates" \
    "$CANON/core-rules/agents"
  printf '# Parent engineering rules\n' > "$CANON/core-rules/CLAUDE.md"
  # The canonical agents dir is empty; only .gitkeep remains.
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
    cd "$CANON" || return 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    git add -A
    git commit -q -m "init"
  )
}

write_config() {
  local harnesses_json="${1:-\"claude\",\"codex\"}"
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
# sets and a .claude/settings.json. The git init is what lets onboard run when a later mutation
# breaks part of the surface.
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
    cd "$hp" || return 1
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



# ===========================================================================
# 1. --fix --dry-run is READ-ONLY: prints the plan, mutates nothing.
#    Fixture has a STALE (wrong-target) rules symlink. Before the cutover this
#    was the rm+onboard [auto] path; since v1.0.0-rc.25 the only disposition is
#    [manual] with the migration that owns it. The read-only oracle is unchanged
#    and still load-bearing.  (dryrun_is_readonly_verified)
# ===========================================================================




# ===========================================================================
# 2. --fix repairs a MISSING rules symlink: afterward it resolves to canonical
#    and the re-check is ✓ + exit 0.  (fix_repairs_verified)
# ===========================================================================


# ===========================================================================
# 3. A STALE/broken symlink is the case that most needs a guard: the pre-cutover
#    path `rm`'d it before re-seeding. With the re-seed gone, an `rm` would
#    destroy a project-owned byte for nothing — so doctor must not touch it at
#    all. This pins that the bad link survives verbatim.
# ===========================================================================



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


# The remedy above is honest only if sync-hooks.sh genuinely cannot repair this
# project. Prove that directly, against a PINNED private machine home (an empty
# $TRELLIS_HOME with no config and no registry — exactly what a legacy-config
# operator has), and assert the SPECIFIC refusal rather than "it failed".

# ===========================================================================
# 5. A dead/cross-machine @-import is MANUAL-only: --fix NEVER edits a user's
#    CLAUDE.md. Since the cutover nothing else is edited either, so the
#    load-bearing assertion is that the user-owned file is byte-identical while
#    the dead import is still named in full.
# ===========================================================================


# ===========================================================================
# 6. Tier-0 on --fix. The gate used to exist because [auto] repair would re-link
#    projects to off-main/dirty rules (incident #2). With no [auto] channel left
#    there is nothing to gate — so the invariant the gate protected has to hold
#    unconditionally: a Tier-0 ERROR is reported and the bad symlink is
#    untouched, exactly as when the canonical is clean.
# ===========================================================================


# ===========================================================================
# 7. Isolation tripwire: even under --fix, doctor must report the FIXTURE
#    canonical, never the live clone — a leaked config would mutate real
#    projects. (Mirrors doctor.bats's read-only isolation test for the mutating
#    path.)
# ===========================================================================


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
    cd "$hp" || return 1
    git add CLAUDE.md 2>/dev/null || true
    git commit -q -m "init" --allow-empty 2>/dev/null || true
    git worktree add -q "$WT_PATH" HEAD
  )
}






# Portable fixture is intentionally local-only. The source checkout is merely
# configuration provenance; no release or attachment is needed to prove doctor
# withholds an unsafe attach repair without mutating an inert manifest.
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
  printf '{"schema_version":2,"harnesses":["claude","codex"]}\n' > "$PORTABLE_SOURCE/trellis.config.json"
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
{"schema_version":1,"projects":{"personal/portable-fixture":{"fleet":"personal","project_id":"portable-fixture","status":"active","metadata":{},"checkouts":{"$PORTABLE_CHECKOUT_ID":{"root":"$PORTABLE_PROJECT","git_common_dir":"$PORTABLE_COMMON","release":"1.2.3","harnesses":["claude","codex"],"worktrees":{"$PORTABLE_WORKTREE_ID":{"root":"$PORTABLE_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$PORTABLE_HOME/registry.json"
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
    "$repo/core-rules/templates" \
    "$repo/core-rules/presets"
  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$repo/core-rules/inheritance-manifest.json"
  cp -R "$REPO_ROOT/core-rules/pi" "$repo/core-rules/pi"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  mkdir -p "$repo/scripts"
  cp "$REPO_ROOT/scripts/trellis" "$repo/scripts/trellis"
  cp "$REPO_ROOT/scripts/release.sh" "$repo/scripts/release.sh"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/scripts/trellis" "$repo/scripts/release.sh" \
    "$repo/scripts/attach-project.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  cat > "$repo/trellis.config.json" <<'EOF'
{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude","codex"],"autonomy_default":2}
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
  # The carrier attach selects when the project has a .husky/ directory.
  mkdir -p "$repo/core-rules/husky"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/husky/pre-push"
  chmod 755 "$repo/core-rules/husky/pre-push"
  # Mirrors doctor.bats: every lib the manifest declares as an explicit codex link
  # source is mandatory in the payload, so a new manifest entry lands here too.
  for hook in fixture aeo-gate-warn code-reviewer decision-receipt-core slop-patterns spec-gate-core ui-verify-core verification-receipt action-normalize hookspath-check; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/hooks/lib/$hook.sh"
    chmod 755 "$repo/core-rules/hooks/lib/$hook.sh"
  done
  # Shared task and verification primitives are explicit manifest link sources.
  # Keep this minimal payload complete before its immutable tree is sealed.
  for primitive in task-context.sh task-state.py verification-bash.py guard-supervise.pl; do
    cp "$REPO_ROOT/core-rules/hooks/lib/$primitive" "$repo/core-rules/hooks/lib/$primitive" || return 1
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/codex/hooks/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/codex/hooks/lib/fixture.sh"
  chmod 755 "$repo/core-rules/codex/hooks/fixture.sh" "$repo/core-rules/codex/hooks/lib/fixture.sh"
  (
    cd "$repo" || return 1
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
  # Bats run sets status and output in the calling shell.
  # shellcheck disable=SC2154
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    "$PORTABLE_ACCOUNT_HOME/.local/bin/trellis" release verify 1.2.3
  # Bats run sets status and output in the calling shell.
  # shellcheck disable=SC2154
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

attach_portable_doctor_project() {
  install_portable_doctor_release
  run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
      --fleet personal --release 1.2.3 \
      --harness claude --harness codex "$PORTABLE_PROJECT"
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














# --- spec 055 R4.6: narrow core.hooksPath repair (A4.4) ------------------------
#
# husky's `prepare` sets core.hooksPath to .husky/_ and git stops invoking the
# Trellis dispatcher. `doctor --fix` restores the managed path only when every
# preflight condition holds; every refusal leaves the config byte-identical and
# names its remedy.

# hooks_fix_attach <recorded-previous: husky|null>
hooks_fix_attach() {
  build_portable_doctor_fix_home
  if [ "$1" = husky ]; then
    # husky 9's runner shape: .husky/_/pre-push runs the project's .husky/pre-push.
    mkdir -p "$PORTABLE_PROJECT/.husky/_"
    printf '#!/bin/sh\nexec "$(dirname "$0")/../pre-push" "$@"\n' > "$PORTABLE_PROJECT/.husky/_/pre-push"
    printf '#!/bin/sh\nprintf chained > "%s"\n' "$SANDBOX/husky-pre-push-ran" > "$PORTABLE_PROJECT/.husky/pre-push"
    chmod +x "$PORTABLE_PROJECT/.husky/_/pre-push" "$PORTABLE_PROJECT/.husky/pre-push"
    git -C "$PORTABLE_PROJECT" config --local core.hooksPath .husky/_
  fi
  attach_portable_doctor_project
  HF_OWNER="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$PORTABLE_WORKTREE_ID.json"
  HF_MANAGED="$PORTABLE_HOME/state/git-hooks/$PORTABLE_CHECKOUT_ID"
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = "$HF_MANAGED" ]
}

husky_prepare() {
  mkdir -p "$PORTABLE_PROJECT/.husky/_"
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath .husky/_
}

config_digest() { shasum -a 256 "$PORTABLE_PROJECT/.git/config" | awk '{print $1}'; }

assert_refused_unchanged() {
  local before="$1" remedy="$2"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath repair refused"*"remedy: $remedy"*"nothing was changed"* ]] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath repaired"* ]] || { echo "$output"; false; }
  [[ "$output" != *"config core.hooksPath "* ]] || { echo "$output"; false; }
  [ "$(config_digest)" = "$before" ]
}


assert_repaired_null_previous() {
  run_portable_doctor_fix --fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath repaired in"*": .husky/_ -> "* ]] || { echo "$output"; false; }
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = "$HF_MANAGED" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$HF_OWNER")" = null ]
}













# ---------------------------------------------------------------------------
# A4.4, R4.6a: `trellis doctor --fix --adopt-husky`.
# ---------------------------------------------------------------------------

# husky 9's runner layout: .husky/_/ holds one runner per git hook name, each
# sourcing _/h, which runs the project's .husky/<name> when it exists.
HUSKY9_HOOKS="applypatch-msg commit-msg post-applypatch post-checkout post-commit post-merge post-rewrite pre-applypatch pre-auto-gc pre-commit pre-merge-commit pre-push pre-rebase prepare-commit-msg"
# The names Trellis passes through: husky's set minus pre-push and post-checkout.
ADOPT_PASSTHROUGH="applypatch-msg commit-msg post-applypatch post-commit post-merge post-rewrite pre-applypatch pre-auto-gc pre-commit pre-merge-commit pre-rebase prepare-commit-msg"

husky9_layout() {
  local root="$1" name
  mkdir -p "$root/.husky/_"
  printf '*\n' > "$root/.husky/_/.gitignore"
  cat > "$root/.husky/_/h" <<'H'
#!/usr/bin/env sh
n=$(basename "$0")
s=$(dirname "$(dirname "$0")")/$n
[ -f "$s" ] || exit 0
sh -e "$s" "$@"
H
  chmod 755 "$root/.husky/_/h"
  for name in $HUSKY9_HOOKS; do
    printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n' > "$root/.husky/_/$name"
    chmod 755 "$root/.husky/_/$name"
  done
}

# Case (c) with husky 9's layout and a project .husky/pre-commit, drifted to .husky/_.
# With `sibling`, a linked worktree attached the normal way shares the checkout;
# attach records it as {"enabled":false} and HF_SIBLING_SUM holds its bytes.
adopt_husky_fixture() {
  local wid
  hooks_fix_attach null
  HF_SIBLING_OWNER=""
  if [ "${1:-}" = sibling ]; then
    HF_SIBLING="$SANDBOX/sibling-wt"
    git -C "$PORTABLE_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b sibling "$HF_SIBLING"
    HF_SIBLING="$(cd "$HF_SIBLING" && pwd -P)"
    run env -u TRELLIS_CONFIG HOME="$PORTABLE_ACCOUNT_HOME" TRELLIS_HOME="$PORTABLE_HOME" \
      bash "$REPO_ROOT/scripts/attach-project.sh" attach --home "$PORTABLE_HOME" \
        --fleet personal --release 1.2.3 --harness claude --harness codex "$HF_SIBLING"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    wid="$(printf '%s' "$HF_SIBLING" | shasum -a 256 | awk '{print $1}')"
    HF_SIBLING_OWNER="$PORTABLE_HOME/state/attachments/$PORTABLE_CHECKOUT_ID/$wid.json"
    [ -f "$HF_SIBLING_OWNER" ]
    [ "$(jq -c '.git_hooks' "$HF_SIBLING_OWNER")" = '{"enabled":false}' ]
    HF_SIBLING_SUM="$(shasum -a 256 < "$HF_SIBLING_OWNER")"
    husky9_layout "$HF_SIBLING"
  fi
  husky9_layout "$PORTABLE_PROJECT"
  printf '#!/bin/sh\nprintf ran > "%s"\n' "$SANDBOX/husky-pre-commit-ran" > "$PORTABLE_PROJECT/.husky/pre-commit"
  chmod +x "$PORTABLE_PROJECT/.husky/pre-commit"
  git -C "$PORTABLE_PROJECT" config --local core.hooksPath .husky/_
}

# Bytes and mode of every record, and every entry of the managed dir (which
# holds the sidecar), by type.
adopt_snapshot() {
  local f
  for f in "$HF_OWNER" ${HF_SIBLING_OWNER:+"$HF_SIBLING_OWNER"}; do
    printf 'R %s %s %s\n' "$f" "$(stat -f %Lp "$f")" "$(shasum -a 256 < "$f" | awk '{print $1}')"
  done
  ( cd "$HF_MANAGED" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"
      elif [ -d "$f" ]; then printf 'D %s %s\n' "$f" "$(stat -f %Lp "$f")"
      else printf 'F %s %s %s\n' "$f" "$(stat -f %Lp "$f")" "$(shasum -a 256 < "$f" | awk '{print $1}')"
      fi
    done )
}

# The R4.6a set is back to its original bytes and mode and no shim remains.
assert_adopt_rolled_back() {
  local before="$1" f name
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"husky adoption rolled back"* ]] || { echo "$output"; false; }
  [ "$(adopt_snapshot)" = "$before" ] || { diff <(printf '%s\n' "$before") <(adopt_snapshot); false; }
  [ "$(jq -r '.git_hooks | has("previous_hooks_path") and .previous_hooks_path == null' "$HF_OWNER")" = true ]
  assert_linked_record_unchanged
  [ "$(wc -c < "$HF_MANAGED/previous-hooks-path" | tr -d ' ')" -eq 1 ]
  [ -z "$(cat "$HF_MANAGED/previous-hooks-path")" ]
  for name in $ADOPT_PASSTHROUGH; do
    [ ! -e "$HF_MANAGED/$name" ] && [ ! -L "$HF_MANAGED/$name" ]
  done
}

# The R4.6a set failed on its own, so the R4.6 config write never ran.
assert_rolled_back_before_repair() {
  [[ "$output" == *"husky adoption rolled back"*"after a failed write or post-check"* ]] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath repair"* ]] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath repaired"* ]] || { echo "$output"; false; }
}

strict_verifies() {
  bash -c '. "$1/scripts/lib/trellis-home.sh" && . "$1/scripts/lib/release-store.sh" && . "$1/scripts/lib/attachment.sh" &&
    _attachment_hooks_state_owned_matches_data "$2" "$(jq -c . "$3")" true' _ "$REPO_ROOT" "$PORTABLE_HOME" "$1"
}

recorded_shim_body() {
  bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 && _attachment_hooks_passthrough_shim_body "$2"' \
    _ "$PORTABLE_HOME/releases/1.2.3/payload" "$1"
}

# The linked worktree's disabled record is byte-identical to what attach wrote.
assert_linked_record_unchanged() {
  [ -z "$HF_SIBLING_OWNER" ] || [ "$(shasum -a 256 < "$HF_SIBLING_OWNER")" = "$HF_SIBLING_SUM" ]
}

assert_adopted() {
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$HF_OWNER")" = ".husky/_" ]
  [ "$(stat -f %Lp "$HF_OWNER")" = 600 ]
  strict_verifies "$HF_OWNER" || { echo "strict verification failed for $HF_OWNER"; false; }
  assert_linked_record_unchanged
  [ "$(cat "$HF_MANAGED/previous-hooks-path")" = ".husky/_" ]
  [ "$(git -C "$PORTABLE_PROJECT" config --local --get-all core.hooksPath)" = "$HF_MANAGED" ]
}












# Drive the R4.6 worktree preflight directly, as (c''''s) does.
worktrees_ok() {
  bash -c 'for lib in trellis-home release-store local-registry surface-plan attachment health-checks; do . "$1/scripts/lib/$lib.sh" || exit 9; done
    _hc_hooks_path_worktrees_ok "$2" "$3" "$4" "$5"' _ "$REPO_ROOT" "$PORTABLE_HOME" "$PORTABLE_PROJECT" "$PORTABLE_CHECKOUT_ID" "$HF_MANAGED"
}


