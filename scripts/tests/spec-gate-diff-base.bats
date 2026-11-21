#!/usr/bin/env bats
# spec 067 T8: option-1 stacked semantics, exact ranges and marker compatibility.
# Synthetic git state only. Each test's inversion is recorded in W108/REPORT.md.

setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)" || return 1
  SANDBOX="$BATS_TEST_TMPDIR/spec-gate"
  REPO_DIR="$SANDBOX/repo"
  RUNTIME="$SANDBOX/runtime"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis-home"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
  mkdir -p "$HOME" "$TRELLIS_HOME" "$REPO_DIR" "$RUNTIME/core-rules/hooks/lib" \
    "$RUNTIME/core-rules/codex/hooks" "$RUNTIME/core-rules/skills/process-gate/scripts/lib" || return 1
  cp "$SOURCE/core-rules/hooks/spec-gate.sh" "$RUNTIME/core-rules/hooks/" || return 1
  cp "$SOURCE/core-rules/codex/hooks/spec-gate.sh" "$RUNTIME/core-rules/codex/hooks/" || return 1
  cp "$SOURCE/core-rules/hooks/lib/"{spec-gate-core,deps,deps-heavy,autonomy}.sh "$RUNTIME/core-rules/hooks/lib/" || return 1
  cp "$SOURCE/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$RUNTIME/core-rules/skills/process-gate/scripts/lib/" || return 1
  export TRELLIS_ROOT="$RUNTIME"
  GATE="$RUNTIME/core-rules/hooks/spec-gate.sh"
  CODEX_GATE="$RUNTIME/core-rules/codex/hooks/spec-gate.sh"
  cd "$REPO_DIR" || return 1
  # Hand-written legacy/ref markers must bind the same physical root as the
  # real writer, not the caller's possibly symlinked TMPDIR spelling.
  REPO_DIR="$(pwd -P)" || return 1
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
    [[ "$output" == *'120 gated lines over floor 80'* ]] || false
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
  [[ "$output" == *'sub-floor(20<=80)' ]] || false
}

@test "sub-floor B passes without its own triad even when A has a triad" {
  stack triad 20
  run bash "$GATE" --gate
  [ "$status" -eq 0 ]
  receipt "$ATIP" "$output"
  run bash -c '. "$1"; sg_verdict "$PWD"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'sub-floor(20<=80)' ]] || false
  [[ "$output" != *'spec-triad('* ]] || false
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
  [[ "$output" == *'surgical-marker'* ]] || false
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
  [[ "$output" == *'no valid surgical declaration'* ]] || false
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
      [[ "$output" == *'via explicit (explicit)'* ]] || false
      [[ "$output" == *"range=$ATIP..$BTIP"* ]] || false
      [[ "$output" == *'120 gated lines over floor 80'* ]] || false
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
  [[ "$output" == *'start not ancestor of head (tree diff)'* ]] || false
  [[ "$output" == *'range=main..HEAD'* ]] || false
  [[ "$output" == *'770 gated lines over floor 80'* ]] || false
}

@test "broken core or invalid verdict blocks both twins without blocking valid passes" {
  stack no-triad 20 || return 1
  local core="$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" gate mode expected
  cp "$core" "$SANDBOX/intact-core" || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
  for mode in syntax missing nonzero unknown empty; do
    cp "$SANDBOX/intact-core" "$core" || return 1
    case "$mode" in
      # A source line number can move inside a quoted jq program after a
      # refactor. Append an unconditional shell parse error, not inert text.
      syntax) printf '\nif then\n' >> "$core"
              if bash -n "$core" >/dev/null 2>&1; then return 1; fi ;;
      missing) printf '\nunset -f sg_verdict\n' >> "$core" ;;
      nonzero) printf '\nsg_verdict() { printf "pass\\tignored"; return 42; }\n' >> "$core" ;;
      unknown) printf '\nsg_verdict() { printf "unexpected\\tignored"; }\n' >> "$core" ;;
      empty) printf '\nsg_verdict() { :; }\n' >> "$core" ;;
    esac
    for gate in "$GATE" "$CODEX_GATE"; do
      run bash "$gate" --gate
      [ "$status" -eq 1 ] || { echo "$mode $gate: $output"; return 1; }
      [[ "$output" == *'BLOCKED'* ]] || { echo "$output"; return 1; }
      expected=0
      [ "$gate" = "$GATE" ] && expected=2
      run bash -c 'printf "{}" | bash "$1"' _ "$gate"
      [ "$status" -eq "$expected" ] || { echo "$mode $gate: $output"; return 1; }
      [[ "$output" == *'"decision":"block"'* ]] || { echo "$output"; return 1; }
      run bash -c 'printf "{\"stop_hook_active\":true}" | bash "$1"' _ "$gate"
      [ "$status" -eq 0 ] || return 1
      [[ "$output" != *'"decision":"block"'* ]] || return 1
    done
  done
}

@test "missing resolver blocks --gate even with pipeline disabled; marker write fails" {
  stack no-triad 20
  printf '{"mandatory_pipeline":{"enabled":false}}\n' > .trellis.json
  mv "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$SANDBOX/saved-resolver.sh"
  local gate
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate
    [ "$status" -eq 4 ]
    [[ "$output" == *'BLOCKED: diff-base resolver missing from trusted runtime'* ]] || false
  done
  run bash "$GATE" --mark 'cannot bind without resolver'
  [ "$status" -eq 1 ]
  [ ! -e .claude/session-surgical ]
}

@test "T27 SC11: disabled and protected skips pass but detached blocks with one receipt" {
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
  [ "$status" -eq 1 ]
  receipt "$M0" "$output" detached
  [[ "$output" == *'BLOCKED: detached-or-unknown-branch'* ]] || false
}

