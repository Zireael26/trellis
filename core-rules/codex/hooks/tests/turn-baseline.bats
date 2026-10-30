#!/usr/bin/env bats
# C01, Codex twin: the Stop receipt demand fires only when THIS turn mutated
# the tree, judged against the UserPromptSubmit baseline. Unknown → receipt.
#
# Deployed layout as in helpers.setup_deployed_hook: the real turn-baseline.sh,
# stop-verify.sh and libs run from <tmp>/deploy/.codex/hooks; the project is a
# separate git repo, so the deployment never enters the changed-file set.
# Codex reads a Stop block from stdout on exit 0. The project is "armed" (its
# .codex/hooks.json registers turn-baseline.sh, git-excluded), and baselines
# live under a private TRELLIS_HOME, never ~/.trellis.

load helpers

setup() {
  setup_deployed_hook
  BASELINE_HOOK="${HOOK%/*}/turn-baseline.sh"
  cp "$BATS_TEST_DIRNAME/../turn-baseline.sh" "$BASELINE_HOOK"
  chmod +x "$BASELINE_HOOK"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p .codex
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' \
      > .codex/hooks.json
    printf '/.codex/hooks.json\n' >> .git/info/exclude
    git config user.email "ci-bats@trellis.test"
    git config user.name "Trellis CI"
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

prompt_payload() {
  jq -nc --arg sid "${1:-sess-1}" --arg cwd "$PROJECT_DIR" \
    '{session_id: $sid, turn_id: "turn-1", transcript_path: null, cwd: $cwd,
      hook_event_name: "UserPromptSubmit", model: "codex-test", prompt: "go"}'
}

stop_payload() {
  jq -nc --arg sid "${1:-sess-1}" --arg tx "$TX" --arg cwd "$PROJECT_DIR" \
    '{session_id: $sid, turn_id: "turn-1", transcript_path: $tx, cwd: $cwd,
      hook_event_name: "Stop", model: "codex-test", stop_hook_active: false,
      last_assistant_message: "It prints one line."}'
}

turn_entry() {
  run bash "$BASELINE_HOOK" <<<"$(prompt_payload "$@")"
  [ "$status" -eq 0 ] || { echo "turn-baseline exited $status: $output"; return 1; }
  [ -z "$output" ] || { echo "turn-baseline printed: $output"; return 1; }
}

turn_stop() {
  run bash "$HOOK" <<<"$(stop_payload "$@")"
}

assert_receipt_demanded() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null ||
    { echo "not a receipts block: $output"; return 1; }
}

assert_no_receipt_demand() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" != *'"decision"'* ]] || { echo "unexpected block: $output"; return 1; }
}

baseline_file() {
  local dir files
  dir="$TRELLIS_HOME/state/turn-baseline"
  files="$(find "$dir" -type f -name 'codex.*' 2>/dev/null)"
  [ "$(printf '%s\n' "$files" | awk 'NF' | wc -l | tr -d ' ')" = "1" ] ||
    { echo "expected one baseline file under $dir, got: $files"; return 1; }
  printf '%s' "$files"
}

@test "codex: no-op turn on a dirty tree: no receipt demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
}

@test "codex: doc-only change and Claude hook state do not require code receipt" {
  ( cd "$PROJECT_DIR" && git show HEAD:app.js > app.js && rm scratch.js )
  turn_entry
  mkdir -p "$PROJECT_DIR/.claude/.reread-state" "$PROJECT_DIR/.pi/.reread-state" "$PROJECT_DIR/.codex/.reread-state"
  for path in .claude/.fail-counter .claude/.reread-state/turn \
    .claude/.review-done-123 .claude/session-surgical \
    .claude/spec-gate-audit.log .pi/.reread-state/turn \
    .codex/.fail-counter .codex/.reread-state/turn .codex/.review-done-123; do
    printf 'state\n' > "$PROJECT_DIR/$path"
  done
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_no_receipt_demand
}

@test "codex: a turn that edits a file: receipt demanded" {
  turn_entry
  printf 'edited this turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
}

@test "codex: a Bash mutation that read-state never saw: receipt demanded" {
  turn_entry
  bash -c 'cd "$1" && rm lib.js' _ "$PROJECT_DIR"
  [ ! -e "$PROJECT_DIR/.codex/.reread-state" ]
  turn_stop
  assert_receipt_demanded
}

@test "codex: an edit to a pre-existing untracked file: receipt demanded" {
  turn_entry
  printf 'more\n' >> "$PROJECT_DIR/scratch.js"
  turn_stop
  assert_receipt_demanded
}

