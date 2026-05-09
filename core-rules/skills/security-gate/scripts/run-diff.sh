#!/usr/bin/env bash
# Mode 2 — diff scan against the latest baseline.
# Scoped to files changed in the push range. Findings already known to the
# baseline JSON are skipped. Emits a verdict block in the same shape as
# process-gate. Exit codes:
#   0  MERGEABLE          — no new Critical/High findings
#   2  NEEDS CHANGES      — only new Medium/Low findings
#   1  BLOCKED            — at least one new Critical/High finding
#
# Usage: run-diff.sh [<project-dir>] [--range=<gitspec>] [--no-llm]
#                    [--baseline=<path-to-json>]
#
# Husky pre-push wiring (added to core-rules/husky/pre-push) passes the
# computed range derived from the stdin refs.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- arg parse -------------------------------------------------------------
PROJECT_DIR=""
RANGE=""
BASELINE=""
# NO_LLM is set by --no-llm; consumption pending — flag accepted for CLI parity
# with run-baseline.sh / run-redteam.sh.
# shellcheck disable=SC2034
NO_LLM=0
# shellcheck disable=SC2034
for arg in "$@"; do
  case "$arg" in
    --range=*)    RANGE="${arg#--range=}" ;;
    --baseline=*) BASELINE="${arg#--baseline=}" ;;
    --no-llm)     NO_LLM=1 ;;
    --*)          echo "unknown flag: $arg" >&2; exit 64 ;;
    *)            PROJECT_DIR="$arg" ;;
  esac
done

# --- resolve project dir --------------------------------------------------
if [ -z "$PROJECT_DIR" ]; then
  if [ -n "${CODEX_PROJECT_DIR:-}" ] && [ -d "$CODEX_PROJECT_DIR" ]; then
    PROJECT_DIR="$CODEX_PROJECT_DIR"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    PROJECT_DIR="$CLAUDE_PROJECT_DIR"
  else
    PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# --- load project-local config --------------------------------------------
for cfg in \
  "$PROJECT_DIR/.claude/skills/security-gate-local/local.config.sh" \
  "$PROJECT_DIR/.agents/skills/security-gate-local/local.config.sh"; do
  if [ -f "$cfg" ]; then
    # shellcheck source=/dev/null
    . "$cfg"
  fi
done

PROFILE="${SECURITY_GATE_STACK_PROFILE:-web-next}"
AUDIT_DIR_REL="${SECURITY_GATE_AUDIT_DIR:-audits}"
AUDIT_DIR="$PROJECT_DIR/$AUDIT_DIR_REL"

# --- range default --------------------------------------------------------
if [ -z "$RANGE" ]; then
  if git -C "$PROJECT_DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
    RANGE="origin/main..HEAD"
  elif git -C "$PROJECT_DIR" rev-parse --verify main >/dev/null 2>&1; then
    RANGE="main..HEAD"
  elif git -C "$PROJECT_DIR" rev-parse --verify master >/dev/null 2>&1; then
    RANGE="master..HEAD"
  else
    RANGE="HEAD~1..HEAD"
  fi
fi

# --- find baseline --------------------------------------------------------
if [ -z "$BASELINE" ]; then
  if [ -d "$AUDIT_DIR" ]; then
    BASELINE="$(ls -1 "$AUDIT_DIR"/*-baseline-"$PROJECT_NAME".json 2>/dev/null | sort | tail -1)"
  fi
fi

print_verdict() {
  local sast="$1" deps="$2" secrets="$3" overall="$4"
  printf "## security-gate verdict (diff)\n\n"
  printf "%-18s %s\n" "SAST:"            "$sast"
  printf "%-18s %s\n" "Deps:"            "$deps"
  printf "%-18s %s\n" "Secrets:"         "$secrets"
  printf "%-18s ➖ n/a\n" "Stack-specific:"
  printf "\nOverall: %s\n\n" "$overall"
}

if [ -z "$BASELINE" ] || [ ! -f "$BASELINE" ]; then
  echo "## security-gate verdict (diff)" >&2
  echo "" >&2
  echo "warn: no baseline JSON found for project '$PROJECT_NAME' under $AUDIT_DIR" >&2
  echo "" >&2
  echo "Run baseline first:" >&2
  echo "  bash $SKILL_DIR/scripts/run-baseline.sh $PROJECT_DIR" >&2
  echo "" >&2
  echo "Diff scan skipped — push allowed (NEEDS CHANGES, justify in PR)." >&2
  print_verdict "⚠️  warn" "⚠️  warn" "⚠️  warn" "NEEDS CHANGES"
  exit 2
