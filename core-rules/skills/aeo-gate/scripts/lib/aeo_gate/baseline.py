from __future__ import annotations

import subprocess
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .capture import atomic_write, normalize_output_dir
from .delta import compare, load_previous_fingerprints, validate_accepted_baseline
from .html import parse_document
from .manifest import sha256_file, write_manifest
from .mapping import prove_mapping
from .models import (
    Baseline,
    Disposition,
    MappingResult,
    RawArtifact,
    StageResult,
    Status,
    canonical_json,
)
from .normalize import normalize
from .probe import USER_AGENTS, ProbeObservation, fetch, write_probe
from .render import write_outputs
from .scanner import SCANNER_PACKAGE, load_scanner_fixture, run_scanner
from .triage import run_triage


def run_baseline(
    *,
    project: str,
    url: str,
    checkout: Path,
    run_dir: Path,
    marker_file: str,
    marker: str,
    html_file: Path | None = None,
    scanner_json: Path | None = None,
    previous_baseline: Path | None = None,
    timeout: float = 30,
    enable_triage: bool = False,
    triage_prompt: Path | None = None,
    triage_provider: str = "ollama",
    triage_model: str = "llama3.2",
    triage_response_file: Path | None = None,
    triage_timeout: float = 120,
) -> Baseline:
    checkout = checkout.resolve()
    run_dir = normalize_output_dir(run_dir, label="run directory")
    fixture_mode = any(
        value is not None for value in (html_file, scanner_json, triage_response_file)
    )
    if previous_baseline is not None:
        validate_accepted_baseline(
            previous_baseline,
            project=project,
            domain=url,
            checkout=checkout.name,
            allow_fixture=fixture_mode,
        )
    _prepare_run_dir(run_dir)
    stages: list[StageResult] = []
    probes, live_html = _collect_probes(url, run_dir, html_file, timeout)
    probe_failed = any(
        not 200 <= item.status < 400
        or item.truncated
        or (
            item.agent == "gptbot"
            and "html" not in item.headers.get("content-type", "").lower()
        )
        for item in probes
    )
    stages.append(
        StageResult(
            "crawler-probes",
            Status.INDETERMINATE if probe_failed else Status.PASS,
            "one or more crawler probes failed or returned incomplete HTML"
            if probe_failed
            else "all crawler probes returned complete HTML responses",
            tuple(f"raw/probe-{item.agent}.json" for item in probes),
        )
    )

    primary_probe = next(item for item in probes if item.agent == "gptbot")
    if primary_probe.truncated:
        mapping = MappingResult(
            Status.INDETERMINATE,
            "mapping cannot use a truncated GPTBot response",
            project=project,
            domain=url,
            checkout=checkout.name,
            marker_file=marker_file,
        )
    else:
        mapping = prove_mapping(
            checkout,
            live_html,
            marker_file,
            marker,
            project=project,
            domain=url,
        )
    atomic_write(run_dir / "raw" / "mapping.json", canonical_json(asdict(mapping)))
    stages.append(
        StageResult("mapping", mapping.status, mapping.reason, ("raw/mapping.json",))
    )

    baseline = Baseline(
        project=project,
        domain=url,
        checkout=checkout.name,
        commit=_commit(checkout),
        generated_at=_now(),
        fixture=fixture_mode,
        mapping=mapping,
        stages=stages,
        tools={"geo-optimizer-skill": SCANNER_PACKAGE},
    )
    if not mapping.proven:
        baseline.overall_status = Status.INDETERMINATE
        _finish(baseline, run_dir)
        return baseline

    scanner_payload: dict[str, Any] = {}
    try:
        if scanner_json is not None:
            scanner_payload = load_scanner_fixture(scanner_json, run_dir)
        else:
            scanner_payload, _ = run_scanner(url, checkout, run_dir, timeout)
        stages.append(
            StageResult(
                "geo-optimizer",
                Status.PASS,
                f"pinned scanner {SCANNER_PACKAGE} completed",
                (
                    "raw/geo-optimizer.stdout",
                    "raw/geo-optimizer.stderr",
                    "raw/geo-optimizer.receipt.json",
                ),
            )
        )
    except Exception as exc:
        stages.append(
            StageResult(
                "geo-optimizer",
                Status.INDETERMINATE,
                _safe_reason(exc),
                tuple(
                    path
                    for path in (
                        "raw/geo-optimizer.stdout",
                        "raw/geo-optimizer.stderr",
                        "raw/geo-optimizer.receipt.json",
                    )
                    if (run_dir / path).exists()
                ),
            )
        )

    document = parse_document(live_html)
    findings, normalization_errors = normalize(
        url=url,
        document=document,
        scanner_payload=scanner_payload,
        probes=probes,
        html_evidence="raw/probe-gptbot.html",
        scanner_evidence="raw/geo-optimizer.stdout",
    )
    stages.append(
        StageResult(
            "normalization",
            Status.INDETERMINATE if normalization_errors else Status.PASS,
            "; ".join(normalization_errors)
            if normalization_errors
            else "deterministic normalization completed",
            ("raw/probe-gptbot.html",),
        )
    )
    if enable_triage:
        if triage_prompt is None:
            raise ValueError("triage prompt is required when triage is enabled")
        try:
            findings = run_triage(
                findings,
                run_dir=run_dir,
                prompt_template=triage_prompt,
                provider=triage_provider,
                model=triage_model,
                response_file=triage_response_file,
                timeout=triage_timeout,
            )
            baseline.tools["triage-provider"] = triage_provider
            baseline.tools["triage-model"] = triage_model
            stages.append(
                StageResult(
                    "model-triage",
                    Status.PASS,
                    "bounded model triage completed",
                    tuple(
                        path
                        for path in (
                            "raw/triage-input.json",
                            "raw/triage.stdout",
                            "raw/triage.stderr",
                            "raw/triage.receipt.json",
                        )
                        if (run_dir / path).exists()
                    ),
                )
            )
        except (OSError, ValueError, RuntimeError) as exc:
            stages.append(
                StageResult(
                    "model-triage",
                    Status.INDETERMINATE,
                    _safe_reason(exc),
                    tuple(
                        path
                        for path in (
                            "raw/triage-input.json",
                            "raw/triage.stdout",
                            "raw/triage.stderr",
                            "raw/triage.receipt.json",
                        )
                        if (run_dir / path).exists()
                    ),
                )
            )
    else:
        stages.append(
            StageResult(
                "model-triage",
                Status.PASS,
                "no-llm-pass: deterministic dispositions retained",
            )
        )
    baseline.findings = findings
    previous = load_previous_fingerprints(previous_baseline)
    baseline.new, baseline.unchanged, baseline.resolved = compare(findings, previous)
    indeterminate = any(stage.status is Status.INDETERMINATE for stage in stages)
    actionable_new = {
        finding.fingerprint
        for finding in findings
        if finding.disposition is Disposition.KEPT and finding.suggested_action
    } & set(baseline.new)
    if indeterminate:
        baseline.overall_status = Status.INDETERMINATE
    elif previous_baseline is not None and actionable_new:
        baseline.overall_status = Status.REGRESSION
    else:
        baseline.overall_status = Status.PASS
    _finish(baseline, run_dir)
    return baseline


