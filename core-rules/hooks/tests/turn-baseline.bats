#!/usr/bin/env bats
# C01: the Stop receipt demand fires only when THIS turn mutated the tree.
#
# turn-baseline.sh (UserPromptSubmit) records a fingerprint of HEAD + index +
# tracked and untracked content; stop-verify.sh consumes it at Stop. Unchanged
# → no receipt demand. Changed, missing, corrupt or uncomputable → the receipt
# is required (unknown never reads as "no edits").
#
# Each test plays a whole turn: seed a repo with a pre-existing dirty tracked
# file and a pre-existing untracked file, submit a prompt, mutate (or not), then
# Stop with a receipt-less transcript. Transcripts live under BATS_TEST_TMPDIR,
# outside the project, so they never enter the changed-file set.
#
# The project is "armed" (its rendered settings register turn-baseline.sh, git-
# excluded as in an attached project), so an unknown baseline counts as changed
# on every path. Baselines live under a private TRELLIS_HOME, never ~/.trellis.

load helpers

BASELINE_HOOK="$HOOKS_DIR/turn-baseline.sh"
STOP_HOOK="$HOOKS_DIR/stop-verify.sh"

setup() {
  setup_project_dir
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p .claude
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' \
      > .claude/settings.local.json
    printf '/.claude/settings.local.json\n' >> .git/info/exclude
    printf 'one\n' > app.js
    printf 'two\n' > lib.js
    git add app.js lib.js
    git commit -q -m seed
    printf 'pre-existing edit\n' >> app.js
    printf 'pre-existing scratch\n' > scratch.js
  )
  TX="$BATS_TEST_TMPDIR/transcript.jsonl"
  cat > "$TX" <<'EOF'
{"type":"user","message":{"role":"user","content":"what does app.js do?"}}
{"type":"assistant","message":{"role":"assistant","content":"It prints one line."}}
EOF
}

teardown() {
  teardown_project_dir
}

prompt_payload() {
  jq -nc --arg sid "${1:-sess-1}" --arg cwd "$PROJECT_DIR" \
    '{session_id: $sid, transcript_path: null, cwd: $cwd, permission_mode: "default",
      hook_event_name: "UserPromptSubmit", prompt: "go"}'
}

stop_payload() {
  jq -nc --arg sid "${1:-sess-1}" --arg tx "$TX" \
    '{session_id: $sid, transcript_path: $tx, hook_event_name: "Stop", stop_hook_active: false}'
}

# Submit a prompt. The hook must stay silent (stdout here becomes prompt
# context) and must never block the prompt.
turn_entry() {
  run bash "$BASELINE_HOOK" <<<"$(prompt_payload "$@")"
  [ "$status" -eq 0 ] || { echo "turn-baseline exited $status: $output"; return 1; }
  [ -z "$output" ] || { echo "turn-baseline printed: $output"; return 1; }
}

turn_stop() {
  run bash "$STOP_HOOK" <<<"$(stop_payload "$@")"
}

assert_receipt_demanded() {
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null ||
    { echo "not a receipts block: $output"; return 1; }
}

assert_no_receipt_demand() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" != *'"decision"'* ]] || { echo "unexpected block: $output"; return 1; }
}

# The single baseline file the prompt wrote (path naming stays the hook's).
baseline_file() {
  local dir files
  dir="$TRELLIS_HOME/state/turn-baseline"
  files="$(find "$dir" -type f -name 'claude.*' 2>/dev/null)"
  [ "$(printf '%s\n' "$files" | awk 'NF' | wc -l | tr -d ' ')" = "1" ] ||
    { echo "expected one baseline file under $dir, got: $files"; return 1; }
  printf '%s' "$files"
}

# --- the narrowed trigger ------------------------------------------------------

@test "no-op turn on a dirty tree: no receipt demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
}

@test "a turn that edits a file: receipt demanded" {
  turn_entry
  printf 'edited this turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
}

@test "a Bash mutation that read-state never saw: receipt demanded" {
  turn_entry
  bash -c 'cd "$1" && rm lib.js' _ "$PROJECT_DIR"
  [ ! -e "$PROJECT_DIR/.claude/.reread-state" ]
  turn_stop
  assert_receipt_demanded
}

@test "an edit to a pre-existing untracked file: receipt demanded" {
  turn_entry
  printf 'more\n' >> "$PROJECT_DIR/scratch.js"
  turn_stop
  assert_receipt_demanded
}

@test "staged-then-reverted (worktree bytes restored, index changed): receipt demanded" {
  local before
  before="$(cat "$PROJECT_DIR/app.js")"
  turn_entry
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'staged change\n' > app.js
    git add app.js
    printf '%s\n' "$before" > app.js
  )
  [ "$(cat "$PROJECT_DIR/app.js")" = "$before" ]
  turn_stop
  assert_receipt_demanded
}

