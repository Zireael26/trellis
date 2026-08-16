#!/usr/bin/env bats
# Focused T24 machine-home library contracts (plan file 91, criteria SC1/SC8/SC9).
#
# `configure.bats` drives scripts/configure.sh and `config-load.bats` drives the
# consumer side. Neither exercises scripts/lib/trellis-home.sh resolution and
# atomic-write primitives directly, so this suite owns:
#   * the TRELLIS_HOME precedence ladder, including the operator-home default;
#   * home paths carrying spaces;
#   * mode enforcement (0700 directories, 0600 machine config);
#   * corrupt/hostile local state fails closed and preserves prior bytes.
#
# Fixtures are file-local on purpose: this suite owns no shared helper.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
HOME_LIB="$REPO_ROOT/scripts/lib/trellis-home.sh"
VALID_MACHINE_A="$REPO_ROOT/scripts/tests/fixtures/local-fleets/valid-machine-personal-work-a.json"
VALID_MACHINE_B="$REPO_ROOT/scripts/tests/fixtures/local-fleets/valid-machine-personal-work-b.json"

th_canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

th_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

th_sha256() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

# Bare `[[ ]]` is vacuous when it is not the final command of a Bats test on
# this host, so every glob assertion in this file is guarded.
th_contains() {
  case "$2" in
    *"$1"*) return 0 ;;
  esac
  printf 'expected to contain %s:\n%s\n' "$1" "$2" >&2
  return 1
}

# Run one library function in a clean shell with an explicit environment. Every
# call names the whole environment it wants so precedence is never ambient.
th_lib() {
  local call="$1"
  shift
  run env -i \
    PATH="$PATH" \
    TMPDIR="${TMPDIR:-/tmp}" \
    HOME="${TH_ENV_HOME-}" \
    TRELLIS_HOME="${TH_ENV_TRELLIS_HOME-}" \
    TRELLIS_FLEET="${TH_ENV_FLEET-}" \
    TRELLIS_RELEASE="${TH_ENV_RELEASE-}" \
    TRELLIS_SOURCE_ROOT="${TH_ENV_SOURCE_ROOT-}" \
    /bin/bash -c '. "$1"; shift; "$@"' trellis-home "$HOME_LIB" "$call" "$@"
}

th_clear_env() {
  TH_ENV_HOME=""
  TH_ENV_TRELLIS_HOME=""
  TH_ENV_FLEET=""
  TH_ENV_RELEASE=""
  TH_ENV_SOURCE_ROOT=""
}

# A machine config the schema-aware validator accepts, written by hand so the
# test controls its bytes and mode.
th_write_config() {
  local destination="$1" fixture="${2:-$VALID_MACHINE_A}"
  cp "$fixture" "$destination"
  chmod 600 "$destination"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/trellis-home.XXXXXX")"
  SANDBOX="$(th_canonical_dir "$SANDBOX")"
  OPERATOR_HOME="$SANDBOX/operator home with spaces"
  SPACED_HOME="$SANDBOX/machine state/trellis home with spaces"
  mkdir -p "$OPERATOR_HOME"
  th_clear_env
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

# GAP: no suite exercised trellis_home_resolve, so the documented ladder
# (explicit argument > TRELLIS_HOME > $HOME/.trellis) and the missing-HOME
# refusal had no executable oracle.
@test "home resolution prefers an explicit argument, then TRELLIS_HOME, then the operator home" {
  local explicit="$SANDBOX/explicit home with spaces"
  local from_env="$SANDBOX/environment home with spaces"

  TH_ENV_HOME="$OPERATOR_HOME"
  TH_ENV_TRELLIS_HOME="$from_env"
  th_lib trellis_home_resolve "$explicit"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = "$explicit" ]

  th_lib trellis_home_resolve ""
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = "$from_env" ]

  TH_ENV_TRELLIS_HOME=""
  th_lib trellis_home_resolve ""
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = "$OPERATOR_HOME/.trellis" ]

  # Neither an explicit home nor TRELLIS_HOME nor HOME: a usage refusal, not a
  # guess at some machine-wide default.
  TH_ENV_HOME=""
  th_lib trellis_home_resolve ""
  [ "$status" -eq 2 ]
  th_contains 'HOME is required when TRELLIS_HOME is not set' "$output"
}

