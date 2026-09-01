#!/usr/bin/env bash
# Validate decision-log entries against the canonical spec-042 grammar.
#
# Python's standard-library regular-expression engine is used so the supplied
# expressions remain unchanged while the shell entrypoint preserves filenames
# (including filenames containing spaces).
set -euo pipefail

exec python3 - "$@" <<'PY'
import json
import re
import sys


ENTRY = r"^- (?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \[L(?P<lvl>[1-5])\] \[(?P<kind>interpretation|pattern|scope|architectural)\] (?P<what>.+?)\. Reasoning: (?P<why>.+?)\. Alternatives considered: (?P<alt>.+?)\.(?P<surfaced> SURFACED INLINE)?$"

ENTRY_RE = re.compile(ENTRY)
# This probe is deliberately separate from ENTRY: it lets us name a kind that
# ENTRY rejects, while retaining the supplied ENTRY expression verbatim.
KIND_PROBE_RE = re.compile(
    r"^-?\s*\d{4}-\d{2}-\d{2}T\S*\s+\[L[^\]]+\]\s*\[([^\]]+)\]"
)
TIMESTAMP_RE = re.compile(r"^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z ")
LEVEL_RE = re.compile(
    r"^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \[L[1-5]\] "
)
KIND_SLOT_RE = re.compile(
    r"^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z "
    r"\[L[1-5]\] \[([^\]]+)\] "
)
ALLOWED_KINDS = {"interpretation", "pattern", "scope", "architectural"}


def meaningful_content_lines(lines: list[str]):
    """Yield the file-content denominator, excluding Markdown scaffolding."""
    in_html_comment = False
    fence_marker = None

    for line_number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if in_html_comment:
            if "-->" in line:
                in_html_comment = False
            continue
        if fence_marker is not None:
            if stripped.startswith(fence_marker):
                fence_marker = None
            continue
        if stripped.startswith("<!--"):
            if "-->" not in stripped[4:]:
                in_html_comment = True
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence_marker = stripped[:3]
            continue
        if not stripped or line.startswith("#"):
            continue
        yield line_number, line


def first_failure(line: str) -> str:
    """Name the first cheap canonical component check that fails."""
    if not line.startswith("- "):
        return 'missing leading "- " (annotations must use a # heading, HTML comment, or fenced block)'
    if TIMESTAMP_RE.match(line) is None:
        return "timestamp not ISO-8601 Z"
    if LEVEL_RE.match(line) is None:
        return "missing or invalid autonomy level [L1-L5]"

    kind_match = KIND_SLOT_RE.match(line)
    if kind_match is None:
        return "missing decision kind"
    kind = kind_match.group(1)
    if kind not in ALLOWED_KINDS:
        return f"unlisted kind [{kind}]"
    if ". Reasoning: " not in line:
        return "missing Reasoning:"
    if ". Alternatives: " in line:
        return 'Alternatives: (expected "Alternatives considered:")'
    if ". Alternatives considered: " not in line:
        return "missing Alternatives considered:"
    if not (line.endswith(".") or line.endswith(". SURFACED INLINE")):
        return "entry must end with a period"
    return "entry has invalid canonical spacing or an empty field"


def usage() -> int:
    print("Usage: scripts/check-decisions-log.sh [--json] <file>...", file=sys.stderr)
    return 2


def no_entries_note(path: str, state: str = "") -> str:
    prefix = f"{state}; " if state else ""
    return (
        f"note: {prefix}no decision entries found in file {path} "
        "(this validator does not and cannot check whether a decisions block "
        "was rendered in a session reply)"
    )


def empty_record(path: str) -> dict:
    return {
        "path": path,
        "scope": "file",
        "candidates": 0,
        "valid": 0,
        "kinds_ok": True,
        "surfaced": 0,
        "architectural": 0,
        "findings": [],
    }


def inspect_file(path: str) -> tuple[dict, bool]:
    record = empty_record(path)
    try:
        with open(path, "r", encoding="utf-8", newline="") as stream:
            contents = stream.read()
    except FileNotFoundError:
        record["findings"].append(no_entries_note(path, "file missing"))
        return record, True
    except IsADirectoryError:
        record["findings"].append("error: path is a directory")
        return record, False
    except (OSError, UnicodeError) as error:
        record["findings"].append(f"error: could not read file ({error})")
        return record, False

    if contents == "":
        record["findings"].append(no_entries_note(path, "file empty"))
        return record, True

    lines = contents.splitlines()
    candidates = list(meaningful_content_lines(lines))
    record["candidates"] = len(candidates)
    if not candidates:
        record["findings"].append(no_entries_note(path))

    for line_number, line in candidates:
        match = ENTRY_RE.match(line)
        if match is None:
            failure = first_failure(line)
            record["findings"].append(f"line {line_number}: {failure}")
        else:
            record["valid"] += 1
            if match.group("kind") == "architectural":
                record["architectural"] += 1
                if match.group("surfaced"):
                    record["surfaced"] += 1

        kind_match = KIND_PROBE_RE.match(line)
        if kind_match is not None:
            kind = kind_match.group(1)
            if kind not in ALLOWED_KINDS:
                record["kinds_ok"] = False
                kind_finding = f"line {line_number}: unlisted kind [{kind}]"
                if kind_finding not in record["findings"]:
                    record["findings"].append(kind_finding)

    if (
        record["architectural"] > 0
        and record["surfaced"] == record["architectural"]
    ):
        record["findings"].append(
            "SUSPICIOUS: all architectural entries carry SURFACED INLINE"
        )

    return record, True


def print_human(records: list[dict]) -> None:
    for record in records:
        line_groups = {}
        other_findings = []
        for finding in record["findings"]:
            line_match = re.match(r"^line (\d+):", finding)
            if line_match is None:
                other_findings.append(finding)
                continue
            line_number = int(line_match.group(1))
            line_groups.setdefault(line_number, []).append(finding)

        for line_number in list(line_groups)[:5]:
            for finding in line_groups[line_number]:
                print(f"  {finding}")
        if len(line_groups) > 5:
            print(f"  ...and {len(line_groups) - 5} more")
        for finding in other_findings:
            print(f"  {finding}")
        print(
            f"{record['path']}: candidates={record['candidates']} "
            f"valid={record['valid']} kinds_ok="
            f"{str(record['kinds_ok']).lower()} "
            f"surfaced={record['surfaced']}/{record['architectural']} "
            f"verdict={record['verdict']}"
        )


def main(argv: list[str]) -> int:
    json_mode = False
    paths = list(argv)
    if paths and paths[0] == "--json":
        json_mode = True
        paths = paths[1:]

    if not paths or any(path.startswith("--") for path in paths):
        return usage()

    records = []
    all_ok = True
    for path in paths:
        record, readable = inspect_file(path)
        record_ok = (
            readable
            and record["candidates"] == record["valid"]
            and record["kinds_ok"]
        )
        record["verdict"] = "PASS" if record_ok else "FAIL"
        records.append(record)
        if not record_ok:
            all_ok = False

    if json_mode:
        json.dump({"files": records, "ok": all_ok}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        print_human(records)

    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
PY
