#!/usr/bin/env bats
# Tests for lib/verification-receipt.sh — durable executed-verification evidence
# (spec 045 T6 phase 1) — exercised through the REAL Stop and SessionStart
# adapters on both harnesses, never by writing receipts by hand.
#
# Every producing test drives a counting fake verifier: the command must run on
# every call (there is no cache), its real exit status must survive, and the
# caller's existing slicing/blocking logic must see byte-identical output.

load helpers

CORE_LIB="$HOOKS_DIR/lib/verification-receipt.sh"

setup() {
  setup_project_dir
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  FAKE_STATE="$BATS_TEST_TMPDIR/fake-state"
  mkdir -p "$FAKE_BIN" "$FAKE_STATE"
}

teardown() {
  teardown_project_dir
}

# --- fixtures ---------------------------------------------------------------

# A counting fake verifier. Records every invocation, replays a configured
# stdout body, and exits with a configured status.
make_fake_tool() {
  local name="$1"
  cat > "$FAKE_BIN/$name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_STATE/calls"
if [ -f "$FAKE_STATE/out" ]; then cat "$FAKE_STATE/out"; fi
exit "$(cat "$FAKE_STATE/exit" 2>/dev/null || printf 0)"
EOF
  chmod +x "$FAKE_BIN/$name"
}

fake_out()  { printf '%s' "$1" > "$FAKE_STATE/out"; }
fake_exit() { printf '%s' "$1" > "$FAKE_STATE/exit"; }
call_count() { awk 'END{print NR}' "$FAKE_STATE/calls" 2>/dev/null || printf 0; }

# Deploy hooks the way the inheritance manifest delivers them: the harness's own
# hook scripts plus lib/, with the SHARED verification-receipt.sh copied in from
# core-rules/hooks/lib (Claude source_children; Codex/Pi explicit link rows).
# with_lib=0 reproduces a checkout where that link is missing.
deploy_hooks() {
  local harness="$1" with_lib="${2:-1}" src deploy
  deploy="$BATS_TEST_TMPDIR/$harness/hooks"
  if [ "$harness" = claude ]; then src="$HOOKS_DIR"; else src="$CODEX_HOOKS_DIR"; fi
  mkdir -p "$deploy/lib"
  cp "$src/stop-verify.sh" "$deploy/stop-verify.sh"
  cp "$src/session-context.sh" "$deploy/session-context.sh"
  cp "$src/lib/deps.sh" "$deploy/lib/deps.sh"
  cp "$src/lib/pm.sh" "$deploy/lib/pm.sh"
  cp "$src/lib/autonomy.sh" "$deploy/lib/autonomy.sh"
  if [ "$with_lib" = 1 ]; then
    cp "$CORE_LIB" "$deploy/lib/verification-receipt.sh"
  fi
  printf '%s' "$deploy"
}

# An argv-form check: ruff.toml + a fake `ruff` binary → `lint.ruff`.
seed_argv_check() {
  make_fake_tool ruff
  printf '' > "$PROJECT_DIR/ruff.toml"
  echo x > "$PROJECT_DIR/scratch.txt"
}

# A legacy-shell-form check: package.json test script + a fake `npm` →
# TEST_CMD="npm run test", run through the existing `eval`.
seed_shell_check() {
  make_fake_tool npm
  cat > "$PROJECT_DIR/package.json" <<'EOF'
{"name":"fixture","scripts":{"test":"exit 0"}}
EOF
  echo x > "$PROJECT_DIR/scratch.txt"
}

run_stop() {
  local hook="$1"; shift
  local err="$BATS_TEST_TMPDIR/stop.stderr"
  set +e
  output="$(printf '%s' '{}' | env PATH="$FAKE_BIN:$PATH" \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR" \
    PROCESS_GATE_NO_RECEIPTS=1 FAKE_STATE="$FAKE_STATE" "$@" \
    bash "$hook" 2>"$err")"
  status=$?
  set -e
  stderr="$(cat "$err")"
}

run_session() {
  local hook="$1"; shift
  local err="$BATS_TEST_TMPDIR/session.stderr"
  set +e
  output="$(printf '%s' '{"source":"startup"}' | env PATH="$FAKE_BIN:$PATH" \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" CODEX_PROJECT_DIR="$PROJECT_DIR" "$@" \
    bash "$hook" 2>"$err")"
  status=$?
  set -e
  stderr="$(cat "$err")"
  CONTEXT="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

