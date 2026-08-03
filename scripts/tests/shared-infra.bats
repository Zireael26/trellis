#!/usr/bin/env bats
# Trellis delegation coverage for the shared local infrastructure contract.
# Every mutating subject is confined to a fresh sandbox fixture.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/shared-infra"
CONFIG_LOADER="$REPO_ROOT/scripts/lib/config-load.sh"
ONBOARD="$REPO_ROOT/scripts/onboard-project.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  SHARED="$SANDBOX/shared-infra"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  mkdir -p "$SHARED" "$PROJECTS"
  cp -R "$FIXTURE_ROOT/." "$SHARED/"
  rm -f "$SHARED/calls.log" "$SHARED/drift" "$SHARED/occupied-port"
  export TRELLIS_CONFIG="$CFG"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

write_config() {
  local shared_root="${1:-$SHARED}"
  local trellis_root="${2:-$REPO_ROOT}"
  local shared_line=""
  if [ "$shared_root" != "__ABSENT__" ]; then
    shared_line="  \"shared_infra_root\": \"$shared_root\","
  fi
  cat > "$CFG" <<EOF
{
  "trellis_root": "$trellis_root",
  "projects_root": "$PROJECTS",
$shared_line
  "user_home": "$SANDBOX",
  "maintainer_name": "Fixture Maintainer",
  "github_user": "fixture-user",
  "harnesses": ["claude"]
}
EOF
}

copy_repository() {
  copy_repository_as "$1" "$1"
}

copy_repository_as() {
  local source_name="$1" target_name="$2"
  cp -R "$FIXTURE_ROOT/repositories/$source_name" "$PROJECTS/$target_name"
  (
    cd "$PROJECTS/$target_name" || exit 1
    git init -q -b main
    git config user.email "fixture@example.com"
    git config user.name "fixture"
    git config commit.gpgsign false
  )
}

build_registry_canonical() {
  FIXTURE_CANON="$SANDBOX/canonical"
  mkdir -p "$FIXTURE_CANON"
  ln -s "$REPO_ROOT/core-rules" "$FIXTURE_CANON/core-rules"
  cp "$FIXTURE_ROOT/registry.md" "$FIXTURE_CANON/registry.md"
}

run_onboard() {
  run env TRELLIS_CONFIG="$CFG" TRELLIS_SKIP_SECURITY_BASELINE=1 \
    bash "$ONBOARD" "$@"
}

sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

@test "config loader exports a canonical shared infrastructure directory" {
  write_config
  run bash -c '. "$1"; printf "shared=%s\n" "$SHARED_INFRA_ROOT"' _ "$CONFIG_LOADER"
  [ "$status" -eq 0 ]
  [ "$output" = "shared=$SHARED" ]
}

@test "config loader leaves shared infrastructure disabled when the optional key is absent" {
  write_config __ABSENT__
  run bash -c '. "$1"; printf "shared=%s\n" "${SHARED_INFRA_ROOT:-}"' _ "$CONFIG_LOADER"
  [ "$status" -eq 0 ]
  [ "$output" = "shared=" ]
}

@test "config loader fails clearly when the configured shared directory is missing" {
  local missing="$SANDBOX/missing-shared-infra"
  write_config "$missing"
  run bash -c '. "$1"' _ "$CONFIG_LOADER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared_infra_root not a directory: $missing"* ]]
}

@test "config loader rejects a configured empty shared infrastructure path" {
  write_config
  jq '.shared_infra_root = ""' "$CFG" > "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
  run bash -c '. "$1"' _ "$CONFIG_LOADER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared_infra_root"* ]]
}

