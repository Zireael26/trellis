"""Shared acquisition primitives; no qualification verdicts live here."""
import hashlib
import os
import platform
import re
import stat
import subprocess
import tempfile
from pathlib import Path

from schema import EvidenceError, canonical, load

BASELINE = "3661cb5f2949c2482b6380fc4631cd549556e0ce"
EXCLUSIONS = ("specs/", "scripts/qualification/", "scripts/lib/test-suites.sh")
BUILD_INPUTS = ("native/trellis-hooks/", "scripts/build-native-hooks.sh")
RECORDER_INPUTS = ("scripts/qualification/", "scripts/bench/", "scripts/release-payload-commit.sh", "scripts/check-process-liveness.sh")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def value_digest(value):
    return digest(canonical(value).encode())


def git(repo, *args, data=None):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_NO_REPLACE_OBJECTS="1")
    process = subprocess.run(["git", "-C", str(repo), *args], input=data, capture_output=True, env=env)
    if process.returncode:
        raise EvidenceError("git " + " ".join(args[:2]) + ": " + process.stderr.decode(errors="replace").strip())
    return process.stdout


def commit(repo, revision="HEAD"):
    return git(repo, "rev-parse", "--verify", revision + "^{commit}").decode().strip()


def safe_relative(value):
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not value or "\x00" in value:
        raise EvidenceError("unsafe relative evidence path: " + value)
    return path


def under(path, prefix):
    return path.startswith(prefix) if prefix.endswith("/") else path == prefix


def tree(repo, revision):
    result = {}
    for row in git(repo, "ls-tree", "-rz", "--full-tree", revision).split(b"\x00"):
        if not row:
            continue
        metadata, path = row.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        name = os.fsdecode(path)
        safe_relative(name)
        result[name] = (mode, kind, oid)
    return result


def payload_exclusions(repo, revision, entries):
    path = "core-rules/payload-exclude.txt"
    if path not in entries:
        return []
    text = git(repo, "cat-file", "blob", entries[path][2]).decode()
    result = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        safe_relative(line)
        if not line.endswith("/") or any(character.isspace() for character in line):
            raise EvidenceError("unsafe payload exclusion")
        result.append(line)
    return result


def selected_input(name, requirements, requirement, scope, excluded):
    if any(under(name, prefix) for prefix in EXCLUSIONS):
        return False
    native = any(under(name, prefix) for prefix in BUILD_INPUTS)
    if scope == "native-build":
        return native
    fixtures = requirement.get("inputs", []) + requirements["input_sets"]["rendered_registrations"]
    return (native or not any(under(name, prefix) for prefix in excluded)
            or any(under(name, prefix) for prefix in fixtures) or name == requirement.get("suite"))


def qualified_paths(repo, revision, requirements, requirement, scope="runtime"):
    entries = tree(repo, revision)
    excluded = payload_exclusions(repo, revision, entries)
    return {name: entries[name] for name in sorted(entries) if selected_input(name, requirements, requirement, scope, excluded)}


def committed_inputs(repo, revision, requirements, requirement, scope="runtime"):
    selected = qualified_paths(repo, revision, requirements, requirement, scope)
    if any(kind != "blob" for _, kind, _ in selected.values()):
        raise EvidenceError("unbounded submodule input")
    # One batch avoids a subprocess per sealed payload file; binary lengths,
    # rather than line splitting, preserve arbitrary blob contents.
    data = git(repo, "cat-file", "--batch", data=b"".join(oid.encode() + b"\n" for _, _, oid in selected.values()))
    result, position = [], 0
    for name, (mode, _, oid) in selected.items():
        end = data.index(b"\n", position)
        header = data[position:end].decode().split()
        if len(header) != 3 or header[:2] != [oid, "blob"]:
            raise EvidenceError("invalid Git batch input")
        size = int(header[2])
        content = data[end + 1:end + 1 + size]
        if len(content) != size or data[end + 1 + size:end + 2 + size] != b"\n":
            raise EvidenceError("truncated Git blob input")
        result.append({"path": name, "mode": mode, "sha256": digest(content)})
        position = end + size + 2
    return result


