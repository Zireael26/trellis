"""Release stamp (spec 072 D-A): a stat manifest of a sealed release, written
right after a full verify passed, so an unchanged release is re-proved by one
lstat sweep instead of a re-hash.

    release_stamp.py check HOME RELEASE_DIR
        exit 0: the stamp matches the release as it is now; prints "hit".
        exit 1: anything else; prints the sweep token when the sweep itself
        succeeded, for the write that follows the full verify of the caller.
    release_stamp.py write HOME RELEASE_DIR TOKEN
        exit 0: written. exit 1: refused, nothing written.

The stamp is $HOME/state/release-stamps/<version>-<release.json sha256>.json
(0600 in a 0700 directory, written to a temporary name, then renamed). It
records, for the release directory and every entry under it, the path, type,
mode, size, mtime_ns, ctime_ns, inode and device, the directory set, the
release.json digest and the schema version. A write, rename, link, or change
of mode, owner or ACL moves ctime, and no ordinary tool can set ctime back, so
any such change since the stamp makes check miss, and the caller falls back to
its full verify. A missing, unreadable, truncated or garbage stamp, or one for
another release.json, is a miss: check never passes on absence.

The token is the digest of the stamp this sweep would write. check computes it
before the full verify and write recomputes it after, and write refuses when
they differ, so nothing that changed while the full verify ran is stamped.

The stamp needs fine-grained ctime: where ctime is coarse (HFS+ keeps whole
seconds, exFAT 10 ms, a kernel that stamps from a coarse clock one tick) a
change and restore within one tick could go unseen. So the release must sit on
one device, a mounted subtree being free to be coarser than the rest, and
every ctime in the sweep must have digits below a millisecond; otherwise check
misses without a token and write refuses. write also proves the device: the
stamp directory must be on it, and two metadata changes in a row on the new
stamp file must each move its ctime. A filesystem that fails any of this
always takes the full verify.

Schema 2 is the first written under that proof. A schema 1 stamp may have been
written on a filesystem the proof now refuses, so it is a miss like any other
stale stamp, and the full verify that follows writes schema 2.

Trust: this resists accidents, other Unix users and same-user changes made
with ordinary tools. A same-user attacker can forge a stamp, but that user can
already rewrite ~/.local/bin/trellis. The sweep is not atomic; its window is
the verify-then-use window callers already accept.

The managed git-hook dispatcher carries this file as text (attachment.sh,
_attachment_release_stamp_emitter) and runs it with python3 -I -c, so the file
must never contain a single quote. Python 3.6 or later, stdlib only.
"""
import hashlib
import json
import os
import re
import stat
import sys

SCHEMA_VERSION = 2
STAMP_LIMIT = 64 * 1024 * 1024
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FIELDS = ("type", "mode", "size", "mtime_ns", "ctime_ns", "ino", "dev")


class Refuse(Exception):
    pass


def open_directory(path):
    """Open a canonical absolute directory without following any component."""
    parts = path.split("/")[1:]
    if not path.startswith("/") or path == "/" or any(p in ("", ".", "..") for p in parts):
        raise Refuse()
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


def describe(info):
    if stat.S_ISREG(info.st_mode):
        kind = "f"
    elif stat.S_ISLNK(info.st_mode):
        kind = "l"
    elif stat.S_ISDIR(info.st_mode):
        kind = "d"
    else:
        raise Refuse()
    return (kind, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_ino, info.st_dev)


def sweep(root_fd):
    """lstat the release directory and everything under it, following nothing.

    Each directory is opened through the root descriptor and must be the inode
    its parent listing recorded, so a directory swapped during the sweep refuses.
    """
    entries = {".": describe(os.fstat(root_fd))}
    pending = ["."]
    while pending:
        rel = pending.pop()
        fd = root_fd if rel == "." else os.open(rel, DIRECTORY_FLAGS, dir_fd=root_fd)
        try:
            info = os.fstat(fd)
            if (info.st_ino, info.st_dev) != entries[rel][5:7]:
                raise Refuse()
            for name in os.listdir(fd):
                child = name if rel == "." else rel + "/" + name
                entry = describe(os.stat(name, dir_fd=fd, follow_symlinks=False))
                entries[child] = entry
                if entry[0] == "d":
                    pending.append(child)
        finally:
            if fd != root_fd:
                os.close(fd)
    return entries


def read_regular(name, dir_fd, limit):
    # O_NONBLOCK: a FIFO opens at once and is refused below, never waited on.
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Refuse()
        chunks = []
        while True:
            chunk = os.read(fd, 1048576)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(fd)
    return info, b"".join(chunks)


def locate(home, release_dir):
    """Return (stamp directory, stamp name, release.json bytes, sweep)."""
    if not home.startswith("/") or not release_dir.startswith("/"):
        raise Refuse()
    home = os.path.realpath(home)
    version = release_dir.rsplit("/", 1)[-1]
    if re.fullmatch("[0-9A-Za-z][0-9A-Za-z.+-]*", version) is None:
        raise Refuse()
    if release_dir != home + "/releases/" + version:
        raise Refuse()
    root_fd = open_directory(release_dir)
    try:
        raw = read_regular("release.json", root_fd, STAMP_LIMIT)[1]
        entries = sweep(root_fd)
    finally:
        os.close(root_fd)
    digest = hashlib.sha256(raw).hexdigest()
    return home + "/state/release-stamps", version + "-" + digest + ".json", raw, entries