@test "unresolvable explicit range refuses instead of passing a sub-floor branch" {
  stack no-triad 20
  run bash "$GATE" --gate --range=missing..HEAD
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^diff-base: ')" -eq 1 ]
  printf '%s\n' "${output%%$'\n'*}" | grep -Eq '^diff-base: - - via refused \(.*\) range=- head=feature/b$'
  [[ "$output" == *'BLOCKED: cannot-resolve-diff-base'* ]] || false
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

@test "R21 marker fixtures survive a symlinked temp directory in both twins" {
  mkdir -p "$BATS_TEST_TMPDIR/physical" || return 1
  ln -s "$BATS_TEST_TMPDIR/physical" "$BATS_TEST_TMPDIR/linked" || return 1
  (
    export BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/linked"
    setup || return 1
    foreign_ref no-triad || return 1
    local gate mode
    for gate in "$GATE" "$CODEX_GATE"; do
      for mode in surgical emergency; do
        foreign_marker "$mode" || return 1
        run bash "$gate" --gate --ref feature/x --head "$XTIP" --range "$M0..$XTIP"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        receipt "$M0" "$output" feature/x || return 1
      done
    done
    grep -Fq $'emergency-override\tfeature/x\tdiff=120\tR21' .claude/spec-gate-audit.log || return 1
  ) || return 1
}

@test "R21 ref alone judges X, not the sub-floor checked-out Y" {
  foreign_ref no-triad || return 1
  run bash "$GATE" --gate --ref feature/x
  [ "$status" -eq 1 ]
  receipt "$M0" "$output" feature/x || return 1
  [[ "$output" == *'120 gated lines over floor 80'* ]] || false
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
  [[ "$output" == *'no in-range spec triad'* ]] || false
}

@test "R21 pushed policy ceiling 800 wins over canonical worktree ceiling 400" {
  foreign_ref no-triad 600 800 || return 1
  foreign_marker surgical || return 1
  run bash -c '. "$1"; sg_verdict "$PWD" "$2" feature/x "$3"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$M0..$XTIP" "$XTIP"
  [ "$status" -eq 0 ]
  [[ "$output" == $'pass\t'* ]] || return 1
  [[ "$output" == *'head=feature/x'* ]] || return 1
  [[ "$output" == *'surgical-marker'* ]] || false
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
  [[ "$output" == *"range=${M0:0:12}..${XTIP:0:12}"* ]] || false
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
  [[ "$output" == *'sub-floor(121<=200)'* ]] || false
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
  [[ "$output" == *'config present but malformed'* ]] || false
}

@test "R21 resolver default policy also comes from X rather than the Y worktree" {
  foreign_ref no-triad || return 1
  printf '{"template":{"branch":"feature/y"},"mandatory_pipeline":{"enabled":true}}\n' > .trellis.json || return 1
  run bash "$GATE" --gate --ref feature/x --head "$XTIP"
  [ "$status" -eq 1 ]
  [[ "$output" == "diff-base: ${M0:0:12} origin/main via default "* ]] || false
}

@test "L4 triad passes without requiring a decisions-log entry at head or in the worktree" {
  git checkout -qb feature/pay main || return 1
  lines src/large.js 120 || return 1
  triad 010-intake || return 1
  rm -f specs/010-intake/clarify.md
  printf '{"template":{"branch":"main"},"autonomy":4,"mandatory_pipeline":{"enabled":true}}\n' > .trellis.json || return 1
  git add -A && git commit -qm 'l4 triad without decisions-log' || return 1
  local tip gate
  tip="$(git rev-parse HEAD)" || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --ref feature/pay --head "$tip" --range "$M0..$tip"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run bash "$gate" --gate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
}

@test "rename accounting classifies the destination without inflating benign moves" {
  mkdir -p specs/007-doc src docs || return 1
  lines specs/007-doc/notes.md 1000 || return 1
  lines specs/007-doc/archive.md 1000 || return 1
  lines src/original.ts 1000 || return 1
  git add -A && git commit -qm 'seed rename sources' || return 1
  local base tip gate
  base="$(git rev-parse HEAD)" || return 1
  git update-ref refs/remotes/origin/main "$base" || return 1
  git checkout -qb feature/doc-to-code || return 1
  git mv specs/007-doc/notes.md src/engine.ts || return 1
  lines src/extra-lines 120 || return 1
  command cat src/extra-lines >> src/engine.ts || return 1
  rm -f "${REPO_DIR:?}/src/extra-lines" || return 1
  git add -A && git commit -qm 'convert prose to code' || return 1
  tip="$(git rev-parse HEAD)" || return 1
  [[ "$(git diff --numstat "$base..$tip")" == *'=> src/engine.ts'* ]] || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --ref feature/doc-to-code --head "$tip" --range "$base..$tip"
    [ "$status" -eq 1 ] && [[ "$output" == *'120 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
  done
  git checkout -qb feature/benign-renames main || return 1
  git mv src/original.ts src/renamed.ts || return 1
  git mv specs/007-doc/archive.md docs/archive.md || return 1
  printf 'small code change\n' >> src/renamed.ts || return 1
  printf 'doc change\n' >> docs/archive.md || return 1
  git add -A && git commit -qm 'move files' || return 1
  tip="$(git rev-parse HEAD)" || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --ref feature/benign-renames --head "$tip" --range "$base..$tip"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
}

@test "head policy cannot declare its feature branch protected" {
  git checkout -qb feature/self main || return 1
  lines src/large.js 120 || return 1
  printf '{"template":{"branch":"feature/self"},"mandatory_pipeline":{"enabled":true}}\n' > .trellis.json || return 1
  git add -A && git commit -qm 'attempt protected-branch bypass' || return 1
  local tip gate
  tip="$(git rev-parse HEAD)" || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --ref feature/self --head "$tip" --range "$M0..$tip"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *'over floor'* ]] || { echo "$output"; return 1; }
    run bash "$gate" --gate
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *'over floor'* ]] || { echo "$output"; return 1; }
  done
  git checkout -q main || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --ref main --head "$M0" --range "$M0..$M0"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
  # A non-main default selected by the base must still receive the exemption.
  printf '{"template":{"branch":"release/stable"},"mandatory_pipeline":{"enabled":true}}\n' > .trellis.json || return 1
  git add .trellis.json && git commit -qm 'base chooses release branch' || return 1
  git update-ref refs/remotes/origin/main HEAD || return 1
  git update-ref refs/remotes/origin/release/stable HEAD || return 1
  local release_base
  release_base="$(git rev-parse HEAD)" || return 1
  git checkout -qb release/stable || return 1
  lines src/release.js 120 || return 1
  git add -A && git commit -qm release || return 1
  tip="$(git rev-parse HEAD)" || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --ref release/stable --head "$tip" --range "$release_base..$tip"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
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

