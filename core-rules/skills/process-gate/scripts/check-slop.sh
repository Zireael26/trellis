#!/usr/bin/env bash
# Gate 9: Anti-slop — evidence-doctrine patterns in the range's ADDED lines.
# Usage: check-slop.sh [--range=<gitspec>]
#
# Posture is read from the project's `.trellis.json`
# `gate_profiles.anti_slop.posture` (spec 037 plan §2):
#   absent | off -> row is n/a, nothing is scanned, exit 0
#   advisory     -> findings print as warn, exit 0 (v1 never blocks)
#   enforced     -> findings print as fail, exit 1
#   malformed    -> treated as advisory plus one warn line naming the breakage
#                   (fail-open on posture, unlike mandatory_pipeline: v1 is
#                   advisory-by-design; revisit when a project sets `enforced`)
#
# Exit codes deliberately DIVERGE from pg_exit_code's warn=2: here the exit code
# encodes only whether the gate blocks (0 = never, 1 = enforced with findings),
# and the printed level (`pass`/`warn`/`fail`/`info`) is what the row renders
# from. run-all.sh reads that first token — it is the only channel that can
# carry `n/a`, which no exit code has.
#
# Scope is the ratchet: only lines the range adds are reported, so pre-existing
# violations belong to the cleanup sessions, not to this gate.
#
# Detection is EITHER the profile's native linter, narrowed to the profile's own
# rules, OR the shared grep pattern set — never the project's whole lint config
# (see the detection-ladder section below) and never an unrun linter's silence
# (see run_native). Both of those render a project's ordinary lint findings, or a
# broken toolchain, as an anti-slop verdict.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# --- posture ---------------------------------------------------------------
# Resolved FIRST, before the pattern lib is even looked for: a project that has
# not opted in renders `n/a` whatever the harness state is. Resolving the lib
# first inverted that — every project whose `hooks/lib` had not been synced yet
# (which is all of them until the rollout lands, and permanently for a codex-only
# attachment) warned, and one warn flips the whole process-gate verdict to NEEDS
# CHANGES on a gate the project never declared.
# One jq pass classifies the declaration: `off:`, `ok:<posture>`, or
# `malformed:<what>`. An unreadable or non-object file is malformed; a missing
# key at any level is simply undeclared.
POSTURE="off"
MALFORMED=""
TRELLIS_JSON="$PROJECT_DIR/.trellis.json"
if [ -f "$TRELLIS_JSON" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    pg_log info "Anti-slop: n/a — jq unavailable, posture unreadable (range=$RANGE)"
    exit 0
  fi
  verdict="$(jq -r '
    . as $r
    | if ($r | type) != "object" then "malformed:.trellis.json is not a JSON object"
      elif ($r.gate_profiles | type) == "null" then "off:"
      elif ($r.gate_profiles | type) != "object" then "malformed:gate_profiles is not an object"
      elif ($r.gate_profiles.anti_slop | type) == "null" then "off:"
      elif ($r.gate_profiles.anti_slop | type) != "object" then "malformed:gate_profiles.anti_slop is not an object"
      elif ($r.gate_profiles.anti_slop.posture | type) == "null" then "off:"
      elif ($r.gate_profiles.anti_slop.posture | type) != "string" then "malformed:posture is a \($r.gate_profiles.anti_slop.posture | type), not a string"
      elif (["off","advisory","enforced"] | index($r.gate_profiles.anti_slop.posture)) then "ok:\($r.gate_profiles.anti_slop.posture)"
      else "malformed:posture \"\($r.gate_profiles.anti_slop.posture)\" is not one of off|advisory|enforced"
      end' "$TRELLIS_JSON" 2>/dev/null || true)"
  case "$verdict" in
    "off:")      POSTURE="off" ;;
    ok:*)        POSTURE="${verdict#ok:}" ;;
    malformed:*) POSTURE="advisory"; MALFORMED="${verdict#malformed:}" ;;
    *)           POSTURE="advisory"; MALFORMED=".trellis.json is not parseable JSON" ;;
  esac
fi

if [ "$POSTURE" = "off" ]; then
  pg_log info "Anti-slop: n/a — posture off or undeclared (range=$RANGE)"
  exit 0
fi

