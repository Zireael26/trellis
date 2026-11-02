#!/usr/bin/env python3
"""CPU-sized local gate with qualified structural containment on macOS.

Trusted tests may accidentally detach; deliberately escaping code is out of
scope. Ownership is the union of registered groups, an inherited sentinel fd,
a run environment token, private-tmp files/cwd, pinned output fds, and descendants.
The checkout's cwd is NEVER an ownership signal. Enumeration is in-process
(libproc and KERN_PROCARGS2), without lsof/ps subprocesses.

TRELLIS_LOCAL_GATE_RUNNER/RECEIPT/DEADLINE/TERM_GRACE remain hermetic test
seams. TRELLIS_LOCAL_GATE_RESERVE scales the cleanup reserve in tests;
TRELLIS_GATE_STATE_DIR isolates durable quarantine records in tests. Production
uses 7200 seconds, a 60-second reserve, and a 5-second TERM grace.

Spec 066 process: START provenance precedes admission and the first planner;
<aggregate>.provenance.jsonl retains caller and effective fenced shard snapshots
and the shard priority decision without changing the timing TSV. Active release
is the read-only config pointer, not a source VERSION inference or a certification
of the installed payload.

Spec 067 P1h: after verified-empty teardown, a failing shard's output and timing
rows are copied to <state>/failed-shards/<token>/ before the run root is deleted;
`--runs-reap` prunes those entries after seven days.

Selection: repeated `--test-file=scripts/tests/NAME.bats` arguments are deduplicated
and carried to the planner and every shard. A successful run then writes
PG_TESTS_RECEIPT_FILE (one line: `narrowed M`, or `full` without selection) only
after the aggregate receipt and containment teardown; any failure writes nothing.
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

# The read-only helper import must not write bytecode into the checkout.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from receipt_provenance import safe_capture, emit
from gate_receipts import state_root as gate_state_root, digest, passing_rows, private
from gate_verdict import safe_inputs, find_verdict, key as verdict_key, describe as describe_verdict

MAX_SHARD_COUNT = 16


def _default_shard_count() -> int:
    # cpu_count may be unavailable; retain the existing eight-shard floor.
    return min(12, max(8, (os.cpu_count() or 10) - 2))


def select_shard_count() -> int:
    override = os.environ.get("TRELLIS_TEST_SHARDS")
    if override is None:
        return _default_shard_count()
    message = "TRELLIS_TEST_SHARDS must be an integer from 1 to 16"
    if not re.fullmatch(r"[0-9]+", override):
        raise ValueError(message)
    try:
        count = int(override)
    except ValueError as exc:
        raise ValueError(message) from exc
    if not 1 <= count <= MAX_SHARD_COUNT:
        raise ValueError(message)
    return count


SHARD_COUNT = _default_shard_count()
GLOBAL_DEADLINE_SECONDS = 7200.0
TEARDOWN_RESERVE_SECONDS = 60.0
TERM_GRACE_SECONDS = 5.0
RECEIPT_HEADER = "ordinal\tstage\telapsed_seconds\texit"
FAILED_SHARD_RETENTION_SECONDS = 7 * 24 * 3600.0


class ContainmentError(Exception):
    def __init__(self, message: str, error: Optional[int] = None) -> None:
        super().__init__(message)
        self.error = error


class UnreadableProcess(ContainmentError):
    """Permission-protected files/environment, not an enumeration failure."""


class _DeadlineExit(Exception):
    pass


class _SignalExit(Exception):
    def __init__(self, signum: int) -> None:
        self.signum = signum


class _BSDInfo(ctypes.Structure):
    # sys/proc_info.h: PROC_PIDTBSDINFO (flavor 3), including the two
    # uint64_t timeval fields. Do not replace this with ps's rounded lstart.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
        "ruid", "rgid", "svuid", "svgid", "reserved",
    )] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
    ] + [(name, ctypes.c_uint32) for name in (
        "nfiles", "pgid", "jobc", "tdev", "tpgid",
    )] + [
        ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
        ("start_usec", ctypes.c_uint64),
    ]


class _ShortBSDInfo(ctypes.Structure):
    # sys/proc_info.h: PROC_PIDT_SHORTBSDINFO (flavor 13), no birth time.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "pid", "ppid", "pgid", "status",
    )] + [("comm", ctypes.c_char * 16)] + [
        (name, ctypes.c_uint32) for name in (
            "flags", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved",
        )
    ]


_LIBPROC = None
if sys.platform == "darwin":
    try:
        _LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        _LIBPROC.proc_pidinfo.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
        ]
        _LIBPROC.proc_pidinfo.restype = ctypes.c_int
    except (OSError, AttributeError):
        _LIBPROC = None  # Admission smoke test returns 70, not an import crash.


def process_identity(pid: int) -> Optional[Tuple[int, int]]:
    """Return (pid, start microseconds); None is ambiguity, not permission."""
    if _LIBPROC is not None:
        ctypes.set_errno(0)
        info = _BSDInfo()
        size = ctypes.sizeof(info)
        if _LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
            return None
        return (info.pid, info.start_sec * 1000000 + info.start_usec)
    if sys.platform.startswith("linux"):
        try:
            fields = Path("/proc/{}/stat".format(pid)).read_text().rsplit(")", 1)[1].split()
            boot = next(line.split()[1] for line in Path("/proc/stat").read_text().splitlines()
                        if line.startswith("btime "))
            return (pid, int(boot) * 1000000 + int(fields[19]) * 1000000 // os.sysconf("SC_CLK_TCK"))
        except (OSError, ValueError, IndexError, StopIteration):
            return None
    return None


class _FileInfo(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
                ("offset", ctypes.c_int64), ("type", ctypes.c_int32),
                ("guard", ctypes.c_uint32)]


class _VStat(ctypes.Structure):
    _fields_ = [("dev", ctypes.c_uint32), ("mode", ctypes.c_uint16),
                ("nlink", ctypes.c_uint16), ("ino", ctypes.c_uint64),
                ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32)] + [
        (name, ctypes.c_int64) for name in (
            "atime", "atimensec", "mtime", "mtimensec", "ctime", "ctimensec",
            "birthtime", "birthtimensec", "size", "blocks",
        )] + [("blksize", ctypes.c_int32)] + [
        (name, ctypes.c_uint32) for name in ("flags", "gen", "rdev")
    ] + [("spare", ctypes.c_int64 * 2)]


class _VNode(ctypes.Structure):
    _fields_ = [("stat", _VStat), ("type", ctypes.c_int),
                ("pad", ctypes.c_int), ("fsid", ctypes.c_int32 * 2)]


class _VNodePath(ctypes.Structure):
    _fields_ = [("node", _VNode), ("path", ctypes.c_char * 1024)]


class _VNodeFD(ctypes.Structure):
    _fields_ = [("file", _FileInfo), ("vnode", _VNodePath)]


class _CwdInfo(ctypes.Structure):
    _fields_ = [("cwd", _VNodePath), ("root", _VNodePath)]


class _FDInfo(ctypes.Structure):
    _fields_ = [("fd", ctypes.c_int32), ("type", ctypes.c_uint32)]


class _SigValue(ctypes.Union):
    _fields_ = [("integer", ctypes.c_int), ("pointer", ctypes.c_void_p)]


class _SigInfo(ctypes.Structure):
    # Darwin sys/signal.h, LP64 (arm64): 104 bytes, pointers at offsets 24/32.
    _fields_ = [(name, ctypes.c_int) for name in ("signo", "error", "code", "pid")] + [
        ("uid", ctypes.c_uint), ("status", ctypes.c_int),
        ("addr", ctypes.c_void_p), ("value", _SigValue),
        ("band", ctypes.c_long), ("pad", ctypes.c_ulong * 7),
    ]


_LIBC = ctypes.CDLL(None, use_errno=True)
_WAITID = None
if sys.platform == "darwin":
    try:
        _WAITID = _LIBC.waitid
        _WAITID.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.POINTER(_SigInfo), ctypes.c_int]
        _WAITID.restype = ctypes.c_int
    except AttributeError:
        pass  # The capability smoke test refuses admission.
if _LIBPROC is not None:
    try:
        _LIBPROC.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        _LIBPROC.proc_listallpids.restype = ctypes.c_int
        _LIBPROC.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        _LIBPROC.proc_listpids.restype = ctypes.c_int
        _LIBPROC.proc_pidfdinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        _LIBPROC.proc_pidfdinfo.restype = ctypes.c_int
        _LIBPROC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        _LIBPROC.proc_pidpath.restype = ctypes.c_int
        _LIBC.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint,
                                ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        _LIBC.sysctl.restype = ctypes.c_int
        _LIBC.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                      ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        _LIBC.sysctlbyname.restype = ctypes.c_int
    except AttributeError:
        _LIBPROC = None


def _scan_identity(pid: int, end: float) -> Optional[Tuple[int, int]]:
    observed = process_identity(pid)
    if observed is None and ctypes.get_errno() not in (errno.EPERM, errno.EACCES, errno.ESRCH):
        _bounded(end)
        observed = process_identity(pid)
    return observed


def _pid_gone(pid: int, error: int) -> bool:
    """Positive death only: an inspection failure alone proves nothing.

    XNU can return a short/zero read without ESRCH after enumeration. A signal-0
    existence probe closes that race; success, EPERM, and other probe failures
    leave the original inspection error fail-closed. No process is signaled.
    """
    if error == errno.ESRCH:
        return True
    if pid <= 0:
        return False  # Never probe a process group.
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        pass
    return False


def _bounded(end: float) -> None:
    if time.monotonic() >= end:
        raise ContainmentError("containment scan budget exhausted")


def _retry_pid(read: Any, end: float) -> Any:
    """Retry one transient per-pid failure, inside the same bounded scan."""
    try:
        return read()
    except ContainmentError as exc:
        if isinstance(exc, UnreadableProcess) or exc.error in (errno.EPERM, errno.EACCES, errno.ESRCH):
            raise
        _bounded(end)
        time.sleep(min(0.01, max(0, end - time.monotonic())))
        _bounded(end)
        return read()


def bsd_info(pid: int) -> Optional[_BSDInfo]:
    ctypes.set_errno(0)
    info = _BSDInfo()
    if _LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info):
        return info
    error = ctypes.get_errno()
    if _pid_gone(pid, error):
        return None
    raise ContainmentError("PROC_PIDTBSDINFO unavailable for pid {}".format(pid), error)


def _short_bsd_info(pid: int) -> Optional[_BSDInfo]:
    """Recover membership metadata, NEVER a birth identity or signal authority."""
    ctypes.set_errno(0)
    short = _ShortBSDInfo()
    size = ctypes.sizeof(short)
    if _LIBPROC.proc_pidinfo(pid, 13, 0, ctypes.byref(short), size) != size:
        error = ctypes.get_errno()
        if _pid_gone(pid, error):
            return None
        raise ContainmentError("PROC_PIDT_SHORTBSDINFO unavailable for pid {}".format(pid), error)
    if short.pid != pid:
        raise ContainmentError("PROC_PIDT_SHORTBSDINFO pid mismatch for {}".format(pid))
    info = _BSDInfo()
    for field in ("pid", "ppid", "pgid", "status", "uid"):
        setattr(info, field, getattr(short, field))
    # Zero means UNKNOWN birth, not pre-run. Such rows still undergo every
    # ownership check, but can never authorize a signal or exclusion receipt.
    return info


def process_table(end: float) -> Dict[int, _BSDInfo]:
    count = _LIBPROC.proc_listallpids(None, 0)
    if count <= 0:
        raise ContainmentError("proc_listallpids unavailable")
    # Headroom handles forks between sizing and enumeration; saturation refuses.
    pids = (ctypes.c_int * (count * 2 + 64))()
    used = _LIBPROC.proc_listallpids(pids, ctypes.sizeof(pids))
    if used <= 0 or used >= len(pids):
        raise ContainmentError("proc_listallpids failed or saturated")
    # UID enumeration lets us exclude unreadable foreign processes without
    # interpreting an identity error as proof that one belongs to this run.
    ours = (ctypes.c_int * len(pids))()
    own_bytes = _LIBPROC.proc_listpids(4, os.getuid(), ours, ctypes.sizeof(ours))  # PROC_UID_ONLY
    if own_bytes <= 0 or own_bytes >= ctypes.sizeof(ours):
        raise ContainmentError("PROC_UID_ONLY unavailable or saturated")
    own_pids = set(ours[:own_bytes // ctypes.sizeof(ctypes.c_int)])
    table = {}
    for pid in pids[:used]:
        _bounded(end)
        if pid <= 0:
            continue
        try:
            info = _retry_pid(lambda: bsd_info(pid), end)
        except ContainmentError as exc:
            if pid not in own_pids:
                continue  # Unreadable other-UID processes cannot be members.
            _bounded(end)
            try:
                info = _short_bsd_info(pid)
            except ContainmentError:
                raise exc  # Preserve the original failure if both reads fail.
        if info is not None:
            table[pid] = info
    return table


def boot_session() -> str:
    value = ctypes.create_string_buffer(128)
    size = ctypes.c_size_t(ctypes.sizeof(value))
    if _LIBC.sysctlbyname(b"kern.bootsessionuuid", value, ctypes.byref(size), None, 0):
        raise ContainmentError("kern.bootsessionuuid unavailable")
    return value.value.decode("ascii")


def parse_environment(raw: bytes) -> Optional[Set[bytes]]:
    """KERN_PROCARGS2: argc, aligned executable block, argv, then env.

    None means the platform-binary response ended immediately after argv.
    The executable block (AFTER argc) is pointer-aligned by XNU; skipping
    arbitrary NULs would also skip an empty argv[0] and eat the first env entry.
    """
    if len(raw) < 4:
        raise ContainmentError("short KERN_PROCARGS2")
    argc = int.from_bytes(raw[:4], sys.byteorder, signed=True)
    if argc < 0:
        raise ContainmentError("invalid KERN_PROCARGS2 argc")
    offset = raw.find(b"\0", 4)
    if offset < 0:
        raise ContainmentError("invalid KERN_PROCARGS2 executable")
    alignment = ctypes.sizeof(ctypes.c_void_p)
    offset = 4 + ((offset - 4 + 1 + alignment - 1) // alignment) * alignment
    if offset > len(raw):
        raise ContainmentError("short KERN_PROCARGS2 executable padding")
    for _ in range(argc):
        offset = raw.find(b"\0", offset)
        if offset < 0:
            raise ContainmentError("invalid KERN_PROCARGS2 argv")
        offset += 1
    if offset == len(raw):
        return None  # Environment absent, NOT a permission-protected process.
    entries = raw[offset:].split(b"\0")
    return set(entries[:entries.index(b"")]) if b"" in entries else set(entries)


def process_environment(pid: int) -> Optional[Set[bytes]]:
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    buffer = ctypes.create_string_buffer(1024 * 1024)
    size = ctypes.c_size_t(ctypes.sizeof(buffer))
    if _LIBC.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            return set()  # The inspected process exited before the argument read.
        if error in (errno.EPERM, errno.EACCES):
            raise UnreadableProcess("KERN_PROCARGS2 unreadable for pid {}".format(pid))
        if error == errno.EIO:
            # Exec or exit in progress: do not require a full BSD reread to
            # classify this known env-absent response. Other signals still apply.
            return None
        fresh = bsd_info(pid)
        if fresh is None or fresh.status == 5:
            return set()  # Positive exit during the scan, not unknown live work.
        raise ContainmentError("KERN_PROCARGS2 unavailable for pid {} (errno {})".format(pid, error), error)
    return parse_environment(buffer.raw[:size.value])


def process_files(pid: int, end: float) -> List[Tuple[Tuple[int, int], str]]:
    ctypes.set_errno(0)
    size = _LIBPROC.proc_pidinfo(pid, 1, 0, None, 0)  # PROC_PIDLISTFDS
    if size < 0 or (size == 0 and ctypes.get_errno() not in (0, errno.ESRCH)):
        error = ctypes.get_errno()
        if _pid_gone(pid, error):
            return []
        if error in (errno.EPERM, errno.EACCES):
            raise UnreadableProcess("PROC_PIDLISTFDS unreadable for pid {}".format(pid))
        raise ContainmentError("PROC_PIDLISTFDS unavailable for pid {}".format(pid), error)
    descriptors = (_FDInfo * (size // ctypes.sizeof(_FDInfo) + 32))()
    ctypes.set_errno(0)
    used = _LIBPROC.proc_pidinfo(pid, 1, 0, descriptors, ctypes.sizeof(descriptors))
    if used < 0 or used >= ctypes.sizeof(descriptors) or (used == 0 and ctypes.get_errno() not in (0, errno.ESRCH)):
        error = ctypes.get_errno()
        if _pid_gone(pid, error):
            return []
        if error in (errno.EPERM, errno.EACCES):
            raise UnreadableProcess("PROC_PIDLISTFDS unreadable for pid {}".format(pid))
        raise ContainmentError("PROC_PIDLISTFDS failed or saturated for pid {}".format(pid), error)
    paths = []
    for descriptor in descriptors[:used // ctypes.sizeof(_FDInfo)]:
        _bounded(end)
        if descriptor.type != 1:  # PROX_FDTYPE_VNODE
            continue
        vnode = _VNodeFD()
        ctypes.set_errno(0)
        got = _LIBPROC.proc_pidfdinfo(pid, descriptor.fd, 2, ctypes.byref(vnode), ctypes.sizeof(vnode))
        if got != ctypes.sizeof(vnode):
            error = ctypes.get_errno()
            if _pid_gone(pid, error):
                return []
            if error in (errno.EBADF, errno.ENOENT):
                continue  # Only this fd closed while enumerating.
            if error in (errno.EPERM, errno.EACCES):
                raise UnreadableProcess("PROC_PIDFDVNODEPATHINFO unreadable for pid {}".format(pid))
            raise ContainmentError("PROC_PIDFDVNODEPATHINFO unavailable for pid {} fd {}".format(pid, descriptor.fd), error)
        paths.append(((vnode.vnode.node.stat.dev, vnode.vnode.node.stat.ino), os.fsdecode(vnode.vnode.path)))
    cwd = _CwdInfo()
    ctypes.set_errno(0)
    if _LIBPROC.proc_pidinfo(pid, 9, 0, ctypes.byref(cwd), ctypes.sizeof(cwd)) == ctypes.sizeof(cwd):
        paths.append(((cwd.cwd.node.stat.dev, cwd.cwd.node.stat.ino), os.fsdecode(cwd.cwd.path)))
    else:
        error = ctypes.get_errno()
        if _pid_gone(pid, error):
            return []
        if error in (errno.EPERM, errno.EACCES):
            raise UnreadableProcess("PROC_PIDVNODEPATHINFO unreadable for pid {}".format(pid))
        raise ContainmentError("PROC_PIDVNODEPATHINFO unavailable for pid {}".format(pid), error)
    return paths


def _birth(info: _BSDInfo) -> int:
    return info.start_sec * 1000000 + info.start_usec


def _unreadable_entry(pid: int, start_us: int) -> Dict[str, Any]:
    path = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
    ctypes.set_errno(0)
    if _LIBPROC.proc_pidpath(pid, path, ctypes.sizeof(path)) <= 0:
        error = ctypes.get_errno()
        # Only exit status is needed here; a full birth reread can fail during
        # the same exec/exit transition that made the executable path unreadable.
        fresh = _short_bsd_info(pid)
        if fresh is not None and fresh.status != 5:
            raise ContainmentError("proc_pidpath unavailable for unreadable pid {}".format(pid), error)
        executable = "<exited>"
    else:
        executable = os.fsdecode(path.value)
    return {"pid": pid, "start_us": start_us, "executable": executable}


def _track_unreadable(data: Dict[str, Any], entries: Sequence[Dict[str, Any]],
                      record_path: Optional[Path] = None) -> None:
    # Receipt/record list is cumulative, deduplicated by birth (not by PID).
    excluded = data.setdefault("unreadable_excluded", [])
    known = {(entry["pid"], entry["start_us"]) for entry in excluded}
    added = [entry for entry in entries if (entry["pid"], entry["start_us"]) not in known]
    if added:
        excluded.extend(added)
        excluded.sort(key=lambda entry: (entry["pid"], entry["start_us"]))
        if record_path is not None:
            save_record(record_path, data)


def signal_member(identity: Optional[Tuple[int, int]], signum: int) -> bool:
    """Re-observe birth immediately before EACH signal; never signal a decoy."""
    if identity is None:
        return False
    observed = process_identity(identity[0])
    if observed != identity:
        if observed is None:
            try:
                fresh = bsd_info(identity[0])
                if fresh is None or fresh.status == 5:
                    return True  # Positive death/zombie, not a signal.
            except ContainmentError:
                pass
        return False
    try:
        os.kill(identity[0], signum)
        return True
    except ProcessLookupError:
        return True
    except PermissionError:
        return False  # Permission failure remains ambiguity, never permission.


def _positive_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    try:
        value = float(raw) if raw else default
    except ValueError as exc:
        raise ValueError("{} must be a positive number".format(name)) from exc
    if not math.isfinite(value) or value <= 0:
        raise ValueError("{} must be a positive number".format(name))
    return value


def _resolve_path(root: Path, value: str) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else root / path


def _command(args: Sequence[str], end: float, allowed: Sequence[int] = (0,)) -> str:
    remaining = end - time.monotonic()
    if remaining <= 0:
        raise ContainmentError("containment scan budget exhausted")
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=min(remaining, 10), check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ContainmentError("containment source unavailable: {}".format(args[0])) from exc
    if result.returncode not in allowed:
        raise ContainmentError("{} exited {}: {}".format(
            args[0], result.returncode, result.stderr.strip()))
    return result.stdout


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ContainmentError("directory is not owner-private: {}".format(path))


def _fsync_directory(path: Path) -> None:
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def save_record(path: Path, data: Dict[str, Any]) -> None:
    """Atomic, durable replacement, including every group registration."""
    fd, temporary = tempfile.mkstemp(prefix=".record-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(data, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class RunState:
    POLL_SECONDS = 2.0
    HEARTBEAT_SECONDS = 15.0
    LEASE_SECONDS = 60.0

    def __init__(self, head: str = "unknown", no_wait: bool = False) -> None:
        try:
            self.root = gate_state_root()
        except ValueError as exc:
            raise ContainmentError(str(exc)) from exc
        _private_directory(self.root)
        self.runs = self.root / "runs"
        self.queue = self.root / "gate-queue"
        for directory in (self.runs, self.queue):
            _private_directory(directory)
        self.holder = self.root / "gate-holder.json"
        self.lock_fd = self._open_lock("queue.lock")
        self.legacy_fd: Optional[int] = None
        self.guard = threading.Lock()
        self.stop = threading.Event()
        self.error: Optional[Exception] = None
        self.thread: Optional[threading.Thread] = None
        self.path: Optional[Path] = None
        self.stale: Dict[str, float] = {}
        identity = process_identity(os.getpid())
        if identity is None:
            os.close(self.lock_fd)
            raise ContainmentError("{} queue process birth identity unavailable".format(
                "libproc" if sys.platform == "darwin" else "procfs"))
        self.entry = {"token": uuid.uuid4().hex, "pid": identity[0], "start_us": identity[1],
                      "head": head, "heartbeat": time.time()}
        try:
            wait = _positive_float("TRELLIS_LOCAL_GATE_QUEUE_WAIT", 3 * GLOBAL_DEADLINE_SECONDS)
            end = time.monotonic() + wait
            while True:
                with self.guard:
                    locked = self._lock()
                    if locked:
                        try:
                            if self._admit(no_wait):
                                break
                        finally:
                            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
                if no_wait or time.monotonic() >= end:
                    raise ContainmentError("queue wait bounded exit 70; holder={} waiters={}".format(
                        self.holder, ",".join(p.name for p in self.queue.glob("*.json"))))
                time.sleep(min(self.POLL_SECONDS, max(0, end - time.monotonic())))
            # Process-directed signals must stay pending while _spawn blocks
            # them in the main thread through durable child registration.
            mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGALRM})
            try:
                self.thread = threading.Thread(target=self._heartbeat, daemon=True)
                self.thread.start()
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        except BaseException:
            self.close()
            raise

    def _open_lock(self, name: str) -> int:
        fd = os.open(str(self.root / name), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            os.close(fd)
            raise ContainmentError("state lock is not owner-private")
        return fd

    def _lock(self) -> bool:
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False

    def _read(self, path: Path) -> Dict[str, Any]:
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise ValueError("not owner-private")
            data = json.loads(path.read_text(encoding="utf-8"))
            if (not re.fullmatch(r"[0-9a-f]{32}", data["token"])
                    or not isinstance(data["pid"], int) or data["pid"] <= 1
                    or not isinstance(data["start_us"], int) or data["start_us"] <= 0
                    or not isinstance(data["head"], str)
                    or not isinstance(data["heartbeat"], (int, float))
                    or not math.isfinite(data["heartbeat"]) or data["heartbeat"] <= 0):
                raise ValueError("invalid lease")
            return data
        except (OSError, KeyError, TypeError, ValueError) as exc:
            raise ContainmentError("corrupt queue entry {}: {}".format(path, exc)) from exc

    def _quarantine(self, path: Path, reason: str) -> None:
        target = path.with_name(path.name + ".quarantine-" + uuid.uuid4().hex)
        os.rename(path, target)
        print("run-tests-local: WARN {} {}; evidence={}".format(reason, path, target), flush=True)

    def _live(self, path: Path, holder: bool = False) -> Optional[Dict[str, Any]]:
        if not path.exists() and not path.is_symlink():
            return None
        try:
            data = self._read(path)
        except ContainmentError:
            if holder:
                raise  # Corrupt holders require an operator; never guess.
            self._quarantine(path, "corrupt waiter")
            return None
        identity = process_identity(data["pid"])
        dead = identity is not None and identity != (data["pid"], data["start_us"])
        if identity is None:
            dead = _pid_gone(data["pid"], 0)
        token = data["token"]
        if time.time() - data["heartbeat"] > self.LEASE_SECONDS:
            dead = dead or self.stale.get(token) == data["heartbeat"]
            self.stale[token] = data["heartbeat"]
        else:
            self.stale.pop(token, None)
        if dead:
            self._quarantine(path, "dead lease")
            return None
        return data

    def _create(self, path: Path) -> None:
        self.entry["heartbeat"] = time.time()
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(self.entry, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        self.path = path

    def _admit(self, no_wait: bool) -> bool:
        holder = self._live(self.holder, holder=True)
        waiters = []
        for path in sorted(self.queue.glob("*.json")):
            if not re.fullmatch(r"[0-9]{20}\.json", path.name):
                self._quarantine(path, "corrupt ticket")
            elif self._live(path):
                waiters.append(path)
        if no_wait and (holder or waiters):
            raise ContainmentError("queue occupied (--no-wait); holder={} waiters={}".format(
                holder["head"] if holder else "none", len(waiters)))
        if self.path is None:
            next_path = self.queue / "next"
            try:
                if next_path.exists() or next_path.is_symlink():
                    if not private(next_path):
                        raise ValueError("next ticket is not owner-private")
                    ticket = int(next_path.read_text())
                else:
                    ticket = 1
                if ticket < 1:
                    raise ValueError("nonpositive ticket")
            except (OSError, ValueError) as exc:
                raise ContainmentError("corrupt queue next ticket") from exc
            while True:
                try:
                    self._create(self.queue / ("{:020d}.json".format(ticket)))
                    break
                except FileExistsError:
                    ticket += 1
            fd, temporary = tempfile.mkstemp(prefix=".next-", dir=str(self.queue))
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    stream.write(str(ticket + 1) + "\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, next_path)
                _fsync_directory(self.queue)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            waiters.append(self.path)
            waiters.sort()
        # Refresh waiting leases on every poll; holders use the background thread.
        if not self.path.exists():
            raise ContainmentError("queue waiter lease lost")
        self.entry["heartbeat"] = time.time()
        save_record(self.path, self.entry)
        if not holder and waiters[0] == self.path:
            # Keep the pre-072 lock for the entire admitted run. Metadata uses
            # queue.lock so waiters can still ticket and refresh their leases.
            if self.legacy_fd is None:
                self.legacy_fd = self._open_lock("lock")
            try:
                fcntl.flock(self.legacy_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                ticket_path = self.path
                self._create(self.holder)
                ticket_path.unlink()
                print("run-tests-local: queue admitted ticket={}".format(ticket_path.stem), flush=True)
                return True
        position = waiters.index(self.path) + 1
        print("run-tests-local: queue position={} holder={} estimated_start={}s".format(
            position, holder["head"] if holder else "legacy-lock", position * GLOBAL_DEADLINE_SECONDS), flush=True)
        return False

    def _heartbeat(self) -> None:
        while not self.stop.wait(self.HEARTBEAT_SECONDS):
            try:
                with self.guard:
                    if not self._lock():
                        continue
                    try:
                        if self._read(self.path)["token"] != self.entry["token"]:
                            raise ContainmentError("queue lease lost")
                        self.entry["heartbeat"] = time.time()
                        save_record(self.path, self.entry)
                    finally:
                        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            except (OSError, ContainmentError) as exc:
                self.error = exc
                return

    def check(self) -> None:
        if self.error is not None:
            raise ContainmentError("queue heartbeat failed: {}".format(self.error))

    def records(self) -> List[Path]:
        return sorted(self.runs.glob("*.json"))

    def close(self, deadline: Optional[float] = None) -> None:
        end = deadline if deadline is not None else time.monotonic() + TERM_GRACE_SECONDS
        self.stop.set()
        if self.thread is not None:
            self.thread.join(max(0, end - time.monotonic()))
            if self.thread.is_alive():
                raise ContainmentError("queue heartbeat shutdown unverified; lease retained")
        if not self.guard.acquire(timeout=max(0, end - time.monotonic())):
            raise ContainmentError("queue shutdown lock unavailable; lease retained")
        try:
            if self._lock():
                try:
                    if self.path is not None and self.path.exists():
                        try:
                            if self._read(self.path)["token"] == self.entry["token"]:
                                self.path.unlink()
                        except ContainmentError:
                            pass  # Preserve corrupt evidence; never mask the run's result.
                finally:
                    fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            # A contended metadata lock leaves a dead lease for the next observer.
            os.close(self.lock_fd)
            if self.legacy_fd is not None:
                os.close(self.legacy_fd)
                self.legacy_fd = None
        finally:
            self.guard.release()


def _read_record(path: Path) -> Dict[str, Any]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ContainmentError("record is not owner-private: {}".format(path))
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        token = data["token"]
        root = Path(data["run_root"])
        if not re.fullmatch(r"[0-9a-f]{32}", token) or path.name != token + ".json":
            raise ValueError("invalid token")
        if root.parent not in (Path("/tmp"), Path("/private/tmp")) or not root.name.startswith("tg-"):
            raise ValueError("invalid private root")
        if Path(data["sentinel"]) != root / "sentinel":
            raise ValueError("invalid sentinel")
        if not isinstance(data["boot_session"], str) or not data["boot_session"]:
            raise ValueError("invalid boot session")
        if not all(isinstance(data["sentinel_id"][key], int) for key in ("dev", "ino")):
            raise ValueError("invalid sentinel identity")
        if data["uid"] != os.getuid():
            raise ValueError("foreign uid")
        owner = data["owner"]
        if not isinstance(owner["pid"], int) or owner["pid"] <= 1 or not isinstance(owner["start_us"], int) or owner["start_us"] <= 0:
            raise ValueError("invalid owner identity")
        if not isinstance(data.get("started_us", owner["start_us"]), int) or data.get("started_us", owner["start_us"]) <= 0:
            raise ValueError("invalid run start")
        if "started_monotonic" in data and (not isinstance(data["started_monotonic"], (int, float)) or not math.isfinite(data["started_monotonic"]) or data["started_monotonic"] <= 0):
            raise ValueError("invalid monotonic start")
        if "pre_run_bound_us" in data and (not isinstance(data["pre_run_bound_us"], int) or data["pre_run_bound_us"] > data["started_us"]):
            raise ValueError("invalid clock-step bound")
        if data.get("clock_step", 0) not in (0, 1):
            raise ValueError("invalid clock-step marker")
        for output in data.get("output_ids", []):
            # Old runs may have used a different CPU count or override. Validate
            # their pinned paths against the supported range, not today's plan.
            if output["path"] not in [str(root / "planner.out")] + [str(root / "shard-{}.out".format(i)) for i in range(1, MAX_SHARD_COUNT + 1)]:
                raise ValueError("invalid output path")
            if not all(isinstance(output[key], int) for key in ("dev", "ino")):
                raise ValueError("invalid output identity")
        for entry in data.get("unreadable_excluded", []):
            if not isinstance(entry["pid"], int) or entry["pid"] <= 1 or not isinstance(entry["start_us"], int) or entry["start_us"] <= 0 or not isinstance(entry["executable"], str):
                raise ValueError("invalid unreadable exclusion")
        for group in data["groups"]:
            if not isinstance(group["pgid"], int) or group["pgid"] <= 1 or not isinstance(group["start_us"], int):
                raise ValueError("invalid group identity")
        if not re.fullmatch(r"[0-9a-f]{40,64}", data["head"]):
            raise ValueError("invalid HEAD")
        if str(root) != os.path.realpath(root) or data["sentinel"] != os.path.realpath(data["sentinel"]):
            raise ValueError("noncanonical root or sentinel")
        if root.exists() or root.is_symlink():
            _private_directory(root)
        return data
    except (OSError, KeyError, TypeError, ValueError) as exc:
        raise ContainmentError("invalid record {}: {}".format(path, exc)) from exc


def _pre_run_bound(data: Dict[str, Any], record_path: Optional[Path]) -> int:
    started_us = data.get("started_us", data["owner"]["start_us"])
    bound = data.get("pre_run_bound_us", started_us)
    if "started_monotonic" in data:
        now = time.monotonic()
        reconstructed = time.time_ns() // 1000 - int(max(0, now - data["started_monotonic"]) * 1000000)
        # Admission reads wall BEFORE monotonic, this scan reads monotonic
        # BEFORE wall: sampling skew is conservative, not a backwards step.
        if reconstructed < bound:
            bound = reconstructed
            data["pre_run_bound_us"] = bound
            data["clock_step"] = 1
            if record_path is not None:
                save_record(record_path, data)
    return bound


class Boundary:
    def __init__(self, data: Dict[str, Any], live: bool = False,
                 record_path: Optional[Path] = None) -> None:
        self.data = data
        self.live = live
        self.record_path = record_path
        self.ambiguous = False

    def scan(self, end: float) -> Dict[int, Optional[Tuple[int, int]]]:
        table = process_table(end)
        excluded: Set[int] = {os.getpid()}
        ancestor = os.getpid()
        while ancestor in table:
            ancestor = table[ancestor].ppid
            if ancestor in excluded:
                break
            excluded.add(ancestor)
        # Older durable records predate started_us; their owner's birth is a
        # conservative lower bound. New runs use the actual admission start.
        started_us = _pre_run_bound(self.data, self.record_path)
        eligible = {pid for pid, entry in table.items()
                    if pid not in excluded and entry.uid == os.getuid() and entry.status != 5
                    and (_birth(entry) == 0 or _birth(entry) >= started_us)}  # SZOMB; unknown births stay eligible.
        groups = set()
        if self.live:
            # These are this runner's registered, strongly-held Popen children.
            # observe_exit NEVER reaps them; even an exited leader pins its PID.
            # XNU may omit zombies from PROC_PIDTBSDINFO, so a missing BSD row
            # is not permission to discard a group or to reap its leader.
            groups = {group["pgid"] for group in self.data["groups"]}
        strong = {pid for pid in eligible if table[pid].pgid in groups}
        owned = set(strong)
        recorded_groups = {entry["pgid"] for entry in self.data["groups"]}
        for pid in list(eligible):
            if _birth(table[pid]) != 0 or not recorded_groups:
                continue
            _bounded(end)
            try:
                session = os.getsid(pid)
            except OSError as exc:
                if _pid_gone(pid, exc.errno):
                    eligible.discard(pid)
                    owned.discard(pid)
                    continue
                raise ContainmentError("session unavailable for pid {}".format(pid), exc.errno) from exc
            if table[pid].pgid in recorded_groups or session in recorded_groups:
                # Even stale IDs are refusal hints for unknown births, never
                # signal authority: a partial row may still be run work.
                owned.add(pid)

        def descendants() -> None:
            while True:
                _bounded(end)
                children = {pid for pid in eligible if table[pid].ppid in owned}
                if children <= owned:
                    break
                owned.update(children)

        descendants()
        token = ("TRELLIS_GATE_RUN_ID=" + self.data["token"]).encode()
        private_tmp = os.path.realpath(str(Path(self.data["run_root"]) / "tmp"))
        sentinel = (self.data["sentinel_id"]["dev"], self.data["sentinel_id"]["ino"])
        outputs = {(entry["dev"], entry["ino"]) for entry in self.data.get("output_ids", [])}
        depths: Dict[int, int] = {}
        for pid in eligible:
            chain = []
            ancestor = pid
            while ancestor in eligible and ancestor not in depths:
                _bounded(end)
                if ancestor in chain:
                    raise ContainmentError("inconsistent ppid cycle in scan")
                chain.append(ancestor)
                ancestor = table[ancestor].ppid
            depth = depths.get(ancestor, -1)
            for member in reversed(chain):
                depth += 1
                depths[member] = depth
        unreadable = set()
        for pid in sorted(eligible, key=lambda member: (depths[member], member)):
            _bounded(end)
            # Group/descendancy needs no readable files or environment. For a
            # structural-only match neither may be permission-protected.
            # Env-absent platform binaries retain all their other signals (r5).
            if pid in owned:
                continue
            try:
                files = _retry_pid(lambda: process_files(pid, end), end)
                environment = _retry_pid(lambda: process_environment(pid), end)
            except UnreadableProcess:
                if _birth(table[pid]) == 0:
                    raise ContainmentError("unreadable membership for pid {}".format(pid))
                unreadable.add(pid)
                continue
            for identity, name in files:
                if identity == sentinel:
                    owned.add(pid)
                elif identity in outputs:
                    owned.add(pid)
                # Never canonicalize unrelated/network paths. Only /tmp aliases
                # can resolve into our root; compare by path components.
                elif name.startswith(("/tmp/", "/private/tmp/")):
                    canonical = os.path.realpath(name)
                    if canonical == private_tmp or canonical.startswith(private_tmp + "/"):
                        owned.add(pid)
            if environment is not None and token in environment:
                owned.add(pid)
            if pid in owned:
                descendants()
        descendants()
        _track_unreadable(self.data, [_retry_pid(lambda: _unreadable_entry(pid, _birth(table[pid])), end)
                                     for pid in sorted(unreadable - owned)], self.record_path)
        ambiguous = set()
        for pid in owned - strong:
            parent = table.get(table[pid].ppid)
            # launchd/init is the orphan authority, not an operator's live
            # parent. Descendants of an owned parent are independently strong.
            if parent is not None and parent.pid != 1 and parent.status != 5 and parent.pid not in owned:
                ambiguous.add(pid)
        # Do not signal descendants rooted in an ambiguous foreign match.
        while True:
            children = {pid for pid in owned if table[pid].ppid in ambiguous}
            if children <= ambiguous:
                break
            ambiguous.update(children)
        result = {}
        for pid in owned:
            if _birth(table[pid]) == 0:
                fresh = _retry_pid(lambda: bsd_info(pid), end)
                if fresh is None or fresh.status == 5:
                    continue  # Positive death still resolves a partial member.
                result[pid] = None  # No pinned birth; never grant signal authority.
                continue
            observed = _scan_identity(pid, end)
            if observed is None:
                # A positively dead process is not an unreadable live identity.
                # Otherwise a normal TERM exit between table and signal scans
                # would incorrectly become a permanent quarantine.
                fresh = _retry_pid(lambda: bsd_info(pid), end)
                if fresh is None or fresh.status == 5:
                    continue
            pinned = (pid, table[pid].start_sec * 1000000 + table[pid].start_usec)
            result[pid] = observed if pid not in ambiguous and observed == pinned else None
        return result

    def teardown(self, end: float, grace: float) -> int:
        """Two full empty scans; any post-launch ambiguity is sticky."""
        term_until = None
        survivors = 1
        empty_scans = 0
        terminated: Set[Tuple[int, int]] = set()
        while time.monotonic() < end:
            try:
                members = self.scan(end)
                survivors = len(members)
                if not members:
                    empty_scans += 1
                    if empty_scans >= 2 and not self.ambiguous:
                        return 0
                    if not self.ambiguous:
                        continue  # Empty fast path has no grace/poll sleep.
                else:
                    empty_scans = 0
                if any(identity is None for identity in members.values()):
                    self.ambiguous = True
                for identity in members.values():
                    if identity is not None and identity not in terminated:
                        if not signal_member(identity, signal.SIGTERM):
                            self.ambiguous = True
                        terminated.add(identity)
                if members and term_until is None:
                    term_until = min(end, time.monotonic() + grace)
                if term_until is not None and time.monotonic() >= term_until:
                    for identity in members.values():
                        if identity is not None and not signal_member(identity, signal.SIGKILL):
                            self.ambiguous = True
            except ContainmentError as exc:
                self.ambiguous = True
                empty_scans = 0
                print("run-tests-local: {}".format(exc), file=sys.stderr)
            time.sleep(min(0.05, max(0, end - time.monotonic())))
        return max(1, survivors)


def _remove_run_root(data: Dict[str, Any]) -> None:
    root = Path(data["run_root"])
    if not root.exists() and not root.is_symlink():
        return
    if str(root) != os.path.realpath(root):
        raise ContainmentError("run root no longer matches recorded path: {}".format(root))
    _private_directory(root)  # Recheck ownership/mode and refuse symlinks.
    shutil.rmtree(root)


def _delete_empty_record(path: Path, data: Dict[str, Any]) -> None:
    # Cleanup only roots admitted by _read_record or created by this runner.
    _remove_run_root(data)
    path.unlink()
    _fsync_directory(path.parent)


def _retain_failed_shards(state: RunState, data: Dict[str, Any], shards: Sequence[Dict[str, Any]]) -> None:
    """Copy each failing shard's TAP and timing rows out of the run root.

    Called only after verified-empty teardown has reaped every leader, so no
    live process holds what is kept; a passing shard keeps nothing. Retention is
    evidence only: a copy failure is reported and never changes the verdict.
    """
    kept = state.root / "failed-shards" / data["token"]
    for entry in shards:
        if entry["process"] is not None and entry["process"].returncode == 0:
            continue
        try:
            _private_directory(kept.parent)
            _private_directory(kept)
            for source in (entry["output"], entry["receipt"]):
                if source.is_file() and not source.is_symlink():
                    shutil.copyfile(str(source), str(kept / source.name))
            print("run-tests-local: retained failing shard {}/{} output: {}".format(
                entry["shard"], SHARD_COUNT, kept / entry["output"].name), flush=True)
        except (ContainmentError, OSError) as exc:
            print("run-tests-local: could not retain failing shard {}/{} output: {}".format(
                entry["shard"], SHARD_COUNT, exc), file=sys.stderr)


def _prune_failed_shards(state: RunState) -> None:
    """Reap drops retained failing-shard output older than seven days.

    Only owner-private <token> directories directly under failed-shards are
    candidates; a symlink or foreign entry is left alone. A prune failure is
    reported and never changes the reap verdict.
    """
    kept = state.root / "failed-shards"
    cutoff = time.time() - FAILED_SHARD_RETENTION_SECONDS
    try:
        if kept.is_symlink() or not kept.is_dir():
            return
        for entry in sorted(kept.iterdir()):
            info = entry.lstat()
            if (re.fullmatch(r"[0-9a-f]{32}", entry.name) and stat.S_ISDIR(info.st_mode)
                    and info.st_uid == os.getuid() and info.st_mtime < cutoff):
                shutil.rmtree(entry)
                print("run-tests-local: pruned failing shard output older than 7 days: {}".format(entry))
    except OSError as exc:
        print("run-tests-local: could not prune failing shard output: {}".format(exc), file=sys.stderr)


def _persist_passing_aggregate(state: RunState, data: Dict[str, Any], aggregate: Path,
                               root: Path, end: float) -> Path:
    content = aggregate.read_bytes()
    passing_rows(content)
    tree = _command(["git", "-C", str(root), "rev-parse", data["head"] + "^{tree}"], end).strip()
    kept = state.root / "passing-runs" / data["token"]
    _private_directory(kept.parent)
    _private_directory(kept)
    fd = os.open(str(kept / "aggregate.tsv"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    save_record(kept / "run.json", {"id": data["token"], "head": data["head"], "tree": tree,
                "completed_at": time.time(), "aggregate_sha256": digest(content)})
    print("run-tests-local: retained passing aggregate: {}".format(kept), flush=True)
    return kept


def _invalidate_verdicts(state: RunState, root: Path, end: float) -> None:
    directory = state.root / "verdicts"
    if not directory.exists():
        return
    if not private(directory, True):
        raise ContainmentError("verdict directory is not owner-private")
    tree = _command(["git", "-C", str(root), "rev-parse", "HEAD^{tree}"], end).strip()
    for path in directory.glob("*.json"):
        try:
            if private(path) and json.loads(path.read_text(encoding="utf-8"))["inputs"]["tree"] == tree:
                path.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            continue


def _write_verdict(state: RunState, before: Optional[Dict[str, Any]], after: Optional[Dict[str, Any]], kept: Path) -> None:
    if before is None or (state.root / "reuse-disabled.json").exists() or after != before:
        return
    record = json.loads((kept / "run.json").read_text(encoding="utf-8"))
    directory = state.root / "verdicts"
    _private_directory(directory)
    save_record(directory / (verdict_key(before) + ".json"), {
        "schema": 1, "key": verdict_key(before), "inputs": before,
        "status": "pass", "complete": True, "containment": "verified-empty",
        "id": record["id"], "aggregate_sha256": record["aggregate_sha256"],
        "completed_at": record["completed_at"]})
    print("run-tests-local: wrote verdict {}".format(record["id"]), flush=True)


def _receipt(data: Dict[str, Any], survivors: int, retained: bool) -> None:
    entries = data.get("unreadable_excluded", [])
    for entry in entries:
        print("run-tests-local: unreadable_excluded pid={} start_us={} executable={}".format(
            entry["pid"], entry["start_us"], json.dumps(entry["executable"])), flush=True)
    print("run-tests-local: containment=qualified run={} survivors={} record={} unreadable_excluded={} clock_step={}".format(
        data["token"], survivors, "retained" if retained else "deleted", len(entries), data.get("clock_step", 0)), flush=True)


def sweep_records(state: RunState, reserve: float, grace: float, end: Optional[float] = None) -> bool:
    cleared = True
    for path in state.records():
        try:
            data = _read_record(path)
            if data["boot_session"] != boot_session():
                # Earlier-boot PIDs/groups/inodes are not evidence of ownership.
                path.unlink()
                _fsync_directory(path.parent)
                _remove_run_root(data)
                _receipt(data, 0, False)
                continue
            owner = (data["owner"]["pid"], data["owner"]["start_us"])
            observed = process_identity(owner[0])
            if observed == owner:
                raise ContainmentError("record owner is alive: {}".format(path))
            if observed is None:
                # Distinguish dead from unreadable identity without signaling it.
                try:
                    os.kill(owner[0], 0)
                except ProcessLookupError:
                    pass
                else:
                    raise ContainmentError("record owner identity unavailable: {}".format(path))
            sweep_end = time.monotonic() + reserve
            if end is not None:
                sweep_end = min(sweep_end, end)
            survivors = Boundary(data, live=False, record_path=path).teardown(sweep_end, grace)
            if survivors:
                _receipt(data, survivors, True)
                raise ContainmentError("quarantined record: {}".format(path))
            _delete_empty_record(path, data)
            _receipt(data, 0, False)
        except (ContainmentError, OSError) as exc:
            print("run-tests-local: {}".format(exc), file=sys.stderr)
            _receipt({"token": path.stem}, 1, True)
            cleared = False
    return cleared


def _capability(end: float, require_wait: bool = True, full_scan: bool = True,
                started_us: Optional[int] = None) -> List[Dict[str, Any]]:
    if started_us is None:
        started_us = time.time_ns() // 1000
    if _LIBPROC is None or process_identity(os.getpid()) is None:
        raise ContainmentError("libproc process birth identity unavailable; nothing launched")
    table = process_table(end)
    if os.getpid() not in table:
        raise ContainmentError("libproc enumeration unavailable; nothing launched")
    boot_session()
    # Own non-platform process must expose env, cwd, and vnode fds.
    mib = (ctypes.c_int * 3)(1, 49, os.getpid())
    buffer = ctypes.create_string_buffer(1024 * 1024)
    size = ctypes.c_size_t(ctypes.sizeof(buffer))
    if _LIBC.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
        raise ContainmentError("KERN_PROCARGS2 smoke test failed; nothing launched")
    parse_environment(buffer.raw[:size.value])
    process_files(os.getpid(), end)
    if require_wait:
        _wait_smoke(end)
    unreadable = []
    if full_scan:
        for pid, info in table.items():
            _bounded(end)
            if info.uid == os.getuid() and info.status != 5 and (_birth(info) == 0 or _birth(info) >= started_us):
                try:
                    _retry_pid(lambda: process_files(pid, end), end)
                    _retry_pid(lambda: process_environment(pid), end)
                except UnreadableProcess:
                    if _birth(info) == 0:
                        raise ContainmentError("unreadable preflight membership for pid {}".format(pid))
                    unreadable.append(_retry_pid(lambda: _unreadable_entry(pid, _birth(info)), end))
    return unreadable


def _heavy_fds() -> Tuple[int, ...]:
    value = os.environ.get("TRELLIS_HEAVY_FD")
    if value is None:
        return ()
    try:
        fd = int(value)
        if fd < 3:
            raise ValueError("reserved descriptor")
        os.fstat(fd)
        return (fd,)
    except (OSError, ValueError) as exc:
        raise ContainmentError("inherited heavy slot fd unusable") from exc


def _new_run(state: RunState, root: Path, end: float, started_us: int,
             started_monotonic: float, unreadable: Sequence[Dict[str, Any]]) -> Tuple[Dict[str, Any], Path, int]:
    run_root = Path(tempfile.mkdtemp(prefix="tg-", dir="/tmp")).resolve()
    sentinel_fd = None
    try:
        _private_directory(run_root)
        _private_directory(run_root / "tmp")
        sentinel = run_root / "sentinel"
        sentinel_fd = os.open(str(sentinel), os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        if sentinel_fd < 3:
            duplicate = fcntl.fcntl(sentinel_fd, fcntl.F_DUPFD_CLOEXEC, 3)
            os.close(sentinel_fd)
            sentinel_fd = duplicate
        info = os.fstat(sentinel_fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ContainmentError("sentinel is not owner-private")
        if (info.st_dev, info.st_ino) not in {identity for identity, _ in process_files(os.getpid(), end)}:
            raise ContainmentError("sentinel fd cannot be observed")
        token = uuid.uuid4().hex
        owner = process_identity(os.getpid())
        if owner is None:
            raise ContainmentError("runner identity unavailable")
        head = _command(["git", "-C", str(root), "rev-parse", "HEAD"], end).strip()
        data = {"token": token, "uid": os.getuid(),
                "owner": {"pid": owner[0], "start_us": owner[1]},
                "run_root": str(run_root), "sentinel": str(sentinel),
                "groups": [], "head": head, "boot_session": boot_session(),
                "sentinel_id": {"dev": info.st_dev, "ino": info.st_ino},
                "started_monotonic": started_monotonic, "started_us": started_us,
                "output_ids": [],
                "unreadable_excluded": list(unreadable)}
        path = state.runs / (token + ".json")
        save_record(path, data)  # MUST precede the planner and every shard.
        return data, path, sentinel_fd
    except BaseException:
        if sentinel_fd is not None:
            os.close(sentinel_fd)
        # A record that made it to disk remains authoritative after a failed
        # fsync; don't erase its root until a later verified sweep.
        if not any(p for p in state.records() if p.stem == locals().get("token")):
            shutil.rmtree(run_root)
        raise


def _shard_priority(environment: Dict[str, str]) -> Tuple[List[str], str]:
    # nice, not a QoS class: QoS would confine shards to efficiency cores (B4 sec 6).
    # A missing nice runs shards unprefixed, and the receipt names that fallback.
    if shutil.which("nice", path=environment.get("PATH", os.defpath)):
        return ["nice", "-n", "10"], "applied: nice -n 10"
    return [], "unavailable: nice not on PATH; shards run at inherited priority"


def _spawn(data: Dict[str, Any], path: Path, fd: int, processes: List[subprocess.Popen],
           command: Sequence[str], root: Path, environment: Dict[str, str], output: Any) -> subprocess.Popen:
    # Block interruptions through Popen + durable registration. SIGKILL may
    # still strike here, but the already-persisted sentinel/root/token owns the
    # in-flight child even before its process group is appended.
    output_info = os.fstat(output.fileno())
    data["output_ids"].append({"path": str(Path(output.name).resolve()),
                               "dev": output_info.st_dev, "ino": output_info.st_ino})
    save_record(path, data)  # Pin inherited stdio BEFORE Popen, even on SIGKILL.
    ready_read, ready_write = os.pipe()
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    # A one-byte admission handshake prevents a very short planner/shard from
    # exiting before its live birth identity is captured. exec keeps PID/PGID
    # and inherited sentinel/heavy descriptors; EOF refuses execution.
    loader = ("import os,sys,signal; signal.pthread_sigmask(signal.SIG_SETMASK," +
              repr(sorted(int(signum) for signum in mask)) + "); "
              "fd=int(sys.argv[1]); go=os.read(fd,1); os.close(fd); "
              "os.execvpe(sys.argv[2],sys.argv[2:],os.environ) if go==b'g' else os._exit(125)")
    try:
        process = subprocess.Popen([sys.executable, "-c", loader, str(ready_read), *command],
                                   cwd=str(root), env=environment,
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True, pass_fds=(fd, ready_read) + _heavy_fds())
        processes.append(process)
        identity = process_identity(process.pid)
        if identity is None:
            raise ContainmentError("new group identity unavailable: {}".format(process.pid))
        data["groups"].append({"pgid": process.pid, "start_us": identity[1]})
        save_record(path, data)
        os.write(ready_write, b"g")
        return process
    finally:
        try:
            os.close(ready_read)
            os.close(ready_write)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def observe_exit(process: subprocess.Popen) -> Optional[int]:
    """Observe without reaping: a zombie pins the registered group's ID."""
    if _WAITID is None:
        raise ContainmentError("libc waitid WNOWAIT unavailable")
    info = _SigInfo()
    # Darwin sys/wait.h: P_PID=1, WEXITED=4, WNOHANG=1, WNOWAIT=0x20.
    if _WAITID(1, process.pid, ctypes.byref(info), 0x04 | 0x01 | 0x20):
        error = ctypes.get_errno()
        raise ContainmentError("libc waitid failed (errno {})".format(error))
    if not info.pid:
        return None
    if info.pid != process.pid or info.code not in (1, 2, 3):  # CLD_EXITED/KILLED/DUMPED
        raise ContainmentError("libc waitid returned invalid exit information")
    return info.status if info.code == 1 else -info.status