# GAP: TRELLIS_HOME candidates were validated only indirectly through
# configure.sh flags. The resolver itself must refuse every unsafe shape with
# the shared class-2 vocabulary.
@test "home resolution refuses relative, ambiguous, traversing, root, and control-character homes" {
  TH_ENV_HOME="$OPERATOR_HOME"

  th_lib trellis_home_resolve "relative/trellis"
  [ "$status" -eq 2 ]
  th_contains 'must be an absolute path' "$output"

  # An unexpanded tilde is exactly the literal a caller must not have accepted.
  # shellcheck disable=SC2088
  th_lib trellis_home_resolve '~/.trellis'
  [ "$status" -eq 2 ]
  th_contains 'must be an absolute path' "$output"

  th_lib trellis_home_resolve "//double/slash/trellis"
  [ "$status" -eq 2 ]
  th_contains 'ambiguous double-slash path' "$output"

  th_lib trellis_home_resolve "$SANDBOX/./trellis"
  [ "$status" -eq 2 ]
  th_contains 'must not contain . or .. path components' "$output"

  th_lib trellis_home_resolve "$SANDBOX/parent/../trellis"
  [ "$status" -eq 2 ]
  th_contains 'must not contain . or .. path components' "$output"

  th_lib trellis_home_resolve "/"
  [ "$status" -eq 2 ]
  th_contains 'must not be the filesystem root' "$output"

  th_lib trellis_home_resolve "$SANDBOX/tab"$'\t'"home"
  [ "$status" -eq 2 ]
  th_contains 'contains terminal control characters' "$output"

  th_lib trellis_home_resolve "$SANDBOX/escape"$'\033'"home"
  [ "$status" -eq 2 ]
  th_contains 'contains terminal control characters' "$output"

  # An unsafe TRELLIS_HOME in the environment is refused on the same terms as
  # an unsafe explicit argument, so no caller inherits a bad home silently.
  TH_ENV_TRELLIS_HOME=$'/tmp/newline\nhome'
  th_lib trellis_home_resolve ""
  [ "$status" -eq 2 ]
  th_contains 'contains terminal control characters' "$output"
}

# GAP: every existing home-permission case ran under a space-free path, and no
# case covered trellis_home_atomic_write_json at all.
@test "a space-bearing home is prepared 0700 and its machine config is written 0600, sorted, and idempotently" {
  local config="$SPACED_HOME/config.json" proposal="$SANDBOX/proposal with spaces.json"
  local first_hash second_hash

  TH_ENV_HOME="$OPERATOR_HOME"
  th_lib trellis_home_prepare_home "$SPACED_HOME"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(th_mode "$SPACED_HOME")" = 700 ]
  [ "$(th_mode "$SPACED_HOME/locks")" = 700 ]
  [ "$(th_mode "$SPACED_HOME/state")" = 700 ]
  [ "$(th_mode "$SPACED_HOME/releases")" = 700 ]

  # A world-readable proposal must not become a world-readable machine config.
  cp "$VALID_MACHINE_A" "$proposal"
  chmod 644 "$proposal"
  th_lib trellis_home_atomic_write_json "$config" "$proposal"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(th_mode "$config")" = 600 ]
  [ "$(th_mode "$proposal")" = 644 ]
  jq -e '.default_fleet == "personal" and (.fleets | has("work"))' "$config" >/dev/null

  # jq -S output: keys are sorted, so the same proposal always yields the same
  # bytes and a re-write is a no-op an operator can diff.
  [ "$(jq -r 'keys_unsorted | join(",")' "$config")" = "$(jq -r 'keys | join(",")' "$config")" ]
  first_hash="$(th_sha256 "$config")"
  th_lib trellis_home_atomic_write_json "$config" "$proposal"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  second_hash="$(th_sha256 "$config")"
  [ "$first_hash" = "$second_hash" ]

  # No temporary sibling survives a successful write.
  [ "$(find "$SPACED_HOME" -maxdepth 1 -name '.config.json.tmp.*' | wc -l | tr -d ' ')" = 0 ]

  # A loosened mode is repaired by validation rather than tolerated.
  chmod 666 "$config"
  th_lib trellis_home_validate_config "$config"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(th_mode "$config")" = 600 ]
  [ "$(th_sha256 "$config")" = "$first_hash" ]
}

