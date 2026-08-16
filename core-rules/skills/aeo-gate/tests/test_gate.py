from __future__ import annotations
# ruff: noqa: E402

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
SKILL_DIR = TEST_DIR.parent
REPO_ROOT = SKILL_DIR.parents[2]
LIB = SKILL_DIR / "scripts" / "lib"
sys.path.insert(0, str(LIB))

from aeo_gate.baseline import run_baseline
from aeo_gate.capture import (
    atomic_write,
    capture_command,
    local_ollama_env,
    normalize_output_dir,
    validate_local_ollama_model,
)
from aeo_gate.deep import run_deep
from aeo_gate.delta import validate_accepted_baseline
from aeo_gate.diff import run_diff, warn_only_verdict
from aeo_gate.fleet import run_fleet
from aeo_gate.html import parse_document
from aeo_gate.jsonld import (
    ABSENT,
    POPULATED,
    VACUOUS,
    classify_key,
    parse_jsonld_blocks,
)
from aeo_gate.manifest import verify_manifest, write_manifest
from aeo_gate.mapping import parse_targets, prove_mapping, reconcile_targets
from aeo_gate.models import (
    Disposition,
    EvidenceGrade,
    Finding,
    Impact,
    Status,
    assert_no_composite_score,
)
from aeo_gate.probe import (
    USER_AGENTS,
    ProbeObservation,
    _validate_public_url,
    fetch,
    write_probe,
)
from aeo_gate.scanner import scanner_argv

FIXTURES = TEST_DIR / "fixtures"
MARKER = "AEO_MAPPING_MARKER_2026_08"


class JsonLdAndHtmlTests(unittest.TestCase):
    def test_full_graph_finds_nested_publisher_same_as(self):
        document = parse_document((FIXTURES / "valid.html").read_text())
        documents, errors = parse_jsonld_blocks(document.jsonld_blocks)
        self.assertEqual(errors, [])
        self.assertEqual(classify_key(documents, "sameAs")[0], POPULATED)

    def test_schema_states_are_distinct(self):
        vacuous_document = parse_document((FIXTURES / "vacuous.html").read_text())
        documents, errors = parse_jsonld_blocks(vacuous_document.jsonld_blocks)
        self.assertEqual(errors, [])
        self.assertEqual(classify_key(documents, "sameAs")[0], VACUOUS)
        self.assertEqual(classify_key(documents, "citation")[0], ABSENT)

    def test_decorative_images_are_not_ambiguous(self):
        document = parse_document((FIXTURES / "valid.html").read_text())
        decorative, unknown = document.images
        self.assertTrue(decorative.decorative)
        self.assertFalse(decorative.ambiguous)
        self.assertTrue(unknown.ambiguous)

    def test_all_decorative_image_signals_exclude_alt_remediation(self):
        document = parse_document(
            "<main>"
            '<img src="role.svg" role="presentation">'
            '<img src="hidden.svg" aria-hidden="true">'
            '<img src="empty.svg" alt="">'
            "</main>"
        )
        self.assertTrue(all(image.decorative for image in document.images))
        self.assertFalse(any(image.ambiguous for image in document.images))


class ContractTests(unittest.TestCase):
    def test_finding_rejects_invalid_enum_values(self):
        with self.assertRaisesRegex(ValueError, "evidence_grade"):
            Finding(
                detector="fixture",
                rule="rule",
                subject="subject",
                state="observed",
                severity="info",
                evidence_grade="STRONG",
                seo_impact=Impact.UNKNOWN,
                aeo_impact=Impact.UNKNOWN,
                disposition=Disposition.KEPT,
                rationale="measured",
                raw_evidence="raw/evidence.json",
                url="https://example.test",
            )

    def test_fingerprint_excludes_rationale_wording(self):
        common = {
            "detector": "fixture",
            "rule": "stable-rule",
            "subject": "semantic subject",
            "state": "observed",
            "severity": "info",
            "evidence_grade": EvidenceGrade.MODERATE,
            "seo_impact": Impact.UNKNOWN,
            "aeo_impact": Impact.UNKNOWN,
            "disposition": Disposition.KEPT,
            "raw_evidence": "raw/evidence.json",
            "url": "https://example.test/",
        }
        first = Finding(rationale="Old scanner wording", **common)
        second = Finding(rationale="New scanner wording", **common)
        self.assertEqual(first.fingerprint, second.fingerprint)

    def test_fingerprint_preserves_case_sensitive_locator_paths(self):
        common = {
            "detector": "fixture",
            "rule": "case-sensitive-url",
            "subject": "same semantic subject",
            "state": "observed",
            "severity": "info",
            "evidence_grade": EvidenceGrade.MODERATE,
            "seo_impact": Impact.UNKNOWN,
            "aeo_impact": Impact.UNKNOWN,
            "disposition": Disposition.KEPT,
            "rationale": "same rationale",
            "raw_evidence": "raw/evidence.json",
        }
        upper = Finding(url="https://EXAMPLE.test/FAQ?Key=Value", **common)
        lower = Finding(url="https://example.test/faq?Key=Value", **common)
        self.assertNotEqual(upper.fingerprint, lower.fingerprint)