@test "proposal mode delegates repository discovery and leaves projects.yaml byte-identical" {
  copy_repository no-service
  write_config
  local before after
  before="$(sha_of "$SHARED/projects.yaml")"

  run_onboard "$PROJECTS/no-service"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  after="$(sha_of "$SHARED/projects.yaml")"
  [ "$before" = "$after" ]
  [[ "$output" == *"proposal for no-service"* ]]
  grep -F "propose PROJECT=no-service SOURCE=$PROJECTS/no-service" "$SHARED/calls.log"
  run grep -q '^register ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
  [ -x "$PROJECTS/no-service/scripts/local-infra-preflight.sh" ]
  grep -F 'PROJECT_NAME="no-service"' "$PROJECTS/no-service/scripts/local-infra-preflight.sh"
}

@test "registry path mapping supplies the manifest key when repository basename differs" {
  copy_repository_as compose-app compose-checkout
  build_registry_canonical
  write_config "$SHARED" "$FIXTURE_CANON"

  run_onboard "$PROJECTS/compose-checkout"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -F "propose PROJECT=compose-app SOURCE=$PROJECTS/compose-checkout" "$SHARED/calls.log"
  grep -F 'PROJECT_NAME="compose-app"' "$PROJECTS/compose-checkout/scripts/local-infra-preflight.sh"
}

@test "unconfigured shared infrastructure preserves legacy onboarding for non-manifest repository names" {
  copy_repository_as no-service Legacy_Project
  write_config __ABSENT__

  run_onboard "$PROJECTS/Legacy_Project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -e "$PROJECTS/Legacy_Project/gotchas.md" ]
  [ ! -e "$PROJECTS/Legacy_Project/scripts/local-infra-preflight.sh" ]
  [ ! -e "$SHARED/calls.log" ]
}

@test "reviewed fragment replaces exactly one project entry and revalidates the candidate manifest" {
  copy_repository no-service
  write_config
  local entry="$SANDBOX/no-service-entry.yaml"
  cat > "$entry" <<'EOF'
services:
  redis:
    databases:
      - index: 12
        prefix: "no-service:"
ports:
  app: [4700]
EOF

  run_onboard "$PROJECTS/no-service" --infra-entry "$entry"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^  no-service:$' "$SHARED/projects.yaml")" -eq 1 ]
  grep -F 'prefix: "no-service:"' "$SHARED/projects.yaml"
  grep -F "register PROJECT=no-service ENTRY=$entry" "$SHARED/calls.log"
  grep -E '^validate PROJECT=no-service PROJECTS_FILE=.*\.tmp\.[0-9]+$' "$SHARED/calls.log"
  grep -F 'reconcile PROJECT=no-service' "$SHARED/calls.log"
  run grep -q '^propose ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

@test "induced registration validation failure preserves the original manifest and writes no project seeds" {
  copy_repository no-service
  write_config
  local entry="$SANDBOX/invalid-entry.yaml"
  cat > "$entry" <<'EOF'
services: INVALID
ports: {}
EOF
  local before after
  before="$(sha_of "$SHARED/projects.yaml")"

  run_onboard "$PROJECTS/no-service" --infra-entry="$entry"
  [ "$status" -ne 0 ]
  [[ "$output" == *"registration failed; no Trellis project files were written"* ]]

  after="$(sha_of "$SHARED/projects.yaml")"
  [ "$before" = "$after" ]
  [ ! -e "$PROJECTS/no-service/gotchas.md" ]
  [ ! -e "$PROJECTS/no-service/scripts/local-infra-preflight.sh" ]
  grep -F "register PROJECT=no-service ENTRY=$entry" "$SHARED/calls.log"
  grep -E '^validate PROJECT=no-service PROJECTS_FILE=.*\.tmp\.[0-9]+$' "$SHARED/calls.log"
  run grep -q '^reconcile ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

@test "one-argument reruns stay idempotent for an already-declared project" {
  copy_repository package-app
  write_config
  local manifest_before wrapper_before
  manifest_before="$(sha_of "$SHARED/projects.yaml")"

  run_onboard "$PROJECTS/package-app"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  wrapper_before="$(sha_of "$PROJECTS/package-app/scripts/local-infra-preflight.sh")"

  run_onboard "$PROJECTS/package-app"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"skip (exists): scripts/local-infra-preflight.sh"* ]]
  [ "$(sha_of "$SHARED/projects.yaml")" = "$manifest_before" ]
  [ "$(sha_of "$PROJECTS/package-app/scripts/local-infra-preflight.sh")" = "$wrapper_before" ]
  [ "$(grep -c '^propose PROJECT=package-app ' "$SHARED/calls.log")" -eq 2 ]
  run grep -q '^register ' "$SHARED/calls.log"
  [ "$status" -ne 0 ]
}

