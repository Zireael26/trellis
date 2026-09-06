#!/usr/bin/env bats
# Tests for lib/code-reviewer.sh — the canonical reviewer ladder (rungs 1/2/3).
# Covers Phase 1 reviewer-core contract:
#   - ladder resolution (rung 1 operator override wins)
#   - rung 2 LLM path (happy + fail-open) via a stubbed `claude`
#   - rung 3 deterministic fallback (committed-secret critical; clean → empty)
#   - JSON-envelope AND raw-diff stdin shapes both accepted
#   - fail-open: ALWAYS exit 0, ALWAYS valid {"findings":[...]} JSON
#   - recursion guard (TRELLIS_REVIEW_IN_PROGRESS=1 skips the LLM rung)
#
# PORTABLE: no absolute machine paths (mirror-clean for the public template).
# Paths resolve from $BATS_TEST_DIRNAME via helpers.bash; temp stubs live under
# $BATS_TMPDIR. The real `claude` on the host PATH is NEVER invoked: rung-3
# tests force-skip the LLM rung with the recursion-guard sentinel, and rung-2
# tests shadow `claude` with a local stub via a prepended PATH dir.

load helpers

LIB="$HOOKS_DIR/lib/code-reviewer.sh"

# A diff line that trips the rung-3 AWS-key critical. AKIA + 16 chars (== the
# AKIA[0-9A-Z]{16} regex). The leading single '+' marks it as an ADDED line.
SECRET_DIFF='diff --git a/conf.py b/conf.py
--- a/conf.py
+++ b/conf.py
@@ -0,0 +1 @@
+aws_key = "AKIAIOSFODNN7EXAMPLE"'

# A clean added-line diff with no secrets / debuggers.
CLEAN_DIFF='diff --git a/app.py b/app.py
--- a/app.py
+++ b/app.py
@@ -0,0 +1 @@
+def add(a, b): return a + b'

# --- stub builders --------------------------------------------------------
# Write an executable `claude` stub into a fresh temp dir; echo that dir so the
# caller can prepend it to PATH. The stub IGNORES stdin/args and prints $1.
# Because main() gates rung 2 on `command -v claude` and run_with_timeout
# exec's `claude` (both PATH-resolved), a prepended stub dir shadows the real
# binary for both.
make_claude_stub() {
  local body="$1" dir
  dir="$(mktemp -d "$BATS_TMPDIR/claudestub.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'cat >/dev/null 2>&1 || true'   # drain stdin like real claude
    printf '%s\n' "$body"
  } >"$dir/claude"
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}

# Build a {diff, autonomy_level, decisions_log} envelope with jq so embedded
# newlines in the diff are escaped correctly.
make_envelope() {
  jq -nc --arg d "$1" '{diff: $d, autonomy_level: 3, decisions_log: ""}'
}

# Run the reviewer while keeping its visible degradation channel separate from
# the one-line stdout envelope. Sets status/output/stderr.
run_reviewer() {
  local input="$1" stderr_file
  stderr_file="$(mktemp "$BATS_TEST_TMPDIR/reviewer-stderr.XXXXXX")"
  if output="$(printf '%s' "$input" | bash "$LIB" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  stderr="$(cat "$stderr_file")"
  rm -f "$stderr_file"
}

# Write a reviewer stand-in that records execution before behaving like a hung
# child. The timeout-runner failure guards must reject it before this body runs.
make_hanging_reviewer() {
  local countfile="$1" stub
  stub="$(mktemp "$BATS_TEST_TMPDIR/hanging-reviewer.XXXXXX")"
  cat > "$stub" <<EOF
#!/usr/bin/env bash
printf x >> "$countfile"
# SAFETY: 2 s is the test-only uncapped-reviewer stand-in; the timeout setup guard must return before the stand-in starts.
sleep 2
EOF
  chmod +x "$stub"
  printf '%s' "$stub"
}

make_perl_free_bindir() {
  local out src cmd
  out="$(mktemp -d "$BATS_TEST_TMPDIR/perlfree.XXXXXX")"
  for cmd in bash sleep; do
    src="$(command -v "$cmd")"
    ln -s "$src" "$out/$cmd"
  done
  printf '%s' "$out"
}

# Assert $output is exactly one single-line JSON object with a .findings array.
# Prefer jq strict validation; fall back to a structural grep when jq is absent
# (the core itself is jq-optional, so the suite must not hard-require jq here).
assert_valid_findings() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$output" | jq -e '(type=="object") and (.findings|type=="array")' >/dev/null
  else
    # Structural fallback: leading '{', a "findings" key, an array bracket.
    printf '%s' "$output" | grep -Eq '^\{.*"findings"[[:space:]]*:[[:space:]]*\[.*\][[:space:]]*\}$'
  fi
  # $() already stripped the single trailing newline; internal newlines (a
  # multi-line / multi-value emission, contract violation) would make wc>0.
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -eq 0 ]
}

