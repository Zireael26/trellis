#!/usr/bin/env bash
# Attach an inert portable project to one immutable local Trellis release.
# Bash 3.2 compatible.

set -u

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/trellis-home.sh
  . "$SCRIPT_DIR/lib/trellis-home.sh"
  # shellcheck source=lib/release-store.sh
  . "$SCRIPT_DIR/lib/release-store.sh"
  # shellcheck source=lib/local-registry.sh
  . "$SCRIPT_DIR/lib/local-registry.sh"
  # shellcheck source=lib/surface-plan.sh
  . "$SCRIPT_DIR/lib/surface-plan.sh"
  # shellcheck source=lib/attachment.sh
  . "$SCRIPT_DIR/lib/attachment.sh"
fi

ATTACH_EXCLUDE_BEGIN='# --- Trellis local attachment exclude block ---'
ATTACH_EXCLUDE_END='# --- end Trellis local attachment exclude block ---'

attach_err() {
  printf 'trellis attach: %s\n' "$*" >&2
}

attach_usage() {
  cat <<'EOF'
Usage:
  attach-project.sh attach [--home PATH] [--fleet NAME] [--release VERSION] [--harness claude|codex|omp]... PATH
  attach-project.sh detach [--home PATH] [--harness claude|codex|omp]... [--all-worktrees] PATH
  attach-project.sh relink [--home PATH] [--fleet NAME] PATH
  attach-project.sh recover [--home PATH] PATH

Attach resolves an immutable installed release, creates only local native harness
leaves, and owns one exact block in the Git common directory's info/exclude.
Detach removes only exact owned leaves and restores common local state after
the final committed worktree owner leaves.
EOF
}

attach_usage_error() {
  attach_err "$*"
  attach_usage >&2
  return "$TRELLIS_EX_USAGE"
}

attach_sha_text() {
  _attachment_hash_text "$1"
}

attach_sha_file() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] || return "$TRELLIS_EX_STATE"
  _attachment_hash "$path"
}

attach_verify_owner_artifacts() {
  local status
  _attachment_verify_owner_artifacts_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attach_base64_file() {
  local path="$1"
  if [ -s "$path" ]; then
    base64 < "$path" | tr -d '\n'
  fi
}

attach_base64_text() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

attach_decode_base64() {
  local value="$1"
  if [ -n "$value" ]; then
    printf '%s' "$value" | base64 -D 2>/dev/null || printf '%s' "$value" | base64 -d 2>/dev/null
  fi
}

attach_uuid() {
  local raw
  if command -v uuidgen >/dev/null 2>&1; then
    raw="$(uuidgen | tr '[:upper:]' '[:lower:]')" || return "$TRELLIS_EX_UNAVAILABLE"
  else
    raw="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  printf '%s\n' "$raw"
}

attach_canonical_root() {
  local root="${1:-}" top
  root="$(local_registry_real_directory 'project root' "$root")" || return "$?"
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || {
    attach_err "project root is not a Git worktree: $root"
    return "$TRELLIS_EX_STATE"
  }
  top="$(local_registry_real_directory 'Git worktree top level' "$top")" || return "$?"
  [ "$root" = "$top" ] || {
    attach_err "project root must equal the Git worktree top level: $root"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$root"
}

attach_relink_runtime_anchor_plan() {
  local root="$1" expected="$2" runtime root_identity trellis_identity expected_old=""
  runtime="$root/.trellis/runtime"
  root_identity="$(release_store_directory_identity "$root")" || {
    attach_err 'project root changed before runtime anchor repair'
    return "$TRELLIS_EX_CONFLICT"
  }
  trellis_identity="$(release_store_directory_identity "$root/.trellis")" || {
    attach_err 'attachment runtime parent changed before runtime anchor repair'
    return "$TRELLIS_EX_CONFLICT"
  }
  if [ -L "$runtime" ]; then
    expected_old="$(readlink "$runtime")" || return "$TRELLIS_EX_STATE"
    if [ "$expected_old" != "$expected" ]; then
      attach_err "runtime anchor points to a different immutable release"
      return "$TRELLIS_EX_STATE"
    fi
  elif [ -e "$runtime" ]; then
    attach_err "owned attachment artifacts are modified"
    return "$TRELLIS_EX_CONFLICT"
  fi
  jq -cn --arg root_identity "$root_identity" --arg trellis_identity "$trellis_identity" \
    --arg expected_old "$expected_old" \
    '{root_identity:$root_identity,trellis_identity:$trellis_identity,expected_old:$expected_old}'
}

attach_relink_identity_matches_locked() {
  local root="$1" locked_identity="$2" current
  current="$(local_registry_identity_for_root "$root")" || return "$TRELLIS_EX_CONFLICT"
  [ "$current" = "$locked_identity" ] || {
    attach_err 'Git worktree identity changed while holding the checkout lock'
    return "$TRELLIS_EX_CONFLICT"
  }
}

attach_relink_directory_identity() {
  release_store_directory_identity "$1" || return "$TRELLIS_EX_CONFLICT"
}
attach_locked_checkout_namespace_matches() {
  local root="$1" locked_identity="$2" locked_root_dev_ino="$3" locked_common_dev_ino="$4"
  local current common current_root_dev_ino current_common_dev_ino
  [ "$#" -eq 4 ] || return "$TRELLIS_EX_STATE"
  current="$(local_registry_identity_for_root "$root")" || {
    attach_err 'Git worktree identity changed while holding the checkout lock'
    return "$TRELLIS_EX_CONFLICT"
  }
  [ "$current" = "$locked_identity" ] || {
    attach_err 'Git worktree identity changed while holding the checkout lock'
    return "$TRELLIS_EX_CONFLICT"
  }
  common="$(printf '%s\n' "$current" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  current_root_dev_ino="$(attach_relink_directory_identity "$root")" || {
    attach_err 'Git worktree filesystem identity changed while holding the checkout lock'
    return "$TRELLIS_EX_CONFLICT"
  }
  current_common_dev_ino="$(attach_relink_directory_identity "$common")" || {
    attach_err 'Git common directory filesystem identity changed while holding the checkout lock'
    return "$TRELLIS_EX_CONFLICT"
  }
  [ "$current_root_dev_ino" = "$locked_root_dev_ino" ] &&
    [ "$current_common_dev_ino" = "$locked_common_dev_ino" ] || {
      attach_err 'Git worktree filesystem identity changed while holding the checkout lock'
      return "$TRELLIS_EX_CONFLICT"
    }
  printf '%s\n' "$current"
}
attach_expected_sha256_valid() {
  local value="${1:-}"
  [ "$#" -eq 1 ] || return 1
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in
    ''|*[!0123456789abcdef]*) return 1 ;;
  esac
  return 0
}

attach_expected_directory_identity_valid() {
  local value="${1:-}" device inode
  [ "$#" -eq 1 ] || return 1
  case "$value" in
    *:*) ;;
    *) return 1 ;;
  esac
  device="${value%%:*}"
  inode="${value#*:}"
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  case "$device:$inode" in
    *:*:*) return 1 ;;
  esac
  case "$device" in *[!0-9]*) return 1 ;; esac
  case "$inode" in *[!0-9]*) return 1 ;; esac
  return 0
}

# Read a state file through a no-follow descriptor rooted at its canonical
# parent.  An expected parent identity is optional for journals; owner repair
# tokens pin it so a same-name parent replacement cannot redirect a repair.
attach_repair_state_file_matches() {
  local path="$1" expected_sha256="$2" expected_parent_dev_ino="${3:-}"
  [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || return "$TRELLIS_EX_STATE"
  attach_expected_sha256_valid "$expected_sha256" || return "$TRELLIS_EX_STATE"
  if [ -n "$expected_parent_dev_ino" ]; then
    attach_expected_directory_identity_valid "$expected_parent_dev_ino" || return "$TRELLIS_EX_STATE"
  fi
  [ -x /usr/bin/python3 ] || return "$TRELLIS_EX_UNAVAILABLE"
  /usr/bin/python3 - "$path" "$expected_sha256" "$expected_parent_dev_ino" <<'PY'
import hashlib
import os
import stat
import sys

path, expected_sha256, expected_parent_identity = sys.argv[1:4]


def fail(code):
    raise SystemExit(code)


def parse_identity(value):
    if not value:
        return None
    parts = value.split(":", 1)
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        fail(17)
    return (int(parts[0]), int(parts[1]))


def open_absolute_directory(path):
    if not path.startswith("/") or path == "/":
        fail(17)
    components = path.split("/")[1:]
    if not components or any(not item or item in (".", "..") for item in components):
        fail(17)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        descriptor = os.open("/", flags)
    except OSError:
        fail(17)
    try:
        for component in components:
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except OSError:
        os.close(descriptor)
        fail(17)


def same_identity(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


if len(expected_sha256) != 64 or any(character not in "0123456789abcdef" for character in expected_sha256):
    fail(17)
if not getattr(os, "O_DIRECTORY", 0) or not getattr(os, "O_NOFOLLOW", 0):
    fail(18)
parent = os.path.dirname(path)
base = os.path.basename(path)
if not parent or not base or base in (".", ".."):
    fail(17)
expected_parent = parse_identity(expected_parent_identity)
parent_fd = open_absolute_directory(parent)
try:
    parent_before = os.fstat(parent_fd)
    if not stat.S_ISDIR(parent_before.st_mode):
        fail(17)
    if expected_parent is not None and (parent_before.st_dev, parent_before.st_ino) != expected_parent:
        fail(17)
    try:
        path_before = os.stat(base, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(path_before.st_mode):
            fail(17)
        file_fd = os.open(base, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError:
        fail(17)
    try:
        file_state = os.fstat(file_fd)
        if not stat.S_ISREG(file_state.st_mode) or not same_identity(path_before, file_state):
            fail(17)
        digest = hashlib.sha256()
        while True:
            chunk = os.read(file_fd, 131072)
            if not chunk:
                break
            digest.update(chunk)
        if digest.hexdigest() != expected_sha256:
            fail(17)
        path_after = os.stat(base, dir_fd=parent_fd, follow_symlinks=False)
        if not same_identity(path_after, file_state):
            fail(17)
        if not same_identity(os.fstat(parent_fd), parent_before):
            fail(17)
    finally:
        os.close(file_fd)
finally:
    os.close(parent_fd)
PY
  case "$?" in
    0) return 0 ;;
    17) return "$TRELLIS_EX_CONFLICT" ;;
    *) return "$TRELLIS_EX_UNAVAILABLE" ;;
  esac
}

attach_expected_journal_state_matches() {
  local journal="$1" expected_sha256="${2:-}" supplied=false rc
  if [ -z "$expected_sha256" ]; then
    expected_sha256="$(attach_sha_file "$journal")" || {
      attach_err 'attachment journal is unavailable or unsafe'
      return "$TRELLIS_EX_CONFLICT"
    }
  else
    supplied=true
  fi
  attach_repair_state_file_matches "$journal" "$expected_sha256"
  rc=$?
  if [ "$rc" -eq "$TRELLIS_EX_CONFLICT" ]; then
    if [ "$supplied" = true ]; then
      attach_err 'expected attachment journal changed while waiting for delegated recovery'
    else
      attach_err 'attachment journal is unavailable or unsafe'
    fi
  fi
  return "$rc"
}

attach_expected_owner_state_matches() {
  local owner="$1" expected_sha256="${2:-}" expected_parent_dev_ino="${3:-}"
  local supplied=false parent rc
  if [ -z "$expected_sha256" ] && [ -z "$expected_parent_dev_ino" ]; then
    parent="$(dirname "$owner")" || return "$TRELLIS_EX_STATE"
    expected_sha256="$(attach_sha_file "$owner")" || {
      attach_err 'attachment owner is unavailable or unsafe'
      return "$TRELLIS_EX_CONFLICT"
    }
    expected_parent_dev_ino="$(attach_relink_directory_identity "$parent")" || {
      attach_err 'attachment ownership parent is unavailable or unsafe'
      return "$TRELLIS_EX_CONFLICT"
    }
  else
    supplied=true
    [ -n "$expected_sha256" ] && [ -n "$expected_parent_dev_ino" ] || return "$TRELLIS_EX_STATE"
  fi
  attach_repair_state_file_matches "$owner" "$expected_sha256" "$expected_parent_dev_ino"
  rc=$?
  if [ "$rc" -eq "$TRELLIS_EX_CONFLICT" ]; then
    if [ "$supplied" = true ]; then
      attach_err 'expected attachment owner changed while waiting for delegated repair'
    else
      attach_err 'attachment owner is unavailable or unsafe'
    fi
  fi
  return "$rc"
}



attach_relink_set_hooks_path_pinned() {
  local root="$1" locked_identity="$2" root_dev_ino="$3" common_dev_ino="$4" managed="$5"
  attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$root_dev_ino" "$common_dev_ino" >/dev/null || return "$?"
  [ -x /usr/bin/python3 ] || return "$TRELLIS_EX_UNAVAILABLE"
  /usr/bin/python3 - "$root" "$locked_identity" "$root_dev_ino" "$common_dev_ino" "$managed" <<'PY'
import hashlib
import json
import os
import stat
import subprocess
import sys

root, identity, root_identity, common_identity, managed = sys.argv[1:6]


def fail(code):
    raise SystemExit(code)


def parse_identity(value):
    if not isinstance(value, str):
        fail(17)
    parts = value.split(":", 1)
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        fail(17)
    return (int(parts[0]), int(parts[1]))


def identity_of(value):
    return (value.st_dev, value.st_ino)


def checked_fd(descriptor, expected):
    value = os.fstat(descriptor)
    if not stat.S_ISDIR(value.st_mode) or identity_of(value) != expected:
        fail(17)


def checked_open_directory(path, expected):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        fail(17)
    try:
        checked_fd(descriptor, expected)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


try:
    expected = json.loads(identity)
    common = expected["git_common_dir"]
    checkout = expected["checkout_id"]
    expected_root = expected["root"]
except (KeyError, TypeError, ValueError):
    fail(17)

if not isinstance(common, str) or not isinstance(checkout, str) or not isinstance(expected_root, str):
    fail(17)
if expected_root != root or hashlib.sha256(common.encode("utf-8")).hexdigest() != checkout:
    fail(17)
if not isinstance(managed, str) or not managed.startswith("/") or any(ord(char) < 32 or ord(char) == 127 for char in managed):
    fail(17)

expected_root_identity = parse_identity(root_identity)
expected_common_identity = parse_identity(common_identity)
if not getattr(os, "O_DIRECTORY", 0) or not getattr(os, "O_NOFOLLOW", 0):
    fail(18)

root_fd = None
common_fd = None
try:
    root_fd = checked_open_directory(root, expected_root_identity)
    common_fd = checked_open_directory(common, expected_common_identity)

    if os.path.realpath(root) != expected_root or os.path.realpath(common) != common:
        fail(17)
    config = os.stat("config", dir_fd=common_fd, follow_symlinks=False)
    if not stat.S_ISREG(config.st_mode):
        fail(17)

    def revalidate_namespace():
        # Verify the retained descriptors and current names immediately before
        # Git creates its config lock and publishes core.hooksPath.
        checked_fd(root_fd, expected_root_identity)
        checked_fd(common_fd, expected_common_identity)
        fresh_root = checked_open_directory(root, expected_root_identity)
        fresh_common = checked_open_directory(common, expected_common_identity)
        try:
            if os.path.realpath(root) != expected_root or os.path.realpath(common) != common:
                fail(17)
        finally:
            os.close(fresh_common)
            os.close(fresh_root)

    revalidate_namespace()
    os.fchdir(common_fd)
    clean_env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/dev/null",
        "TMPDIR": "/tmp",
        "TMP": "/tmp",
        "TEMP": "/tmp",
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    }
    write = subprocess.run(
        ["/usr/bin/git", "config", "--file", "config", "core.hooksPath", managed],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=clean_env,
        close_fds=True,
    )
    if write.returncode != 0:
        fail(18)
    verify = subprocess.run(
        ["/usr/bin/git", "config", "--file", "config", "--get-all", "core.hooksPath"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=clean_env,
        close_fds=True,
    )
    if verify.returncode != 0 or verify.stdout != (managed + "\n").encode("utf-8"):
        fail(17)
    revalidate_namespace()
except SystemExit:
    raise
except OSError:
    fail(18)
finally:
    if common_fd is not None:
        os.close(common_fd)
    if root_fd is not None:
        os.close(root_fd)
PY
  case "$?" in
    0) ;;
    17)
      attach_err 'Git worktree identity changed before managed hook publication'
      return "$TRELLIS_EX_CONFLICT"
      ;;
    *) return "$TRELLIS_EX_UNAVAILABLE" ;;
  esac
}


attach_exclude_block() {
  local surfaces="$1"
  printf '%s\n' "$ATTACH_EXCLUDE_BEGIN"
  printf '%s\n' "$surfaces" | jq -r '
    ["/.trellis/runtime"]
    + [.artifacts[].destination | "/" + .]
    | unique
    | sort
    | .[]
  ' || return "$TRELLIS_EX_STATE"
  printf '%s\n' "$ATTACH_EXCLUDE_END"
}

attach_exclude_parse() {
  # Emits `none` or `one`; rejects malformed, duplicate, or modified blocks.
  local file="$1" block_file="$2" line state=outside count=0 block="" expected
  expected="$(cat "$block_file")" || return "$TRELLIS_EX_UNAVAILABLE"
  [ -e "$file" ] || [ -L "$file" ] || { printf 'none\n'; return 0; }
  [ -f "$file" ] && [ ! -L "$file" ] || return "$TRELLIS_EX_CONFLICT"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$state:$line" in
      outside:"$ATTACH_EXCLUDE_BEGIN") state=inside; count=$((count + 1)); block="$line" ;;
      outside:"$ATTACH_EXCLUDE_END") return "$TRELLIS_EX_CONFLICT" ;;
      outside:*) ;;
      inside:"$ATTACH_EXCLUDE_END")
        block="$block
$line"
        [ "$block" = "$expected" ] || return "$TRELLIS_EX_CONFLICT"
        state=after
        ;;
      inside:"$ATTACH_EXCLUDE_BEGIN") return "$TRELLIS_EX_CONFLICT" ;;
      inside:*) block="$block
$line" ;;
      after:"$ATTACH_EXCLUDE_BEGIN"|after:"$ATTACH_EXCLUDE_END") return "$TRELLIS_EX_CONFLICT" ;;
      after:*) ;;
    esac
  done < "$file"
  [ "$state" != inside ] || return "$TRELLIS_EX_CONFLICT"
  [ "$count" -le 1 ] || return "$TRELLIS_EX_CONFLICT"
  if [ "$count" -eq 1 ]; then printf 'one\n'; else printf 'none\n'; fi
}