@test "spec-gate follows origin HEAD rather than the runtime main default in both twins" {
  git checkout -qb feat/slice-1-contracts main || return 1
  jq 'del(.template)' .trellis.json > "$SANDBOX/project-policy.json" || return 1
  mv "$SANDBOX/project-policy.json" .trellis.json || return 1
  lines src/contracts.js 120 || return 1
  git add -A || return 1
  git commit -qm 'remote default contracts' || return 1
  local trunk gate
  trunk="$(git rev-parse HEAD)" || return 1
  git update-ref refs/remotes/origin/feat/slice-1-contracts "$trunk" || return 1
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat/slice-1-contracts || return 1
  printf '{"template":{"branch":"main"}}\n' > "$RUNTIME/trellis.config.json" || return 1
  git checkout -qb feature/b || return 1
  git config branch.feature/b.trellisParent main || return 1
  git config branch.feature/b.trellisBase "$M0" || return 1
  lines src/child.js 20 || return 1
  git add -A || return 1
  git commit -qm 'small child on remote default' || return 1

  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    receipt "$trunk" "$output" || { echo "$output"; return 1; }
    [[ "$output" == *'origin/feat/slice-1-contracts via default (parent main merged → default)'* ]] || { echo "$output"; return 1; }
  done
}

@test "sweep-fx1: planted resolver in project .claude tree is never executed" {
  stack no-triad
  mv "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$SANDBOX/saved-resolver-planted.sh"
  mkdir -p ".claude/skills/process-gate/scripts/lib"
  cat > ".claude/skills/process-gate/scripts/lib/diff-base.sh" <<'SH'
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/sweep-fx1-planted-executed"
echo "planted resolver sourced" >&2
db_resolve() { DB_BASE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; DB_RANGE="HEAD"; return 0; }
db_receipt() { printf 'planted'; }
db_defbranch() { _dd_ref="feature/evil"; return 0; }
SH
  chmod +x ".claude/skills/process-gate/scripts/lib/diff-base.sh"
  rm -f "$BATS_TEST_TMPDIR/sweep-fx1-planted-executed"
  run bash "$GATE" --gate
  # With no trusted runtime resolver, the gate must refuse with exit 4
  # without sourcing the planted project file.
  [ "$status" -eq 4 ]
  [[ "$output" == *"trusted"* || "$output" == *"runtime"* ]] || false
  [ ! -e "$BATS_TEST_TMPDIR/sweep-fx1-planted-executed" ]
  mv "$SANDBOX/saved-resolver-planted.sh" "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
}

@test "sweep-fx1: missing trusted resolver refuses with exit 4" {
  stack no-triad
  mv "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$SANDBOX/saved-resolver.sh"
  run bash "$GATE" --gate
  [ "$status" -eq 4 ]
  [[ "$output" == *"trusted"* || "$output" == *"runtime"* ]] || false
  mv "$SANDBOX/saved-resolver.sh" "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
}

@test "sweep-fx1-H4: direct-copy layout uses gate own dir and passes" {
  # Simulate legacy direct-copy install: no TRELLIS_ROOT, gate lives in project .claude/hooks,
  # resolver beside it in .claude/skills. Must not refuse with 4.
  local proj="$SANDBOX/direct-copy"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/hooks/lib" "$proj/.claude/skills/process-gate/scripts/lib"
  cp "$SOURCE/core-rules/hooks/spec-gate.sh" "$proj/.claude/hooks/"
  cp "$SOURCE/core-rules/hooks/lib/spec-gate-core.sh" "$proj/.claude/hooks/lib/"
  cp "$SOURCE/core-rules/hooks/lib/deps.sh" "$SOURCE/core-rules/hooks/lib/deps-heavy.sh" "$proj/.claude/hooks/lib/"
  cp "$SOURCE/core-rules/hooks/lib/autonomy.sh" "$proj/.claude/hooks/lib/"
  cp "$SOURCE/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$proj/.claude/skills/process-gate/scripts/lib/"
  cd "$proj" || return 1
  git init -q -b main
  git config user.email t@t.invalid
  git config user.name t
  git config core.hooksPath "$SANDBOX/no-hooks"
  printf '{"template":{"branch":"main"},"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80}}\n' > .trellis.json
  printf 'seed\n' > README.md
  git add -A
  git commit -qm seed
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  git checkout -qb feat
  # Unset runtime to force gate-own-dir resolution
  run env -u TRELLIS_ROOT bash -p .claude/hooks/spec-gate.sh --gate
  [ "$status" -eq 0 ]
  cd "$REPO_DIR" || return 1
}

