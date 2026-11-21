#!/usr/bin/env python3
"""Report-only, heuristic source audit. Run optional tools only on trusted projects."""

import argparse
import ast
from bisect import bisect_right
from collections import Counter, defaultdict
from fnmatch import fnmatchcase
import hashlib
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess


JS = (".ts", ".tsx", ".js", ".mjs")
SOURCE = JS + (".py", ".sh")
DIET_EXTS = set(SOURCE) | {".bats", ".go", ".rs"}
CEREMONY_MARKER = re.compile(
    r"@patch\b|\b(?:vi\.mock|jest\.mock|unittest\.mock|waitForTimeout|time\.sleep)\b"
)
APP_ENTRIES = {
    "page", "layout", "loading", "error", "not-found", "route", "template",
    "default", "middleware", "proxy", "instrumentation", "opengraph-image",
}
SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", ".next", ".nuxt",
    ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".turbo", "coverage",
    "target", "dist", "build",
}
CONFIG_DIRS = {".claude", ".agents", ".pi", ".opencode"}
MIGRATION_DIRS = {"migrations", "migration", "drizzle", "prisma"}
TEST_DIRS = {"test", "tests", "__tests__"}
HELPER_DIRS = {"helpers", "__helpers__", "fixtures", "__fixtures__", "support"}
MAX_BYTES = 2 * 1024 * 1024
STACKS = {
    "javascript": ("package.json",), "python": ("pyproject.toml", "requirements.txt"),
    "rust": ("Cargo.toml",), "go": ("go.mod",),
}
TOKEN = re.compile(r"[\w-]+(?:\.[\w-]+)*")
JS_LEX = re.compile(r"//[^\n]*|/\*[\s\S]*?(?:\*/|\Z)|"
                    r"'(?:\\[\s\S]|[^'\\\n])*'|\"(?:\\[\s\S]|[^\"\\\n])*\"|"
                    r"`(?:\\[\s\S]|[^`\\])*`")
JS_SPEC = r"(?P<q>['\"`])(?P<ref>[^'\"`\n]+)(?P=q)"
JS_STATIC = re.compile(
    r"(?<![\w.])(?P<verb>import|export)\s*(?:(?:type\s+)?"
    r"(?:[\w$*,\s]|\{[^{};]*\})*?\bfrom\s*)?" + JS_SPEC
)
JS_CALL = re.compile(
    r"(?<![\w.])(?P<verb>import(?:\.meta\.glob(?:Eager)?)?|require(?:\.resolve)?)"
    r"\s*\(\s*(?:\[\s*)?" + JS_SPEC + r"(?P<concat>\s*\+)?"
)
SHELL_COMMAND = re.compile(
    r"(?:^|[;&(|])\s*(?:(?:exec|command)\s+)?"
    r"(?:\.?/[\w./-]+/)?(?:(?:source|\.|bash|sh|dash|zsh|node|tsx|python[\d.]*)\s+"
    r"(?:-[\w-]+\s+)*)?['\"]?(?P<ref>[^\s'\";&|()<>]+)"
)
PATH_WORD = re.compile(r"(?:\$\{?[A-Za-z_]\w*\}?/)?[\w.@/-]+(?:/\*)*")
SCRIPT_VAR = re.compile(r"^\$(?:\{(?:SCRIPT_DIR|HERE|PWD)\}|(?:SCRIPT_DIR|HERE|PWD))/")


def project_files(root, stats):
    def walk_error(_error):
        stats["unreadable"] += 1

    for directory, dirs, files in os.walk(root, onerror=walk_error, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name not in SKIP_DIRS
                         and not name.startswith(".env") and not (Path(directory) / name).is_symlink())
        for name in sorted(files):
            path = Path(directory) / name
            if (name == ".git" or name.startswith(".env") or path.suffix in {".pem", ".key"}
                    or path.is_symlink() or not path.is_file()):
                continue
            yield path.relative_to(root)


def read_text(root, path, stats):
    try:
        with (root / path).open("rb") as handle:
            data = handle.read(MAX_BYTES + 1)
    except OSError:
        stats["unreadable"] += 1
        return None
    if len(data) > MAX_BYTES:
        stats["oversized"] += 1
        return None
    if b"\0" in data:
        stats["binary_or_non_utf8"] += 1
        return None
    try:
        return data.decode("utf-8-sig")
    except UnicodeError:
        stats["binary_or_non_utf8"] += 1
        return None


def is_test(path):
    return bool(re.search(r"(?:^test_|_test$|\.(?:test|spec)$)", path.stem)) or (
        path.suffix in JS and path.name.startswith("test-"))


