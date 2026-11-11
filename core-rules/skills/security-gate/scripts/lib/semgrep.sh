#!/usr/bin/env bash
# Semgrep scanner — emits normalized findings JSONL.
# Usage: semgrep.sh <project-dir> <profile> <out-jsonl>
# Exit 0: completed (including findings); exit 2: incomplete.

# Inherited shell functions never answer for a tool. Every command name can be
# shadowed, `builtin` included, but an assignment cannot: POSIXLY_CORRECT turns
# on POSIX mode, where the special builtins `unset` and `set` are found before
# functions, so the first purge cannot be intercepted (see run-diff.sh).
POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
for _sg_fn in $(builtin compgen -A function 2>/dev/null); do builtin unset -f "$_sg_fn"; done
builtin unset -f semgrep python3
builtin unset _sg_fn

set -euo pipefail

PROJECT_DIR="${1:?project-dir required}"
PROFILE="${2:?profile required}"
OUT="${3:?out-jsonl required}"

case "$0" in */*) _sg_lib_dir="${0%/*}" ;; *) _sg_lib_dir=. ;; esac
builtin source "$_sg_lib_dir/engine.sh"
SEMGREP_BIN="$(sg_resolve_engine semgrep "$PROJECT_DIR")" || SEMGREP_BIN=""
# The real python3 behind any shim, never one the project picks (engine.sh).
PYTHON3_BIN="$(sg_resolve_python "$PROJECT_DIR")" || PYTHON3_BIN=""
if [ -z "$SEMGREP_BIN" ] || [ -z "$PYTHON3_BIN" ]; then
  echo "warn: semgrep or python3 unavailable or unsafe — skipping SAST stage" >&2
  : > "$OUT"
  exit 2
fi
if ! sg_path_sanitize "$PROJECT_DIR" || ! sg_vet_helpers "$PROJECT_DIR" bash dirname mktemp rm; then
  echo "semgrep did not complete: unsafe helper" >&2
  : > "$OUT"
  exit 2
fi
builtin unset BASH_ENV ENV PYTHONPATH PYTHONHOME

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
  shell-tooling)
    # Semgrep's registry has no bash ruleset (`p/bash` 404s). These are the two
    # packs whose rules can fire on shell at all. Real shell SAST for this repo is
    # ShellCheck, gated by .github/workflows/shellcheck.yml at severity=warning,
    # not by this engine — see SKILL.md "Shell coverage".
    CONFIGS=(--config=p/owasp-top-ten --config=p/command-injection --config=p/secrets)
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

# Without --error, semgrep exits 0 even with findings, so any other exit is an
# error. Its partial output is still normalized; the stage is incomplete.
# --metrics off: no telemetry.
SCAN_RC=0
"$SEMGREP_BIN" scan --json --metrics=off --quiet "${CONFIGS[@]}" "${EXCLUDES[@]}" "$PROJECT_DIR" >"$RAW" 2>/dev/null || SCAN_RC=$?

# Normalize → JSONL of {tool, rule, severity, file, line, message}
# A report that parses can still be partial: semgrep exits 0 with a Timeout or a
# partial parse listed in errors[]. Those findings are kept, but the stage did
# not complete (exit 4 here), the same rule run-diff.sh applies. Until 1.4.2
# this wrapper ignored errors[], the rc-0 discard recorded in decisions-log.md
# on 2026-10-10.
PARSE_RC=0
"$PYTHON3_BIN" -I - "$RAW" "$PROJECT_DIR" >"$OUT" <<'PY' || PARSE_RC=$?
import json, sys, os
raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_map = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}
try:
    with open(raw) as fh: data = json.load(fh)
except Exception:
    sys.exit(3)
if not isinstance(data, dict) or not isinstance(data.get("results"), list):
    sys.exit(3)
if not isinstance(data.get("errors", []), list):
    sys.exit(3)
for i, r in enumerate(data["results"], 1):
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


# Baseline does not run ShellCheck, so it cannot transfer shell parse coverage
# to another scanner. Every Semgrep error makes this stage incomplete.
types = set()
for error in data.get("errors", []):
    kind = error.get("type") if isinstance(error, dict) else None
    if isinstance(kind, list) and kind:
        kind = kind[0]
    kind = " ".join(kind.split()) if isinstance(kind, str) else "unknown"
    types.add(kind[:64] or "unknown")
if types:
    print("semgrep did not complete: partial scan: JSON errors non-empty (" + ", ".join(sorted(types)) + ")", file=sys.stderr)
    sys.exit(4)
PY

if [ "$SCAN_RC" -ne 0 ]; then
  echo "semgrep did not complete: scanner exit $SCAN_RC" >&2
  exit 2
fi
case "$PARSE_RC" in
  0) ;;
  4) exit 2 ;;
  *) echo "semgrep did not complete: missing or malformed JSON" >&2; exit 2 ;;
esac
