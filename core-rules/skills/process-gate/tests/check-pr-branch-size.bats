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

# Commit a fixture and run the checker over exactly that commit.
commit_and_check() {
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: fixture change'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
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

# --- PR size / ADR exception ----------------------------------------------

@test "range: invalid range with oversized change fails every Git enumeration closed" {
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/invalid-range
  )
  write_bulk "$PROJECT_DIR/bulk.txt" 900
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "feat: bulk"
  )

  # A missing base now fails at config load (gate config loads from the base);
  # a missing end still reaches every git read below.
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=missing-base..HEAD"
  [ "$status" -eq 1 ]
  grep -Fq 'process-gate cannot resolve the base of range missing-base..HEAD' <<<"$output"

  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD..missing-head"
  [ "$status" -eq 1 ]
  grep -Fq 'unable to enumerate commit subjects for range HEAD..missing-head' <<<"$output"
  grep -Fq 'unable to compute diff stats for range HEAD..missing-head' <<<"$output"
  grep -Fq 'unable to enumerate changed files for range HEAD..missing-head' <<<"$output"
  grep -Fq 'unable to enumerate added files for range HEAD..missing-head' <<<"$output"
}

@test "branch: running outside a repository fails closed" {
  local outside_dir
  outside_dir="$(mktemp -d)"

  run bash -c "cd '$outside_dir' && '$SCRIPT' --range=HEAD~1..HEAD"
  rm -rf "${outside_dir:?}"

  [ "$status" -eq 1 ]
  grep -Fq 'process-gate cannot resolve the base of range HEAD~1..HEAD' <<<"$output"
}

@test "size: oversized range with no ADR fails" {
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
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

@test "size: lockfile exemption requires an exact basename" {
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
  git -C "$PROJECT_DIR" checkout -q -b feat/lockfile-boundary
  write_bulk "$PROJECT_DIR/src/payload_uv.lock" 900
  git -C "$PROJECT_DIR" add src/payload_uv.lock
  git -C "$PROJECT_DIR" commit -qm 'feat: oversized code'
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "suffix disguised code: $output"; false; }
  [[ "$output" == *'hard cap 800'* ]] || false

  # An actual lockfile in a nested directory remains exempt.
  write_bulk "$PROJECT_DIR/deps/uv.lock" 900
  git -C "$PROJECT_DIR" add deps/uv.lock
  git -C "$PROJECT_DIR" commit -qm 'chore: update lockfile'
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "size: oversized range with an ADR ADDED in range warns and names the ADR" {
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
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
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
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
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
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

@test "size: uv.lock lines do not count toward PR size" {
  # The fleet is uv-only: a lock refresh must not read as gated feature code.
  (
    cd "$PROJECT_DIR"
    git checkout -q -b feat/uv-refresh
  )
  write_bulk "$PROJECT_DIR/uv.lock" 900
  (
    cd "$PROJECT_DIR"
    git add -A && git commit -q -m "chore: refresh uv.lock"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  grep -Fq '0 lines' <<<"$output"
}

@test "143-pg: lockfile suffix lookalikes count while real lockfiles remain exempt" {
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
  write_bulk "$PROJECT_DIR/packages/app/uv.lock" 900
  git -C "$PROJECT_DIR" add packages/app/uv.lock
  git -C "$PROJECT_DIR" commit -qm 'chore: refresh lockfile'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  write_bulk "$PROJECT_DIR/src/parser-uv.lock" 900
  git -C "$PROJECT_DIR" add src/parser-uv.lock
  git -C "$PROJECT_DIR" commit -qm 'feat: add parser'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"900 lines > hard cap"* ]] || false
}

@test "143-pg: rename into a lockfile cannot subtract unrelated code" {
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
  write_bulk "$PROJECT_DIR/src/legacy.ts" 1500
  git -C "$PROJECT_DIR" add src/legacy.ts
  git -C "$PROJECT_DIR" commit -qm 'chore: seed legacy'
  git -C "$PROJECT_DIR" mv src/legacy.ts src/yarn.lock
  write_bulk "$PROJECT_DIR/src/new.ts" 1000
  git -C "$PROJECT_DIR" add src/new.ts
  git -C "$PROJECT_DIR" commit -qm 'feat: add code and rename'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1000 lines > hard cap"* ]] || false
  mkdir -p "$PROJECT_DIR/packages"
  git -C "$PROJECT_DIR" mv src/yarn.lock packages/yarn.lock
  write_bulk "$PROJECT_DIR/src/small.ts" 10
  git -C "$PROJECT_DIR" add src/small.ts
  git -C "$PROJECT_DIR" commit -qm 'chore: move lockfile and add small change'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"10 lines"* ]] || false
}

@test "143-pg: invalid PR size thresholds fail closed and valid decimals pass" {
  write_bulk "$PROJECT_DIR/src/small.ts" 10
  git -C "$PROJECT_DIR" add src/small.ts
  git -C "$PROJECT_DIR" commit -qm 'feat: small change'
  for var in PROCESS_GATE_PR_SIZE_LIMIT PROCESS_GATE_PR_SIZE_HARD; do
    run env "$var=800k" bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"$var"* && "$output" == *"non-negative integer"* ]] || false
  done
  run env PROCESS_GATE_PR_SIZE_LIMIT=000400 PROCESS_GATE_PR_SIZE_HARD=000800 \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env PROCESS_GATE_PR_SIZE_LIMIT=999999999999999999999999999999 \
    PROCESS_GATE_PR_SIZE_HARD=9999999999999999999999999999999 \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"integer expression expected"* && "$output" != *"integer expected"* ]] || false
}

