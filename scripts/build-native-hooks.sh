#!/usr/bin/env bash
# Source-checkout release tool. Never compile at install/runtime.
# build <target> [asset-directory] | verify [--source <checkout>] [asset-directory]
# --source is an opt-in T71/T46 check of the exact input set/digests against a
# clean checkout's HEAD; unrelated/asset-only commits are allowed. Without it,
# verify remains self-contained and does not require build sources or Git.
# Literal include_str!/include_bytes! edges are discovered from tracked Rust
# sources; computed include paths fail closed instead of escaping provenance.
# Conservative lexical closure, not macro/cfg expansion: cfg/stringify includes
# and literal path= attributes are required even when not module attributes.
# Only top-level literal module paths are supported; nested paths refuse.
# Rust outside the scanned crate-source context (including transitive include!)
# may not declare modules: implicit child-module resolution is not implemented.
# Neither mode establishes rebuild equality, release VERSION or native execution.
# Linux targets must be built on Linux (F5); no toolchain is installed here.
set -euo pipefail
ROOT="$(CDPATH='' cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -I - "$ROOT" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

ROOT = Path(sys.argv[1])
TARGETS = {'aarch64-apple-darwin', 'x86_64-unknown-linux-musl', 'aarch64-unknown-linux-musl'}
INSTALL = 'bin/native/{version}/{target}/{sha256}/trellis-hooks'
# The release version is core-rules/VERSION, never a second pin here. Every
# mode reads it strictly first (main block); the definitions read it leniently
# so fixtures that exec them against a partial tree still load.
VERSION_RE = r'[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'
RUSTC_VERSION = 'rustc 1.97.1 (8bab26f4f 2026-07-14)'
SYSTEM_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'
# Resolve the named checkout and literal commit objects, not caller redirections
# or local refs/replace substitutions (including during build provenance checks).
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
GIT_ENV['GIT_NO_REPLACE_OBJECTS'] = '1'
BUILD_SCOPE = ('native/trellis-hooks', 'scripts/build-native-hooks.sh',
               ':(exclude)native/trellis-hooks/tests/**', ':(exclude)native/trellis-hooks/target/**')


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, **kwargs).decode().strip()


def run_z(args):
    # Never strip path bytes: leading spaces are legal Git filenames.
    return list(filter(None, subprocess.check_output(args, stderr=subprocess.STDOUT, env=GIT_ENV).decode().split('\0')))


def closed(obj, keys):
    require(type(obj) is dict and set(obj) == set(keys.split()), 'unknown/missing manifest fields')


def digest(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'invalid sha256')


def release_version():
    # One version line, as release-payload-commit.sh requires of core-rules/VERSION.
    p = ROOT / 'core-rules/VERSION'
    require(not p.is_symlink() and p.is_file(), 'core-rules/VERSION is not a regular file')
    text = p.read_bytes().decode('ascii', errors='replace')
    require(re.fullmatch(VERSION_RE + '\n', text) is not None, 'core-rules/VERSION is not one version line')
    return text[:-1]


def lenient_release_version():
    # No module-level try statement: fixtures cut this text at its first one.
    try:
        return release_version()
    except (ValueError, OSError):
        return None


VERSION = lenient_release_version()


def read_manifest(base):
    def pairs(items):
        d = {}
        for k, v in items:
            require(k not in d, 'duplicate manifest key')
            d[k] = v
        return d
    require(not base.is_symlink() and base.is_dir(), 'asset root is not a directory')
    p = base / 'artifacts.json'
    require(not p.is_symlink() and p.is_file(), 'missing/linked manifest')
    d = json.loads(p.read_text(), object_pairs_hook=pairs)
    closed(d, 'schema_version version generation source_commit inputs toolchain adapter install_path assets')
    require(type(d['schema_version']) is int and d['schema_version'] == 1, 'unknown schema')
    require(d['version'] == VERSION and d['install_path'] == INSTALL, 'version/install layout mismatch')
    require(type(d['source_commit']) is str and re.fullmatch('[0-9a-f]{40}', d['source_commit']), 'invalid source commit')
    require(type(d['inputs']) is dict and bool(d['inputs']), 'missing source inputs')
    for name, value in d['inputs'].items():
        input_name(name)
        digest(value)
    closed(d['toolchain'], 'channel rustc cargo_lock_sha256 rust_toolchain_sha256')
    require(d['toolchain']['channel'] == '1.97.1' and
            d['toolchain']['rustc'] == RUSTC_VERSION, 'unpinned toolchain')
    for key in ('cargo_lock_sha256', 'rust_toolchain_sha256'):
        digest(d['toolchain'][key])
    require(d['inputs'].get('native/trellis-hooks/Cargo.lock') == d['toolchain']['cargo_lock_sha256'] and
            d['inputs'].get('native/trellis-hooks/rust-toolchain.toml') == d['toolchain']['rust_toolchain_sha256'], 'toolchain input mismatch')
    digest(d['generation'])
    identity = {k: d[k] for k in ('version', 'inputs', 'toolchain')}
    require(d['generation'] == sha(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()), 'generation mismatch')
    require(type(d['assets']) is dict and bool(d['assets']) and set(d['assets']) <= TARGETS, 'invalid target set')
    return d


