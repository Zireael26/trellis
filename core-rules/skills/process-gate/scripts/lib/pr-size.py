#!/usr/bin/env python3
"""Frame isolated, rename-aware line counts and base-side classification metadata."""

import errno
import os
import re
import stat
import subprocess
import sys
import tempfile


def git(*args, data=None, env=None):
    return subprocess.run(
        [b"git", *args], input=data, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, check=True, env=env,
    ).stdout


def git_c_quote(path):
    # The alternates variable is a path list; quote separators and raw bytes.
    return '"' + ''.join(chr(c) if 32 <= c <= 126 and c not in (34, 92)
                         else "\\%03o" % c for c in path) + '"'


def parse_raw(data):
    parts = data.split(b"\0")
    if parts.pop() != b"":
        raise ValueError("incomplete raw diff")
    records = []
    i = 0
    while i < len(parts):
        meta = parts[i]
        i += 1
        if not meta.startswith(b":"):
            raise ValueError("invalid raw diff header")
        old_mode, new_mode, old_oid, new_oid, status = meta[1:].split(b" ")
        old_path = parts[i]
        i += 1
        if status[:1] in (b"R", b"C"):
            new_path = parts[i]
            i += 1
        else:
            new_path = old_path
        if not old_path or not new_path or status[:1] not in (b"A", b"C", b"D", b"M", b"R", b"T"):
            raise ValueError("invalid raw diff path or status")
        records.append((old_mode, new_mode, old_oid, new_oid, old_path, new_path))
    return records