@test "143-pg-r2: edited code renamed to a lockfile still counts" {
  export PROCESS_GATE_PR_SIZE_LIMIT=400 PROCESS_GATE_PR_SIZE_HARD=800
  write_bulk "$PROJECT_DIR/src/legacy.ts" 1000
  git -C "$PROJECT_DIR" add src/legacy.ts
  git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
  git -C "$PROJECT_DIR" mv src/legacy.ts src/yarn.lock
  python3 -I - "$PROJECT_DIR/src/yarn.lock" <<'PY'
import pathlib,sys
with pathlib.Path(sys.argv[1]).open('a') as out:
    for n in range(600): out.write(f'new code line {n}\n')
PY
  write_bulk "$PROJECT_DIR/src/new.ts" 300
  git -C "$PROJECT_DIR" add src
  git -C "$PROJECT_DIR" commit -qm 'feat: edit and rename code'
  [[ "$(git -C "$PROJECT_DIR" diff --summary HEAD~1..HEAD)" == *"rename"* ]] || false
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"900 lines > hard cap"* ]] || false
}

@test "143-pg-r2: malformed lockfile line stats fail closed" {
  write_bulk "$PROJECT_DIR/uv.lock" 50
  git -C "$PROJECT_DIR" add uv.lock
  git -C "$PROJECT_DIR" commit -qm 'chore: refresh lockfile'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local mock_bin="$BATS_TEST_TMPDIR/mock-git" real_git
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'if [ "$1" = diff ] && [ "$2" = --numstat ]; then printf "1\tbad\tuv.lock\n"; exit 0; fi' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"pr-size: unable to enumerate changed files"* ]] || false
}

@test "143-pg: malformed base-config threshold fails even for a small change" {
  mkdir -p "$PROJECT_DIR/.claude/skills/process-gate-local"
  printf '%s\n' 'PROCESS_GATE_PR_SIZE_HARD=800,000' > "$PROJECT_DIR/.claude/skills/process-gate-local/local.config.sh"
  git -C "$PROJECT_DIR" add .claude/skills/process-gate-local/local.config.sh
  git -C "$PROJECT_DIR" commit -qm 'chore: configure size'
  write_bulk "$PROJECT_DIR/src/small.ts" 10
  git -C "$PROJECT_DIR" add src/small.ts
  git -C "$PROJECT_DIR" commit -qm 'feat: small change'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"PROCESS_GATE_PR_SIZE_HARD"* && "$output" == *"non-negative integer"* ]] || false
}

@test "143-pr-size: default boundaries report countable lines on pass warn and fail" {
  local n expected
  for n in 600 601 1200 1201; do
    write_bulk "$PROJECT_DIR/src/code-$n.ts" "$n"
    commit_and_check
    case "$n" in 600) expected=0 ;; 601|1200) expected=2 ;; 1201) expected=1 ;; esac
    [ "$status" -eq "$expected" ] || { echo "$n: $output"; false; }
    [[ "$output" == *"$n lines countable"* ]] || { echo "$output"; false; }
    [[ "$output" == *"excluded: tests=0, fixtures=0, generated=0, lockfiles=0"* ]] || false
  done
}

@test "143-pr-size: overrides apply at both boundaries" {
  export PROCESS_GATE_PR_SIZE_LIMIT=10 PROCESS_GATE_PR_SIZE_HARD=20
  local n expected
  for n in 10 11 20 21; do
    write_bulk "$PROJECT_DIR/src/code-$n.ts" "$n"
    commit_and_check
    case "$n" in 10) expected=0 ;; 11|20) expected=2 ;; 21) expected=1 ;; esac
    [ "$status" -eq "$expected" ] || { echo "$n: $output"; false; }
    [[ "$output" == *"$n lines countable"* ]] || false
  done
}

@test "143-pr-size: test paths and exact filename patterns are excluded" {
  local path
  for path in tests/a.py scripts/tests/a.sh pkg/__tests__/a.js pkg/test/a.py \
    src/check.bats src/item_test.go src/item.test.ts src/item.spec.ts \
    src/item_test.py src/test_widget.py src/item.test.cjs src/item.spec.py; do
    write_bulk "$PROJECT_DIR/$path" 3
  done
  # Names resembling tests, but not in a listed directory or suffix, are code.
  write_bulk "$PROJECT_DIR/src/test_runner.sh" 17
  write_bulk "$PROJECT_DIR/src/contest.ts" 2
  write_bulk "$PROJECT_DIR/src/tests" 1
  write_bulk "$PROJECT_DIR/src/__tests__" 1
  write_bulk "$PROJECT_DIR/src/consumer_test.ts" 1
  write_bulk "$PROJECT_DIR/src/design.spec.md" 1
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"23 lines countable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"excluded: tests=36, fixtures=0, generated=0, lockfiles=0"* ]] || false
}

@test "143-pr-size: fixture and snapshot paths are excluded separately from tests" {
  local path
  for path in fixtures/a.txt tests/fixtures/a.txt pkg/__fixtures__/a.txt \
    pkg/testdata/a.txt pkg/snapshots/a.txt pkg/__snapshots__/a.txt src/view.snap; do
    write_bulk "$PROJECT_DIR/$path" 3
  done
  write_bulk "$PROJECT_DIR/src/fixtures-helper.ts" 2
  write_bulk "$PROJECT_DIR/src/fixtures" 1
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"3 lines countable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"excluded: tests=0, fixtures=21, generated=0, lockfiles=0"* ]] || false
}

