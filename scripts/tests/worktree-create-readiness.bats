#!/usr/bin/env bats
# The post-Git readiness fallback is an explicitly accepted once-only exception.
# These tests preserve its existing success, refusal, and duplicate pass counts.

bats_require_minimum_version 1.5.0
REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/worktree-create-trace

@test "step-level observer records schema, leaf, render and exclude checks" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/steps" owner phase managed
  run bash -c 'cd "$1" && "$2" add steps' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  owner="$(t14_owner_for_root "$target")" || return 1
  # Instrumentation must not force the managed current-worktree proof to miss.
  managed="$(git -C "$T14_PROJECT" config --local --get core.hooksPath)" || return 1
  grep -Eq '^trellis_owner_schema_b64=[A-Za-z0-9+/=]+$' "$managed/post-checkout" || return 1
  grep -Eq '^trellis_manifest_schema_b64=[A-Za-z0-9+/=]+$' "$managed/post-checkout" || return 1
  python3 - "$SOURCE_ROOT/scripts/lib/attachment.sh" "$managed/post-checkout" <<'PY'
import base64
from pathlib import Path
import re
import sys

source, dispatcher = (Path(p).read_text() for p in sys.argv[1:])
# The wrapper evaluates the shared schema assignment; the dispatcher embeds
# exactly that assignment's text.
wrapper = re.search(r'(?ms)^_attachment_owner_json_valid\(\) \{\n.*?^\}\n', source)
assert wrapper is not None
assert 'jq -e "$_attachment_owner_schema_filter" "$file"' in wrapper.group()
schema = re.findall(r"(?ms)^_attachment_owner_schema_filter='\n(.*?)^'\n", source)
assert len(schema) == 1
encoded = re.search(r'(?m)^trellis_owner_schema_b64=([A-Za-z0-9+/=]+)$', dispatcher)
assert encoded is not None
assert base64.b64decode(encoded.group(1)) == schema[0].encode()
PY
  for phase in pre hook; do
    awk -F '\t' -v phase="$phase" -v owner="$DONOR" \
      '$1 == "schema" && $2 == phase && $3 == owner { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
    awk -F '\t' -v phase="$phase" -v root="$T14_PROJECT" \
      '$1 == "leaf" && $2 == phase && $3 == root "/.trellis/runtime" { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
    awk -F '\t' -v phase="$phase" -v root="$T14_PROJECT" \
      '$1 == "render" && $2 == phase && $3 == root "/.claude/fixture-settings.json" { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
    awk -F '\t' -v phase="$phase" \
      '$1 == "exclude" && $2 == phase { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
  done
  awk -F '\t' -v owner="$owner" '$1 == "schema" && $2 == "post" && $3 == owner { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
  awk -F '\t' -v root="$target" '$1 == "leaf" && $2 == "post" && $3 == root "/.trellis/runtime" { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
  awk -F '\t' -v root="$target" '$1 == "render" && $2 == "post" && $3 == root "/.claude/fixture-settings.json" { found=1 } END { exit !found }' "$STEPS" || { summarize_steps; return 1; }
  summarize_steps
}

@test "known exception: post-Git readiness preserves a valid pre-existing runtime" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/pre-existing" owner count
  # Construct a schema-valid older owner shape after Git's hook succeeds but
  # before the independent readiness boundary starts. Canonical readiness
  # misses the owned-anchor predicate; its full continuation can accept the
  # equivalent entry in pre_existing.
  python3 - "$REPO_ROOT/scripts/worktree.sh" <<'PY'
from pathlib import Path
import sys

wrapper = Path(sys.argv[1])
text = wrapper.read_text()
old = '    abs="$(cd "$wt_path" && pwd -P)"\n'
inject = '''    python3 - "$TRELLIS_HOME" "$wt_path" <<'PYBOUND'
import json, os, pathlib, sys
home, root = sys.argv[1:]
root = os.path.realpath(root)
found = []
for path in pathlib.Path(home, 'state', 'attachments').glob('*/*.json'):
    value = json.loads(path.read_text())
    if value.get('worktree_root') == root:
        found.append((path, value))
assert len(found) == 1
path, value = found[0]
items = [a for a in value['artifacts'] if a['path'] == '.trellis/runtime']
assert len(items) == 1 and items[0]['kind'] == 'symlink'
value['artifacts'] = [a for a in value['artifacts'] if a['path'] != '.trellis/runtime']
value['pre_existing'] = value.get('pre_existing', []) + [dict(items[0], reason='pre-existing-symlink')]
tmp = path.with_suffix('.test-next')
tmp.write_text(json.dumps(value, sort_keys=True) + '\\n')
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PYBOUND
'''
assert text.count(old) == 1
wrapper.write_text(text.replace(old, inject + old))
PY
  run bash -c 'cd "$1" && "$2" add pre-existing' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'worktree ready:'* ]] || { echo "$output"; return 1; }
  owner="$(t14_owner_for_root "$target")" || return 1
  count="$(count_verifications "$owner" hook)"
  [ "$count" -eq 4 ] || { echo "post-Git target verifications: $count (expected 4)"; cat "$TRACE"; return 1; }
}

@test "known exception: post-Git owner drift refuses after canonical fallback" {
  local target="$TRELLIS_WORKTREE_ROOT/fixture-project/post-race" owner count
  # Change target owner metadata immediately after its read-only leaf pass.
  # Only the invoking fixture's library is instrumented; the sealed Git hook
  # and its earlier attachment transaction run unchanged.
  python3 - "$REPO_ROOT/scripts/lib/attachment.sh" "$T14_SANDBOX/post-race-injected" <<'PY'
import pathlib
import shlex
import sys

shell, marker = map(pathlib.Path, sys.argv[1:])
text = shell.read_text()
old = ('_attachment_verify_impl() {\n'
       '  _attachment_verify_owner_artifacts_impl "$@" || return $?\n'
       '  _attachment_verify_managed_hooks "$1" "$2"\n'
       '}\n')
q = shlex.quote(str(marker))
new = ('_attachment_verify_impl() {\n'
       '  _attachment_verify_owner_artifacts_impl "$@" || return $?\n'
       '  if [ "${PRE_ADD:-}" = 0 ] && [ ! -e ' + q + ' ]; then\n'
       "    jq '.attachment_id = \"00000000-0000-4000-8000-000000000000\"' \"$2\" > \"$2.test-next\" || return 3\n"
       '    chmod 600 "$2.test-next" && mv "$2.test-next" "$2" || return 3\n'
       '    : > ' + q + '\n'
       '  fi\n'
       '  _attachment_verify_managed_hooks "$1" "$2"\n'
       '}\n')
assert text.count(old) == 1
shell.write_text(text.replace(old, new))
PY
  run bash -c 'cd "$1" && "$2" add post-race' _ "$T14_PROJECT" "$REPO_ROOT/scripts/worktree.sh"
  [ "$status" -eq 3 ] || { echo "unexpected status $status: $output"; return 1; }
  [[ "$output" == *'committed owner no longer exactly matches the expected local registry binding'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'worktree created but not ready'* ]] || { echo "$output"; return 1; }
  owner="$(t14_owner_for_root "$target")" || return 1
  count="$(count_verifications "$owner" hook)"
  [ "$count" -eq 2 ] || { echo "post-Git target verifications: $count (expected 2)"; cat "$TRACE"; return 1; }
}
