#!/usr/bin/env bats
# S4 safety retained under spec 074 D2: a prefix never earns completed coverage.
# D2 supersedes repeated prefix-review: over-cap changes invoke NO reviewer,
# retain unmet state and emit an actionable notice once per capture identity.
# Tests retain shared-prefix/tail changes, over-cap/no marker, repeated Stop,
# and under-cap successful completion as separate acceptance assertions.
#
# PORTABLE / MIRROR-CLEAN: no absolute machine paths. The hook is located from
# $HOOKS_DIR (helpers.bash, resolved from $BATS_TEST_DIRNAME). Fixtures live in
# a throwaway git repo under mktemp; reviewer stubs + their call-count file live
# under $BATS_TEST_TMPDIR. The deterministic reviewer is injected via the rung-1
# CODE_REVIEWER_CMD override so NO real `claude` is ever invoked.

load helpers

HOOK="$HOOKS_DIR/code-review-subagent.sh"

# --- fixtures -------------------------------------------------------------
# A throwaway git repo whose staged diff exceeds the 200000-byte reviewer cap:
# filler.py holds 4000 identical 80-char lines (~324 KB of diff), so the first
# 200000 bytes of `git diff HEAD` are filler content identical across runs.
# tail.py is the small varying tail placed AFTER the filler alphabetically, so
# rewriting it changes only bytes past the cap. Counts clear the edit-heavy
# gate via added lines; .py clears the doc-only skip.
setup_overcap_repo() {
  local tail_content="$1"
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/projover.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    awk 'BEGIN{line=sprintf("%80s"," "); gsub(/ /,"A",line); for(i=0;i<4000;i++) print line}' > filler.py
    printf '%s\n' "$tail_content" > tail.py
    git add -A
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

# A throwaway git repo with a small staged diff (well under the cap): three
# tiny staged non-doc files, mirroring code-review-block.bats.
setup_undercap_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/projunder.XXXXXX")"
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

teardown() {
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR CODE_REVIEWER_CMD
  return 0
}

# Write an executable rung-1 reviewer stub under $BATS_TEST_TMPDIR and echo its
# path. The stub drains stdin, bumps a call-count file (one byte per call),
# then runs $body. Stub and count-file live OUTSIDE the fixture repo so they
# never perturb the diff hash under test.
#   $1 = stub body (shell);  $2 = call-count file path
make_reviewer_stub() {
  local body="$1" countfile="$2" stub
  stub="$(mktemp "$BATS_TEST_TMPDIR/reviewer.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'
    printf 'printf x >> %s\n' "$(_shq "$countfile")"
    printf '%s\n' "$body"
  } > "$stub"
  chmod +x "$stub"
  printf '%s' "$stub"
}

# Single-quote-escape a path for safe embedding in the generated stub.
_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Count reviewer invocations recorded in the count-file (bytes == calls).
reviewer_call_count() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  wc -c < "$f" | tr -d ' '
}

# Count idempotency markers written under the fixture repo.
marker_count() {
  [ -d "$PROJECT_DIR/.claude" ] || { printf '0'; return 0; }
  find "$PROJECT_DIR/.claude" -maxdepth 1 -type f -name '.review-done-*' | wc -l | tr -d ' '
}

# Run the hook with a Stop payload on stdin (default '{}'), capturing
# rc/stdout/stderr. Mirrors helpers.bash::run_with_stderr but pins the
# Stop-payload default so callers don't repeat it.
run_hook() {
  local payload="${1:-{}}"
  run_with_stderr "$HOOK" "$payload"
}

# =========================================================================
# SAFETY: two diffs sharing the first 200000 bytes must not share one marker.
# Run 1 reviews filler + tail=A; run 2 rewrites only the tail (bytes past the
# cap) to B. Neither oversized change set may be prefix-reviewed or completed.
# =========================================================================
@test "marker: two oversized diffs sharing a prefix never call review or share completion" {
  setup_overcap_repo 'TAIL = "alpha"'
  COUNT="$BATS_TEST_TMPDIR/prefix.count"; : > "$COUNT"
  stub="$(make_reviewer_stub 'printf "%s\n" "{\"status\":\"completed\",\"findings\":[]}"' "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]

  ( cd "$PROJECT_DIR" && printf '%s\n' 'TAIL = "beta"' > tail.py && git add tail.py )

  run_hook
  [ "$status" -eq 0 ]

  [ "$(reviewer_call_count "$COUNT")" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
}

# =========================================================================
# SAFETY: an oversized diff is UNREVIEWED, with no reviewer call or marker.
# =========================================================================
@test "marker: an over-cap diff reports unmet and writes NO marker" {
  setup_overcap_repo 'TAIL = "alpha"'
  COUNT="$BATS_TEST_TMPDIR/overcap.count"; : > "$COUNT"
  stub="$(make_reviewer_stub 'printf "%s\n" "{\"status\":\"completed\",\"findings\":[]}"' "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$stderr" == *'UNREVIEWED'* ]] || { echo "$stderr"; false; }
  [ "$(reviewer_call_count "$COUNT")" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
}

# =========================================================================
# SAFETY: repeated oversized Stops stay unmet without repeating paid review.
# =========================================================================
@test "marker: consecutive over-cap Stops make zero reviewer calls" {
  setup_overcap_repo 'TAIL = "alpha"'
  COUNT="$BATS_TEST_TMPDIR/rerun.count"; : > "$COUNT"
  stub="$(make_reviewer_stub 'printf "%s\n" "{\"status\":\"completed\",\"findings\":[]}"' "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  run_hook
  [ "$status" -eq 0 ]

  [ "$(reviewer_call_count "$COUNT")" -eq 0 ]
  [ "$(marker_count)" -eq 0 ]
}

# =========================================================================
# SAFETY: the full-diff marker rule must not break the normal path — an
# under-cap completed review still writes its idempotency marker exactly once.
# =========================================================================
@test "marker: an under-cap completed review still writes its marker" {
  setup_undercap_repo
  COUNT="$BATS_TEST_TMPDIR/undercap.count"; : > "$COUNT"
  stub="$(make_reviewer_stub 'printf "%s\n" "{\"status\":\"completed\",\"findings\":[]}"' "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(reviewer_call_count "$COUNT")" -eq 1 ]
  [ "$(marker_count)" -eq 1 ]
}
