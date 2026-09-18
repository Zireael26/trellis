from __future__ import annotations

from pathlib import Path

from .capture import atomic_write
from .models import Baseline, canonical_json


def write_outputs(baseline: Baseline, run_dir: Path) -> tuple[Path, Path]:
    payload = baseline.as_dict()
    json_path = run_dir / "baseline.json"
    markdown_path = run_dir / "baseline.md"
    atomic_write(json_path, canonical_json(payload))
    atomic_write(markdown_path, render_markdown(baseline))
    return json_path, markdown_path


def render_markdown(baseline: Baseline) -> str:
    lines = [
        f"# AEO gate: {baseline.project}",
        "",
        f"- Domain: `{baseline.domain}`",
        f"- Commit: `{baseline.commit}`",
        f"- Mapping: **{baseline.mapping.status}** — {baseline.mapping.reason}",
        f"- Overall status: **{baseline.overall_status}**",
        "",
        "## Stage status",
        "",
        "| Stage | Status | Reason |",
        "|---|---|---|",
    ]
    for stage in sorted(baseline.stages, key=lambda item: item.name):
        lines.append(
            f"| {escape(stage.name)} | {stage.status} | {escape(stage.reason)} |"
        )
    lines.extend(
        [
            "",
            "## Finding delta",
            "",
            f"- New: {len(baseline.new)}",
            f"- Unchanged: {len(baseline.unchanged)}",
            f"- Resolved: {len(baseline.resolved)}",
            "",
            "## Graded findings",
            "",
        ]
    )
    if not baseline.findings:
        lines.append("No normalized findings.")
    for finding in sorted(baseline.findings, key=lambda item: item.fingerprint):
        lines.extend(
            [
                f"### `{finding.fingerprint}` {escape(finding.subject)}",
                "",
                f"- Detector/rule: `{escape(finding.detector)}` / `{escape(finding.rule)}`",
                f"- State/severity: `{escape(finding.state)}` / `{escape(finding.severity)}`",
                f"- Evidence: **{finding.evidence_grade}**",
                f"- SEO impact: `{finding.seo_impact}`",
                f"- AEO impact: `{finding.aeo_impact}`",
                f"- Disposition: `{finding.disposition}`",
                f"- Raw evidence: `{finding.raw_evidence}`",
                f"- Rationale: {escape(finding.rationale)}",
            ]
        )
        if finding.suggested_action:
            lines.append(f"- Suggested action: {escape(finding.suggested_action)}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("|", "\\|")
        .replace("`", "\\`")
        .replace("\n", " ")
    )
