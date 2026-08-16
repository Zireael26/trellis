from __future__ import annotations

import json
import shutil
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .capture import CaptureResult, atomic_write, capture_command
from .models import canonical_json

SCANNER_PACKAGE = "geo-optimizer-skill==4.16"
SCANNER_VERSION = "4.16"


def scanner_argv(url: str) -> list[str]:
    return [
        "uvx",
        "--from",
        SCANNER_PACKAGE,
        "geo",
        "audit",
        "--url",
        url,
        "--format",
        "json",
        "--verbose",
        "--no-plugins",
    ]


def run_scanner(
    url: str, checkout: Path, run_dir: Path, timeout: float
) -> tuple[dict[str, Any], CaptureResult]:
    if shutil.which("uvx") is None:
        raise RuntimeError("pinned scanner launcher 'uvx' is unavailable")
    result = capture_command(
        scanner_argv(url),
        cwd=checkout,
        output_dir=run_dir / "raw",
        name="geo-optimizer",
        timeout=timeout,
    )
    atomic_write(
        run_dir / "raw" / "geo-optimizer.receipt.json",
        canonical_json({"source": "command", **asdict(result)}),
    )
    if result.exit_code != 0:
        raise RuntimeError(f"pinned scanner exited with status {result.exit_code}")
    payload = _load_json_bytes((run_dir / result.stdout_path).read_bytes())
    return payload, result


def load_scanner_fixture(path: Path, run_dir: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    destination = run_dir / "raw" / "geo-optimizer.stdout"
    atomic_write(destination, raw)
    atomic_write(run_dir / "raw" / "geo-optimizer.stderr", b"")
    atomic_write(
        run_dir / "raw" / "geo-optimizer.receipt.json",
        canonical_json(
            {
                "source": "fixture",
                "fixture": path.name,
                "scanner_package": SCANNER_PACKAGE,
                "exit_code": 0,
            }
        ),
    )
    return _load_json_bytes(raw)


def _load_json_bytes(raw: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"scanner output is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("scanner output root must be an object")
    reported_error = payload.get("error")
    if reported_error not in (None, ""):
        raise ValueError("scanner reported an internal error")
    findings = payload.get("findings")
    checks = payload.get("checks")
    if not isinstance(findings, list) and not isinstance(checks, dict):
        raise ValueError("scanner output requires a findings list or checks object")
    if isinstance(findings, list) and not all(
        isinstance(finding, dict) for finding in findings
    ):
        raise ValueError("scanner findings must be objects")
    if isinstance(checks, dict) and not all(
        isinstance(result, dict) and isinstance(result.get("passed"), bool)
        for result in checks.values()
    ):
        raise ValueError("scanner checks must contain boolean passed results")
    return payload
