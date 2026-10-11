#!/usr/bin/env bats
# spec 067 T8: option-1 stacked semantics, exact ranges and marker compatibility.
# Synthetic git state only. Each test's inversion is recorded in W108/REPORT.md.

setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)" || return 1
  SANDBOX="$BATS_TEST_TMPDIR/spec-gate"
  REPO_DIR="$SANDBOX/repo"
  RUNTIME="$SANDBOX/runtime"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
  mkdir -p "$REPO_DIR" "$RUNTIME/core-rules/hooks/lib" \
    "$RUNTIME/core-rules/codex/hooks" "$RUNTIME/core-rules/skills/process-gate/scripts/lib" || return 1
  cp "$SOURCE/core-rules/hooks/spec-gate.sh" "$RUNTIME/core-rules/hooks/" || return 1
  cp "$SOURCE/core-rules/codex/hooks/spec-gate.sh" "$RUNTIME/core-rules/codex/hooks/" || return 1
  cp "$SOURCE/core-rules/hooks/lib/"{spec-gate-core,deps,autonomy}.sh "$RUNTIME/core-rules/hooks/lib/" || return 1
  cp "$SOURCE/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$RUNTIME/core-rules/skills/process-gate/scripts/lib/" || return 1
  export TRELLIS_ROOT="$RUNTIME"
  GATE="$RUNTIME/core-rules/hooks/spec-gate.sh"
  CODEX_GATE="$RUNTIME/core-rules/codex/hooks/spec-gate.sh"
  cd "$REPO_DIR" || return 1
  git init -q -b main || return 1
  git config user.email t@t.invalid || return 1
  git config user.name t || return 1
  git config core.hooksPath "$SANDBOX/no-hooks" || return 1
  printf 'seed\n' > README.md || return 1
  printf '{"template":{"branch":"main"},"autonomy":3,"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}\n' > .trellis.json || return 1
  git add -A || return 1
  git commit -qm seed || return 1
  M0="$(git rev-parse HEAD)" || return 1
  git update-ref refs/remotes/origin/main "$M0" || return 1
}

lines() {
  local file="$1" n="$2" i
  mkdir -p "$(dirname "$file")" || return 1
  : > "$file" || return 1
  for ((i=1; i<=n; i++)); do printf 'const line_%s = %s;\n' "$i" "$i" >> "$file" || return 1; done
}

triad() {
  local d="specs/$1" f
  mkdir -p "$d" || return 1
  for f in spec plan tasks clarify; do
    printf '# %s\n' "$f" > "$d/$f.md" || return 1
    printf '%s\n' 'This concrete artifact documents the problem, design and acceptance for this branch. It contains real decisions and a complete implementation plan, with meaningful checks and no scaffold tokens. This prose is deliberately longer than two hundred bytes.' >> "$d/$f.md" || return 1
  done
}

stack() {
  git checkout -qb feature/a main
  lines src/a.js 600
  if [ "${1:-}" = triad ]; then triad 001-parent; fi
  git add -A
  git commit -qm parent
  ATIP="$(git rev-parse HEAD)"
  git checkout -qb feature/b feature/a
  git config branch.feature/b.trellisParent feature/a
  git config branch.feature/b.trellisBase "$ATIP"
  lines src/b.js "${2:-120}"
  git add -A
  git commit -qm child
  BTIP="$(git rev-parse HEAD)"
}

# Receipt shape, uniqueness, resolved base and before-verdict placement.
receipt() {
  local expected="$1" text="$2" head="${3:-feature/b}" first
  [ "$(printf '%s\n' "$text" | grep -c '^diff-base: ')" -eq 1 ] || return 1
  first="${text%%$'\n'*}"
  printf '%s\n' "$first" | grep -Eq '^diff-base: [0-9a-f]{12} [^ ]+ via (explicit|pr-cache|recorded|reflog|upstream|default|refused) \(.*\) range=[^ ]+ head=[^ ]+$' || return 1
  [[ "$first" == "diff-base: ${expected:0:12} "* ]] || return 1
  [[ "$first" == *" head=$head" ]] || return 1
}
marker() {
  mkdir -p .claude
  printf '%s\n' feature/b "$REPO_DIR" "$1" "$BTIP" old-session surgical 'legacy declaration' > .claude/session-surgical
}

@test "stacked over-floor B cannot use A's triad or a tasks-only tick; B's own triad passes" {
  stack triad
  printf '\n- [x] parent task completed by B\n' >> specs/001-parent/tasks.md
  git add specs/001-parent/tasks.md
  git commit -qm 'tick parent task'
  local gate
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate
    [ "$status" -eq 1 ]
    receipt "$ATIP" "$output"
    [[ "$output" == *'120 gated lines over floor 80'* ]]
  done
  triad 002-child
  git add specs/002-child
  git commit -qm 'child triad'
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate
    [ "$status" -eq 0 ]
    receipt "$ATIP" "$output"
  done
}

