#!/usr/bin/env python3
"""FD-pinned publication primitives for materialized scheduled tasks.

The materializer creates a complete task generation privately, then this helper
opens the fleet directory once with O_DIRECTORY|O_NOFOLLOW.  Every check,
output migration, and atomic rename is relative to that retained descriptor.
Pathnames are only basenames after the parent is pinned.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import platform
import stat
import sys
from typing import NoReturn

EX_CONFLICT = 3
EX_STATE = 4
EX_UNAVAILABLE = 5


class PublishError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code


def die(code: int, message: str) -> NoReturn:
    print(f"trellis task: {message}", file=sys.stderr)
    raise SystemExit(code)


def directory_flags() -> int:
    required = ("O_DIRECTORY", "O_NOFOLLOW")
    if any(not hasattr(os, flag) for flag in required):
        raise PublishError(EX_UNAVAILABLE, "kernel lacks O_DIRECTORY|O_NOFOLLOW required for task publication")
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


def require_basename(value: str, label: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."}:
        raise PublishError(EX_STATE, f"{label} must be a nonempty basename")
    if "/" in value or "\\" in value or "\x00" in value or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise PublishError(EX_STATE, f"{label} is not a safe basename")
    return value


def parse_identity(value: str, label: str) -> tuple[int, int]:
    parts = value.split(":")
    if len(parts) != 2 or any(not part.isdecimal() for part in parts):
        raise PublishError(EX_STATE, f"{label} is not a valid directory identity")
    device, inode = (int(part) for part in parts)
    if device < 0 or inode <= 0:
        raise PublishError(EX_STATE, f"{label} is not a valid directory identity")
    return device, inode


def identity_for_stat(st: os.stat_result) -> tuple[int, int]:
    if not stat.S_ISDIR(st.st_mode):
        raise PublishError(EX_STATE, "expected a real directory")
    return st.st_dev, st.st_ino


def identity_text(st: os.stat_result) -> str:
    device, inode = identity_for_stat(st)
    return f"{device}:{inode}"


def verify_identity(fd: int, expected: tuple[int, int], label: str) -> os.stat_result:
    st = os.fstat(fd)
    actual = identity_for_stat(st)
    if actual != expected:
        raise PublishError(EX_STATE, f"{label} changed during task materialization")
    return st


def open_directory(path: str, label: str) -> int:
    try:
        fd = os.open(path, directory_flags())
    except OSError as error:
        raise PublishError(EX_STATE, f"could not open {label} with O_NOFOLLOW: {error.strerror}") from error
    try:
        identity_for_stat(os.fstat(fd))
    except Exception:
        os.close(fd)
        raise
    return fd


def open_directory_at(parent_fd: int, name: str, label: str) -> int:
    require_basename(name, label)
    try:
        fd = os.open(name, directory_flags(), dir_fd=parent_fd)
    except OSError as error:
        raise PublishError(EX_STATE, f"could not open {label} with O_NOFOLLOW: {error.strerror}") from error
    try:
        identity_for_stat(os.fstat(fd))
    except Exception:
        os.close(fd)
        raise
    return fd


def lstat_at(parent_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise PublishError(EX_STATE, f"could not inspect task publication entry {name}: {error.strerror}") from error


def require_real_directory_at(parent_fd: int, name: str, label: str) -> os.stat_result | None:
    st = lstat_at(parent_fd, name)
    if st is None:
        return None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise PublishError(EX_STATE, f"{label} must be a real directory")
    return st


def renameatx(fd_from: int, from_name: str, fd_to: int, to_name: str, flags: int) -> None:
    """Use the kernel's fd-relative atomic rename extension; never path fallback."""
    system = platform.system()
    if system == "Darwin":
        try:
            library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            operation = library.renameatx_np
        except (AttributeError, OSError) as error:
            raise PublishError(EX_UNAVAILABLE, "renameatx_np is unavailable for task publication") from error
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        operation.restype = ctypes.c_int
    elif system == "Linux":
        try:
            library = ctypes.CDLL(None, use_errno=True)
            operation = library.renameat2
        except AttributeError as error:
            raise PublishError(EX_UNAVAILABLE, "renameat2 is unavailable for task publication") from error
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        operation.restype = ctypes.c_int
    else:
        raise PublishError(EX_UNAVAILABLE, "kernel lacks fd-relative atomic rename support for task publication")

    if operation(fd_from, os.fsencode(from_name), fd_to, os.fsencode(to_name), flags) != 0:
        error_number = ctypes.get_errno()
        if error_number == errno.EEXIST:
            raise PublishError(EX_CONFLICT, "task publication destination appeared during materialization")
        if error_number in {errno.ENOSYS, errno.ENOTSUP}:
            raise PublishError(EX_UNAVAILABLE, "kernel lacks required fd-relative atomic rename support for task publication")
        detail = os.strerror(error_number) if error_number else "unknown error"
        raise PublishError(EX_UNAVAILABLE, f"fd-relative task publication rename failed: {detail}")


