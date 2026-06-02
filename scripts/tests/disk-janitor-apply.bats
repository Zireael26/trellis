#!/usr/bin/env bats
# THE SAFETY SUITE for scripts/disk-janitor.sh --apply.
#
# These tests verify the bright-line guardrails that keep --apply from ever
# destroying data it shouldn't. They are the load-bearing correctness proof for
# the whole feature. Every test is HERMETIC and CANNOT reach ~/projects:
#   * a fresh `mktemp -d` sandbox per test,
#   * a fixture trellis.config.json whose projects_root IS the sandbox,
#   * $TRELLIS_CONFIG exported so config-load resolves the FIXTURE config,
#   * the injectable overrides DJ_BUILD_ACTIVE_OVERRIDE / DJ_MERGED_OVERRIDE
#     exported into the child process — NEVER a live process or the network.
#
# Each negative ("must NOT delete") test asserts the ARTIFACT survives
# (`[ -d ]`), not merely that some "declined"/"skip" string printed — the
# filesystem is the real verification. Each positive ("must delete") test uses a
# positive control via the plan output so an empty-fleet/skipped vacuous pass
# can't masquerade as success.
#
# We always pass `</dev/null` to apply runs so a stray tty can never feed the
# y/N prompt, and `--yes` only where we WANT the destructive path to run.
# `--scopes` is pinned per test so the host-global `stores` scope never runs.
#
# Paths resolve relative to this file (../.. = worktree root) — no hardcoded
# absolute paths (those leak into the public mirror).
#
# bash 3.2 / bats 1.x. `[[ ]]` is fine in bats (not shellcheck-gated).

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"

