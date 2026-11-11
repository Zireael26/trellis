#!/usr/bin/env bats
# Spec 074 T54, slow tier: git-worktree-add attaches, joins, detaches and
# removes a worktree 30 times in one bench sandbox, and every run exits 0.
# Before T54 the bench removed each attached worktree without detaching it,
# which orphaned its owner record, so every later attach exited 3.
#
# Cost: a release install and fixture attach (about 3 minutes quiet), then 30
# full attach/postjob/detach cycles. 2026-11-01 under load 20-37 the file took
# most of an hour. It runs only with TRELLIS_SLOW_TESTS=1, which
# scripts/weekly-full-battery.py sets; the per-change battery skips it. The
# teardown-failure cases stay in trellis-latency-bench.bats.

SOURCE_ROOT="$(CDPATH='' cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
BENCH="$SOURCE_ROOT/scripts/bench/trellis-latency.py"

assert_repeat_receipt() {
  jq -e '
    .schema == "trellis-latency-bench/1" and .status == "ok"
    and .config.lifecycle_runs >= 30 and .config.warmup == 0
    and (.results | map(.id) == ["git-worktree-add (hooks off)", "git-worktree-add"])
    and all(.results[]; . as $row
      | .runs >= 30 and .warmup == 0 and (.observations | length) == $row.runs
      and .error == null and .teardown_error == null
      and (.members | length) == 1 and .members[0].exit_codes == [0]
      and all(.observations[]; .case_id == $row.id and .warmup == false
        and .exit == 0 and .member_exits == [0] and .readiness == true
        and .timeout == false and .callback_timeout == false and .exec_error == false
        and .aggregation_eligible == ($row.hooks | not))
      and (if .hooks then
        .status == "diagnostic" and .sc1_eligible == false
        and .wall_ms == null and .cpu_ms == null and .serial_sum_p50_ms == null
        and all(.members[]; .wall_ms == null)
      else .hooks == false and .status == "ok" and .wall_ms.n == $row.runs end))
  ' "$1" >/dev/null
}

setup() {
  [ "${TRELLIS_SLOW_TESTS:-}" = 1 ] ||
    skip "slow tier: 30 attach/detach cycles; set TRELLIS_SLOW_TESTS=1 (the weekly full battery does)"
  ROOT="$(CDPATH='' cd -- "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$ROOT/out" "$ROOT/tmp"
}

teardown() {
  if [ -n "${ROOT:-}" ]; then
    # Keep the actual 30-observation receipt outside both Bats and the Git
    # fence cleanup. On a bench failure also preserve its sandbox evidence.
    python3 -I - "$ROOT" <<'PY' >&3 || return 1
import json,os,shutil,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]); output=root/'out'
if not output.is_dir() or not any(output.iterdir()): sys.exit(0)
fence=Path(os.environ.get('TRELLIS_TEST_GIT_FENCE_ROOT',os.environ['TMPDIR'])).resolve()
store=fence.parent/'trellis-bench-test-evidence'
if store.is_symlink(): raise RuntimeError('refusing symlinked evidence store')
store.mkdir(mode=0o700,exist_ok=True)
destination=Path(tempfile.mkdtemp(prefix='t54-repeat-'+root.name+'-',dir=store))
shutil.copytree(output,destination/'receipts',symlinks=True)
failed=any(json.loads(path.read_text()).get('status')!='ok' for path in output.glob('bench-*.json'))
if failed and (root/'tmp').is_dir(): shutil.copytree(root/'tmp',destination/'sandboxes',symlinks=True)
print('# retained T54 receipts/evidence: '+str(destination))
PY
  fi
  # The kept sandbox holds a read-only installed release.
  [ -z "${ROOT:-}" ] || chmod -R u+w "$ROOT" 2>/dev/null || true
}

