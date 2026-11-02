#!/usr/bin/env python3
"""Regenerate reviewed weights from the last five passing aggregate receipts.

The inventory is the existing table: newly split/unmeasured stages retain their
previous estimate, explicitly reported, until a complete battery measures them.
No test command runs, and this command never changes weights automatically.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import statistics
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from gate_receipts import digest, passing_rows, private, state_root

ROOT = Path(__file__).resolve().parent.parent


def refresh(table: Path, baseline: Path, state: Path) -> str:
    lines = table.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "stage\tseconds":
        raise ValueError("invalid weights header")
    weights = {}
    for line in lines[1:]:
        stage, value = line.split("\t")
        seconds = float(value)
        if stage in weights or not stage or not math.isfinite(seconds) or seconds < 0:
            raise ValueError("invalid stage weight")
        weights[stage] = seconds
    runs = [(0.0, str(baseline), passing_rows(baseline.read_bytes()))]
    parent = state / "passing-runs"
    if parent.exists():
        if not private(state, True) or not private(parent, True):
            raise ValueError("passing-run directory is not owner-private")
        for path in sorted(parent.iterdir()):
            try:
                metadata, aggregate = path / "run.json", path / "aggregate.tsv"
                if not all((private(path, True), private(metadata), private(aggregate))):
                    raise ValueError("not owner-private")
                record = json.loads(metadata.read_text(encoding="utf-8"))
                content = aggregate.read_bytes()
                completed = float(record["completed_at"])
                if (record["id"] != path.name or record["aggregate_sha256"] != digest(content)
                        or not record["head"] or not record["tree"] or not math.isfinite(completed) or completed <= 0):
                    raise ValueError("invalid passing-run metadata")
                runs.append((completed, str(path), passing_rows(content)))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                print("refresh-stage-weights: ignored {}: {}".format(path, exc), file=sys.stderr)
    runs.sort(key=lambda entry: (entry[0], entry[1]))
    samples = {}
    for _, source, rows in runs[-5:]:
        print("refresh-stage-weights: source {}".format(source), file=sys.stderr)
        for stage, seconds in rows:
            samples.setdefault(stage, []).append(seconds)
    missing = sorted(set(weights) - samples.keys())
    if missing:
        print("refresh-stage-weights: retained estimates for {} unmeasured stages".format(len(missing)), file=sys.stderr)
    result = ["stage\tseconds"]
    for stage in sorted(weights):
        value = statistics.median(samples[stage]) if stage in samples else weights[stage]
        result.append("{}\t{}".format(stage, math.ceil(value)))
    return "\n".join(result) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, default=ROOT / "scripts/tests/stage-weights.tsv")
    parser.add_argument("--baseline", type=Path, default=ROOT / "specs/072-fast-trellis/evidence/battery-timings-1321.tsv")
    parser.add_argument("--state-dir", type=Path)
    args = parser.parse_args()
    try:
        content = refresh(args.weights, args.baseline, args.state_dir if args.state_dir is not None else state_root())
        args.weights.write_text(content, encoding="utf-8")
    except (OSError, ValueError) as exc:
        print("refresh-stage-weights: {}".format(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