def file_input(root, name):
    relative = safe_relative(name)
    current = root
    for component in relative.parts[:-1]:
        current = current / component
        if current.is_symlink():
            raise EvidenceError("input parent is a symlink: " + name)
    path = root / relative
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"path": name, "mode": "missing", "sha256": digest(b"")}
    if stat.S_ISLNK(info.st_mode):
        content, mode = os.fsencode(os.readlink(path)), "120000"
    elif stat.S_ISREG(info.st_mode):
        content, mode = path.read_bytes(), "100755" if info.st_mode & 0o111 else "100644"
    else:
        raise EvidenceError("input is not a regular file or tracked link: " + name)
    return {"path": name, "mode": mode, "sha256": digest(content)}


def source_snapshot(root, requirements, requirement, scope):
    revision = commit(root)
    expected = committed_inputs(root, revision, requirements, requirement, scope)
    names = {item["path"] for item in expected}
    excluded = payload_exclusions(root, revision, tree(root, revision))
    for raw in git(root, "ls-files", "--others", "-z").split(b"\x00"):
        if not raw:
            continue
        name = os.fsdecode(raw)
        if selected_input(name, requirements, requirement, scope, excluded):
            names.add(name)
    actual = [file_input(root, name) for name in sorted(names)]
    return revision, expected, actual, None


def installed_snapshot(root, requirements, requirement, scope):
    if scope != "runtime":
        raise EvidenceError("build inputs require a source runtime")
    manifest = load(root / "release.json")
    payload = root / "payload"
    expected = []
    actual = []
    # The installed manifest records Git blob OIDs, not SHA-256. Bind them to
    # the actual bytes before retaining this generation's SHA-256 inputs.
    clean = True
    for item in sorted(manifest["tree"], key=lambda item: item["path"]):
        name = item["path"]
        if any(under(name, prefix) for prefix in EXCLUSIONS):
            continue
        observed = file_input(payload, name)
        actual.append(observed)
        path = payload / safe_relative(name)
        content = os.fsencode(os.readlink(path)) if observed["mode"] == "120000" else path.read_bytes() if path.is_file() else b""
        oid = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        clean = clean and oid == item["oid"] and observed["mode"] == item["mode"]
        expected.append(observed)
    if not clean:
        # No invented committed digest for bytes that failed their manifest.
        expected = []
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", manifest["commit"]):
        raise EvidenceError("installed release has no valid runtime commit")
    return manifest["commit"], expected, actual, digest((root / "release.json").read_bytes())


def snapshot(root, kind, requirements, requirement, scope):
    return source_snapshot(root, requirements, requirement, scope) if kind == "source" else installed_snapshot(root, requirements, requirement, scope)


def recorder_identity(root, include_inputs=False):
    revision = commit(root)
    paths = tree(root, revision)
    names = sorted(name for name in paths if any(under(name, prefix) for prefix in RECORDER_INPUTS))
    if not names:
        raise EvidenceError("recorder source is not committed")
    untracked = git(root, "ls-files", "--others", "-z", "--", *RECORDER_INPUTS)
    if untracked.strip(b"\x00"):
        raise EvidenceError("recorder implementation contains uncommitted files")
    actual = [file_input(root, name) for name in names]
    expected = [{"path": name, "mode": paths[name][0], "sha256": digest(git(root, "cat-file", "blob", paths[name][2]))} for name in names]
    if actual != expected:
        raise EvidenceError("recorder implementation differs from recorder_sha")
    result = revision, value_digest(actual)
    return (*result, actual) if include_inputs else result


def device_id(path):
    return path.stat().st_dev


def make_scratch(runtime, base, run_id):
    scratch = Path(tempfile.mkdtemp(prefix="qualification-" + run_id + "-", dir=base))
    scratch.chmod(0o700)
    runtime_device, scratch_device = device_id(runtime), device_id(scratch)
    if runtime_device != scratch_device:
        scratch.rmdir()  # Our own still-empty directory, never caller data.
        raise EvidenceError("measurement TMPDIR and runtime are on different filesystems/devices")
    return scratch, {"scratch_base": "recorder-owned-TMPDIR", "runtime_device": runtime_device,
                     "scratch_device": scratch_device, "same_device": True}


