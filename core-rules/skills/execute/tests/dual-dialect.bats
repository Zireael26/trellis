#!/usr/bin/env bats
# dual-dialect.bats — exercises the REAL tick.sh against the THREE checkbox
# shapes across the TWO loci it must handle.
#
# LIST locus  — prefix-anchored "- [ ]" lines. Three shapes feed it:
#   • flat tasks.md     - [x] `path` — description   (located by backtick path)
#   • plan steps        - [ ] **Step N: label**       (located by "Step N:" label)
#   • Done-criteria      - [ ] free text               (located by text substring)
# TABLE locus — canonical tasks.md "| ID | Task | … | Status |" rows. The first
#   data cell is the ID (located by EXACT equality, T1 != T10); the LAST cell is
#   the "[ ]" Status that gets flipped.
#
# THE CONTRACT: the receipt is the GATE, not file content. tick.sh validates the
# receipt and flips the checkbox; it writes NOTHING ELSE. There is NO in-file
# append. The receipt lives in the transcript / last_assistant_message, which is
# what stop-verify.sh actually checks.
#
# New signature:  tick.sh <tasks-file> <section> <locator> <receipt>
#   <section> "" = whole file; otherwise scopes to the "## <section>" header up
#   to the next "## " header — this is what resolves locator collisions. The
#   match is EXACT (section arg and header are BOTH normalized — leading "#" +
#   surrounding whitespace stripped — and compared for equality), so the caller
#   passes the COMPLETE header line and "Phase 1" never leaks into "Phase 10".
#
# Run:  bats core-rules/skills/execute/tests/dual-dialect.bats

setup() {
  # Resolve the script from the test file location: tests/ -> skills/execute.
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/tick.sh"
  # The two canonical stop-verify sources, for the drift-guard. From tests/:
  #   .. -> skills/execute ; ../../.. -> core-rules ; then hooks/ and codex/hooks/.
  CORE_RULES="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  STOP_VERIFY="$CORE_RULES/hooks/stop-verify.sh"
  CODEX_STOP_VERIFY="$CORE_RULES/codex/hooks/stop-verify.sh"
  WORK="$(mktemp -d)"
  # A well-formed receipt: filled exit + filled diff, single line.
  RECEIPT='<!-- dod-receipt cmd="bats tests/foo.bats" exit=0 diff="+12/-3 (2 files)" -->'
}

teardown() {
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}

# ===========================================================================
# LIST locus
# ===========================================================================

# --- LIST-FLAT-VALID --------------------------------------------------------
@test "LIST-FLAT-VALID: flat box flips, exit 0, NO receipt text written" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks for spec 042

## Phase 1 — scaffolding

- [ ] `core-rules/skills/execute/scripts/tick.sh` — implement the tick contract
- [ ] `core-rules/skills/execute/tests/dual-dialect.bats` — dual-dialect suite

## Phase 2 — wiring

- [ ] `core-rules/skills/execute/SKILL.md` — author the skill body
EOF
  run "$SCRIPT" "$f" "## Phase 1 — scaffolding" '`core-rules/skills/execute/scripts/tick.sh`' "$RECEIPT"
  [ "$status" -eq 0 ]
  # The line flipped to "- [x]" — and is OTHERWISE byte-identical to the
  # original (no receipt text appended). We assert the exact expected line.
  run grep -F -- '- [x] `core-rules/skills/execute/scripts/tick.sh` — implement the tick contract' "$f"
  [ "$status" -eq 0 ]
  # No receipt text anywhere in the file.
  [ "$(grep -c -F -- 'dod-receipt' "$f")" -eq 0 ]
  # Exactly one box flipped; the other two stay unchecked.
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 2 ]
}

# --- LIST-COLLISION-PATH ----------------------------------------------------
@test "LIST-COLLISION-PATH: same path in two phases — only the in-section box flips" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 0 — seeding

- [ ] `src/shared.ts` — phase 0 reference

## Phase 8b — final

