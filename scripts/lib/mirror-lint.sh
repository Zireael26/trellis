#!/usr/bin/env bash
# Pure, sourceable lint for the public Trellis mirror.
#
# The mirror must contain portable policy and tools only. It must never contain
# private TRELLIS_HOME state or an operator's absolute home path. All traversal
# is lexical or `find -P` over regular files, so neither validation nor content
# scans dereference a hostile mirror link. Unknown operator paths fail closed
# on their own bytes.

# lint_mirror MIRROR_DIR
#   Prints "relative-path: reason" per offender to stdout.
#   Returns 0 when clean, 1 for policy violations, 2 for bad arguments.

# mirror_find_path_escape LITERAL_PATH
#   Escapes a literal path for use inside a `find -path` pattern. `-path`
#   matches with shell-glob semantics, so an unescaped `*`, `?`, `[`, `]` or
#   `\` anywhere in the mirror's own absolute path is read as pattern syntax
#   instead of as itself. That fails open, not closed: the whole structural
#   scan silently matches nothing and a dirty mirror lints clean. Escape the
#   root once and interpolate the escaped form into every `-path` term.
mirror_find_path_escape() {
  local out="${1:-}"
  out="${out//\\/\\\\}"
  out="${out//\*/\\*}"
  out="${out//\?/\\?}"
  out="${out//\[/\\[}"
  out="${out//\]/\\]}"
  printf '%s' "$out"
}

# mirror_link_target_is_contained RELATIVE_LINK_PATH TARGET
#   Validates a relative symlink target by lexical resolution. It never follows
#   the link, so a hostile mirror cannot turn validation into filesystem access.
mirror_link_target_is_contained() {
  local rel="${1:-}" target="${2:-}" parent rest component resolved=""
  [ "$#" -eq 2 ] || return 1
  case "$rel" in
    ''|/*|*'//'|*'/./'*|*'/../'*|*/.|*/..|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$target" in
    ''|/*|*'//'|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$rel" in
    */*) parent="${rel%/*}" ;;
    *) parent="" ;;
  esac
  if [ -n "$parent" ]; then rest="$parent/$target"; else rest="$target"; fi
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
      *) component="$rest"; rest="" ;;
    esac
    case "$component" in
      ''|.) ;;
      ..)
        [ -n "$resolved" ] || return 1
        case "$resolved" in */*) resolved="${resolved%/*}" ;; *) resolved="" ;; esac
        ;;
      *)
        case "$component" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
        if [ -n "$resolved" ]; then resolved="$resolved/$component"; else resolved="$component"; fi
        ;;
    esac
  done
  [ -n "$resolved" ]
}

# mirror_validate_symlinks MIRROR_DIR
#   Rejects absolute or relative links that escape the mirror. Safe relative
#   links may remain as leaf artifacts, but callers must never use a link as a
#   destination parent for a mutation.
mirror_validate_symlinks() {
  local mirror_dir="${1:-}" mirror_pat link rel target rc=0
  [ "$#" -eq 1 ] || return 2
  [ -d "$mirror_dir" ] && [ ! -L "$mirror_dir" ] || return 2
  mirror_pat="$(mirror_find_path_escape "$mirror_dir")"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    rel="${link#"$mirror_dir"/}"
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
      /*)
        printf '%s: symlink target leaks absolute path\n' "$rel"
        rc=1
        ;;
      *)
        if ! mirror_link_target_is_contained "$rel" "$target"; then
          printf '%s: symlink target escapes mirror\n' "$rel"
          rc=1
        fi
        ;;
    esac
  done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -type l -print 2>/dev/null)
  return "$rc"
}

# mirror_fleet_identity_tokens
#   Prints the lowercased project identifiers of the local fleet, one per line.
#
# The token set is READ FROM PRIVATE LOCAL STATE, never hardcoded. A hardcoded
# list would publish, inside this very file, the names it exists to suppress —
# and would go stale the moment a project is onboarded, which is precisely how
# a leak returns after being cleaned once. Reading the machine-local registry
# means the guard covers every project the operator has now and every one they
# add later, with nothing to remember.
#
# Fails (non-zero) when the source is unreadable so the caller can refuse to
# certify rather than certify blind.
mirror_fleet_identity_tokens() {
  local source="${TRELLIS_MIRROR_IDENTITY_SOURCE:-${TRELLIS_HOME:-$HOME/.trellis}/registry.json}"
  local public_tokens private_tokens
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  public_tokens="$(mirror_fleet_public_identity_tokens "$source")" || return 1
  private_tokens="$(mirror_fleet_private_identity_tokens "$source")" || return 1
  # An exemption is safe only if no private row normalizes to the same token.
  if [ -n "$public_tokens" ] && [ -n "$private_tokens" ]; then
    public_tokens="$(printf '%s\n' "$public_tokens" | grep -vxF -- "$private_tokens" || [ "$?" -eq 1 ])" || return 1
  fi
  # Deliberately parsed with grep/sed rather than jq. `trellis mirror` re-execs
  # through `env -i` with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a jq-dependent
  # guard resolves "unreadable" on every real publish — it would fail closed
  # forever and be ripped out as broken, which is worse than no guard. The
  # fields read here are flat string values written by this repo's own
  # local-registry writer, so a full JSON parser buys nothing.
  {
    grep -oE '"project_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$source" 2>/dev/null
    grep -oE '"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"[[:space:]]*:[[:space:]]*\{' "$source" 2>/dev/null
  } |
    sed -E 's/.*"([^"]*)"[[:space:]]*:?[[:space:]]*\{?$/\1/; s#.*/##' |
    /usr/bin/env LC_ALL=C tr '[:upper:]' '[:lower:]' |
    sed -E 's/\.(com|org|net|money|live|dev|in|ai|site)$//' |
    grep -vE '^.{0,2}$' |
    sort -u |
    { if [ -n "$public_tokens" ]; then grep -vxF -- "$public_tokens" || [ "$?" -eq 1 ]; else cat; fi; }
}

