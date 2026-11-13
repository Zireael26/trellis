#!/usr/bin/env bats
#
# Spec 072 U5: the post-checkout current-worktree check covers what the full
# reconcile would have checked beyond the commit diff: the owned keys of the
# rendered harness settings, the managed hook set, and the portable manifest's
# working-tree state and declared identity.
#
# The release carries the real settings templates and a reconcile that only
# records that it ran (.reconciled in the worktree), so the witness is direct.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/u5-state.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 TRELLIS_ATTACH_POSTJOB=off
  local source="$SANDBOX/source" path
  mkdir -p "$HOME" "$TRELLIS_HOME" "$source/core-rules/templates" "$source/core-rules/githooks" "$source/scripts"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  # The real legacy provider is needed when no supported Claude is on PATH.
  mkdir -p "$source/core-rules/legacy-hooks"
  cp -R "$REPO_ROOT/core-rules/legacy-hooks/." "$source/core-rules/legacy-hooks/"
  # Owned Booleans, at a leaf and nested, that a number must not stand in for.
  jq '. + {"enableAllProjectMcpServers": true, "fixtureOwned": {"flags": [true, 0, {"on": false}]}}' \
    "$REPO_ROOT/core-rules/templates/claude-settings.local.json" > "$source/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" "$source/core-rules/templates/"
  printf '# fixture policy\n' > "$source/core-rules/CLAUDE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$source/core-rules/githooks/pre-push"
  cat > "$source/scripts/seed-inheritance-symlinks.sh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in --target) target="$2"; shift ;; esac
  shift
done
: > "$target/.reconciled"
SH
  chmod 755 "$source/core-rules/githooks/pre-push" "$source/scripts/seed-inheritance-symlinks.sh"
  printf '9.0.1\n' > "$source/core-rules/VERSION"
  while IFS= read -r path; do
    [ "$path" != scripts/seed-inheritance-symlinks.sh ] || continue
    mkdir -p "$source/${path%/*}"
    cp "$REPO_ROOT/$path" "$source/$path"
  done < <(sed -n '/^  local -a paths=($/,/^  )$/p' "$REPO_ROOT/scripts/lib/attachment.sh" | sed '1d;$d;s/^ *//')
  printf '%s\n' '{"schema_version":1,"harnesses":{"claude":{"links":[{"source":"core-rules/CLAUDE.md","destination":".claude/rules/trellis.md"}],"render":[{"template":"core-rules/templates/claude-settings.local.json","destination":".claude/settings.local.json","merge":"explicit-json","mode":"0600","required":true}]},"codex":{"links":[{"source":"core-rules/CLAUDE.md","destination":".agents/rules/trellis.md"}],"render":[{"template":"core-rules/templates/codex-hooks.local.json","destination":".codex/hooks.json","merge":"explicit-json","mode":"0600","required":true}]}}}' > "$source/core-rules/inheritance-manifest.json"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.0.1 "$source"
  PAYLOAD="$TRELLIS_HOME/releases/9.0.1/payload"

  PROJECT="$SANDBOX/project"
  git init -q "$PROJECT"
  git -C "$PROJECT" config user.name fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"u5-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  BASE="$(git -C "$PROJECT" symbolic-ref --short HEAD)"
  git -C "$PROJECT" checkout -q -b other
  printf 'other\n' > "$PROJECT/src.txt"
  git -C "$PROJECT" add src.txt
  git -C "$PROJECT" commit -qm other
  git -C "$PROJECT" checkout -q "$BASE"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  OWNER="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  MANAGED="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  stamp_release
}

teardown() {
  /usr/bin/python3 - "$SANDBOX" <<'PY'
import os, shutil, sys
for root, dirs, files in os.walk(sys.argv[1]):
    os.chmod(root, 0o700)
    for name in files:
        path = os.path.join(root, name)
        if not os.path.islink(path):
            os.chmod(path, 0o600)
shutil.rmtree(sys.argv[1])
PY
}

# What a full verify leaves behind: a stamp of the release as it is now.
stamp_release() {
  local release="${PAYLOAD%/payload}" token
  token="$(python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "$release")" && return 0
  python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" write "$TRELLIS_HOME" "$release" "$token"
}

# Switch to <branch> and back with hooks on; leaves the reconcile witness.
round_trip() {
  rm -f "$PROJECT/.reconciled"
  run git -C "$PROJECT" switch -q other
  [ "$status" -eq 0 ] || { printf 'switch: %s\n%s\n' "$status" "$output"; return 1; }
  git -C "$PROJECT" -c core.hooksPath=/dev/null switch -q "$BASE"
}

assert_fast() {
  round_trip
  [ ! -e "$PROJECT/.reconciled" ] || { echo 'full reconcile ran'; printf '%s\n' "$output"; false; }
}

assert_full() {
  round_trip
  [ -e "$PROJECT/.reconciled" ] || { echo 'fast path taken'; false; }
}

# The fast path not taken: the reconcile ran, or the hook failed loudly before
# it could (a sidecar that names no usable payload).
assert_missed() {
  rm -f "$PROJECT/.reconciled"
  run git -C "$PROJECT" switch -q other
  git -C "$PROJECT" -c core.hooksPath=/dev/null switch -q "$BASE"
  [ -e "$PROJECT/.reconciled" ] && return 0
  [ "$status" -ne 0 ] && [[ "$output" == *"attachment reconciliation failed"* ]] ||
    { printf 'fast path taken (switch %s)\n%s\n' "$status" "$output"; false; }
}

# Sets the first owned key of the render at <path> to <json>, keeping the mode.
drift_render() {
  local file="$PROJECT/$1" key
  key="$(jq -c --arg path "$1" '.renders[] | select(.path == $path) | .owned_keys[0].path' "$OWNER")"
  [ -n "$key" ] || { echo "no owned key for $1"; return 1; }
  jq --argjson key "$key" --argjson value "$2" 'setpath($key; $value)' "$file" > "$SANDBOX/drift.json"
  cat "$SANDBOX/drift.json" > "$file"
}

@test "a current worktree with rendered settings takes the fast path, and keeps project keys" {
  assert_fast
  for path in .claude/settings.local.json .codex/hooks.json; do
    jq '.projectOwned = {"kept": true}' "$PROJECT/$path" > "$SANDBOX/added.json"
    cat "$SANDBOX/added.json" > "$PROJECT/$path"
  done
  assert_fast
}

run_extracted_current() {
  local tools="$1" log="$2" race_file="${3:-}"
  run env -i PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin" HOME=/dev/null LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TRELLIS_T16_EXEC_LOG="$log" \
    TRELLIS_T16_RACE_FILE="$race_file" \
    /bin/bash --noprofile --norc -c '
set -eu
managed_dir=$1; managed_home=$2; project_root=$3; expected_payload=$4
expected_release_manifest_sha256=$5
for name in expected_passthrough_names trellis_owner_schema_b64 trellis_manifest_schema_b64; do
  declaration=$(/usr/bin/grep "^$name=" "$managed_dir/post-checkout" || true)
  [ -z "$declaration" ] || eval "$declaration"
done
for name in trellis_worktree_current trellis_read_sidecar trellis_hash_text trellis_mode \
  trellis_verify_release_executed trellis_verify_release_anchor trellis_canonical_dir \
  trellis_readonly trellis_hash_file trellis_release_manifest_valid trellis_release_stamp \
  trellis_release_stamp_program; do
  body=$(/usr/bin/awk -v open="$name() {" '\''
    $0 == open { starts++; inside=1 }
    inside { print }
    inside && $0 == "}" { inside=0; ends++ }
    END { if (starts != 1 || ends != 1 || inside) exit 1 }
  '\'' "$managed_dir/post-checkout") || exit 1
  eval "$body"
done
old=$(/usr/bin/git -C "$project_root" rev-parse "$6")
new=$(/usr/bin/git -C "$project_root" rev-parse other)
trellis_worktree_current "$old" "$new" 1
' _ "$MANAGED" "$TRELLIS_HOME" "$PROJECT" "$PAYLOAD" \
    "$(shasum -a 256 "${PAYLOAD%/payload}/release.json" | cut -c1-64)" "$BASE"
}

@test "current worktree checks the stamp and owner in one Python invocation" {
  local count_dir="$SANDBOX/python-count" count_log="$SANDBOX/python-count.log"
  mkdir "$count_dir"
  cat > "$count_dir/python3" <<'SH'
#!/bin/sh
printf 'python\n' >> "$TRELLIS_T16_EXEC_LOG"
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$count_dir/python3"
  cat > "$count_dir/jq" <<'SH'
#!/bin/sh
printf 'jq\n' >> "$TRELLIS_T16_EXEC_LOG"
exec /usr/bin/jq "$@"
SH
  chmod 700 "$count_dir/jq"
  run_extracted_current "$count_dir" "$count_log"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  local python_count jq_count
  python_count="$(grep -c '^python$' "$count_log" || true)"
  jq_count="$(grep -c '^jq$' "$count_log" || true)"
  [ "$python_count" -eq 1 ] && [ "$jq_count" -eq 2 ] || {
    printf 'expected 1 Python and 2 jq invocations, saw %s Python and %s jq\n' "$python_count" "$jq_count"
    false
  }
}

