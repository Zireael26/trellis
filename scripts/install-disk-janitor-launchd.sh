#!/bin/sh
# The direct-entry shell only starts a fixed clean Bash. This keeps BASH_ENV,
# ENV, exported functions, loader variables, Git overrides, and ambient PATH
# from reaching installer code before the body is evaluated.
# shellcheck shell=bash
# The `#!/bin/sh` line above is a POSIX bootstrap: it does nothing but `exec` a
# clean `/bin/bash --noprofile --norc` through `env -i`, so every line of this
# file after the bootstrap is Bash and must be linted as Bash. Without this
# directive ShellCheck believed the shebang and buried ~30 real findings under
# ~250 SC30xx dialect complaints about a dialect that never runs.
#
# ShellCheck only honours `shell=` at the top of a file, so the directive covers
# the POSIX prologue too. `scripts/tests/posix-bootstrap-prologue.bats` re-checks
# each prologue as `sh` to keep that guarantee, since this line removes it here.
# shellcheck disable=SC3028  # Relying on BASH_SOURCE being undefined under POSIX sh is the
# point of this guard: unset under /bin/sh it expands empty and the bootstrap runs, while under
# Bash it holds the sourcing path so a sourced copy is left alone. Valid syntax in both.
if [ -z "${BASH_VERSION-}" ] || [ "${BASH_SOURCE-}" = "$0" ]; then
  exec /usr/bin/env -i \
    "HOME=${HOME-}" "TRELLIS_HOME=${TRELLIS_HOME-}" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash --noprofile --norc -c '
set -u
installer_source="$1"
shift
case "$installer_source" in
  /*) ;;
  *) installer_source="$(/bin/pwd -P)/$installer_source" ;;
esac
installer_body="$(/usr/bin/mktemp /tmp/trellis-disk-janitor-launchd.XXXXXX)" || {
  /usr/bin/printf "%s\n" "trellis launchd: could not prepare trusted installer bootstrap" >&2
  exit 5
}
if ! /usr/bin/awk "body { print } /^# -- trellis disk janitor launchd body --\$/ { body = 1 }" "$installer_source" > "$installer_body" ||
  ! /bin/test -s "$installer_body" ||
  ! /bin/chmod 600 "$installer_body"; then
  /bin/rm -f "$installer_body"
  /usr/bin/printf "%s\n" "trellis launchd: could not prepare trusted installer bootstrap" >&2
  exit 5
fi
exec /usr/bin/env -i \
  "HOME=${HOME-}" "TRELLIS_HOME=${TRELLIS_HOME-}" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  "TRELLIS_DISK_JANITOR_INSTALLER_SOURCE=$installer_source" \
  "TRELLIS_DISK_JANITOR_INSTALLER_BODY=$installer_body" \
  /bin/bash --noprofile --norc "$installer_body" "$@"
' trellis-disk-janitor-launchd-bootstrap "$0" "$@"
fi

# -- trellis disk janitor launchd body --
# Install (or uninstall) the Trellis disk-janitor LaunchAgents.
#
# Scheduled agents invoke one fixed, user-owned launcher and receive an explicit
# canonical TRELLIS_HOME. Neither the generated plist nor an installed agent
# retains a mutable policy-checkout path.

set -euo pipefail
installer_cleanup_body() {
  local body="${TRELLIS_DISK_JANITOR_INSTALLER_BODY:-}"
  [ -z "$body" ] || /bin/rm -f "$body"
}
trap 'installer_cleanup_body' EXIT
unset BASH_ENV ENV CDPATH
PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

installer_source="${TRELLIS_DISK_JANITOR_INSTALLER_SOURCE:-${BASH_SOURCE[0]}}"
case "$installer_source" in
  */*) installer_source_dir="${installer_source%/*}" ;;
  *) installer_source_dir='.' ;;
esac
SCRIPT_DIR="$(CDPATH='' cd "$installer_source_dir" && pwd -P)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"

usage() {
  cat <<'EOF'
Usage:
  trellis launchd [--with-apply] [--uninstall]

Installs the report LaunchAgent by default. --with-apply additionally installs
the destructive nightly safe-only worktree janitor. Both agents start from an
empty environment and execute only the fixed canonical
operator-home/.local/bin/trellis with TRELLIS_HOME set explicitly.
EOF
}

canonical_existing_directory() {
  local input="$1" label="$2" canonical
  trellis_home_require_absolute_safe_path "$label" "$input" || return "$?"
  if [ ! -d "$input" ]; then
    printf 'trellis launchd: %s is unavailable: %s\n' "$label" "$input" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  canonical="$(trellis_home_real_dir "$input")" || {
    printf 'trellis launchd: could not canonicalize %s: %s\n' "$label" "$input" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trellis_home_require_absolute_safe_path "$label" "$canonical" || return "$?"
  printf '%s\n' "$canonical"
}

preflight_real_child_directory() {
  local parent relative label remaining component current
  parent="$1"
  relative="$2"
  label="$3"
  current="$parent"
  case "$relative" in
    ''|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*'//'*) return "$TRELLIS_EX_USAGE" ;;
  esac
  remaining="$relative"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    current="$current/$component"
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
      printf 'trellis launchd: %s has a symlink or non-directory component: %s\n' "$label" "$current" >&2
      return "$TRELLIS_EX_STATE"
    fi
    if [ -d "$current" ]; then
      require_safe_directory "$current" "$label" || return "$?"
    fi
  done
  printf '%s\n' "$current"
}


