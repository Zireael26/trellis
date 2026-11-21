#!/usr/bin/env python3
"""Conservative branch-push selection. Executed from the range BASE, not checkout.

Only audited leaf entrypoints, CHANGELOG and existing top-level Bats may narrow.
Other paths (including shared libs, hooks, launcher and this mapper) stay full.
"""
import ast
import fnmatch
import json
import os
import posixpath
import re
import subprocess
import sys

CORE = {"scripts/tests/" + name + ".bats" for name in (
    "posix-bootstrap-prologue", "suite-coverage", "push-test-map", "release-tag-consumers",
    "check-process-liveness", "test-fencing", "release-payload-commit", "live-model-roster",
    "gpt6-roster-sweep", "diff-base-sync", "no-legacy-herdr",
    # 1.5.1: refuses bare [[ ]] in any Bats suite or helper, which bash 3.2
    # errexit ignores; a narrowed push that edits a suite must still run it.
    "bats-conditionals-lint",
    # T39: its Bash 3.2 compatibility scan reads every shipped shell source,
    # including the narrowing leaf entrypoints, so no narrowed push may skip it.
    "native-hooks-delivery",
    # Its lint greps every tracked product shell file for a BSD stat -f probe
    # chained into GNU stat -c, so a push editing any shell source must run it.
    "attach-verdict-stat-dialect")}
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


JS_EXTS = (".mjs", ".js", ".cjs", ".ts", ".mts", ".cts")
DECLARED_INPUTS_PATH = "scripts/tests/declared-test-inputs.json"
PROTECTED_RUNNERS = {
    "scripts/run-tests.sh",
    "scripts/run-tests-local.py",
    "scripts/weekly-full-battery.py",
    "scripts/check-gate-inventory.sh",
    DECLARED_INPUTS_PATH,
}


def _resolve_py_module(base_dir, module_parts, available):
    found = set()
    rel = "/".join(module_parts)
    roots = [base_dir] if base_dir is not None else ["scripts", ""]
    for root in roots:
        prefix = posixpath.normpath(posixpath.join(root, rel)) if root else posixpath.normpath(rel)
        for candidate in (prefix + ".py", prefix + "/__init__.py"):
            if candidate in available:
                found.add(candidate)
    return found


def python_imports(path, text, available):
    found = set()
    directory = posixpath.dirname(path)
    try:
        tree = ast.parse(text)
    except SyntaxError:
        tree = None
    if tree is not None:
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    parts = [p for p in alias.name.split(".") if p]
                    if parts:
                        found.update(_resolve_py_module(directory, parts, available))
                        found.update(_resolve_py_module(None, parts, available))
            elif isinstance(node, ast.ImportFrom):
                base_dir = directory
                if node.level > 0:
                    for _ in range(node.level - 1):
                        base_dir = posixpath.dirname(base_dir)
                    mod_parts = [p for p in (node.module or "").split(".") if p]
                    if mod_parts:
                        found.update(_resolve_py_module(base_dir, mod_parts, available))
                    for alias in node.names:
                        if alias.name != "*":
                            found.update(_resolve_py_module(base_dir, [*mod_parts, alias.name], available))
                elif node.module:
                    mod_parts = [p for p in node.module.split(".") if p]
                    for root in (directory, None):
                        found.update(_resolve_py_module(root, mod_parts, available))
                        for alias in node.names:
                            if alias.name != "*":
                                found.update(_resolve_py_module(root, [*mod_parts, alias.name], available))
    else:
        for mod in re.findall(r"(?m)^\s*(?:from|import)\s+([A-Za-z0-9_.]+)", text):
            parts = [p for p in mod.split(".") if p]
            if parts:
                found.update(_resolve_py_module(directory, parts, available))
                found.update(_resolve_py_module(None, parts, available))
    return found