def base_attributes(paths, env):
    if not paths:
        return {}
    raw = git(b"check-attr", b"--cached", b"-z", b"--stdin", b"linguist-generated",
              data=b"\0".join(paths) + b"\0", env=env).split(b"\0")
    if raw.pop() != b"" or len(raw) != len(paths) * 3:
        raise ValueError("invalid attribute output")
    result = {}
    for i in range(0, len(raw), 3):
        path, attr, value = raw[i:i + 3]
        if path != paths[i // 3] or attr != b"linguist-generated":
            raise ValueError("invalid attribute record")
        result[path] = value in (b"set", b"true")
    return result


MARKER = re.compile(rb"@generated\b|Code generated .+ DO NOT EDIT\.")


def has_marker(prefix):
    first_lines = b"\n".join(re.split(rb"\r\n|\r|\n", prefix, maxsplit=20)[:20])
    return b"\0" not in first_lines and bool(MARKER.search(first_lines))


def inspect_blobs(oids, env):
    """Batch the binary sniff, bounded marker probe, shebang and bare-CR scan."""
    result = {}
    if not oids:
        return result
    with subprocess.Popen([b"git", b"cat-file", b"--batch"], env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL) as proc:
        for oid in sorted(oids):
            proc.stdin.write(oid + b"\n")
            proc.stdin.flush()
            header = proc.stdout.readline().split()
            if len(header) != 3 or header[0] != oid or header[1] != b"blob":
                raise ValueError("invalid blob inspection header")
            size = int(header[2])
            if size < 0:
                raise ValueError("invalid blob size")
            first = proc.stdout.read(min(size, 8192))
            if len(first) != min(size, 8192):
                raise ValueError("truncated blob inspection")
            binary = b"\0" in first
            shebang = first.startswith(b"#!")
            prefix = bytearray() if binary else bytearray(first)
            left = size
            carry = b""
            found = False
            chunk = first
            while left:
                if not chunk:
                    raise ValueError("truncated blob inspection")
                left -= len(chunk)
                if not found:
                    cr_chunk = carry + chunk
                    carry = b"\r" if cr_chunk.endswith(b"\r") else b""
                    if carry:
                        cr_chunk = cr_chunk[:-1]
                    found = b"\r" in cr_chunk.replace(b"\r\n", b"")
                if left:
                    chunk = proc.stdout.read(min(left, 65536))
                    if not binary and len(prefix) < 65536:
                        prefix.extend(chunk[:65536 - len(prefix)])
            if proc.stdout.read(1) != b"\n":
                raise ValueError("invalid blob inspection terminator")
            result[oid] = (binary, False if binary else has_marker(bytes(prefix)),
                           found or bool(carry), shebang)
        proc.stdin.close()
        if proc.wait() != 0:
            raise ValueError("blob inspection failed")
    return result


def present(mode):
    return mode != b"000000"


def regular(mode):
    return mode in (b"100644", b"100755")


CODE_EXTENSIONS = frozenset(b"js jsx mjs cjs ts tsx mts cts py pyi rb go rs c h cc cpp cxx hpp hxx m mm java kt kts swift cs scala sc sh bash zsh php lua sql pl pm ex exs erl hrl hs fs fsx dart vue svelte proto graphql".split())


def code_path(path):
    name = path.rsplit(b"/", 1)[-1]
    return b"." in name and name.rsplit(b".", 1)[-1].lower() in CODE_EXTENSIONS


def parse_numstat(data):
    parts = data.split(b"\0")
    if parts.pop() != b"":
        raise ValueError("incomplete numstat")
    result = {}
    i = 0
    while i < len(parts):
        adds, dels, path = parts[i].split(b"\t", 2)
        i += 1
        old = path
        if not path:
            old, path = parts[i:i + 2]
            i += 2
        if not old or not path or not adds.isdigit() or not dels.isdigit():
            raise ValueError("invalid text numstat")
        key = (old, path)
        prior = result.get(key, (0, 0))
        result[key] = (prior[0] + int(adds), prior[1] + int(dels))
    return result


def normalized_blob(oid, env):
    """Write a temporary blob with bare CR changed to LF, preserving CRLF."""
    source = subprocess.Popen([b"git", b"cat-file", b"blob", oid], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    sink = subprocess.Popen([b"git", b"hash-object", b"-w", b"--stdin"], env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    try:
        carry = b""
        while True:
            chunk = source.stdout.read(65536)
            if not chunk:
                break
            chunk = carry + chunk
            carry = b"\r" if chunk.endswith(b"\r") else b""
            if carry:
                chunk = chunk[:-1]
            sink.stdin.write(re.sub(rb"\r(?!\n)", b"\n", chunk))
        if carry:
            sink.stdin.write(b"\n")
        source.stdout.close()
        sink.stdin.close()
        result = sink.stdout.read().strip()
        if source.wait() != 0 or sink.wait() != 0 or not result:
            raise ValueError("cannot normalize CR blob")
        return result
    finally:
        for proc in (source, sink):
            if proc.poll() is None:
                proc.kill()
                proc.wait()


def synthetic_trees(records, eligible, cr_oids, env):
    """Keep original rename pairing while diffing normalized blobs in one batch."""
    normalized = {}
    trees = []
    for side in (0, 1):
        index_env = dict(env)
        index_env["GIT_INDEX_FILE"] = os.fsdecode(os.path.join(os.fsencode(env["GIT_DIR"]),
                                                               ("cr-index-%d" % side).encode()))
        git(b"read-tree", b"--empty", env=index_env)
        entries = []
        for i, record in enumerate(records):
            if not eligible[i]:
                continue
            mode, oid = record[side], record[side + 2]
            if not present(mode):
                continue
            if mode == b"160000":
                oid = git(b"hash-object", b"-w", b"--stdin",
                          data=b"Subproject commit " + oid + b"\n", env=env).strip()
            elif oid in cr_oids:
                if oid not in normalized:
                    normalized[oid] = normalized_blob(oid, env)
                oid = normalized[oid]
            entries.append(b"100644 " + oid + b"\t" + (b"pg-%08d" % i) + b"\0")
        if entries:
            git(b"update-index", b"-z", b"--index-info", data=b"".join(entries), env=index_env)
        trees.append(git(b"write-tree", env=index_env).strip())
    return trees, normalized


def hash_stream(stream, env):
    proc = subprocess.Popen([b"git", b"hash-object", b"-w", b"--stdin"], env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    try:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            proc.stdin.write(chunk)
        proc.stdin.close()
        oid = proc.stdout.read().strip()
        if proc.wait() != 0 or not oid:
            raise ValueError("cannot snapshot worktree file")
        return oid
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def worktree_entry(root, path, index_mode, env):
    """Hash one tracked worktree file into the private object store, no symlink traversal."""
    parts = path.split(b"/")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            try:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError as exc:
                if exc.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
                    return None
                raise
            os.close(fd)
            fd = next_fd
        try:
            info = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(parts[-1], dir_fd=fd)
            return b"120000", git(b"hash-object", b"-w", b"--stdin", data=target, env=env).strip()
        if stat.S_ISREG(info.st_mode):
            file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(file_fd, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise ValueError("worktree file changed type")
                oid = hash_stream(stream, env)
            mode = b"100755" if info.st_mode & 0o111 else b"100644"
            return mode, oid
        if index_mode == b"160000" and stat.S_ISDIR(info.st_mode):
            child = os.path.join(root, path)
            child_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            top = git(b"-C", child, b"rev-parse", b"--show-toplevel", env=child_env)[:-1]
            top_info = os.stat(top)
            if (top_info.st_dev, top_info.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError("unavailable worktree submodule")
            oid = git(b"-C", child, b"rev-parse", b"--verify", b"HEAD", env=child_env).strip()
            return b"160000", oid
        raise ValueError("unsupported tracked worktree file")
    finally:
        os.close(fd)


def worktree_tree(base, root, env):
    """Make a private tree of the single-revision tracked working-tree diff."""
    tracked = {}
    for record in git(b"-C", root, b"ls-files", b"--stage", b"-z").split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, oid, stage = meta.split(b" ")
        if stage != b"0":
            raise ValueError("unmerged index")
        tracked[path] = (mode, oid)
    env = dict(env)
    env["GIT_INDEX_FILE"] = os.fsdecode(os.path.join(os.fsencode(env["GIT_DIR"]), b"worktree-index"))
    git(b"read-tree", b"--empty", env=env)
    if tracked:
        index = b"".join(mode + b" " + oid + b"\t" + path + b"\0"
                         for path, (mode, oid) in sorted(tracked.items()))
        git(b"update-index", b"-z", b"--index-info", data=index, env=env)
    scan_env = dict(env)
    scan_env["GIT_WORK_TREE"] = os.fsdecode(root)
    try:
        # The original worktree's Git config, info attributes and clean filters
        # cannot participate in discovery, just as they cannot in counting.
        raw = parse_raw(git(b"--attr-source=" + base, b"diff", b"--raw", b"-z", b"--no-abbrev",
                            b"--no-renames", b"--no-ext-diff", b"--no-textconv", base, env=scan_env))
        paths = sorted({record[5] for record in raw})
        old_records = {record[5]: record for record in raw}
        scanned_all = False
    except subprocess.CalledProcessError:
        # Older Git without --attr-source: hash every tracked worktree path,
        # rather than consulting untrusted worktree or info attributes.
        old_records = {}
        for record in git(b"ls-tree", b"-rz", b"--full-tree", base, env=env).split(b"\0"):
            if not record:
                continue
            meta, path = record.split(b"\t", 1)
            mode, _, oid = meta.split(b" ")
            old_records[path] = (mode, mode, oid, oid, path, path)
        paths = sorted(set(tracked) | set(old_records))
        scanned_all = True
    updates = []
    dirty = []
    for path in paths:
        # Remove first so file/directory replacements do not conflict.
        updates.append(b"0 " + b"0" * len(base) + b"\t" + path + b"\0")
    for path in paths:
        if path in tracked:
            entry = worktree_entry(root, path, tracked[path][0], env)
            if entry is not None:
                mode, oid = entry
                old = old_records.get(path)
                if old and mode == old[0] == b"160000" and oid == old[2]:
                    # In a full scan, check that this unchanged-HEAD submodule
                    # is dirty; otherwise the raw diff already established it.
                    changed = True
                    if scanned_all:
                        child_env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
                        changed = bool(git(b"-C", os.path.join(root, path), b"status", b"--porcelain",
                                           b"--untracked-files=no", env=child_env))
                    if changed:
                        dirty.append((old[0], mode, old[2], oid, old[4], path))
                updates.append(mode + b" " + oid + b"\t" + path + b"\0")
    if updates:
        git(b"update-index", b"-z", b"--index-info", data=b"".join(updates), env=env)
    return git(b"write-tree", env=env).strip(), dirty


def main():
    range_arg, base, head = map(os.fsencode, sys.argv[1:4])
    object_dir = os.path.abspath(git(b"rev-parse", b"--git-path", b"objects").rstrip(b"\n"))
    try:
        object_format = git(b"rev-parse", b"--show-object-format").strip()
    except subprocess.CalledProcessError:
        object_format = b"sha1"
    with tempfile.TemporaryDirectory(prefix="pg-pr-size-") as tmp:
        tmp = os.fsencode(tmp)
        repo = os.path.join(tmp, b"repo.git")
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(HOME=os.fsdecode(tmp), XDG_CONFIG_HOME=os.fsdecode(tmp),
                   GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_ATTR_NOSYSTEM="1", LC_ALL="C")
        init = [b"init", b"--bare", b"--quiet", b"--template="]
        if object_format != b"sha1":
            init.append(b"--object-format=" + object_format)
        git(*init, repo, env=env)
        # Git's --text does not force numeric numstat for NUL blobs. This
        # private diff-only attribute makes numstat numeric without trusting
        # the checkout's attributes; it does not set linguist-generated.
        info = os.path.join(repo, b"info")
        os.makedirs(info, exist_ok=True)
        with open(os.path.join(info, b"attributes"), "wb") as attr_file:
            attr_file.write(b"* diff\n")
        env["GIT_DIR"] = os.fsdecode(repo)
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = git_c_quote(object_dir)
        git(b"read-tree", base, env=env)
        dirty = []
        if b".." in range_arg:
            target = head
        else:
            root = git(b"rev-parse", b"--show-toplevel")[:-1]
            target, dirty = worktree_tree(base, root, env)
        raw = git(b"diff", b"--raw", b"-z", b"--no-abbrev", b"--find-renames", b"--text",
                  b"--no-ext-diff", b"--no-textconv", base, target, env=env)
        records = parse_raw(raw) + dirty
        dirty_paths = {record[5] for record in dirty}
        paths = sorted({path for record in records for path in record[4:6]})
        attrs = base_attributes(paths, env)
        oids = {oid for record in records for mode, oid in ((record[0], record[2]), (record[1], record[3]))
                if present(mode) and mode != b"160000"}
        inspected = inspect_blobs(oids, env)

        def info(mode, oid):
            if not present(mode) or mode == b"160000":
                return False, False, False, False
            return inspected[oid]

        metadata = []
        cr_oids = set()
        for old_mode, new_mode, old_oid, new_oid, old, new in records:
            old_binary, old_marker, old_cr, old_shebang = info(old_mode, old_oid)
            new_binary, new_marker, new_cr, new_shebang = info(new_mode, new_oid)
            binary = old_binary or new_binary
            code_binary = binary and (code_path(old) or code_path(new) or
                                      (regular(old_mode) and old_shebang) or
                                      (regular(new_mode) and new_shebang))
            eligible = not binary or code_binary
            metadata.append((old_marker, new_marker, binary, code_binary, eligible))
            if eligible:
                if old_cr:
                    cr_oids.add(old_oid)
                if new_cr:
                    cr_oids.add(new_oid)
        if cr_oids:
            # Original raw records choose renames. Synthetic paths keep those
            # exact pairs together when normalizing CR changes similarity.
            (old_tree, new_tree), normalized = synthetic_trees(records, [item[4] for item in metadata], cr_oids, env)
            numstat = git(b"diff", b"--numstat", b"-z", b"--text", b"--no-renames",
                          b"--no-ext-diff", b"--no-textconv", old_tree, new_tree, env=env)
            expected = {(b"pg-%08d" % i, b"pg-%08d" % i) for i, item in enumerate(metadata) if item[4]}
        else:
            numstat = git(b"diff", b"--numstat", b"-z", b"--text", b"--find-renames",
                          b"--no-ext-diff", b"--no-textconv", base, target, env=env)
            expected = {(record[4], record[5]) for record in records}
        stats = parse_numstat(numstat)
        if not set(stats).issubset(expected):
            raise ValueError("numstat paths disagree with raw diff")

        out = sys.stdout.buffer
        for i, (old_mode, new_mode, old_oid, new_oid, old, new) in enumerate(records):
            old_marker, new_marker, binary, code_binary, eligible = metadata[i]
            key = (b"pg-%08d" % i, b"pg-%08d" % i) if cr_oids else (old, new)
            adds, dels = stats.get(key, (0, 0))
            if key not in stats and eligible and new not in dirty_paths:
                old_normal = normalized.get(old_oid, old_oid) if cr_oids else old_oid
                new_normal = normalized.get(new_oid, new_oid) if cr_oids else new_oid
                same_type = (old_mode == b"160000") == (new_mode == b"160000")
                if not (present(old_mode) and present(new_mode) and same_type and old_normal == new_normal):
                    raise ValueError("missing numstat record")
            if new in dirty_paths and old_mode == new_mode == b"160000":
                adds, dels = 1, 1
            binary_lines = adds + dels if code_binary else 0
            add_field, del_field = (b"-", b"-") if binary else (str(adds).encode(), str(dels).encode())
            old_generated = regular(old_mode) and (attrs[old] or old_marker)
            new_generated = regular(new_mode) and (attrs[new] or new_marker)
            marker_only = regular(new_mode) and new_marker and not attrs[new]
            fields = (add_field, del_field, old, new, b"1" if present(old_mode) else b"0",
                      b"1" if present(new_mode) else b"0", b"1" if old_generated else b"0",
                      b"1" if new_generated else b"0", b"1" if marker_only else b"0",
                      str(binary_lines).encode())
            out.write(b"\0".join(fields) + b"\0")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, IndexError, subprocess.SubprocessError) as exc:
        print(f"pr-size: metadata unavailable: {exc}", file=sys.stderr)
        sys.exit(1)
