#!/usr/bin/env bash
# audit-slop.sh — repo-scoped anti-slop audit (spec 037 T12, plan §4 file 9).
# Usage: audit-slop.sh [--json] [pathspec ...]
#
# Enumerates every evidence-doctrine violation in the work tree's TRACKED files
# so a de-slop cleanup session has a scope contract. Repo-scoped by design; the
# diff-scoped ratchet is the gate's job (skills/process-gate/scripts/check-slop.sh)
# and the turn-time lane is the tripwire hook's.
#
# Detection ladder per language, mirroring check-slop.sh: the native linter when
# the profile config is installed AND its binary resolves, else the shared grep
# pattern set. A native engine that fails to run (exit >= 2) degrades to patterns
# and says so in `notes` — a fallback that reads like a clean result is worse than
# no audit at all.
#
# Exit status is ALWAYS 0, including for a bad flag or a non-repo directory: this
# is an audit, not a gate. Findings live in the output.
#
# Bash 3.2 (macOS): no associative arrays, no mapfile. Per-language state lives in
# $WORK/<name>.<lang> files rather than in name-keyed arrays.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

JSON=0
HAVE_PATHS=0
PATHSPEC=()
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--json] [pathspec ...]"
      exit 0
      ;;
    -*)
      echo "$(basename "$0"): unknown option: $arg" >&2
      echo "usage: $(basename "$0") [--json] [pathspec ...]" >&2
      exit 0
      ;;
    *) PATHSPEC+=("$arg"); HAVE_PATHS=1 ;;
  esac
done

# Pathspecs stay relative to the caller's directory (git's own convention); with
# none, `:/` is git's magic pathspec for the whole work tree.
SCOPE="${PATHSPEC[*]:-.}"
if [ "$HAVE_PATHS" = "0" ]; then PATHSPEC=(":/"); fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  echo "audit-slop: not inside a git work tree — nothing to audit" >&2
  exit 0
fi

# --- pattern lib -----------------------------------------------------------
# Canonical layout first (this skill's sibling hooks/lib), then the per-harness
# copies sync-hooks.sh / onboard-project.sh seed into a project.
SLOP_LIB=""
for cand in \
  "$SKILL_DIR/../../hooks/lib/slop-patterns.sh" \
  "$ROOT/.claude/hooks/lib/slop-patterns.sh" \
  "$ROOT/.agents/hooks/lib/slop-patterns.sh" \
  "$ROOT/.codex/hooks/lib/slop-patterns.sh"; do
  if [ -f "$cand" ]; then SLOP_LIB="$cand"; break; fi
done
if [ -z "$SLOP_LIB" ]; then
  echo "audit-slop: hooks/lib/slop-patterns.sh not found — pattern set unavailable" >&2
  exit 0
fi
# shellcheck source=../../../hooks/lib/slop-patterns.sh
. "$SLOP_LIB"

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t audit-slop)"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/notes"
: > "$WORK/hits"
: > "$WORK/langsum"

note() { printf '%s\n' "$1" >> "$WORK/notes"; }

# --- candidate files -------------------------------------------------------
# In-scope extension and not carved out. -z keeps paths with spaces intact and
# --full-name makes every path repo-relative whatever directory the caller is in.
for lang in $SLOP_LANGS; do : > "$WORK/files.$lang"; done
SCANNED=0
while IFS= read -r -d '' f; do
  slop_path_carved_out "$f" && continue
  lang="$(slop_lang_for_path "$f" 2>/dev/null || true)"
  [ -n "$lang" ] || continue
  # Tracked but deleted in the work tree (uncommitted `git rm`, mid-rebase): a
  # missing path makes a native linter exit >= 2 and degrade the whole language.
  [ -f "$ROOT/$f" ] || continue
  printf '%s\n' "$f" >> "$WORK/files.$lang"
  SCANNED=$((SCANNED + 1))
done < <(git ls-files -z --full-name -- "${PATHSPEC[@]}" 2>/dev/null || true)

# --- engine resolution -----------------------------------------------------
# A config alone is not enough and a binary alone is not enough: the profile has
# to be installed AND runnable, or the native lane is not this project's lane.
#
# "Installed" means the PROFILE's own marker is in the config, never that a config
# file exists — oxlint keys off the vendored plugin's name, ruff off the ANN401 it
# selects, mypy off the `ignore-without-code` it enables (profiles/*/README.md
# § Ownership). Detecting on existence alone reported the project's whole lint
# configuration under the anti-slop label. Marker strings and candidate lists come
# from the pattern lib so this script, the gate row and doctor's presence row
# cannot disagree about what "installed" means.
#
# resolve_engine <marker> <bin-name> <local-bin-path> <config...> -> path on stdout
resolve_engine() {
  local marker="$1" name="$2" local_bin="$3" cand
  shift 3
  for cand in "$@"; do
    [ -f "$ROOT/$cand" ] || continue
    grep -q "$marker" "$ROOT/$cand" || continue
    if [ -x "$ROOT/$local_bin" ]; then
      printf '%s' "$ROOT/$local_bin"
    elif command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
    fi
    return 0
  done
  return 0
}

