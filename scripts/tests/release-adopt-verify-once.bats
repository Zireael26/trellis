#!/usr/bin/env bats
# 1.5.1 perf: `release adopt` verifies each release once per adoption.
#
# release_store_locate is always captured with $(...), so the per-shell verify
# memo it records died with the capture and every payload_for/locate in one
# adoption re-ran the full release verify (eight full verifies of the same
# release per one-row adopt, ~67 of 95 s at large-checkout scale in bundle mode). The memo
# is the existing, documented one (release-store.sh): keyed on this shell's $$,
# the canonical release dir and sha256(release.json); the ACL refusal still
# runs on every call. These cases pin the count, and that a release changed
# after the first verify is still verified again and refused.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# shellcheck source=helpers/release-fixture.bash
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"

setup_file() {
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/prototype"
  mkdir -p "$RELEASE_FIXTURE_PROTOTYPE"
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$RELEASE_FIXTURE_PROTOTYPE")"
  export RELEASE_FIXTURE_PROTOTYPE
  release_fixture_prototype_build "$RELEASE_FIXTURE_PROTOTYPE"
}

teardown_file() {
  chmod -R u+w "$RELEASE_FIXTURE_PROTOTYPE" 2>/dev/null || true
  rm -rf "$RELEASE_FIXTURE_PROTOTYPE"
}

setup() {
  export TRELLIS_ATTACH_POSTJOB=off
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/adopt-verify-once.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  HOME="$SANDBOX/user"
  TRELLIS_HOME="$SANDBOX/trellis"
  PROJECT="$SANDBOX/project"
  export HOME TRELLIS_HOME
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"adopt-verify-once"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm initial
  LAUNCHER="$HOME/.local/bin/trellis"
  PAYLOAD="$TRELLIS_HOME/releases/9.9.9/payload"
  BODY_LOG="$SANDBOX/verify-body.log"
  : > "$BODY_LOG"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

# Run `release adopt` from the installed payload's release.sh with the full
# release verify body counted. TRELLIS_RELEASE_BUNDLE_PRELOAD only defines the
# command; the entry gate still requires the installed payload path.
run_counted_adopt() {
  run env TRELLIS_RELEASE_CLEAN_ENV=1 TRELLIS_RELEASE_BUNDLE_PRELOAD=1 \
    TRELLIS_VERIFIED_PAYLOAD="$PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=9.9.9 \
    VERIFY_BODY_LOG="$BODY_LOG" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)")" \
    bash --noprofile --norc -c '
      . "$1/scripts/release.sh" || exit 90
      # The launcher bundle that runs `trellis release` carries no stamp program,
      # so there every locate is a full verify unless the memo answers.
      unset -f release_stamp_check
      definition="$(declare -f release_store_verify_path_body)" || exit 91
      eval "${definition/release_store_verify_path_body /real_release_store_verify_path_body }"
      release_store_verify_path_body() {
        printf "%s\n" "$1" >> "$VERIFY_BODY_LOG"
        real_release_store_verify_path_body "$@"
      }
      shift
      release_command_main "$@"
    ' _ "$PAYLOAD" adopt 9.9.9 --project adopt-verify-once
}

attach_project() {
  run "$LAUNCHER" attach --fleet personal "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "release adopt runs the full release verify once for the one release it adopts" {
  attach_project
  run_counted_adopt
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  count="$(grep -c '/releases/9.9.9$' "$BODY_LOG" || true)"
  echo "# full verifies of 9.9.9 during adopt: $count" >&3
  [ "$count" -eq 1 ] || { cat "$BODY_LOG"; false; }
  [ "$(readlink "$PROJECT/.trellis/runtime")" = "$PAYLOAD" ] || false
}

@test "release adopt still refuses a release whose payload drifts after it was verified" {
  attach_project
  # A drifted payload file under the release refuses the adopt: the memo never
  # answers for a first verify, and the warm verify that fails is repeated by
  # the per-row call, which reports it.
  chmod u+w "$PAYLOAD/scripts" "$PAYLOAD/scripts/trellis"
  printf '# drift\n' >> "$PAYLOAD/scripts/trellis"
  run_counted_adopt
  [ "$status" -ne 0 ] || { echo "$output"; false; }
}