# Far-past + recent fixed dates so staleness is deterministic (no race at the
# now-vs-mtime boundary). Stale dir mtime: 2000-01-01. Fresh dir mtime: now.
STALE_TOUCH="200001010000"          # touch -t form: CCYYMMDDhhmm
OLD_COMMIT_DATE="2020-01-01T00:00:00 +0000"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS"
  export TRELLIS_CONFIG="$CFG"
  build_canonical_min
  write_config
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Registry listing exactly one active project "alpha", empty blacklist.
build_canonical_min() {
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| alpha | \`/personal/alpha\` | app | fixture |

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

write_config() {
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"]
}
EOF
}

# Optional: drop a disk_janitor block with a custom cache_ttl_days so we can
# exercise the TTL boundary precisely. $1 = ttl days.
write_config_with_ttl() {
  local ttl="$1"
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"],
  "disk_janitor": { "cache_ttl_days": $ttl }
}
EOF
}

# git_init_at <dir> [iso-date] — init a repo with one backdated commit.
git_init_at() {
  local dir="$1" when="${2:-$OLD_COMMIT_DATE}"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    printf 'seed\n' > seed.txt
    git add -A
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q -m "init"
  )
}

# make_cache <project_dir> <relpath> <touch-stamp> — a non-empty cache dir whose
# DIR mtime is set explicitly (cache staleness keys on the directory mtime, so
# we touch the dir AFTER writing content, never before).
make_cache() {
  local proj="$1" rel="$2" stamp="$3" dir="$1/$2"
  mkdir -p "$dir"
  dd if=/dev/zero of="$dir/blob" bs=1024 count=8 >/dev/null 2>&1
  touch -t "$stamp" "$dir"
}

# add_worktree <repo> <wt_path> <branch> — a linked worktree on its own branch.
# The base commit is already backdated (git_init_at), so the worktree HEAD
# commit time is old -> dj_worktree_mtime reads as stale. Linked worktrees are
# placed UNDER projects_root (the .claude/worktrees house convention) so
# dj_reap_worktree's PROJECTS_ROOT-prefix guard permits removal.
add_worktree() {
  local repo="$1" wt="$2" branch="$3"
  ( cd "$repo" && git worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 )
}

run_dj() { run bash "$DJ" "$@"; }

# ===========================================================================
# CACHE PRUNE — TTL discrimination
# ===========================================================================

@test "cache prune deletes ONLY caches older than TTL; a younger cache survives" {
  git_init_at "$PROJECTS/alpha"
  # Stale cache (dir mtime in 2000) -> should be deleted.
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"
  # Fresh cache (dir mtime now) -> must survive.
  make_cache "$PROJECTS/alpha" ".turbo/cache" "$(date +%Y%m%d%H%M)"

  # Positive control: the plan must mark stale as delete and fresh as skip.
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"delete"*"$PROJECTS/alpha/.next/cache"* || "$output" == *"$PROJECTS/alpha/.next/cache"*"stale"* ]]

  # Apply, auto-confirm. </dev/null guards the prompt path even with --yes.
  run_dj --apply --yes --scopes caches </dev/null
  [ "$status" -eq 0 ]
  # The STALE cache dir is gone; the FRESH one survives. Filesystem is the proof.
  [ ! -d "$PROJECTS/alpha/.next/cache" ]
  [ -d "$PROJECTS/alpha/.turbo/cache" ]
}

@test "cache TTL boundary: ttl=36500 days makes everything fresh -> nothing deleted" {
  write_config_with_ttl 36500
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  run_dj --apply --yes --scopes caches </dev/null
  [ "$status" -eq 0 ]
  # Even the 2000-dated cache is "younger than 36500d" -> survives.
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

# ===========================================================================
# BUILD-ACTIVE GUARD
# ===========================================================================

@test "DJ_BUILD_ACTIVE_OVERRIDE=1 blocks cache deletion even when stale" {
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  DJ_BUILD_ACTIVE_OVERRIDE=1 run_dj --apply --yes --scopes caches </dev/null
  [ "$status" -eq 0 ]
  # Build "running" -> caches left intact, even though stale + --yes.
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "DJ_BUILD_ACTIVE_OVERRIDE=1 marks the cache 'skip' (build running) in the report" {
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"
  DJ_BUILD_ACTIVE_OVERRIDE=1 run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"build running"* ]]
  [[ "$output" != *"[delete]"* ]]
}

# ===========================================================================
# MERGE DISCRIMINATOR — the core correctness triple
# ===========================================================================

@test "worktree REAPED when merged + stale + clean + non-main (all 4 gates hold)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  # stale (backdated commit), clean (no edits), non-main (linked), merged (override).

  # Positive control: report must place this worktree in the delete plan.
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[delete]"*"$wt"* || "$output" == *"$wt"*"merged"* ]]

  [ -d "$wt" ]
  DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Reaped: the linked worktree directory is gone.
  [ ! -d "$wt" ]
}

@test "worktree NOT reaped when branch is UNMERGED (override=unmerged), even if stale+clean" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Unmerged branch -> the 4-gate triad fails -> NOT reaped.
  [ -d "$wt" ]
}

@test "worktree reported as candidate but NOT reaped when merge is UNVERIFIED (override=unverified)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # Report classifies it as a candidate (unverified merge), excluded from apply.
  DJ_MERGED_OVERRIDE=unverified run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate"* ]]
  [[ "$output" == *"unverified"* ]]

  DJ_MERGED_OVERRIDE=unverified run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Unverified -> NEVER reaped.
  [ -d "$wt" ]
}

# ===========================================================================
# UNTRACKED-WIP GUARD — clean check must include untracked files
# ===========================================================================

@test "worktree with untracked WIP is NOT reaped even when merged + stale + non-main" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  # Untracked work-in-progress file: dj_worktree_clean must report DIRTY (no -uno).
  printf 'precious un-committed work\n' > "$wt/WIP.txt"

  DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Clean gate fails on the untracked file -> worktree (and the WIP) survives.
  [ -d "$wt" ]
  [ -f "$wt/WIP.txt" ]
}

# ===========================================================================
# MAIN CHECKOUT — never reaped
# ===========================================================================

@test "main checkout is NEVER reaped (no linked worktrees present)" {
  git_init_at "$PROJECTS/alpha"
  # Only the main checkout exists. Even with merged override, it must survive.
  DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$PROJECTS/alpha/.git" ]
  [ -f "$PROJECTS/alpha/seed.txt" ]
}

@test "report classifies the main checkout as 'main checkout — never reaped'" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"main checkout — never reaped"* ]]
}

# ===========================================================================
# CONFIRMATION GATE — --apply without --yes and no 'y' deletes nothing
# ===========================================================================

@test "--apply without --yes and no 'y' on stdin deletes nothing (prompt declines on EOF)" {
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  # No --yes, stdin is EOF (/dev/null) -> confirm_category declines -> no delete.
  run_dj --apply --scopes caches </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"declined"* ]]
  # The stale cache survives because the operator never confirmed.
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "--apply without --yes but with 'n' on stdin deletes nothing" {
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  # Herestring (not a pipe): a pipe runs run_dj in a subshell, so bats' $status
  # would never propagate back to the test. <<< feeds stdin in-process.
  run_dj --apply --scopes caches <<<'n'
  [ "$status" -eq 0 ]
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "--apply without --yes WITH 'y' on stdin DOES delete the stale cache" {
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  # Feed an explicit 'y' to the single confirmation prompt (herestring, not a
  # pipe — see the 'n' test above for why).
  run_dj --apply --scopes caches <<<'y'
  [ "$status" -eq 0 ]
  [ ! -d "$PROJECTS/alpha/.next/cache" ]
}
