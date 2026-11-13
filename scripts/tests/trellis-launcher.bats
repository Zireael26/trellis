#!/usr/bin/env bats
# Immutable-launcher and dispatcher contracts.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LAUNCHER_TEMPLATE="$REPO_ROOT/scripts/trellis-launcher.sh"
DISPATCHER_TEMPLATE="$REPO_ROOT/scripts/trellis"
load helpers/payload-fixture
load helpers/native-launcher

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/trellis-launcher.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  SOCKET_FIXTURE=""
  SOURCE_POISON="$SANDBOX/source-poison"
  SOURCE_POISON_MARKER="$SANDBOX/source-poison-ran"
  ARGV_LOG="$HOME/trellis-launcher-argv.log"
  ATTACH_PATH_LOG="$HOME/trellis-launcher-attach-path.log"
  ROUTE_LOG="$SANDBOX/route.log"
  LAUNCHER="$SANDBOX/bin/trellis"
  DISPATCH_ROOT="$SANDBOX/dispatcher"
  mkdir -p "$HOME" "$TRELLIS_HOME/releases" "$SANDBOX/projects" "$SOURCE_POISON/scripts" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  cat > "$SOURCE_POISON/scripts/trellis" <<EOF
#!/usr/bin/env bash
printf 'source poison ran\n' > "$SOURCE_POISON_MARKER"
exit 99
EOF
  chmod 755 "$SOURCE_POISON/scripts/trellis"
  cp "$LAUNCHER_TEMPLATE" "$LAUNCHER"
  chmod 755 "$LAUNCHER"
  write_config 1.2.3
}

teardown() {
  if [ -n "${SOCKET_FIXTURE:-}" ] && [ -d "$SOCKET_FIXTURE" ]; then
    rm -rf "$SOCKET_FIXTURE"
  fi
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  find "$SANDBOX" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$SANDBOX"
}

write_config() {
  local version="$1" remote="${2:-fixture://release}"
  jq -n --arg source "$SOURCE_POISON" --arg release "$version" --arg remote "$remote" --arg projects "$SANDBOX/projects" '
    {
      schema_version: 1,
      source_root: $source,
      release_remote: $remote,
      active_cli_release: $release,
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$projects]}}
    }
  ' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

make_bootstrap_release_remote() {
  local version="$1" remote="$2"
  mkdir -p "$remote/core-rules" "$remote/scripts"
  cp "$DISPATCHER_TEMPLATE" "$remote/scripts/trellis"
  cp "$REPO_ROOT/scripts/release.sh" "$remote/scripts/release.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$remote/scripts/lib"
  printf '%s\n' "$version" > "$remote/core-rules/VERSION"
  (
    cd "$remote" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git add core-rules scripts
    git commit -qm "release $version"
    git tag -a "v$version" -m "release $version"
  )
}

make_release() {
  local version="$1" fixture="${2:-dispatcher}" manifest
  RELEASE_DIR="$TRELLIS_HOME/releases/$version"
  PAYLOAD="$RELEASE_DIR/payload"
  manifest="$SANDBOX/manifest-$version.jsonl"
  mkdir -p "$PAYLOAD/scripts"
  case "$fixture" in
    native-probe)
      mkdir -p "$PAYLOAD/scripts/lib"
      printf '# trellis-payload-capability: exec-snapshot\n' > "$PAYLOAD/scripts/lib/trellis-home.sh"
      cat > "$PAYLOAD/scripts/trellis" <<'EOF'
#!/bin/bash
printf '%s\n' "$TMPDIR" > "$HOME/native-scratch.log"
printf '%s\0' "$@" > "$HOME/native-argv.log"
[ -z "${BASH_ENV-}${ENV-}${GIT_CONFIG_COUNT-}${GIT_CONFIG_KEY_0-}" ] || exit 91
if [ "${1:-}" = stdin ]; then
  IFS= read -r line
  printf '%s\n' "$line"
fi
exit 3
EOF
      ;;
    dispatcher)
      cat > "$PAYLOAD/scripts/trellis" <<'EOF'
#!/bin/bash
{
  printf '%s\n' "$#"
  for argument in "$@"; do printf '<%s>\n' "$argument"; done
} > "$HOME/trellis-launcher-argv.log"
printf '%s\n' "${TRELLIS_ATTACH_CALLER_PATH-__UNSET__}" > "$HOME/trellis-launcher-attach-path.log"
exit 3
EOF
      ;;
    stdin)
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      mkdir -p "$PAYLOAD/core-rules/hooks"
      cat > "$PAYLOAD/scripts/doctor.sh" <<'EOF'
#!/bin/bash
IFS= read -r line
printf '%s\n' "$line"
exit 3
EOF
      cp "$PAYLOAD/scripts/doctor.sh" "$PAYLOAD/core-rules/hooks/inject-primer-index.sh"
      chmod 755 "$PAYLOAD/scripts/doctor.sh" "$PAYLOAD/core-rules/hooks/inject-primer-index.sh"
      ;;
    session-context)
      mkdir -p \
        "$PAYLOAD/core-rules/hooks/lib" \
        "$PAYLOAD/core-rules/codex/hooks/lib"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      for hook in session-start session-context inject-primer-index; do
        cp "$REPO_ROOT/core-rules/hooks/$hook.sh" "$PAYLOAD/core-rules/hooks/$hook.sh"
        cp "$REPO_ROOT/core-rules/codex/hooks/$hook.sh" "$PAYLOAD/core-rules/codex/hooks/$hook.sh"
        chmod 755 "$PAYLOAD/core-rules/hooks/$hook.sh" "$PAYLOAD/core-rules/codex/hooks/$hook.sh"
      done
      cp "$REPO_ROOT/core-rules/hooks/lib/deps.sh" \
        "$PAYLOAD/core-rules/hooks/lib/deps.sh"
      cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" \
        "$PAYLOAD/core-rules/hooks/lib/autonomy.sh"
      cp "$REPO_ROOT/core-rules/codex/hooks/lib/deps.sh" \
        "$PAYLOAD/core-rules/codex/hooks/lib/deps.sh"
      cp "$REPO_ROOT/core-rules/codex/hooks/lib/autonomy.sh" \
        "$PAYLOAD/core-rules/codex/hooks/lib/autonomy.sh"
      printf '{"autonomy_default":4}\n' > "$PAYLOAD/trellis.config.json"
      ;;
    native-session|native-session-stubs|native-session-custom|native-session-deps|native-session-heavy)
      # T24: the real dispatcher chain under a warm-capable snapshot.
      mkdir -p "$PAYLOAD/core-rules/hooks" "$PAYLOAD/core-rules/codex/hooks" "$PAYLOAD/scripts/lib"
      printf '# trellis-payload-capability: exec-snapshot\n' > "$PAYLOAD/scripts/lib/trellis-home.sh"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      for dir in core-rules/hooks core-rules/codex/hooks; do
        cp -R "$REPO_ROOT/$dir/lib" "$PAYLOAD/$dir/lib"
        for hook in session-start session-context inject-primer-index post-compact-context; do
          cp "$REPO_ROOT/$dir/$hook.sh" "$PAYLOAD/$dir/$hook.sh"
          chmod 755 "$PAYLOAD/$dir/$hook.sh"
        done
        [ "$fixture" != native-session-custom ] || printf '\n# custom dispatcher bytes\n' >> "$PAYLOAD/$dir/session-start.sh"
        # QP M1: same dispatcher, sealed dependency with different policy.
        [ "$fixture" != native-session-deps ] || cat >> "$PAYLOAD/$dir/lib/deps.sh" <<'EOF'
_se_require_jq() { if [ "${1:-}" = session-start ]; then echo 'custom deps refusal' >&2; exit 7; fi; }
EOF
        # The lazily loaded heavy lib binds like deps.sh: a byte of difference
        # keeps the complete shell route.
        [ "$fixture" != native-session-heavy ] || printf '\n# custom heavy bytes\n' >> "$PAYLOAD/$dir/lib/deps-heavy.sh"
        [ "$fixture" != native-session ] || continue
        # Members that expose how the dispatcher judged them. Behaviour is read
        # at run time from $SANDBOX/member-mode so one sealed release serves all.
        for hook in session-context inject-primer-index post-compact-context; do
          cat > "$PAYLOAD/$dir/$hook.sh" <<EOF
