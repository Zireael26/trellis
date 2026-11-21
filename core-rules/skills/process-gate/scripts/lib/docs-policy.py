"""Inspect immutable Git inputs for check-tests.sh's docs-only policy.

Keep the policy's existing POSIX ERE syntax in the checker. This helper reads
bytes that Bash cannot safely represent (Git framing, blobs, and strict JSON).
"""

import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path


class Refused(ValueError):
    pass


OID = re.compile(rb"[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")
SAFE_PATH = re.compile(rb"[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)*\Z")


def git(*args, cwd=None):
    result = subprocess.run(
        ("git", "--no-replace-objects", "--literal-pathspecs", *args),
        cwd=cwd, env={**os.environ, "GIT_NO_LAZY_FETCH": "1"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode or result.stderr:
        raise Refused(f"cannot verify Git {next(arg for arg in args if arg != '-c' and '=' not in arg)}")
    return result.stdout


def records(data):
    if not data:
        return []
    parts = data.split(b"\0")
    if parts.pop() or not all(parts):
        raise Refused("invalid NUL-framed Git output")
    return parts


def oid_line(data):
    if not data.endswith(b"\n") or not OID.fullmatch(data[:-1]):
        raise Refused("invalid Git object ID")
    return data[:-1]


def require_physical_root(root):
    top = git("rev-parse", "--show-toplevel", cwd=root).removesuffix(b"\n")
    if Path(os.fsdecode(top)).resolve(strict=True) != root:
        raise Refused("Tests is not running at the physical worktree root (or a submodule points elsewhere)")


def reject_altered_history():
    if git("for-each-ref", "--format=%(refname)", "refs/replace/"):
        raise Refused("replace refs make the range ambiguous")
    grafts = Path(os.fsdecode(git("rev-parse", "--git-path", "info/grafts").removesuffix(b"\n")))
    # A broken symlink, unexpected type or unreadable graft file is ambiguous too.
    if os.path.lexists(grafts) and grafts.read_bytes():
        raise Refused("grafts make the range ambiguous")


def tree_blob(commit, path):
    """Exact path lookup; a non-tree ancestor is not true absence."""
    parts = path.encode("ascii").split(b"/")
    for i in range(1, len(parts) + 1):
        name = b"/".join(parts[:i])
        entries = records(git("ls-tree", "--full-tree", "-z", commit, "--", name))
        if not entries:
            return None
        if len(entries) != 1:
            raise Refused(f"ambiguous base path {path}")
        meta, sep, actual = entries[0].partition(b"\t")
        mode, kind, oid = meta.split(b" ")
        if not sep or actual != name or not OID.fullmatch(oid):
            raise Refused(f"invalid base entry for {path}")
        if i < len(parts):
            if (mode, kind) != (b"040000", b"tree"):
                raise Refused(f"non-directory ancestor of {path}")
        elif kind != b"blob" or mode not in (b"100644", b"100755"):
            raise Refused(f"{path} is not a regular file at the base")
    return mode, oid


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refused("duplicate JSON key")
        result[key] = value
    return result


def invalid_constant(_value):
    raise Refused("non-JSON number")


def read_base(base, policies):
    manifest = tree_blob(base, ".trellis.json")
    if manifest:
        try:
            obj = json.loads(git("cat-file", "blob", manifest[1]).decode("utf-8"),
                             object_pairs_hook=unique_object, parse_constant=invalid_constant)
            if not isinstance(obj, dict) or not isinstance(gate := obj.get("gate", {}), dict):
                raise Refused("expected a project JSON object with an optional gate object")
            enabled = gate.get("docs_only_tests", True)
            if type(enabled) is not bool:
                raise Refused("gate.docs_only_tests must be boolean")
        except (ValueError, RecursionError) as exc:
            raise Refused(f"invalid base .trellis.json: {exc}") from exc
        if not enabled:
            raise Refused("base .trellis.json disables gate.docs_only_tests")
    found = None
    for path in policies:
        item = tree_blob(base, path)
        if item is None:
            continue
        mode, oid = item
        if mode != b"100644":
            raise Refused(f"policy {path} is not mode 100644 at the base")
        if found is not None and found != oid:
            raise Refused("docs-only policies differ at the base")
        found = oid
    if found is None:
        return 3
    text_blob(found)
    print(found.decode("ascii"))
    return 0


def text_blob(oid):
    try:
        text = git("cat-file", "blob", oid).decode("utf-8")
    except (UnicodeError, Refused) as exc:
        raise Refused("unreadable or binary blob") from exc
    if any(unicodedata.category(c) == "Cc" and c not in "\t\r\n" for c in text):
        raise Refused("binary blob")
    if text.lstrip("\ufeff").startswith(("version https://git-lfs", "version https://hawser.github.com/spec/")):
        raise Refused("LFS blob")


def clean_checkout(root, head):
    if oid_line(git("rev-parse", "--verify", "HEAD^{commit}", cwd=root)) != head:
        raise Refused("checkout HEAD differs from gated head (or a submodule is out of sync)")
    # Ignore repository settings that can hide dirty files and submodules.
    safe = ("-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.ignoreStat=false",
            "-c", "core.fileMode=true", "-c", "core.symlinks=true", "-c", "core.checkStat=default",
            "-c", "core.trustctime=true")
    for entry in records(git(*safe, "ls-files", "-v", "--stage", "-z", cwd=root)):
        meta, sep, path = entry.partition(b"\t")
        flag, mode, oid, stage = meta.split(b" ")
        if not sep or flag != b"H" or stage != b"0" or not OID.fullmatch(oid):
            raise Refused("checkout index has hidden, unmerged or unreadable entries")
        if mode == b"160000":
            sub = root / os.fsdecode(path)
            if sub != sub.resolve(strict=True) or root not in sub.parents or not (sub / ".git").exists():
                raise Refused("checkout has an unavailable submodule")
            require_physical_root(sub)
            clean_checkout(sub, oid)
    if git(*safe, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", cwd=root):
        raise Refused("checkout index or worktree is dirty")


def changed_paths(parent, commit, checked):
    entries = records(git("diff-tree", "-r", "-z", "--raw", "--no-abbrev", "--no-renames",
                          "--no-commit-id", "--no-ext-diff", "--ignore-submodules=none", parent, commit, "--"))
    if len(entries) % 2:
        raise Refused("truncated raw diff entry")
    paths = set()
    for meta, path in zip(entries[::2], entries[1::2]):
        src, dst, old, new, status = meta.split(b" ")
        if not SAFE_PATH.fullmatch(path) or any(p.endswith(b".") for p in path.split(b"/")):
            raise Refused(f"{path!r}: not an ordinary path")
        if path in paths:
            raise Refused(f"{path!r}: duplicate raw diff entry")
        paths.add(path)
        modes = {b"A": (b":000000", b"100644"), b"M": (b":100644", b"100644"), b"D": (b":100644", b"000000")}
        if modes.get(status) != (src, dst):
            raise Refused(f"{path!r}: unsupported change type or mode {src!r} -> {dst!r}")
        for mode, oid in ((src, old), (dst, new)):
            if not OID.fullmatch(oid) or len(oid) != len(commit) or (not oid.strip(b"0")) != (mode.endswith(b"000000")):
                raise Refused(f"{path!r}: invalid blob ID")
            if oid.strip(b"0") and oid not in checked:
                try:
                    text_blob(oid)
                except Refused as exc:
                    raise Refused(f"{path!r}: {exc}") from exc
                checked.add(oid)
    return paths


def reject_case_aliases(commits, paths):
    spellings = {}
    for path in paths:
        parts = path.decode("ascii").split("/")
        for i in range(1, len(parts) + 1):
            prefix = "/".join(parts[:i])
            if spellings.setdefault(prefix.lower(), prefix) != prefix:
                raise Refused(f"{prefix}: case-fold collision in changed paths")
    # Include unchanged siblings and directory components at every tree in
    # the range. A case-only rename still collides across the history above.
    for commit in commits:
        for entry in records(git("ls-tree", "-r", "-t", "--name-only", "-z", commit)):
            name = entry.decode("utf-8", errors="surrogateescape")
            other = spellings.get(name.casefold())
            if other is not None and other != name:
                raise Refused(f"{other}: case-fold alias in Git tree")


def history(base, head, scope):
    root = Path.cwd()
    require_physical_root(root)
    if scope == "push":
        clean_checkout(root, head)
    # Check the real chain down to base; truncated shallow traversal, a
    # missing parent, an unrelated base or a merge cannot satisfy this walk.
    commits = [head]
    current = head
    touched, checked = set(), set()
    while current != base:
        header, sep, _body = git("cat-file", "commit", current).partition(b"\n\n")
        parents = [line[7:] for line in header.split(b"\n") if line.startswith(b"parent ")]
        if not sep or len(parents) != 1 or not OID.fullmatch(parents[0]) or len(parents[0]) != len(head):
            raise Refused("range is not a readable linear history from an ancestor (or contains a merge)")
        parent = parents[0]
        if parent in commits:
            raise Refused("cycle in Git commit chain")
        touched.update(changed_paths(parent, current, checked))
        commits.append(parent)
        current = parent
    net = changed_paths(base, head, checked)
    if not net or not net <= touched:
        raise Refused("no net changed paths or incomplete history")
    reject_case_aliases(commits, touched)
    print(len(net))
    for path in sorted(touched):
        print(path.decode("ascii"))


def main():
    action, base, *args = sys.argv[1:]
    base = base.encode("ascii")
    if not OID.fullmatch(base):
        raise Refused("unresolved range base")
    reject_altered_history()
    if action == "base":
        return read_base(base, args)
    head, scope = args
    head = head.encode("ascii")
    if not OID.fullmatch(head) or len(head) != len(base):
        raise Refused("unresolved range head")
    history(base, head, scope)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(error)
        sys.exit(1)
