#!/usr/bin/env bats
# Spec 055 R2.7 / A2.6: doctor WARNs when an owner record holds a control-only
# toolchain (pushes from that worktree are refused) and when the installed
# launcher is not byte-identical to the active release's launcher (caller PATH
# forwarding is then not guaranteed). Both rows are silent when healthy.
#
# Runs the real portable doctor against an isolated TRELLIS_HOME and account
# HOME; nothing outside the mktemp sandbox is read or written.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/t14-worktree

setup() {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  ACCOUNT_HOME="$T14_SANDBOX/account home"
  mkdir -p "$ACCOUNT_HOME/.local/bin" "$T14_SANDBOX/real-bin"
  REAL_BIN="$(t14_canonical_dir "$T14_SANDBOX/real-bin")"
  jq -n --arg root "$T14_SANDBOX" --arg source "$T14_SANDBOX/release source" '{
    schema_version: 1,
    source_root: $source,
    release_remote: "fixture://t14",
    active_cli_release: "1.2.3",
    default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$root]}}
  }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  run env TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_ATTACH_CALLER_PATH="$REAL_BIN:/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/attach-project.sh" attach \
    --home "$TRELLIS_HOME" --fleet personal --release "$T14_RELEASE" "$T14_PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  OWNER="$(t14_owner_for_root "$T14_PROJECT")"
  PAYLOAD_LAUNCHER="$TRELLIS_HOME/releases/$T14_RELEASE/payload/scripts/trellis-launcher.sh"
  cp "$PAYLOAD_LAUNCHER" "$ACCOUNT_HOME/.local/bin/trellis"
  chmod 755 "$ACCOUNT_HOME/.local/bin/trellis"
}

teardown() {
  t14_teardown_sandbox
}

run_doctor() {
  run env -u TRELLIS_CONFIG HOME="$ACCOUNT_HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    bash "$REPO_ROOT/scripts/doctor.sh"
}

# The row loop must actually have reached this worktree, or silence proves nothing.
assert_row_reached() {
  printf '%s\n' "$output" | grep -F 'git hook authority:' >/dev/null ||
    { printf 'doctor never reached the attached worktree row\n%s\n' "$output"; false; }
}

refute_line_containing() {
  if printf '%s\n' "$output" | grep -F "$1" >/dev/null; then
    printf 'unexpected row: %s\n%s\n' "$1" "$output"
    false
  fi
}

@test "doctor is silent for a real toolchain record and an identical launcher" {
  run_doctor
  assert_row_reached
  refute_line_containing 'toolchain provenance'
  refute_line_containing 'launcher currency'
}

@test "doctor WARNs for a control-only toolchain record and names the refresh remedy" {
  jq -cS '.toolchain_path = ["/usr/bin","/bin","/usr/sbin","/sbin"]' "$OWNER" > "$T14_SANDBOX/owner.next"
  mv -f "$T14_SANDBOX/owner.next" "$OWNER"
  chmod 600 "$OWNER"
  cp -p "$OWNER" "$T14_SANDBOX/owner.before"
  run_doctor
  assert_row_reached
  printf '%s\n' "$output" | grep -F '⚠ toolchain provenance: the recorded toolchain is the sanitized control PATH' >/dev/null ||
    { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -F 'trellis attach --refresh-toolchain' >/dev/null ||
    { printf '%s\n' "$output"; false; }
  cmp "$OWNER" "$T14_SANDBOX/owner.before"
  refute_line_containing 'launcher currency'
}

@test "doctor WARNs for an installed launcher that differs from the active release's" {
  printf '# local edit\n' >> "$ACCOUNT_HOME/.local/bin/trellis"
  run_doctor
  printf '%s\n' "$output" | grep -F '⚠ launcher currency: the installed launcher' >/dev/null ||
    { printf '%s\n' "$output"; false; }
  refute_line_containing 'toolchain provenance'
}

@test "doctor WARNs when no launcher is installed" {
  rm "$ACCOUNT_HOME/.local/bin/trellis"
  run_doctor
  printf '%s\n' "$output" | grep -F '⚠ launcher currency: the installed launcher' >/dev/null ||
    { printf '%s\n' "$output"; false; }
}