@test "143-pr-size: generated markers and committed attributes are isolated from local state" {
  mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/pkg" "$PROJECT_DIR/.git/info"
  printf '%s\n' 'src/by-attr.c linguist-generated' 'src/attr-false.c -linguist-generated' 'src/attr-true.c linguist-generated=true' > "$PROJECT_DIR/.gitattributes"
  printf '%s\n' '*.c linguist-generated' > "$PROJECT_DIR/pkg/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes pkg/.gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: seed generated attributes'
  printf '%s\n' '// @generated' 'one' 'two' 'three' 'four' 'five' > "$PROJECT_DIR/src/by-marker.c"
  printf '%s\n' '// Code generated by tool. DO NOT EDIT.' 'one' 'two' 'three' 'four' 'five' > "$PROJECT_DIR/src/by-go.c"
  write_bulk "$PROJECT_DIR/src/by-attr.c" 7
  write_bulk "$PROJECT_DIR/src/attr-true.c" 2
  write_bulk "$PROJECT_DIR/pkg/nested.c" 4
  write_bulk "$PROJECT_DIR/src/attr-false.c" 3
  write_bulk "$PROJECT_DIR/src/normal.c" 4
  write_bulk "$PROJECT_DIR/src/global-only.c" 2
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: generated files'
  # Neither the worktree/index nor local Git attributes may change this range.
  printf '%s\n' '* linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  printf '%s\n' 'src/normal.c linguist-generated' > "$PROJECT_DIR/.git/info/attributes"
  printf '%s\n' 'src/global-only.c linguist-generated' > "$BATS_TEST_TMPDIR/global-attributes"
  git -C "$PROJECT_DIR" config core.attributesFile "$BATS_TEST_TMPDIR/global-attributes"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"9 lines countable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"excluded: tests=0, fixtures=0, generated=25, lockfiles=0"* ]] || false
}

@test "143-pr-size: generated deletions use base metadata" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' 'src/generated.c linguist-generated' > "$PROJECT_DIR/.gitattributes"
  write_bulk "$PROJECT_DIR/src/generated.c" 15
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed generated'
  git -C "$PROJECT_DIR" rm -q src/generated.c .gitattributes
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"1 lines countable"* ]] || false
  [[ "$output" == *"excluded: tests=0, fixtures=0, generated=15, lockfiles=0"* ]] || false
}

@test "143-pr-size: unrecognized or late generated markers still count" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '// @generatedly' 'ordinary' > "$PROJECT_DIR/src/near.c"
  write_bulk "$PROJECT_DIR/src/late.c" 20
  printf '%s\n' '// @generated' >> "$PROJECT_DIR/src/late.c"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"23 lines countable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"generated=0"* ]] || false
}

@test "143-pr-size: single revision uses base attributes and tracked working-tree markers" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' 'src/generated.c linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: seed generated attributes'
  write_bulk "$PROJECT_DIR/src/generated.c" 5
  write_bulk "$PROJECT_DIR/src/code.c" 2
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: seed generated'
  printf 'more\n' >> "$PROJECT_DIR/src/generated.c"
  printf 'more\n' >> "$PROJECT_DIR/src/code.c"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"3 lines countable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"excluded: tests=0, fixtures=0, generated=6, lockfiles=0"* ]] || false
}

@test "143-pr-size: lock lines and exclusion breakdown remain visible on warnings" {
  write_bulk "$PROJECT_DIR/src/code.ts" 601
  write_bulk "$PROJECT_DIR/yarn.lock" 10
  write_bulk "$PROJECT_DIR/tests/unit.py" 11
  write_bulk "$PROJECT_DIR/fixtures/input.txt" 12
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '// @generated' 'one' 'two' > "$PROJECT_DIR/src/generated.ts"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"601 lines countable"* ]] || false
  [[ "$output" == *"excluded: tests=11, fixtures=12, generated=3, lockfiles=10"* ]] || false
}

@test "143-pr-size: renames into every exclusion class cannot hide edited code" {
  local target i
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' 'src/generated.c linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed attributes'
  for target in tests/renamed.ts fixtures/renamed.ts src/generated.c src/by-marker.c src/yarn.lock; do
    write_bulk "$PROJECT_DIR/src/original.ts" 1000
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
    mkdir -p "$PROJECT_DIR/$(dirname "$target")"
    git -C "$PROJECT_DIR" mv src/original.ts "$target"
    if [ "$target" = src/by-marker.c ]; then
      python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(b"// @generated\n" + p.read_bytes())' "$PROJECT_DIR/$target"
      i=2
    else
      i=1
    fi
    for ((; i<=400; i++)); do printf 'extra %s\n' "$i" >> "$PROJECT_DIR/$target"; done
    commit_and_check
    [[ "$(git -C "$PROJECT_DIR" diff --summary HEAD~1..HEAD)" == *rename* ]] || { echo "not a rename: $target"; false; }
    [ "$status" -eq 0 ] || { echo "$target: $output"; false; }
    [[ "$output" == *"400 lines countable"* ]] || { echo "$target: $output"; false; }
  done
}

@test "143-pr-size: NUL-framed paths and harness entrypoints agree from a subdirectory" {
  local test_name=$'tests/edge\twith\nnewline.py' code_name=$'src/odd\twith\nnewline.c' first
  mkdir -p "$PROJECT_DIR/tests" "$PROJECT_DIR/src"
  printf 'a\nb\n' > "$PROJECT_DIR/$test_name"
  printf 'one\n' > "$PROJECT_DIR/$code_name"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: unusual filenames'
  run bash -c 'cd "$1/src" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"1 lines countable"* && "$output" == *"tests=2"* ]] || false
  first="$output"
  run env CODEX_PROJECT_DIR="$PROJECT_DIR" bash -c 'cd "$1/src" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] && [ "$output" = "$first" ] || { echo "$output"; false; }
}

@test "143-pr-size: committed metadata works in a repository path containing colons" {
  mv "$PROJECT_DIR" "${PROJECT_DIR}:with:colon"
  PROJECT_DIR="${PROJECT_DIR}:with:colon"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' 'src/generated.c linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: seed generated attributes'
  write_bulk "$PROJECT_DIR/src/generated.c" 3
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"0 lines countable"* && "$output" == *"generated=3"* ]] || false
}

@test "143-pr-size: metadata enumeration failure fails closed" {
  write_bulk "$PROJECT_DIR/src/code.c" 3
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: code'
  local mock_bin="$BATS_TEST_TMPDIR/bad-metadata" real_git
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'if [ "$1" = diff ] && [ "$2" = --raw ]; then exit 44; fi' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"unable to enumerate changed files"* ]] || false
}

