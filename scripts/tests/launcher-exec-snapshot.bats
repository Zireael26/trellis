#!/usr/bin/env bats
# Spec 072 T4: the launcher's persistent execution snapshot and its stamps, and
# the metadata-only routes. A run executes releases/.exec/<version>-<digest>
# only after a stamp hit or a full verify; every miss falls back to the full
# verify, and that verify's verdict decides.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LAUNCHER_TEMPLATE="$REPO_ROOT/scripts/trellis-launcher.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/launcher-exec.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  LAUNCHER="$SANDBOX/bin/trellis"
  RELEASES="$TRELLIS_HOME/releases"
  EXEC_STORE="$RELEASES/.exec"
  MARKER="$SANDBOX/tampered-ran"
  mkdir -p "$HOME" "$RELEASES" "$SANDBOX/projects" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  cp "$LAUNCHER_TEMPLATE" "$LAUNCHER"
  chmod 755 "$LAUNCHER"
  jq -n --arg projects "$SANDBOX/projects" '{
    schema_version: 1, source_root: "/nonexistent", release_remote: "fixture://release",
    active_cli_release: "1.2.3", default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$projects]}}
  }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  find "$SANDBOX" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$SANDBOX"
}

write_config() {
  jq -n --arg projects "$SANDBOX/projects" --arg release "$1" '{
    schema_version: 1, source_root: "/nonexistent", release_remote: "fixture://release",
    active_cli_release: $release, default_fleet: "personal",
    fleets: {personal: {discovery_roots: [$projects]}}
  }' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

# Release VERSION (default 1.2.3) whose CLI reports the path it ran from and
# exits 3, plus EXTRA filler files so a snapshot build takes long enough to race
# or kill. A current release declares the exec-snapshot capability in
# scripts/lib/trellis-home.sh. An old one (KIND=old) does not, and its CLI first
# applies the payload gate releases up to 1.3.21 carry (show-config.sh,
# sync-to-template.sh), verbatim, which refuses the persistent .exec form.
make_release() {
  local extra="${1:-0}" version="${2:-1.2.3}" kind="${3:-current}" payload i
  payload="$RELEASES/$version/payload"
  mkdir -p "$payload/scripts/lib"
  if [ "$kind" = heavy ]; then
    cp "$REPO_ROOT/scripts/trellis" "$REPO_ROOT/scripts/heavy.sh" "$payload/scripts/"
    cp "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" "$payload/scripts/lib/"
    chmod 755 "$payload/scripts/heavy.sh"
    printf '# trellis-payload-capability: exec-snapshot\n' > "$payload/scripts/lib/trellis-home.sh"
  elif [ "$kind" = old ]; then
    cat > "$payload/scripts/trellis" <<'EOF'
#!/bin/bash
old_gate() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}
old_gate "$TRELLIS_HOME" "$TRELLIS_VERIFIED_PAYLOAD" "$TRELLIS_VERIFIED_RELEASE_VERSION" || {
  printf '%s\n' 'old gate: direct source execution is unsupported' >&2
  exit 2
}
printf 'ran %s from %s\n' "$*" "$0"
exit 3
EOF
    printf '# a release before the persistent snapshot\n' > "$payload/scripts/lib/trellis-home.sh"
  else
    cat > "$payload/scripts/trellis" <<'EOF'
#!/bin/bash
printf 'ran %s from %s\n' "$*" "$0"
exit 3
EOF
    printf '# trellis-payload-capability: exec-snapshot\n' > "$payload/scripts/lib/trellis-home.sh"
  fi
  chmod 755 "$payload/scripts/trellis"
  printf 'immutable fixture\n' > "$payload/README"
  ln -s README "$payload/linked"
  for i in $(seq 1 "$extra"); do
    printf 'filler %s\n' "$i" > "$payload/filler-$i"
  done
  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$SANDBOX/manifest.jsonl"
  jq -n --slurpfile tree "$SANDBOX/manifest.jsonl" --arg version "$version" '{
    schema_version: 1, version: $version, tag: ("v" + $version),
    commit: "0000000000000000000000000000000000000000", remote: "fixture://release", tree: $tree
  }' > "$RELEASES/$version/release.json"
  find "$payload" -type f -exec chmod a-w {} +
  find "$payload" -type d -exec chmod a-w {} +
  chmod a-w "$RELEASES/$version/release.json" "$RELEASES/$version"
  DIGEST="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$RELEASES/$version/release.json")"
  SNAPSHOT="$EXEC_STORE/$version-$DIGEST"
  RAN="ran doctor from $SNAPSHOT/payload/scripts/trellis"
}

run_launcher() {
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" "$@"
}

load helpers/native-launcher

run_native_launcher() {
  local binary
  binary="$(native_launcher_binary)" || return $?
  run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$binary" launcher run-v1 -- "$@"
}

native_reseal_cli() {
  local replacement="$1" payload="$RELEASES/1.2.3/payload"
  chmod u+w "$payload/scripts/trellis"
  cp "$replacement" "$payload/scripts/trellis"
  chmod 555 "$payload/scripts/trellis"
  python3 -I "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$SANDBOX/manifest.jsonl"
  chmod u+w "$RELEASES/1.2.3/release.json"
  jq --slurpfile tree "$SANDBOX/manifest.jsonl" '.tree = $tree' \
    "$RELEASES/1.2.3/release.json" > "$SANDBOX/new-record"
  cp "$SANDBOX/new-record" "$RELEASES/1.2.3/release.json"
  chmod 444 "$RELEASES/1.2.3/release.json"
  DIGEST="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$RELEASES/1.2.3/release.json")"
  SNAPSHOT="$EXEC_STORE/1.2.3-$DIGEST"
}

inode_of() {
  python3 -I -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' "$1"
}