#!/usr/bin/env bash
input="\$(cat)"
/bin/ps -o comm= -p "\$PPID" | /usr/bin/sed 's#.*/##' > '$SANDBOX/member-parent'
/usr/bin/env | /usr/bin/grep -Ev '^(_|SHLVL|PWD|OLDPWD)=' | LC_ALL=C /usr/bin/sort > '$SANDBOX/member-env-$hook'
printf '%s' "\$input" > '$SANDBOX/member-stdin-$hook'
case "\$(cat '$SANDBOX/member-mode' 2>/dev/null)/$hook" in
  fail/inject-primer-index) exit 3 ;;
  junk/session-context) printf 'not json\n'; exit 0 ;;
  two/session-context) printf '%s\n' '{"hookSpecificOutput":{"additionalContext":"one"}} null {"hookSpecificOutput":{"additionalContext":"two"}}' ;;
  controls/*) printf '%s\n' '{"hookSpecificOutput":{"additionalContext":"tab\\t del\\u007f \\u0001 \\"q\\" \\u00e9 \\ud83d\\ude00"}}' ;;
  silent/*) printf '\n' ;;
  sleep/session-context) echo \$\$ > '$SANDBOX/member-pid'; exec sleep 30 ;;
  *) printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$hook" ;;
esac
EOF
          chmod 755 "$PAYLOAD/$dir/$hook.sh"
        done
      done
      printf '{"autonomy_default":4}\n' > "$PAYLOAD/trellis.config.json"
      ;;
    command-bundle)
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp "$REPO_ROOT/scripts/upgrade.sh" "$PAYLOAD/scripts/upgrade.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      chmod 755 "$PAYLOAD/scripts/release.sh" "$PAYLOAD/scripts/upgrade.sh"
      printf '%s\n' "$version" > "$PAYLOAD/core-rules/VERSION"
      ;;
    command-bundle-pre-bundle-upgrade|command-bundle-unmarked-upgrade)
      # An installed payload from before the launcher routed upgrade through a
      # verified in-memory bundle. Everything else is the current release.
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      cat > "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
#!/bin/sh
# Pre-bundle upgrade wrapper: a pathname bootstrap and nothing else.
printf 'legacy upgrade wrapper ran\n'
exit 5
EOF
      if [ "$fixture" = command-bundle-pre-bundle-upgrade ]; then
        cat >> "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
# -- trellis upgrade body --
set -u
SCRIPT_DIR="${TRELLIS_UPGRADE_SOURCE_DIR:-}"
printf 'legacy upgrade body ran\n'
exit 0
EOF
      fi
      chmod 755 "$PAYLOAD/scripts/release.sh" "$PAYLOAD/scripts/upgrade.sh"
      printf '%s\n' "$version" > "$PAYLOAD/core-rules/VERSION"
      ;;
    scratch-probe)
      # A payload child that reports the command scratch it was handed and, on
      # request, mutates it. The mode file is read at run time so one fixture
      # covers every lifecycle case without a second sealed release.
      cat > "$PAYLOAD/scripts/trellis" <<EOF
#!/bin/bash
mode="\$(cat "$SANDBOX/scratch-probe-mode" 2>/dev/null || printf record)"
printf '%s\n' "\${TMPDIR-__UNSET__}" > "$SANDBOX/scratch-tmpdir.log"
if [ -n "\${TMPDIR-}" ] && [ -d "\$TMPDIR" ]; then
  LC_ALL=C /bin/ls -ld "\$TMPDIR" | /usr/bin/awk '{print substr(\$1, 1, 10)}' > "$SANDBOX/scratch-mode.log"
fi
case "\$mode" in
  record) ;;
  write)
    printf 'command temp file\n' > "\$TMPDIR/probe-file"
    /usr/bin/mktemp "\${TMPDIR:-/tmp}/probe.XXXXXX" > "$SANDBOX/scratch-mktemp.log"
    ;;
  child-symlink)
    /bin/ln -s "$SANDBOX/neighbour-target" "\$TMPDIR/link"
    ;;
  replace-directory)
    /bin/rmdir "\$TMPDIR" && /bin/mkdir "\$TMPDIR" && printf 'replacement\n' > "\$TMPDIR/replacement"
    ;;
  replace-parent)
    printf 'original scratch bytes\n' > "\$TMPDIR/original"
    /bin/mv "\$TRELLIS_HOME/state/scratch" "\$TRELLIS_HOME/state/scratch-retained" || exit 91
    /bin/mkdir -m 700 "\$TRELLIS_HOME/state/scratch" "\$TMPDIR" || exit 92
    printf 'replacement scratch bytes\n' > "\$TMPDIR/replacement"
    printf 'replacement neighbour bytes\n' > "\$TRELLIS_HOME/state/scratch/neighbour"
    ;;
  replace-state-alias)
    printf 'original scratch bytes\n' > "\$TMPDIR/original"
    printf 'state sentinel bytes\n' > "\$TRELLIS_HOME/state/sentinel"
    printf 'neighbour bytes\n' > "\$TRELLIS_HOME/state/scratch/neighbour"
    /bin/mv "\$TRELLIS_HOME/state" "\$TRELLIS_HOME/state.saved" || exit 91
    /bin/ln -s state.saved "\$TRELLIS_HOME/state" || exit 92
    ;;
  replace-symlink)
    /bin/rmdir "\$TMPDIR" && /bin/ln -s "$SANDBOX/neighbour-target" "\$TMPDIR"
    ;;
  term)
    kill -TERM "\$PPID"
    ;;
esac
exit "\$(cat "$SANDBOX/scratch-probe-status" 2>/dev/null || printf 0)"
EOF
      ;;
    command-bundle-scratch)
      # The real release body preloaded under a fixture upgrade body, so the
      # bundle child reports both the TMPDIR the launcher handed it and the
      # value release.sh admitted from it.
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      cat > "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
#!/bin/sh
printf 'scratch upgrade wrapper ran\n'
exit 5
# -- trellis upgrade body --
set -u
trellis_command_bundle_is_verified upgrade "${TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN:-}" || exit 6
printf 'bundle-tmpdir=%s\n' "${TMPDIR-__UNSET__}"
printf 'bundle-admitted=%s\n' "${RELEASE_ADMITTED_TMPDIR-__UNSET__}"
release_git -c 'alias.trellis-scratch-probe=!printf "git-tmpdir=%s\n" "$TMPDIR"' trellis-scratch-probe || exit 7
exit 0
EOF
      chmod 755 "$PAYLOAD/scripts/release.sh" "$PAYLOAD/scripts/upgrade.sh"
      printf '%s\n' "$version" > "$PAYLOAD/core-rules/VERSION"
      ;;
    command-bundle-verifier|command-bundle-verifier-absent)
      # The real release body under a fixture upgrade body that reports the
      # release verifier bytes the bundle carried and a full verify's verdict.
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      [ "$fixture" != command-bundle-verifier-absent ] || rm "$PAYLOAD/scripts/lib/release_verify.py"
      cat > "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
#!/bin/sh
exit 5
# -- trellis upgrade body --
set -u
trellis_command_bundle_is_verified upgrade "${TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN:-}" || exit 6
if [ -z "${_TRELLIS_BUNDLED_RELEASE_VERIFY_PROGRAM+x}" ]; then
  printf 'bundled-verifier=unset\n'
elif printf '%s' "$_TRELLIS_BUNDLED_RELEASE_VERIFY_PROGRAM" | cmp -s - "$TRELLIS_VERIFIED_PAYLOAD/scripts/lib/release_verify.py"; then
  printf 'bundled-verifier=match\n'
else
  printf 'bundled-verifier=mismatch\n'
fi
release_store_verify 1.2.3 >/dev/null
printf 'verify=%s\n' "$?"
exit 0
EOF
      chmod 755 "$PAYLOAD/scripts/release.sh" "$PAYLOAD/scripts/upgrade.sh"
      printf '%s\n' "$version" > "$PAYLOAD/core-rules/VERSION"
      ;;
    session-primer)
      mkdir -p "$PAYLOAD/core-rules/hooks"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cat > "$PAYLOAD/core-rules/hooks/inject-primer-index.sh" <<'EOF'
#!/bin/bash
printf 'trusted-primer:%s:%s git-dir=%s git-work-tree=%s fsmonitor=%s hooks=%s no-system=%s global=%s\n' \
  "$CLAUDE_PROJECT_DIR" "$TRELLIS_ROOT" "${GIT_DIR-unset}" "${GIT_WORK_TREE-unset}" \
  "${GIT_CONFIG_VALUE_0-unset}" "${GIT_CONFIG_VALUE_1-unset}" \
  "${GIT_CONFIG_NOSYSTEM-unset}" "${GIT_CONFIG_GLOBAL-unset}"
EOF
      chmod 755 "$PAYLOAD/core-rules/hooks/inject-primer-index.sh"
      # Still on disk for project-local opt-in; the retired route must not run it.
      cat > "$PAYLOAD/core-rules/hooks/skill-size-preflight.sh" <<'EOF'
#!/bin/bash
: > "$CLAUDE_PROJECT_DIR/preflight-ran"
printf 'scanned discoverable skills\n'
EOF
      chmod 755 "$PAYLOAD/core-rules/hooks/skill-size-preflight.sh"
      ;;
    *)
      printf 'unknown release fixture: %s\n' "$fixture" >&2
      return 2
      ;;
  esac
  chmod 755 "$PAYLOAD/scripts/trellis"
  printf 'immutable fixture %s\n' "$version" > "$PAYLOAD/README"
  printf 'safe symlink target %s\n' "$version" > "$PAYLOAD/linked target"
  ln -s "linked target" "$PAYLOAD/linked fixture"
  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$PAYLOAD" > "$manifest"
  jq -n --arg version "$version" --slurpfile tree "$manifest" '
    {
      schema_version: 1,
      version: $version,
      tag: ("v" + $version),
      commit: "0000000000000000000000000000000000000000",
      remote: "fixture://release",
      tree: $tree
    }
  ' > "$RELEASE_DIR/release.json"
  find "$PAYLOAD" -type f -exec chmod a-w {} +
  find "$PAYLOAD" -type d -exec chmod a-w {} +
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"
}

# The installed launcher closes PATH. Instrument the test copy's trusted
# program selection instead of relying on a caller PATH that it must ignore.
metadata_process_spies() {
  cat > "$SANDBOX/perl-spy" <<EOF
#!/bin/bash
printf 'perl\n' >> '$SANDBOX/metadata-starts'
exec /usr/bin/perl "\$@"
EOF
  chmod 755 "$SANDBOX/perl-spy"
  python3 -I - "$LAUNCHER" "$SANDBOX" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text();root=sys.argv[2]
s=s.replace('perl_bin="$(command -v perl)"','perl_bin="'+root+'/perl-spy"')
marker='launcher_main "$@"';assert s.count(marker)==1
spy='jq() { printf "jq\\n" >> "'+root+'/metadata-starts"; /usr/bin/jq "$@"; }\n'
# Simulate an absent jq in the closed PATH without modifying system tools.
spy+='command() { if [ "$1" = -v ] && [ "${2:-}" = jq ]; then return 1; fi; builtin command "$@"; }\n'
p.write_text(s.replace(marker,spy+marker))
PY
}

@test "metadata routes validate once with one perl and zero jq without a release or scratch" {
  rmdir "$TRELLIS_HOME/releases"
  metadata_process_spies
  local route
  for route in version help check status; do
    : > "$SANDBOX/metadata-starts"
    case "$route" in
      version) run_launcher --version ;;
      help) run_launcher help ignored words ;;
      check) run_launcher heavy --check ;;
      status) run_launcher heavy --status ;;
    esac
    [ "$status" -eq 0 ] || { echo "$route: $status: $output"; false; }
    [ "$(cat "$SANDBOX/metadata-starts")" = perl ] || { echo "$route starts: $(cat "$SANDBOX/metadata-starts")"; false; }
    if [ "$route" = version ]; then [ "$output" = 'trellis 1.2.3 (configured; not verified)' ]; fi
    [ ! -e "$TRELLIS_HOME/state" ] && [ ! -e "$TRELLIS_HOME/releases" ] && [ ! -e "$SOURCE_POISON_MARKER" ]
  done
}

@test "metadata perl validator matches jq including exact schema and legacy lenient inputs" {
  run python3 -I -c 'import re,subprocess; v=subprocess.check_output(["/usr/bin/jq","--version"],text=True); m=re.search(r"(\d+)\.(\d+)",v); assert m and tuple(map(int,m.groups())) >= (1,7), "exact-decimal oracle requires jq1.7+: "+v'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rmdir "$TRELLIS_HOME/releases"
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/base.json"
  python3 -I - "$SANDBOX" <<'PY'
import json,pathlib,sys
r=pathlib.Path(sys.argv[1]);base=json.loads((r/'base.json').read_bytes());cases={}
for name,patch in [('valid',{}),('schema2',{'schema_version':2}),('schema-string',{'schema_version':'1'}),('version',{'active_cli_release':'bad'}),('fleet',{'default_fleet':'bad name'}),('extra',{'surprise':True}),('empty-remote',{'release_remote':''}),('path',{'source_root':'/x/../bad'}),('duplicate-roots',{'fleets':{'personal':{'discovery_roots':['/p','/p']}}}),('bad-heavy',{'heavy_slots':0})]:
    cases[name]=json.dumps({**base,**patch}).encode()
for name,literal in [('float','1.0'),('exponent','10e-1'),('near-high','1.0000000000000000001'),('near-low','0.99999999999999999999'),('schema01','01')]:
    data={**base,'schema_version':'NUMBER'};cases[name]=json.dumps(data).replace('"NUMBER"',literal).encode()
for name,value in [('nan','NaN'),('infinity','Infinity'),('zero','01'),('plus','+1'),('fraction','.5'),('dot','1.'),('low',r'"\udc00"'),('highhigh',r'"\ud800\ud800"'),('huge','1e1000'),('deep','['*254+'null'+']'*254),('too-deep','['*255+'null'+']'*255)]:
    data={**base,'projects':'VALUE'};cases[name]=json.dumps(data).replace('"VALUE"',value).encode()
raw=json.dumps(base).encode();cases.update(bom=b'\xef\xbb\xbf'+raw,nul=raw+b'\0',**{'nul-prefix':b'\0'+raw,'nul-middle':raw[:5]+b'\0'+raw[5:]},junk=raw+b'junk',bad=b'{malformed',missing=json.dumps({k:v for k,v in base.items() if k!='active_cli_release'}).encode())
for name,raw in cases.items():(r/('metadata-case-'+name+'.json')).write_bytes(raw)
PY
  # Execute the exact old jq admission function as an independent oracle.
  python3 -I - "$LAUNCHER_TEMPLATE" "$SANDBOX/jq-validator" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text();start=s.index('launcher_validate_machine_config() {');end=s.index('\n}',start)+2
pathlib.Path(sys.argv[2]).write_text(s[start:end]+'\nlauncher_validate_machine_config "$1"\n')
PY
  local candidate expected
  for candidate in "$SANDBOX"/metadata-case-*.json; do
    cp "$candidate" "$TRELLIS_HOME/config.json"
    run /bin/bash "$SANDBOX/jq-validator" "$TRELLIS_HOME/config.json"
    expected=4
    [ "$status" -ne 0 ] || expected=0
    # jq1.7 may ignore trailing NUL; jq1.8 rejects it. Apex requires strict
    # refusal on every host, including NUL before/inside/after the document.
    # jq1.8 also permits deeper stacks than jq1.7: keep the conservative bound.
    case "${candidate##*/}" in metadata-case-nul*.json|metadata-case-too-deep.json) expected=4 ;; esac
    run_launcher --version
    [ "$status" -eq "$expected" ] || { echo "${candidate##*/}: jq=$expected metadata=$status: $output"; false; }
    run_launcher help
    [ "$status" -eq "$expected" ] || { echo "help ${candidate##*/}: jq=$expected metadata=$status: $output"; false; }
    [ ! -e "$TRELLIS_HOME/state" ] && [ ! -e "$SOURCE_POISON_MARKER" ]
  done
}

