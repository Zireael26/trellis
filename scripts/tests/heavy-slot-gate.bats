#!/usr/bin/env bats
# Spec 054: `trellis heavy`, the machine-wide slot gate for heavy test runs.
# One @test (or small group) per gate criterion H1-H9 and HA1-HA5 (Amendment
# A1, the light pool); H8 lives with the process gate in
# core-rules/skills/process-gate/tests/check-tests.bats.
#
# Hermetic: HOME and TRELLIS_HOME are sandbox paths, and every slot lives in a
# sandbox TRELLIS_HEAVY_DIR (honoured only with TRELLIS_HEAVY_TEST=1). Nothing
# here touches a real slot directory. Background jobs close fd 3 so bats never
# waits on them, and teardown kills every pid a test recorded.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/heavy.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  export TRELLIS_HEAVY_TEST=1
  export TRELLIS_HEAVY_DIR="$SANDBOX/slots"
  export TRELLIS_HEAVY_TEST_POLL=0.1
  unset TRELLIS_HEAVY_FD TRELLIS_HEAVY_SLOT TRELLIS_HEAVY_DIR_ID TRELLIS_HEAVY_POOL TRELLIS_HEAVY_CALLER_ENV
  unset TRELLIS_HEAVY_LIGHT_WARN TRELLIS_HEAVY_KILL_AFTER TRELLIS_HEAVY_TEST_PAUSE TRELLIS_HEAVY_TEST_TRACE
  unset TRELLIS_HEAVY_TEST_HEARTBEAT TRELLIS_HEAVY_TEST_FAIL TRELLIS_VERIFIED_PAYLOAD
  mkdir -p "$HOME" "$TRELLIS_HOME" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  # `trellis` on the workload's PATH, for nested calls.
  printf '#!/bin/bash\nexec %q "$@"\n' "$REPO_ROOT/scripts/trellis" > "$SANDBOX/bin/trellis"
  chmod 755 "$SANDBOX/bin/trellis"
  export PATH="$SANDBOX/bin:$PATH"
  HEAVY=("$REPO_ROOT/scripts/trellis" heavy)
  PIDS=()
  write_config 2
}

teardown() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  find "$SANDBOX" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$SANDBOX"
}

# write_config N [L]  — heavy_slots and heavy_light_slots as raw JSON; an
# empty (or, for L, absent) value omits the key.
write_config() {
  local slots="$1" light="${2:-}"
  jq -n --arg source "$SANDBOX/source" --arg projects "$SANDBOX/projects" --arg slots "$slots" --arg light "$light" '
    {
      schema_version: 1,
      source_root: $source,
      release_remote: "fixture://release",
      active_cli_release: "1.2.3",
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$projects]}}
    } + (if $slots == "" then {} else {heavy_slots: ($slots | fromjson)} end)
      + (if $light == "" then {} else {heavy_light_slots: ($light | fromjson)} end)
  ' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

wait_for_file() {
  local path="$1" tries="${2:-100}"
  while [ ! -e "$path" ] && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  [ -e "$path" ] || { echo "timed out waiting for $path"; false; }
}

wait_for_grep() {
  local pattern="$1" path="$2" tries="${3:-100}"
  while ! grep -q -- "$pattern" "$path" 2>/dev/null && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  grep -q -- "$pattern" "$path" || { echo "timed out waiting for '$pattern' in $path"; cat "$path" 2>/dev/null; false; }
}

pid_gone() {
  local pid="$1" tries="${2:-60}"
  while kill -0 "$pid" 2>/dev/null && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

# heavy_bg NAME ARGS...  — run `trellis heavy ARGS...` in the background with
# output in $SANDBOX/NAME.out; its pid (the supervisor, after the execs) is
# left in BG_PID.
heavy_bg() {
  local name="$1"
  shift
  "${HEAVY[@]}" "$@" > "$SANDBOX/$name.out" 2>&1 3>&- &
  BG_PID=$!
  PIDS+=("$BG_PID")
}

# hold_slot I SECONDS [PREFIX]  — hold PREFIX-I.lock (default slot, the heavy
# pool; light for the light pool) with a raw flock and no info file.
hold_slot() {
  local i="$1" secs="$2" prefix="${3:-slot}"
  [ -d "$TRELLIS_HEAVY_DIR" ] || mkdir -m 700 "$TRELLIS_HEAVY_DIR"
  perl -MFcntl=:DEFAULT,:flock -e '
    sysopen(my $h, $ARGV[0], O_RDWR | O_CREAT, 0600) or die "open: $!";
    flock($h, LOCK_EX) or die "flock: $!";
    open(my $r, ">", $ARGV[1]) or die; close $r;
    sleep $ARGV[2];
  ' "$TRELLIS_HEAVY_DIR/$prefix-$i.lock" "$SANDBOX/raw-$prefix-$i.ready" "$secs" 3>&- &
  PIDS+=("$!")
  HOLD_PID=$!
  wait_for_file "$SANDBOX/raw-$prefix-$i.ready"
}

# hold_token_slot I TOKEN  — hold slot-I.lock with its own description and
# publish TOKEN as the holder's ownership token, the way a supervisor does. On
# TERM it removes the token and only then exits (releasing the lock), exactly
# as a supervisor releases. HOLD_PID is its pid.
hold_token_slot() {
  local i="$1" token="$2"
  [ -d "$TRELLIS_HEAVY_DIR" ] || mkdir -m 700 "$TRELLIS_HEAVY_DIR"
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($lock, $tokfile, $token, $ready) = @ARGV;
    sysopen(my $h, $lock, O_RDWR | O_CREAT, 0600) or die "open: $!";
    flock($h, LOCK_EX) or die "flock: $!";
    sysopen(my $t, $tokfile, O_WRONLY | O_CREAT | O_TRUNC, 0600) or die; print $t "$token\n"; close $t or die;
    chmod 0600, $tokfile or die;
    $SIG{TERM} = sub { unlink $tokfile; exit 0 };
    open(my $r, ">", $ready) or die; close $r;
    sleep 1 while 1;
  ' "$TRELLIS_HEAVY_DIR/slot-$i.lock" "$TRELLIS_HEAVY_DIR/slot-$i.token" "$token" "$SANDBOX/tok-$i.ready" 3>&- &
  PIDS+=("$!")
  HOLD_PID=$!
  wait_for_file "$SANDBOX/tok-$i.ready"
}

slot_dir_id() { perl -e '@s = stat($ARGV[0]); print "$s[0]:$s[1]"' "$TRELLIS_HEAVY_DIR"; }

# Maximum number of overlapping [start, end] intervals in $SANDBOX/events.
max_overlap() {
  sort -k3,3n -k2,2 "$SANDBOX/events" | awk '
    $2 == "start" { n++; if (n > max) max = n }
    $2 == "end" { n-- }
    END { print max + 0 }'
}

write_job() {
  cat > "$SANDBOX/job.sh" <<EOF
#!/bin/bash
printf '%s start %s\n' "\$1" "\$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" >> "$SANDBOX/events"
sleep "\$2"
printf '%s end %s\n' "\$1" "\$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" >> "$SANDBOX/events"
EOF
  chmod 755 "$SANDBOX/job.sh"
}

# ---------------------------------------------------------------- H1

@test "H1: N=1 runs jobs one at a time" {
  write_config 1
  write_job
  local job pids=()
  for job in a b c; do
    heavy_bg "$job" --lane "h1-$job" -- "$SANDBOX/job.sh" "$job" 0.4
    pids+=("$BG_PID")
  done
  for job in "${pids[@]}"; do wait "$job"; done
  [ "$(grep -c ' end ' "$SANDBOX/events")" -eq 3 ] || { cat "$SANDBOX/events"; false; }
  [ "$(max_overlap)" -eq 1 ] || { cat "$SANDBOX/events"; false; }
}

@test "H1: N=2 runs at most two jobs at once, and does run two" {
  write_config 2
  write_job
  local job pids=()
  for job in a b c d; do
    heavy_bg "$job" -- "$SANDBOX/job.sh" "$job" 0.8
    pids+=("$BG_PID")
  done
  for job in "${pids[@]}"; do wait "$job"; done
  [ "$(grep -c ' end ' "$SANDBOX/events")" -eq 4 ] || { cat "$SANDBOX/events"; false; }
  [ "$(max_overlap)" -eq 2 ] || { cat "$SANDBOX/events"; false; }
}

# ---------------------------------------------------------------- H2

@test "H2: a SIGKILLed supervisor leaves the slot held until its child exits" {
  write_config 1
  heavy_bg sup -- sh -c "echo \$\$ > '$SANDBOX/child'; sleep 1.5"
  wait_for_file "$SANDBOX/child"
  kill -KILL "$BG_PID"
  wait "$BG_PID" 2>/dev/null || true
  local child
  child="$(cat "$SANDBOX/child")"
  kill -0 "$child"
  run "${HEAVY[@]}" --status
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"slot 1: held"* ]] || { echo "$output"; false; }
  pid_gone "$child"
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: free"* ]] || { echo "$output"; false; }
  # The one documented exception to token cleanup (A2 §3): a SIGKILLed holder
  # leaves its token behind, stale, until the next holder overwrites it.
  [ -f "$TRELLIS_HEAVY_DIR/slot-1.token" ]
}

