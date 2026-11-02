#!/usr/bin/env bats
# Hermetic e2e chain: branch-push selector -> real check-tests.sh -> real run-all.sh
# -> real accept-branch.sh parser. The fixture test command records argv and the
# PG_TESTS_* interface, then writes the canonical receipt the wrapper would write.
# PG_PUSH_TEST_SCOPE=branch stands in for the pre-push export of an observed
# branch-only push. The mapper is committed into the fixture's BASE.
# Expected release-base RED: the narrowed case (base never narrows) and the
# docs-only case (base legacy docs-only path). The full-battery case is expected
# green on base; it guards against over-narrowing.

EXPECT_NARROWED="--test-file=scripts/tests/check-decisions-log.bats --test-file=scripts/tests/check-process-liveness.bats --test-file=scripts/tests/diff-base-sync.bats --test-file=scripts/tests/gpt6-roster-sweep.bats --test-file=scripts/tests/live-model-roster.bats --test-file=scripts/tests/no-legacy-herdr.bats --test-file=scripts/tests/posix-bootstrap-prologue.bats --test-file=scripts/tests/push-test-map.bats --test-file=scripts/tests/release-payload-commit.bats --test-file=scripts/tests/release-tag-consumers.bats --test-file=scripts/tests/suite-coverage.bats --test-file=scripts/tests/test-fencing.bats"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp" PI_CODING_AGENT_DIR="$BATS_TEST_TMPDIR/pi-agent"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg/config" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg/cache"
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg/data" XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg/state"
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/gate-state" TRELLIS_ATTACH_POSTJOB=off
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR" "$PI_CODING_AGENT_DIR" \
    "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
  local real="$BATS_TEST_DIRNAME/../scripts"
  SKILL="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$SKILL/scripts/lib"
  cp "$real/run-all.sh" "$real/check-tests.sh" "$SKILL/scripts/"
  cp "$real/lib/common.sh" "$real/lib/diff-base.sh" "$SKILL/scripts/lib/"
  local row
  for row in pr secrets bypass docs security-diff analyze slop; do
    printf '#!/usr/bin/env bash\necho "pass fixture"\n' > "$SKILL/scripts/check-$row.sh"
  done
  printf '#!/usr/bin/env bash\necho "info API contract: n/a — profile undeclared"\n' > "$SKILL/scripts/check-api-contract.sh"
  export PROCESS_GATE_HEAVY_LAUNCHER="$BATS_TEST_TMPDIR/no-launcher"
  export PROCESS_GATE_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  export CLAUDE_PROJECT_DIR="$PROCESS_GATE_PROJECT_DIR"
  unset CODEX_PROJECT_DIR PG_MODE PG_PUSH_TEST_SCOPE PROCESS_GATE_COVERAGE_CMD
  unset PROCESS_GATE_MUTATION_SPOTCHECK PROCESS_GATE_LINT_CMD PROCESS_GATE_TEST_CMD PROCESS_GATE_TEST_MAP
  unset PG_TESTS_BASE PG_TESTS_HEAD PG_TESTS_RECEIPT_FILE
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

  local dir="$PROCESS_GATE_PROJECT_DIR"
  git init -qb main "$dir"
  gfx config user.name Fixture
  gfx config user.email fixture@example.invalid
  gfx config commit.gpgsign false
  mkdir -p "$dir/.claude/skills/process-gate-local" "$dir/scripts/lib" "$dir/scripts/tests" "$dir/docs/notes"
  printf '%s\n' 'PROCESS_GATE_TYPECHECK_CMD=:' 'PROCESS_GATE_LINT_CMD=:' \
    'PROCESS_GATE_TEST_CMD="bash tests-command.sh"' \
    'PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"' 'PROCESS_GATE_STACK_PROFILE=n-a' \
    > "$dir/.claude/skills/process-gate-local/local.config.sh"
  cp "$BATS_TEST_DIRNAME/../../../../scripts/lib/push-test-map.py" "$dir/scripts/lib/push-test-map.py"
  local suite
  for suite in check-decisions-log check-process-liveness diff-base-sync gpt6-roster-sweep \
    live-model-roster no-legacy-herdr posix-bootstrap-prologue push-test-map release-payload-commit \
    release-tag-consumers suite-coverage test-fencing; do
    printf '# fixture suite\n' > "$dir/scripts/tests/$suite.bats"
  done
  printf '#!/usr/bin/env bash\necho base\n' > "$dir/scripts/check-decisions-log.sh"
  printf 'base\n' > "$dir/scripts/lib/shared.sh"
  printf 'base\n' > "$dir/docs/notes/field-guide.md"
  printf 'allow ^docs/notes/[a-z-]+\\.md$\n' > "$dir/.claude/skills/process-gate-local/docs-only-tests.policy"
  cat > "$dir/tests-command.sh" <<'SH'
#!/usr/bin/env bash
# Records argv and the PG_TESTS_* interface; writes the canonical receipt.
n=0
for arg in "$@"; do
  case "$arg" in --test-file=*) n=$((n + 1)) ;; esac