@test "A without a triad does not block sub-floor B for A's lines" {
  stack no-triad 20
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$ATIP" "$output"
  run bash -c '. "$1"; sg_verdict "$PWD"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'sub-floor(20<=80)' ]]
}

@test "sub-floor B passes without its own triad even when A has a triad" {
  stack triad 20
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$ATIP" "$output"
  run bash -c '. "$1"; sg_verdict "$PWD"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'sub-floor(20<=80)' ]]
  [[ "$output" != *'spec-triad('* ]]
}

@test "new surgical marker and verdict share the parent base and B-only ceiling" {
  stack no-triad
  run bash "$GATE" --mark 'mechanical child change'
  [ "$status" -eq 0 ]
  [ "$(awk 'NR == 3 {print; exit}' .claude/session-surgical)" = "$ATIP" ]
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$ATIP" "$output"
  # 720 lines against main would exceed the 400-line surgical ceiling.
  run bash -c '. "$1"; sg_verdict "$PWD"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'surgical-marker'* ]]
}

@test "1.3.10 marker bound to the default-branch merge-base still validates" {
  stack no-triad
  marker "$M0"
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$ATIP" "$output"
}

@test "marker with an unrelated base does not validate" {
  stack no-triad
  git checkout -qb unrelated main
  lines src/unrelated.js 1
  git add src/unrelated.js
  git commit -qm unrelated
  local unrelated
  unrelated="$(git rev-parse HEAD)"
  git checkout -q feature/b
  marker "$unrelated"
  run bash "$GATE" --gate
  [ "$status" -eq 1 ]
  receipt "$ATIP" "$output"
  [[ "$output" == *'no valid surgical declaration'* ]]
}

@test "explicit carrier range fixes both diff size and triad discovery to its end" {
  stack no-triad
  triad 002-child
  lines src/later.js 20
  git add specs/002-child src/later.js
  git commit -qm 'later child code and triad'
  local gate flag
  for gate in "$GATE" "$CODEX_GATE"; do
    for flag in equals split; do
      if [ "$flag" = equals ]; then
        run bash "$gate" --gate --range="$ATIP..$BTIP"
      else
        run bash "$gate" --gate --range "$ATIP..$BTIP"
      fi
      [ "$status" -eq 1 ]
      receipt "$ATIP" "$output"
      [[ "$output" == *'via explicit (explicit)'* ]]
      [[ "$output" == *"range=$ATIP..$BTIP"* ]]
      [[ "$output" == *'120 gated lines over floor 80'* ]]
    done
  done
}

@test "non-ancestor explicit range is verbatim, never three-dot normalized" {
  stack no-triad 20
  git checkout -q main
  lines src/moved-main.js 150
  git add src/moved-main.js
  git commit -qm 'main advanced'
  local m1
  m1="$(git rev-parse HEAD)"
  git checkout -q feature/b
  run bash "$GATE" --gate --range=main..HEAD
  [ "$status" -eq 1 ]
  receipt "$m1" "$output"
  [[ "$output" == *'start not ancestor of head (tree diff)'* ]]
  [[ "$output" == *'range=main..HEAD'* ]]
  [[ "$output" == *'770 gated lines over floor 80'* ]]
}

@test "missing resolver blocks --gate even with pipeline disabled; marker write fails" {
  stack no-triad 20
  printf '{"mandatory_pipeline":{"enabled":false}}\n' > .trellis.json
  mv "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$SANDBOX/saved-resolver.sh"
  local gate
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate
    [ "$status" -eq 1 ]
    [[ "$output" == *'BLOCKED: diff-base resolver missing'* ]]
  done
  run bash "$GATE" --mark 'cannot bind without resolver'
  [ "$status" -eq 1 ]
  [ ! -e .claude/session-surgical ]
}

@test "disabled, protected and detached skips retain their verdict and one receipt" {
  stack no-triad
  printf '{"mandatory_pipeline":{"enabled":false}}\n' > .trellis.json
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$ATIP" "$output"
  git checkout -- .trellis.json
  git checkout -q main
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$M0" "$output" main
  git checkout -q --detach "$BTIP"
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$M0" "$output" detached
  [[ "$output" == *'advisory: detached-or-unknown-branch'* ]]
}

