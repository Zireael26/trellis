#!/usr/bin/env bash
# Gitleaks — current-tree gate plus separately bucketed git-history visibility.
# Emits normalized JSONL with bucket=findings|historical_findings.
# Usage: gitleaks.sh <project-dir> <out-jsonl>

set -euo pipefail

PROJECT_DIR="${1:?project-dir required}"
OUT="${2:?out-jsonl required}"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "warn: gitleaks not installed — skipping secrets stage" >&2
  : > "$OUT"
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RAW_CURRENT="$WORK/current.json"
RAW_HISTORY="$WORK/history.json"
CURRENT_SOURCE="$PROJECT_DIR"

CONFIG_ARGS=()
if [ -f "$PROJECT_DIR/.gitleaks.toml" ]; then
  CONFIG_ARGS=(--config "$PROJECT_DIR/.gitleaks.toml")
fi

# --no-git scans do not honor .gitignore and can descend into dependency/build
# trees. Materialize the current Git-visible tree (tracked plus non-ignored
# untracked files) so the scan represents today's checkout without scanning
# node_modules, nested worktrees, or other ignored artifacts.
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CURRENT_SOURCE="$WORK/current-tree"
  mkdir -p "$CURRENT_SOURCE"
  git -C "$PROJECT_DIR" ls-files --cached --others --exclude-standard -z > "$WORK/all-current-files"
  python3 - "$PROJECT_DIR" "$WORK/all-current-files" "$WORK/current-files" <<'PY'
import os, sys
root, source_path, output_path = sys.argv[1:]
with open(source_path, "rb") as source, open(output_path, "wb") as output:
    for path in source.read().split(b"\0"):
        if not path:
            continue
        decoded = os.fsdecode(path)
        if os.path.lexists(os.path.join(root, decoded)):
            output.write(path + b"\0")
PY
  if [ -s "$WORK/current-files" ]; then
    tar -C "$PROJECT_DIR" --null -T "$WORK/current-files" -cf - | tar -C "$CURRENT_SOURCE" -xf -
  fi
fi

# Gitleaks exits 1 when leaks are found; that is a successful scanner run.
CURRENT_RC=0
gitleaks detect \
  --source "$CURRENT_SOURCE" \
  --no-git \
  --report-format json \
  --report-path "$RAW_CURRENT" \
  --redact \
  --no-banner \
  "${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}" \
  >/dev/null 2>&1 || CURRENT_RC=$?

HISTORY_RC=0
gitleaks detect \
  --source "$PROJECT_DIR" \
  --report-format json \
  --report-path "$RAW_HISTORY" \
  --redact \
  --no-banner \
  "${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}" \
  >/dev/null 2>&1 || HISTORY_RC=$?

[ -f "$RAW_CURRENT" ] || printf '[]\n' > "$RAW_CURRENT"
[ -f "$RAW_HISTORY" ] || printf '[]\n' > "$RAW_HISTORY"

python3 - "$RAW_CURRENT" "$RAW_HISTORY" "$CURRENT_SOURCE" >"$OUT" <<'PY'
import hashlib
import json
import os
import sys

current_path, history_path, current_root = sys.argv[1:]


def load(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        return []
    return data if isinstance(data, list) else []


def normalized_path(value, root=None):
    value = (value or "").replace("\\", "/")
    if root and value:
        root = os.path.abspath(root)
        absolute = os.path.abspath(value)
        try:
            relative = os.path.relpath(absolute, root)
        except ValueError:
            relative = value
        if relative != ".." and not relative.startswith("../"):
            value = relative
    return value[2:] if value.startswith("./") else value


def stable_id(prefix, fingerprint):
    digest = hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()[:12]
    return f"gitleaks-{prefix}-{digest}"


def normalize(leak, bucket, root=None):
    commit = leak.get("Commit") or ""
    rule = leak.get("RuleID") or "unknown"
    desc = leak.get("Description") or rule
    file = normalized_path(leak.get("File"), root)
    line = leak.get("StartLine") or 0
    if bucket == "findings":
        fingerprint = f"{file}:{rule}:{line}"
        prefix = "current"
    else:
        fingerprint = leak.get("Fingerprint") or f"{commit}:{file}:{rule}:{line}"
        prefix = "history"
    return {
        "id": stable_id(prefix, fingerprint),
        "tool": "gitleaks",
        "rule": rule,
        "severity": "high",
        "file": file,
        "line": line,
        "message": f"{desc} (commit={commit[:8]})" if commit else desc,
        "fingerprint": fingerprint,
        "bucket": bucket,
    }


current = [normalize(leak, "findings", current_root) for leak in load(current_path)]
# Git-mode reports the line at the introducing commit while --no-git reports
# today's line. Suppress history by rule+file so line drift cannot double-bucket
# a secret that is still present in the current tree.
current_identities = {(f["rule"], f["file"]) for f in current}

seen = set()
historical = []
for leak in load(history_path):
    finding = normalize(leak, "historical_findings")
    identity = (finding["rule"], finding["file"])
    if identity in current_identities or finding["fingerprint"] in seen:
        continue
    seen.add(finding["fingerprint"])
    historical.append(finding)

for finding in current + historical:
    print(json.dumps(finding, ensure_ascii=False))
PY

STATUS=0
case "$CURRENT_RC" in
  0|1) ;;
  *) echo "warn: gitleaks current-tree scan failed (rc=$CURRENT_RC)" >&2; STATUS=2 ;;
esac
case "$HISTORY_RC" in
  0|1) ;;
  *) echo "warn: gitleaks history scan failed (rc=$HISTORY_RC)" >&2; STATUS=2 ;;
esac
exit "$STATUS"
