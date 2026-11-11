#!/usr/bin/env python3
"""Test the actual stage predicate, including a foreign UID without chown."""
from pathlib import Path
import stat
import sys
from types import SimpleNamespace

source = Path(sys.argv[1]).read_text()
start = source.index('\ndef safe_file(st):\n') + 1
end = source.index('\n\ntry:\n    parent_fd = os.open(parent, DIR)', start)
namespace = {'stat': stat, 'uid': 12345}
exec(compile(source[start:end], 'release.sh:safe_file', 'exec'), namespace)
safe_file = namespace['safe_file']


def check(name, mode, uid, links, expected):
    result = safe_file(SimpleNamespace(st_mode=mode, st_uid=uid, st_nlink=links))
    if result != expected:
        raise AssertionError(f'{name}: got {result!r}, expected {expected!r}')
    print(f'{name}: {result}')


check('owned regular', stat.S_IFREG | 0o600, 12345, 1, True)
check('foreign owner', stat.S_IFREG | 0o600, 12346, 1, False)
check('hardlink', stat.S_IFREG | 0o600, 12345, 2, False)
check('group write', stat.S_IFREG | 0o620, 12345, 1, False)
check('world write', stat.S_IFREG | 0o602, 12345, 1, False)
check('symlink', stat.S_IFLNK | 0o600, 12345, 1, False)
check('directory', stat.S_IFDIR | 0o600, 12345, 1, False)
