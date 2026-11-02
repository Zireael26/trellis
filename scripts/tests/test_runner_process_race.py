"""Injected libproc exit races; no host process enumeration or test children."""
import ast
import contextlib
import ctypes
import errno
import importlib.util
import io
import os
from pathlib import Path
import signal
import tempfile
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
        if flavor != 3:
            ctypes.set_errno(self.error or errno.EIO)
            return 0  # No independent metadata source in this fixture.
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


class PartialProcessList(ProcessList):
    """The full BSD read fails; independent short membership remains readable."""
    def __init__(self, error=errno.EIO, pgid=PID + 1, short_error=None):
        super().__init__(error)
        self.pgid, self.short_error = pgid, short_error
        self.short_reads = 0

    def proc_pidinfo(self, pid, flavor, arg, buffer, size):
        if flavor != 13:
            return super().proc_pidinfo(pid, flavor, arg, buffer, size)
        self.short_reads += 1
        if self.short_error is not None:
            ctypes.set_errno(self.short_error)
            return 0
        info = ctypes.cast(buffer, ctypes.POINTER(GATE._ShortBSDInfo)).contents
        info.pid, info.ppid, info.pgid = pid, 1, self.pgid
        info.uid, info.status = os.getuid(), 2
        return ctypes.sizeof(info)