# A direct-copy project with the gate installed under $2 (.claude/hooks or
# .codex/hooks) and process-gate under $3, committed on main with branch feat.
direct_copy_project() {
  local proj="$1" hooks="$2" skills="$3" twin=""
  rm -rf "$proj"
  mkdir -p "$proj/$hooks/lib" "$proj/$skills/process-gate/scripts/lib" || return 1
  [ "$hooks" = .codex/hooks ] && twin=codex/
  cp "$SOURCE/core-rules/${twin}hooks/spec-gate.sh" "$proj/$hooks/" || return 1
  cp "$SOURCE/core-rules/hooks/lib/spec-gate-core.sh" "$proj/$hooks/lib/" || return 1
  cp "$SOURCE/core-rules/${twin}hooks/lib/deps.sh" "$SOURCE/core-rules/${twin}hooks/lib/deps-heavy.sh" "$SOURCE/core-rules/${twin}hooks/lib/autonomy.sh" "$proj/$hooks/lib/" || return 1
  cp "$SOURCE/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$proj/$skills/process-gate/scripts/lib/" || return 1
  cd "$proj" || return 1
  git init -q -b main
  git config user.email t@t.invalid
  git config user.name t
  git config core.hooksPath "$SANDBOX/no-hooks"
  printf '{"template":{"branch":"main"},"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80}}\n' > .trellis.json
  printf 'seed\n' > README.md
  git add -A
  git commit -qm seed
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  git checkout -qb feat
}

@test "sweep-fx1-R2-M1: Codex direct-copy gate resolves process-gate under its own .agents/skills" {
  direct_copy_project "$SANDBOX/codex-direct-copy" .codex/hooks .agents/skills || return 1
  run env -u TRELLIS_ROOT bash -p .codex/hooks/spec-gate.sh --gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff-base: "* ]] || false
  run env -u TRELLIS_ROOT CODEX_PROJECT_DIR="$PWD" bash .codex/hooks/spec-gate.sh <<<'{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"m1"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *'"block"'* ]] || false
  cd "$REPO_DIR" || return 1
}

@test "sweep-fx1-R2-M1: Claude direct-copy gate still resolves .claude/skills and ignores .agents/skills" {
  direct_copy_project "$SANDBOX/claude-direct-copy" .claude/hooks .claude/skills || return 1
  run env -u TRELLIS_ROOT bash -p .claude/hooks/spec-gate.sh --gate
  [ "$status" -eq 0 ]
  mkdir -p .agents/skills
  mv .claude/skills/process-gate .agents/skills/
  run env -u TRELLIS_ROOT bash -p .claude/hooks/spec-gate.sh --gate
  [ "$status" -eq 4 ]
  cd "$REPO_DIR" || return 1
}

@test "sweep-fx1-R2-M1: a runtime Codex gate never sources the project's .agents/skills" {
  stack no-triad
  mv "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh" "$SANDBOX/saved-resolver-agents.sh"
  mkdir -p .agents/skills/process-gate/scripts/lib
  printf 'touch "%s"\n' "$BATS_TEST_TMPDIR/agents-planted-executed" > .agents/skills/process-gate/scripts/lib/diff-base.sh
  run bash "$CODEX_GATE" --gate
  [ "$status" -eq 4 ]
  [ ! -e "$BATS_TEST_TMPDIR/agents-planted-executed" ]
  mv "$SANDBOX/saved-resolver-agents.sh" "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
}

