"""Hermetic T32 collection/promotion fixtures; never run the real battery."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("full_trace", ROOT / "scripts/trace-release-metadata.py")
TRACE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRACE)
from tag_push_reuse import tag_suites


class TraceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        helper = self.root / "scripts/lib/test-suites.sh"
        helper.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/lib/test-suites.sh", helper)
        self.suites = ["scripts/tests/alpha.bats", "scripts/tests/beta.bats",
                       "core-rules/hooks/tests/hook.bats", "core-rules/codex/hooks/tests/codex.bats",
                       "core-rules/skills/sample/tests/skill.bats"]
        for suite in self.suites + ["scripts/tests/install-disk-janitor-launchd.bats"]:
            path = self.root / suite
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('@test "fixture" { true; }\n')
        (self.root / "scripts/tests/beta.bats").chmod(0o755)
        self.manifest = self.root / TRACE.MANIFEST
        self.manifest.write_text('{"complete": false}\n')
        self.git("init", "-q", "-b", "main")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.run_dir = self.base / "collection"
        (self.run_dir / "logs").mkdir(parents=True)
        self.suites.sort()
        self.receipt = {"schema": 1, "scope": "ci", "finished": True,
                        "traced_revision": self.git("rev-parse", "HEAD").strip(),
                        "source_digest": TRACE.source_digest(self.root, "HEAD", TRACE.MANIFEST),
                        "inventory": self.suites, "traces": {}}
        self.receipt["finished_source_digest"] = self.receipt["source_digest"]
        for index, suite in enumerate(self.suites, 1):
            relative = "logs/{:04d}.strace".format(index)
            content = ('100 openat(AT_FDCWD, "/src/CHANGELOG.md", O_RDONLY) = 3</src/CHANGELOG.md>\n'
                       '100 newfstatat(AT_FDCWD, "/src/.git/packed-refs", {st_mode=S_IFREG}, 0) = 0\n'
                       '100 +++ exited with 0 +++\n').encode()
            (self.run_dir / relative).write_bytes(content)
            self.receipt["traces"][suite] = {"log": relative, "exit": 0, "trace_sha256": TRACE.digest(content)}
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), "-c", "user.name=Fixture",
                                        "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", *args], text=True)

    def save(self):
        (self.run_dir / "run.json").write_text(json.dumps(self.receipt))

    def command(self, mode="--promote-run"):
        return subprocess.run([sys.executable, "-I", str(ROOT / "scripts/trace-release-metadata.py"),
                               mode, str(self.run_dir), "--root", str(self.root)], text=True, capture_output=True)

    def refused(self):
        before = self.manifest.read_bytes()
        result = self.command()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.manifest.read_bytes(), before, "refusal overwrote the audit")
        return result.stderr

    def test_missing_suite_log_refuses_promotion(self):
        suite = self.suites[-1]
        (self.run_dir / self.receipt["traces"][suite]["log"]).unlink()
        self.assertIn("missing suite log", self.refused())
        self.receipt["traces"].pop(suite)
        self.save()
        self.assertIn("missing suite log", self.refused())

    def test_digest_drift_refuses_promotion(self):
        (self.root / "scripts/changed-source.sh").write_text("echo changed\n")
        self.git("add", ".")
        self.git("commit", "-qm", "drift")
        self.assertIn("digest drift", self.refused())

    def test_unparseable_log_refuses_promotion(self):
        entry = self.receipt["traces"][self.suites[0]]
        for content in (b"not a strace log\n", b"", b'100 openat(AT_FDCWD, "VERSION", O_RDONLY <unfinished ...>\n',
                        b'100 openat(AT_FDCWD, "VERSION", O_RDONLY) = 3\n'):
            with self.subTest(content=content):
                (self.run_dir / entry["log"]).write_bytes(content)
                entry["trace_sha256"] = TRACE.digest(content)
                self.save()
                self.refused()

    def test_complete_fixture_requires_explicit_promotion(self):
        self.assertEqual(TRACE.inventory(self.root), self.suites)
        result = self.command("--run")
        self.assertEqual(result.returncode, 0, result.stderr)
        candidate = json.loads((self.run_dir / "audit.json").read_text())
        self.assertIs(candidate["complete"], False)
        self.assertIs(json.loads(self.manifest.read_text())["complete"], False)
        result = self.command()
        self.assertEqual(result.returncode, 0, result.stderr)
        audit = json.loads(self.manifest.read_text())
        self.assertIs(audit["complete"], True)
        self.assertEqual(audit["scope"], "full-ci")
        self.assertEqual(audit["source_digest"], TRACE.source_digest(self.root, "HEAD", TRACE.MANIFEST))
        self.assertEqual(audit["inventory"], self.suites)
        self.assertEqual(sorted(audit["observations"]), self.suites)
        self.assertEqual(audit["suites"], self.suites)
        self.assertTrue(all(entry["tag_reads"] for entry in audit["observations"].values()))
        self.git("add", TRACE.MANIFEST)
        self.git("commit", "-qm", "promote fixture")
        self.assertEqual(tag_suites(self.root, "HEAD"), self.suites)

    def test_nonzero_exit_and_tampered_log_refuse_promotion(self):
        entry = self.receipt["traces"][self.suites[0]]
        entry["exit"] = 7
        self.save()
        self.assertIn("nonzero strace exit", self.refused())
        entry["exit"] = 0
        self.save()
        (self.run_dir / entry["log"]).write_bytes(b'100 access("VERSION", R_OK) = 0\n100 +++ exited with 0 +++\n')
        self.assertIn("trace digest mismatch", self.refused())

    def test_file_and_git_object_reads_are_conservative(self):
        content = (b'100 access("/src/core-rules/VERSION", R_OK) = 0\n'
                   b'100 newfstatat(AT_FDCWD, "/src/docs/adr/001-change.md", {}, 0) = 0\n'
                   b'100 openat(AT_FDCWD, "/repo/.git/objects/pack/pack-abcd.pack", O_RDONLY) = 3\n'
                   b'100 openat(AT_FDCWD, "ignored/VERSION", O_WRONLY|O_CREAT, 0600) = 4\n'
                   b'100 +++ exited with 0 +++\n')
        result = TRACE.parsed_trace(content)
        self.assertIn("core-rules/VERSION", result["metadata"])
        self.assertIn("docs/adr/001-change.md", result["metadata"])
        self.assertIn("CHANGELOG.md", result["metadata"])
        self.assertTrue(result["tag_reads"])
        resumed = (b'100 openat(AT_FDCWD</repo>, "VERSION", O_RDONLY <unfinished ...>\n'
                   b'101 access("/repo/CHANGELOG.md", R_OK) = 0\n'
                   b'100 <... openat resumed>) = 3\n'
                   b'101 +++ exited with 0 +++\n100 +++ exited with 0 +++\n')
        self.assertEqual(TRACE.parsed_trace(resumed)["metadata"], ["CHANGELOG.md", "VERSION"])

    def promoted_observation(self, body):
        content = (body + '\n100 +++ exited with 0 +++\n').encode()
        suite = self.suites[0]
        entry = self.receipt["traces"][suite]
        (self.run_dir / entry["log"]).write_bytes(content)
        entry["trace_sha256"] = TRACE.digest(content)
        self.save()
        result = self.command()
        self.assertEqual(result.returncode, 0, result.stderr)
        audit = json.loads(self.manifest.read_text())
        self.assertIs(audit["complete"], True)
        observation = audit["observations"][suite]
        self.assertEqual(observation["trace_sha256"], TRACE.digest(content))
        return observation

    def test_symlink_targets_use_resolved_fd_paths(self):
        for target in ("VERSION", "core-rules/VERSION", "CHANGELOG.md", "docs/adr/001-decision.md"):
            with self.subTest(target=target):
                result = self.promoted_observation('100 openat(AT_FDCWD</repo>, "/tmp/alias", O_RDONLY) = 3</repo/' + target + '>')
                self.assertEqual(result["metadata"], [target])
        result = self.promoted_observation('100 openat(AT_FDCWD</repo>, "/tmp/O_WRONLY", O_RDONLY) = 3</repo/CHANGELOG.md>')
        self.assertEqual(result["metadata"], ["CHANGELOG.md"])
        for target in ("packed-refs", "refs/tags/v1.3.22"):
            with self.subTest(target=target):
                result = self.promoted_observation('100 openat(AT_FDCWD</repo>, "/tmp/alias", O_RDONLY) = 3</repo/.git/' + target + '>')
                self.assertTrue(result["tag_reads"])

    def test_dirfd_relative_adr_probes_are_classified(self):
        for call, rest in (("newfstatat", '{st_mode=S_IFREG|0644}, 0'),
                           ("openat2", '{flags=O_RDONLY, resolve=0}, 24'),
                           ("faccessat2", 'R_OK, 0'), ("readlinkat", '"target", 4096')):
            with self.subTest(call=call):
                result = self.promoted_observation('100 ' + call + '(3</repo/docs/adr>, "001-decision.md", ' + rest + ') = 0')
                self.assertIn("docs/adr/001-decision.md", result["metadata"])

    def test_empty_path_uses_fd_target(self):
        for call, rest in (("statx", 'AT_EMPTY_PATH, STATX_BASIC_STATS, {}'),
                           ("newfstatat", '{st_mode=S_IFREG}, AT_EMPTY_PATH'),
                           ("faccessat2", 'R_OK, AT_EMPTY_PATH'),
                           ("execveat", '["fixture"], 0x0, AT_EMPTY_PATH')):
            with self.subTest(call=call):
                result = self.promoted_observation('100 ' + call + '(4</repo/docs/adr/002-statx.md>, "", ' + rest + ') = 0')
                self.assertIn("docs/adr/002-statx.md", result["metadata"])

    def test_relative_tag_operand_is_classified(self):
        result = self.promoted_observation('100 newfstatat(AT_FDCWD</repo/.git>, "refs/tags/v1.3.22", {st_mode=S_IFREG}, 0) = 0')
        self.assertTrue(result["tag_reads"])
        self.assertEqual(result["metadata"], [])

    def test_dirfd_relative_tag_operand_is_classified(self):
        result = self.promoted_observation('100 newfstatat(3</repo/.git/refs>, "tags/v1.3.22", {st_mode=S_IFREG}, 0) = 0')
        self.assertTrue(result["tag_reads"])
        self.assertEqual(result["metadata"], [])

    def test_split_resumed_paths_preserve_flags_and_targets(self):
        for flags in ("O_RDONLY", "O_WRONLY|O_CREAT"):
            with self.subTest(flags=flags):
                result = self.promoted_observation('100 openat(AT_FDCWD</repo>, "/tmp/ver-link", ' + flags + ' <unfinished ...>\n'
                    '101 access("/etc/passwd", R_OK) = 0\n101 +++ exited with 0 +++\n'
                    '100 <... openat resumed>) = 3</repo/VERSION>')
                self.assertEqual(result["metadata"], ["VERSION"] if flags == "O_RDONLY" else [])

    def test_o_path_is_a_metadata_dependency(self):
        result = self.promoted_observation('100 openat(AT_FDCWD</repo>, "/tmp/ver-link", O_PATH) = 3</repo/VERSION>')
        self.assertEqual(result["metadata"], ["VERSION"])
        self.assertFalse(result["tag_reads"])

    def test_killed_unfinished_call_retains_path_evidence(self):
        result = self.promoted_observation('100 access("/etc/passwd", R_OK) = 0\n'
            '101 openat(3</repo/docs/adr>, "003-blocked.md", O_RDONLY <unfinished ...>\n'
            '101 +++ killed by SIGKILL +++')
        self.assertIn("docs/adr/003-blocked.md", result["metadata"])

    def test_unresolved_operands_select_both_classes(self):
        for body in ('100 newfstatat(3, "notes.md", {}, 0) = 0',
                     '100 statx(4, "", AT_EMPTY_PATH, STATX_BASIC_STATS, {}) = 0',
                     '100 openat(AT_FDCWD, "notes.md", O_RDONLY) = 3',
                     '100 openat(AT_FDCWD, "/tmp/alias", O_RDONLY) = 3',
                     '100 statx(4</tmp/alias (deleted)>, "", AT_EMPTY_PATH, STATX_BASIC_STATS, {}) = 0'):
            with self.subTest(body=body):
                result = self.promoted_observation(body)
                self.assertEqual(result["metadata"], ["CHANGELOG.md", "VERSION", "core-rules/VERSION", "docs/adr/*"])
                self.assertTrue(result["tag_reads"])

    def probe_suite(self, probe):
        directory = self.base / "probe-run"
        (directory / "logs").mkdir(parents=True)
        (directory / "sandboxes").mkdir()
        links = self.base / "tools"
        links.mkdir()
        for name, pin in (("git", "TRELLIS_TEST_REAL_GIT"), ("mktemp", "TRELLIS_TEST_REAL_MKTEMP")):
            (links / name).symlink_to(os.environ.get(pin) or shutil.which(name))
        tools = {"git": str(links / "git"), "mktemp": str(links / "mktemp"),
                 "strace": "/fixture/strace", "bats": "/fixture/bats"}
        real_run = subprocess.run
        def tracer(command, **kwargs):
            probe(kwargs["env"], real_run)
            Path(command[command.index("-o") + 1]).write_text('100 access("/etc/passwd", R_OK) = 0\n100 +++ exited with 0 +++\n')
            return subprocess.CompletedProcess(command, 0)
        with mock.patch.object(TRACE.subprocess, "run", side_effect=tracer):
            result = TRACE.trace_suite(ROOT, directory, self.suites[0], 1, tools)
        self.assertEqual(result["exit"], 0)

    def test_trace_launchers_survive_scrubbed_environment(self):
        def probe(env, run):
            sandbox = Path(env["TRELLIS_TEST_GIT_FENCE_ROOT"])
            clean = {"PATH": env["PATH"], "HOME": env["HOME"], "GIT_CONFIG_GLOBAL": env["GIT_CONFIG_GLOBAL"], "GIT_CONFIG_NOSYSTEM": "1"}
            for tool in ("git", "mktemp"):
                body = (sandbox / "bin" / tool).read_text()
                self.assertIn("# trellis-test-fence-launcher-v1", body)
            self.assertEqual(env["TRELLIS_TEST_REAL_GIT"], os.path.realpath(self.base / "tools/git"))
            self.assertEqual(env["TRELLIS_TEST_REAL_MKTEMP"], os.path.realpath(self.base / "tools/mktemp"))
            self.assertEqual(env["TRELLIS_TEST_REAL_PYTHON"], os.path.realpath(sys.executable))
            result = run(["git", "init", "-q", str(sandbox / "repo")], env=clean, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = run(["mktemp", "-d"], env=clean, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(sandbox, Path(result.stdout.strip()).parents)
        self.probe_suite(probe)

    def test_trace_launchers_override_forged_pins(self):
        def probe(env, run):
            sandbox = Path(env["TRELLIS_TEST_GIT_FENCE_ROOT"])
            outside = self.base / "outside"
            outside.mkdir()
            forged = dict(env, TRELLIS_TEST_GIT_FENCE_ROOT=str(outside))
            for name in ("GIT", "MKTEMP", "PYTHON"):
                fake = self.base / ("fake-" + name)
                fake.write_text('#!/bin/sh\nprintf called > "' + str(self.base / "forged-called") + '"\nexit 88\n')
                fake.chmod(0o700)
                forged["TRELLIS_TEST_REAL_" + name] = str(fake)
            result = run(["git", "init", "-q", str(sandbox / "repo")], env=forged, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = run(["git", "init", "-q", str(outside / "escape")], env=forged, capture_output=True, text=True)
            self.assertEqual(result.returncode, 97, result.stderr)
            self.assertFalse((outside / "escape").exists())
            result = run(["mktemp", "-d"], env=forged, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(sandbox, Path(result.stdout.strip()).parents)
            self.assertFalse((self.base / "forged-called").exists())
        self.probe_suite(probe)

    def test_trace_scrubs_pi_and_xdg_environment(self):
        def probe(env, run):
            self.assertFalse(any(key.startswith(("PI_", "XDG_")) for key in env))
        with mock.patch.dict(os.environ, {"PI_CODING_AGENT_DIR": str(self.base / "live-pi"),
                "PI_FIXTURE_OTHER": "sentinel", "XDG_CONFIG_HOME": str(self.base / "live-config"),
                "XDG_STATE_HOME": str(self.base / "live-state"), "XDG_FIXTURE_OTHER": "sentinel"}):
            self.probe_suite(probe)

    def test_driver_bounds_workers_and_sandboxes_every_inventory_suite(self):
        fake = self.base / "bin"
        fake.mkdir()
        tracer = fake / "strace"
        events = self.base / "events"
        tracer.write_text("#!/bin/sh\nexec " + str(Path(sys.executable)) + " -I " + str(self.base / "fake.py") + ' "$@"\n')
        tracer.chmod(0o700)
        (self.base / "fake.py").write_text('''import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
assert args[:6] == ['-f', '-yy', '-s', '4096', '-e', 'trace=%file'], args
log = Path(args[args.index('-o') + 1])
base = log.parents[1]
home, tmp, trellis = (Path(os.environ[key]) for key in ('HOME', 'TMPDIR', 'TRELLIS_HOME'))
assert all(base in path.parents for path in (home, tmp, trellis))
assert len({home, tmp, trellis}) == 3
suite = args[-1]
with open(os.environ['TRACE_EVENTS'], 'a') as out:
    out.write(json.dumps({'suite': suite, 'event': 'start', 'time': time.monotonic(), 'home': str(home)}) + '\\n')
time.sleep(.2)
log.write_text('100 access("CHANGELOG.md", R_OK) = 0\\n100 +++ exited with 0 +++\\n')
with open(os.environ['TRACE_EVENTS'], 'a') as out:
    out.write(json.dumps({'suite': suite, 'event': 'end', 'time': time.monotonic()}) + '\\n')
''')
        # Bats is never executed by this fake tracer. All real suites remain for
        # the later Linux owner run, not this fixture.
        (fake / "bats").symlink_to(shutil.which("true"))
        output = self.base / "driver-run"
        with mock.patch.object(TRACE.sys, "platform", "linux"), \
                mock.patch.dict(os.environ, {"PATH": str(fake) + os.pathsep + os.environ["PATH"], "TRACE_EVENTS": str(events)}), \
                contextlib.redirect_stdout(io.StringIO()):
            candidate = TRACE.collect(self.root, output, 2)
        self.assertIs(candidate["complete"], False)
        self.assertEqual(sorted(candidate["observations"]), self.suites)
        rows = [json.loads(line) for line in events.read_text().splitlines()]
        self.assertEqual(sorted(row["suite"] for row in rows if row["event"] == "start"), self.suites)
        self.assertEqual(len({row["home"] for row in rows if row["event"] == "start"}), len(self.suites))
        live, peak = 0, 0
        for row in sorted(rows, key=lambda row: row["time"]):
            live += 1 if row["event"] == "start" else -1
            peak = max(peak, live)
        self.assertEqual(live, 0)
        self.assertEqual(peak, 2)
        run = json.loads((output / "run.json").read_text())
        self.assertTrue(run["finished"])
        self.assertTrue(all(entry["exit"] == 0 for entry in run["traces"].values()))
        self.assertEqual(list((output / "sandboxes").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
