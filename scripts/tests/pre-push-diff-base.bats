#!/usr/bin/env bats
# spec 067 T9 + R21: carrier ranges, policy mode and pushed-ref identity.
# Each case has its own fixture; inversions are mapped in W120/REPORT.md and
# the 1.3.12-a reconciliation report.

setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)" || return 1
  REPO="$BATS_TEST_TMPDIR/repo"
  SCRIPTS="$REPO/.claude/skills/process-gate/scripts"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export PROCESS_GATE_CAPTURE="$BATS_TEST_TMPDIR/runner.log"
  export SPEC_GATE_CAPTURE="$BATS_TEST_TMPDIR/spec.log"
  export AEO_GATE_CAPTURE="$BATS_TEST_TMPDIR/aeo.log"
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR TRELLIS_ROOT TRELLIS_ALLOW_MAIN_PUSH
  mkdir -p "$SCRIPTS/lib" "$REPO/.claude/hooks/lib" || return 1
  cp "$SOURCE/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$SCRIPTS/lib/" || return 1
  # The carrier refuses a passing rc without exactly one Overall line in one
  # verdict block, so the stand-in renders one.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "$PROCESS_GATE_CAPTURE"\nprintf "## process-gate verdict\\n\\nOverall: MERGEABLE\\n"\n' > "$SCRIPTS/run-all.sh" || return 1
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "$SPEC_GATE_CAPTURE"\n' > "$REPO/.claude/hooks/spec-gate.sh" || return 1
  printf '#!/bin/bash\nprintf "%%s\\n" "$AEO_GATE_RANGE" > "$AEO_GATE_CAPTURE"\n' > "$REPO/.claude/hooks/lib/aeo-gate-warn.sh" || return 1
  cd "$REPO" || return 1
  git init -q -b main || return 1
  git config user.email carrier@test.invalid || return 1
  git config user.name carrier-test || return 1
  git config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks" || return 1
  printf '/.claude/\n' > .git/info/exclude || return 1
  printf '{"template":{"branch":"main"},"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80}}\n' > .trellis.json || return 1
  snap seed || return 1
  M0="$TIP"
  git update-ref refs/remotes/origin/main "$M0" || return 1
  ZERO=0000000000000000000000000000000000000000
  CARRIER="$SOURCE/core-rules/githooks/pre-push"
}

snap() {
  printf '%s\n' "$1" > "$1.txt" || return 1
  git add -A || return 1
  git commit -qm "$1" || return 1
  TIP="$(git rev-parse HEAD)" || return 1
}

stack() {
  git checkout -qb feature/a main || return 1
  snap a1 || return 1
  snap a2 || return 1
  ATIP="$TIP"
  git checkout -qb feature/b feature/a || return 1
  git config branch.feature/b.trellisParent feature/a || return 1
  git config branch.feature/b.trellisBase "$ATIP" || return 1
  snap b1 || return 1
  BTIP="$TIP"
}

push_ref() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/refs" || return 1
  shift
  run env "$@" sh "$CARRIER" origin https://example.invalid/repo.git < "$BATS_TEST_TMPDIR/refs"
}

