#!/usr/bin/env bats
# A review that no cross-family LLM completed must never mint the idempotency
# marker (trellis-lean H2, coordinator ruling 2026-10-08 #1).
#
# Before the fix, the ladder's hc branch fell through to the deterministic
# rung WITHOUT marking the result degraded when `pi` was absent or failed, and
# the same happened outside hc when `claude` was absent. The deterministic
# envelope carries no `status`; code-review-subagent.sh defaulted a missing
# status to "completed" and wrote .claude/.review-done-<hash>, so that exact
# diff was never sent to a cross-family reviewer while the marker existed.
#
# Controls keep the existing contract: a failed `claude` route stays degraded
# with no marker, and a rung-1 operator override still mints the marker with or
# without an explicit status (legacy override envelopes may omit it).
#
# PORTABLE / MIRROR-CLEAN: fixtures under mktemp/$BATS_TEST_TMPDIR; tools come
# from a curated PATH dir that deliberately omits `pi` and `claude`.

load helpers

HOOK="$HOOKS_DIR/code-review-subagent.sh"
CORE_LIB_DIR="$HOOKS_DIR/lib"

# Curated PATH: standard tools the hook + ladder need, never `pi` or `claude`.
make_reviewerless_bindir() {
  local out cmd src
  out="$(mktemp -d "$BATS_TEST_TMPDIR/bin.XXXXXX")"
  for cmd in bash sh test [ echo printf grep sed awk gawk cat head tail mktemp \
             date git basename dirname readlink id stat rm mv cp mkdir rmdir \
             tr cut sort uniq wc env jq perl python3 shasum cksum touch ls find xargs; do
    src="$(command -v "$cmd" 2>/dev/null)"
    case "$src" in /*) ln -sf "$src" "$out/$cmd" ;; esac
  done
  printf '%s' "$out"
}

# A failing stub for a reviewer CLI (`pi` or `claude`) in its own dir.
make_failing_cli_dir() {
  local name="$1" dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' 'exit 1' > "$dir/$name"
  chmod +x "$dir/$name"
  printf '%s' "$dir"
}

# Three staged non-doc files: clears the MIN_FILES=3 gate and the doc-only skip.
setup_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/unmet.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git -c user.email=ci-bats@trellis.test -c user.name="Trellis CI" commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n'  > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

marker_count() {
  [ -d "$PROJECT_DIR/.claude" ] || { printf '0'; return 0; }
  find "$PROJECT_DIR/.claude" -maxdepth 1 -type f -name '.review-done-*' | wc -l | tr -d ' '
}

setup() {
  setup_repo
  PATH_BACKUP="$PATH"
  BIN="$(make_reviewerless_bindir)"
  unset CODE_REVIEWER_CMD TRELLIS_REVIEW_IN_PROGRESS
}

teardown() {
  export PATH="$PATH_BACKUP"
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR CODE_REVIEWER_CMD HC_SCOPE HC_TERMINAL_ID
  return 0
}

@test "unmet: inside hc with no pi, no marker and the review is reported unmet" {
  export HC_SCOPE=fixture-scope HC_TERMINAL_ID=fixture-terminal PATH="$BIN"
  run_with_stderr "$HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 0 ] || { echo "marker written; stderr: $stderr"; return 1; }
  [[ "$stderr" == *"review unmet"* ]] || { echo "stderr: $stderr"; return 1; }
}

@test "unmet: inside hc with a failing pi, no marker" {
  PI_DIR="$(make_failing_cli_dir pi)"
  export HC_SCOPE=fixture-scope HC_TERMINAL_ID=fixture-terminal PATH="$PI_DIR:$BIN"
  run_with_stderr "$HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 0 ] || { echo "marker written; stderr: $stderr"; return 1; }
}

@test "unmet: outside hc with no claude, no marker" {
  export PATH="$BIN"
  run_with_stderr "$HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 0 ] || { echo "marker written; stderr: $stderr"; return 1; }
}

@test "control: outside hc with a failing claude stays degraded with no marker" {
  CL_DIR="$(make_failing_cli_dir claude)"
  export PATH="$CL_DIR:$BIN"
  run_with_stderr "$HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
  [[ "$stderr" == *"review degraded"* ]] || { echo "stderr: $stderr"; return 1; }
}

@test "control: a rung-1 override with status completed still writes the marker" {
  STUB="$BATS_TEST_TMPDIR/reviewer-completed"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' \
    'printf "%s\n" "{\"status\":\"completed\",\"findings\":[]}"' > "$STUB"
  chmod +x "$STUB"
  export CODE_REVIEWER_CMD="$STUB" PATH="$BIN"
  run_with_stderr "$HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 1 ]
}

@test "control: a legacy rung-1 override without status still writes the marker" {
  STUB="$BATS_TEST_TMPDIR/reviewer-legacy"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' \
    'printf "%s\n" "{\"findings\":[]}"' > "$STUB"
  chmod +x "$STUB"
  export CODE_REVIEWER_CMD="$STUB" PATH="$BIN"
  run_with_stderr "$HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(marker_count)" -eq 1 ]
}

# --- Codex twin: same contract through the deployed .codex layout ---------
deploy_codex_hook() {
  local deploy hookdir
  deploy="$(mktemp -d "$BATS_TEST_TMPDIR/deploy.XXXXXX")"
  hookdir="$deploy/.codex/hooks"
  mkdir -p "$hookdir/lib"
  cp "$CODEX_HOOKS_DIR/code-review-subagent.sh" "$hookdir/code-review-subagent.sh"
  cp "$CORE_LIB_DIR/code-reviewer.sh"           "$hookdir/lib/code-reviewer.sh"
  cp "$CODEX_HOOKS_DIR/lib/deps.sh"             "$hookdir/lib/deps.sh"
  cp "$CODEX_HOOKS_DIR/lib/pm.sh"               "$hookdir/lib/pm.sh"
  cp "$CODEX_HOOKS_DIR/lib/autonomy.sh"         "$hookdir/lib/autonomy.sh"
  chmod +x "$hookdir/code-review-subagent.sh" "$hookdir/lib/code-reviewer.sh"
  printf '%s' "$hookdir/code-review-subagent.sh"
}

codex_marker_count() {
  find "$PROJECT_DIR" -maxdepth 2 -type f -name '.review-done-*' | wc -l | tr -d ' '
}

@test "unmet (Codex): inside hc with no pi, no marker" {
  CODEX_HOOK="$(deploy_codex_hook)"
  unset CLAUDE_PROJECT_DIR
  export CODEX_PROJECT_DIR="$PROJECT_DIR" HC_SCOPE=fixture-scope HC_TERMINAL_ID=fixture-terminal PATH="$BIN"
  run_with_stderr "$CODEX_HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(codex_marker_count)" -eq 0 ] || { echo "marker written; stderr: $stderr"; return 1; }
}

@test "control (Codex): a rung-1 override with status completed still writes the marker" {
  CODEX_HOOK="$(deploy_codex_hook)"
  STUB="$BATS_TEST_TMPDIR/reviewer-codex-completed"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' \
    'printf "%s\n" "{\"status\":\"completed\",\"findings\":[]}"' > "$STUB"
  chmod +x "$STUB"
  unset CLAUDE_PROJECT_DIR
  export CODEX_PROJECT_DIR="$PROJECT_DIR" CODE_REVIEWER_CMD="$STUB" PATH="$BIN"
  run_with_stderr "$CODEX_HOOK" '{}'
  export PATH="$PATH_BACKUP"
  [ "$status" -eq 0 ]
  [ "$(codex_marker_count)" -eq 1 ]
}
