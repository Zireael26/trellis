"""Full release inventory audit in one process (spec 074 T5).

    release_verify.py RELEASE_DIR SKIP_WRITABLE
    release_verify.py RELEASE_DIR acl

release_store_verify_path_body runs this after its own release.json, version,
tag and containment checks, in place of its per-entry shell pass. It proves
everything that pass proves, in the same order and with the same findings:

  - release.json and payload are the only top-level entries;
  - every manifest path is unique, has no symlinked parent, exists, and has
    the recorded type, executable bit, and Git blob ID (content for a file,
    target bytes for a link); every link target stays inside the payload;
  - the payload holds exactly the manifest paths and their parent directories,
    and nothing that is not a file, link or directory;
  - unless SKIP_WRITABLE is 1, no file, directory or release.json carries a
    write bit or an ACL.

The acl form answers only one question, for release_store_release_has_no_acl:
does the release directory or anything under it carry an ACL? It exits 0 with
"ok" for none and 4 for one, under the same no-verdict rule as the audit.

Every read goes through directory descriptors opened without following links,
and each file is hashed from the descriptor whose type and mode were checked.

Exit 0 with "ok" on stdout: verified. Exit 4: refused, with the same
"trellis release:" findings the shell pass prints, on stderr; findings are
held until the verdict, so an undecided run prints none. Anything else,
including an exit 0 without "ok", decides nothing: the caller runs the shell
pass, whose verdict stands. So an unexpected error never passes a release.

Python 3.6 or later, stdlib only.
"""
import ctypes
import errno
import hashlib
import json
import os
import stat
import sys

DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
WRITE_BITS = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
# ls prints "-" in all three execute columns only when no x, setuid, setgid
# or sticky bit is set; release_store_mode_for_permissions reads those columns.
EXEC_COLUMNS = 0o7111
LINUX_ACL_XATTRS = ("system.posix_acl_access", "system.posix_acl_default", "system.nfs4_acl")


class Undecided(Exception):
    """A condition this program does not judge; the shell pass decides."""


def unsafe_path(path):
    # release_store_path_is_safe
    return (path == "" or path.startswith("/") or path.endswith("/") or "//" in path
            or any(part in (".", "..") for part in path.split("/"))
            or any(c in path for c in "\t\n\r"))


def link_at(payload_fd, candidate):
    """The target of payload/<candidate> when it is a symlink, else None."""
    parts = candidate.split("/")
    fd, opened = payload_fd, []
    try:
        for part in parts[:-1]:
            try:
                fd = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            except OSError as error:
                if error.errno in (errno.ENOENT, errno.ENOTDIR):
                    return None
                if error.errno == errno.ELOOP:
                    # Resolved components are never links; the tree moved.
                    raise Undecided()
                raise
            opened.append(fd)
        try:
            info = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        except (FileNotFoundError, NotADirectoryError):
            return None
        if not stat.S_ISLNK(info.st_mode):
            return None
        return os.readlink(parts[-1], dir_fd=fd)
    finally:
        for fd in opened:
            os.close(fd)


def unsafe_link_target(link_path, target, payload_fd):
    # release_store_symlink_target_is_safe: intermediate links are expanded at
    # their parent, so a chain cannot leave the payload through another link.
    if unsafe_path(link_path) or target == "" or target.startswith("/") or "//" in target:
        return True
    if any(c in target for c in "\t\n\r"):
        return True
    rest = ((link_path.rsplit("/", 1)[0] + "/" + target) if "/" in link_path else target).split("/")
    resolved = []
    followed = 0
    while rest:
        component = rest.pop(0)
        if component in ("", "."):
            continue
        if component == "..":
            if not resolved:
                return True
            resolved.pop()
            continue
        candidate = "/".join(resolved + [component])
        hop = link_at(payload_fd, candidate)
        if hop is None:
            resolved.append(component)
            continue
        followed += 1
        if followed > 40 or hop == "" or hop.startswith("/") or "//" in hop:
            return True
        if any(c in hop for c in "\t\n\r"):
            return True
        rest = hop.split("/") + rest
    return False


