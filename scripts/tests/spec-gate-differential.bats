#!/usr/bin/env bats
# Same fixtures and consumer modes as spec-gate.bats / spec-gate-diff-base.bats.
# The reference overrides only the two functions changed by this optimization;
# it is a frozen copy of the pre-optimization config and verdict code.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  SANDBOX="$BATS_TEST_TMPDIR/spec-gate-differential"
  PROJECT="$SANDBOX/project"
  RUNTIME="$SANDBOX/runtime"
  CORE="$RUNTIME/core-rules/hooks/lib/spec-gate-core.sh"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TRELLIS_ROOT="$RUNTIME"
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset SG_OBJECT_HEAD SG_OBJECT_DIR SG_REQUEST_HEAD SG_REQUEST_REF SG_REQUEST_RANGE SG_DIFF_GATE
  mkdir -p "$HOME" "$TRELLIS_HOME" "$PROJECT" "$RUNTIME/core-rules/hooks/lib" \
    "$RUNTIME/core-rules/codex/hooks" "$RUNTIME/core-rules/skills/process-gate/scripts/lib"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  : > "$GIT_CONFIG_GLOBAL"
  cp "$REPO/core-rules/hooks/"{spec-gate.sh,lib/deps.sh,lib/deps-heavy.sh,lib/autonomy.sh} "$SANDBOX/"
  cp "$SANDBOX/spec-gate.sh" "$RUNTIME/core-rules/hooks/spec-gate.sh"
  cp "$REPO/core-rules/codex/hooks/spec-gate.sh" "$RUNTIME/core-rules/codex/hooks/spec-gate.sh"
  cp "$SANDBOX/"{deps.sh,deps-heavy.sh,autonomy.sh} "$RUNTIME/core-rules/hooks/lib/"
  cp "$REPO/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$RUNTIME/core-rules/skills/process-gate/scripts/lib/"
  cp "$REPO/core-rules/hooks/lib/spec-gate-core.sh" "$SANDBOX/candidate-core"
  cp "$SANDBOX/candidate-core" "$SANDBOX/reference-core"
  printf '\n' >> "$SANDBOX/reference-core"
  cat "$REPO/scripts/tests/helpers/spec-gate-reference.bash" >> "$SANDBOX/reference-core"
  cd "$PROJECT"
  git init -q -b main
  git config user.email fixture@example.invalid
  git config user.name fixture
  git config core.hooksPath "$SANDBOX/no-hooks"
  printf 'seed\n' > README.md
  git add README.md && git commit -qm seed
  BASE="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$BASE"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git checkout -qb feature/parity
}

reset_policies() {
  rm -f "$PROJECT/.trellis.json" "$PROJECT/.trellis.config.json" "$RUNTIME/trellis.config.json"
}

# The two invocations share the same project and runtime paths. Compare raw
# stdout, stderr and exit separately, including trailing newlines.
compare_cfg() {
  local label="$1" expected="${2:-}" mode rc
  for mode in reference candidate; do
    cp "$SANDBOX/$mode-core" "$CORE"
    if bash -c '. "$1"; sg_resolve_cfg "$2"' _ "$CORE" "$PROJECT" \
      > "$SANDBOX/$mode.out" 2> "$SANDBOX/$mode.err"; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" > "$SANDBOX/$mode.rc"
  done
  cmp -s "$SANDBOX/reference.rc" "$SANDBOX/candidate.rc" &&
    cmp -s "$SANDBOX/reference.out" "$SANDBOX/candidate.out" &&
    cmp -s "$SANDBOX/reference.err" "$SANDBOX/candidate.err" || {
      printf 'config differential mismatch: %s\n' "$label" >&2
      diff -u "$SANDBOX/reference.rc" "$SANDBOX/candidate.rc" >&2 || :
      diff -u "$SANDBOX/reference.out" "$SANDBOX/candidate.out" >&2 || :
      diff -u "$SANDBOX/reference.err" "$SANDBOX/candidate.err" >&2 || :
      return 1
    }
  if [ -n "$expected" ]; then
    [ "$(< "$SANDBOX/candidate.out")" = "$expected" ] || {
      printf '%s: expected <%s>, got <%s>\n' "$label" "$expected" "$(< "$SANDBOX/candidate.out")" >&2
      return 1
    }
  fi
}

