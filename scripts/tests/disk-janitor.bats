#!/usr/bin/env bats
# Behavior tests for scripts/disk-janitor.sh — the orchestrator. Covers arg
# parsing (bad flag / bad scope -> exit 2), the read-only invariant of --report
# and --dry-run (fixture bytes IDENTICAL after the run), audit-file emission, and
# exit codes. NO deletion happens in this suite — destructive behavior is the
# job of disk-janitor-apply.bats.
#
# FULLY ISOLATED from the live registry and ~/projects, exactly like doctor.bats:
# every test stands up its own fixture canonical clone + projects_root under a
# fresh `mktemp -d`, writes a fixture trellis.config.json, and exports
# $TRELLIS_CONFIG so config-load.sh resolves the FIXTURE config — never the
# worktree's real one. A buggy test therefore physically cannot reach ~/projects:
# PROJECTS_ROOT is the sandbox.
#
# Paths are resolved relative to this test file ($BATS_TEST_DIRNAME is
# scripts/tests/, so ../.. is the worktree root) — no hardcoded absolute paths
# that would leak into the public mirror.
#
# We pin --scopes to caches/worktrees in every run so the host-global `stores`
# scope (real pnpm/npm probes) never makes a test non-hermetic or slow.
#
# bash 3.2 / bats 1.x. `[[ ]]` is fine in bats (not shellcheck-gated).

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"

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
# Fixture builders
# ---------------------------------------------------------------------------

