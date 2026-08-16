from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Iterable

from .capture import atomic_write
from .models import canonical_json

MANIFEST_SCHEMA = "aeo-gate.evidence-manifest.v1"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(
    run_dir: Path,
    files: Iterable[Path],
    *,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    resolved_root = run_dir.resolve()
    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    for candidate in files:
        path = candidate if candidate.is_absolute() else run_dir / candidate
        resolved = path.resolve(strict=True)
        try:
            relative = resolved.relative_to(resolved_root).as_posix()
        except ValueError as exc:
            raise ValueError(f"artifact escapes run directory: {candidate}") from exc
        if path.is_symlink() or not resolved.is_file():
            raise ValueError(
                f"artifact must be a regular non-symlink file: {candidate}"
            )
        if relative in seen:
            raise ValueError(f"duplicate artifact path: {relative}")
        seen.add(relative)
        entries.append(
            {
                "path": relative,
                "bytes": resolved.stat().st_size,
                "sha256": sha256_file(resolved),
            }
        )
    return {
        "schema": MANIFEST_SCHEMA,
        "metadata": metadata or {},
        "artifacts": sorted(entries, key=lambda item: item["path"]),
    }


def write_manifest(
    run_dir: Path, files: Iterable[Path], *, metadata: dict[str, Any]
) -> Path:
    manifest = build_manifest(run_dir, files, metadata=metadata)
    path = run_dir / "manifest.json"
    atomic_write(path, canonical_json(manifest))
    return path


def verify_manifest(path: Path) -> list[str]:
    errors: list[str] = []
    if path.is_symlink():
        return ["manifest must be a regular non-symlink file"]
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"manifest unreadable ({type(exc).__name__})"]
    if not isinstance(payload, dict):
        return ["manifest root must be an object"]
    if payload.get("schema") != MANIFEST_SCHEMA:
        errors.append(f"unexpected manifest schema: {payload.get('schema')!r}")
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        errors.append("manifest artifacts must be a list")
        return errors
    root = path.parent.resolve()
    declared: set[str] = set()
    for entry in artifacts:
        if not isinstance(entry, dict):
            errors.append("manifest artifact entry must be an object")
            continue
        relative = entry.get("path")
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
        ):
            errors.append(f"invalid artifact path: {relative!r}")
            continue
        if relative in declared:
            errors.append(f"duplicate artifact path: {relative}")
            continue
        declared.add(relative)
        candidate = path.parent / relative
        if candidate.is_symlink():
            errors.append(f"artifact is not a regular file: {relative}")
            continue
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(root)
        except (FileNotFoundError, ValueError):
            errors.append(f"missing or escaping artifact: {relative}")
            continue
        if not resolved.is_file():
            errors.append(f"artifact is not a regular file: {relative}")
            continue
        actual_size = resolved.stat().st_size
        actual_hash = sha256_file(resolved)
        if actual_size != entry.get("bytes"):
            errors.append(f"byte count mismatch: {relative}")
        if actual_hash != entry.get("sha256"):
            errors.append(f"checksum mismatch: {relative}")
    actual = {
        candidate.relative_to(path.parent).as_posix()
        for candidate in path.parent.rglob("*")
        if candidate.is_file() and candidate != path
    }
    for relative in sorted(actual - declared):
        errors.append(f"unmanifested artifact: {relative}")
    return errors