@test "seeded preflight wrapper is cwd-independent, honors override and baked configured root, and propagates occupied-port failure" {
  copy_repository no-service
  write_config
  run_onboard "$PROJECTS/no-service"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local wrapper="$PROJECTS/no-service/scripts/local-infra-preflight.sh"
  local override="$SANDBOX/override-shared-infra"
  mkdir -p "$SANDBOX/elsewhere" "$override"
  cp "$FIXTURE_ROOT/Makefile" "$override/Makefile"
  cp "$FIXTURE_ROOT/projects.yaml" "$override/projects.yaml"
  grep -F "CONFIGURED_SHARED_INFRA_ROOT=\"$SHARED\"" "$wrapper"

  run bash -c 'cd "$1"; SHARED_INFRA_ROOT="$2" "$3"' _ \
    "$SANDBOX/elsewhere" "$override" "$wrapper"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -F 'preflight PROJECT=no-service' "$override/calls.log"

  run env -u SHARED_INFRA_ROOT HOME="$SANDBOX/unrelated-home" bash -c 'cd "$1"; "$2"' _ \
    "$SANDBOX/elsewhere" "$wrapper"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -F 'preflight PROJECT=no-service' "$SHARED/calls.log"

  touch "$SHARED/occupied-port"
  run env -u SHARED_INFRA_ROOT bash -c 'cd "$1"; "$2"' _ \
    "$SANDBOX/elsewhere" "$wrapper"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declared port occupied for no-service"* ]]
}

@test "onboarding rejects malformed infrastructure arguments before writing" {
  copy_repository no-service
  write_config

  run_onboard "$PROJECTS/no-service" --infra-entry
  [ "$status" -eq 2 ]
  [ ! -e "$PROJECTS/no-service/gotchas.md" ]

  run_onboard "$PROJECTS/no-service" --unknown
  [ "$status" -eq 2 ]

  run_onboard "$PROJECTS/no-service" extra-positional
  [ "$status" -eq 2 ]

  local entry="$SANDBOX/entry.yaml"
  printf 'services: {}\nports: {}\n' > "$entry"
  run env TRELLIS_CONFIG="$CFG" TRELLIS_SKIP_SECURITY_BASELINE=1 TRELLIS_SKIP_INFRA=1 \
    bash "$ONBOARD" "$PROJECTS/no-service" --infra-entry "$entry"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be combined with TRELLIS_SKIP_INFRA=1"* ]]
}

@test "discovery fixtures cover Compose env Make package Firebase ambiguous and no-service inputs" {
  [ -f "$FIXTURE_ROOT/repositories/compose-app/compose.yaml" ]
  [ -f "$FIXTURE_ROOT/repositories/compose-app/.env.example" ]
  [ -f "$FIXTURE_ROOT/repositories/ambiguous/compose.yaml" ]
  [ -f "$FIXTURE_ROOT/repositories/ambiguous/.env.example" ]
  [ -f "$FIXTURE_ROOT/repositories/make-app/Makefile" ]
  [ -f "$FIXTURE_ROOT/repositories/package-app/package.json" ]
  [ -f "$FIXTURE_ROOT/repositories/firebase-app/firebase.json" ]
  [ -f "$FIXTURE_ROOT/repositories/no-service/README.md" ]
  run grep -Eq 'REDIS_(DB|INDEX)=|BUCKET(_NAME)?=' "$FIXTURE_ROOT/repositories/ambiguous/.env.example"
  [ "$status" -ne 0 ]
}
