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
  # The /private/tmp ephemerality tests MUST create fixtures under the real
  # /private/tmp (the only way to exercise that code path), outside the sandbox —
  # remove them here so nothing leaks.
  if [ -n "${TMP_WT_ROOT:-}" ] && [ -d "$TMP_WT_ROOT" ]; then
    rm -rf "$TMP_WT_ROOT"
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

# add_worktree_ignoring <repo> <wt> <branch> <gitignore-line...> — a linked
# worktree that commits a .gitignore then materializes the ignored entries. The
# tree stays porcelain-clean (ignored files never show in `git status`), which is
# exactly the Layer-2 shape: clean working tree + build artifacts / secrets in
# gitignored paths.
add_worktree_ignoring() {
  local repo="$1" wt="$2" branch="$3"; shift 3
  ( cd "$repo" && git worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 )
  printf '%s\n' "$@" > "$wt/.gitignore"
  ( cd "$wt" && git add .gitignore \
      && GIT_AUTHOR_DATE="$OLD_COMMIT_DATE" GIT_COMMITTER_DATE="$OLD_COMMIT_DATE" \
         git commit -q -m "gitignore" )
}

# write_config_dj <disk_janitor-json> — fixture config carrying a custom
# disk_janitor object (e.g. '{ "reap_pushed_worktrees": false }').
write_config_dj() {
  local dj="$1"
  cat > "$CFG" <<EOF
{
  "trellis_root": "$CANON",
  "projects_root": "$PROJECTS",
  "user_home": "$SANDBOX",
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"],
  "disk_janitor": $dj
}
EOF
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

# ===========================================================================
# LAYER 2 — recoverable = merged OR pushed (the flood reclaimer)
# ===========================================================================

@test "recoverable via PUSHED (unmerged but on origin) -> REAPED, even though age is dropped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  # Unmerged PR, but the branch is pushed to origin: recoverable -> reapable NOW.

  # Positive control: the report puts this pushed tree in the delete plan.
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[delete]"*"$wt"* ]]
  [[ "$output" == *"pushed"* ]]
  [[ "$output" == *"recoverable"* ]]

  [ -d "$wt" ]
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "recoverable via MERGED override -> REAPED (merged arm of merged-OR-pushed)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  [ -d "$wt" ]
  DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "local-only unmerged (neither merged nor pushed) -> candidate (not recoverable), NOT reaped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate (not recoverable)"* ]]

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Not recoverable -> reported candidate, EXCLUDED from apply -> survives.
  [ -d "$wt" ]
}

# ===========================================================================
# LAYER 2 — cleanliness gate is plain porcelain (allowlist no longer blocks)
# ===========================================================================

@test "porcelain-dirty (untracked source) -> skip, regardless of recoverable" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  # Real un-committed work: a TRACKABLE (non-ignored) untracked source file.
  printf 'precious un-committed work\n' > "$wt/NEWFEATURE.ts"

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[skip]"*"$wt"* ]]
  [[ "$output" == *"dirty (uncommitted work)"* ]]

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Porcelain-dirty ALWAYS wins over recoverable -> the WIP survives.
  [ -d "$wt" ]
  [ -f "$wt/NEWFEATURE.ts" ]
}

