#!/usr/bin/env bats
# Tests for run-all.sh — nine-gate mode contract:
#   - 9-gate parallel arrays (idx 0-8) + dual indexed render loops.
#   - --mode=push|merge (DL-P7-02) PR-shape downgrade: at push a FAIL in
#     {0 PR hygiene, 4 Docs discipline, 7 Analyze} -> WARN; the always-hard
#     gates {1 Secrets, 2 Bypass markers, 3 Tests, 6 Security} NEVER downgrade.
#   - At merge: strict, no downgrade.
#   - Exit-code contract preserved: MERGEABLE 0 / NEEDS CHANGES 2 / BLOCKED 1.
#
# Strategy (FILE A is the aggregator; check-security-diff.sh / check-analyze.sh
# are authored by sibling agents and may not exist yet). We unit-test the
# aggregator in ISOLATION against STUB gate scripts: a throwaway skill dir holds
# run-all.sh + lib/common.sh + seven stub check-*.sh that each `exit
# "${STUB_RC_<idx>:-0}"`. SKILL_DIR resolves to the tmp dir, so every run_gate
# call lands on a stub whose rc we drive via env. PROCESS_GATE_STACK_PROFILE=n-a
# keeps idx 5 (inline, not a script) at n/a so it never affects the verdict.

setup() {
  REAL_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  STUB="$(mktemp -d "$BATS_TEST_TMPDIR/process-gate.XXXXXX")"
  mkdir -p "$STUB/scripts/lib"
  cp "$REAL_SCRIPTS/run-all.sh"      "$STUB/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/lib/common.sh"   "$STUB/scripts/lib/common.sh"
  cp "$REAL_SCRIPTS/lib/diff-base.sh" "$STUB/scripts/lib/diff-base.sh"
  chmod +x "$STUB/scripts/run-all.sh"

  # One stub per run_gate idx. Each exits with STUB_RC_<idx> (default 0=pass).
  # The stub echoes a marker so we can assert it actually ran if needed.
  _stub() {
    local name="$1" envvar="$2"
    cat > "$STUB/scripts/$name" <<EOF
#!/usr/bin/env bash
echo "[stub:$name] ran"
exit "\${$envvar:-0}"
EOF
    chmod +x "$STUB/scripts/$name"
  }
  _stub check-pr.sh            STUB_RC_0
  _stub check-secrets.sh       STUB_RC_1
  _stub check-bypass.sh        STUB_RC_2
  _stub check-tests.sh         STUB_RC_3
  _stub check-docs.sh          STUB_RC_4
  _stub check-security-diff.sh STUB_RC_6
  _stub check-analyze.sh       STUB_RC_7

  # Row 8 (Anti-slop) is NOT dispatched through run_gate — the aggregator reads
  # its level off the first printed token so the row can render `n/a`, which no
  # exit code carries. So its stub prints a level rather than only exiting, and
  # STUB_LEVEL_8 drives it (default `info ... n/a`, the undeclared-posture row
  # every project shows until it opts in). Leaving it out entirely made run-all
  # invoke a nonexistent script in every test here, which is exactly the
  # missing-validator case the aggregator now fails on.
  cat > "$STUB/scripts/check-slop.sh" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_LEVEL_8:-info Anti-slop: n/a — posture off or undeclared}"
exit "${STUB_RC_8:-0}"
EOF
  chmod +x "$STUB/scripts/check-slop.sh"

  # A fixture git repo so common.sh range/project resolution does not error.
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "test"
    git commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  # idx 5 inline stack-profile -> n/a (no validators).
  export PROCESS_GATE_STACK_PROFILE="n-a"
}

teardown() {
  [ -n "${STUB:-}" ] && [ -d "$STUB" ] && rm -rf "$STUB"
  [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR"
  [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"
  return 0
}

# run_all <mode> — invoke the staged aggregator from inside the fixture so the
# default range resolves cleanly. Per-gate rc comes from STUB_RC_<idx> env.
# Merge mode (the default) takes no default range since 1.3.11, so every
# invocation below carries the range the old default resolved to in this
# fixture (local main exists): --range=main..HEAD. Push invocations carry no
# range; the diff-base resolver derives one from that local main.
run_all() {
  local mode="$1"
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=$mode --range=main..HEAD"
}

# --- 9-gate render --------------------------------------------------------

@test "render: all 9 gate labels emitted (verdict loop), all-pass -> MERGEABLE 0" {
  run_all merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR hygiene"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Secrets"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Bypass markers"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Tests & coverage"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Docs discipline"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Stack profile"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Security (diff)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Analyze"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Anti-slop"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]]
}

