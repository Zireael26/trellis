#!/usr/bin/env bats
# An unreadable claim namespace is not evidence that it is empty.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/attachment.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-claims.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$SANDBOX/parent"
  printf '%s\n' '{"removal":null}' > "$SANDBOX/journal.json"
}

shell_check() {
  bash -c '. "$1"; _attachment_claim_namespace_valid "$2" "$3"' _ \
    "$LIB" "$SANDBOX/journal.json" "$SANDBOX/parent/artifact"
}

python_check() {
  python3 -I - "$LIB" "$SANDBOX/parent/artifact" <<'PY'
import os
import sys

with open(sys.argv[1], encoding='utf-8') as f:
    source = f.read()
start = source.index('def claim_namespace_valid(path, removal):')
end = source.index('\n\nclass Commit(object):', start)
namespace = {'os': os, 'REMOVE_PREFIX': '.trellis-attachment-remove-'}
exec(compile(source[start:end], sys.argv[1], 'exec'), namespace)
sys.exit(0 if namespace['claim_namespace_valid'](sys.argv[2], None) else 1)
PY
}

@test "shell claim guard refuses an unreadable parent and a foreign claim" {
  run shell_check
  [ "$status" -eq 0 ]
  mkdir "$SANDBOX/parent/.trellis-attachment-remove-foreign"
  run shell_check
  [ "$status" -ne 0 ]
  rmdir "$SANDBOX/parent/.trellis-attachment-remove-foreign"
  chmod 311 "$SANDBOX/parent"
  run shell_check
  rc="$status"
  chmod 700 "$SANDBOX/parent"
  [ "$rc" -ne 0 ] || { echo 'unreadable namespace accepted'; false; }
}

@test "Python claim guard refuses an unreadable parent and a foreign claim" {
  run python_check
  [ "$status" -eq 0 ]
  mkdir "$SANDBOX/parent/.trellis-attachment-remove-foreign"
  run python_check
  [ "$status" -ne 0 ]
  rmdir "$SANDBOX/parent/.trellis-attachment-remove-foreign"
  chmod 311 "$SANDBOX/parent"
  run python_check
  rc="$status"
  chmod 700 "$SANDBOX/parent"
  [ "$rc" -ne 0 ] || { echo 'unreadable namespace accepted'; false; }
}