# Minimal canonical surface: a registry.md listing one active project ("alpha")
# and an empty blacklist. The orchestrator only needs registry/blacklist + the
# audit dir; it does NOT need the full inheritance skill/command tree doctor uses.
# $1 (optional) = newline of extra "| name | `/personal/name` | app | x |" rows.
build_canonical_min() {
  local extra_rows="${1:-}"
  cat > "$CANON/registry.md" <<EOF
# Project registry

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| alpha | \`/personal/alpha\` | app | fixture |
$extra_rows

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

# Reuse doctor.bats' config shape verbatim — config-load enforces the required
# fields + harnesses minItems>=1 + [ -d trellis_root ]; a hand-rolled minimal
# config would make the orchestrator exit before scanning.
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

# git_init_at <dir> [iso-date] — init a repo with one backdated commit.
git_init_at() {
  local dir="$1" when="${2:-2020-01-01T00:00:00 +0000}"
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

# Build project "alpha" as a git checkout with one stale, non-empty cache dir.
build_alpha_with_stale_cache() {
  local proj="$PROJECTS/alpha"
  git_init_at "$proj"
  mkdir -p "$proj/.next/cache"
  # Real content so dj_dir_bytes > 0 (the apply byte-gate needs this; report
  # also reads the size).
  dd if=/dev/zero of="$proj/.next/cache/blob" bs=1024 count=8 >/dev/null 2>&1
  # Backdate the cache DIR mtime so it reads as stale (dir mtime, not commit).
  touch -t 200001010000 "$proj/.next/cache"
}

# Snapshot a deterministic fingerprint of a tree: each file's path + size +
# mtime-epoch. Used to assert read-only modes mutate NOTHING.
fingerprint() {
  local root="$1"
  find "$root" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' "$f" "$(wc -c < "$f" | tr -d ' ')" \
      "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
  done
}

run_dj() { run bash "$DJ" "$@"; }

# ===========================================================================
# Arg parsing
# ===========================================================================

@test "--help prints usage and exits 0" {
  run_dj --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"trellis disk-janitor"* ]]
  [[ "$output" == *"--report"* ]]
  [[ "$output" == *"--apply"* ]]
}

@test "unknown flag -> stderr + exit 2" {
  run_dj --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "unknown scope -> exit 2" {
  run_dj --scopes caches,bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown scope"* ]]
}

@test "--project with a name not in registry -> exit 2" {
  build_alpha_with_stale_cache
  run_dj --report --scopes caches --project not-a-real-project
  [ "$status" -eq 2 ]
  [[ "$output" == *"not in registry.md"* ]]
}

@test "--project requires a value -> exit 2" {
  run_dj --project
  [ "$status" -eq 2 ]
  [[ "$output" == *"--project requires a NAME"* ]]
}

# ===========================================================================
# Report mode (default): read-only, writes the audit file.
# ===========================================================================

@test "report lists the stale cache as a delete candidate (positive control)" {
  build_alpha_with_stale_cache
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  # The stale cache IS in the plan with a delete verdict — this positive control
  # makes the negative assertions in the apply suite meaningful.
  [[ "$output" == *"[delete]"* ]]
  [[ "$output" == *"$PROJECTS/alpha/.next/cache"* ]]
  [[ "$output" == *"next-cache"* ]]
}

@test "report writes audits/<date>-disk-janitor.md under the FIXTURE canonical" {
  build_alpha_with_stale_cache
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  local audit
  audit="$CANON/audits/$(date +%F)-disk-janitor.md"
  [ -f "$audit" ]
  # Proves isolation: the audit landed under the fixture canon, not the live one.
  [[ "$output" == *"audit written: $audit"* ]]
  run cat "$audit"
  [[ "$output" == *"Disk janitor"* ]]
}

@test "report is READ-ONLY: project tree byte-identical before and after" {
  build_alpha_with_stale_cache
  local before after
  before="$(fingerprint "$PROJECTS/alpha")"
  run_dj --report --scopes caches,worktrees
  [ "$status" -eq 0 ]
  after="$(fingerprint "$PROJECTS/alpha")"
  [ "$before" = "$after" ]
  # The cache dir must still exist (nothing was pruned).
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "report runs the turbo-outputs recurrence pre-pass and flags an unscoped glob" {
  build_alpha_with_stale_cache
  cat > "$PROJECTS/alpha/turbo.json" <<'JSON'
{ "tasks": { "build": { "outputs": [".next/**"] } } }
JSON
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recurrence pre-pass"* ]]
  [[ "$output" == *"UNSCOPED turbo outputs found"* ]]
  [[ "$output" == *"alpha"* ]]
}

@test "report tolerates a registry project with no .git (skipped, not fatal)" {
  # alpha is listed in the registry but never git-init'd.
  mkdir -p "$PROJECTS/alpha"
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: not a git checkout"* ]]
}

# ===========================================================================
# Dry-run: read-only, prints the plan.
# ===========================================================================

@test "dry-run prints the deletion plan and mutates NOTHING" {
  build_alpha_with_stale_cache
  local before after
  before="$(fingerprint "$PROJECTS/alpha")"
  run_dj --dry-run --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"rm -rf"* ]]
  [[ "$output" == *"$PROJECTS/alpha/.next/cache"* ]]
  after="$(fingerprint "$PROJECTS/alpha")"
  [ "$before" = "$after" ]
  [ -d "$PROJECTS/alpha/.next/cache" ]
  # dry-run must NOT write an audit file.
  [ ! -f "$CANON/audits/$(date +%F)-disk-janitor.md" ]
}

# ===========================================================================
# Exit codes
# ===========================================================================

@test "exit 0 on a clean report with an empty fleet (no active projects matched)" {
  # Registry lists alpha, but we never create it -> skipped, run still exits 0.
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
}

@test "cache discovery failure warns, marks the project skipped, and exits nonzero" {
  build_alpha_with_stale_cache
  local shim_dir="$SANDBOX/failing-bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/find" <<'EOF'
#!/bin/sh
exit 73
EOF
  chmod +x "$shim_dir/find"

  PATH="$shim_dir:$PATH" run_dj --report --scopes caches

  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING: cache discovery failed for $PROJECTS/alpha"* ]]
  [[ "$output" == *"WARNING: scan failed for $PROJECTS/alpha"* ]]
  [[ "$output" == *"skipped: scan error ($PROJECTS/alpha)"* ]]
}

@test "worktree discovery failure warns, marks the project skipped, and exits nonzero" {
  build_alpha_with_stale_cache
  local shim_dir="$SANDBOX/failing-bin"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/git" <<EOF
#!/bin/sh
if [ "\${3-}" = "worktree" ] && [ "\${4-}" = "list" ] && [ "\${5-}" = "--porcelain" ]; then
  exit 74
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$shim_dir/git"

  PATH="$shim_dir:$PATH" run_dj --report --scopes worktrees

  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING: worktree discovery failed for $PROJECTS/alpha"* ]]
  [[ "$output" == *"WARNING: scan failed for $PROJECTS/alpha"* ]]
  [[ "$output" == *"skipped: scan error ($PROJECTS/alpha)"* ]]
}

@test "scopes can be narrowed: --scopes worktrees omits the cache section" {
  build_alpha_with_stale_cache
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"== Worktrees =="* ]]
  [[ "$output" != *"== Build caches =="* ]]
}
