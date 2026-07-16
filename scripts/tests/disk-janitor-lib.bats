#!/usr/bin/env bats
# Unit tests for scripts/lib/disk-janitor-lib.sh — the pure scanners + the two
# injectable predicates. NO deletion happens here (those are the safety suite,
# disk-janitor-apply.bats); this file exercises the size/format math, the cache
# finder TSV, the staleness boundary, the worktree porcelain parser, the
# clean-tree predicate, and the turbo-outputs jq predicate.
#
# HERMETIC: the lib functions take EXPLICIT path arguments, so every fixture
# lives under a fresh `mktemp -d` in $BATS_TMPDIR. Nothing here resolves a
# config or reaches ~/projects. We still export PROJECTS_ROOT pointing at the
# sandbox so any guard that reads it (the OWNED funcs are NOT called here) can
# only ever see the sandbox.
#
# Path note: the lib is located relative to this test file ($BATS_TEST_DIRNAME
# is scripts/tests/, so ../.. is the repo/worktree root) — never a hardcoded
# absolute path, which would leak into the public mirror.
#
# bash 3.2 / bats 1.x. `[[ ]]` is fine in bats (not shellcheck-gated like .sh).

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
LIB="$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through the real path so /var vs /private/var cannot diverge between
  # what we create and what dj__abspath canonicalizes.
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export PROJECTS_ROOT="$SANDBOX"
  # Source the lib into THIS shell so we can call its functions directly.
  # shellcheck disable=SC1090
  . "$LIB"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# git_init_at <dir> [iso-date] — init a repo with one backdated commit so