compare_gate() {
  local label="$1"; shift
  local mode rc
  for mode in reference candidate; do
    cp "$SANDBOX/$mode-core" "$CORE"
    if (cd "$PROJECT" && bash "${SG_DIFF_GATE:-$RUNTIME/core-rules/hooks/spec-gate.sh}" "$@") \
      > "$SANDBOX/$mode.out" 2> "$SANDBOX/$mode.err"; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" > "$SANDBOX/$mode.rc"
  done
  cmp -s "$SANDBOX/reference.rc" "$SANDBOX/candidate.rc" &&
    cmp -s "$SANDBOX/reference.out" "$SANDBOX/candidate.out" &&
    cmp -s "$SANDBOX/reference.err" "$SANDBOX/candidate.err" || {
      printf 'gate differential mismatch: %s\n' "$label" >&2
      diff -u "$SANDBOX/reference.rc" "$SANDBOX/candidate.rc" >&2 || :
      diff -u "$SANDBOX/reference.out" "$SANDBOX/candidate.out" >&2 || :
      diff -u "$SANDBOX/reference.err" "$SANDBOX/candidate.err" >&2 || :
      return 1
    }
}

@test "configuration differential preserves independent precedence and defaults" {
  reset_policies
  compare_cfg absent 'false 80 400 disabled'
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":120,"surgical_max_diff_lines":480}}' > "$RUNTIME/trellis.config.json"
  compare_cfg runtime 'true 120 480 ok'
  printf '%s\n' '{"mandatory_pipeline":{"spec_required_diff_lines":90}}' > "$PROJECT/.trellis.config.json"
  printf '%s\n' '{"mandatory_pipeline":{"surgical_max_diff_lines":250}}' > "$PROJECT/.trellis.json"
  compare_cfg independent-fields 'true 90 250 ok'
  printf '%s\n' '{"mandatory_pipeline":{"enabled":false,"spec_required_diff_lines":3,"surgical_max_diff_lines":5}}' > "$PROJECT/.trellis.json"
  compare_cfg explicit-false 'false 3 5 ok'
  printf '%s\n' '{"mandatory_pipeline":{"enabled":null}}' > "$PROJECT/.trellis.json"
  compare_cfg explicit-null 'false 90 480 ok'
  printf '%s\n' '{"mandatory_pipeline":{}}' > "$PROJECT/.trellis.json"
  rm "$PROJECT/.trellis.config.json" "$RUNTIME/trellis.config.json"
  compare_cfg empty-block 'false 80 400 ok'
}

@test "configuration differential retains malformed checks and shadow boundaries" {
  local value key
  for value in '[]' 'null' 'true' '"bad"' '{broken'; do
    reset_policies; printf '%s\n' "$value" > "$PROJECT/.trellis.json"
    compare_cfg "root-$value" 'false 80 400 malformed'
  done
  for value in 'null' 'true' '[]' '"bad"'; do
    reset_policies; printf '{"mandatory_pipeline":%s}\n' "$value" > "$PROJECT/.trellis.json"
    compare_cfg "block-$value" 'false 80 400 malformed'
  done
  for value in 1 '"true"' '[]' '{}'; do
    reset_policies; printf '{"mandatory_pipeline":{"enabled":%s}}\n' "$value" > "$PROJECT/.trellis.json"
    compare_cfg "enabled-$value" 'false 80 400 malformed'
  done
  for key in spec_required_diff_lines surgical_max_diff_lines; do
    for value in 0 -1 1.5 null true '"80"'; do
      reset_policies; printf '{"mandatory_pipeline":{"enabled":true,"%s":%s}}\n' "$key" "$value" > "$PROJECT/.trellis.json"
      compare_cfg "$key-$value" 'false 80 400 malformed'
    done
  done
  reset_policies
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":81,"surgical_max_diff_lines":401}}' > "$PROJECT/.trellis.json"
  printf '{ broken\n' > "$PROJECT/.trellis.config.json"
  compare_cfg all-fields-shadow-malformed 'true 81 401 ok'
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":81}}' > "$PROJECT/.trellis.json"
  compare_cfg unresolved-ceiling-sees-malformed 'false 80 400 malformed'
}