@test "commit-and-clean turn: receipt demanded although the tree is clean" {
  turn_entry
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m work )
  [ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]
  turn_stop
  assert_receipt_demanded
}

@test "commit-and-clean of docs only keeps the doc-only exemption" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  turn_entry
  ( cd "$PROJECT_DIR" && printf '# notes\n' > NOTES.md && git add NOTES.md && git commit -q -m docs )
  turn_stop
  assert_no_receipt_demand
}

@test "a prompt submitted mid-turn cannot launder an earlier edit" {
  turn_entry
  printf 'edited before the second prompt\n' >> "$PROJECT_DIR/app.js"
  turn_entry
  turn_stop
  assert_receipt_demanded
}

# --- unknown means a receipt ---------------------------------------------------

@test "missing baseline (the prompt hook was skipped): receipt demanded" {
  turn_stop
  assert_receipt_demanded
}

@test "corrupted baseline: receipt demanded" {
  local file content
  for content in '' 'garbage' 'trellis-turn-baseline v2 unknown' \
    'trellis-turn-baseline v1 unborn 0000000000000000000000000000000000000000000000000000000000000000' \
    'trellis-turn-baseline v2 00000000000000000000000000000000 unborn not-a-hash'; do
    turn_entry || return 1
    file="$(baseline_file)" || return 1
    printf '%s\n' "$content" > "$file"
    turn_stop
    assert_receipt_demanded || { echo "baseline content: '$content'"; return 1; }
  done
}

@test "a valid line beside a corrupt one still reads as unknown" {
  local file
  turn_entry
  file="$(baseline_file)"
  printf 'garbage\n' >> "$file"
  turn_stop
  assert_receipt_demanded
}

@test "malformed prompt JSON (serialization failure) leaves no baseline: receipt demanded" {
  run bash "$BASELINE_HOOK" <<<'{"session_id": "sess-1", "prompt": '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  turn_stop
  assert_receipt_demanded
}

@test "malformed prompt JSON also voids an unconsumed earlier baseline" {
  turn_entry
  run bash "$BASELINE_HOOK" <<<'not json'
  [ "$status" -eq 0 ]
  turn_stop
  assert_receipt_demanded
}

@test "a Stop envelope without session_id: receipt demanded" {
  turn_entry
  run bash "$STOP_HOOK" <<<"$(jq -nc --arg tx "$TX" '{transcript_path: $tx, stop_hook_active: false}')"
  assert_receipt_demanded
}

@test "a baseline from another session: receipt demanded" {
  turn_entry other-session
  turn_stop sess-1
  assert_receipt_demanded
}

@test "carry: a promptless turn after a clean Stop, with no change: no demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  turn_stop
  assert_no_receipt_demand
}

@test "carry: a promptless turn after a Stop, with code then edited: demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  printf 'edited by a notification turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
}

@test "carry: the first-ever turn, with no carry and no prompt baseline: demand" {
  [ ! -d "$TRELLIS_HOME/state/turn-baseline" ]
  turn_stop
  assert_receipt_demanded
}

@test "carry: a prompt baseline takes precedence over the carry" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  printf 'edited between turns, outside any turn\n' >> "$PROJECT_DIR/app.js"
  turn_entry
  turn_stop
  assert_no_receipt_demand
}

@test "carry: a re-Stop after a blocked Stop, with no change, still demands" {
  turn_entry
  printf 'edited this turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
  turn_stop
  assert_receipt_demanded
}

@test "carry: the stop_hook_active re-fire still skips, and the next promptless Stop demands" {
  turn_entry
  printf 'edited this turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
  run bash "$STOP_HOOK" <<<"$(jq -nc --arg tx "$TX" '{session_id: "sess-1", transcript_path: $tx, stop_hook_active: true}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  turn_stop
  assert_receipt_demanded
}

@test "carry: once a receipt lets Stop pass, the next promptless no-change turn passes" {
  turn_entry
  printf 'edited this turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
  cat >> "$TX" <<'EOT'
{"type":"assistant","message":{"role":"assistant","content":"Done. <!-- dod-receipt cmd=\"node app.js\" exit=0 diff=\"+1/-0 (1 files)\" --> <!-- follow-ups: none -->"}}
EOT
  turn_stop
  assert_no_receipt_demand
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"(background task finished)"}}' >> "$TX"
  turn_stop
  assert_no_receipt_demand
}

@test "carry: a carry line whose nonce the hook never logged: demand" {
  local file
  turn_entry
  turn_stop
  file="$(baseline_file)"
  grep -q '^trellis-turn-carry v2 ' "$file"
  awk '{ $3 = "00000000000000000000000000000000"; print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  turn_stop
  assert_receipt_demanded
}