class CaptureTests(unittest.TestCase):
    def test_timeout_retains_partial_output_and_attribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = capture_command(
                [
                    sys.executable,
                    "-c",
                    "import sys,time;sys.stdout.write('partial');sys.stdout.flush();time.sleep(1)",
                ],
                cwd=root,
                output_dir=root / "raw",
                name="timeout",
                timeout=0.2,
            )
            self.assertEqual(result.exit_code, 124)
            self.assertTrue(result.timed_out)
            self.assertEqual((root / result.stdout_path).read_text(), "partial")

    def test_capture_preserves_nonzero_output_and_redacts_secrets_and_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            secret = "fixture-api-secret"
            script = (
                "import sys;"
                f"sys.stdout.write({str(Path.home())!r} + ' ' + {secret!r});"
                "sys.stderr.write('failed');"
                "raise SystemExit(7)"
            )
            result = capture_command(
                [sys.executable, "-c", script],
                cwd=root,
                output_dir=root / "raw",
                name="failure",
                timeout=5,
                env={"AEO_API_TOKEN": secret},
            )
            self.assertEqual(result.exit_code, 7)
            self.assertEqual(
                (root / result.stdout_path).read_text(),
                "<HOME> <REDACTED>",
            )
            self.assertEqual((root / result.stderr_path).read_text(), "failed")
            self.assertNotIn(secret, " ".join(result.argv))
            self.assertNotIn(str(Path.home()), " ".join(result.argv))

    def test_capture_redacts_secrets_from_inherited_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            secret = "inherited-api-secret"
            with patch.dict(os.environ, {"INHERITED_API_TOKEN": secret}):
                result = capture_command(
                    [
                        sys.executable,
                        "-c",
                        "import os;print(os.environ['INHERITED_API_TOKEN'])",
                    ],
                    cwd=root,
                    output_dir=root / "raw",
                    name="inherited",
                    timeout=5,
                )
            self.assertEqual((root / result.stdout_path).read_text(), "<REDACTED>\n")

    def test_local_ollama_environment_is_loopback_only_and_cloud_models_fail(self):
        with patch.dict(
            os.environ,
            {
                "OLLAMA_HOST": "https://remote.example",
                "HTTPS_PROXY": "https://proxy.example",
                "PAID_API_TOKEN": "secret",
            },
        ):
            environment = local_ollama_env()
        self.assertEqual(environment["OLLAMA_HOST"], "http://127.0.0.1:11434")
        self.assertNotIn("HTTPS_PROXY", environment)
        self.assertNotIn("PAID_API_TOKEN", environment)
        validate_local_ollama_model("llama3.2")
        with self.assertRaisesRegex(ValueError, "cloud models"):
            validate_local_ollama_model("gpt-oss:120b-cloud")

    def test_relative_output_rejects_symlinked_ancestors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resolved_root = root.resolve()
            outside = root / "outside"
            outside.mkdir()
            (root / "linked").symlink_to(outside, target_is_directory=True)
            with patch("aeo_gate.capture.Path.cwd", return_value=resolved_root):
                with self.assertRaisesRegex(ValueError, "symlink components"):
                    normalize_output_dir(Path("linked/run"), label="run directory")
                with self.assertRaisesRegex(ValueError, "symlink components"):
                    normalize_output_dir(
                        resolved_root / "linked/run",
                        label="fleet output directory",
                    )

    def test_probe_rejects_private_query_and_cross_host_targets(self):
        with self.assertRaisesRegex(ValueError, "non-public"):
            fetch("http://127.0.0.1", agent="gptbot", timeout=1)
        with self.assertRaisesRegex(ValueError, "without a query"):
            fetch(
                "https://example.com/?token=secret",
                agent="gptbot",
                timeout=1,
            )
        with self.assertRaisesRegex(ValueError, "changed the configured hostname"):
            _validate_public_url(
                "https://other.example/",
                expected_host="example.com",
            )

    def test_probe_body_redacts_embedded_secret_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observation = ProbeObservation(
                agent="gptbot",
                user_agent="GPTBot/1.0",
                requested_url="https://example.test",
                final_url="https://example.test",
                status=200,
                headers={"content-type": "text/html"},
                fetched_at="2026-08-09T00:00:00Z",
                body_bytes=100,
                truncated=False,
            )
            _, body_path = write_probe(
                root,
                observation,
                b'<main>marker</main><script data-cf-beacon=\'{"token":"live-secret"}\' '
                b'data-api-key="attribute-secret"></script>',
            )
            self.assertIsNotNone(body_path)
            stored = body_path.read_bytes()
            self.assertIn(b"marker", stored)
            self.assertEqual(stored.count(b"<REDACTED>"), 2)
            self.assertNotIn(b"live-secret", stored)
            self.assertNotIn(b"attribute-secret", stored)

    def test_atomic_write_preserves_previous_file_when_replace_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "artifact.json"
            destination.write_text("accepted")
            with patch(
                "aeo_gate.capture.os.replace", side_effect=OSError("replace failed")
            ):
                with self.assertRaises(OSError):
                    atomic_write(destination, "partial")
            self.assertEqual(destination.read_text(), "accepted")
            self.assertEqual(list(root.glob(".artifact.json.*")), [])

    def test_scanner_command_is_exactly_version_pinned(self):
        self.assertEqual(
            scanner_argv("https://example.test"),
            [
                "uvx",
                "--from",
                "geo-optimizer-skill==4.16",
                "geo",
                "audit",
                "--url",
                "https://example.test",
                "--format",
                "json",
                "--verbose",
                "--no-plugins",
            ],
        )


