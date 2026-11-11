#!/usr/bin/env bats
# Exercise the real paired publisher; only release-store lookup/outer
# verification are stubbed, while the publisher verifies its fixture bytes.

setup() {
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  CASE_BASH="${TRELLIS_TRAP_CASE_BASH:-/bin/bash}"
  export HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis"
  RELEASE="$TRELLIS_HOME/releases/1.5.0"
  mkdir -p "$HOME/.local/bin" "$RELEASE/payload/scripts" "$RELEASE/payload/core-rules/native"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  cp "$ROOT/scripts/trellis-launcher.sh" "$RELEASE/payload/scripts/trellis-launcher.sh"
  python3 -I - "$RELEASE" <<'PY'
import hashlib, json, os, platform, sys
from pathlib import Path
r = Path(sys.argv[1]); payload = r / 'payload'
# Choose an asset for a different OS, so this fixture tests the real launcher
# and ledger publication without pretending to qualify a signed native asset.
target = 'x86_64-unknown-linux-musl' if platform.system() == 'Darwin' else 'aarch64-apple-darwin'
manifest = {'schema_version': 1, 'version': '1.5.0', 'source_commit': '',
            'generation': '', 'inputs': {}, 'toolchain': {},
            'install_path': 'bin/native/{version}/{target}/{sha256}/trellis-hooks',
            'adapter': {}, 'assets': {target: {}}}
(payload / 'core-rules/native/artifacts.json').write_text(json.dumps(manifest))
rows = []
for name in ('scripts/trellis-launcher.sh', 'core-rules/native/artifacts.json'):
    path = payload / name; data = path.read_bytes()
    oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    rows.append({'path': name, 'oid': oid,
                 'mode': '100755' if os.stat(path).st_mode & 0o111 else '100644'})
(r / 'release.json').write_text(json.dumps({'version': '1.5.0', 'tree': rows}))
PY
}

publish_pair() {
  run "$CASE_BASH" --noprofile --norc -c '
    . "$1/scripts/lib/trellis-home.sh"
    release_store_locate() { printf "%s/releases/%s\n" "$TRELLIS_HOME" "$1"; }
    release_store_verify_path() { return 0; }
    trellis_home_install_launcher "$2/payload/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis" "$TRELLIS_HOME" 1.5.0
  ' _ "$ROOT" "$RELEASE"
}

@test "paired publisher accepts a plain file and publishes the launcher" {
  publish_pair
  [ "$status" -eq 0 ] || { echo "plain publisher: $status $output"; return 1; }
  [ -x "$HOME/.local/bin/trellis" ]
}

@test "Darwin paired publisher refuses a real ACL on a pair file" {
  [ "$(uname -s)" = Darwin ] || skip 'real chmod +a fixture requires macOS'
  chmod +a 'everyone allow read' "$RELEASE/payload/scripts/trellis-launcher.sh"
  publish_pair
  [ "$status" -eq 4 ] || { echo "ACL file publisher: $status $output"; return 1; }
  [[ "$output" == *'ACL on pair entry'* ]]
  [ ! -e "$HOME/.local/bin/trellis" ]
}

@test "Darwin paired publisher refuses a real ACL on the destination directory" {
  [ "$(uname -s)" = Darwin ] || skip 'real chmod +a fixture requires macOS'
  chmod +a 'everyone allow add_file' "$HOME/.local/bin"
  publish_pair
  [ "$status" -eq 4 ] || { echo "ACL directory publisher: $status $output"; return 1; }
  [[ "$output" == *'ACL on pair entry'* ]]
  [ ! -e "$HOME/.local/bin/trellis" ]
}

@test "Darwin ACL result and free errors fail closed in the publisher" {
  run python3 -I "$ROOT/scripts/tests/helpers/native-pair-acl-cases.py" "$ROOT/scripts/lib/trellis-home.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