@test "H2: a background grandchild keeps the slot after the direct child exits" {
  write_config 1
  heavy_bg gc -- sh -c "(sleep 1.2; touch '$SANDBOX/gc-done') 3>&- & echo \$\$ > '$SANDBOX/leader'; exit 0"
  wait_for_file "$SANDBOX/leader"
  sleep 0.3
  [ ! -e "$SANDBOX/gc-done" ]
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: held"* ]] || { echo "$output"; false; }
  wait "$BG_PID"
  [ -e "$SANDBOX/gc-done" ]
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: free"* ]] || { echo "$output"; false; }
}

@test "H2: a Python close_fds=True grandchild without the descriptor still holds the slot" {
  write_config 1
  heavy_bg py -- python3 -c '
import os, subprocess, sys
d = sys.argv[1]
subprocess.Popen(["sh", "-c", "if [ -e /dev/fd/$TRELLIS_HEAVY_FD ]; then echo has-fd; else echo no-fd; fi > %s/gc-fd; sleep 1.2; touch %s/gc-done" % (d, d)], close_fds=True)
open(d + "/leader", "w").close()
' "$SANDBOX"
  wait_for_file "$SANDBOX/leader"
  wait_for_file "$SANDBOX/gc-fd"
  [ "$(cat "$SANDBOX/gc-fd")" = no-fd ]
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: held"* ]] || { echo "$output"; false; }
  wait "$BG_PID"
  [ -e "$SANDBOX/gc-done" ]
}

@test "H2: the lock descriptor survives exec with FD_CLOEXEC cleared" {
  run "${HEAVY[@]}" -- sh -c '
    [ "$TRELLIS_HEAVY_FD" -ge 64 ] || exit 11
    [ -e "/dev/fd/$TRELLIS_HEAVY_FD" ] || exit 12
    exec perl -e "
      open(my \$h, q(+<&=), \$ENV{TRELLIS_HEAVY_FD}) or exit 13;
      my @a = stat(\$h);
      my @b = stat(qq(\$ENV{TRELLIS_HEAVY_DIR}/slot-\$ENV{TRELLIS_HEAVY_SLOT}.lock));
      exit((\$a[0] == \$b[0] && \$a[1] == \$b[1]) ? 0 : 14);
    "'
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}

# ---------------------------------------------------------------- H3

@test "H3: SIGTERM tears the whole group down, exits 143, and spares the caller" {
  sleep 30 3>&- &
  local sentinel=$!
  PIDS+=("$sentinel")
  heavy_bg term -- sh -c "echo \$\$ > '$SANDBOX/leader'; sleep 30 3>&- & echo \$! > '$SANDBOX/gc'; wait"
  wait_for_file "$SANDBOX/gc"
  local start end rc=0
  start="$(now)"
  kill -TERM "$BG_PID"
  wait "$BG_PID" || rc=$?
  end="$(now)"
  [ "$rc" -eq 143 ] || { echo "rc=$rc"; cat "$SANDBOX/term.out"; false; }
  # Torn down now, not when the 30 s workload would have ended.
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 5 ? 0 : 1)' "$start" "$end"
  pid_gone "$(cat "$SANDBOX/leader")"
  pid_gone "$(cat "$SANDBOX/gc")"
  kill -0 "$sentinel"
}

@test "H3: a group member that ignores TERM is KILLed after TRELLIS_HEAVY_KILL_AFTER" {
  local start end
  start="$(now)"
  TRELLIS_HEAVY_KILL_AFTER=1 run "${HEAVY[@]}" --timeout 1 -- \
    sh -c "trap '' TERM; echo \$\$ > '$SANDBOX/leader'; sleep 30 3>&- & echo \$! > '$SANDBOX/gc'; wait"
  end="$(now)"
  [ "$status" -eq 124 ] || { echo "status=$status $output"; false; }
  pid_gone "$(cat "$SANDBOX/leader")" 1
  pid_gone "$(cat "$SANDBOX/gc")" 1
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 6 ? 0 : 1)' "$start" "$end"
}

@test "H3: KILL waits out the grace period, and a TERM-surviving member runs through it" {
  local end
  # One member that survives TERM (it handles it) and ticks every 0.1 s.
  TRELLIS_HEAVY_KILL_AFTER=1.5 run "${HEAVY[@]}" --timeout 1 -- perl -MTime::HiRes=time,sleep -e '
    open(my $log, ">>", $ARGV[0]) or die; select((select($log), $| = 1)[0]);
    $SIG{TERM} = sub { printf {$log} "term %.3f\n", time };
    while (1) { printf {$log} "tick %.3f\n", time; sleep 0.1 }
  ' "$SANDBOX/member.log"
  end="$(now)"
  [ "$status" -eq 124 ] || { echo "status=$status $output"; false; }
  local term last
  term="$(awk '$1 == "term" { print $2; exit }' "$SANDBOX/member.log")"
  last="$(awk '$1 == "tick" { t = $2 } END { print t }' "$SANDBOX/member.log")"
  [ -n "$term" ] && [ -n "$last" ] || { cat "$SANDBOX/member.log"; false; }
  # Still alive most of the way through the 1.5 s grace period...
  perl -e 'exit(($ARGV[1] - $ARGV[0]) >= 1.0 ? 0 : 1)' "$term" "$last" || { echo "last tick $last, TERM $term"; false; }
  # ...and KILLed no sooner than the grace period, and not much later.
  perl -e 'my $d = $ARGV[1] - $ARGV[0]; exit(($d >= 1.4 && $d < 4) ? 0 : 1)' "$term" "$end" || { echo "TERM $term, end $end"; false; }
}

