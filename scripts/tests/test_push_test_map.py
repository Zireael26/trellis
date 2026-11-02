"""Diff mapper and gate wiring contracts; all Git writes stay in a private HOME."""
import os
from pathlib import Path
import re
from runpy import run_path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAPPER = ROOT / "scripts/lib/push-test-map.py"
CORE = {"scripts/tests/" + name + ".bats" for name in (
    "posix-bootstrap-prologue", "suite-coverage", "push-test-map", "release-tag-consumers",
    "check-process-liveness", "test-fencing", "release-payload-commit", "live-model-roster",
    "gpt6-roster-sweep", "diff-base-sync", "no-legacy-herdr")}
TARGET = "scripts/tests/check-decisions-log.bats"
SOURCE = "scripts/check-decisions-log.sh"
DOCS = {"scripts/tests/gpt6-roster-sweep.bats"}
# Test command under the gate-range receipt contract: count --test-file= selections and
# write exactly one PG_TESTS_RECEIPT line to the private receipt file when one is given.
RECORD_SH = (
    'printf "%s\\n" "$@" > invoked\n'
    'printf "%s\\n" "${PG_PUSH_TEST_SCOPE-unset}" > push-scope\n'
    'if [ "${RECORD_BODY+x}" = x ]; then eval "$RECORD_BODY"; exit; fi\n'
    'count=0\n'
    'for arg in "$@"; do case "$arg" in --test-file=*) count=$((count + 1)) ;; esac; done\n'
    'if [ -n "${PG_TESTS_RECEIPT_FILE:-}" ]; then\n'
    '  if [ "$count" -gt 0 ]; then echo "PG_TESTS_RECEIPT narrowed $count"; '
    'else echo "PG_TESTS_RECEIPT full"; fi > "$PG_TESTS_RECEIPT_FILE"\n'
    'fi\n'
)


class PushTestMapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="push-test-map-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        home = self.root / "home"
        home.mkdir()
        tmp = self.root / "tmp"
        tmp.mkdir()
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(("GIT_", "PG_", "PROCESS_GATE_", "TRELLIS_")) or \
                    key in {"CLAUDE_PROJECT_DIR", "CODEX_PROJECT_DIR"}:
                del self.env[key]
        self.env.update(HOME=str(home), TRELLIS_HOME=str(home / ".trellis"),
                        PI_CODING_AGENT_DIR=str(home / ".pi"), TMPDIR=str(tmp),
                        XDG_CONFIG_HOME=str(home / ".config"), XDG_CACHE_HOME=str(home / ".cache"),
                        XDG_DATA_HOME=str(home / ".local" / "share"),
                        XDG_STATE_HOME=str(home / ".local" / "state"),
                        TRELLIS_ATTACH_POSTJOB="off", GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, PYTHONDONTWRITEBYTECODE="1",
                        PROCESS_GATE_HEAVY_LAUNCHER="/nonexistent")
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@trellis.invalid")
        for path in CORE | DOCS | {TARGET, SOURCE}:
            self.put(path, "# fixture\n")
        self.base = self.commit()

    def run_cmd(self, *args, check=True):
        return subprocess.run(args, cwd=self.repo, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

    def git(self, *args):
        return self.run_cmd("git", *args).stdout.strip()

    def put(self, path, text):
        dest = self.repo / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def select(self, paths):
        for path in paths:
            self.put(path, "# changed\n")
        head = self.commit()
        return self.run_cmd("python3", "-I", str(MAPPER), self.base + ".." + head, check=False)

    def test_mapped_source_runs_coverage_and_core_sorted(self):
        result = self.select([SOURCE])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [f"Tests: narrowed (1 files -> {len(CORE) + 1} test files)"] + sorted(CORE | {TARGET}))

    def test_leaf_sync_probe_keeps_recursive_scanner(self):
        self.put(SOURCE, (ROOT / SOURCE).read_text() + "\ndb_sync\n")
        result = self.run_cmd("python3", str(MAPPER), self.base + ".." + self.commit(), check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("scripts/tests/diff-base-sync.bats", result.stdout.splitlines(), result.stdout)

    def test_mapped_source_with_required_changelog_still_narrows(self):
        result = self.select([SOURCE, "CHANGELOG.md"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[1:], sorted(CORE | DOCS | {TARGET}))

    def test_test_only_diff_is_deduplicated_and_deterministic(self):
        result = self.select([TARGET, SOURCE])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], f"Tests: narrowed (2 files -> {len(CORE) + 1} test files)")
        self.assertEqual(result.stdout.splitlines()[1:], sorted(CORE | {TARGET}))

    def test_repository_scanners_are_core_or_reviewed_exemptions(self):
        exemptions = {
            "trellis-latency-bench": "ROOT is scratch output; SOURCE_ROOT/specs changes force full",
            "hook-inventory": "only core-rules hooks; those paths force full tests",
            "local-registry": "point lookup of registry.md and blacklist.md only",
            "ruff-rule-pin": "only aeo-gate subtree; those paths force full tests",
            "managed-dispatcher-env": "find reads a fixture scratch directory",
            "recover-orphan-journal": "find reads a fixture backup directory",
            "run-tests-local": "suite glob is in a generated fixture runner",
            "pi-guide-parity": "recursive greps cover docs, core-rules/pi and foreman; those paths force full tests",
        }
        scanners = set()
        for suite in (ROOT / "scripts/tests").glob("*.bats"):
            text = suite.read_text().replace("\\\n", " ")
            if (re.search(r'\bgrep\s+-[A-Za-z]*[rR]', text) and
                re.search(r'(?m)^(?![^\n]*(?:\bcd\s+|-C\s+))[^#=\n]*\s"\$\{?(?:ROOT|REPO_ROOT)\}?"(?=\s|[;)]|$)', text)):
                scanners.add(suite.stem)
            for line in text.splitlines():
                if line.lstrip().startswith("#"):
                    continue
                if (re.search(r'\$\{?(?:REPO_ROOT|ROOT)\b', line) and
                    re.search(r"\bgit\b.*\b(?:ls-files|grep)\b|\bfind\s+[\"']?\$\{?(?:REPO_ROOT|ROOT)\b", line) or
                        "scripts/tests/*.bats" in line):
                    scanners.add(suite.stem)
        core = {Path(path).stem for path in run_path(str(MAPPER))["CORE"]}
        self.assertEqual(core, {Path(path).stem for path in CORE})
        self.assertFalse(scanners - core - exemptions.keys(),
                         f"repository scanners missing from CORE: {sorted(scanners - core - exemptions.keys())}")

    def test_changed_bats_keeps_repository_scanners(self):
        path = "scripts/tests/pre-push-range.bats"
        self.put(path, (ROOT / path).read_text())
        self.base = self.commit()
        self.put(path, (ROOT / path).read_text() + "# refs/" + "tags/review-repro\n")
        result = self.run_cmd("python3", str(MAPPER), self.base + ".." + self.commit(), check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(CORE <= set(result.stdout.splitlines()[1:]), result.stdout)

    def test_unknown_shared_and_launcher_paths_fall_back(self):
        for path in ("unknown.txt", "scripts/lib/common.sh", "core-rules/hooks/guard.sh",
                     "scripts/trellis-launcher.sh", "scripts/run-tests.sh",
                     "core-rules/skills/orchestrate/recipes/template.wf.js"):
            with self.subTest(path=path):
                self.base = self.git("rev-parse", "HEAD")
                result = self.select([path])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("full tests", result.stderr)

    def test_unknown_intermediate_change_cannot_be_hidden_by_revert(self):
        self.put("unknown.txt", "new\n")
        self.commit()
        self.git("rm", "unknown.txt")
        result = self.select([SOURCE])
        self.assertNotEqual(result.returncode, 0)

    def test_missing_core_empty_and_invalid_ranges_fall_back(self):
        for range_spec in (self.base + ".." + self.base, "missing..HEAD"):
            self.assertNotEqual(self.run_cmd("python3", str(MAPPER), range_spec, check=False).returncode, 0)
        self.git("rm", "scripts/tests/suite-coverage.bats")
        self.assertNotEqual(self.select([SOURCE]).returncode, 0)

    def test_rename_from_unmapped_path_and_deleted_test_fall_back(self):
        self.put("unknown.sh", "# old\n")
        self.base = self.commit()
        self.git("rm", SOURCE)
        self.git("mv", "unknown.sh", SOURCE)
        self.assertNotEqual(self.select([SOURCE]).returncode, 0)
        self.base = self.git("rev-parse", "HEAD")
        self.git("rm", TARGET)
        self.assertNotEqual(self.select([SOURCE]).returncode, 0)

    def test_merge_nonancestor_and_symlink_test_ranges_fall_back(self):
        self.git("checkout", "-qb", "other")
        self.put(TARGET, "# other\n")
        other = self.commit()
        self.git("checkout", "-qb", "feature", self.base)
        self.put(SOURCE, "# feature\n")
        feature = self.commit()
        self.assertNotEqual(self.run_cmd("python3", str(MAPPER), other + ".." + feature, check=False).returncode, 0)
        self.git("merge", "--no-ff", "-qm", "merge", "other")
        self.assertNotEqual(self.run_cmd("python3", str(MAPPER), self.base + "..HEAD", check=False).returncode, 0)
        self.base = self.git("rev-parse", "HEAD")
        (self.repo / TARGET).unlink()
        (self.repo / TARGET).symlink_to("suite-coverage.bats")
        self.assertNotEqual(self.select([SOURCE]).returncode, 0)

    def test_source_load_closure_includes_unlisted_transitive_consumers(self):
        consumer = "scripts/tests/dependency-consumer.bats"
        helper = "scripts/tests/helpers/outer.bash"
        self.put(consumer, "load helpers/outer\n")
        self.put(helper, '# shellcheck source=../../../scripts/check-decisions-log.sh\n'
                         '. "$computed_source"\n')
        self.base = self.commit()
        result = self.select([SOURCE])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(consumer, result.stdout.splitlines()[1:])

    def test_dependency_reaching_core_suites_falls_back_to_full(self):
        self.put("core-rules/hooks/tests/consumer.bats", '. "$ROOT/scripts/check-decisions-log.sh"\n')
        self.base = self.commit()
        result = self.select([SOURCE])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("core suite", result.stderr)

    def test_removed_load_edge_is_still_covered_from_base(self):
        consumer = "scripts/tests/dependency-consumer.bats"
        helper = "scripts/tests/helpers/outer.bash"
        parent = "scripts/tests/dependency-parent.bats"
        self.put(parent, "load dependency-consumer.bats\n")
        self.put(consumer, "load helpers/outer\n")
        self.put(helper, "# helper\n")
        self.base = self.commit()
        self.put(consumer, "# dependency removed\n")
        result = self.select([helper])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(parent, result.stdout.splitlines()[1:])

    def dependency_run(self, kind):
        """Omit the real consumer from LEAVES; a missed edge would go green."""
        consumer = "scripts/tests/dependency-consumer.bats"
        helper = "scripts/tests/helpers/hidden.bash"
        fixture = "scripts/tests/fixtures/hidden.txt"
        if kind == "source":
            dependency = "scripts/lib/hidden.sh"
            self.put(consumer, '. scripts/lib/hidden.sh\n')
            self.put(dependency, 'return 0\n')
            broken = 'return 9\n'
        elif kind == "helper":
            dependency = helper
            self.put(consumer, 'load() { . "scripts/tests/$1.bash"; }; load helpers/hidden\n')
            self.put(dependency, 'return 0\n')
            broken = 'return 9\n'
        else:
            dependency = fixture
            self.put(consumer, '[ "$(cat scripts/tests/fixtures/hidden.txt)" = good ]\n')
            self.put(dependency, 'good\n')
            broken = 'broken\n'
        self.put("scripts/lib/push-test-map.py", MAPPER.read_text())
        # This command executes the real dependency assertion, not a fabricated
        # receipt. No matching --test-file argument would wrongly skip it.
        self.put("record.sh", 'selected=0\nfor arg in "$@"; do\n'
                 '  [ "$arg" != "--test-file=' + consumer + '" ] || selected=1\ndone\n'
                 'if [ "$#" -eq 0 ] || [ "$selected" -eq 1 ]; then\n'
                 '  bash ' + consumer + ' || exit $?\nfi\n' + RECORD_SH)
        self.put(".claude/skills/process-gate-local/local.config.sh",
                 'PROCESS_GATE_TYPECHECK_CMD=:\nPROCESS_GATE_LINT_CMD=:\n'
                 'PROCESS_GATE_TEST_CMD="bash record.sh"\n'
                 'PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"\n')
        self.base = self.commit()
        self.env.update(PG_PUSH_TEST_SCOPE="branch", CLAUDE_PROJECT_DIR=str(self.repo))
        control = self.run_gate(self.base)
        self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
        (self.repo / "invoked").unlink()
        (self.repo / "push-scope").unlink()
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.put(dependency, broken)
        head = self.commit()
        result = self.run_gate(head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("exited", result.stdout)

    def test_runner_injected_fence_dependency_always_requires_full(self):
        fence = "scripts/tests/helpers/git-fence/git"
        self.put(fence, "# injected into every test by runner\n")
        self.put("scripts/tests/fence-consumer.bats", 'bash "$ROOT/' + fence + '"\n')
        self.base = self.commit()
        result = self.select([fence])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("test fence", result.stderr)

    def test_hidden_sourced_dependency_fails_instead_of_skipping_green(self):
        self.dependency_run("source")

    def test_hidden_helper_dependency_fails_instead_of_skipping_green(self):
        self.dependency_run("helper")

    def test_hidden_fixture_dependency_fails_instead_of_skipping_green(self):
        self.dependency_run("fixture")

    def test_selected_stage_plan_excludes_unrelated_suites(self):
        args = ["bash", str(ROOT / "scripts/run-tests.sh"), "--list"]
        result = self.run_cmd(*args, "--test-file=" + TARGET, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bats " + TARGET, result.stdout)
        self.assertIn("conformance-check", result.stdout)
        self.assertIn("recipe routing lint", result.stdout)
        self.assertNotIn("hooks (claude + codex)", result.stdout)
        self.assertNotIn("bats scripts/tests/release-store.bats", result.stdout)

    def prepare_gate(self):
        self.put("scripts/lib/push-test-map.py", MAPPER.read_text())
        self.put("record.sh", RECORD_SH)
        self.put(".claude/skills/process-gate-local/local.config.sh",
                 'PROCESS_GATE_TYPECHECK_CMD=":"\nPROCESS_GATE_LINT_CMD=":"\n'
                 'PROCESS_GATE_TEST_CMD="bash record.sh"\n'
                 'PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"\n')
        self.base = self.commit()
        self.put(SOURCE, "# changed\n")
        head = self.commit()
        self.env.update(PG_PUSH_TEST_SCOPE="branch", CLAUDE_PROJECT_DIR=str(self.repo))
        return head

    def run_gate(self, head):
        return self.run_cmd("bash", str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"),
                            "--mode=push", "--range=" + self.base + ".." + head, check=False)

    def assert_full_gate(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Tests: full", result.stdout)
        self.assertNotIn("--test-file=", (self.repo / "invoked").read_text())

    def test_push_scope_is_private_to_gate(self):
        head = self.prepare_gate()
        for scope in ("branch", "full"):
            with self.subTest(scope=scope):
                self.env["PG_PUSH_TEST_SCOPE"] = scope
                result = self.run_gate(head)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.repo / "push-scope").read_text(), "unset\n")

    def test_different_checked_out_head_falls_back_to_full(self):
        head = self.prepare_gate()
        self.git("checkout", "--detach", self.base)
        result = self.run_gate(head)
        self.assert_full_gate(result)
        self.assertIn("full tests — HEAD differs from pushed range head", result.stderr)

    def test_dirty_tracked_tree_falls_back_to_full(self):
        head = self.prepare_gate()
        for staged in (False, True):
            with self.subTest(staged=staged):
                self.put("record.sh", RECORD_SH + "# dirty shared test command\n")
                if staged:
                    self.git("add", "record.sh")
                result = self.run_gate(head)
                self.assert_full_gate(result)
                self.assertIn("full tests — tracked tree is dirty", result.stderr)
                self.git("reset", "--hard", head)

    def test_staged_change_with_head_bytes_restored_still_requires_full(self):
        head = self.prepare_gate()
        self.put("record.sh", RECORD_SH + "# staged only\n")
        self.git("add", "record.sh")
        self.put("record.sh", RECORD_SH)
        result = self.run_gate(head)
        self.assert_full_gate(result)
        self.assertIn("full tests — tracked tree is dirty", result.stderr)

    def test_failed_selected_command_reports_failure_not_receipt_mismatch(self):
        head = self.prepare_gate()
        self.env["RECORD_BODY"] = 'echo "selected assertion failed"; exit 7'
        result = self.run_gate(head)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("selected assertion failed", result.stdout)
        self.assertIn("Tests: unknown", result.stdout)
        self.assertNotIn("invalid Tests receipt", result.stdout)
        self.assertIn("--test-file=" + TARGET, (self.repo / "invoked").read_text())

    def test_gate_uses_base_mapper_and_only_narrows_branch_pushes(self):
        self.put("scripts/lib/push-test-map.py",
                 'assert __file__ == "<stdin>", "must execute the base blob, not checkout file"\n' +
                 MAPPER.read_text())
        self.put("record.sh", RECORD_SH)
        self.put(".claude/skills/process-gate-local/local.config.sh",
                 'PROCESS_GATE_TYPECHECK_CMD=":"\nPROCESS_GATE_LINT_CMD=":"\n'
                 'PROCESS_GATE_TEST_CMD="bash record.sh"\n'
                 'PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"\n')
        self.base = self.commit()
        self.put(SOURCE, "# changed\n")
        head = self.commit()
        # An untracked Python shadow must not affect the isolated BASE mapper.
        self.put("subprocess.py", 'open("shadowed", "w").close(); raise SystemExit(1)\n')
        checker = ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"
        self.env.update(CLAUDE_PROJECT_DIR=str(self.repo))
        selected = len(CORE) + 1
        for scope, mode, scoped, narrowed in (("branch", "push", True, True),
                                               ("full", "push", True, False),
                                               ("branch", "merge", True, False),
                                               ("", "push", True, False),
                                               ("branch", "push", False, False)):
            with self.subTest(scope=scope, mode=mode, scoped=scoped):
                self.env["PG_PUSH_TEST_SCOPE"] = scope
                args = ["--mode=" + mode] + (["--range=" + self.base + ".." + head] if scoped else [])
                result = self.run_cmd("bash", str(checker), *args, check=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(f"Tests: narrowed: {selected} selected" in result.stdout, narrowed, result.stdout)
                self.assertEqual("Tests: full" in result.stdout, not narrowed, result.stdout)
                self.assertEqual("--test-file=" + TARGET in (self.repo / "invoked").read_text(), narrowed)
                self.assertFalse((self.repo / "shadowed").exists())
        self.git("rm", "-f", "scripts/lib/push-test-map.py")
        self.base = self.commit()
        self.put(SOURCE, "# next\n")
        head = self.commit()
        self.env["PG_PUSH_TEST_SCOPE"] = "branch"
        result = self.run_cmd("bash", str(checker), "--mode=push", "--range=" + self.base + ".." + head, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("--test-file=", (self.repo / "invoked").read_text())
        self.assertIn("Tests: full", result.stdout)

    def test_selected_command_must_receipt_the_selected_count(self):
        self.put("scripts/lib/push-test-map.py", MAPPER.read_text())
        self.put(".claude/skills/process-gate-local/local.config.sh",
                 'PROCESS_GATE_TYPECHECK_CMD=":"\nPROCESS_GATE_LINT_CMD=":"\n'
                 'PROCESS_GATE_TEST_CMD="bash record.sh"\n'
                 'PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"\n')
        self.put("record.sh", RECORD_SH)
        self.base = self.commit()
        self.put(SOURCE, "# changed\n")
        head = self.commit()
        self.env.update(PG_PUSH_TEST_SCOPE="branch", CLAUDE_PROJECT_DIR=str(self.repo))
        for body in (':\n', 'echo "PG_TESTS_RECEIPT full" > "$PG_TESTS_RECEIPT_FILE"\n',
                     'echo "PG_TESTS_RECEIPT narrowed 1" > "$PG_TESTS_RECEIPT_FILE"\n'):
            with self.subTest(body=body):
                # Keep the tracked tree clean: the receipt fault is a runtime seam.
                self.env["RECORD_BODY"] = body
                result = self.run_cmd("bash", str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"),
                                      "--mode=push", "--range=" + self.base + ".." + head, check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Tests: unknown", result.stdout)
                self.assertNotIn("Tests: full", result.stdout)

    def test_ambient_mapper_cannot_opt_in_without_tracked_config(self):
        self.put("scripts/lib/push-test-map.py", MAPPER.read_text())
        self.put("record.sh", RECORD_SH)
        self.put(".claude/skills/process-gate-local/local.config.sh",
                 'PROCESS_GATE_TYPECHECK_CMD=":"\nPROCESS_GATE_LINT_CMD=":"\n'
                 'PROCESS_GATE_TEST_CMD="bash record.sh"\n')
        self.base = self.commit()
        self.put(SOURCE, "# changed\n")
        self.commit()
        self.env.update(PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py",
                        PG_PUSH_TEST_SCOPE="branch", CLAUDE_PROJECT_DIR=str(self.repo))
        result = self.run_cmd("bash", str(ROOT / "core-rules/skills/process-gate/scripts/check-tests.sh"),
                              "--mode=push", "--range=" + self.base + "..HEAD", check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("--test-file=", (self.repo / "invoked").read_text())
        self.assertNotIn("Tests: narrowed", result.stdout)
        self.assertIn("Tests: full", result.stdout)


if __name__ == "__main__":
    unittest.main()
