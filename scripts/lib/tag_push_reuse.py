"""Verified release-tag reuse. Any uncertainty leaves the full battery intact."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gate_verdict import describe, encoded, find_verdict, git, safe_inputs, tree_verdicts
from gate_receipts import state_root
from release_metadata import source_digest

MANIFEST = "scripts/tests/release-metadata-audit.json"


def tag_suites(root: Path, release: str) -> list[str]:
    if not git(root, "ls-tree", release, "--", MANIFEST).startswith(b"100644 blob "):
        raise ValueError("missing T32 trace")
    audit = json.loads(git(root, "cat-file", "blob", release + ":" + MANIFEST))
    if (audit.get("schema") != 1 or audit.get("complete") is not True
            or audit.get("source_digest") != source_digest(root, release, MANIFEST)):
        raise ValueError("incomplete or stale T32 trace")
    observations = audit.get("observations")
    suites = audit.get("suites")
    if not isinstance(observations, dict) or not isinstance(suites, list) or not suites:
        raise ValueError("unclassified T32 trace")
    classified = []
    tags = []
    for suite, entry in observations.items():
        if (not re.fullmatch(r"(?:scripts/tests|core-rules/(?:codex/)?hooks/tests|core-rules/skills/[^/]+/tests)/[A-Za-z0-9_.-]+\.bats", suite)
                or ".." in suite.split("/") or not isinstance(entry, dict)
                or not isinstance(entry.get("metadata"), list) or type(entry.get("tag_reads")) is not bool
                or not isinstance(entry.get("trace_sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["trace_sha256"])
                or not git(root, "ls-tree", release, "--", suite).startswith((b"100644 blob ", b"100755 blob "))):
            raise ValueError("unreadable or unclassified traced suite")
        if entry["metadata"] or entry["tag_reads"]:
            classified.append(suite)
        if entry["tag_reads"]:
            tags.append(suite)
    if sorted(classified) != sorted(suites) or not tags:
        raise ValueError("inconsistent or empty T32 tag class")
    return sorted(tags)


def evaluate(root: Path, identity: str, range_spec: str) -> dict:
    tag, expected = identity.split(":")
    if (not re.fullmatch(r"refs/tags/v[0-9A-Za-z.+-]+", tag)
            or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", expected)
            or range_spec.count("..") != 1 or "..." in range_spec):
        raise ValueError("ambiguous tag identity or range")
    endpoint = range_spec.split("..")[1]
    payload = git(root, "rev-parse", "--verify", expected + "^{commit}").decode().strip()
    # The selector snapshots range endpoints as commits. Keep the pushed tag
    # object pinned separately, while accepting that immutable peeled endpoint.
    if (git(root, "rev-parse", "--verify", endpoint + "^{commit}").decode().strip() != payload
            or git(root, "rev-parse", "--verify", tag).decode().strip() != expected):
        raise ValueError("pushed tag identity changed")
    release = git(root, "rev-parse", "--verify", payload + "^1").decode().strip()
    verifier = Path(__file__).resolve().parent.parent / "release-payload-commit.sh"
    subprocess.run(["bash", "-p", str(verifier), "--verify-tag", tag[10:], release],
                   cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    suites = tag_suites(root, release)
    current = safe_inputs(root)
    tree = git(root, "rev-parse", release + "^{tree}").decode().strip()
    if current is None or current["tree"] != tree:
        raise ValueError("checkout is not the exact release tree")
    tag_row = tag + " " + expected
    if tag_row not in current["refs"]:
        raise ValueError("verified tag disappeared")
    state = state_root()
    matches = []
    mismatched = set()
    for record in tree_verdicts(tree, state):
        candidate = record["inputs"]
        if find_verdict(candidate, state) is None:
            continue
        # The only allowed key difference is creation of this verified tag.
        # Tree, environment, runner, inventory, tools and every other ref bind.
        refs = candidate["refs"]
        if not isinstance(refs, list):
            continue
        adjusted = dict(candidate)
        if not any(row.startswith(tag + " ") for row in refs):
            adjusted["refs"] = sorted([*refs, tag_row])
        mismatched.update(name for name in current if adjusted.get(name) != current[name])
        if encoded(adjusted) == encoded(current):
            matches.append(record)
    if len(matches) != 1:
        raise ValueError("no unambiguous T30-validated exact-tree verdict; changed inputs: " + ", ".join(sorted(mismatched)))
    if git(root, "rev-parse", "--verify", tag).decode().strip() != expected:
        raise ValueError("tag moved during lookup")
    return {"verdict": describe(matches[0]), "tree": tree,
            "command": "bats " + " ".join(shlex.quote(suite) for suite in suites)}


def main() -> int:
    try:
        result = evaluate(Path.cwd(), *sys.argv[1:])
        print(result["verdict"] + "\n" + result["command"])
        return 0
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, subprocess.SubprocessError) as exc:
        print("tag-push: full tests — " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
