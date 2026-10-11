#!/usr/bin/env bash
# OSV-scanner — emits normalized findings JSONL.
# Usage: osv.sh <project-dir> <out-jsonl> [--status FILE]
#   [--changed-manifests FILE] [--tracked FILE] [--config FILE]
# Changed/tracked lists are NUL-delimited.
# Exit 0: completed (including vulnerabilities); exit 2: incomplete.
#
# --config FILE is passed on as --config, which replaces osv-scanner's discovery of
# osv-scanner.toml beside each manifest; diff mode hands in the range base's
# copy (or an empty file) so the scanned tree cannot waive its own advisories.
# osv-scanner and python3 are absolute PATH binaries outside the project
# (lib/engine.sh); inherited shell functions are dropped first, by a purge
# that cannot be intercepted (POSIX mode finds `unset`/`set` before functions;
# see run-diff.sh). The parser runs isolated (-I) and must reach its end.

POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
for _sg_fn in $(builtin compgen -A function 2>/dev/null); do builtin unset -f "$_sg_fn"; done
builtin unset -f osv-scanner python3
builtin unset _sg_fn

set -euo pipefail

PROJECT_DIR="${1:?project-dir required}"
OUT="${2:?out-jsonl required}"
shift 2
STATUS_OUT=/dev/null
MANIFEST_LIST=""; TRACKED_LIST=""; CONFIG=""; SEEN=" "
case "$0" in */*) _sg_lib_dir="${0%/*}" ;; *) _sg_lib_dir=. ;; esac
builtin source "$_sg_lib_dir/engine.sh"
sg_path_sanitize "$PROJECT_DIR" || { echo "osv-scanner did not complete: cannot resolve $PROJECT_DIR" >&2; exit 2; }
RAN=0; RC=not-run; PARSED=0; SCANNED=0
RAW="$(mktemp)"
ERR="$(mktemp)"
trap 'printf "osv-scanner: ran=%s exit=%s parsed=%s scanned=%s\n" "$RAN" "$RC" "$PARSED" "$SCANNED" > "$STATUS_OUT"; rm -f "$RAW" "$ERR" "$RAW.scanned" "$RAW.reason" "$RAW.tracked"' EXIT
: > "$OUT"

# Never interpret a config/status file as a changed-manifest list. In particular,
# an empty pinned config is valid; an explicitly empty coverage input is not.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status|--changed-manifests|--tracked|--config)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" = --* ]]; then
        echo "osv-scanner did not complete: $1 requires a file" >&2; exit 2
      fi
      case "$SEEN" in *" $1 "*) echo "osv-scanner did not complete: duplicate option $1" >&2; exit 2 ;; esac
      SEEN="$SEEN$1 "
      case "$1" in
        --status) STATUS_OUT="$2" ;;
        --changed-manifests) MANIFEST_LIST="$2" ;;
        --tracked) TRACKED_LIST="$2" ;;
        --config) CONFIG="$2" ;;
      esac
      shift 2
      ;;
    *) echo "osv-scanner did not complete: unknown option or positional argument: $1" >&2; exit 2 ;;
  esac
done
for flag in --changed-manifests --tracked; do
  case "$flag" in --changed-manifests) file="$MANIFEST_LIST" ;; --tracked) file="$TRACKED_LIST" ;; esac
  if [ -n "$file" ] && { [ ! -f "$file" ] || [ ! -r "$file" ] || [ ! -s "$file" ]; }; then
    echo "osv-scanner did not complete: $flag file is missing, unreadable or empty" >&2; exit 2
  fi
done
CONFIG_ARGS=()
if [ -n "$CONFIG" ]; then
  if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    echo "osv-scanner did not complete: config file is missing or unreadable" >&2; exit 2
  fi
  CONFIG_ARGS=(--config "$CONFIG")
fi

OSV_RC=0
OSV_BIN="$(sg_resolve_engine osv-scanner "$PROJECT_DIR")" || OSV_RC=$?
PY_RC=0
PYTHON3_BIN="$(sg_resolve_engine python3 "$PROJECT_DIR")" || PY_RC=$?
case "$OSV_RC:$PY_RC" in
  0:0) ;;
  3:*) echo "osv-scanner did not complete: osv-scanner resolves inside the scanned project" >&2; exit 2 ;;
  *:3) echo "osv-scanner did not complete: python3 resolves inside the scanned project" >&2; exit 2 ;;
  0:*) echo "osv-scanner did not complete: python3 not installed" >&2; exit 2 ;;
  *)   echo "osv-scanner did not complete: binary not installed" >&2; exit 2 ;;
esac

# Baseline/direct callers also get the tracked-only boundary, even without a
# changed-manifest list. Never fall back to counting local/untracked sources.
if [ -z "$TRACKED_LIST" ]; then
  TRACKED_LIST="$RAW.tracked"
  if ! git -C "$PROJECT_DIR" ls-files -z --recurse-submodules > "$TRACKED_LIST" 2>/dev/null; then
    echo "osv-scanner did not complete: could not list tracked files" >&2
    exit 2
  fi
fi

# osv-scanner exits 1 when vulns are found; that is success for our purposes.
RAN=1; RC=0
# Tracked manifests in ignored directories still belong to the pushed range.
# JSON contains only vulnerable sources; stderr carries the coverage receipts.
"$OSV_BIN" --format=json --recursive --no-ignore "${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}" "$PROJECT_DIR" >"$RAW" 2>"$ERR" || RC=$?
case "$RC" in
  0|1) ;;
  128) echo "osv-scanner did not complete: no lockfile osv-scanner can read (scanner exit 128)" >&2; exit 2 ;;
  *) echo "osv-scanner did not complete: scanner exit $RC" >&2; exit 2 ;;
esac

PARSE_DONE="$(mktemp)"
rm -f "$PARSE_DONE"
if SG_PARSE_DONE="$PARSE_DONE" "$PYTHON3_BIN" -I - "$RAW" "$PROJECT_DIR" "$ERR" "$MANIFEST_LIST" "$RAW.scanned" "$RAW.reason" "$TRACKED_LIST" >"$OUT" 2>/dev/null <<'PY'
import fnmatch, json, math, os, re, sys

raw, root = sys.argv[1], os.path.abspath(sys.argv[2])
sev_rank = {"CRITICAL": "critical", "HIGH": "high", "MODERATE": "medium", "MEDIUM": "medium", "LOW": "low"}


def score_severity(value):
    try:
        score = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(score) or not 0 <= score <= 10:
        return None
    if score >= 9:
        return "critical"
    if score >= 7:
        return "high"
    if score >= 4:
        return "medium"
    return "low"


def vulnerability_severity(vuln, groups):
    vulnerability_id = vuln.get("id")
    for group in groups:
        if not isinstance(group, dict):
            continue
        ids = group.get("ids") or []
        if vulnerability_id in ids:
            normalized = score_severity(group.get("max_severity"))
            if normalized:
                return normalized

    database_specific = vuln.get("database_specific")
    if isinstance(database_specific, dict):
        database_severity = database_specific.get("severity")
        if isinstance(database_severity, str):
            normalized = sev_rank.get(database_severity.upper())
            if normalized:
                return normalized

    return "medium"


try:
    with open(raw) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(2)
if not isinstance(data, dict) or not isinstance(data.get("results"), list): sys.exit(2)
if not all(isinstance(result, dict) for result in data["results"]): sys.exit(2)
with open(sys.argv[7], "rb") as fh:
    tracked = {os.path.abspath(os.path.join(root, os.fsdecode(path)))
               for path in fh.read().split(b"\0") if path}
def tracked_source(path):
    # OSV vendored/git sources can name a directory, not a single lockfile.
    # Require a path-component boundary; deps-other is not inside deps.
    return os.path.commonpath((root, path)) == root and (
        path in tracked or any(file.startswith(path + os.sep) for file in tracked))


counter = 0
for result in data["results"]:
    src = (result.get("source") or {}).get("path", "")
    if not isinstance(src, str) or not src: sys.exit(2)
    if not tracked_source(os.path.abspath(os.path.join(root, src))): continue
    if src.startswith(root + os.sep): src = src[len(root) + 1:]
    for pkg in result.get("packages", []):
        info = pkg.get("package", {})
        name, ver, eco = info.get("name", "?"), info.get("version", "?"), info.get("ecosystem", "?")
        groups = pkg.get("groups", []) or []
        for vuln in pkg.get("vulnerabilities", []):
            vid = vuln.get("id", "OSV-UNKNOWN")
            summary = (vuln.get("summary") or vuln.get("details") or "")[:200].splitlines()[0] if (vuln.get("summary") or vuln.get("details")) else ""
            sev = vulnerability_severity(vuln, groups)
            counter += 1
            out = {
                "id": f"osv-{counter:04d}",
                "tool": "osv",
                "rule": vid,
                "severity": sev,
                "file": src,
                "line": 0,
                "message": f"{name}@{ver} ({eco}) — {summary}".strip(" —"),
            }
            print(json.dumps(out, ensure_ascii=False))

# OSV 2.6.0 emits "Scanned <absolute path> file and found ..." on stderr.
# Do not infer coverage from results[], which omits clean dependency sources.
scanned = set()
with open(sys.argv[3]) as fh:
    for line in fh:
        match = re.match(r"^Scanned (.+) file(?: and found .*)?$", line.rstrip("\r\n"))
        if match and os.path.isabs(match.group(1)):
            path = os.path.normpath(match.group(1))
            if path in tracked: scanned.add(path)
with open(sys.argv[5], "w") as fh: fh.write(str(len(scanned)) + "\n")
manifests = []
if sys.argv[4]:
    with open(sys.argv[4], "rb") as fh: contents = fh.read()
    parts = contents.split(b"\0")
    if not contents.endswith(b"\0") or not parts[0] or any(not part for part in parts[:-1]):
        with open(sys.argv[6], "w") as fh: fh.write("changed-manifests file is empty or malformed\n")
        sys.exit(2)
    manifests = [os.fsdecode(path) for path in parts[:-1]]


def jsonc_load(text):
    # Bun's text lock uses JSON with comments and trailing commas. Tokenize
    # strings first so comment markers/commas inside a path stay literal.
    decoder = json.JSONDecoder()
    tokens = []
    i = 0
    while i < len(text):
        if text[i] == '"':
            _, end = decoder.raw_decode(text, i)
            tokens.append(text[i:end]); i = end
        elif text.startswith("//", i):
            end = text.find("\n", i + 2)
            i = len(text) if end < 0 else end
            tokens.append(" ")
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0: raise ValueError("unclosed comment")
            tokens.append(" "); i = end + 2
        else:
            tokens.append(text[i]); i += 1
    cleaned = "".join(tokens)
    tokens = []; i = 0
    while i < len(cleaned):
        if cleaned[i] == '"':
            _, end = decoder.raw_decode(cleaned, i)
            tokens.append(cleaned[i:end]); i = end
        else:
            if cleaned[i] != "," or not cleaned[i + 1:].lstrip().startswith(("}", "]")):
                tokens.append(cleaned[i])
            i += 1
    return json.loads("".join(tokens))


def yaml_scalar(value):
    # Recognize single-line generated lock scalars, not arbitrary YAML. Reject
    # multiline quoted/flow values rather than mistaking their text for keys.
    value = value.strip()
    if not value or value.startswith("#"): return ""
    if value.startswith('"'):
        scalar, end = json.JSONDecoder().raw_decode(value)
        if value[end:].strip() and not value[end:].lstrip().startswith("#"):
            raise ValueError("unsupported YAML scalar")
        return scalar
    if value.startswith("'"):
        match = re.match(r"^'((?:''|[^'])*)'(?:\s*#.*)?$", value)
        if not match: raise ValueError("unsupported YAML scalar")
        return match.group(1).replace("''", "'")
    if value.startswith(("{", "[")):
        # Balanced single-line flow values; quotes cannot span physical lines.
        stack = []; i = 0
        while i < len(value):
            char = value[i]
            if char in "\"'":
                if char == '"':
                    _, i = json.JSONDecoder().raw_decode(value, i)
                else:
                    match = re.match(r"'((?:''|[^'])*)'", value[i:])
                    if not match: raise ValueError("unclosed YAML quote")
                    i += match.end()
                continue
            if char in "{[": stack.append(char)
            elif char in "}]":
                if not stack or stack.pop() != {"}": "{", "]": "["}[char]:
                    raise ValueError("unbalanced YAML flow")
                if not stack:
                    tail = value[i + 1:].strip()
                    if tail and not tail.startswith("#"): raise ValueError("unsupported YAML flow")
                    return value[:i + 1]
            i += 1
        raise ValueError("unclosed YAML flow")
    return re.split(r"\s+#", value, maxsplit=1)[0].rstrip()


def yaml_value(value):
    parsed = yaml_scalar(value)
    # Quoted "{}", "", or "|" are strings, never mapping/block containers.
    return "quoted scalar" if value.lstrip().startswith(('"', "'")) else parsed


def yaml_records(text):
    # A deliberately bounded reader for pnpm/yarn generated mapping keys.
    # No aliases, tags, multiline quotes, or flow importer maps are proof.
    records = []; parents = []; block_indent = None
    key_pattern = r'''^( *)("(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^\s:'"{}\[\]#][^:]*?):(?:\s+(.*)|\s*)$'''
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"): continue
        indent = len(line) - len(line.lstrip(" "))
        if block_indent is not None:
            if indent > block_indent: continue
            block_indent = None
        if "\t" in line[:indent + 1]: raise ValueError("YAML tab indentation")
        if line.lstrip().startswith("- "):
            key = None
            value = yaml_value(line.lstrip()[2:])
        else:
            match = re.match(key_pattern, line)
            if not match: raise ValueError("unsupported YAML mapping")
            key = yaml_scalar(match.group(2))
            value = yaml_value(match.group(3) or "")
        while parents and indent <= parents[-1][0]: parents.pop()
        if indent:
            if not parents or parents[-1][1]: raise ValueError("mapping inside a scalar")
            parent = parents[-1]
            kind = "sequence" if key is None else "mapping"
            if parent[2] not in (None, indent) or parent[3] not in (None, kind):
                raise ValueError("inconsistent YAML container")
            parent[2:] = [indent, kind]
        if not indent and key is None: raise ValueError("root must be a mapping")
        parents.append([indent, value or ("sequence item" if key is None else ""), None, None])
        if value.startswith(("|", ">")): block_indent = indent
        records.append((indent, key, value))
    return records


def block_mapping(records, index):
    indent, _, value = records[index]
    return value == "{}" or (not value and index + 1 < len(records)
                            and records[index + 1][0] > indent
                            and records[index + 1][1] is not None)


def cargo_glob_matches(rel, pattern):
    # Anchor to the lock directory and match * / ? / [] within one component.
    # Only a whole-component ** can consume multiple directory components.
    while pattern.startswith("./"): pattern = pattern[2:]
    parts = pattern.rstrip("/").split("/")
    if os.path.isabs(pattern) or any(part in ("", ".", "..") or
                                   ("**" in part and part != "**") for part in parts):
        raise ValueError("unsupported Cargo workspace glob")
    path = rel.split("/")
    states = {0}
    for part in parts:
        if part == "**":
            states = {end for start in states for end in range(start, len(path) + 1)}
        else:
            states = {start + 1 for start in states if start < len(path)
                      and fnmatch.fnmatchcase(path[start], part)}
    return len(path) in states


def ancestor_member(lock, manifest):
    rel = os.path.relpath(os.path.dirname(manifest), os.path.dirname(lock)).replace(os.sep, "/")
    name = os.path.basename(lock)
    try:
        with open(lock) as fh: text = fh.read()
        if name in ("package-lock.json", "npm-shrinkwrap.json", "bun.lock"):
            data = jsonc_load(text) if name == "bun.lock" else json.loads(text)
            members = data.get("workspaces" if name == "bun.lock" else "packages")
            return isinstance(members, dict) and isinstance(members.get(rel), dict)
        if name in ("pnpm-lock.yaml", "yarn.lock"):
            records = yaml_records(text)
            # Duplicate root keys make membership ambiguous; never accept them.
            roots = [key for indent, key, _ in records if indent == 0]
            if len(roots) != len(set(roots)): return False
            if name == "pnpm-lock.yaml":
                for i, (indent, key, value) in enumerate(records):
                    if indent != 0 or key != "importers" or value: continue
                    children = []
                    for j in range(i + 1, len(records)):
                        child_indent, child_key, _ = records[j]
                        if child_indent == 0: break
                        children.append((j, child_indent, child_key))
                    if not children: return False
                    level = min(indent for _, indent, _ in children)
                    keys = [key for _, indent, key in children if indent == level]
                    if len(keys) != len(set(keys)) or "<<" in keys: return False
                    return any(key == rel and block_mapping(records, j)
                               for j, indent, key in children if indent == level)
                return False
            for i, (indent, key, _) in enumerate(records):
                if indent != 0 or not key or not block_mapping(records, i): continue
                for descriptor in key.split(", "):
                    parts = descriptor.rsplit("@workspace:", 1)
                    if (len(parts) == 2 and parts[1] == rel
                            and re.fullmatch(r"(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+", parts[0])):
                        return True
            return False
        if name in ("uv.lock", "Cargo.lock"):
            try: import tomllib
            except ImportError: import tomli as tomllib
            data = tomllib.loads(text)
            packages = data.get("package", [])
            if name == "uv.lock":
                return any(isinstance(pkg, dict) and isinstance(pkg.get("source"), dict)
                           and any(pkg["source"].get(kind) == rel for kind in ("editable", "virtual"))
                           for pkg in packages)
            with open(manifest, "rb") as fh: manifest_data = tomllib.load(fh)
            if "workspace" in manifest_data: return False
            workspace_path = os.path.join(os.path.dirname(lock), "Cargo.toml")
            if workspace_path not in tracked: return False
            with open(workspace_path, "rb") as fh: workspace = tomllib.load(fh).get("workspace")
            if not isinstance(workspace, dict): return False
            members, excludes = workspace.get("members", []), workspace.get("exclude", [])
            if not all(isinstance(values, list) and all(isinstance(value, str) for value in values)
                       for values in (members, excludes)): return False
            # Evaluate every pattern: unsupported exclude syntax must block,
            # never silently become a non-matching exclusion.
            included = [cargo_glob_matches(rel, pattern) for pattern in members]
            excluded = [cargo_glob_matches(rel, pattern) for pattern in excludes]
            # Cargo excludes literal paths and their descendants. Keep glob
            # matches as additional conservative blocks, never as an exemption.
            for path in excludes:
                while path.startswith("./"): path = path[2:]
                path = path.rstrip("/")
                excluded.append(rel == path or rel.startswith(path + "/"))
            if not any(included) or any(excluded): return False
            member = manifest_data.get("package", {}).get("name")
            return isinstance(member, str) and bool(member) and any(
                isinstance(pkg, dict) and pkg.get("name") == member and "source" not in pkg
                for pkg in packages)
    except (OSError, ValueError, TypeError, AttributeError, ImportError):
        return False
    # Binary bun.lockb and other ancestor formats cannot prove a member here.
    # They can still satisfy the existing sibling-lock contract.
    return False


ecosystem_locks = {
    "package.json": ("package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"),
    "Cargo.toml": ("Cargo.lock",),
    "pyproject.toml": ("uv.lock", "poetry.lock", "Pipfile.lock"),
}
reasons = []
for manifest in manifests:
    path = os.path.abspath(os.path.join(root, manifest))
    name = os.path.basename(path)
    display = manifest.replace("\n", "\\n").replace("\r", "\\r")
    # OSV percent-encodes control characters; accepting such names or literal
    # percent signs would make receipts ambiguous with a differently named file.
    if any(char == "%" or ord(char) < 32 or 127 <= ord(char) <= 159 for char in manifest):
        reasons.append("changed manifest path contains control character or %: " + json.dumps(manifest))
        continue
    if name in ecosystem_locks:
        directory = os.path.dirname(path)
        nearest = []
        while os.path.commonpath((root, directory)) == root:
            nearest = [os.path.join(directory, lock) for lock in ecosystem_locks[name]
                       if os.path.join(directory, lock) in tracked]
            if nearest or directory == root: break
            directory = os.path.dirname(directory)
        receipts = [lock for lock in nearest if lock in scanned]
        if not receipts:
            reasons.append("no lockfile osv-scanner can read: " + display)
        elif directory != os.path.dirname(path) and not any(ancestor_member(lock, path) for lock in receipts):
            reasons.append("ancestor lockfile does not name member: " + display)
    elif name == "go.sum":
        # OSV scans go.mod, not the checksum file; only a same-directory
        # module receipt proves coverage of this dependency change.
        if os.path.join(os.path.dirname(path), "go.mod") not in scanned:
            reasons.append("changed manifest not scanned: " + display + " (sibling go.mod not scanned)")
    elif path not in scanned:
        reasons.append("changed manifest not scanned: " + display)
if reasons:
    with open(sys.argv[6], "w") as fh: fh.write("; ".join(reasons) + "\n")
    sys.exit(2)
open(os.environ["SG_PARSE_DONE"], "w").close()
PY
then
  [ -f "$PARSE_DONE" ] || { rm -f "$PARSE_DONE"; echo "osv-scanner did not complete: parser did not finish" >&2; exit 2; }
  rm -f "$PARSE_DONE"
  PARSED=1
  read -r SCANNED < "$RAW.scanned"
else
  if [ -s "$RAW.reason" ]; then
    PARSED=1
    read -r SCANNED < "$RAW.scanned"
    read -r REASON < "$RAW.reason"
    printf 'osv-scanner did not complete: %s\n' "$REASON" >&2
  else
    echo "osv-scanner did not complete: missing or malformed JSON" >&2
  fi
  exit 2
fi