class MembershipFallbackTests(unittest.TestCase):
    @contextlib.contextmanager
    def readable_membership(self, **kwargs):
        proc = PartialProcessList(**kwargs)
        with mock.patch.object(GATE, "_LIBPROC", proc), \
                mock.patch.object(GATE.os, "kill", return_value=None), \
                mock.patch.object(GATE.os, "getsid", return_value=PID + 1), \
                mock.patch.object(GATE, "process_files", return_value=[]), \
                mock.patch.object(GATE, "process_environment", return_value=set()), \
                mock.patch.object(GATE, "signal_member") as signal_member:
            yield proc, signal_member

    def run_data(self):
        record = data()
        record["groups"] = [{"pgid": PID - 1, "start_us": 1}]
        record["started_us"] = 2000000
        return record

    def test_unrelated_failed_bsd_read_does_not_quarantine(self):
        for error in (0, errno.EIO, errno.EINVAL, errno.EPERM, errno.EACCES):
            with self.subTest(error=error), self.readable_membership(error=error) as (proc, signals):
                table = GATE.process_table(time.monotonic() + 1)
                self.assertEqual(set(table), {os.getpid(), PID})
                self.assertEqual(GATE._birth(table[PID]), 0, "fallback fabricated a birth")
                self.assertEqual(proc.subject_reads, 1 if error in (errno.EPERM, errno.EACCES) else 2)
                self.assertEqual(proc.short_reads, 1)
                for live in (True, False):
                    boundary = GATE.Boundary(self.run_data(), live=live)
                    self.assertEqual(boundary.teardown(time.monotonic() + 1, .01), 0)
                    self.assertFalse(boundary.ambiguous)
                with mock.patch.object(GATE, "process_identity", return_value=(os.getpid(), 1000000)), \
                        mock.patch.object(GATE, "boot_session", return_value="fixture"), \
                        mock.patch.object(GATE, "_LIBC") as libc, \
                        mock.patch.object(GATE, "parse_environment", return_value=set()):
                    libc.sysctl.return_value = 0
                    self.assertEqual(GATE._capability(time.monotonic() + 1,
                        require_wait=False, started_us=2000000), [])
                signals.assert_not_called()

    def test_partial_group_and_session_members_fail_closed(self):
        for source in ("group", "session"):
            with self.subTest(source=source), self.readable_membership(
                    pgid=PID - 1 if source == "group" else PID + 1) as (_, signals):
                for live in (True, False):
                    with mock.patch.object(GATE.os, "getsid", return_value=PID - 1 if source == "session" else PID + 1):
                        boundary = GATE.Boundary(self.run_data(), live=live)
                        with self.assertRaisesRegex(GATE.ContainmentError, "PROC_PIDTBSDINFO unavailable"):
                            boundary.scan(time.monotonic() + 1)
                        with contextlib.redirect_stderr(io.StringIO()):
                            self.assertGreater(boundary.teardown(time.monotonic() + .08, .01), 0)
                        self.assertTrue(boundary.ambiguous)
                        signals.assert_not_called()

    def test_detached_partial_rows_keep_all_structural_membership_checks(self):
        for source in ("sentinel", "tmp", "output", "environment", "descendant"):
            with self.subTest(source=source), self.readable_membership() as (_, signals):
                record = self.run_data()
                record["output_ids"] = [{"dev": 44, "ino": 45}]
                files = {"sentinel": [((42, 43), "/renamed-sentinel")],
                         "tmp": [((0, 0), record["run_root"] + "/tmp/held")],
                         "output": [((44, 45), "/renamed-output")]}.get(source, [])
                environment = {b"TRELLIS_GATE_RUN_ID=race"} if source == "environment" else set()
                # Unknown birth must not be mistaken for a pre-run process.
                table = GATE.process_table(time.monotonic() + 1)
                if source == "descendant":
                    parent = GATE._BSDInfo()
                    parent.pid, parent.ppid, parent.pgid = PID - 2, 1, PID - 1
                    parent.uid, parent.start_sec = os.getuid(), 3
                    table[parent.pid] = parent
                    table[PID].ppid = parent.pid
                with mock.patch.object(GATE, "process_table", return_value=table), \
                        mock.patch.object(GATE, "process_files", return_value=files), \
                        mock.patch.object(GATE, "process_environment", return_value=environment):
                    with self.assertRaisesRegex(GATE.ContainmentError, "PROC_PIDTBSDINFO unavailable"):
                        GATE.Boundary(record, live=True).scan(time.monotonic() + 1)
                    signals.assert_not_called()

    def test_partial_unreadable_rows_cannot_be_excluded_or_recorded(self):
        for source in ("process_files", "process_environment"):
            with self.subTest(source=source), self.readable_membership() as (_, signals), \
                    mock.patch.object(GATE, source, side_effect=GATE.UnreadableProcess("protected")):
                record = self.run_data()
                with self.assertRaisesRegex(GATE.ContainmentError, "unreadable membership"):
                    GATE.Boundary(record).scan(time.monotonic() + 1)
                self.assertNotIn("unreadable_excluded", record)
                with mock.patch.object(GATE, "process_identity", return_value=(os.getpid(), 1000000)), \
                        mock.patch.object(GATE, "boot_session", return_value="fixture"), \
                        mock.patch.object(GATE, "_LIBC") as libc, \
                        mock.patch.object(GATE, "parse_environment", return_value=set()):
                    libc.sysctl.return_value = 0
                    # The capability smoke read of our own files must succeed.
                    def protected(pid, *args):
                        if pid == os.getpid():
                            return []
                        raise GATE.UnreadableProcess("protected")
                    getattr(GATE, source).side_effect = protected
                    with self.assertRaisesRegex(GATE.ContainmentError, "unreadable preflight membership"):
                        GATE._capability(time.monotonic() + 1, require_wait=False, started_us=2000000)
                signals.assert_not_called()

    def test_partial_member_death_after_session_read_is_not_sticky(self):
        with self.readable_membership() as (_, signals):
            exited = [False]
            def session(pid):
                exited[0] = True
                return PID - 1
            def existence(pid, signum):
                self.assertEqual(signum, 0)
                if pid == PID and exited[0]:
                    raise ProcessLookupError(errno.ESRCH, "gone after session read")
            with mock.patch.object(GATE.os, "getsid", side_effect=session), \
                    mock.patch.object(GATE.os, "kill", side_effect=existence):
                boundary = GATE.Boundary(self.run_data(), live=True)
                self.assertEqual(boundary.teardown(time.monotonic() + 1, .01), 0)
                self.assertFalse(boundary.ambiguous)
                signals.assert_not_called()

    def test_recovered_birth_does_not_authorize_signaling_a_partial_member(self):
        with self.readable_membership(pgid=PID - 1) as (_, signals):
            table = GATE.process_table(time.monotonic() + 1)
            fresh = GATE._BSDInfo()
            fresh.pid, fresh.status, fresh.start_sec = PID, 2, 3
            with mock.patch.object(GATE, "process_table", return_value=table), \
                    mock.patch.object(GATE, "bsd_info", return_value=fresh):
                self.assertEqual(GATE.Boundary(self.run_data(), live=True).scan(
                    time.monotonic() + 1), {PID: None})
                fresh.status = 5
                self.assertEqual(GATE.Boundary(self.run_data(), live=True).scan(
                    time.monotonic() + 1), {})
                signals.assert_not_called()

    def test_session_errors_stay_closed_unless_positive_death(self):
        for error in (errno.ESRCH, errno.EPERM, errno.EIO):
            with self.subTest(error=error), self.readable_membership() as (_, signals), \
                    mock.patch.object(GATE.os, "getsid", side_effect=OSError(error, "session")):
                boundary = GATE.Boundary(self.run_data(), live=True)
                if error == errno.ESRCH:
                    self.assertEqual(boundary.scan(time.monotonic() + 1), {})
                else:
                    with self.assertRaisesRegex(GATE.ContainmentError, "session unavailable"):
                        boundary.scan(time.monotonic() + 1)
                signals.assert_not_called()

    def test_unavailable_or_inconsistent_short_metadata_stays_closed(self):
        for error in (errno.EINVAL, errno.EPERM):
            with self.subTest(error=error), self.readable_membership(short_error=error) as (_, signals):
                with self.assertRaisesRegex(GATE.ContainmentError, "PROC_PIDTBSDINFO unavailable"):
                    GATE.process_table(time.monotonic() + 1)
                signals.assert_not_called()
        with self.readable_membership() as (proc, signals):
            original = proc.proc_pidinfo
            def wrong_pid(pid, flavor, arg, buffer, size):
                used = original(pid, flavor, arg, buffer, size)
                if flavor == 13:
                    ctypes.cast(buffer, ctypes.POINTER(GATE._ShortBSDInfo)).contents.pid += 1
                return used
            proc.proc_pidinfo = wrong_pid
            with self.assertRaisesRegex(GATE.ContainmentError, "PROC_PIDTBSDINFO unavailable"):
                GATE.process_table(time.monotonic() + 1)
            signals.assert_not_called()

    def test_native_short_bsd_layout_has_membership_but_no_birth(self):
        if GATE._LIBPROC is None:
            self.skipTest("requires native Darwin libproc")
        full = GATE.bsd_info(os.getpid())
        short = GATE._short_bsd_info(os.getpid())
        self.assertEqual(ctypes.sizeof(GATE._ShortBSDInfo), 64)
        for field in ("pid", "ppid", "pgid", "status", "uid"):
            self.assertEqual(getattr(short, field), getattr(full, field))
        self.assertEqual(GATE._birth(short), 0)

    def test_transient_retry_waits_once_without_overrunning_budget(self):
        for end, expected_reads in ((1, 2), (.005, 1)):
            now = [0.0]
            def sleep(delay):
                now[0] += delay
            reader = mock.Mock(side_effect=[GATE.ContainmentError("transient", errno.EIO), "recovered"])
            with self.subTest(end=end), mock.patch.object(GATE.time, "monotonic", side_effect=lambda: now[0]), \
                    mock.patch.object(GATE.time, "sleep", side_effect=sleep) as wait:
                if expected_reads == 2:
                    self.assertEqual(GATE._retry_pid(reader, end), "recovered")
                else:
                    with self.assertRaisesRegex(GATE.ContainmentError, "budget exhausted"):
                        GATE._retry_pid(reader, end)
                self.assertEqual(reader.call_count, expected_reads)
                wait.assert_called_once_with(min(.01, end))


