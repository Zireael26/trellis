"""Conservative donor reuse. Exit 10 is a read-only miss, never a partial attach.

Called with the existing checkout, attachment and registry locks held. Artifact
publication is batched here; schema, registry and hook checks remain in the
existing attachment machinery. Journals retain the v1 recovery contract.
"""
import base64
import copy
from contextlib import ExitStack, contextmanager
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

# Resolve the shared verifier by absolute sibling path, never project sys.path.
# Import lazily so a broken sibling is a read-only fast miss, not an uncaught
# Python startup failure. The Bash gate checks both paths first as well.
integrity = None


def load_integrity():
    global integrity
    if integrity is None:
        spec = importlib.util.spec_from_file_location('release_executed', Path(__file__).with_name('release-executed.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        integrity = module
    return integrity


def directory(path):
    return load_integrity().directory(path)


def read_regular(*args, **kwargs):
    return load_integrity().read_regular(*args, **kwargs)


def relative(path):
    return load_integrity().relative(path)


def project_file_present(path):
    # The authoritative planner accepts regular project files, not symlinks.
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return False


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


class RenderMiss(ValueError):
    """A donor whose explicit-json render the canonical renderer does not
    reproduce for the donor's own root. Always labelled on stderr; still a
    read-only miss (10) that runs the full attach, never a fast-path success."""


MARKERS = ('__TRELLIS_USER_HOME__', '__TRELLIS_HOME__', '__TRELLIS_LAUNCHER__')


def native_shaped(template):
    """The canonical renderer's own routing test (attachment.sh
    attachment_contextual_template_render_impl): such a template goes to the
    candidate renderer, whose output names the project root and this host's
    companion, so it is reproduced by that renderer, never by substitution."""
    strings = []
    def walk(value):
        if isinstance(value, dict):
            if value.get('command') == MARKERS[2]:
                return True
            args = value.get('args')
            if isinstance(args, list) and any(isinstance(a, str) and '__TRELLIS_' in a for a in args):
                return True
            return any(walk(v) for v in value.values())
        if isinstance(value, list):
            return any(walk(v) for v in value)
        if isinstance(value, str):
            strings.append(value)
        return False
    if walk(template):
        return True
    hooks = template.get('hooks') if isinstance(template, dict) else None
    return (any('__TRELLIS_' in v for v in strings) and isinstance(hooks, dict)
            and ('WorktreeCreate' in hooks or 'WorktreeRemove' in hooks))


COMPANION = re.compile(r'/bin/native/([^/]+)/([^/]+)/([0-9a-f]{64})/trellis-hooks')


def companions(value):
    found = set()
    def walk(item):
        if isinstance(item, str):
            found.update(COMPANION.findall(item))
        elif isinstance(item, list):
            for child in item:
                walk(child)
        elif isinstance(item, dict):
            for child in item.values():
                walk(child)
    walk(value)
    return found


def render_miss_label(actual, wanted):
    have, want = companions(actual), companions(wanted)
    if have == want:
        return 'donor render differs from its own root render'
    if not have:
        return 'legacy donor render; this host renders native'
    if not want:
        return 'native donor render; this host renders legacy'
    if {t for _, t, _ in have} != {t for _, t, _ in want}:
        return 'donor render is for another host target'
    return 'donor render names another companion'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(data):
    return base64.b64encode(data).decode('ascii')


def identity(s):
    return '%d:%d' % (s.st_dev, s.st_ino)


def git(root, *args, data=None, allowed=(0,)):
    result = subprocess.run(['/usr/bin/git', '-C', root, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode in allowed, 'Git preflight failed')
    return result.stdout


def live_identity(root, common):
    with directory(root):
        pass
    top = git(root, 'rev-parse', '--show-toplevel').decode().rstrip('\n')
    actual = git(root, 'rev-parse', '--git-common-dir').decode().rstrip('\n')
    if not os.path.isabs(actual):
        actual = os.path.join(root, actual)
    require(os.path.realpath(top) == root and os.path.realpath(actual) == common, 'checkout identity differs')


def artifact_exact(root, artifact):
    path = relative(artifact['path'])
    parent, name = os.path.split(root + '/' + path)
    with directory(parent) as fd:
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        kind = artifact['kind']
        if kind == 'symlink':
            require(stat.S_ISLNK(info.st_mode) and os.readlink(name, dir_fd=fd) == artifact['target'], 'donor symlink drift')
            return None
        if kind in ('directory', 'parent'):
            require(stat.S_ISDIR(info.st_mode), 'donor directory drift')
            if kind == 'directory':
                with directory(root + '/' + path) as child:
                    require(not os.listdir(child), 'donor empty directory drift')
            return None
        require(kind == 'file', 'unknown artifact kind')
    data = read_regular(root + '/' + path, mode=int(artifact['mode'], 8) if 'mode' in artifact else None)
    require(sha(data) == artifact['sha256'], 'donor file drift')
    return data


def current_inventory(donor, payload, harnesses, native=None):
    """Reject historical/adopted inventories that need the current full planner.

    Recognize the shipped nonrecursive link/render shapes only. Unknown shapes
    are misses, not a second permissive implementation of the general planner.
    A native-shaped explicit-json template is appended to `native` for the
    canonical renderer (canonical_renders); without that list it is a miss.
    """
    manifest_path = 'core-rules/inheritance-manifest.json'
    manifest = json.loads(read_regular(payload + '/' + manifest_path, sealed=True))
    require(manifest.get('schema_version') in (1, 2), 'unknown inheritance schema')
    selected = list(harnesses)
    if manifest['schema_version'] == 2 and any(h in harnesses for h in ('codex', 'pi')):
        selected.append('shared_agents')
    expected = {'.trellis/runtime': ('symlink', payload)}
    sources = [manifest_path]
    for harness in selected:
        section = manifest['harnesses'][harness]
        require(set(section) <= {'links', 'render'}, 'unknown surface shape')
        for entry in section.get('links', []):
            require(not entry.get('destination_home'), 'HOME surface in project plan')
            links = []
            if 'source_children' in entry:
                require(not entry.get('recursive'), 'complex expansion needs full planner')
                base = relative(entry['source_children'])
                with directory(payload + '/' + base) as fd:
                    for name in sorted(os.listdir(fd)):
                        if name in entry.get('exclude_dirs', []):
                            continue
                        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        if entry['entry_type'] == 'directory' and stat.S_ISDIR(info.st_mode):
                            if entry.get('required_file'):
                                read_regular(payload + '/' + base + '/' + name + '/' + relative(entry['required_file']))
                            links.append((base + '/' + name, relative(entry['destination_dir']) + '/' + name))
                        elif entry['entry_type'] == 'file' and name.endswith(entry.get('suffix', '')):
                            require(stat.S_ISREG(info.st_mode), 'nonregular source child')
                            links.append((base + '/' + name, relative(entry['destination_dir']) + '/' + name))
            elif 'project_target' in entry:
                destination = relative(entry['destination'])
                source = relative(entry['project_target'])
                target = '../' * destination.count('/') + source
                if not project_file_present(donor['worktree_root'] + '/' + source):
                    target = '../' * destination.count('/') + '.trellis/runtime/' + relative(entry['fallback_source'])
                require(destination not in expected, 'duplicate surface destination')
                expected[destination] = ('symlink', target)
                continue
            else:
                links.append((relative(entry['source']), relative(entry['destination'])))
            for source, destination in links:
                require(destination not in expected, 'duplicate surface destination')
                expected[destination] = ('symlink', '../' * destination.count('/') + '.trellis/runtime/' + source)
        for entry in section.get('render', []):
            template, destination = relative(entry['template']), relative(entry['destination'])
            if not os.path.lexists(payload + '/' + template) and not entry.get('required', False):
                continue
            data = read_regular(payload + '/' + template, sealed=True)
            sources.append(template)
            require(destination not in expected, 'duplicate render destination')
            if entry['merge'] == 'replace':
                expected[destination] = ('file', sha(data), entry['mode'])
            else:
                require(entry['merge'] == 'explicit-json', 'unknown render merge')
                value = json.loads(data)
                if native_shaped(value):
                    require(native is not None, 'native render needs the canonical renderer')
                    native.append({'template': template, 'destination': destination, 'mode': entry['mode'], 'merge': 'explicit-json'})
                    expected[destination] = ('native', None, entry['mode'])
                    continue
                context = donor.get('render_context') or {}
                replacements = {'__TRELLIS_USER_HOME__': context.get('user_home_shell'), '__TRELLIS_HOME__': context.get('trellis_home_shell'), '__TRELLIS_LAUNCHER__': context.get('launcher_shell')}
                def substitute(value):
                    if isinstance(value, str):
                        for token, replacement in replacements.items():
                            if token in value:
                                require(replacement is not None, 'missing render context')
                                value = value.replace(token, replacement)
                        return value
                    if isinstance(value, list):
                        return [substitute(item) for item in value]
                    if isinstance(value, dict):
                        return {key: substitute(item) for key, item in value.items()}
                    return value
                expected[destination] = ('json', substitute(value), entry['mode'])
    actual = {a['path']: a for a in donor['artifacts'] if a['kind'] != 'parent'}
    require(len(actual) == sum(a['kind'] != 'parent' for a in donor['artifacts']), 'duplicate donor leaves')
    require(set(actual) == set(expected), 'historical or incomplete donor inventory')
    for path, wanted in expected.items():
        artifact = actual[path]
        require(artifact['kind'] == ('file' if wanted[0] in ('json', 'native') else wanted[0]), 'surface kind differs')
        if wanted[0] == 'symlink':
            require(artifact['target'] == wanted[1], 'surface target differs')
        elif wanted[0] == 'file':
            require(artifact['sha256'] == wanted[1] and artifact.get('mode') == wanted[2], 'render template differs')
        elif wanted[0] == 'native':
            require(artifact.get('mode') == wanted[2], 'guard template differs')  # content: canonical_renders
        else:
            data = artifact_exact(donor['worktree_root'], artifact)
            require(json.loads(data) == wanted[1] and artifact.get('mode') == wanted[2], 'guard template differs')
    return sources


def render_inputs(payload):
    """Payload files the canonical renderer reads besides the template: the
    native manifest and adapter, and the pinned legacy provider it selects on
    a native miss. Each present one joins the executed-release verification."""
    names = []
    for name in ('core-rules/native/artifacts.json', 'core-rules/native/hook-adapter.sh'):
        if os.path.lexists(payload + '/' + name):
            names.append(name)
    provider = 'core-rules/legacy-hooks'
    if os.path.lexists(payload + '/' + provider + '/manifest.json'):
        listed = json.loads(read_regular(payload + '/' + provider + '/manifest.json', sealed=True))['files']
        names.append(provider + '/manifest.json')
        names.extend(provider + '/' + relative(name) for name in sorted(listed))
    return names


# One Bash process renders every native-shaped template twice through the
# canonical attach functions: for the donor's own root (to verify the donor)
# and, as attach_json_render_plan, for the target root (the plan's artifact
# and render record). One Claude version probe serves the whole batch; the
# full attach probes per render, a few milliseconds apart.
RENDER = r'''
. "$1" || exit 1
payload="$2"; context="$3"; donor_root="$4"; target_root="$5"
shift 5 || exit 1
if attachment_claude_on_failure_supported; then fast_direct=0; else fast_direct=1; fi
attachment_claude_on_failure_supported() { return "$fast_direct"; }
for record in "$@"; do
  template="$(printf '%s\n' "$record" | jq -r .template)" || exit 1
  donor="$(attach_contextual_template_render "$payload/$template" "$template" "$context" "$donor_root")" || exit 1
  target="$(attach_json_render_plan "$target_root" "$payload" "$record" "$context")" || exit 1
  jq -cn --argjson donor "$donor" --argjson target "$target" '{donor:$donor,target:$target}' || exit 1
done
'''


def canonical_renders(payload, donor, root, entries):
    """T34 option B: verify each native donor render against the canonical
    render for the donor's own root, then take the target's artifact and
    render record from the canonical plan for the target root."""
    result = subprocess.run(['/bin/bash', '-c', RENDER, 'fast-render', str(Path(__file__).parent.parent / 'attach-project.sh'),
                             payload, json.dumps(donor.get('render_context')), donor['worktree_root'], root,
                             *[json.dumps(e, sort_keys=True) for e in entries]],
                            env=dict(os.environ, TRELLIS_LIBS_PRELOADED='0'), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise RenderMiss('canonical render refused: ' + result.stderr.decode(errors='replace').strip()[-400:])
    lines = result.stdout.decode().splitlines()
    require(len(lines) == len(entries), 'canonical render output differs')
    artifacts = {a['path']: a for a in donor['artifacts']}
    renders = [r for r in donor.get('renders', [])]
    out = {}
    for entry, line in zip(entries, lines):
        doc = json.loads(line)
        path = entry['destination']
        actual = json.loads(artifact_exact(donor['worktree_root'], artifacts[path]))
        if actual != doc['donor']:
            raise RenderMiss(render_miss_label(actual, doc['donor']))
        artifact, render = doc['target']['artifact'], doc['target']['render']
        require(artifact.get('path') == path and artifact.get('kind') == 'file' and artifact.get('mode') == entry['mode']
                and 'replace' not in artifact and render.get('before_exists') is False, 'canonical target plan differs')
        recorded = [r for r in renders if r.get('path') == path]
        require(len(recorded) == 1, 'donor render record missing')
        # owned_keys carry the rendered values, so they name each root: the
        # donor's must be its own canonical render's values at the target's
        # owned paths. Every other render field is root-independent.
        strip = lambda r: {k: v for k, v in r.items() if k not in ('after_sha256', 'after_base64', 'owned_keys')}
        have, want = strip(recorded[0]), strip(render)
        fields = sorted(k for k in set(have) | set(want) if have.get(k) != want.get(k))
        def at(value, keys):
            for key in keys:
                value = value[key]
            return value
        try:
            owned = [{'path': k['path'], 'value': at(doc['donor'], k['path'])} for k in render['owned_keys']]
        except (KeyError, IndexError, TypeError):
            owned = None
        if recorded[0].get('owned_keys') != owned:
            fields.append('owned_keys')
        if recorded[0].get('after_sha256') != artifacts[path].get('sha256'):
            fields.append('after_sha256')
        if fields:
            raise RenderMiss('donor render record differs from the canonical plan: ' + ','.join(fields))
        out[path] = (artifact, render)
    return out


def caller_toolchain():
    raw = os.environ.get('TRELLIS_ATTACH_CALLER_PATH', os.environ.get('PATH', ''))
    paths = []
    for entry in raw.split(':'):
        require(entry.startswith('/') and not any(ord(c) < 32 for c in entry), 'unsafe caller PATH')
        if not os.path.isdir(entry):
            require(not os.path.exists(entry), 'caller PATH nondirectory')
            continue
        actual = os.path.realpath(entry)
        with directory(actual):
            pass
        paths.append(actual)
    require(paths, 'empty caller toolchain')
    anchor = os.environ.get('TRELLIS_HOMEBREW_BIN', '/opt/homebrew/bin')
    if os.path.isdir(anchor) and os.path.realpath(anchor) == anchor:
        nvm = next((i for i, p in enumerate(paths) if '/.nvm/' in p or p.endswith('/.nvm')), None)
        if nvm is not None:
            at = paths.index(anchor) if anchor in paths else None
            if at is None:
                paths.insert(0, anchor)
            elif at > nvm:
                paths.pop(at)
                paths.insert(nvm, anchor)
    return paths


def native_directory_publish(fd, stage, name):
    """Exclusive rename, including against a concurrently created empty dir."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        function, flag = libc.renameatx_np, 4  # RENAME_EXCL
    elif sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        function, flag = libc.renameat2, 1  # RENAME_NOREPLACE
    else:
        raise ValueError('exclusive directory rename unavailable')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(fd, os.fsencode(stage), fd, os.fsencode(name), flag):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def json_bytes(value):
    # Same compact sorted serialization as _attachment_write_json / jq -cS.
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode()


def write_json(path, value, exclusive=False, on_publish=None):
    parent, name = os.path.split(path)
    with directory(parent) as fd:
        write_json_at(fd, name, value, exclusive, on_publish)


def write_json_at(fd, name, value, exclusive=False, on_publish=None):
    stage = '.' + name + '.fast-' + uuid.uuid4().hex
    out = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        with os.fdopen(out, 'wb') as stream:
            stream.write(json_bytes(value))
        if exclusive:
            try:
                os.link(stage, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            except OSError as error:
                if not link_unsupported(error):
                    raise
                exclusive_rename_at(fd, stage, name)
        else:
            os.replace(stage, name, src_dir_fd=fd, dst_dir_fd=fd)
        if on_publish is not None:
            on_publish()
    finally:
        try:
            os.unlink(stage, dir_fd=fd)
        except FileNotFoundError:
            pass  # replace consumed the staging name


# T39: HFS+ cannot hard-link a symlink (ENOTSUP). Only for that, publish by an
# exclusive rename that keeps the staged inode: never over an existing name.
RENAME_EXCL_DARWIN = 0x4
RENAME_NOREPLACE_LINUX = 1
AT_FDCWD_LINUX = -100


def link_unsupported(error):
    return error.errno in (errno.ENOTSUP, getattr(errno, 'EOPNOTSUPP', errno.ENOTSUP))


def exclusive_rename_at(fd, source, destination):
    '''renameatx_np(RENAME_EXCL) or renameat2(RENAME_NOREPLACE); raise OSError.'''
    libc = ctypes.CDLL(None, use_errno=True)
    src, dst = os.fsencode(source), os.fsencode(destination)
    if sys.platform == 'darwin':
        call = libc.renameatx_np
        call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = call(fd, src, fd, dst, RENAME_EXCL_DARWIN)
    else:
        call = libc.renameat2
        call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = call(fd, src, fd, dst, RENAME_NOREPLACE_LINUX)
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), source)


class LostTransactionLock(Exception):
    """The original acquired lock scope can no longer be proved."""


def lock_require(condition, reason):
    if not condition:
        raise LostTransactionLock(reason)


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def require_private_lock_fds(expected):
    """Keep the three fixed lock fds and close all unrelated inherited fds."""
    lock_require(tuple(expected) == (31, 32, 33), 'invalid lock fd set')
    for fd in expected:
        try:
            os.fstat(fd)
        except OSError as error:
            raise LostTransactionLock('missing lock fd') from error
    for path in ('/proc/self/fd', '/dev/fd'):
        try:
            names = os.listdir(path)
            break
        except OSError:
            continue
    else:
        raise LostTransactionLock('cannot enumerate inherited descriptors')
    highest = max([33] + [int(name) for name in names if name.isdigit()])
    os.closerange(3, 31)
    os.closerange(34, highest + 1)
    for fd in expected:
        try:
            os.fstat(fd)
        except OSError as error:
            raise LostTransactionLock('lock fd closed during sanitization') from error


def read_lock_token(fd):
    info = os.fstat(fd)
    lock_require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and
                 info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 16384,
                 'unsafe lock owner token')
    os.lseek(fd, 0, os.SEEK_SET)
    chunks = []
    while True:
        part = os.read(fd, 16385)
        if not part:
            break
        chunks.append(part)
        lock_require(sum(map(len, chunks)) <= 16384, 'oversized lock owner token')
    return b''.join(chunks)


class TransactionLocks:
    def __init__(self, entries, parents):
        self.entries = entries
        self.parents = parents

    def recheck(self):
        # The holder's parent fd alone is not enough: its old directory could
        # have been moved away while a new lock namespace takes its place.
        for path, held_parent, original in self.parents:
            try:
                with directory(path) as named_parent:
                    lock_require(integrity._anchor(os.fstat(held_parent)) == integrity._anchor(original) ==
                                 integrity._anchor(os.fstat(named_parent)), 'lock namespace changed')
            except LostTransactionLock:
                raise
            except (OSError, ValueError) as error:
                raise LostTransactionLock('lock namespace could not be rechecked') from error
        for entry in self.entries:
            try:
                held = os.fstat(entry['fd'])
                named = os.stat(entry['holder'], dir_fd=entry['parent'], follow_symlinks=False)
                lock_require(integrity._fingerprint(held) == integrity._fingerprint(entry['holder_info']) ==
                             integrity._fingerprint(named), 'lock holder changed')
                token_info = os.fstat(entry['token_fd'])
                token_name = os.stat(entry['token_name'], dir_fd=entry['fd'], follow_symlinks=False)
                lock_require(integrity._fingerprint(token_info) == integrity._fingerprint(entry['token_info']) ==
                             integrity._fingerprint(token_name) and read_lock_token(entry['token_fd']) == entry['token'],
                             'lock owner token changed')
                if entry['alias']:
                    alias = os.stat(entry['alias'], dir_fd=entry['parent'], follow_symlinks=False)
                    lock_require(integrity._fingerprint(alias) == integrity._fingerprint(entry['alias_info']) and
                                 os.readlink(entry['alias'], dir_fd=entry['parent']) == entry['holder'],
                                 'lock alias changed')
                os.kill(entry['pid'], 0)
            except LostTransactionLock:
                raise
            except (OSError, ValueError) as error:
                raise LostTransactionLock('lock scope could not be rechecked') from error

    def proof_infos(self):
        infos = []
        for entry in self.entries:
            infos.extend((entry['holder_info'], entry['token_info']))
            if entry['alias_info'] is not None:
                infos.append(entry['alias_info'])
        return infos


@contextmanager
def transaction_lock_scope(home, binding, attachment_id, checkout_pid, attachment_pid, registry_pid, fds=(31, 32, 33)):
    """Pin the exact acquired holders, public aliases and owner tokens."""
    operation_failed = False
    try:
        load_integrity()
        checkout = binding['checkout_id']
        worktree = binding['worktree_id']
        common = binding['git_common_dir']
        checkout_pid, attachment_pid, registry_pid = map(int, (checkout_pid, attachment_pid, registry_pid))
        lock_require(len(fds) == 3 and len(set(fds)) == 3 and
                     all(pid > 0 for pid in (checkout_pid, attachment_pid, registry_pid)), 'invalid lock scope')
        with ExitStack() as stack:
            state_parent = stack.enter_context(directory(home + '/state/locks'))
            registry_parent = stack.enter_context(directory(home + '/locks'))
            specs = [
                (fds[0], state_parent, 'attachment-checkout-' + checkout + '.lock',
                 '.attachment-checkout-' + checkout + '.holder-', 'owner.json', checkout_pid,
                 {'checkout_id': checkout, 'git_common_dir': common}),
                (fds[1], state_parent, 'attachment-' + checkout + '-' + worktree + '.lock',
                 '.attachment-' + checkout + '-' + worktree + '.holder-', 'owner.json', attachment_pid,
                 {'checkout_id': checkout, 'worktree_id': worktree, 'attachment_id': attachment_id}),
                (fds[2], registry_parent, None, 'registry.lock', 'pid', registry_pid, None),
            ]
            entries = []
            for fd, parent, alias, prefix, token_name, pid, expected in specs:
                alias_info = None
                if alias:
                    alias_info = os.stat(alias, dir_fd=parent, follow_symlinks=False)
                    lock_require(stat.S_ISLNK(alias_info.st_mode) and alias_info.st_uid == os.geteuid(),
                                 'unsafe lock alias')
                    holder = os.readlink(alias, dir_fd=parent)
                    lock_require('/' not in holder and holder.startswith(prefix) and holder not in ('.', '..'),
                                 'invalid lock holder target')
                else:
                    holder = prefix
                holder_info = os.fstat(fd)
                named = os.stat(holder, dir_fd=parent, follow_symlinks=False)
                lock_require(stat.S_ISDIR(holder_info.st_mode) and holder_info.st_uid == os.geteuid() and
                             stat.S_IMODE(holder_info.st_mode) == 0o700 and
                             integrity._fingerprint(holder_info) == integrity._fingerprint(named),
                             'lock fd does not match named holder')
                token_fd = os.open(token_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                stack.callback(os.close, token_fd)
                token_info = os.fstat(token_fd)
                token = read_lock_token(token_fd)
                token_named = os.stat(token_name, dir_fd=fd, follow_symlinks=False)
                lock_require(integrity._fingerprint(token_info) == integrity._fingerprint(token_named),
                             'lock token name changed')
                if expected is None:
                    lock_require(token == (str(pid) + '\n').encode(), 'registry lock owner differs')
                else:
                    data = json.loads(token.decode('utf-8'), object_pairs_hook=unique_json_object)
                    lock_require(isinstance(data, dict) and set(data) == set(expected) | {'pid', 'process_birth'} and
                                 type(data.get('pid')) is int and data['pid'] == pid and
                                 isinstance(data.get('process_birth'), str) and data['process_birth'] and
                                 all(data.get(key) == value for key, value in expected.items()),
                                 'attachment lock owner differs')
                entries.append({'fd': fd, 'parent': parent, 'alias': alias, 'alias_info': alias_info,
                                'holder': holder, 'holder_info': holder_info, 'token_fd': token_fd,
                                'token_name': token_name, 'token_info': token_info, 'token': token, 'pid': pid})
            parents = [(home + '/state/locks', state_parent, os.fstat(state_parent)),
                       (home + '/locks', registry_parent, os.fstat(registry_parent))]
            scope = TransactionLocks(entries, parents)
            scope.recheck()
            try:
                yield scope
            except BaseException:
                operation_failed = True
                raise
            finally:
                scope.recheck()
    except LostTransactionLock:
        raise
    except (OSError, ValueError, KeyError, TypeError) as error:
        if operation_failed:
            raise
        raise LostTransactionLock('cannot bind transaction locks') from error


def canonical_json(data):
    value = json.loads(data.decode('utf-8'), object_pairs_hook=unique_json_object)
    return json.dumps(value, sort_keys=True, ensure_ascii=True, allow_nan=False, separators=(',', ':'))


def same_registry_snapshot(raw, diagnostic):
    """Conservative typed equality with the canonical diagnostic snapshot.

    Unknown/duplicate JSON shapes, non-finite numbers and different numeric
    encodings miss; this is an eligibility check, not schema validation.
    """
    try:
        return canonical_json(raw) == canonical_json(diagnostic)
    except (ValueError, TypeError, UnicodeError):
        return False


def registry_digest(data):
    # The locked writer re-serializes (jq -S), so bind the JSON value.
    return sha(canonical_json(data).encode('ascii'))


def require_fine_ctime(device, infos, ticks):
    """A reuse miss unless every pinned input is on the probed fine-ctime device."""
    require(len(infos) >= 2 and len(ticks) == 3, 'missing ctime proof inputs')
    require(all(info.st_dev == device and info.st_ctime_ns % 1000000 for info in infos),
            'foreign device or coarse input ctime')
    require(len(set(ticks)) == 3 and all(value % 1000000 for value in ticks),
            'ctime does not move finely')


def prove_fine_ctime(scratch_fd, inputs):
    """Probe two metadata changes on the same device as the held inputs."""
    name = '.registry-ctime-' + uuid.uuid4().hex
    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=scratch_fd)
    try:
        probe = os.fstat(fd)
        ticks = [probe.st_ctime_ns]
        for mode in (0o400, 0o600):
            os.fchmod(fd, mode)
            ticks.append(os.fstat(fd).st_ctime_ns)
        probe = os.fstat(fd)
        require_fine_ctime(probe.st_dev, list(inputs) + [probe], ticks)
    finally:
        held = os.fstat(fd)
        try:
            named = os.stat(name, dir_fd=scratch_fd, follow_symlinks=False)
            if stat.S_ISREG(named.st_mode) and integrity._fingerprint(named) == integrity._fingerprint(held):
                os.unlink(name, dir_fd=scratch_fd)
        except FileNotFoundError:
            pass
        os.close(fd)


@contextmanager
def private_capture(scratch_fd, parent_fd, name, snapshot_name, mode=None, check=None):
    """Copy one held input into the private workspace for the canonical child.

    Keep original and capture descriptors live through the child; a
    name/inode/content change of either is a read-only miss, never permission
    to publish a journal. Yields the bytes and both identities for the
    caller's fine-ctime proof.
    """
    with integrity._bound_file(parent_fd, name, mode=mode) as live:
        if check is not None:
            check(live)
        fd = os.open(snapshot_name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=scratch_fd)
        captured = None
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(os.dup(fd), 'wb') as output:
                output.write(live)
            # Keep the original staging fd open across the name check and
            # canonical child. A replacement, even with identical bytes,
            # must not become the authority lent to that child.
            captured = os.fstat(fd)
            named = os.stat(snapshot_name, dir_fd=scratch_fd, follow_symlinks=False)
            require(stat.S_ISREG(captured.st_mode) and captured.st_nlink == 1 and
                    integrity._fingerprint(named) == integrity._fingerprint(captured),
                    'captured input name changed')
            with integrity._bound_file(scratch_fd, snapshot_name, mode=0o600) as snapshot:
                require(snapshot == live, 'captured input bytes differ')
                yield live, [os.stat(name, dir_fd=parent_fd, follow_symlinks=False),
                             os.stat(snapshot_name, dir_fd=scratch_fd, follow_symlinks=False)]
        finally:
            try:
                current = os.stat(snapshot_name, dir_fd=scratch_fd, follow_symlinks=False)
                if (captured is not None and stat.S_ISREG(current.st_mode) and
                        integrity._fingerprint(current) == integrity._fingerprint(captured) ==
                        integrity._fingerprint(os.fstat(fd))):
                    os.unlink(snapshot_name, dir_fd=scratch_fd)
            except FileNotFoundError:
                pass
            os.close(fd)


@contextmanager
def captured_preflight_registry(scratch_fd, registry_path, diagnostic, lock_infos=()):
    """Lend one pinned capture to the existing canonical registry proposal.

    The normalized diagnostic bytes arrive on stdin from the lock-holding
    parent. Unsupported ctime or a foreign device is a read-only miss. The
    capture is named relative to the held workspace, the child's cwd.
    """
    parent, registry_name = os.path.split(registry_path)
    snapshot_name = 'registry.captured.json'
    def check(live):
        require(same_registry_snapshot(live, diagnostic), 'registry capture differs')
    with directory(parent) as registry_fd, \
         private_capture(scratch_fd, registry_fd, registry_name, snapshot_name, 0o600, check) as (live, inputs):
        prove_fine_ctime(scratch_fd, inputs + list(lock_infos))
        yield live, snapshot_name


@contextmanager
def captured_shared_exclude(scratch_fd, common, common_pin):
    """One exclude read for the donor and every canonical exclude check.

    Bound to the pinned common directory and lent to the child as a private
    copy, so repeated canonical checks of one record value see one file. The
    caller adds the identities to its fine-ctime proof.
    """
    snapshot_name = 'exclude.captured'
    with directory(common) as common_fd:
        require(identity(os.fstat(common_fd)) == common_pin, 'common directory replaced')
        with integrity._child_directory(common_fd, 'info') as info_fd, \
             private_capture(scratch_fd, info_fd, 'exclude', snapshot_name) as (data, inputs):
            yield data, snapshot_name, inputs


@contextmanager
def captured_owner_records(owner_dir, keys):
    keys = tuple(keys)
    require(len(keys) == len(set(keys)) and all(re.fullmatch(r'[0-9a-f]{64}', key) for key in keys),
            'invalid owner keys')
    with directory(owner_dir) as fd:
        expected = {key + '.json' for key in keys}
        require(set(os.listdir(fd)) == expected, 'owner namespace differs')
        parent_info = os.fstat(fd)
        infos = [parent_info]
        records = {}
        with ExitStack() as held:
            for key in keys:
                name = key + '.json'
                path = owner_dir + '/' + name
                records[path] = held.enter_context(integrity._bound_file(fd, name, mode=0o600))
                infos.append(os.stat(name, dir_fd=fd, follow_symlinks=False))
            yield records, infos
            require(set(os.listdir(fd)) == expected and
                    integrity._fingerprint(os.fstat(fd)) == integrity._fingerprint(parent_info),
                    'owner namespace changed during preflight')


PREFLIGHT = r'''
. "$1" || exit 1
home="$2"; registry="$3"; proposal="$4"; plan="$5"; authority="$6"; donor_owner="$7"
exclude_path="$8"; exclude_capture="$9"
trap 'surface_plan_cleanup' EXIT
_SURFACE_PLAN_HARNESSES=()
while IFS= read -r harness; do _SURFACE_PLAN_HARNESSES+=("$harness"); done < <(jq -r '.[]' "$plan.harnesses")
release="$(jq -r .release "$plan")"
payload="$home/releases/$release/payload"
manifest="$payload/core-rules/inheritance-manifest.json"
surface_plan_validate_manifest "$manifest" || exit 1
surface_plan_validate_expanded_skills "$payload" "$manifest" || exit 1
shift 9 || exit 1
verified_excludes=()
for owner in "$@"; do
  if [ "$owner" = "$donor_owner" ]; then
    # This canonical verifier calls _attachment_owner_json_valid itself. With a
    # shared seed proof for these exact bytes (T2a) only the per-artifact leaf
    # loop is skipped: attach-fastpath.py re-proved every leaf under the locks.
    leaves=all
    if [ -n "${_TRELLIS_PREFLIGHT_DONOR_PROVEN:-}" ] &&
       [ "$_TRELLIS_PREFLIGHT_DONOR_PROVEN" = "$owner"$'\t'"$(_attachment_hash "$owner")" ]; then
      leaves=proven-leaves
    fi
    _attachment_verify_owner_artifacts_impl "$home" "$owner" "$leaves" || { printf 'non-exact donor owner\n' >&2; exit 1; }
  else
    _attachment_owner_json_valid "$owner" || { printf 'invalid owner\n' >&2; exit 1; }
  fi
  # Every record must name the shared exclude the parent captured; the check
  # then reads that private copy, so one result serves each identical value.
  exclude="$(jq -cS --arg live "$exclude_path" --arg capture "$exclude_capture" \
    'if .exclude.path == $live then .exclude | .path = $capture else error("foreign exclude path") end' "$owner")" ||
    { printf 'invalid exclude owner\n' >&2; exit 1; }
  verified=0
  for previous in "${verified_excludes[@]+"${verified_excludes[@]}"}"; do
    if [ "$previous" = "$exclude" ]; then verified=1; break; fi
  done
  if [ "$verified" = 0 ]; then
    attach_exclude_verify_state "$exclude" || { printf 'invalid exclude owner\n' >&2; exit 1; }
    verified_excludes+=("$exclude")
  fi
done
_attachment_verify_managed_hooks "$home" "$authority" || { printf 'invalid managed hooks\n' >&2; exit 1; }
_attachment_validate_plan_file "$plan" || { printf 'invalid donor plan\n' >&2; exit 1; }
_attachment_validate_collisions "$(jq -c . "$plan")" || { printf 'donor plan collision\n' >&2; exit 1; }
_attachment_contextual_render_context_record_valid "$(jq -c . "$plan")" "$home" || { printf 'invalid plan context\n' >&2; exit 1; }
root="$(jq -r .worktree_root "$plan")"
identity="$(local_registry_identity_for_root "$root")" || exit 1
local_registry_propose_register_worktree "$registry" "$proposal" \
  "$(jq -r .fleet "$plan")" "$(jq -r .project_id "$plan")" \
  "$(printf '%s\n' "$identity" | jq -r .checkout_root)" \
  "$(printf '%s\n' "$identity" | jq -r .git_common_dir)" \
  "$(jq -r .checkout_id "$plan")" "$root" "$(jq -r .worktree_id "$plan")" \
  "$(jq -r .release "$plan")" "$(cat "$plan.harnesses")" \
  "$(jq -r .attachment_id "$plan")" '{}' bound-row || exit 1
'''


def shared_donor_proof(proof, expected_donor, donor_owner, snapshots, release):
    """T2a: the seed's canonical verify of the donor (attachment_verify_donor)
    stands in for PREFLIGHT's per-artifact loop only for the expected donor,
    the identical owner bytes captured under the locks, and this release.
    prepare() has already re-proved every donor leaf with artifact_exact."""
    if not proof or not expected_donor:
        return None
    fields = proof.split('\t')
    if len(fields) != 3:
        return None
    owner, digest, proof_release = fields
    if owner != donor_owner or proof_release != release or not re.fullmatch('[0-9a-f]{64}', digest):
        return None
    if owner not in snapshots or sha(snapshots[owner]) != digest:
        return None
    return owner + '\t' + digest


def prepare(home, root, fleet, project_id, binding, release, harnesses, expected_donor, attachment_id, root_pin, common_pin, exclude_bytes, owner_stack, registry_bytes):
    checkout, worktree, common = binding['checkout_id'], binding['worktree_id'], binding['git_common_dir']
    require(binding['root'] == root and sha(root.encode()) == worktree and sha(common.encode()) == checkout, 'invalid identity binding')
    with directory(root) as fd:
        require(identity(os.fstat(fd)) == root_pin, 'root replaced')
    with directory(common) as fd:
        require(identity(os.fstat(fd)) == common_pin, 'common directory replaced')
    live_identity(root, common)
    state = home + '/state'
    owner_dir = state + '/attachments/' + checkout
    journal_dir = state + '/attachment-journals'
    owner_path = owner_dir + '/' + worktree + '.json'
    require(not os.path.lexists(owner_path), 'target already owned')
    require(not os.path.lexists(state + '/release-adoptions/' + checkout), 'pending adoption')
    for path in (home, state, state + '/attachments', owner_dir, journal_dir):
        with directory(path) as fd:
            require(stat.S_IMODE(os.fstat(fd).st_mode) == 0o700, 'nonprivate attachment state')
    with directory(journal_dir) as fd:
        require(not os.listdir(fd), 'pending journal')
    registry = json.loads(registry_bytes)
    project = registry['projects'][fleet + '/' + project_id]
    require(project['status'] == 'active' and not project.get('metadata', {}).get('legacy', {}).get('blacklisted', False), 'inactive checkout')
    require(root not in project.get('unavailable_roots', []), 'unavailable target')
    group = project['checkouts'][checkout]
    require(group['git_common_dir'] == common and group['release'] == release and sorted(group['harnesses']) == harnesses, 'release/harness mismatch')
    target_row = group['worktrees'].get(worktree, {'root': root})
    require(target_row['root'] == root and not target_row.get('attachment_id'), 'target registry conflict')
    rows = {key: row for key, row in group['worktrees'].items() if row.get('attachment_id')}
    require(rows and worktree not in rows, 'no attached donor')
    require(sys.platform == 'darwin' or (sys.platform.startswith('linux') and hasattr(ctypes.CDLL(None), 'renameat2')), 'exclusive directory publication unavailable')
    owner_snapshots, owner_infos = owner_stack.enter_context(captured_owner_records(owner_dir, sorted(rows)))
    owners, owner_files, authority = {}, [], None
    for key, row in sorted(rows.items()):
        path = owner_dir + '/' + key + '.json'
        record = json.loads(owner_snapshots[path])
        donor_root = row['root']
        require(donor_root != root and sha(donor_root.encode()) == key, 'donor root binding differs')
        live_identity(donor_root, common)
        manifest = json.loads(read_regular(donor_root + '/.trellis.json'))
        require(manifest.get('project_id') == project_id, 'donor project differs')
        for field, value in [('status', 'committed'), ('fleet', fleet), ('project_id', project_id), ('checkout_id', checkout), ('worktree_id', key), ('attachment_id', row['attachment_id']), ('release', release), ('project_root', donor_root), ('worktree_root', donor_root)]:
            require(record.get(field) == value, 'donor binding differs')
        if record.get('git_hooks', {}).get('enabled'):
            require(authority is None, 'multiple hook authorities')
            authority = path
        owners[key] = record
        owner_files.append(path)
    require(authority is not None, 'missing hook authority')
    donor = None
    candidates = [owners[expected_donor['worktree_id']]] if expected_donor else owners.values()
    for candidate in candidates:
        if not expected_donor and candidate.get('pre_existing'):
            continue  # Deferred leaves need fresh planning; try another donor.
        try:
            for artifact in candidate['artifacts']:
                artifact_exact(candidate['worktree_root'], artifact)
        except (OSError, ValueError):
            continue  # Native drift disqualifies this donor, not exclude ownership.
        donor = candidate
        break
    require(donor is not None, 'no exact donor')
    if expected_donor:
        require(donor['attachment_id'] == expected_donor['attachment_id'] and donor['worktree_root'] == expected_donor['root'], 'expected donor changed')
    require(not donor.get('pre_existing'), 'donor deferred leaves need fresh planning')
    require(all(not r['before_exists'] for r in donor.get('renders', [])), 'donor guards contain project content')
    toolchain = donor.get('toolchain_path', [])
    require(toolchain and any(p not in ('/usr/bin', '/bin', '/usr/sbin', '/sbin') for p in toolchain), 'donor toolchain absent/control-only')
    for path in toolchain:
        with directory(path):
            pass
    if not expected_donor:
        require(caller_toolchain() == toolchain, 'caller toolchain needs fresh capture')
        if donor.get('render_context'):
            require(donor['render_context']['user_home'] == os.path.realpath(os.environ.get('HOME', '')), 'different render home')
    require(project_file_present(root + '/CLAUDE.md') == project_file_present(donor['worktree_root'] + '/CLAUDE.md'), 'different project CLAUDE context')
    managed = state + '/git-hooks/' + checkout
    authority_record = owners[Path(authority).stem]
    hooks = authority_record['git_hooks']
    require(hooks['managed_hooks_path'] == managed, 'different managed hooks')
    require(git(root, 'config', '--local', '--get-all', 'core.hooksPath') == (managed + '\n').encode(), 'hooksPath mismatch')
    require(git(root, 'config', '--get', 'core.hooksPath') == (managed + '\n').encode(), 'effective hooksPath mismatch')
    pins = []
    for name in ('pre-push', 'post-checkout'):
        body = read_regular(managed + '/' + name, mode=0o700).decode()
        found = re.findall(r'^expected_release_manifest_sha256=([0-9a-f]{64})$', body, re.M)
        require(len(found) == 1, 'missing dispatcher manifest pin')
        pins.append(found[0])
    require(pins[0] == pins[1], 'dispatcher pins differ')
    payload = home + '/releases/' + release + '/payload'
    native = []
    required = ['scripts/seed-inheritance-symlinks.sh', hooks['pre_push_source']] + current_inventory(donor, payload, harnesses, native)
    if native:
        required += render_inputs(payload)
    release_record = integrity.verify_release_executed(home + '/releases/' + release, pins[0], required)
    require(release_record['version'] == release, 'release version differs')
    # Native renders name the project root and this host's companion, so the
    # target's are the canonical renderer's, never the donor's bytes.
    target_renders = canonical_renders(payload, donor, root, native) if native else {}
    exclude_path = common + '/info/exclude'
    exclude = copy.deepcopy(authority_record['exclude'])
    require(exclude['managed_by_attachment'] and exclude['path'] == exclude_path and exclude['git_common_dir'] == common, 'exclude authority mismatch')
    require(exclude_bytes == base64.b64decode(exclude['after_base64'], validate=True), 'exclude bytes changed')
    for record in owners.values():
        require(record['exclude_block_hash'] == exclude['managed_block_sha256'] and record['exclude']['git_common_dir'] == common, 'sibling exclude differs')
    block = base64.b64decode(exclude['managed_block_base64'], validate=True)
    require(sha(block) == exclude['managed_block_sha256'] and exclude_bytes.count(block) == 1, 'exclude block differs')
    exclude.update(before_exists=True, before_sha256=sha(exclude_bytes), before_base64=encoded(exclude_bytes), after_exists=True, after_sha256=sha(exclude_bytes), after_base64=encoded(exclude_bytes), managed_by_attachment=False)
    leaves = [copy.deepcopy(target_renders[a['path']][0]) if a['path'] in target_renders else copy.deepcopy(a)
              for a in donor['artifacts'] if a['kind'] != 'parent']
    require(any(a == {'path': '.trellis/runtime', 'kind': 'symlink', 'target': payload} for a in leaves), 'runtime release anchor differs')
    parents = set()
    for artifact in leaves:
        path = relative(artifact['path'])
        require(not os.path.lexists(root + '/' + path), 'project-owned target leaf')
        parts = path.split('/')[:-1]
        parents.update('/'.join(parts[:i]) for i in range(1, len(parts) + 1))
        if artifact['kind'] == 'file' and path not in target_renders:
            artifact['content_base64'] = encoded(artifact_exact(donor['worktree_root'], artifact))
    owned_parents = []
    for path in sorted(parents, key=lambda p: (p.count('/'), p)):
        if os.path.lexists(root + '/' + path):
            with directory(root + '/' + path):
                pass
        else:
            owned_parents.append({'path': path, 'kind': 'parent'})
    paths = [a['path'] for a in leaves]
    require(not git(root, 'ls-files', '-z', '--', *paths), 'tracked destination conflict')
    ignored = git(root, 'check-ignore', '-z', '--no-index', '--stdin', data=('\0'.join(paths) + '\0').encode(), allowed=(0, 1)).decode().split('\0')
    require(set(paths) <= set(ignored), 'exclude not effective')
    plan = copy.deepcopy(donor)
    plan.update(status='prepared', project_root=root, worktree_root=root, checkout_id=checkout, worktree_id=worktree, attachment_id=attachment_id, artifacts=owned_parents + leaves, exclude=exclude, git_hooks={'enabled': False})
    if target_renders:
        plan['renders'] = [copy.deepcopy(target_renders[r['path']][1]) if r['path'] in target_renders else r for r in plan.get('renders', [])]
    donor_owner = owner_dir + '/' + donor['worktree_id'] + '.json'
    return plan, owner_path, journal_dir + '/' + attachment_id + '.json', authority, donor_owner, owner_files, owner_snapshots, owner_infos


def publish(plan, owner_path, journal_path, root_pin, common_pin, recheck_locks):
    root = plan['worktree_root']
    common = plan['exclude']['git_common_dir']
    def namespace():
        # Every namespace check, including the last one before the owner
        # commit, also proves the transaction locks are still the held ones.
        recheck_locks()
        for path, pin in ((root, root_pin), (common, common_pin)):
            with directory(path) as fd:
                require(identity(os.fstat(fd)) == pin, 'namespace replaced')
    namespace()
    journal = json.loads(read_regular(journal_path, mode=0o600))
    require(journal == dict(plan, phase=0, applied=[], pending=None, removal=None), 'journal changed before publication')
    for artifact in plan['artifacts']:
        namespace()
        parent, name = os.path.split(root + '/' + artifact['path'])
        with directory(parent) as fd:
            stage = '.' + name + '.attachment-stage-' + plan['attachment_id'] + '.' + uuid.uuid4().hex
            journal['pending'] = dict(artifact=artifact, staging_path=parent + '/' + stage, staging_identity=None, destination_identity=None, parent_identity=identity(os.fstat(fd)))
            write_json(journal_path, journal)
            kind = artifact['kind']
            if kind in ('parent', 'directory'):
                os.mkdir(stage, 0o755, dir_fd=fd)
            elif kind == 'symlink':
                os.symlink(artifact['target'], stage, dir_fd=fd)
            else:
                out = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, int(artifact.get('mode', '0644'), 8), dir_fd=fd)
                with os.fdopen(out, 'wb') as stream:
                    stream.write(base64.b64decode(artifact['content_base64'], validate=True))
                    os.fchmod(stream.fileno(), int(artifact.get('mode', '0644'), 8))
            journal['pending']['staging_identity'] = identity(os.stat(stage, dir_fd=fd, follow_symlinks=False))
            write_json(journal_path, journal)
            if kind in ('parent', 'directory'):
                native_directory_publish(fd, stage, name)
            else:
                try:
                    os.link(stage, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                except OSError as error:
                    if not link_unsupported(error):
                        raise
                    exclusive_rename_at(fd, stage, name)
                else:
                    os.unlink(stage, dir_fd=fd)
            require(identity(os.stat(name, dir_fd=fd, follow_symlinks=False)) == journal['pending']['staging_identity'], 'publication identity differs')
            namespace()
            journal['phase'] += 1
            journal['applied'] = plan['artifacts'][:journal['phase']]
            journal['pending'] = None
            write_json(journal_path, journal)
        if os.environ.get('ATTACHMENT_FAULT_PHASE') == 'fast-published':
            raise ValueError('injected interruption after batch publication')
    namespace()
    managed = str(Path(journal_path).parent.parent / 'git-hooks' / plan['checkout_id'])
    require(git(root, 'config', '--local', '--get-all', 'core.hooksPath') == (managed + '\n').encode() and git(root, 'config', '--get', 'core.hooksPath') == (managed + '\n').encode(), 'hooksPath changed before commit')
    owner = copy.deepcopy(plan)
    owner['status'] = 'committed'
    for artifact in owner['artifacts']:
        artifact.pop('content_base64', None)
    write_json(owner_path, owner, exclusive=True)
    with directory(os.path.dirname(journal_path)) as fd:
        os.unlink(os.path.basename(journal_path), dir_fd=fd)


def main():
    mode = '--begin'
    started = False
    try:
        mode, workspace = sys.argv[1:3]
        started = mode == '--finish'
        if mode in ('--begin', '--finish'):
            require_private_lock_fds((31, 32, 33))
        load_integrity()
        require(mode in ('--begin', '--finish'), 'invalid phase')
        if mode == '--finish':
            with directory(workspace) as fd:
                require(stat.S_IMODE(os.fstat(fd).st_mode) == 0o700, 'nonprivate workspace')
        plan_file = workspace + '/plan.json'
        # Only this caller's explicit argument may carry a donor proof; never
        # let an inherited value reach PREFLIGHT.
        donor_proof = os.environ.pop('TRELLIS_FASTPATH_DONOR_PROOF', '')
        os.environ.pop('_TRELLIS_PREFLIGHT_DONOR_PROVEN', None)
        if mode == '--begin':
            diagnostic = sys.stdin.buffer.read()
            (home, root, fleet, project, binding, release, harnesses, expected_donor, attachment_id,
             root_pin, common_pin, checkout_pid, attachment_pid, registry_pid) = sys.argv[3:]
            binding = json.loads(binding)
            # One held workspace descriptor serves every begin-phase workspace
            # access and is the canonical child's cwd, so renaming a workspace
            # ancestor cannot redirect what the child reads or writes.
            with transaction_lock_scope(home, binding, attachment_id, checkout_pid, attachment_pid, registry_pid) as locks:
                registry_path = home + '/registry.json'
                with ExitStack() as owner_stack:
                    scratch_fd = owner_stack.enter_context(directory(workspace))
                    require(stat.S_IMODE(os.fstat(scratch_fd).st_mode) == 0o700, 'nonprivate workspace')
                    registry_before, captured_registry = owner_stack.enter_context(
                        captured_preflight_registry(scratch_fd, registry_path, diagnostic, locks.proof_infos()))
                    exclude_before, captured_exclude, exclude_infos = owner_stack.enter_context(
                        captured_shared_exclude(scratch_fd, binding['git_common_dir'], common_pin))
                    locks.recheck()
                    plan, owner_path, candidate, authority, donor_owner, owners, snapshots, owner_infos = prepare(home, root, fleet, project, binding, release, json.loads(harnesses), json.loads(expected_donor or 'null'), attachment_id, root_pin, common_pin, exclude_before, owner_stack, registry_before)
                    prove_fine_ctime(scratch_fd, owner_infos + exclude_infos)
                    # No project or persistent-state writes during eligibility validation.
                    write_json_at(scratch_fd, 'plan.json', plan, exclusive=True)
                    out = os.open('plan.json.harnesses', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=scratch_fd)
                    with os.fdopen(out, 'w') as stream:
                        stream.write(harnesses)
                    env = dict(os.environ, TRELLIS_LIBS_PRELOADED='0')
                    proven = shared_donor_proof(donor_proof, json.loads(expected_donor or 'null'), donor_owner, snapshots, release)
                    if proven:
                        env['_TRELLIS_PREFLIGHT_DONOR_PROVEN'] = proven
                    if os.environ.get('TRELLIS_FASTPATH_TRACE') == '1':
                        print('trellis attach: donor proof ' + ('shared' if proven else 'not shared'), file=sys.stderr)
                    locks.recheck()
                    result = subprocess.run(['/bin/bash', '-c', PREFLIGHT, 'fast-preflight', str(Path(__file__).parent.parent / 'attach-project.sh'), home, captured_registry, 'registry.json', 'plan.json', authority, donor_owner, binding['git_common_dir'] + '/info/exclude', captured_exclude, *owners],
                                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=lambda: os.fchdir(scratch_fd))
                    require(result.returncode == 0, 'existing attachment preflight refused: ' + result.stderr.decode(errors='replace')[-2000:])
                    with integrity._bound_file(scratch_fd, 'registry.json') as data:
                        proposal_digest = registry_digest(data)
                    for path, before in snapshots.items():
                        require(read_regular(path, mode=0o600) == before, 'donor changed during preflight')
                    require(read_regular(registry_path, mode=0o600) == registry_before, 'registry changed during preflight')
                # All pinned input contexts must close cleanly before this first
                # persistent write: a recoverable v1 journal. The lock scope
                # remains held and is checked immediately before and after it.
                require(not os.path.lexists(candidate), 'journal appeared during preflight')
                with directory(root) as fd:
                    require(identity(os.fstat(fd)) == root_pin, 'root replaced')
                with directory(os.path.dirname(candidate)):
                    pass
                locks.recheck()
                write_json(candidate, dict(plan, phase=0, applied=[], pending=None, removal=None), exclusive=True)
                locks.recheck()
            # The only stdout line: --finish binds the registry write to it
            # instead of re-reading the workspace proposal by path.
            print(proposal_digest)
            return 0
        # The calling Bash process holds the registry lock and performs the
        # bound-row write through local_registry_write_locked_bound_rows.
        plan = json.loads(read_regular(plan_file, mode=0o600))
        home = sys.argv[3]
        registry_path = home + '/registry.json'
        root_pin, common_pin, proposal_digest, checkout_pid, attachment_pid, registry_pid = sys.argv[4:10]
        owner_path = home + '/state/attachments/' + plan['checkout_id'] + '/' + plan['worktree_id'] + '.json'
        candidate = home + '/state/attachment-journals/' + plan['attachment_id'] + '.json'
        binding = {'checkout_id': plan['checkout_id'], 'worktree_id': plan['worktree_id'],
                   'git_common_dir': plan['exclude']['git_common_dir']}
        # The caller kept its three lock pins through the registry write:
        # publication and the owner commit run only while they still name
        # the holders --begin proved, and a lost lock leaves the journal.
        with transaction_lock_scope(home, binding, plan['attachment_id'],
                                    checkout_pid, attachment_pid, registry_pid) as locks:
            require(re.fullmatch(r'[0-9a-f]{64}', proposal_digest) is not None and
                    registry_digest(read_regular(registry_path, mode=0o600)) == proposal_digest,
                    'registry API write differs from the begin proposal')
            publish(plan, owner_path, candidate, root_pin, common_pin, locks.recheck)
        print(owner_path)
        return 0
    except LostTransactionLock as error:
        if 'candidate' in locals() and os.path.lexists(candidate):
            print('trellis attach: lock scope changed after journaling; run trellis recover: ' + str(error), file=sys.stderr)
        else:
            print('trellis attach: lock scope changed; inspect the retained locks and retry: ' + str(error), file=sys.stderr)
        return 3
    except Exception as error:
        if started or (mode == '--begin' and 'candidate' in locals() and os.path.lexists(candidate)):
            print('trellis attach: donor batch interrupted; run trellis recover: ' + str(error), file=sys.stderr)
            return 3
        if isinstance(error, RenderMiss):
            print('trellis attach: donor not reused (' + str(error) + '); running the full attach', file=sys.stderr)
        elif os.environ.get('TRELLIS_FASTPATH_TRACE') == '1':
            print('trellis attach: donor fast-path miss: ' + repr(str(error)), file=sys.stderr)
        return 10


if __name__ == '__main__':
    sys.exit(main())
