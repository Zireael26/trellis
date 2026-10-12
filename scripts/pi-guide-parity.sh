#!/usr/bin/env bash
# pi-guide-parity.sh — prove what AGENT_PI_SETUP.md writes, and (on request)
# that it matches the operator's live ~/.pi/agent byte for byte.
#
# Only blocks tagged `<!-- pi-guide:file <path> -->` on the line directly above
# their opening fence are replayed, into a fresh temporary HOME. Nothing is
# executed by a shell: a tagged `bash` block is interpreted here, one line at a
# time, against an allowlist of file operations, and any other line refuses
# the whole block. That is what keeps a wrapped command (`env security …`,
# `command npm …`) or arbitrary code from ever running. The allowlist:
#
#   mkdir -p DST
#   cat > DST <<'TAG' … TAG     literal heredoc
#   cat > DST <<TAG … TAG       unquoted heredoc; only $HOME may appear
#   cp [-R] SRC DST             SRC from the repository
#   install -m MODE SRC DST     SRC from the repository
#   chmod MODE DST
#   rm -rf DST                  only when DST is exactly the block's tagged path
#
# SRC may only be "$TRELLIS_REPO_ROOT/…", must resolve inside the repository and
# may contain no symlink anywhere (links are refused, never copied). DST may
# only be "$HOME/…" and must resolve inside the temporary HOME; a written file
# must be the tagged path or lie under it, and `mkdir -p` may create only the
# tagged path, a directory under a tagged directory, or an ancestor of the
# tagged path. An unquoted heredoc expands `$HOME` or `${HOME}` only at a
# variable boundary (`$HOME_X` is another variable, and refused). A tag whose
# path resolves outside the temporary HOME is refused before anything runs.
# A fence in any other language is file content, written verbatim to the
# tagged path. Untagged blocks never run; those that call `security`, a pi
# OAuth or auth command, `npm` or `pi install` are listed as skipped by name.
#
# Hermetic checks (always):
#   - every expected tagged path is produced;
#   - every rendered JSON file parses;
#   - no output carries a secret value, or an absolute /Users/ path once the
#     temporary HOME is replaced by __HOME__;
#   - every file the guide copies from the repository is byte-identical to its
#     tracked source (node_modules, build output and lockfiles excluded).
#
# --against-live (read-only) additionally compares six rendered files with
# <live-home>/.pi/agent after the same placeholder substitution on both sides:
# the home directory becomes __HOME__. A residual /Users/ path fails. Byte identity is required.
# Nothing under the live home is written, and auth.json is never read.
#
# Usage: scripts/pi-guide-parity.sh [--guide FILE] [--repo DIR] [--emit DIR]
#                                   [--against-live] [--live-home DIR]
#   --emit DIR  also copy the rendered temporary HOME to DIR, only on a pass.
# Exit: 0 pass; 1 a check failed; 2 bad arguments.
set -euo pipefail

ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GUIDE="$ROOT/AGENT_PI_SETUP.md"
REPO="$ROOT"
AGAINST_LIVE=0
LIVE_HOME="$HOME"
EMIT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --guide) [ "$#" -ge 2 ] || { echo 'pi-guide-parity: --guide requires FILE' >&2; exit 2; }; GUIDE="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || { echo 'pi-guide-parity: --repo requires DIR' >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --against-live) AGAINST_LIVE=1; shift ;;
    --live-home) [ "$#" -ge 2 ] || { echo 'pi-guide-parity: --live-home requires DIR' >&2; exit 2; }; LIVE_HOME="$2"; shift 2 ;;
    --emit) [ "$#" -ge 2 ] || { echo 'pi-guide-parity: --emit requires DIR' >&2; exit 2; }; EMIT="$2"; shift 2 ;;
    *) echo "pi-guide-parity: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -f "$GUIDE" ] || { echo "pi-guide-parity: guide not found: $GUIDE" >&2; exit 2; }