# shellcheck disable=SC2086 # the SLOP_*_CONFIGS lists are word lists on purpose.
OXLINT="$(resolve_engine "$SLOP_OXLINT_PLUGIN" oxlint node_modules/.bin/oxlint $SLOP_OXLINT_CONFIGS)"
# shellcheck disable=SC2086
RUFF="$(resolve_engine ANN401 ruff .venv/bin/ruff $SLOP_RUFF_CONFIGS)"
# mypy owns the type-flow half of the Python profile and only has a repo-wide
# lane, which is exactly this script's scope.
# shellcheck disable=SC2086
MYPY="$(resolve_engine ignore-without-code mypy .venv/bin/mypy $SLOP_MYPY_CONFIGS)"

# --- finding producers -----------------------------------------------------
# Every producer emits the same 5-field row:
#   lang <TAB> engine <TAB> file <TAB> line <TAB> label

# scan_patterns <lang> <engine-label> — whole-file grep scan, one file at a time
# so slop_scan_text's per-stdin line numbers are the file's own.
scan_patterns() {
  local lang="$1" engine="$2" f
  while IFS= read -r f; do
    slop_scan_text "$lang" < "$ROOT/$f" \
      | awk -F'\t' -v l="$lang" -v e="$engine" -v f="$f" \
          '{ printf "%s\t%s\t%s\t%s\t%s\n", l, e, f, $1, $2 }' || true
  done < "$WORK/files.$lang"
}

# parse_unix <lang> <engine> [rule-filter-ERE] — <path>:<line>:<col>: <message>, the
# shape shared by `oxlint --format=unix` and `ruff check --output-format=concise`.
# With a filter only matching messages survive: that is how the oxlint lane is
# narrowed to the vendored plugin's own rule ids, since oxlint has no per-plugin
# select flag the way ruff has `--select`.
parse_unix() {
  awk -v l="$1" -v e="$2" -v keep="${3:-}" '{
    if (!match($0, /^[^:]+:[0-9]+:[0-9]+:/)) next
    hdr = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    sub(/^[[:space:]]+/, "", rest)
    if (keep != "" && rest !~ keep) next
    split(hdr, p, ":")
    printf "%s\t%s\t%s\t%s\t%s\n", l, e, p[1], p[2], rest
  }'
}

# parse_mypy <comma-separated-codes> — <path>:<line>: error: <message>  [<code>].
# Column numbers are off by default, so this cannot reuse parse_unix; notes and
# hints are dropped, and only the error codes the profile's mypy fragment owns
# survive (mypy has no "run only these codes" flag, so the narrowing happens on the
# output).
#
# The trailing code is EXTRACTED and matched for exact membership rather than
# regex-matched: passing a `\[(a|b)\]` pattern through `awk -v` gets unescaped once
# by awk's own string processing, leaving `[(a|b)]` — a character class that matches
# any message containing one of those letters, i.e. everything.
parse_mypy() {
  awk -v codes=",$1," '{
    if (!match($0, /^[^:]+:[0-9]+: error: /)) next
    hdr = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    if (!match(rest, /\[[a-z][a-z-]*\][[:space:]]*$/)) next
    code = substr(rest, RSTART + 1, RLENGTH - 2)
    sub(/\].*$/, "", code)
    if (index(codes, "," code ",") == 0) next
    split(hdr, p, ":")
    printf "py\tmypy\t%s\t%s\t%s\n", p[1], p[2], rest
  }'
}

# run_native <engine> <outfile> <cmd...> — captures stdout and reports whether the
# tool ran at all. Exit 1 means "found findings" for all three tools; >= 2 means
# the tool itself failed, and its (empty) output must not read as a clean bill.
#
# The file list is passed as arguments, never through xargs: BSD xargs reports its
# own exit 1 for any nonzero child status, which turns a linter's "config broken"
# (>= 2) into "found violations" (1) and silently produces a green audit. An
# argument list long enough to exceed ARG_MAX fails loudly here instead, which is
# the honest outcome.
#
# The note is written by the CALLER, not here: only the caller knows whether the
# pattern lane actually ran for that language. A note claiming "degraded to the
# pattern set" written at the point of failure lied whenever a sibling engine
# survived — ruff exiting 2 while mypy ran left `py_engine=mypy`, so the pattern
# fallback was skipped and ruff's rules were simply dropped under a note that said
# they were covered.
run_native() {
  local engine="$1" out="$2" rc=0
  shift 2
  ( cd "$ROOT" && "$@" ) > "$out" 2>"$WORK/err" || rc=$?
  if [ "$rc" -ge 2 ]; then
    NATIVE_ERR="$engine exited $rc ($(head -n 1 "$WORK/err" | cut -c1-120))"
    return 1
  fi
  return 0
}
NATIVE_ERR=""

