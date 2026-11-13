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
#   - with `block` (bright-line PreToolUse guards) → a block document + exit 2.
#     TRELLIS_NO_JQ_DEGRADE never applies here: a bright-line guard must not
#     become a no-op.
#   - if TRELLIS_NO_JQ_DEGRADE=1   → write a stderr breadcrumb + exit 0
#   - otherwise                    → write stderr install help + exit 1
#
# Replaces the inline `if ! command -v jq ...; then exit 0; fi` pattern that
# silently dropped enforcement on jq-less environments (audit §3.2 / P1.5).
_se_require_jq() {
  local hook="${1:-hook}"
  if command -v jq >/dev/null 2>&1; then return 0; fi
  if [ "${2:-}" = block ]; then
    printf '{"decision":"block","reason":"%s: jq required but not found; refusing"}\n' "$hook"
    echo "${hook}: jq required but not found; refusing — install jq (brew install jq | apt-get install -y jq); TRELLIS_NO_JQ_DEGRADE does not apply to this guard" >&2
    exit 2
  fi
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

# _se_harness_home <root>
#   - selects the fixed per-harness runtime namespace beneath <root>.
#   - only the validated enum value TRELLIS_HARNESS=pi selects .pi; unset,
#     codex, and every other value preserve the existing .codex default.
#   - callers cannot supply an arbitrary filesystem destination through env.
_se_harness_home() {
  local root="$1"
  if [ "${TRELLIS_HARNESS:-codex}" = "pi" ]; then
    printf '%s/.pi' "$root"
  else
    printf '%s/.codex' "$root"
  fi
}

# _se_emit_hook_context <HookEventName> <message>
#   - emits Codex's current event-specific advisory shape.
#   - SessionStart/PostToolUse/SubagentStart/UserPromptSubmit context is not a
#     top-level `additionalContext`; Codex 0.142+ requires it under
#     `hookSpecificOutput` with the matching hookEventName.
_se_emit_hook_context() {
  local event="$1" msg="$2"
  jq -nc --arg event "$event" --arg msg "$msg" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $msg}}'
}

# _se_emit_system_message <message>
#   - emits a Stop-safe advisory. Codex Stop output does not accept
#     `additionalContext`; `systemMessage` is part of the Stop output schema.
_se_emit_system_message() {
  local msg="$1"
  jq -nc --arg msg "$msg" '{systemMessage: $msg}'
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
  # One git process: --git-common-dir fails outside a repository exactly where
  # a separate --is-inside-work-tree probe fails (both set up the repository
  # first and print "false"/a path with status 0 inside .git or a bare repo).
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
#   - SUM = SHA-256 of SRC; key = first 16 hex of the sum's first field. The
#     digest comes from sha256sum where it exists (coreutils; macOS 14+), one C
#     process against shasum's perl start, and from shasum otherwise or when
#     sha256sum prints anything but 64 lowercase hex.
_se_state_key() {
  local tp="${1:-}" sid="${2:-}" src sum=""
  if [ -n "$sid" ]; then
    src="$sid"
  elif [ -n "$tp" ]; then
    src="$tp"
  else
    src="default"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$src" | sha256sum 2>/dev/null) || sum=""
    sum=${sum%%[[:space:]]*}
    case "$sum" in *[!0-9a-f]*) sum="" ;; esac
    [ "${#sum}" -eq 64 ] || sum=""
  fi
  if [ -z "$sum" ]; then
    sum=$(printf '%s' "$src" | shasum -a 256 2>/dev/null) || return 1
    sum=${sum#"${sum%%[![:space:]]*}"}
    sum=${sum%%[[:space:]]*}
  fi
  [ -n "$sum" ] || return 1
  printf '%s' "${sum:0:16}"
}

# _se_stop_sha256_text <bytes> — full digest for the Stop reuse key. The
# input is already held in a shell variable so a malformed/failed sha256sum
# can be retried with shasum without re-reading a consumed pipe. Both tools
# must return a 64-byte lowercase hex digest; uncertainty is a reuse miss.
_se_stop_sha256_text() {
  local src="$1" sum=""
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$src" | sha256sum 2>/dev/null) || sum=""
    sum=${sum%%[[:space:]]*}
    case "$sum" in *[!0-9a-f]*) sum="" ;; esac
    [ "${#sum}" -eq 64 ] || sum=""
  fi
  if [ -z "$sum" ]; then
    command -v shasum >/dev/null 2>&1 || return 1
    sum=$(printf '%s' "$src" | shasum -a 256 2>/dev/null) || return 1
    sum=${sum%%[[:space:]]*}
    case "$sum" in *[!0-9a-f]*) return 1 ;; esac
    [ "${#sum}" -eq 64 ] || return 1
  fi
  printf '%s' "$sum"
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
  # Already normal (no empty, "." or ".." segment, no trailing "/"): the awk
  # pass below would print it unchanged, so skip that process.
  case "/${p#/}/" in
    *//*|*/./*|*/../*) ;;
    *) printf '%s' "$p"; return ;;
  esac
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