# git-derived mtimes are deterministic. Date defaults to a far-past fixed value.
git_init_at() {
  local dir="$1" when="${2:-2020-01-01T00:00:00}"
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

# ===========================================================================
# size + format
# ===========================================================================

@test "dj_human_bytes renders B / KB / MB / GB / TB with one decimal" {
  [ "$(dj_human_bytes 0)" = "0 B" ]
  [ "$(dj_human_bytes 512)" = "512 B" ]
  # 1536 = 1.5 KiB
  [ "$(dj_human_bytes 1536)" = "1.5 KB" ]
  # 12.6 GB ≈ 13529146982 (12.6 * 1024^3)
  run dj_human_bytes 13529146982
  [ "$status" -eq 0 ]
  [[ "$output" == *"GB"* ]]
  [[ "$output" == 12.* ]]
  # 1 TiB exactly
  [ "$(dj_human_bytes 1099511627776)" = "1.0 TB" ]
}

@test "dj_human_bytes treats non-numeric / empty input as 0 B" {
  [ "$(dj_human_bytes '')" = "0 B" ]
  [ "$(dj_human_bytes 'abc')" = "0 B" ]
}

@test "dj_dir_bytes returns 0 for a missing path and a positive count for a real dir" {
  [ "$(dj_dir_bytes "$SANDBOX/does-not-exist")" = "0" ]
  mkdir -p "$SANDBOX/d"
  # Write ~8 KiB so du reports at least one block on every fs.
  dd if=/dev/zero of="$SANDBOX/d/blob" bs=1024 count=8 >/dev/null 2>&1
  run dj_dir_bytes "$SANDBOX/d"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "dj_mtime echoes 0 for a missing path and a numeric epoch for a real file" {
  [ "$(dj_mtime "$SANDBOX/nope")" = "0" ]
  printf 'x\n' > "$SANDBOX/f"
  run dj_mtime "$SANDBOX/f"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

# ===========================================================================
# dj_find_caches — TSV on a fixture tree
# ===========================================================================

@test "dj_find_caches emits one TSV row per known cache dir, with the right kind" {
  local proj="$SANDBOX/proj"
  mkdir -p "$proj/.turbo/cache" \
           "$proj/.next/cache" \
           "$proj/.next/dev" \
           "$proj/apps/web/.next/cache"
  # Put content in each so dj_dir_bytes is non-zero (proves the column carries).
  printf 'a\n' > "$proj/.turbo/cache/x"
  printf 'b\n' > "$proj/.next/cache/x"
  printf 'c\n' > "$proj/.next/dev/x"
  printf 'd\n' > "$proj/apps/web/.next/cache/x"

  run dj_find_caches "$proj"
  [ "$status" -eq 0 ]
  # One row per cache dir (4 total).
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 4 ]
  # Each kind classification is present.
  [[ "$output" == *"turbo-cache"$'\t'* ]]
  [[ "$output" == *"next-cache"$'\t'* ]]
  [[ "$output" == *"next-dev"$'\t'* ]]
  # The nested apps/*/.next/cache is found too.
  [[ "$output" == *"$proj/apps/web/.next/cache"* ]]
}

@test "dj_find_caches does NOT descend into node_modules (prunes other tools' trees)" {
  local proj="$SANDBOX/proj"
  mkdir -p "$proj/node_modules/.next/cache" \
           "$proj/node_modules/some-dep/.turbo/cache"
  printf 'x\n' > "$proj/node_modules/.next/cache/x"
  printf 'y\n' > "$proj/node_modules/some-dep/.turbo/cache/y"

  run dj_find_caches "$proj"
  [ "$status" -eq 0 ]
  # node_modules is pruned: no cache rows from inside it.
  [[ "$output" != *"node_modules"* ]]
}

@test "dj_find_caches returns nothing for a project with no cache dirs" {
  local proj="$SANDBOX/empty"
  mkdir -p "$proj/src"
  run dj_find_caches "$proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# dj_cache_is_stale — boundary
# ===========================================================================

@test "dj_cache_is_stale: age strictly greater than ttl*86400 is stale; equal/younger is fresh" {
  # ttl = 1 day = 86400 s. now = 1_000_000.
  local now=1000000 ttl=1
  # mtime exactly ttl old -> age == 86400 -> NOT > threshold -> fresh (return 1)
  run dj_cache_is_stale $((now - 86400)) "$ttl" "$now"
  [ "$status" -ne 0 ]
  # mtime one second older than ttl -> age == 86401 -> stale (return 0)
  run dj_cache_is_stale $((now - 86401)) "$ttl" "$now"
  [ "$status" -eq 0 ]
  # mtime newer than now -> negative age -> fresh
  run dj_cache_is_stale $((now + 10)) "$ttl" "$now"
  [ "$status" -ne 0 ]
}

@test "dj_cache_is_stale: a 0 / non-numeric mtime reads as very stale (safe direction)" {
  # now is a realistic epoch (~2023) so a 0/garbage mtime is decades old, well
  # past the 14d threshold (1209600s). A tiny 'now' would make epoch-0 look fresh.
  run dj_cache_is_stale 0 14 1700000000
  [ "$status" -eq 0 ]
  run dj_cache_is_stale "garbage" 14 1700000000
  [ "$status" -eq 0 ]
}

# ===========================================================================
# dj_list_worktrees — parse a real `git worktree add`
# ===========================================================================

@test "dj_list_worktrees parses main + linked worktree into TSV with is_main flags" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  local wt="$SANDBOX/wt-feature"
  ( cd "$repo" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )

  run dj_list_worktrees "$repo"
  [ "$status" -eq 0 ]
  # Two rows: main + linked.
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  # Main checkout row: is_main column (col 4) == 1.
  local main_row
  main_row="$(printf '%s\n' "$output" | awk -F'\t' -v r="$repo" '$1==r')"
  [ -n "$main_row" ]
  [ "$(printf '%s' "$main_row" | awk -F'\t' '{print $4}')" = "1" ]
  # Linked worktree row: is_main == 0, branch == feat/x.
  local wt_real wt_row
  wt_real="$( cd "$wt" && pwd -P )"
  wt_row="$(printf '%s\n' "$output" | awk -F'\t' -v p="$wt_real" '$1==p')"
  [ -n "$wt_row" ]
  [ "$(printf '%s' "$wt_row" | awk -F'\t' '{print $4}')" = "0" ]
  [ "$(printf '%s' "$wt_row" | awk -F'\t' '{print $3}')" = "feat/x" ]
}

@test "dj_list_worktrees returns nothing for a non-git directory" {
  mkdir -p "$SANDBOX/plain"
  run dj_list_worktrees "$SANDBOX/plain"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# dj_worktree_clean — clean vs untracked vs dirty
# ===========================================================================

@test "dj_worktree_clean: clean tree -> 0; untracked file -> non-zero; dirty tracked file -> non-zero" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  # Clean immediately after the seed commit.
  run dj_worktree_clean "$repo"
  [ "$status" -eq 0 ]
  # Untracked WIP is NOT clean (we never pass -uno — untracked is exactly what
  # must not be silently destroyed).
  printf 'wip\n' > "$repo/untracked.txt"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
  rm -f "$repo/untracked.txt"
  run dj_worktree_clean "$repo"
  [ "$status" -eq 0 ]
  # Modified tracked file is also not clean.
  printf 'changed\n' >> "$repo/seed.txt"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
}

@test "dj_worktree_clean: a sensitive gitignored file (.env) blocks; a recoverable artifact (node_modules) does not" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  printf '.env\nnode_modules/\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  # Tree is clean (only the tracked .gitignore changed, now committed).
  run dj_worktree_clean "$repo"
  [ "$status" -eq 0 ]
  # A gitignored secret would be silently destroyed by `git worktree remove` and
  # is NOT recoverable from git — refuse.
  printf 'API_KEY=shhh\n' > "$repo/.env"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
  rm -f "$repo/.env"
  # A gitignored build artifact IS recoverable (reinstall) — it must NOT block,
  # or no real dev worktree could ever be reaped.
  mkdir -p "$repo/node_modules/pkg"
  printf 'x\n' > "$repo/node_modules/pkg/index.js"
  run dj_worktree_clean "$repo"
  [ "$status" -eq 0 ]
}

@test "dj_worktree_clean: allowlist fails closed — an unlisted ignored secret (.npmrc) blocks even though no denylist names it" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  # .npmrc carries npm auth tokens and is gitignored in most JS monorepos. The
  # old denylist never named it, so it would have been silently destroyed; the
  # allowlist refuses any entry it doesn't recognise as recoverable.
  printf '.npmrc\nnode_modules/\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  printf '//registry.npmjs.org/:_authToken=secret\n' > "$repo/.npmrc"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
  # A nested recoverable artifact (apps/web/.next/) is still recognised by
  # basename. Seed tracked source under apps/web/ so git reports the specific
  # "apps/web/.next/" rather than collapsing the whole tree to "apps/" (it only
  # collapses a parent that is ENTIRELY ignored — a real package dir is not).
  rm -f "$repo/.npmrc"
  printf 'apps/web/.next/\n' >> "$repo/.gitignore"
  mkdir -p "$repo/apps/web"
  printf '{}\n' > "$repo/apps/web/package.json"
  ( cd "$repo" && git add -A && git commit -q -m "ignore nested next" )
  mkdir -p "$repo/apps/web/.next/cache"
  printf 'x\n' > "$repo/apps/web/.next/cache/x"
  run dj_worktree_clean "$repo"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# dj_worktree_porcelain_clean — the Layer-2 cleanliness gate (no allowlist)
# ===========================================================================

@test "dj_worktree_porcelain_clean: clean -> 0; untracked -> non-zero; gitignored-only -> 0" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  # Clean immediately after the seed commit.
  run dj_worktree_porcelain_clean "$repo"
  [ "$status" -eq 0 ]
  # Untracked WIP is NOT porcelain-clean (no -uno).
  printf 'wip\n' > "$repo/untracked.txt"
  run dj_worktree_porcelain_clean "$repo"
  [ "$status" -ne 0 ]
  rm -f "$repo/untracked.txt"
  # Unlike dj_worktree_clean's allowlist, porcelain NEVER inspects gitignored
  # files: a tree carrying only a gitignored node_modules AND a gitignored .env
  # is still porcelain-clean. (This is exactly why the secret denylist is a
  # SEPARATE gate — porcelain alone would let the .env through.)
  printf 'node_modules/\n.env\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  mkdir -p "$repo/node_modules/pkg"
  printf 'x\n' > "$repo/node_modules/pkg/index.js"
  printf 'API_KEY=shhh\n' > "$repo/.env"
  run dj_worktree_porcelain_clean "$repo"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# dj_worktree_has_secret_ignored — minimal fail-closed secret denylist
# ===========================================================================

@test "dj_worktree_has_secret_ignored: .env / .env.* / .npmrc / *.pem match; recoverable artifacts do not" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  printf 'node_modules/\n.next/\n.vercel/\n.env\n.env.local\n.npmrc\n*.pem\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  # Only recoverable build artifacts ignored -> NO secret (safe to auto-reap).
  mkdir -p "$repo/node_modules/pkg" "$repo/.next/cache" "$repo/.vercel"
  printf 'x\n' > "$repo/node_modules/pkg/i.js"
  printf 'x\n' > "$repo/.next/cache/x"
  printf 'x\n' > "$repo/.vercel/project.json"
  run dj_worktree_has_secret_ignored "$repo"
  [ "$status" -ne 0 ]
  # A gitignored .env -> secret.
  printf 'S=1\n' > "$repo/.env"
  run dj_worktree_has_secret_ignored "$repo"
  [ "$status" -eq 0 ]
  rm -f "$repo/.env"
  # .env.local matches the .env.* pattern -> secret.
  printf 'S=1\n' > "$repo/.env.local"
  run dj_worktree_has_secret_ignored "$repo"
  [ "$status" -eq 0 ]
  rm -f "$repo/.env.local"
  # .npmrc (npm auth token) -> secret.
  printf '//registry.npmjs.org/:_authToken=secret\n' > "$repo/.npmrc"
  run dj_worktree_has_secret_ignored "$repo"
  [ "$status" -eq 0 ]
  rm -f "$repo/.npmrc"
  # A top-level *.pem (basename match) -> secret.
  printf 'k\n' > "$repo/server.pem"
  run dj_worktree_has_secret_ignored "$repo"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# dj_worktree_pushed — upstream-on-origin recoverability (override + real check)
# ===========================================================================

@test "dj_worktree_pushed honors DJ_PUSHED_OVERRIDE: pushed=0, unpushed=1" {
  DJ_PUSHED_OVERRIDE=pushed   run dj_worktree_pushed "$SANDBOX/wt"
  [ "$status" -eq 0 ]
  DJ_PUSHED_OVERRIDE=unpushed run dj_worktree_pushed "$SANDBOX/wt"
  [ "$status" -eq 1 ]
}

@test "dj_worktree_pushed real check: no upstream -> 1; pushed+not-ahead -> 0; local tip ahead -> 1" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  local wt="$SANDBOX/wt-feature"
  ( cd "$repo" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  # No upstream configured -> unpushed (the fan-out local-only case).
  run dj_worktree_pushed "$wt"
  [ "$status" -ne 0 ]
  # Stand up a bare origin and push feat/x WITH upstream tracking.
  local remote="$SANDBOX/remote.git"
  git init -q --bare "$remote"
  ( cd "$wt" && git remote add origin "$remote" && git push -q -u origin feat/x )
  # @{u} now resolves and the tip is not ahead -> pushed (recoverable).
  run dj_worktree_pushed "$wt"
  [ "$status" -eq 0 ]
  # A new un-pushed commit puts the local tip ahead of @{u} -> unpushed again.
  ( cd "$wt" && git commit --allow-empty -q -m "local ahead" )
  run dj_worktree_pushed "$wt"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# dj_worktree_mtime — last-commit epoch
# ===========================================================================

@test "dj_worktree_mtime returns the HEAD commit epoch (backdated commit -> old epoch)" {
  local repo="$SANDBOX/repo"
  # Backdate to 2020-01-01 UTC -> epoch 1577836800.
  git_init_at "$repo" "2020-01-01T00:00:00 +0000"
  run dj_worktree_mtime "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  # Far older than a recent epoch (2023-01-01 = 1672531200).
  [ "$output" -lt 1672531200 ]
}

# ===========================================================================
# dj_branch_merged — injectable override (the real ladder is network/gh and is
# NOT exercised here; the override IS the contract for tests).
# ===========================================================================

@test "dj_branch_merged honors DJ_MERGED_OVERRIDE: merged=0, unmerged=1, unverified=2" {
  DJ_MERGED_OVERRIDE=merged    run dj_branch_merged "$SANDBOX/repo" feat/x
  [ "$status" -eq 0 ]
  DJ_MERGED_OVERRIDE=unmerged  run dj_branch_merged "$SANDBOX/repo" feat/x
  [ "$status" -eq 1 ]
  DJ_MERGED_OVERRIDE=unverified run dj_branch_merged "$SANDBOX/repo" feat/x
  [ "$status" -eq 2 ]
}

# ===========================================================================
# dj_build_active — injectable override
# ===========================================================================

@test "dj_build_active honors DJ_BUILD_ACTIVE_OVERRIDE: 1=active(0), 0=inactive(1)" {
  DJ_BUILD_ACTIVE_OVERRIDE=1 run dj_build_active "$SANDBOX/proj"
  [ "$status" -eq 0 ]
  DJ_BUILD_ACTIVE_OVERRIDE=0 run dj_build_active "$SANDBOX/proj"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# dj_turbo_outputs_unscoped — unscoped -> 0, scoped -> 1, no-turbo -> 1
# (NOTE the inverted polarity: 0 == problem found.)
# ===========================================================================

@test "dj_turbo_outputs_unscoped: unscoped .next/** glob -> 0 (problem)" {
  local tj="$SANDBOX/turbo.json"
  cat > "$tj" <<'JSON'
{
  "tasks": {
    "build": { "outputs": [".next/**"] }
  }
}
JSON
  run dj_turbo_outputs_unscoped "$tj"
  [ "$status" -eq 0 ]
}

@test "dj_turbo_outputs_unscoped: scoped glob (with !.next/cache/** negation) -> 1 (clean)" {
  local tj="$SANDBOX/turbo.json"
  cat > "$tj" <<'JSON'
{
  "tasks": {
    "build": { "outputs": [".next/**", "!.next/cache/**", "!.next/dev/**"] }
  }
}
JSON
  run dj_turbo_outputs_unscoped "$tj"
  [ "$status" -ne 0 ]
}

@test "dj_turbo_outputs_unscoped: legacy .pipeline schema is inspected too" {
  local tj="$SANDBOX/turbo.json"
  cat > "$tj" <<'JSON'
{
  "pipeline": {
    "build": { "outputs": [".next/**"] }
  }
}
JSON
  run dj_turbo_outputs_unscoped "$tj"
  [ "$status" -eq 0 ]
}

@test "dj_turbo_outputs_unscoped: missing turbo.json -> 1 (no problem)" {
  run dj_turbo_outputs_unscoped "$SANDBOX/no-such-turbo.json"
  [ "$status" -ne 0 ]
}

@test "dj_turbo_fix_hint emits a non-empty fix string mentioning the negations" {
  run dj_turbo_fix_hint
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"!.next/cache/**"* ]]
  [[ "$output" == *"!.next/dev/**"* ]]
}