@test "143-pr-size: three-dot range uses merge-base attributes" {
  printf '%s\n' 'src/generated.c linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: configure attributes'
  git -C "$PROJECT_DIR" checkout -qb feat/generated
  write_bulk "$PROJECT_DIR/src/generated.c" 8
  write_bulk "$PROJECT_DIR/src/code.c" 2
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: generated and code'
  git -C "$PROJECT_DIR" checkout -q main
  printf '%s\n' 'src/generated.c -linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: diverge attributes'
  git -C "$PROJECT_DIR" checkout -q feat/generated
  run bash -c 'cd "$1" && exec bash "$2" --range=main...HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"2 lines countable"* && "$output" == *"generated=8"* ]] || false
}

@test "143-pr-size: threshold overrides from base config are honored" {
  mkdir -p "$PROJECT_DIR/.claude/skills/process-gate-local"
  printf '%s\n' 'PROCESS_GATE_PR_SIZE_LIMIT=2' 'PROCESS_GATE_PR_SIZE_HARD=4' > "$PROJECT_DIR/.claude/skills/process-gate-local/local.config.sh"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: configure size'
  write_bulk "$PROJECT_DIR/src/code.c" 3
  commit_and_check
  [ "$status" -eq 2 ] && [[ "$output" == *"3 lines > 2"* ]] || { echo "$output"; false; }
  write_bulk "$PROJECT_DIR/src/other.c" 5
  commit_and_check
  [ "$status" -eq 1 ] && [[ "$output" == *"5 lines > hard cap 4"* ]] || { echo "$output"; false; }
}

@test "143-pr-size: a rename across excluded classes is counted, not reassigned" {
  write_bulk "$PROJECT_DIR/tests/old.ts" 1000
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed test'
  mkdir -p "$PROJECT_DIR/fixtures"
  git -C "$PROJECT_DIR" mv tests/old.ts fixtures/new.ts
  printf 'changed\n' >> "$PROJECT_DIR/fixtures/new.ts"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$(git -C "$PROJECT_DIR" diff --summary HEAD~1..HEAD)" == *rename* ]] || false
  [[ "$output" == *"1 lines countable"* && "$output" == *"tests=0, fixtures=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: root attributes added in the PR cannot exempt its code" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '* linguist-generated' > "$PROJECT_DIR/.gitattributes"
  write_bulk "$PROJECT_DIR/src/app.py" 1300
  commit_and_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1301 lines countable"* && "$output" == *"generated=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: nested attributes added in the PR cannot exempt code or themselves" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '* linguist-generated' > "$PROJECT_DIR/src/.gitattributes"
  write_bulk "$PROJECT_DIR/src/app.py" 1300
  commit_and_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1301 lines countable"* && "$output" == *"generated=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: attributes files always count even under excluded paths and base rules" {
  printf '%s\n' '* linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: seed broad attributes'
  printf '%s\n' '# extra' >> "$PROJECT_DIR/.gitattributes"
  mkdir -p "$PROJECT_DIR/tests"
  printf '%s\n' '* linguist-generated' > "$PROJECT_DIR/tests/.gitattributes"
  write_bulk "$PROJECT_DIR/tests/unit.py" 3
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"2 lines countable"* && "$output" == *"tests=3"* && "$output" == *"generated=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: marker-only added lines warn strictly above the limit without a hard cap" {
  local n expected
  for n in 600 601 1201; do
    mkdir -p "$PROJECT_DIR/src"
    python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(sys.argv[2]); p.write_text("# @generated\n" + "".join(f"generated {i}\n" for i in range(n-1)))' "$PROJECT_DIR/src/generated-$n.py" "$n"
    commit_and_check
    case "$n" in 600) expected=0 ;; *) expected=2 ;; esac
    [ "$status" -eq "$expected" ] || { echo "$n: $output"; false; }
    [[ "$output" == *"0 lines countable"* && "$output" == *"generated=$n"* && "$output" == *"marker-only=$n"* ]] || { echo "$output"; false; }
    if [ "$n" -gt 600 ]; then [[ "$output" == *"marker-only"* && "$output" == *"reviewer ack"* ]]; fi
  done
}

@test "143-pr-size-r2: marker-only additions aggregate and respect the warn override" {
  export PROCESS_GATE_PR_SIZE_LIMIT=10 PROCESS_GATE_PR_SIZE_HARD=20
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); [(d/f"g{i}.py").write_text("# @generated\n"+"x\n"*5) for i in range(2)]' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"marker-only=12"* && "$output" == *"reviewer ack"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: base attributed generated additions do not trigger marker-only warning" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' 'src/generated.py linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: seed generated attributes'
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("# @generated\n"+"x\n"*1299)' "$PROJECT_DIR/src/generated.py"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"generated=1300"* && "$output" == *"marker-only=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: PR-added minus-diff and binary attributes cannot hide text rewrites" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text("".join(f"old {i}\n" for i in range(50)))' "$PROJECT_DIR/src/app.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
  printf '%s\n' '*.py -diff' > "$PROJECT_DIR/.gitattributes"
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text("".join(f"new {i}\n" for i in range(1400)))' "$PROJECT_DIR/src/app.py"
  commit_and_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1451 lines countable"* && "$output" == *"binary-files=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: PR-added binary attributes cannot hide text rewrites" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("".join(f"old {i}\n" for i in range(50)))' "$PROJECT_DIR/src/app.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
  printf '%s\n' '*.py binary' > "$PROJECT_DIR/.gitattributes"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("".join(f"new {i}\n" for i in range(1400)))' "$PROJECT_DIR/src/app.py"
  commit_and_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1451 lines countable"* && "$output" == *"binary-files=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: info and global minus-diff attributes cannot hide text rewrites" {
  mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/.git/info"
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text("".join(f"old {i}\n" for i in range(50)))' "$PROJECT_DIR/src/app.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text("".join(f"new {i}\n" for i in range(1400)))' "$PROJECT_DIR/src/app.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: rewrite code'
  printf '%s\n' '* -diff' > "$PROJECT_DIR/.git/info/attributes"
  printf '%s\n' '* binary' > "$BATS_TEST_TMPDIR/global-attributes"
  git -C "$PROJECT_DIR" config core.attributesFile "$BATS_TEST_TMPDIR/global-attributes"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1450 lines countable"* && "$output" == *"binary-files=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: global attributes alone cannot hide text" {
  write_bulk "$PROJECT_DIR/src/code.py" 1300
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: add code'
  printf '%s\n' '* binary' > "$BATS_TEST_TMPDIR/global-only-attributes"
  git -C "$PROJECT_DIR" config core.attributesFile "$BATS_TEST_TMPDIR/global-only-attributes"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1300 lines countable"* && "$output" == *"binary-files=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: single revision ignores attributes added in the tracked worktree" {
  mkdir -p "$PROJECT_DIR/src"
  printf '%s\n' '* linguist-generated' > "$PROJECT_DIR/.gitattributes"
  write_bulk "$PROJECT_DIR/src/app.py" 1300
  git -C "$PROJECT_DIR" add -A
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1301 lines countable"* && "$output" == *"generated=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: single revision ignores PR and local clean filters" {
  mkdir -p "$PROJECT_DIR/src"
  printf 'seed\n' > "$PROJECT_DIR/src/code.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
  git -C "$PROJECT_DIR" config filter.conceal.clean "printf 'seed\\n'; touch '$BATS_TEST_TMPDIR/filter-ran'"
  printf '%s\n' 'src/code.py filter=conceal' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  local sentinel="$BATS_TEST_TMPDIR/filter-ran"
  if [ -e "$sentinel" ]; then rm "${sentinel:?}"; fi
  write_bulk "$PROJECT_DIR/src/code.py" 1300
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1302 lines countable"* ]] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/filter-ran" ] || { echo 'untrusted clean filter ran'; false; }
}

