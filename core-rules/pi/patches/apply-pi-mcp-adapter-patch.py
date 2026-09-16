#!/usr/bin/env python3
"""Apply the qualified adapter patch without accepting version or source drift."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) != 2:
    sys.exit("usage: apply-pi-mcp-adapter-patch.py <pi-mcp-adapter-package-root>")
root = Path(sys.argv[1]).resolve(strict=True)
package = json.loads((root / "package.json").read_text())
if (package.get("name"), package.get("version")) != ("pi-mcp-adapter", "2.32.1"):
    sys.exit("unsupported package: require pi-mcp-adapter 2.32.1")
target = root / "tool-registrar.ts"
before = target.read_bytes()
digest = hashlib.sha256(before).hexdigest()
patched = "5b24e2935bd54dbf85b5959297c1aca919baad29542a097b3423412f8befb90e"
if digest == patched:
    print("already applied: pi-mcp-adapter structured content")
    sys.exit(0)
if digest != "4bc8f3c25743d6be3a7bbed5ec2425f80a66cbbbeda3d5922302c1961b67a170":
    sys.exit("source drift: refusing to patch tool-registrar.ts")
patch = Path(__file__).resolve().with_name("pi-mcp-adapter-2.32.1-structured-content.patch")
with tempfile.TemporaryDirectory(prefix=".trellis-patch-", dir=root) as scratch:
    pending = Path(scratch) / target.name
    pending.write_bytes(before)
    subprocess.run(["patch", "--fuzz=0", "-f", "-s", "-p1", "-i", str(patch)], cwd=scratch, check=True)
    if hashlib.sha256(pending.read_bytes()).hexdigest() != patched:
        sys.exit("patched digest mismatch: installed source unchanged")
    if target.read_bytes() != before:
        sys.exit("source changed during patch: refusing replacement")
    pending.chmod(target.stat().st_mode & 0o777)
    os.replace(pending, target)
print("applied: pi-mcp-adapter structured content; restart Pi")
