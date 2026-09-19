#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
TRELLIS="$REPO/scripts/trellis"
MATERIALIZER="$REPO/scripts/materialize-scheduled-task.sh"
REGISTRY_LIB="$REPO/scripts/lib/local-registry.sh"
RELEASE_STORE_LIB="$REPO/scripts/lib/release-store.sh"

setup() {
  # A bare `mktemp -d` ignores TMPDIR on Darwin and lands outside a fenced
  # run's writable root. Template it explicitly under the per-test directory.
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/scheduled-task-contracts.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME_FIX="$SANDBOX/trellis-home"
  RELEASE_REPO="$SANDBOX/release-source"
  mkdir -p "$TRELLIS_HOME_FIX" "$SANDBOX/source" "$SANDBOX/personal" "$SANDBOX/work"
  write_machine_config
  build_release_repo
  install_fixture_release
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

write_machine_config() {
  cat > "$TRELLIS_HOME_FIX/config.json" <<EOF
{"schema_version":1,"source_root":"$SANDBOX/source","release_remote":"$RELEASE_REPO","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX/personal"]},"work":{"discovery_roots":["$SANDBOX/work"]}}}
EOF
  chmod 600 "$TRELLIS_HOME_FIX/config.json"
}

# A ready lane task publishes only when the pinned release actually carries the
# collector, so every fixture release ships the tracked runner with the tracked
# executable mode. `git` records 100755 from the exec bit, which is the mode the
# materializer must admit for this one asset while templates stay 100644.
install_lane_runner() {
  local repo="$1"
  mkdir -p "$repo/scripts"
  cp "$REPO/scripts/lane-freshness.py" "$repo/scripts/lane-freshness.py"
  chmod 755 "$repo/scripts/lane-freshness.py"
}

build_release_repo() {
  mkdir -p "$RELEASE_REPO/core-rules"
  cp -R "$REPO/scheduled-tasks" "$RELEASE_REPO/scheduled-tasks"
  cp "$REPO/trellis.config.json" "$RELEASE_REPO/trellis.config.json"
  install_lane_runner "$RELEASE_REPO"
  printf '%s\n' '1.2.3' > "$RELEASE_REPO/core-rules/VERSION"
  (
    cd "$RELEASE_REPO" || exit 1
    git init -q -b main
    git config user.email materializer@example.invalid
    git config user.name Materializer
    git add .
    git commit -q -m fixture
    git tag -a v1.2.3 -m fixture
  )
  # The executable mode is the point of the baseline fixture; a 100644 runner
  # here would make the mode-strictness assertions vacuous.
  [ "$(git -C "$RELEASE_REPO" ls-files -s scripts/lane-freshness.py | awk '{print $1}')" = 100755 ]
}

install_fixture_release() {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" ""' \
    _ "$RELEASE_STORE_LIB" 1.2.3 "$RELEASE_REPO"
  [ "$status" -eq 0 ]
}

# A second fixture release whose lane-freshness assets are deliberately wrong,
# installed and activated so the refusal is reached through the real release
# path rather than by tampering with an already verified store.
install_variant_release() {
  local version="$1" defect="$2" repo="$SANDBOX/release-variant-$version"
  # Built from the tracked tree the same way `build_release_repo` builds the
  # baseline, never by copying an existing fixture checkout: copying one leaves
  # its `.git` behind and the next `git add` records a gitlink the release
  # store rejects as an unsupported tree entry.
  mkdir -p "$repo/core-rules"
  cp -R "$REPO/scheduled-tasks" "$repo/scheduled-tasks"
  cp "$REPO/trellis.config.json" "$repo/trellis.config.json"
  install_lane_runner "$repo"
  case "$defect" in
    unknown-placeholder)
      printf '%s\n' 'Cache {{LANE_UNKNOWN}} is not a rendered input.' \
        >> "$repo/scheduled-tasks/lane-freshness/prompt.md"
      ;;
    missing-targets)
      rm -f "$repo/scheduled-tasks/lane-freshness/targets.md"
      ;;
    missing-runner)
      rm -f "$repo/scripts/lane-freshness.py"
      ;;
  esac
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email materializer@example.invalid
    git config user.name Materializer
    git add -A
    git commit -q -m "fixture $defect"
    git tag -a "v$version" -m "fixture $defect"
  )
  # Every entry must be a blob; a gitlink here would fail the install for a
  # reason that has nothing to do with the defect under test.
  [ -z "$(git -C "$repo" ls-tree -r HEAD | awk '$2 != "blob"')" ] ||
    { git -C "$repo" ls-tree -r HEAD; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" ""' \
    _ "$RELEASE_STORE_LIB" "$version" "$repo"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq --arg version "$version" '.active_cli_release = $version' \
    "$TRELLIS_HOME_FIX/config.json" > "$TRELLIS_HOME_FIX/config.json.next"
  mv "$TRELLIS_HOME_FIX/config.json.next" "$TRELLIS_HOME_FIX/config.json"
  chmod 600 "$TRELLIS_HOME_FIX/config.json"
}

