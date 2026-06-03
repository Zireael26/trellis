#!/usr/bin/env bash
# tick.sh — the R1 "checkbox drift" isolation point for the execute skill.
#
# ALL checkbox mutation goes through here; the execute loop NEVER hand-edits a
# checkbox. This script is the load-bearing invariant carrier: no checkbox is
# ticked without a valid Definition-of-Done receipt. Within a single execute
# turn the Stop hook does not gate each per-task tick, so the receipt gate MUST
# live here, not in prose.
#
# Usage:  tick.sh <tasks-file> <section> <locator> <receipt>
#
#   <section>  scopes the search to lines from the "## <section>" header up to
#              the next "## " header. The match is EXACT, not a prefix: the
#              <section> arg and each "## " header are BOTH normalized (strip
#              leading "#" chars + surrounding whitespace) and compared for
#              EQUALITY. So the caller passes the COMPLETE header line text;
#              section "Phase 1" never leaks into "Phase 10" / "Phase 1.5" /
#              "Phase 1b" / "Phase 1-rework" (those are distinct headers, and a
#              section that equals no header yields exit 4 — a safe refuse).
#              An EMPTY string ("") means the whole file. Scoping is what
#              resolves locator collisions (a plan repeats "Step N: Commit" 10x;
#              a backtick path repeats across phases).
#   <locator>  selects exactly one unchecked checkbox WITHIN the scope.
#   <receipt>  the canonical Definition-of-Done marker (CLAUDE.md:43). The
#              receipt is the GATE — it is VALIDATED here but is NOT written
#              into the file. The receipt lives in the transcript /
#              last_assistant_message (what stop-verify actually checks), not
#              in the tasks file.
#
# Two checkbox loci, auto-detected during the scan:
#   LIST locus — a line matching the PREFIX-anchored unchecked pattern
#     ^[[:space:]]*- \[ \]  whose text CONTAINS <locator> as a FIXED string.
#     Flip the LEADING "- [ ]" to "- [x]" (prefix-anchored sub) so a "- [ ]"
#     token embedded in the description is NEVER touched. Covers flat tasks.md
#     rows, plan "- [ ] **Step N:**" steps, and Done-criteria boxes.
#   TABLE locus — a table row (line starts with "|") whose FIRST data cell,
#     trimmed, EXACTLY equals <locator> (T1 must NOT match T10) AND whose LAST
#     cell, trimmed, is "[ ]". Flip that LAST cell "[ ]" -> "[x]" (never the
#     first "[ ]" on the row — a Task/Covers cell may legitimately hold "[ ]").
#
# Behavior (in order):
#   1. Arity must be 4, else exit 2.
#   2. Receipt gate, BEFORE any file read/scan that could mutate:
#        (a) a receipt containing a newline is rejected -> exit 3 (kills the
#            multi-line-receipt injection vector);
#        (b) the receipt is validated against the canonical receipt ERE; missing
#            / empty / malformed / multi-line -> exit 3, file BYTE-UNCHANGED.
#   3. Within the section scope, count unchecked checkboxes matching <locator>
#      across both loci. >1 -> exit 5 (ambiguous, file unchanged). 0 unchecked:
#        - if an already-CHECKED box matches the locator -> exit 0 no-op
#          (idempotent re-run, file byte-unchanged);
#        - else -> exit 4 (not found, file unchanged).
#   4. Exactly 1 unchecked -> flip that single box. The ONLY byte change is the
#      checkbox itself ("- [ ]"->"- [x]" or the table's last cell). NO append:
#      the receipt string is NOT written into the file. Atomic write
#      (mktemp in the file's own dir + mv). exit 0.
#
# Portability: bash 3.2 (no namerefs/declare -n, mapfile/readarray, associative
# arrays); BSD awk/sed safe (no GNU-only flags; awk+mktemp+mv, never sed -i);
# clean under "shellcheck --severity=warning". Self-contained — embeds the
# canonical receipt ERE as a literal (does NOT source hooks/lib), so it runs on
# hook-less harnesses.
#
# Injection safety: <section>, <locator>, <receipt> are UNTRUSTED. They are
# never interpolated into the awk program text, never eval'd, never used as a
# printf format string. Section and locator reach awk only via the environment
# (ENVIRON[], which does no escape processing), never via -v. The receipt never
# reaches awk at all (it is validated, then discarded — never written).

set -euo pipefail

# SKILL_DIR resolution precedent (mirrors core-rules/skills/process-gate):
# tick.sh lives in scripts/, so this yields the skill root. Kept for parity /
# future use; tick.sh itself is self-contained and sources nothing.
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export SKILL_DIR

# --- Canonical receipt grammar (CLAUDE.md:43) -------------------------------
# Marker (literal): <!-- dod-receipt cmd="…" exit=<int> diff="+N/-M (K files)" -->
# (the … is U+2026 HORIZONTAL ELLIPSIS).
#
# RECEIPT_ERE below is copied BYTE-FOR-BYTE from the validating extended-regex
# in core-rules/hooks/stop-verify.sh (the `grep -Eq` pattern around line 361)
# and core-rules/codex/hooks/stop-verify.sh (the RECEIPT_RE assignment). A
# drift-guard test (tests/dual-dialect.bats) extracts the operative literal from
# all three files and asserts byte-equality — this is the single-source
# tripwire. Do NOT edit one without the others.
RECEIPT_ERE='<!-- dod-receipt .*cmd=.*exit=[0-9].*diff=.*\+[0-9].*-->'

