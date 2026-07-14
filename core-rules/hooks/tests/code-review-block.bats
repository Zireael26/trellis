#!/usr/bin/env bats
# Tests for code-review-subagent.sh — the Phase-2a Stop hook that dispatches the
# reviewer ladder against `git diff HEAD` and blocks only on a critical finding.
#
# Covers the Phase-2a hook contract (the lib's own verdict ladder is exercised
# separately in code-reviewer-ladder.bats — here we test the HOOK's wiring):
#   - fork-bomb sentinel guard (TRELLIS_REVIEW_IN_PROGRESS=1 → never reviews)
#   - threshold gate (small 1-file diff → no review)
#   - block on a critical finding (exit 2 + {"decision":"block",...})
#   - advisory-only finding (exit 0 + {"additionalContext":<review>...})
#   - fail-open (reviewer nonzero / empty stdout → exit 0, no block)
#   - TRELLIS_REVIEW_OVERRIDE defers AND logs a dated line to decisions-log.md
#   - idempotency (same diff twice → reviewer invoked once)
#
# PORTABLE / MIRROR-CLEAN: no absolute machine paths. The hook is located from
# $HOOKS_DIR (helpers.bash, resolved from $BATS_TEST_DIRNAME). Fixtures live in a
# throwaway git repo under mktemp; reviewer stubs + their call-count file live
# under $BATS_TEST_TMPDIR. The deterministic reviewer is injected via the rung-1
# CODE_REVIEWER_CMD override so NO real `claude` is ever invoked. Tests pass on
# Linux CI (GNU grep) and macOS (BSD) — assertions use bash `[[ == ]]` substring
# matches, not GNU-only grep.

load helpers

HOOK="$HOOKS_DIR/code-review-subagent.sh"

# --- fixtures -------------------------------------------------------------

# A throwaway git repo with HEAD = one empty commit, then THREE staged non-doc
# files so `git diff HEAD` reports 3 changed files (>= the default MIN_FILES=3)
# and at least one is a non-doc (clears the doc-only skip). Staged-but-uncommitted
# new files DO appear in `git diff HEAD` — no second commit needed. Doc-extension
# files (.md/.mdx/.rst/.txt) would be skipped, so we use .py.
# Sets PROJECT_DIR + exports CLAUDE_PROJECT_DIR (consumed by the hook).
setup_triggering_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/proj.XXXXXX")"
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

# A throwaway git repo with a SINGLE tiny staged file — below MIN_FILES=3 AND
# below MIN_LINES=200, so the threshold gate exits 0 before any review.
setup_below_threshold_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/projsmall.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'x = 1\n' > only.py
    git add -A
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

# A throwaway repo with THREE UNTRACKED (never `git add`ed) non-doc files. They
# do NOT appear in `git diff HEAD` — this is the M3 regression: without untracked
# inclusion the threshold gate would see 0 changed files, exit 0, and never
# review a turn that only CREATED new files (and the reviewer would get a blank
# diff even if it did run). gamma.py carries a sentinel to assert the reviewer
# receives real content, not a hollow diff.
setup_untracked_only_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/projuntr.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n'  > beta.py
    printf 'SECRET_MARKER = "untracked-content-xyz"\n' > gamma.py
    # NB: intentionally NOT `git add`ed — these stay untracked.
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

teardown() {
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR CODE_REVIEWER_CMD TRELLIS_REVIEW_IN_PROGRESS \
        TRELLIS_REVIEW_OVERRIDE REVIEWER_COUNT_FILE
  return 0
}