# Exactly one finished snapshot (beside its repair lock file, if a repair ran),
# and no work directory, owner sidecar, verify scratch or per-run snapshot
# anywhere in the store.
assert_one_snapshot_no_work() {
  local entries
  entries="$({ find "$RELEASES" -mindepth 1 -maxdepth 1 -name '.*' -print; find "$EXEC_STORE" -mindepth 1 -maxdepth 1 ! -name ".lock.${SNAPSHOT##*/}" -print; } 2>&1 | LC_ALL=C sort)"
  [ "$entries" = "$(printf '%s\n%s' "$EXEC_STORE" "$SNAPSHOT")" ] || { echo "store holds: $entries"; false; }
}

# The launcher's embedded snapshot driver, run directly.
exec_driver() {
  local driver stamp
  driver="$(awk '/^launcher_exec_snapshot_python\(\) \{$/ { getline; inside = 1; next }
    inside && /^TRELLIS_EXEC_SNAPSHOT_PY$/ { exit } inside { print }' "$LAUNCHER_TEMPLATE")"
  stamp="$(cat "$REPO_ROOT/scripts/lib/release_stamp.py")"
  python3 -I -c "$driver" "$stamp" "$@"
}

# Rewrite a sealed snapshot file and put its mtime back; only ctime moves.
tamper() {
  local file="$1" dir="${1%/*}"
  cp -p "$file" "$SANDBOX/original"
  chmod u+w "$dir" "$file"
  printf '#!/bin/bash\ntouch %q\nexit 0\n' "$MARKER" > "$file"
  touch -r "$SANDBOX/original" "$file"
  chmod a-w "$file" "$dir"
}

@test "T60 executable heavy uses a verified snapshot and refuses installed supervisor tamper" {
  make_release 0 1.2.3 heavy
  pin_native_launcher
  for attempt in cold warm; do
    run native_bounded "$LAUNCHER" heavy --lane fixture -- true
    [ "$status" -eq 0 ] || { echo "$attempt: $status: $output"; false; }
    [ -d "$SNAPSHOT" ]
    [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
  done
  tamper "$RELEASES/1.2.3/payload/scripts/lib/heavy-supervisor.pl"
  run native_bounded "$LAUNCHER" heavy --lane fixture -- /usr/bin/touch "$MARKER"
  [ "$status" -eq 4 ] || { echo "$status: $output"; false; }
  [ ! -e "$MARKER" ]
}

@test "native fusion runs cold and warm snapshots and removes its command scratch" {
  make_release
  run_native_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$status: $output"; false; }
  assert_one_snapshot_no_work
  run_native_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$status: $output"; false; }
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "native fusion preserves stdin and non-UTF8 argv without inheriting shell or Git injection" {
  make_release
  cat > "$SANDBOX/raw-cli" <<'EOF'
#!/bin/bash
IFS= read -r line
printf 'stdin=%s argc=%s raw=' "$line" "$#"
printf '%s' "$2" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n'
printf '\n'
[ -z "${BASH_ENV-}${ENV-}${GIT_CONFIG_COUNT-}${GIT_CONFIG_KEY_0-}${GIT_CONFIG_VALUE_0-}" ] || exit 91
[ -d "$TMPDIR" ] && [ "$TMPDIR" != /tmp ] || exit 92
exit 3
EOF
  native_reseal_cli "$SANDBOX/raw-cli"
  local binary
  binary="$(native_launcher_binary)"
  printf 'original input\n' > "$SANDBOX/input"
  # Exercise both first-run delegation and the native warm path.
  for attempt in 1 2; do
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" BASH_ENV=/nonexistent ENV=/nonexistent \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.bad GIT_CONFIG_VALUE_0='!exit 99' \
      "$binary" launcher run-v1 -- doctor $'\377' < "$SANDBOX/input"
    [ "$status" -eq 3 ] && [ "$output" = 'stdin=original input argc=2 raw=ff' ] || { echo "$status: $output"; false; }
  done
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "native fusion refuses an installed old-mtime tamper before any payload runs" {
  make_release
  run_native_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  tamper "$RELEASES/1.2.3/payload/scripts/trellis"
  run_native_launcher doctor
  [ "$status" -eq 4 ] || { echo "$status: $output"; false; }
  [ ! -e "$MARKER" ]
}

@test "native fusion repairs a tampered snapshot before executing it" {
  make_release
  run_native_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  tamper "$SNAPSHOT/payload/scripts/trellis"
  run_native_launcher doctor
  local expected="trellis: release execution snapshot failed verification and is rebuilt: $SNAPSHOT"
  expected="$expected"$'\n'"$RAN"
  [ "$status" -eq 3 ] && [ "$output" = "$expected" ] || { echo "$status: $output"; false; }
  [ ! -e "$MARKER" ]
  assert_one_snapshot_no_work
}

@test "native fusion scratch replacement refuses without deleting the replacement" {
  make_release
  cat > "$SANDBOX/scratch-cli" <<'EOF'
#!/bin/bash
if [ -f "$TRELLIS_HOME/corrupt-scratch" ]; then
  mv "$TMPDIR" "$TMPDIR.moved"
  mkdir "$TMPDIR"
  printf 'preserve\n' > "$TMPDIR/foreign"
fi
exit 3
EOF
  native_reseal_cli "$SANDBOX/scratch-cli"
  run_native_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  touch "$TRELLIS_HOME/corrupt-scratch"
  run_native_launcher doctor
  [ "$status" -eq 4 ] || { echo "$status: $output"; false; }
  [ "$(find "$TRELLIS_HOME/state/scratch" -name foreign -type f | wc -l | tr -d ' ')" -eq 1 ]
}

@test "native fusion postflight refuses success and preserves a greater child status" {
  make_release
  cat > "$SANDBOX/postflight-cli" <<'EOF'
#!/bin/bash
if [ -f "$TRELLIS_HOME/change-snapshot" ]; then
  chmod u+w "$0"
  exit "$(cat "$TRELLIS_HOME/child-status")"
fi
exit 3
EOF
  native_reseal_cli "$SANDBOX/postflight-cli"
  for child_status in 0 7; do
    rm -f "${TRELLIS_HOME:?}/change-snapshot"
    run_native_launcher doctor
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    printf '%s\n' "$child_status" > "$TRELLIS_HOME/child-status"
    touch "$TRELLIS_HOME/change-snapshot"
    run_native_launcher doctor
    local expected=4
    [ "$child_status" -le 4 ] || expected="$child_status"
    [ "$status" -eq "$expected" ] || { echo "$status: $output"; false; }
    [[ "$output" == *'identity changed'* ]] || { echo "$output"; false; }
    [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
  done
}

@test "paired payload retains SIGPIPE on cold warm and canonical fallback paths" {
  make_release
  cat > "$SANDBOX/sigpipe-cli" <<'EOF'
#!/bin/bash
/usr/bin/yes | /usr/bin/head -1 >/dev/null
producer=${PIPESTATUS[0]}
printf 'producer=%s\n' "$producer"
[ "$producer" -eq 141 ] || exit 92
# With ignored SIGPIPE this producer spins forever on EPIPE. The status
# assertion above fails first so a regression cannot emit unbounded noise.
while :; do echo x; done | /usr/bin/head -1 >/dev/null
[ "${PIPESTATUS[0]}" -eq 141 ] || exit 93
exit 3
EOF
  native_reseal_cli "$SANDBOX/sigpipe-cli"
  pin_native_launcher
  for path in cold warm fallback; do
    if [ "$path" = fallback ]; then
      python3 -I - "$TRELLIS_HOME/config.json" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_bytes(b'\xef\xbb\xbf'+p.read_bytes())
PY
    fi
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor
    [ "$status" -eq 3 ] && [ "$output" = 'producer=141' ] || { echo "$path: $status: $output"; false; }
    [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
  done
}

@test "native fusion rechecks installed release after child even with broken stderr" {
  make_release
  cat > "$SANDBOX/installed-postflight-cli" <<'EOF'
#!/bin/bash
if [ -f "$TRELLIS_HOME/change-installed" ]; then
  chmod u+w "$TRELLIS_HOME/releases/1.2.3/payload/README"
  exit "$(cat "$TRELLIS_HOME/child-status")"
fi
exit 3
EOF
  native_reseal_cli "$SANDBOX/installed-postflight-cli"
  local binary child_status expected
  binary="$(native_launcher_binary)"
  for child_status in 0 7; do
    rm -f "$TRELLIS_HOME/change-installed"
    chmod a-w "$RELEASES/1.2.3/payload/README"
    run_native_launcher doctor
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    printf '%s\n' "$child_status" > "$TRELLIS_HOME/child-status"
    touch "$TRELLIS_HOME/change-installed"
    run python3 -I - "$binary" <<'PY'
import os,subprocess,sys
r,w=os.pipe();os.close(r)
try:
    p=subprocess.run([sys.argv[1],'launcher','run-v1','--','doctor'],stderr=w,stdout=subprocess.PIPE,timeout=45)
finally:
    os.close(w)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode if p.returncode>=0 else 128-p.returncode)
PY
    expected=4
    [ "$child_status" -le 4 ] || expected="$child_status"
    [ "$status" -eq "$expected" ] || { echo "post-child closed stderr: $status: $output"; false; }
    [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
  done
}

@test "paired launcher delegates executable routes before legacy jq validation" {
  make_release
  pin_native_launcher
  python3 -I - "$LAUNCHER" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);text=p.read_text();old='launcher_validate_machine_config() {'
assert text.count(old)==1
p.write_text(text.replace(old,old+'\n  return 91 # fixture: legacy config route must not run'))
PY
  for attempt in 1 2; do
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor
    [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$status: $output"; false; }
  done
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "paired launcher selects its physical-home pin and ignores planted companions" {
  make_release
  pin_native_launcher
  mkdir -p "$SANDBOX/planted"
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$MARKER" > "$SANDBOX/planted/trellis-hooks"
  chmod 755 "$SANDBOX/planted/trellis-hooks"
  cp "$SANDBOX/planted/trellis-hooks" "$SANDBOX/projects/trellis-hooks"
  ln -s "$SANDBOX" "$SANDBOX/parent-alias"
  cd "$SANDBOX/projects"
  for attempt in 1 2; do
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$SANDBOX/parent-alias/trellis-home" \
      PATH="$SANDBOX/planted:$PATH" "$LAUNCHER" doctor
    [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$status: $output"; false; }
  done
  [ ! -e "$MARKER" ]
}

@test "paired launcher refuses a missing pin without discovering a replacement" {
  make_release
  pin_native_launcher
  local entry
  entry="$(find "$TRELLIS_HOME/bin/native" -type f -name trellis-hooks)"
  chmod u+w "${entry%/*}"
  rm -f "${entry:?}"
  mkdir -p "$SANDBOX/planted"
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$MARKER" > "$SANDBOX/planted/trellis-hooks"
  chmod 755 "$SANDBOX/planted/trellis-hooks"
  run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH="$SANDBOX/planted:$PATH" "$LAUNCHER" doctor
  [ "$status" -eq 4 ] && [[ "$output" == *'installed launcher companion is unavailable:'* ]] || { echo "$status: $output"; false; }
  [[ "$output" != *'ran doctor'* ]] && [ ! -e "$MARKER" ]
}

@test "paired native launcher rejects malformed and unknown-key config without invoking the payload" {
  make_release
  pin_native_launcher
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/good-config"
  # These optional fields are intentionally untyped in canonical validation.
  # Do not tighten them accidentally via serde_json's number/depth limits.
  python3 -I - "$SANDBOX/good-config" "$SANDBOX" <<'PY'
import json,pathlib,sys
base=json.loads(pathlib.Path(sys.argv[1]).read_text());root=pathlib.Path(sys.argv[2])
for field in ['projects','heavy_slots','heavy_light_slots']:
    for name,value in [('huge','1e1000'),('deep','['*160+'null'+']'*160)]:
        data=dict(base);data[field]='UNREPRESENTABLE_TEST'
        text=json.dumps(data).replace('"UNREPRESENTABLE_TEST"',value)
        (root/('untyped-'+field+'-'+name+'.json')).write_text(text)
for name,value in [('schema-valid-float','1.0'),('schema-valid-exponent','1e0'),('schema-near-high','1.0000000000000000001'),('schema-near-low','0.99999999999999999999')]:
    data=dict(base);data['schema_version']='EXACT_SCHEMA_NUMBER'
    text=json.dumps(data).replace('"EXACT_SCHEMA_NUMBER"',value)
    (root/(name+'.json')).write_text(text)
PY
  cp "$LAUNCHER_TEMPLATE" "$SANDBOX/legacy-launcher"
  chmod 755 "$SANDBOX/legacy-launcher"
  for candidate in "$SANDBOX"/untyped-*.json "$SANDBOX"/schema-valid-*.json; do
    cp "$candidate" "$TRELLIS_HOME/config.json"
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$SANDBOX/legacy-launcher" doctor
    [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "legacy $candidate: $status: $output"; false; }
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor
    [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "native $candidate: $status: $output"; false; }
  done
  for kind in malformed unknown-key high-surrogate schema-near-high schema-near-low; do
    if [ "$kind" = malformed ]; then
      printf '{malformed' > "$TRELLIS_HOME/config.json"
    elif [ "$kind" = unknown-key ]; then
      jq '. + {unknown_key: true}' "$SANDBOX/good-config" > "$TRELLIS_HOME/config.json"
    elif [ "$kind" = schema-near-high ] || [ "$kind" = schema-near-low ]; then
      cp "$SANDBOX/$kind.json" "$TRELLIS_HOME/config.json"
    else
      python3 -I - "$SANDBOX/good-config" "$TRELLIS_HOME/config.json" <<'PY'
import json,pathlib,sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text());data['projects']=chr(0xd800)
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
    fi
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$SANDBOX/legacy-launcher" doctor
    [ "$status" -eq 4 ] || { echo "legacy $kind: $status: $output"; false; }
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor
    [ "$status" -eq 4 ] && [[ "$output" == *'machine config failed validation'* ]] || { echo "$status: $output"; false; }
    [[ "$output" != *'ran doctor'* ]]
    [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
  done
}

# Both launchers read the same original bytes, never a JSON round-trip.
assert_canonical_config_parity() {
  local label="$1" expected
  run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$SANDBOX/canonical-launcher" doctor
  expected="$status"
  [ "$expected" -eq 3 ] || [ "$expected" -eq 4 ] || { echo "canonical $label: $status: $output"; false; }
  run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor
  [ "$status" -eq "$expected" ] || { echo "$label: canonical=$expected native=$status: $output"; false; }
  if [ "$expected" -eq 3 ]; then
    [ "$output" = "$RAN" ] || { echo "$label: $output"; false; }
  else
    [[ "$output" != *'ran doctor'* ]] || { echo "$label executed payload: $output"; false; }
  fi
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

prepare_config_parity() {
  make_release
  pin_native_launcher
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/parity-base.json"
  cp "$LAUNCHER_TEMPLATE" "$SANDBOX/canonical-launcher"
  chmod 755 "$SANDBOX/canonical-launcher"
}

@test "paired config depth boundaries defer arrays objects and earlier duplicate values to canonical" {
  prepare_config_parity
  python3 -I - "$SANDBOX" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);base=json.loads((root/'parity-base.json').read_bytes())
for field in ['projects','heavy_slots','heavy_light_slots']:
    for kind in ['array','object']:
        for depth in [127,128,254,255]:
            value=('['*depth+'null'+']'*depth if kind=='array' else '{"x":'*depth+'null'+'}'*depth)
            data=dict(base);data[field]='DEPTH_VALUE'
            text=json.dumps(data).replace('"DEPTH_VALUE"',value)
            (root/(f'depth-{field}-{kind}-{depth}.json')).write_text(text)
            duplicate=text[:-1]+',"'+field+'":null}'
            (root/(f'depth-{field}-{kind}-{depth}-duplicate.json')).write_text(duplicate)
PY
  for candidate in "$SANDBOX"/depth-*.json; do
    cp "$candidate" "$TRELLIS_HOME/config.json"
    assert_canonical_config_parity "${candidate##*/}"
  done
}

@test "paired config uncertainty delegates original lenient syntax encoding and duplicates to canonical" {
  prepare_config_parity
  python3 -I - "$SANDBOX" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);base=json.loads((root/'parity-base.json').read_bytes())
for field in ['projects','heavy_slots','heavy_light_slots']:
    for name,value in [('NaN','NaN'),('nan','nan'),('Infinity','Infinity'),('negativeInfinity','-Infinity'),('leadingzero','01'),('plus','+1'),('leadingdot','.5'),('trailingdot','1.'),('low',r'"\udc00"'),('highhigh',r'"\ud800\ud800"')]:
        data=dict(base);data[field]='ODD_VALUE'
        (root/(f'odd-{field}-{name}.json')).write_text(json.dumps(data).replace('"ODD_VALUE"',value))
raw=json.dumps(base).encode()
for name,value in [('bom',b'\xef\xbb\xbf'+raw),('nul',raw+b'\0'),('junk',raw+b'junk'),('typed-low',raw.replace(b'fixture://release',br'\udc00')),('typed-invalid-utf8',raw.replace(b'fixture://release',b'\xff')),('schema01',raw.replace(b'"schema_version": 1',b'"schema_version": 01')),('duplicate-schema',b'{"schema_version":1e1000,'+raw[1:]),('duplicate-fleets',b'{"fleets":'+b'['*200+b'null'+b']'*200+b','+raw[1:])]:
    (root/(f'odd-{name}.json')).write_bytes(value)
PY
  for candidate in "$SANDBOX"/odd-*.json; do
    cp "$candidate" "$TRELLIS_HOME/config.json"
    assert_canonical_config_parity "${candidate##*/}"
  done
}

@test "paired config group access and special mode bits never authorize warm execution" {
  prepare_config_parity
  for mode in 640 1600 2600 4600; do
    chmod "$mode" "$TRELLIS_HOME/config.json"
    local expected
    expected="$(python3 -I -c 'import os,sys;print(4 if os.stat(sys.argv[1]).st_mode & 0o7077 else 3)' "$TRELLIS_HOME/config.json")"
    # Some hosts strip setgid. Judge the bits actually set; synthetic identity
    # unit rows additionally cover all bits, independent of host capability.
    run_launcher doctor
    [ "$status" -eq "$expected" ] || { echo "mode-$mode: expected=$expected native=$status: $output"; false; }
    if [ "$expected" -eq 4 ]; then [[ "$output" != *'ran doctor'* ]]; fi
  done
}

@test "paired invalid config with broken stderr returns refusal rather than panic" {
  prepare_config_parity
  printf '{malformed' > "$TRELLIS_HOME/config.json"
  run python3 -I - "$LAUNCHER" <<'PY'
import os,subprocess,sys
r,w=os.pipe();os.close(r)
try:
    p=subprocess.run([sys.argv[1],'doctor'],stderr=w,stdout=subprocess.PIPE,timeout=45)
finally:
    os.close(w)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode if p.returncode>=0 else 128-p.returncode)
PY
  [ "$status" -eq 4 ] && [ -z "$output" ] || { echo "$status: $output"; false; }
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

# T60/T58 fd parity: payload children see exactly the caller's descriptors, as
# on the shell route, and none of native's proof or carrier descriptors.
@test "native fusion passes caller descriptors and closes proof descriptors in payload children" {
  make_release
  cat > "$SANDBOX/fd-probe.py" <<'EOF'
import os
extra=[]
for name in os.listdir("/dev/fd"):
    try:
        fd=int(name)
        os.fstat(fd)
    except (OSError,ValueError):
        continue
    if fd>2:
        extra.append(fd)
print("extra="+",".join(map(str,sorted(extra))))
EOF
  printf '#!/bin/bash\npython3 -I %q\nexit 3\n' "$SANDBOX/fd-probe.py" > "$SANDBOX/fd-cli"
  native_reseal_cli "$SANDBOX/fd-cli"
  exec 9< "$TRELLIS_HOME/config.json"
  run python3 -I "$SANDBOX/fd-probe.py"
  local expected="$output"
  [[ "$expected" == *9* ]] || { echo "caller baseline: $expected"; false; }
  for attempt in 1 2; do
    run_native_launcher doctor
    [ "$status" -eq 3 ] && [ "$output" = "$expected" ] || { echo "$attempt: $status: $output versus $expected"; false; }
  done
  exec 9<&-
}

@test "native fusion forwards HUP INT TERM and cleans scratch even with inherited ignored INT" {
  make_release
  cat > "$SANDBOX/signal-cli" <<'EOF'
#!/bin/bash
if [ -f "$TRELLIS_HOME/hold" ]; then
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'ready\n'
  while :; do /bin/sleep 0.05; done
fi
exit 3
EOF
  native_reseal_cli "$SANDBOX/signal-cli"
  run_native_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  touch "$TRELLIS_HOME/hold"
  local binary
  binary="$(native_launcher_binary)"
  run python3 -I -c '
import os,selectors,signal,subprocess,sys
for sig in [signal.SIGHUP,signal.SIGINT,signal.SIGTERM]:
    def ignored_int():
        signal.signal(signal.SIGINT,signal.SIG_IGN)
    child=subprocess.Popen([sys.argv[1],"launcher","run-v1","--","doctor"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,stdin=subprocess.DEVNULL,start_new_session=True,preexec_fn=ignored_int)
    try:
        ready=selectors.DefaultSelector();ready.register(child.stdout,selectors.EVENT_READ)
        assert ready.select(timeout=20),"no readiness acknowledgement"
        assert child.stdout.readline()==b"ready\n"
        ready.close()
        os.kill(child.pid,sig)
        out,err=child.communicate(timeout=10)
        assert child.returncode==128+sig,(sig,child.returncode,out,err)
        assert out==err==b"",(sig,out,err)
        print("signal="+str(sig)+" status="+str(child.returncode))
    finally:
        if child.poll() is None:
            os.killpg(child.pid,signal.SIGKILL)
            child.wait()
' "$binary"
  [ "$status" -eq 0 ] && [ "$output" = $'signal=1 status=129\nsignal=2 status=130\nsignal=15 status=143' ] || { echo "$status: $output"; false; }
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "native fusion rejects ACL-bearing private configuration before payload execution" {
  make_release
  pin_native_launcher
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  case "$(uname -s)" in
    Darwin) chmod +a "user:$(id -un) allow read" "$TRELLIS_HOME/config.json" ;;
    Linux)
      command -v setfacl >/dev/null || skip 'POSIX ACL tools unavailable'
      setfacl -m "u:$(id -u):r--,m::---" "$TRELLIS_HOME/config.json"
      ;;
    *) skip 'native ACL fixture unavailable' ;;
  esac
  run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor
  [ "$status" -eq 4 ] && [[ "$output" == *'ACL'* ]] || { echo "$status: $output"; false; }
  [[ "$output" != *'ran doctor'* ]]
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "paired launcher retains legacy verification for an installed T70 scaffold" {
  make_release
  # Known fixture trust-root bytes model the old native ABI (no run-v1), not
  # target payload code. Publish by the same fixed literal digest pin helper.
  printf '#!/bin/sh\nexit 5\n' > "$SANDBOX/old-scaffold"
  chmod 500 "$SANDBOX/old-scaffold"
  pin_native_launcher "$SANDBOX/old-scaffold"
  run_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$status: $output"; false; }
  tamper "$RELEASES/1.2.3/payload/scripts/trellis"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$status: $output"; false; }
  [ ! -e "$MARKER" ]
}

@test "native fusion derives private scratch independently of caller umask" {
  make_release
  local binary
  binary="$(native_launcher_binary)"
  run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" /bin/bash -c \
    'umask 0777; exec "$1" launcher run-v1 -- doctor' native-umask "$binary"
  [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$status: $output"; false; }
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "launcher refuses an ACL hidden by an xattr and permits an xattr alone" {
  [ "$(uname -s)" = Darwin ] || skip 'native Darwin ACL and xattr fixture'
  make_release
  file="$RELEASES/1.2.3/payload/README"
  chmod u+w "$file"
  xattr -w com.trellis.fixture data "$file" || skip 'extended attributes unavailable'
  chmod a-w "$file"
  chmod +a "user:$(id -un) allow write" "$file" || skip 'ACLs unavailable'
  [[ "$(ls -ld "$file")" == *'@ '* ]] || skip 'filesystem does not display the xattr marker'
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'ACL'* ]] || { echo "$output"; false; }
  chmod -N "$file"
  run_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$RAN" ] || { echo "$output"; false; }
}

@test "launcher rejects chained links escaping the configured payload" {
  make_release
  local payload="$RELEASES/1.2.3/payload"
  mkdir -p "$RELEASES/1.0.0/payload"
  printf 'outside release\n' > "$RELEASES/1.0.0/payload/x"
  chmod u+w "$RELEASES/1.2.3" "$payload"
  mkdir "$payload/d"
  ln -s .. "$payload/d/L2"
  ln -s 'd/L2/../../1.0.0/payload/x' "$payload/L1"
  python3 -I "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$SANDBOX/manifest.jsonl"
  chmod u+w "$RELEASES/1.2.3/release.json"
  jq -n --slurpfile tree "$SANDBOX/manifest.jsonl" '{
    schema_version: 1, version: "1.2.3", tag: "v1.2.3",
    commit: "0000000000000000000000000000000000000000", remote: "fixture://release", tree: $tree
  }' > "$RELEASES/1.2.3/release.json"
  find "$payload" -type f -exec chmod a-w {} +
  find "$payload" -type d -exec chmod a-w {} +
  chmod a-w "$RELEASES/1.2.3/release.json" "$RELEASES/1.2.3"
  [ "$(< "$payload/L1")" = 'outside release' ]
  run_launcher doctor
  [ "$status" -eq 4 ] && [[ "$output" == *'unsafe symlink: L1'* ]] || { echo "$output"; false; }

  # The same intermediate link is safe when it resolves inside the payload.
  chmod u+w "$RELEASES/1.2.3" "$payload" "$RELEASES/1.2.3/release.json"
  rm -f "${payload:?}/L1"
  ln -s 'd/L2/README' "$payload/L1"
  python3 -I "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$payload" > "$SANDBOX/manifest.jsonl"
  jq --slurpfile tree "$SANDBOX/manifest.jsonl" '.tree = $tree' \
    "$RELEASES/1.2.3/release.json" > "$SANDBOX/release.json"
  mv "$SANDBOX/release.json" "$RELEASES/1.2.3/release.json"
  chmod a-w "$payload" "$RELEASES/1.2.3/release.json" "$RELEASES/1.2.3"
  run_launcher doctor
  [ "$status" -eq 3 ] && [[ "$output" == 'ran doctor from '* ]] || { echo "$output"; false; }
}

@test "a warm run executes the persistent snapshot without re-verifying anything" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  assert_one_snapshot_no_work
  [ -f "$TRELLIS_HOME/state/release-stamps/1.2.3-$DIGEST.json" ]
  [ -f "$TRELLIS_HOME/state/exec-stamps/1.2.3-$DIGEST.json" ]

  # A full verify allocates scratch beside what it verifies; with both stores
  # read-only any re-verify, copy or rebuild fails. The warm run must not need one.
  chmod 500 "$RELEASES" "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
}

@test "a stamp miss falls back to the full verify, which then re-stamps" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # Same bytes, new ctime: the installed release stamp misses. The fallback
  # full verify needs scratch in the store, so it is refused while the store is
  # read-only: proof that the miss really took the full verify.
  chmod u+w "$RELEASES/1.2.3/payload/README"
  chmod a-w "$RELEASES/1.2.3/payload/README"
  chmod 500 "$RELEASES"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *'could not allocate release verification state'* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }

  chmod 700 "$RELEASES"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  chmod 500 "$RELEASES" "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "re-stamped run: $output"; false; }
  chmod 700 "$RELEASES" "$EXEC_STORE"

  # A missing snapshot stamp: the snapshot is verified in place, kept, and
  # stamped again.
  local inode
  inode="$(inode_of "$SNAPSHOT")"
  rm "$TRELLIS_HOME/state/exec-stamps/1.2.3-$DIGEST.json"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  [ "$(inode_of "$SNAPSHOT")" = "$inode" ]
  [ -f "$TRELLIS_HOME/state/exec-stamps/1.2.3-$DIGEST.json" ]
  assert_one_snapshot_no_work
}

@test "concurrent first runs all succeed and leave exactly one snapshot" {
  local i pids=()
  make_release 300
  for i in 1 2 3 4; do
    env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor "c$i" > "$SANDBOX/out-$i" 2>&1 &
    pids+=("$!")
  done
  for i in 1 2 3 4; do
    local rc=0
    wait "${pids[$((i - 1))]}" || rc=$?
    [ "$rc" -eq 3 ] || { echo "run $i: rc=$rc"; cat "$SANDBOX/out-$i"; false; }
    [ "$(cat "$SANDBOX/out-$i")" = "ran doctor c$i from $SNAPSHOT/payload/scripts/trellis" ] ||
      { echo "run $i:"; cat "$SANDBOX/out-$i"; false; }
  done
  assert_one_snapshot_no_work
}

@test "a run killed while building leaves no runnable partial, and the next run rebuilds" {
  local pid work="" i
  make_release 300
  perl -e 'setpgrp(0, 0); exec @ARGV' env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor \
    > "$SANDBOX/killed.out" 2>&1 &
  pid=$!
  for i in $(seq 1 3000); do
    work="$(find "$EXEC_STORE" -maxdepth 1 -name '.tmp.1.2.3-*' ! -name '*.owner.json' -print 2>/dev/null)" || :
    [ -z "$work" ] || break
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" || true
  [ -n "$work" ] || { echo 'never saw the work directory'; cat "$SANDBOX/killed.out"; false; }
  [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || { echo 'a killed build published the final name'; false; }
  [[ "$(cat "$SANDBOX/killed.out")" != *'ran doctor'* ]]

  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$output" = "$RAN" ] || { echo "$output"; false; }
  [ -d "$SNAPSHOT" ]
  # The killed run's work directory is left for the janitor; it is not the
  # snapshot that ran.
  [ "$(find "$EXEC_STORE" -maxdepth 1 -name '1.2.3-*' -print)" = "$SNAPSHOT" ]
}

@test "a tampered snapshot is refused, rebuilt, and never executed" {
  local inode
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  inode="$(inode_of "$SNAPSHOT")"
  tamper "$SNAPSHOT/payload/scripts/trellis"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"release execution snapshot failed verification and is rebuilt: $SNAPSHOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$RAN"* ]] || { echo "$output"; false; }
  [ ! -e "$MARKER" ] || { echo 'tampered snapshot bytes executed'; false; }
  [ "$(inode_of "$SNAPSHOT")" != "$inode" ]
  assert_one_snapshot_no_work

  # A half-built directory under the final name, and a symlink there to a
  # good copy elsewhere: both refused and replaced.
  chmod -R u+w "$SNAPSHOT"
  rm -rf "$SNAPSHOT/payload"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"failed verification and is rebuilt"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$RAN"* ]] || { echo "$output"; false; }

  chmod u+w "$SNAPSHOT"
  mv "$SNAPSHOT" "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$SNAPSHOT"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"failed verification and is rebuilt"* ]] || { echo "$output"; false; }
  [ ! -L "$SNAPSHOT" ] && [ -d "$SNAPSHOT" ]
  assert_one_snapshot_no_work
}

