#!/usr/bin/env bash
# Mode 1 — baseline scan.
# Runs Semgrep, OSV-scanner, Gitleaks; merges into a normalized JSONL stream;
# optionally pipes through the LLM triage prompt; writes <project>/audits/<date>-baseline-<project>.{md,json}.
#
# Usage: run-baseline.sh [<project-dir>] [--profile=<name>] [--no-llm]

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- arg parse -------------------------------------------------------------
PROJECT_DIR=""
PROFILE_OVERRIDE=""
NO_LLM=0
for arg in "$@"; do
  case "$arg" in
    --profile=*) PROFILE_OVERRIDE="${arg#--profile=}" ;;
    --no-llm)    NO_LLM=1 ;;
    --*)         echo "unknown flag: $arg" >&2; exit 64 ;;
    *)           PROJECT_DIR="$arg" ;;
  esac
done

# --- resolve project dir ---------------------------------------------------
if [ -z "$PROJECT_DIR" ]; then
  if [ -n "${CODEX_PROJECT_DIR:-}" ] && [ -d "$CODEX_PROJECT_DIR" ]; then
    PROJECT_DIR="$CODEX_PROJECT_DIR"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    PROJECT_DIR="$CLAUDE_PROJECT_DIR"
  else
    PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "fail: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# --- load project-local config --------------------------------------------
CFG_LOADED=0
for cfg in \
  "$PROJECT_DIR/.claude/skills/security-gate-local/local.config.sh" \
  "$PROJECT_DIR/.agents/skills/security-gate-local/local.config.sh"; do
  if [ -f "$cfg" ]; then
    # shellcheck source=/dev/null
    . "$cfg"
    CFG_LOADED=1
  fi
done

PROFILE="${PROFILE_OVERRIDE:-${SECURITY_GATE_STACK_PROFILE:-web-next}}"
AUDIT_DIR_REL="${SECURITY_GATE_AUDIT_DIR:-audits}"
AUDIT_DIR="$PROJECT_DIR/$AUDIT_DIR_REL"
DATE_TAG="$(date +%Y-%m-%d)"
TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$AUDIT_DIR"
OUT_MD="$AUDIT_DIR/${DATE_TAG}-baseline-${PROJECT_NAME}.md"
OUT_JSON="$AUDIT_DIR/${DATE_TAG}-baseline-${PROJECT_NAME}.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SEMGREP_OUT="$WORK/semgrep.jsonl"
OSV_OUT="$WORK/osv.jsonl"
GITLEAKS_RAW_OUT="$WORK/gitleaks-all.jsonl"
GITLEAKS_OUT="$WORK/gitleaks-current.jsonl"
HISTORICAL_OUT="$WORK/gitleaks-history.jsonl"
GARAK_OUT="$WORK/garak.jsonl"
MERGED="$WORK/merged.jsonl"
TRIAGE_INPUT="$WORK/triage-input.jsonl"
TRIAGE_OUT="$WORK/triage.jsonl"
PREVIOUS_BASELINE=""

# Preserve the newest baseline before today's deterministic output path is
# replaced. Historical dispositions are carried forward by fingerprint.
if [ -d "$AUDIT_DIR" ]; then
  LATEST_BASELINE="$(ls -1 "$AUDIT_DIR"/*-baseline-"$PROJECT_NAME".json 2>/dev/null | sort | tail -1)"
  if [ -n "$LATEST_BASELINE" ] && [ -f "$LATEST_BASELINE" ]; then
    PREVIOUS_BASELINE="$WORK/previous-baseline.json"
    cp "$LATEST_BASELINE" "$PREVIOUS_BASELINE"
  fi
fi

echo ">> security-gate baseline"
echo "   project:   $PROJECT_NAME"
echo "   path:      $PROJECT_DIR"
echo "   profile:   $PROFILE"
echo "   audit dir: $AUDIT_DIR_REL"
echo "   config:    $([ "$CFG_LOADED" = 1 ] && echo loaded || echo defaults)"
echo