attach_exclude_compose() {
  local source="$1" output="$2" block_file="$3" size last
  : > "$output" || return "$TRELLIS_EX_UNAVAILABLE"
  if [ -e "$source" ] || [ -L "$source" ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || return "$TRELLIS_EX_CONFLICT"
    cat "$source" > "$output" || return "$TRELLIS_EX_UNAVAILABLE"
    size="$(wc -c < "$source" | tr -d ' ')" || return "$TRELLIS_EX_UNAVAILABLE"
    if [ "$size" -gt 0 ]; then
      last="$(dd if="$source" bs=1 skip=$((size - 1)) count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" || return "$TRELLIS_EX_UNAVAILABLE"
      [ "$last" = 0a ] || printf '\n' >> "$output" || return "$TRELLIS_EX_UNAVAILABLE"
    fi
  fi
  cat "$block_file" >> "$output" || return "$TRELLIS_EX_UNAVAILABLE"
}

attach_exclude_state() {
  local common="$1" before="$2" after="$3" before_exists="$4" after_exists="$5" managed_by_attachment="$6" block_file="$7"
  local path="$common/info/exclude" before_hash after_hash block_hash before64 after64 block64
  before_hash="$(attach_sha_file "$before")" || return "$?"
  after_hash="$(attach_sha_file "$after")" || return "$?"
  block_hash="$(attach_sha_file "$block_file")" || return "$?"
  before64="$(attach_base64_file "$before")" || return "$?"
  after64="$(attach_base64_file "$after")" || return "$?"
  block64="$(attach_base64_file "$block_file")" || return "$?"
  jq -cn \
    --arg path "$path" --arg common "$common" \
    --arg before_hash "$before_hash" --arg before64 "$before64" \
    --arg block_hash "$block_hash" --arg block64 "$block64" \
    --arg after_hash "$after_hash" --arg after64 "$after64" \
    --argjson before_exists "$before_exists" --argjson after_exists "$after_exists" \
    --argjson managed_by_attachment "$managed_by_attachment" \
    '{path:$path,git_common_dir:$common,before_exists:$before_exists,before_sha256:$before_hash,before_base64:$before64,managed_block_sha256:$block_hash,managed_block_base64:$block64,after_exists:$after_exists,after_sha256:$after_hash,after_base64:$after64,managed_by_attachment:$managed_by_attachment}'
}

attach_exclude_preflight() (
  local home="$1" checkout="$2" common="$3" before="$4" after="$5" surfaces="$6" state block_state before_exists=false block_file rc
  local path="$common/info/exclude"
  block_file="$(mktemp "${TMPDIR:-/tmp}/trellis.exclude.block.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  trap 'rm -f "$block_file"' EXIT
  attach_exclude_block "$surfaces" > "$block_file" || return "$?"
  [ -d "$common/info" ] && [ ! -L "$common/info" ] || return "$TRELLIS_EX_STATE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return "$TRELLIS_EX_CONFLICT"
    before_exists=true
  fi
  : > "$before" || return "$TRELLIS_EX_UNAVAILABLE"
  if [ "$before_exists" = true ]; then
    cat "$path" > "$before" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  block_state="$(attach_exclude_parse "$path" "$block_file")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$block_state" = one ]; then
    state="$(attach_shared_exclude_state "$home" "$checkout" "$common" "$block_file" "$before" "$after")" || {
      rc=$?
      attach_err "managed exclude block has no matching committed checkout ownership"
      return "$rc"
    }
    printf '%s\n' "$state"
    return 0
  fi
  attach_exclude_compose "$path" "$after" "$block_file" || return "$?"
  state="$(attach_exclude_state "$common" "$before" "$after" "$before_exists" true true "$block_file")" || return "$?"
  printf '%s\n' "$state"
)

attach_exclude_verify_state() (
  local exclude_json="$1" expected_path actual expected_hash block_file block_hash block64
  expected_path="$(printf '%s\n' "$exclude_json" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  actual="$(mktemp "${TMPDIR:-/tmp}/trellis.exclude.actual.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  block_file="$(mktemp "${TMPDIR:-/tmp}/trellis.exclude.block.XXXXXX")" || { rm -f "$actual"; return "$TRELLIS_EX_UNAVAILABLE"; }
  trap 'rm -f "$actual" "$block_file"' EXIT
  block_hash="$(printf '%s\n' "$exclude_json" | jq -r '.managed_block_sha256')" || return "$TRELLIS_EX_STATE"
  block64="$(printf '%s\n' "$exclude_json" | jq -r '.managed_block_base64')" || return "$TRELLIS_EX_STATE"
  attach_decode_base64 "$block64" > "$block_file" || return "$TRELLIS_EX_STATE"
  [ "$(attach_sha_file "$block_file")" = "$block_hash" ] || return "$TRELLIS_EX_STATE"
  if [ -e "$expected_path" ] || [ -L "$expected_path" ]; then
    [ -f "$expected_path" ] && [ ! -L "$expected_path" ] || return "$TRELLIS_EX_CONFLICT"
    cat "$expected_path" > "$actual" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  expected_hash="$(printf '%s\n' "$exclude_json" | jq -r '.after_sha256')" || return "$TRELLIS_EX_STATE"
  [ "$(attach_sha_file "$actual")" = "$expected_hash" ] || return "$TRELLIS_EX_CONFLICT"
  [ "$(attach_exclude_parse "$expected_path" "$block_file")" = one ] || return "$TRELLIS_EX_CONFLICT"
)

attach_shared_exclude_state() {
  local home="$1" checkout="$2" common="$3" block_file="$4" before="$5" after="$6"
  local owner_dir="$home/state/attachments/$checkout" owner exclude block_hash found=false
  [ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] || return "$TRELLIS_EX_CONFLICT"
  block_hash="$(attach_sha_file "$block_file")" || return "$?"
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    [ -f "$owner" ] && [ ! -L "$owner" ] || return "$TRELLIS_EX_CONFLICT"
    attachment_verify "$home" "$owner" || return "$?"
    exclude="$(jq -c '.exclude' "$owner")" || return "$TRELLIS_EX_STATE"
    [ "$(printf '%s\n' "$exclude" | jq -r '.git_common_dir')" = "$common" ] || return "$TRELLIS_EX_STATE"
    [ "$(printf '%s\n' "$exclude" | jq -r '.managed_block_sha256')" = "$block_hash" ] || return "$TRELLIS_EX_CONFLICT"
    attach_exclude_verify_state "$exclude" || return "$?"
    found=true
  done < <(find "$owner_dir" -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort)
  [ "$found" = true ] || return "$TRELLIS_EX_CONFLICT"
  cat "$common/info/exclude" > "$after" || return "$TRELLIS_EX_UNAVAILABLE"
  attach_exclude_state "$common" "$before" "$after" true true false "$block_file"
}

attach_exclude_publish() {
  local exclude_json="$1" path common before_hash before_exists expected_hash expected64 current_hash current_exists=false tmp dir base
  path="$(printf '%s\n' "$exclude_json" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$exclude_json" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  before_hash="$(printf '%s\n' "$exclude_json" | jq -r '.before_sha256')" || return "$TRELLIS_EX_STATE"
  before_exists="$(printf '%s\n' "$exclude_json" | jq -r '.before_exists')" || return "$TRELLIS_EX_STATE"
  expected_hash="$(printf '%s\n' "$exclude_json" | jq -r '.after_sha256')" || return "$TRELLIS_EX_STATE"
  expected64="$(printf '%s\n' "$exclude_json" | jq -r '.after_base64')" || return "$TRELLIS_EX_STATE"
  dir="$(dirname "$path")"; base="$(basename "$path")"
  [ "$dir" = "$common/info" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return "$TRELLIS_EX_STATE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return "$TRELLIS_EX_CONFLICT"
    current_exists=true
    current_hash="$(attach_sha_file "$path")" || return "$?"
  else
    current_hash="$(attach_sha_text '')" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  [ "$current_exists" = "$before_exists" ] && [ "$current_hash" = "$before_hash" ] || return "$TRELLIS_EX_CONFLICT"
  tmp="$(mktemp "$dir/.${base}.trellis-attach.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  attach_decode_base64 "$expected64" > "$tmp" || { rm -f "$tmp"; return "$TRELLIS_EX_STATE"; }
  [ "$(attach_sha_file "$tmp")" = "$expected_hash" ] || { rm -f "$tmp"; return "$TRELLIS_EX_STATE"; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
  chmod 600 "$path" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  attach_exclude_verify_state "$exclude_json"
}

attach_exclude_recover() (
  local exclude_json="$1" path current_hash before_hash expected_hash before64 before_exists current_exists=false tmp="" dir base block_file block_hash block64
  path="$(printf '%s\n' "$exclude_json" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  before_hash="$(printf '%s\n' "$exclude_json" | jq -r '.before_sha256')" || return "$TRELLIS_EX_STATE"
  expected_hash="$(printf '%s\n' "$exclude_json" | jq -r '.after_sha256')" || return "$TRELLIS_EX_STATE"
  before64="$(printf '%s\n' "$exclude_json" | jq -r '.before_base64')" || return "$TRELLIS_EX_STATE"
  before_exists="$(printf '%s\n' "$exclude_json" | jq -r '.before_exists')" || return "$TRELLIS_EX_STATE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return "$TRELLIS_EX_CONFLICT"
    current_exists=true
    current_hash="$(attach_sha_file "$path")" || return "$?"
  else
    current_hash="$(attach_sha_text '')" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  [ "$current_exists" = "$before_exists" ] && [ "$current_hash" = "$before_hash" ] && return 0
  [ "$current_hash" = "$expected_hash" ] || return "$TRELLIS_EX_CONFLICT"
  block_file="$(mktemp "${TMPDIR:-/tmp}/trellis.exclude.block.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  trap 'rm -f "$block_file" "$tmp"' EXIT
  block_hash="$(printf '%s\n' "$exclude_json" | jq -r '.managed_block_sha256')" || return "$TRELLIS_EX_STATE"
  block64="$(printf '%s\n' "$exclude_json" | jq -r '.managed_block_base64')" || return "$TRELLIS_EX_STATE"
  attach_decode_base64 "$block64" > "$block_file" || return "$TRELLIS_EX_STATE"
  [ "$(attach_sha_file "$block_file")" = "$block_hash" ] || return "$TRELLIS_EX_STATE"
  [ "$(attach_exclude_parse "$path" "$block_file")" = one ] || return "$TRELLIS_EX_CONFLICT"
  dir="$(dirname "$path")"; base="$(basename "$path")"
  if [ "$before_exists" = false ]; then
    rm "$path" || return "$TRELLIS_EX_UNAVAILABLE"
    return 0
  fi
  tmp="$(mktemp "$dir/.${base}.trellis-recover.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  attach_decode_base64 "$before64" > "$tmp" || return "$TRELLIS_EX_STATE"
  [ "$(attach_sha_file "$tmp")" = "$before_hash" ] || return "$TRELLIS_EX_STATE"
  chmod 600 "$tmp" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  mv -f "$tmp" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 600 "$path" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
)

attach_project_claude_present() {
  local root="$1"
  [ -f "$root/CLAUDE.md" ] && [ ! -L "$root/CLAUDE.md" ]
}

# Leaves the project already owns, which attach defers to instead of refusing
# or overwriting. Exactly three shapes qualify:
#
#   * a `render_if_absent` seed render whose destination already exists. The
#     payload template is a seed, and doctrine (`core-rules/primers.md`) makes
#     the live file project-authored — rendering over it would replace authored
#     content with an empty template.
#   * a destination that is ALREADY the exact symlink the plan would create,
#     link text byte-for-byte equal to the planned target. This mirrors
#     `mirror_destination_is_staged_link` (scripts/sync-to-template.sh): a
#     destination symlink is normally refused, but one whose text equals the
#     artifact we were about to write is our own goal state, not foreign
#     content. `readlink` and `-L` are lstat-only, so the link is never followed
#     and a hostile target buys nothing; mismatched text still falls through to
#     the refusal.
#   * a symlink destination holding a project-authored REGULAR FILE. A project
#     that writes its own `AGENTS.md` is exercising the same doctrine as the
#     seed render above — the project's own file wins — and refusing there made
#     the whole harness unattachable for such a project rather than merely
#     unmanaging one leaf. `_attachment_symlink_destination_authored` decides
#     it, and is deliberately narrow: an empty file or a byte-for-byte copy of
#     a canonical source is a dropping, not authored content, and stays a
#     refusal so the operator resolves it rather than freezing it.
#
# Anything else — a directory, a symlink with different text, an empty or
# template-identical file — is left in the plan so the destination preflight
# refuses it BY NAME.
attach_deferred_leaves() {
  local root="$1" payload="$2" surfaces="$3" record kind path target reason deferred='[]'
  local has_project_claude=false
  attach_project_claude_present "$root" && has_project_claude=true
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    kind="$(printf '%s\n' "$record" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
    path="$(printf '%s\n' "$record" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
    case "$kind" in
      render)
        [ -e "$root/$path" ] || [ -L "$root/$path" ] || continue
        deferred="$(jq -cn --argjson current "$deferred" --arg path "$path" \
          '$current + [{path:$path,kind:"file",target:null,reason:"project-authored-render"}]')" || return "$TRELLIS_EX_STATE"
        ;;
      symlink)
        [ -e "$root/$path" ] || [ -L "$root/$path" ] || continue
        if [ -L "$root/$path" ]; then
          reason="pre-existing-symlink"
        elif _attachment_symlink_destination_authored "$record" "$root" "$payload" "$path"; then
          reason="project-authored-file"
        else
          continue
        fi
        # Recorded even for the authored-file shape: it pins WHICH link the
        # project displaced, so diagnosis can hold the entry against the same
        # manifest leaf instead of matching on path alone.
        target="$(printf '%s\n' "$record" | jq -r --argjson has_project_claude "$has_project_claude" '
          if .source_scope == "project"
          then (if $has_project_claude then .target else .fallback_target end)
          else .target end')" || return "$TRELLIS_EX_STATE"
        if [ "$reason" = "pre-existing-symlink" ]; then
          _attachment_symlink_matches "$root/$path" "$target" || continue
        fi
        deferred="$(jq -cn --argjson current "$deferred" --arg path "$path" --arg target "$target" --arg reason "$reason" \
          '$current + [{path:$path,kind:"symlink",target:$target,reason:$reason}]')" || return "$TRELLIS_EX_STATE"
        ;;
    esac
  done < <(printf '%s\n' "$surfaces" | jq -c '
    .artifacts[]
    | select((.kind == "render" and (.render_if_absent // false)) or .kind == "symlink")')
  printf '%s\n' "$deferred" | jq -cS 'sort_by(.path)'
}

attach_surfaces_without_deferred() {
  local surfaces="$1" deferred="$2"
  printf '%s\n' "$surfaces" | jq -cS --argjson deferred "$deferred" '
    ($deferred | map(.path)) as $skip
    | .artifacts |= map(.destination as $d | select(($skip | index($d)) == null))'
}

# Every leaf collision must name its path. The transaction layer's own
# destinations-absent guard returns EX_CONFLICT with no output, which reaches an
# operator as a bare exit 3; this runs first so the refusal is always explained.
# `explicit-json` renders are exempt by design — that merge is defined over an
# existing project file and has its own key-overlap refusal.
attach_destination_preflight() {
  local root="$1" surfaces="$2" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
      attach_err "attachment destination is project-owned: $path"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done < <(printf '%s\n' "$surfaces" | jq -r '
    [".trellis/runtime"]
    + [.artifacts[] | select(.kind == "symlink" or (.kind == "render" and .merge == "replace")) | .destination]
    | unique | sort | .[]')
}

# A tracked `.gitignore` outranks `.git/info/exclude` (gitignore(5) precedence),
# so a negation such as `!.claude/primers/*` re-includes an artifact the managed
# block excludes and the attached checkout goes dirty — the managed exclude is
# written, correct, and simply powerless. `git check-ignore -v` reports the
# WINNING pattern per path, and the winner is the whole answer: if it is a
# negation, no managed exclude can beat it, and if nothing matches, the block we
# are about to stage decides. So this needs no simulation of the staged block.
# `--no-index` keeps the verdict a function of the ignore files alone — without
# it git stays silent about an already-tracked path and the check would pass by
# accident.
#
# Ordering: `attach_deferred_leaves` runs BEFORE this, so a deferred leaf is
# never examined here. That is correct, not a gap. `attach_exclude_block`
# derives the managed block from the SAME post-deferral `$surfaces`, so a
# deferred path gets no managed exclude line at all — and this check exists
# only to prove the block we are about to write will actually win. At a path we
# neither create nor exclude there is no exclude for a negation to defeat, and
# the path's Git status after attach is byte-for-byte the status it had before:
# whatever the leaf was — committed, or already untracked under the project's
# own negation — attach did not put it there and does not change it. Widening
# the check to the pre-deferral set would invert the outcome, refusing
# attachment over a project's own file. Pinned by "attach defers a
# project-owned INDEX.md that a tracked negation re-includes" in
# scripts/tests/attach-project.bats.
attach_exclude_effective_preflight() (
  local root="$1" surfaces="$2" input output rc source line pattern path destinations
  input="$(mktemp "${TMPDIR:-/tmp}/trellis.attach.ignore.in.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  output="$(mktemp "${TMPDIR:-/tmp}/trellis.attach.ignore.out.XXXXXX")" || { rm -f "$input"; return "$TRELLIS_EX_UNAVAILABLE"; }
  trap 'rm -f "$input" "$output"' EXIT
  # Capture jq on its own: piped straight into `tr` the exit status would be
  # `tr`'s, so a jq failure would land an EMPTY path list on check-ignore and
  # the whole check would pass vacuously.
  destinations="$(printf '%s\n' "$surfaces" | jq -r '
    [".trellis/runtime"] + [.artifacts[].destination] | unique | sort | .[]')" || return "$TRELLIS_EX_STATE"
  # Planner-validated destinations carry no newline, so `tr` is an exact NUL join.
  printf '%s\n' "$destinations" | tr '\n' '\0' > "$input" || return "$TRELLIS_EX_UNAVAILABLE"
  git -C "$root" check-ignore -v -z --no-index --stdin < "$input" > "$output"
  rc=$?
  case "$rc" in
    0|1) ;;
    *) attach_err 'could not evaluate Git ignore rules for the managed native surface'; return "$TRELLIS_EX_STATE" ;;
  esac
  while IFS= read -r -d '' source && IFS= read -r -d '' line &&
        IFS= read -r -d '' pattern && IFS= read -r -d '' path; do
    case "$pattern" in
      '!'*)
        attach_err "managed exclude cannot cover $path: $source:$line:$pattern re-includes it and outranks info/exclude"
        return "$TRELLIS_EX_CONFLICT"
        ;;
    esac
  done < "$output"
  return 0
)

attach_parent_artifacts() {
  local root="$1" leaves="$2" paths path destination parents='[]'
  paths="$(printf '%s\n' "$leaves" | jq -r '
    [ .[] | .path | split("/") | .[0:-1]
      | range(1; length + 1) as $depth
      | {depth:$depth,path:.[0:$depth] | join("/")} ]
    | unique_by(.path)
    | sort_by(.depth, .path)
    | .[].path
  ')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    destination="$root/$path"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      [ -d "$destination" ] && [ ! -L "$destination" ] || {
        attach_err "attachment parent directory is project-owned: $path"
        return "$TRELLIS_EX_CONFLICT"
      }
      continue
    fi
    parents="$(jq -cn --argjson parents "$parents" --arg path "$path" '$parents + [{path:$path,kind:"parent"}]')" || return "$TRELLIS_EX_STATE"
  done <<< "$paths"
  printf '%s\n' "$parents"
}

attach_mode_json() {
  local path="$1" raw
  raw="$(_attachment_mode "$path")" || return "$TRELLIS_EX_STATE"
  case "$raw" in [0-7][0-7][0-7]) printf '0%s\n' "$raw" ;; *) return "$TRELLIS_EX_STATE" ;; esac
}

attach_contextual_render_context() {
  local status
  attachment_contextual_render_context "$@"
  status=$?
  if [ "$status" -ne 0 ]; then
    attach_err 'could not derive the trusted local SessionStart render context'
  fi
  return "$status"
}

attach_contextual_render_required() {
  attachment_contextual_render_required "$@"
}

attach_contextual_template_render() {
  local status
  attachment_contextual_template_render "$@"
  status=$?
  if [ "$status" -ne 0 ]; then
    attach_err "contextual template is malformed or unsafe: ${2:-<unknown>}"
  fi
  return "$status"
}

