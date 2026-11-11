#!/usr/bin/env python3
"""Probe the *actual* integrated Linux ACL fallback in private fixtures.

Pass the pre-fix 1b281eaa checkout's release-store.sh and a real packaged
release under an operator-specified private sandbox root. Its expected Python
exit 1 is historical; the fixed verifier instead returns 0. This script reads the real release
but never changes it. Synthetic trees, HOME, TRELLIS_HOME, TMPDIR and Git config
are private, and removed on exit. Exactly one separately labelled fallback
call is timed; this is not a full command or SC benchmark.

Example:
 python3 -I release-symlink-acl-fallback-linux.py \
   --store-lib /private/checkout/scripts/lib/release-store.sh \
   --sandbox-root /home/user/w/tmp --real-release /home/user/w/tmp/run/trellis-home/releases/1.4.1
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time


def emit(case, verdict, detail):
    print(f'{case}: {verdict} {detail}', flush=True)


def run(argv, env):
    return subprocess.run(argv, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def count_links(path):
    count = 0
    def fail(error):
        raise error
    for base, dirs, files in os.walk(path, topdown=True, onerror=fail, followlinks=False):
        for name in dirs + files:
            if os.path.islink(os.path.join(base, name)):
                count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store-lib', required=True, type=Path)
    parser.add_argument('--real-release', required=True, type=Path)
    parser.add_argument('--sandbox-root', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() == 0:
        emit('host', 'INCONCLUSIVE', 'requires Linux and a non-root user')
        return 5
    library = args.store_lib.resolve(strict=True)
    program = library.parent / 'release_verify.py'
    release = args.real_release.resolve(strict=True)
    sandbox_root = args.sandbox_root.resolve(strict=True)
    if str(sandbox_root) == '/' or os.path.commonpath([str(release), str(sandbox_root)]) != str(sandbox_root):
        emit('scope', 'INCONCLUSIVE', 'release must be inside the supplied non-root sandbox')
        return 5
    live_home = os.environ.get('HOME', '')
    live_trellis = Path(live_home, '.trellis').resolve() if live_home else None
    if live_trellis and os.path.commonpath([str(release), str(live_trellis)]) == str(live_trellis):
        emit('scope', 'INCONCLUSIVE', 'refusing a live Trellis home')
        return 5
    if not program.is_file() or not (release / 'release.json').is_file() or not (release / 'payload').is_dir():
        emit('scope', 'INCONCLUSIVE', 'missing oracle or real release record/payload')
        return 5
    emit('host', 'INFO', f'{platform.platform()} uid={os.geteuid()}')
    with tempfile.TemporaryDirectory(prefix='trellis-acl-fallback.') as tmp:
        root = Path(tmp)
        os.chmod(root, 0o700)
        for name in ('home', 'trellis', 'tmp'):
            (root / name).mkdir(mode=0o700)
        (root / 'gitconfig').write_text('')
        env = dict(os.environ, HOME=str(root / 'home'), TRELLIS_HOME=str(root / 'trellis'),
                   TMPDIR=str(root / 'tmp'), GIT_CONFIG_GLOBAL=str(root / 'gitconfig'),
                   GIT_CONFIG_NOSYSTEM='1', LC_ALL='C')
        env.pop('TRELLIS_PYTHON', None)
        env.pop('BASH_ENV', None)
        env.pop('ENV', None)
        shell = 'source "$1"; release_store_release_has_no_acl "$2"'
        shell_forced = 'source "$1"; release_store_verify_batch() { return 1; }; release_store_release_has_no_acl "$2"'
        outcome = 0
        for label in ('no-link', 'root-link', 'nested-link', 'two-links'):
            tree = root / label
            (tree / 'payload' / 'nested').mkdir(parents=True)
            (tree / 'payload' / 'file').write_text('fixture\n')
            if label in ('root-link', 'two-links'):
                (tree / 'payload' / 'link').symlink_to('file')
            if label in ('nested-link', 'two-links'):
                (tree / 'payload' / 'nested' / 'link').symlink_to('../file')
            links = count_links(tree)
            py_results = []
            wrapper_results = []
            for _ in range(3):
                py = run(['python3', '-I', str(program), str(tree), 'acl'], env)
                wrapper = run(['/bin/bash', '-c', shell, 'probe', str(library), str(tree)], env)
                py_results.append(py.returncode)
                wrapper_results.append(wrapper.returncode)
            expected_python = 0 if links == 0 else 1
            ok = all(rc == expected_python for rc in py_results) and all(rc == 0 for rc in wrapper_results)
            emit(label, 'PASS' if ok else 'FAIL',
                 f'links={links} python={py_results} canonical_wrapper={wrapper_results}')
            if not ok:
                outcome = 1
        links = count_links(release)
        record_bytes = (release / 'release.json').read_bytes()
        record = json.loads(record_bytes)
        declared = sum(row.get('mode') == '120000' for row in record['tree'])
        emit('real-release', 'INFO', f'path={release} version={record.get("version")} '
             f'links_observed={links} manifest_links={declared} '
             f'record_sha256={hashlib.sha256(record_bytes).hexdigest()}')
        if links != declared or links == 0:
            emit('real-scope', 'INCONCLUSIVE', 'choose an intact packaged fixture containing symlinks')
            return 5
        py = run(['python3', '-I', str(program), str(release), 'acl'], env)
        wrapper = run(['/bin/bash', '-c', shell, 'probe', str(library), str(release)], env)
        ok = py.returncode == 1 and wrapper.returncode == 0
        emit('real-canonical', 'PASS' if ok else 'FAIL',
             f'python={py.returncode} wrapper={wrapper.returncode}')
        if not ok:
            outcome = 1
        observed_load = list(os.getloadavg())
        start = time.monotonic_ns()
        forced = run(['/bin/bash', '-c', shell_forced, 'probe', str(library), str(release)], env)
        elapsed = (time.monotonic_ns() - start) / 1_000_000
        ok = forced.returncode == wrapper.returncode
        emit('real-fallback-once', 'PASS' if ok else 'FAIL',
             f'wrapper_exit={forced.returncode} elapsed_ms={elapsed:.3f} load={observed_load} '
             '(includes one bash startup and library source; no Python ACL pass)')
        if not ok:
            outcome = 1
        emit('scope', 'INFO', 'clean sampled trees on this filesystem only; earlier ACL/errors can short-circuit')
        emit('result', 'PASS' if outcome == 0 else 'FAIL', f'exit={outcome}')
        return outcome


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        emit('result', 'INCONCLUSIVE', f'{type(exc).__name__}: {exc}')
        sys.exit(5)
