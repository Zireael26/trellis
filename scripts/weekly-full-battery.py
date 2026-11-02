#!/usr/bin/env python3
"""Scheduled uncached full battery. This script installs no scheduler/job."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from gate_receipts import private, state_root
from gate_verdict import git, key, safe_inputs, tree_verdicts


@contextlib.contextmanager
def effective_environment(environment):
    original = dict(os.environ)
    os.environ.clear()
    os.environ.update(environment)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(original)


def private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not private(path, True):
        raise ValueError("not an owner-private directory: " + str(path))


def write_json(path: Path, record: dict) -> None:
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(record, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def run_weekly(root: Path) -> int:
    state = state_root()
    private_directory(state)
    parent = state / "weekly-batteries"
    private_directory(parent)
    run_id = uuid.uuid4().hex
    kept = parent / run_id
    private_directory(kept)
    environment = dict(os.environ)
    # No inherited quick/selected/test adapter can turn a scheduled full run
    # into a synthetic or narrowed pass. Keep tool discovery (PATH) unchanged.
    removed = []
    for name in list(environment):
        if (name.startswith("TRELLIS_LOCAL_GATE_") or name.startswith("TRELLIS_TEST_")
                or name in ("PG_PUSH_TEST_SCOPE", "BATS_TEST_FILTER", "BATS_FILTER", "AGGREGATE_SCRIPT", "PACKER", "TRELLIS_STAGE_WEIGHTS_TSV")):
            removed.append(name)
            del environment[name]
    receipt = kept / "aggregate.tsv"
    fd = os.open(str(receipt), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    environment["TRELLIS_LOCAL_GATE_RECEIPT"] = str(receipt)
    with effective_environment(environment):
        before = safe_inputs(root)
        before_tree = git(root, "rev-parse", "HEAD^{tree}").decode().strip()
        candidates = tree_verdicts(before_tree, state)
    command = ["trellis", "heavy", "--lane", "process-gate", "--", sys.executable, "-I",
               str(root / "scripts/run-tests-local.py")]
    result = subprocess.run(command, cwd=root, env=environment, check=False).returncode
    result = result if result >= 0 else 128 - result
    with effective_environment(environment):
        after = safe_inputs(root)
        after_tree = git(root, "rev-parse", "HEAD^{tree}").decode().strip()
    divergence = bool(result and candidates and before_tree == after_tree)
    comparisons = []
    for candidate in candidates:
        fields = set(candidate["inputs"]) | set(before or {}) | set(after or {})
        differed = sorted(field for field in fields if any(
            snapshot is not None and snapshot.get(field) != candidate["inputs"].get(field)
            for snapshot in (before, after)))
        comparisons.append({"id": candidate["id"], "key": candidate["key"],
                            "differing_key_fields": differed,
                            "comparison_unavailable": before is None or after is None})
    report = {"id": run_id, "completed_at": time.time(), "exit": result, "uncached": True,
              "removed_overrides": sorted(removed),
              "prior_verdict": candidates[0]["id"] if candidates else None,
              "candidate_verdicts": comparisons, "before_tree": before_tree, "after_tree": after_tree,
              "input_key": key(before) if before is not None else None, "p1_divergence": divergence}
    if divergence:
        disabled = state / "reuse-disabled.json"
        try:
            write_json(disabled, report)
        except FileExistsError:
            pass  # Preserve the first unresolved incident, never clear it here.
        print("P1: weekly uncached battery diverged from tree-matched verdicts {}; reuse disabled until operator review: {}".format(
            ",".join(candidate["id"] for candidate in candidates), disabled), file=sys.stderr, flush=True)
    write_json(kept / "run.json", report)
    print("weekly-full-battery: uncached run={} exit={} report={}".format(run_id, result, kept), flush=True)
    return result


def main() -> int:
    if sys.argv[1:]:
        print("usage: python3 -I scripts/weekly-full-battery.py (no job is installed)", file=sys.stderr)
        return 64
    try:
        return run_weekly(Path(__file__).resolve().parent.parent)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print("weekly-full-battery: " + str(exc), file=sys.stderr)
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
