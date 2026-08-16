from __future__ import annotations

import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .baseline import _finish, run_baseline
from .capture import atomic_write, normalize_output_dir
from .delta import validate_accepted_baseline
from .manifest import verify_manifest, write_manifest
from .mapping import Target, parse_targets, reconcile_targets
from .models import StageResult, Status, canonical_json


def run_fleet(
    *,
    targets_path: Path,
    registry_path: Path,
    blacklist_path: Path,
    output_dir: Path,
    timeout: float,
    previous_root: Path | None = None,
    html_fixture_dir: Path | None = None,
    scanner_fixture_dir: Path | None = None,
) -> dict[str, Any]:
    output_dir = normalize_output_dir(output_dir, label="fleet output directory")
    active, skipped = parse_targets(targets_path)
    reconcile_targets(
        registry_path=registry_path,
        blacklist_path=blacklist_path,
        active=active,
        skipped=skipped,
    )
    if output_dir.is_symlink():
        raise ValueError("fleet output directory must not be a symlink")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ValueError("fleet output directory must be new or empty")
    output_dir.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []

    for target in active:
        target_dir = output_dir / target.project
        previous_baseline, comparison = _previous(
            previous_root,
            target,
            allow_fixture=(
                html_fixture_dir is not None or scanner_fixture_dir is not None
            ),
        )
        try:
            baseline = run_baseline(
                project=target.project,
                url=target.url,
                checkout=Path(target.checkout).expanduser(),
                run_dir=target_dir,
                marker_file=target.marker_file,
                marker=target.marker,
                timeout=timeout,
                html_file=_fixture(html_fixture_dir, target, ".html"),
                scanner_json=_fixture(scanner_fixture_dir, target, ".json"),
                previous_baseline=previous_baseline,
            )
            if comparison not in {"none-requested"} and not comparison.startswith(
                "accepted:"
            ):
                baseline.stages.append(
                    StageResult(
                        "previous-baseline",
                        Status.INDETERMINATE,
                        comparison,
                    )
                )
                baseline.overall_status = Status.INDETERMINATE
                _finish(baseline, target_dir)
            manifest_errors = verify_manifest(target_dir / "manifest.json")
            if manifest_errors:
                raise RuntimeError(
                    "target manifest invalid after capture: "
                    + "; ".join(manifest_errors)
                )
            results.append(
                {
                    "project": target.project,
                    "url": target.url,
                    "status": baseline.overall_status.value,
                    "baseline": f"{target.project}/baseline.json",
                    "manifest": f"{target.project}/manifest.json",
                    "comparison": comparison,
                    "error": "",
                }
            )
        except (OSError, ValueError, RuntimeError) as exc:
            error = _safe_error(exc)
            target_dir.mkdir(parents=True, exist_ok=True)
            error_path = target_dir / "error.json"
            atomic_write(
                error_path,
                canonical_json(
                    {
                        "project": target.project,
                        "url": target.url,
                        "status": Status.INDETERMINATE.value,
                        "error": error,
                    }
                ).encode("utf-8"),
            )
            write_manifest(
                target_dir,
                [
                    path
                    for path in target_dir.rglob("*")
                    if path.is_file() and path.name != "manifest.json"
                ],
                metadata={"project": target.project, "kind": "error"},
            )
            manifest_errors = verify_manifest(target_dir / "manifest.json")
            if manifest_errors:
                error += "; target manifest invalid: " + "; ".join(manifest_errors)
                atomic_write(
                    error_path,
                    canonical_json(
                        {
                            "project": target.project,
                            "url": target.url,
                            "status": Status.INDETERMINATE.value,
                            "error": error,
                        }
                    ).encode("utf-8"),
                )
                write_manifest(
                    target_dir,
                    [
                        path
                        for path in target_dir.rglob("*")
                        if path.is_file() and path.name != "manifest.json"
                    ],
                    metadata={"project": target.project, "kind": "error"},
                )
            results.append(
                {
                    "project": target.project,
                    "url": target.url,
                    "status": Status.INDETERMINATE.value,
                    "baseline": "",
                    "manifest": f"{target.project}/manifest.json",
                    "error": error,
                    "comparison": comparison,
                }
            )

    status = _fleet_status(results)
    rollup = {
        "schema": "aeo-gate.fleet-rollup.v1",
        "generated_at": _now(),
        "status": status.value,
        "targets": results,
        "skips": [
            {"project": project, "reason": reason}
            for project, reason in sorted(skipped.items())
        ],
        "counts": {
            "active": len(results),
            "skipped": len(skipped),
            "pass": sum(item["status"] == Status.PASS.value for item in results),
            "regression": sum(
                item["status"] == Status.REGRESSION.value for item in results
            ),
            "indeterminate": sum(
                item["status"] == Status.INDETERMINATE.value for item in results
            ),
        },
    }
    rollup_path = output_dir / "fleet-rollup.json"
    atomic_write(rollup_path, canonical_json(rollup).encode("utf-8"))
    fleet_manifest = output_dir / "manifest.json"
    artifacts = [
        path
        for path in output_dir.rglob("*")
        if path.is_file() and path != fleet_manifest
    ]
    write_manifest(
        output_dir,
        artifacts,
        metadata={
            "kind": "fleet",
            "target_count": len(results),
            "skip_count": len(skipped),
        },
    )
    return rollup


def _fixture(root: Path | None, target: Target, suffix: str) -> Path | None:
    if root is None:
        return None
    path = root / f"{target.project}{suffix}"
    if not path.is_file():
        raise ValueError(f"missing fixture for {target.project}")
    return path


def _previous(
    root: Path | None, target: Target, *, allow_fixture: bool
) -> tuple[Path | None, str]:
    if root is None:
        return None, "none-requested"
    rejected: list[str] = []
    for candidate_root in _previous_roots(root):
        path = candidate_root / target.project / "baseline.json"
        if not path.is_file():
            rejected.append(f"{candidate_root.name}:missing")
            continue
        try:
            validate_accepted_baseline(
                path,
                project=target.project,
                domain=target.url,
                checkout=Path(target.checkout).expanduser().resolve().name,
                allow_fixture=allow_fixture,
            )
        except ValueError as exc:
            rejected.append(f"{candidate_root.name}:rejected-{_safe_error(exc)}")
            continue
        return path, f"accepted:{candidate_root.name}"
    return None, "previous-baseline-unresolved:" + ",".join(rejected)


def _previous_roots(root: Path) -> list[Path]:
    date_pattern = re.compile(r"\d{4}-\d{2}-\d{2}\Z")
    if not date_pattern.fullmatch(root.name):
        return [root]
    return sorted(
        (
            candidate
            for candidate in root.parent.iterdir()
            if candidate.is_dir()
            and date_pattern.fullmatch(candidate.name)
            and candidate.name <= root.name
        ),
        key=lambda candidate: candidate.name,
        reverse=True,
    )


def _fleet_status(results: list[dict[str, Any]]) -> Status:
    statuses = {item["status"] for item in results}
    if Status.INDETERMINATE.value in statuses:
        return Status.INDETERMINATE
    if Status.REGRESSION.value in statuses:
        return Status.REGRESSION
    return Status.PASS


def _safe_error(exc: Exception) -> str:
    return str(exc).replace(str(Path.home()), "<HOME>")


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
