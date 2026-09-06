#!/usr/bin/env bats
# Run only in a disposable copied source under the caller's OS fence.
# All evidence is retained in the explicit test root; no teardown deletion.

setup_file() {
  export SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  : "${TRELLIS_CONFORMANCE_TEST_ROOT:?caller must supply a new retained directory outside source}"
  export EVIDENCE="$TRELLIS_CONFORMANCE_TEST_ROOT"
  export PYTHON="$(command -v python3)"
  "$PYTHON" - "$SOURCE" "$EVIDENCE" <<'PY'
import importlib.util
from pathlib import Path
import shutil
import sys
source, evidence = map(Path, sys.argv[1:])
assert not evidence.exists() and not evidence.resolve().is_relative_to(source)
evidence.mkdir()
module = importlib.util.spec_from_file_location('corpus', source / 'scripts/harness-conformance.py')
corpus = importlib.util.module_from_spec(module)
module.loader.exec_module(corpus)
negative = evidence / 'mutated-source'
for name in corpus.input_hashes(source):
    original, target = source / name, negative / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if original.is_symlink():
        target.symlink_to(original.readlink())
    else:
        shutil.copy2(original, target)
guard = negative / 'core-rules/hooks/reread-guard.sh'
text = guard.read_text()
assert text.count('*)   BUDGET=2 ;;') == 1
guard.write_text(text.replace('*)   BUDGET=2 ;;', '*)   BUDGET=99 ;;'))
(evidence / 'business-mutation.txt').write_text('Claude actual guard: L3 BUDGET=2 -> BUDGET=99; third attempt must no longer deny.\n')
PY
  # Negative actual-adapter behavior MUST be observed before the first green run.
  run "$PYTHON" "$EVIDENCE/mutated-source/scripts/harness-conformance.py" \
    --source "$EVIDENCE/mutated-source" --scratch "$EVIDENCE/negative-scratch"
  printf '%s\n' "$output" > "$EVIDENCE/negative.json"
  printf '%s\n' "$status" > "$EVIDENCE/negative.exit"
  [ "$status" -eq 1 ]
  "$PYTHON" - "$EVIDENCE/negative.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r['complete'] and not r['passed']
assert [(c['id'], c['assertion']) for c in r['cases'] if c['assertion'] != 'pass'] == [('claude.reread-budget', 'fail')]
PY
  run "$PYTHON" "$SOURCE/scripts/harness-conformance.py" --source "$SOURCE" --scratch "$EVIDENCE/positive-scratch"
  printf '%s\n' "$output" > "$EVIDENCE/positive.json"
  printf '%s\n' "$status" > "$EVIDENCE/positive.exit"
  [ "$status" -eq 0 ]
}

@test "complete ordered16 corpus uses actual adapters and cannot claim native outcomes" {
  "$PYTHON" - "$SOURCE" "$EVIDENCE/positive.json" <<'PY'
import importlib.util, json, sys
from pathlib import Path
s, receipt = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('corpus', s / 'scripts/harness-conformance.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
r = json.loads(receipt.read_text())
assert set(r) == {'schema_version','evidence_class','source_root','source_inputs','scratch_root','runtime','cases','complete','passed','limitations'}
assert r['complete'] is True and r['passed'] is True and r['schema_version'] == 1
assert r['evidence_class'] == 'fixture' and [x['id'] for x in r['cases']] == c.CASE_IDS
assert r['source_inputs'] == c.input_hashes(s)
assert set(r['runtime']) == {'bash', 'python', 'node', 'jq', 'git'}
for x in r['cases']:
    assert set(x) == {'id','harness','evidence_class','native_outcome','native_loaded','native_exercised','assertion','reason','observations','commands'}
    assert x['assertion'] == 'pass' and x['reason'] and x['observations']
    assert x['native_outcome'] == 'unknown' and x['native_loaded'] is None and x['native_exercised'] is None
assert r['cases'][2]['evidence_class'] == 'registration'
assert r['cases'][10]['observations']['decisions'][0]['capability_status'] == 'enforced'
PY
}

@test "business mutation is complete nonpassing and hash-bound, not a setup failure" {
  "$PYTHON" - "$EVIDENCE" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); good = json.loads((p/'positive.json').read_text()); bad = json.loads((p/'negative.json').read_text())
assert bad['complete'] and not bad['passed'] and len(bad['cases']) == 16
assert bad['cases'][0]['assertion'] == 'fail'
assert 'warn 3/99' in bad['cases'][0]['observations']['responses'][2]['stderr']
changed = [k for k in good['source_inputs'] if good['source_inputs'][k] != bad['source_inputs'][k]]
assert changed == ['core-rules/hooks/reread-guard.sh']
PY
}

