#!/usr/bin/env bats

# T25 integration coverage intentionally uses only the public attachment CLI and
# an installed local fixture release.  It does not source transaction internals.
#
# Two bats-on-Bash-3.2 traps shape the assertion style here: a non-terminal
# `[[ ]]` and a `!`-prefixed command are both vacuous, so substring checks go
# through t25_contains/t25_lacks and negative checks through `[ ! -e ]` or an
# explicit `if ...; then false; fi`.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture
load helpers/t25-portable

setup() {
  t25_setup_attachment_fixture
}

teardown() {
  t25_teardown_sandbox
}

# Retirement reduced nine tests to eight; this helper regression restores nine,
# not the retired native OMP proof and not a new native Pi proof.
@test "harness selectors preserve schema 1 defaults select schema 2 and refuse malformed manifests before attach" {
  local manifest="$T25_SANDBOX/selector-manifest.json" command

  T25_MANIFEST="$manifest"
  printf '%s\n' '{"schema_version":1,"harnesses":{"claude":{},"codex":{}}}' > "$manifest"
  t25_harness_flags
  [ "${#T25_HARNESS_FLAGS[@]}" -eq 0 ]

  printf '%s\n' '{"schema_version":2,"harnesses":{"claude":{},"shared_agents":{},"codex":{},"pi":{}}}' > "$manifest"
  t25_harness_flags
  [ "${#T25_HARNESS_FLAGS[@]}" -eq 6 ]
  [ "${T25_HARNESS_FLAGS[*]}" = '--harness claude --harness codex --harness pi' ]

  # Observe the helper's command boundary, not a provider or fake attach result.
  t25_attachment_env() { printf 'unexpected attach call\n' > "$T25_SANDBOX/attach-called"; }
  printf '{malformed\n' > "$manifest"
  for command in t25_attach t25_attach_with_fault; do
    run "$command" 13
    [ "$status" -ne 0 ]
    [ ! -e "$T25_SANDBOX/attach-called" ]
  done
}

# A rolled-back attach is allowed to leave exactly two marks behind: the machine
# registry row for the discovered worktree, and the local exclude file hardened
# to 0600.  Everything else — bytes, modes, symlinks, hook wiring, attachment
# state — has to be indistinguishable from the pre-attach machine.
#
# Callers invoke this in an `||` context, which suspends `set -e` for the whole
# body, so every check carries its own `return 1`: without them the function
# would report only its last statement.
assert_rolled_back_to_baseline() {
  local project_baseline="$1" home_baseline="$2" exclude_baseline="$3"
  local hooks_baseline="$4" git_baseline="$5"
  local project_now="$T25_SANDBOX/rollback-project.now" home_now="$T25_SANDBOX/rollback-home.now"

  t25_snapshot_tree_without "$T25_PROJECT" "$project_now" './.git/info/exclude' || return 1
  t25_snapshot_tree_without "$T25_TRELLIS_HOME" "$home_now" './registry.json' || return 1
  cmp -s "$project_baseline" "$project_now" || { echo 'project bytes changed'; return 1; }
  cmp -s "$home_baseline" "$home_now" || { echo 'machine bytes changed'; return 1; }
  [ "$(t25_sha256_file "$T25_EXCLUDE")" = "$exclude_baseline" ] ||
    { echo 'exclude bytes changed'; return 1; }
  [ "$(t25_hooks_path "$T25_PROJECT")" = "$hooks_baseline" ] ||
    { echo 'core.hooksPath changed'; return 1; }
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_baseline" ] ||
    { echo 'Git status changed'; return 1; }
  t25_attachment_state_absent "$T25_PROJECT" || { echo 'attachment state survived'; return 1; }
  t25_path_absent "$T25_PROJECT/.trellis/runtime" || { echo 'runtime anchor survived'; return 1; }
  if [ -f "$T25_TRELLIS_HOME/registry.json" ]; then
    jq -e '[.. | objects | .attachment_id? // empty] | length == 0' \
      "$T25_TRELLIS_HOME/registry.json" >/dev/null ||
      { echo 'registry kept an attachment row'; return 1; }
  fi
}

