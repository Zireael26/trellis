"""Release-metadata selection, base policy, and real file-open log parsing."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("verdict_fixture", HERE / "test_gate_verdict.py")
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
import release_metadata as META  # noqa: E402 (path set by the fixture import)

TRACE_SPEC = importlib.util.spec_from_file_location("metadata_trace", HERE.parent / "trace-release-metadata.py")
TRACE = importlib.util.module_from_spec(TRACE_SPEC)
TRACE_SPEC.loader.exec_module(TRACE)
MANIFEST = "scripts/tests/release-metadata-audit.json"


class MetadataTests(FIXTURE.VerdictTests):
    def setUp(self):
        super().setUp()
        shutil.copyfile(FIXTURE.ROOT / "scripts/lib/release_metadata.py", self.root / "scripts/lib/release_metadata.py")
        self.manifest = self.root / MANIFEST
        (self.root / "core-rules/VERSION").parent.mkdir(exist_ok=True)
        (self.root / "core-rules/VERSION").write_text("1.2.3\n")
        (self.root / "CHANGELOG.md").write_text("# Change log\n")
        (self.root / "docs/adr").mkdir(parents=True)
        (self.root / "docs/adr/0001-note.md").write_text("# Decision\n")
        policy = self.root / ".claude/skills/process-gate-local/docs-only-tests.policy"
        policy.parent.mkdir(parents=True)
        policy.write_text("class release-metadata " + MANIFEST + "\nallow ^docs/.*[.]md$\n")
        (self.root / "scripts/tests/sample.bats").write_text('#!/usr/bin/env bats\n@test "metadata" { printf "metadata\\n" >> "$CLASS_LOG"; }\n')
        (self.root / "scripts/tests/sample.bats").chmod(0o755)
        self.commit()
        self.audit = {"schema": 1, "complete": True, "suites": ["scripts/tests/sample.bats"],
                      "source_digest": META.source_digest(self.root, "HEAD", MANIFEST)}
        self.manifest.write_text(json.dumps(self.audit))
        self.commit()
        self.seed_base()

    def seed_base(self):
        self.base_head = self.git("rev-parse", "HEAD").decode().strip()
        self.inputs = FIXTURE.VERDICT.capture_inputs(self.root)
        self.keep()

    def candidate(self, version="1.2.4\n"):
        (self.root / "core-rules/VERSION").write_text(version)
        self.commit()
        return self.git("rev-parse", "HEAD").decode().strip()

    def evaluate(self, head):
        return META.evaluate(self.root, self.base_head, head, MANIFEST)

    def test_complete_audit_and_green_base_narrow_exact_metadata(self):
        (self.root / "CHANGELOG.md").write_text("# New release\n")
        (self.root / "docs/adr/0001-note.md").write_text("# Revised decision\n")
        head = self.candidate()
        self.assertEqual(self.evaluate(head), (3, "bats scripts/tests/sample.bats"))

    def test_no_green_base_never_narrows(self):
        head = self.candidate()
        shutil.rmtree(self.state / "verdicts")
        with self.assertRaises((OSError, ValueError)):
            self.evaluate(head)

    def test_incomplete_or_stale_audit_never_narrows(self):
        start = self.base_head
        for mode in ("incomplete", "stale"):
            self.git("reset", "--hard", start)
            if mode == "incomplete":
                self.manifest.write_text(json.dumps(self.audit | {"complete": False}))
            else:
                (self.root / "marker").write_text("source changed\n")
            self.commit()
            self.seed_base()
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "incomplete or stale"):
                self.evaluate(self.candidate())

    def test_bad_version_mixed_mode_and_hidden_revert_never_narrow(self):
        start = self.base_head
        for mode in ("version", "mixed", "mode", "hidden", "deleted"):
            self.git("reset", "--hard", start)
            self.base_head = start
            if mode == "mixed":
                (self.root / "marker").write_text("behaviour\n")
            if mode == "mode":
                (self.root / "core-rules/VERSION").chmod(0o755)
            head = self.candidate("not-semver\n" if mode in ("version", "hidden") else "1.2.4\n")
            if mode == "hidden":
                head = self.candidate("1.2.3\n")
            if mode == "deleted":
                (self.root / "core-rules/VERSION").unlink()
                self.commit()
                head = self.git("rev-parse", "HEAD").decode().strip()
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.evaluate(head)

    def test_changed_tag_or_other_ref_invalidates_base(self):
        head = self.candidate()
        self.git("tag", "v1.2.4")
        with self.assertRaisesRegex(ValueError, "no matching"):
            self.evaluate(head)

    def test_file_open_parser_excludes_writes_and_keeps_metadata_and_tags(self):
        raw = b'''10 openat(AT_FDCWD</src>, "CHANGELOG.md", O_RDONLY) = 3
11 openat(AT_FDCWD</src>, "core-rules/VERSION", O_RDONLY) = 3
12 openat(AT_FDCWD</src>, "docs/adr/note.md", O_RDWR) = 3
13 openat(AT_FDCWD</tmp>, "/tmp/fixture/VERSION", O_WRONLY|O_CREAT) = 3
14 openat(AT_FDCWD</src>, ".git/packed-refs", O_RDONLY) = 3
15 openat(AT_FDCWD</src>, "scripts/tool.sh", O_RDONLY) = 3
'''
        result = TRACE.observations(raw)
        self.assertEqual(result["metadata"], ["CHANGELOG.md", "core-rules/VERSION", "docs/adr/note.md"])
        self.assertTrue(result["tag_reads"])
        self.assertEqual(result["trace_sha256"], FIXTURE.VERDICT.digest(raw))

    def test_base_side_class_runs_audited_tests_not_full_command(self):
        self.run_class_case("metadata")

    def test_head_helper_cannot_self_certify_its_mixed_range(self):
        self.run_class_case("mixed-head")

    def test_bash_floor_rejects_mixed_range_even_if_base_helper_is_buggy(self):
        self.run_class_case("permissive-base")

    def test_dirty_head_helper_cannot_replace_the_base_helper(self):
        self.run_class_case("dirty-head")

    def test_bash_floor_rejects_merge_only_changes_with_permissive_helper(self):
        self.run_class_case("merge")

    def merge_candidate(self):
        branch = self.git("symbolic-ref", "--short", "HEAD").decode().strip()
        self.git("checkout", "-qb", "metadata-side")
        (self.root / "CHANGELOG.md").write_text("side metadata\n")
        self.commit()
        self.git("checkout", "-q", branch)
        self.candidate()
        self.git("merge", "--no-ff", "--no-commit", "metadata-side")
        (self.root / "marker").write_text("merge-only behaviour\n")
        self.commit()
        self.git("branch", "-D", "metadata-side")
        head = self.git("rev-parse", "HEAD").decode().strip()
        self.assertEqual(len(self.git("rev-list", "--parents", "-n", "1", head).split()), 3)
        self.assertEqual(self.git("diff-tree", "-r", "--name-only", "--no-commit-id", head), b"")
        self.assertIn(b"marker", self.git("diff", "--name-only", head + "^1", head).splitlines())
        return head

    def run_class_case(self, case):
        helper = self.root / "scripts/lib/release_metadata.py"
        if case in ("permissive-base", "merge"):
            source = helper.read_text()
            if case == "merge":
                source = source.replace('count = changed_metadata(root, base, head)', 'count = 1')
            else:
                source = source.replace('raise ValueError("non-metadata path, change type, or mode")', 'continue')
            helper.write_text(source)
            self.commit()
            self.manifest.write_text(json.dumps(self.audit | {"source_digest": META.source_digest(self.root, "HEAD", MANIFEST)}))
            self.commit()
        log = self.base / "class.log"
        self.tools.stop()
        try:
            with mock.patch.dict(os.environ, {"PATH": self.versioned_path(), "PWD": str(self.root), "OLDPWD": str(self.root),
                    "CODEX_PROJECT_DIR": str(self.root), "CLAUDE_PROJECT_DIR": str(self.root), "CLASS_LOG": str(log),
                    "PROCESS_GATE_TYPECHECK_CMD": "true", "PROCESS_GATE_LINT_CMD": "true",
                    "PROCESS_GATE_TEST_CMD": 'printf "full\\n" >> "$CLASS_LOG"',
                    "PROCESS_GATE_HEAVY_LAUNCHER": "/missing/launcher"}):
                self.clear_hook_git_env()
                self.seed_base()
                if case in ("mixed-head", "permissive-base"):
                    (self.root / "marker").write_text("behaviour change\n")
                if case == "mixed-head":
                    helper.write_text(helper.read_text().replace('raise ValueError("non-metadata path, change type, or mode")', 'continue'))
                head = self.merge_candidate() if case == "merge" else self.candidate()
                if case == "dirty-head":
                    helper.write_text('print("1\\tbats scripts/tests/sample.bats")\n')
                command = ["bash", str(FIXTURE.ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"),
                           "--range=" + self.base_head + ".." + head]
                result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if case == "metadata":
                    self.assertIn("Tests: narrowed (release-metadata: 1 files)", result.stdout)
                    self.assertEqual(log.read_text(), "metadata\n")
                else:
                    self.assertNotIn("Tests: narrowed", result.stdout)
                    self.assertEqual(log.read_text(), "full\n")
        finally:
            self.tools.start()


if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
