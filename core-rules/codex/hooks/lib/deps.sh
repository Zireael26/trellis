#!/usr/bin/env bash
# Shared dependency helpers for SE Core hooks.
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
#   - if SE_CORE_NO_JQ_DEGRADE=1   → write a stderr breadcrumb + exit 0
#   - otherwise                    → write stderr install help + exit 1
#
# Replaces the inline `if ! command -v jq ...; then exit 0; fi` pattern that
# silently dropped enforcement on jq-less environments (audit §3.2 / P1.5).
_se_require_jq() {
  local hook="${1:-hook}"
  if command -v jq >/dev/null 2>&1; then return 0; fi
  if [ "${SE_CORE_NO_JQ_DEGRADE:-0}" = "1" ]; then
    echo "${hook}: jq not found; SE_CORE_NO_JQ_DEGRADE=1 — degrading to no-op (install jq: brew install jq | apt-get install -y jq)" >&2
    exit 0
  fi
  echo "${hook}: jq required but not found — install jq (brew install jq | apt-get install -y jq) or set SE_CORE_NO_JQ_DEGRADE=1 to allow degradation" >&2
  exit 1
}

# _se_project_dir
#   - prints CODEX_PROJECT_DIR if set, else CLAUDE_PROJECT_DIR if set, else $PWD
#   - replaces the duplicated `${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}`
#     fallback in 6+ hooks across both harnesses.
_se_project_dir() {
  printf '%s' "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
}
