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

@test "all M5 mutators skip a populated temporary exclusion in dry-run mode" {
  local instance="$BATS_TEST_TMPDIR/instance"
  local projects="$BATS_TEST_TMPDIR/projects"
  local excluded_project="$projects/temp-excluded"
  local active_project="$projects/active-project"
  local script before after before_sha after_sha
  local mutators=(
    rollout-presets.sh
    sync-hooks.sh
    sync-codex-hooks.sh
    sync-merge-gate.sh
    rollout-settings.sh
    rollout-rebrand.sh
    rollout-builder-skills.sh
    rollout-codex-worker-agent.sh
    rollout-debrief-skill.sh
    rollout-feature-skills.sh
    rollout-orchestrate-skill.sh
    rollout-process-gate-skill.sh
    rollout-writing-skill.sh
  )

  mkdir -p "$instance" "$excluded_project" "$active_project/.git"
  ln -s "$REPO_ROOT/core-rules" "$instance/core-rules"
  printf 'excluded sentinel\n' > "$excluded_project/unchanged.txt"
  printf 'active sentinel\n' > "$active_project/unchanged.txt"
  cat > "$instance/registry.md" <<'EOF'
## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| temp-excluded | `/personal/temp-excluded` | app | fixture |
| active-project | `/personal/active-project` | app | control |

---
EOF
  write_populated_blacklist
  cp "$BLACKLIST_FIXTURE" "$instance/blacklist.md"
  cat > "$instance/trellis.config.json" <<EOF
{
  "trellis_root": "$instance",
  "projects_root": "$projects",
  "user_home": "$BATS_TEST_TMPDIR",
  "maintainer_name": "Test Maintainer",
  "github_user": "testuser",
  "harnesses": ["claude", "codex"]
}
EOF

  before="$(find "$excluded_project" -print | LC_ALL=C sort)"
  before_sha="$(shasum -a 256 "$excluded_project/unchanged.txt" | awk '{print $1}')"

  for script in "${mutators[@]}"; do
    run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      TRELLIS_CONFIG="$instance/trellis.config.json" \
      /bin/bash "$REPO_ROOT/scripts/$script" --dry-run --yes
    if [ "$status" -ne 0 ]; then
      echo "$script failed with status $status"
      echo "$output"
      return 1
    fi
    if ! grep -qF 'skip (blacklisted): temp-excluded' <<<"$output"; then
      echo "$script did not skip the populated temporary exclusion"
      echo "$output"
      return 1
    fi
  done

  after="$(find "$excluded_project" -print | LC_ALL=C sort)"
  after_sha="$(shasum -a 256 "$excluded_project/unchanged.txt" | awk '{print $1}')"
  [ "$after" = "$before" ] && [ "$after_sha" = "$before_sha" ]
}

@test "doctor, disk janitor, and every M5 mutator source the one shared parser" {
  local script
  local consumers=(
    doctor.sh
    disk-janitor.sh
    rollout-presets.sh
    sync-hooks.sh
    sync-codex-hooks.sh
    sync-merge-gate.sh
    rollout-settings.sh
    rollout-rebrand.sh
    rollout-builder-skills.sh
    rollout-codex-worker-agent.sh
    rollout-debrief-skill.sh
    rollout-feature-skills.sh
    rollout-orchestrate-skill.sh
    rollout-process-gate-skill.sh
    rollout-writing-skill.sh
  )

  for script in "${consumers[@]}"; do
    if ! grep -qF '. "$SCRIPT_DIR/lib/blacklist-parser.sh"' "$REPO_ROOT/scripts/$script"; then
      echo "$script does not source the shared parser"
      return 1
    fi
    if grep -q '^read_blacklist_names()' "$REPO_ROOT/scripts/$script"; then
      echo "$script still declares an inline blacklist parser"
      return 1
    fi
  done
}
