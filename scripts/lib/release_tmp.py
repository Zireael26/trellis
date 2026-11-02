"""Descriptor-relative scanner/sink for the janitor's release-tmp scope."""
import json
import os
import re
import stat
import subprocess
import sys
import time

DAY = 86400  # Ownerless builds and stamp writes get a full day to finish.
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
KEY = r"(" + VERSION + r")-[0-9a-f]{64}"
SNAPSHOT = re.compile(KEY)
WORK = re.compile(r"\.tmp\.(?:" + KEY + r"|(" + VERSION + r")\.verify)\.[A-Za-z0-9]+")
STAMP = re.compile(KEY + r"\.json")
STAMP_TMP = re.compile(r"\." + KEY + r"\.json\.[0-9a-f]{16}\.tmp")
OWNER = ".owner.json"
FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def identity(info):
    return info.st_dev, info.st_ino


def lstat(fd, name):
    try:
        return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def open_dir(fd, name):
    before = lstat(fd, name)
    child = os.open(name, FLAGS, dir_fd=fd)
    if before is None or identity(os.fstat(child)) != identity(before):
        os.close(child)
        raise OSError("directory changed while opening")
    return child


def read_json(fd, name, limit):
    child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        if not stat.S_ISREG(os.fstat(child).st_mode):
            raise ValueError("not a regular JSON file")
        return json.loads(os.read(child, limit + 1))
    finally:
        os.close(child)


def owner_state(fd, name, birth_program):
    """Unknown is kept; only ESRCH or a proven birth mismatch means dead."""
    if lstat(fd, name + OWNER) is None:
        return "none"
    try:
        record = read_json(fd, name + OWNER, 4096)
        if (not isinstance(record, dict)
                or sorted(record) != ["pid", "process_birth", "schema_version"]
                or type(record["schema_version"]) is not int or record["schema_version"] != 1
                or type(record["pid"]) is not int or not 0 < record["pid"] <= 2147483647
                or not isinstance(record["process_birth"], str) or not record["process_birth"].strip()):
            return "unknown"
        try:
            os.kill(record["pid"], 0)
        except ProcessLookupError:
            return "dead"
        argv = ([sys.executable, "-I", "-c", birth_program, str(record["pid"])]
                if sys.platform == "darwin" else ["ps", "-p", str(record["pid"]), "-o", "lstart="])
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                stdin=subprocess.DEVNULL, timeout=30, env=dict(os.environ, LC_ALL="C"))
        birth = result.stdout.decode("utf-8").strip()
        if result.returncode or not birth:
            return "unknown"
        return "live" if birth == record["process_birth"].strip() else "dead"
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        return "unknown"


def in_use(path, lsof_file):
    try:
        with open(lsof_file) as source:
            if source.readline().strip() != "ok":
                return True
            for line in source:
                if not line.startswith("n"):
                    continue
                opened = line[1:].rstrip("\n").removesuffix(" (deleted)")
                if opened == path or opened.startswith(path + "/"):
                    return True
    except (OSError, UnicodeError):
        return True
    return False


def walk(fd, device, remove=False):
    """Never follow links; sealed trees are made writable through their fds."""
    if remove:
        os.fchmod(fd, 0o700)
    total = os.fstat(fd).st_blocks * 512
    for name in os.listdir(fd):
        info = lstat(fd, name)
        if info is None:
            raise OSError("entry disappeared")
        if stat.S_ISDIR(info.st_mode):
            if info.st_dev != device:
                raise OSError("contains a mount point")
            child = open_dir(fd, name)
            try:
                total += walk(child, device, remove)
            finally:
                os.close(child)
            if identity(lstat(fd, name)) != identity(info):
                raise OSError("entry changed")
            if remove:
                os.rmdir(name, dir_fd=fd)
        else:
            total += info.st_blocks * 512
            if remove:
                os.unlink(name, dir_fd=fd)
    return total


