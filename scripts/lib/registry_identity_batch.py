"""Positive-only registry identity observations for one listing.

The scalar shell classifier is authoritative on every miss.  This helper
certifies the ordinary Git layout only: a non-bare primary checkout with a
.git directory and linked worktrees with Git's standard back-pointers and
symbolic HEAD.  Unusual configuration, layout, or I/O means "undecided".
The input files hold the shell's flattened rows, one JSON object per line;
stdout is one JSON object with parallel boolean arrays.
"""
import concurrent.futures
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import time
import types


SAFE_GIT_ENV = {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_OPTIONAL_LOCKS", "GIT_TERMINAL_PROMPT"}
HEAD = re.compile(rb"ref: refs/heads/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\n?\Z")
GIT = None


def load_fs(path):
    sys.dont_write_bytecode = True
    if path == ":bundle:":
        # The caller admits this only inside the verified command bundle; the
        # manifest-checked source is data, never read from a snapshot path.
        source = os.environ["TRELLIS_REGISTRY_BATCH_FS_PROGRAM"]
        module = types.ModuleType("trellis_attachment_fs")
        exec(compile(source, "<verified attachment_fs>", "exec"), module.__dict__)
        return module
    spec = importlib.util.spec_from_file_location("trellis_attachment_fs", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rows(path):
    with open(path, encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def git(root, *args):
    try:
        result = subprocess.run([GIT, "-C", root, *args], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        return result.stdout if result.returncode == 0 else None
    except (OSError, ValueError):
        return None


def physical(path):
    # os.path.realpath(path, strict=True) exists only from Python 3.10, and the
    # installed launcher can run macOS's /usr/bin/python3 (3.9). os.stat follows
    # the path and raises on a missing component or a symlink loop, which is
    # what strict=True refuses; realpath then names the target.
    try:
        os.stat(path)
        return os.path.realpath(path)
    except (OSError, ValueError):
        return None


def canonical(fs, path):
    # Stricter than the shell's cd/pwd: a symlink component is a miss.
    return isinstance(path, str) and not fs.has_jq_controls(path) and fs.no_symlink_components(path) \
        and os.path.isdir(path) and physical(path) == path


def owned(path):
    try:
        return os.lstat(path).st_uid == os.geteuid()
    except OSError:
        return False


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def read_regular(path):
    # Read a metadata leaf once, without following a substituted link. A
    # changed or unusually large file is not evidence for a positive result.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_size > 65536:
                return None
            data = os.read(fd, 65537)
            after = os.fstat(fd)
            current = os.lstat(path)
            if len(data) != before.st_size or fingerprint(before) != fingerprint(after) \
                    or fingerprint(before) != fingerprint(current):
                return None
            return data
        finally:
            os.close(fd)
    except OSError:
        return None


def projectable(row):
    # jq's .metadata.legacy.blacklisted errors on scalar legacy values; keep
    # those rows in the shell, preserving its error and diagnostic ordering.
    metadata = row.get("metadata")
    if not isinstance(metadata, dict):
        return False
    legacy = metadata.get("legacy")
    return legacy is None or isinstance(legacy, dict)


def ordinary_config(checkout):
    # Includes can vary with the linked worktree's gitdir. Worktree-specific
    # config and core.worktree/bare likewise change Git discovery. Ask Git for
    # *unexpanded* configuration so even a currently inactive includeIf is
    # visible; any such case stays with the scalar classifier.
    raw = git(checkout, "config", "--no-includes", "--null", "--list")
    if raw is None:
        return False
    for record in raw.split(b"\0"):
        if not record:
            continue
        key, sep, value = record.partition(b"\n")
        key = key.lower()
        if not sep or key.startswith((b"include.", b"includeif.")) \
                or key in (b"core.worktree", b"extensions.worktreeconfig"):
            return False
        if key == b"core.bare" and value.lower() not in (b"false", b"no", b"off", b"0"):
            return False
    return True


def linked_metadata(fs, root, common, members):
    if os.fsencode(root) not in members or not owned(root):
        return False
    dotgit = root + "/.git"
    data = read_regular(dotgit)
    if data is None or not data.startswith(b"gitdir: ") or not data.endswith(b"\n"):
        return False
    gitdir = os.fsdecode(data[8:-1])
    if os.path.dirname(gitdir) != common + "/worktrees" or not canonical(fs, gitdir) or not owned(gitdir):
        return False
    if os.path.lexists(gitdir + "/config.worktree"):
        return False
    # The standard pointers are a deliberately narrower subset of Git's
    # accepted syntax. Each path-bound file is opened only once.
    if read_regular(gitdir + "/commondir") not in (b"../..\n", b"../.."):
        return False
    if read_regular(gitdir + "/gitdir") != os.fsencode(dotgit) + b"\n":
        return False
    head = read_regular(gitdir + "/HEAD")
    return head is not None and HEAD.fullmatch(head) is not None


def verify_group(fs, key, indexed_rows):
    checkout, common, checkout_id = key
    try:
        if not canonical(fs, checkout) or not canonical(fs, common) or common != checkout + "/.git" \
                or not owned(checkout) or not owned(common) or fs.sha256_text(common) != checkout_id \
                or os.path.lexists(common + "/config.worktree") or not ordinary_config(checkout):
            return []
        # One Git observation for all rev-parse facts at the primary checkout,
        # and one worktree enumeration for the whole common directory.
        record = git(checkout, "rev-parse", "--show-toplevel", "--is-inside-work-tree", "--git-common-dir")
        if record is None:
            return []
        fields = os.fsdecode(record).rstrip("\n").split("\n")
        if len(fields) != 3 or physical(fields[0]) != checkout or fields[1] != "true":
            return []
        git_common = fields[2] if fields[2].startswith("/") else checkout + "/" + fields[2]
        if physical(git_common) != common:
            return []
        listing = git(checkout, "worktree", "list", "--porcelain", "-z")
        if listing is None or b"\0" not in listing:
            return []
        fields = listing.split(b"\0")
        if not fields[0].startswith(b"worktree ") or physical(os.fsdecode(fields[0][9:])) != checkout:
            return []
        members = {field[9:] for field in fields if field.startswith(b"worktree ")}
        verified = []
        # Duplicate paths can appear in malformed-but-structural state. Reuse a
        # metadata observation only inside this pass, never across listings.
        linked = {}
        for index, row in indexed_rows:
            root, kind = row.get("root"), row.get("kind")
            if not canonical(fs, root) or not owned(root):
                continue
            if kind == "worktree" and fs.sha256_text(root) != row.get("worktree_id"):
                continue
            if root == checkout:
                verified.append(index)
                continue
            if root not in linked:
                linked[root] = linked_metadata(fs, root, common, members)
            if linked[root]:
                verified.append(index)
        return verified
    except OSError:
        # A filesystem error is "undecided" for this group. Anything else is a
        # programming error: it leaves the helper, which exits non-zero, and
        # the whole batch falls back visibly instead of silently unproved.
        return []


def classify(fs, all_rows):
    proofs = [False] * len(all_rows)
    groups = {}
    safe_env = not any(key.startswith("GIT_") and key not in SAFE_GIT_ENV for key in os.environ)
    # Relative config and home paths are resolved after Git's -C, and can
    # therefore name different files in the primary and a linked worktree.
    for key in ("GIT_CONFIG_GLOBAL", "HOME", "XDG_CONFIG_HOME"):
        value = os.environ.get(key)
        if value and not os.path.isabs(value):
            safe_env = False
    if sys.getfilesystemencoding().lower().replace("_", "-") != "utf-8":
        safe_env = False
    for index, row in enumerate(all_rows):
        if not isinstance(row, dict):
            continue
        kind = row.get("kind")
        if kind in ("project", "unavailable"):
            proofs[index] = projectable(row)
        elif safe_env and kind in ("checkout", "worktree") and ("metadata" not in row or projectable(row)):
            key = (row.get("checkout_root"), row.get("git_common_dir"), row.get("checkout_id"))
            if all(isinstance(value, str) for value in key):
                groups.setdefault(key, []).append((index, row))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(verify_group, fs, key, entries) for key, entries in groups.items()]
        for future in futures:
            for index in future.result():
                proofs[index] = True
    return proofs


def _stat_line(info, full):
    if sys.platform == "darwin":
        if not full:
            return "%d\t%d\t%o\t%d" % (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
        def stamp(ns):
            return "%d.%09d" % divmod(ns, 1000000000)
        return "%d\t%d\t%d\t%o\t%s\t%s" % (
            info.st_dev, info.st_ino, info.st_size, info.st_mode,
            stamp(info.st_mtime_ns), stamp(info.st_ctime_ns))
    if sys.platform.startswith("linux"):
        if not full:
            return "%d\t%d\t%x\t%d" % (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
        def stamp(ns):
            seconds, fraction = divmod(ns, 1000000000)
            return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(seconds)) + ".%09d +0000" % fraction
        return "%d\t%d\t%d\t%x\t%s\t%s" % (
            info.st_dev, info.st_ino, info.st_size, info.st_mode,
            stamp(info.st_mtime_ns), stamp(info.st_ctime_ns))
    raise ValueError("unsupported stat format")


def _pin_paths(fs, row, home, global_config, started):
    root, checkout, common = row["root"], row["checkout_root"], row["git_common_dir"]
    dotgit = root + "/.git"
    watched = {root, dotgit, os.path.dirname(root), checkout, common, common + "/config",
               common + "/HEAD", home, home + "/registry.json", global_config,
               os.path.dirname(global_config)}
    if root != checkout:
        data = read_regular(dotgit)
        if data is None or not data.startswith(b"gitdir: ") or not data.endswith(b"\n"):
            return None
        gitdir = os.fsdecode(data[8:-1])
        if os.path.dirname(gitdir) != common + "/worktrees":
            return None
        watched.update((gitdir, os.path.dirname(gitdir), gitdir + "/HEAD",
                        gitdir + "/commondir", gitdir + "/gitdir"))
    ancestors = set()
    for path in watched:
        if not fs.valid_absolute(path) or physical(path) != path or not fs.no_symlink_components(path):
            return None
        parent = os.path.dirname(path)
        while parent:
            ancestors.add(parent)
            if parent == "/":
                break
            parent = os.path.dirname(parent)
    watched = sorted(watched)
    ancestors = sorted(ancestors - set(watched))
    full_lines, ancestor_lines = [], []
    for path in watched:
        info = os.lstat(path)
        # Coarse ctime or a change since classification began cannot prove that
        # this is the same state the classifier observed.
        if info.st_ctime_ns >= started or info.st_ctime_ns % 1000000 == 0:
            return None
        full_lines.append(_stat_line(info, True))
    for path in ancestors:
        info = os.lstat(path)
        if not stat.S_ISDIR(info.st_mode):
            return None
        # A writable ancestor could have been swapped between the Git
        # observation and pin capture. It must be fine-ctime and older than
        # the pass; at use we need only its inode/mode, so unrelated sibling
        # writes after capture do not invalidate every row.
        if os.access(path, os.W_OK | os.X_OK) and (
                info.st_ctime_ns >= started or info.st_ctime_ns % 1000000 == 0):
            return None
        ancestor_lines.append(_stat_line(info, False))
    return watched, full_lines, ancestors, ancestor_lines


def write_sync_pins(fs, listing_rows, proofs, home, directory, started):
    # Until the origin and absence of every system/global config can be pinned,
    # only this explicit Git configuration is eligible. Other environments keep
    # the existing per-row resolver, not a weaker identity check.
    global_config = os.environ.get("GIT_CONFIG_GLOBAL", "")
    if os.environ.get("GIT_CONFIG_NOSYSTEM") != "1" or not os.path.isabs(global_config):
        return
    if not canonical(fs, directory) or not owned(directory):
        return
    info = os.lstat(directory)
    if stat.S_IMODE(info.st_mode) != 0o700:
        return
    for row, verified in zip(listing_rows, proofs):
        if not verified or row.get("kind") != "worktree":
            continue
        identity = row.get("worktree_id")
        if not isinstance(identity, str) or re.fullmatch(r"[0-9a-f]{64}", identity) is None:
            continue
        try:
            pins = _pin_paths(fs, row, home, global_config, started)
            if pins is None:
                continue
            watched, full_lines, ancestors, ancestor_lines = pins
            resolution = {key: row[key] for key in ("fleet", "project_id", "project_key", "checkout_id",
                                                    "worktree_id", "root", "git_common_dir")}
            contents = {
                "root": row["root"] + "\n", "resolution": json.dumps(resolution, ensure_ascii=True) + "\n",
                "watched": "\n".join(watched) + "\n", "full": "\n".join(full_lines) + "\n",
                "ancestors": "\n".join(ancestors) + "\n", "partial": "\n".join(ancestor_lines) + "\n",
            }
            for suffix, content in contents.items():
                path = directory + "/" + identity + "." + suffix
                with open(path, "x", encoding="utf-8") as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(content)
            # Publish the per-row marker last; partial output is never a proof.
            with open(directory + "/" + identity + ".ready", "x", encoding="ascii") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write("ready\n")
        except (OSError, ValueError, TypeError, KeyError, UnicodeError, OverflowError):
            continue


def main():
    global GIT
    if len(sys.argv) != 5 or not os.path.isabs(sys.argv[4]):
        return 1
    started = time.time_ns()
    GIT = sys.argv[4]
    fs = load_fs(sys.argv[1])
    checkout_rows, listing_rows = rows(sys.argv[2]), rows(sys.argv[3])
    proofs = classify(fs, checkout_rows + listing_rows)
    cut = len(checkout_rows)
    pin_home = os.environ.get("TRELLIS_REGISTRY_PIN_HOME", "")
    pin_dir = os.environ.get("TRELLIS_REGISTRY_PIN_DIR", "")
    if pin_home and pin_dir:
        write_sync_pins(fs, listing_rows, proofs[cut:], pin_home, pin_dir, started)
    json.dump({"checkouts": proofs[:cut], "rows": proofs[cut:]}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # any surprise: no proof, and say so
        sys.stderr.write("registry_identity_batch: %s: %s\n" % (type(error).__name__, error))
        sys.exit(3)