- [ ] `src/shared.ts` — phase 8b reference
EOF
  run "$SCRIPT" "$f" "## Phase 8b — final" '`src/shared.ts`' "$RECEIPT"
  [ "$status" -eq 0 ]
  # Phase 8b box flipped...
  run grep -F -- '- [x] `src/shared.ts` — phase 8b reference' "$f"
  [ "$status" -eq 0 ]
  # ...and the Phase 0 box with the SAME path stayed unchecked.
  run grep -F -- '- [ ] `src/shared.ts` — phase 0 reference' "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
}

# --- LIST-PLAN-VALID --------------------------------------------------------
@test "LIST-PLAN-VALID: nested '- [ ] **Step 2: Verify**' flips" {
  f="$WORK/plan.md"
  cat > "$f" <<'EOF'
# Plan: execute skill

## Task 9: build the loop

- [ ] **Step 1: Read the task list**
- [ ] **Step 2: Verify** run the verification command
- [ ] **Step 3: Commit**
EOF
  run "$SCRIPT" "$f" "## Task 9: build the loop" 'Step 2:' "$RECEIPT"
  [ "$status" -eq 0 ]
  run grep -F -- '- [x] **Step 2: Verify** run the verification command' "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- 'dod-receipt' "$f")" -eq 0 ]
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 2 ]
}

# --- LIST-COLLISION-STEP ----------------------------------------------------
@test "LIST-COLLISION-STEP: 'Step 1:' under two Tasks — only the in-section box flips" {
  f="$WORK/plan.md"
  cat > "$f" <<'EOF'
# Plan

## Task 9: alpha

- [ ] **Step 1: do alpha**

## Task 10: beta

- [ ] **Step 1: do beta**
EOF
  run "$SCRIPT" "$f" "## Task 10: beta" 'Step 1:' "$RECEIPT"
  [ "$status" -eq 0 ]
  run grep -F -- '- [x] **Step 1: do beta**' "$f"
  [ "$status" -eq 0 ]
  run grep -F -- '- [ ] **Step 1: do alpha**' "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
}

# --- LIST-EMBEDDED-TOKEN ----------------------------------------------------
@test "LIST-EMBEDDED-TOKEN: '- [ ]' inside the description survives; 2nd run is a byte-identical no-op" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 1

- [ ] fix the - [ ] parser bug
EOF
  run "$SCRIPT" "$f" "## Phase 1" 'parser bug' "$RECEIPT"
  [ "$status" -eq 0 ]
  # Only the LEADING box flipped; the embedded "- [ ]" token is intact.
  run grep -F -- '- [x] fix the - [ ] parser bug' "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- 'dod-receipt' "$f")" -eq 0 ]
  # Idempotency: re-run is a no-op, file byte-identical.
  cp "$f" "$f.after1"
  run "$SCRIPT" "$f" "## Phase 1" 'parser bug' "$RECEIPT"
  [ "$status" -eq 0 ]
  run cmp -s "$f" "$f.after1"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# TABLE locus  (canonical tasks.md "| ID | … | Status |")
# ===========================================================================

# --- TABLE-VALID ------------------------------------------------------------
@test "TABLE-VALID: T2 row LAST cell flips, exit 0, NO receipt text written" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Tasks

| ID | Task | Est. | Depends | Covers (spec §3 criterion) | Status |
|----|------|------|---------|------|--------|
| T1 | scaffold the loop | ~2h | — | c1 | [ ] |
| T2 | implement the tick | ~2h | T1 | c2 | [ ] |
| T3 | wire enforcement | ~1h | T1 | c3 | [ ] |
EOF
  run "$SCRIPT" "$f" "" "T2" "$RECEIPT"
  [ "$status" -eq 0 ]
  # The T2 row's Status cell flipped to [x].
  run grep -F -- '| T2 | implement the tick | ~2h | T1 | c2 | [x] |' "$f"
  [ "$status" -eq 0 ]
  # No receipt text written; exactly one Status cell flipped.
  [ "$(grep -c -F -- 'dod-receipt' "$f")" -eq 0 ]
  [ "$(grep -c -F -- '| [x] |' "$f")" -eq 1 ]
}

