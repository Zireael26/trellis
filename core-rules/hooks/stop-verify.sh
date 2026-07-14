#!/usr/bin/env bash
# stop-verify.sh — Stop. TodoWrite → typecheck → lint → test, auto-detected.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - TRELLIS_REVIEW_IN_PROGRESS=1: exit 0 immediately (nested-review guard).
#   - stop_hook_active guard: if set, exit 0 immediately (infinite-loop guard).
#   - Pure chat / no edits: exit 0 (skip).
#   - Runs checks in order. On any failure, emit
#     {"decision":"block","reason":"<step>: <sliced output>"} and exit 2.
#   - Error slicing: typecheck/lint → first 30 lines; tests → last 30 lines.
#   - Budget: 90s soft cap.
#
# Subtree scoping: when every changed file in this turn sits under a single
# subdirectory that carries its own manifest (package.json, go.mod,
# pyproject.toml, or Cargo.toml), checks run scoped to that subtree instead
# of repo root. Cuts wall time + noise on monorepos. Escape hatch:
# PROCESS_GATE_FORCE_ROOT=1 → always run at repo root (legacy behaviour).
#
# Dependencies: jq (required). Toolchains are detected; absence → skip that step.
#
# Todo state: read from $CLAUDE_PROJECT_DIR/.claude/todos.json. If missing or
# unparseable, we pass that step (don't block). This matches Claude Code's
# current persistence location; if that location changes, override via
# project `.claude/hooks/config.sh` exporting TODOS_FILE.
#
# Base: github.com/iamfakeguru/claude-md (MIT). Extensions vs upstream:
#   - Step 1: TodoWrite state check (receipts-required enforcement).
#   - Go support (go vet / go test / golangci-lint).
#   - Test output uses last-30 lines; lint/typecheck use first-30.
#   - Subtree scoping (auto-detects nested manifests; PROCESS_GATE_FORCE_ROOT escape).

set -u

# Nested reviewers inherit the parent's dirty worktree. Do not make their Stop
# event run the parent turn's verifier (or recursively gate reviewer teardown).
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "stop-verify: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "stop-verify"

# Optional: package-manager resolver (config-driven, lockfile fallback). Absent
# copy → test step falls back to npm (legacy behaviour).
__se_pm_lib="$(dirname "${BASH_SOURCE[0]}")/lib/pm.sh"
# shellcheck source=lib/pm.sh disable=SC1090
[ -f "$__se_pm_lib" ] && . "$__se_pm_lib"