require_real_child_directory() {
  local parent relative label current
  parent="$1"
  relative="$2"
  label="$3"
  current="$(preflight_real_child_directory "$parent" "$relative" "$label")" || return "$?"
  if [ ! -d "$current" ]; then
    printf 'trellis launchd: %s is unavailable: %s\n' "$label" "$current" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  printf '%s\n' "$current"
}

plist_lint() {
  /usr/bin/plutil -lint "$1" >/dev/null 2>&1
}

file_mode() {
  local path="$1" mode
  case "${INSTALLER_SYSTEM_NAME:-$("/usr/bin/uname" -s)}" in
    Darwin) mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" ;;
    *) mode="$(/usr/bin/stat -c '%a' "$path" 2>/dev/null)" ;;
  esac
  [ -n "$mode" ] || return 1
  printf '%s\n' "$mode"
}

path_owner_uid() {
  local path="$1" owner
  case "${INSTALLER_SYSTEM_NAME:-$("/usr/bin/uname" -s)}" in
    Darwin) owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" ;;
    *) owner="$(/usr/bin/stat -c '%u' "$path" 2>/dev/null)" ;;
  esac
  [ -n "$owner" ] || return 1
  printf '%s\n' "$owner"
}

path_device_inode() {
  local path="$1" identity
  case "${INSTALLER_SYSTEM_NAME:-$("/usr/bin/uname" -s)}" in
    Darwin) identity="$(/usr/bin/stat -f '%d:%i' "$path" 2>/dev/null)" ;;
    *) identity="$(/usr/bin/stat -c '%d:%i' "$path" 2>/dev/null)" ;;
  esac
  case "$identity" in
    [0-9]*:[0-9]*) printf '%s\n' "$identity" ;;
    *) return 1 ;;
  esac
}

snapshot_directory_identity() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    printf '%s\n' '-'
    return 0
  fi
  path_device_inode "$path" || {
    printf 'trellis launchd: could not snapshot %s identity: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
}

path_has_extended_acl() {
  local path="$1" listing marker
  case "${INSTALLER_SYSTEM_NAME:-$("/usr/bin/uname" -s)}" in
    Darwin) listing="$(LC_ALL=C /bin/ls -lde "$path" 2>/dev/null)" ;;
    *) listing="$(LC_ALL=C /bin/ls -ld "$path" 2>/dev/null)" ;;
  esac
  [ -n "$listing" ] || return 2
  marker="${listing%% *}"
  case "$marker" in *+) return 0 ;; *) return 1 ;; esac
}

path_has_group_or_other_write() {
  local path="$1" mode group other
  mode="$(file_mode "$path")" || return 2
  case "$mode" in
    [0-7][0-7][0-7])
      group="${mode:1:1}"
      other="${mode:2:1}"
      ;;
    [0-7][0-7][0-7][0-7])
      group="${mode:2:1}"
      other="${mode:3:1}"
      ;;
    *) return 2 ;;
  esac
  case "$group" in 2|3|6|7) return 0 ;; esac
  case "$other" in 2|3|6|7) return 0 ;; esac
  return 1
}

