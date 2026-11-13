#!/usr/bin/env bats
# The spec-gate Stop early warning has no pass cache (1.5.2: a cache key never
# covered every Git-side input, and with one default-branch resolution per
# verdict it saved under 50 ms of Stop). These tests warm a real pass, change
# only a Git input outside the repository's tracked state, and require the
# next Stop to block: configuration, attributes and replacement objects. Also
# the Codex save-context-log growth check (spec 072 U8). The gate fixture
# mirrors scripts/tests/spec-gate.bats: immutable runtime policy under a
# TRELLIS_ROOT fixture, the gate run in place.

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
  printf '{ "template": { "branch": "main" }, "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 80, "surgical_max_diff_lines": 400 } }\n' \
    > "$TRELLIS_FIXTURE/trellis.config.json"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/global.gitconfig"
  : > "$GIT_CONFIG_GLOBAL"
}

stop_gate() { run bash "${1:-$GATE}" <<< '{}'; }

# A feature branch whose one commit adds 120 lines, over the 80-line floor.
big_branch() {
  git checkout -q -b feat/big
  local i
  for i in $(seq 1 120); do echo "const l$i = $i;"; done > src.js
  git add -A && git commit -qm big
}

# 120 lines moved unchanged on feat/rename: under the floor only while Git
# detects renames, so diff.renames decides the verdict.
rename_branch() {
  local i
  for i in $(seq 1 120); do echo "const line$i = $i;"; done > src.js
  git add -A && git commit -qm seed
  git checkout -q -b feat/rename
  git mv src.js dst.js && git commit -qm rename
}

# warm_pass [gate] / expect_block <what> [gate] — the real gate passes, then,
# after the caller's change, blocks.
warm_pass() {
  stop_gate "${1:-$GATE}"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "warm: $status $output"; return 1; }
}
expect_block() {
  stop_gate "${2:-$GATE}"
  [[ "$output" == *'"decision":"block"'* ]] || { echo "passed after a changed $1: $status $output"; return 1; }
}

@test "a Stop writes no spec-gate pass cache" {
  warm_pass
  big_branch
  expect_block 'branch'
  [ ! -e "$TRELLIS_HOME/state/spec-gate" ]
}

@test "a changed global Git config value is seen by the next Stop" {
  printf '[diff]\n\trenames = true\n' > "$GIT_CONFIG_GLOBAL"
  rename_branch
  warm_pass
  printf '[diff]\n\trenames = false\n' > "$GIT_CONFIG_GLOBAL"
  expect_block 'global config'
}

@test "a changed include target is seen by the next Stop" {
  local target="$BATS_TEST_TMPDIR/included.gitconfig"
  printf '[include]\n\tpath = %s\n' "$target" > "$GIT_CONFIG_GLOBAL"
  printf '[diff]\n\trenames = true\n' > "$target"
  rename_branch
  warm_pass
  printf '[diff]\n\trenames = false\n' > "$target"
  expect_block 'include target'
}

@test "a changed config.worktree value is seen by the next Stop" {
  rename_branch
  git config extensions.worktreeConfig true
  git config --worktree diff.renames true
  warm_pass
  git config --worktree diff.renames false
  expect_block 'config.worktree'
}

@test "a changed GIT_CONFIG_* overlay is seen by the next Stop" {
  rename_branch
  run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.renames GIT_CONFIG_VALUE_0=true bash "$GATE" <<< '{}'
  [ "$status" -eq 0 ] || { echo "warm: $output"; return 1; }
  run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.renames GIT_CONFIG_VALUE_0=false bash "$GATE" <<< '{}'
  [[ "$output" == *'"decision":"block"'* ]] || { echo "passed after an overlay change: $output"; return 1; }
}

# Sol r152-stop M2: a binary attribute removes a file from the gated diff.
@test "a changed info/attributes file is seen by the next Stop, both twins" {
  local deploy="$BATS_TEST_TMPDIR/codex-hooks" gate
  mkdir -p "$deploy/lib"
  cp "$CODEX_GATE" "$deploy/spec-gate.sh"
  cp "$CORE" "$CODEX_HOOKS_DIR/lib/deps.sh" "$CODEX_HOOKS_DIR/lib/deps-heavy.sh" "$CODEX_HOOKS_DIR/lib/autonomy.sh" "$deploy/lib/"
  big_branch
  for gate in "$GATE" "$deploy/spec-gate.sh"; do
    printf 'src.js binary\n' > .git/info/attributes
    warm_pass "$gate"
    : > .git/info/attributes
    expect_block 'info/attributes' "$gate"
  done
}

@test "changed core.attributesFile bytes are seen by the next Stop" {
  local attributes="$BATS_TEST_TMPDIR/global.gitattributes"
  printf '[core]\n\tattributesFile = %s\n' "$attributes" > "$GIT_CONFIG_GLOBAL"
  printf 'src.js binary\n' > "$attributes"
  big_branch
  warm_pass
  : > "$attributes"
  expect_block 'core.attributesFile'
}

@test "a changed worktree .gitattributes is seen by the next Stop" {
  big_branch
  printf 'src.js binary\n' > .gitattributes
  printf '/.gitattributes\n' >> .git/info/exclude
  warm_pass
  rm .gitattributes
  expect_block '.gitattributes'
}

# Sol r152-stop M3: a replacement commit with the base's tree masks the diff.
replace_head() {
  local seed head replacement
  seed=$(git rev-parse main)
  big_branch
  head=$(git rev-parse HEAD)
  replacement=$(printf 'replacement\n' | git commit-tree "$seed^{tree}" -p "$seed")
  git replace "$head" "$replacement"
}

@test "GIT_NO_REPLACE_OBJECTS is seen by the next Stop" {
  replace_head
  warm_pass
  run env GIT_NO_REPLACE_OBJECTS=1 bash "$GATE" <<< '{}'
  [[ "$output" == *'"decision":"block"'* ]] || { echo "passed with replacements off: $status $output"; return 1; }
}

@test "GIT_REPLACE_REF_BASE is seen by the next Stop" {
  replace_head
  warm_pass
  run env GIT_REPLACE_REF_BASE=refs/elsewhere/ bash "$GATE" <<< '{}'
  [[ "$output" == *'"decision":"block"'* ]] || { echo "passed with another replace base: $status $output"; return 1; }
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