# A project-owned symlink destination is NOT a collision — `attach_deferred_leaves`
# yields the leaf to the project and drops it from the surface set, so attach
# succeeds and the project's bytes are never claimed. Only `replace` renders and
# the runtime anchor are hard collisions; the next test covers those.
#
# This test asserted exit 3 until the project-authored-file deferral landed, and
# the assertion was never updated because this suite ran in neither
# .github/workflows/bats.yml nor scripts/run-tests.sh. The deferral is the
# deliberate, separately-tested contract — see the "attach defers a project-authored
# AGENTS.md regular file" test in attach-project.bats and the show-config deferral
# tests in doctor.bats. What this test adds over those is the three-harness
# integration view: two deferrals at once, one on the SHARED `.agents` leaf that
# both Codex and Pi consume and one on a Pi-private leaf, proving the deferral is
# a partial YIELD and not a partial attach — every leaf the plan still owns
# lands, and the exclude block covers those and only those.
@test "three-harness late shared-agents and Pi destinations defer to the project without claiming a byte" {
  local shared_before pi_before shared_after pi_after owner git_before

  mkdir -p "$T25_PROJECT/.agents/rules" "$T25_PROJECT/.pi/hooks"
  # Both bodies are non-empty and match no canonical source, which is what makes
  # them authored content rather than a dropping — the narrow condition
  # `_attachment_symlink_destination_authored` requires before deferring.
  printf 'project-owned shared agents destination\n' > "$T25_PROJECT/.agents/rules/trellis.md"
  printf 'project-owned Pi destination\n' > "$T25_PROJECT/.pi/hooks/dispatch.sh"
  chmod 640 "$T25_PROJECT/.agents/rules/trellis.md"
  chmod 600 "$T25_PROJECT/.pi/hooks/dispatch.sh"
  printf '# collision sentinel\n*.must-remain\n' > "$T25_EXCLUDE"
  chmod 640 "$T25_EXCLUDE"

  shared_before="$(t25_sha256_file "$T25_PROJECT/.agents/rules/trellis.md")"
  pi_before="$(t25_sha256_file "$T25_PROJECT/.pi/hooks/dispatch.sh")"
  git_before="$(t25_git_status "$T25_PROJECT")"

  run t25_attach

  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # The rest of the three-harness surface still attached. Without this the whole
  # test would pass over an attach that yielded everything.
  owner="$(t25_owner_path "$T25_PROJECT")"
  [ -L "$T25_PROJECT/.trellis/runtime" ] || { echo "$output"; false; }
  [ -L "$T25_PROJECT/.claude/rules/trellis.md" ] || { echo "$output"; false; }
  [ -L "$T25_PROJECT/.codex/hooks/fixture-hook.sh" ] || { echo "$output"; false; }
  [ -f "$T25_PROJECT/.pi/fixture-policy.md" ] || { echo "$output"; false; }
  jq -e '.status == "committed"' "$owner" >/dev/null || { jq -cS '.status' "$owner"; false; }

  # Both destinations stay project-owned regular files: same bytes, same mode,
  # never replaced by a Trellis symlink.
  [ -f "$T25_PROJECT/.agents/rules/trellis.md" ] || { echo 'shared leaf is not a regular file'; false; }
  [ ! -L "$T25_PROJECT/.agents/rules/trellis.md" ] || { echo 'shared leaf became a symlink'; false; }
  [ -f "$T25_PROJECT/.pi/hooks/dispatch.sh" ] || { echo 'pi leaf is not a regular file'; false; }
  [ ! -L "$T25_PROJECT/.pi/hooks/dispatch.sh" ] || { echo 'pi leaf became a symlink'; false; }
  shared_after="$(t25_sha256_file "$T25_PROJECT/.agents/rules/trellis.md")"
  pi_after="$(t25_sha256_file "$T25_PROJECT/.pi/hooks/dispatch.sh")"
  [ "$shared_after" = "$shared_before" ] || { echo 'shared destination bytes changed'; false; }
  [ "$pi_after" = "$pi_before" ] || { echo 'pi destination bytes changed'; false; }
  [ "$(t25_mode "$T25_PROJECT/.agents/rules/trellis.md")" = 640 ] ||
    { echo "shared destination mode is $(t25_mode "$T25_PROJECT/.agents/rules/trellis.md")"; false; }
  [ "$(t25_mode "$T25_PROJECT/.pi/hooks/dispatch.sh")" = 600 ] ||
    { echo "pi destination mode is $(t25_mode "$T25_PROJECT/.pi/hooks/dispatch.sh")"; false; }

  # The owner record names both deferrals and claims neither as an artifact.
  jq -e '
    ([.pre_existing[] | select(.path == ".agents/rules/trellis.md" or .path == ".pi/hooks/dispatch.sh")
      | {path, kind, reason}] | sort_by(.path)
      == [{path:".agents/rules/trellis.md",kind:"symlink",reason:"project-authored-file"},
          {path:".pi/hooks/dispatch.sh",kind:"symlink",reason:"project-authored-file"}])
    and ([.artifacts[].path
          | select(. == ".agents/rules/trellis.md" or . == ".pi/hooks/dispatch.sh")] | length) == 0
  ' "$owner" >/dev/null || { jq -cS '{pre_existing,artifacts:[.artifacts[].path]}' "$owner"; false; }

  # A deferred leaf gets no managed exclude line at all. The claude leaf is the
  # positive control: it proves the block was written, so the two absence checks
  # below cannot pass because the block is simply missing.
  run grep -Fx '/.claude/rules/trellis.md' "$T25_EXCLUDE"
  [ "$status" -eq 0 ] || { cat "$T25_EXCLUDE"; false; }
  run grep -Fx '/.agents/rules/trellis.md' "$T25_EXCLUDE"
  [ "$status" -ne 0 ] || { cat "$T25_EXCLUDE"; false; }
  run grep -Fx '/.pi/hooks/dispatch.sh' "$T25_EXCLUDE"
  [ "$status" -ne 0 ] || { cat "$T25_EXCLUDE"; false; }
  # The operator's own pre-existing sentinel lines survive verbatim.
  run grep -Fx '*.must-remain' "$T25_EXCLUDE"
  [ "$status" -eq 0 ] || { cat "$T25_EXCLUDE"; false; }

  # Neither deferred file was dirtied, and neither was hidden by an exclude that
  # would have made a tracked file look untracked.
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ] ||
    { echo "git status drifted: $(t25_git_status "$T25_PROJECT")"; false; }
}