require_path_controls() {
  local path="$1" label="$2" owner_code="$3" owner rc
  owner="$(path_owner_uid "$path")" || {
    printf 'trellis launchd: could not inspect owner for %s: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ "$owner" = "$installer_uid" ] || {
    printf 'trellis launchd: %s is not owned by the current operator: %s\n' "$label" "$path" >&2
    return "$owner_code"
  }
  if path_has_extended_acl "$path"; then
    printf 'trellis launchd: %s has an extended ACL: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  else
    rc=$?
    [ "$rc" -eq 1 ] || {
      printf 'trellis launchd: could not inspect ACLs for %s: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    }
  fi
  if path_has_group_or_other_write "$path"; then
    printf 'trellis launchd: %s grants group or other write access: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  else
    rc=$?
    [ "$rc" -eq 1 ] || {
      printf 'trellis launchd: could not inspect permissions for %s: %s\n' "$label" "$path" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    }
  fi
}

require_safe_directory() {
  local path="$1" label="$2"
  [ -d "$path" ] && [ ! -L "$path" ] || {
    printf 'trellis launchd: %s must be a real directory: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_STATE"
  }
  require_path_controls "$path" "$label" "$TRELLIS_EX_STATE"
}

require_private_regular_file() {
  local path="$1" label="$2" ownership_code="$3" mode
  [ -f "$path" ] && [ ! -L "$path" ] || {
    printf 'trellis launchd: %s must be a regular file: %s\n' "$label" "$path" >&2
    return "$ownership_code"
  }
  require_path_controls "$path" "$label" "$ownership_code" || return "$?"
  mode="$(file_mode "$path")" || {
    printf 'trellis launchd: could not inspect permissions for %s: %s\n' "$label" "$path" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ "$mode" = 600 ] || {
    printf 'trellis launchd: %s permissions must be 0600: %s\n' "$label" "$path" >&2
    return "$ownership_code"
  }
}

# Mutate LaunchAgents only through descriptors pinned below the canonical home.
# Pathname checks reject bad inputs before any write; this helper keeps a
# same-UID namespace swap between that check and the sink from redirecting a
# staged plist, replacement, or removal through a changed ancestor.
launch_agents_secure_operation() {
  local rc
  [ -x /usr/bin/python3 ] || {
    printf 'trellis launchd: Python 3 descriptor support is unavailable\n' >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  # -I and env -i prevent HOME/user-site/current-directory imports from
  # creating state or changing the descriptor sink's implementation.
  if /usr/bin/env -i PATH='/usr/bin:/bin:/usr/sbin:/sbin' /usr/bin/python3 -I - "$@" <<'PY'
import html
import os
import plistlib
import re
import secrets
import stat
import sys

CONFLICT = 3
STATE = 4
UNAVAILABLE = 5
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
OPEN_DIRECTORY_FLAGS = os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW


class LaunchdError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message


def fail(code, message):
    raise LaunchdError(code, message)


def parse_identity(value, label):
    if value == "-":
        return None
    match = re.fullmatch(r"([0-9]+):([0-9]+)", value)
    if not match:
        fail(STATE, "invalid expected %s identity" % label)
    return (int(match.group(1)), int(match.group(2)))


def identity(value):
    return (int(value.st_dev), int(value.st_ino))


def display_identity(value):
    return "%d:%d" % identity(value)


def same_identity(value, expected):
    return identity(value) == expected


def safe_directory(value, uid, label):
    if not stat.S_ISDIR(value.st_mode):
        fail(STATE, "%s is not a real directory" % label)
    if value.st_uid != uid:
        fail(STATE, "%s is not owned by the current operator" % label)
    if stat.S_IMODE(value.st_mode) & 0o022:
        fail(STATE, "%s grants group or other write access" % label)


def private_regular(value, uid, label, code=CONFLICT, require_single_link=False):
    if not stat.S_ISREG(value.st_mode):
        fail(code, "%s is not a regular file" % label)
    if value.st_uid != uid:
        fail(code, "%s is not owned by the current operator" % label)
    if stat.S_IMODE(value.st_mode) != 0o600:
        fail(code, "%s permissions are not 0600" % label)
    if require_single_link and value.st_nlink != 1:
        fail(code, "%s is not private" % label)


def lstat_at(parent_fd, name, label):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as error:
        fail(STATE, "could not inspect %s: %s" % (label, error))


def open_root(path, expected, uid, open_fds):
    try:
        descriptor = os.open(path, OPEN_DIRECTORY_FLAGS)
    except (AttributeError, OSError) as error:
        fail(STATE, "operator home changed during operation: %s" % error)
    open_fds.append(descriptor)
    current = os.fstat(descriptor)
    if not same_identity(current, expected):
        fail(STATE, "operator home changed during operation")
    safe_directory(current, uid, "operator home")
    return descriptor


def open_expected_directory(parent_fd, name, expected, uid, label, open_fds):
    before = lstat_at(parent_fd, name, label)
    if before is None:
        fail(STATE, "%s disappeared during operation" % label)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        fail(STATE, "%s has a symlink or non-directory component" % label)
    try:
        descriptor = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd)
    except (AttributeError, OSError) as error:
        fail(STATE, "%s cannot be opened without following links: %s" % (label, error))
    open_fds.append(descriptor)
    current = os.fstat(descriptor)
    if not same_identity(current, identity(before)) or not same_identity(current, expected):
        fail(STATE, "%s changed during operation" % label)
    safe_directory(current, uid, label)
    return descriptor


def ensure_expected_directory(parent_fd, name, expected, uid, label, open_fds):
    before = lstat_at(parent_fd, name, label)
    if before is None:
        if expected is not None:
            fail(STATE, "%s disappeared during operation" % label)
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            fail(STATE, "%s appeared during operation" % label)
        except OSError as error:
            fail(UNAVAILABLE, "could not create %s: %s" % (label, error))
        before = lstat_at(parent_fd, name, label)
        if before is None:
            fail(UNAVAILABLE, "could not inspect newly created %s" % label)
    elif expected is None:
        fail(STATE, "%s appeared during operation" % label)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        fail(STATE, "%s has a symlink or non-directory component" % label)
    try:
        descriptor = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd)
    except (AttributeError, OSError) as error:
        fail(STATE, "%s cannot be opened without following links: %s" % (label, error))
    open_fds.append(descriptor)
    current = os.fstat(descriptor)
    if not same_identity(current, identity(before)):
        fail(STATE, "%s changed during operation" % label)
    if expected is not None and not same_identity(current, expected):
        fail(STATE, "%s changed during operation" % label)
    safe_directory(current, uid, label)
    return descriptor


def validate_label(label):
    if label not in ("org.trellis.disk-janitor", "org.trellis.disk-janitor-apply"):
        fail(STATE, "invalid LaunchAgent label")
    return label + ".plist"


def verify_destination(parent_fd, name, expected, uid, label):
    current = lstat_at(parent_fd, name, "agent destination")
    if expected is None:
        if current is not None:
            fail(CONFLICT, "agent destination appeared during operation")
        return None
    if current is None:
        fail(CONFLICT, "agent destination disappeared during operation")
    if stat.S_ISLNK(current.st_mode):
        fail(CONFLICT, "agent destination became a symlink")
    private_regular(current, uid, "agent destination")
    if not same_identity(current, expected):
        fail(CONFLICT, "agent destination changed during operation")
    return current


def read_template(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | O_NOFOLLOW)
    except (AttributeError, OSError) as error:
        fail(UNAVAILABLE, "could not open template without following links: %s" % error)
    try:
        value = os.fstat(descriptor)
        if not stat.S_ISREG(value.st_mode):
            fail(STATE, "template is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    except OSError as error:
        fail(UNAVAILABLE, "could not read template: %s" % error)
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass


def validate_rendered_plist(rendered, label, user_home, trellis_home, logs_dir, launcher):
    try:
        payload = plistlib.loads(rendered)
    except Exception as error:
        fail(STATE, "rendered plist is invalid: %s" % error)
    expected_arguments = [
        "/usr/bin/env",
        "-i",
        "HOME=%s" % user_home,
        "TRELLIS_HOME=%s" % trellis_home,
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "/bin/bash",
        "--noprofile",
        "--norc",
        launcher,
        "disk-janitor",
    ]
    expected_schedule = {"Hour": 3, "Minute": 30}
    if label == "org.trellis.disk-janitor":
        expected_arguments.append("--report")
    else:
        expected_arguments.extend(["--apply", "--scopes", "worktrees", "--yes", "--safe-only"])
        expected_schedule = {"Hour": 4, "Minute": 0}
    if payload.get("Label") != label:
        fail(STATE, "rendered plist label is invalid")
    if payload.get("ProgramArguments") != expected_arguments:
        fail(STATE, "rendered plist program arguments are invalid")
    if "EnvironmentVariables" in payload:
        fail(STATE, "rendered plist retains ambient environment variables")
    if payload.get("StandardOutPath") != "%s/%s.log" % (logs_dir, label):
        fail(STATE, "rendered plist stdout path is invalid")
    if payload.get("StandardErrorPath") != "%s/%s.log" % (logs_dir, label):
        fail(STATE, "rendered plist stderr path is invalid")
    if payload.get("RunAtLoad") is not False:
        fail(STATE, "rendered plist RunAtLoad is invalid")
    if payload.get("StartCalendarInterval") != expected_schedule:
        fail(STATE, "rendered plist schedule is invalid")


def render_plist(template, label, user_home, trellis_home, logs_dir, launcher):
    try:
        rendered = read_template(template).decode("utf-8")
    except UnicodeDecodeError as error:
        fail(STATE, "template is not UTF-8: %s" % error)
    rendered = rendered.replace("__TRELLIS_HOME__", html.escape(trellis_home, quote=True))
    rendered = rendered.replace("__USER_HOME__", html.escape(user_home, quote=True))
    if re.search(r"__[A-Z_]+__", rendered):
        fail(STATE, "rendered plist has an unresolved template token")
    encoded = rendered.encode("utf-8")
    validate_rendered_plist(encoded, label, user_home, trellis_home, logs_dir, launcher)
    return encoded


def create_staged_plist(parent_fd, label, rendered, uid):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW
    for _ in range(100):
        name = ".%s.%s" % (label, secrets.token_hex(16))
        try:
            descriptor = os.open(name, flags, 0o600, dir_fd=parent_fd)
        except FileExistsError:
            continue
        except (AttributeError, OSError) as error:
            fail(UNAVAILABLE, "could not create private staged agent plist: %s" % error)
        try:
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(rendered):
                offset += os.write(descriptor, rendered[offset:])
            os.fsync(descriptor)
            current = os.fstat(descriptor)
            private_regular(current, uid, "staged agent plist", STATE, True)
            staged = lstat_at(parent_fd, name, "staged agent plist")
            if staged is None or not same_identity(staged, identity(current)):
                fail(STATE, "staged agent plist changed during rendering")
            return name, identity(current)
        except OSError as error:
            fail(UNAVAILABLE, "could not write staged agent plist: %s" % error)
        finally:
            try:
                os.close(descriptor)
            except OSError:
                pass
    fail(UNAVAILABLE, "could not allocate a private staged agent plist")


def remove_staged_if_same(parent_fd, name, expected):
    if name is None:
        return
    current = lstat_at(parent_fd, name, "staged agent plist")
    if current is None or not same_identity(current, expected):
        return
    try:
        os.unlink(name, dir_fd=parent_fd)
    except OSError:
        pass

def remove_staged(parent_fd, name, expected):
    current = lstat_at(parent_fd, name, "staged agent plist")
    if current is None or not same_identity(current, expected):
        fail(STATE, "staged agent plist changed before publication cleanup")
    try:
        os.unlink(name, dir_fd=parent_fd)
    except OSError as error:
        fail(UNAVAILABLE, "could not remove staged agent plist: %s" % error)


def publish(parent_fd, label, expected_destination, template, user_home, trellis_home, logs_dir, launcher, uid):
    name = validate_label(label)
    staged_name = None
    staged_identity = None
    try:
        rendered = render_plist(template, label, user_home, trellis_home, logs_dir, launcher)
        staged_name, staged_identity = create_staged_plist(parent_fd, label, rendered, uid)
        existing = verify_destination(parent_fd, name, expected_destination, uid, label)
        if existing is None:
            try:
                os.link(
                    staged_name,
                    name,
                    src_dir_fd=parent_fd,
                    dst_dir_fd=parent_fd,
                    follow_symlinks=False,
                )
            except FileExistsError:
                fail(CONFLICT, "agent destination appeared during publication")
            except (AttributeError, OSError) as error:
                fail(UNAVAILABLE, "could not publish staged agent plist: %s" % error)
            current = lstat_at(parent_fd, name, "agent destination")
            if current is None or not same_identity(current, staged_identity):
                fail(STATE, "agent destination changed during publication")
            remove_staged(parent_fd, staged_name, staged_identity)
            staged_name = None
            current = lstat_at(parent_fd, name, "agent destination")
            if current is None or not same_identity(current, staged_identity):
                fail(STATE, "agent destination changed after publication")
        else:
            try:
                os.replace(
                    staged_name,
                    name,
                    src_dir_fd=parent_fd,
                    dst_dir_fd=parent_fd,
                )
            except (AttributeError, OSError) as error:
                fail(UNAVAILABLE, "could not atomically replace agent destination: %s" % error)
            staged_name = None
            current = lstat_at(parent_fd, name, "agent destination")
            if current is None or not same_identity(current, staged_identity):
                fail(STATE, "agent destination changed during replacement")
        private_regular(current, uid, "published agent destination", STATE)
        return display_identity(current)
    finally:
        remove_staged_if_same(parent_fd, staged_name, staged_identity)


def remove_destination(parent_fd, label, expected_destination, uid):
    name = validate_label(label)
    verify_destination(parent_fd, name, expected_destination, uid, label)
    current = lstat_at(parent_fd, name, "agent destination")
    if current is None or not same_identity(current, expected_destination):
        fail(CONFLICT, "agent destination changed before removal")
    try:
        os.unlink(name, dir_fd=parent_fd)
    except OSError as error:
        fail(UNAVAILABLE, "could not remove agent destination: %s" % error)


def parse_common(values):
    if len(values) < 5:
        fail(STATE, "invalid secure LaunchAgents operation")
    home = values[0]
    home_identity = parse_identity(values[1], "operator home")
    uid = int(values[2])
    library_identity = parse_identity(values[3], "Library")
    agents_identity = parse_identity(values[4], "LaunchAgents")
    if home_identity is None or library_identity is None or agents_identity is None:
        fail(STATE, "missing expected secure directory identity")
    return home, home_identity, uid, library_identity, agents_identity


def run():
    if not O_DIRECTORY or not O_NOFOLLOW:
        fail(UNAVAILABLE, "descriptor no-follow support is unavailable")
    operation = sys.argv[1] if len(sys.argv) > 1 else ""
    values = sys.argv[2:]
    open_fds = []
    try:
        if operation == "prepare":
            if len(values) != 6:
                fail(STATE, "invalid secure LaunchAgents preparation")
            home = values[0]
            home_identity = parse_identity(values[1], "operator home")
            uid = int(values[2])
            library_expected = parse_identity(values[3], "Library")
            agents_expected = parse_identity(values[4], "LaunchAgents")
            logs_expected = parse_identity(values[5], "Logs")
            if home_identity is None:
                fail(STATE, "missing expected operator home identity")
            root_fd = open_root(home, home_identity, uid, open_fds)
            library_fd = ensure_expected_directory(
                root_fd, "Library", library_expected, uid, "Library directory", open_fds
            )
            agents_fd = ensure_expected_directory(
                library_fd, "LaunchAgents", agents_expected, uid, "LaunchAgents directory", open_fds
            )
            logs_fd = ensure_expected_directory(
                library_fd, "Logs", logs_expected, uid, "Logs directory", open_fds
            )
            return "\t".join(
                [display_identity(os.fstat(library_fd)), display_identity(os.fstat(agents_fd)), display_identity(os.fstat(logs_fd))]
            )

        home, home_identity, uid, library_identity, agents_identity = parse_common(values)
        root_fd = open_root(home, home_identity, uid, open_fds)
        library_fd = open_expected_directory(
            root_fd, "Library", library_identity, uid, "Library directory", open_fds
        )
        agents_fd = open_expected_directory(
            library_fd, "LaunchAgents", agents_identity, uid, "LaunchAgents directory", open_fds
        )
        if operation == "verify-directory":
            return ""
        if len(values) < 7:
            fail(STATE, "invalid secure agent operation")
        label = values[5]
        destination_identity = parse_identity(values[6], "agent destination")
        if operation == "verify":
            name = validate_label(label)
            current = verify_destination(agents_fd, name, destination_identity, uid, label)
            if current is None:
                fail(CONFLICT, "agent destination is missing")
            return ""
        if operation == "remove":
            if destination_identity is None:
                fail(CONFLICT, "agent destination is missing")
            remove_destination(agents_fd, label, destination_identity, uid)
            return ""
        if operation == "publish":
            if len(values) != 11:
                fail(STATE, "invalid secure agent publication")
            template, trellis_home, logs_dir, launcher = values[7:11]
            return publish(
                agents_fd,
                label,
                destination_identity,
                template,
                home,
                trellis_home,
                logs_dir,
                launcher,
                uid,
            )
        fail(STATE, "unknown secure LaunchAgents operation")
    finally:
        for descriptor in reversed(open_fds):
            try:
                os.close(descriptor)
            except OSError:
                pass


try:
    output = run()
except LaunchdError as error:
    sys.stderr.write("trellis launchd: %s\n" % error.message)
    sys.exit(error.code)
except (TypeError, ValueError) as error:
    sys.stderr.write("trellis launchd: invalid secure LaunchAgents operation: %s\n" % error)
    sys.exit(STATE)
except OSError as error:
    sys.stderr.write("trellis launchd: secure LaunchAgents operation failed: %s\n" % error)
    sys.exit(UNAVAILABLE)
else:
    if output:
        print(output)
PY
  then
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    "$TRELLIS_EX_CONFLICT"|"$TRELLIS_EX_STATE"|"$TRELLIS_EX_UNAVAILABLE") return "$rc" ;;
    *)
      printf 'trellis launchd: secure descriptor helper failed\n' >&2
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

