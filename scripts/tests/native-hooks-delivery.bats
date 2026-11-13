#!/usr/bin/env bats
# T6 owns the common/build section. Later lanes extend only their anchors.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  BUILD="$ROOT/scripts/build-native-hooks.sh"
  ASSETS="$ROOT/core-rules/native"
}

# BEGIN A3 T6 build and manifest
@test "native delivery: final asset bytes and closed manifest verify" {
  run bash "$BUILD" verify "$ASSETS"
  [ "$status" -eq 0 ]
}

# T72: the final 1.5.0 selection is exactly arm64 macOS and x86_64 Linux. No
# x86_64 macOS asset (D3, legacy path) and no aarch64 Linux asset (dropped,
# decisions-log 2026-11-09; T38 deferred), so those hosts take the complete
# legacy route; every listed asset is present at its manifest digest.
@test "native delivery: the final manifest selects exactly the 1.5.0 target set" {
  run jq -e '(.assets | keys) == ["aarch64-apple-darwin", "x86_64-unknown-linux-musl"]
    and (.assets | has("x86_64-apple-darwin") | not)
    and (.assets | has("aarch64-unknown-linux-musl") | not)' "$ASSETS/artifacts.json"
  [ "$status" -eq 0 ] || { jq -c '.assets | keys' "$ASSETS/artifacts.json"; return 1; }
  [ ! -e "$ASSETS/aarch64-unknown-linux-musl" ] && [ ! -e "$ASSETS/x86_64-apple-darwin" ]
  run python3 -I - "$ASSETS" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1]); manifest = json.loads((root / 'artifacts.json').read_text())
for target, entry in manifest['assets'].items():
    data = (root / entry['path']).read_bytes()
    assert entry['path'] == target + '/trellis-hooks', target
    assert (len(data), hashlib.sha256(data).hexdigest()) == (entry['size'], entry['sha256']), target
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "native delivery: T72 the final target set is the undeferred target cells, and every absent target cell is deferred" {
  run python3 -I - "$ASSETS/artifacts.json" "$ROOT/specs/074-fast-hooks/evidence/qualification-requirements.json" "$ROOT/specs/074-fast-hooks/evidence/qualification" <<'PY'
import json, pathlib, re, sys
manifest = set(json.loads(pathlib.Path(sys.argv[1]).read_text())['assets'])
policy = json.loads(pathlib.Path(sys.argv[2]).read_text()); evidence = pathlib.Path(sys.argv[3])
rows = {row['cell']: row for row in policy['deferred_cells']}
targeted = {cell['id']: cell for cell in policy['cells'] if cell['target']}
# Every manifest target is qualified by an undeferred native cell, and only those.
qualified = {cell['target'] for name, cell in targeted.items() if name not in rows and cell['route'] == 'native'}
assert manifest == qualified == {'aarch64-apple-darwin', 'x86_64-unknown-linux-musl'}, (manifest, qualified)
# Every target cell whose target the manifest leaves out is exactly a deferred cell.
absent = {name for name, cell in targeted.items() if cell['target'] not in manifest}
assert absent == set(rows) == {'x86_64-macos', 'aarch64-linux'}, (absent, set(rows))
assert policy['selection_only_target'] not in manifest and targeted['aarch64-linux']['target'] == policy['selection_only_target']
# Each deferred cell's own evidence file is its closed deferral block, equal to its row.
for name, row in rows.items():
    match = re.match(r'\s*```json\s*\n(.*?)\n```', (evidence / (name + '.md')).read_text(), re.S)
    block = json.loads(match[1])
    assert block == dict(schema='trellis-qualification-deferral/1', deferred=True, existing_proof=block['existing_proof'], **row), name
    assert block['existing_proof'] and row['task'] in targeted[name]['tasks'], name
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "native delivery: sources are excluded but runtime assets remain payload" {
  grep -qx 'native/' "$ROOT/core-rules/payload-exclude.txt"
  REPO_ROOT="$ROOT"
  source "$ROOT/scripts/tests/helpers/payload-fixture.bash"
  payload_fixture_source "$BATS_TEST_TMPDIR/source" 1.5.0
  repo="$BATS_TEST_TMPDIR/source"
  mkdir -p "$repo/native/src" "$repo/core-rules/native"
  printf source > "$repo/native/src/main.rs"
  printf '{}' > "$repo/core-rules/native/artifacts.json"
  printf 'native/\n' >> "$repo/core-rules/payload-exclude.txt"
  payload_fixture_git -C "$repo" add -A
  payload_fixture_git -C "$repo" commit -qm native
  commit="$(payload_fixture_git -C "$repo" rev-parse HEAD)"
  payload="$(payload_fixture_tool "$repo" "$commit")"
  payload_fixture_git -C "$repo" cat-file -e "$payload:core-rules/native/artifacts.json"
  run payload_fixture_git -C "$repo" cat-file -e "$payload:native"
  [ "$status" -ne 0 ]
}

@test "native delivery: packaging refuses missing source exclusion and runtime exclusion" {
  REPO_ROOT="$ROOT"
  source "$ROOT/scripts/tests/helpers/payload-fixture.bash"
  payload_fixture_source "$BATS_TEST_TMPDIR/source" 1.5.0
  repo="$BATS_TEST_TMPDIR/source"
  mkdir -p "$repo/native/src" "$repo/core-rules/native"
  printf source > "$repo/native/src/main.rs"
  printf '{}' > "$repo/core-rules/native/artifacts.json"
  payload_fixture_git -C "$repo" add -A
  payload_fixture_git -C "$repo" commit -qm native
  run payload_fixture_tool "$repo" HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"must exclude root native/"* ]] || false
  printf 'native/\ncore-rules/native/\n' >> "$repo/core-rules/payload-exclude.txt"
  payload_fixture_git -C "$repo" add -A
  payload_fixture_git -C "$repo" commit -qm exclude-runtime
  run payload_fixture_tool "$repo" HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"drop native runtime assets"* ]] || false
}

@test "native delivery: release store refuses unfiltered native payload but accepts legacy" {
  mkdir -p "$BATS_TEST_TMPDIR/payload/native" "$BATS_TEST_TMPDIR/payload/core-rules/native"
  run bash -c '. "$1/scripts/lib/release-store.sh"; release_store_assert_native_payload_layout "$2"' _ "$ROOT" "$BATS_TEST_TMPDIR/payload"
  [ "$status" -eq 0 ]
  printf '{}' > "$BATS_TEST_TMPDIR/payload/core-rules/native/artifacts.json"
  run bash -c '. "$1/scripts/lib/release-store.sh"; release_store_assert_native_payload_layout "$2"' _ "$ROOT" "$BATS_TEST_TMPDIR/payload"
  [ "$status" -eq 4 ]
  rmdir "$BATS_TEST_TMPDIR/payload/native"
  run bash -c '. "$1/scripts/lib/release-store.sh"; release_store_assert_native_payload_layout "$2"' _ "$ROOT" "$BATS_TEST_TMPDIR/payload"
  [ "$status" -eq 0 ]
}

@test "native delivery: install refuses an unfiltered native-bearing tag before publication" {
  REPO_ROOT="$ROOT"
  source "$ROOT/scripts/tests/helpers/payload-fixture.bash"
  repo="$BATS_TEST_TMPDIR/source"
  payload_fixture_source "$repo" 1.5.0
  mkdir -p "$repo/native/src" "$repo/core-rules/native"
  printf source > "$repo/native/src/main.rs"
  printf '{}' > "$repo/core-rules/native/artifacts.json"
  payload_fixture_git -C "$repo" add -A
  payload_fixture_git -C "$repo" commit -qm unfiltered-native
  payload_fixture_tag "$repo" 1.5.0 HEAD
  mkdir -m 700 "$BATS_TEST_TMPDIR/trellis"
  run env TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" bash -c \
    '. "$1/scripts/lib/release-store.sh"; release_store_install 1.5.0 "$2"' _ "$ROOT" "$repo"
  [ "$status" -eq 4 ]
  [[ "$output" == *"native-bearing payload contains root build sources"* ]] || false
  [ ! -e "$BATS_TEST_TMPDIR/trellis/releases/1.5.0" ]
}

@test "native delivery: runtime adapter is inline production code without hidden dependencies" {
  run python3 -I - "$ASSETS/hook-adapter.sh" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); text=p.read_text()