@test "the warm current-worktree proof does not import tempfile unconditionally" {
  local tools="$SANDBOX/warm-import-bin" log="$SANDBOX/warm-import.log"
  mkdir "$tools"
  cat > "$tools/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] && [[ "${3:-}" == *'operation, stamp_home, release_dir, program'* ]]; then
  printf 'checked-warm-imports\n' >> "$TRELLIS_T16_EXEC_LOG"
  exec /usr/bin/python3 -I - "$@" <<'PY'
import ast, os, sys
program = sys.argv[3]
for node in ast.parse(program).body:
    if isinstance(node, ast.Import) and any(alias.name == 'tempfile' for alias in node.names):
        sys.exit('tempfile imported on every warm proof')
os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-c', program] + sys.argv[4:])
PY
fi
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$tools/python3"
  run_extracted_current "$tools" "$log"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  grep -Fx checked-warm-imports "$log"
}

@test "a failed schema subprocess cannot authorize the current proof" {
  local tools="$SANDBOX/schema-failure-bin"
  mkdir "$tools"
  cat > "$tools/jq" <<'SH'
#!/bin/sh
if [ "${1:-}" = -n ]; then
  printf 'true\n'
  exit 7
fi
exec /usr/bin/jq "$@"
SH
  chmod 700 "$tools/jq"
  run_extracted_current "$tools" "$SANDBOX/failure.log"
  [ "$status" -ne 0 ] || { echo 'failed schema process authorized the proof'; return 1; }
  assert_fast
}

@test "owner and manifest changes during schema validation invalidate the proof" {
  local tools="$SANDBOX/race-bin" file
  mkdir "$tools"
  cat > "$tools/jq" <<'SH'
#!/bin/sh
if [ "${1:-}" = -n ]; then
  printf ' \n' >> "$TRELLIS_T16_RACE_FILE"
fi
exec /usr/bin/jq "$@"
SH
  chmod 700 "$tools/jq"
  cp -p "$OWNER" "$SANDBOX/owner-before-race"
  cp -p "$PROJECT/.trellis.json" "$SANDBOX/manifest-before-race"
  for file in "$OWNER" "$PROJECT/.trellis.json"; do
    run_extracted_current "$tools" "$SANDBOX/race.log" "$file"
    [ "$status" -ne 0 ] || { echo "raced proof unexpectedly succeeded: $file"; return 1; }
    if [ "$file" = "$OWNER" ]; then
      ! cmp -s "$file" "$SANDBOX/owner-before-race" || { echo 'owner race did not fire'; return 1; }
      cat "$SANDBOX/owner-before-race" > "$file"
    else
      ! cmp -s "$file" "$SANDBOX/manifest-before-race" || { echo 'manifest race did not fire'; return 1; }
      cat "$SANDBOX/manifest-before-race" > "$file"
    fi
  done
  assert_fast
}

@test "owned event and hook prefixes preserve appended project hooks without hiding drift" {
  local file="$PROJECT/.claude/settings.local.json"
  cp -p "$file" "$SANDBOX/owned-settings.json"
  jq '.hooks.PreToolUse[0].hooks += [{"type":"command","command":"project-inner"}] |
      .hooks.PreToolUse += [{"matcher":"ProjectOnly","hooks":[{"type":"command","command":"project-block"}]}]' \
    "$SANDBOX/owned-settings.json" > "$SANDBOX/settings-with-project.json"
  cat "$SANDBOX/settings-with-project.json" > "$file"
  assert_fast
  cmp "$file" "$SANDBOX/settings-with-project.json"

  # Neither a changed canonical block nor a changed canonical hook may be
  # mistaken for an unowned append.
  jq '.hooks.PreToolUse[0].matcher = "changed"' "$SANDBOX/settings-with-project.json" > "$file"
  assert_full
  jq '.hooks.PreToolUse[0].hooks[0].command = "changed"' "$SANDBOX/settings-with-project.json" > "$file"
  assert_full
  jq '.hooks.PreToolUse[0].extra = true' "$SANDBOX/settings-with-project.json" > "$file"
  assert_full
  python3 -I -c 'import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
data["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"] = 30.0
with open(sys.argv[2], "w") as f: json.dump(data, f)' "$SANDBOX/settings-with-project.json" "$file"
  assert_full
  jq '.hooks.PreToolUse = [{"matcher":"ProjectFirst","hooks":[]}] + .hooks.PreToolUse' \
    "$SANDBOX/settings-with-project.json" > "$file"
  assert_full
  cat "$SANDBOX/settings-with-project.json" > "$file"
  assert_fast
}

@test "ambiguous rendered settings and hook memos never qualify as current" {
  local file="$PROJECT/.claude/settings.local.json" memo
  cp -p "$file" "$SANDBOX/settings-unambiguous.json"
  python3 -I -c 'import sys
with open(sys.argv[1]) as f: data = f.read().lstrip()
assert data.startswith("{")
with open(sys.argv[2], "w") as f: f.write("{\"hooks\":{}," + data[1:])' \
    "$SANDBOX/settings-unambiguous.json" "$file"
  assert_full
  cat "$SANDBOX/settings-unambiguous.json" > "$file"
  assert_fast

  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/memo-unambiguous.json"
  python3 -I -c 'import sys
with open(sys.argv[1]) as f: data = f.read().lstrip()
assert data.startswith("{")
with open(sys.argv[2], "w") as f: f.write("{\"schema_version\":99," + data[1:])' \
    "$SANDBOX/memo-unambiguous.json" "$memo"
  assert_full
  cat "$SANDBOX/memo-unambiguous.json" > "$memo"
  assert_fast
}

@test "zero old HEAD and an effective hooksPath override cannot use the current proof" {
  local head old
  head="$(git -C "$PROJECT" rev-parse "$BASE")"
  old="$(printf '%040d' 0)"
  run /bin/bash -c 'cd "$1" && "$2" "$3" "$4" 1' _ "$PROJECT" "$MANAGED/post-checkout" "$old" "$head"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -e "$PROJECT/.reconciled" ] || { echo 'zero old HEAD took the fast path'; false; }

  git -C "$PROJECT" config --local extensions.worktreeConfig true
  git -C "$PROJECT" config --worktree core.hooksPath "$SANDBOX/other-hooks"
  rm -f "${PROJECT:?}/.reconciled"
  run /bin/bash -c 'cd "$1" && "$2" "$3" "$4" 1' _ "$PROJECT" "$MANAGED/post-checkout" \
    "$head" "$(git -C "$PROJECT" rev-parse other)"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -e "$PROJECT/.reconciled" ] || { echo 'effective hooksPath override took the fast path'; false; }
  git -C "$PROJECT" config --worktree --unset core.hooksPath
  assert_fast
}

@test "a malformed owner schema or worktree identity cannot qualify as current" {
  local edit
  cp -p "$OWNER" "$SANDBOX/owner-valid.json"
  assert_fast
  for edit in '.schema_version = 2' '.schema_version = true' '.checkout_id = ("0" * 64)' \
      '.worktree_id = ("0" * 64)' '.surface = "user"' '.unexpected_owner_key = true' '.git_hooks.unexpected = true' \
      '.artifacts[0].unexpected = true' '.renders[0].unexpected = true'; do
    jq "$edit" "$SANDBOX/owner-valid.json" > "$SANDBOX/owner-invalid.json"
    cat "$SANDBOX/owner-invalid.json" > "$OWNER"
    assert_full || { echo "owner mutation accepted: $edit"; return 1; }
  done
  cat "$SANDBOX/owner-valid.json" > "$OWNER"
  assert_fast
}

@test "an unknown committed project manifest schema cannot qualify as current" {
  local head
  jq '.schema_version = 2' "$PROJECT/.trellis.json" > "$SANDBOX/manifest-invalid.json"
  cat "$SANDBOX/manifest-invalid.json" > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm 'unknown manifest schema'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  run /bin/bash -c 'cd "$1" && "$2" "$3" "$3" 1' _ "$PROJECT" "$MANAGED/post-checkout" "$head"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -e "$PROJECT/.reconciled" ] || { echo 'unknown manifest schema took the fast path'; false; }
}

@test "duplicate keys in the owner and committed project manifest cannot qualify as current" {
  local head
  cp -p "$OWNER" "$SANDBOX/owner-unique.json"
  python3 -I -c 'import sys
with open(sys.argv[1]) as f: data = f.read().lstrip()
assert data.startswith("{")
with open(sys.argv[2], "w") as f: f.write("{\"status\":\"prepared\"," + data[1:])' \
    "$SANDBOX/owner-unique.json" "$OWNER"
  assert_full
  cat "$SANDBOX/owner-unique.json" > "$OWNER"
  assert_fast
  cp -p "$PROJECT/.trellis.json" "$SANDBOX/manifest-unique.json"
  python3 -I -c 'import sys
with open(sys.argv[1]) as f: data = f.read().lstrip()
assert data.startswith("{")
with open(sys.argv[2], "w") as f: f.write("{\"schema_version\":2," + data[1:])' \
    "$SANDBOX/manifest-unique.json" "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm 'duplicate manifest schema'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  run /bin/bash -c 'cd "$1" && "$2" "$3" "$3" 1' _ "$PROJECT" "$MANAGED/post-checkout" "$head"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -e "$PROJECT/.reconciled" ] || { echo 'duplicate manifest key took the fast path'; false; }
}

@test "an unknown committed manifest policy cannot qualify as current" {
  local head
  jq '.gate = {"unexpected": true}' "$PROJECT/.trellis.json" > "$SANDBOX/manifest-invalid.json"
  cat "$SANDBOX/manifest-invalid.json" > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm 'unknown manifest policy'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  run /bin/bash -c 'cd "$1" && "$2" "$3" "$3" 1' _ "$PROJECT" "$MANAGED/post-checkout" "$head"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -e "$PROJECT/.reconciled" ] || { echo 'unknown manifest policy took the fast path'; false; }
}