plist_is_owned() {
  local label="$1" destination="$2"
  [ "$(plist_value "$destination" Label)" = "$label" ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.0)" = '/usr/bin/env' ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.1)" = '-i' ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.2)" = "HOME=$user_home" ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.3)" = "TRELLIS_HOME=$trellis_home" ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.4)" = 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.5)" = '/bin/bash' ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.6)" = '--noprofile' ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.7)" = '--norc' ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.8)" = "$launcher" ] || return 1
  [ "$(plist_value "$destination" ProgramArguments.9)" = 'disk-janitor' ] || return 1
  ! plist_value "$destination" EnvironmentVariables >/dev/null 2>&1 || return 1
  [ "$(plist_value "$destination" StandardOutPath)" = "$logs_dir/$label.log" ] || return 1
  [ "$(plist_value "$destination" StandardErrorPath)" = "$logs_dir/$label.log" ] || return 1
  [ "$(plist_value "$destination" RunAtLoad)" = false ] || return 1
  case "$label" in
    org.trellis.disk-janitor)
      [ "$(plist_value "$destination" ProgramArguments.10)" = '--report' ] || return 1
      ! plist_value "$destination" ProgramArguments.11 >/dev/null 2>&1 || return 1
      [ "$(plist_value "$destination" StartCalendarInterval.Hour)" = 3 ] || return 1
      [ "$(plist_value "$destination" StartCalendarInterval.Minute)" = 30 ] || return 1
      ;;
    org.trellis.disk-janitor-apply)
      [ "$(plist_value "$destination" ProgramArguments.10)" = '--apply' ] || return 1
      [ "$(plist_value "$destination" ProgramArguments.11)" = '--scopes' ] || return 1
      [ "$(plist_value "$destination" ProgramArguments.12)" = worktrees ] || return 1
      [ "$(plist_value "$destination" ProgramArguments.13)" = '--yes' ] || return 1
      [ "$(plist_value "$destination" ProgramArguments.14)" = '--safe-only' ] || return 1
      ! plist_value "$destination" ProgramArguments.15 >/dev/null 2>&1 || return 1
      [ "$(plist_value "$destination" StartCalendarInterval.Hour)" = 4 ] || return 1
      [ "$(plist_value "$destination" StartCalendarInterval.Minute)" = 0 ] || return 1
      ;;
    *) return 1 ;;
  esac
}

