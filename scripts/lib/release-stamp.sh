#!/usr/bin/env bash
# Release stamp wrappers (spec 072 D-A, plan §3.1) around release_stamp.py.
#
# Public functions:
#   release_stamp_check <home> <release_dir>   0: the stamp proves the release
#                                              unchanged since a full verify
#   release_stamp_write <home> <release_dir>   0: stamped
#
# The pattern every caller follows:
#
#   if ! release_stamp_check "$home" "$release_dir"; then
#     <the existing full verify> || <refuse as today>
#     release_stamp_write "$home" "$release_dir" || :
#   fi
#
# A miss of any kind (changed, absent, unreadable, garbage, another digest,
# coarse ctime, no python3) means the full verify decides, exactly as before the stamp existed.
# A hit is exit 0 with the program's "hit" line, so an interpreter that exits 0
# without running the program (TRELLIS_PYTHON=/bin/true) is a miss too.
# check records the sweep it took before that verify, and write stamps only
# when a fresh sweep still equals it, so nothing that changed during the
# verify is stamped. A write failure only costs the next caller a full verify.
#
# A trusted shell may retain one qualified stamp proof. Reuse re-stats every
# captured release entry and directory, the stamp, and the ancestor anchors;
# it never re-enumerates the tree or runs the stamp program. The re-stat is
# one isolated lstat pass in the pinned Python interpreter (~40 ms), which
# beat the stat utility's ~1.1 s on the Mac while keeping each row's device
# and metadata in one observation; the stat sweep remains its fallback.
# Re-sourcing preserves this
# in-memory proof and a pending pre-verify token, but exported/inherited state
# never initializes either. Call check directly, not in $(...), when its memo
# or pending token must survive. No descriptor survives between shell calls:
# the stat token bridges them, with the legacy verify-then-use window.
# Bash 3.2 compatible.

_RELEASE_STAMP_PROGRAM="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/release_stamp.py"

_release_stamp_init() {
  local context
  context="$(declare -p _TRELLIS_RELEASE_STAMP_CONTEXT 2>/dev/null)" || context=""
  if [ "$context" != "declare -- _TRELLIS_RELEASE_STAMP_CONTEXT=\"$$\"" ]; then
    unset _TRELLIS_RELEASE_STAMP_MEMO _TRELLIS_RELEASE_STAMP_PENDING \
      _TRELLIS_RELEASE_STAMP_CONTEXT _TRELLIS_RELEASE_STAMP_KEY \
      _TRELLIS_RELEASE_STAMP_PATHS _TRELLIS_RELEASE_STAMP_KINDS _TRELLIS_RELEASE_STAMP_ROWS \
      _TRELLIS_RELEASE_STAMP_PENDING_HOME _TRELLIS_RELEASE_STAMP_PENDING_RELEASE \
      _TRELLIS_RELEASE_STAMP_PENDING_PROGRAM _TRELLIS_RELEASE_STAMP_PENDING_TOOLCHAIN \
      _TRELLIS_RELEASE_STAMP_PENDING_TOKEN \
      _TRELLIS_RELEASE_STAMP_SWEEP_KEYS _TRELLIS_RELEASE_STAMP_SWEEPS
    _TRELLIS_RELEASE_STAMP_CONTEXT="$$"
    _TRELLIS_RELEASE_STAMP_KEY=""
    _TRELLIS_RELEASE_STAMP_PATHS=()
    _TRELLIS_RELEASE_STAMP_KINDS=()
    _TRELLIS_RELEASE_STAMP_ROWS=()
    _TRELLIS_RELEASE_STAMP_PENDING_HOME=""
    _TRELLIS_RELEASE_STAMP_PENDING_RELEASE=""
    _TRELLIS_RELEASE_STAMP_PENDING_PROGRAM=""
    _TRELLIS_RELEASE_STAMP_PENDING_TOOLCHAIN=""
    _TRELLIS_RELEASE_STAMP_PENDING_TOKEN=""
    _TRELLIS_RELEASE_STAMP_SWEEP_KEYS=()
    _TRELLIS_RELEASE_STAMP_SWEEPS=()
  fi
  # This also makes sourcing safe under set -a. Exported values must never
  # authorize an exec'd child, even when exec preserves the shell's PID.
  export -n _TRELLIS_RELEASE_STAMP_CONTEXT _TRELLIS_RELEASE_STAMP_KEY \
    _TRELLIS_RELEASE_STAMP_PATHS _TRELLIS_RELEASE_STAMP_KINDS _TRELLIS_RELEASE_STAMP_ROWS \
    _TRELLIS_RELEASE_STAMP_PENDING_HOME _TRELLIS_RELEASE_STAMP_PENDING_RELEASE \
    _TRELLIS_RELEASE_STAMP_PENDING_PROGRAM _TRELLIS_RELEASE_STAMP_PENDING_TOOLCHAIN \
    _TRELLIS_RELEASE_STAMP_PENDING_TOKEN _TRELLIS_RELEASE_STAMP_SWEEP_KEYS _TRELLIS_RELEASE_STAMP_SWEEPS
}
_release_stamp_init

