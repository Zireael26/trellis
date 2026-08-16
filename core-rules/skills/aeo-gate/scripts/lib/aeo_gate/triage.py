from __future__ import annotations

import json
import shutil
from dataclasses import asdict, replace
from pathlib import Path
from typing import Any, Iterable

from .capture import (
    atomic_write,
    capture_command,
    local_ollama_env,
    validate_local_ollama_model,
)
from .models import Disposition, EvidenceGrade, Finding, canonical_json

MAX_TRIAGE_INPUT_BYTES = 64 * 1024
_ALLOWED_KEYS = {"fingerprint", "disposition", "rationale", "suggested_action"}
_ALLOWED_DISPOSITIONS = {
    Disposition.KEPT,
    Disposition.DROPPED,
    Disposition.AMBIGUOUS,
}


def run_triage(
    findings: Iterable[Finding],
    *,
    run_dir: Path,
    prompt_template: Path,
    provider: str,
    model: str,
    response_file: Path | None = None,
    timeout: float = 120,
) -> list[Finding]:
    original = list(findings)
    candidates = [
        finding
        for finding in original
        if finding.disposition is Disposition.NO_LLM_PASS
    ]
    if not candidates:
        return original
    if response_file is None and provider != "ollama":
        raise ValueError("live baseline/diff triage requires provider 'ollama'")
    if response_file is not None and provider not in {"local", "ollama", "none"}:
        raise ValueError("triage fixtures must identify a non-remote provider")

    payload = {
        "schema": "aeo-gate.triage-input.v1",
        "findings": [finding.as_dict() for finding in candidates],
    }
    serialized = canonical_json(payload)
    if len(serialized.encode("utf-8")) > MAX_TRIAGE_INPUT_BYTES:
        raise ValueError("triage input exceeds the 65536-byte bound")
    prompt = prompt_template.read_text(encoding="utf-8") + "\n\nINPUT:\n" + serialized
    raw_dir = run_dir / "raw"
    atomic_write(raw_dir / "triage-input.json", serialized)

    if response_file is not None:
        raw = response_file.read_bytes()
        atomic_write(raw_dir / "triage.stdout", raw)
        atomic_write(raw_dir / "triage.stderr", b"")
        atomic_write(
            raw_dir / "triage.receipt.json",
            canonical_json(
                {
                    "source": "fixture",
                    "fixture": response_file.name,
                    "provider": provider,
                    "model": model,
                    "exit_code": 0,
                }
            ),
        )
    else:
        validate_local_ollama_model(model)
        ollama_env = local_ollama_env()
        if shutil.which("ollama", path=ollama_env.get("PATH")) is None:
            raise RuntimeError("local 'ollama' command is unavailable")
        result = capture_command(
            ["ollama", "run", model],
            cwd=run_dir,
            output_dir=raw_dir,
            name="triage",
            timeout=timeout,
            stdin=prompt.encode("utf-8"),
            env=ollama_env,
        )
        atomic_write(
            raw_dir / "triage.receipt.json",
            canonical_json(
                {
                    "source": "command",
                    "provider": provider,
                    "model": model,
                    **asdict(result),
                }
            ),
        )
        if result.exit_code != 0:
            raise RuntimeError(f"triage exited with status {result.exit_code}")
        raw = (run_dir / result.stdout_path).read_bytes()

    try:
        response = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"triage output is not valid JSON: {exc}") from exc
    replacements = _validate_response(response, candidates)
    return [replacements.get(finding.fingerprint, finding) for finding in original]


def _validate_response(response: Any, candidates: list[Finding]) -> dict[str, Finding]:
    if not isinstance(response, dict) or not isinstance(response.get("findings"), list):
        raise ValueError("triage output requires a findings list")
    by_fingerprint = {finding.fingerprint: finding for finding in candidates}
    replacements: dict[str, Finding] = {}
    for item in response["findings"]:
        if not isinstance(item, dict) or set(item) - _ALLOWED_KEYS:
            raise ValueError("triage findings contain unsupported fields")
        fingerprint = item.get("fingerprint")
        if not isinstance(fingerprint, str) or fingerprint not in by_fingerprint:
            raise ValueError("triage finding has an unknown fingerprint")
        if fingerprint in replacements:
            raise ValueError("triage finding fingerprints must be unique")
        raw_disposition = item.get("disposition")
        if not isinstance(raw_disposition, str):
            raise ValueError("triage disposition is invalid")
        try:
            disposition = Disposition(raw_disposition)
        except ValueError as exc:
            raise ValueError("triage disposition is invalid") from exc
        if disposition not in _ALLOWED_DISPOSITIONS:
            raise ValueError("triage disposition is unsupported")
        rationale = item.get("rationale")
        if not isinstance(rationale, str) or not rationale.strip():
            raise ValueError("triage rationale is required")
        suggested_action = item.get("suggested_action", "")
        if not isinstance(suggested_action, str):
            raise ValueError("triage suggested_action must be text")
        candidate = by_fingerprint[fingerprint]
        if candidate.evidence_grade is EvidenceGrade.SPECULATIVE and suggested_action:
            raise ValueError("speculative triage cannot suggest remediation")
        replacements[fingerprint] = replace(
            candidate,
            disposition=disposition,
            rationale=rationale,
            suggested_action=suggested_action,
        )
    if set(replacements) != set(by_fingerprint):
        raise ValueError("triage output must account for every candidate finding")
    return replacements
