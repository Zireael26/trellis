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
load native-arming-fixture
load t28-submodule-fixture
bats_require_minimum_version 1.5.0

BASELINE_HOOK="$HOOKS_DIR/turn-baseline.sh"
STOP_HOOK="$HOOKS_DIR/stop-verify.sh"

setup() {
  # macOS mktemp -d without a template uses /var/folders even when TMPDIR is
  # fenced. Keep each project under the Bats sandbox and use its physical path.
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/project.XXXXXX")"
  ( cd "$PROJECT_DIR" && git init -q && git config user.email "ci-bats@trellis.test" && git config user.name "Trellis CI" && git commit --allow-empty -q -m init )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
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

# --- baseline hash portability ------------------------------------------------

# Allowlist only fixture delegates: never inherit a host shasum, sha256sum or
# env through PATH. perl hashes the fingerprint (run through /usr/bin/env);
# only the state location still hashes with shasum or sha256sum.
baseline_hash_path() {
  local bin="$BATS_TEST_TMPDIR/baseline-hash-bin" tool
  mkdir -p "$bin"
  for tool in git awk cut cat perl; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  printf '%s' "$bin"
}

run_baseline_helper() {
  local bin="$1"
  shift
  run env PATH="$bin" "$BASH" -c 'source "$1"; shift; "$@"' _ \
    "${BASELINE_HOOK%/*}/lib/deps.sh" "$@"
}

# The fingerprint under the suite's own PATH, which a restricted one must match.
full_fingerprint() {
  ( source "${BASELINE_HOOK%/*}/lib/deps.sh" && _se_tree_fingerprint "$PROJECT_DIR" )
}

# Without a usable state hash the turn state location is unknown, so no
# baseline can be read and the turn counts as unknown. The fingerprint uses
# neither tool and must still be the whole one.
assert_baseline_state_unknown() {
  local bin="$1" expected
  expected="$(full_fingerprint)"
  [[ "$expected" =~ ^[0-9a-f]{40,64}\ [0-9a-f]{64}$ ]]
  run_baseline_helper "$bin" _se_turn_state_dir "$PROJECT_DIR"
  [ "$status" -ne 0 ] && [ -z "$output" ] ||
    { echo "unavailable hash produced state: $status $output"; return 1; }
  run_baseline_helper "$bin" _se_tree_fingerprint "$PROJECT_DIR"
  [ "$status" -eq 0 ] && [ "$output" = "$expected" ] ||
    { echo "fingerprint without a state hash: $status $output (want $expected)"; return 1; }
}

# A fingerprint that cannot be computed is empty and fails, and an empty
# fingerprint reads unknown: never a partial hash.
assert_fingerprint_unknown() {
  local bin="$1" nonce digest
  nonce="$(printf '%032d' 0)"
  digest="$(printf '%064d' 0)"
  run --separate-stderr env PATH="$bin" "$BASH" -c 'source "$1"; _se_tree_fingerprint "$2"' _ \
    "${BASELINE_HOOK%/*}/lib/deps.sh" "$PROJECT_DIR"
  [ "$status" -ne 0 ] && [ -z "$output" ] ||
    { echo "unavailable perl produced fingerprint: $status $output"; return 1; }
  run_baseline_helper "$bin" _se_turn_baseline_state \
    "trellis-turn-baseline v2 $nonce unborn $digest" "$output" "$nonce"
  [ "$status" -eq 0 ]
  [ "$output" = unknown ]
}

@test "sha256sum-only PATH preserves turn state location and full fingerprints" {
  command -v sha256sum >/dev/null 2>&1 || skip "sha256sum is not installed"
  local bin expected before
  bin="$(baseline_hash_path)"
  ln -s "$(command -v sha256sum)" "$bin/sha256sum"
  [ ! -e "$bin/shasum" ] && [ ! -e "$bin/env" ]
  expected="$(cd "$PROJECT_DIR" && pwd -P)"
  expected="$(printf '%s' "$expected" | sha256sum)"
  expected="${expected%% *}"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
  run_baseline_helper "$bin" _se_turn_state_dir "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$TRELLIS_HOME/state/turn-baseline/${expected:0:16}" ]
  [ ! -e "$output" ]
  run_baseline_helper "$bin" _se_tree_fingerprint "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$(full_fingerprint)" ]
  [ "${output%% *}" = "$(git -C "$PROJECT_DIR" rev-parse HEAD)" ]
  [[ "${output#* }" =~ ^[0-9a-f]{64}$ ]]
  before="$output"
  run_baseline_helper "$bin" _se_tree_fingerprint "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$before" ]
  printf 'actual edit this turn\n' >> "$PROJECT_DIR/app.js"
  run_baseline_helper "$bin" _se_tree_fingerprint "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "${output#* }" =~ ^[0-9a-f]{64}$ ]]
  [ "$output" != "$before" ]
}

@test "missing baseline hash tools leave the state unknown and the fingerprint whole" {
  local bin
  bin="$(baseline_hash_path)"
  assert_baseline_state_unknown "$bin"
}

@test "failed sha256sum output is not accepted as a turn state location" {
  local bin
  bin="$(baseline_hash_path)"
  cat > "$bin/sha256sum" <<'SH'
#!/bin/sh
cat >/dev/null
printf '%064d  -\n' 0
exit 1
SH
  chmod +x "$bin/sha256sum"
  assert_baseline_state_unknown "$bin"
}

@test "existing shasum failure is not retried with sha256sum" {
  local bin
  bin="$(baseline_hash_path)"
  export HASH_FALLBACK_LOG="$BATS_TEST_TMPDIR/hash-fallback.log"
  cat > "$bin/shasum" <<'SH'
#!/bin/sh
cat >/dev/null
printf '%064d  -\n' 0
exit 1
SH
  cat > "$bin/sha256sum" <<'SH'
#!/bin/sh
printf 'fallback\n' >> "$HASH_FALLBACK_LOG"
cat >/dev/null
printf '%064d  -\n' 0
SH
  chmod +x "$bin/shasum" "$bin/sha256sum"
  assert_baseline_state_unknown "$bin"
  [ ! -e "$HASH_FALLBACK_LOG" ]
}

@test "a missing or failing fingerprint perl leaves the fingerprint unknown" {
  local bin
  bin="$(baseline_hash_path)"
  rm "$bin/perl"
  assert_fingerprint_unknown "$bin"
  cat > "$bin/perl" <<'SH'
#!/bin/sh
cat >/dev/null
printf '%064d\n' 0
exit 1
SH
  chmod +x "$bin/perl"
  assert_fingerprint_unknown "$bin"
}

# --- the narrowed trigger ------------------------------------------------------

assert_submodule_receipt_demand() {
  local harness="$1" setting="$2" hooks="$HOOKS_DIR" lib fingerprint_status changed_helper
  t28_seed_submodule "$PROJECT_DIR" "$setting"
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"
    mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  BASELINE_HOOK="$hooks/turn-baseline.sh" STOP_HOOK="$hooks/stop-verify.sh"
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  turn_entry
  t28_mutate_submodule "$PROJECT_DIR" "$setting"
  lib="$hooks/lib/deps.sh"
  run bash -c 'source "$1"; _se_tree_fingerprint "$2"' _ "$lib" "$PROJECT_DIR"
  fingerprint_status="$status"
  turn_stop
  if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || { echo "$harness/$setting: no DoD block: $output"; return 1; }; else [ "$status" -eq 0 ]; fi
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null || {
    echo "$harness/$setting: changed submodule did not demand a DoD receipt: $output"; return 1;
  }
  [ "$fingerprint_status" -ne 0 ] || { echo "$harness/$setting: fingerprint concealed a changed gitlink"; return 1; }
  # Isolate changed-file enumeration from the conservative unknown baseline:
  # otherwise its sentinel would mask a missing flag in this function.
  changed_helper="$BATS_TEST_TMPDIR/changed-files.bash"
  awk '/^_se_changed_files\(\) \{/ { found=1 } /^emit_block\(\)/ { exit } found { print }' "$STOP_HOOK" > "$changed_helper"
  run bash -c 'source "$1"; source "$2"; PROJECT_DIR="$3"; _se_changed_files' _ "$lib" "$changed_helper" "$PROJECT_DIR"
  [ "$status" -eq 0 ] && printf '%s\n' "$output" | grep -Fxq sub || { echo "$harness/$setting: changed-files omitted gitlink: $output"; return 1; }
}
@test "T28 Claude submodule ignore dirty demands a DoD receipt" { assert_submodule_receipt_demand claude dirty; }
@test "T28 Claude submodule ignore all demands a DoD receipt" { assert_submodule_receipt_demand claude all; }
@test "T28 Claude submodule ignore all HEAD move demands a DoD receipt" { assert_submodule_receipt_demand claude all-head; }
@test "T28 Claude diff ignoreSubmodules demands a DoD receipt" { assert_submodule_receipt_demand claude config; }
@test "T28 Codex submodule ignore dirty demands a DoD receipt" { assert_submodule_receipt_demand codex dirty; }
@test "T28 Codex submodule ignore all demands a DoD receipt" { assert_submodule_receipt_demand codex all; }
@test "T28 Codex submodule ignore all HEAD move demands a DoD receipt" { assert_submodule_receipt_demand codex all-head; }
@test "T28 Codex diff ignoreSubmodules demands a DoD receipt" { assert_submodule_receipt_demand codex config; }

assert_unarmed_docs_only_ignores_untracked_mode_bits() {
  local harness="$1" hooks="$HOOKS_DIR" path visible
  git -C "$PROJECT_DIR" reset --hard -q HEAD
  rm -f "$PROJECT_DIR/scratch.js" "$PROJECT_DIR/.claude/settings.local.json"
  printf '# before\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md && git -C "$PROJECT_DIR" commit -qm readme
  git -C "$PROJECT_DIR" config core.fileMode false
  while IFS= read -r -d '' path; do chmod 755 "$PROJECT_DIR/$path"; done < <(git -C "$PROJECT_DIR" ls-files -z)
  printf '# after\n' > "$PROJECT_DIR/README.md"
  visible="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)"
  [ "$visible" = ' M README.md' ] || { echo "fixture is not docs-only under Git config: $visible"; return 1; }
  if [ "$harness" = codex ]; then hooks="$CODEX_HOOKS_DIR"; fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  run bash "$hooks/stop-verify.sh" <<<"$(stop_payload)"
  [ "$status" -eq 0 ] || { echo "$harness: unarmed docs-only turn blocked: $output"; return 1; }
  if printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    echo "$harness: unarmed docs-only turn emitted a block: $output"; return 1
  fi
}
@test "T28 R2 Claude unarmed docs-only respects core.fileMode false" { assert_unarmed_docs_only_ignores_untracked_mode_bits claude; }
@test "T28 R2 Codex unarmed docs-only respects core.fileMode false" { assert_unarmed_docs_only_ignores_untracked_mode_bits codex; }

@test "no-op turn on a dirty tree: no receipt demand" {
  turn_entry
  turn_stop
  assert_no_receipt_demand
}

@test "hook state churn does not alter the fingerprint but a real rule edit does" {
  local before after
  source "$HOOKS_DIR/lib/deps.sh"
  before="$(_se_tree_fingerprint "$PROJECT_DIR")"
  mkdir -p "$PROJECT_DIR/.claude/.reread-state" "$PROJECT_DIR/.pi/.reread-state"
  for path in .claude/.fail-counter .claude/.reread-state/turn \
    .claude/.review-done-123 .claude/session-surgical \
    .claude/spec-gate-audit.log .pi/.reread-state/turn; do
    printf 'first\n' > "$PROJECT_DIR/$path"
  done
  after="$(_se_tree_fingerprint "$PROJECT_DIR")"
  [ "$after" = "$before" ] || { echo "hook state changed fingerprint"; return 1; }
  printf 'second\n' > "$PROJECT_DIR/.claude/.reread-state/turn"
  [ "$(_se_tree_fingerprint "$PROJECT_DIR")" = "$before" ]
  printf 'real change\n' > "$PROJECT_DIR/.claude/rules.json"
  [ "$(_se_tree_fingerprint "$PROJECT_DIR")" != "$before" ]
}

