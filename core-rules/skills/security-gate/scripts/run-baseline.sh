#!/usr/bin/env bash
# Mode 1 — baseline scan.
# Runs Semgrep, OSV-scanner, Gitleaks; merges into a normalized JSONL stream;
# optionally pipes through the LLM triage prompt; writes <project>/audits/<date>-baseline-<project>.{md,json}.
#
# Usage: run-baseline.sh [<project-dir>] [--profile=<name>] [--no-llm]
#
# Exit 0: every engine completed, or its scanner proved there was nothing to
# scan (OSV exit 128 with no package sources: not applicable). Exit 2: the baseline was
# written but is incomplete, because an engine failed, was skipped, or left
# output that does not parse; it is never reported clean. Exit 1: aggregation failed, and no
# valid baseline was written.

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
# No relative PATH entry may be consulted even before the project is known.
sg_path_sanitize || exit 1

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
    PROJECT_DIR="$(sg_project_from_cwd)" || exit 1
  fi
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "fail: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

PROJECT_DIR="$(builtin cd "$PROJECT_DIR" && builtin pwd)"
# Capture the first selected scanners before dropping project PATH entries, so
# an unsafe candidate is recorded failed rather than silently substituted.
SG_SEMGREP_RC=0; SG_OSV_RC=0; SG_GITLEAKS_RC=0
SG_SEMGREP_BIN="$(sg_resolve_engine semgrep "$PROJECT_DIR")" || SG_SEMGREP_RC=$?
SG_OSV_BIN="$(sg_resolve_engine osv-scanner "$PROJECT_DIR")" || SG_OSV_RC=$?
SG_GITLEAKS_BIN="$(sg_resolve_engine gitleaks "$PROJECT_DIR")" || SG_GITLEAKS_RC=$?
if ! sg_path_sanitize "$PROJECT_DIR" || ! sg_vet_helpers "$PROJECT_DIR" \
    bash git basename date mkdir mktemp rm ls sort tail cp cat wc tr head awk; then
  echo "fail: unsafe baseline helper or project path" >&2
  exit 1
fi
SG_BASH="$(sg_checked_program "$BASH" "$PROJECT_DIR")" || { echo "fail: unsafe bash at $BASH" >&2; exit 1; }
builtin unset PYTHONPATH PYTHONHOME
# The scanned project is untrusted: python3 must not live inside it, and every
# parser here runs isolated (-I), so a json.py in the cwd is never imported.
PYTHON3_BIN="$(sg_resolve_python "$PROJECT_DIR")" || {
  echo "fail: python3 is not installed, or it (or the interpreter its shim runs) resolves inside the scanned project or cannot be vouched for" >&2
  exit 1
}
# The project key names the REPOSITORY, not the directory the run happened in.
# `basename $PROJECT_DIR` is the worktree name inside a linked worktree, so a
# worktree could never match its own repo's baseline and every diff scan there
# was skipped as "no baseline found". Derive from the common git dir instead,
# which is shared by every worktree of one repository.
PROJECT_NAME="$(basename "$PROJECT_DIR")"
if _sg_common="$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
   && [ -n "$_sg_common" ]; then
  _sg_repo="$(cd "$_sg_common/.." 2>/dev/null && pwd)" || _sg_repo=""
  [ -n "$_sg_repo" ] && PROJECT_NAME="$(basename "$_sg_repo")"
fi

# --- load project-local config --------------------------------------------
CFG_LOADED=0
for cfg in \
  "$PROJECT_DIR/.claude/skills/security-gate-local/local.config.sh" \
  "$PROJECT_DIR/.agents/skills/security-gate-local/local.config.sh"; do
  if [ -f "$cfg" ]; then
    if ! sg_parse_local_config "$cfg"; then
      echo "fail: local config is not allowed data: $cfg line $SG_CONFIG_BAD_LINE" >&2
      exit 1
    fi
    CFG_LOADED=1
  fi
done
# A configured name is held to a strict alphabet. The derived name is the
# repository directory's own basename, which diff and red-team look up as is;
# it is already one component, so only an unusable one is refused.
if [ -n "${SECURITY_GATE_PROJECT_NAME:-}" ]; then
  PROJECT_NAME="$SECURITY_GATE_PROJECT_NAME"
  case "$PROJECT_NAME" in
    .|..|*[!A-Za-z0-9._-]*) echo "fail: SECURITY_GATE_PROJECT_NAME is not a safe path component: $PROJECT_NAME" >&2; exit 1 ;;
  esac