# GAP: nothing proved that a rejected machine-config write leaves the previous
# machine state byte-identical and drops its temporary sibling.
@test "a rejected machine config write preserves the previous bytes and leaves no temporary sibling" {
  local config="$SPACED_HOME/config.json" proposal="$SANDBOX/proposal.json"
  local good_hash

  TH_ENV_HOME="$OPERATOR_HOME"
  th_lib trellis_home_prepare_home "$SPACED_HOME"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  th_write_config "$config"
  good_hash="$(th_sha256 "$config")"

  printf '{ not json\n' > "$proposal"
  th_lib trellis_home_atomic_write_json "$config" "$proposal"
  [ "$status" -eq 4 ]
  th_contains 'refusing to write invalid JSON' "$output"
  [ "$(th_sha256 "$config")" = "$good_hash" ]

  jq '.unexpected_machine_field = true' "$VALID_MACHINE_A" > "$proposal"
  th_lib trellis_home_atomic_write_json "$config" "$proposal"
  [ "$status" -eq 4 ]
  th_contains 'failed schema-aware validation' "$output"
  [ "$(th_sha256 "$config")" = "$good_hash" ]

  jq '.fleets.personal.discovery_roots = ["relative/projects"]' "$VALID_MACHINE_A" > "$proposal"
  th_lib trellis_home_atomic_write_json "$config" "$proposal"
  [ "$status" -eq 4 ]
  [ "$(th_sha256 "$config")" = "$good_hash" ]

  jq --arg root $'/tmp/control\troot' \
    '.fleets.personal.discovery_roots = [$root]' "$VALID_MACHINE_A" > "$proposal"
  th_lib trellis_home_atomic_write_json "$config" "$proposal"
  [ "$status" -eq 4 ]
  [ "$(th_sha256 "$config")" = "$good_hash" ]

  # Every rejected attempt cleaned up after itself.
  [ "$(find "$SPACED_HOME" -maxdepth 1 -name '.config.json.tmp.*' | wc -l | tr -d ' ')" = 0 ]
  [ "$(th_mode "$config")" = 600 ]

  # The store still accepts a valid replacement afterwards.
  th_lib trellis_home_atomic_write_json "$config" "$VALID_MACHINE_B"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(jq -r '.default_fleet' "$config")" = work ]
}

# GAP: hostile local state at the home level (a file where the home belongs, a
# symlinked home, a symlinked config) had no coverage; a silent recreate here
# would move an operator's whole machine inventory.
@test "corrupt or hostile local home state fails closed without following or replacing a symlink" {
  local file_home="$SANDBOX/home that is a file"
  local real_home="$SANDBOX/real home" link_home="$SANDBOX/linked home"
  local outside="$SANDBOX/outside config.json" config

  TH_ENV_HOME="$OPERATOR_HOME"

  printf 'not a directory\n' > "$file_home"
  th_lib trellis_home_prepare_home "$file_home"
  [ "$status" -eq 4 ]
  th_contains 'must be a directory' "$output"
  [ -f "$file_home" ]
  [ "$(cat "$file_home")" = 'not a directory' ]

  mkdir -p "$real_home"
  ln -s "$real_home" "$link_home"
  th_lib trellis_home_prepare_home "$link_home"
  [ "$status" -eq 4 ]
  th_contains 'must not be a symlink' "$output"
  [ ! -e "$real_home/locks" ]
  [ ! -e "$real_home/state" ]
  [ ! -e "$real_home/releases" ]

  # A symlinked config destination is a refusal, and the symlink target keeps
  # its bytes: an atomic write must never follow a link out of the home.
  th_lib trellis_home_prepare_home "$SPACED_HOME"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  config="$SPACED_HOME/config.json"
  printf 'operator sentinel\n' > "$outside"
  ln -s "$outside" "$config"
  th_lib trellis_home_atomic_write_json "$config" "$VALID_MACHINE_A"
  [ "$status" -eq 4 ]
  th_contains 'refusing to replace symlinked machine config' "$output"
  [ -L "$config" ]
  [ "$(cat "$outside")" = 'operator sentinel' ]

  th_lib trellis_home_validate_config "$config"
  [ "$status" -eq 4 ]
  th_contains 'must not be a symlink' "$output"
  [ "$(cat "$outside")" = 'operator sentinel' ]
}

