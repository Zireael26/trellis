#!/usr/bin/env python3
"""Prepare private, offline Cargo state for the native Bats fixtures.

Exit 2 means an offline prerequisite is absent; exit 1 means the inputs are
invalid (in particular, a corrupt archive is never treated as a skip).
"""

import hashlib
import os
from pathlib import Path
import platform
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tomllib


class MissingPrerequisite(Exception):
    pass


def account_home():
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    except KeyError:
        return None


def source_homes(variable, leaf, account):
    explicit = os.environ.get(variable)
    if explicit:
        return [Path(explicit).expanduser().resolve()]
    # HOME can already be fenced, empty, or only partly populated. Try it first,
    # then the account home as a whole; never mix registries between homes.
    candidates = []
    home = os.environ.get("HOME")
    for parent in (Path(home) if home else None, account):
        if parent is not None:
            candidate = (parent / leaf).resolve()
            if candidate not in candidates:
                candidates.append(candidate)
    if not candidates:
        raise MissingPrerequisite("offline source home unavailable: " + variable)
    return candidates


def within(path, root):
    return path == root or root in path.parents


def index_path(name):
    name = name.lower()
    if len(name) == 1:
        return Path("1") / name
    if len(name) == 2:
        return Path("2") / name
    if len(name) == 3:
        return Path("3") / name[0] / name
    return Path(name[:2]) / name[2:4] / name


def toolchain(rustup, probe_version=None):
    machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(
        platform.machine().lower(), platform.machine().lower()
    )
    system = platform.system()
    candidates = []
    for candidate in sorted((rustup / "toolchains").glob("1.97.1-*")):
        host = candidate.name[len("1.97.1-") :]
        if not host.startswith(machine + "-"):
            continue
        if system == "Darwin" and not host.endswith("-apple-darwin"):
            continue
        if system == "Linux" and "-linux-" not in host:
            continue
        if system not in ("Darwin", "Linux"):
            continue
        candidates.append((candidate, host))
    problems = []
    for candidate, host in candidates:
        cargo = candidate / "bin/cargo"
        rustc = candidate / "bin/rustc"
        rustdoc = candidate / "bin/rustdoc"
        # An empty placeholder is not an installed compiler; another source
        # home may contain the toolchain. A present but broken one is an error.
        if not rustc.exists():
            continue
        if not all(
            p.is_file() and os.access(p, os.X_OK) for p in (cargo, rustc, rustdoc)
        ):
            problems.append(f"incomplete installed toolchain: {candidate}")
            continue
        try:
            if probe_version is None:
                version = subprocess.run(
                    [str(rustc), "-vV"],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                ).stdout.strip()
            else:
                version = probe_version(rustc)
                if not version or version.startswith("unavailable:"):
                    raise ValueError(version or "empty probe")
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            problems.append(f"installed rustc failed: {candidate}: {error}")
            continue
        fields = dict(
            line.split(": ", 1) for line in version.splitlines() if ": " in line
        )
        if fields.get("release") == "1.97.1" and fields.get("host") == host:
            return candidate.resolve(), version
        problems.append(f"installed rustc version or host mismatch: {candidate}")
    if problems:
        raise ValueError("; ".join(problems))
    raise MissingPrerequisite(
        "offline Rust toolchain 1.97.1 for this host is not installed"
    )


