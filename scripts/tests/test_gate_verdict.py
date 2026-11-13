"""Exact-input cache mutation and runner lifecycle tests, all in a private repo."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import pwd
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
def _bats_internal(directory):
    """An outer Bats run's libexec directory (BATS_LIBEXEC, or the bats-core one)."""
    if not directory:
        return False
    libexec = os.environ.get("BATS_LIBEXEC")
    return (libexec is not None and os.path.realpath(directory) == os.path.realpath(libexec)) \
        or Path(directory).name == "bats-core" and (Path(directory) / "bats-exec-suite").exists()


# Ambient names a fixture keeps; every other variable is dropped in setUp.
AMBIENT_KEPT = ("PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL", "LC_CTYPE",
                "BATS_LIBEXEC", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")


class VerdictTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        self.state = self.base / "state"
        self.state.mkdir(mode=0o700)
        self.store = self.base / "trellis/state/gate-verdicts"
        # A fixed environment: no ambient export (a qualification run's
        # CARGO_HOME or CARGO_NET_OFFLINE, an outer runner's receipts or
        # selection adapters, RUST*/CC*/AR* build inputs) may reach a fixture.
        # Only names that locate the host's tools and locale survive; HOME is a
        # fresh fixture home. The patch restores the caller on teardown.
        kept = {name: os.environ[name] for name in AMBIENT_KEPT if name in os.environ}
        # An outer Bats prepends its internal libexec driver to PATH; it runs
        # only with the BASH_FUNC_bats_* functions the outer run exports, which
        # this environment drops (they would also join the verdict key). Nested
        # gates must resolve the public `bats` frontend instead.
        if "PATH" in kept:
            kept["PATH"] = os.pathsep.join(part for part in kept["PATH"].split(os.pathsep)
                                           if not _bats_internal(part))
        home = self.base / "home"
        home.mkdir()
        self.env = mock.patch.dict(os.environ, kept | {"TRELLIS_GATE_STATE_DIR": str(self.state),
            "HOME": str(home), "TRELLIS_HOME": str(self.base / "trellis"),
            "TRELLIS_TEST_SHARDS": "1", "GIT_OPTIONAL_LOCKS": "0", "TRELLIS_LOCAL_GATE_QUEUE_WAIT": ".3"}, clear=True)
        self.env.start()
        for name in VERDICT.RUNNER_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        (self.root / "scripts/tests/sample.bats").write_text("# suite v1\n")
        archive = b"fixture archive\n"
        cache = home / ".cargo/registry/cache/index.crates.io-fixture"
        index = home / ".cargo/registry/index/index.crates.io-fixture"
        cache.mkdir(parents=True)
        (index / ".cache/li/bc").mkdir(parents=True)
        (cache / "libc-0.2.178.crate").write_bytes(archive)
        (index / ".cache/li/bc/libc").write_bytes(b"fixture index\n")
        (index / "config.json").write_text("{}\n")
        (self.root / "native/trellis-hooks/Cargo.lock").write_text(
            'version = 4\n[[package]]\nname = "libc"\nversion = "0.2.178"\n'
            'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
            'checksum = "' + hashlib.sha256(archive).hexdigest() + '"\n')
        machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine(), platform.machine())
        host = machine + ("-apple-darwin" if platform.system() == "Darwin" else "-unknown-linux-gnu")
        toolchain = home / ".rustup/toolchains" / ("1.97.1-" + host) / "bin"
        toolchain.mkdir(parents=True)
        (toolchain / "rustc").write_text('#!/bin/sh\nprintf "rustc 1.97.1 (fixture)\\nhost: %s\\nrelease: 1.97.1\\n" "' + host + '"\n')
        for name in ("cargo", "rustdoc"):
            (toolchain / name).write_text("#!/bin/sh\nexit 0\n")
        for name in ("cargo", "rustc", "rustdoc"):
            (toolchain / name).chmod(0o755)
        sysroot = toolchain.parent / "lib/rustlib"
        (sysroot / host / "lib").mkdir(parents=True)
        (sysroot / "multirust-channel-manifest.toml").write_text("fixture manifest\n")
        (sysroot / "components").write_text("fixture components\n")
        (toolchain.parent / "lib/librustc_driver-fixture.so").write_text("fixture driver\n")
        (sysroot / host / "lib/libcore-fixture.rlib").write_text("fixture stdlib\n")
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
        GATE._write_verdict(types.SimpleNamespace(root=self.state), self.inputs, VERDICT.safe_inputs(self.root), kept,
                            VERDICT.ref_rows(self.root))
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
        self.assertNotEqual(changed["tree"], self.inputs["tree"])
        old_head = self.git("rev-parse", "HEAD~1").decode().strip()
        self.assertIsNone(VERDICT.safe_inputs(self.root, old_head))
        (self.root / "scripts/tests/new.bats").write_text("# new suite\n")
        self.commit()
        self.assertNotEqual(VERDICT.capture_inputs(self.root)["tree"], changed["tree"])
        self.assertNotEqual(VERDICT.capture_inputs(self.root, command="node --test --test-concurrency=1")["command"],
                            VERDICT.capture_inputs(self.root)["command"])

    def test_native_cargo_inputs_and_test_seams_bind_full_battery_reuse(self):
        home = Path(os.environ["HOME"])
        fenced = self.base / "fenced-home"
        fenced.mkdir()
        with mock.patch.dict(os.environ, {"HOME": str(fenced)}), \
                mock.patch.object(pwd, "getpwuid", return_value=types.SimpleNamespace(pw_dir=str(home))):
            self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
        toolchain = next((home / ".rustup/toolchains").iterdir()) / "bin"
        index = home / ".cargo/registry/index/index.crates.io-fixture/.cache/li/bc/libc"
        for path in (toolchain / "rustc", toolchain / "cargo", index):
            original = path.read_bytes()
            path.write_bytes(original + b"\n# changed\n")
            self.assertIsNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state), str(path))
            path.write_bytes(original)
            self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
        rustlib = toolchain.parent / "lib/rustlib"
        host = toolchain.parent.name.removeprefix("1.97.1-")
        for path in (rustlib / "multirust-channel-manifest.toml", rustlib / "components"):
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            self.assertIsNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state), str(path))
            path.write_bytes(original)
        for path in (toolchain.parent / "lib/librustc_driver-fixture.so",
                     rustlib / host / "lib/libcore-fixture.rlib"):
            original, metadata = path.read_bytes(), path.stat()
            path.write_bytes(original + b"changed")
            self.assertIsNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state), str(path))
            path.write_bytes(original)
            os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
        archive = home / ".cargo/registry/cache/index.crates.io-fixture/libc-0.2.178.crate"
        original = archive.read_bytes()
        archive.write_bytes(b"corrupt cache")
        self.assertIsNone(VERDICT.safe_inputs(self.root))
        archive.unlink()
        self.assertIsNone(VERDICT.safe_inputs(self.root))
        archive.write_bytes(original)
        with mock.patch.dict(os.environ, {"TRELLIS_A1_TEST_BIN": "/tmp/other-binary"}):
            self.assertIsNone(VERDICT.safe_inputs(self.root))
        for name in ("RUST_MIN_STACK", "CC", "CXX", "AR", "CFLAGS", "LDFLAGS"):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: "fixture"}):
                self.assertIsNone(VERDICT.safe_inputs(self.root))
        with mock.patch.dict(os.environ, {"RUST_TEST_THREADS": "1"}):
            one = VERDICT.capture_inputs(self.root)
            os.environ["RUST_TEST_THREADS"] = "2"
            two = VERDICT.capture_inputs(self.root)
            self.assertNotEqual(VERDICT.key(one), VERDICT.key(two))

    def test_native_cargo_version_probe_uses_the_contained_probe_callback(self):
        calls = []
        def contained(command, env, cwd):
            calls.append(command)
            return VERDICT.probe(command, env, cwd)
        self.assertIsNotNone(VERDICT.safe_inputs(self.root, version_probe=contained))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], "-vV")
        self.assertIsNone(VERDICT.safe_inputs(self.root, version_probe=lambda *args: "unavailable: probe timeout"))

    def test_native_stages_bind_the_pinned_toolchain_not_the_active_default(self):
        # r151-reuse4 R4 (Sol pinned-toolchain-probe): the native stages run
        # cargo +1.97.1, but a rustup default of stable keyed only stable.
        # The pinned cargo/rustc identity is bound through the caller's probe
        # whatever the default is; a changed pin misses, a removed one refuses.
        home = Path(os.environ["HOME"])
        toolchains = home / ".rustup/toolchains"
        pinned = next(toolchains.glob("1.97.1-*")) / "bin"
        for tool in ("cargo", "rustc"):
            binary = toolchains / "stable" / "bin" / tool
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text("#!/bin/sh\necho '%s 1.99.1 (stable)'\n" % tool)
            binary.chmod(0o755)
        dispatch = self.base / "dispatch"
        dispatch.mkdir()
        (dispatch / "rustup").write_text(
            '#!/bin/bash\ntc=stable\nname="${0##*/}"\nif [ "$name" = rustup ]; then\n case "$1" in\n'
            '  show) echo "stable (default)" ;;\n  which) echo "$HOME/.rustup/toolchains/stable/bin/$2" ;;\n esac\n'
            ' exit 0\nfi\nif [[ "${1:-}" = +* ]]; then tc="${1#+}"; shift; fi\n'
            'exec "$HOME/.rustup/toolchains/$tc/bin/$name" "$@"\n')
        (dispatch / "rustup").chmod(0o755)
        for tool in ("cargo", "rustc"):
            (dispatch / tool).symlink_to("rustup")
        probed = []

        def recording(command, env, cwd):
            probed.append(list(command))
            return VERDICT.probe(command, env, cwd)
        self.tools.stop()
        try:
            # The helper also tries the account home; pin it to the fixture.
            with mock.patch.dict(os.environ, {"PATH": str(dispatch) + os.pathsep + os.environ["PATH"]}), \
                    mock.patch.object(VERDICT, "TOOLS", ("cargo", "rustc")), \
                    mock.patch.object(pwd, "getpwuid", return_value=types.SimpleNamespace(pw_dir=str(home))):
                default = VERDICT.capture_inputs(self.root, version_probe=recording)
                self.assertEqual(default["toolchain"]["cargo"]["effective"]["active"], "stable (default)")
                self.inputs = default
                self.keep()
                self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
                for tool in ("cargo", "rustc"):
                    original = (pinned / tool).read_bytes()
                    (pinned / tool).write_bytes(original + b"# changed pin\n")
                    changed = VERDICT.capture_inputs(self.root)
                    self.assertEqual(changed["toolchain"], default["toolchain"], tool)  # the default is unchanged
                    self.assertNotEqual(VERDICT.key(changed), VERDICT.key(default), tool)
                    self.assertIsNone(VERDICT.find_verdict(changed, self.state), tool)
                    (pinned / tool).write_bytes(original)
                self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
                self.assertIn([str(pinned.resolve() / "rustc"), "-vV"], probed)  # through the caller's probe
                (pinned / "cargo").chmod(0o644)  # unreadable as a tool: refuses
                self.assertIsNone(VERDICT.safe_inputs(self.root))
                (pinned / "cargo").chmod(0o755)
                shutil.rmtree(pinned.parent)  # removed: refuses
                self.assertIsNone(VERDICT.safe_inputs(self.root))
        finally:
            self.tools.start()

    def test_native_identity_never_falls_back_past_an_unavailable_candidate(self):
        # r151-reuse4 R5 (Sol merge-fallback-probe): the helper tries each
        # installed 1.97.1 candidate; a gnu rustc -vV that outlives the 2 s
        # key probe let the key fall through to musl while the 30 s
        # preparation probe selected gnu. Any unavailable candidate costs reuse.
        old = Path(os.environ["HOME"])
        home = self.base / "linux-home"
        home.mkdir()
        shutil.copytree(old / ".cargo", home / ".cargo")
        for host, delay in (("x86_64-unknown-linux-gnu", 3), ("x86_64-unknown-linux-musl", 0)):
            toolchain = home / ".rustup/toolchains" / ("1.97.1-" + host)
            (toolchain / "bin").mkdir(parents=True)
            for tool in ("cargo", "rustdoc"):
                (toolchain / "bin" / tool).write_text("#!/bin/sh\nexit 0\n")
                (toolchain / "bin" / tool).chmod(0o755)
            (toolchain / "bin/rustc").write_text("#!/bin/sh\n" + ("sleep 3\n" if delay else "") +
                                                 'printf "rustc 1.97.1 (fixture)\\nhost: %s\\nrelease: 1.97.1\\n"\n' % host)
            (toolchain / "bin/rustc").chmod(0o755)
            rustlib = toolchain / "lib/rustlib"
            (rustlib / host / "lib").mkdir(parents=True)
            (rustlib / "multirust-channel-manifest.toml").write_text("manifest\n")
            (rustlib / "components").write_text("components\n")
            (rustlib / host / "lib/libcore-fixture.rlib").write_text("libcore\n")
            (toolchain / "lib/librustc_driver-fixture.so").write_text("driver\n")
        gnu = str(home / ".rustup/toolchains/1.97.1-x86_64-unknown-linux-gnu/bin/rustc")

        def gnu_unavailable(command, env, cwd):
            if command[0] == gnu:
                return "unavailable: probe timeout"
            return VERDICT.probe(command, env, cwd)
        with mock.patch.dict(os.environ, {"HOME": str(home)}), \
                mock.patch.object(platform, "system", return_value="Linux"), \
                mock.patch.object(platform, "machine", return_value="x86_64"), \
                mock.patch.object(pwd, "getpwuid", return_value=types.SimpleNamespace(pw_dir=str(home))):
            # Without timing: the first candidate's probe is unavailable.
            with self.assertRaises(VERDICT.ProbeUnavailable) as raised:
                VERDICT.capture_inputs(self.root, version_probe=gnu_unavailable)
            self.assertEqual(raised.exception.scope["tree"], self.inputs["tree"])
            # With the real bounded probe and a 3 s gnu rustc.
            with self.assertRaises(VERDICT.ProbeUnavailable):
                VERDICT.capture_inputs(self.root)
            self.assertIsNone(VERDICT.safe_inputs(self.root))

    def test_native_cargo_probe_timeout_costs_reuse_only(self):
        # A timed-out rustc -vV is a probe failure like a --version timeout:
        # the lookup tracks the run by tree and command, so a failure during
        # the timeout still supersedes an earlier pass.
        def slow_rustc(command, env, cwd):
            if command[-1] == "-vV":
                return "unavailable: probe timeout"
            return VERDICT.probe(command, env, cwd)
        with self.assertRaises(VERDICT.ProbeUnavailable) as raised:
            VERDICT.capture_inputs(self.root, version_probe=slow_rustc)
        self.assertEqual(raised.exception.scope, {"schema": VERDICT.SCHEMA, "tree": self.inputs["tree"],
                                                  "command": VERDICT.LOCAL_RUNNER_COMMAND})
        # A missing toolchain is a refusal, not a probe failure: untracked.
        with mock.patch.dict(os.environ, {"HOME": str(self.base / "empty-home")}), \
                mock.patch.object(pwd, "getpwuid", return_value=types.SimpleNamespace(pw_dir=str(self.base / "none"))):
            with self.assertRaises(ValueError) as refused:
                VERDICT.capture_inputs(self.root, version_probe=slow_rustc)
            self.assertNotIsInstance(refused.exception, VERDICT.ProbeUnavailable)

    def test_sessions_and_checkouts_share_a_verdict(self):
        # Environment, Git config, refs and checkout location are not keyed.
        with mock.patch.dict(os.environ, {"ARBITRARY_SESSION_VALUE": "new", "TERM": "another-agent",
                                          "TRELLIS_HEAVY_DIR": "elsewhere"}):
            self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
        self.git("config", "fixture.value", "changed")
        self.git("tag", "v0.0.1")
        self.git("branch", "another-lane")
        self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(self.root), self.state))
        clone = self.base / "clone"
        subprocess.check_call(["git", "clone", "-q", str(self.root), str(clone)], stderr=subprocess.DEVNULL)
        self.assertIsNotNone(VERDICT.find_verdict(VERDICT.capture_inputs(clone), self.state))
        (clone / "untracked").write_text("dirty\n")
        self.assertIsNone(VERDICT.safe_inputs(clone))

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
                def good_probe(command, env, cwd):
                    if command[-1] == "-vV":
                        return VERDICT.probe(command, env, cwd)
                    return "fixture bats 1"
                self.assertIsNotNone(VERDICT.safe_inputs(self.root, version_probe=good_probe))
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
                self.assertEqual(VERDICT.capture_inputs(self.root), self.inputs)

    def test_additional_tool_identities_bind_binary_changes(self):
        executable = self.base / "tool"
        self.tools.stop()
        try:
            for name in ("timeout", "gtimeout", "uv", "shfmt", "lsof", "ps", "gh", "npm", "npx",
                         "cc", "c++", "ar", "ld", "clang", "gcc", "xcrun"):
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
                # A reuse claims the configured command's verdict, not full coverage.
                self.assertIn("Tests: reused: configured command", result.stdout)
                self.assertNotIn("Tests: full", result.stdout)
                self.assertEqual(log.read_text().splitlines(), ["typecheck", "lint", "coverage"])
                # A session environment change still hits.
                os.environ["A_SESSION_VALUE"] = "changed"
                result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
                self.assertIn("reused verdict " + self.id, result.stdout)
                # A dirty tree is a cache miss, and only the real test command
                # executes on that miss (the shim never invokes a battery).
                (self.root / "untracked-input").write_text("dirty\n")
                result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("reused verdict", result.stdout)
                self.assertEqual(log.read_text().splitlines()[-4:], ["typecheck", "lint", "tests", "coverage"])
        finally:
            self.tools.start()

    def run_project_gate(self, test_cmd, path=None, root=None, extra=None, range_arg="HEAD~1..HEAD", mode=()):
        """Run check-tests.sh with a project (not run-tests-local) test command."""
        root = root or self.root
        environment = {"PATH": path or self.project_path, "PWD": str(root), "OLDPWD": str(root),
                       "CODEX_PROJECT_DIR": str(root), "CLAUDE_PROJECT_DIR": str(root),
                       "CHECK_LOG": str(self.check_log), "PROCESS_GATE_TEST_CMD": test_cmd,
                       "PROCESS_GATE_TYPECHECK_CMD": "true", "PROCESS_GATE_LINT_CMD": "true",
                       "PROCESS_GATE_HEAVY_LAUNCHER": "/not/a/launcher", **(extra or {})}
        with mock.patch.dict(os.environ, environment):
            self.clear_hook_git_env()
            command = ["bash", str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"), "--range=" + range_arg, *mode]
            result = subprocess.run(command, cwd=root, text=True, capture_output=True, timeout=120)
        return result

    # The reusable fixture command: real `node --test` over one committed file
    # whose behaviour the (unkeyed) environment drives.
    TEST_CMD = "node --test"
    NODE_CHECKS = (
        'import { test } from "node:test";\n'
        'import { appendFileSync, existsSync, writeFileSync } from "node:fs";\n'
        'import { execFileSync } from "node:child_process";\n'
        'appendFileSync(process.env.CHECK_LOG, "tests\\n");\n'
        'test("fixture checks", () => {\n'
        '  if (process.env.FAIL_FLAG && existsSync(process.env.FAIL_FLAG)) throw new Error("flagged");\n'
        '  if (process.env.APP_MODE === "strict") throw new Error("strict mode");\n'
        '  const want = process.env.WANT_RUSTC;\n'
        '  if (want && !execFileSync("rustc", ["--version"]).toString().includes(want)) throw new Error("rustc");\n'
        '  if (process.env.DIRTY_PATH) writeFileSync(process.env.DIRTY_PATH, "made by tests\\n");\n'
        '  if (process.env.OUTPUT_MARKER) console.log(process.env.OUTPUT_MARKER);\n'
        '});\n')

    def project_inputs(self):
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            return VERDICT.safe_inputs(self.root, command=self.TEST_CMD)

    def project_runs(self):
        return self.check_log.read_text().count("tests\n") if self.check_log.exists() else 0

    def command_verdicts(self):
        return sorted((self.store / "verdicts").glob("*.json"))

    def start_project_gate(self):
        # check-tests.sh probes the real (wrapped) tools; tearDown stops this patch.
        self.tools.stop()
        self.tools = mock.patch.object(VERDICT, "toolchain", VERDICT.toolchain)
        self.tools.start()
        self.check_log = self.base / "project-checks.log"
        self.project_path = self.versioned_path()
        if shutil.which("node") is None:
            self.skipTest("node is required for the real-runner fixture")
        self.commit_files({"checks.test.mjs": self.NODE_CHECKS})

    def test_project_command_pass_is_reused_until_tree_command_or_toolchain_changes(self):
        self.start_project_gate()
        test_cmd = self.TEST_CMD
        result = self.run_project_gate(test_cmd)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.project_runs(), 1)
        self.assertEqual(len(self.command_verdicts()), 1, result.stdout + result.stderr)
        record = json.loads(self.command_verdicts()[0].read_text())
        self.assertEqual(record["inputs"]["command"], test_cmd)
        self.assertEqual(set(record["inputs"]), {"schema", "tree", "command", "runner", "env", "policy", "configs",
                                                 "toolchain", "platform"})
        # Hit: same tree, command and toolchain, even from another session and checkout.
        for extra in ({}, {"TERM": "another-agent", "A_SESSION_VALUE": "changed"}):
            result = self.run_project_gate(test_cmd, extra=extra)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("reused verdict " + record["id"], result.stdout)
            self.assertIn("Tests: reused: configured command", result.stdout)
            self.assertNotIn("Tests: full", result.stdout)
            self.assertEqual(self.project_runs(), 1)
        self.git("tag", "v9.9.9")
        clone = self.base / "clone"
        subprocess.check_call(["git", "clone", "-q", str(self.root), str(clone)], stderr=subprocess.DEVNULL)
        result = self.run_project_gate(test_cmd, root=clone)
        self.assertIn("reused verdict " + record["id"], result.stdout, result.stderr)
        self.assertEqual(self.project_runs(), 1)
        # Miss: a different command runs, and records its own verdict.
        other = test_cmd + " --test-concurrency=1"
        result = self.run_project_gate(other)
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.project_runs(), 2)
        self.assertEqual(len(self.command_verdicts()), 2)
        # Miss: a different toolchain version runs.
        directory = Path(self.project_path.split(os.pathsep)[0])
        wrapper = directory / "bash"
        wrapper.write_text(wrapper.read_text().replace("fixture bash 1", "fixture bash 2"))
        result = self.run_project_gate(test_cmd)
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.project_runs(), 3)
        wrapper.write_text(wrapper.read_text().replace("fixture bash 2", "fixture bash 1"))
        self.assertIn("reused verdict " + record["id"], self.run_project_gate(test_cmd).stdout)
        # Miss: a dirty tree runs and records nothing.
        before = self.command_verdicts()
        (self.root / "untracked-input").write_text("dirty\n")
        result = self.run_project_gate(test_cmd)
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.project_runs(), 4)
        self.assertEqual(self.command_verdicts(), before)
        (self.root / "untracked-input").unlink()
        # A failing run records nothing, and its miss supersedes older passes
        # for the same tree and command (here: external state under toolchain 2).
        flag = self.base / "fail-flag"
        extra = {"FAIL_FLAG": str(flag)}
        self.assertIn("reused verdict", self.run_project_gate(test_cmd, extra=extra).stdout)
        runs = self.project_runs()
        flag.write_text("")
        wrapper.write_text(wrapper.read_text().replace("fixture bash 1", "fixture bash 3"))
        self.assertNotEqual(self.run_project_gate(test_cmd, extra=extra).returncode, 0)
        wrapper.write_text(wrapper.read_text().replace("fixture bash 3", "fixture bash 1"))
        result = self.run_project_gate(test_cmd, extra=extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.project_runs(), runs + 2)
        remaining = [json.loads(path.read_text())["inputs"]["command"] for path in self.command_verdicts()]
        self.assertEqual(remaining, [other])
        flag.unlink()
        self.assertEqual(self.run_project_gate(test_cmd, extra=extra).returncode, 0)
        self.assertIn("reused verdict", self.run_project_gate(test_cmd, extra=extra).stdout)
        # A run that dirties the tree records nothing.
        before = self.command_verdicts()
        made = self.root / "made-by-tests"
        dirtying = test_cmd + " --test-concurrency=2"
        self.assertEqual(self.run_project_gate(dirtying, extra={"DIRTY_PATH": str(made)}).returncode, 0)
        self.assertEqual(self.command_verdicts(), before)
        made.unlink()
        # A disabled store records nothing and reuses nothing.
        (self.state / "reuse-disabled.json").write_text("P1\n")
        runs = self.project_runs()
        self.assertNotIn("reused verdict", self.run_project_gate(test_cmd).stdout)
        self.assertEqual(self.project_runs(), runs + 1)

    def test_project_opt_out_always_runs(self):
        self.start_project_gate()
        (self.root / ".trellis.json").write_text('{"gate": {"verdict_reuse": false}}\n')
        self.commit()
        self.assertIsNone(self.project_inputs())
        test_cmd = self.TEST_CMD
        for expected in (1, 2):
            result = self.run_project_gate(test_cmd)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("reused verdict", result.stdout)
            self.assertEqual(self.project_runs(), expected)
        self.assertEqual(self.command_verdicts(), [])
        # An explicit true, or no gate policy, keeps the default reuse.
        for policy in ('{"gate": {"verdict_reuse": true}}\n', '{"gate": {}}\n'):
            (self.root / ".trellis.json").write_text(policy)
            self.commit()
            self.assertIsNotNone(self.project_inputs())
        # Unreadable or mistyped policy never widens reuse.
        for policy in ('{"gate": {"verdict_reuse": "no"}}\n', '{"gate": []}\n', "[]\n", "{not json\n"):
            (self.root / ".trellis.json").write_text(policy)
            self.commit()
            self.assertIsNone(self.project_inputs(), policy)

    def test_project_verdict_age_and_evidence_are_checked(self):
        inputs = VERDICT.capture_inputs(self.root, command="node --test", runner={"gate": "x"})
        record = VERDICT.record_command_verdict(inputs, copy.deepcopy(inputs), self.store, output=b"ok\n")
        self.assertIsNotNone(record)
        path = self.store / "verdicts" / (record["key"] + ".json")
        self.assertEqual(VERDICT.find_command_verdict(inputs, self.store)["id"], record["id"])
        self.assertIsNone(VERDICT.record_command_verdict(inputs, dict(inputs, tree="changed"), self.store))
        now = time.time()
        for age, reusable in ((1, True), (7 * 86400, True), (7 * 86400 + 1, False), (-1, False)):
            path.write_text(json.dumps(dict(record, completed_at=now - age)))
            with self.subTest(age=age), mock.patch.object(VERDICT.time, "time", return_value=now):
                self.assertEqual(VERDICT.find_command_verdict(inputs, self.store) is not None, reusable)
        for field, value in (("status", "fail"), ("complete", False), ("kind", "battery"), ("key", "b" * 64)):
            path.write_text(json.dumps(dict(record, **{field: value})))
            self.assertIsNone(VERDICT.find_command_verdict(inputs, self.store), field)
        path.write_text(json.dumps(record))
        path.chmod(0o644)
        self.assertIsNone(VERDICT.find_command_verdict(inputs, self.store))
        path.chmod(0o600)
        self.assertIsNotNone(VERDICT.find_command_verdict(inputs, self.store))
        VERDICT.invalidate_command_verdicts(inputs, self.store)
        self.assertIsNone(VERDICT.find_command_verdict(inputs, self.store))

    # --- 1.5.1 review findings (r151-sol H1/H2/M3/M4, r151-muse HIGH-1/MEDIUM-1/LOW-1/LOW-2) ---

    def fixture_bin(self, files):
        directory = self.base / "fixture-bin"
        directory.mkdir(exist_ok=True)
        for name, text in files.items():
            (directory / name).write_text(text)
            (directory / name).chmod(0o755)
        return str(directory) + os.pathsep + self.project_path

    def commit_files(self, files):
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.commit()
        # The gated range changes only an unrelated file, so it is never docs-only or selected.
        (self.root / "marker").write_text("candidate %f\n" % time.time())
        self.commit()

    FIXTURE_PYTEST = (
        '#!/bin/bash\n# Fixture runner: each tests*/test_*.sh is a test; PYTEST_ADDOPTS="-k NAME" selects.\n'
        'filter=""\ncase "${PYTEST_ADDOPTS:-}" in "-k "*) filter="${PYTEST_ADDOPTS#-k }" ;; esac\n'
        'printf "tests\\n" >> "$CHECK_LOG"\nstatus=0\n'
        'for t in tests/test_*.sh tests_extra/test_*.sh; do\n  [ -e "$t" ] || continue\n'
        '  case "$t" in *"$filter"*) ;; *) continue ;; esac\n  bash "$t" || status=1\ndone\nexit $status\n')

    def test_h2_pytest_addopts_filtered_run_is_never_published_as_full(self):
        # r151-sol H2: PYTEST_ADDOPTS='-k pass' passed, recorded, then reused unfiltered.
        self.start_project_gate()
        self.commit_files({"tests/test_pass.sh": "exit 0\n", "tests/test_fail.sh": "exit 1\n"})
        path = self.fixture_bin({"pytest": self.FIXTURE_PYTEST})
        filtered = self.run_project_gate("pytest -q", path=path, extra={"PYTEST_ADDOPTS": "-k pass"})
        self.assertEqual(filtered.returncode, 0, filtered.stdout + filtered.stderr)
        self.assertEqual(self.command_verdicts(), [])
        full = self.run_project_gate("pytest -q", path=path)
        self.assertNotEqual(full.returncode, 0, full.stdout)
        self.assertNotIn("reused verdict", full.stdout)
        self.assertEqual(self.project_runs(), 2)

    def test_n7_reuse_grammar_is_an_allowlist(self):
        # r151 L4/N7: reusable only when the whole command parses to a known
        # runner with audited options; anything else refuses (and runs in full).
        package = {"scripts": {"test": "vitest run", "unit": "vitest run -t fast", "e2e": "jest --onlyChanged",
                               "ci": "jest --ci", "lint": "eslint .", "pretest2": "build", "test2": "jest"}}
        self.commit_files({"package.json": json.dumps(package), "tests/a": "x\n", "pkg/b": "y\n"})
        refused_env = {"pytest": "PYTEST_ADDOPTS", "pytest-plugins": "PYTEST_PLUGINS", "jest": "JEST_FILTER",
                       "vitest": "VITEST_MODE", "nextest": "NEXTEST_PROFILE", "cargo": "CARGO_BUILD_RUSTFLAGS",
                       "cargo-home": "CARGO_HOME", "rustc": "RUSTC_WRAPPER", "go": "GOFLAGS", "go-env-file": "GOENV",
                       "bats": "BATS_TEST_FILTER", "make": "MAKEFLAGS", "npm": "npm_config_script_shell",
                       "pnpm": "pnpm_config_shell_emulator"}
        for runner, name in refused_env.items():
            with self.subTest(runner=runner, env=name), mock.patch.dict(os.environ, {name: "-k x"}):
                self.assertIsNone(VERDICT.safe_inputs(self.root, command="pytest -q"))
        refused_argv = (
            # Sol r151-reuse2 N7 table.
            "pytest -p no:unittest", "PYTEST_ADDOPTS+=-kpass pytest", "jest --help", "vitest run --typecheck.only",
            "node --test --test-name-pattern=pass", "node --test --test-only", "node --test --test-shard=1/2",
            "node --test --test-skip-pattern=fail", "cargo test --tests", "cargo test -- --help",
            "go test -exec /usr/bin/true ./...", "go test ./... -args -test.list .", "make -n test",
            "make --touch test", "make test", "npm --prefix pkg test", "npm -w pkg test", "pnpm -C pkg test",
            "pnpm -r test", "yarn workspace pkg test", "CI=1 npm run unit", 'bash -c "pytest -k pass"',
            # Earlier narrowing rows, which the allowlist subsumes.
            "pytest -k pass", "python3 -m pytest -m slow", "pytest tests/test_a.py::test_one", "pytest -vk pass",
            "pytest --lf", "pytest -o addopts=-kx", "pytest --deselect a", "pytest $PYTEST_ARGS",
            "pytest -W error", "jest -t name", "npx jest src/feature", "jest --onlyChanged", "jest --shard=1/2",
            "jest --config jest.config.js", "vitest run -t name", "vitest run src/a.test.ts", "vitest",
            "pnpm vitest --changed", "cargo test filter", "cargo test -- --skip slow", "cargo test -p one",
            "cargo nextest run -E x", "cargo test --no-run", "cargo +1.97.1 test --workspace",
            "go test -run TestOne ./...", "go test -short ./...", "go test --run=X ./...",
            "pnpm run unit", "npm run e2e", "npm run lint", "npm run test2", "npm run missing",
            "make lint && pytest", "npm test -- -t name", "pnpm test src/only.test.ts",
            "PYTEST_ADDOPTS=-kx pytest", "CARGO_HOME=/tmp/c cargo test", "export NODE_OPTIONS=x; jest",
            "env GOFLAGS=-run=X go test ./...", "env -i pytest", "APP_MODE=1 pytest",
            # Shell forms other than "&&" and expansions.
            "pytest; true", "pytest || true", "pytest | tee log", "pytest > out", "pytest & wait", "(pytest)",
            "jest '&&' jest", "./run-tests.sh", "bin/pytest", "pytest ~/tests", "pytest tests/*",
            # Package-manager options, config and shells (N4).
            "npm --userconfig=/tmp/npmrc test", "npm --script-shell=/usr/bin/true test", "npm test --silent extra",
            "npm --ignore-scripts test", "yarn test --ci", "uv run --with x pytest", "pdm run jest",
            "pytest missing-dir", "pytest ../elsewhere", "go test ./missing/...")
        for command in refused_argv:
            with self.subTest(command=command):
                self.assertIsNone(VERDICT.safe_inputs(self.root, command=command))
        allowed = ("pytest -q", "python3 -m pytest -q tests", "python -I -m pytest -ra -n4 -p no:cacheprovider",
                   "uv run pytest -q", "pdm run python -m pytest", "jest --ci --coverage", "vitest run --coverage",
                   "vitest --run", "pnpm test", "npm test", "npm run ci", "npm -s run ci", "yarn test",
                   "CI=1 npm run ci", "env CI=1 jest --ci", "node --test", "node --test --test-reporter=spec",
                   "cargo test --locked --offline", "cargo --locked test -- --test-threads 1",
                   "cargo nextest run --workspace", "go test -count=1 ./...", "go test ./pkg/... -v", "go test .",
                   "npm test -- --coverage", "pytest -q && node --test")
        for command in allowed:
            with self.subTest(command=command):
                self.assertIsNotNone(VERDICT.safe_inputs(self.root, command=command))

    def test_n7_filtered_node_run_is_never_published_as_full(self):
        # r151-reuse2 N7 runtime: a name-filtered node run recorded a verdict and
        # was then reused as Tests: full, while the unfiltered run fails.
        self.start_project_gate()
        self.commit_files({"suite.test.mjs": 'import { test } from "node:test";\n'
                                             'test("pass", () => {});\ntest("fail", () => { throw new Error("x"); });\n'})
        filtered = self.TEST_CMD + " --test-name-pattern=pass"
        self.assertEqual(self.run_project_gate(filtered).returncode, 0)
        self.assertEqual(self.command_verdicts(), [])
        again = self.run_project_gate(filtered)
        self.assertNotIn("reused verdict", again.stdout)
        self.assertNotEqual(self.run_project_gate(self.TEST_CMD).returncode, 0)

    def test_muse_medium1_execution_shaping_env_refuses_or_keys(self):
        for name in ("LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "PYTHONPATH", "BASH_ENV", "ENV", "SHELLOPTS",
                     "NODE_OPTIONS", "NODE_PATH", "PERL5OPT", "RUBYOPT", "GEM_HOME",
                     "JAVA_TOOL_OPTIONS", "CLASSPATH", "npm_config_ignore_scripts",
                     "MAKEFLAGS", "GNUMAKEFLAGS", "MFLAGS", "MAKEFILES", "GOENV", "CARGO_HOME", "pnpm_config_shell",
                     # r151 reuse4: path-valued settings name what the key cannot bind.
                     "UV_CONFIG_FILE", "UV_PROJECT_ENVIRONMENT", "UV_PYTHON", "PDM_CONFIG_FILE", "PDM_HOME",
                     "YARN_RC_FILENAME", "YARN_YARN_PATH", "NPM_CONFIG_USERCONFIG", "DOCKER_CONFIG",
                     "UV_INDEX_STRATEGY"):
            with self.subTest(refused=name), mock.patch.dict(os.environ, {name: "/tmp/stub"}):
                self.assertIsNone(VERDICT.safe_inputs(self.root))
        base = VERDICT.capture_inputs(self.root)
        # Exported functions and CDPATH are ordinary shell state (bats exports
        # BASH_FUNC_bats_readlinkf%%): keyed, never refused.
        for name in ("NODE_ENV", "CI", "TZ", "DOCKER_HOST", "LC_COLLATE", "GOTOOLCHAIN", "COREPACK_ENABLE_STRICT",
                     "BASH_FUNC_which%%", "CDPATH", "NODE_EXTRA_CA_CERTS", "pnpm_config_verify_deps_before_run",
                     "UV_NO_CACHE", "YARN_ENABLE_SCRIPTS"):
            with self.subTest(keyed=name):
                with mock.patch.dict(os.environ, {name: "one"}):
                    one = VERDICT.capture_inputs(self.root)
                with mock.patch.dict(os.environ, {name: "two"}):
                    two = VERDICT.capture_inputs(self.root)
                self.assertNotEqual(VERDICT.key(one), VERDICT.key(two))
                self.assertNotEqual(VERDICT.key(one), VERDICT.key(base))
        # A URL is not a path: registry settings stay keyed.
        with mock.patch.dict(os.environ, {"UV_INDEX_URL": "https://example.invalid/simple"}):
            self.assertNotEqual(VERDICT.key(VERDICT.capture_inputs(self.root)), VERDICT.key(base))
        for name in ("PYTHONDONTWRITEBYTECODE", "TERM", "COREPACK_HOME", "CARGO_TARGET_DIR", "TRELLIS_TEST_SHARDS"):
            with self.subTest(ignored=name), mock.patch.dict(os.environ, {name: "1"}):
                self.assertEqual(VERDICT.capture_inputs(self.root), base)

    def test_muse_medium1_injected_session_never_publishes(self):
        # An LD_PRELOAD/PYTHONPATH session records nothing a clean session could reuse.
        self.start_project_gate()
        test_cmd = self.TEST_CMD
        for name in ("PYTHONPATH", "RUBYOPT"):
            result = self.run_project_gate(test_cmd, extra={name: str(self.base / "stubs")})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.command_verdicts(), [])
        self.assertNotIn("reused verdict", self.run_project_gate(test_cmd).stdout)
        self.assertEqual(self.project_runs(), 3)

    def test_muse_high1_env_passthrough_values_are_keyed(self):
        self.start_project_gate()
        self.commit_files({".trellis.json": '{"gate": {"env_passthrough": ["APP_MODE"]}}\n'})
        test_cmd = self.TEST_CMD
        result = self.run_project_gate(test_cmd, extra={"APP_MODE": "test"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.command_verdicts()), 1)
        self.assertIn("reused verdict", self.run_project_gate(test_cmd, extra={"APP_MODE": "test"}).stdout)
        strict = self.run_project_gate(test_cmd, extra={"APP_MODE": "strict"})
        self.assertNotEqual(strict.returncode, 0, strict.stdout)
        self.assertNotIn("reused verdict", strict.stdout)
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            os.environ.pop("APP_MODE", None)
            unset = VERDICT.capture_inputs(self.root, command=test_cmd)
            os.environ["APP_MODE"] = ""
            empty = VERDICT.capture_inputs(self.root, command=test_cmd)
        self.assertIsNone(unset["env"]["APP_MODE"])
        self.assertNotEqual(VERDICT.key(unset), VERDICT.key(empty))
        self.commit_files({".trellis.json": '{"gate": {"env_passthrough": "APP_MODE"}}\n'})
        self.assertIsNone(VERDICT.safe_inputs(self.root, command=test_cmd))

    def test_m3_ignored_discovered_test_file_refuses_reuse(self):
        # r151-sol M3: an ignored tests_extra/ test changed to fail; the pass was reused.
        self.start_project_gate()
        self.commit_files({"tests/test_pass.sh": "exit 0\n", ".gitignore": "tests_extra/\n",
                           "pytest.ini": "[pytest]\ntestpaths = tests tests_extra\n"})
        extra = self.root / "tests_extra/test_new.sh"
        extra.parent.mkdir()
        extra.write_text("exit 0\n")
        path = self.fixture_bin({"pytest": self.FIXTURE_PYTEST})
        self.assertEqual(self.run_project_gate("pytest -q", path=path).returncode, 0)
        self.assertEqual(self.command_verdicts(), [])
        extra.write_text("exit 1\n")
        result = self.run_project_gate("pytest -q", path=path)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("reused verdict", result.stdout)

    def test_m3_ignored_file_allowances_follow_the_runner(self):
        self.commit_files({".gitignore": "*\n!.gitignore\n!*/\n!scripts/**\n!marker\n!*.json\n!*.ini\n!*.toml\n"})
        def refused(command, *paths):
            for name in paths:
                target = self.root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("x\n")
            try:
                return VERDICT.safe_inputs(self.root, command=command) is None
            finally:
                for name in paths:
                    shutil.rmtree(self.root / name.split("/")[0], ignore_errors=True)
                    (self.root / name).unlink(missing_ok=True)
        self.assertFalse(refused("node --test", "node_modules/a/x.js", ".DS_Store"))
        self.assertFalse(refused("pytest -q", "src/__pycache__/a.pyc", ".pytest_cache/v", ".DS_Store"))
        # r151 F8: no cache directory is exempt for every runner; node
        # discovers tests in __pycache__ and go ./... reads it as a package.
        self.assertTrue(refused("node --test", "src/__pycache__/a.test.js"))
        self.assertTrue(refused("jest", ".pytest_cache/v"))
        self.assertTrue(refused("node --test", ".env"))
        self.assertFalse(refused("node --test", "node_modules/a/index.test.js"))
        self.assertFalse(refused("pytest -q", "node_modules/a/x.js", ".venv/lib/x.py", "build/x", "dist/x"))
        # r151-reuse2 N5: no blanket coverage/output allowances.
        for command in ("pytest -q", "node --test", "vitest run", "jest"):
            for name in ("coverage/test_extra.py", "coverage/extra.test.js", "htmlcov/index.html", ".coverage"):
                with self.subTest(command=command, path=name):
                    self.assertTrue(refused(command, name))
        self.assertTrue(refused("pytest -q", "target/test_x.py"))
        self.assertTrue(refused("pytest -q", "generated/test_x.py"))
        self.assertTrue(refused("jest", "dist/a.test.js"))
        self.assertTrue(refused("vitest run", "dist/a.test.js"))
        self.assertFalse(refused("jest", "node_modules/a/a.test.js"))
        self.assertFalse(refused("cargo test", "target/debug/x"))
        self.assertTrue(refused("cargo test", "src/generated.rs"))
        self.assertTrue(refused("cargo test", "dist/extra.rs"))
        self.assertTrue(refused("cargo test", "node_modules/a/x.js"))
        self.assertFalse(refused("go test ./...", "_build/x_test.go", ".cache/x"))
        self.assertTrue(refused("go test ./...", "testdata/golden.bin"))
        self.assertTrue(refused("go test ./...", "vendor/m/x.go"))
        self.assertFalse(refused("pytest -q && node --test", "node_modules/a/x.js"))
        self.assertTrue(refused("pytest -q && cargo test", "node_modules/a/x.js"))
        # A committed discovery override, or runner config naming the skipped
        # directory, puts the default skip back in doubt.
        self.commit_files({"Cargo.toml": '[package]\nname = "x"\n[[test]]\nname = "t"\npath = "target/t.rs"\n'})
        self.assertTrue(refused("cargo test", "target/t.rs"))
        self.commit_files({"package.json": '{"jest": {"roots": ["node_modules/fixtures"]}}'})
        self.assertTrue(refused("jest", "node_modules/fixtures/a.test.js"))
        self.assertFalse(refused("pytest -q", "node_modules/a/test_x.py"))
        self.commit_files({"pytest.ini": "[pytest]\nnorecursedirs = docs\n"})
        self.assertTrue(refused("pytest -q", "node_modules/a/test_x.py"))
        self.commit_files({"pytest.ini": "[pytest]\naddopts = -q build\n"})
        self.assertTrue(refused("pytest -q", "build/test_x.py"))
        self.assertFalse(refused("pytest -q", "dist/test_x.py"))

    def rustup_fixture(self):
        home = self.base / "rustup-home"
        for toolchain, version in (("stable", "1.99.1"), ("1.97.1", "1.97.1")):
            for tool in ("rustc", "cargo"):
                binary = home / "toolchains" / toolchain / "bin" / tool
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_text("#!/bin/sh\necho '%s %s'\n" % (tool, version))
                binary.chmod(0o755)
        proxy = self.base / "rustup-bin"
        proxy.mkdir()
        (proxy / "rustup").write_text(
            '#!/bin/bash\ntc="${RUSTUP_TOOLCHAIN:-stable}"\n'
            'case "${0##*/}" in\n  rustup)\n    case "$1 ${2:-}" in\n'
            '      "show active-toolchain") [ -d "$RUSTUP_HOME/toolchains/$tc" ] || exit 1; echo "$tc (environment)" ;;\n'
            '      "which "*) [ -x "$RUSTUP_HOME/toolchains/$tc/bin/$2" ] || exit 1; echo "$RUSTUP_HOME/toolchains/$tc/bin/$2" ;;\n'
            '      *) exit 2 ;;\n    esac ;;\n  *) exec "$RUSTUP_HOME/toolchains/$tc/bin/${0##*/}" "$@" ;;\nesac\n')
        (proxy / "rustup").chmod(0o755)
        for tool in ("rustc", "cargo"):
            (proxy / tool).symlink_to("rustup")
        return home, proxy

    def test_m4_rustup_toolchain_switch_is_keyed_on_the_effective_compiler(self):
        # r151-sol M4: RUSTUP_TOOLCHAIN=1.97.1 reused a pass made under stable 1.99.1.
        self.start_project_gate()
        home, proxy = self.rustup_fixture()
        path = str(proxy) + os.pathsep + self.project_path
        test_cmd = self.TEST_CMD
        extra = {"RUSTUP_HOME": str(home), "WANT_RUSTC": "1.99.1"}
        stable = self.run_project_gate(test_cmd, path=path, extra=extra)
        self.assertEqual(stable.returncode, 0, stable.stdout + stable.stderr)
        self.assertEqual(len(self.command_verdicts()), 1, stable.stdout + stable.stderr)
        self.assertIn("reused verdict", self.run_project_gate(test_cmd, path=path, extra=extra).stdout)
        pinned = self.run_project_gate(test_cmd, path=path, extra=dict(extra, RUSTUP_TOOLCHAIN="1.97.1"))
        self.assertNotEqual(pinned.returncode, 0, pinned.stdout)
        self.assertNotIn("reused verdict", pinned.stdout)

    def test_m4_dispatcher_identity_or_refusal(self):
        self.tools.stop()
        try:
            home, proxy = self.rustup_fixture()

            # Plain --version probes get a fixed answer; the identity and
            # dispatch probes (RUSTUP_FORCE_ARG0, `which`, `show`) now run
            # through the caller's probe too, so they get the real one.
            def probe(command, env, cwd):
                if list(command[1:]) == ["--version"] and not env.get("RUSTUP_FORCE_ARG0"):
                    return "fixture 1"
                return VERDICT.probe(command, env, cwd)
            with mock.patch.dict(os.environ, {"PATH": str(proxy), "RUSTUP_HOME": str(home)}):
                stable = VERDICT.toolchain(self.root, probe)
                self.assertEqual(stable["rustc"]["effective"]["active"], "stable (environment)")
                os.environ["RUSTUP_TOOLCHAIN"] = "1.97.1"
                pinned = VERDICT.toolchain(self.root, probe)
                self.assertNotEqual(stable["rustc"]["effective"], pinned["rustc"]["effective"])
                self.assertEqual(stable["rustc"]["binary"], pinned["rustc"]["binary"])  # the proxy itself
                os.environ["RUSTUP_TOOLCHAIN"] = "missing"
                with self.assertRaises(ValueError):
                    VERDICT.toolchain(self.root, probe)
                os.environ["RUSTUP_HOME"] = str(self.base / "no-toolchains")
                self.assertIsNone(VERDICT.toolchain(self.root, probe)["cargo"]["effective"]["active"])
            pyenv = self.base / ".pyenv"
            (pyenv / "shims").mkdir(parents=True)
            (pyenv / "bin").mkdir()
            for version in ("3.12.1", "3.13.0"):
                real = pyenv / "versions" / version / "bin" / "python3"
                real.parent.mkdir(parents=True)
                real.write_text("#!/bin/sh\necho %s\n" % version)
            (pyenv / "bin/pyenv").write_text('#!/bin/sh\n[ "$1" = which ] || exit 2\n'
                                             'echo "$PYENV_ROOT/versions/$PYENV_VERSION/bin/$2"\n')
            (pyenv / "shims/python3").write_text('#!/bin/sh\nexec "$PYENV_ROOT/bin/pyenv" exec "$@"\n')
            for script in (pyenv / "bin/pyenv", pyenv / "shims/python3"):
                script.chmod(0o755)
            with mock.patch.dict(os.environ, {"PATH": str(pyenv / "shims"), "PYENV_VERSION": "3.12.1"}):
                one = VERDICT.toolchain(self.root, probe)["python3"]["effective"]
                os.environ["PYENV_VERSION"] = "3.13.0"
                two = VERDICT.toolchain(self.root, probe)["python3"]["effective"]
                self.assertEqual(one["manager"], "pyenv")
                self.assertNotEqual(one, two)
                os.environ["PYENV_VERSION"] = "absent"
                with self.assertRaises(OSError):
                    VERDICT.toolchain(self.root, probe)
            unknown = self.base / "elsewhere" / "shims"
            unknown.mkdir(parents=True)
            (unknown / "python3").write_text("#!/bin/sh\n")
            (unknown / "python3").chmod(0o755)
            with mock.patch.dict(os.environ, {"PATH": str(unknown)}), self.assertRaises(ValueError):
                VERDICT.toolchain(self.root, probe)
        finally:
            self.tools.start()

    def forge_command_verdict(self, inputs, log=None):
        store = self.store
        for directory in (store, store / "verdicts", store / "logs"):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            directory.chmod(0o700)
        ident = "f" * 32
        record = {"schema": VERDICT.SCHEMA, "kind": "command", "key": VERDICT.key(inputs), "inputs": inputs,
                  "status": "pass", "complete": True, "id": ident, "completed_at": time.time(),
                  "log_sha256": VERDICT.digest(log or b"")}
        path = store / "verdicts" / (record["key"] + ".json")
        path.write_text(json.dumps(record))
        path.chmod(0o600)
        # The 1.5.1-rc location the review forged into: owner-private JSON was enough.
        legacy = self.state / "command-verdicts"
        legacy.mkdir(mode=0o700, exist_ok=True)
        (legacy / path.name).write_text(json.dumps(record))
        (legacy / path.name).chmod(0o600)
        if log is not None:
            (store / "logs" / (ident + ".log")).write_bytes(log)
            (store / "logs" / (ident + ".log")).chmod(0o600)
        return record

    def test_h1_forged_verdict_without_its_execution_log_is_not_reused(self):
        # r151-sol H1: a hand-written pass for a failing command was reused.
        self.start_project_gate()
        failing = self.TEST_CMD
        flag = self.base / "fail-flag"
        flag.write_text("")
        self.assertNotEqual(self.run_project_gate(failing, extra={"FAIL_FLAG": str(flag)}).returncode, 0)
        runner = VERDICT.gate_runner((str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"),
                                      str(ROOT / "core-rules/skills/process-gate/scripts/lib/common.sh")))
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            inputs = VERDICT.capture_inputs(self.root, command=failing, runner=runner)
        record = self.forge_command_verdict(inputs)  # no retained log
        result = self.run_project_gate(failing, extra={"FAIL_FLAG": str(flag)})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("reused verdict", result.stdout)
        self.forge_command_verdict(inputs, log=b"forged\n")
        log = self.store / "logs" / (record["id"] + ".log")
        log.write_bytes(b"tampered\n")
        result = self.run_project_gate(failing, extra={"FAIL_FLAG": str(flag)})
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.project_runs(), 3)

    def test_n1_hard_linked_verdict_or_log_is_not_reused(self):
        # r151-reuse2 Sol N1, defence in depth: another name for a stored file
        # may have changed its bytes, so a multi-link verdict or log is a miss.
        self.start_project_gate()
        # A reusable command (r151 L4 allowlist): the committed node fixture logs each run.
        test_cmd = self.TEST_CMD
        self.assertEqual(self.run_project_gate(test_cmd).returncode, 0)
        self.assertIn("reused verdict", self.run_project_gate(test_cmd).stdout)
        for kind in ("verdict", "log"):
            with self.subTest(kind=kind):
                [path] = self.command_verdicts()
                record = json.loads(path.read_text())
                stored = path if kind == "verdict" else self.store / "logs" / (record["id"] + ".log")
                alias = self.base / ("alias-" + kind)
                os.link(stored, alias)
                runs = self.project_runs()
                result = self.run_project_gate(test_cmd)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("reused verdict", result.stdout)
                self.assertEqual(self.project_runs(), runs + 1)
                alias.unlink()
        self.assertIn("reused verdict", self.run_project_gate(test_cmd).stdout)

    def test_h1_verdicts_live_only_in_the_guarded_store_with_a_retained_log(self):
        self.start_project_gate()
        test_cmd = self.TEST_CMD
        self.assertEqual(self.run_project_gate(test_cmd, extra={"OUTPUT_MARKER": "suite-output-marker"}).returncode, 0)
        [path] = self.command_verdicts()
        record = json.loads(path.read_text())
        log = self.store / "logs" / (record["id"] + ".log")
        self.assertIn(b"suite-output-marker", log.read_bytes())
        self.assertEqual(VERDICT.digest(log.read_bytes()), record["log_sha256"])
        self.assertEqual(oct(log.stat().st_mode & 0o777), "0o600")
        self.assertEqual(list(self.state.glob("command-verdicts*")), [])
        self.assertEqual(subprocess.check_output(["git", "-C", str(self.root), "status", "--porcelain",
                                                  "--ignored"]), b"")
        # The machine kill switch stops reuse and recording.
        (self.store / "reuse-disabled").write_text("")
        runs = self.project_runs()
        self.assertNotIn("reused verdict", self.run_project_gate(test_cmd).stdout)
        self.assertEqual(self.project_runs(), runs + 1)
        self.assertEqual(self.command_verdicts(), [path])
        # A relative TRELLIS_HOME or one inside a checkout refuses.
        for home in ("relative/home", str(self.root / "inside")):
            with self.subTest(home=home), mock.patch.dict(os.environ, {"TRELLIS_HOME": home}):
                with self.assertRaises(ValueError):
                    VERDICT.command_store()

    def cli(self, *args, stdin=b""):
        with mock.patch.object(sys, "stdin", types.SimpleNamespace(buffer=io.BytesIO(stdin))), \
                mock.patch.object(Path, "cwd", return_value=self.root), \
                contextlib.redirect_stdout(io.StringIO()):
            return VERDICT._cli(list(args))

    def test_muse_low1_inputs_file_is_never_followed_or_trusted(self):
        self.start_project_gate()
        path = mock.patch.dict(os.environ, {"PATH": self.project_path})
        path.start()
        self.addCleanup(path.stop)
        self.clear_hook_git_env()
        head = self.git("rev-parse", "HEAD").decode().strip()
        victim = self.base / "victim"
        victim.write_text("precious\n")
        save = self.base / "inputs"
        save.symlink_to(victim)
        common = ["--head=" + head, "--command=" + self.TEST_CMD, "--save=" + str(save)]
        owner = "--owner-pid=%d" % os.getpid()
        self.assertNotEqual(self.cli("lookup", *common, owner), 0)
        self.assertEqual(victim.read_text(), "precious\n")
        save.unlink()
        os.link(victim, save)
        victim.chmod(0o600)
        self.assertNotEqual(self.cli("lookup", *common, owner), 0)
        self.assertEqual(victim.read_text(), "precious\n")
        save.unlink()
        save.write_text("")
        save.chmod(0o600)
        self.assertEqual(self.cli("lookup", *common, owner), 1)
        saved = json.loads(save.read_text())
        self.assertEqual(self.cli("record", *common, "--log=-", stdin=b"ok\n"), 0)
        self.assertEqual(len(self.command_verdicts()), 1)
        for directory in (self.store / "verdicts", self.store / "logs"):
            for path in directory.iterdir():
                path.unlink()
        # A rewritten save naming a toolchain this host does not have is refused.
        forged = copy.deepcopy(saved)
        forged["inputs"]["toolchain"] = {"bash": {"path": "/forged", "binary": "0" * 64}}
        save.write_text(json.dumps(forged))
        self.assertEqual(self.cli("record", *common, "--log=-"), 1)
        # A world-readable or future-dated save is refused.
        save.write_text(json.dumps(saved))
        save.chmod(0o644)
        self.assertNotEqual(self.cli("record", *common, "--log=-"), 0)
        save.chmod(0o600)
        save.write_text(json.dumps(dict(saved, started_at=time.time() + 3600)))
        self.assertNotEqual(self.cli("record", *common, "--log=-"), 0)
        self.assertEqual(self.command_verdicts(), [])

    def test_muse_low2_failure_during_an_overlapping_pass_wins(self):
        inputs = VERDICT.capture_inputs(self.root, command="node --test", runner={"gate": "x"})
        started = time.time()
        # B fails after A started: A's later record is refused.
        VERDICT.invalidate_command_verdicts(inputs, self.store)
        self.assertIsNone(VERDICT.record_command_verdict(inputs, copy.deepcopy(inputs), self.store,
                                                         started_at=started))
        self.assertIsNone(VERDICT.find_command_verdict(inputs, self.store))
        # A run that starts after the failure records again.
        record = VERDICT.record_command_verdict(inputs, copy.deepcopy(inputs), self.store, started_at=time.time())
        self.assertIsNotNone(record)
        self.assertIsNotNone(VERDICT.find_command_verdict(inputs, self.store))
        # A failure after the pass removes it and its log, and a stale record
        # left behind would still be refused by the tombstone.
        kept = (self.store / "verdicts" / (record["key"] + ".json")).read_text()
        VERDICT.invalidate_command_verdicts(inputs, self.store)
        self.assertEqual(self.command_verdicts(), [])
        self.assertFalse((self.store / "logs" / (record["id"] + ".log")).exists())
        (self.store / "verdicts" / (record["key"] + ".json")).write_text(kept)
        (self.store / "verdicts" / (record["key"] + ".json")).chmod(0o600)
        self.assertIsNone(VERDICT.find_command_verdict(inputs, self.store))

    # --- r151-reuse2 re-review (Sol N2-N9), each against real runners ---

    def real_rust(self):
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        rustup_home = Path(os.environ.get("RUSTUP_HOME") or home / ".rustup")
        rustup = shutil.which("rustup") or str(home / ".cargo/bin/rustup")
        if not Path(rustup).is_file() or not (rustup_home / "toolchains").is_dir():
            self.skipTest("a rustup installation is required")
        return rustup_home, Path(rustup)

    def cargo_extra(self, rustup_home):
        return {"RUSTUP_HOME": str(rustup_home), "CARGO_TARGET_DIR": str(self.base / "cargo-target")}

    CARGO_LOCK = ('# This file is automatically @generated by Cargo.\n# It is not intended for manual editing.\n'
                  'version = 4\n\n[[package]]\nname = "fixture"\nversion = "0.1.0"\n')

    def test_n2_forwarding_and_keying_share_the_remote_default_policy(self):
        # origin/HEAD declares APP_MODE, so the dispatcher forwards it; the
        # candidate HEAD drops the declaration. Keying must follow the forwarded policy.
        self.start_project_gate()
        self.commit_files({".trellis.json": '{"gate": {"env_passthrough": ["APP_MODE"]}}\n'})
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        policy = self.git("rev-parse", "refs/remotes/origin/HEAD:.trellis.json").decode().strip()
        self.commit_files({".trellis.json": '{"gate": {}}\n'})
        managed = {"TRELLIS_GATE_ENV_POLICY": policy}
        first = self.run_project_gate(self.TEST_CMD, extra=dict(managed, APP_MODE="test"))
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(len(self.command_verdicts()), 1, first.stdout + first.stderr)
        strict = self.run_project_gate(self.TEST_CMD, extra=dict(managed, APP_MODE="strict"))
        self.assertNotIn("reused verdict", strict.stdout)
        self.assertNotEqual(strict.returncode, 0, strict.stdout)
        self.assertEqual(VERDICT.trusted_gate_policy(self.root), (policy, ["APP_MODE"]))
        # A dispatcher that forwarded another policy (origin/HEAD moved) never reuses.
        moved = self.run_project_gate(self.TEST_CMD, extra=dict(managed, APP_MODE="test",
                                                                TRELLIS_GATE_ENV_POLICY="0" * 40))
        self.assertNotIn("reused verdict", moved.stdout)
        # The strict failure superseded the pass; a fresh one is reused under the same policy.
        self.assertEqual(self.run_project_gate(self.TEST_CMD, extra=dict(managed, APP_MODE="test")).returncode, 0)
        self.assertIn("reused verdict", self.run_project_gate(self.TEST_CMD, extra=dict(managed, APP_MODE="test")).stdout)

    def test_n3_cargo_home_override_never_publishes(self):
        # A Cargo home whose config sets runner=/usr/bin/true skipped a
        # committed failing test; its pass was then reused under a normal home.
        self.start_project_gate()
        rustup_home, _ = self.real_rust()
        self.commit_files({"Cargo.toml": '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\n',
                           "Cargo.lock": self.CARGO_LOCK, "src/lib.rs": '#[test]\nfn committed_failure() { panic!("committed failure"); }\n'})
        evil = self.base / "evil-cargo"
        evil.mkdir()
        (evil / "config.toml").write_text("[target.'cfg(all())']\nrunner = \"/usr/bin/true\"\n")
        command = "cargo test --offline"
        # A private home: the default Cargo home is $HOME/.cargo, written below.
        home = self.base / "n3-home"
        home.mkdir()
        extra = dict(self.cargo_extra(rustup_home), HOME=str(home))
        hidden = self.run_project_gate(command, extra=dict(extra, CARGO_HOME=str(evil)))
        self.assertEqual(hidden.returncode, 0, hidden.stdout + hidden.stderr)
        self.assertEqual(self.command_verdicts(), [])
        inline = self.run_project_gate("CARGO_HOME=" + str(evil) + " " + command, extra=extra)
        self.assertEqual(inline.returncode, 0, inline.stdout + inline.stderr)
        self.assertEqual(self.command_verdicts(), [])
        normal = self.run_project_gate(command, extra=extra)
        self.assertNotIn("reused verdict", normal.stdout)
        self.assertNotEqual(normal.returncode, 0, normal.stdout)
        # The default home's own config is bound by content.
        (home / ".cargo").mkdir(exist_ok=True)
        with mock.patch.dict(os.environ, {"PATH": self.project_path, "HOME": str(home)}):
            self.clear_hook_git_env()
            before = VERDICT.capture_inputs(self.root, command=command, runner={"gate": "x"}, tools={})
            (home / ".cargo/config.toml").write_text("[build]\njobs = 1\n")
            after = VERDICT.capture_inputs(self.root, command=command, runner={"gate": "x"}, tools={})
        self.assertNotEqual(VERDICT.key(before), VERDICT.key(after))

    def test_n4_package_manager_options_and_config_never_publish(self):
        self.start_project_gate()
        if shutil.which("npm") is None:
            self.skipTest("npm is required")
        home = self.base / "npm-home"
        home.mkdir()
        self.commit_files({"package.json": json.dumps({"scripts": {"test": "node --test"}}),
                           "suite.test.mjs": 'import { test } from "node:test";\ntest("fails", () => { throw new Error("x"); });\n'})
        rc = self.base / "private-npmrc"
        rc.write_text("script-shell=/usr/bin/true\n")
        command = "npm --userconfig=" + str(rc) + " test"
        hidden = self.run_project_gate(command, extra={"HOME": str(home)})
        self.assertEqual(hidden.returncode, 0, hidden.stdout + hidden.stderr)
        self.assertEqual(self.command_verdicts(), [])
        rc.write_text("")
        result = self.run_project_gate(command, extra={"HOME": str(home)})
        self.assertNotIn("reused verdict", result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        # r151 F1: a user npmrc that replaces the script shell never publishes.
        (home / ".npmrc").write_text("script-shell=/usr/bin/true\n")
        self.assertEqual(self.run_project_gate("npm test", extra={"HOME": str(home)}).returncode, 0)
        self.assertEqual(self.command_verdicts(), [])
        (home / ".npmrc").unlink()
        result = self.run_project_gate("npm test", extra={"HOME": str(home)})
        self.assertNotIn("reused verdict", result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def ignored_source_gate(self, command, files, ignored, passing, failing, extra=None):
        """Pass with an ignored test source, mutate it to fail: the gate must not reuse."""
        self.commit_files(files)
        source = self.root / ignored
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(passing)
        self.assertEqual(self.git("status", "--porcelain"), b"")
        first = self.run_project_gate(command, extra=extra)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(self.command_verdicts(), [], ignored)
        source.write_text(failing)
        second = self.run_project_gate(command, extra=extra)
        self.assertNotIn("reused verdict", second.stdout)
        self.assertNotEqual(second.returncode, 0, second.stdout)

    def test_n5_ignored_coverage_tests_are_discovered_by_pytest(self):
        self.start_project_gate()
        if subprocess.run([sys.executable, "-c", "import pytest"], capture_output=True).returncode != 0:
            self.skipTest("pytest is required")
        self.ignored_source_gate("python3 -m pytest -q -p no:cacheprovider",
                                 {".gitignore": "coverage/\n__pycache__/\n", "tests/test_ok.py": "def test_ok():\n    pass\n"},
                                 "coverage/test_extra.py", "def test_extra():\n    pass\n",
                                 "def test_extra():\n    assert False\n", extra={"PYTHONDONTWRITEBYTECODE": "1"})

    def test_n5_ignored_coverage_tests_are_discovered_by_node(self):
        self.start_project_gate()
        self.ignored_source_gate(self.TEST_CMD, {".gitignore": "coverage/\n"}, "coverage/extra.test.js",
                                 'require("node:test")("extra", () => {});\n',
                                 'require("node:test")("extra", () => { throw new Error("x"); });\n')

    def test_n5_ignored_cargo_test_named_by_committed_config(self):
        self.start_project_gate()
        rustup_home, _ = self.real_rust()
        self.ignored_source_gate("cargo test --offline",
                                 {".gitignore": "dist/\n", "src/lib.rs": "\n", "Cargo.lock": self.CARGO_LOCK,
                                  "Cargo.toml": '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\n'
                                                '[[test]]\nname = "extra"\npath = "dist/extra.rs"\n'},
                                 "dist/extra.rs", "#[test]\nfn extra() {}\n",
                                 "#[test]\nfn extra() { panic!(\"x\"); }\n", extra=self.cargo_extra(rustup_home))

    def test_n6_hard_linked_rustup_proxy_is_keyed_on_the_selected_compiler(self):
        self.start_project_gate()
        rustup_home, rustup = self.real_rust()
        links = self.base / "hardlinked"
        links.mkdir()
        shutil.copyfile(rustup, links / "rustup-copy")
        (links / "rustup-copy").chmod(0o755)
        for name in ("rustc", "cargo"):
            os.link(links / "rustup-copy", links / name)
        environment = dict(os.environ, RUSTUP_HOME=str(rustup_home), RUSTUP_AUTO_INSTALL="0")
        versions = {}
        for toolchain in ("stable", "1.97.1"):
            result = subprocess.run([str(links / "rustc"), "--version"], capture_output=True, text=True,
                                    env=dict(environment, RUSTUP_TOOLCHAIN=toolchain))
            versions[toolchain] = result.stdout.split()[1] if result.returncode == 0 else None
        if None in versions.values() or len(set(versions.values())) != 2:
            self.skipTest("two distinct installed rust toolchains (stable, 1.97.1) are required")
        path = str(links) + os.pathsep + self.project_path
        extra = {"RUSTUP_HOME": str(rustup_home), "WANT_RUSTC": versions["stable"]}
        stable = self.run_project_gate(self.TEST_CMD, path=path, extra=extra)
        self.assertEqual(stable.returncode, 0, stable.stdout + stable.stderr)
        [verdict] = self.command_verdicts()
        recorded = json.loads(verdict.read_text())
        pinned = self.run_project_gate(self.TEST_CMD, path=path, extra=dict(extra, RUSTUP_TOOLCHAIN="1.97.1"))
        self.assertNotIn("reused verdict", pinned.stdout)
        self.assertNotEqual(pinned.returncode, 0, pinned.stdout)
        self.assertEqual(recorded["inputs"]["toolchain"]["rustc"]["effective"]["manager"], "rustup")

    def test_n8_forced_full_failures_invalidate_and_block_overlapping_publication(self):
        self.start_project_gate()
        flag = self.base / "fail-flag"
        extra = {"FAIL_FLAG": str(flag)}
        self.assertEqual(self.run_project_gate(self.TEST_CMD, extra=extra).returncode, 0)
        self.assertEqual(len(self.command_verdicts()), 1)
        flag.write_text("")
        forced = self.run_project_gate(self.TEST_CMD, extra=dict(extra, PG_PUSH_TEST_SCOPE="full"))
        self.assertNotEqual(forced.returncode, 0, forced.stdout)
        self.assertNotIn("reused verdict", forced.stdout)
        ordinary = self.run_project_gate(self.TEST_CMD, extra=extra)
        self.assertNotIn("reused verdict", ordinary.stdout)
        self.assertNotEqual(ordinary.returncode, 0, ordinary.stdout)
        self.assertEqual(self.command_verdicts(), [])
        # Overlap: A starts; a forced-full B fails meanwhile; A's pass is never published.
        flag.unlink()
        save = self.base / "a-inputs"
        save.write_text("")
        save.chmod(0o600)
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            head = self.git("rev-parse", "HEAD").decode().strip()
            common = ["--head=" + head, "--command=" + self.TEST_CMD, "--save=" + str(save)]
            self.assertEqual(self.cli("lookup", *common, "--owner-pid=%d" % os.getpid()), 1)
            flag.write_text("")
            self.assertNotEqual(self.run_project_gate(self.TEST_CMD, extra=dict(extra, PG_PUSH_TEST_SCOPE="full")).returncode, 0)
            flag.unlink()
            self.assertEqual(self.cli("record", *common, "--log=-", stdin=b"ok\n"), 1)
        self.assertEqual(self.command_verdicts(), [])

    def test_n9_unhealthy_store_never_reuses_and_failures_survive_repair(self):
        self.start_project_gate()
        flag = self.base / "fail-flag"
        extra = {"FAIL_FLAG": str(flag)}
        self.assertEqual(self.run_project_gate(self.TEST_CMD, extra=extra).returncode, 0)
        self.assertEqual(len(self.command_verdicts()), 1)
        lock = self.store / ".lock"
        lock.chmod(0o640)
        directory = Path(self.project_path.split(os.pathsep)[0])
        wrapper = directory / "bash"
        flag.write_text("")
        wrapper.write_text(wrapper.read_text().replace("fixture bash 1", "fixture bash 2"))
        failed = self.run_project_gate(self.TEST_CMD, extra=extra)
        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        # r151 F10: the unhealthy store is moved aside and the run is tracked in a fresh one.
        self.assertIn("verdict store was unhealthy", failed.stdout)
        aside = [path for path in self.store.parent.iterdir() if path.name.startswith("gate-verdicts.unhealthy-")]
        self.assertEqual(len(aside), 1)
        wrapper.write_text(wrapper.read_text().replace("fixture bash 2", "fixture bash 1"))
        unhealthy = self.run_project_gate(self.TEST_CMD, extra=extra)
        self.assertNotIn("reused verdict", unhealthy.stdout)
        self.assertNotEqual(unhealthy.returncode, 0, unhealthy.stdout)
        # Repairing the old lock does not revive the pass those failures superseded.
        (aside[0] / ".lock").chmod(0o600)
        lock.chmod(0o600)
        repaired = self.run_project_gate(self.TEST_CMD, extra=extra)
        self.assertNotIn("reused verdict", repaired.stdout)
        self.assertNotEqual(repaired.returncode, 0, repaired.stdout)
        flag.unlink()
        self.assertEqual(self.run_project_gate(self.TEST_CMD, extra=extra).returncode, 0)
        self.assertIn("reused verdict", self.run_project_gate(self.TEST_CMD, extra=extra).stdout)
        # A run that exits without finalizing (killed gate) counts as a failure.
        inputs = json.loads(self.command_verdicts()[0].read_text())["inputs"]
        child = subprocess.Popen(["true"])
        child.wait()  # Its pid now names no live owner.
        VERDICT.begin_command_run(inputs, child.pid, reuse=False, store=self.store)
        self.assertIsNone(VERDICT.find_command_verdict(inputs, self.store))
        self.assertNotIn("reused verdict", self.run_project_gate(self.TEST_CMD, extra=extra).stdout)

    # r151 reuse4: a reused verdict equals what rerunning the identical
    # command, in the same keyed tree and environment, would give now.

    def test_f1_user_cargo_runner_replaces_the_executor_and_never_publishes(self):
        self.start_project_gate()
        rustup_home, _ = self.real_rust()
        self.commit_files({"Cargo.toml": '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\n',
                           "Cargo.lock": self.CARGO_LOCK,
                           "src/lib.rs": '#[test]\nfn committed_failure() { panic!("committed failure"); }\n'})
        home = self.base / "cargo-user-home"
        (home / ".cargo").mkdir(parents=True)
        runner = self.base / "cargo-runner"
        runner.write_text("#!/bin/sh\nexit 0\n")
        runner.chmod(0o755)
        (home / ".cargo/config.toml").write_text("[target.'cfg(all())']\nrunner = \"%s\"\n" % runner)
        extra = dict(self.cargo_extra(rustup_home), HOME=str(home))
        hidden = self.run_project_gate("cargo test --offline", extra=extra)
        self.assertEqual(hidden.returncode, 0, hidden.stdout + hidden.stderr)
        self.assertEqual(self.command_verdicts(), [])
        # Only the runner's bytes change: config, command and tree are the same.
        runner.write_text('#!/bin/sh\nexec "$@"\n')
        direct = self.run_project_gate("cargo test --offline", extra=extra)
        self.assertNotIn("reused verdict", direct.stdout)
        self.assertNotEqual(direct.returncode, 0, direct.stdout)
        # Source redirects to code outside the tree refuse too; ordinary settings stay keyed.
        with mock.patch.dict(os.environ, {"PATH": self.project_path, "HOME": str(home)}):
            self.clear_hook_git_env()
            for text in ('[patch.crates-io]\nserde = { path = "/elsewhere/serde" }\n',
                         '[source.crates-io]\nreplace-with = "vendored"\n[source.vendored]\ndirectory = "/elsewhere"\n',
                         '[target.x86_64-unknown-linux-gnu]\nrustflags = ["-C", "linker=/elsewhere/ld"]\n', "not toml ["):
                with self.subTest(config=text):
                    (home / ".cargo/config.toml").write_text(text)
                    self.assertIsNone(VERDICT.safe_inputs(self.root, command="cargo test", runner={"gate": "x"}, tools={}))
            (home / ".cargo/config.toml").write_text("[build]\njobs = 2\n")
            self.assertIsNotNone(VERDICT.safe_inputs(self.root, command="cargo test", runner={"gate": "x"}, tools={}))

    def test_f1_user_npm_script_shell_replaces_the_executor_and_never_publishes(self):
        self.start_project_gate()
        if shutil.which("npm") is None:
            self.skipTest("npm is required")
        home = self.base / "npm-user-home"
        home.mkdir()
        self.commit_files({"package.json": json.dumps({"scripts": {"test": "node --test"}}),
                           "suite.test.mjs": 'import { test } from "node:test";\ntest("fails", () => { throw new Error("x"); });\n'})
        shell = self.base / "script-shell"
        shell.write_text("#!/bin/sh\nexit 0\n")
        shell.chmod(0o755)
        (home / ".npmrc").write_text("script-shell=%s\n" % shell)
        hidden = self.run_project_gate("npm test", extra={"HOME": str(home)})
        self.assertEqual(hidden.returncode, 0, hidden.stdout + hidden.stderr)
        self.assertEqual(self.command_verdicts(), [])
        shell.write_text('#!/bin/sh\nexec /bin/sh "$@"\n')
        direct = self.run_project_gate("npm test", extra={"HOME": str(home)})
        self.assertNotIn("reused verdict", direct.stdout)
        self.assertNotEqual(direct.returncode, 0, direct.stdout)
        # Configuration that only shapes installs stays keyed by content.
        (home / ".npmrc").write_text("fund=false\n")
        with mock.patch.dict(os.environ, {"PATH": self.project_path, "HOME": str(home)}):
            self.clear_hook_git_env()
            self.assertIsNotNone(VERDICT.safe_inputs(self.root, command="npm test", runner={"gate": "x"}, tools={}))

    def project_eligible(self, command):
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            return VERDICT.safe_inputs(self.root, command=command, runner={"gate": "x"}, tools={}) is not None

    def test_r1_committed_or_ancestor_executor_config_never_publishes(self):
        # r151-reuse4 R1 (Sol config-probes committed-npm-script-shell and
        # ancestor-yarn-rc): hashing a committed or ancestor rc binds its
        # text, not the program it names.
        self.start_project_gate()
        if shutil.which("npm") is None:
            self.skipTest("npm is required")
        shell = self.base / "script-shell"
        shell.write_text('#!/bin/sh\nexec /bin/sh "$@"\n')
        shell.chmod(0o755)
        self.commit_files({"package.json": json.dumps({"scripts": {"test": "node --test"}}),
                           ".npmrc": "script-shell=%s\n" % shell})
        first = self.run_project_gate("npm test")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        shell.write_text("#!/bin/sh\nexit 1\n")
        second = self.run_project_gate("npm test")
        self.assertNotIn("reused verdict", second.stdout)
        self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self.command_verdicts(), [])
        # A committed executor is allowed only as a tracked path in the tree.
        tool = '#!/bin/sh\nexec /bin/sh "$@"\n'
        self.commit_files({"tools/shell.sh": tool})
        for line, eligible in (("script-shell=./tools/shell.sh", True), ("script-shell = tools/shell.sh", True),
                               ("script-shell=bash", False), ("script-shell=/bin/sh", False),
                               ("script-shell=../shell", False), ("script-shell=./tools/missing.sh", False),
                               ("node-options=--require ./tools/shell.sh", False), ("fund=false", True)):
            with self.subTest(npmrc=line):
                self.commit_files({".npmrc": line + "\n"})
                self.assertEqual(self.project_eligible("npm test"), eligible)
        self.git("rm", "-q", ".npmrc")
        self.commit()
        for text, eligible in (('[target.x86_64-unknown-linux-gnu]\nrunner = "/usr/bin/true"\n', False),
                               ('[target.x86_64-unknown-linux-gnu]\nrunner = ["./tools/shell.sh", "--flag"]\n', True),
                               ('[target.aarch64-apple-darwin]\nlinker = "cc"\n', False),
                               ('[patch.crates-io]\nfoo = { path = "tools" }\n', True),
                               ('[patch.crates-io]\nfoo = { path = "/tmp/foo" }\n', False),
                               ('[build]\nrustflags = ["-C", "linker=/tmp/ld"]\n', False),
                               ('[build]\njobs = 2\n', True)):
            with self.subTest(cargo=text):
                self.commit_files({".cargo/config.toml": text})
                self.assertEqual(self.project_eligible("cargo test"), eligible)
        self.git("rm", "-q", ".cargo/config.toml")
        self.commit()
        # Ancestor rc files, from the checkout up to /, are inventoried.
        self.assertTrue(self.project_eligible("npm test"))
        for name, text in ((".yarnrc", 'script-shell "%s"\n' % shell), (".npmrc", "script-shell=%s\n" % shell),
                           (".yarnrc.yml", "yarnPath: .yarn/releases/yarn.cjs\n")):
            with self.subTest(ancestor=name):
                (self.base / name).write_text(text)
                self.assertFalse(self.project_eligible("yarn test"))
                self.assertFalse(self.project_eligible("npm test"))
                (self.base / name).unlink()
        (self.base / ".npmrc").write_text("fund=false\n")
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            before = VERDICT.capture_inputs(self.root, command="npm test", runner={"gate": "x"}, tools={})
            (self.base / ".npmrc").write_text("fund=true\n")
            after = VERDICT.capture_inputs(self.root, command="npm test", runner={"gate": "x"}, tools={})
        self.assertNotEqual(VERDICT.key(before), VERDICT.key(after))
        (self.base / ".npmrc").unlink()
        if shutil.which("yarn", path=self.project_path) is not None:
            shell.write_text('#!/bin/sh\nexec /bin/sh "$@"\n')
            (self.base / ".yarnrc").write_text('script-shell "%s"\n' % shell)
            first = self.run_project_gate("yarn test")
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            shell.write_text("#!/bin/sh\nexit 1\n")
            second = self.run_project_gate("yarn test")
            self.assertNotIn("reused verdict", second.stdout)
            self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
            (self.base / ".yarnrc").unlink()
        # The native stages' Cargo adapter runs from /: its config is keyed,
        # and an executor there refuses the full battery.
        cwd = self.base / "native-cwd"
        (cwd / ".cargo").mkdir(parents=True)
        with mock.patch.object(VERDICT, "NATIVE_CARGO_CWD", cwd):
            plain = VERDICT.capture_inputs(self.root, tools={})
            (cwd / ".cargo/config.toml").write_text("[term]\nverbose = true\n")
            self.assertNotEqual(VERDICT.key(VERDICT.capture_inputs(self.root, tools={})), VERDICT.key(plain))
            (cwd / ".cargo/config.toml").write_text('[target.x86_64-unknown-linux-gnu]\nrunner = "/usr/bin/true"\n')
            with self.assertRaises(ValueError) as refused:
                VERDICT.capture_inputs(self.root, tools={})
            self.assertNotIsInstance(refused.exception, VERDICT.ProbeUnavailable)

    def test_r2_reporters_in_committed_runner_config_meet_the_reporter_contract(self):
        # r151-reuse4 R2 (Sol config-probes jest-config-external-reporter).
        self.start_project_gate()
        external = self.base / "reporter.cjs"
        external.write_text("module.exports = class {};\n")

        def jest_package(**config):
            return json.dumps({"jest": dict({"testMatch": ["**/*.spec.js"]}, **config)})
        self.commit_files({"package.json": jest_package(reporters=["default", str(external)]),
                           "passing.spec.js": 'test("passing", () => {});\n',
                           "tools/reporter.cjs": "module.exports = class {};\n"})
        if shutil.which("jest", path=self.project_path) is not None:
            first = self.run_project_gate("jest --runInBand")
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            external.write_text("process.exit(1);\n")
            second = self.run_project_gate("jest --runInBand")
            self.assertNotIn("reused verdict", second.stdout)
            self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
            external.write_text("module.exports = class {};\n")
        self.assertFalse(self.project_eligible("jest --runInBand"))
        for config, eligible in (({"reporters": ["default"]}, True),
                                 ({"reporters": ["default", "<rootDir>/tools/reporter.cjs"]}, True),
                                 ({"reporters": [["./tools/reporter.cjs", {"x": 1}]]}, True),
                                 ({"reporters": ["jest-junit"]}, False), ({"reporters": [str(external)]}, False),
                                 ({"reporters": ["./untracked.cjs"]}, False),
                                 ({"coverageReporters": ["text", "lcov"]}, True),
                                 ({"coverageReporters": [str(external)]}, False),
                                 ({"testResultsProcessor": str(external)}, False)):
            with self.subTest(config=config):
                self.commit_files({"package.json": jest_package(**config)})
                self.assertEqual(self.project_eligible("jest --runInBand"), eligible)
        self.commit_files({"package.json": jest_package(),
                           "jest.config.json": json.dumps({"reporters": [str(external)]})})
        self.assertFalse(self.project_eligible("jest --runInBand"))
        self.git("rm", "-q", "jest.config.json")
        self.commit_files({"jest.config.js": "module.exports = { reporters: [process.env.R] };\n"})
        self.assertFalse(self.project_eligible("jest --runInBand"))
        self.git("rm", "-q", "jest.config.js")
        self.commit_files({"vitest.config.ts": "export default { test: { reporters: ['default'] } };\n"})
        self.assertFalse(self.project_eligible("vitest run"))
        self.commit_files({"vitest.config.ts": "export default { test: {} };\n"})
        self.assertTrue(self.project_eligible("vitest run"))
        self.assertTrue(self.project_eligible("jest --runInBand"))
        # Every accepted config file name is checked, not a fixed list.
        for name, command in (("jest.config.cts", "jest --runInBand"), ("vite.config.cjs", "vitest run"),
                              ("vitest.workspace.mts", "vitest run")):
            with self.subTest(config=name):
                self.commit_files({name: "export default { reporters: ['default'] };\n"})
                self.assertFalse(self.project_eligible(command))
                self.git("rm", "-q", name)
                self.commit()
        # Module-loading options may name a package or an in-tree path, not an outside one.
        for config, eligible in (({"preset": "ts-jest", "testEnvironment": "node"}, True),
                                 ({"setupFiles": ["<rootDir>/tools/reporter.cjs"]}, True),
                                 ({"transform": {"^.+\\.js$": ["babel-jest", {"x": 1}]}}, True),
                                 ({"preset": str(self.base)}, False), ({"preset": "../outside"}, False),
                                 ({"transform": {"^.+\\.js$": str(external)}}, False),
                                 ({"globalSetup": "<rootDir>/../setup.js"}, False),
                                 ({"globalSetup": "<rootDir>../setup.js"}, False),
                                 ({"setupFiles": ["./tools/../../x.js"]}, False),
                                 ({"rootDir": "..", "setupFiles": ["<rootDir>/x.js"]}, False),
                                 ({"rootDir": "."}, True), ({"roots": ["<rootDir>/tools"]}, True),
                                 ({"roots": [str(self.base)]}, False), ({"modulePaths": ["/opt/lib"]}, False),
                                 ({"moduleDirectories": ["node_modules", "tools"]}, True),
                                 ({"moduleNameMapper": {"^x$": str(external)}}, False),
                                 ({"projects": ["<rootDir>/tools"]}, False), ({"projects": ["../sibling"]}, False),
                                 ({"projects": [{"setupFiles": [str(external)]}]}, False),
                                 ({"setupFilesAfterEnv": [str(external)]}, False)):
            with self.subTest(config=config):
                self.commit_files({"package.json": jest_package(**config)})
                self.assertEqual(self.project_eligible("jest --runInBand"), eligible)

    def real_jest_gate(self, files, outside, changed):
        """Sol final-hardening-probes: pass, change only an outside file, rerun."""
        self.commit_files(files)
        first = self.run_project_gate("jest --runInBand")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        outside.write_text(changed)
        second = self.run_project_gate("jest --runInBand")
        self.assertNotIn("reused verdict", second.stdout)
        self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self.command_verdicts(), [])

    def test_r6_string_jest_projects_refuse_reuse(self):
        # r151-reuse4 R6: Jest loads a string project's own configuration
        # (here a subproject jest.config.json with an outside globalSetup),
        # which the check never reads. Any string entry refuses, at any depth.
        self.start_project_gate()
        outside = self.base / "setup.cjs"
        outside.write_text("module.exports = async () => {};\n")
        files = {"package.json": json.dumps({"jest": {"projects": ["<rootDir>/subproject"]}}),
                 "subproject/jest.config.json": json.dumps({"testMatch": ["**/*.spec.js"], "globalSetup": str(outside)}),
                 "subproject/passing.spec.js": 'test("passing", () => {});\n'}
        if shutil.which("jest", path=self.project_path) is not None:
            self.real_jest_gate(files, outside, "module.exports = async () => { process.exit(1); };\n")
        else:
            self.commit_files(files)
        self.assertFalse(self.project_eligible("jest --runInBand"))
        for config, eligible in (({"projects": [{"displayName": "unit", "testMatch": ["**/*.spec.js"]}]}, True),
                                 ({"projects": [{"displayName": "a", "projects": ["<rootDir>/subproject"]}]}, False),
                                 ({"projects": "<rootDir>/subproject"}, False)):
            with self.subTest(config=config):
                self.commit_files({"package.json": json.dumps({"jest": config})})
                self.assertEqual(self.project_eligible("jest --runInBand"), eligible)
        self.commit_files({"package.json": json.dumps({"jest": {}}),
                           "jest.config.json": json.dumps({"projects": ["subproject"]})})
        self.assertFalse(self.project_eligible("jest --runInBand"))

    def test_r7_tracked_symlinks_leaving_the_tree_refuse_reuse(self):
        # r151-reuse4 R7: the key binds a symlink's target spelling, not the
        # files it reaches. A relative Jest rootDir through a tracked link
        # ran an outside suite; any runner, and the full battery, alike.
        self.start_project_gate()
        suite = self.base / "outside-suite"
        suite.mkdir()
        outside = suite / "passing.spec.js"
        outside.write_text('test("passing", () => {});\n')
        (self.root / "suite").symlink_to(suite, target_is_directory=True)
        files = {"package.json": json.dumps({"jest": {"rootDir": "./suite", "testMatch": ["**/*.spec.js"]}})}
        if shutil.which("jest", path=self.project_path) is not None:
            self.real_jest_gate(files, outside, 'test("passing", () => { throw new Error("CHANGED"); });\n')
        else:
            self.commit_files(files)
        for command in ("jest --runInBand", self.TEST_CMD):
            with self.subTest(command=command):
                self.assertFalse(self.project_eligible(command))
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            with self.assertRaises(ValueError) as refused:
                VERDICT.capture_inputs(self.root, tools={})
        self.assertIn("suite", str(refused.exception))
        self.assertNotIsInstance(refused.exception, VERDICT.ProbeUnavailable)
        self.git("rm", "-q", "suite")
        self.commit_files({"package.json": json.dumps({"jest": {"testMatch": ["**/*.spec.js"]}}), "tools/x.js": "\n"})
        self.assertTrue(self.project_eligible(self.TEST_CMD))
        (self.root / "node_modules").mkdir()
        (self.root / "node_modules/out.js").write_text("\n")
        self.commit_files({".gitignore": "node_modules/\n"})
        (self.root / "tools/deep").mkdir()
        (self.root / "tools/deep/inner.js").write_text("\n")
        (self.root / "tools/hop").symlink_to("deep/inner.js")
        self.commit_files({"tools/up": "\n"})
        # "via-link/../x" resolves through tools/hop on disk, not lexically.
        links = {"in-tree": "tools/x.js", "chained": "in-tree/../..", "dangling": "../nowhere",
                 "absolute": str(self.root / "tools/x.js"), "untracked": "tools/missing.js",
                 "ignored": "node_modules/out.js", "git-dir": ".git/config", "git-case": ".GIT/config",
                 "directory": "tools", "via-link": "tools/hop/../up"}
        for name, eligible in (("in-tree", True), ("chained", False), ("dangling", False), ("absolute", False),
                               ("untracked", False), ("ignored", False), ("git-dir", False), ("git-case", False),
                               ("directory", False), ("via-link", False)):
            with self.subTest(link=name):
                (self.root / name).symlink_to(links[name])
                self.commit()
                self.assertEqual(self.project_eligible(self.TEST_CMD), eligible)
                if name != "in-tree":
                    self.git("rm", "-q", name)
                    self.commit()
        # Jest path fields check physical containment, not only spelling
        # (an ignored link the config names is refused earlier as well).
        (self.root / "linkdir").symlink_to(suite, target_is_directory=True)
        (self.root / "realdir").mkdir()
        for value, outside_tree in (("./linkdir/setup.js", True), ("<rootDir>/linkdir", True),
                                    ("./realdir/setup.js", False), ("<rootDir>/tools/x.js", False), ("ts-jest", False),
                                    ("<rootDir>/.git/hooks/x.js", True), ("./.GIT/hooks/x.js", True)):
            with self.subTest(value=value):
                self.assertEqual(VERDICT._outside_module(self.root, value), outside_tree)
        # A submodule's content is not this tree's.
        os.unlink(self.root / "linkdir")
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.git("rev-parse", "HEAD").decode().strip() + ",vendor")
        self.git("commit", "-qm", "gitlink")
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            self.assertIn("submodule", VERDICT.escaping_symlink(self.root))

    def test_f1_path_valued_settings_never_publish(self):
        self.start_project_gate()
        rc = self.base / "elsewhere.yarnrc.yml"
        rc.write_text("enableScripts: false\n")
        for name, value in (("YARN_RC_FILENAME", str(rc)), ("UV_CONFIG_FILE", str(rc)), ("PDM_PYTHON", "/opt/python3"),
                            ("UV_INDEX_URL", "file://" + str(self.base)), ("GOWORK", str(self.base / "go.work")),
                            ("GOROOT", str(self.base))):
            with self.subTest(name=name):
                result = self.run_project_gate(self.TEST_CMD, extra={name: value})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.command_verdicts(), [])
                self.assertEqual(VERDICT.env_rule(name, value)[0], "refuse")

    def test_f2_control_characters_never_parse_as_whitespace(self):
        self.start_project_gate()
        if subprocess.run([sys.executable, "-c", "import pytest"], capture_output=True).returncode != 0:
            self.skipTest("pytest is required")
        self.commit_files({"true/README": "a tracked directory named like a command\n",
                           "tests/test_fail.py": "def test_fail():\n    assert False\n"})
        command = "python3 -m pytest -q -p no:cacheprovider\ntrue"
        extra = {"PYTHONDONTWRITEBYTECODE": "1"}
        first = self.run_project_gate(command, extra=extra)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)  # Bash runs pytest, then true.
        self.assertEqual(self.command_verdicts(), [])
        self.assertNotIn("reused verdict", self.run_project_gate(command, extra=extra).stdout)
        for text in ("node --test\tcoverage", "node --test\r", "node --test\x0b"):
            with self.subTest(command=text), self.assertRaises(ValueError):
                VERDICT.command_runners(self.root, text)
        self.commit_files({"package.json": json.dumps({"scripts": {"test": "node --test\nnode"}})})
        with self.assertRaises(ValueError):
            VERDICT.command_runners(self.root, "npm test")

    def test_f6_reporter_modules_outside_the_tree_never_publish(self):
        self.start_project_gate()
        self.commit_files({"suite.test.mjs": 'import { test } from "node:test";\ntest("fails", () => { throw new Error("x"); });\n',
                           "reporter.cjs": "module.exports = async function* (source) { for await (const _ of source) {} };\n"})
        reporter = self.base / "reporter.cjs"
        reporter.write_text("module.exports = async function* () { process.exit(0); };\n")
        command = "node --test --test-reporter=" + str(reporter)
        first = self.run_project_gate(command)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)  # The reporter ends the run first.
        self.assertEqual(self.command_verdicts(), [])
        self.assertNotIn("reused verdict", self.run_project_gate(command).stdout)
        for value in ("some-reporter", "@scope/reporter", "reporter.cjs", "../reporter.cjs", "./untracked.cjs"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                VERDICT.command_runners(self.root, "node --test --test-reporter=" + value)
        # A built-in reporter, or a module tracked in HEAD, is part of the keyed tree.
        for value in ("spec", "./reporter.cjs"):
            with self.subTest(value=value):
                VERDICT.command_runners(self.root, "node --test --test-reporter=" + value)

    def test_f8_node_discovers_ignored_tests_in_pycache(self):
        self.start_project_gate()
        self.ignored_source_gate(self.TEST_CMD, {".gitignore": "__pycache__/\n"}, "__pycache__/extra.test.js",
                                 'require("node:test")("extra", () => {});\n',
                                 'require("node:test")("extra", () => { throw new Error("x"); });\n')

    def test_f8_explicit_pytest_root_is_traversed_whatever_its_name(self):
        self.start_project_gate()
        if subprocess.run([sys.executable, "-c", "import pytest"], capture_output=True).returncode != 0:
            self.skipTest("pytest is required")
        self.ignored_source_gate("python3 -m pytest -q -p no:cacheprovider .hidden",
                                 {".gitignore": ".hidden/test_extra.py\n__pycache__/\n",
                                  ".hidden/test_ok.py": "def test_ok():\n    pass\n"},
                                 ".hidden/test_extra.py", "def test_extra():\n    pass\n",
                                 "def test_extra():\n    assert False\n", extra={"PYTHONDONTWRITEBYTECODE": "1"})
        # Every spelling of the root is the same root.
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            for spelling in ("./.hidden", ".hidden/", "./.hidden/", ".//.hidden"):
                with self.subTest(root=spelling):
                    self.assertIsNone(VERDICT.safe_inputs(self.root, command="pytest " + spelling,
                                                          runner={"gate": "x"}, tools={}))
        # An ignored conftest.py on the way to an explicit root is loaded too.
        (self.root / ".hidden/test_extra.py").unlink()
        self.commit_files({".gitignore": "build/conftest.py\n", "build/tests/test_ok.py": "def test_ok():\n    pass\n"})
        (self.root / "build/conftest.py").write_text("")
        with mock.patch.dict(os.environ, {"PATH": self.project_path}):
            self.clear_hook_git_env()
            self.assertIsNone(VERDICT.safe_inputs(self.root, command="pytest build/tests", runner={"gate": "x"}, tools={}))
            # Not on the way to the root, inside a skipped directory: never loaded.
            self.assertIsNotNone(VERDICT.safe_inputs(self.root, command="pytest .hidden", runner={"gate": "x"}, tools={}))

    def test_f9_abandoned_failure_supersedes_passes_overlapping_it(self):
        self.start_project_gate()
        flag = self.base / "fail-flag"
        extra = {"FAIL_FLAG": str(flag)}
        save = self.base / "a-inputs"
        save.write_text("")
        save.chmod(0o600)
        owner = subprocess.Popen(["sleep", "120"])
        try:
            with mock.patch.dict(os.environ, {"PATH": self.project_path}):
                self.clear_hook_git_env()
                head = self.git("rev-parse", "HEAD").decode().strip()
                self.assertEqual(self.cli("lookup", "--head=" + head, "--command=" + self.TEST_CMD,
                                          "--save=" + str(save), "--owner-pid=%d" % owner.pid), 1)
            # B passes and publishes while A is unresolved.
            passed = self.run_project_gate(self.TEST_CMD, extra=extra)
            self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            self.assertEqual(len(self.command_verdicts()), 1)
        finally:
            owner.kill()
            owner.wait()
        # A then failed and died without finalizing, after B completed.
        flag.write_text("")
        resolved = self.run_project_gate(self.TEST_CMD, extra=extra)
        self.assertNotIn("reused verdict", resolved.stdout)
        self.assertNotEqual(resolved.returncode, 0, resolved.stdout)

    def test_f10_untrackable_store_moves_aside_or_never_runs(self):
        self.start_project_gate()
        flag = self.base / "fail-flag"
        extra = {"FAIL_FLAG": str(flag)}
        self.assertEqual(self.run_project_gate(self.TEST_CMD, extra=extra).returncode, 0)
        self.assertEqual(len(self.command_verdicts()), 1)
        # An inflight/ directory that cannot hold an intent.
        (self.store / "inflight").chmod(0o500)
        flag.write_text("")
        forced = self.run_project_gate(self.TEST_CMD, extra=dict(extra, PG_PUSH_TEST_SCOPE="full"))
        self.assertNotEqual(forced.returncode, 0, forced.stdout)
        for path in self.store.parent.iterdir():
            if path.name.startswith("gate-verdicts.unhealthy-"):
                (path / "inflight").chmod(0o700)  # The repair.
        (self.store / "inflight").chmod(0o700)
        repaired = self.run_project_gate(self.TEST_CMD, extra=extra)
        self.assertNotIn("reused verdict", repaired.stdout)
        self.assertNotEqual(repaired.returncode, 0, repaired.stdout)
        self.assertIn("verdict store was unhealthy", forced.stdout)
        # When the unhealthy store cannot be moved aside, the command never runs untracked.
        flag.unlink()
        self.assertEqual(self.run_project_gate(self.TEST_CMD, extra=extra).returncode, 0)
        (self.store / ".lock").chmod(0o640)
        self.store.parent.chmod(0o500)
        runs = self.project_runs()
        try:
            blocked = self.run_project_gate(self.TEST_CMD, extra=extra)
        finally:
            self.store.parent.chmod(0o700)
        self.assertNotEqual(blocked.returncode, 0, blocked.stdout)
        self.assertIn("tests: not run", blocked.stdout)
        self.assertNotIn("reused verdict", blocked.stdout)
        self.assertEqual(self.project_runs(), runs)

    def test_range_interface_never_reaches_a_reuse_tracked_command(self):
        self.start_project_gate()
        self.commit_files({"range.test.mjs": (
            'import { test } from "node:test";\n'
            'test("always", () => {});\n'
            '// Committed code that narrows on the gate range interface.\n'
            'if (!process.env.PG_TESTS_BASE) test("whole suite", () => { throw new Error("full run"); });\n')})
        narrow = self.run_project_gate(self.TEST_CMD, range_arg="HEAD~1..HEAD", mode=("--mode=push",))
        self.assertNotEqual(narrow.returncode, 0, narrow.stdout)
        self.assertEqual(self.command_verdicts(), [])
        wider = self.run_project_gate(self.TEST_CMD, range_arg="HEAD~2..HEAD", mode=("--mode=push",))
        self.assertNotIn("reused verdict", wider.stdout)
        self.assertNotEqual(wider.returncode, 0, wider.stdout)

    def test_selected_runs_never_publish_full_and_gate_interface_is_parent_only(self):
        self.run_runner_cases(("selected", "gate-interface"))

    def test_native_only_cannot_reuse_a_full_battery_verdict(self):
        for command in (
            "bash scripts/run-tests.sh --native-cargo-only",
            "env TRELLIS_NATIVE_CARGO_ONLY=qualification bash scripts/run-tests.sh --native-cargo-only",
        ):
            with self.subTest(command=command):
                with self.assertRaises(ValueError):
                    VERDICT.command_runners(self.root, command)
                self.assertIsNone(VERDICT.safe_inputs(self.root, command=command))
        seeded = self.path.read_bytes()
        runner_spec = importlib.util.spec_from_file_location("fixture_native_only_runner", self.root / "scripts/run-tests-local.py")
        runner = importlib.util.module_from_spec(runner_spec)
        runner_spec.loader.exec_module(runner)
        with mock.patch.dict(os.environ, {"TRELLIS_NATIVE_CARGO_ONLY": "qualification"}), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(runner.main(["--native-cargo-only"]), 64)
        self.assertEqual(self.path.read_bytes(), seeded)
        self.path.unlink()  # A refused diagnostic cannot publish a new full verdict either.
        with mock.patch.dict(os.environ, {"TRELLIS_NATIVE_CARGO_ONLY": "qualification"}), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(runner.main(["--native-cargo-only"]), 64)
        self.assertIsNone(VERDICT.find_verdict(self.inputs, self.state))

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
                        # The fixture has no diff base or native input map, so its
                        # native-stage decision fails closed to "run": the plan
                        # carries a cargo stage to match the keyed decision.
                        output.write(b"shard\tstage\tweight\n1\tcargo fixture\t1\ntotal\t1\t1\n")
                    else:
                        if mode == "timeout":
                            raise runner._DeadlineExit()
                        if mode == "killed":
                            raise runner._SignalExit(15)
                        if mode != "partial":
                            Path(environment["TRELLIS_TEST_TSV"]).write_text("ordinal\tstage\telapsed_seconds\texit\n1\tcargo fixture\t1\t0\n")
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
                        mock.patch.object(VERDICT, "native_cargo_identity", return_value=self.inputs["native_cargo"]), \
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

    @contextlib.contextmanager
    def local_runner_gate(self, *, path_prefix=None):
        """check-tests.sh with the local runner command; a shim stands in for its battery."""
        log = self.base / "checks.log"
        bin_dir = self.base / "local-bin"
        bin_dir.mkdir()
        shim = bin_dir / "python3"
        shim.write_text('#!/usr/bin/env bash\nif [ "${1:-}" = scripts/run-tests-local.py ]; then\n'
                        '  printf "tests\\n" >> "$CHECK_LOG"; exit 0\nfi\nexec "$REAL_PYTHON" "$@"\n')
        shim.chmod(0o755)
        self.tools.stop()
        try:
            tools_path = self.versioned_path()
            with mock.patch.dict(os.environ, {"PATH": str(bin_dir) + os.pathsep + tools_path,
                    "PWD": str(self.root), "OLDPWD": str(self.root), "CODEX_PROJECT_DIR": str(self.root),
                    "CLAUDE_PROJECT_DIR": str(self.root), "CHECK_LOG": str(log), "REAL_PYTHON": sys.executable,
                    "PROCESS_GATE_TYPECHECK_CMD": "true", "PROCESS_GATE_LINT_CMD": "true",
                    "PROCESS_GATE_TEST_CMD": "python3 scripts/run-tests-local.py",
                    "PROCESS_GATE_HEAVY_LAUNCHER": "/not/a/launcher"}):
                self.clear_hook_git_env()
                command = ["bash", str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"),
                           "--range=HEAD~1..HEAD"]

                def gate(prefix=None):
                    env = dict(os.environ)
                    if prefix is not None:
                        env["PATH"] = str(prefix) + os.pathsep + env["PATH"]
                    return subprocess.run(command, cwd=self.root, env=env, text=True, capture_output=True, timeout=60)

                def runs():
                    return log.read_text().count("tests\n") if log.exists() else 0
                yield gate, runs
        finally:
            self.tools.start()

    def slow_probe_dir(self):
        """A tool whose --version never answers inside the 2 s probe bound."""
        directory = self.base / "slow-tools"
        directory.mkdir()
        jq = shutil.which("jq") or "/usr/bin/false"
        shell = str(Path(shutil.which("bash")).resolve())
        (directory / "jq").write_text('#!' + shell + '\nif [ "$#" -eq 1 ] && [ "$1" = --version ]; then\n'
                                      '  exec sleep 30\nfi\nexec ' + shlex.quote(jq) + ' "$@"\n')
        (directory / "jq").chmod(0o755)
        return directory

    def test_native_stage_decision_is_keyed_for_the_full_battery(self):
        # run-tests.sh skips the cargo stages when nothing since the resolved
        # base touches a native build input. Same tree, two bases: a verdict
        # from the skipping range must not satisfy the range that needs them.
        for name in ("core-rules/skills/process-gate/scripts/lib/diff-base.sh",):
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, self.root / name)
        (self.root / "core-rules/native").mkdir(parents=True, exist_ok=True)
        (self.root / "core-rules/native/artifacts.json").write_text('{"inputs": {"native/trellis-hooks/Cargo.lock": "x"}}\n')
        (self.root / "native/trellis-hooks").mkdir(parents=True, exist_ok=True)  # the fixture has Cargo.lock
        (self.root / "native/trellis-hooks/src.rs").write_text("// v1\n")
        self.commit()
        before_native = self.git("rev-parse", "HEAD").decode().strip()
        (self.root / "native/trellis-hooks/src.rs").write_text("// v2\n")
        self.commit()
        after_native = self.git("rev-parse", "HEAD").decode().strip()
        (self.root / "marker").write_text("native fixture\n")
        self.commit()
        with self.local_runner_gate() as (gate, runs):
            self.git("update-ref", "refs/remotes/origin/main", after_native)
            self.inputs = VERDICT.capture_inputs(self.root)
            self.keep()
            result = gate()
            self.assertIn("reused verdict " + self.id, result.stdout, result.stderr)
            self.assertEqual(runs(), 0)
            self.git("update-ref", "refs/remotes/origin/main", before_native)
            result = gate()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("reused verdict", result.stdout)
            self.assertEqual(runs(), 1)
            self.assertEqual((self.inputs.get("native"), VERDICT.capture_inputs(self.root).get("native")),
                             ("skip", "run"))

    def test_rustup_detection_timeout_costs_reuse_not_identity(self):
        # r151-reuse4 R3 (Sol extra-probes rustup-detection-timeout): a
        # hard-linked rustup-compatible proxy whose identity query outlives
        # the 2 s probe bound but dispatches promptly. "unavailable" is not
        # "not rustup": the compiler would go unbound and a switched
        # selection reused.
        fake = self.base / "slow-rustup"
        fake.mkdir()
        home = self.base / "slow-rustup-home"
        selection = self.base / "selection"
        selection.write_text("good")
        for toolchain in ("good", "bad"):
            for name in ("cargo", "rustc"):
                binary = home / "toolchains" / toolchain / "bin" / name
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_text("#!/bin/sh\necho '%s %s'\n" % (name, toolchain))
                binary.chmod(0o755)
        (fake / "proxy").write_text(
            '#!/bin/bash\nif [ "${RUSTUP_FORCE_ARG0:-}" = rustup ]; then\n  sleep 3\n  echo "rustup 1.28 fixture"\n'
            '  exit 0\nfi\ntc="$(cat %s)"\nexec %s/toolchains/"$tc"/bin/"${0##*/}" "$@"\n'
            % (shlex.quote(str(selection)), shlex.quote(str(home))))
        (fake / "proxy").chmod(0o755)
        for name in ("cargo", "rustc"):
            os.link(fake / "proxy", fake / name)
        # Without timing: each failed detection answer raises, scoped.
        for answer in ("unavailable: probe timeout", "unavailable: empty probe", ""):
            def failing(command, env, cwd, answer=answer):
                if env.get("RUSTUP_FORCE_ARG0") == "rustup":
                    return answer
                return "fixture 1"
            with self.subTest(answer=answer):
                self.tools.stop()
                try:
                    # Only the proxies are probed: the stub answers nothing else.
                    with mock.patch.dict(os.environ, {"PATH": str(fake) + os.pathsep + os.environ["PATH"]}), \
                            mock.patch.object(VERDICT, "TOOLS", ("cargo", "rustc")):
                        with self.assertRaises(VERDICT.ProbeUnavailable):
                            VERDICT.toolchain(self.root, failing)
                        with self.assertRaises(VERDICT.ProbeUnavailable) as raised:
                            VERDICT.capture_inputs(self.root, command=self.TEST_CMD, version_probe=failing)
                        self.assertEqual(raised.exception.scope["command"], self.TEST_CMD)
                finally:
                    self.tools.start()
        # A successful non-rustup answer is still "not rustup".
        def plain(command, env, cwd):
            return "rustc 1.99.1 (fixture)" if env.get("RUSTUP_FORCE_ARG0") == "rustup" else "fixture 1"
        self.tools.stop()
        try:
            with mock.patch.dict(os.environ, {"PATH": str(fake) + os.pathsep + os.environ["PATH"]}), \
                    mock.patch.object(VERDICT, "TOOLS", ("cargo", "rustc")):
                self.assertNotIn("effective", VERDICT.toolchain(self.root, plain)["rustc"])
        finally:
            self.tools.start()
        # End to end, with the real bounded probe timing out.
        self.start_project_gate()
        path = str(fake) + os.pathsep + self.project_path
        extra = {"RUSTUP_HOME": str(home), "WANT_RUSTC": "good"}
        first = self.run_project_gate(self.TEST_CMD, path=path, extra=extra)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        selection.write_text("bad")
        second = self.run_project_gate(self.TEST_CMD, path=path, extra=extra)
        self.assertNotIn("reused verdict", second.stdout)
        self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self.command_verdicts(), [])  # tracked, never published

    def test_rustup_detection_probes_use_the_callers_probe(self):
        # run-tests-local passes contained_probe; the rustup identity probes
        # (RUSTUP_FORCE_ARG0 --version, show active-toolchain, which) must go
        # through it like every --version probe, not around it.
        fake = self.base / "fake-rustup"
        fake.mkdir()
        rustup_home = self.base / "rustup-home"
        (rustup_home / "toolchains/stable-fixture/bin").mkdir(parents=True)
        for name in ("cargo", "rustc"):
            compiler = rustup_home / "toolchains/stable-fixture/bin" / name
            compiler.write_text("#!/bin/sh\nexit 0\n")
            compiler.chmod(0o755)
        (fake / "proxy").write_text(
            '#!/bin/sh\n[ "${RUSTUP_FORCE_ARG0:-}" = rustup ] || exit 1\ncase "$1" in\n'
            '  --version) echo "rustup 1.28.0 (fixture)" ;;\n  show) echo "stable-fixture (default)" ;;\n'
            '  which) echo "$RUSTUP_HOME/toolchains/stable-fixture/bin/$2" ;;\nesac\n')
        (fake / "proxy").chmod(0o755)
        for name in ("cargo", "rustc"):  # Hard links, as rustup installs its proxies.
            os.link(fake / "proxy", fake / name)
        seen = []

        def recording(command, env, cwd):
            seen.append((list(command[1:]), env.get("RUSTUP_FORCE_ARG0")))
            if Path(command[0]).parent == fake:
                return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True).stdout.strip()
            # Other tools keep real answers to dispatcher queries: a pyenv
            # shim's `pyenv which python` must name a real file.
            if list(command[1:]) == ["--version"] and env.get("RUSTUP_FORCE_ARG0") is None:
                return "fixture 1"
            return VERDICT.probe(command, env, cwd)

        self.tools.stop()
        try:
            with mock.patch.dict(os.environ, {"PATH": str(fake) + os.pathsep + os.environ["PATH"],
                                              "RUSTUP_HOME": str(rustup_home)}):
                tools = VERDICT.toolchain(self.root, recording)
        finally:
            self.tools.start()
        self.assertEqual(tools["cargo"]["effective"]["manager"], "rustup")
        self.assertEqual(tools["cargo"]["effective"]["active"], "stable-fixture (default)")
        for probe in (["--version"], ["show", "active-toolchain"], ["which", "cargo"]):
            self.assertIn((probe, "rustup"), seen)
        # Through the probe, a probe failure refuses the identity.
        self.tools.stop()
        try:
            with mock.patch.dict(os.environ, {"PATH": str(fake) + os.pathsep + os.environ["PATH"],
                                              "RUSTUP_HOME": str(rustup_home)}):
                def failing(command, env, cwd):
                    if command[1:] == ["which", "cargo"]:
                        return "unavailable: probe timeout"
                    return recording(command, env, cwd)
                with self.assertRaises(ValueError):
                    VERDICT.toolchain(self.root, failing)
        finally:
            self.tools.start()

    def test_slow_version_probe_costs_reuse_and_a_failure_still_supersedes(self):
        self.start_project_gate()
        first = self.run_project_gate(self.TEST_CMD)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(len(self.command_verdicts()), 1)
        slow = str(self.slow_probe_dir()) + os.pathsep + self.project_path
        for failing in (False, True):
            flag = self.base / "fail-flag"
            if failing:
                flag.write_text("")
            with self.subTest(failing=failing):
                result = self.run_project_gate(self.TEST_CMD, path=slow, extra={"FAIL_FLAG": str(flag)})
                self.assertNotIn("reused verdict", result.stdout)
                self.assertNotIn("not run", result.stdout)
                self.assertNotIn("verdict store", result.stdout)
                self.assertEqual(result.returncode, 1 if failing else 0, result.stdout + result.stderr)
                self.assertEqual(self.project_runs(), 2 + failing)
                # A pass without inputs publishes nothing and keeps the earlier
                # pass; a failure supersedes it although no inputs were captured.
                self.assertEqual(len(self.command_verdicts()), 0 if failing else 1)
                self.assertEqual(list((self.store / "inflight").glob("*.json")), [])
        # The core invariant: after that failure, a fast-probe lookup reruns.
        flag.unlink()
        result = self.run_project_gate(self.TEST_CMD, extra={"FAIL_FLAG": str(flag)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.project_runs(), 4)
        # Only a probe failure is tracked this way: a refused command (a
        # filter) never touches the store, failing or not, slow probe or not.
        before = sorted(str(path) for path in self.store.rglob("*"))
        flag.write_text("")
        refused = self.run_project_gate('node --test --test-name-pattern="fixture checks"', path=slow,
                                        extra={"FAIL_FLAG": str(flag)})
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertEqual(self.project_runs(), 5)
        self.assertEqual(sorted(str(path) for path in self.store.rglob("*")), before)

    def test_slow_version_probe_only_costs_reuse_for_the_local_runner(self):
        with self.local_runner_gate() as (gate, runs):
            self.inputs = VERDICT.capture_inputs(self.root)
            self.keep()
            self.assertIn("reused verdict " + self.id, gate().stdout)
            result = gate(self.slow_probe_dir())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("reused verdict", result.stdout)
            self.assertEqual(runs(), 1)

    def test_parallelism_only_variables_do_not_refuse_reuse(self):
        # The t45 qualification run exports CARGO_BUILD_JOBS=4 and
        # CARGO_NET_OFFLINE=true: build parallelism changes how fast, not what
        # runs, so it neither refuses nor splits verdicts; offline and the
        # test-thread counts are keyed. CARGO_HOME and every other Cargo
        # override still refuse.
        def captured(**env):
            with mock.patch.dict(os.environ, env):
                return VERDICT.safe_inputs(self.root)

        plain = captured()
        self.assertIsNotNone(plain)
        for jobs in ("1", "4", "default"):
            with self.subTest(jobs=jobs):
                self.assertEqual(captured(CARGO_BUILD_JOBS=jobs), plain)
        for name in ("RUST_TEST_THREADS", "NEXTEST_TEST_THREADS", "CARGO_NET_OFFLINE"):
            with self.subTest(keyed=name):
                one, four = (captured(**{name: "true"}), captured(**{name: "false"})) if name == "CARGO_NET_OFFLINE" \
                    else (captured(**{name: "1"}), captured(**{name: "4"}))
                self.assertIsNotNone(one)
                self.assertNotEqual(VERDICT.key(one), VERDICT.key(four))
                self.assertNotEqual(VERDICT.key(one), VERDICT.key(plain))
        for name, value in (("CARGO_HOME", str(self.base)), ("CARGO_BUILD_TARGET", "x86_64-unknown-linux-gnu"),
                            ("CARGO_BUILD_RUSTFLAGS", "--cfg x"), ("CARGO_ENCODED_RUSTFLAGS", "--cfg"),
                            ("CARGO_BUILD_RUSTC_WRAPPER", "/usr/bin/true"),
                            ("CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER", "/usr/bin/true"),
                            ("NEXTEST_PROFILE", "ci"), ("RUSTFLAGS", "--cfg x")):
            with self.subTest(refused=name):
                self.assertIsNone(captured(**{name: value}))
        # Real cargo: a pass under CARGO_BUILD_JOBS=4 is reused under 2 and unset.
        self.start_project_gate()
        rustup_home, _ = self.real_rust()
        self.commit_files({"Cargo.toml": '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\n',
                           "Cargo.lock": self.CARGO_LOCK, "src/lib.rs": "#[test]\nfn passes() {}\n"})
        home = self.base / "jobs-home"
        home.mkdir()
        extra = dict(self.cargo_extra(rustup_home), HOME=str(home))
        command = "cargo test --offline"
        extra["CARGO_NET_OFFLINE"] = "true"
        first = self.run_project_gate(command, extra=dict(extra, CARGO_BUILD_JOBS="4"))
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        [verdict] = self.command_verdicts()
        record = json.loads(verdict.read_text())
        for jobs in ({"CARGO_BUILD_JOBS": "2"}, {}):
            result = self.run_project_gate(command, extra=dict(extra, **jobs))
            self.assertIn("reused verdict " + record["id"], result.stdout, result.stderr)

    def test_ambient_exports_cannot_break_the_fixture(self):
        # A qualification shell exports Cargo and runner variables; the
        # fixture's own setUp capture must not inherit them.
        ambient = dict(os.environ, CARGO_HOME=str(self.base / "ambient-cargo"), CARGO_NET_OFFLINE="true",
                       PYTEST_ADDOPTS="-k nothing", NODE_OPTIONS="--require /nonexistent", BATS_TEST_FILTER="x",
                       PG_PUSH_TEST_SCOPE="full", RUSTUP_HOME=str(self.base / "ambient-rustup"),
                       RUSTUP_TOOLCHAIN="ambient")
        result = subprocess.run([sys.executable, "-I", str(Path(__file__).resolve()), "VerdictTests.test_mutation_tree",
                                 "VerdictTests.test_native_cargo_inputs_and_test_seams_bind_full_battery_reuse"],
                                env=ambient, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


for field in ("schema", "tree", "command", "runner", "env", "policy", "configs", "toolchain", "platform", "native"):
    setattr(VerdictTests, "test_mutation_" + field, lambda self, field=field: self.mutate(field))

if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