@test "project-owned replace render and runtime anchor collisions refuse before any write" {
  local project_before="$T25_SANDBOX/render-collision-project.before"
  local home_before="$T25_SANDBOX/render-collision-home.before"
  local project_after="$T25_SANDBOX/render-collision-project.after"
  local home_after="$T25_SANDBOX/render-collision-home.after"
  local git_before

  # A fully release-owned `replace` render, not one of the merge destinations
  # the project already owns: nothing may claim it from underneath the project.
  # It is Pi-owned and deliberately NOT the shared `.agents` leaf, so a refusal
  # here is provably a Pi collision rather than a shared-leaf collision.
  printf 'project-owned pi policy\n' > "$T25_PROJECT/.pi/fixture-policy.md"
  chmod 644 "$T25_PROJECT/.pi/fixture-policy.md"
  git_before="$(t25_git_status "$T25_PROJECT")"
  t25_snapshot_tree "$T25_PROJECT" "$project_before"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_before"

  run t25_attach

  [ "$status" -eq 3 ]
  t25_snapshot_tree "$T25_PROJECT" "$project_after"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_after"
  cmp -s "$project_before" "$project_after"
  cmp -s "$home_before" "$home_after"
  t25_attachment_state_absent "$T25_PROJECT"
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ]

  rm "$T25_PROJECT/.pi/fixture-policy.md"
  mkdir "$T25_PROJECT/.trellis"
  printf 'project-owned runtime anchor\n' > "$T25_PROJECT/.trellis/runtime"
  chmod 600 "$T25_PROJECT/.trellis/runtime"
  git_before="$(t25_git_status "$T25_PROJECT")"
  t25_snapshot_tree "$T25_PROJECT" "$project_before"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_before"

  run t25_attach

  [ "$status" -eq 3 ]
  t25_snapshot_tree "$T25_PROJECT" "$project_after"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_after"
  cmp -s "$project_before" "$project_after"
  cmp -s "$home_before" "$home_after"
  [ ! -L "$T25_PROJECT/.trellis/runtime" ]
  [ "$(cat "$T25_PROJECT/.trellis/runtime")" = 'project-owned runtime anchor' ]
  t25_attachment_state_absent "$T25_PROJECT"
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ]
}