make_repo() {
  local path="$1" project_id="$2"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" config user.email materializer@example.invalid
  git -C "$path" config user.name Materializer
  printf '%s\n' '{"schema_version":1,"project_id":"'"$project_id"'"}' > "$path/.trellis.json"
  printf '%s\n' fixture > "$path/README"
  git -C "$path" add .
  git -C "$path" commit -q -m fixture
}

register_repo() {
  local fleet="$1" project_id="$2" path="$3" metadata="${4:-}"
  [ -n "$metadata" ] || metadata='{}'
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" "$2" "$3" "$4" "" "[]" "" "$5"' \
    _ "$REGISTRY_LIB" "$fleet" "$project_id" "$path" "$metadata"
  [ "$status" -eq 0 ]
}

record_unavailable() {
  local fleet="$1" project_id="$2" root="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" "$2" "$3" "$4" "{}"' \
    _ "$REGISTRY_LIB" "$fleet" "$project_id" "$root"
  [ "$status" -eq 0 ]
}

mark_detached() {
  local fleet="$1" project_id="$2" registry="$TRELLIS_HOME_FIX/registry.json"
  jq --arg key "$fleet/$project_id" '.projects[$key].status = "detached"' \
    "$registry" > "$registry.next"
  mv "$registry.next" "$registry"
  chmod 600 "$registry"
}

materialized_digest() {
  local root="$1"
  shasum -a 256 "$root/snapshot.json" "$root/prompt.md" "$root/targets.md" "$root/manifest.json" | shasum -a 256 | awk '{print $1}'
}
materialize_task() {
  local fleet="$1" task="$2"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$MATERIALIZER" materialize --home "$TRELLIS_HOME_FIX" --fleet "$fleet" "$task"
}


@test "materialize isolates personal and work task inputs" {
  local personal="$SANDBOX/personal/alpha checkout" work="$SANDBOX/work/beta checkout"
  make_repo "$personal" alpha
  make_repo "$work" beta
  register_repo personal alpha "$personal"
  register_repo work beta "$work"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  [ "$output" = "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest" ]

  materialize_task work daily-project-digest
  [ "$status" -eq 0 ]
  [ "$output" = "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest" ]

  [ "$(jq -r '.entries[0].project_id' "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/snapshot.json")" = alpha ]
  [ "$(jq -r '.entries[0].project_id' "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/snapshot.json")" = beta ]
  [ "$(grep -cF "$work" "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/snapshot.json")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/snapshot.json"; false; }
  [ "$(grep -cF "$personal" "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/snapshot.json")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/snapshot.json"; false; }
  [ "$(grep -cF "$work" "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/prompt.md")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/prompt.md"; false; }
  [ "$(grep -cF "$personal" "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/targets.md")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/targets.md"; false; }
  [ "$(grep -cF "$personal" "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/prompt.md")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/prompt.md"; false; }
  [ "$(grep -cF "$personal" "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/targets.md")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest/targets.md"; false; }
  [ "$(grep -cF "$work" "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/prompt.md")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/prompt.md"; false; }
  [ "$(grep -cF "$work" "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/targets.md")" -eq 0 ] || { cat "$TRELLIS_HOME_FIX/tasks/work/daily-project-digest/targets.md"; false; }
}

@test "trellis dispatches materialize arguments verbatim" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$TRELLIS" task materialize \
    --home "$TRELLIS_HOME_FIX" --fleet personal daily-project-digest
  [ "$status" -eq 0 ]
  [ "$output" = "$root" ]
}