# Write an executable rung-1 reviewer stub under $BATS_TEST_TMPDIR and echo its
# path. The stub drains stdin (like the real reviewer), optionally bumps a
# call-count file (one byte per call), then runs $body (which prints findings
# and/or sets the exit code). $body is embedded verbatim. Keeping the stub and
# its count-file OUTSIDE the git fixture guarantees they never perturb the diff
# hash the hook keys idempotency on.
#   $1 = stub body (shell);  $2 = optional call-count file path
make_reviewer_stub() {
  local body="$1" countfile="${2:-}" stub
  stub="$(mktemp "$BATS_TEST_TMPDIR/reviewer.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'   # drain the envelope on stdin
    if [ -n "$countfile" ]; then
      printf 'printf %s %s >> %s\n' "'x'" '' "$(_shq "$countfile")"
    fi
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

# Run the hook with a Stop payload on stdin (default '{}' — not stop_hook_active),
# capturing rc/stdout/stderr. Mirrors helpers.bash::run_with_stderr but pins the
# Stop-payload default so callers don't repeat it.
run_hook() {
  local payload="${1:-\{\}}"
  run_with_stderr "$HOOK" "$payload"
}

# =========================================================================
# Sentinel guard: TRELLIS_REVIEW_IN_PROGRESS=1 short-circuits at the very top,
# BEFORE the threshold and BEFORE the reviewer — even on a triggering diff. We
# prove the guard (not the threshold) by using a TRIGGERING repo and asserting
# the reviewer stub was NEVER called.
# =========================================================================
@test "sentinel: TRELLIS_REVIEW_IN_PROGRESS=1 exits 0 and never invokes the reviewer" {
  setup_triggering_repo
  COUNT="$BATS_TEST_TMPDIR/sentinel.count"; : > "$COUNT"
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"x\",\"line\":1,\"msg\":\"secret\"}]}"' \
    "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"
  export TRELLIS_REVIEW_IN_PROGRESS=1

  run_hook
  [ "$status" -eq 0 ]
  [ "$(reviewer_call_count "$COUNT")" -eq 0 ]
}

# =========================================================================
# Below threshold: a single tiny file (< 3 files AND < 200 lines) → the gate
# exits 0 before any review. Reviewer stub must NOT be called.
# =========================================================================
@test "below-threshold: 1-file small diff exits 0 with no review" {
  setup_below_threshold_repo
  COUNT="$BATS_TEST_TMPDIR/small.count"; : > "$COUNT"
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"x\",\"line\":1,\"msg\":\"secret\"}]}"' \
    "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(reviewer_call_count "$COUNT")" -eq 0 ]
}

# =========================================================================
# Block on critical: a rung-1 stub emitting a critical finding → the hook exits
# 2 and stdout is a {"decision":"block",...} object carrying the finding text.
# =========================================================================
@test "block: critical finding → exit 2 with a {\"decision\":\"block\"} object" {
  setup_triggering_repo
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"x\",\"line\":1,\"msg\":\"secret\"}]}"')"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *'secret'* ]]
  # A blocked turn must NOT advise; it blocks.
  [[ "$output" != *'additionalContext'* ]]
}

# =========================================================================
# Advisory only: a rung-1 stub emitting an important/minor finding → exit 0 with
# an {"additionalContext": "<review> ... </review>"} object and NO block.
# =========================================================================
@test "advisory: minor finding → exit 0 with an <review> additionalContext (no block)" {
  setup_triggering_repo
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"minor\",\"file\":\"alpha.py\",\"line\":2,\"msg\":\"prefer a constant\"}]}"')"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"additionalContext"'* ]]
  [[ "$output" == *'<review>'* ]]
  [[ "$output" == *'[minor]'* ]]
  [[ "$output" == *'prefer a constant'* ]]
  [[ "$output" != *'"decision":"block"'* ]]
}

@test "advisory: important finding → exit 0 with an <review> additionalContext (no block)" {
  setup_triggering_repo
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"important\",\"file\":\"beta.py\",\"line\":1,\"msg\":\"missing error handling\"}]}"')"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"additionalContext"'* ]]
  [[ "$output" == *'[important]'* ]]
  [[ "$output" == *'missing error handling'* ]]
  [[ "$output" != *'"decision":"block"'* ]]
}