# R31 over T9's letter: an unpushed parent's commits ride this push, so they
# are gated too, and the receipt and hint say why.
@test "T9/R31 first push of stacked B with an unpushed parent gates a1, a2 and b1" {
  stack || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  local args range
  args="$(< "$PROCESS_GATE_CAPTURE")" || return 1
  range="${args##*--range=}"
  [ "$(git log --format=%s "$range")" = "b1
a2
a1" ] || return 1
  [[ "$output" == *"[pre-push] parent branch feature/a is not on origin; push it first to gate only this branch's commits"* ]] || return 1
  [[ "$output" == *"diff-base: ${M0:0:12} origin/main via default (parent feature/a not on origin) range=${M0:0:12}..${BTIP:0:12} head=feature/b"* ]] || return 1
}

@test "T9 first push of stacked B whose parent is on the remote gates b1 only" {
  stack || return 1
  git update-ref refs/remotes/origin/feature/a "$ATIP" || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  local args range
  args="$(< "$PROCESS_GATE_CAPTURE")" || return 1
  range="${args##*--range=}"
  [ "$(git log --format=%s "$range")" = b1 ] || return 1
}

@test "T9 update push retains remote tip rather than the recorded parent" {
  stack || return 1
  snap b2 || return 1
  push_ref "refs/heads/feature/b $TIP refs/heads/feature/b $BTIP" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$BTIP..$TIP" ] || return 1
}

@test "T9 spec-gate and AEO receive the same exact carrier range" {
  stack || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$SPEC_GATE_CAPTURE")" = "--gate --ref refs/heads/feature/b --head $BTIP --range $(< "$AEO_GATE_CAPTURE")" ] || return 1
}

@test "T9 push targeting a parent feature branch remains push mode" {
  stack || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/a $ATIP" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$ATIP..$BTIP" ] || return 1
}

@test "T9 push targeting policy template.branch uses merge mode" {
  stack || return 1
  printf '{"template":{"branch":"release"}}\n' > .trellis.json || return 1
  git add .trellis.json || return 1
  git commit -qm 'protect release' || return 1
  local head
  head="$(git rev-parse HEAD)" || return 1
  push_ref "refs/heads/feature/b $head refs/heads/release $ATIP" TRELLIS_ALLOW_MAIN_PUSH=1 || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=merge --range=$ATIP..$head --target=main" ] || return 1
}

@test "T9 policy mode reads pushed X rather than checked-out Y" {
  stack || return 1
  printf '{"template":{"branch":"release"}}\n' > .trellis.json || return 1
  git add .trellis.json || return 1
  git commit -qm 'X protects release' || return 1
  local head
  head="$(git rev-parse HEAD)" || return 1
  git checkout -q main || return 1
  push_ref "refs/heads/feature/b $head refs/heads/release $ATIP" TRELLIS_ALLOW_MAIN_PUSH=1 || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=merge --range=$ATIP..$head --target=main" ] || return 1
}

@test "T9 carrier prints one resolver receipt beside verification starting" {
  stack || return 1
  git update-ref refs/remotes/origin/feature/a "$ATIP" || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "[pre-push] Trellis verification starting (mode=push)...
diff-base: ${ATIP:0:12} feature/a via recorded (parent feature/a) range=${ATIP:0:12}..${BTIP:0:12} head=feature/b
## process-gate verdict

Overall: MERGEABLE
[pre-push] process-gate ok" ] || return 1
}

@test "T9 missing selected-runner resolver blocks before any verdict" {
  stack || return 1
  mv "$SCRIPTS/lib/diff-base.sh" "$BATS_TEST_TMPDIR/saved-resolver" || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *'diff-base resolver missing; restore the process-gate skill'* ]] || return 1
}

@test "T9 native and husky carriers stay byte-identical" {
  cmp "$SOURCE/core-rules/githooks/pre-push" "$SOURCE/core-rules/husky/pre-push" || return 1
}

install_real_spec_gate() {
  cp "$SOURCE/core-rules/hooks/spec-gate.sh" "$REPO/.claude/hooks/" || return 1
  cp "$SOURCE/core-rules/hooks/lib/"{spec-gate-core,deps,autonomy}.sh "$REPO/.claude/hooks/lib/" || return 1
}

