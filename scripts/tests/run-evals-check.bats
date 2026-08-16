#!/usr/bin/env bats

SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  HARNESS_ROOT="$(mktemp -d)"
  TRELLIS_HOME="$HARNESS_ROOT/trellis home"
  REGISTRY_LIB="$HARNESS_ROOT/scripts/lib/local-registry.sh"
  CLAUDE_MARKER="$HARNESS_ROOT/claude-called"

  mkdir -p "$HARNESS_ROOT/scripts/lib" "$HARNESS_ROOT/core-rules/evals/template/example" \
    "$HARNESS_ROOT/bin" "$TRELLIS_HOME"
  cp "$SOURCE_ROOT/scripts/run-evals.sh" "$HARNESS_ROOT/scripts/run-evals.sh"
  cp "$SOURCE_ROOT/scripts/registry.sh" "$HARNESS_ROOT/scripts/registry.sh"
  cp "$SOURCE_ROOT/scripts/lib/local-registry.sh" "$REGISTRY_LIB"
  cp "$SOURCE_ROOT/scripts/lib/trellis-home.sh" "$HARNESS_ROOT/scripts/lib/trellis-home.sh"
  cp "$SOURCE_ROOT/scripts/lib/trellis.registry.schema.json" "$HARNESS_ROOT/scripts/lib/trellis.registry.schema.json"
  cp "$SOURCE_ROOT/scripts/lib/trellis.machine.schema.json" "$HARNESS_ROOT/scripts/lib/trellis.machine.schema.json"
  cp "$SOURCE_ROOT/core-rules/CLAUDE.md" "$HARNESS_ROOT/core-rules/CLAUDE.md"
  chmod +x "$HARNESS_ROOT/scripts/run-evals.sh" "$HARNESS_ROOT/scripts/registry.sh"

  cat > "$HARNESS_ROOT/bin/claude" <<'EOF'
#!/usr/bin/env bash
touch "${CLAUDE_MARKER:?}"
echo 'unexpected model invocation' >&2
exit 99
EOF
  cat > "$HARNESS_ROOT/bin/yq" <<'EOF'
#!/usr/bin/env bash
set -eu

if [ "${1:-}" = "." ]; then
  cat "$2"
  exit 0
fi

[ "${1:-}" = "-r" ] || exit 2
query="$2"
file="$3"
case "$query" in
  '.version // ""') key=version; fallback="" ;;
  '.id // ""') key=id; fallback="" ;;
  '.project // ""') key=project; fallback="" ;;
  '.prompt // ""') key=prompt; fallback="" ;;
  '.runs // 5') key=runs; fallback=5 ;;
  '.model // "sonnet"') key=model; fallback=sonnet ;;
  *) exit 2 ;;
esac
value="$(awk -v key="$key" '$0 ~ "^" key ":[[:space:]]*" { sub("^[^:]*:[[:space:]]*", ""); print; exit }' "$file")"
printf '%s\n' "${value:-$fallback}"
EOF
  chmod +x "$HARNESS_ROOT/bin/yq"
  chmod +x "$HARNESS_ROOT/bin/claude"
  cat > "$HARNESS_ROOT/core-rules/evals/template/example/manifest.yml" <<'EOF'
version: 1
id: example
project: template
prompt: This fixture is excluded from fleet evaluation.
EOF
}

teardown() {
  rm -rf "$HARNESS_ROOT"
}

make_repo() {
  local root="$1" project_id="$2"
  mkdir -p "$root"
  git -C "$root" init -q -b main
  git -C "$root" config user.email run-evals@example.invalid
  git -C "$root" config user.name 'Run Evals'
  printf '%s\n' '{"schema_version":1,"project_id":"'"$project_id"'"}' > "$root/.trellis.json"
  printf '%s\n' fixture > "$root/README"
  git -C "$root" add .
  git -C "$root" commit -q -m fixture
}

