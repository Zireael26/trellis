#!/usr/bin/env bash
# SessionStart: when running inside Herdr, inject the visible-pane rule and the
# foreman context so Claude auto-adopts the herdr-foreman skill for multi-unit work.
#
# Lean C04: SessionStart never resolves roles live (the resolver's usage and
# credential probes cost up to two 20-second passes) and never adopts a cached
# roster. It reports the roles as undecided and prints the on-demand resolver
# command.
[ "${HERDR_ENV:-}" = 1 ] || exit 0
echo "HARD RULE (owner): all delegated agent work (workers, reviewers, consults, foremen, research, one-shot pi -p/codex exec) MUST use visible Herdr panes; only harness-native subagents and Dynamic Workflow agents are exempt. One-shot: core-rules/references/herdr-foreman.md § pi launch forms (1.1.0 and above)."
if [ -z "${HERDR_WORKSPACE_ID:-}" ] || [ -z "${HERDR_PANE_ID:-}" ]; then
  echo "DEGRADED: inside Herdr but the current workspace or pane identity is unavailable; deciding roles were not resolved. Do not substitute silently."
  exit 0
fi
command -v pi >/dev/null 2>&1 || { echo "DEGRADED: inside Herdr but pi is not on PATH; foreman and resolver roles are unavailable. Do not substitute silently."; exit 0; }

# Caps the one external call left at SessionStart (`herdr agent list`) and
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
    python3 - "$secs" "$@" <<'PY'
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
# internally consistent one. Remove this pane's copy, as the resolving hook did
# before each pass, and leave a roster scoped to another Herdr pane for that
# pane. Status: 0 = none, 2 = removed, 3 = another pane's, else not removed.
ROSTER_STATUS=0
if [ -e "$ROLE_STATE" ] || [ -L "$ROLE_STATE" ]; then
  python3 - "$ROLE_STATE" "$HERDR_WORKSPACE_ID" "$HERDR_PANE_ID" <<'PY'
import json
import os
import stat
import sys

path, workspace, pane = sys.argv[1:]
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
    owner = (scope.get("herdr_workspace_id"), scope.get("herdr_pane_id"))
    if all(isinstance(value, str) and value for value in owner) and owner != (workspace, pane):
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
  ACTIVE_RELEASE="$(python3 - "$TRELLIS_ROOT/config.json" <<'PY'
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
if ! python3 - "$RELEASE_PAYLOAD" "$R" "$POLICY" <<'PY'
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

FOREMEN_RAW="$(run_with_timeout 2 herdr agent list 2>/dev/null)"
if [ "$?" -eq 0 ]; then
  FOREMEN="$(printf '%s\n' "$FOREMEN_RAW" | python3 -c '
import json,sys
try:
    a=[x for x in json.load(sys.stdin)["result"]["agents"] if x["agent"]=="pi"]
    print(", ".join("%s(%s,%s)" % (x["pane_id"], x["agent_status"], x["cwd"].rsplit("/",1)[-1]) for x in a) or "none")
except Exception:
    print("unknown")')"
else
  FOREMEN="unknown"
fi
echo "## herdr-foreman (auto)"
echo "Inside Herdr (pane ${HERDR_PANE_ID:-?}, workspace ${HERDR_WORKSPACE_ID:-?}). For any multi-unit task, follow skill \`herdr-foreman\`: Claude = apex (briefs, git, receipts), pi foreman pane = workflow/subagent driver, workers chosen by quota. Existing pi panes: ${FOREMEN}"

ON_DEMAND="SessionStart does not probe live quota or credentials; select an implementer, then run python3 $R --implementer <agent> in this pane to resolve on demand."
case "$ROSTER_STATUS" in
  0) ;;
  2) echo "Removed this pane's cached deciding roster at $ROLE_STATE; SessionStart never adopts a cached roster." ;;
  3) echo "The cached deciding roster at $ROLE_STATE belongs to another Herdr workspace or pane; it was left in place for that pane." ;;
  *) echo "DEGRADED: could not safely remove this pane's cached deciding roster at $ROLE_STATE; remove it before relying on any roster. Do not substitute silently." ;;
esac
echo "DEGRADED: SessionStart does not adopt a cached deciding roster; implementer, reviewer, security_reviewer, merge_reviewer, and refuter are undecided. $ON_DEMAND Do not substitute silently."