@test "R21 carrier gets X's block verdict while HEAD is sub-floor Y" {
  install_real_spec_gate || return 1
  git checkout -qb feature/x main || return 1
  local i head
  for ((i=1; i<=120; i++)); do printf 'const x_%s = %s;\n' "$i" "$i" >> x.js || return 1; done
  git add x.js || return 1
  git commit -qm 'X above floor without triad' || return 1
  head="$(git rev-parse HEAD)" || return 1
  local worktree="$BATS_TEST_TMPDIR/worktree-y"
  git worktree add -q -b feature/y "$worktree" main || return 1
  ln -s "$REPO/.claude" "$worktree/.claude" || return 1
  cd "$worktree" || return 1
  snap y1 || return 1
  push_ref "refs/heads/feature/x $head refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"range=$M0..$head head=feature/x"$'\n'"[spec-gate] BLOCKED: 120 gated lines over floor 80"* ]] || return 1
}

@test "R21 carrier gets X's triad pass verdict while HEAD is Y without a triad" {
  install_real_spec_gate || return 1
  git checkout -qb feature/x main || return 1
  local i f head
  for ((i=1; i<=120; i++)); do printf 'const x_%s = %s;\n' "$i" "$i" >> x.js || return 1; done
  mkdir -p specs/001-x || return 1
  for f in spec plan tasks clarify; do
    printf '%s\n' 'This concrete artifact documents the problem, design and acceptance for X. It contains real decisions and a complete implementation plan, with meaningful checks and no scaffold tokens. This prose is deliberately longer than two hundred bytes.' > "specs/001-x/$f.md" || return 1
  done
  git add -A || return 1
  git commit -qm 'X code and triad' || return 1
  head="$(git rev-parse HEAD)" || return 1
  git checkout -qb feature/y main || return 1
  snap y1 || return 1
  push_ref "refs/heads/feature/x $head refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ -f "$PROCESS_GATE_CAPTURE" ] || return 1
}

@test "R21 carrier honours X-bound marker while HEAD is Y" {
  install_real_spec_gate || return 1
  git checkout -qb feature/x main || return 1
  local i head
  for ((i=1; i<=120; i++)); do printf 'const x_%s = %s;\n' "$i" "$i" >> x.js || return 1; done
  git add x.js || return 1
  git commit -qm 'X without triad' || return 1
  head="$(git rev-parse HEAD)" || return 1
  git checkout -qb feature/y main || return 1
  snap y1 || return 1
  printf '%s\n' feature/x "$REPO" "$M0" "$head" carrier-session surgical R21 > .claude/session-surgical || return 1
  push_ref "refs/heads/feature/x $head refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
}

@test "R21 carrier passes the supplied head even when X's branch tip has moved" {
  stack || return 1
  git update-ref refs/remotes/origin/feature/a "$ATIP" || return 1
  snap b2 || return 1
  git checkout -q main || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$SPEC_GATE_CAPTURE")" = "--gate --ref refs/heads/feature/b --head $BTIP --range $ATIP..$BTIP" ] || return 1
}

# R33 supersedes the unresolved-update pass-through: no gate runs at all.
@test "R33 unresolved update refuses before spec-gate or run-all" {
  stack || return 1
  git checkout -q main || return 1
  push_ref "refs/heads/feature/b $BTIP refs/heads/feature/b 1111111111111111111111111111111111111111" || return 1
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"cannot derive the range for refs/heads/feature/b: its remote tip is not local; fetch first"* ]] || return 1
  [ ! -e "$SPEC_GATE_CAPTURE" ] || return 1
  [ ! -e "$PROCESS_GATE_CAPTURE" ] || return 1
}

@test "W124 F1 pushed tree without template.branch ignores the checkout's policy" {
  git checkout -qb feature/x main || return 1
  printf '{}\n' > .trellis.json || return 1
  snap x1 || return 1
  local x1="$TIP"
  snap x2 || return 1
  local x2="$TIP"
  git update-ref refs/remotes/origin/release "$x1" || return 1
  git checkout -q main || return 1
  printf '{"template":{"branch":"release"}}\n' > .trellis.json || return 1
  push_ref "refs/heads/feature/x $x2 refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$x2" ] || return 1
}

