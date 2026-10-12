"""Injected libproc exit races; no host process enumeration or test children."""
import contextlib
import ctypes
import errno
import importlib.util
import io
import os
from pathlib import Path
import signal
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "runner_process_race", Path(__file__).resolve().parents[1] / "run-tests-local.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
PID = 987654321


def data():
    return {"token": "race", "owner": {"pid": os.getpid(), "start_us": 1},
            "started_us": 1, "run_root": "/tmp/runner-race-unit", "groups": [],
            "sentinel_id": {"dev": 42, "ino": 43}}


class ProcessList:
    """PID remains in both enumeration snapshots; BSD inspection then fails."""
    def __init__(self, error):
        self.error = error
        self.subject_reads = 0

    def proc_listallpids(self, buffer, size):
        if buffer is not None:
            buffer[0], buffer[1] = os.getpid(), PID
        return 2

    def proc_listpids(self, kind, uid, buffer, size):
        buffer[0], buffer[1] = os.getpid(), PID
        return 2 * ctypes.sizeof(ctypes.c_int)

    def proc_pidinfo(self, pid, flavor, arg, buffer, size):
        assert flavor == 3
        if pid == PID and self.error is not None:
            self.subject_reads += 1
            ctypes.set_errno(self.error)
            return 0
        info = ctypes.cast(buffer, ctypes.POINTER(GATE._BSDInfo)).contents
        info.pid, info.ppid, info.uid, info.start_sec = pid, 1, os.getuid(), 1
        return ctypes.sizeof(info)


class FileReader:
    def __init__(self, stage, error):
        self.stage, self.error = stage, error

    def fail(self, result):
        ctypes.set_errno(self.error)
        return result

    def proc_pidinfo(self, pid, flavor, arg, buffer, size):
        if flavor == 1:
            if buffer is None:
                if self.stage == "fd-size":
                    return self.fail(-1)
                return ctypes.sizeof(GATE._FDInfo) if self.stage == "vnode" else 0
            if self.stage == "fd-list":
                return self.fail(-1)
            if self.stage == "vnode":
                buffer[0].fd, buffer[0].type = 7, 1
                return ctypes.sizeof(GATE._FDInfo)
            return 0
        assert flavor == 9
        if self.stage == "cwd":
            return self.fail(0)
        return size

    def proc_pidfdinfo(self, *args):
        assert self.stage == "vnode"
        return self.fail(0)


class ArgReader:
    def __init__(self, error):
        self.error = error

    def sysctl(self, *args):
        ctypes.set_errno(self.error)
        return -1


class VanishedProcessTests(unittest.TestCase):
    def test_esrch_between_list_and_inspect_never_becomes_survivor(self):
        with mock.patch.object(GATE, "_LIBPROC", ProcessList(errno.ESRCH)), \
                mock.patch.object(GATE.os, "kill") as kill, \
                mock.patch.object(GATE, "signal_member") as signal_member:
            table = GATE.process_table(time.monotonic() + 1)
            self.assertEqual(set(table), {os.getpid()})
            boundary = GATE.Boundary(data())
            self.assertEqual(boundary.teardown(time.monotonic() + 1, .1), 0)
            self.assertFalse(boundary.ambiguous)
            kill.assert_not_called()
            signal_member.assert_not_called()

    def test_short_bsd_read_rechecked_absent_does_not_block_preflight(self):
        for error in (0, errno.EIO, errno.EINVAL, errno.EPERM, errno.EACCES):
            with self.subTest(error=error), \
                    mock.patch.object(GATE, "_LIBPROC", ProcessList(error)), \
                    mock.patch.object(GATE.os, "kill", side_effect=ProcessLookupError(errno.ESRCH, "gone")) as kill, \
                    mock.patch.object(GATE, "signal_member") as signal_member:
                self.assertEqual(set(GATE.process_table(time.monotonic() + 1)), {os.getpid()})
                boundary = GATE.Boundary(data())
                self.assertEqual(boundary.teardown(time.monotonic() + 1, .1), 0)
                self.assertFalse(boundary.ambiguous)
                with mock.patch.object(GATE, "process_identity", return_value=(os.getpid(), 1000000)), \
                        mock.patch.object(GATE, "boot_session", return_value="fixture"), \
                        mock.patch.object(GATE, "_LIBC") as libc, \
                        mock.patch.object(GATE, "parse_environment", return_value=set()), \
                        mock.patch.object(GATE, "process_files", return_value=[]), \
                        mock.patch.object(GATE, "process_environment", return_value=set()):
                    libc.sysctl.return_value = 0
                    self.assertEqual(GATE._capability(time.monotonic() + 1,
                        require_wait=False, started_us=1), [])
                self.assertTrue(kill.called)
                self.assertTrue(all(call.args == (PID, 0) for call in kill.call_args_list))
                signal_member.assert_not_called()

    def test_exit_during_each_file_reader_returns_no_stale_ownership(self):
        for stage in ("fd-size", "fd-list", "vnode", "cwd"):
            for error in (0, errno.ESRCH, errno.EIO, errno.EPERM, errno.EACCES):
                with self.subTest(stage=stage, error=error), \
                        mock.patch.object(GATE, "_LIBPROC", FileReader(stage, error)), \
                        mock.patch.object(GATE.os, "kill", side_effect=ProcessLookupError(errno.ESRCH, "gone")):
                    self.assertEqual(GATE.process_files(PID, time.monotonic() + 1), [])

    def test_argument_esrch_does_not_reinspect_an_exited_pid(self):
        with mock.patch.object(GATE, "_LIBC", ArgReader(errno.ESRCH)), \
                mock.patch.object(GATE, "bsd_info") as inspection:
            self.assertEqual(GATE.process_environment(PID), set())
            inspection.assert_not_called()

    def test_signal_identity_recheck_accepts_positive_death_without_signaling(self):
        with mock.patch.object(GATE, "process_identity", return_value=None), \
                mock.patch.object(GATE, "_LIBPROC", ProcessList(0)), \
                mock.patch.object(GATE.os, "kill", side_effect=ProcessLookupError(errno.ESRCH, "gone")) as kill:
            self.assertTrue(GATE.signal_member((PID, 1000000), signal.SIGTERM))
            kill.assert_called_once_with(PID, 0)


