#!/usr/bin/env bash
# Trellis machine-home primitives.
#
# Bash 3.2 compatible. This file is meant to be sourced by local setup,
# registry, release, and attachment commands.
#
# Exit classes shared by portable fleet commands:
#   0  success
#   2  bad arguments
#   3  ownership or identity conflict
#   4  invalid or corrupt local state
#   5  unavailable path, remote, or required local capability

TRELLIS_EX_USAGE=2
TRELLIS_EX_CONFLICT=3
TRELLIS_EX_STATE=4
TRELLIS_EX_UNAVAILABLE=5

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _TRELLIS_HOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _TRELLIS_HOME_LIB_DIR=""
fi
_TRELLIS_HOME_LOCK_DIR=""
TRELLIS_HOME_LAUNCHER_ACTION=""

trellis_home_die() {
  local code
  code="$1"
  shift
  printf 'trellis: %s\n' "$*" >&2
  exit "$code"
}

trellis_home_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "trellis: jq is required for local Trellis configuration" >&2
    printf '%s\n' "  macOS:  brew install jq" >&2
    printf '%s\n' "  Debian: apt-get install jq" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
}

trellis_home_has_unsafe_chars() {
  local LC_ALL=C value
  value="$1"
  case "$value" in
    *[$'\001'-$'\037'$'\177']*|*$'\302'[$'\200'-$'\237']*) return 0 ;;
    *) return 1 ;;
  esac
}