@test "H3: SIGINT while waiting exits 130 and never launches" {
  write_config 1
  hold_slot 1 5
  TRELLIS_HEAVY_TEST_TRACE="$SANDBOX/trace" heavy_bg waiter -- touch "$SANDBOX/launched"
  sleep 0.4
  local start end rc=0
  start="$(now)"
  kill -INT "$BG_PID"
  wait "$BG_PID" || rc=$?
  end="$(now)"
  [ "$rc" -eq 130 ] || { echo "rc=$rc"; cat "$SANDBOX/waiter.out"; false; }
  # It stopped waiting at once, not when the 5 s holder let go.
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 2 ? 0 : 1)' "$start" "$end"
  [ ! -e "$SANDBOX/launched" ]
  ! grep -qx fork "$SANDBOX/trace" 2>/dev/null
}

@test "H3: a signal between acquire and fork exits 143 without launching" {
  TRELLIS_HEAVY_TEST_PAUSE=after-acquire TRELLIS_HEAVY_TEST_TRACE="$SANDBOX/trace" heavy_bg paused -- touch "$SANDBOX/launched"
  wait_for_grep 'test pause after-acquire' "$SANDBOX/paused.out"
  kill -TERM "$BG_PID"
  local rc=0
  wait "$BG_PID" || rc=$?
  [ "$rc" -eq 143 ] || { echo "rc=$rc"; cat "$SANDBOX/paused.out"; false; }
  [ ! -e "$SANDBOX/launched" ]
  # Cancelled before fork, not merely killed before the command could run.
  ! grep -qx fork "$SANDBOX/trace" 2>/dev/null || { cat "$SANDBOX/trace"; false; }
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: free"* ]] || { echo "$output"; false; }
}

@test "H3: a signal between fork and group isolation still exits 130, without exec" {
  TRELLIS_HEAVY_TEST_PAUSE=after-fork TRELLIS_HEAVY_TEST_TRACE="$SANDBOX/trace" heavy_bg forked -- touch "$SANDBOX/launched"
  wait_for_grep 'test pause after-fork' "$SANDBOX/forked.out"
  local child
  child="$(sed -n 's/.*after-fork child=\([0-9]*\).*/\1/p' "$SANDBOX/forked.out")"
  # What a terminal ^C does while the child still shares the supervisor's group.
  kill -INT "$child" "$BG_PID"
  local rc=0
  wait "$BG_PID" || rc=$?
  [ "$rc" -eq 130 ] || { echo "rc=$rc"; cat "$SANDBOX/forked.out"; false; }
  [ ! -e "$SANDBOX/launched" ]
  grep -qx fork "$SANDBOX/trace"
  ! grep -qx exec "$SANDBOX/trace" || { cat "$SANDBOX/trace"; false; }
}

@test "H3: a failed or incomplete ps never reads as an empty group" {
  mkdir -p "$SANDBOX/stub-bin"
  cat > "$SANDBOX/stub-bin/ps" <<EOF
#!/bin/sh
case "\$(cat '$SANDBOX/ps-mode')" in
  fail) exit 1 ;;
  empty) exit 0 ;;
esac
exec /bin/ps "\$@"
EOF
  chmod 755 "$SANDBOX/stub-bin/ps"
  echo fail > "$SANDBOX/ps-mode"
  PATH="$SANDBOX/stub-bin:$PATH" heavy_bg probe -- sh -c 'exit 7'
  sleep 1
  kill -0 "$BG_PID"
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: held"* ]] || { echo "$output"; false; }
  echo empty > "$SANDBOX/ps-mode"
  sleep 1
  kill -0 "$BG_PID"
  echo ok > "$SANDBOX/ps-mode"
  local rc=0
  wait "$BG_PID" || rc=$?
  [ "$rc" -eq 7 ] || { echo "rc=$rc"; cat "$SANDBOX/probe.out"; false; }
  [ "$(grep -c 'cannot read the workload' "$SANDBOX/probe.out")" -eq 1 ] || { cat "$SANDBOX/probe.out"; false; }
}

@test "H3: --timeout 1 on sleep 5 exits 124" {
  local start end
  start="$(now)"
  run "${HEAVY[@]}" --timeout 1 -- sleep 5
  end="$(now)"
  [ "$status" -eq 124 ] || { echo "status=$status $output"; false; }
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 4 ? 0 : 1)' "$start" "$end"
}

@test "H3: the leader stays an unreaped zombie until the group is empty" {
  TRELLIS_HEAVY_TEST_TRACE="$SANDBOX/trace" heavy_bg zombie -- \
    sh -c "(sleep 1.2; touch '$SANDBOX/gc-done') 3>&- & echo \$\$ > '$SANDBOX/leader'; exit 0"
  wait_for_file "$SANDBOX/leader"
  wait_for_file "$SANDBOX/trace"
  [ ! -e "$SANDBOX/gc-done" ]
  [[ "$(ps -o stat= -p "$(cat "$SANDBOX/leader")")" == *Z* ]]
  wait "$BG_PID"
  [ -e "$SANDBOX/gc-done" ]
  [ "$(cat "$SANDBOX/trace")" = "$(printf '%s\n' fork exec leader-zombie group-empty reap)" ] || { cat "$SANDBOX/trace"; false; }
}

@test "H3: no group signal is sent after the leader is reaped" {
  TRELLIS_HEAVY_KILL_AFTER=1 TRELLIS_HEAVY_TEST_TRACE="$SANDBOX/trace" run "${HEAVY[@]}" --timeout 1 -- \
    sh -c "(trap '' TERM; exec sleep 30) 3>&- & exit 0"
  [ "$status" -eq 124 ] || { echo "status=$status $output"; false; }
  [ "$(cat "$SANDBOX/trace")" = "$(printf '%s\n' fork exec leader-zombie 'signal TERM group' 'signal KILL group' group-empty reap)" ] ||
    { cat "$SANDBOX/trace"; false; }
  [ "$(tail -n 1 "$SANDBOX/trace")" = reap ]
}

@test "H3: exit codes 0, 1 and 3 pass through" {
  local code
  for code in 0 1 3; do
    run "${HEAVY[@]}" -- sh -c "exit $code"
    [ "$status" -eq "$code" ] || { echo "want $code got $status: $output"; false; }
  done
}

# ---------------------------------------------------------------- H4

