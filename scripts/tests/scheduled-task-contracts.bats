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

# A ready task publishes only when the pinned release carries every asset the
# materializer verifies, so every fixture release ships the tracked templates
# byte-for-byte.
build_release_repo() {
  mkdir -p "$RELEASE_REPO/core-rules"
  cp -R "$REPO/scheduled-tasks" "$RELEASE_REPO/scheduled-tasks"
  cp "$REPO/trellis.config.json" "$RELEASE_REPO/trellis.config.json"
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

# A second fixture release whose named task assets are deliberately wrong,
# installed and activated so the refusal is reached through the real release
# path rather than by tampering with an already verified store.
install_variant_release() {
  local version="$1" defect="$2" task="$3" repo
  repo="$SANDBOX/release-variant-$version"
  # Built from the tracked tree the same way `build_release_repo` builds the
  # baseline, never by copying an existing fixture checkout: copying one leaves
  # its `.git` behind and the next `git add` records a gitlink the release
  # store rejects as an unsupported tree entry.
  mkdir -p "$repo/core-rules"
  cp -R "$REPO/scheduled-tasks" "$repo/scheduled-tasks"
  cp "$REPO/trellis.config.json" "$repo/trellis.config.json"
  case "$defect" in
    unknown-placeholder)
      printf '%s\n' 'Cache {{UNKNOWN_PLACEHOLDER}} is not a rendered input.' \
        >> "$repo/scheduled-tasks/$task/prompt.md"
      ;;
    missing-targets)
      rm -f "$repo/scheduled-tasks/$task/targets.md"
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


@test "materializer TERM while waiting for a foreign lock leaves no stage or publication" {
  local lock="$TRELLIS_HOME_FIX/locks/scheduled-tasks.lock"
  local tasks="$TRELLIS_HOME_FIX/tasks/personal" stage='' runner worker rc i
  local leaked=false published=false lock_kept=false orphan=false
  mkdir -p "$TRELLIS_HOME_FIX/locks" "$SANDBOX/signal-bin"
  mkdir -m 700 "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  chmod 600 "$lock/pid"
  cat > "$SANDBOX/signal-bin/sleep" <<'SH'
#!/bin/bash
if [ -f "$B9_TEST_SLEEP_ENABLE" ]; then
  printf '%s\n' "$PPID" > "$B9_TEST_SLEEP_READY.tmp"
  mv "$B9_TEST_SLEEP_READY.tmp" "$B9_TEST_SLEEP_READY"
  while [ ! -f "$B9_TEST_SLEEP_GO" ]; do /bin/sleep 0.05; done
  exit 0
fi
exec /bin/sleep "$@"
SH
  chmod 700 "$SANDBOX/signal-bin/sleep"
  env PATH="$SANDBOX/signal-bin:$PATH" TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    B9_TEST_SLEEP_ENABLE="$SANDBOX/sleep-enable" B9_TEST_SLEEP_READY="$SANDBOX/sleep-ready" \
    B9_TEST_SLEEP_GO="$SANDBOX/sleep-go" \
    "$MATERIALIZER" materialize --home "$TRELLIS_HOME_FIX" --fleet personal daily-project-digest \
    > "$SANDBOX/materializer.out" 2> "$SANDBOX/materializer.err" &
  runner=$!
  shopt -s nullglob
  for ((i=0; i<3600; i++)); do
    local candidates=("$tasks"/.daily-project-digest.tmp.*)
    if [ "${#candidates[@]}" -gt 0 ] && [ -f "${candidates[0]}/.planned-errors" ]; then
      stage="${candidates[0]}"
      : > "$SANDBOX/sleep-enable"
      break
    fi
    kill -0 "$runner" 2>/dev/null || break
    /bin/sleep 0.05
  done
  if [ -n "$stage" ]; then
    for ((i=0; i<600; i++)); do
      [ -f "$SANDBOX/sleep-ready" ] && break
      kill -0 "$runner" 2>/dev/null || break
      /bin/sleep 0.05
    done
  fi
  if [ ! -f "$SANDBOX/sleep-ready" ]; then
    pkill -TERM -P "$runner" 2>/dev/null || true
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    printf 'materializer did not reach the held task lock\n' >&2
    cat "$SANDBOX/materializer.err" >&2
    return 1
  fi
  worker="$(<"$SANDBOX/sleep-ready")"
  case "$worker" in
    ''|*[!0-9]*|0|1)
      pkill -TERM -P "$runner" 2>/dev/null || true
      kill -TERM "$runner" 2>/dev/null || true
      wait "$runner" 2>/dev/null || true
      echo 'invalid worker identity' >&2
      return 1
      ;;
  esac
  kill -TERM "$runner"
  : > "$SANDBOX/sleep-go"
  if wait "$runner"; then rc=0; else rc=$?; fi
  [ ! -e "$stage" ] || leaked=true
  [ ! -e "$tasks/daily-project-digest" ] || published=true
  [ -f "$lock/pid" ] && [ "$(<"$lock/pid")" = "$$" ] && lock_kept=true
  # The pre-fix subshell is orphaned when the parent dies. Stop only the
  # test-owned shell recorded by the blocked sleep, before fixture teardown.
  if [ "$worker" != "$runner" ] && kill -0 "$worker" 2>/dev/null; then
    orphan=true
    kill -KILL "$worker" 2>/dev/null || true
  fi
  [ "$rc" -eq 143 ] || { printf 'wrong signal status %s\n' "$rc" >&2; return 1; }
  [ "$lock_kept" = true ] || { echo 'foreign task lock was removed' >&2; return 1; }
  [ "$leaked" = false ] || { echo 'stage survived parent termination' >&2; return 1; }
  [ "$orphan" = false ] || { echo 'materializer worker survived its parent' >&2; return 1; }
  [ -z "$(find "$tasks" -maxdepth 1 -name '.*.tmp.*.owner.json' -print)" ] ||
    { echo 'stage owner record survived TERM' >&2; return 1; }
  [ "$published" = false ] || { echo 'task published after parent termination' >&2; return 1; }
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

