"""Qualification tests against a pristine, explicitly supplied npm package."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        source = Path(os.environ["PI_MCP_ADAPTER_PRISTINE"])
        for name in ("package.json", "tool-registrar.ts"):
            shutil.copyfile(source / name, self.root / name)
        self.installer = Path(__file__).resolve().parents[1] / "apply-pi-mcp-adapter-patch.py"

    def run_installer(self):
        return subprocess.run(
            ["python3", str(self.installer), str(self.root)],
            capture_output=True, text=True, check=False,
        )

    def test_apply_and_repeat_preserve_the_qualified_result(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stderr)
        source = (self.root / "tool-registrar.ts").read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(),
                         "5b24e2935bd54dbf85b5959297c1aca919baad29542a097b3423412f8befb90e")
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("already applied", second.stdout)
        self.assertEqual((self.root / "tool-registrar.ts").read_bytes(), source)

    def test_other_version_is_refused_without_source_mutation(self):
        path = self.root / "package.json"
        package = json.loads(path.read_text())
        package["version"] = "2.32.2"
        path.write_text(json.dumps(package))
        before = (self.root / "tool-registrar.ts").read_bytes()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual((self.root / "tool-registrar.ts").read_bytes(), before)

    def test_source_drift_is_refused_without_overwriting_local_changes(self):
        path = self.root / "tool-registrar.ts"
        path.write_bytes(path.read_bytes() + b"\n// local change\n")
        before = path.read_bytes()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
