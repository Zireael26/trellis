#!/usr/bin/env bash
# disk-janitor-lib.sh — shared scanner and registry-owned deletion library for
# `trellis disk-janitor`.
#
# Single source of truth for "what is safe to reclaim." Sourced by
# scripts/disk-janitor.sh (the orchestrator) AFTER config-load.sh and
# sed-portable.sh, so the functions here run UNDER the orchestrator's
# `set -euo pipefail`. Like scripts/lib/health-checks.sh this file does NOT set
# its own shell options — it is a function-only library. Every function:
#
#   * takes EXPLICIT path arguments (no cwd assumptions),
#   * the PURE SCANNERS emit TSV to stdout and signal status via return code,
#   * makes its internal commands fault-tolerant (`2>/dev/null` / `|| fallback`)
#     so a failing `du`/`git`/`jq` never aborts the caller mid-run — the return
#     code is the ONLY status signal.
#
# The registry-backed deletion functions accept the complete local ownership
# identity. They never derive a project path from a fleet root and never fall
# back to a broad `rm -rf` when Git cannot prove the registered worktree.
#
_DISK_JANITOR_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=local-registry.sh
. "$_DISK_JANITOR_LIB_DIR/local-registry.sh"

# bash 3.2 compatible: no `[[ ]]`, no associative arrays, no `mapfile`, no
# `${x,,}` — `[ ]`/`case`, indexed arrays + `while read`, `tr` for case.

# ===========================================================================
# size + format
# ===========================================================================

# dj_mtime <path>
# Epoch modification time on darwin (stat -f %m) and linux (stat -c %Y).
# Echoes 0 when the path is missing or neither dialect answers. The single
# place stat-flavor differences live — every other helper reuses this.
#
# The two dialects MUST be captured separately. GNU `stat -f` is --file-system,
# so `stat -f %m PATH` treats the format as a missing operand AND still prints a
# whole filesystem block for PATH on stdout before exiting non-zero. Chained
# into one `||` list that block was emitted first and the GNU epoch second, so
# on linux this helper returned multi-line garbage that every arithmetic caller
# then read as a bogus age — the opposite of the portability the old comment
# advertised. Exit status alone is not a sufficient probe for the same reason,
# so the BSD result is shape-checked (digits only) before it is trusted.
dj_mtime() {
  local path="$1" candidate
  [ -e "$path" ] || { echo 0; return 0; }
  candidate="$(stat -f %m "$path" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-9]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c %Y "$path" 2>/dev/null)" || candidate=""
    case "$candidate" in
      ''|*[!0-9]*) candidate="" ;;
    esac
  fi
  if [ -z "$candidate" ]; then
    echo 0
  else
    printf '%s\n' "$candidate"
  fi
}

# dj_dir_bytes <path>
# Apparent size of <path> in BYTES (du reports KiB blocks → *1024). Echoes 0
# for a missing/unreadable path so the caller's accounting never breaks.
dj_dir_bytes() {
  local path="$1" kb
  [ -e "$path" ] || { echo 0; return 0; }
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  case "$kb" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$((kb * 1024))" ;;
  esac
}

# dj_human_bytes <bytes>
# Render a byte count as "12.6 GB" / "904 MB" / "1.0 KB" / "0 B". Integer math
# only (one decimal via the tenths trick); /1024 thresholds. Non-numeric input
# is treated as 0.
dj_human_bytes() {
  local bytes="$1"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  if [ "$bytes" -eq 0 ]; then
    echo "0 B"
    return 0
  fi
  if [ "$bytes" -lt 1024 ]; then
    echo "$bytes B"
    return 0
  fi
  # Walk up the units until the value is under 1024 of the next tier. We track
  # the divisor so the one-decimal rendering uses integer tenths.
  local unit divisor tenths int frac
  if [ "$bytes" -lt 1048576 ]; then
    unit="KB"; divisor=1024
  elif [ "$bytes" -lt 1073741824 ]; then
    unit="MB"; divisor=1048576
  elif [ "$bytes" -lt 1099511627776 ]; then
    unit="GB"; divisor=1073741824
  else
    unit="TB"; divisor=1099511627776
  fi
  tenths=$(( (bytes * 10) / divisor ))
  int=$(( tenths / 10 ))
  frac=$(( tenths % 10 ))
  echo "${int}.${frac} ${unit}"
}

# ===========================================================================
# scope A: build caches
# ===========================================================================

# dj_find_caches <project_path>
#
# Enumerate `.turbo/cache`, `.next/cache`, and `.next/dev` below PROJECT_PATH
# without crossing a symlink or mount boundary. `find -P` alone is insufficient:
# a Linux bind mount keeps the source device number, so it can expose external
# bytes as an apparently in-tree cache. This walker opens every directory
# descriptor-relative, compares its inode after opening, and requires the
# descriptor's kernel mount identity to match the registered root. Linux uses
# `statx(2)`'s STATX_MNT_ID; Darwin uses fstatfs's fsid + mountpoint tuple.
# If either capability is unavailable, scanning fails closed instead of guessing.
#
# Emits TSV, one row per verified cache dir:
#   <kind>\t<abs_path>\t<bytes>\t<mtime_epoch>
# kind ∈ turbo-cache | next-cache | next-dev.
dj_find_caches() {
  local proj="$1"
  [ -d "$proj" ] || return 0
  command -v python3 >/dev/null 2>&1 || {
    echo "dj_find_caches: python3 with descriptor-relative mount checks is required" >&2
    return 1
  }
  python3 - "$proj" <<'PY'
import ctypes
import os
import stat
import sys

root_path = sys.argv[1]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class MountIdentityError(Exception):
    pass


class StatxTimestamp(ctypes.Structure):
    _fields_ = [
        ("tv_sec", ctypes.c_int64),
        ("tv_nsec", ctypes.c_uint32),
        ("reserved", ctypes.c_int32),
    ]


class Statx(ctypes.Structure):
    _fields_ = [
        ("stx_mask", ctypes.c_uint32),
        ("stx_blksize", ctypes.c_uint32),
        ("stx_attributes", ctypes.c_uint64),
        ("stx_nlink", ctypes.c_uint32),
        ("stx_uid", ctypes.c_uint32),
        ("stx_gid", ctypes.c_uint32),
        ("stx_mode", ctypes.c_uint16),
        ("spare0", ctypes.c_uint16),
        ("stx_ino", ctypes.c_uint64),
        ("stx_size", ctypes.c_uint64),
        ("stx_blocks", ctypes.c_uint64),
        ("stx_attributes_mask", ctypes.c_uint64),
        ("stx_atime", StatxTimestamp),
        ("stx_btime", StatxTimestamp),
        ("stx_ctime", StatxTimestamp),
        ("stx_mtime", StatxTimestamp),
        ("stx_rdev_major", ctypes.c_uint32),
        ("stx_rdev_minor", ctypes.c_uint32),
        ("stx_dev_major", ctypes.c_uint32),
        ("stx_dev_minor", ctypes.c_uint32),
        ("stx_mnt_id", ctypes.c_uint64),
        ("stx_dio_mem_align", ctypes.c_uint32),
        ("stx_dio_offset_align", ctypes.c_uint32),
        ("spare3", ctypes.c_uint64 * 12),
    ]


class DarwinStatfs(ctypes.Structure):
    _fields_ = [
        ("f_bsize", ctypes.c_uint32),
        ("f_iosize", ctypes.c_int32),
        ("f_blocks", ctypes.c_uint64),
        ("f_bfree", ctypes.c_uint64),
        ("f_bavail", ctypes.c_uint64),
        ("f_files", ctypes.c_uint64),
        ("f_ffree", ctypes.c_uint64),
        ("f_fsid", ctypes.c_int32 * 2),
        ("f_owner", ctypes.c_uint32),
        ("f_type", ctypes.c_uint32),
        ("f_flags", ctypes.c_uint32),
        ("f_fssubtype", ctypes.c_uint32),
        ("f_fstypename", ctypes.c_char * 16),
        ("f_mntonname", ctypes.c_char * 1024),
        ("f_mntfromname", ctypes.c_char * 1024),
        ("f_flags_ext", ctypes.c_uint32),
        ("f_reserved", ctypes.c_uint32 * 7),
    ]


if not O_DIRECTORY or not O_NOFOLLOW:
    raise SystemExit("dj_find_caches: descriptor no-follow support is unavailable")

platform = sys.platform
libc = ctypes.CDLL(None, use_errno=True)
if platform.startswith("linux"):
    try:
        statx = libc.statx
    except AttributeError:
        raise SystemExit("dj_find_caches: Linux statx mount identity is unavailable")
    statx.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint,
        ctypes.POINTER(Statx),
    ]
    statx.restype = ctypes.c_int
elif platform == "darwin":
    fstatfs = libc.fstatfs
    fstatfs.argtypes = [ctypes.c_int, ctypes.POINTER(DarwinStatfs)]
    fstatfs.restype = ctypes.c_int
else:
    raise SystemExit("dj_find_caches: kernel mount identity is unsupported on this platform")


def mount_identity(fd):
    if platform.startswith("linux"):
        result = Statx()
        if statx(fd, b"", 0x1000, 0x1000, ctypes.byref(result)) != 0:
            raise MountIdentityError("statx(STATX_MNT_ID) failed: %s" % os.strerror(ctypes.get_errno()))
        if not (result.stx_mask & 0x1000):
            raise MountIdentityError("statx did not return STATX_MNT_ID")
        return ("linux", int(result.stx_mnt_id))
    result = DarwinStatfs()
    if fstatfs(fd, ctypes.byref(result)) != 0:
        raise MountIdentityError("fstatfs failed: %s" % os.strerror(ctypes.get_errno()))
    mountpoint = bytes(result.f_mntonname).split(b"\0", 1)[0]
    source = bytes(result.f_mntfromname).split(b"\0", 1)[0]
    filesystem = bytes(result.f_fstypename).split(b"\0", 1)[0]
    if not mountpoint:
        raise MountIdentityError("fstatfs returned no mountpoint")
    return (
        "darwin", int(result.f_fsid[0]), int(result.f_fsid[1]),
        filesystem, mountpoint, source,
    )