@test "attach expands exactly the three-harness surface set the release manifest declares" {
  local destination source mode expected actual harnesses

  run t25_attach

  [ "$status" -eq 0 ]
  harnesses="$(jq -r '.harnesses | keys_unsorted | sort | join(",")' "$T25_MANIFEST")"
  [ "$harnesses" = 'claude,codex,pi,shared_agents' ]

  # Every declared link is a symlink to the pinned immutable payload source.
  while IFS= read -r destination; do
    [ -L "$T25_PROJECT/$destination" ]
    source="$(t25_manifest_link_source "$destination")"
    [ "$(t25_resolve_link_target "$T25_PROJECT/$destination")" = "$T25_PAYLOAD/$source" ]
  done < <(t25_manifest_destinations links)

  # Every declared render is a regular file at the declared mode.
  while IFS= read -r destination; do
    [ -f "$T25_PROJECT/$destination" ]
    [ ! -L "$T25_PROJECT/$destination" ]
    mode="$(t25_manifest_render_mode "$destination")"
    [ "0$(t25_mode "$T25_PROJECT/$destination")" = "$mode" ]
  done < <(t25_manifest_destinations render)

  # And the owner claims exactly that set — no extra surface, none missing.
  expected="$(printf '.trellis/runtime\n'; t25_manifest_destinations links)"
  actual="$(t25_owner_artifact_paths symlink)"
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort)" = "$actual" ]
  expected="$(t25_manifest_destinations render)"
  actual="$(t25_owner_artifact_paths file)"
  [ "$expected" = "$actual" ]

  # The pinned SessionStart renders name the fixture launcher and home, never a
  # placeholder and never an ambient variable.
  jq -e --arg launcher "$T25_LAUNCHER" --arg home "$T25_TRELLIS_HOME" --arg user "$T25_USER_HOME" '
    [.hooks.SessionStart[].hooks[].command] as $commands
    | ($commands | length) == 4
    and all($commands[];
      contains($launcher) and contains($home) and contains($user)
      and (contains("__TRELLIS_") | not)
      and (contains("$HOME") | not))
  ' "$T25_PROJECT/.claude/settings.local.json" >/dev/null
  jq -e --arg launcher "$T25_LAUNCHER" '
    [.hooks.SessionStart[].hooks[].command] as $commands
    | ($commands | length) == 3 and all($commands[]; contains($launcher))
  ' "$T25_PROJECT/.codex/hooks.json" >/dev/null

  # The project keeps its own keys in both merge destinations.
  jq -e '.project.claude == "keep"' "$T25_PROJECT/.claude/settings.local.json" >/dev/null
  jq -e '.project.codex == "keep"' "$T25_PROJECT/.codex/hooks.json" >/dev/null
  [ -z "$(t25_git_status "$T25_PROJECT")" ]
}

# RETIRED, NOT MIGRATED: @test "OMP project policy takes effect and clean detach
# removes it" (with its `t25_omp_config_get` helper) covered a host-gated LIVE
# `omp config get` precedence proof — that an attached project's rendered
# `.omp/config.yml` overrode the user-level OMP config, and that a clean detach
# restored the user values. Both the OMP attachment plane and the OMP CLI are
# gone (1b2189e4 "refactor(surface): retire omp attachment plane"), so the
# requirement is retired with the harness. It is deliberately NOT renamed into a
# Pi equivalent: this fixture establishes no equivalent native Pi
# config-precedence assertion, so renaming it would invent unobserved proof.

