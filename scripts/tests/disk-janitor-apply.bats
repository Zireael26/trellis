#!/usr/bin/env bats
# THE SAFETY SUITE for scripts/disk-janitor.sh --apply.
#
# These tests verify the bright-line guardrails that keep --apply from ever
# destroying data it shouldn't. Every test is hermetic:
#   * a fresh `mktemp -d` sandbox per test,
#   * a portable policy plus private TRELLIS_HOME/local registry,
#   * merge/build network checks use injectable overrides; liveness cases use a
#     real background process whose cwd/open handle stays inside the sandbox.
#
# Each negative ("must NOT delete") test asserts the ARTIFACT survives
# (`[ -d ]`), not merely that some "declined"/"skip" string printed — the
# filesystem is the real verification. Each positive ("must delete") test uses a
# positive control via the plan output so an empty-fleet/skipped vacuous pass
# can't masquerade as success.
#
# We always pass `</dev/null` to apply runs so a stray tty can never feed the
# y/N prompt, and `--yes` only where we WANT the destructive path to run.
# `--scopes` is pinned per test so the host-global `stores` scope never runs;
# the Docker test shadows the Docker CLI with a hermetic fixture.
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
  TRELLIS_HOME="$SANDBOX/.trellis"
  CFG="$CANON/trellis.config.json"
  EXTERNAL_WT_ROOT="$SANDBOX/external worktrees"
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
  if [ -n "${EXTERNAL_WT_ROOT:-}" ] && [ -d "$EXTERNAL_WT_ROOT" ]; then
    rm -rf "$EXTERNAL_WT_ROOT"
  fi
  if [ -n "${OUTSIDE_WT_ROOT:-}" ] && [ -d "$OUTSIDE_WT_ROOT" ]; then
    rm -rf "$OUTSIDE_WT_ROOT"
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
  if [ -n "${TMP_WT_ROOT:-}" ] && [ -d "$TMP_WT_ROOT" ]; then
    rm -rf "$TMP_WT_ROOT"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

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

# Optional: drop a disk_janitor block with a custom cache_ttl_days so we can
# exercise the TTL boundary precisely. $1 = ttl days.
write_config_with_ttl() {
  local ttl="$1"
  cat > "$CFG" <<EOF
{
  "schema_version": 2,
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
  case "$dir/" in "$PROJECTS/"*) register_fixture_root "$dir" ;; esac
}

# make_cache <project_dir> <relpath> <touch-stamp> — a non-empty cache dir whose
# DIR mtime is set explicitly (cache staleness keys on the directory mtime).
make_cache() {
  local proj="$1" rel="$2" stamp="$3" dir="$1/$2"
  mkdir -p "$dir"
  dd if=/dev/zero of="$dir/blob" bs=1024 count=8 >/dev/null 2>&1
  touch -t "$stamp" "$dir"
}

# add_worktree <repo> <wt> <branch> — a linked worktree with a registry record.
add_worktree() {
  local repo="$1" wt="$2" branch="$3"
  mkdir -p "$(dirname "$wt")"
  ( cd "$repo" && git worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 )
  register_fixture_root "$wt"
}

# add_unregistered_worktree <repo> <wt> <branch> — linked only in Git metadata.
# Phantom-registration pruning is authorized by a separate strict current root,
# never by treating this arbitrary target as a registry owner.
add_unregistered_worktree() {
  local repo="$1" wt="$2" branch="$3"
  mkdir -p "$(dirname "$wt")"
  ( cd "$repo" && git worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 )
}

