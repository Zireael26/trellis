#!/usr/bin/env bats
# Focused T6 coverage for the immutable, no-write inheritance surface planner.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
PLANNER="$REPO_ROOT/scripts/lib/surface-plan.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  PAYLOAD="$SANDBOX/payload with spaces"
  PROJECT="$SANDBOX/project with spaces"
  MANIFEST="$PAYLOAD/core-rules/inheritance-manifest.json"

  mkdir -p "$TRELLIS_HOME" "$PAYLOAD" "$PROJECT/.claude/skills"
  cp -R "$REPO_ROOT/core-rules" "$PAYLOAD/core-rules"
  printf 'project-owned\n' > "$PROJECT/.claude/skills/project-only.md"
  printf 'project-owned\n' > "$PROJECT/keep.txt"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

run_plan() {
  run bash "$PLANNER" --payload "$PAYLOAD" "$@"
}

rewrite_manifest() {
  local filter="$1" temporary="$MANIFEST.tmp"
  jq "$filter" "$MANIFEST" > "$temporary"
  mv "$temporary" "$MANIFEST"
}

@test "plans exactly Claude Code and Codex as leaf-owned runtime targets" {
  run_plan
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" | jq -e '
    .schema_version == 1
    and .harnesses == ["claude", "codex"]
    and ([.artifacts[].harness] | unique | sort) == ["claude", "codex", "shared_agents"]
    and ([.artifacts[] | select(.destination == ".claude/skills" or .destination == ".agents/skills")] | length) == 0
    and ([.artifacts[] | select(.kind == "symlink" and .source_scope == "payload") | (.target | contains(".trellis/runtime/"))] | all(.[]; .))
    and ([.artifacts[] | select(.destination == "AGENTS.md" and .source == "CLAUDE.md" and .source_scope == "project" and .target == "CLAUDE.md" and .fallback_source == "core-rules/CLAUDE.md" and .fallback_source_scope == "payload" and .fallback_target == ".trellis/runtime/core-rules/CLAUDE.md" and .target_policy == "project-if-present-else-payload")] | length) == 1
    and ([.artifacts[] | select(.destination == ".codex/hooks/lib/spec-gate-core.sh" and .source == "core-rules/hooks/lib/spec-gate-core.sh")] | length) == 1
    and ([.artifacts[] | select(.destination | startswith(".agents/workflows/")) | .destination] | sort) == [
      ".agents/workflows/explore.md",
      ".agents/workflows/primer-check.md",
      ".agents/workflows/primer-refresh.md",
      ".agents/workflows/primer.md",
      ".agents/workflows/surgical.md"
    ]
    and ([.artifacts[] | select(.harness == "pi")] | length) == 0
  ' >/dev/null
}

@test "user manifest owns the Claude orchestration output style at HOME" {
  local user_home="$SANDBOX/user home"
  mkdir -p "$user_home"

  jq -e '
    ([.harnesses.user.links[] |
      select(
        .source == "core-rules/templates/claude-output-styles/trellis-orchestration.md"
        and .destination == ".claude/output-styles/trellis-orchestration.md"
        and .destination_home == true
      )
    ] | length) == 1
  ' "$MANIFEST" >/dev/null

  HOME="$user_home" run_plan --harness user
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg home "$user_home" --arg target "$PAYLOAD/core-rules/templates/claude-output-styles/trellis-orchestration.md" '
    .harnesses == ["user"]
    and ([.artifacts[] |
      select(
        .kind == "symlink"
        and .source == "core-rules/templates/claude-output-styles/trellis-orchestration.md"
        and .source_scope == "payload"
        and .destination == ($home + "/.claude/output-styles/trellis-orchestration.md")
        and .target == $target
      )
    ] | length) == 1
  ' >/dev/null
}

