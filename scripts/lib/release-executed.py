"""Shared synchronous check: pinned release record plus all executable sources.

Full inventory audits belong to the post-attach job and pre-push. Source files
are included even without the executable bit: hooks source/import libraries.
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from contextlib import contextmanager


@contextmanager
def directory(path):
    """Open a canonical absolute directory without following any component."""
    if not isinstance(path, str) or not path.startswith('/') or path == '/':
        raise ValueError('noncanonical directory')
    parts = path.split('/')[1:]
    if any(p in ('', '.', '..') or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in p) for p in parts):
        raise ValueError('unsafe directory')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def relative(path):
    if not isinstance(path, str) or any(p in ('', '.', '..') for p in path.split('/')) or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in path):
        raise ValueError('unsafe relative path')
    return path


def read_regular(path, mode=None, sealed=False, git_mode=None):
    """Pin the parent and leaf, and reject links and concurrent replacement."""
    parent, name = os.path.split(path)
    with directory(parent) as parent_fd:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise ValueError('not a single-link regular file')
            bits = stat.S_IMODE(before.st_mode)
            if mode is not None and bits != mode:
                raise ValueError('file mode differs')
            if sealed and bits & 0o222:
                raise ValueError('writable executed file')
            if git_mode is not None and ('100755' if bits & 0o111 else '100644') != git_mode:
                raise ValueError('executed file mode differs from manifest')
            chunks = []
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            after = os.fstat(fd)
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            def stamp(s):
                return (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if stamp(before) != stamp(after) or stamp(after) != stamp(current):
                raise ValueError('file changed during read')
            return b''.join(chunks)
        finally:
            os.close(fd)


def verify_release_executed(release, expected_sha256, required=()):
    """Verify the dispatcher-pinned manifest and transitive executable sources.

    Returns parsed release.json. A caller must obtain the pin from trusted
    existing dispatcher state, not freshly hash the record and bless itself.
    """
    if not re.fullmatch('[0-9a-f]{64}', expected_sha256):
        raise ValueError('missing release pin')
    data = read_regular(release + '/release.json', sealed=True)
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError('release record pin differs')
    record = json.loads(data)
    if not isinstance(record, dict) or record.get('schema_version') != 1 or record.get('tag') != 'v' + record.get('version', ''):
        raise ValueError('invalid release record')
    rows = record.get('tree')
    if not isinstance(rows, list) or not rows:
        raise ValueError('missing release inventory')
    required = {relative(name) for name in required}
    readonly_dirs = {release, release + '/payload'}
    acl_paths = {release + '/release.json'}
    names = set()
    for row in rows:
        if not isinstance(row, dict) or not {'path', 'mode', 'oid'} <= row.keys():
            raise ValueError('invalid release row')
        name = relative(row['path'])
        if name in names or row['mode'] not in ('100644', '100755', '120000') or not re.fullmatch('[0-9a-f]{40}', row['oid']):
            raise ValueError('invalid release inventory')
        names.add(name)
        executed = (row['mode'] == '100755' or name in required
                    or name.startswith(('scripts/', 'core-rules/hooks/', 'core-rules/githooks/', 'core-rules/husky/', 'core-rules/codex/hooks/', 'core-rules/pi/hooks/', 'core-rules/pi/extensions/'))
                    or name.endswith(('.sh', '.bash', '.py', '.pyc', '.js', '.cjs', '.mjs', '.ts', '.tsx', '.rb', '.pl', '.so', '.dylib', '.node')))
        if not executed:
            continue
        if row['mode'] == '120000':
            raise ValueError('executed symlink needs the full verifier')
        current = release + '/payload'
        for component in name.split('/')[:-1]:
            current += '/' + component
            readonly_dirs.add(current)
        acl_paths.add(release + '/payload/' + name)
        content = read_regular(release + '/payload/' + name, sealed=True, git_mode=row['mode'])
        # Git blob object ID compatibility, not a cryptographic signature.
        digest = hashlib.sha1(b'blob ' + str(len(content)).encode('ascii') + b'\0' + content).hexdigest()  # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
        if digest != row['oid']:
            raise ValueError('executed payload differs: ' + name)
    if not required <= names:
        raise ValueError('executed entry is absent from manifest')
    for path in readonly_dirs:
        with directory(path) as fd:
            if os.fstat(fd).st_mode & 0o222:
                raise ValueError('writable executable namespace')
    # One bounded batch per ~32KiB, not one process per file. On macOS @ can
    # hide the + ACL marker, so request the actual ACL entries, not just modes.
    paths = sorted(acl_paths | readonly_dirs)
    while paths:
        batch, size = [], 0
        while paths and size + len(os.fsencode(paths[-1])) < 32768:
            path = paths.pop()
            batch.append(path)
            size += len(os.fsencode(path)) + 1
        if not batch:
            raise ValueError('ACL pathname exceeds batch limit')
        result = subprocess.run(['/bin/ls', '-lde' if sys.platform == 'darwin' else '-ld', '--', *batch], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, LC_ALL='C'))
        lines = result.stdout.splitlines()
        if result.returncode or len(lines) != len(batch) or any(not line.split() or b'+' in line.split()[0] for line in lines):
            raise ValueError('executed namespace has an ACL or is unavailable')
    return record
