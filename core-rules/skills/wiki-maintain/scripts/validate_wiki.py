#!/usr/bin/env python3
"""Validate WikiSkill qualification evidence and project-local wiki records.

The read-only commands never invoke version control, a network client, or another
process.  ``mark-stale`` is deliberately narrower than a general wiki editor: it
can only replace existing ``active`` status values with ``stale`` in a pattern
frontmatter block and its existing index row.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from datetime import date
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import Any, Iterable, Iterator, Sequence
from urllib.parse import unquote, urlsplit

fcntl: ModuleType | None
try:
    import fcntl as _fcntl
except ImportError:  # pragma: no cover - SAFETY: _wiki_lock rejects None before wiki access.
    fcntl = None
else:
    fcntl = _fcntl


SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
PROVENANCE_RE = re.compile(
    r"^- ([0-9]{4}-[0-9]{2}-[0-9]{2}) (refine|reactivate) "
    r"prior=sha256:([0-9a-f]{64}) — (\S.*)$"
)
SOURCE_RE = re.compile(r"^gotchas\.md#[A-Za-z0-9][A-Za-z0-9._:-]*$")
LINK_RE = re.compile(r"\[([^\]\n]+)\]\(([^)\s]+)(?:\s+\"[^\"\n]*\")?\)")
INDEX_LINK_RE = re.compile(r"^\[([^\]]+)\]\(([^)]+)\)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
PR_URL_RE = re.compile(
    r"^https://[^/\s|]+/(?:[^/?#\s|]+/)*(?:pull|pulls|merge_requests?)/[0-9]+/?(?:[?#][^\s|]*)?$"
)

INDEX_HEADER = "| slug | status | source | updated |"
INDEX_DIVIDER = "|---|---|---|---|"
INDEX_PREFIX = (
    "# Wiki pattern index",
    "",
    "On-demand catalog of evidence-backed operational patterns. The wiki is not injected at session start.",
    "",
    INDEX_HEADER,
    INDEX_DIVIDER,
)
REQUIRED_SECTIONS = (
    "Failure mode",
    "Root cause",
    "Working path",
    "Dead ends",
    "Evidence",
)
STATUSES = frozenset({"active", "stale", "retired"})
QUALIFICATION_FIELDS = frozenset(
    {
        "schema_version",
        "source",
        "pattern_key",
        "occurrences",
        "preconditions",
        "inputs_needed",
        "inputs",
        "steps",
        "result",
        "verification",
        "secret_values_present",
    }
)
SECRET_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
)


class ContractMalformed(ValueError):
    """The command input cannot be interpreted as a contract instance."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class JsonArgumentParser(argparse.ArgumentParser):
    """Turn argparse usage failures into the CLI's JSON malformed contract."""

    def error(self, message: str) -> None:
        raise ContractMalformed("arguments", message)


@dataclass(frozen=True)
class IndexRow:
    slug: str
    status: str
    source_label: str
    source_target: str
    updated: str
    line_index: int


@dataclass(frozen=True)
class PatternPage:
    slug: str
    status: str
    path: Path
    text: str
    status_line_index: int
    gotcha_targets: tuple[str, ...]
    broken_links: tuple[str, ...]
    sha256: str
    provenance: tuple[str, ...]
    substantive_content: str


@dataclass
class WikiState:
    root: Path
    index_path: Path
    index_text: str | None
    rows: dict[str, IndexRow]
    patterns: dict[str, PatternPage]
    structural_errors: list[dict[str, str]]
    semantic_errors: list[dict[str, str]]

    @property
    def errors(self) -> list[dict[str, str]]:
        return self.structural_errors + self.semantic_errors