# --- TABLE-T1-NOT-T10 -------------------------------------------------------
@test "TABLE-T1-NOT-T10: locator T1 flips only T1, T10 stays unchecked (exact-ID)" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
## Tasks

| ID | Task | Est. | Depends | Covers | Status |
|----|------|------|---------|--------|--------|
| T1 | first | ~2h | — | c1 | [ ] |
| T10 | tenth | ~1h | — | c10 | [ ] |
EOF
  run "$SCRIPT" "$f" "" "T1" "$RECEIPT"
  [ "$status" -eq 0 ]
  run grep -F -- '| T1 | first | ~2h | — | c1 | [x] |' "$f"
  [ "$status" -eq 0 ]
  # T10 untouched — substring T1 must NOT have matched T10.
  run grep -F -- '| T10 | tenth | ~1h | — | c10 | [ ] |' "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- '| [x] |' "$f")" -eq 1 ]
}

# --- TABLE-LASTCELL-NOT-DESC ------------------------------------------------
@test "TABLE-LASTCELL-NOT-DESC: a '[ ]' in the description cell is untouched; only Status flips" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
## Tasks

| ID | Task | Est. | Depends | Covers | Status |
|----|------|------|---------|--------|--------|
| T5 | handle the [ ] empty token in the parser | ~2h | — | c5 | [ ] |
EOF
  run "$SCRIPT" "$f" "" "T5" "$RECEIPT"
  [ "$status" -eq 0 ]
  # The description's "[ ]" survived; only the trailing Status cell flipped.
  run grep -F -- '| T5 | handle the [ ] empty token in the parser | ~2h | — | c5 | [x] |' "$f"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- 'dod-receipt' "$f")" -eq 0 ]
}

# ===========================================================================
# GATE / refusal  (both loci)
# ===========================================================================

# --- MULTILINE-INJECT (THE critical regression) -----------------------------
@test "MULTILINE-INJECT: multi-line receipt with a forged 2nd line → exit 3, file BYTE-UNCHANGED" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 1

- [ ] `core-rules/skills/execute/scripts/tick.sh` — implement
EOF
  cp "$f" "$f.orig"
  # Line 1 is a perfectly valid receipt; line 2 forges a checked box.
  multi="$(printf '%s\n%s' "$RECEIPT" '- [x] `evil` INJECTED')"
  run "$SCRIPT" "$f" "## Phase 1" '`core-rules/skills/execute/scripts/tick.sh`' "$multi"
  [ "$status" -eq 3 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
  # Belt and suspenders: the forged token never reached the file.
  [ "$(grep -c -F -- 'INJECTED' "$f")" -eq 0 ]
}

# --- NORECEIPT-LIST ---------------------------------------------------------
@test "NORECEIPT-LIST: empty receipt (list) → exit 3, unchanged" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
## Phase 1

- [ ] `src/x.ts` — do x
EOF
  cp "$f" "$f.orig"
  run "$SCRIPT" "$f" "## Phase 1" '`src/x.ts`' ''
  [ "$status" -eq 3 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
}

# --- NORECEIPT-TABLE --------------------------------------------------------
@test "NORECEIPT-TABLE: empty receipt (table) → exit 3, unchanged" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
| ID | Task | Status |
|----|------|--------|
| T1 | do x | [ ] |
EOF
  cp "$f" "$f.orig"
  run "$SCRIPT" "$f" "" "T1" ''
  [ "$status" -eq 3 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
}

# --- MALFORMED-LIST ---------------------------------------------------------
@test "MALFORMED-LIST: receipt missing exit= (list) → exit 3, unchanged" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
## Phase 1

- [ ] `src/x.ts` — do x
EOF
  cp "$f" "$f.orig"
  bad='<!-- dod-receipt cmd="bats tests/foo.bats" diff="+12/-3 (2 files)" -->'
  run "$SCRIPT" "$f" "## Phase 1" '`src/x.ts`' "$bad"
  [ "$status" -eq 3 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
}

