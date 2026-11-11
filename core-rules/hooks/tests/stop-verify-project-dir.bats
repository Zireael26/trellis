#!/usr/bin/env bats
# Codex must not silently verify an inherited Claude checkout instead of the
# checkout named by its event. Real hooks, no live project state.
load helpers
bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  A="$BATS_TEST_TMPDIR/a" B="$BATS_TEST_TMPDIR/b"
  local p
  for p in "$A" "$B"; do
    git -C "$p" init -q
    git -C "$p" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm init
  done
  mkdir -p "$A/.codex" "$A/pkg"
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$A/.codex/hooks.json"
  printf '/.codex/\n' >> "$A/.git/info/exclude"
  export CLAUDE_PROJECT_DIR="$A"
  unset CODEX_PROJECT_DIR
  BASE="$CODEX_HOOKS_DIR/turn-baseline.sh"
  STOP="$CODEX_HOOKS_DIR/stop-verify.sh"
}

invoke_from() {
  local cwd="$1" hook="$2" input="$3"
  run bash -c 'cd "$1" && exec /bin/bash "$2"' _ "$cwd" "$hook" <<<"$input"
}

@test "143-stop inherited Claude checkout cannot silently mask another Codex worktree" {
  local event
  event="$(jq -nc --arg cwd "$B" '{session_id:"mismatch",cwd:$cwd,last_assistant_message:"Done."}')"
  invoke_from "$B" "$BASE" "$event"
  [ "$status" -eq 0 ]
  printf 'changed\n' > "$B/app.js"
  invoke_from "$B" "$STOP" "$event"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("project directory"))' >/dev/null
  # A missing cwd on the later Stop cannot erase the mismatch observed at prompt.
  invoke_from "$A" "$STOP" '{"session_id":"mismatch","last_assistant_message":"Done."}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("project directory"))' >/dev/null
  # A new prompt from the intended checkout clears the stale mismatch.
  event="$(jq -nc --arg cwd "$A/pkg" '{session_id:"mismatch",cwd:$cwd,last_assistant_message:"Done. <!-- dod-receipt cmd=fixture exit=0 diff=+1 --> <!-- follow-ups: none -->"}')"
  invoke_from "$A/pkg" "$BASE" "$event"
  [ "$status" -eq 0 ]
  invoke_from "$A/pkg" "$STOP" "$event"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]]
}

@test "T30 Codex mismatch never appends while the nonce lock is held" {
  local event state key file gen before oldgen
  event="$(jq -nc --arg cwd "$A" '{session_id:"mismatch-lock",cwd:$cwd}')"
  invoke_from "$A" "$BASE" "$event"; [ "$status" -eq 0 ]
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" "$A")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" 'mismatch-lock')"
  file="$state/codex.$key"; gen="$state/generation.codex.$key"
  before="$(cat "$file")"; oldgen="$(cat "$gen")"; mkdir "$state/.nonces.lock"
  event="$(jq -nc --arg cwd "$B" '{session_id:"mismatch-lock",cwd:$cwd}')"
  invoke_from "$B" "$BASE" "$event"
  [ "$status" -eq 0 ] || { rmdir "$state/.nonces.lock"; return 1; }
  [ "$(cat "$file")" = "$before" ] && [ "$(cat "$gen")" = "$oldgen" ] || { rmdir "$state/.nonces.lock"; echo 'mismatch appended or advanced while another process held the lock'; return 1; }
  [ -n "$(find "$state" -name ".poison.codex.$key.*" -type d -print -quit)" ] || { rmdir "$state/.nonces.lock"; echo 'contended mismatch did not poison session'; return 1; }
  rmdir "$state/.nonces.lock"
  invoke_from "$A" "$STOP" '{"session_id":"mismatch-lock","last_assistant_message":"Done."}'
  [ "$status" -eq 0 ] && printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("project directory"))' >/dev/null || { echo "mismatch was not retained: $output"; return 1; }
}