def select_registry(cargo_source, lock_path):
    lock = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    source_registry = cargo_source / "registry"
    packages = []
    for package in lock.get("package", []):
        source = package.get("source")
        if source is None:
            continue
        if source != "registry+https://github.com/rust-lang/crates.io-index":
            raise ValueError("unsupported Cargo.lock dependency source: " + source)
        name, version = package["name"], package["version"]
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name) or not re.fullmatch(
            r"[A-Za-z0-9_.+-]+", version
        ):
            raise ValueError("invalid Cargo.lock package name or version")
        packages.append((name, name + "-" + version + ".crate", package["checksum"]))
    if not packages:
        return None, None, False, [], []

    caches = sorted((source_registry / "cache").glob("*"))
    caches = [path for path in caches if path.is_dir()]
    # Prefer sparse crates.io when multiple complete registries are cached.
    caches.sort(key=lambda path: not path.name.startswith("index.crates.io-"))
    missing_archive = packages[0][1]
    missing_index = None
    corrupt = None
    selected = None
    for cache in caches:
        absent = next(
            (archive for _, archive, _ in packages if not (cache / archive).is_file()),
            None,
        )
        if absent:
            missing_archive = absent
            continue
        index = source_registry / "index" / cache.name
        legacy = (index / ".git").is_dir() and cache.name.startswith("github.com-")
        if not legacy:
            absent_index = next(
                (
                    name
                    for name, _, _ in packages
                    if not (index / ".cache" / index_path(name)).is_file()
                ),
                None,
            )
            if absent_index or not (index / "config.json").is_file():
                missing_index = absent_index or packages[0][0]
                continue
        archives = []
        for name, archive, checksum in packages:
            data = (cache / archive).read_bytes()
            if hashlib.sha256(data).hexdigest() != checksum:
                corrupt = archive
                break
            archives.append((name, archive, data))
        else:
            selected = cache, index, legacy, archives
            break
    if selected is None:
        if corrupt:
            raise ValueError("cached crate checksum mismatch: " + corrupt)
        if missing_index:
            raise MissingPrerequisite(
                "offline registry index is missing for " + missing_index
            )
        raise MissingPrerequisite("offline cached crate is missing: " + missing_archive)

    cache, index, legacy, archives = selected
    index_items = []
    if not legacy:
        items = [Path("config.json")] + [
            Path(".cache") / index_path(name) for name, _, _ in archives
        ]
        index_items = [(item.as_posix(), (index / item).read_bytes()) for item in items]
    return cache.name, index, legacy, archives, index_items


def sources():
    account = account_home()
    cargo = source_homes("CARGO_HOME", ".cargo", account)
    rustup = source_homes("RUSTUP_HOME", ".rustup", account)
    protected = cargo + rustup
    if account is not None:
        protected += [(account / ".cargo").resolve(), (account / ".rustup").resolve()]
    return cargo, rustup, protected


def select_toolchain(rustup_sources, probe_version=None):
    for source in rustup_sources:
        try:
            return toolchain(source, probe_version)
        except MissingPrerequisite as error:
            missing = error
    raise missing


def select_cached_registry(cargo_sources, lock_path):
    for source in cargo_sources:
        try:
            return select_registry(source, lock_path)
        except MissingPrerequisite as error:
            missing = error
    raise missing


def check_root_config():
    if any(
        os.path.lexists(Path("/.cargo", name)) for name in ("config", "config.toml")
    ):
        raise ValueError("root Cargo config is not supported by native test fixtures")


def sysroot_identity(installed, version):
    fields = dict(line.split(": ", 1) for line in version.splitlines() if ": " in line)
    host = fields.get("host")
    if not host or not re.fullmatch(r"[A-Za-z0-9_-]+", host):
        raise ValueError("invalid rustc host for sysroot identity")
    rustlib = installed / "lib/rustlib"
    manifest = (rustlib / "multirust-channel-manifest.toml").read_bytes()
    components = (rustlib / "components").read_bytes()
    drivers = sorted(
        path for path in (installed / "lib").glob("librustc_driver*") if path.is_file()
    )
    host_lib = rustlib / host / "lib"
    if not drivers or host_lib.is_symlink() or not host_lib.is_dir():
        raise ValueError("pinned Rust compiler driver or host libraries are missing")
    host_files = []
    for path in sorted(host_lib.rglob("*")):
        if path.is_symlink() and path.is_dir():
            raise ValueError("symlinked sysroot directories are not eligible for reuse")
        if path.is_file():
            host_files.append(path)
        elif not path.is_dir():
            raise ValueError("unsupported sysroot entry: " + str(path))
    if not host_files:
        raise ValueError("pinned Rust host libraries are empty")
    # Same-UID in-place rewrites preserving inode, size and mtime are an
    # explicitly accepted residual; a reinstall or ordinary update changes it.
    files = []
    for path in drivers + host_files:
        info = path.stat()
        files.append(
            [
                path.relative_to(installed).as_posix(),
                info.st_dev,
                info.st_ino,
                info.st_size,
                info.st_mtime_ns,
                info.st_mode,
                info.st_uid,
                info.st_gid,
            ]
        )
    return {
        "manifest": hashlib.sha256(manifest).hexdigest(),
        "components": hashlib.sha256(components).hexdigest(),
        "files": files,
    }


