#!/usr/bin/env bats
# The local process gate must exercise the complete run-tests stage inventory,
# but it cannot wait for that battery in unit coverage. These tests replace the
# shard runner with a tiny fixture and pin the orchestration contract instead.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
WRAPPER="$REPO_ROOT/scripts/run-tests-local.py"

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/run-tests-local.XXXXXX")"
  FAKE_RUNNER="$SANDBOX/fake-runner.sh"
  INVOCATIONS="$SANDBOX/invocations.log"
  RECEIPTS="$SANDBOX/receipts.log"
  CHILD_PIDS="$SANDBOX/child-pids.log"
  : > "$INVOCATIONS"
  : > "$RECEIPTS"
  : > "$CHILD_PIDS"

  cat > "$FAKE_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

if [ "${3:-}" = "--plan" ]; then
  printf 'shard\tstage\tweight\n'
  for planned_shard in 1 2 3 4; do
    printf 'total\t%s\t100\n' "$planned_shard"
  done
  exit 0
fi

shard_arg="${2#--shard=}"
shard="${shard_arg%%/*}"
printf '%s %s %s\n' "$$" "$1" "$2" >> "$FAKE_INVOCATIONS"
printf '%s\n' "$TRELLIS_TEST_TSV" >> "$FAKE_RECEIPTS"

case "${FAKE_MODE:-pass}" in
  pass)
    printf 'fake-shard-%s\n' "$shard"
    ;;
  fail)
    printf 'fake-shard-%s\n' "$shard"
    [ "$shard" -eq 3 ] && exit 7
    ;;
  receipt)
    printf 'ordinal\tstage\telapsed_seconds\texit\n' > "$TRELLIS_TEST_TSV"
    printf '%s\tfake-stage-%s\t%s\t0\n' "$shard" "$shard" "$shard" >> "$TRELLIS_TEST_TSV"
    ;;
  multi-receipt)
    printf 'ordinal\tstage\telapsed_seconds\texit\n' > "$TRELLIS_TEST_TSV"
    for ordinal in "$shard" "$((shard + 4))"; do
      printf '%s\tfake-stage-%s\t%s\t0\n' "$ordinal" "$ordinal" "$ordinal" >> "$TRELLIS_TEST_TSV"
    done
    ;;
  timeout|signal)
    (
      trap '' INT TERM
      while :; do sleep 0.05; done
    ) &
    printf '%s\n' "$!" >> "$FAKE_CHILD_PIDS"
    while :; do sleep 0.05; done
    ;;
esac
EOF
  chmod +x "$FAKE_RUNNER"
}

teardown() {
  local pid wrapper_pid="${SIGNAL_WRAPPER_PID:-}"
  if [ -n "$wrapper_pid" ] && kill -0 "$wrapper_pid" 2>/dev/null; then
    kill -TERM "$wrapper_pid" 2>/dev/null || true
  fi
  if [ -f "$CHILD_PIDS" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -TERM "$pid" 2>/dev/null || true
    done < "$CHILD_PIDS"
    sleep 0.05
    if [ -n "$wrapper_pid" ]; then
      kill -KILL "$wrapper_pid" 2>/dev/null || true
    fi
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done < "$CHILD_PIDS"
  fi
  if [ -n "$wrapper_pid" ]; then
    wait "$wrapper_pid" 2>/dev/null || true
  fi
  rm -rf "$SANDBOX"
}

run_wrapper() {
  run env \
    TRELLIS_LOCAL_GATE_RUNNER="$FAKE_RUNNER" \
    TRELLIS_LOCAL_GATE_RECEIPT="$SANDBOX/aggregate.tsv" \
    FAKE_MODE="${FAKE_MODE:-pass}" \
    FAKE_INVOCATIONS="$INVOCATIONS" \
    FAKE_RECEIPTS="$RECEIPTS" \
    FAKE_CHILD_PIDS="$CHILD_PIDS" \
    python3 "$WRAPPER"
}

start_signal_wrapper() {
  SIGNAL_OUTPUT="$SANDBOX/signal-output"
  env \
    TRELLIS_LOCAL_GATE_RUNNER="$FAKE_RUNNER" \
    TRELLIS_LOCAL_GATE_RECEIPT="$SANDBOX/aggregate.tsv" \
    TRELLIS_LOCAL_GATE_TERM_GRACE=0.1 \
    FAKE_MODE=signal \
    FAKE_INVOCATIONS="$INVOCATIONS" \
    FAKE_RECEIPTS="$RECEIPTS" \
    FAKE_CHILD_PIDS="$CHILD_PIDS" \
    python3 "$WRAPPER" >"$SIGNAL_OUTPUT" 2>&1 &
  SIGNAL_WRAPPER_PID=$!

  local attempt invocations children
  for ((attempt = 1; attempt <= 100; attempt++)); do
    invocations="$(wc -l < "$INVOCATIONS" | tr -d ' ')"
    children="$(wc -l < "$CHILD_PIDS" | tr -d ' ')"
    if [ "$invocations" -ge 4 ] && [ "$children" -ge 4 ]; then
      return 0
    fi
    if ! kill -0 "$SIGNAL_WRAPPER_PID" 2>/dev/null; then
      wait "$SIGNAL_WRAPPER_PID" 2>/dev/null || true
      return 1
    fi
    sleep 0.01
  done
  return 1
}

wait_signal_wrapper() {
  SIGNAL_STATUS=0
  wait "$SIGNAL_WRAPPER_PID" || SIGNAL_STATUS=$?
}

children_are_alive() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done < "$CHILD_PIDS"
  return 1
}

