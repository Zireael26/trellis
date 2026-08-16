#!/usr/bin/env bats
# Tests for check-pr.sh — branch-name allowlist (line 24) and the PR-size ADR
# exception (lines 71-97). Subject-regex coverage lives in check-pr-subject.bats.
#
# Two defects are pinned here:
#   1. `feature/<slug>` was rejected while the spec/plan/tasks skills mandate it,
#      so every branch produced by the canonical pipeline failed the gate.
#   2. The ADR exception was unbounded — any `docs/adr/*.md` appearing anywhere in
#      the range disarmed the hard cap, and did so silently (the row read `pass`).
#      It now requires an ADR *added* by the range, and downgrades to `warn`.
#
# Exit codes are pg_exit_code's: 0=pass, 1=fail, 2=warn.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-pr.sh"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Check the working branch with an empty range, so only the branch-name rule can speak.
check_branch() {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b "$1"
    git commit --allow-empty -q -m "chore: work"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

# Write a file of <lines> numbered lines. Each line is unique so git cannot
# collapse it, keeping the counted diff honest.
write_bulk() {
  local path="$1" lines="$2" i=1
  mkdir -p "$(dirname "$path")"
  : > "$path"
  while [ "$i" -le "$lines" ]; do
    printf 'line %s of %s\n' "$i" "$path" >> "$path"
    i=$((i + 1))
  done
}

# --- branch name -----------------------------------------------------------

@test "branch: 'feature/portable-multi-fleet-setup' passes (spec skill mandates it)" {
  check_branch "feature/portable-multi-fleet-setup"
  [ "$status" -eq 0 ]
}

@test "branch: 'feat/short-slug' still passes (feature did not shadow feat)" {
  check_branch "feat/short-slug"
  [ "$status" -eq 0 ]
}

@test "branch: 'featureish/thing' warns (allowlist is anchored, not a prefix match)" {
  check_branch "featureish/thing"
  [ "$status" -eq 2 ]
  grep -Fq 'does not match <type>/<kebab-slug>' <<<"$output"
}

@test "branch: 'nonsense/thing' still warns" {
  check_branch "nonsense/thing"
  [ "$status" -eq 2 ]
  grep -Fq 'does not match <type>/<kebab-slug>' <<<"$output"
}

# --- PR size / ADR exception ----------------------------------------------

@test "size: oversized range with no ADR fails" {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/big
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 900
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: bulk"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  grep -Fq 'hard cap 800' <<<"$output"
  grep -Fq 'split, or add an ADR' <<<"$output"
}

@test "size: oversized range with an ADR ADDED in range warns and names the ADR" {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/big-with-adr
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 900
  mkdir -p "$PROJECT_DIR/docs/adr"
  printf '# ADR\n\nSplitting this cutover would break rollback.\n' \
    > "$PROJECT_DIR/docs/adr/0001-indivisible-cutover.md"
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: bulk with adr"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 2 ]
  grep -Fq 'ADR exception: docs/adr/0001-indivisible-cutover.md' <<<"$output"
  grep -Fq 'record reviewer ack' <<<"$output"
}

@test "size: a pre-existing ADR merely EDITED in range does not disarm the cap" {
  mkdir -p "$PROJECT_DIR/docs/adr"
  printf '# ADR\n\nUnrelated, landed long ago.\n' \
    > "$PROJECT_DIR/docs/adr/0001-unrelated.md"
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "docs: unrelated adr"
    git checkout -q -b feat/big-touching-old-adr
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 900
  printf 'One incidental line.\n' >> "$PROJECT_DIR/docs/adr/0001-unrelated.md"
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: bulk touching old adr"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  grep -Fq 'split, or add an ADR' <<<"$output"
  if grep -Fq 'ADR exception' <<<"$output"; then
    echo "the edited-only ADR was accepted as an exception"; echo "$output"; false
  fi
}

@test "size: a mid-band range still warns with reviewer-ack wording" {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/medium
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 500
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: medium"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 2 ]
  grep -Fq 'request reviewer ack in PR description' <<<"$output"
}

@test "size: a small range passes and reports its line count" {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/small
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 10
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: small"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  grep -Fq '10 lines' <<<"$output"
}