attach_json_render_plan() (
  local root="$1" payload="$2" record="$3" context="${4:-}" template destination mode source template_file before_file after_file detail
  local before_exists=false before_hash before64 before_mode=null after_hash after64 owned created artifact render
  template="$(printf '%s\n' "$record" | jq -r '.template')" || return "$TRELLIS_EX_STATE"
  destination="$(printf '%s\n' "$record" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
  mode="$(printf '%s\n' "$record" | jq -r '.mode')" || return "$TRELLIS_EX_STATE"
  source="$payload/$template"
  _attachment_canonical_file "$source" || return "$TRELLIS_EX_STATE"
  jq -e 'type == "object"' "$source" >/dev/null 2>&1 || {
    attach_err "explicit-json template must be a JSON object: $template"
    return "$TRELLIS_EX_STATE"
  }
  template_file="$(mktemp "${TMPDIR:-/tmp}/trellis.render.template.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  before_file="$(mktemp "${TMPDIR:-/tmp}/trellis.render.before.XXXXXX")" || { rm -f "$template_file"; return "$TRELLIS_EX_UNAVAILABLE"; }
  after_file="$(mktemp "${TMPDIR:-/tmp}/trellis.render.after.XXXXXX")" || { rm -f "$template_file" "$before_file"; return "$TRELLIS_EX_UNAVAILABLE"; }
  trap 'rm -f "$template_file" "$before_file" "$after_file"' EXIT
  attach_contextual_template_render "$source" "$template" "$context" > "$template_file" || return "$?"
  jq -e 'type == "object"' "$template_file" >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  if [ -e "$root/$destination" ] || [ -L "$root/$destination" ]; then
    [ -f "$root/$destination" ] && [ ! -L "$root/$destination" ] || return "$TRELLIS_EX_CONFLICT"
    jq -e 'type == "object"' "$root/$destination" >/dev/null 2>&1 || {
      attach_err "explicit-json destination must be a JSON object: $destination"
      return "$TRELLIS_EX_CONFLICT"
    }
    cat "$root/$destination" > "$before_file" || return "$TRELLIS_EX_UNAVAILABLE"
    before_exists=true
    before_mode="$(attach_mode_json "$root/$destination")" || return "$?"
  else
    printf '{}\n' > "$before_file" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  before_hash="$(if [ "$before_exists" = true ]; then attach_sha_file "$before_file"; else attach_sha_text ''; fi)" || return "$?"
  before64="$(if [ "$before_exists" = true ]; then attach_base64_file "$before_file"; fi)" || return "$?"
  detail="$(jq -cn --slurpfile base "$before_file" --slurpfile template "$template_file" '
    def exists_at($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key] else .exists = false end) | .exists;
    def object_paths($value; $path):
      if ($value | type) == "object"
      then [$path] + [$value | to_entries[] | object_paths(.value; $path + [.key])[]]
      else [] end;
    def leaves($value; $path):
      if ($value | type) == "object"
      then if ($value | length) == 0 then [{path:$path,value:$value}]
           else [$value | to_entries[] | leaves(.value; $path + [.key])] | add end
      else [{path:$path,value:$value}] end;
    def merge_missing($left; $right):
      reduce ($right | keys_unsorted[]) as $key ($left;
        if has($key) then .[$key] = merge_missing(.[$key]; $right[$key])
        else .[$key] = $right[$key] end);
    $base[0] as $base | $template[0] as $template
    | if (($base | type) != "object") or (($template | type) != "object") then error("objects required")
      elif ([object_paths($template; [])[] | select(length > 0) as $path | select(exists_at($base; $path) and (($base | getpath($path)) | type) != "object")] | length) > 0
        then error("object type conflict")
      elif ([leaves($template; [])[] | select(exists_at($base; .path))] | length) > 0
        then error("project key overlap")
      else {after:merge_missing($base;$template),owned_keys:leaves($template; []),created_paths:[object_paths($template; [])[] | select(length > 0) as $path | select(exists_at($base; $path) | not)]}
      end
  ' 2>/dev/null)" || {
    attach_err "explicit-json template overlaps project-owned keys: $destination"
    return "$TRELLIS_EX_CONFLICT"
  }
  printf '%s\n' "$detail" | jq -S '.after' > "$after_file" || return "$TRELLIS_EX_STATE"
  after_hash="$(attach_sha_file "$after_file")" || return "$?"
  after64="$(attach_base64_file "$after_file")" || return "$?"
  owned="$(printf '%s\n' "$detail" | jq -cS '.owned_keys')" || return "$TRELLIS_EX_STATE"
  created="$(printf '%s\n' "$detail" | jq -cS '.created_paths')" || return "$TRELLIS_EX_STATE"
  artifact="$(jq -cn --arg path "$destination" --arg sha "$after_hash" --arg content "$after64" --arg mode "$mode" \
    --arg before_hash "$before_hash" --arg before64 "$before64" --argjson before_exists "$before_exists" --arg before_mode "$before_mode" '
      {path:$path,kind:"file",content_base64:$content,sha256:$sha,mode:$mode}
      + (if $before_exists then {replace:{before_base64:$before64,before_mode:$before_mode,before_sha256:$before_hash}} else {} end)')" || return "$TRELLIS_EX_STATE"
  render="$(jq -cn --arg path "$destination" --arg mode "$mode" --arg before_hash "$before_hash" --arg before64 "$before64" \
    --arg after_hash "$after_hash" --arg after64 "$after64" --argjson before_exists "$before_exists" --arg before_mode "$before_mode" \
    --argjson owned "$owned" --argjson created "$created" '
      {path:$path,merge:"explicit-json",mode:$mode,before_exists:$before_exists,before_sha256:$before_hash,before_base64:$before64,before_mode:(if $before_exists then $before_mode else null end),after_sha256:$after_hash,after_base64:$after64,after_mode:$mode,owned_keys:$owned,created_paths:$created}')" || return "$TRELLIS_EX_STATE"
  jq -cn --argjson artifact "$artifact" --argjson render "$render" '{artifact:$artifact,render:$render}'
)

attach_render_artifacts() {
  local root="$1" payload="$2" surfaces="$3" context="${4:-}" record merge template destination mode source hash result
  local artifacts='[]' renders='[]'
  while IFS= read -r record; do
    merge="$(printf '%s\n' "$record" | jq -r '.merge')" || return "$TRELLIS_EX_STATE"
    template="$(printf '%s\n' "$record" | jq -r '.template')" || return "$TRELLIS_EX_STATE"
    destination="$(printf '%s\n' "$record" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
    mode="$(printf '%s\n' "$record" | jq -r '.mode')" || return "$TRELLIS_EX_STATE"
    case "$merge" in
      replace)
        source="$payload/$template"
        _attachment_canonical_file "$source" || return "$TRELLIS_EX_STATE"
        [ ! -e "$root/$destination" ] && [ ! -L "$root/$destination" ] || {
          attach_err "render destination is project-owned: $destination"
          return "$TRELLIS_EX_CONFLICT"
        }
        hash="$(attach_sha_file "$source")" || return "$?"
        artifacts="$(jq -cn --argjson current "$artifacts" --arg path "$destination" --arg source "$source" --arg hash "$hash" --arg mode "$mode" \
          '$current + [{path:$path,kind:"file",source:$source,sha256:$hash,mode:$mode}]')" || return "$TRELLIS_EX_STATE"
        ;;
      explicit-json)
        result="$(attach_json_render_plan "$root" "$payload" "$record" "$context")" || return "$?"
        artifacts="$(printf '%s\n' "$result" | jq -c --argjson current "$artifacts" '$current + [.artifact]')" || return "$TRELLIS_EX_STATE"
        renders="$(printf '%s\n' "$result" | jq -c --argjson current "$renders" '$current + [.render]')" || return "$TRELLIS_EX_STATE"
        ;;
      *) return "$TRELLIS_EX_STATE" ;;
    esac
  done < <(printf '%s\n' "$surfaces" | jq -c '.artifacts[] | select(.kind == "render")')
  jq -cn --argjson artifacts "$artifacts" --argjson renders "$renders" '{artifacts:$artifacts,renders:$renders}'
}

attach_plan_from_surfaces() {
  local home="$1" root="$2" fleet="$3" project_id="$4" identity="$5" release="$6" attachment_id="$7" payload="$8" surfaces="$9" exclude="${10}" context="${11:-null}" pre_existing="${12:-[]}"
  local leaves parents artifacts has_project_claude render_data render_artifacts renders render_context
  if attach_project_claude_present "$root"; then
    has_project_claude=true
  else
    has_project_claude=false
  fi
  if attachment_contextual_render_required "$surfaces"; then
    [ "$context" != null ] || return "$TRELLIS_EX_STATE"
    attachment_contextual_render_context_validate "$context" "$home" || return "$TRELLIS_EX_STATE"
    render_context="$(printf '%s\n' "$context" | jq -cS .)" || return "$TRELLIS_EX_STATE"
  else
    [ "$context" = null ] || return "$TRELLIS_EX_STATE"
    render_context=null
  fi
  leaves="$(printf '%s\n' "$surfaces" | jq -c --arg payload "$payload" --argjson has_project_claude "$has_project_claude" '
    [{path:".trellis/runtime",kind:"symlink",target:$payload}]
    + [.artifacts[]
      | select(.kind == "symlink")
      | if .source_scope == "project" then
          {path:.destination,kind:"symlink",target:(if $has_project_claude then .target else .fallback_target end)}
        else {path:.destination,kind:"symlink",target:.target} end]
  ')" || return "$TRELLIS_EX_STATE"
  render_data="$(attach_render_artifacts "$root" "$payload" "$surfaces" "$context")" || return "$?"
  render_artifacts="$(printf '%s\n' "$render_data" | jq -c '.artifacts')" || return "$TRELLIS_EX_STATE"
  renders="$(printf '%s\n' "$render_data" | jq -c '.renders')" || return "$TRELLIS_EX_STATE"
  leaves="$(jq -cn --argjson leaves "$leaves" --argjson renders "$render_artifacts" '$leaves + $renders')" || return "$TRELLIS_EX_STATE"
  parents="$(attach_parent_artifacts "$root" "$leaves")" || return "$?"
  artifacts="$(jq -cn --argjson parents "$parents" --argjson leaves "$leaves" '$parents + $leaves')" || return "$TRELLIS_EX_STATE"
  jq -n -S \
    --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg checkout_id "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" \
    --arg worktree_id "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" \
    --arg attachment_id "$attachment_id" --arg root "$root" --arg release "$release" \
    --argjson artifacts "$artifacts" --argjson renders "$renders" --argjson render_context "$render_context" --argjson exclude "$exclude" \
    --argjson pre_existing "$pre_existing" \
    --argjson hooks "$(attach_hooks_plan "$home" "$identity" "$exclude")" \
    '{schema_version:1,status:"prepared",fleet:$fleet,project_id:$project_id,checkout_id:$checkout_id,worktree_id:$worktree_id,attachment_id:$attachment_id,project_root:$root,worktree_root:$root,release:$release,artifacts:$artifacts,pre_existing:$pre_existing,renders:$renders,render_context:$render_context,exclude_block_hash:$exclude.managed_block_sha256,exclude:$exclude,git_hooks:$hooks}'
}

attach_existing_owner() {
  local home="$1" identity="$2" owner
  owner="$(_attachment_ownership_path "$home" "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" "$(printf '%s\n' "$identity" | jq -r '.worktree_id')")"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return "$TRELLIS_EX_UNAVAILABLE"
  printf '%s\n' "$owner"
}

attach_harnesses_from_owner() {
  jq -c '
    [.artifacts[]
      | if .path == "AGENTS.md" or (.path | startswith(".agents/")) or (.path | startswith(".codex/")) then "codex"
        elif .path | startswith(".claude/") then "claude"
        elif .path | startswith(".omp/") then "omp"
        else empty end] | unique | sort
  ' "$1"
}

attach_normalize_harnesses() (
  _SURFACE_PLAN_HARNESSES=()
  surface_plan_normalize_harnesses "$@" || return "$?"
  jq -cn --args '$ARGS.positional' "${_SURFACE_PLAN_HARNESSES[@]+"${_SURFACE_PLAN_HARNESSES[@]}"}" || return "$TRELLIS_EX_STATE"
)
# These flags are intentionally undocumented: doctor and the attachment seeder
# use them to bind a repair to the exact registry rows they just diagnosed. A
# partial binding is unsafe because it could turn a later registry change into
# a mutation of a different checkout.
attach_expected_binding_build() {
  local fleet="$1" project_id="$2" root="$3" checkout_id="$4" worktree_id="$5"
  local attachment_id="$6" release="$7" harnesses="$8" normalized
  trellis_home_require_fleet_name "$fleet" || return "$?"
  local_registry_require_project_id "$project_id" || return "$?"
  local_registry_require_absolute_safe_path 'expected worktree root' "$root" || return "$?"
  local_registry_require_attachment_id "$attachment_id" || return "$?"
  release="$(local_registry_normalize_release "$release")" || return "$?"
  if [ -z "$release" ]; then
    attach_usage_error '--expected-release requires VERSION'
    return "$TRELLIS_EX_USAGE"
  fi
  if ! jq -en --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
    ($checkout | test("^[a-f0-9]{64}$"))
    and ($worktree | test("^[a-f0-9]{64}$"))
  ' >/dev/null 2>&1; then
    attach_usage_error 'expected checkout and worktree IDs must be lowercase SHA-256 values'
    return "$TRELLIS_EX_USAGE"
  fi
  normalized="$(local_registry_normalize_harnesses "$harnesses")" || return "$?"
  if [ "$normalized" = '[]' ]; then
    attach_usage_error '--expected-harnesses-json must name at least one native harness'
    return "$TRELLIS_EX_USAGE"
  fi
  jq -cnS \
    --arg fleet "$fleet" --arg project_id "$project_id" --arg root "$root" \
    --arg checkout_id "$checkout_id" --arg worktree_id "$worktree_id" \
    --arg attachment_id "$attachment_id" --arg release "$release" \
    --argjson harnesses "$normalized" \
    '{fleet:$fleet,project_id:$project_id,root:$root,checkout_id:$checkout_id,
      worktree_id:$worktree_id,attachment_id:$attachment_id,release:$release,
      harnesses:$harnesses}'
}

attach_expected_donor_binding_build() {
  local fleet="$1" project_id="$2" root="$3" checkout_id="$4" worktree_id="$5"
  local attachment_id="$6" release="$7" harnesses="$8" donor
  [ -n "$attachment_id" ] || {
    attach_usage_error '--expected-donor-attachment-id requires a UUID'
    return "$TRELLIS_EX_USAGE"
  }
  donor="$(attach_expected_binding_build "$fleet" "$project_id" "$root" "$checkout_id" \
    "$worktree_id" "$attachment_id" "$release" "$harnesses")" || return "$?"
  printf '%s\n' "$donor"
}

