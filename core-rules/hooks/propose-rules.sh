#!/usr/bin/env bash
# propose-rules.sh — Stop. Scans the just-finished session for patterns worth
# capturing in gotchas.md or core-rules/CLAUDE.md and emits a proposed diff
# for the user to apply (or ignore).
#
# Source: Trellis / core-rules / hooks.md (Tier 2, default-on per DL-P8a-06).
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
#   - Returns proposed updates as additionalContext, never blocks.
#   - At effective L5 only, atomically appends a safe candidate to canonical-root
#     gotchas.md and logs the action in canonical-root decisions-log.md; L1–L4
#     remain advisory-only.
#   - Budget: 30s soft cap (perl-alarm shim — bare `timeout` is a no-op on macOS).
#   - OMP (TRELLIS_OMP=1): the Claude-family `claude -p` proposal rung is
#     policy-unreachable; exit 0 unless TRELLIS_OMP_REVIEW_CMD or
#     CODE_REVIEWER_CMD supplies an explicit non-Anthropic replacement, which is
#     then invoked instead with the same prompt on stdin.
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

# ---------------------------------------------------------------------------
# L5 persistence helpers
#   The subagent output is untrusted. Secret-like material is never emitted or
#   written: token fingerprints and nonempty quoted or unquoted secret-key
#   assignments are screened before either boundary. L5 writes stage temporary
#   siblings before atomic renames.
# ---------------------------------------------------------------------------
_pr_has_secret_material() {
  local candidate="$1"
  if printf '%s\n' "$candidate" | grep -qE '(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})'; then
    return 0
  fi
  printf '%s\n' "$candidate" | grep -qiE "(password|passwd|secret|api[_-]?key|token|access[_-]?key)[[:space:]]*(:|=)[[:space:]]*([\"'][^\"']+[\"']|[^[:space:]\"'#]+)"
}

_pr_candidate_is_well_formed() {
  local candidate="$1"
  [ "${#candidate}" -le 12000 ] || return 1
  case "$candidate" in
    *$'\r'*) return 1 ;;
  esac
  printf '%s\n' "$candidate" | grep -qE '^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][[:space:]]+[-—][[:space:]]+.+$' || return 1
  printf '%s\n' "$candidate" | grep -qE '^\*\*Pattern:\*\*[[:space:]]*[^[:space:]].*$' || return 1
  printf '%s\n' "$candidate" | grep -qE '^\*\*Why it matters:\*\*[[:space:]]*[^[:space:]].*$' || return 1
  printf '%s\n' "$candidate" | grep -qE '^\*\*Rule:\*\*[[:space:]]*[^[:space:]].*$'
}

_pr_candidate_rule() {
  printf '%s\n' "$1" | awk '/^\*\*Rule:\*\*/ { sub(/[[:space:]]+$/, ""); print; exit }'
}

_pr_candidate_already_present() {
  local target="$1" candidate="$2" existing rule
  [ -f "$target" ] || return 1
  existing=$(cat "$target") || return 1
  [[ "$existing" == *"$candidate"* ]] && return 0
  rule=$(_pr_candidate_rule "$candidate")
  [ -n "$rule" ] && grep -Fqx -- "$rule" "$target" 2>/dev/null
}

_pr_temp_sibling() {
  local target="$1" dir base
  dir=$(dirname "$target") || return 1
  base=$(basename "$target") || return 1
  [ -d "$dir" ] || return 1
  mktemp "$dir/.${base}.tmp.XXXXXX"
}

_pr_preserve_mode() {
  local source="$1" target="$2" mode=""
  [ -f "$source" ] || return 0
  mode=$(stat -f '%Lp' "$source" 2>/dev/null || stat -c '%a' "$source" 2>/dev/null || true)
  [ -n "$mode" ] && chmod "$mode" "$target" 2>/dev/null || true
}

_pr_prepare_append() {
  local target="$1" entry="$2" header="$3" tmp
  [ -L "$target" ] && return 1
  [ -e "$target" ] && [ ! -f "$target" ] && return 1
  tmp=$(_pr_temp_sibling "$target") || return 1

  if [ -f "$target" ] && [ -s "$target" ]; then
    if ! cat "$target" > "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    if [ -n "$(tail -c 1 "$target" 2>/dev/null)" ]; then
      printf '\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '%s\n\n' "$header" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$entry" >> "$tmp" || { rm -f "$tmp"; return 1; }
  _pr_preserve_mode "$target" "$tmp"
  printf '%s' "$tmp"
}

