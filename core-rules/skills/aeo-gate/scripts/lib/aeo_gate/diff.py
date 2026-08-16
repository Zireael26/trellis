from __future__ import annotations

import subprocess
from dataclasses import asdict
from pathlib import Path

from .baseline import _commit, _finish, _now, _prepare_run_dir, run_baseline
from .capture import atomic_write, normalize_output_dir
from .models import (
    Baseline,
    MappingResult,
    StageResult,
    Status,
    canonical_json,
)

PAGE_SUFFIXES = {
    ".html",
    ".htm",
    ".md",
    ".mdx",
    ".tsx",
    ".jsx",
    ".vue",
    ".astro",
    ".svelte",
}


def changed_pages(checkout: Path, git_range: str) -> list[str]:
    if not git_range or git_range.startswith("-"):
        raise ValueError("git range is required and cannot start with '-'")
    completed = subprocess.run(
        [
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "--diff-filter=ACDMR",
            git_range,
            "--",
        ],
        cwd=checkout,
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
    return sorted(
        path
        for path in completed.stdout.splitlines()
        if Path(path).suffix.casefold() in PAGE_SUFFIXES
    )


def _exclude_accepted_evidence(
    pages: list[str], checkout: Path, previous_baseline: Path
) -> list[str]:
    try:
        evidence_root = previous_baseline.resolve().parent.relative_to(checkout)
    except ValueError:
        return pages
    prefix = evidence_root.as_posix().rstrip("/")
    return [
        page for page in pages if page != prefix and not page.startswith(f"{prefix}/")
    ]


def run_diff(
    *,
    project: str,
    url: str,
    checkout: Path,
    run_dir: Path,
    marker_file: str,
    marker: str,
    previous_baseline: Path,
    git_range: str,
    html_file: Path | None = None,
    scanner_json: Path | None = None,
    timeout: float = 30,
    enable_triage: bool = False,
    triage_prompt: Path | None = None,
    triage_provider: str = "ollama",
    triage_model: str = "llama3.2",
    triage_response_file: Path | None = None,
    triage_timeout: float = 120,
) -> Baseline:
    checkout = checkout.resolve()
    run_dir = normalize_output_dir(run_dir, label="diff run directory")
    pages = _exclude_accepted_evidence(
        changed_pages(checkout, git_range), checkout, previous_baseline
    )
    unresolved = [page for page in pages if page != marker_file]
    if unresolved:
        _prepare_run_dir(run_dir)
        changed_path = run_dir / "raw" / "changed-pages.txt"
        atomic_write(changed_path, "\n".join(pages) + "\n")
        reason = "affected-page URL mapping is unavailable for: " + ", ".join(
            unresolved
        )
        mapping = MappingResult(
            Status.INDETERMINATE,
            reason,
            project=project,
            domain=url,
            checkout=checkout.name,
            marker_file=marker_file,
        )
        atomic_write(
            run_dir / "raw" / "mapping.json",
            canonical_json(asdict(mapping)),
        )
        baseline = Baseline(
            project=project,
            domain=url,
            checkout=checkout.name,
            commit=_commit(checkout),
            generated_at=_now(),
            mapping=mapping,
            stages=[
                StageResult(
                    "changed-pages",
                    Status.INDETERMINATE,
                    reason,
                    ("raw/changed-pages.txt",),
                ),
                StageResult(
                    "mapping",
                    Status.INDETERMINATE,
                    "mapping was not attempted for unreconciled changed pages",
                    ("raw/mapping.json",),
                ),
            ],
            overall_status=Status.INDETERMINATE,
        )
        _finish(baseline, run_dir)
        return baseline
    baseline = run_baseline(
        project=project,
        url=url,
        checkout=checkout,
        run_dir=run_dir,
        marker_file=marker_file,
        marker=marker,
        html_file=html_file,
        scanner_json=scanner_json,
        previous_baseline=previous_baseline,
        timeout=timeout,
        enable_triage=enable_triage,
        triage_prompt=triage_prompt,
        triage_provider=triage_provider,
        triage_model=triage_model,
        triage_response_file=triage_response_file,
        triage_timeout=triage_timeout,
    )
    changed_path = run_dir / "raw" / "changed-pages.txt"
    atomic_write(changed_path, "\n".join(pages) + ("\n" if pages else ""))
    baseline.stages.append(
        StageResult(
            "changed-pages",
            Status.PASS,
            f"{len(pages)} affected page source file(s) reconciled",
            ("raw/changed-pages.txt",),
        )
    )
    _finish(baseline, run_dir)
    return baseline


def warn_only_verdict(baseline: Baseline) -> str:
    return "\n".join(
        (
            "=== AEO GATE (WARN ONLY) ===",
            f"internal_status={baseline.overall_status}",
            f"new={len(baseline.new)} unchanged={len(baseline.unchanged)} resolved={len(baseline.resolved)}",
            "merge_policy=non-blocking",
        )
    )
