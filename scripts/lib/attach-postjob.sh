#!/usr/bin/env bash
# attach-postjob.sh — the deferred post-attach checks (1.3.12 workstream A, A4).
#
# Attach and post-checkout keep only what must hold before the agent acts: the
# owner record, the managed hooksPath, the guard renders. The rest runs here,
# in ONE detached job per worktree, which records its verdict in
#
#   $TRELLIS_HOME/state/attachment-status/<checkout_id>/<worktree_id>.json
#
# (0600 in 0700 directories, replaced atomically). States:
#   pending             spawned, not yet run, or retrying after contention
#   running             checks in progress
#   ok                  every check passed for the recorded attachment
#   failed              one check failed; .failure = {check, code, remedy}
#   blocked-by-journal  an attachment journal or adoption marker for this
#                       checkout is pending; nothing was checked
# A status is STALE, and reads like pending, when its attachment_id or
# owner_sha256 no longer match the live owner record.
#
# Checks, in order: hooks-path (re-asserts a husky-reset core.hooksPath through
# the doctor R4.6 repair), release (full immutable release verify, skipped
# when the release stamp proves it unchanged since one), owner-artifacts,
# exclude, toolchain, registry (consistency, and the exact-owner reconcile only
# when the row disagrees).
#
# Locks (no new lock): the per-checkout attachment lock is acquired non-blocking
# for hooksPath repair and the final commit (journal/owner re-check, registry
# reconcile, status write). Registry reconciliation may wait through the bounded
# 300-second registry budget while holding that checkout lock; lock ordering
# stays checkout -> registry. Unavailable registry state leaves status pending
# and the background job retries with backoff. A
# second job for the same worktree exits at once (mkdir lock, pid + birth).
#
# Surfaces: SessionStart reads the file as data (core-rules/hooks/lib/
# hookspath-check.sh), doctor reports a row and runs the job under --fix, and
# the managed pre-push runs `prepush`: FAILED and blocked refuse, ok passes,
# anything else runs the read-only checks inline. The gates never get weaker.
#
# Sourced by attach-project.sh and doctor.sh, which have already loaded
# trellis-home.sh, local-registry.sh and attachment.sh; executed by the spawn,
# doctor --fix and the managed pre-push. Bash 3.2 compatible.

_ATTACH_POSTJOB_SELF="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/attach-postjob.sh"
# shellcheck source=release-stamp.sh
. "${_ATTACH_POSTJOB_SELF%/*}/release-stamp.sh"
ATTACH_STATUS_PENDING_WARN_SECONDS=900
ATTACH_POSTJOB_RETRIES=6
ATTACH_POSTJOB_EX_FAILED=1
ATTACH_POSTJOB_EX_BLOCKED=3
ATTACH_POSTJOB_EX_PENDING=5

attach_status_path() {
  printf '%s/state/attachment-status/%s/%s.json\n' "$1" "$2" "$3"
}

_attach_status_private_dir() {
  local dir="$1"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    (umask 077 && mkdir "$dir") 2>/dev/null || true
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  chmod 700 "$dir"
}

_attach_status_prepare() {
  local home="$1" checkout="$2"
  _attach_status_private_dir "$home/state" &&
    _attach_status_private_dir "$home/state/attachment-status" &&
    _attach_status_private_dir "$home/state/attachment-status/$checkout"
}

