#!/usr/bin/env python3
"""Collect Linux per-suite file traces; summarize, then explicitly promote T32.

Targeted --trace samples are always incomplete. --collect runs the CI Bats
inventory, not the static stages or a qualified full-green gate. --promote-run
revalidates every receipt and log against HEAD before certifying coverage.
"""
from __future__ import annotations

import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from gate_receipts import digest
from release_metadata import source_digest
from gate_verdict import git

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = "scripts/tests/release-metadata-audit.json"
SUITE = re.compile(r"(?:scripts/tests|core-rules/(?:codex/)?hooks/tests|core-rules/skills/[^/]+/tests)/[A-Za-z0-9_.-]+\.bats")
META = re.compile(r"(?:^|[/:])(core-rules/VERSION|VERSION|CHANGELOG\.md|docs/adr/[A-Za-z0-9_.-]+\.md)$")


def observations(content: bytes, lines: list[str] | None = None) -> dict:
    paths = set()
    tag_reads = False
    for line in lines if lines is not None else content.decode("utf-8").splitlines():
        call = re.match(r"(?:\[pid\s+\d+\]\s*|\d+\s+)?(\w+)\(", line)
        if not call:
            if "resumed>" not in line:
                continue
            unresolved = True  # Targeted, unjoined fragments cannot prove irrelevance.
        else:
            unresolved = False
        # O_PATH probes still depend on the target. Only proven write-only
        # opens can be ignored; unfamiliar flags conservatively select both.
        if call and call[1] in ("open", "openat", "openat2"):
            flags = re.sub(r'"(?:\\.|[^"\\])*"|<[^>\n]*>', "", line)
            readable = re.search(r"\b(?:O_RDONLY|O_RDWR|O_PATH)\b", flags)
            if re.search(r"\bO_WRONLY\b", flags) and not readable:
                continue
            if not readable:
                unresolved = True
        fd_paths = [posixpath.normpath(path) for path in
                    re.findall(r"(?:\bAT_FDCWD|\b\d+)<(/[^>\n]+)>", line)]
        if any(path.endswith(" (deleted)") or "\\" in path or "<" in path for path in fd_paths):
            unresolved = True
        if call and call[1] in ("open", "openat", "openat2") and not fd_paths and re.search(r"=\s+\d+\s*$", line):
            unresolved = True  # A successful open without a kernel path may hide a symlink.
        operands = [ast.literal_eval(quoted) for quoted in re.findall(r'"(?:\\.|[^"\\])*"', line)]
        candidates = list(fd_paths)
        for operand in operands:
            if operand.startswith("/"):
                candidates.append(posixpath.normpath(operand))
            elif operand and fd_paths:
                candidates.extend(posixpath.normpath(posixpath.join(base, operand)) for base in fd_paths)
            else:
                candidates.append(posixpath.normpath(operand))
                if operand or not fd_paths or "AT_EMPTY_PATH" not in line:
                    unresolved = True
        if not candidates:
            unresolved = True
        for raw in candidates:
            operand = "/" + raw.lstrip("/")
            match = META.search(raw) or META.search(operand)
            if match:
                paths.add(match[1])
            if "packed-refs" in operand or "/refs/tags" in operand:
                tag_reads = True
        # Git objects hide logical paths. Unknown operands/dirfds must likewise
        # never certify a suite as unrelated to release metadata or tags.
        if unresolved or re.search(r"(?:/objects/|/pack-[0-9a-f]+\.(?:pack|idx)|/[0-9a-f]{2}/[0-9a-f]{38}\b)", line):
            paths.update(("VERSION", "core-rules/VERSION", "CHANGELOG.md", "docs/adr/*"))
            tag_reads = True
    return {"metadata": sorted(paths), "tag_reads": tag_reads, "trace_sha256": digest(content)}


def parsed_trace(content: bytes) -> dict:
    """Refuse empty, truncated, unfinished or unknown strace output."""
    pending = {}
    seen, exited = set(), set()
    joined = []
    for line in content.decode("utf-8").splitlines():
        if not line:
            continue
        match = re.fullmatch(r"(?:\[pid\s+(\d+)\]\s*|(\d+)\s+)?(.*)", line)
        pid, body = match[1] or match[2] or "main", match[3]
        if re.fullmatch(r"\+\+\+ (?:exited with \d+|killed by SIG\w+(?: \(core dumped\))?) \+\+\+", body):
            exited.add(pid)
            unfinished = pending.pop(pid, None)
            if unfinished:
                joined.append(unfinished[1])
            continue
        if re.fullmatch(r"--- SIG\w+ .* ---", body):
            continue
        if re.search(r'"\s*\.\.\.', body):
            raise ValueError("truncated strace string")
        resumed = re.match(r"<\.\.\. (\w+) resumed>(.*)", body)
        if resumed:
            unfinished = pending.pop(pid, None)
            if not unfinished or unfinished[0] != resumed[1] or not re.search(r"\)\s+= .+", body):
                raise ValueError("unmatched strace resume")
            joined.append(unfinished[1] + resumed[2])
        else:
            call = re.match(r"(\w+)\(", body)
            if not call or pid in pending:
                raise ValueError("unparseable strace line: " + line[:160])
            if body.endswith("<unfinished ...>"):
                pending[pid] = (call[1], body.removesuffix("<unfinished ...>"))
            elif not re.search(r"\)\s+= .+", body):
                raise ValueError("incomplete strace syscall")
            else:
                joined.append(body)
        seen.add(pid)
    if not joined or pending or not seen <= exited:
        raise ValueError("empty or incomplete strace log")
    return observations(content, joined)