# 1.5.3: declarations cover canonical branch scope, not one transport update.
sg153_verdict() {
  run bash -c '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"' _ \
    "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$1" "${2:-}" "${3:-}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
sg153_main() {
  local file="$1" count="$2" branch
  branch=$(git branch --show-current) || return 1
  git checkout -q main || return 1
  lines "$file" "$count" || return 1
  git add -- "$file" && git commit -qm 'protected changes' || return 1
  IMPORT_TIP=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$IMPORT_TIP" || return 1
  git checkout -q "$branch" || return 1
  git merge -q --no-ff main -m 'Merge protected changes' || return 1
}
sg153_widget() {
  git checkout -qb release/demo-base main || return 1
  lines src/parent.js 10 || return 1
  git add src/parent.js && git commit -qm parent || return 1
  DECL_BASE=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/demo-base "$DECL_BASE" || return 1
  git checkout -qb feature/widget || return 1
  git config branch.feature/widget.trellisParent refs/remotes/origin/demo-base || return 1
  git config branch.feature/widget.trellisBase "$DECL_BASE" || return 1
  lines src/already-pushed.js 5 || return 1
  git add src/already-pushed.js && git commit -qm 'previous push' || return 1
  REMOTE_OLD=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/widget "$REMOTE_OLD" || return 1
  lines src/first.js 45 || return 1
  git add src/first.js && git commit -qm 'first branch change' || return 1
  sg153_main src/protected-first.js 60 || return 1
  lines src/second.js 40 || return 1
  git add src/second.js && git commit -qm 'second branch change' || return 1
  sg153_main src/protected-second.js 60 || return 1
  WIDGET_HEAD=$(git rev-parse HEAD) || return 1
}

@test "153 marker validates an update range and later descendants in both twins" {
  stack no-triad 10 || return 1
  local old="$BTIP" declared head gate flag
  lines src/update.js 120 || return 1
  git add src/update.js && git commit -qm update || return 1
  declared=$(git rev-parse HEAD) || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    for flag in --mark --mark-emergency; do
      run bash "$gate" "$flag" 'mechanical update'
      [ "$status" -eq 0 ] || { echo "$output"; return 1; }
      [ "$(awk 'NR==3' .claude/session-surgical)" = "$ATIP" ]
      run bash "$gate" --gate --range "$old..$declared" --ref refs/heads/feature/b --head "$declared"
      [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
  done
  lines src/descendant.js 20 || return 1
  git add src/descendant.js && git commit -qm descendant || return 1
  head=$(git rev-parse HEAD) || return 1
  [ "$(awk 'NR==4' .claude/session-surgical)" = "$declared" ]
  run bash "$GATE" --gate --range "$old..$head" --ref refs/heads/feature/b --head "$head"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "153 widget-shaped non-default recorded parent discounts two protected merges and honors emergency" {
  sg153_widget || return 1
  sg153_verdict "$REMOTE_OLD..$WIDGET_HEAD" refs/heads/feature/widget "$WIDGET_HEAD" || return 1
  [[ "$output" == $'block\t'*'85 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"protected-imports: raw=205 discounted=85 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
  local gate
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --mark-emergency 'urgent long-lived branch update'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(awk 'NR==3' .claude/session-surgical)" = "$DECL_BASE" ]
    run bash "$gate" --gate --range "$REMOTE_OLD..$WIDGET_HEAD" --ref refs/heads/feature/widget --head "$WIDGET_HEAD"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
  grep -q 'emergency-override.*diff=90' .claude/spec-gate-audit.log
}

@test "153 protected-only imports do not force a triad and receipts bind both counts and anchor" {
  git checkout -qb feature/import main || return 1
  local old="$M0" head gate
  lines src/own.js 20 || return 1
  git add src/own.js && git commit -qm own || return 1
  sg153_main src/protected.js 120 || return 1
  head=$(git rev-parse HEAD) || return 1
  for gate in "$GATE" "$CODEX_GATE"; do
    run bash "$gate" --gate --range "$old..$head" --ref refs/heads/feature/import --head "$head"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"protected-imports: raw=140 discounted=20 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
  done
  sg153_verdict "$old..$head" refs/heads/feature/import "$head" || return 1
  [[ "$output" == *'sub-floor(20<=80)'* ]] || { echo "$output"; return 1; }
}

@test "153 cumulative surgical ceiling also discounts protected imports" {
  stack no-triad 250 || return 1
  sg153_main src/protected.js 250 || return 1
  local head
  head=$(git rev-parse HEAD) || return 1
  run bash "$GATE" --mark 'bounded mechanical branch'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(awk 'NR==3' .claude/session-surgical)" = "$ATIP" ]
  run bash "$GATE" --gate --range "$ATIP..$head" --ref refs/heads/feature/b --head "$head"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"protected-imports: raw=500 discounted=250 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
}

@test "153 repeated pushes cannot narrow a cumulative over-ceiling surgical declaration" {
  stack no-triad 300 || return 1
  local old="$BTIP" head
  lines src/update.js 120 || return 1
  git add src/update.js && git commit -qm update || return 1
  head=$(git rev-parse HEAD) || return 1
  run bash "$GATE" --mark 'not below cumulative ceiling'
  [ "$status" -eq 0 ] || return 1
  run bash "$GATE" --gate --range "$old..$head" --ref refs/heads/feature/b --head "$head"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -q 'oversized-surgical.*diff=420>ceiling=400' .claude/spec-gate-audit.log
}

@test "153 declaring HEAD must be present and ancestral; unknown marker mode never passes" {
  stack no-triad || return 1
  git checkout -qb feature/unrelated main || return 1
  git commit -q --allow-empty -m unrelated || return 1
  local other head mode
  other=$(git rev-parse HEAD) || return 1
  git checkout -q feature/b || return 1
  for head in '' nonexistent HEAD "$other"; do
    mkdir -p .claude
    printf '%s\n' feature/b "$REPO_DIR" "$ATIP" "$head" session emergency reason > .claude/session-surgical
    run bash "$GATE" --gate
    [ "$status" -eq 1 ] || { echo "head=$head: $output"; return 1; }
  done
  printf '%s\n' feature/b "$REPO_DIR" "$ATIP" "$BTIP" session unknown reason > .claude/session-surgical
  run bash "$GATE" --gate
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "153 a child declaration does not authorize an expanded or non-ancestor push range" {
  stack no-triad || return 1
  run bash "$GATE" --mark-emergency 'child only'
  [ "$status" -eq 0 ] || return 1
  run bash "$GATE" --gate --range "$M0..$BTIP" --ref refs/heads/feature/b --head "$BTIP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  git checkout -qb feature/side main || return 1
  lines src/side.js 100 || return 1
  git add src/side.js && git commit -qm side || return 1
  local side
  side=$(git rev-parse HEAD) || return 1
  git checkout -q feature/b || return 1
  run bash "$GATE" --gate --range "$side..$BTIP" --ref refs/heads/feature/b --head "$BTIP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "153 protected deletion is discounted but a private before-state deletion is not" {
  # Identical generated fixture lines must not turn a deletion/addition into a
  # zero-line rename before the protected-transition proof is exercised.
  git config diff.renames false || return 1
  lines src/obsolete.js 120 || return 1
  git add src/obsolete.js && git commit -qm seed-obsolete || return 1
  local old head
  old=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$old" || return 1
  git checkout -qb feature/delete || return 1
  lines src/own.js 20 || return 1
  git add src/own.js && git commit -qm own || return 1
  git checkout -q main || return 1
  git rm -q src/obsolete.js && git commit -qm remove-obsolete || return 1
  IMPORT_TIP=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$IMPORT_TIP" || return 1
  git checkout -q feature/delete && git merge -q --no-ff main -m 'Merge removal' || return 1
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$old..$head" refs/heads/feature/delete "$head" || return 1
  [[ "$output" == *'sub-floor(20<=80)'* ]] || { echo "$output"; return 1; }
  # Now a path introduced only by this branch is deleted to match protected absence.
  lines src/private.js 120 || return 1
  git add src/private.js && git commit -qm private || return 1
  old=$(git rev-parse HEAD) || return 1
  git rm -q src/private.js && git commit -qm remove-private || return 1
  sg153_main src/protected.js 120 || return 1
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$old..$head" refs/heads/feature/delete "$head" || return 1
  [[ "$output" == $'block\t'*'120 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
}

@test "153 mixed files retain the full count and later unmerged protected changes cannot discount it" {
  lines src/shared.js 100 || return 1
  git add src/shared.js && git commit -qm seed-shared || return 1
  local old head
  old=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$old" || return 1
  git checkout -qb feature/mixed || return 1
  printf 'branch-only\n' >> src/shared.js
  git add src/shared.js && git commit -qm branch || return 1
  git checkout -q main || return 1
  printf 'protected-only\n' > "$SANDBOX/shared"
  printf '%s\n' "$(< src/shared.js)" >> "$SANDBOX/shared"
  cp "$SANDBOX/shared" src/shared.js
  git add src/shared.js && git commit -qm protected || return 1
  IMPORT_TIP=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$IMPORT_TIP" || return 1
  git checkout -q feature/mixed && git merge -q --no-ff main -m 'Merge mixed edits' || return 1
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$old..$head" refs/heads/feature/mixed "$head" || return 1
  [[ "$output" == *'sub-floor(2<=80)'* ]] || { echo "$output"; return 1; }
  [[ "$output" != *'protected-imports:'* ]] || { echo "$output"; return 1; }
  # Unmerged protected content is not an authority for the range's after state.
  lines src/unique.js 120 || return 1
  git add src/unique.js && git commit -qm unique || return 1
  head=$(git rev-parse HEAD) || return 1
  git checkout -q main || return 1
  lines src/unique.js 120 || return 1
  git add src/unique.js && git commit -qm unmerged || return 1
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)" || return 1
  git checkout -q feature/mixed || return 1
  sg153_verdict "$old..$head" refs/heads/feature/mixed "$head" || return 1
  [[ "$output" == $'block\t'*'122 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
}

@test "153 literal hostile paths discount only the pinned protected transitions" {
  git checkout -qb feature/paths main || return 1
  local path head
  lines src/own.js 20 || return 1
  git add src/own.js && git commit -qm own || return 1
  git checkout -q main || return 1
  for path in 'src/space name.js' $'src/tab\tname.js' $'src/newline\nname.js' 'src/[glob]*.js'; do
    lines "$path" 30 || return 1
  done
  git add src && git commit -qm 'protected literal paths' || return 1
  IMPORT_TIP=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$IMPORT_TIP" || return 1
  git checkout -q feature/paths && git merge -q --no-ff main -m 'Merge literal paths' || return 1
  head=$(git rev-parse HEAD) || return 1
  lines src/later.js 120 || return 1
  git add src/later.js && git commit -qm later || return 1
  sg153_verdict "$M0..$head" refs/heads/feature/paths "$head" || return 1
  [[ "$output" == *'sub-floor(20<=80)'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"protected-imports: raw=140 discounted=20 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
}

@test "153 rename rows and missing or ambiguous import proof retain the raw count" {
  git config diff.renames true || return 1
  git checkout -qb feature/rename main || return 1
  lines src/old.js 150 || return 1
  git add src/old.js && git commit -qm private || return 1
  local old head
  old=$(git rev-parse HEAD) || return 1
  git checkout -q main || return 1
  lines src/new.js 100 || return 1
  git add src/new.js && git commit -qm protected || return 1
  IMPORT_TIP=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$IMPORT_TIP" || return 1
  git checkout -q feature/rename || return 1
  git mv src/old.js src/new.js || return 1
  lines src/new.js 100 || return 1
  git add src && git commit -qm 'rename and remove private tail' || return 1
  git merge -q --no-ff main -m 'Merge identical protected destination' || return 1
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$old..$head" refs/heads/feature/rename "$head" || return 1
  [[ "$output" == *'sub-floor(50<=80)'* ]] || { echo "$output"; return 1; }
  [[ "$output" != *'protected-imports:'* ]] || { echo "$output"; return 1; }

  git checkout -qb feature/proof main || return 1
  old=$(git rev-parse HEAD) || return 1
  lines src/own.js 20 || return 1
  git add src/own.js && git commit -qm own || return 1
  sg153_main src/imported.js 120 || return 1
  head=$(git rev-parse HEAD) || return 1
  local shim="$SANDBOX/git-shim" kind
  mkdir -p "$shim"
  export SG153_REAL_GIT SG153_ANCHOR="$IMPORT_TIP" SG153_OLD="$old"
  SG153_REAL_GIT=$(command -v git) || return 1
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'diff --numstat -z'*)
    case "$SG153_PROBE" in
      raw-truncated) printf '140\t0\tsrc/imported.js'; exit 0 ;;
      raw-invalid) printf 'invalid\t0\tsrc/imported.js\0'; exit 0 ;;
    esac ;;
  *'merge-base --all'*)
    if [ "$SG153_PROBE" = ambiguous ]; then printf '%s\n%s\n' "$SG153_OLD" "$SG153_ANCHOR"; exit 0; fi ;;
  *diff-tree*)
    case "$SG153_PROBE" in
      error) exit 42 ;;
      truncated) printf 'src/own.js'; exit 0 ;;
    esac ;;
esac
exec "$SG153_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"
  for kind in error truncated ambiguous; do
    run env PATH="$shim:$PATH" SG153_PROBE="$kind" bash -c '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"' _ \
      "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$old..$head" refs/heads/feature/proof "$head"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == $'block\t'*'140 gated lines over floor 80'* ]] || { echo "$kind: $output"; return 1; }
    [[ "$output" != *'protected-imports:'* ]] || { echo "$output"; return 1; }
  done
  for kind in raw-truncated raw-invalid; do
    run env PATH="$shim:$PATH" SG153_PROBE="$kind" bash -c '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"' _ \
      "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$old..$head" refs/heads/feature/proof "$head"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == $'block\t'*'cannot-compute-diff-baseline'* ]] || { echo "$kind: $output"; return 1; }
  done
}