@test "T30 Codex unrecordable mismatch warns without changing prior state" {
  local event state key file gen saved result
  event="$(jq -nc --arg cwd "$A" '{session_id:"mismatch-unwritable",cwd:$cwd}')"
  invoke_from "$A" "$BASE" "$event"; [ "$status" -eq 0 ]
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" "$A")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" 'mismatch-unwritable')"
  file="$state/codex.$key"; gen="$state/generation.codex.$key"; saved="$(cat "$file")"
  mkdir "$state/.nonces.lock"; chmod 400 "$file" "$gen" "$state/nonces.log"; chmod 500 "$state"
  event="$(jq -nc --arg cwd "$B" '{session_id:"mismatch-unwritable",cwd:$cwd}')"
  run --separate-stderr bash -c 'cd "$1" && exec /bin/bash "$2"' _ "$B" "$BASE" <<<"$event"
  result="$output"; local rc="$status"
  chmod 700 "$state"; chmod 600 "$file" "$gen" "$state/nonces.log"; rmdir "$state/.nonces.lock"
  [ "$rc" -eq 0 ] && printf '%s' "$result" | jq -e '.hookSpecificOutput.additionalContext | contains("next Stop may not detect this turn")' >/dev/null || { echo "unrecordable mismatch did not warn: $rc $result"; return 1; }
  [ "$(cat "$file")" = "$saved" ] || { echo 'unrecordable mismatch altered old baseline'; return 1; }
}

@test "T30 Codex mismatch publishes unknown and advances generation under lock" {
  local event state key file gen before
  event="$(jq -nc --arg cwd "$A" '{session_id:"mismatch-generation",cwd:$cwd}')"
  invoke_from "$A" "$BASE" "$event"; [ "$status" -eq 0 ]
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" "$A")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" 'mismatch-generation')"
  file="$state/codex.$key"; gen="$state/generation.codex.$key"; before="$(cat "$gen")"
  event="$(jq -nc --arg cwd "$B" '{session_id:"mismatch-generation",cwd:$cwd}')"
  invoke_from "$B" "$BASE" "$event"; [ "$status" -eq 0 ]
  [ "$(cat "$gen")" -eq "$((before + 1))" ] || { echo 'mismatch failed to advance generation'; return 1; }
  grep -qxF 'trellis-turn-baseline v2 unknown' "$file" || { echo 'mismatch did not poison baseline'; return 1; }
  invoke_from "$A" "$STOP" '{"session_id":"mismatch-generation","last_assistant_message":"Done."}'
  [ "$status" -eq 0 ] && printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("project directory"))' >/dev/null || { echo "mismatch was not retained: $output"; return 1; }
}

@test "143-stop distinct linked worktrees are not treated as the same checkout" {
  local other="$BATS_TEST_TMPDIR/linked" event
  # Separate flags: the suite's Git fence parses worktree options one by one.
  git -C "$A" worktree add -q -b linked "$other"
  event="$(jq -nc --arg cwd "$other" '{session_id:"linked",cwd:$cwd,last_assistant_message:"Done."}')"
  invoke_from "$other" "$BASE" "$event"
  [ "$status" -eq 0 ]
  printf 'linked change\n' > "$other/app.js"
  invoke_from "$other" "$STOP" "$event"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("project directory"))' >/dev/null
}

@test "143-stop explicit Codex project and a same-worktree subdirectory remain authoritative" {
  local event
  event="$(jq -nc --arg cwd "$A/pkg" '{session_id:"same",cwd:$cwd,last_assistant_message:"Done."}')"
  invoke_from "$A/pkg" "$BASE" "$event"
  [ "$status" -eq 0 ]
  invoke_from "$A/pkg" "$STOP" "$event"
  [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
  # Process cwd alone is not the event cwd and must not contradict the env.
  event='{"session_id":"no-event-cwd","last_assistant_message":"Done."}'
  invoke_from "$B" "$BASE" "$event"
  [ "$status" -eq 0 ]
  invoke_from "$B" "$STOP" "$event"
  [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
  export CODEX_PROJECT_DIR="$A"
  event="$(jq -nc --arg cwd "$B" '{session_id:"explicit",cwd:$cwd,last_assistant_message:"Done."}')"
  invoke_from "$B" "$BASE" "$event"
  [ "$status" -eq 0 ]
  invoke_from "$B" "$STOP" "$event"
  [ "$status" -eq 0 ]; [[ "$output" != *'"decision":"block"'* ]]
}