fi

# --- changed files in range -----------------------------------------------
CHANGED="$(git -C "$PROJECT_DIR" diff --name-only --diff-filter=ACMR "$RANGE" 2>/dev/null || true)"
if [ -z "$CHANGED" ]; then
  print_verdict "✅ pass" "✅ pass" "✅ pass" "MERGEABLE"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Materialize changed-files list relative to project root.
CHANGED_LIST="$WORK/changed.txt"
printf "%s\n" "$CHANGED" > "$CHANGED_LIST"

# --- scoped scans ---------------------------------------------------------
SEMGREP_OUT="$WORK/semgrep.jsonl"
OSV_OUT="$WORK/osv.jsonl"
GITLEAKS_OUT="$WORK/gitleaks.jsonl"

# Semgrep — scoped to changed files (filter to existing files; skip deletions).
:>"$SEMGREP_OUT"
SCOPE_FILES=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.rb|*.php) ;;
    *) continue ;;
  esac
  [ -f "$PROJECT_DIR/$f" ] && SCOPE_FILES+=("$PROJECT_DIR/$f")
done < "$CHANGED_LIST"

if [ "${#SCOPE_FILES[@]}" -gt 0 ] && command -v semgrep >/dev/null 2>&1; then
  case "$PROFILE" in
    web-next)   CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript --config=p/nextjs --config=p/react) ;;
    web-static) CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript) ;;
    *)          CONFIGS=(--config=p/owasp-top-ten) ;;
  esac
  RAW="$WORK/semgrep.raw.json"
  semgrep scan --json --metrics=off --quiet "${CONFIGS[@]}" "${SCOPE_FILES[@]}" >"$RAW" 2>/dev/null || true
  python3 - "$RAW" "$PROJECT_DIR" >"$SEMGREP_OUT" <<'PY'
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
    print(json.dumps({
        "id": f"semgrep-diff-{i:04d}",
        "tool": "semgrep",
        "rule": r.get("check_id", "unknown"),
        "severity": sev,
        "file": path,
        "line": (r.get("start") or {}).get("line", 0),
        "message": (r.get("extra", {}).get("message") or "").splitlines()[0][:280],
    }, ensure_ascii=False))
PY
fi

# OSV — only if a manifest changed (deps changed).
:>"$OSV_OUT"
DEPS_CHANGED=0
while IFS= read -r f; do
  case "$f" in
    *pnpm-lock.yaml|*package-lock.json|*yarn.lock|*Cargo.lock|*go.sum|*poetry.lock|*Pipfile.lock|*Gemfile.lock|*requirements*.txt|*package.json|*Cargo.toml|*go.mod|*pyproject.toml)
      DEPS_CHANGED=1
      ;;
  esac
done < "$CHANGED_LIST"
if [ "$DEPS_CHANGED" = "1" ]; then
  bash "$SKILL_DIR/scripts/lib/osv.sh" "$PROJECT_DIR" "$OSV_OUT" || true
fi

# Gitleaks — scoped to the diff range via --log-opts.
:>"$GITLEAKS_OUT"
if command -v gitleaks >/dev/null 2>&1; then
  RAW="$WORK/gitleaks.raw.json"
  CONFIG_ARGS=()
  [ -f "$PROJECT_DIR/.gitleaks.toml" ] && CONFIG_ARGS=(--config "$PROJECT_DIR/.gitleaks.toml")
  gitleaks detect \
    --source "$PROJECT_DIR" \
    --log-opts="$RANGE" \
    --report-format json \
    --report-path "$RAW" \
    --redact \
    --no-banner \
    "${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}" \
    >/dev/null 2>&1 || true
  if [ -s "$RAW" ]; then
    python3 - "$RAW" >"$GITLEAKS_OUT" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    with open(raw) as fh: data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, list): sys.exit(0)
for i, leak in enumerate(data, 1):
    commit = (leak.get("Commit") or "")[:8]
    rule = leak.get("RuleID") or "unknown"
    desc = leak.get("Description") or rule
    print(json.dumps({
        "id": f"gitleaks-diff-{i:04d}",
        "tool": "gitleaks",
        "rule": rule,
        "severity": "high",
        "file": leak.get("File") or "",
        "line": leak.get("StartLine") or 0,
        "message": f"{desc} (commit={commit})" if commit else desc,
    }, ensure_ascii=False))
