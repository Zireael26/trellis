#!/usr/bin/env bash
# Isolated, sealed fixtures and diagnostic observers for worktree-create tests.
# The observer logs attempts only; it never supplies an authorization verdict.
. "$BATS_TEST_DIRNAME/helpers/t14-worktree.bash"

setup() {
  t14_setup_sandbox
  export TRELLIS_WORKTREE_ROOT="$T14_SANDBOX/work trees"
  export TRELLIS_ATTACH_POSTJOB=off
  unset T152_TRACE_CALLBACK
  TRACE="$T14_SANDBOX/donor-verifications.tsv"
  STEPS="$T14_SANDBOX/verification-steps.tsv"
  : > "$TRACE"
  : > "$STEPS"
  local source="$REPO_ROOT" fixture="$T14_SANDBOX/instrumented"
  # shellcheck disable=SC2034  # Out-parameter: worktree-create-readiness.bats reads SOURCE_ROOT.
  SOURCE_ROOT="$source"
  mkdir -p "$fixture/scripts" "$fixture/core-rules/hooks"
  cp -R "$source/scripts/lib" "$fixture/scripts/lib"
  cp "$source/scripts/worktree.sh" "$source/scripts/seed-inheritance-symlinks.sh" \
    "$source/scripts/attach-project.sh" "$source/scripts/trellis-launcher.sh" \
    "$source/scripts/trellis" "$fixture/scripts/"
  cp "$source/core-rules/hooks/trellis-worktree-create.sh" "$fixture/core-rules/hooks/"
  # The managed dispatcher strips caller env. Embed the private trace paths
  # before sealing; never change a verifier input, return value or output.
  # Force the documented postjob-off unit seam inside the clean hook env.
  python3 - "$fixture/scripts/lib/attachment.sh" "$fixture/scripts/lib/attach-fastpath.py" \
    "$fixture/scripts/seed-inheritance-symlinks.sh" "$fixture/scripts/attach-project.sh" \
    "$fixture/scripts" "$TRACE" "$STEPS" "$fixture/scripts/lib/owner_verify.py" <<'PY'
import pathlib
import shlex
import sys

shell, fast, seed, attach, fixture_scripts, trace, steps, verifier = map(pathlib.Path, sys.argv[1:])
def replace_once(text, old, new):
    assert text.count(old) == 1, repr(old)
    return text.replace(old, new)

log_shell = shlex.quote(str(steps))
fixture_shell = shlex.quote(str(fixture_scripts))
logger = '''_t152_step_trace() {
  local phase fixture
  fixture=FIXTURE
  if [ "${PRE_ADD:-}" = 1 ]; then
    phase=pre
  elif [ "${T152_TRACE_CALLBACK:-}" = 1 ]; then
    phase=hook
  else
    case "${BASH_SOURCE[1]-}" in "$fixture"/*) phase=post ;; *) phase=hook ;; esac
  fi
  printf '%s\\t%s\\t%s\\t%s\\n' "$1" "$phase" "$2" "$3" >> LOG
}

'''.replace('FIXTURE', fixture_shell).replace('LOG', log_shell)
text = shell.read_text()
old = '_attachment_verify_owner_artifacts() {\n'
new = (old + '  if [ "${3:-all}" = all ]; then\n'
       + "    printf 'canonical\\t%s\\t%s\\n' \"${PRE_ADD:-unset}\" \"$1\" >> "
       + shlex.quote(str(trace)) + '\n  fi\n')
text = replace_once(text, old, new)
old = '_attachment_owner_json_valid() {\n'
schema_trace = '  _t152_step_trace schema "$1" "${FUNCNAME[1]:-main}"\n'
text = replace_once(text, old, logger + old + schema_trace)
# The real dispatcher generator extracts the canonical jq body only when the
# wrapper matches exactly. Teach the fixture's extractor about its own trace
# line so the generated schema/proof remains enabled and byte-equivalent.
old = ("    '_attachment_owner_json_valid() {\\n'\n"
       "    '  local file=$1\\n'\n")
new = ("    '_attachment_owner_json_valid() {\\n'\n"
       "    '  _t152_step_trace schema \"$1\" \"${FUNCNAME[1]:-main}\"\\n'\n"
       "    '  local file=$1\\n'\n")
text = replace_once(text, old, new)
old = '_attachment_artifact_exact_fields() {\n'
text = replace_once(text, old, old + '  _t152_step_trace leaf "$1/$2" "shell:${FUNCNAME[1]:-main}"\n')
old = '_attachment_render_owned_keys_exact() (\n'
new = (old + '  local _t152_render_path\n'
       '  _t152_render_path="$(printf \'%s\\n\' "$2" | jq -r \'.path // "?"\')" || _t152_render_path="?"\n'
       '  _t152_step_trace render "$1/$_t152_render_path" "shell:${FUNCNAME[1]:-main}"\n')
text = replace_once(text, old, new)
shell.write_text(text)

text = attach.read_text()
old = 'attach_exclude_verify_state() (\n'
new = (old + '  local _t152_exclude_path _t152_exclude_record\n'
       '  _t152_exclude_path="$(printf \'%s\\n\' "$1" | jq -r \'.path // "?"\')" || _t152_exclude_path="?"\n'
       '  _t152_exclude_record="$(printf \'%s\\n\' "$1" | jq -cS \'.path = "<captured-exclude>"\')" || _t152_exclude_record="?"\n'
       '  _t152_step_trace exclude "$_t152_exclude_path" "$_t152_exclude_record"\n')
text = replace_once(text, old, new)
old = 'attach_exclude_preflight() (\n'
text = replace_once(text, old, old + '  _t152_step_trace exclude-plan "${3:-?}/info/exclude" "${FUNCNAME[1]:-main}"\n')
old = 'attach_shared_exclude_state() {\n'
text = replace_once(text, old, old + '  _t152_step_trace exclude-authority "${3:-?}/info/exclude" "${FUNCNAME[1]:-main}"\n')
attach.write_text(text)

text = fast.read_text()
old = "            try:\n                observed = capture_donor_artifacts(candidate['worktree_root'], candidate['artifacts'])\n"
new = ("            try:\n"
       "                with open(" + repr(str(trace)) + ", 'a', encoding='utf-8') as log:\n"
       "                    log.write('fast\\t0\\t' + owner_dir + '/' + candidate['worktree_id'] + '.json\\n')\n"
       "                observed = capture_donor_artifacts(candidate['worktree_root'], candidate['artifacts'])\n")
text = replace_once(text, old, new)
# The ordinary and explicit routes capture each donor leaf once (F1).
old = "            parent, name = os.path.split(root + '/' + relative(artifact['path']))\n            with directory(parent) as fd:\n                node = collector.open(fd, name, kinds[kind], artifact)\n"
new = ("            _t152_step_trace('leaf', root + '/' + relative(artifact['path']), 'python:capture_donor_artifacts')\n" + old)
text = replace_once(text, old, new)
# Registry admission: one complete verifier pass per attempted candidate.
old = "        collector = Collector()\n        entry = {'path': path,"
new = ("        with open(" + repr(str(trace)) + ", 'a', encoding='utf-8') as log:\n"
       "            log.write('fast\\t0\\t' + path + '\\n')\n" + old)
text = replace_once(text, old, new)
# The coordinator's schema verdicts are the owner schema check.
old = "    return {path: verdict is True for path, verdict in zip(paths, valid)}, doc['settings']\n"
new = ("    for _t152_path in paths:\n"
       "        _t152_step_trace('schema', _t152_path, 'python:owner_schema_verdicts')\n" + old)
text = replace_once(text, old, new)
old = 'def artifact_exact(root, artifact):\n'
new = ("def _t152_step_trace(kind, path, detail):\n"
       "    with open(" + repr(str(steps)) + ", 'a', encoding='utf-8') as log:\n"
       "        log.write(kind + '\\thook\\t' + path + '\\t' + detail + '\\n')\n\n\n"
       + old)
text = replace_once(text, old, new)
old = "    path = relative(artifact['path'])\n    parent, name = os.path.split(root + '/' + path)\n"
new = ("    path = relative(artifact['path'])\n"
       "    _t152_step_trace('leaf', root + '/' + path, 'python:' + sys._getframe(1).f_code.co_name)\n"
       "    parent, name = os.path.split(root + '/' + path)\n")
text = replace_once(text, old, new)
old = "        else:\n            data = observed.data(path) if observed is not None else artifact_exact(donor['worktree_root'], artifact)\n"
new = ("        else:\n"
       "            _t152_step_trace('render', donor['worktree_root'] + '/' + path, 'python:current_inventory')\n"
       "            data = observed.data(path) if observed is not None else artifact_exact(donor['worktree_root'], artifact)\n")
text = replace_once(text, old, new)
old = "        actual = json.loads(observed.data(path) if observed is not None else artifact_exact(donor['worktree_root'], artifacts[path]))\n"
new = ("        _t152_step_trace('render', donor['worktree_root'] + '/' + path, 'python:canonical_renders')\n" + old)
text = replace_once(text, old, new)
old = "        require(exclude_bytes == base64.b64decode(exclude['after_base64'], validate=True), 'exclude bytes changed')\n"
new = ("        _t152_normalized_exclude = dict(exclude, path='<captured-exclude>')\n"
       "        _t152_step_trace('exclude', exclude_path, json.dumps(_t152_normalized_exclude, sort_keys=True, ensure_ascii=False, separators=(',', ':')))\n" + old)
text = replace_once(text, old, new)
fast.write_text(text)

text = verifier.read_text()
old = 'def _artifact_exact(root, artifact, opener):\n'
new = ("def _t152_step_trace(kind, path, detail):\n"
       "    with open(" + repr(str(steps)) + ", 'a', encoding='utf-8') as log:\n"
       "        log.write(kind + '\\thook\\t' + path + '\\t' + detail + '\\n')\n\n\n"
       + old + "    _t152_step_trace('leaf', root + '/' + artifact['path'], 'python:owner_verify')\n")
text = replace_once(text, old, new)
old = 'def _render_exact(root, render, opener):\n'
text = replace_once(text, old, old + "    _t152_step_trace('render', root + '/' + render['path'], 'python:owner_verify')\n")
verifier.write_text(text)

text = seed.read_text()
old = 'set -euo pipefail\n'
text = replace_once(text, old, old + 'export TRELLIS_ATTACH_POSTJOB=off\n')
seed.write_text(text)
PY
  # The step-level case adds one ordinary explicit-JSON render to the minimal
  # T14 release before it is sealed. Other cases keep the original fixture.
  if [[ "$BATS_TEST_DESCRIPTION" == 'step-level '* || "$BATS_TEST_DESCRIPTION" == 'captured donor '* ]]; then
    cp "$source/scripts/tests/helpers/t14-worktree.bash" "$fixture/t14-render.bash"
    python3 - "$fixture/t14-render.bash" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '\nJSON\n  (\n    cd "$repo"'
new = '''
JSON
  mkdir -p "$repo/core-rules/templates"
  printf '%s\\n' '{"fixture":{"owned":"value"}}' > "$repo/core-rules/templates/fixture.json"
  jq '.harnesses.claude.render += [{template:"core-rules/templates/fixture.json",destination:".claude/fixture-settings.json",merge:"explicit-json",mode:"0600",required:true}]' \\
    "$repo/core-rules/inheritance-manifest.json" > "$repo/core-rules/manifest.next"
  mv "$repo/core-rules/manifest.next" "$repo/core-rules/inheritance-manifest.json"
  (
    cd "$repo"'''
assert text.count(old) == 1
path.write_text(text.replace(old, new))
PY
    . "$fixture/t14-render.bash"
  fi
  # Captured-donor cases seal a marker-gated, in-place rewrite of the donor's
  # owned render into the fast path, just after admission or just after
  # PREFLIGHT: the inode stays, only the bytes change.
  if [[ "$BATS_TEST_DESCRIPTION" == 'captured donor '* ]]; then
    python3 - "$fixture/scripts/lib/attach-fastpath.py" "$T14_SANDBOX/t152-mutate" <<'PY'
from pathlib import Path
import sys
path, mark = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
def once(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)
once('\nclass Collector:\n', """
_t152_root = None


def _t152_mutate(point, donor):
    global _t152_root
    if donor is not None:
        _t152_root = donor['worktree_root']
    marker = %r + '.' + point
    if _t152_root is None or not os.path.exists(marker):
        return
    os.unlink(marker)
    with open(_t152_root + '/.claude/fixture-settings.json', 'r+b') as stream:
        data = stream.read()
        stream.seek(0)
        stream.write(b'{}' + b' ' * (len(data) - 3) + b'\\n')
    open(marker + '.done', 'w').close()


class Collector:
""" % mark)
once("    require(donor is not None, 'no exact donor')\n",
     "    _t152_mutate('admitted', donor)\n    require(donor is not None, 'no exact donor')\n")
old = "                    require(result.returncode == 0, 'existing attachment preflight refused: ' + result.stderr.decode(errors='replace')[-2000:])\n"
once(old, old + "                    _t152_mutate('preflight', None)\n")
path.write_text(text)
PY
  fi
  # A historical payload predates registry admission: its attach lacks the
  # capability the seed looks for, so the seed keeps selecting and verifying.
  if [[ "$BATS_TEST_DESCRIPTION" == 'historical payload '* ]]; then
    python3 - "$fixture/scripts/attach-project.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '\nattach_donor_select_canonical() {\n'
assert text.count(old) == 1
path.write_text(text.replace(old, '\nattach_donor_select_canonical_unavailable() {\n'))
PY
  fi
  REPO_ROOT="$fixture"
  t14_make_runtime_release
  t14_make_project
  t14_attach
  # shellcheck disable=SC2034  # Out-parameter: worktree-create-once.bats reads DONOR.
  DONOR="$(t14_owner_for_root "$T14_PROJECT")"
  : > "$TRACE"
  : > "$STEPS"
}

teardown() {
  t14_teardown_sandbox
}

count_verifications() {
  local owner="$1" phase="$2"
  awk -F '\t' -v owner="$owner" -v phase="$phase" '
    $3 == owner && ((phase == "pre" && $2 == "1") ||
                    (phase == "hook" && $2 != "1")) { n++ }
    END { print n + 0 }
  ' "$TRACE"
}

summarize_steps() {
  awk -F '\t' '{ n[$1 "\t" $2]++ } END { for (key in n) print key "\t" n[key] }' "$STEPS" | LC_ALL=C sort
}