@test "codex: staged-then-reverted (worktree bytes restored, index changed): receipt demanded" {
  local before
  before="$(cat "$PROJECT_DIR/app.js")"
  turn_entry
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'staged change\n' > app.js
    git add app.js
    printf '%s\n' "$before" > app.js
  )
  turn_stop
  assert_receipt_demanded
}

@test "codex: commit-and-clean turn: receipt demanded although the tree is clean" {
  turn_entry
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m work )
  [ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]
  turn_stop
  assert_receipt_demanded
}

@test "codex: a prompt submitted mid-turn cannot launder an earlier edit" {
  turn_entry
  printf 'edited before the second prompt\n' >> "$PROJECT_DIR/app.js"
  turn_entry
  turn_stop
  assert_receipt_demanded
}

@test "codex: missing baseline (the prompt hook was skipped): receipt demanded" {
  turn_stop
  assert_receipt_demanded
}

@test "codex: corrupted baseline: receipt demanded" {
  local file
  turn_entry
  file="$(baseline_file)"
  printf 'garbage\n' > "$file"
  turn_stop
  assert_receipt_demanded
}

@test "codex: malformed prompt JSON voids the baseline: receipt demanded" {
  turn_entry
  run bash "$BASELINE_HOOK" <<<'{"session_id": "sess-1", "prompt": '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  turn_stop
  assert_receipt_demanded
}

@test "codex: missing baseline, code committed, clean tree: receipt demanded" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  printf 'edited\n' >> "$PROJECT_DIR/app.js"
  ( cd "$PROJECT_DIR" && git add app.js && git commit -q -m work )
  [ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]
  turn_stop
  assert_receipt_demanded
}

@test "codex: unarmed project: a clean tree with no baseline passes as before" {
  rm -f "$PROJECT_DIR/.codex/hooks.json"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  turn_stop
  assert_no_receipt_demand
}

@test "codex: a symlink retargeted from t-newline to t-newline-newline: receipt demanded" {
  ln -s $'t\n' "$PROJECT_DIR/link"
  turn_entry
  rm "$PROJECT_DIR/link"
  ln -s $'t\n\n' "$PROJECT_DIR/link"
  turn_stop
  assert_receipt_demanded
}

@test "codex: a valid-looking baseline whose nonce the hook never logged: receipt demanded" {
  local file line
  turn_entry
  file="$(baseline_file)"
  line="$(cat "$file")"
  printf '%s\n' "$line" | awk '{ $3 = "00000000000000000000000000000000"; print }' > "$file"
  turn_stop
  assert_receipt_demanded
}

@test "codex: the baseline lives in TRELLIS_HOME state at mode 0600" {
  local file
  turn_entry
  file="$(baseline_file)"
  [ "$(ls -l "$file" | cut -c1-10)" = "-rw-------" ]
  [ ! -e "$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-path trellis-turn-baseline)" ]
}

@test "codex: carry: a promptless turn after a clean Stop, with no change: no demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  turn_stop
  assert_no_receipt_demand
}

@test "codex: carry: a promptless turn after a Stop, with code then edited: demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  printf 'edited by a notification turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
}

@test "codex: carry: the first-ever turn, with no carry and no prompt baseline: demand" {
  [ ! -d "$TRELLIS_HOME/state/turn-baseline" ]
  turn_stop
  assert_receipt_demanded
}

@test "codex: carry: a re-Stop after a blocked Stop, with no change, still demands" {
  turn_entry
  printf 'edited this turn\n' >> "$PROJECT_DIR/app.js"
  turn_stop
  assert_receipt_demanded
  turn_stop
  assert_receipt_demanded
}

@test "codex: unarmed project: a dirty tree with no baseline demands, as on base" {
  rm -f "$PROJECT_DIR/.codex/hooks.json"
  turn_stop
  assert_receipt_demanded
}

@test "codex: carry: a prompt baseline takes precedence over the carry" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
  printf 'edited between turns, outside any turn\n' >> "$PROJECT_DIR/app.js"
  turn_entry
  turn_stop
  assert_no_receipt_demand
}

@test "codex: open todos still block an unchanged turn" {
  printf '[{"content":"finish it","status":"pending"}]\n' > "$BATS_TEST_TMPDIR/todos.json"
  export TODOS_FILE="$BATS_TEST_TMPDIR/todos.json"
  turn_entry
  turn_stop
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("TodoWrite:"))' >/dev/null
}

@test "codex: recording the baseline never dirties the tree it measures" {
  local before after
  before="$(git -C "$PROJECT_DIR" status --porcelain=v2 --untracked-files=all)"
  turn_entry
  after="$(git -C "$PROJECT_DIR" status --porcelain=v2 --untracked-files=all)"
  [ "$before" = "$after" ]
  baseline_file >/dev/null
}