@test "a tampered installed release is refused even though its snapshot is intact" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  tamper "$RELEASES/1.2.3/payload/README"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'configured release content has changed: README'* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }
}

@test "help, heavy --check and heavy --status need no release at all" {
  local dispatcher_help supervisor
  mkdir -p "$RELEASES/1.2.3"
  printf 'broken record\n' > "$RELEASES/1.2.3/release.json"
  dispatcher_help="$(bash "$REPO_ROOT/scripts/trellis" help)"

  run_launcher
  [ "$status" -eq 0 ] && [ "$output" = "$dispatcher_help" ] || { echo "no words: $output"; false; }
  for word in help --help -h ''; do
    run_launcher "$word"
    [ "$status" -eq 0 ] || { echo "'$word': $output"; false; }
    [ "$output" = "$dispatcher_help" ] || { echo "'$word': $output"; false; }
  done
  run_launcher help extra words
  [ "$status" -eq 0 ] && [ "$output" = "$dispatcher_help" ] || { echo "$output"; false; }

  for mode in check status; do
    run_launcher heavy "--$mode"
    [ "$status" -eq 0 ] || { echo "$mode: $output"; false; }
    supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" "$mode" 2>&1)"
    [ "$output" = "$supervisor" ] || { printf 'launcher:\n%s\nsupervisor:\n%s\n' "$output" "$supervisor"; false; }
  done
  [ ! -e "$TRELLIS_HOME/state" ] && [ ! -e "$EXEC_STORE" ]

  # Any other shape is an ordinary route and meets the broken release.
  run_launcher heavy --status --light
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
}