def js_imports(path, text, available):
    found = set()
    directory = posixpath.dirname(path)
    specifiers = re.findall(
        r"""(?:import|export)\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]"""
        r"""|(?:import|require)\s*\(\s*['"]([^'"]+)['"]\s*\)""",
        text,
    )
    for left, right in specifiers:
        spec = (left or right).split("?", 1)[0].split("#", 1)[0]
        if not spec:
            continue
        bases = []
        if spec.startswith("."):
            bases.append(posixpath.normpath(posixpath.join(directory, spec)))
        elif spec.startswith(("core-rules/pi/", "scripts/")):
            bases.append(posixpath.normpath(spec))
        for base in bases:
            candidates = [base]
            stem, ext = posixpath.splitext(base)
            if ext in (".js", ".mjs", ".cjs"):
                candidates.extend(stem + alt for alt in (".ts", ".mts", ".cts", ".mjs", ".js"))
            elif not ext:
                candidates.extend(base + alt for alt in JS_EXTS)
                candidates.extend(base + "/index" + alt for alt in JS_EXTS)
            for candidate in candidates:
                if candidate in available:
                    found.add(candidate)
    return found


def dependencies(path, text, available):
    """Over-include literal references, source/load hints, and Python/JS imports."""
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
    if path.endswith(".py") and path.startswith("scripts/"):
        found.update(python_imports(path, text, available))
    if path.endswith(JS_EXTS) and path.startswith(("core-rules/pi/", "scripts/")):
        found.update(js_imports(path, text, available))
    return found


def source_closure(available):
    suites = {
        path for path in available
        if re.fullmatch(
            r"(?:scripts/tests|core-rules/(?:codex/)?hooks/tests|core-rules/skills/[^/]+/tests)/[A-Za-z0-9_-]+\.bats",
            path,
        )
        or re.fullmatch(r"core-rules/pi/[^/]+/[A-Za-z0-9_.-]+\.test\.mjs", path)
        or re.fullmatch(r"core-rules/skills/[^/]+/[^/]+/test_[A-Za-z0-9_]+\.py", path)
        or path in {
            "scripts/tests/test_attach_fastpath.py",
            "scripts/tests/test_release_verify_acl.py",
            "scripts/tests/test_receipt_diagnostics.py",
            "scripts/tests/test_usage_store_open.py",
        }
    }
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


def load_declared_inputs(tree):
    blob = tree.get(DECLARED_INPUTS_PATH)
    if not blob:
        return {}
    try:
        raw = json.loads(git("cat-file", "blob", blob).decode("utf-8"))
    except ValueError as exc:
        raise ValueError("uncertain-full: invalid declared-test-inputs.json") from exc
    if not isinstance(raw, dict):
        raise ValueError("uncertain-full: invalid declared-test-inputs.json")
    mapping = raw.get("declared_inputs", raw)
    if not isinstance(mapping, dict):
        raise ValueError("uncertain-full: invalid declared_inputs mapping")
    parsed = {}
    for pattern, owners in mapping.items():
        if pattern == "schema_version":
            continue
        if (not isinstance(pattern, str) or not pattern
                or not isinstance(owners, list) or not owners
                or any(not isinstance(item, str) or not item for item in owners)):
            raise ValueError("uncertain-full: malformed entry in declared-test-inputs.json")
        parsed[pattern] = tuple(owners)
    return parsed


def declared_owners(path, manifests):
    owners = set()
    for manifest in manifests:
        for pattern, suites in manifest.items():
            if path == pattern or fnmatch.fnmatchcase(path, pattern):
                owners.update(suites)
    return owners