# =========================================================================
# Rung 1: operator override ($CODE_REVIEWER_CMD) wins.
# =========================================================================
@test "rung1: CODE_REVIEWER_CMD override is exec'd and its output returned" {
  stub_dir="$(mktemp -d "$BATS_TMPDIR/rev1.XXXXXX")"
  cat >"$stub_dir/myreviewer" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s\n' '{"findings":[{"severity":"minor","file":"x","line":7,"msg":"from-override","confidence":0.5}]}'
EOF
  chmod +x "$stub_dir/myreviewer"

  export CODE_REVIEWER_CMD="$stub_dir/myreviewer"
  run bash "$LIB" <<<"$SECRET_DIFF"
  unset CODE_REVIEWER_CMD
  rm -rf "$stub_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"from-override"'* ]] || { echo "$output"; false; }
  # Override won, so the rung-3 AWS-key critical must NOT appear.
  [[ "$output" != *"AWS access key"* ]] || { echo "$output"; false; }
  assert_valid_findings
}

# =========================================================================
# Rung 2: LLM happy path — stubbed claude emits valid findings, which are
# returned verbatim (NOT the rung-3 deterministic output). This is the only
# test that proves rung 2 actually executes + normalize_findings works: it
# feeds a CLEAN diff, so a fall-through to rung 3 would yield {"findings":[]}
# and the distinctive "from-llm-stub" assertion would fail.
# =========================================================================
@test "rung2: stubbed claude output is normalized and returned (clean diff)" {
  stub_path="$(make_claude_stub \
    "printf '%s\\n' '{\"findings\":[{\"severity\":\"minor\",\"file\":\"a.py\",\"line\":3,\"msg\":\"from-llm-stub\",\"confidence\":0.4}]}'")"

  PATH_BACKUP="$PATH"; export PATH="$stub_path:$PATH"
  run bash "$LIB" <<<"$(make_envelope "$CLEAN_DIFF")"
  export PATH="$PATH_BACKUP"; rm -rf "$stub_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"from-llm-stub"'* ]] || { echo "$output"; false; }
  assert_valid_findings
}

