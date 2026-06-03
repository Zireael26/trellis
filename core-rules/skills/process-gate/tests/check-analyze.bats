#!/usr/bin/env bats
# Tests for check-analyze.sh — deterministic specs/NNN-*/analyze.md gate.
#
# LOAD-BEARING INVARIANT: this gate NEVER exits 1. analyze is advisory, so it
# must never BLOCK a merge — only pass (0) or warn (2). The trap it must dodge:
# common.sh sets `set -euo pipefail`, and the no-spec-touched case relies on a
# grep that exits 1 (no match); without `set +e` that would abort with exit 1
# and BLOCK every normal merge. These tests pin that invariant head-on.
#
# Approach mirrors the other process-gate bats: a throwaway fixture repo with
# an initial empty commit, then a second commit per test, run against
# HEAD~1..HEAD. analyze.md (when present) is committed INSIDE the spec dir so
# the dir shows up as touched in the range.
#
# Exit codes: 0=pass, 2=warn (NEVER 1).

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-analyze.sh"
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

# Commit a set of files (relpath + content pairs) and run the gate against the
# resulting one-commit range.
commit_and_check() {
  (
    cd "$PROJECT_DIR"
    while [ "$#" -ge 2 ]; do
      mkdir -p "$(dirname "$1")"
      printf "%s" "$2" > "$1"
      git add "$1"
      shift 2
    done
    git commit -q -m "spec change"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

# --- no spec dir touched -> pass (and NEVER 1, the set -e + grep-no-match trap) ---

@test "no spec dir touched -> pass (exit 0)" {
  commit_and_check "src/app.ts" $'export const x = 1;\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no spec dir touched"* ]]
}

@test "no spec dir touched -> NEVER exits 1 (set -e / grep-no-match invariant)" {
  commit_and_check "README.md" $'# hi\n'
  [ "$status" -ne 1 ]
  [ "$status" -eq 0 ]
}

# --- verdict mapping ---

@test "analyze Verdict: PASS -> pass (exit 0)" {
  commit_and_check \
    "specs/001-feature/spec.md"    $'# spec\n' \
    "specs/001-feature/analyze.md" $'# Analyze\n\n## Verdict: PASS\n'
  [ "$status" -eq 0 ]
}

@test "analyze Verdict: NEEDS-REVISION -> warn (exit 2)" {
  commit_and_check \
    "specs/001-feature/spec.md"    $'# spec\n' \
    "specs/001-feature/analyze.md" $'# Analyze\n\n## Verdict: NEEDS-REVISION\n'
  [ "$status" -eq 2 ]
  [[ "$output" == *"NEEDS-REVISION"* ]]
}

@test "analyze Verdict: BLOCKED -> warn (exit 2), NEVER 1" {
  commit_and_check \
    "specs/001-feature/spec.md"    $'# spec\n' \
    "specs/001-feature/analyze.md" $'# Analyze\n\n## Verdict: BLOCKED\n'
  # The load-bearing invariant: even a BLOCKED analyze verdict must not BLOCK
  # the merge. Worst it can do is warn.
  [ "$status" -eq 2 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "analyze.md missing for touched spec dir -> warn (exit 2)" {
  commit_and_check "specs/002-thing/spec.md" $'# spec\n'
  [ "$status" -eq 2 ]
  [[ "$output" == *"analyze not run for specs/002-thing"* ]]
}

@test "analyze.md present but no recognizable Verdict line -> warn (exit 2), NEVER 1" {
  commit_and_check \
    "specs/004-noverdict/spec.md"    $'# spec\n' \
    "specs/004-noverdict/analyze.md" $'# Analyze\n\nsome notes, no verdict header\n'
  [ "$status" -eq 2 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"no recognizable"* ]]
}

# --- worst-across-dirs ---

@test "two spec dirs, one PASS one missing -> warn (worst wins)" {
  commit_and_check \
    "specs/001-ok/spec.md"      $'# spec\n' \
    "specs/001-ok/analyze.md"   $'## Verdict: PASS\n' \
    "specs/003-bad/spec.md"     $'# spec\n'
  [ "$status" -eq 2 ]
  [[ "$output" == *"analyze not run for specs/003-bad"* ]]
}

@test "two spec dirs, both PASS -> pass (exit 0)" {
  commit_and_check \
    "specs/001-ok/spec.md"     $'# spec\n' \
    "specs/001-ok/analyze.md"  $'## Verdict: PASS\n' \
    "specs/002-ok/spec.md"     $'# spec\n' \
    "specs/002-ok/analyze.md"  $'## Verdict: PASS\n'
  [ "$status" -eq 0 ]
}