def fine_ctime(entries):
    """True when the sweep is on one device and every ctime in it is finer
    than a millisecond."""
    if len({entry[6] for entry in entries.values()}) != 1:
        return False
    return all(entry[4] % 1000000 for entry in entries.values())


def ctime_moves(fd):
    """True when two metadata changes in a row on fd each move its ctime: a
    filesystem that stamps ctime from a coarse clock gives both one value."""
    before = os.fstat(fd).st_ctime_ns
    for mode in (0o400, 0o600):
        os.fchmod(fd, mode)
        after = os.fstat(fd).st_ctime_ns
        if after == before:
            return False
        before = after
    return True


def render(release_dir, raw, entries):
    """The exact stamp bytes for this sweep; check compares bytes, not JSON."""
    rows = {"f": [], "l": [], "d": []}
    for path in sorted(entries):
        entry = entries[path]
        row = {"path": path}
        row.update(zip(FIELDS, entry))
        rows[entry[0]].append(row)
    stamp = {
        "schema_version": SCHEMA_VERSION,
        "version": release_dir.rsplit("/", 1)[-1],
        "root": release_dir,
        "release_json_sha256": hashlib.sha256(raw).hexdigest(),
        "entries": sorted(rows["f"] + rows["l"], key=lambda row: row["path"]),
        "directories": rows["d"],
    }
    return (json.dumps(stamp, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def private_directory(path, create):
    """The stamp directory: a real 0700 directory this user owns."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if not create:
            raise Refuse()
        os.mkdir(path, 0o700)
        info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise Refuse()
    if stat.S_IMODE(info.st_mode) != 0o700:
        if not create:
            raise Refuse()
        os.chmod(path, 0o700)


def check(home, release_dir):
    directory, name, raw, entries = locate(home, release_dir)
    if not fine_ctime(entries):
        return 1
    expected = render(release_dir, raw, entries)
    try:
        private_directory(directory, False)
        fd = open_directory(directory)
        try:
            info, recorded = read_regular(name, fd, STAMP_LIMIT)
        finally:
            os.close(fd)
        if info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o600 and recorded == expected:
            print("hit")
            return 0
    except (OSError, Refuse):
        pass
    print(hashlib.sha256(expected).hexdigest())
    return 1


def sealed(raw, entries):
    """The layout a full verify has just proved, re-checked from the sweep alone:
    release.json and payload only, payload equal to the manifest tree, link and
    executable bits as recorded, and no write bit on any file or directory."""
    tree = json.loads(raw.decode("utf-8"))["tree"]
    modes = {}
    for item in tree:
        modes["payload/" + item["path"]] = item["mode"]
    if len(modes) != len(tree):
        raise Refuse()
    directories = {".", "payload"}
    for path in modes:
        while path.count("/") > 1:
            path = path.rsplit("/", 1)[0]
            directories.add(path)
    files = set(modes)
    files.add("release.json")
    if {p for p, e in entries.items() if e[0] == "d"} != directories:
        raise Refuse()
    if {p for p, e in entries.items() if e[0] != "d"} != files:
        raise Refuse()
    for path, entry in entries.items():
        if entry[0] != "l" and entry[1] & 0o222:
            raise Refuse()
    if entries["release.json"][0] != "f":
        raise Refuse()
    for path, mode in modes.items():
        kind, bits = entries[path][0], entries[path][1]
        if mode == "120000":
            if kind != "l":
                raise Refuse()
        elif kind != "f" or bool(bits & 0o111) != (mode == "100755"):
            raise Refuse()


def write(home, release_dir, token):
    if re.fullmatch("[0-9a-f]{64}", token) is None:
        raise Refuse()
    directory, name, raw, entries = locate(home, release_dir)
    if not fine_ctime(entries):
        raise Refuse()
    stamp = render(release_dir, raw, entries)
    if hashlib.sha256(stamp).hexdigest() != token or len(stamp) > STAMP_LIMIT:
        raise Refuse()
    sealed(raw, entries)
    state = directory.rsplit("/", 1)[0]
    try:
        info = os.lstat(state)
    except FileNotFoundError:
        os.mkdir(state, 0o700)
        info = os.lstat(state)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise Refuse()
    private_directory(directory, True)
    fd = open_directory(directory)
    try:
        if os.fstat(fd).st_dev != entries["."][6]:
            raise Refuse()
        temporary = ".%s.%s.tmp" % (name, os.urandom(8).hex())
        out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            os.fchmod(out, 0o600)
            if not ctime_moves(out):
                raise Refuse()
            view = memoryview(stamp)
            while view:
                view = view[os.write(out, view):]
        except BaseException:
            os.close(out)
            os.unlink(temporary, dir_fd=fd)
            raise
        os.close(out)
        try:
            os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
        except BaseException:
            os.unlink(temporary, dir_fd=fd)
            raise
    finally:
        os.close(fd)
    return 0


def main(argv):
    if len(argv) == 3 and argv[0] == "check":
        return check(argv[1], argv[2])
    if len(argv) == 4 and argv[0] == "write":
        return write(argv[1], argv[2], argv[3])
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, Refuse):
        sys.exit(1)
