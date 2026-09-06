#!/usr/bin/env bats
# T6 Phase A — immutable attachment integration suite for Python hooks parity.
# Exercises planned and attached surfaces across Claude, Codex, and Pi;
# task-state capture and cross-harness read with drift detection and tick recording;
# verification-bash execution, reuse, and mutation; and fail-closed leaf validation.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# shellcheck source=helpers/release-fixture.bash
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"

setup_file() {
  # ONE bootstrapped machine with release 9.9.9 installed, built once per Bats
  # file. BATS_FILE_TMPDIR is created fresh for this invocation and removed with
  # the run, so the prototype cannot be reused across runs and has no staleness
  # window: full source input identity still holds every run.
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/prototype"
  mkdir -p "$RELEASE_FIXTURE_PROTOTYPE"
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$RELEASE_FIXTURE_PROTOTYPE")"
  export RELEASE_FIXTURE_PROTOTYPE
  release_fixture_prototype_build "$RELEASE_FIXTURE_PROTOTYPE"
}

teardown_file() {
  # The prototype carries the same sealed a-w tree a sandbox carries, so it
  # needs the same sweep before it can be removed.
  chmod -R u+w "$RELEASE_FIXTURE_PROTOTYPE" 2>/dev/null || true
  rm -rf "$RELEASE_FIXTURE_PROTOTYPE"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/t6-phase-a.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  HOME="$SANDBOX/user"
  TRELLIS_HOME="$SANDBOX/trellis"
  RELEASE_SOURCE="$SANDBOX/release"
  PROJECT="$SANDBOX/project"
  export HOME TRELLIS_HOME
  # Independent PHYSICAL copy of the prototype: this case gets its own user
  # home, TRELLIS_HOME, release source and bootstrap source, and every absolute
  # path the prototype recorded is rewritten to this sandbox.
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"phase-a-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm initial
  LAUNCHER="$HOME/.local/bin/trellis"
  PAYLOAD="$TRELLIS_HOME/releases/9.9.9/payload"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

owner_file() {
  find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print | head -1
}

registry_harnesses() {
  jq -c '.projects["personal/phase-a-fixture"].checkouts | to_entries[0].value.harnesses' "$TRELLIS_HOME/registry.json"
}

target_of() {
  readlink "$1"
}

mode_of() {
  python3 -c 'import os, sys, stat; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"
}

# The attached leaf must resolve into the sealed payload, where `release
# install` strips every write bit (release-store.sh: `find "$payload" -type f
# -exec chmod a-w`). Assert that immutability directly rather than pinning one
# octal literal: the extraction umask decides which read bits survive, and a
# mode assertion that drifts with umask is not an oracle. A pre-seal 0644 leaf,
# or any writable leaf, fails here. The observed mode is echoed to the TAP so
# the receipt records the real number rather than an inference.
assert_immutable_leaf() {
  local link="$1" mode
  [ -L "$link" ] || { echo "expected an immutable symlink leaf: $link"; false; }
  mode="$(mode_of "$link")" || { echo "could not stat resolved leaf: $link"; false; }
  python3 -c '
import os, stat, sys
info = os.stat(sys.argv[1])
mode = stat.S_IMODE(info.st_mode)
if not stat.S_ISREG(info.st_mode):
    raise SystemExit("resolved leaf is not a regular file")
if mode & 0o222:
    raise SystemExit("resolved leaf is writable")
if not mode & 0o400:
    raise SystemExit("resolved leaf is not owner-readable")
' "$link" || { echo "leaf $link is not an immutable readable regular file (mode $mode)"; false; }
  { echo "# immutable leaf $link mode $mode"; } >&3 2>/dev/null || true
}

@test "disposable attach covers claude, codex, pi, and mixed selectors with exact targets and isolation" {
  # 1. Claude-only attach
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness claude "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["claude"]' ]
  [ -L "$PROJECT/.claude/hooks/lib/task-state.py" ]
  [ -L "$PROJECT/.claude/hooks/lib/verification-bash.py" ]
  [ "$(target_of "$PROJECT/.claude/hooks/lib/task-state.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/task-state.py" ]
  [ "$(target_of "$PROJECT/.claude/hooks/lib/verification-bash.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/verification-bash.py" ]
  assert_immutable_leaf "$PROJECT/.claude/hooks/lib/task-state.py"
  assert_immutable_leaf "$PROJECT/.claude/hooks/lib/verification-bash.py"
  [ ! -e "$PROJECT/.codex" ] && [ ! -L "$PROJECT/.codex" ]
  [ ! -e "$PROJECT/.pi" ] && [ ! -L "$PROJECT/.pi" ]

  # Detach Claude
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/.claude" ] && [ ! -L "$PROJECT/.claude" ]

  # 2. Codex-only attach
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness codex "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["codex"]' ]
  [ -L "$PROJECT/.codex/hooks/lib/task-state.py" ]
  [ -L "$PROJECT/.codex/hooks/lib/verification-bash.py" ]
  [ "$(target_of "$PROJECT/.codex/hooks/lib/task-state.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/task-state.py" ]
  [ "$(target_of "$PROJECT/.codex/hooks/lib/verification-bash.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/verification-bash.py" ]
  [ ! -e "$PROJECT/.claude" ] && [ ! -L "$PROJECT/.claude" ]
  [ ! -e "$PROJECT/.pi" ] && [ ! -L "$PROJECT/.pi" ]

  # Detach Codex
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]

  # 3. Pi-only attach
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["pi"]' ]
  [ -L "$PROJECT/.pi/hooks/lib/task-state.py" ]
  [ -L "$PROJECT/.pi/hooks/lib/verification-bash.py" ]
  [ "$(target_of "$PROJECT/.pi/hooks/lib/task-state.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/task-state.py" ]
  [ "$(target_of "$PROJECT/.pi/hooks/lib/verification-bash.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/verification-bash.py" ]
  [ ! -e "$PROJECT/.claude" ] && [ ! -L "$PROJECT/.claude" ]
  [ ! -e "$PROJECT/.codex" ] && [ ! -L "$PROJECT/.codex" ]

  # Detach Pi
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]

  # 4. Mixed Codex + Pi attach: assert shared surface deduplicated and both present
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["codex","pi"]' ]
  [ -L "$PROJECT/.codex/hooks/lib/task-state.py" ]
  [ -L "$PROJECT/.codex/hooks/lib/verification-bash.py" ]
  [ -L "$PROJECT/.pi/hooks/lib/task-state.py" ]
  [ -L "$PROJECT/.pi/hooks/lib/verification-bash.py" ]
  [ -L "$PROJECT/.agents/rules/trellis.md" ]
  [ ! -e "$PROJECT/.claude" ] && [ ! -L "$PROJECT/.claude" ]

  # Detach mixed
  run "$LAUNCHER" detach "$PROJECT"
  [ "$status" -eq 0 ]

  # 5. Three-harness attach: assert all six exact targets exist and point to runtime
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness claude --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(registry_harnesses)" = '["claude","codex","pi"]' ]
  for harness in claude codex pi; do
    [ -L "$PROJECT/.$harness/hooks/lib/task-state.py" ]
    [ -L "$PROJECT/.$harness/hooks/lib/verification-bash.py" ]
    [ "$(target_of "$PROJECT/.$harness/hooks/lib/task-state.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/task-state.py" ]
    [ "$(target_of "$PROJECT/.$harness/hooks/lib/verification-bash.py")" = "../../../.trellis/runtime/core-rules/hooks/lib/verification-bash.py" ]
    assert_immutable_leaf "$PROJECT/.$harness/hooks/lib/task-state.py"
    assert_immutable_leaf "$PROJECT/.$harness/hooks/lib/verification-bash.py"
  done
}

@test "task-state capture and cross-harness read agree, invalidate on byte drift, and record ticks" {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness claude --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  mkdir -p "$PROJECT/specs/045"
  cat <<'EOF' > "$PROJECT/specs/045/tasks.md"
# Spec 045 Tasks

## Phase 1 — Integration

| ID | Task | Est. | Depends | Covers | Status |
| T1 | Wire manifest entries | S | - | FR-1 | [ ] |
| T2 | Verify cross-harness | S | T1 | FR-2 | [ ] |

## Done criteria
- [ ] Integration complete
EOF
  git -C "$PROJECT" add specs/045/tasks.md
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm "add spec 045 tasks"

  # Capture via Claude mapped helper
  run python3 -I "$PROJECT/.claude/hooks/lib/task-state.py" capture --cwd "$PROJECT" --tasks "specs/045/tasks.md" --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "available" and .documents[0].status == "current"' >/dev/null

  # Read via Codex mapped helper with EXACT CLI `read --cwd` (no harness flag)
  run python3 -I "$PROJECT/.codex/hooks/lib/task-state.py" read --cwd "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '
    .status == "available"
    and .documents[0].status == "current"
    and .documents[0].producer_harness == "claude"
    and .documents[0].source.path == "specs/045/tasks.md"
    and (.documents[0].tasks | length) == 3
    and ([.documents[0].tasks[] | select(.checked)] | length) == 0
  ' >/dev/null

  # Read via Pi mapped helper with EXACT CLI `read --cwd`
  run python3 -I "$PROJECT/.pi/hooks/lib/task-state.py" read --cwd "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '
    .status == "available"
    and .documents[0].status == "current"
    and (.documents[0].tasks | length) == 3
    and ([.documents[0].tasks[] | select(.checked)] | length) == 0
  ' >/dev/null

  # Byte change => stale
  printf '\n<!-- trailing drift -->\n' >> "$PROJECT/specs/045/tasks.md"
  run python3 -I "$PROJECT/.codex/hooks/lib/task-state.py" read --cwd "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '
    .status == "available"
    and .documents[0].status == "stale"
    and .documents[0].source.path == "specs/045/tasks.md"
  ' >/dev/null

  # Missing source => missing
  rm "$PROJECT/specs/045/tasks.md"
  run python3 -I "$PROJECT/.pi/hooks/lib/task-state.py" read --cwd "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '
    .status == "available"
    and .documents[0].status == "missing"
    and .documents[0].source.path == "specs/045/tasks.md"
  ' >/dev/null

  # Restore document from Git
  git -C "$PROJECT" checkout -- specs/045/tasks.md

  # Actual tick using canonical tick.sh helper
  run /bin/bash "$PAYLOAD/core-rules/skills/execute/scripts/tick.sh" \
    "$PROJECT/specs/045/tasks.md" \
    "Phase 1 — Integration" \
    "T1" \
    '<!-- dod-receipt cmd="pytest" exit=0 diff="+10/-2 (1 files)" -->'
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Capture immediately AFTER tick via Claude mapped helper
  run python3 -I "$PROJECT/.claude/hooks/lib/task-state.py" capture --cwd "$PROJECT" --tasks "specs/045/tasks.md" --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "available" and .documents[0].status == "current"' >/dev/null

  # Read via Codex mapped helper reflects checked status
  run python3 -I "$PROJECT/.codex/hooks/lib/task-state.py" read --cwd "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '
    .status == "available"
    and .documents[0].status == "current"
    and (.documents[0].tasks | length) == 3
    and ([.documents[0].tasks[] | select(.checked)] | length) == 1
    and (.documents[0].tasks[] | select(.id == "T1") | .checked == true)
    and (.documents[0].tasks[] | select(.id == "T2") | .checked == false)
  ' >/dev/null
}

@test "bash verification primitive reuses across harnesses and invalidates on byte drift and syntax errors" {
  run "$LAUNCHER" attach --fleet personal --release 9.9.9 --harness claude --harness codex --harness pi "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  mkdir -p "$PROJECT/scripts"
  printf '#!/usr/bin/env bash\necho "hello-from-fixture"\n' > "$PROJECT/scripts/fixture.sh"
  chmod 755 "$PROJECT/scripts/fixture.sh"
  git -C "$PROJECT" add scripts/fixture.sh
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm "add fixture script"

  # Initial run via Claude => executed
  run python3 -I "$PROJECT/.claude/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness claude
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "executed" and .exit_status == 0' >/dev/null

  # Subsequent run via Codex => reused
  run python3 -I "$PROJECT/.codex/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness codex
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "reused" and .exit_status == 0' >/dev/null

  # Subsequent run via Pi => reused
  run python3 -I "$PROJECT/.pi/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "reused" and .exit_status == 0' >/dev/null

  # Byte change => causes executed (cache miss due to drift)
  printf '#!/usr/bin/env bash\necho "hello-from-fixture-modified"\n' > "$PROJECT/scripts/fixture.sh"
  run python3 -I "$PROJECT/.codex/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness codex
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "executed" and .exit_status == 0' >/dev/null

  # Verify subsequent run reuses modified file
  run python3 -I "$PROJECT/.pi/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness pi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | jq -e '.status == "reused" and .exit_status == 0' >/dev/null

  # Syntax error => causes executed with parser real nonzero exit code
  printf '#!/usr/bin/env bash\nif; then\n' > "$PROJECT/scripts/fixture.sh"
  run python3 -I "$PROJECT/.codex/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness codex
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.status == "executed" and .exit_status != 0' >/dev/null

  # Re-run after failed syntax parsing => rerun executed and nonzero preserved, never reused
  run python3 -I "$PROJECT/.pi/hooks/lib/verification-bash.py" --cwd "$PROJECT" --harness pi
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.status == "executed" and .exit_status != 0' >/dev/null
}

@test "missing canonical Python leaf fails surface planning and release attachment closed" {
  # 1. Test that surface-plan.sh fails closed when canonical Python leaf is absent from payload
  local broken_payload="$SANDBOX/broken-payload"
  cp -R "$PAYLOAD" "$broken_payload"
  # The sealed payload is chmod a-w down to its directories, and cp -R carries
  # that through, so the copy has to be made writable before a leaf can be
  # removed from it. This corrupts only the disposable copy; $PAYLOAD stays
  # sealed and is still the planner binary under test.
  chmod -R u+w "$broken_payload"
  rm "$broken_payload/core-rules/hooks/lib/task-state.py"

  run bash "$PAYLOAD/scripts/lib/surface-plan.sh" --payload "$broken_payload" --harness claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"required source is missing from immutable payload: core-rules/hooks/lib/task-state.py"* ]] || {
    echo "Unexpected surface-plan output: $output"
    false
  }

  # 2. Test that attachment fails closed before creating an owner record when release payload lacks Python leaf
  local corrupt_source="$SANDBOX/corrupt-release-source"
  mkdir -p "$corrupt_source"
  cp -R "$REPO_ROOT/core-rules" "$REPO_ROOT/scripts" "$corrupt_source/"
  printf '9.9.10\n' > "$corrupt_source/core-rules/VERSION"
  rm "$corrupt_source/core-rules/hooks/lib/verification-bash.py"

  release_fixture_seal_repo "$HOME" "$corrupt_source" 9.9.10
  run "$LAUNCHER" release install 9.9.10 --remote "$corrupt_source"
  local install_status="$status"
  { echo "# release install 9.9.10 without core-rules/hooks/lib/verification-bash.py exited $install_status"; } >&3 2>/dev/null || true

  # The store seals the tagged tree byte-for-byte; it does not resolve manifest
  # leaves. Attachment is where the payload is planned, so whichever stage
  # catches the missing canonical leaf, attaching that release must never
  # succeed and must never publish an owner record.
  run "$LAUNCHER" attach --fleet personal --release 9.9.10 --harness claude "$PROJECT"
  [ "$status" -ne 0 ] || {
    echo "attach succeeded against a payload missing core-rules/hooks/lib/verification-bash.py"
    echo "release install exited $install_status"
    echo "$output"
    false
  }
  if [ "$install_status" -eq 0 ]; then
    [[ "$output" == *"required source is missing from immutable payload: core-rules/hooks/lib/verification-bash.py"* ]] || {
      echo "attach failed without naming the missing canonical leaf: $output"
      false
    }
  fi

  local owner_count
  owner_count="$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' 2>/dev/null | wc -l)"
  [ "$owner_count" -eq 0 ] || {
    echo "owner record published despite a fail-closed attach: $owner_count record(s)"
    false
  }
  [ ! -e "$PROJECT/.claude" ] && [ ! -L "$PROJECT/.claude" ]
  [ ! -e "$PROJECT/.trellis/runtime" ] && [ ! -L "$PROJECT/.trellis/runtime" ]
}
