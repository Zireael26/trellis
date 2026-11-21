"""One-pass owner verification for attachment_verify (perf item 4, 1.5.2).

Every check `attachment_verify` makes of an owner record before its managed
hooks, for many owners in one process: the owner file, its schema verdict and
canonical location, the contextual render context, the worktree root, the
canonical roots, the worktree and checkout ids, the render pairings, every
non-render artifact and every render's owned keys. The shell checks stay the
authority: this program must never pass an owner the shell would refuse.
Anything it cannot decide exactly is a failure (`undecided`), never a pass.

In process (a caller that imports this module, such as a transaction that
must keep what it verified):

    verify_owner_records(home, entries, mode="verify", opener=None) -> failures

`entries` is a list of {"path", "data", "record", "valid", "canonical"}:
`path` the owner file's canonical path; `data` its bytes or None (read through
the opener); `record` the parsed record or None (filled in from the bytes read); `valid` and `canonical` the
shell's verdicts on the schema (jq filter) and on the canonical location,
which the caller computes once for all owners. An empty list means every owner
passed. Each failure is {"owner", "check", "status", "fields"}; `status` is
the status the shell verifier returns at that check, before
_attachment_map_public_status. The first failure of an owner ends that owner,
as in the shell; other owners continue. render_failure(failure) gives the
diagnostic bytes the shell prints there (empty where it prints nothing).

The opener is called for each owner file, artifact parent directory, artifact
leaf and render file: opener(parent_fd, name, kind, expected) -> Node, with
kind file|symlink|directory. The default opener closes every descriptor at
once; a collector may keep Node.fd and Node.data and owns closing them.

mode "verify" leaves managed hooks to the caller: hooks_owners(entries) names
the owners whose hooks `_attachment_verify_managed_hooks` must still check.

    verify_siblings(entries, owner, opener=None) -> (failures, kept)

The per-sibling checks of a scope-current exact-owner reconcile
(_attach_reconcile_verify_owners in scripts/attach-project.sh) that read the
filesystem, for every owner of one checkout at once; see its docstring.
"""

import io
import json
import locale
import os
import stat
import sys

CHECKS = ("owner-file", "schema", "canonical-path", "render-context", "worktree-root", "roots",
          "ids", "render-pairings", "artifact", "render", "undecided")

fs = None          # attachment_fs: canonical_dir, canonical_file, parent_safe, sha256_text, git_common_dirs
settings = None    # the settings_owned_json program, loaded, never run


def load(fs_module, settings_program):
    global fs, settings
    fs = fs_module
    namespace = {"__name__": "trellis_settings_owned_json"}
    exec(compile(settings_program, "<settings-owned-json>", "exec"), namespace)
    settings = namespace


class Node(object):
    def __init__(self, kind, identity, parent_identity, data, fd):
        self.kind = kind
        self.identity = identity
        self.parent_identity = parent_identity
        self.data = data
        self.fd = fd

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def default_opener(parent_fd, name, kind, expected=None):
    """Open NAME under PARENT_FD without following a link; None when it is
    missing or not of KIND. The descriptor is closed before returning."""
    node = capture_opener(parent_fd, name, kind, expected)
    if node is not None:
        node.close()
    return node


def capture_opener(parent_fd, name, kind, expected=None):
    parent = _identity(os.fstat(parent_fd))
    try:
        if kind == "symlink":
            info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if not stat.S_ISLNK(info.st_mode):
                return None
            return Node(kind, _identity(info), parent, os.fsencode(os.readlink(name, dir_fd=parent_fd)), None)
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        if kind == "directory":
            flags |= os.O_DIRECTORY
        fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError:
        return None
    info = os.fstat(fd)
    if kind == "file" and not stat.S_ISREG(info.st_mode):
        os.close(fd)
        return None
    if kind == "directory" and not stat.S_ISDIR(info.st_mode):
        os.close(fd)
        return None
    data = None
    if kind == "file":
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
        data = b"".join(chunks)
    return Node(kind, _identity(info), parent, data, fd)


def _failure(owner, check, status, **fields):
    return {"owner": owner, "check": check, "status": status, "fields": fields}