class SecondaryReadTests(unittest.TestCase):
    def test_known_environment_errors_do_not_require_full_bsd_rereads(self):
        for error in (errno.EIO, errno.EPERM, errno.EACCES):
            with self.subTest(error=error), mock.patch.object(GATE, "_LIBC", ArgReader(error)), \
                    mock.patch.object(GATE, "bsd_info", side_effect=GATE.ContainmentError("full BSD unavailable")) as full:
                if error == errno.EIO:
                    self.assertIsNone(GATE.process_environment(PID))
                else:
                    with self.assertRaises(GATE.UnreadableProcess):
                        GATE.process_environment(PID)
                full.assert_not_called()

    def test_environment_race_reaches_admission_instead_of_unstarted_receipt(self):
        table = {}
        for pid, start in ((os.getpid(), 1), (PID, 2)):
            info = GATE._BSDInfo()
            info.pid, info.ppid, info.uid, info.status, info.start_sec = pid, 1, os.getuid(), 2, start
            table[pid] = info
        def arguments(mib, *args):
            ctypes.set_errno(errno.EIO if mib[2] == PID else 0)
            return -1 if mib[2] == PID else 0
        class Admitted(Exception):
            pass
        with tempfile.TemporaryDirectory(prefix="race-state-") as state_dir, \
                mock.patch.object(GATE, "process_table", return_value=table), \
                mock.patch.object(GATE, "process_identity", return_value=(os.getpid(), 1000000)), \
                mock.patch.object(GATE, "process_files", return_value=[]), \
                mock.patch.object(GATE, "boot_session", return_value="fixture"), \
                mock.patch.object(GATE, "parse_environment", return_value=set()), \
                mock.patch.object(GATE, "_LIBC") as libc, \
                mock.patch.object(GATE, "bsd_info", side_effect=GATE.ContainmentError(
                    "PROC_PIDTBSDINFO unavailable for pid {}".format(PID))), \
                mock.patch.object(GATE, "_wait_smoke"), \
                mock.patch.object(GATE, "RunState") as state, \
                mock.patch.object(GATE, "sweep_records", return_value=True), \
                mock.patch.object(GATE, "safe_capture", return_value={}), \
                mock.patch.object(GATE, "emit"), \
                mock.patch.object(GATE, "_heavy_fds"), \
                mock.patch.object(GATE, "_new_run", side_effect=Admitted), \
                mock.patch.object(GATE.time, "time_ns", return_value=1500000000), \
                contextlib.redirect_stdout(io.StringIO()) as stdout, \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            state.return_value.records.return_value = []
            state.return_value.root = Path(state_dir)
            libc.sysctl.side_effect = arguments
            try:
                result = GATE.main([])
            except Admitted:
                pass  # Stop before any planner, fixture root or child is created.
            else:
                self.fail("admission returned {}: {}{}".format(result, stderr.getvalue(), stdout.getvalue()))
            self.assertNotIn("run=unstarted", stdout.getvalue())

    def test_unreadable_path_uses_short_exit_status_not_full_birth(self):
        for status in (None, 5, 2):
            short = None if status is None else GATE._BSDInfo()
            if short is not None:
                short.pid, short.status = PID, status
            def path(*args):
                ctypes.set_errno(errno.EIO)
                return 0
            with self.subTest(status=status), mock.patch.object(GATE, "_LIBPROC") as proc, \
                    mock.patch.object(GATE, "_short_bsd_info", return_value=short), \
                    mock.patch.object(GATE, "bsd_info", side_effect=GATE.ContainmentError("full BSD unavailable")) as full:
                proc.proc_pidpath.side_effect = path
                if status == 2:
                    with self.assertRaisesRegex(GATE.ContainmentError, "proc_pidpath unavailable"):
                        GATE._unreadable_entry(PID, 1000000)
                else:
                    self.assertEqual(GATE._unreadable_entry(PID, 1000000)["executable"], "<exited>")
                full.assert_not_called()

    def test_unknown_environment_and_exit_status_stay_fail_closed(self):
        with mock.patch.object(GATE, "_LIBC", ArgReader(errno.EINVAL)), \
                mock.patch.object(GATE, "bsd_info", side_effect=GATE.ContainmentError("full BSD unavailable")):
            with self.assertRaises(GATE.ContainmentError):
                GATE.process_environment(PID)
        with mock.patch.object(GATE, "_LIBPROC") as proc, \
                mock.patch.object(GATE, "bsd_info", side_effect=GATE.ContainmentError("full BSD unavailable")), \
                mock.patch.object(GATE, "_short_bsd_info", side_effect=GATE.ContainmentError("status unavailable")):
            proc.proc_pidpath.return_value = 0
            with self.assertRaises(GATE.ContainmentError):
                GATE._unreadable_entry(PID, 1000000)

    def test_detached_member_with_env_eio_and_unreadable_identity_stays_quarantined(self):
        info = GATE._BSDInfo()
        info.pid, info.ppid, info.uid, info.status, info.start_sec = PID, 1, os.getuid(), 2, 2
        with mock.patch.object(GATE, "process_table", return_value={PID: info}), \
                mock.patch.object(GATE, "process_files", return_value=[((42, 43), "/sentinel")]), \
                mock.patch.object(GATE, "_LIBC", ArgReader(errno.EIO)), \
                mock.patch.object(GATE, "process_identity", return_value=None), \
                mock.patch.object(GATE, "bsd_info", side_effect=GATE.ContainmentError("full BSD unavailable")), \
                mock.patch.object(GATE, "signal_member") as signals, \
                contextlib.redirect_stderr(io.StringIO()):
            boundary = GATE.Boundary(data(), live=True)
            self.assertGreater(boundary.teardown(time.monotonic() + .08, .01), 0)
            self.assertTrue(boundary.ambiguous)
            signals.assert_not_called()


