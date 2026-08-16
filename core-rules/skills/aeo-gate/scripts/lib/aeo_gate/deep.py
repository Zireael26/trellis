from __future__ import annotations

import json
import shutil
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .capture import (
    atomic_write,
    capture_command,
    local_ollama_env,
    normalize_output_dir,
    validate_local_ollama_model,
)
from .delta import validate_accepted_baseline
from .html import parse_document
from .manifest import sha256_file, write_manifest
from .models import SCHEMA, assert_no_composite_score, canonical_json

MAX_CONTENT_CHARS = 12000
MAX_CONTEXT_BYTES = 64 * 1024
_ALLOWED_ASPECTS = {
    "answer-first",
    "statistics",
    "quotations",
    "external-authority-citations",
}


def run_deep(
    *,
    html_path: Path,
    baseline_path: Path,
    run_dir: Path,
    prompt_template: Path,
    provider: str,
    model: str,
    confirm_remote: bool,
    response_file: Path | None = None,
    timeout: float = 120,
) -> dict[str, Any]:
    run_dir = normalize_output_dir(run_dir, label="deep review run directory")
    fixture_mode = response_file is not None
    remote = provider != "ollama" and not (
        fixture_mode and provider in {"local", "none"}
    )
    if remote and not confirm_remote:
        raise ValueError("remote metered deep review requires --confirm-remote")
    if remote and not model.casefold().startswith(provider.casefold() + "/"):
        raise ValueError("remote model must be qualified as provider/model")
    if remote:
        if not sys.stdin.isatty():
            raise ValueError("remote deep review requires an interactive terminal")
        expected = f"{provider}:{model}"
        confirmation = input(
            f"Type {expected!r} to authorize this remote metered review: "
        )
        if confirmation != expected:
            raise ValueError("remote deep review confirmation did not match")
    if run_dir.is_symlink():
        raise ValueError("deep review run directory must not be a symlink")
    if run_dir.exists() and any(run_dir.iterdir()):
        raise ValueError("deep review run directory must be new or empty")
    context, baseline_sha256 = _load_baseline_context(
        baseline_path, allow_fixture=fixture_mode
    )
    document = parse_document(html_path.read_text(encoding="utf-8"))
    content = document.visible_text[:MAX_CONTENT_CHARS]
    prompt = (
        prompt_template.read_text(encoding="utf-8")
        + "\n\nDETERMINISTIC CONTEXT:\n"
        + context
        + "\nPAGE CONTENT:\n"
        + content
    )
    run_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = run_dir / "raw"
    atomic_write(raw_dir / "deep-input.txt", prompt)
    if response_file is not None:
        raw = response_file.read_bytes()
        atomic_write(raw_dir / "deep.stdout", raw)
        atomic_write(raw_dir / "deep.stderr", b"")
        atomic_write(
            raw_dir / "deep.receipt.json",
            canonical_json(
                {
                    "source": "fixture",
                    "fixture": response_file.name,
                    "provider": provider,
                    "model": model,
                    "baseline_sha256": baseline_sha256,
                    "exit_code": 0,
                }
            ),
        )
    else:
        if remote:
            executable = "llm"
            command = ["llm", "-m", model]
            unavailable = "provider-neutral 'llm' command is unavailable"
            command_env: dict[str, str] | None = None
        else:
            executable = "ollama"
            command = ["ollama", "run", model]
            unavailable = "local 'ollama' command is unavailable"
            validate_local_ollama_model(model)
            command_env = local_ollama_env()
        if (
            shutil.which(
                executable,
                path=None if command_env is None else command_env.get("PATH"),
            )
            is None
        ):
            _write_failure(run_dir, provider, model, unavailable)
            raise RuntimeError(unavailable)
        result = capture_command(
            command,
            cwd=html_path.parent,
            output_dir=raw_dir,
            name="deep",
            timeout=timeout,
            stdin=prompt.encode("utf-8"),
            env=command_env,
        )
        atomic_write(
            raw_dir / "deep.receipt.json",
            canonical_json(
                {
                    "source": "command",
                    "provider": provider,
                    "model": model,
                    "baseline_sha256": baseline_sha256,
                    **asdict(result),
                }
            ),
        )
        if result.exit_code != 0:
            _write_failure(
                run_dir,
                provider,
                model,
                f"deep review command exited with status {result.exit_code}",
            )
            raise RuntimeError(f"deep review exited with status {result.exit_code}")
        raw = (run_dir / result.stdout_path).read_bytes()
    try:
        response = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _write_failure(run_dir, provider, model, "deep review output is not valid JSON")
        raise ValueError(f"deep review output is not valid JSON: {exc}") from exc
    try:
        _validate_response(response)
    except ValueError:
        _write_failure(run_dir, provider, model, "deep review output failed validation")
        raise
    output = {
        "schema": "aeo-gate.deep.v1",
        "source": "MODEL_DERIVED",
        "provider": provider,
        "model": model,
        "content_chars": len(content),
        "findings": response["findings"],
    }
    output_path = run_dir / "deep.json"
    atomic_write(output_path, canonical_json(output))
    _write_deep_manifest(
        run_dir,
        {"schema": output["schema"], "provider": provider, "model": model},
    )
    return output


def _load_baseline_context(path: Path, *, allow_fixture: bool) -> tuple[str, str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError("deep review baseline is unreadable") from exc
    if not isinstance(payload, dict) or payload.get("schema") != SCHEMA:
        raise ValueError("deep review requires an aeo-gate.baseline.v1 context")
    validate_accepted_baseline(
        path,
        project=str(payload.get("project", "")),
        domain=str(payload.get("domain", "")),
        checkout=str(payload.get("checkout", "")),
        allow_fixture=allow_fixture,
    )
    selected = {
        key: payload.get(key)
        for key in (
            "project",
            "domain",
            "commit",
            "mapping",
            "stages",
            "findings",
            "overall_status",
        )
    }
    context = canonical_json(selected)
    if len(context.encode("utf-8")) > MAX_CONTEXT_BYTES:
        raise ValueError("deep review deterministic context exceeds 65536 bytes")
    return context, sha256_file(path)


def _write_failure(run_dir: Path, provider: str, model: str, reason: str) -> None:
    atomic_write(
        run_dir / "deep-error.json",
        canonical_json(
            {
                "schema": "aeo-gate.deep-error.v1",
                "provider": provider,
                "model": model,
                "error": reason,
            }
        ),
    )
    _write_deep_manifest(
        run_dir,
        {"schema": "aeo-gate.deep-error.v1", "provider": provider, "model": model},
    )


def _write_deep_manifest(run_dir: Path, metadata: dict[str, str]) -> None:
    write_manifest(
        run_dir,
        [
            path
            for path in run_dir.rglob("*")
            if path.is_file() and path.name != "manifest.json"
        ],
        metadata=metadata,
    )


def _validate_response(response: Any) -> None:
    if not isinstance(response, dict) or not isinstance(response.get("findings"), list):
        raise ValueError("deep review output requires a findings list")
    assert_no_composite_score(response)
    forbidden = {"evidence_grade", "fingerprint", "raw_evidence", "deterministic_grade"}
    for finding in response["findings"]:
        if not isinstance(finding, dict):
            raise ValueError("deep review findings must be objects")
        if forbidden & set(finding):
            raise ValueError(
                "deep review cannot overwrite deterministic evidence fields"
            )
        if finding.get("aspect") not in _ALLOWED_ASPECTS:
            raise ValueError(
                f"unsupported deep review aspect: {finding.get('aspect')!r}"
            )
        if not isinstance(finding.get("rationale"), str):
            raise ValueError("deep review finding rationale is required")