@test "legacy two-harness manifests still plan the project surface" {
  rewrite_manifest '
    .schema_version = 1
    | .harnesses.codex.links = (.harnesses.shared_agents.links + .harnesses.codex.links)
    | .harnesses.codex.render = (.harnesses.shared_agents.render + .harnesses.codex.render)
    | del(.harnesses.pi, .harnesses.shared_agents, .harnesses.user)
  '

  run_plan
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .harnesses == ["claude", "codex"]
    and ([.artifacts[].harness] | unique | sort) == ["claude", "codex"]
    and ([.artifacts[] | select(.destination == "AGENTS.md")] | length) == 1
    and ([.artifacts[] | select(.destination == ".agents/primers/INDEX.md")] | length) == 1
  ' >/dev/null
}

@test "operator acceptance may pass the canonical core-rules directory" {
  run bash "$PLANNER" --payload "$PAYLOAD/core-rules" --harness claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .harnesses == ["claude"]
    and all(.artifacts[]; .harness == "claude")
  ' >/dev/null
}

@test "output is byte-stable, dynamically discovers skills and commands, and honors suffix filtering" {
  run_plan --harness claude
  [ "$status" -eq 0 ]
  first_plan="$output"

  run_plan --harness claude
  [ "$status" -eq 0 ]
  [ "$output" = "$first_plan" ]

  mkdir -p "$PAYLOAD/core-rules/skills/dynamic-skill"
  printf '%s\n' '---' 'name: dynamic-skill' '---' > "$PAYLOAD/core-rules/skills/dynamic-skill/SKILL.md"
  printf '# dynamic command\n' > "$PAYLOAD/core-rules/commands/dynamic-command.md"
  printf 'not a command\n' > "$PAYLOAD/core-rules/commands/ignored.txt"

  run_plan --harness claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    ([.artifacts[] | select(.source == "core-rules/skills/dynamic-skill" and .destination == ".claude/skills/dynamic-skill")] | length) == 1
    and ([.artifacts[] | select(.source == "core-rules/commands/dynamic-command.md" and .destination == ".claude/commands/dynamic-command.md")] | length) == 1
    and ([.artifacts[] | select(.source == "core-rules/commands/ignored.txt")] | length) == 0
  ' >/dev/null
}

@test "harness subsets are canonicalized and planning leaves project-native siblings untouched" {
  project_before="$(cat "$PROJECT/.claude/skills/project-only.md")"

  run_plan --harness codex --harness claude --harness codex
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .harnesses == ["claude", "codex"]
    and ([.artifacts[].harness] | unique | sort) == ["claude", "codex", "shared_agents"]
  ' >/dev/null

  [ "$(cat "$PROJECT/.claude/skills/project-only.md")" = "$project_before" ]
  [ "$(cat "$PROJECT/keep.txt")" = "project-owned" ]
  [ ! -e "$PROJECT/.agents" ]
  [ ! -e "$PROJECT/.claude/rules" ]
  [ ! -e "$PROJECT/.claude/commands" ]
}

@test "source-child skills require their declared SKILL.md leaf" {
  mkdir -p "$PAYLOAD/core-rules/skills/missing-contract"

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"required source is missing from immutable payload: core-rules/skills/missing-contract/SKILL.md"* ]] || { echo "$output"; false; }
}