# The canonical harness set is the registry schema enum, and every attached
# checkout declares all five. Materialization accepted only `claude|codex|pi`
# while the schema admitted `antigravity` and `opencode`, so 295 of 296 rows in
# a live snapshot failed canonicalization and no task could be materialized.
@test "a row carrying all five canonical harnesses materializes ready" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  jq '(.projects["personal/alpha"].checkouts[].harnesses) |= ["antigravity","claude","codex","opencode","pi"]' \
    "$TRELLIS_HOME_FIX/registry.json" > "$TRELLIS_HOME_FIX/registry.json.next"
  mv "$TRELLIS_HOME_FIX/registry.json.next" "$TRELLIS_HOME_FIX/registry.json"
  chmod 600 "$TRELLIS_HOME_FIX/registry.json"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ] || { cat "$root/manifest.json"; false; }
  [ "$(jq -c '.entries[0].harnesses' "$root/snapshot.json")" = '["antigravity","claude","codex","opencode","pi"]' ] || \
    { jq -c '.entries[0].harnesses' "$root/snapshot.json"; false; }
}

# Fail closed. Widening the predicate to the schema enum must not turn the
# canonicalizer into an accept-anything check: a token no harness owns is still
# a state error that publishes nothing.
@test "an unknown harness token still fails closed" {
  local personal="$SANDBOX/personal/alpha"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  jq '(.projects["personal/alpha"].checkouts[].harnesses) |= ["claude","grok"]' \
    "$TRELLIS_HOME_FIX/registry.json" > "$TRELLIS_HOME_FIX/registry.json.next"
  mv "$TRELLIS_HOME_FIX/registry.json.next" "$TRELLIS_HOME_FIX/registry.json"
  chmod 600 "$TRELLIS_HOME_FIX/registry.json"

  materialize_task personal daily-project-digest
  # The schema-aware registry validation rejects the row before the snapshot
  # canonicalizer is reached, which is the same fail-closed verdict one step
  # earlier. Nothing is published either way.
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"registry failed schema-aware validation"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest" ]
  [ -z "$(find "$TRELLIS_HOME_FIX/tasks/personal" -maxdepth 1 -name '.daily-project-digest.tmp.*' -print)" ]
}

