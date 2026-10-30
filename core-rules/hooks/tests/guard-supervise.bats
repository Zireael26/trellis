#!/usr/bin/env bats
# Bright-line PreToolUse guards are stall-safe and fail closed.
#
# Claude Code cancels a PreToolUse command hook that reaches its registered
# timeout and lets the tool call continue; it also treats an exit other than 2
# without a decision as a non-blocking error. Every template therefore starts
# each bright-line guard through a POSIX sh entry and
# core-rules/hooks/lib/guard-supervise.pl, and every abnormal result must reach
# the client as that harness's deny.
#
# The shipped deadline has no environment or argument override. setup() copies
# the runtime and lowers the constant in the COPY only (20 -> 3; the supervisor
# rounds its start down to a whole second, so the copy's budget is 2-3 s).
# Stalls are bounded (6 s) so a baseline without supervision still finishes,
# and contract tests first check the supervisor exists so its absence fails
# distinctly from a safety assertion.

load helpers

REPO="$(cd "$HOOKS_DIR/../.." && pwd)"
CLIENT_TIMEOUT=30
SUP=core-rules/hooks/lib/guard-supervise.pl
CLAUDE_TEMPLATE=core-rules/templates/claude-settings.local.json
CODEX_TEMPLATE=core-rules/templates/codex-hooks.local.json
TIMED_OUT='guard timed out after 3s; refusing'
SANITIZE='env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u ENV -u BASH_ENV perl "$@"'

setup() {
  RT="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$RT/core-rules/codex" "$RT/core-rules/pi"
  cp -R "$HOOKS_DIR" "$RT/core-rules/hooks"
  cp -R "$CODEX_HOOKS_DIR" "$RT/core-rules/codex/hooks"
  cp -R "$REPO/core-rules/pi/hooks" "$RT/core-rules/pi/hooks"
  if [ -f "$RT/$SUP" ]; then
    sed 's/^my \$DEADLINE_SECS = 20;$/my $DEADLINE_SECS = 3;/' "$RT/$SUP" > "$RT/$SUP.next"
    mv "$RT/$SUP.next" "$RT/$SUP"
  fi
  setup_project_dir
  mkdir -p "$PROJECT_DIR/.trellis" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/empty-bin"
  ln -s "$RT" "$PROJECT_DIR/.trellis/runtime"
  printf 'x\n' > "$PROJECT_DIR/f.txt"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
}

teardown() {
  teardown_project_dir
}

# Prepend a 6s sleep to a library the guard sources: a slow bootstrap.
slow_lib() {
  local lib="$RT/$1"
  { printf 'sleep 6\n'; cat "$lib"; } > "$lib.next"
  mv "$lib.next" "$lib"
}

extend_test_deadline() {
  local supervisor="$RT/$SUP"
  [ "$(grep -c '^my \$DEADLINE_SECS = 3;$' "$supervisor")" -eq 1 ] || {
    echo "expected the test-copy supervisor deadline to be 3s"
    return 1
  }
  sed 's/^my \$DEADLINE_SECS = 3;$/my $DEADLINE_SECS = 20;/' "$supervisor" > "$supervisor.next"
  mv "$supervisor.next" "$supervisor"
  grep -qx 'my $DEADLINE_SECS = 20;' "$supervisor"
}

stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$STUBS/$1"
  chmod 755 "$STUBS/$1"
}

finish_run() {
  status=$?
  set -e
  stderr="$(cat "$BATS_TEST_TMPDIR/stderr")"
  elapsed=$((SECONDS - start))
}

# run_registered <template> <guard> <event>: run the rendered command for
# <guard> the way the client does, against the copied runtime.
run_registered() {
  local cmd
  cmd="$(jq -r --arg g "/$2.sh" '[.hooks.PreToolUse[].hooks[].command | select(contains($g))][0]' "$REPO/$1")"
  start=$SECONDS
  set +e
  # shellcheck disable=SC2086
  output="$(cd "$PROJECT_DIR" && printf '%s' "$3" | env HOME="$BATS_TEST_TMPDIR/home" \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR" ${EXTRA_ENV:-} \
    /bin/bash -c "$cmd" 2>"$BATS_TEST_TMPDIR/stderr")"
  finish_run
}