def _wait_smoke(end: float) -> None:
    """Verify libc WNOWAIT on our own short-lived child, before gate launch."""
    if _WAITID is None:
        raise ContainmentError("libc waitid WNOWAIT smoke test failed; nothing launched")
    child = subprocess.Popen([sys.executable, "-c", "import os; os._exit(7)"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    try:
        smoke_end = min(end, time.monotonic() + 2)
        while True:
            _bounded(smoke_end)
            status = observe_exit(child)
            if status is not None:
                if status != 7 or observe_exit(child) != 7 or child.returncode is not None:
                    raise ContainmentError("libc waitid WNOWAIT smoke test failed; nothing launched")
                break
            time.sleep(0.01)
    except ContainmentError as exc:
        raise ContainmentError("libc waitid WNOWAIT smoke test failed; nothing launched: {}".format(exc)) from exc
    finally:
        # This probe has no descendants and is not a registered group leader.
        child.kill()
        child.wait()


def _write_aggregate(path: Path, records: Sequence[Dict[str, Any]], expected: Optional[Sequence[str]]) -> None:
    if expected is not None and not expected:
        raise ValueError("empty shard plan")
    rows: List[Tuple[int, str]] = []
    for record in records:
        with record["receipt"].open(encoding="utf-8") as receipt:
            for line in receipt:
                row = line.rstrip("\r\n")
                if not row or row == RECEIPT_HEADER:
                    continue
                fields = row.split("\t")
                if len(fields) != 4 or int(fields[0]) < 1:
                    raise ValueError("invalid timing receipt row: {}".format(row))
                rows.append((int(fields[0]), row))
    rows.sort()
    # Write the receipt before refusing it: a red run keeps its per-stage
    # timings and exits as evidence, and the exit status is unchanged.
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as aggregate:
        aggregate.write(RECEIPT_HEADER + "\n")
        for _, row in rows:
            aggregate.write(row + "\n")
    if expected is not None:
        actual = [(ordinal, row.split("\t")[1]) for ordinal, row in rows]
        if actual != list(enumerate(expected, 1)):
            raise ValueError("incomplete receipt: missing/duplicate ordinal or stage")
    for _, row in rows:
        if int(row.split("\t")[3]) != 0:
            raise ValueError("nonzero timing receipt exit: {}".format(row))


def _write_scope_receipt(path: Path, selected: Sequence[str]) -> None:
    # The process-gate PG_TESTS_RECEIPT contract: exactly one newline-terminated line.
    # M counts the unique selected files; an unselected run is the full suite.
    line = "PG_TESTS_RECEIPT narrowed {}\n".format(len(selected)) if selected else "PG_TESTS_RECEIPT full\n"
    with path.open("w", encoding="utf-8") as receipt:
        receipt.write(line)


def _replay_output(records: Sequence[Dict[str, Any]]) -> None:
    output = sys.stdout.buffer
    for record in records:
        data = record["output"].read_bytes()
        if data:
            output.write(data)
            if not data.endswith(b"\n"):
                output.write(b"\n")
    output.flush()


def _usage() -> str:
    return "usage: scripts/run-tests-local.py [--no-wait|--runs-status|--runs-reap|--verdict-status [--head=COMMIT]|--test-file=scripts/tests/NAME.bats ...]"


def main(argv: Sequence[str]) -> int:
    global SHARD_COUNT
    for name, value in sorted(os.environ.items()):
        if name.startswith("TRELLIS_LOCAL_GATE_") or name in ("TRELLIS_GATE_STATE_DIR", "TRELLIS_TEST_SHARDS"):
            print("run-tests-local: seam active {}={}".format(name, value), file=sys.stderr)
    if argv in (["-h"], ["--help"]):
        print(_usage())
        return 0
    if argv and argv[0] == "--verdict-status":
        if len(argv) > 2 or (len(argv) == 2 and not re.fullmatch(r"--head=[0-9a-f]{40,64}", argv[1])):
            return 64
        root = Path(__file__).resolve().parent.parent
        record = find_verdict(safe_inputs(root, argv[1][7:] if len(argv) == 2 else "HEAD"))
        if record is None:
            return 1
        print(describe_verdict(record))
        return 0
    selected: List[str] = []
    selection_args = [arg for arg in argv if arg != "--no-wait"]
    if selection_args and argv.count("--no-wait") <= 1 and all(
            re.fullmatch(r"--test-file=scripts/tests/[A-Za-z0-9_-]+\.bats", arg) for arg in selection_args):
        selected = list(dict.fromkeys(selection_args))
    if argv and not selected and argv not in (["--no-wait"], ["--runs-status"], ["--runs-reap"]):
        print("run-tests-local: invalid arguments\n" + _usage(), file=sys.stderr)
        return 64
    try:
        SHARD_COUNT = select_shard_count()
    except ValueError as exc:
        print("run-tests-local: {}".format(exc), file=sys.stderr)
        return 64
    if argv == ["--runs-status"]:
        try:
            root = gate_state_root()
        except (OSError, ValueError) as exc:
            print("run-tests-local: {}".format(exc), file=sys.stderr)
            return 70
        records = sorted((root / "runs").glob("*.json"))
        corrupt = False
        for path in records:
            print(path)
            try:
                _read_record(path)
            except (ContainmentError, OSError) as exc:
                print("run-tests-local: quarantined {}: {}".format(path, exc), file=sys.stderr)
                corrupt = True
        return 70 if corrupt else 1 if records else 0

    root = Path(__file__).resolve().parent.parent
    aggregate = None
    configured = os.environ.get("TRELLIS_LOCAL_GATE_RECEIPT")
    # Consume the gate's parent-only interface before fingerprinting the suite
    # environment. Receipt paths are not test inputs; narrowed argv never seals
    # a full verdict, and an explicit pushed head still must match the checkout.
    scope_path = os.environ.pop("PG_TESTS_RECEIPT_FILE", "")
    scope_receipt = Path(scope_path) if scope_path else None
    gated_head = os.environ.pop("PG_TESTS_HEAD", "HEAD")
    os.environ.pop("PG_TESTS_BASE", None)
    if argv in ([], ["--no-wait"]) or selected:
        # START precedes admission; a configured receipt retains refusals too.
        # Tool/release probes are read-only; no Trellis command is invoked.
        provenance = safe_capture(root, [sys.executable, str(Path(__file__).resolve()), *argv])
        try:
            if configured:
                aggregate = _resolve_path(root, configured)
        except (OSError, ValueError, RuntimeError):
            provenance["provenance_sidecar"] = "unavailable: receipt allocation failed"
        emit(provenance, aggregate)
    # Bounded START probes are outside the productive/cleanup deadline budget.
    # Keep the wall/monotonic admission clocks paired for containment accounting.
    started_us = time.time_ns() // 1000
    started = time.monotonic()
    try:
        deadline = _positive_float("TRELLIS_LOCAL_GATE_DEADLINE", GLOBAL_DEADLINE_SECONDS)
        if deadline > GLOBAL_DEADLINE_SECONDS:
            raise ValueError("TRELLIS_LOCAL_GATE_DEADLINE must not exceed 7200 seconds")
        reserve = _positive_float("TRELLIS_LOCAL_GATE_RESERVE", TEARDOWN_RESERVE_SECONDS)
        grace = _positive_float("TRELLIS_LOCAL_GATE_TERM_GRACE", TERM_GRACE_SECONDS)
        if reserve >= deadline or grace >= reserve:
            raise ValueError("require TERM grace < reserve < deadline (scale test seams together)")
    except ValueError as exc:
        print("run-tests-local: {}".format(exc), file=sys.stderr)
        return 64
    deadline_at = started + deadline
    productive_at = deadline_at - reserve
    state = None
    inputs = None
    after_inputs = None
    kept = None
    try:
        state = RunState(head=provenance.get("head", "unknown") if argv != ["--runs-reap"] else "reap",
                         no_wait="--no-wait" in argv)
        # Queue waiting is outside both the productive and cleanup deadline.
        started_us = time.time_ns() // 1000
        started = time.monotonic()
        deadline_at = started + deadline
        productive_at = deadline_at - reserve
        if argv != ["--runs-reap"]:
            _invalidate_verdicts(state, root, productive_at)
        # Quarantine corruption by name even if a host capability is also
        # unavailable. No source failure can make a durable record disappear.
        for path in state.records():
            _read_record(path)
        _prune_failed_shards(state)
        if argv == ["--runs-reap"] and not state.records():
            state.close()
            return 0
        # Boot-aware sweeps do not need child wait observation or a global fd
        # preflight: earlier-boot records must be deleted without signalling.
        _capability(productive_at, require_wait=False, full_scan=False)
        if not sweep_records(state, reserve, grace, productive_at):
            state.close()
            return 70
        if argv == ["--runs-reap"]:
            state.close()
            return 0
        unreadable = _capability(productive_at, started_us=started_us)
        _heavy_fds()
        data, record_path, sentinel_fd = _new_run(state, root, productive_at, started_us, started, unreadable)
    except (ContainmentError, OSError) as exc:
        print("run-tests-local: {}".format(exc), file=sys.stderr)
        if state is not None:
            state.close()
        try:
            retained = any((gate_state_root() / "runs").glob("*.json"))
        except (OSError, ValueError):
            retained = False  # Invalid roots are refused before creating state.
        _receipt({"token": "unstarted"}, 1, retained)
        return 70

    runner = _resolve_path(root, os.environ.get("TRELLIS_LOCAL_GATE_RUNNER", "scripts/run-tests.sh"))
    run_root = Path(data["run_root"])
    environment = os.environ.copy()
    # TRELLIS_TEST_TSV is runner-owned: an outer gate's shard exports it, and a
    # nested runner must not hand that receipt path to its own planner.
    environment.pop("TRELLIS_TEST_TSV", None)
    environment.pop("TRELLIS_TEST_PROVENANCE_RECEIPT", None)
    # Scoped-gate variables describe the parent's range; descendants never receive them.
    for name in ("PG_TESTS_BASE", "PG_TESTS_HEAD", "PG_TESTS_RECEIPT_FILE", "PG_PUSH_TEST_SCOPE"):
        environment.pop(name, None)
    environment["TRELLIS_GATE_RUN_ID"] = data["token"]
    environment["TMPDIR"] = str(run_root / "tmp")
    environment["TRELLIS_GATE_STATE_DIR"] = str(run_root / "state")
    processes: List[subprocess.Popen] = []
    shards: List[Dict[str, Any]] = []
    interrupt = None
    result = 1
    survivors = 1
    old_handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM)}

    def interrupted(signum: int, _frame: Any) -> None:
        nonlocal interrupt
        if interrupt is None:
            interrupt = signum
        raise _SignalExit(signum)

    def expired(_signum: int, _frame: Any) -> None:
        raise _DeadlineExit()

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGALRM, expired)
    try:
        if productive_at <= time.monotonic():
            raise _DeadlineExit()
        signal.setitimer(signal.ITIMER_REAL, productive_at - time.monotonic())
        if not configured:
            # Allocate once, only after admission; unbound refusals leave no files.
            fd, name = tempfile.mkstemp(prefix="trellis-run-tests-aggregate-", suffix=".tsv")
            os.close(fd)
            aggregate = Path(name)
            emit(provenance, aggregate, stderr=False)
        if aggregate is None:
            raise ValueError("timing receipt unavailable")
        planner_output = run_root / "planner.out"

        def contained_probe(command: Sequence[str], env: Dict[str, str], cwd: Path) -> str:
            # Version probes are registered groups with the same sentinel/token
            # as shards, and all run before the final verified-empty scan.
            probe_env = dict(env, TRELLIS_GATE_RUN_ID=data["token"], TMPDIR=str(run_root / "tmp"))
            with planner_output.open("wb") as stream:
                process = _spawn(data, record_path, sentinel_fd, processes, command, cwd, probe_env, stream)
                end = time.monotonic() + 2
                while observe_exit(process) is None:
                    if time.monotonic() >= end:
                        return "unavailable: probe timeout"
                    time.sleep(0.01)
            if observe_exit(process):
                return "unavailable: probe exit {}".format(observe_exit(process))
            lines = planner_output.read_text(encoding="utf-8", errors="replace").strip().splitlines()
            return lines[0] if lines else "unavailable: empty probe"

        inputs = None if selected else safe_inputs(root, gated_head, version_probe=contained_probe)
        with planner_output.open("wb") as stream:
            planner = _spawn(data, record_path, sentinel_fd, processes,
                             ["bash", str(runner), "--scope=local", "--shard=1/{}".format(SHARD_COUNT), "--plan", *selected],
                             root, environment, stream)
            while observe_exit(planner) is None:
                state.check()
                time.sleep(0.02)
        plan = planner_output.read_text(encoding="utf-8")
        planner_status = observe_exit(planner)
        if planner_status != 0:
            raise ValueError("shard plan failed with status {}: {}".format(planner_status, plan.strip()))
        totals = {}
        expected = []
        for line in plan.splitlines():
            fields = line.split("\t")
            if len(fields) == 3 and fields[0] == "total":
                totals[int(fields[1])] = fields[2]
            elif len(fields) == 3 and fields[0].isdigit():
                expected.append(fields[1])
        if not expected:
            raise ValueError("empty shard plan")
        if set(totals) != set(range(1, SHARD_COUNT + 1)):
            raise ValueError("shard plan missing total rows")
        print("run-tests-local: planned shard totals: " + ", ".join(
            "shard {}={}".format(i, totals[i]) for i in range(1, SHARD_COUNT + 1)), flush=True)
        # Only shards are niced: the planner above keeps inherited priority.
        shard_prefix, priority = _shard_priority(environment)
        emit({"phase": "shard-priority", "priority": priority}, aggregate)
        for shard in range(1, SHARD_COUNT + 1):
            state.check()
            output_path = run_root / "shard-{}.out".format(shard)
            receipt_path = run_root / "shard-{}.tsv".format(shard)
            receipt_path.write_text(RECEIPT_HEADER + "\n", encoding="utf-8")
            entry = {"shard": shard, "output": output_path, "receipt": receipt_path,
                     "started": time.monotonic(), "finished": None, "process": None}
            shards.append(entry)
            with output_path.open("wb") as stream:
                shard_environment = environment.copy()
                shard_environment["TRELLIS_TEST_TSV"] = str(receipt_path)
                shard_environment["TRELLIS_TEST_PROVENANCE_RECEIPT"] = str(aggregate)
                try:
                    entry["process"] = _spawn(data, record_path, sentinel_fd, processes,
                        [*shard_prefix, "bash", str(runner), "--scope=local", "--shard={}/{}".format(shard, SHARD_COUNT), *selected],
                        root, shard_environment, stream)
                except OSError as exc:
                    stream.write("run-tests-local: could not start shard {}: {}\n".format(shard, exc).encode())
        while any(entry["process"] is not None and observe_exit(entry["process"]) is None for entry in shards):
            state.check()
            for entry in shards:
                if entry["process"] is not None and observe_exit(entry["process"]) is not None and entry["finished"] is None:
                    entry["finished"] = time.monotonic()
            time.sleep(0.02)
        _replay_output(shards)
        for entry in shards:
            status = observe_exit(entry["process"]) if entry["process"] is not None else 127
            print("run-tests-local: shard {}/{} elapsed_seconds={:.3f} status={}".format(
                entry["shard"], SHARD_COUNT, (entry["finished"] or time.monotonic()) - entry["started"], status))
        _write_aggregate(aggregate, shards, expected)
        print("run-tests-local: aggregate receipt: {}".format(aggregate), flush=True)
        result = 0 if len(shards) == SHARD_COUNT and all(
            e["process"] is not None and observe_exit(e["process"]) == 0 for e in shards) else 1
        if result == 0 and inputs is not None:
            after_inputs = None if selected else safe_inputs(root, gated_head, version_probe=contained_probe)
    except _DeadlineExit:
        print("run-tests-local: global deadline exceeded (productive cutoff)", file=sys.stderr)
        result = 124
    except _SignalExit as exc:
        print("run-tests-local: interrupted by {}".format(signal.Signals(exc.signum).name), file=sys.stderr)
        result = 128 + exc.signum
    except (OSError, ValueError) as exc:
        print("run-tests-local: {}".format(exc), file=sys.stderr)
        result = 1
    except ContainmentError as exc:
        print("run-tests-local: {}".format(exc), file=sys.stderr)
        result = 71
    finally:
        # A pending alarm can be delivered at this call; the itimer is one-shot,
        # so retry until the disarm itself completes.
        while True:
            try:
                signal.setitimer(signal.ITIMER_REAL, 0)
                break
            except _DeadlineExit:
                continue
        # Further interrupts must not interrupt teardown and falsely release a
        # slot. SIGKILL instead leaves the durable quarantine record.
        def remember(signum: int, _frame: Any) -> None:
            nonlocal interrupt
            interrupt = interrupt or signum
        signal.signal(signal.SIGINT, remember)
        signal.signal(signal.SIGTERM, remember)
        teardown_end = min(deadline_at, time.monotonic() + reserve)
        signal.setitimer(signal.ITIMER_REAL, max(0.000001, teardown_end - time.monotonic()))
        try:
            survivors = Boundary(data, live=True, record_path=record_path).teardown(teardown_end, grace)
            if not survivors:
                # Only after two verified-empty scans may leaders be reaped.
                for process in processes:
                    process.wait()
                _retain_failed_shards(state, data, shards)
                if result == 0 and interrupt is None:
                    state.check()
                    try:
                        kept = _persist_passing_aggregate(state, data, aggregate, root, teardown_end)
                    except (OSError, ValueError, ContainmentError) as exc:
                        print("run-tests-local: could not retain passing aggregate: {}".format(exc), file=sys.stderr)
                _delete_empty_record(record_path, data)
        except (OSError, ContainmentError, _DeadlineExit) as exc:
            survivors = max(1, survivors)
            # Don't attempt an unbounded diagnostic after a reserve alarm.
            if not isinstance(exc, _DeadlineExit):
                print("run-tests-local: teardown failed: {}".format(exc), file=sys.stderr)
        finally:
            # A pending alarm can be delivered at this call; the itimer is one-shot,
            # so retry until the disarm itself completes.
            while True:
                try:
                    signal.setitimer(signal.ITIMER_REAL, 0)
                    break
                except _DeadlineExit:
                    continue
            os.close(sentinel_fd)
            # Keep queue ownership through the final receipt and verdict commit.
            # Final receipt output is inside the same hard deadline as cleanup.
            signal.setitimer(signal.ITIMER_REAL, max(0.001, deadline_at - time.monotonic()))
            try:
                _receipt(data, survivors, record_path.exists())
                if not survivors and not result and interrupt is None and kept is not None:
                    _write_verdict(state, inputs, after_inputs, kept)
            except (_DeadlineExit, OSError):
                result = 124 if not survivors else 71
            else:
                # The scope receipt needs a clean aggregate, empty teardown and no signal;
                # a write failure fails the run closed.
                if result == 0 and not survivors and interrupt is None and scope_receipt is not None:
                    try:
                        _write_scope_receipt(scope_receipt, selected)
                    except _DeadlineExit:
                        result = 124
                    except OSError as exc:
                        print("run-tests-local: could not write PG_TESTS_RECEIPT_FILE: {}".format(exc), file=sys.stderr)
                        result = 1
            finally:
                # A pending alarm can be delivered at this call; the itimer is one-shot,
                # so retry until the disarm itself completes.
                while True:
                    try:
                        signal.setitimer(signal.ITIMER_REAL, 0)
                        break
                    except _DeadlineExit:
                        continue
                try:
                    state.close(deadline_at)
                except ContainmentError as exc:
                    print("run-tests-local: {}".format(exc), file=sys.stderr)
                    result = 71
                for signum, handler in old_handlers.items():
                    signal.signal(signum, handler)
    if (survivors or interrupt is not None or result) and inputs is not None:
        # A deadline/interrupt during finalization must not leave a reusable pass.
        path = state.root / "verdicts" / (verdict_key(inputs) + ".json")
        try:
            if json.loads(path.read_text(encoding="utf-8"))["id"] == data["token"]:
                path.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return 71 if survivors else (128 + interrupt if interrupt is not None else result)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
