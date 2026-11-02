#!/usr/bin/env bash
# SessionStart: when running inside a Herdr (herdr-core `hc`) terminal, inject
# the foreman context so the apex adopts the herdr-foreman skill for multi-unit
# work.
#
# Lean C04: SessionStart never resolves roles live (the resolver's usage and
# credential probes cost up to two 20-second passes) and never adopts a cached
# roster. It reports the roles as undecided and prints the on-demand resolver
# command.
# The Herdr app sets HC_SCOPE (unique per terminal) and HC_TERMINAL_ID for
# every terminal it runs; outside one this hook prints nothing.
[ -n "${HC_SCOPE:-}" ] && [ -n "${HC_TERMINAL_ID:-}" ] || exit 0
command -v pi >/dev/null 2>&1 || { echo "DEGRADED: inside Herdr but pi is not on PATH; foreman and resolver roles are unavailable. Do not substitute silently."; exit 0; }

# A real CPython, never a pyenv-style shim (~0.4 s for each of the calls
# below). Only the payload's own resolver is trusted; a mapped copy keeps PATH.
case "${BASH_SOURCE[0]}" in
  */core-rules/hooks/*)
    # shellcheck source=../../scripts/lib/trellis-python.sh disable=SC1091
    . "${BASH_SOURCE[0]%/*}/../../scripts/lib/trellis-python.sh" 2>/dev/null ;;
  */core-rules/codex/hooks/*)
    # shellcheck source=../../../scripts/lib/trellis-python.sh disable=SC1091
    . "${BASH_SOURCE[0]%/*}/../../../scripts/lib/trellis-python.sh" 2>/dev/null ;;
esac
command -v trellis_python >/dev/null 2>&1 && trellis_python || TRELLIS_PYTHON=python3

# Caps the one external call left at SessionStart (`hc ls`) and
# kills its whole process group on expiry.
run_with_timeout() {
  local secs="$1"
  shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      if (!defined $pid) { exit(127); }
      if ($pid == 0) { POSIX::setsid() or POSIX::_exit(127); exec @ARGV or POSIX::_exit(127); }
      $SIG{ALRM} = sub {
        kill("TERM", -$pid); select(undef, undef, undef, 0.3);
        kill("KILL", -$pid); waitpid($pid, 0); exit(142);
      };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
  else
    # Python is already a resolver dependency. Keep the cap on hosts without
    # Perl (GNU `timeout` is not available on the macOS hosts this runs on).
    "$TRELLIS_PYTHON" - "$secs" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
command = sys.argv[2:]
try:
    child = subprocess.Popen(command, start_new_session=True)
except OSError:
    raise SystemExit(127)
try:
    status = child.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        child.wait(timeout=0.3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        child.wait()
    raise SystemExit(142)
raise SystemExit(128 + (-status) if status < 0 else status)
PY
  fi
}

# The resolver expands "~" from HOME. TRELLIS_HOME is the canonical fallback
# when a minimal SessionStart environment has no HOME; otherwise keep resolver
# state in the normal user HOME (~/.trellis/state), not nested under a different
# machine-state directory.
STATE_HOME="${HOME:-${TRELLIS_HOME:-}}"
if [ -z "$STATE_HOME" ]; then
  echo "DEGRADED: no HOME or TRELLIS_HOME for resolver state; implementer and deciding review roles were not resolved. Select an implementer and run the resolver manually; do not substitute silently."
  exit 0
fi
HOME="$STATE_HOME"
export HOME
STATE_PARENT="$STATE_HOME/.trellis/state"
if ! (umask 077 && mkdir -p "$STATE_PARENT") 2>/dev/null ||
   ! chmod 700 "$STATE_PARENT" 2>/dev/null; then
  echo "DEGRADED: could not create a private resolver state parent at $STATE_PARENT; implementer and deciding review roles were not resolved. Do not substitute silently."
  exit 0
fi
ROLE_STATE="$STATE_PARENT/roles-resolved.json"
# SessionStart never adopts a cached deciding roster: roles-resolved.json has
# no resolver-origin attestation, so a same-account writer could plant a fresh,
# internally consistent one. Remove this terminal's copy, as the resolving hook
# did before each pass, and leave a roster scoped to another hc terminal for
# that terminal. Status: 0 = none, 2 = removed, 3 = another terminal's, else
# not removed.
ROSTER_STATUS=0
if [ -e "$ROLE_STATE" ] || [ -L "$ROLE_STATE" ]; then
  "$TRELLIS_PYTHON" - "$ROLE_STATE" "$HC_SCOPE" "$HC_TERMINAL_ID" <<'PY'
import json
import os
import stat
import sys

path, hc_scope, hc_terminal = sys.argv[1:]
try:
    seen = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(0)
scope = None
if stat.S_ISREG(seen.st_mode):
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, encoding="utf-8") as source:
            opened = os.fstat(source.fileno())
            if (opened.st_dev, opened.st_ino) == (seen.st_dev, seen.st_ino):
                artifact = json.load(source)
                if isinstance(artifact, dict):
                    scope = artifact.get("resolution_scope")
    except (OSError, UnicodeDecodeError, ValueError):
        scope = None
if isinstance(scope, dict):
    owner = (scope.get("hc_scope"), scope.get("hc_terminal_id"))
    if all(isinstance(value, str) and value for value in owner) and owner != (hc_scope, hc_terminal):
        raise SystemExit(3)
# Unlink only the entry inspected above; unlink never follows a symlink.
try:
    current = os.lstat(path)
    if (current.st_dev, current.st_ino) != (seen.st_dev, seen.st_ino):
        raise SystemExit(4)
    os.unlink(path)
except FileNotFoundError:
    pass
except OSError:
    raise SystemExit(4)
raise SystemExit(2)
PY
  ROSTER_STATUS=$?
fi

# A shared deciding artifact is governed only by the active immutable release.
# Project and legacy user copies can remain discoverable to a UI, but must never
# set the TTL, model mapping, or family policy that authorizes this artifact.
TRELLIS_ROOT="${TRELLIS_HOME:-}"
if [ -z "$TRELLIS_ROOT" ] && [ -n "${HOME:-}" ]; then
  TRELLIS_ROOT="$HOME/.trellis"
fi
ACTIVE_RELEASE=""
if [ -n "$TRELLIS_ROOT" ] && [ -f "$TRELLIS_ROOT/config.json" ]; then
  ACTIVE_RELEASE="$("$TRELLIS_PYTHON" - "$TRELLIS_ROOT/config.json" <<'PY'
import json
import sys

try:
    release = json.load(open(sys.argv[1], encoding="utf-8")).get("active_cli_release")
    if (
        not isinstance(release, str)
        or not release
        or release.strip() != release
        or "\x00" in release
        or "/" in release
        or "\\" in release
        or release in {".", ".."}
    ):
        raise ValueError("invalid active release")
    print(release)
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
)"
fi
RELEASE_PAYLOAD=""
if [ -n "$ACTIVE_RELEASE" ]; then
  RELEASE_PAYLOAD="$TRELLIS_ROOT/releases/$ACTIVE_RELEASE/payload"
fi
R="$RELEASE_PAYLOAD/core-rules/skills/herdr-foreman/scripts/resolve-roles.py"
POLICY="$RELEASE_PAYLOAD/core-rules/skills/herdr-foreman/roles.json"
if ! "$TRELLIS_PYTHON" - "$RELEASE_PAYLOAD" "$R" "$POLICY" <<'PY'
import os
import sys

payload = os.path.realpath(sys.argv[1])
if not os.path.isdir(payload):
    raise SystemExit(1)
for path in sys.argv[2:]:
    resolved = os.path.realpath(path)
    if (
        not os.path.isfile(resolved)
        or os.path.commonpath((payload, resolved)) != payload
    ):
        raise SystemExit(1)
PY
then
  echo "DEGRADED: active Trellis release resolver or roles policy is unavailable or escapes its payload; implementer and deciding review roles were not resolved. Do not substitute silently."
  exit 0
fi

FOREMEN="unknown"
if command -v hc >/dev/null 2>&1 && FOREMEN_RAW="$(run_with_timeout 2 hc ls --json 2>/dev/null)"; then
  FOREMEN="$(printf '%s\n' "$FOREMEN_RAW" | "$TRELLIS_PYTHON" -c '
import json,sys
try:
    a=[x for x in json.load(sys.stdin)["terminals"] if x.get("agent")=="pi"]
    print(", ".join("%s(%s,%s)" % (x["address"] + (" " + x["name"] if x.get("name") else ""), x.get("status") or "unknown", (x.get("cwd") or "?").rsplit("/",1)[-1]) for x in a) or "none")
except Exception:
    print("unknown")')"
fi
echo "## herdr-foreman (auto)"
echo "Inside Herdr (hc terminal ${HC_TERMINAL_ID}). For any multi-unit task, follow skill \`herdr-foreman\`: you are the apex (briefs, git, receipts); a pi foreman runs as your hc sub-agent and drives workers chosen by quota. Live pi agents: ${FOREMEN}"

ON_DEMAND="SessionStart does not probe live quota or credentials; select an implementer, then run python3 $R --implementer <agent> in this terminal to resolve on demand."
case "$ROSTER_STATUS" in
  0) ;;
  2) echo "Removed this terminal's cached deciding roster at $ROLE_STATE; SessionStart never adopts a cached roster." ;;
  3) echo "The cached deciding roster at $ROLE_STATE belongs to another hc terminal; it was left in place for that terminal." ;;
  *) echo "DEGRADED: could not safely remove this terminal's cached deciding roster at $ROLE_STATE; remove it before relying on any roster. Do not substitute silently." ;;
esac
echo "DEGRADED: SessionStart does not adopt a cached deciding roster; implementer, reviewer, security_reviewer, merge_reviewer, and refuter are undecided. $ON_DEMAND Do not substitute silently."