def test_context(path):
    return is_test(path) or bool(TEST_DIRS.intersection(path.parts[:-1]))


def convention_entry(path):
    dirs = set(path.parts[:-1])
    return (bool(dirs & (CONFIG_DIRS | MIGRATION_DIRS | TEST_DIRS)) or is_test(path)
            or ".config." in path.name
            or path.name in {"conftest.py", "__init__.py", "__main__.py", "manage.py"}
            or (path.suffix in JS and (
                "pages" in dirs or ("app" in dirs and path.stem in APP_ENTRIES)
                or path.stem in {"middleware", "proxy", "instrumentation"})))


class References:
    def __init__(self, sources):
        self.sources = sources
        self.by_name = defaultdict(set)
        for path in sources:
            for name in (path.stem, path.name):
                self.by_name[name].add(path)

    def literal(self, text, source):
        """Exact path first; otherwise a module-shaped string is only weak evidence."""
        if not re.fullmatch(r"[\w.@/-]+", text):
            return set()
        found = self.path(text, source.parent)
        if found:
            return found
        return self.by_name.get(text.rsplit("/", 1)[-1], set())

    def path(self, ref, base, root_search=True):
        """Resolve conventional relative paths, root/src aliases and index modules."""
        ref = ref.split("?", 1)[0].split("#", 1)[0]
        if not ref or ref.startswith("/") or ":" in ref:
            return set()
        if ref.startswith(("@/", "~/")):
            bases, ref = (Path("src"), Path()), ref[2:]
        elif ref.startswith(("./", "../")) or not root_search:
            bases = (base,)
        else:
            bases = (base, Path(), Path("src"))
        hits = set()
        for parent in bases:
            target = posixpath.normpath((parent / ref).as_posix())
            if target == ".." or target.startswith("../"):
                continue
            hits.update(self.sources.intersection({Path(target), Path(target) / "__init__.py"}))
            suffix = Path(target).suffix
            if suffix in (".js", ".mjs"):
                hits.update(self.sources.intersection(
                    Path(target).with_suffix(ext) for ext in (".ts", ".tsx")))
            if suffix not in SOURCE:
                hits.update(self.sources.intersection(Path(target + ext) for ext in SOURCE))
                # For JS directory imports, index files act as barrels.
                hits.update(self.sources.intersection(Path(target) / ("index" + ext) for ext in JS))
        return hits

    def pattern(self, ref, base):
        if not ref or not re.search(r"[\w-]", ref):
            return set()
        if ref.startswith(("@/", "~/")):
            bases, ref = (Path("src"), Path()), ref[2:]
        else:
            bases = (base,)
        matches = set()
        for parent in bases:
            pattern = posixpath.normpath((parent / ref).as_posix())
            variants = (pattern, pattern.replace("**/", ""))
            matches.update(path for path in self.sources if any(
                fnmatchcase(path.as_posix(), variant) or
                fnmatchcase(path.with_suffix("").as_posix(), variant) for variant in variants))
        return matches

    def text_hits(self, text):
        matches = set()
        for token in set(TOKEN.findall(text)):
            matches.update(self.by_name.get(token, ()))
            if "." in token:
                matches.update(self.by_name.get(token.rsplit(".", 1)[0], ()))
                for part in token.split("."):
                    matches.update(self.by_name.get(part, ()))
        return matches


def json_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from json_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from json_strings(item)


def package_entries(text, base, refs):
    config = json.loads(text)
    if not isinstance(config, dict):
        raise ValueError("package.json must contain an object")
    entries = set()
    for field in ("main", "module", "types", "bin", "exports", "scripts"):
        for value in json_strings(config.get(field)):
            specs = [value] if field != "scripts" else PATH_WORD.findall(value)
            for spec in specs:
                spec = SCRIPT_VAR.sub("./", spec)
                if "*" in spec:
                    entries.update(refs.pattern(spec, base))
                else:
                    entries.update(refs.path(spec, base, root_search=False))
    return entries


def python_refs(text, source, refs):
    static, literals = set(), set()
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, ast.Import):
            for alias in node.names:
                static.update(refs.path(alias.name.replace(".", "/"), Path()))
        elif isinstance(node, ast.ImportFrom):
            prefix = (node.module or "").replace(".", "/")
            base = source.parent
            for _ in range(1, node.level):
                base = base.parent
            specs = [prefix] + [posixpath.join(prefix, alias.name) for alias in node.names
                                if alias.name != "*"]
            for spec in filter(None, specs):
                static.update(refs.path(
                    "./" + spec if node.level else spec, base if node.level else Path()))
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            literals.update(refs.literal(node.value, source))
            if re.fullmatch(r"[\w]+(?:\.[\w]+)+", node.value):
                literals.update(refs.path(node.value.replace(".", "/"), Path()))
        elif isinstance(node, ast.JoinedStr) and node.values:
            first = node.values[0]
            if isinstance(first, ast.Constant) and first.value.endswith("."):
                literals.update(refs.pattern(first.value.replace(".", "/") + "*", Path()))
                literals.update(refs.pattern(first.value.replace(".", "/") + "*", Path("src")))
    return {path for path in static if path.suffix == ".py"}, literals