@test "H4: the info file has four tab-delimited fields and argv round-trips" {
  cat > "$SANDBOX/copy-info.sh" <<'EOF'
#!/bin/bash
cp "$TRELLIS_HEAVY_DIR/slot-$TRELLIS_HEAVY_SLOT.info" "$1"
EOF
  chmod 755 "$SANDBOX/copy-info.sh"
  run "${HEAVY[@]}" --lane lane-h4 -- "$SANDBOX/copy-info.sh" "$SANDBOX/info" "arg with spaces" "it's" $'tab\there' ''
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$SANDBOX/info")" -eq 1 ]
  [ "$(awk -F'\t' '{ print NF }' "$SANDBOX/info")" -eq 4 ]
  local pid lane started argv
  IFS=$'\t' read -r pid lane started argv < "$SANDBOX/info"
  [[ "$pid" =~ ^[0-9]+$ ]]
  [ "$lane" = lane-h4 ]
  [[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  eval "set -- $argv"
  [ "$#" -eq 6 ]
  [ "$1" = "$SANDBOX/copy-info.sh" ]
  [ "$3" = "arg with spaces" ]
  [ "$4" = "it's" ]
  [ "$5" = $'tab\there' ]
  [ -z "$6" ]
}

@test "H4: the heartbeat lists only held slots, and unknown without an info file" {
  write_config 2
  heavy_bg holder --lane hb-lane -- sh -c "touch '$SANDBOX/holder-ready'; sleep 3"
  local holder=$BG_PID
  wait_for_file "$SANDBOX/holder-ready"
  hold_slot 2 3
  # A free, retired slot with a stale info file must not be listed.
  : > "$TRELLIS_HEAVY_DIR/slot-3.lock"
  printf '1\tstale\t2026-01-01T00:00:00Z\ttrue\n' > "$TRELLIS_HEAVY_DIR/slot-3.info"
  TRELLIS_HEAVY_TEST_HEARTBEAT=0.3 heavy_bg waiter -- true
  wait_for_grep 'held:' "$SANDBOX/waiter.out"
  local line
  line="$(grep -m1 'held:' "$SANDBOX/waiter.out")"
  [[ "$line" == *"held: 1=hb-lane/$holder 2=unknown" ]] || { echo "$line"; false; }
  [[ "$line" != *"3="* ]]
}

# ---------------------------------------------------------------- H5

@test "H5: heavy_slots absent means 2; 1 and 2 validate; 0, -1 and x exit 78" {
  write_config ""
  run "${HEAVY[@]}" --check
  [ "$status" -eq 0 ] && [[ "$output" == *"heavy_slots=2"* ]] || { echo "$output"; false; }
  hold_slot 1 3
  run "${HEAVY[@]}" -- sh -c 'echo "$TRELLIS_HEAVY_SLOT"'
  [ "$status" -eq 0 ] && [ "$output" = 2 ] || { echo "$output"; false; }

  local value
  for value in 1 2; do
    write_config "$value"
    run "${HEAVY[@]}" --check
    [ "$status" -eq 0 ] && [[ "$output" == *"heavy_slots=$value"* ]] || { echo "$value: $output"; false; }
  done
  for value in 0 -1 '"x"'; do
    write_config "$value"
    run "${HEAVY[@]}" --check
    [ "$status" -eq 78 ] || { echo "$value: status=$status $output"; false; }
    [ "${#lines[@]}" -eq 1 ] || { echo "$value: $output"; false; }
    [[ "$output" == *heavy_slots* ]] || { echo "$value: $output"; false; }
  done
}

@test "H5/HA2: the three closed-object validators accept heavy_slots and heavy_light_slots, even bad values" {
  mkdir -p "$SANDBOX/source" "$SANDBOX/projects"
  local value
  for value in 2 0 '"x"'; do
    write_config "$value" "$value"
    run bash -c '. "$1/scripts/lib/trellis-home.sh"; trellis_home_validate_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/config.json"
    [ "$status" -eq 0 ] || { echo "trellis-home $value: $output"; false; }
    run bash -c 'eval "$(awk "/^launcher_validate_machine_config\\(\\) \\{/,/^\\}/" "$1/scripts/trellis-launcher.sh")"
      launcher_validate_machine_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/config.json"
    [ "$status" -eq 0 ] || { echo "launcher $value: $output"; false; }
    run bash -c 'for l in semver trellis-home local-registry attachment health-checks; do . "$1/scripts/lib/$l.sh"; done
      hc_portable_machine_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME"
    [ "$status" -eq 0 ] || { echo "health-checks $value: $output"; false; }
  done
  # The key set is still closed.
  jq '. + {not_a_key: 1}' "$TRELLIS_HOME/config.json" > "$SANDBOX/c" && cat "$SANDBOX/c" > "$TRELLIS_HOME/config.json"
  run bash -c '. "$1/scripts/lib/trellis-home.sh"; trellis_home_validate_config "$2"' _ "$REPO_ROOT" "$TRELLIS_HOME/config.json"
  [ "$status" -ne 0 ]
}

@test "H5: reducing N never evicts, never hands out a retired slot, and --status shows both" {
  write_config 2
  hold_slot 2 30
  local slot2_holder=$HOLD_PID
  write_config 1
  heavy_bg first -- sh -c "echo \"\$TRELLIS_HEAVY_SLOT\" > '$SANDBOX/first-slot'; sleep 1.5"
  local first=$BG_PID
  wait_for_file "$SANDBOX/first-slot"
  [ "$(cat "$SANDBOX/first-slot")" = 1 ]
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: held lane="* ]] || { echo "$output"; false; }
  [[ "$output" == *"slot 2: held (retired) unknown"* ]] || { echo "$output"; false; }
  # Slot 2 frees while slot 1 is busy: a new run still waits for slot 1.
  kill -KILL "$slot2_holder"
  pid_gone "$slot2_holder"
  heavy_bg second -- sh -c "echo \"\$TRELLIS_HEAVY_SLOT\" > '$SANDBOX/second-slot'"
  local second=$BG_PID
  sleep 0.5
  [ ! -e "$SANDBOX/second-slot" ]
  wait "$first"
  wait "$second"
  [ "$(cat "$SANDBOX/second-slot")" = 1 ]
}

# ---------------------------------------------------------------- H6

# A sealed fixture release carrying the real dispatcher and heavy files, run
# through a copy of the stable launcher, whose env -i allowlist is the thing
# under test.
make_heavy_release() {
  local version=1.2.3 manifest="$SANDBOX/manifest.jsonl"
  RELEASE_DIR="$TRELLIS_HOME/releases/$version"
  PAYLOAD="$RELEASE_DIR/payload"
  mkdir -p "$PAYLOAD/scripts/lib" "$SANDBOX/source" "$SANDBOX/projects" "$SANDBOX/launcher"
  cp "$REPO_ROOT/scripts/trellis" "$REPO_ROOT/scripts/heavy.sh" "$PAYLOAD/scripts/"
  cp "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" "$PAYLOAD/scripts/lib/"
  chmod 755 "$PAYLOAD/scripts/trellis" "$PAYLOAD/scripts/heavy.sh"
  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$PAYLOAD" > "$manifest"
  jq -n --arg version "$version" --slurpfile tree "$manifest" '
    {schema_version: 1, version: $version, tag: ("v" + $version),
     commit: "0000000000000000000000000000000000000000", remote: "fixture://release", tree: $tree}
  ' > "$RELEASE_DIR/release.json"
  find "$PAYLOAD" -type f -exec chmod a-w {} +
  find "$PAYLOAD" -type d -exec chmod a-w {} +
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"
  LAUNCHER="$SANDBOX/launcher/trellis"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$LAUNCHER"
  chmod 755 "$LAUNCHER"
}

@test "H6: the caller's variables, PATH entry and DOCKER_HOST reach the child through the launcher" {
  make_heavy_release
  mkdir -p "$SANDBOX/caller-bin"
  cat > "$SANDBOX/caller-bin/caller-only-tool" <<'EOF'
#!/bin/sh
printf 'custom=%s\ndocker=%s\npayload=%s\nslot=%s\n' "${HEAVY_CALLER_ONLY-unset}" "${DOCKER_HOST-unset}" \
  "${TRELLIS_VERIFIED_PAYLOAD-unset}" "${TRELLIS_HEAVY_SLOT-unset}"
EOF
  chmod 755 "$SANDBOX/caller-bin/caller-only-tool"
  run env PATH="$SANDBOX/caller-bin:$PATH" HEAVY_CALLER_ONLY='kept value' DOCKER_HOST=unix:///tmp/heavy-docker.sock \
    "$LAUNCHER" heavy --lane h6 -- caller-only-tool
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"custom=kept value"* ]] || { echo "$output"; false; }
  [[ "$output" == *"docker=unix:///tmp/heavy-docker.sock"* ]] || { echo "$output"; false; }
  [[ "$output" == *"payload=unset"* ]] || { echo "$output"; false; }
  [[ "$output" == *"slot=1"* ]] || { echo "$output"; false; }
}

