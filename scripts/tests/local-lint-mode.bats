#!/usr/bin/env bats
# T20: use the real local config and battery static-stage bodies, but stub
# tools and the battery entrypoint. No full battery or live gate is launched.

setup() {
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  SCRIPT="$ROOT/core-rules/skills/process-gate/scripts/check-tests.sh"
  SANDBOX="$(CDPATH='' cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis-home" TMPDIR="$SANDBOX/tmp"
  export TRELLIS_GATE_STATE_DIR="$SANDBOX/gate-state"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR" "$SANDBOX/bin" "$SANDBOX/project"
  PROJECT="$SANDBOX/project"
  export CLAUDE_PROJECT_DIR="$PROJECT"
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  unset PROCESS_GATE_TYPECHECK_CMD PROCESS_GATE_LINT_CMD PROCESS_GATE_TEST_CMD
  unset PROCESS_GATE_TEST_COVERS_STATIC PROCESS_GATE_COVERAGE_CMD PROCESS_GATE_COVERAGE_FLOOR
  unset PROCESS_GATE_MUTATION_SPOTCHECK PROCESS_GATE_MUTATION_TIMEOUT STATIC_FAILURE
  export PROCESS_GATE_HEAVY_LAUNCHER="$SANDBOX/no-launcher"
  export STATIC_LOG="$SANDBOX/checks.log" STATIC_BATTERY_FUNCTIONS="$SANDBOX/static-stages.sh"
  : > "$STATIC_LOG"
  CONFIG="$PROJECT/.claude/skills/process-gate-local/local.config.sh"
  mkdir -p "${CONFIG%/*}" "$PROJECT/scripts"
  cp "$ROOT/.claude/skills/process-gate-local/local.config.sh" "$CONFIG"

  # Exercise the exact stage bodies the real battery registers, without
  # executing run-tests.sh or its planner, fence, or any test suite.
  awk '/^shellcheck_tree\(\) \{$/,/^\}$/; /^aeo_static_and_python\(\) \{$/,/^\}$/' \
    "$ROOT/scripts/run-tests.sh" > "$STATIC_BATTERY_FUNCTIONS"
  cat > "$SANDBOX/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "$*" = scripts/run-tests-local.py ]; then
  printf 'battery\n' >> "$STATIC_LOG"
  . "$STATIC_BATTERY_FUNCTIONS"
  rc=0
  aeo_static_and_python || rc=1
  shellcheck_tree || rc=1
  exit "$rc"
fi
[ "$*" = '-m unittest discover -s core-rules/skills/aeo-gate/tests -p test_*.py' ]
SH
  cat > "$SANDBOX/bin/ruff" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'ruff fixture'; exit 0 ;;
  format) exit 0 ;;
  check)
    printf 'ruff-check\n' >> "$STATIC_LOG"
    if [ "${STATIC_FAILURE:-}" = lint ]; then
      echo 'fixture.py:1:1: F821 Undefined name fixture_lint_error' >&2
      exit 1
    fi
    ;;
  *) exit 97 ;;
esac
SH
  cat > "$SANDBOX/bin/mypy" <<'SH'
#!/usr/bin/env bash
printf 'mypy\n' >> "$STATIC_LOG"
if [ "${STATIC_FAILURE:-}" = typecheck ]; then
  echo 'fixture.py:1: error: Incompatible types in assignment' >&2
  exit 1
fi
SH
  cat > "$PROJECT/scripts/lint-shell-tree.sh" <<'SH'
printf 'shellcheck\n' >> "$STATIC_LOG"
SH
  cat > "$PROJECT/scripts/narrowed-fixture.sh" <<'SH'
printf 'narrowed\n' >> "$STATIC_LOG"
SH
  mkdir -p "$PROJECT/scripts/tests"
  printf ':\n' > "$PROJECT/scripts/tests/aeo-gate.test.sh"
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"
  git init -q -b main "$PROJECT"
  git -C "$PROJECT" config user.name 'Static Checks Fixture'
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config commit.gpgsign false
}

commit() { git -C "$PROJECT" add -A && git -C "$PROJECT" commit -qm "$1"; }

code_range() {
  commit base
  printf 'changed\n' > "$PROJECT/code.txt"
  commit change
}

docs_range() {
  printf 'allow ^docs/.*\\.md$\n%s\n' "${1:-}" > "${CONFIG%/*}/docs-only-tests.policy"
  commit base
  mkdir -p "$PROJECT/docs"
  printf 'record\n' > "$PROJECT/docs/note.md"
  commit docs
}

run_row() {
  run bash -c 'cd "$1" && bash "$2" --range=main~1..main' _ "$PROJECT" "$SCRIPT"
  echo "$output"
}

count() { grep -cFx "$1" "$STATIC_LOG" || true; }

@test "full battery runs each static check once, not again in the local row" {
  code_range
  run_row
  [ "$status" -eq 0 ]
  [[ "$output" == *'typecheck and lint: included in full test battery'* ]]
  [ "$(count battery)" -eq 1 ]
  [ "$(count mypy)" -eq 1 ]
  [ "$(count ruff-check)" -eq 1 ]
  [ "$(count shellcheck)" -eq 1 ]
}