# --- pattern lib -----------------------------------------------------------
# Canonical layout first (the skill dir's sibling `hooks/lib`), then the copies
# sync-hooks.sh / onboard-project.sh seed per harness. `.codex/hooks/lib` is the
# destination the inheritance manifest actually creates for a Codex attachment —
# `.agents/hooks/lib` is never populated by codex expansion — so leaving it out
# made a codex-only project take the missing-lib branch forever.
SLOP_LIB=""
for cand in \
  "$SKILL_DIR/../../hooks/lib/slop-patterns.sh" \
  "$PROJECT_DIR/.claude/hooks/lib/slop-patterns.sh" \
  "$PROJECT_DIR/.codex/hooks/lib/slop-patterns.sh" \
  "$PROJECT_DIR/.agents/hooks/lib/slop-patterns.sh"; do
  if [ -f "$cand" ]; then SLOP_LIB="$cand"; break; fi
done
if [ -z "$SLOP_LIB" ]; then
  # A harness gap, not a slop finding — warn and never block, at any posture.
  # Only reachable once a project has DECLARED a posture, which is what makes the
  # warn actionable rather than noise.
  pg_log warn "Anti-slop (range=$RANGE, posture=$POSTURE)"
  pg_finding "hooks/lib/slop-patterns.sh not found — pattern set unavailable; re-run sync-hooks"
  exit 0
fi
# shellcheck source=../../../hooks/lib/slop-patterns.sh
. "$SLOP_LIB"

# --- added-line lookup -----------------------------------------------------
# file<TAB>lineno<TAB>content, one row per added line. Same single-pass awk as
# check-secrets.sh; it is both the scan input and the ratchet filter.
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t check-slop)"
# shellcheck disable=SC2154  # `rc` is assigned inside the trap
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
LOOKUP="$WORK/added"

# `-c core.quotePath=false` so a non-ASCII path arrives as itself rather than
# C-quoted (`"src/na\303\257ve.ts"`), whose extension would parse as `ts"` and
# drop the file with no `detection:` line at all.
#
# The `+++ b/<path>` header is TAB-terminated whenever the path contains a space,
# so the trailing tab (and git's own `\t<info>` suffix) has to come off the name —
# otherwise the LOOKUP columns shift by one and every finding in that file is
# silently dropped.
git -c core.quotePath=false diff --no-color --unified=0 "$RANGE" 2>/dev/null \
  | awk 'BEGIN{file=""; line=0} \
      /^\+\+\+ b\// {file=substr($0,7); sub(/\t.*$/, "", file); next} \
      /^@@ / {match($0, /\+[0-9]+/); line=substr($0,RSTART+1,RLENGTH-1)+0; next} \
      /^\+/ && !/^\+\+\+/ {printf "%s\t%d\t%s\n", file, line, substr($0,2); line++}' \
  > "$LOOKUP" || true

# --- candidate files -------------------------------------------------------
# In-scope extension, not carved out, and actually contributing an added line.
# The list is derived from $LOOKUP rather than from a second `git diff --name-only`
# so the names are byte-identical to the lookup keys the ratchet joins on — a
# separate listing re-introduces the quoting skew this file's own scan just
# avoided. A file with only deletions has nothing to scan either way.
TS_FILES=()
PY_FILES=()
OTHER_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if slop_path_carved_out "$f"; then continue; fi
  lang="$(slop_lang_for_path "$f" 2>/dev/null || true)"
  case "$lang" in
    ts) TS_FILES+=("$f") ;;
    py) PY_FILES+=("$f") ;;
    go|rs) OTHER_FILES+=("$f	$lang") ;;
  esac
done < <(cut -f1 "$LOOKUP" | sort -u)

# --- detection ladder ------------------------------------------------------
# An INSTALLED PROFILE means the native linter owns that language; the grep
# pattern set is the fallback everywhere else. Go and Rust are pattern-only in v1
# (their profiles ship dormant).
#
# "Installed profile" is the profile's own marker in the config, never the mere
# existence of a config file: oxlint keys off the vendored plugin's name, ruff off
# the ANN401 it selects, mypy off the `ignore-without-code` it enables. The config
# candidate lists and the marker strings come from the pattern lib so this file,
# audit-slop.sh and doctor's presence row cannot disagree about what "installed"
# means. Detecting on file existence alone made any project with an oxlint config
# report its entire lint configuration under the anti-slop label.
#
# resolve_engine <marker> <bin-name> <local-bin-path> <config...> -> path on stdout
resolve_engine() {
  local marker="$1" name="$2" local_bin="$3" cand
  shift 3
  for cand in "$@"; do
    [ -f "$PROJECT_DIR/$cand" ] || continue
    grep -q "$marker" "$PROJECT_DIR/$cand" || continue
    if [ -x "$PROJECT_DIR/$local_bin" ]; then
      printf '%s' "$PROJECT_DIR/$local_bin"
    elif command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
    fi
    return 0
  done
  return 0
}