@test "materialize is deterministic and replaces one task directory atomically" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  local first_digest
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  first_digest="$(materialized_digest "$root")"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  [ "$first_digest" = "$(materialized_digest "$root")" ]
  [ -d "$root" ]
  [ -z "$(find "$TRELLIS_HOME_FIX/tasks/personal" -maxdepth 1 -name '.daily-project-digest.tmp.*' -print)" ]
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ]
  [ "$(jq -r 'has("generated_at")' "$root/manifest.json")" = false ]
  [ -d "$root/output" ]
  [ "$(jq -r '.files.output' "$root/manifest.json")" = output ]
  [ "$(jq -r '.output.relative_path' "$root/manifest.json")" = output ]
  [ "$(jq -r '.output.root' "$root/manifest.json")" = "$root/output" ]
}

@test "rematerialization preserves prior private output across atomic generation replacement" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  printf '%s\n' preserved > "$root/output/evidence.txt"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  [ "$(cat "$root/output/evidence.txt")" = preserved ]
}

@test "post-commit prior-generation cleanup failure warns after publishing new task state and output" {
  local personal="$SANDBOX/personal/alpha"
  local second="$SANDBOX/personal/beta"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  printf '%s\n' preserved > "$root/output/evidence.txt"
  make_repo "$second" beta
  register_repo personal beta "$second"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" TRELLIS_TEST_TASK_PUBLISH_FAIL_OLD_CLEANUP=1 \
    "$MATERIALIZER" materialize --home "$TRELLIS_HOME_FIX" --fleet personal daily-project-digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"$root"* ]] || { echo "$output"; false; }
  [[ "$output" == *"published task; deferred cleanup of prior generation: injected prior generation cleanup failure"* ]] || { echo "$output"; false; }
  [ "$(jq -r '.snapshot.entry_count' "$root/manifest.json")" -eq 2 ]
  [ "$(cat "$root/output/evidence.txt")" = preserved ]
  [ -n "$(find "$TRELLIS_HOME_FIX/tasks/personal" -maxdepth 1 -name '.daily-project-digest.tmp.*' -print)" ]
}

@test "materialize rejects unsafe fleet and task names before reading local state" {
  materialize_task '../personal' daily-project-digest
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid fleet name"* ]] || { echo "$output"; false; }

  materialize_task personal '../daily-project-digest'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid task name"* ]] || { echo "$output"; false; }
}

# One offline volume must not take the rest of the fleet with it. `plan.md` §3.1
# says bulk commands print a per-project result and do not claim all-or-nothing
# fleet atomicity; before this contract landed, a single `unavailable` row drove
# 19 of 22 materialized tasks to `planned-error` and every prompt halted on it.
@test "an unavailable row is excluded per project and leaves the task ready" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  record_unavailable personal offline "$SANDBOX/missing/offline"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$root" ]
  # The row stays visible in the snapshot — excluded from the run, not erased.
  [ "$(jq '[.entries[] | select(.availability == "unavailable")] | length' "$root/snapshot.json")" -eq 1 ]
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ] || { cat "$root/manifest.json"; false; }
  [ "$(jq -c '.requirements.excluded_rows' "$root/manifest.json")" = \
    '[{"project_id":"offline","reason":"checkout unavailable in local registry snapshot"}]' ] ||
    { jq -c '.requirements' "$root/manifest.json"; false; }
  [ "$(jq -c '.requirements.planned_errors' "$root/manifest.json")" = '[]' ] ||
    { jq -c '.requirements' "$root/manifest.json"; false; }
  [[ "$output" == *"excluded row: offline: checkout unavailable"* ]] || { echo "$output"; false; }
  [[ "$output" != *"planned error"* ]] || { echo "$output"; false; }
  # The available project is still a target, which is the whole point.
  [ "$(jq '[.entries[] | select(.availability == "available")] | length' "$root/snapshot.json")" -eq 1 ]
}

# Pi is a first-class harness: the registry write path already admits pi
# rows, so the snapshot canonicalizer must accept them too. Before this
# contract landed, a single pi-attached row drove every materialized task to
# a canonicalization failure (exit 4) and no audit in the fleet could run.
@test "a pi-attached row materializes ready" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  jq '(.projects["personal/alpha"].checkouts[].harnesses) |= (if index("pi") then . else . + ["pi"] end)' \
    "$TRELLIS_HOME_FIX/registry.json" > "$TRELLIS_HOME_FIX/registry.json.next"
  mv "$TRELLIS_HOME_FIX/registry.json.next" "$TRELLIS_HOME_FIX/registry.json"
  chmod 600 "$TRELLIS_HOME_FIX/registry.json"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ] || { cat "$root/manifest.json"; false; }
  [ "$(jq -r '.entries[0].harnesses | index("pi") != null' "$root/snapshot.json")" = true ] || \
    { jq -c '.entries[0].harnesses' "$root/snapshot.json"; false; }
}

