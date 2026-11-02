"""Exact-input full-battery verdict reads. Only run-tests-local writes verdicts."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
from typing import Any

from gate_receipts import digest, passing_rows, private, state_root
from receipt_provenance import probe

SCHEMA = 1
MAX_VERDICT_AGE_SECONDS = 7 * 86400
RUNNER_FILES = ("scripts/run-tests-local.py", "scripts/run-tests.sh",
                "scripts/lib/test-suites.sh", "scripts/lib/bats-jobs.sh",
                "scripts/lib/gate_receipts.py", "scripts/lib/gate_verdict.py",
                "scripts/lib/receipt_provenance.py", "scripts/tests/stage-weights.tsv",
                "scripts/tests/helpers/git-fence/git", "scripts/tests/helpers/git-fence/mktemp")
TOOLS = ("bash", "bats", "jq", "git", "node", "pnpm", "perl", "python3", "shellcheck", "ruff", "mypy", "mktemp",
         "timeout", "gtimeout", "uv", "shfmt", "lsof", "ps", "gh", "npm", "npx")
# BSD utilities lack a portable version interface; JS entrypoints are hashed,
# not invoked. Every executable still binds its resolved path and bytes.
BINARY_ONLY_TOOLS = {"mktemp", "lsof", "ps", "npm", "npx"}
# Keep these non-recursive globs aligned with scripts/lib/test-suites.sh.
DISCOVERY_GLOBS = ("scripts/tests/*.bats", "core-rules/hooks/tests/*.bats",
                   "core-rules/codex/hooks/tests/*.bats", "core-rules/skills/*/tests/*.bats")
# These values control queueing, output paths or inherited slot ownership, never
# suite selection/content. All other environment values are hashed, not stored.
OPERATIONAL_ENV = {"_", "SHLVL", "TRELLIS_LOCAL_GATE_RECEIPT", "TRELLIS_LOCAL_GATE_QUEUE_WAIT",
                   "TRELLIS_HEAVY_FD", "TRELLIS_HEAVY_TOKEN", "TRELLIS_HEAVY_SLOT",
                   "TRELLIS_HEAVY_POOL", "TRELLIS_HEAVY_DIR_ID"}


def encoded(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def key(inputs: dict[str, Any]) -> str:
    return digest(encoded(inputs))


def git(root: Path, *args: str) -> bytes:
    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    return subprocess.check_output(["git", "-C", str(root), *args], env=env, stderr=subprocess.DEVNULL, timeout=5)


def toolchain(root: Path, version_probe=probe) -> dict[str, Any]:
    env = os.environ | {"COREPACK_ENABLE_NETWORK": "0", "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0"}
    tools = {}
    for name in TOOLS:
        executable = shutil.which(name)
        if executable:
            path = Path(executable).resolve(strict=True)
            entry = {"path": str(path), "binary": digest(path.read_bytes())}
            if name in BINARY_ONLY_TOOLS:
                entry["binding"] = "binary-only"
                package = path.parent.parent / "package.json"
                if name in ("npm", "npx") and path.parent.name == "bin" and package.is_file():
                    entry["package"] = digest(package.read_bytes())
            else:
                version = version_probe([str(path), "--version"], env, root)
                if not version or version.startswith("unavailable:"):
                    raise ValueError("tool version probe failed: " + name)
                entry["version"] = version
            tools[name] = entry
        else:
            tools[name] = {"unavailable": True}
    tools["interpreter"] = {"path": sys.executable, "version": sys.version,
                            "binary": digest(Path(sys.executable).read_bytes())}
    return tools


def capture_inputs(root: Path, gated_head: str = "HEAD", version_probe=probe) -> dict[str, Any]:
    for name in os.environ:
        if (name in ("PG_PUSH_TEST_SCOPE", "BATS_TEST_FILTER", "BATS_FILTER", "AGGREGATE_SCRIPT", "PACKER")
                or name.startswith("TRELLIS_TEST_") and name != "TRELLIS_TEST_SHARDS"
                or name.startswith("TRELLIS_LOCAL_GATE_") and name not in OPERATIONAL_ENV
                or name.startswith("TRELLIS_HEAVY_TEST")):
            raise ValueError("narrowed or test-seam run: " + name)
    head = git(root, "rev-parse", "--verify", "HEAD^{commit}").strip()
    if git(root, "rev-parse", "--verify", gated_head + "^{commit}").strip() != head:
        raise ValueError("checkout HEAD is not the gated head")
    if git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("checkout is not clean")
    if git(root, "ls-files", "-z", "-o", "-i", "--exclude-standard", "--",
           *(":(glob)" + pattern for pattern in DISCOVERY_GLOBS)):
        raise ValueError("ignored file matches suite discovery")
    if any(entry[:1].islower() or entry.startswith(b"S ") for entry in git(root, "ls-files", "-v", "-z").split(b"\0") if entry):
        raise ValueError("assume-unchanged or skip-worktree checkout")
    listing = git(root, "ls-tree", "-rz", "--full-tree", "HEAD")
    suites = [entry for entry in listing.split(b"\0") if entry and
              (b"/tests/" in entry or entry.split(b"\t", 1)[-1].endswith(b".bats"))]
    runner = {name: digest((root / name).read_bytes()) for name in RUNNER_FILES}
    environment = {name: value for name, value in os.environ.items()
                   if name not in OPERATIONAL_ENV}
    return {"schema": SCHEMA, "tree": git(root, "rev-parse", "HEAD^{tree}").decode().strip(),
            "inventory": digest(b"\0".join(entry.split(b"\t", 1)[-1] for entry in suites)),
            "suite_versions": digest(b"\0".join(suites)), "runner": runner,
            "toolchain": toolchain(root, version_probe), "environment": digest(encoded(environment)),
            "refs": git(root, "for-each-ref", "--format=%(refname) %(objectname)").decode().splitlines(),
            "git_config": digest(git(root, "config", "--null", "--list", "--show-origin")),
            "platform": [sys.platform, platform.release(), platform.machine()]}


def safe_inputs(root: Path, gated_head: str = "HEAD", version_probe=probe) -> dict[str, Any] | None:
    try:
        return capture_inputs(root, gated_head, version_probe)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None  # A miss always executes the real battery.


def find_verdict(inputs: dict[str, Any] | None, state: Path | None = None, *, occupancy: bool = True) -> dict[str, Any] | None:
    if inputs is None:
        return None
    try:
        state = state if state is not None else state_root()
        directory = state / "verdicts"
        path = directory / (key(inputs) + ".json")
        if ((occupancy and ((state / "gate-holder.json").exists() or any((state / "runs").glob("*.json"))))
                or (state / "reuse-disabled.json").exists()
                or not all((private(state, True), private(directory, True), private(path)))):
            return None
        record = json.loads(path.read_text(encoding="utf-8"))
        if (record["schema"] != SCHEMA or record["key"] != key(inputs) or record["inputs"] != inputs
                or record["status"] != "pass" or record["complete"] is not True
                or record["containment"] != "verified-empty"
                or not re.fullmatch(r"[0-9a-f]{32}", record["id"])
                or not math.isfinite(record["completed_at"]) or record["completed_at"] <= 0
                or not 0 <= time.time() - record["completed_at"] <= MAX_VERDICT_AGE_SECONDS):
            return None
        parent = state / "passing-runs"
        kept = parent / record["id"]
        aggregate, metadata = kept / "aggregate.tsv", kept / "run.json"
        if not all((private(parent, True), private(kept, True), private(aggregate), private(metadata))):
            return None
        content = aggregate.read_bytes()
        passing_rows(content)
        run = json.loads(metadata.read_text(encoding="utf-8"))
        if (record["aggregate_sha256"] != digest(content) or run["aggregate_sha256"] != digest(content)
                or run["id"] != record["id"] or run["tree"] != inputs["tree"]
                or run["completed_at"] != record["completed_at"]):
            return None
        return record
    except (OSError, ValueError, KeyError, TypeError):
        return None


def tree_verdicts(tree: str, state: Path) -> list[dict[str, Any]]:
    """Snapshot valid tree matches before an uncached run invalidates them."""
    directory = state / "verdicts"
    try:
        if not private(state, True) or not private(directory, True):
            return []
    except OSError:
        return []
    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            if not private(path):
                continue
            inputs = json.loads(path.read_text(encoding="utf-8"))["inputs"]
            if inputs["tree"] != tree or path.name != key(inputs) + ".json":
                continue
            record = find_verdict(inputs, state, occupancy=False)
            if record is not None:
                records.append(record)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return records


def describe(record: dict[str, Any]) -> str:
    import datetime
    date = datetime.datetime.fromtimestamp(record["completed_at"], datetime.timezone.utc).isoformat()
    return "reused verdict {} (tree {}, ran {})".format(record["id"], record["inputs"]["tree"], date)
