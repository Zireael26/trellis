#!/usr/bin/env bats
# Behaviour tests for the shared task-context advisory helper.
#
# Every case installs the library and an accepted copy of the task-state
# primitive into a private scratch lib directory and drives the public shell
# function. The primitive itself is not re-audited here. Run inside the
# canonical isolated gate with fresh generated Git/mktemp launchers; no native
# lifecycle or SC4 claim follows from these cases.

setup() {
  [ -n "${TRELLIS_TEST_GIT_FENCE_ROOT:-}" ]
  TASK_CONTEXT_SOURCE="${TASK_CONTEXT_UNDER_TEST:-$BATS_TEST_DIRNAME/../lib/task-context.sh}"
  TASK_STATE_SOURCE="${TASK_STATE_UNDER_TEST:-$BATS_TEST_DIRNAME/../lib/task-state.py}"
  [ -f "$TASK_CONTEXT_SOURCE" ]
  [ -f "$TASK_STATE_SOURCE" ]

  WORK="$(mktemp -d)"
  LIB="$WORK/lib"
  mkdir -p "$LIB"
  cp "$TASK_CONTEXT_SOURCE" "$LIB/task-context.sh"
  cp "$TASK_STATE_SOURCE" "$LIB/task-state.py"

  PROJECT="$WORK/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" -c core.hooksPath=/dev/null -c init.templateDir= init -q

  # The library is sourced exactly as a lifecycle hook would source it.
  cat > "$WORK/run.sh" <<'RUNNER'
set -u
. "$1/task-context.sh"
trellis_task_context "$2"
RUNNER
}

capture() {
  python3 -I "$LIB/task-state.py" capture --cwd "${3:-$PROJECT}" --tasks "$1" --harness "${2:-pi}" > /dev/null
}

context() {
  run bash "$WORK/run.sh" "${1:-$LIB}" "${2:-$PROJECT}"
}

# The advisory is bounded in UTF-8 bytes including its trailing newline.
advisory_bytes() {
  printf '%s\n' "$output" | wc -c | tr -d ' '
}

assert_bounded() {
  [ "$(advisory_bytes)" -le 512 ]
  printf '%s\n' "$output" | python3 -I -c 'import sys; raw = sys.stdin.buffer.read(); raw.decode("utf-8"); sys.exit(0 if len(raw) <= 512 and raw.endswith(b"\n") else 1)'
}

@test "a captured list and table document reports only its current checked and pending counts" {
  printf '%s\n' '# plan' \
    '- [x] SENTINELALPHA finished list item' \
    '- [ ] SENTINELBETA pending list item' \
    '| T1 | SENTINELGAMMA done row | SC1 | [x] |' \
    '| T2 | SENTINELDELTA open row | SC2 | [ ] |' \
    '| T3 | SENTINELEPSILON open row | SC3 | [ ] |' > "$PROJECT/tasks.md"
  capture tasks.md claude
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=available documents=1 foreign_records=0 checked=2 pending=3"* ]]
  [[ "$output" == *"- \"tasks.md\": current checked=2 pending=3"* ]]
  [[ "$output" == *"Canonical task documents are authoritative"* ]]
  # No raw task text, table id, or checkbox syntax reaches the advisory.
  [[ "$output" != *SENTINEL* ]]
  [[ "$output" != *"T1"* ]]
  [[ "$output" != *"[x]"* ]]
}

@test "a source edited after capture is reported stale and contributes no counts" {
  printf '%s\n' '- [x] one' '- [ ] two' > "$PROJECT/tasks.md"
  capture tasks.md
  printf '%s\n' '- [x] one' '- [ ] two' '- [ ] three' > "$PROJECT/tasks.md"
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=available documents=1 foreign_records=0 checked=0 pending=0"* ]]
  [[ "$output" == *"- \"tasks.md\": stale"* ]]
}

@test "a deleted source is reported missing and contributes no counts" {
  printf '%s\n' '- [x] one' '- [x] two' > "$PROJECT/tasks.md"
  capture tasks.md
  rm "$PROJECT/tasks.md"
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=available documents=1 foreign_records=0 checked=0 pending=0"* ]]
  [[ "$output" == *"- \"tasks.md\": missing"* ]]
}