# The reserved case: no row the task could act on at all. That invalidates the
# whole run rather than one project, so it stays a planned error and exit 5.
@test "a fleet with no usable checkout at all is still a planned error" {
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  record_unavailable personal offline "$SANDBOX/missing/offline"

  materialize_task personal daily-project-digest
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = planned-error ] || { cat "$root/manifest.json"; false; }
  [[ "$output" == *"no eligible active checkout targets"* ]] || { echo "$output"; false; }
}

@test "AEO materialization refuses missing local URL and marker metadata" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/aeo-baseline"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal aeo-baseline
  [ "$status" -eq 5 ]
  [ -f "$root/snapshot.json" ]
  [ ! -e "$root/aeo-targets.md" ]
  [ "$(jq -r '.aeo_compatibility' "$root/manifest.json")" = unavailable ]
  [[ "$output" == *'missing metadata.task_targets["aeo-baseline"]'* ]] || { echo "$output"; false; }
}

@test "detached rows are report-only while empty and unavailable fleets plan errors" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  mark_detached personal alpha

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ]
  [ "$(jq -r '.entries[0].status' "$root/snapshot.json")" = detached ]
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ]

  rm -f "$TRELLIS_HOME_FIX/registry.json"
  materialize_task personal daily-project-digest
  [ "$status" -eq 5 ]
  [ "$(jq -r '.status' "$root/manifest.json")" = planned-error ]
  [[ "$output" == *"no registered project records"* ]] || { echo "$output"; false; }

  register_repo personal alpha "$personal"
  record_unavailable personal offline "$SANDBOX/missing/offline"
  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ] || { cat "$root/manifest.json"; false; }
  [[ "$output" == *"excluded row: offline: checkout unavailable"* ]] || { echo "$output"; false; }
}

@test "AEO all-blacklisted state is planned and never emits a compatibility triplet" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/aeo-baseline"
  local metadata='{"legacy":{"blacklisted":true,"blacklist":{"reason":"local hold","added":"2026-01-01","review_after":"2026-02-01"}},"task_targets":{"aeo-baseline":{"url":"https://public.example","marker_file":"README","marker":"fixture"}}}'
  make_repo "$personal" alpha
  register_repo personal alpha "$personal" "$metadata"

  materialize_task personal aeo-baseline
  [ "$status" -eq 5 ]
  [ "$(jq -r '.status' "$root/manifest.json")" = planned-error ]
  [ "$(jq -r '.aeo_compatibility' "$root/manifest.json")" = unavailable ]
  [ ! -e "$root/aeo-targets.md" ]
  [ ! -e "$root/registry.md" ]
  [ ! -e "$root/blacklist.md" ]
  [[ "$output" == *"no eligible active targets"* ]] || { echo "$output"; false; }
}

@test "AEO validates the released parser scheme and authority contract before emitting inputs" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/aeo-baseline"
  local metadata='{"task_targets":{"aeo-baseline":{"url":"https:///missing-authority","marker_file":"README","marker":"fixture"}}}'
  make_repo "$personal" alpha
  register_repo personal alpha "$personal" "$metadata"

  materialize_task personal aeo-baseline
  [ "$status" -eq 5 ]
  [ "$(jq -r '.status' "$root/manifest.json")" = planned-error ]
  [ ! -e "$root/aeo-targets.md" ]
  [[ "$output" == *"alpha: target URL does not meet released parser scheme/netloc contract"* ]] || { echo "$output"; false; }
}
@test "AEO rendered shell environment preserves hostile local path bytes" {
  local special_home="$SANDBOX/trellis home & state\\literal"
  local personal="$SANDBOX/personal/alpha"
  local root expected_assignment expected_output_assignment
  local metadata='{"task_targets":{"aeo-baseline":{"url":"https://public.example","marker_file":"README","marker":"fixture"}}}'
  mv "$TRELLIS_HOME_FIX" "$special_home"
  TRELLIS_HOME_FIX="$special_home"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal" "$metadata"

  materialize_task personal aeo-baseline
  [ "$status" -eq 0 ]
  root="$TRELLIS_HOME_FIX/tasks/personal/aeo-baseline"
  expected_assignment="TRELLIS_AEO_RUNNER=$(printf '%q' "$TRELLIS_HOME_FIX/releases/1.2.3/payload/core-rules/skills/aeo-gate/scripts/run-fleet.sh")"
  expected_output_assignment="OUTPUT=$(printf '%q' "$root/output")"
  grep -Fq "$expected_output_assignment" "$root/prompt.md"
  grep -Fq "$expected_assignment" "$root/prompt.md"
  grep -Fq 'bash "$TRELLIS_AEO_RUNNER"' "$root/prompt.md"
  grep -Fq "$root/manifest.json" "$root/prompt.md"
  [ "$(grep -cF '{{' "$root/prompt.md")" -eq 0 ] || { cat "$root/prompt.md"; false; }
}