def inventory(root: Path) -> list[str]:
    command = 'set -o pipefail; . "$1"; test_suites_core hooks; test_suites_core skills; '
    command += 'test_suites_for ci | while IFS= read -r suite; do printf "scripts/tests/%s.bats\\n" "$suite"; done'
    rows = subprocess.check_output(["bash", "-euc", command, "trace-inventory",
                                    str(root / "scripts/lib/test-suites.sh")], cwd=root, text=True).splitlines()
    suites = sorted(rows)
    if not suites or len(suites) != len(set(suites)) or any(not SUITE.fullmatch(suite) for suite in suites):
        raise ValueError("invalid or empty CI suite inventory")
    entries = {row.split(b"\t", 1)[1].decode(): row.split(b"\t", 1)[0]
               for row in git(root, "ls-tree", "-rz", "HEAD").split(b"\0") if row}
    if any(not entries.get(suite, b"").startswith((b"100644 blob ", b"100755 blob ")) for suite in suites):
        raise ValueError("inventory contains an untracked or nonregular suite")
    return suites


def current_source(root: Path) -> str:
    if (git(root, "diff", "--name-only", "HEAD", "--", ".", ":(exclude)" + MANIFEST).strip()
            or git(root, "ls-files", "--others", "--exclude-standard").strip()):
        raise ValueError("source checkout must be clean except for the audit manifest")
    return source_digest(root, "HEAD", MANIFEST)


def write_json(path: Path, data: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def summarize_run(root: Path, directory: Path, promote: bool = False) -> dict:
    receipt = (directory / "run.json").read_bytes()
    run = json.loads(receipt)
    suites = inventory(root)
    expected = current_source(root)
    if (run.get("schema") != 1 or run.get("scope") != "ci" or run.get("finished") is not True
            or run.get("source_digest") != expected or run.get("finished_source_digest") != expected
            or source_digest(root, run["traced_revision"], MANIFEST) != expected):
        raise ValueError("incomplete collection or source digest drift")
    if run.get("inventory") != suites or set(run.get("traces", {})) != set(suites):
        raise ValueError("missing suite log or inventory drift")
    found = {}
    for ordinal, suite in enumerate(suites, 1):
        entry = run["traces"][suite]
        relative = "logs/{:04d}.strace".format(ordinal)
        path = directory / relative
        if (entry.get("log") != relative or type(entry.get("exit")) is not int or entry["exit"] != 0
                or path.is_symlink() or not path.is_file()):
            raise ValueError("missing suite log or nonzero strace exit: " + suite)
        content = path.read_bytes()
        if entry.get("trace_sha256") != digest(content):
            raise ValueError("trace digest mismatch: " + suite)
        found[suite] = parsed_trace(content)
    return {"schema": 1, "complete": promote, "scope": "full-ci",
            "traced_revision": run["traced_revision"], "source_digest": expected,
            "trace_run_sha256": digest(receipt), "inventory": suites,
            "suites": sorted(suite for suite, entry in found.items() if entry["metadata"] or entry["tag_reads"]),
            "observations": found}


def trace_suite(root: Path, directory: Path, suite: str, ordinal: int, tools: dict) -> dict:
    relative = "logs/{:04d}.strace".format(ordinal)
    log = directory / relative
    with tempfile.TemporaryDirectory(prefix="suite-", dir=directory / "sandboxes") as temporary:
        sandbox = Path(temporary).resolve()
        for name in ("home", "trellis", "tmp", "bin"):
            (sandbox / name).mkdir(mode=0o700)
        config = sandbox / "global.gitconfig"
        config.write_text("[user]\n name = Trace Fixture\n email = fixture@trellis.invalid\n[commit]\n gpgSign = false\n[tag]\n gpgSign = false\n")
        config.chmod(0o600)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("GIT_", "TRELLIS_", "PROCESS_GATE_", "HC_", "BATS_", "PI_", "XDG_"))}
        real_git, real_mktemp, real_py = (os.path.realpath(tools["git"]), os.path.realpath(tools["mktemp"]),
                                          os.path.realpath(sys.executable))
        env.update(HOME=str(sandbox / "home"), TRELLIS_HOME=str(sandbox / "trellis"),
                   TMPDIR=str(sandbox / "tmp"), BATS_TMPDIR=str(sandbox / "tmp"),
                   GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0",
                   TRELLIS_ATTACH_POSTJOB="off", TRELLIS_TEST_GIT_FENCE_ROOT=str(sandbox),
                   TRELLIS_TEST_REAL_GIT=real_git, TRELLIS_TEST_REAL_MKTEMP=real_mktemp,
                   TRELLIS_TEST_REAL_PYTHON=real_py,
                   TRELLIS_CONFORMANCE_TEST_ROOT=str(sandbox / "conformance"),
                   TRELLIS_T9_TEST_ROOT=str(sandbox / "skill-eval"),
                   AGGREGATE_SCRIPT=str(root / "scripts/tests/fixtures/skill-eval-v2/aggregate_benchmark.py"))
        pins = "\n".join("{}={}".format(key, shlex.quote(str(value))) for key, value in (
            ("TRELLIS_TEST_GIT_FENCE_ROOT", sandbox), ("TRELLIS_TEST_REAL_GIT", real_git),
            ("TRELLIS_TEST_REAL_MKTEMP", real_mktemp), ("TRELLIS_TEST_REAL_PYTHON", real_py)))
        for name in ("git", "mktemp"):
            shim = sandbox / "bin" / name
            shim.write_text("#!/bin/bash\n# trellis-test-fence-launcher-v1\n" + pins
                            + "\nexport TRELLIS_TEST_GIT_FENCE_ROOT TRELLIS_TEST_REAL_GIT TRELLIS_TEST_REAL_MKTEMP TRELLIS_TEST_REAL_PYTHON\n"
                            + "exec /bin/bash " + shlex.quote(str(root / "scripts/tests/helpers/git-fence" / name)) + ' "$@"\n')
            shim.chmod(0o700)
        (sandbox / "bin/python3").symlink_to(real_py)
        env["PATH"] = str(sandbox / "bin") + os.pathsep + os.environ["PATH"]
        command = [tools["strace"], "-f", "-yy", "-s", "4096", "-e", "trace=%file",
                   "-o", str(log), "--", tools["bats"], suite]
        with (directory / "logs/{:04d}.output".format(ordinal)).open("wb") as output:
            result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
    return {"log": relative, "exit": result.returncode,
            "trace_sha256": digest(log.read_bytes()) if log.is_file() else None}


