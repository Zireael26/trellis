#!/usr/bin/env bats
# 1.5.2 perf item 4: attachment_verify for many owners in one pass.
#
# attachment_verify_owners_batch must pass exactly the owners attachment_verify
# passes, and the in-process verifier (scripts/lib/owner_verify.py) must name
# each refusal with the status and diagnostic the shell verifier gives at that
# check. Every case below drifts one thing and runs all three.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# shellcheck source=helpers/release-fixture.bash
. "$REPO_ROOT/scripts/tests/helpers/release-fixture.bash"
. "$REPO_ROOT/scripts/tests/helpers/doctor-wait-postjobs.bash"

setup_file() {
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$BATS_FILE_TMPDIR")/prototype"
  mkdir -p "$RELEASE_FIXTURE_PROTOTYPE"
  RELEASE_FIXTURE_PROTOTYPE="$(release_fixture_canonical_dir "$RELEASE_FIXTURE_PROTOTYPE")"
  export RELEASE_FIXTURE_PROTOTYPE
  release_fixture_prototype_build "$RELEASE_FIXTURE_PROTOTYPE"
}

teardown_file() {
  chmod -R u+w "$RELEASE_FIXTURE_PROTOTYPE" 2>/dev/null || true
  rm -rf "$RELEASE_FIXTURE_PROTOTYPE"
}

setup() {
  export TRELLIS_ATTACH_POSTJOB=off
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/owner-verify.XXXXXX")"
  SANDBOX="$(release_fixture_canonical_dir "$SANDBOX")"
  HOME="$SANDBOX/user"
  TRELLIS_HOME="$SANDBOX/trellis"
  PROJECT="$SANDBOX/project"
  LINKED="$SANDBOX/linked"
  export HOME TRELLIS_HOME
  release_fixture_prototype_clone "$RELEASE_FIXTURE_PROTOTYPE" "$SANDBOX"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"owner-verify"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm initial
  LAUNCHER="$HOME/.local/bin/trellis"
  PAYLOAD="$TRELLIS_HOME/releases/9.9.9/payload"
  run "$LAUNCHER" attach --fleet personal "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q -b linked "$LINKED"
  run "$LAUNCHER" attach --fleet personal "$LINKED"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  OWNERS="$(dirname "$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f | head -n 1)")"
  MAIN_OWNER="$OWNERS/$(printf '%s' "$PROJECT" | shasum -a 256 | cut -d' ' -f1).json"
  LINKED_OWNER="$OWNERS/$(printf '%s' "$LINKED" | shasum -a 256 | cut -d' ' -f1).json"
  [ -f "$MAIN_OWNER" ] && [ -f "$LINKED_OWNER" ] || { echo "owners missing"; return 1; }
}

teardown() {
  local i
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rm -rf "$SANDBOX" 2>/dev/null && break
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    sleep 1
  done
  rm -rf "$SANDBOX"
}

# The shell verifier's own status (before public mapping) and stderr.
shell_verify() {
  SHELL_STATUS=0
  SHELL_STDERR="$(env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    _attachment_verify_impl "$2" "$3"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$1" 2>&1 >/dev/null)" || SHELL_STATUS=$?
}

batch_verify() {
  BATCH_STATUS=0
  BATCH_OUTPUT="$(env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    home=$2; shift 2
    attachment_verify_owners_batch "$home" "$@"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$@" 2>&1)" || BATCH_STATUS=$?
}