# mirror_fleet_public_identity_tokens SOURCE
#   Prints the normalized identifiers of projects the operator has declared
#   already public, one per line, for subtraction from the guard's token set.
#
# Some project identifiers ARE public by construction: a personal site's own
# domain is the thing it publishes under, and it legitimately appears in this
# repository's README as a link and a maintainer byline. Without this list the
# guard reports that byline as a fleet-identity leak and the mirror can never
# be certified, which ends one of two ways — the byline gets deleted, or the
# check gets deleted. Neither is the right answer, so the distinction is made
# explicit and operator-owned instead.
#
# The declaration lives in machine-local registry metadata, set with
# `trellis registry annotate --metadata-json '{"public_identity": true}'`, for
# the same reason the token set itself is read rather than hardcoded: an
# allowlist written into this file would publish, in the mirror, a list of the
# operator's projects. Default is closed — a row says nothing, it is private.
#
# Parsed by indentation rather than by brace depth. `metadata.legacy` notes
# carry literal braces inside JSON strings, so a depth counter that cannot see
# string boundaries miscounts on real rows; the writer emits `jq -S` output at a
# fixed two-space indent, which those strings cannot forge. A source whose shape
# does not match yields no public tokens, so a formatting change fails toward
# flagging more rather than fewer.
#
# The short-token filter is `sed -E '/^.{0,2}$/d'`, not `grep -vE`. Having no
# annotated rows at all is the ordinary case, and `grep` exits 1 on empty input.
# `sync-to-template.sh` runs under `set -o pipefail`, so that 1 propagates out
# of the pipeline, the caller reads it as `return 1`, and the guard announces
# "fleet identity source unreadable" for a registry it read perfectly well —
# turning the common case into a hard publication failure. `sed` deletes the
# same lines and exits 0 whether or not it matched.
mirror_fleet_public_identity_tokens() {
  mirror_fleet_identity_tokens_by_visibility "$1" public
}

mirror_fleet_private_identity_tokens() {
  mirror_fleet_identity_tokens_by_visibility "$1" private
}

mirror_fleet_identity_tokens_by_visibility() {
  local source="${1:-}" visibility="${2:-}"
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  awk -v visibility="$visibility" '
    /^    "[^"]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ { inproj = 1; pid = ""; pub = 0; next }
    inproj && /^        "public_identity"[[:space:]]*:[[:space:]]*true/ { pub = 1; next }
    inproj && /^      "project_id"[[:space:]]*:[[:space:]]*"/ {
      pid = $0
      sub(/^[^:]*:[[:space:]]*"/, "", pid)
      sub(/".*$/, "", pid)
      next
    }
    inproj && /^    \}/ {
      if (pid != "" && ((visibility == "public" && pub) || (visibility == "private" && !pub))) print pid
      inproj = 0; pid = ""; pub = 0; next
    }
  ' "$source" 2>/dev/null |
    /usr/bin/env LC_ALL=C tr '[:upper:]' '[:lower:]' |
    sed -E 's#.*/##; s/\.(com|org|net|money|live|dev|in|ai|site)$//' |
    sed -E '/^.{0,2}$/d' |
    sort -u
}

# A binary exception is admitted only by the separately supplied payload, never
# by a manifest the mirror can forge. Snapshot the exact verified bytes into a
# printable-text projection; every other path keeps the ordinary full scan.
mirror_prepare_native_scan() {
  local mirror_dir="$1" payload="$2" scan_dir="$3"
  python3 -I - "$mirror_dir" "$payload" "$scan_dir" <<'PY'
import hashlib, json, os, re, stat, subprocess, sys
from pathlib import Path

mirror, payload, output = map(Path, sys.argv[1:])
targets = {'aarch64-apple-darwin', 'x86_64-unknown-linux-musl', 'aarch64-unknown-linux-musl'}
def require(ok, message):
    if not ok:
        raise ValueError(message)
def closed(obj, keys):
    require(type(obj) is dict and set(obj) == set(keys.split()), 'invalid manifest fields')
def digest(b):
    return hashlib.sha256(b).hexdigest()
def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'duplicate manifest key')
        result[key] = value
    return result
