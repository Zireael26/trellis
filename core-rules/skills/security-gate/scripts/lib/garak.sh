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

# shellcheck disable=SC2034  # PROJECT_DIR consumed by sourced caller
PROJECT_DIR="${1:?project-dir required}"
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPORT_DIR="$WORK/garak-out"
mkdir -p "$REPORT_DIR"

RUNNER=()
if command -v timeout >/dev/null 2>&1; then RUNNER=(timeout --preserve-status "$TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then RUNNER=(gtimeout --preserve-status "$TIMEOUT")
fi

# Garak writes a JSONL report under the report dir; capture path.
"${RUNNER[@]}" garak \
  --model_type "$MODEL_TYPE" \
  --model_name "$MODEL_NAME" \
  --probes "$PROBES" \
  --report_prefix "$REPORT_DIR/garak" \
  --narrow_output \
  >/dev/null 2>"$WORK/garak.err" || true

REPORT="$(ls -1 "$REPORT_DIR"/garak.*.report.jsonl 2>/dev/null | head -1)"
if [ -z "$REPORT" ] || [ ! -s "$REPORT" ]; then
  echo "warn: garak produced no report — see $WORK/garak.err" >&2
  : > "$OUT"
  exit 2
fi

# Normalize each failed attempt into our finding shape.
python3 - "$REPORT" >"$OUT" <<'PY'
import json, sys
report = sys.argv[1]
counter = 0
with open(report) as fh:
    for ln in fh:
        ln = ln.strip()
        if not ln: continue
        try:
            r = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if r.get("entry_type") != "attempt": continue
        # Garak per-attempt records: status 0 = pass, 1 = fail (probe succeeded).
        if r.get("status", 0) == 0: continue
        probe = r.get("probe_classname") or r.get("probe") or "unknown"
        detector = r.get("detector_results") or {}
        # Severity heuristic: jailbreak / injection / leakage = high; others = medium.
        sev = "medium"
        for keyword, level in (("jailbreak", "high"), ("inject", "high"), ("leak", "high"), ("hijack", "high")):
            if keyword in probe.lower():
                sev = level
                break
        counter += 1
        print(json.dumps({
            "id": f"garak-{counter:04d}",
            "tool": "garak",
            "rule": probe,
            "severity": sev,
            "file": "(LLM endpoint)",
            "line": 0,
            "message": f"Probe succeeded — {probe} ({list(detector.keys())[:3]})",
        }, ensure_ascii=False))
PY
