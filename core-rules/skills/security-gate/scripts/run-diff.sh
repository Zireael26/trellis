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
PROJECT_NAME="${SECURITY_GATE_PROJECT_NAME:-$PROJECT_NAME}"

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

# A shell script does not have to carry a suffix. `pre-push`, `commit-msg`,
# `pre-commit` and a CLI entrypoint conventionally carry none, so a suffix-only
# filter drops the highest-value scripts in a repository out of *every* arm at
# once — not in the semgrep scope, not in the ShellCheck scope. Classification
# falls back to the shebang, which is what ShellCheck itself dispatches on.
# `env` is resolved through to the real interpreter, and only the four dialects
# ShellCheck accepts count; a `#!/usr/bin/env bats` or `#!/usr/bin/env python3`
# file is not shell and returns non-zero here.
shebang_is_shell() {
  # Bounded read: only the shebang line can matter, and a changed file may be a
  # large binary.
  head -c 256 "$1" 2>/dev/null | awk 'BEGIN { rc = 1 }
       NR == 1 {
         if ($0 ~ /^#!/) {
           sub(/^#![ \t]*/, "")
           interp = $1
           if (interp ~ /(^|\/)env$/) {
             for (i = 2; i <= NF; i++) { if ($i !~ /^-/) { interp = $i; break } }
           }
           sub(/.*\//, "", interp)
           if (interp ~ /^(sh|bash|dash|ksh)$/) rc = 0
         }
         exit rc
       }
       END { exit rc }' 2>/dev/null
}

# Paths carved out of the ShellCheck stage, as whitespace-separated globs
# matched against the repo-relative path. Empty by default: a project sets this
# in its `security-gate-local/local.config.sh` to mirror whatever its own lint
# gate carves out, so the two agree. It is deliberately not hardcoded — this
# skill is inherited by every registered project and must not name one project's
# directory layout.
SHELLCHECK_EXCLUDE_GLOBS=()
if [ -n "${SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS:-}" ]; then
  # Split on whitespace but never pathname-expand. These are patterns to match a
  # repo-relative path against, not paths to resolve against the current
  # directory — and `core-rules/evals/*` resolves against a real directory when
  # the gate runs from the repository root, which silently turned the pattern
  # into a list of literal paths that matched nothing.
  set -f
  # shellcheck disable=SC2206  # word splitting is the point; globbing is off
  SHELLCHECK_EXCLUDE_GLOBS=(${SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS})
  set +f
fi

# Semgrep — scoped to changed files (filter to existing files; skip deletions).
:>"$SEMGREP_OUT"
SCOPE_FILES=()
SHELL_SCOPE_FILES=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$PROJECT_DIR/$f" ] || continue
  is_shell=false
  case "$f" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.rb|*.php) ;;
    # Shell is a first-class language here. Excluding it meant a shell-heavy
    # repository had ~2% of its diff inspected while the row still read `pass`.
    #
    # `.bats` is deliberately NOT in this list. Semgrep's default ignore set skips
    # test directories on a directory scan but not on explicit targets, so a
    # baseline can never hold a finding this mode would then raise out of a test
    # fixture — every run would report the same fixture credentials as new. Test
    # files are covered by the baseline's whole-tree scan instead.
    *.sh|*.bash) is_shell=true ;;
    # `.zsh` gets semgrep only, and that is a real gap rather than coverage:
    # semgrep's registry has no shell ruleset, so only the generic secret and
    # command-injection patterns can fire, and ShellCheck has no zsh dialect to
    # fall back on. A zsh file is listed as scanned and is, in practice, only
    # grepped for secrets.
    *.zsh) ;;
    *) shebang_is_shell "$PROJECT_DIR/$f" || continue; is_shell=true ;;
  esac
  SCOPE_FILES+=("$PROJECT_DIR/$f")
  # ShellCheck refuses anything that is not sh/bash/dash/ksh and reports the
  # refusal as a high-severity finding, so it gets its own narrower list.
  #
  # The carve-out is load-bearing rather than cosmetic: the baseline engine
  # never runs ShellCheck (scripts/lib/semgrep.sh), so a shell finding has no
  # baseline entry to be deduped against and every one is permanently "new". A
  # project therefore scopes this stage to exactly the tree its own lint gate
  # owns; a file the lint gate is not allowed to clean must not be able to block
  # a push here.
  [ "$is_shell" = true ] || continue
  shell_excluded=false
  for glob in ${SHELLCHECK_EXCLUDE_GLOBS[@]+"${SHELLCHECK_EXCLUDE_GLOBS[@]}"}; do
    # shellcheck disable=SC2254  # the config value is a glob pattern by design
    case "$f" in $glob) shell_excluded=true; break ;; esac
  done
  [ "$shell_excluded" = true ] || SHELL_SCOPE_FILES+=("$PROJECT_DIR/$f")
done < "$CHANGED_LIST"