def render_failure(failure):
    """The diagnostic the shell verifier prints for this failure, as bytes."""
    fields = failure["fields"]
    check = failure["check"]
    if check == "worktree-root":
        text = "owner record names a worktree root that no longer exists: %s" % fields["root"]
    elif check == "artifact":
        text = "owned artifact does not match its record: %s (recorded %s) under %s" % (
            fields["relative"], fields["kind"], fields["root"])
    elif check == "render":
        text = "owned render does not match its record: %s/%s" % (fields["root"], fields["relative"])
    else:
        return b""
    return b"trellis: " + os.fsencode(text) + b"\n"


def _posix_shell_quote(value):
    # attachment_contextual_posix_shell_quote
    if "\t" in value or "\n" in value or "\r" in value:
        return None
    return "'" + value.replace("'", "'\\''") + "'"


def _physical(path):
    # `CDPATH='' cd PATH && pwd -P`
    here = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.chdir(path)
        return os.getcwd()
    except OSError:
        return None
    finally:
        os.fchdir(here)
        os.close(here)


def _render_context_valid(record, home):
    # _attachment_contextual_render_context_record_valid with the verifier's
    # home as the expected TRELLIS_HOME.
    context = record.get("render_context")
    if context is None:
        return True
    names = ["launcher", "launcher_shell", "schema_version", "trellis_home", "trellis_home_shell",
             "user_home", "user_home_shell"]
    if not isinstance(context, dict) or sorted(context) != names or context["schema_version"] != 1 \
            or isinstance(context["schema_version"], bool):
        return False
    for key in ("user_home", "trellis_home", "launcher"):
        if not isinstance(context[key], str) or not context[key].startswith("/"):
            return False
    for key in ("user_home_shell", "trellis_home_shell", "launcher_shell"):
        value = context[key]
        if not isinstance(value, str) or not value.startswith("'") or not value.endswith("'"):
            return False
    if any("\0" in context[key] for key in names if isinstance(context[key], str)):
        return False
    user_home, trellis_home, launcher = context["user_home"], context["trellis_home"], context["launcher"]
    if not fs.canonical_dir(user_home) or not fs.canonical_dir(trellis_home):
        return False
    expected = _physical(home)
    if expected is None or not fs.canonical_dir(expected) or trellis_home != expected:
        return False
    bin_dir = _physical(user_home + "/.local/bin")
    if bin_dir is None or launcher != bin_dir + "/trellis":
        return False
    if not fs.canonical_file(launcher) or not os.access(launcher, os.X_OK):
        return False
    for key, value in (("user_home_shell", user_home), ("trellis_home_shell", trellis_home),
                       ("launcher_shell", launcher)):
        if context[key] != _posix_shell_quote(value):
            return False
    return True


def _render_pairings_valid(record):
    for render in record.get("renders") or []:
        artifacts = [item for item in record["artifacts"] if item.get("path") == render.get("path")]
        if (len(artifacts) != 1 or artifacts[0].get("kind") != "file"
                or artifacts[0].get("mode") != render.get("after_mode")
                or artifacts[0].get("sha256") != render.get("after_sha256")):
            return False
    return True


def _open_parent(root, relative):
    # _attachment_parent_safe, then the canonical parent pinned by descriptor.
    if not fs.parent_safe(root, relative):
        return None, None
    destination = root + "/" + relative
    parent, base = os.path.split(destination)
    if not fs.canonical_dir(parent):
        return None, None
    try:
        fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        return None, None
    if _identity(os.fstat(fd))[:2] != _identity(os.lstat(parent))[:2]:
        os.close(fd)
        return None, None
    _READS["parent"] = parent
    return fd, base


def _mode_matches(identity, expected):
    return isinstance(expected, str) and format(stat.S_IMODE(identity[2]), "o") == expected[1:]


def _sha256(data):
    import hashlib
    return hashlib.sha256(data).hexdigest()


def _artifact_exact(root, artifact, opener):
    # _attachment_artifact_exact_fields over _attachment_path_exact_fields.
    fd, base = _open_parent(root, artifact["path"])
    if fd is None:
        return False
    try:
        kind = artifact["kind"]
        if kind == "file":
            node = opener(fd, base, "file", artifact)
            if node is None:
                return False
            if node.identity[4] > 1:
                # A hardlinked regular file is left to the shell check, which
                # accepts it; the batch paths have always declined to judge it.
                return None
            if _sha256(node.data) != artifact.get("sha256"):
                return False
            return "mode" not in artifact or _mode_matches(node.identity, artifact["mode"])
        if kind == "symlink":
            node = opener(fd, base, "symlink", artifact)
            return node is not None and node.data == os.fsencode(artifact.get("target"))
        if kind in ("directory", "parent"):
            node = opener(fd, base, "directory", artifact)
            if node is None:
                return False
            if kind == "parent":
                return True
            listing_fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                if _identity(os.fstat(listing_fd))[:2] != node.identity[:2]:
                    return False
                return not os.listdir(listing_fd)
            finally:
                os.close(listing_fd)
        return False
    finally:
        os.close(fd)