else
  case "$PROJECT_NAME" in
    ''|.|..|*/*) echo "fail: cannot name reports after the project directory '$PROJECT_NAME'; set SECURITY_GATE_PROJECT_NAME" >&2; exit 1 ;;
  esac
fi

PROFILE="${PROFILE_OVERRIDE:-${SECURITY_GATE_STACK_PROFILE:-web-next}}"
AUDIT_DIR_REL="${SECURITY_GATE_AUDIT_DIR:-audits}"
case "$AUDIT_DIR_REL" in
  /*) echo "fail: SECURITY_GATE_AUDIT_DIR must be relative: $AUDIT_DIR_REL" >&2; exit 1 ;;
esac
case "/$AUDIT_DIR_REL/" in
  */../*) echo "fail: SECURITY_GATE_AUDIT_DIR contains a parent segment: $AUDIT_DIR_REL" >&2; exit 1 ;;
esac
# Resolve and check each existing directory before creating its next child:
# mkdir -p on a project symlink could otherwise create directories outside.
AUDIT_DIR="$(builtin cd -P "$PROJECT_DIR" && builtin pwd -P)" || exit 1
IFS=/ builtin read -r -a _sg_audit_parts <<< "$AUDIT_DIR_REL"
for _sg_part in ${_sg_audit_parts[@]+"${_sg_audit_parts[@]}"}; do
  case "$_sg_part" in ''|.) continue ;; esac
  _sg_audit_next="$AUDIT_DIR/$_sg_part"
  if [ ! -d "$_sg_audit_next" ]; then
    if [ -e "$_sg_audit_next" ] || [ -L "$_sg_audit_next" ] || ! mkdir "$_sg_audit_next"; then
      echo "fail: cannot create audit directory: $_sg_audit_next" >&2; exit 1
    fi
  fi
  _sg_audit_physical="$(builtin cd -P "$_sg_audit_next" && builtin pwd -P)" || exit 1
  if ! sg_inside "$_sg_audit_physical" "$PROJECT_DIR"; then
    echo "fail: audit directory resolves outside project: $_sg_audit_next -> $_sg_audit_physical" >&2
    exit 1
  fi
  AUDIT_DIR="$_sg_audit_physical"
done
DATE_TAG="$(date +%Y-%m-%d)"
TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT_MD="$AUDIT_DIR/${DATE_TAG}-baseline-${PROJECT_NAME}.md"
OUT_JSON="$AUDIT_DIR/${DATE_TAG}-baseline-${PROJECT_NAME}.json"
for _sg_report in "$OUT_MD" "$OUT_JSON"; do
  if [ -L "$_sg_report" ]; then
    echo "fail: report path is a symlink: $_sg_report" >&2; exit 1
  fi
done

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
# Each wrapper's stderr is kept so the narrative can say why a stage did not
# complete; it is still shown as the stage ends.
echo "[1/$TOTAL_STAGES] Semgrep…"
if [ "$SG_SEMGREP_RC" -eq 3 ]; then
  echo "semgrep did not complete: unsafe selected engine" > "$WORK/semgrep.err"; : > "$SEMGREP_OUT"; SEMGREP_RC=2
else
  "$SG_BASH" -p "$SKILL_DIR/scripts/lib/semgrep.sh" "$PROJECT_DIR" "$PROFILE" "$SEMGREP_OUT" 2>"$WORK/semgrep.err" || SEMGREP_RC=$?
fi
cat "$WORK/semgrep.err" >&2
echo "[2/$TOTAL_STAGES] OSV…"
if [ "$SG_OSV_RC" -eq 3 ]; then
  echo "osv-scanner did not complete: unsafe selected engine" > "$WORK/osv.err"; : > "$OSV_OUT"; OSV_RC=2
else
  "$SG_BASH" -p "$SKILL_DIR/scripts/lib/osv.sh" "$PROJECT_DIR" "$OSV_OUT" --status "$WORK/osv.status" 2>"$WORK/osv.err" || OSV_RC=$?
fi
cat "$WORK/osv.err" >&2
# Not applicable only on the wrapper's own proof: exit 3 AND a status file
# saying the scanner ran, exited 128 with no package sources, scanned nothing.
if [ "$OSV_RC" -eq 3 ] && [ "$(cat "$WORK/osv.status" 2>/dev/null)" = "osv-scanner: ran=1 exit=128 parsed=0 scanned=0
osv-scanner: not-applicable: scanner found no package sources and scanned nothing" ]; then
  OSV_RC=not-applicable
fi
echo "[3/$TOTAL_STAGES] Gitleaks…"
if [ "$SG_GITLEAKS_RC" -eq 3 ]; then
  echo "gitleaks did not complete: unsafe selected engine" > "$WORK/gitleaks.err"; : > "$GITLEAKS_RAW_OUT"; GITLEAKS_RC=2
else
  "$SG_BASH" -p "$SKILL_DIR/scripts/lib/gitleaks.sh" "$PROJECT_DIR" "$GITLEAKS_RAW_OUT" 2>"$WORK/gitleaks.err" || GITLEAKS_RC=$?
fi
cat "$WORK/gitleaks.err" >&2
:> "$GARAK_OUT"
if [ "$PROFILE" = "web-rag-llm" ]; then
  GARAK_USED=1
  echo "[4/4] Garak (LLM probes)…"
  "$SG_BASH" -p "$SKILL_DIR/scripts/lib/garak.sh" "$PROJECT_DIR" "$GARAK_OUT" 2>"$WORK/garak.err" || GARAK_RC=$?
  cat "$WORK/garak.err" >&2
fi

# Keep history out of the gating scanner stream. The JSONL bucket marker is
# the boundary used by the standalone scanner proof and by this aggregator.
"$PYTHON3_BIN" -I - "$GITLEAKS_RAW_OUT" "$GITLEAKS_OUT" "$HISTORICAL_OUT" <<'PY'
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
"$PYTHON3_BIN" -I - "$MERGED" "$HISTORICAL_OUT" "$PREVIOUS_BASELINE" > "$TRIAGE_INPUT" <<'PY'
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
  if "$SG_BASH" -p "$SKILL_DIR/scripts/lib/llm-call.sh" "$SKILL_DIR/prompts/triage.md" "$TRIAGE_INPUT" "$TRIAGE_OUT" "$PROJECT_DIR"; then
    TRIAGE_USED=1
    LLM_PROVIDER_USED="${LLM_PROVIDER:-anthropic}"
    LLM_MODEL_USED="${LLM_MODEL:-claude-opus-5}"
    echo "triage: completed via $LLM_PROVIDER_USED ($LLM_MODEL_USED)"
  else
    echo "triage: skipped (no provider available); writing raw findings"
    : > "$TRIAGE_OUT"
  fi
fi

# --- merge findings + decisions, write JSON + Markdown --------------------
SEMGREP_VER=""; OSV_VER=""; GITLEAKS_VER=""
[ "$SG_SEMGREP_RC" -ne 0 ] || SEMGREP_VER="$("$SG_SEMGREP_BIN" --version 2>/dev/null | tail -1)"
[ "$SG_OSV_RC" -ne 0 ] || OSV_VER="$("$SG_OSV_BIN" --version 2>/dev/null | head -1 | awk '{print $NF}')"
[ "$SG_GITLEAKS_RC" -ne 0 ] || GITLEAKS_VER="$("$SG_GITLEAKS_BIN" version 2>/dev/null | head -1)"

# Engines: name, wrapper exit, the wrapper's own output before any split, and
# its stderr.
ENGINES=(semgrep "$SEMGREP_RC" "$SEMGREP_OUT" "$WORK/semgrep.err"
         osv-scanner "$OSV_RC" "$OSV_OUT" "$WORK/osv.err"
         gitleaks "$GITLEAKS_RC" "$GITLEAKS_RAW_OUT" "$WORK/gitleaks.err")
[ "$GARAK_USED" = "1" ] && ENGINES+=(garak "$GARAK_RC" "$GARAK_OUT" "$WORK/garak.err")

AGG_RC=0
"$PYTHON3_BIN" -I - "$MERGED" "$HISTORICAL_OUT" "$TRIAGE_OUT" "$PREVIOUS_BASELINE" "$OUT_JSON" "$OUT_MD" \
  "$PROJECT_NAME" "$PROFILE" "$TS_ISO" \
  "${SEMGREP_VER:-unknown}" "${OSV_VER:-unknown}" "${GITLEAKS_VER:-unknown}" \
  "$LLM_PROVIDER_USED" "$LLM_MODEL_USED" "$TRIAGE_USED" "${ENGINES[@]}" <<'PY' || AGG_RC=$?
import json, sys, os, tempfile
merged_p, historical_p, triage_p, previous_p, json_p, md_p = sys.argv[1:7]


def write_report(path, content):
    # Replace the directory entry, never truncate a pre-existing hardlink or
    # follow a report symlink introduced after the shell's initial check.
    fd, temp = tempfile.mkstemp(prefix=".security-gate-", dir=os.path.dirname(path))
    try:
        # mkstemp creates 0600; reports keep the umask mode open() gave them.
        umask = os.umask(0)
        os.umask(umask)
        os.fchmod(fd, 0o666 & ~umask)
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)

project, profile, ts = sys.argv[7:10]
sg_ver, osv_ver, gl_ver = sys.argv[10:13]
llm_provider, llm_model, triage_used = sys.argv[13], sys.argv[14], sys.argv[15] == "1"

# An engine completed only when its wrapper exited 0 AND every line it wrote is
# a finding object. A failure, a skip, or output that does not parse makes
# the whole baseline incomplete; zero findings from it then prove nothing.
engines = {}
args = sys.argv[16:]


def reason(err_p, marker=" did not complete: "):
    # The wrapper's last "<engine> did not complete: <why>" line, if any.
    found = ""
    try:
        with open(err_p, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                if marker in ln:
                    found = ln.split(marker, 1)[1].strip()[:200]
    except OSError:
        pass
    return found


for name, rc, out_p, err_p in zip(args[0::4], args[1::4], args[2::4], args[3::4]):
    if rc == "not-applicable":
        # The wrapper proved there was nothing to scan; it never ran a scanner.
        engines[name] = {"status": "not_applicable", "exit": 3,
                         "detail": reason(err_p, ": not applicable: ") or "nothing to scan"}
        continue
    engine = {"status": "ok", "exit": int(rc)}
    if engine["exit"] != 0:
        engine["status"] = "failed"
        if reason(err_p):
            engine["detail"] = reason(err_p)
    elif not os.path.isfile(out_p):
        engine.update(status="invalid_output", detail="no output file")
    else:
        with open(out_p, encoding="utf-8", errors="replace") as fh:
            for n, ln in enumerate(fh, 1):
                if not ln.strip():
                    continue
                try:
                    row = json.loads(ln)
                except json.JSONDecodeError:
                    row = None
                if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                    engine.update(status="invalid_output", detail=f"line {n} is not a finding object")
                    break
    engines[name] = engine
complete = all(e["status"] in ("ok", "not_applicable") for e in engines.values())
not_applicable = [n for n, e in engines.items() if e["status"] == "not_applicable"]

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
    "complete": complete,
    "engines": engines,
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
write_report(json_p, json.dumps(doc, indent=2))

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
line("## Engines")
line()
for name, e in engines.items():
    if e["status"] == "ok":
        line(f"- {name}: completed")
    elif e["status"] == "not_applicable":
        line(f"- {name}: not applicable ({e['detail']})")
    elif e["status"] == "failed":
        line(f"- {name}: **failed** (exit {e['exit']})" + (f": {e['detail']}" if e.get("detail") else ""))
    else:
        line(f"- {name}: **invalid output** ({e['detail']})")
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
na_note = (" Not applicable: " + ", ".join(not_applicable) + ".") if not_applicable else ""
if not complete:
    missing = ", ".join(n for n, e in engines.items() if e["status"] not in ("ok", "not_applicable"))
    line(f"Verdict: **incomplete** — {missing} did not complete, so the findings below are partial and cannot show that the current tree has none.{na_note}")
elif doc['summary']['total_raw'] == 0:
    line("Verdict: **clean current tree** — no gating findings produced by any scanner." + na_note)
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

write_report(md_p, "\n".join(out_lines) + "\n")
if not complete:
    print("baseline incomplete: " + "; ".join(
        f"{n} {e['status'].replace('_', ' ')} (exit {e['exit']})" for n, e in engines.items() if e["status"] not in ("ok", "not_applicable")))
    sys.exit(2)
PY

case "$AGG_RC" in
  0|2) ;;
  *) echo "fail: baseline aggregation exited $AGG_RC; no valid baseline was written" >&2; exit 1 ;;
esac
echo
echo "wrote: $OUT_MD"
echo "wrote: $OUT_JSON"
exit "$AGG_RC"
