#!/usr/bin/env bats
# Publication checks must not interpret failed probes as successful answers.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-mirror.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  python3 -I - "$REPO_ROOT/scripts/sync-to-template.sh" "$SANDBOX" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
a = source.index('if "$push"', source.index('template_dir="$(mirror_require_real_root'))
b = source.index('\n\n# Positive publication allowlist.', a)
(out / 'status-gate.sh').write_text(source[a:b] + '\n')
a = source.index('ref_integrity_check() {')
b = source.index('\n\n# The verified payload is the only source.', a)
(out / 'refs.sh').write_text(source[a:b] + '\n')
a = source.index('mirror_pin_release_source() {')
b = source.index('\n\n# Restore, from the verified parent', a)
(out / 'pin.sh').write_text(source[a:b] + '\n')
PY
}

@test "push refuses when Git cannot determine checkout cleanliness" {
  run bash -c 'push=true; template_dir=/fixture; mirror_git() { return 128; }; . "$1"; echo gate-passed' _ "$SANDBOX/status-gate.sh"
  [ "$status" -ne 0 ] || { echo "failed status accepted: $output"; false; }
  [[ "$output" != *'gate-passed'* ]]
}

@test "push accepts a successful clean Git status and rejects dirty status" {
  run bash -c 'push=true; template_dir=/fixture; mirror_git() { return 0; }; . "$1"; echo gate-passed' _ "$SANDBOX/status-gate.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'gate-passed'* ]] || { echo "$output"; false; }
  run bash -c 'push=true; template_dir=/fixture; mirror_git() { echo " M file"; }; . "$1"; echo gate-passed' _ "$SANDBOX/status-gate.sh"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
}

@test "reference integrity fails if temporary files cannot be created" {
  printf 'core-rules/missing/reference.md\n' > "$SANDBOX/doc.md"
  run bash -c '. "$1"; sync_paths=(doc.md); mktemp() { return 1; }; core_rules_private_ref() { return 1; }; sync_path_covers_ref() { return 1; }; if ref_integrity_check "$2"; then echo accepted; else exit 4; fi' _ "$SANDBOX/refs.sh" "$SANDBOX"
  [ "$status" -eq 4 ] || { echo "failed mktemp accepted: $output"; false; }
}

@test "reference integrity still accepts a valid document" {
  printf 'No external references.\n' > "$SANDBOX/doc.md"
  run bash -c '. "$1"; sync_paths=(doc.md); core_rules_private_ref() { return 1; }; sync_path_covers_ref() { return 1; }; ref_integrity_check "$2"' _ "$SANDBOX/refs.sh" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

make_release() {
  local with_list="$1" source="$SANDBOX/source" installed="$SANDBOX/installed" commit tree
  mkdir -p "$source" "$installed/payload" "$SANDBOX/bin"
  git -C "$source" init -q -b main
  printf 'parent\n' > "$source/README"
  git -C "$source" add README
  git -C "$source" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm parent
  if [ "$with_list" = true ]; then
    mkdir -p "$source/core-rules"
    printf 'scripts/tests/\n' > "$source/core-rules/payload-exclude.txt"
    tree='[{"path":"core-rules/payload-exclude.txt"}]'
  else
    printf 'legacy\n' > "$source/legacy"
    tree='[{"path":"legacy"}]'
  fi
  git -C "$source" add .
  git -C "$source" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm release
  git -C "$source" tag v1.2.3
  commit="$(git -C "$source" rev-parse HEAD)"
  jq -n --arg commit "$commit" --arg remote "$source" --argjson tree "$tree" '{tag:"v1.2.3",remote:$remote,commit:$commit,tree:$tree}' > "$installed/release.json"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/release-payload-commit.sh"
  chmod 700 "$SANDBOX/bin/release-payload-commit.sh"
}

run_pin() {
  run bash -c '
    . "$1/pin.sh"
    PAYLOAD_ROOT="$1/installed/payload" RELEASE_VERSION=1.2.3
    SOURCE_COMMIT="$(jq -r .commit "$1/installed/release.json")"
    source_repo="$1/source" SCRIPT_DIR="$1/bin" RELEASE_EXCLUDE_LIST=core-rules/payload-exclude.txt
    RESTORE_PARENT= RESTORE_REPO=
    mirror_git() { case " $* " in *" cat-file -e "*) return 128 ;; esac; git -c protocol.file.allow=always "$@"; }
    mirror_git_fetch() { mirror_git "$@"; }
    # Preserve the sandbox path in a global for the writer stub.
    fixture="$1"
    release_store_write_manifest_json() { cp "$fixture/installed/release.json" "$2"; }
    mirror_pin_release_source || exit "$?"
    printf "restore-parent=%s\n" "$RESTORE_PARENT"
  ' _ "$SANDBOX"
}

@test "failed cat-file probe cannot misclassify a filtered release as legacy" {
  make_release true
  run_pin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *'legacy unfiltered release'* ]] || { echo "filtered release lost restore: $output"; false; }
  [[ "$output" == *'restore-parent='* ]] || { echo "$output"; false; }
  [[ "$output" != *'restore-parent='$'\n'* ]]
}

@test "genuinely unfiltered legacy release remains allowed without restore" {
  make_release false
  run_pin
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'legacy unfiltered release'* ]] || { echo "$output"; false; }
  [[ "$output" == *'restore-parent=' ]]
}
