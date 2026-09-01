#!/usr/bin/env bats
# Narrow contract tests for the Stop-time primer-capture nudge.
#
# The fixtures deliberately exercise the gates that make this advisory cheap:
# edit-heavy volume, INDEX coverage, clean turns, malformed envelopes, and a
# missing git tool. These tests are not run by this unit; the foreman runs Bats
# serially after the complete wave lands.

load helpers

HOOK="$HOOKS_DIR/primer-capture-nudge.sh"

setup() {
  setup_project_dir
  unset CODEX_PROJECT_DIR
  mkdir -p "$PROJECT_DIR/.claude/primers"
  cat > "$PROJECT_DIR/.claude/primers/INDEX.md" <<'EOF'
# Primers Index

- [known](./known.md) — known subsystem
EOF
  cat > "$PROJECT_DIR/.claude/primers/known.md" <<'EOF'
---
slug: known
---

## Entry points

- `src/known/main.py` — known entry point

## Purpose

Fixture primer.
EOF
  git -C "$PROJECT_DIR" add .claude/primers
  git -C "$PROJECT_DIR" commit -q -m 'seed primer index'
  unset CODEX_PROJECT_DIR REVIEW_MIN_FILES REVIEW_MIN_LINES TRELLIS_NO_JQ_DEGRADE
}

teardown() {
  unset CODEX_PROJECT_DIR REVIEW_MIN_FILES REVIEW_MIN_LINES TRELLIS_NO_JQ_DEGRADE
  teardown_project_dir
}

run_hook() {
  run_with_stderr "$HOOK" "${1:-{}}"
}

context() {
  printf '%s' "$output" | jq -r '.additionalContext // empty'
}

make_unknown_files() {
  mkdir -p "$PROJECT_DIR/src/new-subsystem"
  printf 'print(1)\n' > "$PROJECT_DIR/src/new-subsystem/a.py"
  printf 'print(2)\n' > "$PROJECT_DIR/src/new-subsystem/b.py"
  printf 'print(3)\n' > "$PROJECT_DIR/src/new-subsystem/c.py"
}

make_known_files() {
  mkdir -p "$PROJECT_DIR/src/known"
  printf 'print(1)\n' > "$PROJECT_DIR/src/known/a.py"
  printf 'print(2)\n' > "$PROJECT_DIR/src/known/b.py"
  printf 'print(3)\n' > "$PROJECT_DIR/src/known/c.py"
}

make_tracked_harness_churn() {
  i=1
  while [ "$i" -le 100 ]; do
    printf '# tracked Claude harness churn %s\n' "$i" >> "$PROJECT_DIR/.claude/primers/INDEX.md"
    i=$((i + 1))
  done
  mkdir -p "$PROJECT_DIR/.codex"
  i=1
  while [ "$i" -le 101 ]; do
    printf 'tracked Codex state %s\n' "$i" >> "$PROJECT_DIR/.codex/fixture-state"
    i=$((i + 1))
  done
  git -C "$PROJECT_DIR" add .codex/fixture-state
  mkdir -p "$PROJECT_DIR/src/new-subsystem"
  printf 'print(1)\n' > "$PROJECT_DIR/src/new-subsystem/only.py"
}

make_non_ascii_harness_churn() {
  mkdir -p "$PROJECT_DIR/.claude/primers" "$PROJECT_DIR/.codex" \
    "$PROJECT_DIR/src/new-subsystem"
  i=1
  while [ "$i" -le 201 ]; do
    printf '# tracked non-ASCII Claude harness churn %s\n' "$i" \
      >> "$PROJECT_DIR/.claude/primers/naïve.md"
    i=$((i + 1))
  done
  git -C "$PROJECT_DIR" add .claude/primers/naïve.md
  printf 'untracked non-ASCII Codex state\n' > "$PROJECT_DIR/.codex/naïve-state"
  printf 'print(1)\n' > "$PROJECT_DIR/src/new-subsystem/only.py"
}

@test "edit-heavy predicate: three changed files nudge an INDEX-missing subsystem" {
  make_unknown_files

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s' "$output" | jq -r 'keys | join(",")')" = "additionalContext" ]
  [[ "$(context)" == *"/primer new-subsystem"* ]]
}

@test "harness-state exclusion: tracked churn does not make one user file edit-heavy" {
  make_tracked_harness_churn

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "harness-state exclusion: non-ASCII harness paths stay silent" {
  make_non_ascii_harness_churn

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "edit-heavy predicate: one small changed file stays silent" {
  mkdir -p "$PROJECT_DIR/src/new-subsystem"
  printf 'print(1)\n' > "$PROJECT_DIR/src/new-subsystem/only.py"

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "edit-heavy predicate: one 200-line file nudges" {
  mkdir -p "$PROJECT_DIR/src/new-subsystem"
  i=1
  while [ "$i" -le 200 ]; do
    printf 'print(%s)\n' "$i" >> "$PROJECT_DIR/src/new-subsystem/large.py"
    i=$((i + 1))
  done

  run_hook
  [ "$status" -eq 0 ]
  [[ "$(context)" == *"/primer new-subsystem"* ]]
}

@test "INDEX suppression: indexed entry-point directory does not nudge" {
  make_known_files

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "no-edit turn exits silently" {
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "malformed Stop input fails open without a nudge" {
  make_unknown_files

  run_hook '{not-json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "missing git tool fails open without a nudge" {
  make_unknown_files
  fake_bin="$(mktemp -d "$BATS_TEST_TMPDIR/no-git.XXXXXX")"
  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$fake_bin/git"
  old_path="$PATH"
  PATH="$fake_bin:$PATH"

  run_hook

  PATH="$old_path"
  rm -rf "$fake_bin"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}