attach_expected_binding_verify() {
  local home="$1" root="$2" identity="$3" expected="$4" donor="${5:-}"
  local donor_json=null state actual expected_actual rc
  [ -n "$expected" ] || {
    [ -z "$donor" ] || {
      attach_err 'expected donor binding requires an expected target binding'
      return "$TRELLIS_EX_STATE"
    }
    return 0
  }
  [ -z "$donor" ] || donor_json="$donor"
  if ! printf '%s\n' "$identity" | jq -e --argjson expected "$expected" '
    .root == $expected.root
    and .checkout_id == $expected.checkout_id
    and .worktree_id == $expected.worktree_id
  ' >/dev/null 2>&1; then
    attach_err 'expected repair binding no longer matches the current Git worktree identity'
    return "$TRELLIS_EX_CONFLICT"
  fi
  # Per-row continuation reaches the apply path here. The whole-file strict
  # reader would abort on the first broken row anywhere in the registry, so one
  # unrelated identity_error row used to fail every healthy sibling's relink.
  # Read diagnostically instead, then apply the SAME strict validation to the
  # rows this call is about to bind: the target checkout and worktree (and the
  # donor pair when repairing from one). Those rows keep failing class 4/5
  # exactly as `local_registry_validate_available_identities` would have made
  # them; no other row's state is consulted. Both call sites in relink run under
  # the held checkout lock, so the lock-time re-check is as strict as before.
  state="$(local_registry_read_diagnostic_state "$home")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    attach_err 'could not re-read local registry state for the expected repair binding'
    return "$rc"
  fi
  local_registry_validate_bound_row_identity "$state" \
    "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" \
    "$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    attach_err 'expected repair binding target row failed strict local registry identity validation'
    return "$rc"
  fi
  if [ "$donor_json" != null ]; then
    local_registry_validate_bound_row_identity "$state" \
      "$(printf '%s\n' "$donor_json" | jq -r '.checkout_id')" \
      "$(printf '%s\n' "$donor_json" | jq -r '.worktree_id')"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      attach_err 'expected donor repair binding row failed strict local registry identity validation'
      return "$rc"
    fi
  fi
  if [ "$donor_json" = null ]; then
    expected_actual="$expected"
  else
    expected_actual="$(jq -cnS --argjson target "$expected" --argjson donor "$donor_json" \
      '{target:$target,donor:$donor}')" || return "$TRELLIS_EX_STATE"
  fi
  actual="$(printf '%s\n' "$state" | jq -cS \
    --arg checkout "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" \
    --arg worktree "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" \
    --arg root "$root" --argjson donor "$donor_json" '
      [.projects | to_entries[] as $project
       | $project.value as $record
       | select($record.status == "active")
       | select(($record.metadata.legacy.blacklisted // false) == false)
       | select((($record.unavailable_roots // []) | index($root)) == null)
       | ($record.checkouts[$checkout] // null) as $checkout_record
       | select($checkout_record != null)
       | ($checkout_record.worktrees[$worktree] // null) as $worktree_record
       | (if $donor == null then
            select($worktree_record != null and $worktree_record.root == $root)
            | {fleet:$record.fleet,project_id:$record.project_id,root:$worktree_record.root,
               checkout_id:$checkout,worktree_id:$worktree,
               attachment_id:($worktree_record.attachment_id // ""),
               release:$checkout_record.release,
               harnesses:($checkout_record.harnesses | unique | sort)}
          else
            select($worktree_record == null
                   or ($worktree_record.root == $root
                       and ($worktree_record.attachment_id // "") == ""))
            | {fleet:$record.fleet,project_id:$record.project_id,root:$root,
               checkout_id:$checkout,worktree_id:$worktree,attachment_id:"",
               release:$checkout_record.release,
               harnesses:($checkout_record.harnesses | unique | sort)}
          end) as $target
       | if $donor == null then
           $target
         else
           ($donor.root) as $donor_root
           | ($donor.checkout_id) as $donor_checkout
           | ($donor.worktree_id) as $donor_worktree
           | ($record.checkouts[$donor_checkout] // null) as $donor_checkout_record
           | select($donor_checkout_record != null)
           | ($donor_checkout_record.worktrees[$donor_worktree] // null) as $donor_worktree_record
           | select($donor_worktree_record != null and $donor_worktree_record.root == $donor_root)
           | select((($record.unavailable_roots // []) | index($donor_root)) == null)
           | {target:$target,
              donor:{fleet:$record.fleet,project_id:$record.project_id,root:$donor_worktree_record.root,
                     checkout_id:$donor_checkout,worktree_id:$donor_worktree,
                     attachment_id:($donor_worktree_record.attachment_id // ""),
                     release:$donor_checkout_record.release,
                     harnesses:($donor_checkout_record.harnesses | unique | sort)}}
         end]
      | if length == 1 then .[0] else null end
    ' 2>/dev/null)" || {
      attach_err 'could not normalize the current registry row for the expected repair binding'
      return "$TRELLIS_EX_STATE"
    }
  if [ "$actual" != "$expected_actual" ]; then
    if [ "$donor_json" = null ]; then
      attach_err 'expected repair binding no longer exactly matches the active local registry row'
    else
      attach_err 'expected repair target or donor binding no longer exactly matches active local registry rows'
    fi
    return "$TRELLIS_EX_CONFLICT"
  fi
}
attach_expected_donor_verify_artifacts() {
  local home="$1" donor="$2" donor_root donor_identity owner release payload rc
  [ -n "$donor" ] || return 0
  donor_root="$(printf '%s\n' "$donor" | jq -r '.root')" || return "$TRELLIS_EX_STATE"
  donor_identity="$(local_registry_identity_for_root "$donor_root")" || {
    attach_err 'expected donor worktree identity is no longer available'
    return "$TRELLIS_EX_CONFLICT"
  }
  if ! printf '%s\n' "$donor_identity" | jq -e --argjson donor "$donor" '
    .root == $donor.root
    and .checkout_id == $donor.checkout_id
    and .worktree_id == $donor.worktree_id
  ' >/dev/null 2>&1; then
    attach_err 'expected donor worktree identity no longer matches its repair binding'
    return "$TRELLIS_EX_CONFLICT"
  fi
  owner="$(_attachment_ownership_path "$home" \
    "$(printf '%s\n' "$donor" | jq -r '.checkout_id')" \
    "$(printf '%s\n' "$donor" | jq -r '.worktree_id')")"
  [ -f "$owner" ] && [ ! -L "$owner" ] || {
    attach_err 'expected donor attachment owner is no longer available'
    return "$TRELLIS_EX_CONFLICT"
  }
  attachment_verify "$home" "$owner" >/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    attach_err 'expected donor attachment artifacts are no longer exact'
    return "$TRELLIS_EX_CONFLICT"
  fi
  attach_expected_binding_owner_matches "$owner" "$donor" || return "$?"
  release="$(printf '%s\n' "$donor" | jq -r '.release')" || return "$TRELLIS_EX_STATE"
  payload="$(TRELLIS_HOME="$home" release_store_locate "$release")" || return "$?"
  payload="$payload/payload"
  if ! jq -e --argjson donor "$donor" --arg payload "$payload" '
    .status == "committed"
    and .fleet == $donor.fleet
    and .project_id == $donor.project_id
    and .checkout_id == $donor.checkout_id
    and .worktree_id == $donor.worktree_id
    and .attachment_id == $donor.attachment_id
    and .project_root == $donor.root
    and .worktree_root == $donor.root
    and .release == $donor.release
    and ([.artifacts[]
          | select(.path == ".trellis/runtime"
                   and .kind == "symlink"
                   and .target == $payload)] | length) == 1
  ' "$owner" >/dev/null 2>&1; then
    attach_err 'expected donor owner no longer matches its runtime release binding'
    return "$TRELLIS_EX_CONFLICT"
  fi
}

attach_expected_binding_test_barrier() {
  local barrier="${ATTACHMENT_TEST_EXPECTED_BINDING_BARRIER_DIR:-}"
  [ -n "$barrier" ] || return 0
  [ -d "$barrier" ] && [ ! -L "$barrier" ] || {
    attach_err 'expected binding test barrier directory is unavailable or unsafe'
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  : > "$barrier/entered" || return "$TRELLIS_EX_UNAVAILABLE"
  while [ ! -e "$barrier/release" ]; do
    sleep 0.01
  done
}

attach_expected_binding_matches_selection() {
  local expected="$1" fleet="$2" project_id="$3" root="$4" identity="$5"
  local attachment_id="$6" release="$7" harnesses="$8" allow_new_attachment="${9:-false}" normalized actual expected_comparison
  [ -n "$expected" ] || return 0
  normalized="$(local_registry_normalize_harnesses "$harnesses")" || {
    attach_err 'repair selected an invalid native harness set'
    return "$TRELLIS_EX_STATE"
  }
  actual="$(jq -cnS \
    --arg fleet "$fleet" --arg project_id "$project_id" --arg root "$root" \
    --arg checkout_id "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" \
    --arg worktree_id "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" \
    --arg attachment_id "$attachment_id" --arg release "$release" \
    --argjson harnesses "$normalized" \
    '{fleet:$fleet,project_id:$project_id,root:$root,checkout_id:$checkout_id,
      worktree_id:$worktree_id,attachment_id:$attachment_id,release:$release,
      harnesses:$harnesses}')" || return "$TRELLIS_EX_STATE"
  expected_comparison="$expected"
  if [ "$allow_new_attachment" = true ]; then
    local_registry_require_attachment_id "$attachment_id" || return "$?"
    [ -n "$attachment_id" ] || {
      attach_err 'repair did not allocate an attachment ID for a previously inert registry row'
      return "$TRELLIS_EX_STATE"
    }
    actual="$(printf '%s\n' "$actual" | jq -cS '.attachment_id = ""')" || return "$TRELLIS_EX_STATE"
  fi
  if [ "$actual" != "$expected_comparison" ]; then
    attach_err 'repair parameters do not exactly match the expected local registry binding'
    return "$TRELLIS_EX_CONFLICT"
  fi
}

attach_expected_binding_owner_matches() {
  local owner="$1" expected="$2" actual
  [ -n "$expected" ] || return 0
  actual="$(jq -cS '
    def harness($path):
      if $path == "AGENTS.md" or ($path | startswith(".agents/")) or ($path | startswith(".codex/")) then "codex"
      elif ($path | startswith(".claude/")) then "claude"
      elif ($path | startswith(".omp/")) then "omp"
      else empty end;
    {fleet,project_id,root:.worktree_root,checkout_id,worktree_id,attachment_id,release,
     harnesses:([.artifacts[] | harness(.path)] | unique | sort)}
  ' "$owner" 2>/dev/null)" || {
    attach_err 'could not normalize the committed owner for the expected repair binding'
    return "$TRELLIS_EX_STATE"
  }
  if [ "$actual" != "$expected" ]; then
    attach_err 'committed owner no longer exactly matches the expected local registry binding'
    return "$TRELLIS_EX_CONFLICT"
  fi
}

attach_expected_binding_journal_matches() {
  local journal="$1" expected="$2" actual
  [ -n "$expected" ] || return 0
  actual="$(jq -cS '
    def harness($path):
      if $path == "AGENTS.md" or ($path | startswith(".agents/")) or ($path | startswith(".codex/")) then "codex"
      elif ($path | startswith(".claude/")) then "claude"
      elif ($path | startswith(".omp/")) then "omp"
      else empty end;
    if .status == "prepared" then .
    elif .status == "detaching" then .original_owner
    else error("unsupported journal status") end
    | {fleet,project_id,root:.worktree_root,checkout_id,worktree_id,attachment_id,release,
       harnesses:([.artifacts[] | harness(.path)] | unique | sort)}
  ' "$journal" 2>/dev/null)" || {
    attach_err 'could not normalize the attachment journal for the expected repair binding'
    return "$TRELLIS_EX_STATE"
  }
  if [ "$actual" != "$expected" ]; then
    attach_err 'attachment journal no longer exactly matches the expected local registry binding'
    return "$TRELLIS_EX_CONFLICT"
  fi
}

attach_register() {
  local home="$1" fleet="$2" project_id="$3" root="$4" release="$5" harnesses="$6" attachment_id="$7"
  local_registry_register_worktree "$home" "$fleet" "$project_id" "$root" "$release" "$harnesses" "$attachment_id" '{}'
}

attach_detach_owner_plan() {
  local owner="$1" selected="$2"
  printf '%s\n' "$owner" | jq -cS --argjson selected "$selected" '
    def harness($path):
      if $path == "AGENTS.md" or ($path | startswith(".agents/")) or ($path | startswith(".codex/")) then "codex"
      elif ($path | startswith(".claude/")) then "claude"
      elif ($path | startswith(".omp/")) then "omp"
      else null end;
    . as $owner
    | ([(.artifacts + (.pre_existing // []))[] | harness(.path) | select(. != null)] | unique | sort) as $current
    | ($current - $selected) as $remaining
    | ([.renders[]?
        | select(harness(.path) as $h | $h != null and ($remaining | index($h)) != null)]) as $keep_renders
    | ([.renders[]?
        | select(harness(.path) as $h | $h != null and ($selected | index($h)) != null)]) as $removed_renders
    | (any($keep_renders[]; .path == ".claude/settings.local.json" or .path == ".codex/hooks.json")) as $keep_contextual
    | ($removed_renders | map(.path)) as $render_paths
    | ([.artifacts[]
        | select(.kind != "parent")
        | select(
            (.path == ".trellis/runtime" and ($remaining | length) > 0)
            or (harness(.path) as $h | $h != null and ($remaining | index($h)) != null)
          )]) as $keep_leaves
    | ([.artifacts[] as $artifact
        | select(
            if $artifact.kind == "parent"
            then any($keep_leaves[]; .path == $artifact.path or (.path | startswith($artifact.path + "/")))
            else any($keep_leaves[]; .path == $artifact.path)
            end)
        | $artifact]) as $keep_artifacts
    | ([.artifacts[] as $artifact
        | select(any($keep_artifacts[]; .path == $artifact.path) | not)
        | select($artifact.kind != "parent" and $artifact.kind != "directory")
        | select(($render_paths | index($artifact.path)) == null)
        | $artifact] | reverse) as $remove
    | {remaining_harnesses:$remaining,remove:$remove,removed_renders:$removed_renders,
       next_owner:(if ($remaining | length) == 0 then null
                   else $owner | .artifacts = $keep_artifacts | .renders = $keep_renders
                        | if has("pre_existing")
                          then .pre_existing = [.pre_existing[]
                            | select(harness(.path) as $h | $h != null and ($remaining | index($h)) != null)]
                          else . end
                        | if $keep_contextual then . else .render_context = null end
                   end)}
  '
}

attach_detach_owner_path() {
  local home="$1" checkout="$2" worktree="$3"
  _attachment_ownership_path "$home" "$checkout" "$worktree"
}

attach_detach_owner_files() {
  local home="$1" checkout="$2" owner_dir
  owner_dir="$home/state/attachments/$checkout"
  [ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] || return "$TRELLIS_EX_UNAVAILABLE"
  find "$owner_dir" -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort
}

attach_detach_pending_journals() {
  local home="$1" identity="$2" root="$3" all="$4" dir checkout worktree candidate rc
  dir="$home/state/attachment-journals"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r candidate; do
    jq -e --arg checkout "$checkout" --arg worktree "$worktree" --arg root "$root" --argjson all "$all" '
      .status == "detaching"
      and .original_owner.checkout_id == $checkout
      and ($all or (.original_owner.worktree_id == $worktree and .original_owner.worktree_root == $root))
    ' "$candidate" >/dev/null 2>&1 || continue
    _attachment_detach_journal_valid "$candidate"
    rc=$?
    [ "$rc" -eq 0 ] || {
      [ "$rc" -eq 3 ] && return "$TRELLIS_EX_CONFLICT"
      return "$TRELLIS_EX_STATE"
    }
    printf '%s\n' "$candidate"
  done < <(find "$dir" -maxdepth 1 -type f -name 'detach-*.json' -print | LC_ALL=C sort)
}

attach_detach_registry_preflight() {
  local home="$1" owner="$2" registry key fleet project checkout worktree attachment
  registry="$(local_registry_path "$home")" || return "$?"
  [ -e "$registry" ] || [ -L "$registry" ] || return 0
  local_registry_validate_file "$registry" || return "$?"
  fleet="$(printf '%s\n' "$owner" | jq -r '.fleet')" || return "$TRELLIS_EX_STATE"
  project="$(printf '%s\n' "$owner" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$owner" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  worktree="$(printf '%s\n' "$owner" | jq -r '.worktree_id')" || return "$TRELLIS_EX_STATE"
  attachment="$(printf '%s\n' "$owner" | jq -r '.attachment_id')" || return "$TRELLIS_EX_STATE"
  key="$(local_registry_project_key "$fleet" "$project")" || return "$?"
  jq -e --arg key "$key" --arg checkout "$checkout" --arg worktree "$worktree" --arg attachment "$attachment" '
    (.projects[$key].checkouts[$checkout].worktrees[$worktree].attachment_id // null) as $actual
    | ($actual == null or $actual == $attachment)
  ' "$registry" >/dev/null 2>&1 || return "$TRELLIS_EX_CONFLICT"
}

attach_detach_restore_registry() {
  local home="$1" owner="$2"
  local_registry_clear_attachment "$home" "$(printf '%s\n' "$owner" | jq -r '.fleet')" "$(printf '%s\n' "$owner" | jq -r '.project_id')" \
    "$(printf '%s\n' "$owner" | jq -r '.checkout_id')" "$(printf '%s\n' "$owner" | jq -r '.worktree_id')" "$(printf '%s\n' "$owner" | jq -r '.attachment_id')"
}

attach_detach_json_keys_match() {
  local file="$1" keys="$2"
  jq -e --argjson keys "$keys" '
    def exists_at($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key] else .exists = false end) | .exists;
    . as $current
    | ($current | type) == "object"
    and all($keys[]; . as $owned | exists_at($current; $owned.path) and (($current | getpath($owned.path)) == $owned.value))
  ' "$file" >/dev/null 2>&1
}

attach_detach_render_state() {
  local root="$1" render="$2" path current_hash after_hash before_hash after_mode before_mode before_exists keys
  path="$(printf '%s\n' "$render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  before_exists="$(printf '%s\n' "$render" | jq -r '.before_exists')" || return "$TRELLIS_EX_STATE"
  after_hash="$(printf '%s\n' "$render" | jq -r '.after_sha256')" || return "$TRELLIS_EX_STATE"
  before_hash="$(printf '%s\n' "$render" | jq -r '.before_sha256')" || return "$TRELLIS_EX_STATE"
  after_mode="$(printf '%s\n' "$render" | jq -r '.after_mode')" || return "$TRELLIS_EX_STATE"
  before_mode="$(printf '%s\n' "$render" | jq -r '.before_mode // empty')" || return "$TRELLIS_EX_STATE"
  if [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ]; then
    [ "$before_exists" = false ] && { printf 'before\n'; return 0; }
    return "$TRELLIS_EX_CONFLICT"
  fi
  [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || return "$TRELLIS_EX_CONFLICT"
  current_hash="$(attach_sha_file "$root/$path")" || return "$?"
  if [ "$current_hash" = "$after_hash" ] && _attachment_mode_matches "$root/$path" "$after_mode"; then
    printf 'after\n'
    return 0
  fi
  if [ "$before_exists" = true ] && [ "$current_hash" = "$before_hash" ] && _attachment_mode_matches "$root/$path" "$before_mode"; then
    printf 'before\n'
    return 0
  fi
  keys="$(printf '%s\n' "$render" | jq -c '.owned_keys')" || return "$TRELLIS_EX_STATE"
  _attachment_mode_matches "$root/$path" "$after_mode" && attach_detach_json_keys_match "$root/$path" "$keys" || return "$TRELLIS_EX_CONFLICT"
  printf 'merged\n'
}

attach_detach_render_preflight() {
  local owner="$1" renders="$2" root render state
  root="$(printf '%s\n' "$owner" | jq -r '.worktree_root')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r render; do
    state="$(attach_detach_render_state "$root" "$render")" || return "$?"
    case "$state" in after|merged) ;; *) return "$TRELLIS_EX_CONFLICT" ;; esac
  done < <(printf '%s\n' "$renders" | jq -c '.[]')
}

attach_detach_render_snapshot() {
  local path="$1" identity hash mode
  [ -f "$path" ] && [ ! -L "$path" ] || return "$TRELLIS_EX_CONFLICT"
  identity="$(_attachment_fs_identity "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
  hash="$(attach_sha_file "$path")" || return "$?"
  mode="$(_attachment_mode "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
  jq -cn --arg identity "$identity" --arg sha "$hash" --arg mode "0$mode" \
    '{identity:$identity,sha256:$sha,mode:$mode}'
}

attach_detach_render_source_matches() {
  local path="$1" identity="$2" expected="$3" mode="$4"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  _attachment_identity_matches "$path" "$identity" file || return 1
  [ "$(attach_sha_file "$path")" = "$expected" ] && _attachment_mode_matches "$path" "$mode"
}

attach_detach_render_pending_result_matches() {
  local path="$1" pending="$2" exists identity expected mode
  exists="$(printf '%s\n' "$pending" | jq -r '.result_exists')" || return 1
  if [ "$exists" = false ]; then
    [ ! -e "$path" ] && [ ! -L "$path" ]
    return $?
  fi
  identity="$(printf '%s\n' "$pending" | jq -r '.staging_identity // empty')" || return 1
  expected="$(printf '%s\n' "$pending" | jq -r '.result_sha256')" || return 1
  mode="$(printf '%s\n' "$pending" | jq -r '.result_mode')" || return 1
  _attachment_identity_matches "$path" "$identity" file || return 1
  [ "$(attach_sha_file "$path")" = "$expected" ] && _attachment_mode_matches "$path" "$mode"
}

attach_detach_render_before_result() {
  local render="$1" before_exists before_base64 before_sha before_mode
  before_exists="$(printf '%s\n' "$render" | jq -r '.before_exists')" || return "$TRELLIS_EX_STATE"
  if [ "$before_exists" = false ]; then
    jq -cn --arg sha "$(attach_sha_text '')" \
      '{result_exists:false,result_base64:"",result_sha256:$sha,result_mode:null}'
    return $?
  fi
  before_base64="$(printf '%s\n' "$render" | jq -r '.before_base64')" || return "$TRELLIS_EX_STATE"
  before_sha="$(printf '%s\n' "$render" | jq -r '.before_sha256')" || return "$TRELLIS_EX_STATE"
  before_mode="$(printf '%s\n' "$render" | jq -r '.before_mode')" || return "$TRELLIS_EX_STATE"
  jq -cn --arg bytes "$before_base64" --arg sha "$before_sha" --arg mode "$before_mode" \
    '{result_exists:true,result_base64:$bytes,result_sha256:$sha,result_mode:$mode}'
}

attach_detach_inverse_render_json() (
  local root="$1" render="$2" path keys created before_exists before_mode after_mode parent base tmp current_hash
  local result_mode result_hash result_base64
  path="$(printf '%s\n' "$render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  keys="$(printf '%s\n' "$render" | jq -c '.owned_keys')" || return "$TRELLIS_EX_STATE"
  created="$(printf '%s\n' "$render" | jq -c '.created_paths')" || return "$TRELLIS_EX_STATE"
  before_exists="$(printf '%s\n' "$render" | jq -r '.before_exists')" || return "$TRELLIS_EX_STATE"
  before_mode="$(printf '%s\n' "$render" | jq -r '.before_mode // empty')" || return "$TRELLIS_EX_STATE"
  after_mode="$(printf '%s\n' "$render" | jq -r '.after_mode')" || return "$TRELLIS_EX_STATE"
  attach_detach_json_keys_match "$root/$path" "$keys" || return "$TRELLIS_EX_CONFLICT"
  _attachment_parent_safe "$root" "$path" || return "$TRELLIS_EX_CONFLICT"
  parent="$(dirname "$root/$path")"; base="$(basename "$path")"
  _attachment_canonical_dir "$parent" || return "$TRELLIS_EX_CONFLICT"
  current_hash="$(attach_sha_file "$root/$path")" || return "$?"
  tmp="$(mktemp "$parent/.${base}.trellis-detach-result.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  trap 'rm -f "$tmp"' EXIT
  jq -S --argjson keys "$keys" --argjson created "$created" '
    def exists_at($value; $path):
      reduce $path[] as $key ({value:$value,exists:true};
        if .exists and (.value | type) == "object" and (.value | has($key))
        then .value = .value[$key] else .exists = false end) | .exists;
    reduce $keys[] as $owned (. ; delpaths([$owned.path]))
    | reduce ($created | sort_by(length) | reverse[]) as $path
        (. ; if exists_at(.; $path) and ((getpath($path) | type) == "object") and ((getpath($path) | length) == 0)
             then delpaths([$path]) else . end)
  ' "$root/$path" > "$tmp" || return "$TRELLIS_EX_CONFLICT"
  [ "$(attach_sha_file "$root/$path")" = "$current_hash" ] || return "$TRELLIS_EX_CONFLICT"
  if [ "$before_exists" = false ] && [ "$(jq -r 'type == "object" and length == 0' "$tmp")" = true ]; then
    jq -cn --arg sha "$(attach_sha_text '')" \
      '{result_exists:false,result_base64:"",result_sha256:$sha,result_mode:null}'
    return $?
  fi
  if [ "$before_exists" = true ]; then result_mode="$before_mode"; else result_mode="$after_mode"; fi
  chmod "${result_mode#0}" "$tmp" || return "$TRELLIS_EX_UNAVAILABLE"
  result_hash="$(attach_sha_file "$tmp")" || return "$?"
  result_base64="$(attach_base64_file "$tmp")" || return "$?"
  jq -cn --arg bytes "$result_base64" --arg sha "$result_hash" --arg mode "$result_mode" \
    '{result_exists:true,result_base64:$bytes,result_sha256:$sha,result_mode:$mode}'
)

attach_detach_render_begin() {
  local owner="$1" journal="$2" root render state path before after result stage
  root="$(printf '%s\n' "$owner" | jq -r '.worktree_root')" || return "$TRELLIS_EX_STATE"
  render="$(jq -c '.external as $external | $external.renders[$external.render_phase]' "$journal")" || return "$TRELLIS_EX_STATE"
  [ "$render" != null ] || return "$TRELLIS_EX_CONFLICT"
  path="$(printf '%s\n' "$render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  state="$(attach_detach_render_state "$root" "$render")" || return "$?"
  case "$state" in
    after)
      before="$(attach_detach_render_snapshot "$root/$path")" || return "$?"
      result="$(attach_detach_render_before_result "$render")" || return "$?"
      after="$(attach_detach_render_snapshot "$root/$path")" || return "$?"
      ;;
    merged)
      before="$(attach_detach_render_snapshot "$root/$path")" || return "$?"
      result="$(attach_detach_inverse_render_json "$root" "$render")" || return "$?"
      after="$(attach_detach_render_snapshot "$root/$path")" || return "$?"
      ;;
    *) return "$TRELLIS_EX_CONFLICT" ;;
  esac
  [ "$before" = "$after" ] || return "$TRELLIS_EX_CONFLICT"
  if [ "$(printf '%s\n' "$result" | jq -r '.result_exists')" = true ]; then
    stage="$(_attachment_stage_candidate "$root" "$path" "$(jq -r '.attachment_id' "$journal")")" || return "$TRELLIS_EX_UNAVAILABLE"
    stage="$(jq -cn --arg path "$stage" '$path')" || return "$TRELLIS_EX_STATE"
  else
    stage=null
  fi
  attachment_detach_render_begin "$journal" "$render" \
    "$(printf '%s\n' "$before" | jq -r '.identity')" "$(printf '%s\n' "$before" | jq -r '.sha256')" "$(printf '%s\n' "$before" | jq -r '.mode')" \
    "$(printf '%s\n' "$result" | jq -r '.result_exists')" "$(printf '%s\n' "$result" | jq -r '.result_base64')" "$(printf '%s\n' "$result" | jq -r '.result_sha256')" \
    "$(printf '%s\n' "$result" | jq -c '.result_mode')" "$stage"
}

attach_detach_render_pending_state() {
  local owner="$1" journal="$2" pending="$3" root render path artifact removal removal_path
  root="$(printf '%s\n' "$owner" | jq -r '.worktree_root')" || return "$TRELLIS_EX_STATE"
  render="$(printf '%s\n' "$pending" | jq -c '.render')" || return "$TRELLIS_EX_STATE"
  path="$root/$(printf '%s\n' "$render" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
  artifact="$(_attachment_detach_render_artifact "$render" "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" "$(printf '%s\n' "$pending" | jq -r '.source_mode')")" || return "$TRELLIS_EX_STATE"
  _attachment_claim_namespace_valid "$journal" "$path" || return "$TRELLIS_EX_CONFLICT"
  removal="$(jq -c '.removal' "$journal")" || return "$TRELLIS_EX_STATE"
  if [ "$removal" != null ]; then
    removal_path="$(printf '%s\n' "$removal" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
    if [ "$removal_path" = "$path" ]; then
      _attachment_journal_claim_layout "$journal" "$path" || return "$TRELLIS_EX_CONFLICT"
      if [ "$_ATTACHMENT_CLAIM_STATE" = claimed ]; then
        _attachment_identity_matches "$_ATTACHMENT_CLAIM_PATH" "$(printf '%s\n' "$pending" | jq -r '.source_identity')" file || return "$TRELLIS_EX_CONFLICT"
        _attachment_path_exact "$_ATTACHMENT_CLAIM_PATH" "$artifact" || return "$TRELLIS_EX_CONFLICT"
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
          printf 'claimed\n'
          return 0
        fi
      fi
    fi
  fi
  if attach_detach_render_source_matches "$path" "$(printf '%s\n' "$pending" | jq -r '.source_identity')" \
    "$(printf '%s\n' "$pending" | jq -r '.source_sha256')" "$(printf '%s\n' "$pending" | jq -r '.source_mode')"; then
    printf 'source\n'
    return 0
  fi
  if attach_detach_render_pending_result_matches "$path" "$pending"; then
    printf 'published\n'
    return 0
  fi
  return "$TRELLIS_EX_CONFLICT"
}

attach_detach_render_resume() {
  local owner="$1" journal="$2" pending state destination
  pending="$(jq -c '.external.render_pending' "$journal")" || return "$TRELLIS_EX_STATE"
  [ "$pending" != null ] || return "$TRELLIS_EX_CONFLICT"
  destination="$(printf '%s\n' "$owner" | jq -r '.worktree_root')/$(printf '%s\n' "$pending" | jq -r '.render.path')" || return "$TRELLIS_EX_STATE"
  state="$(attach_detach_render_pending_state "$owner" "$journal" "$pending")" || return "$?"
  case "$state" in
    source)
      attachment_detach_render_stage "$journal" || return "$?"
      attachment_detach_render_claim "$journal" || return "$?"
      if [ "${ATTACHMENT_FAULT_PHASE:-}" = detach-render-claimed ]; then return "$TRELLIS_EX_UNAVAILABLE"; fi
      ;;
    claimed) ;;
    published)
      attach_detach_render_pending_result_matches "$destination" "$pending" || return "$TRELLIS_EX_CONFLICT"
      attachment_detach_render_cleanup "$journal" || return "$?"
      pending="$(jq -c '.external.render_pending' "$journal")" || return "$TRELLIS_EX_STATE"
      attach_detach_render_pending_result_matches "$destination" "$pending" || return "$TRELLIS_EX_CONFLICT"
      attachment_detach_render_finish "$journal"
      return "$?"
      ;;
    *) return "$TRELLIS_EX_CONFLICT" ;;
  esac
  attachment_detach_render_stage "$journal" || return "$?"
  attachment_detach_render_publish "$journal" || return "$?"
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = detach-render-published ]; then return "$TRELLIS_EX_UNAVAILABLE"; fi
  # Staging pins the result identity into the journal, so the published bytes
  # have to be checked against the journal record rather than the pre-stage copy.
  pending="$(jq -c '.external.render_pending' "$journal")" || return "$TRELLIS_EX_STATE"
  attach_detach_render_pending_result_matches "$destination" "$pending" || return "$TRELLIS_EX_CONFLICT"
  attachment_detach_render_cleanup "$journal" || return "$?"
  pending="$(jq -c '.external.render_pending' "$journal")" || return "$TRELLIS_EX_STATE"
  attach_detach_render_pending_result_matches "$destination" "$pending" || return "$TRELLIS_EX_CONFLICT"
  attachment_detach_render_finish "$journal"
}

attach_detach_apply_renders() {
  local owner="$1" journal="$2" phase total pending
  while :; do
    phase="$(jq -r '.external.render_phase' "$journal")" || return "$TRELLIS_EX_STATE"
    total="$(jq '.external.renders | length' "$journal")" || return "$TRELLIS_EX_STATE"
    pending="$(jq -c '.external.render_pending' "$journal")" || return "$TRELLIS_EX_STATE"
    if [ "$phase" -eq "$total" ]; then
      [ "$pending" = null ] || return "$TRELLIS_EX_CONFLICT"
      return 0
    fi
    if [ "$pending" = null ]; then
      attach_detach_render_begin "$owner" "$journal" || return "$?"
    else
      attach_detach_render_resume "$owner" "$journal" || return "$?"
    fi
  done
}


# Clone-local dispatcher state is not a project artifact. It survives linked
attach_hooks_managed_path() {
  printf '%s/state/git-hooks/%s\n' "$1" "$2"
}

attach_hooks_write_file() {
  local path="$1" contents="$2" mode="$3" parent base temporary rc
  parent="$(dirname "$path")" || return "$TRELLIS_EX_STATE"
  base="$(basename "$path")" || return "$TRELLIS_EX_STATE"
  temporary="$(mktemp "$parent/.${base}.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod "$mode" "$temporary" || { rm -f "$temporary"; return "$TRELLIS_EX_UNAVAILABLE"; }
  printf '%s\n' "$contents" > "$temporary" || { rm -f "$temporary"; return "$TRELLIS_EX_UNAVAILABLE"; }
  release_store_rename_no_clobber "$temporary" "$path"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$temporary"
    return "$rc"
  fi
}

attach_hooks_create() {
  local hooks_root="$1" managed="$2" previous="$3" payload="$4" source="$5" manifest="$6" temporary rc
  _attachment_hooks_pre_push_source_valid "$source" || return "$TRELLIS_EX_STATE"
  temporary="$(mktemp -d "$hooks_root/.git-hooks.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 700 "$temporary" || { rm -rf "$temporary"; return "$TRELLIS_EX_UNAVAILABLE"; }
  attach_hooks_write_file "$temporary/post-checkout" "$(_attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest")" 700 || {
    rc=$?
    rm -rf "$temporary"
    return "$rc"
  }
  attach_hooks_write_file "$temporary/pre-push" "$(_attachment_hooks_pre_push_dispatcher_body "$payload" "$source" "$manifest")" 700 || {
    rc=$?
    rm -rf "$temporary"
    return "$rc"
  }
  attach_hooks_write_file "$temporary/previous-hooks-path" "$previous" 600 || {
    rc=$?
    rm -rf "$temporary"
    return "$rc"
  }
  attach_hooks_write_file "$temporary/release-payload" "$payload" 600 || {
    rc=$?
    rm -rf "$temporary"
    return "$rc"
  }
  attach_hooks_write_file "$temporary/pre-push-source" "$source" 600 || {
    rc=$?
    rm -rf "$temporary"
    return "$rc"
  }
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = hooks-staged ]; then
    rm -rf "$temporary"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  release_store_rename_no_clobber "$temporary" "$managed"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$temporary"
    return "$rc"
  fi
}
attach_hooks_recreate_missing_dispatchers() {
  local managed="$1" previous="$2" payload="$3" source="$4" manifest="$5"
  local entry base missing=false post_checkout pre_push managed_dev_ino
  [ -d "$managed" ] && [ ! -L "$managed" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_canonical_dir "$managed" || return "$TRELLIS_EX_CONFLICT"
  _attachment_mode_matches "$managed" 700 || return "$TRELLIS_EX_CONFLICT"
  for entry in "$managed"/?* "$managed"/.[!.]* "$managed"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="${entry##*/}"
    case "$base" in
      post-checkout|pre-push|previous-hooks-path|release-payload|pre-push-source) ;;
      *) return "$TRELLIS_EX_CONFLICT" ;;
    esac
  done
  _attachment_hooks_file_matches "$managed/previous-hooks-path" "$previous" 600 || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_file_matches "$managed/release-payload" "$payload" 600 || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_file_matches "$managed/pre-push-source" "$source" 600 || return "$TRELLIS_EX_CONFLICT"
  post_checkout="$(_attachment_hooks_post_checkout_dispatcher_body "$payload" "$manifest")" || return "$TRELLIS_EX_STATE"
  pre_push="$(_attachment_hooks_pre_push_dispatcher_body "$payload" "$source" "$manifest")" || return "$TRELLIS_EX_STATE"
  if [ ! -e "$managed/post-checkout" ] && [ ! -L "$managed/post-checkout" ]; then
    missing=true
  else
    _attachment_hooks_file_matches "$managed/post-checkout" "$post_checkout" 700 || return "$TRELLIS_EX_CONFLICT"
  fi
  if [ ! -e "$managed/pre-push" ] && [ ! -L "$managed/pre-push" ]; then
    missing=true
  else
    _attachment_hooks_file_matches "$managed/pre-push" "$pre_push" 700 || return "$TRELLIS_EX_CONFLICT"
  fi
  [ "$missing" = true ] || return "$TRELLIS_EX_CONFLICT"
  managed_dev_ino="$(release_store_directory_identity "$managed")" || return "$TRELLIS_EX_CONFLICT"
  [ -x /usr/bin/python3 ] || return "$TRELLIS_EX_UNAVAILABLE"
  /usr/bin/python3 - "$managed" "$managed_dev_ino" "$post_checkout" "$pre_push" <<'PY'
import errno
import os
import secrets
import stat
import sys

managed, expected_identity, post_checkout, pre_push = sys.argv[1:5]


def fail(code):
    raise SystemExit(code)


def parse_identity(value):
    parts = value.split(":", 1)
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        fail(17)
    return (int(parts[0]), int(parts[1]))


def identity_of(value):
    return (value.st_dev, value.st_ino)


def same_identity(value, expected):
    return identity_of(value) == expected


def checked_directory(descriptor, expected):
    value = os.fstat(descriptor)
    if not stat.S_ISDIR(value.st_mode) or not same_identity(value, expected):
        fail(17)


def remove_stage(parent_fd, name, expected):
    try:
        value = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if stat.S_ISREG(value.st_mode) and same_identity(value, expected):
            os.unlink(name, dir_fd=parent_fd)
    except OSError:
        pass


def write_missing(parent_fd, expected_directory, name, contents):
    try:
        existing = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    except OSError:
        fail(17)
    if existing is not None:
        return

    stage = None
    descriptor = None
    stage_identity = None
    data = (contents + "\n").encode("utf-8")
    for _ in range(32):
        candidate = ".trellis-hook-stage-" + secrets.token_hex(16)
        try:
            descriptor = os.open(
                candidate,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o700,
                dir_fd=parent_fd,
            )
        except FileExistsError:
            continue
        except OSError:
            fail(18)
        stage = candidate
        break
    if stage is None:
        fail(18)

    try:
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                fail(18)
            offset += written
        os.fsync(descriptor)
        value = os.fstat(descriptor)
        if not stat.S_ISREG(value.st_mode):
            fail(17)
        stage_identity = identity_of(value)
    finally:
        if descriptor is not None:
            os.close(descriptor)

    try:
        checked_directory(parent_fd, expected_directory)
        value = os.stat(stage, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(value.st_mode) or not same_identity(value, stage_identity):
            fail(17)
        os.link(
            stage,
            name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
            follow_symlinks=False,
        )
    except FileExistsError:
        fail(17)
    except OSError as error:
        if error.errno in (errno.EEXIST, errno.ENOENT, errno.ELOOP):
            fail(17)
        fail(18)
    finally:
        if stage_identity is not None:
            remove_stage(parent_fd, stage, stage_identity)


expected = parse_identity(expected_identity)
if not getattr(os, "O_DIRECTORY", 0) or not getattr(os, "O_NOFOLLOW", 0):
    fail(18)
try:
    managed_fd = os.open(managed, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    fail(17)
try:
    checked_directory(managed_fd, expected)
    write_missing(managed_fd, expected, "post-checkout", post_checkout)
    write_missing(managed_fd, expected, "pre-push", pre_push)
    checked_directory(managed_fd, expected)
except SystemExit:
    raise
except OSError:
    fail(18)
finally:
    os.close(managed_fd)
PY
  case "$?" in
    0) ;;
    17) return "$TRELLIS_EX_CONFLICT" ;;
    *) return "$TRELLIS_EX_UNAVAILABLE" ;;
  esac
}


attach_hooks_plan() {
  local home="$1" identity="$2" exclude="$3" root checkout managed current previous source
  root="$(printf '%s\n' "$identity" | jq -r '.root')" || return "$TRELLIS_EX_STATE"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  managed="$(attach_hooks_managed_path "$home" "$checkout")" || return "$TRELLIS_EX_STATE"
  current="$(attach_detach_hooks_current "$root")" || return "$?"
  if [ "$current" = "$managed" ]; then
    previous="$(_attachment_hooks_read_sidecar "$managed/previous-hooks-path" true)" || return "$TRELLIS_EX_CONFLICT"
    source="$(_attachment_hooks_read_sidecar "$managed/pre-push-source")" || return "$TRELLIS_EX_CONFLICT"
    [ "$previous" != "$managed" ] || return "$TRELLIS_EX_CONFLICT"
  else
    previous="$current"
    source="$(_attachment_hooks_pre_push_source_for_root "$root")" || return "$TRELLIS_EX_STATE"
  fi
  if [ "$(printf '%s\n' "$exclude" | jq -r '.managed_by_attachment')" != true ]; then
    printf '%s\n' '{"enabled":false}'
    return 0
  fi
  _attachment_hooks_pre_push_source_valid "$source" || return "$TRELLIS_EX_STATE"
  jq -cn --arg managed "$managed" --arg previous "$previous" --arg source "$source" '
    {
      enabled: true,
      managed_hooks_path: $managed,
      previous_hooks_path: (if $previous == "" then null else $previous end),
      pre_push_source: $source
    }'
}

attach_hooks_install() {
  local home="$1" owner="$2" locked_identity="$3" locked_root_dev_ino="$4" locked_common_dev_ino="$5"
  local expected_owner_sha256="${6:-}" expected_owner_parent_dev_ino="${7:-}"
  local enabled managed checkout root previous release payload source manifest carrier reconcile current hooks_root state_status
  [ "$#" -eq 5 ] || [ "$#" -eq 7 ] || return "$TRELLIS_EX_STATE"
  [ -n "$locked_identity" ] && [ -n "$locked_root_dev_ino" ] && [ -n "$locked_common_dev_ino" ] || return "$TRELLIS_EX_STATE"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return "$TRELLIS_EX_STATE"
  attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
  enabled="$(jq -r '.git_hooks.enabled // false' "$owner")" || return "$TRELLIS_EX_STATE"
  [ "$enabled" = true ] || return 0
  managed="$(jq -r '.git_hooks.managed_hooks_path // empty' "$owner")" || return "$TRELLIS_EX_STATE"
  checkout="$(jq -r '.checkout_id' "$owner")" || return "$TRELLIS_EX_STATE"
  root="$(jq -r '.worktree_root' "$owner")" || return "$TRELLIS_EX_STATE"
  previous="$(jq -r '.git_hooks.previous_hooks_path // empty' "$owner")" || return "$TRELLIS_EX_STATE"
  release="$(jq -r '.release' "$owner")" || return "$TRELLIS_EX_STATE"
  source="$(jq -r '.git_hooks.pre_push_source // empty' "$owner")" || return "$TRELLIS_EX_STATE"
  attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" >/dev/null || return "$?"
  [ "$managed" = "$(attach_hooks_managed_path "$home" "$checkout")" ] || return "$TRELLIS_EX_CONFLICT"
  _attachment_hooks_pre_push_source_valid "$source" || return "$TRELLIS_EX_STATE"
  payload="$(TRELLIS_HOME="$home" release_store_locate "$release")" || return "$?"
  payload="$payload/payload"
  manifest="$(_attachment_hooks_release_manifest_sha256 "$payload")" || return "$TRELLIS_EX_STATE"
  reconcile="$payload/scripts/seed-inheritance-symlinks.sh"
  carrier="$payload/$source"
  _attachment_canonical_file "$reconcile" && [ -x "$reconcile" ] || return "$TRELLIS_EX_STATE"
  _attachment_canonical_file "$carrier" && [ -x "$carrier" ] || return "$TRELLIS_EX_STATE"
  current="$(attach_detach_hooks_current "$root")" || return "$?"
  [ "$current" = "$previous" ] || [ "$current" = "$managed" ] || return "$TRELLIS_EX_CONFLICT"
  attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
  hooks_root="$home/state/git-hooks"
  _attachment_ensure_private_dir "$hooks_root" || return "$TRELLIS_EX_UNAVAILABLE"
  if [ ! -e "$managed" ] && [ ! -L "$managed" ]; then
    attach_hooks_create "$hooks_root" "$managed" "$previous" "$payload" "$source" "$manifest" || return "$?"
  else
    state_status=0
    _attachment_hooks_state_matches "$home" "$owner" || state_status=$?
    if [ "$state_status" -ne 0 ]; then
      attach_hooks_recreate_missing_dispatchers "$managed" "$previous" "$payload" "$source" "$manifest" || return "$?"
    fi
  fi
  if [ "$current" != "$managed" ]; then
    attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
    attach_relink_set_hooks_path_pinned "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" "$managed" || return "$?"
  fi
  _attachment_verify_managed_hooks "$home" "$owner" || return "$?"
  attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" >/dev/null
}

attach_hooks_remove() {
  local home="$1" owner="$2" enabled managed
  enabled="$(printf '%s\n' "$owner" | jq -r '.git_hooks.enabled // false')" || return "$TRELLIS_EX_STATE"
  [ "$enabled" = true ] || return 0
  managed="$(printf '%s\n' "$owner" | jq -r '.git_hooks.managed_hooks_path // empty')" || return "$TRELLIS_EX_STATE"
  if [ ! -e "$managed" ] && [ ! -L "$managed" ]; then
    return 0
  fi
  _attachment_hooks_state_owned_matches_data "$home" "$owner" || return "$?"
  rm -f "$managed/post-checkout" "$managed/pre-push" "$managed/previous-hooks-path" \
    "$managed/release-payload" "$managed/pre-push-source" || return "$TRELLIS_EX_UNAVAILABLE"
  rmdir "$managed" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
}

attach_detach_hooks_current() {
  local root="$1" values rc
  values="$(git -C "$root" config --local --get-all core.hooksPath 2>/dev/null)"
  rc=$?
  case "$rc" in
    0)
      [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" -eq 1 ] || return "$TRELLIS_EX_CONFLICT"
      printf '%s\n' "$values"
      ;;
    1) printf '\n' ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
}

attach_detach_hooks_preflight() {
  local owner="$1" root enabled managed current
  enabled="$(printf '%s\n' "$owner" | jq -r '.git_hooks.enabled // false')" || return "$TRELLIS_EX_STATE"
  [ "$enabled" = true ] || return 0
  root="$(printf '%s\n' "$owner" | jq -r '.worktree_root')" || return "$TRELLIS_EX_STATE"
  managed="$(printf '%s\n' "$owner" | jq -r '.git_hooks.managed_hooks_path // empty')" || return "$TRELLIS_EX_STATE"
  [ -n "$managed" ] || return "$TRELLIS_EX_STATE"
  current="$(attach_detach_hooks_current "$root")" || return "$?"
  [ "$current" = "$managed" ] || return "$TRELLIS_EX_CONFLICT"
}

attach_detach_restore_hooks() {
  local owner="$1" root enabled managed previous current home
  enabled="$(printf '%s\n' "$owner" | jq -r '.git_hooks.enabled // false')" || return "$TRELLIS_EX_STATE"
  [ "$enabled" = true ] || return 0
  root="$(printf '%s\n' "$owner" | jq -r '.worktree_root')" || return "$TRELLIS_EX_STATE"
  managed="$(printf '%s\n' "$owner" | jq -r '.git_hooks.managed_hooks_path // empty')" || return "$TRELLIS_EX_STATE"
  previous="$(printf '%s\n' "$owner" | jq -r '.git_hooks.previous_hooks_path // empty')" || return "$TRELLIS_EX_STATE"
  current="$(attach_detach_hooks_current "$root")" || return "$?"
  if [ "$current" = "$managed" ]; then
    if [ -n "$previous" ]; then
      git -C "$root" config --local core.hooksPath "$previous" || return "$TRELLIS_EX_UNAVAILABLE"
    else
      git -C "$root" config --local --unset-all core.hooksPath 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
    fi
  elif [ "$current" != "$previous" ]; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  [ "$(attach_detach_hooks_current "$root")" = "$previous" ] || return "$TRELLIS_EX_CONFLICT"
  home="$(trellis_home_resolve "")" || return "$?"
  attach_hooks_remove "$home" "$owner"
}

attach_detach_transfer_exclude() {
  local external="$1" transfer path expected after
  transfer="$(printf '%s\n' "$external" | jq -c '.transfer // null')" || return "$TRELLIS_EX_STATE"
  [ "$transfer" = null ] && return 0
  path="$(printf '%s\n' "$transfer" | jq -r '.owner_path')" || return "$TRELLIS_EX_STATE"
  expected="$(printf '%s\n' "$transfer" | jq -c '.expected')" || return "$TRELLIS_EX_STATE"
  after="$(printf '%s\n' "$transfer" | jq -c '.after')" || return "$TRELLIS_EX_STATE"
  if _attachment_detach_file_matches_data "$path" "$after"; then return 0; fi
  _attachment_detach_file_matches_data "$path" "$expected" || return "$TRELLIS_EX_CONFLICT"
  _attachment_verify_detach_owner_artifacts "$path" || return "$TRELLIS_EX_CONFLICT"
  _attachment_write_json "$path" "$after"
}
attach_detach_rebase_shared_restore() {
  local home="$1" journal="$2" original external phase action checkout owner_path owner record
  local owners='[]' candidate expected after transfer
  original="$(jq -c '.original_owner' "$journal")" || return "$TRELLIS_EX_STATE"
  external="$(jq -c '.external' "$journal")" || return "$TRELLIS_EX_STATE"
  [ "$(jq -r '.owner_committed' "$journal")" = true ] || return "$TRELLIS_EX_CONFLICT"
  phase="$(printf '%s\n' "$external" | jq -r '.phase')" || return "$TRELLIS_EX_STATE"
  action="$(printf '%s\n' "$external" | jq -r '.exclude_action')" || return "$TRELLIS_EX_STATE"
  [ "$action" = restore ] || return 0
  case "$phase" in 0|1|2) ;; *) return "$TRELLIS_EX_CONFLICT" ;; esac
  checkout="$(printf '%s\n' "$original" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  owner_path="$(attach_detach_owner_files "$home" "$checkout")" || return "$?"
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    attachment_verify_detach "$home" "$owner" || return "$?"
    record="$(jq -cS . "$owner")" || return "$TRELLIS_EX_STATE"
    owners="$(jq -cn --argjson current "$owners" --arg path "$owner" --argjson record "$record" \
      '$current + [{path:$path,record:$record}]')" || return "$TRELLIS_EX_STATE"
  done <<< "$owner_path"
  [ "$(printf '%s\n' "$owners" | jq 'length')" -gt 0 ] || return 0
  attach_exclude_verify_state "$(printf '%s\n' "$original" | jq -c '.exclude')" || return "$?"
  if [ "$(printf '%s\n' "$original" | jq -r '.git_hooks.enabled // false')" = true ]; then
    attach_detach_hooks_preflight "$original" || return "$?"
  fi
  candidate="$(printf '%s\n' "$owners" | jq -c '.[0]')" || return "$TRELLIS_EX_STATE"
  expected="$(printf '%s\n' "$candidate" | jq -c '.record')" || return "$TRELLIS_EX_STATE"
  after="$(printf '%s\n' "$expected" | jq -c \
    --argjson exclude "$(printf '%s\n' "$original" | jq -c '.exclude')" \
    --arg hash "$(printf '%s\n' "$original" | jq -r '.exclude_block_hash')" \
    --argjson hooks "$(printf '%s\n' "$original" | jq -c '.git_hooks // null')" \
    '.exclude = $exclude | .exclude_block_hash = $hash
     | if $hooks == null then del(.git_hooks) else .git_hooks = $hooks end')" || return "$TRELLIS_EX_STATE"
  transfer="$(jq -cn --arg path "$(printf '%s\n' "$candidate" | jq -r '.path')" \
    --argjson expected "$expected" --argjson after "$after" '{owner_path:$path,expected:$expected,after:$after}')" || return "$TRELLIS_EX_STATE"
  _attachment_detach_journal_update "$journal" --argjson transfer "$transfer" '
    if .owner_committed == true and .external.phase >= 0 and .external.phase < 3
      and .external.exclude_action == "restore" and .external.transfer == null
    then .external.exclude_action = "transfer" | .external.transfer = $transfer | .external.restore_hooks = false
    else error("invalid shared detach rebase") end
  ' || return "$?"
  _attachment_detach_journal_valid "$journal" || return "$?"
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = detach-rebase-transfer-pending ]; then
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
}