@test "an uncaptured worktree yields the bounded no_records advisory" {
  printf '%s\n' '- [ ] never captured' > "$PROJECT/tasks.md"
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=no_records documents=0 foreign_records=0 checked=0 pending=0"* ]]
  # Status line and authority note only: no per-document detail is invented.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a second worktree's record is counted as foreign and never replayed" {
  printf '%s\n' '- [x] main worktree' > "$PROJECT/tasks.md"
  git -C "$PROJECT" -c core.hooksPath=/dev/null add tasks.md
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -q -m seed
  capture tasks.md

  local second="$WORK/second"
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q --detach "$second"
  printf '%s\n' '- [ ] foreign one' '- [ ] foreign two' > "$second/other.md"
  capture other.md pi "$second"

  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=available documents=1 foreign_records=1 checked=1 pending=0"* ]]
  [[ "$output" == *"- \"tasks.md\": current checked=1 pending=0"* ]]
  [[ "$output" != *"other.md"* ]]
}

@test "long document paths across several documents force an explicit omission" {
  local deep index path
  deep="$(python3 -I -c 'print("long-specification-directory-segment-" + "x" * 60)')"
  mkdir -p "$PROJECT/$deep"
  for index in 1 2 3 4 5; do
    path="$deep/tasks-$index.md"
    printf '%s\n' '- [x] done' '- [ ] open' > "$PROJECT/$path"
    capture "$path"
  done
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=available documents=5 foreign_records=0 checked=5 pending=5"* ]]
  [[ "$output" == *"summary-omitted"* ]]
  [[ "$output" == *"run the installed hooks/lib/task-state.py read --cwd <worktree>"* ]]
  [[ "$output" != *"$deep"* ]]
}

@test "the 512-byte bound is measured in UTF-8 bytes, not characters" {
  local deep path
  # 109 characters but 310 bytes: a character-counted bound would wrongly
  # decide the full per-document detail fits.
  deep="$(python3 -I -c 'print("日" * 50 + "/" + "本" * 50)')"
  path="$deep/tasks.md"
  mkdir -p "$PROJECT/$deep"
  printf '%s\n' '- [x] done' '- [ ] open' > "$PROJECT/$path"
  capture "$path"
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=available documents=1 foreign_records=0 checked=1 pending=1"* ]]
  [[ "$output" == *"summary-omitted"* ]]
  [[ "$output" != *"$deep"* ]]
}

@test "a state directory that lost its private mode is reported unavailable" {
  printf '%s\n' '- [x] one' > "$PROJECT/tasks.md"
  capture tasks.md
  chmod 755 "$PROJECT/.git/trellis-task-state-v1"
  context
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable reason=unsafe_state documents=0 foreign_records=0 checked=0 pending=0"* ]]
}

@test "a missing sibling helper produces a bounded unavailable advisory" {
  local lonely="$WORK/lonely"
  mkdir -p "$lonely"
  cp "$TASK_CONTEXT_SOURCE" "$lonely/task-context.sh"
  context "$lonely"
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable reason=helper_unavailable"* ]]
}

@test "a missing python3 produces a bounded unavailable advisory" {
  run env PATH=/nonexistent-task-context-path /bin/bash "$WORK/run.sh" "$LIB" "$PROJECT"
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable reason=python_unavailable"* ]]
}

@test "truncated protocol output is reported unavailable, never rendered as a read" {
  local broken="$WORK/broken"
  mkdir -p "$broken"
  cp "$TASK_CONTEXT_SOURCE" "$broken/task-context.sh"
  cat > "$broken/task-state.py" <<'STUB'
import json
import sys

# A protocol object cut off mid-key: valid JSON never resumes from here.
sys.stdout.write(json.dumps({"status": "available", "documents": [], "foreign_records": 0})[:-9])
STUB
  context "$broken"
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable reason=malformed_protocol"* ]]
}

@test "empty stdout is never mistaken for a successful read" {
  local silent="$WORK/silent"
  mkdir -p "$silent"
  cp "$TASK_CONTEXT_SOURCE" "$silent/task-context.sh"
  printf '%s\n' 'import sys' 'sys.exit(0)' > "$silent/task-state.py"
  context "$silent"
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable reason=empty_protocol_output"* ]]
}

