#!/usr/bin/env bats
# Tests for the CODEX variant code-review-subagent.sh — the Phase-2b Stop hook
# that dispatches the canonical reviewer ladder against `git diff HEAD` and
# blocks only on a critical finding. Mirror of the Claude suite
# core-rules/hooks/tests/code-review-block.bats, adapted to:
#   - the Codex hook (core-rules/codex/hooks/code-review-subagent.sh),
#   - the Codex Stop payload (stdin JSON; the hook reads only .stop_hook_active),
#   - a DEPLOYED-LAYOUT setup so the hook resolves its core via the REAL
#     "$HOOK_DIR/lib/code-reviewer.sh" — NOT a full stub (the Phase-2a trap: a
#     bug hid because every test set CODE_REVIEWER_CMD (rung 1) and never ran
#     rung 2/3 against the real core).
#
# Covers the Phase-2b hook contract (the lib's own verdict ladder is exercised
# separately in code-reviewer-ladder.bats — here we test the HOOK's wiring):
#   1. fork-bomb sentinel guard (TRELLIS_REVIEW_IN_PROGRESS=1 → never reviews)
#   2. block on a critical finding — against the REAL core (rung 3 deterministic)
#   3. advisory-only finding (exit 0 + {"systemMessage":<review>...})
#   4. fail-open: missing core → exit 0; empty findings → exit 0
#   5. TRELLIS_REVIEW_OVERRIDE defers AND logs a dated line to decisions-log.md
#   6. idempotency (same diff twice → reviewer invoked once)
#   7. RUNG-2 REACHABILITY (regression guard for the Phase-2a composition bug):
#      NO operator CODE_REVIEWER_CMD; fake `claude` on PATH front emits a
#      critical; assert the BUILT-IN reviewer (rung 2) fires AND blocks.
#
# PORTABLE / MIRROR-CLEAN: NO absolute machine paths. All sources resolve from
# $BATS_TEST_DIRNAME; the deployed layout, fixture git repo, stubs and their
# call-count files live under $BATS_TEST_TMPDIR.
#
# *** THE REAL CORE — and why DEPLOY_ROOT is separate from PROJECT_DIR ***
# The hook resolves its ladder as a sibling: bash "$HOOK_DIR/lib/code-reviewer.sh".
# We build a deployed layout under <tmp>/.codex/hooks/ (the hook + lib/) so that
# path resolves to the REAL canonical core. CRUCIALLY the DEPLOY root is a
# DIFFERENT directory from PROJECT_DIR (the git repo under review): the deployed
# code-reviewer.sh contains its own regex EXAMPLES (e.g. `password = "hunter2"`
# and `debugger;` in comments) which the deterministic rung-3 would flag as
# false criticals/importants if it ever appeared in `git diff HEAD`. Keeping the
# two roots disjoint guarantees `.codex/` never lands in the reviewed diff.
#
# *** NEUTRALIZING THE REAL `claude` ***
# The host PATH almost certainly has a real `claude`. Rung 2 of the ladder runs
# `claude -p` whenever it is on PATH and the sentinel is unset — that would be
# slow, costly and nondeterministic. So every test that must exercise the REAL
# rung-3 deterministic reviewer (cases 2, 3, 4) runs the hook under a CURATED
# PATH that has jq + git + coreutils + shasum + perl but NOT `claude`. Case 7
# instead PREPENDS a fake `claude` to that curated PATH to prove rung 2 is
# reachable.

