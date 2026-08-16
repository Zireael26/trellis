#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
TRELLIS="$REPO/scripts/trellis"
MATERIALIZER="$REPO/scripts/materialize-scheduled-task.sh"
REGISTRY_LIB="$REPO/scripts/lib/local-registry.sh"
RELEASE_STORE_LIB="$REPO/scripts/lib/release-store.sh"

setup() {
  SANDBOX="$(mktemp -d)"
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

build_release_repo() {
  mkdir -p "$RELEASE_REPO/core-rules"
  cp -R "$REPO/scheduled-tasks" "$RELEASE_REPO/scheduled-tasks"
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
}

install_fixture_release() {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c \
    '. "$1"; release_store_install "$2" "$3" ""' \
    _ "$RELEASE_STORE_LIB" 1.2.3 "$RELEASE_REPO"
  [ "$status" -eq 0 ]
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

@test "materialize retains unavailable rows and returns planned exit class 5" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  record_unavailable personal offline "$SANDBOX/missing/offline"

  materialize_task personal daily-project-digest
  [ "$status" -eq 5 ]
  [ -d "$root" ]
  [ "$(jq '[.entries[] | select(.availability == "unavailable")] | length' "$root/snapshot.json")" -eq 1 ]
  [ "$(jq -r '.status' "$root/manifest.json")" = planned-error ]
  [[ "$output" == *"required checkout unavailable for project: offline"* ]] || { echo "$output"; false; }
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
  [ "$status" -eq 5 ]
  [[ "$output" == *"required checkout unavailable for project: offline"* ]] || { echo "$output"; false; }
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
  run bash -c '
    set -e
    if grep -R -nE "/Users/|/(home)/|__TRELLIS_PATH__|registry\.private\.example|TGSC|Lume(App)?" \
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