# Row 8's level comes from the printed token, not the exit code — the one gate
# whose renderer can produce `n/a`. Both halves are asserted, because a renderer
# that ignored the token would still pass the label check above.
@test "render: row 8 renders n/a from its printed level while the verdict stays MERGEABLE" {
  run_all merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"Anti-slop:"*"n/a"* ]] || { echo "$output"; false; }
}

@test "render: row 8 printing warn makes the verdict NEEDS CHANGES at rc 0" {
  run bash -c "cd '$PROJECT_DIR' && STUB_LEVEL_8='warn Anti-slop (posture=advisory)' '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]] || { echo "$output"; false; }
}

# The aggregator's only fail-open hole, now closed: a leaf that predates row 9 has
# no check-slop.sh, and a shell "no such file" error's first token is neither
# pass/warn/fail — it used to fall through to `n/a` and read as a clean row.
@test "render: a MISSING check-slop.sh fails the row, it does not render n/a" {
  rm -f "$STUB/scripts/check-slop.sh"
  run_all merge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"validator not found"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Anti-slop:"*"n/a"* ]] || { echo "$output"; false; }
}

# C08: a narrowed Tests row must never read as a full pass. The receipt line is
# carried from check-tests.sh's own two-space finding into the verdict block,
# and only that exact line counts: indented command output never does.
@test "render: a narrowed Tests row prints its docs-only receipt in the verdict" {
  cat > "$STUB/scripts/check-tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "pass Tests & coverage"
echo "  Tests: narrowed (docs-only: 3 files)"
EOF
  run_all merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall: MERGEABLE"*"Tests: narrowed (docs-only: 3 files)"* ]] || { echo "$output"; false; }
}

@test "render: a full Tests row prints no narrowed receipt, even from command output" {
  cat > "$STUB/scripts/check-tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "fail Tests & coverage"
echo '  tests: `x` exited 1'
echo "    Tests: narrowed (docs-only: 3 files)"
exit 1
EOF
  run_all merge
  [ "$status" -eq 1 ]
  [[ "$output" != *$'\nTests: narrowed'* ]] || { echo "$output"; false; }
}

@test "render: findings loop also surfaces idx 6/7 labels when not MERGEABLE" {
  # Security (6) fails -> BLOCKED -> findings section renders. Analyze (7) warn
  # so its label shows in findings too.
  STUB_RC_6=1 STUB_RC_7=2 run bash -c "cd '$PROJECT_DIR' && STUB_RC_6=1 STUB_RC_7=2 '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"## Findings"* ]] || { echo "$output"; false; }
  [[ "$output" == *"### Security (diff)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"### Analyze"* ]]
}

# --- mode default (fail-closed) -------------------------------------------

@test "mode: missing --mode defaults to merge (strict)" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --range=main..HEAD"
  # idx 0 (PR hygiene) fails; merge default => no downgrade => BLOCKED.
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode=merge"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "mode: garbage --mode value is REFUSED before any gate runs" {
  # Was: resolved silently to merge. A typo'd mode is now reported rather than
  # reinterpreted; `pg_parse_mode`'s fail-closed default still covers the
  # internal path. The assertion is that NO gate work happens: exit 2, usage on
  # stderr, and none of the stub gates' output in the result.
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=bogus"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown --mode value: bogus"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Usage: run-all.sh"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Overall:"* ]] || { echo "$output"; false; }
  [[ "$output" != *"mode=merge"* ]] || { echo "$output"; false; }
}

# --- push: PR-shape downgrade ---------------------------------------------

@test "push: PR hygiene (idx 0) FAIL downgrades to WARN -> NEEDS CHANGES 2" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]] || { echo "$output"; false; }
  [[ "$output" == *"downgraded to WARN"* ]]
}

@test "push: Docs discipline (idx 4) FAIL downgrades to WARN -> NEEDS CHANGES 2" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_4=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

@test "push: Analyze (idx 7) FAIL downgrades to WARN -> NEEDS CHANGES 2" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_7=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