@test "unresolvable explicit range refuses instead of passing a sub-floor branch" {
  stack no-triad 20
  run bash "$GATE" --gate --range=missing..HEAD
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^diff-base: ')" -eq 1 ]
  printf '%s\n' "${output%%$'\n'*}" | grep -Eq '^diff-base: - - via refused \(.*\) range=- head=feature/b$'
  [[ "$output" == *'BLOCKED: cannot-resolve-diff-base'* ]]
}

# R21: each assertion starts from its own X/Y fixture; fixture errors are fatal.
foreign_ref() {
  local kind="$1" n="${2:-120}" ceiling="${3:-400}" f
  git checkout -qb feature/x main || return 1
  lines src/x.js "$n" || return 1
  if [ "$kind" = triad-x ]; then triad 003-ref || return 1; fi
  if [ "$kind" = triad-y ]; then
    mkdir -p specs/003-ref || return 1
    for f in spec plan tasks; do printf 'TODO-SPEC %0250d\n' 0 > "specs/003-ref/$f.md" || return 1; done
  fi
  printf '{"template":{"branch":"main"},"autonomy":3,"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":%s}}\n' "$ceiling" > .trellis.json || return 1
  git add -A || return 1
  git commit -qm 'pushed X' || return 1
  XTIP="$(git rev-parse HEAD)" || return 1
  git checkout -qb feature/y main || return 1
  lines src/y.js 10 || return 1
  if [ "$kind" = triad-y ]; then triad 003-ref || return 1; fi
  git add -A || return 1
  git commit -qm 'checked out Y' || return 1
}

foreign_marker() {
  mkdir -p .claude || return 1
  printf '%s\n' feature/x "$REPO_DIR" "${2:-$M0}" "$XTIP" ref-session "$1" R21 > .claude/session-surgical || return 1
}

@test "R21 ref alone judges X, not the sub-floor checked-out Y" {
  foreign_ref no-triad || return 1
  run bash "$GATE" --gate --ref feature/x
  [ "$status" -eq 1 ]
  receipt "$M0" "$output" feature/x || return 1
  [[ "$output" == *'120 gated lines over floor 80'* ]]
}

@test "R21 emergency audit names pushed X, not checked-out Y" {
  foreign_ref no-triad 600 || return 1
  foreign_marker emergency || return 1
  run bash "$CODEX_GATE" --gate --ref=refs/heads/feature/x --head="$XTIP" --range="$M0..$XTIP"
  [ "$status" -eq 0 ]
  grep -Fq $'emergency-override\tfeature/x\tdiff=600\tR21' .claude/spec-gate-audit.log
}

@test "R21 X-bound surgical marker is honoured from Y" {
  foreign_ref no-triad || return 1
  foreign_marker surgical || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP" --range "$M0..$XTIP"
  [ "$status" -eq 0 ]
  receipt "$M0" "$output" feature/x || return 1
}

@test "R21 committed triad and clarify in X count when absent from Y" {
  foreign_ref triad-x || return 1
  run bash "$CODEX_GATE" --gate --ref feature/x --head "$XTIP" --range "$M0..$XTIP"
  [ "$status" -eq 0 ]
  receipt "$M0" "$output" feature/x || return 1
}

@test "R21 filled triad only in Y cannot validate X's scaffold" {
  foreign_ref triad-y || return 1
  run bash "$GATE" --gate --ref=feature/x --head="$XTIP" --range="$M0..$XTIP"
  [ "$status" -eq 1 ]
  [[ "$output" == *'no in-range spec triad'* ]]
}

@test "R21 pushed policy ceiling 800 wins over canonical worktree ceiling 400" {
  foreign_ref no-triad 600 800 || return 1
  foreign_marker surgical || return 1
  run bash -c '. "$1"; sg_verdict "$PWD" "$2" feature/x "$3"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$M0..$XTIP" "$XTIP"
  [ "$status" -eq 0 ]
  [[ "$output" == $'pass\t'* ]] || return 1
  [[ "$output" == *'head=feature/x'* ]] || return 1
  [[ "$output" == *'surgical-marker'* ]]
}

@test "R21 ref autonomy uses X's decisions log rather than Y's L3 interview path" {
  foreign_ref triad-x || return 1
  git checkout -q feature/x || return 1
  git rm -q specs/003-ref/clarify.md || return 1
  printf '{"autonomy":4,"mandatory_pipeline":{"enabled":true}}\n' > .trellis.json || return 1
  printf 'feature/x: intake decisions recorded\n' > decisions-log.md || return 1
  git add -A || return 1
  git commit -qm 'X L4 interview' || return 1
  XTIP="$(git rev-parse HEAD)" || return 1
  git checkout -q feature/y || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP" --range "$M0..$XTIP"
  [ "$status" -eq 0 ]
}

