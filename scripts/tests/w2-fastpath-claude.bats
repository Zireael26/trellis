#!/usr/bin/env bats
# Donor fast-path project-file semantics must match the authoritative planner.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture
load helpers/native-render-fixture

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-fastpath.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" GIT_CONFIG_NOSYSTEM=1 TRELLIS_ATTACH_POSTJOB=off
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  mkdir -p "$SANDBOX/source/core-rules/templates" "$SANDBOX/source/core-rules/githooks" "$SANDBOX/source/scripts"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  mkdir -p "$SANDBOX/source/core-rules/legacy-hooks"
  cp -R "$REPO_ROOT/core-rules/legacy-hooks/." "$SANDBOX/source/core-rules/legacy-hooks/"
  # Legacy-shaped templates keep the substitution route covered; the T34B
  # native cases render native registrations (T34 option B).
  cp "$REPO_ROOT/core-rules/legacy-hooks/claude-settings.local.json" "$SANDBOX/source/core-rules/templates/"
  cp "$REPO_ROOT/core-rules/legacy-hooks/codex-hooks.local.json" "$SANDBOX/source/core-rules/templates/"
  if [[ "$BATS_TEST_DESCRIPTION" == 'T34B native'* ]]; then
    native_render_fixture_source "$SANDBOX/source"
  fi
  cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/source/scripts/lib"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$REPO_ROOT/scripts/trellis-launcher.sh" "$SANDBOX/source/scripts/"
  printf '# fallback policy\n' > "$SANDBOX/source/core-rules/CLAUDE.md"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/source/core-rules/githooks/pre-push"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$SANDBOX/source/core-rules/githooks/pre-push" "$SANDBOX/source/scripts/seed-inheritance-symlinks.sh"
  printf '1.2.3\n' > "$SANDBOX/source/core-rules/VERSION"
  printf '%s\n' '{"schema_version":1,"harnesses":{"claude":{"links":[{"source":"core-rules/CLAUDE.md","destination":".claude/rules/trellis.md"}],"render":[{"template":"core-rules/templates/claude-settings.local.json","destination":".claude/settings.local.json","merge":"explicit-json","mode":"0600","required":true}]},"codex":{"links":[{"project_target":"CLAUDE.md","fallback_source":"core-rules/CLAUDE.md","destination":"AGENTS.md"}],"render":[{"template":"core-rules/templates/codex-hooks.local.json","destination":".codex/hooks.json","merge":"explicit-json","mode":"0600","required":true}]}}}' > "$SANDBOX/source/core-rules/inheritance-manifest.json"
  if [[ "$BATS_TEST_DESCRIPTION" == *'expanded-skill validation'* ]]; then
    mkdir -p "$SANDBOX/source/core-rules/user/foo"
    printf 'fixture skill\n' > "$SANDBOX/source/core-rules/user/foo/SKILL.md"
    jq '.harnesses.user = {links:[{source_children:"core-rules/user",destination_dir:".agents/skills",entry_type:"directory",destination_home:true},{source:"core-rules/user/foo",destination:".pi/agent/skills/foo",destination_home:true}],render:[]}' \
      "$SANDBOX/source/core-rules/inheritance-manifest.json" > "$SANDBOX/manifest.next"
    mv "$SANDBOX/manifest.next" "$SANDBOX/source/core-rules/inheritance-manifest.json"
  fi
  release_fixture_install "$HOME" "$TRELLIS_HOME" 1.2.3 "$SANDBOX/source"
  PROJECT="$SANDBOX/project" TARGET="$SANDBOX/target"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"fast-claude"}\n' > "$PROJECT/.trellis.json"
  printf '# project policy\n' > "$PROJECT/CLAUDE.md"
  git -C "$PROJECT" add .trellis.json CLAUDE.md
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  if [[ "$BATS_TEST_DESCRIPTION" == *'expanded-skill validation'* ]]; then
    run bash "$REPO_ROOT/scripts/lib/surface-plan.sh" --payload "$TRELLIS_HOME/releases/1.2.3/payload" --harness codex
    [ "$status" -eq 4 ] || { echo "fixture must violate expanded-skill validation: $output"; return 1; }
    # A donor published by older code can exist for a now-invalid manifest.
    bash -c '. "$1"; surface_plan_validate_expanded_skills() { :; }; attach_cmd_attach --home "$2" --fleet personal --release 1.2.3 "$3"' \
      _ "$ATTACH" "$TRELLIS_HOME" "$PROJECT"
  else
    "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$PROJECT"
  fi
  git -C "$PROJECT" worktree add -q -b target "$TARGET"
}

teardown() {
  python3 -I - "$SANDBOX" <<'PY'
import os, shutil, sys
for root, dirs, files in os.walk(sys.argv[1]):
    os.chmod(root, 0o700)
    for name in files:
        path = os.path.join(root, name)
        if not os.path.islink(path):
            os.chmod(path, 0o600)
shutil.rmtree(sys.argv[1])
PY
}

@test "symlinked target CLAUDE uses full planner fallback rather than donor fast path" {
  mv "$TARGET/CLAUDE.md" "$TARGET/project-policy.md"
  ln -s project-policy.md "$TARGET/CLAUDE.md"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'donor fast path'* ]] || { echo "symlink took fast path: $output"; false; }
  [ "$(readlink "$TARGET/AGENTS.md")" = '.trellis/runtime/core-rules/CLAUDE.md' ]
}

@test "regular target and donor CLAUDE files retain the fast path" {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'donor fast path'* ]] || { echo "$output"; false; }
  [ "$(readlink "$TARGET/AGENTS.md")" = 'CLAUDE.md' ]
}

@test "donor fast path cannot bypass expanded-skill validation" {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 4 ] || { echo "invalid expanded skills allowed: $output"; false; }
  [ ! -e "$TARGET/.trellis/runtime" ]
  [ ! -L "$TARGET/.trellis/runtime" ]
}

@test "T34B native regular target and donor CLAUDE files retain the fast path with the target's render" {
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'attached (donor fast path):'* ]] || { echo "$output"; false; }
  [ "$(readlink "$TARGET/AGENTS.md")" = 'CLAUDE.md' ]
  for file in .claude/settings.local.json .codex/hooks.json; do
    native_render_fixture_strings "$TARGET/$file" | grep -qF "$NATIVE_COMPANION"
    native_render_fixture_strings "$TARGET/$file" | grep -qF "$TARGET"
    ! native_render_fixture_strings "$TARGET/$file" | grep -qF "$PROJECT"
  done
}

@test "T34B native symlinked target CLAUDE uses the full planner rather than the donor fast path" {
  mv "$TARGET/CLAUDE.md" "$TARGET/project-policy.md"
  ln -s project-policy.md "$TARGET/CLAUDE.md"
  run "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$TARGET"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'attached (donor fast path)'* ]] || { echo "symlink took fast path: $output"; false; }
  [ "$(readlink "$TARGET/AGENTS.md")" = '.trellis/runtime/core-rules/CLAUDE.md' ]
  native_render_fixture_strings "$TARGET/.claude/settings.local.json" | grep -qF "$TARGET"
}
