#!/usr/bin/env bats
# Behavior tests for scripts/disk-janitor.sh — the orchestrator. Covers arg
# parsing (bad flag / bad scope -> exit 2), the read-only invariant of --report
# and --dry-run (fixture bytes IDENTICAL after the run), audit-file emission, and
# exit codes. NO deletion happens in this suite — destructive behavior is the
# job of disk-janitor-apply.bats.
#
# FULLY ISOLATED from live Trellis state: every test stands up a fresh portable
# policy, private TRELLIS_HOME, and strict local registry under `mktemp -d`.
# A buggy test therefore cannot reach the operator's fleet.
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
  TRELLIS_HOME="$SANDBOX/.trellis"
  CFG="$CANON/trellis.config.json"
  mkdir -p "$CANON" "$PROJECTS" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  export TRELLIS_CONFIG="$CFG" TRELLIS_HOME
  build_canonical_min
  write_config
}

teardown() {
  if [ -n "${LIVE_PID:-}" ]; then
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# The janitor consumes only the portable policy plus machine-local registry.
build_canonical_min() {
  mkdir -p "$CANON/audits"
}

write_config() {
  cat > "$CFG" <<EOF
{
  "schema_version": 2,
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"]
}
EOF
  cat > "$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$CANON",
  "release_remote": "https://example.invalid/trellis.git",
  "active_cli_release": "1.2.3",
  "default_fleet": "personal",
  "fleets": {"personal": {"discovery_roots": ["$PROJECTS"]}}
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

register_fixture_root() {
  local root="$1" project_id="${2:-alpha}"
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_register_worktree "$2" personal "$3" "$4" 1.2.3 "[\"claude\"]" ""
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$project_id" "$root" >/dev/null
}

record_fixture_unavailable() {
  local root="$1" project_id="${2:-alpha}"
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_record_unavailable_root "$2" personal "$3" "$4" "{}"
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$project_id" "$root" >/dev/null
}

set_fixture_status() {
  local project_id="$1" registry_status="$2" state="$TRELLIS_HOME/registry.json" proposal
  proposal="$(mktemp "$SANDBOX/registry-status.XXXXXX")"
  jq --arg key "personal/$project_id" --arg status "$registry_status" \
    '.projects[$key].status = $status' "$state" > "$proposal" &&
    mv "$proposal" "$state"
  chmod 600 "$state"
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
  case "$dir/" in "$PROJECTS/"*) register_fixture_root "$dir" ;; esac
}

# Build project "alpha" as a git checkout with one stale, non-empty cache dir.
build_alpha_with_stale_cache() {
  local proj="$PROJECTS/alpha"
  git_init_at "$proj"
  mkdir -p "$proj/.next/cache"
  dd if=/dev/zero of="$proj/.next/cache/blob" bs=1024 count=8 >/dev/null 2>&1
  touch -t 200001010000 "$proj/.next/cache"
}

# add_worktree <repo> <wt> <branch> — a linked worktree with its own registry row.
add_worktree() {
  local repo="$1" wt="$2" branch="$3"
  mkdir -p "$(dirname "$wt")"
  ( cd "$repo" && git worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 )
  register_fixture_root "$wt"
}

# write_config_dj <disk_janitor-json> — portable policy carrying a custom
# disk_janitor object (used to drive the Layer 3 tripwire ceilings).
write_config_dj() {
  local dj="$1"
  cat > "$CFG" <<EOF
{
  "schema_version": 2,
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"],
  "disk_janitor": $dj
}
EOF
}

# Snapshot a deterministic fingerprint of a tree: each file's path + size +
# mtime-epoch. Used to assert read-only modes mutate NOTHING.
# BSD and GNU stat are probed in SEPARATE captures: GNU `stat -f` is
# --file-system and prints a filesystem block before failing, which a chained
# substitution would concatenate onto the mtime and make every fingerprint
# differ from itself.
file_mtime() {
  local candidate
  candidate="$(stat -f %m "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-9]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %Y "$1" 2>/dev/null)" || candidate=0
  fi
  printf '%s\n' "$candidate"
}

fingerprint() {
  local root="$1"
  find "$root" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' "$f" "$(wc -c < "$f" | tr -d ' ')" \
      "$(file_mtime "$f")"
  done
}