@test "optional T12 templates remain optional and declare only contextual trusted SessionStart routes when present" {
  run_plan
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    ([.optional_missing[] | select(.source == "core-rules/templates/claude-settings.local.json" or .source == "core-rules/templates/codex-hooks.local.json")] | length) == 0
    and ([.artifacts[] | select(.kind == "render" and .source == "core-rules/templates/claude-settings.local.json" and .destination == ".claude/settings.local.json" and .merge == "explicit-json" and .mode == "0600")] | length) == 1
    and ([.artifacts[] | select(.kind == "render" and .source == "core-rules/templates/codex-hooks.local.json" and .destination == ".codex/hooks.json" and .merge == "explicit-json" and .mode == "0600")] | length) == 1
  ' >/dev/null

  jq -e '
    def marker_count($marker): split($marker) | length - 1;
    (.hooks.SessionStart[0].hooks | map(.command)) as $commands
    | ($commands | length) == 4
    and all($commands[];
      startswith("/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook ")
      and contains(" claude \"$CLAUDE_PROJECT_DIR\"")
      and marker_count("__TRELLIS_USER_HOME__") == 1
      and marker_count("__TRELLIS_HOME__") == 1
      and marker_count("__TRELLIS_LAUNCHER__") == 1
      and (contains(".trellis/runtime") or contains("$HOME") or contains("$TRELLIS_HOME") or contains("$PATH") or contains("BASH_ENV") or contains(" ENV=") | not))
  ' "$PAYLOAD/core-rules/templates/claude-settings.local.json" >/dev/null

  jq -e '
    def marker_count($marker): split($marker) | length - 1;
    (.hooks.SessionStart[0].hooks | map(.command)) as $commands
    | ($commands | length) == 3
    and all($commands[];
      startswith("/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook ")
      and contains(" codex \"${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}\"")
      and marker_count("__TRELLIS_USER_HOME__") == 1
      and marker_count("__TRELLIS_HOME__") == 1
      and marker_count("__TRELLIS_LAUNCHER__") == 1
      and (contains(".trellis/runtime") or contains("$HOME") or contains("$TRELLIS_HOME") or contains("$PATH") or contains("BASH_ENV") or contains(" ENV=") | not))
  ' "$PAYLOAD/core-rules/templates/codex-hooks.local.json" >/dev/null
  rm "$PAYLOAD/core-rules/templates/claude-settings.local.json"
  rm "$PAYLOAD/core-rules/templates/codex-hooks.local.json"

  run_plan
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    ([.optional_missing[].source] | sort) == [
      "core-rules/templates/claude-settings.local.json",
      "core-rules/templates/codex-hooks.local.json"
    ]
    and ([.artifacts[] | select(.source == "core-rules/templates/claude-settings.local.json" or .source == "core-rules/templates/codex-hooks.local.json")] | length) == 0
  ' >/dev/null
}

@test "render_if_absent reaches the plan record and defaults to false" {
  run_plan --harness claude --harness codex
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" | jq -e '
    ([.artifacts[] | select(.kind == "render") | {destination, merge, render_if_absent}] | sort_by(.destination)) == [
      {destination: ".agents/primers/INDEX.md", merge: "replace", render_if_absent: true},
      {destination: ".claude/primers/INDEX.md", merge: "replace", render_if_absent: true},
      {destination: ".claude/settings.local.json", merge: "explicit-json", render_if_absent: false},
      {destination: ".codex/hooks.json", merge: "explicit-json", render_if_absent: false}
    ]
    and all(.artifacts[] | select(.kind == "render"); has("render_if_absent"))
  ' >/dev/null

  # An optional template the payload does not carry keeps the flag too, so the
  # optional-missing record stays comparable with the artifact it would become.
  rm "$PAYLOAD/core-rules/templates/claude-settings.local.json"

  run_plan --harness claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    ([.optional_missing[] | select(.destination == ".claude/settings.local.json") | .render_if_absent] == [false])
  ' >/dev/null
}

@test "render_if_absent is rejected on an explicit-json render and when non-boolean" {
  rewrite_manifest '.harnesses.claude.render |= map(if .merge == "explicit-json" then .render_if_absent = true else . end)'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  # `false` is no more legal than `true`: the key itself is meaningless where a
  # merge is defined over the project's existing file.
  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rewrite_manifest '.harnesses.codex.render |= map(if .merge == "explicit-json" then .render_if_absent = false else . end)'

  run_plan --harness codex
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rewrite_manifest '.harnesses.claude.render |= map(if .merge == "replace" then .render_if_absent = "true" else . end)'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  run_plan --harness claude
  [ "$status" -eq 0 ]
}

@test "an unavailable payload path uses the shared unavailable exit class" {
  run bash "$PLANNER" --payload "$SANDBOX/missing payload"
  [ "$status" -eq 5 ]
  [[ "$output" == *"payload is unavailable"* ]] || { echo "$output"; false; }
}

