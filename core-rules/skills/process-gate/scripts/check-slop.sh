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
# Detection uses the profile's native rules plus patterns not owned by a running
# native engine, or the full shared pattern set when the native lane degrades.
# It never reports the project's whole lint config or an unrun linter's silence.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config "$@" || exit 1
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# --- posture ---------------------------------------------------------------
# Invariant: posture is resolved before pattern-lib lookup; off/undeclared renders `n/a`
# regardless of harness state. Governing rule: spec 037 acceptance — see
# check-slop.bats "no pattern lib + posture off/undeclared: still n/a, never a warn".
# One jq pass classifies the declaration: `off:`, `ok:<posture>`, or
# `malformed:<what>`. An unreadable or non-object file is malformed; a missing
# key at any level is simply undeclared.
POSTURE="off"
MALFORMED=""
TRELLIS_JSON="$PROJECT_DIR/.trellis.json"
if [ -f "$TRELLIS_JSON" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    # Posture alone can be read through the same vetted interpreter resolver as
    # security-gate. Restrict resolution to fixed system locations, never the
    # project's or caller's PATH; do not run the scan without jq.
    engine_lib="$SKILL_DIR/../security-gate/scripts/lib/engine.sh"
    fallback_py=""
    if [ -f "$engine_lib" ]; then
      fallback_py="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin; export PATH
        builtin source "$engine_lib" && sg_resolve_python "$PROJECT_DIR")" || fallback_py=""
    fi
    if [ -z "$fallback_py" ] || [ ! -x /usr/bin/env ]; then
      pg_log fail "Anti-slop: jq unavailable and posture unknown — trusted interpreter unavailable (range=$RANGE)"
      exit 1
    fi
    fallback="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="${HOME:-/}" LANG=C \
      "$fallback_py" -I -c '
import json, sys

def kind(value):
    if value is None: return "null"
    if isinstance(value, bool): return "boolean"
    if isinstance(value, dict): return "object"
    if isinstance(value, list): return "array"
    if isinstance(value, str): return "string"
    return "number"

def reject_constant(value):
    raise ValueError(value)

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        root = json.load(stream, parse_constant=reject_constant)
except (OSError, UnicodeError, ValueError):
    print("malformed:.trellis.json is not parseable JSON")
    sys.exit(0)
if not isinstance(root, dict):
    print("malformed:.trellis.json is not a JSON object")
    sys.exit(0)
node = root.get("gate_profiles")
if node is None:
    print("off:")
elif not isinstance(node, dict):
    print("malformed:gate_profiles is not an object")
else:
    node = node.get("anti_slop")
    if node is None:
        print("off:")
    elif not isinstance(node, dict):
        print("malformed:gate_profiles.anti_slop is not an object")
    else:
        posture = node.get("posture")
        if posture is None: print("off:")
        elif not isinstance(posture, str): print("malformed:posture is a " + kind(posture) + ", not a string")
        elif posture in ("off", "advisory", "enforced"): print("ok:" + posture)
        else: print("malformed:posture is not one of off|advisory|enforced")
' "$TRELLIS_JSON" 2>/dev/null)" || fallback=""
    case "$fallback" in
      off:|ok:off)
        pg_log info "Anti-slop: n/a — posture off or undeclared (range=$RANGE)"
        exit 0 ;;
      ok:advisory)
        pg_log info "Anti-slop: n/a — jq unavailable; advisory check did not run (range=$RANGE)"
        exit 0 ;;
      ok:enforced)
        pg_log fail "Anti-slop: jq unavailable; enforced check did not run (range=$RANGE)"
        exit 1 ;;
      malformed:*)
        pg_log warn "Anti-slop: ${fallback#malformed:} — treated as advisory; jq unavailable, check did not run (range=$RANGE)"
        exit 0 ;;
      *)
        pg_log fail "Anti-slop: jq unavailable and posture unknown — trusted interpreter failed (range=$RANGE)"
        exit 1 ;;
    esac
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
trap 'rc=$?; rm -rf "${WORK:?}"; exit "$rc"' EXIT
LOOKUP="$WORK/added"
DEGRADED=""