@test "153 pure protected imports are zero under Bash 3.2 nounset without scratch leaks" {
  git checkout -qb feature/pure main || return 1
  sg153_main src/protected.js 120 || return 1
  local head
  head=$(git rev-parse HEAD) || return 1
  export TMPDIR="$SANDBOX/count-tmp"
  mkdir -m 700 "$TMPDIR" || return 1
  run /bin/bash -uc '. "$1"; sg_compute_gated_diff "$2" "$3"' _ \
    "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$REPO_DIR" "$M0..$head"
  [ "$status" -eq 0 ] && [ "$output" = 0 ] || { echo "$output"; return 1; }
  run /bin/bash -uc '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"' _ \
    "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$M0..$head" refs/heads/feature/pure "$head"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == $'pass\t'*'sub-floor(0<=80)'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"protected-imports: raw=120 discounted=0 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
  [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'trellis-spec-diff.*' -print)" ]
}

@test "153 malformed measurement protocol cannot authorize a surgical or emergency route" {
  stack no-triad || return 1
  run bash "$GATE" --mark-emergency 'requires a known count'
  [ "$status" -eq 0 ] || return 1
  local value
  for value in '' garbage $'120\tbad\t-'; do
    run env SG153_MEASURE="$value" bash -c '. "$1"
      _sg_measure_gated_diff() { printf "%s" "$SG153_MEASURE"; }
      sg_verdict "$PWD" "$2" "$3" "$4"' _ \
      "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$ATIP..$BTIP" refs/heads/feature/b "$BTIP"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == $'block\t'*'cannot-compute-diff-baseline'* ]] || { echo "$output"; return 1; }
    run env SG153_MEASURE="$value" bash -c '. "$1"
      _sg_measure_gated_diff() { printf "%s" "$SG153_MEASURE"; }
      sg_compute_gated_diff "$PWD" "$2"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$ATIP..$BTIP"
    [ "$status" -eq 0 ] && [ "$output" = -1 ] || { echo "$output"; return 1; }
    run env SG153_MEASURE="$value" bash -c '. "$1"
      _sg_measure_gated_diff() { printf "%s" "$SG153_MEASURE"; }
      if sg_valid_marker "$PWD" "$PWD" "$2" 120 400 feature/b "$3"; then exit 5; fi' _ \
      "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$ATIP" "$BTIP"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e .claude/spec-gate-audit.log ]
  done
}