@test "R21 legacy marker base is computed against X's head rather than Y's" {
  foreign_ref no-triad || return 1
  git checkout -q main || return 1
  lines src/main.js 1 || return 1
  git add -A || return 1
  git commit -qm 'main advanced' || return 1
  git update-ref refs/remotes/origin/main HEAD || return 1
  git branch -f feature/y HEAD || return 1
  git checkout -q feature/x || return 1
  git checkout -qb parent/x || return 1
  lines src/parent.js 1 || return 1
  git add -A || return 1
  git commit -qm 'parent tip' || return 1
  local parent
  parent="$(git rev-parse HEAD)" || return 1
  git branch -f feature/x HEAD || return 1
  git config branch.feature/x.trellisParent parent/x || return 1
  git config branch.feature/x.trellisBase "$parent" || return 1
  git checkout -q feature/x || return 1
  lines src/child.js 120 || return 1
  git add -A || return 1
  git commit -qm 'X child' || return 1
  XTIP="$(git rev-parse HEAD)" || return 1
  git checkout -q feature/y || return 1
  foreign_marker surgical "$M0" || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP"
  [ "$status" -eq 0 ]
  receipt "$parent" "$output" feature/x || return 1
}

@test "R21 explicit head pins an older X commit rather than its moved branch tip" {
  foreign_ref no-triad 20 || return 1
  git checkout -q feature/x || return 1
  lines src/x.js 600 || return 1
  git add -A || return 1
  git commit -qm 'X tip moved' || return 1
  git checkout -q feature/y || return 1
  run bash "$CODEX_GATE" --gate --ref feature/x --head "$XTIP"
  [ "$status" -eq 0 ]
  receipt "$M0" "$output" feature/x || return 1
  [[ "$output" == *"range=${M0:0:12}..${XTIP:0:12}"* ]]
}

@test "R21 absent ref policy falls back to runtime, never the canonical policy" {
  foreign_ref no-triad || return 1
  git checkout -q feature/x || return 1
  git rm -q .trellis.json || return 1
  git commit -qm 'X has no project policy' || return 1
  XTIP="$(git rev-parse HEAD)" || return 1
  git checkout -q feature/y || return 1
  printf '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":200}}\n' > "$RUNTIME/trellis.config.json" || return 1
  run bash -c '. "$1"; sg_verdict "$PWD" "$2" feature/x "$3"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$M0..$XTIP" "$XTIP"
  [ "$status" -eq 0 ]
  [[ "$output" == $'pass\t'* ]] || return 1
  [[ "$output" == *'sub-floor(121<=200)'* ]]
}

@test "R21 malformed committed policy blocks even though Y has valid policy" {
  foreign_ref no-triad 20 || return 1
  git checkout -q feature/x || return 1
  printf '{ invalid JSON\n' > .trellis.json || return 1
  git add .trellis.json || return 1
  git commit -qm 'malformed X policy' || return 1
  XTIP="$(git rev-parse HEAD)" || return 1
  git checkout -q feature/y || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP"
  [ "$status" -eq 1 ]
  [[ "$output" == *'config present but malformed'* ]]
}

@test "R21 resolver default policy also comes from X rather than the Y worktree" {
  foreign_ref no-triad || return 1
  printf '{"template":{"branch":"feature/y"},"mandatory_pipeline":{"enabled":true}}\n' > .trellis.json || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP"
  [ "$status" -eq 1 ]
  [[ "$output" == "diff-base: ${M0:0:12} origin/main via default "* ]]
}

# BGSEC-A: spec-gate's default base follows the base's template.branch, never
# the head tree's. A pushed X naming a real remote branch that holds its
# over-floor commit must not shrink the range to the small tail.
@test "BGSEC-A a head-tree template.branch naming a real remote branch does not change spec-gate's range" {
  # Inversion: injecting X's policy bases the range on origin/side (x1), so
  # only x2's lines are counted and the over-floor branch passes.
  git checkout -qb feature/x main || return 1
  lines src/x.js 120 || return 1
  git add -A || return 1
  git commit -qm x1 || return 1
  git update-ref refs/remotes/origin/side "$(git rev-parse HEAD)" || return 1
  printf '{"template":{"branch":"side"},"autonomy":3,"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}\n' > .trellis.json || return 1
  lines src/tail.js 5 || return 1
  git add -A || return 1
  git commit -qm x2 || return 1
  XTIP="$(git rev-parse HEAD)" || return 1
  git checkout -q main || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  receipt "$M0" "$output" feature/x || { echo "$output"; return 1; }
  [[ "$output" == *"range=${M0:0:12}..${XTIP:0:12}"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'over floor 80'* ]] || { echo "$output"; return 1; }
}
