#!/usr/bin/env bats

@test "registry jq controls reject C1 without changing attachment path semantics" {
  python3 -I - "$BATS_TEST_DIRNAME/../lib/attachment_fs.py" \
    "$BATS_TEST_DIRNAME/../lib/registry_identity_batch.py" "$BATS_TEST_TMPDIR" <<'PY'
import importlib.util
import os
import sys

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

fs = load('attachment_fs', sys.argv[1])
registry = load('registry_identity_batch', sys.argv[2])
for code in (*range(32), *range(127, 160)):
    assert fs.has_jq_controls('/tmp/a' + chr(code) + 'b'), code
for code in (32, 126, 160):
    assert not fs.has_jq_controls('/tmp/a' + chr(code) + 'b'), code
assert not fs.has_controls(chr(0x85))
path = os.path.realpath(sys.argv[3]) + '/c1-\u0085'
os.mkdir(path)
assert fs.canonical_dir(path)
assert not registry.canonical(fs, path)
PY
  path="$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]) + "/c1-\u0085")' "$BATS_TEST_TMPDIR")"
  run bash -c '. "$1"; local_registry_real_directory "worktree root" "$2"' \
    _ "$BATS_TEST_DIRNAME/../lib/local-registry.sh" "$path"
  [ "$status" -eq 2 ]
  [[ "$output" == *'terminal control characters'* ]]
}