assert 'Sealed native guard adapter' in text, 'missing production runtime header'
assert 'TEST-ONLY' not in text and 'prototype' not in text.lower(), 'prototype runtime header'
body='\n'.join(line for line in text.splitlines() if not line.startswith('#'))
assert "'" not in body, 'inline single-quote contract'
assert '/usr/bin/env -i' in body, 'missing sanitized execution'
for forbidden in ('hook-adapter.sh', 'launcher.sh', 'eval ', 'source ', '.sh ', '$0'):
    assert forbidden not in body, ('hidden runtime dependency', forbidden)
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# Structural verifier units: synthetic bytes are never executed. On Mac only
# codesign is mocked, so these are not Linux execution/signing qualifications.
synthetic_manifest_case() {
  python3 -I - "$ROOT" "$BATS_TEST_TMPDIR" "$1" <<'PY'
import contextlib,io,json,pathlib,platform,sys
from unittest.mock import patch
root=pathlib.Path(sys.argv[1]); case=sys.argv[3]
base=pathlib.Path(sys.argv[2])/('synthetic-assets-'+case.replace('/','_').replace(':','_'))
source=(root/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1]
definitions=source.split('\ntry:\n    args = sys.argv[2:]',1)[0]
assert definitions != source, 'missing build-script definition boundary'
ns={'__name__':'native_verifier_fixture'}
exec(compile(definitions,'build-native-hooks.sh','exec'),ns)
sha=ns['sha']; verify=ns['verify']
base.mkdir()
elf=bytearray(120); elf[:6]=b'\x7fELF\x02\x01'
elf[18:20]=(62).to_bytes(2,'little')
elf[32:40]=(64).to_bytes(8,'little')
elf[54:56]=(56).to_bytes(2,'little'); elf[56:58]=(1).to_bytes(2,'little')
elf[64:68]=(1).to_bytes(4,'little')
inputs={'native/trellis-hooks/Cargo.lock':sha(b'lock'),
        'native/trellis-hooks/rust-toolchain.toml':sha(b'toolchain'),
        'scripts/build-native-hooks.sh':sha(b'build')}
d=dict(schema_version=1,version=ns['VERSION'],source_commit='1'*40,inputs=inputs,
       toolchain=dict(channel='1.97.1',rustc='rustc 1.97.1 (8bab26f4f 2026-07-14)',
                      cargo_lock_sha256=inputs['native/trellis-hooks/Cargo.lock'],
                      rust_toolchain_sha256=inputs['native/trellis-hooks/rust-toolchain.toml']),
       install_path=ns['INSTALL'],assets={})

def generation(manifest):
    identity={k:manifest[k] for k in ('version','inputs','toolchain')}
    manifest['generation']=sha(json.dumps(identity,sort_keys=True,separators=(',',':')).encode())

def record(path,data):
    p=base/path; p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes(data); p.chmod(0o755)
    return dict(path=path,size=len(data),sha256=sha(data))

d['adapter']=record('hook-adapter.sh',b'# synthetic inline adapter\nexit 0\n')
for target,data in (('x86_64-unknown-linux-musl',elf),
                    ('aarch64-apple-darwin',b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01'+bytes(112))):
    darwin=target.endswith('apple-darwin')
    d['assets'][target]=dict(record(target+'/trellis-hooks',data),
        format='mach-o' if darwin else 'elf-static',signature='adhoc' if darwin else 'none',
        minimum_os='13.0' if darwin else None)
generation(d)
manifest=base/'artifacts.json'

def write_manifest():
    manifest.write_text(json.dumps(d))

def codesign_only(args,**kwargs):
    assert args[:3]==['/usr/bin/codesign','--verify','--strict'], ('unexpected subprocess',args)
    assert pathlib.Path(args[3])==base/'aarch64-apple-darwin/trellis-hooks'
    return b''

def replace_binary(target,mutate):
    a=d['assets'][target]; data=bytearray((base/a['path']).read_bytes())
    mutate(data)
    a.update(record(a['path'],data))

write_manifest()
with patch('subprocess.check_output',side_effect=codesign_only):
    positive_stderr=io.StringIO()
    with contextlib.redirect_stderr(positive_stderr):
        assert verify(base)==d, 'synthetic positive control refused'
    if platform.system()=='Darwin':
        assert 'UNVERIFIED-on-Darwin: Linux asset is structural only' in positive_stderr.getvalue(), 'Linux structural check claimed qualification'
    print(positive_stderr.getvalue(),end='',file=sys.stderr)
    if case=='positive':
        print('synthetic positive control accepted (structure only)')
        sys.exit(0)
    if case=='pt-interp':
        replace_binary('x86_64-unknown-linux-musl',lambda b:b.__setitem__(slice(64,68),(3).to_bytes(4,'little')))
        error='dynamic ELF interpreter'
    elif case=='phdr-bounds':
        replace_binary('x86_64-unknown-linux-musl',lambda b:b.__setitem__(slice(32,40),(10**6).to_bytes(8,'little')))
        error='invalid ELF program headers'
    elif case=='phdr-width':
        replace_binary('x86_64-unknown-linux-musl',lambda b:b.__setitem__(slice(54,56),(4).to_bytes(2,'little')))
        error='invalid ELF program headers'
    elif case=='elf-architecture':
        replace_binary('x86_64-unknown-linux-musl',lambda b:b.__setitem__(slice(18,20),(183).to_bytes(2,'little')))
        error='wrong ELF target'
    elif case=='mach-o-architecture':
        replace_binary('aarch64-apple-darwin',lambda b:b.__setitem__(slice(4,8),b'\x07\x00\x00\x01'))
        error='wrong Mach-O target'
    elif case.startswith('host-path:'):
        marker=case.split(':',1)[1].encode()
        replace_binary('x86_64-unknown-linux-musl',lambda b:b.extend(marker))
        error='unremapped build path'
    elif case.startswith('target-metadata:'):
        key=case.split(':',1)[1]
        d['assets']['x86_64-unknown-linux-musl'][key]={'format':'mach-o','signature':'adhoc','minimum_os':'13.0'}[key]
        error='target metadata mismatch'
    elif case=='generation':
        d['generation']='0'*64
        error='generation mismatch'
    elif case=='executable':
        (base/d['assets']['x86_64-unknown-linux-musl']['path']).chmod(0o644)
        error='asset is not executable'
    elif case=='duplicate-key':
        error='duplicate manifest key'
    elif case=='toolchain-pin':
        # Same release number, wrong compiler revision: a startswith pin is insufficient.
        d['toolchain']['rustc']='rustc 1.97.1 (000000000 2026-07-14)'
        generation(d)
        error='unpinned toolchain'
    elif case=='version':
        d['version']='0.0.0'; generation(d)
        error='version/install layout mismatch'
    elif case=='install-path':
        d['install_path']='bin/native/{version}/{target}/trellis-hooks'
        error='version/install layout mismatch'
    elif case=='adapter-path':
        # Keep the expected hook-adapter.sh inventory intact. An outside regular
        # file with identical bytes passes every remaining check if this require
        # is removed; merely renaming the in-tree file would mask the regression.
        outside=base.parent/'outside-adapter.sh'
        outside.write_bytes((base/'hook-adapter.sh').read_bytes())
        d['adapter']['path']=str(outside)
        error='adapter path mismatch'
    else:
        raise AssertionError(('unknown case',case))
    write_manifest()
    if case=='duplicate-key':
        # Identical duplicate values: only duplicate-key detection can reject it.
        text=manifest.read_text()
        manifest.write_text('{"schema_version":1,'+text[1:])
    try:
        verify(base)
    except ValueError as e:
        assert error in str(e), (case,'wrong refusal',str(e),error)
        print(case+': '+str(e))
    else:
        raise AssertionError(case+': verifier accepted isolated mutation')
PY
}

@test "native delivery synthetic: positive closed manifest control" {
  run synthetic_manifest_case positive
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: PT_INTERP refuses independently" {
  run synthetic_manifest_case pt-interp
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: ELF program header bounds and stride refuse independently" {
  for case in phdr-bounds phdr-width; do
    run synthetic_manifest_case "$case"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "native delivery synthetic: ELF architecture refuses independently" {
  run synthetic_manifest_case elf-architecture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: Mach-O architecture refuses independently of codesign" {
  run synthetic_manifest_case mach-o-architecture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: host paths refuse independently of digest" {
  for marker in /Users/ /home/ /.cargo/ /.rustup/; do
    run synthetic_manifest_case "host-path:$marker"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "native delivery synthetic: target metadata refuses independently" {
  for field in format signature minimum_os; do
    run synthetic_manifest_case "target-metadata:$field"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "native delivery synthetic: generation is recomputed independently" {
  run synthetic_manifest_case generation
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: executable bit refuses independently" {
  run synthetic_manifest_case executable
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: duplicate JSON keys refuse independently" {
  run synthetic_manifest_case duplicate-key
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: full toolchain pin refuses independently of generation" {
  run synthetic_manifest_case toolchain-pin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery synthetic: version and install_path refuse independently" {
  for field in version install-path; do
    run synthetic_manifest_case "$field"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "native delivery synthetic: adapter path refuses with unchanged closed inventory" {
  run synthetic_manifest_case adapter-path
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

copy_assets() {
  cp -R "$ASSETS" "$BATS_TEST_TMPDIR/assets"
  COPY="$BATS_TEST_TMPDIR/assets"
  chmod -R u+w "$COPY"
  TARGET="$(python3 -I -c 'import json,sys; print(next(iter(json.load(open(sys.argv[1]))["assets"])))' "$COPY/artifacts.json")"
}

@test "native delivery: post-signing mutation refuses its digest" {
  copy_assets
  printf 'post-signing mutation' >> "$COPY/$TARGET/trellis-hooks"
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"digest/size mismatch"* ]] || false
}

@test "native delivery: digest mismatch refuses without executing the companion" {
  copy_assets
  printf '#!/bin/sh\ntouch "%s"\n' "$BATS_TEST_TMPDIR/executed" > "$COPY/$TARGET/trellis-hooks"
  chmod +x "$COPY/$TARGET/trellis-hooks"
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "native delivery: missing symlinked and unlisted assets refuse" {
  copy_assets
  mv "$COPY/$TARGET/trellis-hooks" "$BATS_TEST_TMPDIR/real"
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
  ln -s "$BATS_TEST_TMPDIR/real" "$COPY/$TARGET/trellis-hooks"
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
  unlink "$COPY/$TARGET/trellis-hooks"
  mv "$BATS_TEST_TMPDIR/real" "$COPY/$TARGET/trellis-hooks"
  printf extra > "$COPY/unlisted"
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
}

@test "native delivery: closed schema and traversal paths refuse" {
  copy_assets
  python3 -I - "$COPY/artifacts.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['unknown']=True
open(p,'w').write(json.dumps(d))
PY
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
  cp "$ASSETS/artifacts.json" "$COPY/artifacts.json"
  python3 -I - "$COPY/artifacts.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); next(iter(d['assets'].values()))['path']='../escape'
open(p,'w').write(json.dumps(d))
PY
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
}

@test "native delivery: build paths are remapped out of final bytes" {
  python3 -I - "$ASSETS" "$ROOT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); d=json.loads((root/'artifacts.json').read_text())
for a in d['assets'].values():
    b=(root/a['path']).read_bytes()
    for forbidden in (sys.argv[2].encode(), b'/Users/', b'/home/', b'/.cargo/', b'/.rustup/'):
        assert forbidden not in b, forbidden
PY
}

@test "native delivery: unsupported Intel Darwin target is refused before build" {
  run bash "$BUILD" build x86_64-apple-darwin "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a $(cat "$ROOT/core-rules/VERSION") native target"* ]] || false
}

# The release version has one source, core-rules/VERSION: the build script
# carries no pin of its own and refuses an unusable version file.
@test "native delivery: the build script takes its release version from core-rules/VERSION" {
  local copy="$BATS_TEST_TMPDIR/version-root" version
  # The committed manifest's own version, so the case holds between a VERSION
  # bump and its rebuild too: it tests that the script follows the file.
  version="$(jq -r .version "$ASSETS/artifacts.json")"
  run grep -nE "^VERSION = ['\"]" "$BUILD"
  [ "$status" -eq 1 ] || { echo "build script still pins: $output"; false; }
  mkdir -p "$copy/scripts" "$copy/core-rules"
  cp "$BUILD" "$copy/scripts/build-native-hooks.sh"
  cp -R "$ASSETS" "$copy/core-rules/native"
  printf '%s\n' "$version" > "$copy/core-rules/VERSION"
  run bash "$copy/scripts/build-native-hooks.sh" verify
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run bash "$copy/scripts/build-native-hooks.sh" build x86_64-apple-darwin "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"not a $version native target"* ]] || { echo "$output"; false; }
  # Another version in the file, not in the script, rejects the same manifest.
  printf '9.9.9\n' > "$copy/core-rules/VERSION"
  run bash "$copy/scripts/build-native-hooks.sh" verify
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"version/install layout mismatch"* ]] || { echo "$output"; false; }
  run bash "$copy/scripts/build-native-hooks.sh" build x86_64-apple-darwin "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"not a 9.9.9 native target"* ]] || { echo "$output"; false; }
  local bad
  for bad in '1.5' "$version"$'\n'"$version" 'latest' "$version "; do
    printf '%s\n' "$bad" > "$copy/core-rules/VERSION"
    run bash "$copy/scripts/build-native-hooks.sh" verify
    [ "$status" -eq 1 ] || { echo "accepted [$bad]: $output"; false; }
    [[ "$output" == *"core-rules/VERSION is not one version line"* ]] || { echo "$output"; false; }
  done
  printf '%s' "$version" > "$copy/core-rules/VERSION"
  run bash "$copy/scripts/build-native-hooks.sh" verify
  [[ "$output" == *"core-rules/VERSION is not one version line"* ]] || { echo "no newline accepted: $output"; false; }
  rm "$copy/core-rules/VERSION"
  printf '%s\n' "$version" > "$copy/version.real"
  ln -s ../version.real "$copy/core-rules/VERSION"
  run bash "$copy/scripts/build-native-hooks.sh" verify
  [[ "$output" == *"core-rules/VERSION is not a regular file"* ]] || { echo "symlink accepted: $output"; false; }
  rm "$copy/core-rules/VERSION"
  run bash "$copy/scripts/build-native-hooks.sh" verify
  [[ "$output" == *"core-rules/VERSION is not a regular file"* ]] || { echo "missing accepted: $output"; false; }
}

@test "native delivery: L5 nonempty output without manifest refuses before tools or input checks" {
  case "$(uname -s):$(uname -m)" in
    Darwin:*) target=aarch64-apple-darwin ;;
    Linux:aarch64|Linux:arm64) target=aarch64-unknown-linux-musl ;;
    Linux:*) target=x86_64-unknown-linux-musl ;;
    *) skip "unsupported build host" ;;
  esac
  mkdir -p "$BATS_TEST_TMPDIR/output/$target"
  printf 'outside marker must remain unchanged\n' > "$BATS_TEST_TMPDIR/outside"
  cp "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/outside.expected"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/output/$target/trellis-hooks"
  run bash "$BUILD" build "$target" "$BATS_TEST_TMPDIR/output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonempty build output without manifest"* ]] || false
  cmp "$BATS_TEST_TMPDIR/outside.expected" "$BATS_TEST_TMPDIR/outside"
  [ -L "$BATS_TEST_TMPDIR/output/$target/trellis-hooks" ]
  [ ! -e "$BATS_TEST_TMPDIR/output/artifacts.json" ]
}

# Each call imports the real library in a fresh shell, not inherited Bats state.
native_home_call() {
  env -u BASH_ENV -u TRELLIS_LIBS_PRELOADED bash --noprofile --norc -c '
    . "$1/scripts/lib/trellis-home.sh" || exit 90
    shift
    "$@"
  ' _ "$ROOT" "$@"
}

@test "native delivery: M2 configure rejects equals for both native command-path labels" {
  for label in TRELLIS_HOME 'native companion'; do
    run native_home_call trellis_home_require_absolute_safe_path "$label" "$BATS_TEST_TMPDIR/home=x"
    [ "$status" -eq 2 ] || { echo "$output"; false; }
    [[ "$output" == *"$label must not contain an env assignment operand (=)"* ]] || false
  done
  # Narrow ownership: an ordinary source path is not an env command operand.
  run native_home_call trellis_home_require_absolute_safe_path 'source root' "$BATS_TEST_TMPDIR/home=x"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery: M2 shared predicate rejects relative equals ASCII DEL and C1 paths" {
  for path in '' relative/path "$BATS_TEST_TMPDIR/home=x"; do
    run native_home_call trellis_home_native_entry_path_is_safe "$path"
    [ "$status" -eq 1 ] || { echo "accepted unsafe path: $path"; false; }
  done
  # NUL cannot occur in a Bash argument. Cover every other ASCII control,
  # DEL, and every UTF-8 C1 control, with a non-trailing sentinel byte.
  for ((code=1; code<=31; code++)); do
    printf -v octal '\\%03o' "$code"
    printf -v control '%b' "$octal"
    run native_home_call trellis_home_native_entry_path_is_safe "$BATS_TEST_TMPDIR/home${control}x"
    [ "$status" -eq 1 ] || { echo "accepted ASCII control $code"; false; }
  done
  run native_home_call trellis_home_native_entry_path_is_safe "$BATS_TEST_TMPDIR/home"$'\177''x'
  [ "$status" -eq 1 ] || { echo 'accepted DEL'; false; }
  for ((code=128; code<=159; code++)); do
    printf -v octal '\\%03o' "$code"
    printf -v control '%b' "\302$octal"
    run native_home_call trellis_home_native_entry_path_is_safe "$BATS_TEST_TMPDIR/home${control}x"
    [ "$status" -eq 1 ] || { echo "accepted C1 control $code"; false; }
  done
}

@test "native delivery: M2 shared predicate and configure allow shell-quoted metacharacters" {
  safe="$BATS_TEST_TMPDIR/space ; \$literal \`literal\` [*] ! & ( ) ' \" backslash\\"
  run native_home_call trellis_home_native_entry_path_is_safe "$safe"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for label in TRELLIS_HOME 'native companion'; do
    run native_home_call trellis_home_require_absolute_safe_path "$label" "$safe"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

native_render_fixture() {
  env -u BASH_ENV -u TRELLIS_LIBS_PRELOADED HOME="$1" \
    TRELLIS_ATTACH_CALLER_PATH="$1/no-claude" bash --noprofile --norc -c '
    . "$1/scripts/lib/attachment.sh" || exit 90
    context="$(attachment_contextual_render_context "$2")" || exit 91
    attachment_contextual_template_render "$1/core-rules/legacy-hooks/claude-settings.local.json" \
      core-rules/templates/claude-settings.local.json "$context"
  ' _ "$ROOT" "$2"
}

@test "native delivery: M2 rendering refuses an actual canonical equals home after valid context" {
  sandbox="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  user_home="$sandbox/render-user"
  mkdir -p "$user_home/.local/bin" "$sandbox/good-home" "$sandbox/home=x"
  printf '#!/bin/sh\nexit 0\n' > "$user_home/.local/bin/trellis"
  chmod +x "$user_home/.local/bin/trellis"
  run native_render_fixture "$user_home" "$sandbox/good-home"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run native_render_fixture "$user_home" "$sandbox/home=x"
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"registration TRELLIS_HOME is not a safe native env command path"* ]] || false
}

@test "native delivery: shell adapter denies a missing companion for both harnesses" {
  for harness in claude codex; do
    run /bin/sh -c "$(grep -v '^#' "$ASSETS/hook-adapter.sh")" trellis-hooks \
      "$BATS_TEST_TMPDIR/missing" "$harness" PreToolUse "$BATS_TEST_TMPDIR"
    if [ "$harness" = claude ]; then
      [ "$status" -eq 0 ]
      [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    else
      [ "$status" -eq 2 ]
      [[ "$output" == *'"decision":"block"'* ]] || false
    fi
  done
}
# A test-only executable writes a marker and returns the no-op ABI. Avoid
# copying Apple's platform-signed /bin/sh, which may be killed at a new inode.
adapter_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/$1"
  COMPANION="$BATS_TEST_TMPDIR/$1/trellis-hooks"
  printf '%s\n' '#!/bin/sh' ': > "$4/adapter-executed-$2"' 'exit 10' > "$COMPANION"
  chmod +x "$COMPANION"
}

run_inline_adapter() (
  cd "$BATS_TEST_TMPDIR" || exit 1
  /bin/sh -c "$(grep -v '^#' "$ASSETS/hook-adapter.sh")" trellis-hooks \
    "$COMPANION" "$1" PreToolUse "$BATS_TEST_TMPDIR"
)

@test "native delivery: R2 adapter denies equals companion path before env for both harnesses" {
  adapter_stub home=x
  # env can parse an equals-bearing command as an assignment. Require the guard
  # before env as well as denial: a missing `event` program must not mask it.
  run python3 -I - "$ASSETS/hook-adapter.sh" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
assert text.index('[ "${1#*=}" = "$1" ]') < text.index('/usr/bin/env -i')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for harness in claude codex; do
    run run_inline_adapter "$harness"
    if [ "$harness" = claude ]; then
      [ "$status" -eq 0 ]
      [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    else
      [ "$status" -eq 2 ]
      [[ "$output" == *'"decision":"block"'* ]] || false
    fi
    [ ! -e "$BATS_TEST_TMPDIR/adapter-executed-$harness" ]
  done
}

@test "native delivery: inline adapter safely executes a metacharacter companion path" {
  adapter_stub 'home ; $not_expanded [literal]'
  for harness in claude codex; do
    run run_inline_adapter "$harness"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -z "$output" ] || { echo "$output"; false; }
    [ -f "$BATS_TEST_TMPDIR/adapter-executed-$harness" ]
  done
}

