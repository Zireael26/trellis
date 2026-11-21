#!/usr/bin/env bats
# Locale-independent helper behavior is pinned to the original C-locale oracle.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

@test "migrated helpers match original C behavior for ASCII Unicode and invalid bytes" {
  run python3 -I -B -X utf8 "$REPO_ROOT/scripts/tests/helpers/locale-helper-equivalence.py" \
    "$BASH" "$REPO_ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  echo "# $output" >&3
}

@test "passthrough enumeration propagates a failed external sort" {
  local work="$BATS_TEST_TMPDIR/sort-failure"
  mkdir -p "$work/bin" "$work/hooks"
  printf '%s\n' '#!/bin/sh' 'exit 47' > "$work/bin/sort"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$work/hooks/pre-commit"
  chmod +x "$work/bin/sort" "$work/hooks/pre-commit"
  run env TRELLIS_LIBS_PRELOADED=1 "$BASH" -c '
    . "$1/scripts/lib/attachment.sh"
    PATH="$2:$PATH"
    _attachment_hooks_expected_passthrough_names / "$3"
  ' _ "$REPO_ROOT" "$work/bin" "$work/hooks"
  [ "$status" -eq 47 ] || { printf '%s\n' "$output"; false; }
}
