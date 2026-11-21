"""End-to-end tests for the read-only lean-audit report."""

import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]

class LeanAuditTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="lean-audit-")
        self.addCleanup(temp.cleanup)
        self.root, self.bin = Path(temp.name) / "sample project", Path(temp.name) / "bin"
        self.root.mkdir(); self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin))

    def file(self, name, contents):
        p = self.root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(contents, encoding="utf-8"); return p

    def run_audit(self, *args, via_shell=False):
        if via_shell:
            (self.bin / "python3").symlink_to(sys.executable); (self.bin / "dirname").symlink_to("/usr/bin/dirname")
            cmd = [str(SCRIPTS / "lean-audit.sh")]
        else:
            cmd = [sys.executable, "-I", str(SCRIPTS / "lean-audit.py")]
        proc = subprocess.run([*cmd, *args, str(self.root)], cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(proc.returncode, 0, proc.stderr); return proc.stdout

    def report(self): return json.loads(self.run_audit("--json"))
    def candidates(self): return {i["path"]: i for i in self.report()["findings"]}

    def test_json_schema_and_missing_analyzers(self):
        for n, c in (("package.json", "{}"), ("pyproject.toml", "[project]\nname='w'\n"), ("Cargo.toml", "[package]\nname='w'\n"), ("go.mod", "module x/w\n"), ("src/unused_util.ts", "export const v = 1;\n"), ("src/dead_helper.py", "def h(): return 1\n")):
            self.file(n, c)
        rep = self.report()
        self.assertEqual((set(rep), rep["schema_version"], rep["summary"]["stacks"], rep["summary"]["counts"]),
                         ({"schema_version", "analyzers", "summary", "test_diet", "findings"}, 1, ["javascript", "python", "rust", "go"], {"HIGH": 2, "MEDIUM": 0, "LOW": 0}))
        for n in ("knip", "vulture", "cargo-machete", "go"): self.assertEqual(rep["analyzers"][n]["analyzer_status"], "unavailable")
        self.assertEqual([i["path"] for i in rep["findings"]], ["src/dead_helper.py", "src/unused_util.ts"])
        for i in rep["findings"]: self.assertEqual((set(i), i["kind"], i["confidence"], bool(i["reason"])), ({"kind", "confidence", "path", "reason"}, "orphan_module", "HIGH", True))
        self.assertEqual(rep, self.report())

    def test_entry_points_and_static_reachability(self):
        self.file("package.json", json.dumps({"main": "./server.ts", "module": "./module.ts", "types": "./types.d.ts", "bin": {"widget": "./bin/cli.mjs"}, "exports": {"./parts/*": "./parts/*.js"}, "scripts": {"seed": "python3 scripts/seed.py && node scripts/verify.mjs"}}))
        self.file("app/dashboard/page.tsx", "import {boot} from '../../src/boot.js';\nboot();\n")
        self.file("src/boot.ts", "import './startup';\nexport const boot = () => {};\n")
        self.file("next.config.js", "export default {};\n"); self.file("app/dashboard/layout.tsx", "export default function L() {}\n")
        self.file("scripts/dispatch", '#!/bin/bash\ncase "$1" in leaf) shift; exec "$SCRIPT_DIR/leaf.sh" "$@" ;; esac\n')
        for n in ("src/startup.ts", "src/pages/api/status.ts", "src/instrumentation.ts", "drizzle/migrations/runner.ts", "prisma/refresh.py", "sql/migrations/run.sh", ".claude/hooks/check.py", ".agents/hooks/agent.sh", ".pi/extensions/plugin.ts", ".opencode/plugin/setup.mjs", "server.ts", "module.ts", "types.d.ts", "bin/cli.mjs", "parts/one.js", "scripts/seed.py", "scripts/verify.mjs", "scripts/leaf.sh"):
            self.file(n, "")
        self.file("scripts/stale.sh", "#!/bin/bash\ntrue\n")
        c = self.candidates()
        self.assertEqual((set(c), c["scripts/stale.sh"]["kind"], c["scripts/stale.sh"]["confidence"]), ({"scripts/stale.sh"}, "unused_script", "HIGH"))

    def test_dynamic_weak_zero_import_and_analyzers(self):
        self.file("app/page.tsx", "import('./literal_target');\nimport(`../src/loaders/${name}.ts`);\nimport.meta.glob('../src/globs/*.ts');\n// import('./comment_only');\nimport '../src/barrel';\n")
        self.file("src/barrel.ts", "export {item} from './reexported';\n"); self.file("src/unused_root.py", "from . import unused_child\n")
        self.file("src/register.py", "adapter = 'persistent_adapter'\n"); self.file(".github/workflows/unit.yml", "steps:\n  - run: bash scripts/ci.sh\n")
        for n in ("app/literal_target.ts", "app/comment_only.ts", "src/loaders/child.ts", "src/globs/item.ts", "src/reexported.ts", "src/unused_child.py", "src/persistent_adapter.py", "scripts/ci.sh"): self.file(n, "")
        c = self.candidates()
        for p in ("app/literal_target.ts", "src/loaders/child.ts", "src/globs/item.ts", "src/persistent_adapter.py"): self.assertEqual(c[p]["confidence"], "LOW")
        for p in ("app/comment_only.ts", "src/reexported.ts", "src/unused_child.py", "scripts/ci.sh"): self.assertEqual(c[p]["confidence"], "MEDIUM")
        self.assertEqual((c["src/unused_root.py"]["confidence"], "src/barrel.ts" in c), ("HIGH", False))

    def test_zero_import_tests_analyzers_and_markdown_wrapper(self):
        self.file("src/data.py", "VALUE = 1\n"); self.file("tests/test_real.py", "from src.data import VALUE\n")
        self.file("tests/test_empty.py", "import unittest\n"); self.file("tests/check.spec.ts", "import './utils';\n"); self.file("tests/utils.ts", "export const h = 1;\n")
        for s in ("a", "b"): self.file(f"tests/{s}/helpers/factory.py", "VALUE = 2\n")
        c = self.candidates()
        self.assertTrue("tests/test_real.py" not in c and "src/data.py" not in c)
        for p in ("tests/test_empty.py", "tests/check.spec.ts"): self.assertEqual((c[p]["kind"], c[p]["confidence"]), ("zero_production_imports", "MEDIUM"))
        self.assertEqual((c["tests/b/helpers"]["kind"], c["tests/b/helpers"]["duplicate_of"]), ("duplicate_test_helpers", "tests/a/helpers"))
        self.file("package.json", "{}"); self.file("requirements.txt", ""); self.file("Cargo.toml", ""); self.file("module.py", "")
        self.file("node_modules/.bin/knip", '#!/bin/bash\n[[ "$*" == "--production --reporter json" && -f package.json ]] || exit 2\nprintf \'%s\\n\' \'{"files":["unused.ts"],"issues":[]}\'\nexit 1\n').chmod(0o755)
        for n, body in {"knip": "exit 9\n", "vulture": '[[ "$*" == "--min-confidence 80"*"module.py"* ]] || exit 2\nprintf "vulture finding\\n"\nexit 3\n', "cargo": '[[ "$*" == machete && "$CARGO_NET_OFFLINE" == true ]] || exit 2\nexit 0\n', "cargo-machete": "exit 0\n"}.items():
            p = self.bin / n; p.write_text("#!/bin/bash\n" + body, encoding="utf-8"); p.chmod(0o700)
        a = self.report()["analyzers"]
        self.assertEqual((a["knip"]["analyzer_status"], a["vulture"]["analyzer_status"], a["cargo-machete"]["analyzer_status"], a["knip"]["output"]["files"], a["vulture"]["output"]), ("ok", "ok", "ok", ["unused.ts"], "vulture finding"))
        self.file("node_modules/.bin/knip", "#!/bin/bash\nexit 0\n").chmod(0o755)
        self.assertEqual(self.report()["analyzers"]["knip"]["analyzer_status"], "error")
        md = self.run_audit(via_shell=True)
        self.assertTrue("# Lean Audit" in md and "knip:" in md and "test-diet:" in md)

    def test_diet_metrics_and_ceremony(self):
        self.file("src/app.py", "a = 1\nb = 2\n")
        self.file("tests/test_small.py", "from src.app import a\nassert a == 1\n")
        self.file("tests/test_mocky.spec.ts", "vi.mock('a')\njest.mock('b')\nwaitForTimeout(1)\ntime.sleep(1)\n@patch('x')\n")
        diet = self.report()["test_diet"]
        self.assertEqual((diet["source_loc"], diet["test_loc"], diet["test_to_source_ratio"]), (2, 7, 3.5))
        self.assertEqual(diet["largest_test_files"][0], {"path": "tests/test_mocky.spec.ts", "loc": 5})
        self.assertEqual(diet["high_ceremony_tests"], [{"path": "tests/test_mocky.spec.ts", "markers": 5, "loc": 5}])
        self.assertIn("test-diet: source_loc=2 test_loc=7 ratio=3.50 high_ceremony=1", self.run_audit())

if __name__ == "__main__":
    unittest.main()