@test "H6: the launcher forwards TERM to a heavy run instead of waiting it out" {
  make_heavy_release
  "$LAUNCHER" heavy -- sh -c "echo \$\$ > '$SANDBOX/leader'; exec sleep 30" > "$SANDBOX/launcher.out" 2>&1 3>&- &
  local launcher=$!
  PIDS+=("$launcher")
  wait_for_file "$SANDBOX/leader"
  local start end rc=0
  start="$(now)"
  kill -TERM "$launcher"
  wait "$launcher" || rc=$?
  end="$(now)"
  [ "$rc" -eq 143 ] || { echo "rc=$rc"; cat "$SANDBOX/launcher.out"; false; }
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 5 ? 0 : 1)' "$start" "$end"
  pid_gone "$(cat "$SANDBOX/leader")" 1
}

@test "H6: a signal before the launcher's child resets INT is queued and forwarded as itself (INT 130, HUP 129)" {
  make_heavy_release
  local sig want rc
  for sig in INT HUP; do
    case "$sig" in INT) want=130 ;; HUP) want=129 ;; esac
    : > "$SANDBOX/launcher-$sig.out"
    # perl restores INT's default disposition: bats starts background jobs with
    # INT ignored, and a shell cannot trap a signal ignored on entry.
    TRELLIS_HEAVY_TEST_PAUSE=launcher-startup perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV' \
      "$LAUNCHER" heavy -- sleep 5 > "$SANDBOX/launcher-$sig.out" 2>&1 3>&- &
    local launcher=$!
    PIDS+=("$launcher")
    wait_for_grep 'test pause launcher-startup' "$SANDBOX/launcher-$sig.out"
    kill -s "$sig" "$launcher"
    rc=0
    wait "$launcher" || rc=$?
    [ "$rc" -eq "$want" ] || { echo "$sig: rc=$rc want=$want"; cat "$SANDBOX/launcher-$sig.out"; false; }
  done
}

@test "H6: a launcher that predates heavy is refused rather than stripping the caller env" {
  run env TRELLIS_VERIFIED_PAYLOAD="$SANDBOX/payload" "${HEAVY[@]}" --check
  [ "$status" -eq 78 ] || { echo "$output"; false; }
  [[ "$output" == *"predates trellis heavy"* ]] || { echo "$output"; false; }
}

# ---------------------------------------------------------------- H7

@test "H7: a nested call with N=1 times out with 124, no deadlock, no new group" {
  write_config 1
  local start end
  cat > "$SANDBOX/inner.sh" <<EOF
#!/bin/sh
ps -o pgid= -p \$\$ | tr -d ' ' > '$SANDBOX/inner-pgid'
exec sleep 5
EOF
  chmod 755 "$SANDBOX/inner.sh"
  start="$(now)"
  run "${HEAVY[@]}" -- sh -c "ps -o pgid= -p \$\$ | tr -d ' ' > '$SANDBOX/outer-pgid'; trellis heavy --timeout 1 -- '$SANDBOX/inner.sh'"
  end="$(now)"
  [ "$status" -eq 124 ] || { echo "status=$status $output"; false; }
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 4 ? 0 : 1)' "$start" "$end"
  [ -s "$SANDBOX/inner-pgid" ]
  [ "$(cat "$SANDBOX/inner-pgid")" = "$(cat "$SANDBOX/outer-pgid")" ]
}

@test "H7: an outer timeout around a nested TERM-ignoring leaf removes every pid and frees the slot" {
  write_config 1
  TRELLIS_HEAVY_KILL_AFTER=1 run "${HEAVY[@]}" --timeout 1 -- \
    trellis heavy -- sh -c "trap '' TERM; echo \$PPID > '$SANDBOX/inner'; echo \$\$ > '$SANDBOX/leaf'; sleep 30"
  [ "$status" -eq 124 ] || { echo "status=$status $output"; false; }
  pid_gone "$(cat "$SANDBOX/inner")" 1
  pid_gone "$(cat "$SANDBOX/leaf")" 1
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 1: free"* ]] || { echo "$output"; false; }
}

# The child reports whether it runs in a group of its own (an acquired call)
# or in its caller's group (a verified nested call).
report_group() {
  printf '%s\n' "sp=\$(ps -o pgid= -p \$\$ | tr -d ' '); if [ \"\$sp\" = \$\$ ]; then echo own-group; else echo caller-group; fi"
}

# spoof_suite POOL PREFIX [--light]  — the H7 spoofs against one pool's files.
spoof_suite() {
  local pool="$1" prefix="$2" id probe
  shift 2
  probe="$(report_group)"
  [ -d "$TRELLIS_HEAVY_DIR" ] || mkdir -m 700 "$TRELLIS_HEAVY_DIR"
  : > "$TRELLIS_HEAVY_DIR/$prefix-1.lock"
  id="$(perl -e '@s = stat($ARGV[0]); print "$s[0]:$s[1]"' "$TRELLIS_HEAVY_DIR")"

  # Positive control: a genuine nested call runs in the caller's group.
  run "${HEAVY[@]}" "$@" -- trellis heavy "$@" -- sh -c "$probe"
  [ "$output" = caller-group ] || { echo "$pool control: $output"; false; }

  # No descriptor.
  run env TRELLIS_HEAVY_POOL="$pool" TRELLIS_HEAVY_SLOT=1 TRELLIS_HEAVY_DIR_ID="$id" "${HEAVY[@]}" "$@" -- sh -c "$probe"
  [ "$output" = own-group ] || { echo "$pool no fd: $output"; false; }
  # A descriptor on another file.
  : > "$SANDBOX/other-file"
  run bash -c 'exec 77<>"$1"; shift; exec env TRELLIS_HEAVY_FD=77 TRELLIS_HEAVY_SLOT=1 "$@"' _ \
    "$SANDBOX/other-file" TRELLIS_HEAVY_POOL="$pool" TRELLIS_HEAVY_DIR_ID="$id" "${HEAVY[@]}" "$@" -- sh -c "$probe"
  [ "$output" = own-group ] || { echo "$pool other file: $output"; false; }
  # The right slot file, the wrong directory identity.
  run bash -c 'exec 77<>"$1"; shift; exec env TRELLIS_HEAVY_FD=77 TRELLIS_HEAVY_SLOT=1 "$@"' _ \
    "$TRELLIS_HEAVY_DIR/$prefix-1.lock" TRELLIS_HEAVY_POOL="$pool" TRELLIS_HEAVY_DIR_ID=1:1 "${HEAVY[@]}" "$@" -- sh -c "$probe"
  [ "$output" = own-group ] || { echo "$pool wrong id: $output"; false; }
  # A closed descriptor.
  run env TRELLIS_HEAVY_POOL="$pool" TRELLIS_HEAVY_FD=77 TRELLIS_HEAVY_SLOT=1 TRELLIS_HEAVY_DIR_ID="$id" "${HEAVY[@]}" "$@" -- sh -c "$probe"
  [ "$output" = own-group ] || { echo "$pool closed fd: $output"; false; }
}

