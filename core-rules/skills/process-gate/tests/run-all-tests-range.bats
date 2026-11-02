#!/usr/bin/env bats
# Real aggregator + Tests row; unrelated rows are isolated stubs.
setup() {
  unset PG_PUSH_TEST_SCOPE
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/gate-state"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  local real="$BATS_TEST_DIRNAME/../scripts"
  SKILL="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$SKILL/scripts/lib"
  cp "$real/run-all.sh" "$real/check-tests.sh" "$SKILL/scripts/"
  cp "$real/lib/common.sh" "$real/lib/diff-base.sh" "$SKILL/scripts/lib/"
  local row
  for row in pr secrets bypass docs security-diff analyze slop; do
    printf '#!/usr/bin/env bash\necho "pass fixture"\n' > "$SKILL/scripts/check-$row.sh"
  done
  export PROCESS_GATE_HEAVY_LAUNCHER="$BATS_TEST_TMPDIR/no-launcher"
  export PROCESS_GATE_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  export CLAUDE_PROJECT_DIR="$PROCESS_GATE_PROJECT_DIR"
  unset CODEX_PROJECT_DIR PG_MODE PROCESS_GATE_COVERAGE_CMD PROCESS_GATE_MUTATION_SPOTCHECK
  unset PROCESS_GATE_LINT_CMD
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  git init -qb main "$PROCESS_GATE_PROJECT_DIR"
  gfx config user.name Fixture
  gfx config user.email fixture@example.invalid
  gfx config commit.gpgsign false
  mkdir -p "$PROCESS_GATE_PROJECT_DIR/.claude/skills/process-gate-local"
  printf '%s\n' 'PROCESS_GATE_TYPECHECK_CMD=:' 'PROCESS_GATE_LINT_CMD="${PROCESS_GATE_LINT_CMD:-:}"' \
    'PROCESS_GATE_TEST_CMD="bash tests-command.sh"' 'PROCESS_GATE_STACK_PROFILE=n-a' \
    > "$PROCESS_GATE_PROJECT_DIR/.claude/skills/process-gate-local/local.config.sh"
  printf 'base\n' > "$PROCESS_GATE_PROJECT_DIR/code"
  gfx add .; gfx commit -qm base
  BASE="$(gfx rev-parse HEAD)"
  printf 'range\n' >> "$PROCESS_GATE_PROJECT_DIR/code"
  gfx commit -qam range
  HEAD_SHA="$(gfx rev-parse HEAD)"
  # The gate head intentionally differs from the checkout HEAD.
  printf 'checkout\n' >> "$PROCESS_GATE_PROJECT_DIR/code"
  gfx commit -qam checkout
  export SEEN="$BATS_TEST_TMPDIR/seen" RECEIPT="" TEST_RC=0
  cat > "$PROCESS_GATE_PROJECT_DIR/tests-command.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${PG_TESTS_BASE-unset}" "${PG_TESTS_HEAD-unset}" > "$SEEN"
printf '%s\n' "${PG_TESTS_RECEIPT_FILE-unset}" >> "$SEEN"
if [ -n "$RECEIPT" ] && [ -n "${PG_TESTS_RECEIPT_FILE:-}" ]; then
  printf '%s\n' "$RECEIPT" > "$PG_TESTS_RECEIPT_FILE"
fi
exit "$TEST_RC"
SH
}
gfx() { git -C "$PROCESS_GATE_PROJECT_DIR" "$@"; }
gate() {
  run bash -c 'cd "$PROCESS_GATE_PROJECT_DIR" && bash -p "$1/scripts/run-all.sh" "--mode=$2" "--range=$3"' \
    _ "$SKILL" "${1:-push}" "${2:-$BASE..$HEAD_SHA}"
  echo "$output"
}
assert_receipt() {
  [[ "$output" == *"Tests & coverage:"*"— $1"* ]]
  [[ "$output" == *"Overall: MERGEABLE"*$'\nTests: '"$1"* ]]
}

parse_merge_verdict() {
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/verdict"
  run python3 - "$BATS_TEST_DIRNAME/../../herdr-foreman/scripts/accept-branch.sh" "$BATS_TEST_TMPDIR/verdict" 0 "$BASE" "$HEAD_SHA" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text().split('if ! PARSED_VERDICT=', 1)[1]
sys.argv = sys.argv[1:]
exec(source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0])
PY
}

