#!/usr/bin/env bash
# Mode 3 — red-team. Static chained-exploit reasoning over the latest
# baseline. Composes the baseline's individual findings into kill chains
# targeting a named class. Output is sensitive (lists working attack
# steps) — per-run sign-off is required.
#
# Usage: run-redteam.sh <project-dir> <target-class> [--confirm] [--no-llm]
#
# target-class ∈ data-exfil | priv-esc | account-takeover | tenant-break | model-jailbreak
#
# Output: <project>/audits/<YYYY-MM-DD>-redteam-<project>-<target-class>.md

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PROJECT_DIR="${1:-}"
TARGET_CLASS="${2:-}"
shift $(( $# > 1 ? 2 : $# ))

CONFIRM=0
NO_LLM=0
for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=1 ;;
    --no-llm)  NO_LLM=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

if [ -z "$PROJECT_DIR" ] || [ -z "$TARGET_CLASS" ]; then
  cat >&2 <<EOF
usage: run-redteam.sh <project-dir> <target-class> [--confirm] [--no-llm]

target-class ∈ data-exfil | priv-esc | account-takeover | tenant-break | model-jailbreak

Examples:
  run-redteam.sh /personal/vericite tenant-break --confirm
  run-redteam.sh /personal/lume     account-takeover --confirm
EOF
  exit 64
fi

case "$TARGET_CLASS" in
  data-exfil|priv-esc|account-takeover|tenant-break|model-jailbreak) ;;
  *) echo "fail: unknown target-class '$TARGET_CLASS'" >&2; exit 64 ;;
esac

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
AUDIT_DIR="$PROJECT_DIR/${SECURITY_GATE_AUDIT_DIR:-audits}"
DATE_TAG="$(date +%Y-%m-%d)"
OUT_MD="$AUDIT_DIR/${DATE_TAG}-redteam-${PROJECT_NAME}-${TARGET_CLASS}.md"

# --- per-run sign-off -----------------------------------------------------
cat <<EOF
================================================================
security-gate red-team — Mode 3 (chained-exploit reasoning)

Project:       $PROJECT_NAME
Target class:  $TARGET_CLASS
Output:        $OUT_MD

This run will:
  - Read the latest baseline JSON for $PROJECT_NAME.
  - Ask an LLM to compose individual findings into kill chains
    targeting "$TARGET_CLASS".
  - Write a narrative containing concrete attacker steps,
    reproduction inputs, and remediation diffs.

The output IS SENSITIVE. Treat it like a CVE pre-disclosure:
  - Do not paste into chat tools.
  - Do not commit to a public branch — keep under audits/ which is
    git-ignored / redacted in template sync.
  - Share with humans on a need-to-know basis.

If you weren't expecting this output to be generated, abort.
================================================================
EOF

if [ "$CONFIRM" -ne 1 ] && [ -t 0 ]; then
  printf "Type 'yes' to proceed: "
  read -r answer
  if [ "$answer" != "yes" ]; then
    echo "aborted." >&2
    exit 1
  fi
elif [ "$CONFIRM" -ne 1 ]; then
  echo "fail: stdin is not a TTY and --confirm was not passed. Pass --confirm to acknowledge sign-off." >&2
  exit 1
fi

# --- find baseline --------------------------------------------------------
BASELINE="$(ls -1 "$AUDIT_DIR"/*-baseline-"$PROJECT_NAME".json 2>/dev/null | sort | tail -1)"
if [ -z "$BASELINE" ] || [ ! -f "$BASELINE" ]; then
  echo "fail: no baseline JSON for '$PROJECT_NAME' under $AUDIT_DIR — run run-baseline.sh first" >&2
  exit 1
fi
echo "baseline: $(basename "$BASELINE")"

# --- prepare LLM input ----------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Filter findings to kept-or-no-llm-pass (skip dropped FPs) and emit JSONL
# for the prompt. Append target-class context as a sentinel header line.
INPUT="$WORK/input.jsonl"
{
  printf '{"_target_class":"%s","_project":"%s"}\n' "$TARGET_CLASS" "$PROJECT_NAME"
  python3 - "$BASELINE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh: doc = json.load(fh)
for f in doc.get("findings", []):
    if f.get("triage") == "dropped": continue
    out = {k: f.get(k) for k in ("id","tool","rule","severity","file","line","message","exploit_steps","suggested_fix")}
    print(json.dumps(out, ensure_ascii=False))
PY
} > "$INPUT"

mkdir -p "$AUDIT_DIR"

# --- header ---------------------------------------------------------------
{
  printf "# Red-team narrative — %s — %s\n\n" "$PROJECT_NAME" "$TARGET_CLASS"
  printf "%s\n" "- generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
  printf "%s\n" "- baseline:  \`$(basename "$BASELINE")\`"
  printf "%s\n" "- mode:      Mode 3 (chained-exploit reasoning, static)"
  printf "%s\n\n" "- scope:     local/dev only — no live DAST, no production traffic"
  printf "## Sign-off\n\n"
  printf "Run authorized by interactive operator at %s. Output is sensitive.\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT_MD"

if [ "$NO_LLM" -eq 1 ]; then
  {
    printf "## No-LLM mode\n\n"
    printf "Run invoked with \`--no-llm\` — no kill-chain composition performed. The baseline findings are listed below for manual analysis.\n\n"
    printf "## Baseline findings (kept)\n\n"
    python3 - "$BASELINE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh: doc = json.load(fh)
for f in doc.get("findings", []):
    if f.get("triage") == "dropped": continue
    sev = f.get("severity","")
    print(f"- **{sev}** `{f.get('tool','')}/{f.get('rule','')}` @ `{f.get('file','')}:{f.get('line','')}` — {f.get('message','')}")
PY
  } >> "$OUT_MD"
  echo "wrote (no-llm): $OUT_MD"
  exit 0
fi

LLM_OUT="$WORK/redteam.md"
if ! bash "$SKILL_DIR/scripts/lib/llm-call.sh" "$SKILL_DIR/prompts/redteam.md" "$INPUT" "$LLM_OUT"; then
  {
    printf "## LLM unavailable\n\n"
    printf "No LLM provider was usable for this run (\`scripts/lib/llm-call.sh\` returned non-zero). Falling back to a no-LLM listing — re-run with \`LLM_PROVIDER\` set + \`llm\` plugin installed for the chain composition.\n\n"
    printf "## Baseline findings (kept)\n\n"
    python3 - "$BASELINE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh: doc = json.load(fh)
for f in doc.get("findings", []):
    if f.get("triage") == "dropped": continue
    sev = f.get("severity","")
    print(f"- **{sev}** `{f.get('tool','')}/{f.get('rule','')}` @ `{f.get('file','')}:{f.get('line','')}` — {f.get('message','')}")
PY
  } >> "$OUT_MD"
  echo "wrote (no-llm fallback): $OUT_MD"
  exit 2
fi

cat "$LLM_OUT" >> "$OUT_MD"
echo "wrote: $OUT_MD"
exit 0