# In-process failures for the given owners, one JSON line each, plus the
# diagnostic render_failure gives for each, as {"failure":..,"rendered":..}.
inprocess_verify() {
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    lib=$1/scripts/lib home=$2; shift 2
    jq -cS -n --arg home "$home" --argjson expected "$(_attachment_paths_json "$@")" "$_attachment_exact_inputs_def
      [exact_inputs | .path as \$path | .record | {path: \$path, record: null, data: null,
        valid: (try ($_attachment_owner_schema_filter) catch false),
        canonical: (try (\$path == (\$home + \"/state/attachments/\" + .checkout_id + \"/\" + .worktree_id + \".json\")) catch false)}]
    " "$@" | /usr/bin/env TRELLIS_SETTINGS_OWNED_JSON_PROGRAM="$(_settings_owned_json_program)" LC_ALL=C python3 -I -c "
import importlib.util, json, os, sys
lib, home = sys.argv[1:3]
spec = importlib.util.spec_from_file_location(\"owner_verify\", lib + \"/owner_verify.py\")
ov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ov)
ov.load(ov.load_modules(lib + \"/attachment_fs.py\"), os.environ[\"TRELLIS_SETTINGS_OWNED_JSON_PROGRAM\"])
for failure in ov.verify_owner_records(home, json.load(sys.stdin)):
    print(json.dumps({\"failure\": failure, \"rendered\": ov.render_failure(failure).decode()}, sort_keys=True))
" "$lib" "$home"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$@"
}

# One owner drifted: the batch refuses, the shell refuses, and the in-process
# failure carries the shell's status, the expected check, and its diagnostic.
assert_parity() {
  local owner=$1 check=$2 line status rendered
  batch_verify "$MAIN_OWNER" "$LINKED_OWNER"
  [ "$BATCH_STATUS" -eq 10 ] || { echo "batch status $BATCH_STATUS: $BATCH_OUTPUT"; return 1; }
  [ -z "$BATCH_OUTPUT" ] || { echo "batch printed: $BATCH_OUTPUT"; return 1; }
  shell_verify "$owner"
  [ "$SHELL_STATUS" -ne 0 ] || { echo "the shell verifier passed the drifted owner"; return 1; }
  line="$(inprocess_verify "$owner")"
  [ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 ] || { echo "in-process: $line"; return 1; }
  [ "$(printf '%s\n' "$line" | jq -r '.failure.check')" = "$check" ] || { echo "in-process: $line"; return 1; }
  status="$(printf '%s\n' "$line" | jq -r '.failure.status')"
  [ "$status" -eq "$SHELL_STATUS" ] || { echo "status in-process $status shell $SHELL_STATUS"; return 1; }
  rendered="$(printf '%s\n' "$line" | jq -j '.rendered')"
  [ "$rendered" = "$SHELL_STDERR" ] || { printf 'rendered <%s>\nshell    <%s>\n' "$rendered" "$SHELL_STDERR"; return 1; }
}

# Rewrites an owner record through jq, keeping its mode and inode.
edit_owner() {
  local file=$1
  shift
  jq -c "$@" "$file" > "$SANDBOX/owner.next"
  cat "$SANDBOX/owner.next" > "$file"
}

first_artifact() {
  jq -r --arg kind "$2" '
    ((.renders // []) | map(.path)) as $renders
    | [.artifacts[] | select(.kind == $kind and ((.path as $p | $renders | index($p)) == null))][0].path // empty
  ' "$1"
}

@test "healthy owners pass the batch, the shell and the in-process verifier" {
  batch_verify "$MAIN_OWNER" "$LINKED_OWNER"
  [ "$BATCH_STATUS" -eq 0 ] || { echo "$BATCH_OUTPUT"; false; }
  shell_verify "$MAIN_OWNER"; [ "$SHELL_STATUS" -eq 0 ] || { echo "$SHELL_STDERR"; false; }
  shell_verify "$LINKED_OWNER"; [ "$SHELL_STATUS" -eq 0 ] || { echo "$SHELL_STDERR"; false; }
  [ -z "$(inprocess_verify "$MAIN_OWNER" "$LINKED_OWNER")" ] || false
}

@test "a retargeted owned symlink is refused with the shell's status and diagnostic" {
  local relative
  relative="$(first_artifact "$LINKED_OWNER" symlink)"
  [ -n "$relative" ] || skip "fixture has no symlink artifact"
  ln -sfn /nonexistent-target "$LINKED/$relative"
  assert_parity "$LINKED_OWNER" artifact
}

@test "a removed owned symlink is refused with the shell's status and diagnostic" {
  local relative
  relative="$(first_artifact "$LINKED_OWNER" symlink)"
  rm -f "$LINKED/$relative"
  assert_parity "$LINKED_OWNER" artifact
}

@test "an owned symlink replaced by a regular file is refused" {
  local relative
  relative="$(first_artifact "$LINKED_OWNER" symlink)"
  rm -f "$LINKED/$relative"
  printf 'project file\n' > "$LINKED/$relative"
  assert_parity "$LINKED_OWNER" artifact
}

@test "a symlinked artifact parent is refused" {
  local relative parent
  relative="$(jq -r '[.artifacts[] | select(.kind == "symlink" and (.path | contains("/")))][0].path' "$LINKED_OWNER")"
  parent="$LINKED/${relative%/*}"
  mv "$parent" "$parent.moved"
  ln -s "$parent.moved" "$parent"
  assert_parity "$LINKED_OWNER" artifact
}

@test "a drifted owned render key is refused with the shell's status and diagnostic" {
  local relative key
  relative="$(jq -r '.renders[0].path' "$LINKED_OWNER")"
  key="$(jq -c '.renders[0].owned_keys[0].path' "$LINKED_OWNER")"
  jq --argjson key "$key" 'setpath($key; "drifted")' "$LINKED/$relative" > "$SANDBOX/render.json"
  cat "$SANDBOX/render.json" > "$LINKED/$relative"
  assert_parity "$LINKED_OWNER" render
}

@test "a render with a changed mode is refused" {
  local relative
  relative="$(jq -r '.renders[0].path' "$LINKED_OWNER")"
  chmod 644 "$LINKED/$relative"
  assert_parity "$LINKED_OWNER" render
}

@test "a render with a duplicate JSON key is refused" {
  local relative
  relative="$(jq -r '.renders[0].path' "$LINKED_OWNER")"
  python3 - "$LINKED/$relative" <<'PY'
import sys
path = sys.argv[1]
data = open(path).read().rstrip()
assert data.endswith("}")
open(path, "w").write(data[:-1] + ', "hooks": {}}\n')
PY
  assert_parity "$LINKED_OWNER" render
}

@test "an owner file with mode 0644 is refused with status 3 and no diagnostic" {
  chmod 644 "$LINKED_OWNER"
  assert_parity "$LINKED_OWNER" owner-file
}

@test "a vanished worktree root is refused with the shell's diagnostic" {
  mv "$LINKED" "$LINKED.moved"
  assert_parity "$LINKED_OWNER" worktree-root
}

@test "a record whose project root is not canonical is refused" {
  ln -s "$SANDBOX" "$SANDBOX/alias"
  edit_owner "$LINKED_OWNER" --arg x "$SANDBOX/alias/linked" '.project_root = $x'
  assert_parity "$LINKED_OWNER" roots
}

@test "a record whose render pairing differs is refused" {
  edit_owner "$LINKED_OWNER" '.renders[0].after_sha256 = ("0" * 64)'
  assert_parity "$LINKED_OWNER" render-pairings
}

@test "a record whose render context names another launcher is refused" {
  jq -e '.render_context != null' "$LINKED_OWNER" >/dev/null || skip "fixture records no render context"
  edit_owner "$LINKED_OWNER" '.render_context.launcher_shell = "'"'"'/elsewhere'"'"'"'
  assert_parity "$LINKED_OWNER" render-context
}

@test "a drifted managed hook of the hooks-enabled owner fails the batch" {
  local managed
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$MAIN_OWNER")"
  chmod u+w "$managed/post-checkout"
  printf '# drift\n' >> "$managed/post-checkout"
  batch_verify "$MAIN_OWNER" "$LINKED_OWNER"
  [ "$BATCH_STATUS" -eq 10 ] || { echo "batch status $BATCH_STATUS"; false; }
  shell_verify "$MAIN_OWNER"
  [ "$SHELL_STATUS" -ne 0 ] || false
}

@test "a batch with a missing owner path refuses" {
  batch_verify "$MAIN_OWNER" "$OWNERS/$(printf '%064d' 0).json"
  [ "$BATCH_STATUS" -eq 10 ] || false
}

# sync on a healthy fleet takes the batch pass: no row runs its own owner
# verification. Without the batch every row runs _attachment_verify_impl.
# xtrace goes to its own descriptor: the per-row verify runs with stderr
# discarded, which would hide its trace lines from a 2>&1 capture.
run_sync_traced() {
  SYNC_TRACE="$SANDBOX/sync.trace"
  run env TRELLIS_HOME="$TRELLIS_HOME" PS4='+ ' bash -c '
    exec 9>"$1"
    export BASH_XTRACEFD=9
    exec bash -x "$2" --home "$3" --dry-run
  ' _ "$SYNC_TRACE" "$PAYLOAD/scripts/sync-hooks.sh" "$TRELLIS_HOME"
}

verify_impl_calls() {
  grep -c '^+* _attachment_verify_impl ' "$SYNC_TRACE" || true
}

# The call counts read xtrace from its own descriptor, which needs
# BASH_XTRACEFD (Bash 4.1+). On an older bash the trace would land on the
# discarded stderr and a zero count would pass vacuously, so the count is
# skipped there after the behavioural checks ran; Bash 5 is the shell of record.
require_xtrace_fd() {
  bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }' ||
    skip "call counting needs BASH_XTRACEFD (Bash 4.1+); counted under Bash 5"
}

@test "sync verifies a healthy fleet's owners in one batch, not row by row" {
  run_sync_traced
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | grep -v '^+' | tail -20; false; }
  [[ "$output" == *"(in sync: attached immutable release 9.9.9)"* ]] || { printf '%s\n' "$output" | grep -v '^+'; false; }
  require_xtrace_fd
  [ "$(verify_impl_calls)" -eq 0 ] || {
    echo "per-row owner verification ran"; false; }
}

@test "sync on a drifted fleet still verifies each row and reports the drift" {
  local relative
  relative="$(first_artifact "$LINKED_OWNER" symlink)"
  ln -sfn /nonexistent-target "$LINKED/$relative"
  run_sync_traced
  [[ "$output" == *"(in sync: attached immutable release 9.9.9)"* ]] || { printf '%s\n' "$output" | grep -v '^+'; false; }
  require_xtrace_fd
  [ "$(verify_impl_calls)" -ge 2 ] || {
    echo "rows did not verify alone after a batch miss"; false; }
}

# Per-owner verdicts for doctor and show-config: one pass, a line per owner,
# never looser than _attachment_verify_owner_artifacts OWNER HOME.
owner_verdicts() {
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    home=$2; shift 2
    attachment_owner_artifact_verdicts "$home" "$@"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$@"
}

owner_verdicts_readonly() {
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    home=$2; shift 2
    attachment_owner_artifact_verdicts_readonly "$home" "$@"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$@"
}

shell_owner_artifacts() {
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    _attachment_verify_owner_artifacts "$3" "$2"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$1" >/dev/null 2>&1
}

@test "owner verdicts name each owner in order and agree with the shell owner-artifact check" {
  local relative expected
  run owner_verdicts "$LINKED_OWNER" "$MAIN_OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected="$(printf '0\t%s\n0\t%s' "$LINKED_OWNER" "$MAIN_OWNER")"
  [ "$output" = "$expected" ] || { printf 'got <%s>\n' "$output"; false; }
  relative="$(first_artifact "$LINKED_OWNER" symlink)"
  ln -sfn /nonexistent-target "$LINKED/$relative"
  run owner_verdicts "$LINKED_OWNER" "$MAIN_OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected="$(printf '1\t%s\n0\t%s' "$LINKED_OWNER" "$MAIN_OWNER")"
  [ "$output" = "$expected" ] || { printf 'got <%s>\n' "$output"; false; }
  ! shell_owner_artifacts "$LINKED_OWNER" || { echo "shell passed the drifted owner"; false; }
  shell_owner_artifacts "$MAIN_OWNER" || { echo "shell refused the healthy owner"; false; }
}

@test "readonly owner verdicts really run on Python 3.9 without creating or chmodding state" {
  local before after expected
  /usr/bin/python3 -c 'import sys; assert sys.version_info[:2] == (3, 9)' 2>/dev/null || skip 'system Python 3.9 is not available'
  doctor_wait_postjobs "$TRELLIS_HOME"
  rm -rf "$TRELLIS_HOME/state/attachment-journals"
  before="$(find "$TRELLIS_HOME" -ls | LC_ALL=C sort)"
  run env PATH=/usr/bin:/bin:/usr/sbin:/sbin TRELLIS_HOME="$TRELLIS_HOME" /bin/bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    home=$2; shift 2
    attachment_owner_artifact_verdicts_readonly "$home" "$@"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$MAIN_OWNER" "$LINKED_OWNER"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected="$(printf '0\t%s\n0\t%s' "$MAIN_OWNER" "$LINKED_OWNER")"
  [ "$output" = "$expected" ] || { echo "batch proved no owners: $output"; false; }
  after="$(find "$TRELLIS_HOME" -ls | LC_ALL=C sort)"
  [ "$before" = "$after" ] || {
    printf '%s\n' "$before" > "$SANDBOX/state-before"
    printf '%s\n' "$after" > "$SANDBOX/state-after"
    diff -u "$SANDBOX/state-before" "$SANDBOX/state-after" >&3 || :
    echo 'readonly verdicts changed machine state'; false
  }
  [ ! -e "$TRELLIS_HOME/state/attachment-journals" ]
}

@test "readonly owner verdicts refuse unsafe state without repairing it" {
  # A detached fixture postjob may otherwise repair the directory after chmod.
  doctor_wait_postjobs "$TRELLIS_HOME" || { echo 'fixture postjobs did not finish'; false; }
  chmod 755 "$TRELLIS_HOME/state/attachments"
  [ "$(_attachment_test_mode "$TRELLIS_HOME/state/attachments")" = 755 ]
  run owner_verdicts_readonly "$MAIN_OWNER" "$LINKED_OWNER"
  [ "$status" -eq 10 ] || { echo "status=$status output=$output"; false; }
  [ "$(_attachment_test_mode "$TRELLIS_HOME/state/attachments")" = 755 ]
}

_attachment_test_mode() {
  # GNU stat -f can print partial stdout before failing; try GNU first.
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

@test "readonly owner verdicts refuse a duplicate owner path" {
  run owner_verdicts_readonly "$MAIN_OWNER" "$MAIN_OWNER"
  [ "$status" -eq 10 ] && [ -z "$output" ] || { echo "status=$status output=$output"; false; }
}

@test "readonly owner verification writes no Python bytecode in a writable library" {
  local lib="$SANDBOX/writable-lib"
  cp -R "$PAYLOAD/scripts/lib" "$lib"
  chmod -R u+w "$lib"
  rm -rf "$lib/__pycache__"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/attachment.sh" >/dev/null || exit 90
    attachment_owner_artifact_verdicts_readonly "$2" "$3"
  ' _ "$lib" "$TRELLIS_HOME" "$MAIN_OWNER"
  [ "$status" -eq 0 ] && [ "$output" = "$(printf '0\t%s' "$MAIN_OWNER")" ] || { echo "$output"; false; }
  [ ! -e "$lib/__pycache__" ] || { echo 'Python wrote bytecode into the library'; false; }
}

@test "the health-check owner batch is the shared verifier" {
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    . "$1/scripts/lib/health-checks.sh" >/dev/null || exit 91
    _hc_portable_owner_artifacts_batch "$3" "$2"; printf "batch=%s\n" "$?"
    declare -f _hc_portable_owner_artifacts_batch | grep -c attachment_owner_artifact_verdicts
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$LINKED_OWNER"
  [[ "$output" == *"batch=0"* ]] || { echo "$output"; false; }
  [[ "$output" == *$'\n1'* ]] || { echo "$output"; false; }
}

# The reconcile loop compares only owner fields, so its trellis_jq calls stay
# on the direct jq path; whole owner records (~100 KB with render images) sent
# every call through the temporary-file transport.
@test "the exact-owner reconcile keeps its sibling checks off the trellis_jq file transport" {
  local trace="$SANDBOX/reattach.trace" count
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    exec 9>"$1"
    export BASH_XTRACEFD=9 PS4="+\${FUNCNAME[*]-}| "
    exec bash -x "$2/scripts/attach-project.sh" attach --home "$3" --fleet personal "$4"
  ' _ "$trace" "$PAYLOAD" "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  require_xtrace_fd
  grep -q '_attach_reconcile_verify_owners' "$trace" || { echo "reconcile did not run"; false; }
  count="$(grep -c '^+*trellis_jq _attach_reconcile_verify_owners[^|]*| __trellis_jq_scratch=' "$trace" || true)"
  echo "# reconcile trellis_jq file transports: $count" >&3
  [ "$count" -le 1 ] || false
}

# The reconcile's row-ownership check must not carry whole owner records in
# argv: at about 98 KB each, macOS refuses past eleven owners (1 MiB in all)
# and Linux past one 128 KiB argument (MAX_ARG_STRLEN). The shim applies the
# Linux limit on any host. A refused jq must refuse the attach, never skip
# the check: with the linked owner gone, its live row lacks exact ownership.
@test "the reconcile's row-ownership check keeps owner records out of argv and still refuses an unowned row" {
  local bin="$SANDBOX/argv-bin" second="$SANDBOX/second" second_owner real_jq size
  # A third worktree, so two owners remain once the linked one is gone.
  git -C "$PROJECT" worktree add -q -b second "$second"
  run "$LAUNCHER" attach --fleet personal "$second"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  second_owner="$OWNERS/$(printf '%s' "$second" | shasum -a 256 | cut -d' ' -f1).json"
  [ -f "$second_owner" ] || { echo "second owner missing"; false; }
  real_jq="$(command -v jq)"
  size="$(cat "$MAIN_OWNER" "$second_owner" | wc -c | tr -d ' ')"
  [ "$size" -gt 131072 ] || { echo "fixture owners too small to exceed the argv limit: $size bytes"; false; }
  mkdir -p "$bin"
  cat > "$bin/jq" <<SHIM
#!/bin/bash
for arg do
  if [ "\${#arg}" -ge 131072 ]; then
    printf 'oversized argv\\n' >> "$SANDBOX/oversized-argv"
    exit 7
  fi
done
exec "$real_jq" "\$@"
SHIM
  chmod 755 "$bin/jq"
  rm -f "$LINKED_OWNER"
  run env TRELLIS_HOME="$TRELLIS_HOME" PATH="$bin:$PATH" bash "$PAYLOAD/scripts/attach-project.sh" attach --home "$TRELLIS_HOME" --fleet personal "$PROJECT"
  [ ! -e "$SANDBOX/oversized-argv" ] || { echo "a jq argument reached the argv limit"; echo "$output"; false; }
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"live registry row lacks exact ownership at $LINKED"* ]] || { echo "$output"; false; }
}

# Re-attach (scope current) checks its siblings in one batch
# (_attach_reconcile_siblings_batch); only the owner itself runs the loop body.
reattach_traced() {
  REATTACH_TRACE="$SANDBOX/reattach-batch.trace"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    exec 9>"$1"
    export BASH_XTRACEFD=9 PS4="+\${FUNCNAME[*]-}| "
    exec bash -x "$2/scripts/attach-project.sh" attach --home "$3" --fleet personal "$4"
  ' _ "$REATTACH_TRACE" "$PAYLOAD" "$TRELLIS_HOME" "$PROJECT"
}

@test "re-attach verifies its siblings in one batch, not row by row" {
  reattach_traced
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"already attached: $PROJECT"* ]] || { echo "$output"; false; }
  require_xtrace_fd
  grep -q '^+*_attach_reconcile_siblings_batch _attach_reconcile_verify_owners' "$REATTACH_TRACE" ||
    { echo "the sibling batch did not run"; false; }
  ! grep -q '^+*_attachment_validate_ids _attach_reconcile_verify_owners' "$REATTACH_TRACE" ||
    { echo "a sibling was validated row by row"; false; }
}

@test "re-attach still refuses a sibling whose manifest names another project, with the loop's message" {
  printf '{"schema_version":1,"project_id":"someone-else"}\n' > "$LINKED/.trellis.json"
  reattach_traced
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: sibling project ID disagrees with the manifest at $LINKED"* ]] ||
    { echo "$output"; false; }
}

@test "re-attach still refuses a sibling owner file that is not mode 0600, with the loop's message" {
  chmod 644 "$LINKED_OWNER"
  reattach_traced
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: invalid owner $LINKED_OWNER"* ]] || { echo "$output"; false; }
}

# sibling-identity HOME FS OWNER: the kept owners as one JSON array, or 10.
sibling_identity() {
  local tamper="$1"
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/scripts/lib/attachment.sh" >/dev/null || exit 90
    jq -cS -n --arg tamper "$4" --argjson expected "$(_attachment_paths_json "$3" "$5")" "$_attachment_exact_inputs_def
      [exact_inputs | {path, record: (if .path == \$tamper then .record.release = \"0.0.0\" else .record end),
      data: null, canonical: true, valid: true}]" "$3" "$5" |
      _attachment_owner_verify_exec sibling-identity "$2" "$3"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$MAIN_OWNER" "$tamper" "$LINKED_OWNER"
}

@test "sibling identity keeps both owners and refuses a record that differs from its file" {
  run sibling_identity ""
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e --arg a "$MAIN_OWNER" --arg b "$LINKED_OWNER" '. == [$a, $b]' >/dev/null ||
    { echo "$output"; false; }
  run sibling_identity "$LINKED_OWNER"
  [ "$status" -eq 10 ] || { echo "status $status: $output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

# attach_reconcile_postconditions HOME BASE KEY CHECKOUT AFTER OWNERS: every
# owner file must still hold its recorded owner record. One jq pass: the owners
# array crosses trellis_jq once, not once per owner.
postconditions() {
  local owners="$1" owners_file="$SANDBOX/postconditions-owners.json"
  # Owners may exceed the OS per-argument limit before the product function
  # gets to use trellis_jq's file transport. Cross this test seam by file too.
  printf '%s' "$owners" > "$owners_file" || return 1
  env TRELLIS_HOME="$TRELLIS_HOME" TRELLIS_LIBS_PRELOADED= bash -c '
    . "$1/scripts/attach-project.sh" >/dev/null || exit 90
    eval "$(declare -f trellis_jq | sed "1s/^trellis_jq/__counted_trellis_jq/")"
    calls_log=$7
    trellis_jq() { printf "call\n" >> "$calls_log"; __counted_trellis_jq "$@"; }
    key="personal/owner-verify"
    checkout="$(jq -r ".checkout_id" "$4")"
    after="$(jq -cS --arg key "$key" --arg checkout "$checkout" ".projects[\$key].checkouts[\$checkout]" "$2/registry.json")"
    owners="$(<"$5")" || exit 90
    attach_reconcile_postconditions "$2" "$3" "$key" "$checkout" "$after" "$owners"
  ' _ "$PAYLOAD" "$TRELLIS_HOME" "$SANDBOX/postcondition-base.json" "$MAIN_OWNER" "$owners_file" unused "$SANDBOX/trellis-jq-calls"
}

owners_json() {
  local expected
  expected="$(jq -cn '$ARGS.positional' --args "$@")"
  jq -cS -n --argjson expected "$expected" '[inputs | {path: input_filename, record: .}] as $docs
    | if ($docs | map(.path)) == $expected then $docs else error("owner files must each hold one document") end' "$@"
}

@test "reconcile postconditions check every owner in one trellis_jq pass and refuse a changed or missing owner" {
  local owners changed
  # Force a single owner snapshot past Linux's per-argument limit. The helper
  # must still reach the production function's large-JSON file transport.
  python3 -I - "$MAIN_OWNER" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    owner = json.load(stream)
owner["test_large_owner_payload"] = "x" * 140000
with open(path, "w", encoding="utf-8") as stream:
    json.dump(owner, stream)
PY
  owners="$(owners_json "$MAIN_OWNER" "$LINKED_OWNER")"
  [ "${#owners}" -gt 131072 ] || { echo 'fixture did not exceed Linux per-argument limit'; false; }
  : > "$SANDBOX/trellis-jq-calls"
  run postconditions "$owners"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$SANDBOX/trellis-jq-calls" | tr -d ' ')" -le 1 ] || {
    echo "trellis_jq calls: $(wc -l < "$SANDBOX/trellis-jq-calls")"; false; }
  changed="$(printf '%s\n' "$owners" | jq -c '.[1].record.fleet = "elsewhere"')"
  run postconditions "$changed"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: owner postcondition failed"* ]] || { echo "$output"; false; }
  rm -f "$LINKED_OWNER"
  run postconditions "$owners"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: owner postcondition failed"* ]] || { echo "$output"; false; }
}

# verify_siblings shares the end-of-pass check: an owner file changed after it
# was read (here its ctime, by a same-mode chmod) is undecided, never a pass.
@test "sibling identity makes an owner changed while the pass ran undecided" {
  run python3 -I - "$PAYLOAD/scripts/lib" "$MAIN_OWNER" "$LINKED_OWNER" <<'PY'
import importlib.util, json, os, sys
lib, main_owner, linked_owner = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("owner_verify", lib + "/owner_verify.py")
ov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ov)
ov.load(ov.load_modules(lib + "/attachment_fs.py"), "")
entries = [{"path": path, "record": json.load(open(path)), "valid": True} for path in (main_owner, linked_owner)]
failures, kept = ov.verify_siblings([dict(entry) for entry in entries], main_owner)
print("clean %d %d" % (len(failures), len(kept)))
def touching(parent_fd, name, kind, expected=None):
    node = ov.default_opener(parent_fd, name, kind, expected)
    if node is not None and name == os.path.basename(linked_owner):
        os.chmod(name, 0o600, dir_fd=parent_fd)
    return node
failures, kept = ov.verify_siblings([dict(entry) for entry in entries], main_owner, touching)
print("changed " + json.dumps([[f["owner"] == linked_owner, f["check"], f["fields"].get("reason")] for f in failures]))
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "clean 0 2" ] || { echo "$output"; false; }
  [ "${lines[1]}" = 'changed [[true, "undecided", "changed during verification"]]' ] || { echo "$output"; false; }
}

# Sync reads and compares each row in one jq. A per-column read of a row is
# `jq -r .fleet` / `jq -er .fleet`; the shim counts those during a healthy sync.
@test "sync reads and compares each row in one jq, not column by column" {
  local bin="$SANDBOX/column-bin" real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$bin"
  cat > "$bin/jq" <<SHIM
#!/bin/bash
for arg do
  [ "\$arg" != .fleet ] || { printf 'column\n' >> "$SANDBOX/column-reads"; break; }
done
exec "$real_jq" "\$@"
SHIM
  chmod 755 "$bin/jq"
  : > "$SANDBOX/column-reads"
  run env TRELLIS_HOME="$TRELLIS_HOME" PATH="$bin:$PATH" bash "$PAYLOAD/scripts/sync-hooks.sh" --home "$TRELLIS_HOME" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"(in sync: attached immutable release 9.9.9)"* ]] || { echo "$output"; false; }
  [ "$(wc -l < "$SANDBOX/column-reads" | tr -d ' ')" -eq 0 ] || {
    echo "per-column reads: $(wc -l < "$SANDBOX/column-reads")"; false; }
}

# The row functions of sync-hooks.sh, taken from the payload as the
# part2 suite does, in a shell with the libraries they call.
sync_row_functions() {
  local script="$PAYLOAD/scripts/sync-hooks.sh" out="$SANDBOX/sync-row-functions.sh"
  {
    sed -n "/^SYNC_ROW_ARGS_DEFS='\$/,/^'\$/p" "$script"
    for name in _row_matches_resolved_root_fast row_matches_resolved_root owner_harnesses_json \
        _owner_matches_row_fields_fast owner_matches_row _sync_row_columns_fast; do
      sed -n "/^$name() {\$/,/^}\$/p" "$script"
    done
  } > "$out"
  printf '%s\n' "$out"
}

# Rows the fast paths must judge exactly as the per-column code, or leave to it.
sync_row_table() {
  local base="$1"
  printf '%s\n' "$base" | jq -c '
    ., (.release = "0.0.1"), (.root = null), (.root = false), (.fleet = 5), (.fleet = null),
    (.root = (.root + "\n")), (.root = (.root + "\nx")), (.attachment_id = null),
    (.worktree_id = "\u001f"), (.project_id = "")'
}

@test "the one-jq row comparisons agree with the per-column ones on every row shape" {
  local functions base row resolution fast slow
  functions="$(sync_row_functions)"
  base="$(jq -c '{fleet, project_id, root: .worktree_root, checkout_id, worktree_id, attachment_id, release,
    harnesses: ["claude", "codex"], kind: "worktree", availability: "available", status: "active"}' "$LINKED_OWNER")"
  resolution="$(printf '%s\n' "$base" | jq -c '{fleet, project_id, root, checkout_id, worktree_id}')"
  while IFS= read -r row; do
    for check in resolution owner; do
      fast="$(env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
        . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; . "$2"
        if [ "$3" = resolution ]; then row_matches_resolved_root "$4" "$5"; else owner_matches_row "$6" "$4"; fi
        echo "rc=$?"' _ "$PAYLOAD" "$functions" "$check" "$row" "$resolution" "$LINKED_OWNER")"
      slow="$(env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
        . "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; . "$2"
        _row_matches_resolved_root_fast() { return 2; }
        _owner_matches_row_fields_fast() { return 2; }
        if [ "$3" = resolution ]; then row_matches_resolved_root "$4" "$5"; else owner_matches_row "$6" "$4"; fi
        echo "rc=$?"' _ "$PAYLOAD" "$functions" "$check" "$row" "$resolution" "$LINKED_OWNER")"
      [ "$fast" = "$slow" ] || { echo "$check differs on $row: fast $fast, per-column $slow"; false; }
    done
  done < <(sync_row_table "$base")
  # The fast paths decide ordinary rows themselves (else the comparison above
  # would hold trivially): the base row matches, a changed release does not.
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"
    _row_matches_resolved_root_fast "$2" "$3"; printf "resolution=%s " "$?"
    _owner_matches_row_fields_fast "$4" "$2"; printf "owner=%s " "$?"
    _owner_matches_row_fields_fast "$4" "$5"; printf "owner-release=%s\n" "$?"' \
    _ "$functions" "$base" "$resolution" "$LINKED_OWNER" "$(printf '%s\n' "$base" | jq -c '.release = "0.0.1"')"
  [ "$output" = "resolution=0 owner=0 owner-release=1" ] || { echo "$output"; false; }
  # The base row matches both ways, and a changed release refuses the owner.
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; . "$2"; owner_matches_row "$3" "$4"' \
    _ "$PAYLOAD" "$functions" "$LINKED_OWNER" "$base"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; . "$2"; owner_matches_row "$3" "$4"' \
    _ "$PAYLOAD" "$functions" "$LINKED_OWNER" "$(printf '%s\n' "$base" | jq -c '.release = "0.0.1"')"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "the one-jq row columns keep an empty column in place and leave unusual rows to the per-column reads" {
  local functions
  functions="$(sync_row_functions)"
  run bash -c '. "$1"
    _sync_row_columns_fast "$2" || { echo undecided; exit 0; }
    printf "<%s>" "$fleet" "$project_id" "$kind" "$availability" "$status" "$excluded" "$root" "$release" \
      "$attachment_id" "$checkout_id" "$worktree_id" "$row_harnesses"' _ "$functions" \
    '{"fleet":"personal","project_id":"p","kind":"worktree","availability":"available","status":"active","root":"/r","release":"9.9.9","attachment_id":null,"checkout_id":"c","worktree_id":"w","harnesses":["codex"]}'
  [ "$output" = '<personal><p><worktree><available><active><false></r><9.9.9><><c><w><["codex"]>' ] || { echo "$output"; false; }
  for row in '{"fleet":5,"project_id":"p","kind":"worktree","availability":"available","status":"active"}' \
      '{"fleet":null,"project_id":"p","kind":"worktree","availability":"available","status":"active"}' \
      '{"fleet":"personal","project_id":"p","kind":"worktree","availability":"available","status":"active","root":"/a\nb"}' \
      '{"fleet":"personal","project_id":"p","kind":"worktree","availability":"available","status":"active","root":"/a\u001fb"}'; do
    run bash -c '. "$1"; _sync_row_columns_fast "$2" && echo decided || echo undecided' _ "$functions" "$row"
    [ "$output" = undecided ] || { echo "$row: $output"; false; }
  done
}

# Sol r152-perf H1 and r152-perf-2 L1: the row-ownership root decoder must
# refuse with TRELLIS_EX_STATE (4) when jq fails, with no output or after
# partial output, never turn the failure into an empty root and skip the row.
# The shim fails only the decoder itself: the `jq -j .` whose input is the
# unowned row's root as a JSON string. With no failure injected (control) the
# same run reaches the row and refuses it (3, "lacks exact ownership").
decoder_failure_attach() {
  local mode="$1" bin="$SANDBOX/decoder-bin" real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$bin"
  jq -n --arg root "$LINKED" '$root' > "$SANDBOX/decoder-target"
  cat > "$bin/jq" <<SHIM
#!/bin/bash
if [ "\$#" -eq 2 ] && [ "\$1" = -j ] && [ "\$2" = . ]; then
  input="\$(cat)"
  if [ "\$input" = "\$(cat "$SANDBOX/decoder-target")" ]; then
    printf 'hit\n' >> "$SANDBOX/decoder-hits"
    case "$mode" in
      none) exit 7 ;;
      partial) printf '%s' "$SANDBOX/part"; exit 7 ;;
    esac
  fi
  printf '%s\n' "\$input" | exec "$real_jq" "\$@"
fi
exec "$real_jq" "\$@"
SHIM
  chmod 755 "$bin/jq"
  : > "$SANDBOX/decoder-hits"
  rm -f "$LINKED_OWNER"
  run env TRELLIS_HOME="$TRELLIS_HOME" PATH="$bin:$PATH" bash "$PAYLOAD/scripts/attach-project.sh" attach --home "$TRELLIS_HOME" --fleet personal "$PROJECT"
  DECODER_HITS="$(wc -l < "$SANDBOX/decoder-hits" | tr -d ' ')"
}

@test "re-attach reaches the unowned row through the root decoder (control)" {
  decoder_failure_attach control
  [ "$DECODER_HITS" -eq 1 ] || { echo "decoder hits: $DECODER_HITS"; echo "$output"; false; }
  [ "$status" -eq 3 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: live registry row lacks exact ownership at $LINKED"* ]] || { echo "$output"; false; }
}

@test "re-attach refuses with a state error when the root decoder fails with no output" {
  decoder_failure_attach none
  [ "$DECODER_HITS" -eq 1 ] || { echo "decoder hits: $DECODER_HITS"; echo "$output"; false; }
  [ "$status" -eq 4 ] || { echo "status $status: $output"; false; }
  [[ "$output" != *"lacks exact ownership"* && "$output" != *"already attached"* ]] || { echo "$output"; false; }
}

@test "re-attach refuses with a state error when the root decoder fails after partial output" {
  decoder_failure_attach partial
  [ "$DECODER_HITS" -eq 1 ] || { echo "decoder hits: $DECODER_HITS"; echo "$output"; false; }
  [ "$status" -eq 4 ] || { echo "status $status: $output"; false; }
  [[ "$output" != *"lacks exact ownership"* && "$output" != *"already attached"* ]] || { echo "$output"; false; }
}

# Sol r152-perf M1: an owner file that parses to no document (empty or
# whitespace only) must not vanish from a batch.
@test "re-attach refuses an empty or whitespace-only orphan owner with the loop's message" {
  local orphan="$OWNERS/$(printf '%064d' 0).json" content
  for content in '' $' \n\t\n'; do
    printf '%s' "$content" > "$orphan"
    chmod 600 "$orphan"
    run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PAYLOAD/scripts/attach-project.sh" attach --home "$TRELLIS_HOME" --fleet personal "$PROJECT"
    [ "$status" -ne 0 ] || { echo "content <$content>: $output"; false; }
    [[ "$output" == *"exact-owner reconcile refused: invalid owner $orphan"* ]] || { echo "content <$content>: $output"; false; }
  done
}

@test "owner batches refuse an empty owner file alone, beside a healthy owner, and beside a two-document file" {
  local empty="$OWNERS/$(printf '%064d' 0).json" double="$OWNERS/$(printf '%064d' 1).json" set
  : > "$empty"
  cat "$MAIN_OWNER" "$MAIN_OWNER" > "$double"
  chmod 600 "$empty" "$double"
  for set in "$empty" "$MAIN_OWNER $empty" "$double $empty" "$empty $double"; do
    # shellcheck disable=SC2086 # the set is a list of paths without spaces
    batch_verify $set
    [ "$BATCH_STATUS" -eq 10 ] || { echo "verify batch on <$set>: $BATCH_STATUS $BATCH_OUTPUT"; false; }
    # shellcheck disable=SC2086
    run owner_verdicts $set
    [ "$status" -eq 10 ] || { echo "verdicts on <$set>: $status $output"; false; }
    [ -z "$output" ] || { echo "verdicts on <$set>: $output"; false; }
  done
  batch_verify "$MAIN_OWNER"
  [ "$BATCH_STATUS" -eq 0 ] || { echo "healthy owner alone: $BATCH_STATUS $BATCH_OUTPUT"; false; }
}

# Sol r152-perf-2 M1-R: jq turns non-UTF-8 filename bytes into U+FFFD, so the
# batch accepts only owner paths shaped .../<64 hex>/<64 hex>.json, each once.
# Here: a path given twice, a non-canonical name, and the CLI with orphans at
# non-canonical names. The review's Linux case follows; it skips where the
# filesystem refuses names that are not UTF-8 (APFS).
@test "owner batches miss on a duplicate or non-canonical owner path" {
  local odd="$OWNERS/odd.json"
  cp "$LINKED_OWNER" "$odd"
  chmod 600 "$odd"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/scripts/lib/attachment.sh" >/dev/null; _attachment_paths_json "$2" "$2"' _ "$PAYLOAD" "$MAIN_OWNER"
  [ "$status" -eq 10 ] || { echo "duplicate: $status $output"; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/scripts/lib/attachment.sh" >/dev/null; _attachment_paths_json "$2"' _ "$PAYLOAD" "$odd"
  [ "$status" -eq 10 ] || { echo "non-canonical: $status $output"; false; }
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/scripts/lib/attachment.sh" >/dev/null; _attachment_paths_json "$2" "$3"' _ "$PAYLOAD" "$MAIN_OWNER" "$LINKED_OWNER"
  [ "$status" -eq 0 ] || { echo "canonical pair: $status $output"; false; }
  batch_verify "$MAIN_OWNER" "$MAIN_OWNER"
  [ "$BATCH_STATUS" -eq 10 ] || { echo "verify batch, duplicate: $BATCH_STATUS $BATCH_OUTPUT"; false; }
  run owner_verdicts "$LINKED_OWNER" "$LINKED_OWNER"
  [ "$status" -eq 10 ] || { echo "verdicts, duplicate: $status $output"; false; }
  batch_verify "$MAIN_OWNER" "$odd"
  [ "$BATCH_STATUS" -eq 10 ] || { echo "verify batch, non-canonical: $BATCH_STATUS $BATCH_OUTPUT"; false; }
}

@test "re-attach refuses an empty orphan beside a valid copy at a non-canonical name, with the loop's message" {
  local copy="$OWNERS/odd-copy.json" empty="$OWNERS/odd-empty.json"
  cp "$LINKED_OWNER" "$copy"
  : > "$empty"
  chmod 600 "$copy" "$empty"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PAYLOAD/scripts/attach-project.sh" attach --home "$TRELLIS_HOME" --fleet personal "$PROJECT"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: invalid owner $empty"* ]] || { echo "$output"; false; }
}

@test "re-attach refuses the Linux non-UTF-8 three-file collision with the loop's message" {
  local bad1="$OWNERS/"$'odd-\x80.json' bad2="$OWNERS/"$'odd-\x81.json' replacement="$OWNERS/"$'odd-\xef\xbf\xbd.json'
  : > "$bad1" 2>/dev/null || skip "this filesystem refuses file names that are not UTF-8"
  cat "$LINKED_OWNER" "$LINKED_OWNER" > "$bad1"
  : > "$bad2"
  cat "$LINKED_OWNER" > "$replacement"
  chmod 600 "$bad1" "$bad2" "$replacement"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$PAYLOAD/scripts/attach-project.sh" attach --home "$TRELLIS_HOME" --fleet personal "$PROJECT"
  [ "$status" -eq 3 ] || { echo "status $status: $output"; false; }
  [[ "$output" == *"exact-owner reconcile refused: invalid owner $OWNERS/odd-"* ]] || { echo "$output"; false; }
}

@test "the owner-path duplicate check is NUL-framed: a path with a newline, given twice, misses" {
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1/scripts/lib/attachment.sh" >/dev/null; _attachment_paths_json "$2" "$2"' _ "$PAYLOAD" \
    "$SANDBOX/a"$'\n'"b/$(printf '%064d' 0)/$(printf '%064d' 1).json"
  [ "$status" -eq 10 ] || { echo "status $status: $output"; false; }
}