_pr_backup_file() {
  local source="$1" backup
  backup=$(_pr_temp_sibling "$source") || return 1
  if ! cat "$source" > "$backup"; then
    rm -f "$backup"
    return 1
  fi
  _pr_preserve_mode "$source" "$backup"
  printf '%s' "$backup"
}

# Returns 0 when both durable records are written, 2 for an existing candidate,
# 1 when the staged transaction rolls back, and 3 when a recovery backup is
# retained after a failed transaction.
_pr_append_l5_candidate() {
  local gotchas="$1" decisions="$2" candidate="$3"
  local gotchas_tmp="" decisions_tmp="" backup="" action_day action
  local had_gotchas=0
  _pr_l5_recovery_backup=""
  _pr_l5_recovery_reason=""

  if [ -L "$gotchas" ] || [ -L "$decisions" ]; then
    return 1
  fi
  if _pr_candidate_already_present "$gotchas" "$candidate"; then
    return 2
  fi

  action_day=$(date -u +%Y-%m-%d 2>/dev/null || printf '?')
  action="- ${action_day} [L5] propose-rules auto-appended a surfaced gotcha to gotchas.md."
  gotchas_tmp=$(_pr_prepare_append "$gotchas" "$candidate" "# Gotchas") || return 1
  decisions_tmp=$(_pr_prepare_append "$decisions" "$action" "# Decisions log") || {
    rm -f "$gotchas_tmp"
    return 1
  }

  if [ -f "$gotchas" ]; then
    had_gotchas=1
    backup=$(_pr_backup_file "$gotchas") || {
      rm -f "$gotchas_tmp" "$decisions_tmp"
      return 1
    }
  fi

  if ! mv -f "$gotchas_tmp" "$gotchas"; then
    rm -f "$gotchas_tmp" "$decisions_tmp"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
      _pr_l5_recovery_backup="$backup"
      _pr_l5_recovery_reason="could not replace canonical gotchas.md"
      return 3
    fi
    return 1
  fi
  gotchas_tmp=""

  if ! mv -f "$decisions_tmp" "$decisions"; then
    rm -f "$decisions_tmp"
    if [ "$had_gotchas" -eq 1 ]; then
      if [ -n "$backup" ] && mv -f "$backup" "$gotchas"; then
        return 1
      fi
      if [ -n "$backup" ] && [ -f "$backup" ]; then
        _pr_l5_recovery_backup="$backup"
        _pr_l5_recovery_reason="could not restore canonical gotchas.md after the decisions-log write failed"
      fi
    elif rm -f "$gotchas"; then
      return 1
    fi
    return 3
  fi

  rm -f "$backup"
  return 0
}

INPUT=$(cat)

# Gate — default-ON for registered projects (DL-P8a-06). Unset → runs;
# explicit PROCESS_GATE_PROPOSE_RULES=0 → opt-out (silent no-op).
if [ "${PROCESS_GATE_PROPOSE_RULES:-1}" != "1" ]; then
  exit 0
fi

