from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from .models import MappingResult, Status

_PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def _validate_project_name(project: str) -> None:
    if not _PROJECT_NAME.fullmatch(project):
        raise ValueError(f"unsafe AEO target project name: {project!r}")


@dataclass(frozen=True)
class Target:
    project: str
    url: str
    checkout: str
    marker_file: str
    marker: str
    status: str = "active"
    reason: str = ""

    def __post_init__(self) -> None:
        _validate_project_name(self.project)
        parsed = urlparse(self.url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError(f"target URL must be absolute HTTP(S): {self.project}")
        if not Path(self.checkout).expanduser().is_absolute():
            raise ValueError(f"target checkout must be absolute: {self.project}")
        marker_path = Path(self.marker_file)
        if marker_path.is_absolute() or ".." in marker_path.parts:
            raise ValueError(f"unsafe target marker path: {self.project}")


def prove_mapping(
    checkout: Path,
    live_html: str,
    marker_file: str,
    marker: str,
    *,
    project: str = "",
    domain: str = "",
) -> MappingResult:
    root = checkout.resolve()
    identity = {
        "project": project,
        "domain": domain,
        "checkout": root.name,
        "marker_file": marker_file,
        "live_html_sha256": hashlib.sha256(live_html.encode("utf-8")).hexdigest(),
    }
    if not marker_file or not marker:
        return MappingResult(
            Status.INDETERMINATE,
            "mapping marker file and value are required",
            **identity,
        )
    if len(marker.strip()) < 16:
        return MappingResult(
            Status.INDETERMINATE,
            "mapping marker must be at least 16 characters",
            **identity,
        )
    candidate = (root / marker_file).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return MappingResult(
            Status.INDETERMINATE,
            "mapping marker file escapes checkout",
            **identity,
        )
    try:
        source = candidate.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return MappingResult(
            Status.INDETERMINATE,
            f"mapping marker file unreadable ({type(exc).__name__})",
            **identity,
        )
    local_count = source.count(marker)
    live_count = live_html.count(marker)
    marker_digest = hashlib.sha256(marker.encode("utf-8")).hexdigest()
    evidence = {
        **identity,
        "local_source_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "local_marker_sha256": marker_digest if local_count else "",
        "live_marker_sha256": marker_digest if live_count else "",
    }
    if local_count == 0:
        return MappingResult(
            Status.INDETERMINATE,
            "mapping marker is absent from checkout",
            **evidence,
        )
    if live_count == 0:
        return MappingResult(
            Status.INDETERMINATE,
            "mapping marker is absent from live HTML",
            **evidence,
        )
    observed_local = source[source.index(marker) : source.index(marker) + len(marker)]
    observed_live = live_html[
        live_html.index(marker) : live_html.index(marker) + len(marker)
    ]
    return MappingResult(
        Status.PASS,
        (
            "configured deployment identity and deterministic content marker "
            f"were observed ({local_count} local, {live_count} live)"
        ),
        project=project,
        domain=domain,
        checkout=root.name,
        marker_file=marker_file,
        local_marker_sha256=hashlib.sha256(observed_local.encode("utf-8")).hexdigest(),
        live_marker_sha256=hashlib.sha256(observed_live.encode("utf-8")).hexdigest(),
        local_source_sha256=hashlib.sha256(source.encode("utf-8")).hexdigest(),
        live_html_sha256=hashlib.sha256(live_html.encode("utf-8")).hexdigest(),
    )


def parse_targets(path: Path) -> tuple[list[Target], dict[str, str]]:
    active: list[Target] = []
    skipped: dict[str, str] = {}
    section = ""
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.casefold() == "## active targets":
            section = "active"
            continue
        if line.casefold() == "## explicit skips":
            section = "skips"
            continue
        if not line.startswith("|") or set(line.replace("|", "").strip()) <= {
            "-",
            ":",
            " ",
        }:
            continue
        columns = [column.strip() for column in line.strip("|").split("|")]
        if section == "active" and columns and columns[0].casefold() != "project":
            if len(columns) != 5:
                raise ValueError(f"active target row requires 5 columns: {line}")
            if not all(columns):
                raise ValueError(f"active target row has empty fields: {line}")
            active.append(Target(*columns))
        elif section == "skips" and columns and columns[0].casefold() != "project":
            if len(columns) != 2:
                raise ValueError(f"skip row requires 2 columns: {line}")
            if not all(columns):
                raise ValueError(f"skip row has empty fields: {line}")
            if columns[0] in skipped:
                raise ValueError(f"duplicate skip target: {columns[0]}")
            _validate_project_name(columns[0])
            skipped[columns[0]] = columns[1]
    duplicate = {
        target.project
        for target in active
        if sum(item.project == target.project for item in active) > 1
    }
    overlap = duplicate | ({target.project for target in active} & set(skipped))
    if overlap:
        raise ValueError(
            f"duplicate or conflicting targets: {', '.join(sorted(overlap))}"
        )
    return active, skipped


def reconcile_targets(
    *,
    registry_path: Path,
    blacklist_path: Path,
    active: list[Target],
    skipped: dict[str, str],
) -> None:
    eligible = _registry_projects(registry_path) - _temporary_blacklist(blacklist_path)
    if not eligible:
        raise ValueError("AEO target reconciliation has no eligible registry projects")
    accounted = {target.project for target in active} | set(skipped)
    missing = eligible - accounted
    unexpected = accounted - eligible
    if missing or unexpected:
        details = []
        if missing:
            details.append(f"missing: {', '.join(sorted(missing))}")
        if unexpected:
            details.append(f"unexpected: {', '.join(sorted(unexpected))}")
        raise ValueError(f"AEO target reconciliation failed ({'; '.join(details)})")


def _registry_projects(path: Path) -> set[str]:
    values = _section_first_column(path, "## active projects", None)
    if not values:
        raise ValueError("active project registry must not be empty")
    return set(values)


def _temporary_blacklist(path: Path) -> set[str]:
    return set(
        _section_first_column(
            path,
            "## 1. temporarily excluded (registered projects)",
            "## 2. permanently excluded from management",
        )
    )


def _section_first_column(
    path: Path, start_heading: str, end_heading: str | None
) -> list[str]:
    values: list[str] = []
    active = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        folded = line.casefold()
        if folded == start_heading:
            active = True
            continue
        if active and end_heading is not None and folded == end_heading:
            break
        if not active or not line.startswith("|"):
            continue
        columns = [column.strip() for column in line.strip("|").split("|")]
        if not columns or columns[0].casefold() in {"project", "path"}:
            continue
        if set(columns[0]) <= {"-", ":", " "}:
            continue
        value = columns[0].strip("`")
        _validate_project_name(value)
        values.append(value)
    if not active:
        raise ValueError(f"missing table section {start_heading!r} in {path}")
    duplicates = sorted({value for value in values if values.count(value) > 1})
    if duplicates:
        raise ValueError(
            f"duplicate projects in {start_heading!r}: {', '.join(duplicates)}"
        )
    return values