@test "143-pr-size-r2: single revision safely falls back when Git lacks attr-source" {
  mkdir -p "$PROJECT_DIR/src"
  printf 'seed\n' > "$PROJECT_DIR/src/code.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed code'
  git -C "$PROJECT_DIR" config filter.conceal.clean "printf 'seed\\n'; touch '$BATS_TEST_TMPDIR/filter-ran'"
  printf '%s\n' 'src/code.py filter=conceal' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  local sentinel="$BATS_TEST_TMPDIR/filter-ran" mock_bin="$BATS_TEST_TMPDIR/old-git" real_git
  if [ -e "$sentinel" ]; then rm "${sentinel:?}"; fi
  write_bulk "$PROJECT_DIR/src/code.py" 1300
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'case "$1" in --attr-source=*) printf x > "$FALLBACK_MARKER"; exit 129 ;; esac' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" FALLBACK_MARKER="$BATS_TEST_TMPDIR/fallback" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"1302 lines countable"* ]] || { echo "$output"; false; }
  [ -e "$BATS_TEST_TMPDIR/fallback" ] && [ ! -e "$sentinel" ] || { echo 'fallback missed or clean filter ran'; false; }
}

@test "143-pr-size-r2: single revision keeps base attributes despite worktree changes" {
  printf '%s\n' 'src/generated.py linguist-generated' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: seed attributes'
  printf '%s\n' 'src/generated.py -linguist-generated' > "$PROJECT_DIR/.gitattributes"
  write_bulk "$PROJECT_DIR/src/generated.py" 1300
  git -C "$PROJECT_DIR" add -A
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"2 lines countable"* && "$output" == *"generated=1300"* && "$output" == *"marker-only=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: single revision counts changed and dirty submodules" {
  local child="$BATS_TEST_TMPDIR/child"
  git init -q -b main "$child"
  git -C "$child" config user.name test
  git -C "$child" config user.email test@example.com
  printf 'one\n' > "$child/code.txt"
  git -C "$child" add -A
  git -C "$child" commit -qm 'chore: seed child'
  git -C "$PROJECT_DIR" -c protocol.file.allow=always submodule add -q "$child" dep
  git -C "$PROJECT_DIR" commit -qm 'chore: seed submodule'
  git -C "$PROJECT_DIR/dep" config user.name test
  git -C "$PROJECT_DIR/dep" config user.email test@example.com
  printf 'two\n' >> "$PROJECT_DIR/dep/code.txt"
  git -C "$PROJECT_DIR/dep" add -A
  git -C "$PROJECT_DIR/dep" commit -qm 'feat: update child'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] && [[ "$output" == *"2 lines countable"* ]] || { echo "$output"; false; }
  git -C "$PROJECT_DIR/dep" checkout -q --detach HEAD~1
  printf 'dirty\n' >> "$PROJECT_DIR/dep/code.txt"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] && [[ "$output" == *"2 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: base minus-diff still counts text and actual binaries are reported" {
  printf '%s\n' '* -diff' > "$PROJECT_DIR/.gitattributes"
  git -C "$PROJECT_DIR" add .gitattributes
  git -C "$PROJECT_DIR" commit -qm 'chore: mark binary'
  mkdir -p "$PROJECT_DIR/src"
  write_bulk "$PROJECT_DIR/src/code.py" 601
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); (d/"binary.dat").write_bytes(b"a\0b\n"*50); (d/"edge-nul.dat").write_bytes(b"x"*8191+b"\0\n"); (d/"late-nul.dat").write_bytes(b"x"*8192+b"\0\nline\n")' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"603 lines countable"* && "$output" == *"binary-files=2"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: actual large blobs are bounded and binaries skip marker reads" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); (d/"gen.c").write_bytes(b"// @generated\n"+b"x"*2000000+b"\n"); (d/"bin.dat").write_bytes(b"\0"+b"x"*2000000)' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"0 lines countable"* && "$output" == *"generated=2"* && "$output" == *"marker-only=2"* && "$output" == *"binary-files=1"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: SHA-256 repositories work for committed and single revisions" {
  local sha_repo="$BATS_TEST_TMPDIR/sha256"
  git init -q -b main --object-format=sha256 "$sha_repo" || skip 'Git lacks SHA-256 repositories'
  git -C "$sha_repo" config user.name test
  git -C "$sha_repo" config user.email test@example.com
  git -C "$sha_repo" commit --allow-empty -qm 'chore: seed'
  write_bulk "$sha_repo/src/code.py" 601
  git -C "$sha_repo" add -A
  run env CLAUDE_PROJECT_DIR="$sha_repo" bash -c 'cd "$1" && exec bash "$2" --range=HEAD' fixture "$sha_repo" "$SCRIPT"
  [ "$status" -eq 2 ] && [[ "$output" == *"601 lines countable"* ]] || { echo "$output"; false; }
  git -C "$sha_repo" commit -qm 'feat: code'
  run env CLAUDE_PROJECT_DIR="$sha_repo" bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$sha_repo" "$SCRIPT"
  [ "$status" -eq 2 ] && [[ "$output" == *"601 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r2: batched blobs preserve binary sniff and bounded markers" {
  run python3 -I - "$SCRIPT" <<'PY'
import importlib.util, io, pathlib, sys
sys.dont_write_bytecode = True
p = pathlib.Path(sys.argv[1]).parent / 'lib/pr-size.py'
spec = importlib.util.spec_from_file_location('pr_size', p)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
blobs = {
    b'1'*40: b'#!/usr/bin/env node\n\0@generated\r',
    b'2'*40: b'// @generated\n' + b'x'*70000 + b'\r',
    b'3'*40: b'x'*65536 + b'\n// @generated\n',
    b'4'*40: b'x'*8191 + b'\0',
    b'5'*40: b'x'*8192 + b'\0',
    b'6'*40: b'x'*8191 + b'\r\nend\n',
}
wire = b''.join(oid+b' blob '+str(len(data)).encode()+b'\n'+data+b'\n' for oid,data in sorted(blobs.items()))
class Input:
    def __init__(self): self.data = bytearray()
    def write(self, data): self.data.extend(data)
    def flush(self): pass
    def close(self): pass
class Proc:
    def __init__(self): self.stdin = Input(); self.stdout = io.BytesIO(wire)
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def wait(self): return 0
proc = Proc()
calls = []
def start(argv, **kwargs): calls.append(argv); return proc
m.subprocess.Popen = start
found = m.inspect_blobs(set(blobs), {})
assert calls == [[b'git', b'cat-file', b'--batch']]
assert bytes(proc.stdin.data).splitlines() == sorted(blobs)
assert found[b'1'*40] == (True, False, True, True)
assert found[b'2'*40] == (False, True, True, False)
assert found[b'3'*40] == (False, False, False, False)
assert found[b'4'*40][0] and not found[b'5'*40][0]
assert not found[b'6'*40][2]
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "143-pr-size-r2: two-step laundering limits are documented" {
  local doc="$(dirname "$SCRIPT")/../references/pr-hygiene.md"
  grep -Fq 'pure rename from a previously excluded test or generated path to production has zero changed lines' "$doc"
  grep -Fq 'broad attribute already present in the base can also exclude later matching edits' "$doc"
}

@test "143-pr-size-r2: shipped shell test-like name and OpenAPI spec count" {
  write_bulk "$PROJECT_DIR/core-rules/skills/foo/scripts/preflight_test.sh" 1300
  commit_and_check
  [ "$status" -eq 1 ] && [[ "$output" == *"1300 lines countable"* ]] || { echo "$output"; false; }
  write_bulk "$PROJECT_DIR/api/openapi.spec.yaml" 1300
  commit_and_check
  [ "$status" -eq 1 ] && [[ "$output" == *"1300 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: binary source lines warn above the soft limit, not the hard cap" {
  local n expected
  mkdir -p "$PROJECT_DIR/src"
  for n in 600 601 1201; do
    python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(sys.argv[2]); p.write_bytes(b"// \0\n"+b"console.log(0)\n"*(n-1))' "$PROJECT_DIR/src/source-$n.js" "$n"
    commit_and_check
    case "$n" in 600) expected=0 ;; *) expected=2 ;; esac
    [ "$status" -eq "$expected" ] || { echo "$n: $output"; false; }
    [[ "$output" == *"0 lines countable"* && "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=$n"* ]] || { echo "$output"; false; }
    if [ "$n" -gt 600 ]; then [[ "$output" == *"binary-code"* && "$output" == *"reviewer ack"* ]]; fi
  done
}

@test "143-pr-size-r3: binary-source warnings aggregate and honor the override" {
  export PROCESS_GATE_PR_SIZE_LIMIT=10 PROCESS_GATE_PR_SIZE_HARD=20
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); [(d/f"file{i}.c").write_bytes(b"/* \0 */\n"+b"code\n"*5) for i in range(2)]' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"binary-files=2"* && "$output" == *"binary-code-lines=12"* && "$output" == *"reviewer ack"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: large non-code binaries do not trigger the code warning" {
  mkdir -p "$PROJECT_DIR/assets"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"\0\n"+b"bytes\n"*1200)' "$PROJECT_DIR/assets/image.bin"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: binary-to-text source rewrites are visibly warned" {
  mkdir -p "$PROJECT_DIR/src"
  printf '\0\n' > "$PROJECT_DIR/src/app.js"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed binary'
  write_bulk "$PROJECT_DIR/src/app.js" 1400
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"0 lines countable"* && "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=1401"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: binary code renamed to a non-code path still warns" {
  mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/assets"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"// \0\n"+b"".join(f"old {i}\n".encode() for i in range(1000)))' "$PROJECT_DIR/src/app.js"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed binary source'
  git -C "$PROJECT_DIR" mv src/app.js assets/app.dat
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes()+b"".join(f"new {i}\n".encode() for i in range(601)))' "$PROJECT_DIR/assets/app.dat"
  commit_and_check
  [[ "$(git -C "$PROJECT_DIR" diff --summary HEAD~1..HEAD)" == *rename* ]] || { echo 'rename not detected'; false; }
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=601"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR-only binary source cannot evade its warning" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"// \0\r"+b"code\r"*600)' "$PROJECT_DIR/src/app.js"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"0 lines countable"* && "$output" == *"binary-code-lines=601"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR-only files obey all countable size boundaries" {
  local n expected
  mkdir -p "$PROJECT_DIR/src"
  for n in 600 601 1200 1201; do
    python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"".join(f"line {i}\r".encode() for i in range(int(sys.argv[2]))))' "$PROJECT_DIR/src/cr-$n.js" "$n"
    commit_and_check
    case "$n" in 600) expected=0 ;; 601|1200) expected=2 ;; 1201) expected=1 ;; esac
    [ "$status" -eq "$expected" ] || { echo "$n: $output"; false; }
    [[ "$output" == *"$n lines countable"* ]] || { echo "$output"; false; }
  done
}