@test "native delivery: host binary runs contract but refuses measurement-only routes" {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) skip "legacy-path host has no native asset" ;;
  esac
  [ -f "$ASSETS/$target/trellis-hooks" ] || skip "host has no selected native asset"
  run "$ASSETS/$target/trellis-hooks" contract
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deadline_secs":20'* ]] || false
  run bash -c 'printf "%s" "{\"tool_input\":{\"command\":\"echo safe\"}}" | "$1" proto-event none codex PreToolUse "$2" "$2/core-rules/hooks/rules/destructive.json"' _ "$ASSETS/$target/trellis-hooks" "$ROOT"
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown command"* ]] || false
}
@test "native delivery: registry cache checksum is verified and extracted source is never reused" {
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import io,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]); tmp=pathlib.Path(sys.argv[2])
source=(root/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1]
definitions=source.split('\ntry:\n    args = sys.argv[2:]',1)[0]
assert definitions != source, 'missing build-script definition boundary'
ns={'__name__':'registry_fixture'}
exec(compile(definitions,'build-native-hooks.sh','exec'),ns)
cargo=tmp/'cargo-home'; cache=cargo/'registry/cache/crates-fixture'
cache.mkdir(parents=True)
index=cargo/'registry/index'; index.mkdir(); (index/'config.json').write_text('{}')
src=cargo/'registry/src/crates-fixture/fixture-1.0.0'
src.mkdir(parents=True); (src/'lib.rs').write_text('untrusted extracted source')
archive=cache/'fixture-1.0.0.crate'
# A real small archive; no dependency download or Cargo invocation is involved.
with tarfile.open(archive,'w:gz') as tar:
    content=b'// pinned archive source\n'
    member=tarfile.TarInfo('fixture-1.0.0/src/lib.rs'); member.size=len(content)
    tar.addfile(member,io.BytesIO(content))
pinned=archive.read_bytes()
lock=tmp/'Cargo.lock'
lock.write_text('version = 4\n\n[[package]]\nname = "fixture"\nversion = "1.0.0"\n'
                'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
                'checksum = "'+ns['sha'](pinned)+'"\n')
private=tmp/'private-cargo'; private.mkdir()
ns['populate_registry'](cargo,private,lock)
copied=private/'registry/cache/crates-fixture/fixture-1.0.0.crate'
assert copied.read_bytes()==pinned, 'positive cache population failed'
assert not copied.is_symlink() and not copied.samefile(archive), 'cache was linked, not copied'
assert (private/'registry/index').is_symlink(), 'index is not the permitted shared index'
assert (private/'registry/index/config.json').read_text()=='{}'
assert not (private/'registry/src').exists(), 'ambient registry/src was reused'
archive.write_bytes(pinned+b'tampered')
assert copied.read_bytes()==pinned, 'private cache changed with ambient cache'
refused=tmp/'refused-cargo'; refused.mkdir()
try:
    ns['populate_registry'](cargo,refused,lock)
except ValueError as e:
    assert 'cached dependency checksum mismatch: fixture-1.0.0.crate' in str(e), str(e)
else:
    raise AssertionError('tampered cached crate accepted')
assert not (refused/'registry/cache/crates-fixture/fixture-1.0.0.crate').exists(), 'tampered archive copied'
assert not (refused/'registry/src').exists(), 'refusal reused extracted sources'
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery: crate workspace ignores an enclosing Cargo workspace" {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) hosts='aarch64-apple-darwin' ;;
    Darwin:x86_64) hosts='x86_64-apple-darwin' ;;
    Linux:x86_64) hosts='x86_64-unknown-linux-gnu x86_64-unknown-linux-musl' ;;
    Linux:aarch64|Linux:arm64) hosts='aarch64-unknown-linux-gnu aarch64-unknown-linux-musl' ;;
    *) skip 'unsupported build host' ;;
  esac
  cargo=''
  for host in $hosts; do
    candidate="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.97.1-$host/bin/cargo"
    if [ -x "$candidate" ]; then cargo="$candidate"; break; fi
  done
  [ -n "$cargo" ] || skip 'pinned native Cargo unavailable; workspace isolation unverified'
  fixture="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$fixture/native/trellis-hooks/src" "$fixture/cargo"
  cp "$ROOT/native/trellis-hooks/Cargo.toml" "$fixture/native/trellis-hooks/Cargo.toml"
  printf 'fn main() {}\n' > "$fixture/native/trellis-hooks/src/main.rs"
  printf '[workspace]\nmembers = ["native/trellis-hooks"]\nresolver = "2"\n[profile.release]\nopt-level = 0\npanic = "unwind"\n' > "$fixture/Cargo.toml"
  run env CARGO_HOME="$fixture/cargo" "$cargo" locate-project --workspace --offline --manifest-path "$fixture/native/trellis-hooks/Cargo.toml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  actual="$(printf '%s\n' "$output" | jq -r '.root')"
  [ "$actual" = "$fixture/native/trellis-hooks/Cargo.toml" ] || { echo "Cargo selected enclosing workspace: $actual"; false; }
}