_attach_detach_finish_journal_locked() {
  local home="$1" journal="$2" original external phase action
  original="$(jq -c '.original_owner' "$journal")" || return "$TRELLIS_EX_STATE"
  attach_detach_rebase_shared_restore "$home" "$journal" || return "$?"
  external="$(jq -c '.external' "$journal")" || return "$TRELLIS_EX_STATE"
  phase="$(printf '%s\n' "$external" | jq -r '.phase')" || return "$TRELLIS_EX_STATE"
  action="$(printf '%s\n' "$external" | jq -r '.exclude_action // "none"')" || return "$TRELLIS_EX_STATE"
  if [ "$action" = transfer ]; then
    attach_detach_transfer_exclude "$external" || return "$?"
  fi
  if [ "$phase" -lt 1 ]; then
    attachment_detach_mark_external_phase "$home" "$journal" 1 || return "$?"
    phase=1
  fi
  if [ "$phase" -lt 2 ]; then
    attach_detach_apply_renders "$original" "$journal" || return "$?"
    external="$(jq -c '.external' "$journal")" || return "$TRELLIS_EX_STATE"
    jq -e '
      .render_phase == (.renders | length)
      and .render_pending == null
    ' <<< "$external" >/dev/null 2>&1 || return "$TRELLIS_EX_CONFLICT"
    [ "$(jq -r '.removal == null' "$journal")" = true ] || return "$TRELLIS_EX_CONFLICT"
    attachment_detach_mark_external_phase "$home" "$journal" 2 || return "$?"
    phase=2
  fi
  if [ "$phase" -lt 3 ]; then
    action="$(printf '%s\n' "$external" | jq -r '.exclude_action // "none"')" || return "$TRELLIS_EX_STATE"
    case "$action" in
      none|transfer) ;;
      restore) attach_exclude_recover "$(printf '%s\n' "$original" | jq -c '.exclude')" || return "$?" ;;
      *) return "$TRELLIS_EX_STATE" ;;
    esac
    attachment_detach_mark_external_phase "$home" "$journal" 3 || return "$?"
    phase=3
  fi
  if [ "$phase" -lt 4 ]; then
    if [ "$(printf '%s\n' "$external" | jq -r '.restore_hooks // false')" = true ]; then
      attach_detach_restore_hooks "$original" || return "$?"
    fi
    attachment_detach_mark_external_phase "$home" "$journal" 4 || return "$?"
    phase=4
  fi
  if [ "$phase" -lt 5 ]; then
    if [ "$(printf '%s\n' "$external" | jq -r '.clear_registry // false')" = true ]; then
      attach_detach_restore_registry "$home" "$original" || return "$?"
    fi
    attachment_detach_mark_external_phase "$home" "$journal" 5 || return "$?"
  fi
  attachment_detach_finalize "$home" "$journal"
}