# --- Guard 1: stop_hook_active ---
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Fail-counter state: absolute under the canonical project root (NOT a subtree —
# emit_block fires both before and after the subtree cd). A clean pass removes it.
STATE_FILE="${PROJECT_DIR}/.claude/.fail-counter"

# _se_changed_files — echo the full set of files changed this turn, one per line:
# tracked diff-vs-HEAD UNION untracked (not-yet-`git add`ed). Mirrors the union
# in _se_find_subtree. cwd-independent (git -C PROJECT_DIR) so it's stable on
# both sides of the subtree cd. `git diff HEAD --name-only` alone OMITS untracked
# new files — a turn that only Writes new code files would otherwise look empty.
# Filter the hook's OWN state file: where .claude/ is committed (not gitignored,
# as in Trellis projects) ls-files would otherwise surface .claude/.fail-counter,
# (a) destabilising the file-set hash between consecutive blocks (counter never
# reaches 2) and (b) making a code-revert-plus-doc-edit turn read as non-doc.
# Exact path only — a genuine .claude/settings.json edit still needs a receipt.
_se_changed_files() {
  { git -C "$PROJECT_DIR" diff HEAD --name-only 2>/dev/null; \
    git -C "$PROJECT_DIR" ls-files --others --exclude-standard 2>/dev/null; } \
    | grep -vxF '.claude/.fail-counter' \
    | sort -u
}

emit_block() {
  local step="$1"
  local output="$2"

  # --- Fail-counter: count consecutive blocks against the SAME changed file-set.
  # File-set hash is cwd-independent (git -C PROJECT_DIR) so it's stable whether
  # emit_block fires before or after the subtree cd. cksum is POSIX-portable
  # (macOS has no sha256sum); we key off the set of changed paths, not contents.
  local fileset_hash prevhash prevcount count
  fileset_hash=$(_se_changed_files | cksum | awk '{print $1}')
  prevhash=""
  prevcount=0
  if [ -f "$STATE_FILE" ]; then
    read -r prevhash prevcount < "$STATE_FILE"
  fi
  prevcount=${prevcount:-0}
  if [ "$prevhash" = "$fileset_hash" ]; then
    count=$((prevcount + 1))
  else
    count=1
  fi
  mkdir -p "${PROJECT_DIR}/.claude" 2>/dev/null || true
  printf '%s %s\n' "$fileset_hash" "$count" > "$STATE_FILE" 2>/dev/null || true

  local reason="${step}: ${output}"
  if [ "$count" -ge 2 ]; then
    reason="${reason}
STOP: re-read top-down, state the wrong assumption before retrying (same files failed ${count} times)."
  fi
  jq -nc --arg reason "$reason" '{decision: "block", reason: $reason}'
  exit 2
}

# _se_find_subtree — echo the deepest subtree (relative to PROJECT_DIR) that
# contains every changed file in this turn AND carries its own manifest. Echo
# nothing if changed files span multiple subtrees, none have a nested manifest,
# or git isn't here. Quiet by design.
_se_find_subtree() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local file dir found common=""

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    dir="$(dirname "$file")"
    found=""
    # Walk up. Stop one level above the worktree root.
    while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
      if [ -f "$dir/package.json" ] || [ -f "$dir/go.mod" ] \
         || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Cargo.toml" ]; then
        found="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done

    # File has no nested manifest above it → caller falls back to repo root.
    [ -z "$found" ] && return 0

    if [ -z "$common" ]; then
      common="$found"
    elif [ "$common" != "$found" ]; then
      # Changed files span multiple subtrees → fall back to repo root.
      return 0
    fi
  done < <(
    { git diff --name-only HEAD 2>/dev/null; \
      git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
  )

  printf '%s' "$common"
}

# --- Step 1: TodoWrite check (runs before the dirty-tree skip — pure-chat turns
# can close todos via TodoWrite without touching files; receipts-required must
# still hold). ---
TODOS_FILE="${TODOS_FILE:-${PROJECT_DIR}/.claude/todos.json}"
if [ -f "$TODOS_FILE" ]; then
  # Grab any pending/in_progress task content. If jq errors, we silently pass.
  OPEN_TODOS=$(jq -r '
    [.. | objects | select(.status? == "in_progress" or .status? == "pending")]
    | map("- [\(.status)] \(.content // .task // "?")")
    | .[]
  ' "$TODOS_FILE" 2>/dev/null | head -20)

  if [ -n "$OPEN_TODOS" ]; then
    emit_block "TodoWrite" "open tasks remain — complete, defer with reason, or abandon with reason:
${OPEN_TODOS}"
  fi
fi

# --- Guard 2: no file edits this turn → pure chat; skip typecheck/lint/test.
# Best-effort: check git worktree dirtiness. If git isn't here, fall through
# and let downstream steps no-op when no config files exist.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Porcelain output is empty iff worktree matches HEAD (no staged, unstaged, or untracked changes).
  # NOTE: earlier versions used `grep -c '^' || echo 0` here — that doubles output to "0\n0"
  # when empty (grep -c prints 0 AND exits non-zero), breaking the numeric test.
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    # Nothing changed this turn → treat as pure chat and skip checks.
    exit 0
  fi
fi

# --- Subtree scoping. If every changed file shares one subtree with its own
# manifest, run scoped checks there instead of repo-root. Opt-out:
# PROCESS_GATE_FORCE_ROOT=1.
if [ "${PROCESS_GATE_FORCE_ROOT:-0}" != "1" ]; then
  SUBTREE="$(_se_find_subtree)"
  if [ -n "$SUBTREE" ] && [ -d "$SUBTREE" ]; then
    cd "$SUBTREE" 2>/dev/null || true
  fi
fi

CHECKS_RUN=0

# --- Step 2: Typecheck ---
# TypeScript
if [ -f "tsconfig.json" ] && command -v npx >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(npx --no-install tsc --noEmit 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "typecheck (tsc)" "$SLICED"
  fi
fi

# Python (mypy)
if command -v mypy >/dev/null 2>&1; then
  HAS_MYPY_CFG=0
  [ -f "mypy.ini" ] && HAS_MYPY_CFG=1
  if [ -f "pyproject.toml" ] && grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; then
    HAS_MYPY_CFG=1
  fi
  if [ "$HAS_MYPY_CFG" = "1" ]; then
    CHECKS_RUN=$((CHECKS_RUN + 1))
    OUT=$(mypy . 2>&1)
    if [ $? -ne 0 ]; then
      SLICED=$(printf '%s' "$OUT" | head -30)
      emit_block "typecheck (mypy)" "$SLICED"
    fi
  fi
fi

# Rust
if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(cargo check 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "typecheck (cargo check)" "$SLICED"
  fi
fi

# Go
if [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(go vet ./... 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "typecheck (go vet)" "$SLICED"
  fi
fi

# --- Step 3: Lint (repo-wide) ---
# ESLint
if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.cjs" ] \
   || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f ".eslintrc.yaml" ] \
   || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ] || [ -f "eslint.config.ts" ]; then
  if command -v npx >/dev/null 2>&1 && npx --no-install eslint --version >/dev/null 2>&1; then
    CHECKS_RUN=$((CHECKS_RUN + 1))
    OUT=$(npx --no-install eslint . --quiet 2>&1)
    if [ $? -ne 0 ]; then
      SLICED=$(printf '%s' "$OUT" | head -30)
      emit_block "lint (eslint)" "$SLICED"
    fi
  fi
fi

# ruff
if command -v ruff >/dev/null 2>&1 && { [ -f "pyproject.toml" ] || [ -f "ruff.toml" ] || [ -f ".ruff.toml" ]; }; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(ruff check . 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "lint (ruff)" "$SLICED"
  fi
fi

# clippy
if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(cargo clippy --quiet --message-format=short -- -D warnings 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "lint (clippy)" "$SLICED"
  fi
fi

# golangci-lint
if [ -f "go.mod" ] && command -v golangci-lint >/dev/null 2>&1; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(golangci-lint run 2>&1)
  if [ $? -ne 0 ]; then
    SLICED=$(printf '%s' "$OUT" | head -30)
    emit_block "lint (golangci-lint)" "$SLICED"
  fi
fi

# --- Step 4: Test (fast suite; skip e2e unless explicitly configured) ---
TEST_CMD=""
if [ -f "package.json" ] && command -v jq >/dev/null 2>&1; then
  HAS_TEST=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  if [ -n "$HAS_TEST" ] && [ "$HAS_TEST" != "echo \"Error: no test specified\" && exit 1" ]; then
    if command -v trellis_resolve_pm >/dev/null 2>&1; then
      _PM="$(trellis_resolve_pm "$PROJECT_DIR")"
    else
      _PM="npm"
    fi
    # Configured-but-missing PM → skip the test step rather than hard-fail.
    if [ -n "$_PM" ] && command -v "$_PM" >/dev/null 2>&1; then
      TEST_CMD="$_PM run test"
    fi
  fi
elif { [ -f "pyproject.toml" ] || [ -f "pytest.ini" ] || [ -f "setup.cfg" ]; } && command -v pytest >/dev/null 2>&1; then
  TEST_CMD="pytest --tb=short -q"
elif [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  TEST_CMD="cargo test --quiet"
elif [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  TEST_CMD="go test ./..."
fi

if [ -n "$TEST_CMD" ]; then
  CHECKS_RUN=$((CHECKS_RUN + 1))
  OUT=$(eval "$TEST_CMD" 2>&1)
  if [ $? -ne 0 ]; then
    # Tests: last 30 lines (stack traces / assertions land at the end).
    SLICED=$(printf '%s' "$OUT" | tail -30)
    emit_block "test (${TEST_CMD})" "$SLICED"
  fi
fi

# --- Step 5: Receipts gate — structural done-detection. -----------------------
# Reached only on a dirty tree (pure-chat clean-tree skip already exited) with no
# open todos (TodoWrite check already blocked) and all configured checks passed.
# Runs even when CHECKS_RUN==0: a code change with no toolchain STILL needs a
# receipt. Placed BEFORE the CHECKS_RUN==0 advisory so it gates that path too.
if [ "${PROCESS_GATE_NO_RECEIPTS:-0}" != "1" ]; then
  # Doc-only skip: every changed file has a doc extension (.md/.mdx/.rst/.txt).
  # Reuse code-review-subagent's final-path-segment anchor + NONDOC_COUNT==0
  # logic, but over the diff-UNION-untracked set (a turn that only Writes new
  # code files has an empty `git diff HEAD` — those must NOT read as doc-only).
  NONDOC_COUNT=$(_se_changed_files \
    | grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
    | awk 'END{print NR}')
  if [ "$NONDOC_COUNT" != "0" ]; then
    # Read transcript path from the Stop envelope. Missing or absent file → the
    # receipt is unverifiable in this harness (e.g. Codex / no transcript_path):
    # fail OPEN with an advisory rather than block.
    TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
    if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
      rm -f "$STATE_FILE"
      jq -nc '{additionalContext: "stop-verify: receipts unverifiable (no transcript_path in this harness envelope); state your DoD receipt to the user."}'
      exit 0
    fi

    # Turn-scoping (load-bearing): a receipt from a PRIOR turn must not satisfy
    # THIS turn. The transcript is JSONL. Emit one role per input line (1:1 map,
    # robust to malformed lines via fromjson? // "null"), find the LAST user-role
    # line, and search ONLY lines after it. No user line → scope whole file.
    LAST_USER=$(jq -rR '(fromjson? | (.message.role // .role)) // "null"' "$TRANSCRIPT" 2>/dev/null \
      | grep -n '^user$' | tail -1 | cut -d: -f1)
    # Canonical marker: <!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->
    # ERE matches the fields IN ORDER and requires FILLED values, not just field
    # names: `exit=[0-9]` (a digit must follow, rejecting the literal `exit=<int>`)
    # and `diff=.*\+[0-9]` (a `+<digit>` must appear, rejecting `+N/-M`). Without
    # this, the unfilled template the block message prints below would itself
    # satisfy the gate. Anchoring on `\+[0-9]` (not the quote char) is agnostic to
    # JSONL-escaped (\") vs unescaped (") quoting. See CLAUDE.md:43.
    # Follow-ups marker (spec 012): <!-- follow-ups: <count> --> or
    # <!-- follow-ups: none -->, emitted alongside the DoD receipt. The ERE
    # requires a FILLED value (`none` or digits) after the literal
    # `follow-ups: `, so the warn message's deliberately-unfilled template
    # `<count-or-none>` can never satisfy it (`<` follows the colon-space —
    # same tightening trick as `exit=[0-9]` above). Distinct literals mean no
    # cross-collision with dod-receipt parsing in either direction, and the
    # marker carries no quote characters, so it is immune to JSONL
    # \"-escaping differences by construction.
    FOLLOWUPS_RE='<!-- follow-ups: (none|[0-9]+) -->'
    if awk -v n="${LAST_USER:-0}" 'NR>n' "$TRANSCRIPT" \
         | grep -Eq '<!-- dod-receipt .*cmd=.*exit=[0-9].*diff=.*\+[0-9].*-->'; then
      rm -f "$STATE_FILE"
      # Follow-ups nudge (spec 012 D4): receipt present — re-scan the SAME
      # turn-scoped window for the follow-ups marker. Present → silent pass,
      # byte-identical to pre-012 behaviour. Absent → NON-BLOCKING advisory.
      # Warn stays warn: never emit_block, never exit 2, on this path.
      # dod-receipt spans are stripped first (perl non-greedy; the transcript is
      # JSONL so a receipt quoting the marker inside cmd="…" would otherwise
      # false-satisfy the scan — 012 review F1).
      if awk -v n="${LAST_USER:-0}" 'NR>n' "$TRANSCRIPT" | perl -pe 's/<!--\s*dod-receipt\b.*?-->//g' | grep -Eq "$FOLLOWUPS_RE"; then
        exit 0
      fi
      jq -nc --arg m 'stop-verify: DoD receipt found but no follow-ups marker. End the message with a Follow-ups block — numbered, decreasing priority (blocking-risk > correctness > cost/quota > hygiene), one line each, disposition fold/new-spec/surgical, derived ONLY from context already read this session (no new exploration) — or state none. Then paste the marker: <!-- follow-ups: <count-or-none> -->' '{additionalContext: $m}'
      exit 0
    fi
    emit_block "receipts" 'no Definition-of-Done receipt found for this turn. A code change is not done without one. State the verification command, its exit code, and the diff lines that prove the change, then paste the canonical marker (CLAUDE.md:43):
<!-- dod-receipt cmd="<verification command>" exit=<int> diff="+N/-M (K files)" -->'
  fi
fi

# --- Pass / no-check advisory ---
if [ "$CHECKS_RUN" -eq 0 ]; then
  rm -f "$STATE_FILE"
  jq -nc '{additionalContext: "stop-verify: no typecheck/lint/test configured for this repo. Task completion is unverified — state this to the user."}'
  exit 0
fi

rm -f "$STATE_FILE"
exit 0