def blob_oid(data):
    # Git blob object ID compatibility, not a cryptographic signature.
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()  # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1


def open_directory(path):
    """Open a canonical absolute directory without following any component."""
    parts = path.split("/")[1:]
    if not path.startswith("/") or path == "/" or any(p in ("", ".", "..") for p in parts):
        raise Undecided()
    fd = os.open("/", DIRECTORY_FLAGS)
    try:
        for part in parts:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
    except BaseException:
        os.close(fd)
        raise
    return fd


class AclProbe:
    """Whether an entry carries an ACL: what ls -le shows on macOS (where an
    "@" can hide the "+" of ls -l) and what GNU ls marks with "+".

    The audit asks through the descriptor it already holds (has_acl_fd), so
    the answer is about the inode it checked and read. The acl form, which
    stands in for a pathname listing, asks by path without following a link
    (has_acl_path)."""

    def __init__(self):
        self.libc = None
        if sys.platform == "darwin":
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            libc.acl_get_fd_np.restype = ctypes.c_void_p
            libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            libc.acl_get_link_np.restype = ctypes.c_void_p
            libc.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
            libc.acl_get_entry.restype = ctypes.c_int
            libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
            libc.acl_free.argtypes = [ctypes.c_void_p]
            self.libc = libc
        elif not sys.platform.startswith("linux"):
            raise Undecided()

    def _darwin(self, getter, target):
        ctypes.set_errno(0)
        acl = getter(target, 0x100)  # ACL_TYPE_EXTENDED
        if not acl:
            if ctypes.get_errno() == errno.ENOENT:
                return False
            raise Undecided()
        try:
            entry = ctypes.c_void_p()
            ctypes.set_errno(0)
            if self.libc.acl_get_entry(acl, 0, ctypes.byref(entry)) == 0:  # ACL_FIRST_ENTRY
                return True
            # Only a NULL getter with ENOENT proves absence. An entry error
            # cannot certify that an ACL is empty or that inspection worked.
            raise Undecided()
        finally:
            if self.libc.acl_free(acl) != 0:
                raise Undecided()

    @staticmethod
    def _linux(target, is_symlink=False, **kwargs):
        # POSIX ACLs cannot be attached to Linux symlinks; their no-follow
        # lookup may report EOPNOTSUPP instead of ENODATA. This exception is
        # only for those two lookups on a known symlink, never regular entries
        # or the NFSv4 xattr enumeration below.
        for name in LINUX_ACL_XATTRS[:2]:
            try:
                os.getxattr(target, name, **kwargs)
            except OSError as error:
                if error.errno == errno.ENODATA or (is_symlink and error.errno == errno.EOPNOTSUPP):
                    continue
                raise
            return True
        # Keep the existing NFSv4 ACL detection. A failed enumeration is not
        # evidence of absence, even on a filesystem without xattr support.
        names = os.listxattr(target, **kwargs)
        return 'system.nfs4_acl' in names

    def has_acl_fd(self, fd):
        if self.libc is not None:
            return self._darwin(self.libc.acl_get_fd_np, fd)
        return self._linux(fd)

    def has_acl_path(self, path, is_symlink=False):
        if self.libc is not None:
            return self._darwin(self.libc.acl_get_link_np, os.fsencode(path))
        return self._linux(path, is_symlink=is_symlink, follow_symlinks=False)