def collect(root: Path, directory: Path, workers: int) -> dict:
    if sys.platform != "linux":
        raise ValueError("full tracing requires Linux strace; promotion is portable")
    if workers < 1:
        raise ValueError("workers must be positive")
    directory = directory.resolve()
    if directory == root.resolve() or root.resolve() in directory.parents:
        raise ValueError("trace output must be outside the source checkout")
    suites, initial = inventory(root), current_source(root)
    tools = {name: shutil.which(name) for name in ("strace", "bats", "git", "mktemp")}
    if not all(tools.values()):
        raise ValueError("strace, bats, git and mktemp must be installed")
    directory.mkdir(mode=0o700)  # Never reuse an old collection directory.
    for name in ("logs", "sandboxes"):
        (directory / name).mkdir(mode=0o700)
    run = {"schema": 1, "scope": "ci", "finished": False, "source_digest": initial,
           "traced_revision": git(root, "rev-parse", "HEAD").decode().strip(),
           "inventory": suites, "workers": workers, "traces": {}}
    write_json(directory / "run.json", run)
    def work(item):
        ordinal, suite = item
        try:
            return suite, trace_suite(root, directory, suite, ordinal, tools)
        except (OSError, subprocess.SubprocessError) as exc:
            return suite, {"exit": 1, "error": str(exc)}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for suite, entry in pool.map(work, enumerate(suites, 1)):
            run["traces"][suite] = entry
            write_json(directory / "run.json", run)
            print("trace: {} exit={}".format(suite, entry["exit"]), flush=True)
    run["finished"] = True
    run["finished_source_digest"] = source_digest(root, "HEAD", MANIFEST)
    write_json(directory / "run.json", run)
    return summarize_run(root, directory)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--trace", action="append", metavar="SUITE=LOG")
    modes.add_argument("--collect", type=Path, metavar="NEW_DIRECTORY")
    modes.add_argument("--run", type=Path, metavar="DIRECTORY")
    modes.add_argument("--promote-run", type=Path, metavar="DIRECTORY")
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        if args.trace:
            found = {}
            for item in args.trace:
                suite, path = item.split("=", 1)
                if not SUITE.fullmatch(suite) or suite in found:
                    raise ValueError("each trace must name a distinct bats suite")
                found[suite] = observations(Path(path).read_bytes())
            result = {"schema": 1, "complete": False, "scope": "targeted",
                      "traced_revision": git(root, "rev-parse", args.revision).decode().strip(),
                      "source_digest": source_digest(root, args.revision, MANIFEST),
                      "suites": sorted(suite for suite, entry in found.items() if entry["metadata"] or entry["tag_reads"]),
                      "observations": found}
        elif args.collect:
            result = collect(root, args.collect, args.workers)
        else:
            result = summarize_run(root, args.run or args.promote_run, promote=args.promote_run is not None)
        output = args.output or ((args.collect or args.run) / "audit.json" if args.collect or args.run else root / MANIFEST)
        # Recheck immediately before the explicit certification write.
        if args.promote_run and current_source(root) != result["source_digest"]:
            raise ValueError("source digest drift before promotion")
        write_json(output, result)
        return 0
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, SyntaxError, subprocess.SubprocessError) as exc:
        print("trace-release-metadata: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
