#!/usr/bin/env bats
# Tests for propose-rules.sh — the Phase-8a Stop hook (default-ON per DL-P8a-06)
# that, on edit-heavy turns with a correction signal, dispatches a one-turn
# `claude -p` to propose a gotchas.md rule (advisory, never blocks).
#
# Covers the DL-P8a-06 / DL-P8a-10 / Spec-005 T-P5a contract (the HOOK's
# wiring + gates):
#   (a) umbrella recursion sentinel: TRELLIS_REVIEW_IN_PROGRESS=1 on entry →
#       exit 0 and the stubbed `claude` is NEVER called.
#   (b) default-on path: gate unset + dirty edit-heavy tree + correction signal
#       + transcript present → the hook proceeds to the `claude` call (recorded).
#   (c) edit-heavy gate: a tiny diff (1 file, ~10 lines) below the threshold →
#       exit 0 without calling `claude`.
#   (d) explicit opt-out: PROCESS_GATE_PROPOSE_RULES=0 → exit immediately,
#       `claude` never called.
#   (e) effective L5: append only safe, non-duplicate candidates to canonical
#       root gotchas.md and log the action atomically; L1–L4 stay advisory.
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
    git config user.email "ci-bats@trellis.test"
    git config user.name "Trellis CI"
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
    git config user.email "ci-bats@trellis.test"
    git config user.name "Trellis CI"
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
  [ -n "${WORKTREE:-}" ] && [ -d "$WORKTREE" ] && rm -rf "$WORKTREE"
  [ -n "${CANONICAL_ROOT:-}" ] && [ -d "$CANONICAL_ROOT" ] && rm -rf "$CANONICAL_ROOT"
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset PROJECT_DIR TRANSCRIPT CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR \
        CLAUDE_TRANSCRIPT_PATH CODEX_TRANSCRIPT_PATH TRELLIS_ROOT \
        TRELLIS_FIXTURE TRELLIS_REVIEW_IN_PROGRESS PROCESS_GATE_PROPOSE_RULES \
        WORKTREE CANONICAL_ROOT CANDIDATE
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

# Build a minimal command PATH that intentionally has no perl. The proposal
# command remains discoverable through the optional first directory argument.
make_no_perl_path() {
  local extra="${1:-}" out command_name source_path
  out="$(mktemp -d "$BATS_TMPDIR/propose-no-perl.XXXXXX")"
  for command_name in awk bash cat date dirname env git grep jq mktemp mv python3 rm sed sort tail tr wc; do
    if source_path="$(command -v "$command_name" 2>/dev/null)"; then
      ln -s "$source_path" "$out/$command_name"
    fi
  done
  if [ -n "$extra" ]; then
    printf '%s:%s' "$extra" "$out"
  else
    printf '%s' "$out"
  fi
}