def fixture_identity(lock_path, probe_version=None):
    """Inputs consumed by both Bats and standalone native Cargo stages."""
    check_root_config()
    cargo_sources, rustup_sources, _ = sources()
    installed, version = select_toolchain(rustup_sources, probe_version)
    cache_name, _, legacy, archives, index_items = select_cached_registry(
        cargo_sources, lock_path
    )
    if legacy:
        # A git index may consult packed objects and refs beyond the entries
        # copied by a sparse index. Run it, but do not reuse its verdict.
        raise ValueError("legacy Git registry index is not eligible for verdict reuse")

    def digest(data):
        return hashlib.sha256(data).hexdigest()

    return {
        "toolchain_path": str(installed),
        "rustc": digest((installed / "bin/rustc").read_bytes()),
        "cargo": digest((installed / "bin/cargo").read_bytes()),
        "rustdoc": digest((installed / "bin/rustdoc").read_bytes()),
        "rustc_vv": version,
        "sysroot": sysroot_identity(installed, version),
        "registry": cache_name,
        "archives": [[archive, digest(data)] for _, archive, data in archives],
        "index": [[name, digest(data)] for name, data in index_items],
    }


def prepare(destination, lock_path):
    cargo_sources, rustup_sources, protected = sources()
    if os.path.lexists(destination):
        raise ValueError("private Cargo destination must be new")
    destination = destination.resolve()
    if any(within(destination, source) for source in protected):
        raise ValueError("private Cargo state must not be inside a source home")
    # Cargo discovers ancestor config from cwd. The adapter runs from /, so a
    # root-level Cargo config would otherwise inject unkeyed build behavior.
    check_root_config()
    installed, _ = select_toolchain(rustup_sources)
    cache_name, index, legacy, archives, index_items = select_cached_registry(
        cargo_sources, lock_path
    )
    destination.mkdir(mode=0o700)
    cargo = destination / "cargo"
    cargo.mkdir()
    (destination / "rustup").mkdir()
    if cache_name is not None:
        destination_index = cargo / "registry/index" / cache_name
        if legacy:
            shutil.copytree(index, destination_index, dirs_exist_ok=True)
        else:
            for name, data in index_items:
                target = destination_index / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        for _, archive, data in archives:
            target = cargo / "registry/cache" / cache_name / archive
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    protocol = "git" if legacy else "sparse"
    binary_dir = destination / "bin"
    binary_dir.mkdir()
    for name in ("rustc", "rustdoc"):
        (binary_dir / name).symlink_to(installed / "bin" / name)
    # Direct binaries never ask rustup to sync. The tiny adapter supports the
    # pinned selector used by qualification and rejects any other selector.
    # This test-only seam is refused by verdict reuse (TRELLIS_TEST_*).
    profile = os.environ.get("TRELLIS_TEST_CARGO_SANDBOX_PROFILE")
    if profile and (platform.system() != "Darwin" or not Path(profile).is_file()):
        raise ValueError("invalid Cargo sandbox profile")
    command = shlex.quote(str(installed / "bin/cargo"))
    if profile:
        command = "/usr/bin/sandbox-exec -f " + shlex.quote(profile) + " " + command
    wrapper = binary_dir / "cargo"
    wrapper.write_text(
        "#!/bin/sh\n"
        "case ${1-} in +1.97.1) shift ;; +*) echo 'unsupported Rust toolchain selector' >&2; exit 1 ;; esac\n"
        "unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER CARGO_BUILD_RUSTC_WRAPPER CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER\n"
        f"RUSTC={shlex.quote(str(installed / 'bin/rustc'))}\n"
        f"RUSTDOC={shlex.quote(str(installed / 'bin/rustdoc'))}\n"
        f"CARGO_TARGET_DIR={shlex.quote(str(destination / 'target'))}\n"
        "CARGO_NET_OFFLINE=true\n"
        "CARGO_BUILD_JOBS=2\n"
        "RUST_TEST_THREADS=1\n"
        f"CARGO_REGISTRIES_CRATES_IO_PROTOCOL={protocol}\n"
        "export RUSTC RUSTDOC CARGO_TARGET_DIR CARGO_NET_OFFLINE CARGO_BUILD_JOBS RUST_TEST_THREADS CARGO_REGISTRIES_CRATES_IO_PROTOCOL\n"
        "cd / || exit 1\n"
        f'exec {command} "$@"\n',
        encoding="utf-8",
    )
    wrapper.chmod(0o700)


def main():
    if len(sys.argv) != 3:
        print("usage: native-cargo-home.py PRIVATE_DIR Cargo.lock", file=sys.stderr)
        return 1
    try:
        prepare(Path(sys.argv[1]), Path(sys.argv[2]))
    except MissingPrerequisite as error:
        print(str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("native Cargo fixture: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