def classify(home_fd, releases_fd, fd, area, name, home, lsof_file, birth_program):
    info = lstat(fd, name)
    if info is None:
        return None
    owner = None
    path = home + "/" + area + "/" + name
    if area == "releases/.exec":
        base = name[:-len(OWNER)] if name.endswith(OWNER) else name
        work = WORK.fullmatch(base)
        final = SNAPSHOT.fullmatch(name)
        if work:
            if name.endswith(OWNER):
                if lstat(fd, base) is not None or not stat.S_ISREG(info.st_mode):
                    return None
                kind = "exec-owner"
            elif stat.S_ISDIR(info.st_mode):
                kind = "exec-work"
                owner = lstat(fd, name + OWNER)
            else:
                return None
            state = owner_state(fd, base, birth_program)
            age = time.time() - max(info.st_mtime, owner.st_mtime if owner else 0)
            reap = state == "dead" or (state == "none" and age > DAY)
            reason = "owner=" + state + ("; older than 1d" if age > DAY else "; younger than 1d")
        elif final and stat.S_ISDIR(info.st_mode):
            kind = "exec-snapshot"
            reap, reason = uninstalled(home_fd, releases_fd, final[1])
        else:
            return None
    else:
        temporary, final = STAMP_TMP.fullmatch(name), STAMP.fullmatch(name)
        if not stat.S_ISREG(info.st_mode) or not (temporary or final):
            return None
        kind = "stamp-tmp" if temporary else "release-stamp"
        if temporary:
            reap = time.time() - info.st_mtime > DAY
            reason = "stamp write older than 1d" if reap else "stamp write younger than 1d"
        else:
            reap, reason = uninstalled(home_fd, releases_fd, final[1])
    if reap and kind in ("exec-snapshot", "stamp-tmp") and in_use(path, lsof_file):
        reap, reason = False, "live handle or lsof unavailable"
    return info, owner, kind, reap, reason


def uninstalled(home_fd, releases_fd, version):
    # Re-read after confirmation as well: a plan never authorizes deletion.
    config = read_json(home_fd, "config.json", 1048576)
    active = config["active_cli_release"]
    if not isinstance(active, str) or not active:
        raise ValueError("active release is unavailable")
    if version == active:
        return False, "active release"
    if lstat(releases_fd, version) is not None:
        return False, "release still installed"
    return True, "release no longer installed"


def process(home, mode, lsof_file, birth_program, selected=None, expected=None):
    if os.path.realpath(home) != home:
        raise ValueError("TRELLIS_HOME is not canonical")
    home_fd = os.open(home, FLAGS)
    try:
        releases_fd = open_dir(home_fd, "releases")
        try:
            for area in ("releases/.exec", "state/release-stamps", "state/exec-stamps"):
                if selected is not None and not selected.startswith(home + "/" + area + "/"):
                    continue
                parent_name, leaf = area.split("/")
                try:
                    parent = open_dir(home_fd, parent_name)
                    try:
                        fd = open_dir(parent, leaf)
                    finally:
                        os.close(parent)
                except FileNotFoundError:
                    continue
                try:
                    names = [selected.rsplit("/", 1)[1]] if selected else sorted(os.listdir(fd))
                    for name in names:
                        path = home + "/" + area + "/" + name
                        row = classify(home_fd, releases_fd, fd, area, name, home, lsof_file, birth_program)
                        if row is None:
                            continue
                        info, owner, kind, reap, reason = row
                        if mode == "remove" and (not reap or identity(info) != expected):
                            print("  skipped (plan changed): " + path)
                            continue
                        if stat.S_ISDIR(info.st_mode):
                            child = open_dir(fd, name)
                            try:
                                if info.st_dev != os.fstat(fd).st_dev:
                                    raise OSError("candidate on another device")
                                size = walk(child, info.st_dev)
                                if mode == "remove":
                                    again = classify(home_fd, releases_fd, fd, area, name, home, lsof_file, birth_program)
                                    if (again is None or not again[3] or identity(again[0]) != identity(info)
                                            or (identity(again[1]) if again[1] else None) != (identity(owner) if owner else None)):
                                        print("  skipped (plan changed): " + path)
                                        continue
                                    walk(child, info.st_dev, True)
                            finally:
                                os.close(child)
                        else:
                            size = info.st_blocks * 512
                        if owner:
                            size += owner.st_blocks * 512
                        if mode == "scan":
                            print("\t".join(map(str, ("release-tmp", "delete" if reap else "skip", kind,
                                                      path, size, "-", reason, *identity(info)))))
                        else:
                            if identity(lstat(fd, name)) != identity(info):
                                raise OSError("candidate changed before unlink")
                            if stat.S_ISDIR(info.st_mode):
                                os.rmdir(name, dir_fd=fd)
                            else:
                                os.unlink(name, dir_fd=fd)
                            if owner:
                                if identity(lstat(fd, name + OWNER)) != identity(owner):
                                    raise OSError("owner changed before unlink")
                                os.unlink(name + OWNER, dir_fd=fd)
                            print("  removed: %s (%d bytes)" % (path, size))
                finally:
                    os.close(fd)
        finally:
            os.close(releases_fd)
    finally:
        os.close(home_fd)


if __name__ == "__main__":
    try:
        home, mode, lsof_file, birth_program = sys.argv[1:5]
        selected = sys.argv[5] if len(sys.argv) > 5 else None
        expected = tuple(map(int, sys.argv[6:8])) if selected else None
        process(home, mode, lsof_file, birth_program, selected, expected)
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.stderr.write("disk-janitor release-tmp: %s\n" % error)
        sys.exit(1)
