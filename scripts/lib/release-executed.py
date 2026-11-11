"""Shared synchronous check: pinned release record plus all executable sources.

Full inventory audits belong to the post-attach job and pre-push. Source files
are included even without the executable bit: hooks source/import libraries.
All release inputs and their parents remain descriptor-bound until postflight.
"""
import ctypes
import errno
import hashlib
import json
import os
import re
import stat
import sys
from contextlib import ExitStack, contextmanager


def _anchor(info):
    # Directory size/timestamps change with child churn; the held descriptor
    # pins its inode, while the parent-relative lookup proves its binding.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)


def _fingerprint(info):
    return (_anchor(info), info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@contextmanager
def _child_directory(parent_fd, name, sealed=False):
    """Retain an entry and prove the same inode remains at its parent name."""
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode):
        raise ValueError('not a real directory')
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        if _anchor(before) != _anchor(os.fstat(fd)):
            raise ValueError('directory changed while opening')
        if sealed:
            _sealed_directory(fd)
        yield fd
        if sealed:
            _sealed_directory(fd)
        if (_anchor(before) != _anchor(os.fstat(fd)) or
                _anchor(before) != _anchor(os.stat(name, dir_fd=parent_fd, follow_symlinks=False))):
            raise ValueError('directory changed during verification')
    finally:
        os.close(fd)


@contextmanager
def directory(path):
    """Open a canonical absolute directory, retaining every no-follow parent."""
    if not isinstance(path, str) or not path.startswith('/') or path == '/':
        raise ValueError('noncanonical directory')
    parts = path.split('/')[1:]
    if any(p in ('', '.', '..') or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in p) for p in parts):
        raise ValueError('unsafe directory')
    root_fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    fd = root_fd
    try:
        with ExitStack() as stack:
            for part in parts:
                fd = stack.enter_context(_child_directory(fd, part))
            yield fd
    finally:
        # The filesystem-root descriptor belongs to this function, not the
        # stack of descendant contexts.
        os.close(root_fd)


def relative(path):
    if not isinstance(path, str) or any(p in ('', '.', '..') for p in path.split('/')) or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in path):
        raise ValueError('unsafe relative path')
    return path


def check_fd_acl(fd):
    """Raise on ACL presence or an unavailable descriptor inspection."""
    if sys.platform == 'darwin':
        lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.acl_get_fd_np.restype = ctypes.c_void_p
        lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
        lib.acl_get_entry.restype = ctypes.c_int
        lib.acl_free.argtypes = [ctypes.c_void_p]
        lib.acl_free.restype = ctypes.c_int
        ctypes.set_errno(0)
        acl = lib.acl_get_fd_np(fd, 0x100)
        if not acl:
            error = ctypes.get_errno()
            if error == errno.ENOENT:
                return
            raise OSError(error or errno.EIO, 'ACL inspection failed')
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = lib.acl_get_entry(acl, 0, ctypes.byref(entry))
        entry_error = (ctypes.get_errno() or errno.EIO) if result != 0 else (errno.EIO if not entry.value else 0)
        ctypes.set_errno(0)
        freed = lib.acl_free(acl)
        free_error = ctypes.get_errno() if freed != 0 else 0
        if freed != 0:
            raise OSError(free_error or errno.EIO, 'ACL free failed')
        if entry_error:
            raise OSError(entry_error, 'ACL entry inspection failed')
        raise ValueError('entry carries an ACL')
    if sys.platform.startswith('linux'):
        for name in ('system.posix_acl_access', 'system.posix_acl_default'):
            try:
                os.getxattr(fd, name)
            except OSError as error:
                if error.errno == errno.ENODATA:
                    continue
                raise
            raise ValueError('entry carries an ACL')
        return
    raise OSError(errno.EOPNOTSUPP, 'descriptor ACL inspection unavailable')


def _sealed_directory(fd):
    if os.fstat(fd).st_mode & 0o222:
        raise ValueError('writable executable namespace')
    check_fd_acl(fd)


@contextmanager
def _bound_file(parent_fd, name, mode=None, sealed=False, git_mode=None, check_acl=False):
    before_name = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('not a single-link regular file')
        if _fingerprint(before) != _fingerprint(before_name):
            raise ValueError('file changed while opening')
        bits = stat.S_IMODE(before.st_mode)
        if mode is not None and bits != mode:
            raise ValueError('file mode differs')
        if sealed and bits & 0o222:
            raise ValueError('writable executed file')
        if git_mode is not None and ('100755' if bits & 0o111 else '100644') != git_mode:
            raise ValueError('executed file mode differs from manifest')
        if check_acl:
            check_fd_acl(fd)
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        if check_acl:
            check_fd_acl(fd)
        if (_fingerprint(before) != _fingerprint(os.fstat(fd)) or
                _fingerprint(before) != _fingerprint(os.stat(name, dir_fd=parent_fd, follow_symlinks=False))):
            raise ValueError('file changed during read')
        yield b''.join(chunks)
        if check_acl:
            check_fd_acl(fd)
        if (_fingerprint(before) != _fingerprint(os.fstat(fd)) or
                _fingerprint(before) != _fingerprint(os.stat(name, dir_fd=parent_fd, follow_symlinks=False))):
            raise ValueError('file changed during verification')
    finally:
        os.close(fd)


def read_regular(path, mode=None, sealed=False, git_mode=None):
    """Pin the parent and leaf, and reject links and concurrent replacement."""
    parent, name = os.path.split(path)
    with directory(parent) as parent_fd:
        with _bound_file(parent_fd, name, mode=mode, sealed=sealed, git_mode=git_mode) as data:
            return data


def verify_release_executed(release, expected_sha256, required=()):
    """Verify the trusted manifest pin and transitive executable sources.

    The pin is obtained from trusted dispatcher state, never by hashing the
    record immediately before this call and treating that as authorization.
    """
    if not re.fullmatch('[0-9a-f]{64}', expected_sha256):
        raise ValueError('missing release pin')
    required = {relative(name) for name in required}
    with directory(release) as release_fd:
        _sealed_directory(release_fd)
        with ExitStack() as held:
            data = held.enter_context(_bound_file(release_fd, 'release.json', sealed=True, check_acl=True))
            if hashlib.sha256(data).hexdigest() != expected_sha256:
                raise ValueError('release record pin differs')
            record = json.loads(data)
            if not isinstance(record, dict) or record.get('schema_version') != 1 or record.get('tag') != 'v' + record.get('version', ''):
                raise ValueError('invalid release record')
            rows = record.get('tree')
            if not isinstance(rows, list) or not rows:
                raise ValueError('missing release inventory')
            payload_fd = held.enter_context(_child_directory(release_fd, 'payload', sealed=True))
            directories = {(): payload_fd}
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
                parts = name.split('/')
                prefix = ()
                for component in parts[:-1]:
                    child = prefix + (component,)
                    if child not in directories:
                        directories[child] = held.enter_context(_child_directory(directories[prefix], component, sealed=True))
                    prefix = child
                content = held.enter_context(_bound_file(directories[prefix], parts[-1], sealed=True, git_mode=row['mode'], check_acl=True))
                # Git blob object ID compatibility, not a cryptographic signature.
                digest = hashlib.sha1(b'blob ' + str(len(content)).encode('ascii') + b'\0' + content).hexdigest()  # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
                if digest != row['oid']:
                    raise ValueError('executed payload differs: ' + name)
            if not required <= names:
                raise ValueError('executed entry is absent from manifest')
            _sealed_directory(release_fd)
        return record