# attach_status_write <home> <checkout> <worktree> <state> <attachment> <owner-sha> <checks> <failure>
attach_status_write() {
  local home="$1" checkout="$2" worktree="$3" path tmp json
  json="$(jq -cn --arg state "$4" --arg checkout "$checkout" --arg worktree "$worktree" \
    --arg attachment "$5" --arg sha "$6" --argjson checks "$7" --argjson failure "$8" \
    --argjson at "$(date +%s)" '
      {schema_version:1,state:$state,checkout_id:$checkout,worktree_id:$worktree,
       attachment_id:$attachment,owner_sha256:$sha,updated_at:$at,checks:$checks,failure:$failure}')" || return 1
  _attach_status_prepare "$home" "$checkout" || return 1
  path="$(attach_status_path "$home" "$checkout" "$worktree")"
  [ ! -L "$path" ] || return 1
  tmp="$(mktemp "${path%/*}/.$worktree.json.XXXXXX")" || return 1
  if ! { chmod 600 "$tmp" && printf '%s\n' "$json" > "$tmp" && mv -f "$tmp" "$path"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# attach_status_classify <home> <owner> <checkout> <worktree>
# Prints one TSV line: class, age in seconds, failed check, remedy. The class is
# missing, stale, pending, running, ok, failed or blocked-by-journal. Anything
# unreadable, malformed, or bound to another attachment state is stale.
attach_status_classify() {
  local home="$1" owner="$2" path record state attachment sha at check remedy now
  path="$(attach_status_path "$home" "$3" "$4")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'missing\t0\t\t\n'
    return 0
  fi
  now="$(date +%s)"
  if [ -L "$path" ] || [ ! -f "$path" ] || [ "$(_attachment_mode "$path")" != 600 ] ||
     ! record="$(jq -r '
       select(.schema_version == 1
         and (.state | IN("pending","running","ok","failed","blocked-by-journal"))
         and (.attachment_id | type == "string") and (.owner_sha256 | type == "string")
         and (.updated_at | type == "number"))
       | [.state, .attachment_id, .owner_sha256, (.updated_at | floor | tostring),
          (.failure.check? // ""), (.failure.remedy? // "")]
       | map(gsub("[[:cntrl:]]"; " ")) | @tsv' "$path" 2>/dev/null)" || [ -z "$record" ]; then
    printf 'stale\t0\t\t\n'
    return 0
  fi
  IFS=$'\t' read -r state attachment sha at check remedy <<EOF
$record
EOF
  if [ "$attachment" != "$(jq -r '.attachment_id' "$owner" 2>/dev/null)" ] ||
     [ "$sha" != "$(_attachment_hash "$owner" 2>/dev/null)" ]; then
    state=stale
  fi
  printf '%s\t%s\t%s\t%s\n' "$state" "$((now - at))" "$check" "$remedy"
}

# Exact attachment journals (attach, detach, reconcile) for this checkout, or
# its group adoption marker. A journal that cannot be read counts as pending.
# Prints the remedy and succeeds when one is pending.
attach_postjob_journal_pending() {
  local home="$1" checkout="$2" root="$3" dir="$1/state/attachment-journals" found
  if [ -e "$home/state/release-adoptions/$checkout" ] || [ -L "$home/state/release-adoptions/$checkout" ]; then
    printf 'a group release adoption is pending for this checkout; remedy: retry trellis release adopt with the same selector to recover\n'
    return 0
  fi
  [ -d "$dir" ] || return 1
  found="$(find "$dir" -maxdepth 1 -type f -name '*.json' -exec jq -r --arg checkout "$checkout" '
    select([.checkout_id?, .original_owner?.checkout_id?, .owner?.checkout_id?] | index($checkout)) | input_filename
  ' {} + 2>/dev/null)" || found=pending
  [ -n "$found" ] || return 1
  printf 'an attachment journal for this checkout is pending; remedy: trellis recover %s\n' "$root"
  return 0
}

# trellis_attach_postjob_spawn HOME ROOT          (frozen interface, A1–A5)
#   HOME  the resolved TRELLIS_HOME; ROOT  the worktree root just attached.
# The single call site for attach, post-checkout and worktree sync. Requires
# trellis-home.sh, local-registry.sh, release-store.sh and attachment.sh
# already sourced.
# Writes the worktree's status as pending, then starts the job fully detached —
# its own session, stdin /dev/null, stdout/stderr to
# state/attachment-status/<checkout>/<worktree>.log, every other descriptor
# closed — and RETURNS IMMEDIATELY; it never waits for the job or for a lock.
# The job runs from the installed release, never from an execution snapshot:
# the snapshot is removed when this process exits, which the detached job can
# outlive, so a snapshot path would vanish underneath it mid-source.
# Exit code: always 0. A spawn failure prints one stderr line and leaves the
# status missing or pending, which pre-push treats by running the checks
# inline, so it never fails or slows the caller. No owner record for ROOT:
# nothing is spawned. Lock contention inside the job means the status stays
# PENDING and the background job retries with backoff (1+2+4+8+16 s); it never
# waits in the foreground. TRELLIS_ATTACH_POSTJOB=off skips the spawn entirely
# (the suite runner sets it).
trellis_attach_postjob_spawn() {
  local home="$1" root="$2" identity checkout worktree owner log release payload postjob
  [ "${TRELLIS_ATTACH_POSTJOB:-}" != off ] || return 0
  if identity="$(local_registry_identity_for_root "$root" 2>/dev/null)" &&
     checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" &&
     worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')" &&
     owner="$(_attachment_ownership_path "$home" "$checkout" "$worktree")" && [ -f "$owner" ] &&
     release="$(jq -r '.release' "$owner" 2>/dev/null)" &&
     payload="$(TRELLIS_HOME="$home" release_store_locate "$release" 2>/dev/null)" &&
     postjob="$payload/payload/scripts/lib/attach-postjob.sh" && [ -f "$postjob" ] && [ ! -L "$postjob" ] &&
     attach_status_write "$home" "$checkout" "$worktree" pending "$(jq -r '.attachment_id' "$owner")" \
       "$(_attachment_hash "$owner")" '[]' null; then
    log="$home/state/attachment-status/$checkout/$worktree.log"
    if perl -MPOSIX -e '
      my $log = shift @ARGV;
      defined(my $pid = fork) or exit 1;
      if ($pid) { waitpid($pid, 0); exit($? >> 8); }
      POSIX::setsid() or POSIX::_exit(1);
      defined(my $grandchild = fork) or POSIX::_exit(1);
      POSIX::_exit(0) if $grandchild;
      open(STDIN, "<", "/dev/null") or POSIX::_exit(1);
      open(STDOUT, ">>", $log) or POSIX::_exit(1);
      open(STDERR, ">&", \*STDOUT) or POSIX::_exit(1);
      # Close every descriptor actually open above stderr, by enumeration;
      # a guessed ceiling misses inherited descriptors above it.
      my ($dir, @fds);
      if (opendir($dir, "/proc/self/fd") || opendir($dir, "/dev/fd")) {
        @fds = grep { /^[0-9]+$/ && $_ > 2 } readdir($dir);
        closedir($dir);
      } else {
        my $max = POSIX::sysconf(POSIX::_SC_OPEN_MAX());
        POSIX::_exit(1) if !defined($max) || $max < 3;
        @fds = (3 .. $max - 1);
      }
      POSIX::close($_) for @fds;
      exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
    ' "$log" /usr/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_PREFIX \
      -u TMPDIR TRELLIS_HOME="$home" /bin/bash --noprofile --norc "$postjob" run --target "$root" \
      </dev/null >/dev/null 2>&1; then
      return 0
    fi
  fi
  printf 'trellis attach: the deferred attachment checks could not start for %s; pre-push runs them inline (trellis doctor --fix runs them now)\n' "$root" >&2
  return 0
}

# hc_portable_attach_status <home> <owner> <checkout> <worktree>: the doctor row.
hc_portable_attach_status() {
  local line class age check remedy minutes
  line="$(attach_status_classify "$1" "$2" "$3" "$4")" || return "$HC_ERROR"
  IFS=$'\t' read -r class age check remedy <<EOF
$line
EOF
  minutes=$((age / 60))
  case "$class" in
    ok) echo "attachment checks: ok"; return "$HC_OK" ;;
    missing)
      echo 'attachment checks: not recorded for this attachment; pre-push runs them inline; trellis doctor --fix runs them now'
      return "$HC_INFO"
      ;;
    stale)
      echo 'attachment checks: stale (recorded for an earlier attachment state); pre-push runs them inline; remedy: trellis doctor --fix'
      return "$HC_WARN"
      ;;
    pending|running)
      if [ "$age" -gt "$ATTACH_STATUS_PENDING_WARN_SECONDS" ]; then
        echo "attachment checks: $class for $minutes min; pre-push runs them inline; remedy: trellis doctor --fix"
        return "$HC_WARN"
      fi
      echo "attachment checks: $class; pre-push runs them inline until they finish"
      return "$HC_INFO"
      ;;
    failed)
      echo "attachment checks FAILED at $check; pushes from this worktree are refused; remedy: $remedy"
      return "$HC_ERROR"
      ;;
    blocked-by-journal)
      echo "attachment checks blocked by an unfinished Trellis operation; $remedy"
      return "$HC_ERROR"
      ;;
  esac
  echo "attachment checks: unreadable status class $class"
  return "$HC_ERROR"
}

# ---------------------------------------------------------------------------
# The job. Everything below runs only when this file is executed.
# ---------------------------------------------------------------------------

_attach_postjob_log() {
  printf '%s attach-postjob: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

_attach_postjob_checks_add() {
  _APJ_CHECKS="$(jq -cn --argjson checks "$_APJ_CHECKS" --arg name "$1" --arg result "$2" \
    '$checks + [{name:$name,result:$result}]')"
}

_attach_postjob_status() {
  attach_status_write "$_APJ_HOME" "$_APJ_CHECKOUT" "$_APJ_WORKTREE" "$1" "$_APJ_ATTACHMENT" "$_APJ_OWNER_SHA" \
    "$_APJ_CHECKS" "${2:-null}"
}

_attach_postjob_fail() {
  local check="$1" code="$2" remedy="$3"
  _attach_postjob_log "check $check failed (code $code): $remedy"
  _attach_postjob_checks_add "$check" failed
  _attach_postjob_status failed "$(jq -cn --arg check "$check" --argjson code "$code" --arg remedy "$remedy" \
    '{check:$check,code:$code,remedy:$remedy}')"
}

_attach_postjob_checkout_lock() {
  attachment_checkout_lock_reclaim "$_APJ_HOME" "$_APJ_CHECKOUT" "$_APJ_COMMON" >/dev/null 2>&1 &&
    attachment_checkout_lock_acquire "$_APJ_HOME" "$_APJ_CHECKOUT" "$_APJ_COMMON" >/dev/null 2>&1 && return 0
  _attach_postjob_log 'another Trellis writer holds the checkout lock; staying pending'
  return 1
}

# The read-only checks, shared by the job and the inline pre-push run. Prints
# "pass\t<check>" per passed check and, for the first failure,
# "fail\t<check>\t<code>\t<remedy>", then returns 1.
attach_postjob_verify() {
  local home="$1" owner="$2" root="$3" release payload joined rc
  release="$(jq -r '.release' "$owner")" || { printf 'fail\trelease\t4\tthe owner record is unreadable; run trellis doctor\n'; return 1; }
  # Spec 072 D-A: a release stamped by an earlier full verify and unchanged
  # since skips release_store_locate's verify; anything else takes it, and its
  # success stamps the release for the next caller.
  if payload="$(TRELLIS_HOME="$home" release_store_release_path "$release" 2>/dev/null)" &&
     release_stamp_check "$home" "$payload"; then
    :
  else
    # rc reads the check's own status: `if ! f; then rc=$?` would read the
    # negation (always 0), so every leg below uses `||` to keep the true code.
    payload="$(TRELLIS_HOME="$home" release_store_locate "$release")" || {
      rc=$?
      printf 'fail\trelease\t%s\timmutable release %s does not verify; reinstall it (trellis release install %s), then trellis doctor --fix\n' "$rc" "$release" "$release"
      return 1
    }
    release_stamp_write "$home" "$payload" || :
  fi
  if ! jq -e --arg payload "$payload/payload" '
       ([.artifacts[] | select(.path == ".trellis/runtime" and .kind == "symlink" and .target == $payload)] | length) == 1
     ' "$owner" >/dev/null 2>&1; then
    printf 'fail\trelease\t3\tthe runtime anchor does not name the verified release payload; detach and attach %s\n' "$root"
    return 1
  fi
  printf 'pass\trelease\n'
  attachment_verify "$home" "$owner" || {
    rc=$?
    printf 'fail\towner-artifacts\t%s\tlive attachment artifacts or managed hooks differ from the owner record; restore the recorded artifacts, or detach and attach %s\n' "$rc" "$root"
    return 1
  }
  printf 'pass\towner-artifacts\n'
  attach_exclude_verify_state "$(jq -c '.exclude' "$owner")" || {
    rc=$?
    printf 'fail\texclude\t%s\tthe managed info/exclude block differs from the owner record; restore the recorded block, or detach and attach the checkout group\n' "$rc"
    return 1
  }
  printf 'pass\texclude\n'
  joined="$(jq -er 'if (.toolchain_path | type) == "array" then .toolchain_path | join(":") else empty end' "$owner" 2>/dev/null)" || joined=""
  if [ -n "$joined" ] && trellis_toolchain_control_only "$joined"; then
    printf 'fail\ttoolchain\t3\tthe recorded toolchain is the sanitized control PATH, so the push gate refuses; run trellis attach --refresh-toolchain %s\n' "$root"
    return 1
  fi
  printf 'pass\ttoolchain\n'
}

_attach_postjob_registry_consistent() {
  local registry
  registry="$(local_registry_path "$_APJ_HOME")" || return 1
  jq -e --arg checkout "$_APJ_CHECKOUT" --arg worktree "$_APJ_WORKTREE" --slurpfile record "$_APJ_OWNER" '
    $record[0] as $r
    | [.projects[]? | .checkouts[$checkout]? | select(. != null)] as $rows
    | ($rows | length) == 1
      and $rows[0].release == $r.release
      and $rows[0].worktrees[$worktree] == {root:$r.worktree_root,attachment_id:$r.attachment_id}
  ' "$registry" >/dev/null 2>&1
}

# Under the checkout lock, before the repair write and again before success:
# no journal or adoption, the owner record unchanged since the pass began, and
# the worktree and its git common dir still the same directories (device and
# inode) the pass began on. Returns 0, or the pass's exit code after recording
# the status; the caller releases the lock.
_attach_postjob_locked_recheck() {
  local blocked
  if blocked="$(attach_postjob_journal_pending "$_APJ_HOME" "$_APJ_CHECKOUT" "$_APJ_ROOT")"; then
    _attach_postjob_log "$blocked"
    _APJ_CHECKS='[]'
    _attach_postjob_status blocked-by-journal "$(jq -cn --arg remedy "$blocked" '{check:"journal",code:3,remedy:$remedy}')"
    return "$ATTACH_POSTJOB_EX_BLOCKED"
  fi
  if [ "$(_attachment_hash "$_APJ_OWNER" 2>/dev/null)" != "$_APJ_OWNER_SHA" ]; then
    _attach_postjob_log 'the owner record changed during the checks; staying pending'
    _attach_postjob_status pending
    return "$ATTACH_POSTJOB_EX_PENDING"
  fi
  if ! _attachment_identity_matches "$_APJ_ROOT" "$_APJ_ROOT_ID" directory ||
     ! _attachment_identity_matches "$_APJ_COMMON" "$_APJ_COMMON_ID" directory; then
    _attach_postjob_log 'the worktree or its git common dir was replaced during the checks; staying pending'
    _attach_postjob_status pending
    return "$ATTACH_POSTJOB_EX_PENDING"
  fi
}

# One pass. Returns 0 ok, 1 failed, 3 blocked-by-journal, 5 pending.
_attach_postjob_once() {
  local blocked verdict kind check code remedy hooks_output rc
  _APJ_CHECKS='[]'
  _APJ_ATTACHMENT="$(jq -r '.attachment_id' "$_APJ_OWNER")" || return "$ATTACH_POSTJOB_EX_PENDING"
  _APJ_OWNER_SHA="$(_attachment_hash "$_APJ_OWNER")" || return "$ATTACH_POSTJOB_EX_PENDING"
  _APJ_ROOT_ID="$(_attachment_fs_identity "$_APJ_ROOT")" || return "$ATTACH_POSTJOB_EX_PENDING"
  _APJ_COMMON_ID="$(_attachment_fs_identity "$_APJ_COMMON")" || return "$ATTACH_POSTJOB_EX_PENDING"
  if blocked="$(attach_postjob_journal_pending "$_APJ_HOME" "$_APJ_CHECKOUT" "$_APJ_ROOT")"; then
    _attach_postjob_log "$blocked"
    _attach_postjob_status blocked-by-journal "$(jq -cn --arg remedy "$blocked" '{check:"journal",code:3,remedy:$remedy}')"
    return "$ATTACH_POSTJOB_EX_BLOCKED"
  fi
  _attach_postjob_status running

  if [ -n "$(hc_hooks_path_fix_needed "$_APJ_OWNER" "$_APJ_ROOT")" ]; then
    # Test seam: a pause (never a command) between the journal read and the lock.
    if [ -n "${ATTACH_POSTJOB_TEST_LOCK_HOLD:-}" ]; then
      _attach_postjob_log 'test hold before the checkout lock'
      sleep "$ATTACH_POSTJOB_TEST_LOCK_HOLD"
    fi
    _attach_postjob_checkout_lock || { _attach_postjob_status pending; return "$ATTACH_POSTJOB_EX_PENDING"; }
    _attach_postjob_locked_recheck || { rc=$?; _attachment_checkout_lock_release >/dev/null 2>&1; return "$rc"; }
    hooks_output="$(hc_hooks_path_fix "$_APJ_HOME" "$_APJ_ROOT" "$_APJ_OWNER" false false true)"
    rc=$?
    _attachment_checkout_lock_release >/dev/null 2>&1
    _attach_postjob_log "$hooks_output"
    case "$rc" in
      0|4) ;;
      *) _attach_postjob_fail hooks-path "$rc" "$hooks_output"; return "$ATTACH_POSTJOB_EX_FAILED" ;;
    esac
  fi
  _attach_postjob_checks_add hooks-path ok

  verdict="$(attach_postjob_verify "$_APJ_HOME" "$_APJ_OWNER" "$_APJ_ROOT")"
  while IFS=$'\t' read -r kind check code remedy; do
    case "$kind" in
      pass) _attach_postjob_checks_add "$check" ok ;;
      fail) _attach_postjob_fail "$check" "$code" "$remedy"; return "$ATTACH_POSTJOB_EX_FAILED" ;;
    esac
  done <<EOF
$verdict
EOF
  # A verify that died without naming its failure is not a pass.
  [ "$(printf '%s\n' "$verdict" | grep -c '^pass')" -eq 4 ] || {
    _attach_postjob_fail verify 4 'the checks stopped without a verdict; see the job log, then trellis doctor --fix'
    return "$ATTACH_POSTJOB_EX_FAILED"
  }

  # Commit: brief, non-blocking, under the checkout lock.
  _attach_postjob_checkout_lock || { _attach_postjob_status pending; return "$ATTACH_POSTJOB_EX_PENDING"; }
  _attach_postjob_locked_recheck || { rc=$?; _attachment_checkout_lock_release >/dev/null 2>&1; return "$rc"; }
  if ! _attach_postjob_registry_consistent; then
    if (attach_reconcile_owner_registry "$_APJ_HOME" "$_APJ_OWNER" "$_APJ_IDENTITY"); then :; else
      rc=$?
      _attachment_checkout_lock_release >/dev/null 2>&1
      if [ "$rc" -eq "$TRELLIS_EX_UNAVAILABLE" ]; then
        _attach_postjob_log 'registry reconciliation is temporarily unavailable; staying pending for retry'
        _attach_postjob_status pending
        return "$ATTACH_POSTJOB_EX_PENDING"
      fi
      _attach_postjob_fail registry "$rc" 'the registry row disagrees with the owner record and the exact-owner reconcile refused; run trellis doctor and resolve that row'
      return "$ATTACH_POSTJOB_EX_FAILED"
    fi
  fi
  _attach_postjob_checks_add registry ok
  _attach_postjob_status ok
  rc=$?
  _attachment_checkout_lock_release >/dev/null 2>&1
  [ "$rc" -eq 0 ] || return "$ATTACH_POSTJOB_EX_PENDING"
  _attach_postjob_log 'every check passed'
  return 0
}

_attach_postjob_job_lock_release() {
  [ -n "${_APJ_JOB_LOCK:-}" ] || return 0
  rm -f "$_APJ_JOB_LOCK/pid"
  rmdir "$_APJ_JOB_LOCK" 2>/dev/null
  _APJ_JOB_LOCK=""
}

# One job per worktree: a mkdir lock holding "<pid> <process birth>". A holder
# whose process is gone, or whose pid now names another process, is reclaimed.
_attach_postjob_job_lock() {
  local lock="$1" pid birth recorded attempt=0
  _attachment_capture_current_pid "${lock%/*}" || return 1
  pid="$_ATTACHMENT_PROCESS_PID"
  birth="$(_attachment_process_birth "$pid")" || return 1
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if mkdir -m 700 "$lock" 2>/dev/null; then
      if ! { printf '%s %s\n' "$pid" "$birth" > "$lock/pid" && chmod 600 "$lock/pid"; }; then
        rm -f "$lock/pid"
        rmdir "$lock" 2>/dev/null
        return 1
      fi
      _APJ_JOB_LOCK="$lock"
      return 0
    fi
    [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
    recorded="$(cut -d ' ' -f 1 "$lock/pid" 2>/dev/null)" || recorded=""
    [ -n "$recorded" ] || return 3
    if kill -0 "$recorded" 2>/dev/null &&
       [ "$(_attachment_process_birth "$recorded" 2>/dev/null)" = "$(cut -d ' ' -f 2- "$lock/pid")" ]; then
      return 3
    fi
    rm -f "$lock/pid"
    rmdir "$lock" 2>/dev/null || return 3
  done
  return 3
}

# attach_postjob_run <home> <root> <sync:0|1>
attach_postjob_run() {
  local home="$1" root="$2" sync="$3" rc attempt=0 dir
  _APJ_HOME="$home"
  _APJ_IDENTITY="$(local_registry_identity_for_root "$root")" || return "$TRELLIS_EX_STATE"
  _APJ_ROOT="$(printf '%s\n' "$_APJ_IDENTITY" | jq -r '.root')"
  _APJ_CHECKOUT="$(printf '%s\n' "$_APJ_IDENTITY" | jq -r '.checkout_id')"
  _APJ_WORKTREE="$(printf '%s\n' "$_APJ_IDENTITY" | jq -r '.worktree_id')"
  _APJ_COMMON="$(printf '%s\n' "$_APJ_IDENTITY" | jq -r '.git_common_dir')"
  _APJ_OWNER="$(_attachment_ownership_path "$home" "$_APJ_CHECKOUT" "$_APJ_WORKTREE")"
  if [ ! -f "$_APJ_OWNER" ] || [ -L "$_APJ_OWNER" ]; then
    _attach_postjob_log "no attachment owner for $_APJ_ROOT; nothing to check"
    return 0
  fi
  _attach_status_prepare "$home" "$_APJ_CHECKOUT" || return "$TRELLIS_EX_UNAVAILABLE"
  dir="$home/state/attachment-status/$_APJ_CHECKOUT"
  _attach_postjob_job_lock "$dir/$_APJ_WORKTREE.job"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _attach_postjob_log 'another job for this worktree is running; leaving it to finish'
    [ "$sync" -eq 1 ] && return "$ATTACH_POSTJOB_EX_PENDING"
    return 0
  fi
  trap '_attachment_checkout_lock_release >/dev/null 2>&1; _attach_postjob_job_lock_release' EXIT
  trap '_attachment_signal_exit' HUP INT TERM
  # Private scratch: the spawning hook's TMPDIR is removed when the hook exits.
  TMPDIR="$(mktemp -d "$dir/.tmp.$_APJ_WORKTREE.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  export TMPDIR
  trap '_attachment_checkout_lock_release >/dev/null 2>&1; _attach_postjob_job_lock_release; rm -rf "$TMPDIR"' EXIT
  if [ -n "${ATTACH_POSTJOB_TEST_HOLD:-}" ]; then sleep "$ATTACH_POSTJOB_TEST_HOLD"; fi
  while :; do
    _attach_postjob_once
    rc=$?
    case "$rc" in
      0|"$ATTACH_POSTJOB_EX_FAILED") return "$rc" ;;
    esac
    attempt=$((attempt + 1))
    if [ "$sync" -eq 1 ] || [ "$attempt" -ge "$ATTACH_POSTJOB_RETRIES" ]; then
      return "$rc"
    fi
    sleep $((1 << (attempt - 1)))
  done
}

# attach_postjob_prepush <home> <root>: the managed pre-push's verdict.
attach_postjob_prepush() {
  local home="$1" root="$2" identity checkout worktree owner line class age check remedy blocked kind
  identity="$(local_registry_identity_for_root "$root")" || {
    printf 'trellis pre-push: the worktree identity could not be read for the attachment checks\n' >&2
    return 1
  }
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return 1
  worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')" || return 1
  root="$(printf '%s\n' "$identity" | jq -r '.root')" || return 1
  owner="$(_attachment_ownership_path "$home" "$checkout" "$worktree")"
  # A worktree without its own owner record has no attachment to check; the
  # gate itself still runs.
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 0
  # A live journal or adoption outranks any recorded status, ok included.
  if blocked="$(attach_postjob_journal_pending "$home" "$checkout" "$root")"; then
    printf 'trellis pre-push: attachment checks are blocked: %s\n' "$blocked" >&2
    return 1
  fi
  line="$(attach_status_classify "$home" "$owner" "$checkout" "$worktree")" || return 1
  IFS=$'\t' read -r class age check remedy <<EOF
$line
EOF
  case "$class" in
    ok) return 0 ;;
    failed)
      printf 'trellis pre-push: attachment checks FAILED at %s for this worktree; remedy: %s\n' "$check" "$remedy" >&2
      return 1
      ;;
  esac
  [ "$class" != blocked-by-journal ] || class=pending
  printf 'trellis pre-push: attachment checks are %s; running them inline\n' "$class" >&2
  line="$(attach_postjob_verify "$home" "$owner" "$root")"
  if [ "$(printf '%s\n' "$line" | grep -c '^pass')" -ne 4 ]; then
    line="$(printf '%s\n' "$line" | grep '^fail' || printf 'fail\tverify\t4\tthe checks stopped without a verdict; run trellis doctor --fix')"
    IFS=$'\t' read -r kind check age remedy <<EOF
$line
EOF
    printf 'trellis pre-push: attachment check failed at %s; remedy: %s\n' "$check" "$remedy" >&2
    return 1
  fi
  # A journal that appeared while the inline checks ran still refuses.
  if blocked="$(attach_postjob_journal_pending "$home" "$checkout" "$root")"; then
    printf 'trellis pre-push: attachment checks are blocked: %s\n' "$blocked" >&2
    return 1
  fi
}

attach_postjob_main() {
  local command="${1:-}" home_opt="" root="" sync=0 home
  [ "$#" -eq 0 ] || shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || return "$TRELLIS_EX_USAGE"; home_opt="$2"; shift 2 ;;
      --target) [ "$#" -ge 2 ] || return "$TRELLIS_EX_USAGE"; root="$2"; shift 2 ;;
      --sync) sync=1; shift ;;
      *) printf 'attach-postjob: unknown argument: %s\n' "$1" >&2; return "$TRELLIS_EX_USAGE" ;;
    esac
  done
  [ -n "$root" ] || { printf 'usage: attach-postjob.sh run|prepush --target ROOT [--home PATH] [--sync]\n' >&2; return "$TRELLIS_EX_USAGE"; }
  home="$(trellis_home_resolve "$home_opt")" || return "$?"
  case "$command" in
    run) attach_postjob_run "$home" "$root" "$sync" ;;
    prepush) attach_postjob_prepush "$home" "$root" ;;
    *) printf 'attach-postjob: unknown command: %s\n' "$command" >&2; return "$TRELLIS_EX_USAGE" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  _APJ_LIB="${_ATTACH_POSTJOB_SELF%/*}"
  # shellcheck source=trellis-home.sh
  . "$_APJ_LIB/trellis-home.sh"
  # shellcheck source=release-store.sh
  . "$_APJ_LIB/release-store.sh"
  # shellcheck source=local-registry.sh
  . "$_APJ_LIB/local-registry.sh"
  # shellcheck source=surface-plan.sh
  . "$_APJ_LIB/surface-plan.sh"
  # shellcheck source=attachment.sh
  . "$_APJ_LIB/attachment.sh"
  # shellcheck source=health-checks.sh
  . "$_APJ_LIB/health-checks.sh"
  # The libraries above are loaded; attach-project.sh must not reload them.
  # shellcheck source=../attach-project.sh
  TRELLIS_LIBS_PRELOADED=1 . "$_APJ_LIB/../attach-project.sh"
  attach_postjob_main "$@"
  exit "$?"
fi