@test "metadata refuses multiple top-level objects as malformed single-object config" {
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/one-config.json"
  cat "$SANDBOX/one-config.json" "$SANDBOX/one-config.json" > "$TRELLIS_HOME/config.json"
  # Accepted fail-closed difference: jq's stream filter may admit this, but a
  # machine config is one object. Apex will harden canonical separately.
  run_launcher --version
  [ "$status" -eq 4 ] && [[ "$output" == *'machine config failed validation:'* ]] || { echo "$status: $output"; false; }
  run_launcher help
  [ "$status" -eq 4 ] || { echo "$status: $output"; false; }
  [ ! -e "$TRELLIS_HOME/state" ] && [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "metadata heavy typing stays local while version usage and help text stay exact" {
  jq '.heavy_slots=0' "$TRELLIS_HOME/config.json" > "$SANDBOX/bad-heavy.json"
  cp "$SANDBOX/bad-heavy.json" "$TRELLIS_HOME/config.json"
  run_launcher --version
  [ "$status" -eq 0 ] && [ "$output" = 'trellis 1.2.3 (configured; not verified)' ] || { echo "$status: $output"; false; }
  run_launcher --version extra
  [ "$status" -eq 2 ] && [ "$output" = 'trellis: --version takes no arguments' ] || { echo "$status: $output"; false; }
  local expected
  expected="$(bash "$DISPATCHER_TEMPLATE" help)"
  run_launcher help extra words
  [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || { echo "$status: $output"; false; }
  run_launcher heavy --check
  [ "$status" -eq 78 ] && [[ "$output" == *'heavy_slots must be an integer >= 1 (found 0)'* ]] || { echo "$status: $output"; false; }
  [ ! -e "$TRELLIS_HOME/state" ] && [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "metadata cached slot_counts preserves direct read_slots typing and exact messages" {
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/slots-base.json"
  local field value expected_status expected_output
  for field in heavy_slots heavy_light_slots; do
    for value in 0 -1 1.5 '"2"' true null '[]' '{}' 1000000 2 1.0 1e0; do
      jq --arg field "$field" --argjson value "$value" '.[$field]=$value' "$SANDBOX/slots-base.json" > "$TRELLIS_HOME/config.json"
      run env -i HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH=/usr/bin:/bin \
        /usr/bin/perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" check
      expected_status="$status"; expected_output="$output"
      run_launcher heavy --check
      [ "$status" -eq "$expected_status" ] && [ "$output" = "$expected_output" ] || {
        echo "$field=$value direct=$expected_status: $expected_output; metadata=$status: $output"; false;
      }
    done
  done
}

@test "T59 reviewer corpus covers every verdict class on all four metadata routes" {
  run python3 -I "$REPO_ROOT/scripts/tests/helpers/metadata-parity-corpus.py" "$SANDBOX/reviewer-corpus"
  [ "$status" -eq 0 ] && [ "$output" = 473 ] || { echo "$status: $output"; false; }
  python3 -I - "$LAUNCHER_TEMPLATE" "$SANDBOX/reviewer-jq-validator" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text();start=s.index('launcher_validate_machine_config() {');end=s.index('\n}',start)+2
pathlib.Path(sys.argv[2]).write_text(s[start:end]+'\nlauncher_validate_machine_config "$1"\n')
PY
  run python3 -I "$REPO_ROOT/scripts/tests/helpers/metadata-parity-driver.py" "$LAUNCHER" \
    "$SANDBOX/reviewer-jq-validator" "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" \
    "$SANDBOX/reviewer-corpus" "$TRELLIS_HOME/config.json" "$SANDBOX/reviewer-results.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T59 GNU privacy checks start only the two needed listings" {
  run python3 -I "$REPO_ROOT/scripts/tests/helpers/metadata-privacy-driver.py" "$LAUNCHER_TEMPLATE" "$SANDBOX/privacy-counts" "$BASH" counts
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T59 privacy bit and ACL failure policy is preserved across platform selectors" {
  run python3 -I "$REPO_ROOT/scripts/tests/helpers/metadata-privacy-driver.py" "$LAUNCHER_TEMPLATE" "$SANDBOX/privacy-policy" "$BASH" policy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T59 heavy metadata selectors with extra argv retain canonical dispatch" {
  make_release 1.2.3 dispatcher
  local option
  for option in --check --status; do
    run_launcher heavy "$option" extra
    [ "$status" -eq 3 ] || { echo "extra argv was consumed as metadata: $status: $output"; false; }
    [ "$(cat "$ARGV_LOG")" = "$(printf '3\n<heavy>\n<%s>\n<extra>' "$option")" ] || { echo 'canonical argv changed'; false; }
  done
}

@test "T59 metadata byte ceiling admits exact boundary and refuses over-bound strings and arrays on all routes" {
  python3 -I - "$REPO_ROOT/scripts/tests/helpers/metadata-large-config-probe.py" "$SANDBOX" <<'PY'
import pathlib,runpy,sys
make=runpy.run_path(sys.argv[1])['fixture_bytes'];root=pathlib.Path(sys.argv[2])
for size in (32768,32769,1000195):
    for shape in ('string','array'):
        raw,_=make(size,shape);assert len(raw)==size
        (root/f'boundary-{shape}-{size}.json').write_bytes(raw)
PY
  local shape size route
  for shape in string array; do
    for size in 32768 32769 1000195; do
      cp "$SANDBOX/boundary-$shape-$size.json" "$TRELLIS_HOME/config.json"
      for route in version help check status; do
        case "$route" in version) run_launcher --version ;; help) run_launcher help ;; *) run_launcher heavy "--$route" ;; esac
        if [ "$size" -eq 32768 ]; then
          [ "$status" -eq 0 ] || { echo "$shape/$size/$route: $status: $output"; false; }
        else
          [ "$status" -eq 4 ] || { echo "$shape/$size/$route: $status: $output"; false; }
          [[ "$output" == *'32768-byte limit'* && "$output" == *"actual $size bytes"* && "$output" == *"$TRELLIS_HOME/config.json"* && "$output" == *'command execution is unaffected'* ]] || { echo "$output"; false; }
        fi
      done
    done
  done
  [ ! -d "$TRELLIS_HOME/state" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "T59 metadata ceiling reads at most sentinel bytes and reports held-file size" {
  metadata_process_spies
  python3 -I - "$REPO_ROOT/scripts/tests/helpers/metadata-large-config-probe.py" "$TRELLIS_HOME/config.json" "$SANDBOX" <<'PY'
import pathlib,runpy,sys
raw,_=runpy.run_path(sys.argv[1])['fixture_bytes'](1000195,'string');pathlib.Path(sys.argv[2]).write_bytes(raw)
r=pathlib.Path(sys.argv[3]);(r/'ReadBudget.pm').write_text(r'''
package ReadBudget;
BEGIN {
    *CORE::GLOBAL::read = sub (*\$$;$) {
        my ($fh,$buffer,$wanted,$offset) = @_;
        my $n = defined($offset) ? CORE::read($fh,$$buffer,$wanted,$offset) : CORE::read($fh,$$buffer,$wanted);
        if (caller eq 'main') {
            open(my $log,'>>',q{LOG_PATH}) or die $!;
            print $log "$wanted ",defined($n) ? $n : -1,"\n"; close $log;
        }
        return $n;
    };
}
1;
'''.replace('LOG_PATH',str(r/'read-budget.log')))
(r/'perl-spy').write_text('#!/bin/bash\nexec /usr/bin/perl -I'+str(r)+' -MReadBudget "$@"\n')
PY
  run_launcher --version
  [ "$status" -eq 4 ] && [[ "$output" == *'actual 1000195 bytes'* ]] || { echo "$status: $output"; false; }
  run python3 -I - "$SANDBOX/read-budget.log" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);assert p.is_file(),'no bounded config read was observed'
rows=[tuple(map(int,line.split())) for line in p.read_text().splitlines()]
assert rows and max(wanted for wanted,n in rows)<=32769 and sum(n for wanted,n in rows)==32769,rows
print('bounded sentinel read verified')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T59 metadata ceiling does not change executable canonical config authority" {
  make_release 1.2.3 native-probe
  python3 -I - "$REPO_ROOT/scripts/tests/helpers/metadata-large-config-probe.py" "$TRELLIS_HOME/config.json" <<'PY'
import pathlib,runpy,sys
raw,_=runpy.run_path(sys.argv[1])['fixture_bytes'](1000195,'array');pathlib.Path(sys.argv[2]).write_bytes(raw)
PY
  run_launcher --version
  [ "$status" -eq 4 ] || { echo "$status: $output"; false; }
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "execution affected by metadata limit: $status: $output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "T59 metadata lexical normalization uses byte offsets and preserves Unicode fields" {
  python3 -I - "$TRELLIS_HOME/config.json" "$LAUNCHER_TEMPLATE" "$SANDBOX/byte-lexer.pl" <<'PY'
import json,pathlib,sys
config,template,probe=map(pathlib.Path,sys.argv[1:]);v=json.loads(config.read_text())
v['source_root']='/a/é/😀';v['fleets']['personal']['discovery_roots']=['/p/é'];v['projects']=['é😀']*2000
config.write_text(json.dumps(v,ensure_ascii=False))
s=template.read_text().split("  cat <<'TRELLIS_METADATA_PL'\n",1)[1].split('\nTRELLIS_METADATA_PL\n',1)[0]
prefix=s.split("open(my $metadata_fh, '<', $metadata_path)",1)[0]
probe.write_text(prefix+r'''
open(my $probe_fh, '<', $metadata_path) or die $!;
my $raw = do { local $/; <$probe_fh> }; close $probe_fh;
my $normal = metadata_json_text($raw);
die "normalization refused" unless defined $normal;
die "normalized JSON remains character-indexed" if utf8::is_utf8($normal);
my $decoded = JSON::PP->new->utf8->decode($normal);
die "Unicode field changed" unless $decoded->{source_root} eq '/a/'.chr(0xe9).'/'.chr(0x1f600);
print "byte offsets; Unicode values preserved\\n";
''')
PY
  run env -i HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH=/usr/bin:/bin /usr/bin/perl "$SANDBOX/byte-lexer.pl" version 1
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local route
  for route in version help check status; do
    case "$route" in version) run_launcher --version ;; help) run_launcher help ;; *) run_launcher heavy "--$route" ;; esac
    [ "$status" -eq 0 ] || { echo "$route: $status: $output"; false; }
  done
}

@test "T59 safety refuses NUL and invalid UTF8 on all four metadata routes" {
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/safety-base.json"
  python3 -I - "$SANDBOX" <<'PY'
import pathlib,sys
r=pathlib.Path(sys.argv[1]);raw=(r/'safety-base.json').read_bytes()
for name,data in [('nul-nl',raw+b'\0\n'),('nul-junk',raw+b'\0junk\n'),('nul-second',raw+b'\0'+raw+b'\n'),('nul-line',raw+b'\n\0\n'),('utf8-ff',raw.replace(b'fixture://release',b'\xff')),('utf8-overlong',raw.replace(b'fixture://release',b'\xc0\x80'))]:
    (r/('unsafe-'+name)).write_bytes(data)
PY
  local candidate route
  for candidate in "$SANDBOX"/unsafe-*; do
    cp "$candidate" "$TRELLIS_HOME/config.json"
    for route in version help check status; do
      case "$route" in version) run_launcher --version ;; help) run_launcher help ;; *) run_launcher heavy "--$route" ;; esac
      [ "$status" -eq 4 ] || { echo "${candidate##*/}/$route: $status: $output"; false; }
    done
  done
}

@test "T59 huge schema exponent refuses in under one second without an orphan Perl" {
  python3 -I - "$TRELLIS_HOME/config.json" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_bytes(p.read_bytes().replace(b'"schema_version": 1',b'"schema_version": 1e-999999999'))
PY
  run python3 -I - "$LAUNCHER" <<'PY'
import os,signal,subprocess,sys,time
start=time.monotonic();p=subprocess.Popen([sys.argv[1],'--version'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
try:
    out,err=p.communicate(timeout=.9)
except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGKILL);p.communicate()
    raise AssertionError('schema exponent exceeded .9s; killed entire owned process group')
elapsed=time.monotonic()-start
assert p.returncode==4 and elapsed<1,(p.returncode,elapsed,out,err)
print('bounded literal refusal',p.returncode)
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T59 large slot integers preserve direct supervisor quoted error messages" {
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/large-base"
  local field value expected expected_status
  for field in heavy_slots heavy_light_slots; do
    for value in 100000000000000000000 200000000000000000000 99999999999999999999; do
      python3 -I - "$SANDBOX/large-base" "$TRELLIS_HOME/config.json" "$field" "$value" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text());v[sys.argv[3]]='LARGE';pathlib.Path(sys.argv[2]).write_text(json.dumps(v).replace('"LARGE"',sys.argv[4]))
PY
      run env -i HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" PATH=/usr/bin:/bin /usr/bin/perl "$REPO_ROOT/scripts/lib/heavy-supervisor.pl" check
      expected="$output";expected_status="$status"
      run_launcher heavy --check
      [ "$status" -eq "$expected_status" ] && [ "$output" = "$expected" ] || { echo "$field=$value: expected $expected; got $status: $output"; false; }
    done
  done
}

@test "T59 metadata assembly appends supervisor bytes only for check and status" {
  run python3 -I - "$LAUNCHER_TEMPLATE" "$SANDBOX" <<'PY'
import pathlib,subprocess,sys
source=pathlib.Path(sys.argv[1]).read_text();root=pathlib.Path(sys.argv[2])
def heredoc(marker):
    return source.split("cat <<'"+marker+"'\n",1)[1].split('\n'+marker+'\n',1)[0]
prefix=heredoc('TRELLIS_METADATA_PL');heavy=heredoc('TRELLIS_HEAVY_METADATA_PL')
capture=root/'assembled.pl';collector=root/'collect-program'
collector.write_text('#!'+sys.executable+'\nimport pathlib,sys\nassert sys.argv[1]=="-e"\npathlib.Path('+repr(str(capture))+').write_text(sys.argv[2])\n')
collector.chmod(0o700)
selector='perl_bin="$(command -v perl)"';assert source.count(selector)==1
launcher=root/'capture-launcher';launcher.write_text(source.replace(selector,'perl_bin="'+str(collector)+'"'));launcher.chmod(0o700)
for mode,argv in [('version',['--version']),('help',['help']),('check',['heavy','--check']),('status',['heavy','--status'])]:
    result=subprocess.run([str(launcher),*argv],capture_output=True)
    assert result.returncode==0,(mode,result.returncode,result.stderr)
    expected=prefix if mode in ('version','help') else prefix+'\n'+heavy
    assert capture.read_text()==expected,(mode,'wrong assembled Perl bytes',len(capture.read_bytes()),len(expected.encode()))
print('four exact assembled programs; version/help contain only the metadata prefix')
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T59 every metadata route requires needed modules but not unused modules" {
  metadata_process_spies
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/module-config-base"
  local module kind route expected
  for module in JSON/PP Encode Fcntl MIME/Base64 Storable; do
    mkdir -p "$(dirname "$SANDBOX/missing-modules/$module.pm")"
    printf 'die "fixture module unavailable\\n";\n' > "$SANDBOX/missing-modules/$module.pm"
    cat > "$SANDBOX/perl-spy" <<EOF
#!/bin/bash
exec /usr/bin/perl -I'$SANDBOX/missing-modules' "\$@"
EOF
    for kind in ascii unicode; do
      python3 -I - "$SANDBOX/module-config-base" "$TRELLIS_HOME/config.json" "$kind" <<'PY'
import json,pathlib,sys
v=json.loads(pathlib.Path(sys.argv[1]).read_text())
if sys.argv[3]=='unicode': v['source_root']='/a/é/😀'
pathlib.Path(sys.argv[2]).write_text(json.dumps(v,ensure_ascii=False))
PY
      for route in version help check status; do
        # Independent host-module oracle, never the candidate program: direct
        # needs are fixed, but their transitive closure varies by Perl release.
        # E.g. Linux Encode 3.24 -> Storable -> Fcntl; macOS Encode 3.0801 does
        # not load either. A missing transitive need is still unavailable 5.
        run env -i PATH=/usr/bin:/bin /usr/bin/perl -I"$SANDBOX/missing-modules" -e '
          my ($kind, $route, $hidden) = @ARGV;
          my $ok = eval {
            require JSON::PP;
            JSON::PP->new->utf8->decode("{}");
            if ($kind eq "unicode") {
              require Encode;
              my $raw = "\xc3\xa9";
              Encode::decode("UTF-8", $raw, Encode::FB_CROAK());
            }
            if ($route eq "check" || $route eq "status") {
              require Fcntl; require MIME::Base64;
              MIME::Base64::decode_base64("eD0xAA==");
            }
            1;
          };
          # A loader may probe/catch the first missing require internally;
          # Perl then reports a reload of that same failed module instead.
          die $@ if !$ok && $@ !~ /fixture module unavailable/ &&
            index($@, "Attempt to reload $hidden aborted.") != 0;
          exit($ok ? 0 : 5);
        ' "$kind" "$route" "$module.pm"
        expected="$status"
        case "$expected" in 0|5) ;; *) echo "module oracle failed: $status: $output"; false ;; esac
        case "$route" in version) run_launcher --version ;; help) run_launcher help ;; *) run_launcher heavy "--$route" ;; esac
        [ "$status" -eq "$expected" ] || { echo "$module/$kind/$route expected=$expected got=$status: $output"; false; }
      done
    done
    rm -f "${SANDBOX:?}/missing-modules/$module.pm"
  done
}

assert_native_warm_scratch() {
  # Observation only, never authorization: native uses16 random bytes, whereas
  # canonical uses8. Disabling native dispatch must fail each paired test.
  local scratch suffix
  scratch="$(cat "$HOME/native-scratch.log")"
  suffix="${scratch##*/.cmd.}"
  [ "${#suffix}" -eq 32 ] || { echo "native warm route was not used: $scratch"; false; }
}