# --- push: always-hard gates NEVER downgrade (fail-open guard) -------------

@test "push: Secrets (idx 1) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_1=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "push: Bypass markers (idx 2) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_2=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "push: Tests (idx 3) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_3=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "push: Security (idx 6) FAIL still BLOCKS (no downgrade) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_6=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- merge: strict, every FAIL blocks (incl PR-shape) ---------------------

@test "merge: PR hygiene (idx 0) FAIL hard-blocks (no downgrade at merge) -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "merge: Docs discipline (idx 4) FAIL hard-blocks -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_4=1 '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

@test "merge: Analyze (idx 7) FAIL hard-blocks -> 1" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_7=1 '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- warn handling preserved ----------------------------------------------

@test "any gate WARN (rc 2) -> NEEDS CHANGES 2 at both modes" {
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_1=2 '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Overall: NEEDS CHANGES"* ]]
}

@test "push: a real fail + a warn -> still BLOCKED when fail is always-hard" {
  # idx 6 always-hard fail + idx 0 PR-shape fail (downgraded). Overall BLOCKED.
  run bash -c "cd '$PROJECT_DIR' && STUB_RC_6=1 STUB_RC_0=1 '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]]
}

# --- PG_MODE is exported to child gates -----------------------------------

@test "PG_MODE is exported so child gates observe the mode" {
  # Replace the analyze stub with one that records the PG_MODE it observed to a
  # side file. run_gate captures child stdout (only rendered on non-MERGEABLE),
  # so the side file is the reliable channel for a passing child.
  local seen="$STUB/pg_mode_seen.txt"
  cat > "$STUB/scripts/check-analyze.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\${PG_MODE:-<unset>}" > '$seen'
exit 0
EOF
  chmod +x "$STUB/scripts/check-analyze.sh"
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 0 ]
  [ "$(cat "$seen")" = "push" ]
}

# --- S1 guards (C7-F18): check-slop nonzero / off-contract output blocks ---

@test "render: check-slop exiting nonzero fails the row, it does not render n/a" {
  cat > "$STUB/scripts/check-slop.sh" <<'EOF'
#!/usr/bin/env bash
echo "unexpected output with no contract token"
exit 3
EOF
  chmod +x "$STUB/scripts/check-slop.sh"
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Anti-slop:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Anti-slop:"*"n/a"* ]] || { echo "$output"; false; }
}

# Real Security adapter + payload scanner; only unrelated rows stay stubbed.
security_payload_fixture() {
  mkdir -p "$STUB/bin" "$PROJECT_DIR/audits"
  cp "$REAL_SCRIPTS/check-security-diff.sh" "$STUB/scripts/"
  cp -R "$REAL_SCRIPTS/../../security-gate" "$BATS_TEST_TMPDIR/security-gate"
  # .trellis.json and the baseline are security-gate config: they belong to the
  # base (main), so the range under test carries only the lockfile.
  printf '{"schema_version":1,"project_id":"security-fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  git -C "$PROJECT_DIR" add .trellis.json
  git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -qm 'chore: trellis manifest'
  # The diff gate dedupes against the range BASE's baseline, so it lands on main
  # before the feature branch. SECURITY_FIXTURE_BASELINE=0 leaves the base without one.
  if [ "${SECURITY_FIXTURE_BASELINE:-1}" = 1 ]; then
    printf '{"findings":[]}\n' > "$PROJECT_DIR/audits/2026-01-01-baseline-project.json"
    git -C "$PROJECT_DIR" add audits
    git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -qm 'chore: security baseline'
  fi
  printf '# fixture lock\n' > "$PROJECT_DIR/uv.lock"
  git -C "$PROJECT_DIR" checkout -qb feature/security-fixture
  git -C "$PROJECT_DIR" add .
  git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -qm 'chore: lockfile'
  export TRELLIS_HOME="$STUB/trellis-home" SECURITY_GATE_PROJECT_NAME=project
  export SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_SHELLCHECK=0
  export OSV_FIXTURE_FILE="$STUB/osv.json" OSV_RAN="$STUB/osv-ran"
  unset SECURITY_GATE_SKIP
  printf '{"results":[]}\n' > "$OSV_FIXTURE_FILE"
  cat > "$STUB/bin/osv-scanner" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo 'osv-scanner version 2.4.0'; exit 0; }
