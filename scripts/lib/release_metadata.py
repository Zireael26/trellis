"""Base-side release-metadata class. Incomplete/stale audits run the full battery."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gate_receipts import digest, private, state_root
from gate_verdict import encoded, find_verdict, git, safe_inputs


def metadata_path(path: str) -> bool:
    return path in ("VERSION", "core-rules/VERSION", "CHANGELOG.md") or bool(
        re.fullmatch(r"docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md", path))


def source_digest(root: Path, revision: str, manifest: str) -> str:
    entries = git(root, "ls-tree", "-rz", "--full-tree", revision).split(b"\0")
    return digest(b"\0".join(entry for entry in entries if entry and
        entry.split(b"\t", 1)[1].decode() != manifest and
        not metadata_path(entry.split(b"\t", 1)[1].decode())))


def version_line(content: bytes) -> bool:
    text = content.decode("ascii").removesuffix("\n")
    match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
                         r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
                         r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", text)
    return bool(match and (not match[4] or all(not part.isdigit() or part == "0" or not part.startswith("0")
                                            for part in match[4].split("."))))


def changed_metadata(root: Path, base: str, head: str) -> int:
    if not git(root, "merge-base", base, head).strip() == git(root, "rev-parse", base).strip():
        raise ValueError("base is not an ancestor")
    commits = git(root, "rev-list", base + ".." + head).decode().splitlines()
    if not commits or git(root, "rev-list", "--min-parents=2", base + ".." + head):
        raise ValueError("empty range or merge commit")
    changes = []
    for commit in commits:
        fields = git(root, "diff-tree", "-r", "--raw", "-z", "--no-abbrev", "--no-renames", "--no-commit-id", commit).split(b"\0")
        for index in range(0, len(fields) - 1, 2):
            src, dst, _, blob, status = fields[index].decode().lstrip(":").split()
            path = fields[index + 1].decode()
            changes.append((path, src, dst, blob, status))
    if not any(metadata_path(path) for path, *_ in changes):
        return 0  # Ordinary docs still use their existing policy class.
    for path, src, dst, blob, status in changes:
        if (not metadata_path(path) or status not in ("A", "M", "D")
                or (src, dst) not in (("000000", "100644"), ("100644", "100644"), ("100644", "000000"))):
            raise ValueError("non-metadata path, change type, or mode")
        if path in ("VERSION", "core-rules/VERSION") and dst != "100644":
            raise ValueError("VERSION may not be deleted")
        if dst == "100644":
            content = git(root, "cat-file", "blob", blob)
            if b"\0" in content or content.startswith(b"version https://git-lfs"):
                raise ValueError("binary or LFS metadata")
            if path in ("VERSION", "core-rules/VERSION") and not version_line(content):
                raise ValueError("VERSION is not one semver line")
    return len({path for path, *_ in changes})


def evaluate(root: Path, base: str, head: str, manifest: str) -> tuple[int, str]:
    count = changed_metadata(root, base, head)
    if not count:
        return 0, ""
    if not re.fullmatch(r"[A-Za-z0-9_./-]+\.json", manifest) or ".." in manifest.split("/"):
        raise ValueError("unsafe audit path")
    entry = git(root, "ls-tree", base, "--", manifest).decode()
    if not entry.startswith("100644 blob "):
        raise ValueError("audit is not a regular base-side file")
    audit = json.loads(git(root, "cat-file", "blob", base + ":" + manifest))
    if (audit.get("schema") != 1 or audit.get("complete") is not True
            or audit.get("source_digest") != source_digest(root, base, manifest)):
        raise ValueError("release-metadata audit is incomplete or stale")
    suites = audit.get("suites")
    if not isinstance(suites, list) or not suites or len(set(suites)) != len(suites):
        raise ValueError("empty or duplicate audited suites")
    for suite in suites:
        if (not isinstance(suite, str) or not re.fullmatch(r"(?:scripts/tests|core-rules/[A-Za-z0-9_./-]+)/[A-Za-z0-9_.-]+\.bats", suite)
                or ".." in suite.split("/") or not git(root, "ls-tree", base, "--", suite).startswith((b"100644 blob ", b"100755 blob "))):
            raise ValueError("invalid audited suite")
    current = safe_inputs(root, head)
    if current is None:
        raise ValueError("checkout is not clean at the gated head")
    tree = git(root, "rev-parse", base + "^{tree}").decode().strip()
    branch = git(root, "symbolic-ref", "-q", "HEAD").decode().strip()
    base_head = git(root, "rev-parse", base).decode().strip()
    gated_head = git(root, "rev-parse", head).decode().strip()
    state = state_root()
    if not private(state, True) or not private(state / "verdicts", True):
        raise ValueError("no private base verdict directory")
    for path in sorted((state / "verdicts").glob("*.json")):
        try:
            if not private(path):
                continue
            candidate = json.loads(path.read_text(encoding="utf-8"))["inputs"]
            if candidate["tree"] != tree or find_verdict(candidate, state) is None:
                continue
            adjusted = dict(candidate, tree=current["tree"])
            # Only the current branch may have advanced from base to candidate;
            # tags, remote refs and every other branch must be unchanged.
            if isinstance(candidate["refs"], list):
                adjusted["refs"] = [branch + " " + gated_head if row == branch + " " + base_head else row
                                    for row in candidate["refs"]]
            if encoded(adjusted) == encoded(current):
                return count, "bats " + " ".join(shlex.quote(suite) for suite in suites)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    raise ValueError("no matching full green base verdict")


def main() -> int:
    try:
        count, command = evaluate(Path.cwd(), *sys.argv[1:])
        if not count:
            return 2
        print(str(count) + "\t" + command)
        return 0
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, subprocess.SubprocessError) as exc:
        print("release-metadata: full tests — " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
