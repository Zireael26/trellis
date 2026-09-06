#!/usr/bin/env bats
# Tests for the mandatory-pipeline gate (spec 006) — spec-gate-core.sh + the
# spec-gate.sh --gate CLI (the LOAD-BEARING pre-push teeth).
#
# THE PARITY GUARANTEE under test: the verdict is a pure function of git +
# filesystem state (branch diff size, which paths changed, whether a spec triad
# was added in THIS branch's range, whether a bound surgical marker exists). Zero
# model classification. That is what makes enforcement equal on Claude + Codex.
#
# Isolation: every test stands up its own throwaway git repo under `mktemp`. The
# CANONICAL scripts under core-rules/ are exercised in place (spec-gate.sh sources
# its lib relative to its own location), so we test the real gate, not a copy. The
# fixture supplies only git state + trellis.config.json; the gate operates on $PWD.
#
# bash 3.2 / bats 1.x compatible.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
GATE="$REPO/core-rules/hooks/spec-gate.sh"
CODEX_GATE="$REPO/core-rules/codex/hooks/spec-gate.sh"
CORE="$REPO/core-rules/hooks/lib/spec-gate-core.sh"
NATIVE_PREPUSH="$REPO/core-rules/githooks/pre-push"

setup() {
  SANDBOX="$(mktemp -d)"
  REPO_DIR="$SANDBOX/repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  unset TRELLIS_ROOT
  # base commit on main so a feature branch has a merge-base
  echo "seed" > README.md
  git add -A && git commit -qm "init" >/dev/null
  TRELLIS_FIXTURE="$SANDBOX/trellis"
  mkdir -p "$TRELLIS_FIXTURE/core-rules/presets"
}

teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# --- helpers ----------------------------------------------------------------

# _config <enabled> [floor] [ceiling] — write immutable runtime policy for an
# attached fixture. Project-root trellis.config.json is deliberately not policy.
_config() {
  local enabled="$1" floor="${2:-80}" ceiling="${3:-400}"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  cat > "$TRELLIS_FIXTURE/trellis.config.json" <<JSON
{ "template": { "branch": "main" },
  "mandatory_pipeline": { "enabled": $enabled, "spec_required_diff_lines": $floor, "surgical_max_diff_lines": $ceiling } }
JSON
}

# _write_lines <file> <n> — n distinct source lines (deterministic content).
_write_lines() {
  local file="$1" n="$2" i
  mkdir -p "$(dirname "$REPO_DIR/$file")"
  : > "$REPO_DIR/$file"
  for i in $(seq 1 "$n"); do
    echo "const line_${i} = ${i};" >> "$REPO_DIR/$file"
  done
}

# _real_triad <dir> [with_clarify] — a non-template spec triad (>=200 bytes each,
# no placeholder tokens) under specs/<dir>/. Optionally a clarify.md.
_real_triad() {
  local d="$1" clarify="${2:-}"
  mkdir -p "$REPO_DIR/specs/$d"
  local body="This is a real, filled-in artifact with enough prose to clear the non-template minimum byte floor. It describes concrete problem, users, and acceptance criteria without any unfilled scaffold tokens whatsoever. Lorem ipsum padding to be safe and well over two hundred bytes total length here."
  printf '# spec\n%s\n' "$body" > "$REPO_DIR/specs/$d/spec.md"
  printf '# plan\n%s\n' "$body" > "$REPO_DIR/specs/$d/plan.md"
  printf '# tasks\n%s\n' "$body" > "$REPO_DIR/specs/$d/tasks.md"
  if [ -n "$clarify" ]; then
    printf '# clarify\n%s\n' "$body" > "$REPO_DIR/specs/$d/clarify.md"
  fi
  return 0
}

# run the pre-push gate CLI from inside the fixture repo.
_gate() {
  ( cd "$REPO_DIR" && bash "$GATE" --gate )
}

_deploy_native_spec_gate() {
  mkdir -p "$REPO_DIR/.claude/hooks/lib"
  cp "$GATE" "$REPO_DIR/.claude/hooks/spec-gate.sh"
  cp "$CORE" "$REPO_DIR/.claude/hooks/lib/spec-gate-core.sh"
  cp "$REPO/core-rules/hooks/lib/deps.sh" "$REPO_DIR/.claude/hooks/lib/deps.sh"
  cp "$REPO/core-rules/hooks/lib/autonomy.sh" "$REPO_DIR/.claude/hooks/lib/autonomy.sh"
}

