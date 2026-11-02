#!/usr/bin/env bats
# Tests for the spec-gate Stop-hook pass cache and the Codex save-context-log
# growth check (spec 072 U8). The gate fixture mirrors scripts/tests/spec-gate.bats:
# immutable runtime policy under a TRELLIS_ROOT fixture, the gate run in place.

load helpers

GATE="$HOOKS_DIR/spec-gate.sh"
CODEX_GATE="$CODEX_HOOKS_DIR/spec-gate.sh"
CORE="$HOOKS_DIR/lib/spec-gate-core.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$HOME"
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR"
  REPO_DIR="$(cd "$REPO_DIR" && pwd -P)"
  cd "$REPO_DIR" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  echo seed > README.md
  git add -A && git commit -qm init
  TRELLIS_FIXTURE="$BATS_TEST_TMPDIR/trellis"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets" \
    "$TRELLIS_FIXTURE/core-rules/skills/process-gate/scripts/lib"
  cp "$HOOKS_DIR/../skills/process-gate/scripts/lib/diff-base.sh" \
    "$TRELLIS_FIXTURE/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
}

config() {
  printf '{ "template": { "branch": "main" }, "mandatory_pipeline": { "enabled": %s, "spec_required_diff_lines": 80, "surgical_max_diff_lines": 400 } }\n' \
    "$1" > "$TRELLIS_FIXTURE/trellis.config.json"
}

# A feature branch whose one commit is over the 80-line floor with no triad.
big_branch() {
  git checkout -q -b feat/big
  local i
  for i in $(seq 1 120); do echo "const l$i = $i;"; done > src.js
  git add -A && git commit -qm big
}

stop_gate() { run bash "${1:-$GATE}" <<< '{}'; }
cache_files() { find "$TRELLIS_HOME/state/spec-gate" -type f ! -name '.tmp*' 2>/dev/null | wc -l | tr -d ' '; }

# plant_pass <harness> — write a pass entry for the CURRENT key, as the hook
# itself would, so the next Stop proves whether that key still matches.
plant_pass() {
  bash -c '. "$1"; f=$(sg_stop_cache_file "$PWD" "$2") && k=$(sg_stop_cache_key "$PWD") && _se_stop_receipt_write "$f" "$k" planted' \
    "$GATE" "$CORE" "${1:-claude}"
}

@test "a pass is cached and a block is not" {
  config true
  big_branch
  stop_gate
  [ "$status" -eq 2 ]
  [ "$(cache_files)" -eq 0 ]
  config false
  stop_gate
  [ "$status" -eq 0 ]
  [ "$(cache_files)" -eq 1 ]
  head -1 "$(find "$TRELLIS_HOME/state/spec-gate" -type f -name '*.claude')" | grep -Eq '^trellis-stop-pass v1 [0-9a-f]{64}$'
}

@test "a matching key short-circuits, and HEAD, refs, policy and records each invalidate it" {
  config true
  big_branch
  plant_pass
  stop_gate
  [ "$status" -eq 0 ]
  # HEAD
  echo more >> src.js && git commit -qam more
  stop_gate
  [ "$status" -eq 2 ]
  # Any ref (the diff base reads refs; the key takes all of them)
  plant_pass
  git update-ref refs/tags/unrelated HEAD
  stop_gate
  [ "$status" -eq 2 ]
  # Runtime policy, rewritten with identical bytes
  plant_pass
  config true
  stop_gate
  [ "$status" -eq 2 ]
  # Project records read by the interview check
  plant_pass
  echo '- note' >> "$REPO_DIR/decisions-log.md"
  stop_gate
  [ "$status" -eq 2 ]
  # The surgical marker
  plant_pass
  mkdir -p "$REPO_DIR/.claude" && echo x > "$REPO_DIR/.claude/session-surgical"
  stop_gate
  [ "$status" -eq 2 ]
}

@test "a surgical-marker pass is never cached" {
  config true
  git checkout -q -b feat/small
  local i
  for i in $(seq 1 120); do echo "const l$i = $i;"; done > src.js
  git add -A && git commit -qm big
  run bash "$GATE" --mark "fixture"
  [ "$status" -eq 0 ]
  stop_gate
  [ "$status" -eq 0 ]
  [ "$(cache_files)" -eq 0 ]
}

@test "the Codex twin caches its own passes" {
  # Deployed layout: the shared core beside the Codex hook and its own deps.
  local deploy="$BATS_TEST_TMPDIR/codex-hooks"
  mkdir -p "$deploy/lib"
  cp "$CODEX_GATE" "$deploy/spec-gate.sh"
  cp "$CORE" "$CODEX_HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/autonomy.sh" "$deploy/lib/"
  config false
  stop_gate "$deploy/spec-gate.sh"
  [ "$status" -eq 0 ]
  [ -n "$(find "$TRELLIS_HOME/state/spec-gate" -type f -name '*.codex')" ]
}

@test "the pre-push --gate never reads the cache" {
  config true
  big_branch
  plant_pass
  run bash "$GATE" --gate
  [ "$status" -eq 1 ]
}

# --- Codex save-context-log ---------------------------------------------------

@test "Codex save-context-log rewrites only when the transcript or the log changed" {
  local hook="$CODEX_HOOKS_DIR/save-context-log.sh" tx="$BATS_TEST_TMPDIR/t.jsonl" ino
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"first ask"}}' > "$tx"
  inode() { ls -i "$REPO_DIR/context-log.md" | awk '{print $1}'; }
  run env CODEX_PROJECT_DIR="$REPO_DIR" bash "$hook" <<< "$(jq -nc --arg t "$tx" '{transcript_path: $t}')"
  [ "$status" -eq 0 ]
  grep -q 'first ask' "$REPO_DIR/context-log.md"
  ino=$(inode)
  run env CODEX_PROJECT_DIR="$REPO_DIR" bash "$hook" <<< "$(jq -nc --arg t "$tx" '{transcript_path: $t}')"
  [ "$(inode)" = "$ino" ]
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"second ask"}}' >> "$tx"
  run env CODEX_PROJECT_DIR="$REPO_DIR" bash "$hook" <<< "$(jq -nc --arg t "$tx" '{transcript_path: $t}')"
  grep -q 'second ask' "$REPO_DIR/context-log.md"
  # Someone else rewrote the log: this hook writes its own again.
  echo clobbered > "$REPO_DIR/context-log.md"
  run env CODEX_PROJECT_DIR="$REPO_DIR" bash "$hook" <<< "$(jq -nc --arg t "$tx" '{transcript_path: $t}')"
  grep -q 'second ask' "$REPO_DIR/context-log.md"
}
