#!/usr/bin/env bats
# Spec 055 Unit 1: Codex hooks run in place from the payload resolve their
# shared core libraries, and only inside the declared runtime's own tree.
#
# The rendered .codex/hooks.json runs each hook as
#   TRELLIS_ROOT=<project>/.trellis/runtime <project>/.trellis/runtime/core-rules/codex/hooks/<hook>.sh
# where .trellis/runtime links to the release payload. In place, the hook's own
# lib/ lacks the shared cores, so they must come from core-rules/hooks/lib/ —
# but never from a project-controlled <project>/hooks/lib/ reached through a
# deployed .codex/hooks/ link, and never from a project path that merely ends in
# core-rules/codex/hooks.
#
# Every fixture lives under $BATS_TEST_TMPDIR (a copy of the payload-shaped tree,
# a throwaway project repo, an unrelated cwd); nothing touches ~/.trellis.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  unset TRELLIS_ROOT CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR CODE_REVIEWER_CMD \
    TRELLIS_REVIEW_IN_PROGRESS TRELLIS_REVIEW_OVERRIDE SLOP_TRIPWIRE \
    HC_SCOPE HC_TERMINAL_ID HC_TERMINAL_SOCKET
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  PAYLOAD="$TMP/payload"
  mkdir -p "$PAYLOAD/core-rules/codex"
  cp -R "$REPO/core-rules/codex/hooks" "$PAYLOAD/core-rules/codex/hooks"
  cp -R "$REPO/core-rules/hooks" "$PAYLOAD/core-rules/hooks"
  # spec-gate takes its diff base from the process-gate resolver, which every
  # release payload ships beside the hooks.
  mkdir -p "$PAYLOAD/core-rules/skills/process-gate/scripts/lib"
  cp "$REPO/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$PAYLOAD/core-rules/skills/process-gate/scripts/lib/diff-base.sh"
  printf '%s\n' '{ "template": { "branch": "main" }, "mandatory_pipeline": { "enabled": true, "spec_required_diff_lines": 80, "surgical_max_diff_lines": 400 } }' \
    > "$PAYLOAD/trellis.config.json"
  INPLACE="$PAYLOAD/core-rules/codex/hooks"
  CLAUDE_INPLACE="$PAYLOAD/core-rules/hooks"
  ELSEWHERE="$TMP/elsewhere"
  mkdir -p "$ELSEWHERE"
  MARK="$TMP/sentinel-ran"

  PROJECT="$TMP/project"
  mkdir -p "$PROJECT/.trellis"
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" config user.email t@t.t
  git -C "$PROJECT" config user.name t
  printf '.trellis/\n.codex/\n' >> "$PROJECT/.git/info/exclude"
  printf 'seed\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" commit -qm init
  ln -s "$PAYLOAD" "$PROJECT/.trellis/runtime"
  RUNTIME="$PROJECT/.trellis/runtime"
}

# A feature branch whose 200-line diff the mandatory pipeline blocks.
blocking_branch() {
  local i
  git -C "$PROJECT" checkout -q -b feat/big
  mkdir -p "$PROJECT/src"
  for i in $(seq 1 200); do printf 'const line_%s = %s;\n' "$i" "$i"; done > "$PROJECT/src/f.js"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "feat: big"
}

# A feature branch the mandatory pipeline passes (sub-floor).
passing_branch() {
  git -C "$PROJECT" checkout -q -b fix/small
  mkdir -p "$PROJECT/src"
  printf 'const a = 1;\n' > "$PROJECT/src/f.js"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "fix: small"
}

# Three staged non-doc files: enough for the code-review threshold.
review_trigger() {
  printf 'def alpha():\n    return 1\n' > "$PROJECT/alpha.py"
  printf 'def beta():\n    return 2\n' > "$PROJECT/beta.py"
  printf 'def gamma():\n    return 3\n' > "$PROJECT/gamma.py"
  git -C "$PROJECT" add alpha.py beta.py gamma.py
}

critical_reviewer() {
  local reviewer="$TMP/critical-reviewer.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' \
    'printf "%s\n" "{\"findings\":[{\"severity\":\"critical\",\"file\":\"alpha.py\",\"line\":1,\"msg\":\"stub critical\"}]}"' \
    > "$reviewer"
  chmod +x "$reviewer"
  printf '%s' "$reviewer"
}

# sentinel <path>: a file that records it ran, whether sourced or executed.
sentinel() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "printf 'ran %s\n' '$1' >> '$MARK'" > "$1"
  chmod +x "$1"
}

slop_event() {
  jq -nc --arg f "$1" --arg cwd "$PROJECT" '{tool_name: "Edit", tool_input: {file_path: $f}, cwd: $cwd}'
}

# Run a hook as the rendered in-place command does, from an unrelated cwd.
run_inplace() {
  local hook="$1" input="$2"
  shift 2
  run bash -c 'cd "$1" && shift && printf "%s" "$1" | env "${@:3}" "$2"' _ \
    "$ELSEWHERE" "$input" "$hook" CODEX_PROJECT_DIR="$PROJECT" "$@"
}