register_project() {
  local fleet="$1" project_id="$2" root="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; local_registry_register_worktree "$TRELLIS_HOME" "$2" "$3" "$4" "" "[]" "" "{}"' \
    _ "$REGISTRY_LIB" "$fleet" "$project_id" "$root"
  [ "$status" -eq 0 ]
}

record_unavailable() {
  local fleet="$1" project_id="$2" root="$3"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1"; local_registry_record_unavailable_root "$TRELLIS_HOME" "$2" "$3" "$4" "{}"' \
    _ "$REGISTRY_LIB" "$fleet" "$project_id" "$root"
  [ "$status" -eq 0 ]
}
write_machine_config() {
  local default_fleet="${1:-personal}" discovery_root="$HARNESS_ROOT/discovery root"
  mkdir -p "$discovery_root"
  jq -n \
    --arg source "$HARNESS_ROOT" \
    --arg root "$discovery_root" \
    --arg fleet "$default_fleet" \
    '{
      schema_version: 1,
      source_root: $source,
      release_remote: "fixture://release",
      active_cli_release: "1.2.3",
      default_fleet: $fleet,
      fleets: {($fleet): {discovery_roots: [$root]}}
    }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}


write_fixture() {
  local project="$1"
  local fixture="$HARNESS_ROOT/core-rules/evals/$project/smoke"
  mkdir -p "$fixture"
  cat > "$fixture/manifest.yml" <<EOF
version: 1
id: smoke
project: $project
prompt: Create SMOKE.md.
EOF
  printf '%s\n' '{"assertions": []}' > "$fixture/expected.json"
}

run_mode() {
  local mode="$1" fleet="${2:-personal}"
  run env \
    TRELLIS_HOME="$TRELLIS_HOME" \
    CLAUDE_MARKER="$CLAUDE_MARKER" \
    PATH="$HARNESS_ROOT/bin:$PATH" \
    bash "$HARNESS_ROOT/scripts/run-evals.sh" "--$mode" \
      --home "$TRELLIS_HOME" --fleet "$fleet"
}

@test "template-only evals pass for an empty selected local fleet without model invocation" {
  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no fixtures matched"* ]] || { echo "$output"; false; }
  done
  [ ! -e "$CLAUDE_MARKER" ]
}

@test "available worktrees with spaces are selected from the requested fleet and unavailable rows are reported" {
  alpha="$HARNESS_ROOT/personal roots/alpha project"
  unavailable="$HARNESS_ROOT/offline volume/alpha\\backup"
  make_repo "$alpha" alpha
  register_project personal alpha "$alpha"
  record_unavailable personal alpha-offline "$unavailable"
  write_fixture alpha

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"unavailable local registry row: personal/alpha-offline"* ]] || { echo "$output"; false; }
    [[ "$output" == *"$unavailable"* ]] || { echo "$output"; false; }
    [[ "$output" == *"1 fixture(s) valid"* ]] || { echo "$output"; false; }
    if [ "$mode" = dry-run ]; then
      [[ "$output" == *"would run:"* ]] || { echo "$output"; false; }
    fi
  done
  [ ! -e "$CLAUDE_MARKER" ]
}

@test "unavailable rows do not require an eval fixture or trigger a model invocation" {
  record_unavailable personal unavailable-only "$HARNESS_ROOT/missing volume/project"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"unavailable local registry row: personal/unavailable-only"* ]] || { echo "$output"; false; }
    [[ "$output" == *"no fixtures matched"* ]] || { echo "$output"; false; }
  done
  [ ! -e "$CLAUDE_MARKER" ]
}
# A registered row whose recorded root is present but is not a Git worktree.
# Its stored hashes still verify, so `registry.sh list` emits the complete
# listing and only then exits with the state class.
add_broken_registry_row() {
  local fleet="$1" project_id="$2" sibling="$HARNESS_ROOT/broken sibling checkout"
  local registry="$TRELLIS_HOME/registry.json" checkout_id worktree_id sha
  mkdir -p "$sibling"
  if command -v shasum >/dev/null 2>&1; then sha="shasum -a 256"; else sha="sha256sum"; fi
  checkout_id="$(printf '%s' "$sibling/.git" | $sha | cut -d ' ' -f 1)"
  worktree_id="$(printf '%s' "$sibling" | $sha | cut -d ' ' -f 1)"
  jq --arg key "$fleet/$project_id" --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg root "$sibling" --arg common "$sibling/.git" \
    --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
      .projects[$key] = {
        fleet: $fleet, project_id: $project_id, status: "active", metadata: {},
        checkouts: {
          ($checkout): {
            root: $root, git_common_dir: $common, harnesses: [],
            worktrees: {($worktree): {root: $root}}
          }
        }
      }' "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"
  chmod 600 "$registry"
}