@test "native delivery: Linux entropy loop retries EINTR and refuses short or failed reads" {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) hosts='aarch64-apple-darwin' ;;
    Darwin:x86_64) hosts='x86_64-apple-darwin' ;;
    Linux:x86_64) hosts='x86_64-unknown-linux-gnu x86_64-unknown-linux-musl' ;;
    Linux:aarch64|Linux:arm64) hosts='aarch64-unknown-linux-gnu aarch64-unknown-linux-musl' ;;
    *) skip 'unsupported build host' ;;
  esac
  rustc=''
  for host in $hosts; do
    candidate="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.97.1-$host/bin/rustc"
    if [ -x "$candidate" ]; then rustc="$candidate"; break; fi
  done
  [ -n "$rustc" ] || skip 'pinned native rustc unavailable; entropy simulation unverified'
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR" "$rustc" <<'PY'
import pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); tmp=pathlib.Path(sys.argv[2]); rustc=sys.argv[3]
source=(root/'native/trellis-hooks/src/preflight.rs').read_text()
segment=source.split('pub fn scratch_create(',1)[1].split('    let name = format!',1)[0]
linux=segment.split('    #[cfg(target_os = "linux")]\n',1)[1]
harness=r'''
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
static MODE: AtomicUsize = AtomicUsize::new(0);
static CALLS: AtomicUsize = AtomicUsize::new(0);
static LAST: AtomicI32 = AtomicI32::new(0);
mod libc {
    #[allow(non_camel_case_types)] pub type c_void = std::ffi::c_void;
    pub const EINTR: i32 = 4;
    pub const SYS_getrandom: i64 = 318;
    // The raw getrandom syscall the companion uses (static musl has no libc
    // getrandom symbol).
    pub unsafe fn syscall(number: i64, buf: *mut c_void, len: usize, _: i32) -> i64 {
        assert_eq!(number, SYS_getrandom);
        let call = super::CALLS.fetch_add(1, super::Ordering::SeqCst);
        match super::MODE.load(super::Ordering::SeqCst) {
            1 if call < 2 => { super::LAST.store(EINTR, super::Ordering::SeqCst); -1 },
            2 => { super::LAST.store(5, super::Ordering::SeqCst); -1 },
            3 => { std::ptr::write_bytes(buf as *mut u8, 0x5a, 3); 3 },
            4 => 0,
            _ => { std::ptr::write_bytes(buf as *mut u8, 0x5a, len); len as i64 },
        }
    }
}
fn errno() -> i32 { LAST.load(Ordering::SeqCst) }
fn sample() -> Result<[u8; 8], String> {
    let mut random = [0u8; 8];
''' + linux + r'''
    Ok(random)
}
fn main() {
    for (mode, succeeds, calls) in [(0, true, 1), (1, true, 3), (2, false, 1), (3, false, 1), (4, false, 1)] {
        MODE.store(mode, Ordering::SeqCst); CALLS.store(0, Ordering::SeqCst);
        let result = sample();
        assert_eq!(result.is_ok(), succeeds, "mode {mode}");
        if succeeds { assert_eq!(result.unwrap(), [0x5a; 8]); }
        assert_eq!(CALLS.load(Ordering::SeqCst), calls, "mode {mode}");
    }
}
'''
program=tmp/'entropy.rs'; program.write_text(harness)
subprocess.run([rustc,'--edition=2021',str(program),'-o',str(tmp/'entropy')],check=True)
subprocess.run([str(tmp/'entropy')],check=True)
print('simulated Linux getrandom syscall: success, EINTR retries, EIO, short and zero refusals')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery: platform builds join after an asset-only commit but changed inputs refuse" {
  # Real Git history/publication; compiler, host and signing operations are
  # simulated so this tests identity on either host, not Linux qualification.
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR/generation" <<'PY'
import contextlib,hashlib,io,json,os,pathlib,shutil,subprocess,sys
from unittest.mock import patch
root=pathlib.Path(sys.argv[1]); fixture=pathlib.Path(sys.argv[2])
shutil.copytree(root/'native/trellis-hooks', fixture/'native/trellis-hooks', ignore=shutil.ignore_patterns('target'))
# Mock Cargo never resolves dependencies. Keep this fixture independent of the
# caller's registry, including its extracted source tree and cached checksums.
(fixture/'native/trellis-hooks/Cargo.lock').write_text('version = 4\n\n[[package]]\nname = "trellis-hooks"\nversion = "0.1.0"\n')
(fixture/'scripts').mkdir()
shutil.copy2(root/'scripts/build-native-hooks.sh', fixture/'scripts/build-native-hooks.sh')
# A checkout carries its release version (core-rules/VERSION); not an input.
(fixture/'core-rules').mkdir(parents=True,exist_ok=True); shutil.copy2(root/'core-rules/VERSION',fixture/'core-rules/VERSION')
source=(fixture/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
ns={}; exec(compile(source.split('\ntry:\n',1)[0],'build-native-hooks.sh','exec'),ns)
for name in ns['include_inputs'](root):
    destination=fixture/name
    if not destination.exists():
        destination.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(root/name,destination)
assets=fixture/'core-rules/native'
real_output=subprocess.check_output; real_run=subprocess.run

def git(*args):
    return real_output(['git','-C',str(fixture),'-c','core.hooksPath=/dev/null',
                        '-c','commit.gpgsign=false','-c','user.name=Native Fixture',
                        '-c','user.email=fixture@example.invalid',*args]).decode().strip()

git('init','-q'); git('add','.'); git('commit','-qm','native inputs')
initial_head=git('rev-parse','HEAD')
rustup=fixture.parent/'private-rustup'
cargo_home=fixture.parent/'empty-cargo'
cargo_home.mkdir()
for host in ('aarch64-apple-darwin','x86_64-unknown-linux-gnu'):
    tools=rustup/'toolchains'/('1.97.1-'+host)/'bin'
    tools.mkdir(parents=True)
    for tool in ('rustc','cargo'):
        p=tools/tool; p.write_text('# mocked tool, never executed\n'); p.chmod(0o755)

def output(args,**kwargs):
    assert pathlib.Path(args[0]).name!='rustup', 'ambient rustup resolution'
    if pathlib.Path(args[0]).name=='rustc':
        assert pathlib.Path(args[0]).is_absolute()
        assert pathlib.Path(args[0]).is_relative_to(rustup/'toolchains')
        return b'rustc 1.97.1 (8bab26f4f 2026-07-14)\n'
    if args[0] in ('/usr/bin/strip','/usr/bin/codesign'):
        return b''
    return real_output(args,**kwargs)

compile_calls=[]
mutate_during_compile=False

def compile_fixture(args,**kwargs):
    if pathlib.Path(args[0]).name!='cargo':
        return real_run(args,**kwargs)
    compile_calls.append(args)
    target=args[args.index('--target')+1]
    host='aarch64-apple-darwin' if target.endswith('apple-darwin') else 'x86_64-unknown-linux-gnu'
    assert pathlib.Path(args[0])==rustup/'toolchains'/('1.97.1-'+host)/'bin/cargo'
    assert pathlib.Path(kwargs['env']['RUSTC'])==pathlib.Path(args[0]).with_name('rustc')
    assert kwargs['env']['PATH']=='/usr/bin:/bin:/usr/sbin:/sbin'
    assert kwargs['env']['CARGO_BUILD_JOBS']==os.environ.get('CARGO_BUILD_JOBS','2')
    private=pathlib.Path(kwargs['env']['CARGO_HOME'])
    assert private!=cargo_home and not (private/'registry/src').exists()
    assert not (private/'registry').is_symlink()
    p=pathlib.Path(kwargs['env']['CARGO_TARGET_DIR'])/target/'release/trellis-hooks'
    p.parent.mkdir(parents=True)
    if target.endswith('apple-darwin'):
        b=b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01'+bytes(112)
    else:
        b=bytearray(120); b[:6]=b'\x7fELF\x02\x01'
        b[18:20]=(62).to_bytes(2,'little')
        b[32:40]=(64).to_bytes(8,'little')
        b[54:56]=(56).to_bytes(2,'little'); b[56:58]=(1).to_bytes(2,'little')
        b[64:68]=(1).to_bytes(4,'little')
    p.write_bytes(b)
    if mutate_during_compile:
        changed=fixture/'native/trellis-hooks/src/main.rs'
        changed.write_text(changed.read_text()+'\n// committed during compilation\n')
        git('add','native/trellis-hooks/src/main.rs')
        git('commit','-qm','change input while compiling')
    return subprocess.CompletedProcess(args,0)

def build(target,host,destination=assets):
    sys.argv=['build-native-hooks',str(fixture),'build',target,str(destination)]
    machine='arm64' if host=='Darwin' else 'x86_64'
    errors=io.StringIO(); code=0
    with patch.dict(os.environ,{'RUSTUP_HOME':str(rustup),'CARGO_HOME':str(cargo_home)}), \
         patch('platform.system',return_value=host), patch('platform.machine',return_value=machine), \
         patch('subprocess.check_output',side_effect=output), patch('subprocess.run',side_effect=compile_fixture), \
         contextlib.redirect_stderr(errors):
        try:
            exec(compile(source,'build-native-hooks.sh','exec'),{'__name__':'__main__'})
        except SystemExit as e:
            code=e.code
    build.error=errors.getvalue()
    print(build.error,end='',file=sys.stderr)
    return code

assert build('aarch64-apple-darwin','Darwin')==0
first=json.loads((assets/'artifacts.json').read_text())
assert first['source_commit']==initial_head, 'wrong input provenance before asset commit'
git('add','core-rules/native'); git('commit','-qm','commit platform A asset')
assert git('rev-parse','HEAD')!=initial_head
assert build('x86_64-unknown-linux-musl','Linux')==0, 'platform B refused after asset-only commit'
joined=json.loads((assets/'artifacts.json').read_text())
assert joined['generation']==first['generation'], 'asset commit changed generation'
assert joined['source_commit']==initial_head, 'asset-only commit changed input provenance'
assert set(joined['assets'])=={'aarch64-apple-darwin','x86_64-unknown-linux-musl'}
p=fixture/'native/trellis-hooks/src/main.rs'; original=p.read_text()
p.write_text(original+'\n// changed input\n')
compiled=len(compile_calls)
dirty_destination=fixture/'core-rules/dirty-native'
assert build('x86_64-unknown-linux-musl','Linux',dirty_destination)==1, 'dirty input accepted into fresh output'
assert 'dirty native build input' in build.error and not dirty_destination.exists(), build.error
assert len(compile_calls)==compiled, 'dirty fresh build reached compiler'
assert build('x86_64-unknown-linux-musl','Linux')==1, 'changed input was accepted'
assert 'dirty native build input' in build.error, build.error
assert len(compile_calls)==compiled, 'dirty input reached compiler'
assert json.loads((assets/'artifacts.json').read_text())==joined, 'refusal mutated published assets'
p.write_text(original)

# Neither a clean nor a modified file with either hidden-index flag is admitted.
for flag,clear in (('--skip-worktree','--no-skip-worktree'),
                   ('--assume-unchanged','--no-assume-unchanged')):
    git('update-index',flag,'native/trellis-hooks/src/main.rs')
    destination=fixture/('core-rules/flagged-'+flag[2:])
    assert build('x86_64-unknown-linux-musl','Linux',destination)==1, flag+' clean input accepted'
    assert 'flagged native build input' in build.error and not destination.exists(), build.error
    p.write_text(original+'\n// hidden dirty input\n')
    assert build('x86_64-unknown-linux-musl','Linux',destination)==1, flag+' dirty input accepted'
    assert 'flagged native build input' in build.error and not destination.exists(), build.error
    assert len(compile_calls)==compiled, flag+' reached compiler'
    git('update-index',clear,'native/trellis-hooks/src/main.rs')
    p.write_text(original)

# Ignoring a source-like file must not hide it from the build-input boundary.
ignored=fixture/'native/trellis-hooks/ignored.inc'
(fixture/'.git/info/exclude').write_text('native/trellis-hooks/ignored.inc\n')
ignored.write_text('ignored, but potentially compiled include data\n')
assert build('x86_64-unknown-linux-musl','Linux',fixture/'core-rules/ignored-native')==1, 'ignored untracked input was accepted'
assert 'untracked native build input' in build.error, build.error
assert len(compile_calls)==compiled, 'ignored input reached compiler'
ignored.unlink()

include=fixture/'native/trellis-hooks/data/include.txt'
include.parent.mkdir(exist_ok=True); include.write_text('new tracked include data\n')
assert build('x86_64-unknown-linux-musl','Linux')==1, 'untracked include data was accepted'
assert 'untracked native build input' in build.error, build.error
assert len(compile_calls)==compiled, 'untracked input reached compiler'
assert json.loads((assets/'artifacts.json').read_text())==joined, 'untracked refusal mutated assets'

git('add','native/trellis-hooks/data/include.txt'); git('commit','-qm','track include data')
include_head=git('rev-parse','HEAD')
assert build('x86_64-unknown-linux-musl','Linux')==1, 'new tracked input reused old generation'
assert 'different source generation' in build.error, build.error
assert len(compile_calls)==compiled, 'generation refusal reached compiler'
assert json.loads((assets/'artifacts.json').read_text())==joined, 'generation refusal mutated assets'

fresh=fixture/'core-rules/new-native'
assert build('x86_64-unknown-linux-musl','Linux',fresh)==0, 'clean tracked include data refused fresh build'
updated=json.loads((fresh/'artifacts.json').read_text())
assert updated['generation']!=joined['generation'], 'tracked include data omitted from generation'
assert updated['inputs']['native/trellis-hooks/data/include.txt']==hashlib.sha256(include.read_bytes()).hexdigest()
assert updated['source_commit']==include_head, 'new tracked input provenance is wrong'
assert json.loads((assets/'artifacts.json').read_text())==joined, 'fresh build mutated old generation'

# A deletion must not escape dirtiness/provenance just because the index no
# longer lists the deleted input. After commit the content identity may return
# to the original generation, but provenance must name the deletion commit.
git('rm','native/trellis-hooks/data/include.txt')
deleted=fixture/'core-rules/deleted-native'
compiled=len(compile_calls)
assert build('x86_64-unknown-linux-musl','Linux',deleted)==1, 'staged input deletion was accepted'
assert 'dirty native build input' in build.error and not deleted.exists(), build.error
assert len(compile_calls)==compiled, 'staged deletion reached compiler'
git('commit','-qm','remove tracked include data')
delete_head=git('rev-parse','HEAD')
assert build('x86_64-unknown-linux-musl','Linux',deleted)==0, 'committed input deletion refused fresh build'
removed=json.loads((deleted/'artifacts.json').read_text())
assert removed['source_commit']==delete_head, 'deletion-only input provenance is wrong'
assert 'native/trellis-hooks/data/include.txt' not in removed['inputs']
assert removed['generation']==joined['generation'], 'restored input set changed content generation'

# Cwd ancestors can inject Cargo config even with a private CARGO_HOME.
parent=fixture.parent/'ambient-parent'
config=parent/'.cargo/config.toml'
config.parent.mkdir(parents=True)
config.write_text('[build]\nrustflags = ["--cfg", "injected"]\n')
ambient_out=fixture/'core-rules/ambient-native'
compiled=len(compile_calls)
with patch.dict(os.environ,{'TMPDIR':str(parent)}):
    assert build('x86_64-unknown-linux-musl','Linux',ambient_out)==1, 'ancestor Cargo config accepted'
    assert 'ambient ancestor Cargo config' in build.error and not ambient_out.exists(), build.error
    assert len(compile_calls)==compiled, 'ancestor Cargo config reached compiler'
    config.unlink()
    assert build('x86_64-unknown-linux-musl','Linux',ambient_out)==0, 'clean ancestor refused'
assert len(compile_calls)==compiled+1, 'clean ancestor did not reach compiler'

# Commit a tracked input during the mocked compile: Git is clean afterwards,
# so only the before/after byte identity can refuse publication.
compiled=len(compile_calls)
mutate_during_compile=True
changed_out=fixture/'core-rules/changed-during-native'
assert build('x86_64-unknown-linux-musl','Linux',changed_out)==1, 'mid-build input change accepted'
assert 'build inputs changed during compilation' in build.error and not changed_out.exists(), build.error
assert len(compile_calls)==compiled+1, 'mid-build test did not reach compiler'
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
@test "native delivery Darwin: three TMPDIR lengths produce identical signed release bytes" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'native arm64 Darwin reproducibility only'
  tools="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.97.1-aarch64-apple-darwin/bin"
  [ -x "$tools/cargo" ] && [ -x "$tools/rustc" ] || skip 'pinned native toolchain unavailable; reproducibility unverified'
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR/reproducibility" <<'PY'
import json,os,pathlib,shutil,subprocess,sys
root=pathlib.Path(sys.argv[1]); fixture=pathlib.Path(sys.argv[2]); fixture.mkdir()
shutil.copytree(root/'native/trellis-hooks',fixture/'native/trellis-hooks',ignore=shutil.ignore_patterns('target'))
(fixture/'scripts').mkdir(); shutil.copy2(root/'scripts/build-native-hooks.sh',fixture/'scripts/build-native-hooks.sh')
# A checkout carries its release version (core-rules/VERSION); not an input.
(fixture/'core-rules').mkdir(parents=True,exist_ok=True); shutil.copy2(root/'core-rules/VERSION',fixture/'core-rules/VERSION')
# A real crate now embeds canonical sources outside native/. Copy the exact
# mechanically discovered closure, never maintain a second fixture allowlist.
text=(root/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
ns={}; exec(compile(text.split('\ntry:\n',1)[0],'build-native-hooks.sh','exec'),ns)
for name in ns['include_inputs'](root):
    destination=fixture/name
    if not destination.exists():
        destination.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(root/name,destination)
for args in (['init','-q'],['add','.'],['commit','-qm','reproducible inputs']):
    subprocess.run(['git','-C',str(fixture),'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false',
                    '-c','user.name=Repro Fixture','-c','user.email=fixture@example.invalid',*args],check=True)
reference=None
for name in ('t','temporary-middle','temporary-'+'long-'*12):
    tmp=fixture.parent/name; tmp.mkdir(mode=0o700)
    assets=fixture.parent/('assets-'+name)
    env=dict(os.environ,TMPDIR=str(tmp))
    subprocess.run(['bash',str(fixture/'scripts/build-native-hooks.sh'),'build','aarch64-apple-darwin',str(assets)],
                   env=env,check=True)
    d=json.loads((assets/'artifacts.json').read_text())
    data=(assets/'aarch64-apple-darwin/trellis-hooks').read_bytes()
    value=(d['generation'],data,(assets/'hook-adapter.sh').read_bytes())
    if reference is None:
        reference=value
    assert value==reference, 'release bytes depend on TMPDIR length '+str(len(str(tmp)))
    subprocess.run(['bash',str(fixture/'scripts/build-native-hooks.sh'),'verify','--source',str(fixture),str(assets)],check=True)
    print('TMPDIR length',len(str(tmp)),'sha256',d['assets']['aarch64-apple-darwin']['sha256'])
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

source_verification_case() {
  python3 -I - "$ROOT" "$BATS_TEST_TMPDIR/source-verification" "$1" <<'PY'
import hashlib,json,os,pathlib,re,subprocess,sys
root=pathlib.Path(sys.argv[1]); fixture=pathlib.Path(sys.argv[2]); fixture.mkdir()
case=sys.argv[3]
script=root/'scripts/build-native-hooks.sh'
fixture_env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}

def git(*args):
    return subprocess.check_output(['git','-C',str(fixture),'-c','core.hooksPath=/dev/null',
        '-c','commit.gpgsign=false','-c','user.name=Source Fixture',
        '-c','user.email=fixture@example.invalid',*args],env=fixture_env).decode().strip()

def check(arguments,error=None,env=None):
    result=subprocess.run(['bash',str(script),*map(str,arguments)],cwd=fixture.parent,
                          env=fixture_env if env is None else env,
                          stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    if error is None:
        assert result.returncode==0, result.stdout
    else:
        assert result.returncode==1 and error in result.stdout, result.stdout

paths={'native/trellis-hooks/Cargo.lock':b'lock',
       'native/trellis-hooks/rust-toolchain.toml':b'toolchain',
       'native/trellis-hooks/src/main.rs':b'fn main() {}\n',
       'scripts/build-native-hooks.sh':script.read_bytes()}
for name,data in paths.items():
    p=fixture/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(data)
# A checkout carries its release version; it is not a native build input.
version=(root/'core-rules/VERSION').read_text().strip()
(fixture/'core-rules').mkdir(); (fixture/'core-rules/VERSION').write_text(version+'\n')
git('init','-q'); git('add','.'); git('commit','-qm','source')
inputs={p:hashlib.sha256(data).hexdigest() for p,data in paths.items()}
assets=fixture/'core-rules/native'; assets.mkdir(parents=True)
elf=bytearray(120); elf[:6]=b'\x7fELF\x02\x01'; elf[18:20]=(62).to_bytes(2,'little')
elf[32:40]=(64).to_bytes(8,'little'); elf[54:56]=(56).to_bytes(2,'little')
elf[56:58]=(1).to_bytes(2,'little'); elf[64:68]=(1).to_bytes(4,'little')
def record(name,data):
    p=assets/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(data); p.chmod(0o755)
    return dict(path=name,size=len(data),sha256=hashlib.sha256(data).hexdigest())
d=dict(schema_version=1,version=version,source_commit=git('rev-parse','HEAD'),inputs=inputs,
       toolchain=dict(channel='1.97.1',rustc='rustc 1.97.1 (8bab26f4f 2026-07-14)',
           cargo_lock_sha256=inputs['native/trellis-hooks/Cargo.lock'],
           rust_toolchain_sha256=inputs['native/trellis-hooks/rust-toolchain.toml']),
       install_path='bin/native/{version}/{target}/{sha256}/trellis-hooks',
       adapter=record('hook-adapter.sh',b'exit 0\n'),
       assets={'x86_64-unknown-linux-musl':dict(record('x86_64-unknown-linux-musl/trellis-hooks',elf),
           format='elf-static',signature='none',minimum_os=None)})
def manifest():
    identity={k:d[k] for k in ('version','inputs','toolchain')}
    d['generation']=hashlib.sha256(json.dumps(identity,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    (assets/'artifacts.json').write_text(json.dumps(d))
manifest()
source=['verify','--source',fixture,assets]
check(source); check(['verify',assets])
if case=='replace':
    x=git('rev-parse','HEAD')
    key='native/trellis-hooks/src/main.rs'; p=fixture/key
    p.write_bytes(paths[key]+b'// replacement bytes\n')
    git('add',key); git('commit','-qm','replacement'); y=git('rev-parse','HEAD')
    git('update-ref','HEAD',x)  # Leave Y's index and worktree bytes in place.
    git('replace',x,y)
    assert git('rev-parse','HEAD')==x and git('show','HEAD:'+key).encode()==p.read_bytes().rstrip(b'\n')
    d['inputs'][key]=hashlib.sha256(p.read_bytes()).hexdigest(); manifest()
    check(['verify',assets])
    check(source,'dirty native build input')
    print('replace ref cannot attest Y bytes under HEAD X')
    sys.exit(0)
if case=='git-dir':
    foreign=fixture.parent/'foreign'; foreign.mkdir()
    subprocess.run(['git','init','-q',str(foreign)],env=fixture_env,check=True)
    # Even unrelated/hostile repository and object/index/config redirections
    # must not override the explicit checkout or our no-replacements setting.
    inherited=dict(fixture_env,GIT_DIR=str(foreign/'.git'),GIT_WORK_TREE=str(foreign),
                   GIT_INDEX_FILE=str(foreign/'no-index'),GIT_NO_REPLACE_OBJECTS='0',
                   GIT_OBJECT_DIRECTORY=str(foreign/'no-objects'),
                   GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='core.bare',GIT_CONFIG_VALUE_0='true')
    check(source,env=inherited)
    check(['verify',assets],env=inherited)
    print('inherited GIT_DIR and other GIT_ variables cannot redirect source checks')
    sys.exit(0)
assert case=='baseline', case
script=fixture/'scripts/build-native-hooks.sh'
check(['verify','--source',fixture])  # default asset directory of the tool's checkout
script=root/'scripts/build-native-hooks.sh'
check(['verify','--source',fixture/'native',assets],'source must be a checkout root')
# A newer HEAD outside build scope is valid: source_commit is not generation.
(fixture/'asset-receipt.txt').write_text('asset-only commit\n')
git('add','.'); git('commit','-qm','receipt'); check(source)
p=fixture/'native/trellis-hooks/src/main.rs'; original=p.read_bytes()
p.write_bytes(original+b'// dirty\n'); check(source,'dirty native build input'); p.write_bytes(original)
for flag,clear in (('--skip-worktree','--no-skip-worktree'),('--assume-unchanged','--no-assume-unchanged')):
    git('update-index',flag,str(p.relative_to(fixture)))
    check(source,'flagged native build input')
    git('update-index',clear,str(p.relative_to(fixture)))
extra=fixture/'native/trellis-hooks/include.txt'; extra.write_text('new input')
check(source,'untracked native build input')
git('add','.'); git('commit','-qm','include'); check(source,'source input set/digest mismatch')
git('rm',str(extra.relative_to(fixture))); git('commit','-qm','remove include'); check(source)
# Self-consistent stale manifest still verifies alone, but not against checkout.
p.write_bytes(original+b'// committed change\n'); git('add','.'); git('commit','-qm','change')
check(['verify',assets]); check(source,'source input set/digest mismatch')
p.write_bytes(original); git('add','.'); git('commit','-qm','restore'); check(source)
# Missing manifest input and wrong digest are separately refused even when the
# generation has been recomputed, so manifest integrity cannot mask the check.
key='native/trellis-hooks/src/main.rs'; saved=d['inputs'].pop(key); manifest()
check(['verify',assets]); check(source,'source input set/digest mismatch')
d['inputs'][key]='0'*64; manifest()
check(['verify',assets]); check(source,'source input set/digest mismatch')
d['inputs'][key]=saved; manifest(); check(source)
# Simulate a cached-stat false clean: matching on-disk/manifest bytes must not
# substitute for the committed blobs even when git diff reports clean.
from unittest.mock import patch
text=script.read_text().split("<<'PY'\n",1)[1].split('\ntry:\n    args = sys.argv[2:]',1)[0]
ns={'__name__':'source_fixture'}; exec(compile(text,'build-native-hooks.sh','exec'),ns)
p.write_bytes(original+b'// cached stat\n'); d['inputs'][key]=hashlib.sha256(p.read_bytes()).hexdigest(); manifest()
real_run=subprocess.run
def cached_stat(args,**kwargs):
    if args[:4]==['git','-C',str(fixture),'diff']:
        return subprocess.CompletedProcess(args,0)
    return real_run(args,**kwargs)
with patch('subprocess.run',side_effect=cached_stat):
    try:
        ns['verify_source'](assets,fixture)
    except ValueError as e:
        assert 'source inputs differ from checkout HEAD' in str(e), str(e)
    else:
        raise AssertionError('uncommitted bytes accepted with cached-stat false clean')
p.write_bytes(original); d['inputs'][key]=saved; manifest(); check(source)
print('source verification: clean/asset-only pass; dirty, flags, untracked, set and digest refuse')
PY
}

@test "native delivery: source verification binds an explicit clean checkout without changing asset-only verify" {
  run source_verification_case baseline
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery: source verification refuses replace-ref provenance" {
  run source_verification_case replace
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery: source verification scrubs inherited GIT_DIR and all GIT_ redirections" {
  run source_verification_case git-dir
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
@test "native delivery: every literal include target is declared and hashed, including B2 launcher" {
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR/include-inputs" <<'PY'
import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); fixture=pathlib.Path(sys.argv[2]); fixture.mkdir()
script=(root/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
ns={}; saved=sys.argv; sys.argv=['build-native-hooks',str(fixture)]
try: exec(compile(script.split('\ntry:\n',1)[0],'build-native-hooks.sh','exec'),ns)
finally: sys.argv=saved
files={
 'scripts/build-native-hooks.sh':(root/'scripts/build-native-hooks.sh').read_bytes(),
 'native/trellis-hooks/Cargo.toml':b'[package]\nname="include-fixture"\nversion="0.1.0"\n',
 'native/trellis-hooks/Cargo.lock':b'version = 4\n',
 'native/trellis-hooks/rust-toolchain.toml':b'[toolchain]\nchannel="1.97.1"\n',
 'native/trellis-hooks/src/launcher.rs':b'const LAUNCHER: &str = include_str!("../../../scripts/trellis-launcher.sh");\n',
 'native/trellis-hooks/src/data.rs':br'''// include_str!("../../../must-not-open")
/* nested /* include_bytes!("missing") */ still comment */
const TEXT: &str = r###"include_str!("not-a-real-target")"###;
const RAW_BYTES: &[u8] = br###"include_bytes!("not-a-real-target")"###;
const OPAQUE: &[u8] = b"\xff";
const BYTES: &[u8] = std::include_bytes! ( r#"../../../data/bytes.bin"# , );
const NOTE: &str = include_str!("../../../data/\u{6e}ote.txt");
const SPACE: &[u8] = include_bytes!("../../../ leading.dat");
''',
 'scripts/trellis-launcher.sh':b'#!/bin/sh\nprintf launcher\n',
 'data/bytes.bin':b'\x00\xffopaque\x00', 'data/note.txt':b'complete include bytes\n',
 ' leading.dat':b'leading filename space\n'}
for name,body in files.items():
    p=fixture/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(body)
def git(*args): return subprocess.check_output(['git','-C',str(fixture),*args],stderr=subprocess.STDOUT).decode().strip()
git('init','-q','-b','main'); git('add','.'); git('-c','user.name=test','-c','user.email=test@example.com','commit','-qm','fixture')
inputs=ns['build_inputs'](fixture)
for name in ('scripts/trellis-launcher.sh','data/bytes.bin','data/note.txt',' leading.dat'):
    assert inputs.get(name)==hashlib.sha256(files[name]).hexdigest(), 'include target omitted from declared inputs: '+name
# The self-contained schema accepts canonical repository-relative include keys;
# only --source makes the stronger exact source-closure assertion below.
identity={'version':ns['VERSION'],'inputs':inputs,'toolchain':{
 'channel':'1.97.1','rustc':ns['RUSTC_VERSION'],
 'cargo_lock_sha256':inputs['native/trellis-hooks/Cargo.lock'],
 'rust_toolchain_sha256':inputs['native/trellis-hooks/rust-toolchain.toml']}}
doc=dict(identity,schema_version=1,source_commit=git('rev-parse','HEAD'),
 generation=ns['sha'](json.dumps(identity,sort_keys=True,separators=(',',':')).encode()),
 adapter={},install_path=ns['INSTALL'],assets={'aarch64-apple-darwin':{}})
manifest=fixture/'schema'; manifest.mkdir(); (manifest/'artifacts.json').write_text(json.dumps(doc))
assert ns['read_manifest'](manifest)['inputs']==inputs
assert not any('must-not-open' in p or 'not-a-real-target' in p for p in inputs)
# Outside-native inputs get the same dirtiness/index-flag boundary as Rust.
launcher=fixture/'scripts/trellis-launcher.sh'; original=launcher.read_bytes()
launcher.write_bytes(original+b'# dirty\n')
try: ns['build_inputs'](fixture)
except ValueError as e: assert 'dirty native build input' in str(e), str(e)
else: raise AssertionError('dirty outside-native include accepted')
launcher.write_bytes(original)
for flag,clear in (('--skip-worktree','--no-skip-worktree'),('--assume-unchanged','--no-assume-unchanged')):
    git('update-index',flag,'scripts/trellis-launcher.sh')
    try: ns['build_inputs'](fixture)
    except ValueError as e: assert 'flagged native build input' in str(e), str(e)
    else: raise AssertionError('flagged outside-native include accepted')
    git('update-index',clear,'scripts/trellis-launcher.sh')
launcher.write_bytes(original+b'# committed\n'); git('add','scripts/trellis-launcher.sh')
git('-c','user.name=test','-c','user.email=test@example.com','commit','-qm','outside include changed')
updated=ns['build_inputs'](fixture)
assert updated['scripts/trellis-launcher.sh']!=inputs['scripts/trellis-launcher.sh']
assert ns['build_source_commit'](fixture)==git('rev-parse','HEAD'), 'outside-native provenance omitted'
# Exact source verification must refuse a manifest omitting ANY include leaf.
# Structural asset verification is independently covered by the existing corpus.
ns['verify']=lambda base: {'inputs':updated}
ns['verify_source'](fixture,fixture)
for omitted in ('scripts/trellis-launcher.sh','data/bytes.bin','data/note.txt',' leading.dat'):
    ns['verify']=lambda base: {'inputs':{k:v for k,v in updated.items() if k!=omitted}}
    try: ns['verify_source'](fixture,fixture)
    except ValueError as e: assert 'source input set/digest mismatch' in str(e), str(e)
    else: raise AssertionError('undeclared include target accepted: '+omitted)
print('all include targets declared/hashed; missing leaves, dirty bytes and hidden-index flags refused')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "native delivery: include discovery fails closed on computed, escaped-root and symlink targets" {
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR/include-refusals" <<'PY'
import pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); fixture=pathlib.Path(sys.argv[2]); fixture.mkdir()
script=(root/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
ns={}; saved=sys.argv; sys.argv=['build-native-hooks',str(fixture)]
try: exec(compile(script.split('\ntry:\n',1)[0],'build-native-hooks.sh','exec'),ns)
finally: sys.argv=saved
source=fixture/'native/trellis-hooks/src/lib.rs'; source.parent.mkdir(parents=True)
(fixture/'scripts').mkdir(); (fixture/'scripts/build-native-hooks.sh').write_text(script)
(fixture/'data').mkdir(); (fixture/'data/plain.txt').write_text('data')
(fixture/'data/linked.txt').symlink_to('plain.txt')
(fixture/'data/linked-dir').symlink_to('.',target_is_directory=True)
def git(*args): return subprocess.check_output(['git','-C',str(fixture),*args],stderr=subprocess.STDOUT).decode().strip()
git('init','-q','-b','main')
for body,expected in [
 ('const X: &str=include_str!(concat!("../../../data/", "plain.txt"));\n','literal'),
 ('use std::include_str as read; const X: &str=read!("../../../data/plain.txt");\n','aliased'),
 ('const X: &str=include_str!("../../../../outside.txt");\n','outside'),
 ('const X: &str=include_str!("../../../data/linked.txt");\n','symlink'),
 ('const X: &str=include_str!("../../../data/linked-dir/../data/plain.txt");\n','symlink'),
 ('const X: &str=include_str!("../../../data/missing.txt");\n','missing')]:
    source.write_text(body); git('add','.'); git('-c','user.name=test','-c','user.email=test@example.com','commit','-qm',expected)
    try: ns['build_inputs'](fixture)
    except (ValueError,OSError) as e: assert expected in str(e).lower(), (expected,str(e))
    else: raise AssertionError('unsafe or unresolved include accepted: '+expected)
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
@test "native delivery: out-of-crate module declarations cannot hide compiler inputs" {
  run python3 -I - "$ROOT" "$BATS_TEST_TMPDIR/external-modules" <<'PY'
import pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); fixture=pathlib.Path(sys.argv[2]); fixture.mkdir()
script=(root/'scripts/build-native-hooks.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
ns={}; saved=sys.argv; sys.argv=['build-native-hooks',str(fixture)]
try: exec(compile(script.split('\ntry:\n',1)[0],'build-native-hooks.sh','exec'),ns)
finally: sys.argv=saved
source=fixture/'native/trellis-hooks/src/lib.rs'; source.parent.mkdir(parents=True)
(fixture/'scripts').mkdir(); (fixture/'scripts/build-native-hooks.sh').write_text(script)
(fixture/'gen').mkdir(); (fixture/'gen/mod.rs').write_text('pub mod child;\n')
(fixture/'gen/child.rs').write_text('pub fn value() -> u8 { 1 }\n')
def git(*args): return subprocess.check_output(['git','-C',str(fixture),*args],stderr=subprocess.STDOUT).decode().strip()
git('init','-q','-b','main')
for body in ('#[path="../../../gen/mod.rs"] pub mod generated;\n',
             'include!("../../../gen/mod.rs");\n'):
    source.write_text(body); git('add','.'); git('-c','user.name=test','-c','user.email=test@example.com','commit','-qm','external module route')
    try: ns['build_inputs'](fixture)
    except ValueError as e:
        assert 'out-of-crate module' in str(e), str(e)
    else: raise AssertionError('external mod child escaped source hashes, dirty checks and provenance')
# An out-of-crate include can itself include tracked in-crate Rust. Its module
# resolution context must not become trusted merely because that file is seeded.
source.write_text('include!("../../../gen/mod.rs");\n')
(fixture/'gen/mod.rs').write_text('include!("../native/trellis-hooks/src/z_embedded.rs");\n')
(fixture/'native/trellis-hooks/src/z_embedded.rs').write_text('pub mod child;\n')
git('add','.'); git('-c','user.name=test','-c','user.email=test@example.com','commit','-qm','transitive include context')
try: ns['build_inputs'](fixture)
except ValueError as e: assert 'out-of-crate module' in str(e), str(e)
else: raise AssertionError('transitive include erased its external module context')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
# END A3 T6 build and manifest

# BEGIN B1 T55 install rollback and concurrency
# shellcheck source=scripts/tests/helpers/hfs-volume.bash
. "$BATS_TEST_DIRNAME/helpers/hfs-volume.bash"
teardown() {
  hfs_volume_detach
  if [ -d "$BATS_TEST_TMPDIR/trellis/releases" ]; then
    find "$BATS_TEST_TMPDIR/trellis/releases" -depth -type d -exec chmod u+w {} +
  fi
}

# T35/T37: the native-pair tests run on every host the release ships an
# asset for, with portable inode, mode and digest helpers; codesign applies
# to Darwin only (Linux assets are static ELF bound by their digest).
b1_native_host() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) B1_TARGET=aarch64-apple-darwin ;;
    Linux:x86_64) B1_TARGET=x86_64-unknown-linux-musl ;;
    *) skip "no native asset ships for $(uname -s) $(uname -m); see native delivery legacy host" ;;
  esac
}
b1_inode() { if [ "$(uname -s)" = Darwin ]; then stat -f '%i' "$1"; else stat -c '%i' "$1"; fi; }
b1_mode() { if [ "$(uname -s)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi; }
b1_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
b1_verify_signature() { [ "$(uname -s)" != Darwin ] || /usr/bin/codesign --verify --strict "$1"; }

b1_install_candidate_release() {
  REPO_ROOT="$ROOT"
  source "$ROOT/scripts/tests/helpers/payload-fixture.bash"
  local version="${2:-1.5.0}" repo="$BATS_TEST_TMPDIR/candidate-source-${2:-1.5.0}"
  payload_fixture_source "$repo" "$version"
  printf '{}\n' > "$repo/trellis.config.json"
  cp -R "$ASSETS" "$repo/core-rules/native"
  jq --arg version "$version" '.version=$version' "$repo/core-rules/native/artifacts.json" > "$repo/core-rules/native/artifacts.next"
  mv "$repo/core-rules/native/artifacts.next" "$repo/core-rules/native/artifacts.json"
  # T36/T38 legacy host: a release that ships no asset for this host, as the
  # real manifest is for x86_64 macOS (D3). On such a host this is a no-op.
  if [ -n "${B1_DROP_HOST_TARGET:-}" ]; then
    local host_target=''
    case "$(uname -s):$(uname -m)" in
      Darwin:arm64) host_target=aarch64-apple-darwin ;;
      Linux:x86_64) host_target=x86_64-unknown-linux-musl ;;
      Linux:aarch64) host_target=aarch64-unknown-linux-musl ;;
    esac
    if [ -n "$host_target" ]; then
      jq --arg t "$host_target" 'del(.assets[$t])' "$repo/core-rules/native/artifacts.json" > "$repo/core-rules/native/artifacts.next"
      mv "$repo/core-rules/native/artifacts.next" "$repo/core-rules/native/artifacts.json"
      rm -rf "${repo:?}/core-rules/native/$host_target"
    fi
  fi
  cp "$ROOT/scripts/trellis-launcher.sh" "$ROOT/scripts/trellis" \
    "$ROOT/scripts/configure.sh" "$ROOT/scripts/attach-project.sh" "$ROOT/scripts/upgrade.sh" "$repo/scripts/"
  cp -R "$ROOT/scripts/lib" "$repo/scripts/lib"
  chmod 755 "$repo/scripts/trellis-launcher.sh" "$repo/scripts/trellis" "$repo/scripts/configure.sh"
  payload_fixture_git -C "$repo" add -A
  payload_fixture_git -C "$repo" commit -qm 'candidate release'
  payload_fixture_tag "$repo" "$version" HEAD
  mkdir -p "$BATS_TEST_TMPDIR/trellis" "$BATS_TEST_TMPDIR/user" "$BATS_TEST_TMPDIR/projects"
  chmod 700 "$BATS_TEST_TMPDIR/trellis" "$BATS_TEST_TMPDIR/user"
  B1_REPO="$repo"
  B1_VERSION="$version"
  B1_PAYLOAD="$BATS_TEST_TMPDIR/trellis/releases/$version/payload"
  if [ "${1:-}" = source-only ]; then return 0; fi
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" bash -c \
    '. "$1/scripts/lib/release-store.sh"; release_store_install "$3" "$2"' _ "$ROOT" "$repo" "$version"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "B1 T55: configure installs the verified native companion before its pinned launcher" {
  b1_native_host
  b1_install_candidate_release
  local digest companion launcher source
  digest="$(jq -r --arg t "$B1_TARGET" '.assets[$t].sha256' "$B1_PAYLOAD/core-rules/native/artifacts.json")"
  companion="$BATS_TEST_TMPDIR/trellis/bin/native/1.5.0/$B1_TARGET/$digest/trellis-hooks"
  launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  source="$B1_PAYLOAD/core-rules/native/$B1_TARGET/trellis-hooks"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    bash "$ROOT/scripts/configure.sh" --source "$B1_REPO" --active-cli-release 1.5.0 \
    --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$companion" ] && [ ! -L "$companion" ]
  cmp -s "$source" "$companion"
  [ "$(b1_mode "$companion")" = 500 ]
  [ "$(b1_inode "$source")" != "$(b1_inode "$companion")" ]
  grep -F "$companion" "$launcher"
  b1_verify_signature "$companion"
}
b1_configure_pair() {
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    bash "$ROOT/scripts/configure.sh" --source "$B1_REPO" --active-cli-release "$B1_VERSION" \
    --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
}

@test "B1 T55: pair publication is idempotent and custom launcher collisions refuse" {
  b1_native_host
  b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis" before
  before="$(b1_inode "$launcher")"
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(b1_inode "$launcher")" = "$before" ]
  printf '\n# operator customization\n' >> "$launcher"
  cp "$launcher" "$BATS_TEST_TMPDIR/custom-launcher"
  b1_configure_pair
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$BATS_TEST_TMPDIR/custom-launcher"
}

@test "B1 T55: a changed companion refuses without publishing a launcher" {
  b1_native_host
  b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis" companion
  cp "$launcher" "$BATS_TEST_TMPDIR/old-launcher"
  companion="$(find "$BATS_TEST_TMPDIR/trellis/bin/native" -type f -name trellis-hooks)"
  chmod u+w "$companion"
  printf changed >> "$companion"
  chmod 500 "$companion"
  b1_configure_pair
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"changed immutable pair entry"* ]] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$BATS_TEST_TMPDIR/old-launcher"
}

@test "B1 T55: old and new launcher readers retain complete bytes and fresh inodes" {
  b1_native_host
  b1_install_candidate_release
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  mkdir -p "${launcher%/*}"
  cp "$B1_PAYLOAD/scripts/trellis-launcher.sh" "$launcher"
  exec 9< "$launcher"
  local old_inode="$(b1_inode "$launcher")"
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(b1_inode "$launcher")" != "$old_inode" ]
  /bin/cat <&9 > "$BATS_TEST_TMPDIR/old-reader"
  exec 9<&-
  cmp -s "$BATS_TEST_TMPDIR/old-reader" "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  grep -F 'launcher_native_entry=' "$launcher" | grep -F '/bin/native/'
  # The retained immutable launchers are byte-exact rollback/reader entries.
  local ledger
  ledger="$(find "$BATS_TEST_TMPDIR/trellis/bin/launchers" -type f -name trellis)"
  cmp -s "$ledger" "$launcher"
}

@test "B1 T55: failed config publication restores the prior launcher pair" {
  b1_native_host
  b1_install_candidate_release
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis" script="$BATS_TEST_TMPDIR/configure-failure.sh"
  mkdir -p "${launcher%/*}"
  cp "$B1_PAYLOAD/scripts/trellis-launcher.sh" "$launcher"
  cp "$launcher" "$BATS_TEST_TMPDIR/old-launcher"
  # Derive the real configure body with only its config-write operation faulted.
  python3 -I - "$ROOT/scripts/configure.sh" "$script" "$ROOT/scripts" <<'PY'
from pathlib import Path
import sys
source,out,script_dir=sys.argv[1:]
s=Path(source).read_text(); needle='  if trellis_home_atomic_write_json "$cfg" "$proposed"; then'
assert s.count(needle)==1
s=s.replace(needle,'  if false; then')
s=s.replace('SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"','SCRIPT_DIR='+repr(script_dir))
Path(out).write_text(s)
PY
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    bash "$script" --source "$B1_REPO" --active-cli-release 1.5.0 \
    --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$BATS_TEST_TMPDIR/old-launcher"
  [ ! -e "$BATS_TEST_TMPDIR/trellis/config.json" ]
}

@test "B1 T55: symlinked native directories refuse and outside bytes remain untouched" {
  b1_native_host
  b1_install_candidate_release
  mkdir -p "$BATS_TEST_TMPDIR/trellis/bin" "$BATS_TEST_TMPDIR/outside"
  chmod 700 "$BATS_TEST_TMPDIR/trellis/bin"
  printf unchanged > "$BATS_TEST_TMPDIR/outside/marker"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/trellis/bin/native"
  b1_configure_pair
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ "$(< "$BATS_TEST_TMPDIR/outside/marker")" = unchanged ]
  [ ! -e "$BATS_TEST_TMPDIR/user/.local/bin/trellis" ]
}
@test "B1 T55: actual 1.4.0 first-hop launcher remains legacy until second configure" {
  b1_native_host
  b1_install_candidate_release source-only
  local old="$BATS_TEST_TMPDIR/old-source" launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  mkdir -p "$old" "${launcher%/*}"
  git -C "$ROOT" archive v1.4.0 -- scripts core-rules trellis.config.json | tar -x -C "$old"
  payload_fixture_git -C "$old" init -q
  payload_fixture_git -C "$old" add -A
  payload_fixture_git -C "$old" commit -qm 'historical 1.4.0 fixture'
  payload_fixture_tag "$old" 1.4.0 HEAD
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" bash -c \
    '. "$1/scripts/lib/release-store.sh"; release_store_install 1.4.0 "$1"' _ "$old"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cp "$old/scripts/trellis-launcher.sh" "$launcher"
  chmod 755 "$launcher"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    bash "$old/scripts/configure.sh" --source "$B1_REPO" --release 1.4.0 --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher" release install 1.5.0 --remote "$B1_REPO"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mv "$launcher" "$launcher.before"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher.before" configure --release 1.5.0 --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ ! -e "$BATS_TEST_TMPDIR/trellis/bin/native" ]
  mkdir -p "$BATS_TEST_TMPDIR/project" "$BATS_TEST_TMPDIR/hostile-bin"
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$BATS_TEST_TMPDIR/planted-ran" > "$BATS_TEST_TMPDIR/hostile-bin/trellis-hooks"
  chmod 755 "$BATS_TEST_TMPDIR/hostile-bin/trellis-hooks"
  cp "$BATS_TEST_TMPDIR/hostile-bin/trellis-hooks" "$BATS_TEST_TMPDIR/project/trellis-hooks"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    PATH="$BATS_TEST_TMPDIR/hostile-bin:$PATH" "$launcher" --version
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *1.5.0* ]] || false
  # This interruption point is a usable legacy launcher; retry completes.
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    PATH="$BATS_TEST_TMPDIR/hostile-bin:$PATH" "$launcher" configure --release 1.5.0 \
    --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep '^launcher_native_entry=' "$launcher" | grep -F '/bin/native/'
  local inode="$(b1_inode "$launcher")"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher" configure --release 1.5.0 --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "idempotent configure exited $status: $output"; return 1; }
  [ "$(b1_inode "$launcher")" = "$inode" ]
  [ ! -e "$BATS_TEST_TMPDIR/planted-ran" ]
}
# 1.5.1: the documented two-configure first hop with a committed user
# attachment, from the real 1.4.1 code. The first configure (old launcher, no
# companion yet) relinks the user surface through the 1.5.x payload: it must
# render the complete legacy user template, not refuse on the missing
# companion; the second configure stages the companion and renders native.
@test "1.5.1: real 1.4.1 first hop with a user attachment renders legacy, then native on the second configure" {
  b1_native_host
  REPO_ROOT="$ROOT"
  source "$ROOT/scripts/tests/helpers/payload-fixture.bash"
  local old="$BATS_TEST_TMPDIR/old-source" launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  local settings="$BATS_TEST_TMPDIR/user/.claude/settings.json" owner rel
  # The release under test is the one the committed native manifest names.
  rel="$(jq -r .version "$ROOT/core-rules/native/artifacts.json")"
  # The real 1.5.x payload: committed core-rules, and this checkout's scripts.
  B1_REPO="$BATS_TEST_TMPDIR/candidate-source-real"
  B1_PAYLOAD="$BATS_TEST_TMPDIR/trellis/releases/$rel/payload"
  mkdir -p "$B1_REPO" "$BATS_TEST_TMPDIR/trellis" "$BATS_TEST_TMPDIR/user"
  chmod 700 "$BATS_TEST_TMPDIR/trellis" "$BATS_TEST_TMPDIR/user"
  git -C "$ROOT" archive HEAD -- core-rules trellis.config.json | tar -x -C "$B1_REPO"
  cp -R "$ROOT/scripts" "$B1_REPO/scripts"
  [ "$(cat "$B1_REPO/core-rules/VERSION")" = "$rel" ] ||
    printf '%s\n' "$rel" > "$B1_REPO/core-rules/VERSION"
  payload_fixture_git -C "$B1_REPO" init -q
  payload_fixture_git -C "$B1_REPO" add -A
  payload_fixture_git -C "$B1_REPO" commit -qm 'real candidate release'
  payload_fixture_tag "$B1_REPO" "$rel" HEAD
  mkdir -p "$old" "${launcher%/*}" "$BATS_TEST_TMPDIR/user/.claude"
  git -C "$ROOT" archive v1.4.1 -- scripts core-rules trellis.config.json | tar -x -C "$old"
  payload_fixture_git -C "$old" init -q
  payload_fixture_git -C "$old" add -A
  payload_fixture_git -C "$old" commit -qm 'historical 1.4.1 fixture'
  payload_fixture_tag "$old" 1.4.1 HEAD
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" bash -c \
    '. "$1/scripts/lib/release-store.sh"; release_store_install 1.4.1 "$1"' _ "$old"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cp "$old/scripts/trellis-launcher.sh" "$launcher"
  chmod 755 "$launcher"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    bash "$old/scripts/configure.sh" --source "$B1_REPO" --release 1.4.1 --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher" attach --user
  [ "$status" -eq 0 ] || { echo "1.4.1 attach --user: $output"; return 1; }
  jq -e '.hooks.WorktreeCreate[0].hooks[0].command | contains("trellis-worktree-create.sh")' "$settings" >/dev/null ||
    { cat "$settings"; return 1; }

  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher" release install "$rel" --remote "$B1_REPO"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mv "$launcher" "$launcher.before"
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher.before" configure --release "$rel" --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "first configure: $output"; return 1; }
  [[ "$output" != *"contextual registration refused"* ]] || { echo "$output"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/trellis/bin/native" ] || false
  owner="$BATS_TEST_TMPDIR/trellis/attachments/user.json"
  jq -e --arg rel "$rel" '.release == $rel' "$owner" >/dev/null || { cat "$owner"; return 1; }
  # Complete legacy user surface: the launcher-free worktree callbacks.
  jq -e '[.hooks.WorktreeCreate[].hooks[], .hooks.WorktreeRemove[].hooks[]]
    | length == 2 and all(.[]; (.command | contains("/bin/native/") | not) and (has("args") | not))' "$settings" >/dev/null ||
    { cat "$settings"; return 1; }

  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    "$launcher" configure --release "$rel" --launcher-template "$B1_PAYLOAD/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "second configure: $output"; return 1; }
  grep '^launcher_native_entry=' "$launcher" | grep -F '/bin/native/'
  jq -e '[.hooks.WorktreeCreate[].hooks[], .hooks.WorktreeRemove[].hooks[]]
    | length == 2 and all(.[]; .command | contains("/bin/native/" + $rel + "/"))' --arg rel "$rel" "$settings" >/dev/null ||
    { cat "$settings"; return 1; }
  jq -e '.workflowSizeGuideline == "large"' "$settings" >/dev/null
}
@test "B1 T55: verified upgrade pair rolls back when adoption fails" {
  b1_native_host
  b1_install_candidate_release
  # /bin/bash is what the stable launcher runs this bundle under (3.2 on macOS).
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  mkdir -p "${launcher%/*}"
  cp "$B1_PAYLOAD/scripts/trellis-launcher.sh" "$launcher"
  cp "$launcher" "$BATS_TEST_TMPDIR/old-launcher"
  # The ordinary launcher suite proves bundle authentication; this probe faults
  # only the in-process adopt surface, with the real preloaded publication lib.
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    TRELLIS_VERIFIED_PAYLOAD="$B1_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.5.0 \
    /bin/bash -c '
      root="$1"; shift
      . "$root/scripts/lib/trellis-home.sh"
      . "$root/scripts/lib/release-store.sh"
      TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade
      TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=test-token
      trellis_command_bundle_is_verified() { [ "$1:$2" = upgrade:test-token ]; }
      release_command_main() { [ "$1" != adopt ] || return "${PAIR_ADOPT_EXIT:-42}"; }
      eval "$(awk '\''body { print } /^# -- trellis upgrade body --$/ { body=1 }'\'' "$root/scripts/upgrade.sh")"
    ' _ "$ROOT" 1.5.0 --all
  [ "$status" -eq 42 ] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$BATS_TEST_TMPDIR/old-launcher"
  [ -n "$(find "$BATS_TEST_TMPDIR/trellis/bin/native" -type f -name trellis-hooks)" ]
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
    TRELLIS_VERIFIED_PAYLOAD="$B1_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.5.0 \
    /bin/bash -c '
      root="$1"; shift
      . "$root/scripts/lib/trellis-home.sh"
      . "$root/scripts/lib/release-store.sh"
      TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade
      TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=test-token
      trellis_command_bundle_is_verified() { [ "$1:$2" = upgrade:test-token ]; }
      release_command_main() { return 0; }
      eval "$(awk '\''body { print } /^# -- trellis upgrade body --$/ { body=1 }'\'' "$root/scripts/upgrade.sh")"
    ' _ "$ROOT" 1.5.0 --all
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -F 'launcher_native_entry=' "$launcher" | grep -F '/bin/native/'
}
@test "B1 review delivery H1 pairs N to N+1 and a prerelease without overwriting old entries" {
  b1_native_host
  local version old_entry='' old_hash='' launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  for version in 1.5.0 1.5.1 1.6.0-rc.2; do
    b1_install_candidate_release '' "$version"
    b1_configure_pair
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -Fx "launcher_native_version='$version'" "$launcher"
    if [ -n "$old_entry" ]; then
      [ "$(b1_sha256 "$old_entry")" = "$old_hash" ]
    fi
    old_entry="$(find "$BATS_TEST_TMPDIR/trellis/bin/native/$version" -type f -name trellis-hooks)"
    old_hash="$(b1_sha256 "$old_entry")"
    cmp -s "$old_entry" "$B1_PAYLOAD/core-rules/native/$B1_TARGET/trellis-hooks"
  done
}

@test "B1 review delivery M3 accepts trusted symlink parents but not native subtree links" {
  b1_native_host
  b1_install_candidate_release
  local alias="$BATS_TEST_TMPDIR/trusted-alias" user="$BATS_TEST_TMPDIR/user"
  ln -s "$BATS_TEST_TMPDIR" "$alias"
  mkdir -p "$user/.local" "$BATS_TEST_TMPDIR/real-launchers"
  ln -s "$BATS_TEST_TMPDIR/real-launchers" "$user/.local/bin"
  run env HOME="$alias/user" TRELLIS_HOME="$alias/trellis" bash "$ROOT/scripts/configure.sh" \
    --source "$B1_REPO" --active-cli-release 1.5.0 --launcher-template "$alias/trellis/releases/1.5.0/payload/scripts/trellis-launcher.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -x "$BATS_TEST_TMPDIR/real-launchers/trellis" ]
  grep '^launcher_native_entry=' "$BATS_TEST_TMPDIR/real-launchers/trellis" | grep -F '/bin/native/1.5.0/'

  # A native subtree link (bin/native/1.5.0 -> outside) refuses, as the
  # bin/native-level case does: outside bytes unchanged, no launcher written.
  local outside="$BATS_TEST_TMPDIR/outside-subtree"
  mkdir -p "$outside"
  chmod 700 "$outside"
  printf unchanged > "$outside/marker"
  rm -rf "$BATS_TEST_TMPDIR/trellis/bin/native"
  mkdir -p "$BATS_TEST_TMPDIR/trellis/bin/native"
  chmod 700 "$BATS_TEST_TMPDIR/trellis/bin" "$BATS_TEST_TMPDIR/trellis/bin/native"
  ln -s "$outside" "$BATS_TEST_TMPDIR/trellis/bin/native/1.5.0"
  rm -f "$BATS_TEST_TMPDIR/real-launchers/trellis"
  b1_configure_pair
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"paired publication refused"* ]] || { echo "$output"; return 1; }
  [ "$(< "$outside/marker")" = unchanged ]
  [ ! -e "$outside/trellis-hooks" ]
  [ ! -e "$BATS_TEST_TMPDIR/user/.local/bin/trellis" ]
}
@test "B1 review delivery L3 a concurrent immutable publisher compares the winning bytes" {
  b1_native_host
  b1_install_candidate_release
  local derived="$BATS_TEST_TMPDIR/trusted-publisher-race.sh"
  # Deterministic syscall race in a derived trusted test library: the competing
  # writer publishes exactly these bytes before our no-replace link returns
  # EEXIST. No production seam, candidate code or installed-file edit.
  python3 -I - "$ROOT/scripts/lib/trellis-home.sh" "$derived" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();needle='template, destination, home, release_dir = map(Path, sys.argv[1:])'
assert s.count(needle)==1
s=s.replace(needle,needle+'''\nreal_link = os.link
def competing_link(*args, **kwargs):
    real_link(*args, **kwargs)
    if args[0].startswith('.pair.'):
        raise FileExistsError('fixture competitor won')
os.link = competing_link\n''')
Path(sys.argv[2]).write_text(s)
PY
  run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" bash -c '
    . "$1/scripts/lib/release-store.sh"
    . "$2"
    trellis_home_install_launcher "$3/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis" "$TRELLIS_HOME" 1.5.0
  ' _ "$ROOT" "$derived" "$B1_PAYLOAD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -Fx "launcher_native_version='1.5.0'" "$BATS_TEST_TMPDIR/user/.local/bin/trellis"
}

