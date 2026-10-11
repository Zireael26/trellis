#!/usr/bin/env bats
# B0-6: every Trellis pi launcher validates <cwd>/.pi before starting pi.
# Hermetic: each case builds its own repository and TRELLIS_HOME under a
# temporary directory; the protected base is a local refs/remotes/origin ref.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
VALIDATOR="$REPO_ROOT/core-rules/pi/lib/validate-project-pi.sh"
PAYLOAD='{"workflowsEnabled": true, "toolDescriptionMode": "compact"}'

setup() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/validate-project-pi.XXXXXX")"
  WORK="$(CDPATH= cd "$WORK" && pwd -P)"
  export HOME="$WORK/home" TRELLIS_HOME="$WORK/home/.trellis"
  mkdir -p "$HOME"
  WT="$WORK/wt"
  git -c init.defaultBranch=main init -q "$WT"
  git -C "$WT" config user.name test
  git -C "$WT" config user.email test@example.invalid
  git -C "$WT" config commit.gpgsign false
  printf 'seed\n' >"$WT/README"
  git -C "$WT" add README
  git -C "$WT" commit -qm seed
}

teardown() {
  chmod -R u+rwx "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}

# Make the current HEAD the protected base: origin's default branch tip.
publish_base() {
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  git -C "$WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

commit_all() {
  git -C "$WT" add -A -f .pi
  git -C "$WT" commit -qm "$1"
}

refuses_key() {
  mkdir -p "$WT/.pi"
  printf '{"workflowsEnabled": true, "toolDescriptionMode": "compact", "%s": %s}\n' "$1" "$2" >"$WT/.pi/subagents.json"
  publish_base
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/subagents.json"* ]]
  [[ "$output" == *"$1"* ]]
  [[ "$output" == *"remove it, or merge it through a PR with owner approval"* ]]
}

# --- widening keys in subagents.json ------------------------------------------

@test "fallbackSubagent refuses" { refuses_key fallbackSubagent '"general-purpose"'; }
@test "worktreeIsolation refuses" { refuses_key worktreeIsolation false; }
@test "strictAgentFiles refuses" { refuses_key strictAgentFiles false; }
@test "scopeModels refuses" { refuses_key scopeModels false; }
@test "disableDefaultAgents refuses" { refuses_key disableDefaultAgents true; }
@test "maxSubagentDepth refuses" { refuses_key maxSubagentDepth 0; }
@test "defaultMaxTurns refuses" { refuses_key defaultMaxTurns 1; }
@test "maxConcurrent refuses" { refuses_key maxConcurrent 1; }
@test "any other key refuses" { refuses_key someFutureKey '"x"'; }

@test "a foreman value other than the launcher's refuses" {
  mkdir -p "$WT/.pi"
  printf '{"workflowsEnabled": false, "toolDescriptionMode": "compact"}\n' >"$WT/.pi/subagents.json"
  publish_base
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/subagents.json"* ]]
}

# --- loader paths ---------------------------------------------------------------

@test ".pi/agents/ refuses" {
  mkdir -p "$WT/.pi/agents"
  printf -- '---\nname: x\n---\n' >"$WT/.pi/agents/x.md"
  publish_base
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/agents/x.md"* ]]
  [[ "$output" == *"untracked"* ]]
}

@test ".pi/extensions/ refuses" {
  mkdir -p "$WT/.pi/extensions"
  printf 'export default () => {}\n' >"$WT/.pi/extensions/evil.ts"
  publish_base
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/evil.ts"* ]]
}

@test ".pi/settings.json refuses" {
  mkdir -p "$WT/.pi"
  printf '{"packages": ["npm:evil"]}\n' >"$WT/.pi/settings.json"
  publish_base
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/settings.json"* ]]
}

@test ".pi/settings.local.json, mcp.json, skills, prompts, SYSTEM.md refuse" {
  for path in settings.local.json mcp.json skills/x/SKILL.md prompts/x.md SYSTEM.md; do
    rm -rf "$WT/.pi"
    mkdir -p "$(dirname "$WT/.pi/$path")"
    printf 'x\n' >"$WT/.pi/$path"
    run "$VALIDATOR" "$WT"
    [ "$status" -eq 1 ] || { echo "$path passed"; false; }
    [[ "$output" == *".pi/$path"* ]]
  done
}

# --- what passes ----------------------------------------------------------------

@test "no .pi, an empty .pi, and the foreman's own files pass" {
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 0 ]
  mkdir -p "$WT/.pi"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$PAYLOAD" >"$WT/.pi/subagents.json"
  printf '/.gitignore\n/subagents.json\n' >"$WT/.pi/.gitignore"
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 0 ]
}

