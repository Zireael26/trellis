#!/usr/bin/env bash
# stop-verify.sh — Codex Stop. Todo state → typecheck → lint → test, auto-detected.
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - TRELLIS_REVIEW_IN_PROGRESS=1: exit 0 immediately (nested-review guard).
#   - stop_hook_active guard: if set, exit 0 immediately (infinite-loop guard).
#   - Pure chat / no edits: exit 0 (skip).
#   - Runs checks in order. On any failure, emit
#     {"decision":"block","reason":"<step>: <sliced output>"} and exit 2.
#   - Error slicing: typecheck/lint → first 30 lines; tests → last 30 lines.
#   - Budget: 90s soft cap.
#   - Receipts gate (Step 5): on a dirty non-doc tree with no open todos and all
#     checks passed, require a Definition-of-Done receipt for this turn. The
#     receipt is detected from EITHER the Stop payload's last_assistant_message
#     OR a turn-scoped parse of transcript_path (union; both are NullableString).
#     No receipt in either source → block. Both sources unavailable → advisory
#     fail-open. Doc-only turns + PROCESS_GATE_NO_RECEIPTS=1 skip the gate.
#   - Follow-ups warn (spec 012): a receipt WITHOUT a follow-ups marker
#     (`<!-- follow-ups: N|none -->`, same two-source union) triggers a
#     NON-BLOCKING systemMessage advisory — warn stays warn, never a block.
#   - Fail-counter: emit_block counts consecutive blocks against the same
#     git-derived changed-file set (cksum of sorted paths, .codex/.fail-counter
#     state); same set ≥2 injects a "re-read top-down" steer. A clean pass
#     removes the state file. The counter is GIT-derived only — the
#     NullableString payload fields never feed it.
#
# Dependencies: jq (required). Toolchains are detected; absence → skip that step.
#
# Todo state: read from $CODEX_PROJECT_DIR/.codex/todos.json when present,
# falling back to the Claude Code location for shared projects. If missing or
# unparseable, we pass that step. Override via TODOS_FILE.
#
# Subtree scoping: when every changed file in this turn sits under a single
# subdirectory that carries its own manifest (package.json, go.mod,
# pyproject.toml, or Cargo.toml), checks run scoped to that subtree instead
# of repo root. Cuts wall time + noise on monorepos. Escape hatch:
# PROCESS_GATE_FORCE_ROOT=1 → always run at repo root (legacy behaviour).
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
# emit_block fires both before and after the subtree cd). Codex path: .codex/.
# A clean pass removes it.
STATE_FILE="${PROJECT_DIR}/.codex/.fail-counter"

# _se_changed_files — echo the full set of files changed this turn, one per line:
# tracked diff-vs-HEAD UNION untracked (not-yet-`git add`ed). Mirrors the union
# in _se_find_subtree. cwd-independent (git -C PROJECT_DIR) so it's stable on
# both sides of the subtree cd. `git diff HEAD --name-only` alone OMITS untracked
# new files — a turn that only Writes new code files would otherwise look empty
# (false fail-counter escalation AND a new code file would read as doc-only in
# the receipts gate, slipping a done-claim past it). Filter the hook's OWN state
# file: where .codex/ is committed (not gitignored) ls-files would surface
# .codex/.fail-counter, (a) destabilising the file-set hash between consecutive
# blocks (counter never reaches 2) and (b) making a code-revert-plus-doc-edit
# turn read as non-doc. Exact path only — a genuine .codex/ edit still needs a
# receipt.
_se_changed_files() {
  { git -C "$PROJECT_DIR" diff HEAD --name-only 2>/dev/null; \
    git -C "$PROJECT_DIR" ls-files --others --exclude-standard 2>/dev/null; } \
    | grep -vxF '.codex/.fail-counter' \
    | sort -u
}

