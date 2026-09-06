#!/usr/bin/env bash
# Garak — NVIDIA OSS LLM vulnerability scanner. Probes a deployed LLM endpoint
# for prompt injection, jailbreak, leakage, and tool-misuse vulnerabilities.
# Activated by the web-rag-llm profile when project-local config declares a
# Garak target.
#
# Usage: garak.sh <project-dir> <out-jsonl>
#
# Project-local env (from security-gate-local/local.config.sh):
#   SECURITY_GATE_GARAK_TARGET   model spec, e.g. "openai:gpt-4o-mini" or
#                                "rest:./apps/ai-service/garak-rest.json"
#   SECURITY_GATE_GARAK_PROBES   comma-separated probe list (default:
#                                "promptinject.HijackHateHumans,latentinjection,leakreplay.LiteratureCloze")
#   SECURITY_GATE_GARAK_TIMEOUT  per-probe timeout in seconds (default: 600)
#
# Garak install (optional): `pipx install garak`. If missing, the wrapper
# warns and emits an empty findings stream — matches the semgrep/osv/gitleaks
# convention.

set -euo pipefail

: "${1:?project-dir required}"
OUT="${2:?out-jsonl required}"

if [ -z "${SECURITY_GATE_GARAK_TARGET:-}" ]; then
  echo "info: SECURITY_GATE_GARAK_TARGET unset — skipping LLM-app probe stage" >&2
  : > "$OUT"
  exit 2
fi

if ! command -v garak >/dev/null 2>&1; then
  echo "warn: garak not installed (pipx install garak) — skipping LLM-app probe stage" >&2
  : > "$OUT"
  exit 2
fi

PROBES="${SECURITY_GATE_GARAK_PROBES:-promptinject.HijackHateHumans,latentinjection,leakreplay.LiteratureCloze}"
TIMEOUT="${SECURITY_GATE_GARAK_TIMEOUT:-600}"

# Garak's target spec is "<model_type>:<model_name>".
MODEL_TYPE="${SECURITY_GATE_GARAK_TARGET%%:*}"
MODEL_NAME="${SECURITY_GATE_GARAK_TARGET#*:}"

RUNNER=()
if command -v timeout >/dev/null 2>&1; then
  RUNNER=(timeout --preserve-status "$TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then
  RUNNER=(gtimeout --preserve-status "$TIMEOUT")
else
  echo "warn: neither timeout nor gtimeout is available — refusing to invoke garak without a deadline" >&2
  : > "$OUT"
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPORT_DIR="$WORK/garak-out"
mkdir -p "$REPORT_DIR"

# Garak writes a JSONL report under the report dir; capture its status and path.
GARAK_RC=0
# SAFETY: SECURITY_GATE_GARAK_TIMEOUT, default 600 seconds per the env contract above, bounds the external scanner.
"${RUNNER[@]}" garak \
  --model_type "$MODEL_TYPE" \
  --model_name "$MODEL_NAME" \
  --probes "$PROBES" \
  --report_prefix "$REPORT_DIR/garak" \
  --narrow_output \
  >/dev/null 2>"$WORK/garak.err" || GARAK_RC=$?

if [ "$GARAK_RC" -ne 0 ]; then
  echo "warn: garak execution failed (rc=$GARAK_RC)" >&2
  if [ -s "$WORK/garak.err" ]; then cat "$WORK/garak.err" >&2; fi
  : > "$OUT"
  exit 2
fi

shopt -s nullglob
REPORTS=("$REPORT_DIR"/garak.*.report.jsonl)
shopt -u nullglob
REPORT="${REPORTS[0]:-}"
if [ -z "$REPORT" ] || [ ! -s "$REPORT" ]; then
  echo "warn: garak produced no report" >&2
  if [ -s "$WORK/garak.err" ]; then cat "$WORK/garak.err" >&2; fi
  : > "$OUT"
  exit 2
fi

# Normalize each failed attempt into our finding shape.
NORMALIZED="$WORK/normalized.jsonl"
NORMALIZE_RC=0
python3 - "$REPORT" >"$NORMALIZED" <<'PY' || NORMALIZE_RC=$?
import json
import sys

report = sys.argv[1]
counter = 0


def invalid(line_number, detail):
    print(f"warn: garak report {detail} at line {line_number}", file=sys.stderr)
    raise SystemExit(2)


with open(report) as fh:
    for line_number, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        # SAFETY: Every nonblank report line must decode; malformed scanner data makes the stage indeterminate.
        except json.JSONDecodeError:
            invalid(line_number, "contains malformed JSON")
        if not isinstance(record, dict):
            invalid(line_number, "contains a non-object record")
        if record.get("entry_type") != "attempt":
            continue
        if "status" not in record:
            print(f"warn: garak report attempt at line {line_number} has no status", file=sys.stderr)
            raise SystemExit(2)
        status = record["status"]
        if isinstance(status, bool) or status not in (0, 1):
            invalid(line_number, "contains an invalid attempt status")
        # Garak per-attempt records: status 0 = pass, 1 = fail (probe succeeded).
        if status == 0:
            continue
        probe = record.get("probe_classname") or record.get("probe") or "unknown"
        detector = record.get("detector_results") or {}
        if not isinstance(probe, str) or not isinstance(detector, dict):
            invalid(line_number, "contains an invalid attempt record")
        # Severity heuristic: jailbreak / injection / leakage = high; others = medium.
        severity = "medium"
        for keyword, level in (("jailbreak", "high"), ("inject", "high"), ("leak", "high"), ("hijack", "high")):
            if keyword in probe.lower():
                severity = level
                break
        counter += 1
        print(json.dumps({
            "id": f"garak-{counter:04d}",
            "tool": "garak",
            "rule": probe,
            "severity": severity,
            "file": "(LLM endpoint)",
            "line": 0,
            "message": f"Probe succeeded — {probe} ({list(detector.keys())[:3]})",
        }, ensure_ascii=False))
PY

if [ "$NORMALIZE_RC" -ne 0 ]; then
  : > "$OUT"
  exit 2
fi
mv "$NORMALIZED" "$OUT"