def javascript_refs(text, source, refs):
    static, barrels, dynamic, literals = set(), set(), set(), set()
    strings = []

    def clean(match):
        token = match.group()
        if token.startswith(("//", "/*")):
            return re.sub(r"[^\n]", " ", token)
        strings.append((match.start(), match.end()))
        literals.update(refs.literal(token[1:-1], source))
        return token

    code = JS_LEX.sub(clean, text)
    starts = [start for start, _ in strings]
    for pattern in (JS_STATIC, JS_CALL):
        for match in pattern.finditer(code):
            index = bisect_right(starts, match.start()) - 1
            if index >= 0 and match.start() < strings[index][1]:
                continue
            ref, verb = match["ref"], match["verb"]
            targets = {path for path in refs.path(ref, source.parent) if path.suffix in JS}
            if pattern is JS_STATIC:
                (barrels if verb == "export" else static).update(targets)
            elif verb == "require" and not match["concat"] and "${" not in ref:
                static.update(targets)
            else:
                dynamic.update(targets)
                glob = re.sub(r"\$\{[^}]*\}", "*", ref)
                if match["concat"]:
                    glob += "*"
                if "*" in glob:
                    dynamic.update(path for path in refs.pattern(glob, source.parent) if path.suffix in JS)
    # Import literals in an unreachable source are still static references,
    # not independent evidence of dynamic dispatch.
    return static, barrels, dynamic, literals - static - barrels


def shell_targets(text, source, refs):
    targets = set()
    for line in text.splitlines():
        for match in SHELL_COMMAND.finditer(line.split(" #", 1)[0]):
            ref = match["ref"]
            if ref.startswith("#") or "/" not in ref and Path(ref).suffix not in SOURCE:
                continue
            ref = SCRIPT_VAR.sub("./", ref)
            if ref.startswith("$"):
                continue
            targets.update(refs.path(ref, source.parent))
            if ref.startswith("./") and not match["ref"].startswith("$"):
                targets.update(refs.path(ref, Path()))
    return targets


def reachable(roots, edges):
    visited = set(roots)
    pending = list(roots)
    while pending:
        for target in edges.get(pending.pop(), ()):
            if target not in visited:
                visited.add(target)
                pending.append(target)
    return visited