printf 'scanned\n' > "$OSV_RAN"
root="$(cd "${!#}" && pwd)" || exit 2
# Recursive scans receive a root, not individual lockfile arguments. Emit
# real-format receipts for every tracked dependency source under that root.
while IFS= read -r -d '' manifest; do
  case "${manifest##*/}" in
    uv.lock|poetry.lock|Pipfile.lock|package-lock.json|npm-shrinkwrap.json|pnpm-lock.yaml|yarn.lock|bun.lock|bun.lockb|Cargo.lock|go.mod|Gemfile.lock|requirements*.txt)
      printf 'Scanned %s/%s file and found 1 packages\n' "$root" "$manifest" >&2
      ;;
  esac
done < <(git -C "$root" ls-files -z --recurse-submodules)
cat "$OSV_FIXTURE_FILE"
EOF
  cat > "$STUB/bin/semgrep" <<'EOF'
#!/usr/bin/env bash
printf '{"results":[]}\n'
EOF
  cat > "$STUB/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 1 ]; do
  if [ "$1" = --report-path ]; then printf '[]' > "$2"; break; fi
  shift
done
EOF
  chmod +x "$STUB/bin/"*
  export PATH="$STUB/bin:$PATH"
  [ ! -e "$PROJECT_DIR/.trellis/runtime" ]
  [ ! -e "$TRELLIS_HOME/state/attachments" ]
}

@test "Security: unattached clone with seeded HIGH advisory fails the merge row" {
  security_payload_fixture
  jq -n --arg path "$PROJECT_DIR/uv.lock" '{results:[{source:{path:$path,type:"lockfile"},
    packages:[{package:{name:"fixture",version:"1.0",ecosystem:"PyPI"},groups:[],
      vulnerabilities:[{id:"FIXTURE-HIGH",summary:"seeded advisory",database_specific:{severity:"HIGH"}}]}]}]}' > "$OSV_FIXTURE_FILE"
  run_all merge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Security (diff):"*"❌ fail"* ]]
  [[ "$output" == *"osv/FIXTURE-HIGH"* ]]
  [[ "$output" != *"skipped"* ]]
  [ -f "$OSV_RAN" ]
}

@test "Security: tracked project warn-skip cannot shadow payload seeded HIGH advisory" {
  security_payload_fixture
  local project_gate="$PROJECT_DIR/.claude/skills/security-gate/scripts/run-diff.sh"
  mkdir -p "$(dirname "$project_gate")"
  printf '#!/usr/bin/env bash\necho PROJECT-SECURITY-STUB\nexit 2\n' > "$project_gate"
  git -C "$PROJECT_DIR" add .claude
  git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -qm 'chore: legacy project gate'
  jq -n --arg path "$PROJECT_DIR/uv.lock" '{results:[{source:{path:$path,type:"lockfile"},
    packages:[{package:{name:"fixture",version:"1.0",ecosystem:"PyPI"},groups:[],
      vulnerabilities:[{id:"FIXTURE-HIGH",summary:"seeded advisory",database_specific:{severity:"HIGH"}}]}]}]}' > "$OSV_FIXTURE_FILE"
  run_all merge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Security (diff):"*"❌ fail"* ]]
  [[ "$output" == *"osv/FIXTURE-HIGH"* ]]
  [[ "$output" != *"PROJECT-SECURITY-STUB"* && "$output" != *"skipped"* ]]
  [ -f "$OSV_RAN" ]
}

@test "Security: clean unattached clone runs payload scanner and passes the row" {
  security_payload_fixture
  # Keep more than uv.lock in the range: a hard-coded single receipt is not
  # a completed recursive scan when another dependency source changed.
  mkdir -p "$PROJECT_DIR/deps"
  printf '{"lockfileVersion":3,"packages":{}}\n' > "$PROJECT_DIR/deps/package-lock.json"
  printf 'fixture==1.0\n' > "$PROJECT_DIR/deps/requirements.txt"
  git -C "$PROJECT_DIR" add deps/package-lock.json deps/requirements.txt
  git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -qm 'chore: more lockfiles'
  run_all merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Security (diff):"*"✅ pass"* ]]
  [ -f "$OSV_RAN" ]
}