_attach_detach_finish_journal_impl() (
  local home="$1" journal="$2" checkout worktree attachment
  _attachment_prepare_state "$home" || return "$?"
  _attachment_detach_journal_valid "$journal" || return "$?"
  checkout="$(jq -r '.checkout_id' "$journal")" || return "$TRELLIS_EX_STATE"
  worktree="$(jq -r '.worktree_id' "$journal")" || return "$TRELLIS_EX_STATE"
  attachment="$(jq -r '.attachment_id' "$journal")" || return "$TRELLIS_EX_STATE"
  _attachment_lock_acquire "$home" "$checkout" "$worktree" "$attachment" || return "$?"
  _attachment_install_lock_traps
  _attachment_detach_journal_valid "$journal" || return "$?"
  _attach_detach_finish_journal_locked "$home" "$journal"
)

attach_detach_finish_journal() {
  local status
  _attach_detach_finish_journal_impl "$@"
  status=$?
  _attachment_map_public_status "$status"
}

attach_cmd_detach() (
  local home_opt="" root_opt="" home root identity checkout common requested_harnesses owner_path owner record selected plan
  local owners='[]' plans='[]' after='[]' manager manager_worktree manager_plan candidate transfer_expected transfer_after external
  local journal pending rc project_id hooks_owner
  local all_worktrees=false
  local -a harnesses=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || { attach_usage_error '--home requires PATH'; return $?; }; home_opt="$2"; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || { attach_usage_error '--harness requires NAME'; return $?; }; harnesses+=("$2"); shift 2 ;;
      --all-worktrees) all_worktrees=true; shift ;;
      --) shift; break ;;
      -h|--help) attach_usage; return 0 ;;
      -*) attach_usage_error "unknown detach option: $1"; return $? ;;
      *) [ -z "$root_opt" ] || { attach_usage_error 'detach accepts one PATH'; return $?; }; root_opt="$1"; shift ;;
    esac
  done
  [ "$#" -eq 0 ] || { attach_usage_error "unexpected argument: $1"; return $?; }
  [ -n "$root_opt" ] || { attach_usage_error 'detach requires PATH'; return $?; }
  home="$(trellis_home_resolve "$home_opt")" || return "$?"
  trellis_home_prepare_home "$home" || return "$?"
  root="$(attach_canonical_root "$root_opt")" || return "$?"
  identity="$(local_registry_identity_for_root "$root")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  attachment_checkout_lock_reclaim "$home" "$checkout" "$common" || return "$?"
  attachment_checkout_lock_acquire "$home" "$checkout" "$common" || return "$?"
  _attachment_install_checkout_lock_traps
  if [ -n "${ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK:-}" ]; then sleep "$ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK"; fi
  pending="$(attach_detach_pending_journals "$home" "$identity" "$root" "$all_worktrees")" || return "$?"
  if [ -n "$pending" ]; then
    if [ "$all_worktrees" = false ] && [ "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')" -ne 1 ]; then
      attach_err "multiple matching detach journals for $root"
      return "$TRELLIS_EX_STATE"
    fi
    while IFS= read -r journal; do
      [ -n "$journal" ] || continue
      attachment_detach_recover "$home" "$journal" || return "$?"
      attach_detach_finish_journal "$home" "$journal" || return "$?"
    done <<< "$pending"
  fi
  requested_harnesses="$(attach_normalize_harnesses "${harnesses[@]+"${harnesses[@]}"}")" || return "$?"
  if ! owner_path="$(attach_detach_owner_files "$home" "$(printf '%s\n' "$identity" | jq -r '.checkout_id')")"; then
    printf 'already detached: %s\n' "$root"
    return 0
  fi
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    attachment_verify_detach "$home" "$owner" || return "$?"
    record="$(jq -cS . "$owner")" || return "$TRELLIS_EX_STATE"
    owners="$(jq -cn --argjson current "$owners" --arg path "$owner" --argjson record "$record" '$current + [{path:$path,record:$record}]')" || return "$TRELLIS_EX_STATE"
  done <<< "$owner_path"
  [ "$(printf '%s\n' "$owners" | jq 'length')" -gt 0 ] || { printf 'already detached: %s\n' "$root"; return 0; }
  manager="$(printf '%s\n' "$owners" | jq -c '[.[] | select(.record.exclude.managed_by_attachment == true)] | if length == 1 then .[0] else error("missing manager") end' 2>/dev/null)" || {
    attach_err 'committed checkout ownership has no single exclude manager'
    return "$TRELLIS_EX_CONFLICT"
  }
  attach_exclude_verify_state "$(printf '%s\n' "$manager" | jq -c '.record.exclude')" || return "$?"
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    record="$(printf '%s\n' "$owner" | jq -c '.record')" || return "$TRELLIS_EX_STATE"
    if [ "$all_worktrees" = true ] || [ "$(printf '%s\n' "$record" | jq -r '.worktree_id')" = "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" ]; then
      if [ "${#harnesses[@]}" -eq 0 ]; then
        selected="$(printf '%s\n' "$record" | jq -c '[.artifacts[].path | if . == "AGENTS.md" or startswith(".agents/") or startswith(".codex/") then "codex" elif startswith(".claude/") then "claude" elif startswith(".omp/") then "omp" else empty end] | unique | sort')" || return "$TRELLIS_EX_STATE"
      else
        selected="$requested_harnesses"
      fi
      plan="$(attach_detach_owner_plan "$record" "$selected")" || return "$TRELLIS_EX_STATE"
      if [ "$(printf '%s\n' "$plan" | jq '(.remove + .removed_renders) | length')" -gt 0 ]; then
        attach_detach_render_preflight "$record" "$(printf '%s\n' "$plan" | jq -c '.removed_renders')" || return "$?"
        plans="$(jq -cn --argjson current "$plans" --arg path "$(printf '%s\n' "$owner" | jq -r '.path')" --argjson record "$record" --argjson plan "$plan" \
          '$current + [{path:$path,record:$record,worktree_id:$record.worktree_id,next:$plan.next_owner,remove:$plan.remove,external:{exclude_action:"none",restore_hooks:false,clear_registry:($plan.next_owner == null),transfer:null,renders:$plan.removed_renders}}]')" || return "$TRELLIS_EX_STATE"
      fi
    fi
  done < <(printf '%s\n' "$owners" | jq -c '.[]')
  [ "$(printf '%s\n' "$plans" | jq 'length')" -gt 0 ] || { printf 'already detached: %s\n' "$root"; return 0; }

  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    record="$(printf '%s\n' "$owner" | jq -c '.record')" || return "$TRELLIS_EX_STATE"
    plan="$(printf '%s\n' "$plans" | jq -c --arg worktree "$(printf '%s\n' "$record" | jq -r '.worktree_id')" '[.[] | select(.worktree_id == $worktree)] | if length == 1 then .[0] else null end')" || return "$TRELLIS_EX_STATE"
    if [ "$plan" = null ]; then
      after="$(jq -cn --argjson current "$after" --arg path "$(printf '%s\n' "$owner" | jq -r '.path')" --argjson record "$record" '$current + [{path:$path,record:$record}]')" || return "$TRELLIS_EX_STATE"
    elif [ "$(printf '%s\n' "$plan" | jq -r '.next == null')" = false ]; then
      after="$(jq -cn --argjson current "$after" --arg path "$(printf '%s\n' "$plan" | jq -r '.path')" --argjson record "$(printf '%s\n' "$plan" | jq -c '.next')" '$current + [{path:$path,record:$record}]')" || return "$TRELLIS_EX_STATE"
    fi
  done < <(printf '%s\n' "$owners" | jq -c '.[]')

  manager_worktree="$(printf '%s\n' "$manager" | jq -r '.record.worktree_id')" || return "$TRELLIS_EX_STATE"
  manager_plan="$(printf '%s\n' "$plans" | jq -c --arg worktree "$manager_worktree" '[.[] | select(.worktree_id == $worktree)] | if length == 1 then .[0] else null end')" || return "$TRELLIS_EX_STATE"
  if [ "$manager_plan" != null ] && [ "$(printf '%s\n' "$manager_plan" | jq -r '.next == null')" = true ]; then
    if [ "$(printf '%s\n' "$after" | jq 'length')" -eq 0 ]; then
      external="$(printf '%s\n' "$manager_plan" | jq -c '.external + {exclude_action:"restore"}')" || return "$TRELLIS_EX_STATE"
      plans="$(printf '%s\n' "$plans" | jq -c --arg worktree "$manager_worktree" --argjson external "$external" 'map(if .worktree_id == $worktree then .external = $external else . end)')" || return "$TRELLIS_EX_STATE"
      hooks_owner="$(printf '%s\n' "$plans" | jq -c '[.[] | select(.record.git_hooks.enabled // false)] | if length == 0 then null else .[0].worktree_id end')" || return "$TRELLIS_EX_STATE"
      if [ "$hooks_owner" != null ]; then
        hooks_owner="${hooks_owner#\"}"; hooks_owner="${hooks_owner%\"}"
        attach_detach_hooks_preflight "$(printf '%s\n' "$plans" | jq -c --arg worktree "$hooks_owner" '.[] | select(.worktree_id == $worktree) | .record')" || return "$?"
        plans="$(printf '%s\n' "$plans" | jq -c --arg worktree "$hooks_owner" 'map(if .worktree_id == $worktree then .external.restore_hooks = true else . end)')" || return "$TRELLIS_EX_STATE"
      fi
    else
      candidate="$(printf '%s\n' "$after" | jq -c '.[0]')" || return "$TRELLIS_EX_STATE"
      transfer_expected="$(printf '%s\n' "$candidate" | jq -c '.record')" || return "$TRELLIS_EX_STATE"
      transfer_after="$(printf '%s\n' "$transfer_expected" | jq -c \
        --argjson exclude "$(printf '%s\n' "$manager" | jq -c '.record.exclude')" \
        --arg hash "$(printf '%s\n' "$manager" | jq -r '.record.exclude_block_hash')" \
        --argjson hooks "$(printf '%s\n' "$manager" | jq -c '.record.git_hooks // null')" \
        '.exclude = $exclude | .exclude_block_hash = $hash
         | if $hooks == null then del(.git_hooks) else .git_hooks = $hooks end')" || return "$TRELLIS_EX_STATE"
      external="$(printf '%s\n' "$manager_plan" | jq -c --argjson transfer "$(jq -cn --arg path "$(printf '%s\n' "$candidate" | jq -r '.path')" --argjson expected "$transfer_expected" --argjson after "$transfer_after" '{owner_path:$path,expected:$expected,after:$after}')" '.external + {exclude_action:"transfer",transfer:$transfer}')" || return "$TRELLIS_EX_STATE"
      plans="$(printf '%s\n' "$plans" | jq -c --arg worktree "$manager_worktree" --argjson external "$external" 'map(if .worktree_id == $worktree then .external = $external else . end)')" || return "$TRELLIS_EX_STATE"
    fi
  fi

  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    if [ "$(printf '%s\n' "$plan" | jq -r '.next == null')" = true ]; then
      attach_detach_registry_preflight "$home" "$(printf '%s\n' "$plan" | jq -c '.record')" || return "$?"
    fi
    attachment_detach_prepare "$home" "$(printf '%s\n' "$plan" | jq -r '.path')" "$(printf '%s\n' "$plan" | jq -c '.next')" "$(printf '%s\n' "$plan" | jq -c '.remove')" "$(printf '%s\n' "$plan" | jq -c '.external')" || return "$?"
  done < <(printf '%s\n' "$plans" | jq -c '.[]')
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = detach-prepared ]; then return "$TRELLIS_EX_UNAVAILABLE"; fi
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    journal="$(_attachment_detach_journal_path "$home" "$(printf '%s\n' "$plan" | jq -r '.record.attachment_id')")"
    attachment_detach_commit "$home" "$journal" || return "$?"
  done < <(printf '%s\n' "$plans" | jq -c '.[]')
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = detach-committed ]; then return "$TRELLIS_EX_UNAVAILABLE"; fi
  while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    journal="$(_attachment_detach_journal_path "$home" "$(printf '%s\n' "$plan" | jq -r '.record.attachment_id')")"
    attach_detach_finish_journal "$home" "$journal" || return "$?"
  done < <(printf '%s\n' "$plans" | jq -c '.[]')
  printf 'detached: %s\n' "$root"
)