# The predicate is exercised directly: a row that already passed registry
# validation must canonicalize for every canonical harness and must still fail
# for a token the schema does not admit.
@test "the snapshot canonicalizer admits exactly the schema harness union" {
  local snapshot="$SANDBOX/snapshot-five.json"
  jq -n '{
    schema_version: 1,
    discovery_ignores: {},
    entries: [{
      fleet: "personal", project_id: "alpha", project_key: "personal/alpha",
      status: "active", kind: "worktree",
      checkout_id: null, worktree_id: null, root: "/tmp/alpha", git_common_dir: null,
      harnesses: ["antigravity","claude","codex","opencode","pi"],
      metadata: {}, availability: "available", excluded: false
    }]
  }' > "$snapshot"

  run bash -c '. "$1" help >/dev/null 2>&1 || exit 1; canonicalize_registry_snapshot "$2" "$3" personal' \
    _ "$MATERIALIZER" "$snapshot" "$SANDBOX/canonical-five.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -c '.entries[0].harnesses' "$SANDBOX/canonical-five.json")" = \
    '["antigravity","claude","codex","opencode","pi"]' ] ||
    { jq -c '.entries[0].harnesses' "$SANDBOX/canonical-five.json"; false; }

  jq '.entries[0].harnesses = ["claude","grok"]' "$snapshot" > "$SANDBOX/snapshot-grok.json"
  run bash -c '. "$1" help >/dev/null 2>&1 || exit 1; canonicalize_registry_snapshot "$2" "$3" personal' \
    _ "$MATERIALIZER" "$SANDBOX/snapshot-grok.json" "$SANDBOX/canonical-grok.json"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"could not canonicalize strict registry snapshot"* ]] || { echo "$output"; false; }
  [ ! -s "$SANDBOX/canonical-grok.json" ] || { echo 'canonicalizer wrote output on refusal'; false; }
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