@test "paired native launcher accepts cold then certifies warm argv without legacy scratch nesting" {
  make_release 1.2.3 native-probe
  pin_native_launcher
  for attempt in 1 2; do
    run native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" BASH_ENV=/nonexistent ENV=/nonexistent \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.bad GIT_CONFIG_VALUE_0='!exit 99' \
      "$LAUNCHER" doctor '' 'two words'
    [ "$status" -eq 3 ] || { echo "$status: $output"; false; }
    run python3 -I - "$HOME/native-argv.log" <<'PY'
import pathlib,sys
assert pathlib.Path(sys.argv[1]).read_bytes()==b'doctor\0\0two words\0'
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    assert_no_command_scratch
  done
  assert_native_warm_scratch
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "paired native warm launcher preserves the caller stdin stream" {
  make_release 1.2.3 native-probe
  pin_native_launcher
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  run native_bounded /bin/bash -c 'printf "original input\n" | "$1" stdin' _ "$LAUNCHER"
  [ "$status" -eq 3 ] && [ "$output" = 'original input' ] || { echo "$status: $output"; false; }
  assert_native_warm_scratch
  assert_no_command_scratch
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "paired native launcher delegates uncertified original bytes but refuses unsafe config" {
  make_release 1.2.3 native-probe
  pin_native_launcher
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$status: $output"; false; }
  assert_native_warm_scratch
  cp "$TRELLIS_HOME/config.json" "$SANDBOX/paired-base.json"
  python3 -I - "$TRELLIS_HOME/config.json" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_bytes(b'\xef\xbb\xbf'+p.read_bytes())
PY
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$status: $output"; false; }
  for kind in malformed group; do
    cp "$SANDBOX/paired-base.json" "$TRELLIS_HOME/config.json"
    chmod 600 "$TRELLIS_HOME/config.json"
    if [ "$kind" = malformed ]; then
      printf '{malformed' > "$TRELLIS_HOME/config.json"
    else
      chmod 640 "$TRELLIS_HOME/config.json"
    fi
    rm -f "$HOME/native-argv.log"
    run_launcher doctor
    [ "$status" -eq 4 ] || { echo "$kind: $status: $output"; false; }
    [ ! -e "$HOME/native-argv.log" ]
  done
  assert_no_command_scratch
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "--version reports configured release without payload preflight or state writes" {
  # No release store is needed, and the mutable source must never execute.
  rmdir "$TRELLIS_HOME/releases"
  run_launcher --version
  [ "$status" -eq 0 ]
  [ "$output" = 'trellis 1.2.3 (configured; not verified)' ]
  [ ! -e "$TRELLIS_HOME/state" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]

  # A malformed installed release must not turn this metadata query into a
  # verification attempt, nor may extra arguments acquire the cheap route.
  mkdir -p "$TRELLIS_HOME/releases/1.2.3"
  printf 'broken record\n' > "$TRELLIS_HOME/releases/1.2.3/release.json"
  run_launcher --version
  [ "$status" -eq 0 ]
  [ "$output" = 'trellis 1.2.3 (configured; not verified)' ]
  run_launcher --version doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *'--version takes no arguments'* ]] || false
  [ ! -e "$TRELLIS_HOME/state" ]

  chmod 644 "$TRELLIS_HOME/config.json"
  run_launcher --version
  [ "$status" -eq 4 ]
  [[ "$output" == *'machine config is missing, not private'* ]] || false
}

# macOS ls prints "@" for an extended attribute in place of the "+" of an ACL,
# so a mode-column check misses an ACL on a file that also carries an xattr.
# Some hosts tag every new file with com.apple.provenance, so even the ACL-only
# fixture can show "@" there.
@test "launcher refuses a private config whose ACL an xattr marker hides" {
  [ "$(uname -s)" = Darwin ] || skip 'macOS-only: ls -e ACL listing and chmod +a fixture'
  local config="$TRELLIS_HOME/config.json"
  xattr -w com.example.x 1 "$config"
  chmod +a "user:$(id -un) allow read" "$config"
  [[ "$(LC_ALL=C /bin/ls -ld "$config")" == '-rw-------@ '* ]] || { ls -lde "$config"; false; }
  run_launcher --version
  [ "$status" -eq 4 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *'machine config is missing, not private'* ]] || { echo "$output"; false; }
}

@test "launcher admits a private config carrying an xattr and no ACL" {
  [ "$(uname -s)" = Darwin ] || skip 'macOS-only: xattr fixture'
  local config="$TRELLIS_HOME/config.json"
  xattr -w com.example.x 1 "$config"
  [[ "$(LC_ALL=C /bin/ls -ld "$config")" == '-rw-------@ '* ]] || { ls -lde "$config"; false; }
  run_launcher --version
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$output" = 'trellis 1.2.3 (configured; not verified)' ]
}

@test "launcher refuses a private config carrying an ACL" {
  [ "$(uname -s)" = Darwin ] || skip 'macOS-only: chmod +a fixture'
  chmod +a "user:$(id -un) allow read" "$TRELLIS_HOME/config.json"
  run_launcher --version
  [ "$status" -eq 4 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *'machine config is missing, not private'* ]] || { echo "$output"; false; }
}

# Native refuses any of setuid, setgid or sticky on the config (mask 0o7077).
# A host may strip a bit chmod asked for (setgid outside the file's group), so
# each row asserts on the bits actually present.
@test "launcher refuses a private config carrying special mode bits" {
  local config="$TRELLIS_HOME/config.json" mode actual
  for mode in 4600 4700 2600 1600; do
    chmod "$mode" "$config"
    # BSD %Lp drops the special bits; %Mp is that digit.
    actual="$(stat -f '%Mp%Lp' "$config" 2>/dev/null)" || actual=""
    case "$actual" in ''|*[!0-7]*) actual="$(stat -c '%a' "$config")" ;; esac
    if [ "$actual" -lt 1000 ]; then
      echo "# $mode: host stripped the special bit (now $actual)" >&3
      continue
    fi
    run_launcher --version
    [ "$status" -eq 4 ] || { echo "mode $actual: status=$status $output"; false; }
    [[ "$output" == *'machine config is missing, not private'* ]] || { echo "$output"; false; }
  done
  for mode in 600 700 400; do
    chmod "$mode" "$config"
    run_launcher --version
    [ "$status" -eq 0 ] || { echo "mode $mode: status=$status $output"; false; }
  done
}

@test "launcher refuses a Trellis home whose ACL an xattr marker hides" {
  [ "$(uname -s)" = Darwin ] || skip 'macOS-only: ls -e ACL listing and chmod +a fixture'
  xattr -w com.example.x 1 "$TRELLIS_HOME"
  run_launcher --version
  [ "$status" -eq 0 ] || { echo "xattr alone: status=$status $output"; false; }
  chmod +a "user:$(id -un) allow list" "$TRELLIS_HOME"
  [[ "$(LC_ALL=C /bin/ls -ld "$TRELLIS_HOME")" == 'drwx------@ '* ]] || { ls -lde "$TRELLIS_HOME"; false; }
  run_launcher --version
  [ "$status" -eq 4 ] || { echo "status=$status $output"; false; }
  [[ "$output" == *'Trellis home is missing, not private'* ]] || { echo "$output"; false; }
}

run_launcher() {
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" "$@"
}

# The persistent execution snapshot (releases/.exec/<version>-<digest>) stays;
# nothing else a run creates in the store may survive it: no snapshot work
# directory or owner sidecar, no verify scratch, no per-run snapshot of the kind
# launchers before 1.4.0 made. `find` prints nothing at all when its own start
# point does not exist — it writes to stderr and returns non-zero — so a bare
# `[ -z "$(find …)" ]` also passes when the release store was never created,
# which is not the claim. Prove the store is there first, then fold stderr into
# the captured text so a find failure is non-empty output rather than a silent
# pass.
assert_no_execution_snapshot() {
  [ -d "$TRELLIS_HOME/releases" ] ||
    { echo "release store is absent, so the emptiness claim is vacuous: $TRELLIS_HOME/releases"; false; }
  local leftover
  leftover="$(find "$TRELLIS_HOME/releases" -maxdepth 2 -name '.tmp.*' -print 2>&1)"
  [ -z "$leftover" ] || { echo "execution snapshot work survived: $leftover"; false; }
}

# Same shape as assert_no_execution_snapshot: prove the root exists first, so an
# absent scratch root cannot pass as an empty one.
assert_no_command_scratch() {
  [ -d "$TRELLIS_HOME/state/scratch" ] ||
    { echo "command scratch root is absent, so the emptiness claim is vacuous: $TRELLIS_HOME/state/scratch"; false; }
  local leftover
  leftover="$(find "$TRELLIS_HOME/state/scratch" -maxdepth 1 -name '.cmd.*' -print 2>&1)"
  [ -z "$leftover" ] || { echo "command scratch survived: $leftover"; false; }
}

run_launcher_with_tmpdir() {
  local candidate="$1"
  shift
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TMPDIR="$candidate" "$LAUNCHER" "$@"
}

# release.sh reached by pathname, with the entry gate satisfied exactly as the
# installed payload satisfies it, and CANDIDATE offered as the caller's TMPDIR.
run_release_pathname() {
  local candidate="$1"
  shift
  run env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" "TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3" \
    "TMPDIR=$candidate" "PATH=$PATH" \
    /bin/bash "$PAYLOAD/scripts/release.sh" "$@"
}

make_poisoned_project_runtime() {
  local hook
  PROJECT="$SANDBOX/projects/project with spaces"
  PROJECT_RUNTIME_MARKER="$SANDBOX/project-runtime-ran"
  mkdir -p \
    "$PROJECT/.trellis/runtime/core-rules/hooks" \
    "$PROJECT/.trellis/runtime/core-rules/codex/hooks"
  for hook in \
    "$PROJECT/.trellis/runtime/core-rules/hooks/session-context.sh" \
    "$PROJECT/.trellis/runtime/core-rules/codex/hooks/session-context.sh"; do
    cat > "$hook" <<EOF
#!/usr/bin/env bash
: > "$PROJECT_RUNTIME_MARKER"
exit 97
EOF
    chmod 755 "$hook"
  done
  printf '{"autonomy_default":1}\n' > "$PROJECT/.trellis/runtime/trellis.config.json"
  printf 'verified payload project context\n' > "$PROJECT/context-log.md"
}

run_session_context() {
  local harness="$1" project_root="$2" route="${3:-session-context}"
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    CLAUDE_PROJECT_DIR="$SANDBOX/incorrect claude project" \
    CODEX_PROJECT_DIR="$SANDBOX/incorrect codex project" \
    PROJECT_RUNTIME_MARKER="$PROJECT_RUNTIME_MARKER" \
    bash -c 'printf "%s\n" "{\"source\":\"startup\"}" | "$1" hook "$4" "$2" "$3"' \
    _ "$LAUNCHER" "$harness" "$project_root" "$route"
}

# The Codex SessionStart command exactly as it is written into a project's
# settings, with the render placeholders resolved. Reading it back out of the
# template is the point: a test that retypes the fallback chain proves only that
# two copies of a string agree, which is all the string assertions elsewhere in
# this file can prove.
render_codex_session_start_command() {
  render_session_start_command codex-hooks.local.json
}

render_session_start_command() {
  jq -r '.hooks.SessionStart[0].hooks[].command | select(contains(" hook session-start "))' \
    "$REPO_ROOT/core-rules/templates/$1" |
    sed -e "s#__TRELLIS_USER_HOME__#$HOME#g" \
      -e "s#__TRELLIS_HOME__#$TRELLIS_HOME#g" \
      -e "s#__TRELLIS_LAUNCHER__#$LAUNCHER#g"
}

# Run that command for real from directory $1, with the environment variables
# named in $2.. removed. Everything after the first argument is unset.
run_rendered_codex_session_start() {
  local cwd="$1" command
  shift
  command="$(render_codex_session_start_command)"
  run env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "${@}" \
    /bin/bash --noprofile --norc -c \
    "cd \"\$1\" || exit 1; printf '%s\n' '{\"source\":\"startup\"}' | { $command; }" \
    _ "$cwd"
}

make_dispatch_stub() {
  local name="$1"
  cat > "$DISPATCH_ROOT/$name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" > "$TRELLIS_TEST_ROUTE"
for argument in "$@"; do printf '<%s>\n' "$argument" >> "$TRELLIS_TEST_ROUTE"; done
exit "${TRELLIS_TEST_STATUS:-0}"
EOF
  chmod 755 "$DISPATCH_ROOT/$name"
}

prepare_dispatcher_fixture() {
  mkdir -p "$DISPATCH_ROOT"
  cp "$DISPATCHER_TEMPLATE" "$DISPATCH_ROOT/trellis"
  chmod 755 "$DISPATCH_ROOT/trellis"
  for script in configure.sh release.sh registry.sh show-config.sh attach-project.sh doctor.sh conformance-check.sh install-disk-janitor-launchd.sh materialize-scheduled-task.sh sync-to-template.sh worktree.sh; do
    make_dispatch_stub "$script"
  done
}
make_agent_socket_fixture() {
  # The isolated runner binds and closes this inert socket before fencing
  # network access. Keep aliases and negative controls in our own subtree.
  if [ -n "${TRELLIS_TEST_SOCKET_PATH:-}" ]; then
    [ -n "${TRELLIS_TEST_SOCKET_METADATA:-}" ] || return 1
    SOCKET_CANONICAL="$TRELLIS_TEST_SOCKET_PATH"
    [ -S "$SOCKET_CANONICAL" ] && [ ! -L "$SOCKET_CANONICAL" ] || return 1
    [ "${SOCKET_CANONICAL##*/}" = s ] || return 1
    SOCKET_FIXTURE="$BATS_TEST_TMPDIR/socket-fixture"
    SOCKET_REAL="$SOCKET_FIXTURE/r"
    SOCKET_ALIAS="$SOCKET_FIXTURE/a"
    mkdir -p "$SOCKET_REAL"
    ln -s "${SOCKET_CANONICAL%/*}" "$SOCKET_ALIAS"
    return
  fi
  # A real AF_UNIX socket: the resolver requires -S, so no plain file can stand
  # in.
  # Built inside the runner's own private temp root, resolved physically so the
  # fixture's path contributes no symlink of its own. A literal /tmp spelling
  # put it outside that boundary, which an isolated runner refuses outright, and
  # /private/tmp does not exist on Linux, which is where CI runs this.
  #
  # sun_path caps a bound socket at 104 bytes and the root is already deep:
  # scripts/run-tests.sh hands each shard a `trellis-test-git.XXXXXX` directory
  # under the ambient temp dir, which is 80 bytes on a stock macOS $TMPDIR. The
  # leaves are therefore spelled as tersely as the limit demands and named
  # through variables, so the cases below still read as real-versus-alias.
  local tmp_root
  tmp_root="$(CDPATH='' cd "${TMPDIR:-/tmp}" && pwd -P)"
  SOCKET_FIXTURE="$(mktemp -d "$tmp_root/s.XXXXXX")"
  SOCKET_REAL="$SOCKET_FIXTURE/r"
  SOCKET_ALIAS="$SOCKET_FIXTURE/a"
  SOCKET_CANONICAL="$SOCKET_REAL/s"
  mkdir -p "$SOCKET_REAL"
  /usr/bin/perl -MSocket -e '
    socket(my $sock, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    bind($sock, sockaddr_un($ARGV[0])) or die "bind: $!";
  ' "$SOCKET_CANONICAL"
  # The stock macOS spelling reaches the launchd socket through /var, a symlink
  # to /private/var, so an alias directory reproduces the real-world path.
  ln -s "$SOCKET_REAL" "$SOCKET_ALIAS"
}

resolve_ssh_auth_sock() {
  local resolver
  resolver="$(
    awk '/^launcher_absolute_path_is_clean\(\) \{/,/^\}/' "$LAUNCHER_TEMPLATE"
    awk '/^launcher_verified_ssh_auth_sock\(\) \{/,/^\}/' "$LAUNCHER_TEMPLATE"
  )"
  SSH_AUTH_SOCK="$1" /bin/bash --noprofile --norc -c "set -u
$resolver
launcher_verified_ssh_auth_sock"
}

@test "verified SSH_AUTH_SOCK resolves a socket reached through a symlinked directory" {
  local canonical
  make_agent_socket_fixture
  canonical="$SOCKET_CANONICAL"

  run resolve_ssh_auth_sock "$SOCKET_ALIAS/s"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$canonical" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$canonical"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$canonical" ] || { echo "$output"; false; }
}

