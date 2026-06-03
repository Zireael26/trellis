#!/usr/bin/env bats
# Tests for check-security-diff.sh — the adapter to security-gate/run-diff.sh.
#
# This is a thin adapter: its whole job is to locate run-diff.sh and pass its
# exit code through verbatim (0 pass / 2 warn / 1 fail), with two non-blocking
# escape hatches — SECURITY_GATE_SKIP=1 (deliberate skip -> pass/0) and an
# absent security-gate (warn-skip -> 2, never fail). We therefore stub
# run-diff.sh in the fixture tree (mirroring how check-secrets plants its
# allowlist) so the passthrough can be exercised without semgrep/gitleaks/a
# baseline. The stub echoes its argv so we can assert --no-llm is added iff
# PG_MODE=push.
#
# Exit codes: 0=pass, 1=fail, 2=warn (per pg_exit_code / run-diff contract).

setup() {
  # SCRIPT is overridable (PG_TEST_SCRIPT) so the red-green driver case can point
  # the SAME 644-non-executable run-diff scenario at a pre-fix (-x) copy of the
  # script under a full scripts/ tree — see the "RED driver" @test at the bottom
  # ("pre-fix -x located-run-diff predicate warn-skips the 644 file (fail-OPEN)").
  # That case sed-flips the copy's predicate -f -> -x, exports PG_TEST_SCRIPT,
  # AND reassigns SCRIPT (setup() runs before the @test body, so the export alone
  # cannot re-derive SCRIPT). Default is the on-disk script; normal runs are
  # unaffected.
  SCRIPT="${PG_TEST_SCRIPT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-security-diff.sh}"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  unset PG_MODE
  unset SECURITY_GATE_SKIP
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Plant a stub run-diff.sh under the project's security-gate skill. The stub
# echoes a marker + its argv, then exits with the requested code.
stub_run_diff() {
  local rc="$1" dir="${2:-.claude}" mode="${3:-755}"
  local d="$PROJECT_DIR/$dir/skills/security-gate/scripts"
  mkdir -p "$d"
  cat > "$d/run-diff.sh" <<EOF
#!/usr/bin/env bash
echo "STUB-RUN-DIFF argv: \$*"
exit $rc
EOF
  chmod "$mode" "$d/run-diff.sh"
}

run_check() {
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

# --- exit-code passthrough ---

@test "passthrough: run-diff rc 0 -> pass (exit 0)" {
  stub_run_diff 0
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

@test "passthrough: run-diff rc 2 -> warn (exit 2)" {
  stub_run_diff 2
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

@test "passthrough: run-diff rc 1 -> fail (exit 1) and output echoed" {
  stub_run_diff 1
  run_check
  [ "$status" -eq 1 ]
  # Critical: a fail must still echo run-diff's output (set -e must not have
  # swallowed it on the non-zero capture).
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

# --- warn-skip when absent ---

@test "warn-skip: security-gate not installed -> warn (exit 2), not fail" {
  # No stub planted.
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"security-gate not installed"* ]]
}

# --- HIGH-1/HIGH-3 regression: located-but-non-executable run-diff.sh ---
#
# A present-but-mode-644 run-diff.sh is the steady state after a fresh clone /
# tarball / mirror-sync that does not preserve the exec bit (cp without -p,
# archive extraction, core.fileMode=false). The location test MUST be -f (a
# regular file), not -x (executable). With -f the located 644 script is invoked
# via `bash` and its REAL rc (here: 1, a Critical secret found) flows through —
# the gate stays hard. With the pre-fix -x test the 644 file fails the predicate,
# RUNDIFF stays empty, and the script warn-skips (rc 2, "security-gate not
# installed") — fail-OPEN: a Critical secret in the diff slips the merge gate.
#
# We assert on BOTH the rc (1, the gate's own rc — not the warn-skip rc 2) AND
# the absence of the "not installed" finding text, so this case cannot pass
# against the -x version. The "RED driver" @test at the bottom of this file
# ("pre-fix -x located-run-diff predicate warn-skips the 644 file (fail-OPEN)")
# drives this exact scenario against a pre-fix (-x) copy via PG_TEST_SCRIPT and
# asserts the inverse outcome — proving these assertions genuinely discriminate
# -x from -f rather than passing tautologically.
@test "located run-diff.sh present but non-executable (644) is still invoked (real rc passes through), not warn-skipped" {
  # Narrative fidelity: stage a file carrying a fake secret in the diff. The
  # stub ignores argv content — rc 1 IS the simulated Critical finding — but a
  # real diff makes the fail-OPEN scenario concrete.
  ( cd "$PROJECT_DIR" \
    && printf 'aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n' > leak.env \
    && git add leak.env \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "add secret" )

  stub_run_diff 1 ".claude" 644   # located, mode 644 (NOT executable), returns FAIL
  [ ! -x "$PROJECT_DIR/.claude/skills/security-gate/scripts/run-diff.sh" ]  # sanity: really non-exec

  run_check
  [ "$status" -eq 1 ]                                  # the gate's own rc, passed through
  [[ "$output" == *"STUB-RUN-DIFF"* ]]                 # the 644 script was actually invoked
  [[ "$output" != *"not installed"* ]]                 # NOT downgraded to a warn-skip
  [[ "$output" != *"skipped"* ]]
}

# --- SECURITY_GATE_SKIP ---

@test "SECURITY_GATE_SKIP=1 -> pass (exit 0), run-diff not invoked" {
  stub_run_diff 1   # would fail if invoked
  run bash -c "cd '$PROJECT_DIR' && SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  [[ "$output" != *"STUB-RUN-DIFF"* ]]
}

# --- .agents fallback ---

@test "fallback: run-diff under .agents is found when .claude absent" {
  stub_run_diff 0 ".agents"
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

# --- --no-llm keyed on PG_MODE ---

@test "PG_MODE=push -> --no-llm passed to run-diff" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=push '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-llm"* ]]
}

@test "PG_MODE=merge (or unset) -> --no-llm NOT passed" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=merge '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--no-llm"* ]]
}

# --- RED driver: pre-fix (-x) located-run-diff predicate fails OPEN on a 644 file ---
#
# This is the CI-enforced RED half (DL-P7-08 item 2) of the green 644 case above:
# it drives the IDENTICAL 644-non-executable run-diff scenario against a pre-fix
# COPY of the gate whose locator predicate is sed-flipped from [ -f "$cand" ]
# back to [ -x "$cand" ]. Against that copy the 644 (non-exec) run-diff.sh fails
# the -x test, RUNDIFF stays empty, and the gate warn-skips (rc 2, "not
# installed", stub never invoked) — the fail-OPEN: a Critical secret slips an
# ALWAYS-HARD merge gate. By ASSERTING that buggy outcome (rc 2 + "not installed"
# + no STUB-RUN-DIFF marker) this case stays green while proving the on-disk -f
# fix is what makes the green 644 case pass. It is the exact inverse of that case,
# so the two together demonstrate the assertions discriminate -x from -f and are
# not tautological (DL-P5-11 red-green mandate).
@test "RED driver: pre-fix -x located-run-diff predicate warn-skips the 644 file (fail-OPEN)" {
  # 1) Copy the WHOLE scripts/ tree (check-security-diff.sh + lib/common.sh + the
  #    rest) into a fresh mktemp -d so the copy's SKILL_DIR/lib/common.sh source
  #    resolves. A bare single-file copy would crash command-not-found at the
  #    `. "$SKILL_DIR/scripts/lib/common.sh"` line instead of exercising the
  #    -x/-f locator we are testing.
  local SRC COPY GATE
  SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  COPY="$(mktemp -d)"
  cp -R "$SRC" "$COPY/"                 # -> $COPY/scripts/{check-security-diff.sh,lib/common.sh,...}
  GATE="$COPY/scripts/check-security-diff.sh"

  # 2) sed-flip the located-run-diff predicate in the COPY back to the pre-fix -x.
  #    Single-quote the program so the bats shell does not expand $cand to empty;
  #    write to a temp then mv (in-place -i is non-portable across BSD/GNU sed).
  sed 's/-f "$cand"/-x "$cand"/' "$GATE" > "$GATE.tmp" && mv "$GATE.tmp" "$GATE"
  # The rewrite drops the exec bit (umask on the temp + mv); run_check execs
  # $SCRIPT directly (not via bash), so restore it or we'd see status 126.
  chmod +x "$GATE"
  # grep-confirm the substitution actually hit (a sed miss should fail loudly
  # HERE, not as a confusing assertion failure later). -F -- guards the dash.
  grep -qF -- '-x "$cand"' "$GATE"
  # Use -F (fixed string): without it the leading `-f`-as-flag is dodged by `--`
  # but `$` is a regex end-anchor, so a plain `grep -c` would report 0 even when
  # the predicate is PRESENT — a tautological guard. -F makes this a real check.
  [[ "$(grep -cF -- '-f "$cand"' "$GATE")" -eq 0 ]]  # the -f predicate is gone

  # 3) Point the harness at the copy. PG_TEST_SCRIPT makes the comment-promised
  #    plumbing real for any child; SCRIPT is the lever run_check actually reads
  #    (setup() already ran, so the export alone cannot re-derive SCRIPT).
  export PG_TEST_SCRIPT="$GATE"
  SCRIPT="$PG_TEST_SCRIPT"

  # 4) The SAME 644 run-diff scenario as the green case: a real secret staged in
  #    the diff, a located-but-mode-644 (non-exec) run-diff.sh returning FAIL.
  ( cd "$PROJECT_DIR" \
    && printf 'aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n' > leak.env \
    && git add leak.env \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "add secret" )

  stub_run_diff 1 ".claude" 644   # located, mode 644 (NOT executable), would FAIL if invoked
  [ ! -x "$PROJECT_DIR/.claude/skills/security-gate/scripts/run-diff.sh" ]  # sanity: really non-exec

  run_check

  # 5) Assert RED against the pre-fix copy — the exact inverse of the green case:
  [ "$status" -eq 2 ]                                  # warn-skip rc (NOT the gate's own rc 1)
  [[ "$output" == *"not installed"* ]]                 # downgraded to a warn-skip ...
  [[ "$output" == *"skipped"* ]]                       # ... fail-OPEN
  [[ "$output" != *"STUB-RUN-DIFF"* ]]                 # the 644 script was NEVER invoked

  # Glob-free cleanup on a verified-nonempty full path (mirrors teardown; never a
  # glob on a possibly-empty var, which would trip the rm safety prompt).
  [ -n "${COPY:-}" ] && [ -d "$COPY" ] && rm -rf "$COPY"
}
