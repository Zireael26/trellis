#!/usr/bin/env bats
# Exercise only the real aggregator: every row runs fixture code, never a gate.

setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/gate-rows.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export TRELLIS_GATE_STATE_DIR="$SANDBOX/state"
  export ROW_LOG="$SANDBOX/rows"
  unset CODEX_PROJECT_DIR TRELLIS_ROOT BASH_ENV ENV
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  REPO="$SANDBOX/repo"
  SKILL="$SANDBOX/process-gate"
  mkdir -p "$REPO/.claude/skills/process-gate-local" "$SKILL/scripts/lib"
  local real="$SOURCE/core-rules/skills/process-gate/scripts"
  cp "$real/run-all.sh" "$SKILL/scripts/"
  cp "$real/lib/common.sh" "$real/lib/diff-base.sh" "$real/lib/validator-env.sh" "$SKILL/scripts/lib/"
  local name idx=0
  for name in pr secrets bypass tests docs stack security-diff analyze slop; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s >> "$ROW_LOG"\n' "$idx" > "$SKILL/scripts/check-$name.sh"
    if [ "$name" = tests ]; then
      printf 'sleep "${TEST_DELAY:-0}"\n' >> "$SKILL/scripts/check-$name.sh"
    fi
    if [ "$name" = slop ]; then
      printf 'printf "%%s\\n" "${SLOP_LEVEL:-info} fixture row 8"\n' >> "$SKILL/scripts/check-$name.sh"
    else
      printf 'printf "fixture row %s\\n"\n' "$idx" >> "$SKILL/scripts/check-$name.sh"
    fi
    printf 'exit "${ROW_RC_%s:-0}"\n' "$idx" >> "$SKILL/scripts/check-$name.sh"
    idx=$((idx + 1))
  done
  cp "$SKILL/scripts/check-stack.sh" "$REPO/.claude/skills/process-gate-local/stack.sh"
  printf 'PROCESS_GATE_STACK_PROFILE=fixture\nPROCESS_GATE_STACK_VALIDATORS=(stack.sh)\n' > "$REPO/.claude/skills/process-gate-local/local.config.sh"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email fixture@example.invalid
  git -C "$REPO" config user.name fixture
  git -C "$REPO" config core.hooksPath "$SANDBOX/no-hooks"
  git -C "$REPO" add .
  git -C "$REPO" -c commit.gpgsign=false commit -qm 'chore: fixture'
  BASE="$(git -C "$REPO" rev-parse --short=12 HEAD)"
  export CLAUDE_PROJECT_DIR="$REPO"
  cd "$REPO"
}

run_fixture() {
  local mode="$1"
  shift
  run env "$@" bash -p "$SKILL/scripts/run-all.sh" "--mode=$mode" --range=main..HEAD
}

@test "verdict snapshots preserve pass, warn, fail and preflight BLOCKED" {
  local actual="$SANDBOX/verdicts.txt"
  run_fixture merge
  [ "$status" -eq 0 ]
  printf '=== pass (rc=%s) ===\n%s\n' "$status" "${output//$BASE/<base>}" > "$actual"

  run_fixture push ROW_RC_0=1 ROW_RC_1=2 ROW_RC_4=1 ROW_RC_5=2 ROW_RC_7=1 SLOP_LEVEL=warn
  [ "$status" -eq 2 ]
  printf '\n=== warn (rc=%s) ===\n%s\n' "$status" "${output//$BASE/<base>}" >> "$actual"

  run_fixture merge ROW_RC_0=1 ROW_RC_1=1 ROW_RC_2=1 ROW_RC_3=1 ROW_RC_4=1 ROW_RC_5=1 ROW_RC_6=1 ROW_RC_7=1 SLOP_LEVEL=fail
  [ "$status" -eq 1 ]
  printf '\n=== fail (rc=%s) ===\n%s\n' "$status" "${output//$BASE/<base>}" >> "$actual"

  run bash -p "$SKILL/scripts/run-all.sh" --mode=merge --range=missing..HEAD
  [ "$status" -eq 1 ]
  printf '\n=== blocked (rc=%s) ===\n%s\n' "$status" "$output" >> "$actual"
  diff -u "$SOURCE/scripts/tests/fixtures/process-gate-verdicts.txt" "$actual"
}

assert_row_order() {
  local expected="$1"
  [ "$(tr '\n' ' ' < "$ROW_LOG")" = "$expected" ]
}

@test "all cheap rows precede Tests on clean, warning and failed merge runs" {
  run_fixture push
  [ "$status" -eq 0 ]
  assert_row_order '0 1 2 4 5 6 7 8 3 '

  : > "$ROW_LOG"
  run_fixture push ROW_RC_0=1 ROW_RC_4=1 ROW_RC_7=1 ROW_RC_1=2 ROW_RC_2=2 ROW_RC_5=2 ROW_RC_6=2 SLOP_LEVEL=warn
  [ "$status" -eq 2 ]
  assert_row_order '0 1 2 4 5 6 7 8 3 '

  : > "$ROW_LOG"
  run_fixture merge ROW_RC_1=1 ROW_RC_2=1 ROW_RC_5=1 ROW_RC_6=1 SLOP_LEVEL=fail
  [ "$status" -eq 1 ]
  assert_row_order '0 1 2 4 5 6 7 8 3 '
}

@test "each hard cheap push failure skips only Tests and emits one BLOCKED verdict" {
  local failure
  for failure in ROW_RC_1=1 ROW_RC_2=1 ROW_RC_5=1 ROW_RC_6=1 SLOP_LEVEL=fail ROW_RC_1=3 ROW_RC_6=127 SLOP_LEVEL=invalid ROW_RC_8=3; do
    : > "$ROW_LOG"
    run_fixture push "$failure"
    [ "$status" -eq 1 ]
    assert_row_order '0 1 2 4 5 6 7 8 '
    [[ "$output" == *'Tests & coverage:  ➖ n/a'* ]]
    [[ "$output" == *'Tests: not run (mode=push: always-hard cheap row failed; battery skipped)'* ]]
    [ "$(printf '%s\n' "$output" | grep -c '^## process-gate verdict')" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c '^Overall: BLOCKED$')" -eq 1 ]
  done

  : > "$ROW_LOG"
  run_fixture push ROW_RC_0=1 ROW_RC_4=1 ROW_RC_7=1 ROW_RC_3=1
  [ "$status" -eq 1 ]
  assert_row_order '0 1 2 4 5 6 7 8 3 '
  [[ "$output" == *'Tests & coverage:  ❌ fail'* ]]
  [[ "$output" != *'Tests: not run'* ]]
}

@test "push early-failure fixture skips delayed Tests and reports time to refusal" {
  run env ROW_RC_1=1 TEST_DELAY=2 python3 -I -c '
import statistics
import subprocess
import sys
import time

elapsed = []
for _ in range(5):
    start = time.perf_counter()
    result = subprocess.run(["bash", "-p", sys.argv[1], "--mode=push", "--range=main..HEAD"], capture_output=True, text=True)
    elapsed.append(time.perf_counter() - start)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Overall: BLOCKED" in result.stdout, result.stdout
print("refusal seconds: " + ", ".join(f"{value:.3f}" for value in elapsed))
print(f"refusal median seconds: {statistics.median(elapsed):.3f}")
' "$SKILL/scripts/run-all.sh"
  [ "$status" -eq 0 ]
  printf '# %s\n' "$output" >&3
  [ "$(grep -c '^3$' "$ROW_LOG" || true)" -eq 0 ]
  [ "$(wc -l < "$ROW_LOG" | tr -d ' ')" -eq 40 ]
}