@test "codex: both Codex manifests register turn-baseline once on UserPromptSubmit" {
  local manifest
  for manifest in "$BATS_TEST_DIRNAME/../../hooks.json" "$BATS_TEST_DIRNAME/../../../templates/codex-hooks.local.json"; do
    jq -e '
      [.hooks.UserPromptSubmit[]?.hooks[]?.command | select(test("/turn-baseline\\.sh\"?$"))]
      | length == 1
    ' "$manifest" >/dev/null || { echo "not wired once: $manifest"; return 1; }
    jq -e '[.. | strings | select(contains("turn-baseline.sh"))] | length == 1' \
      "$manifest" >/dev/null || { echo "wired elsewhere too: $manifest"; return 1; }
  done
}

# --- bug #6: non-code dirty status must not run the heavy checks -------------
# A fake TypeScript toolchain (npx for tsc, npm for the test script) logs every
# call to FULL_LOG. A non-empty log means typecheck, lint or the suite ran.
suite_project() {
  local fake_bin="$BATS_TEST_TMPDIR/suite-bin" tool
  FULL_LOG="$BATS_TEST_TMPDIR/full-suite.log"
  export FULL_LOG
  : > "$FULL_LOG"
  mkdir -p "$fake_bin"
  for tool in npx npm; do
    cat > "$fake_bin/$tool" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$FULL_LOG"
exit 0
EOF
    chmod +x "$fake_bin/$tool"
  done
  export PATH="$fake_bin:$PATH"
  (
    cd "$PROJECT_DIR" || exit 1
    printf '{"scripts":{"test":"fake-test"}}\n' > package.json
    printf '{}\n' > tsconfig.json
    git add package.json tsconfig.json
    git commit -q -m "toolchain manifests"
  )
}

# Drop the setup's pre-existing code edits so only the turn's dirt is in play.
clean_code_dirt() {
  ( cd "$PROJECT_DIR" && git show HEAD:app.js > app.js && rm -f scratch.js )
}

assert_no_heavy_checks() {
  [ ! -s "$FULL_LOG" ] || { echo "heavy checks ran:"; cat "$FULL_LOG"; return 1; }
}

assert_heavy_checks_ran() {
  [ -s "$FULL_LOG" ] || { echo "heavy checks did not run"; return 1; }
}

# The deployed Codex hook warns on stderr when no verification-receipt lib sits
# beside it; `run` merges stderr, so the block JSON is the last output line.
assert_receipt_block_last_line() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  printf '%s\n' "$output" | tail -n 1 | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null ||
    { echo "not a receipts block: $output"; return 1; }
}

@test "codex: bug #6: a doc-only edit on a dirty tree runs no typecheck, lint or test" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "codex: bug #6: a no-op turn with doc-only dirt runs no typecheck, lint or test" {
  suite_project
  clean_code_dirt
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_entry
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "codex: bug #6: a code edit still runs the checks and demands a receipt" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'x\n' >> "$PROJECT_DIR/lib.js"
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_block_last_line
}

@test "codex: bug #6: a committed code change plus doc dirt still runs the checks" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'x\n' >> "$PROJECT_DIR/lib.js"
  ( cd "$PROJECT_DIR" && git add lib.js && git commit -q -m "code change" )
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_block_last_line
}

@test "codex: bug #6: pre-existing dirty code does not rerun checks on a known no-op turn" {
  suite_project
  turn_entry
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "codex: bug #6: committed code with a clean tree still runs checks" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'new code\n' >> "$PROJECT_DIR/lib.js"
  ( cd "$PROJECT_DIR" && git add lib.js && git commit -q -m "code committed this turn" )
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_block_last_line
}

@test "codex: bug #6: a committed code-to-doc rename plus doc dirt still runs checks" {
  suite_project
  clean_code_dirt
  turn_entry
  ( cd "$PROJECT_DIR" && git mv lib.js guide.md && git commit -q -m "rename code to doc" )
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_block_last_line
}

@test "codex: bug #6: a new doc in a new directory runs no typecheck, lint or test" {
  suite_project
  clean_code_dirt
  turn_entry
  mkdir -p "$PROJECT_DIR/docs/new"
  printf 'notes\n' > "$PROJECT_DIR/docs/new/guide.md"
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "codex: bug #6: a staged code-to-doc rename still runs the checks" {
  suite_project
  clean_code_dirt
  turn_entry
  ( cd "$PROJECT_DIR" && git mv lib.js guide.md )
  turn_stop
  assert_heavy_checks_ran
}

@test "codex: bug #6: an unknown baseline keeps the checks on doc-only dirt" {
  suite_project
  clean_code_dirt
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
}