@test "heavy --status from the launcher matches the supervisor on held, retired and broken tables" {
  local slots="$TRELLIS_HOME/locks/heavy" supervisor holder
  mkdir -p "$RELEASES"
  mkdir -p "$slots"
  chmod 700 "$TRELLIS_HOME/locks" "$slots"
  # Slot 3 is retired (heavy_slots 2) and held, with an info line.
  printf '%s\tlane-x\t2026-10-31T00:00:00Z\tbats x.bats\n' "$$" > "$slots/slot-3.info"
  perl -MFcntl=:flock -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; print "locked\n"; $| = 1; sleep 30' \
    "$slots/slot-3.lock" > "$SANDBOX/holder.out" &
  holder=$!
  for _ in $(seq 1 200); do [ -s "$SANDBOX/holder.out" ] && break; sleep 0.05; done
  run_launcher heavy --status
  supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" status 2>&1)"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'slot 3: held (retired) lane=lane-x'* ]] || { echo "$output"; false; }
  [ "$output" = "$supervisor" ] || { printf 'launcher:\n%s\nsupervisor:\n%s\n' "$output" "$supervisor"; false; }

  # A broken config and an open slot directory fail the same way in both.
  jq '.heavy_slots = 0' "$TRELLIS_HOME/config.json" > "$SANDBOX/config" && cat "$SANDBOX/config" > "$TRELLIS_HOME/config.json"
  run_launcher heavy --check
  supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" check 2>&1)" || :
  [ "$status" -eq 78 ] && [ "$output" = "$supervisor" ] || { printf '%s\n--\n%s\n' "$output" "$supervisor"; false; }
  jq 'del(.heavy_slots)' "$TRELLIS_HOME/config.json" > "$SANDBOX/config" && cat "$SANDBOX/config" > "$TRELLIS_HOME/config.json"
  chmod 755 "$slots"
  run_launcher heavy --status
  supervisor="$(TRELLIS_HOME="$TRELLIS_HOME" perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" status 2>&1)" || :
  [ "$status" -eq 78 ] && [ "$output" = "$supervisor" ] || { printf '%s\n--\n%s\n' "$output" "$supervisor"; false; }
}