@test "143-pr-size-r3: mixed endings and CR beyond 64 KiB count logical lines" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); (d/"mixed.js").write_bytes(b"one\r\ntwo\rthree\nfour\r"); (d/"late.js").write_bytes(b"x"*70000+b"\r"+b"line\r"*601)' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"606 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR and CRLF across the scan boundary are counted correctly" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); (d/"bare.c").write_bytes(b"x"*65535+b"\r"+b"end\n"); (d/"crlf.c").write_bytes(b"y"*65535+b"\r\n"+b"end\n"); (d/"mixed.c").write_bytes(b"first\r"+b"z"*(65535-6)+b"\r\nend\n")' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"7 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR-only rename keeps original source and destination pairing" {
  mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/tests"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"".join(f"line {i}\r".encode() for i in range(1000)))' "$PROJECT_DIR/src/source.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed cr source'
  git -C "$PROJECT_DIR" mv src/source.py tests/dest.py
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes()+b"".join(f"extra {i}\r".encode() for i in range(400)))' "$PROJECT_DIR/tests/dest.py"
  commit_and_check
  [[ "$(git -C "$PROJECT_DIR" diff --summary HEAD~1..HEAD)" == *rename* ]] || { echo 'rename not detected'; false; }
  [ "$status" -eq 0 ] && [[ "$output" == *"400 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: equivalent CR and LF content normalizes to zero" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"alpha\rbeta\r")' "$PROJECT_DIR/src/app.js"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed cr file'
  printf 'alpha\nbeta\n' > "$PROJECT_DIR/src/app.js"
  commit_and_check
  [ "$status" -eq 0 ] && [[ "$output" == *"0 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR-only deletion counts deleted logical lines" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"line\r"*601)' "$PROJECT_DIR/src/app.js"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed cr file'
  git -C "$PROJECT_DIR" rm -q src/app.js
  commit_and_check
  [ "$status" -eq 2 ] && [[ "$output" == *"601 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR-only edits count changed logical lines, not whole files" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"".join(f"old {i}\r".encode() for i in range(1000)))' "$PROJECT_DIR/src/app.js"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed cr file'
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); lines=p.read_bytes().split(b"\r"); lines[500]=b"changed"; p.write_bytes(b"\r".join(lines)+b"new one\rnew two\r")' "$PROJECT_DIR/src/app.js"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"4 lines countable"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: CR-delimited generated markers honor the 20-line boundary" {
  mkdir -p "$PROJECT_DIR/src"
  python3 -I -c 'import pathlib,sys; d=pathlib.Path(sys.argv[1]); (d/"early.c").write_bytes(b"header\r// @generated\rcode\r"); (d/"late.c").write_bytes(b"line\r"*20+b"// @generated\r")' "$PROJECT_DIR/src"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"21 lines countable"* && "$output" == *"generated=3"* && "$output" == *"marker-only=3"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r3: one batched numstat and one attribute query per range" {
  local mock_bin="$BATS_TEST_TMPDIR/batch-git" real_git n count="$BATS_TEST_TMPDIR/calls"
  for n in 1 2 3 4 5 6 7 8; do write_bulk "$PROJECT_DIR/src/file-$n.py" 2; done
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: many files'
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'case " $* " in *" --numstat "*) printf "numstat\\n" >> "$CALLS" ;; esac' \
    'if [ "$1" = check-attr ]; then printf "attr\\n" >> "$CALLS"; fi' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  : > "$count"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" CALLS="$count" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^numstat$' "$count")" -eq 1 ] && [ "$(grep -c '^attr$' "$count")" -eq 1 ] || { echo 'not batched'; false; }
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"first\rsecond\r")' "$PROJECT_DIR/src/cr.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: cr file'
  : > "$count"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" CALLS="$count" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] && [[ "$output" == *"2 lines countable"* ]] || { echo "$output"; false; }
  [ "$(grep -c '^numstat$' "$count")" -eq 1 ] && [ "$(grep -c '^attr$' "$count")" -eq 1 ] || { echo 'CR path not batched'; false; }
}