# --- MALFORMED-TABLE --------------------------------------------------------
@test "MALFORMED-TABLE: receipt missing exit= (table) → exit 3, unchanged" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
| ID | Task | Status |
|----|------|--------|
| T1 | do x | [ ] |
EOF
  cp "$f" "$f.orig"
  bad='<!-- dod-receipt cmd="bats tests/foo.bats" diff="+12/-3 (2 files)" -->'
  run "$SCRIPT" "$f" "" "T1" "$bad"
  [ "$status" -eq 3 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
}

# --- AMBIGUOUS --------------------------------------------------------------
@test "AMBIGUOUS: locator matching >1 unchecked box in-scope → exit 5, unchanged" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
## Phase 1

- [ ] `src/shared.ts` — first reference
- [ ] `src/shared.ts` — second reference
EOF
  cp "$f" "$f.orig"
  run "$SCRIPT" "$f" "## Phase 1" '`src/shared.ts`' "$RECEIPT"
  [ "$status" -eq 5 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
}

# --- NOTFOUND ---------------------------------------------------------------
@test "NOTFOUND: locator matching 0 boxes → exit 4" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
## Phase 1

- [ ] `src/x.ts` — do x
EOF
  run "$SCRIPT" "$f" "## Phase 1" '`does/not/exist.ts`' "$RECEIPT"
  [ "$status" -eq 4 ]
}

# --- ARITY ------------------------------------------------------------------
@test "ARITY: wrong number of args → exit 2" {
  f="$WORK/tasks.md"
  echo '- [ ] `x` — y' > "$f"
  run "$SCRIPT" "$f" "## Phase 1" '`x`'
  [ "$status" -eq 2 ]
}

# ===========================================================================
# SECTION scope boundary  (EXACT full-header match: "Phase 1" must not reopen
# at "Phase 10" — and bare-token sections that equal no header refuse safely)
# ===========================================================================

# --- SECTION-PREFIX ---------------------------------------------------------
@test "SECTION-PREFIX: section 'Phase 1' flips only the Phase-1 box; 'Phase 10' (same locator) stays unchecked" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 1

- [ ] `src/dup.ts` — shared reference

## Phase 10

- [ ] `src/dup.ts` — shared reference
EOF
  run "$SCRIPT" "$f" "## Phase 1" '`src/dup.ts`' "$RECEIPT"
  [ "$status" -eq 0 ]
  # The Phase-1 box flipped...
  run grep -F -- '- [x] `src/dup.ts` — shared reference' "$f"
  [ "$status" -eq 0 ]
  # ...exactly one box flipped (scope did NOT reopen at Phase 10)...
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
  # ...and the Phase-10 box with the SAME locator stayed unchecked.
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 1 ]
}

# --- SECTION-PREFIX-IDEMPOTENT ----------------------------------------------
@test "SECTION-PREFIX-IDEMPOTENT: Phase-1 already [x] → exit 0 no-op; must NOT leak into Phase 10 and flip ITS box" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 1

- [x] `src/dup.ts` — shared reference

## Phase 10

- [ ] `src/dup.ts` — shared reference
EOF
  cp "$f" "$f.orig"
  run "$SCRIPT" "$f" "## Phase 1" '`src/dup.ts`' "$RECEIPT"
  [ "$status" -eq 0 ]
  # Byte-unchanged: the no-op did NOT leak past the boundary into Phase 10.
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
  # Phase 10 box is still unchecked.
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 1 ]
}

# --- SECTION-EXACT ----------------------------------------------------------
# Full-header sections with a textual suffix: ticking the EXACT "Phase 1"
# header flips only that box; the "Phase 10" sibling (same locator) is untouched.
@test "SECTION-EXACT: full-header section flips only its box; sibling 'Phase 10' header stays unchecked" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 1 — first

- [ ] `src/dup.ts` — shared reference

## Phase 10 — tenth

