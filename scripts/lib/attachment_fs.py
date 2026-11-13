"""Filesystem primitives shared by the attachment programs.

The attach publisher (`_attachment_commit_program` in attachment.sh) and the
native detach program load this file by absolute path from the sealed payload
(never from sys.path) and take its names into their globals. Each program keeps
its own `checkpoint` crash-test seam in its own text.
"""
import base64
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import random
import signal
import stat
import string
import sys

# T39: HFS+ cannot hard-link a symlink (ENOTSUP). Only for that, a symlink is
# published by rename_exclusive, which keeps the staged inode and never
# replaces an existing name; every other link failure still refuses.
def link_unsupported(error):
    return error.errno in (errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", errno.ENOTSUP))


# Exit statuses match the shell publish path they replace: 1 I/O, 2 shape,
# 3 conflict. FAULT is the pre-existing numeric ATTACHMENT_FAULT_PHASE stop.
FAULT = 75
ORPHANED = 76
REMOVE_PREFIX = ".trellis-attachment-remove-"


class Stop(Exception):
    def __init__(self, status):
        Exception.__init__(self, status)
        self.status = status


def refuse(status=3):
    raise Stop(status)


def orphaned():
    # Our parent is no longer the shell recorded as the lock owner, so a
    # recovery may already own the worktree: stop without another write.
    sys.stderr.write("trellis attachment: commit stopped: the transaction lock owner is gone\n")
    sys.stderr.flush()
    os._exit(ORPHANED)


def has_controls(value):
    return any(ord(char) < 32 or ord(char) == 127 for char in value)


def has_jq_controls(value):
    # Registry schema paths use jq's [[:cntrl:]], including the C1 range.
    # Keep this distinct from the attachment shell's C0/DEL predicate.
    return any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)


def valid_absolute(value):
    if not value.startswith("/") or value == "/" or value.endswith("/"):
        return False
    if "//" in value or "/./" in value or "/../" in value:
        return False
    if value.endswith("/.") or value.endswith("/.."):
        return False
    return not has_controls(value)