def _issue(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def _safe_root(raw: str) -> Path:
    try:
        root = Path(raw).expanduser().resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ContractMalformed("root", "project root does not resolve") from exc
    if not root.is_dir():
        raise ContractMalformed("root", "project root is not a directory")
    return root


@contextmanager
def _wiki_lock(root: Path, *, exclusive: bool) -> Iterator[None]:
    """Coordinate wiki readers and the status writer without creating lock files."""
    fcntl_binding = fcntl
    if fcntl_binding is None:
        raise ContractMalformed("lock", "wiki locking is unavailable")

    wiki = root / "wiki"
    lock_path = wiki if wiki.is_dir() and not wiki.is_symlink() else root
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(lock_path, flags)
    except OSError as exc:
        raise ContractMalformed("lock", "wiki lock cannot be opened") from exc
    try:
        try:
            operation = fcntl_binding.LOCK_EX if exclusive else fcntl_binding.LOCK_SH
            fcntl_binding.flock(descriptor, operation)
        except OSError as exc:
            raise ContractMalformed("lock", "wiki lock cannot be acquired") from exc
        try:
            yield
        finally:
            try:
                fcntl_binding.flock(descriptor, fcntl_binding.LOCK_UN)
            except OSError:
                pass
    finally:
        os.close(descriptor)


@contextmanager
def _wiki_locks(roots: Sequence[Path], *, exclusive: bool) -> Iterator[None]:
    """Acquire multiple project wiki locks in a stable order."""
    unique_roots = sorted(set(roots), key=os.fspath)
    with ExitStack() as stack:
        for root in unique_roots:
            stack.enter_context(_wiki_lock(root, exclusive=exclusive))
        yield


def _relative(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return "<outside-root>"


def _is_plain_file(path: Path) -> bool:
    try:
        mode = path.lstat().st_mode
    except OSError:
        return False
    return stat.S_ISREG(mode) and not path.is_symlink()


def _read_text(path: Path) -> str:
    try:
        if not _is_plain_file(path):
            raise ContractMalformed("file", "required input is not a regular file")
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ContractMalformed("encoding", "required input is not UTF-8") from exc
    except OSError as exc:
        raise ContractMalformed("read", "required input cannot be read") from exc


def _safe_string(value: Any, *, allow_empty: bool) -> bool:
    if not isinstance(value, str):
        return False
    if not allow_empty and not value.strip():
        return False
    return not any(ord(character) < 32 and character not in "\t\n\r" for character in value)


def _safe_string_list(value: Any) -> bool:
    return isinstance(value, list) and all(
        _safe_string(item, allow_empty=True) for item in value
    )


def _secret_value_detected(value: Any) -> bool:
    if isinstance(value, str):
        return any(pattern.search(value) for pattern in SECRET_PATTERNS)
    if isinstance(value, list):
        return any(_secret_value_detected(item) for item in value)
    if isinstance(value, dict):
        return any(_secret_value_detected(item) for item in value.values())
    return False


def _valid_evidence_ref(value: str) -> bool:
    if "\\" in value or "#" not in value:
        return False
    path_text, anchor = value.split("#", 1)
    if not path_text.endswith(".md") or not anchor:
        return False
    path = PurePosixPath(path_text)
    return (
        not path.is_absolute()
        and all(part not in {"", ".", ".."} for part in path.parts)
        and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", anchor))
    )


def _validate_qualification_object(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractMalformed("evidence-schema", "evidence must be a JSON object")
    if set(value) != QUALIFICATION_FIELDS:
        raise ContractMalformed(
            "evidence-schema", "evidence object does not have the exact required fields"
        )
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ContractMalformed("evidence-schema", "schema_version must be 1")
    if not _safe_string(value["source"], allow_empty=False) or not SOURCE_RE.fullmatch(
        value["source"]
    ):
        raise ContractMalformed("evidence-schema", "source must be a gotchas.md anchor")
    if not _safe_string(value["pattern_key"], allow_empty=False) or not SLUG_RE.fullmatch(
        value["pattern_key"]
    ):
        raise ContractMalformed("evidence-schema", "pattern_key must be a lower-case slug")

    occurrences = value["occurrences"]
    if not isinstance(occurrences, list):
        raise ContractMalformed("evidence-schema", "occurrences must be an array")
    for occurrence in occurrences:
        if not isinstance(occurrence, dict) or set(occurrence) != {"ref", "recorded"}:
            raise ContractMalformed(
                "evidence-schema", "each occurrence must contain ref and recorded"
            )
        if not _safe_string(occurrence["ref"], allow_empty=False) or not _valid_evidence_ref(
            occurrence["ref"]
        ):
            raise ContractMalformed("evidence-schema", "occurrence ref is malformed")
        if type(occurrence["recorded"]) is not bool:
            raise ContractMalformed("evidence-schema", "occurrence recorded must be boolean")

    if not _safe_string_list(value["preconditions"]):
        raise ContractMalformed("evidence-schema", "preconditions must be a string array")
    if type(value["inputs_needed"]) is not bool:
        raise ContractMalformed("evidence-schema", "inputs_needed must be boolean")
    if not _safe_string_list(value["inputs"]):
        raise ContractMalformed("evidence-schema", "inputs must be a string array")

    steps = value["steps"]
    if not isinstance(steps, list):
        raise ContractMalformed("evidence-schema", "steps must be an array")
    for step in steps:
        if not isinstance(step, dict) or set(step) != {"order", "action"}:
            raise ContractMalformed(
                "evidence-schema", "each step must contain order and action"
            )
        if type(step["order"]) is not int or step["order"] < 1:
            raise ContractMalformed("evidence-schema", "step order must be a positive integer")
        if not _safe_string(step["action"], allow_empty=True):
            raise ContractMalformed("evidence-schema", "step action must be a string")

    if not _safe_string(value["result"], allow_empty=True):
        raise ContractMalformed("evidence-schema", "result must be a string")
    if not _safe_string(value["verification"], allow_empty=True):
        raise ContractMalformed("evidence-schema", "verification must be a string")
    if type(value["secret_values_present"]) is not bool:
        raise ContractMalformed(
            "evidence-schema", "secret_values_present must be boolean"
        )
    return value


def _nonempty_strings(values: Iterable[str]) -> list[str]:
    return [value for value in values if value.strip()]


def _qualification_decision(evidence: dict[str, Any]) -> tuple[dict[str, Any], int]:
    secret_bearing = evidence["secret_values_present"] or _secret_value_detected(evidence)
    if secret_bearing:
        return (
            {
                "schema_version": 1,
                "source": evidence["source"],
                "pattern_key": evidence["pattern_key"],
                "predicate": "none",
                "occurrences": [],
                "steps": [],
                "preconditions": [],
                "inputs": [],
                "result": "",
                "verification": "",
                "verdict": "retain-as-gotcha",
                "reasons": ["secret-values-present"],
            },
            1,
        )

    recorded_occurrences: list[dict[str, Any]] = []
    recorded_refs: set[str] = set()
    for occurrence in evidence["occurrences"]:
        if occurrence["recorded"] and occurrence["ref"] not in recorded_refs:
            recorded_refs.add(occurrence["ref"])
            recorded_occurrences.append(dict(occurrence))

    step_orders = [step["order"] for step in evidence["steps"]]
    ordered_steps = (
        len(step_orders) >= 3
        and step_orders == list(range(1, len(step_orders) + 1))
        and all(step["action"].strip() for step in evidence["steps"])
    )
    preconditions = _nonempty_strings(evidence["preconditions"])
    inputs = _nonempty_strings(evidence["inputs"])
    path_complete = (
        ordered_steps
        and bool(preconditions)
        and (not evidence["inputs_needed"] or bool(inputs))
        and bool(evidence["result"].strip())
        and bool(evidence["verification"].strip())
    )

    if len(recorded_occurrences) >= 2:
        predicate = "recurrence"
        verdict = "qualify"
        reasons: list[str] = []
        exit_code = 0
    elif path_complete:
        predicate = "repeatable-path"
        verdict = "qualify"
        reasons = []
        exit_code = 0
    else:
        predicate = "none"
        verdict = "retain-as-gotcha"
        reasons = []
        if len(recorded_occurrences) < 2:
            reasons.append("insufficient-recorded-occurrences")
        if not ordered_steps:
            reasons.append("procedure-needs-three-ordered-steps")
        if not preconditions:
            reasons.append("procedure-needs-preconditions")
        if evidence["inputs_needed"] and not inputs:
            reasons.append("procedure-needs-inputs")
        if not evidence["result"].strip():
            reasons.append("procedure-needs-result")
        if not evidence["verification"].strip():
            reasons.append("procedure-needs-verification")
        exit_code = 1

    decision = {
        "schema_version": 1,
        "source": evidence["source"],
        "pattern_key": evidence["pattern_key"],
        "predicate": predicate,
        "occurrences": recorded_occurrences,
        "steps": [dict(step) for step in evidence["steps"]],
        "preconditions": preconditions,
        "inputs": inputs,
        "result": evidence["result"],
        "verification": evidence["verification"],
        "verdict": verdict,
        "reasons": reasons,
    }
    return decision, exit_code


def _run_qualify(evidence_path: str) -> int:
    original = Path(evidence_path).expanduser()
    try:
        if stat.S_ISLNK(original.lstat().st_mode):
            raise ContractMalformed("evidence", "evidence file must not be a symlink")
        resolved = original.resolve(strict=True)
        if not _is_plain_file(original):
            raise ContractMalformed("evidence", "evidence file must be a regular non-symlink file")
        raw = _read_text(resolved)
        parsed = json.loads(raw)
    except ContractMalformed:
        raise
    except (OSError, RuntimeError) as exc:
        raise ContractMalformed("evidence", "evidence file does not resolve") from exc
    except json.JSONDecodeError as exc:
        raise ContractMalformed("json", "evidence is not valid JSON") from exc
    evidence = _validate_qualification_object(parsed)
    decision, exit_code = _qualification_decision(evidence)
    _emit(decision)
    return exit_code


def _split_table_row(line: str) -> list[str] | None:
    if not line.startswith("|") or not line.endswith("|"):
        return None
    cells = line[1:-1].split("|")
    if len(cells) != 4:
        return None
    return [cell.strip() for cell in cells]


def _parse_local_target(
    target: str, *, base: Path, root: Path
) -> tuple[Path, str] | None:
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc or parsed.query or not parsed.fragment:
        return None
    decoded_path = unquote(parsed.path)
    anchor = unquote(parsed.fragment)
    if not decoded_path or "\\" in decoded_path or "\x00" in decoded_path or not anchor:
        return None
    path = PurePosixPath(decoded_path)
    if path.is_absolute():
        return None
    try:
        unresolved = Path(os.path.abspath(base / Path(*path.parts)))
        relative = unresolved.relative_to(root)
        current = root
        for part in relative.parts:
            current /= part
            if current.is_symlink():
                return None
        resolved = unresolved.resolve(strict=False)
        resolved.relative_to(root)
    except (OSError, RuntimeError, ValueError):
        return None
    return resolved, anchor


def _markdown_anchor_base(title: str) -> str:
    value = title.strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return value.replace(" ", "-")


def _anchors(text: str) -> set[str]:
    result: set[str] = set()
    counts: dict[str, int] = {}
    for line in text.splitlines():
        heading = HEADING_RE.fullmatch(line)
        if heading:
            base = _markdown_anchor_base(heading.group(2))
            if base:
                seen = counts.get(base, 0)
                result.add(base if seen == 0 else f"{base}-{seen}")
                counts[base] = seen + 1
        for explicit in re.finditer(
            r"<a\s+(?:id|name)=[\"']([^\"']+)[\"'](?:\s*></a>|\s*/?>)",
            line,
            flags=re.IGNORECASE,
        ):
            result.add(explicit.group(1))
    return result


def _link_resolves(path: Path, anchor: str, cache: dict[Path, set[str] | None]) -> bool:
    if path not in cache:
        if not _is_plain_file(path):
            cache[path] = None
        else:
            try:
                cache[path] = _anchors(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                cache[path] = None
    anchors = cache[path]
    return anchors is not None and anchor in anchors


def _parse_index(root: Path, errors: list[dict[str, str]]) -> tuple[str | None, dict[str, IndexRow]]:
    index_path = root / "wiki" / "index.md"
    if not _is_plain_file(index_path):
        errors.append(_issue("missing-index", "wiki/index.md", "index is missing or not a regular file"))
        return None, {}
    try:
        text = index_path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        errors.append(_issue("unreadable-index", "wiki/index.md", "index is not readable UTF-8"))
        return None, {}

    lines = text.splitlines()
    while len(lines) > len(INDEX_PREFIX) and lines[-1] == "":
        lines.pop()
    if tuple(lines[: len(INDEX_PREFIX)]) != INDEX_PREFIX:
        errors.append(_issue("index-contract", "wiki/index.md", "index header or table shape is not exact"))
        return text, {}
    if lines.count(INDEX_HEADER) != 1 or lines.count(INDEX_DIVIDER) != 1:
        errors.append(
            _issue(
                "index-contract",
                "wiki/index.md",
                "index must contain exactly one catalog table",
            )
        )

    rows: dict[str, IndexRow] = {}
    for line_index, line in enumerate(lines[len(INDEX_PREFIX) :], start=len(INDEX_PREFIX)):
        cells = _split_table_row(line)
        if cells is None:
            errors.append(_issue("index-row", "wiki/index.md", "index contains a malformed data row"))
            continue
        slug_cell, status_value, source_cell, updated = cells
        slug_link = INDEX_LINK_RE.fullmatch(slug_cell)
        source_link = INDEX_LINK_RE.fullmatch(source_cell)
        if slug_link is None:
            errors.append(_issue("index-slug-link", "wiki/index.md", "slug cell must be a pattern link"))
            continue
        slug, pattern_target = slug_link.groups()
        if not SLUG_RE.fullmatch(slug):
            errors.append(_issue("index-slug", "wiki/index.md", "index slug is malformed"))
            continue
        if pattern_target != f"patterns/{slug}.md":
            errors.append(_issue("index-pattern-link", "wiki/index.md", "pattern link does not match its slug"))
        if slug in rows:
            errors.append(_issue("duplicate-slug", "wiki/index.md", "index contains a duplicate slug"))
            continue
        if status_value not in STATUSES:
            errors.append(_issue("index-status", "wiki/index.md", "index status is invalid"))
        if source_link is None:
            errors.append(_issue("index-source", "wiki/index.md", "source cell must be a Markdown link"))
            source_label, source_target = "", ""
        else:
            source_label, source_target = source_link.groups()
            resolved_source = _parse_local_target(
                source_target, base=index_path.parent, root=root
            )
            if resolved_source is None or resolved_source[0] != root / "gotchas.md":
                errors.append(_issue("index-source", "wiki/index.md", "source must target a root gotchas.md anchor"))
        if not DATE_RE.fullmatch(updated):
            errors.append(_issue("index-date", "wiki/index.md", "updated date is not ISO YYYY-MM-DD"))
        else:
            try:
                if date.fromisoformat(updated).isoformat() != updated:
                    raise ValueError
            except ValueError:
                errors.append(_issue("index-date", "wiki/index.md", "updated date is not a real calendar date"))
        rows[slug] = IndexRow(
            slug=slug,
            status=status_value,
            source_label=source_label,
            source_target=source_target,
            updated=updated,
            line_index=line_index,
        )
    return text, rows


def _section_ranges(lines: list[str]) -> tuple[dict[str, tuple[int, int]], list[str]]:
    headings: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        match = re.fullmatch(r"##\s+(.+?)\s*", line)
        if match:
            headings.append((index, match.group(1)))
    ranges: dict[str, tuple[int, int]] = {}
    duplicates: list[str] = []
    for position, (line_index, name) in enumerate(headings):
        end = headings[position + 1][0] if position + 1 < len(headings) else len(lines)
        if name in ranges:
            duplicates.append(name)
        else:
            ranges[name] = (line_index + 1, end)
    return ranges, duplicates


def _parse_pattern(
    root: Path,
    path: Path,
    filename_slug: str,
    anchor_cache: dict[Path, set[str] | None],
    errors: list[dict[str, str]],
) -> PatternPage | None:
    rel = _relative(path, root)
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        errors.append(_issue("unreadable-pattern", rel, "pattern is not readable UTF-8"))
        return None
    if _secret_value_detected(text):
        errors.append(_issue("secret-value", rel, "pattern contains a recognizable secret value"))

    lines = text.splitlines()
    if not lines or lines[0] != "---":
        errors.append(_issue("frontmatter", rel, "pattern frontmatter must begin at the first line"))
        return None
    try:
        closing = lines.index("---", 1)
    except ValueError:
        errors.append(_issue("frontmatter", rel, "pattern frontmatter is not closed"))
        return None

    fields: dict[str, str] = {}
    field_lines: dict[str, int] = {}
    malformed_frontmatter = False
    for index in range(1, closing):
        match = re.fullmatch(r"([a-z]+):\s*(\S+)\s*", lines[index])
        if match is None or match.group(1) in fields:
            malformed_frontmatter = True
            continue
        fields[match.group(1)] = match.group(2)
        field_lines[match.group(1)] = index
    if malformed_frontmatter or set(fields) != {"slug", "status"}:
        errors.append(_issue("frontmatter", rel, "frontmatter must contain exactly slug and status"))
        return None

    slug = fields["slug"]
    status_value = fields["status"]
    if not SLUG_RE.fullmatch(slug) or slug != filename_slug:
        errors.append(_issue("pattern-slug", rel, "frontmatter slug must match the filename"))
    if status_value not in STATUSES:
        errors.append(_issue("pattern-status", rel, "frontmatter status is invalid"))

    body = lines[closing + 1 :]
    nonblank = next((line for line in body if line.strip()), None)
    if nonblank != f"# Pattern: {filename_slug}":
        errors.append(_issue("pattern-title", rel, "pattern title must match the filename slug"))
    h1_lines = [line for line in body if re.fullmatch(r"#\s+.+", line)]
    if h1_lines != [f"# Pattern: {filename_slug}"]:
        errors.append(_issue("pattern-title", rel, "pattern must contain exactly one matching title"))

    ranges, duplicates = _section_ranges(body)
    for duplicate in sorted(set(duplicates) & (set(REQUIRED_SECTIONS) | {"Provenance"})):
        errors.append(_issue("duplicate-section", rel, f"required section is duplicated: {duplicate}"))
    required_positions: list[int] = []
    for section in REQUIRED_SECTIONS:
        section_range = ranges.get(section)
        if section_range is None:
            errors.append(_issue("missing-section", rel, f"required section is missing: {section}"))
            continue
        required_positions.append(section_range[0])
        start, end = section_range
        if not any(line.strip() for line in body[start:end]):
            errors.append(_issue("empty-section", rel, f"required section is empty: {section}"))
    if required_positions != sorted(required_positions):
        errors.append(_issue("section-order", rel, "required sections are out of order"))

    provenance: list[str] = []
    provenance_range = ranges.get("Provenance")
    content_end = len(body)
    if provenance_range is not None:
        start, end = provenance_range
        content_end = start - 1
        if any(position >= start for position in required_positions) or end != len(body):
            errors.append(_issue("provenance-order", rel, "Provenance must follow the mandatory sections and be last"))
        raw_body = text.splitlines(keepends=True)[closing + 1 :]
        previous_date = ""
        for line in raw_body[start:end]:
            if not line.strip():
                continue
            provenance.append(line)
            record = PROVENANCE_RE.fullmatch(line.rstrip("\r\n"))
            if record is None:
                errors.append(_issue("provenance-record", rel, "provenance record has invalid syntax"))
                continue
            recorded_date = record[1]
            try:
                date.fromisoformat(recorded_date)
            except ValueError:
                errors.append(_issue("provenance-date", rel, "provenance date is not a real calendar date"))
            if recorded_date < previous_date:
                errors.append(_issue("provenance-date", rel, "provenance dates must not decrease"))
            previous_date = recorded_date
    substantive_content = re.sub(
        r"\s+", "", "\n".join(
            line for line in body[:content_end]
            if line.strip() and not HEADING_RE.fullmatch(line.strip())
        )
    )

    gotcha_targets: list[str] = []
    history_targets: list[str] = []
    pr_targets: list[str] = []
    broken_links: list[str] = []
    evidence_range = ranges.get("Evidence")
    if evidence_range is not None:
        evidence_text = "\n".join(body[evidence_range[0] : evidence_range[1]])
        for match in LINK_RE.finditer(evidence_text):
            target = match.group(2)
            parsed = urlsplit(target)
            if parsed.scheme:
                if PR_URL_RE.fullmatch(target) and parsed.username is None:
                    pr_targets.append(target)
                continue
            local = _parse_local_target(target, base=path.parent, root=root)
            if local is None:
                errors.append(_issue("evidence-link", rel, "evidence contains an unsafe or malformed local link"))
                continue
            target_path, anchor = local
            identity = f"{_relative(target_path, root)}#{anchor}"
            if target_path == root / "gotchas.md":
                gotcha_targets.append(identity)
            elif target_path in {root / "context-log.md", root / "decisions-log.md"}:
                history_targets.append(identity)
            if not _link_resolves(target_path, anchor, anchor_cache):
                broken_links.append(identity)

    if not gotcha_targets:
        errors.append(_issue("evidence-gotcha", rel, "Evidence must link a root gotchas.md anchor"))
    if not history_targets:
        errors.append(_issue("evidence-history", rel, "Evidence must link context-log.md or decisions-log.md"))
    if not pr_targets:
        errors.append(_issue("evidence-pr", rel, "Evidence must contain an HTTPS pull-request link"))

    return PatternPage(
        slug=slug,
        status=status_value,
        path=path,
        text=text,
        status_line_index=field_lines["status"],
        gotcha_targets=tuple(sorted(set(gotcha_targets))),
        broken_links=tuple(sorted(set(broken_links))),
        sha256=hashlib.sha256(raw).hexdigest(),
        provenance=tuple(provenance),
        substantive_content=substantive_content,
    )


def _load_wiki(root: Path) -> WikiState:
    structural: list[dict[str, str]] = []
    semantic: list[dict[str, str]] = []
    wiki = root / "wiki"
    if not wiki.exists() or not wiki.is_dir() or wiki.is_symlink():
        structural.append(_issue("missing-wiki", "wiki", "wiki directory is missing or unsafe"))
    logs = wiki / "logs.md"
    if logs.exists() or logs.is_symlink():
        structural.append(_issue("forbidden-logs", "wiki/logs.md", "wiki/logs.md is forbidden"))

    index_text, rows = _parse_index(root, structural)
    patterns: dict[str, PatternPage] = {}
    patterns_dir = wiki / "patterns"
    anchor_cache: dict[Path, set[str] | None] = {}
    if patterns_dir.exists():
        if not patterns_dir.is_dir() or patterns_dir.is_symlink():
            structural.append(_issue("patterns-directory", "wiki/patterns", "patterns path is not a safe directory"))
        else:
            try:
                entries = sorted(patterns_dir.iterdir(), key=lambda item: item.name)
            except OSError:
                entries = []
                structural.append(_issue("patterns-directory", "wiki/patterns", "patterns directory cannot be read"))
            for path in entries:
                rel = _relative(path, root)
                if path.is_symlink() or not path.is_file():
                    structural.append(_issue("pattern-entry", rel, "pattern entry must be a regular file"))
                    continue
                if path.suffix != ".md" or not SLUG_RE.fullmatch(path.stem):
                    structural.append(_issue("pattern-filename", rel, "pattern filename must be a lower-case slug.md"))
                    continue
                page = _parse_pattern(root, path, path.stem, anchor_cache, structural)
                if page is not None:
                    patterns[path.stem] = page
    elif rows:
        structural.append(_issue("patterns-directory", "wiki/patterns", "indexed patterns require a patterns directory"))

    for slug in sorted(set(rows) - set(patterns)):
        structural.append(_issue("missing-pattern", f"wiki/patterns/{slug}.md", "indexed pattern page is missing"))
    for slug in sorted(set(patterns) - set(rows)):
        structural.append(_issue("unindexed-pattern", f"wiki/patterns/{slug}.md", "pattern page has no index row"))

    for slug in sorted(set(rows) & set(patterns)):
        row = rows[slug]
        page = patterns[slug]
        if row.status != page.status:
            structural.append(_issue("status-mismatch", f"wiki/patterns/{slug}.md", "page and index statuses differ"))
        index_source = _parse_local_target(
            row.source_target, base=(root / "wiki"), root=root
        )
        if index_source is not None:
            source_identity = f"{_relative(index_source[0], root)}#{index_source[1]}"
            if source_identity not in page.gotcha_targets:
                structural.append(_issue("source-mismatch", f"wiki/patterns/{slug}.md", "page gotcha evidence differs from the index source"))
        if page.status == "active" and page.broken_links:
            semantic.append(_issue("active-unresolved", f"wiki/patterns/{slug}.md", "active pattern has unresolved local evidence"))
        elif page.status == "stale" and not page.broken_links:
            semantic.append(_issue("stale-resolved", f"wiki/patterns/{slug}.md", "stale pattern has no unresolved local evidence"))

    return WikiState(
        root=root,
        index_path=root / "wiki" / "index.md",
        index_text=index_text,
        rows=rows,
        patterns=patterns,
        structural_errors=structural,
        semantic_errors=semantic,
    )


def _state_patterns(state: WikiState) -> list[dict[str, Any]]:
    return [
        {
            "slug": slug,
            "status": page.status,
            "broken_links": list(page.broken_links),
        }
        for slug, page in sorted(state.patterns.items())
    ]


def _run_check(root_arg: str) -> int:
    root = _safe_root(root_arg)
    with _wiki_lock(root, exclusive=False):
        state = _load_wiki(root)
    valid = not state.errors
    _emit(
        {
            "command": "check",
            "verdict": "valid" if valid else "invalid",
            "patterns": _state_patterns(state),
            "errors": state.errors,
        }
    )
    return 0 if valid else 1


def _replace_line(text: str, line_index: int, replacement: str) -> str:
    lines = text.splitlines(keepends=True)
    ending = ""
    if lines[line_index].endswith("\r\n"):
        ending = "\r\n"
    elif lines[line_index].endswith("\n"):
        ending = "\n"
    elif lines[line_index].endswith("\r"):
        ending = "\r"
    lines[line_index] = replacement + ending
    return "".join(lines)


def _replace_cell(cell: str, value: str) -> str:
    leading = cell[: len(cell) - len(cell.lstrip())]
    trailing = cell[len(cell.rstrip()) :]
    return f"{leading}{value}{trailing}"


def _replace_index_statuses(
    text: str,
    rows: dict[str, IndexRow],
    replacements: dict[str, str],
    updated_dates: dict[str, str] | None = None,
) -> str:
    lines = text.splitlines(keepends=True)
    updated_dates = updated_dates or {}
    for slug, status_value in replacements.items():
        row = rows[slug]
        raw = lines[row.line_index]
        ending = ""
        content = raw
        if raw.endswith("\r\n"):
            content, ending = raw[:-2], "\r\n"
        elif raw.endswith("\n"):
            content, ending = raw[:-1], "\n"
        parts = content.split("|")
        if len(parts) != 6:
            raise ContractMalformed("index-row", "index row changed while preparing status update")
        parts[2] = _replace_cell(parts[2], status_value)
        if slug in updated_dates:
            parts[4] = _replace_cell(parts[4], updated_dates[slug])
        lines[row.line_index] = "|".join(parts) + ending
    return "".join(lines)


def _atomic_batch_write(updates: dict[Path, str]) -> None:
    staged: dict[Path, Path] = {}
    originals: dict[Path, bytes] = {}
    replaced: list[Path] = []
    failure: BaseException | None = None
    rollback_errors: list[tuple[Path, OSError]] = []
    cleanup_errors: list[tuple[Path, OSError]] = []
    try:
        for target, text in updates.items():
            if not _is_plain_file(target):
                raise OSError("target is not a regular file")
            original = target.read_bytes()
            originals[target] = original
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
            )
            temporary = Path(temporary_name)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(text.encode("utf-8"))
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, stat.S_IMODE(target.stat().st_mode))
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
            staged[target] = temporary
        for target, temporary in staged.items():
            os.replace(temporary, target)
            replaced.append(target)
    except BaseException as exc:
        failure = exc
        for target in reversed(replaced):
            try:
                descriptor, temporary_name = tempfile.mkstemp(
                    prefix=f".{target.name}.", suffix=".rollback", dir=target.parent
                )
                temporary = Path(temporary_name)
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(originals[target])
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, stat.S_IMODE(target.stat().st_mode))
                os.replace(temporary, target)
            except OSError as rollback_error:
                rollback_errors.append((target, rollback_error))
    finally:
        for target, temporary in staged.items():
            try:
                temporary.unlink(missing_ok=True)
            except OSError as cleanup_error:
                cleanup_errors.append((target, cleanup_error))

    if failure is None and not cleanup_errors:
        return

    details = ["stale status update could not be completed"]
    if rollback_errors:
        failures = ", ".join(
            f"{target.name}: {error}" for target, error in rollback_errors
        )
        details.append(f"rollback failed for {failures}")
    if cleanup_errors:
        failures = ", ".join(
            f"{target.name}: {error}" for target, error in cleanup_errors
        )
        details.append(f"temporary cleanup failed for {failures}")
    cause = failure if failure is not None else cleanup_errors[0][1]
    raise ContractMalformed("write", "; ".join(details)) from cause


def _run_mark_stale(root_arg: str) -> int:
    root = _safe_root(root_arg)
    with _wiki_lock(root, exclusive=True):
        return _mark_stale_locked(root)


def _mark_stale_locked(root: Path) -> int:
    state = _load_wiki(root)
    stale_candidates = {
        slug: page
        for slug, page in state.patterns.items()
        if page.status == "active" and page.broken_links
    }
    permitted_semantic = {
        f"wiki/patterns/{slug}.md" for slug in stale_candidates
    }
    other_semantic = [
        error
        for error in state.semantic_errors
        if error["code"] != "active-unresolved" or error["path"] not in permitted_semantic
    ]
    errors = state.structural_errors + other_semantic
    if errors:
        _emit(
            {
                "command": "mark-stale",
                "verdict": "invalid",
                "changed_paths": [],
                "patterns": [],
                "errors": errors,
            }
        )
        return 1
    if not stale_candidates:
        _emit(
            {
                "command": "mark-stale",
                "verdict": "valid",
                "changed_paths": [],
                "patterns": [],
                "errors": [],
            }
        )
        return 0
    if state.index_text is None:
        raise ContractMalformed("index", "index disappeared while preparing status update")

    replacements = {slug: "stale" for slug in stale_candidates}
    today = date.today().isoformat()
    updated_dates = {
        slug: max(state.rows[slug].updated, today) for slug in stale_candidates
    }
    updates: dict[Path, str] = {
        page.path: _replace_line(page.text, page.status_line_index, "status: stale")
        for page in stale_candidates.values()
    }
    updates[state.index_path] = _replace_index_statuses(
        state.index_text, state.rows, replacements, updated_dates
    )
    _atomic_batch_write(updates)
    changed_paths = sorted(_relative(path, root) for path in updates)
    _emit(
        {
            "command": "mark-stale",
            "verdict": "valid",
            "changed_paths": changed_paths,
            "patterns": sorted(stale_candidates),
            "errors": [],
        }
    )
    return 0


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tree_snapshot(root: Path) -> dict[str, tuple[str, int, str]]:
    snapshot: dict[str, tuple[str, int, str]] = {}

    def visit(directory: Path, relative: PurePosixPath) -> None:
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: entry.name)
        except OSError as exc:
            raise ContractMalformed("snapshot", "project tree cannot be read") from exc
        for entry in entries:
            if relative == PurePosixPath(".") and entry.name == ".git":
                continue
            child_rel = (
                PurePosixPath(entry.name)
                if relative == PurePosixPath(".")
                else relative / entry.name
            )
            child = Path(entry.path)
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ContractMalformed("snapshot", "project entry cannot be inspected") from exc
            mode = stat.S_IMODE(metadata.st_mode)
            if entry.is_symlink():
                try:
                    target = os.readlink(child)
                except OSError as exc:
                    raise ContractMalformed("snapshot", "project symlink cannot be read") from exc
                snapshot[child_rel.as_posix()] = ("symlink", mode, target)
            elif entry.is_dir(follow_symlinks=False):
                visit(child, child_rel)
            elif entry.is_file(follow_symlinks=False):
                try:
                    digest = _hash_file(child)
                except OSError as exc:
                    raise ContractMalformed("snapshot", "project file cannot be read") from exc
                snapshot[child_rel.as_posix()] = ("file", mode, digest)
            else:
                snapshot[child_rel.as_posix()] = ("special", mode, "")

    visit(root, PurePosixPath("."))
    return snapshot