@test "configuration differential preserves multi-document legacy behavior" {
  local first second
  for first in '{}' 'null' '{"mandatory_pipeline":{"enabled":false}}' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":2}}'; do
    for second in '{}' 'null' '{"mandatory_pipeline":{"enabled":true,"surgical_max_diff_lines":5}}'; do
      reset_policies
      printf '%s\n%s\n' "$first" "$second" > "$PROJECT/.trellis.json"
      printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}' > "$RUNTIME/trellis.config.json"
      compare_cfg "multi-$first-$second"
    done
  done
  reset_policies
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true}}' > "$PROJECT/.trellis.json"
  printf '%s\n%s\n' '{}' '{"mandatory_pipeline":{"spec_required_diff_lines":91}}' > "$PROJECT/.trellis.config.json"
  printf '%s\n' '{"mandatory_pipeline":{"surgical_max_diff_lines":401}}' > "$RUNTIME/trellis.config.json"
  compare_cfg multi-lower-priority
  reset_policies
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":81,"surgical_max_diff_lines":401}}' > "$PROJECT/.trellis.json"
  printf '%s\n%s\n' '{}' 'null' > "$PROJECT/.trellis.config.json"
  compare_cfg multi-shadowed 'true 81 401 ok'
}

@test "differential preserves diagnostics on unreadable and NUL-containing policy" {
  reset_policies
  printf '%s\n%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}' > "$PROJECT/.trellis.json"
  printf '{}\n' > "$PROJECT/.trellis.config.json"
  chmod 000 "$PROJECT/.trellis.config.json"
  if [ -r "$PROJECT/.trellis.config.json" ]; then
    chmod 600 "$PROJECT/.trellis.config.json"
    skip 'requires a user that cannot read mode-000 files'
  fi
  compare_cfg unreadable-shadowed-by-multi
  printf '%s\n%s\n' '{}' '{}' > "$PROJECT/.trellis.json"
  compare_cfg unreadable-after-multi
  chmod 600 "$PROJECT/.trellis.config.json"
  reset_policies
  printf '{}\n' > "$PROJECT/.trellis.json"
  chmod 000 "$PROJECT/.trellis.json"
  compare_cfg unreadable-first-source
  chmod 600 "$PROJECT/.trellis.json"
  reset_policies
  printf '{"mandatory_pipeline":{"enabled":true}}\000\n' > "$PROJECT/.trellis.json"
  printf '%s\n' '{"mandatory_pipeline":{"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}' > "$RUNTIME/trellis.config.json"
  compare_cfg nul-warning-when-reading-multiple-fields
}

