#!/usr/bin/env bats
# Codex mirror tests for propose-rules.sh. Covers the L5-only canonical write,
# decision receipt, duplicate suppression, secret suppression, and L1–L4
# advisory boundary in addition to the baseline Stop-hook behavior.

HOOK="$BATS_TEST_DIRNAME/../propose-rules.sh"

setup_editheavy_repo() {
  PROJECT_DIR="$(mktemp -d "$BATS_TMPDIR/codex-prop.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q
    git config user.email "ci-bats@trellis.test"
    git config user.name "Trellis CI"
    git commit --allow-empty -q -m init
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n' > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CODEX_PROJECT_DIR="$PROJECT_DIR"
  unset CLAUDE_PROJECT_DIR
}

setup_transcript_with_signal() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/codex-transcript.txt"
  {
    printf '%s\n' 'user: please refactor the parser'
    printf '%s\n' 'assistant: done, used a recursive descent approach'
    printf '%s\n' "user: no, do not use recursion here - it overflows on deep input"
  } > "$TRANSCRIPT"
  export CODEX_TRANSCRIPT_PATH="$TRANSCRIPT"
  unset CLAUDE_TRANSCRIPT_PATH
}

teardown() {
  [ -n "${WORKTREE:-}" ] && [ -d "$WORKTREE" ] && rm -rf "$WORKTREE"
  [ -n "${CANONICAL_ROOT:-}" ] && [ -d "$CANONICAL_ROOT" ] && rm -rf "$CANONICAL_ROOT"
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  unset PROJECT_DIR TRANSCRIPT CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR \
        CODEX_TRANSCRIPT_PATH CLAUDE_TRANSCRIPT_PATH TRELLIS_ROOT \
        TRELLIS_FIXTURE TRELLIS_REVIEW_IN_PROGRESS PROCESS_GATE_PROPOSE_RULES \
        WORKTREE CANONICAL_ROOT CANDIDATE
  return 0
}

run_with_stderr() {
  local script="$1" input="$2" stderr_file
  stderr_file="$(mktemp)"
  set +e
  output="$(printf '%s' "$input" | bash "$script" 2>"$stderr_file")"
  status=$?
  set -e
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}

install_fake_claude() {
  local countfile="$1" envfile="${2:-}" bindir
  bindir="$BATS_TEST_TMPDIR/fakebin.$$.$RANDOM"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'
    printf 'printf %s >> %s\n' "'x'" "$(_shq "$countfile")"
    if [ -n "$envfile" ]; then
      printf 'printf %s "${TRELLIS_REVIEW_IN_PROGRESS:-UNSET}" > %s\n' '%s' "$(_shq "$envfile")"
    fi
    printf '%s\n' 'printf "%s\n" "## 2026-07-03 - avoid recursion"'
  } > "$bindir/claude"
  chmod +x "$bindir/claude"
  printf '%s' "$bindir:$PATH"
}

_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

claude_call_count() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  wc -c < "$f" | tr -d ' '
}

# Run a Stop hook from a linked worktree while shared records live in the
# canonical checkout. This catches accidental worktree-local persistence.
setup_l5_worktree_repo() {
  CANONICAL_ROOT="$(mktemp -d "$BATS_TMPDIR/codex-propcanonical.XXXXXX")"
  WORKTREE="$BATS_TMPDIR/codex-propworktree.$$.$RANDOM"
  git init -q "$CANONICAL_ROOT"
  git -C "$CANONICAL_ROOT" config user.email "ci-bats@trellis.test"
  git -C "$CANONICAL_ROOT" config user.name "Trellis CI"
  printf '%s\n' '{"autonomy":5}' > "$CANONICAL_ROOT/.trellis.json"
  printf '# Gotchas\n\n' > "$CANONICAL_ROOT/gotchas.md"
  printf '# Decisions log\n\n' > "$CANONICAL_ROOT/decisions-log.md"
  printf 'fixture\n' > "$CANONICAL_ROOT/README.md"
  git -C "$CANONICAL_ROOT" add .
  git -C "$CANONICAL_ROOT" commit -qm init
  git -C "$CANONICAL_ROOT" worktree add -qb codex-propose-l5 "$WORKTREE"
  (
    cd "$WORKTREE" || exit 1
    printf 'def alpha():\n    return 1\n' > alpha.py
    printf 'def beta():\n    return 2\n' > beta.py
    printf 'def gamma():\n    return 3\n' > gamma.py
    git add -A
  )
  export CODEX_PROJECT_DIR="$WORKTREE"
  unset CLAUDE_PROJECT_DIR
}

setup_safe_candidate() {
  CANDIDATE="$BATS_TEST_TMPDIR/codex-safe-candidate.md"
  cat > "$CANDIDATE" <<'EOF'
## 2026-08-23 — Canonical gotcha writes
**Pattern:** A Stop hook wrote a shared record into a linked worktree.
**Why it matters:** Linked worktrees can be removed, while canonical records must survive.
**Rule:** Write shared gotcha records only at the canonical repository root.
EOF
}

setup_secret_candidate() {
  CANDIDATE="$BATS_TEST_TMPDIR/codex-secret-candidate.md"
  cat > "$CANDIDATE" <<'EOF'
## 2026-08-23 — Unsafe generated value
**Pattern:** A response included api_key="not-a-real-secret".
**Why it matters:** Credential-shaped values must not enter durable guidance.
**Rule:** Never copy credential-shaped values into gotchas.
EOF
}