run_dj() { run bash "$DJ" "$@"; }

# ===========================================================================
# Arg parsing
# ===========================================================================

@test "--help prints usage and exits 0" {
  run_dj --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"trellis disk-janitor"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--report"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--apply"* ]] || { echo "$output"; false; }
}

@test "unknown flag -> stderr + exit 2" {
  run_dj --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]] || { echo "$output"; false; }
}

@test "unknown scope -> exit 2" {
  run_dj --scopes caches,bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown scope"* ]] || { echo "$output"; false; }
}

@test "--project with an unknown local-registry identity -> exit 2" {
  build_alpha_with_stale_cache
  run_dj --report --scopes caches --project not-a-real-project
  [ "$status" -eq 2 ]
  [[ "$output" == *"not in the local registry"* ]] || { echo "$output"; false; }
}

@test "--project requires a value -> exit 2" {
  run_dj --project
  [ "$status" -eq 2 ]
  [[ "$output" == *"--project requires a NAME"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"[delete]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$PROJECTS/alpha/.next/cache"* ]] || { echo "$output"; false; }
  [[ "$output" == *"next-cache"* ]] || { echo "$output"; false; }
}

@test "report writes audits/<date>-disk-janitor.md under the FIXTURE canonical" {
  build_alpha_with_stale_cache
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  local audit
  audit="$CANON/audits/$(date +%F)-disk-janitor.md"
  [ -f "$audit" ]
  # Proves isolation: the audit landed under the fixture canon, not the live one.
  [[ "$output" == *"audit written: $audit"* ]] || { echo "$output"; false; }
  run cat "$audit"
  [[ "$output" == *"Disk janitor"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"Recurrence pre-pass"* ]] || { echo "$output"; false; }
  [[ "$output" == *"UNSCOPED turbo outputs found"* ]] || { echo "$output"; false; }
  [[ "$output" == *"alpha"* ]] || { echo "$output"; false; }
}

@test "report retains an unavailable registry root as a skip without probing it" {
  local unavailable="$SANDBOX/unmounted volume/alpha"
  record_fixture_unavailable "$unavailable"
  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: unavailable registry row"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$unavailable"* ]] || { echo "$output"; false; }
}

@test "report retains a detached registry project as an explicit inactive skip" {
  build_alpha_with_stale_cache
  set_fixture_status alpha detached

  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: inactive registry status (personal/alpha: detached)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"$PROJECTS/alpha/.next/cache"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"DRY RUN"* ]] || { echo "$output"; false; }
  [[ "$output" == *"descriptor-relative remove"* ]] || { echo "$output"; false; }
  [[ "$output" != *"rm -rf"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$PROJECTS/alpha/.next/cache"* ]] || { echo "$output"; false; }
  after="$(fingerprint "$PROJECTS/alpha")"
  [ "$before" = "$after" ]
  [ -d "$PROJECTS/alpha/.next/cache" ]
  # dry-run must NOT write an audit file.
  [ ! -f "$CANON/audits/$(date +%F)-disk-janitor.md" ]
}

@test "live process cwd inside a worktree is a manual candidate absent from the reap plan" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # Real process, real cwd, real lsof predicate — no lsof mocking. Redirect its
  # inherited descriptors so bats' output capture never waits for the sleeper.
  ( cd "$wt" && exec sleep 30 ) >/dev/null 2>&1 &
  LIVE_PID=$!

  # Avoid a spawn-vs-snapshot race: require the exact primitive from the safety
  # contract to observe the cwd before invoking the janitor.
  local tries=0
  while [ "$tries" -lt 50 ]; do
    lsof -a -d cwd -- "$wt" >/dev/null 2>&1 && break
    sleep 0.05
    tries=$((tries + 1))
  done
  lsof -a -d cwd -- "$wt" >/dev/null 2>&1

  # Both recoverability arms are forced true, so this would be a delete without
  # the liveness gate. It must instead render a manual row with an explicit reason.
  DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"worktree in use"* ]] || { echo "$output"; false; }
  [[ "$output" == *"live process cwd or open file handle under worktree"* ]] || { echo "$output"; false; }

  DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --dry-run --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"git worktree remove  $wt"* ]] || { echo "$output"; false; }
  [ -d "$wt" ]
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
  cat > "$shim_dir/python3" <<'EOF'