def verify(base):
    d = read_manifest(base)
    expected = {'artifacts.json', 'hook-adapter.sh'}
    closed(d['adapter'], 'path size sha256')
    require(d['adapter']['path'] == 'hook-adapter.sh', 'adapter path mismatch')
    records = [(d['adapter'], None)]
    for target, a in d['assets'].items():
        closed(a, 'path size sha256 format signature minimum_os')
        require(a['path'] == target + '/trellis-hooks', 'asset path mismatch')
        darwin = target.endswith('apple-darwin')
        require(a['format'] == ('mach-o' if darwin else 'elf-static') and
                a['signature'] == ('adhoc' if darwin else 'none') and
                a['minimum_os'] == ('13.0' if darwin else None), 'target metadata mismatch')
        expected.add(target)
        expected.add(a['path'])
        records.append((a, target))
    actual = set()
    for p in base.rglob('*'):
        require(not p.is_symlink(), 'symlink in asset set')
        actual.add(p.relative_to(base).as_posix())
    require(actual == expected, 'missing/unlisted asset')
    for a, target in records:
        p = base / a['path']
        require(stat.S_ISREG(p.lstat().st_mode), 'asset is not regular')
        b = p.read_bytes()
        digest(a['sha256'])
        require(type(a['size']) is int and a['size'] > 0 and a['size'] == len(b) and
                a['sha256'] == sha(b), 'digest/size mismatch: ' + a['path'])
        if target:
            require(p.stat().st_mode & 0o111, 'asset is not executable')
            if target.endswith('apple-darwin'):
                require(b[:8] == b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01', 'wrong Mach-O target')
                if platform.system() == 'Darwin':
                    try:
                        run(['/usr/bin/codesign', '--verify', '--strict', str(p)])
                    except subprocess.CalledProcessError as e:
                        raise ValueError('signature verification failed: ' + e.output.decode()) from e
                else:
                    print('UNVERIFIED-on-Linux: Darwin signature (digest verified)', file=sys.stderr)
            else:
                require(b[:6] == b'\x7fELF\x02\x01' and
                        int.from_bytes(b[18:20], 'little') == (62 if target.startswith('x86_64') else 183), 'wrong ELF target')
                # Static musl may be static PIE, but must never have PT_INTERP.
                off = int.from_bytes(b[32:40], 'little')
                width = int.from_bytes(b[54:56], 'little')
                count = int.from_bytes(b[56:58], 'little')
                require(width == 56 and count > 0 and off + width * count <= len(b), 'invalid ELF program headers')
                require(all(int.from_bytes(b[off+i*width:off+i*width+4], 'little') != 3 for i in range(count)), 'dynamic ELF interpreter')
                if platform.system() != 'Linux':
                    print('UNVERIFIED-on-Darwin: Linux asset is structural only', file=sys.stderr)
            require(not any(x in b for x in (b'/Users/', b'/home/', b'/.cargo/', b'/.rustup/')), 'unremapped build path')
    print('native assets verified: ' + ', '.join(sorted(d['assets'])))
    return d


def populate_registry(cargo_home, private_cargo, lock_path):
    # Never trust pre-extracted registry/src or reuse an unchecked .crate.
    registry = private_cargo/'registry'
    registry.mkdir()
    index = cargo_home/'registry/index'
    if index.exists():
        (registry/'index').symlink_to(index, target_is_directory=True)
    lock = tomllib.loads(lock_path.read_text())
    for package in lock.get('package', []):
        if 'source' not in package:
            continue
        require(package['source'] == 'registry+https://github.com/rust-lang/crates.io-index', 'unapproved dependency source')
        name = package['name'] + '-' + package['version'] + '.crate'
        matches = list((cargo_home/'registry/cache').glob('*/' + name))
        require(len(matches) == 1, 'missing/ambiguous cached dependency: ' + name)
        data = matches[0].read_bytes()
        require(sha(data) == package['checksum'], 'cached dependency checksum mismatch: ' + name)
        destination = registry/'cache'/matches[0].parent.name/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)


