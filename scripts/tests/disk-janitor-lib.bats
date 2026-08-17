#!/usr/bin/env bats
# Unit tests for scripts/lib/disk-janitor-lib.sh — the pure scanners,
# injectable predicates, and registry-owned deletion primitives. Scanner math,
# cache discovery, worktree parsing, clean-tree checks, and turbo-output
# predicates stay unit-level here; the orchestration-level --apply safety
# matrix lives in disk-janitor-apply.bats.
#
# HERMETIC: scanner inputs and registry fixtures live under a fresh `mktemp -d`.
# The ownership tests use a private TRELLIS_HOME, never the operator's machine
# state.
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
  TRELLIS_HOME="$SANDBOX/.trellis"
  mkdir -p "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  # Source the lib into THIS shell so we can call its functions directly.
  # shellcheck disable=SC1090
  . "$LIB"
}

teardown() {
  if [ -n "${HOLDER_PID:-}" ]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  if [ -n "${BIND_MOUNT:-}" ] && [ -d "$BIND_MOUNT" ]; then
    umount "$BIND_MOUNT" 2>/dev/null || umount -l "$BIND_MOUNT" 2>/dev/null || true
  fi
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

register_fixture_root() {
  local root="$1" project_id="${2:-fixture}"
  local_registry_register_worktree "$TRELLIS_HOME" personal "$project_id" \
    "$root" 1.2.3 '["claude"]' "" >/dev/null
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
  [[ "$output" == *"GB"* ]] || { echo "$output"; false; }
  [[ "$output" == 12.* ]] || { echo "$output"; false; }
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
  [[ "$output" =~ ^[0-9]+$ ]] || { echo "$output"; false; }
  [ "$output" -gt 0 ]
}

# Install a `stat` that behaves like GNU coreutils: `-f` is --file-system and
# takes NO format argument, so it reports on every operand — printing a
# filesystem block for the real path on STDOUT — and exits non-zero because the
# format string is not a file. This is the dialect the chained
# `stat -f … || stat -c …` idiom silently corrupted.
#
# The real Linux binary is not available on the macOS dev host this suite runs
# on, so the GNU dialect itself is established here BY INSPECTION; the shim
# reproduces the exact observable shape (stdout block + non-zero exit) that the
# inspection identified, and the assertions below run against it for real.
#
# T27's ubuntu:24.04 container run covered the doctor/attach contracts lane,
# which is where the same chained-`stat` defect was confirmed against the real
# GNU binary. That confirmation is what this shim models.
#
# The shim delegates its `-c` branch to the real BSD `/usr/bin/stat -f`, so the
# case below is a Darwin-host simulation by construction and cannot run on Linux
# — it is skipped there rather than excluding the whole suite from CI, which
# since T34 runs every suite under scripts/tests/.
install_gnu_stat_shim() {
  GNU_BIN="$SANDBOX/gnu-bin"
  mkdir -p "$GNU_BIN"
  cat > "$GNU_BIN/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-f" ]; then
  shift
  printf 'stat: cannot read file system information for %s\n' "${1:-}" >&2
  shift
  for operand in "$@"; do
    printf '  File: "%s"\n' "$operand"
    printf '    ID: 0 Namelen: 255 Type: apfs\n'
  done
  exit 1
fi
if [ "$1" = "-c" ]; then
  case "$2" in
    %Y) exec /usr/bin/stat -f %m "$3" ;;
    %a) exec /usr/bin/stat -f %Lp "$3" ;;
    '%d:%i') exec /usr/bin/stat -f '%d:%i' "$3" ;;
  esac
fi
exit 2
SH
  chmod 755 "$GNU_BIN/stat"
}

