#!/usr/bin/env bats
# Tests for check-pr.sh — branch-name allowlist, fail-closed range checks, and
# retirement of the flat PR line-count cap (docs/adr/2026-11-17-retire-pr-size-cap.md).
# Subject-regex coverage lives in check-pr-subject.bats.
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
    git commit --allow-empty -q -m "chore: init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "${PROJECT_DIR:?}"
  fi
}

check_branch() {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b "$1"
    git commit --allow-empty -q -m "chore: work"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

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

@test "branch: 'pi-agent-worker-123' passes (pi worker branch)" {
  check_branch "pi-agent-worker-123"
  [ "$status" -eq 0 ]
}

@test "branch: obsolete 'pi-agent/probe' form warns" {
  check_branch "pi-agent/probe"
  [ "$status" -eq 2 ]
  grep -Fq 'does not match <type>/<kebab-slug>' <<<"$output"
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

# --- range & retired PR size cap -------------------------------------------

@test "range: invalid range fails closed" {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/invalid-range
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 50
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: bulk"
  )

  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=missing-base..HEAD"
  [ "$status" -eq 1 ]
  grep -Fq 'process-gate cannot resolve the base of range missing-base..HEAD' <<<"$output"

  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD..missing-head"
  [ "$status" -eq 1 ]
  grep -Fq 'unable to enumerate commit subjects for range HEAD..missing-head' <<<"$output"
}

@test "branch: running outside a repository fails closed" {
  local outside_dir
  outside_dir="$(mktemp -d)"

  run bash -c "cd '$outside_dir' && '$SCRIPT' --range=HEAD~1..HEAD"
  rm -rf "${outside_dir:?}"

  [ "$status" -eq 1 ]
  grep -Fq 'process-gate cannot resolve the base of range HEAD~1..HEAD' <<<"$output"
}

@test "size: large diff passes without requiring a waiver ADR and tolerates legacy size config keys" {
  mkdir -p "$PROJECT_DIR/.claude/skills/process-gate-local"
  printf '%s\n' 'PROCESS_GATE_PR_SIZE_LIMIT=10' 'PROCESS_GATE_PR_SIZE_HARD=20' \
    > "$PROJECT_DIR/.claude/skills/process-gate-local/local.config.sh"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm "chore: legacy size config"
  git -C "$PROJECT_DIR" checkout -q -b feat/large-clean-pr
  write_bulk "$PROJECT_DIR/src/feature.ts" 1500
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm "feat: cohesive large change"

  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Fq 'pass PR hygiene' <<<"$output"
}
