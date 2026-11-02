"""Hermetic spec 066 process controls; no real Bats or Trellis is executed."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
import receipt_provenance as provenance


class ReceiptProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="receipt-provenance-", dir=os.environ.get("TRELLIS_PROVENANCE_TEST_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "source with spaces"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.root.mkdir()
        self.order = self.base / "order"
        self.receipt = self.base / "receipt.tsv"
        self.home = self.base / "trellis-home"
        self.home.mkdir()
        (self.home / "config.json").write_text('{"active_cli_release":"1.3.9"}')
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("TRELLIS_", "GIT_", "HC_"))}
        self.env.update(PATH=str(self.bin) + ":/usr/bin:/bin", TMPDIR=str(self.base),
                        TRELLIS_HOME=str(self.home), ORDER=str(self.order),
                        TRELLIS_TEST_TSV=str(self.receipt))
        for tool in provenance.TOOLS:
            self.tool(tool)
        self.script("python3", 'exec ' + self.quote(sys.executable) + ' "$@"\n')

    @staticmethod
    def quote(text):
        import shlex
        return shlex.quote(str(text))

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o700)
        return path

    def tool(self, name):
        body = ('if [ "${1:-}" = --version ]; then\n'
                '  printf "probe-' + name + '\\n" >> "$ORDER"\n'
                '  printf "' + name + '-START\\n"; exit 0\nfi\n')
        if name == "bash":
            body += 'exec /bin/bash "$@"\n'
        elif name == "git":
            body += 'printf "%040d\\n" 1\n'
        else:
            body += 'printf "test-' + name + '\\n" >> "$ORDER"\nexit 0\n'
        return self.script(name, body)

    def runner_fixture(self, mode="pass"):
        files = ["scripts/run-tests.sh", "scripts/lib/receipt_provenance.py",
                 "scripts/lib/gate_receipts.py", "scripts/lib/gate_verdict.py",
                 "scripts/lib/test-suites.sh", "scripts/lib/bats-jobs.sh",
                 "scripts/lib/trellis-python.sh",
                 "scripts/tests/stage-weights.tsv",
                 "scripts/tests/helpers/git-fence/git", "scripts/tests/helpers/git-fence/mktemp"]
        for relative in files:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        stage = self.root / "scripts/lint-shell-tree.sh"
        stage.write_text('printf "test-first\\n" >> "$ORDER"\n' + {
            "pass": "exit 0\n",
            "red": "exit 7\n",
            "signal": 'kill -TERM "$PPID"\nexit 0\n',
            "timeout": 'sleep 30\n',
            # The next Bats stage changes caller tool availability, not START.
            "swap": 'printf "#!/bin/bash\\necho bats-END\\n" > '
                    + self.quote(self.bin / "bats") + '\nexit 0\n',
        }[mode])
        (self.root / "scripts/conformance-check.sh").write_text('exit 0\n')
        (self.root / "scripts/tests/aeo-gate.test.sh").write_text('exit 0\n')
        for name in ("ruff", "mypy"):
            self.script(name, 'exit 0\n')
        # Keep the synthetic interpreter selected after the runner pins Python.
        self.env["TRELLIS_PYTHON"] = str(self.bin / "python3")
        # Only this fixture's AEO unittest stage is skipped, never the subject helper.
        self.script("python3", 'if [ "${1:-}" = -m ]; then exit 0; fi\nexec '
                    + self.quote(sys.executable) + ' "$@"\n')
        return self.root / "scripts/run-tests.sh"

    def load_gate(self):
        spec = importlib.util.spec_from_file_location("gate", ROOT / "scripts/run-tests-local.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        return gate

    def records(self):
        return [json.loads(line) for line in
                Path(str(self.receipt) + ".provenance.jsonl").read_text().splitlines()]

    def launch(self, runner, *args, env=None):
        return subprocess.run(["/bin/bash", str(runner), *args], env=env or self.env,
                              capture_output=True, text=True, timeout=15)

    def test_start_precedes_tests_and_has_exact_identity(self):
        runner = self.runner_fixture()
        result = self.launch(runner, "--quick")
        self.assertEqual(result.returncode, 0, result.stderr)
        record, fenced = self.records()
        self.assertEqual(fenced["phase"], "fenced")
        self.assertEqual(record["phase"], "start")
        self.assertEqual(record["command"], ["/bin/bash", str(runner), "--quick"])
        self.assertEqual(record["head"], "0" * 39 + "1")
        self.assertEqual(record["path"], self.env["PATH"])
        self.assertEqual(record["active_trellis_release"], "1.3.9")
        self.assertIn("+00:00", record["timestamp"])
        for name in provenance.TOOLS:
            self.assertEqual(record["tools"][name]["version"], name + "-START")
            self.assertEqual(record["tools"][name]["path"], str(self.bin / name))
            self.assertEqual(record["tools"][name]["realpath"], str((self.bin / name).resolve()))
        self.assertEqual(self.order.read_text().splitlines().count("probe-bats"), 2)

    def test_inventory_never_probes_or_writes_with_any_binding(self):
        runner = self.runner_fixture()
        before = set(self.base.rglob("*"))
        for option in ("--list", "--plan"):
            for bindings in ((), ("TRELLIS_TEST_TSV",),
                             ("TRELLIS_TEST_PROVENANCE_RECEIPT",),
                             ("TRELLIS_TEST_TSV", "TRELLIS_TEST_PROVENANCE_RECEIPT")):
                with self.subTest(option=option, bindings=bindings):
                    env = self.env.copy()
                    env.pop("TRELLIS_TEST_TSV")
                    env.update({name: str(self.receipt) for name in bindings})
                    result = self.launch(runner, "--quick", option, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")
                    self.assertTrue(result.stdout.startswith(
                        "shard\tstage\tweight\n" if option == "--plan" else "shellcheck ("))
                    self.assertFalse(self.order.exists())
                    self.assertFalse(Path(str(self.receipt) + ".provenance.jsonl").exists())
                    self.assertEqual(set(self.base.rglob("*")), before)

    def test_no_python_capture_preserves_existing_refusal_and_exit(self):
        runner = self.runner_fixture()
        empty_bin = self.base / "no-python-bin"
        empty_bin.mkdir()
        env = self.env | {"PATH": str(empty_bin)}
        result = self.launch(runner, "--quick", env=env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        record, = self.records()
        self.assertEqual(record, {"phase": "start", "provenance": "unavailable",
                                  "reason": "python3 not found"})
        self.assertIn(json.dumps(record, separators=(",", ":")), result.stderr)
        self.assertIn("could not resolve the real Git executable", result.stderr)
        self.assertNotIn("command not found", result.stderr)
        self.assertFalse(self.order.exists())
        self.assertFalse(list(self.base.glob("trellis-test-git.*")))
        # Argument validation also retains its original exit class, not capture's.
        result = self.launch(runner, "--unknown", env=env)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("unknown argument", result.stderr)
        (empty_bin / "awk").symlink_to(shutil.which("awk"))
        before = Path(str(self.receipt) + ".provenance.jsonl").read_bytes()
        for option in ("--plan", "--list"):
            result = self.launch(runner, "--quick", option, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(Path(str(self.receipt) + ".provenance.jsonl").read_bytes(), before)

    def test_failed_helper_is_nonfatal_at_start_and_fenced(self):
        runner = self.runner_fixture()
        self.script("python3", 'case "${1:-}" in *receipt_provenance.py) exit 29 ;; esac\n'
                    'if [ "${1:-}" = -m ]; then exit 0; fi\nexec '
                    + self.quote(sys.executable) + ' "$@"\n')
        result = self.launch(runner, "--quick")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["phase"] for r in self.records()], ["start", "fenced"])
        self.assertTrue(all(r["reason"] == "provenance helper failed" for r in self.records()))
        self.assertIn("test-first", self.order.read_text())
        self.assertNotIn('"provenance"', result.stdout)

    def test_sidecar_write_failure_does_not_replace_runner_exit(self):
        runner = self.runner_fixture()
        blocked = self.base / "blocked-parent"
        blocked.write_text("not a directory")
        env = self.env | {"TRELLIS_TEST_PROVENANCE_RECEIPT": str(blocked / "receipt")}
        for args, expected in ((("--quick",), 0), (("--quick", "--plan"), 0),
                               (("--quick", "--list"), 0), (("--unknown",), 64)):
            with self.subTest(args=args):
                result = self.launch(runner, *args, env=env)
                self.assertEqual(result.returncode, expected, result.stderr)
                if "--plan" in args or "--list" in args:
                    self.assertEqual(result.stderr, "")
                else:
                    self.assertIn('"provenance_sidecar": "unavailable: write failed"', result.stderr)
                self.assertNotIn('"receipt_provenance"', result.stdout)
        # The wrapper must reach its existing invalid-deadline refusal too.
        env.update(TRELLIS_LOCAL_GATE_RECEIPT=str(blocked / "receipt"),
                   TRELLIS_LOCAL_GATE_DEADLINE="invalid")
        result = subprocess.run([sys.executable, str(ROOT / "scripts/run-tests-local.py")],
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn('"provenance_sidecar": "unavailable: write failed"', result.stderr)
        self.assertIn("must be a positive number", result.stderr)

    def test_wrapper_unbound_refusals_leave_no_files_or_probe_deadline_cost(self):
        gate = self.load_gate()
        env = self.env | {"TRELLIS_GATE_STATE_DIR": str(self.base / "state"),
                          "TRELLIS_LOCAL_GATE_RESERVE": "5", "TRELLIS_LOCAL_GATE_TERM_GRACE": "0.1"}
        before = set(self.base.rglob("*"))
        for deadline, status in (("invalid", 64), ("15", 70)):
            with self.subTest(status=status):
                now = [100.0]
                def slow_capture(*args):
                    now[0] += 14.0  # All seven probes can exhaust their timeout.
                    return {"phase": "start"}
                err = io.StringIO()
                with patch.dict(os.environ, env | {"TRELLIS_LOCAL_GATE_DEADLINE": deadline}, clear=True), \
                        patch.object(gate, "safe_capture", side_effect=slow_capture), \
                        patch.object(gate.time, "monotonic", side_effect=lambda: now[0]), \
                        patch.object(gate, "RunState") as state, \
                        patch.object(gate, "_capability", side_effect=gate.ContainmentError("refused")) as admission, \
                        patch.object(gate.tempfile, "mkstemp") as allocate, \
                        patch.object(gate.sys, "stderr", err):
                    state.return_value.records.return_value = []
                    state.return_value.root = self.base / "state"
                    self.assertEqual(gate.main([]), status)
                    allocate.assert_not_called()
                    if status == 70:
                        self.assertEqual(admission.call_args.args[0] - now[0], 10.0)
                self.assertIn('"phase": "start"', err.getvalue())
                self.assertEqual(set(self.base.rglob("*")), before)

    def test_wrapper_allocates_once_after_admission_without_retry(self):
        gate = self.load_gate()
        env = self.env | {"TRELLIS_GATE_STATE_DIR": str(self.base / "state"),
                          "TRELLIS_LOCAL_GATE_DEADLINE": "15", "TRELLIS_LOCAL_GATE_RESERVE": "5",
                          "TRELLIS_LOCAL_GATE_TERM_GRACE": "0.1"}
        for fail in (False, True):
            with self.subTest(fail=fail):
                fd = os.open(self.base / "sentinel", os.O_CREAT | os.O_RDONLY, 0o600)
                with patch.dict(os.environ, env, clear=True), \
                        patch.object(gate, "RunState") as state, \
                        patch.object(gate, "_capability", return_value=[]), \
                        patch.object(gate, "sweep_records", return_value=True), \
                        patch.object(gate, "_heavy_fds"), \
                        patch.object(gate, "_new_run", return_value=(
                            {"run_root": str(self.base), "token": "control"}, self.base / "record", fd)), \
                        patch.object(gate.tempfile, "tempdir", str(self.base)), \
                        patch.object(gate.tempfile, "mkstemp", wraps=tempfile.mkstemp,
                                     side_effect=OSError("no receipt") if fail else None) as allocate, \
                        patch.object(gate, "_spawn", side_effect=OSError("planner refused")) as spawn, \
                        patch.object(gate, "Boundary") as boundary, \
                        patch.object(gate, "_delete_empty_record"), patch.object(gate, "_receipt"), \
                        patch.object(gate.sys, "stderr", io.StringIO()):
                    state.return_value.records.return_value = []
                    state.return_value.root = self.base / "state"
                    boundary.return_value.teardown.return_value = 0
                    self.assertEqual(gate.main([]), 1)
                    allocate.assert_called_once_with(prefix="trellis-run-tests-aggregate-", suffix=".tsv")
                    if fail:
                        spawn.assert_not_called()
                    else:
                        # The planner has no inherited outer receipt bindings.
                        planner_env = spawn.call_args.args[-2]
                        self.assertNotIn("TRELLIS_TEST_TSV", planner_env)
                        self.assertNotIn("TRELLIS_TEST_PROVENANCE_RECEIPT", planner_env)
        sidecar, = self.base.glob("trellis-run-tests-aggregate-*.tsv.provenance.jsonl")
        start, = [json.loads(line) for line in sidecar.read_text().splitlines()]
        self.assertEqual(start["phase"], "start")
        self.assertNotIn("provenance_sidecar", start)

    def test_wrapper_import_does_not_write_source_bytecode(self):
        self.runner_fixture()
        wrapper = self.root / "scripts/run-tests-local.py"
        shutil.copy2(ROOT / "scripts/run-tests-local.py", wrapper)
        env = self.env | {"TRELLIS_LOCAL_GATE_DEADLINE": "invalid"}
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        result = subprocess.run([sys.executable, str(wrapper)], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn('"phase": "start"', result.stderr)
        self.assertEqual(list(self.root.rglob("__pycache__")), [])

    def test_capture_exception_and_closed_stderr_are_nonfatal(self):
        with patch.object(provenance, "capture", side_effect=RuntimeError("private detail")):
            record = provenance.safe_capture(self.root, ["exact"])
        self.assertEqual(record, {"phase": "start", "provenance": "unavailable",
                                  "reason": "capture failed: RuntimeError"})
        with patch.object(provenance.sys.stderr, "write", side_effect=OSError("closed")):
            self.assertTrue(provenance.emit(record, self.receipt))
        self.assertEqual(self.records(), [record])
        gate = self.load_gate()
        for exc in (gate._DeadlineExit(), gate._SignalExit(signal.SIGTERM)):
            with self.subTest(exception=type(exc).__name__), \
                    patch.object(provenance, "capture", side_effect=exc):
                with self.assertRaises(type(exc)):
                    provenance.safe_capture(self.root, ["exact"])

    def test_nested_inventory_and_real_runner_leave_outer_sidecar_byte_identical(self):
        runner = self.runner_fixture()
        stage = self.root / "scripts/lint-shell-tree.sh"
        for explicit_binding in (False, True):
            with self.subTest(explicit_binding=explicit_binding):
                # Prevent recursion, then exercise inventory AND a real nested run.
                stage.write_text('[ "${PROVENANCE_NESTED:-}" != 1 ] || exit 0\n'
                                 '[ -z "${TRELLIS_TEST_PROVENANCE_RECEIPT+x}" ] || exit 91\n'
                                 '[ -z "${TRELLIS_TEST_TSV+x}" ] || exit 92\n'
                                 'cp "$OUTER_SIDECAR" "$BEFORE_NESTED"\n'
                                 'bash scripts/run-tests.sh --quick --list >/dev/null || exit 93\n'
                                 'cp "$OUTER_SIDECAR" "$AFTER_LIST"\n'
                                 'PROVENANCE_NESTED=1 bash scripts/run-tests.sh --quick >/dev/null || exit 94\n'
                                 'cp "$OUTER_SIDECAR" "$AFTER_RUN"\n')
                env = self.env | {"OUTER_SIDECAR": str(self.receipt) + ".provenance.jsonl",
                                  "BEFORE_NESTED": str(self.base / "before-nested"),
                                  "AFTER_LIST": str(self.base / "after-list"),
                                  "AFTER_RUN": str(self.base / "after-run")}
                if explicit_binding:
                    env["TRELLIS_TEST_PROVENANCE_RECEIPT"] = str(self.receipt)
                result = self.launch(runner, "--quick", env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                before = Path(env["BEFORE_NESTED"]).read_bytes()
                for name in ("AFTER_LIST", "AFTER_RUN", "OUTER_SIDECAR"):
                    self.assertEqual(Path(env[name]).read_bytes(), before)
                self.assertEqual([r["phase"] for r in self.records()[-2:]], ["start", "fenced"])

    def test_path_shim_is_probed_as_found_and_realpath_recorded_separately(self):
        shim = self.script("manager", 'printf "shim notice\\n" >&2\n'
                           'printf "%s-SHIM\\n" "${0##*/}"\n')
        (self.bin / "node").unlink()
        (self.bin / "node").symlink_to(shim)
        with patch.dict(os.environ, self.env, clear=True):
            tool = provenance.capture(self.root, ["exact"])["tools"]["node"]
        self.assertEqual(tool, {"path": str(self.bin / "node"), "realpath": str(shim.resolve()),
                                "version": "node-SHIM"})

    def test_fenced_capture_precedes_first_test_and_preserves_caller_path(self):
        runner = self.runner_fixture("swap")
        result = self.launch(runner, "--quick")
        self.assertEqual(result.returncode, 0, result.stderr)
        start, fenced = self.records()
        self.assertEqual(start["path"], self.env["PATH"])
        self.assertTrue(fenced["path"].endswith(":" + start["path"]))
        self.assertIn("trellis-test-git.", fenced["tools"]["git"]["path"])
        for record in (start, fenced):
            self.assertEqual(record["tools"]["bats"]["version"], "bats-START")
        lines = self.order.read_text().splitlines()
        first = lines.index("test-first")
        self.assertEqual(lines[:first].count("probe-bats"), 2)
        self.assertNotIn("probe-bats", lines[first:])
        self.assertTrue(self.receipt.read_text().startswith("ordinal\tstage\telapsed_seconds\texit\n"))
        # Emitted before test output, not merely stored by an end-only capture.
        self.assertLess(result.stderr.index('"phase": "start"'),
                        result.stderr.index('"phase": "fenced"'))

    def test_implicit_receipt_keeps_provenance_only_on_stderr(self):
        runner = self.runner_fixture()
        (self.root / "scripts/lint-shell-tree.sh").write_text(
            'find "$TMPDIR" -name "*.provenance.jsonl" -print > "$IMPLICIT_SIDECARS"\nexit 0\n')
        env = self.env | {"IMPLICIT_SIDECARS": str(self.base / "implicit-sidecars")}
        env.pop("TRELLIS_TEST_TSV")
        result = self.launch(runner, "--quick", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in result.stderr.splitlines()
                   if line.startswith('{"active_release_source"')]
        self.assertEqual([r["phase"] for r in records], ["start", "fenced"])
        self.assertEqual(Path(env["IMPLICIT_SIDECARS"]).read_text(), "")
        self.assertIn("run-tests: receipt=", result.stdout)

    def test_probe_failure_timeout_empty_stdout_and_group_are_explicit(self):
        failure = self.script("failure", "exit 9\n")
        hanging = self.script("hanging", "exec sleep 30\n")
        empty = self.script("empty", 'printf "notice only\\n" >&2\n')
        for tool, expected in ((failure, "probe exit 9"), (hanging, "probe timeout"),
                               (empty, "empty probe")):
            self.assertEqual(provenance.probe([str(tool)], self.env, self.root),
                             "unavailable: " + expected)
        self.assertEqual(provenance.probe([sys.executable, "-c", "import os; print(os.getpgrp())"],
                                         self.env, self.root), str(os.getpgrp()))
        # Timeout remains timeout when the leader has gone and stdout stays open.
        with patch.object(provenance.subprocess, "Popen") as popen:
            child = popen.return_value
            child.communicate.side_effect = subprocess.TimeoutExpired("probe", 2)
            child.kill.side_effect = ProcessLookupError()
            self.assertEqual(provenance.probe(["probe"], self.env, self.root),
                             "unavailable: probe timeout")
            self.assertEqual(child.communicate.call_args_list[-1].kwargs, {"timeout": 0.2})
            child.stdout.close.assert_called_once()

    def test_setup_failure_still_has_start(self):
        runner = self.runner_fixture()
        env = self.env | {"TRELLIS_TEST_REAL_GIT": str(self.base / "missing")}
        result = self.launch(runner, "--quick", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not resolve the real Git", result.stderr)
        start, = self.records()
        self.assertEqual(start["phase"], "start")
        self.assertNotIn("test-", self.order.read_text())

    def test_red_signal_and_timeout_retain_start_and_fenced(self):
        for mode in ("red", "signal", "timeout"):
            with self.subTest(mode=mode):
                # Sidecar is append-only across invocations; inspect the latest pair.
                runner = self.runner_fixture(mode)
                child = subprocess.Popen(["/bin/bash", str(runner), "--quick"],
                                         env=self.env, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, start_new_session=True)
                if mode == "timeout":
                    end = time.monotonic() + 10
                    while not self.order.exists() or "test-first" not in self.order.read_text():
                        self.assertLess(time.monotonic(), end)
                        time.sleep(0.01)
                    # Timeout disposition without ever running the real battery.
                    os.killpg(child.pid, signal.SIGTERM)
                out, err = child.communicate(timeout=15)
                self.assertNotEqual(child.returncode, 0, (out, err))
                self.assertEqual([r["phase"] for r in self.records()[-2:]], ["start", "fenced"])
                self.order.unlink()

    def test_missing_tools_and_release_are_explicit_no_environment_dump(self):
        with patch.dict(os.environ, self.env | {"PATH": str(self.base / "absent"),
                                               "API_SECRET": "never-record-me"}, clear=True):
            (self.home / "config.json").write_text("invalid JSON")
            record = provenance.capture(self.root, ["exact", "", "space arg"])
        self.assertEqual(record["command"], ["exact", "", "space arg"])
        for tool in record["tools"].values():
            self.assertTrue(tool["version"].startswith("unavailable:"))
        self.assertTrue(record["active_trellis_release"].startswith("unavailable:"))
        self.assertNotIn("never-record-me", json.dumps(record))

    def test_local_wrapper_start_survives_admission_failure(self):
        env = self.env | {"TRELLIS_LOCAL_GATE_RECEIPT": str(self.receipt),
                          "TRELLIS_LOCAL_GATE_DEADLINE": "invalid"}
        result = subprocess.run([sys.executable, str(ROOT / "scripts/run-tests-local.py")],
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 64, result.stderr)
        record, = self.records()
        self.assertEqual(record["phase"], "start")
        self.assertLess(result.stderr.index('"receipt_provenance"'),
                        result.stderr.index("must be a positive number"))

if __name__ == "__main__":
    unittest.main()