wait_for_children_to_die() {
  local attempt
  for ((attempt = 1; attempt <= 100; attempt++)); do
    if ! children_are_alive; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

@test "launches exactly four local shard arguments and uses distinct timing receipts" {
  run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(wc -l < "$INVOCATIONS" | tr -d ' ')" -eq 4 ]
  [ "$(sort "$RECEIPTS" | uniq | wc -l | tr -d ' ')" -eq 4 ]
  local shard
  for shard in 1 2 3 4; do
    grep -F -- "--scope=local --shard=$shard/4" "$INVOCATIONS" >/dev/null
  done
}

@test "all passing shards replay output in deterministic order" {
  run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local expected
  expected=$'fake-shard-1\nfake-shard-2\nfake-shard-3\nfake-shard-4'
  [[ "$output" == *"$expected"* ]]
  [[ "$output" == *"planned shard totals: shard 1=100, shard 2=100, shard 3=100, shard 4=100"* ]]
  [[ "$output" == *"shard 1/4"*"status=0"* ]]
  [[ "$output" == *"shard 4/4"*"status=0"* ]]
}

@test "one failing shard fails the aggregate while all four still run" {
  FAKE_MODE=fail run_wrapper
  [ "$status" -eq 1 ] || { echo "$output"; false; }

  [ "$(wc -l < "$INVOCATIONS" | tr -d ' ')" -eq 4 ]
  [[ "$output" == *"shard 3/4"*"status=7"* ]]
  [[ "$output" == *"aggregate receipt:"* ]]
}

@test "global timeout terminates shard process groups and returns 124" {
  FAKE_MODE=timeout \
    run env \
      TRELLIS_LOCAL_GATE_RUNNER="$FAKE_RUNNER" \
      TRELLIS_LOCAL_GATE_RECEIPT="$SANDBOX/aggregate.tsv" \
      TRELLIS_LOCAL_GATE_DEADLINE=0.2 \
      TRELLIS_LOCAL_GATE_TERM_GRACE=0.1 \
      FAKE_MODE=timeout \
      FAKE_INVOCATIONS="$INVOCATIONS" \
      FAKE_RECEIPTS="$RECEIPTS" \
      FAKE_CHILD_PIDS="$CHILD_PIDS" \
      python3 "$WRAPPER"
  [ "$status" -eq 124 ] || { echo "$output"; false; }
  [[ "$output" == *"global deadline exceeded"* ]]

  local pid alive=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then
        alive=1
        break
      fi
    done < "$CHILD_PIDS"
    [ "$alive" -eq 0 ] && break
    sleep 0.05
  done
  [ "$alive" -eq 0 ]
}

@test "SIGINT terminates every shard descendant and preserves status 130" {
  start_signal_wrapper || { cat "$SIGNAL_OUTPUT" 2>/dev/null || true; false; }
  kill -INT "$SIGNAL_WRAPPER_PID"
  wait_signal_wrapper
  [ "$SIGNAL_STATUS" -eq 130 ] || { cat "$SIGNAL_OUTPUT"; false; }
  wait_for_children_to_die || { cat "$SIGNAL_OUTPUT"; false; }
}

@test "SIGTERM terminates every shard descendant and preserves status 143" {
  start_signal_wrapper || { cat "$SIGNAL_OUTPUT" 2>/dev/null || true; false; }
  kill -TERM "$SIGNAL_WRAPPER_PID"
  wait_signal_wrapper
  [ "$SIGNAL_STATUS" -eq 143 ] || { cat "$SIGNAL_OUTPUT"; false; }
  wait_for_children_to_die || { cat "$SIGNAL_OUTPUT"; false; }
}

@test "run-tests --list emits stages without creating a timing receipt" {
  local list_receipt="$SANDBOX/list.tsv"
  run env TRELLIS_TEST_TSV="$list_receipt" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$list_receipt" ]
  [[ "$output" == *"shellcheck (CI scope, severity=warning)"* ]]
}

@test "invalid arguments fail before spawning any shard" {
  run env \
    TRELLIS_LOCAL_GATE_RUNNER="$FAKE_RUNNER" \
    FAKE_INVOCATIONS="$INVOCATIONS" \
    FAKE_RECEIPTS="$RECEIPTS" \
    python3 "$WRAPPER" --not-a-real-option
  [ "$status" -eq 64 ]
  [ ! -s "$INVOCATIONS" ]
}

@test "aggregate receipt contains one header and every shard row" {
  FAKE_MODE=receipt run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local aggregate expected
  aggregate="$(printf '%s\n' "$output" | sed -n 's/.*aggregate receipt: //p' | sed -n '$p')"
  [ -f "$aggregate" ]
  expected=$'ordinal\tstage\telapsed_seconds\texit\n1\tfake-stage-1\t1\t0\n2\tfake-stage-2\t2\t0\n3\tfake-stage-3\t3\t0\n4\tfake-stage-4\t4\t0'
  [ "$(cat "$aggregate")" = "$expected" ]
}

@test "aggregate receipt merges multiple rows per shard by global ordinal" {
  FAKE_MODE=multi-receipt run_wrapper
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local aggregate expected
  aggregate="$(printf '%s\n' "$output" | sed -n 's/.*aggregate receipt: //p' | sed -n '$p')"
  [ -f "$aggregate" ]
  expected=$'ordinal\tstage\telapsed_seconds\texit\n1\tfake-stage-1\t1\t0\n2\tfake-stage-2\t2\t0\n3\tfake-stage-3\t3\t0\n4\tfake-stage-4\t4\t0\n5\tfake-stage-5\t5\t0\n6\tfake-stage-6\t6\t0\n7\tfake-stage-7\t7\t0\n8\tfake-stage-8\t8\t0'
  [ "$(cat "$aggregate")" = "$expected" ]
}

@test "four --list shards partition the complete 1/1 inventory as sets" {
  local baseline="$SANDBOX/list-all.txt"
  local combined="$SANDBOX/list-shards.txt"
  local actual="$SANDBOX/list-shards-unique.txt"
  local shard left right overlap

  run env -u TRELLIS_STAGE_WEIGHTS_TSV TRELLIS_TEST_TSV="$SANDBOX/list-all.tsv" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard=1/1 --list
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/list-all.tsv" ]
  printf '%s\n' "$output" | sort -u > "$baseline"
  [ -s "$baseline" ]

  : > "$combined"
  for shard in 1 2 3 4; do
    run env -u TRELLIS_STAGE_WEIGHTS_TSV TRELLIS_TEST_TSV="$SANDBOX/list-$shard.tsv" \
      bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard="$shard/4" --list
    [ ! -e "$SANDBOX/list-$shard.tsv" ]
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    sort -u <<<"$output" > "$SANDBOX/list-$shard.txt"
    [ -s "$SANDBOX/list-$shard.txt" ]
    cat "$SANDBOX/list-$shard.txt" >> "$combined"
  done

  sort -u "$combined" > "$actual"
  [ "$(cat "$baseline")" = "$(cat "$actual")" ]

  for left in 1 2 3 4; do
    for right in 1 2 3 4; do
      [ "$left" -lt "$right" ] || continue
      overlap="$SANDBOX/overlap-$left-$right.txt"
      comm -12 "$SANDBOX/list-$left.txt" "$SANDBOX/list-$right.txt" > "$overlap"
      [ ! -s "$overlap" ]
    done
  done
}

@test "four-way --plan stays within half the shipped total weight" {
  local plan="$SANDBOX/plan.tsv"
  local expected_total

  run env -u TRELLIS_STAGE_WEIGHTS_TSV TRELLIS_TEST_TSV="$SANDBOX/plan-receipt.tsv" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard=1/4 --plan
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" > "$plan"
  [ ! -e "$SANDBOX/plan-receipt.tsv" ]
  [ "$(sed -n '1p' "$plan")" = $'shard\tstage\tweight' ]

  expected_total="$(awk -F '\t' 'NR > 1 { total += $2 } END { print total + 0 }' \
    "$REPO_ROOT/scripts/tests/stage-weights.tsv")"
  awk -F '\t' -v expected="$expected_total" '
    $1 == "total" {
      count++
      weight = $3 + 0
      if (weight > max) max = weight
    }
    END {
      if (count != 4 || 2 * max > expected) exit 1
    }
  ' "$plan"
}

@test "missing stage weight defaults to 30 in exactly one planned row" {
  local shipped="$REPO_ROOT/scripts/tests/stage-weights.tsv"
  local weights="$SANDBOX/missing-stage-weights.tsv"
  local plan="$SANDBOX/missing-stage-plan.tsv"
  local missing_stage

  missing_stage="$(awk -F '\t' 'NR == 2 { print $1; exit }' "$shipped")"
  [ -n "$missing_stage" ]
  awk -F '\t' -v missing="$missing_stage" \
    'NR == 1 || $1 != missing' "$shipped" > "$weights"
  [ "$(awk -F '\t' -v missing="$missing_stage" \
    '$1 == missing { count++ } END { print count + 0 }' "$weights")" -eq 0 ]

  run env \
    TRELLIS_STAGE_WEIGHTS_TSV="$weights" \
    TRELLIS_TEST_TSV="$SANDBOX/missing-plan-receipt.tsv" \
    bash "$REPO_ROOT/scripts/run-tests.sh" --scope=local --shard=1/4 --plan
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" > "$plan"
  [ ! -e "$SANDBOX/missing-plan-receipt.tsv" ]
  awk -F '\t' -v missing="$missing_stage" '
    $1 ~ /^[0-9]+$/ && $2 == missing {
      count++
      if (($3 + 0) != 30) wrong = 1
    }
    END {
      exit !(count == 1 && wrong == 0)
    }
  ' "$plan"
}
