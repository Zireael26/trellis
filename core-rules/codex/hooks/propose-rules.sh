#!/usr/bin/env bash
# propose-rules.sh — Codex Stop. Scans the just-finished session for patterns worth
# capturing in gotchas.md or core-rules/CLAUDE.md and emits a proposed diff
# for the user to apply (or ignore).
#
# Source: Trellis / core-rules / codex hooks.
#
# Contract:
#   - Default-ON for registered projects. PROCESS_GATE_PROPOSE_RULES unset → runs;
#     explicit =0 → exit 0 silently (opt-out).
#   - stop_hook_active guard: if set, exit 0.
#   - Umbrella recursion sentinel: TRELLIS_REVIEW_IN_PROGRESS=1 on entry → exit 0
#     (closes both self- and cross-hook `claude -p` Stop-chain recursion).
#   - Pure chat / no edits: exit 0 (skip).
#   - Edit-heavy gate: skip unless ≥3 files OR ≥200 lines changed (same threshold
#     as code-review) so it does not stack a second per-Stop `claude -p` every turn.
#   - Returns proposed updates as Stop-safe systemMessage, never blocks.
#   - Budget: 30s soft cap (perl-alarm shim — bare `timeout` is a no-op on macOS).
#
# Cost note: this hook calls a subagent and reads the session transcript. Both
# cost tokens; the edit-heavy + correction-signal gates bound it to turns where a
# rule proposal is plausible. Projects that never want it set
# PROCESS_GATE_PROPOSE_RULES=0.
#
# Status: promoted default-on (DL-P8a-06). The prompt stays conservative
# (proposes only on a clear correction signal in the recent transcript).

set -u

# ---------------------------------------------------------------------------
# run_with_timeout <secs> <cmd...>
#   Portable wall-clock timeout. KEEP IN SYNC with lib/code-reviewer.sh's
#   run_with_timeout (duplicated, NOT sourced — code-reviewer.sh has side
#   effects and pulls in the reviewer). GNU `timeout` (and gtimeout) are ABSENT
#   on macOS, so we use a perl shim. It runs the command in its OWN process
#   group (setsid) and, on timeout, kills the WHOLE group — a bare SIGALRM
#   reaches only the direct child, so a grandchild (e.g. claude's Node
#   descendants + a long HTTP request) would otherwise keep the captured pipe
#   open past the deadline. Exits 142 on timeout; propagates the command's own
#   exit status otherwise. If perl is absent we run the command WITHOUT a
#   wall-clock cap and rely on the caller's --max-turns 1 to bound it.
# ---------------------------------------------------------------------------
run_with_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      if (!defined $pid) { exec @ARGV; }                 # fork failed → best effort
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or POSIX::_exit(127); }
      $SIG{ALRM} = sub {
        kill("TERM", -$pid); select(undef, undef, undef, 0.3);
        kill("KILL", -$pid); waitpid($pid, 0); exit(142);
      };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
  else
    "$@"
  fi
}

INPUT=$(cat)

# Gate — default-ON for registered projects (DL-P8a-06). Unset → runs;
# explicit PROCESS_GATE_PROPOSE_RULES=0 → opt-out (silent no-op).
if [ "${PROCESS_GATE_PROPOSE_RULES:-1}" != "1" ]; then
  exit 0
fi

# Source shared lib (sibling to this script) + enforce jq dependency.
__pr_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__pr_lib" ] || { echo "propose-rules: missing sibling lib at $__pr_lib — re-run sync-codex-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__pr_lib"
_se_require_jq "propose-rules"

# --- Guard 1: stop_hook_active ---
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
[ "$STOP_ACTIVE" = "true" ] && exit 0

# --- Umbrella recursion sentinel (mirrors code-review-subagent.sh) ---
# This hook's `claude -p` child fires ITS OWN Stop chain — including
# code-review-subagent.sh AND this very hook — which would spawn more `claude -p`
# turns. TRELLIS_REVIEW_IN_PROGRESS propagates through `claude -p` into the
# child's Stop-hook environment (empirically confirmed). Set on entry → bail,
# closing BOTH self- and cross-hook recursion. The child invocation below
# exports this sentinel scoped to ONLY that pipeline.
if [ "${TRELLIS_REVIEW_IN_PROGRESS:-}" = "1" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# --- Non-git cost-bound (DL-P8a-13.2; mirrors code-review-subagent.sh:134) ---
# Both cost bounds below (pure-chat Guard 2 + the edit-heavy gate) are
# git-conditional and fall THROUGH when git is absent, so a non-git project
# would reach the `claude -p` call unbounded. A non-git project has no diff to
# learn an edit-heavy rule from anyway, so exit early and skip entirely.
if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- Guard 2: pure-chat turn → nothing to learn from.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    exit 0
  fi
fi

# --- Edit-heavy gate (DL-P8a-06; verbatim from code-review-subagent.sh) ---
# Default-on means this hook could otherwise stack a second per-Stop `claude -p`
# on EVERY edit turn. The same edit-heavy threshold as code-review (≥3 files OR
# ≥200 lines changed in `git diff HEAD`) keeps it to edit-heavy turns only. The
# correction-signal heuristic (Guard 4) is the SEMANTIC trigger and STAYS; this
# is the additional volume filter. Needs git (Guard 2 establishes it) — when git
# is absent the gate is skipped (same conditionalization as Guard 2).
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MIN_FILES="${REVIEW_MIN_FILES:-3}"
  MIN_LINES="${REVIEW_MIN_LINES:-200}"

  # Count always outputs a number, never errors. Avoid `grep -c '^' || echo 0` —
  # that doubles output to "0\n0" on empty input and breaks numeric comparisons.
  # Untracked-inclusive: a session that only CREATES files must still count
  # (git diff HEAD omits untracked). Read-only — ls-files never stages anything.
  # `.claude/` / `.codex/` are harness state, not session work — exclude them
  # from the untracked scan so they don't inflate the volume gate.
  CHANGED_FILES=$( { git diff HEAD --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null | grep -vE '^\.(claude|codex)/'; } \
    | sort -u | sed '/^$/d' | awk 'END{print NR}')

  # Sum added+deleted lines: tracked via numstat (skip binary rows marked '-'),
  # untracked via line count (the whole new file is an addition).
  _pr_tracked_lines=$(git diff HEAD --numstat 2>/dev/null \
    | awk '$1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum+0 }')
  _pr_untracked_lines=$(git ls-files --others --exclude-standard 2>/dev/null | grep -vE '^\.(claude|codex)/' \
    | while IFS= read -r f; do [ -f "$f" ] && wc -l < "$f" 2>/dev/null; done \
    | awk '{ sum += $1 } END { print sum+0 }')
  CHANGED_LINES=$((_pr_tracked_lines + _pr_untracked_lines))

  if [ "$CHANGED_FILES" -lt "$MIN_FILES" ] && [ "$CHANGED_LINES" -lt "$MIN_LINES" ]; then
    exit 0
  fi
fi

# --- Guard 3: transcript path. Claude Code writes the session transcript to
# $CLAUDE_TRANSCRIPT_PATH (set by the harness when invoking hooks). Codex
# may surface this differently — for now, accept either env var.
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-${CODEX_TRANSCRIPT_PATH:-}}"
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  # No transcript available — silent skip. We don't synthesize from scratch.
  exit 0