@test "gate differential preserves bytes and exit for committed policy and edge verdicts" {
  local head i
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":5,"surgical_max_diff_lines":400}}' > "$PROJECT/.trellis.json"
  mkdir -p "$PROJECT/src"
  for ((i=1; i<=10; i++)); do printf 'line %s\n' "$i"; done > "$PROJECT/src/change.txt"
  git add .trellis.json src/change.txt && git commit -qm 'fixture change'
  head="$(git rev-parse HEAD)"
  compare_gate over-floor --gate --ref refs/heads/feature/parity --head "$head" --range "$BASE..$head"
  [ "$(< "$SANDBOX/candidate.rc")" = 1 ]
  grep -q '11 gated lines over floor 5' "$SANDBOX/candidate.err"
  # The explicit request reads the committed JSON, not this malformed edit.
  printf '{ broken\n' > "$PROJECT/.trellis.json"
  compare_gate committed-not-worktree --gate --ref refs/heads/feature/parity --head "$head" --range "$BASE..$head"
  [ "$(< "$SANDBOX/candidate.rc")" = 1 ]
  grep -q '11 gated lines over floor 5' "$SANDBOX/candidate.err"
  # With no pinned head the malformed worktree policy is authoritative.
  compare_gate malformed-worktree --gate --range "$BASE..$head"
  [ "$(< "$SANDBOX/candidate.rc")" = 1 ]
  grep -q 'mandatory_pipeline config present but malformed' "$SANDBOX/candidate.err"
  compare_gate invalid-ref --gate --ref 'refs/heads/bad..name' --head "$head" --range "$BASE..$head"
  [ "$(< "$SANDBOX/candidate.rc")" = 1 ]
  grep -q 'invalid-ref' "$SANDBOX/candidate.err"
}

@test "gate differential preserves triad, interview, disabled and protected verdicts in both twins" {
  local gate i f head body
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":5,"surgical_max_diff_lines":400}}' > "$PROJECT/.trellis.json"
  mkdir -p "$PROJECT/src" "$PROJECT/specs/001-fixture"
  for ((i=1; i<=10; i++)); do printf 'line %s\n' "$i"; done > "$PROJECT/src/change.txt"
  body='A concrete specification records the requirements, decisions, implementation plan and verification for this branch. These contents are intentionally longer than the template threshold and contain no placeholder markers or unfilled tokens.'
  for f in spec plan tasks; do printf '# %s\n%s\n' "$f" "$body" > "$PROJECT/specs/001-fixture/$f.md"; done
  git add .trellis.json src specs && git commit -qm 'fixture triad'
  head="$(git rev-parse HEAD)"
  for gate in "$RUNTIME/core-rules/hooks/spec-gate.sh" "$RUNTIME/core-rules/codex/hooks/spec-gate.sh"; do
    SG_DIFF_GATE="$gate"
    compare_gate missing-interview --gate --ref refs/heads/feature/parity --head "$head" --range "$BASE..$head"
    [ "$(< "$SANDBOX/candidate.rc")" = 1 ]
    grep -q 'interview artifact is missing' "$SANDBOX/candidate.err"
  done
  printf 'answered\n' > "$PROJECT/specs/001-fixture/clarify.md"
  git add specs/001-fixture/clarify.md && git commit -qm 'fixture interview'
  head="$(git rev-parse HEAD)"
  for gate in "$RUNTIME/core-rules/hooks/spec-gate.sh" "$RUNTIME/core-rules/codex/hooks/spec-gate.sh"; do
    SG_DIFF_GATE="$gate"
    compare_gate triad-pass --gate --ref refs/heads/feature/parity --head "$head" --range "$BASE..$head"
    [ "$(< "$SANDBOX/candidate.rc")" = 0 ]
  done
  printf '%s\n' '{"mandatory_pipeline":{"enabled":false}}' > "$PROJECT/.trellis.json"
  compare_gate disabled --gate
  [ "$(< "$SANDBOX/candidate.rc")" = 0 ]
  git checkout -q -- .trellis.json
  git checkout -q main
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true}}' > "$PROJECT/.trellis.json"
  compare_gate protected --gate
  [ "$(< "$SANDBOX/candidate.rc")" = 0 ]
}

