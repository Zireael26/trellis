#!/usr/bin/env bats
# Tests for session-context.sh — SessionStart (startup|resume) hook.
# Covers MEDIUM audit §2.1 fixes:
#   - gotchas detector anchors to headings + status fields (no free-text false-positives)
#   - context-log read window large enough to surface meaningful content from
#     a typical 6-10K log written by save-context-log.sh

load helpers

HOOK="$HOOKS_DIR/session-context.sh"
CODEX_HOOK="$CODEX_HOOKS_DIR/session-context.sh"

setup() {
  # Never read the operator's ~/.trellis; hookspath_ctx overrides per call.
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  setup_project_dir
}

teardown() {
  teardown_project_dir
}

# Extract additionalContext from the hook's JSON output. Claude wraps it in
# hookSpecificOutput; Codex emits it flat. Try Claude shape first, fall back.
extract_ctx() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // .additionalContext // ""'
}

run_hook() {
  local hook="$1"
  printf '%s' '{"source":"startup"}' | bash "$hook"
}

# --- Gotchas detector: heading match ---

@test "M2.1: gotchas detector matches a heading line (## Unresolved)" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Unresolved
Body of the entry.
EOF
  out="$(run_hook "$HOOK")"
  ctx="$(extract_ctx "$out")"
  [[ "$ctx" == *"Unresolved gotchas"* ]] || { echo "$ctx"; false; }
  [[ "$ctx" == *"## Unresolved"* ]]
}

@test "M2.1: gotchas detector matches a deeper heading (### Unresolved gotchas)" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

### Unresolved gotchas
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"### Unresolved gotchas"* ]]
}

@test "M2.1: gotchas detector matches a dated heading containing UNRESOLVED" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## 2026-05-11 — UNRESOLVED: pre-push gate missing
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"UNRESOLVED: pre-push gate missing"* ]]
}

# --- Gotchas detector: status field match ---

@test "M2.1: gotchas detector matches a Status: unresolved field" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

Status: unresolved
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"Status: unresolved"* ]]
}

@test "M2.1: gotchas detector matches a **unresolved** status tag" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

**unresolved**
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"**unresolved**"* ]]
}

# --- Gotchas detector: free-text mentions do NOT match ---

@test "M2.1: gotchas detector ignores free-text 'was unresolved on …'" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Resolved item
This issue is now resolved (was unresolved on 2026-04-01).
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  # Section header should not appear at all because no anchored match exists.
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

@test "M2.1: gotchas detector ignores body text 'mentions unresolved status'" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Resolved item
Some body text mentions unresolved status in passing.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

@test "M2.1: gotchas detector ignores **Fix.** UNRESOLVED. (different bold label)" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Some entry
**Fix.** UNRESOLVED.
EOF
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

# --- Codex parity: same gotchas regex must apply ---

@test "M2.1: Codex copy also ignores free-text mentions" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Resolved item
This issue is now resolved (was unresolved on 2026-04-01).
EOF
  ctx="$(extract_ctx "$(run_hook "$CODEX_HOOK")")"
  [[ "$ctx" != *"Unresolved gotchas"* ]]
}

@test "M2.1: Codex copy matches the same heading shape" {
  cat > "$PROJECT_DIR/gotchas.md" <<'EOF'
# Gotchas

## Unresolved
Body.
EOF
  ctx="$(extract_ctx "$(run_hook "$CODEX_HOOK")")"
  [[ "$ctx" == *"## Unresolved"* ]]
}

# --- Context-log injection size sanity ---

@test "M2.1: 5K context-log → injection contains >1000 chars of log content" {
  # Build a 5K context-log.md whose body is line-numbered so we can prove
  # the new 1200-char window surfaces meaningful content past the header.
  {
    printf '# Context log\n_Saved: 2026-05-20T00:00:00Z_\n\n'
    i=0
    while [ "$i" -lt 100 ]; do
      printf 'line %03d body content for read-window verification\n' "$i"
      i=$((i + 1))
    done
  } > "$PROJECT_DIR/context-log.md"
  ctx="$(extract_ctx "$(run_hook "$HOOK")")"
  [[ "$ctx" == *"context-log.md (previous session)"* ]] || { echo "$ctx"; false; }
  # More than 1000 chars of log body must reach the injection. The pre-fix
  # 800-char window would fail this; the new 1200-char window passes.
  log_len=$(printf '%s' "$ctx" | awk '/context-log.md \(previous session\)/{flag=1;next} /Unresolved gotchas/{flag=0} flag' | wc -c)
  [ "$log_len" -gt 1000 ]
}

