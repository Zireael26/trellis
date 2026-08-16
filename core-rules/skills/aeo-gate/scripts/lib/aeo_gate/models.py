from __future__ import annotations

import hashlib
import json
import re
from dataclasses import asdict, dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

SCHEMA = "aeo-gate.baseline.v1"


class Status(StrEnum):
    PASS = "PASS"
    REGRESSION = "REGRESSION"
    INDETERMINATE = "INDETERMINATE"


class EvidenceGrade(StrEnum):
    STRONG = "STRONG"
    MODERATE = "MODERATE"
    SPECULATIVE = "SPECULATIVE"


class Disposition(StrEnum):
    KEPT = "kept"
    DROPPED = "dropped"
    AMBIGUOUS = "ambiguous"
    NO_LLM_PASS = "no-llm-pass"


class Impact(StrEnum):
    HELPS = "helps"
    HURTS = "hurts"
    NEUTRAL = "neutral"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class Finding:
    detector: str
    rule: str
    subject: str
    state: str
    severity: str
    evidence_grade: EvidenceGrade
    seo_impact: Impact
    aeo_impact: Impact
    disposition: Disposition
    rationale: str
    raw_evidence: str
    url: str = ""
    source_path: str = ""
    suggested_action: str = ""
    fingerprint: str = ""

    def __post_init__(self) -> None:
        text_fields = (
            self.detector,
            self.rule,
            self.subject,
            self.state,
            self.severity,
            self.rationale,
            self.raw_evidence,
        )
        if not all(isinstance(value, str) and value for value in text_fields):
            raise ValueError("finding required text fields must be non-empty strings")
        if not all(
            isinstance(value, str)
            for value in (self.url, self.source_path, self.suggested_action)
        ):
            raise ValueError("finding optional text fields must be strings")
        if not self.url and not self.source_path:
            raise ValueError("finding URL or source_path is required")
        if not isinstance(self.evidence_grade, EvidenceGrade):
            raise ValueError("finding evidence_grade must be an EvidenceGrade")
        if not isinstance(self.seo_impact, Impact) or not isinstance(
            self.aeo_impact, Impact
        ):
            raise ValueError("finding impacts must be Impact values")
        if not isinstance(self.disposition, Disposition):
            raise ValueError("finding disposition must be a Disposition")
        if (
            self.disposition in {Disposition.DROPPED, Disposition.AMBIGUOUS}
            and self.suggested_action
        ):
            raise ValueError("dropped or ambiguous findings cannot suggest actions")
        if self.evidence_grade is EvidenceGrade.SPECULATIVE and self.suggested_action:
            raise ValueError("speculative findings cannot suggest actions")
        if not self.fingerprint:
            object.__setattr__(self, "fingerprint", finding_fingerprint(self))

    def as_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        for key in ("evidence_grade", "seo_impact", "aeo_impact", "disposition"):
            payload[key] = str(payload[key])
        return payload


@dataclass(frozen=True)
class MappingResult:
    status: Status
    reason: str
    project: str = ""
    domain: str = ""
    checkout: str = ""
    marker_file: str = ""
    local_marker_sha256: str = ""
    live_marker_sha256: str = ""
    local_source_sha256: str = ""
    live_html_sha256: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.status, Status):
            raise ValueError("mapping status must be a Status")
        if not isinstance(self.reason, str) or not self.reason:
            raise ValueError("mapping reason must be a non-empty string")
        if not all(
            isinstance(value, str)
            for value in (
                self.project,
                self.domain,
                self.checkout,
                self.marker_file,
                self.local_marker_sha256,
                self.live_marker_sha256,
                self.local_source_sha256,
                self.live_html_sha256,
            )
        ):
            raise ValueError("mapping evidence fields must be strings")
        if self.proven:
            hashes = (
                self.local_marker_sha256,
                self.live_marker_sha256,
                self.local_source_sha256,
                self.live_html_sha256,
            )
            if (
                not self.checkout
                or not self.marker_file
                or not all(re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes)
            ):
                raise ValueError("proven mapping requires complete checksum evidence")
            if self.local_marker_sha256 != self.live_marker_sha256:
                raise ValueError("proven mapping marker checksums must match")

    @property
    def proven(self) -> bool:
        return self.status is Status.PASS


@dataclass(frozen=True)
class StageResult:
    name: str
    status: Status
    reason: str = ""
    raw_artifacts: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name:
            raise ValueError("stage name must be a non-empty string")
        if not isinstance(self.reason, str) or not isinstance(
            self.raw_artifacts, tuple
        ):
            raise ValueError("stage reason and raw_artifacts have invalid types")
        if not all(isinstance(path, str) for path in self.raw_artifacts):
            raise ValueError("stage raw artifact paths must be strings")
        if not isinstance(self.status, Status):
            raise ValueError("stage status must be a Status")