@test "a non-foreman launcher refuses even the foreman payload" {
  mkdir -p "$WT/.pi"
  printf '%s\n' "$PAYLOAD" >"$WT/.pi/subagents.json"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/subagents.json"* ]]
}

@test "content tracked and identical at the protected base passes" {
  mkdir -p "$WT/.pi/agents"
  printf -- '---\nname: x\n---\n' >"$WT/.pi/agents/x.md"
  printf '{"maxConcurrent": 4}\n' >"$WT/.pi/subagents.json"
  commit_all reviewed
  publish_base
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "tracked content modified on the branch refuses" {
  mkdir -p "$WT/.pi/agents"
  printf -- '---\nname: x\n---\n' >"$WT/.pi/agents/x.md"
  commit_all reviewed
  publish_base
  printf -- '---\nname: x\ntools: read, bash\n---\n' >"$WT/.pi/agents/x.md"
  commit_all widened
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/agents/x.md"* ]]
  [[ "$output" == *"differs from the protected base"* ]]
}

@test "an unresolvable protected base refuses" {
  mkdir -p "$WT/.pi/agents"
  printf -- '---\nname: x\n---\n' >"$WT/.pi/agents/x.md"
  commit_all reviewed
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected base"* ]]
}

@test "content outside a git worktree refuses" {
  mkdir -p "$WORK/plain/.pi/agents"
  printf 'x\n' >"$WORK/plain/.pi/agents/x.md"
  run "$VALIDATOR" "$WORK/plain"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/agents/x.md"* ]]
}

# --- links and escapes ------------------------------------------------------------

@test "a symlinked .pi refuses" {
  mkdir -p "$WORK/elsewhere"
  ln -s "$WORK/elsewhere" "$WT/.pi"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
}

@test "a symlink under .pi refuses, even to a tracked identical target" {
  mkdir -p "$WT/.pi/agents"
  printf 'x\n' >"$WT/agent.md"
  ln -s ../../agent.md "$WT/.pi/agents/x.md"
  commit_all reviewed
  publish_base
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/agents/x.md"* ]]
  [[ "$output" == *"symlink"* ]]
}

@test "a directory symlink resolving outside the worktree refuses" {
  mkdir -p "$WT/.pi" "$WORK/outside-ext"
  printf 'x\n' >"$WORK/outside-ext/evil.ts"
  ln -s "$WORK/outside-ext" "$WT/.pi/extensions"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions"* ]]
}

@test "a hardlink under .pi refuses" {
  mkdir -p "$WT/.pi"
  printf '%s\n' "$PAYLOAD" >"$WORK/shared.json"
  ln "$WORK/shared.json" "$WT/.pi/subagents.json"
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"link count"* ]]
}

# --- Trellis-managed attachment leaves --------------------------------------------

attach_fixture() {
  mkdir -p "$TRELLIS_HOME/releases/9.9.9/payload/core-rules/pi/extensions" "$WT/.trellis" "$WT/.pi/extensions"
  printf 'trellis\n' >"$TRELLIS_HOME/releases/9.9.9/payload/core-rules/pi/extensions/trellis.ts"
  ln -s "$TRELLIS_HOME/releases/9.9.9/payload" "$WT/.trellis/runtime"
  ln -s ../../.trellis/runtime/core-rules/pi/extensions/trellis.ts "$WT/.pi/extensions/trellis.ts"
}

@test "a managed attachment link listed in the exclude block passes" {
  attach_fixture
  printf '%s\n' '# --- Trellis local attachment exclude block ---' '/.trellis/runtime' \
    '/.pi/extensions/trellis.ts' '# --- end Trellis local attachment exclude block ---' >>"$WT/.git/info/exclude"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the same link without a managed exclude entry refuses" {
  attach_fixture
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts"* ]]
}

@test "a \$HOME other than the account's passwd home is validated like any directory" {
  mkdir -p "$HOME/.pi/agent/extensions"
  printf 'x\n' >"$HOME/.pi/agent/extensions/mine.ts"
  run "$VALIDATOR" "$HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HOME"* ]]
}

