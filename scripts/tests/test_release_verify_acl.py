#!/usr/bin/env python3
"""Linux ACL errno classes for the canonical one-process release verifier."""
import errno
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


LIB = Path(__file__).resolve().parents[1] / 'lib' / 'release_verify.py'
SPEC = importlib.util.spec_from_file_location('release_verify_acl_tests', LIB)
release_verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_verify)


def error(code):
    return OSError(code, 'injected ACL lookup')


class LinuxAclClasses(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith('linux'), 'real Linux kernel required')
    def test_real_linux_acl_program_decides_for_a_tree_with_a_symlink(self):
        with tempfile.TemporaryDirectory(prefix='release-acl-linux-') as tmp:
            root = Path(tmp)
            (root / 'file').write_text('fixture\n')
            (root / 'link').symlink_to('file')
            proc = subprocess.run([sys.executable, '-I', str(LIB), str(root), 'acl'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors='replace'))
            self.assertEqual(proc.stdout, b'ok\n')

    def test_symlink_eopnotsupp_is_absent_but_still_checks_both_names_and_nfs(self):
        with patch.object(release_verify.os, 'getxattr', side_effect=error(errno.EOPNOTSUPP), create=True) as get, \
             patch.object(release_verify.os, 'listxattr', return_value=[], create=True) as listing:
            self.assertFalse(release_verify.AclProbe._linux('/held/link', is_symlink=True, follow_symlinks=False))
        self.assertEqual([c.args[1] for c in get.call_args_list], list(release_verify.LINUX_ACL_XATTRS[:2]))
        for call in get.call_args_list:
            self.assertEqual(call.kwargs, {'follow_symlinks': False})
        listing.assert_called_once_with('/held/link', follow_symlinks=False)

    def test_eopnotsupp_on_non_symlink_never_means_clean(self):
        for target in (7, '/held/file'):
            with self.subTest(target=target), \
                 patch.object(release_verify.os, 'getxattr', side_effect=error(errno.EOPNOTSUPP), create=True), \
                 patch.object(release_verify.os, 'listxattr', create=True) as listing:
                with self.assertRaises(OSError) as caught:
                    release_verify.AclProbe._linux(target)
                self.assertEqual(caught.exception.errno, errno.EOPNOTSUPP)
                listing.assert_not_called()

    def test_symlink_other_errors_and_list_errors_are_not_absence(self):
        for code in (errno.EACCES, errno.EPERM, errno.EIO, errno.EINVAL, errno.ENOENT):
            with self.subTest(code=code), \
                 patch.object(release_verify.os, 'getxattr', side_effect=error(code), create=True), \
                 patch.object(release_verify.os, 'listxattr', create=True) as listing:
                with self.assertRaises(OSError) as caught:
                    release_verify.AclProbe._linux('/held/link', is_symlink=True, follow_symlinks=False)
                self.assertEqual(caught.exception.errno, code)
                listing.assert_not_called()
        with patch.object(release_verify.os, 'getxattr', side_effect=error(errno.EOPNOTSUPP), create=True), \
             patch.object(release_verify.os, 'listxattr', side_effect=error(errno.EOPNOTSUPP), create=True):
            with self.assertRaises(OSError) as caught:
                release_verify.AclProbe._linux('/held/link', is_symlink=True, follow_symlinks=False)
            self.assertEqual(caught.exception.errno, errno.EOPNOTSUPP)

    def test_present_posix_or_nfs_acl_is_not_suppressed(self):
        with patch.object(release_verify.os, 'getxattr', return_value=b'acl', create=True), \
             patch.object(release_verify.os, 'listxattr', create=True) as listing:
            self.assertTrue(release_verify.AclProbe._linux('/held/link', is_symlink=True, follow_symlinks=False))
            listing.assert_not_called()
        with patch.object(release_verify.os, 'getxattr', side_effect=error(errno.EOPNOTSUPP), create=True), \
             patch.object(release_verify.os, 'listxattr', return_value=['system.nfs4_acl'], create=True):
            self.assertTrue(release_verify.AclProbe._linux('/held/link', is_symlink=True, follow_symlinks=False))
        # r151-muse LOW-3: RichACL and file capabilities are refused too.
        for name in ('system.richacl', 'security.capability'):
            with patch.object(release_verify.os, 'getxattr', side_effect=error(errno.ENODATA), create=True), \
                 patch.object(release_verify.os, 'listxattr', return_value=['user.other', name], create=True):
                self.assertTrue(release_verify.AclProbe._linux('/held/file', follow_symlinks=False), name)

    def test_whole_acl_walk_does_not_classify_a_regular_file_as_a_symlink(self):
        with tempfile.TemporaryDirectory(prefix='release-acl-type-') as tmp:
            root = Path(tmp)
            (root / 'file').write_text('fixture\n')
            (root / 'link').symlink_to('file')
            def getxattr(target, _name, **_kwargs):
                raise error(errno.EOPNOTSUPP if isinstance(target, str) else errno.ENODATA)
            with patch.object(release_verify.AclProbe, '__init__', lambda self: setattr(self, 'libc', None)), \
                 patch.object(release_verify.os, 'getxattr', side_effect=getxattr, create=True), \
                 patch.object(release_verify.os, 'listxattr', return_value=[], create=True):
                with self.assertRaises(OSError) as caught:
                    release_verify.any_acl(str(root))
                self.assertEqual(caught.exception.errno, errno.EOPNOTSUPP)

    def test_whole_acl_walk_marks_only_symlinks_and_rechecks_identity(self):
        with tempfile.TemporaryDirectory(prefix='release-acl-test-') as tmp:
            root = Path(tmp)
            (root / 'file').write_text('fixture\n')
            (root / 'link').symlink_to('file')
            original_stat = os.stat

            def getxattr(target, _name, **_kwargs):
                code = errno.EOPNOTSUPP if isinstance(target, str) and os.path.islink(target) else errno.ENODATA
                raise error(code)

            def run(changed):
                seen = [0]
                def fake_stat(path, *args, **kwargs):
                    value = original_stat(path, *args, **kwargs)
                    if path == 'link' and kwargs.get('dir_fd') is not None:
                        seen[0] += 1
                        if changed and seen[0] == 2:
                            fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid',
                                      'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
                            copied = {key: getattr(value, key) for key in fields}
                            copied['st_ino'] += 1
                            return types.SimpleNamespace(**copied)
                    return value
                with patch.object(release_verify.AclProbe, '__init__', lambda self: setattr(self, 'libc', None)), \
                     patch.object(release_verify.os, 'getxattr', side_effect=getxattr, create=True), \
                     patch.object(release_verify.os, 'listxattr', return_value=[], create=True), \
                     patch.object(release_verify.os, 'stat', side_effect=fake_stat):
                    if changed:
                        with self.assertRaises(release_verify.Undecided):
                            release_verify.any_acl(str(root))
                    else:
                        self.assertFalse(release_verify.any_acl(str(root)))
                self.assertEqual(seen[0], 2)
            run(False)
            run(True)


if __name__ == '__main__':
    unittest.main()