# =========================================================================
# Fail-open (reviewer error): rung-1 exec swallows the stub's exit code via the
# hook's `|| true`; the hook reacts only to STDOUT. A reviewer that exits nonzero
# with NO stdout must therefore NOT block → exit 0, empty output.
# =========================================================================
@test "fail-open: reviewer exits nonzero with no output → exit 0, no block" {
  setup_triggering_repo
  stub="$(make_reviewer_stub 'exit 7')"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$output" != *'"decision":"block"'* ]]
}

# =========================================================================
# Fail-open (empty findings): a reviewer that emits a well-formed empty verdict
# → exit 0, no block, no advisory context.
# =========================================================================
@test "fail-open: reviewer emits empty findings → exit 0, no block, no advisory" {
  setup_triggering_repo
  stub="$(make_reviewer_stub 'printf "%s\n" "{\"findings\":[]}"')"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]]
  [[ "$output" != *'additionalContext'* ]]
}

# =========================================================================
# Override defers + LOGS: TRELLIS_REVIEW_OVERRIDE=1 → exit 0, reviewer never
# called, AND a new dated "- 20..." line is appended to decisions-log.md (the
# format session-context.sh greps). The log lands at $PROJECT_DIR/decisions-log.md
# (REPO_ROOT == repo top-level after the hook cd's into PROJECT_DIR).
# =========================================================================
@test "override: TRELLIS_REVIEW_OVERRIDE=1 → exit 0 and appends a dated decisions-log line" {
  setup_triggering_repo
  COUNT="$BATS_TEST_TMPDIR/override.count"; : > "$COUNT"
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"x\",\"line\":1,\"msg\":\"secret\"}]}"' \
    "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"
  export TRELLIS_REVIEW_OVERRIDE=1

  run_hook
  [ "$status" -eq 0 ]
  [ "$(reviewer_call_count "$COUNT")" -eq 0 ]

  local log="$PROJECT_DIR/decisions-log.md"
  [ -f "$log" ]
  # A line matching the dated format session-context.sh keys off: "- 20YY-...".
  run grep -E '^- 20[0-9][0-9]' "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *'TRELLIS_REVIEW_OVERRIDE'* ]]
}

# =========================================================================
# L2 / idempotency: the SAME diff reviewed twice → the reviewer runs only ONCE.
# The marker hash is Git-native, so a missing/broken shasum cannot collapse the
# marker to a global `.review-done-` skip key.
# The stub must be NON-critical: the block path deliberately does NOT write the
# marker (a blocked turn must re-review the corrected diff), so a critical stub
# would (correctly) be invoked twice. We use a minor (advisory) stub.
# =========================================================================
@test "L2 idempotency: broken shasum still creates a non-empty Git hash marker and reviews once" {
  setup_triggering_repo
  COUNT="$BATS_TEST_TMPDIR/idem.count"; : > "$COUNT"
  local no_shasum_bin="$BATS_TEST_TMPDIR/no-shasum-bin"
  mkdir -p "$no_shasum_bin"
  cat > "$no_shasum_bin/shasum" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$no_shasum_bin/shasum"
  PATH="$no_shasum_bin:$PATH"
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"minor\",\"file\":\"alpha.py\",\"line\":1,\"msg\":\"nit\"}]}"' \
    "$COUNT")"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 0 ]
  run_hook
  [ "$status" -eq 0 ]

  [ "$(reviewer_call_count "$COUNT")" -eq 1 ]
  [ ! -e "$PROJECT_DIR/.claude/.review-done-" ]
  marker_count=$(find "$PROJECT_DIR/.claude" -maxdepth 1 -type f -name '.review-done-*' | wc -l | tr -d ' ')
  [ "$marker_count" -eq 1 ]
}

# =========================================================================
# Rung-2 reachability (REGRESSION for the composition bug): with NO operator
# CODE_REVIEWER_CMD set, the hook MUST reach the built-in `claude -p` reviewer
# (rung 2) — not skip straight to the rung-3 regex. A hook-side pre-export of
# TRELLIS_REVIEW_IN_PROGRESS would gut rung 2 (the ladder gates rung 2 on that
# sentinel). We put a fake `claude` on the FRONT of PATH that records its
# invocation + emits a critical, leave CODE_REVIEWER_CMD UNSET, and assert (a)
# the fake claude WAS invoked (rung 2 reached) and (b) its critical blocks.
# =========================================================================
@test "rung-2 reachable: no operator cmd → built-in claude (rung 2) IS invoked and its critical blocks" {
  setup_triggering_repo
  CLAUDE_COUNT="$BATS_TEST_TMPDIR/claude.count"; : > "$CLAUDE_COUNT"
  local bindir="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'                       # drain the envelope on stdin
    printf 'printf %s >> %s\n' "'x'" "$(_shq "$CLAUDE_COUNT")"        # record one byte per call
    printf '%s\n' 'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"alpha.py\",\"line\":1,\"msg\":\"eval injection\"}]}"'
  } > "$bindir/claude"
  chmod +x "$bindir/claude"
  # CODE_REVIEWER_CMD intentionally UNSET → rung 1 skipped, rung 2 must run.
  PATH="$bindir:$PATH"

  run_hook
  # Rung 2 was reached: the built-in claude reviewer was actually invoked.
  [ "$(reviewer_call_count "$CLAUDE_COUNT")" -ge 1 ]
  # And its critical finding propagated to a block.
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *'eval injection'* ]]
}

