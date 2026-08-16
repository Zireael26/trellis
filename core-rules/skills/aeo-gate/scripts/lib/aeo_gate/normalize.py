from __future__ import annotations

from typing import Any, Iterable

from .html import DocumentParser
from .jsonld import ABSENT, POPULATED, VACUOUS, classify_key, parse_jsonld_blocks
from .models import Disposition, EvidenceGrade, Finding, Impact
from .probe import ProbeObservation


def normalize(
    *,
    url: str,
    document: DocumentParser,
    scanner_payload: dict[str, Any],
    probes: Iterable[ProbeObservation],
    html_evidence: str,
    scanner_evidence: str,
) -> tuple[list[Finding], list[str]]:
    findings: list[Finding] = []
    errors: list[str] = []
    documents, jsonld_errors = parse_jsonld_blocks(document.jsonld_blocks)
    errors.extend(jsonld_errors)

    if len(document.visible_text) < 200:
        findings.append(
            Finding(
                detector="trellis-no-js",
                rule="substantive-content",
                subject="raw HTML visible content",
                state="insufficient",
                severity="high",
                evidence_grade=EvidenceGrade.STRONG,
                seo_impact=Impact.HURTS,
                aeo_impact=Impact.HURTS,
                disposition=Disposition.KEPT,
                rationale="AI retrieval crawlers do not execute page JavaScript; the raw response has insufficient visible text.",
                raw_evidence=html_evidence,
                url=url,
                suggested_action="Render substantive answer content in the initial HTML response.",
            )
        )

    if not documents:
        findings.append(
            Finding(
                detector="trellis-jsonld",
                rule="schema-presence",
                subject="JSON-LD graph",
                state=ABSENT,
                severity="medium",
                evidence_grade=EvidenceGrade.MODERATE,
                seo_impact=Impact.HURTS,
                aeo_impact=Impact.UNKNOWN,
                disposition=Disposition.KEPT,
                rationale="No valid JSON-LD document is present in the raw HTML.",
                raw_evidence=html_evidence,
                url=url,
                suggested_action="Add schema that truthfully describes the page and its publisher.",
            )
        )
    else:
        same_as_state, _ = classify_key(documents, "sameAs")
        if same_as_state != POPULATED:
            vacuous = same_as_state == VACUOUS
            findings.append(
                Finding(
                    detector="trellis-jsonld",
                    rule="entity-same-as",
                    subject="sameAs entity claims",
                    state=same_as_state,
                    severity="high" if vacuous else "medium",
                    evidence_grade=EvidenceGrade.MODERATE,
                    seo_impact=Impact.HURTS,
                    aeo_impact=Impact.UNKNOWN,
                    disposition=Disposition.KEPT,
                    rationale=(
                        "The JSON-LD graph makes an explicit but vacuous sameAs claim."
                        if vacuous
                        else "The full JSON-LD graph contains no sameAs claim."
                    ),
                    raw_evidence=html_evidence,
                    url=url,
                    suggested_action=(
                        "Populate or remove the vacuous sameAs claim."
                        if vacuous
                        else "Add verified entity URLs when the publisher has authoritative profiles."
                    ),
                )
            )

    for image in document.images:
        if image.decorative or image.alt_present:
            continue
        findings.append(
            Finding(
                detector="trellis-html",
                rule="image-alt-ambiguity",
                subject=image.src or "image without src",
                state="ambiguous",
                severity="info",
                evidence_grade=EvidenceGrade.MODERATE,
                seo_impact=Impact.UNKNOWN,
                aeo_impact=Impact.UNKNOWN,
                disposition=Disposition.AMBIGUOUS,
                rationale="The rendered markup does not prove whether this image is meaningful or decorative.",
                raw_evidence=html_evidence,
                url=url,
            )
        )

    for probe in probes:
        if 200 <= probe.status < 400:
            continue
        findings.append(
            Finding(
                detector="trellis-crawler",
                rule="crawler-access",
                subject=probe.agent,
                state=f"http-{probe.status}" if probe.status else "unreachable",
                severity="high",
                evidence_grade=EvidenceGrade.STRONG,
                seo_impact=Impact.UNKNOWN,
                aeo_impact=Impact.HURTS,
                disposition=Disposition.KEPT,
                rationale=(
                    f"{probe.agent} could not retrieve the page. Cloudflare cannot reliably allow search crawlers while blocking training crawlers as separate policy classes."
                ),
                raw_evidence=f"raw/probe-{probe.agent}.json",
                url=url,
                suggested_action="Review the observed crawler response and the site's bot policy without assuming a search/training split.",
            )
        )

    findings.extend(_scanner_findings(scanner_payload, url, scanner_evidence))
    return findings, errors


def _scanner_findings(
    payload: dict[str, Any], url: str, raw_evidence: str
) -> list[Finding]:
    raw_findings = payload.get("findings")
    if not isinstance(raw_findings, list):
        raw_findings = _failed_scanner_checks(payload.get("checks"))
    normalized: list[Finding] = []
    for index, raw in enumerate(raw_findings):
        if not isinstance(raw, dict):
            continue
        rule = str(raw.get("rule") or raw.get("id") or f"raw-{index}")
        message = str(raw.get("message") or raw.get("title") or rule)
        llms = "llms.txt" in f"{rule} {message}".casefold().replace("_", ".")
        normalized.append(
            Finding(
                detector="geo-optimizer",
                rule=rule,
                subject=str(raw.get("subject") or rule),
                state=str(raw.get("state") or "observed"),
                severity="info" if llms else str(raw.get("severity") or "info").lower(),
                evidence_grade=EvidenceGrade.SPECULATIVE,
                seo_impact=Impact.NEUTRAL if llms else Impact.UNKNOWN,
                aeo_impact=Impact.NEUTRAL if llms else Impact.UNKNOWN,
                disposition=Disposition.DROPPED if llms else Disposition.NO_LLM_PASS,
                rationale=(
                    "llms.txt has no confirmed retrieval benefit and cannot affect gate status."
                    if llms
                    else "Raw scanner observation retained for triage; it is not a work order."
                ),
                raw_evidence=raw_evidence,
                url=url,
            )
        )
    return normalized


def _failed_scanner_checks(checks: Any) -> list[dict[str, str]]:
    if not isinstance(checks, dict):
        return []
    findings: list[dict[str, str]] = []
    for rule, result in sorted(checks.items()):
        if not isinstance(result, dict) or result.get("passed") is not False:
            continue
        findings.append(
            {
                "rule": str(rule),
                "message": f"Scanner check {rule} failed",
                "state": "failed",
                "severity": "info",
            }
        )
    return findings