# =========================================================================
# Rung 2 fail-open: garbage from claude → fall through to rung 3, still 0.
# (claude is NOT shadowed away; it runs, emits prose, normalize_findings
# rejects it, ladder degrades to the deterministic rung on the same input.)
# =========================================================================
@test "fail-open: garbage claude output visibly degrades and falls through to rung 3" {
  stub_path="$(make_claude_stub "printf '%s\\n' 'I am not JSON, just chatty prose.'")"

  PATH_BACKUP="$PATH"; export PATH="$stub_path:$PATH"
  run_reviewer "$SECRET_DIFF"
  export PATH="$PATH_BACKUP"; rm -rf "$stub_path"

  [ "$status" -eq 0 ]
  assert_valid_findings
  [ "$(printf '%s' "$output" | jq -r '.status')" = "degraded" ]
  [[ "$stderr" == *'code-reviewer: review degraded'* ]] || { echo "$stderr"; false; }
  # Fell through to rung 3 on the secret diff → the critical is recovered.
  [[ "$output" == *'"critical"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"AWS access key"* ]]
}

@test "fail-open: claude nonzero visibly degrades to rung 3 with valid JSON" {
  stub_path="$(make_claude_stub "exit 7")"

  PATH_BACKUP="$PATH"; export PATH="$stub_path:$PATH"
  run_reviewer "$CLEAN_DIFF"
  export PATH="$PATH_BACKUP"; rm -rf "$stub_path"

  [ "$status" -eq 0 ]
  assert_valid_findings
  [ "$(printf '%s' "$output" | jq -r '.status')" = "degraded" ]
  [[ "$stderr" == *'code-reviewer: review degraded'* ]] || { echo "$stderr"; false; }
  [ "$(printf '%s' "$output" | jq -c '.findings')" = '[]' ]
}

@test "timeout runner: Perl unavailable never starts an uncapped reviewer" {
  COUNT="$BATS_TEST_TMPDIR/perl-missing.count"; : > "$COUNT"
  reviewer="$(make_hanging_reviewer "$COUNT")"
  perlfree="$(make_perl_free_bindir)"

  # SAFETY: 1 s is a test-only ceiling; the missing-Perl setup guard must return before the uncapped-reviewer stand-in starts.
  run bash -c 'PATH="$2"; source "$1"; run_with_timeout 1 "$3"' _ "$LIB" "$perlfree" "$reviewer"

  [ "$status" -ne 0 ]
  [ ! -s "$COUNT" ]
  [[ "$output" == *'code-reviewer: review degraded'* ]] || { echo "$output"; false; }
  [[ "$output" == *'Perl'* ]] || { echo "$output"; false; }
}

@test "timeout runner: Perl fork failure never starts an uncapped reviewer" {
  COUNT="$BATS_TEST_TMPDIR/perl-fork.count"; : > "$COUNT"
  reviewer="$(make_hanging_reviewer "$COUNT")"
  perl_hook_dir="$(mktemp -d "$BATS_TEST_TMPDIR/perl-hook.XXXXXX")"
  cat > "$perl_hook_dir/NoFork.pm" <<'EOF'
package NoFork;
sub import { *CORE::GLOBAL::fork = sub { $! = 11; return undef }; }
1;
EOF

  # SAFETY: 1 s is a test-only ceiling; the fork-failure setup guard must return before the uncapped-reviewer stand-in starts.
  PERL5LIB="$perl_hook_dir" PERL5OPT=-MNoFork \
    run bash -c 'source "$1"; run_with_timeout 1 "$2"' _ "$LIB" "$reviewer"

  [ "$status" -ne 0 ]
  [ ! -s "$COUNT" ]
  [[ "$output" == *'code-reviewer: review degraded'* ]] || { echo "$output"; false; }
  [[ "$output" == *'fork'* ]] || { echo "$output"; false; }
}

# =========================================================================
# Rung 3: deterministic fallback. Force-skip the LLM rung with the sentinel
# (most robust — independent of whether a real `claude` is on PATH).
# =========================================================================
@test "rung3: planted AWS key in diff → critical finding (sentinel-forced)" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<"$SECRET_DIFF"
  unset TRELLIS_REVIEW_IN_PROGRESS

  [ "$status" -eq 0 ]
  assert_valid_findings
  [[ "$output" == *'"severity":"critical"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"AWS access key"* ]]
}

@test "rung3: clean diff (no secrets) → {\"findings\":[]}" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<"$CLEAN_DIFF"
  unset TRELLIS_REVIEW_IN_PROGRESS

  [ "$status" -eq 0 ]
  [ "$output" = '{"findings":[]}' ]
  assert_valid_findings
}

# =========================================================================
# Rung 3 PRECISION (the E1 review fix). A credential-named key is critical ONLY
# when assigned a QUOTED, non-empty, non-placeholder LITERAL. Unquoted TYPE
# ANNOTATIONS / struct / GraphQL fields, env-var refs, and empty/placeholder
# values must NOT trip a (false) critical — rung 3 is the SOLE reviewer when
# claude is absent, so a false critical is a false hard-block.
# =========================================================================
@test "rung3 precision: quoted credential literal → critical" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<'+password = "hunter2"'
  unset TRELLIS_REVIEW_IN_PROGRESS
  [ "$status" -eq 0 ]
  assert_valid_findings
  [[ "$output" == *'"severity":"critical"'* ]]
}

@test "rung3 precision: unquoted type annotations / struct fields → NOT critical" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  for line in '+  password: string' '+def login(password: str):' '+  apiKey: ApiKey' '+  api_key: String,' '+  password: String!'; do
    run bash "$LIB" <<<"$line"
    [ "$status" -eq 0 ]
    [ "$output" = '{"findings":[]}' ] || { echo "FALSE CRITICAL on: $line -> $output"; return 1; }
  done
}

@test "rung3 precision: empty / placeholder / env-ref values → NOT critical" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  for line in '+password = ""' '+password = "REPLACE_ME"' '+token = "${SECRET}"' '+api_key = process.env.KEY'; do
    run bash "$LIB" <<<"$line"
    [ "$status" -eq 0 ]
    [ "$output" = '{"findings":[]}' ] || { echo "FALSE CRITICAL on: $line -> $output"; return 1; }
  done
}