def builtin(root):
    stats = Counter({key: 0 for key in ("scanned_text", "unreadable", "oversized",
                                       "binary_or_non_utf8", "parse_errors")})
    # Materialize once before walking references; imports can point forward.
    paths = list(project_files(root, stats))
    sources = {path for path in paths if path.suffix in SOURCE}
    refs = References(sources)
    roots = {path for path in sources if convention_entry(path)}
    edges, imported, helpers = {}, {}, defaultdict(dict)
    textual, dynamic, unscanned, incomplete_helpers = set(), set(), set(), set()
    source_loc, test_loc, test_sizes, ceremony = 0, 0, [], []
    for path in paths:
        helper = next((parent for parent in path.parents
                       if parent.name in HELPER_DIRS and test_context(parent)), None)
        text = read_text(root, path, stats)
        if text is None:
            unscanned.add(path)
            if helper:
                incomplete_helpers.add(helper)
            continue
        stats["scanned_text"] += 1
        if path.suffix in DIET_EXTS:
            loc = len(text.splitlines())
            if test_context(path) or path.suffix == ".bats":
                test_loc += loc
                test_sizes.append((loc, path.as_posix()))
                markers = len(CEREMONY_MARKER.findall(text))
                if markers >= 5:
                    ceremony.append((markers, loc, path.as_posix()))
            else:
                source_loc += loc
        textual.update(refs.text_hits(text) - {path})
        if helper:
            helpers[helper][path.relative_to(helper).as_posix()] = hashlib.sha256(
                text.encode("utf-8")).hexdigest()
        static, late = set(), set()
        try:
            if path.name == "package.json":
                roots.update(package_entries(text, path.parent, refs))
            elif path.suffix == ".py":
                static, late = python_refs(text, path, refs)
                late -= static
            elif path.suffix in JS:
                static, barrels, calls, literals = javascript_refs(text, path, refs)
                textual.update(barrels - {path})
                late = calls | literals
                imported[path] = static | calls
            elif path.suffix == ".sh" or (not path.suffix and re.match(
                    r"#![^\n]*\b(?:ba|da|z|k)?sh\b", text)):
                static = shell_targets(text, path, refs)
                if not path.suffix or re.search(r"^\s*case\s+.+\s+in\s*$", text, re.M):
                    roots.update(static - {path})
        except (SyntaxError, ValueError, RecursionError):
            stats["parse_errors"] += 1
            unscanned.add(path)
            continue
        if path.suffix == ".py":
            imported[path] = static
        if static:
            edges[path] = static - {path}
            textual.update(edges[path])
        dynamic.update(late - {path})

    findings = []

    def finding(kind, confidence, path, reason, **extra):
        findings.append(dict(kind=kind, confidence=confidence, path=path.as_posix(),
                             reason=reason, **extra))

    for path in sources - reachable(roots, edges):
        confidence, reason = ("HIGH", "No reference found in scanned project text")
        if path in dynamic:
            confidence, reason = ("LOW", "Possible string-addressed or dynamic reference")
        elif path in unscanned:
            confidence, reason = ("MEDIUM", "Source could not be fully scanned")
        elif path in textual:
            confidence, reason = ("MEDIUM", "References found, but no static path from an entry point")
        finding("unused_script" if path.suffix == ".sh" or "scripts" in path.parts[:-1]
                else "orphan_module", confidence, path, reason)
    for path, targets in imported.items():
        if is_test(path) and not any(not test_context(target) for target in targets):
            finding("zero_production_imports", "MEDIUM", path,
                    "No direct import of a local production module resolved")
    groups = defaultdict(list)
    for directory, contents in helpers.items():
        if directory not in incomplete_helpers:
            groups[tuple(sorted(contents.items()))].append(directory)
    for group in groups.values():
        first, *duplicates = sorted(group)
        for directory in duplicates:
            finding("duplicate_test_helpers", "MEDIUM", directory,
                    "Matches another test helper tree in relative paths and scanned content",
                    duplicate_of=first.as_posix())
    order = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
    findings.sort(key=lambda item: (order[item["confidence"]], item["path"], item["kind"]))
    test_diet = {
        "source_loc": source_loc,
        "test_loc": test_loc,
        "test_to_source_ratio": round(test_loc / source_loc, 2) if source_loc else None,
        "largest_test_files": [
            {"path": p, "loc": n} for n, p in sorted(test_sizes, key=lambda x: (-x[0], x[1]))[:10]
        ],
        "high_ceremony_tests": [
            {"path": p, "markers": m, "loc": n}
            for m, n, p in sorted(ceremony, key=lambda x: (-x[0], x[2]))[:10]
        ],
    }
    return findings, {**stats, "source_files": len(sources), "entry_points": len(roots)}, paths, test_diet


def analyzer(root, argv, accepted_codes, parse_knip=False):
    safe_keys = ("PATH", "HOME", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "LC_CTYPE", "USER", "SYSTEMROOT")
    env = {k: os.environ[k] for k in safe_keys if k in os.environ}
    env.update(NO_COLOR="1", CARGO_NET_OFFLINE="true")
    try:
        proc = subprocess.run(argv, cwd=root, capture_output=True, text=True,
                              errors="replace", timeout=90, check=False, env=env,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"analyzer_status": "error", "reason": "Analyzer timed out (90 seconds)"}
    except OSError as error:
        return {"analyzer_status": "error", "reason": error.strerror or type(error).__name__}
    result = {"analyzer_status": "ok" if proc.returncode in accepted_codes else "error",
              "exit_code": proc.returncode}
    if proc.stderr.strip():
        result["stderr"] = proc.stderr.strip()
    if parse_knip and result["analyzer_status"] == "ok":
        try:
            data = json.loads(proc.stdout)
            if (not isinstance(data, dict) or not isinstance(data.get("files"), list)
                    or not isinstance(data.get("issues"), list)
                    or (proc.returncode != 0 and not (data["files"] or data["issues"]))):
                raise ValueError("unrecognized Knip report")
        except (ValueError, RecursionError):
            result.update(analyzer_status="error", reason="Invalid Knip JSON report")
        else:
            result["output"] = data
            return result
    result["output"] = proc.stdout.strip()
    return result


def which(name):
    path = shutil.which(name)
    return os.path.abspath(path) if path else None