@test "conductor preserves only snapshot-validated private backlog state" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/conductor"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal conductor
  [ "$status" -eq 0 ]
  [ "$(jq -r '.files.backlog' "$root/manifest.json")" = backlog.json ]
  [ "$(jq -r '.policy.conductor.auto_execute_top_n' "$root/manifest.json")" -eq 0 ]
  [ "$(jq -r '.items | length' "$root/backlog.json")" -eq 0 ]

  printf '%s\n' '{"schema_version":1,"weights":{"deadline":0.35,"impact":0.30,"unblock":0.15,"effort":0.10,"staleness":0.10},"items":[{"id":"alpha-task","project_id":"alpha","title":"Alpha task","note":"Portable local prose","priority":"high","effort":"M","type":"dev","impact":"users","engine":"claude","status":"todo","tags":["fixture"],"auto_spec":false,"surgical":false}]}' > "$root/backlog.json"
  chmod 600 "$root/backlog.json"
  materialize_task personal conductor
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[0].project_id' "$root/backlog.json")" = alpha ]
  printf '%s\n' '{"schema_version":1,"items":[{"id":"alpha-task","project_id":"alpha","command":"unsafe"}]}' > "$root/backlog.json"
  chmod 600 "$root/backlog.json"
  materialize_task personal conductor
  [ "$status" -eq 4 ]
  [[ "$output" == *"invalid schema"* ]] || { echo "$output"; false; }

  printf '%s\n' '{"schema_version":1,"items":[{"id":"unknown-task","project_id":"unknown"}]}' > "$root/backlog.json"
  chmod 600 "$root/backlog.json"
  materialize_task personal conductor
  [ "$status" -eq 4 ]
  [[ "$output" == *"without an active available snapshot root"* ]] || { echo "$output"; false; }
}