def same_stat(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def stat_child(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        return None


def open_child_directory(parent_fd, name, root_device, root_mount):
    before = stat_child(parent_fd, name)
    if before is None or not stat.S_ISDIR(before.st_mode):
        return None
    try:
        child_fd = os.open(
            name, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW, dir_fd=parent_fd
        )
    except OSError:
        return None
    actual = os.fstat(child_fd)
    try:
        mounted = mount_identity(child_fd)
    except MountIdentityError:
        os.close(child_fd)
        return None
    if not same_stat(actual, before) or actual.st_dev != root_device or mounted != root_mount:
        os.close(child_fd)
        return None
    return child_fd, actual


def allocated_bytes(value):
    return int(getattr(value, "st_blocks", 0)) * 512


def measure_tree(directory_fd, root_device, root_mount):
    own = os.fstat(directory_fd)
    try:
        if own.st_dev != root_device or mount_identity(directory_fd) != root_mount:
            return None
    except MountIdentityError:
        return None
    try:
        names = sorted(os.listdir(directory_fd))
    except OSError:
        return None
    total = allocated_bytes(own)
    for name in names:
        if name in (".", "..") or "/" in name:
            return None
        before = stat_child(directory_fd, name)
        if before is None:
            return None
        if stat.S_ISDIR(before.st_mode):
            opened = open_child_directory(directory_fd, name, root_device, root_mount)
            if opened is None:
                return None
            child_fd, child_stat = opened
            try:
                nested = measure_tree(child_fd, root_device, root_mount)
            finally:
                os.close(child_fd)
            current = stat_child(directory_fd, name)
            if nested is None or current is None or not same_stat(current, child_stat):
                return None
            total += nested
        else:
            current = stat_child(directory_fd, name)
            if current is None or not same_stat(current, before):
                return None
            total += allocated_bytes(before)
    return total


def cache_kind(parent_name, name):
    if parent_name == ".turbo" and name == "cache":
        return "turbo-cache"
    if parent_name == ".next" and name == "cache":
        return "next-cache"
    if parent_name == ".next" and name == "dev":
        return "next-dev"
    return None


def walk(directory_fd, directory_path, root_device, root_mount):
    try:
        names = sorted(os.listdir(directory_fd))
    except OSError:
        return
    parent_name = os.path.basename(directory_path)
    for name in names:
        if name in (".", "..") or "/" in name or name in (".git", "node_modules"):
            continue
        opened = open_child_directory(directory_fd, name, root_device, root_mount)
        if opened is None:
            continue
        child_fd, child_stat = opened
        child_path = os.path.join(directory_path, name)
        try:
            kind = cache_kind(parent_name, name)
            if kind is not None:
                size = measure_tree(child_fd, root_device, root_mount)
                current = stat_child(directory_fd, name)
                if size is not None and current is not None and same_stat(current, child_stat):
                    print("%s\t%s\t%d\t%d" % (kind, child_path, size, int(child_stat.st_mtime)))
            else:
                walk(child_fd, child_path, root_device, root_mount)
        finally:
            os.close(child_fd)


try:
    root_fd = os.open(root_path, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
except OSError as error:
    raise SystemExit("dj_find_caches: registered root cannot be opened without following links: %s" % error)
try:
    root_stat = os.fstat(root_fd)
    root_mount = mount_identity(root_fd)
    walk(root_fd, root_path, root_stat.st_dev, root_mount)
except MountIdentityError as error:
    raise SystemExit("dj_find_caches: %s" % error)
finally:
    os.close(root_fd)
PY
}

# dj_cache_is_stale <mtime> <ttl_days> <now_epoch>
# return 0 (stale) iff (now - mtime) > ttl_days*86400. Non-numeric inputs are
# treated as 0 so a bad mtime never reports "fresh" by accident — a 0 mtime is
# the epoch and will read as very stale, which is the safe direction for a
# report (apply has independent guards).
dj_cache_is_stale() {
  local mtime="$1" ttl_days="$2" now="$3" age threshold
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  case "$ttl_days" in ''|*[!0-9]*) ttl_days=0 ;; esac
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  age=$(( now - mtime ))
  threshold=$(( ttl_days * 86400 ))
  [ "$age" -gt "$threshold" ]
}

# ===========================================================================
# scope A guard: build active (INJECTABLE for tests)
# ===========================================================================

# dj_build_active <project_path>
# return 0 (a build IS running for this project → do NOT prune its caches),
# return 1 (no active build).
#
# Test injection: if $DJ_BUILD_ACTIVE_OVERRIDE is set, "1"→active (return 0),
# "0"→inactive (return 1). Any other value is treated as unset.
#
# The real check delegates to the shared process-table helper. That helper
# anchors identity on the executing binary and uses argv only as secondary
# project/tool context, so prompt text cannot manufacture a live build. A
# missing helper or failed/malformed process snapshot is unsafe to interpret as
# idle and therefore fails closed as active.
dj_build_active() {
  local proj="$1"
  case "${DJ_BUILD_ACTIVE_OVERRIDE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if "$_DISK_JANITOR_LIB_DIR/../check-process-liveness.sh" --build "$proj" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ===========================================================================
# scope B: worktrees
# ===========================================================================

# dj_list_worktrees <repo_path>
# Parse `git -C <repo> worktree list --porcelain` into TSV, one row per tree:
#   <wt_abs_path>\t<head_sha>\t<branch_or_detached>\t<is_main 0|1>\t<prunable 0|1>
# branch is the short name (refs/heads/foo → foo) or the literal "detached".
# is_main is 1 for the first porcelain entry (always the main checkout) and is
# corroborated by comparing the worktree's --git-common-dir to its --git-dir,
# both canonicalized, so a relative/absolute mismatch can't misclassify.
dj_list_worktrees() {
  local repo="$1"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local porcelain rc
  if porcelain="$(git -C "$repo" worktree list --porcelain 2>/dev/null)"; then :; else
    rc=$?
    return "$rc"
  fi
  [ -n "$porcelain" ] || return 0

  local wt="" head="" branch="" prunable=0 first=1 line
  # A trailing newline-only delimiter flushes the final block.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt="${line#worktree }"
        head=""
        branch="detached"
        prunable=0
        ;;
      "HEAD "*)
        head="${line#HEAD }"
        ;;
      "branch "*)
        branch="${line#branch }"
        branch="${branch#refs/heads/}"
        ;;
      "detached")
        branch="detached"
        ;;
      "prunable "*|"prunable")
        prunable=1
        ;;
      "")
        # Blank line terminates a block → emit it.
        if [ -n "$wt" ]; then
          dj__emit_worktree "$repo" "$wt" "$head" "$branch" "$first" "$prunable"
          first=0
          wt=""
        fi
        ;;
    esac
  done <<EOF
$porcelain
EOF
  # Flush a final block with no trailing blank line.
  if [ -n "$wt" ]; then
    dj__emit_worktree "$repo" "$wt" "$head" "$branch" "$first" "$prunable"
  fi
}

# dj__emit_worktree <repo> <wt> <head> <branch> <is_first> <prunable>
# Internal: compute is_main and print one TSV row for dj_list_worktrees.
dj__emit_worktree() {
  local repo="$1" wt="$2" head="$3" branch="$4" is_first="$5" prunable="$6"
  local is_main=0
  if [ "$is_first" = "1" ]; then
    is_main=1
  else
    # Corroborate: a main checkout has --git-common-dir == --git-dir.
    local common gd
    common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null || echo '')"
    gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || echo '')"
    common="$(dj__abspath "$common")"
    gd="$(dj__abspath "$gd")"
    if [ -n "$common" ] && [ "$common" = "$gd" ]; then
      is_main=1
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$wt" "$head" "$branch" "$is_main" "$prunable"
}

# Best-effort canonical absolute path (cd+pwd -P for dirs; resolve a file's
# parent). Empty input → empty output. Used for Git identity and containment
# comparisons.
dj__abspath() {
  local p="$1"
  [ -n "$p" ] || { printf ''; return 0; }
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
  else
    local dir base
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    if [ -d "$dir" ]; then
      local rdir
      rdir="$( cd "$dir" 2>/dev/null && pwd -P )" || rdir="$dir"
      printf '%s/%s' "$rdir" "$base"
    else
      printf '%s' "$p"
    fi
  fi
}

# dj_worktree_mtime <wt_path>
# Epoch of the worktree's last commit (git log -1 --format=%ct). Falls back to
# the mtime of .git/logs/HEAD, then 0.
dj_worktree_mtime() {
  local wt="$1" ct
  ct="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo '')"
  case "$ct" in
    ''|*[!0-9]*) ;;
    *) echo "$ct"; return 0 ;;
  esac
  # Fallback: the reflog head's mtime. .git may be a file (linked worktree) so
  # resolve the actual git dir.
  local gd
  gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || echo '')"
  if [ -n "$gd" ] && [ -f "$gd/logs/HEAD" ]; then
    dj_mtime "$gd/logs/HEAD"
    return 0
  fi
  echo 0
}

# dj_worktree_clean <wt_path>
#
# Return 0 only when `git status --porcelain --ignored` is empty. A linked
# worktree removal destroys ignored files too, and an ignored path's basename is
# never adequate proof that its contents are disposable: a credential, database,
# or operator state can share any seemingly-artifact name. Auto-reap therefore
# refuses every ignored, untracked, staged, and unstaged entry; cleanup of a
# tree carrying any residual local state stays an explicit operator action.
dj_worktree_clean() {
  local wt="$1" status
  status="$(git -C "$wt" status --porcelain --ignored 2>/dev/null || echo 'ERR')"
  [ -z "$status" ]
}

# dj_worktree_porcelain_clean <wt_path>
#
# Return 0 only when tracked and ordinary untracked changes are absent. The
# orchestrator uses this narrower predicate solely to distinguish untracked
# work from ignored local content; every automatic reap still requires
# dj_worktree_clean's no-local-content predicate immediately afterward.
dj_worktree_porcelain_clean() {
  local wt="$1" status
  status="$(git -C "$wt" status --porcelain 2>/dev/null || echo 'ERR')"
  [ -z "$status" ]
}