_native_prepush() {
  ( cd "$REPO_DIR" && printf '' | sh "$NATIVE_PREPUSH" )
}

_resolved_cfg() {
  ( . "$CORE" && sg_resolve_cfg "$REPO_DIR" )
}

_autonomy_level() {
  ( . "$CORE" && sg_autonomy_level "$REPO_DIR" )
}

_protected_branch() {
  ( . "$CORE" && sg_protected_branch "$REPO_DIR" )
}

_verdict_with_git_diff_failure() {
  local failing_mode="$1"
  (
    git() {
      if [ "${3:-}" = "diff" ] && [ "${4:-}" = "$failing_mode" ]; then
        return 70
      fi
      command git "$@"
    }
    . "$CORE"
    sg_verdict "$REPO_DIR"
  )
}

_verdict_with_triad_grep_failure() {
  (
    grep() {
      if [ "${1:-}" = "-E" ] \
        && [ "${2:-}" = '^specs/[0-9][^/]*/(spec|plan|tasks)\.md$' ]; then
        return 2
      fi
      command grep "$@"
    }
    . "$CORE"
    sg_verdict "$REPO_DIR"
  )
}

_write_fleet_autonomy() {
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  if [ -f "$TRELLIS_FIXTURE/trellis.config.json" ]; then
    jq --argjson level "$1" '. + {autonomy_default: $level}' \
      "$TRELLIS_FIXTURE/trellis.config.json" > "$TRELLIS_FIXTURE/trellis.config.json.tmp"
    mv "$TRELLIS_FIXTURE/trellis.config.json.tmp" "$TRELLIS_FIXTURE/trellis.config.json"
  else
    printf '{"autonomy_default":%s}\n' "$1" > "$TRELLIS_FIXTURE/trellis.config.json"
  fi
}

_write_project_autonomy() {
  local autonomy_json="$1" presets_json="${2:-[]}"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  jq -n \
    --argjson autonomy "$autonomy_json" \
    --argjson presets "$presets_json" \
    '{presets: $presets}
     + (if $autonomy == null then {} else {autonomy: $autonomy} end)' \
    > "$REPO_DIR/.trellis.json"
}

# --- default-off invariant (SC5) --------------------------------------------

@test "knob absent -> pass (default off, byte-identical to prior behavior)" {
  _write_lines src/f.js 200
  git checkout -q -b feat/x
  git add -A && git commit -qm "feat: big" >/dev/null
  # no trellis.config.json at all
  run _gate
  [ "$status" -eq 0 ]
}

@test "knob enabled:false -> pass" {
  _config false
  _write_lines src/f.js 200
  git checkout -q -b feat/x
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}


# --- portable policy source precedence --------------------------------------