def _collect_probes(
    url: str,
    run_dir: Path,
    html_file: Path | None,
    timeout: float,
) -> tuple[list[ProbeObservation], str]:
    observations: list[ProbeObservation] = []
    primary = b""
    if html_file is not None:
        primary = html_file.read_bytes()
        for agent in USER_AGENTS:
            observation = ProbeObservation(
                agent=agent,
                user_agent=USER_AGENTS[agent],
                requested_url=url,
                final_url=url,
                status=200,
                headers={"content-type": "text/html"},
                fetched_at=_now(),
                body_bytes=len(primary),
                truncated=False,
            )
            write_probe(
                run_dir,
                observation,
                primary if agent == "gptbot" else None,
            )
            observations.append(observation)
    else:
        for agent in USER_AGENTS:
            observation, body = fetch(url, agent=agent, timeout=timeout)
            write_probe(
                run_dir,
                observation,
                body if agent == "gptbot" else None,
            )
            observations.append(observation)
            if agent == "gptbot":
                primary = body
    return observations, primary.decode("utf-8", errors="replace")


def _finish(baseline: Baseline, run_dir: Path) -> None:
    baseline.raw_artifacts = [
        RawArtifact(
            path.relative_to(run_dir).as_posix(),
            path.stat().st_size,
            sha256_file(path),
        )
        for path in sorted((run_dir / "raw").rglob("*"))
        if path.is_file() and not path.is_symlink()
    ]
    artifact_paths = {artifact.path for artifact in baseline.raw_artifacts}
    referenced_paths = {finding.raw_evidence for finding in baseline.findings} | {
        path for stage in baseline.stages for path in stage.raw_artifacts
    }
    missing = sorted(referenced_paths - artifact_paths)
    if missing:
        raise ValueError(
            "normalized evidence references missing raw artifacts: "
            + ", ".join(missing)
        )
    write_outputs(baseline, run_dir)
    files = [
        path
        for path in run_dir.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    ]
    write_manifest(
        run_dir,
        files,
        metadata={
            "schema": baseline.schema,
            "project": baseline.project,
            "domain": baseline.domain,
            "commit": baseline.commit,
            "generated_at": baseline.generated_at,
            "scanner": SCANNER_PACKAGE,
        },
    )


def _prepare_run_dir(run_dir: Path) -> None:
    if run_dir.is_symlink():
        raise ValueError("run directory must not be a symlink")
    if run_dir.exists() and any(run_dir.iterdir()):
        raise ValueError("run directory must be new or empty")
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "raw").mkdir()


def _commit(checkout: Path) -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=checkout,
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def _safe_reason(exc: Exception) -> str:
    return str(exc).replace(str(Path.home()), "<HOME>")


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