state_root() {
  local dir="${1:-$PROJECT_DIR}" common
  common="$(git -C "$dir" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$dir/$common" ;; esac
  printf '%s/trellis-verification-receipts' "$(cd "$common" && pwd -P)"
}

# Producer-owned artifacts only: the planted foreign entries in the pruning test
# are also *.json, and must not be counted as receipts.
receipts() {
  local root; root="$(state_root "${1:-$PROJECT_DIR}")"
  ls -1 "$root" 2>/dev/null \
    | grep -E '^[0-9a-f]{16}\.[0-9]{8}T[0-9]{6}Z\..+\.json$' \
    | sed "s#^#$root/#" || true
}

one_receipt() { receipts "$@" | head -1; }
receipt_count() { receipts "$@" | awk 'END{print NR}'; }

file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

# --- producer: argv form ----------------------------------------------------

@test "argv check writes an executed, non-reusable receipt with the real argv" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
  [ "$(receipt_count)" -eq 1 ]

  local r; r="$(one_receipt)"
  [ "$(jq -r '.schema_version' "$r")" = "1" ]
  [ "$(jq -r '.executed' "$r")" = "true" ]
  [ "$(jq -r '.check_id' "$r")" = "lint.ruff" ]
  [ "$(jq -r '.command.form' "$r")" = "argv" ]
  [ "$(jq -r '.command.argv | join(" ")' "$r")" = "ruff check ." ]
  [ "$(jq -r '.command.shell' "$r")" = "null" ]
  [ "$(jq -r '.exit_status' "$r")" = "0" ]
  [ "$(jq -r '.harness' "$r")" = "claude" ]
  [ "$(jq -r '.reusable' "$r")" = "false" ]
  [ "$(jq -r '.reusable_reason' "$r")" = "open-contract" ]
  [ "$(jq -r '.cwd' "$r")" = "$(cd "$PROJECT_DIR" && pwd -P)" ]
  [ "$(jq -r '.roots.worktree_root' "$r")" = "$(cd "$PROJECT_DIR" && pwd -P)" ]
  [ "$(jq -r '.head' "$r")" = "$(git -C "$PROJECT_DIR" rev-parse HEAD)" ]
  jq -e '.started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$r" >/dev/null
  jq -e '.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$r" >/dev/null

  [ "$(file_mode "$r")" = "600" ]
  [ "$(file_mode "$(state_root)")" = "700" ]
}

@test "a failing argv check still blocks, and its receipt records the failure" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 3
  fake_out "boom"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "block" ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "lint (ruff): boom" ]

  local r; r="$(one_receipt)"
  [ "$(jq -r '.exit_status' "$r")" = "3" ]
  [ "$(jq -r '.executed' "$r")" = "true" ]
  [ "$(jq -r '.output.text' "$r")" = "boom" ]
}

@test "the command runs again on every call — receipts are never a cache" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]

  [ "$(call_count)" -eq 3 ]
  [ "$(receipt_count)" -eq 3 ]
}

@test "typecheck/lint slicing is unchanged: first 30 lines of real output" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 1
  local body=""
  local i
  for i in $(seq 1 40); do body="${body}L${i}
"; done
  printf '%s' "$body" > "$FAKE_STATE/out"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 2 ]
  local reason; reason="$(printf '%s' "$output" | jq -r '.reason')"
  printf '%s\n' "$reason" | grep -qx 'lint (ruff): L1'
  printf '%s\n' "$reason" | grep -qx 'L30'
  ! printf '%s\n' "$reason" | grep -qx 'L31'
}

# --- producer: legacy shell form --------------------------------------------

@test "legacy shell form is recorded as legacy-shell, not reinterpreted as argv" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_shell_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
  grep -qx 'run test' "$FAKE_STATE/calls"

  local r; r="$(one_receipt)"
  [ "$(jq -r '.check_id' "$r")" = "test" ]
  [ "$(jq -r '.command.form' "$r")" = "legacy-shell" ]
  [ "$(jq -r '.command.shell' "$r")" = "npm run test" ]
  [ "$(jq -r '.command.argv' "$r")" = "null" ]
}

@test "test slicing is unchanged: last 30 lines of real output" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_shell_check
  fake_exit 1
  local body="" i
  for i in $(seq 1 40); do body="${body}L${i}
"; done
  printf '%s' "$body" > "$FAKE_STATE/out"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 2 ]
  local reason; reason="$(printf '%s' "$output" | jq -r '.reason')"
  printf '%s\n' "$reason" | grep -qx 'test (npm run test): L11'
  printf '%s\n' "$reason" | grep -qx 'L40'
  ! printf '%s\n' "$reason" | grep -qx 'L10'
}