setup_unquoted_secret_candidate() {
  CANDIDATE="$BATS_TEST_TMPDIR/codex-unquoted-secret-candidate.md"
  cat > "$CANDIDATE" <<'EOF'
## 2026-08-23 — Unsafe generated value
**Pattern:** A response included api_key=not-a-real-secret.
**Why it matters:** Credential-shaped values must not enter durable guidance.
**Rule:** Never copy credential-shaped values into gotchas.
EOF
}

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

run_hook() {
  run_with_stderr "$HOOK" '{}'
}

@test "codex propose-rules syntax is valid" {
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "codex transcript + project vars reach claude with recursion sentinel exported" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/default.count"; : > "$COUNT"
  ENVF="$BATS_TEST_TMPDIR/default.env"; : > "$ENVF"
  PATH="$(install_fake_claude "$COUNT" "$ENVF")"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -ge 1 ]
  [ "$(cat "$ENVF")" = "1" ]
}

@test "codex explicit opt-out exits without invoking claude" {
  setup_editheavy_repo
  setup_transcript_with_signal
  COUNT="$BATS_TEST_TMPDIR/optout.count"; : > "$COUNT"
  PATH="$(install_fake_claude "$COUNT")"
  export PROCESS_GATE_PROPOSE_RULES=0

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 0 ]
}

@test "codex L5 writes and logs at canonical root, then suppresses duplicates" {
  setup_l5_worktree_repo
  setup_transcript_with_signal
  setup_safe_candidate
  COUNT="$BATS_TEST_TMPDIR/codex-l5.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 1 ]
  [[ "$output" == *"auto-appended the candidate"* ]]
  [[ "$output" == *"systemMessage"* ]]
  [[ "$(cat "$CANONICAL_ROOT/gotchas.md")" == *"## 2026-08-23 — Canonical gotcha writes"* ]]
  [[ "$(cat "$CANONICAL_ROOT/decisions-log.md")" == *"propose-rules auto-appended a surfaced gotcha"* ]]
  [[ "$(cat "$WORKTREE/gotchas.md")" != *"## 2026-08-23 — Canonical gotcha writes"* ]]

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate already exists"* ]]
  [ "$(grep -Fxc "## 2026-08-23 — Canonical gotcha writes" "$CANONICAL_ROOT/gotchas.md")" -eq 1 ]
  [ "$(grep -Fc "propose-rules auto-appended a surfaced gotcha to gotchas.md." "$CANONICAL_ROOT/decisions-log.md")" -eq 1 ]
}

@test "codex effective L4 clamps a requested L5 to advisory-only" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5,"presets":["ceiling"]}' > "$PROJECT_DIR/.trellis.json"
  TRELLIS_FIXTURE="$BATS_TEST_TMPDIR/codex-l4-runtime"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets"
  cat > "$TRELLIS_FIXTURE/core-rules/presets/ceiling.md" <<'EOF'
---
autonomy_ceiling: 4
---
EOF
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/codex-l4.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [ "$(claude_call_count "$COUNT")" -eq 1 ]
  [[ "$output" == *"review and append if useful"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "codex L5 secret-like candidate is neither emitted nor persisted" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_secret_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/codex-l5-secret.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret-like material"* ]]
  [[ "$output" != *"not-a-real-secret"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "codex L5 unquoted secret-key candidates are neither emitted nor persisted" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_unquoted_secret_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/codex-l5-unquoted-secret.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret-like material"* ]]
  [[ "$output" != *"not-a-real-secret"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "codex L5 invalid decision log target leaves gotchas byte-unchanged" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  mkdir "$PROJECT_DIR/decisions-log.md"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  COUNT="$BATS_TEST_TMPDIR/codex-l5-atomic.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not atomically append and log"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ -d "$PROJECT_DIR/decisions-log.md" ]
}

@test "codex L5 rolls back gotchas when the decision-log rename fails" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/codex-l5-rollback.count"; : > "$COUNT"
  PATH="$(install_fake_claude_response "$COUNT" "$CANDIDATE")"
  PATH="$(install_fail_decision_mv)"

  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not atomically append and log"* ]]
  [ "$(cat "$PROJECT_DIR/gotchas.md")" = "$gotchas_before" ]
  [ "$(cat "$PROJECT_DIR/decisions-log.md")" = "$decisions_before" ]
}

@test "codex L5 failed rollback preserves its backup and recovery path" {
  setup_editheavy_repo
  setup_transcript_with_signal
  setup_safe_candidate
  printf '# Gotchas\n\n' > "$PROJECT_DIR/gotchas.md"
  printf '# Decisions log\n\n' > "$PROJECT_DIR/decisions-log.md"
  printf '%s\n' '{"autonomy":5}' > "$PROJECT_DIR/.trellis.json"
  gotchas_before="$(cat "$PROJECT_DIR/gotchas.md")"
  decisions_before="$(cat "$PROJECT_DIR/decisions-log.md")"
  COUNT="$BATS_TEST_TMPDIR/codex-l5-restore-failure.count"; : > "$COUNT"
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