@test "configuration differential keeps missing jq distinct from disabled" {
  local bin="$SANDBOX/no-jq" shell mode rc
  mkdir "$bin"
  ln -s "$(command -v dirname)" "$bin/dirname"
  shell="$(command -v bash)"
  for mode in reference candidate; do
    cp "$SANDBOX/$mode-core" "$CORE"
    if env PATH="$bin" "$shell" -c '. "$1"; sg_resolve_cfg "$2"' _ "$CORE" "$PROJECT" \
      > "$SANDBOX/$mode.out" 2> "$SANDBOX/$mode.err"; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" > "$SANDBOX/$mode.rc"
  done
  cmp -s "$SANDBOX/reference.rc" "$SANDBOX/candidate.rc"
  cmp -s "$SANDBOX/reference.out" "$SANDBOX/candidate.out"
  cmp -s "$SANDBOX/reference.err" "$SANDBOX/candidate.err"
  [ "$(< "$SANDBOX/candidate.out")" = 'false 80 400 nojq' ]
}

@test "public diff resolver ignores extra arguments instead of trusting a supplied root" {
  local fake="$SANDBOX/fake" head plain_rc extra_rc
  mkdir -p "$fake/.claude/skills/process-gate/scripts/lib"
  cp "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$fake/.claude/skills/process-gate/scripts/lib/"
  rm "$RUNTIME/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
  printf 'change\n' > "$PROJECT/change.txt"
  git add change.txt && git commit -qm change
  head="$(git rev-parse HEAD)"
  cp "$SANDBOX/candidate-core" "$CORE"
  if bash -c '. "$1"; sg_resolve_diff "$2" "$3" "$4" "$5"' _ "$CORE" "$PROJECT" "$BASE..$head" refs/heads/feature/parity "$head" > "$SANDBOX/plain.out" 2> "$SANDBOX/plain.err"; then plain_rc=0; else plain_rc=$?; fi
  if bash -c '. "$1"; sg_resolve_diff "$2" "$3" "$4" "$5" "$6"' _ "$CORE" "$PROJECT" "$BASE..$head" refs/heads/feature/parity "$head" "$fake" > "$SANDBOX/extra.out" 2> "$SANDBOX/extra.err"; then extra_rc=0; else extra_rc=$?; fi
  # a5b364825: a resolver missing from the trusted runtime refuses with 4.
  [ "$plain_rc" -eq 4 ]
  [ "$extra_rc" -eq "$plain_rc" ]
  cmp -s "$SANDBOX/plain.out" "$SANDBOX/extra.out"
  cmp -s "$SANDBOX/plain.err" "$SANDBOX/extra.err"
}

@test "full gate reuses the resolved common root for its diff resolver" {
  local bin="$SANDBOX/git-count" realgit head count
  mkdir "$bin"
  realgit="$(command -v git)"
  cat > "$bin/git" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SG_GIT_LOG"
exec "$SG_REAL_GIT" "$@"
SH
  chmod 755 "$bin/git"
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true}}' > "$RUNTIME/trellis.config.json"
  printf 'change\n' > "$PROJECT/change.txt"
  git add change.txt && git commit -qm change
  head="$(git rev-parse HEAD)"
  cp "$SANDBOX/candidate-core" "$CORE"
  export SG_REAL_GIT="$realgit" SG_GIT_LOG="$SANDBOX/full-git.log"
  PATH="$bin:$PATH" bash "$RUNTIME/core-rules/hooks/spec-gate.sh" --gate \
    --ref refs/heads/feature/parity --head "$head" --range "$BASE..$head" > "$SANDBOX/full.out"
  count="$(grep -Fxc -- "-C $PROJECT rev-parse --git-common-dir" "$SG_GIT_LOG")"
  [ "$count" -eq 2 ] || { printf 'common-root reads: %s (expected 2)\n' "$count" >&2; return 1; }
}

