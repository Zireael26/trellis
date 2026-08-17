#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/fleet-dependencies"
CLI="$ROOT/scripts/fleet-dependencies.mjs"
REGISTRY_LIB="$ROOT/scripts/lib/local-registry.sh"

setup() {
  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/fleet dependency state"
  FIXTURE_COPY="$SANDBOX/fixture source"
  TRELLIS_HOME="$SANDBOX/trellis home"
  PROJECT_ROOT="$SANDBOX/registered worktrees"
  PROJECT_A="$PROJECT_ROOT/repo a"
  PROJECT_B="$PROJECT_ROOT/repo b"
  UNAVAILABLE_ROOT="$SANDBOX/offline volume/repo offline"

  mkdir -p "$PROJECT_ROOT" "$TRELLIS_HOME"
  cp -R "$FIXTURE" "$FIXTURE_COPY"
  mv "$FIXTURE_COPY/repo-a" "$PROJECT_A"
  mv "$FIXTURE_COPY/repo-b" "$PROJECT_B"
  make_repo "$PROJECT_A" repo-a
  make_repo "$PROJECT_B" repo-b
  register_project personal repo-a "$PROJECT_A"
  register_project personal repo-b "$PROJECT_B"
  record_unavailable personal offline "$UNAVAILABLE_ROOT"
}

make_repo() {
  local root="$1" project_id="$2"
  git -C "$root" init -q -b main
  git -C "$root" config user.email fleet-dependencies@example.invalid
  git -C "$root" config user.name 'Fleet Dependencies'
  printf '%s\n' '{"schema_version":1,"project_id":"'"$project_id"'"}' > "$root/.trellis.json"
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
  local default_fleet="${1:-personal}" discovery_root="$SANDBOX/discovery root"
  mkdir -p "$discovery_root"
  jq -n \
    --arg source "$ROOT" \
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


run_check() {
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --ref worktree \
    --today 2026-07-21 \
    --json
}

@test "local registry worktrees with spaces satisfy the shared dependency baseline" {
  run_check

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.projects | length')" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.projects[] | select(.name == "repo-a") | .root')" = "$PROJECT_A" ]
  [ "$(printf '%s' "$output" | jq -r '.projects[] | select(.name == "repo-b") | .root')" = "$PROJECT_B" ]
}

@test "unavailable local rows are retained in JSON and never become evaluation roots" {
  run_check

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.unavailable[] | select(.project == "offline") | .root')" = "$UNAVAILABLE_ROOT" ]
  [ "$(printf '%s' "$output" | jq --arg root "$UNAVAILABLE_ROOT" '[.projects[].root] | index($root) == null')" = true ]
}

@test "peer compatibility accepts a matching alternative range from the recorded root" {
  jq '.peerDependencies.react = "^18.0.0 || ^19.0.0"' \
    "$PROJECT_A/package.json" > "$PROJECT_A/package-next.json"
  mv "$PROJECT_A/package-next.json" "$PROJECT_A/package.json"

  run_check

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 0 ]
}

@test "all patched brace-expansion branches are checked independently" {
  sed -i.bak 's/brace-expansion@2.1.2/brace-expansion@2.1.1/' "$PROJECT_A/pnpm-lock.yaml"

  run_check

  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings[] | select(.type == "security-floor" and .package == "brace-expansion" and .resolved == "2.1.1" and .minimum == "2.1.2")' >/dev/null
}

@test "expired exceptions fail even when dependency versions match" {
  jq '.exceptions = [{id:"expired",project:"repo-a",workspace:".",ecosystem:"npm",package:"foo",reason:"fixture",owner:"platform",replacement_condition:"remove fixture",expires_on:"2026-07-20"}]' \
    "$FIXTURE_COPY/baseline.json" > "$FIXTURE_COPY/baseline-expired.json"
  mv "$FIXTURE_COPY/baseline-expired.json" "$FIXTURE_COPY/baseline.json"

  run_check

  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings[] | select(.type == "expired-exception" and .exception == "expired")' >/dev/null
}