@test "second three-harness attach rewrites no project machine or artifact byte" {
  local project_first="$T25_SANDBOX/idempotent-project.first"
  local home_first="$T25_SANDBOX/idempotent-home.first"
  local project_second="$T25_SANDBOX/idempotent-project.second"
  local home_second="$T25_SANDBOX/idempotent-home.second"
  local owner exclude_first owner_first artifacts_first

  run t25_attach

  [ "$status" -eq 0 ]
  owner="$(t25_owner_path "$T25_PROJECT")"
  exclude_first="$(t25_sha256_file "$T25_EXCLUDE")"
  owner_first="$(t25_sha256_file "$owner")"
  artifacts_first="$(t25_owner_artifact_paths any)"
  t25_snapshot_tree "$T25_PROJECT" "$project_first"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_first"
  jq -e '.status == "committed"' "$owner" >/dev/null

  run t25_attach

  [ "$status" -eq 0 ]
  t25_contains "$output" 'already attached'
  t25_snapshot_tree "$T25_PROJECT" "$project_second"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_second"
  # The tree snapshots carry every artifact hash, the owner status row, the
  # journal directory and the exclude bytes, so this is the byte comparison for
  # all four at once; the explicit checks below name them for failure output.
  cmp -s "$project_first" "$project_second"
  cmp -s "$home_first" "$home_second"
  [ "$(t25_sha256_file "$T25_EXCLUDE")" = "$exclude_first" ]
  [ "$(t25_sha256_file "$owner")" = "$owner_first" ]
  [ "$(t25_owner_artifact_paths any)" = "$artifacts_first" ]
  jq -e '.status == "committed"' "$owner" >/dev/null
  [ -z "$(t25_journal_files)" ]
  [ -z "$(t25_git_status "$T25_PROJECT")" ]
}

@test "every numbered attach transaction phase rolls back to identical bytes" {
  local phase faulted project_baseline home_baseline exclude_baseline hooks_baseline git_baseline
  local settings_baseline hooks_json_baseline registry_baseline registry_now

  project_baseline="$T25_SANDBOX/sweep-project.baseline"
  home_baseline="$T25_SANDBOX/sweep-home.baseline"
  t25_snapshot_tree_without "$T25_PROJECT" "$project_baseline" './.git/info/exclude'
  t25_snapshot_tree_without "$T25_TRELLIS_HOME" "$home_baseline" './registry.json'
  exclude_baseline="$(t25_sha256_file "$T25_EXCLUDE")"
  hooks_baseline="$(t25_hooks_path "$T25_PROJECT")"
  git_baseline="$(t25_git_status "$T25_PROJECT")"
  settings_baseline="$(t25_sha256_file "$T25_PROJECT/.claude/settings.local.json")"
  hooks_json_baseline="$(t25_sha256_file "$T25_PROJECT/.codex/hooks.json")"

  # MACHINE-REGISTRY STABILITY ACROSS ITERATIONS.
  #
  # `registry.json` is projected out of the home snapshot above because it has
  # ONE legitimate delta over this sweep: absent before any attach ran, present
  # afterwards. That projection is what a leak would hide, because it removes
  # the file from the byte comparison entirely and leaves only the semantic
  # "no attachment_id survived" check in `assert_rolled_back_to_baseline` — which
  # passes over a registry that grew an unavailable root, a stale checkout map,
  # or a duplicated project row on every faulted phase.
  #
  # So the one allowed delta is spent exactly once. The first faulted phase
  # records the file's bytes; every phase after it must be byte-identical to
  # that. Rollback either restores the registry or it does not, and a rollback
  # that leaks a little on each pass now goes red on the second pass.
  registry_baseline=''
  registry_now="$T25_SANDBOX/sweep-registry.now"

  # The plan length is not known until an attach commits, so the sweep walks
  # phase indexes until one runs past the plan and commits instead of faulting.
  # Every index before that has to fault and roll back to the same bytes.
  phase=1
  faulted=0
  while [ "$phase" -le 32 ]; do
    run t25_attach_with_fault "$phase"

    [ "$status" -eq 5 ] || break
    assert_rolled_back_to_baseline "$project_baseline" "$home_baseline" \
      "$exclude_baseline" "$hooks_baseline" "$git_baseline" ||
      { echo "phase $phase left state behind"; false; }
    # The two project-owned merge destinations are the user bytes a partial
    # render is most likely to eat, so they are named separately.
    [ "$(t25_sha256_file "$T25_PROJECT/.claude/settings.local.json")" = "$settings_baseline" ] ||
      { echo "phase $phase rewrote the project Claude settings"; false; }
    [ "$(t25_sha256_file "$T25_PROJECT/.codex/hooks.json")" = "$hooks_json_baseline" ] ||
      { echo "phase $phase rewrote the project Codex hooks"; false; }

    # Byte-compare the registry against the first faulted phase. `absent` is a
    # legitimate first value, so it is captured the same way any other value is
    # and must then hold for the rest of the sweep.
    t25_snapshot_optional_file "$T25_TRELLIS_HOME/registry.json" "$registry_now"
    if [ -z "$registry_baseline" ]; then
      registry_baseline="$T25_SANDBOX/sweep-registry.baseline"
      cp "$registry_now" "$registry_baseline"
    else
      cmp -s "$registry_baseline" "$registry_now" || {
        echo "phase $phase changed the machine registry relative to the first faulted phase"
        echo "expected: $(cat "$registry_baseline")"
        echo "actual:   $(cat "$registry_now")"
        false
      }
    fi

    faulted=$((faulted + 1))
    phase=$((phase + 1))
  done

  # The first index past the plan is a clean attach, and the plan it committed
  # is exactly as long as the run of phases that faulted.
  [ "$status" -eq 0 ] || { echo "phase $phase exited $status: $output"; false; }
  [ "$faulted" -eq "$(t25_owner_artifact_count)" ]
  # Adding a fixture artifact must also update the late-fault index below.
  [ "$faulted" -eq 13 ]
  [ "$faulted" -ge 8 ]
  [ -L "$T25_PROJECT/.trellis/runtime" ]
  [ -z "$(t25_git_status "$T25_PROJECT")" ]
}

