"""Exact-input cache mutation and runner lifecycle tests, all in a private repo."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verdict_runner", ROOT / "scripts/run-tests-local.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
VERDICT = sys.modules["gate_verdict"]


class VerdictTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        self.state = self.base / "state"
        self.state.mkdir(mode=0o700)
        self.env = mock.patch.dict(os.environ, {"TRELLIS_GATE_STATE_DIR": str(self.state),
            "TRELLIS_TEST_SHARDS": "1", "GIT_OPTIONAL_LOCKS": "0", "TRELLIS_LOCAL_GATE_QUEUE_WAIT": ".3"})
        self.env.start()
        # Nested battery fixtures must not inherit the outer runner's receipts
        # or selection adapters; the patch restores the caller on teardown.
        for name in list(os.environ):
            if (name in ("PG_PUSH_TEST_SCOPE", "BATS_TEST_FILTER", "BATS_FILTER", "AGGREGATE_SCRIPT", "PACKER")
                    or name.startswith("TRELLIS_TEST_") and name != "TRELLIS_TEST_SHARDS"
                    or name.startswith("TRELLIS_LOCAL_GATE_") and name != "TRELLIS_LOCAL_GATE_QUEUE_WAIT"
                    or name.startswith("TRELLIS_HEAVY_TEST")):
                del os.environ[name]
        for name in VERDICT.RUNNER_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        (self.root / "scripts/tests/sample.bats").write_text("# suite v1\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "core.hooksPath", "/dev/null")
        self.commit()
        (self.root / "marker").write_text("candidate\n")
        self.commit()
        self.tools = mock.patch.object(VERDICT, "toolchain", return_value={"bash": {"version": "one"}})
        self.tools.start()
        self.inputs = VERDICT.capture_inputs(self.root)
        self.id = "a" * 32
        self.keep()

    def tearDown(self):
        self.tools.stop()
        self.env.stop()
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def keep(self):
        kept = self.state / "passing-runs" / self.id
        kept.mkdir(mode=0o700, parents=True, exist_ok=True)
        kept.parent.chmod(0o700)
        content = b"ordinal\tstage\telapsed_seconds\texit\n1\tfixture\t1\t0\n"
        (kept / "aggregate.tsv").write_bytes(content)
        (kept / "aggregate.tsv").chmod(0o600)
        GATE.save_record(kept / "run.json", {"id": self.id, "head": self.git("rev-parse", "HEAD").decode().strip(),
            "tree": self.inputs["tree"], "completed_at": time.time(), "aggregate_sha256": VERDICT.digest(content)})
        GATE._write_verdict(types.SimpleNamespace(root=self.state), self.inputs, VERDICT.safe_inputs(self.root), kept)
        self.path = self.state / "verdicts" / (VERDICT.key(self.inputs) + ".json")
        self.assertIsNotNone(VERDICT.find_verdict(self.inputs, self.state))
        return kept

    def clear_hook_git_env(self):
        # check-tests.sh unsets Git routing/config overrides (run-tests.sh's fence
        # exports GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM) before it reads a
        # verdict. Capture under that same environment; call inside patch.dict.
        for name in list(os.environ):
            if name.startswith("GIT_") and name != "GIT_OPTIONAL_LOCKS":
                del os.environ[name]

    def versioned_path(self):
        directory = self.base / "versioned-tools"
        directory.mkdir()
        shell = str(Path(shutil.which("bash")).resolve())
        for name in VERDICT.TOOLS:
            executable = sys.executable if name == "python3" else shutil.which(name)
            if executable:
                wrapper = directory / name
                wrapper.write_text('#!' + shell + '\nif [ "$#" -eq 1 ] && [ "$1" = --version ]; then\n'
                                   '  echo "fixture ' + name + ' 1"; exit 0\nfi\nexec ' + shlex.quote(executable) + ' "$@"\n')
                wrapper.chmod(0o755)
        return str(directory) + os.pathsep + os.environ["PATH"]

    def mutate(self, field):
        changed = copy.deepcopy(self.inputs)
        if field == "runner":
            for name in VERDICT.RUNNER_FILES:
                with self.subTest(blob=name):
                    variant = copy.deepcopy(changed)
                    variant[field][name] = "changed"
                    self.assertIsNone(VERDICT.find_verdict(variant, self.state))
        elif field == "toolchain":
            for name in VERDICT.TOOLS:
                with self.subTest(tool=name):
                    variant = copy.deepcopy(changed)
                    variant[field][name] = {"version": "changed"}
                    self.assertIsNone(VERDICT.find_verdict(variant, self.state))
        else:
            changed[field] = "changed"
            self.assertIsNone(VERDICT.find_verdict(changed, self.state))

    def test_capture_binds_real_sources_and_rejects_dirty_or_wrong_head(self):
        for flag, undo in (("--assume-unchanged", "--no-assume-unchanged"), ("--skip-worktree", "--no-skip-worktree")):
            self.git("update-index", flag, "scripts/tests/sample.bats")
            self.assertIsNone(VERDICT.safe_inputs(self.root))
            self.git("update-index", undo, "scripts/tests/sample.bats")
        fence = self.root / "scripts/tests/helpers/git-fence/git"
        fence.write_text(fence.read_text() + "\n# changed\n")
        self.assertIsNone(VERDICT.safe_inputs(self.root))
        self.commit()
        changed = VERDICT.capture_inputs(self.root)
        self.assertNotEqual(changed["runner"], self.inputs["runner"])
        self.assertNotEqual(changed["suite_versions"], self.inputs["suite_versions"])
        self.assertNotEqual(changed["tree"], self.inputs["tree"])
        old_head = self.git("rev-parse", "HEAD~1").decode().strip()
        self.assertIsNone(VERDICT.safe_inputs(self.root, old_head))
        (self.root / "scripts/tests/new.bats").write_text("# new suite\n")
        self.commit()
        self.assertNotEqual(VERDICT.capture_inputs(self.root)["inventory"], changed["inventory"])
        with mock.patch.dict(os.environ, {"ARBITRARY_TEST_OPTION": "new"}):
            self.assertNotEqual(VERDICT.capture_inputs(self.root)["environment"], changed["environment"])
        self.git("config", "fixture.value", "changed")
        self.assertNotEqual(VERDICT.capture_inputs(self.root)["git_config"], changed["git_config"])
        self.git("tag", "v0.0.1")
        self.assertNotEqual(VERDICT.capture_inputs(self.root)["refs"], changed["refs"])

    def test_bad_evidence_mode_location_and_failure_are_never_reused(self):
        original = self.path.read_bytes()
        for field, value in (("status", "fail"), ("complete", False), ("containment", "unknown"),
                             ("key", "b" * 64), ("aggregate_sha256", "b" * 64)):
            record = json.loads(original)
            record[field] = value
            GATE.save_record(self.path, record)
            self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state), field)
        self.path.write_bytes(original)
        self.path.chmod(0o644)
        self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))
        self.path.chmod(0o600)
        content = self.path.read_bytes()
        self.path.unlink()
        target = self.base / "elsewhere"
        target.write_bytes(content)
        target.chmod(0o600)
        self.path.symlink_to(target)
        self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))
        self.path.unlink()
        self.path.write_bytes(content)
        self.path.chmod(0o600)
        aggregate = self.state / "passing-runs" / self.id / "aggregate.tsv"
        passing = aggregate.read_bytes()
        aggregate.write_bytes(passing.replace(b"\t0\n", b"\t1\n"))
        self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))
        aggregate.write_bytes(passing)
        self.assertIsNotNone(VERDICT.find_verdict(self.inputs, self.state))
        (self.state / "reuse-disabled.json").write_text("P1\n")
        self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))

    def test_ignored_discovery_suites_refuse_reuse_but_caches_do_not(self):
        exclude = self.root / ".git/info/exclude"
        original = exclude.read_text()
        benign = self.root / "scripts/tests/__pycache__/fixture.pyc"
        benign.parent.mkdir()
        benign.write_bytes(b"cache")
        exclude.write_text(original + "\n__pycache__/\n")
        self.assertEqual(VERDICT.capture_inputs(self.root), self.inputs)
        for pattern in VERDICT.DISCOVERY_GLOBS:
            name = pattern.replace("*", "ignored", 1) if pattern.count("*") == 2 else pattern
            name = name.replace("*", "local-extra")
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('@test "fails" { false; }\n')
            exclude.write_text(original + "\n__pycache__/\n" + name + "\n")
            self.assertEqual(self.git("status", "--porcelain"), b"")
            with self.subTest(path=name):
                self.assertIsNone(VERDICT.safe_inputs(self.root))
            path.unlink()
        parent = self.root / "core-rules/skills/ignored-parent/tests"
        parent.mkdir(parents=True)
        (parent / "extra.bats").write_text('@test "fails" { false; }\n')
        exclude.write_text(original + "\n__pycache__/\ncore-rules/skills/ignored-parent/\n")
        self.assertIsNone(VERDICT.safe_inputs(self.root))

    def test_failed_version_probe_refuses_reuse(self):
        executable = self.base / "bats-tool"
        executable.write_bytes(b"fixture executable")
        self.tools.stop()
        try:
            with mock.patch.object(VERDICT.shutil, "which", side_effect=lambda name: str(executable) if name == "bats" else None):
                self.assertIsNotNone(VERDICT.safe_inputs(self.root, version_probe=lambda *args: "fixture bats 1"))
                for failure in ("unavailable: probe timeout", "unavailable: probe exit 1", "unavailable: empty probe", ""):
                    with self.subTest(failure=failure):
                        self.assertIsNone(VERDICT.safe_inputs(self.root, version_probe=lambda *args: failure))
        finally:
            self.tools.start()

    def test_heavy_only_operational_transport_is_excluded(self):
        for name in ("TRELLIS_HEAVY_FD", "TRELLIS_HEAVY_TOKEN", "TRELLIS_HEAVY_SLOT", "TRELLIS_HEAVY_POOL", "TRELLIS_HEAVY_DIR_ID"):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: "transport"}):
                self.assertEqual(VERDICT.capture_inputs(self.root), self.inputs)
        for name in ("TRELLIS_HEAVY_TEST", "TRELLIS_HEAVY_TEST_FAIL", "TRELLIS_HEAVY_TEST_POLL"):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: "test"}):
                self.assertIsNone(VERDICT.safe_inputs(self.root))
        for name in ("TRELLIS_HEAVY_DIR", "TRELLIS_HEAVY_KILL_AFTER", "TRELLIS_HEAVY_FUTURE_OPTION"):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: "changed"}):
                self.assertNotEqual(VERDICT.capture_inputs(self.root), self.inputs)

    def test_additional_tool_identities_bind_binary_changes(self):
        executable = self.base / "tool"
        self.tools.stop()
        try:
            for name in ("timeout", "gtimeout", "uv", "shfmt", "lsof", "ps", "gh", "npm", "npx"):
                self.assertIn(name, VERDICT.TOOLS)
                with self.subTest(name=name), mock.patch.object(VERDICT.shutil, "which", side_effect=lambda tool: str(executable) if tool == name else None):
                    executable.write_bytes(b"version one")
                    before = VERDICT.toolchain(self.root, lambda *args: "fixture tool 1")
                    executable.write_bytes(b"version two")
                    after = VERDICT.toolchain(self.root, lambda *args: "fixture tool 1")
                    self.assertNotEqual(before[name]["binary"], after[name]["binary"])
        finally:
            self.tools.start()

    def test_npm_package_upgrade_is_bound_without_invoking_npm(self):
        package = self.base / "npm/package.json"
        executable = self.base / "npm/bin/npm-cli.js"
        executable.parent.mkdir(parents=True)
        executable.write_text("require('../lib/cli.js')\n")
        self.tools.stop()
        try:
            with mock.patch.object(VERDICT.shutil, "which", side_effect=lambda name: str(executable) if name in ("npm", "npx") else None):
                def never_probe(*args):
                    self.fail("npm/npx must not be executed")
                package.write_text('{"version":"1"}\n')
                before = VERDICT.toolchain(self.root, never_probe)
                package.write_text('{"version":"2"}\n')
                after = VERDICT.toolchain(self.root, never_probe)
                for name in ("npm", "npx"):
                    self.assertEqual(before[name]["binary"], after[name]["binary"])
                    self.assertNotEqual(before[name]["package"], after[name]["package"])
        finally:
            self.tools.start()

    def test_verdict_age_is_capped_at_seven_days(self):
        now = time.time()
        metadata = self.state / "passing-runs" / self.id / "run.json"
        record = json.loads(self.path.read_text())
        run = json.loads(metadata.read_text())
        for age, reusable in ((1, True), (7 * 86400, True), (7 * 86400 + 1, False), (-1, False)):
            record["completed_at"] = run["completed_at"] = now - age
            GATE.save_record(self.path, record)
            GATE.save_record(metadata, run)
            with self.subTest(age=age), mock.patch.object(VERDICT.time, "time", return_value=now):
                self.assertEqual(VERDICT.find_verdict(self.inputs, self.state) is not None, reusable)

    def test_narrowed_and_test_seam_inputs_never_qualify(self):
        for name in ("PG_PUSH_TEST_SCOPE", "BATS_TEST_FILTER", "TRELLIS_TEST_TSV",
                     "TRELLIS_LOCAL_GATE_RUNNER", "TRELLIS_LOCAL_GATE_DEADLINE", "AGGREGATE_SCRIPT", "PACKER"):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: "test"}):
                self.assertIsNone(VERDICT.safe_inputs(self.root))

    def test_active_or_quarantined_run_never_reuses_an_older_pass(self):
        runs = self.state / "runs"
        runs.mkdir(mode=0o700)
        for marker in (self.state / "gate-holder.json", runs / ("d" * 32 + ".json")):
            marker.write_text("unresolved evidence\n")
            marker.chmod(0o600)
            self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))
            marker.unlink()
            self.assertIsNotNone(VERDICT.find_verdict(self.inputs, self.state))

    def test_weekly_snapshot_ignores_occupancy_not_disable_or_bad_evidence(self):
        marker = self.state / "gate-holder.json"
        marker.write_text("occupied\n")
        self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))
        self.assertEqual(len(VERDICT.tree_verdicts(self.inputs["tree"], self.state)), 1)
        disabled = self.state / "reuse-disabled.json"
        disabled.write_text("P1\n")
        self.assertEqual(VERDICT.tree_verdicts(self.inputs["tree"], self.state), [])
        disabled.unlink()
        aggregate = self.state / "passing-runs" / self.id / "aggregate.tsv"
        aggregate.write_text("bad evidence\n")
        self.assertEqual(VERDICT.tree_verdicts(self.inputs["tree"], self.state), [])

    def test_reap_does_not_invalidate_a_pass(self):
        with mock.patch.object(GATE, "_invalidate_verdicts", side_effect=AssertionError("administrative reap invalidated a pass")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main(["--runs-reap"]), 0)
        self.assertIsNotNone(VERDICT.find_verdict(self.inputs, self.state))

    def test_tests_row_reuses_but_static_and_coverage_still_execute(self):
        log = self.base / "checks.log"
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        shim = bin_dir / "python3"
        shim.write_text('#!/usr/bin/env bash\nif [ "${1:-}" = scripts/run-tests-local.py ]; then\n'
                        '  printf "tests\\n" >> "$CHECK_LOG"; exit 0\nfi\nexec "$REAL_PYTHON" "$@"\n')
        shim.chmod(0o755)
        self.tools.stop()
        try:
            with mock.patch.dict(os.environ, {"PATH": str(bin_dir) + os.pathsep + self.versioned_path(),
                    "PWD": str(self.root), "OLDPWD": str(self.root), "CODEX_PROJECT_DIR": str(self.root),
                    "CLAUDE_PROJECT_DIR": str(self.root), "CHECK_LOG": str(log), "REAL_PYTHON": sys.executable,
                    "PROCESS_GATE_TYPECHECK_CMD": 'printf "typecheck\\n" >> "$CHECK_LOG"',
                    "PROCESS_GATE_LINT_CMD": 'printf "lint\\n" >> "$CHECK_LOG"',
                    "PROCESS_GATE_COVERAGE_CMD": 'printf "coverage\\n" >> "$CHECK_LOG"',
                    "PROCESS_GATE_TEST_CMD": "python3 scripts/run-tests-local.py",
                    "PROCESS_GATE_HEAVY_LAUNCHER": "/not/a/launcher"}):
                self.clear_hook_git_env()
                self.inputs = VERDICT.capture_inputs(self.root)
                self.keep()
                command = ["bash", str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"), "--range=HEAD~1..HEAD"]
                result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("reused verdict " + self.id, result.stdout)
                self.assertEqual(log.read_text().splitlines(), ["typecheck", "lint", "coverage"])
                # An input change is a cache miss, and only the real test command
                # executes on that miss (the shim never invokes a battery).
                os.environ["A_TEST_INPUT"] = "changed"
                result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("reused verdict", result.stdout)
                self.assertEqual(log.read_text().splitlines()[-4:], ["typecheck", "lint", "tests", "coverage"])
        finally:
            self.tools.start()

    def test_selected_runs_never_publish_full_and_gate_interface_is_parent_only(self):
        self.run_runner_cases(("selected", "gate-interface"))

    def test_runner_writes_only_complete_verified_empty_green(self):
        self.run_runner_cases(("preflight", "fail", "partial", "timeout", "killed", "survivors", "pass"))

    def test_disabled_green_run_publishes_no_verdict(self):
        self.run_runner_cases(("disabled",))

    def test_failed_close_deletes_a_published_verdict(self):
        self.run_runner_cases(("close-fail",))

    def test_midrun_input_change_prevents_publication(self):
        self.run_runner_cases(("changed",))

    def run_runner_cases(self, modes):
        # Synthetic planner/shards exercise main's real result/finalization path;
        # there are no child processes, host scans, or actual battery commands.
        runner_spec = importlib.util.spec_from_file_location("fixture_runner", self.root / "scripts/run-tests-local.py")
        runner = importlib.util.module_from_spec(runner_spec)
        runner_spec.loader.exec_module(runner)
        runner.SHARD_COUNT = 1
        for mode in modes:
            self.keep()  # A failed rerun must also invalidate an older green.
            if mode == "disabled":
                (self.state / "reuse-disabled.json").write_text("P1\n")
            with self.subTest(mode=mode), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                token = {"pass": "c", "selected": "d", "gate-interface": "e"}.get(mode, "b") * 32
                def new_run(state, root, end, started_us, started, unreadable):
                    run_root = Path(tempfile.mkdtemp(prefix="tg-", dir="/tmp")).resolve()
                    (run_root / "tmp").mkdir(mode=0o700)
                    data = {"token": token, "run_root": str(run_root),
                            "head": self.git("rev-parse", "HEAD").decode().strip()}
                    path = state.runs / (token + ".json")
                    runner.save_record(path, data)
                    return data, path, os.open(str(run_root / "sentinel"), os.O_CREAT | os.O_RDWR, 0o600)
                events = []
                def spawn(data, path, fd, processes, command, root, environment, output):
                    if command == ["fixture-version"]:
                        self.assertEqual(environment["TRELLIS_GATE_RUN_ID"], token)
                        self.assertEqual(environment["TMPDIR"], data["run_root"] + "/tmp")
                        os.fstat(fd)
                        events.append("probe")
                        output.write(b"two\n" if mode == "changed" and events.count("probe") == 2 else b"one\n")
                    elif "--plan" in command:
                        output.write(b"shard\tstage\tweight\n1\tfixture\t1\ntotal\t1\t1\n")
                    else:
                        if mode == "timeout":
                            raise runner._DeadlineExit()
                        if mode == "killed":
                            raise runner._SignalExit(15)
                        if mode != "partial":
                            Path(environment["TRELLIS_TEST_TSV"]).write_text("ordinal\tstage\telapsed_seconds\texit\n1\tfixture\t1\t0\n")
                    process = types.SimpleNamespace(returncode=7 if mode == "fail" and "--plan" not in command and command != ["fixture-version"] else 0)
                    process.wait = lambda: process.returncode
                    processes.append(process)
                    return process
                def teardown(*args):
                    events.append("teardown")
                    return 1 if mode == "survivors" else 0
                def write_verdict(state, *args):
                    self.assertTrue((state.root / "gate-holder.json").exists(), "released before verdict publication")
                    self.assertEqual(events[-1], "teardown", "probe launched after verified-empty cleanup")
                    if mode == "selected":
                        self.assertIsNone(args[0], "selected run captured full-verdict inputs")
                        self.assertIsNone(args[1], "selected run captured full-verdict final inputs")
                    if mode == "gate-interface":
                        self.assertFalse(any(name.startswith("PG_TESTS_") for name in os.environ))
                    if mode == "changed":
                        self.assertEqual(events.count("probe"), 2)
                        self.assertIsNotNone(args[0])
                        self.assertIsNotNone(args[1])
                        self.assertNotEqual(args[0], args[1])
                    GATE._write_verdict(state, *args)
                    if mode == "close-fail":
                        self.assertTrue(self.path.exists(), "test never exercised deletion after publication")
                        events.append("published")
                original_close = runner.RunState.close
                def close(state, deadline=None):
                    original_close(state, deadline)
                    if mode == "close-fail":
                        self.assertEqual(events[-1], "published")
                        raise runner.ContainmentError("synthetic failure after publication")
                interface = {"PG_TESTS_BASE": self.git("rev-parse", "HEAD~1").decode().strip(),
                             "PG_TESTS_HEAD": self.git("rev-parse", "HEAD").decode().strip(),
                             "PG_TESTS_RECEIPT_FILE": str(self.base / "scope.txt")} if mode in ("selected", "gate-interface") else {}
                with mock.patch.dict(os.environ, interface), mock.patch.object(runner, "_capability", side_effect=runner.ContainmentError("preflight") if mode == "preflight" else None, return_value=[]), \
                        mock.patch.object(VERDICT, "toolchain", side_effect=lambda root, version_probe: {"bash": {"version": version_probe(["fixture-version"], {}, root)}}), \
                        mock.patch.object(runner, "_write_verdict", side_effect=write_verdict), \
                        mock.patch.object(runner.RunState, "close", close), \
                        mock.patch.object(runner, "_new_run", side_effect=new_run), \
                        mock.patch.object(runner, "_spawn", side_effect=spawn), \
                        mock.patch.object(runner, "observe_exit", side_effect=lambda p: p.returncode), \
                        mock.patch.object(runner, "_replay_output"), \
                        mock.patch.object(runner.Boundary, "teardown", side_effect=teardown):
                    result = runner.main(["--no-wait", "--test-file=scripts/tests/sample.bats"] if mode == "selected" else [])
                self.assertEqual(result == 0, mode in ("pass", "disabled", "changed", "selected", "gate-interface"))
                found = VERDICT.find_verdict(self.inputs, self.state)
                self.assertEqual(found is not None, mode in ("pass", "gate-interface"))
                if interface:
                    expected = "narrowed 1" if mode == "selected" else "full"
                    self.assertEqual((self.base / "scope.txt").read_text(), "PG_TESTS_RECEIPT " + expected + "\n")
                if mode in ("disabled", "close-fail", "changed"):
                    self.assertFalse(self.path.exists(), "green verdict survived a disabled or failed finalization")
                # A quarantined synthetic run must not affect the next subcase.
                for record in (self.state / "runs").glob("*.json"):
                    data = json.loads(record.read_text())
                    shutil.rmtree(data["run_root"])
                    record.unlink()


for field in ("schema", "tree", "inventory", "suite_versions", "runner", "toolchain", "environment", "refs", "git_config", "platform"):
    setattr(VerdictTests, "test_mutation_" + field, lambda self, field=field: self.mutate(field))

if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