def optional_analyzers(root, stacks, paths):
    results = {}

    def run(name, stack, command, codes, *, parse_knip=False):
        if stack not in stacks:
            results[name] = {"analyzer_status": "not_applicable"}
        elif command is None:
            results[name] = {"analyzer_status": "unavailable", "reason": "Not installed"}
        else:
            results[name] = analyzer(root, command, codes, parse_knip=parse_knip)

    local_knip = root / "node_modules/.bin/knip"
    knip = (str(local_knip) if local_knip.is_file() and os.access(local_knip, os.X_OK)
            else which("knip")) if "javascript" in stacks else None
    run("knip", "javascript", [knip, "--production", "--reporter", "json"] if knip else None,
        {0, 1}, parse_knip=True)
    vulture = which("vulture") if "python" in stacks else None
    python = ["./" + path.as_posix() for path in paths if path.suffix == ".py"]
    if vulture and not python:
        results["vulture"] = {"analyzer_status": "not_applicable", "reason": "No Python source files"}
    elif vulture and sum(len(item) + 1 for item in python) > 65536:
        excludes = ",".join(sorted(SKIP_DIRS | CONFIG_DIRS))
        run("vulture", "python", [vulture, "--min-confidence", "80", "--exclude", excludes, "."], {0, 3})
    else:
        run("vulture", "python", [vulture, "--min-confidence", "80", *python] if vulture else None,
            {0, 3})
    cargo = which("cargo") if "rust" in stacks and which("cargo-machete") else None
    run("cargo-machete", "rust", [cargo, "machete"] if cargo else None, {0, 1})
    results["go"] = ({"analyzer_status": "unavailable", "reason": "No external Go analyzer configured"}
                     if "go" in stacks else {"analyzer_status": "not_applicable"})
    return results


def audit(root):
    findings, stats, paths, test_diet = builtin(root)
    present = set(paths)
    stacks = [stack for stack, manifests in STACKS.items()
              if any(Path(name) in present for name in manifests)]
    counts = Counter(item["confidence"] for item in findings)
    return {"schema_version": 1, "analyzers": optional_analyzers(root, stacks, paths),
            "summary": {"stacks": stacks, "counts": {key: counts[key] for key in
                        ("HIGH", "MEDIUM", "LOW")}, **stats},
            "test_diet": test_diet, "findings": findings}


def markdown(report):
    summary = report["summary"]
    diet = report["test_diet"]
    ratio_str = "n/a" if diet["test_to_source_ratio"] is None else f"{diet['test_to_source_ratio']:.2f}"
    lines = ["# Lean Audit", "", "Report only. Candidates are not deletion proof.", "",
             f"Stacks: {', '.join(summary['stacks']) or 'none detected'}",
             f"Scanned {summary['scanned_text']} text files; {summary['source_files']} source files; "
             f"{summary['entry_points']} protected entry points.",
             f"Skipped: {summary['oversized']} oversized, {summary['unreadable']} unreadable, "
             f"{summary['binary_or_non_utf8']} binary/non-UTF-8; {summary['parse_errors']} parse errors.",
             f"test-diet: source_loc={diet['source_loc']} test_loc={diet['test_loc']} "
             f"ratio={ratio_str} "
             f"high_ceremony={len(diet['high_ceremony_tests'])}",
             "Built-in checks exclude symlinks, dependency and build trees, and common secret file types.",
             "", "## Analyzers", ""]
    for name, result in report["analyzers"].items():
        status = result["analyzer_status"]
        note = (f" (exit {result['exit_code']}; details in --json)" if "exit_code" in result else "")
        if result.get("reason"):
            note += f" — {result['reason']}"
        lines.append(f"- {name}: **{status}**{note}")
    lines.extend(["", "## Candidates", "", ", ".join(
        f"{key}: {value}" for key, value in summary["counts"].items()), ""])
    for item in report["findings"]:
        lines.append(f"- **{item['confidence']}** {item['kind']} "
                     f"{json.dumps(item['path'])}: {item['reason']}")
    if not report["findings"]:
        lines.append("No candidates from built-in checks; see analyzer statuses for coverage.")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        prog="trellis lean-audit",
        description="Report unused-file candidates. Only audit trusted checkouts: installed "
                    "analyzers can load project configuration. Never run in pre-push.")
    parser.add_argument("--json", action="store_true", help="Emit a schema-versioned JSON report")
    parser.add_argument("project_root", metavar="PROJECT_ROOT", nargs="?", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.project_root.resolve()
    if not root.is_dir():
        parser.error(f"not a project directory: {args.project_root}")
    report = audit(root)
    print(json.dumps(report, indent=2) if args.json else markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
