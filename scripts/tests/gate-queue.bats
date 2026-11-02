#!/usr/bin/env bats
# Queue-only real processes; never launch a battery or use the caller's state.

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gate-queue.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
  TESTS="$BATS_TEST_DIRNAME/test_gate_queue.py"
}

teardown() { rm -rf "$SANDBOX"; }

check_queue() {
  run python3 -I "$TESTS" "QueueTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "queue serializes runners and refreshes holder and waiter heartbeats" { check_queue test_serial_and_heartbeat; }
@test "queue pins agent and cron state regardless of XDG_STATE_HOME" { check_queue test_default_state_root_ignores_agent_and_cron_xdg; }
@test "queue refuses relative and checkout-local state before writing" { check_queue test_state_root_refuses_relative_checkout_and_symlink_into_checkout; }
@test "queue holder keeps the legacy flock until close" { check_queue test_holder_keeps_legacy_lock_until_close; }
@test "queue waits behind a legacy holder and no-wait refuses" { check_queue test_legacy_holder_blocks_queue_and_no_wait; }
@test "queue passes a killed holder within the lease bound" { check_queue test_kill_holder; }
@test "queue skips a killed head waiter" { check_queue test_kill_head_waiter; }
@test "queue racers receive distinct ordered tickets" { check_queue test_racing_tickets; }
@test "queue bounded wait and no-wait refuse with 70" { check_queue test_bounded_and_no_wait; }
@test "queue corrupt ticket counter refuses without following symlinks" { check_queue test_corrupt_counter_refuses_without_following_symlinks; }
@test "queue corrupt holder refuses without removing evidence" { check_queue test_corrupt_holder_refuses; }
@test "queue corrupt waiter is quarantined and skipped" { check_queue test_corrupt_waiter_quarantined; }
@test "queue heartbeat cannot consume signals during child registration" { check_queue test_heartbeat_thread_cannot_consume_registration_signals; }
@test "queue shutdown is bounded and retains an unverified heartbeat lease" { check_queue test_shutdown_retains_lease_when_heartbeat_wedged; }
@test "queue wait does not consume the run deadline" { check_queue test_wait_is_outside_deadline; }
@test "queue holder and waiter stale heartbeat requires two checks" { check_queue test_same_stale_rule_requires_two_checks; }