@dataclass(frozen=True)
class RawArtifact:
    path: str
    bytes: int
    sha256: str

    def __post_init__(self) -> None:
        if not isinstance(self.path, str):
            raise ValueError("raw artifact path must be a string")
        if (
            not self.path
            or Path(self.path).is_absolute()
            or ".." in Path(self.path).parts
        ):
            raise ValueError("raw artifact path must be safe and relative")
        if not isinstance(self.bytes, int) or self.bytes < 0:
            raise ValueError("raw artifact byte count must be a non-negative integer")
        if not isinstance(self.sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", self.sha256
        ):
            raise ValueError("raw artifact sha256 must be lowercase hexadecimal")


@dataclass
class Baseline:
    project: str
    domain: str
    checkout: str
    commit: str
    generated_at: str
    mapping: MappingResult
    fixture: bool = False
    stages: list[StageResult] = field(default_factory=list)
    raw_artifacts: list[RawArtifact] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    new: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)
    resolved: list[str] = field(default_factory=list)
    tools: dict[str, str] = field(default_factory=dict)
    overall_status: Status = Status.INDETERMINATE
    schema: str = SCHEMA

    def __post_init__(self) -> None:
        identity = (
            self.project,
            self.domain,
            self.checkout,
            self.commit,
            self.generated_at,
        )
        if not all(isinstance(value, str) and value for value in identity):
            raise ValueError("baseline identity fields must be non-empty strings")
        if not isinstance(self.fixture, bool):
            raise ValueError("baseline fixture flag must be boolean")
        if not isinstance(self.tools, dict) or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in self.tools.items()
        ):
            raise ValueError("baseline tools must map strings to strings")
        if not isinstance(self.mapping, MappingResult):
            raise ValueError("baseline mapping must be a MappingResult")
        if self.mapping.proven and (
            self.mapping.project != self.project
            or self.mapping.domain != self.domain
            or self.mapping.checkout != self.checkout
        ):
            raise ValueError("proven mapping identity must match baseline identity")
        if not isinstance(self.overall_status, Status):
            raise ValueError("baseline overall_status must be a Status")
        if self.schema != SCHEMA:
            raise ValueError(f"unsupported baseline schema: {self.schema!r}")

    def as_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schema": self.schema,
            "project": self.project,
            "domain": self.domain,
            "checkout": self.checkout,
            "commit": self.commit,
            "generated_at": self.generated_at,
            "mapping": {
                "status": str(self.mapping.status),
                "reason": self.mapping.reason,
                "project": self.mapping.project,
                "domain": self.mapping.domain,
                "checkout": self.mapping.checkout,
                "marker_file": self.mapping.marker_file,
                "local_marker_sha256": self.mapping.local_marker_sha256,
                "live_marker_sha256": self.mapping.live_marker_sha256,
                "local_source_sha256": self.mapping.local_source_sha256,
                "live_html_sha256": self.mapping.live_html_sha256,
            },
            "tools": dict(sorted(self.tools.items())),
            "fixture": self.fixture,
            "raw_artifacts": [
                asdict(artifact)
                for artifact in sorted(self.raw_artifacts, key=lambda item: item.path)
            ],
            "stages": [
                {
                    "name": stage.name,
                    "status": str(stage.status),
                    "reason": stage.reason,
                    "raw_artifacts": list(stage.raw_artifacts),
                }
                for stage in sorted(self.stages, key=lambda item: item.name)
            ],
            "findings": [
                finding.as_dict()
                for finding in sorted(self.findings, key=lambda item: item.fingerprint)
            ],
            "delta": {
                "new": sorted(self.new),
                "unchanged": sorted(self.unchanged),
                "resolved": sorted(self.resolved),
            },
            "overall_status": str(self.overall_status),
        }
        assert_no_composite_score(payload)
        return payload


def finding_fingerprint(finding: Finding) -> str:
    identity = "\0".join(
        (
            finding.detector.strip().lower(),
            finding.rule.strip().lower(),
            normalize_locator(finding.url or finding.source_path),
            normalize_subject(finding.subject),
            finding.state.strip().lower(),
        )
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]


def normalize_subject(value: str) -> str:
    return " ".join(value.strip().lower().split()).rstrip("/")


def normalize_locator(value: str) -> str:
    normalized = " ".join(value.strip().split())
    parsed = urlsplit(normalized)
    if not parsed.scheme or not parsed.hostname:
        return normalized.rstrip("/")
    scheme = parsed.scheme.casefold()
    host = parsed.hostname.casefold()
    if ":" in host:
        host = f"[{host}]"
    try:
        port = parsed.port
    except ValueError:
        return normalized
    if port is not None and not (
        (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    ):
        host = f"{host}:{port}"
    path = parsed.path or "/"
    if path != "/":
        path = path.rstrip("/")
    return urlunsplit((scheme, host, path, parsed.query, ""))


def assert_no_composite_score(value: Any, path: str = "$") -> None:
    forbidden = {"score", "composite_score", "seo_aeo_score", "overall_score"}
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() in forbidden:
                raise ValueError(f"composite score field is forbidden at {path}.{key}")
            assert_no_composite_score(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_no_composite_score(child, f"{path}[{index}]")


def canonical_json(value: Any) -> str:
    assert_no_composite_score(value)
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