def read_file(root, relative):
    # Walk from the supplied root without following any native-set component.
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parts = relative.split('/')
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
        before = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        require(stat.S_ISREG(before.st_mode), 'non-regular native file')
        child = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            opened = os.fstat(child)
            require((before.st_dev, before.st_ino) == (opened.st_dev, opened.st_ino), 'native file changed')
            chunks = []
            while True:
                chunk = os.read(child, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            after = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
            final = os.fstat(child)
            ident = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            require(ident(before) == ident(after) == ident(final), 'native file changed during read')
            return b''.join(chunks), opened.st_mode
        finally:
            os.close(child)
    finally:
        os.close(fd)
def inventory(root):
    result = set()
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            p = Path(current) / name
            mode = p.lstat().st_mode
            require(not stat.S_ISLNK(mode) and (stat.S_ISDIR(mode) or stat.S_ISREG(mode)), 'linked or special native entry')
            result.add(p.relative_to(root).as_posix())
    return result
try:
    require(payload.is_absolute() and payload.is_dir(), 'trusted payload unavailable')
    base = mirror / 'core-rules/native'
    trusted = payload / 'core-rules/native'
    require(not base.is_symlink() and base.is_dir() and not trusted.is_symlink() and trusted.is_dir(), 'native root unavailable')
    manifest, _ = read_file(base, 'artifacts.json')
    trusted_manifest, _ = read_file(trusted, 'artifacts.json')
    require(manifest == trusted_manifest, 'native manifest differs from trusted payload')
    d = json.loads(manifest.decode('utf-8'), object_pairs_hook=pairs)
    closed(d, 'schema_version version source_commit generation inputs toolchain install_path adapter assets')
    # The expected version is the trusted payload's core-rules/VERSION, never a pin here.
    version, _ = read_file(payload, 'core-rules/VERSION')
    version = version.decode('ascii', errors='replace')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\n', version) is not None, 'trusted payload VERSION is not one version line')
    require(type(d['schema_version']) is int and d['schema_version'] == 1 and d['version'] == version[:-1], 'invalid native version')
    require(d['install_path'] == 'bin/native/{version}/{target}/{sha256}/trellis-hooks', 'invalid native install path')
    require(type(d['source_commit']) is str and re.fullmatch('[0-9a-f]{40}', d['source_commit']), 'invalid source provenance')
    require(type(d['inputs']) is dict and bool(d['inputs']), 'missing native inputs')
    for key, value in d['inputs'].items():
        # Literal include_str!/include_bytes! edges outside the crate are
        # recorded inputs too (build-native-hooks.sh); any safe relative path.
        require(type(key) is str and key and not key.startswith('/') and all(part not in ('', '.', '..') for part in key.split('/'))
                and not any(ord(c) < 32 for c in key), 'invalid native input')
        require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'invalid input digest')
    closed(d['toolchain'], 'channel rustc cargo_lock_sha256 rust_toolchain_sha256')
    tc = d['toolchain']
    require(tc['channel'] == '1.97.1' and tc['rustc'] == 'rustc 1.97.1 (8bab26f4f 2026-07-14)', 'invalid native toolchain')
    require(tc['cargo_lock_sha256'] == d['inputs'].get('native/trellis-hooks/Cargo.lock') and tc['rust_toolchain_sha256'] == d['inputs'].get('native/trellis-hooks/rust-toolchain.toml'), 'toolchain input mismatch')
    identity = {k: d[k] for k in ('version', 'inputs', 'toolchain')}
    require(d['generation'] == digest(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()), 'invalid native generation')
    require(type(d['assets']) is dict and bool(d['assets']) and set(d['assets']) <= targets, 'invalid native targets')
    closed(d['adapter'], 'path size sha256')
    require(d['adapter']['path'] == 'hook-adapter.sh', 'invalid adapter path')
    records = [(d['adapter'], None)]
    expected = {'artifacts.json', 'hook-adapter.sh'}
    for target, asset in d['assets'].items():
        closed(asset, 'path size sha256 format signature minimum_os')
        require(asset['path'] == target + '/trellis-hooks', 'invalid native asset path')
        darwin = target == 'aarch64-apple-darwin'
        require((asset['format'], asset['signature'], asset['minimum_os']) == (('mach-o', 'adhoc', '13.0') if darwin else ('elf-static', 'none', None)), 'invalid native metadata')
        expected.update((target, asset['path']))
        records.append((asset, target))
    require(inventory(base) == expected and inventory(trusted) == expected, 'missing or unlisted native file')
    for record, target in records:
        data, mode = read_file(base, record['path'])
        reference, _ = read_file(trusted, record['path'])
        require(type(record['size']) is int and record['size'] > 0 and len(data) == record['size'], 'native size mismatch')
        require(type(record['sha256']) is str and re.fullmatch('[0-9a-f]{64}', record['sha256']) and digest(data) == record['sha256'] and data == reference, 'native digest mismatch')
        if target is None:
            continue
        require(mode & 0o111, 'non-executable native asset')
        if target == 'aarch64-apple-darwin':
            require(data[:8] == b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01', 'invalid Mach-O target')
            if sys.platform == 'darwin':
                require(subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(base / record['path'])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0, 'invalid native signature')
        else:
            require(data[:6] == b'\x7fELF\x02\x01' and len(data) >= 64, 'invalid ELF')
            require(int.from_bytes(data[18:20], 'little') == (62 if target.startswith('x86_64') else 183), 'invalid ELF architecture')
            off = int.from_bytes(data[32:40], 'little'); width = int.from_bytes(data[54:56], 'little'); count = int.from_bytes(data[56:58], 'little')
            require(width == 56 and count > 0 and off + width * count <= len(data), 'invalid ELF program headers')
            require(all(int.from_bytes(data[off+i*width:off+i*width+4], 'little') != 3 for i in range(count)), 'dynamic ELF interpreter')
        projected = output / target / 'trellis-hooks'
        projected.parent.mkdir(parents=True)
        projected.write_bytes(b'\n'.join(re.findall(rb'[\x20-\x7e]+', data)) + b'\n')
except (OSError, ValueError, UnicodeError, KeyError, TypeError) as error:
    print('core-rules/native: native runtime verification failed: ' + str(error))
    raise SystemExit(1)
PY
}