@test "B1 review delivery L4 pin selection rejects unknown targets extra components and traversal" {
  local block="$BATS_TEST_TMPDIR/pin-block.sh"
  python3 -I - "$ROOT/scripts/trellis-launcher.sh" "$block" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();s=s.split('# BEGIN B1 companion pin (T55).',1)[1].split('# END B1 companion pin (T55).',1)[0]
Path(sys.argv[2]).write_text('# extracted B1 selection-only block\n# BEGIN B1 companion pin (T55).'+s)
PY
  run bash -c '
    . "$1"
    home=/trusted; launcher_native_version=1.5.1-rc.2
    launcher_native_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    for target in aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
      launcher_native_entry="$home/bin/native/$launcher_native_version/$target/$launcher_native_sha256/trellis-hooks"
      launcher_native_companion_path "$home" >/dev/null || exit 91
    done
    for target in unknown aarch64-apple-darwin/extra aarch64-apple-darwin/../../escape; do
      launcher_native_entry="$home/bin/native/$launcher_native_version/$target/$launcher_native_sha256/trellis-hooks"
      launcher_native_companion_path "$home" >/dev/null; [ "$?" -eq 4 ] || exit 92
    done
    launcher_native_version=1.5.0/../escape
    launcher_native_entry="$home/bin/native/$launcher_native_version/aarch64-apple-darwin/$launcher_native_sha256/trellis-hooks"
    launcher_native_companion_path "$home" >/dev/null; [ "$?" -eq 4 ] || exit 93
  ' _ "$block"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# T37/T35: an ACL anywhere on the companion's private chain refuses
# publication (POSIX ACLs on Linux, extended ACLs on Darwin) and leaves the
# installed launcher pair untouched.
@test "B1 T55: an ACL on the native pair chain refuses publication and keeps the old pair" {
  b1_native_host
  b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis" chain="$BATS_TEST_TMPDIR/trellis/bin/native"
  cp "$launcher" "$BATS_TEST_TMPDIR/before-acl"
  if [ "$(uname -s)" = Darwin ]; then
    /bin/chmod +a 'everyone allow add_file,delete_child' "$chain" || skip 'ACL unsupported on this filesystem'
  else
    setfacl -m "u:$(id -u):rwx" "$chain" || skip 'ACL unsupported on this filesystem'
  fi
  b1_install_candidate_release '' 1.5.1
  b1_configure_pair
  [ "$status" -ne 0 ] || { echo "published through an ACL: $output"; return 1; }
  # Linux setfacl also widens the group bits through the ACL mask, so the
  # privacy check may refuse before the ACL check; both refuse publication.
  [[ "$output" == *"ACL on pair entry"* || "$output" == *"pair directory is not private"* ]] || { echo "$output"; return 1; }
  cmp -s "$launcher" "$BATS_TEST_TMPDIR/before-acl"
  if [ "$(uname -s)" = Darwin ]; then /bin/chmod -N "$chain"; else setfacl -b "$chain"; fi
}

# T35: the matching rollback in an isolated home. Configuring N again after
# N+1 re-pins N's retained companion; both immutable entries keep their bytes.
@test "B1 T55: rollback to N re-pins its retained companion and both entries stay byte-exact" {
  b1_native_host
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis" n_repo n_payload n_entry n_hash m_entry m_hash entry
  b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  n_repo="$B1_REPO" n_payload="$B1_PAYLOAD"
  n_entry="$(find "$BATS_TEST_TMPDIR/trellis/bin/native/1.5.0" -type f -name trellis-hooks)"
  n_hash="$(b1_sha256 "$n_entry")"
  b1_install_candidate_release '' 1.5.1
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -Fx "launcher_native_version='1.5.1'" "$launcher"
  m_entry="$(find "$BATS_TEST_TMPDIR/trellis/bin/native/1.5.1" -type f -name trellis-hooks)"
  m_hash="$(b1_sha256 "$m_entry")"
  B1_REPO="$n_repo" B1_PAYLOAD="$n_payload" B1_VERSION=1.5.0
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -Fx "launcher_native_version='1.5.0'" "$launcher"
  entry="$(sed -n "s/^launcher_native_entry='\(.*\)'$/\1/p" "$launcher")"
  [ "$entry" = "$n_entry" ] || { echo "pinned $entry, want $n_entry"; return 1; }
  [ "$(b1_sha256 "$n_entry")" = "$n_hash" ]
  [ "$(b1_sha256 "$m_entry")" = "$m_hash" ]
  run "$entry" contract
  [ "$status" -eq 0 ]
  b1_verify_signature "$entry"
}
# END B1 T55 install rollback and concurrency

# BEGIN C1 Darwin arm64 T35
@test "native delivery Darwin: final ad-hoc signature verifies" {
  [ "$(uname -s)" = Darwin ] || skip "Darwin only"
  codesign --verify --strict "$ASSETS/aarch64-apple-darwin/trellis-hooks"
}

@test "native delivery Darwin: a forged digest cannot conceal a broken signature" {
  [ "$(uname -s)" = Darwin ] || skip "Darwin only"
  copy_assets
  printf mutation >> "$COPY/aarch64-apple-darwin/trellis-hooks"
  python3 -I - "$COPY" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'artifacts.json').read_text())