@test "the launcher's pinned copies equal their sources" {
  local copy source
  copy="$(awk '/^launcher_release_stamp_python\(\) \{$/ { getline; inside = 1; next }
    inside && /^TRELLIS_RELEASE_STAMP_PY$/ { exit } inside { print }' "$LAUNCHER_TEMPLATE")"
  [ -n "$copy" ] && [ "$copy" = "$(cat "$REPO_ROOT/scripts/lib/release_stamp.py")" ] ||
    { echo 'launcher_release_stamp_python drifted from scripts/lib/release_stamp.py'; false; }

  copy="$(awk '/^launcher_usage\(\) \{$/ { getline; inside = 1; next } inside && /^EOF$/ { exit } inside { print }' "$LAUNCHER_TEMPLATE")"
  source="$(awk '/^usage\(\) \{$/ { getline; inside = 1; next } inside && /^EOF$/ { exit } inside { print }' "$REPO_ROOT/scripts/trellis")"
  [ -n "$copy" ] && [ "$copy" = "$source" ] || { echo 'launcher_usage drifted from usage() in scripts/trellis'; false; }

  run python3 -I - "$LAUNCHER_TEMPLATE" "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" <<'PY'
import re, sys
launcher, supervisor = (open(path).read() for path in sys.argv[1:3])
body = launcher.split("launcher_heavy_metadata_perl() {\n", 1)[1].split("\nTRELLIS_HEAVY_METADATA_PL\n", 1)[0]
blocks = re.findall(r"\n#@pin\n(.*?)\n#@end\n", body, re.S)
if len(blocks) != 2:
    sys.exit("expected two pinned blocks, found %d" % len(blocks))
for block in blocks:
    if block not in supervisor:
        sys.exit("pinned block is not in heavy-supervisor.pl:\n" + block[:200])
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # The capability line the launcher looks for is the one this release's own
  # normative predicate file declares, so a current payload takes the
  # persistent snapshot.
  copy="$(sed -n "s/.*grep -qxF '\\(# trellis-payload-capability: [a-z-]*\\)'.*/\\1/p" "$LAUNCHER_TEMPLATE")"
  [ -n "$copy" ] && grep -qxF "$copy" "$REPO_ROOT/scripts/lib/trellis-home.sh" ||
    { echo "capability line '$copy' is not declared in scripts/lib/trellis-home.sh"; false; }
}

