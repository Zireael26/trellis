#!/usr/bin/env bats
# Attach and detach run Python programs that load attachment_fs.py by path from
# the payload. An installed payload is read-only, but a source checkout is not
# (a maintainer tree, the qualification runtime clone), and Python caches the
# bytecode of a file-loaded module beside its source unless told not to. Both
# must leave a writable checkout byte for byte as they found it.

REAL_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture
load helpers/detach-journal

setup() {
  unset PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX
  BASE="$(release_fixture_canonical_dir "$BATS_TEST_TMPDIR")"
  CHECKOUT="$BASE/writable checkout"
  mkdir -p "$CHECKOUT"
  cp -R "$REAL_ROOT/scripts" "$REAL_ROOT/core-rules" "$CHECKOUT/"
  # Start from a tree without caches, whatever the source tree holds.
  find "$CHECKOUT" -name __pycache__ -prune -exec rm -rf {} +
  # The fixture and the attach under test both run from the writable copy.
  REPO_ROOT="$CHECKOUT"
}

teardown() {
  chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

@test "attach and detach from a writable checkout leave no Python bytecode in it" {
  detach_journal_build "$BASE/sandbox"
  run find "$CHECKOUT" \( -name __pycache__ -o -name '*.pyc' \) -print
  [ -z "$output" ] || { printf 'attach wrote bytecode into the checkout:\n%s\n' "$output"; false; }
  run "$CHECKOUT/scripts/attach-project.sh" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME/state/attachments" ] || [ -z "$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json')" ] ||
    { echo 'detach left an owner record'; false; }
  run find "$CHECKOUT" \( -name __pycache__ -o -name '*.pyc' \) -print
  [ -z "$output" ] || { printf 'detach wrote bytecode into the checkout:\n%s\n' "$output"; false; }
}