@test "snapshot discovers shared direct dependencies from available local worktrees" {
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" snapshot \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --ref worktree \
    --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.packages[] | select(.ecosystem == "npm" and .name == "foo")' >/dev/null
  printf '%s' "$output" | jq -e '.packages[] | select(.ecosystem == "pypi" and .name == "fastapi")' >/dev/null
}

@test "fleet selection never reads a same-machine worktree from another fleet" {
  work_project="$SANDBOX/work volume/work only"
  mkdir -p "$work_project"
  make_repo "$work_project" work-only
  register_project work work-only "$work_project"

  run_check

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.projects[].fleet] | unique')" = '["personal"]' ]

  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet work \
    --ref worktree \
    --today 2026-07-21 \
    --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.projects[0].root')" = "$work_project" ]
}

@test "an explicitly unavailable selected project fails before fetch" {
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" snapshot \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project offline \
    --fetch \
    --ref origin/main

  [ "$status" -eq 1 ]
  [[ "$output" == *"project is not eligible for dependency evaluation in local fleet personal: offline"* ]] || { echo "$output"; false; }
  [[ "$output" == *"availability unavailable"* ]] || { echo "$output"; false; }
}

@test "a selected fleet must exist in validated local machine state" {
  write_machine_config personal

  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" snapshot \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet work \
    --ref worktree

  [ "$status" -eq 2 ]
  [[ "$output" == *"selected fleet is not configured locally: work"* ]] || { echo "$output"; false; }
}

@test "retired tracked registry options cannot re-enter the normal path" {
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --registry "$FIXTURE_COPY/registry.md"

  [ "$status" -eq 2 ]
  [[ "$output" == *"--registry is no longer supported"* ]] || { echo "$output"; false; }
}

@test "terminal ledger rows require evidence and risk dispositions require expiry metadata" {
  run node "$CLI" ledger-check --ledger "$FIXTURE_COPY/ledger-valid.json" --today 2026-07-21
  [ "$status" -eq 0 ]

  jq '.findings[0].evidence = [] | .findings[0].disposition = "accepted-risk"' \
    "$FIXTURE_COPY/ledger-valid.json" > "$FIXTURE_COPY/ledger-invalid.json"
  run node "$CLI" ledger-check --ledger "$FIXTURE_COPY/ledger-invalid.json" --today 2026-07-21
  [ "$status" -eq 1 ]
  [[ "$output" == *"terminal disposition requires evidence"* ]] || { echo "$output"; false; }
  [[ "$output" == *"accepted-risk requires owner"* ]] || { echo "$output"; false; }
}