# --- scanners -------------------------------------------------------------
SEMGREP_RC=0; OSV_RC=0; GITLEAKS_RC=0; GARAK_RC=0; GARAK_USED=0
TOTAL_STAGES=3
[ "$PROFILE" = "web-rag-llm" ] && TOTAL_STAGES=4
echo "[1/$TOTAL_STAGES] Semgrep…";  bash "$SKILL_DIR/scripts/lib/semgrep.sh"  "$PROJECT_DIR" "$PROFILE" "$SEMGREP_OUT"  || SEMGREP_RC=$?
echo "[2/$TOTAL_STAGES] OSV…";      bash "$SKILL_DIR/scripts/lib/osv.sh"      "$PROJECT_DIR" "$OSV_OUT"               || OSV_RC=$?
echo "[3/$TOTAL_STAGES] Gitleaks…"; bash "$SKILL_DIR/scripts/lib/gitleaks.sh" "$PROJECT_DIR" "$GITLEAKS_RAW_OUT"      || GITLEAKS_RC=$?
:> "$GARAK_OUT"
if [ "$PROFILE" = "web-rag-llm" ]; then
  GARAK_USED=1
  echo "[4/4] Garak (LLM probes)…"
  bash "$SKILL_DIR/scripts/lib/garak.sh" "$PROJECT_DIR" "$GARAK_OUT" || GARAK_RC=$?
fi

# Keep history out of the gating scanner stream. The JSONL bucket marker is
# the boundary used by the standalone scanner proof and by this aggregator.
python3 - "$GITLEAKS_RAW_OUT" "$GITLEAKS_OUT" "$HISTORICAL_OUT" <<'PY'
import json, sys
source, current_path, history_path = sys.argv[1:]
with open(current_path, "w") as current, open(history_path, "w") as history:
    try:
        lines = open(source)
    except OSError:
        lines = []
    for line in lines:
        try:
            finding = json.loads(line)
        except json.JSONDecodeError:
            continue
        target = history if finding.get("bucket") == "historical_findings" else current
        target.write(json.dumps(finding, ensure_ascii=False) + "\n")
PY

cat "$SEMGREP_OUT" "$OSV_OUT" "$GITLEAKS_OUT" "$GARAK_OUT" 2>/dev/null > "$MERGED" || true
RAW_COUNT="$(wc -l < "$MERGED" | tr -d ' ')"
HISTORICAL_COUNT="$(wc -l < "$HISTORICAL_OUT" | tr -d ' ')"
echo
if [ "$GARAK_USED" = "1" ]; then
  echo "raw findings: $RAW_COUNT (semgrep rc=$SEMGREP_RC, osv rc=$OSV_RC, gitleaks rc=$GITLEAKS_RC, garak rc=$GARAK_RC)"
else
  echo "raw findings: $RAW_COUNT (semgrep rc=$SEMGREP_RC, osv rc=$OSV_RC, gitleaks rc=$GITLEAKS_RC)"
fi
echo "historical findings: $HISTORICAL_COUNT (separate, non-gating; severity retained)"

# --- triage ---------------------------------------------------------------
TRIAGE_USED=0
LLM_PROVIDER_USED="none"
LLM_MODEL_USED=""

# Previously triaged historical findings retain their disposition and never
# re-enter LLM triage. Current-tree findings always follow the existing flow.
python3 - "$MERGED" "$HISTORICAL_OUT" "$PREVIOUS_BASELINE" > "$TRIAGE_INPUT" <<'PY'
import json, os, sys
current_path, history_path, previous_path = sys.argv[1:]

persisted = set()
if previous_path and os.path.exists(previous_path):
    try:
        with open(previous_path) as fh:
            previous = json.load(fh)
        persisted = {
            f.get("fingerprint")
            for f in previous.get("historical_findings", [])
            if f.get("fingerprint") and f.get("triage") in ("kept", "dropped")
        }
    except Exception:
        persisted = set()

for path, historical in ((current_path, False), (history_path, True)):
    try:
        lines = open(path)
    except OSError:
        continue
    for line in lines:
        try:
            finding = json.loads(line)
        except json.JSONDecodeError:
            continue
        if historical and finding.get("fingerprint") in persisted:
            continue
        print(json.dumps(finding, ensure_ascii=False))
