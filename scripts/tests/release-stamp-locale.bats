#!/usr/bin/env bats
# Regression for Bash 5.3/macOS fork-time locale crashes in captured checks.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="${STAMP_TEST_LIB:-$REPO_ROOT/scripts/lib}"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/stamp-locale.XXXXXX")"
  SANDBOX="$(CDPATH='' cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TMPDIR" "$TRELLIS_HOME/releases/1.0.0/payload/core-rules"
  chmod 700 "$HOME" "$TMPDIR" "$TRELLIS_HOME" "$TRELLIS_HOME/releases"
  REL="$TRELLIS_HOME/releases/1.0.0"
  export REL
  python3 -I - "$REL" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
files = {"core-rules/CLAUDE.md": b"rules\n", "core-rules/VERSION": b"1.0.0\n"}
tree = []
for path, data in sorted(files.items()):
    with open(root + "/payload/" + path, "wb") as output:
        output.write(data)
    oid = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    tree.append({"path": path, "mode": "100644", "oid": oid})
with open(root + "/release.json", "w") as output:
    json.dump({"schema_version": 1, "version": "1.0.0", "tag": "v1.0.0",
               "commit": "a" * 40, "remote": "fixture://locale", "tree": tree}, output)
for current, dirs, files in os.walk(root, topdown=False):
    for name in files:
        os.chmod(os.path.join(current, name), 0o444)
    os.chmod(current, 0o555)
PY
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

@test "stamp interpreter has no temporary shell locale assignment" {
  run bash -c '. "$1/release-stamp.sh"; declare -f _release_stamp_run' _ "$LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if printf '%s\n' "$output" | grep -Eq '^[[:space:]]*(LANG|LC_[A-Z_]+)=[^[:space:]]+[[:space:]]+'; then
    echo 'temporary locale assignment survives'; false
  fi
}

@test "owner batch interpreter delegates locale setup to env" {
  # This helper runs inside captured owner-batch calls. A temporary LC_ALL
  # assignment is reset by Bash itself on return, which can crash in libintl
  # after fork on macOS when the caller has no locale variables.
  run env TRELLIS_LIBS_PRELOADED=1 bash -c '. "$1/attachment.sh"; declare -f _attachment_owner_verify_exec' _ "$LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'/usr/bin/env TRELLIS_SETTINGS_OWNED_JSON_PROGRAM="$settings" LC_ALL=C "$python_bin"'* ]] || {
    echo "owner batch locale is a temporary shell assignment: $output"; false
  }
  grep -qF '| /usr/bin/env TRELLIS_SETTINGS_OWNED_JSON_PROGRAM="$(_settings_owned_json_program)" LC_ALL=C python3' \
    "$REPO_ROOT/scripts/tests/owner-verify-batch.bats" || {
    echo 'owner batch test oracle uses a temporary shell locale assignment'; false
  }
}

@test "generated dispatcher stamp helper delegates locale setup to env" {
  local generated="$SANDBOX/dispatcher.sh"
  # Exercise the emitted dispatcher, not just the generator's source text.
  run env HOME="$HOME" bash -c '
    . "$1/trellis-home.sh"; . "$1/release-store.sh"; . "$1/local-registry.sh"
    . "$1/surface-plan.sh"; . "$1/attachment.sh"
    _attachment_hooks_pre_push_dispatcher_body_in_process "$2" core-rules/husky/pre-push placeholder > "$3"
  ' _ "$LIB" "$REL/payload" "$generated"
  [ "$status" -eq 0 ] || { echo "dispatcher generation: $output"; false; }
  run awk '
    /^trellis_release_stamp\(\) \{$/ { inside=1; count++ }
    inside { print }
    inside && /^\}$/ { inside=0 }
    END { if (count != 1 || inside) exit 1 }
  ' "$generated"
  [ "$status" -eq 0 ] || { echo "missing or duplicate dispatcher helper: $output"; false; }
  [[ "$output" == *'/usr/bin/env LC_ALL=C "$python_bin" -I -c "$program"'* ]] || {
    echo "dispatcher stamp helper does not use env: $output"; false
  }
  if printf '%s\n' "$output" | grep -Eq '^[[:space:]]*(LANG|LC_[A-Z_]+)=[^[:space:]]+[[:space:]]+'; then
    echo 'temporary locale assignment survives in dispatcher'; false
  fi
}

@test "real stamp checks and writes survive repeated redirected substitutions" {
  [ -x /usr/bin/python3 ] || skip 'system Python is unavailable'
  # The stamp is written only after the fixture passed the complete verifier.
  run env TRELLIS_PYTHON=/usr/bin/python3 bash -c '. "$1/release-store.sh"; release_store_verify_path "$2" 1.0.0' _ "$LIB" "$REL"
  [ "$status" -eq 0 ] || { echo "fixture verify: $output"; false; }
  run /usr/bin/python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME" "$REL"
  [ "$status" -eq 1 ] && [[ "$output" =~ ^[0-9a-f]{64}$ ]] || { echo "fixture token: $output"; false; }
  token="$output"
  run /usr/bin/python3 -I "$LIB/release_stamp.py" write "$TRELLIS_HOME" "$REL" "$token"
  [ "$status" -eq 0 ] || { echo "fixture stamp: $output"; false; }

  local operation n failures=0 segv=0 detail=''
  for operation in check-memo write-memo; do
    for n in $(seq 1 30); do
      # A fresh Bash for each call reproduces the real Bats/launcher fork shape.
      run env TRELLIS_PYTHON=/usr/bin/python3 bash -c '
        . "$1/release-stamp.sh"
        if [ "$2" = write-memo ]; then
          output="$(_release_stamp_run "$2" "$3" "$4" "$5")"; rc=$?
        else
          output="$(_release_stamp_run "$2" "$3" "$4")"; rc=$?
        fi
        [ "$rc" -eq 0 ] || exit "$rc"
        case "$output" in hit|$'\''hit\t'\''*) exit 0 ;; *) exit 1 ;; esac
      ' _ "$LIB" "$operation" "$TRELLIS_HOME" "$REL" "$token"
      if [ "$status" -ne 0 ]; then
        failures=$((failures + 1))
        [ "$status" -ne 139 ] || segv=$((segv + 1))
        detail="$detail $operation:$status"
      fi
    done
  done
  echo "# attempts=60 failures=$failures segv=$segv$detail" >&3
  [ "$failures" -eq 0 ] || { echo "attempts=60 failures=$failures segv=$segv$detail"; false; }
}