@test "153 contradictory explicit head refuses and ref-only historical ranges use historical policy" {
  stack no-triad 350 || return 1
  local first="$BTIP" later historical
  run bash "$GATE" --mark 'first bounded state'
  [ "$status" -eq 0 ] || return 1
  lines src/later.js 100 || return 1
  git add src/later.js && git commit -qm 'over ceiling later' || return 1
  later=$(git rev-parse HEAD) || return 1
  run bash "$GATE" --gate --ref refs/heads/feature/b --head "$later" --range "$ATIP..$first"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *'range-head-mismatch'* ]] || { echo "$output"; return 1; }

  git checkout -qb feature/historical main || return 1
  lines src/own.js 120 || return 1
  triad 003-historical || return 1
  rm specs/003-historical/clarify.md || return 1
  git add src/own.js specs/003-historical && git commit -qm 'triad without interview' || return 1
  historical=$(git rev-parse HEAD) || return 1
  mkdir -p .claude
  printf 'later waiver\n' > .claude/spec-waiver
  git add .claude/spec-waiver && git commit -qm 'later interview waiver' || return 1
  run bash "$GATE" --gate --ref refs/heads/feature/historical --range "$M0..$historical"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *'interview artifact is missing'* ]] || { echo "$output"; return 1; }
  later=$(git rev-parse HEAD) || return 1
  run bash "$GATE" --gate --ref refs/heads/feature/historical --head "$later" --range "$M0..$later"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "153 compatibility API keeps root-relative paths with diff.relative enabled" {
  git checkout -qb feature/sub main || return 1
  lines src/app.js 120 || return 1
  git add src/app.js && git commit -qm own || return 1
  sg153_main src/protected.js 10 || return 1
  local head
  head=$(git rev-parse HEAD) || return 1
  git config diff.relative true || return 1
  run bash -c '. "$1"; sg_compute_gated_diff "$2/src" "$3"' _ \
    "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$REPO_DIR" "$M0..$head"
  [ "$status" -eq 0 ] && [ "$output" = 120 ] || { echo "$output"; return 1; }
}