@test "H7: spoofed nesting markers fail verification and acquire normally" {
  write_config 1
  spoof_suite heavy slot
}

@test "H7: a marker on an unlocked retired slot is rejected and never takes that slot" {
  write_config 1
  local id probe
  probe="$(report_marker)"
  mkdir -m 700 "$TRELLIS_HEAVY_DIR"
  : > "$TRELLIS_HEAVY_DIR/slot-2.lock"
  id="$(perl -e '@s = stat($ARGV[0]); print "$s[0]:$s[1]"' "$TRELLIS_HEAVY_DIR")"
  run bash -c 'exec 77<>"$1"; shift; exec "$@"' _ "$TRELLIS_HEAVY_DIR/slot-2.lock" \
    env TRELLIS_HEAVY_FD=77 TRELLIS_HEAVY_SLOT=2 TRELLIS_HEAVY_POOL=heavy TRELLIS_HEAVY_DIR_ID="$id" \
    "${HEAVY[@]}" -- sh -c "$probe"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' own-group 'pool=heavy slot=1')" ] || { echo "$output"; false; }
  run "${HEAVY[@]}" --status
  [[ "$output" == *"slot 2: free (retired)"* ]] || { echo "$output"; false; }
}

@test "H7: a separately opened descriptor on a held slot is rejected by flock" {
  write_config 2
  local probe
  probe="$(report_marker)"
  hold_token_slot 1 0123456789abcdef0123456789abcdef
  # Same inode, directory, pool and even the holder's token, but its own
  # description: only the flock on the inherited description can refuse it.
  run bash -c 'exec 77<>"$1"; shift; exec "$@"' _ "$TRELLIS_HEAVY_DIR/slot-1.lock" \
    env TRELLIS_HEAVY_FD=77 TRELLIS_HEAVY_SLOT=1 TRELLIS_HEAVY_POOL=heavy TRELLIS_HEAVY_DIR_ID="$(slot_dir_id)" \
    TRELLIS_HEAVY_TOKEN=0123456789abcdef0123456789abcdef "${HEAVY[@]}" -- sh -c "$probe"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' own-group 'pool=heavy slot=2')" ] || { echo "$output"; false; }
}

@test "H7: a holder that releases mid-verification never lends its slot to another description" {
  write_config 1
  local probe
  printf '#!/bin/sh\n%s\n' "$(report_marker)" > "$SANDBOX/probe.sh"
  chmod 755 "$SANDBOX/probe.sh"
  hold_token_slot 1 0123456789abcdef0123456789abcdef
  local holder=$HOLD_PID
  # A separate description with the right token. Verification reads the token,
  # pauses, and in that pause the holder removes its token and releases, so
  # the flock that follows would newly take the slot.
  TRELLIS_HEAVY_TEST_PAUSE=verify-before-flock \
    bash -c 'exec 77<>"$1"; shift; exec "$@"' _ "$TRELLIS_HEAVY_DIR/slot-1.lock" \
    env TRELLIS_HEAVY_FD=77 TRELLIS_HEAVY_SLOT=1 TRELLIS_HEAVY_POOL=heavy TRELLIS_HEAVY_DIR_ID="$(slot_dir_id)" \
    TRELLIS_HEAVY_TOKEN=0123456789abcdef0123456789abcdef "${HEAVY[@]}" -- "$SANDBOX/probe.sh" > "$SANDBOX/race.out" 2>&1 3>&- &
  local racer=$!
  PIDS+=("$racer")
  wait_for_grep 'test pause verify-before-flock' "$SANDBOX/race.out"
  kill -TERM "$holder"
  pid_gone "$holder"
  # Rejected, and the lock it briefly took is given back, so a normal
  # acquisition of the only slot succeeds instead of waiting on itself.
  pid_gone "$racer" 160 || { echo "racer still waiting"; cat "$SANDBOX/race.out"; false; }
  wait "$racer"
  [ "$(grep -v 'test pause' "$SANDBOX/race.out")" = "$(printf '%s\n' own-group 'pool=heavy slot=1')" ] ||
    { cat "$SANDBOX/race.out"; false; }
}

# held_mismatch POOL PREFIX [--light]  — inside a genuine holder of slot 1, a
# nested call whose marker names slot 2 (held elsewhere, so the flock proof
# passes) or the wrong directory identity must be rejected, and then acquires
# slot 2 once its holder lets go.
held_mismatch() {
  local pool="$1" prefix="$2" flag="${3:-}"
  printf '#!/bin/sh\n%s\n' "$(report_marker)" > "$SANDBOX/probe.sh"
  chmod 755 "$SANDBOX/probe.sh"
  hold_slot 2 1.5 "$prefix"
  # Copy the outer token to slot 2, so only the inode check can tell the
  # descriptor (slot 1) from the slot the marker names.
  run "${HEAVY[@]}" ${flag:+"$flag"} -- sh -c '
    cp "$TRELLIS_HEAVY_DIR/$1-1.token" "$TRELLIS_HEAVY_DIR/$1-2.token" || exit 9
    TRELLIS_HEAVY_SLOT=2 exec trellis heavy ${2:+"$2"} -- "$3"' _ "$prefix" "$flag" "$SANDBOX/probe.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' own-group "pool=$pool slot=2")" ] || { echo "$pool other slot: $output"; false; }
  run "${HEAVY[@]}" ${flag:+"$flag"} -- env TRELLIS_HEAVY_DIR_ID=1:1 trellis heavy ${flag:+"$flag"} -- "$SANDBOX/probe.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' own-group "pool=$pool slot=2")" ] || { echo "$pool wrong dir id: $output"; false; }
}
@test "H7: a genuinely held descriptor under a mismatched slot or directory marker is rejected" {
  write_config 2 2
  held_mismatch heavy slot
}

@test "HA4: a genuinely held light descriptor under a mismatched marker is rejected" {
  write_config 2 2
  held_mismatch light light --light
}

