#!/usr/bin/env bats
# Trellis delegation coverage for the shared local infrastructure contract.
# Every mutating subject is confined to a fresh sandbox fixture.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FIXTURE_ROOT="$BATS_TEST_DIRNAME/fixtures/shared-infra"
CONFIG_LOADER="$REPO_ROOT/scripts/lib/config-load.sh"
ONBOARD="$REPO_ROOT/scripts/onboard-project.sh"
load helpers/portable-config

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  SHARED="$SANDBOX/shared-infra"
  PROJECTS="$SANDBOX/projects"
  CFG="$SANDBOX/trellis.config.json"
  LOCAL_HOME="$SANDBOX/.trellis"
  POLICY_SOURCE="$SANDBOX/policy-source"
  mkdir -p "$SHARED" "$PROJECTS" "$LOCAL_HOME" "$POLICY_SOURCE"
  chmod 700 "$LOCAL_HOME"
  cp -R "$FIXTURE_ROOT/." "$SHARED/"
  rm -f "$SHARED/calls.log" "$SHARED/drift" "$SHARED/occupied-port"
  export TRELLIS_CONFIG="$CFG"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

# --- fixture for the PORTABLE loader (tests 1-4) ----------------------------
# Spec 036 split configuration in two: tracked policy carries no machine paths,
# and shared_infra_root now lives per-fleet in $TRELLIS_HOME/config.json. The
# loader contracts these tests pin are unchanged in substance — they just read
# from machine state now — so they are re-pointed rather than deleted.
#
# The fixture itself is the shared one onboard-project.bats already models
# (helpers/portable-config.bash), not a second copy of the same schema.
# `__ABSENT__` still means "the optional key is not configured".
write_portable_config() {
  portable_config_write "$CFG" "$POLICY_SOURCE" "$LOCAL_HOME/config.json" \
    "$PROJECTS" "${1:-$SHARED}"
}

load_portable_config() {
  run env HOME="$SANDBOX" TRELLIS_HOME="$LOCAL_HOME" TRELLIS_CONFIG="$CFG" \
    bash -c "$1" _ "$CONFIG_LOADER"
}

# --- fixture for LEGACY onboarding (tests 5-12) -----------------------------
# The shared-infrastructure delegation lives entirely in onboard's `--legacy`
# branch, which reads the machine-local config shape directly. Keep it.
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
  # `--legacy` explicitly selects the direct-link/shared-infra compatibility
  # command; the unflagged spelling is now portable onboarding, which delegates
  # to attach and has no shared-infrastructure step at all.
  run env TRELLIS_CONFIG="$CFG" TRELLIS_SKIP_SECURITY_BASELINE=1 \
    bash "$ONBOARD" --legacy "$@"
}

sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

@test "config loader exports a canonical shared infrastructure directory" {
  write_portable_config
  load_portable_config '. "$1"; printf "shared=%s|%s\n" "$SHARED_INFRA_ROOT" "$SHARED_INFRA_ROOT_AVAILABLE"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "shared=$SHARED|1" ]
}

@test "config loader leaves shared infrastructure disabled when the optional key is absent" {
  write_portable_config __ABSENT__
  load_portable_config '. "$1"; printf "shared=%s|%s\n" "${SHARED_INFRA_ROOT:-}" "${SHARED_INFRA_ROOT_AVAILABLE:-}"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "shared=|0" ]
}

# Original intent: a configured-but-missing shared root must never be mistaken
# for a usable one. Spec 036 changed the MECHANISM from "abort the load" to
# "load, but report the root unavailable" — unavailability is per-fleet local
# state now, not a fatal policy error — so the assertion pins that distinction
# instead of the old exit code.
@test "config loader reports a missing configured shared directory as unavailable" {
  local missing="$SANDBOX/missing-shared-infra"
  write_portable_config "$missing"
  load_portable_config '. "$1"; printf "shared=%s|%s\n" "$SHARED_INFRA_ROOT" "$SHARED_INFRA_ROOT_AVAILABLE"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "shared=$missing|0" ]
  load_portable_config '. "$1"; printf "%s\n" "$TRELLIS_FLEET_LOCAL_JSON"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e --arg missing "$missing" '
    .shared_infra_root.configured_path == $missing
    and .shared_infra_root.available == false
    and .shared_infra_root.canonical_path == null' >/dev/null
}