# Search every ordinary file as text, except exact verified assets whose
# printable snapshots are searched instead. Unlisted and invalid files never
# acquire a binary exemption. Results retain the original mirror path.
# Every argument after OPTIONS is one pattern, passed to grep with -e.
mirror_lint_grep() {
  local root="$1" scan_dir="$2" options="$3" root_pat target line pattern
  local -a excludes=() patterns=()
  for pattern in "${@:4}"; do patterns+=( -e "$pattern" ); done
  root_pat="$(mirror_find_path_escape "$root")"
  if [ -n "$scan_dir" ]; then
    for target in aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
      [ -f "$scan_dir/$target/trellis-hooks" ] || continue
      excludes+=( ! -path "$root_pat/core-rules/native/$target/trellis-hooks" )
    done
  fi
  find -P "$root" -path "$root_pat/.git" -prune -o -type f "${excludes[@]+"${excludes[@]}"}" \
    -exec grep "$options" "${patterns[@]}" {} + 2>/dev/null
  if [ -n "$scan_dir" ]; then
    while IFS= read -r line; do
      printf '%s/core-rules/native/%s\n' "$root" "${line#"$scan_dir"/}"
    done < <(find -P "$scan_dir" -type f -exec grep "$options" "${patterns[@]}" {} + 2>/dev/null)
  fi
  return 0
}