# An absolute, executable TRELLIS_PYTHON wins over a PATH lookup, so a caller
# PATH that leads with a version-manager shim costs no shim start per call.
_release_stamp_run() {
  local python_bin="${TRELLIS_PYTHON:-}"
  case "$python_bin" in /*) [ -x "$python_bin" ] || python_bin="" ;; *) python_bin="" ;; esac
  if [ -z "$python_bin" ]; then
    python_bin="$(command -v python3)" || return 1
    case "$python_bin" in /*) ;; *) return 1 ;; esac
  fi
  LC_ALL=C "$python_bin" -I "$_RELEASE_STAMP_PROGRAM" "$@" 2>/dev/null
}

# BEGIN T11 STAMP-STAT CORE — pinned verbatim in scripts/trellis-launcher.sh
# Normalise seconds and exactly nine fractional digits to integer nanoseconds.
# The caller owns the dynamically scoped _release_ns variable. Refuse extreme
# or unsupported representations instead of overflowing Bash's signed int.
_release_stamp_ns() {
  local seconds="$1" fraction="$2" digits="${1#-}"
  case "$digits" in ''|*[!0-9]*) return 1 ;; esac
  case "$fraction" in *[!0-9]*|'') return 1 ;; esac
  [ "${#fraction}" -eq 9 ] && [ "${#digits}" -le 10 ] || return 1
  [ "$seconds" -ge -9223372035 ] && [ "$seconds" -le 9223372035 ] || return 1
  _release_ns=$((seconds * 1000000000 + 10#$fraction))
}

# Check the captured list, never discover new names. Directory ctime detects
# membership changes. Ancestors outside the release are identity anchors only.
#
# The first proof is one os.lstat per row in one isolated Python process:
# device and metadata come from one observation per row, and the program
# prints each row in the record's own format, so the comparison is a single
# string test. It takes ~40 ms for a 2,364-entry release where Darwin's stat
# spends ~0.4 ms per printed %d on a device-name lookup (~1.1 s a recheck).
# The interpreter is an absolute, executable TRELLIS_PYTHON, else the
# python3 the launcher's control PATH resolves, by absolute path; never a
# PATH lookup. It runs with -I -S in a clean environment. If no interpreter
# runs the program, the stat sweep below decides, as it always did.
#
# That sweep's stat process is absolute, its environment is clean, and
# argument chunks are bounded below ARG_MAX. An unavailable or malformed stat
# is always a miss. Every row's device comes from the same stat line as its
# other fields: a parent directory's device seen by a later stat proves
# nothing about a file seen earlier, since a mount can come and go in between.
# Every call stats every entry afresh. A sweep whose stat output and captured
# lists both equal those of a sweep that passed the row comparison earlier in
# this shell has the same result; anything else is compared row by row.
_release_stamp_matches() {
  local os stat_bin argmax budget index=0 used next rows line_no count expected
  local dev ino size mt ct mode msec csec mhuman chuman _release_ns mns cns actual
  local key sweep pos slot=0 batch_no=0
  local -a batch outputs sizes
  count="${#_TRELLIS_RELEASE_STAMP_PATHS[@]}"
  [ "$count" -gt 0 ] || return 1
  if [ "${#_TRELLIS_RELEASE_STAMP_KINDS[@]}" -eq "$count" ] &&
     [ "${#_TRELLIS_RELEASE_STAMP_ROWS[@]}" -eq "$count" ] &&
     rows="$(_release_stamp_lstat_rows)"; then
    case "$rows" in
      "ok $count"$'\n'*)
        printf -v expected '%s\n' "${_TRELLIS_RELEASE_STAMP_ROWS[@]}"
        if [ "${rows#*$'\n'}"$'\n' = "$expected" ]; then return 0; fi
        return 1
        ;;
    esac
  fi
  os="$(/usr/bin/uname -s 2>/dev/null)" || return 1
  case "$os" in Darwin|Linux) ;; *) return 1 ;; esac
  if [ -x /usr/bin/stat ]; then stat_bin=/usr/bin/stat
  elif [ -x /bin/stat ]; then stat_bin=/bin/stat
  else return 1
  fi
  argmax="$(/usr/bin/getconf ARG_MAX 2>/dev/null)" || return 1
  case "$argmax" in ''|*[!0-9]*) return 1 ;; esac
  budget=$((argmax / 4))
  [ "$budget" -le 262144 ] || budget=262144
  [ "$budget" -ge 1024 ] || return 1
  while [ "$index" -lt "$count" ]; do
    batch=() used=0 pos="$index"
    while [ "$pos" -lt "$count" ]; do
      next="${_TRELLIS_RELEASE_STAMP_PATHS[$pos]}"
      # Account for bytes and argv pointers, and leave fixed-format overhead.
      used=$((used + ${#next} * 4 + 16))
      if [ "$used" -gt "$budget" ]; then
        [ "${#batch[@]}" -gt 0 ] || return 1
        break
      fi
      batch+=("$next")
      pos=$((pos + 1))
    done
    rows="$(_release_stamp_stat "$os" "$stat_bin" "${batch[@]}")" || return 1
    outputs+=("$rows")
    sizes+=("${#batch[@]}")
    index="$pos"
  done
  # %q keeps the key injective whatever the lists contain.
  printf -v key '%q\n' "$count" "${#_TRELLIS_RELEASE_STAMP_KINDS[@]}" "${#_TRELLIS_RELEASE_STAMP_ROWS[@]}" \
    "${_TRELLIS_RELEASE_STAMP_PATHS[@]}" \
    "${_TRELLIS_RELEASE_STAMP_KINDS[@]+"${_TRELLIS_RELEASE_STAMP_KINDS[@]}"}" \
    "${_TRELLIS_RELEASE_STAMP_ROWS[@]+"${_TRELLIS_RELEASE_STAMP_ROWS[@]}"}"
  printf -v sweep '%s\n' "${outputs[@]}"
  while [ "$slot" -lt "${#_TRELLIS_RELEASE_STAMP_SWEEP_KEYS[@]}" ]; do
    if [ "$key" = "${_TRELLIS_RELEASE_STAMP_SWEEP_KEYS[$slot]}" ] &&
       [ "$sweep" = "${_TRELLIS_RELEASE_STAMP_SWEEPS[$slot]-}" ]; then
      return 0
    fi
    slot=$((slot + 1))
  done
  index=0
  while [ "$batch_no" -lt "${#sizes[@]}" ]; do
    rows="${outputs[$batch_no]}"
    line_no=0
    while IFS=$'\t' read -r dev ino size mt ct mode mhuman chuman; do
      [ "$line_no" -lt "${sizes[$batch_no]}" ] || return 1
      if [ "$os" = Darwin ]; then
        msec="${mt%%.*}"; mhuman="${mt#*.}"
        csec="${ct%%.*}"; chuman="${ct#*.}"
        case "$mode" in ''|*[!0-7]*) return 1 ;; esac
        mode=$((8#$mode))
      else
        # GNU fields: seconds, human fractional mtime, seconds, human ctime.
        msec="$mt"; csec="$mode"; mode="$chuman"; chuman="$mhuman"; mhuman="$ct"
        mhuman="${mhuman#*.}"; mhuman="${mhuman%% *}"
        chuman="${chuman#*.}"; chuman="${chuman%% *}"
        case "$mode" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
        mode=$((16#$mode))
      fi
      _release_stamp_ns "$msec" "$mhuman" || return 1; mns="$_release_ns"
      _release_stamp_ns "$csec" "$chuman" || return 1; cns="$_release_ns"
      if [ "${_TRELLIS_RELEASE_STAMP_KINDS[$index]}" = A ]; then
        actual="$dev $ino $mode"
      else
        [ "$((cns % 1000000))" -ne 0 ] || return 1
        actual="$dev $ino $size $mns $cns $mode"
      fi
      [ "$actual" = "${_TRELLIS_RELEASE_STAMP_ROWS[$index]}" ] || return 1
      index=$((index + 1)); line_no=$((line_no + 1))
    done <<EOF
$rows
EOF
    [ "$line_no" -eq "${sizes[$batch_no]}" ] || return 1
    batch_no=$((batch_no + 1))
  done
  if [ "${#_TRELLIS_RELEASE_STAMP_SWEEP_KEYS[@]}" -gt 0 ]; then
    _TRELLIS_RELEASE_STAMP_SWEEP_KEYS=("$key" "${_TRELLIS_RELEASE_STAMP_SWEEP_KEYS[0]}")
    _TRELLIS_RELEASE_STAMP_SWEEPS=("$sweep" "${_TRELLIS_RELEASE_STAMP_SWEEPS[0]-}")
  else
    _TRELLIS_RELEASE_STAMP_SWEEP_KEYS=("$key")
    _TRELLIS_RELEASE_STAMP_SWEEPS=("$sweep")
  fi
  export -n _TRELLIS_RELEASE_STAMP_SWEEP_KEYS _TRELLIS_RELEASE_STAMP_SWEEPS
}

# One absolute stat process in a clean environment over one batch.
_release_stamp_stat() {
  local os="$1" stat_bin="$2"
  shift 2
  if [ "$os" = Darwin ]; then
    /usr/bin/env -i LC_ALL=C TZ=UTC0 "$stat_bin" -f $'%d\t%i\t%z\t%Fm\t%Fc\t%p' -- "$@" 2>/dev/null
  else
    /usr/bin/env -i LC_ALL=C TZ=UTC0 "$stat_bin" --printf='%d\t%i\t%s\t%Y\t%y\t%Z\t%z\t%f\n' -- "$@" 2>/dev/null
  fi
}

# The rows of the record, from one os.lstat per path: "dev ino mode" for an
# anchor (A), else "dev ino size mtime_ns ctime_ns mode", or "coarse" for a
# ctime without sub-millisecond digits. Kinds then paths arrive NUL-separated
# on stdin; a header names the count. Quote-free so it can sit in quotes.
# The double quotes are Python source, passed only as one quoted -c argument.
# shellcheck disable=SC2089
_RELEASE_STAMP_LSTAT_PROGRAM='import os, sys
n = int(sys.argv[1])
fields = sys.stdin.buffer.read().split(b"\0")
if n <= 0 or len(fields) != 2 * n + 1 or fields[-1]:
    sys.exit(2)
out = ["ok %d" % n]
for kind, path in zip(fields[:n], fields[n:2 * n]):
    s = os.lstat(path)
    if kind == b"A":
        out.append("%d %d %d" % (s.st_dev, s.st_ino, s.st_mode))
    elif s.st_ctime_ns % 1000000:
        out.append("%d %d %d %d %d %d" % (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode))
    else:
        out.append("coarse")
sys.stdout.write("\n".join(out) + "\n")
'
# shellcheck disable=SC2090
export -n _RELEASE_STAMP_LSTAT_PROGRAM

_release_stamp_lstat_rows() {
  local python_bin="${TRELLIS_PYTHON:-}"
  case "$python_bin" in /*) [ -x "$python_bin" ] || python_bin="" ;; *) python_bin="" ;; esac
  if [ -z "$python_bin" ]; then
    if [ -x /usr/bin/python3 ]; then python_bin=/usr/bin/python3
    elif [ -x /bin/python3 ]; then python_bin=/bin/python3
    else return 1
    fi
  fi
  printf '%s\0' "${_TRELLIS_RELEASE_STAMP_KINDS[@]}" "${_TRELLIS_RELEASE_STAMP_PATHS[@]}" |
    /usr/bin/env -i LC_ALL=C "$python_bin" -I -S -c "$_RELEASE_STAMP_LSTAT_PROGRAM" \
      "${#_TRELLIS_RELEASE_STAMP_PATHS[@]}" 2>/dev/null
}

# Populate only from the result of a successful, fine-ctime-qualified check.
# This only records the lists; nothing may rely on them until
# _release_stamp_matches has compared them with a fresh stat sweep.
_release_stamp_capture() {
  local output="$1" header body count kind path dev ino size mt ct mode n=0
  local -a paths kinds recorded
  paths=(); kinds=(); recorded=()
  header="${output%%$'\n'*}"
  case "$header" in $'hit\t'*) count="${header#*$'\t'}" ;; *) return 1 ;; esac
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$count" -gt 0 ] && [ "$count" -le 1000000 ] || return 1
  # Bash 3.2 does not interpret $'\n' inside this here-doc expansion.
  body="${output#*$'\n'}"
  while IFS=$'\t' read -r kind path dev ino size mt ct mode; do
    case "$kind" in E|A) ;; *) return 1 ;; esac
    case "$path" in /*) ;; *) return 1 ;; esac
    case "$dev:$ino:$size:$mt:$ct:$mode" in *[!0-9:-]*) return 1 ;; esac
    paths+=("$path")
    kinds+=("$kind")
    if [ "$kind" = A ]; then
      recorded+=("$dev $ino $mode")
    else
      recorded+=("$dev $ino $size $mt $ct $mode")
    fi
    n=$((n + 1))
  done <<EOF
$body
EOF
  [ "$n" -eq "$count" ] || return 1
  _TRELLIS_RELEASE_STAMP_PATHS=("${paths[@]}")
  _TRELLIS_RELEASE_STAMP_KINDS=("${kinds[@]}")
  _TRELLIS_RELEASE_STAMP_ROWS=("${recorded[@]}")
  export -n _TRELLIS_RELEASE_STAMP_PATHS _TRELLIS_RELEASE_STAMP_KINDS _TRELLIS_RELEASE_STAMP_ROWS
}
# END T11 STAMP-STAT CORE

# Keys containing delimiters are never reusable: do not let one spelling of
# a home, release, program or toolchain collide with another.
_release_stamp_key() {
  _release_key=""
  case "$1$2$_RELEASE_STAMP_PROGRAM${TRELLIS_PYTHON:-}${PATH:-}" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  _release_key="$1"$'\t'"$2"$'\t'"$_RELEASE_STAMP_PROGRAM"$'\t'"${TRELLIS_PYTHON:-}"$'\t'"${PATH:-}"
}

release_stamp_check() {
  local home="${1:-}" release="${2:-}" key="" _release_key="" output=""
  _release_stamp_init
  _TRELLIS_RELEASE_STAMP_PENDING_TOKEN=""
  export -n _TRELLIS_RELEASE_STAMP_PENDING_TOKEN
  if _release_stamp_key "$home" "$release"; then key="$_release_key"; fi
  if [ -n "$key" ] && [ "$key" = "$_TRELLIS_RELEASE_STAMP_KEY" ] && _release_stamp_matches; then
    return 0
  fi
  _TRELLIS_RELEASE_STAMP_KEY=""
  export -n _TRELLIS_RELEASE_STAMP_KEY
  if output="$(_release_stamp_run check-memo "$home" "$release")"; then
    case "$output" in
      hit) return 0 ;;
      $'hit\t'*)
        # Python's hit is the verdict. The lists are bound by the first
        # _release_stamp_matches that reuses them, so a check nothing reuses
        # costs no stat sweep.
        if _release_stamp_capture "$output"; then
          _TRELLIS_RELEASE_STAMP_KEY="$key"
          export -n _TRELLIS_RELEASE_STAMP_KEY
          return 0
        fi
        # The memo lines were malformed.
        output="$(_release_stamp_run check "$home" "$release")" && [ "$output" = hit ] && return 0
        ;;
    esac
  fi
  _TRELLIS_RELEASE_STAMP_PENDING_HOME="$home"
  _TRELLIS_RELEASE_STAMP_PENDING_RELEASE="$release"
  _TRELLIS_RELEASE_STAMP_PENDING_PROGRAM="$_RELEASE_STAMP_PROGRAM"
  _TRELLIS_RELEASE_STAMP_PENDING_TOOLCHAIN="${TRELLIS_PYTHON:-}"$'\t'"${PATH:-}"
  _TRELLIS_RELEASE_STAMP_PENDING_TOKEN="$output"
  export -n _TRELLIS_RELEASE_STAMP_PENDING_HOME _TRELLIS_RELEASE_STAMP_PENDING_RELEASE \
    _TRELLIS_RELEASE_STAMP_PENDING_PROGRAM _TRELLIS_RELEASE_STAMP_PENDING_TOOLCHAIN \
    _TRELLIS_RELEASE_STAMP_PENDING_TOKEN
  return 1
}

release_stamp_write() {
  local home="${1:-}" release="${2:-}" token output key="" _release_key=""
  local pending_home pending_release pending_program pending_toolchain
  _release_stamp_init
  pending_home="$_TRELLIS_RELEASE_STAMP_PENDING_HOME"
  pending_release="$_TRELLIS_RELEASE_STAMP_PENDING_RELEASE"
  pending_program="$_TRELLIS_RELEASE_STAMP_PENDING_PROGRAM"
  pending_toolchain="$_TRELLIS_RELEASE_STAMP_PENDING_TOOLCHAIN"
  token="$_TRELLIS_RELEASE_STAMP_PENDING_TOKEN"
  _TRELLIS_RELEASE_STAMP_PENDING_TOKEN=""
  export -n _TRELLIS_RELEASE_STAMP_PENDING_TOKEN
  [ "$pending_home" = "$home" ] && [ "$pending_release" = "$release" ] &&
    [ "$pending_program" = "$_RELEASE_STAMP_PROGRAM" ] &&
    [ "$pending_toolchain" = "${TRELLIS_PYTHON:-}"$'\t'"${PATH:-}" ] || return 1
  output="$(_release_stamp_run write-memo "$home" "$release" "$token")" || return 1
  if _release_stamp_key "$home" "$release"; then key="$_release_key"; fi
  if [ -n "$key" ] && _release_stamp_capture "$output"; then
    _TRELLIS_RELEASE_STAMP_KEY="$key"
    export -n _TRELLIS_RELEASE_STAMP_KEY
  fi
  return 0
}
