"""Pure shard selection and historical record validation; no gate processes."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "gate_shard_count", Path(__file__).resolve().parents[1] / "run-tests-local.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ShardCountTests(unittest.TestCase):
    def test_cpu_derivation_floor_reserve_and_cap(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            for cpus, expected in ((None, 8), (1, 8), (2, 8), (8, 8), (10, 8),
                                   (11, 9), (12, 10), (13, 11), (14, 12), (64, 12)):
                with self.subTest(cpus=cpus), mock.patch.object(GATE.os, "cpu_count", return_value=cpus):
                    self.assertEqual(GATE.select_shard_count(), expected)

    def test_valid_overrides_ignore_cpu_count(self):
        for value in ("1", "4", "8", "12", "16", "08"):
            with self.subTest(value=value), mock.patch.dict(os.environ, {"TRELLIS_TEST_SHARDS": value}), \
                    mock.patch.object(GATE.os, "cpu_count", side_effect=AssertionError("override must win")):
                self.assertEqual(GATE.select_shard_count(), int(value))

    def test_invalid_overrides_reject_before_admission_or_receipts(self):
        for value in ("", "0", "17", "-1", "+8", " 8", "8 ", "8.0", "True", "eight", "８", "9" * 5000):
            with self.subTest(value=value), mock.patch.dict(os.environ, {"TRELLIS_TEST_SHARDS": value}), \
                    mock.patch.object(GATE, "RunState") as state, \
                    mock.patch.object(GATE, "safe_capture") as capture, \
                    mock.patch.object(GATE, "emit") as emit, \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(GATE.main([]), 64)
                self.assertIn("TRELLIS_TEST_SHARDS must be an integer from 1 to 16", stderr.getvalue())
                state.assert_not_called()
                capture.assert_not_called()
                emit.assert_not_called()

    def test_valid_main_selects_override_before_status(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(os.environ, {"TRELLIS_TEST_SHARDS": "16", "TRELLIS_GATE_STATE_DIR": directory}), \
                mock.patch.object(GATE, "SHARD_COUNT", 8), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main(["--runs-status"]), 0)
            self.assertEqual(GATE.SHARD_COUNT, 16)


class HistoricalRecordTests(unittest.TestCase):
    def test_output_path_validation_does_not_use_todays_shard_count(self):
        # Legacy records carry no shard_count. A 16-shard run must remain
        # inspectable/reapable on a later 1-shard host, with no schema migration.
        with tempfile.TemporaryDirectory(prefix="tg-shards-", dir="/tmp") as directory, \
                mock.patch.object(GATE, "SHARD_COUNT", 1):
            root = Path(directory).resolve()
            token = "a" * 32
            path = root / (token + ".json")
            data = {"token": token, "run_root": str(root), "sentinel": str(root / "sentinel"),
                    "boot_session": "fixture", "sentinel_id": {"dev": 0, "ino": 0},
                    "uid": os.getuid(), "owner": {"pid": os.getpid(), "start_us": 1},
                    "groups": [], "head": "b" * 40}
            for output in ("planner.out", "shard-1.out", "shard-8.out", "shard-12.out", "shard-16.out"):
                with self.subTest(output=output):
                    data["output_ids"] = [{"path": str(root / output), "dev": 0, "ino": 0}]
                    path.write_text(json.dumps(data))
                    path.chmod(0o600)
                    self.assertEqual(GATE._read_record(path), data)
            for output in ("shard-0.out", "shard-17.out", "other.out", "../shard-1.out"):
                with self.subTest(rejected=output):
                    data["output_ids"] = [{"path": str(root / output), "dev": 0, "ino": 0}]
                    path.write_text(json.dumps(data))
                    with self.assertRaises(GATE.ContainmentError):
                        GATE._read_record(path)


if __name__ == "__main__":
    unittest.main()