# Run the canonical validator from the same verified payload that generated
# the dispatcher. Its status is a verdict, not an attachment authorization.
canonical_owner_schema() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C \
    TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
_attachment_owner_json_valid "$2"' owner-schema "$PAYLOAD" "$1"
}

canonical_manifest_schema() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/local-registry.sh" >/dev/null 2>&1 || exit 9
local_registry_manifest_project_id "$2" >/dev/null 2>&1' manifest-schema "$PAYLOAD" "$1"
}

# Exercise the exact schema function embedded in the generated dispatcher,
# without running its other identity/hook checks over deliberately invalid data.
# The same function is called by the real fast proof before it trusts an owner.
fused_schemas() {
  python3 -I - "$MANAGED/post-checkout" "$1" "$2" \
    "$trellis_owner_schema_b64" "$trellis_manifest_schema_b64" <<'PY'
import base64, binascii, pathlib, subprocess, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
begin, end = "# trellis-schema-validation-begin", "# trellis-schema-validation-end"
if text.count(begin) != 1 or text.count(end) != 1:
    raise SystemExit(9)
fragment = text.split(begin, 1)[1].split(end, 1)[0]
namespace = {"base64": base64, "binascii": binascii, "subprocess": subprocess}
exec(compile(fragment, "<generated-schema-validation>", "exec"), namespace)
result = namespace["trellis_schema_valid"](pathlib.Path(sys.argv[2]).read_bytes(),
                                           pathlib.Path(sys.argv[3]).read_bytes(), *sys.argv[4:6])
raise SystemExit(0 if result else 1)
PY
}

fused_owner_schema() {
  fused_schemas "$1" "$PROJECT/.trellis.json"
}

@test "fused owner schema matches the canonical validator over nested mutation corpus" {
  local declaration edit expected actual count=0 candidate="$SANDBOX/owner-corpus.json"
  declaration="$(grep '^trellis_owner_schema_b64=' "$MANAGED/post-checkout")"
  [ -n "$declaration" ] || { echo 'missing generated canonical owner validator'; return 1; }
  eval "$declaration"
  declaration="$(grep '^trellis_manifest_schema_b64=' "$MANAGED/post-checkout")"
  [ -n "$declaration" ] || { echo 'missing generated canonical manifest validator'; return 1; }
  eval "$declaration"
  cp -p "$OWNER" "$candidate"
  jq -e '(.git_hooks | type == "object") and (.artifacts | length > 0) and
         (.renders | length > 0 and (.[0].owned_keys | length > 0)) and
         (.exclude | type == "object") and (.render_context | type == "object")' "$candidate" >/dev/null
  canonical_owner_schema "$candidate"
  fused_owner_schema "$candidate"
  # A missing optional exclude is accepted by the canonical validator.
  jq 'del(.exclude)' "$OWNER" > "$candidate"
  chmod 600 "$candidate"
  canonical_owner_schema "$candidate"
  fused_owner_schema "$candidate"
  for edit in \
    '.unexpected = true' 'del(.status)' '.schema_version = true' \
    '.git_hooks.unexpected = true' '.git_hooks.previous_hooks_path = false' \
    '.git_hooks.previous_hooks_path = ""' '.git_hooks.previous_hooks_path = 0' \
    'del(.git_hooks.managed_hooks_path)' '.git_hooks.enabled = 1' \
    '.git_hooks.previous_hooks_path = 7' '.git_hooks.pre_push_source = "invalid"' \
    'del(.fleet)' '.fleet = "BAD FLEET"' 'del(.attachment_id)' '.attachment_id = 7' '."$schema" = 7' \
    '.toolchain_path = "relative"' '.toolchain_path = ["rel/bin"]' '.toolchain_path = [false]' \
    'del(.render_context)' '.render_context = {"schema_version":9}' \
    '.render_context.unexpected = true' 'del(.render_context.user_home)' '.render_context.schema_version = true' \
    '.exclude.unexpected = true' '.exclude_block_hash = ("0" * 64)' 'del(.exclude_block_hash)' \
    'del(.exclude.path)' '.exclude.after_exists = "true"' '.exclude.managed_by_attachment = 1' \
    '.pre_existing = [{"bogus":1}]' \
    '.artifacts[0].path as $p | .pre_existing = [{"path":$p,"kind":"symlink","reason":"pre-existing-symlink","target":"x"}]' \
    '.artifacts[0].unexpected = true' '.artifacts[0] = {"kind":"parent","path":".."}' \
    '.artifacts[0] = {"kind":"parent","path":"."}' 'del(.artifacts[0].path)' '.artifacts[0].kind = false' \
    '.renders = null' '.renders = {}' '.renders[0].unexpected = true' '.renders[0].merge = "other"' \
    'del(.renders[0].before_sha256)' '.renders += [.renders[0]]' '.renders[0].owned_keys = false' \
    '.renders[0].owned_keys[0].unexpected = true' 'del(.renders[0].owned_keys[0].value)' \
    '.renders[0].owned_keys[0].path = 3' '.renders[0].created_paths = [false]'; do
    jq "$edit" "$OWNER" > "$candidate"
    chmod 600 "$candidate"
    if canonical_owner_schema "$candidate"; then expected=0; else expected=$?; fi
    [ "$expected" -ne 9 ] || { echo 'canonical validator did not load'; return 1; }
    [ "$expected" -eq 0 ] || expected=1
    if fused_owner_schema "$candidate"; then actual=0; else actual=$?; fi
    [ "$actual" -ne 9 ] || { echo 'fused validator could not be extracted'; return 1; }
    # The canonical keyset predicate allows a missing owned-key value; the
    # current-worktree proof separately misses when it later reads that value.
    if [ "$edit" != 'del(.renders[0].owned_keys[0].value)' ] && [ "$expected" -ne 1 ]; then
      printf 'mutation unexpectedly valid in canonical validator: %s\n' "$edit"
      return 1
    fi
    [ "$actual" -eq "$expected" ] || {
      printf 'schema differential failed: %s canonical=%s fused=%s\n' "$edit" "$expected" "$actual"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 40 ]
}

@test "fused project manifest schema matches the canonical validator" {
  local declaration edit expected actual count=0 candidate="$SANDBOX/manifest-corpus.json"
  declaration="$(grep '^trellis_owner_schema_b64=' "$MANAGED/post-checkout")"; eval "$declaration"
  declaration="$(grep '^trellis_manifest_schema_b64=' "$MANAGED/post-checkout")"; eval "$declaration"
  cp -p "$PROJECT/.trellis.json" "$candidate"
  canonical_manifest_schema "$candidate"
  fused_schemas "$OWNER" "$candidate"
  for edit in \
    '.unexpected = true' 'del(.project_id)' '.schema_version = 2' '.project_id = 7' '.project_id = "bad id"' \
    '.autonomy = 0' '.autonomy = true' '.presets = "bad"' '.presets = ["UPPER"]' \
    '.presets = ["repeat","repeat"]' '.package_manager = "pip"' '.loop_safety = []' \
    '.loop_safety = {"unexpected":true}' '.loop_safety.max_iterations = 0' \
    '.loop_safety.usd_per_mtok = 0' '.mandatory_pipeline = {"unexpected":true}' \
    '.mandatory_pipeline.enabled = 1' '.mandatory_pipeline.spec_required_diff_lines = 0' \
    '.gate = {"unexpected":true}' '.gate.env_passthrough = ["PASSWORD"]' \
    '.gate.env_passthrough = ["APP_MODE","APP_MODE"]' '.security_gate = {"unexpected":true}' \
    '.security_gate.semgrep_timeout = 601' '.gate_profiles = {"one":false}' '."$schema" = false' \
    '.project_id = "good\nbad"' '., .'; do
    jq "$edit" "$PROJECT/.trellis.json" > "$candidate"
    if canonical_manifest_schema "$candidate"; then expected=0; else expected=$?; fi
    [ "$expected" -ne 9 ] || { echo 'canonical manifest validator did not load'; return 1; }
    [ "$expected" -eq 0 ] || expected=1
    if fused_schemas "$OWNER" "$candidate"; then actual=0; else actual=$?; fi
    [ "$actual" -ne 9 ] || { echo 'fused validator could not be extracted'; return 1; }
    [ "$expected" -eq 1 ] && [ "$actual" -eq "$expected" ] || {
      printf 'manifest differential failed: %s canonical=%s fused=%s\n' "$edit" "$expected" "$actual"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -eq 27 ]
}

schema_generator_from_copy() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C TRELLIS_LIBS_PRELOADED=1 \
    /bin/bash --noprofile --norc -c '
LIB_DIR=$1
. "$LIB_DIR/attachment.sh" >/dev/null 2>&1 || exit 9
_attachment_library_source() { printf "%s\n" "$LIB_DIR/attachment.sh"; }
_attachment_hooks_dispatcher_common_body() { :; }
_attachment_hooks_post_checkout_dispatcher_body_in_process /tmp/payload placeholder
' schema-generator "$1"
}

