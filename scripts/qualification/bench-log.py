#!/usr/bin/env python3
"""Retain the actual I-A4 JSON as the recorded command's stdout.

This transport never manufactures observations, changes eligibility, or turns a
variant label into measurements. Owners must add missing cold/repair/fallback
rows to I-A4; the checker rejects any missing required row.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--variant", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    # Output is temporary transport only: record.py retains the JSON bytes and
    # their hash. Bench failures retain their own quarantined sandbox evidence.
    with tempfile.TemporaryDirectory(prefix="qualification-bench-log-") as temporary:
        result = subprocess.run([sys.executable, "-I", str(root / "scripts/bench/trellis-latency.py"),
            "--source", str(args.runtime.resolve()), "--rev", "HEAD", "--n", "30", "--warmup", "2", "--out", temporary,
            "--sandbox-base", os.environ["TMPDIR"], "--condition", "normal", "--label", "qualification"], stdout=sys.stderr, stderr=sys.stderr)
        receipts = list(Path(temporary).glob("bench-*.json"))
        if len(receipts) != 1:
            print("qualification bench: no unique raw receipt", file=sys.stderr)
            return result.returncode or 2
        raw = receipts[0].read_bytes()
        json.loads(raw)  # Invalid bytes are never substituted with a PASS.
        sys.stdout.buffer.write(raw)
        return result.returncode


if __name__ == "__main__":
    sys.exit(main())
