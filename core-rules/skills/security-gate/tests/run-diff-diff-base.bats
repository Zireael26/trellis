#!/usr/bin/env bats
# run-diff.sh diff base (spec 067 T6): standalone, the process-gate resolver
# picks the range; Semgrep's targets and Gitleaks' --log-opts both follow it,
# and the verdict carries its receipt. Scanners are stubs that log what they get.

setup() {
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"
  PROJECT="$BATS_TEST_TMPDIR/project"
  export SEMGREP_LOG="$BATS_TEST_TMPDIR/semgrep.log" GITLEAKS_LOG="$BATS_TEST_TMPDIR/gitleaks.log"
  mkdir -p "$BIN" "$PROJECT/audits"
  unset TRELLIS_ROOT
  : > "$SEMGREP_LOG"
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "1.157.0"; exit 0; fi
paths=""
for a in "$@"; do case "$a" in /*) printf '%s\n' "${a##*/}" >> "$SEMGREP_LOG"; paths="$paths${paths:+,}\"$a\"" ;; esac; done
printf '{"results":[],"errors":[],"paths":{"scanned":[%s]}}\n' "$paths"
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then echo "8.30.1"; exit 0; fi
report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-opts=*) printf '%s\n' "${1#--log-opts=}" > "$GITLEAKS_LOG"; shift ;;
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$report" ] && printf '[]' > "$report"
exit 0
SH
  chmod +x "$BIN/semgrep" "$BIN/gitleaks"
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" config user.email security-gate@trellis.test
  git -C "$PROJECT" config user.name "trellis test"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-01-01-baseline-project.json"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm seed
  git -C "$PROJECT" checkout -qb feature/a
  commit a1.js
  ATIP="$(git -C "$PROJECT" rev-parse HEAD)"
  git -C "$PROJECT" checkout -qb feature/b
  commit b1.js
  HEAD_SHA="$(git -C "$PROJECT" rev-parse HEAD)"
  git -C "$PROJECT" config branch.feature/b.trellisParent feature/a
  git -C "$PROJECT" config branch.feature/b.trellisBase "$ATIP"
}

commit() {
  printf 'export const x = 1;\n' > "$PROJECT/$1"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "$1"
}

run_diff() {
  run env PATH="$BIN:$PATH" SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    bash "$1/scripts/run-diff.sh" "$PROJECT" --no-llm
}

@test "stacked branch: Semgrep and Gitleaks both scan b1's range only" {
  # Inversion: the old origin/main..HEAD-or-main..HEAD default scans a1.js too.
  run_diff "$SCRIPT_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$SEMGREP_LOG")" = "b1.js" ] || { cat "$SEMGREP_LOG"; false; }
  [ "$(cat "$GITLEAKS_LOG")" = "$ATIP..$HEAD_SHA" ] || { cat "$GITLEAKS_LOG"; false; }
  [[ "$output" == *$'## security-gate verdict (diff)\n\ndiff-base: '"${ATIP:0:12} feature/a via recorded (parent feature/a) range=${ATIP:0:12}..${HEAD_SHA:0:12} head=feature/b"* ]] || { echo "$output"; false; }
}

@test "without the process-gate skill beside it, the old default runs and the receipt says so" {
  # Inversion: dropping the fallback leaves RANGE empty and the scan BLOCKs.
  mkdir -p "$BATS_TEST_TMPDIR/skills"
  cp -R "$SCRIPT_ROOT" "$BATS_TEST_TMPDIR/skills/security-gate"
  run_diff "$BATS_TEST_TMPDIR/skills/security-gate"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"diff-base: - main via default (resolver absent) range=main..HEAD head=feature/b"* ]] || { echo "$output"; false; }
  [ "$(LC_ALL=C sort "$SEMGREP_LOG" | tr '\n' ' ')" = "a1.js b1.js " ] || { cat "$SEMGREP_LOG"; false; }
}