# entry_script <claude|codex>: the shipped sh entry, taken from the template.
entry_script() {
  local template="$CLAUDE_TEMPLATE"
  [ "$1" = codex ] && template="$CODEX_TEMPLATE"
  jq -r '.hooks.PreToolUse[0].hooks[0].command' "$REPO/$template" |
    sed -n "s/^.*\/bin\/sh -c '\(.*\)' guard-supervise .*$/\1/p"
}

# supervise <claude|codex> <stub-or-path> [input]: the shipped sh entry and the
# copied supervisor, on a stub guard.
supervise() {
  local target="$2" input="${3-}" script
  [ -f "$RT/$SUP" ] || { echo "supervisor missing: $SUP"; return 1; }
  script="$(entry_script "$1")"
  [ -n "$script" ] || { echo "no sh entry in the $1 template"; return 1; }
  [ -n "$input" ] || input='{}'
  case "$target" in /*) ;; *) target="$STUBS/$target" ;; esac
  start=$SECONDS
  set +e
  output="$(printf '%s' "$input" | /bin/sh -c "$script" guard-supervise "$RT/$SUP" "$1" test-guard "$target" \
    2>"$BATS_TEST_TMPDIR/stderr")"
  finish_run
}

assert_claude_deny() {
  [ "$status" -eq 0 ] || { echo "status=$status stderr=$stderr"; return 1; }
  printf '%s' "$output" | jq -se 'length == 1' >/dev/null || { echo "not one JSON document: $output"; return 1; }
  printf '%s' "$output" | jq -e --arg re "$1" '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | test($re))' >/dev/null || { echo "$output"; return 1; }
}

assert_codex_block() {
  [ "$status" -eq 2 ] || { echo "status=$status stderr=$stderr"; return 1; }
  printf '%s' "$output" | jq -se 'length == 1' >/dev/null || { echo "not one JSON document: $output"; return 1; }
  printf '%s' "$output" | jq -e --arg re "$1" '.decision == "block" and (.reason | test($re))' >/dev/null ||
    { echo "$output"; return 1; }
  [[ "$stderr" =~ $1 ]] || { echo "stderr=$stderr"; return 1; }
}

assert_deny() {
  if [ "$1" = claude ]; then assert_claude_deny "$2"; else assert_codex_block "$2"; fi
}

assert_quick() {
  [ "$elapsed" -le 5 ] || { echo "elapsed=${elapsed}s"; return 1; }
}

BASH_EVENT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'

edit_event() {
  jq -nc --arg f "$PROJECT_DIR/f.txt" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",session_id:"s1",tool_input:{file_path:$f}}'
}

# --- the deadline covers bootstrap, through the rendered registration ---------

@test "claude block-destructive: a slow sourced dependency is denied at the deadline" {
  slow_lib core-rules/hooks/lib/deps.sh
  run_registered "$CLAUDE_TEMPLATE" block-destructive "$BASH_EVENT"
  assert_claude_deny "$TIMED_OUT"
  assert_quick
}

@test "claude reread-guard: a slow sourced dependency is denied at the deadline" {
  slow_lib core-rules/hooks/lib/deps.sh
  run_registered "$CLAUDE_TEMPLATE" reread-guard "$(edit_event)"
  assert_claude_deny "$TIMED_OUT"
  assert_quick
}

@test "claude skill-preload-guard: a slow sourced dependency is denied at the deadline" {
  slow_lib core-rules/hooks/lib/skill-size.sh
  run_registered "$CLAUDE_TEMPLATE" skill-preload-guard \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"commit"}}'
  assert_claude_deny "$TIMED_OUT"
  assert_quick
}

@test "codex block-destructive: a slow sourced dependency is blocked at the deadline" {
  slow_lib core-rules/codex/hooks/lib/deps.sh
  run_registered "$CODEX_TEMPLATE" block-destructive "$BASH_EVENT"
  assert_codex_block "$TIMED_OUT"
  assert_quick
}

@test "codex reread-guard: a slow sourced dependency is blocked at the deadline" {
  slow_lib core-rules/codex/hooks/lib/deps.sh
  run_registered "$CODEX_TEMPLATE" reread-guard "$(edit_event)"
  assert_codex_block "$TIMED_OUT"
  assert_quick
}

@test "PERL5LIB/PERL5OPT in the client environment cannot stop the clock" {
  mkdir -p "$BATS_TEST_TMPDIR/evil/Time"
  printf 'package Time::HiRes; sub time { 0 } sub sleep { } 1;\n' > "$BATS_TEST_TMPDIR/evil/Time/HiRes.pm"
  printf 'package Skip; BEGIN { exit 0 } 1;\n' > "$BATS_TEST_TMPDIR/evil/Skip.pm"
  slow_lib core-rules/hooks/lib/deps.sh
  EXTRA_ENV="PERL5LIB=$BATS_TEST_TMPDIR/evil PERL5OPT=-MSkip" \
    run_registered "$CLAUDE_TEMPLATE" block-destructive "$BASH_EVENT"
  assert_claude_deny "$TIMED_OUT"
  assert_quick
}

@test "pi: a stalled required guard is denied at the deadline" {
  local event
  # pi runs the runtime payload's hooks in place.
  printf '#!/bin/bash\nsleep 6\n' > "$RT/core-rules/codex/hooks/block-destructive.sh"
  printf '#!/bin/bash\nexit 0\n' > "$RT/core-rules/codex/hooks/pr-gate-shiftleft.sh"
  event="$(jq -nc --arg cwd "$PROJECT_DIR" '{schema_version:1,harness:"pi",cwd:$cwd,session_id:"s",
    phase:"pre_action",native_event:"tool_call",action:{family:"shell",tool_name:"bash",input:{command:"ls"},targets:[]}}' |
    base64 | tr -d '\n')"
  start=$SECONDS
  set +e
  output="$(cd "$PROJECT_DIR" && HOME="$BATS_TEST_TMPDIR/home" bash "$RT/core-rules/pi/hooks/dispatch.sh" --base64 "$event" 2>"$BATS_TEST_TMPDIR/stderr")"
  finish_run
  printf '%s' "$output" | tail -n 1 | jq -e --arg re "$TIMED_OUT" '.decision == "deny" and (.reason | test($re))' >/dev/null ||
    { echo "$output"; false; }
  assert_quick
}

# --- the sh entry fails closed ---------------------------------------------------

@test "no perl on PATH: every rendered registration denies instead of erroring" {
  local guard
  for guard in block-destructive reread-guard skill-preload-guard; do
    EXTRA_ENV="PATH=$BATS_TEST_TMPDIR/empty-bin" run_registered "$CLAUDE_TEMPLATE" "$guard" "$BASH_EVENT"
    assert_claude_deny 'guard supervisor failed \(status 127\); refusing$' || { echo "$guard"; return 1; }
  done
  for guard in block-destructive reread-guard; do
    EXTRA_ENV="PATH=$BATS_TEST_TMPDIR/empty-bin" run_registered "$CODEX_TEMPLATE" "$guard" "$BASH_EVENT"
    assert_codex_block 'guard supervisor failed \(status 127\); refusing$' || { echo "$guard"; return 1; }
  done
}

@test "a missing supervisor file denies instead of erroring" {
  [ -f "$RT/$SUP" ] || { echo "supervisor missing: $SUP"; false; }
  mv "$RT/$SUP" "$RT/$SUP.aside"
  run_registered "$CLAUDE_TEMPLATE" block-destructive "$BASH_EVENT"
  assert_claude_deny 'guard supervisor failed'
  run_registered "$CODEX_TEMPLATE" block-destructive "$BASH_EVENT"
  assert_codex_block 'guard supervisor failed'
}

@test "a guard that signals the supervisor still gets a deny" {
  local harness
  stub parricide.sh 'kill -TERM $PPID; sleep 6'
  for harness in claude codex; do
    supervise "$harness" parricide.sh
    assert_deny "$harness" 'supervisor received SIGTERM; refusing$' || { echo "$harness"; return 1; }
    assert_quick
  done
}

# --- streams -------------------------------------------------------------------

@test "a stalled guard whose daemon holds stderr: the whole capture ends before the client timeout" {
  local both
  [ -f "$RT/$SUP" ] || { echo "supervisor missing: $SUP"; false; }
  stub stall.sh "perl -MPOSIX -e 'POSIX::setsid(); sleep 6' &
sleep 30"
  start=$SECONDS
  both="$(printf '{}' | /bin/sh -c "$(entry_script claude)" guard-supervise "$RT/$SUP" claude test-guard "$STUBS/stall.sh" 2>&1)"
  elapsed=$((SECONDS - start))
  [[ "$both" == *"test-guard: $TIMED_OUT"* ]] || { echo "$both"; false; }
  assert_quick
}

@test "a large event and an escaped stdin holder cannot hold the capture open" {
  local input
  stub hold-stdin.sh "perl -MPOSIX -e 'POSIX::setsid(); sleep 6' <&0 &
sleep 30"
  input="$(head -c 2097152 /dev/zero | tr '\0' x)"
  supervise claude hold-stdin.sh "$input"
  assert_claude_deny "$TIMED_OUT"
  assert_quick
}

@test "the guard reads the whole event from the supervisor's spool" {
  stub echo-size.sh 'n=$(wc -c | tr -d " "); printf "%s\n" "{\"decision\":\"block\",\"reason\":\"$n\"}"; echo "$n" >&2; exit 2'
  supervise codex echo-size.sh "$(head -c 300000 /dev/zero | tr '\0' x)"
  assert_codex_block '^300000$'
}

@test "output still open after the guard exits is refused, never read as an allow" {
  local harness target
  local deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"late"}}'
  stub delayed.sh "( sleep 1; printf '%s\n' '$deny' ) &
exit 0"
  stub partial.sh "printf '{\"hookSpecificOutput\":'; ( sleep 1; printf '{}}\n' ) &
exit 0"
  for harness in claude codex; do
    for target in delayed.sh partial.sh; do
      supervise "$harness" "$target"
      assert_deny "$harness" 'output still open; refusing$' || { echo "$harness $target"; return 1; }
    done
  done
}

@test "a daemon that keeps only stderr does not hold an allow to the deadline" {
  stub stderr-only.sh "perl -MPOSIX -e 'POSIX::setsid(); sleep 6' >/dev/null &
exit 0"
  supervise claude stderr-only.sh
  [ "$status" -eq 0 ] || { echo "status=$status out=$output"; false; }
  [ -z "$output" ]
  assert_quick
}

# --- results -------------------------------------------------------------------

@test "exec failure, exit 1, exit 127 and a signal are denied for both harnesses" {
  local harness target
  stub one.sh 'exit 1'
  stub missing-cmd.sh 'exit 127'
  stub killed.sh 'kill -KILL $$'
  for harness in claude codex; do
    for target in "$STUBS/does-not-exist.sh" one.sh missing-cmd.sh killed.sh; do
      supervise "$harness" "$target"
      assert_deny "$harness" 'refusing$' || { echo "$harness $target"; return 1; }
    done
  done
}

@test "anything but empty output or one valid decision is denied for both harnesses" {
  extend_test_deadline
  local harness target
  stub two.sh "printf '{}\\n{}\\n'"
  stub malformed.sh "printf '{\"decision\"'"
  stub empty-object.sh "printf '{}'"
  stub foo.sh "printf '{\"foo\":1}'"
  stub claude-shape.sh "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\"}}'"
  stub codex-shape.sh "printf '%s' '{\"decision\":\"block\",\"reason\":\"x\"}'"
  stub empty-block.sh 'exit 2'
  for target in two.sh malformed.sh empty-object.sh foo.sh codex-shape.sh; do
    supervise claude "$target"
    assert_claude_deny 'not exactly one decision document; refusing$' || { echo "claude $target"; return 1; }
  done
  for target in two.sh malformed.sh empty-object.sh foo.sh claude-shape.sh empty-block.sh; do
    supervise codex "$target"
    assert_codex_block 'refusing$' || { echo "codex $target"; return 1; }
  done
}

@test "a Claude guard's own exit 2 becomes an explicit deny document" {
  stub refuse.sh 'echo "test-guard: jq required but not found; refusing" >&2; exit 2'
  supervise claude refuse.sh
  assert_claude_deny 'guard refused \(test-guard: jq required but not found; refusing\) with exit 2; refusing$'
}

@test "oversized output is refused before any passthrough, pi included" {
  local big
  stub big.sh "printf '%s' '{\"hookSpecificOutput\":{\"additionalContext\":\"x\"}}'; head -c 1100000 /dev/zero | tr '\\0' ' '; printf '%s\n' '{\"decision\":\"block\",\"reason\":\"late\"}'"
  supervise claude big.sh
  assert_claude_deny 'capture limit; refusing$'
  supervise codex big.sh
  assert_codex_block 'capture limit; refusing$'
  set +e
  big="$(printf '{}' | perl "$RT/$SUP" pi test-guard "$STUBS/big.sh" 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || { echo "pi status=$status"; false; }
  printf '%s' "$big" | jq -e '.decision == "block" and (.reason | test("capture limit"))' >/dev/null
}

@test "pi mode blocks malformed exit-0 output and passes valid results through" {
  extend_test_deadline
  local out
  stub empty-object.sh "printf '{}'"
  stub advice.sh "printf '%s\n' '{\"hookSpecificOutput\":{\"additionalContext\":\"note\"}}'"
  set +e
  out="$(printf '{}' | perl "$RT/$SUP" pi test-guard "$STUBS/empty-object.sh" 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || { echo "$status $out"; false; }
  [[ "$out" == *'"decision":"block"'* ]] || { echo "$status $out"; false; }
  out="$(printf '{}' | perl "$RT/$SUP" pi test-guard "$STUBS/advice.sh")"
  [ "$out" = '{"hookSpecificOutput":{"additionalContext":"note"}}' ]
}

@test "a valid single decision and an allow pass through unchanged" {
  extend_test_deadline
  local deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub says no"}}'
  stub claude-deny.sh "printf '%s\\n' '$deny'"
  stub codex-block.sh "printf '%s\\n' '{\"decision\":\"block\",\"reason\":\"stub says no\"}'; echo 'stub says no' >&2; exit 2"
  stub allow.sh 'echo advisory >&2; exit 0'
  supervise claude claude-deny.sh
  [ "$status" -eq 0 ] || { echo "$status $output"; false; }
  [ "$output" = "$deny" ] || { echo "$status $output"; false; }
  supervise codex codex-block.sh
  [ "$status" -eq 2 ] || { echo "$status $output $stderr"; false; }
  [ "$output" = '{"decision":"block","reason":"stub says no"}' ] || { echo "$status $output $stderr"; false; }
  [ "$stderr" = 'stub says no' ] || { echo "$status $output $stderr"; false; }
  supervise claude allow.sh
  [ "$status" -eq 0 ] || { echo "$status $output $stderr"; false; }
  [ -z "$output" ] || { echo "$status $output $stderr"; false; }
  [ "$stderr" = advisory ] || { echo "$status $output $stderr"; false; }
  supervise codex allow.sh
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$status $output"; false; }
}

# --- the real guards through their registrations ------------------------------

@test "real guard decisions pass through the registered supervisor unchanged" {
  extend_test_deadline
  run_registered "$CLAUDE_TEMPLATE" block-destructive '{"tool_input":{"command":"git push --force origin main"}}'
  printf '%s' "$output" | jq -se 'length == 1 and (.[0].hookSpecificOutput.permissionDecisionReason | startswith("Blocked force push"))' \
    >/dev/null || { echo "$output"; false; }
  run_registered "$CLAUDE_TEMPLATE" block-destructive "$BASH_EVENT"
  [ "$status" -eq 0 ] || { echo "$status $output"; false; }
  [ -z "$output" ] || { echo "$status $output"; false; }
  run_registered "$CODEX_TEMPLATE" block-destructive '{"tool_input":{"command":"git push --force origin main"}}'
  assert_codex_block '^Blocked force push'
  run_registered "$CODEX_TEMPLATE" block-destructive "$BASH_EVENT"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$status $output"; false; }
}

# --- registrations ------------------------------------------------------------

@test "every template starts each bright-line guard through the sanitizing sh entry at 30s" {
  local template harness guard tail got
  while IFS='|' read -r template harness guard tail; do
    got="$(jq -r --arg g "/$guard.sh" '[.hooks.PreToolUse[].hooks[] | select(.command | contains($g))]
      | if length == 1 then "\(.[0].timeout)|\(.[0].command)" else "count \(length)" end' "$REPO/$template")"
    [ "${got%%|*}" = "$CLIENT_TIMEOUT" ] || { echo "$template $guard: ${got%%|*}"; return 1; }
    case "${got#*|}" in
      *"/bin/sh -c '"*"$SANITIZE"*"' guard-supervise $tail") ;;
      *) echo "$template $guard: ${got#*|}"; return 1 ;;
    esac
  done <<'EOF'
core-rules/templates/claude-settings.local.json|claude|block-destructive|"$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" claude block-destructive "$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/block-destructive.sh"
core-rules/templates/claude-settings.local.json|claude|reread-guard|"$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" claude reread-guard "$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/reread-guard.sh"
core-rules/templates/claude-settings.local.json|claude|skill-preload-guard|"$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" claude skill-preload-guard "$CLAUDE_PROJECT_DIR/.trellis/runtime/core-rules/hooks/skill-preload-guard.sh"
core-rules/templates/codex-hooks.local.json|codex|block-destructive|"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" codex block-destructive "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.trellis/runtime/core-rules/codex/hooks/block-destructive.sh"
core-rules/templates/codex-hooks.local.json|codex|reread-guard|"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" codex reread-guard "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.trellis/runtime/core-rules/codex/hooks/reread-guard.sh"
core-rules/templates/claude-settings.json|claude|block-destructive|"$CLAUDE_PROJECT_DIR/.claude/hooks/lib/guard-supervise.pl" claude block-destructive "$CLAUDE_PROJECT_DIR/.claude/hooks/block-destructive.sh"
core-rules/templates/claude-settings.json|claude|reread-guard|"$CLAUDE_PROJECT_DIR/.claude/hooks/lib/guard-supervise.pl" claude reread-guard "$CLAUDE_PROJECT_DIR/.claude/hooks/reread-guard.sh"
core-rules/templates/claude-settings.json|claude|skill-preload-guard|"$CLAUDE_PROJECT_DIR/.claude/hooks/lib/guard-supervise.pl" claude skill-preload-guard "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-preload-guard.sh"
core-rules/codex/hooks.json|codex|block-destructive|"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.codex/hooks/lib/guard-supervise.pl" codex block-destructive /bin/bash "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.codex/hooks/block-destructive.sh"
core-rules/codex/hooks.json|codex|reread-guard|"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.codex/hooks/lib/guard-supervise.pl" codex reread-guard /bin/bash "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.codex/hooks/reread-guard.sh"
EOF
}

@test "the inheritance manifest links guard-supervise.pl for every harness, without widening a suffix" {
  local h
  # pi renders no hook leaves; its dispatcher runs the payload supervisor.
  jq -e '[.harnesses.pi.links[] | .destination // .destination_dir | select(startswith(".pi/hooks"))] | length == 0' \
    "$REPO/core-rules/inheritance-manifest.json" >/dev/null
  for h in claude codex; do
    jq -e --arg h "$h" '[.harnesses[$h].links[] | select(.source == "core-rules/hooks/lib/guard-supervise.pl"
        and .destination == ".\($h)/hooks/lib/guard-supervise.pl")] | length == 1' \
      "$REPO/core-rules/inheritance-manifest.json" >/dev/null || { echo "$h"; return 1; }
  done
  jq -e '[.harnesses[].links[] | select(.source_children != null) | .suffix // empty | select(. == ".pl")] | length == 0' \
    "$REPO/core-rules/inheritance-manifest.json" >/dev/null
}

@test "the pi dispatcher starts required guards through the supervisor with a clean perl env" {
  grep -q 'env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u ENV -u BASH_ENV' "$REPO/core-rules/pi/hooks/dispatch.sh"
  grep -q 'perl "$(dispatch_dir)/../../hooks/lib/guard-supervise.pl" pi' "$REPO/core-rules/pi/hooks/dispatch.sh"
}

@test "shipped supervisor deadline is 20s, well below the 30s client timeout" {
  grep -qx 'my $DEADLINE_SECS = 20;' "$REPO/$SUP"
  [ $((20 + 10)) -le "$CLIENT_TIMEOUT" ]
  run grep -c 'ENV{' "$REPO/$SUP"
  [ "$output" = 0 ] || { echo "the supervisor reads the environment"; false; }
}

@test "advisory pr-gate-shiftleft keeps its own 120s timeout" {
  local template
  for template in "$CLAUDE_TEMPLATE" "$CODEX_TEMPLATE"; do
    jq -e '[.hooks.PreToolUse[].hooks[] | select(.command | contains("/pr-gate-shiftleft.sh")) | .timeout] == [120]' \
      "$REPO/$template" >/dev/null || { echo "$template"; return 1; }
  done
}

# --- client permissions.deny backing -----------------------------------------

@test "rendered Claude template carries exactly the client deny backstop and no allow" {
  jq -e '.permissions == {deny: [
    "Bash(rm -rf /*)",
    "Bash(rm -fr /*)",
    "Bash(rm -rf ~*)",
    "Bash(rm -fr ~*)",
    "Bash(rm -rf $HOME*)",
    "Bash(rm -fr $HOME*)",
    "Bash(rm -rf ..)",
    "Bash(rm -rf ../*)",
    "Bash(git push --force *)",
    "Bash(git push * --force)",
    "Bash(git push * --force *)",
    "Bash(git push -f *)",
    "Bash(git push * -f)",
    "Bash(git push * -f *)",
    "Bash(git reset --hard)",
    "Bash(git reset --hard HEAD)",
    "Bash(git reset --hard HEAD~*)",
    "Bash(git reset --hard origin/*)"
  ]}' "$REPO/$CLAUDE_TEMPLATE" >/dev/null ||
    { jq -c '.permissions' "$REPO/$CLAUDE_TEMPLATE"; false; }
}

# One sample per rule (every * replaced by 1). This shows each rule's obvious
# instance is also a hook denial; it is not a proof that a rule matches nothing
# the hook allows, nor of how the client matches `$HOME` or `~`.
@test "each client deny rule's sample command is also denied by block-destructive" {
  local rule cmd out n=0
  while IFS= read -r rule; do
    case "$rule" in
      'Bash('*')') ;;
      *) echo "not a Bash rule: $rule"; return 1 ;;
    esac
    cmd="${rule#Bash(}"
    cmd="${cmd%)}"
    cmd="${cmd//\*/1}"
    out="$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}' | bash "$HOOKS_DIR/block-destructive.sh")"
    [[ "$out" == *'"permissionDecision":"deny"'* ]] || { echo "sample not denied by the hook: $rule ($cmd)"; return 1; }
    n=$((n + 1))
  done < <(jq -r '.permissions.deny[]' "$REPO/$CLAUDE_TEMPLATE")
  [ "$n" -gt 0 ]
}
