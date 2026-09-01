#!/usr/bin/env python3
"""Validate and record evidence-backed wiki-to-skill proposals.

The check operation is read-only.  The record operation writes only the project
impact ledger and its linked machine receipt.  This module deliberately has no
Git, subprocess, network, release, or user-global integration.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path, PurePosixPath
from typing import Any, Iterator, NoReturn, Sequence, TextIO
from urllib.parse import unquote, urlsplit

try:
    import fcntl
except ImportError:  # pragma: no cover - only relevant on platforms without flock
    fcntl = None  # type: ignore[assignment]


EXIT_NOT_READY = 1
EXIT_MALFORMED = 2

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DECIMAL_RE = re.compile(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$")
ROUTE_RE = re.compile(
    r"^(?P<family>[a-z0-9][a-z0-9._-]*)::"
    r"(?P<provider>[a-z0-9][a-z0-9._-]*)/"
    r"(?P<model>[a-z0-9][a-z0-9._+-]*)$"
)
RFC3339_UTC_RE = re.compile(
    r"^(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})T"
    r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z$"
)
MARKDOWN_LINK_RE = re.compile(r"\[([^\]\n]+)\]\(([^()\s]+)\)")
FRONTMATTER_RE = re.compile(r"\A---\n(?P<body>.*?)\n---(?:\n|\Z)", re.DOTALL)
INDEX_LINK_RE = re.compile(r"^\[([^\]]+)\]\(([^)]+)\)$")
RECEIPT_LINK_RE = re.compile(
    r"^\[[^\]\n]+\]\(skill-impact/(?P<skill>[a-z0-9][a-z0-9-]*)/"
    r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})-(?P<short>[0-9a-f]{7,12})\.json\)$"
)
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

LEDGER_HEADER = "| date | skill | diff ref | eval score | best-before | verdict | PR | run receipt |"
LEDGER_DIVIDER = "|---|---|---|---:|---|---|---|---|"
LEDGER_PREFIX = (
    "# Skill impact ledger",
    "",
    "Durable record of every evaluated create or patch proposal.",
    "",
    LEDGER_HEADER,
    LEDGER_DIVIDER,
)
RECEIPT_FIELD_ORDER = (
    "skill",
    "proposal_sha",
    "eval_cmd",
    "score",
    "best_before",
    "baseline",
    "verdict",
    "run_at",
    "runner_model",
)
RECEIPT_FIELDS = frozenset(RECEIPT_FIELD_ORDER)
RUNNER_FIELD_ORDER = ("proposer", "evaluator", "judge")
RUNNER_FIELDS = frozenset(RUNNER_FIELD_ORDER)
QUALIFICATION_FIELDS = {
    "schema_version",
    "source",
    "pattern_key",
    "predicate",
    "occurrences",
    "steps",
    "preconditions",
    "inputs",
    "result",
    "verification",
    "verdict",
    "reasons",
}
BENCHMARK_TOP_LEVEL_FIELDS = {"metadata", "runs", "run_summary", "notes"}
RECORD_VERDICTS = {"eval-passed", "accepted", "rejected", "failed"}
IMMUTABLE_SKILL_ROOT_PARTS = {
    ".agents",
    ".claude",
    ".git",
    ".omp",
    ".trellis",
    "dist",
    "release",
    "releases",
}


class ProposalError(Exception):
    """Base class for controlled CLI failures."""


class MalformedError(ProposalError):
    """An input or durable artifact does not satisfy its schema."""


class NotReadyError(ProposalError):
    """A well-formed proposal does not satisfy a promotion gate."""


@dataclass(frozen=True)
class ProposalDiff:
    base: str
    head: str


@dataclass(frozen=True)
class Benchmark:
    score: Decimal
    baseline: Decimal


@dataclass(frozen=True)
class Receipt:
    raw: dict[str, Any]
    skill: str
    proposal_sha: str
    eval_cmd: str
    score: Decimal
    score_text: str
    best_before: Decimal
    best_before_text: str
    baseline: Decimal
    baseline_text: str
    verdict: str
    run_at: str
    run_date: str
    runner_model: dict[str, str]
    runner_families_separated: bool


@dataclass(frozen=True)
class PatternRecord:
    slug: str
    source: str


@dataclass(frozen=True)
class LedgerRow:
    line_index: int
    date: str
    skill: str
    diff_ref: str
    score_text: str
    score: Decimal
    best_before_text: str
    best_before: Decimal
    verdict: str
    pr: str
    receipt_cell: str
    receipt_target: str
    diff_base: str
    diff_head: str
    patterns: tuple[str, ...]
    new_evidence: tuple[str, ...]


@dataclass
class Ledger:
    lines: list[str]
    divider_index: int
    rows: list[LedgerRow]


@dataclass(frozen=True)
class PreEvaluationProposal:
    root: Path
    skill: str
    patterns: tuple[str, ...]
    new_evidence: tuple[str, ...]
    proposal_diff: ProposalDiff


@dataclass(frozen=True)
class StaticProposal:
    root: Path
    skill: str
    patterns: tuple[str, ...]
    new_evidence: tuple[str, ...]
    proposal_diff: ProposalDiff
    benchmark: Benchmark
    receipt: Receipt
    process_gate_path: Path


def fail(message: str) -> NoReturn:
    raise MalformedError(message)


def require_plain_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        fail(f"{label} must be a string")
    if not allow_empty and not value:
        fail(f"{label} must not be empty")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail(f"{label} contains a control character")
    return value


def reject_json_constant(value: str) -> NoReturn:
    fail(f"JSON contains non-finite numeric constant {value}")


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON object contains duplicate key {key!r}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> Any:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} must be a regular, non-symlink file: {path}")
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(
                handle,
                parse_float=Decimal,
                parse_int=int,
                parse_constant=reject_json_constant,
                object_pairs_hook=unique_json_object,
            )
    except ProposalError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"could not read {label} as UTF-8 JSON: {error}")


def read_text(path: Path, label: str) -> str:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} must be a regular, non-symlink file: {path}")
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")


def safe_repo_path(value: str, label: str) -> PurePosixPath:
    require_plain_string(value, label)
    if "\\" in value or ":" in value or value.startswith(("/", "~")) or value.endswith("/"):
        fail(f"{label} must be a normalized repository-relative POSIX path")
    path = PurePosixPath(value)
    if str(path) != value or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{label} must be a normalized repository-relative POSIX path")
    return path


def relative_to_or_none(path: Path, parent: Path) -> Path | None:
    try:
        return path.relative_to(parent)
    except ValueError:
        return None


def ensure_no_symlink_below(root: Path, target: Path, label: str) -> None:
    relative = relative_to_or_none(target, root)
    if relative is None:
        fail(f"{label} escapes the project root")
    current = root
    for component in relative.parts:
        current = current / component
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            fail(f"could not inspect {label}: {error}")
        if stat.S_ISLNK(mode):
            fail(f"{label} must not traverse a symlink")

def ensure_real_directory_below(root: Path, path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        fail(f"{label} must be a real directory")
    ensure_no_symlink_below(root, path, label)
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"could not resolve {label}: {error}")
    if resolved != path or relative_to_or_none(resolved, root) is None:
        fail(f"{label} must resolve beneath the project root")


def ensure_regular_file_below(root: Path, path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} must be a regular, non-symlink file")
    ensure_no_symlink_below(root, path, label)
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"could not resolve {label}: {error}")
    if resolved != path or relative_to_or_none(resolved, root) is None:
        fail(f"{label} must resolve beneath the project root")


def validated_wiki_directory(root: Path) -> Path:
    wiki = root / "wiki"
    ensure_real_directory_below(root, wiki, "wiki directory")
    return wiki


def resolve_root(value: str) -> Path:
    root_input = Path(value).expanduser()
    try:
        root = root_input.resolve(strict=True)
    except OSError as error:
        fail(f"project root does not resolve: {error}")
    if not root.is_dir():
        fail("project root must be a directory")
    parts = root.parts
    if any(
        parts[index] in {".trellis", ".omp"}
        and index + 1 < len(parts)
        and parts[index + 1] in {"release", "releases"}
        for index in range(len(parts))
    ):
        fail("project root is inside an immutable release payload")
    return root


def resolve_skill_root(root: Path, value: str) -> tuple[PurePosixPath, Path]:
    relative = safe_repo_path(value, "skill root")
    if any(part in IMMUTABLE_SKILL_ROOT_PARTS for part in relative.parts):
        fail("skill root points at an immutable release or tool-owned payload")
    skill_root = root.joinpath(*relative.parts)
    try:
        resolved = skill_root.resolve(strict=True)
    except OSError as error:
        fail(f"skill root does not resolve inside the project: {error}")
    if resolved != skill_root or relative_to_or_none(resolved, root) is None:
        fail("skill root must be a real project-local directory")
    ensure_no_symlink_below(root, resolved, "skill root")
    if not resolved.is_dir():
        fail("skill root must be a directory")
    return relative, resolved


def resolve_candidate(root: Path, skill_root: Path, value: str) -> Path:
    candidate_input = Path(value).expanduser()
    candidate_path = candidate_input if candidate_input.is_absolute() else root / candidate_input
    try:
        candidate = candidate_path.resolve(strict=True)
    except OSError as error:
        fail(f"candidate directory does not resolve: {error}")
    if not candidate.is_dir() or candidate.parent != skill_root:
        fail("candidate must be one direct child directory of the configured skill root")
    ensure_no_symlink_below(root, candidate, "candidate")
    if not SLUG_RE.fullmatch(candidate.name):
        fail("candidate directory name must be a lower-case skill slug")
    return candidate


def parse_patterns(value: str) -> tuple[str, ...]:
    require_plain_string(value, "patterns")
    raw = value.split(",")
    if any(not item for item in raw):
        fail("patterns must be a comma-separated list without empty entries")
    if any(not SLUG_RE.fullmatch(item) for item in raw):
        fail("every pattern must be a lower-case slug")
    if len(set(raw)) != len(raw):
        fail("patterns must not contain duplicates")
    return tuple(sorted(raw))


def validate_new_evidence(values: Sequence[str]) -> tuple[str, ...]:
    result: list[str] = []
    seen: set[str] = set()
    for position, value in enumerate(values, start=1):
        link = require_plain_string(value, f"new evidence #{position}")
        if link == "none" or any(char in link for char in ",;|") or any(char.isspace() for char in link):
            fail("new evidence must be a single link without separators or whitespace")
        parsed = urlsplit(link)
        if parsed.scheme:
            if parsed.scheme != "https" or not parsed.netloc or parsed.username is not None:
                fail("new evidence URLs must be credential-free HTTPS links")
        else:
            if "#" not in link:
                fail("local new evidence must include a file anchor")
            path_text, anchor = link.split("#", 1)
            safe_repo_path(path_text, "new evidence path")
            if not anchor:
                fail("local new evidence must include a nonempty anchor")
        if link in seen:
            fail("new evidence links must not be duplicated")
        seen.add(link)
        result.append(link)
    return tuple(result)


def validate_new_evidence_resolution(root: Path, links: Sequence[str]) -> None:
    for link in links:
        parsed = urlsplit(link)
        if parsed.scheme:
            continue
        path_text, anchor = link.split("#", 1)
        relative = safe_repo_path(path_text, "new evidence path")
        try:
            target = root.joinpath(*relative.parts).resolve(strict=True)
        except OSError as error:
            raise NotReadyError(f"new evidence link does not resolve: {error}") from error
        if relative_to_or_none(target, root) is None or target.is_symlink() or not target.is_file():
            raise NotReadyError("new evidence must resolve to a regular project file")
        ensure_no_symlink_below(root, target, "new evidence")
        if not file_has_anchor(target, unquote(anchor)):
            raise NotReadyError("new evidence anchor does not resolve")




def parse_proposal_diff(path: Path, skill_root: PurePosixPath, skill: str) -> ProposalDiff:
    value = load_json(path, "proposal diff")
    if not isinstance(value, dict) or set(value) != {"base", "head", "changed_paths"}:
        fail("proposal diff must have exactly base, head, and changed_paths")
    base = require_plain_string(value["base"], "proposal diff base")
    head = require_plain_string(value["head"], "proposal diff head")
    if not SHA_RE.fullmatch(base) or not SHA_RE.fullmatch(head) or base == head:
        fail("proposal diff base and head must be distinct 40-character lowercase hexadecimal SHAs")
    paths_value = value["changed_paths"]
    if not isinstance(paths_value, list) or not paths_value:
        fail("proposal diff changed_paths must be a nonempty array")

    seen: set[str] = set()
    candidate_change_count = 0
    sidecar_change_count = 0
    candidate_prefix = (*skill_root.parts, skill)
    for index, item in enumerate(paths_value, start=1):
        changed = safe_repo_path(
            require_plain_string(item, f"changed path #{index}"),
            f"changed path #{index}",
        )
        text = str(changed)
        if text in seen:
            fail("proposal diff changed_paths must not contain duplicates")
        seen.add(text)

        if changed.parts[: len(candidate_prefix)] == candidate_prefix:
            if len(changed.parts) == len(candidate_prefix):
                fail("proposal diff must list changed files, not a skill directory")
            candidate_change_count += 1
            continue
        if text in {"gotchas.md", "wiki/skill-impact.md"}:
            continue
        if (
            len(changed.parts) == 4
            and changed.parts[:3] == ("wiki", "skill-impact", skill)
        ):
            match = re.fullmatch(
                r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})-(?P<short>[0-9a-f]{7,12})\.json",
                changed.name,
            )
            if match is None or not head.startswith(match.group("short")):
                raise NotReadyError(
                    "proposal diff sidecar path must identify the selected proposal"
                )
            try:
                datetime.strptime(match.group("date"), "%Y-%m-%d")
            except ValueError as error:
                fail(f"proposal diff sidecar date is invalid: {error}")
            sidecar_change_count += 1
            if sidecar_change_count > 1:
                raise NotReadyError(
                    "proposal diff may change only one sidecar for the selected proposal"
                )
            continue
        raise NotReadyError(
            "proposal diff may change only the selected candidate, gotchas.md, "
            "and the selected proposal impact row or sidecar"
        )

    if candidate_change_count == 0:
        raise NotReadyError("proposal diff must change files beneath the selected candidate skill")
    return ProposalDiff(base=base, head=head)


def parse_frontmatter(text: str, label: str) -> dict[str, str]:
    normalized = text.replace("\r\n", "\n")
    match = FRONTMATTER_RE.match(normalized)
    if match is None:
        fail(f"{label} must begin with YAML-style frontmatter")
    fields: dict[str, str] = {}
    for line in match.group("body").splitlines():
        if not line.strip():
            continue
        if ":" not in line:
            fail(f"{label} contains malformed frontmatter")
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not key or key in fields:
            fail(f"{label} contains duplicate or empty frontmatter keys")
        fields[key] = value
    return fields


def section_body(text: str, heading: str, label: str) -> str:
    pattern = re.compile(
        rf"(?m)^## {re.escape(heading)}[ \t]*\n(?P<body>.*?)(?=^##? |\Z)",
        re.DOTALL,
    )
    matches = list(pattern.finditer(text.replace("\r\n", "\n")))
    if len(matches) != 1:
        fail(f"{label} must contain exactly one '## {heading}' section")
    body = matches[0].group("body").strip()
    if not body:
        fail(f"{label} section '## {heading}' must not be empty")
    return body


def validate_candidate_files(candidate: Path, skill: str) -> None:
    skill_file = candidate / "SKILL.md"
    purpose_file = candidate / "PURPOSE.md"
    skill_text = read_text(skill_file, "candidate SKILL.md")
    purpose_text = read_text(purpose_file, "candidate PURPOSE.md")
    skill_frontmatter = parse_frontmatter(skill_text, "candidate SKILL.md")
    if skill_frontmatter.get("name") != skill:
        raise NotReadyError("candidate SKILL.md frontmatter name must match the candidate directory")


def markdown_anchor(text: str) -> str:
    value = text.strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return value.replace(" ", "-")


def file_has_anchor(path: Path, anchor: str) -> bool:
    if not anchor:
        return False
    text = read_text(path, f"linked evidence file {path}")
    wanted = unquote(anchor)
    counts: dict[str, int] = {}
    for line in text.replace("\r\n", "\n").splitlines():
        match = re.fullmatch(r"#{1,6}\s+(.+?)\s*", line)
        if match is not None:
            base = markdown_anchor(match.group(1))
            if base:
                count = counts.get(base, 0)
                counts[base] = count + 1
                generated = base if count == 0 else f"{base}-{count}"
                if generated == wanted:
                    return True
        for explicit in re.finditer(
            r"<a\s+(?:id|name)=[\"']([^\"']+)[\"'](?:\s*></a>|\s*/?>)",
            line,
            flags=re.IGNORECASE,
        ):
            if explicit.group(1) == wanted:
                return True
    return False


def resolve_local_link(root: Path, source_file: Path, target: str, label: str) -> tuple[Path, str]:
    split = urlsplit(target)
    if split.scheme or split.netloc or split.query or not split.path or not split.fragment:
        raise NotReadyError(f"{label} must be a resolving local file-and-anchor link")
    try:
        decoded_path = unquote(split.path)
        linked = (source_file.parent / decoded_path).resolve(strict=True)
    except (OSError, UnicodeError) as error:
        raise NotReadyError(f"{label} does not resolve: {error}") from error
    if relative_to_or_none(linked, root) is None or linked.is_symlink() or not linked.is_file():
        raise NotReadyError(f"{label} must resolve to a regular file inside the project")
    ensure_no_symlink_below(root, linked, label)
    if not file_has_anchor(linked, split.fragment):
        raise NotReadyError(f"{label} anchor does not resolve")
    return linked, unquote(split.fragment)


def normalized_root_link(root: Path, linked: Path, anchor: str) -> str:
    return f"{linked.relative_to(root).as_posix()}#{anchor}"


def parse_index(root: Path) -> dict[str, tuple[str, str, str]]:
    index_path = validated_wiki_directory(root) / "index.md"
    ensure_regular_file_below(root, index_path, "wiki index")
    text = read_text(index_path, "wiki index")
    lines = text.replace("\r\n", "\n").splitlines()
    if lines[: len(INDEX_PREFIX)] != list(INDEX_PREFIX):
        fail("wiki index is missing its exact on-demand title, description, or table")
    if lines.count(INDEX_HEADER) != 1 or lines.count(INDEX_DIVIDER) != 1:
        fail("wiki index must contain exactly one catalog table")
    header_index = 4
    rows: dict[str, tuple[str, str, str]] = {}
    for line in lines[header_index + 2 :]:
        if not line.startswith("|"):
            break
        cells = split_markdown_row(line, 4, "wiki index row")
        slug_match = INDEX_LINK_RE.fullmatch(cells[0])
        source_match = INDEX_LINK_RE.fullmatch(cells[2])
        if slug_match is None or source_match is None:
            fail("wiki index slug and source cells must be Markdown links")
        slug, target = slug_match.groups()
        if not SLUG_RE.fullmatch(slug) or target != f"patterns/{slug}.md":
            fail("wiki index contains a malformed pattern link")
        if cells[1] not in {"active", "stale", "retired"}:
            fail(f"wiki index row {slug} has invalid status")
        try:
            datetime.strptime(cells[3], "%Y-%m-%d")
        except ValueError as error:
            fail(f"wiki index row {slug} has invalid updated date: {error}")
        if slug in rows:
            fail(f"wiki index contains duplicate slug {slug}")
        rows[slug] = (cells[1], source_match.group(2), cells[3])
    return rows


def validate_pattern(root: Path, slug: str, index: dict[str, tuple[str, str, str]]) -> PatternRecord:
    if slug not in index:
        raise NotReadyError(f"selected pattern {slug} is absent from wiki/index.md")
    index_status, index_source_target, _updated = index[slug]
    page = root / "wiki" / "patterns" / f"{slug}.md"
    text = read_text(page, f"pattern page {slug}")
    fields = parse_frontmatter(text, f"pattern page {slug}")
    if fields.get("slug") != slug:
        raise NotReadyError(f"pattern page {slug} has mismatched frontmatter slug")
    status = fields.get("status")
    if status not in {"active", "stale", "retired"}:
        fail(f"pattern page {slug} has malformed status")
    if status != index_status:
        raise NotReadyError(f"pattern page {slug} status disagrees with wiki/index.md")
    if status != "active":
        raise NotReadyError(f"pattern page {slug} is {status} and cannot motivate a proposal")
    evidence = section_body(text, "Evidence", f"pattern page {slug}")
    links = [target for _label, target in MARKDOWN_LINK_RE.findall(evidence)]
    gotcha_links: list[tuple[Path, str]] = []
    history_links: list[tuple[Path, str]] = []
    pr_links: list[str] = []
    for target in links:
        parsed = urlsplit(target)
        if parsed.scheme:
            if PR_URL_RE.fullmatch(target) and parsed.username is None:
                pr_links.append(target)
            continue
        linked, anchor = resolve_local_link(root, page, target, f"pattern {slug} evidence link")
        relative = linked.relative_to(root).as_posix()
        if relative == "gotchas.md":
            gotcha_links.append((linked, anchor))
        elif relative in {"context-log.md", "decisions-log.md"}:
            history_links.append((linked, anchor))
    if len(gotcha_links) != 1 or not history_links or not pr_links:
        raise NotReadyError(
            f"pattern page {slug} needs one resolving gotcha link, a resolving context/decision link, and an HTTPS PR link"
        )
    index_linked, index_anchor = resolve_local_link(root, root / "wiki" / "index.md", index_source_target, f"index source for {slug}")
    source = normalized_root_link(root, gotcha_links[0][0], gotcha_links[0][1])
    if normalized_root_link(root, index_linked, index_anchor) != source:
        raise NotReadyError(f"pattern page {slug} gotcha evidence disagrees with its index source")
    return PatternRecord(slug=slug, source=source)


def validate_purpose_links(candidate: Path, root: Path, patterns: Sequence[PatternRecord]) -> None:
    purpose = candidate / "PURPOSE.md"
    text = read_text(purpose, "candidate PURPOSE.md")
    try:
        body = section_body(text, "Motivating patterns", "candidate PURPOSE.md")
    except MalformedError as error:
        raise NotReadyError(str(error)) from error
    links = MARKDOWN_LINK_RE.findall(body)
    if len(links) != len(patterns):
        raise NotReadyError("PURPOSE.md must contain exactly one motivating link per selected pattern")
    resolved: list[str] = []
    for _label, target in links:
        split = urlsplit(target)
        if split.scheme or split.netloc or split.fragment or not split.path:
            raise NotReadyError("PURPOSE.md motivating links must be relative pattern-file links without fragments")
        try:
            linked = (purpose.parent / unquote(split.path)).resolve(strict=True)
        except OSError as error:
            raise NotReadyError(f"PURPOSE.md motivating link does not resolve: {error}") from error
        if relative_to_or_none(linked, root) is None or linked.is_symlink() or not linked.is_file():
            raise NotReadyError("PURPOSE.md motivating links must resolve inside the project")
        resolved.append(linked.relative_to(root).as_posix())
    expected = [f"wiki/patterns/{record.slug}.md" for record in patterns]
    if sorted(resolved) != sorted(expected) or len(set(resolved)) != len(resolved):
        raise NotReadyError("PURPOSE.md motivating links do not exactly match the selected pattern set")


def qualification_decisions(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict) and set(value) == QUALIFICATION_FIELDS:
        return [value]
    if isinstance(value, list) and value:
        if not all(isinstance(item, dict) for item in value):
            fail("qualification decision array must contain only objects")
        return list(value)
    if isinstance(value, dict) and set(value) == {"decisions"} and isinstance(value["decisions"], list) and value["decisions"]:
        if not all(isinstance(item, dict) for item in value["decisions"]):
            fail("qualification decisions must contain only objects")
        return list(value["decisions"])
    fail("qualification must be one decision or a nonempty array of decisions")


def validate_qualification(path: Path, patterns: Sequence[PatternRecord]) -> None:
    decisions = qualification_decisions(load_json(path, "qualification decision"))
    if len(decisions) != len(patterns):
        raise NotReadyError("qualification must contain exactly one decision per selected pattern")
    unmatched_sources = {record.source for record in patterns}
    for index, decision in enumerate(decisions, start=1):
        if set(decision) != QUALIFICATION_FIELDS:
            fail(f"qualification decision #{index} does not have the exact validator output fields")
        if decision["schema_version"] != 1:
            fail(f"qualification decision #{index} has unsupported schema_version")
        source = require_plain_string(decision["source"], f"qualification decision #{index} source")
        require_plain_string(decision["pattern_key"], f"qualification decision #{index} pattern_key")
        predicate = require_plain_string(decision["predicate"], f"qualification decision #{index} predicate")
        verdict = require_plain_string(decision["verdict"], f"qualification decision #{index} verdict")
        for key in ("occurrences", "steps", "preconditions", "inputs", "reasons"):
            if not isinstance(decision[key], list):
                fail(f"qualification decision #{index} {key} must be an array")
        result = require_plain_string(decision["result"], f"qualification decision #{index} result", allow_empty=True)
        verification = require_plain_string(
            decision["verification"], f"qualification decision #{index} verification", allow_empty=True
        )
        if verdict != "qualify" or predicate not in {"recurrence", "repeatable-path"}:
            raise NotReadyError("every selected pattern must have a qualifying decision")
        if source not in unmatched_sources:
            raise NotReadyError("qualification source does not exactly match a selected pattern's gotcha evidence")
        unmatched_sources.remove(source)
        if predicate == "recurrence":
            occurrences = decision["occurrences"]
            refs: set[str] = set()
            for occurrence in occurrences:
                if not isinstance(occurrence, dict) or set(occurrence) != {"ref", "recorded"}:
                    fail("recurrence decisions must contain exact ref/recorded occurrence objects")
                ref = require_plain_string(occurrence["ref"], "qualification occurrence ref")
                if occurrence["recorded"] is not True:
                    raise NotReadyError("recurrence qualification requires recorded occurrences")
                refs.add(ref)
            if len(occurrences) < 2 or len(refs) < 2:
                raise NotReadyError("recurrence qualification requires two distinct recorded occurrences")
        else:
            steps = decision["steps"]
            if len(steps) < 3 or not decision["preconditions"] or not result or not verification:
                raise NotReadyError("repeatable-path qualification is incomplete")
            orders: list[int] = []
            for step in steps:
                if not isinstance(step, dict) or set(step) != {"order", "action"}:
                    fail("repeatable-path decisions must contain exact order/action step objects")
                if not isinstance(step["order"], int) or isinstance(step["order"], bool):
                    fail("qualification step order must be an integer")
                require_plain_string(step["action"], "qualification step action")
                orders.append(step["order"])
            if orders != list(range(1, len(orders) + 1)):
                raise NotReadyError("repeatable-path qualification steps must be ordered from one without gaps")
    if unmatched_sources:
        raise NotReadyError("qualification omits selected pattern evidence")


def decimal_from_json_number(value: Any, label: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, Decimal)):
        fail(f"{label} must be a JSON number")
    try:
        decimal = Decimal(value) if isinstance(value, int) else value
    except InvalidOperation as error:
        fail(f"{label} is not a decimal: {error}")
    if not decimal.is_finite():
        fail(f"{label} must be finite")
    return decimal


def decimal_from_string(value: Any, label: str) -> tuple[str, Decimal]:
    text = require_plain_string(value, label)
    if not DECIMAL_RE.fullmatch(text):
        fail(f"{label} must be a finite decimal encoded as a string")
    try:
        decimal = Decimal(text)
    except InvalidOperation as error:
        fail(f"{label} is not a decimal: {error}")
    if not decimal.is_finite():
        fail(f"{label} must be finite")
    return text, decimal


def require_pass_rate(value: Decimal, label: str) -> None:
    if value < Decimal(0) or value > Decimal(1):
        fail(f"{label} must be between zero and one")


def parse_rfc3339_utc(value: Any, label: str) -> tuple[str, str]:
    text = require_plain_string(value, label)
    match = RFC3339_UTC_RE.fullmatch(text)
    if match is None:
        fail(f"{label} must be RFC 3339 UTC ending in Z")
    try:
        datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        fail(f"{label} is not a real UTC timestamp: {error}")
    return text, match.group("date")


def parse_benchmark(path: Path, skill: str) -> Benchmark:
    value = load_json(path, "benchmark")
    if not isinstance(value, dict) or set(value) != BENCHMARK_TOP_LEVEL_FIELDS:
        fail("benchmark must be the standard aggregate with metadata, runs, run_summary, and notes")
    metadata = value["metadata"]
    if not isinstance(metadata, dict):
        fail("benchmark metadata must be an object")
    required_metadata = {"skill_name", "timestamp", "evals_run", "runs_per_configuration"}
    if not required_metadata.issubset(metadata):
        fail("benchmark metadata is missing standard aggregate fields")
    if metadata["skill_name"] != skill:
        raise NotReadyError("benchmark metadata skill_name does not match the candidate")
    parse_rfc3339_utc(metadata["timestamp"], "benchmark metadata timestamp")
    evals_run = metadata["evals_run"]
    runs_per_configuration = metadata["runs_per_configuration"]
    if (
        not isinstance(evals_run, list)
        or not evals_run
        or any(not isinstance(item, int) or isinstance(item, bool) or item < 1 for item in evals_run)
        or len(set(evals_run)) != len(evals_run)
    ):
        fail("benchmark metadata evals_run must be a nonempty array of unique positive integers")
    if not isinstance(runs_per_configuration, int) or isinstance(runs_per_configuration, bool) or runs_per_configuration < 1:
        fail("benchmark metadata runs_per_configuration must be a positive integer")
    if not isinstance(value["notes"], list):
        fail("benchmark notes must be an array")
    runs = value["runs"]
    expected_run_count = len(evals_run) * runs_per_configuration * 2
    if not isinstance(runs, list) or len(runs) != expected_run_count:
        fail("benchmark runs do not match evals_run and runs_per_configuration")
    rates: dict[str, list[Decimal]] = {"with_skill": [], "without_skill": []}
    identities: set[tuple[int, str, int]] = set()
    for run_index, run in enumerate(runs, start=1):
        if not isinstance(run, dict):
            fail(f"benchmark run #{run_index} must be an object")
        eval_id = run.get("eval_id")
        configuration = run.get("configuration")
        run_number = run.get("run_number")
        result = run.get("result")
        if (
            not isinstance(eval_id, int)
            or isinstance(eval_id, bool)
            or eval_id not in evals_run
            or not isinstance(configuration, str)
            or configuration not in rates
        ):
            fail(f"benchmark run #{run_index} has unexpected eval_id or configuration")
        if not isinstance(run_number, int) or isinstance(run_number, bool) or not 1 <= run_number <= runs_per_configuration:
            fail(f"benchmark run #{run_index} has invalid run_number")
        identity = (eval_id, configuration, run_number)
        if identity in identities:
            fail("benchmark contains duplicate eval/configuration/run identities")
        identities.add(identity)
        if not isinstance(result, dict) or "pass_rate" not in result:
            fail(f"benchmark run #{run_index} is missing result.pass_rate")
        rate = decimal_from_json_number(result["pass_rate"], f"benchmark run #{run_index} pass_rate")
        require_pass_rate(rate, f"benchmark run #{run_index} pass_rate")
        rates[configuration].append(rate)
    summary = value["run_summary"]
    if not isinstance(summary, dict):
        fail("benchmark run_summary must be an object")
    means: dict[str, Decimal] = {}
    for configuration in ("with_skill", "without_skill"):
        configuration_summary = summary.get(configuration)
        if not isinstance(configuration_summary, dict):
            fail(f"benchmark run_summary.{configuration} must be an object")
        pass_rate = configuration_summary.get("pass_rate")
        if not isinstance(pass_rate, dict) or "mean" not in pass_rate:
            fail(f"benchmark run_summary.{configuration}.pass_rate.mean is required")
        mean = decimal_from_json_number(pass_rate["mean"], f"benchmark {configuration} pass_rate mean")
        require_pass_rate(mean, f"benchmark {configuration} pass_rate mean")
        computed = sum(rates[configuration], Decimal(0)) / Decimal(len(rates[configuration]))
        if mean != computed:
            fail(f"benchmark {configuration} pass_rate mean does not match its runs")
        means[configuration] = mean
    return Benchmark(
        score=means["with_skill"],
        baseline=means["without_skill"],
    )


def parse_receipt_value(value: Any, label: str = "machine receipt") -> Receipt:
    if not isinstance(value, dict) or set(value) != RECEIPT_FIELDS:
        fail(f"{label} must contain exactly the nine receipt fields")
    skill = require_plain_string(value["skill"], f"{label} skill")
    if not SLUG_RE.fullmatch(skill):
        fail(f"{label} skill must be a lower-case slug")
    proposal_sha = require_plain_string(value["proposal_sha"], f"{label} proposal_sha")
    if not SHA_RE.fullmatch(proposal_sha):
        fail(f"{label} proposal_sha must be 40 lowercase hexadecimal characters")
    eval_cmd = require_plain_string(value["eval_cmd"], f"{label} eval_cmd")
    score_text, score = decimal_from_string(value["score"], f"{label} score")
    best_text, best = decimal_from_string(value["best_before"], f"{label} best_before")
    baseline_text, baseline = decimal_from_string(value["baseline"], f"{label} baseline")
    for decimal, field in ((score, "score"), (best, "best_before"), (baseline, "baseline")):
        require_pass_rate(decimal, f"{label} {field}")
    verdict = require_plain_string(value["verdict"], f"{label} verdict")
    if verdict not in RECORD_VERDICTS:
        fail(f"{label} verdict is invalid")
    run_at, run_date = parse_rfc3339_utc(value["run_at"], f"{label} run_at")
    runner = value["runner_model"]
    if not isinstance(runner, dict) or set(runner) != RUNNER_FIELDS:
        fail(f"{label} runner_model must contain exactly proposer, evaluator, and judge")
    routes: dict[str, str] = {}
    families: dict[str, str] = {}
    for role in ("proposer", "evaluator", "judge"):
        route = require_plain_string(runner[role], f"{label} runner_model.{role}")
        match = ROUTE_RE.fullmatch(route)
        if match is None:
            fail(f"{label} runner_model.{role} must use canonical <family>::<provider/model> grammar")
        routes[role] = route
        families[role] = match.group("family")
    families_separated = (
        families["evaluator"] != families["proposer"]
        and families["judge"] != families["proposer"]
    )
    return Receipt(
        raw=value,
        skill=skill,
        proposal_sha=proposal_sha,
        eval_cmd=eval_cmd,
        score=score,
        score_text=score_text,
        best_before=best,
        best_before_text=best_text,
        baseline=baseline,
        baseline_text=baseline_text,
        verdict=verdict,
        run_at=run_at,
        run_date=run_date,
        runner_model=routes,
        runner_families_separated=families_separated,
    )


def parse_receipt(path: Path, label: str = "machine receipt") -> Receipt:
    return parse_receipt_value(load_json(path, label), label)


def validate_process_gate(path: Path) -> None:
    text = read_text(path, "process-gate receipt").replace("\r\n", "\n")
    lines = (text[:-1] if text.endswith("\n") else text).split("\n")
    expected = [
        "bash core-rules/skills/process-gate/scripts/run-all.sh --range=origin/main..HEAD",
        "exit: 0",
        "Overall: MERGEABLE",
    ]
    if lines != expected:
        raise NotReadyError("process-gate receipt is not the exact successful merge-mode receipt")


def split_markdown_row(line: str, count: int, label: str) -> list[str]:
    if not line.startswith("|") or not line.endswith("|"):
        fail(f"{label} must be a Markdown table row")
    cells = [cell.strip() for cell in line[1:-1].split("|")]
    if len(cells) != count or any(not cell for cell in cells):
        fail(f"{label} must contain exactly {count} nonempty cells")
    return cells


def parse_diff_ref(value: str, label: str) -> tuple[str, str, tuple[str, ...], tuple[str, ...]]:
    match = re.fullmatch(
        r"diff=([^;]+)\.\.([^;]+); patterns=([^;]+); new-evidence=(.+)",
        value,
    )
    if match is None:
        fail(f"{label} has malformed diff ref")
    base, head, pattern_text, evidence_text = (part.strip() for part in match.groups())
    if not SHA_RE.fullmatch(base) or not SHA_RE.fullmatch(head) or base == head:
        fail(f"{label} diff refs must be distinct 40-character lowercase hexadecimal SHAs")
    pattern_values = pattern_text.split(",")
    if (
        any(not SLUG_RE.fullmatch(item) for item in pattern_values)
        or len(set(pattern_values)) != len(pattern_values)
        or pattern_values != sorted(pattern_values)
    ):
        fail(f"{label} patterns token must contain unique sorted slugs")
    if evidence_text == "none":
        evidence_values: tuple[str, ...] = ()
    else:
        evidence_values = validate_new_evidence(evidence_text.split(","))
    return base, head, tuple(pattern_values), evidence_values


def parse_receipt_cell(value: str, label: str) -> tuple[str, str, str]:
    match = RECEIPT_LINK_RE.fullmatch(value)
    if match is None:
        fail(f"{label} must link a canonical skill-impact receipt path")
    return match.group("skill"), match.group("date"), match.group("short")


def validate_pr_value(value: str, label: str) -> None:
    if value == "not-opened":
        return
    parsed = urlsplit(value)
    if PR_URL_RE.fullmatch(value) is None or parsed.username is not None:
        fail(f"{label} PR must be not-opened or a credential-free HTTPS pull-request URL")


def parse_ledger_text(text: str) -> Ledger:
    lines = text.replace("\r\n", "\n").splitlines()
    if lines[: len(LEDGER_PREFIX)] != list(LEDGER_PREFIX):
        fail("impact ledger is missing its exact title, description, or eight-column table")
    if lines.count(LEDGER_HEADER) != 1 or lines.count(LEDGER_DIVIDER) != 1:
        fail("impact ledger must contain exactly one ledger table")
    header_index = 4
    rows: list[LedgerRow] = []
    receipt_targets: set[str] = set()
    for line_index in range(header_index + 2, len(lines)):
        line = lines[line_index]
        if not line.startswith("|"):
            break
        cells = split_markdown_row(line, 8, f"impact ledger row {line_index + 1}")
        date, skill, diff_ref, score_text, best_text, verdict, pr, receipt_cell = cells
        try:
            datetime.strptime(date, "%Y-%m-%d")
        except ValueError as error:
            fail(f"impact ledger row {line_index + 1} date is invalid: {error}")
        if not SLUG_RE.fullmatch(skill):
            fail(f"impact ledger row {line_index + 1} skill is invalid")
        diff_base, diff_head, patterns, new_evidence = parse_diff_ref(diff_ref, f"impact ledger row {line_index + 1}")
        parsed_score_text, score = decimal_from_string(score_text, f"impact ledger row {line_index + 1} eval score")
        parsed_best_text, best = decimal_from_string(best_text, f"impact ledger row {line_index + 1} best-before")
        require_pass_rate(score, f"impact ledger row {line_index + 1} eval score")
        require_pass_rate(best, f"impact ledger row {line_index + 1} best-before")
        if verdict not in RECORD_VERDICTS:
            fail(f"impact ledger row {line_index + 1} verdict is invalid")
        validate_pr_value(pr, f"impact ledger row {line_index + 1}")
        linked_skill, linked_date, _short = parse_receipt_cell(receipt_cell, f"impact ledger row {line_index + 1}")
        if linked_skill != skill or linked_date != date:
            fail(f"impact ledger row {line_index + 1} receipt path disagrees with its skill or date")
        receipt_target = INDEX_LINK_RE.fullmatch(receipt_cell).group(2)  # type: ignore[union-attr]
        if receipt_target in receipt_targets:
            fail("impact ledger contains a duplicate receipt link")
        receipt_targets.add(receipt_target)
        rows.append(
            LedgerRow(
                line_index=line_index,
                date=date,
                skill=skill,
                diff_ref=diff_ref,
                score_text=parsed_score_text,
                score=score,
                best_before_text=parsed_best_text,
                best_before=best,
                verdict=verdict,
                pr=pr,
                receipt_cell=receipt_cell,
                receipt_target=receipt_target,
                diff_base=diff_base,
                diff_head=diff_head,
                patterns=patterns,
                new_evidence=new_evidence,
            )
        )
    return Ledger(lines=lines, divider_index=header_index + 1, rows=rows)


def load_ledger(root: Path) -> Ledger:
    path = validated_wiki_directory(root) / "skill-impact.md"
    ensure_regular_file_below(root, path, "impact ledger")
    return parse_ledger_text(read_text(path, "impact ledger"))


def receipt_path_for_row(root: Path, row: LedgerRow) -> Path:
    wiki = validated_wiki_directory(root)
    path = wiki / row.receipt_target
    expected_parent = wiki / "skill-impact" / row.skill
    if path.parent != expected_parent or relative_to_or_none(path, root) is None:
        fail("impact ledger receipt link escapes its canonical skill directory")
    return path


def validate_row_sidecar(root: Path, row: LedgerRow, *, required: bool) -> Receipt | None:
    path = receipt_path_for_row(root, row)
    if path.is_symlink():
        fail(f"linked receipt {row.receipt_target} must not be a symlink")
    if not path.exists():
        if required:
            raise NotReadyError(f"impact ledger history is missing receipt {row.receipt_target}")
        return None
    ensure_real_directory_below(root, path.parent, "impact receipt skill directory")
    ensure_regular_file_below(root, path, f"linked receipt {row.receipt_target}")
    receipt = parse_receipt(path, f"linked receipt {row.receipt_target}")
    _linked_skill, _linked_date, short = parse_receipt_cell(row.receipt_cell, "impact ledger receipt")
    if (
        receipt.skill != row.skill
        or receipt.run_date != row.date
        or not receipt.proposal_sha.startswith(short)
        or receipt.score != row.score
        or receipt.best_before != row.best_before
        or receipt.verdict != row.verdict
    ):
        fail(f"linked receipt {row.receipt_target} disagrees with its ledger row")
    if row.diff_head != receipt.proposal_sha:
        fail(f"linked receipt {row.receipt_target} proposal_sha disagrees with the row diff head")
    if receipt.verdict != "failed" and not receipt.runner_families_separated:
        fail(f"linked receipt {row.receipt_target} violates runner-family separation")
    if receipt.verdict in {"eval-passed", "accepted", "rejected"} and receipt.score <= receipt.best_before:
        fail(f"linked receipt {row.receipt_target} does not record a strict improvement")
    return receipt


def canonical_sidecar_paths(root: Path) -> set[Path]:
    impact = validated_wiki_directory(root) / "skill-impact"
    if impact.is_symlink():
        fail("wiki/skill-impact must not be a symlink")
    if not impact.exists():
        return set()
    ensure_real_directory_below(root, impact, "wiki/skill-impact")
    paths: set[Path] = set()
    try:
        for skill_dir in impact.iterdir():
            if not SLUG_RE.fullmatch(skill_dir.name):
                fail("wiki/skill-impact contains a noncanonical skill directory")
            ensure_real_directory_below(root, skill_dir, "impact receipt skill directory")
            for entry in skill_dir.iterdir():
                if not re.fullmatch(
                    r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7,12}\.json",
                    entry.name,
                ):
                    fail("wiki/skill-impact contains a noncanonical sidecar entry")
                ensure_regular_file_below(root, entry, "impact receipt sidecar")
                paths.add(entry)
    except ProposalError:
        raise
    except OSError as error:
        fail(f"could not inspect impact sidecars: {error}")
    return paths


def validate_history_integrity(root: Path, ledger: Ledger) -> dict[str, tuple[LedgerRow, Receipt]]:
    by_sha: dict[str, tuple[LedgerRow, Receipt]] = {}
    linked_paths: set[Path] = set()
    for row in ledger.rows:
        receipt = validate_row_sidecar(root, row, required=True)
        assert receipt is not None
        path = receipt_path_for_row(root, row)
        linked_paths.add(path)
        if receipt.proposal_sha in by_sha:
            fail("impact ledger contains duplicate proposal SHAs")
        by_sha[receipt.proposal_sha] = (row, receipt)
    orphaned = canonical_sidecar_paths(root) - linked_paths
    if orphaned:
        raise NotReadyError("impact history contains an orphaned sidecar or a deleted ledger row")
    return by_sha


def greatest_accepted_score(root: Path, ledger: Ledger, skill: str) -> Decimal | None:
    scores: list[Decimal] = []
    for row in ledger.rows:
        if row.skill == skill and row.verdict == "accepted":
            receipt = validate_row_sidecar(root, row, required=True)
            assert receipt is not None
            scores.append(receipt.score)
    return max(scores) if scores else None


def matching_rejected_rows(ledger: Ledger, patterns: tuple[str, ...]) -> list[LedgerRow]:
    return [row for row in ledger.rows if row.verdict == "rejected" and row.patterns == patterns]


def enforce_rejected_set_rule(
    ledger: Ledger,
    patterns: tuple[str, ...],
    new_evidence: tuple[str, ...],
) -> None:
    matches = matching_rejected_rows(ledger, patterns)
    if not matches:
        return
    if not new_evidence:
        raise NotReadyError("this exact pattern set has a final rejected proposal and no new evidence was cited")
    new_set = set(new_evidence)
    for row in matches:
        if not (new_set - set(row.new_evidence)):
            raise NotReadyError("new evidence must add a link absent from every matching rejected row")


def validate_benchmark_receipt_match(proposal: StaticProposal) -> None:
    receipt = proposal.receipt
    benchmark = proposal.benchmark
    if receipt.skill != proposal.skill:
        raise NotReadyError("machine receipt skill does not match the candidate")
    if receipt.proposal_sha != proposal.proposal_diff.head:
        raise NotReadyError("machine receipt proposal_sha does not match proposal diff head")
    if receipt.score != benchmark.score:
        raise NotReadyError("machine receipt score does not match benchmark with-skill mean")
    if receipt.baseline != benchmark.baseline:
        raise NotReadyError("machine receipt baseline does not match benchmark without-skill mean")


def applicable_best_before(root: Path, ledger: Ledger, proposal: StaticProposal) -> Decimal:
    accepted = greatest_accepted_score(root, ledger, proposal.skill)
    return accepted if accepted is not None else proposal.benchmark.baseline


def validate_eval_passed_gate(root: Path, ledger: Ledger, proposal: StaticProposal) -> Decimal:
    if not proposal.receipt.runner_families_separated:
        raise NotReadyError("evaluator and judge runner families must each differ from the proposer family")
    expected_best = applicable_best_before(root, ledger, proposal)
    if proposal.receipt.best_before != expected_best:
        raise NotReadyError("machine receipt best_before is not the greatest accepted score or same-run baseline")
    if proposal.receipt.score <= expected_best:
        raise NotReadyError("candidate score must be strictly greater than best_before")
    if proposal.receipt.verdict != "eval-passed":
        raise NotReadyError("a review-ready proposal receipt must have verdict eval-passed")
    validate_process_gate(proposal.process_gate_path)
    return expected_best


def build_pre_evaluation_proposal(args: argparse.Namespace) -> PreEvaluationProposal:
    root = resolve_root(args.root)
    skill_root_relative, skill_root = resolve_skill_root(root, args.skill_root)
    candidate = resolve_candidate(root, skill_root, args.candidate)
    skill = candidate.name
    patterns = parse_patterns(args.patterns)
    new_evidence = validate_new_evidence(args.new_evidence)
    validate_new_evidence_resolution(root, new_evidence)
    validate_candidate_files(candidate, skill)
    proposal_diff = parse_proposal_diff(Path(args.proposal_diff), skill_root_relative, skill)
    index = parse_index(root)
    pattern_records = tuple(validate_pattern(root, slug, index) for slug in patterns)
    validate_purpose_links(candidate, root, pattern_records)
    validate_qualification(Path(args.qualification), pattern_records)
    return PreEvaluationProposal(
        root=root,
        skill=skill,
        patterns=patterns,
        new_evidence=new_evidence,
        proposal_diff=proposal_diff,
    )


def build_static_proposal(
    args: argparse.Namespace,
    pre_evaluation: PreEvaluationProposal | None = None,
) -> StaticProposal:
    pre = pre_evaluation if pre_evaluation is not None else build_pre_evaluation_proposal(args)
    benchmark = parse_benchmark(Path(args.benchmark), pre.skill)
    receipt = parse_receipt(Path(args.receipt))
    proposal = StaticProposal(
        root=pre.root,
        skill=pre.skill,
        patterns=pre.patterns,
        new_evidence=pre.new_evidence,
        proposal_diff=pre.proposal_diff,
        benchmark=benchmark,
        receipt=receipt,
        process_gate_path=Path(args.process_gate_receipt),
    )
    validate_benchmark_receipt_match(proposal)
    return proposal


def check_proposal(args: argparse.Namespace) -> dict[str, Any]:
    pre = build_pre_evaluation_proposal(args)
    ledger = load_ledger(pre.root)
    enforce_rejected_set_rule(ledger, pre.patterns, pre.new_evidence)
    proposal = build_static_proposal(args, pre)
    history = validate_history_integrity(proposal.root, ledger)
    if proposal.receipt.proposal_sha in history:
        raise NotReadyError("proposal SHA is already recorded")
    validate_eval_passed_gate(proposal.root, ledger, proposal)
    return {
        "status": "EVAL-PASSED",
        "skill": proposal.skill,
        "proposal_sha": proposal.receipt.proposal_sha,
        "patterns": list(proposal.patterns),
        "new_evidence": list(proposal.new_evidence),
        "score": proposal.receipt.score_text,
        "best_before": proposal.receipt.best_before_text,
        "baseline": proposal.receipt.baseline_text,
    }


@contextmanager
def exclusive_lock(handle: TextIO) -> Iterator[None]:
    if fcntl is None:
        fail("record requires a platform with advisory file locking")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    except OSError as error:
        fail(f"could not lock proposal record: {error}")
    try:
        yield
    finally:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass


def directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def open_directory_descriptor(path: Path, label: str) -> int:
    try:
        descriptor = os.open(path, directory_open_flags())
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            fail(f"{label} must be a real directory")
        return descriptor
    except ProposalError:
        raise
    except OSError as error:
        fail(f"could not open {label}: {error}")


def open_child_directory(
    parent_descriptor: int,
    name: str,
    label: str,
    *,
    create: bool,
) -> tuple[int, bool]:
    created = False
    if create:
        try:
            os.mkdir(name, mode=0o755, dir_fd=parent_descriptor)
            created = True
        except FileExistsError:
            pass
        except OSError as error:
            fail(f"could not create {label}: {error}")
    try:
        descriptor = os.open(
            name,
            directory_open_flags(),
            dir_fd=parent_descriptor,
        )
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            fail(f"{label} must be a real directory")
        return descriptor, created
    except ProposalError:
        raise
    except OSError as error:
        if created:
            try:
                os.rmdir(name, dir_fd=parent_descriptor)
            except OSError as cleanup_error:
                fail(
                    f"could not open {label}: {error}; "
                    f"could not roll back its directory: {cleanup_error}"
                )
        fail(f"could not open {label}: {error}")


def open_locked_ledger(root: Path) -> TextIO:
    wiki = validated_wiki_directory(root)
    path = wiki / "skill-impact.md"
    ensure_regular_file_below(root, path, "impact ledger")
    wiki_descriptor = open_directory_descriptor(wiki, "wiki directory")
    descriptor = -1
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open("skill-impact.md", flags, dir_fd=wiki_descriptor)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            fail("impact ledger must be a regular file")
        handle = os.fdopen(descriptor, "r+", encoding="utf-8", newline="")
        descriptor = -1
        return handle
    except ProposalError:
        raise
    except OSError as error:
        fail(f"could not open impact ledger for locked recording: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(wiki_descriptor)


def read_locked_text(handle: TextIO, label: str) -> str:
    try:
        handle.seek(0)
        return handle.read()
    except (OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")


def ledger_from_locked_handle(handle: TextIO) -> Ledger:
    return parse_ledger_text(read_locked_text(handle, "locked impact ledger"))


def write_locked_text(handle: TextIO, text: str, label: str) -> None:
    try:
        handle.seek(0)
        handle.write(text)
        handle.truncate()
        handle.flush()
        os.fsync(handle.fileno())
    except (OSError, UnicodeError) as error:
        fail(f"could not write {label}: {error}")


def rollback_locked_texts(states: Sequence[tuple[TextIO, str, str]]) -> tuple[str, ...]:
    errors: list[str] = []
    for handle, original, label in states:
        try:
            write_locked_text(handle, original, label)
        except Exception as error:
            errors.append(f"{label}: {error}")
    return tuple(errors)


def receipt_relative_target(receipt: Receipt) -> str:
    return f"skill-impact/{receipt.skill}/{receipt.run_date}-{receipt.proposal_sha[:12]}.json"


def format_diff_ref(proposal: StaticProposal) -> str:
    evidence = ",".join(proposal.new_evidence) if proposal.new_evidence else "none"
    return (
        f"diff={proposal.proposal_diff.base}..{proposal.proposal_diff.head}; "
        f"patterns={','.join(proposal.patterns)}; new-evidence={evidence}"
    )


def format_ledger_row(proposal: StaticProposal, verdict: str, pr: str, receipt_target: str) -> str:
    return (
        f"| {proposal.receipt.run_date} | {proposal.skill} | {format_diff_ref(proposal)} | "
        f"{proposal.receipt.score_text} | {proposal.receipt.best_before_text} | {verdict} | {pr} | "
        f"[run receipt]({receipt_target}) |"
    )


def format_finalized_ledger_row(row: LedgerRow, verdict: str, pr: str) -> str:
    return (
        f"| {row.date} | {row.skill} | {row.diff_ref} | {row.score_text} | "
        f"{row.best_before_text} | {verdict} | {pr} | {row.receipt_cell} |"
    )


def serialize_ledger(ledger: Ledger) -> str:
    return "\n".join(ledger.lines) + "\n"


def insert_ledger_row(ledger: Ledger, line: str) -> None:
    insertion = ledger.rows[-1].line_index + 1 if ledger.rows else ledger.divider_index + 1
    ledger.lines.insert(insertion, line)


def open_existing_sidecar(root: Path, row: LedgerRow) -> TextIO:
    path = receipt_path_for_row(root, row)
    ensure_real_directory_below(root, path.parent, "impact receipt skill directory")
    ensure_regular_file_below(root, path, "proposal receipt")
    wiki_descriptor = open_directory_descriptor(
        validated_wiki_directory(root),
        "wiki directory",
    )
    impact_descriptor = -1
    skill_descriptor = -1
    descriptor = -1
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        impact_descriptor, _ = open_child_directory(
            wiki_descriptor,
            "skill-impact",
            "wiki/skill-impact",
            create=False,
        )
        skill_descriptor, _ = open_child_directory(
            impact_descriptor,
            row.skill,
            "impact receipt skill directory",
            create=False,
        )
        descriptor = os.open(path.name, flags, dir_fd=skill_descriptor)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            fail("proposal receipt must be a regular file")
        handle = os.fdopen(descriptor, "r+", encoding="utf-8", newline="")
        descriptor = -1
        return handle
    except ProposalError:
        raise
    except OSError as error:
        fail(f"could not open existing proposal receipt for finalization: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        for directory_descriptor in (skill_descriptor, impact_descriptor, wiki_descriptor):
            if directory_descriptor >= 0:
                os.close(directory_descriptor)


@contextmanager
def write_new_sidecar(root: Path, receipt: Receipt) -> Iterator[TextIO]:
    relative_target = receipt_relative_target(receipt)
    wiki = validated_wiki_directory(root)
    path = wiki / relative_target
    expected_parent = wiki / "skill-impact" / receipt.skill
    if path.parent != expected_parent or relative_to_or_none(path, root) is None:
        fail("computed receipt path is not canonical or beneath the project root")

    wiki_descriptor = open_directory_descriptor(wiki, "wiki directory")
    impact_descriptor = -1
    skill_descriptor = -1
    descriptor = -1
    sidecar_handle: TextIO | None = None
    impact_created = False
    skill_created = False
    file_created = False
    keep_file = False
    cleanup_errors: list[str] = []
    try:
        impact_descriptor, impact_created = open_child_directory(
            wiki_descriptor,
            "skill-impact",
            "wiki/skill-impact",
            create=True,
        )
        skill_descriptor, skill_created = open_child_directory(
            impact_descriptor,
            receipt.skill,
            "impact receipt skill directory",
            create=True,
        )
        try:
            descriptor = os.open(
                path.name,
                os.O_RDWR
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                0o644,
                dir_fd=skill_descriptor,
            )
        except FileExistsError as error:
            raise NotReadyError("proposal receipt already exists") from error
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            fail("new proposal receipt must be a regular file")
        file_created = True
        sidecar_handle = os.fdopen(descriptor, "r+", encoding="utf-8", newline="")
        descriptor = -1
        yield sidecar_handle
        sidecar_handle.close()
        sidecar_handle = None
        keep_file = True
    except ProposalError:
        raise
    except OSError as error:
        fail(f"could not create proposal receipt: {error}")
    finally:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if sidecar_handle is not None:
            try:
                sidecar_handle.close()
            except OSError as error:
                cleanup_errors.append(f"proposal receipt: {error}")
        if not keep_file and file_created and skill_descriptor >= 0:
            try:
                os.unlink(path.name, dir_fd=skill_descriptor)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_errors.append(f"proposal receipt: {error}")
        if skill_descriptor >= 0:
            try:
                os.close(skill_descriptor)
            except OSError:
                pass
        if not keep_file and skill_created and impact_descriptor >= 0:
            try:
                os.rmdir(receipt.skill, dir_fd=impact_descriptor)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_errors.append(f"receipt skill directory: {error}")
        if impact_descriptor >= 0:
            try:
                os.close(impact_descriptor)
            except OSError:
                pass
        if not keep_file and impact_created:
            try:
                os.rmdir("skill-impact", dir_fd=wiki_descriptor)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_errors.append(f"wiki/skill-impact: {error}")
        try:
            os.close(wiki_descriptor)
        except OSError:
            pass
        if cleanup_errors:
            raise MalformedError(
                "could not complete proposal receipt rollback: "
                + "; ".join(cleanup_errors)
            )


def receipt_json_text(receipt: Receipt) -> str:
    value = {field: receipt.raw[field] for field in RECEIPT_FIELD_ORDER}
    value["runner_model"] = {
        role: receipt.runner_model[role] for role in RUNNER_FIELD_ORDER
    }
    return json.dumps(value, indent=2, ensure_ascii=True) + "\n"


def immutable_receipt_fields_match(existing: Receipt, incoming: Receipt) -> bool:
    for field in RECEIPT_FIELDS - {"verdict"}:
        if existing.raw[field] != incoming.raw[field]:
            return False
    return True


def row_matches_proposal(row: LedgerRow, proposal: StaticProposal) -> bool:
    return (
        row.skill == proposal.skill
        and row.date == proposal.receipt.run_date
        and row.diff_base == proposal.proposal_diff.base
        and row.diff_head == proposal.proposal_diff.head
        and row.patterns == proposal.patterns
        and row.new_evidence == proposal.new_evidence
        and row.score == proposal.receipt.score
        and row.best_before == proposal.receipt.best_before
    )


def record_new(
    ledger_handle: TextIO,
    ledger: Ledger,
    proposal: StaticProposal,
    pr: str,
) -> dict[str, Any]:
    enforce_rejected_set_rule(ledger, proposal.patterns, proposal.new_evidence)
    # The caller validated the complete locked history before dispatching here.
    if proposal.receipt.verdict == "eval-passed":
        validate_eval_passed_gate(proposal.root, ledger, proposal)
    elif proposal.receipt.verdict == "failed":
        expected_best = applicable_best_before(proposal.root, ledger, proposal)
        if proposal.receipt.best_before != expected_best:
            raise NotReadyError("failed receipt best_before does not match the applicable comparison")
        gate_failed = (
            proposal.receipt.score <= expected_best
            or not proposal.receipt.runner_families_separated
        )
        try:
            validate_process_gate(proposal.process_gate_path)
        except NotReadyError:
            gate_failed = True
        if not gate_failed:
            raise NotReadyError("a passing evaluation and process receipt cannot be recorded as failed")
    else:
        raise NotReadyError("a new proposal may be recorded only as eval-passed or failed")

    receipt_target = receipt_relative_target(proposal.receipt)
    original_ledger_text = read_locked_text(ledger_handle, "locked impact ledger")
    mutation_started = False
    try:
        with write_new_sidecar(proposal.root, proposal.receipt) as sidecar_handle:
            with exclusive_lock(sidecar_handle):
                mutation_started = True
                write_locked_text(
                    sidecar_handle,
                    receipt_json_text(proposal.receipt),
                    "proposal receipt",
                )
                insert_ledger_row(
                    ledger,
                    format_ledger_row(
                        proposal,
                        proposal.receipt.verdict,
                        pr,
                        receipt_target,
                    ),
                )
                write_locked_text(
                    ledger_handle,
                    serialize_ledger(ledger),
                    "impact ledger",
                )
    except BaseException as error:
        if mutation_started:
            rollback_errors = rollback_locked_texts(
                ((ledger_handle, original_ledger_text, "impact ledger rollback"),)
            )
            if rollback_errors:
                raise MalformedError(
                    "proposal recording failed and the impact ledger could not be restored: "
                    + "; ".join(rollback_errors)
                ) from error
        raise
    return {
        "status": "RECORDED",
        "action": "created",
        "skill": proposal.skill,
        "proposal_sha": proposal.receipt.proposal_sha,
        "verdict": proposal.receipt.verdict,
        "pr": pr,
        "receipt": f"wiki/{receipt_target}",
    }


def record_existing(
    ledger_handle: TextIO,
    ledger: Ledger,
    proposal: StaticProposal,
    pr: str,
    row: LedgerRow,
    existing_receipt: Receipt,
) -> dict[str, Any]:
    if not row_matches_proposal(row, proposal):
        raise NotReadyError("record finalization must preserve the original proposal row")
    if not immutable_receipt_fields_match(existing_receipt, proposal.receipt):
        raise NotReadyError("record finalization must preserve every receipt field except verdict")
    old_verdict = row.verdict
    new_verdict = proposal.receipt.verdict
    if existing_receipt.verdict != old_verdict:
        fail("existing ledger row and receipt verdict disagree")
    verdict_changed = new_verdict != old_verdict
    if verdict_changed and not (old_verdict == "eval-passed" and new_verdict in {"accepted", "rejected"}):
        raise NotReadyError("receipt verdict transition is backward or terminal")
    pr_changed = pr != row.pr
    if pr_changed and not (row.pr == "not-opened" and PR_URL_RE.fullmatch(pr)):
        raise NotReadyError("PR transition must be forward from not-opened to an HTTPS pull-request URL")
    if not verdict_changed and not pr_changed:
        raise NotReadyError("duplicate record operation would make no forward transition")
    if new_verdict == "accepted":
        if not PR_URL_RE.fullmatch(pr):
            raise NotReadyError("accepted finalization requires an HTTPS pull-request URL")
        validate_process_gate(proposal.process_gate_path)

    sidecar_handle = open_existing_sidecar(proposal.root, row)
    try:
        with exclusive_lock(sidecar_handle):
            original_sidecar_text = read_locked_text(
                sidecar_handle,
                "locked proposal receipt",
            )
            try:
                locked_value = json.loads(
                    original_sidecar_text,
                    parse_float=Decimal,
                    parse_int=int,
                    parse_constant=reject_json_constant,
                    object_pairs_hook=unique_json_object,
                )
            except (UnicodeError, json.JSONDecodeError) as error:
                fail(f"could not reread locked proposal receipt: {error}")
            locked_receipt = parse_receipt_value(
                locked_value,
                "locked proposal receipt",
            )
            if locked_receipt.raw != existing_receipt.raw:
                raise NotReadyError("proposal receipt changed while awaiting finalization")

            original_ledger_text = read_locked_text(
                ledger_handle,
                "locked impact ledger",
            )
            ledger.lines[row.line_index] = format_finalized_ledger_row(
                row,
                new_verdict,
                pr,
            )
            new_sidecar_text = receipt_json_text(proposal.receipt)
            new_ledger_text = serialize_ledger(ledger)
            try:
                write_locked_text(
                    sidecar_handle,
                    new_sidecar_text,
                    "proposal receipt",
                )
                write_locked_text(
                    ledger_handle,
                    new_ledger_text,
                    "impact ledger",
                )
            except BaseException as error:
                rollback_errors = rollback_locked_texts(
                    (
                        (
                            ledger_handle,
                            original_ledger_text,
                            "impact ledger rollback",
                        ),
                        (
                            sidecar_handle,
                            original_sidecar_text,
                            "proposal receipt rollback",
                        ),
                    )
                )
                if rollback_errors:
                    raise MalformedError(
                        "proposal finalization failed and durable state could not be restored: "
                        + "; ".join(rollback_errors)
                    ) from error
                raise
    finally:
        sidecar_handle.close()
    action = "finalized" if verdict_changed else "pr-finalized"
    return {
        "status": "RECORDED",
        "action": action,
        "skill": proposal.skill,
        "proposal_sha": proposal.receipt.proposal_sha,
        "verdict": new_verdict,
        "pr": pr,
        "receipt": f"wiki/{row.receipt_target}",
    }


def record_proposal(args: argparse.Namespace) -> dict[str, Any]:
    proposal = build_static_proposal(args)
    pr = require_plain_string(args.pr, "PR")
    validate_pr_value(pr, "record")
    ledger_handle = open_locked_ledger(proposal.root)
    try:
        with exclusive_lock(ledger_handle):
            ledger = ledger_from_locked_handle(ledger_handle)
            # Refuse a matching rejected set before demanding its historical
            # sidecar. This preserves the required pre-evaluation short circuit.
            matching = matching_rejected_rows(ledger, proposal.patterns)
            current_row = next(
                (row for row in ledger.rows if row.diff_head == proposal.receipt.proposal_sha),
                None,
            )
            if current_row is None and matching and not proposal.new_evidence:
                enforce_rejected_set_rule(ledger, proposal.patterns, proposal.new_evidence)
            history = validate_history_integrity(proposal.root, ledger)
            existing = history.get(proposal.receipt.proposal_sha)
            if existing is None:
                return record_new(ledger_handle, ledger, proposal, pr)
            row, existing_receipt = existing
            return record_existing(ledger_handle, ledger, proposal, pr, row, existing_receipt)
    finally:
        ledger_handle.close()


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", required=True, help="project root")
    parser.add_argument("--candidate", required=True, help="candidate skill directory")
    parser.add_argument("--patterns", required=True, help="comma-separated motivating pattern slugs")
    parser.add_argument("--benchmark", required=True, help="standard skill-creator benchmark.json")
    parser.add_argument("--receipt", required=True, help="exact nine-field machine receipt JSON")
    parser.add_argument("--process-gate-receipt", required=True, help="merge-mode process-gate receipt")
    parser.add_argument("--proposal-diff", required=True, help="PR-wide changed-path JSON manifest")
    parser.add_argument("--qualification", required=True, help="wiki qualification decision JSON")
    parser.add_argument(
        "--skill-root",
        default="core-rules/skills",
        help="repository-relative tracked skill root (default: core-rules/skills)",
    )
    parser.add_argument(
        "--new-evidence",
        action="append",
        default=[],
        help="fresh evidence link; repeat for multiple links",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    check = subparsers.add_parser("check", help="read-only review-readiness validation")
    add_common_arguments(check)
    record = subparsers.add_parser("record", help="locked ledger/sidecar create or forward finalization")
    add_common_arguments(record)
    record.add_argument("--pr", required=True, help="HTTPS pull-request URL or not-opened")
    return parser


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        if args.operation == "check":
            emit(check_proposal(args))
        else:
            emit(record_proposal(args))
        return 0
    except NotReadyError as error:
        emit({"status": "NOT-READY", "error": str(error)})
        return EXIT_NOT_READY
    except MalformedError as error:
        emit({"status": "MALFORMED", "error": str(error)})
        return EXIT_MALFORMED
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        emit({"status": "MALFORMED", "error": f"artifact I/O failed: {error}"})
        return EXIT_MALFORMED
    except KeyboardInterrupt:
        emit({"status": "MALFORMED", "error": "interrupted"})
        return EXIT_MALFORMED


if __name__ == "__main__":
    raise SystemExit(main())