@test "tracked prompts retain portable loop safety and restored generic defaults" {
  run bash -c '
    set -e
    for prompt in "$1"/*/prompt.md; do
      grep -Fq "manifest.json" "$prompt"
      grep -Fq "max_iterations" "$prompt"
      grep -Fq "no_progress_iterations" "$prompt"
      grep -Fq "budget_ceiling_usd" "$prompt"
      grep -Fq "Progress signal:" "$prompt"
      grep -Fq "{{OUTPUT_ROOT}}" "$prompt"
    done
    grep -Eq "\`auto_spec_top_n\` \| (\*\*)?0(\*\*)? \|" "$1/conductor/targets.md"
    grep -Eq "\`INCLUDE_DEV_DEPS\`: \`true\`" "$1/dep-vulnerabilities/targets.md"
    grep -Eq "\`MAJOR_GRACE_DAYS\`: \`14\`" "$1/dep-currency/targets.md"
    grep -Fq "STALE_AFTER_DAYS = 180" "$1/gotchas-rollup/targets.md"
    # `set -e` never fires on a `!`-inverted command, so an absence check has to
    # branch and exit explicitly or it asserts nothing.
    if grep -R -nF "conductor/backlog.yml" "$1/conductor"; then
      echo "unexpected backlog reference above" >&2
      exit 1
    fi
    grep -Fq "trellis task materialize --home \"\$TRELLIS_HOME\" --fleet \"\$FLEET\" \"\$TASK\"" "$1/README.md"
  ' _ "$REPO/scheduled-tasks"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
@test "tracked scheduled task templates contain no machine-root leakage" {
  # This guard used to name two real projects as extra leak tokens. That is a
  # weaker check than it looks — it covers exactly the two names someone
  # remembered to add — and the literals are themselves published, so the guard
  # leaked what it existed to catch. Project-identifier leakage is now covered
  # comprehensively by lint_mirror, which derives the token set from the
  # machine-local registry and therefore tracks every project automatically.
  # What stays here is the machine-root half, which is this test's stated scope.
  run bash -c '
    set -e
    if grep -R -nE "/Users/|/(home)/|__TRELLIS_PATH__|registry\.private\.example" \
      "$1/README.md" "$1"/*/prompt.md "$1"/*/targets.md "$1"/*/watchlist.md; then
      echo "unexpected machine-root leakage above" >&2
      exit 1
    fi
    [ ! -e "$1/prompt.md" ]
    [ ! -e "$1/targets.md" ]
    [ ! -e "$1/watchlist.md" ]
  ' _ "$REPO/scheduled-tasks"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# aeo-baseline is Tier 2 with its wrapper text checked in but no MCP
# registration. audit-report-rollup derives its registered-schedule denominator
# from README.md, so a row promoted to Tier 1 ahead of the actual registration
# would make the rollup report missed runs for a task that never ran. Pin both
# halves: the wrapper must be present, and the task must still read as pending.
@test "AEO baseline ships a wrapper block and stays unregistered until an operator acts" {
  local readme="$REPO/scheduled-tasks/README.md"
  grep -q 'wrapper ready, awaiting registration' "$readme"
  grep -q '`30 11 1 \* \*`' "$readme"
  grep -q 'expected run count is 0' "$readme"
  # Still parked. The single task catalogue replaced the old Tier 1 / Tier 2
  # split, so the negative is now "the catalogue row still reads `drafted`"
  # rather than "the row lives in the Tier 2 table". Scope it to the catalogue
  # row itself: the ready-to-paste cron lives in a fenced example above, and a
  # whole-file grep for the cadence would match that and never fail.
  grep -q '^| `aeo-baseline` | drafted |' "$readme"
  run grep -c '^| `aeo-baseline` | \(daily\|weekly\|weekdays\|monthly\|quarterly\) |' "$readme"
  [ "$output" -eq 0 ]
}

# The lane cache is the one file a task writes outside its output root, so the
# path must come from the home this run selected — not from whatever `HOME` or
# `TRELLIS_HOME` the calling shell happened to carry.
@test "lane-freshness renders the selected home over a conflicting ambient default" {
  local decoy="$SANDBOX/ambient home"
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/lane-freshness"
  mkdir -p "$decoy/state"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  grep -Fq '{{LANE_ENVIRONMENT}}' "$REPO/scheduled-tasks/lane-freshness/prompt.md"
  run env HOME="$decoy" TRELLIS_HOME="$decoy" "$MATERIALIZER" materialize \
    --home "$TRELLIS_HOME_FIX" --fleet personal lane-freshness
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$root" ]

  grep -Fq "TRELLIS_HOME=$(printf '%q' "$TRELLIS_HOME_FIX")" "$root/prompt.md"
  grep -Fq "TRELLIS_LANE_CACHE=$(printf '%q' "$TRELLIS_HOME_FIX/state/lane-availability.json")" "$root/prompt.md"
  grep -Fq "TRELLIS_LANE_RUNNER=$(printf '%q' "$TRELLIS_HOME_FIX/releases/1.2.3/payload/scripts/lane-freshness.py")" "$root/prompt.md"
  grep -Fq 'python3 "$TRELLIS_LANE_RUNNER" --home "$TRELLIS_HOME"' "$root/prompt.md"
  [ "$(grep -cF "$decoy" "$root/prompt.md")" -eq 0 ] || { cat "$root/prompt.md"; false; }
  [ "$(grep -cF '{{' "$root/prompt.md")" -eq 0 ] || { cat "$root/prompt.md"; false; }
  [ "$(grep -cF '{{' "$root/targets.md")" -eq 0 ] || { cat "$root/targets.md"; false; }
}

@test "lane environment survives a selected home with spaces and shell metacharacters" {
  local special_home="$SANDBOX/trellis home & lane\\state"
  local personal="$SANDBOX/personal/alpha"
  local root
  mv "$TRELLIS_HOME_FIX" "$special_home"
  TRELLIS_HOME_FIX="$special_home"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal lane-freshness
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  root="$TRELLIS_HOME_FIX/tasks/personal/lane-freshness"

  # Each assignment must survive evaluation as exactly one shell word.
  run bash -c 'eval "$(grep -m1 -E "^TRELLIS_LANE_CACHE=" "$1")"; printf "%s\n" "$TRELLIS_LANE_CACHE"' \
    _ "$root/prompt.md"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$TRELLIS_HOME_FIX/state/lane-availability.json" ]
  run bash -c 'eval "$(grep -m1 -E "^TRELLIS_HOME=" "$1")"; printf "%s\n" "$TRELLIS_HOME"' \
    _ "$root/prompt.md"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$TRELLIS_HOME_FIX" ]
  [ "$(jq -r '.lane_cache.path' "$root/manifest.json")" = "$TRELLIS_HOME_FIX/state/lane-availability.json" ]
}

# This task reads local state only. An empty fleet is a normal ready run, not
# the reserved no-usable-checkout planned error.
@test "lane-freshness is ready with an empty fleet and requires no checkout" {
  local root="$TRELLIS_HOME_FIX/tasks/personal/lane-freshness"

  materialize_task personal lane-freshness
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ] || { cat "$root/manifest.json"; false; }
  [ "$(jq -r '.requirements.checkout_required' "$root/manifest.json")" = false ]
  [ "$(jq -c '.requirements.planned_errors' "$root/manifest.json")" = '[]' ]
  [ "$(jq -c '.requirements.excluded_rows' "$root/manifest.json")" = '[]' ]
  [ "$(jq -r '.snapshot.entry_count' "$root/manifest.json")" -eq 0 ]
  [[ "$output" != *"planned error"* ]] || { echo "$output"; false; }
}

