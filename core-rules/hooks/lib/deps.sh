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

# _se_require_jq <hook-name> [block]
#   - if jq is available → return 0
#   - if TRELLIS_NO_JQ_DEGRADE=1   → write a stderr breadcrumb + exit 0
#   - otherwise                    → write stderr install help + exit 1, or with
#     `block` (bright-line PreToolUse guards) exit 2, Claude's blocking code,
#     because Claude treats exit 1 as a non-blocking error and runs the tool.
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
  if [ "${2:-}" = block ]; then
    echo "${hook}: jq required but not found; refusing — install jq (brew install jq | apt-get install -y jq) or set TRELLIS_NO_JQ_DEGRADE=1 to allow degradation" >&2
    exit 2
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

# _se_state_key <transcript_path> <session_id>
#   - prints the 16-hex state key for the re-read guard's per-session state
#     files, or prints NOTHING (empty) on any failure (caller fails-open).
#   - SOURCE precedence: session_id PRIMARY, transcript_path FALLBACK,
#     literal "default" last. (DL-P5-09: session_id is reliably present on every
#     Claude/Codex event; transcript_path is NullableString with cross-event
#     population unconfirmed — keying off it first risked stamp-turn and the
#     guard deriving DIFFERENT keys → the guard reads a never-written .epoch →
#     permanent silent permit. One shared helper ELIMINATES the drift class.)
#   - SUM = shasum -a 256 of SRC (macOS has no sha256sum); key = first 16 hex of
#     the sum's first field.
_se_state_key() {
  local tp="${1:-}" sid="${2:-}" src sum key
  if [ -n "$sid" ]; then
    src="$sid"
  elif [ -n "$tp" ]; then
    src="$tp"
  else
    src="default"
  fi
  sum=$(printf '%s' "$src" | shasum -a 256 2>/dev/null) || return 1
  sum=$(printf '%s' "$sum" | awk '{print $1}')
  [ -n "$sum" ] || return 1
  key=$(printf '%s' "$sum" | cut -c1-16)
  [ -n "$key" ] || return 1
  printf '%s' "$key"
}

# _se_normpath <path>
#   - prints a LEXICALLY normalized path. No file-existence required (must work
#     for new files). bash 3.2 / BSD-awk safe — pure string ops, NO realpath /
#     readlink -f (absent / non-portable on macOS).
#   - Normalize (DL-P5-10): strip a leading './'; collapse '//' to '/'; collapse
#     '/./' to '/'; resolve a real 'X/../' segment lexically; drop a trailing
#     '/' (but keep a bare '/'). The SAME normalized spelling must be produced
#     on the store side (track-read) and the compare side (reread-guard), so
#     './foo' ≡ 'foo' ≡ 'a/../foo'. A near-no-op for Claude's absolute paths;
#     this fixes the Codex relative-path IN_SET self-block.
_se_normpath() {
  local p="${1:-}"
  [ -n "$p" ] || { printf '%s' "$p"; return; }
  # awk does the segment work so the '..' resolution is robust; it preserves a
  # leading '/' (absolute) and the './' / '//' / '/./' collapses lexically.
  printf '%s' "$p" | awk '
    {
      path = $0
      # remember whether the path is absolute, then split on "/".
      abs = (substr(path, 1, 1) == "/") ? 1 : 0
      n = split(path, parts, "/")
      top = 0            # stack depth of the resolved output segments
      for (i = 1; i <= n; i++) {
        seg = parts[i]
        if (seg == "" || seg == ".") {
          # empty segment (from "//" or leading/trailing "/") or "." → drop.
          continue
        }
        if (seg == "..") {
          if (top > 0 && stack[top] != "..") {
            # pop a real preceding segment (lexical X/.. resolution).
            top--
          } else if (abs) {
            # ".." at the root of an absolute path → drop (stays at root).
            continue
          } else {
            # leading ".." on a relative path has nothing to pop → keep it.
            stack[++top] = ".."
          }
          continue
        }
        stack[++top] = seg
      }
      out = ""
      for (i = 1; i <= top; i++) {
        out = (out == "") ? stack[i] : out "/" stack[i]
      }
      if (abs) {
        out = "/" out          # bare "/" survives (out == "" → just "/")
      } else if (out == "") {
        out = "."              # relative path that normalized to nothing → "."
      }
      printf "%s", out
    }
  '
}