@test "release list and locate ignore the execution snapshot store" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -d "$SNAPSHOT" ]

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_list' _ "$REPO_ROOT/scripts/lib/release-store.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'.exec'* ]] && [[ "$output" != *'unexpected release store entry'* ]] || { echo "$output"; false; }
  [[ "$output" == *'1.2.3'* ]] || { echo "$output"; false; }

  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_locate 1.2.3' _ "$REPO_ROOT/scripts/lib/release-store.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$RELEASES/1.2.3" ] || { echo "$output"; false; }
}

@test "a snapshot changed while the installed release is re-verified is refused and rebuilt" {
  local pid i seen="" rc=0
  make_release 1000
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # Same bytes, new ctime: only the installed release's stamp misses, so this
  # run takes its full verify. While that verify runs, rewrite the snapshot,
  # whose stamp hit before the verify began.
  chmod u+w "$RELEASES/1.2.3/payload/README"
  chmod a-w "$RELEASES/1.2.3/payload/README"
  env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor > "$SANDBOX/race.out" 2>&1 &
  pid=$!
  for i in $(seq 1 3000); do
    seen="$(find "$RELEASES" -maxdepth 1 -name '.tmp.1.2.3.verify.*' -print 2>/dev/null)" || :
    [ -z "$seen" ] || break
  done
  [ -z "$seen" ] || tamper "$SNAPSHOT/payload/scripts/trellis"
  wait "$pid" || rc=$?
  [ -n "$seen" ] || { echo 'never caught the installed release verify'; cat "$SANDBOX/race.out"; false; }
  [ ! -e "$MARKER" ] || { echo 'snapshot bytes changed during the verify were executed'; false; }
  [ "$rc" -eq 3 ] || { echo "rc=$rc"; cat "$SANDBOX/race.out"; false; }
  grep -qF "release execution snapshot failed verification and is rebuilt: $SNAPSHOT" "$SANDBOX/race.out" ||
    { cat "$SANDBOX/race.out"; false; }
  grep -qxF "$RAN" "$SANDBOX/race.out" || { cat "$SANDBOX/race.out"; false; }
}