def publish_file(source, destination):
    # Fresh inode + rename, including when replacing a source-tree output.
    # The manifest is published last. This is not T55's runtime transaction.
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.native-', delete=False) as f:
        temporary = Path(f.name)
        f.write(source.read_bytes())
    try:
        temporary.chmod(stat.S_IMODE(source.stat().st_mode))
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def input_name(name):
    # Self-contained verification checks path syntax, not the source graph.
    # --source below proves exact membership and committed bytes mechanically.
    require(type(name) is str and bool(name) and name != '.' and
            not Path(name).is_absolute() and '..' not in Path(name).parts and
            Path(name).as_posix() == name and '\\' not in name and
            not any(ord(c) < 32 or ord(c) == 127 for c in name), 'invalid input path')


def input_file(root, name):
    input_name(name)
    p = root
    for part in Path(name).parts:
        p = p/part
        require(not p.is_symlink(), 'symlinked build input: ' + name)
    require(p.is_file(), 'missing build input: ' + name)
    return p


def rust_string(body):
    # Rust escapes differ from JSON (notably unicode braces/line continuations).
    body = re.sub(r'\\\r?\n[ \t\r\n]*', '', body)
    out = []; i = 0
    simple = {'n': '\n', 'r': '\r', 't': '\t', '0': '\0', '\\': '\\', '"': '"', "'": "'"}
    while i < len(body):
        if body[i] != '\\':
            out.append(body[i]); i += 1; continue
        i += 1
        require(i < len(body), 'unterminated Rust string escape')
        c = body[i]; i += 1
        if c in simple:
            out.append(simple[c])
        elif c == 'x':
            h = body[i:i+2]
            require(re.fullmatch('[0-9a-fA-F]{2}', h) and int(h, 16) < 128, 'invalid Rust hex escape')
            out.append(chr(int(h, 16))); i += 2
        elif c == 'u':
            m = re.match(r'\{([0-9a-fA-F_]+)\}', body[i:])
            require(m is not None, 'invalid Rust unicode escape')
            out.append(chr(int(m[1].replace('_', ''), 16))); i += len(m[0])
        else:
            raise ValueError('unsupported Rust string escape')
    return ''.join(out)


def rust_tokens(text):
    # Lex, do not grep: comments, character literals and raw/normal string
    # contents can contain fake include invocations. Keep only real tokens.
    i = 0
    while i < len(text):
        c = text[i]
        if c.isspace(): i += 1; continue
        if text.startswith('//', i):
            end = text.find('\n', i); i = len(text) if end < 0 else end+1; continue
        if text.startswith('/*', i):
            depth = 1; i += 2
            while depth and i < len(text):
                if text.startswith('/*', i): depth += 1; i += 2
                elif text.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            require(depth == 0, 'unterminated Rust comment'); continue
        raw = re.match(r'((?:b|c)?r)(#{0,255})"', text[i:]) if c in 'rbc' else None
        if raw:
            start = i+len(raw[0]); end = text.find('"'+raw[2], start)
            require(end >= 0, 'unterminated Rust raw string')
            yield ('string' if raw[1] == 'r' else 'other_string', text[start:end])
            i = end+1+len(raw[2]); continue
        prefixed = c in 'bc' and text[i+1:i+2] == '"'
        if c == '"' or prefixed:
            start = i+1+int(prefixed); i = start
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            require(i < len(text), 'unterminated Rust string')
            yield ('other_string', text[start:i]) if prefixed else ('string', rust_string(text[start:i]))
            i += 1; continue
        if c == "'" and i+2 < len(text) and (text[i+1] == '\\' or text[i+2] == "'"):
            i += 1
            while i < len(text) and text[i] != "'": i += 2 if text[i] == '\\' else 1
            require(i < len(text), 'unterminated Rust character'); i += 1; continue
        ident = re.match(r'[A-Za-z_][A-Za-z_0-9]*', text[i:])
        if ident:
            yield ('ident', ident[0]); i += len(ident[0])
        else:
            yield (c, c); i += 1


