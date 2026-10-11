#!/usr/bin/env bats
# SessionStart roster handling, run end to end through BOTH hook copies
# (Claude Code and Codex).
#
# Lean C04: SessionStart never runs the resolver (its live usage and credential
# probes cost up to 2 x 20 s) and never adopts a cached roles-resolved.json:
# the file carries no resolver-origin attestation, so a same-account writer
# could plant a fresh, internally consistent roster (B4-S1). The hook removes
# this pane's cached artifact, leaves another pane's alone, and reports the
# roles as undecided with the on-demand resolver command. The spec 052 SC7
# fixtures (built by sc7_artifacts.py, never by the resolver) are planted as
# that cached artifact; the active-release resolver is a stub that counts its
# calls and hangs, so any live resolution shows up as a call and a slow start.

load helpers

REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
SC7_BUILDER="$REPO_ROOT/scripts/tests/fixtures/herdr-task-routing/sc7_artifacts.py"
SESSION_HOOKS=("$HOOKS_DIR/herdr-foreman-session.sh" "$CODEX_HOOKS_DIR/herdr-foreman-session.sh")
# Generous for one stat and unlink, far below one hung resolver pass (20 s).
SESSION_BUDGET_SECONDS=4

setup() {
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  SKILL="$FAKE_HOME/.trellis/releases/1.2.3/payload/core-rules/skills/herdr-foreman"
  ROLE_STATE="$FAKE_HOME/.trellis/state/roles-resolved.json"
  RESOLVER_CALLS="$BATS_TEST_TMPDIR/resolver-calls"
  SC7_DIR="$BATS_TEST_TMPDIR/sc7"
  CLI_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SKILL/scripts" "$CLI_DIR" "$(dirname "$ROLE_STATE")"
  cp "$HOOKS_DIR/../skills/herdr-foreman/roles.json" "$SKILL/roles.json"
  printf '{"active_cli_release":"1.2.3"}\n' >"$FAKE_HOME/.trellis/config.json"
  : >"$RESOLVER_CALLS"

  # Stands in for a resolver whose live probes hang: one line per call, then
  # a sleep well past the hook's old 20 s pass cap.
  cat >"$SKILL/scripts/resolve-roles.py" <<'PY'
import os, sys, time
with open(os.environ["RESOLVER_CALLS"], "a") as sink:
    sink.write(" ".join(sys.argv[1:]) + "\n")
time.sleep(30)
PY
  printf '#!/usr/bin/env bash\nexit 0\n' >"$CLI_DIR/pi"
  cat >"$CLI_DIR/herdr" <<'EOF'
#!/usr/bin/env bash
printf '{"result":{"agents":[]}}\n'
EOF
  chmod +x "$CLI_DIR/pi" "$CLI_DIR/herdr"

  python3 "$SC7_BUILDER" "$SKILL/roles.json" "$SC7_DIR" \
    fixture-workspace fixture-pane fixture-workspace:fixture-pane:sc7-pass
}

# plant_roster SOURCE: install SOURCE as the cached deciding roster, mode 0600.
plant_roster() {
  rm -f "$ROLE_STATE"
  cp "$1" "$ROLE_STATE"
  chmod 600 "$ROLE_STATE"
}

# rewrite_roster PYTHON: edit the planted roster in place (`artifact` in scope).
rewrite_roster() {
  python3 - "$ROLE_STATE" "$1" <<'PY'
import datetime as dt, json, sys
path, code = sys.argv[1:]
artifact = json.load(open(path))
exec(code)
json.dump(artifact, open(path, "w"))
PY
  chmod 600 "$ROLE_STATE"
}

# run_session HOOK [PANE]: one SessionStart in the fixture workspace. Fails
# when the hook exits nonzero, called the resolver, or overran the budget.
run_session() {
  local hook="$1" pane="${2:-fixture-pane}" start
  : >"$RESOLVER_CALLS"
  start=$(date +%s)
  run env -u CODE_REVIEWER_CMD \
    HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID="$pane" \
    RESOLVER_CALLS="$RESOLVER_CALLS" PATH="$CLI_DIR:$PATH" \
    bash "$hook"
  ELAPSED=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ] || { echo "$hook exited $status: $output"; return 1; }
  [ ! -s "$RESOLVER_CALLS" ] || {
    echo "$hook ran a live resolver pass at SessionStart: $(cat "$RESOLVER_CALLS")"; return 1; }
  [ "$ELAPSED" -lt "$SESSION_BUDGET_SECONDS" ] || {
    echo "$hook took ${ELAPSED}s at SessionStart"; return 1; }
}

@test "both session hook copies are byte-identical" {
  cmp "${SESSION_HOOKS[@]}"
}

@test "visible-pane HARD rule precedes DEGRADED identity and missing-pi exits in both hooks" {
  local hook
  local rule="HARD RULE (owner): all delegated agent work (workers, reviewers, consults, foremen, research, one-shot pi -p/codex exec) MUST use visible Herdr panes; only harness-native subagents and Dynamic Workflow agents are exempt. One-shot: core-rules/references/herdr-foreman.md § pi launch forms (1.1.0 and above)."
  mkdir -p "$CLI_DIR/no-pi"
  for hook in "${SESSION_HOOKS[@]}"; do
    run env HERDR_ENV=1 HERDR_WORKSPACE_ID= HERDR_PANE_ID= /bin/bash "$hook"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$rule" ]
    [[ "${lines[1]}" == "DEGRADED: inside Herdr but the current workspace or pane identity is unavailable;"* ]]

    # Empty PATH forces the next early exit without touching resolver state.
    run env HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
      PATH="$CLI_DIR/no-pi" /bin/bash "$hook"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$rule" ]
    [[ "${lines[1]}" == "DEGRADED: inside Herdr but pi is not on PATH;"* ]]
  done
}