@test "git-worktree-add: 30 attached worktrees, each joined, detached and removed; all exits 0; fixture restored" {
  export HOME="$ROOT/home" TRELLIS_HOME="$ROOT/trellis-home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  run python3 -I "$BENCH" --source "$SOURCE_ROOT" --sections lifecycle --lifecycle-items git-worktree-add \
    --lifecycle-runs 30 --warmup 0 --condition functional-t54-no-timing-claim \
    --sandbox-base "$ROOT/tmp" --keep --label repeat --out "$ROOT/out"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  # Before T54 every hooks-on run after the first exited 3: the plain remove
  # orphaned the owner record and the next attach in the checkout conflicted.
  assert_repeat_receipt "$ROOT/out/"bench-*-repeat.json || { jq . "$ROOT/out/"bench-*-repeat.json >&2; return 1; }

  local sb
  sb="$(find "$ROOT/tmp" -maxdepth 1 -name 'trellis-bench.*')"
  [ -d "$sb" ]
  [ "$(find "$sb/trellis-home/state/attachments" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  jq -e --arg root "$sb/projects/bench-fixture" \
    '[.projects[].checkouts[].worktrees[]] | length == 1 and .[0].root == $root and (.[0].attachment_id | type == "string")' \
    "$sb/trellis-home/registry.json" >/dev/null
  [ "$(git -C "$sb/projects/bench-fixture" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
  [ -z "$(git -C "$sb/projects/bench-fixture" branch --list 'bench-wt-*')" ]
  [ -z "$(find "$sb/trellis-home/state/attachment-journals" -mindepth 1 -print -quit)" ]
  run pgrep -f "attach-postjob\.sh run --target $sb/worktrees/"
  [ "$status" -eq 1 ]
}

@test "T54 receipt contract admits 30 diagnostic attachments but rejects incomplete or failed teardown evidence" {
  python3 -I - "$ROOT" <<'PY'
import copy,json,sys
from pathlib import Path
root=Path(sys.argv[1]); rows=[]
for hooks in (False,True):
    name='git-worktree-add'+('' if hooks else ' (hooks off)')
    rows.append({'id':name,'runs':30,'warmup':0,'hooks':hooks,'status':'diagnostic' if hooks else 'ok',
      'sc1_eligible':False,'wall_ms':None if hooks else {'n':30},'cpu_ms':None,'serial_sum_p50_ms':None,
      'members':[{'exit_codes':[0],'wall_ms':None if hooks else {'n':30}}],
      'observations':[{'case_id':name,'exit':0,'member_exits':[0],'readiness':True,'warmup':False,
                       'timeout':False,'callback_timeout':False,'exec_error':False,'aggregation_eligible':not hooks} for _ in range(30)]})
valid={'schema':'trellis-latency-bench/1','status':'ok','config':{'lifecycle_runs':30,'warmup':0},'results':rows}
(root/'valid-repeat.json').write_text(json.dumps(valid))
for mode in ('short','not-ready','teardown-error','partial-stats','wrong-exit','warmup','eligible-diagnostic'):
    bad=copy.deepcopy(valid); row=bad['results'][1]
    if mode=='short': row['observations'].pop()
    elif mode=='not-ready': row['observations'][-1]['readiness']=False
    elif mode=='teardown-error': row['error']={'phase':'after','type':'TeardownError','message':'injected'}
    elif mode=='partial-stats': row['wall_ms']={'n':30}
    elif mode=='wrong-exit': row['members'][0]['exit_codes']=[3]
    elif mode=='warmup': row['observations'][-1]['warmup']=True
    elif mode=='eligible-diagnostic': row['observations'][-1]['aggregation_eligible']=True
    (root/(mode+'-repeat.json')).write_text(json.dumps(bad))
PY
  run assert_repeat_receipt "$ROOT/valid-repeat.json"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  local mode
  for mode in short not-ready teardown-error partial-stats wrong-exit warmup eligible-diagnostic; do
    run assert_repeat_receipt "$ROOT/$mode-repeat.json"
    [ "$status" -eq 1 ] || { printf '%s: %s\n' "$mode" "$output" >&2; return 1; }
  done
}

@test "T54 injected teardown failure fails the 30-run request and retains evidence" {
  run python3 -I - "$BENCH" "$ROOT" <<'PY'
import json,runpy,sys
from pathlib import Path
G=runpy.run_path(sys.argv[1])['main'].__globals__; root=Path(sys.argv[2]); injected=[]
def build(*args):
    sb=G['Sandbox'](str(root/'tmp/trellis-bench.injected'))
    for directory in (Path(sb.project),sb.scratch,Path(sb.home),Path(sb.trellis_home),Path(sb.tmp)):
        directory.mkdir(parents=True,exist_ok=True)
    sb.meta={}
    return sb
G['build_sandbox']=build; G['is_checkout']=lambda *_:False; G['gate_or_bats_running']=lambda:False
def after(iteration):
    injected.append(iteration)
    raise G['TeardownError']('injected T54 teardown failure')
def lifecycle(sb,args,results):
    results.append(G['measure']('git-worktree-add',[G['Member']('git-worktree-add',[sys.executable,'-I','-c','pass'])],
        b'',sb.project,sb.env(),args.lifecycle_runs,args.warmup,sb.scratch,after=after,
        extra={'section':'lifecycle','fixture_id':'T54-injected','boundary_id':'teardown-fault',
               'hooks':True,'sc1_eligible':False,'timing_scope':'completion-readiness-diagnostic-only'}))
G['bench_lifecycle']=lifecycle
code=G['main'](['--sections','lifecycle','--lifecycle-items','git-worktree-add','--lifecycle-runs','30','--warmup','0',
                '--label','injected-teardown','--out',str(root/'out'),'--sandbox-base',str(root/'tmp')])
receipt=json.loads(next((root/'out').glob('bench-*-injected-teardown.json')).read_text())
assert code==1 and receipt['status']=='failed', (code,receipt)
assert injected==[0] and receipt['sandbox']['kept'] and receipt['sandbox']['quarantined'], receipt
record=receipt['results'][0]
assert record['status']=='failed' and record['runs']==30 and len(record['observations'])==1
assert record['error']['type']=='TeardownError' and record['error']['phase']=='after'
assert record['observations'][0]['exit']==0 and record['observations'][0]['readiness'] is False
assert record['wall_ms'] is None and all(member['wall_ms'] is None for member in record['members'])
assert (root/'tmp/trellis-bench.injected').is_dir()
print('injected teardown failed the run after its first successful operation; evidence retained, no partial stats')
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}