@test "153 extra range delimiters are refused rather than silently normalized" {
  stack no-triad 20 || return 1
  local range gate
  for range in "$ATIP..not-a-rev..$BTIP" "$ATIP..$M0 $ATIP..$BTIP"; do
    for gate in "$GATE" "$CODEX_GATE"; do
      run bash "$gate" --gate --range "$range"
      [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    done
    run bash -c '. "$1"; sg_compute_gated_diff "$PWD" "$2"' _ "$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh" "$range"
    [ "$status" -eq 0 ] && [ "$output" = -1 ] || { echo "$output"; return 1; }
  done
}

@test "153 judged-branch template policy cannot select an accomplice import anchor" {
  git checkout -qb feature/accomplice main || return 1
  lines src/accomplice.js 120 || return 1
  git add src/accomplice.js && git commit -qm accomplice || return 1
  git update-ref refs/remotes/origin/feature/accomplice "$(git rev-parse HEAD)" || return 1
  git checkout -qb feature/judged main || return 1
  jq -c '.template.branch="feature/accomplice"' .trellis.json > "$SANDBOX/policy"
  cp "$SANDBOX/policy" .trellis.json
  git add .trellis.json && git commit -qm 'untrusted head-side policy' || return 1
  git merge -q --no-ff feature/accomplice -m 'Merge accomplice' || return 1
  local head
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$M0..$head" refs/heads/feature/judged "$head" || return 1
  [[ "$output" == $'block\t'*'122 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
  [[ "$output" != *'protected-imports:'* ]] || { echo "$output"; return 1; }
}

@test "153 quoted lookup keys distinguish control bytes from literal escape spellings" {
  git checkout -qb feature/quoted main || return 1
  local path head
  for path in 'src/newline\nname.js' 'src/tab\tname.js'; do
    lines "$path" 60 || return 1
  done
  git add src && git commit -qm 'literal escape spellings' || return 1
  git checkout -q main || return 1
  for path in $'src/newline\nname.js' $'src/tab\tname.js'; do
    lines "$path" 60 || return 1
  done
  git add src && git commit -qm 'protected control-byte paths' || return 1
  IMPORT_TIP=$(git rev-parse HEAD) || return 1
  git update-ref refs/remotes/origin/main "$IMPORT_TIP" || return 1
  git checkout -q feature/quoted && git merge -q --no-ff main -m 'Merge distinct path bytes' || return 1
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$M0..$head" refs/heads/feature/quoted "$head" || return 1
  [[ "$output" == $'block\t'*'120 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"protected-imports: raw=240 discounted=120 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
}

@test "153 unavailable awk retains the full raw count with a visible diagnostic" {
  git checkout -qb feature/awk-fallback main || return 1
  lines src/own.js 20 || return 1
  git add src/own.js && git commit -qm own || return 1
  sg153_main src/protected.js 120 || return 1
  local head core="$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  head=$(git rev-parse HEAD) || return 1
  sg153_verdict "$M0..$head" refs/heads/feature/awk-fallback "$head" || return 1
  [[ "$output" == $'pass\t'*'sub-floor(20<=80)'* ]] || { echo "$output"; return 1; }
  # Fault only the private runtime copy; never remove/rename system awk or
  # modify the production core to introduce a test-only dependency selector.
  python3 -I -B - "$core" "$SANDBOX/missing-awk" <<'PY'
from pathlib import Path
import shlex,sys
core=Path(sys.argv[1]);missing=Path(sys.argv[2]);assert not missing.exists()
text=core.read_text();needle='/usr/bin/env LC_ALL=C /usr/bin/awk'
assert text.count(needle)==1
core.write_text(text.replace(needle,'/usr/bin/env LC_ALL=C '+shlex.quote(str(missing))))
PY
  run --separate-stderr bash -c '. "$1"; sg_compute_gated_diff "$2" "$3"' _ \
    "$core" "$REPO_DIR" "$M0..$head" </dev/null
  [ "$status" -eq 0 ] && [ "$output" = 140 ] || { echo "$output $stderr"; return 1; }
  [[ "$stderr" == *'protected import lookup unavailable; counting full range'* ]] || { echo "$stderr"; return 1; }
  run --separate-stderr bash -c '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"' _ \
    "$core" "$M0..$head" refs/heads/feature/awk-fallback "$head" </dev/null
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [[ "$output" == $'block\t'*'140 gated lines over floor 80'* ]] || { echo "$output"; return 1; }
  [[ "$output" != *'protected-imports:'* ]] || { echo "$output"; return 1; }
  [[ "$stderr" == *'protected import lookup unavailable; counting full range'* ]] || { echo "$stderr"; return 1; }
}

@test "153 temporary directories containing equals remain filenames not awk assignments" {
  git checkout -qb feature/tmp-equals main || return 1
  lines src/own.js 20 || return 1
  git add src/own.js && git commit -qm own || return 1
  sg153_main src/protected.js 120 || return 1
  local head tmp core="$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  head=$(git rev-parse HEAD) || return 1
  for tmp in "$SANDBOX/scratch=absolute" 'scratch=relative'; do
    mkdir -m 700 -- "$tmp" || return 1
    export TMPDIR="$tmp"
    # EOF is explicit: if the relative name regresses into a var=value operand,
    # awk must not wait on the interactive runner's stdin instead of failing.
    run --separate-stderr bash -c '. "$1"; sg_compute_gated_diff "$2" "$3"' _ \
      "$core" "$REPO_DIR" "$M0..$head" </dev/null
    [ "$status" -eq 0 ] && [ "$output" = 20 ] || { echo "$output $stderr"; return 1; }
    [ -z "$stderr" ] || { echo "$stderr"; return 1; }
    run --separate-stderr bash -c '. "$1"; sg_verdict "$PWD" "$2" "$3" "$4"' _ \
      "$core" "$M0..$head" refs/heads/feature/tmp-equals "$head" </dev/null
    [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
    [[ "$output" == $'pass\t'*'sub-floor(20<=80)'* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"protected-imports: raw=140 discounted=20 anchor=$IMPORT_TIP"* ]] || { echo "$output"; return 1; }
    [ -z "$stderr" ] || { echo "$stderr"; return 1; }
    [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'trellis-spec-diff.*' -print)" ]
  done
}