# dj_capture_lsof_snapshot <snapshot_path> [timeout_seconds]
# Capture one host-wide lsof field snapshot for all worktree liveness checks in a
# scan. A single snapshot is materially faster than recursively walking every
# worktree with `lsof +D` (and still sees BOTH cwd records and open files below a
# worktree because every `n<absolute-path>` record is present). The first line is
# a status marker consumed by dj_worktree_in_use:
#   ok
#   error<TAB><fail-safe reason>
#
# macOS has neither timeout(1) nor gtimeout(1) by default, so Perl's alarm wraps
# the exec without adding a platform dependency. Missing lsof/perl, a non-zero
# lsof exit, or the alarm all write an error marker and return non-zero. Callers
# MUST still pass the marker to dj_worktree_in_use: a broken safety probe blocks
# reaping rather than opening the gate.
dj_capture_lsof_snapshot() {
  local snapshot="$1" timeout_seconds="${2:-5}" tmp rc reason
  case "$timeout_seconds" in
    ''|*[!0-9]*|0) timeout_seconds=5 ;;
  esac

  # Never leave a prior successful snapshot behind when a refresh fails: the
  # caller would otherwise mistake stale liveness data for a fresh safe result.
  rm -f "$snapshot" || return 1

  if ! command -v lsof >/dev/null 2>&1; then
    printf 'error\tlsof unavailable\n' >"$snapshot" || rm -f "$snapshot"
    return 1
  fi
  if ! command -v perl >/dev/null 2>&1; then
    printf 'error\tlsof timeout wrapper unavailable\n' >"$snapshot" || rm -f "$snapshot"
    return 1
  fi

  tmp="${snapshot}.capture.$$"
  rm -f "$tmp"
  rc=0
  perl -e 'alarm shift; exec @ARGV' "$timeout_seconds" \
    lsof -n -P -Fn >"$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$tmp" ]; then
    rc=65
  fi

  if [ "$rc" -eq 0 ]; then
    if {
      printf 'ok\n'
      cat "$tmp"
    } >"$snapshot"; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp" "$snapshot"
    return 1
  fi

  case "$rc" in
    65) reason="lsof returned an empty snapshot" ;;
    142) reason="lsof timed out after ${timeout_seconds}s" ;;
    *) reason="lsof failed (exit $rc)" ;;
  esac
  if ! printf 'error\t%s\n' "$reason" >"$snapshot"; then
    rm -f "$snapshot"
  fi
  rm -f "$tmp"
  return 1
}

# dj_worktree_in_use <wt_path> <lsof_snapshot>
# return 0 iff reaping must be blocked, and print the reason on stdout. This is
# deliberately fail-safe: a missing/malformed/error snapshot returns 0 exactly
# like a positive liveness hit. return 1 is the ONLY "no live use observed"
# result.
#
# The host-wide `lsof -Fn` snapshot contains records such as:
#   fcwd            + n/path       (a process cwd)
#   f12             + n/path/file  (an open file descriptor)
# Matching the canonical worktree path exactly or as a slash-delimited prefix
# catches a cwd anywhere inside the tree and any open handle below it. Linux may
# append ` (deleted)` after a directory has been unlinked, which remains a live
# handle and must close the gate too. Fixed-string grep keeps ~35 checks cheap
# even when the snapshot contains many thousands of open-file records.
dj_worktree_in_use() {
  local wt="$1" snapshot="$2" real_wt header reason grep_rc matches line open_path
  real_wt="$(dj__abspath "$wt")"

  if [ -z "$snapshot" ] || [ ! -r "$snapshot" ]; then
    printf 'lsof snapshot unavailable'
    return 0
  fi
  if ! IFS= read -r header <"$snapshot"; then
    printf 'lsof snapshot unreadable'
    return 0
  fi
  case "$header" in
    ok) ;;
    error$'\t'*)
      reason="${header#*$'\t'}"
      printf '%s' "${reason:-lsof check failed}"
      return 0
      ;;
    *)
      printf 'lsof snapshot invalid'
      return 0
      ;;
  esac

  [ -n "$real_wt" ] || {
    printf 'worktree path could not be resolved'
    return 0
  }

  # Pull only fixed-string candidates in one pass, then validate exact/path-prefix
  # semantics in shell so sibling names ("wt" vs "wt-old") cannot false-positive.
  # grep status 1 means no match; any other non-zero is a broken check and blocks.
  if matches="$(LC_ALL=C grep -F "n$real_wt" "$snapshot" 2>/dev/null)"; then
    while IFS= read -r line; do
      case "$line" in
        n*) open_path="${line#n}" ;;
        *) continue ;;
      esac
      case "$open_path" in
        "$real_wt"|"${real_wt} (deleted)"|"$real_wt"/*|"$real_wt"/*' (deleted)')
          printf 'live process cwd or open file handle under worktree'
          return 0
          ;;
      esac
    done <<EOF
$matches
EOF
    return 1
  else
    grep_rc=$?
  fi
  if [ "$grep_rc" -eq 1 ]; then
    return 1
  fi
  printf 'lsof snapshot search failed (exit %s)' "$grep_rc"
  return 0
}

# dj_phantom_worktree_absent_path <path>
#
# Canonicalize an ABSENT absolute path without trusting the lexical spelling.
# Unlike dj__abspath, this walks to the nearest accessible existing ancestor,
# so /tmp aliases, intermediate symlinks, and `..` components cannot make an
# outside path look ephemeral. An existing path (including a broken symlink),
# an inaccessible ancestor, or control characters are all refusals.
#
# Prints the canonical path only when the final leaf is conclusively absent.
dj_phantom_worktree_absent_path() {
  local path="${1:-}" probe="" parent="" base="" suffix="" resolved=""

  [ "$#" -eq 1 ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\n'*|*$'\t'*) return 1 ;;
  esac
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1

  probe="$path"
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    parent="$(dirname "$probe")"
    [ "$parent" != "$probe" ] || return 1
    base="$(basename "$probe")"
    suffix="/$base$suffix"
    probe="$parent"
  done
  # Requiring search permission on the first existing ancestor distinguishes an
  # inaccessible path from a missing one. A failed probe must never authorize a
  # Git metadata mutation.
  [ -d "$probe" ] && [ -x "$probe" ] || return 1
  resolved="$(CDPATH='' cd "$probe" 2>/dev/null && pwd -P)" || return 1
  printf '%s%s\n' "$resolved" "$suffix"
}

# dj_phantom_worktree_reapable <current_registered_root> <phantom_root>
#
# Return 0 only for one exact, absent, non-main, Git-prunable registration below
# the intentionally narrow ephemeral namespaces /sessions and /tmp. CURRENT is
# the registered live worktree from which Git metadata is read; its strict local
# registry identity is checked by the caller immediately before mutation.
#
# This intentionally says nothing about arbitrary missing worktree metadata:
# `git worktree prune` would sweep those broadly. The caller may remove only the
# one exact registration that this predicate re-observes.
dj_phantom_worktree_reapable() {
  local current="${1:-}" phantom="${2:-}" canonical="" worktree_rows=""
  local wt_path head_sha branch is_main prunable candidate matches=0 eligible=0

  [ "$#" -eq 2 ] || return 1
  canonical="$(dj_phantom_worktree_absent_path "$phantom")" || return 1
  [ "$canonical" = "$phantom" ] || return 1
  case "$phantom" in
    /sessions/*|/tmp/*|/private/tmp/*) ;;
    *) return 1 ;;
  esac
  if worktree_rows="$(dj_list_worktrees "$current")"; then :; else
    return 1
  fi
  while IFS="$(printf '\t')" read -r wt_path head_sha branch is_main prunable; do
    [ -n "$wt_path" ] || continue
    : "${head_sha:-}" "${branch:-}"
    candidate="$(dj_phantom_worktree_absent_path "$wt_path" 2>/dev/null)" || continue
    [ "$candidate" = "$phantom" ] || continue
    matches=$((matches + 1))
    if [ "$is_main" != "1" ] && [ "$prunable" = "1" ]; then
      eligible=$((eligible + 1))
    fi
  done <<EOF
$worktree_rows
EOF
  [ "$matches" -eq 1 ] && [ "$eligible" -eq 1 ]
}

# dj_branch_merged <repo_path> <branch>
# return 0 (merged → reapable), 1 (NOT merged), 2 (UNVERIFIED → never reaped).
#
# Test injection: if $DJ_MERGED_OVERRIDE is set, "merged"→0, "unmerged"→1,
# "unverified"→2. Any other value is treated as unset.
#
# The ONLY auto-reap signal is a MERGED pull request whose head is <branch>, in
# THIS repo, as reported by `gh`. Notes on why it is exactly this and no more:
#
#   * `gh` resolves its target repo from the working directory, so we `cd`
#     into <repo> first. A bare `gh pr list` would query whatever repo the
#     operator's cwd happens to be (a different project, or trellis-instance
#     itself) — and a branch-name collision there could falsely read as merged.
#   * We do NOT treat a deleted remote branch ("[gone]") as merged. A
#     force-pushed-away / abandoned / admin-deleted branch shows "[gone]" too
#     and is NOT merged. `gh` still sees a squash-merged PR after its branch is
#     deleted (the PR record persists), so the fleet's squash-merge workflow is
#     caught by the PR check — without the [gone] false positives. (This also
#     means report/dry-run never run `git fetch --prune`: nothing is mutated.)
#   * NEVER `git branch --merged` — the fleet squash-merges, so the tip is never
#     an ancestor of main and it would skip exactly the worktrees we want gone.
#
#   gh present, merged PR for <branch>   → 0 (merged)
#   gh present, no merged PR             → 1 (not merged — conservative; a
#                                            non-PR merge reads as not-merged,
#                                            i.e. reported but not reaped)
#   gh absent / detached HEAD            → 2 (UNVERIFIED — reported, never reaped)
dj_branch_merged() {
  local repo="$1" branch="$2"
  case "${DJ_MERGED_OVERRIDE:-}" in
    merged) return 0 ;;
    unmerged) return 1 ;;
    unverified) return 2 ;;
  esac

  # A detached / branchless worktree has nothing to verify a merge against.
  case "$branch" in
    ''|detached|HEAD) return 2 ;;
  esac

  # gh absent → we cannot authoritatively verify → UNVERIFIED (never reaped).
  command -v gh >/dev/null 2>&1 || return 2

  # Scope gh to <repo> via a subshell cd; `|| echo ''` keeps the whole
  # substitution exit-0 under the caller's `set -e`.
  local merged_prs
  merged_prs="$( cd "$repo" 2>/dev/null && gh pr list --head "$branch" --state merged --json number 2>/dev/null || echo '' )"
  case "$merged_prs" in
    ''|'[]'|'null') return 1 ;;
    *) return 0 ;;
  esac
}

# dj_worktree_pushed <wt_path>
# return 0 iff the worktree's branch has an upstream (on origin) AND the local
# tip is NOT ahead of it — i.e. every local commit is already on the remote, so
# a `git worktree remove` loses no committed work. This is the OTHER half of
# `recoverable` (merged OR pushed) and the key change from the 2026-07-16 flood:
# it catches the unmerged-but-pushed bulk (open PRs) that a merged-only gate
# skipped.
#
# Test injection: if $DJ_PUSHED_OVERRIDE is set, "pushed"→0, "unpushed"→1. Any
# other value is treated as unset. This mirrors DJ_MERGED_OVERRIDE — the real
# check reads remote-tracking state and is not exercised against a live remote.
#
#   @{u} resolves (upstream configured) AND `rev-list --count @{u}..HEAD` == 0 → 0
#   no upstream / local tip ahead of upstream / any git error                  → 1
dj_worktree_pushed() {
  local wt="$1" ahead
  case "${DJ_PUSHED_OVERRIDE:-}" in
    pushed) return 0 ;;
    unpushed) return 1 ;;
  esac
  # Upstream must be configured (the branch tracks a remote ref). Quote @{u} so
  # the shell never treats the braces as an expansion.
  git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || return 1
  # Count local commits not yet on the upstream. 0 => fully pushed (safe).
  ahead="$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '')"
  case "$ahead" in
    0) return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# scope C: package stores
# ===========================================================================

# dj_pkg_store_plan
# Echo a best-effort estimate (in bytes) of what `pnpm store prune` /
# `npm cache verify` could reclaim — REPORT ONLY, mutates nothing. We never run
# the prune itself here (only the OWNED functions delete). Estimating reclaim
# without mutating is not reliably possible across pnpm/npm versions, so this
# returns the on-disk store size as an upper bound, or 0 when nothing is found.
dj_pkg_store_plan() {
  local total=0 store

  if command -v pnpm >/dev/null 2>&1; then
    store="$(pnpm store path 2>/dev/null || echo '')"
    if [ -n "$store" ] && [ -d "$store" ]; then
      total=$(( total + $(dj_dir_bytes "$store") ))
    fi
  fi

  # npm cache: prefer the configured cache dir, else the conventional default
  # under the user home (resolved from config, never hardcoded).
  if command -v npm >/dev/null 2>&1; then
    local npm_cache
    npm_cache="$(npm config get cache 2>/dev/null || echo '')"
    case "$npm_cache" in
      ''|undefined|null) npm_cache="${USER_HOME:-$HOME}/.npm" ;;
    esac
    if [ -d "$npm_cache" ]; then
      total=$(( total + $(dj_dir_bytes "$npm_cache") ))
    fi
  fi

  echo "$total"
}

# ===========================================================================
# scope D: release execution staging (host-global)
# ===========================================================================

# dj_release_staging_name_parts <basename>
#
# Print VERSION<TAB>SUFFIX for one exact execution-snapshot basename. The
# separator is taken from the final `.exec.` delimiter, then VERSION is
# validated as a release SemVer. This is deliberately not a prefix/greedy
# suffix test: a version containing an earlier `.exec.` token remains intact,
# while a foreign-version snapshot cannot be accepted under a shorter prefix.
dj_release_staging_name_parts() {
  local name="${1:-}" rest suffix version marker
  [ "$#" -eq 1 ] || return 1
  case "$name" in
    .tmp.*.exec.*) ;;
    *) return 1 ;;
  esac
  case "$name" in
    *$'\n'*|*$'\t'*|*$'\r'*) return 1 ;;
  esac
  rest="${name#.tmp.}"
  [ "$rest" != "$name" ] || return 1
  suffix="${rest##*.exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  marker=".exec.$suffix"
  version="${rest%"$marker"}"
  [ "$version" != "$rest" ] || return 1
  trellis_home_is_valid_semver "$version" || return 1
  printf '%s\t%s\n' "$version" "$suffix"
}

# dj_release_staging_path_is_safe <releases_dir> <snapshot_path> <version>
#
# The scanner and sink both use this lexical/canonical gate. It admits one
# real direct child only; no glob, parent traversal, or symlinked directory is
# ever treated as a release snapshot.
dj_release_staging_path_is_safe() {
  local releases="${1:-}" snapshot="${2:-}" version="${3:-}"
  local releases_real snapshot_real parent base parsed parsed_version
  [ "$#" -eq 3 ] || return 1
  [ -d "$releases" ] && [ ! -L "$releases" ] || return 1
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
  releases_real="$(dj__abspath "$releases")" || return 1
  snapshot_real="$(dj__abspath "$snapshot")" || return 1
  [ "$releases_real" = "$releases" ] || return 1
  [ "$snapshot_real" = "$snapshot" ] || return 1
  parent="${snapshot%/*}"
  base="${snapshot##*/}"
  [ "$parent" = "$releases" ] || return 1
  parsed="$(dj_release_staging_name_parts "$base")" || return 1
  IFS="$(printf '\t')" read -r parsed_version _ <<EOF
