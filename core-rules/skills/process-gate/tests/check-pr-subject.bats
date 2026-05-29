#!/usr/bin/env bats
# Tests for check-pr.sh — Conventional Commits subject regex (line 35).
# Covers:
#   - Audit-closure: `!` breaking-change marker (scoped + unscoped) accepted;
#     empty scope `feat(): subject` rejected.
#   - Real defect: `codex` type is allowed on commit subjects, matching the
#     branch-name allowlist on line 24.
#
# Approach: each test stages a single commit on top of a clean fixture repo
# and invokes `check-pr.sh --range=HEAD~1..HEAD`, so the subject check is
# isolated from branch-name and PR-size gates.
#   - HEAD stays on `main` so branch-name check short-circuits (lines 21–22).
#   - `--allow-empty` keeps PR size at 0/0, so the size gate is satisfied.
#   - CLAUDE_PROJECT_DIR is pointed at the fixture so no host config leaks in.

setup() {
  # BATS_TEST_FILENAME is set by bats to the real path of this .bats file
  # (top-level $BASH_SOURCE[0] is unreliable across bats releases).
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

# Commit a single empty commit with the given subject, then run check-pr.sh
# against just that commit. Exit code: 0=pass, 1=fail, 2=warn (per pg_exit_code).
commit_and_check() {
  local subject="$1"
  (
    cd "$PROJECT_DIR"
    git commit --allow-empty -q -m "$subject"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

@test "audit-closure: 'feat!: bang' passes (breaking-change marker, no scope)" {
  commit_and_check "feat!: bang"
  [ "$status" -eq 0 ]
}

@test "audit-closure: 'fix(api)!: scoped bang' passes (breaking-change marker, scoped)" {
  commit_and_check "fix(api)!: scoped bang"
  [ "$status" -eq 0 ]
}

@test "audit-closure: 'feat(): empty' fails (empty scope is invalid)" {
  commit_and_check "feat(): empty"
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit-subject"* ]]
}

@test "codex-fix: 'codex: subject' passes (unscoped)" {
  commit_and_check "codex: subject"
  [ "$status" -eq 0 ]
}

@test "codex-fix: 'codex(scope): subject' passes (scoped)" {
  commit_and_check "codex(scope): subject"
  [ "$status" -eq 0 ]
}

@test "baseline: 'feat: subject' passes" {
  commit_and_check "feat: subject"
  [ "$status" -eq 0 ]
}

@test "baseline: 'random: subject' fails (unknown type)" {
  commit_and_check "random: subject"
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit-subject"* ]]
}

@test "baseline: 'feat:nospace' fails (missing space after colon)" {
  commit_and_check "feat:nospace"
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit-subject"* ]]
}