@test "every raw command stream is a retained regular scratch-relative file" {
  "$PYTHON" - "$EVIDENCE" <<'PY'
import json, sys
from pathlib import Path
for name in ['positive', 'negative']:
    r = json.loads((Path(sys.argv[1]) / (name+'.json')).read_text()); root = Path(r['scratch_root'])
    assert json.loads((root/'source-inputs-after.json').read_text()) == r['source_inputs']
    for case in r['cases']:
        for c in case['commands']:
            assert set(c) == {'argv','cwd','exit_code','status','stdout_path','stderr_path'}
            assert c['status'] == 'exited' and type(c['exit_code']) is int and c['argv']
            for key in ['stdout_path','stderr_path']:
                p = Path(c[key]); full = root/p
                assert not p.is_absolute() and full.resolve().is_relative_to(root)
                assert full.is_file() and not full.is_symlink()
PY
}

@test "missing dependencies produce explicit unknown cases and nonzero receipt" {
  mkdir "$EVIDENCE/no-tools"
  run env PATH="$EVIDENCE/no-tools" "$PYTHON" "$SOURCE/scripts/harness-conformance.py" \
    --source "$SOURCE" --scratch "$EVIDENCE/missing-dependency-scratch"
  printf '%s\n' "$output" > "$EVIDENCE/missing-dependency.json"
  printf '%s\n' "$status" > "$EVIDENCE/missing-dependency.exit"
  [ "$status" -eq 1 ]
  "$PYTHON" - "$EVIDENCE/missing-dependency.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert not r['complete'] and not r['passed'] and len(r['cases']) == 16
assert all(c['assertion'] == 'unknown' and 'dependencies' in c['reason'] for c in r['cases'])
assert r['runtime']['node']['executable'] is None
PY
}

@test "malformed source produces unknown non-green without consuming external symlinks" {
  mkdir "$EVIDENCE/malformed-source"
  run "$PYTHON" "$SOURCE/scripts/harness-conformance.py" --source "$EVIDENCE/malformed-source" --scratch "$EVIDENCE/malformed-scratch"
  printf '%s\n' "$output" > "$EVIDENCE/malformed.json"
  printf '%s\n' "$status" > "$EVIDENCE/malformed.exit"
  [ "$status" -eq 1 ]
  "$PYTHON" - "$EVIDENCE/malformed.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert not r['complete'] and not r['passed'] and all(c['assertion'] == 'unknown' for c in r['cases'])
PY
  mkdir -p "$EVIDENCE/escaping-source/core-rules"
  ln -s "$SOURCE/core-rules/hooks" "$EVIDENCE/escaping-source/core-rules/hooks"
  run "$PYTHON" "$SOURCE/scripts/harness-conformance.py" --source "$EVIDENCE/escaping-source" --scratch "$EVIDENCE/escaping-scratch"
  printf '%s\n' "$output" > "$EVIDENCE/escaping.json"
  printf '%s\n' "$status" > "$EVIDENCE/escaping.exit"
  [ "$status" -eq 1 ]
  "$PYTHON" - "$EVIDENCE/escaping.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert not r['complete'] and not r['passed']
assert all(c['assertion'] == 'unknown' and 'escaping source symlink' in c['reason'] for c in r['cases'])
PY
}