# --- producer: the Codex Stop adapter ---------------------------------------

@test "the Codex Stop adapter produces receipts too, stamped with its harness" {
  local hooks; hooks="$(deploy_hooks codex)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]

  local r; r="$(one_receipt)"
  [ "$(jq -r '.harness' "$r")" = "codex" ]
  [ "$(jq -r '.check_id' "$r")" = "lint.ruff" ]
}

@test "TRELLIS_HARNESS=pi stamps the Pi harness through the shared Codex adapter" {
  local hooks; hooks="$(deploy_hooks codex)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh" TRELLIS_HARNESS=pi
  [ "$status" -eq 0 ]
  [ "$(jq -r '.harness' "$(one_receipt)")" = "pi" ]
}

@test "canonical Codex payload records and reads evidence from the single shared library" {
  local payload hooks
  payload="$BATS_TEST_TMPDIR/payload/core-rules"
  hooks="$payload/codex/hooks"
  mkdir -p "$payload/codex" "$payload/hooks/lib"
  cp -R "$CODEX_HOOKS_DIR" "$hooks"
  cp "$CORE_LIB" "$payload/hooks/lib/verification-receipt.sh"
  [ ! -e "$hooks/lib/verification-receipt.sh" ]
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
  [ "$(receipt_count)" -eq 1 ]
  [ "$(jq -r '.harness' "$(one_receipt)")" = codex ]

  run_session "$hooks/session-context.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$CONTEXT" | grep -q 'historical execution; current applicability unknown; reusable:no'
  printf '%s\n' "$CONTEXT" | grep -q '^- lint.ruff: exit 0 (codex, HEAD '
}

# --- readers ----------------------------------------------------------------

@test "a Claude-produced receipt is visible through BOTH active-worktree readers" {
  local claude codex
  claude="$(deploy_hooks claude)"
  codex="$(deploy_hooks codex)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$claude/stop-verify.sh"
  [ "$status" -eq 0 ]

  run_session "$claude/session-context.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$CONTEXT" | grep -q 'historical execution; current applicability unknown; reusable:no'
  printf '%s\n' "$CONTEXT" | grep -q '^- lint.ruff: exit 0 (claude, HEAD '

  run_session "$codex/session-context.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$CONTEXT" | grep -q 'historical execution; current applicability unknown; reusable:no'
  printf '%s\n' "$CONTEXT" | grep -q '^- lint.ruff: exit 0 (claude, HEAD '
}

@test "readers present at most three summaries" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  local i
  for i in 1 2 3 4 5; do run_stop "$hooks/stop-verify.sh"; [ "$status" -eq 0 ]; done
  [ "$(receipt_count)" -eq 5 ]

  run_session "$hooks/session-context.sh"
  [ "$(printf '%s\n' "$CONTEXT" | grep -c '^- lint.ruff: exit 0')" -eq 3 ]
}

@test "readers never replay raw output or a thinking sentinel into context" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out 'SENTINEL_RAW_OUTPUT_MUST_NOT_REACH_CONTEXT
<thinking>SENTINEL_THINKING_MUST_NOT_REACH_CONTEXT</thinking>'

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]

  # The raw output IS retained privately in the receipt...
  grep -q 'SENTINEL_RAW_OUTPUT_MUST_NOT_REACH_CONTEXT' "$(one_receipt)"

  # ...and must never appear in what either reader hands the model.
  run_session "$hooks/session-context.sh"
  ! printf '%s' "$output" | grep -q 'SENTINEL_RAW_OUTPUT_MUST_NOT_REACH_CONTEXT'
  ! printf '%s' "$output" | grep -q 'SENTINEL_THINKING_MUST_NOT_REACH_CONTEXT'

  local codex; codex="$(deploy_hooks codex)"
  run_session "$codex/session-context.sh"
  ! printf '%s' "$output" | grep -q 'SENTINEL_RAW_OUTPUT_MUST_NOT_REACH_CONTEXT'
  ! printf '%s' "$output" | grep -q 'SENTINEL_THINKING_MUST_NOT_REACH_CONTEXT'
}

@test "a tampered retained output is not evidence" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out "original output"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]

  local r; r="$(one_receipt)"
  jq '.output.text = "tampered output"' "$r" > "$r.tmp" && mv "$r.tmp" "$r"

  run_session "$hooks/session-context.sh"
  ! printf '%s\n' "$CONTEXT" | grep -q '^- lint.ruff:'
  printf '%s\n' "$CONTEXT" | grep -q 'Verification receipts: unavailable'
}

