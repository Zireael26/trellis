#!/usr/bin/env bats
# Focused coverage for the shared blacklist parser and the M5 fleet mutators.
# Fixtures use the current blacklist.md headings and include a populated
# temporary-exclusions row so the latent audit failure cannot regress silently.

# shellcheck source=../lib/blacklist-parser.sh
source "$BATS_TEST_DIRNAME/../lib/blacklist-parser.sh"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BLACKLIST_FIXTURE="$BATS_TEST_TMPDIR/blacklist.md"
}

write_populated_blacklist() {
  cat > "$BLACKLIST_FIXTURE" <<'EOF'
# Blacklist

## 1. Temporarily excluded (registered projects)

| Project | Reason | Added | Review after |
|---|---|---|---|
| temp-excluded | fixture pause | 2026-07-14 | 2026-07-21 |
| temp_project.2 | second fixture | 2026-07-14 | 2026-07-21 |

## 2. Permanently excluded from management

| Path | Reason |
|---|---|
| `/personal/permanent-excluded` | fixture |
| `/personal/permanent.project-2` | fixture |

---

## Semantics

| should-not-parse | outside blacklist sections |
EOF
}

@test "current temporary and permanent headings emit registry-compatible names" {
  write_populated_blacklist

  run read_blacklist_names "$BLACKLIST_FIXTURE"

  [ "$status" -eq 0 ]
  [ "$output" = $'temp-excluded\ntemp_project.2\npermanent-excluded\npermanent.project-2' ]
}

@test "placeholder-only current sections and a missing file emit nothing" {
  cat > "$BLACKLIST_FIXTURE" <<'EOF'
## 1. Temporarily excluded (registered projects)

| Project | Reason | Added | Review after |
|---|---|---|---|
| — | — | — | — |

## 2. Permanently excluded from management

| Path | Reason |
|---|---|
| — | — |

## Semantics
EOF

  run read_blacklist_names "$BLACKLIST_FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run read_blacklist_names "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Fleet-mutator exclusion after the cutover.
#
# The two cases replaced here were stale before this change and RED at HEAD
# 38f1291 (verified by stashing): they drove the mutators through a tracked
# `registry.md`/`blacklist.md` pair and a `trellis_root`-shaped config, both of
# which T17/T18 had already replaced with the local registry. T32 removed the
# tracked files outright, so the contract they asserted no longer exists in any
# form.
#
# The contract that DOES exist: legacy exclusions are imported onto the registry
# row as `metadata.legacy.blacklisted`, the listing surfaces that as `.excluded`,
# and every fleet mutator skips such a row by key. That is what is pinned below,
# against a temporary TRELLIS_HOME — never the operator's real one.
# ---------------------------------------------------------------------------

make_excluded_fleet_home() {
  local base
  base="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  LOCAL_HOME="$base/home/.trellis"
  PROJECTS="$base/projects"
  EXCLUDED_PROJECT="$PROJECTS/temp-excluded"
  mkdir -p "$LOCAL_HOME/locks" "$LOCAL_HOME/state" "$LOCAL_HOME/releases" "$EXCLUDED_PROJECT"
  chmod 700 "$LOCAL_HOME" "$LOCAL_HOME/locks" "$LOCAL_HOME/state" "$LOCAL_HOME/releases"
  printf 'excluded sentinel\n' > "$EXCLUDED_PROJECT/unchanged.txt"
  git -C "$EXCLUDED_PROJECT" init -q -b main
  git -C "$EXCLUDED_PROJECT" add unchanged.txt
  git -C "$EXCLUDED_PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm init

  local identity checkout_id worktree_id common
  identity="$(bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; local_registry_identity_for_root "$2"' _ "$REPO_ROOT" "$EXCLUDED_PROJECT")"
  checkout_id="$(printf '%s\n' "$identity" | jq -r .checkout_id)"
  worktree_id="$(printf '%s\n' "$identity" | jq -r .worktree_id)"
  common="$(printf '%s\n' "$identity" | jq -r .git_common_dir)"

  printf '{"schema_version":2,"harnesses":["claude"]}\n' > "$base/trellis.config.json"
  cat > "$LOCAL_HOME/config.json" <<EOF
{"schema_version":1,"source_root":"$REPO_ROOT","release_remote":"$REPO_ROOT","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$PROJECTS"]}}}
EOF
  chmod 600 "$LOCAL_HOME/config.json"
  cat > "$LOCAL_HOME/registry.json" <<EOF
{"schema_version":1,"projects":{"personal/temp-excluded":{"fleet":"personal","project_id":"temp-excluded","status":"active","metadata":{"legacy":{"blacklisted":true}},"checkouts":{"$checkout_id":{"root":"$EXCLUDED_PROJECT","git_common_dir":"$common","release":"1.2.3","harnesses":["claude"],"worktrees":{"$worktree_id":{"root":"$EXCLUDED_PROJECT"}}}}}},"discovery_ignores":{}}
EOF
  chmod 600 "$LOCAL_HOME/registry.json"
}

