#!/usr/bin/env bash
# session-context.sh — SessionStart (startup|resume). Inject repo context header.
# Source: Trellis / core-rules / hooks.md
#
# Contract:
#   - Runs on SessionStart with source=startup or source=resume.
#   - Assembles: current branch, last 5 commits, dirty-file count,
#     context-log.md (if present), unresolved gotchas.md entries.
#   - context-log.md and gotchas.md are read from the canonical project root
#     (resolved via `git rev-parse --git-common-dir`) so worktree sessions
#     still see the repo-level files.
#   - Emits {"hookSpecificOutput":{"hookEventName":"SessionStart",
#            "additionalContext":"..."}}.
#   - Output trimmed to ≤ 2000 chars. Never blocks. Exit 0 always.
#
# Dependencies: jq (required), git (optional — skips git section if absent).
#
# Status: new in this core-rules layer (not in upstream template).

set -u

INPUT=$(cat 2>/dev/null || true)

# Source shared lib (sibling to this script) + enforce jq dependency.
__se_lib="$(dirname "${BASH_SOURCE[0]}")/lib/deps.sh"
[ -f "$__se_lib" ] || { echo "session-context: missing sibling lib at $__se_lib — re-run sync-hooks" >&2; exit 1; }
# shellcheck source=lib/deps.sh disable=SC1090
. "$__se_lib"
_se_require_jq "session-context"

SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"')

# Only run on startup/resume. compact is handled by post-compact-context.sh.
case "$SOURCE" in
  startup|resume) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
REPO_ROOT=$(_se_repo_root "$PROJECT_DIR")

CTX=""

# --- Git section ---
# Branch / commits / dirty count reflect the active checkout (worktree HEAD
# when in a worktree, main HEAD otherwise) — the user's working context.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  DIRTY=$(git status --porcelain 2>/dev/null | awk 'END{print NR}')
  COMMITS=$(git log --oneline -n 5 2>/dev/null || true)

  CTX="${CTX}Branch: ${BRANCH}    Dirty files: ${DIRTY}

Last 5 commits:
${COMMITS}

"
fi

# --- context-log.md (from a previous session) ---
# Read 1200 chars: 2000-char cap below leaves ~1600 after the branch section
# (~400). Worst-case gotchas (10 lines × ~80 chars) can claim up to ~800, but
# in practice the anchored gotchas regex (audit §2.1) keeps that section
# small enough that 1200 of log content fits without crowding gotchas out.
# Paired with post-compact-context.sh's 8000 — see comment there for asymmetry.
if [ -f "${REPO_ROOT}/context-log.md" ]; then
  LOG_CONTENT=$(head -c 1200 "${REPO_ROOT}/context-log.md")
  CTX="${CTX}--- context-log.md (previous session) ---
${LOG_CONTENT}

"
fi

# --- audit digest (unresolved findings, from daily-project-digest) ---
# C1: a tiny advisory PUSH — unresolved audit findings surface the moment work
# begins, instead of the PULL of a separate cron report. The emitter
# An optional operator digest writes a count + top item to this file;
# kept to head -c 400 so it cannot crowd out real context under the 2000-char
# $CTX cap below. Advisory only — never blocks or mutates.
if [ -f "${REPO_ROOT}/.claude/audit-digest.md" ]; then
  DIGEST_CONTENT=$(head -c 400 "${REPO_ROOT}/.claude/audit-digest.md")
  CTX="${CTX}--- audit digest (unresolved findings) ---
${DIGEST_CONTENT}

"
fi

# --- Autonomy level ---
# Resolution priority: session override file > project config > preset default > fleet default > 3
LEVEL=3
TRELLIS_CFG=""
# Find trellis.config.json — search PROJECT_DIR upward, then $TRELLIS_ROOT env.
if [ -n "${TRELLIS_ROOT:-}" ] && [ -f "$TRELLIS_ROOT/trellis.config.json" ]; then
  TRELLIS_CFG="$TRELLIS_ROOT/trellis.config.json"
