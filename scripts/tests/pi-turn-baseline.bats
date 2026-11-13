#!/usr/bin/env bats
# The Pi extension's prompt/Stop wiring, under the repository test fence.
bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  PROJECT="$BATS_TEST_TMPDIR/project"
  export HOME="$BATS_TEST_TMPDIR/home" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export TRACE="$BATS_TEST_TMPDIR/checks" TRELLIS_HARNESS=pi CODEX_PROJECT_DIR="$PROJECT" CLAUDE_PROJECT_DIR="$PROJECT"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR" "$PROJECT/node_modules/.bin" "$PROJECT/.codex" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nprintf "typecheck\\n" >> "$TRACE"\n' > "$PROJECT/node_modules/.bin/tsc"
  printf '#!/bin/bash\nprintf "test\\n" >> "$TRACE"\n' > "$BATS_TEST_TMPDIR/bin/npm"
  printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/npx"
  chmod +x "$PROJECT/node_modules/.bin/tsc" "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  printf '/node_modules/\n/.codex/\n' > "$PROJECT/.gitignore"
  printf '{}\n' > "$PROJECT/tsconfig.json"
  printf '{"scripts":{"test":"true"}}\n' > "$PROJECT/package.json"
  printf 'export const value = 1;\n' > "$PROJECT/app.ts"
  git -C "$PROJECT" add .gitignore tsconfig.json package.json app.ts
  git -C "$PROJECT" commit -qm 'fixture seed'
  printf '// pre-existing code change\n' >> "$PROJECT/app.ts"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT/.codex/hooks.json"
  PROMPT="$ROOT/core-rules/codex/hooks/turn-baseline.sh"
  STOP="$ROOT/core-rules/codex/hooks/stop-verify.sh"
}

payload() {
  jq -nc --arg sid "$1" --arg cwd "$PROJECT" '{session_id:$sid,cwd:$cwd,stop_hook_active:false,last_assistant_message:"<!-- dod-receipt cmd=\"fixture\" exit=0 diff=\"+1/-0 (1 files)\" --> <!-- follow-ups: none -->"}'
}

publish() {
  payload "$1" | bash "$PROMPT"
}

settle() {
  payload "$1" | bash "$STOP"
}