class FixtureTableRaceTests(unittest.TestCase):
    @contextlib.contextmanager
    def fixture_table(self, declared=False, short_error=None):
        suite = Path(__file__).with_name("run-tests-local.bats").read_text()
        driver = suite.split('cat > "$SANDBOX/driver.py" <<\'PY\'\n', 1)[1].split('\nPY\n}', 1)[0]
        function = next(node for node in ast.parse(driver).body
                        if isinstance(node, ast.FunctionDef) and node.name == "fixture_table")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "children").write_text(str(PID) + "\n" if declared else "")
            namespace = {"gate": GATE, "os": os, "ctypes": ctypes, "baseline": set(),
                         "baseline_data": {"owner": os.getpid()}, "fixture": root}
            exec(compile(ast.Module(body=[function], type_ignores=[]), "fixture-table", "exec"), namespace)
            proc = PartialProcessList(pgid=PID - 1, short_error=short_error)
            with mock.patch.object(GATE, "_LIBPROC", proc), \
                    mock.patch.object(GATE.os, "kill", return_value=None):
                yield namespace["fixture_table"]

    def test_fixture_scanner_recovers_unrelated_full_bsd_failure(self):
        with self.fixture_table() as table:
            self.assertEqual(set(table(time.monotonic() + 1)), {os.getpid()})
            with mock.patch.object(GATE, "process_table", side_effect=table), \
                    mock.patch.object(GATE, "process_identity", return_value=(os.getpid(), 1000000)), \
                    mock.patch.object(GATE, "boot_session", return_value="fixture"), \
                    mock.patch.object(GATE, "process_files", return_value=[]), \
                    mock.patch.object(GATE, "_LIBC") as libc, \
                    mock.patch.object(GATE, "parse_environment", return_value=set()):
                libc.sysctl.return_value = 0
                self.assertEqual(GATE._capability(time.monotonic() + 1, require_wait=False, full_scan=False), [])

    def test_fixture_scanner_retains_unreadable_declared_member(self):
        with self.fixture_table(declared=True) as table, \
                mock.patch.object(GATE, "process_table", side_effect=table), \
                mock.patch.object(GATE.os, "getsid", return_value=PID + 1), \
                mock.patch.object(GATE, "signal_member") as signals, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertIn(PID, table(time.monotonic() + 1))
            record = data()
            record["groups"] = [{"pgid": PID - 1, "start_us": 1}]
            boundary = GATE.Boundary(record, live=True)
            self.assertGreater(boundary.teardown(time.monotonic() + .08, .01), 0)
            self.assertTrue(boundary.ambiguous)
            signals.assert_not_called()

    def test_fixture_scanner_cannot_skip_unknown_membership(self):
        with self.fixture_table(short_error=errno.EIO) as table:
            with self.assertRaises(GATE.ContainmentError):
                table(time.monotonic() + 1)


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
