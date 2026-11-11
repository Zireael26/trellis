#!/usr/bin/env python3
"""Inject Darwin ACL API results into the publisher's actual no_acl body."""
import ctypes
import errno
from pathlib import Path
import sys
from unittest.mock import patch

source = Path(sys.argv[1]).read_text()
start = source.index('\ndef no_acl(fd):\n') + 1
end = source.index('\ndef directory(', start)


class Refusal(Exception):
    def __init__(self, message, code=4):
        super().__init__(message)
        self.code = code


def require(ok, message, code=4):
    if not ok:
        raise Refusal(message, code)


namespace = dict(ctypes=ctypes, errno=errno, sys=sys, Refusal=Refusal, require=require)
exec(compile(source[start:end], 'trellis-home.sh:no_acl', 'exec'), namespace)


class Call:
    def __init__(self, function):
        self.function = function

    def __call__(self, *args):
        return self.function(*args)


class Lib:
    def __init__(self, pointer, error, result, entry, freed):
        def get_acl(_fd, _kind):
            ctypes.set_errno(error)
            return pointer

        def get_entry(_acl, _which, result_pointer):
            result_pointer._obj.value = entry
            return result

        self.acl_get_fd_np = Call(get_acl)
        self.acl_get_entry = Call(get_entry)
        self.acl_free = Call(lambda _acl: freed)


def check(name, api, expected_code, expected_message):
    with patch.object(sys, 'platform', 'darwin'), patch.object(ctypes, 'CDLL', return_value=api):
        try:
            namespace['no_acl'](0)
        except Refusal as exc:
            actual = (exc.code, str(exc))
        else:
            actual = (0, '')
    expected = (expected_code, expected_message)
    if actual != expected:
        raise AssertionError(f'{name}: expected {expected!r}, got {actual!r}')
    print(f'{name}: {actual!r}')


check('null ENOENT', Lib(None, errno.ENOENT, 0, None, 0), 0, '')
check('null EIO', Lib(None, errno.EIO, 0, None, 0), 5, 'ACL inspection unavailable')
check('ACL entry', Lib(1, 0, 0, 1, 0), 4, 'ACL on pair entry')
check('entry error', Lib(1, 0, -1, None, 0), 5, 'ACL inspection failed')
check('unexpected entry result', Lib(1, 0, 1, None, 0), 5, 'ACL inspection failed')
check('unexpected result with entry', Lib(1, 0, 1, 1, 0), 5, 'ACL inspection failed')
check('null entry', Lib(1, 0, 0, None, 0), 5, 'ACL inspection failed')
check('free error', Lib(1, 0, 0, 1, -1), 5, 'ACL inspection failed')
