#!/usr/bin/env bash
# Gitleaks — history-aware secret scan, emits normalized findings JSONL.
# Usage: gitleaks.sh <project-dir> <out-jsonl>

set -euo pipefail

PROJECT_DIR="${1:?project-dir required}"
OUT="${2:?out-jsonl required}"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "warn: gitleaks not installed — skipping secrets stage" >&2
  : > "$OUT"
  exit 2
fi

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

CONFIG_ARGS=()
if [ -f "$PROJECT_DIR/.gitleaks.toml" ]; then
  CONFIG_ARGS=(--config "$PROJECT_DIR/.gitleaks.toml")
fi

# gitleaks exits 1 when leaks found; that is success for us.
gitleaks detect \
  --source "$PROJECT_DIR" \
  --report-format json \
  --report-path "$RAW" \
  --redact \
  --no-banner \
  "${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}" \
  >/dev/null 2>&1 || true

python3 - "$RAW" >"$OUT" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    with open(raw) as fh: data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for i, leak in enumerate(data, 1):
    commit = (leak.get("Commit") or "")[:8]
    rule = leak.get("RuleID") or "unknown"
    desc = leak.get("Description") or rule
    out = {
        "id": f"gitleaks-{i:04d}",
        "tool": "gitleaks",
        "rule": rule,
        "severity": "high",
        "file": leak.get("File") or "",
        "line": leak.get("StartLine") or 0,
        "message": f"{desc} (commit={commit})" if commit else desc,
    }
    print(json.dumps(out, ensure_ascii=False))
PY