attach_cmd_attach() (
  local home_opt="" fleet_opt="" release_opt="" expected_project_id="" root_opt="" home config fleet release root identity checkout common locked_identity locked_root_dev_ino locked_common_dev_ino project_id payload surfaces attachment_id plan journal exclude_before exclude_after exclude owner owner_release owner_fleet owner_harnesses requested_harnesses requested_release requested_fleet harnesses_json rc rollback_rc registry_rc selector expected_binding="" expected_donor_binding="" render_context=null
  local expected_owner_sha256="" expected_owner_parent_dev_ino="" pre_existing="[]"
  local expected_owner_sha_seen=0 expected_owner_parent_seen=0
  local expected_donor_root="" expected_donor_checkout_id="" expected_donor_worktree_id="" expected_donor_attachment_id="" expected_donor_release="" expected_donor_harnesses_json=""
  local expected_binding_requested=0 expected_fleet_seen=0 expected_project_seen=0 expected_root_seen=0 expected_checkout_seen=0 expected_worktree_seen=0 expected_attachment_seen=0 expected_release_seen=0 expected_harnesses_seen=0
  local expected_donor_binding_requested=0 expected_donor_root_seen=0 expected_donor_checkout_seen=0 expected_donor_worktree_seen=0 expected_donor_attachment_seen=0 expected_donor_release_seen=0 expected_donor_harnesses_seen=0
  local -a harnesses=() selectors=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || { attach_usage_error '--home requires PATH'; return $?; }; home_opt="$2"; shift 2 ;;
      --fleet) [ "$#" -ge 2 ] || { attach_usage_error '--fleet requires NAME'; return $?; }; fleet_opt="$2"; shift 2 ;;
      --release) [ "$#" -ge 2 ] || { attach_usage_error '--release requires VERSION'; return $?; }; release_opt="$2"; shift 2 ;;
      --expected-fleet) [ "$#" -ge 2 ] || { attach_usage_error '--expected-fleet requires NAME'; return $?; }; expected_fleet="$2"; expected_fleet_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-project-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-project-id requires ID'; return $?; }; expected_project_id="$2"; expected_project_seen=1; shift 2 ;;
      --expected-root) [ "$#" -ge 2 ] || { attach_usage_error '--expected-root requires PATH'; return $?; }; expected_root="$2"; expected_root_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-checkout-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-checkout-id requires ID'; return $?; }; expected_checkout_id="$2"; expected_checkout_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-worktree-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-worktree-id requires ID'; return $?; }; expected_worktree_id="$2"; expected_worktree_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-attachment-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-attachment-id requires ID'; return $?; }; expected_attachment_id="$2"; expected_attachment_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-release) [ "$#" -ge 2 ] || { attach_usage_error '--expected-release requires VERSION'; return $?; }; expected_release="$2"; expected_release_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-harnesses-json) [ "$#" -ge 2 ] || { attach_usage_error '--expected-harnesses-json requires JSON'; return $?; }; expected_harnesses_json="$2"; expected_harnesses_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-donor-root) [ "$#" -ge 2 ] || { attach_usage_error '--expected-donor-root requires PATH'; return $?; }; expected_donor_root="$2"; expected_donor_root_seen=1; expected_donor_binding_requested=1; expected_binding_requested=1; shift 2 ;;
      --expected-donor-checkout-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-donor-checkout-id requires ID'; return $?; }; expected_donor_checkout_id="$2"; expected_donor_checkout_seen=1; expected_donor_binding_requested=1; expected_binding_requested=1; shift 2 ;;
      --expected-donor-worktree-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-donor-worktree-id requires ID'; return $?; }; expected_donor_worktree_id="$2"; expected_donor_worktree_seen=1; expected_donor_binding_requested=1; expected_binding_requested=1; shift 2 ;;
      --expected-donor-attachment-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-donor-attachment-id requires ID'; return $?; }; expected_donor_attachment_id="$2"; expected_donor_attachment_seen=1; expected_donor_binding_requested=1; expected_binding_requested=1; shift 2 ;;
      --expected-donor-release) [ "$#" -ge 2 ] || { attach_usage_error '--expected-donor-release requires VERSION'; return $?; }; expected_donor_release="$2"; expected_donor_release_seen=1; expected_donor_binding_requested=1; expected_binding_requested=1; shift 2 ;;
      --expected-donor-harnesses-json) [ "$#" -ge 2 ] || { attach_usage_error '--expected-donor-harnesses-json requires JSON'; return $?; }; expected_donor_harnesses_json="$2"; expected_donor_harnesses_seen=1; expected_donor_binding_requested=1; expected_binding_requested=1; shift 2 ;;
      --expected-owner-sha256) [ "$#" -ge 2 ] || { attach_usage_error '--expected-owner-sha256 requires SHA256'; return $?; }; expected_owner_sha256="$2"; expected_owner_sha_seen=1; shift 2 ;;
      --expected-owner-parent-dev-ino) [ "$#" -ge 2 ] || { attach_usage_error '--expected-owner-parent-dev-ino requires DEV:INO'; return $?; }; expected_owner_parent_dev_ino="$2"; expected_owner_parent_seen=1; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || { attach_usage_error '--harness requires NAME'; return $?; }; harnesses+=("$2"); shift 2 ;;
      --) shift; break ;;
      -h|--help) attach_usage; return 0 ;;
      -*) attach_usage_error "unknown attach option: $1"; return $? ;;
      *) [ -z "$root_opt" ] || { attach_usage_error 'attach accepts one PATH'; return $?; }; root_opt="$1"; shift ;;
    esac
  done
  [ "$#" -eq 0 ] || { attach_usage_error "unexpected argument: $1"; return $?; }
  [ -n "$root_opt" ] || { attach_usage_error 'attach requires PATH'; return $?; }
  home="$(trellis_home_resolve "$home_opt")" || return "$?"
  config="$(trellis_home_config_path "$home")"
  root="$(attach_canonical_root "$root_opt")" || return "$?"
  [ -z "$expected_project_id" ] || local_registry_require_project_id "$expected_project_id" || return "$?"
  project_id="$(local_registry_manifest_project_id "$root/.trellis.json")" || return "$?"
  [ -z "$expected_project_id" ] || [ "$project_id" = "$expected_project_id" ] || {
    attach_err "project manifest ID $project_id does not match expected registry project ID $expected_project_id"
    return "$TRELLIS_EX_CONFLICT"
  }
  if [ "$expected_binding_requested" -eq 1 ]; then
    if [ "$expected_fleet_seen" -ne 1 ] || [ "$expected_project_seen" -ne 1 ] ||
       [ "$expected_root_seen" -ne 1 ] || [ "$expected_checkout_seen" -ne 1 ] ||
       [ "$expected_worktree_seen" -ne 1 ] || [ "$expected_attachment_seen" -ne 1 ] ||
       [ "$expected_release_seen" -ne 1 ] || [ "$expected_harnesses_seen" -ne 1 ]; then
      attach_usage_error 'expected repair binding requires fleet, project, root, checkout, worktree, attachment, release, and harnesses'
      return "$TRELLIS_EX_USAGE"
    fi
    expected_binding="$(attach_expected_binding_build "$expected_fleet" "$expected_project_id" "$expected_root" \
      "$expected_checkout_id" "$expected_worktree_id" "$expected_attachment_id" \
      "$expected_release" "$expected_harnesses_json")" || return "$?"
  fi
  if [ "$expected_donor_binding_requested" -eq 1 ]; then
    if [ "$expected_donor_root_seen" -ne 1 ] || [ "$expected_donor_checkout_seen" -ne 1 ] ||
       [ "$expected_donor_worktree_seen" -ne 1 ] || [ "$expected_donor_attachment_seen" -ne 1 ] ||
       [ "$expected_donor_release_seen" -ne 1 ] || [ "$expected_donor_harnesses_seen" -ne 1 ]; then
      attach_usage_error 'expected donor binding requires root, checkout, worktree, attachment, release, and harnesses'
      return "$TRELLIS_EX_USAGE"
    fi
    [ -z "$expected_attachment_id" ] || {
      attach_usage_error 'expected donor binding requires an unattached target state'
      return "$TRELLIS_EX_USAGE"
    }
    [ "$expected_donor_checkout_id" = "$expected_checkout_id" ] || {
      attach_usage_error 'expected donor checkout ID must match the target checkout ID'
      return "$TRELLIS_EX_USAGE"
    }
    [ "$expected_donor_worktree_id" != "$expected_worktree_id" ] &&
      [ "$expected_donor_root" != "$expected_root" ] || {
      attach_usage_error 'expected donor must name a different worktree from the target'
      return "$TRELLIS_EX_USAGE"
    }
    expected_donor_binding="$(attach_expected_donor_binding_build "$expected_fleet" "$expected_project_id" \
      "$expected_donor_root" "$expected_donor_checkout_id" "$expected_donor_worktree_id" \
      "$expected_donor_attachment_id" "$expected_donor_release" "$expected_donor_harnesses_json")" || return "$?"
  fi
  if [ "$expected_owner_sha_seen" -ne "$expected_owner_parent_seen" ]; then
    attach_usage_error 'expected owner repair state requires both owner SHA-256 and ownership parent DEV:INO'
    return "$TRELLIS_EX_USAGE"
  fi
  if [ "$expected_owner_sha_seen" -eq 1 ]; then
    attach_expected_sha256_valid "$expected_owner_sha256" || {
      attach_usage_error 'expected owner SHA-256 must be 64 lowercase hexadecimal characters'
      return "$TRELLIS_EX_USAGE"
    }
    attach_expected_directory_identity_valid "$expected_owner_parent_dev_ino" || {
      attach_usage_error 'expected ownership parent DEV:INO is invalid'
      return "$TRELLIS_EX_USAGE"
    }
  fi
  trellis_home_prepare_home "$home" || return "$?"
  identity="$(local_registry_identity_for_root "$root")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  locked_identity="$identity"
  locked_root_dev_ino="$(attach_relink_directory_identity "$root")" || return "$?"
  locked_common_dev_ino="$(attach_relink_directory_identity "$common")" || return "$?"
  attachment_checkout_lock_reclaim "$home" "$checkout" "$common" || return "$?"
  attachment_checkout_lock_acquire "$home" "$checkout" "$common" || return "$?"
  _attachment_install_checkout_lock_traps
  if [ -n "${ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK:-}" ]; then sleep "$ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK"; fi
  if [ -n "$expected_donor_binding" ]; then
    attach_expected_binding_test_barrier || return "$?"
  fi
  identity="$(attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  project_id="$(local_registry_manifest_project_id "$root/.trellis.json")" || return "$?"
  [ -z "$expected_project_id" ] || [ "$project_id" = "$expected_project_id" ] || {
    attach_err 'project manifest changed while waiting for the expected repair binding'
    return "$TRELLIS_EX_CONFLICT"
  }
  if [ -n "$expected_binding" ]; then
    attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" "$expected_donor_binding" || return "$?"
  fi
  requested_harnesses="$(attach_normalize_harnesses "${harnesses[@]+"${harnesses[@]}"}")" || return "$?"

  if owner="$(attach_existing_owner "$home" "$identity")"; then
    attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
    attach_expected_binding_owner_matches "$owner" "$expected_binding" || return "$?"
    attach_verify_owner_artifacts "$home" "$owner" || return "$?"
    owner_release="$(jq -r '.release' "$owner")" || return "$TRELLIS_EX_STATE"
    owner_fleet="$(jq -r '.fleet' "$owner")" || return "$TRELLIS_EX_STATE"
    owner_harnesses="$(attach_harnesses_from_owner "$owner")" || return "$TRELLIS_EX_STATE"
    [ "$requested_harnesses" = "$owner_harnesses" ] || { attach_err "requested harnesses differ from the recorded attachment"; return "$TRELLIS_EX_CONFLICT"; }
    if [ -n "$release_opt" ] || [ -n "${TRELLIS_RELEASE:-}" ]; then
      requested_release="$(trellis_home_resolve_release "$release_opt" "" "")" || return "$?"
      [ "$requested_release" = "$owner_release" ] || { attach_err "recorded release $owner_release conflicts with requested release $requested_release; use release adopt"; return "$TRELLIS_EX_CONFLICT"; }
    fi
    if [ -n "$fleet_opt" ] || [ -n "${TRELLIS_FLEET:-}" ]; then
      requested_fleet="$(trellis_home_resolve_fleet "$fleet_opt" "")" || return "$?"
      [ "$requested_fleet" = "$owner_fleet" ] || { attach_err "recorded fleet conflicts with requested fleet $requested_fleet; use registry move"; return "$TRELLIS_EX_CONFLICT"; }
    fi
    attach_exclude_verify_state "$(jq -c '.exclude' "$owner")" || return "$?"
    attach_expected_binding_matches_selection "$expected_binding" "$owner_fleet" "$project_id" "$root" \
      "$identity" "$(jq -r '.attachment_id' "$owner")" "$owner_release" "$owner_harnesses" || return "$?"
    attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" "$expected_donor_binding" || return "$?"
    attach_expected_binding_owner_matches "$owner" "$expected_binding" || return "$?"
    attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
    attach_hooks_install "$home" "$owner" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" \
      "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
    attach_register "$home" "$owner_fleet" "$project_id" "$root" "$owner_release" "$owner_harnesses" "$(jq -r '.attachment_id' "$owner")" >/dev/null || return "$?"
    printf 'already attached: %s\n' "$root"
    return 0
  fi
  if [ "$expected_owner_sha_seen" -eq 1 ]; then
    attach_err 'expected attachment owner is no longer available'
    return "$TRELLIS_EX_CONFLICT"
  fi

  fleet="$(trellis_home_resolve_fleet "$fleet_opt" "$config")" || return "$?"
  release="$(trellis_home_resolve_release "$release_opt" "$config" '')" || return "$?"
  payload="$(release_store_locate "$release")" || return "$?"
  payload="$payload/payload"
  [ -d "$payload" ] && [ ! -L "$payload" ] || return "$TRELLIS_EX_STATE"
  if [ "${#harnesses[@]}" -eq 0 ]; then
    surfaces="$(surface_plan_emit "$payload")" || return "$?"
  else
    selectors=()
    for selector in "${harnesses[@]}"; do
      selectors+=("--harness" "$selector")
    done
    surfaces="$(surface_plan_main --payload "$payload" "${selectors[@]}")" || return "$?"
  fi
  pre_existing="$(attach_deferred_leaves "$root" "$payload" "$surfaces")" || return "$?"
  surfaces="$(attach_surfaces_without_deferred "$surfaces" "$pre_existing")" || return "$TRELLIS_EX_STATE"
  attach_destination_preflight "$root" "$surfaces" || return "$?"
  attach_exclude_effective_preflight "$root" "$surfaces" || return "$?"
  if attach_contextual_render_required "$surfaces"; then
    render_context="$(attach_contextual_render_context "$home")" || return "$?"
  fi
  harnesses_json="$(printf '%s\n' "$surfaces" | jq -c '.harnesses')" || return "$TRELLIS_EX_STATE"
  attachment_id="$(attach_uuid)" || return "$?"
  if [ -n "$expected_binding" ]; then
    attach_expected_binding_matches_selection "$expected_binding" "$fleet" "$project_id" "$root" \
      "$identity" "$attachment_id" "$release" "$harnesses_json" true || return "$?"
    attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" "$expected_donor_binding" || return "$?"
  fi
  exclude_before="$(mktemp "${TMPDIR:-/tmp}/trellis.exclude.before.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  exclude_after="$(mktemp "${TMPDIR:-/tmp}/trellis.exclude.after.XXXXXX")" || { rm -f "$exclude_before"; return "$TRELLIS_EX_UNAVAILABLE"; }
  exclude="$(attach_exclude_preflight "$home" "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" "$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" "$exclude_before" "$exclude_after" "$surfaces")" || { rc=$?; rm -f "$exclude_before" "$exclude_after"; return "$rc"; }
  plan="$(mktemp "${TMPDIR:-/tmp}/trellis.attach.plan.XXXXXX")" || { rm -f "$exclude_before" "$exclude_after"; return "$TRELLIS_EX_UNAVAILABLE"; }
  attach_plan_from_surfaces "$home" "$root" "$fleet" "$project_id" "$identity" "$release" "$attachment_id" "$payload" "$surfaces" "$exclude" "$render_context" "$pre_existing" > "$plan" || { rc=$?; rm -f "$plan" "$exclude_before" "$exclude_after"; return "$rc"; }
  chmod 600 "$plan" || { rm -f "$plan" "$exclude_before" "$exclude_after"; return "$TRELLIS_EX_UNAVAILABLE"; }
  journal="$(_attachment_journal_path "$home" "$attachment_id")"
  identity="$(attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino")" || { rc=$?; rm -f "$plan" "$exclude_before" "$exclude_after"; return "$rc"; }
  if [ -n "$expected_donor_binding" ]; then
    attach_expected_donor_verify_artifacts "$home" "$expected_donor_binding" || { rc=$?; rm -f "$plan" "$exclude_before" "$exclude_after"; return "$rc"; }
  fi
  attachment_prepare "$home" "$plan" "$journal" || { rc=$?; rm -f "$plan" "$exclude_before" "$exclude_after"; return "$rc"; }
  attach_register "$home" "$fleet" "$project_id" "$root" "$release" "$harnesses_json" "$attachment_id" >/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    attachment_rollback "$home" "$journal"
    rollback_rc=$?
    registry_rc=0
    attach_detach_restore_registry "$home" "$(cat "$plan")" || registry_rc=$?
    rm -f "$plan" "$exclude_before" "$exclude_after"
    [ "$rollback_rc" -eq 0 ] || return "$rollback_rc"
    [ "$registry_rc" -eq 0 ] || return "$registry_rc"
    return "$rc"
  fi
  if [ "$(printf '%s\n' "$exclude" | jq -r '.managed_by_attachment')" = true ]; then
    attach_exclude_publish "$exclude"
  else
    attach_exclude_verify_state "$exclude"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    attachment_rollback "$home" "$journal"
    rollback_rc=$?
    if [ "$(printf '%s\n' "$exclude" | jq -r '.managed_by_attachment')" = true ]; then
      attach_exclude_recover "$exclude" >/dev/null 2>&1 || true
    fi
    registry_rc=0
    attach_detach_restore_registry "$home" "$(cat "$plan")" || registry_rc=$?
    rm -f "$plan" "$exclude_before" "$exclude_after"
    [ "$rollback_rc" -eq 0 ] || return "$rollback_rc"
    [ "$registry_rc" -eq 0 ] || return "$registry_rc"
    return "$rc"
  fi
  if [ "${ATTACHMENT_FAULT_PHASE:-}" = prepared ]; then
    rm -f "$plan" "$exclude_before" "$exclude_after"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  attachment_commit "$home" "$journal"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Owner publication commits the attachment even if final journal cleanup was interrupted.
    # Only an owner-absent rollback may restore the pre-attachment exclude bytes.
    if ! owner="$(attach_existing_owner "$home" "$identity")"; then
      if [ "$(printf '%s\n' "$exclude" | jq -r '.managed_by_attachment')" = true ]; then
        attach_exclude_recover "$exclude" >/dev/null 2>&1 || true
      fi
      registry_rc=0
      attach_detach_restore_registry "$home" "$(cat "$plan")" || registry_rc=$?
    fi
    rm -f "$plan" "$exclude_before" "$exclude_after"
    [ "${registry_rc:-0}" -eq 0 ] || return "$registry_rc"
    return "$rc"
  fi
  owner="$(attach_existing_owner "$home" "$identity")" || { rm -f "$plan" "$exclude_before" "$exclude_after"; return "$TRELLIS_EX_STATE"; }
  attach_hooks_install "$home" "$owner" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$plan" "$exclude_before" "$exclude_after"
    return "$rc"
  fi
  rm -f "$plan" "$exclude_before" "$exclude_after"
  printf 'attached: %s\n' "$root"
)