# _se_turn_sha256 — hash stdin in the selected utility's native output format.
# Prefer existing shasum (macOS); select before reading stdin, never retry a
# failed command against an already-consumed stream.
_se_turn_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    return 1
  fi
}

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
  sum=$(printf '%s' "$top" | _se_turn_sha256 2>/dev/null) || return 1
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || return 1
  printf '%s/state/turn-baseline/%s' "$home" "${sum:0:16}"
}

# Release-store ACL listing semantics, restricted to the exact trusted paths:
# Darwin -e exposes ACL rows even when @ hides +; GNU ls marks ACLs with +.
# A malformed or incomplete listing is unknown. Pure Bash parsing adds no
# process beyond the one /bin/ls for all entries.
_se_acl_listing_safe() {
  local listing="$1" expected="$2" line mode links who group size month day clock name permissions suffix count=0
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected" -gt 0 ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || return 1
    IFS=$' \t' read -r mode links who group size month day clock name <<< "$line"
    [ -n "$mode" ] && [ -n "$links" ] && [ -n "$who" ] && [ -n "$group" ] \
      && [ -n "$size" ] && [ -n "$month" ] && [ -n "$day" ] && [ -n "$clock" ] && [ -n "$name" ] || return 1
    case "$links:$size:$day" in *[!0-9:]*) return 1 ;; esac
    [ "${#mode}" -ge 10 ] && [ "${#mode}" -le 11 ] || return 1
    case "${mode:0:1}" in -|d) ;; *) return 1 ;; esac
    permissions=${mode:1:9}; suffix=${mode:10}
    case "$permissions" in *[!rwxstST-]*) return 1 ;; esac
    case "$suffix" in ''|'@'|'.') ;; *) return 1 ;; esac
    count=$((count + 1))
  done <<< "$listing"
  [ "$count" -eq "$expected" ]
}
_se_paths_no_acl() {
  local platform="$1" listing
  shift
  [ "$#" -gt 0 ] || return 1
  case "$platform" in
    Darwin) listing=$(/usr/bin/env LC_ALL=C TIME_STYLE=locale /bin/ls -lde "$@" 2>/dev/null) || return 1 ;;
    Linux) listing=$(/usr/bin/env LC_ALL=C TIME_STYLE=locale /bin/ls -ld "$@" 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  _se_acl_listing_safe "$listing" "$#"
}

# Functions only the Stop, edit-verification, spec, receipt, context-save and
# doctor paths use live in lib/deps-heavy.sh beside this file, so the hooks
# that never call them do not parse them. _se_load_heavy sources it once, from
# the same directory (and so the same proven, embedded or stamped copy) as this
# file. A missing, symlinked or unloadable copy fails closed: it returns 70 and
# the stubs below exit 70 rather than run with an absent function.
_se_load_heavy() {
  [ -z "${__se_heavy_loaded:-}" ] || return 0
  local lib="${BASH_SOURCE[0]%/*}/deps-heavy.sh"
  # shellcheck source=deps-heavy.sh disable=SC1090
  if [ ! -f "$lib" ] || [ -L "$lib" ] || ! . "$lib" || [ "${__se_heavy_loaded:-}" != 1 ]; then
    printf 'trellis hooks: %s is missing or failed to load; refusing\n' "$lib" >&2
    return 70
  fi
}