# A linked worktree proves that L5 writes shared records at the canonical root,
# rather than into the ephemeral worktree where the Stop hook happened to run.
setup_l5_worktree_repo() {
  CANONICAL_ROOT="$(mktemp -d "$BATS_TMPDIR/propcanonical.XXXXXX")"
  WORKTREE="$BATS_TMPDIR/propworktree.$$.$RANDOM"
  git init -q "$CANONICAL_ROOT"
  git -C "$CANONICAL_ROOT" config user.email "ci-bats@trellis.test"
  git -C "$CANONICAL_ROOT" config user.name "Trellis CI"
  printf '%s\n' '{"autonomy":5}' > "$CANONICAL_ROOT/.trellis.json"
  printf '# Gotchas\n\n' > "$CANONICAL_ROOT/gotchas.md"
  printf '# Decisions log\n\n' > "$CANONICAL_ROOT/decisions-log.md"
  printf 'fixture\n' > "$CANONICAL_ROOT/README.md"
  git -C "$CANONICAL_ROOT" add .
  git -C "$CANONICAL_ROOT" commit -qm init
  git -C "$CANONICAL_ROOT" worktree add -q -b propose-l5 "$WORKTREE"
  (
    cd "$WORKTREE" || exit 1
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n' > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CLAUDE_PROJECT_DIR="$WORKTREE"
}

setup_safe_candidate() {
  CANDIDATE="$BATS_TEST_TMPDIR/safe-candidate.md"
  cat > "$CANDIDATE" <<'EOF'
## 2026-08-23 — Canonical gotcha writes
**Pattern:** A Stop hook wrote a shared record into a linked worktree.
**Why it matters:** Linked worktrees can be removed, while canonical records must survive.
**Rule:** Write shared gotcha records only at the canonical repository root.
EOF
}

setup_secret_candidate() {
  CANDIDATE="$BATS_TEST_TMPDIR/secret-candidate.md"
  cat > "$CANDIDATE" <<'EOF'
## 2026-08-23 — Unsafe generated value
**Pattern:** A response included api_key="not-a-real-secret".
**Why it matters:** Credential-shaped values must not enter durable guidance.
**Rule:** Never copy credential-shaped values into gotchas.
EOF
}

setup_unquoted_secret_candidate() {
  CANDIDATE="$BATS_TEST_TMPDIR/unquoted-secret-candidate.md"
  cat > "$CANDIDATE" <<'EOF'
## 2026-08-23 — Unsafe generated value
**Pattern:** A response included api_key=not-a-real-secret.
**Why it matters:** Credential-shaped values must not enter durable guidance.
**Rule:** Never copy credential-shaped values into gotchas.
EOF
}

# A response-file variant keeps adversarial candidate content out of generated
# shell quoting while retaining the normal call-count proof.
install_fake_claude_response() {
  local countfile="$1" responsefile="$2" bindir
  bindir="$BATS_TEST_TMPDIR/fakebin-response.$$.$RANDOM"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'
    printf 'printf %s >> %s\n' "'x'" "$(_shq "$countfile")"
    printf 'cat %s\n' "$(_shq "$responsefile")"
  } > "$bindir/claude"
  chmod +x "$bindir/claude"
  printf '%s' "$bindir:$PATH"
}

# Force only the decision-log rename to fail; the hook must atomically restore
# the already-renamed gotchas file instead of leaving an unlogged write behind.
install_fail_decision_mv() {
  local bindir real_mv
  real_mv="$(command -v mv)"
  [ -n "$real_mv" ] || return 1
  bindir="$BATS_TEST_TMPDIR/fakebin-mv.$$.$RANDOM"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'last=""'
    printf '%s\n' 'for arg in "$@"; do last="$arg"; done'
    printf '%s\n' 'case "$last" in */decisions-log.md) exit 1 ;; esac'
    printf 'exec %s "$@"\n' "$(_shq "$real_mv")"
  } > "$bindir/mv"
  chmod +x "$bindir/mv"
  printf '%s' "$bindir:$PATH"
}