@test "Security: missing project and payload scanner fails, never warn-skips" {
  security_payload_fixture
  rm "$BATS_TEST_TMPDIR/security-gate/scripts/run-diff.sh"
  run_all merge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Security (diff):"*"❌ fail"* ]]
  [[ "$output" == *"security-gate unavailable"* ]]
  [[ "$output" != *"skipped"* ]]
}

@test "Security: absent baseline fails instead of warn-skipping the diff scan" {
  SECURITY_FIXTURE_BASELINE=0 security_payload_fixture
  run_all merge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Security (diff):"*"❌ fail"* ]]
  [[ "$output" == *"no baseline JSON"* ]]
  [[ "$output" != *"skipped"* ]]
}

@test "render: an off-contract first token from check-slop fails the row" {
  cat > "$STUB/scripts/check-slop.sh" <<'EOF'
#!/usr/bin/env bash
echo "boom: something unexpected"
exit 0
EOF
  chmod +x "$STUB/scripts/check-slop.sh"
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=merge --range=main..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Anti-slop:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Anti-slop:"*"n/a"* ]] || { echo "$output"; false; }
}

# --- merge mode requires an explicit range (1.3.11 fail-closed) --------------

# A scratch clone: the only branch is a feature branch, no local main/master.
# Two commits so HEAD~1..HEAD would be a strict subset of the branch.
scratch_feature_repo() {
  SCRATCH="$(mktemp -d)"
  (
    cd "$SCRATCH" || exit 1
    git init -q -b feature
    git config user.email "test@example.com"
    git config user.name "test"
    git commit --allow-empty -q -m "one"
    git commit --allow-empty -q -m "two"
  )
  # The scratch clone is the project: gate config loads from its range base.
  export CLAUDE_PROJECT_DIR="$SCRATCH"
}

@test "merge without --range refuses before any check runs" {
  scratch_feature_repo
  run bash -c "cd '$SCRATCH' && '$STUB/scripts/run-all.sh' --mode=merge"
  [ "$status" -eq 1 ]
  [[ "$output" == *'merge mode requires --range/--base'* ]] || { echo "$output"; false; }
  [[ "$output" != *'Overall:'* ]] || { echo "$output"; false; }
  [[ "$output" != *'[stub:'* ]] || { echo "$output"; false; }
}

@test "merge with an explicit --range proceeds past the refusal" {
  scratch_feature_repo
  first="$(git -C "$SCRATCH" rev-list --max-parents=0 HEAD)"
  run bash -c "cd '$SCRATCH' && '$STUB/scripts/run-all.sh' --mode=merge --range='$first..HEAD'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'Overall: MERGEABLE'* ]] || { echo "$output"; false; }
  [[ "$output" != *'merge mode requires'* ]] || { echo "$output"; false; }
}

@test "merge with --base alone, as pr-gate-shiftleft calls it, proceeds past the refusal" {
  # Inversion: an R1 refusal that counts only --range=* refuses this (exit 1),
  # and an argument guard without --base=* rejects it (exit 2).
  scratch_feature_repo
  first="$(git -C "$SCRATCH" rev-list --max-parents=0 HEAD)"
  run bash -c "cd '$SCRATCH' && '$STUB/scripts/run-all.sh' --base='$first'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'mode=merge'* ]] || { echo "$output"; false; }
  [[ "$output" == *'Overall: MERGEABLE'* ]] || { echo "$output"; false; }
  [[ "$output" != *'merge mode requires'* ]] || { echo "$output"; false; }
}

# Intent changed by coordinator ruling D1 (1.3.12-a): this case used to assert
# 1.3.11's push fallbacks ("keeps its fallbacks and is not refused"), which
# ended in HEAD~1..HEAD here. That gates one commit of a two-commit push and
# under-gates it (R31). With no derivable base and no local main/master to
# fall back to, push mode now refuses before any check runs.
@test "push without --range on an underivable two-commit branch refuses, never HEAD~1..HEAD" {
  scratch_feature_repo
  run bash -c "cd '$SCRATCH' && '$STUB/scripts/run-all.sh' --mode=push"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *'no diff base resolvable'* ]] || { echo "$output"; false; }
  [[ "$output" != *'Overall:'* ]] || { echo "$output"; false; }
  [[ "$output" != *'[stub:'* ]] || { echo "$output"; false; }
}