# --- A1.1: each hook resolves its core in place ------------------------------

@test "A1.1 in-place spec-gate --gate blocks the state the Claude gate blocks" {
  blocking_branch
  run bash -c 'cd "$1" && TRELLIS_ROOT="$2" "$3" --gate' _ "$PROJECT" "$RUNTIME" "$RUNTIME/core-rules/codex/hooks/spec-gate.sh"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" != *"No such file"* ]] || { echo "$output"; false; }
  [[ "$output" != *"degraded"* ]] || { echo "$output"; false; }
  # Same verdict as the Claude gate on the same state.
  run bash -c 'cd "$1" && TRELLIS_ROOT="$2" "$3" --gate' _ "$PROJECT" "$RUNTIME" "$RUNTIME/core-rules/hooks/spec-gate.sh"
  [ "$status" -eq 1 ]
}

@test "A1.1 in-place ui-verify reaches its core and relays a block" {
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "{\"verdict\":\"block\",\"reason\":\"stub-core-block\"}"' \
    > "$PAYLOAD/core-rules/hooks/lib/ui-verify-core.sh"
  run_inplace "$RUNTIME/core-rules/codex/hooks/ui-verify.sh" '{}' TRELLIS_ROOT="$RUNTIME"
  # Codex Stop block contract (spec 045 amendment): stdout JSON on exit 0.
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'"decision":"block"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"stub-core-block"* ]] || { echo "$output"; false; }
}

@test "A1.1 in-place code-review-subagent reaches the reviewer ladder and blocks on a critical" {
  review_trigger
  run_inplace "$RUNTIME/core-rules/codex/hooks/code-review-subagent.sh" '{}' \
    TRELLIS_ROOT="$RUNTIME" CODE_REVIEWER_CMD="$(critical_reviewer)"
  # Codex Stop block contract (spec 045 amendment): stdout JSON on exit 0.
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'"decision":"block"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"stub critical"* ]] || { echo "$output"; false; }
  [[ "$output" != *"reviewer library unavailable"* ]] || { echo "$output"; false; }
}

@test "A1.1 in-place slop-tripwire reaches its patterns and reports an added slop line" {
  mkdir -p "$PROJECT/src"
  printf 'const bad = JSON.parse(body) as any;\n' > "$PROJECT/src/client.ts"
  run_inplace "$RUNTIME/core-rules/codex/hooks/slop-tripwire.sh" "$(slop_event "$PROJECT/src/client.ts")" \
    TRELLIS_ROOT="$RUNTIME"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"slop-tripwire: ts-as-any"* ]] || { echo "$output"; false; }
}

# --- A1.2: the fallback never reaches a project-controlled file --------------

@test "A1.2 deployed hooks with a missing sibling never source <project>/hooks/lib" {
  local codex="$PROJECT/.codex/hooks" pair hook lib f input
  for pair in \
    decision-receipt.sh:decision-receipt-core.sh \
    post-edit-verify.sh:action-normalize.sh \
    reread-guard.sh:action-normalize.sh \
    slop-tripwire.sh:action-normalize.sh \
    track-read.sh:action-normalize.sh \
    wiki-skill-suggest.sh:action-normalize.sh; do
    hook="${pair%%:*}" lib="${pair#*:}"
    # The manifest's deployed layout: hook links in .codex/hooks/, every lib
    # linked into .codex/hooks/lib/ — minus the one under test.
    mkdir -p "$codex/lib"
    find "$codex" -type l -exec unlink {} \;
    ln -s "$INPLACE/$hook" "$codex/$hook"
    for f in "$INPLACE"/lib/*.sh "$PAYLOAD"/core-rules/hooks/lib/*; do
      [ "${f##*/}" = "$lib" ] || [ -e "$codex/lib/${f##*/}" ] || ln -s "$f" "$codex/lib/${f##*/}"
    done
    sentinel "$PROJECT/hooks/lib/$lib"
    input="$(slop_event "$PROJECT/README.md")"
    run bash -c 'cd "$1" && printf "%s" "$2" | env CODEX_PROJECT_DIR="$1" TRELLIS_ROOT="$1/.trellis/runtime" "$3"' _ \
      "$PROJECT" "$input" "$codex/$hook"
    [ ! -e "$MARK" ] || { echo "$hook sourced $(cat "$MARK")"; false; }
  done
}