@test "late attachment fault rolls back project-owned render bytes modes hooks and excludes" {
  local project_baseline="$T25_SANDBOX/fault-project.baseline"
  local home_baseline="$T25_SANDBOX/fault-home.baseline"
  local exclude_baseline hooks_baseline git_baseline

  hooks_baseline="$(t25_hooks_path "$T25_PROJECT")"
  git_baseline="$(t25_git_status "$T25_PROJECT")"
  exclude_baseline="$(t25_sha256_file "$T25_EXCLUDE")"
  t25_snapshot_tree_without "$T25_PROJECT" "$project_baseline" './.git/info/exclude'
  t25_snapshot_tree_without "$T25_TRELLIS_HOME" "$home_baseline" './registry.json'

  # This fixture plans five missing parents, the runtime anchor, four harness
  # leaves and three renders — thirteen phases, which the sweep above proves is
  # the whole plan.  Phase 13 is therefore the LAST one, so it fails after both
  # project-owned explicit-JSON merge destinations have already been replaced.
  run t25_attach_with_fault 13

  [ "$status" -eq 5 ]
  assert_rolled_back_to_baseline "$project_baseline" "$home_baseline" \
    "$exclude_baseline" "$hooks_baseline" "$git_baseline"
  t25_path_absent "$T25_PROJECT/.claude/rules/trellis.md"
  t25_path_absent "$T25_PROJECT/.agents/rules/trellis.md"
  t25_path_absent "$T25_PROJECT/.codex/hooks/fixture-hook.sh"
  t25_path_absent "$T25_PROJECT/.pi/hooks/dispatch.sh"
  t25_path_absent "$T25_PROJECT/.pi/fixture-policy.md"
  jq -e '.project.claude == "keep" and (has("hooks") | not)' \
    "$T25_PROJECT/.claude/settings.local.json" >/dev/null
  jq -e '.project.codex == "keep" and (has("hooks") | not)' \
    "$T25_PROJECT/.codex/hooks.json" >/dev/null
}

