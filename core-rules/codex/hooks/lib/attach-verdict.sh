#!/usr/bin/env bash
# attach-verdict.sh — the Stop gate on a worktree's attachment checks verdict.
# Source: Trellis / spec 074 T14, amended 2026-11-10 (owner decision).
#
# Attach returns once a worktree is attached; its background checks job writes
# a verdict under $TRELLIS_HOME/state/attachment-status. The next Stop (here)
# and the next push gate on it. Fast path: a schema-2 ok verdict bound to this
# worktree's owner record (attachment, release, root, owner digest) passes
# without starting anything; a recorded toolchain failure passes here too (it
# is push-only, as before). Everything else is decided by the gate of this
# hook's own payload (scripts/lib/attach-postjob.sh gate --for stop), which
# waits for a pending job, runs the full job for a missing or stale verdict,
# and refuses with a labelled reason. A worktree with no owner record has no
# attachment and passes.
#
# trellis_attach_verdict_stop ROOT: 0 pass; 1 block with the reason on stdout.
# Bash 3.2 compatible. Claude and Codex twins are byte-identical.

_trellis_attach_verdict_sha256() {
  local out
  out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" || out="$(printf '%s' "$1" | sha256sum 2>/dev/null)" || return 1
  printf '%s\n' "${out%% *}"
}

_trellis_attach_verdict_file_sha256() {
  local out
  out="$(shasum -a 256 "$1" 2>/dev/null)" || out="$(sha256sum "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${out%% *}"
}

_trellis_attach_verdict_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

trellis_attach_verdict_stop() {
  local root="${1:-}" home top common checkout worktree owner status payload gate out rc
  if [ -n "${TRELLIS_HOME:-}" ]; then
    home="$TRELLIS_HOME"
  elif [ -n "${HOME:-}" ]; then
    home="$HOME/.trellis"
  else
    return 0
  fi
  [ -n "$root" ] && [ -d "$root" ] || return 0
  if ! top="$(command git -C "$root" rev-parse --show-toplevel 2>/dev/null)" ||
     ! common="$(command git -C "$top" rev-parse --git-common-dir 2>/dev/null)"; then
    # Git cannot identify the worktree. Fail closed when it is the main
    # checkout of an attachment (its .git directory names the owner);
    # otherwise there is no attachment to look up.
    [ -d "$root/.git" ] && [ ! -L "$root/.git" ] || return 0
    root="$(CDPATH='' cd -P "$root" 2>/dev/null && pwd -P)" || return 0
    common="$(CDPATH='' cd -P "$root/.git" 2>/dev/null && pwd -P)" || return 0
    checkout="$(_trellis_attach_verdict_sha256 "$common")" || return 0
    worktree="$(_trellis_attach_verdict_sha256 "$root")" || return 0
    owner="$home/state/attachments/$checkout/$worktree.json"
    if [ -e "$owner" ] || [ -L "$owner" ]; then
      printf 'attachment checks: Git could not identify %s, which has an attachment owner record; remedy: trellis doctor --fix\n' "$root"
      return 1
    fi
    return 0
  fi
  root="$(CDPATH='' cd -P "$top" 2>/dev/null && pwd -P)" || return 0
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  common="$(CDPATH='' cd -P "$common" 2>/dev/null && pwd -P)" || return 0
  checkout="$(_trellis_attach_verdict_sha256 "$common")" || {
    printf 'attachment checks: could not identify %s\n' "$root"
    return 1
  }
  worktree="$(_trellis_attach_verdict_sha256 "$root")" || {
    printf 'attachment checks: could not identify %s\n' "$root"
    return 1
  }
  owner="$home/state/attachments/$checkout/$worktree.json"
  # No owner record: this worktree has no Trellis attachment to gate.
  [ -e "$owner" ] || [ -L "$owner" ] || return 0
  status="$home/state/attachment-status/$checkout/$worktree.json"
  if [ -f "$owner" ] && [ ! -L "$owner" ] && [ -f "$status" ] && [ ! -L "$status" ] &&
     [ "$(_trellis_attach_verdict_mode "$status")" = 600 ] &&
     out="$(_trellis_attach_verdict_file_sha256 "$owner")" &&
     jq -e --arg sha "$out" --arg root "$root" --arg checkout "$checkout" --arg worktree "$worktree" \
       --slurpfile owner "$owner" '
         $owner[0] as $o
         | .schema_version == 2
           and (.state == "ok" or (.state == "failed" and .failure.check? == "toolchain"))
           and .owner_sha256 == $sha and .checkout_id == $checkout and .worktree_id == $worktree
           and (.attachment_id | type == "string") and (.release | type == "string")
           and .attachment_id == $o.attachment_id and .release == $o.release
           and .worktree_root == $o.worktree_root and .worktree_root == $root
       ' "$status" >/dev/null 2>&1; then
    return 0
  fi
  # The gate is this hook's own payload, the code already running here, never
  # a path an owner record or the release store could redirect.
  payload="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || payload=""
  payload="${payload%/core-rules/*}"
  gate="$payload/scripts/lib/attach-postjob.sh"
  if [ -z "$payload" ] || [ ! -f "$gate" ] || [ -L "$gate" ]; then
    printf 'attachment checks: this hook payload has no checks gate, so the checks for %s cannot run; remedy: trellis doctor --fix\n' "$root"
    return 1
  fi
  # As the attach spawn runs the job: the installed release, the harness PATH
  # (the checks need its jq and git), no Git or shell-startup overrides.
  out="$(/usr/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_PREFIX \
    -u BASH_ENV -u ENV TRELLIS_HOME="$home" \
    /bin/bash --noprofile --norc "$gate" gate --for stop --target "$root" 2>&1 >/dev/null </dev/null)"
  rc=$?
  [ "$rc" -ne 0 ] || return 0
  printf '%s\n' "${out:-attachment checks did not pass for $root (exit $rc); remedy: trellis doctor --fix}"
  return 1
}