done
if [ "$n" -gt 0 ]; then receipt="PG_TESTS_RECEIPT narrowed $n"; else receipt="PG_TESTS_RECEIPT full"; fi
{
  printf 'base=%s\n' "${PG_TESTS_BASE-unset}"
  printf 'head=%s\n' "${PG_TESTS_HEAD-unset}"
  printf 'receipt=%s\n' "$receipt"
  for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
} > "$SEEN"
[ -z "${PG_TESTS_RECEIPT_FILE:-}" ] || printf '%s\n' "$receipt" > "$PG_TESTS_RECEIPT_FILE"
exit 0
SH
  gfx add .
  gfx commit -qm base
  BASE="$(gfx rev-parse HEAD)"
  export SEEN="$BATS_TEST_TMPDIR/seen"
}

gfx() { git -C "$PROCESS_GATE_PROJECT_DIR" "$@"; }

branch_commit() {  # branch_commit <path> <line>
  mkdir -p "$(dirname "$PROCESS_GATE_PROJECT_DIR/$1")"
  printf '%s\n' "$2" >> "$PROCESS_GATE_PROJECT_DIR/$1"
  gfx add "$1"
  gfx commit -qm "branch: $1"
  HEAD_SHA="$(gfx rev-parse HEAD)"
}

gate() {
  rm -f "$SEEN"
  run bash -c 'cd "$PROCESS_GATE_PROJECT_DIR" && PG_PUSH_TEST_SCOPE=branch bash -p "$1/scripts/run-all.sh" --mode=push "--range=$2"' \
    _ "$SKILL" "$BASE..$HEAD_SHA"
}

recorded() { sed -n "s/^$1=//p" "$SEEN"; }
recorded_args() { sed -n 's/^arg=//p' "$SEEN" | paste -sd' ' -; }

assert_tests_row() {  # assert_tests_row <scope>
  [[ "$output" == *"Overall: MERGEABLE"* ]]
  [[ "$output" == *"Tests & coverage:"*"— $1"* ]]
  [[ "$output" == *$'\nTests: '"$1"* ]]
}

accept_verdict() {
  # Acceptance runs merge gates in production. Replay the real push verdict with
  # only its mode header adapted, so the unchanged merge parser consumes the
  # actual Tests row/scope. Every receipt and branch mutation stays in fixtures.
  export SAVED_GATE_OUTPUT="$BATS_TEST_TMPDIR/push-verdict"
  printf '%s\n' "$output" > "$SAVED_GATE_OUTPUT"
  local tree="$BATS_TEST_TMPDIR/accept-tree" gate_dir v
  mkdir -p "$tree/core-rules/skills/herdr-foreman/scripts" "$tree/scripts"
  cp "$BATS_TEST_DIRNAME/../../herdr-foreman/scripts/accept-branch.sh" \
    "$tree/core-rules/skills/herdr-foreman/scripts/"
  printf '#!/usr/bin/env python3\n' > "$tree/scripts/usage-federation.py"
  gate_dir="$TRELLIS_HOME/releases/9.9.9/payload/core-rules/skills/process-gate/scripts"
  mkdir -p "$gate_dir/lib"
  for v in checker-preflight.sh check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh \
    check-docs.sh check-security-diff.sh check-analyze.sh check-slop.sh check-api-contract.sh lib/api-contract.py; do
    printf '#!/bin/bash\nexit 0\n' > "$gate_dir/$v"
  done
  cp "$BATS_TEST_DIRNAME/../scripts/lib/diff-base.sh" "$gate_dir/lib/"
  printf '#!/usr/bin/env bash\nsed "s/(mode=push)/(mode=merge)/" "$SAVED_GATE_OUTPUT"\n' > "$gate_dir/run-all.sh"
  printf '{"active_cli_release":"9.9.9"}\n' > "$TRELLIS_HOME/config.json"
  printf '{"version":"9.9.9","commit":"%040d"}\n' 0 > "$TRELLIS_HOME/releases/9.9.9/release.json"
  gfx branch pi-agent-receipt "$HEAD_SHA"
  run bash -c 'cd "$1" && bash "$2" 11111111-1111-4111-8111-111111111111 "$3" "$4"' \
    _ "$PROCESS_GATE_PROJECT_DIR" "$tree/core-rules/skills/herdr-foreman/scripts/accept-branch.sh" "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"accept: parsed verdict=accept"* ]]
  ! gfx show-ref --verify --quiet refs/heads/pi-agent-receipt
}

@test "branch push narrows an audited leaf change to its mapped suites" {
  branch_commit scripts/check-decisions-log.sh 'echo change'
  gate
  [ "$status" -eq 0 ]
  [ "$(recorded base)" = "$BASE" ]
  [ "$(recorded head)" = "$HEAD_SHA" ]
  [ "$(recorded_args)" = "$EXPECT_NARROWED" ]
  local row
  row="$(printf '%s\n' "$output" | grep -F 'Tests & coverage:')"
  [[ "$row" == *✅* ]]
  assert_tests_row "narrowed: 12 selected"
  accept_verdict
}

@test "branch push with an unmappable source change runs the full battery" {
  branch_commit scripts/lib/shared.sh 'echo change'
  gate
  [ "$status" -eq 0 ]
  [ "$(recorded base)" = "$BASE" ]
  [ "$(recorded head)" = "$HEAD_SHA" ]
  [ -z "$(recorded_args)" ]
  assert_tests_row full
  accept_verdict
}

@test "branch push with docs-only change reports canonical no-tests without running the battery" {
  branch_commit docs/notes/field-guide.md 'more prose'
  gate
  [ "$status" -eq 0 ]
  [ ! -e "$SEEN" ]
  assert_tests_row "no-tests: docs-only"
  accept_verdict
}