@test "doc-only turn with hook state churn does not demand a code receipt" {
  ( cd "$PROJECT_DIR" && git show HEAD:app.js > app.js && rm scratch.js )
  turn_entry
  mkdir -p "$PROJECT_DIR/.claude/.reread-state" "$PROJECT_DIR/.pi/.reread-state"
  for path in .claude/.fail-counter .claude/.reread-state/turn \
    .claude/.review-done-123 .claude/session-surgical \
    .claude/spec-gate-audit.log .pi/.reread-state/turn; do
    printf 'state\n' > "$PROJECT_DIR/$path"
  done
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_no_receipt_demand
}

@test "another agent's pi runtime output on a no-edit turn: no receipt demand" {
  turn_entry
  mkdir -p "$PROJECT_DIR/.pi/subagent-schedules" "$PROJECT_DIR/.pi/.reread-state"
  printf '{}\n' > "$PROJECT_DIR/.pi/subagent-schedules/0001.json"
  printf 'turn\n' > "$PROJECT_DIR/.pi/.reread-state/turn"
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

@test "non-string prompt sessions invalidate earlier baselines in both harnesses" {
  local hooks harness malformed
  for harness in claude codex; do
    hooks="$HOOKS_DIR"
    [ "$harness" = claude ] || hooks="$CODEX_HOOKS_DIR"
    for malformed in true 42 '["sess-1"]' '{"id":"sess-1"}'; do
      run bash "$hooks/turn-baseline.sh" <<<"$(prompt_payload)"
      [ "$status" -eq 0 ] || return 1
      run bash "$hooks/turn-baseline.sh" <<<"{\"session_id\":$malformed}"
      [ "$status" -eq 0 ] && [ -z "$output" ] || return 1
      [ -z "$(find "$TRELLIS_HOME/state/turn-baseline" -name "$harness.*" -type f)" ] || return 1
    done
  done
}

@test "T28 every prompt and carry line must bind its own nonce in both twins" {
  local lib one two digest baseline_lines
  one="$(printf '%032d' 1)"; two="$(printf '%032d' 2)"; digest="$(printf '%064d' 0)"
  baseline_lines="trellis-turn-carry v2 $one unborn $digest"$'\n'"trellis-turn-baseline v2 $two unborn $digest"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c 'source "$1"; _se_turn_baseline_state "$2" "$3" "$4"' _ "$lib" "$baseline_lines" "unborn $digest" "$one"$'\n'"$two"
    [ "$status" -eq 0 ] && [ "$output" = same ] || { echo "$lib: valid multi-line baseline failed: $output"; return 1; }
    run bash -c 'source "$1"; _se_turn_baseline_state "$2" "$3" "$4"' _ "$lib" "$baseline_lines" "unborn $digest" "$one"
    [ "$status" -eq 0 ] && [ "$output" = unknown ] || { echo "$lib: accepted later unbound prompt nonce: $output"; return 1; }
  done
}

# Hold the old nonce rewrite after its awk read but before mv. A concurrent
# prompt must wait until the rewrite completes; otherwise mv loses its append.
assert_concurrent_prompt_survives_nonce_take() {
  local harness="$1" hooks="$HOOKS_DIR" lib state key_a key_b file_b nonce shim pid_take pid_prompt i
  [ "$harness" = claude ] || hooks="$CODEX_HOOKS_DIR"
  lib="$hooks/lib/deps.sh"
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key_a="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-take')"
  key_b="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-publish')"
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" "$4"' _ "$lib" "$PROJECT_DIR" "$harness" 't30-take'
  [ -f "$state/$harness.$key_a" ] && [ -f "$state/nonces.log" ]
  shim="$BATS_TEST_TMPDIR/race-bin"; mkdir "$shim"
  export T30_NONCE_LOG="$state/nonces.log" T30_RACE_READY="$BATS_TEST_TMPDIR/rewrite-ready"
  export T30_RACE_GO="$BATS_TEST_TMPDIR/rewrite-go" T30_LOCK_ATTEMPT="$BATS_TEST_TMPDIR/lock-attempt"
  export T30_LOCK_PATH="$state/.nonces.lock" T30_PROMPT_DONE="$BATS_TEST_TMPDIR/prompt-done"
  cat > "$shim/mv" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$T30_NONCE_LOG" ]; then
    : > "$T30_RACE_READY"
    while [ ! -f "$T30_RACE_GO" ]; do sleep 0.01; done
    break
  fi
done
exec /bin/mv "$@"
SH
  cat > "$shim/mkdir" <<'SH'
#!/bin/bash
for arg in "$@"; do [ "$arg" != "$T30_LOCK_PATH" ] || : > "$T30_LOCK_ATTEMPT"; done
exec /bin/mkdir "$@"
SH
  chmod +x "$shim/mv" "$shim/mkdir"
  PATH="$shim:$PATH" bash -c 'source "$1"; _se_turn_consume "$2" "$3"; rc=$?; printf "%s" "$__se_nonces" > "$4"; exit "$rc"' _ "$lib" "$state" "$harness.$key_a" "$BATS_TEST_TMPDIR/taken" & pid_take=$!
  for ((i=0; i<1000; i++)); do [ ! -f "$T30_RACE_READY" ] || break; sleep 0.01; done
  if [ ! -f "$T30_RACE_READY" ]; then : > "$T30_RACE_GO"; wait "$pid_take" || true; echo 'nonce rewrite did not reach rendezvous'; return 1; fi
  # The first lock acquisition precedes the blocked mv; only the second
  # contender's attempt should release the parent handshake.
  rm -f "$T30_LOCK_ATTEMPT"
  PATH="$shim:$PATH" bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" "$4"; : > "$T30_PROMPT_DONE"' _ "$lib" "$PROJECT_DIR" "$harness" 't30-publish' & pid_prompt=$!
  for ((i=0; i<1000; i++)); do
    [ ! -f "$T30_LOCK_ATTEMPT" ] && [ ! -f "$T30_PROMPT_DONE" ] || break
    sleep 0.01
  done
  if [ ! -f "$T30_LOCK_ATTEMPT" ] && [ ! -f "$T30_PROMPT_DONE" ]; then
    : > "$T30_RACE_GO"; wait "$pid_take" || true; wait "$pid_prompt" || true
    echo 'prompt did not reach the lock/append rendezvous'; return 1
  fi
  : > "$T30_RACE_GO"
  wait "$pid_take" && wait "$pid_prompt" || { echo 'racing operation failed'; return 1; }
  file_b="$state/$harness.$key_b"
  [ -f "$file_b" ] || { echo 'concurrent prompt did not publish'; return 1; }
  nonce="$(awk 'NR == 1 { print $3 }' "$file_b")"
  grep -Fxq "$harness.$key_b $nonce" "$state/nonces.log" || { echo "$harness: concurrent prompt nonce was lost by the rewrite"; return 1; }
}
@test "T30 Claude nonce consume cannot lose a concurrent prompt append" { assert_concurrent_prompt_survives_nonce_take claude; }
@test "T30 Codex nonce consume cannot lose a concurrent prompt append" { assert_concurrent_prompt_survives_nonce_take codex; }

assert_shell_prompt_poison_recovery() {
  local harness="$1" hooks="$HOOKS_DIR" lib state key file poison lock before
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"
    mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  lib="$hooks/lib/deps.sh"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  turn_entry 't30-shell-poison'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-shell-poison')"
  file="$state/$harness.$key"; poison=".poison.$harness.$key.*"; lock="$state/.nonces.lock"
  before="$(cat "$file")"; mkdir "$lock"
  turn_entry 't30-shell-poison'
  [ -n "$(find "$state" -name "$poison" -type d -print -quit)" ] && [ "$(cat "$file")" = "$before" ] || { echo "$harness: contention did not poison without publishing"; return 1; }
  run --separate-stderr env PROCESS_GATE_NO_RECEIPTS=1 bash "$STOP_HOOK" <<<"$(stop_payload 't30-shell-poison')"
  [ "$status" -eq 0 ] || { echo "$harness: degraded Stop itself blocked: $output $stderr"; return 1; }
  [[ "$stderr" == *"$lock"* ]] || { echo "$harness: degraded notice omitted lock path: $stderr"; return 1; }
  [ "$(cat "$file")" = "$before" ] || { echo "$harness: poisoned Stop published carry"; return 1; }
  [ ! -d "$TRELLIS_HOME/state/stop-receipts" ] || [ -z "$(find "$TRELLIS_HOME/state/stop-receipts" -type f -print -quit)" ]
  rmdir "$lock"
  turn_entry 't30-shell-poison'
  [ -z "$(find "$state" -name "$poison" -type d -print -quit)" ] || { echo "$harness: successful prompt did not clear poison"; return 1; }
  [ "$(wc -l < "$file" | tr -d ' ')" = 1 ] || { echo "$harness: recovery retained an old baseline"; return 1; }
  turn_stop 't30-shell-poison'
  [ "$status" -eq 0 ] && grep -q '^trellis-turn-carry v2 ' "$file" || { echo "$harness: recovered Stop did not carry: $output"; return 1; }
}
@test "T30 Claude shell prompt poison is non-blocking and a fresh prompt recovers" { assert_shell_prompt_poison_recovery claude; }
@test "T30 Codex shell prompt poison is non-blocking and a fresh prompt recovers" { assert_shell_prompt_poison_recovery codex; }

assert_degraded_unknown_demands_receipt() {
  local harness="$1" hooks="$HOOKS_DIR" state lock expected
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"; mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  unset PROCESS_GATE_NO_RECEIPTS
  export CODEX_PROJECT_DIR="$PROJECT_DIR"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  turn_entry 't30-receipt-control'
  run --separate-stderr bash "$STOP_HOOK" <<<"$(stop_payload 't30-receipt-control')"
  [ "$status" -eq 0 ] && [[ "$output" != *'"decision"'* ]] || { echo "$harness: unchanged control blocked: $status $output"; return 1; }
  turn_entry 't30-degraded-receipt'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$hooks/lib/deps.sh" "$PROJECT_DIR")"
  lock="$state/.nonces.lock"; mkdir "$lock"; turn_entry 't30-degraded-receipt'; rmdir "$lock"
  run --separate-stderr bash "$STOP_HOOK" <<<"$(stop_payload 't30-degraded-receipt')"
  expected=2; [ "$harness" = claude ] || expected=0
  [ "$status" -eq "$expected" ] && printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null || { echo "$harness: degraded unknown did not demand receipt: $status $output"; return 1; }
  [[ "$stderr" == *"$lock"* && "$stderr" == *'armed unknown turn requires a receipt'* ]] || { echo "$harness: degraded notice omitted receipt rule: $stderr"; return 1; }
}
@test "T30 Claude degraded unknown requires a receipt without bypass" { assert_degraded_unknown_demands_receipt claude; }
@test "T30 Codex degraded unknown requires a receipt without bypass" { assert_degraded_unknown_demands_receipt codex; }

assert_generation_failure_is_nonblocking() {
  local harness="$1" hooks="$HOOKS_DIR" lib state key file gen poison saved before kind
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"; mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"; lib="$hooks/lib/deps.sh"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  turn_entry 't30-bad-generation'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-bad-generation')"
  file="$state/$harness.$key"; gen="$state/generation.$harness.$key"; poison=".poison.$harness.$key.*"
  for kind in empty no-newline multiline overflow lax-mode; do
    saved="$(cat "$gen")"; before="$(cat "$file")"
    case "$kind" in
      empty) : > "$gen" ;;
      no-newline) printf 1 > "$gen" ;;
      multiline) printf '1\n2\n' > "$gen" ;;
      overflow) printf '999999999999999999\n' > "$gen" ;;
      lax-mode) chmod 644 "$gen" ;;
    esac
    turn_entry 't30-bad-generation'
    [ -n "$(find "$state" -name "$poison" -type d -print -quit)" ] || { echo "$harness/$kind: no poison"; return 1; }
    [ "$(cat "$file")" = "$before" ] || { echo "$harness/$kind: corrupted generation published a baseline"; return 1; }
    run --separate-stderr env PROCESS_GATE_NO_RECEIPTS=1 bash "$STOP_HOOK" <<<"$(stop_payload 't30-bad-generation')"
    [ "$status" -eq 0 ] && [[ "$stderr" == *"$state/.nonces.lock"* ]] || { echo "$harness/$kind: no nonblocking degraded notice: $output $stderr"; return 1; }
    [ "$(cat "$file")" = "$before" ] || { echo "$harness/$kind: degraded Stop published a carry"; return 1; }
    printf '%s\n' "$saved" > "$gen"; chmod 600 "$gen"
    turn_entry 't30-bad-generation'
    [ -z "$(find "$state" -name "$poison" -type d -print -quit)" ] || { echo "$harness/$kind: repaired prompt did not clear poison"; return 1; }
  done
}
@test "T30 Claude corrupt generation warns without blocking prompt" { assert_generation_failure_is_nonblocking claude; }
@test "T30 Codex corrupt generation warns without blocking prompt" { assert_generation_failure_is_nonblocking codex; }