@test "changed canonical validation wrappers fall back rather than guessing a schema" {
  local library="$SANDBOX/schema-source" declaration
  mkdir "$library"
  cp "$REPO_ROOT/scripts/lib/attachment.sh" "$library/attachment.sh"
  cp "$REPO_ROOT/scripts/lib/local-registry.sh" "$library/local-registry.sh"
  cp "$REPO_ROOT/scripts/lib/trellis-home.sh" "$library/trellis-home.sh"
  run schema_generator_from_copy "$library"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -Eq '^trellis_owner_schema_b64=.+$'
  printf '%s\n' "$output" | grep -Eq '^trellis_manifest_schema_b64=.+$'

  python3 -I - "$library/attachment.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = path.read_text(encoding="utf-8")
before = '_attachment_mode() {\n  _attachment_stat_mode "$1"\n}\n'
after = '_attachment_mode() {\n  # Changed helper must disable schema extraction.\n  _attachment_stat_mode "$1"\n}\n'
assert data.count(before) == 1
path.write_text(data.replace(before, after), encoding="utf-8")
PY
  run schema_generator_from_copy "$library"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  printf '%s\n' "$output" | grep -qx '^trellis_owner_schema_b64=$'
  printf '%s\n' "$output" | grep -qx '^trellis_manifest_schema_b64=$'
  declaration="$(grep '^trellis_manifest_schema_b64=' "$MANAGED/post-checkout")"; eval "$declaration"
  trellis_owner_schema_b64=""
  if fused_schemas "$OWNER" "$PROJECT/.trellis.json"; then
    echo 'an unavailable canonical schema unexpectedly passed'
    return 1
  fi
}

@test "schema extraction fallback warns exactly once on stderr without changing generator output" {
  local library="$SANDBOX/schema-warning-source" warning
  warning='trellis post-checkout generator: canonical schema unavailable; current-worktree fast path will reconcile'
  mkdir "$library"
  cp "$REPO_ROOT/scripts/lib/attachment.sh" "$library/attachment.sh"
  cp "$REPO_ROOT/scripts/lib/local-registry.sh" "$library/local-registry.sh"
  cp "$REPO_ROOT/scripts/lib/trellis-home.sh" "$library/trellis-home.sh"
  schema_generator_from_copy "$library" > "$SANDBOX/schema.stdout" 2> "$SANDBOX/schema.stderr"
  [ ! -s "$SANDBOX/schema.stderr" ] || { echo 'healthy extraction warned'; return 1; }

  python3 -I - "$library/attachment.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = path.read_text(encoding="utf-8")
before = '_attachment_mode() {\n  _attachment_stat_mode "$1"\n}\n'
after = '_attachment_mode() {\n  # Changed helper makes schema extraction unavailable.\n  _attachment_stat_mode "$1"\n}\n'
assert data.count(before) == 1
path.write_text(data.replace(before, after), encoding="utf-8")
PY
  schema_generator_from_copy "$library" > "$SANDBOX/schema.stdout" 2> "$SANDBOX/schema.stderr"
  grep -qx '^trellis_owner_schema_b64=$' "$SANDBOX/schema.stdout"
  grep -qx '^trellis_manifest_schema_b64=$' "$SANDBOX/schema.stdout"
  [ "$(wc -l < "$SANDBOX/schema.stderr" | tr -d ' ')" -eq 1 ]
  grep -Fxq "$warning" "$SANDBOX/schema.stderr"
  ! grep -Fq "$warning" "$SANDBOX/schema.stdout"

  # Missing source has the same conservative fallback and diagnostic.
  mv "$library/local-registry.sh" "$library/local-registry.absent"
  schema_generator_from_copy "$library" > "$SANDBOX/schema.stdout" 2> "$SANDBOX/schema.stderr"
  grep -qx '^trellis_owner_schema_b64=$' "$SANDBOX/schema.stdout"
  grep -qx '^trellis_manifest_schema_b64=$' "$SANDBOX/schema.stdout"
  [ "$(wc -l < "$SANDBOX/schema.stderr" | tr -d ' ')" -eq 1 ]
  grep -Fxq "$warning" "$SANDBOX/schema.stderr"
  ! grep -Fq "$warning" "$SANDBOX/schema.stdout"
}

@test "a duplicate render cannot hide owned settings drift" {
  local file="$PROJECT/.claude/settings.local.json"
  cp -p "$OWNER" "$SANDBOX/owner-valid.json"
  cp -p "$file" "$SANDBOX/settings-valid.json"
  drift_render '.claude/settings.local.json' '[]'
  jq '.renders += [(.renders[] | select(.path == ".claude/settings.local.json") | .owned_keys = [])]' \
    "$SANDBOX/owner-valid.json" > "$OWNER"
  assert_full
  cat "$SANDBOX/owner-valid.json" > "$OWNER"
  assert_full
  cat "$SANDBOX/settings-valid.json" > "$file"
  assert_fast
}

@test "an owned key drifted in either rendered settings file takes the full reconcile" {
  for path in .claude/settings.local.json .codex/hooks.json; do
    cp -p "$PROJECT/$path" "$SANDBOX/saved.json"
    drift_render "$path" '[]'
    assert_full
    cat "$SANDBOX/saved.json" > "$PROJECT/$path"
    assert_fast
  done
  # The guard list emptied, mode unchanged: the finding's exact scenario.
  jq '.hooks.PreToolUse = []' "$PROJECT/.claude/settings.local.json" > "$SANDBOX/drift.json"
  cat "$SANDBOX/drift.json" > "$PROJECT/.claude/settings.local.json"
  assert_full
}

@test "an owned Boolean read back as a number, or a number as a Boolean, takes the full reconcile" {
  local file="$PROJECT/.claude/settings.local.json" drift
  jq -e '.enableAllProjectMcpServers == true and .fixtureOwned.flags == [true, 0, {"on": false}]' "$file" >/dev/null
  cp -p "$file" "$SANDBOX/saved.json"
  assert_fast
  for drift in '.enableAllProjectMcpServers = 1' '.fixtureOwned.flags[0] = 1' \
      '.fixtureOwned.flags[1] = false' '.fixtureOwned.flags[2].on = 0'; do
    jq "$drift" "$SANDBOX/saved.json" > "$SANDBOX/drift.json"
    cat "$SANDBOX/drift.json" > "$file"
    assert_full
  done
  cat "$SANDBOX/saved.json" > "$file"
  assert_fast
}

# The owner-bound verifier a full attach runs, from the attached payload.
owner_verifier() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
_attachment_hooks_state_owned_matches "$2" "$3"' owner-verifier "$PAYLOAD" "$TRELLIS_HOME" "$OWNER"
}

# Applies one hook-state mutation (a shell snippet), requires the owner-bound
# verifier to reject it and the switch to take the full reconcile, then
# restores the saved state and requires both to accept again.
mutation_misses() {
  eval "$1"
  run owner_verifier
  [ "$status" -ne 0 ] || { echo "verifier accepted: $1"; return 1; }
  [ "$status" -ne 9 ] || { echo "verifier did not load"; return 1; }
  assert_missed || { echo "after: $1"; return 1; }
  restore_hook_state
  owner_verifier || { echo "verifier rejects the restored state: $1"; return 1; }
  assert_fast
}

restore_hook_state() {
  local name
  for name in previous-hooks-path release-payload pre-push-source; do
    cp -p "$SANDBOX/saved-hooks/$name" "$MANAGED/$name"
  done
  cp -p "$SANDBOX/saved-hooks/owner.json" "$OWNER"
}

# Rewrites the owner record through jq, keeping its mode.
edit_owner() {
  jq "$1" "$SANDBOX/saved-hooks/owner.json" > "$SANDBOX/owner.json"
  cat "$SANDBOX/owner.json" > "$OWNER"
}

@test "every hook-state change the owner-bound verifier rejects takes the full reconcile" {
  local name release="${PAYLOAD%/payload}"
  mkdir "$SANDBOX/saved-hooks" "$SANDBOX/prior-hooks"
  for name in previous-hooks-path release-payload pre-push-source; do
    cp -p "$MANAGED/$name" "$SANDBOX/saved-hooks/$name"
  done
  cp -p "$OWNER" "$SANDBOX/saved-hooks/owner.json"
  [ -z "$(jq -r '.git_hooks.previous_hooks_path // empty' "$OWNER")" ]
  [ "$(jq -r '.git_hooks.pre_push_source' "$OWNER")" = core-rules/githooks/pre-push ]
  owner_verifier
  assert_fast

  # Each sidecar, rewritten in place (mode 0600 kept) to a coherent value the
  # owner record does not name.
  mutation_misses 'printf "%s\n" "$SANDBOX/prior-hooks" > "$MANAGED/previous-hooks-path"'
  mutation_misses 'printf "%s\n" "$release/./payload" > "$MANAGED/release-payload"'
  mutation_misses 'printf "%s\n" core-rules/husky/pre-push > "$MANAGED/pre-push-source"'
  # The owner record's side of the same bindings.
  mutation_misses 'edit_owner ".git_hooks.managed_hooks_path = \"$SANDBOX/elsewhere\""'
  mutation_misses 'edit_owner ".git_hooks.previous_hooks_path = \"$SANDBOX/prior-hooks\""'
  # Not as a sidecar: the dispatcher runs the prior hook it names before any
  # check, so a sidecar naming the managed dir would run itself without end.
  mutation_misses 'edit_owner ".git_hooks.previous_hooks_path = \"$MANAGED\""'
  mutation_misses 'edit_owner ".git_hooks.pre_push_source = \"core-rules/husky/pre-push\""'

  # Hooks recorded as disabled: the verifier does not read the flag, but a
  # disabled record never vouches for a managed hook set, so this misses too.
  edit_owner '.git_hooks.enabled = false'
  assert_full
  restore_hook_state
  assert_fast

  # release.json changed and stamped again, as if a full verify had passed:
  # only the manifest the dispatchers were generated from can tell.
  cp -p "$release/release.json" "$SANDBOX/saved-hooks/release.json"
  chmod u+w "$release/release.json"
  printf '\n' >> "$release/release.json"
  chmod a-w "$release/release.json"
  stamp_release
  python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "$release" >/dev/null
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_missed
}