fi

# --- Guard 4: cheap heuristic. Only run the subagent when the last ~50 lines
# of transcript contain at least one explicit user correction signal. This
# keeps the hook from burning tokens every turn.
TAIL="$(tail -200 "$TRANSCRIPT" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
case "$TAIL" in
  *"no, "*|*"don't "*|*"do not "*|*"actually, "*|*"that's wrong"*|*"stop doing"*|*"never do"*)
    : # correction signal present, proceed
    ;;
  *)
    exit 0
    ;;
esac

# --- Step 1: Dispatch a subagent via a small `claude -p` invocation. The
# subagent reads the transcript tail and the project's gotchas.md, and emits a
# proposed addition (or "no proposal" if nothing concrete found).
#
# Falls back silently if `claude` is not on PATH (e.g., Codex-driven session
# with no Claude CLI installed). The hook is informational anyway.
if ! command -v claude >/dev/null 2>&1; then
  exit 0
fi

GOTCHAS="$PROJECT_DIR/gotchas.md"
[ -f "$GOTCHAS" ] || GOTCHAS="/dev/null"

# Compose the prompt. Keep it small — this runs every Stop turn with the gate set.
# Note: heredoc-in-$() can mishandle apostrophes in some bash versions, so the
# prompt avoids them and uses ASCII-safe phrasing throughout.
PROMPT='You will read the tail of a session transcript and the project gotchas.md.
Propose ONE rule addition for the project gotchas.md if and only if the
transcript shows a clear, surprising correction the user gave the agent that
would help future sessions avoid the same mistake.

If nothing concrete is in the transcript, output exactly: NONE

Otherwise output a single markdown block in this shape (and nothing else):

## <YYYY-MM-DD> — <short title>
**Pattern:** <one-line restatement of the surprising correction>
**Why it matters:** <one short paragraph on why this surprised the agent and
why future sessions will benefit from knowing>
**Rule:** <imperative sentence the agent will read next time>

Do NOT propose rules already in gotchas.md. Do NOT propose rules for trivial
preferences (e.g., use tabs). Do NOT propose rules with weak evidence (one
slip-up is not a pattern).'

# Scoped fork-bomb sentinel: export TRELLIS_REVIEW_IN_PROGRESS=1 ONLY inside this
# command-substitution subshell, wrapping ONLY the child `claude -p`. Per the
# Phase-2a pre-export lesson, setting it early in the parent path would make this
# hook's top-of-hook umbrella guard suppress its OWN intended run; scoping it to
# the subshell means the child's Stop chain (code-review + this hook) sees the
# sentinel and bails, while the parent run proceeds. run_with_timeout (the
# perl-alarm shim) replaces the bare `timeout 30`, which is a NO-OP on macOS.
#
# The transcript tail is untrusted content, so the child reviewer runs with ZERO
# host tools: `--tools Read` makes the available set EXCLUSIVE (Read + advisor),
# matching the rung-2 reviewer. A `--disallowedTools` denylist would be incomplete
# — the host permissions.defaultMode can be `auto` (auto-allow headless), and the
# default set includes ToolSearch (loads further deferred tools) + agent-spawn
# tools — so restricting the available set is the airtight lever. Input is piped
# on stdin, so `--tools Read` can be the last claude arg with no positional to eat.
OUT="$( export TRELLIS_REVIEW_IN_PROGRESS=1; {
  printf '%s\n\n--- TRANSCRIPT TAIL ---\n' "$PROMPT"
  tail -300 "$TRANSCRIPT" 2>/dev/null
  printf '\n--- GOTCHAS.MD ---\n'
  cat "$GOTCHAS" 2>/dev/null
} | run_with_timeout 30 claude -p --max-turns 1 --output-format text \
      --tools Read 2>/dev/null )"

# Empty or NONE → no proposal.
case "$OUT" in
  ""|"NONE"|*"NONE"*"NONE"*) exit 0 ;;
esac

# Emit the proposal as a Stop-safe advisory. Never blocks.
_se_emit_system_message "propose-rules: candidate gotchas.md entry below — review and append if useful.\n\n$OUT"
exit 0