@test "real run-all merge verdict passes accept parser, with legacy and exact scoped rows" {
  gate merge
  [ "$status" -eq 0 ]
  local verdict="$output" scope
  parse_merge_verdict
  [ "$output" = accept ]
  for scope in '' full 'narrowed: 7 selected' 'no-tests: docs-only' 'narrowed (docs-only: 3 files)' 'narrowed (release-metadata: 2 files)' 'not run' unknown invalid 'invalid pass' 'narrowed: 0 selected' 'full — full'; do
    output="$(printf '%s\n' "$verdict" | sed "/^Tests & coverage:/s/ — .*/${scope:+ — $scope}/")"
    parse_merge_verdict
    case "$scope" in invalid*|'narrowed: 0 selected'|'full — full') [[ "$output" == *$'\nreject' ]] ;; *) [ "$output" = accept ] ;; esac
  done
  for scope in 'Secrets: — invalid pass' 'Tests & coverage: —bogus pass'; do
    output="$(printf '%s\n' "$verdict" | sed "/^${scope%%:*}:/ { s/ — .*//; s/$/${scope#*:}/; }")"
    parse_merge_verdict
    [[ "$output" == *$'\nreject' ]]
  done
}

@test "undeclared Tests command is not run, never full" {
  printf 'PROCESS_GATE_TEST_CMD=\n' >> "$PROCESS_GATE_PROJECT_DIR/.claude/skills/process-gate-local/local.config.sh"
  gfx add .claude; gfx commit -qm undeclared
  BASE="$(gfx rev-parse HEAD)"; HEAD_SHA="$BASE"
  gate
  [ "$status" -eq 2 ]
  [[ "$output" == *'— not run'* && "$output" == *$'\nTests: not run'* && "$output" != *$'\nTests: full'* ]]
}

@test "crashed Tests checker reports unknown, never full" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SKILL/scripts/check-tests.sh"
  gate merge
  [ "$status" -eq 1 ]
  [[ "$output" == *'— unknown'* && "$output" == *$'\nTests: unknown'* && "$output" != *$'\nTests: full'* ]]
}

@test "last checker-owned Tests line wins over an earlier finding" {
  printf '#!/usr/bin/env bash\necho "  Tests: full"\necho "  Tests: no-tests: docs-only"\n' > "$SKILL/scripts/check-tests.sh"
  gate
  [ "$status" -eq 0 ]
  assert_receipt 'no-tests: docs-only'
}

@test "queue reuse and metadata receipts supplement one canonical selector scope" {
  local scope
  for scope in full 'narrowed (release-metadata: 2 files)'; do
    printf '#!/usr/bin/env bash\nprintf "  tests: reused verdict aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, ran fixture)\\n  tests: tag-reading suites executed\\n  Tests: %s\\n"\n' "$scope" > "$SKILL/scripts/check-tests.sh"
    gate merge
    [ "$status" -eq 0 ]
    assert_receipt "$scope"
    [[ "$output" == *'tests: reused verdict aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'* ]]
    [[ "$output" == *'tests: tag-reading suites executed'* ]]
    [ "$(printf '%s\n' "$output" | grep -c '^Tests: ')" -eq 1 ]
    parse_merge_verdict
    [ "$output" = accept ]
  done
}

@test "push Tests gets immutable exact endpoints, not trunk or checkout HEAD" {
  gate
  [ "$status" -eq 0 ]
  [ "$(head -n 2 "$SEEN")" = "$(printf '%s\n' "$BASE" "$HEAD_SHA")" ]
}

@test "push Tests full receipt reaches row and final verdict" {
  export RECEIPT='PG_TESTS_RECEIPT full'
  gate
  [ "$status" -eq 0 ]
  assert_receipt full
}

@test "push Tests narrowed receipt reaches row and final verdict for Codex too" {
  export CODEX_PROJECT_DIR="$PROCESS_GATE_PROJECT_DIR" RECEIPT='PG_TESTS_RECEIPT narrowed 7'
  gate
  [ "$status" -eq 0 ]
  assert_receipt 'narrowed: 7 selected'
}

@test "push Tests no-tests docs-only receipt reaches row and final verdict" {
  export RECEIPT='PG_TESTS_RECEIPT no-tests docs-only'
  gate
  [ "$status" -eq 0 ]
  assert_receipt 'no-tests: docs-only'
}

@test "caller-set range and receipt path are ignored and absent during lint" {
  export PG_TESTS_BASE=forged PG_TESTS_HEAD=forged PG_TESTS_RECEIPT_FILE="$BATS_TEST_TMPDIR/forged"
  export PROCESS_GATE_LINT_CMD='env | grep ^PG_TESTS_ > lint-env; test ! -s lint-env'
  gate
  [ "$status" -eq 0 ]
  [ "$(head -n 2 "$SEEN")" = "$(printf '%s\n' "$BASE" "$HEAD_SHA")" ]
  [ "$(tail -n 1 "$SEEN")" != "$PG_TESTS_RECEIPT_FILE" ]
  [ ! -e "$PG_TESTS_RECEIPT_FILE" ]
  [ -f "$PROCESS_GATE_PROJECT_DIR/lint-env" ]
  [ ! -s "$PROCESS_GATE_PROJECT_DIR/lint-env" ]
  [ ! -e "$(tail -n 1 "$SEEN")" ]
}