def rename_no_replace(parent_fd: int, stage_name: str, task_name: str) -> None:
    # Darwin RENAME_EXCL and Linux RENAME_NOREPLACE both have value 1 only on
    # Linux; Darwin reserves 0x00000004 for RENAME_EXCL.
    flag = 0x00000004 if platform.system() == "Darwin" else 0x00000001
    renameatx(parent_fd, stage_name, parent_fd, task_name, flag)


def rename_exchange(parent_fd: int, stage_name: str, task_name: str) -> None:
    # RENAME_SWAP on Darwin and RENAME_EXCHANGE on Linux are both 0x00000002.
    renameatx(parent_fd, stage_name, parent_fd, task_name, 0x00000002)


def directory_is_empty(fd: int) -> bool:
    try:
        return not os.listdir(fd)
    except OSError as error:
        raise PublishError(EX_STATE, f"could not inspect staged output directory: {error.strerror}") from error


def remove_tree_contents(fd: int) -> None:
    """Remove a known previous generation through already-open descriptors."""
    try:
        names = os.listdir(fd)
    except OSError as error:
        raise PublishError(EX_UNAVAILABLE, f"could not enumerate previous task generation: {error.strerror}") from error
    for name in names:
        require_basename(name, "previous task entry")
        st = lstat_at(fd, name)
        if st is None:
            continue
        if stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode):
            child_fd = open_directory_at(fd, name, "previous task directory")
            try:
                remove_tree_contents(child_fd)
                current = lstat_at(fd, name)
                if current is None or (current.st_dev, current.st_ino) != (st.st_dev, st.st_ino):
                    raise PublishError(EX_STATE, "previous task directory changed during cleanup")
                os.rmdir(name, dir_fd=fd)
            except OSError as error:
                raise PublishError(EX_UNAVAILABLE, f"could not remove previous task directory: {error.strerror}") from error
            finally:
                os.close(child_fd)
        else:
            try:
                os.unlink(name, dir_fd=fd)
            except OSError as error:
                raise PublishError(EX_UNAVAILABLE, f"could not remove previous task entry: {error.strerror}") from error


def remove_previous_generation(parent_fd: int, name: str, expected: tuple[int, int]) -> None:
    old_fd = open_directory_at(parent_fd, name, "previous materialized task directory")
    try:
        verify_identity(old_fd, expected, "previous materialized task directory")
        remove_tree_contents(old_fd)
        current = lstat_at(parent_fd, name)
        if current is None or (current.st_dev, current.st_ino) != expected:
            raise PublishError(EX_STATE, "previous materialized task directory changed during cleanup")
        try:
            os.rmdir(name, dir_fd=parent_fd)
        except OSError as error:
            raise PublishError(EX_UNAVAILABLE, f"could not remove previous materialized task directory: {error.strerror}") from error
    finally:
        os.close(old_fd)


def migrate_output(old_task_fd: int, stage_fd: int) -> bool:
    old_output = require_real_directory_at(old_task_fd, "output", "previous materialized output directory")
    if old_output is None:
        return False
    staged_output = require_real_directory_at(stage_fd, "output", "staged output directory")
    if staged_output is None:
        raise PublishError(EX_STATE, "staged task is missing its output directory")
    staged_output_fd = open_directory_at(stage_fd, "output", "staged output directory")
    try:
        if not directory_is_empty(staged_output_fd):
            raise PublishError(EX_STATE, "staged output directory must be empty before publication")
    finally:
        os.close(staged_output_fd)
    try:
        os.rmdir("output", dir_fd=stage_fd)
        os.rename("output", "output", src_dir_fd=old_task_fd, dst_dir_fd=stage_fd)
    except OSError as error:
        raise PublishError(EX_UNAVAILABLE, f"could not preserve prior task output: {error.strerror}") from error
    return True


