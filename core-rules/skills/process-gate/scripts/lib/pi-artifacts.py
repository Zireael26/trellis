#!/usr/bin/env python3
"""Read-only Pi owner verification shared by check-bypass and doctor."""
import hashlib
import json
import os
import re
import stat
import sys

root, payload, *required = sys.argv[1:]
owner = json.load(sys.stdin)
pre_existing = owner.get("pre_existing", [])
owned = owner["artifacts"] + pre_existing
deferred = {e["path"] for e in pre_existing
            if e["kind"] == "symlink" and e.get("reason") == "project-authored-file"}


def declared_by_payload(relative):
    # A requirement holds only where the attachment's own release declares the
    # leaf: 1.3.18 stopped rendering .pi/hooks, older pinned releases still do.
    # An unreadable manifest keeps every requirement (fail closed).
    try:
        with open(os.path.join(payload, "core-rules/inheritance-manifest.json"), "rb") as source:
            links = json.load(source)["harnesses"]["pi"]["links"]
        return any(link.get("destination") == relative
                   or relative.startswith(link.get("destination_dir", "\0") + "/") for link in links)
    except (OSError, ValueError, KeyError, TypeError):
        return True


required = [relative for relative in required if declared_by_payload(relative)]
paths = sorted(set(required + [e["path"] for e in owned if e["path"].startswith(".pi/")]))


def safe_text(value):
    return isinstance(value, str) and value and all(
        ord(c) >= 32 and not 127 <= ord(c) <= 159 for c in value
    )


def safe_parents(relative):
    if not safe_text(relative) or any(p in ("", ".", "..") for p in relative.split("/")):
        raise ValueError("unsafe artifact path")
    parent = root
    for part in relative.split("/")[:-1]:
        parent = os.path.join(parent, part)
        if not stat.S_ISDIR(os.lstat(parent).st_mode):
            raise ValueError("redirected surface parent")


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        mode = os.fstat(source.fileno()).st_mode
        if not stat.S_ISREG(mode):
            raise ValueError("not a regular file")
        return source.read(), mode


def verify_payload(relative):
    recorded = os.path.join(payload, relative)
    if (not payload or os.path.realpath(payload) != payload
            or os.path.commonpath([payload, recorded]) != payload
            or os.path.realpath(recorded) != recorded):
        raise ValueError("payload file escapes recorded runtime")
    content, source_mode = read_regular(recorded)
    # release.json uses Git blob IDs, not a second owner/hash schema. Runtime
    # JSON data has the same authenticity requirement as the linked entry.
    record, _ = read_regular(os.path.join(os.path.dirname(payload), "release.json"))
    rows = [e for e in json.loads(record)["tree"] if e["path"] == relative]
    blob = ("blob %d\0" % len(content)).encode() + content
    oid = hashlib.sha1(blob, usedforsecurity=False).hexdigest()  # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
    git_mode = "100755" if source_mode & 0o111 else "100644"
    if not content or len(rows) != 1 or (rows[0]["mode"], rows[0]["oid"]) != (git_mode, oid):
        raise ValueError("payload content hash or mode mismatch")


def verify(relative):
    safe_parents(relative)
    matches = [e for e in owned if e["path"] == relative]
    if len(matches) != 1:
        raise ValueError("missing or ambiguous artifact")
    entry = matches[0]
    path = os.path.join(root, relative)
    mode = os.lstat(path).st_mode
    kind = entry["kind"]
    if kind == "parent":
        # Require owner rwx, no setuid/sticky or group/world write. Setgid only
        # controls group inheritance; 0700, 0755 and setgid variants are safe.
        if not stat.S_ISDIR(mode) or mode & 0o700 != 0o700 or mode & 0o5022:
            raise ValueError("parent is not a real directory with safe mode")
        return  # Never feed a literal directory to the leaf-file validator.
    if kind == "symlink":
        target = entry.get("target")
        if not stat.S_ISLNK(mode) or not safe_text(target) or os.readlink(path) != target:
            raise ValueError("symlink differs from owner")
        runtime = os.path.join(root, ".trellis/runtime")
        recorded = os.path.normpath(os.path.join(os.path.dirname(path), target))
        if recorded.startswith(runtime + os.sep):
            recorded = os.path.join(payload, os.path.relpath(recorded, runtime))
        if (not payload or os.path.realpath(payload) != payload
                or os.path.commonpath([payload, recorded]) != payload
                or os.path.realpath(recorded) != recorded or os.path.realpath(path) != recorded):
            raise ValueError("symlink escapes recorded payload file")
        # Symlink owners pin targets rather than content hashes.
        verify_payload(os.path.relpath(recorded, payload))
    elif kind == "file":
        digest = entry.get("sha256", "")
        if not stat.S_ISREG(mode) or not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError("invalid file hash baseline")
        content, _ = read_regular(path)
        if not content or hashlib.sha256(content).hexdigest() != digest:
            raise ValueError("file content hash mismatch")
    else:
        raise ValueError("unsupported owner kind")


failed = False
for relative in paths:
    try:
        verify(relative)
    except (OSError, ValueError, KeyError, TypeError) as error:
        context = (f"deferred to project file — {error}; move the project file aside, then detach and attach again"
                   if relative in deferred else str(error))
        print(f"{relative}: native Pi hook artifact missing or does not match owner — hooks not registered ({context})")
        failed = True
# trellis.ts is the sole manifest-linked production module. Its shared rules
# are loaded at runtime from the immutable payload, not linked under .pi or
# statically imported as a second module. Removing their owner entries (there
# normally are none) must not turn an unusable delivery into a healthy one.
# Historical dispatcher-linked releases keep their pinned delivery contract.
if ".pi/extensions/trellis.ts" in paths and not declared_by_payload(".pi/hooks/dispatch.sh"):
    for relative in ("core-rules/hooks/rules/destructive.json", "core-rules/hooks/rules/reread.json"):
        try:
            verify_payload(relative)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f".trellis/runtime/{relative}: native Pi hook artifact missing or does not match owner — hooks not registered ({error})")
            failed = True
sys.exit(1 if failed else 0)