@test "Pi publishes session-bound prompt baselines and fails closed on uncertainty" {
  local root
  root="$ROOT"
  run node --test --test-reporter=tap "$root/core-rules/pi/tests/turn-baseline.test.mjs"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "Pi completion and session-boundary regressions stay intact" {
  run node --test --test-reporter=tap "$ROOT/core-rules/pi/tests/completion-gate.test.mjs" "$ROOT/core-rules/pi/tests/session-boundaries.test.mjs"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "two Pi sessions on a pre-dirty checkout run no checks" {
  publish session-a
  publish session-b
  payload session-a > "$BATS_TEST_TMPDIR/a.json"
  payload session-b > "$BATS_TEST_TMPDIR/b.json"
  bash "$STOP" < "$BATS_TEST_TMPDIR/a.json" > "$BATS_TEST_TMPDIR/a.out" 2> "$BATS_TEST_TMPDIR/a.err" &
  a=$!
  bash "$STOP" < "$BATS_TEST_TMPDIR/b.json" > "$BATS_TEST_TMPDIR/b.out" 2> "$BATS_TEST_TMPDIR/b.err" &
  b=$!
  wait "$a"
  wait "$b"
  [ ! -s "$TRACE" ] || { printf 'unexpected checks:\n'; command grep . "$TRACE"; return 1; }
  ! grep -q '"decision":"block"' "$BATS_TEST_TMPDIR/a.out" || false
  ! grep -q '"decision":"block"' "$BATS_TEST_TMPDIR/b.out" || false
}

@test "a real Pi edit runs both typecheck and test" {
  publish editing-session
  printf '// changed in this turn\n' >> "$PROJECT/app.ts"
  run settle editing-session
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]] || false
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "another session's concurrent edit is conservatively checked" {
  publish session-a
  publish session-b
  printf '// external concurrent edit\n' >> "$PROJECT/app.ts"
  run settle session-a
  [ "$status" -eq 0 ]
  run settle session-b
  [ "$status" -eq 0 ]
  [ "$(grep -c '^typecheck$' "$TRACE")" -eq 2 ]
  [ "$(grep -c '^test$' "$TRACE")" -eq 2 ]
}

@test "a change between initial fingerprint and status runs the checks" {
  publish session-a
  export REAL_FIXTURE_GIT="$(command -v git)" RACE_MARK="$BATS_TEST_TMPDIR/raced"
  printf '%s\n' '#!/bin/bash' \
    'if [ "$*" = "status --porcelain --untracked-files=all" ] && [ ! -e "$RACE_MARK" ]; then' \
    '  printf "// concurrent edit\\n" >> "$CODEX_PROJECT_DIR/app.ts"; : > "$RACE_MARK"' \
    'fi' 'exec "$REAL_FIXTURE_GIT" "$@"' > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  run settle session-a
  [ "$status" -eq 0 ]
  [ -f "$RACE_MARK" ]
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "a change immediately after the receipt gate runs checks" {
  local hook="$BATS_TEST_TMPDIR/race-hook"
  publish session-a
  mkdir -p "$hook"
  cp "$STOP" "$hook/stop-verify.sh"
  ln -s "$ROOT/core-rules/codex/hooks/lib" "$hook/lib"
  # Inject in the fixture copy at the exact post-receipt boundary. This must
  # be visible to the final fingerprint, not merely to the carry writer.
  python3 - "$hook/stop-verify.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '    if [ "$TURN_STATE" = "same" ]; then\n      _se_receipt_gate\n'
assert s.count(needle) == 1
p.write_text(s.replace(needle, needle + '      printf "// post-receipt edit\\n" >> "$PROJECT_DIR/app.ts"\n', 1))
PY
  payload session-a > "$BATS_TEST_TMPDIR/stop.json"
  run bash -c 'cd "$1" && bash "$2" < "$3"' _ "$PROJECT" "$hook/stop-verify.sh" "$BATS_TEST_TMPDIR/stop.json"
  [ "$status" -eq 0 ]
  grep -q '^// post-receipt edit$' "$PROJECT/app.ts"
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "an unavailable post-receipt fingerprint runs checks" {
  local hook="$BATS_TEST_TMPDIR/broken-fingerprint-hook"
  publish session-a
  mkdir -p "$hook"
  cp "$STOP" "$hook/stop-verify.sh"
  ln -s "$ROOT/core-rules/codex/hooks/lib" "$hook/lib"
  python3 - "$hook/stop-verify.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '    if [ "$TURN_STATE" = "same" ]; then\n      _se_receipt_gate\n'
assert s.count(needle) == 1
p.write_text(s.replace(needle, needle + '      _se_tree_fingerprint() { return 1; }\n', 1))
PY
  payload session-a > "$BATS_TEST_TMPDIR/stop.json"
  run bash -c 'cd "$1" && bash "$2" < "$3"' _ "$PROJECT" "$hook/stop-verify.sh" "$BATS_TEST_TMPDIR/stop.json"
  [ "$status" -eq 0 ]
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "a no-op carry never certifies a later tree, staged or direct" {
  local lib expected current state mode
  expected="$(bash -c '. "$1"; _se_load_heavy; _se_tree_fingerprint "$2"' _ "$ROOT/core-rules/codex/hooks/lib/deps.sh" "$PROJECT")"
  printf '// later edit\n' >> "$PROJECT/app.ts"
  current="$(bash -c '. "$1"; _se_load_heavy; _se_tree_fingerprint "$2"' _ "$ROOT/core-rules/codex/hooks/lib/deps.sh" "$PROJECT")"
  for lib in "$ROOT/core-rules/codex/hooks/lib/deps.sh" "$ROOT/core-rules/hooks/lib/deps.sh"; do
    for mode in stage direct; do
      state="$BATS_TEST_TMPDIR/carry-${lib#"$ROOT/core-rules/"}-$mode"
      mkdir -p "$state"
      run bash -c '. "$1"; _se_load_heavy; _se_turn_carry_write "$2" pi.fixture "$3" "$4" "$5"' _ "$lib" "$state" "$PROJECT" "$mode" "$expected"
      [ "$status" -eq 0 ]
      [ ! -e "$state/pi.fixture" ]
      [ ! -e "$state/nonces.log" ]
      run bash -c '. "$1"; _se_load_heavy; _se_turn_carry_write "$2" pi.fixture "$3" "$4" "$5"' _ "$lib" "$state" "$PROJECT" "$mode" "$current"
      [ "$status" -eq 0 ]
      [ -s "$state/pi.fixture" ]
      [ -s "$state/nonces.log" ]
    done
  done
}

@test "a failed Pi prompt cannot reuse a previous carry" {
  publish session-a
  run settle session-a
  [ "$status" -eq 0 ]
  [ ! -s "$TRACE" ]
  export TRELLIS_PI_BASELINE_UNTRUSTED=1
  run settle session-a
  [ "$status" -eq 0 ]
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "invalid Pi session identities cannot consume another session baseline" {
  local baseline before kind
  publish session-a
  baseline="$(find "$TRELLIS_HOME/state/turn-baseline" -type f -name 'pi.*' -print)"
  [ -n "$baseline" ]
  before="$BATS_TEST_TMPDIR/baseline-before"
  cp "$baseline" "$before"
  for kind in newline cr nul empty null number missing stream; do
    if [ "$kind" = stream ]; then
      { payload session-a; payload ''; } > "$BATS_TEST_TMPDIR/invalid-stop.json"
    else
      payload session-a | jq --arg kind "$kind" '
        if $kind == "newline" then .session_id = "session-a\n"
        elif $kind == "cr" then .session_id = "session-a\r"
        elif $kind == "nul" then .session_id = "session-a\u0000"
        elif $kind == "empty" then .session_id = ""
        elif $kind == "null" then .session_id = null
        elif $kind == "number" then .session_id = 7
        else del(.session_id) end' > "$BATS_TEST_TMPDIR/invalid-stop.json"
    fi
    : > "$TRACE"
    run bash -c 'cd "$1" && bash "$2" < "$3"' _ "$PROJECT" "$STOP" "$BATS_TEST_TMPDIR/invalid-stop.json"
    [ "$status" -eq 0 ] || { echo "$kind: $output"; return 1; }
    grep -qx typecheck "$TRACE" || { echo "$kind skipped typecheck"; return 1; }
    grep -qx test "$TRACE" || { echo "$kind skipped tests"; return 1; }
    cmp -s "$baseline" "$before" || { echo "$kind consumed another session baseline"; return 1; }
  done
  : > "$TRACE"
  run settle session-a
  [ "$status" -eq 0 ]
  [ ! -s "$TRACE" ]
}

@test "an invalid Pi identity is conservative even in a clean Pi-only checkout" {
  rm "$PROJECT/.codex/hooks.json"
  git -C "$PROJECT" add app.ts
  git -C "$PROJECT" commit -qm 'pre-existing edit'
  payload session-a | jq '.session_id = ""' > "$BATS_TEST_TMPDIR/invalid-stop.json"
  run bash -c 'cd "$1" && bash "$2" < "$3"' _ "$PROJECT" "$STOP" "$BATS_TEST_TMPDIR/invalid-stop.json"
  [ "$status" -eq 0 ]
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "the legacy-compatible untrusted turn marker cannot reuse a carry" {
  publish session-a
  run settle session-a
  [ "$status" -eq 0 ]
  [ ! -s "$TRACE" ]
  payload session-a | jq '.turn_id = "trellis-baseline-untrusted:turn-1"' > "$BATS_TEST_TMPDIR/legacy-stop.json"
  run bash -c 'cd "$1" && bash "$2" < "$3"' _ "$PROJECT" "$STOP" "$BATS_TEST_TMPDIR/legacy-stop.json"
  [ "$status" -eq 0 ]
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "an untrusted Pi-only turn that committed still runs checks" {
  rm "$PROJECT/.codex/hooks.json"
  git -C "$PROJECT" add app.ts
  git -C "$PROJECT" commit -qm 'pre-existing edit'
  publish session-a
  printf '// edit committed in this turn\n' >> "$PROJECT/app.ts"
  git -C "$PROJECT" add app.ts
  git -C "$PROJECT" commit -qm 'turn edit'
  export TRELLIS_PI_BASELINE_UNTRUSTED=1
  run settle session-a
  [ "$status" -eq 0 ]
  grep -qx typecheck "$TRACE"
  grep -qx test "$TRACE"
}

@test "Pi dispatcher accepts only a proven successful native prompt result" {
  local runtime="$PROJECT/.trellis/runtime" target digest dir event result
  mkdir -p "$runtime/core-rules/native" "$runtime/core-rules/codex/hooks/lib" "$BATS_TEST_TMPDIR/event"
  chmod 700 "$BATS_TEST_TMPDIR/event"
  cp "$ROOT/core-rules/codex/hooks/lib/deps.sh" "$ROOT/core-rules/codex/hooks/lib/deps-heavy.sh" "$runtime/core-rules/codex/hooks/lib/"
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) skip 'no native asset for this host' ;;
  esac
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$TRACE"' 'cat > "$HOME/native-input"' \
    'if [ "$3" = agent_before_settle ] && jq -e '\''has("allow_turn_baseline")'\'' "$HOME/native-input" >/dev/null; then exit 2; fi' \
    'cat "$HOME/native-response"' > "$BATS_TEST_TMPDIR/companion"
  digest="$(shasum -a 256 "$BATS_TEST_TMPDIR/companion" | awk '{print $1}')"
  jq -n --arg t "$target" --arg d "$digest" '{version:"9.9.9",assets:{($t):{sha256:$d}}}' > "$runtime/core-rules/native/artifacts.json"
  dir="$TRELLIS_HOME/bin/native/9.9.9/$target/$digest"
  mkdir -p "$dir"
  chmod 700 "$TRELLIS_HOME/bin" "$TRELLIS_HOME/bin/native" "$TRELLIS_HOME/bin/native/9.9.9" "$TRELLIS_HOME/bin/native/9.9.9/$target" "$dir"
  cp "$BATS_TEST_TMPDIR/companion" "$dir/trellis-hooks"
  chmod 500 "$dir/trellis-hooks"
  event="$BATS_TEST_TMPDIR/event/event.json"
  jq -nc --arg cwd "$PROJECT" '{schema_version:1,harness:"pi",phase:"lifecycle",native_event:"before_agent_start",cwd:$cwd,session_id:"s"}' > "$event"
  chmod 600 "$event"
  jq -nc '{schema_version:1,harness:"pi",phase:"before_agent_start",boundary:null,batch:{decision:"allow",members:[{member:"turn-baseline",result:{status:"allow",exit_code:0,context:"",reason:"",error_class:null}}]}}' > "$HOME/native-response"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$event"
  [ "$status" -eq 0 ]
  result="${lines[0]}"
  jq -e '.decision == "allow" and .capability_status == "enforced"' <<< "$result" >/dev/null
  jq -e --arg cwd "$PROJECT" '.phase == "before_agent_start" and .session_id == "s" and .cwd == $cwd' "$HOME/native-input" >/dev/null
  jq '.session_id = "s\n"' "$event" > "$BATS_TEST_TMPDIR/event/bad.json"
  chmod 600 "$BATS_TEST_TMPDIR/event/bad.json"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$BATS_TEST_TMPDIR/event/bad.json"
  [ "$status" -ne 0 ]
  result="${lines[0]}"
  jq -e '.decision == "deny" and (.reason | contains("invalid Pi prompt session identity"))' <<< "$result" >/dev/null
  [ "$(wc -l < "$TRACE" | tr -d ' ')" -eq 1 ]
  jq '.batch.members[0].result.status = "advice"' "$HOME/native-response" > "$HOME/bad-response"
  mv "$HOME/bad-response" "$HOME/native-response"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$event"
  [ "$status" -ne 0 ]
  result="${lines[0]}"
  jq -e '.decision == "deny" and .capability_status == "unknown"' <<< "$result" >/dev/null

  # A verified old companion accepts only the original completion envelope.
  # The extension-only false flag becomes a restrictive turn-id prefix.
  jq -nc '{schema_version:1,harness:"pi",phase:"agent_before_settle",boundary:{},batch:{decision:"allow",members:
    (["spec-gate","decision-receipt","stop-verify","code-review-subagent","ui-verify","required-post-action","stamp-turn"]
      | map({member:.,result:{status:"no_op",exit_code:0,context:"",reason:"",error_class:null}}))}}' > "$HOME/native-response"
  jq -nc --arg cwd "$PROJECT" '{schema_version:1,harness:"pi",phase:"agent_before_settle",cwd:$cwd,session_id:"s",turn_id:"turn-1",generation:1,can_continue:false,last_assistant_message:"done",stop_hook_active:false,allow_turn_baseline:false}' > "$event"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$event"
  [ "$status" -eq 0 ]
  result="${lines[0]}"
  jq -e '.decision == "allow"' <<< "$result" >/dev/null
  jq -e '(has("allow_turn_baseline") | not) and .turn_id == "trellis-baseline-untrusted:turn-1"' "$HOME/native-input" >/dev/null
  jq '.allow_turn_baseline = true' "$event" > "$BATS_TEST_TMPDIR/event/true.json"
  chmod 600 "$BATS_TEST_TMPDIR/event/true.json"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$BATS_TEST_TMPDIR/event/true.json"
  [ "$status" -eq 0 ]
  jq -e '(has("allow_turn_baseline") | not) and .turn_id == "turn-1"' "$HOME/native-input" >/dev/null
  # T64a's mandatory native proof still refuses unverifiable or absent assets.
  chmod 700 "$dir/trellis-hooks"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$event"
  [ "$status" -ne 0 ]
  result="${lines[0]}"
  jq -e '.decision == "deny" and .capability_status == "unknown"' <<< "$result" >/dev/null
  rm "$dir/trellis-hooks"
  run bash -c 'cd "$1" && bash "$2" --event-file "$3"' _ "$PROJECT" "$ROOT/core-rules/pi/hooks/dispatch.sh" "$event"
  [ "$status" -ne 0 ]
  result="${lines[0]}"
  jq -e '.decision == "deny" and .capability_status == "unknown"' <<< "$result" >/dev/null
}

@test "open todos still block an unchanged Pi turn before any checks" {
  printf '[{"status":"pending","content":"finish task"}]\n' > "$PROJECT/.codex/todos.json"
  publish session-a
  run settle session-a
  [ "$status" -eq 0 ]
  [[ "$output" == *'TodoWrite'* ]] || false
  [ ! -s "$TRACE" ]
}