def _allowed_change_path(path: str) -> bool:
    return path == "wiki/index.md" or re.fullmatch(
        r"wiki/patterns/[a-z0-9][a-z0-9-]*\.md", path
    ) is not None


def _semantic_error_paths(state: WikiState, code: str) -> set[str]:
    return {error["path"] for error in state.semantic_errors if error["code"] == code}


def _page_status_only(
    before: PatternPage, after: PatternPage, status_value: str
) -> bool:
    return (
        _replace_line(before.text, before.status_line_index, f"status: {status_value}")
        == after.text
    )


def _same_row_content(before: IndexRow, after: IndexRow) -> bool:
    return (
        before.slug,
        before.status,
        before.source_label,
        before.source_target,
        before.updated,
    ) == (
        after.slug,
        after.status,
        after.source_label,
        after.source_target,
        after.updated,
    )


def _rows_compatible(
    before: WikiState,
    after: WikiState,
    *,
    touched: set[str],
    status_changes: dict[str, tuple[str, str]],
    strict_status_only: bool,
) -> bool:
    if set(before.rows) != set(after.rows):
        return False
    for slug in before.rows:
        old = before.rows[slug]
        new = after.rows[slug]
        expected = status_changes.get(slug)
        if expected is None:
            if slug not in touched or strict_status_only:
                if old != new:
                    return False
            else:
                # A merge may revise the surviving row's source and date along
                # with its page. Structural validation has already proved that
                # the new source matches the survivor's gotcha evidence.
                if (
                    old.status != new.status
                    or new.status != "active"
                    or new.updated < old.updated
                ):
                    return False
        else:
            if old.source_label != new.source_label or old.source_target != new.source_target:
                return False
            if (old.status, new.status) != expected:
                return False
            if new.updated < old.updated:
                return False
            if slug not in touched:
                return False
    if strict_status_only:
        if before.index_text is None or after.index_text is None:
            return False
        replacement = {slug: new for slug, (_, new) in status_changes.items()}
        updated_dates = {slug: after.rows[slug].updated for slug in status_changes}
        return (
            _replace_index_statuses(
                before.index_text, before.rows, replacement, updated_dates
            )
            == after.index_text
        )
    return True