# Runs <code> with the attached payload's library loaded and P set to it.
payload_lib() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
P=$1
eval "$2"' payload-lib "$PAYLOAD" "$1"
}

@test "dispatcher generation rejects non-payload and symlink-aliased paths before loading code" {
  local fake="$SANDBOX/not-payload" real="$SANDBOX/real-release" alias="$SANDBOX/alias-release"
  local marker="$SANDBOX/foreign-generator-ran" candidate
  mkdir -p "$fake/scripts/lib" "$real/payload/scripts/lib"
  for candidate in "$fake/scripts/lib/attachment.sh" "$real/payload/scripts/lib/attachment.sh"; do
    cat > "$candidate" <<EOF
printf '%s\\n' reached > "$marker"
exit 91
EOF
  done
  ln -s "$real" "$alias"
  run payload_lib "_attachment_hooks_post_checkout_dispatcher_body $(printf '%q' "$fake") placeholder"
  [ "$status" -ne 0 ] && [ ! -e "$marker" ] || { echo 'invalid payload generator was executed'; false; }
  run payload_lib "_attachment_hooks_post_checkout_dispatcher_body $(printf '%q' "$alias/payload") placeholder"
  [ "$status" -ne 0 ] && [ ! -e "$marker" ] || { echo 'aliased payload generator was executed'; false; }

  # Even a provisional alias with no generator must not take the in-process
  # fallback: that would emit a dispatcher bound to an ambiguous payload.
  mkdir -p "$SANDBOX/empty-release/payload"
  printf '%s\n' '{"tree":[]}' > "$SANDBOX/empty-release/release.json"
  ln -s "$SANDBOX/empty-release" "$SANDBOX/alias-empty"
  run payload_lib "_attachment_hooks_post_checkout_dispatcher_body $(printf '%q' "$SANDBOX/alias-empty/payload") placeholder"
  [ "$status" -ne 0 ] || { echo 'aliased provisional payload was accepted'; false; }
}

@test "dispatcher generation refuses an exhausted recursion depth" {
  local foreign="$SANDBOX/foreign-release/payload" marker="$SANDBOX/second-hop-ran"
  run payload_lib 'TRELLIS_HOOK_GENERATOR_DEPTH=2; _attachment_hooks_post_checkout_dispatcher_body "$P" placeholder'
  [ "$status" -ne 0 ] || { echo 'exhausted generator depth was accepted'; false; }
  run payload_lib 'TRELLIS_HOOK_GENERATOR_DEPTH=1; _attachment_hooks_post_checkout_dispatcher_body "$P" placeholder >/dev/null'
  [ "$status" -eq 0 ] || { echo 'one verified cross-payload hop was refused'; false; }
  mkdir -p "$foreign/scripts/lib"
  cat > "$foreign/scripts/lib/attachment.sh" <<EOF
printf '%s\\n' reached > "$marker"
exit 91
EOF
  run payload_lib "TRELLIS_HOOK_GENERATOR_DEPTH=1; _attachment_hooks_post_checkout_dispatcher_body $(printf '%q' "$foreign") placeholder"
  [ "$status" -ne 0 ] && [ ! -e "$marker" ] || { echo 'second cross-payload hop was executed'; false; }
}

hook_memo() {
  find "$TRELLIS_HOME/state/hook-digests" -name '*.json' -type f
}

@test "the attach records a hook digest memo equal to the generator's output for every hook file" {
  local memo manifest source expected
  memo="$(hook_memo)"
  [ -n "$memo" ] && [ "$(printf '%s\n' "$memo" | wc -l)" -eq 1 ]
  [ "$(python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$memo")" = 600 ]
  manifest="$(shasum -a 256 "${PAYLOAD%/payload}/release.json" | cut -c1-64)"
  source="$(jq -r '.git_hooks.pre_push_source' "$OWNER")"
  [ "${memo##*/}" = "$manifest-$(printf '%s' "$source" | shasum -a 256 | cut -c1-64).json" ]
  jq -e --arg m "$manifest" --arg p "$PAYLOAD" --arg s "$source" \
    '.schema_version == 2 and .manifest_sha256 == $m and .payload == $p and .pre_push_source == $s' "$memo" >/dev/null

  # The names the library passes through, as the case pattern spells them,
  # are the list the memo is built from and exactly the keys of both shim maps.
  expected="$(sed -n '/^_attachment_hooks_is_passthrough_name() {/,/^}/p' "$PAYLOAD/scripts/lib/attachment.sh" |
    sed -n 's/^ *\([a-z0-9|-]*\)) return 0 ;;$/\1/p' | tr '|' '\n' | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$expected" | wc -l)" -ge 20 ]
  [ "$(payload_lib _attachment_hooks_passthrough_names | LC_ALL=C sort)" = "$expected" ]
  [ "$(jq -r '.shims | keys[]' "$memo" | LC_ALL=C sort)" = "$expected" ]
  [ "$(jq -r '.default_shims | keys[]' "$memo" | LC_ALL=C sort)" = "$expected" ]

  # Every digest is the regeneration path's own output, hashed as installed.
  expected="$(payload_lib '
manifest="$(_attachment_hooks_release_manifest_sha256 "$P")" || exit 1
digest() { python3 -I -c "import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"; }
printf "post_checkout %s\n" "$(printf "%s\n" "$(_attachment_hooks_post_checkout_dispatcher_body "$P" "$manifest")" | digest)"
printf "pre_push %s\n" "$(printf "%s\n" "$(_attachment_hooks_pre_push_dispatcher_body "$P" core-rules/githooks/pre-push "$manifest")" | digest)"
for name in $(_attachment_hooks_passthrough_names); do
  printf "shim:%s %s\n" "$name" "$(printf "%s\n" "$(_attachment_hooks_passthrough_shim_body "$name")" | digest)"
  printf "default:%s %s\n" "$name" "$(printf "%s\n" "$(_attachment_hooks_default_passthrough_shim_body "$name")" | digest)"
done' | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$expected" | wc -l)" -ge 42 ]
  [ "$(jq -r '"post_checkout \(.post_checkout)", "pre_push \(.pre_push)", (.shims | to_entries[] | "shim:\(.key) \(.value)"),
      (.default_shims | to_entries[] | "default:\(.key) \(.value)")' "$memo" | LC_ALL=C sort)" = "$expected" ]
  [ "$(shasum -a 256 "$MANAGED/post-checkout" | cut -c1-64)" = "$(jq -r .post_checkout "$memo")" ]
  [ "$(shasum -a 256 "$MANAGED/pre-push" | cut -c1-64)" = "$(jq -r .pre_push "$memo")" ]

  # A re-attach rebuilds the memo from the generator, even where the installed
  # files cannot vouch for an entry (no update hook is installed here).
  cp -p "$memo" "$SANDBOX/memo.json"
  jq '.shims.update = ("0" * 64)' "$SANDBOX/memo.json" > "$SANDBOX/memo-edit.json"
  cat "$SANDBOX/memo-edit.json" > "$memo"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  cmp "$memo" "$SANDBOX/memo.json"
}

@test "a missing safe digest memo is rebuilt from the verified generator and re-proved" {
  local memo
  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/memo-before.json"
  assert_fast
  rm -f "${memo:?}"
  assert_fast
  [ -f "$memo" ] && [ ! -L "$memo" ]
  [ "$(python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$memo")" = 600 ]
  cmp "$memo" "$SANDBOX/memo-before.json"
}

@test "a missing memo cannot conceal hook drift or pending adoption" {
  local memo checkout
  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/memo-before.json"
  cp -p "$MANAGED/pre-push" "$SANDBOX/pre-push-before"
  rm -f "${memo:?}"
  printf '# drift\n' >> "$MANAGED/pre-push"
  assert_full
  cp -p "$SANDBOX/pre-push-before" "$MANAGED/pre-push"
  cp -p "$SANDBOX/memo-before.json" "$memo"
  assert_fast

  rm -f "${memo:?}"
  checkout="$(jq -r .checkout_id "$OWNER")"
  mkdir -p "$TRELLIS_HOME/state/release-adoptions/$checkout"
  assert_full
  [ ! -e "$memo" ] && [ ! -L "$memo" ]
}

@test "missing memo with unsafe private ancestors is not rebuilt or repaired" {
  local memo directory mode
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  for directory in "${memo%/*}" "$TRELLIS_HOME/state" "$TRELLIS_HOME"; do
    chmod 755 "$directory"
    rm -f "$PROJECT/.reconciled"
    run git -C "$PROJECT" switch -q other
    local switch_status=$status
    git -C "$PROJECT" -c core.hooksPath=/dev/null switch -q "$BASE"
    [ "$switch_status" -ne 0 ] || [ -e "$PROJECT/.reconciled" ] || {
      echo "unsafe directory authorized the fast path: $directory"; return 1;
    }
    [ ! -e "$memo" ] && [ ! -L "$memo" ]
    mode="$(python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$directory")"
    [ "$mode" = 755 ] || { echo "unsafe directory was changed: $directory"; return 1; }
    chmod 700 "$directory"
  done
}