class Parents:
    """Descriptor stack for the directory of the current manifest row."""

    def __init__(self, payload_fd, payload):
        self.payload_fd = payload_fd
        self.payload = payload
        self.parts = []
        self.fds = []
        # (ino, dev) of each directory as first opened; a reopen in a later
        # pass must find the same directory.
        self.pinned = {}

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.parts, self.fds = [], []

    def open(self, parts):
        """The descriptor of payload/<parts>, or ("link", component) when a
        component is a symlink, or ("missing", None) when it is absent or not
        a directory."""
        keep = 0
        while keep < len(self.parts) and keep < len(parts) and self.parts[keep] == parts[keep]:
            keep += 1
        for fd in self.fds[keep:]:
            os.close(fd)
        self.parts, self.fds = self.parts[:keep], self.fds[:keep]
        for part in parts[keep:]:
            parent = self.fds[-1] if self.fds else self.payload_fd
            try:
                fd = os.open(part, DIRECTORY_FLAGS, dir_fd=parent)
            except OSError as error:
                if error.errno not in (errno.ELOOP, errno.ENOTDIR, errno.ENOENT):
                    raise
                try:
                    info = os.stat(part, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    return "missing", None
                if stat.S_ISLNK(info.st_mode):
                    return "link", self.payload + "/" + "/".join(self.parts + [part])
                return "missing", None
            self.parts.append(part)
            self.fds.append(fd)
            info = os.fstat(fd)
            pin = self.pinned.setdefault(tuple(self.parts), (info.st_ino, info.st_dev))
            if pin != (info.st_ino, info.st_dev):
                raise Undecided()
        return "ok", (self.fds[-1] if self.fds else self.payload_fd)


def fingerprint(info):
    return (info.st_ino, info.st_dev, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_file(name, dir_fd, expected, acl):
    """Content of a regular file, and whether it has an ACL (None when acl is
    None), read through one descriptor. The descriptor must match the lstat
    the type and mode checks used and must not change while it is read."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        before = os.fstat(fd)
        if fingerprint(before) != fingerprint(expected):
            raise Undecided()
        chunks = []
        while True:
            chunk = os.read(fd, 1048576)
            if not chunk:
                break
            chunks.append(chunk)
        has_acl = None if acl is None else acl.has_acl_fd(fd)
        if fingerprint(os.fstat(fd)) != fingerprint(before):
            raise Undecided()
    finally:
        os.close(fd)
    return b"".join(chunks), has_acl


def audit(release_dir, skip_writable):
    findings = []

    def refuse(message):
        findings.append("trellis release: " + message)

    acl = None if skip_writable else AclProbe()
    release_fd = open_directory(release_dir)
    try:
        fd = os.open("release.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=release_fd)
        try:
            record_info = os.fstat(fd)
            if not stat.S_ISREG(record_info.st_mode):
                raise Undecided()
            raw = b""
            while True:
                chunk = os.read(fd, 1048576)
                if not chunk:
                    break
                raw += chunk
            record_acl = None if acl is None else acl.has_acl_fd(fd)
            if fingerprint(os.fstat(fd)) != fingerprint(record_info):
                raise Undecided()
        finally:
            os.close(fd)
        rows = json.loads(raw.decode("utf-8"))["tree"]
        if not isinstance(rows, list) or not rows:
            raise Undecided()
        for row in rows:
            if (not isinstance(row, dict) or not all(isinstance(row.get(k), str) for k in ("path", "mode", "oid"))):
                raise Undecided()
            # The shell pass reads paths through jq, whose @tsv doubles a
            # backslash and whose decoder replaces a lone surrogate escape, so
            # it names another file than this one would; leave those to it.
            if "\\" in row["path"]:
                raise Undecided()
            row["path"].encode("utf-8")

        paths = [row["path"] for row in rows]
        if len(set(paths)) != len(paths):
            refuse("duplicate manifest path in %s/release.json" % release_dir)
        manifest_dirs = set()
        for path in paths:
            while "/" in path:
                path = path.rsplit("/", 1)[0]
                manifest_dirs.add(path)

        for name in sorted(os.listdir(release_fd)):
            if name not in ("release.json", "payload"):
                refuse("unexpected release top-level entry: %s" % name)
                break

        payload = release_dir + "/payload"
        payload_fd = os.open("payload", DIRECTORY_FLAGS, dir_fd=release_fd)
        parents = Parents(payload_fd, payload)
        try:
            # Pass 1, release_store_verify_path_body's first manifest loop:
            # safe path, no symlinked parent, present, type matches the mode.
            tree_ok = True
            infos = []
            for row in rows:
                mode, path = row["mode"], row["path"]
                if unsafe_path(path):
                    refuse("unsafe manifest path: %s" % path)
                    tree_ok = False
                    break
                parts = path.split("/")
                state, value = parents.open(parts[:-1])
                if state == "link":
                    refuse("symlinked release payload parent for %s: %s" % (path, value))
                    tree_ok = False
                    break
                info = None
                if state == "ok":
                    try:
                        info = os.stat(parts[-1], dir_fd=value, follow_symlinks=False)
                    except FileNotFoundError:
                        info = None
                if info is None:
                    refuse("missing release content: %s" % path)
                    tree_ok = False
                    break
                if mode == "120000":
                    if stat.S_ISLNK(info.st_mode):
                        pass
                    elif stat.S_ISREG(info.st_mode):
                        found = "100755" if info.st_mode & EXEC_COLUMNS else "100644"
                        refuse("wrong mode for %s: expected %s, found %s" % (path, mode, found))
                        tree_ok = False
                        break
                    else:
                        refuse("wrong release content type: %s" % path)
                        tree_ok = False
                        break
                elif mode in ("100644", "100755"):
                    if stat.S_ISLNK(info.st_mode):
                        refuse("wrong mode for %s: expected %s, found 120000" % (path, mode))
                        tree_ok = False
                        break
                    if not stat.S_ISREG(info.st_mode):
                        refuse("wrong release content type: %s" % path)
                        tree_ok = False
                        break
                else:
                    refuse("wrong mode for %s: expected %s, found %s" % (path, mode, "unknown"))
                    tree_ok = False
                    break
                infos.append(info)

            # Pass 2: link targets stay inside the payload, file modes match.
            targets = {}
            if tree_ok:
                for row, info in zip(rows, infos):
                    mode, path = row["mode"], row["path"]
                    parts = path.split("/")
                    state, dir_fd = parents.open(parts[:-1])
                    if state != "ok":
                        raise Undecided()
                    if mode == "120000":
                        target = os.readlink(parts[-1], dir_fd=dir_fd)
                        if unsafe_link_target(path, target, payload_fd):
                            refuse("unsafe release symlink target: %s" % path)
                            tree_ok = False
                            break
                        targets[path] = os.fsencode(target)
                    else:
                        actual = "100755" if info.st_mode & EXEC_COLUMNS else "100644"
                        if actual != mode:
                            refuse("wrong mode for %s: expected %s, found %s" % (path, mode, actual))
                            tree_ok = False
                            break

            # Pass 3: Git blob IDs, then the write bit or ACL of each file.
            if tree_ok:
                for row, info in zip(rows, infos):
                    mode, path, oid = row["mode"], row["path"], row["oid"]
                    parts = path.split("/")
                    if mode == "120000":
                        data = targets[path]
                    else:
                        state, dir_fd = parents.open(parts[:-1])
                        if state != "ok":
                            raise Undecided()
                        data, file_acl = read_file(parts[-1], dir_fd, info, acl)
                    if blob_oid(data) != oid:
                        refuse("changed release content: %s" % path)
                        break
                    if not skip_writable and mode != "120000":
                        if info.st_mode & WRITE_BITS or file_acl:
                            refuse("writable release content: %s" % path)
                            break
        finally:
            parents.close()

        # The payload holds exactly the manifest paths and their directories;
        # the same walk finds the first writable directory of the release.
        fs_paths, fs_dirs = set(), set()
        writable_dir = None
        if not skip_writable:
            for rel, fd in (("", release_fd), ("payload", payload_fd)):
                if os.fstat(fd).st_mode & WRITE_BITS or acl.has_acl_fd(fd):
                    writable_dir = rel or release_dir
                    break
        payload_info = os.fstat(payload_fd)
        pending = [("", payload_info.st_ino, payload_info.st_dev)]
        try:
            while pending:
                rel, ino, dev = pending.pop()
                fd = payload_fd if rel == "" else os.open(rel, DIRECTORY_FLAGS, dir_fd=payload_fd)
                try:
                    info = os.fstat(fd)
                    if (info.st_ino, info.st_dev) != (ino, dev):
                        raise Undecided()
                    if rel and writable_dir is None and not skip_writable:
                        if info.st_mode & WRITE_BITS or acl.has_acl_fd(fd):
                            writable_dir = "payload/" + rel
                    for name in os.listdir(fd):
                        child = name if rel == "" else rel + "/" + name
                        if unsafe_path(child):
                            refuse("unsafe release payload path: %s" % child)
                            return findings
                        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        if stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode):
                            fs_paths.add(child)
                        elif stat.S_ISDIR(info.st_mode):
                            fs_dirs.add(child)
                            pending.append((child, info.st_ino, info.st_dev))
                        else:
                            refuse("unexpected release payload content type: %s" % child)
                            return findings
                finally:
                    if fd != payload_fd:
                        os.close(fd)
        finally:
            os.close(payload_fd)
        manifest_paths = set(paths)
        if manifest_paths != fs_paths:
            for path in sorted(manifest_paths - fs_paths):
                findings.append("-" + path)
            for path in sorted(fs_paths - manifest_paths):
                findings.append("+" + path)
            refuse("release payload has missing or added paths")
        if manifest_dirs != fs_dirs:
            for path in sorted(manifest_dirs - fs_dirs):
                findings.append("-" + path)
            for path in sorted(fs_dirs - manifest_dirs):
                findings.append("+" + path)
            refuse("release payload has missing or added directories")
        if writable_dir is not None:
            refuse("writable release directory: %s" % writable_dir)
        if not skip_writable:
            if record_info.st_mode & WRITE_BITS or record_acl:
                refuse("writable release record: release.json")
    finally:
        os.close(release_fd)
    return findings


def any_acl(release_dir):
    """Whether the release directory or any entry under it has an ACL, links
    included, as `find | xargs ls -lde` lists them. Directories are asked
    through the descriptor the walk holds; other entries by path, without
    following a link, as that listing does."""
    acl = AclProbe()
    root_fd = open_directory(release_dir)
    try:
        root = os.fstat(root_fd)
        pending = [("", root.st_ino, root.st_dev)]
        while pending:
            rel, ino, dev = pending.pop()
            fd = root_fd if rel == "" else os.open(rel, DIRECTORY_FLAGS, dir_fd=root_fd)
            try:
                info = os.fstat(fd)
                if (info.st_ino, info.st_dev) != (ino, dev):
                    raise Undecided()
                if acl.has_acl_fd(fd):
                    return True
                for name in os.listdir(fd):
                    child = name if rel == "" else rel + "/" + name
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        pending.append((child, info.st_ino, info.st_dev))
                    else:
                        is_symlink = stat.S_ISLNK(info.st_mode)
                        if acl.has_acl_path(release_dir + "/" + child, is_symlink=is_symlink):
                            return True
                        if is_symlink:
                            after = os.stat(name, dir_fd=fd, follow_symlinks=False)
                            fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid',
                                      'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
                            if any(getattr(info, key) != getattr(after, key) for key in fields):
                                raise Undecided()
            finally:
                if fd != root_fd:
                    os.close(fd)
    finally:
        os.close(root_fd)
    return False


def main(argv):
    if len(argv) == 2 and argv[1] == "acl":
        if any_acl(argv[0]):
            return 4
        print("ok")
        return 0
    if len(argv) != 2 or argv[1] not in ("0", "1"):
        return 2
    findings = audit(argv[0], argv[1] == "1")
    for line in findings:
        sys.stderr.write(line + "\n")
    if findings:
        return 4
    print("ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:
        sys.exit(1)