# The optimized generation update must not dispatch mktemp/mv from PATH; it
# still holds the shared lock and refuses unsafe on-disk state on both twins.
@test "T30 generation update is atomic, private and needs no PATH temp tools" {
  local lib state id file fake kind before
  state="$BATS_TEST_TMPDIR/generation-update"; mkdir -m 700 "$state"
  fake="$BATS_TEST_TMPDIR/generation-tools"; mkdir "$fake"
  for kind in mktemp mv; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$T30_BAD_TOOL"\nexit 91\n' "$kind" > "$fake/$kind"
    chmod 755 "$fake/$kind"
  done
  export T30_BAD_TOOL="$BATS_TEST_TMPDIR/untrusted-tool-ran"
  cat > "$fake/T30Injection.pm" <<'PERL'
package T30Injection;
BEGIN { open(my $f, '>', $ENV{T30_BAD_TOOL}) or die $!; print {$f} "injected\n"; close($f); die "untrusted Perl module ran"; }
1;
PERL
  id=claude.0123456789abcdef; file="$state/generation.$id"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    run bash -c 'source "$1"; body=$(declare -f _se_turn_generation_bump); case "$body" in *perl*) exit 1 ;; esac' _ "$lib"
    [ "$status" -eq 0 ] || { echo "$lib starts Perl on the prompt generation path"; return 1; }
    rm -f "$file"
    run env PATH="$fake:$PATH" PERL5OPT=-MT30Injection PERL5LIB="$fake" bash -c 'source "$1"; _se_turn_lock "$2" || exit; _se_turn_generation_bump "$2" "$3"; rc=$?; _se_turn_unlock "$2"; exit "$rc"' _ "$lib" "$state" "$id"
    [ "$status" -eq 0 ] && [ "$output" = 1 ] && [ "$(cat "$file")" = 1 ] || { echo "$lib first generation: $status $output"; return 1; }
    run env PATH="$fake:$PATH" bash -c 'source "$1"; _se_turn_lock "$2" || exit; _se_turn_generation_bump "$2" "$3"; rc=$?; _se_turn_unlock "$2"; exit "$rc"' _ "$lib" "$state" "$id"
    [ "$status" -eq 0 ] && [ "$output" = 2 ] && [ "$(cat "$file")" = 2 ] || { echo "$lib increment: $status $output"; return 1; }
    [ ! -e "$T30_BAD_TOOL" ] || { echo "$lib ran PATH-selected tool or injected Perl module"; return 1; }
    printf '00009\n' > "$file"
    run env PATH="$fake:$PATH" bash -c 'source "$1"; _se_turn_lock "$2" || exit; _se_turn_generation_bump "$2" "$3"; rc=$?; _se_turn_unlock "$2"; exit "$rc"' _ "$lib" "$state" "$id"
    [ "$status" -eq 0 ] && [ "$output" = 10 ] || { echo "$lib leading-zero generation: $status $output"; return 1; }
    printf '999999999999999998\n' > "$file"
    run env PATH="$fake:$PATH" bash -c 'source "$1"; _se_turn_lock "$2" || exit; _se_turn_generation_bump "$2" "$3"; rc=$?; _se_turn_unlock "$2"; exit "$rc"' _ "$lib" "$state" "$id"
    [ "$status" -eq 0 ] && [ "$output" = 999999999999999999 ] || { echo "$lib last generation: $status $output"; return 1; }
    printf '2\n' > "$file"; printf 'untouched\n' > "$state/outside"
    run env PATH="$fake:$PATH" bash -c '
      source "$1"; _se_turn_lock "$2" || exit 1
      temp="$2/.nonces.lock/.generation.$$.tmp"; ln -s "$4" "$temp" || exit 1
      _se_turn_generation_bump "$2" "$3" >/dev/null; rc=$?
      [ "$rc" -ne 0 ] && [ -L "$temp" ] && [ "$(cat "$4")" = untouched ] || exit 1
      /bin/rm -f "$temp"; _se_turn_unlock "$2"
    ' _ "$lib" "$state" "$id" "$state/outside"
    [ "$status" -eq 0 ] && [ "$(cat "$file")" = 2 ] || { echo "$lib followed or removed an unknown temp: $output"; return 1; }
    for kind in empty no-newline multiline overflow lax-mode symlink hardlink; do
      rm -f "$file" "$state/alias"
      case "$kind" in
        empty) : > "$file" ;;
        no-newline) printf 1 > "$file" ;;
        multiline) printf '1\n2\n' > "$file" ;;
        overflow) printf '999999999999999999\n' > "$file" ;;
        lax-mode) printf '1\n' > "$file" ;;
        symlink) printf '1\n' > "$state/alias"; ln -s "$state/alias" "$file" ;;
        hardlink) printf '1\n' > "$state/alias"; ln "$state/alias" "$file" ;;
      esac
      [ "$kind" = symlink ] || chmod 600 "$file"
      [ "$kind" != lax-mode ] || chmod 644 "$file"
      before="$(cat "$file")"
      run env PATH="$fake:$PATH" bash -c 'source "$1"; _se_turn_lock "$2" || exit; _se_turn_generation_bump "$2" "$3"; rc=$?; _se_turn_unlock "$2"; exit "$rc"' _ "$lib" "$state" "$id"
      [ "$status" -ne 0 ] && [ "$(cat "$file")" = "$before" ] || { echo "$lib accepted $kind generation: $status $output"; return 1; }
      [ -z "$(find "$state" -name '.generation.tmp.*' -print -quit)" ] || { echo "$lib left generation temp after $kind"; return 1; }
    done
  done
}

assert_newer_poison_survives_older_publisher() {
  local harness="$1" hooks="$HOOKS_DIR" lib state key file lock pattern old newer marker name rest pid token shim older i
  [ "$harness" = claude ] || hooks="$CODEX_HOOKS_DIR"
  lib="$hooks/lib/deps.sh"; BASELINE_HOOK="$hooks/turn-baseline.sh"
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  turn_entry 't30-poison-race'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-poison-race')"
  file="$state/$harness.$key"; lock="$state/.nonces.lock"; pattern=".poison.$harness.$key.*"
  mkdir "$lock"; turn_entry 't30-poison-race'; rmdir "$lock"
  old="$(find "$state" -name "$pattern" -type d -print)"
  [ -n "$old" ] && [ "$(printf '%s\n' "$old" | wc -l | tr -d ' ')" = 1 ] || { echo 'first failure did not create one marker'; return 1; }
  shim="$BATS_TEST_TMPDIR/poison-race-bin"; mkdir "$shim"
  export T30_POISON_BASELINE="$file" T30_POISON_READY="$BATS_TEST_TMPDIR/poison-ready" T30_POISON_GO="$BATS_TEST_TMPDIR/poison-go"
  cat > "$shim/rm" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$T30_POISON_BASELINE" ]; then
    : > "$T30_POISON_READY"
    while [ ! -f "$T30_POISON_GO" ]; do sleep 0.01; done
    break
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$shim/rm"
  PATH="$shim:$PATH" bash "$BASELINE_HOOK" <<<"$(prompt_payload 't30-poison-race')" > "$BATS_TEST_TMPDIR/older.out" 2>&1 & older=$!
  for ((i=0; i<1000; i++)); do [ ! -f "$T30_POISON_READY" ] || break; sleep 0.01; done
  if [ ! -f "$T30_POISON_READY" ]; then : > "$T30_POISON_GO"; wait "$older" || true; echo 'older publisher did not reach poison snapshot'; return 1; fi
  turn_entry 't30-poison-race'
  newer="$(find "$state" -name "$pattern" -type d -print | grep -vFx "$old")"
  if [ -z "$newer" ]; then : > "$T30_POISON_GO"; wait "$older" || true; echo 'newer failed prompt did not create a distinct marker'; return 1; fi
  for marker in "$old" "$newer"; do
    name=${marker##*/}; rest=${name#".poison.$harness.$key."}; pid=${rest%%.*}; token=${rest#*.}
    case "$pid" in ''|*[!0-9]*) : > "$T30_POISON_GO"; wait "$older" || true; echo "marker lacks PID: $name"; return 1 ;; esac
    case "$token" in ''|*[!A-Za-z0-9]*) : > "$T30_POISON_GO"; wait "$older" || true; echo "marker lacks random token: $name"; return 1 ;; esac
    [ "${#token}" -ge 8 ] || { : > "$T30_POISON_GO"; wait "$older" || true; echo "marker token too short: $name"; return 1; }
  done
  : > "$T30_POISON_GO"; wait "$older" || { echo 'older publisher failed'; return 1; }
  [ ! -e "$old" ] && [ -d "$newer" ] || { echo "$harness: older publisher erased newer failure"; return 1; }
  turn_entry 't30-poison-race'
  [ -z "$(find "$state" -name "$pattern" -type d -print -quit)" ] || { echo 'next prompt did not clear observed marker'; return 1; }
}
@test "T30 Claude older publisher cannot erase a newer poison" { assert_newer_poison_survives_older_publisher claude; }
@test "T30 Codex older publisher cannot erase a newer poison" { assert_newer_poison_survives_older_publisher codex; }

assert_waiting_publisher_keeps_later_poison() {
  local harness="$1" hooks="$HOOKS_DIR" lib state key lock pattern old newer shim older i
  [ "$harness" = claude ] || hooks="$CODEX_HOOKS_DIR"
  lib="$hooks/lib/deps.sh"; BASELINE_HOOK="$hooks/turn-baseline.sh"
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  turn_entry 't30-waiting-poison'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-waiting-poison')"
  lock="$state/.nonces.lock"; pattern=".poison.$harness.$key.*"
  mkdir "$lock"; turn_entry 't30-waiting-poison'; rmdir "$lock"
  old="$(find "$state" -name "$pattern" -type d -print)"; [ -n "$old" ]
  shim="$BATS_TEST_TMPDIR/waiting-poison-bin"; mkdir "$shim"
  export T30_WAIT_LOCK="$lock" T30_WAIT_READY="$BATS_TEST_TMPDIR/wait-ready" T30_WAIT_GO="$BATS_TEST_TMPDIR/wait-go"
  cat > "$shim/mkdir" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$T30_WAIT_LOCK" ]; then
    : > "$T30_WAIT_READY"
    while [ ! -f "$T30_WAIT_GO" ]; do sleep 0.01; done
    break
  fi
done
exec /bin/mkdir "$@"
SH
  chmod +x "$shim/mkdir"
  PATH="$shim:$PATH" bash "$BASELINE_HOOK" <<<"$(prompt_payload 't30-waiting-poison')" > "$BATS_TEST_TMPDIR/waiting.out" 2>&1 & older=$!
  for ((i=0; i<1000; i++)); do [ ! -f "$T30_WAIT_READY" ] || break; sleep 0.01; done
  if [ ! -f "$T30_WAIT_READY" ]; then : > "$T30_WAIT_GO"; wait "$older" || true; echo 'older prompt did not reach pre-lock rendezvous'; return 1; fi
  /bin/mkdir "$lock"
  turn_entry 't30-waiting-poison'
  newer="$(find "$state" -name "$pattern" -type d -print | grep -vFx "$old")"
  rmdir "$lock"; : > "$T30_WAIT_GO"; wait "$older" || { echo 'older waiting prompt failed'; return 1; }
  [ -n "$newer" ] && [ ! -e "$old" ] && [ -d "$newer" ] || { echo "$harness: waiting publisher cleared a later failure"; return 1; }
  turn_entry 't30-waiting-poison'
  [ -z "$(find "$state" -name "$pattern" -type d -print -quit)" ]
}
@test "T30 Claude waiting publisher cannot erase a newer poison" { assert_waiting_publisher_keeps_later_poison claude; }
@test "T30 Codex waiting publisher cannot erase a newer poison" { assert_waiting_publisher_keeps_later_poison codex; }

