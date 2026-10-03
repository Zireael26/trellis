#!/usr/bin/env python3
"""Assert the launcher preloads what every PRELOADED guard skips sourcing.

argv: <trellis-launcher.sh> <scripts/lib dir>. Exit 1 names the gaps.
"""
import glob
import os
import re
import sys

launcher, libdir = sys.argv[1:3]
block = re.search(r"^LIBRARIES = \((.*?)^\)", open(launcher).read(), re.S | re.M).group(1)
preloaded = {name.rsplit("/", 1)[-1] for name in re.findall(r'"([^"]+)"', block)}

GUARD = re.compile(r'if\s+\[\s+"\$\{TRELLIS_LIBS_PRELOADED:-\}"\s+!=\s+1\s+\]')
SOURCE = re.compile(r'^\s*(?:\.|source)\s+"[^"]*/([A-Za-z0-9._-]+\.sh)"', re.M)

missing = []
for path in sorted(glob.glob(os.path.join(libdir, "*.sh"))):
    text = open(path).read()
    guard = GUARD.search(text)
    if not guard:
        continue
    # the branch taken when the flag is absent is what the flag promises
    tail = text[guard.end():]
    body = tail[: tail.index("\nfi")] if "\nfi" in tail else tail
    for dep in SOURCE.findall(body):
        if dep not in preloaded and os.path.exists(os.path.join(libdir, dep)):
            missing.append("%s -> %s" % (os.path.basename(path), dep))

if missing:
    print("guarded dependencies absent from LIBRARIES: " + ", ".join(missing))
    raise SystemExit(1)
print("closure ok: %d preloaded libraries" % len(preloaded))