def _has_float(value):
    if isinstance(value, float):
        return True
    if isinstance(value, dict):
        return any(_has_float(item) for item in value.values())
    if isinstance(value, list):
        return any(_has_float(item) for item in value)
    return False


def _render_exact(root, render, opener):
    # _attachment_render_owned_keys_exact: a regular file with the recorded
    # mode, a JSON object, and the owned keys as settings_owned_json `detail`
    # judges them. Owned values that hold a float are undecided: the shell
    # hands jq's re-serialization of them to the planner, which this process
    # does not reproduce.
    if _has_float(render.get("owned_keys")):
        return None
    fd, base = _open_parent(root, render["path"])
    if fd is None:
        return False
    try:
        node = opener(fd, base, "file", render)
        if node is None or not _mode_matches(node.identity, render.get("after_mode")):
            return False
        try:
            text = io.TextIOWrapper(io.BytesIO(node.data), encoding=locale.getpreferredencoding(False)).read()
            current = settings["parse"](text)
            keys = settings["parse"](json.dumps(render["owned_keys"]))
            if type(current) is not dict:
                return False
            settings["valid_owned"](keys)
            return not settings["detail"](current, keys)
        except (OSError, ValueError, TypeError, KeyError):
            return False
    finally:
        os.close(fd)


def hooks_owners(entries):
    return [entry["path"] for entry in entries
            if isinstance(entry.get("record"), dict)
            and (entry["record"].get("git_hooks") or {}).get("enabled") is True]


def _read_owner(entry, opener):
    path = entry["path"]
    parent, name = os.path.split(path)
    try:
        fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        return None
    _READS["parent"] = parent
    try:
        return opener(fd, name, "file", None)
    finally:
        os.close(fd)


# Every node a check read, per owner: (parent path, name, its identity, the
# parent's identity). After all checks the same names are looked at again; a
# change to any of them while the pass ran (a write moves ctime even when mtime
# is put back) makes that owner undecided, so nothing changed mid-pass passes.
_READS = {"parent": None, "owner": None, "log": {}}


def _recording(opener):
    def record(parent_fd, name, kind, expected=None):
        node = opener(parent_fd, name, kind, expected)
        if node is not None and _READS["owner"] is not None:
            _READS["log"].setdefault(_READS["owner"], []).append(
                (_READS["parent"], name, node.identity, node.parent_identity))
        return node
    return record


def _unchanged(owner):
    for parent, name, identity, parent_identity in _READS["log"].get(owner, []):
        try:
            if (_identity(os.lstat(parent)) != parent_identity
                    or _identity(os.lstat(parent + "/" + name)) != identity):
                return False
        except OSError:
            return False
    return True