# --- source locations (all relative to this test file) --------------------
# Canonical core dir holding code-reviewer.sh + ui-verify-core.sh:
CORE_LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../../hooks/lib" && pwd)"
# Codex hook + its sibling libs (deps.sh, pm.sh):
CODEX_HOOK_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# =========================================================================
# Build a curated PATH dir holding the standard tools the hook + ladder need
# (jq, git, shasum, perl, coreutils) but DELIBERATELY OMITTING `claude`, so the
# ladder's rung 2 never fires the real binary. Echoes the dir; caller prepends.
# Mirrors helpers.bash::make_jq_free_path but KEEPS jq and ADDS shasum/perl.
# =========================================================================
make_claudeless_bindir() {
  local out
  out="$(mktemp -d "$BATS_TEST_TMPDIR/clbin.XXXXXX")"
  for cmd in bash sh test [ echo printf grep sed awk gawk cat head tail mktemp \
             date git basename dirname readlink id stat rm mv cp mkdir rmdir \
             tr cut sort uniq wc env jq perl shasum cksum touch ls find xargs; do
    local src
    src="$(command -v "$cmd" 2>/dev/null)"
    # Only link a resolvable ABSOLUTE path. A bare name (shell builtin/alias, or
    # an interactive shell where `command -v grep` returns just "grep") would
    # produce a self-referential, broken symlink — and the curated PATH must NOT
    # silently drop a tool the hook/ladder relies on (grep, awk, jq, git ...).
    case "$src" in /*) ln -sf "$src" "$out/$cmd" ;; esac
  done
  printf '%s' "$out"
}

# =========================================================================
# Build a DEPLOYED layout under a fresh DEPLOY root and echo the deployed hook
# path. Layout:
#   <deploy>/.codex/hooks/code-review-subagent.sh   (the hook under test)
#   <deploy>/.codex/hooks/lib/code-reviewer.sh       (the REAL canonical core)
#   <deploy>/.codex/hooks/lib/deps.sh                (real sibling lib)
#   <deploy>/.codex/hooks/lib/pm.sh                  (real sibling lib)
# The deploy root is INTENTIONALLY separate from PROJECT_DIR so the deployed
# core never appears in the reviewed `git diff HEAD`.
# =========================================================================
deploy_hook() {
  local deploy hookdir
  deploy="$(mktemp -d "$BATS_TEST_TMPDIR/deploy.XXXXXX")"
  hookdir="$deploy/.codex/hooks"
  mkdir -p "$hookdir/lib"
  cp "$CODEX_HOOK_DIR/code-review-subagent.sh" "$hookdir/code-review-subagent.sh"
  cp "$CORE_LIB_DIR/code-reviewer.sh"          "$hookdir/lib/code-reviewer.sh"
  cp "$CODEX_HOOK_DIR/lib/deps.sh"             "$hookdir/lib/deps.sh"
  cp "$CODEX_HOOK_DIR/lib/pm.sh"               "$hookdir/lib/pm.sh"
  chmod +x "$hookdir/code-review-subagent.sh" "$hookdir/lib/code-reviewer.sh"
  printf '%s' "$hookdir/code-review-subagent.sh"
}

# --- fixture repos --------------------------------------------------------
# A throwaway git repo with HEAD = one empty commit, then THREE staged non-doc
# files so `git diff HEAD` reports 3 changed files (>= the default MIN_FILES=3)
# and at least one is a non-doc (clears the doc-only skip). Staged-but-uncommitted
# new files DO appear in `git diff HEAD` — no second commit needed. .py is used
# (doc extensions .md/.mdx/.rst/.txt would be skipped). Sets PROJECT_DIR; the
# repo is DISJOINT from the deploy root. Caller exports CODEX_PROJECT_DIR.
setup_triggering_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/proj.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n'  > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
}

# Like setup_triggering_repo, but ALSO stages a real committed secret (an AWS
# access key id) in a non-doc file — so the REAL rung-3 deterministic_review
# flags a CRITICAL. AKIA + 16 upper/digit chars == the AKIA[0-9A-Z]{16} regex.
setup_triggering_repo_with_secret() {
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/projsec.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n'  > beta.py
    printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > config.py
    git add -A
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
}

# Like setup_triggering_repo, but stages a left-in debugger statement — the REAL
# rung-3 flags an IMPORTANT (advisory, not blocking). `debugger;` == the rung-3
# important regex. (Rung 3 emits `important`, never `minor`; the advisory path
# treats any non-critical finding as advisory.)
setup_triggering_repo_with_debugger() {
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/projdbg.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'function a() { return 1; }\n' > alpha.js
    printf 'function b() { return 2; }\n' > beta.js
    printf 'function c() { debugger; }\n' > gamma.js
    git add -A
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
}

# A throwaway git repo with three clean (no-secret, no-debugger) non-doc files —
# triggers the threshold but the REAL rung-3 finds nothing → empty findings.
setup_triggering_repo_clean() {
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/projclean.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git commit --allow-empty -q -m init
    printf 'def add(a, b):\n    return a + b\n' > alpha.py
    printf 'def sub(a, b):\n    return a - b\n' > beta.py
    printf 'def mul(a, b):\n    return a * b\n' > gamma.py
    git add -A
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
}

teardown() {
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR CODE_REVIEWER_CMD \
        TRELLIS_REVIEW_IN_PROGRESS TRELLIS_REVIEW_OVERRIDE
  return 0
}

# --- stub builders --------------------------------------------------------
# Build a fake `claude` under a fresh bindir; echo the bindir so the caller can
# PREPEND it to PATH. The fake drains stdin (like the real claude), optionally
# records one byte per call to $countfile, then runs $body. Used by case 7 and
# the idempotency/sentinel count assertions.
#   $1 = body (shell);  $2 = optional call-count file
make_fake_claude_bindir() {
  local body="$1" countfile="${2:-}" bindir
  bindir="$(mktemp -d "$BATS_TEST_TMPDIR/fakebin.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'   # drain the diff on stdin
    if [ -n "$countfile" ]; then
      printf 'printf %s >> %s\n' "'x'" "$(_shq "$countfile")"
    fi
    printf '%s\n' "$body"
  } > "$bindir/claude"
  chmod +x "$bindir/claude"
  printf '%s' "$bindir"
}

# Single-quote-escape a path for safe embedding in a generated stub.
_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Count invocations recorded in a count-file (bytes == calls).
call_count() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  wc -c < "$f" | tr -d ' '
}

# --- hook runner ----------------------------------------------------------
# A realistic Codex Stop payload (the hook reads only .stop_hook_active; the
# other keys are present for fidelity to the confirmed stop.command.input
# schema). Override .stop_hook_active by passing $1=true.
codex_stop_payload() {
  local stop_active="${1:-false}"
  printf '%s' "{\"cwd\":\"/tmp/x\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"done\",\"model\":\"codex\",\"permission_mode\":\"default\",\"session_id\":\"s1\",\"stop_hook_active\":${stop_active},\"transcript_path\":null,\"turn_id\":\"t1\"}"
}

# Run the deployed hook under a CURATED (claude-less unless $EXTRA_BINDIR is set)
# PATH, feeding a Codex Stop payload on stdin. Sets status/output/stderr.
# Globals consumed: HOOK (deployed hook path), CLAUDELESS_BIN, EXTRA_BINDIR opt.
run_hook() {
  local payload="${1:-$(codex_stop_payload false)}"
  local effective_path="$CLAUDELESS_BIN"
  [ -n "${EXTRA_BINDIR:-}" ] && effective_path="$EXTRA_BINDIR:$effective_path"
  local stderr_file
  stderr_file="$(mktemp "$BATS_TEST_TMPDIR/stderr.XXXXXX")"
  set +e
  output="$(printf '%s' "$payload" | PATH="$effective_path" bash "$HOOK" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}

# Common per-test bootstrap: deploy the hook + build the claude-less PATH.
setup() {
  HOOK="$(deploy_hook)"
  CLAUDELESS_BIN="$(make_claudeless_bindir)"
}

# =========================================================================
# 1. Sentinel guard: TRELLIS_REVIEW_IN_PROGRESS=1 short-circuits at the very
# top, BEFORE the threshold and BEFORE the reviewer — even on a triggering
# diff. We prove the GUARD (not the threshold) by using a TRIGGERING repo with
# a planted secret + a fake `claude` on PATH that records calls, and asserting
# the reviewer was NEVER reached (no block, claude never called).
# =========================================================================
@test "sentinel: TRELLIS_REVIEW_IN_PROGRESS=1 exits 0 and never invokes the reviewer" {
  setup_triggering_repo_with_secret
  CLAUDE_COUNT="$BATS_TEST_TMPDIR/sentinel.count"; : > "$CLAUDE_COUNT"
  EXTRA_BINDIR="$(make_fake_claude_bindir \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"x\",\"line\":1,\"msg\":\"secret\"}]}"' \
    "$CLAUDE_COUNT")"
  export TRELLIS_REVIEW_IN_PROGRESS=1

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(call_count "$CLAUDE_COUNT")" -eq 0 ]
}

# =========================================================================
# 2. Block on critical — against the REAL CORE (rung 3, deterministic).
# NO CODE_REVIEWER_CMD, NO fake claude (claude-less PATH) → the ladder falls to
# rung 3, the real deterministic_review flags the planted AWS key as critical,
# and the hook exits 2 with a {"decision":"block",...} object carrying the
# finding. This is the case the Phase-2a trap hid: it runs the real core, not a
# rung-1 stub.
# =========================================================================
@test "block: real core (rung 3) flags planted secret → exit 2 with {\"decision\":\"block\"}" {
  setup_triggering_repo_with_secret

  run_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *'AWS access key'* ]]
  # A blocked turn must NOT advise; it blocks.
  [[ "$output" != *'systemMessage'* ]]
}

# =========================================================================
# 3. Advisory only — against the REAL CORE (rung 3). A left-in `debugger;` →
# the real deterministic_review emits an IMPORTANT (non-critical) finding →
# exit 0 with {"systemMessage":"<review> ... </review>"} and NO block.
# =========================================================================
@test "advisory: real core (rung 3) important finding → exit 0 with <review> systemMessage (no block)" {
  setup_triggering_repo_with_debugger

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"systemMessage"'* ]]
  [[ "$output" == *'<review>'* ]]
  [[ "$output" == *'[important]'* ]]
  [[ "$output" == *'debugger'* ]]
  [[ "$output" != *'"decision":"block"'* ]]
}

# =========================================================================
# 4a. Fail-open (missing core): the deployed ladder is removed → the hook's
# explicit fail-OPEN guard (`[ ! -f "$HOOK_DIR/lib/code-reviewer.sh" ] → exit 0`)
# fires → exit 0, no block, even on a triggering+secret diff.
# =========================================================================
@test "fail-open: missing core (ladder removed) → exit 0, no block" {
  setup_triggering_repo_with_secret
  rm -f "$(dirname "$HOOK")/lib/code-reviewer.sh"

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$output" != *'"decision":"block"'* ]]
}

# =========================================================================
# 4b. Fail-open (empty findings): a clean triggering diff (no secret/debugger)
# runs the REAL rung-3, which returns {"findings":[]} → exit 0, no block, no
# advisory context.
# =========================================================================
@test "fail-open: real core empty findings (clean diff) → exit 0, no block, no advisory" {
  setup_triggering_repo_clean

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]]
  [[ "$output" != *'systemMessage'* ]]
}

# =========================================================================
# 5. Override defers + LOGS: TRELLIS_REVIEW_OVERRIDE=1 → exit 0, reviewer never
# reached, AND a new dated "- 20..." line is appended to decisions-log.md (the
# format session-context.sh greps). The log lands at the canonical repo root
# == PROJECT_DIR/decisions-log.md (REPO_ROOT resolved via _se_repo_root after
# the hook cd's into PROJECT_DIR; the fixture is a non-worktree repo so root ==
# PROJECT_DIR). A fake critical-emitting claude + countfile proves the ladder
# was never reached.
# =========================================================================
@test "override: TRELLIS_REVIEW_OVERRIDE=1 → exit 0 and appends a dated decisions-log line" {
  setup_triggering_repo_with_secret
  CLAUDE_COUNT="$BATS_TEST_TMPDIR/override.count"; : > "$CLAUDE_COUNT"
  EXTRA_BINDIR="$(make_fake_claude_bindir \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"x\",\"line\":1,\"msg\":\"secret\"}]}"' \
    "$CLAUDE_COUNT")"
  export TRELLIS_REVIEW_OVERRIDE=1

  run_hook
  [ "$status" -eq 0 ]
  [ "$(call_count "$CLAUDE_COUNT")" -eq 0 ]

  log="$PROJECT_DIR/decisions-log.md"
  [ -f "$log" ]
  # A line matching the dated format session-context.sh keys off: "- 20YY-...".
  run grep -E '^- 20[0-9][0-9]' "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *'TRELLIS_REVIEW_OVERRIDE'* ]]
}

# =========================================================================
# 6. Idempotency: the SAME diff reviewed twice → the reviewer runs only ONCE.
# The completed-review marker (sha256 of the diff, under .codex/) short-circuits
# the second run. The finding MUST be non-critical: the block path deliberately
# does NOT write the marker (a blocked turn must re-review the corrected diff),
# so a critical would (correctly) be invoked twice. We use a fake claude on PATH
# emitting a MINOR finding (advisory → marker IS written) with a countfile,
# leaving CODE_REVIEWER_CMD unset so rung 2 (the real built-in path) runs it.
# =========================================================================
@test "idempotency: same diff twice → reviewer invoked exactly once" {
  setup_triggering_repo
  CLAUDE_COUNT="$BATS_TEST_TMPDIR/idem.count"; : > "$CLAUDE_COUNT"
  EXTRA_BINDIR="$(make_fake_claude_bindir \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"minor\",\"file\":\"alpha.py\",\"line\":1,\"msg\":\"nit\"}]}"' \
    "$CLAUDE_COUNT")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'[minor]'* ]]
  run_hook
  [ "$status" -eq 0 ]

  [ "$(call_count "$CLAUDE_COUNT")" -eq 1 ]
}

# =========================================================================
# 7. Rung-2 reachability (REGRESSION for the composition bug): with NO operator
# CODE_REVIEWER_CMD set, the hook MUST reach the built-in `claude -p` reviewer
# (rung 2) — not skip straight to the rung-3 regex. A hook-side pre-export of
# TRELLIS_REVIEW_IN_PROGRESS would gut rung 2 (the ladder gates rung 2 on that
# sentinel). We prepend a fake `claude` to the curated PATH that records its
# invocation + emits a critical, leave CODE_REVIEWER_CMD UNSET, and assert (a)
# the fake claude WAS invoked (rung 2 reached through the REAL core) and (b) its
# critical propagated to a block. This is the Phase-2a regression guard on the
# Codex side.
# =========================================================================
@test "rung-2 reachable: no operator cmd → built-in claude (rung 2) IS invoked and its critical blocks" {
  setup_triggering_repo
  CLAUDE_COUNT="$BATS_TEST_TMPDIR/claude.count"; : > "$CLAUDE_COUNT"
  EXTRA_BINDIR="$(make_fake_claude_bindir \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"alpha.py\",\"line\":1,\"msg\":\"eval injection\"}]}"' \
    "$CLAUDE_COUNT")"
  # CODE_REVIEWER_CMD intentionally UNSET → rung 1 skipped, rung 2 must run.

  run_hook
  # Rung 2 was reached: the built-in claude reviewer was actually invoked.
  [ "$(call_count "$CLAUDE_COUNT")" -ge 1 ]
  # And its critical finding propagated to a block.
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *'eval injection'* ]]
}