lint_mirror() {
  local mirror_dir="${1:-}" mirror_pat rc=0 f rel hit path username scan_dir='' scan_file
  local identity_tokens identity_token identity_ere identity_pattern address
  [ "$#" -eq 1 ] || { printf 'mirror-lint: usage: lint_mirror MIRROR_DIR\n' >&2; return 2; }
  [ -d "$mirror_dir" ] && [ ! -L "$mirror_dir" ] || {
    printf 'mirror-lint: not an ordinary directory: %s\n' "$mirror_dir" >&2
    return 2
  }
  mirror_pat="$(mirror_find_path_escape "$mirror_dir")"
  if [ -e "$mirror_dir/core-rules/native" ] || [ -L "$mirror_dir/core-rules/native" ]; then
    scan_dir="$(mktemp -d "${TMPDIR:-/tmp}/trellis-native-scan.XXXXXX")" || return 2
    if ! mirror_prepare_native_scan "$mirror_dir" "${PAYLOAD_ROOT:-}" "$scan_dir"; then
      rc=1
      rm -rf "${scan_dir:?}"
      scan_dir=''
    fi
  fi

  # Local machine state is never a public template payload. Keep the list
  # structural rather than content-based: it catches a future sync allowlist
  # mistake before a path-redaction scheme has a chance to hide it.
  #
  # Every term is a top-level TRELLIS_HOME child, anchored at exactly one depth
  # (`$mirror_pat/NAME` plus `$mirror_pat/NAME/*`) so the group stays readable
  # as an inventory of private roots. A deeper or unanchored `-name` term would
  # be redundant with its own root and, being a glob rather than a path, could
  # not be paired with a `delist_prune` entry in `sync-to-template.sh`. That
  # pairing is a hard invariant: a path this lint rejects but the sync cannot
  # prune is a mirror that can never be published clean again.
  #
  # `tasks` and `locks` are distinct roots, not sub-cases of the ones above
  # them. `tasks` holds materialized task state — a local-registry snapshot and
  # private backlog — and is *not* covered by `scheduled-tasks`, which is the
  # repository's own source directory. `locks` is the TRELLIS_HOME lock root
  # and is not covered by `state`, which has its own separate `state/locks`.
  #
  # KNOWN GAP, deliberately not covered: TRELLIS_HOME also holds transient
  # atomic-write temporaries as *siblings* of the artifacts above —
  # `.config.json.tmp.XXXXXX` (scripts/lib/trellis-home.sh) and
  # `.registry.json.tmp.XXXXXX` (scripts/lib/local-registry.sh). Their names
  # end in an `mktemp` suffix, so no exact relative path can ever name them,
  # and `delist_prune` in `sync-to-template.sh` deletes exact literal paths
  # only — `mirror_remove_pruned_paths` builds `$root/$path` and never expands
  # a glob. Adding a reject term for them without first teaching the prune side
  # to match a prefix would therefore manufacture the exact permanently
  # unpublishable mirror the pairing invariant exists to prevent, so the term
  # is withheld rather than unpairable. Residual exposure is bounded: any
  # directory-granularity allowlist mistake that copies a temp also copies its
  # committed sibling, and the anchored `config.json` / `registry.json` terms
  # below reject that and block the publish. What stays uncovered is only an
  # allowlist naming a dot-prefixed temp pattern with no committed sibling
  # present. Closing it is a `delist_prune` prefix-matching change, tracked as
  # such, not a lint-only edit.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    printf '%s: private Trellis machine state must not publish\n' "$rel"
    rc=1
  done < <(find -P "$mirror_dir" \
    \( -path "$mirror_pat/.trellis" -o -path "$mirror_pat/.trellis/*" \
       -o -path "$mirror_pat/config.json" \
       -o -path "$mirror_pat/roster.json" \
       -o -path "$mirror_pat/registry.json" \
       -o -path "$mirror_pat/releases" -o -path "$mirror_pat/releases/*" \
       -o -path "$mirror_pat/state" -o -path "$mirror_pat/state/*" \
       -o -path "$mirror_pat/tasks" -o -path "$mirror_pat/tasks/*" \
       -o -path "$mirror_pat/locks" -o -path "$mirror_pat/locks/*" \
       -o -path "$mirror_pat/scheduled-tasks" -o -path "$mirror_pat/scheduled-tasks/*" \
       -o -path "$mirror_pat/local" -o -path "$mirror_pat/local/*" \) \
    -not -path '*/.git/*' -print 2>/dev/null)

  # A public symlink may be relative only when lexical resolution remains
  # inside the mirror. This rejects both absolute targets and ../ escapes
  # without dereferencing a potentially hostile target.
  # Record the failure and keep going. Returning here would let one unresolvable
  # symlink short-circuit every content check below, so a mirror could carry an
  # operator path or a fleet identifier and still be reported only as a symlink
  # problem. The verdict is the same either way; what changes is that the
  # operator sees the whole picture in one run.
  if ! mirror_validate_symlinks "$mirror_dir"; then
    rc=1
  fi
  # A home path may follow punctuation, control bytes, or high bytes; only a
  # path-segment character before the slash makes it relative. Recognizable
  # narrowly recognized relative route, glob and variable fixtures are not
  # literal roots. Other route-like prefixes do not exempt a home name.
  # Binary files retain the historical slash-terminated interior check
  # regardless of the preceding byte.
  # URLs are never discarded: their root, punctuation/fragment, Vite @fs, and
  # slash-terminated interior home segments can publish an operator name. Bare
  # nested API/documentation routes remain allowed. An ambiguous quoted command
  # ending in a home segment fails closed like a rooted path with spaces.
  # In the C locale, keep non-ASCII username bytes too; ASCII-only alnum
  # would make a valid UTF-8 operator name disappear from the bytewise scan.
  home_user_re="[[:alnum:]_.$(printf '\200-\377')-]+"
  home_name_re="(Users|home)/${home_user_re}"
  home_boundary_re="(^|[^[:alnum:]_.~/-])"
  home_path_re="${home_boundary_re}(/|~/)${home_name_re}|${home_boundary_re}(/[^/[:space:]\"'\\\\]|~/)([^[:space:]\"'\\\\]|\\\\[[:space:]])*/${home_name_re}|\"([^\"[:space:]/]*[=,:])?(/[^/[:space:]\"'\\\\]|~/)([^\"\\\\]|\\\\[[:space:]])*/${home_name_re}([/:']|\")|'([^'[:space:]/]*[=,:])?(/[^/[:space:]\"'\\\\]|~/)([^'\\\\]|\\\\[[:space:]])*/${home_name_re}([/:\"]|')"
  home_url_re="[[:alpha:]][[:alnum:]+.-]*://[^/[:space:]\"'<>]*/${home_name_re}|[[:alpha:]][[:alnum:]+.-]*://[^[:space:]\"'<>]*/${home_name_re}/|[[:alpha:]][[:alnum:]+.-]*://[^[:space:]\"'<>]*/@fs/${home_name_re}"
  home_route_re="${home_boundary_re}([[:alnum:]_.-]+/)+(\\([^/[:space:]()]+\\)|\\[[^/[:space:]]+\\])/${home_name_re}(/)?|${home_boundary_re}\\*\\*/${home_name_re}(/)?|${home_boundary_re}\\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}/${home_name_re}(/)?"
  # Keep this regex definition from looking like a literal home path itself.
  home_route_segment="ho""me"
  home_safe_route_re="${home_boundary_re}([[:alnum:]_.-]+/)*app/(\\([^/[:space:]()]+\\)|\\[[^/[:space:]]+\\])/${home_route_segment}/[[:alnum:]_.-]+[.](tsx|ts|jsx|js)(/)?|${home_boundary_re}\\*\\*/${home_route_segment}/node(/)?|${home_boundary_re}\\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}/${home_route_segment}/config[.]json(/)?"
  # Keep a possible NUL and the slash after the username for the binary pass.
  home_candidate_re="(^|.)(/|~/)(([^[:space:]\\\\]|\\\\[[:space:]])*/)?${home_name_re}(/)?"
  home_control_re="[$(printf '\001-\010\013\014\016-\037\177')]"
  home_binary_file="" home_is_binary=0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    home_source_file="${hit%%:*}"
    rel="${home_source_file#"$mirror_dir"/}"
    path="${hit#*:}"
    if [ "$home_source_file" != "$home_binary_file" ]; then
      home_binary_file="$home_source_file"
      home_is_binary=0
      # ASCII controls, NULs or invalid UTF-8 mark a byte-oriented payload.
      # An unavailable validation tool fails closed as binary.
      if /usr/bin/env LC_ALL=C grep -aqE "$home_control_re" -- "$home_source_file" 2>/dev/null || \
         ! cmp -s "$home_source_file" <(/usr/bin/env LC_ALL=C tr -d '\000' < "$home_source_file") || \
         ! /usr/bin/iconv -f UTF-8 -t UTF-8 "$home_source_file" >/dev/null 2>&1; then
        home_is_binary=1
      fi
    fi
    while IFS= read -r username; do
      [ -n "$username" ] || continue
      username="${username#/Users/}"
      username="${username#/home/}"
      username="${username%%/*}"
      case "$username" in
        me|example|user|you|test|jane|helios|alex|'…') continue ;;
        *[!._-]*) ;;
        *) continue ;;
      esac
      # A valid Unicode punctuation-only token is a placeholder, not a user.
      # Invalid bytes or an unavailable interpreter are never exempted.
      if [[ "$username" != *[0-9A-Za-z]* ]] && [ -x /usr/bin/perl ] && \
         printf '%s' "$username" | /usr/bin/perl -T -MEncode -e '
           local $/; my $bytes = <STDIN>;
           my $name = eval { Encode::decode("UTF-8", $bytes, Encode::FB_CROAK) };
           exit 1 if $@;
           exit($name =~ /\A\p{P}+\z/ ? 0 : 1);
         ' 2>/dev/null; then
        continue
      fi
      printf '%s: absolute-path leak\n' "$rel"
      rc=1
      break
    # Recheck after NUL-to-tab conversion. The binary lane preserves the old
    # anywhere rule; the text lane discards only recognized relative routes.
    done < <(export LC_ALL=C
      if [ "$home_is_binary" -eq 1 ]; then
        if printf '%s\n' "$path" | grep -oE -e "$home_url_re" -e "$home_path_re" |
          grep -oE "/${home_name_re}" 2>/dev/null; then :; fi
        # Leave the final slash available as the start of the next match.
        printf '%s\n' "$path" | awk -v re="/${home_name_re}/" '
          { text = $0
            while (match(text, re)) {
              print substr(text, RSTART, RLENGTH - 1)
              text = substr(text, RSTART + RLENGTH - 1)
            }
          }'
      else
        printf '%s\n' "$path" | grep -oE -e "$home_route_re" -e "$home_url_re" -e "$home_path_re" |
          while IFS= read -r home_match; do
            if printf '%s\n' "$home_match" | grep -qE "^(${home_safe_route_re})$"; then continue; fi
            printf '%s\n' "$home_match" | grep -oE "/${home_name_re}" 2>/dev/null
          done
      fi)
  done < <(export LC_ALL=C; mirror_lint_grep "$mirror_dir" "$scan_dir" -aHnoE \
    "$home_route_re" "$home_url_re" "$home_path_re" "$home_candidate_re" | tr '\000' '\t')

  # Preserve the historical-record boundary for the retired AntiGravity
  # harness. Three tokens name LIVE, publishable things and are stripped before
  # the stale-reference check: `google-antigravity` (the OMP provider id),
  # `pi-antigravity` (the pi provider extension package on npm), and the bare
  # lowercase `antigravity` (the pi provider id, as used in `/login antigravity`
  # and `--list-models antigravity`). Each is stripped only as a whole token —
  # adjacent identifier characters still mark it stale.
  #
  # Case is the discriminator that makes this safe: the retired harness was
  # always written `AntiGravity`/`Antigravity` in prose, so anything left after
  # stripping the three lowercase tokens still fails, including every
  # capitalised form. Public docs must therefore name the live provider by its
  # lowercase id rather than in prose caps.
  #
  # Spec 047 ships a live, public, antigravity-backed web-search adapter whose
  # public contract is unavoidably capitalised: the environment-variable names
  # it reads, its exported transport symbol, the provider host fragment, the
  # wire `ideType` value, and the provider's own spelling in error text and
  # attribution. Lower-casing any of them breaks the shipped feature.
  #
  # The allowance is PATH-SCOPED to the adapter, its runner and its one public
  # guide, which documents the same env contract, and every extra
  # token is an exact whole string, never a prefix class. A global allowance was
  # rejected: it would let a retired-harness reference through anywhere in the
  # tree. `AntiGravity` still fails everywhere, including inside the scope, and
  # the private-path, fleet-identity and proxy-token rules are untouched. This
  # is an allowance, not a skip — the check still runs on these files.
  #
  # Spec 053 adds a second, narrower scope on the same terms: the one tracked
  # file `core-rules/pi/extensions/trellis-web-search.ts`, which the public pi
  # guide installs and which must stay byte-identical to the operator's live
  # copy, so its capitalised spellings cannot be edited away.

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    case "$rel" in
      docs/adr/*|docs/specs/*|CHANGELOG.md|scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats|scripts/sync-to-template.sh) ;;
      *)
        # Path-scoped extra tokens for the Spec 047 adapter's public contract.
        mirror_allowed_tokens='google-antigravity pi-antigravity antigravity'
        case "$rel" in
          core-rules/pi/web-search/*|scripts/pi-web-search-tests.sh|docs/pi-web-search.md)
            mirror_allowed_tokens="ANTIGRAVITY_RUNTIME_MODEL ANTIGRAVITY_USER_AGENT \
ANTIGRAVITY_HUB_VERSION ANTIGRAVITY_PROJECT_ID ANTIGRAVITY_HUB_ARCH \
ANTIGRAVITY_BASE_URL createAntigravityTransport ANTIGRAVITY_HUB_OS \
ANTIGRAVITY_HUB_CL ANTIGRAVITY_API antigravity-api Antigravity-backed \
ANTIGRAVITY_ ANTIGRAVITY Antigravity $mirror_allowed_tokens"
            ;;
          # Spec 053 C6: the always-loaded pi web-search extension, tracked
          # byte-identical to the operator's live copy. Exactly one file and
          # four exact whole tokens, the compound identifiers first so the bare
          # capitalised form never sees their suffix. No ANTIGRAVITY_ prefix.
          core-rules/pi/extensions/trellis-web-search.ts)
            mirror_allowed_tokens="antigravityError searchAntigravity \
Antigravity ANTIGRAVITY $mirror_allowed_tokens"
            ;;
          # Spec 072 T32: the generated release-metadata audit lists every ADR
          # a traced suite reads, by path. docs/adr/* is release metadata by
          # design (trace-release-metadata.py META), and the ADR itself is
          # exempt above, so its exact path is allowed in this one file only.
          scripts/tests/release-metadata-audit.json)
            mirror_allowed_tokens="docs/adr/2026-05-20-antigravity-third-harness.md \
$mirror_allowed_tokens"
            ;;
          # Disk-janitor transcripts histogram reads the real ~/.gemini/antigravity-cli
          # runtime directory; allow the exact lowercase dir token in those two files.
          scripts/lib/disk-janitor-host.sh|scripts/tests/disk-janitor-lane-d.bats)
            mirror_allowed_tokens="antigravity-cli $mirror_allowed_tokens"
            ;;
        esac
        scan_file="$f"
        case "$rel" in
          core-rules/native/*)
            if [ -n "$scan_dir" ] && [ -f "$scan_dir/${rel#core-rules/native/}" ]; then
              scan_file="$scan_dir/${rel#core-rules/native/}"
            fi
            ;;
        esac
        if /usr/bin/env LC_ALL=C tr '\000' '\n' < "$scan_file" | awk -v allowed_tokens="$mirror_allowed_tokens" '
          {
            line = $0
            # Longest first: pi-/google- prefixes must be consumed before the
            # bare id, or the bare-id pass would see their suffix as a match
            # with an identifier character before it and call it stale.
            n = split(allowed_tokens, allowed, /[ \t\n]+/)
            for (i = 1; i <= n; i++) {
              if (allowed[i] == "") continue
              token = allowed[i]
              while ((pos = index(line, token)) != 0) {
                before = pos == 1 ? "" : substr(line, pos - 1, 1)
                after = substr(line, pos + length(token), 1)
                if (before ~ /[[:alnum:]_-]/ || after ~ /[[:alnum:]_-]/) {
                  stale = 1
                  exit
                }
                line = substr(line, 1, pos - 1) substr(line, pos + length(token))
              }
            }
            if (index(tolower(line), "antigravity")) {
              stale = 1
              exit
            }
          }
          END { exit stale ? 0 : 1 }
        '; then
          printf "%s: stale 'antigravity' in current operator surface\n" "$rel"
          rc=1
        fi
        ;;
    esac
  done < <(mirror_lint_grep "$mirror_dir" "$scan_dir" -aliF 'antigravity')

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    case "$rel" in
      docs/adr/*|docs/specs/*|CHANGELOG.md|scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) ;;
      *) printf "%s: instance-private proxy token must not publish\n" "$rel"; rc=1 ;;
    esac
  done < <(mirror_lint_grep "$mirror_dir" "$scan_dir" -aliE 'claudex|cli-proxy-api|cliproxy')

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$mirror_dir"/}"
    case "$rel" in
      docs/adr/*|docs/specs/*|CHANGELOG.md|scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) ;;
      *) printf "%s: operator account or workspace token must not publish\n" "$rel"; rc=1 ;;
    esac
  done < <(export LC_ALL=C && mirror_lint_grep "$mirror_dir" "$scan_dir" -alE 'wrk_[0-9A-Za-z]{20,}')

  # Fleet project identifiers must never reach a public mirror. Deliberately NO
  # historical-record exemption: unlike the retired-integration tokens above,
  # `docs/adr/*`, `docs/specs/*` and `CHANGELOG.md` are exactly where project
  # names accumulated unnoticed, because narrative prose is written long after
  # the allowlist decision and nothing re-checked it. A name is as public in a
  # two-year-old ADR as in today's README, so the boundary does not apply here.
  if ! identity_tokens="$(mirror_fleet_identity_tokens)" || [ -z "$identity_tokens" ]; then
    printf 'mirror-lint: fleet identity source unreadable — refusing to certify a mirror it cannot check\n'
    rc=1
  else
    while IFS= read -r identity_token; do
      [ -n "$identity_token" ] || continue
      # Treat underscore as an identifier separator but keep alphanumeric word
      # boundaries, so HELIOS_HOME is caught without flagging heliospheric.
      identity_ere="$(printf '%s' "$identity_token" | /usr/bin/env LC_ALL=C sed 's/[][\\.^$*+?{}()|]/\\&/g')"
      identity_pattern="(^|[^[:alnum:]])${identity_ere}([^[:alnum:]]|$)"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$mirror_dir"/}"
        case "$rel" in
          scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) ;;
          *) printf '%s: local fleet project identifier must not publish\n' "$rel"; rc=1 ;;
        esac
      done < <(export LC_ALL=C && mirror_lint_grep "$mirror_dir" "$scan_dir" -aliE "$identity_pattern")
      # Filenames, directory names and symlink names are published too. Never
      # follow links; NUL delimiters keep unusual path bytes in one record.
      while IFS= read -r -d '' f; do
        [ "$f" != "$mirror_dir" ] || continue
        rel="${f#"$mirror_dir"/}"
        if printf '%s\n' "$rel" | /usr/bin/env LC_ALL=C grep -qiE -- "$identity_pattern"; then
          printf '%s: local fleet project identifier must not publish\n' "$rel"
          rc=1
        fi
      done < <(find -P "$mirror_dir" -path "$mirror_pat/.git" -prune -o -print0 2>/dev/null)
    done <<IDENTITY_TOKENS
$identity_tokens
IDENTITY_TOKENS
  fi

  # Routable IPv4 literals are operator infrastructure — origin hosts, VPS
  # addresses, tunnel endpoints. Private, loopback, link-local and the three
  # RFC 5737 documentation ranges stay allowed so examples and fixtures work.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rel="${hit%%:*}"
    rel="${rel#"$mirror_dir"/}"
    case "$rel" in
      scripts/lib/mirror-lint.sh|scripts/tests/mirror-lint.bats) continue ;;
    esac
    path="${hit#*:}"
    while IFS= read -r address; do
      [ -n "$address" ] || continue
      case "$address" in
        10.*|127.*|169.254.*|0.0.0.0|255.255.255.255) continue ;;
        192.168.*|192.0.2.*|198.51.100.*|203.0.113.*) continue ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
      esac
      printf '%s: routable IP literal must not publish\n' "$rel"
      rc=1
      break
    done < <(export LC_ALL=C; printf '%s\n' "$path" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null)
  done < <(export LC_ALL=C; mirror_lint_grep "$mirror_dir" "$scan_dir" -aHnoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')

  if [ -n "$scan_dir" ]; then rm -rf "${scan_dir:?}"; fi
  return "$rc"
}