def _change_rejection(
    changed_paths: list[str], errors: list[dict[str, str]], patterns: dict[str, list[str]] | None = None
) -> tuple[dict[str, Any], int]:
    return (
        {
            "command": "check-change",
            "verdict": "rejected",
            "transition": "none",
            "changed_paths": changed_paths,
            "patterns": patterns
            or {"created": [], "retired": [], "stale": [], "survivors": []},
            "errors": errors,
        },
        1,
    )


def _classify_change(
    before: WikiState, after: WikiState, changed_paths: list[str]
) -> tuple[dict[str, Any], int]:
    if before.structural_errors or after.structural_errors:
        errors = [
            _issue(error["code"], f"before/{error['path']}", error["message"])
            for error in before.structural_errors
        ] + [
            _issue(error["code"], f"after/{error['path']}", error["message"])
            for error in after.structural_errors
        ]
        return _change_rejection(changed_paths, errors)

    before_slugs = set(before.patterns)
    after_slugs = set(after.patterns)
    created = sorted(after_slugs - before_slugs)
    removed = sorted(before_slugs - after_slugs)
    common = before_slugs & after_slugs
    changed_pages = {
        slug for slug in common if before.patterns[slug].text != after.patterns[slug].text
    }
    status_changes = {
        slug: (before.patterns[slug].status, after.patterns[slug].status)
        for slug in common
        if before.patterns[slug].status != after.patterns[slug].status
    }
    stale = sorted(
        slug for slug, statuses in status_changes.items() if statuses == ("active", "stale")
    )
    retired = sorted(
        slug
        for slug, statuses in status_changes.items()
        if statuses == ("active", "retired")
    )
    survivors = sorted(
        slug
        for slug in changed_pages
        if slug not in status_changes and after.patterns[slug].status == "active"
    )
    pattern_summary = {
        "created": created,
        "retired": retired,
        "stale": stale,
        "survivors": survivors,
    }

    if "wiki/index.md" not in changed_paths:
        return _change_rejection(
            changed_paths,
            [_issue("index-unchanged", "wiki/index.md", "an allowed wiki transition must update its index row")],
            pattern_summary,
        )
    if removed:
        return _change_rejection(
            changed_paths,
            [_issue("pattern-deletion", "wiki/patterns", "allowed transitions preserve pattern pages")],
            pattern_summary,
        )

    for slug in sorted(changed_pages):
        old_records = before.patterns[slug].provenance
        if after.patterns[slug].provenance[: len(old_records)] != old_records:
            return _change_rejection(
                changed_paths,
                [_issue("provenance-history", f"wiki/patterns/{slug}.md", "existing provenance records must be preserved byte-for-byte in order")],
                pattern_summary,
            )

    # A single-page refinement or stale reactivation appends one byte-bound record.
    if not created and len(changed_pages) == 1:
        slug = next(iter(changed_pages))
        old_page, new_page = before.patterns[slug], after.patterns[slug]
        statuses = (old_page.status, new_page.status)
        transition = {("active", "active"): "refine", ("stale", "active"): "reactivate"}.get(statuses)
        rel = f"wiki/patterns/{slug}.md"
        if transition is not None and set(changed_paths) == {"wiki/index.md", rel}:
            added = new_page.provenance[len(old_page.provenance) :]
            prior_sha256 = old_page.sha256
            if len(added) != 1:
                return _change_rejection(changed_paths, [_issue("provenance-append", rel, "transition requires exactly one appended provenance record")], pattern_summary)
            record = PROVENANCE_RE.fullmatch(added[0].rstrip("\r\n"))
            # Structural validation above has already parsed every record.
            assert record is not None
            if record[2] != transition or record[3] != prior_sha256:
                return _change_rejection(changed_paths, [_issue("provenance-prior", rel, "record action and prior digest must match the actual before page")], pattern_summary)
            rows_ok = _rows_compatible(
                before, after, touched={slug}, status_changes=status_changes,
                strict_status_only=False,
            )
            assert before.index_text is not None and after.index_text is not None
            old_lines = before.index_text.splitlines(keepends=True)
            new_lines = after.index_text.splitlines(keepends=True)
            old_row = old_lines.pop(before.rows[slug].line_index)
            new_row = new_lines.pop(after.rows[slug].line_index)
            before_other = [
                error for error in before.semantic_errors
                if transition != "reactivate" or error["code"] != "stale-resolved" or error["path"] != rel
            ]
            if (
                rows_ok and old_row != new_row and old_lines == new_lines
                and not before_other and not after.semantic_errors
                and (transition == "reactivate" or old_page.substantive_content != new_page.substantive_content)
            ):
                return (
                    {
                        "command": "check-change",
                        "verdict": "allowed",
                        "transition": transition,
                        "changed_paths": changed_paths,
                        "patterns": pattern_summary,
                        "provenance": {"slug": slug, "prior_sha256": prior_sha256, "after_sha256": new_page.sha256},
                        "errors": [],
                    },
                    0,
                )

    # Creation adds exactly one active, fully valid page and changes no existing page.
    if len(created) == 1 and not status_changes and not changed_pages:
        if all(after.patterns[slug].status == "active" for slug in created):
            expected_paths = {"wiki/index.md"} | {
                f"wiki/patterns/{slug}.md" for slug in created
            }
            existing_rows_preserved = all(
                slug in after.rows
                and _same_row_content(before.rows[slug], after.rows[slug])
                for slug in before.rows
            )
            if (
                set(changed_paths) == expected_paths
                and existing_rows_preserved
                and not before.semantic_errors
                and not after.semantic_errors
            ):
                return (
                    {
                        "command": "check-change",
                        "verdict": "allowed",
                        "transition": "create",
                        "changed_paths": changed_paths,
                        "patterns": pattern_summary,
                        "errors": [],
                    },
                    0,
                )

    # Stale marking is stricter than other metadata transitions: only the page
    # status and its index status/date may change, and evidence must be broken.
    if not created and stale and len(status_changes) == len(stale):
        stale_set = set(stale)
        before_unresolved = _semantic_error_paths(before, "active-unresolved")
        expected_unresolved = {f"wiki/patterns/{slug}.md" for slug in stale}
        page_only = changed_pages == stale_set and all(
            _page_status_only(before.patterns[slug], after.patterns[slug], "stale")
            for slug in stale
        )
        rows_only = _rows_compatible(
            before,
            after,
            touched=stale_set,
            status_changes={slug: ("active", "stale") for slug in stale},
            strict_status_only=True,
        )
        before_other = [
            error
            for error in before.semantic_errors
            if error["code"] != "active-unresolved" or error["path"] not in expected_unresolved
        ]
        if (
            page_only
            and rows_only
            and before_unresolved == expected_unresolved
            and not before_other
            and not after.semantic_errors
        ):
            return (
                {
                    "command": "check-change",
                    "verdict": "allowed",
                    "transition": "mark-stale",
                    "changed_paths": changed_paths,
                    "patterns": pattern_summary,
                    "errors": [],
                },
                0,
            )

    # Retirement with a concurrently revised active survivor is a merge.  A
    # retirement without such a survivor is the distinct explicit transition.
    if not created and retired and len(status_changes) == len(retired):
        retired_set = set(retired)
        touched = retired_set | set(survivors)
        retired_pages_status_only = all(
            _page_status_only(before.patterns[slug], after.patterns[slug], "retired")
            for slug in retired
        )
        if changed_pages <= touched and retired_set <= changed_pages:
            rows_ok = _rows_compatible(
                before,
                after,
                touched=touched,
                status_changes={
                    slug: (before.patterns[slug].status, "retired") for slug in retired
                },
                strict_status_only=False,
            )
            if (
                retired_pages_status_only
                and rows_ok
                and not before.semantic_errors
                and not after.semantic_errors
            ):
                transition = "merge-with-retirement" if survivors else "retire-superseded"
                if survivors or (
                    len(retired) == 1 and changed_pages == retired_set
                ):
                    return (
                        {
                            "command": "check-change",
                            "verdict": "allowed",
                            "transition": transition,
                            "changed_paths": changed_paths,
                            "patterns": pattern_summary,
                            "errors": [],
                        },
                        0,
                    )

    errors: list[dict[str, str]] = []
    if before.semantic_errors:
        errors.extend(
            _issue(error["code"], f"before/{error['path']}", error["message"])
            for error in before.semantic_errors
        )
    if after.semantic_errors:
        errors.extend(
            _issue(error["code"], f"after/{error['path']}", error["message"])
            for error in after.semantic_errors
        )
    errors.append(
        _issue(
            "unsupported-transition",
            "wiki",
            "diff is not create, refine, reactivate, merge-with-retirement, retire-superseded, or mark-stale",
        )
    )
    return _change_rejection(changed_paths, errors, pattern_summary)


