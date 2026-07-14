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

# _config <enabled> [floor] [ceiling] — write the fixture trellis.config.json AND
# commit it on the current branch (always main, at call time) so every feature
# branch created afterward inherits it through the merge-base. Without the commit,
# a test that checks out main mid-run would lose the config on the next branch.
_config() {
  local enabled="$1" floor="${2:-80}" ceiling="${3:-400}"
  cat > "$REPO_DIR/trellis.config.json" <<JSON
{ "template": { "branch": "main" },
  "mandatory_pipeline": { "enabled": $enabled, "spec_required_diff_lines": $floor, "surgical_max_diff_lines": $ceiling } }
JSON
  ( cd "$REPO_DIR" && git add trellis.config.json && git commit -qm "chore: trellis config" >/dev/null )
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

_resolved_cfg() {
  ( . "$CORE" && sg_resolve_cfg "$REPO_DIR" )
}

_autonomy_level() {
  ( . "$CORE" && sg_autonomy_level "$REPO_DIR" )
}

_write_fleet_autonomy() {
  printf '{"autonomy_default":%s}\n' "$1" > "$TRELLIS_FIXTURE/trellis.config.json"
}

_write_project_autonomy() {
  local autonomy_json="$1" presets_json="${2:-[]}"
  jq -n \
    --arg root "$TRELLIS_FIXTURE" \
    --argjson autonomy "$autonomy_json" \
    --argjson presets "$presets_json" \
    '{trellis_root: $root, presets: $presets}
     + (if $autonomy == null then {} else {autonomy: $autonomy} end)' \
    > "$REPO_DIR/.trellis.config.json"
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
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"Surgical"* ]]
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
  [[ "$output" == *"interview artifact"* ]]
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

# --- config failure semantics (C-6a) ----------------------------------------

@test "malformed: mandatory_pipeline not an object -> BLOCK (fail-closed)" {
  cat > "$REPO_DIR/trellis.config.json" <<'JSON'
{ "template": { "branch": "main" }, "mandatory_pipeline": true }
JSON
  _write_lines src/f.js 200
  git checkout -q -b feat/malformed
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

@test "malformed: unparseable JSON -> BLOCK (fail-closed)" {
  printf '{ this is not json ' > "$REPO_DIR/trellis.config.json"
  _write_lines src/f.js 200
  git checkout -q -b feat/badjson
  git add -A && git commit -qm "feat: big" >/dev/null
  run _gate
  [ "$status" -eq 1 ]
}

@test "missing optional thresholds use the documented defaults" {
  cat > "$REPO_DIR/trellis.config.json" <<'JSON'
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
        "$key" "$value" > "$REPO_DIR/trellis.config.json"

      run _gate
      [ "$status" -eq 1 ]
      [[ "$output" == *"malformed"* ]]
    done
  done
}

# --- fail-open on a broken environment --------------------------------------

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
  [[ "$output" == *'"decision":"block"'* ]]
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
  [[ "$output" != *'"decision":"block"'* ]]
}

@test "Stop-hook mode: passing state -> exit 0, no block JSON (Claude)" {
  _config true 80 400
  _write_lines src/f.js 20
  git checkout -q -b feat/stop-ok
  git add -A && git commit -qm "fix: tiny" >/dev/null
  run bash -c "cd '$REPO_DIR' && printf '{}' | bash '$GATE'"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision":"block"'* ]]
}

@test "Stop-hook mode: DEPLOYED Codex twin blocks identically (exit 2 + JSON)" {
  local cdir="$SANDBOX/codex/hooks"
  mkdir -p "$cdir/lib"
  cp "$CODEX_GATE" "$cdir/spec-gate.sh"
  cp "$REPO/core-rules/hooks/lib/spec-gate-core.sh" "$cdir/lib/spec-gate-core.sh"
  cp "$REPO/core-rules/codex/hooks/lib/deps.sh" "$cdir/lib/deps.sh"
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/stop-codex
  git add -A && git commit -qm "feat: big" >/dev/null
  run bash -c "cd '$REPO_DIR' && printf '{}' | bash '$cdir/spec-gate.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"decision":"block"'* ]]
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
  _config true 80 400
  _write_lines src/f.js 200
  git checkout -q -b feat/parity
  git add -A && git commit -qm "feat: big" >/dev/null
  run bash -c "cd '$REPO_DIR' && bash '$GATE' --gate"; local claude=$status
  run bash -c "cd '$REPO_DIR' && bash '$cdir/spec-gate.sh' --gate"; local codex=$status
  [ "$claude" -eq 1 ]
  [ "$claude" -eq "$codex" ]
}
