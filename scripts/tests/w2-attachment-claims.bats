#!/usr/bin/env bats
# An unreadable claim namespace is not evidence that it is empty.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/attachment.sh"
FS_MODULE="$REPO_ROOT/scripts/lib/attachment_fs.py"

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
  # The one Python implementation, shared by the attach publisher and the
  # native detach program.
  python3 -I -B - "$FS_MODULE" "$SANDBOX/parent/artifact" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("attachment_fs", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.exit(0 if module.claim_namespace_valid(sys.argv[2], None) else 1)
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
