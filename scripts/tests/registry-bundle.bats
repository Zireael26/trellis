#!/usr/bin/env bats
# Registry programs must be captured and manifest-attested with the command
# bundle, never executed later by snapshot pathname.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  # The launcher runs under env -i, so the batch never sees a caller's GIT_*
  # variables; the helper (rightly) refuses any it does not allow, which would
  # make these tests depend on the developer's shell (an exported GIT_EDITOR).
  local name
  for name in $(compgen -e); do
    case "$name" in
      GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|GIT_OPTIONAL_LOCKS|GIT_TERMINAL_PROMPT) ;;
      GIT_*) unset "$name" ;;
    esac
  done
  ROOT="$BATS_TEST_TMPDIR/registry-bundle"
  export TRELLIS_HOME="$ROOT/home" BUNDLE_BATCH_OUT="$ROOT/batch.out" BUNDLE_FS_OUT="$ROOT/fs.out"
  SNAPSHOT="$TRELLIS_HOME/releases/.tmp.1.2.3.exec.Ab3xY9"
  PAYLOAD="$SNAPSHOT/payload"
  mkdir -p "$PAYLOAD/scripts/lib"
  local file
  for file in semver trellis-home skill-roots release-store local-registry settings-hooks-merge attachment; do
    printf '# fixture %s\n' "$file" > "$PAYLOAD/scripts/lib/$file.sh"
  done
  printf '# carrier\n' > "$PAYLOAD/scripts/trellis"
  printf '%s\n' 'printf "%s" "${_TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM-}" > "$BUNDLE_BATCH_OUT"' \
    'printf "%s" "${_TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM-}" > "$BUNDLE_FS_OUT"' > "$PAYLOAD/scripts/release.sh"
  cp "$REPO_ROOT/scripts/lib/registry_identity_batch.py" "$PAYLOAD/scripts/lib/registry_identity_batch.py"
  cp "$REPO_ROOT/scripts/lib/attachment_fs.py" "$PAYLOAD/scripts/lib/attachment_fs.py"
  python3 -I "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$PAYLOAD" > "$ROOT/tree.jsonl"
  jq -s '{tree:.}' "$ROOT/tree.jsonl" > "$SNAPSHOT/release.json"
  DIGEST="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$SNAPSHOT/release.json")"
  find "$SNAPSHOT" -type f -exec chmod 400 {} +
  find "$SNAPSHOT" -type d -exec chmod 500 {} +
  TRELLIS_EX_USAGE=2 TRELLIS_EX_UNAVAILABLE=5
  for function in launcher_absolute_path_is_clean launcher_error launcher_snapshot_payload_matches \
      launcher_snapshot_name_is_safe launcher_emit_verified_command_bundle; do
    body="$(awk -v name="$function" '$0 == name "() {" {inside=1; next} inside && $0 == "}" {exit} inside {print}' "$REPO_ROOT/scripts/trellis-launcher.sh")"
    eval "$function() { $body
}"
  done
}

teardown() {
  [ ! -d "$ROOT" ] || chmod -R u+w "$ROOT"
}

@test "verified command bundle carries exact registry helper and filesystem bytes" {
  launcher_emit_verified_command_bundle "$SNAPSHOT" "$DIGEST" release 1.2.3 > "$ROOT/command.sh" || false
  bash "$ROOT/command.sh" release || false
  cmp "$PAYLOAD/scripts/lib/registry_identity_batch.py" "$BUNDLE_BATCH_OUT" || false
  cmp "$PAYLOAD/scripts/lib/attachment_fs.py" "$BUNDLE_FS_OUT" || false
}

@test "tampering with either bundled registry program is refused before output" {
  for file in registry_identity_batch.py attachment_fs.py; do
    chmod 600 "$PAYLOAD/scripts/lib/$file"
    printf '# tampered\n' >> "$PAYLOAD/scripts/lib/$file"
    chmod 400 "$PAYLOAD/scripts/lib/$file"
    if launcher_emit_verified_command_bundle "$SNAPSHOT" "$DIGEST" release 1.2.3 > "$ROOT/refused.out" 2> "$ROOT/refused.err"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 4 ] || false
    [ ! -s "$ROOT/refused.out" ] || false
    grep -q 'source does not match release record' "$ROOT/refused.err" || false
    chmod 600 "$PAYLOAD/scripts/lib/$file"
    cp "$REPO_ROOT/scripts/lib/$file" "$PAYLOAD/scripts/lib/$file"
    chmod 400 "$PAYLOAD/scripts/lib/$file"
  done
}