@test "a missing memo cannot rebuild across a simulated foreign scratch device" {
  local memo tools="$SANDBOX/foreign-device-bin" log="$SANDBOX/foreign-device.log"
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  mkdir "$tools"
  cat > "$tools/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] && [[ "${3:-}" == *'operation, stamp_home, release_dir, program'* ]]; then
  printf 'simulated-foreign-device\n' >> "$TRELLIS_T16_EXEC_LOG"
  export TMPDIR="${TRELLIS_T16_EXEC_LOG%/*}"
  exec /usr/bin/python3 -I - "$@" <<'PY'
import os, sys
program = sys.argv[3]
needle = 'operation, stamp_home, release_dir, program = sys.argv[1:5]\n'
injection = '''
_original_stat = os.stat
def _foreign_scratch_stat(path, *args, **kwargs):
    info = _original_stat(path, *args, **kwargs)
    if isinstance(path, str) and path.startswith("/") and os.path.basename(path).startswith(".trellis-generator-"):
        fields = list(info)
        fields[2] = info.st_dev + 1
        return os.stat_result(fields)
    return info
os.stat = _foreign_scratch_stat
'''
if program.count(needle) != 1:
    sys.exit(1)
program = program.replace(needle, injection + needle, 1)
os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-c', program] + sys.argv[4:])
PY
fi
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$tools/python3"
  run_extracted_current "$tools" "$log"
  grep -Fx simulated-foreign-device "$log"
  [ "$status" -ne 0 ] || { echo 'foreign scratch device authorized the fast path'; return 1; }
  [ ! -e "$memo" ] && [ ! -L "$memo" ] || { echo 'foreign scratch published a memo'; return 1; }
}

@test "a missing memo cannot rebuild with simulated coarse scratch ctime" {
  local memo tools="$SANDBOX/coarse-device-bin" log="$SANDBOX/coarse-device.log"
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  mkdir "$tools"
  cat > "$tools/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] && [[ "${3:-}" == *'operation, stamp_home, release_dir, program'* ]]; then
  printf 'simulated-coarse-ctime\n' >> "$TRELLIS_T16_EXEC_LOG"
  export TMPDIR="${TRELLIS_T16_EXEC_LOG%/*}"
  exec /usr/bin/python3 -I - "$@" <<'PY'
import os, sys
program = sys.argv[3]
needle = 'exec(compile(program, "<embedded-release-stamp>", "exec"), stamp)\n'
if program.count(needle) != 1:
    sys.exit(1)
program = program.replace(needle, needle + 'stamp["ctime_moves"] = lambda fd: False\n', 1)
os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-c', program] + sys.argv[4:])
PY
fi
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$tools/python3"
  run_extracted_current "$tools" "$log"
  grep -Fx simulated-coarse-ctime "$log"
  [ "$status" -ne 0 ] || { echo 'coarse scratch authorized the fast path'; return 1; }
  [ ! -e "$memo" ] && [ ! -L "$memo" ] || { echo 'coarse scratch published a memo'; return 1; }
}

@test "a re-stamped but oid-mismatched generator is never executed" {
  local memo generator="$PAYLOAD/scripts/lib/attachment.sh"
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  chmod u+w "$generator"
  printf '\n: > %q\n' "$SANDBOX/forged-generator-ran" >> "$generator"
  chmod a-w "$generator"
  # Test-only forged stamp: write it without the launchers full content audit.
  # This proves the separate release-manifest blob check, not stamp freshness.
  stamp_release
  [ "$(python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "${PAYLOAD%/payload}")" = hit ]
  assert_full
  [ ! -e "$SANDBOX/forged-generator-ran" ] || { echo 'oid-mismatched generator executed'; return 1; }
  [ ! -e "$memo" ] && [ ! -L "$memo" ] || { echo 'oid-mismatched generator published a memo'; return 1; }
}

@test "a missing memo never runs an altered unverified generator" {
  local memo generator="$PAYLOAD/scripts/lib/attachment.sh"
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  chmod u+w "$generator"
  printf '\n: > %q\n' "$SANDBOX/untrusted-generator-ran" >> "$generator"
  chmod a-w "$generator"
  assert_missed
  [ ! -e "$SANDBOX/untrusted-generator-ran" ]
  [ ! -e "$memo" ] && [ ! -L "$memo" ]
}

# In a private fixture, race after the generator snapshot appears, not before
# the initial missing-leaf check. The marker proves the race actually fired.
start_memo_racer() {
  /usr/bin/python3 -I - "$TRELLIS_HOME/state/scratch" "$1" "$2" "$SANDBOX/race-fired" <<'PY' &
import os, sys, time
root, action, target, marker = sys.argv[1:]
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    found = any(name.startswith(".trellis-generator-") for _, dirs, _ in os.walk(root) for name in dirs)
    if found:
        if action == "competing-memo":
            try:
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except FileExistsError:
                sys.exit("racer arrived after publication")
            with os.fdopen(fd, "wb") as out:
                out.write(b"competing memo must not be replaced\n")
        elif action == "changed-owner":
            with open(target, "ab") as out:
                out.write(b" \n")
        else:
            sys.exit("unknown race")
        with open(marker, "w") as out:
            out.write(action)
        sys.exit(0)
    time.sleep(0.005)
sys.exit("generator snapshot was not observed")
PY
  RACE_PID=$!
}

@test "a killed memo publication leaves no temporary in hook-digests" {
  local memo tools="$SANDBOX/kill-publish-bin" log="$SANDBOX/kill-publish.log"
  local -a residues=()
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  mkdir "$tools"
  cat > "$tools/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] && [[ "${3:-}" == *'operation, stamp_home, release_dir, program'* ]]; then
  export TMPDIR="${TRELLIS_T16_EXEC_LOG%/*}"
  exec /usr/bin/python3 -I - "$@" <<'PY'
import os, sys
program = sys.argv[3]
needle = '            # trellis-memo-publish-link: exclusive publication from private scratch.\n'
injection = '''            with open(os.environ["TRELLIS_T16_EXEC_LOG"], "a") as witness:
                witness.write("killed-at-publication\\n")
            os.kill(os.getpid(), 9)
'''
if program.count(needle) != 1:
    sys.exit(1)
program = program.replace(needle, injection + needle, 1)
os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-c', program] + sys.argv[4:])
PY
fi
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$tools/python3"
  run_extracted_current "$tools" "$log"
  grep -Fx killed-at-publication "$log"
  [ "$status" -ne 0 ]
  [ ! -e "$memo" ] && [ ! -L "$memo" ]
  shopt -s nullglob
  residues=("${memo%/*}/".memo-*)
  shopt -u nullglob
  [ "${#residues[@]}" -eq 0 ] || { printf 'leaked memo temporary: %s\n' "${residues[@]}"; return 1; }
  assert_fast
  [ -f "$memo" ] && [ ! -L "$memo" ] || { echo 'retry did not rebuild the memo'; return 1; }
}

# Replace the staging name at the last possible seam. The retry witness must
# not appear: a later reproof miss alone could leave attacker bytes published.
assert_staging_swap_missed() {
  local kind="$1" memo tools="$SANDBOX/staging-swap-bin" log="$SANDBOX/staging-swap.log" target
  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/canonical-memo.json"
  target="$SANDBOX/$kind"
  case "$kind" in
    garbage) printf 'not a hook digest memo\n' > "$target" ;;
    valid|inplace)
      python3 -I - "$SANDBOX/canonical-memo.json" "$target" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as src:
    value = json.load(src)
with open(sys.argv[2], 'w', encoding='utf-8') as dst:
    dst.write(json.dumps(value, indent=2, sort_keys=True) + '\n')
PY
      ! cmp -s "$SANDBOX/canonical-memo.json" "$target" ;;
    link) cp -p "$SANDBOX/canonical-memo.json" "$target" ;;
    *) return 1 ;;
  esac
  rm -f "${memo:?}"
  mkdir "$tools"
  cat > "$tools/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] && [[ "${3:-}" == *'operation, stamp_home, release_dir, program'* ]]; then
  export TMPDIR="${TRELLIS_T16_EXEC_LOG%/*}"
  exec /usr/bin/python3 -I - "$@" <<'PY'
import os, sys
program = sys.argv[3]
needle = '            # trellis-memo-publish-link: exclusive publication from private scratch.\n'
retry = '    # This is a retry request, not an authorization.'
swap = '''            with open(os.environ["TRELLIS_T16_EXEC_LOG"], "a") as witness:
                witness.write("swapped-staging-leaf\\n")
            replacement = os.environ["TRELLIS_T16_RACE_FILE"]
            kind = os.path.basename(replacement)
            if kind != "inplace":
                os.unlink(temporary, dir_fd=staging_fd)
            if kind == "link":
                os.symlink(replacement, temporary, dir_fd=staging_fd)
            else:
                flags = os.O_WRONLY | os.O_NOFOLLOW
                flags |= os.O_TRUNC if kind == "inplace" else os.O_CREAT | os.O_EXCL
                fd = os.open(temporary, flags, 0o600, dir_fd=staging_fd)
                with os.fdopen(fd, "wb") as out_file, open(replacement, "rb") as source_file:
                    out_file.write(source_file.read())
'''
mark = '''    with open(os.environ["TRELLIS_T16_EXEC_LOG"], "a") as witness:
        witness.write("reached-retry-marker\\n")
'''
if program.count(needle) != 1 or program.count(retry) != 1:
    sys.exit(1)