# =========================================================================
# M3 REGRESSION — untracked-file blind spot. `git diff HEAD` omits untracked
# files, so a turn that only CREATES new files used to (a) fall below the
# threshold and skip review entirely, or (b) if it somehow triggered, hand the
# reviewer a blank diff. The fix folds `git ls-files --others` + per-file
# `git diff --no-index` into both the counts AND the reviewer payload.
# =========================================================================
@test "M3 untracked-only: 3 new unstaged files → review IS triggered (not skipped)" {
  setup_untracked_only_repo
  stub="$(make_reviewer_stub \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"gamma.py\",\"line\":1,\"msg\":\"planted\"}]}"')"
  export CODE_REVIEWER_CMD="$stub"

  run_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *'planted'* ]]
}

@test "M3 untracked-only: reviewer receives the untracked file CONTENTS (non-hollow diff)" {
  setup_untracked_only_repo
  CAP="$BATS_TEST_TMPDIR/m3.envelope"
  local bindir="$BATS_TEST_TMPDIR/capbin"; mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'cat > %s\n' "$(_shq "$CAP")"
    printf '%s\n' 'printf "%s\n" "{\"findings\":[]}"'
  } > "$bindir/rev"
  chmod +x "$bindir/rev"
  export CODE_REVIEWER_CMD="$bindir/rev"

  run_hook
  [ "$status" -eq 0 ]
  [ -f "$CAP" ]
  # The envelope's .diff must carry the NEW file's path AND its actual content.
  run jq -r '.diff' "$CAP"
  [[ "$output" == *'gamma.py'* ]]
  [[ "$output" == *'untracked-content-xyz'* ]]
}

@test "M3 untracked-only: scanning untracked files is mutation-free (no git add -N)" {
  setup_untracked_only_repo
  stub="$(make_reviewer_stub 'printf "%s\n" "{\"findings\":[]}"')"
  export CODE_REVIEWER_CMD="$stub"

  local before after
  before="$(cd "$PROJECT_DIR" && git status --porcelain)"
  run_hook
  [ "$status" -eq 0 ]
  after="$(cd "$PROJECT_DIR" && git status --porcelain)"

  # The files stay UNTRACKED (??) before and after — never staged as an
  # addition (A ). A `git add -N` would flip them to 'A ' / 'AM'.
  [[ "$before" == *'?? alpha.py'* ]]
  [[ "$after"  == *'?? alpha.py'* ]]
  [[ "$after"  == *'?? gamma.py'* ]]
  [[ "$after" != *'A  alpha.py'* ]]
  [[ "$after" != *'A  gamma.py'* ]]
}