usage() {
  printf 'usage: tick.sh <tasks-file> <section> <locator> <receipt>\n' >&2
}

# --- Step 1: arg arity ------------------------------------------------------
if [ "$#" -ne 4 ]; then
  usage
  exit 2
fi

TASKS_FILE="$1"
SECTION="$2"
LOCATOR="$3"
RECEIPT="$4"

# --- Step 2: validate the receipt FIRST (before locating / touching file) ---
# (a) Reject any receipt containing a newline. A multi-line receipt is the
#     injection vector: line 1 is a valid marker, line 2+ forges a checked box.
#     bash-3.2-safe: $'\n' is ANSI-C quoting (a literal LF), NOT command
#     substitution — $(printf '\n') would strip the trailing newline and yield
#     "" which matches every receipt.
nl=$'\n'
case "$RECEIPT" in
  *"$nl"*)
    printf 'tick.sh: multi-line dod-receipt rejected for locator %s — no tick written.\n' "$LOCATOR" >&2
    exit 3
    ;;
esac

# (b) Validate against the canonical receipt ERE. printf '%s' (never
#     printf "$RECEIPT") keeps the untrusted receipt as data, not a format
#     string. grep reads it from stdin; the ERE is the embedded literal, never
#     derived from any argument.
if ! printf '%s' "$RECEIPT" | grep -Eq "$RECEIPT_ERE"; then
  printf 'tick.sh: invalid or missing dod-receipt for locator %s — no tick written.\n' "$LOCATOR" >&2
  exit 3
fi

# --- File must exist now that the receipt is known good ---------------------
if [ ! -f "$TASKS_FILE" ]; then
  printf 'tick.sh: tasks file not found: %s\n' "$TASKS_FILE" >&2
  exit 4
fi

# --- Step 3: classify matches within the section scope ----------------------
# Single awk pass. SECTION and LOCATOR arrive via ENVIRON (NOT -v: -v processes
# backslash escapes and is an injection surface; ENVIRON does neither). The
# receipt is NOT passed — it never enters awk. The pass emits three integers:
#   unchecked  — boxes (LIST or TABLE) matching the locator that are UNCHECKED
#   checked    — boxes matching the locator that are already CHECKED (idempotency)
#
# Scope rule: with an empty SECTION the whole file is in scope. Otherwise scope
# opens at each "## " header whose NORMALIZED text EXACTLY EQUALS the normalized
# SECTION arg (both stripped of leading "#" chars + surrounding whitespace via
# hdrnorm) and closes at the next "## " header. EXACT equality — not a prefix —
# so "Phase 1" never matches "Phase 10" / "Phase 1b" / "Phase 1.5".
#
# LIST detection is PREFIX-ANCHORED via a regex on $0 (^[[:space:]]*- \[ \]),
# never index($0,"- [ ]") — that is the embedded-token fix: a description
# containing the text "- [ ]" must NOT be counted as an unchecked box.
# TABLE detection keys on FIRST-cell EXACT equality (T1 != T10) and LAST-cell.
COUNTS="$(
  TICK_SECTION="$SECTION" TICK_LOC="$LOCATOR" awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function hdrnorm(s) { gsub(/^#+[[:space:]]*/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    BEGIN {
      loc     = ENVIRON["TICK_LOC"]
      # Normalize the SECTION arg ONCE: strip leading "#" chars + surrounding
      # whitespace so it compares EXACTLY against each normalized header.
      snorm = hdrnorm(ENVIRON["TICK_SECTION"])
      have_section = (length(snorm) > 0)
      in_scope = (have_section ? 0 : 1)
      unchecked = 0
      checked = 0
    }
    # Section scoping on "## " headers (only when a section was requested).
    have_section && /^## / {
      # EXACT full-header scope: normalize THIS header the SAME way as the
      # section arg and scope on EQUALITY. "Phase 1" thus never matches
      # "Phase 10" / "Phase 1b" / "Phase 1.5" — those normalize to distinct
      # strings. This expression MUST stay byte-identical in the flip pass.
      hnorm = hdrnorm($0)
      in_scope = (hnorm == snorm) ? 1 : 0;
      next
    }
    in_scope == 0 { next }

    # TABLE locus: row starts with "|". Split on "|"; first data cell is $2,
    # last cell is $(NF-1) given the trailing "|". Exact-equality on the ID.
    /^[ \t]*\|/ {
      n = split($0, cell, "|")
      if (n >= 3) {
        first = trim(cell[2])
        last  = trim(cell[n - 1])
        if (first == loc) {
          if (last == "[ ]") { unchecked++ }
          else if (last == "[x]") { checked++ }
        }
      }
      next
    }

    # LIST locus: prefix-anchored unchecked / checked, locator as fixed string.
    {
      if (index($0, loc) > 0) {
        if ($0 ~ /^[ \t]*- \[ \]/) { unchecked++ }
        else if ($0 ~ /^[ \t]*- \[x\]/) { checked++ }
      }
    }
    END { print unchecked, checked }
  ' "$TASKS_FILE"
)"
UNCHECKED="${COUNTS%% *}"
CHECKED="${COUNTS##* }"

