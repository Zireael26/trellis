#!/usr/bin/env bats
# Focused SemVer regression tests for scripts/upgrade.sh.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SEMVER_LIB="$REPO/scripts/lib/semver.sh"
UPGRADE="$REPO/scripts/upgrade.sh"

setup() {
  # shellcheck source=../lib/semver.sh disable=SC1090
  . "$SEMVER_LIB"
}

make_verified_upgrade_fixture() {
  mkdir -p "$BATS_TEST_TMPDIR/home"
  UPGRADE_FIXTURE_HOME="$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)"
  UPGRADE_FIXTURE_PAYLOAD="$UPGRADE_FIXTURE_HOME/releases/1.2.3/payload"
  UPGRADE_FIXTURE_SCRIPT="$UPGRADE_FIXTURE_PAYLOAD/scripts/upgrade.sh"
  mkdir -p "$UPGRADE_FIXTURE_PAYLOAD/scripts"
  cp "$UPGRADE" "$UPGRADE_FIXTURE_SCRIPT"
  cat > "$UPGRADE_FIXTURE_PAYLOAD/scripts/release.sh" <<'EOF'
#!/bin/sh
exit 99
EOF
  chmod 755 "$UPGRADE_FIXTURE_SCRIPT" "$UPGRADE_FIXTURE_PAYLOAD/scripts/release.sh"
}

# Mirror the carrier the stable launcher emits for the upgrade route: preloaded
# libraries, a preloaded release command surface, then the upgrade body. The
# release surface here is a probe, so install, verify, and adopt are observed as
# in-process calls rather than as argv on an executed release-script pathname.
make_upgrade_bundle() {
  UPGRADE_BUNDLE="$BATS_TEST_TMPDIR/upgrade-bundle.sh"
  {
    printf '%s\n' \
      'TRELLIS_LIBS_PRELOADED=1' \
      'export TRELLIS_LIBS_PRELOADED' \
      'TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade' \
      'TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=bundle-token'
    cat <<'BUNDLE'
trellis_command_bundle_is_verified() {
  [ "$#" -eq 2 ] || return 1
  [ "$1" = "$TRELLIS_VERIFIED_COMMAND_BUNDLE" ] && [ "$2" = "$TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN" ]
}
case "${1:-}" in
  upgrade) shift ;;
  *) printf '%s\n' 'trellis: verified release bundle route mismatch' >&2; exit 2 ;;
esac
release_command_main() { printf '%s\n' "$*"; }
BUNDLE
    awk 'body { print } /^# -- trellis upgrade body --$/ { body = 1 }' "$UPGRADE"
  } > "$UPGRADE_BUNDLE"
}

run_upgrade_bundle() {
  run env -i \
    "HOME=$UPGRADE_FIXTURE_HOME" "TRELLIS_HOME=$UPGRADE_FIXTURE_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$UPGRADE_FIXTURE_PAYLOAD" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc -s -- upgrade "$@" < "$UPGRADE_BUNDLE"
}

# A release-store entry that is not the attested release: same store, same
# shape, different identity.
make_upgrade_payload_entry() {
  local entry="$1"
  local payload="$UPGRADE_FIXTURE_HOME/releases/$entry/payload"
  mkdir -p "$payload/scripts"
  cp "$UPGRADE" "$payload/scripts/upgrade.sh"
  chmod 755 "$payload/scripts/upgrade.sh"
  printf '%s\n' "$payload"
}

run_upgrade_bundle_with_payload() {
  local payload="$1" version="$2"
  shift 2
  run env -i \
    "HOME=$UPGRADE_FIXTURE_HOME" "TRELLIS_HOME=$UPGRADE_FIXTURE_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$payload" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=$version" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc -s -- upgrade "$@" < "$UPGRADE_BUNDLE"
}

# The launcher pipes the bundle into 'bash -s', so the command bodies are the
# shell's own unread stdin. Reproduce that carrier exactly, with an install
# step whose child drains descriptor 0.
make_stdin_consuming_upgrade_bundle() {
  UPGRADE_BUNDLE="$BATS_TEST_TMPDIR/upgrade-bundle-stdin.sh"
  {
    printf '%s\n' \
      'TRELLIS_LIBS_PRELOADED=1' \
      'export TRELLIS_LIBS_PRELOADED' \
      'TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade' \
      'TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=bundle-token'
    cat <<'BUNDLE'
trellis_command_bundle_is_verified() {
  [ "$#" -eq 2 ] || return 1
  [ "$1" = "$TRELLIS_VERIFIED_COMMAND_BUNDLE" ] && [ "$2" = "$TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN" ]
}
case "${1:-}" in
  upgrade) shift ;;
  *) printf '%s\n' 'trellis: verified release bundle route mismatch' >&2; exit 2 ;;