@test "R31 tag-only push skips spec-gate and gates the tag range with its receipt" {
  stack || return 1
  git tag v1 "$BTIP" || return 1
  push_ref "refs/tags/v1 $BTIP refs/tags/v1 $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ ! -e "$SPEC_GATE_CAPTURE" ] || return 1
  [[ "$output" == *"spec-gate: skipped (tag-only push)"* ]] || return 1
  [[ "$output" == *"diff-base: ${M0:0:12} - via explicit (explicit) range=$M0..$BTIP head=refs/tags/v1"* ]] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$BTIP" ] || return 1
}

@test "R31 branch+tag gives spec-gate the branch and still gates a tag range outside it" {
  stack || return 1
  git update-ref refs/remotes/origin/feature/a "$ATIP" || return 1
  git tag v1 "$BTIP" || return 1
  push_ref "refs/tags/v1 $BTIP refs/tags/v1 $ZERO
refs/heads/feature/b $BTIP refs/heads/feature/b $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$SPEC_GATE_CAPTURE")" = "--gate --ref refs/heads/feature/b --head $BTIP --range $ATIP..$BTIP" ] || return 1
  # a1 and a2 are outside the stacked branch range, so the tag range runs last.
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$BTIP" ] || return 1
}

@test "F1 a pushed tree naming another template.branch cannot unprotect main" {
  printf '{"template":{"branch":"release"}}\n' > .trellis.json || return 1
  snap unprotect || return 1
  push_ref "refs/heads/main $TIP refs/heads/main $M0" || return 1
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"Direct push to refs/heads/main blocked by Trellis policy"* ]] || return 1
  [ ! -e "$PROCESS_GATE_CAPTURE" ] || return 1
}

@test "F1 an empty pushed policy cannot unprotect the remote default's template.branch" {
  printf '{"template":{"branch":"release"}}\n' > .trellis.json || return 1
  snap declare || return 1
  local base="$TIP"
  git update-ref refs/remotes/origin/main "$base" || return 1
  git checkout -qb feature/x || return 1
  printf '{}\n' > .trellis.json || return 1
  snap emptied || return 1
  push_ref "refs/heads/feature/x $TIP refs/heads/release $base" || return 1
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"Direct push to refs/heads/release blocked by Trellis policy"* ]] || return 1
  [ ! -e "$PROCESS_GATE_CAPTURE" ] || return 1
}

@test "F1 control: the remote default's template.branch protects that branch" {
  printf '{"template":{"branch":"release"}}\n' > .trellis.json || return 1
  snap declare || return 1
  local base="$TIP"
  git update-ref refs/remotes/origin/main "$base" || return 1
  snap next || return 1
  push_ref "refs/heads/main $TIP refs/heads/release $base" TRELLIS_ALLOW_MAIN_PUSH=1 || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=merge --range=$base..$TIP --target=main" ] || return 1
}

# BGSEC-6: a pushed tree's template.branch never picks a first push's base.
@test "BGSEC-6 a pushed tree's template.branch naming a local rev cannot empty a first push range" {
  git checkout -qb feature/x main || return 1
  snap x1 || return 1
  printf '{"template":{"branch":"HEAD"}}\n' > .trellis.json || return 1
  snap x2 || return 1
  local x2="$TIP"
  push_ref "refs/heads/feature/x $x2 refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$x2" ] || return 1
}

@test "BGSEC-6 a pushed tree's template.branch naming an in-range sha cannot narrow a first push range" {
  git checkout -qb feature/x main || return 1
  snap x1 || return 1
  printf '{"template":{"branch":"%s"}}\n' "$TIP" > .trellis.json || return 1
  snap x2 || return 1
  local x2="$TIP"
  push_ref "refs/heads/feature/x $x2 refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$x2" ] || return 1
}

