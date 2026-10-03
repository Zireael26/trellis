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

@test "R4.1: the recorded previous value .husky/_ is still drift" {
  hookspath_fixture '".husky/_"'
  git -C "$PROJECT_DIR" config --local core.hooksPath .husky/_
  hookspath_ctx "$HOOK"
  [[ "$ctx" == *'core.hooksPath is ".husky/_"'*'`trellis doctor --fix`'* ]] || { echo "$ctx"; false; }
  [[ "$ctx" != *'git config'* ]]
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