# load_file_args <lang> — fills FILE_ARGS with that language's candidate paths.
# A global array because bash 3.2 cannot return one.
FILE_ARGS=()
load_file_args() {
  local f
  FILE_ARGS=()
  while IFS= read -r f; do FILE_ARGS+=("$f"); done < "$WORK/files.$1"
}

# --- TypeScript / JavaScript ----------------------------------------------
if [ -s "$WORK/files.ts" ]; then
  ts_engine="patterns"
  if [ -n "$OXLINT" ]; then
    load_file_args ts
    if run_native oxlint "$WORK/out" "$OXLINT" --format=unix "${FILE_ARGS[@]}"; then
      ts_engine="oxlint"
      parse_unix ts oxlint "$SLOP_OXLINT_PLUGIN" < "$WORK/out" >> "$WORK/hits"
    else
      note "$NATIVE_ERR — degraded to the pattern set for ts"
    fi
  fi
  if [ "$ts_engine" = "patterns" ]; then
    scan_patterns ts patterns >> "$WORK/hits"
  else
    note "ts: $ts_engine lane — pattern ids with no rule in that tool are not reported here (the profile README's known gaps; the tripwire still sees them at turn-time)"
  fi
  printf 'ts\t%s\t%s\t%s\n' "$ts_engine" "$(wc -l < "$WORK/files.ts" | tr -d ' ')" 0 >> "$WORK/langsum"
fi

# --- Python ----------------------------------------------------------------
# ruff and mypy own disjoint rule sets (plan D3), so both run when installed and
# neither double-reports the other. The pattern set is the fallback when neither
# ran AND when EITHER of them failed to run: the pattern lane approximates both
# halves, so falling back cannot under-report, whereas keeping the surviving
# engine's findings drops the failed engine's rules entirely under a summary that
# names a native engine.
if [ -s "$WORK/files.py" ]; then
  py_engine=""
  py_failed=""
  : > "$WORK/py.native"
  load_file_args py
  if [ -n "$RUFF" ]; then
    if run_native ruff "$WORK/out" "$RUFF" check --no-cache \
      --output-format=concise --select "$SLOP_RUFF_RULES" "${FILE_ARGS[@]}"; then
      py_engine="ruff"
      parse_unix py ruff < "$WORK/out" >> "$WORK/py.native"
    else
      py_failed="$NATIVE_ERR"
    fi
  fi
  if [ -n "$MYPY" ]; then
    if run_native mypy "$WORK/out" "$MYPY" --no-incremental --cache-dir=/dev/null \
      --no-error-summary "${FILE_ARGS[@]}"; then
      py_engine="${py_engine:+$py_engine+}mypy"
      parse_mypy "$SLOP_MYPY_CODES" < "$WORK/out" >> "$WORK/py.native"
    else
      py_failed="${py_failed:+$py_failed; }$NATIVE_ERR"
    fi
  fi
  if [ -n "$py_failed" ]; then
    note "$py_failed — degraded to the pattern set for py (the engine that did run is discarded, so no rule is reported as covered when it was not)"
    py_engine=""
  fi
  if [ -z "$py_engine" ]; then
    py_engine="patterns"
    scan_patterns py patterns >> "$WORK/hits"
  else
    cat "$WORK/py.native" >> "$WORK/hits"
    note "py: $py_engine lane — pattern ids with no rule in those tools are not reported here (profiles/python/README.md § Known gaps; the tripwire still sees them at turn-time)"
  fi
  printf 'py\t%s\t%s\t%s\n' "$py_engine" "$(wc -l < "$WORK/files.py" | tr -d ' ')" 0 >> "$WORK/langsum"
fi

# --- Java ------------------------------------------------------------------
# Pattern layer, LIVE (not dormant): Java is a first-class profile whose rows are
# calibrated in profiles/java/README.md. There is deliberately no native lane yet
# — Error Prone / NullAway are javac plugins, so wiring one edits the project's
# build and runs on every compile, which is a different blast radius from a lint
# config. The note says "no native lane" rather than "profile dormant" so a reader
# cannot mistake a live pattern-layer result for an unrun profile.
if [ -s "$WORK/files.java" ]; then
  scan_patterns java patterns >> "$WORK/hits"
  note "java: pattern layer (no native lane) — profiles/java/README.md § Known gaps"
  printf 'java\tpatterns\t%s\t%s\n' "$(wc -l < "$WORK/files.java" | tr -d ' ')" 0 >> "$WORK/langsum"