$parsed
EOF
  [ "$parsed_version" = "$version" ]
}

# dj_find_release_staging <releases_dir>
#
# Emit one row per real, direct-child execution snapshot:
#   <basename>\t<version>\t<allocated_bytes>\t<mtime_epoch>\t<device>\t<inode>
#
# The descriptor-relative walker opens the releases directory and each
# candidate with O_NOFOLLOW, snapshots identities after opening, and never
# descends through a symlink. A nested symlink is counted as a leaf (and is
# therefore safe for the matching descriptor-relative remover to unlink).
dj_find_release_staging() {
  local releases="${1:-}"
  [ "$#" -eq 1 ] || return 1
  [ -d "$releases" ] && [ ! -L "$releases" ] || return 0
  [ "$(dj__abspath "$releases")" = "$releases" ] || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "dj_find_release_staging: python3 with descriptor-relative filesystem APIs is required" >&2
    return 1
  }
  python3 - "$releases" <<'PY'
import os
import re
import stat
import sys

releases = sys.argv[1]
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
if not O_DIRECTORY or not O_NOFOLLOW:
    raise SystemExit("dj_find_release_staging: descriptor no-follow support is unavailable")

version_re = re.compile(
    r"^[0-9]+\.[0-9]+\.[0-9]+"
    r"(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"
)
suffix_re = re.compile(r"^[A-Za-z0-9]+$")


def allocated_bytes(value):
    return int(getattr(value, "st_blocks", 0)) * 512


def snapshot_parts(name):
    if not name.startswith(".tmp.") or ".exec." not in name:
        return None
    rest = name[len(".tmp."):]
    separator = rest.rfind(".exec.")
    if separator <= 0:
        return None
    version = rest[:separator]
    suffix = rest[separator + len(".exec."):]
    if not suffix_re.fullmatch(suffix) or not version_re.fullmatch(version):
        return None
    return version, suffix


def lstat_at(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        return None


def measure_tree(directory_fd, root_device):
    own = os.fstat(directory_fd)
    if own.st_dev != root_device:
        return None
    try:
        names = sorted(os.listdir(directory_fd))
    except OSError:
        return None
    total = allocated_bytes(own)
    for name in names:
        if name in (".", "..") or "/" in name:
            return None
        before = lstat_at(directory_fd, name)
        if before is None:
            return None
        if stat.S_ISDIR(before.st_mode):
            if before.st_dev != root_device:
                return None
            try:
                child_fd = os.open(
                    name,
                    os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
            except OSError:
                return None
            try:
                opened = os.fstat(child_fd)
                if (
                    opened.st_dev != before.st_dev
                    or opened.st_ino != before.st_ino
                ):
                    return None
                nested = measure_tree(child_fd, root_device)
            finally:
                os.close(child_fd)
            current = lstat_at(directory_fd, name)
            if (
                nested is None
                or current is None
                or current.st_dev != before.st_dev
                or current.st_ino != before.st_ino
            ):
                return None
            total += nested
        else:
            current = lstat_at(directory_fd, name)
            if (
                current is None
                or current.st_dev != before.st_dev
                or current.st_ino != before.st_ino
            ):
                return None
            total += allocated_bytes(before)
    return total


try:
    releases_fd = os.open(releases, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
except OSError as error:
    raise SystemExit("dj_find_release_staging: releases directory cannot be opened safely: %s" % error)

try:
    releases_stat = os.fstat(releases_fd)
    if not stat.S_ISDIR(releases_stat.st_mode):
        raise SystemExit("dj_find_release_staging: releases path is not a directory")
    for name in sorted(os.listdir(releases_fd)):
        parts = snapshot_parts(name)
        if parts is None:
            continue
        before = lstat_at(releases_fd, name)
        if before is None or not stat.S_ISDIR(before.st_mode):
            continue
        try:
            snapshot_fd = os.open(
                name,
                os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
                dir_fd=releases_fd,
            )
        except OSError:
            continue
        try:
            opened = os.fstat(snapshot_fd)
            if (
                opened.st_dev != before.st_dev
                or opened.st_ino != before.st_ino
                or opened.st_dev != releases_stat.st_dev
            ):
                continue
            size = measure_tree(snapshot_fd, releases_stat.st_dev)
            current = lstat_at(releases_fd, name)
            if (
                size is None
                or current is None
                or current.st_dev != opened.st_dev
                or current.st_ino != opened.st_ino
            ):
                continue
            print(
                "%s\t%s\t%d\t%d\t%d\t%d"
                % (
                    name,
                    parts[0],
                    size,
                    int(opened.st_mtime),
                    int(opened.st_dev),
                    int(opened.st_ino),
                )
            )
        finally:
            os.close(snapshot_fd)
finally:
    os.close(releases_fd)
PY
}

# dj_release_staging_sidecar_bytes <owner_json>
# Allocated bytes for one exact regular, non-symlink owner sidecar.
dj_release_staging_sidecar_bytes() {
  local path="${1:-}" kb
  [ -f "$path" ] && [ ! -L "$path" ] || { echo 0; return 0; }
  kb="$(du -k "$path" 2>/dev/null | awk '{print $1}')" || kb=""
  case "$kb" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$((kb * 1024))" ;;
  esac
}

# dj_release_staging_owner_state <snapshot_path>
#
# Status is conveyed by the return class:
#   0 live owner (hard skip)
#   1 orphaned owner (missing, dead, or birth mismatch; deletion may proceed)
#   2 malformed/unreadable/indeterminate owner (fail closed)
#
# A valid owner record is intentionally checked with only kill(2), through
# Python so ESRCH is distinguishable from EPERM, and
# `LC_ALL=C ps -p PID -o lstart=`. We never inspect argv or any command-line
# text, so PID reuse is rejected by the birth token rather than guessed from a
# process name.
dj_release_staging_owner_state() {
  local snapshot="${1:-}" owner owner_json pid recorded_birth current_birth process_state python_bin
  [ "$#" -eq 1 ] || { printf 'owner record malformed or unreadable'; return 2; }
  owner="${snapshot}.owner.json"
  if [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    printf 'missing owner record (legacy snapshot)'
    return 1
  fi
  [ -f "$owner" ] && [ ! -L "$owner" ] && [ -r "$owner" ] || {
    printf 'owner record malformed or unreadable'
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'owner record malformed or unreadable (jq unavailable)'
    return 2
  }
  owner_json="$(<"$owner")" || {
    printf 'owner record malformed or unreadable'
    return 2
  }
  if ! jq -e '
    type == "object"
    and (keys | sort) == ["pid","process_birth","schema_version"]
    and (.schema_version | type == "number" and floor == . and . == 1)
    and (.pid | type == "number" and floor == . and . > 0)
    and (.process_birth | type == "string" and length > 0)
  ' <<<"$owner_json" >/dev/null 2>&1; then
    printf 'owner record malformed or unreadable'
    return 2
  fi
  pid="$(jq -r '.pid | tostring' <<<"$owner_json" 2>/dev/null)" || {
    printf 'owner record malformed or unreadable'
    return 2
  }
  recorded_birth="$(jq -r '.process_birth' <<<"$owner_json" 2>/dev/null)" || {
    printf 'owner record malformed or unreadable'
    return 2
  }
  # ps formatting pads lstart on some BSD/GNU combinations; normalize only
  # outer whitespace so producers and the descriptor-relative sink compare the
  # same process-birth token without touching argv or internal date spacing.
  recorded_birth="$(printf '%s\n' "$recorded_birth" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$recorded_birth" ] || {
    printf 'owner record malformed or unreadable'
    return 2
  }
  command -v ps >/dev/null 2>&1 || {
    printf 'owner liveness could not be determined (ps unavailable)'
    return 2
  }
  command -v python3 >/dev/null 2>&1 || {
    printf 'owner liveness could not be determined (python3 unavailable)'
    return 2
  }
  python_bin="$(command -v python3)" || {
    printf 'owner liveness could not be determined (python3 unavailable)'
    return 2
  }
  process_state="$("$python_bin" - "$pid" 2>/dev/null <<'PY'
import os
import sys

pid = int(sys.argv[1])
try:
    os.kill(pid, 0)
except ProcessLookupError:
    print("dead")
except (PermissionError, OSError):
    print("indeterminate")
else:
    print("live")
PY
  )" || {
    printf 'owner liveness could not be determined (pid %s)' "$pid"
    return 2
  }
  case "$process_state" in
    dead)
      printf 'owner process is dead (pid %s)' "$pid"
      return 1
      ;;
    live) ;;
    *)
      printf 'owner liveness could not be determined (pid %s)' "$pid"
      return 2
      ;;
  esac
  if ! current_birth="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)"; then
    printf 'owner liveness could not be determined (pid %s)' "$pid"
    return 2
  fi
  current_birth="$(printf '%s\n' "$current_birth" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$current_birth" ] || {
    printf 'owner liveness could not be determined (pid %s)' "$pid"
    return 2
  }
  if [ "$current_birth" = "$recorded_birth" ]; then
    printf 'owner process is live (pid %s)' "$pid"
    return 0
  fi
  printf 'owner process birth mismatch (pid %s)' "$pid"
  return 1
}