fi
if [ -n "$TRELLIS_CFG" ] && command -v jq >/dev/null 2>&1; then
  FLEET=$(jq -r '.autonomy_default // empty' "$TRELLIS_CFG" 2>/dev/null)
  [ -n "$FLEET" ] && LEVEL="$FLEET"
fi
# Project-local override
for cand in "$REPO_ROOT/.trellis.config.json" "$REPO_ROOT/trellis.config.json"; do
  if [ -f "$cand" ] && command -v jq >/dev/null 2>&1; then
    PL=$(jq -r '.autonomy // empty' "$cand" 2>/dev/null)
    [ -n "$PL" ] && LEVEL="$PL"
    break
  fi
done
# Session-autonomy file (highest priority before clamp)
SESSION_FILE="$REPO_ROOT/.claude/session-autonomy"
if [ -f "$SESSION_FILE" ]; then
  SESS=$(head -1 "$SESSION_FILE" | tr -d '[:space:]')
  case "$SESS" in 1|2|3|4|5) LEVEL="$SESS" ;; esac
fi
# Map to name
case "$LEVEL" in
  1) NAME="Pedagogical" ;;
  2) NAME="Cautious" ;;
  3) NAME="Standard" ;;
  4) NAME="Initiative" ;;
  5) NAME="Autonomous" ;;
  *) NAME="?"; LEVEL=3 ;;
esac
CTX="${CTX}--- Autonomy ---
Level: L${LEVEL} (${NAME})

"

# --- Recent decisions (L4/L5 only) ---
if [ "$LEVEL" -ge 4 ] 2>/dev/null && [ -f "$REPO_ROOT/decisions-log.md" ]; then
  RECENT=$(grep -E '^- 20[0-9]{2}-' "$REPO_ROOT/decisions-log.md" 2>/dev/null | tail -10)
  if [ -n "$RECENT" ]; then
    CTX="${CTX}--- Recent decisions (L4/L5) ---
${RECENT}

"
  fi
fi

# --- Unresolved gotchas ---
# Convention: entry is "unresolved" when anchored at line-start either as a
# heading (`## Unresolved …`) or a status field (`Status: unresolved`,
# `**unresolved**`). Free-text mentions of "unresolved" elsewhere are ignored
# to avoid false positives like "this issue is now resolved (was unresolved …)".
if [ -f "${REPO_ROOT}/gotchas.md" ]; then
  UNRESOLVED=$(grep -inE '^(#{1,6}[[:space:]]+.*unresolved|[[:space:]]*\*\*unresolved\*\*|[[:space:]]*status:[[:space:]]+unresolved)' "${REPO_ROOT}/gotchas.md" 2>/dev/null | head -10 || true)
  if [ -n "$UNRESOLVED" ]; then
    CTX="${CTX}--- Unresolved gotchas ---
${UNRESOLVED}

"
  fi
fi