# shellcheck disable=SC2086 # the SLOP_*_CONFIGS lists are word lists on purpose.
oxlint_bin="$(resolve_engine "$SLOP_OXLINT_PLUGIN" oxlint node_modules/.bin/oxlint $SLOP_OXLINT_CONFIGS)"
# shellcheck disable=SC2086
ruff_bin="$(resolve_engine ANN401 ruff .venv/bin/ruff $SLOP_RUFF_CONFIGS)"
# shellcheck disable=SC2086
mypy_bin="$(resolve_engine ignore-without-code mypy .venv/bin/mypy $SLOP_MYPY_CONFIGS)"

# parse_unix_findings [rule-filter-ERE] — <path>:<line>:<col>: <message> (oxlint
# --format=unix and `ruff check --output-format=concise` share the shape) ->
# file<TAB>line<TAB>msg. With a filter, only messages matching it survive: that is
# how the oxlint lane is narrowed to the vendored plugin's own rule ids, since
# oxlint has no per-plugin select flag.
parse_unix_findings() {
  awk -v keep="${1:-}" '{
    if (!match($0, /^[^:]+:[0-9]+:[0-9]+:/)) next
    hdr = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    sub(/^[[:space:]]+/, "", rest)
    if (keep != "" && rest !~ keep) next
    split(hdr, p, ":")
    printf "%s\t%s\t%s\n", p[1], p[2], rest
  }'
}

# parse_mypy_findings <comma-separated-codes> — <path>:<line>: error: <message>
# [<code>]. Columns are off by default so this cannot reuse parse_unix_findings;
# notes and hints are dropped, and only the error codes the profile's mypy fragment
# owns survive (mypy has no "run only these codes" flag).
#
# The trailing code is EXTRACTED and matched for exact membership rather than
# regex-matched: passing a `\[(a|b)\]` pattern through `awk -v` gets unescaped once
# by awk's own string processing, leaving `[(a|b)]` — a character class that
# matches any message containing one of those letters, i.e. everything.
parse_mypy_findings() {
  awk -v codes=",$1," '{
    if (!match($0, /^[^:]+:[0-9]+: error: /)) next
    hdr = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    if (!match(rest, /\[[a-z][a-z-]*\][[:space:]]*$/)) next
    code = substr(rest, RSTART + 1, RLENGTH - 2)
    sub(/\].*$/, "", code)
    if (index(codes, "," code ",") == 0) next
    split(hdr, p, ":")
    printf "%s\t%s\t%s\n", p[1], p[2], rest
  }'
}

# run_native <engine> <outfile> <cmd...> — capture stdout, report whether the tool
# RAN. Exit 1 means "found findings" for all three tools; >= 2 means the tool
# itself failed (broken config, missing plugin, bad flag) and its empty output
# must never render as a clean gate row — that is a fallback presented as
# measured, the one failure mode this gate exists to avoid.
run_native() {
  local engine="$1" out="$2" rc=0
  shift 2
  ( cd "$PROJECT_DIR" && "$@" ) > "$out" 2>"$WORK/err" || rc=$?
  if [ "$rc" -ge 2 ]; then
    DEGRADED="$DEGRADED $engine(rc=$rc)"
    return 1
  fi
  return 0
}

# scan_patterns <file> <lang> -> file<TAB>line<TAB>pattern-id, added lines only.
# slop_scan_text numbers its own stdin, so the real line numbers are carried in
# a parallel column and re-joined by index.
#
# The content column is rebuilt by cutting the two leading fields off the row, not
# by printing $3: the content still carries its own leading indentation, so under
# FS='\t' a tab-indented added line puts the code in $4 and up and `print $3`
# yields an empty string. gofmt indents with tabs, so `print $3` made the entire
# Go lane — and every tab-indented TS/JS/PY file — invisible to the gate while the
# tripwire flagged the same lines.
scan_patterns() {
  local file="$1" lang="$2"
  awk -F'\t' -v f="$file" '$1 == f { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' "$LOOKUP" > "$WORK/lines"
  awk -F'\t' -v f="$file" '$1 == f { print $2 }' "$LOOKUP" > "$WORK/nums"
  [ -s "$WORK/lines" ] || return 0
  slop_scan_text "$lang" < "$WORK/lines" \
    | awk -F'\t' -v f="$file" -v nf="$WORK/nums" '
        BEGIN { while ((getline l < nf) > 0) { n[++i] = l } }
        { printf "%s\t%s\t%s\n", f, n[$1], $2 }' || true
}

RAW="$WORK/raw"
: > "$RAW"
MODES=""
DEGRADED=""