emit_block() {
  local step="$1"
  local output="$2"

  # --- Fail-counter: count consecutive blocks against the SAME changed file-set.
  # File-set hash is cwd-independent (git -C PROJECT_DIR) so it's stable whether
  # emit_block fires before or after the subtree cd. cksum is POSIX-portable
  # (macOS has no sha256sum); we key off the set of changed paths, not contents.
  # GIT-DERIVED ONLY — never the (NullableString) payload/transcript.
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
  mkdir -p "${PROJECT_DIR}/.codex" 2>/dev/null || true
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
    while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
      if [ -f "$dir/package.json" ] || [ -f "$dir/go.mod" ] \
         || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Cargo.toml" ]; then
        found="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done

    [ -z "$found" ] && return 0

    if [ -z "$common" ]; then
      common="$found"
    elif [ "$common" != "$found" ]; then
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
if [ -z "${TODOS_FILE:-}" ]; then
  if [ -f "${PROJECT_DIR}/.codex/todos.json" ]; then
    TODOS_FILE="${PROJECT_DIR}/.codex/todos.json"
  else
    TODOS_FILE="${PROJECT_DIR}/.claude/todos.json"
  fi
fi
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
#
# Codex specifics (vs the Claude hook): the Stop payload hands us BOTH
# last_assistant_message (final agent text, NullableString) AND transcript_path
# (JSONL, NullableString). A receipt counts as PRESENT if the canonical marker
# matches in EITHER source — generous detection. We only block a done-claim that
# has NO receipt in either. The fail-counter (emit_block) stays GIT-derived; the
# NullableString fields below never touch it.
if [ "${PROCESS_GATE_NO_RECEIPTS:-0}" != "1" ]; then
  # Doc-only skip: every changed file has a doc extension (.md/.mdx/.rst/.txt).
  # Reuse code-review-subagent's final-path-segment anchor + NONDOC_COUNT==0
  # logic, but over the diff-UNION-untracked set (a turn that only Writes new
  # code files has an empty `git diff HEAD` — those must NOT read as doc-only).
  NONDOC_COUNT=$(_se_changed_files \
    | grep -vE '(^|/)[^/]+\.(md|mdx|rst|txt)$' \
    | awk 'END{print NR}')
  if [ "$NONDOC_COUNT" != "0" ]; then
    # Two-source union. (a) last_assistant_message: robust when transcript_path
    # is null but sees only the FINAL message. (b) turn-scoped transcript parse:
    # catches a receipt emitted before the final tool call. NullableString → use
    # `// empty` so a JSON null collapses to "".
    LAST_MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')
    TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

    # Canonical marker (must match the Claude hook's TIGHTENED form): fields IN
    # ORDER with FILLED values — `exit=[0-9]` (a digit must follow, rejecting the
    # literal `exit=<int>`) and `diff=.*\+[0-9]` (a `+<digit>` must appear,
    # rejecting `+N/-M`). Without this the unfilled template the block prints
    # below would itself satisfy the gate. Anchoring on `\+[0-9]` (not the quote
    # char) is agnostic to JSONL-escaped (\") vs unescaped (") quoting. One
    # constant, used against BOTH sources, so they cannot drift. See CLAUDE.md:43.
    RECEIPT_RE='<!-- dod-receipt .*cmd=.*exit=[0-9].*diff=.*\+[0-9].*-->'

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

    RECEIPT_FOUND=0

    # Turn-scoping line index, computed ONCE for both the receipt scan below
    # and the follow-ups scan on the pass path. Turn-scoping (load-bearing): a
    # receipt from a PRIOR turn must not satisfy THIS turn. The transcript is
    # JSONL. Emit one role per input line (1:1 map, robust to malformed lines
    # via fromjson? // "null"), find the LAST user-role line, and search ONLY
    # lines after it. No user line → scope whole file. Same technique as the
    # Claude hook / save-context-log.sh.
    LAST_USER=""
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      LAST_USER=$(jq -rR '(fromjson? | (.message.role // .role)) // "null"' "$TRANSCRIPT" 2>/dev/null \
        | grep -n '^user$' | tail -1 | cut -d: -f1)
    fi

    # Source (a): last_assistant_message.
    if [ -n "$LAST_MSG" ] && printf '%s' "$LAST_MSG" | grep -Eq "$RECEIPT_RE"; then
      RECEIPT_FOUND=1
    fi

    # Source (b): turn-scoped transcript parse.
    if [ "$RECEIPT_FOUND" = "0" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      if awk -v n="${LAST_USER:-0}" 'NR>n' "$TRANSCRIPT" | grep -Eq "$RECEIPT_RE"; then
        RECEIPT_FOUND=1
      fi
    fi

    if [ "$RECEIPT_FOUND" = "1" ]; then
      rm -f "$STATE_FILE"
      # Follow-ups nudge (spec 012 D4): receipt present — scan the SAME
      # two-source union, in the same order, for the follow-ups marker.
      # Cross-source generosity is deliberate and mirrors receipt detection:
      # receipt in last_assistant_message + marker only in the transcript (or
      # vice versa) passes clean. Present → silent pass, byte-identical to
      # pre-012 behaviour. Absent → NON-BLOCKING advisory. Warn stays warn:
      # never emit_block, never exit 2, on this path. The fail-counter stays
      # GIT-derived — this scan never feeds it.
      # dod-receipt spans stripped first (perl non-greedy) so a receipt quoting
      # the marker inside cmd="…" cannot false-satisfy the scan (012 review F1).
      FOLLOWUPS_FOUND=0
      if [ -n "$LAST_MSG" ] && printf '%s' "$LAST_MSG" | perl -pe 's/<!--\s*dod-receipt\b.*?-->//g' | grep -Eq "$FOLLOWUPS_RE"; then
        FOLLOWUPS_FOUND=1
      fi
      if [ "$FOLLOWUPS_FOUND" = "0" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
        if awk -v n="${LAST_USER:-0}" 'NR>n' "$TRANSCRIPT" | perl -pe 's/<!--\s*dod-receipt\b.*?-->//g' | grep -Eq "$FOLLOWUPS_RE"; then
          FOLLOWUPS_FOUND=1
        fi
      fi
      if [ "$FOLLOWUPS_FOUND" = "0" ]; then
        _se_emit_system_message 'stop-verify: DoD receipt found but no follow-ups marker. End the message with a Follow-ups block — numbered, decreasing priority (blocking-risk > correctness > cost/quota > hygiene), one line each, disposition fold/new-spec/surgical, derived ONLY from context already read this session (no new exploration) — or state none. Then paste the marker: <!-- follow-ups: <count-or-none> -->'
      fi
      exit 0
    fi

    # NullableString fail-open: ONLY when BOTH sources are unavailable — neither
    # a last_assistant_message NOR a usable transcript_path (null/absent/missing
    # file). The receipt is unverifiable in this harness state: advisory PASS
    # rather than block. NOTE: last_assistant_message present (non-null) with no
    # receipt and a null transcript still BLOCKS — that is a verifiable miss.
    if [ -z "$LAST_MSG" ] && { [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; }; then
      rm -f "$STATE_FILE"
      _se_emit_system_message "stop-verify: receipts unverifiable (no last_assistant_message and no transcript_path in this Stop envelope); state your DoD receipt to the user."
      exit 0
    fi

    emit_block "receipts" 'no Definition-of-Done receipt found for this turn. A code change is not done without one. State the verification command, its exit code, and the diff lines that prove the change, then paste the canonical marker (CLAUDE.md:43):
<!-- dod-receipt cmd="<verification command>" exit=<int> diff="+N/-M (K files)" -->'
  fi
fi

# --- Pass / no-check advisory ---
if [ "$CHECKS_RUN" -eq 0 ]; then
  rm -f "$STATE_FILE"
  _se_emit_system_message "stop-verify: no typecheck/lint/test configured for this repo. Task completion is unverified — state this to the user."
  exit 0
fi

rm -f "$STATE_FILE"
exit 0