# --- spec 055 R4.1/R4.2: core.hooksPath drift line ----------------------------

# A private TRELLIS_HOME whose owner record for PROJECT_DIR enables git hooks
# with a managed dispatcher path; the local core.hooksPath starts at that path.
hookspath_fixture() {
  local previous="${1:-null}" root checkout worktree
  root="$(cd "$PROJECT_DIR" && pwd -P)"
  HP_HOME="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/trellis-home"
  checkout="$(printf '%s' "$root/.git" | shasum -a 256 | awk '{print $1}')"
  worktree="$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')"
  HP_MANAGED="$HP_HOME/state/git-hooks/$checkout"
  mkdir -p "$HP_HOME/state/attachments/$checkout" "$HP_MANAGED"
  jq -n --arg managed "$HP_MANAGED" --argjson previous "$previous" \
    '{git_hooks: {enabled: true, managed_hooks_path: $managed, previous_hooks_path: $previous, pre_push_source: "core-rules/githooks/pre-push"}}' \
    > "$HP_HOME/state/attachments/$checkout/$worktree.json"
  git -C "$PROJECT_DIR" config --local core.hooksPath "$HP_MANAGED"
}

# Run <hook> with the fixture home into $ctx; the git config must be
# byte-identical afterwards (R4.2).
hookspath_ctx() {
  local hook="$1" before
  before="$(shasum -a 256 "$PROJECT_DIR/.git/config")"
  ctx="$(extract_ctx "$(printf '%s' '{"source":"startup"}' | TRELLIS_HOME="$HP_HOME" bash "$hook")")"
  [ "$(shasum -a 256 "$PROJECT_DIR/.git/config")" = "$before" ] || { echo "git config changed"; return 1; }
}

@test "R4.1: each core.hooksPath drift warns with trellis doctor --fix and no git config command" {
  local value
  hookspath_fixture
  for value in ".husky/_" "$HP_HOME/state/git-hooks/other"; do
    git -C "$PROJECT_DIR" config --local core.hooksPath "$value"
    hookspath_ctx "$HOOK"
    [[ "$ctx" == *"core.hooksPath is \"$value\""* ]] || { echo "$value: $ctx"; false; }
    [[ "$ctx" == *'`trellis doctor --fix`'* ]] || { echo "$ctx"; false; }
    [[ "$ctx" != *'git config'* ]] || { echo "$ctx"; false; }
  done
  git -C "$PROJECT_DIR" config --local core.hooksPath .husky/_
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *husky*prepare* ]] || { echo "$ctx"; false; }
  # A duplicated managed value is drift as well.
  git -C "$PROJECT_DIR" config --local core.hooksPath "$HP_MANAGED"
  git -C "$PROJECT_DIR" config --local --add core.hooksPath "$HP_MANAGED"
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *'2 values'*'trellis doctor --fix'* ]] || { echo "$ctx"; false; }
  [[ "$ctx" != *'git config'* ]] || { echo "$ctx"; false; }
  # A trailing empty value is the one git honours, which turns the hooks off.
  git -C "$PROJECT_DIR" config --local --replace-all core.hooksPath "$HP_MANAGED"
  git -C "$PROJECT_DIR" config --local --add core.hooksPath ""
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *"2 values (\"$HP_MANAGED\", \"\")"*'trellis doctor --fix'* ]] || { echo "$ctx"; false; }
}

@test "R4.1: the recorded previous value .husky/_ names the exact restore command and changes no config" {
  local root expected
  hookspath_fixture '".husky/_"'
  git -C "$PROJECT_DIR" config --local core.hooksPath .husky/_
  hookspath_ctx "$HOOK"
  root="$(cd "$PROJECT_DIR" && pwd -P)"
  expected="git -C $(printf '%q' "$root") config --local --replace-all core.hooksPath $(printf '%q' "$HP_MANAGED")"
  [[ "$ctx" == *"local core.hooksPath is the recorded previous value \".husky/_\""*"Operator remedy (report it; never run it yourself): $expected"* ]] || { echo "$ctx"; false; }
  [ "$(grep -c 'Trellis git hooks are not running' <<<"$ctx")" -eq 1 ] || { echo "$ctx"; false; }
  [ "$(git -C "$PROJECT_DIR" config --local --get-all core.hooksPath)" = ".husky/_" ]
}