require_owned_destination() {
  local label="$1" destination="$2"
  [ ! -L "$destination" ] || {
    printf 'trellis launchd: refusing symlinked agent destination: %s\n' "$destination" >&2
    return "$TRELLIS_EX_CONFLICT"
  }
  [ ! -e "$destination" ] || {
    [ -f "$destination" ] || {
      printf 'trellis launchd: refusing non-regular agent destination: %s\n' "$destination" >&2
      return "$TRELLIS_EX_CONFLICT"
    }
    require_private_regular_file "$destination" 'agent destination' "$TRELLIS_EX_CONFLICT" || return "$?"
    plist_is_owned "$label" "$destination" || {
      printf 'trellis launchd: refusing unowned agent destination: %s\n' "$destination" >&2
      return "$TRELLIS_EX_CONFLICT"
    }
  }
}

require_launch_agents_directory() {
  launch_agents_secure_operation verify-directory \
    "$user_home" "$user_home_identity" "$installer_uid" \
    "$library_identity" "$launch_agents_identity"
}

prepare_launch_agents_directories() {
  local identities
  identities="$(launch_agents_secure_operation prepare \
    "$user_home" "$user_home_identity" "$installer_uid" \
    "$library_identity" "$launch_agents_identity" "$logs_identity")" || return "$?"
  IFS=$'\t' read -r library_identity launch_agents_identity logs_identity <<< "$identities"
  case "$library_identity:$launch_agents_identity:$logs_identity" in
    [0-9]*:[0-9]*:[0-9]*:[0-9]*:[0-9]*:[0-9]*) ;;
    *)
      printf 'trellis launchd: could not retain secure LaunchAgents identities\n' >&2
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
}