if [ "${#SCOPE_FILES[@]}" -gt 0 ] && command -v semgrep >/dev/null 2>&1; then
  case "$PROFILE" in
    web-next)      CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript --config=p/nextjs --config=p/react) ;;
    web-static)    CONFIGS=(--config=p/owasp-top-ten --config=p/javascript --config=p/typescript) ;;
    shell-tooling) CONFIGS=(--config=p/owasp-top-ten --config=p/command-injection --config=p/secrets) ;;
    *)             CONFIGS=(--config=p/owasp-top-ten) ;;
  esac
  # Same exclusions the baseline engine applies (scripts/lib/semgrep.sh), so a
  # diff finding is comparable to a baseline finding rather than an artefact of
  # the two modes disagreeing about scope.
  EXCLUDES=(--exclude=node_modules --exclude=.next --exclude=dist --exclude=build --exclude=.turbo --exclude=test-results --exclude=coverage --exclude=audits --exclude=playwright-report)
  RAW="$WORK/semgrep.raw.json"
  semgrep scan --json --metrics=off --quiet "${CONFIGS[@]}" "${EXCLUDES[@]}" "${SCOPE_FILES[@]}" >"$RAW" 2>/dev/null || true
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

# ShellCheck — the actual SAST for shell. Semgrep's registry has no bash ruleset
# (`p/bash` 404s) and a canary proves it detects neither `eval "$x"` nor a
# hardcoded AWS secret in a .sh file, so scoping shell in without this engine
# would put shell files in `paths.scanned` and still see nothing. Findings join
# the semgrep stream because they populate the same SAST row.
#
# The stage is opt-in per project rather than fleet-wide, and the default tracks
# the profile only as a convenience. It cannot simply be on everywhere: the
# baseline engine does not run ShellCheck, so on a tree whose shell has never
# been linted every finding is permanently new and unbaselineable, and turning
# this on would block every push over pre-existing debt. `SECURITY_GATE_SHELLCHECK=1`
# in a project's `security-gate-local/local.config.sh` is the opt-in; `=0` is the
# opt-out for a `shell-tooling` project that is not ready yet.
case "${SECURITY_GATE_SHELLCHECK:-}" in
  1|true|on|yes)  SHELLCHECK_ENABLED=true ;;
  0|false|off|no) SHELLCHECK_ENABLED=false ;;
  "")             if [ "$PROFILE" = "shell-tooling" ]; then SHELLCHECK_ENABLED=true; else SHELLCHECK_ENABLED=false; fi ;;
  *)              echo "warn: unrecognized SECURITY_GATE_SHELLCHECK value — treating as unset" >&2
                  if [ "$PROFILE" = "shell-tooling" ]; then SHELLCHECK_ENABLED=true; else SHELLCHECK_ENABLED=false; fi ;;
esac

if [ "$SHELLCHECK_ENABLED" = true ] && [ "${#SHELL_SCOPE_FILES[@]}" -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
  SC_RAW="$WORK/shellcheck.raw.json"
  shellcheck --severity=warning --format=json "${SHELL_SCOPE_FILES[@]}" >"$SC_RAW" 2>/dev/null || true
  python3 - "$SC_RAW" "$PROJECT_DIR" >>"$SEMGREP_OUT" <<'SCPY'
import json, sys, os
raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_map = {"error": "high", "warning": "medium", "info": "low", "style": "low"}
try:
    with open(raw) as fh: data = json.load(fh)
except Exception:
    sys.exit(0)
for i, r in enumerate(data, 1):
    path = r.get("file") or ""
    if path.startswith(root + os.sep): path = path[len(root) + 1:]
    print(json.dumps({
        "id": f"shellcheck-diff-{i:04d}",
        "tool": "shellcheck",
        "rule": f"SC{r.get('code', 0)}",
        "severity": sev_map.get((r.get("level") or "").lower(), "low"),
        "file": path,
        "line": r.get("line", 0),
        "message": (r.get("message") or "")[:280],
    }, ensure_ascii=False))
SCPY
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
    # v2 historical_findings are deliberately excluded: only current-tree
    # findings form the dedupe/pass-fail baseline for a new diff.
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
    # ShellCheck rides the same SAST row as semgrep — it is the SAST engine for
    # shell, and semgrep is blind to it. Without this arm every ShellCheck
    # finding fell through the case, updated no *_WORST, and a new high-severity
    # shell defect returned MERGEABLE/0 on a repository that is mostly Bash.
    # Kept as its own arm rather than relabelling the tool so the printed
    # provenance (`shellcheck/SC1072`) stays truthful.
    semgrep|shellcheck) SAST_NEW=$((SAST_NEW+1)); [ "$WORST" = "fail" ] && SAST_WORST="fail";    [ "$WORST" = "warn" ] && [ "$SAST_WORST" = "pass" ] && SAST_WORST="warn" ;;
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
line = f.get("line")
if line: loc += ":" + str(line)
print("- **" + f.get("severity","") + "** `" + f.get("tool","") + "/" + f.get("rule","") + "` @ `" + loc + "` — " + f.get("message",""))
'
  done
  printf "\n"
fi

case "$OVERALL" in
  MERGEABLE)        exit 0 ;;
  "NEEDS CHANGES")  exit 2 ;;
  BLOCKED)          exit 1 ;;
esac