program = program.replace(needle, swap + needle, 1).replace(retry, mark + retry, 1)
os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-c', program] + sys.argv[4:])
PY
fi
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$tools/python3"
  run_extracted_current "$tools" "$log" "$target"
  grep -Fx swapped-staging-leaf "$log"
  [ -e "$memo" ] || [ -L "$memo" ] || { echo 'swap did not reach publication'; return 1; }
  ! grep -Fx reached-retry-marker "$log" || { echo 'staging swap reached retry marker'; return 1; }
  [ "$status" -ne 0 ] || { echo 'staging swap authorized the fast path'; return 1; }
}

@test "a swapped garbage staging file never reaches the retry marker" {
  assert_staging_swap_missed garbage
}

@test "a swapped different valid memo never reaches the retry marker" {
  assert_staging_swap_missed valid
}

@test "a swapped staging symlink never reaches the retry marker" {
  assert_staging_swap_missed link
}

@test "an in-place staging mutation never reaches the retry marker" {
  assert_staging_swap_missed inplace
}

@test "a competitor appearing immediately before publication is never overwritten" {
  local memo tools="$SANDBOX/link-race-bin" log="$SANDBOX/link-race.log"
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  mkdir "$tools"
  cat > "$tools/python3" <<'SH'
#!/bin/bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] && [[ "${3:-}" == *'operation, stamp_home, release_dir, program'* ]]; then
  printf 'injected-at-publication\n' >> "$TRELLIS_T16_EXEC_LOG"
  export TMPDIR="${TRELLIS_T16_EXEC_LOG%/*}"
  exec /usr/bin/python3 -I - "$@" <<'PY'
import os, sys
program = sys.argv[3]
needle = '            # trellis-memo-publish-link: exclusive publication from private scratch.\n'
injection = '''            race_fd = os.open(memo_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
            with os.fdopen(race_fd, "wb") as race_file:
                race_file.write(b"competitor at publication\\n")
'''
if program.count(needle) != 1:
    sys.exit(1)
program = program.replace(needle, injection + needle, 1)
os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-c', program] + sys.argv[4:])
PY
fi
exec /usr/bin/python3 "$@"
SH
  chmod 700 "$tools/python3"
  run_extracted_current "$tools" "$log"
  grep -Fx injected-at-publication "$log"
  [ "$status" -ne 0 ] || { echo 'competing publication authorized the fast path'; return 1; }
  [ -f "$memo" ] && [ ! -L "$memo" ]
  [ "$(<"$memo")" = 'competitor at publication' ] || { echo 'competing memo overwritten'; return 1; }
}

@test "a competing memo during generator publication is never overwritten" {
  local memo
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  start_memo_racer competing-memo "$memo"
  round_trip
  wait "$RACE_PID"
  [ "$(<"$SANDBOX/race-fired")" = competing-memo ]
  [ -e "$PROJECT/.reconciled" ] || { echo 'raced memo authorized the fast path'; return 1; }
  [ "$(<"$memo")" = 'competing memo must not be replaced' ]
}

@test "owner changed during generator work cannot publish a memo or authorize the fast path" {
  local memo
  memo="$(hook_memo)"
  rm -f "${memo:?}"
  start_memo_racer changed-owner "$OWNER"
  round_trip
  wait "$RACE_PID"
  [ "$(<"$SANDBOX/race-fired")" = changed-owner ]
  [ -e "$PROJECT/.reconciled" ] || { echo 'raced owner authorized the fast path'; return 1; }
  [ ! -e "$memo" ] && [ ! -L "$memo" ]
}

@test "a private-mode-broken or mismatched hook digest memo takes the full reconcile" {
  local memo edit
  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/memo.json"
  assert_fast
  chmod 644 "$memo"
  assert_full
  chmod 600 "$memo"
  for edit in '.post_checkout = ("0" * 64)' '.pre_push = ("0" * 64)' '.payload = "/elsewhere/payload"' \
      '.manifest_sha256 = ("0" * 64)' '.pre_push_source = "core-rules/husky/pre-push"' '.schema_version = 1' \
      '.schema_version = 3' '.schema_version = true' '.shims = []' '.shims["pre-commit"] = "not-a-digest"' '.extra = 1' \
      'del(.shims)' '.default_shims = []' '.default_shims["pre-commit"] = "not-a-digest"' 'del(.default_shims)'; do
    jq "$edit" "$SANDBOX/memo.json" > "$SANDBOX/memo-edit.json"
    cat "$SANDBOX/memo-edit.json" > "$memo"
    assert_full || { echo "after: $edit"; false; }
  done
  # Valid JSON with the right digests, but over the 64 KiB cap.
  { cat "$SANDBOX/memo.json"; head -c 70000 /dev/zero | tr '\0' ' '; } > "$SANDBOX/memo-edit.json"
  cat "$SANDBOX/memo-edit.json" > "$memo"
  assert_full
  cat "$SANDBOX/memo.json" > "$memo"
  assert_fast

  # A link to a good memo, never followed.
  cp -p "$SANDBOX/memo.json" "$SANDBOX/memo-target.json"
  rm "$memo"
  ln -s "$SANDBOX/memo-target.json" "$memo"
  assert_full
  rm "$memo"
  cp -p "$SANDBOX/memo.json" "$memo"
  # The directory: another mode, or a link to a good copy.
  chmod 755 "${memo%/*}"
  assert_full
  chmod 700 "${memo%/*}"
  mv "${memo%/*}" "$SANDBOX/hook-digests"
  ln -s "$SANDBOX/hook-digests" "${memo%/*}"
  assert_full
  rm "${memo%/*}"
  mv "$SANDBOX/hook-digests" "${memo%/*}"
  assert_fast
}

@test "with a predecessor, the attach installs exactly the shims it calls for, as the memo and the generator have them" {
  local second="$SANDBOX/second" prior="$SANDBOX/second-hooks" owner managed memo base name expected
  mkdir "$prior"
  for name in pre-commit commit-msg; do
    printf '#!/bin/sh\nexit 0\n' > "$prior/$name"
    chmod 755 "$prior/$name"
  done
  printf '#!/bin/sh\nexit 0\n' > "$prior/not-a-hook"
  chmod 755 "$prior/not-a-hook"
  git init -q "$second"
  git -C "$second" config user.name fixture
  git -C "$second" config user.email fixture@example.invalid
  git -C "$second" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"u5-second"}\n' > "$second/.trellis.json"
  git -C "$second" add .trellis.json
  git -C "$second" -c core.hooksPath=/dev/null commit -qm initial
  base="$(git -C "$second" symbolic-ref --short HEAD)"
  git -C "$second" -c core.hooksPath=/dev/null checkout -q -b other
  printf 'other\n' > "$second/src.txt"
  git -C "$second" add src.txt
  git -C "$second" -c core.hooksPath=/dev/null commit -qm other
  git -C "$second" -c core.hooksPath=/dev/null checkout -q "$base"
  git -C "$second" config core.hooksPath "$prior"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$second" >/dev/null
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f -exec jq -r --arg root "$second" \
    'select(.worktree_root == $root) | input_filename' {} \;)"
  [ -n "$owner" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$prior" ]
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ "$(ls -A "$managed" | LC_ALL=C sort | tr '\n' ' ')" = \
    "commit-msg post-checkout pre-commit pre-push pre-push-source previous-hooks-path release-payload " ]

  # One memo serves both checkouts: same release, same source.
  memo="$(hook_memo)"
  [ "$(printf '%s\n' "$memo" | wc -l)" -eq 1 ]
  expected="$(payload_lib '
digest() { python3 -I -c "import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"; }
for name in commit-msg pre-commit; do
  printf "%s %s\n" "$name" "$(printf "%s\n" "$(_attachment_hooks_passthrough_shim_body "$name")" | digest)"
done')"
  [ "$(jq -r '.shims | to_entries[] | select(.key == "commit-msg" or .key == "pre-commit") | "\(.key) \(.value)"' "$memo" |
    LC_ALL=C sort)" = "$expected" ]
  for name in commit-msg pre-commit; do
    [ "$name $(shasum -a 256 "$managed/$name" | cut -c1-64)" = "$(printf '%s\n' "$expected" | grep "^$name ")" ]
  done
  [ "$(shasum -a 256 "$managed/post-checkout" | cut -c1-64)" = "$(jq -r .post_checkout "$memo")" ]
  [ "$(shasum -a 256 "$managed/pre-push" | cut -c1-64)" = "$(jq -r .pre_push "$memo")" ]

  # And that layout takes the fast path.
  rm -f "$second/.reconciled"
  git -C "$second" switch -q other
  git -C "$second" -c core.hooksPath=/dev/null switch -q "$base"
  [ ! -e "$second/.reconciled" ]
}

@test "the shims a predecessor calls for are checked against the memo, as the owner-bound verifier checks them" {
  local prior="$SANDBOX/prior-hooks"
  mkdir "$prior"
  printf '#!/bin/sh\nexit 0\n' > "$prior/pre-commit"
  chmod 755 "$prior/pre-commit"
  jq --arg prior "$prior" '.git_hooks.previous_hooks_path = $prior' "$OWNER" > "$SANDBOX/owner.json"
  cat "$SANDBOX/owner.json" > "$OWNER"
  printf '%s\n' "$prior" > "$MANAGED/previous-hooks-path"
  (umask 077 && payload_lib 'printf "%s\n" "$(_attachment_hooks_passthrough_shim_body pre-commit)"' > "$MANAGED/pre-commit")
  chmod 700 "$MANAGED/pre-commit"
  cp -p "$MANAGED/pre-commit" "$SANDBOX/pre-commit"
  owner_verifier
  assert_fast

  printf '# drift\n' >> "$MANAGED/pre-commit"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full
  cp -p "$SANDBOX/pre-commit" "$MANAGED/pre-commit"
  assert_fast

  # A predecessor hook no longer executable: its shim is now unexpected.
  chmod 644 "$prior/pre-commit"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full
  chmod 755 "$prior/pre-commit"

  # A predecessor hook with no shim yet.
  printf '#!/bin/sh\nexit 0\n' > "$prior/commit-msg"
  chmod 755 "$prior/commit-msg"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full
}