@test "H7: a rejected marker leaves the caller's descriptor open for the workload" {
  write_config 2
  hold_token_slot 1 0123456789abcdef0123456789abcdef
  # Slot 1 is held by another description; fd 78 is a second description of the
  # same inode with a marker that passes every identity and token check, so the
  # rejection comes last, at the flock, after the descriptor has been examined.
  run bash -c 'exec 78<>"$1"; shift; exec "$@"' _ "$TRELLIS_HEAVY_DIR/slot-1.lock" \
    env TRELLIS_HEAVY_FD=78 TRELLIS_HEAVY_SLOT=1 TRELLIS_HEAVY_POOL=heavy TRELLIS_HEAVY_DIR_ID="$(slot_dir_id)" \
    TRELLIS_HEAVY_TOKEN=0123456789abcdef0123456789abcdef "${HEAVY[@]}" -- sh -c '
      echo "slot=$TRELLIS_HEAVY_SLOT"
      if [ -e /dev/fd/78 ]; then echo fd-kept; else echo fd-closed; fi'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' slot=2 fd-kept)" ] || { echo "$output"; false; }
}
@test "H7: two concurrent outer jobs with nested calls still run one after the other" {
  write_config 1
  write_job
  heavy_bg a -- trellis heavy -- "$SANDBOX/job.sh" a 0.5
  local a=$BG_PID
  heavy_bg b -- trellis heavy -- "$SANDBOX/job.sh" b 0.5
  wait "$a"
  wait "$BG_PID"
  [ "$(grep -c ' end ' "$SANDBOX/events")" -eq 2 ] || { cat "$SANDBOX/events"; false; }
  [ "$(max_overlap)" -eq 1 ] || { cat "$SANDBOX/events"; false; }
}

# ---------------------------------------------------------------- H9

@test "H9: TRELLIS_HEAVY_DIR is ignored without TRELLIS_HEAVY_TEST=1" {
  local ignored="$SANDBOX/ignored" expected
  run env -u TRELLIS_HEAVY_TEST TRELLIS_HEAVY_DIR="$ignored" "${HEAVY[@]}" -- sh -c 'echo "$TRELLIS_HEAVY_DIR_ID"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/locks/heavy/slot-1.lock" ]
  [ ! -e "$ignored" ]
  expected="$(perl -e '@s = stat($ARGV[0]); print "$s[0]:$s[1]"' "$TRELLIS_HOME/locks/heavy")"
  [ "$output" = "$expected" ] || { echo "$output != $expected"; false; }
  [ "$(stat -f %Lp "$TRELLIS_HOME/locks/heavy" 2>/dev/null || stat -c %a "$TRELLIS_HOME/locks/heavy")" = 700 ]
  [ "$(stat -f %Lp "$TRELLIS_HOME/locks/heavy/slot-1.lock" 2>/dev/null || stat -c %a "$TRELLIS_HOME/locks/heavy/slot-1.lock")" = 600 ]
}

# ---------------------------------------------------------------- usage