verify_finalized_destination() {
  local label="$1" identity="$2"
  launch_agents_secure_operation verify \
    "$user_home" "$user_home_identity" "$installer_uid" \
    "$library_identity" "$launch_agents_identity" \
    "$label" "$identity"
}

publish_plist() {
  local label="$1" template="$2" expected_identity="$3"
  launch_agents_secure_operation publish \
    "$user_home" "$user_home_identity" "$installer_uid" \
    "$library_identity" "$launch_agents_identity" \
    "$label" "$expected_identity" "$template" \
    "$trellis_home" "$logs_dir" "$launcher"
}

remove_plist() {
  local label="$1" expected_identity="$2"
  launch_agents_secure_operation remove \
    "$user_home" "$user_home_identity" "$installer_uid" \
    "$library_identity" "$launch_agents_identity" \
    "$label" "$expected_identity"
}

launchctl_run() {
  /bin/launchctl "$@"
}

preflight_template() {
  local label="$1" template="$template_dir/$1.plist"
  [ -f "$template" ] && [ ! -L "$template" ] || {
    printf 'trellis launchd: template missing: %s\n' "$template" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  if ! plist_lint "$template"; then
    printf 'trellis launchd: template is invalid: %s\n' "$template" >&2
    return "$TRELLIS_EX_STATE"
  fi
}

remove_agent() {
  local label="$1" destination expected_identity
  destination="$launch_agents_dir/$label.plist"
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    printf 'nothing to do: %s not present\n' "$destination"
    return 0
  fi
  require_launch_agents_directory || return "$?"
  require_owned_destination "$label" "$destination" || return "$?"
  expected_identity="$(path_device_inode "$destination")" || {
    printf 'trellis launchd: could not snapshot agent destination: %s\n' "$destination" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  verify_finalized_destination "$label" "$expected_identity" || return "$?"
  launchctl_run unload "$destination" 2>/dev/null || true
  remove_plist "$label" "$expected_identity" || return "$?"
  printf 'removed: %s\n' "$destination"
}

install_agent() {
  local label="$1" template="$template_dir/$1.plist" destination="$launch_agents_dir/$1.plist"
  local expected_identity='-' published_identity had_existing=false
  [ -f "$template" ] && [ ! -L "$template" ] || {
    printf 'trellis launchd: template missing: %s\n' "$template" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  require_launch_agents_directory || return "$?"
  require_owned_destination "$label" "$destination" || return "$?"
  if [ -e "$destination" ]; then
    expected_identity="$(path_device_inode "$destination")" || {
      printf 'trellis launchd: could not snapshot agent destination: %s\n' "$destination" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    }
    had_existing=true
    verify_finalized_destination "$label" "$expected_identity" || return "$?"
  fi
  if "$had_existing"; then launchctl_run unload "$destination" 2>/dev/null || true; fi
  published_identity="$(publish_plist "$label" "$template" "$expected_identity")" || return "$?"
  verify_finalized_destination "$label" "$published_identity" || return "$?"
  launchctl_run load "$destination" || return "$TRELLIS_EX_UNAVAILABLE"
  printf 'installed: %s\n' "$destination"
}

installer_uid=''
user_home_identity=''
library_identity=''
launch_agents_identity=''
logs_identity=''
INSTALLER_SYSTEM_NAME="$("/usr/bin/uname" -s)"
report_label='org.trellis.disk-janitor'
apply_label='org.trellis.disk-janitor-apply'
template_dir="$(CDPATH='' cd "$SCRIPT_DIR/../core-rules/templates" && pwd -P)"

main() {
  local arg user_home_input trellis_home_input launcher_dir label library_dir
  local -a selected_labels
  uninstall=false
  with_apply=false

  for arg in "$@"; do
    case "$arg" in
      --uninstall) uninstall=true ;;
      --with-apply) with_apply=true ;;
      --help|-h) usage; return 0 ;;
      -*) printf 'trellis launchd: unknown option: %s\n' "$arg" >&2; return "$TRELLIS_EX_USAGE" ;;
      *) printf 'trellis launchd: unexpected argument: %s\n' "$arg" >&2; return "$TRELLIS_EX_USAGE" ;;
    esac
  done

  user_home_input="${HOME:-}"
  [ -n "$user_home_input" ] || {
    printf 'trellis launchd: HOME is required\n' >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  user_home="$(canonical_existing_directory "$user_home_input" 'operator home')" || return "$?"
  installer_uid="$("/usr/bin/id" -u)" || return "$TRELLIS_EX_UNAVAILABLE"
  case "$installer_uid" in
    ''|*[!0-9]*)
      printf 'trellis launchd: could not determine current operator identity\n' >&2
      return "$TRELLIS_EX_UNAVAILABLE"
      ;;
  esac
  require_safe_directory "$user_home" 'operator home' || return "$?"
  user_home_identity="$(path_device_inode "$user_home")" || {
    printf 'trellis launchd: could not snapshot operator home identity: %s\n' "$user_home" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  trellis_home_input="$(trellis_home_resolve "")" || return "$?"
  trellis_home="$(canonical_existing_directory "$trellis_home_input" 'Trellis home')" || return "$?"
  launcher="$user_home/.local/bin/trellis"
  if ! "$uninstall"; then
    # shellcheck disable=SC2034  # Called for its validation and non-zero return; the path itself
    # is resolved again by the caller. Capturing stdout keeps the probe off the installer's output.
    launcher_dir="$(require_real_child_directory "$user_home" '.local/bin' 'stable launcher directory')" || return "$?"
    [ -f "$launcher" ] && [ ! -L "$launcher" ] && [ -x "$launcher" ] || {
      printf 'trellis launchd: canonical stable launcher is unavailable or unsafe: %s\n' "$launcher" >&2
      printf 'trellis launchd: run trellis configure to install the stable launcher first\n' >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    }
    require_path_controls "$launcher" 'stable launcher' "$TRELLIS_EX_STATE" || return "$?"
  fi

  if "$uninstall"; then
    selected_labels=("$apply_label" "$report_label")
  else
    selected_labels=("$report_label")
    if "$with_apply"; then selected_labels+=("$apply_label"); fi
  fi

  library_dir="$user_home/Library"
  launch_agents_dir="$(preflight_real_child_directory "$user_home" 'Library/LaunchAgents' 'LaunchAgents directory')" || return "$?"
  logs_dir="$user_home/Library/Logs"
  if ! "$uninstall"; then
    logs_dir="$(preflight_real_child_directory "$user_home" 'Library/Logs' 'Logs directory')" || return "$?"
  fi
  library_identity="$(snapshot_directory_identity "$library_dir" 'Library directory')" || return "$?"
  launch_agents_identity="$(snapshot_directory_identity "$launch_agents_dir" 'LaunchAgents directory')" || return "$?"
  if "$uninstall"; then
    logs_identity='-'
  else
    logs_identity="$(snapshot_directory_identity "$logs_dir" 'Logs directory')" || return "$?"
  fi
  for label in "${selected_labels[@]}"; do
    if ! "$uninstall"; then preflight_template "$label" || return "$?"; fi
    require_owned_destination "$label" "$launch_agents_dir/$label.plist" || return "$?"
  done

  if "$uninstall"; then
    remove_agent "$apply_label" || return "$?"
    remove_agent "$report_label" || return "$?"
    return 0
  fi

  prepare_launch_agents_directories || return "$?"
  require_launch_agents_directory || return "$?"
  for label in "${selected_labels[@]}"; do
    require_owned_destination "$label" "$launch_agents_dir/$label.plist" || return "$?"
  done

  install_agent "$report_label" || return "$?"
  printf '  runs: %s disk-janitor --report (daily 03:30, report-only)\n' "$launcher"
  printf '  TRELLIS_HOME: %s\n' "$trellis_home"
  printf '  logs: %s/%s.log\n' "$logs_dir" "$report_label"

  if "$with_apply"; then
    printf '\n!! installing the NIGHTLY APPLY agent — this one DELETES worktrees.\n'
    install_agent "$apply_label" || return "$?"
    printf '  runs: %s disk-janitor --apply --scopes worktrees --yes --safe-only (daily 04:00)\n' "$launcher"
    printf '  reaps ONLY: merged + porcelain-clean + non-detached + non-secret worktrees\n'
    printf '  NEVER reaps: pushed-but-unmerged, dirty, secret-bearing, or ephemeral /private/tmp trees\n'
    printf '  logs: %s/%s.log\n' "$logs_dir" "$apply_label"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