@test "the account's passwd home is the user's own profile, not a project" {
  account_home="$(python3 -Ic 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
  # Exits before reading anything there.
  HOME="$account_home" run "$VALIDATOR" "$account_home"
  [ "$status" -eq 0 ]
}

# --- .agents loaders (LB-12 ruling) ---------------------------------------------

@test ".agents/agents/evil.md refuses" {
  mkdir -p "$WT/.agents/agents"
  printf -- '---\nname: evil\ntools: read, bash, write\n---\n' >"$WT/.agents/agents/evil.md"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".agents/agents/evil.md"* ]]
}

@test ".agents/skills/x/SKILL.md refuses" {
  mkdir -p "$WT/.agents/skills/x"
  printf -- '---\nname: x\n---\n' >"$WT/.agents/skills/x/SKILL.md"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".agents/skills/x/SKILL.md"* ]]
}

@test ".agents/workflows/evil.js refuses" {
  mkdir -p "$WT/.agents/workflows"
  printf 'export default 1\n' >"$WT/.agents/workflows/evil.js"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".agents/workflows/evil.js"* ]]
}

@test "an ancestor .agents/skills inside the repository refuses from a subdirectory" {
  mkdir -p "$WT/.agents/skills/x" "$WT/sub"
  printf 'x\n' >"$WT/.agents/skills/x/SKILL.md"
  run "$VALIDATOR" "$WT/sub"
  [ "$status" -eq 1 ]
  [[ "$output" == *".agents/skills/x/SKILL.md"* ]]
}

@test ".agents content pi does not load passes" {
  mkdir -p "$WT/.agents/rules"
  printf 'x\n' >"$WT/.agents/rules/notes.md"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "release-roster copies pass in .pi/agents and .agents/agents; an edited one refuses" {
  roster="$(ls "$REPO_ROOT"/core-rules/pi/agents/*.md 2>/dev/null | head -1)"
  [ -n "$roster" ] || skip "no release roster in this checkout"
  name="$(basename "$roster")"
  mkdir -p "$WT/.pi/agents" "$WT/.agents/agents"
  cp "$roster" "$WT/.pi/agents/$name"
  cp "$roster" "$WT/.agents/agents/$name"
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'tools: read, bash, write\n' >>"$WT/.agents/agents/$name"
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".agents/agents/$name"* ]]
}

@test "a managed .agents/skills link listed in the exclude block passes" {
  mkdir -p "$TRELLIS_HOME/releases/9.9.9/payload/core-rules/skills/process-gate" "$WT/.trellis" "$WT/.agents/skills"
  ln -s "$TRELLIS_HOME/releases/9.9.9/payload" "$WT/.trellis/runtime"
  ln -s ../../.trellis/runtime/core-rules/skills/process-gate "$WT/.agents/skills/process-gate"
  printf '%s\n' '# --- Trellis local attachment exclude block ---' '/.trellis/runtime' \
    '/.agents/skills/process-gate' '# --- end Trellis local attachment exclude block ---' >>"$WT/.git/info/exclude"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a managed link whose runtime anchor is not a Trellis release refuses" {
  mkdir -p "$WORK/fake-runtime/core-rules/pi/extensions" "$WT/.trellis" "$WT/.pi/extensions"
  printf 'evil\n' >"$WORK/fake-runtime/core-rules/pi/extensions/trellis.ts"
  ln -s "$WORK/fake-runtime" "$WT/.trellis/runtime"
  ln -s ../../.trellis/runtime/core-rules/pi/extensions/trellis.ts "$WT/.pi/extensions/trellis.ts"
  printf '%s\n' '# --- Trellis local attachment exclude block ---' '/.trellis/runtime' \
    '/.pi/extensions/trellis.ts' '# --- end Trellis local attachment exclude block ---' >>"$WT/.git/info/exclude"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts"* ]]
}

# --- authorization-bypass audit -----------------------------------------------------