#!/bin/sh
exit 73
EOF
  chmod +x "$shim_dir/python3"

  PATH="$shim_dir:$PATH" run_dj --report --scopes caches

  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING: cache discovery failed for $PROJECTS/alpha"* ]] || { echo "$output"; false; }
  [[ "$output" == *"WARNING: scan failed for $PROJECTS/alpha"* ]] || { echo "$output"; false; }
  [[ "$output" == *"skipped: scan error ($PROJECTS/alpha)"* ]] || { echo "$output"; false; }
}

@test "worktree discovery failure warns, marks the project skipped, and exits nonzero" {
  build_alpha_with_stale_cache
  local shim_dir="$SANDBOX/failing-bin"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/git" <<EOF
#!/bin/sh
# The strict registry validator uses the NUL-delimited form. Fail only the
# janitor's line-based scanner invocation after identity selection succeeded.
if [ "\${3-}" = "worktree" ] && [ "\${4-}" = "list" ] && [ "\${5-}" = "--porcelain" ] && [ "\${6-}" != "-z" ]; then
  exit 74
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$shim_dir/git"

  PATH="$shim_dir:$PATH" run_dj --report --scopes worktrees

  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING: worktree discovery failed for $PROJECTS/alpha"* ]] || { echo "$output"; false; }
  [[ "$output" == *"WARNING: scan failed for $PROJECTS/alpha"* ]] || { echo "$output"; false; }
  [[ "$output" == *"skipped: scan error ($PROJECTS/alpha)"* ]] || { echo "$output"; false; }
}

@test "scopes can be narrowed: --scopes worktrees omits the cache section" {
  build_alpha_with_stale_cache
  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"== Worktrees =="* ]] || { echo "$output"; false; }
  [[ "$output" != *"== Build caches =="* ]] || { echo "$output"; false; }
}

# ===========================================================================
# Layer 3 tripwire — linked-worktree count + aggregate footprint
# ===========================================================================