@test "internal transitive links bind intermediate spelling and target ancestors" {
  "$PYTHON" - "$SOURCE" "$EVIDENCE" <<'PY'
import hashlib, importlib.util, json, sys
from pathlib import Path
source, evidence = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('corpus', source/'scripts/harness-conformance.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
root = evidence/'link-source'; root.mkdir()
(root/'extra').mkdir(); (root/'extra/real').mkdir()
(root/'extra/real/file').write_bytes(b'raw\x00target\xff')
(root/'extra/ancestor').symlink_to('real', target_is_directory=True)
(root/'extra/middle').symlink_to('ancestor/file')
(root/'entry').symlink_to('extra/middle')
c.INPUT_ROOTS = ['entry']
before = c.input_hashes(root)
(root/'extra/middle').unlink(); (root/'extra/middle').symlink_to('./ancestor/file')
after = c.input_hashes(root)
(evidence/'link-binding.json').write_text(json.dumps({'before': before, 'after': after}, indent=2))
assert before != after, 'intermediate spelling mutation escaped input drift detection'
assert set(before) == {'entry', 'extra/middle', 'extra/ancestor', 'extra/real/file'}
assert [k for k in before if before[k] != after[k]] == ['extra/middle']
assert before['extra/real/file']['sha256'] == hashlib.sha256(b'raw\x00target\xff').hexdigest()
# Reject a hop that leaves source even if its eventual target comes back inside.
external = evidence/'external-return'; external.symlink_to(root/'extra/real/file')
(root/'extra/middle').unlink(); (root/'extra/middle').symlink_to(external)
try:
    c.input_hashes(root)
except c.Incomplete:
    pass
else:
    raise AssertionError('escaping intermediate hop accepted')
for target in ['../entry', '../extra']:
    (root/'extra/middle').unlink(); (root/'extra/middle').symlink_to(target)
    try:
        c.input_hashes(root)
    except c.Incomplete:
        pass
    else:
        raise AssertionError('symlink or directory cycle accepted')
PY
}

@test "deadline crossing during final hashing cannot produce a passing receipt" {
  "$PYTHON" - "$SOURCE" "$EVIDENCE" <<'PY'
import contextlib, importlib.util, io, json, sys
from pathlib import Path
from unittest.mock import patch
source, evidence = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('corpus', source/'scripts/harness-conformance.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
clock = [0.0]; phase = [0]; crossed = [False]
real_hashes, real_sha = c.input_hashes, c.hashlib.sha256
class Hash:
    def __init__(self, data=b''):
        self.inner = real_sha(data)
        if data:
            self.cross()
    def cross(self):
        if phase[0] == 2:
            clock[0] = 181.0
            crossed[0] = True
    def update(self, data):
        self.inner.update(data); self.cross()
    def hexdigest(self):
        return self.inner.hexdigest()
def hashes(*args, **kwargs):
    phase[0] += 1
    return real_hashes(*args, **kwargs)
def fixture_observe(self, case):
    case['observations']['deadline_fixture'] = True
output = io.StringIO()
with patch.object(c.time, 'monotonic', lambda: clock[0]), \
     patch.object(c, 'input_hashes', hashes), patch.object(c.hashlib, 'sha256', Hash), \
     patch.object(c.Corpus, 'runtimes', lambda self: None), \
     patch.object(c.Corpus, 'observe', fixture_observe), \
     patch.object(sys, 'argv', ['corpus', '--source', str(source), '--scratch', str(evidence/'deadline-scratch')]), \
     contextlib.redirect_stdout(output):
    code = c.main()
r = json.loads(output.getvalue())
(evidence/'deadline.json').write_text(output.getvalue())
(evidence/'deadline.exit').write_text(str(code)+'\n')
assert crossed[0] and phase[0] == 2, 'clock fixture did not reach final hashing'
assert all(x['assertion'] == 'pass' for x in r['cases']), 'fixture failed before final hashing'
assert code == 1 and not r['complete'] and not r['passed'], 'green receipt after 180-second deadline'
assert any('deadline' in x for x in r['limitations'])
PY
}

@test "existing scratch and in-source scratch are rejected without writes" {
  run "$PYTHON" "$SOURCE/scripts/harness-conformance.py" --source "$SOURCE" --scratch "$EVIDENCE/positive-scratch"
  [ "$status" -eq 2 ]
  run "$PYTHON" "$SOURCE/scripts/harness-conformance.py" --source "$SOURCE" --scratch "$SOURCE/forbidden-new-scratch"
  [ "$status" -eq 2 ]
  [ ! -e "$SOURCE/forbidden-new-scratch" ]
}