trellis_home_require_safe_text() {
  local label value
  label="$1"
  value="$2"
  if [ -z "$value" ]; then
    printf 'trellis: %s is required\n' "$label" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  if trellis_home_has_unsafe_chars "$value"; then
    printf 'trellis: %s contains terminal control characters, which Trellis state forbids\n' "$label" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_require_absolute_safe_path() {
  local label path normalized
  label="$1"
  path="$2"
  trellis_home_require_safe_text "$label" "$path" || return "$?"
  case "$path" in
    /*) ;;
    *)
      printf 'trellis: %s must be an absolute path: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  case "$path" in
    //*)
      printf 'trellis: %s must not use an ambiguous double-slash path: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  case "$path/" in
    */./*|*/../*)
      printf 'trellis: %s must not contain . or .. path components: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  normalized="$path"
  while [ "${normalized%/}" != "$normalized" ]; do
    normalized="${normalized%/}"
  done
  if [ -z "$normalized" ]; then
    printf 'trellis: %s must not be the filesystem root: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_is_valid_fleet_name() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$'
}

trellis_home_require_fleet_name() {
  local name
  name="$1"
  if ! trellis_home_is_valid_fleet_name "$name"; then
    printf 'trellis: invalid fleet name %s; expected ^[a-z0-9][a-z0-9._-]{0,63}$\n' "$name" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_is_valid_lock_name() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$'
}

trellis_home_require_lock_name() {
  local name
  name="$1"
  if ! trellis_home_is_valid_lock_name "$name"; then
    printf 'trellis: invalid lock name %s; expected ^[a-z0-9][a-z0-9._-]{0,63}$\n' "$name" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

trellis_home_is_valid_semver() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

# NORMATIVE DEFINITION of the release-store execution-payload predicate.
#
# A stable launcher never executes the installed release directory itself: it
# seals a private snapshot of the configured release under another name and
# executes that. So a verified payload is legitimately either
#
#   HOME/releases/VERSION/payload                      (the installed release)
#   HOME/releases/.tmp.VERSION.exec.SUFFIX/payload     (its execution snapshot)
#
# and nothing else in the store. Every gate in the tree that admits a payload
# decides exactly this question, so the answer is defined once, here, and
# unit-tested here. SIX callers cannot reach this function at the moment they
# ask — five direct-source gates that run before any library may be sourced
# (scripts/show-config.sh, the scripts/upgrade.sh body, both the bootstrap and
# the body of scripts/sync-to-template.sh, and the scripts/trellis-launcher.sh
# body) plus scripts/lib/release-store.sh, which by its own file header depends
# on nothing above semver.sh — so each carries a byte-identical copy of this
# body under its own name. scripts/tests/release-snapshot-predicate.bats pins
# those six copies to this definition, so the seven can never drift apart. See
# that test's header for why a call cannot replace the copies.
#
# The version segment is matched WHOLE, never as a prefix. Release versions
# carry dots, so '.tmp.1.2.3.exec.9.exec.SUFFIX' — the snapshot of a release
# literally named '1.2.3.exec.9' — shares the entire '.tmp.1.2.3.exec.' prefix
# with a snapshot of release 1.2.3 and ends in an alphanumeric suffix of its
# own. A prefix glob plus a greedy '##*.exec.' strip accepts it under the 1.2.3
# attestation, which is the hole this shape closes: strip the delimiters
# literally (the version is quoted inside the pattern, so its own dots and any
# glob metacharacter stay literal) and require what remains to be exactly the
# opaque suffix.
#
# Pure string predicate: it touches no filesystem and reads no environment, so
# a caller must still prove the paths are real, unlinked, and canonical.
trellis_home_snapshot_payload_matches() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

trellis_home_resolve() {
  local explicit candidate
  explicit="${1:-}"
  if [ -n "$explicit" ]; then
    candidate="$explicit"
  elif [ -n "${TRELLIS_HOME:-}" ]; then
    candidate="$TRELLIS_HOME"
  else
    if [ -z "${HOME:-}" ]; then
      printf 'trellis: HOME is required when TRELLIS_HOME is not set\n' >&2
      return "$TRELLIS_EX_USAGE"
    fi
    candidate="$HOME/.trellis"
  fi
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$candidate" || return "$?"
  printf '%s\n' "$candidate"
}

# Reduce an operator-supplied home to the exact spelling the fixed launcher will
# later accept, or refuse it here. Configure is the only writer that can still
# ask; every later dispatch reads a persisted decision, so a home that merely
# passes `trellis_home_require_absolute_safe_path` (which tolerates an embedded
# `//`) but fails the launcher's stricter canonical test would strand the
# machine with a config it cannot dispatch from.
#
# Canonical here means: no repeated or trailing separators, no traversal or
# control characters, not the filesystem root, not a symlink itself, and every
# existing ancestor resolved through `pwd -P`.
trellis_home_canonical_home() {
  local path="${1:-}" suffix="" base parent real
  trellis_home_require_safe_text "TRELLIS_HOME" "$path" || return "$?"
  case "$path" in
    *//*)
      path="$(printf '%s' "$path" | tr -s '/')" || {
        printf 'trellis: could not canonicalize TRELLIS_HOME: %s\n' "$1" >&2
        return "$TRELLIS_EX_UNAVAILABLE"
      }
      ;;
  esac
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$path" || return "$?"
  if [ -L "$path" ]; then
    printf 'trellis: TRELLIS_HOME must not be a symlink: %s\n' "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  parent="$path"
  while [ "$parent" != "/" ] && [ ! -d "$parent" ]; do
    base="${parent##*/}"
    parent="${parent%/*}"
    [ -n "$parent" ] || parent="/"
    suffix="/$base$suffix"
  done
  real="$(trellis_home_real_dir "$parent")" || {
    printf 'trellis: could not canonicalize TRELLIS_HOME: %s\n' "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ "$real" != "/" ] || real=""
  path="$real$suffix"
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$path" || return "$?"
  case "$path" in
    *'//'*)
      printf 'trellis: could not canonicalize TRELLIS_HOME: %s\n' "$path" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
  printf '%s\n' "$path"
}

trellis_home_config_path() {
  printf '%s/config.json\n' "$1"
}

trellis_home_schema_path() {
  if [ "${TRELLIS_LIBS_PRELOADED:-}" = 1 ]; then
    printf '\n'
  else
    printf '%s/trellis.machine.schema.json\n' "$_TRELLIS_HOME_LIB_DIR"
  fi
}