fi

# --- Go, Rust --------------------------------------------------------------
# Pattern layer only: both profiles ship dormant (spec §4 non-goal), so there is
# no installed-config lane to prefer yet.
for lang in go rs; do
  [ -s "$WORK/files.$lang" ] || continue
  scan_patterns "$lang" patterns >> "$WORK/hits"
  note "$lang: profile dormant — pattern layer only"
  printf '%s\tpatterns\t%s\t%s\n' "$lang" "$(wc -l < "$WORK/files.$lang" | tr -d ' ')" 0 >> "$WORK/langsum"
done

# Stable order (file, then line) and de-duplicated: a native linter can report the
# same line twice when two configs overlap.
sort -t$'\t' -k3,3 -k4,4n -k5,5 -u "$WORK/hits" -o "$WORK/hits"

# Per-language finding counts, folded back into the summary rows. The counts are
# read with getline rather than an NR == FNR pass, which silently misfires when
# the first file is empty (no findings is the expected case).
awk -F'\t' -v hits="$WORK/hits" '
  BEGIN { while ((getline row < hits) > 0) { split(row, p, "\t"); n[p[1]]++ } }
  { printf "%s\t%s\t%s\t%d\n", $1, $2, $3, n[$1] + 0 }
' "$WORK/langsum" > "$WORK/langsum.counted"
mv "$WORK/langsum.counted" "$WORK/langsum"

TOTAL="$(wc -l < "$WORK/hits" | tr -d ' ')"
FILES_HIT="$(cut -f3 "$WORK/hits" | sort -u | grep -c . || true)"

# --- output ----------------------------------------------------------------
if [ "$JSON" = "1" ]; then
  scope_json="$(printf '%s' "$SCOPE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"tool":"audit-slop","scope":"%s","files_scanned":%d,"files_with_findings":%d,"findings_total":%d,"languages":[' \
    "$scope_json" "$SCANNED" "$FILES_HIT" "$TOTAL"
  awk -F'\t' '
    NR > 1 { printf "," }
    { printf "{\"lang\":\"%s\",\"engine\":\"%s\",\"files_scanned\":%d,\"findings\":%d}", $1, $2, $3, $4 }
  ' "$WORK/langsum"
  printf '],"findings":['
  awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    NR > 1 { printf "," }
    { printf "{\"lang\":\"%s\",\"engine\":\"%s\",\"file\":\"%s\",\"line\":%d,\"label\":\"%s\"}", \
        $1, $2, esc($3), $4, esc($5) }
  ' "$WORK/hits"
  printf '],"notes":['
  awk '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    NR > 1 { printf "," }
    { printf "\"%s\"", esc($0) }
  ' "$WORK/notes"
  printf '],"doctrine":"%s"}\n' "$SLOP_DOCTRINE_REF"
  exit 0
fi

lang_label() {
  case "$1" in
    ts) printf 'TypeScript/JavaScript\n' ;;
    py) printf 'Python\n' ;;
    go) printf 'Go\n' ;;
    rs) printf 'Rust\n' ;;
    java) printf 'Java\n' ;;
  esac
}

printf 'anti-slop audit — %s (%d tracked files in scope)\n' "$SCOPE" "$SCANNED"

if [ ! -s "$WORK/langsum" ]; then
  printf '\nno files in a covered language (.ts .tsx .js .jsx .py .go .rs .java) after carve-outs\n'
  exit 0
fi

while IFS=$'\t' read -r lang engine files count; do
  printf '\n%s — %s (%s files, %s findings)\n' "$(lang_label "$lang")" "$engine" "$files" "$count"
  awk -F'\t' -v l="$lang" '$1 == l { printf "  %s:%s  %s\n", $3, $4, $5 }' "$WORK/hits"
done < "$WORK/langsum"

printf '\nsummary\n'
awk -F'\t' '{ printf "  %-4s %-12s %5s files  %5s findings\n", $1, $2, $3, $4 }' "$WORK/langsum"
printf '  total %s findings in %s of %s files scanned\n' "$TOTAL" "$FILES_HIT" "$SCANNED"

if [ -s "$WORK/notes" ]; then
  printf '\nnotes\n'
  sed 's/^/  - /' "$WORK/notes"
fi

printf '\ndoctrine: %s\n' "$SLOP_DOCTRINE_REF"
exit 0
