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
import json, sys, os
raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_rank = {"CRITICAL": "critical", "HIGH": "high", "MODERATE": "medium", "MEDIUM": "medium", "LOW": "low"}
try:
    with open(raw) as fh: data = json.load(fh)
except Exception:
    sys.exit(0)
counter = 0
for result in data.get("results", []):
    src = (result.get("source") or {}).get("path", "")
    if src.startswith(root + os.sep): src = src[len(root) + 1:]
    for pkg in result.get("packages", []):
        info = pkg.get("package", {})
        name, ver, eco = info.get("name", "?"), info.get("version", "?"), info.get("ecosystem", "?")
        for vuln in pkg.get("vulnerabilities", []):
            vid = vuln.get("id", "OSV-UNKNOWN")
            summary = (vuln.get("summary") or vuln.get("details") or "")[:200].splitlines()[0] if (vuln.get("summary") or vuln.get("details")) else ""
            sev_raw = ""
            for s in vuln.get("severity", []) or []:
                if isinstance(s, dict):
                    sev_raw = s.get("type") or s.get("score") or ""
                    if sev_raw: break
            sev = "medium"
            for db_sev in vuln.get("database_specific", {}).get("severity", "") if isinstance(vuln.get("database_specific"), dict) else []:
                pass
            for grp in result.get("groups", []) or []:
                ms = grp.get("max_severity", "")
                if ms:
                    try:
                        score = float(ms)
                        if score >= 9: sev = "critical"
                        elif score >= 7: sev = "high"
                        elif score >= 4: sev = "medium"
                        else: sev = "low"
                    except ValueError:
                        pass
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