@test "R4.1: the restore command quotes a root and managed path with spaces and metacharacters" {
  local weird expected home root checkout worktree managed out
  weird="$BATS_TEST_TMPDIR/we ird;x"
  mkdir -p "$weird"
  git -C "$weird" init -q
  home="$BATS_TEST_TMPDIR/home d;x"
  root="$(cd "$weird" && pwd -P)"
  checkout="$(printf '%s' "$root/.git" | shasum -a 256 | awk '{print $1}')"
  worktree="$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')"
  managed="$home/state/git-hooks/$checkout"
  mkdir -p "$home/state/attachments/$checkout" "$managed"
  jq -n --arg managed "$managed" \
    '{git_hooks: {enabled: true, managed_hooks_path: $managed, previous_hooks_path: ".husky/_", pre_push_source: "core-rules/githooks/pre-push"}}' \
    > "$home/state/attachments/$checkout/$worktree.json"
  git -C "$weird" config --local core.hooksPath .husky/_
  out="$(TRELLIS_HOME="$home" bash -c '. "$1"; trellis_hookspath_drift_line "$2"' _ "$HOOKS_DIR/lib/hookspath-check.sh" "$weird")"
  expected="git -C $(printf '%q' "$root") config --local --replace-all core.hooksPath $(printf '%q' "$managed")"
  [[ "$out" == *"Operator remedy (report it; never run it yourself): $expected" ]] || { echo "$out"; false; }
  [ "$(git -C "$weird" config --local --get-all core.hooksPath)" = ".husky/_" ]
}

@test "R4.1: the managed value alone gives no line" {
  hookspath_fixture
  hookspath_ctx "$HOOK"
  [[ "$ctx" != *'core.hooksPath'* ]] || { echo "$ctx"; false; }
}

@test "R4.1: the Codex copy warns in place through the declared runtime" {
  export TRELLIS_ROOT
  TRELLIS_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
  hookspath_fixture
  git -C "$PROJECT_DIR" config --local core.hooksPath .husky/_
  hookspath_ctx "$CODEX_HOOK"
  [[ "$ctx" == *'core.hooksPath is ".husky/_"'*'`trellis doctor --fix`'* ]] || { echo "$ctx"; false; }
  [[ "$ctx" != *'git config'* ]]
  git -C "$PROJECT_DIR" config --local core.hooksPath "$HP_MANAGED"
  hookspath_ctx "$CODEX_HOOK"
  [[ "$ctx" != *'core.hooksPath'* ]] || { echo "$ctx"; false; }
}

# --- 1.3.12 A4: deferred attachment checks status ------------------------------

# The hookspath fixture's owner gains an attachment ID; the status file is the
# job's, keyed to that ID and to the owner record's digest.
status_fixture() {
  local root checkout worktree tmp
  hookspath_fixture
  root="$(cd "$PROJECT_DIR" && pwd -P)"
  checkout="$(printf '%s' "$root/.git" | shasum -a 256 | awk '{print $1}')"
  worktree="$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')"
  ST_OWNER="$HP_HOME/state/attachments/$checkout/$worktree.json"
  tmp="$(jq '.attachment_id = "6f1c2a4e-0d7b-4c39-9a51-2b8e7f3d1c05"' "$ST_OWNER")"
  printf '%s\n' "$tmp" > "$ST_OWNER"
  ST_FILE="$HP_HOME/state/attachment-status/$checkout/$worktree.json"
  mkdir -p "${ST_FILE%/*}"
}