trellis_home_prepare_private_dir() {
  local path label
  path="$1"
  label="$2"
  if [ -L "$path" ]; then
    printf 'trellis: %s must not be a symlink: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    printf 'trellis: %s must be a directory: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$path" ]; then
    (umask 077; mkdir -p "$path") || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    printf 'trellis: %s must be a real directory: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  fi
  chmod 700 "$path" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  return 0
}

trellis_home_prepare_home() {
  local home
  home="$1"
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$home" || return "$?"
  trellis_home_prepare_private_dir "$home" "TRELLIS_HOME" || return "$?"
  trellis_home_prepare_private_dir "$home/locks" "Trellis locks directory" || return "$?"
  trellis_home_prepare_private_dir "$home/state" "Trellis state directory" || return "$?"
  trellis_home_prepare_private_dir "$home/releases" "Trellis releases directory" || return "$?"
  return 0
}

trellis_home_lock_read_pid() {
  local pid_file pid
  pid_file="$1"
  if [ -L "$pid_file" ] || [ ! -f "$pid_file" ]; then
    printf 'trellis: lock is missing a regular pid record: %s\n' "$pid_file" >&2
    return "$TRELLIS_EX_STATE"
  fi
  pid="$(cat "$pid_file" 2>/dev/null)" || {
    printf 'trellis: could not read lock pid record: %s\n' "$pid_file" >&2
    return "$TRELLIS_EX_STATE"
  }
  case "$pid" in
    ''|*[!0-9]*|0*)
      printf 'trellis: lock has an invalid pid record: %s\n' "$pid_file" >&2
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  printf '%s\n' "$pid"
}

trellis_home_pid_is_live() {
  local pid
  pid="$1"
  case "$pid" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1
}

# ===========================================================================
# process birth
# ===========================================================================

# The Darwin process-birth reader, emitted as data.
#
# macOS ships `ps` setgid `kmem`, and a setgid binary does not run under the
# seatbelt profiles the Claude Code, Codex, and isolated-verification shells
# use. Every `LC_ALL=C ps -p PID -o lstart=` call site therefore went
# indeterminate inside them, which is what blocked the launcher owner-cleanup
# cases in specs/045-three-harness-parity. libproc answers the same question
# through an ordinary dynamic library, with no privilege and no sandbox
# exception, and returns the identical token.
#
# A consumer that already owns a child-process boundary — the disk-janitor
# descriptor-relative deletion sink — takes this program as an argument and
# runs it there as `python3 -I -c PROGRAM PID`. `-I` is load-bearing: it stops
# a poisoned cwd or PYTHONPATH from shadowing `ctypes` or `time`. The program
# is data from trusted in-memory release code and is never written to or read
# from the filesystem, so no call site discovers a mutable source path at
# runtime.
trellis_process_birth_python() {
  cat <<'TRELLIS_PROCESS_BIRTH_PY'
import ctypes
import sys
import time

# proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) fills `struct
# proc_bsdinfo` (<sys/proc_info.h>) and returns the number of bytes written:
#
#   uint32_t pbi_flags, pbi_status, pbi_xstatus, pbi_pid, pbi_ppid,
#            pbi_uid, pbi_gid, pbi_ruid, pbi_rgid, pbi_svuid, pbi_svgid, rfu_1;
#   char     pbi_comm[MAXCOMLEN];      /* 16 */
#   char     pbi_name[2 * MAXCOMLEN];  /* 32 */
#   uint32_t pbi_nfiles, pbi_pgid, pbi_pjobc, e_tdev, e_tpgid;
#   int32_t  pbi_nice;
#   uint64_t pbi_start_tvsec, pbi_start_tvusec;
#
# Only pbi_pid (head[3]) and pbi_start_tvsec are read; the rest is layout.
PROC_PIDTBSDINFO = 3
ESRCH = 3


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("head", ctypes.c_uint32 * 12),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("tail", ctypes.c_uint32 * 5),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


if len(sys.argv) != 2 or not sys.argv[1].isdigit():
    raise SystemExit(2)
pid = int(sys.argv[1])
# Reject a non-canonical spelling as well as an out-of-range value: the pid
# crosses into C as a signed int, and "007" is not the pid any record stored.
if str(pid) != sys.argv[1] or pid < 1 or pid > 2147483647:
    raise SystemExit(2)

try:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidinfo = libproc.proc_pidinfo
except (OSError, AttributeError):
    raise SystemExit(1)
proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.POINTER(ProcBsdInfo),
    ctypes.c_int,
]
proc_pidinfo.restype = ctypes.c_int