PY
TRIAGE_COUNT="$(wc -l < "$TRIAGE_INPUT" | tr -d ' ')"

if [ "$NO_LLM" -eq 1 ] || [ "$TRIAGE_COUNT" -eq 0 ]; then
  : > "$TRIAGE_OUT"
else
  if bash "$SKILL_DIR/scripts/lib/llm-call.sh" "$SKILL_DIR/prompts/triage.md" "$TRIAGE_INPUT" "$TRIAGE_OUT"; then
    TRIAGE_USED=1
    LLM_PROVIDER_USED="${LLM_PROVIDER:-anthropic}"
    LLM_MODEL_USED="${LLM_MODEL:-claude-opus-4-7}"
    echo "triage: completed via $LLM_PROVIDER_USED ($LLM_MODEL_USED)"
  else
    echo "triage: skipped (no provider available); writing raw findings"
    : > "$TRIAGE_OUT"
  fi
fi

# --- merge findings + decisions, write JSON + Markdown --------------------
SEMGREP_VER="$(semgrep --version 2>/dev/null | tail -1)"
OSV_VER="$(osv-scanner --version 2>/dev/null | head -1 | awk '{print $NF}')"
GITLEAKS_VER="$(gitleaks version 2>/dev/null | head -1)"

python3 - "$MERGED" "$HISTORICAL_OUT" "$TRIAGE_OUT" "$PREVIOUS_BASELINE" "$OUT_JSON" "$OUT_MD" \
  "$PROJECT_NAME" "$PROFILE" "$TS_ISO" \
  "${SEMGREP_VER:-unknown}" "${OSV_VER:-unknown}" "${GITLEAKS_VER:-unknown}" \
  "$LLM_PROVIDER_USED" "$LLM_MODEL_USED" "$TRIAGE_USED" <<'PY'
import json, sys, os
merged_p, historical_p, triage_p, previous_p, json_p, md_p = sys.argv[1:7]
project, profile, ts = sys.argv[7:10]
sg_ver, osv_ver, gl_ver = sys.argv[10:13]
llm_provider, llm_model, triage_used = sys.argv[13], sys.argv[14], sys.argv[15] == "1"

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

raw = load_jsonl(merged_p)
historical_raw = load_jsonl(historical_p)
decisions = {d["id"]: d for d in load_jsonl(triage_p) if "id" in d}

persisted_historical = {}
if previous_p and os.path.exists(previous_p):
    try:
        with open(previous_p) as fh:
            previous = json.load(fh)
        persisted_historical = {
            f["fingerprint"]: f
            for f in previous.get("historical_findings", [])
            if f.get("fingerprint") and f.get("triage") in ("kept", "dropped")
        }
    except Exception:
        persisted_historical = {}

findings = []
for r in raw:
    fid = r["id"]
    d = decisions.get(fid)
    if d:
        triage = d.get("decision", "kept")
        reason = d.get("reason", "")
        exploit = d.get("exploit_steps", "")
        fix = d.get("suggested_fix", "")
        sev = d.get("severity_override") or r.get("severity", "low")
    elif triage_used:
        triage = "dropped"
        reason = "no decision returned by triage"
        exploit, fix, sev = "", "", r.get("severity", "low")
    else:
        triage = "no-llm-pass"
        reason = "triage skipped"
        exploit, fix, sev = "", "", r.get("severity", "low")
    findings.append({
        "id": fid,
        "tool": r.get("tool", ""),
        "rule": r.get("rule", ""),
        "severity": sev,
        "file": r.get("file", ""),
        "line": r.get("line", 0),
        "message": r.get("message", ""),
        **({"fingerprint": r["fingerprint"]} if r.get("fingerprint") else {}),
        "triage": triage,
        "triage_reason": reason,
        "exploit_steps": exploit,
        "suggested_fix": fix,
    })