assert_invalidation_cleans_only_own_poison() {
  local harness="$1" other=codex hooks="$HOOKS_DIR" lib state key other_key before after
  if [ "$harness" = codex ]; then other=claude; hooks="$CODEX_HOOKS_DIR"; fi
  lib="$hooks/lib/deps.sh"
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-invalidate')"; other_key="$key"
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" "$4"; _se_turn_baseline_publish "$2" "$5" "$4"' _ "$lib" "$PROJECT_DIR" "$harness" 't30-invalidate' "$other"
  bash -c 'source "$1"; _se_turn_poison "$2" "$3"; _se_turn_poison "$2" "$4"' _ "$lib" "$state" "$harness.$key" "$other.$other_key"
  before="$(cat "$state/generation.$harness.$key")"
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" ""' _ "$lib" "$PROJECT_DIR" "$harness"
  [ -z "$(find "$state" -name ".poison.$harness.$key.*" -print -quit)" ] || { echo 'own poison was not cleaned on invalidation'; return 1; }
  [ -n "$(find "$state" -name ".poison.$other.$other_key.*" -print -quit)" ] || { echo 'other harness poison was removed'; return 1; }
  [ ! -e "$state/$harness.$key" ] && [ -f "$state/$other.$other_key" ]
  after="$(cat "$state/generation.$harness.$key")"
  [ "$after" -gt "$before" ] || { echo 'invalidation did not advance pending intent generation'; return 1; }
}
@test "T30 Claude invalidation cleans own poison only" { assert_invalidation_cleans_only_own_poison claude; }
@test "T30 Codex invalidation cleans own poison only" { assert_invalidation_cleans_only_own_poison codex; }

# Accepted residual, not a passing oracle: if all durable writes fail during
# lock contention, a later process has no observable new state. This fixture
# also denies appends to existing files, so it applies to pre-T30 code.
assert_poison_storage_failure_reverifies() {
  local harness="$1" mode="${2:-verify}" hooks="$HOOKS_DIR" lib state count prompt_status prompt_output baseline
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"; mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  mkdir -p "$PROJECT_DIR/.venv/bin"
  count="$BATS_TEST_TMPDIR/storage-failure-check-count"
  cat > "$PROJECT_DIR/.venv/bin/mypy" <<SH
#!/usr/bin/perl
if (@ARGV && \$ARGV[0] eq '--version') { print "mypy 1\\n"; exit 0; }
open(my \$f,'>>',q{$count}) or die \$!; print \$f "run\\n"; close \$f; exit 0;
SH
  chmod 755 "$PROJECT_DIR/.venv/bin/mypy"
  printf '[mypy]\n' > "$PROJECT_DIR/mypy.ini"
  turn_entry 't30-no-durable-poison'
  lib="$hooks/lib/deps.sh"
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  mkdir "$state/.nonces.lock"
  baseline="$(find "$state" -maxdepth 1 -name "$harness.*" -type f)"
  [ -n "$baseline" ] && [ -f "$state/nonces.log" ]
  # Deny appending as well as creating, replacing or removing any state.
  # Restore permissions before making assertions or running the Stop hook.
  chmod 400 "$baseline" "$state/nonces.log"; chmod 500 "$state"
  run --separate-stderr bash "$BASELINE_HOOK" <<<"$(prompt_payload 't30-no-durable-poison')"
  prompt_status="$status"; prompt_output="$output"
  chmod 700 "$state"; chmod 600 "$baseline" "$state/nonces.log"; rmdir "$state/.nonces.lock"
  [ "$prompt_status" -eq 0 ] || { echo 'failed prompt must not block'; return 1; }
  if [ "$mode" = notice ]; then
    printf '%s' "$prompt_output" | jq -e '
      .hookSpecificOutput.hookEventName == "UserPromptSubmit" and
      (.hookSpecificOutput.additionalContext | contains("next Stop may not detect this turn")) and
      (has("decision") | not)
    ' >/dev/null || { echo "$harness: model-visible degraded prompt notice missing: $prompt_output"; return 1; }
    return
  fi
  run env PROCESS_GATE_NO_RECEIPTS=1 bash "$STOP_HOOK" <<<"$(stop_payload 't30-no-durable-poison')"
  [ "$status" -eq 0 ] && [ -s "$count" ] || { echo "$harness: marker-write failure left an older baseline trusted and skipped re-verification"; return 1; }
}
@test "T30 Claude no-durable-poison failure warns the model without blocking" {
  assert_poison_storage_failure_reverifies claude notice
}
@test "T30 Codex no-durable-poison failure warns the model without blocking" {
  assert_poison_storage_failure_reverifies codex notice
}
@test "T30 both prompt twins stay silent outside a Git worktree" {
  local plain="$BATS_TEST_TMPDIR/not-a-worktree" bare="$BATS_TEST_TMPDIR/bare.git" project script
  mkdir "$plain"; git init --bare -q "$bare"
  for project in "$plain" "$bare"; do
    for script in "$HOOKS_DIR/turn-baseline.sh" "$CODEX_HOOKS_DIR/turn-baseline.sh"; do
      run --separate-stderr env CLAUDE_PROJECT_DIR="$project" CODEX_PROJECT_DIR="$project" bash "$script" <<<'{"session_id":"non-git"}'
      [ "$status" -eq 0 ] && [ -z "$output" ] && [ -z "$stderr" ] || { echo "$script non-worktree $project was noisy: $status $output $stderr"; return 1; }
    done
  done
}
@test "T30 prompt twins still warn on an indeterminate Git failure" {
  local shim="$BATS_TEST_TMPDIR/broken-git" script
  mkdir "$shim"; printf '#!/bin/sh\nexit 2\n' > "$shim/git"; chmod 755 "$shim/git"
  for script in "$HOOKS_DIR/turn-baseline.sh" "$CODEX_HOOKS_DIR/turn-baseline.sh"; do
    run --separate-stderr env PATH="$shim:$PATH" CODEX_PROJECT_DIR="$PROJECT_DIR" bash "$script" <<<'{"session_id":"broken-git"}'
    [ "$status" -eq 0 ] && printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("next Stop may not detect this turn")' >/dev/null || { echo "$script suppressed uncertain Git failure: $status $output"; return 1; }
    run --separate-stderr env HOME='' TRELLIS_HOME='' CODEX_PROJECT_DIR="$PROJECT_DIR" bash "$script" <<<'{"session_id":"missing-home"}'
    [ "$status" -eq 0 ] && printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("next Stop may not detect this turn")' >/dev/null || { echo "$script suppressed missing-home failure: $status $output"; return 1; }
  done
}
@test "T30 pending Claude no-durable-poison failure must reverify" {
  [ "${T30_RUN_FULL_STORAGE_FAILURE:-0}" = 1 ] || skip 'T30 accepted residual: no writable poison or invalidation authority'
  assert_poison_storage_failure_reverifies claude
}
@test "T30 pending Codex no-durable-poison failure must reverify" {
  [ "${T30_RUN_FULL_STORAGE_FAILURE:-0}" = 1 ] || skip 'T30 accepted residual: no writable poison or invalidation authority'
  assert_poison_storage_failure_reverifies codex
}

# A Stop may never leave a nonce for a baseline it has seen, even when its
# loop guard suppresses checks. Restoring the old baseline alone must not
# launder it into a later no-op turn; another session remains untouched.
assert_stop_consumes_seen_nonce() {
  local harness="$1" outcome="$2" hooks="$HOOKS_DIR" lib state key other_key file other log before input expected gen other_gen before_gen other_before_gen
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"; mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  lib="$hooks/lib/deps.sh"
  turn_entry 't30-consume-seen'; turn_entry 't30-other-session'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-consume-seen')"
  other_key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 't30-other-session')"
  file="$state/$harness.$key"; other="$state/$harness.$other_key"; log="$state/nonces.log"
  gen="$state/generation.$harness.$key"; other_gen="$state/generation.$harness.$other_key"
  before_gen="$(cat "$gen")"; other_before_gen="$(cat "$other_gen")"
  before="$(cat "$file")"; [ -n "$before" ] && [ -f "$other" ]
  [ -n "$(awk -v id="$harness.$key" '$1 == id' "$log")" ]
  input="$(stop_payload 't30-consume-seen')"
  if [ "$outcome" = nested ]; then
    local log_before; log_before="$(cat "$log")"
    run --separate-stderr env TRELLIS_REVIEW_IN_PROGRESS=1 bash "$STOP_HOOK" <<<"$input"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$harness nested reviewer changed verdict: $status $output"; return 1; }
    [ "$(cat "$file")" = "$before" ] && [ "$(cat "$log")" = "$log_before" ] && [ "$(cat "$gen")" = "$before_gen" ] || { echo "$harness nested reviewer consumed parent state"; return 1; }
    return
  elif [ "$outcome" = reentrant ]; then
    input="$(printf '%s' "$input" | jq '.stop_hook_active = true')"
    run --separate-stderr bash "$STOP_HOOK" <<<"$input"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$harness reentry changed verdict: $status $output"; return 1; }
  else
    printf 'new work\n' >> "$PROJECT_DIR/app.js"
    run --separate-stderr bash "$STOP_HOOK" <<<"$input"
    expected=2; [ "$harness" = claude ] || expected=0
    [ "$status" -eq "$expected" ] && printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null || { echo "$harness denial missing: $status $output"; return 1; }
  fi
  [ ! -e "$file" ] || { echo "$harness $outcome retained seen baseline"; return 1; }
  [ "$(cat "$gen")" -eq "$((before_gen + 1))" ] || { echo "$harness $outcome failed to advance consumed generation"; return 1; }
  [ "$(cat "$other_gen")" = "$other_before_gen" ] || { echo "$harness $outcome changed another session generation"; return 1; }
  [ -z "$(awk -v id="$harness.$key" '$1 == id' "$log")" ] || { echo "$harness $outcome retained seen nonce"; return 1; }
  [ -f "$other" ] && [ -n "$(awk -v id="$harness.$other_key" '$1 == id' "$log")" ] || { echo "$harness $outcome consumed another session"; return 1; }
  if [ "$outcome" = reentrant ]; then
    printf '%s\n' "$before" > "$file"
    run --separate-stderr bash "$STOP_HOOK" <<<"$(stop_payload 't30-consume-seen')"
    expected=2; [ "$harness" = claude ] || expected=0
    [ "$status" -eq "$expected" ] && printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null || { echo "$harness replayed reentrant baseline was trusted: $status $output"; return 1; }
  fi
}
@test "T30 Claude denied Stop consumes its seen baseline nonce" { assert_stop_consumes_seen_nonce claude deny; }
@test "T30 Codex denied Stop consumes its seen baseline nonce" { assert_stop_consumes_seen_nonce codex deny; }
@test "T30 Claude reentrant Stop consumes its seen baseline nonce" { assert_stop_consumes_seen_nonce claude reentrant; }
@test "T30 Codex reentrant Stop consumes its seen baseline nonce" { assert_stop_consumes_seen_nonce codex reentrant; }
@test "T30 nested reviewer cannot consume either harness parent baseline" {
  assert_stop_consumes_seen_nonce claude nested
  # Reset the project so this second fixture has only the Codex namespace.
  rm -rf "${TRELLIS_HOME:?}"
  assert_stop_consumes_seen_nonce codex nested
}