def include_inputs(root):
    tracked = set(run_z(['git', '-C', str(root), 'ls-files', '-z']))
    # Include all tracked crate Rust sources, including test modules: discovery
    # itself reads them, and their include edges must not escape provenance.
    pending = sorted(p for p in tracked if p.startswith('native/trellis-hooks/') and
                     p.endswith('.rs') and not p.startswith('native/trellis-hooks/target/'))
    seeded = set(pending)
    inputs = seeded.copy(); pending = [(p, False) for p in pending]; visited = set()
    def target(source, literal):
        require(not Path(literal).is_absolute(), 'include outside checkout: ' + source)
        # Inspect original components BEFORE collapsing '..': normalizing a
        # symlink/../target first would hash a different file than rustc reads.
        p = root
        for part in (Path(source).parent/literal).parts:
            p = p.parent if part == '..' else p/part
            require(p.is_relative_to(root), 'include outside checkout: ' + source)
            require(not p.is_symlink(), 'symlinked build input: ' + source)
        name = p.relative_to(root).as_posix()
        input_file(root, name)
        require(name in tracked, 'untracked native build input: ' + name)
        inputs.add(name)
        return name
    while pending:
        source, external_context = pending.pop()
        if (source, external_context) in visited: continue
        visited.add((source, external_context))
        tokens = list(rust_tokens(input_file(root, source).read_text(encoding='utf-8')))
        braces = 0; attribute = 0
        for i, token in enumerate(tokens):
            kind, value = token
            # Plain mod children in external Rust are not covered by the crate
            # seed scan. Refuse, rather than publish an incomplete source map.
            require(not (external_context and token == ('ident', 'mod')),
                    'out-of-crate module declarations unsupported: ' + source)
            if kind == '{': braces += 1
            elif kind == '}': braces -= 1
            if token == ('#', '#') and tokens[i+1:i+2] == [('[', '[')]: attribute = 1
            elif attribute and kind == '[' and tokens[i-1] != ('#', '#'): attribute += 1
            elif attribute and kind == ']': attribute -= 1
            if attribute and token == ('ident', 'path') and tokens[i+1:i+2] == [('=', '=')]:
                require(braces == 0 and i+2 < len(tokens) and tokens[i+2][0] == 'string',
                        'unsupported nested/computed Rust module path: ' + source)
                name = target(source, tokens[i+2][1])
                pending.append((name, external_context or name not in seeded))
            if kind != 'ident' or value not in ('include_str', 'include_bytes', 'include'): continue
            require(tokens[i+1:i+2] != [('ident', 'as')], 'aliased include macros unsupported: ' + source)
            if tokens[i+1:i+2] != [('!', '!')]: continue
            args = tokens[i+2:i+7]
            require(len(args) >= 3 and args[0][0] in '([{' and args[1][0] == 'string',
                    'include must use a literal path: ' + source)
            close = {'(': ')', '[': ']', '{': '}'}[args[0][0]]
            end = 3 if args[2][0] == ',' else 2
            require(len(args) > end and args[end][0] == close, 'include must use a literal path: ' + source)
            name = target(source, args[1][1])
            if value == 'include': pending.append((name, external_context or name not in seeded))
    return inputs


def build_scopes(root):
    # Separate queries: Git's global exclude pathspecs must not mask a real
    # include target under tests/, or interpret a target's ':' as pathspec magic.
    extra = tuple(':(literal)' + p for p in sorted(include_inputs(root)))
    return (BUILD_SCOPE, extra) if extra else (BUILD_SCOPE,)


def build_inputs(root=ROOT):
    paths = set()
    for scope in build_scopes(root):
        paths.update(run_z(['git', '-C', str(root), 'ls-files', '-z', '--', *scope]))
        untracked = run_z(['git', '-C', str(root), 'ls-files', '--others', '-z', '--', *scope])
        require(not untracked, 'untracked native build input')
        # Git diff ignores skip-worktree and assume-unchanged, even if dirty.
        flags = run_z(['git', '-C', str(root), 'ls-files', '-v', '-z', '--', *scope])
        require(all(entry.startswith('H ') for entry in flags if entry), 'flagged native build input')
        # Full base scope (not surviving paths): staged deletions still count.
        require(subprocess.run(['git', '-C', str(root), 'diff', '--quiet', 'HEAD', '--', *scope], env=GIT_ENV).returncode == 0, 'dirty native build input')
    return {p: sha(input_file(root, p).read_bytes()) for p in sorted(paths)}