a=d['assets']['aarch64-apple-darwin']; b=(p/a['path']).read_bytes()
a.update(size=len(b),sha256=hashlib.sha256(b).hexdigest())
(p/'artifacts.json').write_text(json.dumps(d))
PY
  run bash "$BUILD" verify "$COPY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature"* ]] || false
}

# T35: the shipped asset is the actual single-architecture arm64 Mach-O, built
# for the manifest's declared deployment target, so no compiler or SDK is
# needed at install or hook time.
@test "native delivery Darwin: the arm64 asset is arm64-only at the declared deployment target" {
  [ "$(uname -s)" = Darwin ] || skip "Darwin only"
  local asset="$ASSETS/aarch64-apple-darwin/trellis-hooks" declared minos
  [ "$(lipo -archs "$asset")" = arm64 ]
  declared="$(jq -r '.assets["aarch64-apple-darwin"] | select(.format == "mach-o") | .minimum_os' "$ASSETS/artifacts.json")"
  [ -n "$declared" ] && [ "$declared" != null ]
  minos="$(otool -l "$asset" | awk '/cmd LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }')"
  [ "$minos" = "$declared" ] || { echo "minos=$minos declared=$declared"; return 1; }
  run otool -L "$asset"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | sed 1d | grep -Ev '^[[:space:]]+/usr/lib/|^[[:space:]]+/System/Library/' || { echo "$output"; return 1; }
}

