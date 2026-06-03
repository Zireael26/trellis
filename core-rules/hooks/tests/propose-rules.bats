#!/usr/bin/env bats
# Tests for propose-rules.sh — the Phase-8a Stop hook (default-ON per DL-P8a-06)
# that, on edit-heavy turns with a correction signal, dispatches a one-turn
# `claude -p` to propose a gotchas.md rule (advisory, never blocks).
#
# Covers the DL-P8a-06 / DL-P8a-10 contract (the HOOK's wiring + gates):
#   (a) umbrella recursion sentinel: TRELLIS_REVIEW_IN_PROGRESS=1 on entry →
#       exit 0 and the stubbed `claude` is NEVER called.
#   (b) default-on path: gate unset + dirty edit-heavy tree + correction signal
#       + transcript present → the hook proceeds to the `claude` call (recorded).
#   (c) edit-heavy gate: a tiny diff (1 file, ~10 lines) below the threshold →
#       exit 0 without calling `claude`.
#   (d) explicit opt-out: PROCESS_GATE_PROPOSE_RULES=0 → exit immediately,
#       `claude` never called.
#
# PORTABLE / MIRROR-CLEAN: no absolute machine paths. The hook is located from
# $HOOKS_DIR (helpers.bash, resolved from $BATS_TEST_DIRNAME). Fixtures live in a
# throwaway git repo under mktemp; the `claude` stub is a PATH shim under
# $BATS_TEST_TMPDIR that records each call to a count-file. NO real `claude` is
# ever invoked (the stub shadows it on the front of PATH). The transcript lives
# OUTSIDE the git fixture so it never perturbs `git diff HEAD`. Assertions use
# bash `[[ == ]]` substring matches (portable across GNU/BSD).

load helpers

HOOK="$HOOKS_DIR/propose-rules.sh"

# --- fixtures -------------------------------------------------------------

# A throwaway git repo with HEAD = one empty commit, then an edit-heavy staged
# change: THREE non-doc files (>= default MIN_FILES=3) so `git diff HEAD` clears
# the edit-heavy gate. Staged-but-uncommitted new files DO appear in
# `git diff HEAD` — no second commit needed.
# Sets PROJECT_DIR + exports CLAUDE_PROJECT_DIR (consumed by the hook).
setup_editheavy_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/prop.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n'  > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

# A throwaway git repo with a SINGLE tiny staged file (~10 lines) — below
# MIN_FILES=3 AND below MIN_LINES=200, so the edit-heavy gate exits 0.
setup_below_threshold_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/propsmall.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'a=1\nb=2\nc=3\nd=4\ne=5\nf=6\ng=7\nh=8\ni=9\nj=10\n' > only.py
    git add -A
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

# Create a transcript file OUTSIDE the git fixture whose tail carries an explicit
# correction signal (clears Guard 4). Exports CLAUDE_TRANSCRIPT_PATH.
setup_transcript_with_signal() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.txt"
  {
    printf '%s\n' 'user: please refactor the parser'
    printf '%s\n' 'assistant: done, used a recursive descent approach'
    printf '%s\n' "user: no, do not use recursion here — it overflows on deep input"
  } > "$TRANSCRIPT"
  export CLAUDE_TRANSCRIPT_PATH="$TRANSCRIPT"
}

teardown() {
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR CLAUDE_TRANSCRIPT_PATH CODEX_TRANSCRIPT_PATH \
        TRELLIS_REVIEW_IN_PROGRESS PROCESS_GATE_PROPOSE_RULES
  return 0
}

# Put a fake `claude` on the FRONT of PATH so the hook's `command -v claude`
# resolves it and the `run_with_timeout 30 claude -p ...` invocation runs it.
# The stub drains stdin, records ONE byte per call to $1, captures the value of
# TRELLIS_REVIEW_IN_PROGRESS it SEES (to $2, when given), then prints a proposal
# block (non-NONE) so the hook would emit additionalContext if reached. Echoes
# the modified PATH on stdout for the caller to export.
#   $1 = call-count file path;  $2 = optional env-capture file path
install_fake_claude() {
  local countfile="$1" envfile="${2:-}" bindir
  bindir="$BATS_TEST_TMPDIR/fakebin.$$.$RANDOM"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'                  # drain the prompt+transcript on stdin
    printf 'printf %s >> %s\n' "'x'" "$(_shq "$countfile")"      # record one byte per call
    if [ -n "$envfile" ]; then
      # Capture the sentinel value the child SEES — proves the scoped subshell
      # export (the line-190 child export), not the test env, set it.
      printf 'printf %s "${TRELLIS_REVIEW_IN_PROGRESS:-UNSET}" > %s\n' '%s' "$(_shq "$envfile")"
    fi
    printf '%s\n' 'printf "%s\n" "## 2026-06-03 — avoid recursion"'
  } > "$bindir/claude"
  chmod +x "$bindir/claude"
  printf '%s' "$bindir:$PATH"
}

