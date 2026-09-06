#!/usr/bin/env python3
"""Emit a fixture's Git blob manifest without one Git/jq process per file.

Only test fixture construction uses this helper. Production verification still
independently validates the resulting modes, paths and object identities.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def entries(root):
    paths = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if stat.S_ISREG(mode) or stat.S_ISLNK(mode):
                paths.append(path)
    for path in sorted(paths, key=lambda item: os.fsencode(item.relative_to(root))):
        if path.is_symlink():
            data = os.fsencode(os.readlink(path))
            mode = "120000"
        else:
            data = path.read_bytes()
            mode = "100755" if os.access(path, os.X_OK) else "100644"
        oid = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
        yield {"path": str(path.relative_to(root)), "mode": mode, "oid": oid}


if __name__ == "__main__":
    for entry in entries(Path(sys.argv[1])):
        print(json.dumps(entry, separators=(",", ":")))