[ -d "$REPO" ] || { echo "pi-guide-parity: repo not found: $REPO" >&2; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pi-guide-parity.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"
SANDBOX_HOME="$(CDPATH='' cd "$SANDBOX/home" && pwd -P)"

status=0
python3 - "$GUIDE" "$REPO" "$SANDBOX_HOME" "$AGAINST_LIVE" "$LIVE_HOME" <<'PY' || status=$?
import filecmp
import json
import os
import re
import shlex
import shutil
import sys
from pathlib import Path

guide_path, repo, sandbox_home, against_live, live_home = sys.argv[1:6]
repo = Path(repo).resolve()
home = Path(sandbox_home)
failures = []

# Paths the guide must write. A tag that disappears is a failure, not a skip.
EXPECTED = [
    "~/.pi/agent/settings.json",
    "~/.pi/agent/extensions/opencode-go-2.ts",
    "~/.pi/agent/extensions/trellis-web-search.ts",
    "~/.pi/agent/extensions/trellis-bash-guard.ts",
    "~/.pi/agent/extensions/omp-statusline/",
    "~/.pi/agent/subagents.json",
    "~/.pi/agent/pi-statusline.json",
    "~/.zshenv",
]
# Files the guide copies from this repository, with their tracked source.
COPIES = {
    "~/.pi/agent/extensions/opencode-go-2.ts": "core-rules/pi/extensions/opencode-go-2.ts",
    "~/.pi/agent/extensions/trellis-web-search.ts": "core-rules/pi/extensions/trellis-web-search.ts",
    "~/.pi/agent/extensions/trellis-bash-guard.ts": "core-rules/pi/extensions/trellis-bash-guard.ts",
    "~/.pi/agent/extensions/omp-statusline/": "core-rules/pi/statusline/omp-statusline",
}
COPY_EXCLUDES = {"node_modules", "dist", "build", "package-lock.json", "npm-shrinkwrap.json"}
LIVE_FILES = [
    ".pi/agent/settings.json",
    ".pi/agent/subagents.json",
    ".pi/agent/pi-statusline.json",
    ".pi/agent/extensions/opencode-go-2.ts",
    ".pi/agent/extensions/trellis-web-search.ts",
    ".pi/agent/extensions/trellis-bash-guard.ts",
]
# Only for naming untagged blocks in the skipped list; replay safety comes from
# the allowlist interpreter, not from these patterns.
SKIP_REASONS = [
    ("security", re.compile(r"(?<![!\w-])security\s")),
    ("oauth-login", re.compile(r"(^|\s)/login\b|\bpi\s+auth\b", re.M)),
    ("npm", re.compile(r"(?<![\w-])npm\s")),
    ("pi-install", re.compile(r"\bpi\s+install\b")),
    ("interactive-pi", re.compile(r"(^|[;&|(]\s*)\s*(env\s.*\s)?pi\s*$", re.M)),
]
SECRET_PATTERNS = [
    ("provider-key", re.compile(r"\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xai-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})")),
    ("credential-field", re.compile(
        r"""["']?\b(api_?key|apiKey|access|refresh|access_token|refresh_token|token|secret|password|key)["']?\s*[:=]\s*["'](?![!$])[^"'\s]{16,}["']""")),
    ("literal-secret-export", re.compile(
        r"""(?m)^\s*(export\s+)?[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*=(?!\$\(|"\$\()\S+""")),
]

TAG = re.compile(r"^<!-- pi-guide:file (\S+) -->$")
FENCE = re.compile(r"^```(\S*)\s*$")
HEREDOC = re.compile(r"""^cat\s+>\s*(\S+)\s+<<(')?([A-Za-z_]+)(')?\s*$""")


class Refused(Exception):
    pass


def parse_blocks(text):
    """Yield (heading, ordinal, tag, language, body) for every fenced block."""
    lines = text.split("\n")
    heading, ordinal, tag, i = "(preamble)", {}, None, 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("## "):
            heading = line[3:].strip()
        m = TAG.match(line)
        if m:
            if i + 1 >= len(lines) or not FENCE.match(lines[i + 1]):
                failures.append(f"tag at line {i + 1} is not directly above a fence")
            else:
                tag = m.group(1)
            i += 1
            continue
        f = FENCE.match(line)
        if f:
            lang, body = f.group(1), []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            ordinal[heading] = ordinal.get(heading, 0) + 1
            yield heading, ordinal[heading], tag, lang, "\n".join(body) + "\n"
            tag = None
        i += 1


def inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def tag_target(tagged):
    if not tagged.startswith("~/"):
        raise Refused(f"tag path must start with ~/: {tagged}")
    target = home / tagged[2:]
    if not inside(target, home) or os.path.realpath(target) == os.path.realpath(home):
        raise Refused(f"tag {tagged} resolves outside the temporary HOME")
    return target


def operand(token, kind):
    """Map one quoted "$HOME/…" or "$TRELLIS_REPO_ROOT/…" operand to a checked path."""
    roots = {"dst": (("$HOME/", "${HOME}/"), home), "src": (("$TRELLIS_REPO_ROOT/", "${TRELLIS_REPO_ROOT}/"), repo)}
    prefixes, root = roots[kind]
    for prefix in prefixes:
        if token.startswith(prefix):
            rest = token[len(prefix):]
            if "$" in rest or "`" in rest:
                break
            path = root / rest
            if not inside(path, root):
                raise Refused(f"{kind} {token} resolves outside {'the temporary HOME' if kind == 'dst' else 'the repository'}")
            return path
    raise Refused(f"{kind} operand must be {prefixes[0]}…: {token}")


def writes_within(path, target, tagged):
    if tagged.endswith("/"):
        ok = inside(path, target)
    else:
        ok = os.path.realpath(path) == os.path.realpath(target)
    if not ok:
        raise Refused(f"writes {path} outside its tagged path {tagged}")


def mkdir_within(path, target, tagged):
    # A directory may be the tagged path, lie under a tagged directory, or be an
    # ancestor of the tagged path (the parents a write needs). Nothing else.
    real, goal = os.path.realpath(path), os.path.realpath(target)
    if goal == real or goal.startswith(real + os.sep):
        return
    if tagged.endswith("/") and inside(path, target):
        return
    raise Refused(f"mkdir {path} outside its tagged path {tagged}")


def refuse_links(src):
    # Repository sources are copied as plain files. Any symlink, at the source
    # or anywhere inside a copied directory, is refused before a byte is copied:
    # a link could point outside the repository and outside the temporary HOME.
    if os.path.islink(src):
        raise Refused(f"symlink in repository source: {src}")
    if os.path.isdir(src):
        for root, dirs, files in os.walk(src):
            for name in dirs + files:
                if os.path.islink(os.path.join(root, name)):
                    raise Refused(f"symlink in repository source: {os.path.join(root, name)}")


HOME_VAR = re.compile(r"\$\{HOME\}|\$HOME(?![A-Za-z0-9_])")


def interpret(body, target, tagged):
    lines = body.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i].lstrip()
        i += 1
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        h = HEREDOC.match(stripped)
        if h:
            dest_tok, open_q, delim, close_q = h.groups()
            if bool(open_q) != bool(close_q):
                raise Refused(f"malformed heredoc: {stripped}")
            dest = operand(shlex.split(dest_tok)[0], "dst")
            writes_within(dest, target, tagged)
            content = []
            while i < len(lines) and lines[i] != delim:
                content.append(lines[i])
                i += 1
            if i >= len(lines):
                raise Refused(f"unterminated heredoc {delim}")
            i += 1
            text = "\n".join(content) + "\n"
            if not open_q:
                if "`" in text or "\\" in text:
                    raise Refused("unquoted heredoc contains a backtick or backslash")
                # $HOME only at a variable boundary: $HOME_SUFFIX is a different
                # variable and must stay, so the check below refuses it.
                text = HOME_VAR.sub(lambda _m: str(home), text)
                if "$" in text:
                    raise Refused("unquoted heredoc expands a variable other than $HOME")
            dest.write_text(text, encoding="utf-8")
            continue
        if re.search(r"[;&|<>`]|\$\(", stripped):
            raise Refused(f"shell operator in: {stripped}")
        argv = shlex.split(stripped)
        cmd, args = argv[0], argv[1:]
        if cmd == "mkdir" and len(args) == 2 and args[0] == "-p":
            dst = operand(args[1], "dst")
            mkdir_within(dst, target, tagged)
            dst.mkdir(parents=True, exist_ok=True)
        elif cmd == "cp" and len(args) in (2, 3) and (len(args) == 2 or args[0] == "-R"):
            src, dst = operand(args[-2], "src"), operand(args[-1], "dst")
            writes_within(dst, target, tagged)
            refuse_links(src)
            if src.is_dir():
                if len(args) != 3:
                    raise Refused(f"cp of a directory needs -R: {stripped}")
                shutil.copytree(src, dst / src.name if dst.is_dir() else dst, symlinks=False)
            else:
                shutil.copyfile(src, dst / src.name if dst.is_dir() else dst)
        elif cmd == "install" and len(args) == 4 and args[0] == "-m" and re.fullmatch(r"0?[0-7]{3}", args[1]):
            src, dst = operand(args[2], "src"), operand(args[3], "dst")
            writes_within(dst, target, tagged)
            refuse_links(src)
            shutil.copyfile(src, dst)
            os.chmod(dst, int(args[1], 8))
        elif cmd == "chmod" and len(args) == 2 and re.fullmatch(r"0?[0-7]{3}", args[0]):
            dst = operand(args[1], "dst")
            writes_within(dst, target, tagged)
            os.chmod(dst, int(args[0], 8))
        elif cmd == "rm" and args[:1] == ["-rf"] and len(args) == 2:
            dst = operand(args[1], "dst")
            if os.path.realpath(dst) != os.path.realpath(target):
                raise Refused(f"rm -rf is allowed only on the tagged path itself: {stripped}")
            if dst.is_dir() and not dst.is_symlink():
                shutil.rmtree(dst)
            elif dst.exists() or dst.is_symlink():
                dst.unlink()
        else:
            raise Refused(f"command not allowlisted: {cmd}")


