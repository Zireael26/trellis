#!/usr/bin/env bats
# Spec 073: Trellis drives Herdr only through herdr-core (`hc`). No live file
# may call the old `herdr` CLI or read its HERDR_* environment. Dated history
# (CHANGELOG, UPGRADING, ADRs, design notes, specs, audits) keeps its record.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

live_files() {
  git -C "$REPO_ROOT" ls-files -- core-rules scripts .pi AGENT_PI_SETUP.md gotchas.md docs \
    ':!docs/UPGRADING.md' ':!docs/adr' ':!docs/specs' ':!docs/plans'
}

@test "no live file calls the old herdr CLI" {
  # Only this suite, the foreman grep test and the old-format rejection tests may
  # spell the old names.
  local hits
  hits="$(cd "$REPO_ROOT" && live_files | xargs grep -nIE '\bherdr (pane|agent|tab|workspace|machine|server)\b' -- 2>/dev/null |
    grep -vE '^(scripts/tests/no-legacy-herdr\.bats|core-rules/skills/herdr-foreman/tests/foreman-start-hc\.bats|core-rules/hooks/tests/pi-review-route\.bats):' || true)"
  [ -z "$hits" ] || { echo "$hits"; false; }
}

@test "no live file reads HERDR_* except tests proving it is ignored" {
  local hits
  hits="$(cd "$REPO_ROOT" && live_files | xargs grep -nIE 'HERDR_' -- 2>/dev/null |
    grep -vE '^(scripts/tests/no-legacy-herdr\.bats|core-rules/skills/herdr-foreman/tests/foreman-start-hc\.bats|core-rules/hooks/tests/herdr-foreman-session-validator\.bats|core-rules/hooks/tests/pi-review-route\.bats):' || true)"
  [ -z "$hits" ] || { echo "$hits"; false; }
}

@test "the exemptions still exercise the old variables they are exempt for" {
  grep -q 'HERDR_ENV=1' "$REPO_ROOT/core-rules/hooks/tests/herdr-foreman-session-validator.bats"
  grep -q 'HERDR_ENV=1' "$REPO_ROOT/core-rules/skills/herdr-foreman/tests/foreman-start-hc.bats"
  grep -q 'HERDR_ENV=1' "$REPO_ROOT/core-rules/hooks/tests/pi-review-route.bats"
  grep -q 'herdr_workspace_id' "$REPO_ROOT/core-rules/hooks/tests/pi-review-route.bats"
}
