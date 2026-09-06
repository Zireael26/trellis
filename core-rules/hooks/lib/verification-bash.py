#!/usr/bin/env python3
"""Explicit, isolated syntax.bash v1 adapter; not a generic command cache.

Host libraries and effective-UID state are trusted. Hashes detect drift and
corruption, not same-user forgery or an independently attested OS toolchain.
"""
import sys

_LOADED_CODE = sys._getframe().f_code

import argparse
import base64
import hashlib
import json
import marshal
import os
from pathlib import Path
import platform
import re
import shutil
import selectors
import stat
import subprocess
import time
import types
import uuid

ADAPTER = "syntax.bash"
VERSION = 1
STORE = "trellis-bash-verification-v1"
RECORD_CAP = 1048576
OUTPUT_CAP = 65536
INPUT_FILE_CAP = 16 * 1024 * 1024
INPUT_TOTAL_CAP = 64 * 1024 * 1024
ENV = {"LC_ALL": "C"}
GIT_ENV = {"LC_ALL": "C", "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
           "GIT_OPTIONAL_LOCKS": "0"}


class Unavailable(Exception):
    def __init__(self, reason, exit_status=None):
        super().__init__(reason)
        self.exit_status = exit_status


def remaining(end):
    value = end - time.monotonic()
    if value <= 0:
        raise Unavailable("deadline_exceeded")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def normalized(code):
    return code.replace(co_filename=ADAPTER, co_consts=tuple(
        normalized(item) if isinstance(item, types.CodeType) else item for item in code.co_consts))


def read_bytes(fd, end, cap=None):
    chunks, size = [], 0
    while True:
        remaining(end)
        chunk = os.read(fd, 65536 if cap is None else min(65536, cap - size + 1))
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        if cap is not None and size > cap:
            raise ValueError("size cap")
        chunks.append(chunk)


def file_digest(path, end):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not regular")
        value = hashlib.sha256()
        while True:
            remaining(end)
            chunk = os.read(fd, 65536)
            if not chunk:
                return value.hexdigest()
            value.update(chunk)
    finally:
        os.close(fd)


def runtime(end):
    python = os.path.realpath(sys.executable)
    bash = os.path.realpath("/bin/bash")
    return {"bash": {"path": bash, "sha256": file_digest(bash, end)},
            "python": {"path": python, "sha256": file_digest(python, end), "version": sys.version},
            "platform": list(platform.uname()),
            "implementation": {"source": file_digest(os.path.realpath(__file__), end),
                               "loaded": digest(marshal.dumps(normalized(_LOADED_CODE)))}}


def git_call(git, cwd, args, end, optional=False):
    try:
        result = subprocess.run([git, "-C", cwd, *args], env=GIT_ENV,
                                stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=remaining(end))
    except subprocess.TimeoutExpired:
        raise Unavailable("deadline_exceeded") from None
    if result.returncode and not optional:
        raise Unavailable("dependency_unavailable")
    return result.stdout if result.returncode == 0 else b""


def roots(git, cwd, end):
    root = os.path.realpath(os.fsdecode(git_call(git, cwd, ["rev-parse", "--show-toplevel"], end)).strip())
    common = os.fsdecode(git_call(git, cwd, ["rev-parse", "--git-common-dir"], end)).strip()
    common = os.path.realpath(os.path.join(cwd, common))
    if os.path.commonpath([cwd, root]) != root:
        raise Unavailable("unsafe_input")
    return {"worktree": root, "common": common}


def snapshot(git, root, end):
    raw = git_call(git, root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.sh"], end)
    files, total = [], 0
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in sorted(set(raw.split(b"\0")) - {b""}):
            remaining(end)
            try:
                name = name.decode("utf-8")
                parts = name.split("/")
                if any(not p or p in (".", "..") for p in parts) or any(ord(c) < 32 or ord(c) == 127 for c in name):
                    raise ValueError("unsafe name")
                parent = os.dup(root_fd)
                try:
                    for part in parts[:-1]:
                        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                        os.close(parent)
                        parent = child
                    fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    try:
                        info = os.fstat(fd)
                        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
                            raise ValueError("not readable regular file")
                        data = read_bytes(fd, end, min(INPUT_FILE_CAP, INPUT_TOTAL_CAP - total))
                        total += len(data)
                    finally:
                        os.close(fd)
                finally:
                    os.close(parent)
            except FileNotFoundError:
                continue  # Tracked deletions are absent from the present-file set.
            except (OSError, ValueError):
                raise Unavailable("unsafe_input") from None
            files.append((name, digest(data), data))
            if len(encoded([[n, h] for n, h, _ in files])) > RECORD_CAP // 2:
                raise Unavailable("unsafe_input")
    finally:
        os.close(root_fd)
    return files


def admitted(fd, directory):
    info = os.fstat(fd)
    return (info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600)
            and (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)))