# =========================================================================
# stdin contract: both envelope shapes accepted at rung 3.
# =========================================================================
@test "envelope: JSON {diff,autonomy_level,decisions_log} stdin is accepted" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<"$(make_envelope "$SECRET_DIFF")"
  unset TRELLIS_REVIEW_IN_PROGRESS

  [ "$status" -eq 0 ]
  assert_valid_findings
  # The .diff inside the envelope is extracted and scanned → key is found.
  [[ "$output" == *'"critical"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"AWS access key"* ]]
}

@test "envelope: raw-diff (non-JSON) stdin is accepted" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<"$SECRET_DIFF"
  unset TRELLIS_REVIEW_IN_PROGRESS

  [ "$status" -eq 0 ]
  assert_valid_findings
  [[ "$output" == *'"critical"'* ]]
}

@test "envelope: clean JSON envelope → empty findings" {
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<"$(make_envelope "$CLEAN_DIFF")"
  unset TRELLIS_REVIEW_IN_PROGRESS

  [ "$status" -eq 0 ]
  [ "$output" = '{"findings":[]}' ]
}

# =========================================================================
# Recursion guard: with the sentinel set, the LLM rung is skipped even when a
# `claude` stub that WOULD have emitted findings is on PATH. Proof: the stub's
# distinctive payload must be ABSENT (the deterministic rung ran instead).
# =========================================================================
@test "recursion-guard: TRELLIS_REVIEW_IN_PROGRESS=1 skips the LLM rung" {
  stub_path="$(make_claude_stub \
    "printf '%s\\n' '{\"findings\":[{\"severity\":\"critical\",\"file\":\"z\",\"line\":1,\"msg\":\"from-llm-stub\",\"confidence\":0.9}]}'")"

  PATH_BACKUP="$PATH"; export PATH="$stub_path:$PATH"
  export TRELLIS_REVIEW_IN_PROGRESS=1
  run bash "$LIB" <<<"$CLEAN_DIFF"
  unset TRELLIS_REVIEW_IN_PROGRESS
  export PATH="$PATH_BACKUP"; rm -rf "$stub_path"

  [ "$status" -eq 0 ]
  # LLM rung skipped → stub payload never appears; deterministic rung on a
  # clean diff yields the empty verdict.
  [[ "$output" != *"from-llm-stub"* ]] || { echo "$output"; false; }
  [ "$output" = '{"findings":[]}' ]
}

# =========================================================================
# Herdr cross-family path: never fall through to same-family Claude.
# =========================================================================
@test "herdr: HERDR_ENV=1 skips the claude rung (no Anthropic fallback)" {
  local claude_count="$BATS_TEST_TMPDIR/claude.count" pi_count="$BATS_TEST_TMPDIR/pi.count"
  stub_path="$(make_claude_stub \
    "printf x >> '$claude_count'; printf '%s\\n' '{\"findings\":[{\"severity\":\"minor\",\"file\":\"a.py\",\"line\":3,\"msg\":\"from-llm-stub\",\"confidence\":0.4}]}'")"
  printf '#!/usr/bin/env bash\nprintf x >> "%s"\n' "$pi_count" > "$stub_path/pi"
  chmod +x "$stub_path/pi"
  local private_home="$BATS_TEST_TMPDIR/herdr-home"
  mkdir -m 700 "$private_home"
  [ ! -e "$private_home/.trellis/state/roles-resolved.json" ]

  PATH_BACKUP="$PATH"; export PATH="$stub_path:$PATH"
  unset CODE_REVIEWER_CMD
  HOME="$private_home" HERDR_ENV=1 \
    HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
    run_reviewer "$CLEAN_DIFF"
  export PATH="$PATH_BACKUP"; rm -rf "$stub_path"

  [ "$status" -eq 0 ]
  [[ "$output" != *"from-llm-stub"* ]] || { echo "$output"; false; }
  [ "$output" = '{"findings":[]}' ]
  assert_valid_findings
  [ "$stderr" = 'code-reviewer: deciding artifact is unavailable or invalid; deterministic fallback applies' ] || { echo "$stderr"; false; }
  [ ! -e "$claude_count" ]
  [ ! -e "$pi_count" ]
}

# =========================================================================
# Direct unit test of the pure rung-3 function. Run in a subshell (bash -c) as
# defence-in-depth; the file applies `set -euo pipefail` only inside its
# run-as-main guard, so sourcing it does not contaminate the bats shell.
# =========================================================================
@test "unit: deterministic_review (sourced) flags planted AWS key" {
  run bash -c 'source "$1"; printf "%s" "$2" | deterministic_review' _ "$LIB" "$SECRET_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"severity":"critical"'* ]] || { echo "$output"; false; }
  assert_valid_findings
}

@test "unit: deterministic_review (sourced) on empty stdin → empty findings" {
  run bash -c 'source "$1"; printf "%s" "" | deterministic_review' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = '{"findings":[]}' ]
}
