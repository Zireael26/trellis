#!/usr/bin/env python3
"""Test-only small-config startup/module/compile/chain profile, not SC9.

python3 -I scripts/tests/helpers/metadata-small-profile.py --out /tmp/new-dir --trace

Five interleaved observations per arm by default; private HOME/TH/TMP/Git config,
exact launcher/assembled Perl retained. No normal-run timeout or production edit.
Counterfactual chain copies intentionally do not validate JSON: diagnostics ONLY.
Do not sum standalone module costs or treat counterfactual arms as valid routes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import runpy
import shutil
import signal
import statistics
import subprocess
import time


def observed(argv, env):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    load_start = list(os.getloadavg())
    start = time.monotonic()
    child = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = child.communicate()
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        raise
    wall = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {"exit": child.returncode, "wall_seconds": wall,
            "user_cpu_seconds": after.ru_utime-before.ru_utime,
            "sys_cpu_seconds": after.ru_stime-before.ru_stime,
            "load_start": load_start, "load_end": list(os.getloadavg())}, stdout, stderr


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    p.add_argument("--runs", type=int, choices=range(1, 21), default=5)
    p.add_argument("--trace", action="store_true", help="one separate strace per complete route if available")
    args = p.parse_args()
    repo = args.repo.resolve(strict=True)
    out = args.out.absolute()
    out.mkdir(mode=0o700)
    out = out.resolve(strict=True)
    for name in ("home", "trellis-home", "tmp"):
        (out/name).mkdir(mode=0o700)
    (out/'gitconfig').write_text('')
    env = {"HOME": str(out/'home'), "TRELLIS_HOME": str(out/'trellis-home'),
           "TMPDIR": str(out/'tmp'), "GIT_CONFIG_GLOBAL": str(out/'gitconfig'),
           "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    fixture = runpy.run_path(str(repo/'scripts/tests/helpers/metadata-large-config-probe.py'))['fixture_bytes']
    raw, _ = fixture(0, 'string')
    assert len(raw) == 181
    config = out/'trellis-home/config.json'
    config.write_bytes(raw)
    config.chmod(0o600)
    template = (repo/'scripts/trellis-launcher.sh').read_text()
    def launcher(name, text):
        path = out/name
        path.write_text(text)
        path.chmod(0o700)
        return str(path)
    def changed(old, new):
        assert template.count(old) == 1, (old, template.count(old))
        return template.replace(old, new, 1)
    actual = launcher('actual-launcher', template)
    # Capture the real builder output, including route-specific helper selection.
    # This untimed test copy only writes its trusted -e argument and exits.
    selector = 'perl_bin="$(command -v perl)"'
    script = out/'actual-metadata.pl'
    collector = out/'capture-program'
    collector.write_text('#!/usr/bin/python3\nimport pathlib,sys\nassert sys.argv[1]=="-e"\npathlib.Path('+repr(str(script))+').write_text(sys.argv[2])\n')
    collector.chmod(0o700)
    capturing = launcher('capture-launcher', changed(selector, 'perl_bin="'+str(collector)+'"'))
    subprocess.run([capturing, '--version'], env=env, check=True, capture_output=True)
    program = script.read_text()
    generation_lines = [line.strip().split(' ||',1)[0] for line in template.splitlines() if 'program="$(launcher_metadata_perl' in line]
    assert len(generation_lines) == 1
    empty_generated = launcher('chain-empty-generated-program', changed(generation_lines[0], "program='exit 0;'"))
    empty_executed = launcher('chain-real-generation-empty-perl', changed('"$perl_bin" -e "$program" "$mode" "$argc"', '"$perl_bin" -e "exit 0;" "$mode" "$argc"'))
    true_chain = launcher('chain-real-generation-bin-true', changed('perl_bin="$(command -v perl)"', "perl_bin='/usr/bin/true'"))
    privacy_only = launcher('bootstrap-and-privacy-only', changed('launcher_metadata() {\n', 'launcher_metadata() {\n  return 0 # TEST ONLY, no JSON admission\n'))
    canonical_ref = 'b7a3bddca6dc8e405695fe54fc2c4ef1fa836215'
    canonical_bytes = subprocess.run(['/usr/bin/git', '-C', str(repo), 'show', canonical_ref+':scripts/trellis-launcher.sh'],
                                     env=env, capture_output=True, check=True).stdout
    canonical = launcher('canonical-jq', canonical_bytes.decode())
    perl = '/usr/bin/perl'
    arms = {
        'perl-startup': [perl, '-e', 'exit 0;'],
        'load-JSON-PP': [perl, '-e', 'require JSON::PP;'],
        'load-Encode': [perl, '-e', 'require Encode;'],
        'load-Fcntl': [perl, '-e', 'require Fcntl;'],
        'load-MIME-Base64': [perl, '-e', 'require MIME::Base64;'],
        'load-all-four': [perl, '-e', 'require JSON::PP; require Encode; require Fcntl; require MIME::Base64;'],
        'actual-script-compile-only': [perl, '-c', '-e', program, 'version', '1'],
        'actual-script-direct-e': [perl, '-e', program, 'version', '1'],
        'actual-script-direct-file': [perl, str(script), 'version', '1'],
        'chain-empty-generated-program': [empty_generated, '--version'],
        'chain-real-generation-empty-perl': [empty_executed, '--version'],
        'chain-real-generation-bin-true': [true_chain, '--version'],
        'bootstrap-and-privacy-only': [privacy_only, '--version'],
        'complete-perl-launcher': [actual, '--version'],
        'complete-canonical-jq': [canonical, '--version'],
    }
    expected_version = b'trellis 1.2.3 (configured; not verified)\n'
    version_arms = {'actual-script-direct-e', 'actual-script-direct-file', 'complete-perl-launcher', 'complete-canonical-jq'}
    result = {"kind": "T59-small-config-diagnostic-not-SC9", "config_bytes": len(raw),
              "config_sha256": hashlib.sha256(raw).hexdigest(), "runs_per_arm": args.runs,
              "warmups": 0, "normal_run_timeout": None,
              "metadata_SC9_budget_ms": {"p50": 35, "p90": 50},
              "host": {"platform": platform.platform(), "logical_cpus": os.cpu_count(),
                       "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None},
              "launcher_sha256": hashlib.sha256(template.encode()).hexdigest(),
              "assembled_perl_sha256": hashlib.sha256(program.encode()).hexdigest(),
              "canonical_ref": canonical_ref, "observations": [],
              "notes": ["Standalone module arms each include Perl startup; do not sum them.",
                        "Compile-only includes BEGIN/module loads, not just parser work.",
                        "Counterfactual chain copies intentionally skip JSON validation and are not runtime choices.",
                        "strace is separate and excluded from untraced observations.",
                        "The instrumented diagnostic preloads Time::HiRes/shared dependencies; standalone untraced arms remain the cost reference."]}
    receipt = out/'results.json'
    for number in range(1, args.runs+1):
        for label, argv in arms.items():
            row, stdout, stderr = observed(argv, env)
            (out/f'{label}-{number}.stdout').write_bytes(stdout)
            (out/f'{label}-{number}.stderr').write_bytes(stderr)
            row.update(arm=label, run=number)
            result['observations'].append(row)
            receipt.write_text(json.dumps(result, indent=2)+'\n')
            assert row['exit'] == 0, (label, row, stdout, stderr)
            if label in version_arms:
                assert stdout == expected_version and stderr == b'', (label, stdout, stderr)
            print(json.dumps(row, sort_keys=True), flush=True)
    # One instrumented diagnostic: exact full script, require timings inside BEGIN
    # and compile/runtime split. Profiler's Time::HiRes load is excluded from its
    # internal compile clock but INCLUDED in outer wall/CPU; not a baseline arm.
    instrumented = program
    for name in ('JSON::PP','Encode','Fcntl','MIME::Base64'):
        guard = 'require '+name+';'
        assert instrumented.count(guard) == 1
        instrumented = instrumented.replace(guard, "T59Profile::load('"+name+"',sub { "+guard+" });", 1)
    preamble = r'''package T59Profile;
our (%modules,$start,$compiled);
BEGIN { require Time::HiRes; $start=Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); }
sub load { my($name,$f)=@_; my $t=Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); $f->(); $modules{$name}+=Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())-$t; }
CHECK { $compiled=Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())-$start; }
END { print STDERR "T59_SMALL_PHASES ",JSON::PP->new->canonical->encode({module_seconds=>\%modules,compile_including_modules_seconds=>$compiled,runtime_seconds=>Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())-$start-$compiled}),"\n"; }
package main;
'''
    profiled = out/'instrumented-actual-metadata.pl'
    profiled.write_text(preamble+instrumented)
    row, stdout, stderr = observed([perl, str(profiled), 'version', '1'], env)
    (out/'instrumented.stdout').write_bytes(stdout)
    (out/'instrumented.stderr').write_bytes(stderr)
    marker = b'T59_SMALL_PHASES '
    phase = [line[len(marker):] for line in stderr.splitlines() if line.startswith(marker)]
    assert row['exit'] == 0 and stdout == expected_version and len(phase) == 1, (row, stdout, stderr)
    result['instrumented_full_script'] = dict(row, phases=json.loads(phase[0]))
    if args.trace:
        strace = shutil.which('strace', path=env['PATH'])
        result['strace'] = {'available': bool(strace), 'observations_are_untraced': True}
        if strace:
            for label, command in (('perl', actual), ('jq', canonical)):
                trace = out/f'exec-chain-{label}.strace'
                row, stdout, stderr = observed([strace, '-f', '-ttt', '-T', '-s', '80', '-e', 'trace=process', '-o', str(trace), command, '--version'], env)
                (out/f'exec-chain-{label}.stderr').write_bytes(stderr)
                result['strace'][label] = dict(row, path=str(trace))
                assert row['exit'] == 0 and stdout == expected_version, (label, row, stdout, stderr)
    result['median_wall_seconds'] = {label: statistics.median(row['wall_seconds'] for row in result['observations'] if row['arm'] == label) for label in arms}
    receipt.write_text(json.dumps(result, indent=2)+'\n')
    print(f'Retained {receipt}; SC9 metadata budget35/50ms remains unqualified', flush=True)


if __name__ == '__main__':
    main()
