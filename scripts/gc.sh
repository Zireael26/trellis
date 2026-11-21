#!/usr/bin/env bash
# trellis gc — mark-and-sweep garbage collection for private TRELLIS_HOME state.
#
# Modes:
#   --dry-run (default)  Report unreachable releases, native binaries, dead-PID
#                        .tmp.* staging directories, stale (>7d)
#                        native-stop-bundles, state/scratch/.cmd.* leaks,
#                        tasks .tmp.* orphans, and pi-worktrees.test strays.
#   --apply              chmod -R u+w (no symlink traversal) and remove reported
#                        reclaimable entries.
#   --home PATH          Explicit TRELLIS_HOME override.
#
# Never invoked automatically by `trellis doctor`. Bash 3.2 compatible.

set -euo pipefail

unset TRELLIS_LIBS_PRELOADED

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/release-store.sh
. "$SCRIPT_DIR/lib/release-store.sh"

gc_err() {
  printf 'trellis gc: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: trellis gc [--dry-run|--apply] [--home PATH]

Reclaim unreachable immutable releases ($TRELLIS_HOME/releases/<ver>),
unreachable native companion directories ($TRELLIS_HOME/bin/native/<ver>),
dead-PID .tmp.* staging directories, stale (>7d) native-stop-bundles,
state/scratch/.cmd.* leaks, tasks .tmp.* orphans, and test strays.

Options:
  --dry-run      Report reclaimable entries without deleting anything (default)
  --apply        Make reclaimable entries writable and delete them
  --home PATH    Override TRELLIS_HOME
  -h, --help     Show this help message
EOF
}

mode="dry-run"
home_opt=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --apply)
      mode="apply"
      shift
      ;;
    --home)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        gc_err "--home requires a path"
        exit "$TRELLIS_EX_USAGE"
      fi
      home_opt="$2"
      shift 2
      ;;
    --home=*)
      home_opt="${1#--home=}"
      if [ -z "$home_opt" ]; then
        gc_err "--home requires a path"
        exit "$TRELLIS_EX_USAGE"
      fi
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      gc_err "unknown option: $1"
      usage >&2
      exit "$TRELLIS_EX_USAGE"
      ;;
  esac
done

home_candidate="$(trellis_home_resolve "$home_opt")" || exit "$?"
if [ ! -e "$home_candidate" ] && [ ! -L "$home_candidate" ]; then
  gc_err "Trellis home does not exist: $home_candidate"
  exit "$TRELLIS_EX_STATE"
fi
if [ -L "$home_candidate" ] || [ ! -d "$home_candidate" ]; then
  gc_err "Trellis home must be a real directory: $home_candidate"
  exit "$TRELLIS_EX_STATE"
fi
home="$(CDPATH='' cd "$home_candidate" && pwd -P)" || {
  gc_err "could not canonicalize Trellis home: $home_candidate"
  exit "$TRELLIS_EX_UNAVAILABLE"
}

export TRELLIS_HOME="$home"

command -v python3 >/dev/null 2>&1 || {
  gc_err "python3 is required for trellis gc"
  exit "$TRELLIS_EX_UNAVAILABLE"
}
python_bin="$(command -v python3)" || exit "$TRELLIS_EX_UNAVAILABLE"
birth_program="$(release_store_process_birth_python 2>/dev/null || true)"
export -f release_store_process_birth release_store_process_birth_python 2>/dev/null || true

exec "$python_bin" -I - "$home" "$mode" "${HOME:-}" "$birth_program" "${BASH:-/bin/bash}" <<'PY'
import errno
import json
import os
import re
import stat
import subprocess
import sys
import time

home, mode, user_home, birth_program, birth_bash = sys.argv[1:6]
SEVEN_DAYS = 7 * 86400
ONE_DAY = 86400
SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$"
)
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def die(code, message):
    sys.stderr.write(f"trellis gc: {message}\n")
    sys.exit(code)


