#!/usr/bin/env bats
# Tests for check-security-diff.sh — the adapter to security-gate/run-diff.sh.
#
# This is a thin adapter: its whole job is to locate run-diff.sh and pass its
# exit code through verbatim (0 pass / 2 warn / 1 fail) when the child printed
# the matching `Overall:` verdict; no verdict, or a disagreeing one, FAILs.
# SECURITY_GATE_SKIP=1 is never a pass: an unperformed scan reports BLOCKED in
# every mode. An unavailable gate FAILs. We stub
# run-diff.sh in the fixture tree (mirroring how check-secrets plants its
# allowlist) so the passthrough can be exercised without semgrep/gitleaks/a
# baseline. The stub echoes its argv so we can assert --no-llm is added iff
# PG_MODE=push.
#
# Exit codes: 0=pass, 1=fail, 2=warn (per pg_exit_code / run-diff contract).

setup() {
  # Isolate the adapter from the real sibling security-gate, so absence and
  # locator mutations cannot accidentally fall back to a host/payload scanner.
  SOURCE_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  ADAPTER="$BATS_TEST_TMPDIR/adapter"
  mkdir -p "$ADAPTER/scripts/lib"
  cp "$SOURCE_SCRIPTS/check-security-diff.sh" "$ADAPTER/scripts/"
  cp "$SOURCE_SCRIPTS/lib/common.sh" "$SOURCE_SCRIPTS/lib/diff-base.sh" "$ADAPTER/scripts/lib/"
  SCRIPT="${PG_TEST_SCRIPT:-$ADAPTER/scripts/check-security-diff.sh}"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
    # run_check gates HEAD~1..HEAD; its base must resolve for config to load.
    git commit --allow-empty -q -m "change"
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
# echoes a marker + its argv and the verdict run-diff prints for that rc, then
# exits with the requested code. A fourth argument overrides the verdict line
# ("none" prints none).
stub_run_diff() {
  local rc="$1" dir="${2:-.claude}" mode="${3:-755}" verdict="${4:-}"
  local d="$PROJECT_DIR/$dir/skills/security-gate/scripts"
  if [ -z "$verdict" ]; then
    case "$rc" in 0) verdict=MERGEABLE ;; 2) verdict="NEEDS CHANGES" ;; *) verdict=BLOCKED ;; esac
  fi
  local line="Overall: $verdict"
  [ "$verdict" != none ] || line=""
  mkdir -p "$d"
  cat > "$d/run-diff.sh" <<EOF
#!/usr/bin/env bash
echo "STUB-RUN-DIFF argv: \$*"
echo "$line"
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

# --- fail closed when absent (adapter has no sibling payload in this fixture) ---

@test "missing security-gate in both project and payload -> fail (exit 1)" {
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"security-gate unavailable"* ]]
  [[ "$output" != *"skipped"* ]]
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
# The invocation marker distinguishes a real security FAIL from a missing-gate
# FAIL. The locator mutation below proves -x loses that marker; absence must
# still fail closed, never restore the old warn-skip.
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
  [[ "$output" == *"STUB-RUN-DIFF"* ]] || { echo "$output"; false; }  # the 644 script was actually invoked
  [[ "$output" != *"not installed"* ]] || { echo "$output"; false; }  # NOT downgraded to a warn-skip
  [[ "$output" != *"skipped"* ]]
}

# --- SECURITY_GATE_SKIP ---

@test "push mode SECURITY_GATE_SKIP=1 -> BLOCKED (exit 1), never a pass" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=push SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" != *"STUB-RUN-DIFF"* ]]
}

@test "merge mode SECURITY_GATE_SKIP=1 -> BLOCKED (exit 1), run-diff not invoked" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=merge SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" != *"STUB-RUN-DIFF"* ]]
}