def rollback_output(old_task_fd: int, stage_fd: int) -> None:
    try:
        os.rename("output", "output", src_dir_fd=stage_fd, dst_dir_fd=old_task_fd)
    except OSError as error:
        raise PublishError(EX_STATE, f"could not restore prior task output after failed publication: {error.strerror}") from error

def test_fail_old_generation_cleanup() -> bool:
    """Deterministic fault injection for the post-commit cleanup contract."""
    return os.environ.get("TRELLIS_TEST_TASK_PUBLISH_FAIL_OLD_CLEANUP") == "1"


def publish(args: argparse.Namespace) -> None:
    fleet_name = require_basename(args.fleet_name, "fleet directory entry")
    stage_name = require_basename(args.stage_name, "task staging directory entry")
    task_name = require_basename(args.task_name, "task directory entry")
    if stage_name == task_name:
        raise PublishError(EX_STATE, "task staging and destination names must differ")
    expected_fleet = parse_identity(args.fleet_identity, "fleet directory identity")
    expected_stage = parse_identity(args.stage_identity, "task staging directory identity")

    fleet_fd = open_directory(args.fleet_dir, "fleet task state directory")
    stage_fd: int | None = None
    task_fd: int | None = None
    try:
        verify_identity(fleet_fd, expected_fleet, "fleet task state directory")
        stage_st = require_real_directory_at(fleet_fd, stage_name, "task staging directory")
        if stage_st is None:
            raise PublishError(EX_STATE, "task staging directory disappeared before publication")
        stage_fd = open_directory_at(fleet_fd, stage_name, "task staging directory")
        verify_identity(stage_fd, expected_stage, "task staging directory")

        old_task_st = require_real_directory_at(fleet_fd, task_name, "materialized task destination")
        if old_task_st is None:
            rename_no_replace(fleet_fd, stage_name, task_name)
            return

        task_fd = open_directory_at(fleet_fd, task_name, "materialized task destination")
        old_task_identity = identity_for_stat(os.fstat(task_fd))
        moved_output = migrate_output(task_fd, stage_fd)
        try:
            rename_exchange(fleet_fd, stage_name, task_name)
        except PublishError:
            if moved_output:
                rollback_output(task_fd, stage_fd)
            raise

        # This exchange is the durable publication commit point. After it
        # succeeds, failure to remove the old generation cannot roll back the
        # new one or change the command outcome. Defer cleanup with a warning.
        try:
            if test_fail_old_generation_cleanup():
                raise PublishError(EX_UNAVAILABLE, "injected prior generation cleanup failure")
            remove_previous_generation(fleet_fd, stage_name, old_task_identity)
        except PublishError as error:
            print(f"trellis task: published task; deferred cleanup of prior generation: {error}", file=sys.stderr)
    finally:
        if task_fd is not None:
            os.close(task_fd)
        if stage_fd is not None:
            os.close(stage_fd)
        os.close(fleet_fd)


def main() -> None:
    parser = argparse.ArgumentParser(prog="task-publish.py", add_help=False)
    subparsers = parser.add_subparsers(dest="command", required=True)
    identity_parser = subparsers.add_parser("identity", add_help=False)
    identity_parser.add_argument("path")
    publish_parser = subparsers.add_parser("publish", add_help=False)
    publish_parser.add_argument("--fleet-dir", required=True)
    publish_parser.add_argument("--fleet-name", required=True)
    publish_parser.add_argument("--fleet-identity", required=True)
    publish_parser.add_argument("--stage-name", required=True)
    publish_parser.add_argument("--stage-identity", required=True)
    publish_parser.add_argument("--task-name", required=True)
    args = parser.parse_args()

    try:
        if args.command == "identity":
            fd = open_directory(args.path, "task publication directory")
            try:
                print(identity_text(os.fstat(fd)))
            finally:
                os.close(fd)
        else:
            publish(args)
    except PublishError as error:
        die(error.code, str(error))
    except (OSError, ValueError) as error:
        die(EX_UNAVAILABLE, f"task publication helper failed: {error}")


if __name__ == "__main__":
    main()