class LiveUnreadableTests(unittest.TestCase):
    def test_live_unreadable_bsd_row_keeps_fail_closed_quarantine(self):
        for error in (0, errno.EIO, errno.EINVAL, errno.EPERM, errno.EACCES):
            proc = ProcessList(error)
            with self.subTest(error=error), mock.patch.object(GATE, "_LIBPROC", proc), \
                    mock.patch.object(GATE.os, "kill", return_value=None), \
                    mock.patch.object(GATE, "signal_member") as signal_member:
                with self.assertRaises(GATE.ContainmentError) as caught:
                    GATE.process_table(time.monotonic() + 1)
                self.assertEqual(caught.exception.error, error)
                self.assertEqual(proc.subject_reads, 1 if error in (errno.EPERM, errno.EACCES) else 2)
                with self.assertRaises(GATE.ContainmentError):
                    GATE._capability(time.monotonic() + 1, require_wait=False, started_us=1)
                boundary = GATE.Boundary(data())
                ticks = iter(range(1000))
                with contextlib.redirect_stderr(io.StringIO()) as stderr, \
                        mock.patch.object(GATE.time, "monotonic", side_effect=lambda: next(ticks) / 1000), \
                        mock.patch.object(GATE.time, "sleep"):
                    self.assertGreater(boundary.teardown(.03, .01), 0)
                self.assertTrue(boundary.ambiguous)
                self.assertIn("PROC_PIDTBSDINFO unavailable", stderr.getvalue())
                signal_member.assert_not_called()

    def test_inconclusive_existence_probe_cannot_erase_inspection_failure(self):
        for probe_error in (PermissionError(errno.EPERM, "protected"), OSError(errno.EIO, "probe failed")):
            with self.subTest(probe_error=probe_error), \
                    mock.patch.object(GATE, "_LIBPROC", ProcessList(errno.EINVAL)), \
                    mock.patch.object(GATE.os, "kill", side_effect=probe_error):
                with self.assertRaises(GATE.ContainmentError) as caught:
                    GATE.bsd_info(PID)
                self.assertEqual(caught.exception.error, errno.EINVAL)

    def test_live_file_reader_errors_retain_their_original_classification(self):
        for stage in ("fd-size", "fd-list", "vnode", "cwd"):
            for error in (0, errno.EIO, errno.EPERM, errno.EACCES):
                expected = GATE.UnreadableProcess if error in (errno.EPERM, errno.EACCES) else GATE.ContainmentError
                with self.subTest(stage=stage, error=error), \
                        mock.patch.object(GATE, "_LIBPROC", FileReader(stage, error)), \
                        mock.patch.object(GATE.os, "kill", return_value=None):
                    with self.assertRaises(expected):
                        GATE.process_files(PID, time.monotonic() + 1)

    def test_readable_bsd_row_needs_no_existence_probe(self):
        with mock.patch.object(GATE, "_LIBPROC", ProcessList(None)), \
                mock.patch.object(GATE.os, "kill") as kill:
            self.assertEqual(set(GATE.process_table(time.monotonic() + 1)), {os.getpid(), PID})
            kill.assert_not_called()

    def test_live_argument_errors_keep_eio_and_permission_semantics(self):
        info = GATE._BSDInfo()
        info.pid, info.status = PID, 2
        for error in (errno.EIO, errno.EINVAL, errno.EPERM, errno.EACCES):
            with self.subTest(error=error), mock.patch.object(GATE, "_LIBC", ArgReader(error)), \
                    mock.patch.object(GATE, "bsd_info", return_value=info):
                if error == errno.EIO:
                    self.assertIsNone(GATE.process_environment(PID))
                else:
                    expected = GATE.UnreadableProcess if error in (errno.EPERM, errno.EACCES) else GATE.ContainmentError
                    with self.assertRaises(expected):
                        GATE.process_environment(PID)

    def test_unreadable_signal_identity_still_refuses_authority(self):
        with mock.patch.object(GATE, "process_identity", return_value=None), \
                mock.patch.object(GATE, "_LIBPROC", ProcessList(errno.EPERM)), \
                mock.patch.object(GATE.os, "kill", return_value=None) as kill:
            self.assertFalse(GATE.signal_member((PID, 1000000), signal.SIGTERM))
            kill.assert_called_once_with(PID, 0)


if __name__ == "__main__":
    unittest.main()