info = ProcBsdInfo()
ctypes.set_errno(0)
written = proc_pidinfo(
    pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info)
)
saved_errno = ctypes.get_errno()
# A short write is a failure, never a partially trusted record. ESRCH is the
# only errno that means "gone"; EPERM and an unsupported flavour are
# indeterminate and must not be reported as death.
if written != ctypes.sizeof(info):
    raise SystemExit(3 if saved_errno == ESRCH else 1)
if info.head[3] != pid:
    raise SystemExit(1)
if info.pbi_start_tvsec < 1:
    raise SystemExit(1)
try:
    token = time.strftime(
        "%a %b %e %H:%M:%S %Y", time.localtime(info.pbi_start_tvsec)
    )
except (OSError, OverflowError, ValueError):
    raise SystemExit(1)
# `ps -o lstart=` emits exactly 28 columns and a newline; anything else is not
# the schema every stored owner record was written in.
if not token or len(token) > 28:
    raise SystemExit(1)
sys.stdout.write(token.ljust(28) + "\n")
TRELLIS_PROCESS_BIRTH_PY
}

# trellis_process_birth <pid>
#
# The process-birth token for PID: `LC_ALL=C ps -p PID -o lstart=` wherever ps
# runs, and the libproc reader above on Darwin. Both emit the same 28-column
# localtime string, so the stored `process_birth` schema is unchanged and a
# record written by either reader compares equal to one read by the other.
#
# Status: 0 with the token on stdout, 2 for a malformed or out-of-range pid, 3
# when the Darwin reader reports ESRCH, 1 for every other failure. Callers must
# keep mapping EVERY nonzero status to "indeterminate": a birth read that fails
# after kill(0) reported the process live has not proved it dead and must never
# authorize cleanup.
trellis_process_birth() {
  local pid program
  pid="${1:-}"
  case "$pid" in
    ""|*[!0-9]*|0*) return 2 ;;
  esac
  [ "$pid" -le 2147483647 ] || return 2
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    command -v python3 >/dev/null 2>&1 || return 1
    program="$(trellis_process_birth_python)" || return 1
    LC_ALL=C python3 -I -c "$program" "$pid" 2>/dev/null || return "$?"
    return 0
  fi
  LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || return 1
  return 0
}


trellis_home_lock_release() {
  local lock_dir pid
  lock_dir="$_TRELLIS_HOME_LOCK_DIR"
  _TRELLIS_HOME_LOCK_DIR=""
  [ -n "$lock_dir" ] || return 0
  if [ -L "$lock_dir" ] || [ ! -d "$lock_dir" ]; then
    printf 'trellis: refusing to release an invalid lock directory: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  pid="$(trellis_home_lock_read_pid "$lock_dir/pid")" || return "$?"
  if [ "$pid" != "$$" ]; then
    printf 'trellis: refusing to release lock not owned by this process: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if ! trellis_home_lock_has_only_pid "$lock_dir"; then
    printf 'trellis: refusing to release lock with unexpected contents: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  rm -f "$lock_dir/pid" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! rmdir "$lock_dir" 2>/dev/null; then
    printf 'trellis: lock changed during release: %s\n' "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  return 0
}