# --- Turn-entry baseline (C01) ------------------------------------------------
# turn-baseline.sh (UserPromptSubmit) appends one line per prompt to
# <state>/<harness>.<KEY>:
#   trellis-turn-baseline v2 <nonce> <head|unborn> <sha256>
# and logs "<harness>.<KEY> <nonce>" to <state>/nonces.log. stop-verify consumes
# both at Stop and, when Stop passes (never after a block), writes the end
# state as a carry line for the next turn (trellis-turn-carry v2 ...), so a
# turn that starts without a prompt (a background notification) still has a
# baseline. Prompt lines take precedence
# over carry lines. A turn is "same" only when every line is well formed, every
# nonce is in the log, and the tree still matches every line in force; anything
# it cannot read, parse, match or recompute is "unknown". Same-uid files cannot be
# made unforgeable: an agent that deliberately rewrites both can still suppress
# the demand (accepted residual, hooks.md § stop-verify).

# _se_turn_state_dir <dir>
#   - prints <TRELLIS_HOME|~/.trellis>/state/turn-baseline/<16 hex of the
#     worktree's physical path>, outside any worktree, so recording a baseline
#     never dirties the tree it measures and linked worktrees stay separate.
#     Fails outside a git worktree or without TRELLIS_HOME/HOME. Creates nothing.
_se_turn_state_dir() {
  local home top sum
  if [ -n "${TRELLIS_HOME:-}" ]; then
    home="$TRELLIS_HOME"
  elif [ -n "${HOME:-}" ]; then
    home="$HOME/.trellis"
  else
    return 1
  fi
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || return 1
  top=$(CDPATH='' cd -P "$top" 2>/dev/null && pwd -P) || return 1
  sum=$(printf '%s' "$top" | shasum -a 256 2>/dev/null) || return 1
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || return 1
  printf '%s/state/turn-baseline/%s' "$home" "$(printf '%s' "$sum" | cut -c1-16)"
}

# _se_turn_baseline_armed <dir> <claude|codex>
#   - succeeds when the project's rendered or legacy hook settings register
#     turn-baseline.sh. Armed, an unknown baseline counts as a change on every
#     path; unarmed (not yet re-rendered), stop-verify keeps its old behaviour.
_se_turn_baseline_armed() {
  local f
  if [ "$2" = "claude" ]; then
    set -- "$1/.claude/settings.local.json" "$1/.claude/settings.json"
  else
    set -- "$1/.codex/hooks.json"
  fi
  for f in "$@"; do
    [ -f "$f" ] && grep -qF 'turn-baseline.sh' "$f" 2>/dev/null && return 0
  done
  return 1
}

# _se_fp_classify — NUL-separated root-relative paths on stdin; one record per
# path on stdout ("F" regular file, "L" symlink + hex of the raw target bytes,
# "X" absent). Fails on anything whose content it cannot cover: a directory
# (submodule or nested repo), a special file, or a path holding a newline or
# tab. The target is hex-encoded because $(readlink) would drop trailing
# newlines and make distinct targets collide.
_se_fp_classify() {
  local p target
  while IFS= read -r -d '' p; do
    case "$p" in *$'\n'*|*$'\t'*) return 1 ;; esac
    if [ -L "$p" ]; then
      target=$(readlink "$p" | od -An -tx1 | tr -d ' \n') || return 1
      [ -n "$target" ] || return 1
      printf 'L\t%s\t%s\n' "$p" "$target"
    elif [ -f "$p" ]; then
      printf 'F\t%s\n' "$p"
    elif [ -e "$p" ]; then
      return 1
    else
      printf 'X\t%s\n' "$p"
    fi
  done
}

# Restrict Git's view at the source, including tracked hook-state files and
# porcelain metadata (filtering only the content hash would still churn).
# The :/ pathspec keeps the whole repository in view; the root-anchored
# excludes do not hide real changes elsewhere in .claude/.pi.
_se_hook_state_git() {
  git "$@" -- ':/' \
    ':(exclude,top).claude/.fail-counter' \
    ':(exclude,top).claude/.reread-state' \
    ':(exclude,top,glob).claude/.review-done-*' \
    ':(exclude,top).claude/session-surgical' \
    ':(exclude,top).claude/spec-gate-audit.log' \
    ':(exclude,top).pi/.reread-state'
}

# _se_tree_fingerprint <dir>
#   - prints "<head|unborn> <sha256>" over HEAD, the full porcelain-v2 status
#     (HEAD and index object ids, modes, renames, untracked paths) and the
#     content of every non-ignored path that differs from the index or is
#     untracked. Any failed git call or uncoverable path → non-zero, never a
#     partial hash. Ignored files are out of scope, as for the dirty-tree check.
_se_tree_fingerprint() (
  set -o pipefail
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && cd "$top" || exit 1
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=unborn
  paths=$( { _se_hook_state_git diff --no-ext-diff --name-only -z && _se_hook_state_git ls-files --others --exclude-standard -z; } \
    | _se_fp_classify) || exit 1
  sum=$( { printf 'head\t%s\n' "$head" &&
           _se_hook_state_git --no-optional-locks status --porcelain=v2 -z --untracked-files=all &&
           printf '\n%s\n' "$paths" &&
           printf '%s\n' "$paths" | awk -F '\t' '$1 == "F" { print $2 }' \
             | git hash-object --no-filters --stdin-paths
         } | shasum -a 256) || exit 1
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || exit 1
  printf '%s %s\n' "$head" "$sum"
)

