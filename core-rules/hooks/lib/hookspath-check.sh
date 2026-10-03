#!/usr/bin/env bash
# Shared core.hooksPath drift check (spec 055 R4.1/R4.3/R4.5).
#
# `trellis_hookspath_drift_line <worktree-root>` prints ONE advisory line when
# this worktree's Trellis owner record has git hooks enabled and the local
# core.hooksPath is anything other than exactly one value equal to the record's
# managed_hooks_path. It prints nothing when the hooks are healthy, disabled, or
# the worktree has no readable owner record.
#
# husky's `prepare` (`git config core.hooksPath .husky/_`) is the usual cause:
# git then never invokes the Trellis dispatcher, so no git hook can report its
# own removal. The harness hooks are the only place left to notice.
#
# Read-only: it never writes git config, an owner record, or any file. It reads
# `git config --local --get-all`, never the effective value, because the harness
# git wrappers pin `-c core.hooksPath=/dev/null`. The authority classifier is
# not consulted: the recorded previous value counts as drift too. The line names
# the guarded repair, never a bare `git config` write.
#
# Bash 3.2 compatible; sourcing this file has no side effects.

trellis_hookspath_drift_line() {
  local root="${1:-}" home common checkout worktree owner enabled managed values rc count current husky=""
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$root" ] && [ -d "$root" ] || return 0
  if [ -n "${TRELLIS_HOME:-}" ]; then
    home="$TRELLIS_HOME"
  elif [ -n "${HOME:-}" ]; then
    home="$HOME/.trellis"
  else
    return 0
  fi
  root="$(command git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 0
  root="$(CDPATH='' cd -P "$root" 2>/dev/null && pwd -P)" || return 0
  common="$(command git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  common="$(CDPATH='' cd -P "$common" 2>/dev/null && pwd -P)" || return 0
  checkout="$(_trellis_hookspath_sha256 "$common")" || return 0
  worktree="$(_trellis_hookspath_sha256 "$root")" || return 0
  owner="$home/state/attachments/$checkout/$worktree.json"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 0
  enabled="$(jq -r '.git_hooks.enabled // false' "$owner" 2>/dev/null)" || return 0
  [ "$enabled" = true ] || return 0
  managed="$(jq -r '.git_hooks.managed_hooks_path // empty' "$owner" 2>/dev/null)" || return 0
  [ -n "$managed" ] || return 0

  # The sentinel keeps a trailing empty value, which git honours as the last
  # one and which command substitution would otherwise strip.
  values="$(command git -C "$root" config --local --get-all core.hooksPath 2>/dev/null && printf .)"
  rc=$?
  case "$rc" in
    0) values="${values%.}"; values="${values%$'\n'}" ;;
    1) values="" ;;
    *) return 0 ;;
  esac
  if [ "$rc" -eq 0 ]; then
    count="$(printf '%s\n' "$values" | wc -l | tr -d ' ')"
    [ "$count" -ne 1 ] || [ "$values" != "$managed" ] || return 0
    current="$(printf '%s\n' "$values" | sed 's/.*/"&"/' | paste -sd ',' - | sed 's/,/, /g')"
    [ "$count" -eq 1 ] || current="$count values ($current)"
    [ "$values" != ".husky/_" ] || husky=" (husky's \`prepare\` sets .husky/_ after a package install)"
  else
    current="unset"
  fi
  printf 'Trellis git hooks are not running in this worktree: local core.hooksPath is %s%s, not the managed dispatcher "%s", so pushes are ungated. Repair with `trellis doctor --fix`.\n' \
    "$current" "$husky" "$managed"
}

_trellis_hookspath_sha256() {
  local output
  output="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" ||
    output="$(printf '%s' "$1" | sha256sum 2>/dev/null)" || return 1
  printf '%s\n' "${output%% *}"
}