# T35: publishing N+1 never rewrites N in place. A companion still running
# from N finishes normally (no kernel signature-cache SIGKILL), and N's
# signed inode, bytes and mode are unchanged and still execute.
@test "native delivery Darwin: a running companion survives a newer pair publication on its own signed inode" {
  [ "$(uname -s):$(uname -m)" = 'Darwin:arm64' ] || skip 'Darwin arm64 candidate fixture'
  b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local old old_inode old_hash new fifo="$BATS_TEST_TMPDIR/event.fifo" pid rc
  old="$(find "$BATS_TEST_TMPDIR/trellis/bin/native/1.5.0" -type f -name trellis-hooks)"
  old_inode="$(stat -f '%i' "$old")" old_hash="$(shasum -a 256 "$old" | awk '{print $1}')"
  mkfifo "$fifo"
  ( set +e
    env -i HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" PATH=/usr/bin:/bin \
      "$old" event claude PreToolUse "$BATS_TEST_TMPDIR/projects" < "$fifo" > "$BATS_TEST_TMPDIR/running.out" 2>&1
    echo "$?" > "$BATS_TEST_TMPDIR/running.rc" ) &
  pid=$!
  exec 8> "$fifo"
  b1_install_candidate_release '' 1.5.1
  b1_configure_pair
  [ "$status" -eq 0 ] || { exec 8>&-; echo "$output"; return 1; }
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' >&8
  exec 8>&-
  wait "$pid"
  rc="$(cat "$BATS_TEST_TMPDIR/running.rc")"
  [ "$rc" = 11 ] || { echo "running companion exited $rc: $(cat "$BATS_TEST_TMPDIR/running.out")"; return 1; }
  grep -F '"permissionDecision":"deny"' "$BATS_TEST_TMPDIR/running.out"
  [ "$(stat -f '%i' "$old")" = "$old_inode" ]
  [ "$(shasum -a 256 "$old" | awk '{print $1}')" = "$old_hash" ]
  [ "$(stat -f '%Lp' "$old")" = 500 ]
  /usr/bin/codesign --verify --strict "$old"
  run "$old" contract
  [ "$status" -eq 0 ]
  new="$(find "$BATS_TEST_TMPDIR/trellis/bin/native/1.5.1" -type f -name trellis-hooks)"
  [ -n "$new" ] && [ "$new" != "$old" ]
  [ "$(stat -f '%i' "$new")" != "$old_inode" ]
}
# END C1 Darwin arm64 T35