@test "BGSEC-6 a pushed tree's template.branch naming a remote branch does not pick the first push base" {
  # Inversion: injecting the pushed policy bases the range on origin/side (x1).
  git checkout -qb feature/x main || return 1
  snap x1 || return 1
  git update-ref refs/remotes/origin/side "$TIP" || return 1
  printf '{"template":{"branch":"side"}}\n' > .trellis.json || return 1
  snap x2 || return 1
  local x2="$TIP"
  push_ref "refs/heads/feature/x $x2 refs/heads/feature/x $ZERO" || return 1
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$x2" ] || return 1
}

@test "BGSEC-6 a default base the push remote lacks is not trusted: the remote-default range is gated" {
  # Inversion: exempting DB_SOURCE=default from R31 containment gates o1..x1,
  # and o1 is not on the push remote.
  git checkout -qb feature/x main || return 1
  snap o1 || return 1
  local o1="$TIP"
  git update-ref refs/remotes/origin/main "$o1" || return 1
  git update-ref refs/remotes/fork/main "$M0" || return 1
  snap x1 || return 1
  local x1="$TIP"
  printf '%s\n' "refs/heads/feature/x $x1 refs/heads/feature/x $ZERO" > "$BATS_TEST_TMPDIR/refs" || return 1
  run sh "$CARRIER" fork https://example.invalid/fork.git < "$BATS_TEST_TMPDIR/refs"
  [ "$status" -eq 0 ] || return 1
  [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$x1" ] || return 1
  [ "$(git log --format=%s "$M0..$x1")" = "x1
o1" ] || return 1
  # The hint and receipt name the resolver's base, not a parent branch.
  [[ "$output" == *"[pre-push] resolved base origin/main is not on fork; gating from fork's default branch instead"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"diff-base: ${M0:0:12} fork/main via default (base origin/main not on fork) range=${M0:0:12}..${x1:0:12} head=feature/x"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"parent branch"* ]] || { echo "$output"; return 1; }
}

# A run-all stand-in that BLOCKs when the range it is handed carries the key.
block_on_key() {
  cat > "$SCRIPTS/run-all.sh" <<'SH' || return 1
#!/bin/bash
args="$*"
printf '%s\n' "$args" > "$PROCESS_GATE_CAPTURE"
range="${args##*--range=}"
echo "## process-gate verdict"
if git log -p "$range" -- | grep -q AKIA; then echo "Overall: BLOCKED"; exit 1; fi
echo "Overall: MERGEABLE"
SH
}

@test "BGSEC-6 a key behind a pushed HEAD, @, sha, short sha or option-shaped template.branch BLOCKs the first push" {
  # Inversion: HEAD and @ gate B..B, the shas A..B; each push exits 0.
  block_on_key || return 1
  local pol branch a b
  for pol in HEAD @ sha short --all; do
    branch="feature/k-${pol#--}"
    git checkout -q main || return 1
    git checkout -qb "$branch" || return 1
    printf 'AWS_ACCESS_KEY_ID=%s%s\n' AKIA QYLPMN5HFIQR7XYZ > creds.env || return 1
    git add creds.env || return 1
    git commit -qm creds || return 1
    a="$(git rev-parse HEAD)" || return 1
    case "$pol" in sha) pol="$a" ;; short) pol="${a:0:7}" ;; esac
    printf '{"template":{"branch":"%s"}}\n' "$pol" > .trellis.json || return 1
    git add .trellis.json || return 1
    git commit -qm policy || return 1
    b="$(git rev-parse HEAD)" || return 1
    rm -f "$PROCESS_GATE_CAPTURE"
    push_ref "refs/heads/$branch $b refs/heads/$branch $ZERO" || return 1
    [ "$status" -eq 1 ] || { echo "policy $pol: $output"; return 1; }
    [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "policy $pol: $output"; return 1; }
    [ "$(< "$PROCESS_GATE_CAPTURE")" = "--mode=push --range=$M0..$b" ] || { echo "policy $pol"; cat "$PROCESS_GATE_CAPTURE"; return 1; }
  done
}