trellis_home_lock_has_only_pid() {
  local lock_dir
  lock_dir="$1"
  (
    shopt -s dotglob nullglob
    set -- "$lock_dir"/*
    [ "$#" -eq 1 ] && [ "$1" = "$lock_dir/pid" ]
  )
}

trellis_home_lock_is_initializing() {
  local lock_dir pid_file pid
  lock_dir="$1"
  pid_file="$lock_dir/pid"
  if [ ! -e "$pid_file" ] && [ ! -L "$pid_file" ]; then
    return 0
  fi
  if [ -L "$pid_file" ] || [ ! -f "$pid_file" ]; then
    return 1
  fi
  pid="$(cat "$pid_file" 2>/dev/null)" || return 1
  [ -z "$pid" ]
}

trellis_home_lock_try_recover_stale() {
  local lock_dir name pid
  lock_dir="$1"
  name="$2"

  if [ -L "$lock_dir" ]; then
    printf 'trellis: refusing symlinked %s lock at %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$lock_dir" ] && [ ! -d "$lock_dir" ]; then
    printf 'trellis: refusing non-directory %s lock at %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  [ -d "$lock_dir" ] || return "$TRELLIS_EX_UNAVAILABLE"

  # mkdir(2) publishes the lock directory before its owner record. A
  # contender must wait for that short initialization window, never reclaim it.
  if trellis_home_lock_is_initializing "$lock_dir"; then
    return 1
  fi
  pid="$(trellis_home_lock_read_pid "$lock_dir/pid")" || return "$?"
  if trellis_home_pid_is_live "$pid"; then
    return 1
  fi
  if ! trellis_home_lock_has_only_pid "$lock_dir"; then
    printf 'trellis: refusing to recover stale %s lock with unexpected contents: %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi

  rm -f "$lock_dir/pid" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! rmdir "$lock_dir" 2>/dev/null; then
    printf 'trellis: stale %s lock changed during recovery: %s\n' "$name" "$lock_dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  printf 'trellis: recovered stale %s lock at %s (dead pid %s)\n' "$name" "$lock_dir" "$pid" >&2
  return 0
}

trellis_home_lock_acquire() {
  local home name timeout lock_root lock_dir elapsed pid recover_code
  home="$1"
  name="${2:-config}"
  timeout="${3:-30}"
  trellis_home_require_absolute_safe_path "TRELLIS_HOME" "$home" || return "$?"
  trellis_home_require_lock_name "$name" || return "$?"
  case "$timeout" in
    ''|*[!0-9]*)
      printf 'trellis: lock timeout must be a non-negative integer: %s\n' "$timeout" >&2
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  if [ -L "$home" ]; then
    printf 'trellis: TRELLIS_HOME must not be a symlink: %s\n' "$home" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$home" ]; then
    printf 'trellis: TRELLIS_HOME is unavailable: %s\n' "$home" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi

  lock_root="$home/locks"
  lock_dir="$lock_root/$name.lock"
  elapsed=0
  if [ -L "$lock_root" ] || { [ -e "$lock_root" ] && [ ! -d "$lock_root" ]; }; then
    printf 'trellis: refusing invalid Trellis locks directory: %s\n' "$lock_root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$lock_root" ]; then
    (umask 077; mkdir "$lock_root") || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ -L "$lock_root" ] || [ ! -d "$lock_root" ]; then
    printf 'trellis: refusing invalid Trellis locks directory: %s\n' "$lock_root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  chmod 700 "$lock_root" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"

  while :; do
    if mkdir -m 700 "$lock_dir" 2>/dev/null; then
      if ! printf '%s\n' "$$" > "$lock_dir/pid"; then
        rmdir "$lock_dir" 2>/dev/null || true
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
      if ! chmod 600 "$lock_dir/pid" 2>/dev/null; then
        rm -f "$lock_dir/pid" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
      _TRELLIS_HOME_LOCK_DIR="$lock_dir"
      return 0
    fi

    if [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
      printf 'trellis: could not create %s lock at %s\n' "$name" "$lock_dir" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if trellis_home_lock_try_recover_stale "$lock_dir" "$name"; then
      recover_code=0
    else
      recover_code="$?"
    fi
    if [ "$recover_code" -eq 0 ]; then
      continue
    fi
    if [ "$recover_code" -eq "$TRELLIS_EX_STATE" ] || [ "$recover_code" -eq "$TRELLIS_EX_UNAVAILABLE" ]; then
      return "$recover_code"
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      if trellis_home_lock_is_initializing "$lock_dir"; then
        printf 'trellis: timed out waiting for %s lock at %s (still initializing)\n' "$name" "$lock_dir" >&2
        return "$TRELLIS_EX_STATE"
      fi
      pid="$(trellis_home_lock_read_pid "$lock_dir/pid")" || return "$?"
      printf 'trellis: timed out waiting for %s lock at %s (held by pid %s)\n' "$name" "$lock_dir" "$pid" >&2
      return "$TRELLIS_EX_STATE"
    fi
    sleep 1 || return "$TRELLIS_EX_UNAVAILABLE"
    elapsed=$((elapsed + 1))
  done
}

trellis_home_real_dir() {
  local path
  path="$1"
  [ -d "$path" ] || return 1
  (cd "$path" && pwd -P)
}

trellis_home_require_source_root() {
  local path real
  path="$1"
  trellis_home_require_absolute_safe_path "source root" "$path" || return "$?"
  if [ ! -d "$path" ]; then
    printf 'trellis: source root is not a directory: %s\n' "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  real="$(trellis_home_real_dir "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
  trellis_home_require_absolute_safe_path "source root" "$real" || return "$?"
  if [ ! -f "$real/trellis.config.json" ]; then
    printf 'trellis: source root does not look like a Trellis policy checkout: %s\n' "$real" >&2
    printf 'trellis: expected trellis.config.json under the source root\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$real"
}

trellis_home_validate_config() {
  local cfg schema
  cfg="$1"
  schema="$(trellis_home_schema_path)"
  trellis_home_require_jq || return "$?"
  if [ -L "$cfg" ]; then
    printf 'trellis: machine config must not be a symlink: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -f "$cfg" ]; then
    printf 'trellis: machine config must be a regular file: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ] && [ ! -f "$schema" ]; then
    printf 'trellis: machine schema missing at %s\n' "$schema" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    printf 'trellis: config is not valid JSON object: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if ! jq -e '
    def no_machine_controls:
      type == "string" and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def absolute_safe_path:
      no_machine_controls
      and startswith("/")
      and length >= 2
      and (startswith("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def closed_object($required; $optional):
      type == "object"
      and ((keys_unsorted - ($required + $optional)) | length == 0)
      and (($required - keys_unsorted) | length == 0);
    def fleet_name:
      no_machine_controls and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def version:
      no_machine_controls and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$");
    def fleet_config:
      closed_object(["discovery_roots"]; ["shared_infra_root"])
      and (.discovery_roots | type == "array" and length >= 1)
      and ([.discovery_roots[] | absolute_safe_path] | all)
      and ((.discovery_roots | unique | length) == (.discovery_roots | length))
      and ((has("shared_infra_root") | not) or (.shared_infra_root | absolute_safe_path));

    closed_object(["schema_version", "source_root", "release_remote", "active_cli_release", "default_fleet", "fleets"]; ["$schema"])
    and ((has("$schema") | not) or (.["$schema"] | no_machine_controls and length > 0))
    and .schema_version == 1
    and (.source_root | absolute_safe_path)
    and (.release_remote | no_machine_controls and length > 0)
    and (.active_cli_release | version)
    and (.default_fleet | fleet_name)
    and (.fleets | type == "object" and length >= 1)
    and ([.fleets | keys[] | fleet_name] | all)
    and (.fleets[.default_fleet] != null)
    and ([.fleets[] |
      fleet_config
    ] | all)
  ' "$cfg" >/dev/null 2>&1; then
    printf 'trellis: machine config failed schema-aware validation: %s\n' "$cfg" >&2
    return "$TRELLIS_EX_STATE"
  fi

  chmod 600 "$cfg" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  return 0
}

trellis_home_atomic_write_json() {
  local dest src dir base tmp code
  dest="$1"
  src="$2"
  trellis_home_require_jq || return "$?"
  trellis_home_require_absolute_safe_path "machine config" "$dest" || return "$?"
  if [ -L "$dest" ]; then
    printf 'trellis: refusing to replace symlinked machine config: %s\n' "$dest" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    printf 'trellis: machine config destination must be a regular file: %s\n' "$dest" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -L "$src" ] || [ ! -f "$src" ]; then
    printf 'trellis: machine config proposal must be a regular file: %s\n' "$src" >&2
    return "$TRELLIS_EX_STATE"
  fi
  dir="$(dirname "$dest")"
  base="$(basename "$dest")"
  if [ -L "$dir" ]; then
    printf 'trellis: refusing symlinked machine config directory: %s\n' "$dir" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -d "$dir" ]; then
    printf 'trellis: machine config directory is unavailable: %s\n' "$dir" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"

  if ! jq -S . "$src" > "$tmp"; then
    rm -f "$tmp"
    printf 'trellis: refusing to write invalid JSON to %s\n' "$dest" >&2
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trellis_home_validate_config "$tmp" || {
    code="$?"
    rm -f "$tmp"
    return "$code"
  }
  mv "$tmp" "$dest" || {
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  chmod 600 "$dest" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  return 0
}

trellis_home_resolve_fleet() {
  local explicit config fleet
  explicit="${1:-}"
  config="${2:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    fleet="$explicit"
  elif [ -n "${TRELLIS_FLEET:-}" ]; then
    fleet="$TRELLIS_FLEET"
  elif [ -n "$config" ] && [ -f "$config" ]; then
    fleet="$(jq -r '.default_fleet // empty' "$config" 2>/dev/null || true)"
  else
    fleet="personal"
  fi
  trellis_home_require_fleet_name "$fleet" || return "$?"
  printf '%s\n' "$fleet"
}

trellis_home_resolve_release() {
  local explicit config source_root release
  explicit="${1:-}"
  config="${2:-}"
  source_root="${3:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    release="$explicit"
  elif [ -n "${TRELLIS_RELEASE:-}" ]; then
    release="$TRELLIS_RELEASE"
  elif [ -n "$config" ] && [ -f "$config" ]; then
    release="$(jq -r '.active_cli_release // empty' "$config" 2>/dev/null || true)"
  else
    release=""
  fi
  if [ -z "$release" ] && [ -n "$source_root" ] && [ -f "$source_root/core-rules/VERSION" ]; then
    release="$(sed -n '1p' "$source_root/core-rules/VERSION" | tr -d '[:space:]')"
  fi
  if [ -z "$release" ]; then
    printf 'trellis: active CLI release is required; pass --active-cli-release or set TRELLIS_RELEASE\n' >&2
    return "$TRELLIS_EX_USAGE"
  fi
  if ! trellis_home_is_valid_semver "$release"; then
    printf 'trellis: active CLI release is not SemVer: %s\n' "$release" >&2
    return "$TRELLIS_EX_USAGE"
  fi
  printf '%s\n' "$release"
}

trellis_home_resolve_source_root() {
  local explicit config source
  explicit="${1:-}"
  config="${2:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    source="$explicit"
  elif [ -n "${TRELLIS_SOURCE_ROOT:-}" ]; then
    source="$TRELLIS_SOURCE_ROOT"
  elif [ -n "$config" ] && [ -f "$config" ]; then
    source="$(jq -r '.source_root // empty' "$config" 2>/dev/null || true)"
  else
    source=""
  fi
  if [ -z "$source" ]; then
    printf 'trellis: source root is required; pass --source or set TRELLIS_SOURCE_ROOT\n' >&2
    return "$TRELLIS_EX_USAGE"
  fi
  trellis_home_require_source_root "$source"
}

trellis_home_default_release_remote() {
  local explicit config source_root remote
  explicit="${1:-}"
  config="${2:-}"
  source_root="${3:-}"
  if [ -n "$config" ] && { [ -f "$config" ] || [ -L "$config" ]; }; then
    trellis_home_validate_config "$config" || return "$?"
  fi
  if [ -n "$explicit" ]; then
    trellis_home_require_safe_text "release remote" "$explicit" || return "$?"
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -n "$config" ] && [ -f "$config" ]; then
    remote="$(jq -r '.release_remote // empty' "$config" 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  if [ -n "$source_root" ] && [ -f "$source_root/trellis.config.json" ]; then
    remote="$(jq -r '.template.remote // empty' "$source_root/trellis.config.json" 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      trellis_home_require_safe_text "release remote" "$remote" || return "$?"
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  if [ -n "$source_root" ] && git -C "$source_root" rev-parse --git-dir >/dev/null 2>&1; then
    remote="$(git -C "$source_root" config --get remote.origin.url 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      trellis_home_require_safe_text "release remote" "$remote" || return "$?"
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  trellis_home_require_safe_text "release remote" "$source_root" || return "$?"
  printf '%s\n' "$source_root"
}

trellis_home_parent_dir() {
  local path
  path="$1"
  dirname "$path"
}

trellis_home_publish_file_noreplace() {
  local tmp dest
  tmp="$1"
  dest="$2"

  case "$(uname -s)" in
    Darwin) ln -h "$tmp" "$dest" 2>/dev/null ;;
    *) ln -n "$tmp" "$dest" 2>/dev/null ;;
  esac
  if [ "$?" -eq 0 ]; then
    if ! rm -f "$tmp"; then
      printf 'trellis: launcher published but temporary file could not be removed: %s\n' "$tmp" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    return 0
  fi
  rm -f "$tmp"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    printf 'trellis: refusing to overwrite existing launcher: %s\n' "$dest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  printf 'trellis: could not publish launcher at %s\n' "$dest" >&2
  return "$TRELLIS_EX_UNAVAILABLE"
}

trellis_home_install_launcher() {
  local template dest dest_dir tmp
  template="$1"
  dest="$2"
  TRELLIS_HOME_LAUNCHER_ACTION=""

  trellis_home_require_absolute_safe_path "launcher template" "$template" || return "$?"
  if [ -L "$template" ] || [ ! -f "$template" ]; then
    printf 'trellis: launcher template not found: %s\n' "$template" >&2
    printf 'trellis: pass --launcher-template PATH once scripts/trellis-launcher.sh exists, or use --no-install-launcher for config-only setup\n' >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  trellis_home_require_absolute_safe_path "launcher destination" "$dest" || return "$?"

  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    printf 'trellis: refusing non-regular launcher destination: %s\n' "$dest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -f "$dest" ]; then
    if cmp -s "$template" "$dest"; then
      chmod 755 "$dest" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
      TRELLIS_HOME_LAUNCHER_ACTION="retained"
      return 0
    fi
    printf 'trellis: refusing to overwrite existing launcher: %s\n' "$dest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi

  dest_dir="$(dirname "$dest")"
  if [ -L "$dest_dir" ]; then
    printf 'trellis: refusing symlinked launcher directory: %s\n' "$dest_dir" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -e "$dest_dir" ] && [ ! -d "$dest_dir" ]; then
    printf 'trellis: launcher directory is not a directory: %s\n' "$dest_dir" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ ! -d "$dest_dir" ]; then
    (umask 022; mkdir -p "$dest_dir") || return "$TRELLIS_EX_UNAVAILABLE"
    if [ -L "$dest_dir" ] || [ ! -d "$dest_dir" ]; then
      printf 'trellis: refusing invalid launcher directory: %s\n' "$dest_dir" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    chmod 755 "$dest_dir" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  tmp="$(mktemp "$dest_dir/.trellis.launcher.tmp.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! cp "$template" "$tmp"; then
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  chmod 755 "$tmp" || {
    rm -f "$tmp"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trellis_home_publish_file_noreplace "$tmp" "$dest" || return "$?"
  # shellcheck disable=SC2034  # Out-parameter: the caller reads it after this function returns.
  TRELLIS_HOME_LAUNCHER_ACTION="installed"
  return 0
}