@test "verified SSH_AUTH_SOCK refuses a symlinked socket, a non-socket, and an unclean path" {
  make_agent_socket_fixture
  ln -s "$SOCKET_CANONICAL" "$SOCKET_REAL/link.sock"
  : > "$SOCKET_REAL/plain"

  run resolve_ssh_auth_sock "$SOCKET_REAL/link.sock"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$SOCKET_REAL/plain"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$SOCKET_REAL/../r/s"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$SOCKET_REAL/missing.sock"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "copied launcher runs only active immutable payload with exact argv and status" {
  local expected expected_path="$PATH"
  make_release 1.2.3


  run_launcher attach --fleet "work fleet" ""
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  expected="$(printf '%s\n' 4 '<attach>' '<--fleet>' '<work fleet>' '<>')"
  [ "$(cat "$ARGV_LOG")" = "$expected" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]
  [ "$(cat "$ATTACH_PATH_LOG")" = "$expected_path" ]
  # Spec 055 R2.5: every operator route that can attach forwards the caller
  # PATH; any other route does not.
  for route in onboard worktree doctor; do
    rm -f "$ATTACH_PATH_LOG"
    run_launcher "$route"
    [ "$status" -eq 3 ] || { echo "$route: $output"; false; }
    [ "$(cat "$ATTACH_PATH_LOG")" = "$expected_path" ] || { echo "$route: $(cat "$ATTACH_PATH_LOG")"; false; }
  done
  rm -f "$ATTACH_PATH_LOG"
  run_launcher registry
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(cat "$ATTACH_PATH_LOG")" = __UNSET__ ]
  # The dispatcher intentionally exits 3 after the launcher has handed off its
  # sealed snapshot. No snapshot work may survive this error path either, not
  # only a successful payload exit.
  assert_no_execution_snapshot
}

@test "direct launcher bootstrap ignores BASH startup and exported function payloads" {
  local startup marker
  make_release 1.2.3
  startup="$SANDBOX/hostile-startup"
  marker="$SANDBOX/hostile-startup-ran"
  cat > "$startup" <<EOF
/usr/bin/touch "$marker"
EOF

  run /usr/bin/env -i \
    "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOSTILE_MARKER=$marker" \
    /bin/bash --noprofile --norc -c '
      umask() {
        /usr/bin/touch "$HOSTILE_MARKER"
        builtin umask "$@"
      }
      export -f umask
      BASH_ENV="$2"
      ENV="$2"
      export BASH_ENV ENV
      exec "$1" doctor
    ' trellis-launcher-hostile "$LAUNCHER" "$startup"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ ! -e "$marker" ]
}

# Extract the actual clean -c program, not a hand-written bootstrap facsimile.
launcher_clean_prologue() {
  awk '
    /^  \/bin\/bash --noprofile --norc -c / { body = 1; next }
    /^\047 trellis-launcher-bootstrap / { exit }
    body { print }
  ' "$LAUNCHER_TEMPLATE"
}

@test "launcher bootstrap preserves ordinary and hook stdin" {
  make_release 1.2.3 stdin
  local route
  for route in doctor hook; do
    run /bin/bash -c '
      printf "%s\n" "caller stdin: spaces and backslash \\" |
        "$1" "$2" "${@:3}"
    ' _ "$LAUNCHER" "$route" inject-primer-index claude "$SANDBOX/projects"
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    [ "$output" = 'caller stdin: spaces and backslash \' ]
    assert_no_execution_snapshot
  done
}

@test "launcher bootstrap rejects missing marker and empty body with status 5" {
  local variant
  for variant in missing empty; do
    awk '/^# -- trellis launcher body --$/ { exit } { print }' "$LAUNCHER_TEMPLATE" > "$LAUNCHER"
    if [ "$variant" = empty ]; then
      printf '%s\n' '# -- trellis launcher body --' >> "$LAUNCHER"
    fi
    run_launcher doctor
    [ "$status" -eq 5 ] || { echo "$output"; false; }
    [[ "$output" == *'trellis: could not prepare trusted launcher bootstrap'* ]] || false
    [ ! -e "$ARGV_LOG" ]
  done
}

@test "launcher bootstrap source read failure is checked before evaluation" {
  local prologue
  prologue="$(launcher_clean_prologue)"
  [ -n "$prologue" ]
  run /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash --noprofile --norc -c "$prologue" trellis-launcher-bootstrap "$SANDBOX/missing-source" doctor
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *'awk:'* ]] || false
  [[ "$output" == *'trellis: could not prepare trusted launcher bootstrap'* ]] || false
  [ ! -e "$ARGV_LOG" ]
}

@test "launcher bootstrap executes a valid body larger than ARG_MAX without argv transport" {
  make_release 1.2.3
  python3 - "$LAUNCHER" <<'PY'
import os
from pathlib import Path
import sys
path = Path(sys.argv[1])
with path.open("a") as stream:
    stream.write("\n# padding\n" * (os.sysconf("SC_ARG_MAX") // 10 + 1))
PY
  run_launcher attach --fleet "work fleet" ""
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(cat "$ARGV_LOG")" = "$(printf '%s\n' 4 '<attach>' '<--fleet>' '<work fleet>' '<>')" ]
  assert_no_execution_snapshot
}

@test "launcher bootstrap final eval preserves options umask EXIT trap and body status" {
  local prologue
  prologue="$(launcher_clean_prologue)"
  [ "${prologue##*$'\n'}" = 'eval "$launcher_body"' ]
  cat > "$SANDBOX/probe-source" <<'EOF'
# -- trellis launcher body --
case "$-" in *u*) ;; *) exit 91 ;; esac
case "$-" in *e*|*x*|*v*) exit 92 ;; esac
[ "$(umask)" = 0077 ] || exit 93
shopt -q nullglob && exit 94
[ "$(set -o | awk '$1 == "pipefail" { print $2 }')" = off ] || exit 95
trap 'printf "exit-status=%s\n" "$?"' EXIT
false
printf 'argc=%s first=<%s> second=<%s>\n' "$#" "$1" "$2"
(exit 42)
EOF
  run /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash --noprofile --norc -c "$prologue" trellis-launcher-bootstrap "$SANDBOX/probe-source" 'with space' ''
  [ "$status" -eq 42 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' 'argc=2 first=<with space> second=<>' 'exit-status=42')" ]
}

@test "session-start and session-context routes run verified data hooks and never poisoned project runtime" {
  local harness route
  make_release 1.2.3 session-context
  make_poisoned_project_runtime

  for route in session-start session-context; do
    for harness in claude codex; do
      rm -f "$PROJECT_RUNTIME_MARKER"
      run_session_context "$harness" "$PROJECT" "$route"

      [ "$status" -eq 0 ] || { echo "$route $harness: $output"; false; }
      [[ "$output" == *"verified payload project context"* ]] || { echo "$route $harness: $output"; false; }
      [[ "$output" == *"Level: L4"* ]] || { echo "$route $harness: $output"; false; }
      [ ! -e "$PROJECT_RUNTIME_MARKER" ]
    done
  done
}

# Review HIGH-2: the project's runtime anchor is data to diagnose. A dispatcher
# planted in a replaced runtime directory, or behind a retargeted runtime
# symlink, never runs; the verified payload's dispatcher does, under the
# attach-time HOME and TRELLIS_HOME whatever the caller's environment holds.
@test "the rendered SessionStart command never executes a replaced or retargeted project runtime" {
  local name harness_dir command layout hook
  make_release 1.2.3 session-context
  make_poisoned_project_runtime
  mkdir -p "$SANDBOX/poison tree/core-rules/hooks" "$SANDBOX/poison tree/core-rules/codex/hooks"
  for hook in core-rules/hooks/session-start.sh core-rules/codex/hooks/session-start.sh; do
    for layout in "$PROJECT/.trellis/runtime" "$SANDBOX/poison tree"; do
      printf '#!/usr/bin/env bash\n: > %q\nexit 97\n' "$PROJECT_RUNTIME_MARKER" > "$layout/$hook"
      chmod 755 "$layout/$hook"
    done
  done
  for layout in replaced retargeted; do
    if [ "$layout" = retargeted ]; then
      rm -rf "$PROJECT/.trellis/runtime"
      ln -s "$SANDBOX/poison tree" "$PROJECT/.trellis/runtime"
    fi
    for name in claude-settings.local.json codex-hooks.local.json; do
      rm -f "$PROJECT_RUNTIME_MARKER"
      command="$(render_session_start_command "$name")"
      run env -i HOME="$SANDBOX/hostile home" TRELLIS_HOME="$SANDBOX/hostile trellis home" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin BASH_ENV="$SANDBOX/hostile-bash-env" \
        CLAUDE_PROJECT_DIR="$PROJECT" CODEX_PROJECT_DIR="$PROJECT" \
        /bin/bash --noprofile --norc -c "printf '%s\n' '{\"source\":\"startup\"}' | { $command; }"
      [ "$status" -eq 0 ] || { echo "$layout $name: $output"; false; }
      [[ "$output" == *"verified payload project context"* ]] || { echo "$layout $name: $output"; false; }
      [ ! -e "$PROJECT_RUNTIME_MARKER" ] || { echo "$layout $name executed the project runtime"; false; }
    done
  done
}

# Every other assertion about the fallback chain is a string match on the
# template or the rendered JSON, so all of them would still pass if the chain
# resolved nothing at runtime. These execute it. The fixture project's path
# contains a space, which is where an unquoted expansion would come apart.
@test "the Codex SessionStart fallback chain resolves a project dir at runtime" {
  make_release 1.2.3 session-context
  make_poisoned_project_runtime

  # 1. CODEX_PROJECT_DIR wins when Codex sets it.
  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$SANDBOX" \
    "CODEX_PROJECT_DIR=$PROJECT" "CLAUDE_PROJECT_DIR=$SANDBOX/projects/wrong"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }

  # 2. CLAUDE_PROJECT_DIR is the next leg when Codex does not set its own.
  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$SANDBOX" "CLAUDE_PROJECT_DIR=$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }

  # 3. With neither set, `$PWD` is the last resort. Before the chain landed this
  #    passed an empty string and the hook exited 2 on a non-absolute path.
  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }

  # The project's own runtime is never the thing that ran, in any of the three.
  [ ! -e "$PROJECT_RUNTIME_MARKER" ]
}

# `$PWD` is where the session started, which for a Codex session is routinely a
# subdirectory rather than the project root — and `context-log.md` and
# `.claude/primers/INDEX.md` both live at the root, so the hooks would find
# nothing and inject nothing without ever saying so.
@test "a SessionStart project dir inside a project resolves to the attachment root" {
  make_release 1.2.3 session-context
  make_poisoned_project_runtime
  mkdir -p "$PROJECT/src/deep"

  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$PROJECT/src/deep"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }
  [ ! -e "$PROJECT_RUNTIME_MARKER" ]
}

# ...and a directory under no attachment at all still resolves to itself, so an
# unattached clone behaves exactly as it did before the walk existed.
@test "a SessionStart project dir under no attachment resolves to itself" {
  make_release 1.2.3 session-context
  make_poisoned_project_runtime
  mkdir -p "$SANDBOX/projects/unattached"

  run_session_context codex "$SANDBOX/projects/unattached"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"verified payload project context"* ]] || { echo "$output"; false; }
}

@test "SessionStart routes reject malformed paths and report missing absolute projects as unavailable" {
  make_release 1.2.3 session-context
  mkdir -p "$SANDBOX/projects/valid"

  run /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$LAUNCHER" hook session-context claude "$SANDBOX/projects/valid"
  [ "$status" -eq 2 ]
  [[ "$output" == *'TRELLIS_HOME is required for SessionStart hook routes'* ]] || { echo "$output"; false; }

  run_session_context claude relative-project
  [ "$status" -eq 2 ]
  [[ "$output" == *'PROJECT_ROOT must be an absolute canonical directory'* ]] || { echo "$output"; false; }

  run_session_context codex "$SANDBOX/projects/missing"
  [ "$status" -eq 5 ]
  [[ "$output" == *'PROJECT_ROOT is unavailable'* ]] || { echo "$output"; false; }
}

@test "SessionStart runs a non-context hook from the verified payload without project runtime" {
  make_release 1.2.3 session-primer
  mkdir -p "$SANDBOX/projects/valid"

  run_launcher hook inject-primer-index claude "$SANDBOX/projects/valid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The executed payload is a sealed execution snapshot of the configured
  # release, never the installed release directory itself. This fixture does
  # not declare the exec-snapshot capability, so like a release before 1.4.0
  # it runs from a per-run snapshot, removed again on the way out.
  [[ "$output" == *"trusted-primer:$SANDBOX/projects/valid:$TRELLIS_HOME/releases/.tmp.1.2.3.exec."*"/payload "* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"trusted-primer:$SANDBOX/projects/valid:$PAYLOAD "* ]] ||
    { echo "$output"; false; }
  assert_no_execution_snapshot
  [ ! -e "$TRELLIS_HOME/releases/.exec" ]
}