@test "canonical, legacy, and immutable runtime resolve mandatory fields independently" {
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  cat > "$TRELLIS_FIXTURE/trellis.config.json" <<'JSON'
{ "template": { "branch": "runtime" },
  "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 120, "surgical_max_diff_lines": 480 } }
JSON
  cat > "$REPO_DIR/.trellis.config.json" <<'JSON'
{ "template": { "branch": "legacy" },
  "mandatory_pipeline": { "spec_required_diff_lines": 90 } }
JSON
  cat > "$REPO_DIR/.trellis.json" <<'JSON'
{ "template": { "branch": "canonical" },
  "mandatory_pipeline": { "surgical_max_diff_lines": 250 } }
JSON

  run _resolved_cfg
  [ "$status" -eq 0 ]
  [ "$output" = "true 90 250 ok" ]
}
@test "unattached project-root config is ignored as mutable source policy" {
  cat > "$REPO_DIR/trellis.config.json" <<'JSON'
{ "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 91, "surgical_max_diff_lines": 401 } }
JSON
  unset TRELLIS_ROOT

  run _resolved_cfg
  [ "$status" -eq 0 ]
  [ "$output" = "false 80 400 disabled" ]
}

@test "attached native pre-push derives and enforces immutable runtime policy" {
  _config true 80 400
  mkdir -p "$REPO_DIR/.trellis"
  ln -s "$TRELLIS_FIXTURE" "$REPO_DIR/.trellis/runtime"
  _deploy_native_spec_gate
  _write_lines src/f.js 200
  git checkout -q -b feat/native-runtime
  git add -A && git commit -qm "feat: runtime policy" >/dev/null
  unset TRELLIS_ROOT

  run _native_prepush
  [ "$status" -eq 1 ]
  [[ "$output" == *"spec-gate blocked"* ]] || { echo "$output"; false; }
}

@test "broken attached native runtime fails closed before spec-gate dispatch" {
  mkdir -p "$REPO_DIR/.trellis"
  ln -s "$SANDBOX/missing-runtime" "$REPO_DIR/.trellis/runtime"
  unset TRELLIS_ROOT

  run _native_prepush
  [ "$status" -eq 1 ]
  [[ "$output" == *"attached Trellis runtime is corrupt"* ]] || { echo "$output"; false; }
}

@test "invalid canonical protected branch claims do not fall through" {
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  printf '{ "template": { "branch": "runtime" } }\n' > "$TRELLIS_FIXTURE/trellis.config.json"
  printf '{ "template": { "branch": "bypass" } }\n' > "$REPO_DIR/.trellis.config.json"

  local value
  for value in null '""' 7; do
    printf '{ "template": { "branch": %s } }\n' "$value" > "$REPO_DIR/.trellis.json"
    run _protected_branch
    [ "$status" -eq 0 ]
    [ "$output" = main ]
  done

  printf '{}\n' > "$REPO_DIR/.trellis.json"
  run _protected_branch
  [ "$status" -eq 0 ]
  [ "$output" = bypass ]
}

# --- core verdict matrix (knob on) ------------------------------------------

@test "on the protected branch -> pass (never gates main)" {
  _config true
  _write_lines src/f.js 200
  git add -A && git commit -qm "chore: on main" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "sub-floor diff -> pass (surgical-default)" {
  _config true 80 400
  _write_lines src/f.js 20
  git checkout -q -b feat/small
  git add -A && git commit -qm "fix: tiny" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "over-floor + no spec + no marker -> BLOCK with remedy" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/big
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Surgical"* ]] || { echo "$output"; false; }
}

@test "excluded paths do not count toward the gated diff" {
  _config true 80 400
  # 500 lines but entirely under tests/ + docs/ + specs/ -> gated diff ~0
  _write_lines src/big_test.test.js 200
  _write_lines docs/notes.md 200
  _write_lines specs/999-x/spec.md 200
  git checkout -q -b feat/excluded
  git add -A && git commit -qm "docs+tests only" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "root-level AGENT_*.md guides do not count toward the gated diff" {
  _config true 80 400
  # Paste-into-agent guides live at the root, not under docs/, because the public
  # mirror surfaces them there. They are prose, not feature code.
  _write_lines AGENT_SETUP.md 300
  _write_lines AGENT_PI_SETUP.md 500
  git checkout -q -b docs/agent-guides
  git add -A && git commit -qm "docs: agent guides" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "AGENT_ prefixed source files still count toward the gated diff" {
  _config true 80 400
  # The exemption is for .md guides only; it must not launder code.
  _write_lines AGENT_runner.py 200
  git checkout -q -b feat/agent-runner
  git add -A && git commit -qm "feat: runner" >/dev/null
  run _gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]] || { echo "$output"; false; }
}

@test "supported test basenames do not count toward the gated diff" {
  _config true 80 400
  _write_lines src/legacy_test.js 100
  _write_lines src/current.test.ts 100
  _write_lines src/current.spec.ts 100
  _write_lines scripts/current.bats 100
  _write_lines Tests/InventoryTests.swift 100
  _write_lines tests/test_inventory.py 100
  _write_lines test/InventoryTest.kt 100
  git checkout -q -b feat/test-basenames
  git add -A && git commit -qm "test: supported conventions" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "test-like directories do not exclude production source files" {
  _config true 80 400
  local fixture n=1
  for fixture in \
    "legacy_test.js/production.js" \
    "current.test.ts/production.ts" \
    "current.spec.ts/production.ts" \
    "InventoryTests.swift/Inventory.swift" \
    "test_fixture.py/production.py" \
    "InventoryTest.kt/Inventory.kt"
  do
    git checkout -q -b "feat/near-miss-$n"
    _write_lines "$fixture" 100
    git add -A && git commit -qm "feat: production near miss $n" >/dev/null
    run _gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"over floor"* ]]
    git checkout -q main
    n=$(( n + 1 ))
  done
}

@test "over-floor + in-range triad + clarify.md (L3) -> pass" {
  _config true 80 400
  _write_lines src/f.js 200
  _real_triad 001-feature with_clarify
  git checkout -q -b feat/spec
  git add -A && git commit -qm "feat: big + spec" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "over-floor + in-range triad but NO interview artifact -> BLOCK" {
  _config true 80 400
  _write_lines src/f.js 200
  _real_triad 001-feature      # no clarify.md, no spec-waiver
  git checkout -q -b feat/spec-nointerview
  git add -A && git commit -qm "feat: big + spec, no clarify" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"interview artifact"* ]] || { echo "$output"; false; }
}

@test "C-CRIT-1: triad exists on main but NOT in branch range -> BLOCK" {
  _config true 80 400
  # triad committed on main BEFORE branching -> not in main...HEAD
  _real_triad 001-old with_clarify
  git add -A && git commit -qm "chore: historical spec" >/dev/null
  git checkout -q -b feat/unrelated
  _write_lines src/f.js 200
  git add -A && git commit -qm "feat: big, reuses old spec dir" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

@test "C-CRIT-2: in-range triad that is still a TEMPLATE -> BLOCK" {
  _config true 80 400
  _write_lines src/f.js 200
  mkdir -p "$REPO_DIR/specs/001-tmpl"
  # placeholder tokens + under the byte floor -> non-template check fails
  printf '# spec <NNN>-<slug>\nTODO-SPEC\n' > "$REPO_DIR/specs/001-tmpl/spec.md"
  printf 'TODO-SPEC\n' > "$REPO_DIR/specs/001-tmpl/plan.md"
  printf 'TODO-SPEC\n' > "$REPO_DIR/specs/001-tmpl/tasks.md"
  git checkout -q -b feat/tmpl
  git add -A && git commit -qm "feat: big + template spec" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

# --- surgical / emergency markers -------------------------------------------

@test "surgical marker under ceiling -> pass" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/surgical
  git add -A && git commit -qm "refactor: mechanical" >/dev/null
  ( cd "$REPO_DIR" && bash "$GATE" --mark "mechanical rename, no behavior change" >/dev/null )
  run _gate
  [ "$status" -eq 0 ]
}

@test "surgical marker but diff grows over ceiling -> BLOCK + oversized-surgical audit" {
  _config true 80 120     # low ceiling to force over-ceiling
  _write_lines src/f.js 200
  git checkout -q -b feat/oversized
  git add -A && git commit -qm "refactor: too big" >/dev/null
  ( cd "$REPO_DIR" && bash "$GATE" --mark "claiming small" >/dev/null )
  run _gate
  [ "$status" -eq 1 ]
  grep -q "oversized-surgical" "$REPO_DIR/.claude/spec-gate-audit.log"
}

@test "emergency marker over ceiling -> pass + emergency-override audit" {
  _config true 80 120
  _write_lines src/f.js 200
  git checkout -q -b feat/emergency
  git add -A && git commit -qm "hotfix: urgent" >/dev/null
  ( cd "$REPO_DIR" && bash "$GATE" --mark-emergency "prod down, spec to follow" >/dev/null )
  run _gate
  [ "$status" -eq 0 ]
  grep -q "emergency-override" "$REPO_DIR/.claude/spec-gate-audit.log"
}

@test "emergency marker with an unwritable audit target does not silently pass" {
  _config true 80 120
  _write_lines src/f.js 200
  git checkout -q -b feat/emergency-unloggable
  git add -A && git commit -qm "hotfix: urgent but unloggable" >/dev/null
  ( cd "$REPO_DIR" && bash "$GATE" --mark-emergency "audit required" >/dev/null )
  mkdir "$REPO_DIR/.claude/spec-gate-audit.log"

  run _gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED"* ]] || { echo "$output"; false; }
}

@test "surgical marker is branch-bound: ignored on a different branch" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/one
  git add -A && git commit -qm "feat: big" >/dev/null
  ( cd "$REPO_DIR" && bash "$GATE" --mark "declared for feat/one" >/dev/null )
  # switch to a second over-floor branch — marker must NOT carry over
  git checkout -q main
  git checkout -q -b feat/two
  _write_lines src/g.js 200
  git add -A && git commit -qm "feat: big two" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

# --- L4/L5 interview path ----------------------------------------------------

@test "autonomy resolver preserves every fleet default from L1 through L5" {
  _write_project_autonomy null '[]'
  local level
  for level in 1 2 3 4 5; do
    _write_fleet_autonomy "$level"
    run _autonomy_level
    [ "$status" -eq 0 ]
    [ "$output" = "$level" ]
  done
}

@test "autonomy resolver uses active preset default when project override is absent" {
  _write_fleet_autonomy 2
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 4
---
EOF
  _write_project_autonomy null '["experimental"]'

  run _autonomy_level
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "autonomy resolver project override beats fleet and preset defaults" {
  _write_fleet_autonomy 1
  cat > "$TRELLIS_FIXTURE/core-rules/presets/experimental.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 5
---
EOF
  _write_project_autonomy 4 '["experimental"]'

  run _autonomy_level
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "autonomy resolver session override is clamped to lowest active preset ceiling" {
  _write_fleet_autonomy 3
  cat > "$TRELLIS_FIXTURE/core-rules/presets/loose.md" <<'EOF'
---
autonomy_ceiling: 5
autonomy_default: 4
---
EOF
  cat > "$TRELLIS_FIXTURE/core-rules/presets/strict.md" <<'EOF'
---
autonomy_ceiling: 2
---
EOF
  _write_project_autonomy 1 '["loose","strict"]'
  mkdir -p "$REPO_DIR/.claude"
  printf '5\n' > "$REPO_DIR/.claude/session-autonomy"

  run _autonomy_level
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "project L4 selects the decisions-log interview path" {
  _config true 80 400
  _write_fleet_autonomy 2
  _write_project_autonomy 4 '[]'
  _write_lines src/f.js 200
  _real_triad 001-feature
  git checkout -q -b feat/project-l4
  printf '# decisions\n- feat/project-l4: self-answered intake\n' > "$REPO_DIR/decisions-log.md"
  git add -A && git commit -qm "feat: project L4 spec" >/dev/null

  run _gate
  [ "$status" -eq 0 ]
}


@test "canonical autonomy selects the decisions-log interview path over legacy and runtime" {
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  cat > "$TRELLIS_FIXTURE/trellis.config.json" <<'JSON'
{ "autonomy_default": 2,
  "mandatory_pipeline": { "enabled": true } }
JSON
  printf '{ "autonomy": 1 }\n' > "$REPO_DIR/.trellis.config.json"
  printf '{ "autonomy": 4 }\n' > "$REPO_DIR/.trellis.json"
  _write_lines src/f.js 200
  _real_triad 001-feature
  git checkout -q -b feat/canonical-l4
  printf '# decisions\n- feat/canonical-l4: self-answered intake\n' > "$REPO_DIR/decisions-log.md"
  git add -A && git commit -qm "feat: canonical L4 spec" >/dev/null

  run _autonomy_level
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
  run _gate
  [ "$status" -eq 0 ]
}
@test "preset ceiling clamps L5 session to L2 interview path" {
  _config true 80 400
  _write_fleet_autonomy 3
  cat > "$TRELLIS_FIXTURE/core-rules/presets/strict.md" <<'EOF'
---
autonomy_ceiling: 2
---
EOF
  _write_project_autonomy null '["strict"]'
  mkdir -p "$REPO_DIR/.claude"
  printf '5\n' > "$REPO_DIR/.claude/session-autonomy"
  _write_lines src/f.js 200
  _real_triad 001-feature with_clarify
  git checkout -q -b feat/clamped-l2
  git add -A && git commit -qm "feat: clamped interview path" >/dev/null

  run _gate
  [ "$status" -eq 0 ]
}

@test "L5 + in-range triad + decisions-log entry (no clarify.md) -> pass" {
  _config true 80 400
  printf '5\n' > "$REPO_DIR/.claude/session-autonomy" 2>/dev/null || { mkdir -p "$REPO_DIR/.claude"; printf '5\n' > "$REPO_DIR/.claude/session-autonomy"; }
  _write_lines src/f.js 200
  _real_triad 001-feature      # deliberately NO clarify.md
  git checkout -q -b feat/l5
  printf '# decisions\n- feat/l5: chose X over Y because Z\n' > "$REPO_DIR/decisions-log.md"
  git add -A && git commit -qm "feat: big + spec (L5 self-answered)" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "L5 + in-range triad but NO decisions-log entry -> BLOCK" {
  _config true 80 400
  mkdir -p "$REPO_DIR/.claude"; printf '5\n' > "$REPO_DIR/.claude/session-autonomy"
  _write_lines src/f.js 200
  _real_triad 001-feature with_clarify   # clarify.md present, but at L5 that is not the artifact
  git checkout -q -b feat/l5-missing
  git add -A && git commit -qm "feat: big + spec, no decisions log" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}


@test "malformed canonical policy blocks before legacy and runtime fallback" {
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  cat > "$TRELLIS_FIXTURE/trellis.config.json" <<'JSON'
{ "mandatory_pipeline": { "enabled": true } }
JSON
  printf '{ "mandatory_pipeline": { "enabled": false } }\n' > "$REPO_DIR/.trellis.config.json"
  printf '{ "mandatory_pipeline": { "enabled": "true" } }\n' > "$REPO_DIR/.trellis.json"

  run _resolved_cfg
  [ "$status" -eq 0 ]
  [ "$output" = "false 80 400 malformed" ]
}

@test "malformed immutable runtime policy blocks when project policy is absent" {
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  printf '{ this is not json ' > "$TRELLIS_FIXTURE/trellis.config.json"

  run _resolved_cfg
  [ "$status" -eq 0 ]
  [ "$output" = "false 80 400 malformed" ]
}
# --- config failure semantics (C-6a) ----------------------------------------

@test "malformed: mandatory_pipeline not an object -> BLOCK (fail-closed)" {
  cat > "$REPO_DIR/.trellis.json" <<'JSON'
{ "template": { "branch": "main" }, "mandatory_pipeline": true }
JSON
  _write_lines src/f.js 200
  git checkout -q -b feat/malformed
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

@test "malformed: unparseable JSON -> BLOCK (fail-closed)" {
  printf '{ this is not json ' > "$REPO_DIR/.trellis.json"
  _write_lines src/f.js 200
  git checkout -q -b feat/badjson
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

@test "missing optional thresholds use the documented defaults" {
  cat > "$REPO_DIR/.trellis.json" <<'JSON'
{ "template": { "branch": "main" }, "mandatory_pipeline": { "enabled": true } }
JSON

  run _resolved_cfg
  [ "$status" -eq 0 ]
  [ "$output" = "true 80 400 ok" ]
}

@test "malformed: present thresholds must be positive JSON integers" {
  local key value
  for key in spec_required_diff_lines surgical_max_diff_lines; do
    for value in '"80"' -1 0 1.5 null true; do
      printf '{ "template": { "branch": "main" }, "mandatory_pipeline": { "enabled": true, "%s": %s } }\n' \
        "$key" "$value" > "$REPO_DIR/.trellis.json"

      run _gate
      [ "$status" -eq 1 ]
      [[ "$output" == *"malformed"* ]] || { echo "$output"; false; }
    done
  done
}

@test "schema requires positive mandatory-pipeline thresholds" {
  run node - "$REPO/scripts/lib/trellis.config.schema.json" <<'NODE'
const fs = require('node:fs')
const schema = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const mandatory = schema.properties?.mandatory_pipeline?.properties
for (const key of ['spec_required_diff_lines', 'surgical_max_diff_lines']) {
  if (mandatory?.[key]?.type !== 'integer' || mandatory[key].minimum !== 1) process.exit(1)
}
NODE
  [ "$status" -eq 0 ]
}

# --- fail-open on a broken environment --------------------------------------

@test "failed numstat diff is advisory rather than a zero-line pass" {
  _config true 80 400
  _write_lines src/f.js 20
  git checkout -q -b feat/numstat-failure
  git add -A && git commit -qm "fix: tiny" >/dev/null

  run _verdict_with_git_diff_failure --numstat
  [ "$status" -eq 0 ]
  [[ "$output" == $'advisory\t'* ]] || { echo "$output"; false; }
}

@test "failed git triad discovery is advisory rather than no-triad block" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/triad-git-failure
  git add -A && git commit -qm "feat: big" >/dev/null

  run _verdict_with_git_diff_failure --name-only
  [ "$status" -eq 0 ]
  [[ "$output" == $'advisory\t'* ]] || { echo "$output"; false; }
}

@test "failed grep triad discovery is advisory rather than no-triad block" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/triad-grep-failure
  git add -A && git commit -qm "feat: big" >/dev/null

  run _verdict_with_triad_grep_failure
  [ "$status" -eq 0 ]
  [[ "$output" == $'advisory\t'* ]] || { echo "$output"; false; }
}

@test "detached HEAD -> advisory (fail-open, exit 0)" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/detach
  git add -A && git commit -qm "feat: big" >/dev/null
  git checkout -q --detach HEAD
  run _gate
  [ "$status" -eq 0 ]
}

# --- determinism (SC2) -------------------------------------------------------

@test "determinism: identical state -> identical verdict across repeated runs" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/determ
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate; local first=$status
  run _gate; local second=$status
  run _gate; local third=$status
  [ "$first" -eq 1 ]
  [ "$first" -eq "$second" ]
  [ "$second" -eq "$third" ]
}

# --- harness parity ----------------------------------------------------------

# --- Stop-hook mode (the harness-facing early-warning) ----------------------

@test "Stop-hook mode: over-floor no-spec -> block JSON + exit 2 (Claude)" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/stop
  git add -A && git commit -qm "feat: big" >/dev/null
  # Stop hooks receive event JSON on stdin; the verdict is state-based.
  run bash -c "cd '$REPO_DIR' && printf '{}' | bash '$GATE'"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]] || { echo "$output"; false; }
}

@test "Stop-hook mode: stop_hook_active=true -> exit 0 (re-entrancy guard, no infinite loop)" {
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/stopguard
  git add -A && git commit -qm "feat: big" >/dev/null
  # Same blocking state as above, but the Stop event is already re-entrant:
  # the guard must exit 0 instead of re-blocking (else infinite Stop loop).
  run bash -c "cd '$REPO_DIR' && printf '{\"stop_hook_active\":true}' | bash '$GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]] || { echo "$output"; false; }
}

@test "Stop-hook mode: passing state -> exit 0, no block JSON (Claude)" {
  _config true 80 400
  _write_lines src/f.js 20
  git checkout -q -b feat/stop-ok
  git add -A && git commit -qm "fix: tiny" >/dev/null
  run bash -c "cd '$REPO_DIR' && printf '{}' | bash '$GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]] || { echo "$output"; false; }
}

@test "Stop-hook mode: DEPLOYED Codex twin blocks identically (exit 2 + JSON)" {
  local cdir="$SANDBOX/codex/hooks"
  mkdir -p "$cdir/lib"
  cp "$CODEX_GATE" "$cdir/spec-gate.sh"
  cp "$REPO/core-rules/hooks/lib/spec-gate-core.sh" "$cdir/lib/spec-gate-core.sh"
  cp "$REPO/core-rules/codex/hooks/lib/deps.sh" "$cdir/lib/deps.sh"
  cp "$REPO/core-rules/hooks/lib/autonomy.sh" "$cdir/lib/autonomy.sh"
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/stop-codex
  git add -A && git commit -qm "feat: big" >/dev/null
  run bash -c "cd '$REPO_DIR' && printf '{}' | bash '$cdir/spec-gate.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]] || { echo "$output"; false; }
}

@test "parity: Claude spec-gate.sh and Codex twin are byte-identical" {
  cmp -s "$GATE" "$CODEX_GATE"
}

@test "parity: same verdict from the DEPLOYED Codex twin on the same state" {
  # The Codex core is single-source: sync-codex-hooks.sh deploys the canonical
  # Claude core into .codex/hooks/lib/. Reproduce that deployed layout so the
  # twin can source its core, then assert it agrees with the Claude gate.
  local cdir="$SANDBOX/codex/hooks"
  mkdir -p "$cdir/lib"
  cp "$CODEX_GATE" "$cdir/spec-gate.sh"
  cp "$REPO/core-rules/hooks/lib/spec-gate-core.sh" "$cdir/lib/spec-gate-core.sh"
  cp "$REPO/core-rules/codex/hooks/lib/deps.sh" "$cdir/lib/deps.sh"
  cp "$REPO/core-rules/hooks/lib/autonomy.sh" "$cdir/lib/autonomy.sh"
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/parity
  git add -A && git commit -qm "feat: big" >/dev/null
  run bash -c "cd '$REPO_DIR' && bash '$GATE' --gate"; local claude=$status
  run bash -c "cd '$REPO_DIR' && bash '$cdir/spec-gate.sh' --gate"; local codex=$status
  [ "$claude" -eq 1 ]
  [ "$claude" -eq "$codex" ]
}


@test "parity: deployed Codex resolves immutable policy with Claude" {
  local cdir="$SANDBOX/codex/hooks"
  mkdir -p "$cdir/lib"
  cp "$CODEX_GATE" "$cdir/spec-gate.sh"
  cp "$REPO/core-rules/hooks/lib/spec-gate-core.sh" "$cdir/lib/spec-gate-core.sh"
  cp "$REPO/core-rules/codex/hooks/lib/deps.sh" "$cdir/lib/deps.sh"
  cp "$REPO/core-rules/hooks/lib/autonomy.sh" "$cdir/lib/autonomy.sh"
  export TRELLIS_ROOT="$TRELLIS_FIXTURE"
  cat > "$TRELLIS_FIXTURE/trellis.config.json" <<'JSON'
{ "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 120, "surgical_max_diff_lines": 480 } }
JSON
  printf '{ "mandatory_pipeline": { "spec_required_diff_lines": 90 } }\n' > "$REPO_DIR/.trellis.config.json"
  printf '{ "mandatory_pipeline": { "surgical_max_diff_lines": 250 } }\n' > "$REPO_DIR/.trellis.json"

  run bash -c "cd '$REPO_DIR' && . '$CORE' && sg_resolve_cfg '$REPO_DIR'"; local claude="$output"
  [ "$status" -eq 0 ]
  run bash -c "cd '$REPO_DIR' && . '$cdir/lib/spec-gate-core.sh' && sg_resolve_cfg '$REPO_DIR'"; local codex="$output"
  [ "$status" -eq 0 ]
  [ "$claude" = "true 90 250 ok" ]
  [ "$claude" = "$codex" ]
}
@test "inherited Trellis infrastructure does not count toward the gated diff" {
  _config true 80 400
  # A canonical hook sync: far over the floor, but every path is copied from the
  # Trellis clone rather than authored here, so the project-local triad the gate
  # would demand cannot meaningfully exist.
  _write_lines .claude/hooks/stop-verify.sh 300
  _write_lines .claude/hooks/lib/spec-gate-core.sh 300
  _write_lines .codex/hooks/spec-gate.sh 300
  _write_lines .agents/skills/execute/SKILL.md 200
  git checkout -q -b chore/sync-hooks
  git add -A && git commit -qm "chore: sync hooks to canonical" >/dev/null
  run _gate
  [ "$status" -eq 0 ]
}

@test "inherited-infra exclusion does not shield real feature code beside it" {
  _config true 80 400
  # The exclusion is path-scoped, not a blanket pass for the commit: application
  # code in the same push is still counted and still blocks.
  _write_lines .claude/hooks/stop-verify.sh 300
  _write_lines src/billing.ts 200
  git checkout -q -b feat/mixed
  git add -A && git commit -qm "hooks plus a real feature" >/dev/null
  run _gate
  [ "$status" -ne 0 ]
  [[ "$output" == *"over floor"* ]] || { echo "$output"; false; }
}