def verify_owner_records(home, entries, mode="verify", opener=None):
    """mode "verify": every attachment_verify check before the managed hooks.
    mode "artifacts": exactly _attachment_verify_owner_artifacts OWNER HOME,
    which does not judge the owner file's mode, schema or location (its
    callers have); an unreadable record is its status 3."""
    if mode not in ("verify", "artifacts"):
        raise ValueError("unsupported verification mode: %s" % mode)
    opener = _recording(opener or default_opener)
    _READS["log"] = {}
    if mode == "artifacts":
        for entry in entries:
            entry["valid"] = entry["canonical"] = True
    failures = []
    pending = []
    for entry in entries:
        path = entry["path"]
        _READS["owner"] = path
        try:
            # _attachment_owner_json_valid: a regular JSON file (2), mode 0600 (3),
            # the schema (2); then the canonical location (2).
            node = _read_owner(entry, opener)
            if node is None:
                failures.append(_failure(path, "owner-file", 3 if mode == "artifacts" else 2))
                continue
            data = entry.get("data")
            if data is not None and data != node.data:
                failures.append(_failure(path, "undecided", 2, reason="owner bytes differ from the caller's"))
                continue
            try:
                record = json.loads(node.data.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                failures.append(_failure(path, "owner-file", 3 if mode == "artifacts" else 2))
                continue
            if mode == "verify" and stat.S_IMODE(node.identity[2]) != 0o600:
                failures.append(_failure(path, "owner-file", 3))
                continue
            if entry.get("valid") is not True or not isinstance(record, dict):
                failures.append(_failure(path, "schema", 2))
                continue
            if entry.get("canonical") is not True:
                failures.append(_failure(path, "canonical-path", 2))
                continue
            if entry.get("record") is not None and entry["record"] != record:
                failures.append(_failure(path, "undecided", 2, reason="owner record differs from the caller's"))
                continue
            entry["record"] = record
            if not _render_context_valid(record, home):
                failures.append(_failure(path, "render-context", 3))
                continue
            root = record["worktree_root"]
            if not os.path.isdir(root):
                failures.append(_failure(path, "worktree-root", 3, root=root))
                continue
            if not fs.canonical_dir(record["project_root"]) or not fs.canonical_dir(root):
                failures.append(_failure(path, "roots", 3, root=root))
                continue
            if fs.sha256_text(root) != record["worktree_id"]:
                failures.append(_failure(path, "ids", 3, root=root, worktree_id=record["worktree_id"]))
                continue
            pending.append((path, record))
        except (KeyError, TypeError, AttributeError):
            failures.append(_failure(path, "undecided", 3, reason="malformed owner record"))
    commons = fs.git_common_dirs(sorted(set(record["worktree_root"] for _, record in pending)))
    for path, record in pending:
        _READS["owner"] = path
        try:
            root = record["worktree_root"]
            common = commons.get(root)
            if common is None or fs.sha256_text(common) != record["checkout_id"]:
                failures.append(_failure(path, "ids", 3, root=root, checkout_id=record["checkout_id"]))
                continue
            if not _render_pairings_valid(record):
                failures.append(_failure(path, "render-pairings", 3, root=root))
                continue
            renders = record.get("renders") or []
            render_paths = set(render["path"] for render in renders)
            failed = False
            for artifact in record["artifacts"]:
                if artifact["path"] in render_paths:
                    continue
                exact = _artifact_exact(root, artifact, opener)
                if exact is None:
                    failures.append(_failure(path, "undecided", 3, relative=artifact["path"], root=root,
                                             reason="hardlinked file"))
                    failed = True
                    break
                if not exact:
                    failures.append(_failure(path, "artifact", 3, relative=artifact["path"],
                                             kind=artifact["kind"], root=root))
                    failed = True
                    break
            if failed:
                continue
            for render in renders:
                exact = _render_exact(root, render, opener)
                if exact is None:
                    failures.append(_failure(path, "undecided", 3, relative=render["path"], root=root,
                                             reason="owned value holds a float"))
                    break
                if not exact:
                    failures.append(_failure(path, "render", 3, relative=render["path"], root=root))
                    break
        except (KeyError, TypeError, AttributeError):
            failures.append(_failure(path, "undecided", 3, reason="malformed owner record"))
    _READS["owner"] = None
    failed = set(failure["owner"] for failure in failures)
    for entry in entries:
        if entry["path"] not in failed and not _unchanged(entry["path"]):
            failures.append(_failure(entry["path"], "undecided", 3, reason="changed during verification"))
    return failures


def verify_siblings(entries, owner, opener=None):
    """For each entry, in order, the checks the reconcile loop makes of a
    sibling owner file under scope current: a regular JSON file, never a
    symlink (2), mode 0600 (3), the schema verdict (2); then, only when its
    worktree root is still there (exists or is a symlink, as the shell's
    [ -e ] || [ -L ]), the canonical project and worktree roots and both ids
    (_attachment_validate_roots, _attachment_validate_ids). OWNER itself gets
    the file checks only: the caller verifies it in full. Each entry's
    "record" must be the caller's parse of the same file; any difference, or
    any change to a file read while the pass ran, is undecided. Returns
    (failures, kept): kept are the paths whose root is there, in order. The
    caller still makes the manifest, field, exclude and managed-hook checks."""
    opener = _recording(opener or default_opener)
    _READS["log"] = {}
    failures = []
    kept = []
    pending = []
    for entry in entries:
        path = entry["path"]
        _READS["owner"] = path
        try:
            node = _read_owner(entry, opener)
            if node is None:
                failures.append(_failure(path, "owner-file", 2))
                continue
            try:
                record = json.loads(node.data.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                failures.append(_failure(path, "owner-file", 2))
                continue
            if stat.S_IMODE(node.identity[2]) != 0o600:
                failures.append(_failure(path, "owner-file", 3))
                continue
            if entry.get("valid") is not True or not isinstance(record, dict):
                failures.append(_failure(path, "schema", 2))
                continue
            if entry.get("record") is None or entry["record"] != record:
                failures.append(_failure(path, "undecided", 2, reason="owner record differs from the caller's"))
                continue
            root = record["worktree_root"]
            if not isinstance(root, str) or not os.path.lexists(root):
                continue
            kept.append(path)
            if path == owner:
                continue
            if not fs.canonical_dir(record["project_root"]) or not fs.canonical_dir(root):
                failures.append(_failure(path, "roots", 2, root=root))
                continue
            if fs.sha256_text(root) != record["worktree_id"]:
                failures.append(_failure(path, "ids", 2, root=root, worktree_id=record["worktree_id"]))
                continue
            pending.append((path, record))
        except (KeyError, TypeError, AttributeError):
            failures.append(_failure(path, "undecided", 3, reason="malformed owner record"))
    commons = fs.git_common_dirs(sorted(set(record["worktree_root"] for _, record in pending)))
    for path, record in pending:
        try:
            common = commons.get(record["worktree_root"])
            if common is None or fs.sha256_text(common) != record["checkout_id"]:
                failures.append(_failure(path, "ids", 2, root=record["worktree_root"],
                                         checkout_id=record["checkout_id"]))
        except (KeyError, TypeError, AttributeError):
            failures.append(_failure(path, "undecided", 3, reason="malformed owner record"))
    _READS["owner"] = None
    failed = set(failure["owner"] for failure in failures)
    for entry in entries:
        if entry["path"] not in failed and not _unchanged(entry["path"]):
            failures.append(_failure(entry["path"], "undecided", 3, reason="changed during verification"))
    return failures, kept


def load_modules(fs_path):
    """attachment_fs.py, loaded from its absolute payload path."""
    import importlib.util
    import sys as _sys
    _sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("trellis_attachment_fs", fs_path)
    fs_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fs_module)
    return fs_module


def main(argv):
    # VERB HOME FS: entries as JSON on stdin, the settings_owned_json
    # program in TRELLIS_SETTINGS_OWNED_JSON_PROGRAM.
    # verify-owner-records: exit 0 when every owner passed, printing the owners
    # whose managed hooks the caller must still verify; 10 on any failure or
    # when the check cannot run, printing the failures as JSON lines.
    # owner-verdicts: exit 0 having printed "0<TAB>path" or "1<TAB>path" for
    # every owner in order; 10 when the check cannot run.
    # sibling-identity HOME FS OWNER: verify_siblings; exit 0 printing the kept
    # paths as one JSON array, 10 on any failure or when it cannot run.
    verbs = {"verify-owner-records": 3, "owner-verdicts": 3, "sibling-identity": 4}
    if not argv or verbs.get(argv[0]) != len(argv):
        return 2
    try:
        home, fs_path = argv[1:3]
        load(load_modules(fs_path), os.environ["TRELLIS_SETTINGS_OWNED_JSON_PROGRAM"])
        entries = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        if not isinstance(entries, list):
            return 10
        here = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            if argv[0] == "sibling-identity":
                failures, kept = verify_siblings(entries, argv[3])
            else:
                failures = verify_owner_records(home, entries,
                                                "artifacts" if argv[0] == "owner-verdicts" else "verify")
        finally:
            os.fchdir(here)
            os.close(here)
    except Exception as error:  # any surprise is a miss, never a pass
        sys.stderr.write("owner_verify: %s\n" % error)
        return 10
    out = sys.stdout
    if argv[0] == "sibling-identity":
        if failures:
            for failure in failures:
                sys.stderr.write(json.dumps(failure, sort_keys=True) + "\n")
            return 10
        out.write(json.dumps(kept) + "\n")
        return 0
    if argv[0] == "owner-verdicts":
        failed = set(failure["owner"] for failure in failures)
        for entry in entries:
            out.write("%d\t%s\n" % (1 if entry["path"] in failed else 0, entry["path"]))
        return 0
    if failures:
        for failure in failures:
            out.write(json.dumps(failure, sort_keys=True) + "\n")
        return 10
    for path in hooks_owners(entries):
        out.write(path + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
