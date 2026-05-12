#!/usr/bin/env bash
# Shared dependency helpers for Trellis hooks.
# Sourced by each hook. Sibling location: lib/ alongside the hook scripts.
#
# Plan task: P3.5 (extract shared hook utilities).
#
# Ship rules:
#   - sync-hooks.sh / sync-codex-hooks.sh copy this file alongside *.sh.
#   - onboard-project.sh seeds .claude/hooks/lib/ + .codex/hooks/lib/.
#   - Functions are prefixed _se_ to avoid clashing with consumer scripts.

# _se_require_jq <hook-name>
#   - if jq is available → return 0
#   - if TRELLIS_NO_JQ_DEGRADE=1   → write a stderr breadcrumb + exit 0
#   - otherwise                    → write stderr install help + exit 1
#
# Replaces the inline `if ! command -v jq ...; then exit 0; fi` pattern that
# silently dropped enforcement on jq-less environments (audit §3.2 / P1.5).
_se_require_jq() {
  local hook="${1:-hook}"
  if command -v jq >/dev/null 2>&1; then return 0; fi
  if [ "${TRELLIS_NO_JQ_DEGRADE:-0}" = "1" ]; then
    echo "${hook}: jq not found; TRELLIS_NO_JQ_DEGRADE=1 — degrading to no-op (install jq: brew install jq | apt-get install -y jq)" >&2
    exit 0
  fi
  echo "${hook}: jq required but not found — install jq (brew install jq | apt-get install -y jq) or set TRELLIS_NO_JQ_DEGRADE=1 to allow degradation" >&2
  exit 1
}

# _se_project_dir
#   - prints CODEX_PROJECT_DIR if set, else CLAUDE_PROJECT_DIR if set, else $PWD
#   - replaces the duplicated `${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}`
#     fallback in 6+ hooks across both harnesses.
_se_project_dir() {
  printf '%s' "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
}

# _se_repo_root <dir>
#   - prints the canonical repo root resolved via `git rev-parse --git-common-dir`
#     (one level up from the common dir), so worktree sessions still see
#     `context-log.md` and `gotchas.md` at the main checkout.
#   - falls back to <dir> when git is unavailable, the path is not a git repo,
#     or any step fails — never errors. Caller can treat the output as a
#     directory path regardless.
#
# Replaces the inline `__se_repo_root` block in the three context-log hooks
# (session-context, save-context-log, post-compact-context) on both harnesses.
# See `audits/2026-05-11-cross-project-process-audit.md` and the
# `0001-fix-hooks-context-log-canonical-root.patch` history.
_se_repo_root() {
  local dir="$1" common
  command -v git >/dev/null 2>&1 || { printf '%s' "$dir"; return; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '%s' "$dir"; return; }
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || { printf '%s' "$dir"; return; }
  [ -n "$common" ] || { printf '%s' "$dir"; return; }
  case "$common" in
    /*) ;;
    *) common="${dir}/${common}" ;;
  esac
  ( cd "${common}/.." 2>/dev/null && pwd ) || printf '%s' "$dir"
}
