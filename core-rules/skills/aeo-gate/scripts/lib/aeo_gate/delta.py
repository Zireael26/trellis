from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

from .manifest import verify_manifest
from .models import (
    Baseline,
    Disposition,
    EvidenceGrade,
    Finding,
    Impact,
    MappingResult,
    RawArtifact,
    SCHEMA,
    StageResult,
    Status,
)


def compare(
    findings: Iterable[Finding], previous_fingerprints: Iterable[str]
) -> tuple[list[str], list[str], list[str]]:
    current = {finding.fingerprint for finding in findings}
    previous = {str(fingerprint) for fingerprint in previous_fingerprints}
    return (
        sorted(current - previous),
        sorted(current & previous),
        sorted(previous - current),
    )


def validate_accepted_baseline(
    path: Path,
    *,
    project: str,
    domain: str,
    checkout: str,
    allow_fixture: bool = False,
) -> dict[str, Any]:
    manifest_path = path.parent / "manifest.json"
    manifest_errors = verify_manifest(manifest_path)
    if manifest_errors:
        raise ValueError(
            "accepted baseline manifest is invalid: " + "; ".join(manifest_errors)
        )
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        baseline = _parse_baseline(payload)
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"accepted baseline is invalid: {exc}") from exc
    manifest_artifacts = {
        item["path"]: item
        for item in manifest["artifacts"]
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    manifest_paths = set(manifest_artifacts)
    if path.name not in manifest_paths:
        raise ValueError("accepted baseline is not tracked by its manifest")
    if baseline.overall_status is not Status.PASS:
        raise ValueError("accepted baseline status must be PASS")
    if baseline.fixture and not allow_fixture:
        raise ValueError("fixture evidence cannot be an accepted baseline")
    expected = (project, domain, checkout)
    if (baseline.project, baseline.domain, baseline.checkout) != expected:
        raise ValueError("accepted baseline identity does not match the current target")
    if not baseline.mapping.proven:
        raise ValueError("accepted baseline mapping is not proven")
    raw_paths = {artifact.path for artifact in baseline.raw_artifacts}
    if not raw_paths.issubset(manifest_paths):
        raise ValueError("accepted baseline raw evidence is not fully manifested")
    if any(
        manifest_artifacts[artifact.path].get("bytes") != artifact.bytes
        or manifest_artifacts[artifact.path].get("sha256") != artifact.sha256
        for artifact in baseline.raw_artifacts
    ):
        raise ValueError(
            "accepted baseline raw evidence metadata does not match manifest"
        )
    if any(
        not set(stage.raw_artifacts).issubset(raw_paths) for stage in baseline.stages
    ):
        raise ValueError("accepted baseline stage references unknown raw evidence")
    if any(
        finding.raw_evidence.split("#", 1)[0] not in raw_paths
        for finding in baseline.findings
    ):
        raise ValueError("accepted baseline finding references unknown raw evidence")
    return payload


def _parse_baseline(payload: Any) -> Baseline:
    if not isinstance(payload, dict):
        raise ValueError("payload must be an object")
    mapping_payload = payload["mapping"]
    mapping = MappingResult(
        status=Status(mapping_payload["status"]),
        reason=mapping_payload["reason"],
        project=mapping_payload["project"],
        domain=mapping_payload["domain"],
        checkout=mapping_payload["checkout"],
        marker_file=mapping_payload["marker_file"],
        local_marker_sha256=mapping_payload["local_marker_sha256"],
        live_marker_sha256=mapping_payload["live_marker_sha256"],
        local_source_sha256=mapping_payload["local_source_sha256"],
        live_html_sha256=mapping_payload["live_html_sha256"],
    )
    stages = [
        StageResult(
            name=item["name"],
            status=Status(item["status"]),
            reason=item["reason"],
            raw_artifacts=tuple(item["raw_artifacts"]),
        )
        for item in payload["stages"]
    ]
    artifacts = [RawArtifact(**item) for item in payload["raw_artifacts"]]
    findings = [
        Finding(
            detector=item["detector"],
            rule=item["rule"],
            subject=item["subject"],
            state=item["state"],
            severity=item["severity"],
            evidence_grade=EvidenceGrade(item["evidence_grade"]),
            seo_impact=Impact(item["seo_impact"]),
            aeo_impact=Impact(item["aeo_impact"]),
            disposition=Disposition(item["disposition"]),
            rationale=item["rationale"],
            raw_evidence=item["raw_evidence"],
            url=item["url"],
            source_path=item["source_path"],
            suggested_action=item["suggested_action"],
        )
        for item in payload["findings"]
    ]
    delta = payload["delta"]
    baseline = Baseline(
        project=payload["project"],
        domain=payload["domain"],
        checkout=payload["checkout"],
        commit=payload["commit"],
        generated_at=payload["generated_at"],
        mapping=mapping,
        fixture=payload["fixture"],
        stages=stages,
        raw_artifacts=artifacts,
        findings=findings,
        new=delta["new"],
        unchanged=delta["unchanged"],
        resolved=delta["resolved"],
        tools=payload["tools"],
        overall_status=Status(payload["overall_status"]),
        schema=payload["schema"],
    )
    if baseline.as_dict() != payload:
        raise ValueError("payload is not canonical or contains invalid fields")
    return baseline


def load_previous_fingerprints(path: Path | None) -> set[str]:
    if path is None:
        return set()
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema") != SCHEMA:
        raise ValueError(f"unsupported baseline schema: {payload.get('schema')!r}")
    findings = payload.get("findings")
    if not isinstance(findings, list):
        raise ValueError("baseline findings must be a list")
    fingerprints: set[str] = set()
    for finding in findings:
        if not isinstance(finding, dict) or not isinstance(
            finding.get("fingerprint"), str
        ):
            raise ValueError("baseline finding is missing a fingerprint")
        fingerprints.add(finding["fingerprint"])
    return fingerprints