- [ ] `src/dup.ts` — shared reference
EOF
  run "$SCRIPT" "$f" "## Phase 1 — first" '`src/dup.ts`' "$RECEIPT"
  [ "$status" -eq 0 ]
  # Exactly the Phase-1 box flipped; Phase 10 did NOT reopen.
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 1 ]
  # The flipped box sits under Phase 1; the Phase-10 box is still unchecked.
  awk '/^## Phase 1 — first/{p=1;next} /^## /{p=0} p && /- \[x\]/{f=1} END{exit !f}' "$f"
  awk '/^## Phase 10 — tenth/{p=1;next} /^## /{p=0} p && /- \[ \]/{f=1} END{exit !f}' "$f"
}

# --- SECTION-SUFFIX-NOLEAK (the surviving-critical proof) -------------------
# A BARE token "Phase 1" equals NO header (every header has a suffix), so under
# exact-equality scoping it matches nothing -> exit 4, file BYTE-UNCHANGED. This
# proves bare-prefix sections can no longer leak into Phase 1.5 / 1-rework / 1_x
# / 10 / 1b. Then the FULL header "Phase 1 — x" flips exactly its one box.
@test "SECTION-SUFFIX-NOLEAK: bare 'Phase 1' matches no header → exit 4 unchanged; full header flips only its box" {
  f="$WORK/tasks.md"
  cat > "$f" <<'EOF'
# Tasks

## Phase 1 — x

- [ ] `src/dup.ts` — shared reference

## Phase 1.5 — y

- [ ] `src/dup.ts` — shared reference

## Phase 1-rework — z

- [ ] `src/dup.ts` — shared reference

## Phase 1_x — w

- [ ] `src/dup.ts` — shared reference

## Phase 10 — v

- [ ] `src/dup.ts` — shared reference

## Phase 1b — u

- [ ] `src/dup.ts` — shared reference
EOF
  cp "$f" "$f.orig"
  # Bare "Phase 1" equals no full header → exit 4, NOTHING flips, byte-unchanged.
  run "$SCRIPT" "$f" "Phase 1" '`src/dup.ts`' "$RECEIPT"
  [ "$status" -eq 4 ]
  run cmp -s "$f" "$f.orig"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 0 ]
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 6 ]
  # The FULL header "Phase 1 — x" flips exactly its one box; siblings untouched.
  run "$SCRIPT" "$f" "Phase 1 — x" '`src/dup.ts`' "$RECEIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c -F -- '- [x]' "$f")" -eq 1 ]
  [ "$(grep -c -F -- '- [ ]' "$f")" -eq 5 ]
  # The flipped box is the one under "Phase 1 — x", not a sibling.
  awk '/^## Phase 1 — x/{p=1;next} /^## /{p=0} p && /- \[x\]/{f=1} END{exit !f}' "$f"
}

# ===========================================================================
# NO-TRAILING-NEWLINE — a file with no final newline keeps no final newline.
# ===========================================================================

# --- NO-TRAILING-NEWLINE ----------------------------------------------------
@test "NO-TRAILING-NEWLINE: file lacking a final newline keeps it absent after a valid tick" {
  f="$WORK/tasks.md"
  # printf (not heredoc) so the last byte is content, NOT a newline.
  printf '## Phase 1\n\n- [ ] `src/x.ts` — do x' > "$f"
  # Sanity: the fixture really has no trailing newline.
  [ "$(tail -c1 "$f" | wc -l | tr -d ' ')" -eq 0 ]
  run "$SCRIPT" "$f" "## Phase 1" '`src/x.ts`' "$RECEIPT"
  [ "$status" -eq 0 ]
  # The box flipped...
  run grep -F -- '- [x] `src/x.ts` — do x' "$f"
  [ "$status" -eq 0 ]
  # ...and the file STILL has no trailing newline (awk did not add one).
  [ "$(tail -c1 "$f" | wc -l | tr -d ' ')" -eq 0 ]
}