# Projects rendered by 1.3.11 and earlier still register skill-size-preflight.
# The active dispatcher answers that retired route with a silent no-op so a
# project left on an older release does not fail every session.
@test "SessionStart answers the retired skill-size-preflight route with a silent no-op" {
  make_release 1.2.3 session-primer
  mkdir -p "$SANDBOX/projects/valid"

  run_launcher hook skill-size-preflight claude "$SANDBOX/projects/valid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/projects/valid/preflight-ran" ]
  assert_no_execution_snapshot

  run_launcher hook skill-size-preflight codex "$SANDBOX/projects/valid"
  [ "$status" -eq 2 ]
  [[ "$output" == *'unsupported SessionStart hook route: codex/skill-size-preflight'* ]] || { echo "$output"; false; }

  run_launcher hook truncation-check claude "$SANDBOX/projects/valid"
  [ "$status" -eq 2 ]
  [[ "$output" == *'unsupported SessionStart hook route: claude/truncation-check'* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/projects/valid/preflight-ran" ]
}

@test "SessionStart drops inherited Git execution controls before the verified hook" {
  make_release 1.2.3 session-primer
  mkdir -p "$SANDBOX/projects/valid"

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    GIT_DIR="$SANDBOX/poisoned-git" GIT_WORK_TREE="$SANDBOX/poisoned-worktree" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=true \
    "$LAUNCHER" hook inject-primer-index claude "$SANDBOX/projects/valid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'git-dir=unset git-work-tree=unset fsmonitor=false hooks=/dev/null no-system=1 global=/dev/null'* ]] || { echo "$output"; false; }
}
@test "SessionStart templates route the one session-start dispatcher through the clean stable launcher" {
  local expected
  run jq -r '[.hooks.SessionStart[].hooks[].command] | if length == 1 then .[0] else error("not one command") end' \
    "$REPO_ROOT/core-rules/templates/claude-settings.local.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected='/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook session-start claude "$CLAUDE_PROJECT_DIR"'
  [ "$output" = "$expected" ] || { echo "actual:   $output"; echo "expected: $expected"; false; }

  # Claude Code always sets CLAUDE_PROJECT_DIR, but Codex does not reliably set
  # CODEX_PROJECT_DIR, so every Codex surface resolves the project through the
  # documented ${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}} chain.
  run jq -r '[.hooks.SessionStart[].hooks[].command] | if length == 1 then .[0] else error("not one command") end' \
    "$REPO_ROOT/core-rules/templates/codex-hooks.local.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected='/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook session-start codex "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"'
  [ "$output" = "$expected" ] || { echo "actual:   $output"; echo "expected: $expected"; false; }
}

@test "clean home allows only fixed launcher initial active release install" {
  local remote="$SANDBOX/bootstrap-release-remote"
  make_bootstrap_release_remote 1.2.3 "$remote"
  write_config 1.2.3 "$remote"

  run_launcher doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 'trellis release install 1.2.3 [--remote URL]' is available"* ]] || { echo "$output"; false; }

  run_launcher release install 1.2.3 --remote "$remote"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME/releases/1.2.3/payload" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "launcher has no latest fallback when active release is absent" {
  make_release 9.9.9

  run_launcher doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 'trellis release install 1.2.3 [--remote URL]' is available"* ]] || { echo "$output"; false; }
  [ ! -e "$ARGV_LOG" ]
}

@test "launcher refuses corrupt missing symlinked and writable release state" {
  make_release 1.2.3
  chmod 755 "$TRELLIS_HOME"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"Trellis home is missing, not private, or not a real directory"* ]] || { echo "$output"; false; }
  chmod 700 "$TRELLIS_HOME"

  chmod u+w "$RELEASE_DIR/release.json"
  printf '{invalid}\n' > "$RELEASE_DIR/release.json"
  chmod a-w "$RELEASE_DIR/release.json"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing, writable, or invalid"* ]] || { echo "$output"; false; }

  # A release store with no configured release is not corrupt state: it is the
  # pre-active condition, and the launcher's only pre-active route reports it.
  find "$TRELLIS_HOME/releases/1.2.3" -depth -type d -exec chmod u+w {} +
  rm -rf "$TRELLIS_HOME/releases/1.2.3"
  run_launcher doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 'trellis release install 1.2.3 [--remote URL]' is available"* ]] ||
    { echo "$output"; false; }

  make_release 1.2.3
  chmod u+w "$RELEASE_DIR"
  mv "$RELEASE_DIR" "$RELEASE_DIR.real"
  ln -s "$RELEASE_DIR.real" "$RELEASE_DIR"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"configured release is not a real directory"* ]] || { echo "$output"; false; }

  rm "$RELEASE_DIR"
  mv "$RELEASE_DIR.real" "$RELEASE_DIR"
  chmod u+w "$PAYLOAD/scripts/trellis"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"configured release directory is writable"* ]] || { echo "$output"; false; }
}

@test "launcher runs upgrade as a verified in-memory bundle without a release pathname" {
  make_release 1.2.3 command-bundle

  run_launcher upgrade
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  # The upgrade body only reaches argument validation when it ran from the
  # bundle: the sealed-snapshot pathname route rejects the snapshot payload as
  # direct source execution instead.
  [[ "$output" == *'VERSION is required'* ]] || { echo "$output"; false; }
  [[ "$output" == *'trellis upgrade VERSION'* ]] || { echo "$output"; false; }
  [[ "$output" != *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]

  run_launcher upgrade 9.9.9 --all --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'upgrade accepts one selector'* ]] || { echo "$output"; false; }
}

@test "launcher upgrade composes the real release and upgrade bodies against a fixture home" {
  local remote="$SANDBOX/upgrade-release-remote"
  make_release 1.2.3 command-bundle
  make_bootstrap_release_remote 1.2.4 "$remote"

  # No stub on either half: the bundle carries the payload's real release body
  # as a preloaded command surface and its real upgrade body on top of it.
  run_launcher upgrade 1.2.4 --remote "$remote" --all

  # install and verify are observed by their effects on the release store.
  [ -d "$TRELLIS_HOME/releases/1.2.4/payload" ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/releases/1.2.4/release.json" ]
  [ ! -w "$TRELLIS_HOME/releases/1.2.4/release.json" ]
  [[ "$output" == *"$TRELLIS_HOME/releases/1.2.4"* ]] || { echo "$output"; false; }
  # verify is silent on success and fatal on failure, so the adoption line
  # below is also the proof that verification of the new payload passed.
  [[ "$output" == *"no registered worktrees matched the requested adoption selector"* ]] ||
    { echo "$output"; false; }
  # The fixture home has no registered worktrees, so the real adoption step
  # ends unavailable rather than silently succeeding.
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]
  assert_no_execution_snapshot
}

@test "launcher refuses an installed payload whose upgrade command predates bundle execution" {
  make_release 1.2.3 command-bundle-pre-bundle-upgrade

  run_launcher upgrade 1.2.4 --all
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'installed release 1.2.3 cannot run '"'"'trellis upgrade'"'"' as a verified in-memory bundle'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'predates the verified command-bundle attestation'* ]] || { echo "$output"; false; }
  [[ "$output" == *'trellis release install VERSION [--remote URL]'* ]] || { echo "$output"; false; }
  [[ "$output" != *'legacy upgrade body ran'* ]] || { echo "$output"; false; }
  [[ "$output" != *'legacy upgrade wrapper ran'* ]] || { echo "$output"; false; }

  write_config 1.2.5
  make_release 1.2.5 command-bundle-unmarked-upgrade

  run_launcher upgrade 1.2.6 --all
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'installed release 1.2.5 cannot run '"'"'trellis upgrade'"'"' as a verified in-memory bundle'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'carries no command-body marker'* ]] || { echo "$output"; false; }
  [[ "$output" != *'legacy upgrade wrapper ran'* ]] || { echo "$output"; false; }
}

@test "launcher upgrade refuses a payload upgrade source that drifts from its record" {
  make_release 1.2.3 command-bundle

  chmod u+w "$PAYLOAD/scripts" "$PAYLOAD/scripts/upgrade.sh"
  # Exactly one byte, rewritten in place: same size, same mode, different bytes.
  printf 'x' | dd of="$PAYLOAD/scripts/upgrade.sh" bs=1 seek=3 conv=notrunc status=none
  chmod a-w "$PAYLOAD/scripts/upgrade.sh" "$PAYLOAD/scripts"

  run_launcher upgrade 1.2.4 --all
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  # The refusal comes from the launcher's own content verification, which runs
  # before any snapshot is taken and before any bundle is emitted, and it names
  # the drifted path. (The bundle emitter re-checks the same path against the
  # pinned record when it buffers the snapshot; that second check only ever
  # fires on drift introduced after this one passed, so it is unreachable from
  # a test that mutates the payload up front.)
  [[ "$output" == *'configured release content has changed: scripts/upgrade.sh'* ]] ||
    { echo "$output"; false; }
  # Nothing downstream ran: no upgrade body reached argument validation.
  [[ "$output" != *'VERSION is required'* ]] || { echo "$output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]
  assert_no_execution_snapshot
}

@test "launcher derives a private command scratch and hands it to the ordinary payload child" {
  local observed
  make_release 1.2.3 scratch-probe
  printf 'write\n' > "$SANDBOX/scratch-probe-mode"

  run_launcher_with_tmpdir "/hostile ambient tmp" doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  case "$observed" in
    "$TRELLIS_HOME/state/scratch/.cmd."*) ;;
    *) echo "observed TMPDIR: $observed"; false ;;
  esac
  [ "$(cat "$SANDBOX/scratch-mode.log")" = 'drwx------' ] ||
    { echo "scratch mode: $(cat "$SANDBOX/scratch-mode.log")"; false; }
  # The permission field only: macOS appends `@` for extended attributes, which
  # the launcher's own private-directory check also ignores (it refuses an ACL
  # from the -e entry listing and reads exactly the ten mode characters).
  [ "$(LC_ALL=C ls -ld "$TRELLIS_HOME/state" | awk '{print substr($1, 1, 10)}')" = 'drwx------' ]
  [ "$(LC_ALL=C ls -ld "$TRELLIS_HOME/state/scratch" | awk '{print substr($1, 1, 10)}')" = 'drwx------' ]
  # A real command temp file allocated through ${TMPDIR:-/tmp}: the hostile
  # ambient value never reached the child, and the derived one is writable.
  case "$(cat "$SANDBOX/scratch-mktemp.log")" in
    "$observed"/probe.??????) ;;
    *) echo "mktemp landed outside the derived scratch: $(cat "$SANDBOX/scratch-mktemp.log")"; false ;;
  esac
  [ ! -e "$observed" ] || { echo "command scratch survived: $observed"; false; }
  assert_no_command_scratch
  assert_no_execution_snapshot
}

@test "command scratch preserves a Trellis home spelled with spaces" {
  local spaced observed
  spaced="$SANDBOX/trellis home with spaces"
  mv "$TRELLIS_HOME" "$spaced"
  export TRELLIS_HOME="$spaced"
  make_release 1.2.3 scratch-probe

  run_launcher_with_tmpdir /tmp doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  case "$observed" in
    "$spaced/state/scratch/.cmd."*) ;;
    *) echo "observed TMPDIR: $observed"; false ;;
  esac
  assert_no_command_scratch
}