# Force the decision-log rename and the subsequent gotchas restore rename to
# fail. The first gotchas rename still succeeds, so the recovery branch must
# retain its backup rather than deleting it.
install_fail_decision_and_restore_mv() {
  local bindir real_mv gotchas_seen
  real_mv="$(command -v mv)"
  [ -n "$real_mv" ] || return 1
  bindir="$BATS_TEST_TMPDIR/fakebin-mv-restore.$$.$RANDOM"
  gotchas_seen="$BATS_TEST_TMPDIR/gotchas-mv-seen.$$.$RANDOM"
  rm -f "$gotchas_seen"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'last=""'
    printf '%s\n' 'for arg in "$@"; do last="$arg"; done'
    printf '%s\n' 'case "$last" in'
    printf '%s\n' '  */decisions-log.md) exit 1 ;;'
    printf '%s\n' '  */gotchas.md)'
    printf '    if [ -e %s ]; then exit 1; fi\n' "$(_shq "$gotchas_seen")"
    printf '    : > %s\n' "$(_shq "$gotchas_seen")"
    printf '%s\n' '    ;;'
    printf '%s\n' 'esac'
    printf 'exec %s "$@"\n' "$(_shq "$real_mv")"
  } > "$bindir/mv"
  chmod +x "$bindir/mv"
  printf '%s' "$bindir:$PATH"
}
# Run the hook with a Stop payload on stdin (default '{}' — not stop_hook_active).
run_hook() {
  local payload='{}'
  if [ "$#" -gt 0 ]; then payload="$1"; fi
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

@test "timeout: missing Perl skips the canonical proposal with one visible degradation" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/proposal-no-perl.count"; : > "$COUNT"
  FAKE_PATH="$(install_fake_claude "$COUNT")"
  FAKE_BIN="${FAKE_PATH%%:*}"
  NO_PERL_PATH="$(make_no_perl_path "$FAKE_BIN")"
  PATH_BACKUP="$PATH"
  export PATH="$NO_PERL_PATH"
  run_hook
  export PATH="$PATH_BACKUP"

  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
  [[ "$stderr" == *"propose-rules"*"Perl"* ]]
  [ "$(printf '%s' "$stderr" | grep -Fc 'Perl')" -eq 1 ]
  rm -rf "$FAKE_BIN" "${NO_PERL_PATH#*:}"
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

# =========================================================================
# (e) Effective L5 is the sole auto-write boundary. These adversarial cases
# prove canonical-root targeting, effective-level gating, secret suppression,
# duplicate suppression, and staged no-partial-write behavior.
# =========================================================================
@test "C locale: L5 accepts hyphen and complete em dash headings" {
  setup_editheavy_repo
  setup_transcript_with_signal
  export LC_ALL=C
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  setup_safe_candidate
  COUNT="$BATS_TEST_TMPDIR/locale.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"
  local delimiter
  for delimiter in '-' '—'; do
    rm -f "$PROJECT_DIR/gotchas.md" "$PROJECT_DIR/decisions-log.md"
    printf '## 2026-08-23 %s Locale heading\n**Pattern:** A heading uses a supported delimiter.\n**Why it matters:** Locale must not change persistence.\n**Rule:** Accept complete supported heading tokens.\n' "$delimiter" > "$CANDIDATE"
    run_hook
    [ "$status" -eq 0 ] || return 1
    [ -z "$stderr" ] || return 1
    [[ "$output" == *"auto-appended the candidate"* ]] || return 1
    grep -Fqx "## 2026-08-23 $delimiter Locale heading" "$PROJECT_DIR/gotchas.md" || return 1
    grep -Fq 'propose-rules auto-appended a surfaced gotcha' "$PROJECT_DIR/decisions-log.md" || return 1
  done
  [ "$(claude_call_count "$COUNT")" -eq 2 ]
}

@test "C locale: L5 rejects unsupported delimiters and malformed required fields" {
  setup_editheavy_repo
  setup_transcript_with_signal
  export LC_ALL=C
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  setup_safe_candidate
  COUNT="$BATS_TEST_TMPDIR/locale-rejected.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"
  local variant heading pattern why rule
  for variant in endash letter date title pattern why rule; do
    heading='## 2026-08-23 — Locale heading'
    pattern='A heading must have required fields.'
    why='Malformed proposals must remain advisory.'
    rule='Reject malformed proposals.'
    case "$variant" in
      endash) heading='## 2026-08-23 – Locale heading' ;;
      letter) heading='## 2026-08-23 x Locale heading' ;;
      date) heading='## 2026-8-23 — Locale heading' ;;
      title) heading='## 2026-08-23 —' ;;
      pattern) pattern='' ;;
      why) why='' ;;
      rule) rule='' ;;
    esac
    printf '%s\n**Pattern:** %s\n**Why it matters:** %s\n**Rule:** %s\n' "$heading" "$pattern" "$why" "$rule" > "$CANDIDATE"
    run_hook
    [ "$status" -eq 0 ] || return 1
    [ -z "$stderr" ] || return 1
    [[ "$output" == *"did not match the required gotcha format"* ]] || return 1
    [ ! -e "$PROJECT_DIR/gotchas.md" ] || return 1
    [ ! -e "$PROJECT_DIR/decisions-log.md" ] || return 1
  done
  [ "$(claude_call_count "$COUNT")" -eq 7 ]
}