def _run_check_change(before_arg: str, after_arg: str) -> int:
    before_root = _safe_root(before_arg)
    after_root = _safe_root(after_arg)
    with _wiki_locks((before_root, after_root), exclusive=False):
        return _check_change_locked(before_root, after_root)


def _check_change_locked(before_root: Path, after_root: Path) -> int:
    before_snapshot = _tree_snapshot(before_root)
    after_snapshot = _tree_snapshot(after_root)
    changed_paths = sorted(
        path
        for path in set(before_snapshot) | set(after_snapshot)
        if before_snapshot.get(path) != after_snapshot.get(path)
    )
    if not changed_paths:
        payload, exit_code = _change_rejection(
            [], [_issue("no-change", ".", "before and after roots have no file changes")]
        )
        _emit(payload)
        return exit_code
    forbidden = [path for path in changed_paths if not _allowed_change_path(path)]
    if forbidden:
        payload, exit_code = _change_rejection(
            changed_paths,
            [
                _issue(
                    "forbidden-path",
                    path,
                    "maintainer changes are confined to wiki/index.md and wiki/patterns/*.md",
                )
                for path in forbidden
            ],
        )
        _emit(payload)
        return exit_code

    before = _load_wiki(before_root)
    after = _load_wiki(after_root)
    payload, exit_code = _classify_change(before, after, changed_paths)
    _emit(payload)
    return exit_code