@test "an older payload runs from a per-run snapshot its own gate accepts, and rollback keeps working" {
  local old_digest current_ran
  make_release 0 1.2.4
  current_ran="$RAN"
  make_release 0 1.2.3 old
  old_digest="$DIGEST"

  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == "ran doctor from $RELEASES/.tmp.1.2.3.exec."*"/payload/scripts/trellis" ]] || { echo "$output"; false; }
  [ ! -e "$EXEC_STORE" ] || { echo 'an old payload created the persistent store'; false; }
  [ -z "$(find "$RELEASES" -maxdepth 2 -name '.tmp.*' -print)" ] || { echo 'the per-run snapshot survived'; false; }
  [ -f "$TRELLIS_HOME/state/release-stamps/1.2.3-$old_digest.json" ]

  # Forward to the current release, then roll back with the same launcher.
  write_config 1.2.4
  run_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$current_ran" ] || { echo "$output"; false; }
  write_config 1.2.3
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "rollback: $output"; false; }
  [[ "$output" == "ran doctor from $RELEASES/.tmp.1.2.3.exec."*"/payload/scripts/trellis" ]] || { echo "$output"; false; }
  write_config 1.2.4
  run_launcher doctor
  [ "$status" -eq 3 ] && [ "$output" = "$current_ran" ] || { echo "$output"; false; }
}