@test "the lane cache authorization is exact and absent from every other task" {
  local personal="$SANDBOX/personal/alpha"
  local lane="$TRELLIS_HOME_FIX/tasks/personal/lane-freshness"
  local digest="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  local conductor="$TRELLIS_HOME_FIX/tasks/personal/conductor"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal lane-freshness
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -cS '.lane_cache' "$lane/manifest.json")" = \
    "$(jq -ncS --arg home "$TRELLIS_HOME_FIX" \
      '{path: ($home + "/state/lane-availability.json"), temporary_prefix: ($home + "/state/.lane-availability.")}')" ] ||
    { jq -c '.lane_cache' "$lane/manifest.json"; false; }
  # The prefix is the collector's own `mkstemp` prefix, trailing dot included,
  # read out of the pinned runner rather than restated from memory here.
  grep -Fq "prefix=\".lane-availability.\"" \
    "$TRELLIS_HOME_FIX/releases/1.2.3/payload/scripts/lane-freshness.py"
  [ "$(basename "$(jq -r '.lane_cache.temporary_prefix' "$lane/manifest.json")")" = ".lane-availability." ]
  # Ordinary file entries stay relative to the task root.
  [ "$(jq -r '[.files[] | select(startswith("/"))] | length' "$lane/manifest.json")" -eq 0 ]

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r 'has("lane_cache")' "$digest/manifest.json")" = false ]

  materialize_task personal conductor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r 'has("lane_cache")' "$conductor/manifest.json")" = false ]
}

@test "materialize refuses an unknown placeholder and a missing required template asset" {
  local personal="$SANDBOX/personal/alpha"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  install_variant_release 1.2.4 unknown-placeholder
  materialize_task personal lane-freshness
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"unknown placeholder {{LANE_UNKNOWN}}"* ]] || { echo "$output"; false; }
  [[ "$output" == *"could not render release template"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/tasks/personal/lane-freshness" ]

  install_variant_release 1.2.5 missing-targets
  materialize_task personal lane-freshness
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *"does not provide required asset: scheduled-tasks/lane-freshness/targets.md"* ]] ||
    { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/tasks/personal/lane-freshness" ]
}

# The lane task publishes a rendered collector invocation. A release that does
# not carry the collector cannot produce a usable run, so it must be refused as
# a missing asset before anything is published — not published as `ready` with a
# runner path that does not resolve.
@test "a ready lane task requires the pinned release to carry the collector" {
  local personal="$SANDBOX/personal/alpha"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  install_variant_release 1.2.6 missing-runner
  materialize_task personal lane-freshness
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *"does not provide required asset: scripts/lane-freshness.py"* ]] ||
    { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/tasks/personal/lane-freshness" ]
}

# A registry row whose machine state contradicts the recorded identity is a
# state error for every task, including the ones that consume no checkout. The
# lane task must still say so precisely rather than materializing `ready`.
@test "a registered root that lost its Git linkage plans a lane identity error" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/lane-freshness"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  rm -rf "$personal/.git"

  materialize_task personal lane-freshness
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = planned-error ] || { cat "$root/manifest.json"; false; }
  [ "$(jq -r '.requirements.checkout_required' "$root/manifest.json")" = false ]
  [ "$(jq -r '.snapshot.identity_error_entry_count' "$root/manifest.json")" -eq 1 ]
  [ "$(jq -c '.requirements.planned_errors' "$root/manifest.json")" = \
    '["local registry row failed identity validation: personal/alpha"]' ] ||
    { jq -c '.requirements.planned_errors' "$root/manifest.json"; false; }
  [[ "$output" == *"planned error: local registry row failed identity validation: personal/alpha"* ]] ||
    { echo "$output"; false; }
}