@test "merge Tests has no range or receipt channel even with forged inputs" {
  export PG_TESTS_BASE=forged PG_TESTS_HEAD=forged PG_TESTS_RECEIPT_FILE=forged
  export RECEIPT='PG_TESTS_RECEIPT no-tests docs-only'
  gate merge
  [ "$status" -eq 0 ]
  [ "$(< "$SEEN")" = "$(printf 'unset\nunset\nunset')" ]
  assert_receipt full
}

@test "no receipt means full and stdout cannot forge a narrowing receipt" {
  printf '\necho "PG_TESTS_RECEIPT no-tests docs-only"\n' >> "$PROCESS_GATE_PROJECT_DIR/tests-command.sh"
  # Remove the normal exit so the stdout marker actually runs.
  perl -pi -e 's/^exit "\$TEST_RC"$/true/' "$PROCESS_GATE_PROJECT_DIR/tests-command.sh"
  gate
  [ "$status" -eq 0 ]
  assert_receipt full
}

@test "malformed or multiple receipts block instead of claiming full or narrowed" {
  local receipt
  for receipt in 'PG_TESTS_RECEIPT narrowed 0' 'PG_TESTS_RECEIPT unknown' \
    $'PG_TESTS_RECEIPT narrowed 7\nPG_TESTS_RECEIPT full'; do
    export RECEIPT="$receipt"
    gate
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid Tests receipt'* ]]
  done
}

@test "a narrowing receipt cannot hide a failing Tests command" {
  export RECEIPT='PG_TESTS_RECEIPT narrowed 7' TEST_RC=9
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *'Overall: BLOCKED'*'Tests: narrowed: 7 selected'* ]]
}

@test "three-dot push range delivers its merge-base, not the divergent left tip" {
  gfx checkout -qb divergent "$BASE"
  printf 'other\n' > "$PROCESS_GATE_PROJECT_DIR/other"
  gfx add other; gfx commit -qm divergent
  local left="$(gfx rev-parse HEAD)"
  gate push "$left...$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$(head -n 2 "$SEEN")" = "$(printf '%s\n' "$BASE" "$HEAD_SHA")" ]
}

@test "push snapshot survives a prior row moving the named range head" {
  gfx update-ref refs/heads/pushed "$HEAD_SHA"
  printf '#!/usr/bin/env bash\ngit -C "$CLAUDE_PROJECT_DIR" update-ref refs/heads/pushed HEAD\n' > "$SKILL/scripts/check-pr.sh"
  gate push "$BASE..pushed"
  [ "$status" -eq 0 ]
  [ "$(head -n 2 "$SEEN")" = "$(printf '%s\n' "$BASE" "$HEAD_SHA")" ]
}

@test "Tests scope and receipt survive a heavy launcher clean-env boundary" {
  export PROCESS_GATE_HEAVY_LAUNCHER="$BATS_TEST_TMPDIR/launcher"
  cat > "$PROCESS_GATE_HEAVY_LAUNCHER" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" != --check ] || exit 0
while [ "$1" != -- ]; do shift; done
shift
exec env -i PATH="$PATH" HOME="$HOME" SEEN="$SEEN" RECEIPT="$RECEIPT" TEST_RC="$TEST_RC" "$@"
SH
  chmod +x "$PROCESS_GATE_HEAVY_LAUNCHER"
  export RECEIPT='PG_TESTS_RECEIPT narrowed 2'
  gate
  [ "$status" -eq 0 ]
  [ "$(head -n 2 "$SEEN")" = "$(printf '%s\n' "$BASE" "$HEAD_SHA")" ]
  assert_receipt 'narrowed: 2 selected'
}

@test "standalone push without explicit scope provides no Tests range" {
  run bash -c 'cd "$PROCESS_GATE_PROJECT_DIR" && bash -p "$1/scripts/check-tests.sh" --mode=push' _ "$SKILL"
  [ "$status" -eq 0 ]
  [ "$(< "$SEEN")" = "$(printf 'unset\nunset\nunset')" ]
}

@test "standalone push with an unresolved head provides no Tests range" {
  run bash -c 'cd "$PROCESS_GATE_PROJECT_DIR" && bash -p "$1/scripts/check-tests.sh" --mode=push "--range=$2..missing"' _ "$SKILL" "$BASE"
  [ "$status" -eq 0 ]
  [ "$(< "$SEEN")" = "$(printf 'unset\nunset\nunset')" ]
}

@test "standalone release unknown and absent modes provide no Tests range" {
  export PG_TESTS_BASE=forged PG_TESTS_HEAD=forged PG_TESTS_RECEIPT_FILE=forged PG_MODE=push
  local mode
  for mode in release unknown ''; do
    run bash -c 'cd "$PROCESS_GATE_PROJECT_DIR" && bash -p "$1/scripts/check-tests.sh" "$2" "--range=$3"' \
      _ "$SKILL" "${mode:+--mode=$mode}" "$BASE..$HEAD_SHA"
    [ "$status" -eq 0 ]
    [ "$(< "$SEEN")" = "$(printf 'unset\nunset\nunset')" ]
  done
}