def acquire_artifacts(root, manifest_path):
    """Capture declared provenance and independently hash the produced files."""
    path = root / safe_relative(manifest_path)
    manifest = load(path)
    entries, outputs = [], []
    for target, item in sorted(manifest["assets"].items()):
        relative = str(Path(manifest_path).parent / safe_relative(item["path"]))
        observed = file_input(root, relative)
        if observed["mode"] != "100755":
            raise EvidenceError("built artifact is not an executable regular file: " + relative)
        entries.append(dict(item, target=target))
        outputs.append({"target": target, "path": item["path"], "size": (root / relative).stat().st_size,
                        "sha256": observed["sha256"]})
    toolchain = dict(manifest["toolchain"])
    for tool in ("rustc", "cargo"):
        result = subprocess.run([tool, "--version"], cwd=root / "native/trellis-hooks", capture_output=True, text=True, timeout=30)
        if result.returncode or not result.stdout.strip():
            raise EvidenceError("build toolchain identity unavailable: " + tool)
        if tool == "rustc" and toolchain["rustc"] != result.stdout.strip():
            raise EvidenceError("build rustc differs from manifest")
        toolchain[tool] = result.stdout.strip()
    toolchain["targets"] = sorted(manifest["assets"])
    toolchain["codesign"] = digest(Path("/usr/bin/codesign").read_bytes()) if platform.system() == "Darwin" else None
    return {"manifest_generation": digest(path.read_bytes()), "version": manifest["version"],
            "source_commit": manifest["source_commit"], "toolchain": toolchain,
            "inputs": manifest["inputs"], "entries": entries, "outputs": outputs}


def ctime_probe(runtime, output):
    if runtime.stat().st_dev != output.stat().st_dev:
        return {"capability": "unknown", "same_device": False, "samples_ns": []}
    fd, name = tempfile.mkstemp(prefix="ctime-proof-", dir=output)
    samples = []
    try:
        with os.fdopen(fd, "wb", buffering=0) as handle:
            for value in (b"a", b"b", b"c"):
                handle.write(value)
                os.fsync(handle.fileno())
                samples.append(os.fstat(handle.fileno()).st_ctime_ns)
    finally:
        Path(name).unlink()
    fine = len(set(samples)) == 3 and all(value % 1000000000 for value in samples)
    return {"capability": "fine" if fine else "coarse", "same_device": True, "samples_ns": samples}


def host_snapshot(runtime, output):
    system = platform.system()
    if system == "Linux":
        identity = Path("/etc/machine-id").read_text().strip()
        filesystem = subprocess.run(["stat", "-f", "-c", "%T", str(runtime)], capture_output=True, text=True, check=True).stdout.strip()
        emulated = False
    elif system == "Darwin":
        result = subprocess.run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, check=True).stdout
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', result)
        if not match:
            raise EvidenceError("stable host identity unavailable")
        identity = match.group(1)
        mounts = subprocess.run(["mount"], capture_output=True, text=True, check=True).stdout
        filesystem, longest = "unknown", 0
        for line in mounts.splitlines():
            found = re.search(r" on (.*?) \(([^,)]+)", line)
            if found and (str(runtime) == found.group(1) or str(runtime).startswith(found.group(1).rstrip("/") + "/")) and len(found.group(1)) > longest:
                filesystem, longest = found.group(2), len(found.group(1))
        translation = subprocess.run(["sysctl", "-in", "sysctl.proc_translated"], capture_output=True, text=True)
        emulated = translation.returncode == 0 and translation.stdout.strip() == "1"
    else:
        raise EvidenceError("unsupported qualification host: " + system)
    machine = platform.machine().lower()
    architecture = "aarch64" if machine in ("arm64", "aarch64") else "x86_64" if machine in ("x86_64", "amd64") else machine
    proof = ctime_probe(runtime, output)
    return {"host_id": digest((system + ":" + identity).encode()),
            "platform": {"os": system, "arch": architecture, "os_version": platform.release(), "filesystem": filesystem,
                         "ctime_capability": proof["capability"], "ctime_probe": proof, "emulated": emulated},
            "load_average": list(os.getloadavg()), "logical_cores": os.cpu_count() or 1, "battery_running": battery_running()}


def battery_running():
    process = subprocess.run(["ps", "-eo", "pid=,ppid=,args="], capture_output=True, text=True)
    if process.returncode:
        return True
    rows = {}
    for line in process.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            rows[int(fields[0])] = (int(fields[1]), fields[2])
    own = {os.getpid()}
    current = os.getpid()
    while current in rows and rows[current][0] not in own:
        current = rows[current][0]
        own.add(current)
    pattern = re.compile(r"(?:^|/)(?:bats(?:-exec-[^ ]+)?|cargo|run-tests\.sh|weekly-full-battery\.py)(?: |$)")
    return any(pid not in own and pattern.search(command) for pid, (_, command) in rows.items())