@test "143-pr-size-r3: missing batched numstat fails closed with or without CR" {
  local mock_bin="$BATS_TEST_TMPDIR/no-numstat" real_git name
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'if [ "$1" = diff ] && [ "$2" = --numstat ]; then exit 0; fi' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  for name in normal cr; do
    mkdir -p "$PROJECT_DIR/src"
    if [ "$name" = normal ]; then
      printf 'one\ntwo\n' > "$PROJECT_DIR/src/$name.py"
    else
      python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"one\rtwo\r")' "$PROJECT_DIR/src/$name.py"
    fi
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -qm 'feat: add file'
    run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" \
      bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
    [ "$status" -eq 1 ] && [[ "$output" == *"unable to enumerate changed files"* ]] || { echo "$name: $output"; false; }
  done
}

@test "143-pr-size-r3: both additional two-step limits are documented" {
  local doc="$(dirname "$SCRIPT")/../references/pr-hygiene.md"
  grep -Fq 'binary-to-text rewrite' "$doc"
  grep -Fq 'marker-generated file rewritten while retaining its marker' "$doc"
}

@test "143-pr-size-r4: mts cts and uppercase code extensions warn for binary source" {
  local ext n=0
  mkdir -p "$PROJECT_DIR/src"
  for ext in mts cts JS Py MTS CTS; do
    n=$((n + 1))
    python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"// \0\n"+b"source\n"*600)' "$PROJECT_DIR/src/app-$n.$ext"
    commit_and_check
    [ "$status" -eq 2 ] || { echo "$ext: $output"; false; }
    [[ "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=601"* ]] || { echo "$ext: $output"; false; }
  done
}