@test "Pi-only and Codex-plus-Pi plans share agent leaves without duplicate destinations" {
  run_plan --harness pi
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .harnesses == ["pi"]
    and ([.artifacts[].harness] | unique | sort) == ["pi", "shared_agents"]
    and any(.artifacts[]; .destination == "AGENTS.md")
    and any(.artifacts[]; .destination | startswith(".pi/"))
    and (any(.artifacts[]; .destination | startswith(".codex/")) | not)
    and ([.artifacts[].destination] | length) == ([.artifacts[].destination] | unique | length)
  ' >/dev/null

  run_plan --harness codex --harness pi
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .harnesses == ["codex", "pi"]
    and ([.artifacts[].harness] | unique | sort) == ["codex", "pi", "shared_agents"]
    and any(.artifacts[]; .destination | startswith(".codex/"))
    and any(.artifacts[]; .destination | startswith(".pi/"))
    and ([.artifacts[].destination] | length) == ([.artifacts[].destination] | unique | length)
  ' >/dev/null
}

@test "unknown harnesses are usage errors" {
  run_plan --harness unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown harness: unknown"* ]] || { echo "$output"; false; }
}

@test "user planning matches attachment runtime HOME shape acceptance" {
  real_parent="$SANDBOX/real-parent"
  real_home="$real_parent/home"
  mkdir -p "$real_home"
  export HOME="$real_home"

  run_plan --harness user
  [ "$status" -eq 0 ]

  ln -s "$real_home" "$SANDBOX/home-link"
  export HOME="$SANDBOX/home-link"
  run_plan --harness user
  [ "$status" -eq 5 ]
  [[ "$output" == *"HOME is unavailable or is a symlink"* ]] || { echo "$output"; false; }

  export HOME="$real_home/"
  run_plan --harness user
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME must be a canonical absolute path"* ]] || { echo "$output"; false; }

  export HOME="$real_parent//home"
  run_plan --harness user
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME must be a canonical absolute path"* ]] || { echo "$output"; false; }

  ln -s "$real_parent" "$SANDBOX/parent-link"
  export HOME="$SANDBOX/parent-link/home"
  run_plan --harness user
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg home "$real_home" '
    all(.artifacts[]; .destination | startswith($home + "/"))
  ' >/dev/null
}

@test "case-folded aliases of reserved control destinations are invalid manifest state" {
  mkdir -p "$SANDBOX/user-home"
  export HOME="$SANDBOX/user-home"
  rewrite_manifest '.harnesses.user.links[0].destination = ".TrElLiS/runtime/escape"'

  run_plan --harness user
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rewrite_manifest '.harnesses.user.links[0].destination = ".trelli\u017f/runtime/escape"'

  run_plan --harness user
  [ "$status" -eq 4 ]
  [[ "$output" == *"reserved managed destination alias:"* ]] || { echo "$output"; false; }

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rewrite_manifest '.harnesses.claude.links[0].destination = ".GiT/config"'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }
}

@test "user destination case aliases fail with a deterministic duplicate result" {
  mkdir -p "$SANDBOX/user-home"
  export HOME="$SANDBOX/user-home"
  rewrite_manifest '.harnesses.user.links += [
    {"source": "core-rules/CLAUDE.md", "destination": ".claude/agent/Alias.md", "destination_home": true},
    {"source": "core-rules/CLAUDE.md", "destination": ".claude/AGENT/alias.md", "destination_home": true}
  ]'

  run_plan --harness user
  [ "$status" -eq 3 ]
  [[ "$output" == *"duplicate managed destination alias:"* ]] || { echo "$output"; false; }
  first_error="$output"

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rewrite_manifest '.harnesses.user.links += [
    {"source": "core-rules/CLAUDE.md", "destination": ".claude/AGENT/alias.md", "destination_home": true},
    {"source": "core-rules/CLAUDE.md", "destination": ".claude/agent/Alias.md", "destination_home": true}
  ]'

  run_plan --harness user
  [ "$status" -eq 3 ]
  [ "$output" = "$first_error" ]
}