historical_findings = []
for r in historical_raw:
    fid = r["id"]
    fingerprint = r.get("fingerprint", "")
    prior = persisted_historical.get(fingerprint)
    d = decisions.get(fid)
    if prior:
        triage = prior.get("triage", "kept")
        reason = prior.get("triage_reason", "")
        exploit = prior.get("exploit_steps", "")
        fix = prior.get("suggested_fix", "")
    elif d:
        triage = d.get("decision", "kept")
        reason = d.get("reason", "")
        exploit = d.get("exploit_steps", "")
        fix = d.get("suggested_fix", "")
    else:
        triage = "no-llm-pass"
        reason = "no triage decision returned" if triage_used else "triage skipped"
        exploit, fix = "", ""
    historical_findings.append({
        "id": fid,
        "tool": r.get("tool", ""),
        "rule": r.get("rule", ""),
        # Historical Gitleaks findings retain scanner severity. Triage may
        # disposition them, but may not silently downgrade them.
        "severity": r.get("severity", "high"),
        "file": r.get("file", ""),
        "line": r.get("line", 0),
        "message": r.get("message", ""),
        "fingerprint": fingerprint,
        "triage": triage,
        "triage_reason": reason,
        "exploit_steps": exploit,
        "suggested_fix": fix,
    })

kept = [f for f in findings if f["triage"] in ("kept", "no-llm-pass")]
sev_count = {"critical": 0, "high": 0, "medium": 0, "low": 0}
for f in kept:
    sev_count[f.get("severity", "low")] = sev_count.get(f.get("severity", "low"), 0) + 1

historical_kept = [f for f in historical_findings if f["triage"] in ("kept", "no-llm-pass")]
historical_sev_count = {"critical": 0, "high": 0, "medium": 0, "low": 0}
for f in historical_kept:
    severity = f.get("severity", "high")
    historical_sev_count[severity] = historical_sev_count.get(severity, 0) + 1

doc = {
    "schema": "security-gate.baseline.v2",
    "project": project,
    "profile": profile,
    "generated_at": ts,
    "tools": {"semgrep": sg_ver, "osv-scanner": osv_ver, "gitleaks": gl_ver},
    "llm": {"provider": llm_provider, "model": llm_model, "triage_used": triage_used},
    "findings": findings,
    "historical_findings": historical_findings,
    "summary": {
        "total_raw": len(raw),
        "kept": len([f for f in findings if f["triage"] == "kept"]),
        "dropped": len([f for f in findings if f["triage"] == "dropped"]),
        "no_llm_pass": len([f for f in findings if f["triage"] == "no-llm-pass"]),
        "by_severity": sev_count,
        "historical": {
            "total_raw": len(historical_raw),
            "kept": len([f for f in historical_findings if f["triage"] == "kept"]),
            "dropped": len([f for f in historical_findings if f["triage"] == "dropped"]),
            "no_llm_pass": len([f for f in historical_findings if f["triage"] == "no-llm-pass"]),
            "by_severity": historical_sev_count,
        },
    },
}
with open(json_p, "w") as fh: json.dump(doc, fh, indent=2)

# --- markdown narrative ---
sev_order = {"critical": 0, "high": 1, "medium": 2, "low": 3}
kept_sorted = sorted(kept, key=lambda f: (sev_order.get(f.get("severity", "low"), 9), f.get("tool", ""), f.get("rule", "")))

def line(s=""): out_lines.append(s)
out_lines = []
line(f"# security-gate baseline — {project}")
line()
line(f"- generated: `{ts}`")
line(f"- profile:   `{profile}`")
line(f"- tools:     semgrep `{sg_ver}` · osv-scanner `{osv_ver}` · gitleaks `{gl_ver}`")
line(f"- triage:    " + (f"`{llm_provider}` ({llm_model})" if triage_used else "skipped (no LLM)"))
line()
line("## Summary")
line()
line(f"- current-tree raw findings (gating): **{doc['summary']['total_raw']}**")
line(f"- kept after triage: **{doc['summary']['kept']}**")
line(f"- dropped (FP): **{doc['summary']['dropped']}**")
if not triage_used:
    line(f"- no-llm-pass: **{doc['summary']['no_llm_pass']}** (raw scanner output, not triaged)")