@test "public validator source carries no maintainer-specific absolute path" {
  # `grep`, not `rg`: ripgrep is not on a stock ubuntu runner, and an absent
  # binary exits 127 — which is not 1, so the case failed for the one reason it
  # was never about. A literal `grep -F` answers exactly the same question with a
  # tool every host has.
  run grep -nF '/Users/'"abhishek" "$CLI"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "artifact-writing commands refuse to persist state derived from a drifted registry" {
  rm -rf "$PROJECT_B/.git"

  # `snapshot` and `ledger-sync` used to end in a hard exit 0, so a class-4
  # registry state error disappeared at exactly the point where the derived file
  # gets written. Refuse the write and carry the class.
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" snapshot \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --ref worktree \
    --output "$SANDBOX/baseline-out.json"

  [ "$status" -eq 4 ]
  [[ "$output" == *"STATE-ERROR personal/repo-b"* ]] || { echo "$output"; false; }
  [[ "$output" == *"refusing to write a dependency baseline"* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/baseline-out.json" ]

  # --json suppressed the row report, so the refusal names the rows itself.
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" ledger-sync \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --ledger "$FIXTURE_COPY/ledger-valid.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --ref worktree \
    --json \
    --output "$SANDBOX/ledger-out.json"

  [ "$status" -eq 4 ]
  [[ "$output" == *"STATE-ERROR personal/repo-b"* ]] || { echo "$output"; false; }
  [[ "$output" == *"refusing to write a remediation ledger"* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/ledger-out.json" ]
}

@test "an unregistered project selector still reports a drifted sibling row" {
  rm -rf "$PROJECT_B/.git"

  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project no-such-project \
    --ref worktree \
    --today 2026-07-21
  # A mistyped selector must not discard the state errors already computed.
  [ "$status" -eq 4 ]
  [[ "$output" == *"STATE-ERROR personal/repo-b"* ]] || { echo "$output"; false; }
  [[ "$output" == *"project is not registered in local fleet personal: no-such-project"* ]] || { echo "$output"; false; }

  # A clean registry keeps the plain usage class for the same typo.
  git -C "$PROJECT_B" init -q -b main
  git -C "$PROJECT_B" config user.email fleet-dependencies@example.invalid
  git -C "$PROJECT_B" config user.name 'Fleet Dependencies'
  git -C "$PROJECT_B" add .
  git -C "$PROJECT_B" commit -q -m refixture
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project no-such-project \
    --ref worktree \
    --today 2026-07-21
  [ "$status" -eq 2 ]
}

@test "a registry state error outside the selection still reaches the exit class" {
  # repo-b's root stays present but stops resolving as a canonical Git worktree,
  # so its registry row lists as identity_error while repo-a stays healthy.
  rm -rf "$PROJECT_B/.git"

  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project repo-a \
    --ref worktree \
    --today 2026-07-21
  # The selected project is healthy and is still evaluated, but a corrupt
  # sibling row is a property of the REGISTRY: report it and carry class 4.
  [ "$status" -eq 4 ]
  [[ "$output" == *"STATE-ERROR personal/repo-b"* ]] || { echo "$output"; false; }

  # The selected project's OWN row failing identity validation is the same
  # state class, not the ordinary ineligible-selection exit 1.
  run env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project repo-b \
    --ref worktree \
    --today 2026-07-21
  [ "$status" -eq 4 ]
  [[ "$output" == *"availability identity_error"* ]] || { echo "$output"; false; }
}

@test "a JSON run names the rows that raised its exit class" {
  # `run --separate-stderr` keeps $output as pure stdout: the child
  # `registry.sh list` writes its own per-row diagnostics to stderr, which would
  # otherwise be merged into the JSON this test parses.
  bats_require_minimum_version 1.5.0
  # repo-b's root stays present but stops resolving as a canonical Git worktree,
  # so its registry row lists as identity_error while repo-a stays healthy.
  rm -rf "$PROJECT_B/.git"

  # `--json` suppresses the stderr row reports, so a scoped JSON run exited 4
  # while the only machine-readable artifact it produced named nothing wrong.
  # `state_errors` carries exactly the rows that raised the class, whether or
  # not the selector included them.
  run --separate-stderr env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" check \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project repo-a \
    --ref worktree \
    --json \
    --today 2026-07-21
  [ "$status" -eq 4 ] || { echo "$output"; echo "$stderr"; false; }
  printf '%s\n' "$output" | jq -e '
    (.state_errors | length) == 1
    and .state_errors[0].project == "repo-b"
    and .state_errors[0].availability == "identity_error"
  ' >/dev/null

  # `apply --json` carries the same field: it is the other machine-output path
  # that exits on `findingsExit`.
  run --separate-stderr env TRELLIS_HOME="$TRELLIS_HOME" node "$CLI" apply \
    --baseline "$FIXTURE_COPY/baseline.json" \
    --home "$TRELLIS_HOME" \
    --fleet personal \
    --project repo-a \
    --ref worktree \
    --json \
    --today 2026-07-21
  [ "$status" -eq 4 ] || { echo "$output"; echo "$stderr"; false; }
  printf '%s\n' "$output" | jq -e '
    (.state_errors | length) == 1 and .state_errors[0].project == "repo-b"
  ' >/dev/null
}