@test "usage errors exit 2 and name the problem" {
  run "${HEAVY[@]}" sleep 1
  [ "$status" -eq 2 ] && [[ "$output" == *"put the command after --"* ]] || { echo "$output"; false; }
  run "${HEAVY[@]}" --
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run "${HEAVY[@]}" --timeout soon -- true
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run "${HEAVY[@]}" --lane 'bad lane' -- true
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  run "${HEAVY[@]}" --check -- true
  [ "$status" -eq 2 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------- A1: HA1-HA5

@test "HA1: the pools are independent: a heavy and a light run overlap, two light runs do not" {
  write_config 1 1
  write_job
  heavy_bg h -- "$SANDBOX/job.sh" heavy 0.8
  local h=$BG_PID
  heavy_bg l --light -- "$SANDBOX/job.sh" light 0.8
  wait "$h"
  wait "$BG_PID"
  [ "$(max_overlap)" -eq 2 ] || { cat "$SANDBOX/events"; false; }

  : > "$SANDBOX/events"
  heavy_bg l1 --light -- "$SANDBOX/job.sh" l1 0.5
  local l1=$BG_PID
  heavy_bg l2 --light -- "$SANDBOX/job.sh" l2 0.5
  wait "$l1"
  wait "$BG_PID"
  [ "$(grep -c ' end ' "$SANDBOX/events")" -eq 2 ] || { cat "$SANDBOX/events"; false; }
  [ "$(max_overlap)" -eq 1 ] || { cat "$SANDBOX/events"; false; }
}

@test "HA2: heavy_light_slots absent means 4; 0, -1 and x exit 78" {
  write_config 1
  run "${HEAVY[@]}" --check
  [ "$status" -eq 0 ] && [[ "$output" == *"heavy_light_slots=4"* ]] || { echo "$output"; false; }
  hold_slot 1 3 light
  hold_slot 2 3 light
  hold_slot 3 3 light
  run "${HEAVY[@]}" --light -- sh -c 'echo "$TRELLIS_HEAVY_POOL/$TRELLIS_HEAVY_SLOT"'
  [ "$status" -eq 0 ] && [ "$output" = light/4 ] || { echo "$output"; false; }
  local value
  for value in 0 -1 '"x"'; do
    write_config 1 "$value"
    run "${HEAVY[@]}" --check
    [ "$status" -eq 78 ] || { echo "$value: status=$status $output"; false; }
    [ "${#lines[@]}" -eq 1 ] || { echo "$value: $output"; false; }
    [[ "$output" == *heavy_light_slots* ]] || { echo "$value: $output"; false; }
  done
}

@test "HA3: a long light run warns exactly once with the effective threshold and keeps its exit code" {
  TRELLIS_HEAVY_LIGHT_WARN=1 run "${HEAVY[@]}" --light -- sh -c 'sleep 2.4; exit 3'
  [ "$status" -eq 3 ] || { echo "status=$status $output"; false; }
  [ "$(grep -c 'light run exceeded' <<<"$output")" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis heavy: light run exceeded 1s; use the heavy pool for long runs"* ]] || { echo "$output"; false; }
  # The heavy pool never warns.
  TRELLIS_HEAVY_LIGHT_WARN=1 run "${HEAVY[@]}" -- sleep 1.6
  [ "$status" -eq 0 ] && [[ "$output" != *"light run exceeded"* ]] || { echo "$output"; false; }
}

# A probe that prints its group relation and the marker it inherited.
report_marker() {
  printf '%s\n' "$(report_group); echo \"pool=\${TRELLIS_HEAVY_POOL-unset} slot=\${TRELLIS_HEAVY_SLOT-unset}\""
}

@test "HA4: nested calls across pools take no slot and keep the outer marker" {
  write_config 1 1
  local probe
  probe="$(report_marker)"
  # light-in-heavy, with the only light slot held elsewhere.
  hold_slot 1 30 light
  local light_holder=$HOLD_PID
  run "${HEAVY[@]}" --timeout 5 -- trellis heavy --light -- sh -c "$probe"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$output" = "$(printf '%s\n' caller-group 'pool=heavy slot=1')" ] || { echo "light-in-heavy: $output"; false; }
  kill -KILL "$light_holder"
  pid_gone "$light_holder"
  # heavy-in-light, with the only heavy slot held elsewhere.
  hold_slot 1 30
  local heavy_holder=$HOLD_PID
  run "${HEAVY[@]}" --light --timeout 5 -- trellis heavy -- sh -c "$probe"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$output" = "$(printf '%s\n' caller-group 'pool=light slot=1')" ] || { echo "heavy-in-light: $output"; false; }
  kill -KILL "$heavy_holder"
  pid_gone "$heavy_holder"
  # light-in-light with one light slot: acquiring would deadlock.
  run "${HEAVY[@]}" --light --timeout 5 -- trellis heavy --light -- sh -c "$probe"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$output" = "$(printf '%s\n' caller-group 'pool=light slot=1')" ] || { echo "light-in-light: $output"; false; }
}

@test "HA4: a depth-2 heavy -> light -> heavy chain verifies at every level" {
  write_config 1 1
  local probe
  probe="$(report_marker)"
  # Hold the only light slot: the middle call must not try to take one.
  hold_slot 1 30 light
  run "${HEAVY[@]}" --timeout 5 -- trellis heavy --light -- trellis heavy -- sh -c "$probe"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$output" = "$(printf '%s\n' caller-group 'pool=heavy slot=1')" ] || { echo "$output"; false; }
}

@test "HA4: a missing, unknown or mismatched pool in the marker acquires normally" {
  write_config 1 1
  printf '#!/bin/sh\n%s\n' "$(report_group)" > "$SANDBOX/probe.sh"
  chmod 755 "$SANDBOX/probe.sh"
  # Each runs inside a genuine heavy holder, so only the pool field is wrong.
  run "${HEAVY[@]}" -- env -u TRELLIS_HEAVY_POOL trellis heavy --light -- "$SANDBOX/probe.sh"
  [ "$output" = own-group ] || { echo "missing: $output"; false; }
  run "${HEAVY[@]}" -- env TRELLIS_HEAVY_POOL=bogus trellis heavy --light -- "$SANDBOX/probe.sh"
  [ "$output" = own-group ] || { echo "unknown: $output"; false; }
  # A heavy descriptor presented as a light marker.
  run "${HEAVY[@]}" -- env TRELLIS_HEAVY_POOL=light trellis heavy --light -- "$SANDBOX/probe.sh"
  [ "$output" = own-group ] || { echo "wrong pool: $output"; false; }
  # Control: the same chain with the marker intact is nested.
  run "${HEAVY[@]}" -- env trellis heavy --light -- "$SANDBOX/probe.sh"
  [ "$output" = caller-group ] || { echo "control: $output"; false; }
}

@test "HA4: the H7 spoofs hold for the light pool too" {
  write_config 1 1
  spoof_suite light light --light
}

@test "HA4: a nested --light call inside a heavy holder never warns" {
  TRELLIS_HEAVY_LIGHT_WARN=1 run "${HEAVY[@]}" -- trellis heavy --light -- sleep 1.6
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [[ "$output" != *"light run exceeded"* ]] || { echo "$output"; false; }
}

@test "HA5: --status lists both pools, including slots still held after a reduction" {
  write_config 2 2
  hold_slot 2 30
  hold_slot 2 30 light
  write_config 1 1
  run "${HEAVY[@]}" --status
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"heavy_slots=1 heavy_light_slots=1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"slot 1: free"* && "$output" == *"slot 2: held (retired) unknown"* ]] || { echo "$output"; false; }
  [[ "$output" == *"light 1: free"* && "$output" == *"light 2: held (retired) unknown"* ]] || { echo "$output"; false; }
  run "${HEAVY[@]}" --status --light
  [ "$status" -eq 2 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------- A2

# No token, token temp file or info file may remain in the slot directory.
assert_no_holder_files() {
  local left
  left="$(find "$TRELLIS_HEAVY_DIR" -name '*.token*' -o -name '*.info*' 2>&1)"
  [ -z "$left" ] || { echo "left behind ($1): $left"; false; }
}

@test "A2-8: no token or info file survives a normal exit, a timeout, INT or TERM" {
  run "${HEAVY[@]}" -- sh -c 'exit 3'
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  assert_no_holder_files normal
  run "${HEAVY[@]}" --timeout 1 -- sleep 5
  [ "$status" -eq 124 ] || { echo "$output"; false; }
  assert_no_holder_files timeout
  local sig want rc
  for sig in INT TERM; do
    case "$sig" in INT) want=130 ;; TERM) want=143 ;; esac
    rm -f "$SANDBOX/ready"
    heavy_bg "sig-$sig" -- sh -c "touch '$SANDBOX/ready'; exec sleep 5"
    wait_for_file "$SANDBOX/ready"
    [ -f "$TRELLIS_HEAVY_DIR/slot-1.token" ]
    kill -s "$sig" "$BG_PID"
    rc=0
    wait "$BG_PID" || rc=$?
    [ "$rc" -eq "$want" ] || { echo "$sig rc=$rc"; false; }
    assert_no_holder_files "$sig"
  done
}

@test "A2-9: a token that cannot be written fails with 5 before launch and leaves nothing" {
  TRELLIS_HEAVY_TEST_FAIL=token-write run "${HEAVY[@]}" -- touch "$SANDBOX/launched"
  [ "$status" -eq 5 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"could not write the slot token"* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/launched" ]
  assert_no_holder_files token-write
}

@test "A2-10: a token that cannot be published fails with 5 and removes its temp file" {
  mkdir -m 700 "$TRELLIS_HEAVY_DIR"
  # A directory where the token belongs makes the rename fail for real.
  mkdir "$TRELLIS_HEAVY_DIR/slot-1.token"
  run "${HEAVY[@]}" -- touch "$SANDBOX/launched"
  [ "$status" -eq 5 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"could not publish the slot token"* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/launched" ]
  [ -z "$(find "$TRELLIS_HEAVY_DIR" -name '*.tmp.*')" ] || { ls -la "$TRELLIS_HEAVY_DIR"; false; }
}

@test "A2-11: a failure after the token is published removes it while the slot is still held" {
  TRELLIS_HEAVY_TEST_FAIL=after-publish run "${HEAVY[@]}" -- touch "$SANDBOX/launched"
  [ "$status" -eq 5 ] || { echo "status=$status $output"; false; }
  [ ! -e "$SANDBOX/launched" ]
  assert_no_holder_files after-publish
}

@test "A2-12: a symlinked or non-600 token file is no token" {
  write_config 2
  printf '#!/bin/sh\n%s\n' "$(report_marker)" > "$SANDBOX/probe.sh"
  chmod 755 "$SANDBOX/probe.sh"
  # The genuine holder's own token, same content, reached through a symlink.
  run "${HEAVY[@]}" -- sh -c '
    t="$TRELLIS_HEAVY_DIR/slot-1.token"
    cp -p "$t" "$t.real" && rm "$t" && ln -s "$t.real" "$t" || exit 9
    exec trellis heavy -- "$1"' _ "$SANDBOX/probe.sh"
  [ "$output" = "$(printf '%s\n' own-group 'pool=heavy slot=2')" ] || { echo "symlink: $output"; false; }
  run "${HEAVY[@]}" -- sh -c '
    chmod 644 "$TRELLIS_HEAVY_DIR/slot-1.token" || exit 9
    exec trellis heavy -- "$1"' _ "$SANDBOX/probe.sh"
  [ "$output" = "$(printf '%s\n' own-group 'pool=heavy slot=2')" ] || { echo "mode 644: $output"; false; }
  # Control: untouched, the same chain is nested.
  run "${HEAVY[@]}" -- trellis heavy -- "$SANDBOX/probe.sh"
  [ "$output" = "$(printf '%s\n' caller-group 'pool=heavy slot=1')" ] || { echo "control: $output"; false; }
}

@test "A2-13: a child that cannot acknowledge readiness ends the launcher run with 5, never launching" {
  make_heavy_release
  local start end
  start="$(now)"
  TRELLIS_HEAVY_TEST_FAIL=launcher-ready run "$LAUNCHER" heavy -- touch "$SANDBOX/launched"
  end="$(now)"
  [ "$status" -eq 5 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"could not acknowledge heavy child readiness"* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/launched" ]
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 5 ? 0 : 1)' "$start" "$end"
}