# Single-quote-escape a path for safe embedding in the generated stub.
_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Count `claude` invocations recorded in the count-file (bytes == calls).
claude_call_count() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  wc -c < "$f" | tr -d ' '
}

# Run the hook with a Stop payload on stdin (default '{}' — not stop_hook_active).
run_hook() {
  local payload="${1:-\{\}}"
  run_with_stderr "$HOOK" "$payload"
}

# =========================================================================
# (a) Sentinel guard: TRELLIS_REVIEW_IN_PROGRESS=1 short-circuits at the very
# top (after the stop_hook_active guard), BEFORE git/threshold/transcript — even
# on a fully triggering setup. We prove the GUARD (not a later gate) by using a
# triggering repo + transcript + signal and asserting `claude` was NEVER called.
# =========================================================================
@test "sentinel: TRELLIS_REVIEW_IN_PROGRESS=1 exits 0 and never invokes claude" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/sentinel.count"; : > "$COUNT"
  PATH="$(install_fake_claude "$COUNT")"
  export TRELLIS_REVIEW_IN_PROGRESS=1

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
}

# =========================================================================
# (b) Default-on path: PROCESS_GATE_PROPOSE_RULES UNSET (default-on), a dirty
# edit-heavy tree (3 files), a correction signal in the transcript, and a
# transcript present → the hook clears every gate and reaches the `claude` call.
# The stub records the invocation. We ALSO assert the child saw
# TRELLIS_REVIEW_IN_PROGRESS=1 — the test env leaves it UNSET (else the entry
# guard would trip), so the child seeing "1" can ONLY come from the scoped
# subshell export wrapping the `claude -p` pipeline (the cross-hook recursion
# prevention half of DL-P8a-06). Proves the export reaches claude's immediate
# process; it does NOT prove `claude -p` propagates it onward to the child's
# Stop hooks (that composition-recursion claim is deferred to the live
# fork-bomb-chain check per DL-P8a-10).
# =========================================================================
@test "default-on: edit-heavy + correction signal + transcript → claude IS invoked with sentinel exported" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/defon.count"; : > "$COUNT"
  ENVF="$BATS_TEST_TMPDIR/defon.env"; : > "$ENVF"
  PATH="$(install_fake_claude "$COUNT" "$ENVF")"
  # PROCESS_GATE_PROPOSE_RULES intentionally UNSET → default-on.
  # TRELLIS_REVIEW_IN_PROGRESS intentionally UNSET in the test env.

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -ge 1 ]
  # The child claude saw the scoped-exported sentinel.
  [ "$(cat "$ENVF")" = "1" ]
}

# =========================================================================
# (c) Edit-heavy gate: a tiny diff (1 file, ~10 lines) is below MIN_FILES=3 AND
# below MIN_LINES=200, so the edit-heavy gate exits 0 — even with a transcript
# and a correction signal present. `claude` must NOT be called.
# =========================================================================
@test "edit-heavy gate: tiny diff below threshold → exit 0, claude NOT invoked" {
  setup_below_threshold_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/small.count"; : > "$COUNT"
  PATH="$(install_fake_claude "$COUNT")"
  # PROCESS_GATE_PROPOSE_RULES UNSET → default-on; only the edit-heavy gate stops it.

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
}

# =========================================================================
# (d) Explicit opt-out: PROCESS_GATE_PROPOSE_RULES=0 → the gate exits 0 before
# any git/transcript work. `claude` must NOT be called, even on a triggering
# setup.
# =========================================================================
@test "opt-out: PROCESS_GATE_PROPOSE_RULES=0 → exit 0 immediately, claude NOT invoked" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/optout.count"; : > "$COUNT"
  PATH="$(install_fake_claude "$COUNT")"
  export PROCESS_GATE_PROPOSE_RULES=0

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
}