@test "user destination Unicode canonical aliases cannot produce a plan" {
  mkdir -p "$SANDBOX/user-home"
  export HOME="$SANDBOX/user-home"
  rewrite_manifest '.harnesses.user.links += [
    {"source": "core-rules/CLAUDE.md", "destination": ".claude/agent/\u00c5lias.md", "destination_home": true},
    {"source": "core-rules/CLAUDE.md", "destination": ".claude/agent/A\u030alias.md", "destination_home": true}
  ]'

  run_plan --harness user
  [ "$status" -eq 3 ]
  [[ "$output" == *"duplicate managed destination alias:"* ]] || { echo "$output"; false; }
}

@test "duplicate managed destinations are ownership conflicts" {
  rewrite_manifest '.harnesses.claude.links += [{"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}]'

  run_plan --harness claude
  [ "$status" -eq 3 ]
  [[ "$output" == *"duplicate managed destination: .claude/rules/trellis.md"* ]] || { echo "$output"; false; }
}

@test "unsafe source and destination traversal are rejected as corrupt manifest state" {
  rewrite_manifest '.harnesses.claude.links[0].source = "../outside"'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  rewrite_manifest '.harnesses.claude.links[0].source = "core-rules/CLAUDE.md" | .harnesses.claude.links[0].destination = ".trellis/runtime/escape"'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rewrite_manifest '.harnesses.codex.links[0].project_target = "../CLAUDE.md"'

  run_plan --harness codex
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }
}

@test "tab newline and NUL manifest path values are rejected" {
  rewrite_manifest '.harnesses.claude.links[0].destination = ".claude/\tunsafe.md"'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  rewrite_manifest '.harnesses.claude.links[0].destination = ".claude/\nunsafe.md"'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  rewrite_manifest '.harnesses.claude.links[0].destination = ".claude/\u0000unsafe.md"'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }
}

@test "malformed entry shapes and missing required payload sources fail closed" {
  rewrite_manifest '.harnesses.claude.links[0].unexpected = true'

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"inheritance manifest is malformed or unsafe"* ]] || { echo "$output"; false; }

  cp "$REPO_ROOT/core-rules/inheritance-manifest.json" "$MANIFEST"
  rm "$PAYLOAD/core-rules/CLAUDE.md"

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"required source is missing from immutable payload: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "manifest enumeration failures cannot produce a partial successful plan" {
  printf '{\n' > "$MANIFEST"

  run bash -c '. "$1"; trap surface_plan_cleanup EXIT; surface_plan_emit_harness "$2" "$3" claude' _ \
    "$PLANNER" "$PAYLOAD" "$MANIFEST"
  [ "$status" -eq 4 ]
  [[ "$output" == *"could not enumerate links for harness: claude"* ]] || { echo "$output"; false; }
}

@test "child exclusion and sorting failures cannot silently drop planned leaves" {
  run bash -c '. "$1"; jq() { if [ "$1" = "-r" ] && [ "$2" = ".exclude_dirs // [] | .[]" ]; then return 1; fi; command jq "$@"; }; surface_plan_emit "$2" claude' _ \
    "$PLANNER" "$PAYLOAD"
  [ "$status" -eq 4 ]
  [[ "$output" == *"could not enumerate source exclusions"* ]] || { echo "$output"; false; }

  run bash -c '. "$1"; sort() { return 1; }; surface_plan_emit "$2" claude' _ \
    "$PLANNER" "$PAYLOAD"
  [ "$status" -eq 4 ]
  [[ "$output" == *"could not sort immutable source candidates"* ]] || { echo "$output"; false; }
}

@test "payload symlink escapes and internal symlink collisions fail before a plan is emitted" {
  external_skill="$SANDBOX/external-skill"
  mkdir -p "$external_skill"
  printf '# external\n' > "$external_skill/SKILL.md"
  rm -rf "$PAYLOAD/core-rules/skills/clarify"
  ln -s "$external_skill" "$PAYLOAD/core-rules/skills/clarify"

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"source symlink escapes immutable payload"* ]] || { echo "$output"; false; }

  rm "$PAYLOAD/core-rules/skills/clarify"
  ln -s "spec" "$PAYLOAD/core-rules/skills/clarify"

  run_plan --harness claude
  [ "$status" -eq 4 ]
  [[ "$output" == *"source symlink collision inside immutable payload"* ]] || { echo "$output"; false; }
}