def build_source_commit(root=ROOT):
    commits = {run(['git', '-C', str(root), 'log', '-1', '--format=%H', '--', *scope], env=GIT_ENV)
               for scope in build_scopes(root)}
    return next(c for c in run(['git', '-C', str(root), 'rev-list', 'HEAD'], env=GIT_ENV).splitlines() if c in commits)


def verify_source(base, checkout):
    d = verify(base)
    checkout = checkout.resolve(strict=True)
    require(Path(run(['git', '-C', str(checkout), 'rev-parse', '--show-toplevel'], env=GIT_ENV)).resolve() == checkout,
            'source must be a checkout root')
    inputs = build_inputs(checkout)
    require(inputs == d['inputs'], 'source input set/digest mismatch')
    # Check committed bytes too: do not rely on Git's cached stat information.
    committed = {p: sha(subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:' + p], env=GIT_ENV))
                 for p in inputs}
    require(inputs == committed, 'source inputs differ from checkout HEAD')
    print('native source inputs verified: ' + run(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], env=GIT_ENV))


def build(target, base):
    require(target in TARGETS, 'not a ' + VERSION + ' native target: ' + target)
    darwin = target.endswith('apple-darwin')
    require(platform.system() == ('Darwin' if darwin else 'Linux'), 'build Linux targets on Linux and Darwin on Mac (F5)')
    require(not base.is_symlink(), 'symlinked build output')
    if base.exists():
        require(base.is_dir(), 'build output is not a directory')
        require((base/'artifacts.json').exists() or not any(base.iterdir()), 'nonempty build output without manifest')
    crate = ROOT / 'native/trellis-hooks'
    channel = '1.97.1'
    before = build_inputs()
    env = {k: os.environ[k] for k in ('HOME', 'TMPDIR', 'RUSTUP_HOME') if k in os.environ}
    env['PATH'] = SYSTEM_PATH
    env['RUSTUP_AUTO_INSTALL'] = '0'
    # Preserve the caller's bounded budget in the otherwise hermetic child.
    env['CARGO_BUILD_JOBS'] = os.environ.get('CARGO_BUILD_JOBS', '2')
    cargo_home = Path(os.environ.get('CARGO_HOME', str(Path.home()/'.cargo'))).resolve()
    rustup_home = Path(env.get('RUSTUP_HOME', str(Path.home()/'.rustup'))).resolve()
    arch = {'arm64': 'aarch64', 'amd64': 'x86_64'}.get(platform.machine(), platform.machine())
    hosts = [arch + '-apple-darwin'] if darwin else [arch + '-unknown-linux-gnu', arch + '-unknown-linux-musl']
    toolchains = [rustup_home/'toolchains'/(channel+'-'+host) for host in hosts]
    toolchain = next((p for p in toolchains if (p/'bin/rustc').is_file() and (p/'bin/cargo').is_file()), None)
    require(toolchain is not None, 'pinned native toolchain is not installed')
    rustc_path = str(toolchain/'bin/rustc')
    cargo_path = str(toolchain/'bin/cargo')
    env['RUSTC'] = rustc_path
    rustc = run([rustc_path, '-vV'], env=env).splitlines()[0]
    require(rustc == RUSTC_VERSION, 'wrong rustc version')
    # Asset-only commits must not split a multi-host build generation.
    # Commit provenance is informative; the actual input bytes define identity.
    source_commit = build_source_commit()
    identity = dict(version=VERSION, inputs=before,
                    toolchain=dict(channel=channel, rustc=rustc,
                                   cargo_lock_sha256=before['native/trellis-hooks/Cargo.lock'],
                                   rust_toolchain_sha256=before['native/trellis-hooks/rust-toolchain.toml']))
    generation = sha(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode())
    assets = {}
    if (base/'artifacts.json').exists():
        previous = verify(base)
        require(previous['generation'] == generation, 'different source generation: build into a fresh directory')
        assets = previous['assets']
    # No ambient flags/wrappers/config may alter a release build outside its receipt.
    remaps = [(ROOT, '/trellis/workspace'), (cargo_home, '/trellis/cargo'), (rustup_home, '/trellis/rustup')]
    flags = ['--remap-path-prefix=' + str(p) + '=' + replacement for p, replacement in remaps]
    if darwin:
        # Strip debug paths before ld computes LC_UUID. Post-link stripping alone
        # leaves a UUID dependent on the temporary object-path lengths.
        flags.extend(['-C', 'link-arg=-Wl,-S'])
    with tempfile.TemporaryDirectory(prefix='native-hooks.', dir=os.environ.get('TMPDIR')) as tmp:
        tmp = Path(tmp)
        flags.append('--remap-path-prefix=' + str(tmp) + '=/trellis/build')
        # Cargo discovers config from cwd ancestors, not --manifest-path.
        # A fresh cwd/home permits cached crates, but no caller Cargo config.
        for parent in (tmp, *tmp.parents):
            require(not any((parent/'.cargo'/name).exists() for name in ('config', 'config.toml')), 'ambient ancestor Cargo config')
        private_cargo = tmp/'cargo'
        private_cargo.mkdir()
        populate_registry(cargo_home, private_cargo, crate/'Cargo.lock')
        env['CARGO_HOME'] = str(private_cargo)
        env['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join(flags)
        env['CARGO_TARGET_DIR'] = str(tmp/'target')
        if darwin:
            env['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
        subprocess.run([cargo_path, 'build', '--manifest-path', str(crate/'Cargo.toml'),
                        '--release', '--locked', '--offline', '--target', target, '--no-default-features'], env=env, cwd=tmp, check=True)
        final = tmp/'trellis-hooks'
        shutil.copyfile(tmp/'target'/target/'release/trellis-hooks', final)
        final.chmod(0o755)
        # Cargo's pinned release profile strips on all platforms. Darwin strip
        # runs before signing; nothing modifies the executable after codesign.
        if darwin:
            run(['/usr/bin/strip', '-x', str(final)])
            run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(final)])
            run(['/usr/bin/codesign', '--verify', '--strict', str(final)])
        require(before == build_inputs(), 'build inputs changed during compilation')
        b = final.read_bytes()
        assets[target] = dict(path=target+'/trellis-hooks', size=len(b), sha256=sha(b),
                              format='mach-o' if darwin else 'elf-static', signature='adhoc' if darwin else 'none',
                              minimum_os='13.0' if darwin else None)
        body = '\n'.join(line for line in (crate/'proto/hook-adapter.sh').read_text().splitlines() if not line.lstrip().startswith('#'))
        require('if [ -f "$1" ]' in body, 'adapter source changed')
        body = body.replace('if [ -f "$1" ]', 'if [ "${1#*=}" = "$1" ] && [ -f "$1" ]')
        adapter = ('# shellcheck shell=sh\n# Sealed native guard adapter; inline registration program (I-A3).\n' + body + '\n').encode()
        manifest = dict(schema_version=1, generation=generation, source_commit=source_commit,
                        **identity, install_path=INSTALL, assets=assets,
                        adapter=dict(path='hook-adapter.sh', size=len(adapter), sha256=sha(adapter)))
        # Validate the complete candidate before publishing any output.
        stage = tmp/'assets'
        if base.exists():
            shutil.copytree(base, stage)
        else:
            stage.mkdir()
        (stage/target).mkdir(exist_ok=True)
        shutil.copyfile(final, stage/target/'trellis-hooks')
        (stage/target/'trellis-hooks').chmod(0o755)
        (stage/'hook-adapter.sh').write_bytes(adapter)
        (stage/'artifacts.json').write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
        verify(stage)
        base.mkdir(parents=True, exist_ok=True)
        (base/target).mkdir(exist_ok=True)
        # These are source-tree release outputs, NOT the installed executable
        # entries. T55 owns private fresh-inode installation and publication.
        publish_file(stage/target/'trellis-hooks', base/target/'trellis-hooks')
        publish_file(stage/'hook-adapter.sh', base/'hook-adapter.sh')
        publish_file(stage/'artifacts.json', base/'artifacts.json')
    verify(base)


try:
    args = sys.argv[2:]
    VERSION = release_version()
    usage = 'usage: build-native-hooks.sh build <target> [asset-dir] | verify [--source <checkout>] [asset-dir]'
    require(bool(args), usage)
    if args[0] == 'verify' and len(args) in (3, 4) and args[1] == '--source':
        verify_source(Path(args[3]) if len(args) == 4 else ROOT/'core-rules/native', Path(args[2]))
    elif args[0] == 'verify' and len(args) in (1, 2):
        verify(Path(args[1]) if len(args) == 2 else ROOT/'core-rules/native')
    elif args[0] == 'build' and len(args) in (2, 3):
        build(args[1], Path(args[2]) if len(args) == 3 else ROOT/'core-rules/native')
    else:
        raise ValueError(usage)
except (ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError) as e:
    print('native-hooks: refused: ' + str(e), file=sys.stderr)
    sys.exit(1)
PY