# write_session_status <state> [age-seconds] [owner-sha256]
write_session_status() {
  local sha="${3:-$(shasum -a 256 "$ST_OWNER" | awk '{print $1}')}"
  jq -n --arg state "$1" --arg sha "$sha" --argjson at "$(( $(date +%s) - ${2:-0} ))" '
    {schema_version:1,state:$state,checkout_id:"c",worktree_id:"w",
     attachment_id:"6f1c2a4e-0d7b-4c39-9a51-2b8e7f3d1c05",owner_sha256:$sha,updated_at:$at,checks:[],
     failure:(if $state == "failed" then {check:"exclude",code:3,remedy:"restore the recorded exclude block"}
              elif $state == "blocked-by-journal" then {check:"journal",code:3,remedy:"trellis recover /x"}
              else null end)}' > "$ST_FILE"
}

@test "A4: FAILED and blocked attachment checks give one WARN line with the remedy, in both copies" {
  local hook
  export TRELLIS_ROOT
  TRELLIS_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
  status_fixture
  for hook in "$HOOK" "$CODEX_HOOK"; do
    write_session_status failed
    hookspath_ctx "$hook"
    [[ "$ctx" == *'Trellis attachment checks FAILED in this worktree (exclude)'*'restore the recorded exclude block'* ]] || { echo "$hook: $ctx"; false; }
    [ "$(printf '%s\n' "$ctx" | grep -c 'Trellis attachment checks')" -eq 1 ]
    write_session_status blocked-by-journal
    hookspath_ctx "$hook"
    [[ "$ctx" == *'Trellis attachment checks are blocked'*'trellis recover /x'* ]] || { echo "$hook: $ctx"; false; }
  done
}

# Session context reaches agents as instructions. A worker once ran
# `trellis doctor --fix` from the stale advisory against its brief (2026-10-19),
# so every remedy is introduced as an operator remedy, never as an imperative.
@test "every drift and attachment-check remedy is marked as an operator remedy, in both copies" {
  local hook state op='Operator remedy (report it; never run it yourself): '
  export TRELLIS_ROOT
  TRELLIS_ROOT="$(cd "$HOOKS_DIR/../.." && pwd -P)"
  status_fixture
  for hook in "$HOOK" "$CODEX_HOOK"; do
    for state in failed blocked-by-journal pending stale; do
      case "$state" in
        stale) write_session_status ok 0 "$(printf '0%.0s' $(seq 64))" ;;
        *) write_session_status "$state" 7200 ;;
      esac
      hookspath_ctx "$hook"
      [ "$(printf '%s\n' "$ctx" | grep -c 'Trellis attachment checks')" -eq 1 ] || { echo "$hook $state: $ctx"; false; }
      [[ "$(printf '%s\n' "$ctx" | grep 'Trellis attachment checks')" == *"$op"* ]] || { echo "$hook $state: $ctx"; false; }
    done
    git -C "$PROJECT_DIR" config --local core.hooksPath "$HP_HOME/state/git-hooks/other"
    hookspath_ctx "$hook"
    [[ "$(printf '%s\n' "$ctx" | grep 'Trellis git hooks are not running')" == *"$op"'`trellis doctor --fix`'* ]] || { echo "$hook drift: $ctx"; false; }
    git -C "$PROJECT_DIR" config --local core.hooksPath "$HP_MANAGED"
  done
}

@test "A4: stale and long-PENDING checks warn; fresh PENDING, ok and a missing status stay silent" {
  status_fixture
  hookspath_ctx "$HOOK"
  [[ "$ctx" != *'Trellis attachment checks'* ]] || { echo "missing: $ctx"; false; }
  write_session_status ok
  hookspath_ctx "$HOOK"
  [[ "$ctx" != *'Trellis attachment checks'* ]] || { echo "ok: $ctx"; false; }
  write_session_status pending 30
  hookspath_ctx "$HOOK"
  [[ "$ctx" != *'Trellis attachment checks'* ]] || { echo "fresh pending: $ctx"; false; }
  write_session_status pending 7200
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *'Trellis attachment checks have been pending for 120 min'*'`trellis doctor --fix`'* ]] || { echo "$ctx"; false; }
  write_session_status running 7200
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *'Trellis attachment checks have been running for 120 min'* ]] || { echo "$ctx"; false; }
  write_session_status ok 0 "$(printf '0%.0s' $(seq 64))"
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *'Trellis attachment checks are stale'*'`trellis doctor --fix`'* ]] || { echo "stale: $ctx"; false; }
}