@test "a retained receipt whose output went missing is not evidence" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out "original output"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]

  local r; r="$(one_receipt)"
  jq 'del(.output.text)' "$r" > "$r.tmp" && mv "$r.tmp" "$r"

  run_session "$hooks/session-context.sh"
  ! printf '%s\n' "$CONTEXT" | grep -q '^- lint.ruff:'
  printf '%s\n' "$CONTEXT" | grep -q 'Verification receipts: unavailable'
}

@test "a receipt bound to another worktree is not evidence in this one" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(receipt_count)" -eq 1 ]

  local other="$BATS_TEST_TMPDIR/other-worktree"
  git -C "$PROJECT_DIR" worktree add -q -b other "$other"

  # Same Git common directory, so the SAME receipt store — the binding, not the
  # location, is what keeps the two worktrees apart.
  [ "$(state_root "$other")" = "$(state_root "$PROJECT_DIR")" ]

  PROJECT_DIR="$other" run_session "$hooks/session-context.sh"
  local ctx
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  ! printf '%s\n' "$ctx" | grep -q '^- lint.ruff:'
  printf '%s\n' "$ctx" | grep -q 'Verification receipts: unavailable'
}

# --- output cap -------------------------------------------------------------

@test "oversize output is omitted with a byte count, never presented as complete" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  head -c 70000 /dev/zero | tr '\0' 'x' > "$FAKE_STATE/out"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]

  local r; r="$(one_receipt)"
  [ "$(jq -r '.output.retained' "$r")" = "false" ]
  [ "$(jq -r '.output.text' "$r")" = "null" ]
  [ "$(jq -r '.output.bytes' "$r")" = "70000" ]
  jq -e '.output.omitted_reason | test("70000") and test("65536")' "$r" >/dev/null
  # The integrity hash of the FULL output is still recorded.
  jq -e '.output.sha256 | test("^[0-9a-f]{64}$")' "$r" >/dev/null

  # Still valid evidence for the reader — the omission is stated, not implied.
  run_session "$hooks/session-context.sh"
  printf '%s\n' "$CONTEXT" | grep -q '^- lint.ruff: exit 0'
}

# --- unsafe / unavailable state ---------------------------------------------

@test "a symlinked receipt destination is refused, and the check still runs" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  local decoy="$BATS_TEST_TMPDIR/decoy"
  mkdir -p "$decoy"
  ln -s "$decoy" "$(state_root)"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q 'durable evidence unavailable'
  printf '%s\n' "$stderr" | grep -q 'symlink'
  # Nothing was written through the symlink.
  [ -z "$(ls -A "$decoy")" ]
}

@test "a group/other-writable receipt destination is refused without being repaired" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  local root; root="$(state_root)"
  mkdir -p "$root"
  chmod 777 "$root"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" | grep -q 'group/other-writable'
  [ "$(receipt_count)" -eq 0 ]
  # Pre-existing user permissions are reported, never "fixed".
  [ "$(file_mode "$root")" = "777" ]
}

@test "unavailable persistence degrades visibly and preserves the check's failure" {
  if [ "$(id -u)" = "0" ]; then skip "root ignores directory permissions"; fi
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 4
  fake_out "still failing"

  local root; root="$(state_root)"
  mkdir -p "$root"
  chmod 500 "$root"

  run_stop "$hooks/stop-verify.sh"
  chmod 700 "$root"

  # The check ran, and its failure still blocks with the unchanged reason.
  [ "$(call_count)" -eq 1 ]
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "lint (ruff): still failing" ]
  # The recording failure is stated on its own channel, not folded into the
  # block reason and not hidden in output the caller discards.
  printf '%s\n' "$stderr" | grep -q 'durable evidence unavailable'
  ! printf '%s' "$output" | grep -q 'durable evidence unavailable'
  [ "$(receipt_count)" -eq 0 ]
}

@test "a missing shared library degrades visibly and never fakes a green check" {
  local hooks; hooks="$(deploy_hooks claude 0)"
  seed_argv_check
  fake_exit 5
  fake_out "real failure"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 2 ]
  [ "$(call_count)" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "lint (ruff): real failure" ]
  printf '%s\n' "$stderr" | grep -q 'missing sibling lib'
  [ "$(receipt_count)" -eq 0 ]

  run_session "$hooks/session-context.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$CONTEXT" | grep -q 'Verification receipts: unavailable (missing sibling lib'
}