# --- Act on the counts ------------------------------------------------------
if [ "$UNCHECKED" -gt 1 ]; then
  printf 'tick.sh: ambiguous locator %s in section "%s" — matches %s unchecked boxes.\n' "$LOCATOR" "$SECTION" "$UNCHECKED" >&2
  exit 5
fi

if [ "$UNCHECKED" -eq 0 ]; then
  # Idempotency: the locator already points at a CHECKED box → safe no-op.
  if [ "$CHECKED" -ge 1 ]; then
    exit 0
  fi
  printf 'tick.sh: locator %s in section "%s" matched no unchecked box.\n' "$LOCATOR" "$SECTION" >&2
  exit 4
fi

# --- Step 4: exactly one unchecked match → flip it, NO append ---------------
# Section + locator via ENVIRON; neither touches the awk program text. The
# receipt is NOT involved here. `flipped` guards against touching any later
# line. The ONLY byte change is the single checkbox.
DIR="$(dirname "$TASKS_FILE")"
TMP="$(mktemp "$DIR/.tick.XXXXXX")"
# Best-effort cleanup if we die before the atomic mv.
trap 'rm -f "$TMP"' EXIT

# Record whether the original file ends in a trailing newline. awk's print adds
# one newline per record, so a file that lacked a final newline would gain one.
# $(tail -c1) strips a trailing newline in command substitution: a NON-empty
# result means the last byte is content (NO trailing newline); an empty result
# means the last byte was a newline (HAS trailing newline). We restore the
# original state after the awk pass so the only byte change is the checkbox.
ORIG_HAS_NL=1
if [ -n "$(tail -c1 "$TASKS_FILE")" ]; then ORIG_HAS_NL=0; fi

# FS=OFS="|" so that assigning a TABLE field rebuilds $0 with "|" as separator
# (the default OFS=" " would turn every pipe into a space and corrupt the
# table). LIST lines contain no "|", so $0 is a single field and rebuilds
# verbatim; the LIST sub() operates on $0 directly without an OFS rebuild.
TICK_SECTION="$SECTION" TICK_LOC="$LOCATOR" awk '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function hdrnorm(s) { gsub(/^#+[[:space:]]*/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
  BEGIN {
    FS = "|"; OFS = "|"
    loc     = ENVIRON["TICK_LOC"]
    # Normalize the SECTION arg ONCE: strip leading "#" chars + surrounding
    # whitespace so it compares EXACTLY against each normalized header.
    snorm = hdrnorm(ENVIRON["TICK_SECTION"])
    have_section = (length(snorm) > 0)
    in_scope = (have_section ? 0 : 1)
    flipped = 0
  }
  # Header lines: re-scope. $0 has no "|" so it prints back verbatim.
  have_section && /^## / {
    # EXACT full-header scope: normalize THIS header the SAME way as the
    # section arg and scope on EQUALITY. "Phase 1" thus never matches
    # "Phase 10" / "Phase 1b" / "Phase 1.5" — those normalize to distinct
    # strings. This expression MUST stay byte-identical in the scan pass.
    hnorm = hdrnorm($0)
    in_scope = (hnorm == snorm) ? 1 : 0;
    print $0
    next
  }
  {
    if (flipped == 0 && in_scope == 1) {
      # TABLE locus.
      if ($0 ~ /^[ \t]*\|/ && NF >= 3) {
        first = trim($2)
        last  = trim($(NF - 1))
        if (first == loc && last == "[ ]") {
          sub(/\[ \]/, "[x]", $(NF - 1))
          flipped = 1
          print $0
          next
        }
      }
      # LIST locus: prefix-anchored unchecked + fixed-string locator. The
      # sub() is anchored to the LEADING box so an embedded "- [ ]" in the
      # description is never touched.
      else if ($0 ~ /^[ \t]*- \[ \]/ && index($0, loc) > 0) {
        sub(/- \[ \]/, "- [x]")
        flipped = 1
        print $0
        next
      }
    }
    print $0
  }
' "$TASKS_FILE" > "$TMP"

# Restore the original's no-trailing-newline state if it lacked one. $(cat …)
# strips ALL trailing newlines; awk added exactly one (the original's last byte
# was content), so this is a byte-perfect restore. bash performs the command
# substitution BEFORE the redirection truncates $TMP, so reading and writing the
# same file here is safe.
if [ "$ORIG_HAS_NL" -eq 0 ]; then
  printf '%s' "$(cat "$TMP")" > "$TMP"
fi

# Preserve mode of the original where possible (best-effort; ignore failure).
chmod "$(stat -f '%Lp' "$TASKS_FILE" 2>/dev/null || echo 644)" "$TMP" 2>/dev/null || true

mv "$TMP" "$TASKS_FILE"
trap - EXIT
exit 0