@test "Stop payload: an explicit active guard is preserved" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/active.count"; : > "$COUNT"
  PATH="$(install_fake_claude "$COUNT")"
  run_hook '{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -z "$output" ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
}

@test "L5: writes and logs only at canonical root, then suppresses duplicates" {
  setup_l5_worktree_repo
  setup_transcript_with_signal
  setup_safe_candidate
  COUNT="$BATS_TEST_TMPDIR/l5.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 1 ]
  [[ "$output" == *"auto-appended the candidate"* ]]
  [[ "$(cat "$CANONICAL_ROOT/gotchas.md")" == *"## 2026-08-23 — Canonical gotcha writes"* ]]
  [[ "$(cat "$CANONICAL_ROOT/decisions-log.md")" == *"propose-rules auto-appended a surfaced gotcha"* ]]
  [[ "$(cat "$WORKTREE/gotchas.md")" != *"## 2026-08-23 — Canonical gotcha writes"* ]]

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate already exists"* ]]
  [ "$(grep -Fxc "## 2026-08-23 — Canonical gotcha writes" "$CANONICAL_ROOT/gotchas.md")" -eq 1 ]
  [ "$(grep -Fc "propose-rules auto-appended a surfaced gotcha to gotchas.md." "$CANONICAL_ROOT/decisions-log.md")" -eq 1 ]
}

@test "effective L4: a requested L5 clamped by preset stays advisory-only" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5,"presets":["ceiling"]}' > "$PROJECT_DIR/.trellis.json"
  TRELLIS_FIXTURE="$BATS_TEST_TMPDIR/l4-runtime"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets"
  cat > "$TRELLIS_FIXTURE/core-rules/presets/ceiling.md" <<'EOF'
---
autonomy_ceiling: 4
---
EOF
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/l4.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 1 ]
  [[ "$output" == *"review and append if useful"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "L5: secret-like candidate is neither emitted nor persisted" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_secret_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/l5-secret.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret-like material"* ]]
  [[ "$output" != *"not-a-real-secret"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "L5: unquoted secret-key candidates are neither emitted nor persisted" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_unquoted_secret_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/l5-unquoted-secret.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret-like material"* ]]
  [[ "$output" != *"not-a-real-secret"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "L5: an invalid decision log target leaves gotchas byte-unchanged" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  mkdir "$PROJECT_DIR/decisions-log.md"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  COUNT="$BATS_TEST_TMPDIR/l5-atomic.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not atomically append and log"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ -d "$PROJECT_DIR/decisions-log.md" ]
}

@test "L5: a failed decision-log rename rolls back the gotchas append" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/l5-rollback.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"
  PATH="$(install_fail_decision_mv)"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not atomically append and log"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "L5: a failed rollback preserves its backup and recovery path" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/l5-restore-failure.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"
  PATH="$(install_fail_decision_and_restore_mv)"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not restore canonical gotchas.md after the decisions-log write failed"* ]]
  [[ "$output" == *"preserved the intact backup at"* ]]
  backup="$(printf '%s\n' "$PROJECT_DIR"/.gotchas.md.tmp.*)"
  [ -f "$backup" ]
  [[ "$output" == *"$backup"* ]]
  [ "$(cat "$backup")" = "$gotchas_before" ]
  [[ "$(cat "$PROJECT_DIR/gotchas.md")" == *"## 2026-08-23 — Canonical gotcha writes"* ]]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}
