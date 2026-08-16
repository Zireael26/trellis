from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .baseline import run_baseline
from .deep import run_deep
from .diff import run_diff, warn_only_verdict
from .fleet import run_fleet
from .manifest import verify_manifest
from .models import Status

DEFAULT_TRIAGE_PROMPT = Path(__file__).resolve().parents[3] / "prompts" / "triage.md"


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="aeo-gate")
    commands = root.add_subparsers(dest="command", required=True)
    baseline = commands.add_parser("baseline")
    _common_scan_arguments(baseline)
    baseline.add_argument("--baseline", type=Path)

    diff = commands.add_parser("diff")
    _common_scan_arguments(diff)
    diff.add_argument("--baseline", type=Path, required=True)
    diff.add_argument("--range", default="origin/main..HEAD")

    deep = commands.add_parser("deep")
    deep.add_argument("--html", type=Path, required=True)
    deep.add_argument("--baseline", type=Path, required=True)
    deep.add_argument("--output", type=Path, required=True)
    deep.add_argument("--prompt", type=Path, required=True)
    deep.add_argument("--provider", default="ollama")
    deep.add_argument("--model", default="llama3.2")
    deep.add_argument("--confirm-remote", action="store_true")
    deep.add_argument("--response-file", type=Path)
    deep.add_argument("--timeout", type=float, default=120)
    fleet = commands.add_parser("fleet")
    fleet.add_argument("--targets", type=Path, required=True)
    fleet.add_argument("--registry", type=Path, required=True)
    fleet.add_argument("--blacklist", type=Path, required=True)
    fleet.add_argument("--output", type=Path, required=True)
    fleet.add_argument("--previous-root", type=Path)
    fleet.add_argument("--timeout", type=float, default=30)
    fleet.add_argument("--html-fixture-dir", type=Path)
    fleet.add_argument("--scanner-fixture-dir", type=Path)

    verify = commands.add_parser("verify-manifest")
    verify.add_argument("manifest", type=Path)
    return root


def _common_scan_arguments(command: argparse.ArgumentParser) -> None:
    command.add_argument("--project", required=True)
    command.add_argument("--url", required=True)
    command.add_argument("--checkout", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--marker-file", required=True)
    command.add_argument("--marker", required=True)
    command.add_argument("--html-file", type=Path)
    command.add_argument("--scanner-json", type=Path)
    command.add_argument("--timeout", type=float, default=30)
    command.add_argument("--triage", action="store_true")
    command.add_argument("--triage-prompt", type=Path, default=DEFAULT_TRIAGE_PROMPT)
    command.add_argument("--triage-provider", default="ollama")
    command.add_argument("--triage-model", default="llama3.2")
    command.add_argument("--triage-response-file", type=Path)
    command.add_argument("--triage-timeout", type=float, default=120)


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    fixture_inputs = (
        getattr(args, "html_file", None),
        getattr(args, "scanner_json", None),
        getattr(args, "triage_response_file", None),
        getattr(args, "response_file", None),
        getattr(args, "html_fixture_dir", None),
        getattr(args, "scanner_fixture_dir", None),
    )
    if (
        any(value is not None for value in fixture_inputs)
        and os.environ.get("AEO_GATE_ALLOW_FIXTURES") != "1"
    ):
        parser().error(
            "fixture inputs are test-only and require AEO_GATE_ALLOW_FIXTURES=1"
        )
    if (
        args.command in {"baseline", "diff"}
        and args.triage_response_file
        and not args.triage
    ):
        parser().error("--triage-response-file requires --triage")
    try:
        if args.command == "verify-manifest":
            errors = verify_manifest(args.manifest)
            if errors:
                print("\n".join(errors), file=sys.stderr)
                return 2
            print("manifest valid")
            return 0
        if args.command == "deep":
            output = run_deep(
                html_path=args.html,
                baseline_path=args.baseline,
                run_dir=args.output,
                prompt_template=args.prompt,
                provider=args.provider,
                model=args.model,
                confirm_remote=args.confirm_remote,
                response_file=args.response_file,
                timeout=args.timeout,
            )
            print(
                json.dumps(
                    {"schema": output["schema"], "findings": len(output["findings"])}
                )
            )
            return 0
        if args.command == "fleet":
            output = run_fleet(
                targets_path=args.targets,
                registry_path=args.registry,
                blacklist_path=args.blacklist,
                output_dir=args.output,
                previous_root=args.previous_root,
                timeout=args.timeout,
                html_fixture_dir=args.html_fixture_dir,
                scanner_fixture_dir=args.scanner_fixture_dir,
            )
            print(json.dumps({"status": output["status"], "output": str(args.output)}))
            return 0 if output["status"] == Status.PASS.value else 2
        common = {
            "project": args.project,
            "url": args.url,
            "checkout": args.checkout,
            "run_dir": args.output,
            "marker_file": args.marker_file,
            "marker": args.marker,
            "html_file": args.html_file,
            "scanner_json": args.scanner_json,
            "timeout": args.timeout,
            "enable_triage": args.triage,
            "triage_prompt": args.triage_prompt,
            "triage_provider": args.triage_provider,
            "triage_model": args.triage_model,
            "triage_response_file": args.triage_response_file,
            "triage_timeout": args.triage_timeout,
        }
        if args.command == "baseline":
            result = run_baseline(**common, previous_baseline=args.baseline)
            print(
                json.dumps(
                    {
                        "status": result.overall_status,
                        "output": str(args.output / "baseline.json"),
                    }
                )
            )
            return 0 if result.overall_status is Status.PASS else 2
        result = run_diff(
            **common,
            previous_baseline=args.baseline,
            git_range=args.range,
        )
        print(warn_only_verdict(result))
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"aeo-gate: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