@test "tripwire WARNs when a repo exceeds worktree_count_ceiling AND fleet exceeds the GB ceiling" {
  # ceiling of 1 tree / 0 GB -> any 2 linked worktrees + any footprint trip both.
  write_config_dj '{ "worktree_count_ceiling": 1, "worktree_total_gb_ceiling": 0 }'
  git_init_at "$PROJECTS/alpha"
  add_worktree "$PROJECTS/alpha" "$PROJECTS/alpha/.claude/worktrees/a" "feat/a"
  add_worktree "$PROJECTS/alpha" "$PROJECTS/alpha/.claude/worktrees/b" "feat/b"

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  # Count tripwire: 2 linked trees in the busiest checkout > ceiling 1 -> WARN.
  [[ "$output" == *"linked worktrees (busiest checkout): 2 in "*"$PROJECTS/alpha/.git"* ]] || { echo "$output"; false; }
  [[ "$output" == *"linked worktrees (busiest checkout)"*"⚠ OVER ceiling (1)"* ]] || { echo "$output"; false; }
  # Aggregate tripwire: any footprint > 0 GB -> WARN.
  [[ "$output" == *"linked-worktree footprint (fleet)"*"⚠ OVER ceiling"* ]] || { echo "$output"; false; }
  # The config line echoes the new keys.
  [[ "$output" == *"worktree_count_ceiling=1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"worktree_total_gb_ceiling=0"* ]] || { echo "$output"; false; }
}

@test "tripwire shows ✓ under ceiling with default ceilings and only a couple of worktrees" {
  git_init_at "$PROJECTS/alpha"
  add_worktree "$PROJECTS/alpha" "$PROJECTS/alpha/.claude/worktrees/a" "feat/a"

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked worktrees (busiest checkout): 1 in "* ]] || { echo "$output"; false; }
  [[ "$output" == *"linked worktrees (busiest checkout)"*"✓ under ceiling (25)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"linked-worktree footprint (fleet)"*"✓ under ceiling (80.0 GB)"* ]] || { echo "$output"; false; }
  # Default new-key values are echoed on the config line.
  [[ "$output" == *"reap_pushed_worktrees=true"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ephemeral_tmp_ttl_days=2"* ]] || { echo "$output"; false; }
  [[ "$output" == *"worktree_count_ceiling=25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"worktree_total_gb_ceiling=80"* ]] || { echo "$output"; false; }
}

@test "strict registry scans a project path with spaces outside a discovery root" {
  local project="$SANDBOX/external volume/project with spaces"
  git_init_at "$project"
  register_fixture_root "$project" "space-project"
  mkdir -p "$project/.next/cache"
  printf 'cache\n' > "$project/.next/cache/blob"
  touch -t 200001010000 "$project/.next/cache"

  run_dj --report --scopes caches --project space-project
  [ "$status" -eq 0 ]
  [[ "$output" == *"$project/.next/cache"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[delete]"* ]] || { echo "$output"; false; }
}

@test "strict registry reports but never selects an unregistered sibling worktree cache" {
  local registered="$PROJECTS/alpha/.claude/worktrees/registered"
  local unregistered="$PROJECTS/alpha/.claude/worktrees/unregistered"
  git_init_at "$PROJECTS/alpha"
  add_worktree "$PROJECTS/alpha" "$registered" "feat/registered"
  mkdir -p "$(dirname "$unregistered")"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/unregistered "$unregistered" >/dev/null 2>&1 )
  mkdir -p "$registered/.next/cache" "$unregistered/.next/cache"
  printf 'registered\n' > "$registered/.next/cache/blob"
  printf 'unregistered\n' > "$unregistered/.next/cache/blob"
  touch -t 200001010000 "$registered/.next/cache" "$unregistered/.next/cache"

  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"$registered/.next/cache"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[skip]"*"${unregistered}/.next/cache"* ]] || { echo "$output"; false; }
  [[ "$output" == *"${unregistered}/.next/cache"*"cache crosses a registered Git worktree boundary"* ]] || { echo "$output"; false; }
}

@test "--project accepts multiple worktrees with one checkout identity" {
  local worktree="$PROJECTS/alpha/.claude/worktrees/feat-x"
  git_init_at "$PROJECTS/alpha"
  add_worktree "$PROJECTS/alpha" "$worktree" "feat/x"
  mkdir -p "$worktree/.next/cache"
  printf 'cache\n' > "$worktree/.next/cache/blob"
  touch -t 200001010000 "$worktree/.next/cache"

  run_dj --report --scopes caches --project alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"$worktree/.next/cache"* ]] || { echo "$output"; false; }
}

@test "--project still carries a drifted sibling row into the exit class" {
  local beta="$PROJECTS/beta"
  build_alpha_with_stale_cache
  mkdir -p "$beta"
  (
    cd "$beta"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    printf 'seed\n' > seed.txt
    git add -A
    git commit -q -m init
  )
  register_fixture_root "$beta" beta
  # Root stays present but stops resolving as a canonical Git worktree, so its
  # registry row lists as identity_error while alpha stays healthy.
  rm -rf "$beta/.git"

  # The selection filter used to run BEFORE the identity_error test, so a scoped
  # run dropped the sibling row and exited 0 over a registry it had just been
  # shown to be corrupt.
  run_dj --report --scopes caches --project alpha
  [ "$status" -eq 4 ]
  [[ "$output" == *"registry row failed identity validation"* ]] || { echo "$output"; false; }
  [[ "$output" == *"personal/beta"* ]] || { echo "$output"; false; }
  # Selection still limits PROCESSING: alpha is the only project acted on.
  [[ "$output" == *"$PROJECTS/alpha/.next/cache"* ]] || { echo "$output"; false; }
}

# Builds a healthy alpha plus a registered beta whose root stays present but no
# longer resolves as a canonical Git worktree, so beta's row lists identity_error.
build_drifted_beta_sibling() {
  local beta="$PROJECTS/beta"
  mkdir -p "$beta"
  (
    cd "$beta"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false
    printf 'seed\n' > seed.txt
    git add -A
    git commit -q -m init
  )
  register_fixture_root "$beta" beta
  rm -rf "$beta/.git"
}

@test "--project preflight refusals never report below a proven registry state error" {
  build_alpha_with_stale_cache
  build_drifted_beta_sibling

  # PREFLIGHT, not the row loop: both guards below exit before the row scan that
  # tests identity_error, so an unknown or ambiguous selector used to exit 2 or 3
  # over a registry the listing in hand had already proved corrupt — a class
  # BELOW the state error, naming none of the rows that caused it.
  run_dj --report --scopes caches --project not-a-real-project
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'not in the local registry' <<<"$output"
  grep -qF 'registry row failed identity validation' <<<"$output"
  grep -qF 'personal/beta' <<<"$output"

  git_init_at "$SANDBOX/clone one"
  git_init_at "$SANDBOX/clone two"
  register_fixture_root "$SANDBOX/clone one" alpha
  register_fixture_root "$SANDBOX/clone two" alpha
  run_dj --report --scopes caches --project alpha
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  grep -qF 'multiple registered checkout identities' <<<"$output"
  grep -qF 'registry row failed identity validation' <<<"$output"
}

@test "a registered checkout with no worktree row is inventory, not an unavailable root" {
  local clone="$SANDBOX/checkout only clone"
  git_init_at "$clone"
  register_fixture_root "$clone" checkout-only
  # Keep the checkout, drop its worktree entry: the listing then emits a
  # `kind: "checkout"` VISIBILITY row whose own identity still validates.
  jq '.projects["personal/checkout-only"].checkouts |= with_entries(.value.worktrees = {})' \
    "$TRELLIS_HOME/registry.json" > "$SANDBOX/registry.next"
  mv -f "$SANDBOX/registry.next" "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"

  run_dj --report --scopes caches
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF 'registered checkout with no worktree row (personal/checkout-only' <<<"$output"
  [ "$(grep -cF 'unavailable registry row (personal/checkout-only' <<<"$output")" -eq 0 ] || { echo "$output"; false; }
}

@test "--project rejects two available registered checkout identities" {
  local first="$SANDBOX/clone one" second="$SANDBOX/clone two"
  git_init_at "$first"
  git_init_at "$second"
  register_fixture_root "$first" alpha
  register_fixture_root "$second" alpha

  run_dj --report --scopes caches --project alpha
  [ "$status" -eq 3 ]
  [[ "$output" == *"multiple registered checkout identities"* ]] || { echo "$output"; false; }
}

@test "--project rejects multiple checkout identities even when one clone is unavailable" {
  local first="$SANDBOX/clone one" second="$SANDBOX/clone two"
  git_init_at "$first"
  git_init_at "$second"
  register_fixture_root "$first" alpha
  register_fixture_root "$second" alpha
  # Preserve the second checkout ID in the registry while making its root
  # unavailable. A project selector cannot silently pick the remaining clone.
  rm -rf "$second"

  run_dj --report --scopes caches --project alpha
  [ "$status" -eq 3 ]
  [[ "$output" == *"multiple registered checkout identities"* ]] || { echo "$output"; false; }
}

@test "free-space floors are emitted once per actual filesystem and unavailable roots never reach df" {
  local first="$SANDBOX/volume one/project" second="$SANDBOX/volume two/project"
  local fake_bin="$SANDBOX/bin" df_log="$SANDBOX/df.log"
  git_init_at "$first"
  git_init_at "$second"
  register_fixture_root "$first" volume-one
  register_fixture_root "$second" volume-two
  record_fixture_unavailable "$SANDBOX/unmounted volume/project" unavailable-project
  mkdir -p "$fake_bin"
  cat > "$fake_bin/df" <<EOF
#!/bin/sh
printf '%s\n' "\$2" >> "$df_log"
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
case "\$2" in
  *"volume one"*) echo '/dev/volume-one 100 10 90 10% /one' ;;
  *"volume two"*) echo '/dev/volume-two 100 20 80 20% /two' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$fake_bin/df"

  PATH="$fake_bin:$PATH" run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"free space on filesystem /dev/volume-one"* ]] || { echo "$output"; false; }
  [[ "$output" == *"free space on filesystem /dev/volume-two"* ]] || { echo "$output"; false; }
  [[ "$(cat "$df_log")" != *"unmounted volume"* ]] || { cat "$df_log"; false; }
}
