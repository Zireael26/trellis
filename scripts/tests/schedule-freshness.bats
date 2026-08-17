#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CLI="$ROOT/scripts/check-schedule-freshness.mjs"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/schedule-freshness"
  mkdir -p "$FIXTURE/scheduled-tasks" "$FIXTURE/audits"
  cat > "$FIXTURE/scheduled-tasks/README.md" <<'EOF'
| Task | Cadence | Cron (local) | Purpose |
|---|---|---|---|
| `conductor` | Daily | `0 6 * * *` | slate |
| `dep-currency` | Weekly | `30 11 * * 1` | currency |
| `dep-vulnerabilities` | Weekdays | `30 8 * * 1-5` | vulnerabilities |
EOF

  : > "$FIXTURE/audits/2026-07-25-conductor.md"
  : > "$FIXTURE/audits/2026-08-13-conductor.md"
  : > "$FIXTURE/audits/2026-07-13-dep-currency.md"
  : > "$FIXTURE/audits/2026-08-13-dep-currency.md"
  : > "$FIXTURE/audits/2026-07-24-dep-vulnerabilities.md"
  : > "$FIXTURE/audits/2026-08-13-dep-vulnerabilities.md"
}

@test "known 2026-08-13 conductor and dependency gaps remain execution-unknown without scheduler evidence" {
  run node "$CLI" --root "$FIXTURE" --from 2026-07-20 --as-of 2026-08-13
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.summary.missed == 0)
    and any(.findings[]; .task == "conductor" and .scheduled_for == "2026-07-26" and .status == "execution-unknown")
  ' >/dev/null
  printf '%s' "$output" | jq -e '
    .findings[] | select(.task == "dep-currency" and .scheduled_for == "2026-07-20" and .status == "execution-unknown")
  ' >/dev/null
  printf '%s' "$output" | jq -e '
    .findings[] | select(.task == "dep-vulnerabilities" and .scheduled_for == "2026-07-27" and .status == "execution-unknown")
  ' >/dev/null
}

@test "a completed scheduler receipt makes only its absent artifact missed" {
  cat > "$FIXTURE/receipts.json" <<'EOF'
{
  "runs": [
    { "task": "conductor", "scheduled_for": "2026-08-10", "status": "completed" }
  ]
}
EOF

  run node "$CLI" --root "$FIXTURE" --from 2026-08-10 --as-of 2026-08-11 --execution-receipts "$FIXTURE/receipts.json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .findings[] | select(.task == "conductor" and .scheduled_for == "2026-08-10" and .status == "missed" and .evidence.status == "completed")
  ' >/dev/null
  printf '%s' "$output" | jq -e '
    .findings[] | select(.task == "conductor" and .scheduled_for == "2026-08-11" and .status == "execution-unknown")
  ' >/dev/null
}