@test "command scratch is removed after a nonzero payload exit without changing the status" {
  make_release 1.2.3 scratch-probe
  printf '7\n' > "$SANDBOX/scratch-probe-status"

  run_launcher doctor
  [ "$status" -eq 7 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$(cat "$SANDBOX/scratch-tmpdir.log")" ]
  assert_no_command_scratch
}

@test "the existing TERM trap cleans the command scratch and keeps its 143 status" {
  make_release 1.2.3 scratch-probe
  # The payload signals its own launcher and returns: the trap is exercised
  # exactly as a real TERM exercises it, with no sleep and no polling. The
  # alarm is a hard ceiling on a hang, not the mechanism under test.
  printf 'term\n' > "$SANDBOX/scratch-probe-mode"

  run /usr/bin/perl -e 'alarm 60; exec @ARGV or die "exec: $!"' \
    env "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" "$LAUNCHER" doctor
  [ "$status" -eq 143 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$(cat "$SANDBOX/scratch-tmpdir.log")" ]
  assert_no_command_scratch
}

@test "command scratch cleanup refuses a replaced directory and preserves it and its neighbours" {
  local replaced
  make_release 1.2.3 scratch-probe
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'neighbour bytes\n' > "$TRELLIS_HOME/state/scratch/neighbour"

  printf 'replace-directory\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'could not clean command scratch directory'* ]] || { echo "$output"; false; }
  replaced="$(cat "$SANDBOX/scratch-tmpdir.log")"
  [ -d "$replaced" ] && [ ! -L "$replaced" ]
  [ "$(cat "$replaced/replacement")" = replacement ]
  [ "$(cat "$TRELLIS_HOME/state/scratch/neighbour")" = 'neighbour bytes' ]
}

@test "command scratch cleanup refuses a replaced parent and preserves both directory trees" {
  local observed retained expected
  make_release 1.2.3 scratch-probe

  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$(cat "$SANDBOX/scratch-tmpdir.log")" ]
  assert_no_command_scratch
  assert_no_execution_snapshot
  printf 'original neighbour bytes\n' > "$TRELLIS_HOME/state/scratch/neighbour"

  printf 'replace-parent\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  retained="$TRELLIS_HOME/state/scratch-retained/${observed##*/}"
  expected="$(printf '%s\n' \
    'trellis: the command scratch root changed since it was recorded' \
    "trellis: could not clean command scratch directory: $observed")"
  [ "$output" = "$expected" ] || { echo "parent-identity refusal mismatch: $output"; false; }
  [ -d "$observed" ] && [ ! -L "$observed" ]
  [ -d "$retained" ] && [ ! -L "$retained" ]
  printf 'replacement scratch bytes\n' | cmp - "$observed/replacement"
  printf 'replacement neighbour bytes\n' | cmp - "$TRELLIS_HOME/state/scratch/neighbour"
  printf 'original scratch bytes\n' | cmp - "$retained/original"
  printf 'original neighbour bytes\n' | cmp - "$TRELLIS_HOME/state/scratch-retained/neighbour"
  assert_no_execution_snapshot
}

# Extract the actual helper boundaries without sourcing the launcher entrypoint.
# The emitted Python is executed unchanged, including its imports and arguments.
prepare_command_scratch_helpers() {
  python3 -I -c '
import pathlib, re, subprocess, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
functions = re.findall(r"^launcher_(?:command_scratch_[a-z_]+|derive_command_scratch|remove_command_scratch|absolute_path_is_clean|error)\(\) \{\n.*?^\}", source, re.M | re.S)
assert len(functions) >= 6
library = out / "scratch-helpers.sh"
library.write_text("TRELLIS_EX_USAGE=2\nTRELLIS_EX_STATE=4\nTRELLIS_EX_UNAVAILABLE=5\n" + "\n".join(functions))
for mode in ("create", "remove"):
    result = subprocess.run(["/bin/bash", "-c", "source \"$1\"; launcher_command_scratch_" + mode + "_program", "bash", str(library)], capture_output=True, text=True, check=True)
    (out / (mode + ".py")).write_text(result.stdout)
' "$LAUNCHER_TEMPLATE" "$SANDBOX"
}

@test "command scratch repair refuses a completed state ancestor alias before cleanup" {
  local observed retained
  make_release 1.2.3 scratch-probe
  printf 'replace-state-alias\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "repair mismatch: alias cleanup status=$status $output"; false; }
  [[ "$output" == *'without following links'* ]] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  retained="$TRELLIS_HOME/state.saved/scratch/${observed##*/}"
  [ -L "$TRELLIS_HOME/state" ] && [ -d "$retained" ]
  printf 'original scratch bytes\n' | cmp - "$retained/original"
  printf 'state sentinel bytes\n' | cmp - "$TRELLIS_HOME/state.saved/sentinel"
  printf 'neighbour bytes\n' | cmp - "$TRELLIS_HOME/state.saved/scratch/neighbour"
  assert_no_execution_snapshot
}

@test "command scratch repair refuses ancestor aliases when opening the canonical home" {
  prepare_command_scratch_helpers
  mkdir -m 700 "$SANDBOX/entry" "$SANDBOX/entry/home"
  run python3 -I "$SANDBOX/create.py" "$SANDBOX/entry/home"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mv "$SANDBOX/entry" "$SANDBOX/entry.saved"
  ln -s entry.saved "$SANDBOX/entry"
  printf 'sentinel\n' > "$SANDBOX/entry.saved/sentinel"
  run python3 -I "$SANDBOX/create.py" "$SANDBOX/entry/home"
  [ "$status" -eq 4 ] || { echo "repair mismatch: home alias status=$status $output"; false; }
  [[ "$output" == *'without following links'* ]] || { echo "$output"; false; }
  printf 'sentinel\n' | cmp - "$SANDBOX/entry.saved/sentinel"
  [ -L "$SANDBOX/entry" ]
}

@test "command scratch repair rejects real Darwin ACLs on home state root and new child" {
  [ "$(uname -s)" = Darwin ] || skip "native Darwin ACL fixture"
  prepare_command_scratch_helpers
  run python3 -I -c '
import os, pathlib, stat, subprocess, sys
base = pathlib.Path(sys.argv[1])
program = (base / "create.py").read_text()
failures = []
for label in ("home", "state", "root", "child"):
    home = base / ("acl-" + label)
    root = home / "state" / "scratch"
    root.mkdir(parents=True)
    for p in (home, home / "state", root):
        p.chmod(0o700)
    target = {"home": home, "state": home / "state", "root": root}.get(label)
    if target:
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,search,directory_inherit", str(target)], check=True)
        assert stat.S_IMODE(target.stat().st_mode) == 0o700
        before = subprocess.run(["/bin/ls", "-lde", str(target)], capture_output=True, text=True, check=True).stdout
        assert "allow" in before
        code = program
    else:
        # Install a real ACL immediately after mkdir of the new command child,
        # before the production no-follow open/private check, not on a decoy path.
        code = """import os, subprocess, sys
real_mkdir = os.mkdir
def mkdir(name, mode=0o777, *, dir_fd=None):
    real_mkdir(name, mode, dir_fd=dir_fd)
    if str(name).startswith(".cmd."):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,search,directory_inherit", sys.argv[1] + "/state/scratch/" + name], check=True)
os.mkdir = mkdir
""" + program
    result = subprocess.run([sys.executable, "-I", "-c", code, str(home)], capture_output=True, text=True)
    print(label, result.returncode, result.stderr, flush=True)
    if result.returncode != 4 or "has an ACL" not in result.stderr:
        failures.append(label)
    if target:
        after = subprocess.run(["/bin/ls", "-lde", str(target)], capture_output=True, text=True, check=True).stdout
        assert before.splitlines()[1:] == after.splitlines()[1:], (label, "ACL was repaired")
        assert stat.S_IMODE(target.stat().st_mode) == 0o700, (label, "mode was repaired")
assert not failures, "repair mismatch: ACL accepted at " + repr(failures)
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch repair rejects malformed identities at wrapper and embedded boundaries" {
  prepare_command_scratch_helpers
  run python3 -I -c '
import pathlib, subprocess, sys
base = pathlib.Path(sys.argv[1])
home = base / "identity-home"
home.mkdir(mode=0o700)
created = subprocess.run([sys.executable, "-I", str(base / "create.py"), str(home)], capture_output=True, text=True, check=True)
name, child_id, root_id = created.stdout.strip().split("\t")
root = str(home / "state" / "scratch")
wrapper = ["/bin/bash", "-c", "source \"$1\"; shift; launcher_remove_command_scratch \"$@\"", "bash", str(base / "scratch-helpers.sh")]
embedded = [sys.executable, "-I", str(base / "remove.py")]
for command in (wrapper, embedded):
    # Both real removal and well-formed missing-child idempotence must work.
    subprocess.run(command + [root, name, child_id, root_id], check=True)
failures = []
for label, command in (("wrapper", wrapper), ("embedded", embedded)):
    for bad in (":", "1::2", "123", "", "1:", ":2", "١:2", "1:2\n", "-1:2"):
        for position in (2, 3):
            args = [root, name, child_id, root_id]
            args[position] = bad
            result = subprocess.run(command + args, capture_output=True, text=True)
            if result.returncode != 2:
                failures.append((label, bad, position, result.returncode))
assert not failures, "repair mismatch: malformed cleanup identities " + repr(failures)
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch distinguishes Darwin ACL inspection errors from absent ACLs" {
  [ "$(uname -s)" = Darwin ] || skip "native Darwin ACL API"
  prepare_command_scratch_helpers
  run python3 -I -c '
import errno, pathlib, subprocess, sys
base = pathlib.Path(sys.argv[1])
home = base / "acl-error-home"
home.mkdir(mode=0o700)
program = (base / "create.py").read_text()
for error in (errno.EBADF, errno.EACCES, errno.EIO, errno.ENOTSUP):
    prefix = """import ctypes
native_cdll = ctypes.CDLL
def load(*args, **kwargs):
    library = native_cdll(*args, **kwargs)
    def get_acl(fd, kind):
        ctypes.set_errno(%d)
        return None
    library.acl_get_fd_np = get_acl
    return library
ctypes.CDLL = load
""" % error
    result = subprocess.run([sys.executable, "-I", "-c", prefix + program, str(home)], capture_output=True, text=True)
    assert result.returncode == 5 and "could not inspect ACL" in result.stderr, (error, result)
    assert not (home / "state").exists()
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch rejects malformed producer identities before publishing its globals" {
  prepare_command_scratch_helpers
  run python3 -I -c '
import pathlib, subprocess, sys
base = pathlib.Path(sys.argv[1])
command = ["/bin/bash", "-c", "source \"$1\"; program=$2; launcher_command_scratch_create_program() { printf %s \"$program\"; }; launcher_derive_command_scratch \"$3\"", "bash", str(base / "scratch-helpers.sh")]
for bad in (":", "1::2", "123", "", "١:2"):
    for identities in ((bad, "1:2"), ("1:2", bad)):
        record = ".cmd.a\t" + "\t".join(identities)
        result = subprocess.run(command + ["print(" + repr(record) + ")", str(base)], capture_output=True, text=True)
        assert result.returncode == 4, (identities, result)
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch allows existing nonwritable ancestors when allocation locations are writable" {
  make_release 1.2.3 scratch-probe
  mkdir -p "$TRELLIS_HOME/state/scratch"
  chmod 500 "$TRELLIS_HOME/state"
  chmod 700 "$TRELLIS_HOME/state/scratch"
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_no_command_scratch
}

@test "command scratch cleanup unlinks a child symlink without following it and refuses a symlinked scratch" {
  local observed
  make_release 1.2.3 scratch-probe
  printf 'target bytes\n' > "$SANDBOX/neighbour-target"

  printf 'child-symlink\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  [ ! -e "$observed" ] && [ ! -L "$observed" ]
  [ "$(cat "$SANDBOX/neighbour-target")" = 'target bytes' ]
  assert_no_command_scratch

  printf 'replace-symlink\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'could not clean command scratch directory'* ]] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  [ -L "$observed" ] || { echo "replacement symlink was removed: $observed"; false; }
  [ "$(cat "$SANDBOX/neighbour-target")" = 'target bytes' ]
}

@test "command scratch derivation refuses symlinked, non-private, and unwritable state parents" {
  make_release 1.2.3 scratch-probe
  mkdir -p "$SANDBOX/outside-state"
  ln -s "$SANDBOX/outside-state" "$TRELLIS_HOME/state"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'command scratch'* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }
  rm "$TRELLIS_HOME/state"

  mkdir -p "$TRELLIS_HOME/state/scratch"
  chmod 700 "$TRELLIS_HOME/state"
  chmod 755 "$TRELLIS_HOME/state/scratch"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }

  chmod 500 "$TRELLIS_HOME/state/scratch"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }

  rmdir "$TRELLIS_HOME/state/scratch"
  chmod 500 "$TRELLIS_HOME/state"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }

  # Positive control: the same home derives and removes a scratch once its
  # state parents are private and writable again.
  chmod 700 "$TRELLIS_HOME/state"
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  case "$(cat "$SANDBOX/scratch-tmpdir.log")" in
    "$TRELLIS_HOME/state/scratch/.cmd."*) ;;
    *) echo "observed TMPDIR: $(cat "$SANDBOX/scratch-tmpdir.log")"; false ;;
  esac
  assert_no_command_scratch
}

@test "the verified command bundle child receives and admits the derived command scratch" {
  local observed admitted git_tmpdir
  make_release 1.2.3 command-bundle-scratch

  run_launcher_with_tmpdir "/hostile ambient tmp" upgrade
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"bundle-tmpdir=$TRELLIS_HOME/state/scratch/.cmd."* ]] || { echo "$output"; false; }
  [[ "$output" == *"bundle-admitted=$TRELLIS_HOME/state/scratch/.cmd."* ]] || { echo "$output"; false; }
  [[ "$output" != *'scratch upgrade wrapper ran'* ]] || { echo "$output"; false; }
  observed="$(printf '%s\n' "$output" | sed -n 's/^bundle-tmpdir=//p')"
  admitted="$(printf '%s\n' "$output" | sed -n 's/^bundle-admitted=//p')"
  git_tmpdir="$(printf '%s\n' "$output" | sed -n 's/^git-tmpdir=//p')"
  [ "$admitted" = "$observed" ] || { echo "$output"; false; }
  [ "$git_tmpdir" = "$observed" ] || { echo "Git TMPDIR mismatch: $output"; false; }
  assert_no_command_scratch
}

@test "the verified command bundle carries the payload's release verifier bytes" {
  make_release 1.2.3 command-bundle-verifier
  run_launcher upgrade
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"bundled-verifier=match"* ]] || { echo "$output"; false; }
  [[ "$output" == *"verify=0"* ]] || { echo "$output"; false; }
}

@test "a release without release_verify.py gets no bundled verifier and still verifies" {
  make_release 1.2.3 command-bundle-verifier-absent
  run_launcher upgrade
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"bundled-verifier=unset"* ]] || { echo "$output"; false; }
  [[ "$output" == *"verify=0"* ]] || { echo "$output"; false; }
}

@test "release pathname execution admits only a private Trellis command scratch candidate" {
  local scratch hostile
  make_release 1.2.3 command-bundle
  mkdir -p "$TRELLIS_HOME/state/scratch"
  chmod 700 "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/scratch"
  scratch="$TRELLIS_HOME/state/scratch/.cmd.fixture"
  mkdir -m 700 "$scratch"

  run_release_pathname "$scratch" adopt 1.2.3 --all
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'no registered worktrees matched the requested adoption selector'* ]] ||
    { echo "$output"; false; }

  # The admitted value is the directory the command actually allocates in:
  # made unwritable, the same command dies at its first temp allocation.
  chmod 500 "$scratch"
  run_release_pathname "$scratch" adopt 1.2.3 --all
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" != *'no registered worktrees matched'* ]] ||
    { echo "the command allocated outside the admitted scratch"; echo "$output"; false; }
  chmod 700 "$scratch"

  ln -s "$scratch" "$TRELLIS_HOME/state/scratch/.cmd.link"
  for hostile in \
    /tmp \
    "$SANDBOX" \
    "$TRELLIS_HOME/state/scratch" \
    "$TRELLIS_HOME/state/scratch/.cmd.missing" \
    "$TRELLIS_HOME/state/scratch/.cmd.link" \
    "$TRELLIS_HOME/state/scratch/./.cmd.fixture"; do
    run_release_pathname "$hostile" adopt 1.2.3 --all
    [ "$status" -eq 4 ] || { echo "candidate=$hostile status=$status"; echo "$output"; false; }
    [[ "$output" == *'command scratch directory is not an admissible'* ]] ||
      { echo "candidate=$hostile"; echo "$output"; false; }
  done

  # Direct source execution stays refused, admissible candidate or not.
  run env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" "PATH=$PATH" "TMPDIR=$scratch" \
    /bin/bash "$REPO_ROOT/scripts/release.sh" adopt 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
}

@test "dispatcher passes grouped routes and preserves legacy route argv and status" {
  local expected command
  prepare_dispatcher_fixture

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" configure --source "/fixture source"
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' configure.sh '<configure>' '<--source>' '</fixture source>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" fleet add work
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' configure.sh '<fleet>' '<add>' '<work>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  for command in release registry; do
    run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" "$command" list
    [ "$status" -eq 3 ]
    expected="$(printf '%s\n' "$command.sh" '<list>')"
    [ "$(cat "$ROUTE_LOG")" = "$expected" ]
  done

  for command in attach detach recover relink; do
    run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" "$command" --probe "$command"
    [ "$status" -eq 3 ]
    expected="$(printf '%s\n' attach-project.sh "<$command>" '<--probe>' "<$command>")"
    [ "$(cat "$ROUTE_LOG")" = "$expected" ]
  done

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" doctor --fix
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' doctor.sh '<--fix>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" mirror --dry-run
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' sync-to-template.sh '<--dry-run>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" conformance --quiet
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' conformance-check.sh '<--quiet>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" launchd --with-apply
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' install-disk-janitor-launchd.sh '<--with-apply>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]
}

@test "dispatcher routes show-config with its home and fleet selection argv" {
  local expected
  prepare_dispatcher_fixture

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 \
    "$DISPATCH_ROOT/trellis" show-config --home "$TRELLIS_HOME" --fleet "work fleet"
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' show-config.sh '<--home>' "<$TRELLIS_HOME>" '<--fleet>' '<work fleet>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]
}

@test "dispatcher refuses the upgrade pathname route and names the launcher route" {
  prepare_dispatcher_fixture
  make_dispatch_stub upgrade.sh

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 \
    "$DISPATCH_ROOT/trellis" upgrade 1.2.4 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'upgrade runs only through the installed stable launcher'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'trellis upgrade VERSION'* ]] || { echo "$output"; false; }
  # No upgrade pathname was opened: the stub would have written the route log.
  [ ! -e "$ROUTE_LOG" ] || { cat "$ROUTE_LOG"; false; }
}

@test "dispatcher preserves materialize argv without injecting a duplicate action" {
  prepare_dispatcher_fixture

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 \
    "$DISPATCH_ROOT/trellis" task materialize --fleet work nightly
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' materialize-scheduled-task.sh '<materialize>' '<--fleet>' '<work>' '<nightly>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]
}

@test "dispatcher prints help and rejects unknown commands" {
  prepare_dispatcher_fixture

  run "$DISPATCH_ROOT/trellis" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: trellis <command> [args...]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"configure"* ]] || { echo "$output"; false; }
  [[ "$output" == *"relink"* ]] || { echo "$output"; false; }
  [[ "$output" == *"conformance"* ]] || { echo "$output"; false; }
  [[ "$output" == *"launchd"* ]] || { echo "$output"; false; }
  [[ "$output" == *"show-config"* ]] || { echo "$output"; false; }
  [[ "$output" == *"upgrade"* ]] || { echo "$output"; false; }

  run "$DISPATCH_ROOT/trellis" unknown-command
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: trellis <command> [args...]"* ]] || { echo "$output"; false; }
}