# exec keeps the caller's $$, so a verification memo it exports would match.
# The materializer must load the release store with an empty memo and catch the
# payload change made after the caller's own successful verification.
@test "materialize ignores a verification memo handed over by exec" {
  local personal="$SANDBOX/personal/alpha"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c '
    . "$1" || exit 90
    release_store_locate 1.2.3 >/dev/null || exit 91
    [ -n "$_TRELLIS_RELEASE_STORE_VERIFY_MEMO" ] || exit 92
    version="$TRELLIS_HOME/releases/1.2.3/payload/core-rules/VERSION"
    chmod u+w "$version" && printf "tampered\n" > "$version" && chmod a-w "$version" || exit 93
    export _TRELLIS_RELEASE_STORE_VERIFY_MEMO
    exec "$2" materialize --home "$TRELLIS_HOME" --fleet personal daily-project-digest
  ' _ "$RELEASE_STORE_LIB" "$MATERIALIZER"
  [ "$status" -eq 4 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"changed release content: core-rules/VERSION"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest" ]
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
  local manifest_before backlog_before manifest_status_before tree_before
  manifest_before="$(shasum -a 256 "$root/manifest.json" | awk '{print $1}')"
  backlog_before="$(shasum -a 256 "$root/backlog.json" | awk '{print $1}')"
  manifest_status_before="$(jq -r '.status // empty' "$root/manifest.json")"
  tree_before="$(cd "$root" && find . -type f | LC_ALL=C sort)"
  materialize_task personal conductor
  [ "$status" -eq 4 ]
  [[ "$output" == *"invalid schema"* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$root/manifest.json" | awk '{print $1}')" = "$manifest_before" ]
  [ "$(shasum -a 256 "$root/backlog.json" | awk '{print $1}')" = "$backlog_before" ]
  [ "$(jq -r '.status // empty' "$root/manifest.json")" = "$manifest_status_before" ]
  [ "$(cd "$root" && find . -type f | LC_ALL=C sort)" = "$tree_before" ]

  printf '%s\n' '{"schema_version":1,"items":[{"id":"unknown-task","project_id":"unknown"}]}' > "$root/backlog.json"
  chmod 600 "$root/backlog.json"
  manifest_before="$(shasum -a 256 "$root/manifest.json" | awk '{print $1}')"
  backlog_before="$(shasum -a 256 "$root/backlog.json" | awk '{print $1}')"
  manifest_status_before="$(jq -r '.status // empty' "$root/manifest.json")"
  tree_before="$(cd "$root" && find . -type f | LC_ALL=C sort)"
  materialize_task personal conductor
  [ "$status" -eq 4 ]
  [[ "$output" == *"without an active available snapshot root"* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$root/manifest.json" | awk '{print $1}')" = "$manifest_before" ]
  [ "$(shasum -a 256 "$root/backlog.json" | awk '{print $1}')" = "$backlog_before" ]
  [ "$(jq -r '.status // empty' "$root/manifest.json")" = "$manifest_status_before" ]
  [ "$(cd "$root" && find . -type f | LC_ALL=C sort)" = "$tree_before" ]
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

@test "materialize refuses an unknown placeholder and a missing required template asset" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  install_variant_release 1.2.4 unknown-placeholder daily-project-digest
  materialize_task personal daily-project-digest
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"unknown placeholder {{UNKNOWN_PLACEHOLDER}}"* ]] || { echo "$output"; false; }
  [[ "$output" == *"could not render release template"* ]] || { echo "$output"; false; }
  [ ! -e "$root" ]

  install_variant_release 1.2.5 missing-targets daily-project-digest
  materialize_task personal daily-project-digest
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *"does not provide required asset: scheduled-tasks/daily-project-digest/targets.md"* ]] ||
    { echo "$output"; false; }
  [ ! -e "$root" ]
}

# This task reads local state only. An empty fleet is a normal ready run, not
# the reserved no-usable-checkout planned error.
@test "a control-plane task is ready with an empty fleet and requires no checkout" {
  local root="$TRELLIS_HOME_FIX/tasks/personal/audit-report-rollup"

  materialize_task personal audit-report-rollup
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r '.status' "$root/manifest.json")" = ready ] || { cat "$root/manifest.json"; false; }
  [ "$(jq -r '.requirements.checkout_required' "$root/manifest.json")" = false ]
  [ "$(jq -c '.requirements.planned_errors' "$root/manifest.json")" = '[]' ]
  [ "$(jq -c '.requirements.excluded_rows' "$root/manifest.json")" = '[]' ]
  [ "$(jq -r '.snapshot.entry_count' "$root/manifest.json")" -eq 0 ]
  [[ "$output" != *"planned error"* ]] || { echo "$output"; false; }
}

# The lane-availability cache authorization retired with the lane-freshness
# task: the collector now runs from a LaunchAgent and no materialized task may
# claim an external write. File entries stay relative to the task root.
@test "no materialized manifest carries an external cache authorization" {
  local personal="$SANDBOX/personal/alpha"
  local digest="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  local conductor="$TRELLIS_HOME_FIX/tasks/personal/conductor"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r 'has("lane_cache")' "$digest/manifest.json")" = false ]
  [ "$(jq -r '[.files[] | select(startswith("/"))] | length' "$digest/manifest.json")" -eq 0 ]

  materialize_task personal conductor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r 'has("lane_cache")' "$conductor/manifest.json")" = false ]

  run grep -R -n 'LANE_ENVIRONMENT\|lane_cache\|TRELLIS_LANE_' \
    "$REPO/scheduled-tasks/README.md" "$REPO/scheduled-tasks"/*/prompt.md "$REPO/scheduled-tasks"/*/targets.md
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

