#!/usr/bin/env bats
# The fixture is the REAL catalogue, not a hand-written table: the previous
# fixture asserted on a backticked cron column the real README had already
# replaced with prose, so the suite stayed green while the tool exited 2 on the
# repository it shipped in.

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CLI="$ROOT/scripts/check-schedule-freshness.mjs"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/schedule-freshness"
  HOME_FIX="$FIXTURE/home"
  mkdir -p "$FIXTURE/scheduled-tasks"
  local task
  for task in test-health dep-currency daily-project-digest; do
    mkdir -p "$HOME_FIX/tasks/personal/$task/output"
  done
  cp "$ROOT/scheduled-tasks/README.md" "$FIXTURE/scheduled-tasks/README.md"
  cp "$ROOT/scheduled-tasks/cadence.json" "$FIXTURE/scheduled-tasks/cadence.json"
  # Dated artifacts live in the manifest-bound private output root, which is the
  # only surface a task may write.
  : > "$HOME_FIX/tasks/personal/test-health/output/2026-10-05-test-health.md"
  : > "$HOME_FIX/tasks/personal/test-health/output/2026-10-12-test-health.md"
  : > "$HOME_FIX/tasks/personal/dep-currency/output/2026-10-05-dep-currency.md"
  : > "$HOME_FIX/tasks/personal/daily-project-digest/output/2026-10-05-digest.md"
}

freshness() {
  node "$CLI" --root "$FIXTURE" --home "$HOME_FIX" --fleet personal "$@"
}

@test "the real catalogue parses without a cron column and measures output roots" {
  run freshness --from 2026-10-05 --as-of 2026-10-19
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | jq -e '
    (.schema_version == 2)
    and (.fleet == "personal")
    and (.summary.tasks == 16)
    and (.summary.scheduled == 13)
    and any(.tasks[]; .task == "test-health"
      and .cadence.value == "weekly"
      and .output_root == "'"$HOME_FIX"'/tasks/personal/test-health/output"
      and .observed_runs == 2
      and .expected_runs == 2)
  ' >/dev/null || { printf '%s' "$output" | jq '.summary, [.tasks[]|{task,c:.cadence.value,e:.expected_runs,o:.observed_runs}]'; false; }
}

@test "unscheduled cadences never become expected runs" {
  run freshness --from 2026-10-05 --as-of 2026-10-19
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | jq -e '
    any(.tasks[]; .task == "conductor" and .cadence.value == "on-demand" and .expected_runs == 0)
    and any(.tasks[]; .task == "aeo-baseline" and .cadence.value == "drafted" and .expected_runs == 0)
    and any(.tasks[]; .task == "lean-trend" and .cadence.value == "drafted" and .expected_runs == 0)
  ' >/dev/null
}

@test "a completed scheduler receipt makes only its period missed" {
  cat > "$FIXTURE/receipts.json" <<'EOF'
{
  "runs": [
    { "task": "test-health", "scheduled_for": "2026-10-19", "status": "completed" }
  ]
}
EOF

  run freshness --from 2026-10-05 --as-of 2026-11-03 --execution-receipts "$FIXTURE/receipts.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | jq -e '
    any(.findings[]; .task == "test-health" and .period.start == "2026-10-19"
      and .status == "missed" and .evidence.status == "completed")
    and any(.findings[]; .task == "test-health" and .period.start == "2026-10-26"
      and .status == "execution-unknown")
  ' >/dev/null || { printf '%s' "$output" | jq '[.findings[]|select(.task=="test-health")]'; false; }
}

@test "no coverage evidence is one unknown finding, never a clean or missed run" {
  run node "$CLI" --root "$FIXTURE" --home "$FIXTURE/empty-home" --fleet personal --as-of 2026-10-19
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | jq -e '
    (.summary.missed == 0)
    and any(.findings[]; .task == "test-health" and .scheduled_for == null and .status == "execution-unknown")
  ' >/dev/null
  # conductor and the drafted tasks stay out of the findings entirely.
  printf '%s' "$output" | jq -e '[.findings[] | select(.task == "conductor" or .task == "lean-trend")] | length == 0' >/dev/null
}

@test "a README/ledger cadence divergence fails closed" {
  /usr/bin/sed -i '' 's/^| `test-health` | weekly |/| `test-health` | monthly |/' \
    "$FIXTURE/scheduled-tasks/README.md"
  run freshness --as-of 2026-10-19
  [ "$status" -eq 2 ]
  [[ "$output" == *"cadence mismatch for test-health: README says monthly, cadence.json says weekly"* ]] ||
    { echo "$output"; false; }
}

@test "a ledger entry with no catalogue row fails closed" {
  jq '.tasks["ghost-task"] = {cadence: "weekly"}' "$FIXTURE/scheduled-tasks/cadence.json" \
    > "$FIXTURE/scheduled-tasks/cadence.json.next"
  mv "$FIXTURE/scheduled-tasks/cadence.json.next" "$FIXTURE/scheduled-tasks/cadence.json"
  run freshness --as-of 2026-10-19
  [ "$status" -eq 2 ]
  [[ "$output" == *"ghost-task"* ]] || { echo "$output"; false; }
}

@test "an unknown cadence token fails closed instead of being guessed" {
  /usr/bin/sed -i '' 's/^| `bypass-tripwire` | weekdays |/| `bypass-tripwire` | twice a day |/' \
    "$FIXTURE/scheduled-tasks/README.md"
  run freshness --as-of 2026-10-19
  [ "$status" -eq 2 ]
  [[ "$output" == *"bypass-tripwire"* ]] || { echo "$output"; false; }
}

@test "the shipped repository catalogue parses and exits 0" {
  run node "$CLI" --root "$ROOT" --home "$FIXTURE/empty-home" --fleet personal --as-of 2026-11-19
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | jq -e '.summary.tasks == 16 and .summary.scheduled == 13' >/dev/null
}
