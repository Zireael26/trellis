#!/usr/bin/env bats

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/release-metadata.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}
teardown() { rm -rf "$SANDBOX"; }

check_metadata() {
  run python3 -I "$BATS_TEST_DIRNAME/test_release_metadata.py" "MetadataTests.$1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "metadata complete base audit and full green verdict narrow the exact class" { check_metadata test_complete_audit_and_green_base_narrow_exact_metadata; }
@test "metadata no full green base verdict runs full tests" { check_metadata test_no_green_base_never_narrows; }
@test "metadata incomplete and stale audits run full tests" { check_metadata test_incomplete_or_stale_audit_never_narrows; }
@test "metadata bad versions mixed paths modes deletion and hidden reverts run full tests" { check_metadata test_bad_version_mixed_mode_and_hidden_revert_never_narrow; }
@test "metadata changed tags or other refs invalidate the green base" { check_metadata test_changed_tag_or_other_ref_invalidates_base; }
@test "metadata trace parser records actual read opens not writes" { check_metadata test_file_open_parser_excludes_writes_and_keeps_metadata_and_tags; }
@test "metadata head helper cannot self-certify a mixed range (P2)" { check_metadata test_head_helper_cannot_self_certify_its_mixed_range; }
@test "metadata bash path floor survives a permissive base helper" { check_metadata test_bash_floor_rejects_mixed_range_even_if_base_helper_is_buggy; }
@test "metadata bash floor refuses merge-only changes even with a permissive helper" { check_metadata test_bash_floor_rejects_merge_only_changes_with_permissive_helper; }
@test "metadata dirty head helper cannot replace the frozen base helper" { check_metadata test_dirty_head_helper_cannot_replace_the_base_helper; }
@test "metadata base policy class executes only audited suites" { check_metadata test_base_side_class_runs_audited_tests_not_full_command; }