# A registry row whose machine state contradicts the recorded identity is a
# state error for every task, including the ones that consume no checkout. The
# control-plane task must still say so precisely rather than materializing
# `ready`.
@test "a registered root that lost its Git linkage plans a control-plane identity error" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/audit-report-rollup"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  rm -rf "$personal/.git"

  materialize_task personal audit-report-rollup
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

# The stage trap covers EXIT, HUP, INT and TERM. SIGKILL cannot be trapped, and
# that is how 159 `.tmp.*` orphans accumulated: the owner sidecar is the only
# thing that tells `trellis gc` which PID went away, so it must survive a kill
# the traps never see and be removed on every path the traps do cover.
@test "an untrappable kill leaves a dead-PID stage owner record for gc" {
  local personal="$SANDBOX/personal/alpha"
  local bin="$SANDBOX/kill-bin" ready="$SANDBOX/kill-ready" runner='' stage='' rc=0
  local real_python
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"
  real_python="$(command -v python3)"
  mkdir -p "$bin"
  # Block only at the template render, which is the first python after the stage
  # exists: earlier python calls (home liveness, config projection) must run.
  cat > "$bin/python3" <<EOF
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in */.release-assets/prompt.md) blocked=1 ;; esac
done
[ "\${blocked:-0}" = 1 ] || exec "$real_python" "\$@"
printf 'ready\n' > "$ready"
for _ in \$(seq 1 1200); do
  kill -0 "\$PPID" 2>/dev/null || exit 0
  /bin/sleep 0.05
done
exit 0
EOF
  chmod 700 "$bin/python3"
  env PATH="$bin:$PATH" TRELLIS_HOME="$TRELLIS_HOME_FIX" \
    "$MATERIALIZER" materialize --home "$TRELLIS_HOME_FIX" --fleet personal daily-project-digest \
    > "$SANDBOX/kill.out" 2> "$SANDBOX/kill.err" &
  runner=$!
  local i
  for ((i=0; i<1200; i++)); do
    [ -f "$ready" ] && break
    kill -0 "$runner" 2>/dev/null || break
    /bin/sleep 0.05
  done
  if [ ! -f "$ready" ]; then
    kill -KILL "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    printf 'materializer never reached rendering\n' >&2
    cat "$SANDBOX/kill.err" >&2
    return 1
  fi
  # The owner sidecar shares the glob prefix, so select the stage directory.
  local stages=()
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && stages+=("$candidate")
  done < <(find "$TRELLIS_HOME_FIX/tasks/personal" -maxdepth 1 -type d \
    -name '.daily-project-digest.tmp.*' -print)
  [ "${#stages[@]}" -eq 1 ] || { printf 'expected one stage, found %s\n' "${#stages[@]}" >&2; false; }
  stage="${stages[0]}"
  [ -d "$stage" ] || { echo 'stage missing before kill' >&2; false; }
  [ -f "$stage.owner.json" ] || { echo 'owner sidecar missing before kill' >&2; false; }
  [ "$(jq -r '.pid' "$stage.owner.json")" = "$runner" ] ||
    { jq -c . "$stage.owner.json"; false; }
  [[ "$(jq -r '.created_at' "$stage.owner.json")" =~ ^[0-9]+$ ]] ||
    { jq -c . "$stage.owner.json"; false; }

  kill -KILL "$runner"
  wait "$runner" || rc=$?
  [ "$rc" -eq 137 ] || { printf 'wrong signal status %s\n' "$rc" >&2; false; }
  # Untrappable: the stage and its record survive, and the recorded PID is dead,
  # which is exactly the state gc's `pid_state` classifies as reclaimable.
  [ -d "$stage" ] || { echo 'stage vanished on SIGKILL' >&2; false; }
  [ -f "$stage.owner.json" ] || { echo 'owner sidecar vanished on SIGKILL' >&2; false; }
  run kill -0 "$runner"
  [ "$status" -ne 0 ] || { echo 'recorded owner still alive' >&2; false; }
  rm -rf "$stage" "$stage.owner.json"
}

