#!/usr/bin/env bats
# The AEO gate's ruff rule set is pinned on the command line (spec 058).
#
# Both gate rows ran bare `ruff check`, so the rule set was whatever the
# resolved binary enabled by default. With no config anywhere, ruff 0.16.7
# enables a wider set than 0.15.5 (CI's pin) and failed every PR gate with 35
# findings that 0.15.5 does not report. The pin is `--isolated` (no config
# discovery) plus an explicit `--select`, in both rows.
#
# These are literal assertions, not a lint run: they go red on any machine,
# with any ruff or none, when either pin is removed. The behavioral inversion
# on 0.16.7 is a receipt in specs/058-ruff-rule-pin/receipts/.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"
LOCAL_CONFIG="$REPO_ROOT/.claude/skills/process-gate-local/local.config.sh"

@test "aeo_static_and_python runs exactly the two pinned ruff commands" {
  local body commands expected
  body="$(sed -n '/^aeo_static_and_python() {$/,/^}$/p' "$RUN_TESTS")"
  [ -n "$body" ] || { echo 'aeo_static_and_python not found in run-tests.sh'; false; }

  # Every line that invokes ruff format/check, with indentation and the
  # trailing `&&` stripped. `ruff --version` (the receipt line) is excluded.
  commands="$(printf '%s\n' "$body" |
    sed -nE 's/^[[:space:]]*(ruff (format|check) .*[^[:space:]&])[[:space:]]*(&&)?[[:space:]]*$/\1/p')"
  expected="ruff format --isolated --check core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests
ruff check --isolated --select E4,E7,E9,F core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests"

  [ "$commands" = "$expected" ] || {
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$commands"
    false
  }
}

@test "PROCESS_GATE_LINT_CMD is the pinned command" {
  local expected
  expected="ruff check --isolated --select E4,E7,E9,F core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests && bash scripts/lint-shell-tree.sh"

  # Clean environment: a pre-exported value must not stand in for the file's.
  run env -u PROCESS_GATE_LINT_CMD bash -c '. "$1" && printf "%s" "$PROCESS_GATE_LINT_CMD"' _ "$LOCAL_CONFIG"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$expected" ] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$output"
    false
  }
}

@test "the installed aeo-gate skill ships no ruff config" {
  local found
  found="$(find "$REPO_ROOT/core-rules/skills/aeo-gate" \
    \( -name ruff.toml -o -name .ruff.toml -o -name pyproject.toml \) -print)"

  [ -z "$found" ] || { echo "lint config under aeo-gate: $found"; false; }
}