@test "SECURITY_GATE_SKIP=1 with PG_MODE unset is merge mode -> BLOCKED" {
  stub_run_diff 0
  run bash -c "cd '$PROJECT_DIR' && SECURITY_GATE_SKIP=1 '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

# --- a verdict is required, not just an exit code ---

@test "run-diff rc 0 without an Overall line fails (push mode)" {
  stub_run_diff 0 .claude 755 none
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=push '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"without an Overall verdict"* ]] || { echo "$output"; false; }
}

@test "run-diff rc 0 without an Overall line fails (merge mode)" {
  stub_run_diff 0 .claude 755 none
  run bash -c "cd '$PROJECT_DIR' && PG_MODE=merge '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "a silent fallback run-diff under .agents fails" {
  stub_run_diff 0 .agents 755 none
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "run-diff rc 0 with Overall: BLOCKED fails" {
  stub_run_diff 0 .claude 755 BLOCKED
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"reported Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "two Overall lines are not one verdict and fail" {
  local d="$PROJECT_DIR/.claude/skills/security-gate/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "Overall: BLOCKED"\necho "Overall: MERGEABLE"\nexit 0\n' > "$d/run-diff.sh"
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "an exported set function cannot forge the adapter's pass" {
  stub_run_diff 1
  run env 'BASH_FUNC_set%%=() { printf "\nOverall: MERGEABLE\n"; exit 0; }' \
    bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"STUB-RUN-DIFF"* ]] || { echo "$output"; false; }
}

# --- .agents fallback ---

@test "fallback: run-diff under .agents is found when .claude absent" {
  stub_run_diff 0 ".agents"
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB-RUN-DIFF"* ]]
}

# --- in-tree core-rules/ fallback (the Trellis clone itself) ---
#
# In the repository that authors the gate, the skill IS the tree: a linked
# worktree has no seeded .claude/skills and no .agents, so this hard gate used to
# downgrade itself to a non-blocking warn on exactly the checkout where the gate
# is being changed. Last among project fallbacks; the executing payload wins.

@test "fallback: run-diff under core-rules/ is found when neither harness dir exists" {
  stub_run_diff 0 "core-rules-marker"
  rm -rf "$PROJECT_DIR/core-rules-marker"
  local d="$PROJECT_DIR/core-rules/skills/security-gate/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "STUB-CORE-RULES argv: $*"\necho "Overall: MERGEABLE"\nexit 0\n' > "$d/run-diff.sh"
  chmod 755 "$d/run-diff.sh"
  run_check
  [ "$status" -eq 0 ]
  grep -Fq 'STUB-CORE-RULES' <<<"$output"
}

@test "fallback precedence: .claude wins over project in-tree when payload is absent" {
  stub_run_diff 0 ".claude"
  local d="$PROJECT_DIR/core-rules/skills/security-gate/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "STUB-CORE-RULES argv: $*"\necho "Overall: BLOCKED"\nexit 1\n' > "$d/run-diff.sh"
  chmod 755 "$d/run-diff.sh"
  run_check
  [ "$status" -eq 0 ]
  grep -Fq 'STUB-RUN-DIFF' <<<"$output"
  if grep -Fq 'STUB-CORE-RULES' <<<"$output"; then
    echo "in-tree copy shadowed the installed one"; echo "$output"; false
  fi
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

# Locator mutation: the 644 positive control loses its invocation under -x.
# Even this rejected candidate must now FAIL, not restore the old warn-skip.
@test "RED driver: -x locator rejects the 644 file but missing gate now fails closed" {
  # 1) Copy the WHOLE scripts/ tree (check-security-diff.sh + lib/common.sh + the
  #    rest) into a fresh mktemp -d so the copy's SKILL_DIR/lib/common.sh source
  #    resolves. A bare single-file copy would crash command-not-found at the
  #    `. "$SKILL_DIR/scripts/lib/common.sh"` line instead of exercising the
  #    -x/-f locator we are testing.
  local SRC COPY GATE
  SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  COPY="$(mktemp -d "$BATS_TEST_TMPDIR/adapter-copy.XXXXXX")"
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
  [[ "$(grep -cF -- '-f "$cand"' "$GATE")" -eq 0 ]] || { grep -nF -- '-f "$cand"' "$GATE"; false; }  # the -f predicate is gone

  # 3) Point the harness at the copy. PG_TEST_SCRIPT makes the comment-promised
  #    plumbing real for any child; SCRIPT is the lever run_check actually reads
  #    (setup() already ran, so the export alone cannot re-derive SCRIPT).
  export PG_TEST_SCRIPT="$GATE"
  SCRIPT="$PG_TEST_SCRIPT"

  # 4) The same 644 run-diff scenario as the green invocation control.
  ( cd "$PROJECT_DIR" \
    && printf 'aws_secret_access_key = AKIAIOSFODNN7EXAMPLE\n' > leak.env \
    && git add leak.env \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "add secret" )

  stub_run_diff 1 ".claude" 644   # located, mode 644 (NOT executable), would FAIL if invoked
  [ ! -x "$PROJECT_DIR/.claude/skills/security-gate/scripts/run-diff.sh" ]  # sanity: really non-exec

  run_check

  # The locator mutation loses the scan, but cannot reopen a warn-skip path.
  [ "$status" -eq 1 ]
  [[ "$output" == *"security-gate unavailable"* ]]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" != *"STUB-RUN-DIFF"* ]]

  # Glob-free cleanup on a verified-nonempty full path (mirrors teardown; never a
  # glob on a possibly-empty var, which would trip the rm safety prompt).
  [ -n "${COPY:-}" ] && [ -d "$COPY" ] && rm -rf "$COPY"
}