# First-call stubs: load deps-heavy.sh, then call the real definition.
# Sourcing this file again replaces any loaded definitions with these stubs, so
# the loaded flag is cleared with them; otherwise a stub would call itself.
unset __se_heavy_loaded
_se_inherited_project_mismatch() { _se_load_heavy || exit 70; _se_inherited_project_mismatch "$@"; }
_se_turn_confirm_non_git() { _se_load_heavy || exit 70; _se_turn_confirm_non_git "$@"; }
_se_turn_quote() { _se_load_heavy || exit 70; _se_turn_quote "$@"; }
_se_turn_json_strict() { _se_load_heavy || exit 70; _se_turn_json_strict "$@"; }
_se_turn_json_strict_each() { _se_load_heavy || exit 70; _se_turn_json_strict_each "$@"; }
_se_turn_directory_inspectable() { _se_load_heavy || exit 70; _se_turn_directory_inspectable "$@"; }
_se_turn_baseline_arming() { _se_load_heavy || exit 70; _se_turn_baseline_arming "$@"; }
_se_turn_baseline_armed() { _se_load_heavy || exit 70; _se_turn_baseline_armed "$@"; }
_se_fp_classify() { _se_load_heavy || exit 70; _se_fp_classify "$@"; }
_se_hook_state_git() { _se_load_heavy || exit 70; _se_hook_state_git "$@"; }
_se_flagged_candidates() { _se_load_heavy || exit 70; _se_flagged_candidates "$@"; }
_se_index_stamp() { _se_load_heavy || exit 70; _se_index_stamp "$@"; }
_se_unmasked_index() { _se_load_heavy || exit 70; _se_unmasked_index "$@"; }
_se_flagged_changed_files() { _se_load_heavy || exit 70; _se_flagged_changed_files "$@"; }
_se_flagged_changed_lines() { _se_load_heavy || exit 70; _se_flagged_changed_lines "$@"; }
_se_tree_fingerprint() { _se_load_heavy || exit 70; _se_tree_fingerprint "$@"; }
_se_state_lock_try() { _se_load_heavy || exit 70; _se_state_lock_try "$@"; }
_se_turn_lock() { _se_load_heavy || exit 70; _se_turn_lock "$@"; }
_se_turn_unlock() { _se_load_heavy || exit 70; _se_turn_unlock "$@"; }
_se_turn_poison() { _se_load_heavy || exit 70; _se_turn_poison "$@"; }
_se_turn_is_poisoned() { _se_load_heavy || exit 70; _se_turn_is_poisoned "$@"; }
_se_turn_clear_poison() { _se_load_heavy || exit 70; _se_turn_clear_poison "$@"; }
_se_turn_generation_read() { _se_load_heavy || exit 70; _se_turn_generation_read "$@"; }
_se_turn_generation_bump() { _se_load_heavy || exit 70; _se_turn_generation_bump "$@"; }
_se_turn_nonce() { _se_load_heavy || exit 70; _se_turn_nonce "$@"; }
_se_turn_start_append() { _se_load_heavy || exit 70; _se_turn_start_append "$@"; }
_se_turn_baseline_publish() { _se_load_heavy || exit 70; _se_turn_baseline_publish "$@"; }
_se_turn_carry_write() { _se_load_heavy || exit 70; _se_turn_carry_write "$@"; }
_se_turn_baseline_select() { _se_load_heavy || exit 70; _se_turn_baseline_select "$@"; }
_se_turn_baseline_state() { _se_load_heavy || exit 70; _se_turn_baseline_state "$@"; }
_se_ui_baseline_append() { _se_load_heavy || exit 70; _se_ui_baseline_append "$@"; }
_se_ui_baseline_load() { _se_load_heavy || exit 70; _se_ui_baseline_load "$@"; }
_se_turn_nonce_take_locked() { _se_load_heavy || exit 70; _se_turn_nonce_take_locked "$@"; }
_se_turn_consume() { _se_load_heavy || exit 70; _se_turn_consume "$@"; }
_se_turn_observe_unarmed() { _se_load_heavy || exit 70; _se_turn_observe_unarmed "$@"; }
_se_turn_discard_reentrant() { _se_load_heavy || exit 70; _se_turn_discard_reentrant "$@"; }
_se_turn_range_files() { _se_load_heavy || exit 70; _se_turn_range_files "$@"; }
_se_stat_lines() { _se_load_heavy || exit 70; _se_stat_lines "$@"; }
_se_find_eslint_config() { _se_load_heavy || exit 70; _se_find_eslint_config "$@"; }
_se_node_bin() { _se_load_heavy || exit 70; _se_node_bin "$@"; }
_se_stop_receipt_file() { _se_load_heavy || exit 70; _se_stop_receipt_file "$@"; }
_se_stop_receipt_match() { _se_load_heavy || exit 70; _se_stop_receipt_match "$@"; }
_se_stop_receipt_write() { _se_load_heavy || exit 70; _se_stop_receipt_write "$@"; }
_se_kill_tree() { _se_load_heavy || exit 70; _se_kill_tree "$@"; }
_se_kill_identities() { _se_load_heavy || exit 70; _se_kill_identities "$@"; }
_se_kill_survivors() { _se_load_heavy || exit 70; _se_kill_survivors "$@"; }
_se_kill_wait() { _se_load_heavy || exit 70; _se_kill_wait "$@"; }
_se_stop_fast_config() { _se_load_heavy || exit 70; _se_stop_fast_config "$@"; }
_se_ignored_digest() { _se_load_heavy || exit 70; _se_ignored_digest "$@"; }
_se_tool_closure() { _se_load_heavy || exit 70; _se_tool_closure "$@"; }
_se_pkg_digest() { _se_load_heavy || exit 70; _se_pkg_digest "$@"; }
_se_pm_progs() { _se_load_heavy || exit 70; _se_pm_progs "$@"; }
_se_pm_config() { _se_load_heavy || exit 70; _se_pm_config "$@"; }
_se_env_moves_code() { _se_load_heavy || exit 70; _se_env_moves_code "$@"; }