def lstat_or_none(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def no_symlink_components(value):
    if not valid_absolute(value):
        return False
    parts = value[1:].split("/")
    current = ""
    for index, part in enumerate(parts):
        if not part:
            return False
        current += "/" + part
        info = lstat_or_none(current)
        if info is None or stat.S_ISLNK(info.st_mode):
            return False
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            return False
    return True


def canonical_dir(value):
    # Pins the working directory, like the shell's `cd` + `pwd -P`.
    if not no_symlink_components(value):
        return False
    info = lstat_or_none(value)
    if info is None or not stat.S_ISDIR(info.st_mode):
        return False
    try:
        os.chdir(value)
        return os.getcwd() == value
    except OSError:
        return False


def canonical_file(value):
    if not no_symlink_components(value):
        return False
    info = lstat_or_none(value)
    if info is None or not stat.S_ISREG(info.st_mode):
        return False
    parent, base = os.path.split(value)
    try:
        os.chdir(parent or "/")
        actual = os.getcwd()
    except OSError:
        return False
    return (("/" + base) if actual == "/" else (actual + "/" + base)) == value


def identity(path):
    info = lstat_or_none(path)
    if info is None:
        return ""
    return "%d:%d" % (info.st_dev, info.st_ino)


def is_file(path):
    info = lstat_or_none(path)
    return info is not None and stat.S_ISREG(info.st_mode)


def is_dir(path):
    info = lstat_or_none(path)
    return info is not None and stat.S_ISDIR(info.st_mode)


def is_link(path):
    info = lstat_or_none(path)
    return info is not None and stat.S_ISLNK(info.st_mode)


def exists(path):
    return lstat_or_none(path) is not None


def rename_exclusive(source, destination):
    # rename(2) silently replaces an empty directory, so a directory raced into
    # the destination would be lost; refuse it instead, as the shell's mv did.
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        result = libc.renamex_np(source.encode(), destination.encode(), ctypes.c_uint(0x4))  # RENAME_EXCL
    else:
        result = libc.renameat2(-100, source.encode(), -100, destination.encode(), ctypes.c_uint(0x1))  # AT_FDCWD, RENAME_NOREPLACE
    if result != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            refuse(3)
        raise OSError(code, os.strerror(code), destination)


def hold_transaction_lock(holder, owner_pid):
    # The transaction lock is recorded against the shell that started us, and
    # a SIGKILL of that shell does not stop us. Hold a flock in the lock's
    # holder for our whole life: recovery reclaims the lock only once it is
    # free. A shell that died before we took it may already have been
    # reclaimed, so stop before any mutation if our parent is not that shell.
    if not canonical_dir(holder):
        refuse(3)
    fd = os.open(holder + "/publisher.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        refuse(3)
    if os.getppid() != owner_pid:
        orphaned()
    return fd


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_text(value):
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()


def mode_matches(path, expected):
    info = lstat_or_none(path)
    return info is not None and format(stat.S_IMODE(info.st_mode), "o") == expected[1:]


def identity_matches(path, expected, kind, dir_fd=None):
    if not expected:
        return False
    try:
        info = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return False
    if kind == "file" and not stat.S_ISREG(info.st_mode):
        return False
    if kind == "symlink" and not stat.S_ISLNK(info.st_mode):
        return False
    if kind in ("directory", "parent") and not stat.S_ISDIR(info.st_mode):
        return False
    return "%d:%d" % (info.st_dev, info.st_ino) == expected


def open_fresh_dir(name):
    # Pin a directory we just created before changing it: a symlink swapped in
    # after the mkdir fails O_NOFOLLOW, and the pinned inode must still be the
    # entry by that name.
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        refuse(3)
    if identity(name) != fd_identity(fd):
        os.close(fd)
        refuse(3)
    return fd


def fd_identity(fd):
    info = os.fstat(fd)
    return "%d:%d" % (info.st_dev, info.st_ino)


def path_exact(path, artifact):
    kind = artifact["kind"]
    if kind == "file":
        if not is_file(path) or sha256_file(path) != artifact["sha256"]:
            return False
        return "mode" not in artifact or mode_matches(path, artifact["mode"])
    if kind == "symlink":
        return is_link(path) and os.readlink(path) == artifact["target"]
    if kind == "directory":
        return is_dir(path) and not os.listdir(path)
    if kind == "parent":
        return is_dir(path)
    return False


def path_exact_pinned(name, artifact):
    # `name` is relative to the pinned working directory.
    here = os.getcwd()
    return canonical_dir(here) and path_exact("./" + name, artifact)


def parent_safe(root, relative):
    parent = os.path.dirname(relative)
    if not parent:
        return True
    current = root
    for part in parent.split("/"):
        if not part:
            return False
        current += "/" + part
        if not is_dir(current):
            return False
    return True


def replace_before_matches(path, artifact):
    replace = artifact["replace"]
    return (is_file(path) and sha256_file(path) == replace["before_sha256"]
            and mode_matches(path, replace["before_mode"]))


def claim_layout(path, nonce):
    return os.path.dirname(path) + "/" + REMOVE_PREFIX + sha256_text(nonce + ":" + path)


def claim_namespace_valid(path, removal):
    parent = os.path.dirname(path)
    expected = None
    if removal is not None and os.path.dirname(removal["path"]) == parent:
        expected = claim_layout(removal["path"], removal["nonce"])
    try:
        entries = os.listdir(parent)
    except OSError:
        return False
    return all(parent + "/" + entry == expected
               for entry in entries if entry.startswith(REMOVE_PREFIX))


def git_common_dirs(roots):
    # _attachment_git_common_dir for every root, the same git command, run
    # a few at a time. None where git fails or the directory does not resolve.
    import shutil
    import subprocess
    git = shutil.which("git")
    results = {}
    if git is None:
        return results
    pending = list(roots)
    running = []
    while pending or running:
        while pending and len(running) < 8:
            root = pending.pop(0)
            child = subprocess.Popen([git, "-C", root, "rev-parse", "--git-common-dir"],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
            running.append((root, child))
        root, child = running.pop(0)
        output = child.communicate()[0]
        if child.returncode != 0:
            results[root] = None
            continue
        common = os.fsdecode(output).rstrip("\n")
        if not common:
            results[root] = None
            continue
        target = common if common.startswith("/") else root + "/" + common
        here = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.chdir(target)
            results[root] = os.getcwd()
        except OSError:
            results[root] = None
        finally:
            os.fchdir(here)
            os.close(here)
    return results
