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

# Inherited shell functions never answer for a tool: the same uninterceptable
# purge as run-diff.sh (POSIX mode finds `unset`/`set` before functions).
POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
for _sg_fn in $(builtin compgen -A function 2>/dev/null); do builtin unset -f "$_sg_fn"; done
builtin unset _sg_fn
# Nor does inherited startup code: no child shell reads BASH_ENV or ENV, and
# the scanner wrappers run privileged (`-p`), which ignores both anyway.
builtin unset BASH_ENV ENV

set -uo pipefail

case "$0" in */*) _sg_self_dir="${0%/*}" ;; *) _sg_self_dir=. ;; esac
SKILL_DIR="$(builtin cd "$_sg_self_dir/.." && builtin pwd)"
builtin source "$SKILL_DIR/scripts/lib/engine.sh"
sg_path_sanitize || exit 1

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
  builtin printf '%s\n' \
    'usage: run-redteam.sh <project-dir> <target-class> [--confirm] [--no-llm]' '' \
    'target-class ∈ data-exfil | priv-esc | account-takeover | tenant-break | model-jailbreak' '' \
    'Examples:' '  run-redteam.sh /path/to/project-a tenant-break --confirm' \
    '  run-redteam.sh /path/to/project-b account-takeover --confirm' >&2
  exit 64
fi

case "$TARGET_CLASS" in
  data-exfil|priv-esc|account-takeover|tenant-break|model-jailbreak) ;;
  *) echo "fail: unknown target-class '$TARGET_CLASS'" >&2; exit 64 ;;
esac

PROJECT_DIR="$(builtin cd "$PROJECT_DIR" && builtin pwd)" || exit 1
if ! sg_path_sanitize "$PROJECT_DIR" || ! sg_vet_helpers "$PROJECT_DIR" bash cat basename date ls sort tail mktemp rm mkdir; then
  echo "fail: unsafe red-team helper or project path" >&2
  exit 1
fi
SG_BASH="$(sg_checked_program "$BASH" "$PROJECT_DIR")" || { echo "fail: unsafe bash at $BASH" >&2; exit 1; }
builtin unset PYTHONPATH PYTHONHOME
# The scanned project is untrusted: python3 must not live inside it, and every
# parser runs isolated (-I), so a json.py or re.py in the cwd is never imported.
PYTHON3_BIN="$(sg_resolve_python "$PROJECT_DIR")" || {
  echo "fail: python3 is not installed, or it (or the interpreter its shim runs) resolves inside the scanned project or cannot be vouched for" >&2
  exit 1
}
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
# Chains are only as complete as the baseline under them. Red-team never
# gates, so it does not refuse an incomplete baseline; it says so everywhere
# its findings go: here, in the narrative header and in the reasoning input.
# lib/baseline_state.py is the schema check diff mode uses.
STATE="$("$PYTHON3_BIN" -I "$SKILL_DIR/scripts/lib/baseline_state.py" "$BASELINE" "${BASELINE##*/}" 2>/dev/null)"
STATE="${STATE%%$'\t'*}"
case "$STATE" in
  complete)     COMPLETENESS="complete" ;;
  unknown)      COMPLETENESS="unknown (pre-1.4.2 baseline)" ;;
  incomplete:*) COMPLETENESS="incomplete (${STATE#incomplete: })" ;;
  *)            COMPLETENESS="unknown (baseline does not parse)" ;;
esac
# The state is repository data spliced into JSON and Markdown below.
COMPLETENESS="${COMPLETENESS//[^A-Za-z0-9 ,().:\/_-]/?}"
echo "baseline completeness: ${COMPLETENESS:-unknown}"

# --- prepare LLM input ----------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Filter current and historical findings to kept-or-no-llm-pass (skip dropped
# dispositions) and emit JSONL for the prompt. History remains relevant to
# chained-exploit reasoning even though it is excluded from baseline gating.
INPUT="$WORK/input.jsonl"
{
  printf '{"_target_class":"%s","_project":"%s","_baseline_completeness":"%s"}\n' "$TARGET_CLASS" "$PROJECT_NAME" "${COMPLETENESS:-unknown}"
  "$PYTHON3_BIN" -I - "$BASELINE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh: doc = json.load(fh)
for bucket in ("findings", "historical_findings"):
    for f in doc.get(bucket, []):
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
  printf "%s\n" "- completeness: ${COMPLETENESS:-unknown}"
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
    "$PYTHON3_BIN" -I - "$BASELINE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh: doc = json.load(fh)
for bucket in ("findings", "historical_findings"):
    for f in doc.get(bucket, []):
        if f.get("triage") == "dropped": continue
        sev = f.get("severity","")
        print(f"- **{sev}** `{f.get('tool','')}/{f.get('rule','')}` @ `{f.get('file','')}:{f.get('line','')}` — {f.get('message','')}")
PY
  } >> "$OUT_MD"
  echo "wrote (no-llm): $OUT_MD"
  exit 0
fi

LLM_OUT="$WORK/redteam.md"
if ! "$SG_BASH" -p "$SKILL_DIR/scripts/lib/llm-call.sh" "$SKILL_DIR/prompts/redteam.md" "$INPUT" "$LLM_OUT" "$PROJECT_DIR"; then
  {
    printf "## LLM unavailable\n\n"
    printf "No LLM provider was usable for this run (\`scripts/lib/llm-call.sh\` returned non-zero). Falling back to a no-LLM listing — re-run with \`LLM_PROVIDER\` set + \`llm\` plugin installed for the chain composition.\n\n"
    printf "## Baseline findings (kept)\n\n"
    "$PYTHON3_BIN" -I - "$BASELINE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh: doc = json.load(fh)
for bucket in ("findings", "historical_findings"):
    for f in doc.get(bucket, []):
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