# --- Worktree inheritance safety-net ---
# Detect a linked worktree missing its Trellis inheritance symlinks.
# Fail-safe: any error is swallowed; hook always continues normally.
# NOTE: seeder stdout/stderr is suppressed to protect the JSON contract. The
# subshell also isolates a set -u abort in the detection body, so keep the
# `( ... ) > file 2>/dev/null || true` structure (capturing via $() would leak
# the abort and kill the hook). mktemp — not a predictable /tmp/$$ path —
# avoids a symlink/collision race; if mktemp fails we skip detection rather
# than let `printf 'WARN'` leak into the JSON on stdout.
_se_worktree_warn=""
if _se_wt_tmp=$(mktemp "${TMPDIR:-/tmp}/trellis-wtwarn.XXXXXX" 2>/dev/null); then
(
  command -v git >/dev/null 2>&1 || exit 0
  common=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
  gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
  [ -n "$common" ] && [ -n "$gitdir" ] || exit 0
  # In a main checkout, --git-dir == --git-common-dir (both resolve to .git).
  # Canonicalize both before comparing so macOS /var vs /private/var doesn't matter.
  common_abs="$(cd "$common" 2>/dev/null && pwd -P)" || exit 0
  gitdir_abs="$(cd "$gitdir" 2>/dev/null && pwd -P)" || exit 0
  [ "$common_abs" != "$gitdir_abs" ] || exit 0
  # We are in a linked worktree. Locate the seeder via the main checkout.
  main_line=""
  wt_list=$(git worktree list --porcelain 2>/dev/null) || exit 0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) main_line="$line"; break ;;
    esac
  done <<< "$wt_list"
  [ -n "$main_line" ] || exit 0
  MAIN="${main_line#worktree }"
  [ -d "$MAIN" ] || exit 0
  MAIN="$(cd "$MAIN" && pwd -P)" || exit 0
  # Resolve TRELLIS_ROOT from the main checkout's trellis.md symlink.
  root=""
  trellis_link="$MAIN/.claude/rules/trellis.md"
  if [ -L "$trellis_link" ]; then
    link_target="$(readlink "$trellis_link" 2>/dev/null)" || true
    candidate="${link_target%/core-rules/CLAUDE.md}"
    if [ "$candidate" != "$link_target" ] && [ -d "$candidate" ]; then
      root="$candidate"
    fi
  fi
  # Fallback: $TRELLIS_ROOT env var
  if [ -z "$root" ] && [ -n "${TRELLIS_ROOT:-}" ] && [ -d "$TRELLIS_ROOT" ]; then
    root="$TRELLIS_ROOT"
  fi
  # Fallback: trellis.config.json walk-up
  if [ -z "$root" ] && command -v jq >/dev/null 2>&1; then
    walk="$PWD"
    while [ "$walk" != "/" ]; do
      if [ -f "$walk/trellis.config.json" ]; then
        candidate="$(jq -r '.trellis_root // empty' "$walk/trellis.config.json" 2>/dev/null || true)"
        if [ -n "$candidate" ] && [ -d "$candidate" ]; then
          root="$candidate"
        fi
        break
      fi
      walk="$(dirname "$walk")"
    done
  fi
  [ -n "$root" ] || exit 0
  seeder="$root/scripts/seed-inheritance-symlinks.sh"
  [ -f "$seeder" ] || exit 0
  # Check if symlinks are present.
  bash "$seeder" --target "$PWD" --verify-only --quiet >/dev/null 2>&1 && exit 0
  # Symlinks missing: seed for next session (suppress all output).
  bash "$seeder" --target "$PWD" --quiet >/dev/null 2>&1 || true
  # Signal that warning should be emitted.
  printf 'WARN'
) > "$_se_wt_tmp" 2>/dev/null || true
_se_worktree_warn=$(cat "$_se_wt_tmp" 2>/dev/null || true)
rm -f "$_se_wt_tmp" 2>/dev/null || true
fi

if [ "${_se_worktree_warn:-}" = "WARN" ]; then
  _se_wt_msg="⚠️ TRELLIS INHERITANCE WAS MISSING IN THIS WORKTREE. Parent rules + skills (process-gate, etc.) did not load for THIS session — Claude Code enumerates them at startup, before this hook ran. I have re-created the symlinks; RESTART this session (or open a new one in this worktree) to load them. Until then, parent rules/skills are NOT active. Tip: create worktrees with \`trellis worktree add <path>\` to avoid this."
  CTX="${_se_wt_msg}

${CTX}"
fi

if [ -z "$CTX" ]; then
  exit 0
fi

# Hard cap at 2000 chars per spec.
if [ "${#CTX}" -gt 2000 ]; then
  CTX=$(printf '%s' "$CTX" | head -c 1980)
  CTX="${CTX}
...[trimmed]"
fi

jq -nc \
  --arg ctx "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