line(f"- historical findings (separate, non-gating): **{doc['summary']['historical']['total_raw']}**")
line(f"- historical dispositions: kept **{doc['summary']['historical']['kept']}** · dropped **{doc['summary']['historical']['dropped']}** · untriaged **{doc['summary']['historical']['no_llm_pass']}**")
line()
line(f"- severity (kept + no-llm-pass): " + " · ".join(f"**{k}**: {v}" for k, v in sev_count.items()))
line(f"- historical severity (kept + no-llm-pass): " + " · ".join(f"**{k}**: {v}" for k, v in historical_sev_count.items()))
line()
if doc['summary']['total_raw'] == 0:
    line("Verdict: **clean current tree** — no gating findings produced by any scanner.")
elif doc['summary']['kept'] == 0 and triage_used:
    fp_rate = doc['summary']['dropped'] / max(doc['summary']['total_raw'], 1)
    line(f"Verdict: **clean (after triage)** — all {doc['summary']['total_raw']} raw findings dropped as false positives. FP rate: {fp_rate:.0%}.")
elif triage_used:
    fp_rate = doc['summary']['dropped'] / max(doc['summary']['total_raw'], 1)
    line(f"Verdict: **{doc['summary']['kept']} kept findings**. FP rate observed: {fp_rate:.0%}.")
else:
    line(f"Verdict: **{doc['summary']['no_llm_pass']} raw findings** (no LLM triage performed).")
line()
line("## Findings")
line()
if not kept_sorted:
    line("_No retained findings._")
else:
    for f in kept_sorted:
        line(f"### `{f['id']}` — {f['severity']} — {f['tool']}/{f['rule']}")
        line()
        loc = f["file"] or "(no path)"
        if f.get("line"): loc += f":{f['line']}"
        line(f"- location: `{loc}`")
        line(f"- message: {f['message']}")
        if f.get("exploit_steps"):
            line(f"- exploit step: {f['exploit_steps']}")
        if f.get("suggested_fix"):
            line(f"- suggested fix: {f['suggested_fix']}")
        if f.get("triage_reason"):
            line(f"- triage: {f['triage']} — {f['triage_reason']}")
        line()

line("## Historical findings (separate, non-gating)")
line()
line("Historical credentials retain scanner severity. Their disposition is persisted by Gitleaks fingerprint; they remain visible but do not change the current-tree baseline verdict.")
line()
if not historical_findings:
    line("_No history-only findings._")
else:
    historical_sorted = sorted(
        historical_findings,
        key=lambda f: (sev_order.get(f.get("severity", "high"), 9), f.get("file", ""), f.get("line", 0)),
    )
    for f in historical_sorted:
        line(f"### `{f['id']}` — {f['severity']} — {f['tool']}/{f['rule']}")
        line()
        loc = f["file"] or "(no path)"
        if f.get("line"): loc += f":{f['line']}"
        line(f"- location: `{loc}`")
        line(f"- fingerprint: `{f['fingerprint']}`")
        line(f"- message: {f['message']}")
        line(f"- disposition: {f['triage']}" + (f" — {f['triage_reason']}" if f.get("triage_reason") else ""))
        if f.get("exploit_steps"):
            line(f"- exploit step: {f['exploit_steps']}")
        if f.get("suggested_fix"):
            line(f"- suggested fix: {f['suggested_fix']}")
        line()

if triage_used:
    dropped = [f for f in findings if f["triage"] == "dropped"]
    if dropped:
        line("## Dropped (FP) findings")
        line()
        line(f"_{len(dropped)} findings dropped during triage — listed for traceability._")
        line()
        for f in dropped:
            loc = f["file"] or "(no path)"
            if f.get("line"): loc += f":{f['line']}"
            line(f"- `{f['id']}` `{f['tool']}/{f['rule']}` @ `{loc}` — {f['triage_reason']}")
        line()

with open(md_p, "w") as fh: fh.write("\n".join(out_lines) + "\n")
PY

echo
echo "wrote: $OUT_MD"
echo "wrote: $OUT_JSON"
exit 0