# Allocate a real path outside the only phantom namespaces. $SANDBOX may itself
# live under /tmp on some runners, so it is not a valid negative control.
make_outside_phantom_root() {
  local parent candidate canonical
  for parent in /private/var/tmp /var/tmp; do
    [ -d "$parent" ] || continue
    candidate="$(mktemp -d "$parent/dj-phantom-outside.XXXXXX" 2>/dev/null)" || continue
    canonical="$(cd "$candidate" && pwd -P)" || {
      rm -rf "$candidate"
      continue
    }
    case "$canonical/" in
      /sessions/*|/tmp/*|/private/tmp/*)
        rm -rf "$candidate"
        ;;
      *)
        OUTSIDE_WT_ROOT="$canonical"
        printf '%s\n' "$OUTSIDE_WT_ROOT"
        return 0
        ;;
    esac
  done
  return 1
}

# add_worktree_ignoring <repo> <wt> <branch> <gitignore-line...>
add_worktree_ignoring() {
  local repo="$1" wt="$2" branch="$3"; shift 3
  mkdir -p "$(dirname "$wt")"
  ( cd "$repo" && git worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 )
  printf '%s\n' "$@" > "$wt/.gitignore"
  ( cd "$wt" && git add .gitignore \
      && GIT_AUTHOR_DATE="$OLD_COMMIT_DATE" GIT_COMMITTER_DATE="$OLD_COMMIT_DATE" \
         git commit -q -m "gitignore" )
  register_fixture_root "$wt"
}

# write_config_dj <disk_janitor-json> — portable policy carrying a custom
# disk_janitor object (e.g. '{ "reap_pushed_worktrees": false }').
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

run_dj() { run bash "$DJ" "$@"; }
# ---------------------------------------------------------------------------
# RELEASE EXECUTION SNAPSHOT FIXTURES
# ---------------------------------------------------------------------------

# make_release_execution_snapshot <version> <suffix> <touch-stamp|fresh>
# creates the same direct-child namespace the executor uses. The payload marker
# makes the directory observably real rather than a vacuous pathname match.
make_release_execution_snapshot() {
  local version="$1" suffix="$2" stamp="$3" snapshot
  snapshot="$TRELLIS_HOME/releases/.tmp.$version.exec.$suffix"
  mkdir -p "$snapshot/payload"
  printf 'release snapshot fixture\n' > "$snapshot/payload/marker"
  if [ "$stamp" = fresh ]; then
    touch "$snapshot"
  else
    touch -t "$stamp" "$snapshot"
  fi
  printf '%s\n' "$snapshot"
}

# write_release_execution_owner <snapshot> <pid> <process-birth>
# The owner record is deliberately closed: the janitor must reject any extra
# key instead of treating a merely plausible pid as ownership evidence.
write_release_execution_owner() {
  local snapshot="$1" pid="$2" process_birth="$3"
  jq -cn --argjson pid "$pid" --arg process_birth "$process_birth" \
    '{schema_version:1,pid:$pid,process_birth:$process_birth}' \
    > "$snapshot.owner.json"
  chmod 600 "$snapshot.owner.json"
}

release_process_birth() {
  # Keep the exact token shape used by dj_release_staging_owner_state; command
  # substitution removes only ps's trailing newline.
  LC_ALL=C ps -p "$1" -o lstart=
}

# ===========================================================================
# RELEASE EXECUTION SNAPSHOTS — direct store children and owner identity
# ===========================================================================

@test "--apply --yes --scopes releases retains a fresh execution snapshot" {
  local snapshot
  snapshot="$(make_release_execution_snapshot 1.2.3 FreshA1 fresh)"

  # Report mode renders every planned row, including a fresh retention skip;
  # this is the positive control that proves the exact directory was scanned.
  run_dj --report --scopes releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$snapshot"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[skip]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"younger"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --scopes releases </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Filesystem proof: a real directory with payload content survived.
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ]
  [ -f "$snapshot/payload/marker" ]
}

@test "--apply --yes --scopes releases removes an aged orphan and its owner sidecar" {
  local snapshot owner
  snapshot="$(make_release_execution_snapshot 1.2.3 DeadA1 "$STALE_TOUCH")"
  owner="$snapshot.owner.json"
  # A schema-valid record for a mismatched/dead owner must not authorize
  # retention. The impossible pid keeps this independent of the host process
  # table while still exercising the strict owner-record parser.
  write_release_execution_owner "$snapshot" 2147483647 "dead-process"

  # First capture the complete plan row; --apply may print only rows that will
  # be deleted, so the report is the non-vacuous planned-target control.
  run_dj --report --scopes releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$snapshot"* ]] || { echo "$output"; false; }
  [[ "$output" == *"orphaned"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[delete]"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --scopes releases </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ]
  [ ! -e "$owner" ] && [ ! -L "$owner" ]
  # Both planning and execution must name the actual target, and the summary
  # must report reclaimed work rather than passing on an empty plan.
  [[ "$output" == *"$snapshot"* ]] || { echo "$output"; false; }
  [[ "$output" == *"delete"* || "$output" == *"reclaim"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"removed"* || "$output" == *"reaped"* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *"reclaimed"* ]] || { echo "$output"; false; }
}

@test "an aged execution snapshot with a strict live owner is retained without argv matching" {
  local snapshot owner birth command_line
  snapshot="$(make_release_execution_snapshot 1.2.3 LiveA1 "$STALE_TOUCH")"

  # Keep the process in the sandbox, but do not place the snapshot path in its
  # argv. Retention therefore proves pid + LC_ALL=C ps lstart identity rather
  # than a command-line substring heuristic.
  ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  birth="$(release_process_birth "$LIVE_PID")"
  [ -n "$birth" ] || { echo "could not read live process birth"; false; }
  command_line="$(LC_ALL=C ps -o command= -p "$LIVE_PID")"
  [[ "$command_line" != *"$snapshot"* ]] || {
    echo "live owner fixture unexpectedly contains snapshot path in argv: $command_line"
    false
  }
  write_release_execution_owner "$snapshot" "$LIVE_PID" "$birth"
  owner="$snapshot.owner.json"

  # Report mode is the explicit plan evidence for a retained candidate; apply
  # must then leave both the directory and its owner sidecar untouched.
  run_dj --report --scopes releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$snapshot"* ]] || { echo "$output"; false; }
  [[ "$output" == *"owner process is live"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[candidate]"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --scopes releases </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ]
  [ -f "$owner" ] && [ ! -L "$owner" ]
}

@test "an aged live owner fails closed when its process birth probe fails" {
  local snapshot owner birth fake_bin real_ps
  snapshot="$(make_release_execution_snapshot 1.2.3 ProbeFailA1 "$STALE_TOUCH")"
  ( cd "$SANDBOX" && exec /bin/sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  birth="$(release_process_birth "$LIVE_PID")"
  [ -n "$birth" ] || { echo "could not read live process birth"; false; }
  write_release_execution_owner "$snapshot" "$LIVE_PID" "$birth"
  owner="$snapshot.owner.json"

  real_ps="$(command -v ps)"
  fake_bin="$SANDBOX/failing-owner-ps"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ps" <<'EOF'
#!/bin/bash
if [ "$*" = "-p $FAIL_PS_PID -o lstart=" ]; then
  exit 69
fi
exec "$REAL_PS" "$@"
EOF
  chmod +x "$fake_bin/ps"

  run env PATH="$fake_bin:$PATH" REAL_PS="$real_ps" FAIL_PS_PID="$LIVE_PID" \
    bash "$DJ" --report --scopes releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$snapshot"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[candidate]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"could not be determined"* ]] || { echo "$output"; false; }

  run env PATH="$fake_bin:$PATH" REAL_PS="$real_ps" FAIL_PS_PID="$LIVE_PID" \
    bash "$DJ" --apply --yes --scopes releases </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ]
  [ -f "$owner" ] && [ ! -L "$owner" ]
}

@test "an aged execution snapshot with a malformed owner fails closed" {
  local snapshot owner
  snapshot="$(make_release_execution_snapshot 1.2.3 MalformedA1 "$STALE_TOUCH")"
  owner="$snapshot.owner.json"
  jq -cn '{schema_version:1,pid:1,process_birth:"not-authoritative",extra:true}' > "$owner"
  chmod 600 "$owner"

  run_dj --report --scopes releases
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$snapshot"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[candidate]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"malformed"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --scopes releases </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ]
  [ -f "$owner" ] && [ ! -L "$owner" ]
}


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
  [[ "$output" == *"delete"*"$PROJECTS/alpha/.next/cache"* || "$output" == *"$PROJECTS/alpha/.next/cache"*"stale"* ]] || { echo "$output"; false; }

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
  [[ "$output" == *"build running"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"[delete]"*"$wt"* || "$output" == *"$wt"*"merged"* ]] || { echo "$output"; false; }

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
  [[ "$output" == *"candidate"* ]] || { echo "$output"; false; }
  [[ "$output" == *"unverified"* ]] || { echo "$output"; false; }

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
  [[ "$output" == *"main checkout — never reaped"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"declined"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"[delete]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"pushed"* ]] || { echo "$output"; false; }
  [[ "$output" == *"recoverable"* ]] || { echo "$output"; false; }

  [ -d "$wt" ]
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "registered recoverable worktree outside a discovery root is reaped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$EXTERNAL_WT_ROOT/alpha/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/external"
  [ -d "$wt" ]
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"reaped: $wt"* ]] || { echo "$output"; false; }
  [ ! -d "$wt" ]
}

@test "worktree summary counts only successful removals" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  local real_git fake_bin
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  real_git="$(command -v git)"
  fake_bin="$SANDBOX/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<EOF
#!/bin/sh
case " \$* " in
  *" worktree remove "*) exit 1 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged \
    run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 1 ]
  [ -d "$wt" ]
  [[ "$output" == *"REFUSED/failed: $wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"worktrees: 0 B reaped"* ]] || { echo "$output"; false; }
  [[ "$output" != *"reaped (planned)"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"candidate (not recoverable)"* ]] || { echo "$output"; false; }

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Not recoverable -> reported candidate, EXCLUDED from apply -> survives.
  [ -d "$wt" ]
}

# ===========================================================================
# LAYER 2 — no-local-content safety gate
# ===========================================================================

@test "porcelain-dirty (untracked source) -> skip, regardless of recoverable" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  # Real un-committed work: a TRACKABLE (non-ignored) untracked source file.
  printf 'precious un-committed work\n' > "$wt/NEWFEATURE.ts"

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[skip]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"dirty (uncommitted work)"* ]] || { echo "$output"; false; }

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Porcelain-dirty ALWAYS wins over recoverable -> the WIP survives.
  [ -d "$wt" ]
  [ -f "$wt/NEWFEATURE.ts" ]
}

@test "porcelain-clean + ignored build artifacts -> candidate, NOT reaped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree_ignoring "$PROJECTS/alpha" "$wt" "feat/x" "node_modules/" ".next/"
  mkdir -p "$wt/node_modules/pkg" "$wt/.next/cache"
  printf 'x\n' > "$wt/node_modules/pkg/i.js"
  printf 'x\n' > "$wt/.next/cache/x"

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ignored local content"* ]] || { echo "$output"; false; }

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  [ -f "$wt/node_modules/pkg/i.js" ]
  [ -f "$wt/.next/cache/x" ]
}

@test "porcelain-clean + unknown gitignored data (.vercel) -> candidate, NOT reaped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree_ignoring "$PROJECTS/alpha" "$wt" "feat/x" ".vercel/"
  mkdir -p "$wt/.vercel"
  printf '{}\n' > "$wt/.vercel/project.json"

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ignored local content"* ]] || { echo "$output"; false; }

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  [ -f "$wt/.vercel/project.json" ]
}

@test "porcelain-clean + a gitignored .env secret -> candidate (manual), NOT reaped" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree_ignoring "$PROJECTS/alpha" "$wt" "feat/x" ".env" "node_modules/"
  printf 'API_KEY=shhh\n' > "$wt/.env"
  mkdir -p "$wt/node_modules"; printf 'x\n' > "$wt/node_modules/x"

  # Recoverable + porcelain-clean, but any ignored local content downgrades it.
  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ignored local content"* ]] || { echo "$output"; false; }

  DJ_PUSHED_OVERRIDE=pushed DJ_MERGED_OVERRIDE=unmerged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Ignored local content is a manual candidate, excluded from apply.
  [ -d "$wt" ]
  [ -f "$wt/.env" ]
}

# ===========================================================================
# LAYER 2 — /private/tmp ephemerality (short TTL, no upstream needed)
#
# These MUST create fixtures under the real /private/tmp (the only way to hit
# that branch); guarded by [ -d /private/tmp ] and cleaned in teardown via
# TMP_WT_ROOT. A registered /private/tmp worktree remains eligible because
# explicit registry identity, not discovery-root placement, is the boundary.
# ===========================================================================

@test "/private/tmp clean tree, stale + no upstream + not-detached -> delete verdict" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  # Backdated init commit -> HEAD is far past -> stale at the 2d ephemeral TTL.
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  register_fixture_root "$wt"

  # Not recoverable (unmerged + unpushed), clean, /private/tmp, stale, branch set.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[delete]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ephemeral-tmp"* ]] || { echo "$output"; false; }
}

@test "/private/tmp clean stale registered tree is actually REAPED by --apply" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  register_fixture_root "$wt"

  [ -d "$wt" ]
  # Exact registry ownership, rather than a root-prefix exception, permits this
  # registered ephemeral worktree to be removed.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
}

@test "/private/tmp stale tree with gitignored local content -> candidate, NOT reaped" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  register_fixture_root "$wt"
  # Gitignore .env (tree stays porcelain-clean), backdated commit so HEAD is stale.
  printf '.env\n' > "$wt/.gitignore"
  ( cd "$wt" && git add .gitignore \
      && GIT_AUTHOR_DATE="$OLD_COMMIT_DATE" GIT_COMMITTER_DATE="$OLD_COMMIT_DATE" git commit -q -m "gitignore" )
  printf 'SECRET=1\n' > "$wt/.env"

  # Not recoverable + porcelain-clean + /private/tmp + stale would otherwise be
  # an ephemeral delete, but ignored local state must force a manual candidate.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"[delete]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$wt"*"ignored local content"* ]] || { echo "$output"; false; }
}

@test "/private/tmp clean tree that is YOUNGER than the TTL -> candidate, NOT delete" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  ( cd "$PROJECTS/alpha" && git worktree add -q -b feat/x "$wt" >/dev/null 2>&1 )
  register_fixture_root "$wt"
  # Fresh commit (current date) -> HEAD is recent -> NOT stale at the 2d TTL.
  ( cd "$wt" && git commit --allow-empty -q -m "fresh" )

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"[delete]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"candidate (not recoverable)"*"$wt"* || "$output" == *"$wt"*"candidate (not recoverable)"* ]] || { echo "$output"; false; }
}

@test "/private/tmp clean tree that is DETACHED -> candidate, NOT delete (no branch ref)" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-eph.XXXXXX)"
  local wt="$TMP_WT_ROOT/wt"
  # Detached HEAD at the backdated init commit -> stale but branchless.
  ( cd "$PROJECTS/alpha" && git worktree add -q --detach "$wt" HEAD >/dev/null 2>&1 )
  register_fixture_root "$wt"

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"[delete]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"candidate"* ]] || { echo "$output"; false; }
}


# ===========================================================================
# PHANTOM GIT REGISTRATIONS — missing ephemeral entries only
#
# A phantom is a Git worktree registration whose directory is gone. The target
# itself is intentionally unregistered; the live main checkout is the strict
# local-registry current root that authorizes inspecting its Git metadata.
# ===========================================================================

@test "registered current root reaps one absent /tmp phantom without broad-pruning an outside registration" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-phantom.XXXXXX)"
  local phantom="$TMP_WT_ROOT/stale"
  make_outside_phantom_root >/dev/null || skip "no writable path outside /sessions and /tmp"
  local outside="$OUTSIDE_WT_ROOT/stale"

  add_unregistered_worktree "$PROJECTS/alpha" "$phantom" "phantom/stale"
  add_unregistered_worktree "$PROJECTS/alpha" "$outside" "phantom/outside"
  rm -rf "$phantom" "$outside"

  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[delete]"*"$phantom"* ]] || { echo "$output"; false; }
  [[ "$output" == *"phantom registration"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"*"$outside"* ]] || { echo "$output"; false; }

  # The unattended merged-only schedule must leave phantom registration cleanup
  # to the normal manually-confirmed apply path.
  run_dj --apply --yes --safe-only --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  run git -C "$PROJECTS/alpha" worktree list --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" == *"$phantom"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$outside"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"reaped: $phantom"* ]] || { echo "$output"; false; }
  run git -C "$PROJECTS/alpha" worktree list --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" != *"$phantom"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$outside"* ]] || { echo "$output"; false; }
}


@test "phantom registration cleanup honors reap_pushed_worktrees=false" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-phantom-legacy.XXXXXX)"
  local phantom="$TMP_WT_ROOT/legacy"
  add_unregistered_worktree "$PROJECTS/alpha" "$phantom" "phantom/legacy"
  rm -rf "$phantom"
  write_config_dj '{ "reap_pushed_worktrees": false }'

  run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  run git -C "$PROJECTS/alpha" worktree list --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" == *"$phantom"* ]] || { echo "$output"; false; }
}

@test "phantom pruning refuses an active deleted cwd plus existing dirty and outside worktrees" {
  [ -d /private/tmp ] || skip "/private/tmp not present on this host"
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  git_init_at "$PROJECTS/alpha"
  TMP_WT_ROOT="$(mktemp -d /private/tmp/dj-phantom-guards.XXXXXX)"
  local active="$TMP_WT_ROOT/active"
  local existing="$TMP_WT_ROOT/existing"
  local dirty="$TMP_WT_ROOT/dirty"
  make_outside_phantom_root >/dev/null || skip "no writable path outside /sessions and /tmp"
  local outside="$OUTSIDE_WT_ROOT/guarded"
  local tries=0

  add_unregistered_worktree "$PROJECTS/alpha" "$active" "phantom/active"
  add_unregistered_worktree "$PROJECTS/alpha" "$existing" "phantom/existing"
  add_unregistered_worktree "$PROJECTS/alpha" "$dirty" "phantom/dirty"
  add_unregistered_worktree "$PROJECTS/alpha" "$outside" "phantom/outside"
  printf 'precious WIP\n' > "$dirty/UNCOMMITTED.txt"
  ( cd "$active" && exec sleep 30 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  while [ "$tries" -lt 50 ]; do
    lsof -a -d cwd -- "$active" >/dev/null 2>&1 && break
    sleep 0.05
    tries=$((tries + 1))
  done
  lsof -a -d cwd -- "$active" >/dev/null 2>&1
  rm -rf "$active" "$outside"

  run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"*"$active"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$active"*"phantom registration in use"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"*"$active"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"*"$existing"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"*"$dirty"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[delete]"*"$outside"* ]] || { echo "$output"; false; }

  run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [ -d "$PROJECTS/alpha" ]
  [ -d "$existing" ]
  [ -d "$dirty" ]
  [ -f "$dirty/UNCOMMITTED.txt" ]
  run git -C "$PROJECTS/alpha" worktree list --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" == *"$active"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$existing"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$dirty"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$outside"* ]] || { echo "$output"; false; }
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
  [[ "$output" == *"candidate (unverified merge)"* ]] || { echo "$output"; false; }

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
  [[ "$output" == *"enabled is false"* ]] || { echo "$output"; false; }
  # The stale cache is untouched — apply never ran.
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "disk_janitor.enabled=false still permits --report (inspection stays open)" {
  write_config_dj '{ "enabled": false }'
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"

  run_dj --report --scopes caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled=false"* ]] || { echo "$output"; false; }
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

@test "safe-only PROTECTS a merged + clean tree while a process cwd is inside it" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # The ADR historically used merged-ness as the proxy for "nobody is there."
  # Exercise the residual case directly: merged + clean, but a real live cwd.
  ( cd "$wt" && exec sleep 30 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  local tries=0
  while [ "$tries" -lt 50 ]; do
    lsof -a -d cwd -- "$wt" >/dev/null 2>&1 && break
    sleep 0.05
    tries=$((tries + 1))
  done
  lsof -a -d cwd -- "$wt" >/dev/null 2>&1

  DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=unpushed \
    run_dj --report --safe-only --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"candidate (worktree in use)"* ]] || { echo "$output"; false; }

  [ -d "$wt" ]
  DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=unpushed \
    run_dj --apply --yes --safe-only --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # The nightly predicate is unchanged (still merged-only); liveness is an
  # additive belt-and-braces gate that narrows the result and preserves the tree.
  [ -d "$wt" ]
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
  [[ "$output" == *"safe-only: not merged"* ]] || { echo "$output"; false; }
  # And the banner advertises the restriction.
  [[ "$output" == *"safe-only: merged-clean worktrees only"* ]] || { echo "$output"; false; }
}

@test "lsof failure fails closed: merged worktree is manual-only in default and safe-only apply" {
  git_init_at "$PROJECTS/alpha"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"

  # Put a real executable named lsof first in PATH and make the probe fail. This
  # exercises command discovery + the subprocess exit path without replacing the
  # helper itself; any lsof failure must close, never open, the deletion gate.
  local shim_dir="$SANDBOX/failing-lsof-bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/lsof" <<'EOF'
#!/bin/sh
exit 73
EOF
  chmod +x "$shim_dir/lsof"

  PATH="$shim_dir:$PATH" DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --report --scopes worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"[candidate]"*"$wt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"worktree in use"* ]] || { echo "$output"; false; }
  [[ "$output" == *"lsof failed (exit 73)"* ]] || { echo "$output"; false; }

  PATH="$shim_dir:$PATH" DJ_MERGED_OVERRIDE=merged DJ_PUSHED_OVERRIDE=pushed \
    run_dj --apply --yes --safe-only --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  # Nightly path: a broken liveness check over-refuses and leaves the tree intact.
  [ -d "$wt" ]
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

@test "apply skips a cache when its exact registry owner changes after planning" {
  local fake_bin="$SANDBOX/race-bin" real_python
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"
  real_python="$(command -v python3)"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/python3" <<'EOF'
#!/bin/sh
"$DJ_REAL_PYTHON" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${1:-}" = "-" ] &&
   [ "${2:-}" = "$DJ_RACE_ROOT" ] && [ ! -e "$DJ_RACE_HOME/raced" ]; then
  : > "$DJ_RACE_HOME/raced"
  rm -f "$DJ_RACE_HOME/registry.json"
fi
exit "$rc"
EOF
  chmod +x "$fake_bin/python3"

  PATH="$fake_bin:$PATH" DJ_REAL_PYTHON="$real_python" \
    DJ_RACE_ROOT="$PROJECTS/alpha" DJ_RACE_HOME="$TRELLIS_HOME" \
    run_dj --apply --yes --scopes caches </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped (plan changed)"* ]] || { echo "$output"; false; }
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "apply skips a cache when its registry status becomes detached after planning" {
  local fake_bin="$SANDBOX/status-race-bin" real_python
  git_init_at "$PROJECTS/alpha"
  make_cache "$PROJECTS/alpha" ".next/cache" "$STALE_TOUCH"
  real_python="$(command -v python3)"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/python3" <<'EOF'
#!/bin/sh
"$DJ_REAL_PYTHON" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${1:-}" = "-" ] &&
   [ "${2:-}" = "$DJ_RACE_ROOT" ] && [ ! -e "$DJ_RACE_HOME/status-raced" ]; then
  : > "$DJ_RACE_HOME/status-raced"
  proposal="$DJ_RACE_HOME/registry.detached"
  jq --arg key "$DJ_RACE_KEY" '.projects[$key].status = "detached"' \
    "$DJ_RACE_HOME/registry.json" > "$proposal" || exit 74
  chmod 600 "$proposal"
  mv "$proposal" "$DJ_RACE_HOME/registry.json"
fi
exit "$rc"
EOF
  chmod +x "$fake_bin/python3"

  PATH="$fake_bin:$PATH" DJ_REAL_PYTHON="$real_python" \
    DJ_RACE_ROOT="$PROJECTS/alpha" DJ_RACE_HOME="$TRELLIS_HOME" \
    DJ_RACE_KEY="personal/alpha" \
    run_dj --apply --yes --scopes caches </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped (plan changed)"* ]] || { echo "$output"; false; }
  [ -d "$PROJECTS/alpha/.next/cache" ]
}

@test "apply skips a worktree made dirty after its delete plan" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  local wt="$PROJECTS/alpha/.claude/worktrees/feat-x"
  local fake_bin="$SANDBOX/worktree-race-bin" real_git
  git_init_at "$PROJECTS/alpha"
  add_worktree "$PROJECTS/alpha" "$wt" "feat/x"
  real_git="$(command -v git)"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<EOF
#!/bin/sh
if [ "\${1-}" = "-C" ] && [ "\${2-}" = "\$DJ_RACE_WT" ] &&
   [ "\${3-}" = "worktree" ] && [ "\${4-}" = "list" ] &&
   [ "\${5-}" = "--porcelain" ] && [ "\${6-}" != "-z" ]; then
  "$real_git" "\$@"
  rc=\$?
  if [ -e "\$DJ_RACE_STATE" ]; then
    printf 'late write\n' > "\$DJ_RACE_WT/late-uncommitted.txt"
  else
    : > "\$DJ_RACE_STATE"
  fi
  exit "\$rc"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" DJ_RACE_WT="$wt" DJ_RACE_STATE="$SANDBOX/worktree-race" \
    DJ_MERGED_OVERRIDE=merged run_dj --apply --yes --scopes worktrees </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped (plan changed): $wt"* ]] || { echo "$output"; false; }
  [ -f "$wt/late-uncommitted.txt" ]
  [ -d "$wt" ]
}

@test "Docker apply deletes only its exact planned anonymous volume IDs" {
  local fake_bin="$SANDBOX/docker-bin" log="$SANDBOX/docker.log"
  local volume_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
case "${1:-}:${2:-}" in
  info:) exit 0 ;;
  version:--format) printf '23.0.0\n' ;;
  system:df)
    if [ "${3:-}" = "-v" ]; then
      printf '{"Volumes":[{"Name":"%s","Links":"0","Size":"1MB"}]}\n' "$DJ_DOCKER_ID_ONE"
    else
      printf '%s\n' '{"Type":"Images","TotalCount":"2"}'
    fi
    ;;
  buildx:du) printf '%s\n' '{"Reclaimable":true,"Size":"3MB"}' ;;
  buildx:prune) printf 'buildx:%s\n' "$*" >> "$DJ_DOCKER_LOG" ;;
  volume:inspect) printf '%s\n' "${5:-}" ;;
  ps:-a) : ;;
  volume:rm) printf 'rm:%s\n' "${3:-}" >> "$DJ_DOCKER_LOG" ;;
  volume:prune) printf 'broad-prune\n' >> "$DJ_DOCKER_LOG" ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 72 ;;
esac
EOF
  chmod +x "$fake_bin/docker"

  PATH="$fake_bin:$PATH" DJ_DOCKER_LOG="$log" DJ_DOCKER_ID_ONE="$volume_id" \
    run_dj --apply --yes --scopes docker </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker volume rm $volume_id"* ]] || { echo "$output"; false; }

  run cat "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rm:$volume_id"* ]] || { echo "$output"; false; }
  [[ "$output" == *"buildx:buildx prune"* ]] || { echo "$output"; false; }
  [[ "$output" != *"broad-prune"* ]] || { echo "$output"; false; }
}

@test "Docker apply exits nonzero when an exact planned volume refusal is not an attachment race" {
  local fake_bin="$SANDBOX/docker-bin"
  local volume_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
case "${1:-}:${2:-}" in
  info:) exit 0 ;;
  version:--format) printf '23.0.0\n' ;;
  system:df)
    if [ "${3:-}" = "-v" ]; then
      printf '{"Volumes":[{"Name":"%s","Links":"0","Size":"1MB"}]}\n' "$DJ_DOCKER_ID_ONE"
    else
      printf '%s\n' '{"Type":"Images","TotalCount":"2"}'
    fi
    ;;
  buildx:du) printf '%s\n' '{"Reclaimable":true,"Size":"3MB"}' ;;
  buildx:prune) : ;;
  volume:inspect) printf '%s\n' "${5:-}" ;;
  ps:-a) : ;;
  volume:rm) exit 1 ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 72 ;;
esac
EOF
  chmod +x "$fake_bin/docker"

  PATH="$fake_bin:$PATH" DJ_DOCKER_ID_ONE="$volume_id" \
    run_dj --apply --yes --scopes docker </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED/failed planned Docker volume removal: $volume_id"* ]] || { echo "$output"; false; }
}

@test "Docker apply treats only a proven post-plan attachment as a benign remove race" {
  local fake_bin="$SANDBOX/docker-bin" race="$SANDBOX/volume-attached"
  local volume_id="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
case "${1:-}:${2:-}" in
  info:) exit 0 ;;
  version:--format) printf '23.0.0\n' ;;
  system:df)
    if [ "${3:-}" = "-v" ]; then
      printf '{"Volumes":[{"Name":"%s","Links":"0","Size":"1MB"}]}\n' "$DJ_DOCKER_ID_ONE"
    else
      printf '%s\n' '{"Type":"Images","TotalCount":"2"}'
    fi
    ;;
  buildx:du) printf '%s\n' '{"Reclaimable":true,"Size":"3MB"}' ;;
  buildx:prune) : ;;
  volume:inspect) printf '%s\n' "${5:-}" ;;
  ps:-a)
    if [ -f "$DJ_DOCKER_RACE" ]; then
      printf '%s\n' 'container-now-attached'
    fi
    ;;
  volume:rm) : > "$DJ_DOCKER_RACE"; exit 1 ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 72 ;;
esac
EOF
  chmod +x "$fake_bin/docker"

  PATH="$fake_bin:$PATH" DJ_DOCKER_ID_ONE="$volume_id" DJ_DOCKER_RACE="$race" \
    run_dj --apply --yes --scopes docker </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped planned Docker volume (benign attachment race): $volume_id"* ]] || { echo "$output"; false; }
}