@test "143-pr-size-r4: binary extensionless shebangs warn and ordinary assets do not" {
  mkdir -p "$PROJECT_DIR/bin" "$PROJECT_DIR/assets"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"#!/usr/bin/env node\n// \0\n"+b"source\n"*599)' "$PROJECT_DIR/bin/tool"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"binary-code-lines=601"* ]] || { echo "$output"; false; }
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"not a shebang\n#!/bin/sh\n\0\n"+b"data\n"*598)' "$PROJECT_DIR/assets/data.bin"
  commit_and_check
  [ "$status" -eq 0 ] && [[ "$output" == *"binary-code-lines=0"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r4: a shebang on the new side of a binary rewrite warns" {
  mkdir -p "$PROJECT_DIR/bin"
  printf '\0\n' > "$PROJECT_DIR/bin/tool"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed binary'
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"#!/usr/bin/env node\n"+b"source\n"*600)' "$PROJECT_DIR/bin/tool"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=602"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r4: a shebang on the old side of a binary rewrite warns" {
  mkdir -p "$PROJECT_DIR/bin"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"#!/usr/bin/env node\n// \0\n"+b"source\n"*599)' "$PROJECT_DIR/bin/tool"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed binary'
  printf 'replacement\n' > "$PROJECT_DIR/bin/tool"
  commit_and_check
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"binary-files=1"* && "$output" == *"binary-code-lines=602"* ]] || { echo "$output"; false; }
}

@test "143-pr-size-r4: malformed or failed blob batches fail closed" {
  local mock_bin="$BATS_TEST_TMPDIR/bad-blob-batch" real_git fault
  write_bulk "$PROJECT_DIR/src/file.py" 3
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: file'
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'if [ "$1" = cat-file ] && [ "$2" = --batch ]; then' \
    '  case "$FAULT" in' \
    '    header) printf "invalid\\n"; exit 0 ;;' \
    '    truncated) IFS= read -r oid; printf "%s blob 100\\nx" "$oid"; exit 0 ;;' \
    '    terminator) IFS= read -r oid; printf "%s blob 1\\nx" "$oid"; exit 0 ;;' \
    '    exit) "$REAL_GIT" "$@"; exit 1 ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  for fault in header truncated terminator exit; do
    run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" FAULT="$fault" \
      bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
    [ "$status" -eq 1 ] && [[ "$output" == *"unable to enumerate changed files"* ]] || { echo "$fault: $output"; false; }
  done
}

@test "143-pr-size-r4: one blob batch handles the whole non-CR range" {
  local mock_bin="$BATS_TEST_TMPDIR/batch-objects" real_git n count="$BATS_TEST_TMPDIR/object-calls"
  for n in 1 2 3 4 5 6 7 8; do write_bulk "$PROJECT_DIR/src/file-$n.py" 2; done
  mkdir -p "$PROJECT_DIR/assets"
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"\0"+b"x"*200000)' "$PROJECT_DIR/assets/data.bin"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: many files'
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'if [ "$1" = cat-file ] && [ "$2" = --batch ]; then printf "batch\\n" >> "$CALLS"; fi' \
    'if [ "$1" = cat-file ] && [ "$2" = blob ]; then printf "blob\\n" >> "$CALLS"; fi' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  : > "$count"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" CALLS="$count" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^batch$' "$count" || true)" -eq 1 ] && [ "$(grep -c '^blob$' "$count" || true)" -eq 0 ] || { echo 'blob probes not batched'; false; }
  python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"first\rsecond\r")' "$PROJECT_DIR/src/cr.py"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'feat: cr file'
  : > "$count"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" CALLS="$count" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] && [[ "$output" == *"2 lines countable"* ]] || { echo "$output"; false; }
  [ "$(grep -c '^batch$' "$count" || true)" -eq 1 ] || { echo 'CR inspection not batched'; false; }
}

@test "143-pr-size: same-class rename stays excluded and generated marker changes do not hide edits" {
  write_bulk "$PROJECT_DIR/tests/old.ts" 1000
  write_bulk "$PROJECT_DIR/src/plain.ts" 1000
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm 'chore: seed files'
  git -C "$PROJECT_DIR" mv tests/old.ts tests/new.ts
  python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_bytes(b"// @generated\n" + p.read_bytes())' "$PROJECT_DIR/src/plain.ts"
  printf '%s\n' 'more test' >> "$PROJECT_DIR/tests/new.ts"
  commit_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"1 lines countable"* ]] || { echo "$output"; false; }
  [[ "$output" == *"excluded: tests=1, fixtures=0, generated=0, lockfiles=0"* ]] || false
}