@test "every fleet mutator skips an excluded local registry row in dry-run mode" {
  local script before after before_sha after_sha
  local mutators=(
    rollout-presets.sh
    rollout-settings.sh
    rollout-rebrand.sh
    rollout-builder-skills.sh
    rollout-debrief-skill.sh
    rollout-feature-skills.sh
    rollout-orchestrate-skill.sh
    rollout-process-gate-skill.sh
    rollout-writing-skill.sh
  )

  make_excluded_fleet_home
  before="$(find "$EXCLUDED_PROJECT" -print | LC_ALL=C sort)"
  before_sha="$(shasum -a 256 "$EXCLUDED_PROJECT/unchanged.txt" | awk '{print $1}')"

  for script in "${mutators[@]}"; do
    run env TRELLIS_HOME="$LOCAL_HOME" \
      TRELLIS_CONFIG="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/trellis.config.json" \
      /bin/bash "$REPO_ROOT/scripts/$script" --dry-run --yes
    # The skip line's wording varies by script ("excluded", "excluded local
    # row", "excluded local registry row"); what every one of them must do is
    # name the row and say it was skipped.
    if ! grep -qE 'skip \(excluded[^)]*\): personal/temp-excluded' <<<"$output"; then
      echo "$script did not skip the excluded row (status $status)"
      echo "$output"
      return 1
    fi
  done

  # The excluded checkout is byte-identical: a skip is a skip, not a partial run.
  after="$(find "$EXCLUDED_PROJECT" -print | LC_ALL=C sort)"
  after_sha="$(shasum -a 256 "$EXCLUDED_PROJECT/unchanged.txt" | awk '{print $1}')"
  [ "$after" = "$before" ] && [ "$after_sha" = "$before_sha" ]
}

@test "no fleet script resolves a tracked blacklist, and the parser has exactly one definition" {
  local script
  # doctor.sh is deliberately absent: its explicit legacy diagnosis mode still
  # reads `$CANON/blacklist.md`, where $CANON is the OPERATOR-SUPPLIED legacy
  # checkout named by TRELLIS_CONFIG — not this repository. That is the one
  # surviving read, and it is asserted separately below.
  local consumers=(
    disk-janitor.sh
    rollout-presets.sh
    rollout-settings.sh
    rollout-rebrand.sh
    rollout-builder-skills.sh
    rollout-debrief-skill.sh
    rollout-feature-skills.sh
    rollout-orchestrate-skill.sh
    rollout-process-gate-skill.sh
    rollout-writing-skill.sh
  )

  for script in "${consumers[@]}"; do
    # Nothing may reconstruct a repository-relative blacklist path: the tracked
    # file is gone, and a script that rebuilt one would silently exclude nothing
    # while looking like it still honoured exclusions.
    if grep -qE '(ROOT|CANON|SOURCE_ROOT)[^ ]*/blacklist\.md' "$REPO_ROOT/scripts/$script"; then
      echo "$script still resolves a tracked blacklist path"
      grep -nE '(ROOT|CANON|SOURCE_ROOT)[^ ]*/blacklist\.md' "$REPO_ROOT/scripts/$script"
      return 1
    fi
    if grep -q '^read_blacklist_names()' "$REPO_ROOT/scripts/$script"; then
      echo "$script declares an inline blacklist parser"
      return 1
    fi
  done

  # doctor.sh is the ONE remaining consumer, and only in explicit legacy
  # diagnosis mode against an operator-supplied checkout. It must reach the
  # parser through the shared library, never an inline copy, and it must resolve
  # the file under the legacy canonical root it was handed.
  grep -qF '. "$SCRIPT_DIR/lib/blacklist-parser.sh"' "$REPO_ROOT/scripts/doctor.sh"
  grep -qF 'BLACKLIST="$CANON/blacklist.md"' "$REPO_ROOT/scripts/doctor.sh"
  run grep -q '^read_blacklist_names()' "$REPO_ROOT/scripts/doctor.sh"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^read_blacklist_names()' "$REPO_ROOT/scripts/lib/blacklist-parser.sh")" -eq 1 ]

  # And the repository itself tracks neither file any more.
  [ ! -e "$REPO_ROOT/blacklist.md" ]
  [ ! -e "$REPO_ROOT/registry.md" ]
}