class BaselineTests(unittest.TestCase):
    def test_valid_baseline_is_graded_scoreless_and_manifested(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = self._checkout(root)
            run_dir = root / "run"
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            self.assertEqual(baseline.overall_status, Status.PASS)
            payload = json.loads((run_dir / "baseline.json").read_text())
            assert_no_composite_score(payload)
            self.assertNotIn("score", json.dumps(payload).casefold())
            self.assertTrue(all(item["evidence_grade"] for item in payload["findings"]))
            self.assertTrue(
                all(
                    "seo_impact" in item and "aeo_impact" in item
                    for item in payload["findings"]
                )
            )
            llms = next(
                item
                for item in payload["findings"]
                if item["rule"] == "llms.txt-missing"
            )
            self.assertEqual(llms["disposition"], Disposition.DROPPED)
            self.assertEqual(llms["suggested_action"], "")
            ambiguity = next(
                item
                for item in payload["findings"]
                if item["rule"] == "image-alt-ambiguity"
            )
            self.assertEqual(ambiguity["disposition"], Disposition.AMBIGUOUS)
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])
            self.assertTrue((run_dir / "raw" / "probe-gptbot.html").is_file())
            self.assertFalse((run_dir / "raw" / "probe-claudebot.html").exists())
            self.assertTrue(payload["raw_artifacts"])
            self.assertTrue(
                all(
                    item["path"].startswith("raw/")
                    and item["bytes"] >= 0
                    and len(item["sha256"]) == 64
                    for item in payload["raw_artifacts"]
                )
            )
            probe_receipt = json.loads(
                (run_dir / "raw" / "probe-gptbot.json").read_text()
            )
            self.assertEqual(probe_receipt["user_agent"], "GPTBot/1.0")
            self.assertEqual(probe_receipt["redirects"], [])
            scanner_receipt = json.loads(
                (run_dir / "raw" / "geo-optimizer.receipt.json").read_text()
            )
            self.assertEqual(
                scanner_receipt["scanner_package"], "geo-optimizer-skill==4.16"
            )

    def test_real_scanner_check_shape_retains_failed_observations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scanner = root / "scanner.json"
            scanner.write_text(
                json.dumps(
                    {
                        "checks": {
                            "schema_jsonld": {"passed": False, "score": 0, "max": 16},
                            "meta_tags": {"passed": True, "score": 14, "max": 14},
                            "llms_txt": {"passed": False, "score": 0, "max": 18},
                        }
                    }
                )
            )
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=root / "run",
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=scanner,
            )
            scanner_findings = {
                finding.rule: finding
                for finding in baseline.findings
                if finding.detector == "geo-optimizer"
            }
            self.assertEqual(set(scanner_findings), {"llms_txt", "schema_jsonld"})
            self.assertEqual(
                scanner_findings["llms_txt"].disposition, Disposition.DROPPED
            )
            self.assertEqual(
                scanner_findings["schema_jsonld"].disposition,
                Disposition.NO_LLM_PASS,
            )

    def test_optional_triage_changes_only_allowed_fields_and_records_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = self._checkout(root)
            untriaged = run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=root / "untriaged",
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            candidate = next(
                finding
                for finding in untriaged.findings
                if finding.disposition is Disposition.NO_LLM_PASS
            )
            response = root / "triage-response.json"
            response.write_text(
                json.dumps(
                    {
                        "findings": [
                            {
                                "fingerprint": candidate.fingerprint,
                                "disposition": "dropped",
                                "rationale": "The scanner observation is not actionable.",
                            }
                        ]
                    }
                )
            )
            triaged = run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=root / "triaged",
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
                enable_triage=True,
                triage_prompt=SKILL_DIR / "prompts" / "triage.md",
                triage_provider="local",
                triage_model="fixture",
                triage_response_file=response,
            )
            result = next(
                finding
                for finding in triaged.findings
                if finding.fingerprint == candidate.fingerprint
            )
            self.assertEqual(result.disposition, Disposition.DROPPED)
            self.assertEqual(result.evidence_grade, candidate.evidence_grade)
            self.assertEqual(result.seo_impact, candidate.seo_impact)
            self.assertEqual(result.aeo_impact, candidate.aeo_impact)
            self.assertEqual(result.raw_evidence, candidate.raw_evidence)
            self.assertEqual(
                (triaged.tools["triage-provider"], triaged.tools["triage-model"]),
                ("local", "fixture"),
            )
            self.assertEqual(
                next(
                    stage for stage in triaged.stages if stage.name == "model-triage"
                ).status,
                Status.PASS,
            )
            self.assertEqual(
                verify_manifest(root / "triaged" / "manifest.json"),
                [],
            )

    def test_invalid_triage_output_is_indeterminate_without_grade_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            response = root / "triage-response.json"
            response.write_text(
                json.dumps(
                    {
                        "findings": [
                            {
                                "fingerprint": "not-a-real-fingerprint",
                                "disposition": "kept",
                                "rationale": "unsupported",
                                "evidence_grade": "STRONG",
                            }
                        ]
                    }
                )
            )
            run_dir = root / "run"
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
                enable_triage=True,
                triage_prompt=SKILL_DIR / "prompts" / "triage.md",
                triage_provider="local",
                triage_model="fixture",
                triage_response_file=response,
            )
            self.assertEqual(baseline.overall_status, Status.INDETERMINATE)
            self.assertTrue(
                any(
                    finding.disposition is Disposition.NO_LLM_PASS
                    for finding in baseline.findings
                )
            )
            self.assertEqual(
                next(
                    stage for stage in baseline.stages if stage.name == "model-triage"
                ).status,
                Status.INDETERMINATE,
            )
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])

    def test_mapping_failure_emits_no_findings_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = self._checkout(root, source="different")
            run_dir = root / "run"
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            self.assertEqual(baseline.overall_status, Status.INDETERMINATE)
            self.assertEqual(baseline.findings, [])
            self.assertFalse((run_dir / "raw" / "geo-optimizer.stdout").exists())

    def test_vacuous_same_as_is_higher_severity_than_absence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=root / "run",
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "vacuous.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            finding = next(
                item for item in baseline.findings if item.rule == "entity-same-as"
            )
            self.assertEqual(finding.state, VACUOUS)
            self.assertEqual(finding.severity, "high")

    def test_malformed_scanner_retains_partial_evidence_and_is_indeterminate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner-malformed.json",
            )
            self.assertEqual(baseline.overall_status, Status.INDETERMINATE)
            self.assertTrue((run_dir / "raw" / "geo-optimizer.stdout").exists())
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])

    def test_structurally_invalid_scanner_fails_closed_with_raw_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scanner = root / "scanner.json"
            scanner.write_text("{}")
            run_dir = root / "run"
            baseline = run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=scanner,
            )
            self.assertEqual(baseline.overall_status, Status.INDETERMINATE)
            scanner_stage = next(
                stage for stage in baseline.stages if stage.name == "geo-optimizer"
            )
            self.assertIn(
                "requires a findings list or checks object", scanner_stage.reason
            )
            self.assertTrue((run_dir / "raw" / "geo-optimizer.stdout").is_file())
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])

    def test_missing_scanner_fails_closed_without_erasing_probe_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            with patch("aeo_gate.scanner.shutil.which", return_value=None):
                baseline = run_baseline(
                    project="example",
                    url="https://example.test",
                    checkout=self._checkout(root),
                    run_dir=run_dir,
                    marker_file="site.html",
                    marker=MARKER,
                    html_file=FIXTURES / "valid.html",
                )
            self.assertEqual(baseline.overall_status, Status.INDETERMINATE)
            scanner_stage = next(
                stage for stage in baseline.stages if stage.name == "geo-optimizer"
            )
            self.assertIn("unavailable", scanner_stage.reason)
            self.assertTrue((run_dir / "raw" / "probe-gptbot.html").is_file())
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])

    def test_truncated_primary_probe_fails_closed_before_mapping(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def truncated_fetch(url, *, agent, timeout):
                body = MARKER.encode()
                return (
                    ProbeObservation(
                        agent=agent,
                        user_agent=USER_AGENTS[agent],
                        requested_url=url,
                        final_url=url,
                        status=200,
                        headers={"content-type": "text/html"},
                        fetched_at="2026-08-09T00:00:00Z",
                        body_bytes=len(body),
                        truncated=agent == "gptbot",
                    ),
                    body,
                )

            with patch("aeo_gate.baseline.fetch", side_effect=truncated_fetch):
                baseline = run_baseline(
                    project="example",
                    url="https://example.test",
                    checkout=self._checkout(root),
                    run_dir=root / "run",
                    marker_file="site.html",
                    marker=MARKER,
                    scanner_json=FIXTURES / "scanner.json",
                )
            self.assertEqual(baseline.overall_status, Status.INDETERMINATE)
            self.assertEqual(baseline.findings, [])
            self.assertIn("truncated", baseline.mapping.reason)

    def test_fixture_replay_has_stable_findings_and_no_llm_stage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = self._checkout(root)
            payloads = []
            for name in ("first", "second"):
                run_dir = root / name
                baseline = run_baseline(
                    project="example",
                    url="https://example.test",
                    checkout=checkout,
                    run_dir=run_dir,
                    marker_file="site.html",
                    marker=MARKER,
                    html_file=FIXTURES / "valid.html",
                    scanner_json=FIXTURES / "scanner.json",
                )
                no_llm = next(
                    stage for stage in baseline.stages if stage.name == "model-triage"
                )
                self.assertEqual(
                    no_llm.reason, "no-llm-pass: deterministic dispositions retained"
                )
                payloads.append(json.loads((run_dir / "baseline.json").read_text()))
            self.assertEqual(payloads[0]["findings"], payloads[1]["findings"])
            self.assertEqual(payloads[0]["delta"], payloads[1]["delta"])

    def test_baseline_refuses_to_mix_evidence_in_a_reused_run_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            arguments = {
                "project": "example",
                "url": "https://example.test",
                "checkout": self._checkout(root),
                "run_dir": run_dir,
                "marker_file": "site.html",
                "marker": MARKER,
                "html_file": FIXTURES / "valid.html",
                "scanner_json": FIXTURES / "scanner.json",
            }
            run_baseline(**arguments)
            with self.assertRaisesRegex(ValueError, "must be new or empty"):
                run_baseline(**arguments)

    def test_previous_baseline_must_match_exact_target_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = self._checkout(root)
            accepted_dir = root / "accepted"
            run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=accepted_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            with self.assertRaisesRegex(ValueError, "identity"):
                run_baseline(
                    project="other-project",
                    url="https://example.test",
                    checkout=checkout,
                    run_dir=root / "rejected",
                    marker_file="site.html",
                    marker=MARKER,
                    previous_baseline=accepted_dir / "baseline.json",
                    html_file=FIXTURES / "valid.html",
                    scanner_json=FIXTURES / "scanner.json",
                )

    def test_accepted_baseline_reconciles_raw_metadata_with_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = self._checkout(root)
            run_dir = root / "accepted"
            run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            manifest = json.loads((run_dir / "manifest.json").read_text())
            payload = json.loads((run_dir / "baseline.json").read_text())
            payload["raw_artifacts"][0]["bytes"] += 1
            (run_dir / "baseline.json").write_text(json.dumps(payload))
            files = [
                run_dir / item["path"]
                for item in manifest["artifacts"]
                if item["path"] != "manifest.json"
            ]
            write_manifest(run_dir, files, metadata=manifest["metadata"])
            with self.assertRaisesRegex(ValueError, "metadata does not match"):
                validate_accepted_baseline(
                    run_dir / "baseline.json",
                    project="example",
                    domain="https://example.test",
                    checkout=checkout.name,
                    allow_fixture=True,
                )

    def test_manifest_detects_modified_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            (run_dir / "raw" / "probe-gptbot.html").write_text("tampered")
            self.assertTrue(
                any(
                    "mismatch" in error
                    for error in verify_manifest(run_dir / "manifest.json")
                )
            )

    def test_manifest_rejects_untracked_symlinked_escaping_and_corrupt_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            run_baseline(
                project="example",
                url="https://example.test",
                checkout=self._checkout(root),
                run_dir=run_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            manifest = run_dir / "manifest.json"
            extra = run_dir / "untracked.txt"
            extra.write_text("untracked")
            self.assertTrue(
                any(
                    "unmanifested artifact" in error
                    for error in verify_manifest(manifest)
                )
            )
            extra.unlink()

            linked = run_dir / "raw" / "mapping.json"
            linked.unlink()
            linked.symlink_to(root / "outside.json")
            (root / "outside.json").write_text("{}")
            self.assertTrue(
                any("regular file" in error for error in verify_manifest(manifest))
            )
            linked.unlink()
            self.assertTrue(
                any("missing" in error for error in verify_manifest(manifest))
            )

            payload = json.loads(manifest.read_text())
            payload["artifacts"].append(
                {"path": "../outside.json", "bytes": 2, "sha256": "0" * 64}
            )
            payload["artifacts"].append(payload["artifacts"][0])
            manifest.write_text(json.dumps(payload))
            errors = verify_manifest(manifest)
            self.assertTrue(any("escaping artifact" in error for error in errors))
            self.assertTrue(any("duplicate artifact" in error for error in errors))

            manifest.write_text("{")
            self.assertTrue(
                any(
                    "manifest unreadable" in error
                    for error in verify_manifest(manifest)
                )
            )

    def _checkout(self, root: Path, source: str | None = None) -> Path:
        checkout = root / "checkout"
        checkout.mkdir()
        (checkout / "site.html").write_text(source if source is not None else MARKER)
        return checkout


class FleetTests(unittest.TestCase):
    def test_fleet_isolates_target_failures_and_manifests_rollup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / "checkout"
            checkout.mkdir()
            (checkout / "site.html").write_text(MARKER)
            targets = root / "targets.md"
            targets.write_text(
                "## Active targets\n| Project | URL | Checkout | Marker file | Marker |\n"
                "|---|---|---|---|---|\n"
                f"| demo | https://demo.test | {checkout} | site.html | {MARKER} |\n"
                f"| broken | https://broken.test | {checkout} | site.html | {MARKER} |\n"
                "## Explicit skips\n| Project | Reason |\n|---|---|\n"
                "| native | no public site |\n"
            )
            registry = root / "registry.md"
            registry.write_text(
                "## Active projects\n| Project | Path |\n|---|---|\n"
                "| demo | /demo |\n| broken | /broken |\n| native | /native |\n"
            )
            blacklist = root / "blacklist.md"
            blacklist.write_text(
                "## 1. Temporarily excluded (registered projects)\n"
                "| Project | Reason |\n|---|---|\n"
                "## 2. Permanently excluded from management\n"
                "| Path | Reason |\n|---|---|\n"
            )
            html_dir = root / "html"
            scanner_dir = root / "scanner"
            html_dir.mkdir()
            scanner_dir.mkdir()
            shutil.copyfile(FIXTURES / "valid.html", html_dir / "demo.html")
            shutil.copyfile(FIXTURES / "scanner.json", scanner_dir / "demo.json")
            output_dir = root / "2026-07-01"
            rollup = run_fleet(
                targets_path=targets,
                registry_path=registry,
                blacklist_path=blacklist,
                output_dir=output_dir,
                timeout=5,
                html_fixture_dir=html_dir,
                scanner_fixture_dir=scanner_dir,
            )
            self.assertEqual(rollup["status"], Status.INDETERMINATE.value)
            self.assertEqual(
                rollup["counts"],
                {
                    "active": 2,
                    "skipped": 1,
                    "pass": 1,
                    "regression": 0,
                    "indeterminate": 1,
                },
            )
            self.assertTrue((output_dir / "demo" / "baseline.json").is_file())
            self.assertTrue((output_dir / "broken" / "error.json").is_file())
            self.assertEqual(verify_manifest(output_dir / "demo" / "manifest.json"), [])
            self.assertEqual(
                verify_manifest(output_dir / "broken" / "manifest.json"), []
            )
            self.assertEqual(verify_manifest(output_dir / "manifest.json"), [])
            shutil.copyfile(FIXTURES / "valid.html", html_dir / "broken.html")
            shutil.copyfile(FIXTURES / "scanner.json", scanner_dir / "broken.json")
            shutil.copyfile(FIXTURES / "vacuous.html", html_dir / "demo.html")
            next_output = root / "2026-08-01"
            next_rollup = run_fleet(
                targets_path=targets,
                registry_path=registry,
                blacklist_path=blacklist,
                output_dir=next_output,
                timeout=5,
                previous_root=output_dir,
                html_fixture_dir=html_dir,
                scanner_fixture_dir=scanner_dir,
            )
            broken = next(
                item for item in next_rollup["targets"] if item["project"] == "broken"
            )
            self.assertEqual(broken["status"], Status.INDETERMINATE.value)
            self.assertIn("previous-baseline-unresolved", broken["comparison"])
            self.assertTrue((next_output / "broken" / "baseline.json").is_file())
            demo = next(
                item for item in next_rollup["targets"] if item["project"] == "demo"
            )
            self.assertEqual(demo["status"], Status.REGRESSION.value)
            shutil.copyfile(FIXTURES / "valid.html", html_dir / "demo.html")
            final_output = root / "2026-09-01"
            final_rollup = run_fleet(
                targets_path=targets,
                registry_path=registry,
                blacklist_path=blacklist,
                output_dir=final_output,
                timeout=5,
                previous_root=next_output,
                html_fixture_dir=html_dir,
                scanner_fixture_dir=scanner_dir,
            )
            final_demo = next(
                item for item in final_rollup["targets"] if item["project"] == "demo"
            )
            self.assertEqual(final_demo["status"], Status.PASS.value)
            self.assertEqual(final_demo["comparison"], "accepted:2026-07-01")


class MappingAndDiffTests(unittest.TestCase):
    def test_mapping_requires_marker_in_both_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            (checkout / "page").write_text(MARKER)
            self.assertTrue(prove_mapping(checkout, MARKER, "page", MARKER).proven)
            missing_live = prove_mapping(checkout, "other", "page", MARKER)
            self.assertFalse(missing_live.proven)
            self.assertTrue(missing_live.local_source_sha256)
            self.assertTrue(missing_live.live_html_sha256)
            self.assertTrue(missing_live.local_marker_sha256)
            self.assertFalse(missing_live.live_marker_sha256)

    def test_targets_reject_active_skip_overlap(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "targets.md"
            path.write_text(
                "## Active targets\n| Project | URL | Checkout | Marker file | Marker |\n"
                "|---|---|---|---|---|\n| demo | https://demo.test | /tmp/demo | page | marker |\n"
                "## Explicit skips\n| Project | Reason |\n|---|---|\n| demo | no public site |\n"
            )
            with self.assertRaises(ValueError):
                parse_targets(path)

    def test_reconciliation_rejects_duplicate_and_empty_registries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            targets = root / "targets.md"
            targets.write_text(
                "## Active targets\n"
                "| Project | URL | Checkout | Marker file | Marker |\n"
                "|---|---|---|---|---|\n"
                f"| demo | https://demo.test | {root} | page | {MARKER} |\n"
                "## Explicit skips\n| Project | Reason |\n|---|---|\n"
            )
            blacklist = root / "blacklist.md"
            blacklist.write_text(
                "## 1. Temporarily excluded (registered projects)\n"
                "| Project | Reason |\n|---|---|\n"
                "## 2. Permanently excluded from management\n"
            )
            active, skipped = parse_targets(targets)
            registry = root / "registry.md"
            registry.write_text(
                "## Active projects\n| Project | Path |\n|---|---|\n"
                "| demo | /one |\n| demo | /two |\n"
            )
            with self.assertRaisesRegex(ValueError, "duplicate projects"):
                reconcile_targets(
                    registry_path=registry,
                    blacklist_path=blacklist,
                    active=active,
                    skipped=skipped,
                )
            registry.write_text("## Active projects\n| Project | Path |\n|---|---|\n")
            with self.assertRaisesRegex(ValueError, "must not be empty"):
                reconcile_targets(
                    registry_path=registry,
                    blacklist_path=blacklist,
                    active=[],
                    skipped={},
                )

    def test_targets_reject_unsafe_output_names_and_marker_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for project, marker_file in (("../escape", "page"), ("demo", "../page")):
                path = (
                    root
                    / f"{project.replace('/', '-')}-{marker_file.replace('/', '-')}.md"
                )
                path.write_text(
                    "## Active targets\n"
                    "| Project | URL | Checkout | Marker file | Marker |\n"
                    "|---|---|---|---|---|\n"
                    f"| {project} | https://demo.test | /tmp/demo | {marker_file} | marker |\n"
                    "## Explicit skips\n| Project | Reason |\n|---|---|\n"
                )
                with self.assertRaises(ValueError):
                    parse_targets(path)

    def test_checked_in_targets_carry_no_machine_roster(self):
        # Spec 036 T20 moved the AEO roster out of the tracked template and into
        # `scripts/materialize-scheduled-task.sh`, which renders a local-only
        # table under `~/.trellis/tasks/<fleet>/aeo-baseline/aeo-targets.md`.
        # The tracked file is now a contract document, so what it must guarantee
        # is the *absence* of machine state, not reconciliation against
        # `registry.md`/`blacklist.md` (themselves removed at T31/T32).
        path = REPO_ROOT / "scheduled-tasks" / "aeo-baseline" / "targets.md"
        active, skipped = parse_targets(path)
        self.assertEqual(active, [])
        self.assertEqual(skipped, {})
        text = path.read_text(encoding="utf-8")
        for leak in ("/Users/", "/home/", "https://", "http://"):
            self.assertNotIn(leak, text)
        self.assertFalse(
            [line for line in text.splitlines() if line.strip().startswith("|")],
            "tracked AEO template must carry no roster table",
        )

    def test_materialized_targets_reconcile_registry_minus_blacklist(self):
        # The reconciliation invariant the tracked file used to carry now binds
        # the materializer's rendered output: every registry entry appears
        # exactly once as a mapped target or an explicit skip.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            registry = root / "registry.md"
            registry.write_text(
                "## Active projects\n| Project | Path |\n|---|---|\n"
                "| alpha | /one |\n| bravo | /two |\n| charlie | /three |\n"
            )
            blacklist = root / "blacklist.md"
            blacklist.write_text(
                "## 1. Temporarily excluded (registered projects)\n"
                "| Project | Reason |\n|---|---|\n| charlie | on hold |\n"
                "## 2. Permanently excluded from management\n"
            )
            rendered = root / "aeo-targets.md"
            rendered.write_text(
                "## Active targets\n"
                "| Project | URL | Checkout | Marker file | Marker |\n"
                "|---|---|---|---|---|\n"
                f"| alpha | https://alpha.test | {root} | page | {MARKER} |\n"
                "## Explicit skips\n| Project | Reason |\n|---|---|\n"
                "| bravo | no public site |\n"
            )
            active, skipped = parse_targets(rendered)
            reconcile_targets(
                registry_path=registry,
                blacklist_path=blacklist,
                active=active,
                skipped=skipped,
            )
            rendered.write_text(
                "## Active targets\n"
                "| Project | URL | Checkout | Marker file | Marker |\n"
                "|---|---|---|---|---|\n"
                f"| alpha | https://alpha.test | {root} | page | {MARKER} |\n"
                "## Explicit skips\n| Project | Reason |\n|---|---|\n"
            )
            dropped_active, dropped_skipped = parse_targets(rendered)
            with self.assertRaisesRegex(ValueError, "missing: bravo"):
                reconcile_targets(
                    registry_path=registry,
                    blacklist_path=blacklist,
                    active=dropped_active,
                    skipped=dropped_skipped,
                )

    def test_diff_is_warn_only_and_reports_regression(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / "checkout"
            checkout.mkdir()
            self._git(checkout, "init")
            self._git(checkout, "config", "user.email", "test@example.test")
            self._git(checkout, "config", "user.name", "AEO Test")
            (checkout / "site.html").write_text(MARKER)
            self._git(checkout, "add", "site.html")
            self._git(checkout, "commit", "-m", "base")
            base = self._git(checkout, "rev-parse", "HEAD").strip()
            baseline_dir = checkout / "audits" / "aeo"
            run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=baseline_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            (checkout / "site.html").write_text(MARKER + "\nchanged")
            self._git(checkout, "add", "site.html", "audits/aeo")
            self._git(checkout, "commit", "-m", "page")
            mapped_head = self._git(checkout, "rev-parse", "HEAD").strip()
            result = run_diff(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=root / "diff",
                marker_file="site.html",
                marker=MARKER,
                previous_baseline=baseline_dir / "baseline.json",
                git_range=f"{base}..HEAD",
                html_file=FIXTURES / "vacuous.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            self.assertTrue(result.new)
            self.assertTrue(result.unchanged)
            self.assertTrue(result.resolved)
            (checkout / "page.tsx").write_text(
                "export default function Page(){return null}"
            )
            self._git(checkout, "add", "page.tsx")
            self._git(checkout, "commit", "-m", "unmapped-page")
            unresolved = run_diff(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=root / "unmapped-diff",
                marker_file="site.html",
                marker=MARKER,
                previous_baseline=baseline_dir / "baseline.json",
                git_range=f"{base}..HEAD",
                html_file=FIXTURES / "vacuous.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            self.assertEqual(unresolved.overall_status, Status.INDETERMINATE)
            self.assertEqual(unresolved.findings, [])
            self.assertEqual(
                (unresolved.new, unresolved.unchanged, unresolved.resolved),
                ([], [], []),
            )
            self.assertIn(
                "affected-page URL mapping is unavailable",
                next(
                    stage.reason
                    for stage in unresolved.stages
                    if stage.name == "changed-pages"
                ),
            )
            added_head = self._git(checkout, "rev-parse", "HEAD").strip()
            (checkout / "page.tsx").unlink()
            self._git(checkout, "add", "page.tsx")
            self._git(checkout, "commit", "-m", "delete-unmapped-page")
            deleted = run_diff(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=root / "deleted-diff",
                marker_file="site.html",
                marker=MARKER,
                previous_baseline=baseline_dir / "baseline.json",
                git_range=f"{added_head}..HEAD",
                html_file=FIXTURES / "vacuous.html",
                scanner_json=FIXTURES / "scanner.json",
            )
            self.assertEqual(deleted.overall_status, Status.INDETERMINATE)
            self.assertEqual(deleted.findings, [])
            baseline_path = baseline_dir / "baseline.json"
            baseline_path.write_text(baseline_path.read_text() + " ")
            with self.assertRaisesRegex(
                ValueError, "accepted baseline manifest is invalid"
            ):
                run_diff(
                    project="example",
                    url="https://example.test",
                    checkout=checkout,
                    run_dir=root / "tampered-diff",
                    marker_file="site.html",
                    marker=MARKER,
                    previous_baseline=baseline_path,
                    git_range=f"{base}..{mapped_head}",
                    html_file=FIXTURES / "vacuous.html",
                    scanner_json=FIXTURES / "scanner.json",
                )
            self.assertEqual(result.overall_status, Status.REGRESSION)
            verdict = warn_only_verdict(result)
            self.assertIn("REGRESSION", verdict)
            self.assertIn("merge_policy=non-blocking", verdict)

    def _git(self, checkout: Path, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=checkout, check=True, capture_output=True, text=True
        ).stdout


class DeepReviewTests(unittest.TestCase):
    def test_deep_review_is_bounded_and_model_derived(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            baseline_path = self._baseline(root)
            output = run_deep(
                html_path=FIXTURES / "valid.html",
                baseline_path=baseline_path,
                run_dir=run_dir,
                prompt_template=SKILL_DIR / "prompts" / "deep.md",
                provider="local",
                model="fixture",
                confirm_remote=False,
                response_file=FIXTURES / "deep-response.json",
            )
            self.assertEqual(output["source"], "MODEL_DERIVED")
            self.assertLessEqual(output["content_chars"], 12000)
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])
            self.assertIn(
                "DETERMINISTIC CONTEXT:",
                (run_dir / "raw" / "deep-input.txt").read_text(),
            )
            receipt = json.loads((run_dir / "raw" / "deep.receipt.json").read_text())
            self.assertEqual(
                (receipt["source"], receipt["provider"], receipt["model"]),
                ("fixture", "local", "fixture"),
            )

    def test_deep_review_truncates_oversized_visible_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            html = root / "large.html"
            html.write_text(f"<main><p>{'measured evidence ' * 2000}</p></main>")
            output = run_deep(
                html_path=html,
                baseline_path=self._baseline(root),
                run_dir=root / "run",
                prompt_template=SKILL_DIR / "prompts" / "deep.md",
                provider="local",
                model="fixture",
                confirm_remote=False,
                response_file=FIXTURES / "deep-response.json",
            )
            self.assertEqual(output["content_chars"], 12000)
            self.assertEqual(verify_manifest(root / "run" / "manifest.json"), [])

    def test_invalid_deep_output_fails_closed_and_preserves_manifested_raw_evidence(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            response = root / "invalid.json"
            response.write_text(
                json.dumps(
                    {
                        "findings": [
                            {
                                "aspect": "answer-first",
                                "rationale": "model prose",
                                "evidence_grade": "STRONG",
                            }
                        ]
                    }
                )
            )
            run_dir = root / "run"
            with self.assertRaisesRegex(ValueError, "deterministic evidence"):
                run_deep(
                    html_path=FIXTURES / "valid.html",
                    baseline_path=self._baseline(root),
                    run_dir=run_dir,
                    prompt_template=SKILL_DIR / "prompts" / "deep.md",
                    provider="local",
                    model="fixture",
                    confirm_remote=False,
                    response_file=response,
                )
            self.assertTrue((run_dir / "raw" / "deep.stdout").is_file())
            self.assertTrue((run_dir / "deep-error.json").is_file())
            self.assertEqual(verify_manifest(run_dir / "manifest.json"), [])

    def test_remote_deep_review_requires_confirmation_before_reading_response(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline_path = self._baseline(root)
            with self.assertRaisesRegex(ValueError, "confirm-remote"):
                run_deep(
                    html_path=FIXTURES / "valid.html",
                    baseline_path=baseline_path,
                    run_dir=root / "run",
                    prompt_template=SKILL_DIR / "prompts" / "deep.md",
                    provider="anthropic",
                    model="anthropic/remote",
                    confirm_remote=False,
                    response_file=FIXTURES / "deep-response.json",
                )
            with patch("aeo_gate.deep.sys.stdin.isatty", return_value=False):
                with self.assertRaisesRegex(ValueError, "interactive terminal"):
                    run_deep(
                        html_path=FIXTURES / "valid.html",
                        baseline_path=baseline_path,
                        run_dir=root / "remote-run",
                        prompt_template=SKILL_DIR / "prompts" / "deep.md",
                        provider="anthropic",
                        model="anthropic/remote",
                        confirm_remote=True,
                    )

    def _baseline(self, root: Path) -> Path:
        checkout = root / "checkout"
        checkout.mkdir(exist_ok=True)
        (checkout / "site.html").write_text(MARKER)
        baseline_dir = root / "baseline"
        if not baseline_dir.exists():
            run_baseline(
                project="example",
                url="https://example.test",
                checkout=checkout,
                run_dir=baseline_dir,
                marker_file="site.html",
                marker=MARKER,
                html_file=FIXTURES / "valid.html",
                scanner_json=FIXTURES / "scanner.json",
            )
        return baseline_dir / "baseline.json"


if __name__ == "__main__":
    unittest.main()
