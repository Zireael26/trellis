"""Receipt-derived weights, using only sandboxed files."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("weights", Path(__file__).resolve().parents[1] / "refresh-stage-weights.py")
WEIGHTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEIGHTS)


class WeightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        (self.state / "passing-runs").mkdir(mode=0o700)
        self.table = self.root / "weights.tsv"
        self.table.write_text("stage\tseconds\na\t1\nb\t7\n")
        self.baseline = self.root / "baseline.tsv"
        self.baseline.write_bytes(self.receipt(99))

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def receipt(seconds):
        return b"ordinal\tstage\telapsed_seconds\texit" + \
            "\n1\ta\t{}\t0\n".format(seconds).encode()

    def keep(self, number, seconds):
        path = self.state / "passing-runs" / ("{:032x}".format(number))
        path.mkdir(mode=0o700)
        content = self.receipt(seconds)
        (path / "aggregate.tsv").write_bytes(content)
        (path / "run.json").write_text(json.dumps({"id": path.name, "completed_at": number,
            "head": "a" * 40, "tree": "b" * 40, "aggregate_sha256": WEIGHTS.digest(content)}))
        for entry in path.iterdir():
            entry.chmod(0o600)
        return path

    def refresh(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            result = WEIGHTS.refresh(self.table, self.baseline, self.state)
        return result, stderr.getvalue()

    def test_median_of_last_five_and_unmeasured_estimate(self):
        for number, seconds in enumerate((100, 10, 20, 30, 40, 50), 1):
            self.keep(number, seconds)
        result, evidence = self.refresh()
        self.assertEqual(result, "stage\tseconds\na\t30\nb\t7\n")
        self.assertEqual(evidence.count("source "), 5)
        self.assertIn("retained estimates for 1 unmeasured stages", evidence)

    def test_tampered_and_nonprivate_runs_are_not_samples(self):
        for number, mutation in enumerate(("digest", "mode", "red", "partial"), 1):
            path = self.keep(number, 10)
            if mutation == "digest":
                (path / "aggregate.tsv").write_bytes(self.receipt(0))
            elif mutation == "mode":
                (path / "run.json").chmod(0o644)
            else:
                content = self.receipt(0).replace(b"\t0\n", b"\t1\n") if mutation == "red" else self.receipt(0).replace(b"\n1\t", b"\n2\t")
                (path / "aggregate.tsv").write_bytes(content)
                record = json.loads((path / "run.json").read_text())
                record["aggregate_sha256"] = WEIGHTS.digest(content)
                (path / "run.json").write_text(json.dumps(record))
        result, evidence = self.refresh()
        self.assertEqual(result, "stage\tseconds\na\t99\nb\t7\n")
        self.assertEqual(evidence.count("ignored "), 4)

    def test_baseline_must_be_complete_green_with_finite_timings(self):
        for content in (b"bad\n", self.receipt("nan"), self.receipt(-1),
                        self.receipt(1).replace(b"\t0\n", b"\t7\n"),
                        self.receipt(1).replace(b"\n1\t", b"\n2\t")):
            with self.subTest(content=content):
                self.baseline.write_bytes(content)
                with self.assertRaises(ValueError):
                    self.refresh()


if __name__ == "__main__":
    unittest.main()