# Source shared lib (sibling to this script) + enforce jq dependency.
__pr_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__pr_lib" ] || { echo "propose-rules: missing sibling lib at $__pr_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__pr_lib"
_se_require_jq "propose-rules"
__pr_autonomy_lib="$(dirname "${BASH_SOURCE[0]}")/lib/autonomy.sh"
[ -f "$__pr_autonomy_lib" ] || { echo "propose-rules: missing sibling lib at $__pr_autonomy_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/autonomy.sh disable=SC1090,SC1091
. "$__pr_autonomy_lib"

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

# Canonical-root files survive worktree cleanup and are shared by both harnesses.
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

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

# --- OMP no-Anthropic guarantee (hooks.md: OMP owns its stop event) ---------
# This hook's only action is a Claude-family `claude -p` proposal rung; under
# OMP (TRELLIS_OMP=1, exported by core-rules/omp/hooks/pre/trellis.ts) that
# default is unreachable by policy. Skip unless the operator supplies an
# explicit non-Anthropic replacement command via TRELLIS_OMP_REVIEW_CMD or
# CODE_REVIEWER_CMD — then the proposal prompt is piped to THAT command and
# its stdout is treated exactly like the Claude child's.
if [ "${TRELLIS_OMP:-}" = "1" ]; then
  if [ -n "${TRELLIS_OMP_REVIEW_CMD:-}" ] && command -v "${TRELLIS_OMP_REVIEW_CMD}" >/dev/null 2>&1; then
    PROPOSAL_CMD=("${TRELLIS_OMP_REVIEW_CMD}")
  elif [ -n "${CODE_REVIEWER_CMD:-}" ] && command -v "${CODE_REVIEWER_CMD}" >/dev/null 2>&1; then
    PROPOSAL_CMD=("${CODE_REVIEWER_CMD}")
  else
    exit 0
  fi
else
  if ! command -v claude >/dev/null 2>&1; then
    exit 0
  fi
  PROPOSAL_CMD=(claude -p --max-turns 1 --output-format text --tools Read)
fi

GOTCHAS="$REPO_ROOT/gotchas.md"
[ -f "$GOTCHAS" ] || GOTCHAS="/dev/null"
DECISIONS_LOG="$REPO_ROOT/decisions-log.md"

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
# command-substitution subshell, wrapping ONLY the child proposal run. Per the
# Phase-2a pre-export lesson, setting it early in the parent path would make this
# hook's top-of-hook umbrella guard suppress its OWN intended run; scoping it to
# the subshell means the child's Stop chain (code-review + this hook) sees the
# sentinel and bails, while the parent run proceeds. run_with_timeout (the
# perl-alarm shim) replaces the bare `timeout 30`, which is a NO-OP on macOS.
#
# The child command comes from PROPOSAL_CMD above: the canonical `claude -p …`
# on Claude Code/Codex, or an explicit operator-supplied non-Anthropic command
# under OMP. The transcript tail is untrusted content on every path — the
# Claude/Codex shape runs with ZERO host tools (`--tools Read` makes the
# available set EXCLUSIVE, so a prompt-injected transcript cannot induce a host
# tool_use regardless of permissions.defaultMode; a denylist would be incomplete
# because the default set includes ToolSearch + agent-spawn tools). Input is
# piped on stdin, so `--tools Read` can be the last claude arg with no positional
# to eat.
OUT="$( export TRELLIS_REVIEW_IN_PROGRESS=1; {
  printf '%s\n\n--- TRANSCRIPT TAIL ---\n' "$PROMPT"
  tail -300 "$TRANSCRIPT" 2>/dev/null
  printf '\n--- GOTCHAS.MD ---\n'
  cat "$GOTCHAS" 2>/dev/null
} | run_with_timeout 30 "${PROPOSAL_CMD[@]}" 2>/dev/null )"

# Empty or NONE → no proposal.
case "$OUT" in
  ""|"NONE"|*"NONE"*"NONE"*) exit 0 ;;
esac

# Never echo a possible credential into hook output or persist it in project docs.
if _pr_has_secret_material "$OUT"; then
  jq -nc --arg ctx "propose-rules: candidate contained secret-like material and was not emitted or written." '{additionalContext: $ctx}'
  exit 0
fi

# L1–L4 remain advisory-only. The resolver applies canonical project policy,
# session overrides, and active-preset ceilings before this write boundary.
_se_resolve_autonomy "$REPO_ROOT"
if [ "$AUTONOMY_LEVEL" != "5" ]; then
  jq -nc --arg ctx "propose-rules: candidate gotchas.md entry below — review and append if useful.\n\n$OUT" '{additionalContext: $ctx}'
  exit 0
fi

if ! _pr_candidate_is_well_formed "$OUT"; then
  jq -nc --arg ctx "propose-rules: candidate did not match the required gotcha format, so it was not auto-appended. Review it manually if useful.\n\n$OUT" '{additionalContext: $ctx}'
  exit 0
fi

_pr_append_l5_candidate "$REPO_ROOT/gotchas.md" "$DECISIONS_LOG" "$OUT"
append_rc=$?
case "$append_rc" in
  0)
    ctx="propose-rules: auto-appended the candidate to canonical gotchas.md at L5 and logged the action in decisions-log.md.\n\n$OUT"
    ;;
  2)
    ctx="propose-rules: candidate already exists in canonical gotchas.md; no write was made.\n\n$OUT"
    ;;
  3)
    if [ -n "${_pr_l5_recovery_backup:-}" ]; then
      ctx="propose-rules: ${_pr_l5_recovery_reason}; preserved the intact backup at ${_pr_l5_recovery_backup}. Restore canonical gotchas.md from that path before retrying.\n\n$OUT"
    else
      ctx="propose-rules: could not complete the decisions-log write after the gotchas write; inspect canonical files before retrying.\n\n$OUT"
    fi
    ;;
  *)
    ctx="propose-rules: could not atomically append and log the candidate; no write was retained. Review and append it manually if useful.\n\n$OUT"
    ;;
esac
jq -nc --arg ctx "$ctx" '{additionalContext: $ctx}'
exit 0