guide = Path(guide_path).read_text(encoding="utf-8")
produced = []
for heading, n, tagged, lang, body in parse_blocks(guide):
    name = f"{heading} [block {n}]"
    if tagged is None:
        if lang in ("bash", "sh", ""):
            reasons = [label for label, rx in SKIP_REASONS if rx.search(body)]
            if reasons:
                print(f"skipped: {name}: calls {', '.join(reasons)}")
        continue
    try:
        target = tag_target(tagged)
        if lang in ("bash", "sh"):
            interpret(body, target, tagged)
            print(f"replayed: {name} -> {tagged}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("a", encoding="utf-8") as handle:
                handle.write(body)
            print(f"written: {name} -> {tagged} (content block)")
    except Refused as exc:
        failures.append(f"tagged block {name} ({tagged}) refused: {exc}")
        continue
    if not target.exists():
        failures.append(f"tagged block {name} did not produce {tagged}")
    produced.append(tagged)

for tagged in EXPECTED:
    if tagged not in produced:
        failures.append(f"guide has no tagged block writing {tagged}")

home_s = str(home)
for path in sorted(home.rglob("*")):
    if path.is_symlink():
        # Never followed: its target could lie outside the temporary HOME.
        failures.append(f"~/{path.relative_to(home)}: symlink in rendered output")
        continue
    if not path.is_file() or "node_modules" in path.parts:
        continue
    rel = "~/" + str(path.relative_to(home))
    text = path.read_bytes().decode("utf-8", errors="replace")
    if path.suffix == ".json":
        try:
            json.loads(text)
        except ValueError as exc:
            failures.append(f"{rel}: JSON does not parse: {exc}")
    for label, rx in SECRET_PATTERNS:
        if rx.search(text):
            failures.append(f"{rel}: looks like a secret value ({label})")
    if "/Users/" in text.replace(home_s, "__HOME__"):
        failures.append(f"{rel}: absolute /Users/ path left unreplaced")


def listing(root):
    out = set()
    for p in root.rglob("*"):
        rel = p.relative_to(root)
        if p.is_file() and not p.is_symlink() and not any(part in COPY_EXCLUDES for part in rel.parts):
            out.add(rel)
    return out


for tagged, source in COPIES.items():
    dst, src = home / tagged[2:], repo / source
    if not dst.exists():
        continue
    if src.is_file():
        if dst.read_bytes() != src.read_bytes():
            failures.append(f"{tagged}: differs from tracked {source}")
        continue
    a, b = listing(src), listing(dst)
    if a != b:
        failures.append(f"{tagged}: file set differs from {source}: {sorted(map(str, a ^ b))[:10]}")
    for rel in sorted(a & b):
        if not filecmp.cmp(src / rel, dst / rel, shallow=False):
            failures.append(f"{tagged}: {rel} differs from {source}/{rel}")

if against_live == "1":
    live = Path(live_home)

    def normalise(data, root):
        return data.decode("utf-8").replace(str(root), "__HOME__")

    for rel in LIVE_FILES:
        mine, theirs = home / rel, live / rel
        if not theirs.is_file():
            failures.append(f"live {rel}: missing")
            continue
        if mine.is_symlink() or not mine.is_file():
            failures.append(f"guide {rel}: not rendered")
            continue
        a, b = normalise(mine.read_bytes(), home), normalise(theirs.read_bytes(), live)
        for side, text in (("guide", a), ("live", b)):
            if "/Users/" in text:
                failures.append(f"{side} {rel}: residual /Users/ path after placeholder substitution")
        if a == b:
            print(f"live: {rel} IDENTICAL")
        else:
            failures.append(f"live {rel}: DIFFERS from the guide's rendering")

for failure in failures:
    print(f"FAIL: {failure}", file=sys.stderr)
print(f"pi-guide-parity: {'FAIL' if failures else 'PASS'} ({len(produced)} tagged blocks, {len(failures)} failures)")
sys.exit(1 if failures else 0)
PY
if [ -n "$EMIT" ] && [ "$status" -eq 0 ]; then
  # A copy of the rendered temporary HOME, for inspection and for tests. Only
  # a passing render is emitted, so a refused one leaves nothing behind.
  mkdir -p "$EMIT"
  cp -R "$SANDBOX_HOME/." "$EMIT/"
fi
exit "$status"