@test "a missing shared library degrades the same way on the Codex adapters" {
  local hooks; hooks="$(deploy_hooks codex 0)"
  seed_argv_check
  fake_exit 5
  fake_out "real failure"

  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 2 ]
  [ "$(call_count)" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "lint (ruff): real failure" ]
  printf '%s\n' "$stderr" | grep -q 'missing sibling lib'

  run_session "$hooks/session-context.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$CONTEXT" | grep -q 'Verification receipts: unavailable (missing sibling lib'
}

# Every mutation starts from an actual Stop receipt, with a positive reader
# control before mutation. A fixture/setup failure must never look like rejection.
mutation_fixture() {
  CLAUDE_HOOKS="$(deploy_hooks claude)"
  CODEX_HOOKS="$(deploy_hooks codex)"
  seed_argv_check
  fake_exit 0
  fake_out ""
  run_stop "$CLAUDE_HOOKS/stop-verify.sh"
  [ "$status" -eq 0 ] || return 1
  [ "$(call_count)" -eq 1 ] || return 1
  [ "$(receipt_count)" -eq 1 ] || return 1
  RECEIPT="$(one_receipt)"
  ORIGINAL="$BATS_TEST_TMPDIR/original.json"
  cp "$RECEIPT" "$ORIGINAL"
  local hooks
  for hooks in "$CLAUDE_HOOKS" "$CODEX_HOOKS"; do
    run_session "$hooks/session-context.sh"
    [ "$status" -eq 0 ] || return 1
    [[ "$CONTEXT" == *'- lint.ruff: exit 0'* ]] || return 1
  done
}

reject_both() {
  local hooks
  for hooks in "$CLAUDE_HOOKS" "$CODEX_HOOKS"; do
    run_session "$hooks/session-context.sh"
    [ "$status" -eq 0 ] || return 1
    [[ "$CONTEXT" == *'Verification receipts: unavailable'* ]] || return 1
    # The unavailable advisory mentions receipts; only execution summaries carry this field.
    [[ "$CONTEXT" != *': exit '* ]] || return 1
    [[ "$CONTEXT" != *'INJECTED'* ]] || return 1
  done
}

@test "both readers reject incomplete identity, unsafe metadata and invalid times" {
  mutation_fixture
  local mutation
  for mutation in \
    'del(.command)' 'del(.cwd)' 'del(.started_at)' 'del(.finished_at)' \
    '.roots.git_common_dir = "/wrong"' '.roots.extra = true' \
    '.check_id = "lint.ruff\nINJECTED"' '.check_id = ("x" * 65)' \
    '.head = "abc\nINJECTED"' '.head = "ABCDEF"' \
    '.cwd = (.cwd + "/../escape")' '.cwd = (.cwd + "//nested")' \
    '.cwd = (.cwd + "-sibling")' '.cwd = "relative"' \
    '.started_at = "2026-02-30T00:00:00Z"' \
    '.started_at = "2026-01-01T24:00:00Z"' \
    '.started_at = "2026-01-01T00:00:60Z"' \
    '.started_at = "2026-01-01T00:00:00Z\n"' \
    '.finished_at = "2000-01-01T00:00:00Z"' \
    '.exit_status = 0.5' '.exit_status = -1' '.exit_status = 256' \
    '.exit_status = "0"' '.extra = true' 'del(.head)' \
    '.executed = false' '.reusable = true' '.schema_version = 2'; do
    printf 'mutation: %s\n' "$mutation" >&3
    jq "$mutation" "$ORIGINAL" > "$RECEIPT"
    reject_both
  done
  cp "$ORIGINAL" "$RECEIPT"
  cat "$ORIGINAL" >> "$RECEIPT"
  reject_both
}