PY
  fi
fi

# --- dedupe vs baseline ---------------------------------------------------
NEW_FINDINGS="$WORK/new.jsonl"
python3 - "$BASELINE" "$SEMGREP_OUT" "$OSV_OUT" "$GITLEAKS_OUT" >"$NEW_FINDINGS" <<'PY'
import json, sys, os
baseline_p, *parts = sys.argv[1:]
def load_jsonl(p):
    out = []
    if not os.path.exists(p): return out
    with open(p) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln: continue
            try: out.append(json.loads(ln))
            except json.JSONDecodeError: continue
    return out
known = set()
try:
    with open(baseline_p) as fh: doc = json.load(fh)
    for f in doc.get("findings", []):
        if f.get("triage") == "dropped": continue
        known.add((f.get("tool",""), f.get("rule",""), f.get("file",""), f.get("line", 0)))
except Exception:
    pass
for p in parts:
    for f in load_jsonl(p):
        key = (f.get("tool",""), f.get("rule",""), f.get("file",""), f.get("line", 0))
        if key in known: continue
        print(json.dumps(f, ensure_ascii=False))
PY

# --- verdict --------------------------------------------------------------
SAST_NEW=0; DEPS_NEW=0; SECRETS_NEW=0
SAST_WORST="pass"; DEPS_WORST="pass"; SECRETS_WORST="pass"
HIGH_OR_CRIT=0
LOW_MED=0
declare -a NEW_LINES=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  NEW_LINES+=("$line")
  tool="$(printf "%s" "$line" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("tool",""))')"
  sev="$(printf "%s" "$line"  | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("severity",""))')"
  case "$sev" in
    critical|high) HIGH_OR_CRIT=$((HIGH_OR_CRIT+1)); WORST="fail" ;;
    medium|low)    LOW_MED=$((LOW_MED+1));            WORST="warn" ;;
    *)             WORST="warn" ;;
  esac
  case "$tool" in
    semgrep)  SAST_NEW=$((SAST_NEW+1));    [ "$WORST" = "fail" ] && SAST_WORST="fail";    [ "$WORST" = "warn" ] && [ "$SAST_WORST" = "pass" ] && SAST_WORST="warn" ;;
    osv)      DEPS_NEW=$((DEPS_NEW+1));    [ "$WORST" = "fail" ] && DEPS_WORST="fail";    [ "$WORST" = "warn" ] && [ "$DEPS_WORST" = "pass" ] && DEPS_WORST="warn" ;;
    gitleaks) SECRETS_NEW=$((SECRETS_NEW+1)); SECRETS_WORST="fail" ;;
  esac
done < "$NEW_FINDINGS"

glyph() {
  case "$1" in
    pass) printf "✅ pass" ;;
    warn) printf "⚠️  warn" ;;
    fail) printf "❌ fail" ;;
  esac
}

OVERALL="MERGEABLE"
[ "$SAST_WORST" = "warn" ] || [ "$DEPS_WORST" = "warn" ] || [ "$SECRETS_WORST" = "warn" ] && OVERALL="NEEDS CHANGES"
[ "$SAST_WORST" = "fail" ] || [ "$DEPS_WORST" = "fail" ] || [ "$SECRETS_WORST" = "fail" ] && OVERALL="BLOCKED"

print_verdict "$(glyph "$SAST_WORST")" "$(glyph "$DEPS_WORST")" "$(glyph "$SECRETS_WORST")" "$OVERALL"

if [ "${#NEW_LINES[@]}" -gt 0 ]; then
  printf "## New findings vs baseline\n\n"
  printf "_Baseline: \`%s\`_\n\n" "$(basename "$BASELINE")"
  printf "_Range:    \`%s\`_\n\n" "$RANGE"
  for ln in "${NEW_LINES[@]}"; do
    printf "%s\n" "$ln" | python3 -c '
import json, sys
f = json.loads(sys.stdin.read())
loc = f.get("file","(no path)")
if f.get("line"): loc += f":{f[\"line\"]}"
print(f"- **{f[\"severity\"]}** `{f[\"tool\"]}/{f[\"rule\"]}` @ `{loc}` — {f.get(\"message\",\"\")}")
'
  done
  printf "\n"
fi

case "$OVERALL" in
  MERGEABLE)        exit 0 ;;
  "NEEDS CHANGES")  exit 2 ;;
  BLOCKED)          exit 1 ;;
esac