# `-c core.quotePath=false` so a non-ASCII path arrives as itself rather than
# C-quoted (`"src/na\303\257ve.ts"`), whose extension would parse as `ts"` and
# drop the file with no `detection:` line at all.
#
# The `+++ b/<path>` header is TAB-terminated whenever the path contains a space,
# so the trailing tab (and git's own `\t<info>` suffix) has to come off the name —
# otherwise the LOOKUP columns shift by one and every finding in that file is
# silently dropped.
diff_rc=0
git -c core.quotePath=false diff --no-ext-diff --no-textconv \
  --src-prefix=a/ --dst-prefix=b/ --no-color --unified=0 "$RANGE" \
  2>"$WORK/diff.err" >"$WORK/diff.raw" || diff_rc=$?
# SAFETY: an unresolvable range must fail visibly — an empty lookup would pass over work that never ran.
if [ "$diff_rc" -ne 0 ]; then
  pg_log fail "Anti-slop (range=$RANGE, posture=$POSTURE)"
  pg_finding "unresolvable range \"$RANGE\" — no diff to scan ($(head -n 1 "$WORK/diff.err" 2>/dev/null | cut -c1-120))"
  exit 1
fi
lookup_rc=0
awk 'BEGIN{file=""; line=0} \
    /^\+\+\+ b\// {file=substr($0,7); sub(/\t.*$/, "", file); next} \
    /^@@ / {match($0, /\+[0-9]+/); line=substr($0,RSTART+1,RLENGTH-1)+0; next} \
    /^\+/ && !/^\+\+\+/ {printf "%s\t%d\t%s\n", file, line, substr($0,2); line++}' \
  <"$WORK/diff.raw" >"$LOOKUP" || lookup_rc=$?
# SAFETY: a broken lookup pipeline must degrade — a truncated lookup is not a clean scan.
if [ "$lookup_rc" -ne 0 ]; then
  DEGRADED="$DEGRADED lookup(rc=$lookup_rc)"
fi

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
    go|rs|java) OTHER_FILES+=("$f	$lang") ;;
  esac
done < <(cut -f1 "$LOOKUP" | sort -u)

