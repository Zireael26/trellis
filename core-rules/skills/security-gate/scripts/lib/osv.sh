#!/usr/bin/env bash
# OSV-scanner — emits normalized findings JSONL.
# Usage: osv.sh <project-dir> <out-jsonl>

set -euo pipefail

PROJECT_DIR="${1:?project-dir required}"
OUT="${2:?out-jsonl required}"

if ! command -v osv-scanner >/dev/null 2>&1; then
  echo "warn: osv-scanner not installed — skipping SCA stage" >&2
  : > "$OUT"
  exit 2
fi

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

# osv-scanner exits 1 when vulns are found; that is success for our purposes.
osv-scanner --format=json --recursive "$PROJECT_DIR" >"$RAW" 2>/dev/null || true

python3 - "$RAW" "$PROJECT_DIR" >"$OUT" <<'PY'
import json, math, os, sys

raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_rank = {"CRITICAL": "critical", "HIGH": "high", "MODERATE": "medium", "MEDIUM": "medium", "LOW": "low"}


def score_severity(value):
    try:
        score = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(score) or not 0 <= score <= 10:
        return None
    if score >= 9:
        return "critical"
    if score >= 7:
        return "high"
    if score >= 4:
        return "medium"
    return "low"


def vulnerability_severity(vuln, groups):
    vulnerability_id = vuln.get("id")
    for group in groups:
        if not isinstance(group, dict):
            continue
        ids = group.get("ids") or []
        if vulnerability_id in ids:
            normalized = score_severity(group.get("max_severity"))
            if normalized:
                return normalized

    database_specific = vuln.get("database_specific")
    if isinstance(database_specific, dict):
        database_severity = database_specific.get("severity")
        if isinstance(database_severity, str):
            normalized = sev_rank.get(database_severity.upper())
            if normalized:
                return normalized

    return "medium"


try:
    with open(raw) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
counter = 0
for result in data.get("results", []):
    src = (result.get("source") or {}).get("path", "")
    if src.startswith(root + os.sep): src = src[len(root) + 1:]
    for pkg in result.get("packages", []):
        info = pkg.get("package", {})
        name, ver, eco = info.get("name", "?"), info.get("version", "?"), info.get("ecosystem", "?")
        groups = pkg.get("groups", []) or []
        for vuln in pkg.get("vulnerabilities", []):
            vid = vuln.get("id", "OSV-UNKNOWN")
            summary = (vuln.get("summary") or vuln.get("details") or "")[:200].splitlines()[0] if (vuln.get("summary") or vuln.get("details")) else ""
            sev = vulnerability_severity(vuln, groups)
            counter += 1
            out = {
                "id": f"osv-{counter:04d}",
                "tool": "osv",
                "rule": vid,
                "severity": sev,
                "file": src,
                "line": 0,
                "message": f"{name}@{ver} ({eco}) — {summary}".strip(" —"),
            }
            print(json.dumps(out, ensure_ascii=False))
PY
