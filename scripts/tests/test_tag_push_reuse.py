"""T31 real hook/Tests chain with runner-written sandbox verdicts, never a battery."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tag_verdict_fixture", HERE / "test_gate_verdict.py")
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
import release_metadata as META

ROOT = FIXTURE.ROOT
MANIFEST = "scripts/tests/release-metadata-audit.json"
ZERO = "0" * 40


class TagReuseTests(FIXTURE.VerdictTests):
    def setUp(self):
        super().setUp()
        self.log = self.base / "checks.log"
        self.skill = self.root / "core-rules/skills/process-gate"
        scripts = self.skill / "scripts"
        (scripts / "lib").mkdir(parents=True)
        source = ROOT / "core-rules/skills/process-gate/scripts"
        for name in ("run-all.sh", "check-tests.sh", "lib/common.sh", "lib/diff-base.sh", "lib/validator-env.sh"):
            shutil.copyfile(source / name, scripts / name)
        for name in ("pr", "secrets", "bypass", "docs", "security-diff", "analyze", "slop"):
            (scripts / ("check-" + name + ".sh")).write_text('echo "info fixture"\n')
        for name in ("tag_push_reuse.py", "release_metadata.py"):
            shutil.copyfile(ROOT / "scripts/lib" / name, self.root / "scripts/lib" / name)
        shutil.copyfile(ROOT / "scripts/release-payload-commit.sh", self.root / "scripts/release-payload-commit.sh")
        (self.root / "core-rules/VERSION").write_text("1.4.0\n")
        (self.root / "core-rules/payload-exclude.txt").write_text("instance-only/\n")
        (self.root / "instance-only").mkdir()
        (self.root / "instance-only/private.txt").write_text("excluded fixture\n")
        self.suite = "scripts/tests/sample.bats"
        (self.root / self.suite).write_text('''#!/usr/bin/env bats
@test "reads the actual release tag" {
  run git cat-file -t "$TEST_RELEASE_REF"
  [ "$status" -eq 0 ]
  [ "$output" = tag ]
  printf 'tag\n' >> "$CHECK_LOG"
  [ "${TEST_TAG_FAIL:-0}" -eq 0 ]
}
''')
        (self.root / self.suite).chmod(0o755)
        self.commit()
        self.audit = {"schema": 1, "complete": True, "suites": [self.suite],
                      "source_digest": META.source_digest(self.root, "HEAD", MANIFEST),
                      "observations": {self.suite: {"metadata": [], "tag_reads": True, "trace_sha256": "a" * 64}}}
        (self.root / MANIFEST).write_text(json.dumps(self.audit))
        self.commit()
        self.tag = "refs/tags/v1.4.0"

    @contextlib.contextmanager
    def environment(self, **extra):
        directory = self.base / "bin"
        directory.mkdir()
        shim = directory / "python3"
        # bash 3.2 (macOS /bin/bash) drops an inherited OLDPWD; keep it, as check-tests.sh's cd exported it.
        shim.write_text('#!/bin/bash\nexport OLDPWD="${OLDPWD:-$PWD}"\nif [ "${1:-}" = scripts/run-tests-local.py ]; then\n'
                        '  printf "full\\n" >> "$CHECK_LOG"; exit 0\nfi\nexec "$REAL_PYTHON" "$@"\n')
        shim.chmod(0o755)
        self.tools.stop()
        try:
            # Outer Bats prepends its internal libexec driver, which is not a
            # standalone entrypoint. Resolve tools through the public frontend.
            clean_path = os.pathsep.join(part for part in os.environ["PATH"].split(os.pathsep)
                                         if part != os.environ.get("BATS_LIBEXEC"))
            with mock.patch.dict(os.environ, {"PATH": clean_path}):
                tools_path = self.versioned_path()
            env = {"PATH": str(directory) + os.pathsep + tools_path,
                   "PWD": str(self.root), "OLDPWD": str(self.root), "PG_MODE": "push",
                   "CODEX_PROJECT_DIR": str(self.root), "CLAUDE_PROJECT_DIR": str(self.root),
                   "CHECK_LOG": str(self.log), "REAL_PYTHON": sys.executable,
                   "HUSKY": "0", "pnpm_config_verify_deps_before_run": "error",
                   "PROCESS_GATE_TYPECHECK_CMD": 'printf "typecheck\\n" >> "$CHECK_LOG"',
                   "PROCESS_GATE_LINT_CMD": 'printf "lint\\n" >> "$CHECK_LOG"',
                   "PROCESS_GATE_COVERAGE_CMD": 'printf "coverage\\n" >> "$CHECK_LOG"',
                   "PROCESS_GATE_TEST_CMD": "python3 scripts/run-tests-local.py",
                   "PROCESS_GATE_STACK_PROFILE": "n-a", "PROCESS_GATE_HEAVY_LAUNCHER": "/missing/launcher",
                   "TEST_RELEASE_REF": self.tag}
            with mock.patch.dict(os.environ, env | extra):
                # Match check-tests' repository-routing cleanup and its cd to
                # the project root (which sets OLDPWD even when already there).
                # The parent patch restores the outer fixture.
                for name in list(os.environ):
                    if ((name.startswith("GIT_") and name != "GIT_OPTIONAL_LOCKS")
                            or name.startswith(("BASH_FUNC_", "BATS_"))):
                        del os.environ[name]
                yield
        finally:
            self.tools.start()

    def seed_release(self):
        self.release = self.git("rev-parse", "HEAD").decode().strip()
        self.git("update-ref", "refs/remotes/origin/main", self.release)
        self.inputs = FIXTURE.VERDICT.capture_inputs(self.root)
        self.keep()  # The real runner writer, retained aggregate and T30 reader.
        payload = subprocess.check_output(["bash", str(ROOT / "scripts/release-payload-commit.sh"), self.release],
                                         cwd=self.root, text=True).strip()
        self.git("tag", "-a", self.tag[10:], payload, "-m", "fixture release")
        self.object = self.git("rev-parse", self.tag).decode().strip()
        self.range = self.release + ".." + self.object

    def row(self, *, identity=True, push_scope=None):
        args = ["bash", "-p", str(self.skill / "scripts/check-tests.sh"), "--mode=push", "--tag-push",
                "--range=" + self.range]
        if identity:
            args.append("--release-tag=" + self.tag + ":" + self.object)
        env = dict(os.environ)
        if push_scope is not None:
            env["PG_PUSH_TEST_SCOPE"] = push_scope
        return subprocess.run(args, cwd=self.root, env=env, text=True, capture_output=True, timeout=45)

    def assert_full(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("reused verdict", result.stdout)
        self.assertEqual(self.log.read_text().splitlines(), ["typecheck", "lint", "full", "coverage"])

    def test_exact_tree_hit_reuses_runner_verdict_and_runs_tag_suite(self):
        with self.environment():
            self.seed_release()
            result = self.row()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("reused verdict " + self.id, result.stdout)
            self.assertIn(self.inputs["tree"], result.stdout)
            self.assertIn("tag-reading suites executed", result.stdout)
            self.assertEqual(self.log.read_text().splitlines(), ["typecheck", "lint", "tag", "coverage"])

    def test_one_byte_tree_change_runs_full(self):
        with self.environment():
            self.seed_release()
            marker = self.root / "marker"
            marker.write_bytes(marker.read_bytes() + b"x")
            self.commit()
            self.assert_full(self.row())

    def test_forged_or_edited_verdict_runs_full(self):
        with self.environment():
            self.seed_release()
            original = self.path.read_bytes()
            for field, value in (("status", "fail"), ("aggregate_sha256", "f" * 64), ("id", "f" * 32)):
                record = json.loads(original)
                record[field] = value
                FIXTURE.GATE.save_record(self.path, record)
                self.log.unlink(missing_ok=True)
                with self.subTest(field=field):
                    self.assert_full(self.row())
            self.path.write_bytes(original)
            self.path.chmod(0o600)
            kept = self.state / "passing-runs" / self.id / "aggregate.tsv"
            kept.write_bytes(kept.read_bytes().replace(b"\t0\n", b"\t1\n"))
            self.log.unlink()
            self.assert_full(self.row())

    def test_missing_incomplete_or_stale_t32_trace_runs_full(self):
        start = self.git("rev-parse", "HEAD").decode().strip()
        with self.environment():
            for mode in ("missing", "incomplete", "stale"):
                self.git("reset", "--hard", start)
                self.git("tag", "-d", self.tag[10:]) if mode != "missing" else None
                manifest = self.root / MANIFEST
                if mode == "missing":
                    manifest.unlink()
                else:
                    manifest.write_text(json.dumps(self.audit | ({"complete": False} if mode == "incomplete" else {"source_digest": "b" * 64})))
                self.commit()
                self.seed_release()
                self.log.unlink(missing_ok=True)
                with self.subTest(mode=mode):
                    self.assert_full(self.row())

    def test_tag_reading_suite_failure_blocks_instead_of_reusing_to_green(self):
        with self.environment(TEST_TAG_FAIL="1"):
            self.seed_release()
            result = self.row()
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("exited 1", result.stdout)
            self.assertEqual(self.log.read_text().splitlines(), ["typecheck", "lint", "tag", "coverage"])

    def test_verify_tag_failure_runs_full(self):
        self.tag = "refs/tags/v1.4.1"  # Annotated, but not the payload's VERSION.
        with self.environment():
            self.seed_release()
            result = self.row()
            self.assert_full(result)

    def test_ref_changes_stale_or_ambiguous_verdicts_run_full(self):
        with self.environment():
            self.seed_release()
            self.git("branch", "unrelated", "HEAD")
            self.assert_full(self.row())
            self.git("branch", "-D", "unrelated")
            self.log.unlink()
            original = self.path.read_bytes()
            metadata = self.state / "passing-runs" / self.id / "run.json"
            original_metadata = metadata.read_bytes()
            record = json.loads(original)
            run = json.loads(original_metadata)
            record["completed_at"] = run["completed_at"] = time.time() - 8 * 86400
            FIXTURE.GATE.save_record(self.path, record)
            FIXTURE.GATE.save_record(metadata, run)
            self.assert_full(self.row())
            self.path.write_bytes(original)
            metadata.write_bytes(original_metadata)
            self.log.unlink()
            self.inputs = FIXTURE.VERDICT.capture_inputs(self.root)
            self.id = "b" * 32
            self.keep()  # Both before-tag and after-tag candidates now validate.
            self.assert_full(self.row())

    def test_tag_push_without_verified_identity_cannot_use_ordinary_t30_reuse(self):
        with self.environment():
            self.seed_release()
            # Even a full verdict captured after tag creation is not sufficient
            # when the hook could not verify/classify this tag push.
            self.git("checkout", "--detach", self.tag + "^{commit}")
            self.inputs = FIXTURE.VERDICT.capture_inputs(self.root)
            self.keep()
            self.assert_full(self.row(identity=False))

    def test_tag_identity_beats_branch_selector_scope_and_never_narrows(self):
        mapper = self.root / "scripts/lib/push-test-map.py"
        mapper.write_text('print("Tests: narrowed\\nscripts/tests/sample.bats")\n')
        config = self.root / ".claude/skills/process-gate-local/local.config.sh"
        config.parent.mkdir(parents=True)
        config.write_text('PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"\n')
        self.commit()
        self.audit["source_digest"] = META.source_digest(self.root, "HEAD", MANIFEST)
        (self.root / MANIFEST).write_text(json.dumps(self.audit))
        self.commit()
        with self.environment():
            self.seed_release()
            result = self.row(push_scope="branch")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("reused verdict " + self.id, result.stdout)
            self.assertIn("Tests: full", result.stdout)
            self.assertNotIn("Tests: narrowed", result.stdout)
            self.assertEqual(self.log.read_text().splitlines(), ["typecheck", "lint", "tag", "coverage"])
            self.log.unlink()
            self.git("checkout", "--detach", self.tag + "^{commit}")
            self.assert_full(self.row(identity=False, push_scope="branch"))

    def test_both_hooks_forward_only_verified_single_tag_and_render_receipt(self):
        with self.environment():
            self.seed_release()
            for hook in ("githooks", "husky"):
                self.log.unlink(missing_ok=True)
                result = subprocess.run(["sh", str(ROOT / "core-rules" / hook / "pre-push"), "origin"],
                    input=f"{self.tag} {self.object} {self.tag} {ZERO}\n", cwd=self.root,
                    text=True, capture_output=True, timeout=60)
                with self.subTest(hook=hook):
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("release-payload-commit: tag v1.4.0 verified", result.stdout)
                    self.assertIn("reused verdict " + self.id, result.stdout)
                    self.assertIn("tag-reading suites executed", result.stdout)
                    self.assertEqual(self.log.read_text().splitlines(), ["typecheck", "lint", "tag", "coverage"])


if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
