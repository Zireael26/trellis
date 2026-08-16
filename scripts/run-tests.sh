#!/usr/bin/env bash
# Run exactly what CI runs, in one command.
#
# The process-gate's Tests & coverage row used to be pointed at `:` on the
# grounds that "Trellis is a configuration repository … no test runner". That
# stopped being true: .github/workflows/bats.yml runs seven test jobs and
# .github/workflows/shellcheck.yml runs two more, so the gate was reporting a
# green row over an unrun suite — on the repository that defines the gate.
# `.claude/skills/process-gate-local/local.config.sh` now points
# PROCESS_GATE_TEST_CMD here.
#
# Usage: scripts/run-tests.sh [--quick]
#   --quick   run only the fast deterministic slice (shellcheck, AEO static +
#             python, conformance). Intended for a tight local loop, never for
#             a gate run.
#
# Every stage runs even if an earlier one fails; the exit code is the number of
# failed stages, so one red suite cannot hide behind another.

set -uo pipefail

ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

QUICK=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    *) printf 'run-tests: unknown argument: %s\n' "$arg" >&2; exit 64 ;;
  esac
done

FAILED=0
FAILED_STAGES=()

stage() {
  local name="$1"; shift
  printf '\n=== %s ===\n' "$name"
  if "$@"; then
    printf '>>> %s: ok\n' "$name"
  else
    printf '>>> %s: FAILED (exit %s)\n' "$name" "$?"
    FAILED=$((FAILED + 1))
    FAILED_STAGES+=("$name")
  fi
}

shellcheck_tree() {
  find core-rules/ scripts/ scheduled-tasks/ local/ .claude/ specs/ \
    \( -name '*.sh' -o -name '*.bash' \) -type f \
    -not -path 'core-rules/evals/*' -print0 |
    xargs -0 shellcheck --severity=warning
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
  stage "skill gates + spec gate" bats core-rules/skills/*/tests/ scripts/tests/spec-gate.bats
  stage "rollout tools" bats \
    scripts/tests/sync-hooks-settings.bats \
    scripts/tests/sync-merge-gate.bats \
    scripts/tests/hook-inventory.bats \
    scripts/tests/mirror-lint.bats \
    scripts/tests/sync-to-template-dry-run.bats \
    scripts/tests/release-snapshot-predicate.bats
  stage "hermetic launcher regressions" bats \
    scripts/tests/cmux-trellis-teams.bats \
    scripts/tests/setup-runbooks.bats \
    scripts/tests/trellis-launcher.bats \
    scripts/tests/upgrade-semver.bats \
    scripts/tests/launcher-remote-transport.bats
  stage "doctor" bats scripts/tests/doctor.bats
  stage "recipe routing lint" bash scripts/lint-recipe-routing.sh
  stage "dynamic-workflow recipes" bats \
    scripts/tests/digest-adopt.bats \
    scripts/tests/workflow-stage-integrity.bats \
    scripts/tests/orchestrate-recipe-followups.bats \
    scripts/tests/orchestrate-meta-mirror.bats \
    scripts/tests/conductor-ref-refresh.bats \
    scripts/tests/lint-recipe-routing.bats
fi

printf '\n===============================\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'run-tests: all stages passed\n'
else
  printf 'run-tests: %s stage(s) failed:\n' "$FAILED"
  printf '  - %s\n' "${FAILED_STAGES[@]}"
fi
exit "$FAILED"