@test "carry: an unarmed project writes no carry state" {
  rm -f "$PROJECT_DIR/.claude/settings.local.json"
  turn_stop
  [ ! -e "$TRELLIS_HOME/state/turn-baseline" ]
}

@test "an uncoverable path (nested repo) makes the turn unknown: receipt demanded" {
  mkdir -p "$PROJECT_DIR/vendor/dep"
  git -C "$PROJECT_DIR/vendor/dep" init -q
  turn_entry
  turn_stop
  assert_receipt_demanded
}

@test "missing baseline, code committed, clean tree: receipt demanded" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  printf 'edited\n' >> "$PROJECT_DIR/app.js"
  ( cd "$PROJECT_DIR" && git add app.js && git commit -q -m work )
  [ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]
  turn_stop
  assert_receipt_demanded
}

@test "corrupt baseline, code committed, clean tree: receipt demanded" {
  local file
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  turn_entry
  file="$(baseline_file)"
  printf 'garbage\n' > "$file"
  printf 'edited\n' >> "$PROJECT_DIR/app.js"
  ( cd "$PROJECT_DIR" && git add app.js && git commit -q -m work )
  turn_stop
  assert_receipt_demanded
}

@test "unarmed project: a dirty tree with no baseline demands, as on base" {
  rm -f "$PROJECT_DIR/.claude/settings.local.json"
  turn_stop
  assert_receipt_demanded
}

@test "unarmed project: commit-and-clean with no baseline passes, as on base (documented residual)" {
  rm -f "$PROJECT_DIR/.claude/settings.local.json"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  printf 'edited\n' >> "$PROJECT_DIR/app.js"
  ( cd "$PROJECT_DIR" && git add app.js && git commit -q -m work )
  [ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]
  turn_stop
  assert_no_receipt_demand
}

@test "unarmed project (prompt hook not registered): a clean tree with no baseline passes as before" {
  rm -f "$PROJECT_DIR/.claude/settings.local.json"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  turn_stop
  assert_no_receipt_demand
}

@test "a symlink retargeted from t-newline to t-newline-newline: receipt demanded" {
  ln -s $'t\n' "$PROJECT_DIR/link"
  turn_entry
  rm "$PROJECT_DIR/link"
  ln -s $'t\n\n' "$PROJECT_DIR/link"
  turn_stop
  assert_receipt_demanded
}

@test "a valid-looking baseline whose nonce the hook never logged: receipt demanded" {
  local file line
  turn_entry
  file="$(baseline_file)"
  line="$(cat "$file")"
  printf '%s\n' "$line" | awk '{ $3 = "00000000000000000000000000000000"; print }' > "$file"
  [ "$(awk '{ print $4, $5 }' "$file")" = "$(printf '%s\n' "$line" | awk '{ print $4, $5 }')" ]
  turn_stop
  assert_receipt_demanded
}

@test "the baseline lives in TRELLIS_HOME state at mode 0600, not in the repo's git dir" {
  local file
  turn_entry
  file="$(baseline_file)"
  [ "$(ls -l "$file" | cut -c1-10)" = "-rw-------" ]
  [ ! -e "$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-path trellis-turn-baseline)" ]
}

# --- what stays unconditional ----------------------------------------------------

@test "open todos still block an unchanged turn" {
  printf '[{"content":"finish it","status":"pending"}]\n' > "$BATS_TEST_TMPDIR/todos.json"
  export TODOS_FILE="$BATS_TEST_TMPDIR/todos.json"
  turn_entry
  turn_stop
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.reason | startswith("TodoWrite:")' >/dev/null
}

@test "consecutive turns: a no-op turn passes and the next editing turn still demands" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  turn_entry
  printf 'x\n' >> "$PROJECT_DIR/lib.js"
  turn_stop
  assert_receipt_demanded
}

# --- the baseline itself -------------------------------------------------------

@test "recording the baseline never dirties the tree it measures" {
  local before after
  before="$(git -C "$PROJECT_DIR" status --porcelain=v2 --untracked-files=all)"
  turn_entry
  after="$(git -C "$PROJECT_DIR" status --porcelain=v2 --untracked-files=all)"
  [ "$before" = "$after" ]
  baseline_file >/dev/null
}

@test "both Claude templates register turn-baseline once on UserPromptSubmit" {
  local template
  for template in claude-settings.local.json claude-settings.json; do
    jq -e '
      [.hooks.UserPromptSubmit[]?.hooks[]?.command | select(endswith("/turn-baseline.sh\"") or endswith("/turn-baseline.sh"))]
      | length == 1
    ' "$HOOKS_DIR/../templates/$template" >/dev/null || { echo "not wired once: $template"; return 1; }
    jq -e '[.. | strings | select(contains("turn-baseline.sh"))] | length == 1' \
      "$HOOKS_DIR/../templates/$template" >/dev/null || { echo "wired elsewhere too: $template"; return 1; }
  done
}