@test "a handled run removes the stage owner record on success and on failure" {
  local personal="$SANDBOX/personal/alpha"
  local root="$TRELLIS_HOME_FIX/tasks/personal/daily-project-digest"
  make_repo "$personal" alpha
  register_repo personal alpha "$personal"

  materialize_task personal daily-project-digest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$root" ]
  [ -z "$(find "$TRELLIS_HOME_FIX/tasks/personal" -maxdepth 1 -name '.daily-project-digest.tmp.*' -print)" ]

  install_variant_release 1.2.7 missing-targets daily-project-digest
  materialize_task personal daily-project-digest
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ -z "$(find "$TRELLIS_HOME_FIX/tasks/personal" -maxdepth 1 -name '.daily-project-digest.tmp.*' -print)" ]
}

# The lane collector is one local HTTP GET, so it must never be an agent turn.
# This template is the replacement for the retired lane-freshness task: no model
# binary, no checkout path, a five-minute interval, and a valid plist.
@test "the lane-freshness LaunchAgent template is zero-cost and renders valid" {
  local template="$REPO/core-rules/templates/org.trellis.lane-freshness.plist"
  local rendered="$SANDBOX/lane-freshness.plist"
  command -v /usr/bin/plutil >/dev/null 2>&1 || skip "plutil not available"
  [ -f "$template" ] || { echo 'lane-freshness plist template missing'; false; }

  /usr/bin/sed -e 's|__TRELLIS_HOME__|/fixture/trellis-home|g' \
    -e 's|__USER_HOME__|/fixture/user|g' \
    -e 's|__PYTHON3__|/usr/bin/python3|g' \
    "$template" > "$rendered"

  run /usr/bin/plutil -lint "$rendered"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run /usr/libexec/PlistBuddy -c 'Print :StartInterval' "$rendered"
  [ "$output" = 300 ]
  run /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$rendered"
  [ "$output" = '/fixture/trellis-home/state/lane-freshness/lane-freshness.py' ]
  # A model binary in the arguments would restore the cost this task retired.
  run grep -E '<string>[^<]*(claude|codex|opencode|antigravity)[^<]*</string>' "$rendered"
  [ "$status" -eq 1 ] || { echo "model binary in plist: $output"; false; }
  # The collector runs from a release-independent copy under TRELLIS_HOME, never a checkout path.
  grep -Fq '__TRELLIS_HOME__/state/lane-freshness/lane-freshness.py' "$template"
  run grep -E '__TRELLIS_ROOT__|/[U]sers/|/[p]rojects/' "$template"
  [ "$status" -eq 1 ] || { echo "checkout path in plist: $output"; false; }
}

@test "AEO URL parsing isolates its stdin python from modules in the caller cwd" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  local poison="$SANDBOX/poison-urllib" marker="$SANDBOX/urllib-marker"
  mkdir -p "$poison/urllib"
  cat > "$poison/urllib/__init__.py" <<'PY'
import os
open(os.environ["SHADOW_MARKER"], "w").write("shadowed\n")
raise SystemExit(0)
PY
  run env SHADOW_MARKER="$marker" bash -c '
    . "$1" help >/dev/null 2>&1 || exit 1
    cd "$2" || exit 1
    aeo_url_matches_target_parser "https://example.invalid/path"
  ' _ "$MATERIALIZER" "$poison"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$marker" ] || { echo "cwd urllib executed"; false; }
}