attach_cmd_recover() (
  local home_opt="" root_opt="" home root identity locked_identity locked_root_dev_ino locked_common_dev_ino checkout common journal journal_record status exclude rc registry_rc owner project_id
  local expected_binding="" expected_fleet="" expected_project_id="" expected_root="" expected_checkout_id="" expected_worktree_id="" expected_attachment_id="" expected_release="" expected_harnesses_json=""
  local expected_journal_sha256="" expected_journal_sha_seen=0
  local expected_binding_requested=0 expected_fleet_seen=0 expected_project_seen=0 expected_root_seen=0 expected_checkout_seen=0 expected_worktree_seen=0 expected_attachment_seen=0 expected_release_seen=0 expected_harnesses_seen=0
  local journal_dir="" candidate canonical attachment matches=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || { attach_usage_error '--home requires PATH'; return $?; }; home_opt="$2"; shift 2 ;;
      --expected-fleet) [ "$#" -ge 2 ] || { attach_usage_error '--expected-fleet requires NAME'; return $?; }; expected_fleet="$2"; expected_fleet_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-project-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-project-id requires ID'; return $?; }; expected_project_id="$2"; expected_project_seen=1; shift 2 ;;
      --expected-root) [ "$#" -ge 2 ] || { attach_usage_error '--expected-root requires PATH'; return $?; }; expected_root="$2"; expected_root_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-checkout-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-checkout-id requires ID'; return $?; }; expected_checkout_id="$2"; expected_checkout_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-worktree-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-worktree-id requires ID'; return $?; }; expected_worktree_id="$2"; expected_worktree_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-attachment-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-attachment-id requires ID'; return $?; }; expected_attachment_id="$2"; expected_attachment_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-release) [ "$#" -ge 2 ] || { attach_usage_error '--expected-release requires VERSION'; return $?; }; expected_release="$2"; expected_release_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-harnesses-json) [ "$#" -ge 2 ] || { attach_usage_error '--expected-harnesses-json requires JSON'; return $?; }; expected_harnesses_json="$2"; expected_harnesses_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-journal-sha256) [ "$#" -ge 2 ] || { attach_usage_error '--expected-journal-sha256 requires SHA256'; return $?; }; expected_journal_sha256="$2"; expected_journal_sha_seen=1; shift 2 ;;
      -h|--help) attach_usage; return 0 ;;
      -*) attach_usage_error "unknown recover option: $1"; return $? ;;
      *) [ -z "$root_opt" ] || { attach_usage_error 'recover accepts one PATH'; return $?; }; root_opt="$1"; shift ;;
    esac
  done
  [ "$#" -eq 0 ] || { attach_usage_error "unexpected argument: $1"; return $?; }
  [ -n "$root_opt" ] || { attach_usage_error 'recover requires PATH'; return $?; }
  if [ "$expected_journal_sha_seen" -eq 1 ]; then
    attach_expected_sha256_valid "$expected_journal_sha256" || {
      attach_usage_error 'expected journal SHA-256 must be 64 lowercase hexadecimal characters'
      return "$TRELLIS_EX_USAGE"
    }
  fi
  home="$(trellis_home_resolve "$home_opt")" || return "$?"
  trellis_home_prepare_home "$home" || return "$?"
  root="$(attach_canonical_root "$root_opt")" || return "$?"
  if [ "$expected_binding_requested" -eq 1 ]; then
    if [ "$expected_fleet_seen" -ne 1 ] || [ "$expected_project_seen" -ne 1 ] ||
       [ "$expected_root_seen" -ne 1 ] || [ "$expected_checkout_seen" -ne 1 ] ||
       [ "$expected_worktree_seen" -ne 1 ] || [ "$expected_attachment_seen" -ne 1 ] ||
       [ "$expected_release_seen" -ne 1 ] || [ "$expected_harnesses_seen" -ne 1 ]; then
      attach_usage_error 'expected repair binding requires fleet, project, root, checkout, worktree, attachment, release, and harnesses'
      return "$TRELLIS_EX_USAGE"
    fi
    expected_binding="$(attach_expected_binding_build "$expected_fleet" "$expected_project_id" "$expected_root" \
      "$expected_checkout_id" "$expected_worktree_id" "$expected_attachment_id" \
      "$expected_release" "$expected_harnesses_json")" || return "$?"
  fi
  identity="$(local_registry_identity_for_root "$root")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  locked_identity="$identity"
  locked_root_dev_ino="$(attach_relink_directory_identity "$root")" || return "$?"
  locked_common_dev_ino="$(attach_relink_directory_identity "$common")" || return "$?"
  attachment_checkout_lock_reclaim "$home" "$checkout" "$common" || return "$?"
  attachment_checkout_lock_acquire "$home" "$checkout" "$common" || return "$?"
  _attachment_install_checkout_lock_traps
  if [ -n "${ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK:-}" ]; then sleep "$ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK"; fi
  identity="$(attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" || return "$?"
  journal_dir="$home/state/attachment-journals"
  [ -d "$journal_dir" ] && [ ! -L "$journal_dir" ] || {
    attach_err "attachment journal directory is unavailable or unsafe: $journal_dir"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  for candidate in "$journal_dir"/*.json; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || {
      attach_err "attachment journal entry is unsafe: $candidate"
      return "$TRELLIS_EX_STATE"
    }
    status="$(jq -r '.status // empty' "$candidate" 2>/dev/null)" || {
      attach_err "attachment journal is invalid: $candidate"
      return "$TRELLIS_EX_STATE"
    }
    attachment="$(jq -r '.attachment_id // empty' "$candidate" 2>/dev/null)" || {
      attach_err "attachment journal has no valid attachment ID: $candidate"
      return "$TRELLIS_EX_STATE"
    }
    case "$status" in
      prepared)
        _attachment_journal_json_valid "$candidate" || {
          attach_err "attachment journal is invalid: $candidate"
          return "$TRELLIS_EX_STATE"
        }
        canonical="$(_attachment_journal_path "$home" "$attachment")"
        if ! jq -e --arg checkout "$checkout" --arg worktree "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" --arg root "$root" '
          .checkout_id == $checkout and .worktree_id == $worktree and .worktree_root == $root
        ' "$candidate" >/dev/null 2>&1; then
          continue
        fi
        ;;
      detaching)
        _attachment_detach_journal_valid "$candidate" || {
          attach_err "attachment journal is invalid: $candidate"
          return "$TRELLIS_EX_STATE"
        }
        canonical="$(_attachment_detach_journal_path "$home" "$attachment")"
        if ! jq -e --arg checkout "$checkout" --arg worktree "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" --arg root "$root" '
          .original_owner.checkout_id == $checkout and .original_owner.worktree_id == $worktree
          and .original_owner.worktree_root == $root
        ' "$candidate" >/dev/null 2>&1; then
          continue
        fi
        ;;
      *) continue ;;
    esac
    if [ "$candidate" != "$canonical" ]; then
      attach_err "attachment journal is not at its canonical path: $candidate"
      return "$TRELLIS_EX_CONFLICT"
    fi
    if [ -n "$matches" ]; then
      matches="$matches
$candidate"
    else
      matches="$candidate"
    fi
  done
  journal="$matches"
  [ -n "$journal" ] || { attach_err "no matching attachment journal for $root"; return "$TRELLIS_EX_UNAVAILABLE"; }
  [ "$(printf '%s\n' "$journal" | wc -l | tr -d ' ')" -eq 1 ] || { attach_err "multiple matching attachment journals for $root"; return "$TRELLIS_EX_STATE"; }
  status="$(jq -r '.status' "$journal")" || return "$TRELLIS_EX_STATE"
  attach_expected_binding_journal_matches "$journal" "$expected_binding" || return "$?"
  attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" || return "$?"
  if [ "$status" = detaching ]; then
    identity="$(attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino")" || return "$?"
    attach_expected_journal_state_matches "$journal" "$expected_journal_sha256" || return "$?"
    attachment_detach_recover "$home" "$journal" || return "$?"
    attach_detach_finish_journal "$home" "$journal"
    return "$?"
  fi
  [ "$status" = prepared ] || return "$TRELLIS_EX_STATE"
  exclude="$(jq -c '.exclude' "$journal")" || return "$TRELLIS_EX_STATE"
  journal_record="$(jq -c . "$journal")" || return "$TRELLIS_EX_STATE"
  owner="$(_attachment_ownership_path "$home" "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" "$(printf '%s\n' "$identity" | jq -r '.worktree_id')")"
  if [ -f "$owner" ] && [ ! -L "$owner" ]; then
    attach_expected_binding_owner_matches "$owner" "$expected_binding" || return "$?"
    attach_verify_owner_artifacts "$home" "$owner" || return "$?"
    attach_exclude_verify_state "$exclude" || return "$?"
    project_id="$(local_registry_manifest_project_id "$root/.trellis.json")" || return "$?"
    attach_expected_binding_matches_selection "$expected_binding" "$(jq -r '.fleet' "$owner")" "$project_id" "$root" \
      "$identity" "$(jq -r '.attachment_id' "$owner")" "$(jq -r '.release' "$owner")" "$(attach_harnesses_from_owner "$owner")" || return "$?"
    attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" || return "$?"
    attach_expected_binding_journal_matches "$journal" "$expected_binding" || return "$?"
    attach_expected_binding_owner_matches "$owner" "$expected_binding" || return "$?"
    attach_expected_journal_state_matches "$journal" "$expected_journal_sha256" || return "$?"
    attach_hooks_install "$home" "$owner" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" || return "$?"
    attach_register "$home" "$(jq -r '.fleet' "$owner")" "$project_id" "$root" "$(jq -r '.release' "$owner")" "$(attach_harnesses_from_owner "$owner")" "$(jq -r '.attachment_id' "$owner")" >/dev/null || return "$?"
    attach_expected_journal_state_matches "$journal" "$expected_journal_sha256" || return "$?"
    attachment_recover "$home" "$journal" || return "$?"
    attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" >/dev/null
    return "$?"
  fi
  identity="$(attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino")" || return "$?"
  attach_expected_journal_state_matches "$journal" "$expected_journal_sha256" || return "$?"
  attachment_recover "$home" "$journal"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$(printf '%s\n' "$exclude" | jq -r '.managed_by_attachment')" = true ]; then
      attach_exclude_recover "$exclude" || rc=$?
    fi
    registry_rc=0
    attach_detach_restore_registry "$home" "$journal_record" || registry_rc=$?
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" >/dev/null || return "$?"
  return "$registry_rc"
)
attach_cmd_relink() (
  local home_opt="" fleet_opt="" root_opt="" home root identity locked_identity locked_root_dev_ino locked_common_dev_ino checkout common owner release payload expected anchor_plan root_identity trellis_identity expected_old exclude verify_rc project_id owner_harnesses
  local expected_binding="" expected_fleet="" expected_project_id="" expected_root="" expected_checkout_id="" expected_worktree_id="" expected_attachment_id="" expected_release="" expected_harnesses_json=""
  local expected_owner_sha256="" expected_owner_parent_dev_ino=""
  local expected_owner_sha_seen=0 expected_owner_parent_seen=0
  local expected_binding_requested=0 expected_fleet_seen=0 expected_project_seen=0 expected_root_seen=0 expected_checkout_seen=0 expected_worktree_seen=0 expected_attachment_seen=0 expected_release_seen=0 expected_harnesses_seen=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || { attach_usage_error '--home requires PATH'; return $?; }; home_opt="$2"; shift 2 ;;
      --fleet) [ "$#" -ge 2 ] || { attach_usage_error '--fleet requires NAME'; return $?; }; fleet_opt="$2"; shift 2 ;;
      --expected-fleet) [ "$#" -ge 2 ] || { attach_usage_error '--expected-fleet requires NAME'; return $?; }; expected_fleet="$2"; expected_fleet_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-project-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-project-id requires ID'; return $?; }; expected_project_id="$2"; expected_project_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-root) [ "$#" -ge 2 ] || { attach_usage_error '--expected-root requires PATH'; return $?; }; expected_root="$2"; expected_root_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-checkout-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-checkout-id requires ID'; return $?; }; expected_checkout_id="$2"; expected_checkout_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-worktree-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-worktree-id requires ID'; return $?; }; expected_worktree_id="$2"; expected_worktree_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-attachment-id) [ "$#" -ge 2 ] || { attach_usage_error '--expected-attachment-id requires ID'; return $?; }; expected_attachment_id="$2"; expected_attachment_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-release) [ "$#" -ge 2 ] || { attach_usage_error '--expected-release requires VERSION'; return $?; }; expected_release="$2"; expected_release_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-harnesses-json) [ "$#" -ge 2 ] || { attach_usage_error '--expected-harnesses-json requires JSON'; return $?; }; expected_harnesses_json="$2"; expected_harnesses_seen=1; expected_binding_requested=1; shift 2 ;;
      --expected-owner-sha256) [ "$#" -ge 2 ] || { attach_usage_error '--expected-owner-sha256 requires SHA256'; return $?; }; expected_owner_sha256="$2"; expected_owner_sha_seen=1; shift 2 ;;
      --expected-owner-parent-dev-ino) [ "$#" -ge 2 ] || { attach_usage_error '--expected-owner-parent-dev-ino requires DEV:INO'; return $?; }; expected_owner_parent_dev_ino="$2"; expected_owner_parent_seen=1; shift 2 ;;
      -h|--help) attach_usage; return 0 ;;
      -*) attach_usage_error "unknown relink option: $1"; return $? ;;
      *) [ -z "$root_opt" ] || { attach_usage_error 'relink accepts one PATH'; return $?; }; root_opt="$1"; shift ;;
    esac
  done
  [ -n "$root_opt" ] || { attach_usage_error 'relink requires PATH'; return $?; }
  if [ "$expected_owner_sha_seen" -ne "$expected_owner_parent_seen" ]; then
    attach_usage_error 'expected owner repair state requires both owner SHA-256 and ownership parent DEV:INO'
    return "$TRELLIS_EX_USAGE"
  fi
  if [ "$expected_owner_sha_seen" -eq 1 ]; then
    attach_expected_sha256_valid "$expected_owner_sha256" || {
      attach_usage_error 'expected owner SHA-256 must be 64 lowercase hexadecimal characters'
      return "$TRELLIS_EX_USAGE"
    }
    attach_expected_directory_identity_valid "$expected_owner_parent_dev_ino" || {
      attach_usage_error 'expected ownership parent DEV:INO is invalid'
      return "$TRELLIS_EX_USAGE"
    }
  fi
  home="$(trellis_home_resolve "$home_opt")" || return "$?"
  root="$(attach_canonical_root "$root_opt")" || return "$?"
  if [ "$expected_binding_requested" -eq 1 ]; then
    if [ "$expected_fleet_seen" -ne 1 ] || [ "$expected_project_seen" -ne 1 ] ||
       [ "$expected_root_seen" -ne 1 ] || [ "$expected_checkout_seen" -ne 1 ] ||
       [ "$expected_worktree_seen" -ne 1 ] || [ "$expected_attachment_seen" -ne 1 ] ||
       [ "$expected_release_seen" -ne 1 ] || [ "$expected_harnesses_seen" -ne 1 ]; then
      attach_usage_error 'expected repair binding requires fleet, project, root, checkout, worktree, attachment, release, and harnesses'
      return "$TRELLIS_EX_USAGE"
    fi
    expected_binding="$(attach_expected_binding_build "$expected_fleet" "$expected_project_id" "$expected_root" \
      "$expected_checkout_id" "$expected_worktree_id" "$expected_attachment_id" \
      "$expected_release" "$expected_harnesses_json")" || return "$?"
  fi
  identity="$(local_registry_identity_for_root "$root")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  locked_identity="$identity"
  locked_root_dev_ino="$(attach_relink_directory_identity "$root")" || return "$?"
  locked_common_dev_ino="$(attach_relink_directory_identity "$common")" || return "$?"
  attachment_checkout_lock_reclaim "$home" "$checkout" "$common" || return "$?"
  attachment_checkout_lock_acquire "$home" "$checkout" "$common" || return "$?"
  _attachment_install_checkout_lock_traps
  if [ -n "${ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK:-}" ]; then sleep "$ATTACHMENT_TEST_HOLD_CHECKOUT_LOCK"; fi
  identity="$(attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')" || return "$TRELLIS_EX_STATE"
  attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" || return "$?"
  owner="$(attach_existing_owner "$home" "$identity")" || return "$?"
  attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
  attach_expected_binding_owner_matches "$owner" "$expected_binding" || return "$?"
  release="$(jq -r '.release' "$owner")" || return "$TRELLIS_EX_STATE"
  project_id="$(local_registry_manifest_project_id "$root/.trellis.json")" || return "$?"
  owner_harnesses="$(attach_harnesses_from_owner "$owner")" || return "$TRELLIS_EX_STATE"
  attach_expected_binding_matches_selection "$expected_binding" "$(jq -r '.fleet' "$owner")" "$project_id" "$root" \
    "$identity" "$(jq -r '.attachment_id' "$owner")" "$release" "$owner_harnesses" || return "$?"
  payload="$(TRELLIS_HOME="$home" release_store_locate "$release")" || return "$?"
  expected="$(CDPATH='' cd "$payload/payload" && pwd -P)" || return "$TRELLIS_EX_STATE"
  anchor_plan="$(attach_relink_runtime_anchor_plan "$root" "$expected")" || return "$?"
  root_identity="$(printf '%s\n' "$anchor_plan" | jq -r '.root_identity')" || return "$TRELLIS_EX_STATE"
  trellis_identity="$(printf '%s\n' "$anchor_plan" | jq -r '.trellis_identity')" || return "$TRELLIS_EX_STATE"
  expected_old="$(printf '%s\n' "$anchor_plan" | jq -r '.expected_old')" || return "$TRELLIS_EX_STATE"
  attach_verify_owner_artifacts "$home" "$owner"
  verify_rc=$?
  if [ "$verify_rc" -ne 0 ]; then
    [ "$verify_rc" -eq "$TRELLIS_EX_CONFLICT" ] || return "$verify_rc"
    [ ! -e "$root/.trellis/runtime" ] && [ ! -L "$root/.trellis/runtime" ] || {
      attach_err "owned attachment artifacts are modified"
      return "$TRELLIS_EX_CONFLICT"
    }
    while IFS= read -r artifact; do
      [ -n "$artifact" ] || continue
      _attachment_artifact_exact "$root" "$artifact" || {
        attach_err "owned attachment artifacts are modified"
        return "$TRELLIS_EX_CONFLICT"
      }
    done < <(jq -c '.artifacts[] | select(.path != ".trellis/runtime")' "$owner")
  fi
  [ -z "$fleet_opt" ] || [ "$fleet_opt" = "$(jq -r '.fleet' "$owner")" ] || { attach_err 'requested fleet differs from recorded attachment'; return "$TRELLIS_EX_STATE"; }
  exclude="$(jq -c '.exclude' "$owner")" || return "$TRELLIS_EX_STATE"
  attach_exclude_verify_state "$exclude" || return "$?"
  project_id="$(local_registry_manifest_project_id "$root/.trellis.json")" || return "$?"
  attach_expected_binding_verify "$home" "$root" "$identity" "$expected_binding" || return "$?"
  attach_expected_binding_owner_matches "$owner" "$expected_binding" || return "$?"
  attach_expected_binding_matches_selection "$expected_binding" "$(jq -r '.fleet' "$owner")" "$project_id" "$root" \
    "$identity" "$(jq -r '.attachment_id' "$owner")" "$release" "$owner_harnesses" || return "$?"
  attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" >/dev/null || return "$?"
  attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
  TRELLIS_HOME="$home" release_store_adopt_runtime_anchor_pinned \
    "$release" "$root" "$root_identity" "$trellis_identity" "$expected_old" >/dev/null || return "$?"
  attach_expected_owner_state_matches "$owner" "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
  attach_hooks_install "$home" "$owner" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" \
    "$expected_owner_sha256" "$expected_owner_parent_dev_ino" || return "$?"
  attachment_verify "$home" "$owner" || return "$?"
  attach_locked_checkout_namespace_matches "$root" "$locked_identity" "$locked_root_dev_ino" "$locked_common_dev_ino" >/dev/null || return "$?"
  printf 'relinked: %s\n' "$root"
)
main() {
  local command="${1:-}"
  case "$command" in
    attach) shift; attach_cmd_attach "$@" ;;
    detach) shift; attach_cmd_detach "$@" ;;
    relink) shift; attach_cmd_relink "$@" ;;
    recover) shift; attach_cmd_recover "$@" ;;
    -h|--help|help|'') attach_usage ;;
    *) attach_usage_error "unknown command: $command" ;;
  esac
}

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
