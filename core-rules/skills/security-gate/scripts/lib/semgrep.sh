#!/usr/bin/env bash
# Semgrep scanner — emits normalized findings JSONL.
# Usage: semgrep.sh <project-dir> <profile> <out-jsonl>

set -euo pipefail

PROJECT_DIR="${1:?project-dir required}"
PROFILE="${2:?profile required}"
OUT="${3:?out-jsonl required}"

if ! command -v semgrep >/dev/null 2>&1; then
  echo "warn: semgrep not installed — skipping SAST stage" >&2
  : > "$OUT"
  exit 2
fi

SKILL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

case "$PROFILE" in
  web-next)
    CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript --config=p/nextjs --config=p/react)
    ;;
  web-static)
    CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript)
    ;;
  web-rag-llm)
    CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript --config=p/nextjs --config=p/react)
    if [ -d "$SKILL_ROOT/rulesets/web-rag-llm" ]; then
      CONFIGS+=("--config=$SKILL_ROOT/rulesets/web-rag-llm")
    fi
    ;;
  monorepo-saas)
    CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript --config=p/nextjs --config=p/react)
    ;;
  unity-game)
    CONFIGS=(--config=p/owasp-top-ten --config=p/csharp)
    if [ -d "$SKILL_ROOT/rulesets/unity-game" ]; then
      CONFIGS+=("--config=$SKILL_ROOT/rulesets/unity-game")
    fi
    ;;
  *)
    CONFIGS=(--config=p/owasp-top-ten)
    ;;
esac

EXCLUDES=(--exclude=node_modules --exclude=.next --exclude=dist --exclude=build --exclude=.turbo --exclude=test-results --exclude=coverage --exclude=audits --exclude=playwright-report)

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

# --error 0: do not exit non-zero just because findings exist; --metrics off: no telemetry.
if ! semgrep scan --json --metrics=off --quiet "${CONFIGS[@]}" "${EXCLUDES[@]}" "$PROJECT_DIR" >"$RAW" 2>/dev/null; then
  echo "warn: semgrep exited non-zero — partial output (if any) used" >&2
fi

# Normalize → JSONL of {tool, rule, severity, file, line, message}
python3 - "$RAW" "$PROJECT_DIR" >"$OUT" <<'PY'
import json, sys, os
raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_map = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}
try:
    with open(raw) as fh: data = json.load(fh)
except Exception:
    sys.exit(0)
for i, r in enumerate(data.get("results", []), 1):
    sev = sev_map.get((r.get("extra", {}).get("severity") or "").upper(), "low")
    path = r.get("path") or ""
    if path.startswith(root + os.sep): path = path[len(root) + 1:]
    out = {
        "id": f"semgrep-{i:04d}",
        "tool": "semgrep",
        "rule": r.get("check_id", "unknown"),
        "severity": sev,
        "file": path,
        "line": (r.get("start") or {}).get("line", 0),
        "message": (r.get("extra", {}).get("message") or "").splitlines()[0][:280],
    }
    print(json.dumps(out, ensure_ascii=False))
PY