@test "both session hooks stay silent outside Herdr" {
  local hook
  for hook in "${SESSION_HOOKS[@]}"; do
    run env -u HERDR_ENV /bin/bash "$hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

UNDECIDED="DEGRADED: SessionStart does not adopt a cached deciding roster; implementer, reviewer, security_reviewer, merge_reviewer, and refuter are undecided."

# assert_undecided HOOK: the roles are reported undecided with the on-demand
# command, and nothing is reported as adopted or decided.
assert_undecided() {
  [[ "$output" == *"$UNDECIDED"* ]] || { echo "$1: undecided line missing: $output"; return 1; }
  [[ "$output" == *"--implementer <agent> in this pane"* ]] || { echo "$1: on-demand command missing: $output"; return 1; }
  [[ "$output" == *"Existing pi panes"* ]] || { echo "$1: pi panes missing: $output"; return 1; }
  [[ "$output" != *"Cached deciding roster ("* && "$output" != *"adopted"* ]] || {
    echo "$1 adopted a cached roster: $output"; return 1; }
}

@test "C04/B4-S1: a fresh, consistent non-resolver roster for this pane is not adopted and is removed" {
  local hook
  for hook in "${SESSION_HOOKS[@]}"; do
    plant_roster "$SC7_DIR/a.json"
    run_session "$hook"
    assert_undecided "$hook"
    [[ "$output" == *"Removed this pane's cached deciding roster at $ROLE_STATE"* ]] || { echo "$output"; false; }
    [ ! -e "$ROLE_STATE" ] || { echo "$hook kept the planted roster"; false; }
  done
}

@test "C04/B4-S1: no SC7 artifact, valid or invalid, is adopted at SessionStart" {
  local hook case
  for case in $(python3 -c 'import json,sys; print(" ".join(r["case"] for r in json.load(open(sys.argv[1]))))' "$SC7_DIR/manifest.json"); do
    for hook in "${SESSION_HOOKS[@]}"; do
      plant_roster "$SC7_DIR/$case.json"
      run_session "$hook" || { echo "SC7($case)"; false; }
      assert_undecided "$hook" || { echo "SC7($case)"; false; }
      [ ! -e "$ROLE_STATE" ] || { echo "$hook kept SC7($case)"; false; }
    done
  done
}

@test "C04/B4-S1: a re-scoped, re-timestamped replay is not adopted" {
  local hook
  for hook in "${SESSION_HOOKS[@]}"; do
    plant_roster "$SC7_DIR/a.json"
    rewrite_roster 'artifact["resolved_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).isoformat(timespec="seconds"); artifact["resolution_scope"]["herdr_pane_id"] = "other-pane"; artifact["resolution_nonce"] = "fixture-workspace:other-pane:old"'
    # Replay: relabel the stale foreign roster as this pane's and refresh it.
    rewrite_roster 'artifact["resolved_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"); artifact["resolution_scope"]["herdr_pane_id"] = "fixture-pane"'
    run_session "$hook"
    assert_undecided "$hook"
    [ ! -e "$ROLE_STATE" ]
  done
}

@test "C04: with no cached roster SessionStart reports undecided roles without a live probe" {
  local hook
  for hook in "${SESSION_HOOKS[@]}"; do
    rm -f "$ROLE_STATE"
    run_session "$hook"
    assert_undecided "$hook"
    [[ "$output" != *"Removed"* ]] || { echo "$output"; false; }
    [ ! -e "$ROLE_STATE" ]
  done
}

@test "C04: another pane's cached roster, valid or tampered, is left untouched and not adopted" {
  local hook case before
  for case in a c; do
    for hook in "${SESSION_HOOKS[@]}"; do
      plant_roster "$SC7_DIR/$case.json"
      before="$(cksum <"$ROLE_STATE")"
      run_session "$hook" other-pane
      assert_undecided "$hook"
      [[ "$output" == *"belongs to another Herdr workspace or pane; it was left in place"* ]] || { echo "$output"; false; }
      [ -f "$ROLE_STATE" ] || { echo "$hook removed SC7($case) from another pane"; false; }
      [ "$(cksum <"$ROLE_STATE")" = "$before" ] || { echo "$hook modified another pane's roster"; false; }
    done
  done
}

@test "C04: a non-private or symlinked cached roster is removed without following the link" {
  local hook target
  target="$BATS_TEST_TMPDIR/symlink-target.json"
  for hook in "${SESSION_HOOKS[@]}"; do
    plant_roster "$SC7_DIR/a.json"
    chmod 644 "$ROLE_STATE"
    run_session "$hook"
    assert_undecided "$hook"
    [ ! -e "$ROLE_STATE" ]

    cp "$SC7_DIR/a.json" "$target"
    chmod 600 "$target"
    ln -s "$target" "$ROLE_STATE"
    run_session "$hook"
    assert_undecided "$hook"
    [ ! -e "$ROLE_STATE" ] && [ ! -L "$ROLE_STATE" ] || { echo "symlinked roster kept"; false; }
    [ -f "$target" ] || { echo "hook followed the symlink and removed its target"; false; }
    [ "$(cksum <"$target")" = "$(cksum <"$SC7_DIR/a.json")" ] || { echo "symlink target modified"; false; }
  done
}