# Spec 049 regression. The launcher exports TRELLIS_LIBS_PRELOADED=1, and every
# library guarded by that flag skips sourcing its own dependencies when it is
# set. So LIBRARIES must carry what those guards skip; a dependency added to a
# guard but not here is a definition the flag promises and nobody loaded. 1.3.0
# shipped exactly that skew: surface-plan.sh skips skill-roots.sh, the launcher
# did not preload it, and doctor reported `skill_roots_for_harnesses: command
# not found`, failing managed-excludes, native-surfaces and manifest-leaves on
# every attachment it evaluated.
@test "launcher preloads every dependency a PRELOADED guard skips sourcing" {
  run /usr/bin/python3 "$REPO_ROOT/scripts/tests/helpers/preload-closure.py" \
    "$LAUNCHER_TEMPLATE" "$REPO_ROOT/scripts/lib"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "surface-plan resolves skill roots under the launcher preload flag" {
  # Source exactly what the launcher preloads — read from LIBRARIES, never a
  # hardcoded list, or this passes while the launcher omits the dependency.
  libs="$(
    /usr/bin/python3 -c '
import re, sys
block = re.search(r"^LIBRARIES = \((.*?)^\)", open(sys.argv[1]).read(), re.S | re.M).group(1)
print("\n".join(re.findall(r"\"([^\"]+)\"", block)))
' "$LAUNCHER_TEMPLATE"
  )"
  [ -n "$libs" ]

  run /bin/bash --noprofile --norc -c '
    cd "$1" || exit 1
    export TRELLIS_LIBS_PRELOADED=1
    while IFS= read -r lib; do
      [ -n "$lib" ] && . "$lib"
    done <<<"$2"
    . scripts/lib/surface-plan.sh
    command -v skill_roots_for_harnesses >/dev/null || exit 1
    skill_roots_for_harnesses claude
  ' _ "$REPO_ROOT" "$libs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *".claude/skills" ]] || { echo "$output"; false; }
}

# Spec 055 A3.4, the launcher half. The released 1.3.6 launcher and store, both
# unchanged, install one packaged tag from a remote whose main has moved past
# the release commit and never contained the payload commit. Both records are
# byte-identical and carry no excluded entry; the released 1.3.6 configure then
# selects the release and the 1.3.6 launcher dispatches into it. The inversion
# runs the same launcher on an unfiltered release-commit tag.
# stale_directory_cursor <dir> — "stale" when a directory descriptor listed
# while empty still lists nothing after an entry is added (Linux Btrfs), else
# "fresh".
stale_directory_cursor() {
  python3 -I - "$1" <<'PY'
import os, sys, tempfile
d = tempfile.mkdtemp(dir=sys.argv[1])
fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
os.listdir(fd)
open(os.path.join(d, "entry"), "w").close()
print("stale" if not os.listdir(fd) else "fresh")
os.close(fd)
PY
}

@test "A3.4 the v1.3.6 launcher and store install one packaged tag identically and configure selects it" {
  local v136="$SANDBOX/v1.3.6" src="$SANDBOX/packaged-source" remote="$SANDBOX/packaged-remote.git"
  local launcher store_home="$SANDBOX/v136-store-home" record
  payload_fixture_v136 "$v136" scripts/trellis-launcher.sh scripts/lib/release-store.sh scripts/lib/semver.sh
  launcher="$v136/scripts/trellis-launcher.sh"
  chmod 755 "$launcher"
  mkdir -p "$v136/configure"
  git -C "$REPO_ROOT" archive v1.3.6 scripts/configure.sh scripts/lib | tar -x -C "$v136/configure"

  payload_fixture_source "$src" 7.7.7
  payload_fixture_package "$src"
  payload_fixture_tag "$src" 7.7.7 "$PAYLOAD_FIXTURE_PAYLOAD"
  payload_fixture_remote "$src" "$remote" 7.7.7
  [ -z "$(payload_fixture_git --git-dir="$remote" rev-list main | grep -x "$PAYLOAD_FIXTURE_PAYLOAD")" ]

  write_config 7.7.7 "$remote"
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$launcher" release install 7.7.7 --remote "$remote"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  record="$TRELLIS_HOME/releases/7.7.7/release.json"
  [ "$(jq -r .commit "$record")" = "$PAYLOAD_FIXTURE_PAYLOAD" ]
  [ "$(payload_fixture_excluded_entries "$record")" -eq 0 ]

  mkdir -p "$store_home"
  chmod 700 "$store_home"
  run env TRELLIS_HOME="$store_home" bash -c '. "$1"; release_store_install 7.7.7 "$2" ""' _ \
    "$v136/scripts/lib/release-store.sh" "$remote"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cmp "$record" "$store_home/releases/7.7.7/release.json"

  mkdir -p "$SANDBOX/configure-source/core-rules"
  printf '{}\n' > "$SANDBOX/configure-source/trellis.config.json"
  printf '7.7.7\n' > "$SANDBOX/configure-source/core-rules/VERSION"
  run env HOME="$HOME" bash "$v136/configure/scripts/configure.sh" --home "$TRELLIS_HOME" \
    --source "$SANDBOX/configure-source" --release 7.7.7 --default-fleet personal \
    --discovery-root "$SANDBOX/projects" --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .active_cli_release "$TRELLIS_HOME/config.json")" = 7.7.7 ]
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$launcher" probe filtered
  # v1.3.6 seals its execution snapshot by listing it through a descriptor
  # opened while it was empty. Btrfs keeps that descriptor's end-of-directory
  # cursor, so v1.3.6 sees nothing to seal and refuses its own still-writable
  # snapshot record (fixed since by fresh_names). Where the store's filesystem
  # does that, pin the old refusal and run the configured release through the
  # current launcher instead.
  if [ "$(stale_directory_cursor "$SANDBOX")" = stale ]; then
    [ "$status" -ne 0 ]
    [[ "$output" == *"configured release record is missing, writable, or invalid: $TRELLIS_HOME/releases/.tmp.7.7.7.exec."* ]] ||
      { echo "$output"; false; }
    run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" probe filtered
  fi
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = 'fixture dispatcher: probe filtered' ] || { echo "$output"; false; }

  # Inversion: the same launcher on the unfiltered release-commit tag.
  payload_fixture_write "$src/core-rules/VERSION" 7.7.8
  payload_fixture_git -C "$src" commit -qam 'release 7.7.8'
  PAYLOAD_FIXTURE_RELEASE="$(payload_fixture_git -C "$src" rev-parse HEAD)"
  payload_fixture_unfiltered_remote "$src" "$SANDBOX/unfiltered-remote.git" 7.7.8
  write_config 7.7.8 "$SANDBOX/unfiltered-remote.git"
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$launcher" release install 7.7.8 \
    --remote "$SANDBOX/unfiltered-remote.git"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(payload_fixture_excluded_entries "$TRELLIS_HOME/releases/7.7.8/release.json")" -eq 5 ]
}

# ------------------------------------------------------------------ T24
# The installed launcher runs `hook <harness> session-start` in process after
# its warm proof. The shell route (pre-T24 decision) is the oracle.
session_shell_reference() {
  cp "$LAUNCHER" "$SANDBOX/shell-reference"
  python3 -I - "$SANDBOX/shell-reference" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text();old='launcher_native_run_if_available() {\n';assert s.count(old)==1
p.write_text(s.replace(old,old+'  return 10 # test-only shell route reference\n',1))
PY
}

# session_pair HARNESS ROOT EVENT: native then shell, each with stdout only.
# Compares stdout, stderr and status.
session_pair() {
  local launcher rc
  for launcher in "$LAUNCHER" "$SANDBOX/shell-reference"; do
    rc=0
    printf '%s' "$3" | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
      "$launcher" hook session-start "$1" "$2" > "$SANDBOX/pair-out" 2> "$SANDBOX/pair-err" || rc=$?
    { printf 'status=%s\nstderr:\n' "$rc"; cat "$SANDBOX/pair-err"; } >> "$SANDBOX/pair-out"
    if [ "$launcher" = "$LAUNCHER" ]; then mv "$SANDBOX/pair-out" "$SANDBOX/native-out"; fi
  done
  cmp -s "$SANDBOX/native-out" "$SANDBOX/pair-out" || {
    echo "native:"; cat "$SANDBOX/native-out"; echo "shell:"; cat "$SANDBOX/pair-out"; false
  }
}

warm_native_session() {
  pin_native_launcher
  session_shell_reference
  PROJECT="$SANDBOX/projects/session project"
  mkdir -p "$PROJECT/.trellis/runtime" "$PROJECT/sub dir"
  git init -q "$PROJECT"
  printf '# Context log\nbranch: main, last step é\n' > "$PROJECT/context-log.md"
  # The first call is a cold stamp miss on the complete canonical route.
  printf '{"source":"startup"}' | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    "$LAUNCHER" hook session-start claude "$PROJECT" > /dev/null 2>&1 || true
}

@test "T24 native session-start equals the shell route byte for byte with the real hooks" {
  make_release 1.2.3 native-session
  warm_native_session
  local harness event root
  for harness in claude codex; do
    for event in '{"source":"startup"}' '{"source":"resume","session_id":"s"}' '{"source":"compact"}' \
      '{"source":"clear"}' '{}' '' 'not json' '{"source":"startup"} {"source":1}'; do
      for root in "$PROJECT" "$PROJECT/sub dir"; do
        session_pair "$harness" "$root" "$event"
      done
    done
  done
  session_pair claude "$PROJECT" '{"source":"startup"}'
  grep -q 'branch: main, last step é' "$SANDBOX/native-out" || { cat "$SANDBOX/native-out"; false; }
}

@test "T24 native session-start runs members in process and judges them like the shell dispatcher" {
  make_release 1.2.3 native-session-stubs
  warm_native_session
  local harness mode event parent
  for harness in claude codex; do
    for mode in ok fail junk two controls silent; do
      printf '%s' "$mode" > "$SANDBOX/member-mode"
      for event in '{"source":"startup"}' '{"source":"compact"}'; do
        session_pair "$harness" "$PROJECT" "$event"
        [ "$(cat "$SANDBOX/member-parent")" = bash ] || { echo "shell parent: $(cat "$SANDBOX/member-parent")"; false; }
      done
    done
    printf ok > "$SANDBOX/member-mode"
    printf '%s\n\n' '{"source":"startup","x":"a\u0000b"}' | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
      "$LAUNCHER" hook session-start "$harness" "$PROJECT/sub dir" > /dev/null
    parent="$(cat "$SANDBOX/member-parent")"
    [ "$parent" = trellis-hooks ] || { echo "$harness: member parent was $parent, not the native launcher"; false; }
    cp "$SANDBOX/member-env-session-context" "$SANDBOX/native-env"
    cp "$SANDBOX/member-stdin-session-context" "$SANDBOX/native-stdin"
    printf '%s\n\n' '{"source":"startup","x":"a\u0000b"}' | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
      "$SANDBOX/shell-reference" hook session-start "$harness" "$PROJECT/sub dir" > /dev/null
    cmp "$SANDBOX/native-env" "$SANDBOX/member-env-session-context" || {
      diff "$SANDBOX/native-env" "$SANDBOX/member-env-session-context"; false
    }
    cmp "$SANDBOX/native-stdin" "$SANDBOX/member-stdin-session-context"
  done
  assert_no_command_scratch
}

@test "T24 a different dispatcher or a refused root keeps the complete shell route" {
  make_release 1.2.3 native-session-custom
  warm_native_session
  printf ok > "$SANDBOX/member-mode"
  printf '{"source":"startup"}' | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    "$LAUNCHER" hook session-start claude "$PROJECT" > /dev/null
  [ "$(cat "$SANDBOX/member-parent")" = bash ] || { echo "custom dispatcher ran natively"; false; }
  session_pair claude "$PROJECT" '{"source":"startup"}'
  local root
  for root in relative "$PROJECT/./sub dir" "$PROJECT/missing" "$PROJECT//" "$SANDBOX/projects/../projects"; do
    session_pair claude "$root" '{"source":"startup"}'
  done
}

@test "T24 a changed sealed dispatcher dependency keeps the complete shell route" {
  make_release 1.2.3 native-session-deps
  warm_native_session
  printf ok > "$SANDBOX/member-mode"
  local harness
  for harness in claude codex; do
    session_pair "$harness" "$PROJECT" '{"source":"startup"}'
    grep -q '^status=7$' "$SANDBOX/native-out" || { cat "$SANDBOX/native-out"; false; }
    grep -q 'custom deps refusal' "$SANDBOX/native-out" || { cat "$SANDBOX/native-out"; false; }
  done
}

@test "T24 a changed sealed deps-heavy.sh keeps the complete shell route" {
  make_release 1.2.3 native-session-heavy
  warm_native_session
  printf ok > "$SANDBOX/member-mode"
  local harness
  for harness in claude codex; do
    rm -f "$SANDBOX/member-parent"
    printf '{"source":"startup"}' | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
      "$LAUNCHER" hook session-start "$harness" "$PROJECT" > /dev/null
    [ "$(cat "$SANDBOX/member-parent")" = bash ] || { echo "$harness: changed heavy lib ran natively"; false; }
  done
}

@test "T24 native session-start leaves no state that could authorize a later call" {
  make_release 1.2.3 native-session-stubs
  warm_native_session
  local before after launcher
  printf ok > "$SANDBOX/member-mode"
  state_listing() {
    find "$TRELLIS_HOME" "$PROJECT" -path "$TRELLIS_HOME/state/scratch" -prune -o -print | LC_ALL=C sort
  }
  before="$(state_listing)"
  printf '{"source":"startup"}' | native_bounded env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    "$LAUNCHER" hook session-start claude "$PROJECT" > /dev/null
  [ "$(state_listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(state_listing); false; }
  # Killed mid-member: still nothing beyond its private command scratch.
  printf 'sleep' > "$SANDBOX/member-mode"
  rm -f "$SANDBOX/member-pid"
  printf '{"source":"startup"}' | env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" hook session-start claude "$PROJECT" > /dev/null 2>&1 &
  launcher=$!
  local tries=100
  while [ ! -s "$SANDBOX/member-pid" ] && [ "$tries" -gt 0 ]; do sleep 0.05; tries=$((tries - 1)); done
  [ -s "$SANDBOX/member-pid" ] || { echo "member never started"; false; }
  [ "$(cat "$SANDBOX/member-parent")" = trellis-hooks ]
  kill -KILL "$launcher"
  kill -KILL "$(cat "$SANDBOX/member-pid")"
  wait "$launcher" || true
  after="$(state_listing)"
  [ "$after" = "$before" ] || { diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"); false; }
}
