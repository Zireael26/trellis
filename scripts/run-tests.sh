#!/usr/bin/env bash
# Run exactly what CI runs, in one command.
#
# The process-gate's Tests & coverage row used to be pointed at `:` on the
# grounds that "Trellis is a configuration repository … no test runner". That
# stopped being true: .github/workflows/bats.yml runs the same stages this
# script does and .github/workflows/shellcheck.yml runs two more, so the gate
# was reporting a green row over an unrun suite — on the repository that defines
# the gate. `.claude/skills/process-gate-local/local.config.sh` now points
# PROCESS_GATE_TEST_CMD here.
#
# The `scripts/tests/` suites are ENUMERATED, never hand-listed. Both this
# script and the workflow used to name their suites one by one and both lists
# had drifted to 20 of 57 — the 37 omissions were nearly the whole portable
# fleet surface, and one of them was red at the committed tip while the gate
# reported pass. `scripts/lib/test-suites.sh` holds the one exclusion list, and
# `scripts/tests/suite-coverage.bats` fails when a suite is neither globbed nor
# excluded there.
#
# Usage: scripts/run-tests.sh [--quick] [--scope=local|ci] [--shard=I/N] [--list]
#   --quick        run only the fast deterministic slice (shellcheck, AEO static
#                  + python, conformance, bootstrap prologues). Intended for a
#                  tight local loop, never for a gate run.
#   --scope=ci     apply the CI exclusions as well as the global ones.
#   --shard=I/N    run stage I of N, round-robin over the ordered stage list.
#                  The workflow fans these out across a matrix; locally the
#                  default 1/1 runs everything.
#   --list         print the stage names this invocation would run, and exit 0.
#                  Concatenating the four shards' lists must reproduce the 1/1
#                  list exactly — suite-coverage.bats asserts that.
#
# Every stage runs even if an earlier one fails; the exit code is the number of
# failed stages, so one red suite cannot hide behind another.

set -uo pipefail

ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

# shellcheck source=scripts/lib/test-suites.sh
. "$ROOT/scripts/lib/test-suites.sh"

QUICK=0
LIST=0
SCOPE=local
SHARD_INDEX=1
SHARD_TOTAL=1
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --list) LIST=1 ;;
    --scope=*) SCOPE="${arg#--scope=}" ;;
    --shard=*)
      SHARD_INDEX="${arg#--shard=}"
      SHARD_TOTAL="${SHARD_INDEX#*/}"
      SHARD_INDEX="${SHARD_INDEX%%/*}"
      ;;
    *) printf 'run-tests: unknown argument: %s\n' "$arg" >&2; exit 64 ;;
  esac
done

case "$SCOPE" in
  local|ci) ;;
  *) printf 'run-tests: unknown scope: %s\n' "$SCOPE" >&2; exit 64 ;;
esac
case "$SHARD_INDEX$SHARD_TOTAL" in
  *[!0-9]*|'') printf 'run-tests: --shard expects I/N\n' >&2; exit 64 ;;
esac
if [ "$SHARD_TOTAL" -lt 1 ] || [ "$SHARD_INDEX" -lt 1 ] || [ "$SHARD_INDEX" -gt "$SHARD_TOTAL" ]; then
  printf 'run-tests: --shard=%s/%s is out of range\n' "$SHARD_INDEX" "$SHARD_TOTAL" >&2
  exit 64
fi

FAILED=0
RAN=0
SKIPPED=0
FAILED_STAGES=()
STAGE_ORDINAL=0

# Round-robin ownership: stage k belongs to shard ((k mod N) + 1).
stage() {
  local name="$1"; shift
  STAGE_ORDINAL=$((STAGE_ORDINAL + 1))
  if [ "$SHARD_TOTAL" -gt 1 ] &&
     [ "$(( (STAGE_ORDINAL - 1) % SHARD_TOTAL + 1 ))" -ne "$SHARD_INDEX" ]; then
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  RAN=$((RAN + 1))
  if [ "$LIST" -eq 1 ]; then
    printf '%s\n' "$name"
    return 0
  fi
  printf '\n=== %s ===\n' "$name"
  if "$@"; then
    printf '>>> %s: ok\n' "$name"
  else
    printf '>>> %s: FAILED (exit %s)\n' "$name" "$?"
    FAILED=$((FAILED + 1))
    FAILED_STAGES+=("$name")
  fi
}

# Enumeration lives in scripts/lint-shell-tree.sh, shared with
# .github/workflows/shellcheck.yml. Both used to carry their own suffix-only
# `find`, which left every extensionless script — the pre-push hooks and the
# `trellis` entrypoint among them — unlinted in either place.
shellcheck_tree() {
  bash scripts/lint-shell-tree.sh
}

aeo_static_and_python() {
  ruff format --check core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests &&
    ruff check core-rules/skills/aeo-gate/scripts core-rules/skills/aeo-gate/tests &&
    mypy core-rules/skills/aeo-gate/scripts/lib/aeo_gate &&
    python3 -m unittest discover -s core-rules/skills/aeo-gate/tests -p 'test_*.py' &&
    bash scripts/tests/aeo-gate.test.sh
}

stage "shellcheck (CI scope, severity=warning)" shellcheck_tree
stage "POSIX bootstrap prologues" bats scripts/tests/posix-bootstrap-prologue.bats
stage "AEO contract, static, and entrypoint" aeo_static_and_python
stage "conformance-check" bash scripts/conformance-check.sh

if [ "$QUICK" -eq 0 ]; then
  stage "hooks (claude + codex)" bats core-rules/hooks/tests/ core-rules/codex/hooks/tests/
  stage "skill gates" bats core-rules/skills/*/tests/
  stage "recipe routing lint" bash scripts/lint-recipe-routing.sh

  # One stage per suite: a failure names the suite that caused it, and the exit
  # code stays an honest count of failing suites.
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    # posix-bootstrap-prologue already ran above as part of the quick slice.
    [ "$suite" = "posix-bootstrap-prologue" ] && continue
    stage "bats scripts/tests/$suite.bats" bats "scripts/tests/$suite.bats"
  done < <(test_suites_for "$SCOPE")
fi

if [ "$LIST" -eq 1 ]; then
  exit 0
fi

printf '\n===============================\n'
printf 'run-tests: scope=%s shard=%s/%s stages ran=%s skipped=%s\n' \
  "$SCOPE" "$SHARD_INDEX" "$SHARD_TOTAL" "$RAN" "$SKIPPED"
if [ "$FAILED" -eq 0 ]; then
  printf 'run-tests: all stages passed\n'
else
  printf 'run-tests: %s stage(s) failed:\n' "$FAILED"
  printf '  - %s\n' "${FAILED_STAGES[@]}"
fi
exit "$FAILED"