@test "a repair waits for the one in progress and keeps the snapshot it leaves" {
  local inode holder pid rc=0
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  inode="$(inode_of "$SNAPSHOT")"

  # Another run holds the repair lock while the snapshot is tampered with.
  tamper "$SNAPSHOT/payload/scripts/trellis"
  perl -MFcntl=:flock -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; $| = 1; print "held\n"; sleep 60' \
    "$EXEC_STORE/.lock.${SNAPSHOT##*/}" > "$SANDBOX/holder.out" &
  holder=$!
  for _ in $(seq 1 200); do [ -s "$SANDBOX/holder.out" ] && break; sleep 0.05; done
  env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" doctor > "$SANDBOX/waiter.out" 2>&1 &
  pid=$!
  sleep 3
  # The holder repairs it in place, then lets go.
  chmod u+w "$SNAPSHOT/payload/scripts" "$SNAPSHOT/payload/scripts/trellis"
  cat "$SANDBOX/original" > "$SNAPSHOT/payload/scripts/trellis"
  chmod a-w "$SNAPSHOT/payload/scripts/trellis" "$SNAPSHOT/payload/scripts"
  kill "$holder"
  wait "$holder" 2>/dev/null || :
  wait "$pid" || rc=$?
  [ "$rc" -eq 3 ] || { echo "rc=$rc"; cat "$SANDBOX/waiter.out"; false; }
  [ "$(cat "$SANDBOX/waiter.out")" = "$RAN" ] || { cat "$SANDBOX/waiter.out"; false; }
  [ ! -e "$MARKER" ]
  [ "$(inode_of "$SNAPSHOT")" = "$inode" ] || { echo 'the repaired snapshot was replaced'; false; }
}

@test "retiring a rejected snapshot moves only that instance" {
  local identity
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  identity="$(exec_driver exec-identity "$TRELLIS_HOME" 1.2.3 "$DIGEST")"
  [[ "$identity" == *:* ]] || { echo "$identity"; false; }

  run exec_driver exec-retire "$TRELLIS_HOME" 1.2.3 "$DIGEST" "0:0" "$$" "fixture birth"
  [ "$status" -eq 3 ] || { echo "status=$status $output"; false; }
  [ "$(exec_driver exec-identity "$TRELLIS_HOME" 1.2.3 "$DIGEST")" = "$identity" ]
  assert_one_snapshot_no_work

  run exec_driver exec-retire "$TRELLIS_HOME" 1.2.3 "$DIGEST" "$identity" "$$" "fixture birth"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ ! -e "$SNAPSHOT" ] && [ -d "$EXEC_STORE/$output" ] && [ -f "$EXEC_STORE/$output.owner.json" ]
}

@test "an unsafe execution snapshot store is refused before it is used" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # Opened up after warming: the stamp would hit, but the store is refused.
  chmod 777 "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"release execution snapshot store is not a private real directory: $EXEC_STORE"* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }
  chmod 700 "$EXEC_STORE"
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
}

@test "an execution snapshot store symlinked outside is refused and nothing is written there" {
  make_release
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }

  # A store that is a symlink to a directory outside, holding a planted copy.
  mkdir -m 700 "$SANDBOX/outside"
  chmod -R u+w "$EXEC_STORE"
  mv "$SNAPSHOT" "$SANDBOX/outside/"
  rm -rf "$EXEC_STORE"
  ln -s "$SANDBOX/outside" "$EXEC_STORE"
  ls -A "$SANDBOX/outside" > "$SANDBOX/outside.before"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *"release execution snapshot store is not a private real directory"* ]] || { echo "$output"; false; }
  [[ "$output" != *'ran doctor'* ]] || { echo "$output"; false; }
  ls -A "$SANDBOX/outside" | cmp -s - "$SANDBOX/outside.before" || { echo 'wrote outside the store:'; ls -A "$SANDBOX/outside"; false; }
}