@test "a memo missing a predecessor hook name cannot hide its missing managed shim" {
  local prior="$SANDBOX/prior-hooks" memo
  mkdir "$prior"
  printf '#!/bin/sh\nexit 0\n' > "$prior/pre-commit"
  chmod 700 "$prior/pre-commit"
  jq --arg prior "$prior" '.git_hooks.previous_hooks_path = $prior' "$OWNER" > "$SANDBOX/owner.json"
  cat "$SANDBOX/owner.json" > "$OWNER"
  printf '%s\n' "$prior" > "$MANAGED/previous-hooks-path"
  (umask 077 && payload_lib 'printf "%s\n" "$(_attachment_hooks_passthrough_shim_body pre-commit)"' > "$MANAGED/pre-commit")
  chmod 700 "$MANAGED/pre-commit"
  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/memo-complete.json"
  owner_verifier
  assert_fast

  jq 'del(.shims["pre-commit"])' "$SANDBOX/memo-complete.json" > "$SANDBOX/memo-incomplete.json"
  cat "$SANDBOX/memo-incomplete.json" > "$memo"
  rm -f "${MANAGED:?}/pre-commit"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full

  cat "$SANDBOX/memo-complete.json" > "$memo"
  (umask 077 && payload_lib 'printf "%s\n" "$(_attachment_hooks_passthrough_shim_body pre-commit)"' > "$MANAGED/pre-commit")
  chmod 700 "$MANAGED/pre-commit"
  assert_fast
  jq 'del(.default_shims["pre-commit"])' "$SANDBOX/memo-complete.json" > "$SANDBOX/memo-incomplete.json"
  cat "$SANDBOX/memo-incomplete.json" > "$memo"
  assert_full
}

@test "a missing, changed or non-executable managed pre-push takes the full reconcile" {
  cp -p "$MANAGED/pre-push" "$SANDBOX/pre-push"
  rm "$MANAGED/pre-push"
  assert_full
  cp -p "$SANDBOX/pre-push" "$MANAGED/pre-push"
  assert_fast

  printf '# drift\n' >> "$MANAGED/pre-push"
  assert_full
  cp -p "$SANDBOX/pre-push" "$MANAGED/pre-push"

  chmod 600 "$MANAGED/pre-push"
  assert_full
  chmod 700 "$MANAGED/pre-push"
  assert_fast

  git -C "$PROJECT" config --local --add core.hooksPath "$MANAGED"
  assert_full
}

@test "an unstaged or staged manifest change, or a committed identity change, takes the full reconcile" {
  # Same identity, other policy: only the working-tree state can tell.
  printf '{"schema_version":1,"project_id":"u5-fixture","gate":{"env_passthrough":["APP_MODE"]}}\n' \
    > "$PROJECT/.trellis.json"
  assert_full

  git -C "$PROJECT" add .trellis.json
  assert_full
  git -C "$PROJECT" reset -q -- .trellis.json
  git -C "$PROJECT" checkout -- .trellis.json
  assert_fast

  printf '{"schema_version":1,"project_id":"different-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json

  # Committed on both sides of the switch: the diff is silent, the identity is not.
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm 'fixture identity'
  git -C "$PROJECT" -c core.hooksPath=/dev/null branch -f other HEAD
  git -C "$PROJECT" -c core.hooksPath=/dev/null checkout -q other
  printf 'other\n' > "$PROJECT/src.txt"
  git -C "$PROJECT" add src.txt
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm other
  git -C "$PROJECT" -c core.hooksPath=/dev/null checkout -q "$BASE"
  [ -z "$(git -C "$PROJECT" status --porcelain -- .trellis.json)" ]
  assert_full
}

# 1.5.1 perf: a linked worktree's owner records no hook state (git_hooks
# enabled false); the checkout's hooks-enabled owner does. The current-worktree
# proof binds its hook checks to that owner, as the full reconcile verifies it.
attach_linked() {
  LINKED="$SANDBOX/linked"
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q -b linked "$LINKED" "$BASE"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$LINKED" >/dev/null
  LINKED_OWNER="$(dirname "$OWNER")/$(printf '%s' "$LINKED" | shasum -a 256 | cut -d' ' -f1).json"
  [ -f "$LINKED_OWNER" ] || { echo "no linked owner $LINKED_OWNER"; return 1; }
  [ "$(jq -r '.git_hooks.enabled' "$LINKED_OWNER")" = false ] || { echo 'linked owner holds hooks'; return 1; }
  git -C "$LINKED" branch -q linked-other other
}

# Switch the linked worktree to linked-other and back with hooks on.
linked_round_trip() {
  rm -f "$LINKED/.reconciled"
  run git -C "$LINKED" switch -q linked-other
  [ "$status" -eq 0 ] || { printf 'switch: %s\n%s\n' "$status" "$output"; return 1; }
  git -C "$LINKED" -c core.hooksPath=/dev/null switch -q linked
}

# Rewrites the main (hooks-enabled) owner record through jq, keeping its mode.
edit_main_owner() {
  jq -c "$1" "$OWNER" > "$SANDBOX/owner.next"
  cat "$SANDBOX/owner.next" > "$OWNER"
}

@test "a current linked worktree takes the fast path through the checkout's hooks-enabled owner" {
  attach_linked
  linked_round_trip
  [ ! -e "$LINKED/.reconciled" ] || { echo 'full reconcile ran in the linked worktree'; printf '%s\n' "$output"; false; }
  # The main worktree's own fast path is unchanged.
  assert_fast
}

@test "a linked worktree takes the full reconcile when the enabled owner's hook record drifts" {
  attach_linked
  edit_main_owner '.git_hooks.previous_hooks_path = "/nonexistent-hooks"'
  linked_round_trip
  [ -e "$LINKED/.reconciled" ] || { echo 'fast path taken with a drifted hook record'; false; }
}

@test "a linked worktree takes the full reconcile with no hooks-enabled owner in its checkout" {
  attach_linked
  edit_main_owner '.git_hooks = {"enabled": false}'
  linked_round_trip
  [ -e "$LINKED/.reconciled" ] || { echo 'fast path taken with no hooks-enabled owner'; false; }
}

@test "a linked worktree takes the full reconcile when its checkout holds an unexpected owner entry" {
  attach_linked
  printf '{}\n' > "$(dirname "$OWNER")/stray.json"
  chmod 600 "$(dirname "$OWNER")/stray.json"
  linked_round_trip
  [ -e "$LINKED/.reconciled" ] || { echo 'fast path taken beside an unexpected owner entry'; false; }
}

@test "a linked worktree takes the full reconcile when the enabled owner is on another release" {
  attach_linked
  edit_main_owner '.release = "9.0.2"'
  linked_round_trip
  [ -e "$LINKED/.reconciled" ] || { echo 'fast path taken across releases'; false; }
}

# Guard: the repository's own libraries must yield both canonical schemas.
# "canonical schema unavailable" turns the current-worktree fast path off for
# every worktree while every check still passes (it fails closed to the full
# reconcile), so a refactor of the validators must fail here, not degrade.
@test "the repository's generator extracts both canonical schemas and never warns" {
  local owner_b64 owner_schema
  run --separate-stderr schema_generator_from_copy "$REPO_ROOT/scripts/lib"
  [ "$status" -eq 0 ] || { printf '%s\n%s\n' "$output" "$stderr"; false; }
  [ -z "$stderr" ] || { echo "generator warned: $stderr"; false; }
  owner_b64="$(printf '%s\n' "$output" | sed -n 's/^trellis_owner_schema_b64=//p')"
  [ -n "$owner_b64" ] || { echo 'no owner schema'; false; }
  printf '%s\n' "$output" | grep -Eq '^trellis_manifest_schema_b64=.+$' || { echo 'no manifest schema'; false; }
  # The extracted owner schema is the expression the per-file check runs.
  owner_schema="$(printf '%s' "$owner_b64" | base64 --decode 2>/dev/null || printf '%s' "$owner_b64" | base64 -D)"
  run bash -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1; printf "%s" "$_attachment_owner_schema_filter"' _ "$REPO_ROOT"
  # The variable's value opens with the newline after its quote.
  [ "$output" = $'\n'"$owner_schema" ] || { echo 'extracted owner schema differs from _attachment_owner_schema_filter'; false; }
}

@test "an attach writes a dispatcher that carries both schemas, without the fallback warning" {
  local managed
  rm -rf "$MANAGED"
  run --separate-stderr "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n%s\n' "$output" "$stderr"; false; }
  [[ "$stderr" != *"canonical schema unavailable"* ]] || { echo "$stderr"; false; }
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  grep -Eq '^trellis_owner_schema_b64=.+$' "$managed/post-checkout" || { echo 'dispatcher lacks the owner schema'; false; }
  grep -Eq '^trellis_manifest_schema_b64=.+$' "$managed/post-checkout" || { echo 'dispatcher lacks the manifest schema'; false; }
}
