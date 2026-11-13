#!/usr/bin/env python3
"""Refuse bare `[[ ]]` statements inside Bats tests and their helpers.

Under /bin/bash 3.2 (stock macOS), errexit ignores a failing `[[ ]]`
compound command, so a bare `[[ "$output" == *x* ]]` in the middle of a Bats
test or helper function cannot fail it there: the test stays green whatever
the assertion says. Bash 4.1+ made `[[` errexit-visible, which hid the gap on
the assertion shell of record (decisions-log 2026-11-10, "Bash 3.2
assertions"). `[[ ... ]] || false` has the same exit status on every bash and
fails the test on 3.2 too.

A statement is flagged when, inside a `@test` body or a function body, a line
starts with `[[`, its matching `]]` ends the statement (nothing but an
optional comment follows), and the previous line does not continue into it
(`&&`, `||`, `|`, `\\`). Heredoc bodies and multi-line quoted strings are
skipped: they are data or scripts for another shell, not this test.

Usage: lint-bats-conditionals.py [--fix] [--list-files] [PATH ...]
  With no PATH, checks every tracked *.bats file and the *.bash helpers under
  test directories. Exit 0 clean, 1 findings (path:line:text), 2 usage error.
  --fix appends ` || false` to each finding in place and exits 0.
"""
import re
import subprocess
import sys
from pathlib import Path

# Fixture suites whose source is itself the object under test.
EXCLUDED_PREFIXES = ("scripts/tests/fixtures/",)
FUNC_START = re.compile(
    r"^\s*(?:@test\s+(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')|(?:function\s+)?[A-Za-z_][A-Za-z0-9_:.-]*\s*\(\s*\))\s*\{\s*(?:#.*)?$"
)
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
CONTINUES = ("&&", "||", "|", "\\")


def tracked_files(root):
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.bats", "*.bash"],
        check=True, capture_output=True,
    ).stdout.decode()
    files = []
    for rel in out.split("\0"):
        if not rel or rel.startswith(EXCLUDED_PREFIXES):
            continue
        if rel.endswith(".bash") and "/tests/" not in "/" + rel:
            continue
        files.append(rel)
    return sorted(files)


def _scan_quotes(text, state):
    """Advance a minimal single/double-quote state over one line of text.

    Returns the new state (None, "'", '"') and the index of an unquoted `#`
    comment start, or -1. Enough to keep multi-line quoted scripts (bash -c
    '...', python -c "...") out of the scan; not a full shell lexer.
    """
    i, comment = 0, -1
    while i < len(text):
        ch = text[i]
        if state == "'":
            if ch == "'":
                state = None
        elif state == '"':
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = None
        else:
            if ch == "\\":
                i += 1
            elif ch in "'\"":
                state = ch
            elif ch == "#" and (i == 0 or text[i - 1] in " \t;"):
                comment = i
                break
        i += 1
    return state, comment


def _bare_conditional(code):
    """True when `code` is exactly one `[[ ... ]]` compound command."""
    stripped = code.strip()
    if not stripped.startswith("[[ ") and stripped != "[[":
        return False
    depth, state, i = 0, None, 0
    while i < len(stripped):
        ch = stripped[i]
        if state == "'":
            if ch == "'":
                state = None
        elif state == '"':
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = None
        elif ch == "\\":
            i += 1
        elif ch in "'\"":
            state = ch
        elif stripped.startswith("[[", i) and (i == 0 or stripped[i - 1] in " \t(!"):
            depth += 1
            i += 1
        elif stripped.startswith("]]", i) and (i + 2 == len(stripped) or stripped[i + 2] in " \t;)"):
            depth -= 1
            i += 1
            if depth == 0:
                return stripped[i + 1:].strip() == ""
        i += 1
    return False


def findings(path):
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    found = []
    in_func = False
    heredoc = None
    quote = None
    previous = ""
    for number, line in enumerate(lines, 1):
        if heredoc is not None:
            word, strip_tabs = heredoc
            if (line.lstrip("\t") if strip_tabs else line) == word:
                heredoc = None
            continue
        if quote is not None:
            quote, _ = _scan_quotes(line, quote)
            continue
        if not in_func:
            if FUNC_START.match(line):
                in_func = True
                previous = ""
            continue
        if line.startswith("}"):
            in_func = False
            continue
        new_quote, comment = _scan_quotes(line, None)
        code = line if comment < 0 else line[:comment]
        if (new_quote is None and not previous.endswith(CONTINUES)
                and _bare_conditional(code)):
            found.append((number, line))
        match = HEREDOC.search(code)
        if match and new_quote is None:
            heredoc = (match.group(3), match.group(1) == "-")
        quote = new_quote
        if code.strip():
            previous = code.rstrip()
    return found


def fix(path, numbers):
    text = Path(path).read_text(encoding="utf-8")
    lines = text.split("\n")
    for number in numbers:
        line = lines[number - 1]
        _, comment = _scan_quotes(line, None)
        if comment < 0:
            lines[number - 1] = line.rstrip() + " || false"
        else:
            code = line[:comment].rstrip()
            lines[number - 1] = code + " || false " + line[comment:]
    Path(path).write_text("\n".join(lines), encoding="utf-8")


def main(argv):
    do_fix = "--fix" in argv
    list_files = "--list-files" in argv
    paths = [arg for arg in argv if not arg.startswith("--")]
    if any(arg.startswith("--") and arg not in ("--fix", "--list-files") for arg in argv):
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    files = paths
    if not files:
        root = Path(subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True,
            cwd=Path(__file__).resolve().parent,
        ).stdout.decode().strip())
        files = [str(root / rel) for rel in tracked_files(root)]
    if list_files:
        print("\n".join(files))
        return 0
    total = 0
    for path in files:
        hits = findings(path)
        if not hits:
            continue
        total += len(hits)
        if do_fix:
            fix(path, [number for number, _ in hits])
            continue
        for number, line in hits:
            print(f"{path}:{number}:{line.strip()}")
    if do_fix:
        print(f"fixed {total} bare [[ ]] statement(s)", file=sys.stderr)
        return 0
    if total:
        print(
            f"{total} bare [[ ]] statement(s) inside Bats tests or helpers: bash 3.2 "
            "errexit ignores a false [[ ]], so these cannot fail there. Append "
            "' || false' (or an explicit '|| { echo ...; false; }').",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
