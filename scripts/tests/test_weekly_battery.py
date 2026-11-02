"""Weekly scheduling adapter tests: mock only the battery subprocess."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("weekly", Path(__file__).resolve().parents[1] / "weekly-full-battery.py")
WEEKLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEEKLY)


class WeeklyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.state = self.root / "state"
        self.environment = mock.patch.dict(os.environ, {"TRELLIS_GATE_STATE_DIR": str(self.state)})
        self.environment.start()
        self.inputs = {"schema": 1, "tree": "a" * 40}

    def tearDown(self):
        self.environment.stop()
        self.tmp.cleanup()

    def run_weekly(self, status, prior=None, changed=False):
        snapshots = [self.inputs, self.inputs | {"tree": "changed"} if changed else self.inputs]
        candidates = [dict(prior, key="fixture-key", inputs=self.inputs)] if prior else []
        with mock.patch.object(WEEKLY, "safe_inputs", side_effect=snapshots), \
                mock.patch.object(WEEKLY, "git", side_effect=[snapshot["tree"].encode() for snapshot in snapshots]), \
                mock.patch.object(WEEKLY, "tree_verdicts", return_value=candidates), \
                mock.patch.object(WEEKLY.subprocess, "run", return_value=mock.Mock(returncode=status)) as child, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as stderr:
            result = WEEKLY.run_weekly(self.root)
        records = list((self.state / "weekly-batteries").glob("*/run.json"))
        self.assertEqual(len(records), 1)
        return result, json.loads(records[0].read_text()), child, stderr.getvalue()

    def test_full_uncached_command_scrubs_selection_and_runner_overrides(self):
        overrides = {name: "synthetic" for name in ("TRELLIS_LOCAL_GATE_RUNNER", "TRELLIS_LOCAL_GATE_DEADLINE",
            "TRELLIS_LOCAL_GATE_RECEIPT", "TRELLIS_TEST_SHARDS", "TRELLIS_TEST_TSV", "PG_PUSH_TEST_SCOPE",
            "BATS_TEST_FILTER", "AGGREGATE_SCRIPT", "PACKER", "TRELLIS_STAGE_WEIGHTS_TSV")}
        with mock.patch.dict(os.environ, overrides):
            result, report, child, _ = self.run_weekly(0, {"id": "old-green"})
            self.assertEqual(result, 0)
            command = child.call_args.args[0]
            self.assertEqual(command[:5], ["trellis", "heavy", "--lane", "process-gate", "--"])
            self.assertEqual(command[-2:], ["-I", str(self.root / "scripts/run-tests-local.py")])
            self.assertNotIn("--verdict-status", command)
            env = child.call_args.kwargs["env"]
            self.assertEqual(env["PATH"], os.environ["PATH"])
            self.assertEqual(set(overrides) & env.keys(), {"TRELLIS_LOCAL_GATE_RECEIPT"})
            self.assertTrue(env["TRELLIS_LOCAL_GATE_RECEIPT"].startswith(str(self.state / "weekly-batteries")))
            self.assertTrue(report["uncached"])
            self.assertFalse(report["p1_divergence"])
            self.assertFalse((self.state / "reuse-disabled.json").exists())

    def test_failure_against_exact_green_disables_reuse_and_records_p1(self):
        result, report, _, stderr = self.run_weekly(7, {"id": "old-green"})
        self.assertEqual(result, 7)
        self.assertTrue(report["p1_divergence"])
        self.assertIn("P1:", stderr)
        disabled = self.state / "reuse-disabled.json"
        self.assertEqual(json.loads(disabled.read_text())["prior_verdict"], "old-green")
        self.assertEqual(disabled.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)

    def test_changed_inputs_or_absent_green_are_failures_not_false_divergence(self):
        for prior, changed in (({"id": "old-green"}, True), (None, False)):
            with self.subTest(prior=prior, changed=changed):
                result, report, _, _ = self.run_weekly(-15, prior, changed=changed)
                self.assertEqual(result, 143)
                self.assertFalse(report["p1_divergence"])
                self.assertFalse((self.state / "reuse-disabled.json").exists())
                shutil.rmtree(self.state / "weekly-batteries")

    def test_unsafe_state_directory_is_refused_before_battery(self):
        self.state.mkdir()
        self.state.chmod(0o755)
        with mock.patch.object(WEEKLY.subprocess, "run") as child, self.assertRaises(ValueError):
            WEEKLY.run_weekly(self.root)
        child.assert_not_called()


FIXTURE_SPEC = importlib.util.spec_from_file_location("weekly_verdict_fixture", Path(__file__).with_name("test_gate_verdict.py"))
FIXTURE = importlib.util.module_from_spec(FIXTURE_SPEC)
FIXTURE_SPEC.loader.exec_module(FIXTURE)


class WeeklyIntegrationTests(FIXTURE.VerdictTests):
    def test_scheduler_environment_drift_still_disables_tree_reuse(self):
        self.run_scheduler_case()

    def test_occupied_holder_snapshot_still_raises_p1(self):
        self.run_scheduler_case("holder")

    def test_dead_record_snapshot_still_raises_p1(self):
        self.run_scheduler_case("record")

    def test_agent_and_cron_xdg_share_p1_disable_marker(self):
        self.run_scheduler_case(pinned=True)

    def run_scheduler_case(self, occupancy=None, pinned=False):
        # Real capture, writer, reader and candidate snapshot. Only the external
        # battery command is replaced, including its normal tree invalidation.
        if pinned:
            home = self.base / "home"
            home.mkdir()
            os.environ.pop("TRELLIS_GATE_STATE_DIR")
            os.environ.update(HOME=str(home), XDG_STATE_HOME=str(self.base / "agent-state"))
            self.state = home / ".local/state/trellis-gate"
            self.state.mkdir(mode=0o700, parents=True)
            self.assertEqual(FIXTURE.GATE.gate_state_root(), self.state)
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        for name in ("bash", "git", "python3"):
            (bin_dir / name).symlink_to(sys.executable if name == "python3" else shutil.which(name))
        mktemp = bin_dir / "mktemp"
        mktemp.write_text('#!/bin/sh\nif [ "$1" = --version ]; then echo "fixture mktemp 1"; else exec /usr/bin/mktemp "$@"; fi\n')
        mktemp.chmod(0o755)
        original_run = subprocess.run
        self.tools.stop()
        try:
            with mock.patch.dict(os.environ, {"PATH": str(bin_dir), "TERM": "interactive"}):
                os.environ.pop("TRELLIS_TEST_SHARDS", None)
                self.inputs = FIXTURE.VERDICT.capture_inputs(self.root)
                self.keep()
                first = self.path
                with mock.patch.dict(os.environ, {"TERM": "another-agent"}):
                    self.id = "b" * 32
                    self.inputs = FIXTURE.VERDICT.capture_inputs(self.root)
                    self.keep()
                occupied = None
                if occupancy is not None:
                    occupied = self.state / ("gate-holder.json" if occupancy == "holder" else "runs/dead.json")
                    occupied.parent.mkdir(mode=0o700, exist_ok=True)
                    occupied.write_text("unresolved occupancy\n")
                    occupied.chmod(0o600)
                    self.assertIsNone(FIXTURE.VERDICT.find_verdict(self.inputs, self.state))
                def battery(command, *args, **kwargs):
                    if command[0] == "trellis":
                        if occupied is not None:
                            occupied.unlink()
                        FIXTURE.GATE._invalidate_verdicts(mock.Mock(root=self.state), self.root, FIXTURE.time.monotonic() + 5)
                        self.assertFalse(first.exists())
                        self.assertFalse(self.path.exists())
                        return mock.Mock(returncode=7)
                    return original_run(command, *args, **kwargs)
                scheduler = {"TERM": "dumb-scheduler"}
                if pinned:
                    scheduler["XDG_STATE_HOME"] = str(self.base / "cron-state")
                with mock.patch.dict(os.environ, scheduler), \
                        mock.patch.object(WEEKLY.subprocess, "run", side_effect=battery), \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as stderr:
                    self.assertEqual(WEEKLY.run_weekly(self.root), 7)
                    self.assertEqual(WEEKLY.state_root(), self.state)
                reports = list((self.state / "weekly-batteries").glob("*/run.json"))
                self.assertEqual(len(reports), 1)
                report = json.loads(reports[0].read_text())
                self.assertTrue(report["p1_divergence"])
                self.assertEqual({candidate["id"] for candidate in report["candidate_verdicts"]}, {"a" * 32, "b" * 32})
                for candidate in report["candidate_verdicts"]:
                    self.assertEqual(candidate["differing_key_fields"], ["environment"])
                self.assertIn("P1:", stderr.getvalue())
                self.assertTrue((self.state / "reuse-disabled.json").exists())
                self.assertEqual(FIXTURE.GATE.gate_state_root(), self.state)
                if pinned:
                    self.assertFalse((self.base / "agent-state").exists())
                    self.assertFalse((self.base / "cron-state").exists())
        finally:
            self.tools.start()


if __name__ == "__main__":
    unittest.main()
