#!/usr/bin/env python3
"""Probe Linux link ACL semantics in a private, unprivileged temporary tree.

Historical baseline probe: its canonical lookup models 1b281eaa, before the
symlink-specific EOPNOTSUPP change. An inconclusive result is not a verdict.

Run: python3 -I release-symlink-acl-linux.py
No project or installed release is read or changed. The ACL payload is a valid
Linux POSIX ACL with a named user, checked first on an ordinary owned file and
on an owned directory. The final lookup duplicates the exact low-level calls of
release_verify.py AclProbe._linux(..., follow_symlinks=False).

A zero exit is evidence for this host/filesystem, not all possible filesystems
or NFSv4 ACL implementations. 1 is a contradiction; 5 is inconclusive.
"""
import errno
import json
import os
import platform
import struct
import sys
import tempfile


def result(case, verdict, detail):
    print(f'{case}: {verdict} {detail}', flush=True)


def main():
    if sys.platform != 'linux':
        result('host', 'INCONCLUSIVE', f'not Linux: {sys.platform}')
        return 5
    if os.geteuid() == 0:
        result('host', 'INCONCLUSIVE', 'must run as a non-root user')
        return 5
    if not hasattr(os, 'O_PATH'):
        result('host', 'INCONCLUSIVE', 'O_PATH unavailable')
        return 5
    result('host', 'INFO', f'{platform.platform()} uid={os.geteuid()}')
    with tempfile.TemporaryDirectory(prefix='trellis-symlink-acl.') as root:
        os.chmod(root, 0o700)
        for name in ('home', 'trellis', 'tmp'):
            os.mkdir(os.path.join(root, name), 0o700)
        os.environ.update(HOME=os.path.join(root, 'home'),
                          TRELLIS_HOME=os.path.join(root, 'trellis'),
                          TMPDIR=os.path.join(root, 'tmp'),
                          GIT_CONFIG_GLOBAL=os.path.join(root, 'gitconfig'),
                          GIT_CONFIG_NOSYSTEM='1')
        regular = os.path.join(root, 'file')
        directory = os.path.join(root, 'dir')
        link = os.path.join(root, 'link')
        with open(regular, 'wb') as f:
            f.write(b'control\n')
        os.chmod(regular, 0o600)
        os.mkdir(directory, 0o700)
        os.symlink('file', link)
        # linux/posix_acl_xattr.h: version 2; tag, permissions, id. The named
        # user and mask ensure this is an extended ACL rather than mode bits.
        acl = struct.pack('<I', 2) + b''.join(
            struct.pack('<HHI', tag, perm, ident) for tag, perm, ident in [
                (0x01, 6, 0xffffffff), (0x02, 4, 65534),
                (0x04, 0, 0xffffffff), (0x10, 4, 0xffffffff),
                (0x20, 0, 0xffffffff)])
        pairs = [('access', 'system.posix_acl_access', regular),
                 ('default', 'system.posix_acl_default', directory)]
        outcome = 0
        for label, name, control in pairs:
            try:
                os.setxattr(control, name, acl, follow_symlinks=False)
                got = os.getxattr(control, name, follow_symlinks=False)
                if got != acl:
                    result(label + '-control', 'INCONCLUSIVE', 'ACL bytes changed')
                    outcome = 1 if outcome == 1 else 5
                    continue
                result(label + '-control', 'PASS', 'valid ACL set and read back')
            except OSError as exc:
                result(label + '-control', 'INCONCLUSIVE', f'errno={exc.errno} {exc.strerror}')
                outcome = 1 if outcome == 1 else 5
                continue
            try:
                os.setxattr(link, name, acl, follow_symlinks=False)
            except OSError as exc:
                if exc.errno in (errno.EPERM, errno.EACCES, errno.EOPNOTSUPP, errno.EINVAL):
                    result(label + '-symlink', 'PASS', f'no-follow set refused errno={exc.errno} {exc.strerror}')
                else:
                    result(label + '-symlink', 'INCONCLUSIVE', f'errno={exc.errno} {exc.strerror}')
                    outcome = 1 if outcome == 1 else 5
            else:
                result(label + '-symlink', 'FAIL', 'kernel accepted a symlink POSIX ACL')
                outcome = 1
        try:
            # Match release_verify.py AclProbe._linux precisely: only ENODATA
            # means absent for each POSIX name; an NFSv4 name means ACL.
            present = []
            for name in ('system.posix_acl_access', 'system.posix_acl_default'):
                try:
                    os.getxattr(link, name, follow_symlinks=False)
                except OSError as exc:
                    if exc.errno != errno.ENODATA:
                        raise
                else:
                    present.append(name)
            names = os.listxattr(link, follow_symlinks=False)
            if 'system.nfs4_acl' in names:
                present.append('system.nfs4_acl')
            if present:
                result('canonical-link-acl', 'FAIL', f'canonical sees {json.dumps(present)}')
                outcome = 1
            else:
                result('canonical-link-acl', 'PASS', f'POSIX absent, NFSv4 absent; xattrs={json.dumps(names)}')
        except OSError as exc:
            result('canonical-link-acl', 'INCONCLUSIVE', f'errno={exc.errno} {exc.strerror}')
            outcome = 1 if outcome == 1 else 5
        try:
            fd = os.open(link, os.O_PATH | os.O_NOFOLLOW)
            try:
                os.getxattr(fd, 'system.posix_acl_access')
            finally:
                os.close(fd)
        except OSError as exc:
            result('opath-fgetxattr', 'INFO', f'errno={exc.errno} {exc.strerror}')
        else:
            result('opath-fgetxattr', 'INFO', 'descriptor query unexpectedly succeeded')
        result('scope', 'INFO', 'one local filesystem only; NFSv4 symlink ACL creation not exercised')
        result('result', 'PASS' if outcome == 0 else ('FAIL' if outcome == 1 else 'INCONCLUSIVE'), f'exit={outcome}')
        return outcome


if __name__ == '__main__':
    sys.exit(main())
