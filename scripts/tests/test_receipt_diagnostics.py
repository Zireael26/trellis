import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from usage_federation import cli


class FixtureFailure(Exception):
    pass


class ReceiptDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp_home = tempfile.TemporaryDirectory(prefix="receipt-diagnostics-")
        self.home = Path(self.temp_home.name)

    def tearDown(self):
        self.temp_home.cleanup()

    def run_failure(self, handler, patched_name, args, operation, secret):
        error = FixtureFailure(
            f"synthetic storage failure\n\x1b[31m; receipt={secret}"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        target = f"usage_federation.dispatch_receipts.{patched_name}"
        with (
            mock.patch.object(cli, "_resolve_trellis_home", return_value=self.home),
            mock.patch(target, side_effect=error),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = handler(args)

        diagnostic = stderr.getvalue()
        self.assertEqual(status, cli.EXIT_UNAVAILABLE)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn(f"receipt {operation} failed", diagnostic)
        self.assertIn(f"cause_code=receipt_{operation}_failed", diagnostic)
        self.assertIn("FixtureFailure: synthetic storage failure", diagnostic)
        self.assertIn(r"\u000a\u001b[31m", diagnostic)
        self.assertIn("receipt=[redacted]", diagnostic)
        self.assertNotIn(secret, stdout.getvalue() + diagnostic)
        self.assertEqual(diagnostic.count("\n"), 1)

    def test_begin_failure_reports_safe_cause(self):
        secret = "receipt-payload-secret-begin"
        args = SimpleNamespace(
            worktree="/tmp/worktree",
            harness="pi",
            unit="15",
            agent="luna",
            provider="openai-codex",
            model="fixture-model",
            effort="max",
            pane="w1:p1",
            name=secret,
        )
        self.run_failure(cli._run_receipt_begin, "begin_receipt", args, "begin", secret)

    def test_accept_failure_reports_safe_cause(self):
        secret = "receipt-payload-secret-accept"
        args = SimpleNamespace(
            dispatch_id="dispatch-fixture",
            base_sha="a" * 40,
            head_sha="b" * 40,
            checker_id=secret,
            checker_sha="c" * 40,
            verdict="accepted",
        )
        self.run_failure(cli._run_receipt_accept, "accept_receipt", args, "accept", secret)

    def test_bind_failure_reports_safe_cause(self):
        secret = "/tmp/receipt-payload-secret-bind/session.jsonl"
        args = SimpleNamespace(
            unresolved=False,
            dispatch_id="dispatch-fixture",
            session_path=secret,
        )
        self.run_failure(cli._run_receipt_bind, "bind_session_path", args, "bind", secret)

    def test_begin_success_keeps_uuid_on_stdout(self):
        dispatch_id = "12345678-1234-4234-8234-123456789abc"
        args = SimpleNamespace(
            worktree="/tmp/worktree",
            harness="pi",
            unit="15",
            agent="luna",
            provider="openai-codex",
            model="fixture-model",
            effort="max",
            pane="w1:p1",
            name="fixture",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(cli, "_resolve_trellis_home", return_value=self.home),
            mock.patch(
                "usage_federation.dispatch_receipts.begin_receipt",
                return_value=dispatch_id,
            ),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = cli._run_receipt_begin(args)
        self.assertEqual(status, cli.EXIT_COMPLETE)
        self.assertEqual(stdout.getvalue(), f"{dispatch_id}\n")
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