# The collector's exit status is always 0, so classification rests entirely on
# the snapshot. Run the prompt's own jq programs — extracted from the rendered
# task, not restated here — over fixture caches that reproduce every shape the
# collector actually writes. No HTTP and no provider is involved.
@test "the rendered lane classifier separates fresh, preserved-stale and bootstrap caches" {
  local root="$TRELLIS_HOME_FIX/tasks/personal/lane-freshness"
  local validator classifier fixtures="$SANDBOX/lane-fixtures"

  materialize_task personal lane-freshness
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  validator="$(sed -n "/^jq -e '(\.stale /{s/^jq -e '//;s/' .*\$//;p;q;}" "$root/prompt.md")"
  classifier="$(sed -n "/^jq -r 'if /{s/^jq -r '//;s/' .*\$//;p;q;}" "$root/prompt.md")"
  [ -n "$validator" ] || { cat "$root/prompt.md"; false; }
  [ -n "$classifier" ] || { cat "$root/prompt.md"; false; }

  mkdir -p "$fixtures"
  # A successful poll. An empty `lanes` object here is a real empty observation.
  printf '%s\n' '{"fetchedAt":"2026-09-06T00:00:00Z","lanes":{"codex":{"remaining":0.62}},"errors":[],"stale":false}' > "$fixtures/fresh.json"
  printf '%s\n' '{"fetchedAt":"2026-09-06T00:00:00Z","lanes":{},"errors":[],"stale":false}' > "$fixtures/fresh-empty.json"
  # A failed poll over a real prior snapshot: preserved lanes, original
  # timestamp, plus the collector's `lastErrorAt`.
  printf '%s\n' '{"fetchedAt":"2026-09-05T00:00:00Z","lanes":{"codex":{"remaining":0.62}},"errors":[],"stale":true,"lastErrorAt":"2026-09-06T00:00:00Z"}' > "$fixtures/stale.json"
  # The no-prior bootstrap marker the collector writes when the very first poll
  # fails, and the same marker after a second failed poll added `lastErrorAt`.
  # Neither carries a measured lane observation.
  printf '%s\n' '{"fetchedAt":"2026-09-06T00:00:00Z","lanes":{},"errors":[],"stale":true}' > "$fixtures/bootstrap.json"
  printf '%s\n' '{"fetchedAt":"2026-09-06T00:00:00Z","lanes":{},"errors":[],"stale":true,"lastErrorAt":"2026-09-06T00:01:00Z"}' > "$fixtures/bootstrap-retried.json"
  printf '%s\n' '{"fetchedAt":"2026-09-06T00:00:00Z","lanes":{},"errors":[]}' > "$fixtures/no-stale.json"
  printf '%s\n' '{"fetchedAt":"2026-09-06T00:00:00Z","lanes":{},"errors":[],"stale":"true"}' > "$fixtures/stale-string.json"
  printf '%s\n' 'not json' > "$fixtures/malformed.json"

  local name
  for name in fresh fresh-empty stale bootstrap bootstrap-retried; do
    run jq -e "$validator" "$fixtures/$name.json"
    [ "$status" -eq 0 ] || { echo "$name: $output"; false; }
  done
  # `stale` must be validated as a boolean, not merely present.
  for name in no-stale stale-string malformed; do
    run jq -e "$validator" "$fixtures/$name.json"
    [ "$status" -ne 0 ] || { echo "$name: $output"; false; }
  done

  run jq -r "$classifier" "$fixtures/fresh.json"
  [ "$output" = fresh ] || { echo "$output"; false; }
  run jq -r "$classifier" "$fixtures/fresh-empty.json"
  [ "$output" = fresh ] || { echo "$output"; false; }
  run jq -r "$classifier" "$fixtures/stale.json"
  [ "$output" = stale ] || { echo "$output"; false; }
  # A bootstrap marker is not a usable prior snapshot, with or without the
  # repeated-failure `lastErrorAt`.
  run jq -r "$classifier" "$fixtures/bootstrap.json"
  [ "$output" = error ] || { echo "$output"; false; }
  run jq -r "$classifier" "$fixtures/bootstrap-retried.json"
  [ "$output" = error ] || { echo "$output"; false; }
}