@test "nothing resolvable BLOCKs with a refused receipt instead of scanning HEAD~1" {
  # Inversion: a HEAD~1..HEAD fallback scans the last commit and passes.
  git -C "$PROJECT" checkout -q --orphan lone
  git -C "$PROJECT" commit -qm lone
  git -C "$PROJECT" branch -D main feature/a feature/b >/dev/null
  run_diff "$SCRIPT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"security-gate: no diff base resolvable; pass --base"* ]] || { echo "$output"; false; }
  [[ "$output" == *"diff-base: - - via refused (no diff base resolvable; pass --base) range=- head=lone"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "without the process-gate skill and with no main or master, it BLOCKs instead of scanning HEAD~1" {
  # Inversion: the old HEAD~1..HEAD fallback scans lone2.js alone and passes.
  mkdir -p "$BATS_TEST_TMPDIR/skills"
  cp -R "$SCRIPT_ROOT" "$BATS_TEST_TMPDIR/skills/security-gate"
  git -C "$PROJECT" checkout -q --orphan lone
  commit lone1.js
  commit lone2.js
  git -C "$PROJECT" branch -D main feature/a feature/b >/dev/null
  : > "$SEMGREP_LOG"
  run_diff "$BATS_TEST_TMPDIR/skills/security-gate"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"security-gate: no diff base resolvable; pass --range"* ]] || { echo "$output"; false; }
  [[ "$output" == *"diff-base: - - via refused (no diff base resolvable; pass --range) range=- head=lone"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [ ! -s "$SEMGREP_LOG" ] || { cat "$SEMGREP_LOG"; false; }
}

# BGSEC-A: a synthetic AWS key sits behind a template.branch the range sets.
# The gitleaks stub reports a leak whenever the range it is handed carries the
# key, so the verdict follows the range the resolver chose. The semgrep stub
# reports every target scanned, so only Secrets can fail.
leaky_scanners() {
  cat > "$BIN/semgrep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "1.157.0"; exit 0; fi
paths=""
for a in "$@"; do case "$a" in /*) paths="$paths${paths:+,}\"$a\"" ;; esac; done
printf '{"results":[],"errors":[],"paths":{"scanned":[%s]}}\n' "$paths"
SH
  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then echo "8.30.1"; exit 0; fi
src="" range="" report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) src="$2"; shift 2 ;;
    --log-opts=*) range="${1#--log-opts=}"; shift ;;
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$range" > "$GITLEAKS_LOG"
if git -C "$src" log -p "$range" -- | grep -q 'AKIA'; then
  printf '[{"RuleID":"aws-access-token","Description":"AWS key","File":"creds.env","StartLine":1,"Commit":"00000000"}]' > "$report"
  exit 1
fi
printf '[]' > "$report"
SH
  chmod +x "$BIN/semgrep" "$BIN/gitleaks"
}

# creds_branch <policy>: origin/main at main's tip M0, then feature/x off main
# with the key in commit A and, in commit B, template.branch set to <policy>
# (`sha` and `short` name A).
creds_branch() {
  local pol="$1"
  M0="$(git -C "$PROJECT" rev-parse main)" || return 1
  git -C "$PROJECT" update-ref refs/remotes/origin/main "$M0" || return 1
  git -C "$PROJECT" checkout -qb feature/x main || return 1
  printf 'AWS_ACCESS_KEY_ID=%s%s\n' AKIA QYLPMN5HFIQR7XYZ > "$PROJECT/creds.env" || return 1
  git -C "$PROJECT" add creds.env || return 1
  git -C "$PROJECT" commit -qm creds || return 1
  A="$(git -C "$PROJECT" rev-parse HEAD)" || return 1
  case "$pol" in sha) pol="$A" ;; short) pol="${A:0:7}" ;; esac
  printf '{"template":{"branch":"%s"}}\n' "$pol" > "$PROJECT/.trellis.json" || return 1
  git -C "$PROJECT" add .trellis.json || return 1
  git -C "$PROJECT" commit -qm policy || return 1
  B="$(git -C "$PROJECT" rev-parse HEAD)" || return 1
  leaky_scanners
}

assert_creds_blocked() {
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"MERGEABLE"* ]] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep '^Secrets:' | grep -q fail || { echo "$output"; return 1; }
}

@test "BGSEC-A a range-carried template.branch of HEAD cannot empty the scan: the key BLOCKs" {
  # Inversion: the checkout's policy resolves B..B and the verdict is MERGEABLE.
  creds_branch HEAD
  run_diff "$SCRIPT_ROOT"
  assert_creds_blocked
  [ "$(cat "$GITLEAKS_LOG")" = "$M0..$B" ] || { cat "$GITLEAKS_LOG"; false; }
  printf '%s\n' "$output" | grep -q '^SAST: .*pass' || { echo "$output"; false; }
}

@test "BGSEC-A a range-carried template.branch naming the creds sha cannot narrow the scan" {
  # Inversion: the policy is taken as a revspec and the scan is A..B.
  creds_branch sha
  run_diff "$SCRIPT_ROOT"
  assert_creds_blocked
  [ "$(cat "$GITLEAKS_LOG")" = "$M0..$B" ] || { cat "$GITLEAKS_LOG"; false; }
}

@test "BGSEC-A a range-carried @, abbreviated sha or option-shaped policy still BLOCKs the key" {
  # Inversion: @ gives B..B and the short sha A..B, both MERGEABLE.
  local pol
  for pol in @ short --all; do
    git -C "$PROJECT" checkout -q main || return 1
    git -C "$PROJECT" branch -D feature/x >/dev/null 2>&1 || true
    creds_branch "$pol" || return 1
    run_diff "$SCRIPT_ROOT"
    assert_creds_blocked || { echo "policy $pol"; return 1; }
    [ "$(cat "$GITLEAKS_LOG")" = "$M0..$B" ] || { echo "policy $pol"; cat "$GITLEAKS_LOG"; return 1; }
  done
}

@test "BGSEC-A control: an explicit --range=origin/main..HEAD BLOCKs the key" {
  creds_branch HEAD
  run env PATH="$BIN:$PATH" SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --no-llm --range=origin/main..HEAD
  assert_creds_blocked
  [ "$(cat "$GITLEAKS_LOG")" = origin/main..HEAD ] || { cat "$GITLEAKS_LOG"; false; }
}

@test "BGSEC-A a base template.branch that is not a branch refuses and BLOCKs, never MERGEABLE" {
  # Inversion: resolving HEAD as the policy branch scans B..B and passes.
  printf '{"template":{"branch":"HEAD"}}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm 'base policy'
  creds_branch @
  run_diff "$SCRIPT_ROOT"
  assert_creds_blocked
  [[ "$output" == *"no diff base resolvable; pass --range"* ]] || { echo "$output"; false; }
  [[ "$output" == *"via refused ("*") range=- head=feature/x"* ]] || { echo "$output"; false; }
}

@test "BGSEC-A a base template.branch of main still resolves through origin/main, whatever the range sets" {
  # Inversion: refusing a real policy branch BLOCKs with a refused receipt.
  printf '{"template":{"branch":"main"}}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm 'base policy'
  creds_branch HEAD
  run_diff "$SCRIPT_ROOT"
  assert_creds_blocked
  [ "$(cat "$GITLEAKS_LOG")" = "$M0..$B" ] || { cat "$GITLEAKS_LOG"; false; }
  [[ "$output" == *"diff-base: ${M0:0:12} origin/main via default ("* ]] || { echo "$output"; false; }
}