def select_with_reasons(range_spec):
    selection_mode = os.environ.get("PROCESS_GATE_TEST_SELECTION", "auto") or "auto"
    if selection_mode == "full":
        raise ValueError("forced by PROCESS_GATE_TEST_SELECTION=full")
    if selection_mode != "auto":
        raise ValueError("uncertain-full: invalid PROCESS_GATE_TEST_SELECTION=" + selection_mode)
    if range_spec.count("..") != 1 or "..." in range_spec:
        raise ValueError("uncertain-full: unsupported range")
    left, right = range_spec.split("..")
    base = git("rev-parse", "--verify", left + "^{commit}").strip().decode()
    head = git("rev-parse", "--verify", right + "^{commit}").strip().decode()
    git("merge-base", "--is-ancestor", base, head)
    if git("rev-list", "--min-parents=2", base + ".." + head).strip():
        raise ValueError("uncertain-full: merge commit")
    commits = git("rev-list", base + ".." + head)
    # Inspect every commit, not just the net diff: reverted unknown changes and
    # both sides of renames must not disappear from the coverage decision.
    paths = set(git("diff-tree", "--stdin", "-r", "--no-commit-id", "--name-only",
                    "--no-renames", "-z", input=commits).decode().strip("\0").split("\0"))
    if not commits or not paths or "" in paths:
        raise ValueError("uncertain-full: empty range")
    for path in sorted(paths):
        if path.startswith(("scripts/lib/", "scripts/tests/helpers/git-fence/")):
            raise ValueError("uncertain-full: shared library or test fence: " + path)
        if path in PROTECTED_RUNNERS:
            raise ValueError("uncertain-full: runner or selector manifest: " + path)
    available = [inventory(ref) for ref in (base, head)]
    manifests = [load_declared_inputs(tree) for tree in available]
    consumers = {}
    for tree in available:
        for path, suites in source_closure(tree).items():
            consumers.setdefault(path, set()).update(suites)
    reasons = {}

    def add_suite(suite, tag):
        reasons.setdefault(suite, set()).add(tag)

    for smoke in CORE:
        add_suite(smoke, "fixed-smoke")

    for path in sorted(paths):
        if path.startswith(("scripts/lib/", "scripts/tests/helpers/git-fence/")):
            raise ValueError("uncertain-full: shared library or test fence: " + path)
        if path in PROTECTED_RUNNERS:
            raise ValueError("uncertain-full: runner or selector manifest: " + path)
        reached = consumers.get(path, set())
        for suite in reached:
            add_suite(suite, "import-consumer")
        declared = declared_owners(path, manifests)
        for suite in declared:
            add_suite(suite, "declared-fixture")
        is_narrowable_module = (
            (path.startswith("scripts/") and path.endswith((".py",) + JS_EXTS))
            or (path.startswith("core-rules/pi/") and path.endswith(JS_EXTS))
        )
        if re.fullmatch(r"scripts/tests/[A-Za-z0-9_-]+\.bats", path):
            add_suite(path, "explicit-owner")
        elif path == "CHANGELOG.md":
            pass  # Record scanners are already in CORE.
        elif path in {"scripts/" + name + ".sh" for name in LEAVES}:
            for suite in LEAVES[path[8:-3]]:
                add_suite("scripts/tests/" + suite + ".bats", "explicit-owner")
        elif declared:
            pass
        elif path.startswith(("scripts/tests/helpers/", "scripts/tests/fixtures/")) and reached:
            pass
        elif is_narrowable_module and reached:
            pass
        else:
            raise ValueError("uncertain-full: unmapped path: " + path)

    tests = set(reasons.keys())
    if any(not re.fullmatch(r"scripts/tests/[A-Za-z0-9_-]+\.bats", path) for path in tests):
        raise ValueError("uncertain-full: dependency reaches a core suite; full battery required")
    for tree in available:
        if not tests <= tree.keys():
            raise ValueError("uncertain-full: required test missing or not regular")
    ordered_reasons = {suite: sorted(reasons[suite]) for suite in sorted(tests)}
    return len(paths), ordered_reasons


def select(range_spec):
    changed_count, ordered_reasons = select_with_reasons(range_spec)
    suites = list(ordered_reasons.keys())
    return ["Tests: narrowed ({} files -> {} test files)".format(changed_count, len(suites)), *suites]


def _main(argv):
    explain = False
    positional = []
    for arg in argv:
        if arg == "--explain":
            explain = True
        else:
            positional.append(arg)
    if len(positional) != 1:
        raise IndexError("expected exactly one range argument")
    range_spec = positional[0]
    try:
        changed_count, ordered_reasons = select_with_reasons(range_spec)
    except (IndexError, ValueError, UnicodeError, OSError, subprocess.CalledProcessError) as exc:
        if explain:
            print(json.dumps({"status": "uncertain-full", "range": range_spec, "reason": str(exc)}, indent=2))
        print("process-gate: full tests — {}".format(exc), file=sys.stderr)
        return 1
    if explain:
        print(json.dumps({
            "status": "narrowed",
            "range": range_spec,
            "changed_files": changed_count,
            "selected_suites": len(ordered_reasons),
            "suites": ordered_reasons,
        }, indent=2))
        return 0
    suites = list(ordered_reasons.keys())
    print("\n".join(["Tests: narrowed ({} files -> {} test files)".format(changed_count, len(suites)), *suites]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(_main(sys.argv[1:]))
    except IndexError as exc:
        print("process-gate: full tests — {}".format(exc), file=sys.stderr)
        sys.exit(1)