@test "a registry state-error row raises the exit class without discarding the listing" {
  alpha="$HARNESS_ROOT/personal roots/alpha project"
  make_repo "$alpha" alpha
  register_project personal alpha "$alpha"
  add_broken_registry_row personal broken-sibling
  write_fixture alpha

  for mode in check dry-run; do
    run_mode "$mode"

    # The complete listing survives exit 4: the healthy row is still evaluated,
    # the state-error row is reported, and class 4 reaches run-evals' own exit
    # rather than being discarded or downgraded.
    [ "$status" -eq 4 ]
    [[ "$output" == *"state-error local registry row: personal/broken-sibling"* ]] || { echo "$output"; false; }
    [[ "$output" == *"1 fixture(s) valid"* ]] || { echo "$output"; false; }
  done
  [ ! -e "$CLAUDE_MARKER" ]
}

@test "an explicitly filtered ineligible fixture fails instead of becoming an empty success" {
  unavailable="$HARNESS_ROOT/missing volume/alpha"
  record_unavailable personal alpha "$unavailable"
  write_fixture alpha

  run env \
    TRELLIS_HOME="$TRELLIS_HOME" \
    CLAUDE_MARKER="$CLAUDE_MARKER" \
    PATH="$HARNESS_ROOT/bin:$PATH" \
    bash "$HARNESS_ROOT/scripts/run-evals.sh" --check \
      --home "$TRELLIS_HOME" --fleet personal --filter 'alpha/*'

  [ "$status" -eq 4 ]
  [[ "$output" == *"selected eval fixture 'alpha/smoke' has no active available worktree in fleet 'personal'"* ]] || { echo "$output"; false; }
  [ ! -e "$CLAUDE_MARKER" ]
}

@test "a selected fleet must exist in validated local machine state" {
  write_machine_config personal

  run_mode check work

  [ "$status" -eq 4 ]
  [[ "$output" == *"selected fleet is not configured locally: work"* ]] || { echo "$output"; false; }
  [ ! -e "$CLAUDE_MARKER" ]
}


@test "fleet selection is isolated even when the same machine registry has other available roots" {
  personal="$HARNESS_ROOT/personal roots/alpha project"
  work="$HARNESS_ROOT/work roots/beta project"
  make_repo "$personal" alpha
  make_repo "$work" beta
  register_project personal alpha "$personal"
  register_project work beta "$work"
  write_fixture alpha

  run_mode check personal
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 fixture(s) valid"* ]] || { echo "$output"; false; }

  run_mode check work
  [ "$status" -eq 4 ]
  [[ "$output" == *"active available project 'beta' is missing eval fixture"* ]] || { echo "$output"; false; }
  [ ! -e "$CLAUDE_MARKER" ]
}

@test "check fails only for an available selected worktree without a fixture" {
  alpha="$HARNESS_ROOT/registered/alpha"
  make_repo "$alpha" alpha
  register_project personal alpha "$alpha"

  run_mode check

  [ "$status" -eq 4 ]
  [[ "$output" == *"active available project 'alpha' is missing eval fixture"* ]] || { echo "$output"; false; }
  [ ! -e "$CLAUDE_MARKER" ]
}
