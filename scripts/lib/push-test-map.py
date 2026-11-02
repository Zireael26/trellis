#!/usr/bin/env python3
"""Conservative branch-push selection. Executed from the range BASE, not checkout.

Only audited leaf entrypoints, CHANGELOG and existing top-level Bats may narrow.
Other paths (including shared libs, hooks, launcher and this mapper) stay full.
"""
import posixpath
import re
import subprocess
import sys

CORE = {"scripts/tests/" + name + ".bats" for name in (
    "posix-bootstrap-prologue", "suite-coverage", "push-test-map", "release-tag-consumers",
    "check-process-liveness", "test-fencing", "release-payload-commit", "live-model-roster",
    "gpt6-roster-sweep", "diff-base-sync", "no-legacy-herdr")}
LEAVES = {
    "check-decisions-log": ("check-decisions-log",),
    "install-pi-web-search": ("install-pi-web-search",),
    "pi-guide-parity": ("pi-guide-parity", "sync-to-template-dry-run"),
    "lint-recipe-routing": ("lint-recipe-routing", "commit-hooks", "workflow-stage-integrity"),
    "pi-spill-watchdog": ("pi-spill-watchdog", "disk-janitor-agents", "install-disk-janitor-launchd"),
}


def git(*args, **kwargs):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, **kwargs)


def inventory(ref):
    return {entry.split(b"\t", 1)[1].decode(): entry.split()[2].decode() for entry in
            git("ls-tree", "-r", "-z", ref).split(b"\0") if entry.startswith(
                (b"100644 blob ", b"100755 blob "))}


def dependencies(path, text, available):
    """Over-include literal references as well as source/load and shellcheck hints."""
    found = set()
    directory = posixpath.dirname(path)
    tokens = re.findall(r"[^\s'\"`;()<>|]+", text)
    tokens += re.findall(r"#\s*shellcheck\s+source=([^\s]+)", text)
    for token in tokens:
        token = token.strip("'\"")
        token = re.sub(r"\$\{?BATS_TEST_DIRNAME\}?", directory, token)
        # ROOT-style prefixes vary between suites. A repository path suffix is
        # sufficient; fixture-local lookalikes only add tests, never remove them.
        match = re.search(r"(?:^|/)((?:scripts|core-rules)/[^$\s]+)", token)
        candidates = [match[1]] if match else []
        candidates.append(posixpath.normpath(posixpath.join(directory, token)))
        if token.startswith(directory + "/"):
            candidates.append(token)
        for candidate in candidates:
            for name in (candidate, candidate + ".bash"):
                if name in available:
                    found.add(name)
            # A copied fixture directory binds every file under it.
            if "/fixtures/" in candidate or candidate.endswith("/fixtures"):
                found.update(name for name in available if name.startswith(candidate.rstrip("/") + "/"))
    return found


def source_closure(available):
    suites = {path for path in available if re.fullmatch(
        r"(?:scripts/tests|core-rules/(?:codex/)?hooks/tests|core-rules/skills/[^/]+/tests)/[A-Za-z0-9_-]+\.bats", path)}
    graph = {}
    pending = set(suites)
    while pending:
        batch = sorted(pending)
        pending = set()
        blobs = git("cat-file", "--batch", input="".join(available[path] + "\n" for path in batch).encode())
        offset = 0
        for path in batch:
            end = blobs.index(b"\n", offset)
            size = int(blobs[offset:end].split()[2])
            text = blobs[end + 1:end + 1 + size].decode(errors="replace")
            offset = end + size + 2
            graph[path] = dependencies(path, text, available)
        for path in batch:
            pending.update(graph[path] - graph.keys())
    consumers = {}
    for suite in suites:
        seen = set()
        pending = {suite}
        while pending:
            path = pending.pop()
            if path in seen:
                continue
            seen.add(path)
            consumers.setdefault(path, set()).add(suite)
            pending.update(graph[path] - seen)
    return consumers


def select(range_spec):
    if range_spec.count("..") != 1 or "..." in range_spec:
        raise ValueError("unsupported range")
    left, right = range_spec.split("..")
    base = git("rev-parse", "--verify", left + "^{commit}").strip().decode()
    head = git("rev-parse", "--verify", right + "^{commit}").strip().decode()
    git("merge-base", "--is-ancestor", base, head)
    if git("rev-list", "--min-parents=2", base + ".." + head).strip():
        raise ValueError("merge commit")
    commits = git("rev-list", base + ".." + head)
    # Inspect every commit, not just the net diff: reverted unknown changes and
    # both sides of renames must not disappear from the coverage decision.
    paths = set(git("diff-tree", "--stdin", "-r", "--no-commit-id", "--name-only",
                    "--no-renames", "-z", input=commits).decode().strip("\0").split("\0"))
    if not commits or not paths or "" in paths:
        raise ValueError("empty range")
    available = [inventory(ref) for ref in (base, head)]
    consumers = {}
    for tree in available:
        for path, suites in source_closure(tree).items():
            consumers.setdefault(path, set()).update(suites)
    tests = set(CORE)
    for path in sorted(paths):
        if path.startswith(("scripts/lib/", "scripts/tests/helpers/git-fence/")):
            raise ValueError("shared library or test fence: " + path)
        tests.update(consumers.get(path, ()))
        if re.fullmatch(r"scripts/tests/[A-Za-z0-9_-]+\.bats", path):
            tests.add(path)
        elif path == "CHANGELOG.md":
            pass  # Record scanners are already in CORE.
        elif path in {"scripts/" + name + ".sh" for name in LEAVES}:
            tests.update("scripts/tests/" + suite + ".bats" for suite in LEAVES[path[8:-3]])
        elif path.startswith(("scripts/tests/helpers/", "scripts/tests/fixtures/")) and path in consumers:
            pass
        else:
            raise ValueError("unmapped path: " + path)
    if any(not re.fullmatch(r"scripts/tests/[A-Za-z0-9_-]+\.bats", path) for path in tests):
        raise ValueError("dependency reaches a core suite; full battery required")
    for tree in available:
        if not tests <= tree.keys():
            raise ValueError("required test missing or not regular")
    return ["Tests: narrowed ({} files -> {} test files)".format(len(paths), len(tests)), *sorted(tests)]


if __name__ == "__main__":
    try:
        print("\n".join(select(sys.argv[1])))
    except (IndexError, ValueError, UnicodeError, OSError, subprocess.CalledProcessError) as exc:
        print("process-gate: full tests — {}".format(exc), file=sys.stderr)
        sys.exit(1)