# ===========================================================================
# DRIFT-GUARD — extract the operative ERE from THREE files, assert byte-equal.
# ===========================================================================
@test "DRIFT-GUARD: canonical receipt ERE is byte-identical in tick.sh and BOTH stop-verify.sh copies" {
  [ -f "$SCRIPT" ]
  [ -f "$STOP_VERIFY" ]
  [ -f "$CODEX_STOP_VERIFY" ]
  # Extract the OPERATIVE single-quoted literal from each file (the assignment
  # in tick.sh / codex stop-verify, and the `grep -Eq '...'` pattern in the
  # Claude stop-verify). The ERE contains no single-quote, so the
  # single-quote-delimited capture is unambiguous across all three surrounding
  # syntaxes. NOT a hardcoded 4th copy — each value is pulled from its file.
  a="$(grep -o "'<!-- dod-receipt[^']*'" "$SCRIPT"            | head -1 | sed "s/^'//; s/'$//")"
  b="$(grep -o "'<!-- dod-receipt[^']*'" "$STOP_VERIFY"       | head -1 | sed "s/^'//; s/'$//")"
  c="$(grep -o "'<!-- dod-receipt[^']*'" "$CODEX_STOP_VERIFY" | head -1 | sed "s/^'//; s/'$//")"
  # Each extraction must be non-empty (a missing literal would silently pass an
  # "" == "" comparison).
  [ -n "$a" ]
  [ -n "$b" ]
  [ -n "$c" ]
  [ "$a" = "$b" ] && [ "$b" = "$c" ]
}

# ===========================================================================
# SCOPE-EXPR DRIFT-GUARD — the section-scope header-DETECTION + normalization +
# equality test appears TWICE in tick.sh (scan pass ~L154/L166/L171/L172, flip
# pass ~L244/L256/L261/L262). Extract those operative lines from EACH pass and
# assert byte-identity after stripping leading whitespace (the two awk programs
# are indented differently) so the two copies can never silently diverge — on
# what counts as a header OR on how it is scoped — mirrors the receipt-ERE guard.
# ===========================================================================
@test "SCOPE-EXPR-DRIFT-GUARD: the section-scope expression is byte-identical in the scan pass and the flip pass" {
  [ -f "$SCRIPT" ]
  # The four operative source lines (in document order they alternate between
  # the two passes). After stripping leading indentation each appears EXACTLY
  # twice — once per pass. Strip the indentation, sort, and confirm every line
  # is duplicated; then build the per-pass concatenation and compare. The set
  # covers BOTH the header-DETECTION line ("have_section && /^## /" — what
  # counts as a section header) AND the normalization + scope-equality lines, so
  # the two passes cannot silently diverge on either question.
  norm="$(grep -nE 'function hdrnorm|have_section && /\^## / \{|hnorm = hdrnorm\(\$0\)|in_scope = \(hnorm == snorm\)' "$SCRIPT")"
  # Four distinct logical lines, each present in BOTH passes → 8 hits total.
  [ "$(printf '%s\n' "$norm" | grep -c .)" -eq 8 ]
  # Reduce to the bare expression text (drop "NN:" prefix and leading spaces).
  bare="$(printf '%s\n' "$norm" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
  # hdrnorm definition: identical in both passes.
  hd="$(printf '%s\n' "$bare" | grep -F 'function hdrnorm' | sort -u)"
  [ "$(printf '%s\n' "$hd" | grep -c .)" -eq 1 ]
  [ -n "$hd" ]
  # header-DETECTION expression: identical in both passes (what counts as a
  # "## " section header must match byte-for-byte across the scan and flip
  # passes, else the passes could split a scope differently).
  hh="$(printf '%s\n' "$bare" | grep -F 'have_section && /^## / {' | sort -u)"
  [ "$(printf '%s\n' "$hh" | grep -c .)" -eq 1 ]
  [ -n "$hh" ]
  # hnorm assignment: identical in both passes.
  ha="$(printf '%s\n' "$bare" | grep -F 'hnorm = hdrnorm($0)' | sort -u)"
  [ "$(printf '%s\n' "$ha" | grep -c .)" -eq 1 ]
  [ -n "$ha" ]
  # in_scope equality test: identical in both passes.
  is="$(printf '%s\n' "$bare" | grep -F 'in_scope = (hnorm == snorm)' | sort -u)"
  [ "$(printf '%s\n' "$is" | grep -c .)" -eq 1 ]
  [ -n "$is" ]
}