# dj_remove_release_staging_safely RELEASES_DIR SNAPSHOT VERSION TTL_DAYS
#   EXPECTED_DEVICE EXPECTED_INODE
#
# Validate and remove one exact execution snapshot through descriptors rooted
# at RELEASES_DIR. Every directory component is opened O_NOFOLLOW and pinned
# to its lstat identity. The exact adjacent owner sidecar is validated again
# (including process birth) and unlinked only after the snapshot itself has
# passed the same checks. No pathname-recursive rm is used.
dj_remove_release_staging_safely() {
  local releases="${1:-}" snapshot="${2:-}" version="${3:-}"
  local ttl_days="${4:-}" expected_device="${5:-}" expected_inode="${6:-}"
  [ "$#" -eq 6 ] || return 1
  case "$ttl_days" in ''|*[!0-9]*) return 1 ;; esac
  case "$expected_device" in ''|*[!0-9]*) return 1 ;; esac
  case "$expected_inode" in ''|*[!0-9]*) return 1 ;; esac
  dj_release_staging_path_is_safe "$releases" "$snapshot" "$version" || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "dj_remove_release_staging_safely: python3 with descriptor-relative filesystem APIs is required" >&2
    return 1
  }
  python3 - "$releases" "$snapshot" "$version" "$ttl_days" \
    "$expected_device" "$expected_inode" <<'PY'
import errno
import json
import math
import os
import re
import stat
import subprocess
import sys
import time

releases, snapshot, version = sys.argv[1:4]
ttl_days = int(sys.argv[4])
expected_identity = (int(sys.argv[5]), int(sys.argv[6]))
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
if not O_DIRECTORY or not O_NOFOLLOW:
    sys.stderr.write(
        "dj_remove_release_staging_safely: descriptor no-follow support is unavailable\n"
    )
    raise SystemExit(1)

version_re = re.compile(
    r"^[0-9]+\.[0-9]+\.[0-9]+"
    r"(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"
)
suffix_re = re.compile(r"^[A-Za-z0-9]+$")


def fail(message):
    sys.stderr.write("dj_remove_release_staging_safely: %s\n" % message)
    raise RuntimeError(message)


def identity(value):
    return value.st_dev, value.st_ino


def allocated_bytes(value):
    return int(getattr(value, "st_blocks", 0)) * 512