@test "A1.2 a project path ending in core-rules/codex/hooks gains no fallback (suffix spoof)" {
  local spoof="$PROJECT/vendor/core-rules/codex/hooks" hook core
  mkdir -p "$spoof/lib"
  cp "$INPLACE"/lib/*.sh "$spoof/lib/"
  for hook in spec-gate.sh ui-verify.sh code-review-subagent.sh slop-tripwire.sh; do
    cp "$INPLACE/$hook" "$spoof/$hook"
  done
  for core in spec-gate-core.sh ui-verify-core.sh code-reviewer.sh slop-patterns.sh action-normalize.sh; do
    sentinel "$PROJECT/vendor/core-rules/hooks/lib/$core"
  done
  blocking_branch
  review_trigger
  for hook in spec-gate.sh ui-verify.sh code-review-subagent.sh slop-tripwire.sh; do
    run bash -c 'cd "$1" && printf "{}" | env CODEX_PROJECT_DIR="$1" TRELLIS_ROOT="$2" "$3"' _ \
      "$PROJECT" "$PAYLOAD" "$spoof/$hook"
    [ ! -e "$MARK" ] || { echo "$hook sourced $(cat "$MARK")"; false; }
  done
  run bash -c 'cd "$1" && TRELLIS_ROOT="$2" "$3" --gate' _ "$PROJECT" "$PAYLOAD" "$spoof/spec-gate.sh"
  [ "$status" -eq 1 ]
  [ ! -e "$MARK" ]
}

@test "A1.2 TRELLIS_ROOT both ways: unset fails closed, set resolves the core" {
  passing_branch
  run bash -c 'cd "$1" && unset TRELLIS_ROOT && "$2" --gate' _ "$PROJECT" "$INPLACE/spec-gate.sh"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"degraded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"run trellis doctor in $PROJECT"* ]] || { echo "$output"; false; }
  run bash -c 'cd "$1" && TRELLIS_ROOT="$2" "$3" --gate' _ "$PROJECT" "$PAYLOAD" "$INPLACE/spec-gate.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"degraded"* ]] || { echo "$output"; false; }
}

# --- A1.3: a missing core fails closed in the blocking gates -----------------

@test "A1.3 missing spec-gate core: --gate exits 1 in both harness copies" {
  local gate
  passing_branch
  mv "$PAYLOAD/core-rules/hooks/lib/spec-gate-core.sh" "$TMP/spec-gate-core.sh.aside"
  for gate in "$RUNTIME/core-rules/codex/hooks/spec-gate.sh" "$RUNTIME/core-rules/hooks/spec-gate.sh"; do
    run bash -c 'cd "$1" && TRELLIS_ROOT="$2" "$3" --gate' _ "$PROJECT" "$RUNTIME" "$gate"
    [ "$status" -eq 1 ] || { echo "$gate: $output"; false; }
    [[ "$output" == *"spec-gate-core.sh"* ]] || { echo "$output"; false; }
    [[ "$output" == *"run trellis doctor in $PROJECT"* ]] || { echo "$output"; false; }
  done
}

@test "A1.3 missing cores: both Stop gates block with the repair line in both copies" {
  local hook
  passing_branch
  mv "$PAYLOAD/core-rules/hooks/lib/spec-gate-core.sh" "$TMP/spec-gate-core.sh.aside"
  mv "$PAYLOAD/core-rules/hooks/lib/ui-verify-core.sh" "$TMP/ui-verify-core.sh.aside"
  for hook in codex/hooks/spec-gate.sh hooks/spec-gate.sh codex/hooks/ui-verify.sh hooks/ui-verify.sh; do
    run bash -c 'cd "$1" && printf "{}" | env CODEX_PROJECT_DIR="$1" TRELLIS_ROOT="$2" "$3"' _ \
      "$PROJECT" "$RUNTIME" "$RUNTIME/core-rules/$hook"
    # Block contracts differ by harness: Claude JSON + exit 2, Codex stdout JSON on
    # exit 0 (spec 045 amendment).
    local want=2; [[ "$hook" == codex/* ]] && want=0
    [ "$status" -eq "$want" ] || { echo "$hook: $status $output"; false; }
    [[ "$output" == *'"decision":"block"'* ]] || { echo "$hook: $output"; false; }
    [[ "$output" == *"-core.sh"* ]] || { echo "$hook: $output"; false; }
    [[ "$output" == *"run trellis doctor in $PROJECT"* ]] || { echo "$hook: $output"; false; }
    # Re-entrant Stop never re-blocks.
    run bash -c 'cd "$1" && printf "{\"stop_hook_active\":true}" | env CODEX_PROJECT_DIR="$1" TRELLIS_ROOT="$2" "$3"' _ \
      "$PROJECT" "$RUNTIME" "$RUNTIME/core-rules/$hook"
    [ "$status" -eq 0 ] || { echo "$hook guard: $status $output"; false; }
    [[ "$output" != *'"decision":"block"'* ]] || { echo "$hook guard: $output"; false; }
  done
}

@test "A1.3 missing reviewer: code-review-subagent stays advisory with a degraded line" {
  review_trigger
  mv "$PAYLOAD/core-rules/hooks/lib/code-reviewer.sh" "$TMP/code-reviewer.sh.aside"
  run_inplace "$RUNTIME/core-rules/codex/hooks/code-review-subagent.sh" '{}' \
    TRELLIS_ROOT="$RUNTIME" CODE_REVIEWER_CMD="$(critical_reviewer)"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"review degraded"* ]] || { echo "$output"; false; }
  [[ "$output" != *'"decision":"block"'* ]] || { echo "$output"; false; }
}