@test "multi-document legacy fallback reuses the same policy snapshots" {
  local mode
  printf '%s\n%s\n' '{}' '{}' > "$PROJECT/.trellis.json"
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true,"spec_required_diff_lines":80,"surgical_max_diff_lines":400}}' > "$RUNTIME/trellis.config.json"
  compare_cfg multi-fallback 'true 80 400 ok'
  cp "$SANDBOX/candidate-core" "$CORE"
  export SG_READ_LOG="$SANDBOX/multi-read.log"
  bash -c '
    . "$1"
    original="$(declare -f sg_policy_json)"
    eval "${original/sg_policy_json/sg_policy_json_original}"
    sg_policy_json() { printf "%s\n" "$1" >> "$SG_READ_LOG"; sg_policy_json_original "$@"; }
    sg_resolve_cfg "$2"
  ' _ "$CORE" "$PROJECT" > "$SANDBOX/multi-count.out"
  [ "$(< "$SANDBOX/multi-count.out")" = 'true 80 400 ok' ]
  for mode in "$PROJECT/.trellis.json" "$PROJECT/.trellis.config.json" "$RUNTIME/trellis.config.json"; do
    [ "$(grep -Fxc "$mode" "$SG_READ_LOG")" -eq 1 ]
  done
}

@test "settings sources and committed policy blobs are read only once per resolution" {
  local bin="$SANDBOX/count-bin" realjq realgit head
  mkdir "$bin"
  realjq="$(command -v jq)"; realgit="$(command -v git)"
  cat > "$bin/jq" <<'SH'
#!/bin/sh
printf 'jq\n' >> "$SG_JQ_LOG"
exec "$SG_REAL_JQ" "$@"
SH
  cat > "$bin/git" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SG_GIT_LOG"
exec "$SG_REAL_GIT" "$@"
SH
  chmod 755 "$bin/jq" "$bin/git"
  printf '%s\n' '{"mandatory_pipeline":{"enabled":true}}' > "$PROJECT/.trellis.json"
  printf '%s\n' '{"mandatory_pipeline":{"spec_required_diff_lines":90}}' > "$PROJECT/.trellis.config.json"
  printf '%s\n' '{"mandatory_pipeline":{"surgical_max_diff_lines":250}}' > "$RUNTIME/trellis.config.json"
  git add .trellis.json .trellis.config.json && git commit -qm policy
  head="$(git rev-parse HEAD)"
  cp "$SANDBOX/candidate-core" "$CORE"
  export SG_REAL_JQ="$realjq" SG_REAL_GIT="$realgit" SG_JQ_LOG="$SANDBOX/jq.log" SG_GIT_LOG="$SANDBOX/git.log" SG_READ_LOG="$SANDBOX/read.log"
  PATH="$bin:$PATH" bash -c '
    . "$1"
    original="$(declare -f sg_policy_json)"
    eval "${original/sg_policy_json/sg_policy_json_original}"
    sg_policy_json() { printf "%s\n" "$1" >> "$SG_READ_LOG"; sg_policy_json_original "$@"; }
    SG_OBJECT_DIR="$2" SG_OBJECT_HEAD="$3"
    sg_resolve_cfg "$2"
  ' _ "$CORE" "$PROJECT" "$head" > "$SANDBOX/count.out"
  [ "$(< "$SANDBOX/count.out")" = 'true 90 250 ok' ]
  [ "$(grep -Fxc "$PROJECT/.trellis.json" "$SG_READ_LOG")" -eq 1 ]
  [ "$(grep -Fxc "$PROJECT/.trellis.config.json" "$SG_READ_LOG")" -eq 1 ]
  [ "$(grep -Fxc "$RUNTIME/trellis.config.json" "$SG_READ_LOG")" -eq 1 ]
  [ "$(grep -c '^jq$' "$SG_JQ_LOG")" -le 3 ]
  [ "$(grep -c ' ls-tree .* -- .trellis.json$' "$SG_GIT_LOG")" -eq 1 ]
  [ "$(grep -c ' ls-tree .* -- .trellis.config.json$' "$SG_GIT_LOG")" -eq 1 ]
}