@test "porcelain-clean + only build artifacts ignored (node_modules/.next) -> REAPED" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree_ignoring "$PROJECTS/alpha" "$wt" "feat/x" "node_modules/" ".next/"
  mkdir -p "$wt/node_modules/pkg" "$wt/.next/cache"
  printf 'x\n' > "$wt/node_modules/pkg/i.js"
  printf 'x\n' > "$wt/.next/cache/x"

  [ -d "$wt" ]
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "porcelain-clean + an UNLISTED non-secret ignored file (.vercel) -> REAPED (old allowlist would have blocked)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  # .vercel is NOT on the old dj_worktree_clean allowlist and is NOT a secret.
  # Under the old predicate it over-refused (left the tree); Layer 2 reaps it.
  add_worktree_ignoring "$PROJECTS/alpha" "$wt" "feat/x" ".vercel/"
  mkdir -p "$wt/.vercel"
  printf '{}\n' > "$wt/.vercel/project.json"

  [ -d "$wt" ]
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "porcelain-clean + a gitignored .env secret -> candidate (manual), NOT reaped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree_ignoring "$PROJECTS/alpha" "$wt" "feat/x" ".env" "node_modules/"
  printf 'API_KEY=shhh\n' > "$wt/.env"
  mkdir -p "$wt/node_modules"; printf 'x\n' > "$wt/node_modules/x"

  # Recoverable + porcelain-clean, BUT the gitignored secret downgrades it.
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate"* ]]
  [[ "$output" == *"secret ignored file present"* ]]

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Secret denylist -> manual candidate, EXCLUDED from apply -> the .env survives.
  [ -d "$wt" ]
  [ -f "$wt/.env" ]
}

# ===========================================================================
# LAYER 2 — /private/tmp ephemerality (short TTL, no upstream needed)
#
# These MUST create fixtures under the real /private/tmp (the only way to hit
# that branch); guarded by [ -d /private/tmp ] and cleaned in teardown via
# TMP_WT_ROOT. The dj_reap_worktree root guard permits the ephemeral tmp root
# (in addition to PROJECTS_ROOT), so a /private/tmp delete verdict is actually
# reaped by --apply — asserted at both the REPORT and APPLY levels below.
# ===========================================================================

@test "/private/tmp clean tree, stale + no upstream + not-detached -> delete verdict" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  # Backdated init commit -> HEAD is far past -> stale at the 2d ephemeral TTL.
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )

  # Not recoverable (unmerged + unpushed), clean, /private/tmp, stale, branch set.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[delete]"*"$wt"* ]]
  [[ "$output" == *"ephemeral-tmp"* ]]
}

@test "/private/tmp clean stale tree is actually REAPED by --apply (root guard permits tmp)" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )

  [ -d "$wt" ]
  # Widened dj_reap_worktree root guard must let --apply remove a tmp worktree
  # (exit 0), NOT the old "outside PROJECTS_ROOT" refusal that set EXIT_STATUS=1.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "/private/tmp stale tree with a gitignored SECRET -> candidate, NOT reaped (ephemeral path honors secret denylist)" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  # Gitignore .env (tree stays porcelain-clean), backdated commit so HEAD is stale.
  printf '.env\n' > "$wt/.gitignore"
  ( cd "$wt" && git add .gitignore \
      && GIT_AUTHOR_DATE="$OLD_COMMIT_DATE" GIT_COMMITTER_DATE="$OLD_COMMIT_DATE" git commit -q -m "gitignore" )
  printf 'SECRET=1\n' > "$wt/.env"

  # Not recoverable + clean + /private/tmp + stale would be an ephemeral delete,
  # but the gitignored secret must force candidate (never auto-reaped).
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"[delete]"*"$wt"* ]]
  [[ "$output" == *"$wt"*"secret ignored file present"* ]]
}

@test "/private/tmp clean tree that is YOUNGER than the TTL -> candidate, NOT delete" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  # Fresh commit (current date) -> HEAD is recent -> NOT stale at the 2d TTL.
  ( cd "$wt" && git commit --allow-empty -q -m "fresh" )

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"[delete]"*"$wt"* ]]
  [[ "$output" == *"candidate (not recoverable)"*"$wt"* || "$output" == *"$wt"*"candidate (not recoverable)"* ]]
}

@test "/private/tmp clean tree that is DETACHED -> candidate, NOT delete (no branch ref)" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  # Detached HEAD at the backdated init commit -> stale but branchless.
  ( cd "$PROJECTS/alpha" && git worktree add -q --detach "$wt" HEAD >/dev/null 2>&1 )

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"[delete]"*"$wt"* ]]
  [[ "$output" == *"candidate"* ]]
}

