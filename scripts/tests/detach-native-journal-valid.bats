#!/usr/bin/env bats
# Spec 075 T4/R5: the native program judges a detach journal with the shell
# validator's own jq filters. Over a mutation corpus of real journals (a
# prepared one and one in the middle of a render restore), the native verdict
# equals `_attachment_detach_journal_valid`'s status for every mutation.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/release-fixture
load helpers/detach-journal
bats_require_minimum_version 1.5.0

setup_file() {
  detach_journal_setup_file
}

teardown_file() {
  detach_journal_teardown_file
}

setup() {
  detach_journal_setup
  LIB="$REPO_ROOT/scripts/lib/attachment.sh"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

shell_verdict() {
  bash -c '. "$1"; _attachment_detach_journal_valid "$2" >/dev/null 2>&1' _ "$LIB" "$1"
}

native_verdict() {
  bash -c '. "$1"; _attachment_detach_python_filters journal-valid "$2" >/dev/null 2>&1' _ "$LIB" "$1"
}

# mutate JOURNAL FILTER: rewrite the journal through jq, private and atomic.
mutate() {
  local journal="$1" filter="$2" tmp
  tmp="$(mktemp "$journal.tmp.XXXXXX")"
  chmod 600 "$tmp"
  jq -c "$filter" "$journal" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal"
}

compare_corpus() {
  local journal="$1" pristine="$SANDBOX/pristine-journal.json" filter shell_status native_status checked=0
  local -a filters=()
  cp -p "$journal" "$pristine"
  while IFS= read -r key; do
    filters+=("del(.$key)" ".$key = null" ".$key = \"x\"" ".$key = 7")
  done < <(jq -r 'keys[]' "$journal")
  filters+=(
    '.'
    '. + {unexpected: true}'
    '.phase = -1' '.phase = 1.5' '.phase = ((.remove | length) + 1)'
    '.owner_committed = true'
    '.removal = {path: "relative/path", nonce: ("a" * 64)}'
    '.removal = {path: "/elsewhere/file", nonce: ("a" * 64)}'
    '.removal = {path: (.original_owner.worktree_root + "/" + .remove[0].path), nonce: "short"}'
    '.external.phase = 2'
    '.external.phase = 9'
    '.external.render_phase = 99'
    '.external.exclude_action = "transfer"'
    '.external.clear_registry = false'
    '.original_owner.artifacts[0].sha256 = "bad"'
    '.original_owner.worktree_id = ("0" * 64)'
    '.original_owner.worktree_root = "/nonexistent/root"'
    '.attachment_id = "00000000-0000-0000-0000-000000000000"'
    '.next_owner = .original_owner'
    '.remove = (.remove + .remove)'
    '.remove = []'
    '.external.render_pending = (.external.renders[0] // null)'
    'if .external.render_pending != null then .external.render_pending.source_sha256 = ("b" * 64) else . end'
    'if .external.render_pending != null then .external.render_pending.staging_identity = "1:2" else . end'
    'if .external.render_pending != null then .external.render_pending.result_base64 = "AAAA" else . end'
  )
  for filter in "${filters[@]}"; do
    cp -p "$pristine" "$journal"
    mutate "$journal" "$filter" || { echo "mutation failed: $filter"; return 1; }
    shell_status=0; shell_verdict "$journal" || shell_status=$?
    native_status=0; native_verdict "$journal" || native_status=$?
    [ "$shell_status" -eq "$native_status" ] ||
      { echo "mutation $filter: shell $shell_status native $native_status"; return 1; }
    checked=$((checked + 1))
  done
  # Mode, symlink and misplaced journals.
  cp -p "$pristine" "$journal"; chmod 644 "$journal"
  shell_status=0; shell_verdict "$journal" || shell_status=$?
  native_status=0; native_verdict "$journal" || native_status=$?
  [ "$shell_status" -eq "$native_status" ] && [ "$shell_status" -eq 3 ] || { echo "mode: $shell_status $native_status"; return 1; }
  chmod 600 "$journal"
  mv "$journal" "$journal.real"; ln -s "$journal.real" "$journal"
  shell_status=0; shell_verdict "$journal" || shell_status=$?
  native_status=0; native_verdict "$journal" || native_status=$?
  [ "$shell_status" -eq "$native_status" ] && [ "$shell_status" -ne 0 ] || { echo "symlink: $shell_status $native_status"; return 1; }
  rm "$journal"; mv "$journal.real" "$journal"
  cp -p "$pristine" "$SANDBOX/misplaced.json"
  shell_status=0; shell_verdict "$SANDBOX/misplaced.json" || shell_status=$?
  native_status=0; native_verdict "$SANDBOX/misplaced.json" || native_status=$?
  [ "$shell_status" -eq "$native_status" ] && [ "$shell_status" -ne 0 ] || { echo "misplaced: $shell_status $native_status"; return 1; }
  cp -p "$pristine" "$journal"
  echo "checked $checked mutations"
}

@test "native and shell validators agree on every mutation of a prepared detach journal" {
  run env ATTACHMENT_FAULT_PHASE=detach-prepared "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -ne 0 ]
  journal="$(detach_journal_path)"
  shell_verdict "$journal"
  native_verdict "$journal"
  compare_corpus "$journal"
}

@test "native and shell validators agree on every mutation of a journal in the middle of a render restore" {
  kill_detach_at attachment_detach_render_claim 1
  journal="$(detach_journal_path)"
  jq -e '.external.render_pending != null and .removal != null' "$journal" >/dev/null
  shell_verdict "$journal"
  native_verdict "$journal"
  compare_corpus "$journal"
}

# A transfer record may exceed Linux's per-argument limit. The leaf must still
# receive its exact arguments, and the called function must see an empty stdin.
@test "a shell leaf takes an argument beyond one argv string's limit" {
  local program
  program="$(bash -c '. "$1"; _attachment_detach_program' _ "$LIB")"
  PROGRAM="$program" TRELLIS_DETACH_BASH="$BASH" python3 -I -B - <<'PY'
import os
namespace = {"__name__": "shell_leaf_check"}
exec(compile(os.environ["PROGRAM"], "detach_native.py", "exec"), namespace)
big = '{"renders":"' + "x" * 300000 + '"}'
assert namespace["shell_leaf"]("detach", "test", big, "=", big) == 0
assert namespace["shell_leaf"]("detach", "test", big, "=", big + "y") == 1
assert namespace["shell_leaf"]("detach", "test", "a b", "=", "a b") == 0
assert namespace["shell_leaf"]("detach", "test", "", "=", "") == 0
assert namespace["shell_leaf"]("detach", "read", "-r", "line") == 1
PY
}