@test "full three-harness detach restores project-owned state and is byte-idempotent" {
  project_before="$T25_SANDBOX/detach-project.before"
  project_after_first="$T25_SANDBOX/detach-project.after-first"
  project_after_second="$T25_SANDBOX/detach-project.after-second"
  home_after_first="$T25_SANDBOX/detach-home.after-first"
  home_after_second="$T25_SANDBOX/detach-home.after-second"
  hooks_before="$(t25_hooks_path "$T25_PROJECT")"
  git_before="$(t25_git_status "$T25_PROJECT")"
  exclude_before="$(t25_sha256_file "$T25_EXCLUDE")"
  # Detach currently keeps the empty harness parents its attach created and
  # leaves the local exclude file hardened to 0600.  Both are asserted by name
  # below; project-owned bytes, modes and symlinks are compared exactly.
  t25_snapshot_tree_without "$T25_PROJECT" "$project_before" \
    './.git/info/exclude' './.claude/rules' './.agents/rules' './.codex/hooks' \
    './.pi/hooks' './.trellis'

  run t25_attach

  [ "$status" -eq 0 ]
  [ -L "$T25_PROJECT/.claude/rules/trellis.md" ]
  [ -L "$T25_PROJECT/.agents/rules/trellis.md" ]
  [ -L "$T25_PROJECT/.codex/hooks/fixture-hook.sh" ]
  [ -L "$T25_PROJECT/.pi/hooks/dispatch.sh" ]
  [ -f "$T25_PROJECT/.pi/fixture-policy.md" ]
  jq -e '.project.claude == "keep" and (.hooks.SessionStart | length) == 1' \
    "$T25_PROJECT/.claude/settings.local.json" >/dev/null
  jq -e '.project.codex == "keep" and (.hooks.SessionStart | length) == 1' \
    "$T25_PROJECT/.codex/hooks.json" >/dev/null
  [ -f "$(t25_owner_path "$T25_PROJECT")" ]
  [ -z "$(t25_git_status "$T25_PROJECT")" ]

  run t25_detach

  [ "$status" -eq 0 ]
  t25_snapshot_tree_without "$T25_PROJECT" "$project_after_first" \
    './.git/info/exclude' './.claude/rules' './.agents/rules' './.codex/hooks' \
    './.pi/hooks' './.trellis'
  cmp -s "$project_before" "$project_after_first"
  [ "$(t25_sha256_file "$T25_EXCLUDE")" = "$exclude_before" ]
  [ "$(t25_hooks_path "$T25_PROJECT")" = "$hooks_before" ]
  t25_attachment_state_absent "$T25_PROJECT"
  t25_path_absent "$T25_PROJECT/.trellis/runtime"
  t25_path_absent "$T25_PROJECT/.claude/rules/trellis.md"
  t25_path_absent "$T25_PROJECT/.agents/rules/trellis.md"
  t25_path_absent "$T25_PROJECT/.codex/hooks/fixture-hook.sh"
  t25_path_absent "$T25_PROJECT/.pi/hooks/dispatch.sh"
  t25_path_absent "$T25_PROJECT/.pi/fixture-policy.md"
  # FOLLOW-UP: inverse cleanup stops at the leaves — the parents attach created
  # survive detach as empty directories.  Asserting emptiness keeps the residue
  # bounded and makes a future full inverse cleanup fail here on purpose.
  t25_directory_is_empty "$T25_PROJECT/.claude/rules"
  t25_directory_is_empty "$T25_PROJECT/.agents/rules"
  t25_directory_is_empty "$T25_PROJECT/.codex/hooks"
  t25_directory_is_empty "$T25_PROJECT/.pi/hooks"
  t25_directory_is_empty "$T25_PROJECT/.trellis"
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ]
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_after_first"

  run t25_detach

  [ "$status" -eq 0 ]
  t25_snapshot_tree "$T25_PROJECT" "$project_after_second"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$home_after_second"
  cmp -s "$project_after_first.full" "$project_after_second"
  cmp -s "$home_after_first" "$home_after_second"
  [ "$(t25_git_status "$T25_PROJECT")" = "$git_before" ]
}

@test "detach refuses a modified owned render and leaves every project and machine byte" {
  local attached_project="$T25_SANDBOX/refuse-project.attached"
  local attached_home="$T25_SANDBOX/refuse-home.attached"
  local after_project="$T25_SANDBOX/refuse-project.after"
  local after_home="$T25_SANDBOX/refuse-home.after"
  local owner

  run t25_attach
  [ "$status" -eq 0 ]
  owner="$(t25_owner_path "$T25_PROJECT")"

  # `.pi/fixture-policy.md` is a fully owned `replace` render, so any local edit
  # is drift the inverse transaction must refuse rather than overwrite.
  printf 'locally edited owned render\n' > "$T25_PROJECT/.pi/fixture-policy.md"
  t25_snapshot_tree "$T25_PROJECT" "$attached_project"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$attached_home"

  run t25_detach

  [ "$status" -eq 3 ]
  t25_snapshot_tree "$T25_PROJECT" "$after_project"
  t25_snapshot_tree "$T25_TRELLIS_HOME" "$after_home"
  cmp -s "$attached_project" "$after_project"
  cmp -s "$attached_home" "$after_home"
  [ -f "$owner" ]
  [ -L "$T25_PROJECT/.trellis/runtime" ]
  [ -L "$T25_PROJECT/.claude/rules/trellis.md" ]
  [ "$(cat "$T25_PROJECT/.pi/fixture-policy.md")" = 'locally edited owned render' ]
  [ -z "$(t25_journal_files)" ]
}