@test "a full battery lint error still blocks the Tests row" {
  code_range
  export STATIC_FAILURE=lint
  run_row
  [ "$status" -eq 1 ]
  [[ "$output" == *'tests: `python3 scripts/run-tests-local.py` exited 1'* ]]
  [[ "$output" == *'F821 Undefined name fixture_lint_error'* ]]
  [ "$(count battery)" -eq 1 ]
  [ "$(count ruff-check)" -eq 1 ]
}

@test "a docs-only range without tests still blocks on a local lint error" {
  docs_range
  export STATIC_FAILURE=lint
  run_row
  [ "$status" -eq 1 ]
  [[ "$output" == *'Tests: narrowed (docs-only: 1 files)'* ]]
  [[ "$output" == *'lint: '*"exited 1"*'F821 Undefined name fixture_lint_error'* ]]
  [ "$(count battery)" -eq 0 ]
  [ "$(count mypy)" -eq 1 ]
  [ "$(count ruff-check)" -eq 1 ]
}

@test "a narrowed docs tests command still blocks on a local lint error" {
  docs_range 'tests bash scripts/narrowed-fixture.sh'
  export STATIC_FAILURE=lint
  run_row
  [ "$status" -eq 1 ]
  [[ "$output" == *'Tests: narrowed (docs-only: 1 files)'* ]]
  [[ "$output" == *'F821 Undefined name fixture_lint_error'* ]]
  [ "$(count battery)" -eq 0 ]
  [ "$(count narrowed)" -eq 1 ]
  [ "$(count mypy)" -eq 1 ]
  [ "$(count ruff-check)" -eq 1 ]
}

@test "a different narrowed test command keeps local lint and typecheck" {
  printf 'PROCESS_GATE_TEST_CMD="bash scripts/narrowed-fixture.sh"\n' >> "$CONFIG"
  code_range
  export STATIC_FAILURE=lint
  run_row
  [ "$status" -eq 1 ]
  [[ "$output" == *'F821 Undefined name fixture_lint_error'* ]]
  [ "$(count battery)" -eq 0 ]
  [ "$(count narrowed)" -eq 1 ]
  [ "$(count mypy)" -eq 1 ]
  [ "$(count ruff-check)" -eq 1 ]
}

@test "a narrowed typecheck error still blocks when lint passes" {
  docs_range 'tests bash scripts/narrowed-fixture.sh'
  export STATIC_FAILURE=typecheck
  run_row
  [ "$status" -eq 1 ]
  [[ "$output" == *'typecheck: '*"exited 1"*'Incompatible types in assignment'* ]]
  [ "$(count mypy)" -eq 1 ]
  [ "$(count ruff-check)" -eq 1 ]
  [ "$(count shellcheck)" -eq 1 ]
  [ "$(count narrowed)" -eq 1 ]
}

@test "a docs policy naming the covering battery still keeps local static checks" {
  docs_range 'tests python3 scripts/run-tests-local.py'
  run_row
  [ "$status" -eq 0 ]
  [[ "$output" == *'Tests: narrowed (docs-only: 1 files)'* ]]
  [[ "$output" != *'typecheck and lint: included in full test battery'* ]]
  [ "$(count battery)" -eq 1 ]
  [ "$(count mypy)" -eq 2 ]
  [ "$(count ruff-check)" -eq 2 ]
  [ "$(count shellcheck)" -eq 2 ]
}

@test "a changed static command not covered by the tuple still runs locally" {
  printf 'PROCESS_GATE_TYPECHECK_CMD="mypy another-surface"\n' >> "$CONFIG"
  code_range
  run_row
  [ "$status" -eq 0 ]
  [[ "$output" != *'typecheck and lint: included in full test battery'* ]]
  [ "$(count battery)" -eq 1 ]
  [ "$(count mypy)" -eq 2 ]
  [ "$(count ruff-check)" -eq 2 ]
  [ "$(count shellcheck)" -eq 2 ]
}

@test "an inherited covering declaration cannot suppress local checks" {
  awk '/^PROCESS_GATE_TEST_COVERS_STATIC=\(/ { skip=1; next }
       skip && /^\)/ { skip=0; next }
       !skip { print }' "$CONFIG" > "$SANDBOX/no-declaration"
  cp "$SANDBOX/no-declaration" "$CONFIG"
  code_range
  # Exported bash arrays do not cross exec; a scalar is a valid injected
  # one-item declaration and must be cleared, not trusted as config.
  export PROCESS_GATE_TEST_COVERS_STATIC='python3 scripts/run-tests-local.py'
  run_row
  [ "$status" -eq 0 ]
  [[ "$output" != *'typecheck and lint: included in full test battery'* ]]
  [ "$(count battery)" -eq 1 ]
  [ "$(count mypy)" -eq 2 ]
  [ "$(count ruff-check)" -eq 2 ]
  [ "$(count shellcheck)" -eq 2 ]
}