if [ "${#TS_FILES[@]}" -gt 0 ]; then
  ts_engine="patterns"
  if [ -n "$oxlint_bin" ]; then
    if run_native oxlint "$WORK/out" "$oxlint_bin" --format=unix "${TS_FILES[@]}"; then
      ts_engine="oxlint"
      parse_unix_findings "$SLOP_OXLINT_PLUGIN" < "$WORK/out" >> "$RAW" || true
    fi
  fi
  if [ "$ts_engine" = "patterns" ]; then
    for f in "${TS_FILES[@]}"; do scan_patterns "$f" ts >> "$RAW"; done
  fi
  MODES="$MODES ts=$ts_engine"
fi

# ruff and mypy own disjoint halves of the Python profile (plan D3), so both run
# when installed. If EITHER fails to run, the whole language degrades to the
# pattern set — the pattern lane approximates both halves, so it cannot
# under-report, whereas keeping the surviving engine's findings would let the note
# claim coverage for rules nothing checked.
if [ "${#PY_FILES[@]}" -gt 0 ]; then
  py_engine=""
  py_failed=0
  if [ -n "$ruff_bin" ]; then
    if run_native ruff "$WORK/out" "$ruff_bin" check --no-cache \
      --output-format=concise --select "$SLOP_RUFF_RULES" "${PY_FILES[@]}"; then
      py_engine="ruff"
      parse_unix_findings < "$WORK/out" >> "$WORK/py.native" || true
    else
      py_failed=1
    fi
  fi
  if [ -n "$mypy_bin" ]; then
    if run_native mypy "$WORK/out" "$mypy_bin" --no-incremental \
      --cache-dir=/dev/null --no-error-summary "${PY_FILES[@]}"; then
      py_engine="${py_engine:+$py_engine+}mypy"
      parse_mypy_findings "$SLOP_MYPY_CODES" < "$WORK/out" >> "$WORK/py.native" || true
    else
      py_failed=1
    fi
  fi
  if [ -z "$py_engine" ] || [ "$py_failed" = "1" ]; then
    py_engine="patterns"
    rm -f "$WORK/py.native"
    for f in "${PY_FILES[@]}"; do scan_patterns "$f" py >> "$RAW"; done
  else
    cat "$WORK/py.native" >> "$RAW"
  fi
  MODES="$MODES py=$py_engine"
fi

if [ "${#OTHER_FILES[@]}" -gt 0 ]; then
  MODES="$MODES go/rs=patterns"
  for row in "${OTHER_FILES[@]}"; do
    scan_patterns "${row%%	*}" "${row##*	}" >> "$RAW"
  done
fi

# The ratchet, applied to every detection mode alike: drop any finding whose
# file:line is not an added line in the range. This is what keeps a native
# linter's whole-file report diff-scoped.
HITS="$(awk -F'\t' -v lk="$LOOKUP" '
  BEGIN { while ((getline l < lk) > 0) { split(l, p, "\t"); added[p[1] "\t" p[2]] = 1 } }
  ($1 "\t" $2) in added { print }' "$RAW" | sort -u || true)"

# --- verdict ---------------------------------------------------------------
worst="pass"
findings=()

if [ -n "$MALFORMED" ]; then
  findings+=("posture: $MALFORMED — treated as advisory")
  worst="warn"
fi

# A native engine that could not run is reported as a warn even when the pattern
# fallback came back clean. Silence here would be the pattern-lane result wearing
# the native lane's authority.
if [ -n "$DEGRADED" ]; then
  findings+=("native engine failed to run:${DEGRADED} — degraded to the pattern set ($(head -n 1 "$WORK/err" 2>/dev/null | cut -c1-120))")
  [ "$worst" = "fail" ] || worst="warn"
fi

if [ -n "$HITS" ]; then
  while IFS=$'\t' read -r file lineno label; do
    [ -n "$file" ] || continue
    findings+=("$file:$lineno — $label")
  done <<EOF
$HITS
EOF
  case "$POSTURE" in
    enforced) worst="fail" ;;
    *)        worst="warn" ;;
  esac
fi

header="Anti-slop (range=$RANGE, posture=$POSTURE)"
case "$worst" in
  pass) pg_log pass "$header" ;;
  warn) pg_log warn "$header" ;;
  fail) pg_log fail "$header" ;;
esac
if [ "$worst" != "pass" ]; then
  for f in ${findings[@]+"${findings[@]}"}; do pg_finding "$f"; done
  pg_finding "doctrine: $SLOP_DOCTRINE_REF"
fi
if [ -n "$MODES" ]; then pg_log info "detection:$MODES"; fi

# Only `enforced` blocks. See the exit-code note in the header comment.
case "$worst" in
  fail) exit 1 ;;
  *)    exit 0 ;;
esac