# GAP: the fleet/release/source-root resolvers had no direct coverage, so
# neither their precedence nor their refusal to fall back past corrupt machine
# state was pinned.
@test "fleet, release, and source-root resolution honor precedence and refuse to read past corrupt state" {
  local config="$SPACED_HOME/config.json" source_root="$SANDBOX/policy source with spaces"

  TH_ENV_HOME="$OPERATOR_HOME"
  th_lib trellis_home_prepare_home "$SPACED_HOME"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  th_write_config "$config"
  mkdir -p "$source_root/core-rules"
  printf '{}\n' > "$source_root/trellis.config.json"
  printf '9.9.9\n' > "$source_root/core-rules/VERSION"

  # Explicit argument wins over the environment, which wins over the config.
  TH_ENV_FLEET=environment-fleet
  th_lib trellis_home_resolve_fleet explicit-fleet "$config"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = explicit-fleet ]
  th_lib trellis_home_resolve_fleet "" "$config"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = environment-fleet ]
  TH_ENV_FLEET=""
  th_lib trellis_home_resolve_fleet "" "$config"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = personal ]

  # An invalid fleet name is a usage refusal at every layer.
  th_lib trellis_home_resolve_fleet 'Not A Fleet' "$config"
  [ "$status" -eq 2 ]

  TH_ENV_RELEASE=2.0.0
  th_lib trellis_home_resolve_release 3.0.0 "$config" "$source_root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = 3.0.0 ]
  th_lib trellis_home_resolve_release "" "$config" "$source_root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = 2.0.0 ]
  TH_ENV_RELEASE=""
  th_lib trellis_home_resolve_release "" "$config" "$source_root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = 1.0.0-rc.24 ]
  # Only with no config does the source checkout's VERSION become the answer.
  th_lib trellis_home_resolve_release "" "" "$source_root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = 9.9.9 ]
  th_lib trellis_home_resolve_release 'not-semver' "$config" "$source_root"
  [ "$status" -eq 2 ]
  th_contains 'is not SemVer' "$output"

  TH_ENV_SOURCE_ROOT="$source_root"
  th_lib trellis_home_resolve_source_root "" "$config"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$output" = "$source_root" ]
  TH_ENV_SOURCE_ROOT=""
  # The configured source root does not exist on this machine: unavailable, not
  # a silent fallback to some other checkout.
  th_lib trellis_home_resolve_source_root "" "$config"
  [ "$status" -eq 5 ]
  th_contains 'source root is not a directory' "$output"
  # Present but not a policy checkout is corrupt state, not unavailable.
  th_lib trellis_home_resolve_source_root "$SANDBOX" "$config"
  [ "$status" -eq 4 ]
  th_contains 'does not look like a Trellis policy checkout' "$output"

  # Corrupt machine config: every resolver refuses class 4 instead of falling
  # through to its own default.
  printf '{ corrupt\n' > "$config"
  chmod 600 "$config"
  th_lib trellis_home_resolve_fleet "" "$config"
  [ "$status" -eq 4 ]
  th_lib trellis_home_resolve_release "" "$config" "$source_root"
  [ "$status" -eq 4 ]
  th_lib trellis_home_resolve_source_root "" "$config"
  [ "$status" -eq 4 ]
  # Even an explicit argument does not excuse reading a corrupt machine config.
  th_lib trellis_home_resolve_fleet explicit-fleet "$config"
  [ "$status" -eq 4 ]
}