@test "both readers reject malformed command and output branches" {
  mutation_fixture
  local mutation
  for mutation in \
    '.command.argv = []' '.command.argv = [1]' '.command.shell = "extra"' \
    'del(.command.shell)' '.command.extra = true' \
    '.command = {form:"legacy-shell",argv:[],shell:"test"}' \
    '.command = {form:"legacy-shell",argv:null,shell:""}' \
    '.command = {form:"legacy-shell",argv:null,shell:42}' \
    '.command.form = "shell"' \
    'del(.output.text)' 'del(.output.omitted_reason)' '.output.extra = true' \
    '.output.bytes = -1' '.output.bytes = 0.5' '.output.sha256 = "ABC"' \
    '.output.retained = "true"' '.output.omitted_reason = "wrong branch"' \
    '.output.retained = false | .output.text = null | .output.omitted_reason = "small"' \
    '.output.retained = false | .output.bytes = 70000 | .output.omitted_reason = "text present"' \
    '.output.retained = false | .output.bytes = 70000 | .output.text = null | .output.omitted_reason = ""' \
    '.output.retained = false | .output.bytes = 70000 | .output.text = null | .output.omitted_reason = ("x" * 257)' \
    '.output.retained = false | .output.bytes = 70000 | .output.text = null | .output.omitted_reason = "bad\nINJECTED"' \
    '.output.retained = false | .output.bytes = 70000 | .output.text = null | del(.output.omitted_reason)'; do
    printf 'mutation: %s\n' "$mutation" >&3
    jq "$mutation" "$ORIGINAL" > "$RECEIPT"
    reject_both
  done
}

@test "unknown producer-like filenames are neither read nor pruned" {
  mutation_fixture
  local prefix root name
  root="$(state_root)"
  prefix="$(basename "$RECEIPT" | cut -c1-16)"
  rm "$RECEIPT"
  for name in \
    "$prefix.20000101T000000Z.metadata.json" \
    "$prefix.20000101T000000Z.0-123.json" \
    "$prefix.20000101T000000Z.1-random.json" \
    "$prefix.abcdefghTabcdefZ.1-123.json" \
    "$prefix.20000101T000000Z.1-123"$'\nINJECTED.json'; do
    cp "$ORIGINAL" "$root/$name"
    reject_both
    # Use the actual producer to trigger pruning. Unknown entries must survive
    # even with a zero cap; the deployed test copy alone gets this cap override.
    bash -c 'source "$1"; _VR_MAX_RECEIPTS=0; cd "$2"; _vr_run test argv true' \
      _ "$CORE_LIB" "$PROJECT_DIR"
    [ -f "$root/$name" ]
    cmp "$ORIGINAL" "$root/$name"
    rm "$root/$name"
  done
}

@test "same-second generated receipts have distinct complete pointers on both readers" {
  mutation_fixture
  # Pin only the producer clock in the private deployed library, not its writer.
  printf '\n_vr_now_stamp() { printf 20260906T010203Z; }\n' >> "$CLAUDE_HOOKS/lib/verification-receipt.sh"
  rm "$RECEIPT"
  run_stop "$CLAUDE_HOOKS/stop-verify.sh"
  [ "$status" -eq 0 ]
  run_stop "$CLAUDE_HOOKS/stop-verify.sh"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 3 ]
  [ "$(receipt_count)" -eq 2 ]
  local hooks pointers file
  for hooks in "$CLAUDE_HOOKS" "$CODEX_HOOKS"; do
    run_session "$hooks/session-context.sh"
    [ "$status" -eq 0 ]
    pointers="$(printf '%s\n' "$CONTEXT" | grep '^- lint.ruff:' | sed 's/.*receipt //; s/)$//')"
    [ "$(printf '%s\n' "$pointers" | sort -u | wc -l | tr -d ' ')" -eq 2 ]
    while IFS= read -r file; do
      printf '%s\n' "$pointers" | grep -Fx "$(basename "$file" .json)"
    done < <(receipts)
  done
}

# --- pruning ----------------------------------------------------------------

@test "pruning caps retained receipts and touches nothing it does not own" {
  local hooks; hooks="$(deploy_hooks claude)"
  seed_argv_check
  fake_exit 0
  fake_out ""

  local i
  for i in $(seq 1 22); do
    run_stop "$hooks/stop-verify.sh"
    [ "$status" -eq 0 ]
  done
  [ "$(call_count)" -eq 22 ]

  local root; root="$(state_root)"
  [ "$(receipt_count)" -le 20 ]
  [ "$(receipt_count)" -eq 20 ]

  # Foreign entries in the same directory survive: an unknown file, a symlink,
  # and a JSON file that is not shaped like a producer artifact.
  printf 'keep me\n' > "$root/unrelated.txt"
  printf '{"schema_version":1}\n' > "$root/not-a-receipt.json"
  ln -s /dev/null "$root/dangling.json"
  run_stop "$hooks/stop-verify.sh"
  [ "$status" -eq 0 ]

  [ -f "$root/unrelated.txt" ]
  [ -f "$root/not-a-receipt.json" ]
  [ -L "$root/dangling.json" ]
  [ "$(receipt_count)" -eq 20 ]
}