@test "stat-dialect helpers stay single-valued under the GNU dialect (-f is --file-system)" {
  [ "$(uname -s)" = Darwin ] || skip "the GNU shim delegates to BSD /usr/bin/stat -f"
  install_gnu_stat_shim
  printf 'x\n' > "$SANDBOX/f"
  mkdir -p "$SANDBOX/dir"
  local real_mtime real_ident
  real_mtime="$(/usr/bin/stat -f %m "$SANDBOX/f")"
  real_ident="$(/usr/bin/stat -f '%d:%i' "$SANDBOX/dir")"

  # The shim really is GNU-shaped: the OLD chained idiom emits the filesystem
  # block AND the epoch, so it hands its caller multi-line garbage at exit 0.
  run env PATH="$GNU_BIN:$PATH" bash -c \
    'stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0' _ "$SANDBOX/f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 1 ] || { echo "$output"; false; }
  [ "$output" != "$real_mtime" ]

  # dj_mtime captures the dialects separately and shape-checks the BSD probe.
  run env PATH="$GNU_BIN:$PATH" bash -c '. "$1"; dj_mtime "$2"' _ "$LIB" "$SANDBOX/f"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${#lines[@]}" -eq 1 ] || { echo "$output"; false; }
  [ "$output" = "$real_mtime" ] || { echo "$output"; false; }

  # And so does dj_stat_device_inode — which previously refused every real
  # directory on the GNU dialect because the block failed its shape check.
  run env PATH="$GNU_BIN:$PATH" bash -c '. "$1"; dj_stat_device_inode "$2"' _ "$LIB" "$SANDBOX/dir"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${#lines[@]}" -eq 1 ] || { echo "$output"; false; }
  [ "$output" = "$real_ident" ] || { echo "$output"; false; }

  # A missing path still fails closed rather than emitting a partial identity.
  run env PATH="$GNU_BIN:$PATH" bash -c '. "$1"; dj_stat_device_inode "$2"' _ "$LIB" "$SANDBOX/nope"
  [ "$status" -ne 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
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
  [[ "$output" == *"turbo-cache"$'\t'* ]] || { echo "$output"; false; }
  [[ "$output" == *"next-cache"$'\t'* ]] || { echo "$output"; false; }
  [[ "$output" == *"next-dev"$'\t'* ]] || { echo "$output"; false; }
  # The nested apps/*/.next/cache is found too.
  [[ "$output" == *"$proj/apps/web/.next/cache"* ]] || { echo "$output"; false; }
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
  [[ "$output" != *"node_modules"* ]] || { echo "$output"; false; }
}

@test "dj_find_caches returns nothing for a project with no cache dirs" {
  local proj="$SANDBOX/empty"
  mkdir -p "$proj/src"
  run dj_find_caches "$proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dj_find_caches skips a Linux bind-mounted cache outside the registered root" {
  [ "$(uname -s)" = "Linux" ] || skip "bind mounts are Linux-specific"
  command -v mount >/dev/null 2>&1 || skip "mount command unavailable"
  local proj="$SANDBOX/project" external="$SANDBOX/external-cache"
  local cache="$proj/.next/cache"
  mkdir -p "$cache" "$external"
  printf 'keep\n' > "$external/keep"
  if ! mount --bind "$external" "$cache" 2>/dev/null; then
    skip "bind mounts are unavailable in this test environment"
  fi
  BIND_MOUNT="$cache"

  run dj_find_caches "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$cache"* ]] || { echo "$output"; false; }
  [ -f "$external/keep" ]
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

@test "dj_worktree_clean: every gitignored entry blocks, including build artifacts" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  printf '.env\nnode_modules/\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  # The tracked .gitignore is committed, so the tree starts content-clean.
  run dj_worktree_clean "$repo"
  [ "$status" -eq 0 ]
  # A gitignored secret would be destroyed by `git worktree remove` — refuse.
  printf 'API_KEY=shhh\n' > "$repo/.env"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
  rm -f "$repo/.env"
  # A build artifact can carry operator state too; no basename allowlist is
  # sufficient proof that it is recoverable, so it also blocks auto-reap.
  mkdir -p "$repo/node_modules/pkg"
  printf 'x\n' > "$repo/node_modules/pkg/index.js"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
}

@test "dj_worktree_clean: an unknown gitignored path blocks even with a harmless name" {
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  # .vercel is neither a conventional secret basename nor proof of
  # recoverability; auto-reap must preserve it for explicit operator review.
  printf '.vercel/\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  mkdir -p "$repo/.vercel"
  printf '{}\n' > "$repo/.vercel/project.json"
  run dj_worktree_clean "$repo"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# dj_worktree_porcelain_clean — tracked/untracked distinction
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
  # Porcelain intentionally does not inspect ignored paths. The caller uses
  # this only to distinguish untracked work from ignored local content, then
  # runs dj_worktree_clean before any automatic reap.
  printf 'node_modules/\n.env\n' > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -q -m "gitignore" )
  mkdir -p "$repo/node_modules/pkg"
  printf 'x\n' > "$repo/node_modules/pkg/index.js"
  printf 'API_KEY=shhh\n' > "$repo/.env"
  run dj_worktree_porcelain_clean "$repo"
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
  [[ "$output" =~ ^[0-9]+$ ]] || { echo "$output"; false; }
  # Far older than a recent epoch (2023-01-01 = 1672531200).
  [ "$output" -lt 1672531200 ]
}

# ===========================================================================
# dj_worktree_in_use — one lsof snapshot catches cwd + open-handle liveness
# ===========================================================================

@test "dj_worktree_in_use detects an open file below the tree even when process cwd is elsewhere" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  local repo="$SANDBOX/repo"
  git_init_at "$repo"
  local held="$repo/held-open.txt" snapshot="$SANDBOX/lsof.snapshot"
  printf 'held\n' > "$held"

  # Keep fd 9 open on a file under the tree while sleep itself stays cwd'd in the
  # bats runner directory. This isolates the open-handle arm from the cwd arm.
  ( exec 9<"$held"; exec sleep 30 ) >/dev/null 2>&1 &
  HOLDER_PID=$!

  local tries=0
  while [ "$tries" -lt 50 ]; do
    lsof -- "$held" >/dev/null 2>&1 && break
    sleep 0.05
    tries=$((tries + 1))
  done
  lsof -- "$held" >/dev/null 2>&1

  run dj_capture_lsof_snapshot "$snapshot" 5
  [ "$status" -eq 0 ]
  run dj_worktree_in_use "$repo" "$snapshot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"live process cwd or open file handle under worktree"* ]] || { echo "$output"; false; }

  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=""
  run dj_capture_lsof_snapshot "$snapshot" 5
  [ "$status" -eq 0 ]
  run dj_worktree_in_use "$repo" "$snapshot"
  [ "$status" -ne 0 ]
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
  [[ "$output" == *"!.next/cache/**"* ]] || { echo "$output"; false; }
  [[ "$output" == *"!.next/dev/**"* ]] || { echo "$output"; false; }
}