assert_contended_reentry_reverifies() {
  local harness="$1" hooks="$HOOKS_DIR" state count input
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"; mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  mkdir -p "$PROJECT_DIR/.venv/bin"; count="$BATS_TEST_TMPDIR/reentry-check-count"
  cat > "$PROJECT_DIR/.venv/bin/mypy" <<SH
#!/usr/bin/perl
if (@ARGV && \$ARGV[0] eq '--version') { print "mypy 1\\n"; exit 0; }
open(my \$f,'>>',q{$count}) or die \$!; print \$f "run\\n"; close \$f; exit 0;
SH
  chmod 755 "$PROJECT_DIR/.venv/bin/mypy"; printf '[mypy]\n' > "$PROJECT_DIR/mypy.ini"
  turn_entry 't30-reentry-contention'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$hooks/lib/deps.sh" "$PROJECT_DIR")"
  mkdir "$state/.nonces.lock"
  input="$(stop_payload 't30-reentry-contention' | jq '.stop_hook_active = true')"
  run --separate-stderr bash "$STOP_HOOK" <<<"$input"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { rmdir "$state/.nonces.lock"; echo "reentry blocked: $status $output"; return 1; }
  [[ "$stderr" == *"$state/.nonces.lock"* ]] || { rmdir "$state/.nonces.lock"; echo "missing degraded lock notice: $stderr"; return 1; }
  rmdir "$state/.nonces.lock"
  run --separate-stderr env PROCESS_GATE_NO_RECEIPTS=1 bash "$STOP_HOOK" <<<"$(stop_payload 't30-reentry-contention')"
  [ "$status" -eq 0 ] && [ -s "$count" ] || { echo "$harness contended reentry skipped real checks: $status $output"; return 1; }
}
@test "T30 Claude contended reentry warns and next Stop reverifies" { assert_contended_reentry_reverifies claude; }
@test "T30 Codex contended reentry warns and next Stop reverifies" { assert_contended_reentry_reverifies codex; }