def _parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(prog="validate_wiki.py", add_help=True)
    commands = parser.add_subparsers(dest="command", required=True)

    qualify = commands.add_parser("qualify", help="validate temporary qualification evidence")
    qualify.add_argument("--evidence", required=True)

    check = commands.add_parser("check", help="validate wiki/index.md and pattern pages")
    check.add_argument("--root", required=True)

    stale = commands.add_parser("mark-stale", help="mark active pages with broken local evidence stale")
    stale.add_argument("--root", required=True)

    change = commands.add_parser("check-change", help="prove a maintainer before/after transition")
    change.add_argument("--before", required=True)
    change.add_argument("--after", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    command = "unknown"
    try:
        arguments = _parser().parse_args(argv)
        command = arguments.command
        if command == "qualify":
            return _run_qualify(arguments.evidence)
        if command == "check":
            return _run_check(arguments.root)
        if command == "mark-stale":
            return _run_mark_stale(arguments.root)
        if command == "check-change":
            return _run_check_change(arguments.before, arguments.after)
        raise ContractMalformed("arguments", "unknown command")
    except ContractMalformed as exc:
        _emit(
            {
                "command": command,
                "verdict": "malformed",
                "errors": [_issue(exc.code, ".", exc.message)],
            }
        )
        return 2
    except KeyboardInterrupt:
        _emit(
            {
                "command": command,
                "verdict": "malformed",
                "errors": [_issue("interrupted", ".", "operation was interrupted")],
            }
        )
        return 2
    except (OSError, UnicodeError, json.JSONDecodeError):
        _emit(
            {
                "command": command,
                "verdict": "malformed",
                "errors": [_issue("internal", ".", "input could not be safely validated")],
            }
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