@test "a nonzero CLI exit carrying an available payload is refused" {
  local mismatched="$WORK/mismatched"
  mkdir -p "$mismatched"
  cp "$TASK_CONTEXT_SOURCE" "$mismatched/task-context.sh"
  cat > "$mismatched/task-state.py" <<'STUB'
import json
import sys

print(json.dumps({"status": "available", "foreign_records": 0, "documents": [
    {"status": "stale", "source": {"path": "tasks.md", "sha256": "0" * 64, "bytes": 3}}]}))
sys.exit(3)
STUB
  context "$mismatched"
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable reason=cli_status_mismatch"* ]]
}

@test "an unavailable record without a source sorts last and is never dropped" {
  local unsorted="$WORK/unsorted"
  mkdir -p "$unsorted"
  cp "$TASK_CONTEXT_SOURCE" "$unsorted/task-context.sh"
  cat > "$unsorted/task-state.py" <<'STUB'
import json
import sys

print(json.dumps({"status": "unavailable", "foreign_records": 4, "documents": [
    {"status": "unavailable", "reason": "invalid_or_unsafe_record_or_source"},
    {"status": "missing", "source": {"path": "zeta.md", "sha256": "0" * 64, "bytes": 3}},
    {"status": "stale", "source": {"path": "alpha.md", "sha256": "0" * 64, "bytes": 3}}]}))
sys.exit(1)
STUB
  context "$unsorted"
  [ "$status" -eq 1 ]
  assert_bounded
  [[ "$output" == *"status=unavailable documents=3 foreign_records=4 checked=0 pending=0"* ]]
  printf '%s\n' "$output" | grep -q -- '- "alpha.md": stale'
  printf '%s\n' "$output" | grep -q -- '- "zeta.md": missing'
  printf '%s\n' "$output" | grep -q -- '- (source unavailable): unavailable'
  [ "$(printf '%s\n' "$output" | grep -n -- '- "alpha.md": stale' | cut -d: -f1)" -lt \
    "$(printf '%s\n' "$output" | grep -n -- '- (source unavailable): unavailable' | cut -d: -f1)" ]
}

@test "the helper is called without a harness flag and never captures or ticks" {
  local recorder="$WORK/recorder"
  mkdir -p "$recorder"
  cp "$TASK_CONTEXT_SOURCE" "$recorder/task-context.sh"
  cat > "$recorder/task-state.py" <<'STUB'
import json
import os
import sys

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "argv.json"), "w") as handle:
    json.dump(sys.argv[1:], handle)
print(json.dumps({"status": "no_records", "documents": [], "foreign_records": 0}))
STUB
  printf '%s\n' '- [ ] untouched' > "$PROJECT/tasks.md"
  context "$recorder"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=no_records"* ]]
  run cat "$recorder/argv.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[\"read\", \"--cwd\", \"$PROJECT\"]" ]
  # The document is untouched and no state directory was created.
  [ "$(cat "$PROJECT/tasks.md")" = '- [ ] untouched' ]
  [ ! -e "$PROJECT/.git/trellis-task-state-v1" ]
}


@test "foreign-only records preserve no_records and the foreign count" {
  printf '%s\n' '- [x] main worktree' > "$PROJECT/tasks.md"
  git -C "$PROJECT" -c core.hooksPath=/dev/null add tasks.md
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -q -m seed
  local second="$WORK/second"
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q --detach "$second"
  printf '%s\n' '- [ ] foreign content' > "$second/other.md"
  capture other.md pi "$second"
  context
  [ "$status" -eq 0 ]
  assert_bounded
  [[ "$output" == *"status=no_records documents=0 foreign_records=1 checked=0 pending=0"* ]]
  [[ "$output" != *"other.md"* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "source paths with punctuation are JSON quoted as data" {
  local path='a: "quoted" [tasks].md'
  printf '%s\n' '- [x] private task text' > "$PROJECT/$path"
  capture "$path"
  context
  [ "$status" -eq 0 ]
  assert_bounded
  printf '%s\n' "$output" | python3 -I -c 'import json,sys; line=sys.stdin.read().splitlines()[2]; value,end=json.JSONDecoder().raw_decode(line[2:]); assert value == sys.argv[1]; assert line[2+end:] == ": current checked=1 pending=0"' "$path"
  [[ "$output" != *"private task text"* ]]
}