# ===========================================================================
# LAYER 2 — clean opt-out: reap_pushed_worktrees=false restores legacy gates
# ===========================================================================

@test "reap_pushed_worktrees=false: a pushed-unmerged tree is NOT reaped (legacy merged-only)" {
  write_config_dj '{ "reap_pushed_worktrees": false }'
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # Under the legacy predicate, PUSHED is irrelevant — only merged counts, and
  # this branch is unmerged, so the 4-gate triad fails.
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
}

@test "reap_pushed_worktrees=false: a merged+stale+clean tree IS reaped (legacy behavior intact)" {
  write_config_dj '{ "reap_pushed_worktrees": false }'
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  [ -d "$wt" ]
  DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "reap_pushed_worktrees=false: an UNVERIFIED-merge tree is a legacy candidate, NOT reaped" {
  # Covers the fallback path's unverified arm (unverified merge -> candidate).
  write_config_dj '{ "reap_pushed_worktrees": false }'
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  DJ_MERGED_OVERRIDE=unverified run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate (unverified merge)"* ]]

  DJ_MERGED_OVERRIDE=unverified run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
}

# ===========================================================================
# ENABLED SWITCH — enabled=false must hard-block --apply
#
# Regression guard: jq's `//` coalesces an explicit `false` like `null`, so the
# old `.disk_janitor.enabled // true` read false back as true and did NOT block
# apply. cfg_bool honors the explicit false. (Booleans MUST NOT use `// DEFAULT`.)
# ===========================================================================

@test "disk_janitor.enabled=false hard-blocks --apply (exit 2), honoring an explicit false" {
  write_config_dj '{ "enabled": false }'
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  run_dj --apply --yes --scopes caches </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"enabled is false"* ]]
  # The stale cache is untouched — apply never ran.
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "disk_janitor.enabled=false still permits --report (inspection stays open)" {
  write_config_dj '{ "enabled": false }'
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled=false"* ]]
}

# ===========================================================================
# --safe-only — the unattended nightly restriction (merged-only)
#
# The nightly apply LaunchAgent runs `--apply --scopes worktrees --yes
# --safe-only`. --safe-only must keep an auto-reap ONLY for a merged, clean,
# non-detached tree — never a pushed-but-unmerged one, because that tree is
# exactly what an in-flight fan-out unit is working in (it pushed to open its
# PR, then keeps running). The discriminating pair below proves the flag is
# load-bearing: the SAME pushed-unmerged tree is reaped WITHOUT the flag and
# survives WITH it.
# ===========================================================================

@test "safe-only REAPS a merged + clean tree (the intended nightly target)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  [ -d "$wt" ]
  DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --safe-only --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # merged + clean + non-detached -> survives the safe-only tightening -> reaped.
  [ ! -d "$wt" ]
}

@test "safe-only PROTECTS a pushed-but-unmerged clean tree (concurrency guard)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # Recoverable via push (not merged). Under --safe-only it must be DOWNGRADED
  # to a manual candidate and left in place — an in-flight fan-out tree.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --apply --yes --safe-only --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
}

@test "WITHOUT safe-only the same pushed-unmerged tree IS reaped (flag is load-bearing)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # Identical setup, no --safe-only: recoverable(pushed) + clean -> delete -> reaped.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "safe-only report labels a pushed-unmerged tree 'candidate (safe-only: not merged)'" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --report --safe-only --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"safe-only: not merged"* ]]
  # And the banner advertises the restriction.
  [[ "$output" == *"safe-only: merged-clean worktrees only"* ]]
}

@test "safe-only still skips a DIRTY tree (porcelain gate wins before any downgrade)" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  echo "wip" > "$wt/uncommitted.txt"   # real uncommitted work

  DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --safe-only --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Dirty -> skip regardless of merged/safe-only. Work preserved.
  [ -d "$wt" ]
  [ -f "$wt/uncommitted.txt" ]
}