@test "GIT_DIR in the caller's environment cannot supply the approval" {
  mkdir -p "$WT/.pi/agents"
  printf 'evil\n' >"$WT/.pi/agents/x.md"
  EVIL="$WORK/evil"
  git -c init.defaultBranch=main init -q "$EVIL"
  mkdir -p "$EVIL/.pi/agents"
  printf 'evil\n' >"$EVIL/.pi/agents/x.md"
  git -C "$EVIL" add -f .pi/agents/x.md
  git -C "$EVIL" -c user.name=t -c user.email=t@e.invalid -c commit.gpgsign=false commit -qm evil
  git -C "$EVIL" update-ref refs/remotes/origin/main HEAD
  GIT_DIR="$EVIL/.git" GIT_WORK_TREE="$WT" run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/agents/x.md"* ]]
}

@test "a branch-committed .trellis/runtime cannot stand in for the managed anchor" {
  mkdir -p "$WT/.trellis/runtime/core-rules/pi/extensions" "$WT/.pi/extensions"
  printf 'evil\n' >"$WT/.trellis/runtime/core-rules/pi/extensions/trellis.ts"
  ln -s ../../.trellis/runtime/core-rules/pi/extensions/trellis.ts "$WT/.pi/extensions/trellis.ts"
  printf '%s\n' '# --- Trellis local attachment exclude block ---' '/.trellis/runtime' \
    '/.pi/extensions/trellis.ts' '# --- end Trellis local attachment exclude block ---' >>"$WT/.git/info/exclude"
  run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts"* ]]
}

@test "a .pi pi can search but the validator cannot list refuses" {
  mkdir -p "$WT/.pi"
  printf '{"fallbackSubagent": "general-purpose"}\n' >"$WT/.pi/subagents.json"
  chmod 0311 "$WT/.pi"
  run "$VALIDATOR" "$WT"
  chmod 0755 "$WT/.pi"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi"* ]]
}

@test "a subagents.json with a second JSON value refuses" {
  mkdir -p "$WT/.pi"
  printf '%s\n%s\n' '{"fallbackSubagent": "general-purpose"}' "$PAYLOAD" >"$WT/.pi/subagents.json"
  run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/subagents.json"* ]]
}

# --- environment a branch's .envrc can set (B0-6 security review F1-F5) ------------

evil_extension() {
  mkdir -p "$WT/.pi/extensions"
  printf 'export default () => {}\n' >"$WT/.pi/extensions/evil.ts"
  publish_base
}

@test "F1: HOME pointed at the worktree does not exempt it" {
  evil_extension
  HOME="$WT" run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HOME"* ]]
}

@test "F2: PI_CODING_AGENT_DIR pointed into the worktree refuses" {
  mkdir -p "$WT/.pi-agent/extensions"
  printf 'export default () => {}\n' >"$WT/.pi-agent/extensions/pwn.ts"
  publish_base
  PI_CODING_AGENT_DIR="$WT/.pi-agent" run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PI_CODING_AGENT_DIR"* ]]
}

@test "F3: a TRELLIS_HOME inside the worktree cannot vouch for a managed link" {
  TRELLIS_HOME="$WT/.fake-trellis"
  attach_fixture
  printf '%s\n' '# --- Trellis local attachment exclude block ---' '/.trellis/runtime' \
    '/.pi/extensions/trellis.ts' '# --- end Trellis local attachment exclude block ---' >>"$WT/.git/info/exclude"
  TRELLIS_HOME="$TRELLIS_HOME" run "$VALIDATOR" "$WT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRELLIS_HOME"* ]]
}

@test "F4: a symlinked ancestor .agents refuses from a subdirectory" {
  mkdir -p "$WORK/outside-agents/skills/x" "$WT/sub"
  printf -- '---\nname: x\n---\n' >"$WORK/outside-agents/skills/x/SKILL.md"
  ln -s "$WORK/outside-agents" "$WT/.agents"
  run "$VALIDATOR" "$WT/sub"
  [ "$status" -eq 1 ]
  [[ "$output" == *".agents"*"symlink"* ]]
}

@test "F5: a jq earlier on PATH inside the worktree is never run" {
  mkdir -p "$WT/bin" "$WT/.pi"
  printf '#!/bin/sh\n: >"%s"\nexit 0\n' "$WORK/fake-jq-ran" >"$WT/bin/jq"
  chmod +x "$WT/bin/jq"
  printf '{"fallbackSubagent": "general-purpose"}\n' >"$WT/.pi/subagents.json"
  PATH="$WT/bin:$PATH" run "$VALIDATOR" --foreman "$WT"
  [ "$status" -eq 1 ]
  [ ! -e "$WORK/fake-jq-ran" ]
}