def lstat_at(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        fail("descriptor-relative stat failed for %s: %s" % (name, error))


def open_directory(parent_fd, name, expected=None):
    before = lstat_at(parent_fd, name)
    if not stat.S_ISDIR(before.st_mode):
        fail("release snapshot path component is not a real directory: %s" % name)
    if before.st_dev != root_device:
        fail("release snapshot path crosses a filesystem boundary: %s" % name)
    try:
        child_fd = os.open(
            name,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except OSError as error:
        fail("release snapshot path cannot be opened without following links: %s (%s)" % (name, error))
    opened = os.fstat(child_fd)
    if identity(opened) != identity(before):
        os.close(child_fd)
        fail("release snapshot path component changed during validation: %s" % name)
    if expected is not None and identity(opened) != expected:
        os.close(child_fd)
        fail("release snapshot directory identity changed")
    return child_fd, before, opened


def remove_contents(directory_fd):
    try:
        os.fchmod(directory_fd, 0o700)
    except OSError as error:
        fail("could not make release snapshot directory removable: %s" % error)
    try:
        names = os.listdir(directory_fd)
    except OSError as error:
        fail("could not enumerate release snapshot directory: %s" % error)
    reclaimed = allocated_bytes(os.fstat(directory_fd))
    for name in names:
        if name in (".", "..") or "/" in name:
            fail("unsafe release snapshot directory entry")
        before = lstat_at(directory_fd, name)
        if stat.S_ISDIR(before.st_mode):
            child_fd, _, child_stat = open_directory(directory_fd, name)
            try:
                reclaimed += remove_contents(child_fd)
                current = lstat_at(directory_fd, name)
                if identity(current) != identity(child_stat):
                    fail("release snapshot directory changed before removal: %s" % name)
                try:
                    os.rmdir(name, dir_fd=directory_fd)
                except OSError as error:
                    fail("could not remove release snapshot directory entry %s: %s" % (name, error))
            finally:
                os.close(child_fd)
        else:
            current = lstat_at(directory_fd, name)
            if identity(current) != identity(before):
                fail("release snapshot entry changed before removal: %s" % name)
            try:
                os.unlink(name, dir_fd=directory_fd)
            except OSError as error:
                fail("could not remove release snapshot entry %s: %s" % (name, error))
            reclaimed += allocated_bytes(before)
    return reclaimed


def whole_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, float) and not math.isfinite(value):
        return False
    return value == int(value)


def read_owner(root_fd, owner_name):
    try:
        before = os.stat(owner_name, dir_fd=root_fd, follow_symlinks=False)
    except OSError as error:
        if getattr(error, "errno", None) == errno.ENOENT:
            return "missing", None, 0
        fail("owner sidecar could not be inspected: %s" % error)
    if not stat.S_ISREG(before.st_mode):
        fail("owner sidecar is not a regular non-symlink file")
    try:
        owner_fd = os.open(
            owner_name,
            os.O_RDONLY | O_NOFOLLOW,
            dir_fd=root_fd,
        )
    except OSError as error:
        fail("owner sidecar cannot be opened without following links: %s" % error)
    try:
        opened = os.fstat(owner_fd)
        if identity(opened) != identity(before):
            fail("owner sidecar changed while opening")
        chunks = []
        total = 0
        while True:
            chunk = os.read(owner_fd, 1024 * 1024)

            if not chunk:
                break
            total += len(chunk)
            if total > 1024 * 1024:
                fail("owner sidecar is too large")
            chunks.append(chunk)
        after = os.stat(owner_name, dir_fd=root_fd, follow_symlinks=False)
        if identity(after) != identity(before):
            fail("owner sidecar changed while reading")
    except OSError as error:
        fail("owner sidecar could not be read: %s" % error)
    finally:
        os.close(owner_fd)
    try:
        payload = json.loads(b"".join(chunks).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        fail("owner sidecar JSON is malformed")
    if (
        not isinstance(payload, dict)
        or set(payload.keys()) != {"schema_version", "pid", "process_birth"}
        or not whole_number(payload.get("schema_version"))
        or int(payload.get("schema_version")) != 1
        or not whole_number(payload.get("pid"))
        or int(payload.get("pid")) <= 0
        or not isinstance(payload.get("process_birth"), str)
        or not payload.get("process_birth")
    ):
        fail("owner sidecar schema is malformed")
    recorded_birth = payload["process_birth"].strip(" \t\r\n")
    if not recorded_birth:
        fail("owner sidecar schema is malformed")
    pid = int(payload["pid"])
    try:
        os.kill(pid, 0)
    except OSError as error:
        if getattr(error, "errno", None) == errno.ESRCH:
            return "orphan", before, allocated_bytes(before)
        fail("owner process liveness could not be determined")
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    try:
        result = subprocess.Popen(
            ["ps", "-p", str(pid), "-o", "lstart="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        output = result.communicate()[0]
    except OSError:
        fail("owner process birth could not be read")
    if result.returncode != 0 or not output:
        fail("owner process birth could not be read")
    try:
        current_birth = output.decode("utf-8").strip(" \t\r\n")
    except UnicodeDecodeError:
        fail("owner process birth could not be read")
    if not current_birth:
        fail("owner process birth could not be read")
    if current_birth == recorded_birth:
        fail("owner process is live")
    return "orphan", before, allocated_bytes(before)


root_device = None
root_fd = None
snapshot_fd = None
try:
    if not os.path.isabs(releases) or not os.path.isabs(snapshot):
        fail("release staging paths must be absolute")
    if os.path.realpath(releases) != releases:
        fail("release staging store is not canonical")
    if os.path.dirname(snapshot) != releases:
        fail("release snapshot is not a direct child of releases")
    base = os.path.basename(snapshot)
    if not base.startswith(".tmp.") or ".exec." not in base:
        fail("release snapshot name is unsafe")
    rest = base[len(".tmp."):]
    separator = rest.rfind(".exec.")
    if separator <= 0:
        fail("release snapshot name is unsafe")
    parsed_version = rest[:separator]
    suffix = rest[separator + len(".exec."):]
    if (
        parsed_version != version
        or not version_re.fullmatch(parsed_version)
        or not suffix_re.fullmatch(suffix)
    ):
        fail("release snapshot name is unsafe")

    try:
        root_fd = os.open(
            releases,
            os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
        )
    except OSError as error:
        fail("release staging store cannot be opened safely: %s" % error)
    root_stat = os.fstat(root_fd)
    if not stat.S_ISDIR(root_stat.st_mode):
        fail("release staging store is not a directory")
    root_device = root_stat.st_dev

    before = lstat_at(root_fd, base)
    if not stat.S_ISDIR(before.st_mode):
        fail("release snapshot is not a real directory")
    if identity(before) != expected_identity:
        fail("release snapshot directory identity changed")
    snapshot_fd, _, opened = open_directory(root_fd, base, expected_identity)
    if identity(opened) != expected_identity:
        fail("release snapshot directory identity changed")
    age = time.time() - opened.st_mtime
    if age <= ttl_days * 86400:
        fail("release snapshot is no longer aged")

    owner_name = base + ".owner.json"
    owner_state, owner_identity, owner_bytes = read_owner(root_fd, owner_name)
    # Revalidate the exact target and owner immediately before recursive
    # descriptor-relative removal. A live owner is never deleted, even if it is
    # observed after the initial plan.
    current = lstat_at(root_fd, base)
    if identity(current) != expected_identity or not stat.S_ISDIR(current.st_mode):
        fail("release snapshot directory identity changed before removal")
    if time.time() - current.st_mtime <= ttl_days * 86400:
        fail("release snapshot is no longer aged")
    owner_state_again, owner_identity_again, owner_bytes_again = read_owner(
        root_fd, owner_name
    )
    if owner_state_again != owner_state:
        fail("owner sidecar state changed before removal")
    if (owner_identity is None) != (owner_identity_again is None):
        fail("owner sidecar appeared or disappeared before removal")
    if (
        owner_identity is not None
        and identity(owner_identity_again) != identity(owner_identity)
    ):
        fail("owner sidecar changed before removal")

    reclaimed = remove_contents(snapshot_fd)
    current = lstat_at(root_fd, base)
    if identity(current) != expected_identity or not stat.S_ISDIR(current.st_mode):
        fail("release snapshot directory changed before final removal")
    try:
        os.rmdir(base, dir_fd=root_fd)
    except OSError as error:
        fail("could not remove release snapshot: %s" % error)
    if owner_identity is not None:
        owner_current = lstat_at(root_fd, owner_name)
        if identity(owner_current) != identity(owner_identity):
            fail("owner sidecar changed before final removal")
        try:
            os.unlink(owner_name, dir_fd=root_fd)
        except OSError as error:
            fail("could not remove exact owner sidecar: %s" % error)
        reclaimed += owner_bytes_again
    print(str(reclaimed))
except RuntimeError:
    raise SystemExit(1)
except (AttributeError, NotImplementedError) as error:
    sys.stderr.write(
        "dj_remove_release_staging_safely: descriptor-relative cleanup is unavailable: %s\n"
        % error
    )
    raise SystemExit(1)
except OSError as error:
    sys.stderr.write(
        "dj_remove_release_staging_safely: descriptor-relative cleanup failed: %s\n"
        % error
    )
    raise SystemExit(1)
finally:
    if snapshot_fd is not None:
        try:
            os.close(snapshot_fd)
        except OSError:
            pass
    if root_fd is not None:
        try:
            os.close(root_fd)
        except OSError:
            pass
PY
}

# ===========================================================================
# recurrence pre-pass / doctor guard (shared, pure jq)
# ===========================================================================

# dj_turbo_outputs_unscoped <turbo_json_path>
# return 0 (UNSCOPED — BAD: a task writes a `.next/**`-class output without a
# `!.next/cache/**` negation, so turbo caches the dev/cache dirs → unbounded
# growth). return 1 if the file is absent, has no turbo tasks, or every
# offending output is already negated. Prints NOTHING — status via return only.
#
# NOTE the inverted convention: 0 = problem found. Supports both the modern
# `.tasks` and legacy `.pipeline` turbo schemas. Pure jq.
dj_turbo_outputs_unscoped() {
  local turbo_json="$1"
  [ -f "$turbo_json" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # For each task: does outputs[] contain a `.next/**`-class glob while LACKING
  # the `!.next/cache/**` negation? `any` over tasks → exit 0 from jq when true.
  # We feed jq's boolean back through the shell: jq prints "true"/"false".
  local verdict
  verdict="$(jq -r '
    (.tasks // .pipeline // {})
    | to_entries
    | map(.value.outputs // [])
    | any(
        . as $outs
        | (
            ($outs | any(test("(^|/)\\.next(/|$)|(^|/)\\.next/\\*\\*")))
            and
            ($outs | any(. == "!.next/cache/**") | not)
          )
      )
  ' "$turbo_json" 2>/dev/null || echo 'false')"

  [ "$verdict" = "true" ]
}

# dj_turbo_fix_hint
# THE canonical one-line fix string (single source of truth). Contains BOTH the
# !.next/cache/** and !.next/dev/** negations so authors paste a complete fix.
# Kept distinct from the detection predicate above (detection keys only on the
# absence of `!.next/cache/**`).
dj_turbo_fix_hint() {
  echo 'add cache-excluding negations to the task outputs, e.g. "outputs": [".next/**", "!.next/cache/**", "!.next/dev/**"]'
}

# ===========================================================================
# Registry-owned deletion
# ===========================================================================

# dj_registered_owner_identity HOME FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID
#   GIT_COMMON_DIR ROOT
#
# Print the freshly verified Git identity for exactly one active, available
# registry row. This is deliberately strict: state corruption, a status change,
# a disappeared volume, a changed Git common directory, a moved worktree, or a
# duplicate owner all refuse the caller before it can mutate anything.
dj_registered_owner_identity() {
  local home="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5"
  local common="$6" root="$7" root_real common_real snapshot row actual

  [ "$#" -eq 7 ] || {
    echo "dj_registered_owner_identity: expected HOME FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID GIT_COMMON_DIR ROOT" >&2
    return 1
  }
  [ -n "$home" ] && [ -n "$fleet" ] && [ -n "$project_id" ] &&
    [ -n "$checkout_id" ] && [ -n "$worktree_id" ] && [ -n "$common" ] && [ -n "$root" ] || {
    echo "dj_registered_owner_identity: incomplete registry identity refused" >&2
    return 1
  }
  [ -d "$root" ] && [ ! -L "$root" ] || {
    echo "dj_registered_owner_identity: registered worktree is unavailable or symlinked: $root" >&2
    return 1
  }
  [ -d "$common" ] && [ ! -L "$common" ] || {
    echo "dj_registered_owner_identity: registered Git common directory is unavailable or symlinked: $common" >&2
    return 1
  }
  root_real="$(dj__abspath "$root")"
  common_real="$(dj__abspath "$common")"
  [ "$root_real" = "$root" ] && [ "$common_real" = "$common" ] || {
    echo "dj_registered_owner_identity: registry identity must use canonical real paths" >&2
    return 1
  }

  if snapshot="$(local_registry_list_json "$home" "$fleet")"; then :; else
    echo "dj_registered_owner_identity: strict registry read failed" >&2
    return 1
  fi
  if row="$(printf '%s\n' "$snapshot" | jq -cer \
      --arg fleet "$fleet" --arg project_id "$project_id" \
      --arg checkout_id "$checkout_id" --arg worktree_id "$worktree_id" \
      --arg common "$common" --arg root "$root" '
        [ .entries[]
          | select(
              .kind == "worktree" and .availability == "available"
              and .status == "active"
              and .fleet == $fleet and .project_id == $project_id
              and .checkout_id == $checkout_id and .worktree_id == $worktree_id
              and .git_common_dir == $common and .root == $root
            )
        ]
        | if length == 1 then .[0] else error("registered owner is absent or ambiguous") end
      ')"; then :; else
    echo "dj_registered_owner_identity: exact active registry owner not found" >&2
    return 1
  fi
  : "$row"

  if actual="$(local_registry_identity_for_root "$root")"; then :; else
    echo "dj_registered_owner_identity: could not re-read Git worktree identity: $root" >&2
    return 1
  fi
  if ! printf '%s\n' "$actual" | jq -e \
      --arg root "$root" --arg common "$common" \
      --arg checkout_id "$checkout_id" --arg worktree_id "$worktree_id" '
        .root == $root and .git_common_dir == $common
        and .checkout_id == $checkout_id and .worktree_id == $worktree_id
      ' >/dev/null; then
    echo "dj_registered_owner_identity: live Git identity no longer matches registry ownership" >&2
    return 1
  fi
  printf '%s\n' "$actual"
}

# dj_cache_entry_owned_by_worktree ROOT CACHE
#
# Return 0 only when CACHE is a real directory below ROOT and Git still reports
# ROOT as CACHE's own worktree top level. The final check prevents a parent
# checkout scan from crossing into a nested linked worktree or submodule.
dj_cache_entry_owned_by_worktree() {
  local root="$1" target="$2" root_real target_real top

  [ "$#" -eq 2 ] || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [ -d "$target" ] && [ ! -L "$target" ] || return 1
  root_real="$(dj__abspath "$root")"
  target_real="$(dj__abspath "$target")"
  [ "$root_real" = "$root" ] || return 1
  case "$target_real/" in
    "$root_real"/*) ;;
    *) return 1 ;;
  esac
  top="$(git -C "$target_real" rev-parse --show-toplevel 2>/dev/null || echo '')"
  [ -n "$top" ] || return 1
  top="$(dj__abspath "$top")"
  [ "$top" = "$root_real" ]
}

# dj_stat_device_inode <directory>
#
# Emit a portable device:inode identity for a real directory. This snapshot is
# passed to the descriptor-relative cache remover so a namespace swap between
# the shell's ownership checks and the sink is refused rather than followed.
#
# The two dialects MUST be captured separately: GNU `stat -f` is --file-system,
# so it prints a whole filesystem block for the path on stdout before failing on
# the format operand. Chained into one substitution that block was concatenated
# with the GNU identity, and the case below then rejected the result — so on
# linux this refused every legitimate cache root instead of snapshotting it.
# Shape-check the BSD result (digits:digits) rather than trusting exit status.
dj_stat_device_inode() {
  local path="$1" identity
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  identity="$(stat -f '%d:%i' "$path" 2>/dev/null)" || identity=""
  case "$identity" in
    *[!0-9:]*|*:*:*|:*|*:|'') identity="" ;;
    *:*) ;;
    *) identity="" ;;
  esac
  if [ -z "$identity" ]; then
    identity="$(stat -c '%d:%i' "$path" 2>/dev/null)" || identity=""
  fi
  case "$identity" in
    *[!0-9:]*|*:*:*|:*|*:|'') return 1 ;;
    *:*) printf '%s\n' "$identity" ;;
    *) return 1 ;;
  esac
}

# dj_remove_cache_tree_safely ROOT TARGET
#
# Delete TARGET only through descriptors rooted at ROOT. Python's dir_fd APIs
# give this Bash library openat-style O_NOFOLLOW traversal on both macOS and
# Linux: every component is pinned, compared against its lstat identity, and
# kept on ROOT's filesystem. A symlink, replacement, or nested mount fails
# closed; no pathname-based recursive rm is used at the sink.
dj_remove_cache_tree_safely() {
  local root="$1" target="$2" root_identity target_identity
  local root_dev root_inode target_dev target_inode

  command -v python3 >/dev/null 2>&1 || {
    echo "dj_prune_cache_entry: python3 with descriptor-relative filesystem APIs is required" >&2
    return 1
  }
  root_identity="$(dj_stat_device_inode "$root")" || {
    echo "dj_prune_cache_entry: could not snapshot registered root identity" >&2
    return 1
  }
  target_identity="$(dj_stat_device_inode "$target")" || {
    echo "dj_prune_cache_entry: could not snapshot cache identity" >&2
    return 1
  }
  root_dev="${root_identity%%:*}"
  root_inode="${root_identity#*:}"
  target_dev="${target_identity%%:*}"
  target_inode="${target_identity#*:}"

  python3 - "$root" "$target" "$root_dev" "$root_inode" "$target_dev" "$target_inode" <<'PY'
import ctypes
import os
import stat
import sys

root, target = sys.argv[1:3]
expected_root = (int(sys.argv[3]), int(sys.argv[4]))
expected_target = (int(sys.argv[5]), int(sys.argv[6]))


def fail(message):
    sys.stderr.write("dj_prune_cache_entry: %s\n" % message)
    raise SystemExit(1)


class MountIdentityError(Exception):
    pass


class StatxTimestamp(ctypes.Structure):
    _fields_ = [
        ("tv_sec", ctypes.c_int64),
        ("tv_nsec", ctypes.c_uint32),
        ("reserved", ctypes.c_int32),
    ]


class Statx(ctypes.Structure):
    _fields_ = [
        ("stx_mask", ctypes.c_uint32),
        ("stx_blksize", ctypes.c_uint32),
        ("stx_attributes", ctypes.c_uint64),
        ("stx_nlink", ctypes.c_uint32),
        ("stx_uid", ctypes.c_uint32),
        ("stx_gid", ctypes.c_uint32),
        ("stx_mode", ctypes.c_uint16),
        ("spare0", ctypes.c_uint16),
        ("stx_ino", ctypes.c_uint64),
        ("stx_size", ctypes.c_uint64),
        ("stx_blocks", ctypes.c_uint64),
        ("stx_attributes_mask", ctypes.c_uint64),
        ("stx_atime", StatxTimestamp),
        ("stx_btime", StatxTimestamp),
        ("stx_ctime", StatxTimestamp),
        ("stx_mtime", StatxTimestamp),
        ("stx_rdev_major", ctypes.c_uint32),
        ("stx_rdev_minor", ctypes.c_uint32),
        ("stx_dev_major", ctypes.c_uint32),
        ("stx_dev_minor", ctypes.c_uint32),
        ("stx_mnt_id", ctypes.c_uint64),
        ("stx_dio_mem_align", ctypes.c_uint32),
        ("stx_dio_offset_align", ctypes.c_uint32),
        ("spare3", ctypes.c_uint64 * 12),
    ]


class DarwinStatfs(ctypes.Structure):
    _fields_ = [
        ("f_bsize", ctypes.c_uint32),
        ("f_iosize", ctypes.c_int32),
        ("f_blocks", ctypes.c_uint64),
        ("f_bfree", ctypes.c_uint64),
        ("f_bavail", ctypes.c_uint64),
        ("f_files", ctypes.c_uint64),
        ("f_ffree", ctypes.c_uint64),
        ("f_fsid", ctypes.c_int32 * 2),
        ("f_owner", ctypes.c_uint32),
        ("f_type", ctypes.c_uint32),
        ("f_flags", ctypes.c_uint32),
        ("f_fssubtype", ctypes.c_uint32),
        ("f_fstypename", ctypes.c_char * 16),
        ("f_mntonname", ctypes.c_char * 1024),
        ("f_mntfromname", ctypes.c_char * 1024),
        ("f_flags_ext", ctypes.c_uint32),
        ("f_reserved", ctypes.c_uint32 * 7),
    ]


platform = sys.platform
libc = ctypes.CDLL(None, use_errno=True)
if platform.startswith("linux"):
    try:
        statx = libc.statx
    except AttributeError:
        fail("Linux statx mount identity is unavailable")
    statx.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint,
        ctypes.POINTER(Statx),
    ]
    statx.restype = ctypes.c_int
elif platform == "darwin":
    fstatfs = libc.fstatfs
    fstatfs.argtypes = [ctypes.c_int, ctypes.POINTER(DarwinStatfs)]
    fstatfs.restype = ctypes.c_int
else:
    fail("kernel mount identity is unsupported on this platform")


def mount_identity(fd):
    if platform.startswith("linux"):
        result = Statx()
        if statx(fd, b"", 0x1000, 0x1000, ctypes.byref(result)) != 0:
            raise MountIdentityError(
                "statx(STATX_MNT_ID) failed: %s" % os.strerror(ctypes.get_errno())
            )
        if not (result.stx_mask & 0x1000):
            raise MountIdentityError("statx did not return STATX_MNT_ID")
        return ("linux", int(result.stx_mnt_id))
    result = DarwinStatfs()
    if fstatfs(fd, ctypes.byref(result)) != 0:
        raise MountIdentityError(
            "fstatfs failed: %s" % os.strerror(ctypes.get_errno())
        )
    mountpoint = bytes(result.f_mntonname).split(b"\0", 1)[0]
    source = bytes(result.f_mntfromname).split(b"\0", 1)[0]
    filesystem = bytes(result.f_fstypename).split(b"\0", 1)[0]
    if not mountpoint:
        raise MountIdentityError("fstatfs returned no mountpoint")
    return (
        "darwin", int(result.f_fsid[0]), int(result.f_fsid[1]),
        filesystem, mountpoint, source,
    )


def same_identity(value, expected):
    return value.st_dev == expected[0] and value.st_ino == expected[1]


def stat_child(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        fail("descriptor-relative stat failed for %s: %s" % (name, error))


def open_child_directory(parent_fd, name, root_device, root_mount, expected=None):
    before = stat_child(parent_fd, name)
    if not stat.S_ISDIR(before.st_mode):
        fail("cache path component is not a real directory: %s" % name)
    if before.st_dev != root_device:
        fail("cache path crosses a filesystem boundary: %s" % name)
    try:
        child_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except (AttributeError, OSError) as error:
        fail("cache path component cannot be opened without following links: %s (%s)" % (name, error))
    actual = os.fstat(child_fd)
    try:
        child_mount = mount_identity(child_fd)
    except MountIdentityError as error:
        os.close(child_fd)
        fail("could not determine cache mount identity for %s: %s" % (name, error))
    if not same_identity(actual, (before.st_dev, before.st_ino)):
        os.close(child_fd)
        fail("cache path component changed during validation: %s" % name)
    if child_mount != root_mount:
        os.close(child_fd)
        fail("cache path crosses a mount boundary: %s" % name)
    if expected is not None and not same_identity(actual, expected):
        os.close(child_fd)
        fail("cache target changed during validation")
    return child_fd, actual


def remove_contents(directory_fd, root_device, root_mount):
    try:
        if mount_identity(directory_fd) != root_mount:
            fail("cache content crosses a mount boundary")
        names = os.listdir(directory_fd)
    except MountIdentityError as error:
        fail("could not determine cache mount identity: %s" % error)
    except OSError as error:
        fail("could not enumerate cache directory: %s" % error)
    for name in names:
        if name in (".", "..") or "/" in name:
            fail("unsafe cache directory entry")
        before = stat_child(directory_fd, name)
        if stat.S_ISDIR(before.st_mode):
            if before.st_dev != root_device:
                fail("cache content crosses a filesystem boundary: %s" % name)
            child_fd, child_stat = open_child_directory(
                directory_fd, name, root_device, root_mount,
                (before.st_dev, before.st_ino),
            )
            try:
                remove_contents(child_fd, root_device, root_mount)
                current = stat_child(directory_fd, name)
                if not same_identity(current, (child_stat.st_dev, child_stat.st_ino)):
                    fail("cache directory changed before removal: %s" % name)
                os.rmdir(name, dir_fd=directory_fd)
            except OSError as error:
                fail("could not remove cache directory entry %s: %s" % (name, error))
            finally:
                os.close(child_fd)
        else:
            current = stat_child(directory_fd, name)
            if not same_identity(current, (before.st_dev, before.st_ino)):
                fail("cache file changed before removal: %s" % name)
            try:
                os.unlink(name, dir_fd=directory_fd)
            except OSError as error:
                fail("could not remove cache file entry %s: %s" % (name, error))


try:
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except (AttributeError, OSError) as error:
    fail("registered root cannot be opened without following links: %s" % error)

open_fds = [root_fd]
try:
    root_stat = os.fstat(root_fd)
    if not same_identity(root_stat, expected_root):
        fail("registered root changed during validation")
    if root_stat.st_dev != expected_root[0]:
        fail("registered root filesystem changed during validation")
    try:
        root_mount = mount_identity(root_fd)
    except MountIdentityError as error:
        fail("could not determine registered root mount identity: %s" % error)

    relative = os.path.relpath(target, root)
    if relative in ("", ".") or relative == ".." or relative.startswith("../"):
        fail("cache target is not strictly below the registered root")
    parts = relative.split(os.sep)
    if any(part in ("", ".", "..") for part in parts):
        fail("cache target has an unsafe relative path")

    parent_fd = root_fd
    for component in parts[:-1]:
        parent_fd, _ = open_child_directory(
            parent_fd, component, root_stat.st_dev, root_mount
        )
        open_fds.append(parent_fd)
    target_fd, target_stat = open_child_directory(
        parent_fd, parts[-1], root_stat.st_dev, root_mount, expected_target
    )
    open_fds.append(target_fd)
    remove_contents(target_fd, root_stat.st_dev, root_mount)
    current = stat_child(parent_fd, parts[-1])
    if not same_identity(current, (target_stat.st_dev, target_stat.st_ino)):
        fail("cache target changed before removal")
    os.rmdir(parts[-1], dir_fd=parent_fd)
finally:
    for descriptor in reversed(open_fds):
        try:
            os.close(descriptor)
        except OSError:
            pass
PY
}

# dj_prune_cache_entry HOME FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID
#   GIT_COMMON_DIR ROOT ABS_CACHE_PATH
#
# Delete one known cache directory only after a fresh strict registry and Git
# identity check. The registry lock is held from that final check through the
# descriptor-relative deletion sink, so a registry writer cannot revoke or
# reassign ownership mid-mutation.
dj_prune_cache_entry() {
  local home="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5"
  local common="$6" root="$7" target="$8" real result=1

  [ "$#" -eq 8 ] || {
    echo "dj_prune_cache_entry: expected complete registry identity and cache path" >&2
    return 1
  }
  [ -n "$target" ] || {
    echo "dj_prune_cache_entry: empty path refused" >&2
    return 1
  }
  [ -d "$target" ] && [ ! -L "$target" ] || {
    echo "dj_prune_cache_entry: cache is unavailable, not a directory, or symlinked: $target" >&2
    return 1
  }
  if ! trellis_home_lock_acquire "$home" registry 30; then
    echo "dj_prune_cache_entry: could not acquire the registry lock" >&2
    return 1
  fi

  if ! dj_registered_owner_identity "$home" "$fleet" "$project_id" "$checkout_id" \
      "$worktree_id" "$common" "$root" >/dev/null; then
    echo "dj_prune_cache_entry: registered ownership changed or is unavailable" >&2
  elif ! dj_cache_entry_owned_by_worktree "$root" "$target"; then
    echo "dj_prune_cache_entry: cache crosses its registered worktree boundary: $target" >&2
  else
    real="$(dj__abspath "$target")"
    case "$real" in
      */.turbo/cache|*/.next/cache|*/.next/dev)
        if dj_remove_cache_tree_safely "$root" "$target"; then
          result=0
        fi
        ;;
      *)
        echo "dj_prune_cache_entry: '$real' is not a recognized cache directory" >&2
        ;;
    esac
  fi

  if ! trellis_home_lock_release >/dev/null 2>&1; then
    echo "dj_prune_cache_entry: could not release the registry lock" >&2
    result=1
  fi
  return "$result"
}

# dj_reap_worktree HOME FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID
#   GIT_COMMON_DIR ROOT
#
# Remove a registered linked worktree through Git. A main checkout, changed
# identity, unsafe ignored content, symlinked path, or a failed Git removal is
# refused. The registry lock covers the final exact owner check through Git's
# removal, so writers cannot reassign the worktree during the destructive step.
dj_reap_worktree() {
  local home="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5"
  local common="$6" root="$7" identity checkout_root checkout_root_real checkout_common
  local git_dir result=1

  [ "$#" -eq 7 ] || {
    echo "dj_reap_worktree: expected complete registry identity" >&2
    return 1
  }
  if ! trellis_home_lock_acquire "$home" registry 30; then
    echo "dj_reap_worktree: could not acquire the registry lock" >&2
    return 1
  fi

  if identity="$(dj_registered_owner_identity "$home" "$fleet" "$project_id" \
      "$checkout_id" "$worktree_id" "$common" "$root")"; then
    checkout_root="$(printf '%s\n' "$identity" | jq -r '.checkout_root // empty')"
    if [ -z "$checkout_root" ] || [ ! -d "$checkout_root" ] || [ -L "$checkout_root" ]; then
      echo "dj_reap_worktree: registered primary checkout is unavailable or symlinked" >&2
    else
      checkout_root_real="$(dj__abspath "$checkout_root")"
      checkout_common="$(git -C "$checkout_root" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
      checkout_common="$(dj__abspath "$checkout_common")"
      if [ "$checkout_root_real" != "$checkout_root" ]; then
        echo "dj_reap_worktree: registered primary checkout is not a canonical real path" >&2
      elif [ -z "$checkout_common" ] || [ "$checkout_common" != "$common" ]; then
        echo "dj_reap_worktree: primary checkout no longer has the registered Git common directory" >&2
      elif [ "$root" = "$checkout_root" ]; then
        echo "dj_reap_worktree: registered root is the main checkout — refusing" >&2
      else
        git_dir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
        git_dir="$(dj__abspath "$git_dir")"
        if [ -z "$git_dir" ] || [ "$git_dir" = "$common" ]; then
          echo "dj_reap_worktree: registered root is not a linked worktree — refusing" >&2
        elif ! dj_worktree_clean "$root"; then
          echo "dj_reap_worktree: worktree has tracked, untracked, or ignored local content" >&2
        elif git -C "$checkout_root" worktree remove "$root" >/dev/null 2>&1; then
          result=0
        else
          echo "dj_reap_worktree: Git refused registered worktree removal: $root" >&2
        fi
      fi
    fi
  else
    echo "dj_reap_worktree: registered ownership changed or is unavailable" >&2
  fi

  if ! trellis_home_lock_release >/dev/null 2>&1; then
    echo "dj_reap_worktree: could not release the registry lock" >&2
    result=1
  fi
  return "$result"
}

# dj_reap_phantom_worktree HOME FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID
#   GIT_COMMON_DIR CURRENT_ROOT PHANTOM_ROOT LSOF_SNAPSHOT
#
# Remove ONE exact stale Git worktree registration, never a filesystem tree.
# CURRENT_ROOT remains the strict, active local-registry owner that authorizes
# the mutation. PHANTOM_ROOT must still be absent, prunable, non-main, inactive,
# and below the narrow ephemeral namespaces at the sink. No broad `worktree
# prune` is used: Git receives only the exact phantom root.
dj_reap_phantom_worktree() {
  local home="$1" fleet="$2" project_id="$3" checkout_id="$4" worktree_id="$5"
  local common="$6" current_root="$7" phantom_root="$8" lsof_snapshot="$9"
  local identity checkout_root checkout_root_real checkout_common in_use_reason
  local result=1

  [ "$#" -eq 9 ] || {
    echo "dj_reap_phantom_worktree: expected current registry identity, phantom root, and lsof snapshot" >&2
    return 1
  }
  if ! trellis_home_lock_acquire "$home" registry 30; then
    echo "dj_reap_phantom_worktree: could not acquire the registry lock" >&2
    return 1
  fi

  if identity="$(dj_registered_owner_identity "$home" "$fleet" "$project_id" \
      "$checkout_id" "$worktree_id" "$common" "$current_root")"; then
    checkout_root="$(printf '%s\n' "$identity" | jq -r '.checkout_root // empty')"
    if [ -z "$checkout_root" ] || [ ! -d "$checkout_root" ] || [ -L "$checkout_root" ]; then
      echo "dj_reap_phantom_worktree: registered primary checkout is unavailable or symlinked" >&2
    else
      checkout_root_real="$(dj__abspath "$checkout_root")"
      checkout_common="$(git -C "$checkout_root" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
      checkout_common="$(dj__abspath "$checkout_common")"
      if [ "$checkout_root_real" != "$checkout_root" ]; then
        echo "dj_reap_phantom_worktree: registered primary checkout is not a canonical real path" >&2
      elif [ -z "$checkout_common" ] || [ "$checkout_common" != "$common" ]; then
        echo "dj_reap_phantom_worktree: primary checkout no longer has the registered Git common directory" >&2
      elif ! dj_phantom_worktree_reapable "$current_root" "$phantom_root"; then
        echo "dj_reap_phantom_worktree: phantom registration is no longer absent, prunable, and ephemeral" >&2
      elif in_use_reason="$(dj_worktree_in_use "$phantom_root" "$lsof_snapshot")"; then
        echo "dj_reap_phantom_worktree: phantom worktree is in use ($in_use_reason)" >&2
      # Re-observe after the liveness snapshot: a recreated, dirty, or moved
      # path between plan and sink is a refusal, never an implicit prune.
      elif ! dj_phantom_worktree_reapable "$current_root" "$phantom_root"; then
        echo "dj_reap_phantom_worktree: phantom registration changed after liveness check" >&2
      elif git -C "$checkout_root" worktree remove "$phantom_root" >/dev/null 2>&1; then
        result=0
      else
        echo "dj_reap_phantom_worktree: Git refused exact phantom registration removal: $phantom_root" >&2
      fi
    fi
  else
    echo "dj_reap_phantom_worktree: current registry ownership changed or is unavailable" >&2
  fi

  if ! trellis_home_lock_release >/dev/null 2>&1; then
    echo "dj_reap_phantom_worktree: could not release the registry lock" >&2
    result=1
  fi
  return "$result"
}