@test "dj_prune_cache_entry uses exact registered ownership across a path with spaces" {
  local root="$SANDBOX/external volume/project with spaces" cache sibling identity
  local checkout_id worktree_id common
  git_init_at "$root"
  register_fixture_root "$root" external-project
  identity="$(local_registry_identity_for_root "$root")"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  cache="$root/.next/cache"
  mkdir -p "$cache"
  printf 'cache\n' > "$cache/blob"

  run dj_prune_cache_entry "$TRELLIS_HOME" personal external-project "$checkout_id" \
    "$worktree_id" "$common" "$root" "$cache"
  [ "$status" -eq 0 ]
  [ ! -d "$cache" ]

  sibling="$SANDBOX/sibling/.next/cache"
  mkdir -p "$sibling"
  printf 'keep\n' > "$sibling/blob"
  run dj_prune_cache_entry "$TRELLIS_HOME" personal external-project "$checkout_id" \
    "$worktree_id" "$common" "$root" "$sibling"
  [ "$status" -ne 0 ]
  [ -d "$sibling" ]
  mkdir -p "$root/.next"
  ln -s "$sibling" "$cache"
  run dj_prune_cache_entry "$TRELLIS_HOME" personal external-project "$checkout_id" \
    "$worktree_id" "$common" "$root" "$cache"
  [ "$status" -ne 0 ]
  [ -d "$sibling" ]
}

@test "dj_remove_cache_tree_safely refuses an intermediate symlink and preserves its target" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  local root="$SANDBOX/root" victim="$SANDBOX/victim"
  local cache="$root/apps/web/.next/cache"
  mkdir -p "$root/apps" "$victim/.next/cache"
  printf 'keep\n' > "$victim/.next/cache/keep"
  ln -s "$victim" "$root/apps/web"

  run dj_remove_cache_tree_safely "$root" "$cache"
  [ "$status" -ne 0 ]
  [ -d "$victim/.next/cache" ]
  [ -f "$victim/.next/cache/keep" ]
}

@test "dj_remove_cache_tree_safely refuses a Linux bind-mounted cache and preserves its source" {
  [ "$(uname -s)" = "Linux" ] || skip "bind mounts are Linux-specific"
  command -v mount >/dev/null 2>&1 || skip "mount command unavailable"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  local root="$SANDBOX/root" external="$SANDBOX/external-cache"
  local cache="$root/.next/cache"
  mkdir -p "$cache" "$external"
  printf 'keep\n' > "$external/keep"
  if ! mount --bind "$external" "$cache" 2>/dev/null; then
    skip "bind mounts are unavailable in this test environment"
  fi
  BIND_MOUNT="$cache"

  run dj_remove_cache_tree_safely "$root" "$cache"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mount boundary"* ]] || { echo "$output"; false; }
  [ -f "$external/keep" ]
}

@test "dj_reap_worktree removes only a registered linked worktree, never its main checkout" {
  local root="$SANDBOX/checkout" linked="$SANDBOX/outside volume/linked worktree"
  local identity checkout_id worktree_id common
  git_init_at "$root"
  register_fixture_root "$root" fixture
  mkdir -p "$(dirname "$linked")"
  ( cd "$root" && git worktree add -q -b feat/x "$linked" >/dev/null 2>&1 )
  register_fixture_root "$linked" fixture
  identity="$(local_registry_identity_for_root "$linked")"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"

  run dj_reap_worktree "$TRELLIS_HOME" personal fixture "$checkout_id" "$worktree_id" \
    "$common" "$linked"
  [ "$status" -eq 0 ]
  [ ! -d "$linked" ]
  [ -d "$root" ]
}

@test "dj_reap_worktree refuses ignored local content at the destructive sink" {
  local root="$SANDBOX/checkout" linked="$SANDBOX/linked"
  local identity checkout_id worktree_id common
  git_init_at "$root"
  register_fixture_root "$root" fixture
  ( cd "$root" && git worktree add -q -b feat/x "$linked" >/dev/null 2>&1 )
  register_fixture_root "$linked" fixture
  printf '.env\n' > "$linked/.gitignore"
  ( cd "$linked" && git add .gitignore && git commit -q -m "ignore local state" )
  printf 'TOKEN=secret\n' > "$linked/.env"
  identity="$(local_registry_identity_for_root "$linked")"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"

  run dj_reap_worktree "$TRELLIS_HOME" personal fixture "$checkout_id" "$worktree_id" \
    "$common" "$linked"
  [ "$status" -ne 0 ]
  [ -d "$linked" ]
  [ -f "$linked/.env" ]
}