assert_unarmed_observer_consumes_racing_prompt() {
  local h="$1" hooks="$HOOKS_DIR" settings state key file log shim pid i nonce
  if [ "$h" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"; settings="$PROJECT_DIR/.codex/hooks.json"; mkdir -p "${settings%/*}"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}\n' > "$settings"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  else settings="$PROJECT_DIR/.claude/settings.local.json"; fi
  export CODEX_PROJECT_DIR="$PROJECT_DIR"; BASELINE_HOOK="$hooks/turn-baseline.sh"; STOP_HOOK="$hooks/stop-verify.sh"
  turn_entry 'unarmed-observer-race'
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$hooks/lib/deps.sh" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$hooks/lib/deps.sh" 'unarmed-observer-race')"
  file="$state/$h.$key"; log="$state/nonces.log"
  bash -c 'source "$1"; _se_turn_consume "$2" "$3"' _ "$hooks/lib/deps.sh" "$state" "$h.$key"
  [ ! -e "$file" ] || return 1
  rm -f "$settings"
  shim="$BATS_TEST_TMPDIR/unarmed-observer-bin"; mkdir "$shim"
  export T30_OBSERVE_LOCK="$state/.nonces.lock" T30_OBSERVE_READY="$BATS_TEST_TMPDIR/observe-ready" T30_OBSERVE_GO="$BATS_TEST_TMPDIR/observe-go"
  cat > "$shim/mkdir" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$T30_OBSERVE_LOCK" ]; then
    : > "$T30_OBSERVE_READY"
    while [ ! -f "$T30_OBSERVE_GO" ]; do sleep 0.01; done
    break
  fi
done
exec /bin/mkdir "$@"
SH
  chmod +x "$shim/mkdir"
  PATH="$shim:$PATH" PROCESS_GATE_NO_RECEIPTS=1 bash "$STOP_HOOK" <<<"$(stop_payload 'unarmed-observer-race')" > "$BATS_TEST_TMPDIR/observe-out" 2>&1 & pid=$!
  for ((i=0; i<1000; i++)); do [ ! -f "$T30_OBSERVE_READY" ] || break; sleep 0.01; done
  if [ ! -f "$T30_OBSERVE_READY" ]; then : > "$T30_OBSERVE_GO"; wait "$pid" || true; echo 'unarmed Stop never reached its generation lock'; return 1; fi
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" "$4"' _ "$hooks/lib/deps.sh" "$PROJECT_DIR" "$h" 'unarmed-observer-race'
  nonce="$(awk 'NR == 1 { print $3 }' "$file")"; [ -n "$nonce" ] || { : > "$T30_OBSERVE_GO"; wait "$pid" || true; return 1; }
  : > "$T30_OBSERVE_GO"; wait "$pid" || { echo 'unarmed Stop failed'; return 1; }
  ! grep -Fxq "$h.$key $nonce" "$log" || { echo "$h racing prompt nonce was not consumed"; return 1; }
  grep -q '^trellis-turn-carry v2 ' "$file" || { echo "$h racing prompt did not receive a fresh carry"; return 1; }
}
@test "T30 Claude unarmed observer consumes a prompt published before lock" { assert_unarmed_observer_consumes_racing_prompt claude; }
@test "T30 Codex unarmed observer consumes a prompt published before lock" { assert_unarmed_observer_consumes_racing_prompt codex; }

assert_unreadable_range_requires_receipt() {
  local harness="$1" hooks="$HOOKS_DIR" file fake
  git -C "$PROJECT_DIR" reset --hard -q HEAD
  rm -f "$PROJECT_DIR/scratch.js"
  if [ "$harness" = codex ]; then
    hooks="$CODEX_HOOKS_DIR"
    mkdir -p "$PROJECT_DIR/.codex"
    printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"x/turn-baseline.sh"}]}]}}\n' > "$PROJECT_DIR/.codex/hooks.json"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  BASELINE_HOOK="$hooks/turn-baseline.sh" STOP_HOOK="$hooks/stop-verify.sh"
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  turn_entry
  file="$(find "$TRELLIS_HOME/state/turn-baseline" -name "$harness.*" -type f)"
  [ -n "$file" ] && [ -f "$file" ]
  fake="$(printf '%040d' 0)"
  awk -v missing="$fake" '{$4=missing; print}' "$file" > "$file.next" && mv "$file.next" "$file"
  printf '# only documentation changed\n' > "$PROJECT_DIR/README.md"
  run --separate-stderr bash "$STOP_HOOK" <<<"$(stop_payload)"
  if { [ "$harness" = claude ] && [ "$status" -ne 2 ]; } || { [ "$harness" = codex ] && [ "$status" -ne 0 ]; }; then
    echo "$harness: unreadable committed range was treated as docs-only: status=$status output=$output"; return 1
  fi
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null || {
    echo "$harness: unreadable committed range was treated as docs-only: $output; stderr=$stderr"; return 1;
  }
}
@test "T28 Claude unreadable committed range stays non-doc and demands receipt" { assert_unreadable_range_requires_receipt claude; }
@test "T28 Codex unreadable committed range stays non-doc and demands receipt" { assert_unreadable_range_requires_receipt codex; }

@test "baseline fingerprint and publication helpers retain exact twin parity" {
  local claude codex fn names_claude names_codex expected
  names_claude="$BATS_TEST_TMPDIR/claude-functions"; names_codex="$BATS_TEST_TMPDIR/codex-functions"
  bash -c 'source "$1"; declare -F' _ "$HOOKS_DIR/lib/deps.sh" | awk '$3 ~ /^_se_/ { print $3 }' | LC_ALL=C sort > "$names_claude"
  bash -c 'source "$1"; declare -F' _ "$CODEX_HOOKS_DIR/lib/deps.sh" | awk '$3 ~ /^_se_/ { print $3 }' | LC_ALL=C sort > "$names_codex"
  [ -s "$names_claude" ]
  [ -z "$(comm -23 "$names_claude" "$names_codex")" ] || { echo 'a Claude helper is missing from Codex'; return 1; }
  expected=$(printf '%s\n' _se_emit_hook_context _se_emit_system_message _se_harness_home _se_inherited_project_mismatch | LC_ALL=C sort)
  [ "$(comm -13 "$names_claude" "$names_codex")" = "$expected" ] || { echo 'unexpected one-sided helper; update the reviewed harness-only list'; return 1; }
  while IFS= read -r fn; do
    [ "$fn" != _se_require_jq ] || continue # Harness-specific output transport.
    claude="$(bash -c 'source "$1"; declare -f "$2"' _ "$HOOKS_DIR/lib/deps.sh" "$fn")"
    codex="$(bash -c 'source "$1"; declare -f "$2"' _ "$CODEX_HOOKS_DIR/lib/deps.sh" "$fn")"
    [ -n "$claude" ] && [ "$claude" = "$codex" ] || { echo "$fn drifted between twins"; return 1; }
  done < "$names_claude"
  claude="$(bash -c 'source "$1"; printf "%s" "$__se_fp_perl"' _ "$HOOKS_DIR/lib/deps.sh")"
  codex="$(bash -c 'source "$1"; printf "%s" "$__se_fp_perl"' _ "$CODEX_HOOKS_DIR/lib/deps.sh")"
  [ -n "$claude" ] && [ "$claude" = "$codex" ] || { echo '__se_fp_perl drifted between twins'; return 1; }
}

@test "T28 hook-state pathspec arrays retain exact twin parity" {
  local claude codex
  claude="$(bash -c 'source "$1"; printf "%s\n" "${__se_hook_state_pathspec[@]}"' _ "$HOOKS_DIR/lib/deps.sh")"
  codex="$(bash -c 'source "$1"; printf "%s\n" "${__se_hook_state_pathspec[@]}"' _ "$CODEX_HOOKS_DIR/lib/deps.sh")"
  [ "$claude" = "$codex" ] || { echo 'top-level hook-state pathspecs differ'; return 1; }
}

@test "T28 both fingerprints exclude both harness state trees only" {
  local lib before path
  mkdir -p "$PROJECT_DIR/.claude/.reread-state" "$PROJECT_DIR/.codex/.reread-state"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    before="$(bash -c 'source "$1"; _se_tree_fingerprint "$2"' _ "$lib" "$PROJECT_DIR")"
    for path in .claude/.fail-counter .claude/.reread-state/turn .claude/.review-done-123 \
      .codex/.fail-counter .codex/.reread-state/turn .codex/.review-done-123; do
      printf 'first\n' > "$PROJECT_DIR/$path"
      [ "$(bash -c 'source "$1"; _se_tree_fingerprint "$2"' _ "$lib" "$PROJECT_DIR")" = "$before" ] || {
        echo "$lib: untracked $path changed fingerprint"; return 1;
      }
      git -C "$PROJECT_DIR" add -f -- "$path"
      printf 'second\n' > "$PROJECT_DIR/$path"
      [ "$(bash -c 'source "$1"; _se_tree_fingerprint "$2"' _ "$lib" "$PROJECT_DIR")" = "$before" ] || {
        echo "$lib: tracked $path changed fingerprint"; return 1;
      }
    done
    for path in .claude/rules.json .codex/rules.json nested/.codex/.fail-counter; do
      mkdir -p "$PROJECT_DIR/${path%/*}"
      printf 'real input\n' > "$PROJECT_DIR/$path"
      [ "$(bash -c 'source "$1"; _se_tree_fingerprint "$2"' _ "$lib" "$PROJECT_DIR")" != "$before" ] || {
        echo "$lib: real input $path was excluded"; return 1;
      }
      rm -f "${PROJECT_DIR:?}/$path"
    done
  done
}

assert_native_armed_clean_stop() {
  local harness="$1" form="${2:-direct}" hook
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  native_prompt_candidate "$harness" "$form"
  hook="$HOOKS_DIR/stop-verify.sh"; [ "$harness" = claude ] || hook="$CODEX_HOOKS_DIR/stop-verify.sh"
  run bash "$hook" <<<"$(stop_payload)"
  if [ "$harness" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("receipts:"))' >/dev/null || {
    echo "$harness: status=$status output=$output"; return 1;
  }
}

@test "T62 native Claude prompt arms fallback Stop on a clean committed turn" {
  assert_native_armed_clean_stop claude
}

@test "T62 native Codex prompt arms fallback Stop on a clean committed turn" {
  assert_native_armed_clean_stop codex
}

@test "T62 older Claude native shell prompt also arms fallback Stop" {
  assert_native_armed_clean_stop claude shell
}

@test "T62 native prompt loss blocks even when a valid prior baseline exists" {
  local file
  native_prompt_candidate claude
  turn_entry
  file="$PROJECT_DIR/.claude/settings.local.json"
  jq 'del(.hooks.UserPromptSubmit)' "$file" > "$file.next" && mv "$file.next" "$file"
  turn_stop
  [ "$status" -eq 2 ] || { echo "native inspection error returned $status: $output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
}

@test "T62 a legacy filename outside UserPromptSubmit is not an armed registration" {
  local file="$PROJECT_DIR/.claude/settings.local.json"
  printf '%s\n' '{"note":"/tmp/turn-baseline.sh","hooks":{"UserPromptSubmit":[]}}' > "$file"
  source "$HOOKS_DIR/lib/deps.sh"
  [ "$(_se_turn_baseline_arming "$PROJECT_DIR" claude)" = unarmed ]
}

@test "T62 a legacy bare command arms a clean turn with a missing baseline" {
  local file="$PROJECT_DIR/.claude/settings.local.json"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"turn-baseline.sh"}]}]}}' > "$file"
  turn_stop
  assert_receipt_demanded
}

@test "T62 legacy command without type stays armed for Claude Codex and Pi" {
  local body='{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}'
  printf '%s\n' "$body" > "$PROJECT_DIR/.claude/settings.local.json"
  mkdir -p "$PROJECT_DIR/.codex"
  printf '%s\n' "$body" > "$PROJECT_DIR/.codex/hooks.json"
  source "$HOOKS_DIR/lib/deps.sh"
  [ "$(_se_turn_baseline_arming "$PROJECT_DIR" claude)" = legacy ]
  [ "$(_se_turn_baseline_arming "$PROJECT_DIR" codex)" = legacy ]
  [ "$(_se_turn_baseline_arming "$PROJECT_DIR" pi)" = legacy ]
  mv "$PROJECT_DIR/.codex/hooks.json" "$BATS_TEST_TMPDIR/removed-codex-settings"
  [ "$(_se_turn_baseline_arming "$PROJECT_DIR" pi)" = unarmed ]
}

@test "T34 a selectable payload with a legacy-shaped template stays legacy for both twins" {
  # qp-fix-native item 0: jq's "no native entry" status (1) must not read as
  # an uninspectable template on a host the payload ships an asset for.
  local body='{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' lib runtime
  printf '%s\n' "$body" > "$PROJECT_DIR/.claude/settings.local.json"
  mkdir -p "$PROJECT_DIR/.codex"
  printf '%s\n' "$body" > "$PROJECT_DIR/.codex/hooks.json"
  runtime="$PROJECT_DIR/.trellis/runtime/core-rules"
  mkdir -p "$runtime/templates" "$runtime/native"
  printf '%s\n' "$body" > "$runtime/templates/claude-settings.local.json"
  printf '%s\n' "$body" > "$runtime/templates/codex-hooks.local.json"
  printf '%s\n' '{"assets":{"aarch64-apple-darwin":{"sha256":"00"},"x86_64-unknown-linux-musl":{"sha256":"00"},"aarch64-unknown-linux-musl":{"sha256":"00"}}}' \
    > "$runtime/native/artifacts.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    (
      source "$lib"
      [ "$(_se_turn_baseline_arming "$PROJECT_DIR" claude)" = legacy ] &&
        [ "$(_se_turn_baseline_arming "$PROJECT_DIR" codex)" = legacy ]
    ) || { echo "$lib: legacy template on a selectable host was not legacy"; return 1; }
  done
}

@test "B9 unreadable settings are unknown for both twins and all harnesses" {
  local lib harness file home layout result
  mkdir -p "$PROJECT_DIR/.codex"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for harness in claude codex pi; do
      file="$PROJECT_DIR/.codex/hooks.json"
      [ "$harness" != claude ] || file="$PROJECT_DIR/.claude/settings.local.json"
      for layout in absent present; do
        home="$BATS_TEST_TMPDIR/home-$harness-$layout"
        mkdir -p "$home/state"
        [ "$layout" != present ] || mkdir -p "$home/state/attachments"
        export TRELLIS_HOME="$home"
        printf '%s\n' '{"native":"/bin/native/companion"}' > "$file"
        chmod 000 "$file"
        [ ! -r "$file" ] || skip 'requires a non-root user to make a settings file unreadable'
        result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
        chmod 600 "$file"
        [ "$result" = unknown ] || { echo "$lib $harness $layout: $result"; return 1; }
      done
    done
  done
}

@test "B9 malformed settings are unknown for both twins and all harnesses" {
  local lib harness file content result
  mkdir -p "$PROJECT_DIR/.codex"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for harness in claude codex pi; do
      file="$PROJECT_DIR/.codex/hooks.json"
      [ "$harness" != claude ] || file="$PROJECT_DIR/.claude/settings.local.json"
      printf '{}\n' > "$file"
      [ "$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")" = unarmed ] || return 1
      for content in '' 'garbage' '{"hooks":' '{}{}' 'null' '[]' '{"hooks":"str"}' '{"note":"turn-baseline.sh"' '{"note":"/bin/native/"'; do
        printf '%s\n' "$content" > "$file"
        result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
        [ "$result" = unknown ] || { echo "$lib $harness malformed $content: $result"; return 1; }
      done
    done
  done
}

@test "B9 broken secondary Claude settings and non-files are unknown" {
  local lib file="$PROJECT_DIR/.claude/settings.json" result
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    printf '{"hooks":\n' > "$file"
    [ "$(_se_turn_baseline_arming "$PROJECT_DIR" claude)" = unknown ] || return 1
    printf '{}\n' > "$file"; chmod 000 "$file"
    [ ! -r "$file" ] || skip 'requires a non-root user to make a settings file unreadable'
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"; chmod 600 "$file"
    [ "$result" = unknown ] || { echo "unreadable secondary: $result"; return 1; }
    rm -f "${file:?}"; mkdir "$file"
    [ "$(_se_turn_baseline_arming "$PROJECT_DIR" claude)" = unknown ] || return 1
    rmdir "$file"; ln -s "$BATS_TEST_TMPDIR/missing-settings" "$file"
    [ "$(_se_turn_baseline_arming "$PROJECT_DIR" claude)" = unknown ] || return 1
    rm -f "${file:?}"
  done
}

@test "B9 unavailable parser or failed settings read is unknown" {
  local lib bin="$BATS_TEST_TMPDIR/no-parser" result
  mkdir "$bin"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(PATH="$bin" _se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "missing jq: $result"; return 1; }
    result="$(grep() { return 2; }; _se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "failed grep: $result"; return 1; }
  done
}

@test "B9 missing or broken attached template or runtime cannot look unarmed" {
  local lib layout result content template="$BATS_TEST_TMPDIR/empty-runtime/core-rules/templates/claude-settings.local.json"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  mkdir -p "$PROJECT_DIR/.trellis" "$PROJECT_DIR/.claude/hooks" "${template%/*}"
  printf '# managed hook\n' > "$PROJECT_DIR/.claude/hooks/stop-verify.sh"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for layout in absent present; do
      export TRELLIS_HOME="$BATS_TEST_TMPDIR/template-home-$layout"
      mkdir -p "$TRELLIS_HOME/state"
      [ "$layout" != present ] || mkdir -p "$TRELLIS_HOME/state/attachments"
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
      [ "$result" = unknown ] || { echo "missing runtime $layout: $result"; return 1; }
      ln -s "$BATS_TEST_TMPDIR/empty-runtime" "$PROJECT_DIR/.trellis/runtime"
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
      [ "$result" = unknown ] || { echo "missing template $layout: $result"; return 1; }
      for content in '{"hooks":' '{}{}' '[]' 'null'; do
        printf '%s\n' "$content" > "$template"
        result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
        [ "$result" = unknown ] || { echo "malformed template $layout $content: $result"; return 1; }
      done
      printf '{}\n' > "$template"; chmod 000 "$template"
      [ ! -r "$template" ] || skip 'requires a non-root user to make a template unreadable'
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"; chmod 600 "$template"
      [ "$result" = unknown ] || { echo "unreadable template $layout: $result"; return 1; }
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
      [ "$result" = unarmed ] || { echo "plain template $layout: $result"; return 1; }
      rm -f "${template:?}" "${PROJECT_DIR:?}/.trellis/runtime"
    done
  done
  rm -f "${PROJECT_DIR:?}/.claude/hooks/stop-verify.sh"
  result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
  [ "$result" = unarmed ] || { echo "no harness-specific evidence: $result"; return 1; }
}

@test "B9 unused native templates and empty harness directories are unarmed" {
  local lib harness result file templates="$BATS_TEST_TMPDIR/unused-runtime/core-rules/templates"
  mkdir -p "$PROJECT_DIR/.codex" "$PROJECT_DIR/.trellis" "$templates"
  rm -f "${PROJECT_DIR:?}/.claude/settings.local.json"
  ln -s "$BATS_TEST_TMPDIR/unused-runtime" "$PROJECT_DIR/.trellis/runtime"
  for harness in claude codex; do
    if [ "$harness" = claude ]; then file=claude-settings.local.json; else file=codex-hooks.local.json; fi
    jq -n --arg h "$harness" '{hooks:{UserPromptSubmit:[{hooks:[{command:"__TRELLIS_LAUNCHER__",args:["hook","event",$h,"UserPromptSubmit"]}]}]}}' > "$templates/$file"
  done
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for harness in claude codex pi; do
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
      [ "$result" = unarmed ] || { echo "$lib unused $harness: $result"; return 1; }
    done
  done
}

@test "B9 a managed registration makes a missing template unknown" {
  local lib result
  mkdir -p "$PROJECT_DIR/.trellis"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"command":"x/.trellis/runtime/core-rules/hooks/block-destructive.sh"}]}]}}' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib managed registration: $result"; return 1; }
  done
}

@test "B9 registered Trellis hook names are evidence but user names are not" {
  local lib harness file result command
  mkdir -p "$PROJECT_DIR/.codex" "$PROJECT_DIR/.trellis"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for harness in claude codex pi; do
      file="$PROJECT_DIR/.codex/hooks.json"; command='.codex/hooks/code-review-subagent.sh'
      if [ "$harness" = claude ]; then file="$PROJECT_DIR/.claude/settings.local.json"; command='.claude/hooks/code-review-subagent.sh'; fi
      jq -n --arg cmd "$command" '{hooks:{PreToolUse:[{hooks:[{type:"command",command:$cmd}]}]}}' > "$file"
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
      [ "$result" = unknown ] || { echo "$lib $harness managed registration: $result"; return 1; }
      jq -n --arg cmd "${command%/*}/format.sh" '{hooks:{PreToolUse:[{hooks:[{type:"command",command:$cmd}]}]}}' > "$file"
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
      [ "$result" = unarmed ] || { echo "$lib $harness user registration: $result"; return 1; }
    done
  done
}

@test "B9 a dangling attachment directory with a managed hook is not unarmed" {
  local lib result
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  mkdir -p "$PROJECT_DIR/.claude/hooks"
  printf '# managed hook\n' > "$PROJECT_DIR/.claude/hooks/stop-verify.sh"
  ln -s "$BATS_TEST_TMPDIR/missing-trellis" "$PROJECT_DIR/.trellis"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib dangling attachment: $result"; return 1; }
    printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$PROJECT_DIR/.claude/settings.local.json"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib dangling legacy attachment: $result"; return 1; }
    printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  done
}

@test "B9 an unreadable or malformed settings file blocks Claude fallback Stop" {
  local file="$PROJECT_DIR/.claude/settings.local.json" layout
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  for layout in absent present; do
    export TRELLIS_HOME="$BATS_TEST_TMPDIR/stop-home-$layout"
    mkdir -p "$TRELLIS_HOME/state"
    [ "$layout" != present ] || mkdir -p "$TRELLIS_HOME/state/attachments"
    printf '%s\n' '{"native":"/bin/native/companion"}' > "$file"
    chmod 000 "$file"
    [ ! -r "$file" ] || skip 'requires a non-root user to make a settings file unreadable'
    turn_stop
    chmod 600 "$file"
    [ "$status" -eq 2 ] || { echo "unreadable $layout: $status $output"; return 1; }
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null || return 1
    printf '%s\n' '{"hooks":' > "$file"
    turn_stop
    [ "$status" -eq 2 ] || { echo "malformed $layout: $status $output"; return 1; }
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null || return 1
  done
}

@test "T62 missing native settings are unknown, not an unarmed clean turn" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  native_prompt_candidate claude
  mv "$PROJECT_DIR/.claude/settings.local.json" "$BATS_TEST_TMPDIR/removed-settings"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 native owner prevents missing render plus missing anchor from looking unarmed" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  native_prompt_candidate claude
  native_prompt_owner_record claude
  mv "$PROJECT_DIR/.claude/settings.local.json" "$BATS_TEST_TMPDIR/removed-settings"
  mv "$PROJECT_DIR/.trellis/runtime" "$BATS_TEST_TMPDIR/removed-anchor"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 owner still arms when the entire project attachment directory is missing" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  native_prompt_candidate claude
  mv "$PROJECT_DIR/.claude/settings.local.json" "$BATS_TEST_TMPDIR/removed-settings"
  mv "$PROJECT_DIR/.trellis" "$BATS_TEST_TMPDIR/removed-trellis"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 an attached native release without prompt member cannot look unarmed" {
  local source="$BATS_TEST_TMPDIR/native-payload/core-rules/templates/claude-settings.local.json" owner
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  # Retain harness-specific owner evidence but remove the native owned value.
  jq '.renders |= map(.owned_keys = [])' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  jq 'del(.hooks.UserPromptSubmit)' "$source" > "$source.next" && mv "$source.next" "$source"
  mv "$PROJECT_DIR/.claude/settings.local.json" "$BATS_TEST_TMPDIR/removed-settings"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "B9 L4 a dangling managed hook symlink is attachment evidence" {
  local lib result
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  mkdir -p "$PROJECT_DIR/.claude/hooks"
  ln -s "$BATS_TEST_TMPDIR/missing-managed-hook" "$PROJECT_DIR/.claude/hooks/stop-verify.sh"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib dangling managed hook: $result"; return 1; }
  done
}

@test "B9 L4 a lone turn-baseline hook with no legacy registration needs a template" {
  local lib result
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  mkdir -p "$PROJECT_DIR/.claude/hooks"
  printf '# managed\n' > "$PROJECT_DIR/.claude/hooks/turn-baseline.sh"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib lone baseline hook: $result"; return 1; }
  done
}

@test "B9 L4 an owned legacy harness cannot hide a missing runtime" {
  local lib owner result
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(.owned_keys = [])' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  rm -f "${PROJECT_DIR:?}/.trellis/runtime"; rmdir "$PROJECT_DIR/.trellis"
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"turn-baseline.sh"}]}]}}' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib owned legacy with missing runtime: $result"; return 1; }
  done
}

@test "B9 L4 managed evidence in a non-git project is unknown" {
  local lib result project="$BATS_TEST_TMPDIR/non-git-project"
  mkdir -p "$project/.claude/hooks" "$TRELLIS_HOME/state/attachments"
  printf '# managed\n' > "$project/.claude/hooks/stop-verify.sh"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$project" claude)"
    [ "$result" = unknown ] || { echo "$lib non-git managed hook: $result"; return 1; }
  done
}

assert_b9_owner_path_evidence() {
  local source_kind="$1" lib owner result
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  case "$source_kind" in
    artifact) jq '.renders=[] | .artifacts += [{kind:"symlink",path:".claude/rules/trellis.md",target:"/fixture"}]' "$owner" > "$owner.next" ;;
    pre-existing) jq '.renders=[] | .pre_existing=[{kind:"file",path:".claude/settings.local.json",reason:"project-authored-render",target:null}]' "$owner" > "$owner.next" ;;
  esac
  mv "$owner.next" "$owner" && chmod 600 "$owner"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  rm -f "${BATS_TEST_TMPDIR:?}/native-payload/core-rules/templates/claude-settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib $source_kind owner evidence: $result"; return 1; }
  done
}

@test "B9 L4 an owner artifact alone proves harness attachment" { assert_b9_owner_path_evidence artifact; }
@test "B9 L4 an owner pre-existing row alone proves harness attachment" { assert_b9_owner_path_evidence pre-existing; }

@test "B9 L2 escaped native markers are unknown without owner evidence" {
  local lib harness file content result
  mkdir -p "$PROJECT_DIR/.codex"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for harness in claude codex pi; do
      file="$PROJECT_DIR/.codex/hooks.json"; [ "$harness" != claude ] || file="$PROJECT_DIR/.claude/settings.local.json"
      for content in '{"note":"\/bin\/native\/companion"}' '{"note":"\u002fbin\u002fnative\u002fcompanion"}'; do
        printf '%s\n' "$content" > "$file"
        result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
        [ "$result" = unknown ] || { echo "$lib $harness escaped native marker: $result"; return 1; }
      done
      printf '%s\n' '{"note":"\/bin\/other\/companion"}' > "$file"
      result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
      [ "$result" = unarmed ] || { echo "$lib $harness unrelated escape: $result"; return 1; }
    done
  done
}

@test "B9 L2 an escaped native marker blocks Claude fallback Stop" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  printf '%s\n' '{"note":"\/bin\/native\/companion"}' > "$PROJECT_DIR/.claude/settings.local.json"
  turn_stop
  [ "$status" -eq 2 ] || { echo "escaped Claude Stop: $status $output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "B9 L1 unsearchable or unreadable harness directories are unknown" {
  local lib harness directory mode result
  mkdir -p "$PROJECT_DIR/.codex"
  printf '{}\n' > "$PROJECT_DIR/.codex/hooks.json"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for harness in claude codex pi; do
      directory="$PROJECT_DIR/.codex"; [ "$harness" != claude ] || directory="$PROJECT_DIR/.claude"
      for mode in 000 300 600; do
        chmod "$mode" "$directory"
        if [ -r "$directory" ] && [ -x "$directory" ]; then chmod 700 "$directory"; skip 'requires non-root permission checks'; fi
        result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
        chmod 700 "$directory"
        [ "$result" = unknown ] || { echo "$lib $harness directory $mode: $result"; return 1; }
      done
    done
  done
}

@test "B9 L1 inaccessible attachment state ancestors cannot look unarmed" {
  local lib owner checkout directory mode result
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  checkout="$(dirname "$owner")"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    for directory in "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/attachments" "$checkout"; do
      for mode in 000 300 600; do
        chmod "$mode" "$directory"
        if [ -r "$directory" ] && [ -x "$directory" ]; then chmod 700 "$directory"; skip 'requires non-root permission checks'; fi
        result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
        chmod 700 "$directory"
        [ "$result" = unknown ] || { echo "$lib $directory $mode: $result"; return 1; }
      done
    done
  done
}

@test "B9 L1 inaccessible hooks and home ancestors are not absence" {
  local lib result blocked="$BATS_TEST_TMPDIR/blocked-home"
  mkdir -p "$PROJECT_DIR/.claude/hooks" "$blocked/trellis/state/attachments"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    chmod 600 "$PROJECT_DIR/.claude/hooks"
    [ ! -x "$PROJECT_DIR/.claude/hooks" ] || { chmod 700 "$PROJECT_DIR/.claude/hooks"; skip 'requires non-root permission checks'; }
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    chmod 700 "$PROJECT_DIR/.claude/hooks"
    [ "$result" = unknown ] || { echo "$lib blocked hooks: $result"; return 1; }
    export TRELLIS_HOME="$blocked/trellis"
    chmod 600 "$blocked"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    chmod 700 "$blocked"
    [ "$result" = unknown ] || { echo "$lib blocked home ancestor: $result"; return 1; }
  done
}

@test "B9 L1 absent harness and attachment directories remain unarmed" {
  local lib result
  rm -rf "${PROJECT_DIR:?}/.claude" "${TRELLIS_HOME:?}"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unarmed ] || { echo "$lib absent directories: $result"; return 1; }
  done
}

@test "B9 L1 an unsearchable Claude directory blocks fallback Stop" {
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  chmod 600 "$PROJECT_DIR/.claude"
  [ ! -x "$PROJECT_DIR/.claude" ] || { chmod 700 "$PROJECT_DIR/.claude"; skip 'requires non-root permission checks'; }
  run --separate-stderr bash "$STOP_HOOK" <<<"$(stop_payload)"
  chmod 700 "$PROJECT_DIR/.claude"
  [ "$status" -eq 2 ] || { echo "unsearchable Claude Stop: $status $output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "B9 Pi compatibility Stop permits an unrelated user Codex hook" {
  local owner target="$BATS_TEST_TMPDIR/pi-extension.js"
  ( cd "$PROJECT_DIR" && git add -A && git commit -q -m clean-start )
  native_prompt_candidate codex
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  printf '// Pi extension fixture\n' > "$target"
  jq --arg target "$target" '.renders=[] | .artifacts += [{kind:"symlink",path:".pi/extensions/trellis",target:$target}]' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  native_prompt_ok_verdict
  mkdir -p "$PROJECT_DIR/.codex/hooks" "$PROJECT_DIR/.pi/extensions"
  ln -s "$target" "$PROJECT_DIR/.pi/extensions/trellis"
  printf '#!/bin/sh\nexit 0\n' > "$PROJECT_DIR/.codex/hooks/notify.sh"
  jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:".codex/hooks/notify.sh"}]}]}}' > "$PROJECT_DIR/.codex/hooks.json"
  printf '/.codex/hooks/\n/.pi/\n' >> "$PROJECT_DIR/.git/info/exclude"
  run env TRELLIS_HARNESS=pi CODEX_PROJECT_DIR="$PROJECT_DIR" bash "$CODEX_HOOKS_DIR/stop-verify.sh" <<<"$(stop_payload)"
  [ "$status" -eq 0 ] || { echo "Pi Stop status: $status $output"; return 1; }
  [[ "$output" != *'"decision"'* ]] || { echo "Pi Stop blocked user hook: $output"; return 1; }
}

@test "B9 owner-only harness evidence makes a missing template unknown" {
  local owner result lib
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(.owned_keys = [])' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  printf '{}\n' > "$PROJECT_DIR/.claude/settings.local.json"
  rm -f "${BATS_TEST_TMPDIR:?}/native-payload/core-rules/templates/claude-settings.local.json"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib owner-only missing template: $result"; return 1; }
  done
}

@test "B9 a native owner for another harness cannot authorize Claude" {
  local owner result lib
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders=[]' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib owner without Claude render: $result"; return 1; }
  done
}

@test "B9 another Claude artifact cannot replace the owned native render" {
  local owner result lib
  native_prompt_candidate claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders=[] | .artifacts += [{kind:"symlink",path:".claude/rules/trellis.md",target:"/fixture"}]' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  for lib in "$HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps.sh"; do
    source "$lib"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" claude)"
    [ "$result" = unknown ] || { echo "$lib owner without settings render: $result"; return 1; }
  done
}

@test "T62 native registration with missing owner is unknown, not verified" {
  local owner
  native_prompt_candidate claude
  native_prompt_owner_record claude
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  [ -n "$owner" ]
  mv "$owner" "$BATS_TEST_TMPDIR/removed-owner"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 ACL listing parser refuses ACL rows and ambiguous output" {
  local good='drwx------ 1 owner group 42 Jan 1 12:00 /tmp/with spaces'
  local xattr='drwx------@ 1 owner group 42 Jan 1 12:00 /tmp/xattr'
  source "$HOOKS_DIR/lib/deps.sh"
  _se_acl_listing_safe "$good" 1 || return 1
  _se_acl_listing_safe "$xattr" 1 || return 1
  _se_acl_listing_safe "$good"$'\n'"$xattr" 2 || return 1
  ! _se_acl_listing_safe 'drwx------+ 1 owner group 42 Jan 1 12:00 /tmp/acl' 1 || return 1
  ! _se_acl_listing_safe "$xattr"$'\n'' 0: everyone allow write' 1 || return 1
  ! _se_acl_listing_safe 'drwx------ malformed' 1 || return 1
  ! _se_acl_listing_safe "$good" 2 || return 1
  ! _se_acl_listing_safe '' 1 || return 1
}

native_acl_add() {
  local path="$1"
  case "$(uname -s)" in
    Darwin)
      if [ -d "$path" ]; then chmod +a 'everyone allow add_file,delete_child' "$path" 2>/dev/null
      else chmod +a 'everyone allow write' "$path" 2>/dev/null; fi ;;
    Linux)
      command -v setfacl >/dev/null 2>&1 || skip 'setfacl unavailable'
      setfacl -m "u:$(id -u):r,m::---" "$path" 2>/dev/null ;;
    *) skip 'ACL fixture unsupported' ;;
  esac
}
native_acl_clear() {
  case "$(uname -s)" in Darwin) chmod -N "$1" ;; Linux) setfacl -b "$1" ;; esac
}
assert_native_acl_is_unknown() {
  local harness="$1" owner companion path state result hook digest_dir target_dir version_dir
  native_prompt_candidate "$harness"
  owner="$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json')"
  companion="$(find "$TRELLIS_HOME/bin/native" -type f -name trellis-hooks)"
  [ -n "$owner" ] && [ -n "$companion" ]
  digest_dir="${companion%/*}"; target_dir="${digest_dir%/*}"; version_dir="${target_dir%/*}"
  source "$HOOKS_DIR/lib/deps.sh"
  [ "$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")" = native ]
  hook="$HOOKS_DIR/stop-verify.sh"; [ "$harness" = claude ] || hook="$CODEX_HOOKS_DIR/stop-verify.sh"
  for path in "$TRELLIS_HOME" "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/attachments" "${owner%/*}" "$owner" \
    "$TRELLIS_HOME/bin" "$TRELLIS_HOME/bin/native" "$version_dir" "$target_dir" "$digest_dir" "$companion"; do
    native_acl_add "$path" || skip 'ACLs unavailable on test filesystem'
    state="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
    [ "$state" = unknown ] || { echo "$harness ACL on $path gave $state"; return 1; }
    run bash "$hook" <<<"$(stop_payload)"
    if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1; else [ "$status" -eq 0 ] || return 1; fi
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null || return 1
    native_acl_clear "$path"
    result="$(_se_turn_baseline_arming "$PROJECT_DIR" "$harness")"
    [ "$result" = native ] || { echo "$harness after ACL removal: $result"; return 1; }
  done
}

@test "T62 Claude native owner and companion ACLs are unknown" {
  assert_native_acl_is_unknown claude
}
@test "T62 Codex native owner and companion ACLs are unknown" {
  assert_native_acl_is_unknown codex
}

@test "T62 unsafe native companion directory is unknown" {
  native_prompt_candidate claude
  chmod 755 "$TRELLIS_HOME/bin/native"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 stale native companion blocks before a valid baseline can be reused" {
  local companion
  native_prompt_candidate claude
  turn_entry
  companion="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].args[4]' "$PROJECT_DIR/.claude/settings.local.json")"
  chmod u+w "$companion"; printf 'tamper' >> "$companion"; chmod 500 "$companion"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 duplicate native settings keys are unknown to Stop" {
  local file="$PROJECT_DIR/.claude/settings.local.json" hooks
  native_prompt_candidate claude
  hooks="$(jq -c '.hooks' "$file")"
  printf '{"hooks":{},"hooks":%s}\n' "$hooks" > "$file"
  turn_stop
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null
}

@test "T62 incomplete native timeout or onFailure is unknown" {
  local file="$PROJECT_DIR/.claude/settings.local.json" original="$BATS_TEST_TMPDIR/original.json" mutation
  native_prompt_candidate claude
  cp "$file" "$original"
  for mutation in '(.hooks.UserPromptSubmit[0].hooks[0].timeout) = 5' \
    '(.hooks.UserPromptSubmit[0].hooks[0].timeout) = 30.5' 'del(.hooks.UserPromptSubmit[0].hooks[0].onFailure)'; do
    jq "$mutation" "$original" > "$file"
    turn_stop
    [ "$status" -eq 2 ] || { echo "$mutation: status=$status output=$output"; return 1; }
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | startswith("turn-baseline:"))' >/dev/null || {
      echo "$mutation: not an arming block: $output"; return 1;
    }
  done
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

@test "T28 consumed prompt is replaced, not retained alongside the carry" {
  local file prompt carry
  turn_entry
  file="$(baseline_file)"
  prompt="$(<"$file")"
  turn_stop
  assert_no_receipt_demand
  carry="$(<"$file")"
  [[ "$carry" = 'trellis-turn-carry v2 '* ]] || { echo "not a carry: $carry"; return 1; }
  [ "$(printf '%s\n' "$carry" | wc -l | tr -d ' ')" = 1 ] || { echo 'consumed prompt was retained'; return 1; }
  [ "$(printf '%s\n' "$prompt" | awk '{print $3}')" != "$(printf '%s\n' "$carry" | awk '{print $3}')" ]
}

@test "T28 replaying a consumed prompt cannot waive the receipt" {
  local file prompt
  turn_entry
  file="$(baseline_file)"
  prompt="$(<"$file")"
  turn_stop
  assert_no_receipt_demand
  # Restore the exact prior line with its original, now-consumed nonce. This
  # tests nonce consumption separately from removal of the baseline file.
  printf '%s\n' "$prompt" > "$file"
  turn_stop
  assert_receipt_demanded
}

@test "T28 consuming one session preserves another session nonce" {
  local file nonce1 nonce2 log
  turn_entry sess-1
  file="$(baseline_file)"
  nonce1="$(awk '{print $3}' "$file")"
  log="${file%/*}/nonces.log"
  turn_entry sess-2
  nonce2="$(awk -v n="$nonce1" '$2 != n {print $2}' "$log")"
  [ "${#nonce2}" -eq 32 ] || { echo 'second session nonce missing'; return 1; }
  turn_stop sess-1
  assert_no_receipt_demand
  ! grep -q " $nonce1\$" "$log" || { echo 'consumed nonce survived'; return 1; }
  grep -q " $nonce2\$" "$log" || { echo 'another session nonce was removed'; return 1; }
}

@test "T28 a nonce from another session cannot validate this prompt" {
  local file nonce1 nonce2 log
  turn_entry sess-1
  file="$(baseline_file)"
  nonce1="$(awk '{print $3}' "$file")"
  log="${file%/*}/nonces.log"
  turn_entry sess-2
  nonce2="$(awk -v n="$nonce1" '$2 != n {print $2}' "$log")"
  [ "${#nonce2}" -eq 32 ] || { echo 'second session nonce missing'; return 1; }
  awk -v n="$nonce2" '{ $3 = n; print }' "$file" > "$file.next" && mv "$file.next" "$file"
  turn_stop sess-1
  assert_receipt_demanded
  grep -q " $nonce2\$" "$log" || { echo 'another session nonce was removed'; return 1; }
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
  rm -f "${PROJECT_DIR:?}/.claude/settings.local.json"
  ( cd "$PROJECT_DIR" && git add -A && git commit -qm clean-start )
  turn_stop
  assert_no_receipt_demand
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
  # T34: the project template routes UserPromptSubmit through the native
  # entry (member turn-baseline); its shell registration is pinned in the
  # legacy surface, which the fallback render uses.
  local template
  for template in legacy-hooks/claude-settings.local.json templates/claude-settings.json; do
    jq -e '
      [.hooks.UserPromptSubmit[]?.hooks[]? | (.args // [.command]) | last
       | select(endswith("/turn-baseline.sh\"") or endswith("/turn-baseline.sh"))]
      | length == 1
    ' "$HOOKS_DIR/../$template" >/dev/null || { echo "not wired once: $template"; return 1; }
    jq -e '[.. | strings | select(contains("turn-baseline.sh"))] | length == 1' \
      "$HOOKS_DIR/../$template" >/dev/null || { echo "wired elsewhere too: $template"; return 1; }
  done
  jq -e '[.hooks.UserPromptSubmit[]?.hooks[]? | .args // [] | select(index("UserPromptSubmit"))] | length == 1' \
    "$HOOKS_DIR/../templates/claude-settings.local.json" >/dev/null || { echo "native UserPromptSubmit not wired once"; return 1; }
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

@test "bug #6: a doc-only edit on a dirty tree runs no typecheck, lint or test" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "bug #6: a no-op turn with doc-only dirt runs no typecheck, lint or test" {
  suite_project
  clean_code_dirt
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_entry
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "bug #6: a code edit still runs the checks and demands a receipt" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'x\n' >> "$PROJECT_DIR/lib.js"
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_demanded
}

@test "bug #6: a committed code change plus doc dirt still runs the checks" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'x\n' >> "$PROJECT_DIR/lib.js"
  ( cd "$PROJECT_DIR" && git add lib.js && git commit -q -m "code change" )
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_demanded
}

@test "bug #6: pre-existing dirty code does not rerun checks on a known no-op turn" {
  suite_project
  turn_entry
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "bug #6: committed code with a clean tree still runs checks" {
  suite_project
  clean_code_dirt
  turn_entry
  printf 'new code\n' >> "$PROJECT_DIR/lib.js"
  ( cd "$PROJECT_DIR" && git add lib.js && git commit -q -m "code committed this turn" )
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_demanded
}

@test "bug #6: a committed code-to-doc rename plus doc dirt still runs checks" {
  suite_project
  clean_code_dirt
  turn_entry
  ( cd "$PROJECT_DIR" && git mv lib.js guide.md && git commit -q -m "rename code to doc" )
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
  assert_receipt_demanded
}

@test "bug #6: a new doc in a new directory runs no typecheck, lint or test" {
  suite_project
  clean_code_dirt
  turn_entry
  mkdir -p "$PROJECT_DIR/docs/new"
  printf 'notes\n' > "$PROJECT_DIR/docs/new/guide.md"
  turn_stop
  assert_no_receipt_demand
  assert_no_heavy_checks
}

@test "bug #6: a staged code-to-doc rename still runs the checks" {
  suite_project
  clean_code_dirt
  turn_entry
  ( cd "$PROJECT_DIR" && git mv lib.js guide.md )
  turn_stop
  assert_heavy_checks_ran
}

@test "bug #6: an unknown baseline keeps the checks on doc-only dirt" {
  suite_project
  clean_code_dirt
  printf 'notes\n' > "$PROJECT_DIR/notes.md"
  turn_stop
  assert_heavy_checks_ran
}

# Merge of fx1 turn-start with B9 locking: a prompt that cannot take the nonce
# lock still starts a fresh turn-start, marked unknown, and a carry that cannot
# take it leaves no turn-start, so decision-receipt runs its gate.
assert_turn_start_fails_closed_on_lock() {
  local lib="$1"/lib/deps.sh harness="$2" state key ts lock
  state="$(bash -c 'source "$1"; _se_turn_state_dir "$2"' _ "$lib" "$PROJECT_DIR")"
  key="$(bash -c 'source "$1"; _se_state_key "" "$2"' _ "$lib" 'fx1-merge')"
  ts="$state/turn-start.$harness.$key"; lock="$state/.nonces.lock"
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" fx1-merge' _ "$lib" "$PROJECT_DIR" "$harness"
  [ "$(grep -c '^trellis-turn-baseline v2 [0-9a-f]\{32\} ' "$ts")" = 1 ] || { echo "$harness: no baseline in turn-start"; return 1; }
  bash -c 'source "$1"; _se_turn_carry_write "$2" "$3" "$4"' _ "$lib" "$state" "$harness.$key" "$PROJECT_DIR"
  [[ "$(tail -n 1 "$ts")" == 'trellis-turn-carry v2 '* ]] || { echo "$harness: carry missing from turn-start"; return 1; }
  mkdir "$lock"
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" fx1-merge' _ "$lib" "$PROJECT_DIR" "$harness" || true
  [ "$(cat "$ts")" = 'trellis-turn-baseline v2 unknown' ] || { echo "$harness: locked prompt kept: $(cat "$ts")"; return 1; }
  rmdir "$lock"
  bash -c 'source "$1"; _se_turn_baseline_publish "$2" "$3" fx1-merge' _ "$lib" "$PROJECT_DIR" "$harness"
  mkdir "$lock"
  bash -c 'source "$1"; _se_turn_carry_write "$2" "$3" "$4"' _ "$lib" "$state" "$harness.$key" "$PROJECT_DIR" 2>/dev/null
  rmdir "$lock"
  [ ! -e "$ts" ] || { echo "$harness: locked carry kept turn-start: $(cat "$ts")"; return 1; }
}
@test "fx1 merge: turn-start fails closed when the nonce lock is held (Claude)" {
  assert_turn_start_fails_closed_on_lock "$HOOKS_DIR" claude
}
@test "fx1 merge: turn-start fails closed when the nonce lock is held (Codex)" {
  assert_turn_start_fails_closed_on_lock "$CODEX_HOOKS_DIR" codex
}