# --- detection ladder ------------------------------------------------------
# An INSTALLED PROFILE owns the patterns its native rules cover; remaining
# patterns still run. Go, Rust and Java have no native lane in v1.
# The map names only pattern IDs; native rules with no pattern equivalent need
# no entry. Suppressions retain the native engine's own semantics.
native_covered_patterns() {
  case "$1" in
    # ts-as-any: native accepts justified assertions, e.g. `// SAFETY: checked` then `x as any`.
    # ts-as-unknown-as: no-chained-type-assertions owns assertion chains.
    # ts-record-literal: native intentionally allows empty accumulators, e.g. `const x: Record<string, T> = {}`.
    # ts-module-mock: native excludes a locally shadowed vi, e.g. `const vi = service; vi.mock("x")`.
    oxlint) printf '%s' 'ts-as-any,ts-as-unknown-as,ts-record-literal,ts-module-mock' ;;
    # ANN401 misses standalone class fields, e.g. `class C:\n    field: Any`;
    # PGH004 has no corresponding pattern rule.
    ruff) printf '%s' 'py-any-annotation' ;;
    # ignore-without-code owns bare ignores; unused-ignore is also kept only
    # for bare comments, since strict mypy reports an unused bare ignore that way.
    # A module-level bare # type: ignore skips the whole file silently in mypy;
    # e.g. `# type: ignore` on line 1 followed by `x: int = "wrong"`.
    # Unlike grep, mypy ignores string text such as `message = "# type: ignore"`.
    mypy) printf '%s' 'py-bare-type-ignore' ;;
  esac
}
#
# "Installed profile" is the profile's own marker in the config, never the mere
# existence of a config file: oxlint keys off the vendored plugin's name, ruff off
# the ANN401 it selects, mypy off the `ignore-without-code` it enables. The config
# candidate lists and the marker strings come from the pattern lib so this file,
# audit-slop.sh and doctor's presence row cannot disagree about what "installed"
# means. Detecting on file existence alone made any project with an oxlint config
# report its entire lint configuration under the anti-slop label.
#
# resolve_engine <marker> <bin-name> <local-bin-path> <config...> -> path,
# unavailable (marker but no executable), or empty (no configured profile).
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
    else
      printf '%s' unavailable
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
# owns survive (mypy has no "run only these codes" flag). `unused-ignore` is
# additionally kept only when its added source line has a bare ignore: mypy's
# strict mode assigns that code instead of `ignore-without-code` to unused ones.
#
# The trailing code is EXTRACTED and matched for exact membership rather than
# regex-matched: passing a `\[(a|b)\]` pattern through `awk -v` gets unescaped once
# by awk's own string processing, leaving `[(a|b)]` — a character class that
# matches any message containing one of those letters, i.e. everything.
parse_mypy_findings() {
  awk -v codes=",$1," -v lk="$LOOKUP" '
  BEGIN {
    while ((read_status = getline source < lk) > 0) {
      split(source, fields, "\t")
      sub(/^[^\t]*\t[^\t]*\t/, "", source)
      if (source ~ /#[[:space:]]*type:[[:space:]]*ignore([^[:alnum:]_]|$)/ &&
          source !~ /#[[:space:]]*type:[[:space:]]*ignore[[:space:]]*\[/)
        bare[fields[1] "\t" fields[2]] = 1
    }
    if (read_status < 0) exit 2
  }
  {
    if (!match($0, /^[^:]+:[0-9]+: error: /)) next
    hdr = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    if (!match(rest, /\[[a-z][a-z-]*\][[:space:]]*$/)) next
    code = substr(rest, RSTART + 1, RLENGTH - 2)
    sub(/\].*$/, "", code)
    split(hdr, p, ":")
    if (index(codes, "," code ",") == 0 &&
        !(code == "unused-ignore" && (p[1] "\t" p[2]) in bare)) next
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

# scan_patterns <file> <lang> [native-covered-ids] -> file<TAB>line<TAB>pattern-id.
# slop_scan_text numbers its own stdin, so the real line numbers are carried in
# a parallel column and re-joined by index.
#
# The content column is rebuilt by cutting the two leading fields off the row, not
# by printing $3: the content still carries its own leading indentation. Insert
# a blank scan line at each gap in source line numbers so a SAFETY comment cannot
# justify a construct separated from it by unchanged code.
scan_patterns() {
  local file="$1" lang="$2" covered="${3:-}" scan_rc=0 join_rc=0
  : > "$WORK/lines"
  : > "$WORK/nums"
  # Numbered scan input is <file-line> TAB <text>. A gap line carries the
  # unchanged line before the next added one and an index entry of 0.
  awk -F'\t' -v f="$file" -v lines="$WORK/lines" -v nums="$WORK/nums" '
    $1 == f {
      if (previous && $2 != previous + 1) { print ($2 - 1) "\t" >> lines; print 0 >> nums }
      previous = $2
      print $2 >> nums
      n = $2
      sub(/^[^\t]*\t[^\t]*\t/, "")
      print n "\t" $0 >> lines
    }' "$LOOKUP"
  [ -s "$WORK/lines" ] || return 0
  slop_scan_text "$lang" --numbered < "$WORK/lines" > "$WORK/hits" || scan_rc=$?
  # SAFETY: slop_scan_text is grep-like — only status 1 means clean; an error must degrade, never pass as a clean scan.
  if [ "$scan_rc" -ge 2 ]; then
    DEGRADED="$DEGRADED scan-$lang(rc=$scan_rc)"
    return 0
  fi
  if [ "$scan_rc" -eq 1 ]; then return 0; fi
  awk -F'\t' -v f="$file" -v nf="$WORK/nums" -v covered="$covered" '
        BEGIN { while ((getline l < nf) > 0) { n[++i] = l } }
        index("," covered ",", "," $2 ",") == 0 {
          printf "%s\t%s\t%s\n", f, n[$1], $2
        }' "$WORK/hits" || join_rc=$?
  # SAFETY: a failed line-number join must degrade — partial output is not a clean scan.
  if [ "$join_rc" -ne 0 ]; then
    DEGRADED="$DEGRADED scan-join-$lang(rc=$join_rc)"
  fi
}

RAW="$WORK/raw"
: > "$RAW"
MODES=""

if [ "${#TS_FILES[@]}" -gt 0 ]; then
  ts_engine="patterns"
  if [ -n "$oxlint_bin" ] && [ "$oxlint_bin" != unavailable ]; then
    if run_native oxlint "$WORK/out" "$oxlint_bin" --format=unix "${TS_FILES[@]}"; then
      ts_engine="oxlint"
      parse_rc=0
      parse_unix_findings "$SLOP_OXLINT_PLUGIN" < "$WORK/out" > "$WORK/ts.native" || parse_rc=$?
      # SAFETY: a failed parser cannot establish native coverage; discard any
      # partial report and run the full pattern lane.
      if [ "$parse_rc" -ne 0 ]; then
        DEGRADED="$DEGRADED oxlint-parse(rc=$parse_rc)"
        ts_engine="patterns"
      else
        cat "$WORK/ts.native" >> "$RAW"
      fi
    fi
  fi
  ts_covered=""
  if [ "$ts_engine" = oxlint ]; then
    ts_covered="$(native_covered_patterns oxlint)"
    ts_engine="oxlint+patterns"
  fi
  for f in "${TS_FILES[@]}"; do scan_patterns "$f" ts "$ts_covered" >> "$RAW"; done
  MODES="$MODES ts=$ts_engine"
fi

# ruff and mypy own disjoint halves of the Python profile (plan D3), so both run
# when installed. If EITHER configured engine fails or is unavailable, discard
# native findings and run the full pattern set; the mode reports the fallback.
if [ "${#PY_FILES[@]}" -gt 0 ]; then
  py_engine=""
  py_covered=""
  py_failed=0
  if [ "$ruff_bin" = unavailable ]; then py_failed=1; ruff_bin=""; fi
  if [ "$mypy_bin" = unavailable ]; then py_failed=1; mypy_bin=""; fi
  if [ -n "$ruff_bin" ]; then
    if run_native ruff "$WORK/out" "$ruff_bin" check --no-cache \
      --output-format=concise --select "$SLOP_RUFF_RULES" "${PY_FILES[@]}"; then
      py_engine="ruff"
      py_covered="$(native_covered_patterns ruff)"
      parse_rc=0
      parse_unix_findings < "$WORK/out" >> "$WORK/py.native" || parse_rc=$?
      # SAFETY: an unparsed native report is untrusted output — its loss must degrade, never pass as clean.
      if [ "$parse_rc" -ne 0 ]; then
        DEGRADED="$DEGRADED ruff-parse(rc=$parse_rc)"
        py_failed=1
      fi
    else
      py_failed=1
    fi
  fi
  if [ -n "$mypy_bin" ]; then
    if run_native mypy "$WORK/out" "$mypy_bin" --no-incremental \
      --cache-dir=/dev/null --no-error-summary "${PY_FILES[@]}"; then
      py_engine="${py_engine:+$py_engine+}mypy"
      py_covered="${py_covered:+$py_covered,}$(native_covered_patterns mypy)"
      parse_rc=0
      parse_mypy_findings "$SLOP_MYPY_CODES" < "$WORK/out" >> "$WORK/py.native" || parse_rc=$?
      # SAFETY: an unparsed native report is untrusted output — its loss must degrade, never pass as clean.
      if [ "$parse_rc" -ne 0 ]; then
        DEGRADED="$DEGRADED mypy-parse(rc=$parse_rc)"
        py_failed=1
      fi
    else
      py_failed=1
    fi
  fi
  if [ -z "$py_engine" ] || [ "$py_failed" = "1" ]; then
    py_engine="patterns"
    rm -f "${WORK:?}/py.native"
    py_covered=""
  else
    cat "$WORK/py.native" >> "$RAW"
    py_engine="$py_engine+patterns"
  fi
  for f in "${PY_FILES[@]}"; do scan_patterns "$f" py "$py_covered" >> "$RAW"; done
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
ratchet_awk_rc=0
ratchet_sort_rc=0
awk -F'\t' -v lk="$LOOKUP" '
  BEGIN { while ((getline l < lk) > 0) { split(l, p, "\t"); added[p[1] "\t" p[2]] = 1 } }
  ($1 "\t" $2) in added { print }' "$RAW" > "$WORK/ratchet.in" 2>"$WORK/ratchet.err" || ratchet_awk_rc=$?
sort -u "$WORK/ratchet.in" > "$WORK/ratchet.out" 2>>"$WORK/ratchet.err" || ratchet_sort_rc=$?
# SAFETY: the ratchet is the diff scope — if it fails, findings are lost or unfiltered, so the row must degrade, never pass.
if [ "$ratchet_awk_rc" -ne 0 ] || [ "$ratchet_sort_rc" -ne 0 ]; then
  DEGRADED="$DEGRADED ratchet(awk-rc=$ratchet_awk_rc,sort-rc=$ratchet_sort_rc)"
fi
HITS="$(cat "$WORK/ratchet.out")"

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
  # SAFETY: $WORK/err exists only once a native engine has run — parser/scan/ratchet degradation must not abort on its absence.
  findings+=("native engine failed to run:${DEGRADED} — degraded to the pattern set ($(head -n 1 "$WORK/err" 2>/dev/null | cut -c1-120 || true))")
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