def open_store(common):
    parent = os.open(common, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            os.mkdir(STORE, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
        fd = os.open(STORE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        if not admitted(fd, True):
            os.close(fd)
            raise OSError("unsafe store")
        return fd
    finally:
        os.close(parent)


def create_file(parent, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        if not admitted(fd, False):
            raise OSError("unsafe created mode")
        with os.fdopen(os.dup(fd), "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        os.unlink(name, dir_fd=parent)
        raise
    finally:
        os.close(fd)


def valid_record(record, identity):
    if type(record) is not dict or set(record) != {"adapter", "version", "identity", "key", "exit_status", "executed", "harness", "head", "started_ns", "finished_ns", "output"}:
        return False
    if (record["adapter"] != ADAPTER or type(record["version"]) is not int or record["version"] != VERSION
            or type(record["exit_status"]) is not int or record["exit_status"] != 0 or record["executed"] is not True
            or type(record["harness"]) is not str or record["harness"] not in ("claude", "codex", "pi")
            or encoded(record["identity"]) != encoded(identity) or record["key"] != digest(encoded(identity))):
        return False
    if record["head"] is not None and (type(record["head"]) is not str or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", record["head"])):
        return False
    if any(type(record[k]) is not int or not 0 < record[k] < 10**20 for k in ("started_ns", "finished_ns")) or record["started_ns"] > record["finished_ns"]:
        return False
    output = record["output"]
    if type(output) is not dict or set(output) != {"base64", "bytes", "sha256"} or type(output["base64"]) is not str or type(output["bytes"]) is not int or not 0 <= output["bytes"] <= OUTPUT_CAP:
        return False
    try:
        data = base64.b64decode(output["base64"], validate=True)
    except ValueError:
        return False
    return len(data) == output["bytes"] and digest(data) == output["sha256"]


def records(fd, prefix, end):
    names = []
    with os.scandir(fd) as entries:
        for entry in entries:
            remaining(end)
            if re.fullmatch(re.escape(prefix) + r"\.[0-9]{20}\.[0-9a-f]{32}\.json", entry.name):
                names.append(entry.name)
                if len(names) > 100:
                    raise Unavailable("unsafe_storage")
    return sorted(names, reverse=True)


def strict_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate key")
        value[key] = item
    return value


def reject_constant(value):
    raise ValueError("nonfinite constant")


def load_record(fd, name, end):
    try:
        item = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            if not admitted(item, False) or os.fstat(item).st_size > RECORD_CAP:
                return None
            return json.loads(read_bytes(item, end, RECORD_CAP), object_pairs_hook=strict_object,
                              parse_constant=reject_constant)
        finally:
            os.close(item)
    except (OSError, ValueError, RecursionError):
        return None


def parse_file(path, end):
    process = subprocess.Popen(["/bin/bash", "--noprofile", "--norc", "-n", "--", path],
                               env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                if not selector.select(remaining(end)):
                    raise Unavailable("deadline_exceeded")
                chunk = os.read(process.stdout.fileno(), min(65536, OUTPUT_CAP - len(output) + 1))
                if not chunk:
                    break
                if len(output) + len(chunk) > OUTPUT_CAP:
                    raise Unavailable("output_limit", process.poll())
                output.extend(chunk)
        return process.wait(timeout=remaining(end)), bytes(output)
    except subprocess.TimeoutExpired:
        raise Unavailable("deadline_exceeded", process.poll()) from None
    except Unavailable as exc:
        if exc.exit_status is None:
            exc.exit_status = process.poll()
        raise
    finally:
        # Only this invocation's parser is owned; never signal a process group.
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def cleanup(fd, name):
    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
    try:
        for entry in os.listdir(child):
            os.unlink(entry, dir_fd=child)
    finally:
        os.close(child)
    os.rmdir(name, dir_fd=fd)


def result(status, exit_status=None, receipt=None, reason=None):
    return {"adapter": ADAPTER, "version": VERSION, "status": status, "exit_status": exit_status,
            "receipt": receipt, "reason": reason,
            "diagnostic": "Bash syntax check failed." if exit_status not in (None, 0) else (
                "Verification persistence failed." if reason == "persistence_failed" else
                ("Verification unavailable." if reason else ""))}


def verify(cwd, harness):
    end = time.monotonic() + 30
    fd, scratch, observed = None, None, None
    answer = result("unavailable", reason="dependency_unavailable")
    try:
        if not sys.flags.isolated:
            raise Unavailable("dependency_unavailable")
        if not os.path.isabs(cwd):
            raise Unavailable("unsafe_input")
        cwd = os.path.realpath(cwd)
        git = shutil.which("git")
        if not git:
            raise Unavailable("dependency_unavailable")
        git = os.path.abspath(git)
        binding = roots(git, cwd, end)
        before = runtime(end)
        files = snapshot(git, binding["worktree"], end)
        if not files:
            raise Unavailable("no_inputs")
        identity = {"adapter": ADAPTER, "version": VERSION, "roots": binding, "runtime": before,
                    "inputs": [[n, h] for n, h, _ in files]}
        if len(encoded(identity)) > RECORD_CAP // 2:
            raise Unavailable("unsafe_input")
        try:
            fd = open_store(binding["common"])
        except OSError:
            raise Unavailable("unsafe_storage") from None
        prefix = digest(encoded(binding))[0:32]
        try:
            names = records(fd, prefix, end)
        except OSError:
            raise Unavailable("unsafe_storage") from None
        hit = next((name for name in names if valid_record(load_record(fd, name, end), identity)), None)
        started = time.time_ns()
        output = b""
        if not hit:
            name = "scratch-" + uuid.uuid4().hex
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
                scratch = name
                child = os.open(scratch, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError:
                raise Unavailable("unsafe_storage") from None
            try:
                try:
                    if not admitted(child, True):
                        raise Unavailable("unsafe_storage")
                except OSError:
                    raise Unavailable("unsafe_storage") from None
                for index, (_, _, data) in enumerate(files):
                    remaining(end)
                    try:
                        create_file(child, str(index), data)
                    except OSError:
                        raise Unavailable("unsafe_storage") from None
                    observed, text = parse_file(os.path.join(binding["common"], STORE, scratch, str(index)), end)
                    if len(output) + len(text) > OUTPUT_CAP:
                        raise Unavailable("output_limit", observed)
                    output += text
                    if observed != 0:
                        break
            finally:
                os.close(child)
        after_files = snapshot(git, binding["worktree"], end)
        if [[n, h] for n, h, _ in after_files] != identity["inputs"] or roots(git, cwd, end) != binding:
            raise Unavailable("source_drift")
        if runtime(end) != before:
            raise Unavailable("runtime_drift")
        if scratch:
            try:
                cleanup(fd, scratch)
            except OSError:
                raise Unavailable("cleanup_failed") from None
            scratch = None
        remaining(end)
        if hit:
            answer = result("reused", 0, os.path.join(binding["common"], STORE, hit))
        else:
            answer = result("executed", observed)
            if observed == 0:
                head = git_call(git, cwd, ["rev-parse", "--verify", "HEAD"], end, optional=True).decode().strip() or None
                record = {"adapter": ADAPTER, "version": VERSION, "identity": identity, "key": digest(encoded(identity)),
                          "exit_status": 0, "executed": True, "harness": harness, "head": head,
                          "started_ns": started, "finished_ns": time.time_ns(),
                          "output": {"base64": base64.b64encode(output).decode(), "bytes": len(output), "sha256": digest(output)}}
                payload = encoded(record)
                if len(payload) > RECORD_CAP or not valid_record(record, identity):
                    raise Unavailable("unsafe_input")
                name = f"{prefix}.{record['finished_ns']:020d}.{uuid.uuid4().hex}.json"
                answer = result("executed", 0, os.path.join(binding["common"], STORE, name))
                encoded(answer)
                remaining(end)
                staging = "scratch-" + uuid.uuid4().hex
                staged = reserved = False
                try:
                    for old in names[19:]:
                        previous = load_record(fd, old, end)
                        if (type(previous) is dict and type(previous.get("identity")) is dict
                                and previous["identity"].get("roots") == binding
                                and valid_record(previous, previous["identity"])):
                            os.unlink(old, dir_fd=fd)
                    create_file(fd, staging, payload)
                    staged = True
                    # Reserve a unique empty destination with O_EXCL. It is not
                    # evidence; replace only this invocation's reservation, never
                    # a prior record. Rename consumes staging, so publication is
                    # the last filesystem operation, with no post-pass cleanup.
                    create_file(fd, name, b"")
                    reserved = True
                    remaining(end)
                    os.replace(staging, name, src_dir_fd=fd, dst_dir_fd=fd)
                    staged = reserved = False
                except OSError:
                    answer = result("executed", observed, reason="persistence_failed")
                finally:
                    try:
                        if staged:
                            os.unlink(staging, dir_fd=fd)
                        if reserved:
                            os.unlink(name, dir_fd=fd)
                    except OSError:
                        raise Unavailable("cleanup_failed") from None
    except Unavailable as exc:
        if exc.exit_status is not None:
            observed = exc.exit_status
        answer = result("unavailable", observed, reason=str(exc))
    except OSError:
        answer = result("unavailable", observed, reason="dependency_unavailable")
    finally:
        if scratch and fd is not None:
            try:
                cleanup(fd, scratch)
            except OSError:
                answer = result("unavailable", observed, reason="cleanup_failed")
        if fd is not None:
            os.close(fd)
    return answer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--harness", choices=("claude", "codex", "pi"), required=True)
    args = parser.parse_args()
    answer = verify(args.cwd, args.harness)
    print(encoded(answer).decode())
    return 3 if answer["status"] == "unavailable" else answer["exit_status"]


if __name__ == "__main__":
    raise SystemExit(main())