def lstat_none(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def require_private_dir(path, label):
    info = lstat_none(path)
    if info is None or stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        die(4, f"{label} is missing or not a real directory: {path}")
    if info.st_uid != os.getuid() or (stat.S_IMODE(info.st_mode) & 0o077) != 0:
        die(4, f"{label} is not private (mode {stat.S_IMODE(info.st_mode):04o}): {path}")


def require_optional_dir(path, label):
    info = lstat_none(path)
    if info is None:
        return False
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        die(4, f"{label} must be a real directory when present: {path}")
    if not os.access(path, os.R_OK | os.X_OK):
        die(4, f"{label} is not readable/searchable: {path}")
    return True


def read_json_documents(path, label, allow_jsonl=False):
    info = lstat_none(path)
    if info is None or stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        die(4, f"{label} is not a regular file: {path}")
    try:
        raw = open(path, "rb").read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        die(4, f"{label} is unreadable: {path} ({exc})")
    if not raw.strip():
        die(4, f"{label} is empty: {path}")
    if allow_jsonl:
        docs = []
        for line in raw.splitlines():
            text = line.strip()
            if not text:
                continue
            try:
                docs.append(json.loads(text))
            except ValueError as exc:
                die(4, f"{label} contains invalid JSONL: {path} ({exc})")
        if not docs:
            die(4, f"{label} contains no JSON records: {path}")
        return docs
    try:
        return [json.loads(raw)]
    except ValueError as exc:
        die(4, f"{label} contains invalid JSON: {path} ({exc})")


def extract_versions_from_value(value, home_prefix, out):
    releases_prefix = (home_prefix + "/releases/").lower()
    exec_prefix = (home_prefix + "/releases/.exec/").lower()
    native_prefix = (home_prefix + "/bin/native/").lower()
    if isinstance(value, dict):
        for k, v in value.items():
            if k in ("release", "old_version", "new_version", "active_cli_release") and isinstance(v, str):
                candidate = v[1:] if v.startswith("v") and SEMVER_RE.match(v[1:]) else v
                if SEMVER_RE.match(candidate):
                    out.add(candidate.lower())
            extract_versions_from_value(v, home_prefix, out)
    elif isinstance(value, list):
        for item in value:
            extract_versions_from_value(item, home_prefix, out)
    elif isinstance(value, str):
        lowered = value.lower()
        if lowered.startswith(exec_prefix):
            tail = value[len(exec_prefix):].split("/", 1)[0]
            if "-" in tail:
                ver_part, digest_part = tail.rsplit("-", 1)
                if HEX64_RE.match(digest_part.lower()) and SEMVER_RE.match(ver_part):
                    out.add(ver_part.lower())
        elif lowered.startswith(releases_prefix):
            seg = value[len(releases_prefix):].split("/", 1)[0]
            if SEMVER_RE.match(seg):
                out.add(seg.lower())
        elif lowered.startswith(native_prefix):
            seg = value[len(native_prefix):].split("/", 1)[0]
            if SEMVER_RE.match(seg):
                out.add(seg.lower())


def pid_state(pid, expected_birth=None):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0 or pid > 2147483647:
        return "invalid"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "dead"
    except PermissionError:
        # Owned by another user -> cannot be our Trellis staging process if birth is bound;
        # without birth, treat conservatively as alive.
        return "dead" if expected_birth else "alive"
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return "dead"
        return "alive"
    if expected_birth and birth_program and os.path.exists(birth_bash):
        try:
            proc = subprocess.run(
                [birth_bash, "-c", 'release_store_process_birth "$1"', "_", str(pid)],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
            )
            now_birth = proc.stdout.strip()
            if proc.returncode == 0 and now_birth and now_birth != expected_birth.strip():
                return "dead"
        except Exception:
            pass
    return "alive"


def inspect_owner_json(owner_path):
    info = lstat_none(owner_path)
    if info is None:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return "refused"
    try:
        data = json.loads(open(owner_path, "rb").read().decode("utf-8"))
    except Exception:
        return "invalid"
    if not isinstance(data, dict):
        return "invalid"
    pid = data.get("pid")
    birth = data.get("process_birth") if isinstance(data.get("process_birth"), str) else None
    return pid_state(pid, birth)


def valid_semver_value(val):
    if not isinstance(val, str):
        return False
    cand = val[1:] if val.startswith("v") and SEMVER_RE.match(val[1:]) else val
    return bool(SEMVER_RE.match(cand))


def inspect_worktree_root(wt_root, home_prefix, out, strict=True):
    st = lstat_none(wt_root)
    if st is None:
        return
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        if strict:
            die(4, f"registered worktree root is not a real directory: {wt_root}")
        return
    runtime_link = os.path.join(wt_root, ".trellis", "runtime")
    rst = lstat_none(runtime_link)
    if rst is not None:
        if not stat.S_ISLNK(rst.st_mode):
            if strict:
                die(4, f"worktree runtime anchor is not a symlink: {runtime_link}")
        else:
            try:
                target = os.readlink(runtime_link)
            except OSError as exc:
                if strict:
                    die(4, f"worktree runtime anchor is unreadable: {runtime_link} ({exc})")
                target = ""
            if target:
                extract_versions_from_value(target, home_prefix, out)
                if not os.path.isabs(target):
                    resolved = os.path.normpath(os.path.join(wt_root, ".trellis", target))
                    extract_versions_from_value(resolved, home_prefix, out)
    for cfg_name in (".trellis.json", ".trellis.config.json", "trellis.config.json"):
        cfg_path = os.path.join(wt_root, cfg_name)
        cst = lstat_none(cfg_path)
        if cst is None:
            continue
        if strict:
            doc = read_json_documents(cfg_path, f"worktree config {cfg_name}")[0]
            if not isinstance(doc, dict):
                die(4, f"worktree config {cfg_name} must be a JSON object: {cfg_path}")
        else:
            if stat.S_ISLNK(cst.st_mode) or not stat.S_ISREG(cst.st_mode):
                continue
            try:
                doc = json.loads(open(cfg_path, "rb").read().decode("utf-8"))
            except Exception:
                continue
            if not isinstance(doc, dict):
                continue
        tv = doc.get("trellis_version")
        if valid_semver_value(tv):
            cand = tv[1:] if tv.startswith("v") else tv
            out.add(cand.lower())


def tmp_embedded_pid(name):
    # Only match explicit pid tokens (e.g. .pid.12345, pid_12345, -pid-12345);
    # never treat semver patch digits or random suffixes as process IDs.
    m = re.search(r"(?:^|\.|-)pid[._-]?([1-9][0-9]{0,9})(?:$|\.|-)", name)
    if m:
        val = int(m.group(1))
        if 1 < val <= 2147483647:
            return val
    return None


def tree_bytes_nofollow(path):
    info = lstat_none(path)
    if info is None:
        return 0
    if stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode):
        return info.st_size
    if not stat.S_ISDIR(info.st_mode):
        return 0
    total = info.st_size
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as it:
                for entry in it:
                    try:
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    total += st.st_size
                    if stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode):
                        stack.append(entry.path)
        except OSError:
            continue
    return total