# _se_turn_nonce — prints 32 random hex digits, or fails.
_se_turn_nonce() {
  local n
  n=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$n" in *[!0-9a-f]*|"") return 1 ;; esac
  [ "${#n}" -eq 32 ] || return 1
  printf '%s' "$n"
}

# _se_turn_carry_write <state-dir> <harness>.<KEY> <dir>
#   - appends the current end state as a carry line (fresh nonce, logged
#     first) for the next turn. Any failure writes nothing usable, so the next
#     promptless turn reads unknown.
_se_turn_carry_write() {
  local sdir="$1" id="$2" nonce fp
  nonce=$(_se_turn_nonce) || return 0
  fp=$(_se_tree_fingerprint "$3") || return 0
  ( umask 077 && mkdir -p "$sdir" ) 2>/dev/null || return 0
  ( umask 077 && printf '%s %s\n' "$id" "$nonce" >> "$sdir/nonces.log" ) 2>/dev/null || return 0
  ( umask 077 && printf 'trellis-turn-carry v2 %s %s\n' "$nonce" "$fp" >> "$sdir/$id" ) 2>/dev/null \
    || rm -f "$sdir/$id" 2>/dev/null
  chmod 600 "$sdir/$id" "$sdir/nonces.log" 2>/dev/null
  return 0
}

# _se_turn_baseline_select <baseline-lines>
#   - prints the lines in force: the prompt lines when there are any (they take
#     precedence), else the carry lines.
_se_turn_baseline_select() {
  if printf '%s\n' "$1" | grep -q '^trellis-turn-baseline '; then
    printf '%s\n' "$1" | grep '^trellis-turn-baseline '
  else
    printf '%s\n' "$1"
  fi
}

# _se_turn_baseline_state <baseline-lines> <current-fingerprint> <logged-nonces>
#   - prints same | changed | unknown. Empty input, any malformed line (incl.
#     the writer's "unknown" poison line), a nonce missing from the hook's log,
#     or an empty fingerprint → unknown.
_se_turn_baseline_state() {
  local lines="$1" now="$2" nonces="$3" n
  [ -n "$lines" ] && [ -n "$now" ] && [ -n "$nonces" ] || { echo unknown; return; }
  if printf '%s\n' "$lines" \
       | grep -Evq '^trellis-turn-(baseline|carry) v2 [0-9a-f]{32} (unborn|[0-9a-f]{40}|[0-9a-f]{64}) [0-9a-f]{64}$'; then
    echo unknown
    return
  fi
  for n in $(printf '%s\n' "$lines" | awk '{ print $3 }'); do
    printf '%s\n' "$nonces" | grep -qxF "$n" || { echo unknown; return; }
  done
  if _se_turn_baseline_select "$lines" | awk '{ print $4, $5 }' | grep -vqxF "$now"; then
    echo changed
  else
    echo same
  fi
}

# _se_turn_nonce_take <state-dir> <harness>.<KEY>
#   - prints the nonces logged for that baseline and removes them from the log
#     (the baseline is single use). A failed rewrite leaves stale entries,
#     which only ever match the baseline file that is deleted alongside.
_se_turn_nonce_take() {
  local log="$1/nonces.log" tmp
  [ -f "$log" ] || return 0
  awk -v k="$2" '$1 == k { print $2 }' "$log" 2>/dev/null
  tmp="$log.$$"
  if ( umask 077 && awk -v k="$2" '$1 != k' "$log" > "$tmp" ) 2>/dev/null; then
    mv -f "$tmp" "$log" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# _se_turn_range_files <dir> <current-head> <baseline-lines>
#   - prints the paths changed between each entry HEAD in force and the current
#     HEAD (a turn that committed). Fails when any range cannot be read.
_se_turn_range_files() {
  local dir="$1" now="$2" h from
  for h in $(_se_turn_baseline_select "$3" | awk '{ print $4 }' | sort -u); do
    [ "$h" = "$now" ] && continue
    [ "$now" != unborn ] || return 1
    if [ "$h" = unborn ]; then
      from=$(git -C "$dir" hash-object -t tree /dev/null) || return 1
    else
      from="$h"
    fi
    git -C "$dir" diff --no-ext-diff --no-renames --name-only "$from" "$now" || return 1
  done
}
