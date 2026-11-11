#!/usr/bin/env python3
"""Test fstat and fstatfs on a Linux O_PATH|O_NOFOLLOW symlink, unprivileged."""
import ctypes
import os
from pathlib import Path
import stat
import sys
import tempfile


def main():
    if sys.platform != 'linux' or os.geteuid() == 0 or not hasattr(os, 'O_PATH'):
        print('result: INCONCLUSIVE requires Linux, a non-root user and O_PATH')
        return 5
    with tempfile.TemporaryDirectory(prefix='trellis-symlink-statfs.') as tmp:
        root = Path(tmp)
        (root / 'file').write_text('fixture\n')
        (root / 'link').symlink_to('file')
        fd = os.open(root / 'link', os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            info = os.fstat(fd)
            if not stat.S_ISLNK(info.st_mode):
                print('fstat: FAIL O_PATH descriptor is not a symlink')
                return 1
            print(f'fstat: PASS symlink dev={info.st_dev} ino={info.st_ino}')
            libc = ctypes.CDLL(None, use_errno=True)
            libc.fstatfs.argtypes = [ctypes.c_int, ctypes.c_void_p]
            libc.fstatfs.restype = ctypes.c_int
            # Oversized aligned buffer avoids assuming the rest of struct
            # statfs; f_type is its first native long on Linux targets.
            buffer = (ctypes.c_long * 64)()
            if libc.fstatfs(fd, ctypes.byref(buffer)) != 0:
                err = ctypes.get_errno()
                print(f'fstatfs: FAIL errno={err} {os.strerror(err)}')
                return 1
            print(f'fstatfs: PASS f_type=0x{buffer[0] & 0xffffffff:08x} temp={root}')
            return 0
        finally:
            os.close(fd)


if __name__ == '__main__':
    sys.exit(main())