# Original intent: an empty configured shared root must be REJECTED, never
# quietly read as "not configured". Spec 036 moved the key into machine state,
# so the rejection is now the machine schema's — the assertions below pin both
# halves: the specific diagnostic the rewritten fixture shape actually
# produces, and the contract that diagnostic guards (empty ≠ absent). A bare
# `status -ne 0` would pass on any unrelated fixture breakage.
@test "config loader rejects a configured empty shared infrastructure path" {
  write_portable_config

  # Control: unmutated, this exact fixture loads and reports the root usable.
  # Without it, the rejection below could be the fixture failing, not the key.
  load_portable_config '. "$1"; printf "shared=%s|%s\n" "$SHARED_INFRA_ROOT" "$SHARED_INFRA_ROOT_AVAILABLE"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "shared=$SHARED|1" ]

  jq '.fleets.personal.shared_infra_root = ""' "$LOCAL_HOME/config.json" > "$LOCAL_HOME/config.json.tmp"
  mv "$LOCAL_HOME/config.json.tmp" "$LOCAL_HOME/config.json"
  chmod 600 "$LOCAL_HOME/config.json"
  load_portable_config '. "$1"'
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"machine config failed schema-aware validation: $LOCAL_HOME/config.json"* ]] \
    || { echo "$output"; false; }

  # The contract the rejection guards: an empty string is NOT the absent key.
  # Absent means "shared infrastructure is not configured" and loads fine.
  write_portable_config __ABSENT__
  load_portable_config '. "$1"; printf "shared=%s|%s\n" "${SHARED_INFRA_ROOT:-}" "${SHARED_INFRA_ROOT_AVAILABLE:-}"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "shared=|0" ]
}

# ---------------------------------------------------------------------------
# Cutover (v1.0.0-rc.25): shared-infrastructure REGISTRATION is withdrawn.
#
# The seven cases replaced here drove `onboard-project.sh --legacy` and proved
# what the `--infra-entry` flow did: proposal mode, registry path mapping,
# reviewed-fragment replacement, induced validation failure, rerun idempotence,
# the seeded preflight wrapper, and argument rejection. That flow lived entirely
# inside the direct-link writer, which the cutover removed, so none of it has a
# subject any more.
#
# This is a deliberate capability gap, not an oversight: plan.md §4.4 row 73
# routes the shared-infra contract to its own dependency-ordered PR, and this
# machine currently configures no `shared_infra_root` at all. Re-hosting
# registration on the portable attach path is tracked as a follow-up.
#
# What remains under test here is what still has a subject: the config loader's
# per-fleet shared-infra resolution (above), the legacy reader's tilde branch
# (below), the discovery fixtures, and — immediately here — the refusal, so a
# reintroduction of the writer cannot pass unnoticed.
# ---------------------------------------------------------------------------

@test "shared-infrastructure registration refuses with the writer that hosted it" {
  copy_repository no-service
  write_config
  local before
  before="$(sha_of "$SHARED/projects.yaml")"

  run_onboard "$PROJECTS/no-service"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare"* ]] || { echo "$output"; false; }

  # No delegation reached the shared repository, and its manifest is untouched.
  [ ! -e "$SHARED/calls.log" ]
  [ "$(sha_of "$SHARED/projects.yaml")" = "$before" ]
  # No project-side artifact was seeded either.
  [ ! -e "$PROJECTS/no-service/scripts/local-infra-preflight.sh" ]
  [ ! -e "$PROJECTS/no-service/gotchas.md" ]
}

@test "--infra-entry refuses before reading the entry file or touching the manifest" {
  copy_repository no-service
  write_config
  local entry="$SANDBOX/entry.yml"
  printf 'services: {}
' > "$entry"
  local before
  before="$(sha_of "$SHARED/projects.yaml")"

  run env TRELLIS_CONFIG="$CFG" TRELLIS_SKIP_SECURITY_BASELINE=1 \
    bash "$ONBOARD" --infra-entry "$entry" "$PROJECTS/no-service"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [ ! -e "$SHARED/calls.log" ]
  [ "$(sha_of "$SHARED/projects.yaml")" = "$before" ]
}

# The legacy reader's tilde branch. doctor.sh historically wrote
# `${raw_shared#~/}` UNQUOTED, so bash tilde-expanded the word and the strip
# targeted a "$HOME/" prefix — a no-op on a value beginning with a literal
# `~/`, which resolved `~/name` to "$USER_HOME/~/name" and failed the directory
# guard. Consumers need a real directory (`make -C`, Makefile presence), so pin
# the literal strip. The control half pins that the absolute form — what every
# real legacy config carries — resolves to the same place, unchanged.
@test "legacy reader expands a tilde-form shared_infra_root against user_home" {
  local reader="$REPO_ROOT/scripts/lib/legacy-config.sh"
  local probe='. "$1"; legacy_config_read fixture "$TRELLIS_CONFIG" || exit "$?"
    printf "%s\n" "$SHARED_INFRA_ROOT"'

  write_config "~/$(basename "$SHARED")"
  run env TRELLIS_CONFIG="$CFG" HOME="$SANDBOX/unrelated-home" \
    bash -c "$probe" _ "$reader"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$SHARED" ]

  write_config "$SHARED"
  run env TRELLIS_CONFIG="$CFG" HOME="$SANDBOX/unrelated-home" \
    bash -c "$probe" _ "$reader"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$SHARED" ]
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