def remove_entry_nofollow(parent_dir, name):
    parent_fd = os.open(parent_dir, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    try:
        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if stat.S_ISLNK(st.st_mode):
            die(4, f"refusing to delete symlink target: {os.path.join(parent_dir, name)}")
        if stat.S_ISREG(st.st_mode):
            os.chmod(name, stat.S_IMODE(st.st_mode) | 0o200, dir_fd=parent_fd)
            os.unlink(name, dir_fd=parent_fd)
            return

        def purge_dir(dir_fd):
            dir_st = os.fstat(dir_fd)
            os.fchmod(dir_fd, stat.S_IMODE(dir_st.st_mode) | 0o700)
            for child in os.listdir(dir_fd):
                child_st = os.stat(child, dir_fd=dir_fd, follow_symlinks=False)
                if stat.S_ISDIR(child_st.st_mode) and not stat.S_ISLNK(child_st.st_mode):
                    child_fd = os.open(child, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW, dir_fd=dir_fd)
                    try:
                        purge_dir(child_fd)
                    finally:
                        os.close(child_fd)
                    os.rmdir(child, dir_fd=dir_fd)
                else:
                    if stat.S_ISREG(child_st.st_mode) and not stat.S_ISLNK(child_st.st_mode):
                        os.chmod(child, stat.S_IMODE(child_st.st_mode) | 0o200, dir_fd=dir_fd)
                    os.unlink(child, dir_fd=dir_fd)

        if stat.S_ISDIR(st.st_mode):
            target_fd = os.open(name, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW, dir_fd=parent_fd)
            try:
                purge_dir(target_fd)
            finally:
                os.close(target_fd)
            os.rmdir(name, dir_fd=parent_fd)
        else:
            die(4, f"refusing to delete unsupported file type: {os.path.join(parent_dir, name)}")
    finally:
        os.close(parent_fd)


require_private_dir(home, "TRELLIS_HOME")
config_path = os.path.join(home, "config.json")
config_info = lstat_none(config_path)
if config_info is None or stat.S_ISLNK(config_info.st_mode) or not stat.S_ISREG(config_info.st_mode):
    die(4, f"machine config is missing or not a regular file: {config_path}")
if config_info.st_uid != os.getuid() or (stat.S_IMODE(config_info.st_mode) & 0o077) != 0:
    die(4, f"machine config is not private: {config_path}")

config_doc = read_json_documents(config_path, "machine config")[0]
if not isinstance(config_doc, dict):
    die(4, f"machine config must be a JSON object: {config_path}")
active_release = config_doc.get("active_cli_release")
if not isinstance(active_release, str) or not SEMVER_RE.match(active_release):
    die(4, f"active_cli_release is missing or invalid in {config_path}")

reachable = {active_release.lower()}

# 1. Owner records under $TRELLIS_HOME/state/attachments/*/*.json and $TRELLIS_HOME/attachments/*.json
state_dir = os.path.join(home, "state")
if require_optional_dir(state_dir, "state directory"):
    attachments_dir = os.path.join(state_dir, "attachments")
    if require_optional_dir(attachments_dir, "state/attachments"):
        for entry in sorted(os.listdir(attachments_dir)):
            checkout_dir = os.path.join(attachments_dir, entry)
            st = lstat_none(checkout_dir)
            if st is None:
                continue
            if stat.S_ISLNK(st.st_mode):
                die(4, f"attachment checkout namespace is a symlink: {checkout_dir}")
            if not stat.S_ISDIR(st.st_mode):
                if entry == ".DS_Store":
                    continue
                die(4, f"unexpected non-directory in state/attachments: {checkout_dir}")
            if not os.access(checkout_dir, os.R_OK | os.X_OK):
                die(4, f"attachment checkout namespace is unreadable: {checkout_dir}")
            for fname in sorted(os.listdir(checkout_dir)):
                fpath = os.path.join(checkout_dir, fname)
                if fname.endswith(".json"):
                    for doc in read_json_documents(fpath, "attachment owner record"):
                        if not isinstance(doc, dict) or not valid_semver_value(doc.get("release")):
                            die(4, f"attachment owner record is missing a valid release version: {fpath}")
                        extract_versions_from_value(doc, home, reachable)
                elif ".tmp." in fname:
                    continue
                elif fname == ".DS_Store":
                    continue
                else:
                    fst = lstat_none(fpath)
                    if fst is not None and stat.S_ISLNK(fst.st_mode):
                        die(4, f"unexpected symlink in attachment namespace: {fpath}")

    # 2. Live attachment / user-attachment journals
    for jdir_name in ("attachment-journals", "user-attachment-journals"):
        jdir = os.path.join(state_dir, jdir_name)
        if require_optional_dir(jdir, f"state/{jdir_name}"):
            for fname in sorted(os.listdir(jdir)):
                if fname == ".DS_Store" or ".tmp." in fname:
                    continue
                fpath = os.path.join(jdir, fname)
                if fname.endswith(".json"):
                    for doc in read_json_documents(fpath, f"pending {jdir_name} record"):
                        if not isinstance(doc, dict):
                            die(4, f"pending {jdir_name} record must be a JSON object: {fpath}")
                        extract_versions_from_value(doc, home, reachable)
                else:
                    die(4, f"unexpected entry in state/{jdir_name}: {fpath}")

    # 3. Live release-adoption journals
    adoptions_dir = os.path.join(state_dir, "release-adoptions")
    if require_optional_dir(adoptions_dir, "state/release-adoptions"):
        for dname in sorted(os.listdir(adoptions_dir)):
            if dname == ".DS_Store":
                continue
            work_dir = os.path.join(adoptions_dir, dname)
            wst = lstat_none(work_dir)
            if wst is None or stat.S_ISLNK(wst.st_mode) or not stat.S_ISDIR(wst.st_mode):
                die(4, f"pending adoption entry is invalid: {work_dir}")
            plans_path = os.path.join(work_dir, "plans.jsonl")
            if lstat_none(plans_path) is None:
                die(4, f"pending adoption journal is missing plans.jsonl: {work_dir}")
            for doc in read_json_documents(plans_path, "pending adoption journal", allow_jsonl=True):
                if (
                    not isinstance(doc, dict)
                    or not valid_semver_value(doc.get("old_version"))
                    or not valid_semver_value(doc.get("new_version"))
                ):
                    die(4, f"pending adoption journal row is missing valid old_version/new_version: {plans_path}")
                extract_versions_from_value(doc, home, reachable)

    # 4. Managed git-hook release-payload sidecars (if any)
    git_hooks_dir = os.path.join(state_dir, "git-hooks")
    if require_optional_dir(git_hooks_dir, "state/git-hooks"):
        for dname in sorted(os.listdir(git_hooks_dir)):
            hook_dir = os.path.join(git_hooks_dir, dname)
            hst = lstat_none(hook_dir)
            if hst is None or not stat.S_ISDIR(hst.st_mode) or stat.S_ISLNK(hst.st_mode):
                continue
            sidecar = os.path.join(hook_dir, "release-payload")
            sst = lstat_none(sidecar)
            if sst is not None:
                if stat.S_ISLNK(sst.st_mode) or not stat.S_ISREG(sst.st_mode):
                    die(4, f"git-hook release-payload sidecar is invalid: {sidecar}")
                try:
                    text = open(sidecar, "rb").read().decode("utf-8")
                except Exception as exc:
                    die(4, f"git-hook release-payload sidecar is unreadable: {sidecar} ({exc})")
                for line in text.splitlines():
                    extract_versions_from_value(line.strip(), home, reachable)

# User-level attachment records under $TRELLIS_HOME/attachments/*.json
user_attachments_dir = os.path.join(home, "attachments")
if require_optional_dir(user_attachments_dir, "attachments"):
    for fname in sorted(os.listdir(user_attachments_dir)):
        if fname == ".DS_Store" or ".tmp." in fname:
            continue
        fpath = os.path.join(user_attachments_dir, fname)
        if fname.endswith(".json"):
            for doc in read_json_documents(fpath, "user attachment owner record"):
                if not isinstance(doc, dict) or not valid_semver_value(doc.get("release")):
                    die(4, f"user attachment owner record is missing a valid release version: {fpath}")
                extract_versions_from_value(doc, home, reachable)

# Local registry checkout release pins and registered worktree roots (if registry.json exists)
registry_path = os.path.join(home, "registry.json")
if lstat_none(registry_path) is not None:
    reg_doc = read_json_documents(registry_path, "local registry")[0]
    if not isinstance(reg_doc, dict):
        die(4, f"local registry must be a JSON object: {registry_path}")
    extract_versions_from_value(reg_doc, home, reachable)
    projects = reg_doc.get("projects")
    if projects is not None:
        if not isinstance(projects, dict):
            die(4, f"local registry projects field must be a JSON object: {registry_path}")
        for proj in projects.values():
            if not isinstance(proj, dict):
                die(4, f"local registry project entry must be a JSON object: {registry_path}")
            unavail = set(proj.get("unavailable_roots") or []) if isinstance(proj.get("unavailable_roots"), list) else set()
            wt_roots = set()
            if isinstance(proj.get("root"), str) and proj["root"]:
                wt_roots.add(proj["root"])
            if isinstance(proj.get("worktrees"), dict):
                for wt in proj["worktrees"].values():
                    if isinstance(wt, dict) and isinstance(wt.get("root"), str) and wt["root"]:
                        wt_roots.add(wt["root"])
            if isinstance(proj.get("checkouts"), dict):
                for co in proj["checkouts"].values():
                    if isinstance(co, dict) and isinstance(co.get("worktrees"), dict):
                        for wt in co["worktrees"].values():
                            if isinstance(wt, dict) and isinstance(wt.get("root"), str) and wt["root"]:
                                wt_roots.add(wt["root"])
            strict_proj = proj.get("status") == "active"
            for wt_root in sorted(wt_roots - unavail):
                if os.path.isabs(wt_root):
                    inspect_worktree_root(wt_root, home, reachable, strict=strict_proj)

# Shallow discovery roots declared in config.json fleets.*.discovery_roots
fleets_cfg = config_doc.get("fleets")
if isinstance(fleets_cfg, dict):
    for fcfg in fleets_cfg.values():
        if not isinstance(fcfg, dict) or not isinstance(fcfg.get("discovery_roots"), list):
            continue
        for droot in fcfg["discovery_roots"]:
            if not isinstance(droot, str) or not os.path.isabs(droot):
                continue
            dst = lstat_none(droot)
            if dst is None or stat.S_ISLNK(dst.st_mode) or not stat.S_ISDIR(dst.st_mode) or not os.access(droot, os.R_OK | os.X_OK):
                continue
            inspect_worktree_root(droot, home, reachable, strict=False)
            try:
                children = sorted(os.listdir(droot))
            except OSError:
                children = []
            for child in children:
                cpath = os.path.join(droot, child)
                cst = lstat_none(cpath)
                if cst is not None and stat.S_ISDIR(cst.st_mode) and not stat.S_ISLNK(cst.st_mode):
                    inspect_worktree_root(cpath, home, reachable, strict=False)

# Installed stable launcher companion pin (if ~/.local/bin/trellis exists)
if user_home and os.path.isabs(user_home):
    launcher_path = os.path.join(user_home, ".local", "bin", "trellis")
    lst = lstat_none(launcher_path)
    if lst is not None and stat.S_ISREG(lst.st_mode) and not stat.S_ISLNK(lst.st_mode):
        try:
            launcher_text = open(launcher_path, "rb").read(65536).decode("utf-8", errors="ignore")
            m = re.search(r"^launcher_native_version='([^']+)'", launcher_text, re.M)
            if m and SEMVER_RE.match(m.group(1)):
                reachable.add(m.group(1).lower())
        except OSError:
            pass

now = time.time()
candidates = []  # (category, parent_dir, entry_name, full_path, bytes, reason)

# Scan $TRELLIS_HOME/releases
releases_dir = os.path.join(home, "releases")
if require_optional_dir(releases_dir, "releases"):
    release_entries = sorted(os.listdir(releases_dir))
    for name in release_entries:
        full = os.path.join(releases_dir, name)
        st = lstat_none(full)
        if st is None:
            continue
        if name == ".exec":
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                die(4, f"releases/.exec is not a real directory: {full}")
            for snap in sorted(os.listdir(full)):
                snap_full = os.path.join(full, snap)
                snap_st = lstat_none(snap_full)
                if snap_st is None or stat.S_ISLNK(snap_st.st_mode):
                    continue
                if snap.startswith(".lock.") and stat.S_ISREG(snap_st.st_mode):
                    lock_tail = snap[len(".lock."):]
                    if "-" in lock_tail:
                        ver_part, digest_part = lock_tail.rsplit("-", 1)
                        if HEX64_RE.match(digest_part.lower()) and SEMVER_RE.match(ver_part):
                            if ver_part.lower() not in reachable:
                                candidates.append((
                                    "release-exec-lock",
                                    full,
                                    snap,
                                    snap_full,
                                    snap_st.st_size,
                                    f"lockfile for unreachable execution snapshot {ver_part}",
                                ))
                    continue
                if not stat.S_ISDIR(snap_st.st_mode):
                    continue
                if "-" in snap:
                    ver_part, digest_part = snap.rsplit("-", 1)
                    if HEX64_RE.match(digest_part.lower()) and SEMVER_RE.match(ver_part):
                        if ver_part.lower() not in reachable:
                            candidates.append((
                                "release-exec-snapshot",
                                full,
                                snap,
                                snap_full,
                                tree_bytes_nofollow(snap_full),
                                f"unreachable execution snapshot for {ver_part}",
                            ))
            continue
        if name.endswith(".lock"):
            continue
        if name.startswith(".tmp."):
            if name.endswith(".owner.json"):
                target_name = name[:-len(".owner.json")]
                if lstat_none(os.path.join(releases_dir, target_name)) is None:
                    state = inspect_owner_json(full)
                    age = max(0, int(now - st.st_mtime))
                    if state == "dead" or age > 3600:
                        candidates.append((
                            "tmp-staging",
                            releases_dir,
                            name,
                            full,
                            st.st_size,
                            "orphaned .tmp.* owner sidecar",
                        ))
                continue
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                die(4, f"refusing non-directory .tmp.* entry: {full}")
            sidecar_path = full + ".owner.json"
            inner_owner = os.path.join(full, "owner.json")
            remove_owner = os.path.join(full, "remove.owner.json")
            state = None
            for opath in (sidecar_path, inner_owner, remove_owner):
                if lstat_none(opath) is not None:
                    state = inspect_owner_json(opath)
                    break
            if state == "refused":
                die(4, f"refusing symlinked .tmp.* owner record for: {full}")
            if state is None:
                embedded = tmp_embedded_pid(name)
                if embedded is not None:
                    state = pid_state(embedded)
            age = max(0, int(now - st.st_mtime))
            if state == "dead" or (state is None and age > ONE_DAY):
                reason = "dead-PID .tmp.* staging directory" if state == "dead" else f"orphaned .tmp.* staging directory (age={age}s)"
                candidates.append((
                    "tmp-staging",
                    releases_dir,
                    name,
                    full,
                    tree_bytes_nofollow(full),
                    reason,
                ))
                if lstat_none(sidecar_path) is not None:
                    sst = lstat_none(sidecar_path)
                    if sst is not None and stat.S_ISREG(sst.st_mode) and not stat.S_ISLNK(sst.st_mode):
                        candidates.append((
                            "tmp-staging",
                            releases_dir,
                            name + ".owner.json",
                            sidecar_path,
                            sst.st_size,
                            "paired .tmp.* owner sidecar",
                        ))
            continue
        if SEMVER_RE.match(name):
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                die(4, f"release entry is not a real directory: {full}")
            if name.lower() in reachable:
                continue
            lock_path = os.path.join(releases_dir, f"{name}.lock")
            if lstat_none(lock_path) is not None:
                continue
            candidates.append((
                "release",
                releases_dir,
                name,
                full,
                tree_bytes_nofollow(full),
                f"unreachable release {name}",
            ))

# Associated stamps for unreachable releases
if require_optional_dir(state_dir, "state directory"):
    for stamp_dir_name in ("release-stamps", "exec-stamps"):
        stamp_dir = os.path.join(state_dir, stamp_dir_name)
        if require_optional_dir(stamp_dir, f"state/{stamp_dir_name}"):
            for fname in sorted(os.listdir(stamp_dir)):
                if not fname.endswith(".json"):
                    continue
                stem = fname[:-5]
                if "-" not in stem:
                    continue
                ver_part, digest_part = stem.rsplit("-", 1)
                if HEX64_RE.match(digest_part.lower()) and SEMVER_RE.match(ver_part):
                    if ver_part.lower() not in reachable:
                        fpath = os.path.join(stamp_dir, fname)
                        fst = lstat_none(fpath)
                        if fst is not None and stat.S_ISREG(fst.st_mode) and not stat.S_ISLNK(fst.st_mode):
                            candidates.append((
                                "release-stamp",
                                stamp_dir,
                                fname,
                                fpath,
                                fst.st_size,
                                f"stamp for unreachable release {ver_part}",
                            ))

# Scan $TRELLIS_HOME/bin/native/<ver> and dead-PID .tmp.* under bin/native
bin_dir = os.path.join(home, "bin")
if require_optional_dir(bin_dir, "bin"):
    native_dir = os.path.join(bin_dir, "native")
    if require_optional_dir(native_dir, "bin/native"):
        for name in sorted(os.listdir(native_dir)):
            full = os.path.join(native_dir, name)
            st = lstat_none(full)
            if st is None:
                continue
            if name.startswith(".tmp."):
                if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                    die(4, f"refusing non-directory .tmp.* entry in bin/native: {full}")
                embedded = tmp_embedded_pid(name)
                state = pid_state(embedded) if embedded is not None else None
                age = max(0, int(now - st.st_mtime))
                if state == "dead" or (state is None and age > ONE_DAY):
                    candidates.append((
                        "tmp-staging",
                        native_dir,
                        name,
                        full,
                        tree_bytes_nofollow(full),
                        "dead-PID .tmp.* native staging directory" if state == "dead" else f"orphaned .tmp.* native staging directory (age={age}s)",
                    ))
                continue
            if SEMVER_RE.match(name):
                if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                    die(4, f"native version entry is not a real directory: {full}")
                if name.lower() not in reachable:
                    candidates.append((
                        "native-binary",
                        native_dir,
                        name,
                        full,
                        tree_bytes_nofollow(full),
                        f"unreachable native companion {name}",
                    ))

# Scan $TRELLIS_HOME/state/native-stop-bundles (>7d)
if require_optional_dir(state_dir, "state directory"):
    bundles_dir = os.path.join(state_dir, "native-stop-bundles")
    if require_optional_dir(bundles_dir, "state/native-stop-bundles"):
        for name in sorted(os.listdir(bundles_dir)):
            full = os.path.join(bundles_dir, name)
            st = lstat_none(full)
            if st is None:
                continue
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                die(4, f"native-stop-bundles entry is not a real directory: {full}")
            age = max(0, int(now - st.st_mtime))
            if age > SEVEN_DAYS:
                candidates.append((
                    "native-stop-bundle",
                    bundles_dir,
                    name,
                    full,
                    tree_bytes_nofollow(full),
                    f"stale native-stop-bundle (age={age}s > {SEVEN_DAYS}s)",
                ))

# Sweep $TRELLIS_HOME/state/scratch/.cmd.* leaked launcher dirs: dead-PID or
# >24h old across the entire subtree with no open handle anywhere inside.
# Uses remove_entry_nofollow (chmod u+w).
def lsof_has_open_handle(path):
    try:
        proc = subprocess.run(
            ["lsof", "+D", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        # lsof +D exits 0 with header + rows when any process holds a handle
        # inside the tree; exit 1 with empty stdout means no open handles.
        if proc.returncode == 0:
            return True
        if (proc.stdout or "").strip():
            return True
    except Exception:
        return True
    return False


def newest_mtime_nofollow(path):
    st = lstat_none(path)
    if st is None:
        return now
    newest = st.st_mtime
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        return newest
    for root, dirs, files in os.walk(path, followlinks=False):
        for entry in dirs + files:
            est = lstat_none(os.path.join(root, entry))
            if est is not None and est.st_mtime > newest:
                newest = est.st_mtime
    return newest


if require_optional_dir(state_dir, "state directory"):
    scratch_dir = os.path.join(state_dir, "scratch")
    if require_optional_dir(scratch_dir, "state/scratch"):
        for name in sorted(os.listdir(scratch_dir)):
            if not name.startswith(".cmd."):
                continue
            full = os.path.join(scratch_dir, name)
            st = lstat_none(full)
            if st is None:
                continue
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                continue
            embedded = tmp_embedded_pid(name)
            state = pid_state(embedded) if embedded is not None else None
            age = max(0, int(now - newest_mtime_nofollow(full)))
            if state == "dead":
                candidates.append((
                    "scratch-cmd",
                    scratch_dir,
                    name,
                    full,
                    tree_bytes_nofollow(full),
                    "dead-PID state/scratch .cmd.* directory",
                ))
            elif age > ONE_DAY and not lsof_has_open_handle(full):
                if state == "alive":
                    continue
                candidates.append((
                    "scratch-cmd",
                    scratch_dir,
                    name,
                    full,
                    tree_bytes_nofollow(full),
                    f"orphaned state/scratch .cmd.* directory (age={age}s > 86400s)",
                ))

# Sweep $TRELLIS_HOME/tasks/<fleet>/.*.tmp.* orphan staging dirs (dead PID via
# .owner.json sidecar if present, OR >24h old with no owner sidecar) AND
# orphaned .tmp.*.owner.json sidecars.
TASK_TMP_RE = re.compile(r"^\.(?:[A-Za-z0-9][A-Za-z0-9._-]*\.)?tmp\.[A-Za-z0-9]+(?:\.owner\.json)?$")
tasks_dir = os.path.join(home, "tasks")
if require_optional_dir(tasks_dir, "tasks"):
    for fleet in sorted(os.listdir(tasks_dir)):
        fleet_dir = os.path.join(tasks_dir, fleet)
        fst = lstat_none(fleet_dir)
        if fst is None or stat.S_ISLNK(fst.st_mode) or not stat.S_ISDIR(fst.st_mode):
            continue
        try:
            names = sorted(os.listdir(fleet_dir))
        except OSError:
            continue
        for name in names:
            if not TASK_TMP_RE.match(name):
                continue
            full = os.path.join(fleet_dir, name)
            st = lstat_none(full)
            if st is None:
                continue
            if name.endswith(".owner.json"):
                if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
                    continue
                target = full[: -len(".owner.json")]
                if lstat_none(target) is None:
                    state = inspect_owner_json(full)
                    age = max(0, int(now - st.st_mtime))
                    if state == "dead" or age > 3600:
                        candidates.append((
                            "task-tmp",
                            fleet_dir,
                            name,
                            full,
                            st.st_size,
                            "orphaned .tmp.* owner sidecar",
                        ))
                continue
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                continue
            sidecar = full + ".owner.json"
            state = inspect_owner_json(sidecar) if lstat_none(sidecar) is not None else None
            if state == "refused":
                die(4, f"refusing symlinked .tmp.* owner record for: {full}")
            age = max(0, int(now - st.st_mtime))
            if state == "dead":
                candidates.append((
                    "task-tmp",
                    fleet_dir,
                    name,
                    full,
                    tree_bytes_nofollow(full),
                    "dead-PID tasks .tmp.* staging directory",
                ))
                if lstat_none(sidecar) is not None:
                    sst = lstat_none(sidecar)
                    if sst is not None and stat.S_ISREG(sst.st_mode) and not stat.S_ISLNK(sst.st_mode):
                        candidates.append((
                            "task-tmp",
                            fleet_dir,
                            name + ".owner.json",
                            sidecar,
                            sst.st_size,
                            "paired .tmp.* owner sidecar",
                        ))
            elif state is None and age > ONE_DAY and not lsof_has_open_handle(full):
                candidates.append((
                    "task-tmp",
                    fleet_dir,
                    name,
                    full,
                    tree_bytes_nofollow(full),
                    f"orphaned tasks .tmp.* staging directory (age={age}s)",
                ))

# Report stale pi-worktrees.test.* 0-byte strays at $TRELLIS_HOME root.
for name in sorted(os.listdir(home)):
    if not name.startswith("pi-worktrees.test."):
        continue
    full = os.path.join(home, name)
    st = lstat_none(full)
    if st is None or stat.S_ISLNK(st.st_mode):
        continue
    if stat.S_ISREG(st.st_mode) and st.st_size == 0:
        candidates.append((
            "test-stray",
            home,
            name,
            full,
            0,
            "stale pi-worktrees.test.* 0-byte stray",
        ))

verb = "removed" if mode == "apply" else "would-remove"
total_bytes = 0
count = 0
for category, parent_dir, entry_name, full_path, size_bytes, reason in candidates:
    if mode == "apply":
        remove_entry_nofollow(parent_dir, entry_name)
    print(f"gc: {verb} {category} {full_path} bytes={size_bytes} ({reason})")
    total_bytes += size_bytes
    count += 1

mib = total_bytes / 1048576.0
print(f"gc: mode={mode} reachable={','.join(sorted(reachable))} entries={count} bytes={total_bytes} ({mib:.1f} MiB)")
PY