# BEGIN C2 Linux x86_64 T37
@test "native delivery Linux: x86_64 musl static asset" {
  [ "$(uname -s)" = Linux ] || skip "UNVERIFIED-on-Mac: Linux musl qualification"
  [ "$(uname -m)" = x86_64 ] || skip "x86_64 only"
  [ -f "$ASSETS/x86_64-unknown-linux-musl/trellis-hooks" ]
  run bash "$BUILD" verify "$ASSETS"
  [ "$status" -eq 0 ]
  run file "$ASSETS/x86_64-unknown-linux-musl/trellis-hooks"
  [[ "$output" == *"static"* ]] || false
}

# T37: the static-musl assumption, from the ELF itself: no program
# interpreter and no shared-library dependency, so nothing on the host's
# loader path can change what runs.
@test "native delivery Linux: the musl asset has no interpreter and no shared-library dependency" {
  [ "$(uname -s):$(uname -m)" = Linux:x86_64 ] || skip "UNVERIFIED-on-Mac: Linux musl qualification"
  local asset="$ASSETS/x86_64-unknown-linux-musl/trellis-hooks"
  run readelf -lW "$asset"
  [ "$status" -eq 0 ]
  [[ "$output" != *INTERP* ]] || { echo "$output"; return 1; }
  run readelf -dW "$asset"
  [ "$status" -eq 0 ]
  [[ "$output" != *"(NEEDED)"* ]] || { echo "$output"; return 1; }
  run ldd "$asset"
  [[ "$output" == *"not a dynamic executable"* || "$output" == *"statically linked"* ]] || { echo "$output"; return 1; }
  run env -i PATH=/usr/bin:/bin LD_PRELOAD=/nonexistent/preload.so "$asset" contract
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# T37 (apex ruling E11): the sealed adapter's passthrough under dash, the
# shell Linux renders select when /bin/dash exists. Each companion status maps
# exactly; anything else refuses for both harnesses.
@test "native delivery Linux: the sealed adapter passes every decision through under dash (E11)" {
  [ "$(uname -s)" = Linux ] || skip "UNVERIFIED-on-Mac: Linux dash passthrough"
  local dash adapter stub code harness doc
  dash="$(command -v dash || true)"
  [ -n "$dash" ] || { echo "dash is not installed on this Linux host; E11 cannot be verified"; return 1; }
  adapter="$(grep -v '^[[:space:]]*#' "$ASSETS/hook-adapter.sh")"
  for code in 10 11 12 1 127; do
    stub="$BATS_TEST_TMPDIR/stub-$code"
    printf '#!/bin/sh\ncat >/dev/null\nprintf %%s %s\nexit %s\n' "'{\"decision\":\"block\",\"reason\":\"stub $code\"}'" "$code" > "$stub"
    chmod 755 "$stub"
    for harness in claude codex; do
      run bash -c 'printf %s "{}" | HOME="$1" "$2" -c "$3" trellis-hooks "$4" "$5" PreToolUse /nonexistent' _ "$BATS_TEST_TMPDIR" "$dash" "$adapter" "$stub" "$harness"
      case "$code" in
        10) [ "$status" -eq 0 ] && [ -z "$output" ] ;;
        11) [ "$status" -eq 0 ] && [[ "$output" == *'"reason":"stub 11"'* ]] ;;
        12) [ "$status" -eq 2 ] && [[ "$output" == *'"reason":"stub 12"'* ]] ;;
        *) [[ "$output" == *"native entry failed (status $code); refusing"* ]] &&
           if [ "$harness" = claude ]; then [ "$status" -eq 0 ] && [[ "$output" == *'"permissionDecision":"deny"'* ]];
           else [ "$status" -eq 2 ]; fi ;;
      esac || { echo "$harness status $code -> $status: $output"; return 1; }
    done
  done
}
# END C2 Linux x86_64 T37

# BEGIN C3 Intel Darwin and Linux aarch64 T36 T38
# Intel Darwin intentionally has no native asset (D3).
# aarch64 musl remains UNVERIFIED-on-Mac; T38 owns native-vs-legacy evidence.
#
# T36 legacy host: on a host whose target the release ships no asset for, the
# install, configure, adopt and rollback paths keep the complete legacy route:
# no companion, no native pin, the pinned legacy hook surface labelled as the
# fallback, never a native attempt or a missing-asset deny. On x86_64 macOS this
# runs as is; elsewhere B1_DROP_HOST_TARGET removes this host's asset first.
legacy_host_assert_no_native() {
  local launcher="$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  grep -Fx "launcher_native_entry=''" "$launcher" || { grep -F launcher_native_ "$launcher"; return 1; }
  grep -Fx "launcher_native_version=''" "$launcher"
  [ -z "$(find "$BATS_TEST_TMPDIR/trellis/bin" -type f -name trellis-hooks 2>/dev/null)" ] ||
    { echo "a companion was installed on a legacy host"; return 1; }
}

@test "native delivery legacy host: configure installs no companion and pins no native entry" {
  [ "$(uname -s)" = Darwin ] || [ "$(uname -s)" = Linux ] || skip 'unsupported host'
  B1_DROP_HOST_TARGET=1 b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  legacy_host_assert_no_native
  [[ "$output" != *"native"*"refus"* ]] || { echo "$output"; return 1; }
}

@test "native delivery legacy host: upgrade, adoption failure and rollback stay on the legacy route" {
  [ "$(uname -s)" = Darwin ] || [ "$(uname -s)" = Linux ] || skip 'unsupported host'
  local n_repo n_payload
  B1_DROP_HOST_TARGET=1 b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  n_repo="$B1_REPO" n_payload="$B1_PAYLOAD"
  B1_DROP_HOST_TARGET=1 b1_install_candidate_release '' 1.5.1
  # An adoption that fails leaves the legacy pair; a successful one keeps it legacy.
  for adopt in 42 0; do
    run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" \
      TRELLIS_VERIFIED_PAYLOAD="$B1_PAYLOAD" TRELLIS_VERIFIED_RELEASE_VERSION=1.5.1 PAIR_ADOPT_EXIT="$adopt" \
      /bin/bash -c '
        root="$1"; shift
        . "$root/scripts/lib/trellis-home.sh"
        . "$root/scripts/lib/release-store.sh"
        TRELLIS_VERIFIED_COMMAND_BUNDLE=upgrade
        TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN=test-token
        trellis_command_bundle_is_verified() { [ "$1:$2" = upgrade:test-token ]; }
        release_command_main() { [ "$1" != adopt ] || return "$PAIR_ADOPT_EXIT"; }
        eval "$(awk '\''body { print } /^# -- trellis upgrade body --$/ { body=1 }'\'' "$root/scripts/upgrade.sh")"
      ' _ "$ROOT" 1.5.1 --all
    [ "$status" -eq "$adopt" ] || { echo "adopt=$adopt: $output"; return 1; }
    legacy_host_assert_no_native
  done
  grep -Fx "launcher_native_version=''" "$BATS_TEST_TMPDIR/user/.local/bin/trellis"
  B1_REPO="$n_repo" B1_PAYLOAD="$n_payload" B1_VERSION=1.5.0
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  legacy_host_assert_no_native
}

@test "native delivery legacy host: attach renders the complete pinned legacy surface, labelled, for all three templates" {
  [ "$(uname -s)" = Darwin ] || [ "$(uname -s)" = Linux ] || skip 'unsupported host'
  B1_DROP_HOST_TARGET=1 b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local project="$BATS_TEST_TMPDIR/projects/legacy-host" template root fallback reference payload="$BATS_TEST_TMPDIR/legacy-payload"
  mkdir -p "$project" "$payload/core-rules"
  project="$(cd "$project" && pwd -P)"
  # The production templates and pinned legacy surface beside this release's
  # host-less native manifest.
  cp -R "$ROOT/core-rules/templates" "$ROOT/core-rules/legacy-hooks" "$payload/core-rules/"
  cp -R "$B1_PAYLOAD/core-rules/native" "$payload/core-rules/native"
  chmod -R u+w "$payload"
  ! jq -e --arg t "$(case "$(uname -s):$(uname -m)" in Darwin:arm64) echo aarch64-apple-darwin ;; Linux:x86_64) echo x86_64-unknown-linux-musl ;; Linux:aarch64) echo aarch64-unknown-linux-musl ;; *) echo none ;; esac)" \
    '.assets | has($t)' "$payload/core-rules/native/artifacts.json" >/dev/null || { echo "the release lists this host"; return 1; }
  for template in claude-settings.local.json codex-hooks.local.json claude-user-settings.json; do
    root="$project"; [ "$template" != claude-user-settings.json ] || root=''
    fallback="$BATS_TEST_TMPDIR/$template.fallback" reference="$BATS_TEST_TMPDIR/$template.reference"
    run env HOME="$BATS_TEST_TMPDIR/user" TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis" bash -c '
      . "$1/scripts/lib/attachment.sh"
      attachment_claude_on_failure_supported() { return 0; }
      context="$(attachment_contextual_render_context "$TRELLIS_HOME")" || exit 91
      attachment_contextual_template_select "$2/core-rules/templates/$3" "core-rules/templates/$3" "$context" "$4" > "$5" 2> "$5.err" || exit 92
      attachment_contextual_template_render_impl "$2/core-rules/legacy-hooks/$3" "core-rules/templates/$3" "$context" "$4" > "$6"
    ' _ "$ROOT" "$payload" "$template" "$root" "$fallback" "$reference"
    [ "$status" -eq 0 ] || { echo "$template: $output $(cat "$fallback.err" 2>/dev/null)"; return 1; }
    jq -e --slurpfile ref "$reference" '.hooks == $ref[0].hooks' "$fallback" >/dev/null || { echo "$template: not the pinned legacy hooks"; return 1; }
    grep -F 'legacy fallback: native selection miss 10' "$fallback.err" || { echo "$template: unlabelled fallback"; return 1; }
    ! grep -Eq '/bin/native/|__TRELLIS_LAUNCHER__|event-client' "$fallback" || { echo "$template: a native registration leaked"; return 1; }
  done
}
# END C3 Intel Darwin and Linux aarch64 T36 T38

# BEGIN C1 Darwin fallback filesystem T39
# T39: every shipped shell source parses under the stable /bin/bash 3.2, and
# none uses a Bash-4 runtime feature 3.2 would only reject when it runs.
@test "native delivery Darwin: every shipped shell source is Bash 3.2 compatible" {
  [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' || skip 'no Bash 3.2 at /bin/bash'
  local list="$BATS_TEST_TMPDIR/shell-sources" f bad=0
  { find "$ROOT/core-rules" "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.bash' \) \
      -not -path '*/tests/*' -not -path '*/node_modules/*' -not -path '*/evals/*'
    printf '%s\n' "$ROOT/scripts/trellis"; } | LC_ALL=C sort -u > "$list"
  [ "$(wc -l < "$list")" -gt 150 ] || { echo "too few shell sources: $(wc -l < "$list")"; return 1; }
  while IFS= read -r f; do
    /bin/bash -n "$f" 2>"$BATS_TEST_TMPDIR/parse.err" || { echo "3.2 parse: $f: $(cat "$BATS_TEST_TMPDIR/parse.err")"; bad=1; }
  done < "$list"
  run python3 -I - "$list" <<'PY'
import re, sys
features = [
    (r'(^|[;&|({]|\bthen|\bdo|\belse)\s*(mapfile|readarray)\b', 'mapfile/readarray'),
    (r'\b(declare|local|typeset)\s+-[a-zA-Z]*[An][a-zA-Z]*\s', 'associative array or nameref'),
    (r'\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}', 'case-modifying expansion'),
    (r'\[\[\s+-v\s', '[[ -v ]]'),
    (r'shopt\s+-s\s+(globstar|lastpipe)\b', 'shopt globstar/lastpipe'),
    (r'\$\{?EPOCH(SECONDS|REALTIME)\b', 'EPOCHSECONDS/EPOCHREALTIME'),
    (r'\bwait\s+-n\b', 'wait -n'),
]
hits = []
for path in open(sys.argv[1]).read().split('\n'):
    if not path:
        continue
    for number, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
        # A feature behind a same-line version check (with its 3.2 fallback
        # beside it, as _gr_now reads EPOCHSECONDS only on Bash 5) is allowed.
        if line.lstrip().startswith('#') or 'BASH_VERSINFO' in line:
            continue
        for pattern, name in features:
            if re.search(pattern, line):
                hits.append('%s:%d: %s' % (path, number, name))
print('\n'.join(hits))
sys.exit(1 if hits else 0)
PY
  [ "$status" -eq 0 ] || { echo "$output"; bad=1; }
  [ "$bad" -eq 0 ]
}

# T39: a native pair installed and configured on a real non-APFS volume. HFS+
# ctime is whole seconds (proven), so no release stamp may ever be written:
# every verification is the full one, and the companion still selects.
@test "native delivery Darwin: on a real HFS+ volume the native pair installs and selects without any release stamp" {
  b1_native_host
  hfs_volume_attach
  hfs_volume_coarse_ctime
  local original="$BATS_TEST_TMPDIR" companion
  BATS_TEST_TMPDIR="$HFS_MNT/t"
  mkdir -p "$BATS_TEST_TMPDIR"
  b1_install_candidate_release
  b1_configure_pair
  [ "$status" -eq 0 ] || { BATS_TEST_TMPDIR="$original"; echo "$output"; return 1; }
  companion="$(sed -n "s/^launcher_native_entry='\(.*\)'$/\1/p" "$BATS_TEST_TMPDIR/user/.local/bin/trellis")"
  case "$companion" in "$HFS_MNT"/*) ;; *) BATS_TEST_TMPDIR="$original"; echo "companion not on the HFS+ volume: $companion"; return 1 ;; esac
  run "$companion" contract
  [ "$status" -eq 0 ] || { BATS_TEST_TMPDIR="$original"; echo "$output"; return 1; }
  b1_verify_signature "$companion"
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/trellis/state/release-stamps" 2>/dev/null)" ] ||
    { ls -la "$BATS_TEST_TMPDIR/trellis/state/release-stamps"; BATS_TEST_TMPDIR="$original"; return 1; }
  find "$BATS_TEST_TMPDIR/trellis/releases" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
  BATS_TEST_TMPDIR="$original"
}
# END C1 Darwin fallback filesystem T39