esac
release_command_main() {
  printf '%s\n' "$*"
  if [ "${1:-}" = install ]; then
    # Stands in for any release child that reads stdin (git prompting, a hook).
    /bin/cat > /dev/null
  fi
}
BUNDLE
    awk 'body { print } /^# -- trellis upgrade body --$/ { body = 1 }' "$UPGRADE"
  } > "$UPGRADE_BUNDLE"
}

run_piped_upgrade_bundle() {
  run env -i \
    "HOME=$UPGRADE_FIXTURE_HOME" "TRELLIS_HOME=$UPGRADE_FIXTURE_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$UPGRADE_FIXTURE_PAYLOAD" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "UPGRADE_BUNDLE=$UPGRADE_BUNDLE" \
    /bin/bash --noprofile --norc -c \
    '/bin/cat "$UPGRADE_BUNDLE" | /bin/bash --noprofile --norc -s -- "$@"' \
    trellis-upgrade-carrier upgrade "$@"
}

@test "numeric prerelease identifiers order rc.10 after rc.2" {
  run semver_compare 1.0.0-rc.10 1.0.0-rc.2
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run semver_compare 1.0.0-rc.10 1.0.0-rc.11
  [ "$status" -eq 0 ]
  [ "$output" = "-1" ]
}

@test "stable release orders after every prerelease of the same core" {
  run semver_compare 1.0.0 1.0.0-rc.999
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "SemVer prerelease identifier precedence follows numeric lexical and length rules" {
  [ "$(semver_compare 1.0.0-alpha.1 1.0.0-alpha.beta)" = "-1" ]
  [ "$(semver_compare 1.0.0-alpha.beta 1.0.0-beta)" = "-1" ]
  [ "$(semver_compare 1.0.0-beta.2 1.0.0-beta.11)" = "-1" ]
  [ "$(semver_compare 1.0.0-rc 1.0.0-rc.1)" = "-1" ]
}

@test "build metadata does not affect precedence" {
  run semver_compare 1.2.3-rc.1+build.7 1.2.3-rc.1+build.99
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "strict validator rejects leading zeroes and malformed prereleases" {
  # Negative assertions are written as `run` + explicit status checks on purpose:
  # a bare `! semver_is_valid ...` is exempt from errexit, so it can never fail the
  # test body no matter what the validator returns.
  for bad in 01.0.0 1.0.0-rc.01 1.0.0-; do
    run semver_is_valid "$bad"
    [ "$status" -ne 0 ] || { echo "semver_is_valid accepted malformed version: $bad"; false; }
  done

  run semver_is_valid v1.0.0-rc.11
  [ "$status" -eq 0 ] || { echo "semver_is_valid rejected valid version: v1.0.0-rc.11"; false; }
}

@test "semver_max ignores malformed tags and prefers stable over prerelease" {
  run bash -c '
    . "$1"
    printf "%s\n" \
      v1.0.0-rc.2 \
      v1.0.0-rc.11 \
      v1.0.0-rc.10 \
      v1.0.0 \
      v1.0.0-rc.01 \
      version-next \
      | semver_max
  ' _ "$SEMVER_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.0.0" ]
}

@test "upgrade rejects latest-tag checks and requires one named registry selector" {
  config="$BATS_TEST_TMPDIR/tracked-policy.json"
  printf '{"trellis_version":"1.0.0-rc.10"}\n' > "$config"
  before="$(shasum -a 256 "$config" | cut -d ' ' -f 1)"
  make_verified_upgrade_fixture

  run env TRELLIS_CONFIG="$config" TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" --check

  [ "$status" -eq 2 ]
  [[ "$output" == *'VERSION is required'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$config" | cut -d ' ' -f 1)" = "$before" ]

  run env TRELLIS_CONFIG="$config" TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --check

  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown upgrade option: --check'* ]] || { echo "$output"; false; }

  run env TRELLIS_CONFIG="$config" TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3

  [ "$status" -eq 2 ]
  [[ "$output" == *'upgrade requires --project, --fleet, or --all'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$config" | cut -d ' ' -f 1)" = "$before" ]
}

@test "upgrade rejects empty or repeated explicit release and adoption inputs before install" {
  make_verified_upgrade_fixture
  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" "" --all
  [ "$status" -eq 2 ]
  [[ "$output" == *'VERSION is required'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --remote= --all
  [ "$status" -eq 2 ]
  [[ "$output" == *'--remote requires URL'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --project= --all
  [ "$status" -eq 2 ]
  [[ "$output" == *'--project requires ID'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --fleet= --all
  [ "$status" -eq 2 ]
  [[ "$output" == *'--fleet requires NAME'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --remote https://example.invalid/a --remote=https://example.invalid/b --all
  [ "$status" -eq 2 ]
  [[ "$output" == *'upgrade accepts one --remote'* ]] || { echo "$output"; false; }
}

@test "verified upgrade bundle sends one named install, verification, and all-adoption in process" {
  make_verified_upgrade_fixture
  make_upgrade_bundle

  run_upgrade_bundle 1.2.3 --all

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = $'install 1.2.3\nverify 1.2.3\nadopt 1.2.3 --all' ]
}

@test "verified upgrade bundle carries remote, project, and fleet selection into adoption" {
  make_verified_upgrade_fixture
  make_upgrade_bundle

  run_upgrade_bundle 1.2.3 --remote https://example.invalid/policy.git --project acme --fleet "work fleet"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = $'install 1.2.3 --remote https://example.invalid/policy.git\nverify 1.2.3\nadopt 1.2.3 --project acme --fleet work fleet' ]
}

@test "verified upgrade bundle binds its payload to the attested release version" {
  local other snapshot foreign_snapshot ambiguous
  make_verified_upgrade_fixture
  make_upgrade_bundle

  # The sealed launcher snapshot of the attested release is the executed form.
  snapshot="$(make_upgrade_payload_entry ".tmp.1.2.3.exec.Ab3xY9")"
  run_upgrade_bundle_with_payload "$snapshot" 1.2.3 1.2.3 --all
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = $'install 1.2.3\nverify 1.2.3\nadopt 1.2.3 --all' ]

  # Another installed release is a well-formed single-component store entry and
  # must still be refused: it is not the release this bundle was attested for.
  other="$(make_upgrade_payload_entry 9.9.9)"
  run_upgrade_bundle_with_payload "$other" 1.2.3 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # A sealed snapshot of another release is refused for the same reason.
  foreign_snapshot="$(make_upgrade_payload_entry ".tmp.9.9.9.exec.Ab3xY9")"
  run_upgrade_bundle_with_payload "$foreign_snapshot" 1.2.3 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # A snapshot suffix is opaque but not free-form.
  other="$(make_upgrade_payload_entry ".tmp.1.2.3.exec.bad suffix")"
  run_upgrade_bundle_with_payload "$other" 1.2.3 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }

  # The version segment is delimiter-exact, not a prefix. Versions carry dots,
  # so a snapshot of release '1.2.3.exec.9' shares the entire
  # '.tmp.1.2.3.exec.' prefix with a snapshot of release 1.2.3, and its own
  # suffix is alphanumeric — it is only refusable when the segment between
  # '.tmp.' and '.exec.' is matched whole.
  ambiguous="$(make_upgrade_payload_entry ".tmp.1.2.3.exec.9.exec.Ab3xY9")"
  run_upgrade_bundle_with_payload "$ambiguous" 1.2.3 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
}

@test "verified upgrade bundle keeps verify and adopt when an install child drains stdin" {
  make_verified_upgrade_fixture
  make_stdin_consuming_upgrade_bundle

  run_piped_upgrade_bundle 1.2.3 --all

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Without a detached stdin the install child swallows this shell's own
  # unread source and verify/adopt never run at all.
  [ "$output" = $'install 1.2.3\nverify 1.2.3\nadopt 1.2.3 --all' ]
}

@test "verified upgrade bundle rejects a route that does not match its attestation" {
  make_verified_upgrade_fixture
  make_upgrade_bundle

  run env -i \
    "HOME=$UPGRADE_FIXTURE_HOME" "TRELLIS_HOME=$UPGRADE_FIXTURE_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$UPGRADE_FIXTURE_PAYLOAD" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc -s -- release 1.2.3 --all < "$UPGRADE_BUNDLE"
  [ "$status" -eq 2 ]
  [[ "$output" == *'verified release bundle route mismatch'* ]] || { echo "$output"; false; }
}

@test "pathname upgrade refuses release work without a verified command bundle" {
  make_verified_upgrade_fixture

  # The fixture release CLI exits 99 when executed by pathname, so a status of
  # 2 with this message is the proof that no release pathname ran.
  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'verified release execution is unavailable'* ]] || { echo "$output"; false; }

  # A forged bundle claim without the launcher attestation stays out of bundle mode.
  run env TRELLIS_HOME="$UPGRADE_FIXTURE_HOME" \
    TRELLIS_VERIFIED_PAYLOAD="$UPGRADE_FIXTURE_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3 \
    TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=forged \
    "$UPGRADE_FIXTURE_SCRIPT" 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'verified release execution is unavailable'* ]] || { echo "$output"; false; }
}

# The same carrier as run_upgrade_bundle, except TRELLIS_UPGRADE_SOURCE_DIR is
# also present in the environment — the state the bundle-mode predicate's first
# conjunct exists to refuse.
run_upgrade_bundle_with_source_dir() {
  local source_dir="$1"
  shift
  run env -i \
    "HOME=$UPGRADE_FIXTURE_HOME" "TRELLIS_HOME=$UPGRADE_FIXTURE_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$UPGRADE_FIXTURE_PAYLOAD" \
    "TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3" \
    "TRELLIS_UPGRADE_SOURCE_DIR=$source_dir" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc -s -- upgrade "$@" < "$UPGRADE_BUNDLE"
}

@test "a pathname bootstrap variable keeps a bundle-shaped environment out of bundle mode" {
  make_verified_upgrade_fixture
  make_upgrade_bundle

  # INVERSION TEST for the first conjunct of the bundle-mode predicate,
  # `[ -z "${TRELLIS_UPGRADE_SOURCE_DIR:-}" ]`. Every other conjunct is
  # satisfied here: the carrier really does export
  # TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade, really does define
  # trellis_command_bundle_is_verified, and the token really does match. Only
  # the source-dir conjunct separates this from a genuine launcher bundle, so
  # deleting it is the one edit this assertion can see.
  #
  # A pathname execution always exports TRELLIS_UPGRADE_SOURCE_DIR across its
  # own `env -i` boundary, so its presence means the bytes in this shell reached
  # it by some route other than the launcher's in-memory bundle. Bundle mode
  # would then take SCRIPT_DIR from TRELLIS_VERIFIED_PAYLOAD and run install,
  # verify, and adopt out of a preloaded release surface that no launcher
  # attested — which is exactly what must not happen.
  run_upgrade_bundle_with_source_dir "$UPGRADE_FIXTURE_PAYLOAD/scripts" 1.2.3 --all

  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'verified release execution is unavailable'* ]] || { echo "$output"; false; }
  # The discriminator: in bundle mode the preloaded release surface would have
  # echoed each command, so no release work may appear.
  [[ "$output" != *'install 1.2.3'* ]] || { echo 'ran release work outside bundle mode'; echo "$output"; false; }
  [[ "$output" != *'adopt 1.2.3'* ]] || { echo 'ran adoption outside bundle mode'; echo "$output"; false; }
}

@test "direct source upgrade bootstrap fails closed before mutable body execution" {
  local startup marker hostile_bin
  startup="$BATS_TEST_TMPDIR/hostile-startup"
  marker="$BATS_TEST_TMPDIR/hostile-ran"
  hostile_bin="$BATS_TEST_TMPDIR/hostile-bin"
  mkdir -p "$hostile_bin"
  cat > "$startup" <<EOF
/usr/bin/touch "$marker"
EOF
  cat > "$hostile_bin/awk" <<EOF
#!/bin/sh
/usr/bin/touch "$marker"
exit 99
EOF
  chmod 755 "$hostile_bin/awk"

  run /usr/bin/env -i \
    "HOME=$BATS_TEST_TMPDIR/home" "TRELLIS_HOME=$BATS_TEST_TMPDIR/home/.trellis" \
    "PATH=$hostile_bin" "HOSTILE_MARKER=$marker" \
    /bin/bash --noprofile --norc -c '
      umask() {
        /usr/bin/touch "$HOSTILE_MARKER"
        builtin umask "$@"
      }
      export -f umask
      BASH_ENV="$2"
      ENV="$2"
      export BASH_ENV ENV
      exec "$1" --check
    ' trellis-upgrade-hostile "$UPGRADE" "$startup"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
  [ ! -e "$marker" ]
}
