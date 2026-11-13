#!/usr/bin/env bats
# Codex mirror contract tests for the Stop-time primer-capture nudge.
#
# Keep these fixtures behavior-identical to core-rules/hooks/tests/primer-
# capture-nudge.bats; only the Stop advisory field differs (systemMessage).

load "$BATS_TEST_DIRNAME/../../../hooks/tests/primer-capture-nudge-bound"

HOOK="$BATS_TEST_DIRNAME/../primer-capture-nudge.sh"

setup() {
  pcn_isolate_environment
  pcn_prepare_hook
  unset CLAUDE_PROJECT_DIR
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/primer-codex.XXXXXX")"
  ( cd "$PROJECT_DIR" && git init -q && git config user.email test@example.com \
      && git config user.name test && git commit --allow-empty -q -m init )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
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
  unset CLAUDE_PROJECT_DIR REVIEW_MIN_FILES REVIEW_MIN_LINES TRELLIS_NO_JQ_DEGRADE
}

teardown() {
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR REVIEW_MIN_FILES REVIEW_MIN_LINES TRELLIS_NO_JQ_DEGRADE
  [ -z "${PROJECT_DIR:-}" ] || rm -rf "$PROJECT_DIR"
}

run_hook() {
  local input="${1:-{}}" stderr_file
  stderr_file="$(mktemp "$BATS_TEST_TMPDIR/primer-stderr.XXXXXX")"
  set +e
  output="$(printf '%s' "$input" | bash "$HOOK" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}

context() {
  printf '%s' "$output" | jq -r '.systemMessage // empty'
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
  [ "$(printf '%s' "$output" | jq -r 'keys | join(",")')" = "systemMessage" ]
  [[ "$(context)" == *"/primer new-subsystem"* ]] || false
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
  [[ "$(context)" == *"/primer new-subsystem"* ]] || false
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

# These cases are shared verbatim with the Claude suite. Invoke Bats with the
# desired bash first on PATH to exercise both macOS Bash 3.2 and Bash 5.
@test "bounded scan: 500000 tracked names stop early with one notice" {
  pcn_process_case flood
}

@test "bounded scan: 500000 expanded untracked names stop early with one notice" {
  pcn_process_case untracked-flood
}

@test "bounded scan: real untracked tree producers receive default PIPE and XFSZ" {
  pcn_pipe_signals_case
}

@test "bounded scan: stalled git and its TERM-ignoring child hit the time budget" {
  pcn_process_case deadline
}

@test "bounded scan: SIGTERM cleans the stalled worker and descendants promptly" {
  pcn_process_case signal
}

@test "bounded scan: SIGTERM is handled even when initially inherited ignored" {
  pcn_process_case signal-ignored
}

@test "bounded scan: ignored SIGCHLD does not defeat descendant cleanup" {
  pcn_process_case sigchld-ignored
}

@test "bounded scan: a healthy PID-1 parent is not mistaken for an orphan" {
  make_unknown_files
  pcn_process_case parent-one
}

@test "bounded scan: immediate parent death cleans descendants even with TERM ignored" {
  pcn_process_case parent-death
}

@test "bounded scan: SIGKILL of supervisor still cleans descendants and temporary files" {
  pcn_process_case supervisor-death
}

@test "bounded scan: stalled stdin is included in the time budget" {
  pcn_process_case stdin
}

@test "bounded scan: blocked stdout is included in the time budget" {
  make_unknown_files
  pcn_process_case stdout-stall
}

@test "bounded scan: blocked stderr cannot prevent timeout cleanup" {
  pcn_process_case stderr-stall
}

@test "bounded scan: timed-out partial advisory is never published" {
  make_unknown_files
  pcn_process_case partial-output
}

@test "bounded scan: stalled temporary directory creation is supervised" {
  pcn_process_case mkdir-stall
}

@test "bounded scan: a temporary-name collision never removes existing files" {
  pcn_process_case mkdir-collision
}

@test "bounded scan: parent death during stalled directory creation leaves no worker" {
  pcn_process_case mkdir-parent-death
}

@test "bounded scan: supervisor death during stalled directory creation leaves no worker" {
  pcn_process_case mkdir-supervisor-death
}

@test "bounded scan: stalled output read cannot outlive the deadline" {
  make_unknown_files
  pcn_process_case output-read-stall
}

@test "bounded scan: TERM interrupts a stalled output read" {
  make_unknown_files
  pcn_process_case output-read-signal
}

@test "bounded scan: stalled temporary cleanup cannot hang the hook" {
  make_unknown_files
  pcn_process_case cleanup-stall
}

@test "bounded scan: exactly 200 changed paths remain eligible for a nudge" {
  pcn_exact_200_case
}

@test "bounded scan: 201 changed paths emit exactly one scan-limit notice" {
  pcn_exact_201_case
}

@test "bounded scan: mixed tracked and untracked paths respect the 200 boundary" {
  pcn_mixed_boundary_case
}

@test "bounded scan: untracked directory expansion respects nested gitignore" {
  pcn_nested_ignore_case
}

@test "bounded scan: ignored dependency trees do not consume the path budget" {
  pcn_ignored_bulk_case
}

@test "bounded scan: nested repository contents do not consume the path budget" {
  pcn_nested_repo_bulk_case
}

@test "bounded scan: untracked root pathspecs are literal" {
  pcn_literal_root_case
}

@test "bounded scan: a spaced untracked path preserves the 199/200 line predicate" {
  pcn_untracked_spaces_and_lines_case
}

@test "bounded scan: oversized advisory is skipped without partial JSON" {
  pcn_output_limit_case
}

@test "bounded scan: Git fsmonitor hooks are not launched" {
  pcn_fsmonitor_disabled_case
}

@test "bounded scan: an untracked symlink preserves the 200-line predicate" {
  pcn_untracked_symlink_lines_case
}

@test "bounded scan: a subdirectory project includes tracked sibling changes" {
  pcn_subdirectory_tracked_case
}

@test "bounded scan: tracked paths with spaces remain intact" {
  pcn_tracked_spaces_case
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
